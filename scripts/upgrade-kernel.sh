#!/bin/bash
# Bring the guest onto the newest kernel its distro offers, before ansible runs.
#
# This deliberately lives outside the playbook. packer's ansible provisioner
# proxies every task through packer's own SSH connection to the guest, so a
# reboot in the middle of the playbook kills that connection. The proxy keeps
# answering keepalives afterwards, so the task ansible has in flight never
# returns and never times out — the build hangs forever rather than failing.
# Rebooting between provisioners (expect_disconnect) is the supported way.
#
# This is the first of three provisioners in packer/qemu/packer.json that have
# to stay together and in order:
#
#   1. this script                     upgrade, and leave a marker if the newly
#                                      installed kernel is not the running one
#   2. shell, expect_disconnect        reboot when the marker is there; the lost
#                                      SSH connection is the expected outcome
#   3. shell, pause_before/max_retries reconnect gate — packer re-establishes the
#                                      connection here, so everything after runs
#                                      on the final kernel
#
# /run is tmpfs, so the marker can never end up in the shipped image, and a
# guest that already boots the newest kernel skips the reboot entirely.
#
# Caveat: this runs before the setup role, so it uses the base image's repos.
# Builds that point ansible at an internal mirror (http_proxy, extra_repos,
# disable_public_repos) do not get that configuration here.

set -euo pipefail

MARKER=/run/kernel-reboot-required
rm -f "$MARKER"

if command -v apt-get >/dev/null 2>&1; then
    # Any hold on a kernel package — ours or one inherited from the base cloud
    # image — would silently pin the kernel. showhold is filtered first because
    # `apt-mark unhold` errors out on a package that is not installed.
    held=$(apt-mark showhold | grep -E '^linux-' || true)
    if [ -n "$held" ]; then
        apt-mark unhold $held
    fi

    # full-upgrade, not upgrade: an Ubuntu kernel bump arrives as a NEW
    # linux-image-<abi> package pulled in by the linux-image-virtual meta
    # package, and a plain upgrade never installs new packages.
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get -y full-upgrade

    # Handles both naming schemes (linux-image-<abi> and
    # linux-image-unsigned-<abi>, depending on the cloud image) and drops
    # unversioned meta packages such as linux-image-virtual, which carry no ABI
    # and would break the sort. What remains is the `uname -r` form.
    # sort -V is required: lexically, 6.8.0-99 would beat 6.8.0-134.
    newest=$(dpkg-query -W -f='${Package}\n' 'linux-image-*' 2>/dev/null \
        | sed -E 's/^linux-image-(unsigned-)?//' \
        | grep -E '^[0-9]' \
        | sort -V | tail -1)

elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    pm=$(command -v dnf || command -v yum)
    "$pm" -y upgrade

    # Kernel packages on EL are install-only, so an upgrade lays the newest
    # kernel down alongside the running one. Reinstalling by name is
    # belt-and-suspenders: it pulls every kernel subpackage to the newest
    # available version regardless of how the upgrade treats install-only
    # packages. The list is derived from what is already installed rather than
    # assumed, because the layout differs by EL generation (EL7/AL2 ship a
    # monolithic `kernel`, EL8 splits out kernel-core/kernel-modules, EL9+ adds
    # kernel-modules-core) and asking for a package the distro does not ship
    # fails with "Unable to find a match".
    pkgs=$(rpm -qa --qf '%{NAME}\n' 'kernel*' \
        | grep -E '^kernel(-core|-modules|-modules-core)?$' | sort -u)
    if [ -n "$pkgs" ]; then
        "$pm" -y install $pkgs
    fi

    # %{VERSION}-%{RELEASE}.%{ARCH} is exactly the `uname -r` string here.
    query=kernel
    if rpm -q kernel-core >/dev/null 2>&1; then
        query=kernel-core
    fi
    newest=$(rpm -q "$query" --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V | tail -1)

else
    # A guest with no supported package manager has no kernel to upgrade.
    echo "kernel: no supported package manager — nothing to upgrade"
    exit 0
fi

running=$(uname -r)
echo "kernel: running=${running} newest=${newest}"

if [ "$newest" = "$running" ]; then
    echo "kernel: already booted the newest installed kernel — no reboot needed"
else
    echo "kernel: ${newest} installed but not running — requesting a reboot"
    : > "$MARKER"
fi
