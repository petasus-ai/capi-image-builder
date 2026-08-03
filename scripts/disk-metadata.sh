#!/usr/bin/env bash
# Disk geometry of a built golden image, for attachment as an OCI label.
#
# A container-disk's compressed registry size says nothing about the PVC it
# needs. CDI sizes an import against the disk's VIRTUAL size, and on a
# filesystem-mode PVC it additionally reserves CDIConfig.filesystemOverhead, so
# the PVC request has to be strictly LARGER than the image:
#
#   usable = requested x (1 - filesystemOverhead)   and   usable >= virtual size
#
# Without this label a DataVolume author has to guess, and the guess is silent
# until it fails: an nvidia_*_full_* image is a 40Gi disk, and the portal's
# 20Gi default rejected it at import with no hint of the right number. Even
# "just use 40Gi" fails, because 40 x 0.945 = 37.8Gi < 40Gi.
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
#    "minPvcSize":"43Gi","filesystemOverhead":0.055}
#
# minPvcSize is the SMALLEST request CDI accepts on a filesystem-mode PVC — it
# is a floor, not a recommendation. It leaves the guest almost no free space
# once cloud-init grows the root filesystem to fill the volume, so a consumer
# that sizes a working VM (rather than a one-off import) should add its own
# headroom on top. Block-mode PVCs take no overhead and need only
# virtualSizeGi, but requesting minPvcSize there is harmless.
#
# The overhead is CDI's 0.055 default. A cluster that sets a different
# CDIConfig.filesystemOverhead has to recompute from virtualSizeBytes, which is
# why the assumption is published alongside the result rather than baked into
# an opaque number.
set -euo pipefail

# CDIConfig.filesystemOverhead default, as per mille so the arithmetic below
# stays in integers — bash has no floats, and rounding a PVC size down by one
# byte is the difference between an import that works and one that does not.
FS_OVERHEAD_PER_MILLE=55

GIB=$((1024 * 1024 * 1024))

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

# ceil(a/b) == (a + b - 1) / b in integer division. Applied twice: once to undo
# the filesystem overhead, once to round the result up to a whole Gi. Rounding
# up is mandatory in both places — CDI compares against the exact byte count.
USABLE_PER_MILLE=$((1000 - FS_OVERHEAD_PER_MILLE))
MIN_BYTES=$(( (VSIZE * 1000 + USABLE_PER_MILLE - 1) / USABLE_PER_MILLE ))
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
