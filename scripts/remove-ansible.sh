#!/bin/bash -x

os_distro_raw=`awk -F '=' '/^ID=/ { print $2 }' /etc/os-release`
os_distro="${os_distro_raw%\"}"
os_distro="${os_distro#\"}"

if [ $os_distro == "centos" ]; then
    yum remove -y ansible
    rm -rf /tmp/*
    rm -rf /root/*.rpm
elif [ $os_distro == "rocky" ]; then
    dnf remove -y ansible
    dnf remove -y epel-release
    dnf -y makecache
    rm -rf /tmp/*
else
    echo "Unsupported OS"
fi
