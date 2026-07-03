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
# disappears, taking SR-IOV, RDMA and any NFS-over-RDMA mount with it. Whether
# the race is lost depends on when sunrpc happens to be pinned, so it hits some
# nodes of a cluster and not others.
#
# Put the stack back for any Mellanox device that ended up driverless, and judge
# the result by the netdev rather than by the driver binding, since the netdev is
# what everything downstream consumes. Exits non-zero if a device is still
# without one, so a node that could not be repaired shows up in systemctl
# --failed instead of looking healthy. No-op on nodes where openibd succeeded.
#
# Scope: only devices that are bound to no driver at all. A device that is bound
# yet exposes no interface is a different fault, and repairing it would mean
# unbinding a live driver -- out of scope here.
set -u

# systemd captures stdout into the journal under this unit, so there is no need
# to also call logger -- that only duplicates every line.
log() { echo "mlx-modules-ensure: $*"; }

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
for pci in "${driverless[@]}"; do
    dev="/sys/bus/pci/devices/$pci"

    if [ ! -e "$dev/driver" ]; then
        log "$pci still has no driver bound"
        unrepaired=1
        continue
    fi

    driver=$(basename "$(readlink -f "$dev/driver")")
    netdevs=("$dev"/net/*)
    if [ ${#netdevs[@]} -gt 0 ]; then
        log "$pci is bound to $driver, netdev $(basename "${netdevs[0]}")"
        continue
    fi

    # An InfiniBand-link-layer port exposes no netdev unless ib_ipoib is loaded,
    # which this script deliberately does not pull in; its RDMA device is the
    # working interface. Gate on the link layer: an Ethernet/RoCE function keeps
    # its infiniband/ node too, so accepting that without the check would call a
    # missing netdev a success on exactly the devices this exists to catch.
    for ibdev in "$dev"/infiniband/*; do
        for port in "$ibdev"/ports/*; do
            if [ "$(cat "$port/link_layer" 2>/dev/null)" = "InfiniBand" ]; then
                log "$pci is bound to $driver, InfiniBand port $(basename "$ibdev"), no netdev"
                continue 3
            fi
        done
    done

    log "$pci is bound to $driver but has no netdev and no InfiniBand port"
    unrepaired=1
done

exit "$unrepaired"
