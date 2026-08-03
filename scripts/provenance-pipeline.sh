#!/usr/bin/env bash
# Provenance pipeline: keyless signing + SLSA v1 attestation + signature sidecar.
#
# Signs the pushed image with cosign (keyless, Sigstore), attaches a SLSA v1
# provenance attestation, and publishes a field-whitelisted signature summary to
# the public mirror named in supply-chain.conf so the portal can state that an
# image is signed without doing crypto in the browser.
#
# Mirror path contract (portal depends on it exactly):
#   <repository>/sha256-<digest-hex>.signature.json
#
# The attestation itself is NEVER mirrored. Its runDetails.builder.id is the
# workflow URI, which names the private builder repo; publishing it verbatim
# would contradict the portal's redaction policy, and publishing a modified copy
# would make our mirror differ from the document that was actually signed —
# indistinguishable from tampering on a page whose purpose is trust. The
# statement stays registry-only, complete and unmodified, where
# `cosign verify-attestation` reads it.
#
# Scope: per-arch digests only. A manifest index (latest/latest-csap) is refused
# — its digest changes whenever either arch is rebuilt via `docker manifest
# create --amend`, so an index signature goes stale immediately.
#
# Usage:
#   provenance-pipeline.sh run <repo> <tag>
# Environment:
#   PROV_TOKEN                   write-access PAT for the mirror repo (MY_TOKEN in CI)
#   PROV_FORCE                   default false; re-sign and overwrite an existing sidecar
#   QUAY_USERNAME/QUAY_PASSWORD  registry credentials for `cosign login`
#   COSIGN_TOOLS_DIR             pinned-tool cache (default ~/.cache/sbom-tools)
set -euo pipefail

# Same pin as sbom-pipeline.sh. cosign stays on the 2.x line because
# attach/download sbom (the SBOM portal contract) are deprecated in 3.x.
COSIGN_VERSION="2.6.4"

# Registry, mirror and builder identity — the only builder-specific values in
# this script. See the note in sbom-pipeline.sh.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=supply-chain.conf
. "$SCRIPT_DIR/supply-chain.conf"

MIRROR_PUSH="https://x-access-token:${PROV_TOKEN:-}@github.com/${MIRROR_SLUG}.git"
# SLSA v1. NOT `slsaprovenance` — that is cosign's legacy alias for v0.2, whose
# schema expects builder/buildType/invocation/materials, not the
# buildDefinition/runDetails shape produced below. Declaring v0.2 while carrying
# a v1 body would pass `verify-attestation --type slsaprovenance` (the type just
# feeds back on itself) and only break for downstream consumers.
SLSA_TYPE="slsaprovenance1"
SLSA_PREDICATE_URI="https://slsa.dev/provenance/v1"
TOOLS_DIR="${COSIGN_TOOLS_DIR:-$HOME/.cache/sbom-tools}"
PROV_FORCE="${PROV_FORCE:-false}"

WORK=""
PUBLISHED="false"

log() { echo "[prov] $*"; }
die() { echo "[prov] ERROR: $*" >&2; exit 1; }
usage() { echo "usage: $0 run <repo> <tag>" >&2; exit 2; }
cleanup() { [[ -n "$WORK" ]] && rm -rf "$WORK"; }

host_arch() {
  case "$(uname -m)" in
    x86_64) echo amd64 ;;
    aarch64) echo arm64 ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}

ensure_tools() {
  mkdir -p "$TOOLS_DIR/bin"
  export PATH="$TOOLS_DIR/bin:$PATH"
  local have
  have=""
  command -v cosign >/dev/null 2>&1 && have=$(cosign version --json 2>/dev/null | jq -r '.gitVersion // empty' | sed 's/^v//') || true
  if [[ "$have" != "$COSIGN_VERSION" ]]; then
    log "installing cosign v${COSIGN_VERSION} (found: ${have:-none})"
    curl -sSfL -o "$TOOLS_DIR/bin/cosign" \
      "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-linux-$(host_arch)"
    chmod +x "$TOOLS_DIR/bin/cosign"
  fi
  command -v skopeo >/dev/null 2>&1 || die "skopeo not found"
  command -v jq >/dev/null 2>&1 || die "jq not found"
  log "tools: cosign $(cosign version --json 2>/dev/null | jq -r .gitVersion), $(skopeo --version)"
}

# Refuse manifest indexes: only per-arch child digests get signed.
assert_single_manifest() {
  local ref=$1 media
  media=$(skopeo inspect --raw "docker://${ref}" | jq -r '.mediaType // empty')
  case "$media" in
    *manifest.list.v2+json|*image.index.v1+json)
      die "refusing to sign a manifest index (${media}) — sign per-arch digests only" ;;
  esac
  log "manifest media type: ${media:-unknown} (single image)"
}

# SLSA v1 predicate. cosign wraps this in the in-toto Statement (subject +
# predicateType), so only the predicate body belongs here.
write_predicate() {
  local out=$1 repo=$2 tag=$3 digest=$4 started=$5
  local finished
  finished=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -n \
    --arg repository "${GITHUB_REPOSITORY:-unknown}" \
    --arg ref "${GITHUB_REF:-unknown}" \
    --arg sha "${GITHUB_SHA:-unknown}" \
    --arg workflow_ref "${GITHUB_WORKFLOW_REF:-unknown}" \
    --arg server "${GITHUB_SERVER_URL:-https://github.com}" \
    --arg run_id "${GITHUB_RUN_ID:-unknown}" \
    --arg run_attempt "${GITHUB_RUN_ATTEMPT:-1}" \
    --arg image "${REGISTRY}/${repo}:${tag}" \
    --arg digest "$digest" \
    --arg arch "$(uname -m)" \
    --arg started "$started" \
    --arg finished "$finished" \
    --arg build_type "$SLSA_BUILD_TYPE" \
    '{
      buildDefinition: {
        buildType: $build_type,
        externalParameters: {
          repository: $repository, ref: $ref, workflow: $workflow_ref,
          image: $image, imageDigest: $digest
        },
        internalParameters: { runnerArchitecture: $arch, runnerEnvironment: "self-hosted" },
        resolvedDependencies: [
          { uri: ("git+" + $server + "/" + $repository + "@" + $ref),
            digest: { gitCommit: $sha } }
        ]
      },
      runDetails: {
        builder: { id: $workflow_ref },
        metadata: {
          invocationId: ($server + "/" + $repository + "/actions/runs/" + $run_id + "/attempts/" + $run_attempt),
          startedOn: $started,
          finishedOn: $finished
        }
      }
    }' > "$out"
}

# Whitelist projection. cosign's verify output embeds the signing certificate;
# under keyless the repo path and commit SHA appear in the Subject, the
# githubWorkflow* fields, the 57264.1.3-.6 OID extensions AND inside
# Bundle.Payload.body (the base64 Rekor entry carries the whole cert). Blacklists
# therefore do not work — select fields individually and never emit Bundle.
write_sidecar() {
  local verify_out=$1 out=$2
  jq --arg identity "$SIGNER_DISPLAY_NAME" '{
    signed:    true,
    issuer:    (.[0].optional.Issuer // null),
    identity:  $identity,
    signedAt:  (if .[0].optional.Bundle.Payload.integratedTime
                then (.[0].optional.Bundle.Payload.integratedTime | todate)
                else null end),
    tlogIndex: (.[0].optional.Bundle.Payload.logIndex // null),
    tlogID:    (.[0].optional.Bundle.Payload.logID // null),
    digest:    .[0].critical.image."docker-manifest-digest"
  }' "$verify_out" > "$out"
}

# Publish-time gate: never let builder identity reach the public mirror. Runs
# BEFORE the push so a leak cannot land even transiently (acceptance criterion
# #6 checks the same thing after publish). Markers are specific on purpose — a
# bare org name would match the intentional `identity` display string.
assert_no_leak() {
  local file=$1 m
  for m in "${GITHUB_REPOSITORY:-$BUILDER_REPO}" \
           "github.com/${BUILDER_ORG}" \
           ".github/workflows" \
           "${GITHUB_SHA:-}"; do
    [[ -z "$m" ]] && continue
    if grep -qiF -- "$m" "$file"; then
      die "redaction gate: sidecar contains '${m}' — refusing to publish"
    fi
  done
  log "redaction gate passed"
}

publish() {
  local sidecar=$1 clone=$2 dest_rel=$3 repo=$4 hex=$5
  mkdir -p "$clone/$(dirname "$dest_rel")"
  cp "$sidecar" "$clone/$dest_rel"

  git -C "$clone" config user.name "$MIRROR_GIT_NAME"
  git -C "$clone" config user.email "$MIRROR_GIT_EMAIL"
  git -C "$clone" remote set-url origin "$MIRROR_PUSH"
  git -C "$clone" add "$dest_rel"
  if git -C "$clone" diff --cached --quiet; then
    log "sidecar unchanged — nothing to commit"
    return 0
  fi
  git -C "$clone" commit -q -m "Add signature sidecar for ${repo}@sha256:${hex:0:12}"

  local attempt
  for attempt in 1 2 3; do
    if GIT_TERMINAL_PROMPT=0 git -C "$clone" push -q origin "$MIRROR_BRANCH"; then
      log "mirror published: ${dest_rel}"
      PUBLISHED="true"
      return 0
    fi
    log "push failed (attempt ${attempt}/3) — rebasing and retrying"
    GIT_TERMINAL_PROMPT=0 git -C "$clone" pull -q --rebase origin "$MIRROR_BRANCH"
  done
  die "failed to push to the mirror after 3 attempts"
}

verify_raw() {
  local sidecar=$1 dest_rel=$2
  local url="${MIRROR_RAW}/${dest_rel}" want got attempt
  want=$(sha256sum < "$sidecar" | awk '{print $1}')
  for attempt in 1 2 3 4 5; do
    if got=$(curl -sf "$url" | sha256sum | awk '{print $1}') && [[ "$got" == "$want" ]]; then
      log "raw mirror verified: ${url}"
      return 0
    fi
    log "raw mirror not consistent yet (attempt ${attempt}/5) — waiting 30s"
    sleep 30
  done
  die "raw mirror verification failed: ${url}"
}

cmd_run() {
  [[ $# -eq 2 ]] || usage
  local repo=$1 tag=$2
  [[ -n "${PROV_TOKEN:-}" ]] || die "PROV_TOKEN is required"

  ensure_tools

  local digest hex ref
  digest=$(skopeo inspect --format '{{.Digest}}' "docker://${REGISTRY}/${repo}:${tag}")
  [[ "$digest" == sha256:* ]] || die "unexpected digest for ${repo}:${tag}: ${digest}"
  hex=${digest#sha256:}
  ref="${REGISTRY}/${repo}@${digest}"
  log "image ${REGISTRY}/${repo}:${tag} @ ${digest}"
  assert_single_manifest "$ref"

  WORK=$(mktemp -d)
  trap cleanup EXIT

  GIT_TERMINAL_PROMPT=0 git clone -q --depth 1 --branch "$MIRROR_BRANCH" "$MIRROR_HTTPS" "$WORK/mirror"
  local dest_rel="${repo}/sha256-${hex}.signature.json"
  if [[ -f "$WORK/mirror/$dest_rel" && "$PROV_FORCE" != "true" ]]; then
    log "signature sidecar already published for ${digest} — skipping (set PROV_FORCE=true to re-sign)"
    return 0
  fi

  # Registry credentials: the workflow logs in with `sudo docker login`, so the
  # runner user's docker config is empty. cosign logs in for itself, via stdin so
  # the token never reaches the process argument list.
  if [[ -n "${QUAY_USERNAME:-}" && -n "${QUAY_PASSWORD:-}" ]]; then
    printf '%s' "$QUAY_PASSWORD" | cosign login "$REGISTRY_HOST" -u "$QUAY_USERNAME" --password-stdin >/dev/null
    log "cosign login to ${REGISTRY_HOST} as ${QUAY_USERNAME}"
  fi

  # Build start time for the predicate: the image's own created label, so the
  # window is the real build rather than this script's runtime.
  local started
  started=$(skopeo inspect "docker://${ref}" \
    | jq -r '.Labels["org.opencontainers.image.created"] // empty')
  [[ -n "$started" ]] || started=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  log "signing ${ref} (keyless)"
  COSIGN_YES=true cosign sign "$ref"

  log "attesting SLSA v1 provenance"
  write_predicate "$WORK/predicate.json" "$repo" "$tag" "$digest" "$started"
  COSIGN_YES=true cosign attest --type "$SLSA_TYPE" --predicate "$WORK/predicate.json" "$ref"

  # Self-check for acceptance criterion #5: the declared predicateType must be
  # SLSA v1, which a type round-trip through verify-attestation cannot catch.
  # --predicate-type filters server-side; without it a second attestation would
  # make the payload stream ambiguous.
  local declared
  declared=$(cosign download attestation --predicate-type="$SLSA_PREDICATE_URI" "$ref" 2>/dev/null \
    | jq -r '.payload' | base64 -d | jq -r '.predicateType')
  [[ "$declared" == "$SLSA_PREDICATE_URI" ]] \
    || die "attestation declares '${declared}', expected '${SLSA_PREDICATE_URI}'"
  log "attestation predicateType verified: ${declared}"

  # Verify before publishing. A failure here means we must NOT emit a sidecar
  # claiming the image is signed — fail the stage instead.
  log "verifying signature"
  local attempt=0
  until cosign verify "$ref" \
      --certificate-identity-regexp "^https://github\.com/${BUILDER_ORG}/.+" \
      --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
      --output json > "$WORK/verify.json" 2>/dev/null; do
    attempt=$((attempt + 1))
    # No Rekor propagation wait is needed: `cosign sign` bundles the Rekor entry
    # and its SignedEntryTimestamp into the signature, so verify runs offline.
    # This single retry only covers a transient network failure.
    [[ $attempt -ge 2 ]] && die "cosign verify failed for ${ref}"
    log "verify failed — one retry"
    sleep 5
  done
  log "signature verified"

  local sidecar="$WORK/sha256-${hex}.signature.json"
  write_sidecar "$WORK/verify.json" "$sidecar"
  jq -e 'has("signed") and has("digest")' "$sidecar" >/dev/null || die "malformed sidecar"
  assert_no_leak "$sidecar"
  log "sidecar: $(jq -c '{issuer, signedAt, tlogIndex}' "$sidecar")"

  publish "$sidecar" "$WORK/mirror" "$dest_rel" "$repo" "$hex"
  [[ "$PUBLISHED" == "true" ]] && verify_raw "$sidecar" "$dest_rel"
  log "provenance pipeline complete for ${ref}"
}

case "${1:-}" in
  run) shift; cmd_run "$@" ;;
  *)   usage ;;
esac
