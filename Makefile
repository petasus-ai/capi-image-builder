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

# If you update this file, please follow
# https://suva.sh/posts/well-documented-makefiles

# Ensure Make is run with bash shell as some syntax below is bash-specific
SHELL := /usr/bin/env bash

.DEFAULT_GOAL := help

# hack/ensure-packer.sh installs the pinned Packer here, so it has to outrank
# whatever version the build runner ships. Harmless when the directory does not
# exist, which is the case on a host that already has the pinned version.
export PATH := $(abspath .local/bin):$(PATH)

# Pin where Packer looks for plugins. Packer's own resolution is not
# self-consistent -- see hack/ensure-packer-plugins.sh -- so the install step
# and the build have to be told the same path rather than each guessing.
export PACKER_PLUGIN_PATH ?= $(HOME)/.packer.d/plugins

## --------------------------------------
## Help
## --------------------------------------
##@ Helpers
help: ## Display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-35s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

## --------------------------------------
## Dependencies
## --------------------------------------
##@ Dependencies

.PHONY: deps-qemu
deps-qemu: ## Installs Ansible, Packer and the Packer plugins the build needs
	hack/ensure-ansible.sh
	hack/ensure-packer.sh
	hack/ensure-packer-plugins.sh

## --------------------------------------
## Packer flags
## --------------------------------------

# Set Packer color to true if not already set in env variables
# Only valid for builds
ifneq (,$(findstring build-, $(MAKECMDGOALS)))
PACKER_COLOR ?= true
PACKER_FLAGS += -color=$(PACKER_COLOR)
endif

# We want the var files passed to Packer to have a specific order, because the
# precenence of the variables they contain depends on the order. Files listed
# later on the CLI have higher precedence. We want the common var files found in
# packer/config to be listed first, then the var files that specific to the
# provider, then any user-supplied var files so that a user can override what
# they need to.

# A list of variable files given to Packer to configure things like the versions
# of Kubernetes, CNI, and ContainerD to install. Any additional files from the
# environment are appended.
COMMON_VAR_FILES :=	packer/config/kubernetes.json \
					packer/config/cni.json \
					packer/config/containerd.json \
					packer/config/ansible-args.json \
					packer/config/goss-args.json \
					packer/config/common.json \
					packer/config/additional_components.json

# Initialize a list of flags to pass to Packer. This includes any existing flags
# specified by PACKER_FLAGS, as well as prefixing the list with the variable
# files from COMMON_VAR_FILES, with each file prefixed by -var-file=.
#
# Any existing values from PACKER_FLAGS take precendence over variable files.
PACKER_BUILD_FLAGS := $(foreach f,$(abspath $(COMMON_VAR_FILES)),-var-file="$(f)" ) \
				$(PACKER_FLAGS)
ABSOLUTE_PACKER_VAR_FILES := $(foreach f,$(abspath $(PACKER_VAR_FILES)),-var-file="$(f)" )

## --------------------------------------
## Platform and version combinations
## --------------------------------------
QEMU_AMD64_BUILD_NAMES			?=	qemu-ubuntu-2404 qemu-rockylinux-10-uefi
QEMU_ARM64_BUILD_NAMES			?=	qemu-ubuntu-2404-aarch64 qemu-rockylinux-10-uefi-aarch64

## --------------------------------------
## Dynamic build targets
## --------------------------------------
QEMU_AMD64_BUILD_TARGETS	:= $(addprefix build-,$(QEMU_AMD64_BUILD_NAMES))
QEMU_ARM64_BUILD_TARGETS	:= $(addprefix build-,$(QEMU_ARM64_BUILD_NAMES))
QEMU_AMD64_VALIDATE_TARGETS	:= $(addprefix validate-,$(QEMU_AMD64_BUILD_NAMES))
QEMU_ARM64_VALIDATE_TARGETS	:= $(addprefix validate-,$(QEMU_ARM64_BUILD_NAMES))

# Bound each packer build with a timeout so a stalled SNAT is killed at this bound and the
# job fails fast for a manual re-run. Override via the PACKER_BUILD_TIMEOUT env (see CI workflows).
PACKER_BUILD_TIMEOUT ?= 60m

# Cap the host-side packer/plugin Go runtime (defaults to nproc): packer 1.15 plugins
# busy-loop mid-build and burn tens of cores. Known issue: below ~16 the spinners starve
# packer's ansible SSH proxy instead (connections accepted but never served -> sudo/sftp hangs).
PACKER_GOMAXPROCS ?= 16

.PHONY: $(QEMU_AMD64_BUILD_TARGETS)
$(QEMU_AMD64_BUILD_TARGETS): deps-qemu
	GOMAXPROCS=$(PACKER_GOMAXPROCS) timeout $(PACKER_BUILD_TIMEOUT) packer build $(PACKER_BUILD_FLAGS) -var-file="packer/config/amd64-args.json" -var-file="$(abspath packer/qemu/$(subst build-,,$@).json)" $(ABSOLUTE_PACKER_VAR_FILES) packer/qemu/packer.json

.PHONY: $(QEMU_ARM64_BUILD_TARGETS)
$(QEMU_ARM64_BUILD_TARGETS): deps-qemu
	GOMAXPROCS=$(PACKER_GOMAXPROCS) timeout $(PACKER_BUILD_TIMEOUT) packer build $(PACKER_BUILD_FLAGS) -var-file="packer/config/arm64-args.json" -var-file="$(abspath packer/qemu/$(subst build-,,$@).json)" $(ABSOLUTE_PACKER_VAR_FILES) packer/qemu/packer.json

.PHONY: $(QEMU_AMD64_VALIDATE_TARGETS)
$(QEMU_AMD64_VALIDATE_TARGETS): deps-qemu
	packer validate $(PACKER_BUILD_FLAGS) -var-file="packer/config/amd64-args.json" -var-file="$(abspath packer/qemu/$(subst validate-,,$@).json)" $(ABSOLUTE_PACKER_VAR_FILES) packer/qemu/packer.json

.PHONY: $(QEMU_ARM64_VALIDATE_TARGETS)
$(QEMU_ARM64_VALIDATE_TARGETS): deps-qemu
	packer validate $(PACKER_BUILD_FLAGS) -var-file="packer/config/arm64-args.json" -var-file="$(abspath packer/qemu/$(subst validate-,,$@).json)" $(ABSOLUTE_PACKER_VAR_FILES) packer/qemu/packer.json


## --------------------------------------
## Dynamic clean targets
## --------------------------------------
# Keyed on packer's build_name (packer/qemu/*.json), which is what names the output
# directory: both architectures share one, and it carries neither the -uefi nor the
# -aarch64 suffix the build targets do.
QEMU_OUTPUT_NAMES := ubuntu-2404 rockylinux-10
QEMU_CLEAN_TARGETS := $(addprefix clean-qemu-,$(QEMU_OUTPUT_NAMES))
.PHONY: $(QEMU_CLEAN_TARGETS)
$(QEMU_CLEAN_TARGETS):
	rm -fr output/$(subst clean-qemu-,,$@)-kube*

## --------------------------------------
## Document dynamic build targets
## --------------------------------------
##@ Builds
build-qemu-ubuntu-2404: ## Builds Ubuntu 24.04 QEMU image
build-qemu-ubuntu-2404-aarch64: ## Builds Ubuntu 24.04 arm QEMU image
build-qemu-rockylinux-10-uefi: ## Builds Rocky Linux 10 UEFI QEMU image
build-qemu-rockylinux-10-uefi-aarch64: ## Builds Rocky Linux 10 UEFI arm QEMU image
build-qemu-amd64-all: $(QEMU_AMD64_BUILD_TARGETS) ## Builds all amd64 Qemu images
build-qemu-arm64-all: $(QEMU_ARM64_BUILD_TARGETS) ## Builds all arm64 Qemu images
build-qemu-all: $(QEMU_AMD64_BUILD_TARGETS) $(QEMU_ARM64_BUILD_TARGETS) ## Builds all Qemu images

## --------------------------------------
## Document dynamic validate targets
## --------------------------------------
##@ Validate packer config
validate-qemu-ubuntu-2404: ## Validates Ubuntu 24.04 QEMU image packer config
validate-qemu-ubuntu-2404-aarch64: ## Validates Ubuntu 24.04 QEMU image packer config
validate-qemu-rockylinux-10-uefi: ## Validates Rocky Linux 10 UEFI QEMU image packer config
validate-qemu-rockylinux-10-uefi-aarch64: ## Validates Rocky Linux 10 UEFI arm QEMU image packer config
validate-qemu-all: $(QEMU_AMD64_VALIDATE_TARGETS) $(QEMU_ARM64_VALIDATE_TARGETS) ## Validates all Qemu Packer config

validate-all: validate-qemu-all

## --------------------------------------
## Clean targets
## --------------------------------------
##@ Cleaning
.PHONY: clean
clean: ## Removes all image output directories and packer image cache
clean: $(QEMU_CLEAN_TARGETS) clean-packer-cache

.PHONY: clean-qemu
clean-qemu: ## Removes all qemu image output directories (see NOTE at top of help)
clean-qemu: $(QEMU_CLEAN_TARGETS)

.PHONY: clean-packer-cache
clean-packer-cache: ## Removes the packer cache
clean-packer-cache:
	rm -fr packer_cache/*
