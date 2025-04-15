#!/bin/bash -x

os_distro=$(awk -F '=' '/^ID=/ { gsub(/"/, "", $2); print $2 }' /etc/os-release)

if [ "$os_distro" = "rocky" ] || [ "$os_distro" = "almalinux" ]; then
    dnf install -y epel-release
    dnf -y makecache
    if ! command -v python3 &>/dev/null; then
        dnf install -y python3
    fi
fi