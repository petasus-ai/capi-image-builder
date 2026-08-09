#!/usr/bin/env bash

# Copyright 2019 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Install the Packer plugins packer/qemu/packer.json needs. The template is
# legacy JSON, so it declares no required_plugins and `packer init` is inert --
# without this step the plugins are whatever the build host happens to carry,
# and a fresh one fails with "The builder qemu is unknown by Packer".
#
# Run after hack/ensure-packer.sh: `packer plugins install` needs packer itself.
#
# PACKER_PLUGIN_PATH is pinned rather than left to Packer's own resolution,
# which is not self-consistent: Packer picks ~/.packer.d as its config directory
# when that directory exists and the XDG path otherwise, but it writes its
# checkpoint files to ~/.packer.d unconditionally -- so a host that resolved to
# the XDG path CREATES ~/.packer.d as a side effect, and the next invocation
# resolves to that instead and no longer sees the plugins just installed.
# Pinning the path makes install and build agree whatever else is on the host.
# The Makefile exports the same default.
#
# The goss provisioner was also renamed from packer-provisioner-goss to
# packer-plugin-goss at v3.2.0. Releases before that ship the pre-1.10
# single-binary layout, which Packer 1.10 and newer do not discover at all --
# this script used to pin v3.1.4 into exactly that layout. Keep it at 3.2+.
#
# goss_version in packer/config/goss-args.json is a different thing: the goss
# binary this plugin downloads into the guest.

set -o errexit
set -o nounset
set -o pipefail

[[ -n ${DEBUG:-} ]] && set -o xtrace

# Pinned: an unpinned `packer plugins install` resolves to whatever is latest on
# the day the host is bootstrapped, so a plugin release could change a build
# with no commit behind it. Same versions as edgestack-image-builder.
_qemu_plugin_version="v1.1.6"
_ansible_plugin_version="v1.1.6"
_goss_version="v3.2.14"

export PACKER_PLUGIN_PATH="${PACKER_PLUGIN_PATH:-${HOME}/.packer.d/plugins}"

if ! command -v packer >/dev/null 2>&1; then
  echo "!!! packer is not on \$PATH; run hack/ensure-packer.sh first." >&2
  exit 1
fi

# Idempotent: an already-installed plugin at the pinned version is left alone.
packer plugins install github.com/hashicorp/qemu "${_qemu_plugin_version}"
packer plugins install github.com/hashicorp/ansible "${_ansible_plugin_version}"
packer plugins install github.com/YaleUniversity/goss "${_goss_version}"

echo "Packer plugins in ${PACKER_PLUGIN_PATH}:"
packer plugins installed
