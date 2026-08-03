#!/usr/bin/env bash
# One-off SBOM backfill for an already-pushed containerdisk tag: pulls the
# image, extracts the qcow2, then runs the standard SBOM pipeline
# (scan -> cosign attach -> mirror publish). See README (SBOM Pipeline).
#
# Usage:
#   scripts/backfill-sbom.sh <repo> <tag>
#   e.g. scripts/backfill-sbom.sh ubuntu-2204-container-disk x86_64
#
# Requires: skopeo, GNU tar, plus everything sbom-pipeline.sh needs:
#   SBOM_TOKEN                   write-access PAT for the mirror repo
#   QUAY_USERNAME/QUAY_PASSWORD  or a prior `cosign login` to the registry
#
# Disk/time: the image is pulled and unpacked locally. NVIDIA "full" images
# have 15-20 GB compressed layers and a much larger extracted qcow2 — allow
# roughly 50 GB free in WORK_ROOT (default /var/tmp) and tens of minutes per
# image. Do not re-push the tag while a backfill for it is running.
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

echo "[backfill] pulling ${REGISTRY}/${REPO}:${TAG} (this may take a while)"
skopeo copy "docker://${REGISTRY}/${REPO}:${TAG}" "oci:${WORK}/oci:img"

# The qcow2 layer is by far the largest blob (the other layer is the alpine base).
BLOB=$(find "$WORK/oci/blobs" -type f -exec du -b {} + | sort -rn | head -1 | cut -f2)
echo "[backfill] extracting qcow2 from $(basename "$BLOB")"
tar -xzf "$BLOB" -C "$WORK" --wildcards "$IMAGE_DISK_GLOB"
QCOW2=$(find "$WORK/disk" -type f | head -1)
[[ -n "$QCOW2" ]] || { echo "[backfill] ERROR: no disk image found in the layer" >&2; exit 1; }

"$PIPELINE" run "$QCOW2" "$REPO" "$TAG"
