#!/bin/bash -x

os_distro_raw=`awk -F '=' '/^ID=/ { print $2 }' /etc/os-release`
os_distro="${os_distro_raw%\"}"
os_distro="${os_distro#\"}"

if [ $os_distro == "rocky" ]; then
    dnf -y makecache
    dnf install -y epel-release
    dnf -y makecache
    dnf install -y python3
fi
