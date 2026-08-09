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

set -o errexit
set -o nounset
set -o pipefail

[[ -n ${DEBUG:-} ]] && set -o xtrace

_version="1.14.2"

# Change directories to the parent directory of the one in which this
# script is located.
cd "$(dirname "${BASH_SOURCE[0]}")/.."

source hack/utils.sh

_bindir="$(pwd)/.local/bin"

# Report the version of the packer on PATH, empty if there is none. sed rather
# than `head -n 1`, which would close the pipe on the first line and leave packer
# to die of SIGPIPE on the upgrade notice it prints after it -- a failed pipeline
# under `set -o pipefail`.
packer_version() {
  command -v packer >/dev/null 2>&1 || return 0
  packer version | sed -n -e '1s/^Packer v//p'
}

# A version check, not a presence check. The build runners ship their own packer,
# and a bare `command -v packer` accepted whatever that happened to be -- so the
# pin above described the version nothing actually used. Installing into
# .local/bin, which the Makefile puts ahead of the rest of PATH, pins the build
# without touching the runner image.
if [ "$(packer_version)" != "${_version}" ]; then
  mkdir -p "${_bindir}"

  SED="sed"
  if command -v gsed >/dev/null; then
    SED="gsed"
  fi
  if ! (${SED} --version 2>&1 | grep -q GNU); then
    echo "!!! GNU sed is required.  If on OS X, use 'brew install gnu-sed'." >&2
    exit 1
  fi

  (
    cd "${_bindir}"

    _chkfile="packer_${_version}_SHA256SUMS"
    _chk_url="https://releases.hashicorp.com/packer/${_version}/${_chkfile}"
    _zipfile="packer_${_version}_${HOSTOS}_${HOSTARCH}.zip"
    _zip_url="https://releases.hashicorp.com/packer/${_version}/${_zipfile}"
    curl -SsLO "${_chk_url}"
    curl -SsLO "${_zip_url}"
    ${SED} -i -n "/${HOSTOS}_${HOSTARCH}/p" "${_chkfile}"
    checksum_sha256 "${_chkfile}"
    unzip -o "${_zipfile}"
    rm -f "${_chkfile}" "${_zipfile}"
  )

  echo "packer ${_version} has been installed to ${_bindir}"
fi
