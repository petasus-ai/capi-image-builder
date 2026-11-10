#!/bin/bash
# Bring the Mellanox module stack up after openibd, and repair what an aborted
# openibd start left behind.
#
# openibd's "start" begins with a "stop", and that stop aborts when one of the
# modules it wants to unload is still held. Two holders are seen on these
# images:
#
#   - sunrpc, which DOCA-OFED replaces for NFS-over-RDMA and which rpcbind, an
#     NFS mount in /etc/fstab or an rpcrdma entry in /etc/modules-load.d can
#     pin before openibd runs:
#
#       Unloading sunrpc                                        [FAILED]
#       rmmod: ERROR: Module sunrpc is in use
#
#   - mlx5_core itself, when udev has already probed the passed-through
#     functions and loaded mlx5_ib before openibd gets to them:
#
#       rmmod: ERROR: Module mlx5_core is in use by: mlx5_ib
#
#   openibd.service: Main process exited, code=exited, status=1/FAILURE
#
# Whether the race is lost depends on boot timing, so it hits some boots and
# not others, and it leaves the guest in one of two states:
#
#   - the unload half ran far enough to take mlx5_core with it, so the Mellanox
#     functions (typically SR-IOV VFs) are bound to no driver and their netdevs
#     are gone, taking RDMA and any LNet mount with them;
#   - the functions (typically passed-through PFs) kept mlx5_core but the load
#     half never ran, so mlx5_ib or the upper RDMA modules (ib_umad, rdma_ucm,
#     ...) are missing and the node differs from one where openibd succeeded.
#
# The modprobe pass therefore runs unconditionally -- a driverless function is
# not the only symptom -- and the rebinding pass covers the first state. The
# result is judged per function by what everything downstream consumes: an
# InfiniBand-link-layer port or a netdev. Exits non-zero when a Mellanox
# function is left with neither, so a guest that could not be repaired shows up
# in `systemctl --failed` instead of looking healthy.
#
# IPoIB follows openibd's own switch: ib_ipoib is loaded here only when the
# last IPOIB_LOAD assignment in /etc/infiniband/openib.conf is yes. The image
# build sets it to no by default (the platform uses InfiniBand for RDMA only and
# gives IB links no address), so every node comes up the same whichever way
# openibd went. Turning IPoIB on also needs /etc/modprobe.d/petasus-no-ipoib.conf,
# which makes `modprobe ib_ipoib` a no-op, removed; the doca_ipoib role variable
# does both.
#
# Shared verbatim between capi-image-builder and edgestack-image-builder (master
# lines); change both copies together. The cilium-line copies predate the
# IPoIB switch and always load ib_ipoib.
set -u

# systemd captures stdout into the journal under this unit, so there is no need
# to also call logger -- that only duplicates every line.
log() { echo "mlx-modules-ensure: $*"; }

shopt -s nullglob

mellanox=()
driverless=()
for dev in /sys/bus/pci/devices/*; do
    [ "$(cat "$dev/vendor" 2>/dev/null)" = "0x15b3" ] || continue
    mellanox+=("$(basename "$dev")")
    [ -e "$dev/driver" ] || driverless+=("$(basename "$dev")")
done

if [ ${#mellanox[@]} -eq 0 ]; then
    log "no Mellanox device present, nothing to do"
    exit 0
fi

log "Mellanox devices: ${mellanox[*]}"
[ ${#driverless[@]} -eq 0 ] || log "with no driver bound: ${driverless[*]}"

# mlx5_core first so the rebinding pass below has a driver to bind to.
modules=(mlx5_core mlx5_ib ib_umad ib_uverbs rdma_ucm)
# openibd sources the file, so the last assignment wins; judge that one alone.
ipoib_load=$(grep -sE '^[[:space:]]*IPOIB_LOAD=' /etc/infiniband/openib.conf | tail -n1)
if printf '%s\n' "$ipoib_load" | grep -qE '^[[:space:]]*IPOIB_LOAD=["'"'"']?yes["'"'"']?[[:space:]]*(#.*)?$'; then
    modules+=(ib_ipoib)
else
    log "IPoIB is off (IPOIB_LOAD is not yes in /etc/infiniband/openib.conf), not loading ib_ipoib"
fi

for mod in "${modules[@]}"; do
    if err=$(modprobe "$mod" 2>&1); then
        # modprobe is a no-op, and still exits 0, when the module is already
        # resident -- so this says the module is present, not that it was loaded.
        log "$mod present"
    else
        # Secure Boot rejecting an unsigned module, a DKMS build missing after a
        # kernel upgrade and a version mismatch all report themselves here.
        # Without this the failure is indistinguishable from "already loaded".
        log "modprobe $mod failed: ${err:-no output}"
    fi
done

# modprobe is a no-op when the module is already loaded, which leaves a device
# that lost its binding on its own -- a failed probe, a partial openibd stop, an
# earlier manual unbind -- exactly as it was. Ask the driver to take it.
for pci in "${driverless[@]}"; do
    [ -e "/sys/bus/pci/devices/$pci/driver" ] && continue
    if [ ! -w /sys/bus/pci/drivers/mlx5_core/bind ]; then
        log "cannot bind $pci: mlx5_core exposes no writable bind attribute (module not loaded?)"
        continue
    fi
    if err=$( { echo "$pci" > /sys/bus/pci/drivers/mlx5_core/bind; } 2>&1 ); then
        log "bound $pci to mlx5_core"
    else
        log "binding $pci to mlx5_core failed: ${err:-no output}"
    fi
done

# udev creates the netdev asynchronously, so settle before judging the outcome.
if command -v udevadm >/dev/null 2>&1; then
    udevadm settle --timeout=30 || true
else
    sleep 2
fi

unrepaired=0
for pci in "${mellanox[@]}"; do
    dev="/sys/bus/pci/devices/$pci"

    if [ ! -e "$dev/driver" ]; then
        log "$pci still has no driver bound"
        unrepaired=1
        continue
    fi

    driver=$(basename "$(readlink -f "$dev/driver")")

    # An InfiniBand-link-layer port is the working interface on an IB fabric,
    # and it appears only once mlx5_ib is loaded -- which is exactly what this
    # script exists to guarantee. Check it before the netdev, since with IPoIB
    # off an IB port has no netdev at all and still counts as repaired. Gate on
    # the link layer: an Ethernet/RoCE function keeps its infiniband/ node too,
    # and for one of those only the netdev below proves the stack is up.
    for ibdev in "$dev"/infiniband/*; do
        for port in "$ibdev"/ports/*; do
            if [ "$(cat "$port/link_layer" 2>/dev/null)" = "InfiniBand" ]; then
                log "$pci is bound to $driver, InfiniBand port $(basename "$ibdev")"
                continue 3
            fi
        done
    done

    netdevs=("$dev"/net/*)
    if [ ${#netdevs[@]} -gt 0 ]; then
        log "$pci is bound to $driver, netdev $(basename "${netdevs[0]}")"
        continue
    fi

    log "$pci is bound to $driver but has no netdev and no InfiniBand port"
    unrepaired=1
done

exit "$unrepaired"
