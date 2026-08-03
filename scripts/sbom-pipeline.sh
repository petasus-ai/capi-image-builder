#!/usr/bin/env bash
# SBOM pipeline for golden container-disk images.
#
# Generates an SPDX 2.3 JSON SBOM from the built qcow2 (read-only guestmount
# + syft on the build host — the guest is never modified), attaches it to the
# pushed image with cosign (source of truth in the registry, stored as the
# sha256-<hex>.sbom tag), and mirrors the same file to the public mirror
# repository named in supply-chain.conf, keyed by manifest digest so the
# registry portal can read it over CORS-enabled raw.githubusercontent.com.
#
# Mirror path contract (portal depends on it exactly):
#   <repository>/sha256-<digest-hex>.spdx.json
#
# Idempotency: if the mirror already has the digest-keyed file, the whole
# stage (scan/attach/mirror) is skipped as success — the digest guarantees
# the image content. Set SBOM_FORCE=true to regenerate and overwrite
# (manual repair only; retry until both attach and mirror succeed).
#
# Usage:
#   sbom-pipeline.sh run <qcow2-path> <repo> <tag>   full pipeline
#   sbom-pipeline.sh exists <repo> <tag>             exit 0 if the mirror
#                                                    already has the SBOM
# Environment:
#   SBOM_TOKEN                   write-access PAT for the mirror repo
#                                (required for `run`; injected from the
#                                MY_TOKEN CI secret)
#   SBOM_FORCE                   default false — see above
#   QUAY_USERNAME/QUAY_PASSWORD  optional; when both are set the script runs
#                                `cosign login` (no docker daemon involved),
#                                otherwise an existing credential is assumed
#   SBOM_TOOLS_DIR               where pinned tools are cached
#                                (default ~/.cache/sbom-tools)
set -euo pipefail

# Pinned tool versions (checked 2026-07). The script verifies the installed
# versions and downloads the pinned release when they differ, so whatever is
# preinstalled on the runner does not affect the output.
# cosign is deliberately pinned to the maintained 2.x line: `attach sbom` /
# `download sbom` are deprecated upstream (removal planned for v4) but they
# are the portal contract (.sbom tag), and 2.x keeps their behavior stable.
SYFT_VERSION="1.48.0"
COSIGN_VERSION="2.6.4"

# Registry, mirror and builder identity — the only builder-specific values in
# this script. Keeping them in one sourced file lets a sibling image builder
# adopt the pipeline by copying the script verbatim.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=supply-chain.conf
. "$SCRIPT_DIR/supply-chain.conf"

MIRROR_PUSH="https://x-access-token:${SBOM_TOKEN:-}@github.com/${MIRROR_SLUG}.git"
MIN_PACKAGES=100
# Size guard (spec v4): GitHub warns at 50MB and hard-blocks 100MB; exceeding
# this is the signal to renegotiate the size policy.
MAX_SBOM_BYTES=$((50 * 1024 * 1024))
TOOLS_DIR="${SBOM_TOOLS_DIR:-$HOME/.cache/sbom-tools}"
SBOM_FORCE="${SBOM_FORCE:-false}"

# Containerized fallback appliance: libguestfs boots the appliance VM with a
# kernel from the local environment, so guests whose filesystems are newer
# than the runner kernel (e.g. EL10 XFS on an EL8 runner) fail host-side
# inspection. The fallback reruns guestmount+syft inside a Fedora container
# whose much newer kernel-core package backs the appliance. Built once per
# runner and cached (docker system prune -f does not remove tagged images).
FALLBACK_IMAGE_TAG="sbom-guestfs-appliance:fedora42"

# Cataloger exclusions for a golden-IMAGE SBOM (we want what is INSTALLED and
# could actually be exploited, not declarations or redundant synthetic entries):
#
# -linux-kernel-cataloger: reads the kernel binary and emits a `linux-kernel`
#   package (type UnknownPackage, pkg:generic/). Redundant — the kernel is
#   already catalogued precisely as linux-image-*/kernel-core packages — and
#   harmful two ways: it only fires on x86 (the arm64 kernel image format is not
#   recognised), so the same image yields different SBOMs per architecture; and
#   grype matches that one entry against the whole Linux CVE set, adding ~9,800
#   findings on x86 and none on arm64.
#
# -python-package-cataloger: reads requirements.txt / setup.py / poetry.lock etc.
#   — DECLARED dependencies, not installed packages. It reported a phantom
#   `pillow 8.3.1` (2 Critical CVEs) from a single line in an NVIDIA HPC-X tool's
#   /opt/hpcx/clusterkit/bin/output/requirements.txt, though PIL is installed
#   nowhere and cannot be exploited. Installed python packages are still
#   catalogued by python-installed-package-cataloger (dist-info/egg-info), so
#   dropping this one removes declared-but-not-installed false positives only.
SYFT_CATALOGER_SELECT="-linux-kernel-cataloger,-python-package-cataloger"

WORK=""
MNT=""
PUBLISH_SKIPPED="false"

log() { echo "[sbom] $*"; }
die() { echo "[sbom] ERROR: $*" >&2; exit 1; }

usage() {
  echo "usage: $0 run <qcow2-path> <repo> <tag> | $0 exists <repo> <tag>" >&2
  exit 2
}

cleanup() {
  if [[ -n "$MNT" ]]; then
    guestunmount "$MNT" 2>/dev/null || true
    rmdir "$MNT" 2>/dev/null || true
  fi
  [[ -n "$WORK" ]] && rm -rf "$WORK"
}

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
  command -v syft >/dev/null 2>&1 && have=$(syft version 2>/dev/null | awk '/^Version:/{print $2}') || true
  if [[ "$have" != "$SYFT_VERSION" ]]; then
    log "installing syft v${SYFT_VERSION} (found: ${have:-none})"
    curl -sSfL "https://github.com/anchore/syft/releases/download/v${SYFT_VERSION}/syft_${SYFT_VERSION}_linux_${arch}.tar.gz" \
      | tar -xz -C "$TOOLS_DIR/bin" syft
  fi

  have=""
  command -v cosign >/dev/null 2>&1 && have=$(cosign version --json 2>/dev/null | jq -r '.gitVersion // empty' | sed 's/^v//') || true
  if [[ "$have" != "$COSIGN_VERSION" ]]; then
    log "installing cosign v${COSIGN_VERSION} (found: ${have:-none})"
    curl -sSfL -o "$TOOLS_DIR/bin/cosign" \
      "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-linux-${arch}"
    chmod +x "$TOOLS_DIR/bin/cosign"
  fi

  command -v guestmount >/dev/null 2>&1 || die "guestmount not found (install libguestfs-tools)"
  command -v skopeo >/dev/null 2>&1 || die "skopeo not found"
  command -v jq >/dev/null 2>&1 || die "jq not found"
  log "tools: syft $(syft version 2>/dev/null | awk '/^Version:/{print $2}'), cosign $(cosign version --json 2>/dev/null | jq -r .gitVersion), $(skopeo --version), $(guestmount --version | head -1)"
}

resolve_digest() {
  local repo=$1 tag=$2
  skopeo inspect --format '{{.Digest}}' "docker://${REGISTRY}/${repo}:${tag}"
}

clone_mirror() {
  local dest=$1
  GIT_TERMINAL_PROMPT=0 git clone -q --depth 1 --branch "$MIRROR_BRANCH" "$MIRROR_HTTPS" "$dest"
}

build_fallback_image() {
  if sudo docker image inspect "$FALLBACK_IMAGE_TAG" >/dev/null 2>&1; then
    return 0
  fi
  log "building the containerized libguestfs appliance image (one-time per runner)"
  sudo docker build -t "$FALLBACK_IMAGE_TAG" - << 'EOF'
FROM registry.fedoraproject.org/fedora:42
RUN dnf install -y guestfs-tools kernel-core && dnf clean all
EOF
}

scan_in_container() {
  local qcow2=$1 repo=$2 tag=$3
  build_fallback_image

  local qdir qname syft_bin
  qdir=$(cd "$(dirname "$qcow2")" && pwd)
  qname=$(basename "$qcow2")
  syft_bin=$(command -v syft)

  local kvm_args=()
  [[ -e /dev/kvm ]] && kvm_args+=(--device /dev/kvm)

  sudo docker run --rm "${kvm_args[@]}" \
    --device /dev/fuse --cap-add SYS_ADMIN \
    -v "$qdir":/in:ro,z \
    -v "$WORK":/work:z \
    -v "$syft_bin":/usr/local/bin/syft:ro,z \
    "$FALLBACK_IMAGE_TAG" \
    bash -c "set -euo pipefail
      export LIBGUESTFS_BACKEND=direct SYFT_FILE_METADATA_SELECTION=none
      mnt=\$(mktemp -d)
      guestmount -a '/in/${qname}' -i --ro \"\$mnt\"
      syft scan \"dir:\$mnt\" -o spdx-json -q --select-catalogers '${SYFT_CATALOGER_SELECT}' --source-name '${REGISTRY}/${repo}' --source-version '${tag}' > /work/sbom-raw.json
      guestunmount \"\$mnt\""
}

scan_qcow2() {
  local qcow2=$1 repo=$2 tag=$3 out=$4

  # The guest is never modified — prove it by hashing before and after.
  local pre post
  log "hashing ${qcow2} (pre-scan)"
  pre=$(sha256sum "$qcow2" | awk '{print $1}')

  export LIBGUESTFS_BACKEND=direct
  MNT=$(mktemp -d)
  log "mounting ${qcow2} read-only"
  if guestmount -a "$qcow2" -i --ro "$MNT" 2> "$WORK/guestmount.err"; then
    log "scanning with syft (package-level, file catalog disabled)"
    SYFT_FILE_METADATA_SELECTION=none syft scan "dir:${MNT}" -o spdx-json -q \
      --select-catalogers "$SYFT_CATALOGER_SELECT" \
      --source-name "${REGISTRY}/${repo}" \
      --source-version "${tag}" \
      > "$WORK/sbom-raw.json"
    guestunmount "$MNT"
    rmdir "$MNT" 2>/dev/null || true
    MNT=""
  else
    cat "$WORK/guestmount.err" >&2
    rmdir "$MNT" 2>/dev/null || true
    MNT=""
    log "host guestmount failed — retrying inside the containerized appliance (guest filesystem likely newer than the runner kernel supports)"
    scan_in_container "$qcow2" "$repo" "$tag"
  fi

  log "hashing ${qcow2} (post-scan)"
  post=$(sha256sum "$qcow2" | awk '{print $1}')
  [[ "$pre" == "$post" ]] || die "qcow2 changed during scan (${pre} -> ${post})"

  # Slim SBOM (spec v4): package-level only — drop file entries. But KEEP every
  # package<->package relationship (only file-referencing ones are dropped, since
  # .files is gone and they would dangle). This deliberately preserves syft's
  # ownership-by-file-overlap relationships (emitted in SPDX as OTHER): grype uses
  # them to recognise that a language package (pip `cryptography`) is owned by an
  # OS package (`python3-cryptography`) and collapse the duplicate. Filtering to
  # DESCRIBES-only — as this step used to — stripped them, so grype scored the pip
  # metadata independently against PyPI advisories and reported distro-backported
  # CVEs as unfixed false positives. Dropping .files is where the size win is;
  # package<->package relationships are tiny.
  jq -c '
    del(.files)
    | .relationships |= ((. // []) | map(select(
        ((.spdxElementId // "")      | startswith("SPDXRef-File") | not) and
        ((.relatedSpdxElement // "") | startswith("SPDXRef-File") | not)
      )))
  ' "$WORK/sbom-raw.json" > "$out"
  jq -e '((.files // []) | length) == 0' "$out" >/dev/null \
    || die "file-level entries remain in the SBOM after post-processing"

  local count size
  count=$(jq '.packages | length' "$out")
  size=$(wc -c < "$out")
  log "SBOM: ${count} packages, ${size} bytes"
  [[ "$count" -ge "$MIN_PACKAGES" ]] || die "only ${count} packages found (<${MIN_PACKAGES}) — treating as mount/scan failure"
  [[ "$size" -le "$MAX_SBOM_BYTES" ]] || die "SBOM is ${size} bytes (>${MAX_SBOM_BYTES}) — size policy needs renegotiation"
}

attach_sbom() {
  local sbom=$1 repo=$2 digest=$3
  local ref="${REGISTRY}/${repo}@${digest}"

  log "attaching SBOM to ${ref}"
  # --type takes (spdx|cyclonedx|syft); with a .json file cosign stores it
  # as media type text/spdx+json.
  cosign attach sbom --type spdx --sbom "$sbom" "$ref"

  # Round-trip verification: what quay serves must be byte-identical.
  local want got
  cosign download sbom "$ref" 2>/dev/null > "$WORK/sbom-roundtrip.json"
  want=$(sha256sum < "$sbom" | awk '{print $1}')
  got=$(sha256sum < "$WORK/sbom-roundtrip.json" | awk '{print $1}')
  [[ "$want" == "$got" ]] || die "cosign round-trip mismatch (${want} != ${got})"
  log "cosign round-trip verified (sha256 ${want})"
}

publish_mirror() {
  local sbom=$1 clone=$2 dest_rel=$3 repo=$4 hex=$5

  # Publish-time safety net: never overwrite an existing digest-keyed file
  # unless SBOM_FORCE=true (mirror files are immutable). If another run
  # published it between our entry check and now, keep the existing file.
  if [[ -f "$clone/$dest_rel" && "$SBOM_FORCE" != "true" ]]; then
    log "WARNING: mirror already has ${dest_rel} — keeping the existing file, skipping commit"
    log "WARNING: the quay .sbom tag was just refreshed by this run and may differ byte-wise from the mirror"
    PUBLISH_SKIPPED="true"
    return 0
  fi

  mkdir -p "$clone/$(dirname "$dest_rel")"
  cp "$sbom" "$clone/$dest_rel"

  git -C "$clone" config user.name "$MIRROR_GIT_NAME"
  git -C "$clone" config user.email "$MIRROR_GIT_EMAIL"
  git -C "$clone" remote set-url origin "$MIRROR_PUSH"
  git -C "$clone" add "$dest_rel"
  if git -C "$clone" diff --cached --quiet; then
    log "nothing to commit for ${dest_rel}"
    return 0
  fi
  git -C "$clone" commit -q -m "Add SBOM for ${repo}@sha256:${hex:0:12}"

  local attempt
  for attempt in 1 2 3; do
    if GIT_TERMINAL_PROMPT=0 git -C "$clone" push -q origin "$MIRROR_BRANCH"; then
      log "mirror published: ${dest_rel}"
      return 0
    fi
    log "push failed (attempt ${attempt}/3) — rebasing and retrying"
    GIT_TERMINAL_PROMPT=0 git -C "$clone" pull -q --rebase origin "$MIRROR_BRANCH"
  done
  die "failed to push to the mirror after 3 attempts"
}

verify_raw() {
  local sbom=$1 dest_rel=$2
  local url="${MIRROR_RAW}/${dest_rel}"
  local want got attempt
  want=$(sha256sum < "$sbom" | awk '{print $1}')

  # raw CDN propagation can lag by a few minutes.
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
  [[ $# -eq 3 ]] || usage
  local qcow2=$1 repo=$2 tag=$3
  [[ -f "$qcow2" ]] || die "qcow2 not found: $qcow2"
  [[ -n "${SBOM_TOKEN:-}" ]] || die "SBOM_TOKEN is required"

  ensure_tools

  local digest hex
  digest=$(resolve_digest "$repo" "$tag")
  [[ "$digest" == sha256:* ]] || die "unexpected digest for ${repo}:${tag}: ${digest}"
  hex=${digest#sha256:}
  log "image ${REGISTRY}/${repo}:${tag} @ ${digest}"

  WORK=$(mktemp -d)
  trap cleanup EXIT

  # Entry-time skip check against the mirror clone (not the raw CDN, which
  # can serve stale 404s).
  clone_mirror "$WORK/mirror"
  local dest_rel="${repo}/sha256-${hex}.spdx.json"
  if [[ -f "$WORK/mirror/$dest_rel" && "$SBOM_FORCE" != "true" ]]; then
    log "SBOM already published for ${digest} — skipping (set SBOM_FORCE=true to regenerate)"
    return 0
  fi

  if [[ -n "${QUAY_USERNAME:-}" && -n "${QUAY_PASSWORD:-}" ]]; then
    printf '%s' "$QUAY_PASSWORD" | cosign login "$REGISTRY_HOST" -u "$QUAY_USERNAME" --password-stdin >/dev/null
    log "cosign login to ${REGISTRY_HOST} as ${QUAY_USERNAME}"
  fi

  local sbom="$WORK/sbom-${repo}-${tag}.spdx.json"
  scan_qcow2 "$qcow2" "$repo" "$tag" "$sbom"
  attach_sbom "$sbom" "$repo" "$digest"
  publish_mirror "$sbom" "$WORK/mirror" "$dest_rel" "$repo" "$hex"
  if [[ "$PUBLISH_SKIPPED" != "true" ]]; then
    verify_raw "$sbom" "$dest_rel"
  fi
  log "SBOM pipeline complete for ${REGISTRY}/${repo}@${digest}"
}

cmd_exists() {
  [[ $# -eq 2 ]] || usage
  local repo=$1 tag=$2
  command -v skopeo >/dev/null 2>&1 || die "skopeo not found"

  local digest hex
  digest=$(resolve_digest "$repo" "$tag")
  [[ "$digest" == sha256:* ]] || die "unexpected digest for ${repo}:${tag}: ${digest}"
  hex=${digest#sha256:}

  WORK=$(mktemp -d)
  trap cleanup EXIT
  clone_mirror "$WORK/mirror"
  if [[ -f "$WORK/mirror/${repo}/sha256-${hex}.spdx.json" ]]; then
    log "present: ${repo}/sha256-${hex}.spdx.json"
    return 0
  fi
  log "absent: ${repo}/sha256-${hex}.spdx.json"
  return 1
}

case "${1:-}" in
  run)    shift; cmd_run "$@" ;;
  exists) shift; cmd_exists "$@" ;;
  *)      usage ;;
esac
