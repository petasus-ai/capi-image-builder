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
# The layer comes straight from the registry API and streams into tar, so
# neither the compressed blob nor a container tool's local layout is kept:
# `skopeo copy` into an OCI layout under WORK_ROOT failed on the arm64
# runners, where skopeo could not see the directory the script had just made
# ("lstat ...: no such file or directory"). The stream is checked against the
# layer digest the manifest names.
#
# Disk/time: NVIDIA "full" images extract to a qcow2 of tens of GB — allow
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

# A pull token for the repository: anonymous for a public repository, the
# registry login when one is given.
scope="repository:${REGISTRY_NAMESPACE}/${REPO}:pull"
auth=()
if [[ -n "${QUAY_USERNAME:-}" && -n "${QUAY_PASSWORD:-}" ]]; then
  auth=(-u "${QUAY_USERNAME}:${QUAY_PASSWORD}")
fi
token=$(curl -sf --retry 5 ${auth[@]+"${auth[@]}"} \
    "https://${REGISTRY_HOST}/v2/auth?service=${REGISTRY_HOST}&scope=${scope}" | jq -r '.token // empty')
[[ -n "$token" ]] || { echo "[backfill] ERROR: no pull token for ${REPO}" >&2; exit 1; }
base="https://${REGISTRY_HOST}/v2/${REGISTRY_NAMESPACE}/${REPO}"

# The per-arch tag is a single image manifest; the qcow2 layer is by far its
# largest (the other is the alpine base).
manifest=$(curl -sf --retry 5 -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
    -H "Accept: application/vnd.oci.image.manifest.v1+json" \
    "${base}/manifests/${TAG}")
layer=$(jq -r '.layers | max_by(.size) | .digest // empty' <<< "$manifest")
[[ "$layer" =~ ^sha256:[0-9a-f]{64}$ ]] \
  || { echo "[backfill] ERROR: ${REPO}:${TAG} is not a single image manifest with layers" >&2; exit 1; }
echo "[backfill] fetching ${REGISTRY}/${REPO}:${TAG} layer ${layer} ($(jq -r '.layers | max_by(.size) | .size' <<< "$manifest") bytes)"

for attempt in 1 2 3; do
  rm -rf "$WORK/disk" "$WORK/layer.sha256"
  # The digest is taken off the same stream tar reads; a blip mid-transfer
  # fails the pipeline and the attempt starts over.
  if curl -sfL --retry 5 -H "Authorization: Bearer ${token}" "${base}/blobs/${layer}" \
      | tee >(sha256sum | cut -d' ' -f1 > "$WORK/layer.sha256") \
      | tar -xzf - -C "$WORK" --wildcards "$IMAGE_DISK_GLOB"; then
    for _ in $(seq 1 50); do [[ -s "$WORK/layer.sha256" ]] && break; sleep 0.2; done
    if [[ "sha256:$(cat "$WORK/layer.sha256" 2>/dev/null)" == "$layer" ]]; then
      break
    fi
    echo "[backfill] WARNING: the layer did not match ${layer} (attempt ${attempt}/3)"
  else
    echo "[backfill] WARNING: fetching the layer failed (attempt ${attempt}/3)"
  fi
  [[ $attempt -lt 3 ]] || { echo "[backfill] ERROR: could not fetch ${layer}" >&2; exit 1; }
  sleep $((attempt * 30))
done

QCOW2=$(find "$WORK/disk" -type f | head -1)
[[ -n "$QCOW2" ]] || { echo "[backfill] ERROR: no disk image found in the layer" >&2; exit 1; }
echo "[backfill] extracted $(basename "$QCOW2") ($(du -h "$QCOW2" | cut -f1))"

"$PIPELINE" run "$QCOW2" "$REPO" "$TAG"
