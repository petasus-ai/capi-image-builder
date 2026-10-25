#!/usr/bin/env bash
# One-off SBOM backfill for an already-pushed containerdisk tag: fetches the
# image's qcow2 layer, extracts the qcow2, then runs the standard SBOM pipeline
# (scan -> cosign attach -> mirror publish). See README (SBOM Pipeline).
#
# Usage:
#   scripts/backfill-sbom.sh <repo> <tag>
#   e.g. scripts/backfill-sbom.sh ubuntu-2204-container-disk x86_64
#
# Requires: curl, jq, GNU tar, sha256sum, plus everything sbom-pipeline.sh
# needs:
#   SBOM_TOKEN                   write-access PAT for the mirror repo
#   QUAY_USERNAME/QUAY_PASSWORD  or a prior `cosign login` to the registry
#                                (also used for the layer pull when set)
#
# The layer comes straight from the registry API with curl, not `skopeo copy`
# into an OCI layout under WORK_ROOT: on the arm64 runners skopeo could not see
# the directory the script had just made ("lstat ...: no such file or
# directory"). The runners' link to quay.io drops long transfers - a 23 GB
# NVIDIA layer broke off after ~10 minutes, three times running - so the
# download resumes where it stopped (curl -C -, a fresh pull token each time)
# until the file has the manifest's size, is checked against the layer digest,
# and is deleted once the disk is extracted.
#
# Disk/time: NVIDIA "full" images have 20+ GB layers that extract to a disk of
# tens of GB, both on disk until the extraction ends — allow roughly 80 GB
# free in WORK_ROOT (default /var/tmp) and an hour or more per image. Do not
# re-push the tag while a backfill for it is running.
#
# Re-running for the same tag is a no-op (entry-time skip on the mirror),
# unless SBOM_FORCE=true.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=supply-chain.conf
. "$SCRIPT_DIR/supply-chain.conf"
PIPELINE="$SCRIPT_DIR/sbom-pipeline.sh"
WORK_ROOT="${WORK_ROOT:-/var/tmp}"

[[ $# -eq 2 ]] || { echo "usage: $0 <repo> <tag>" >&2; exit 2; }
REPO=$1
TAG=$2

# Entry-time skip before the expensive image pull.
if [[ "${SBOM_FORCE:-false}" != "true" ]] && "$PIPELINE" exists "$REPO" "$TAG"; then
  echo "[backfill] SBOM already published for ${REPO}:${TAG} — nothing to do"
  exit 0
fi

WORK=$(mktemp -d "${WORK_ROOT}/sbom-backfill.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# A pull token for the repository: anonymous for a public repository, the
# registry login when one is given. Taken again before every request, since
# the download outlives a token.
scope="repository:${REGISTRY_NAMESPACE}/${REPO}:pull"
auth=()
if [[ -n "${QUAY_USERNAME:-}" && -n "${QUAY_PASSWORD:-}" ]]; then
  auth=(-u "${QUAY_USERNAME}:${QUAY_PASSWORD}")
fi
pull_token() {
  curl -sf --retry 5 ${auth[@]+"${auth[@]}"} \
    "https://${REGISTRY_HOST}/v2/auth?service=${REGISTRY_HOST}&scope=${scope}" | jq -r '.token // empty'
}
token=$(pull_token)
[[ -n "$token" ]] || { echo "[backfill] ERROR: no pull token for ${REPO}" >&2; exit 1; }
base="https://${REGISTRY_HOST}/v2/${REGISTRY_NAMESPACE}/${REPO}"

# The per-arch tag is a single image manifest; the qcow2 layer is by far its
# largest (the other is the alpine base).
manifest=$(curl -sf --retry 5 -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
    -H "Accept: application/vnd.oci.image.manifest.v1+json" \
    "${base}/manifests/${TAG}")
layer=$(jq -r '.layers | max_by(.size) | .digest // empty' <<< "$manifest")
size=$(jq -r '.layers | max_by(.size) | .size // 0' <<< "$manifest")
[[ "$layer" =~ ^sha256:[0-9a-f]{64}$ && "$size" =~ ^[0-9]+$ ]] \
  || { echo "[backfill] ERROR: ${REPO}:${TAG} is not a single image manifest with layers" >&2; exit 1; }
echo "[backfill] fetching ${REGISTRY}/${REPO}:${TAG} layer ${layer} (${size} bytes)"

# Resume until the file is whole. A try that adds nothing counts against
# STALLS_ALLOWED; one that moves the file on resets it, so a link that keeps
# dropping but keeps delivering gets as many tries as it needs.
BLOB="$WORK/layer"
STALLS_ALLOWED=5
stalls=0
have=0
: > "$BLOB"
while (( have < size )); do
  before=$have
  token=$(pull_token) || true
  curl -sfL -C - -H "Authorization: Bearer ${token}" -o "$BLOB" "${base}/blobs/${layer}" || true
  have=$(stat -c %s "$BLOB" 2>/dev/null || stat -f %z "$BLOB")
  if (( have > size )); then
    echo "[backfill] WARNING: the layer grew past ${size} bytes — starting it over"
    : > "$BLOB"; have=0
  fi
  if (( have <= before )); then
    stalls=$((stalls + 1))
    (( stalls <= STALLS_ALLOWED )) || { echo "[backfill] ERROR: could not fetch ${layer} (${have}/${size} bytes)" >&2; exit 1; }
    sleep $((stalls * 30))
  else
    stalls=0
  fi
  (( have < size )) && echo "[backfill] ${have}/${size} bytes so far — resuming"
done
if [[ "sha256:$(sha256sum "$BLOB" | cut -d' ' -f1)" != "$layer" ]]; then
  echo "[backfill] ERROR: the layer does not match ${layer}" >&2
  exit 1
fi
echo "[backfill] layer verified; extracting the disk"
# Overlay whiteouts (.wh.*) are layer bookkeeping, not files: an ADD into a
# fresh directory leaves an empty disk/.wh..wh..opq beside the disk, which an
# extensionless IMAGE_DISK_GLOB ("disk/*") would otherwise take as the disk.
tar -xzf "$BLOB" -C "$WORK" --wildcards --exclude='*/.wh.*' "$IMAGE_DISK_GLOB"
rm -f "$BLOB"

# The largest file is the disk, whatever else the glob let through.
QCOW2=$(find "$WORK/disk" -type f ! -name '.wh.*' -exec ls -1S {} + 2>/dev/null | head -1)
[[ -n "$QCOW2" ]] || { echo "[backfill] ERROR: no disk image found in the layer" >&2; exit 1; }
echo "[backfill] extracted $(basename "$QCOW2") ($(du -h "$QCOW2" | cut -f1))"

"$PIPELINE" run "$QCOW2" "$REPO" "$TAG"
