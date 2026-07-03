#!/bin/bash
# Rewrite absolute symlinks under /usr/src/ofa_kernel to relative targets.
#
# DOCA-OFED >= 3.4 (mlnx-ofed-kernel-dkms 26.04) installs the real MOFED
# header/Module.symvers tree under /usr/src/ofa_kernel-dkms/ and leaves only
# absolute symlinks under /usr/src/ofa_kernel/ (x86_64/<kernel> -> the dkms
# tree, default -> /etc/alternatives/ofa_kernel_headers).
#
# The NVIDIA GPU operator driver container (driver.rdma.useHostMofed=true)
# bind-mounts the host /usr/src at /run/mellanox/drivers/usr/src, so absolute
# targets resolve against the container root and dangle there. The
# nvidia-peermem Kbuild then falls back to bare /usr/src/ofa_kernel and fails
# with "Module.symvers: No such file or directory". Relative symlinks resolve
# on both sides because the whole tree lives inside the same bind mount.
#
# The dkms POST_BUILD hook (dkms_ofed_post_build.sh) restores absolute links
# on every module rebuild, so this must run on every boot. A rebuilt kernel
# only takes effect after reboot, so boot-time normalization is sufficient.
set -eu

base=${1:-/usr/src/ofa_kernel}
[ -d "$base" ] || exit 0

find "$base" -maxdepth 2 -type l | while read -r link; do
    # Follow the full chain (including update-alternatives indirection).
    target=$(readlink -f "$link") || continue
    # Skip dangling links (e.g. leftovers pointing into /run/mellanox).
    [ -e "$target" ] || continue
    # Only rewrite targets that live in the same tree the GPU operator mounts.
    case "$target" in
        "${base%/*}"/*) ;;
        *) continue ;;
    esac
    rel=$(realpath --relative-to="$(dirname "$link")" "$target")
    ln -sfn "$rel" "$link"
done
