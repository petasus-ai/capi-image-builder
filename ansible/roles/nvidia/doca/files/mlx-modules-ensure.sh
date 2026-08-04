#!/bin/bash
# openibd tears the OFED module stack down before it loads it -- its "start"
# calls stop first -- and aborts when something still holds one of the modules.
# On these nodes that is sunrpc, which DOCA-OFED replaces (NFSoRDMA) and which
# rpcbind pins early in boot, so the service dies half way through:
#
#   openibd: Calling stop...
#   rmmod: ERROR: Module sunrpc is in use
#   openibd.service: Failed with result 'exit-code'
#
# The unload half has already run by then, so the node is left with mlx5_core
# gone and its Mellanox VFs bound to no driver at all -- the netdev simply
# disappears, taking SR-IOV, RDMA and any LNet mount with it. Whether the race
# is lost depends on when sunrpc happens to be pinned, so it hits some nodes of
# a cluster and not others.
#
# Reload the stack for any Mellanox device that ended up driverless. udev then
# renames the netdev and netplan reapplies its addresses exactly as it would on
# a clean boot, so this is a no-op on nodes where openibd succeeded.
set -u

log() {
    logger -t mlx-modules-ensure "$*" 2>/dev/null || true
    echo "mlx-modules-ensure: $*"
}

shopt -s nullglob

driverless=()
for dev in /sys/bus/pci/devices/*; do
    [ "$(cat "$dev/vendor" 2>/dev/null)" = "0x15b3" ] || continue
    [ -e "$dev/driver" ] && continue
    driverless+=("$(basename "$dev")")
done

if [ ${#driverless[@]} -eq 0 ]; then
    log "no Mellanox device is missing its driver, nothing to do"
    exit 0
fi

log "Mellanox devices with no driver bound: ${driverless[*]}"

for mod in mlx5_core mlx5_ib ib_umad ib_uverbs rdma_ucm; do
    if modprobe "$mod" 2>/dev/null; then
        log "loaded $mod"
    fi
done

for pci in "${driverless[@]}"; do
    driver_link="/sys/bus/pci/devices/$pci/driver"
    if [ -e "$driver_link" ]; then
        log "$pci is now bound to $(basename "$(readlink -f "$driver_link")")"
    else
        log "$pci still has no driver bound"
    fi
done
