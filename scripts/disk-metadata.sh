#!/usr/bin/env bash
# Disk geometry of a built golden image, for attachment as an OCI label.
#
# A container-disk's compressed registry size says nothing about the PVC it
# needs. The CDI importer compares the disk's VIRTUAL size with the free space
# it actually finds on the target volume (on a filesystem-mode PVC, the smaller
# of the filesystem's free space and the PVC request) and rejects the import
# when the disk does not fit: "virtual image size N is larger than the reported
# available storage M. A larger PVC is required".
#   https://github.com/kubevirt/containerized-data-importer/blob/v1.66.0/pkg/importer/data-processor.go
#
# A DataVolume spec.storage request is first grown by CDIConfig.filesystemOverhead
# (0.06 by default) before the PVC is created; a spec.pvc request is used as is.
# Either way the filesystem's own metadata comes off the PVC before the importer
# measures it, so the request has to be strictly LARGER than the image:
#   https://github.com/kubevirt/containerized-data-importer/blob/v1.66.0/doc/datavolumes.md#storage
#   https://github.com/kubevirt/containerized-data-importer/blob/v1.66.0/doc/cdi-config.md
#
#   pvc = requested x (1 + filesystemOverhead)   (spec.storage; spec.pvc: pvc = requested)
#   free space on pvc >= virtual size
#
# Without this label a DataVolume author has to guess, and the guess is silent
# until it fails: an nvidia_*_full_* image is a 40Gi disk, and the portal's
# 20Gi default rejected it at import with no hint of the right number. Even
# "just use 40Gi" fails, because a 40Gi filesystem never has 40Gi free.
#
# Emitting the measured size lets the portal compute the DataVolume size from
# the image instead of from a constant that has to be kept in sync with
# packer's disk_size by hand.
#
# Usage:
#   disk-metadata.sh <qcow2-path>     prints one line of JSON
#
# Output (the ai.petasus.disk label body):
#   {"virtualSizeBytes":42949672960,"virtualSizeGi":40,"minPvcSizeGi":43,
#    "minPvcSize":"43Gi","filesystemOverhead":0.06}
#
# minPvcSize is virtualSizeBytes grown the way CDI grows a spec.storage request
# (1MiB-aligned, x 1.06) and rounded up to a whole Gi: the PVC CDI itself would
# create for a request of the virtual size, and the floor for a spec.pvc
# request. It is a floor, not a recommendation. CDI's 6% is an assumption about
# the filesystem, and ext4 with its default 5% reserved blocks plus inode and
# journal metadata loses more than that, so a 16Gi disk requested at exactly
# virtualSizeGi fails there (16Gi x 1.06 = 16.96Gi PVC, about 15.9Gi free). It
# also leaves the guest almost no free space once cloud-init grows the root
# filesystem to fill the volume. A consumer should add its own headroom on top
# (edgespray requests 20Gi for the 16Gi disks and 48Gi for the 40Gi disk).
# Block-mode PVCs take no overhead and need only virtualSizeGi, but requesting
# minPvcSize there is harmless.
#
# The overhead is CDI's default. A cluster that sets a different
# CDIConfig.filesystemOverhead has to recompute from virtualSizeBytes, which is
# why the assumption is published alongside the result rather than baked into
# an opaque number.
set -euo pipefail

# CDIConfig.filesystemOverhead default (DefaultGlobalOverhead in CDI v1.66.0),
# as per mille so the arithmetic below stays in integers: bash has no floats,
# and rounding a PVC size down by one byte is the difference between an import
# that works and one that does not.
FS_OVERHEAD_PER_MILLE=60

MIB=$((1024 * 1024))
GIB=$((1024 * MIB))

log() { echo "[disk-meta] $*" >&2; }
die() { echo "[disk-meta] ERROR: $*" >&2; exit 1; }

[[ $# -eq 1 ]] || { echo "usage: $0 <qcow2-path>" >&2; exit 2; }
QCOW2=$1

[[ -f "$QCOW2" ]] || die "no such file: $QCOW2"
command -v qemu-img >/dev/null 2>&1 || die "qemu-img not found"
command -v jq >/dev/null 2>&1 || die "jq not found"

# Measure the artifact rather than reading back packer's disk_size variable:
# the label then describes the disk that was actually produced, and stays
# correct if a builder ever resizes or converts the image after packer runs.
VSIZE=$(qemu-img info --output=json "$QCOW2" | jq -r '."virtual-size"')
[[ "$VSIZE" =~ ^[0-9]+$ ]] && [[ "$VSIZE" -gt 0 ]] \
  || die "qemu-img reported no usable virtual-size for ${QCOW2} (got: ${VSIZE})"

# CDI's own arithmetic for a spec.storage request (GetRequiredSpace in
# pkg/util/util.go): align the size up to 1MiB, then grow it by the overhead.
# ceil(a/b) == (a + b - 1) / b in integer division, applied to the overhead and
# again to round up to a whole Gi. Rounding up is mandatory in both places: CDI
# compares against the exact byte count.
ALIGNED=$(( (VSIZE + MIB - 1) / MIB * MIB ))
MIN_BYTES=$(( (ALIGNED * (1000 + FS_OVERHEAD_PER_MILLE) + 999) / 1000 ))
MIN_GI=$(( (MIN_BYTES + GIB - 1) / GIB ))
VSIZE_GI=$(( (VSIZE + GIB - 1) / GIB ))

log "virtual=${VSIZE} bytes (${VSIZE_GI}Gi) -> min PVC ${MIN_GI}Gi at ${FS_OVERHEAD_PER_MILLE}/1000 overhead"

jq -nc \
  --argjson bytes "$VSIZE" \
  --argjson vgi "$VSIZE_GI" \
  --argjson mgi "$MIN_GI" \
  --argjson overhead "$(printf '0.%03d' "$FS_OVERHEAD_PER_MILLE")" \
  '{
     virtualSizeBytes: $bytes,
     virtualSizeGi:    $vgi,
     minPvcSizeGi:     $mgi,
     minPvcSize:       (($mgi | tostring) + "Gi"),
     filesystemOverhead: $overhead
   }'
