#!/usr/bin/env bash
# Vulnerability (CVE) pipeline for golden container-disk images.
#
# Scans the already-published SBOM (not the qcow2) with grype and publishes a
# grype-native JSON report to the public mirror repository named in
# supply-chain.conf, keyed by manifest digest, so the portal can read it over
# CORS-enabled raw.githubusercontent.com — the same mirror the SBOM lives in.
#
# Mirror path contract (portal depends on it exactly):
#   <repository>/sha256-<digest-hex>.vuln.json
#
# Storage model is the DELIBERATE OPPOSITE of the SBOM's. An SBOM is immutable
# per digest; a vulnerability report is mutable ("last scan"): the same image
# gains new CVEs over time as advisories are published. So this report is
# overwritten whenever it is re-scanned with a newer grype DB. A companion
# scheduled workflow in the mirror repo re-scans every SBOM daily.
#
# The SBOM is always read from the mirror clone (never assumed present on the
# build host): the SBOM stage skips its scan when the digest already exists and
# cleans up its work dir on exit. If the mirror has no SBOM for this digest
# (e.g. the SBOM stage failed under SBOM_STRICT=false), there is nothing to
# scan and the stage skips successfully.
#
# Usage:
#   vuln-pipeline.sh run <repo> <tag>
# Environment:
#   VULN_TOKEN    write-access PAT for the mirror repo (required; MY_TOKEN in CI)
#   VULN_FORCE    default false; when true, always overwrite regardless of the
#                 existing report's DB build date (manual repair)
#   VULN_STRICT   read by the workflow (continue-on-error), not by this script
#   GRYPE_TOOLS_DIR / GRYPE_DB_CACHE_DIR   tool + DB cache locations
set -euo pipefail

# Pinned tool version (checked 2026-07). Verified/installed like the SBOM
# pipeline so a runner's preinstalled grype cannot change the output.
GRYPE_VERSION="0.116.0"

# Registry and mirror — the only builder-specific values in this script. See
# the note in sbom-pipeline.sh.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=supply-chain.conf
. "$SCRIPT_DIR/supply-chain.conf"

MIRROR_PUSH="https://x-access-token:${VULN_TOKEN:-}@github.com/${MIRROR_SLUG}.git"
MAX_VULN_BYTES=$((50 * 1024 * 1024))

# Portal projection. grype's native JSON for a full distro scan is 70-95 MB
# (13k+ matches, each carrying relatedVulnerabilities/matchDetails/descriptions
# /epss/kev and full artifact metadata) — over the size guard and far too heavy
# for the portal to pull over the raw CDN. This keeps EXACTLY the fields the
# portal contract lists (spec §6) plus grype/DB versions (acceptance #4), which
# drops the payload to ~4 MB with zero match loss. It also NORMALIZES the DB
# build time to descriptor.db.built: grype v0.116 (DB v6) nests it under
# descriptor.db.status.built, so the portal's documented path would otherwise
# be null.
#
# fix.availableInDistro / fix.distroLatest come from distro-fix-check.sh (passed
# in as $av). grype matches Rocky/Alma against the RHEL feed — correct about
# whether a CVE applies, wrong about the fix existing yet, since EL clones
# rebuild Red Hat's errata later. Without these fields the portal cannot tell
# "upgrade available now" from "Red Hat fixed it, this distro has not shipped
# it", and grades an already-fully-upgraded image down for an impossible
# upgrade. null = not judged (non-distro package, or the lookup was skipped).
VULN_PROJECT='{
  descriptor: {
    name: .descriptor.name, version: .descriptor.version,
    timestamp: .descriptor.timestamp,
    db: {
      built: (.descriptor.db.built // .descriptor.db.status.built),
      schemaVersion: (.descriptor.db.schemaVersion // .descriptor.db.status.schemaVersion)
    }
  },
  matches: [.matches[] |
    ($av[.artifact.name + "|" + ((.vulnerability.fix.versions // []) | join(","))]) as $d | {
    vulnerability: {
      id: .vulnerability.id, severity: .vulnerability.severity,
      fix: {
        versions: (.vulnerability.fix.versions // []), state: .vulnerability.fix.state,
        availableInDistro: (if $d == null then null else $d.availableInDistro end),
        distroLatest: (if $d == null then null else $d.distroLatest end)
      },
      cvss: (.vulnerability.cvss // []), urls: (.vulnerability.urls // []),
      dataSource: .vulnerability.dataSource
    },
    artifact: {name: .artifact.name, version: .artifact.version, type: .artifact.type}
  }]
}'
TOOLS_DIR="${GRYPE_TOOLS_DIR:-$HOME/.cache/sbom-tools}"
export GRYPE_DB_CACHE_DIR="${GRYPE_DB_CACHE_DIR:-$HOME/.cache/grype}"
VULN_FORCE="${VULN_FORCE:-false}"

WORK=""
PUBLISHED="false"

log() { echo "[vuln] $*"; }
die() { echo "[vuln] ERROR: $*" >&2; exit 1; }

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
  local arch have
  arch=$(host_arch)

  have=""
  command -v grype >/dev/null 2>&1 && have=$(grype version 2>/dev/null | awk '/^Version:/{print $2}') || true
  if [[ "$have" != "$GRYPE_VERSION" ]]; then
    log "installing grype v${GRYPE_VERSION} (found: ${have:-none})"
    curl -sSfL "https://github.com/anchore/grype/releases/download/v${GRYPE_VERSION}/grype_${GRYPE_VERSION}_linux_${arch}.tar.gz" \
      | tar -xz -C "$TOOLS_DIR/bin" grype
  fi

  command -v skopeo >/dev/null 2>&1 || die "skopeo not found"
  command -v jq >/dev/null 2>&1 || die "jq not found"
  log "tools: grype $(grype version 2>/dev/null | awk '/^Version:/{print $2}'), $(skopeo --version)"
}

resolve_digest() {
  local repo=$1 tag=$2
  skopeo inspect --format '{{.Digest}}' "docker://${REGISTRY}/${repo}:${tag}"
}

# grype's descriptor.db.built path changed across DB schema versions; coalesce
# the known locations. Echoes the RFC3339 timestamp or "" if absent.
db_built() { jq -r '(.descriptor.db.built // .descriptor.db.status.built // "")' "$1" 2>/dev/null || echo ""; }

to_epoch() { date -d "$1" +%s 2>/dev/null || echo 0; }

cmd_run() {
  [[ $# -eq 2 ]] || usage
  local repo=$1 tag=$2
  [[ -n "${VULN_TOKEN:-}" ]] || die "VULN_TOKEN is required"

  ensure_tools

  local digest hex
  digest=$(resolve_digest "$repo" "$tag")
  [[ "$digest" == sha256:* ]] || die "unexpected digest for ${repo}:${tag}: ${digest}"
  hex=${digest#sha256:}
  log "image ${REGISTRY}/${repo}:${tag} @ ${digest}"

  WORK=$(mktemp -d)
  trap cleanup EXIT

  GIT_TERMINAL_PROMPT=0 git clone -q --depth 1 --branch "$MIRROR_BRANCH" "$MIRROR_HTTPS" "$WORK/mirror"
  local sbom_rel="${repo}/sha256-${hex}.spdx.json"
  local vuln_rel="${repo}/sha256-${hex}.vuln.json"
  local sbom="$WORK/mirror/${sbom_rel}"

  if [[ ! -f "$sbom" ]]; then
    log "no SBOM in the mirror for ${digest} — nothing to scan, skipping"
    return 0
  fi

  log "updating grype vulnerability DB"
  grype db update

  local raw="$WORK/vuln-raw.json"
  local vuln="$WORK/${repo//\//_}-${tag}.vuln.json"
  log "scanning SBOM with grype"
  grype "sbom:${sbom}" -o json > "$raw"

  jq -e '.descriptor and (.matches | type == "array")' "$raw" >/dev/null \
    || die "grype output missing descriptor/matches"

  # Resolve, per finding, whether the cited fix is actually published by THIS
  # distro (see VULN_PROJECT). Fails soft to {} — every field then stays null
  # and the report is exactly what it was before this step existed.
  local avail
  avail=$("$(dirname "${BASH_SOURCE[0]}")/distro-fix-check.sh" "$repo" "$raw" || echo '{}')
  echo "$avail" | jq -e 'type == "object"' >/dev/null 2>&1 || avail='{}'

  # Project to the portal contract (see VULN_PROJECT) before publishing.
  jq -c --argjson av "$avail" "$VULN_PROJECT" "$raw" > "$vuln"

  local size count built raw_size
  raw_size=$(wc -c < "$raw")
  size=$(wc -c < "$vuln")
  count=$(jq '.matches | length' "$vuln")
  built=$(jq -r '.descriptor.db.built // ""' "$vuln")
  log "vuln report: ${count} matches, DB built ${built:-unknown}, ${size} bytes (raw ${raw_size})"
  log "severity: $(jq -rc '[.matches[].vulnerability.severity] | group_by(.) | map({(.[0]): length}) | add // {}' "$vuln")"
  log "fixed-but-not-yet-in-this-distro: $(jq '[.matches[] | select(.vulnerability.fix.availableInDistro == false)] | length' "$vuln")"
  [[ "$size" -le "$MAX_VULN_BYTES" ]] || die "report is ${size} bytes (>${MAX_VULN_BYTES}) — size policy needs renegotiation"

  publish "$vuln" "$WORK/mirror" "$vuln_rel" "$repo" "$hex" "$built" "$count"

  if [[ "$PUBLISHED" == "true" ]]; then
    verify_raw "$vuln" "$vuln_rel"
  fi
  log "vulnerability pipeline complete for ${REGISTRY}/${repo}@${digest}"
}

publish() {
  local vuln=$1 clone=$2 dest_rel=$3 repo=$4 hex=$5 built=$6 count=$7
  local existing="$clone/$dest_rel"

  # Mutable-report update gate: overwrite only when this scan used a newer DB
  # than the published report, so re-runs with the same DB do not churn.
  if [[ -f "$existing" && "$VULN_FORCE" != "true" ]]; then
    local old_built new_e old_e
    old_built=$(db_built "$existing")
    new_e=$(to_epoch "$built"); old_e=$(to_epoch "$old_built")
    if [[ -n "$old_built" && "$new_e" -le "$old_e" ]]; then
      log "existing report DB (${old_built}) is not older than this scan (${built}) — skipping (no churn)"
      return 0
    fi
    log "existing report DB (${old_built:-unknown}) older than this scan (${built}) — overwriting"
  fi

  mkdir -p "$clone/$(dirname "$dest_rel")"
  cp "$vuln" "$existing"

  git -C "$clone" config user.name "$MIRROR_GIT_NAME"
  git -C "$clone" config user.email "$MIRROR_GIT_EMAIL"
  git -C "$clone" remote set-url origin "$MIRROR_PUSH"
  git -C "$clone" add "$dest_rel"
  if git -C "$clone" diff --cached --quiet; then
    log "report unchanged — nothing to commit"
    return 0
  fi

  local db_date="${built%%T*}"
  git -C "$clone" commit -q -m "Add vuln report for ${repo}@sha256:${hex:0:12} (grype db ${db_date:-unknown}, ${count} findings)"

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
  local vuln=$1 dest_rel=$2
  local url="${MIRROR_RAW}/${dest_rel}"
  local want got attempt
  want=$(sha256sum < "$vuln" | awk '{print $1}')
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

case "${1:-}" in
  run) shift; cmd_run "$@" ;;
  *)   usage ;;
esac
