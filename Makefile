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

# This option is for running docker manifest command
export DOCKER_CLI_EXPERIMENTAL := enabled
export PATH := $(PATH):$(PWD)/.local/bin

export IB_VERSION ?= $(shell git describe --dirty)

## --------------------------------------
## Help
## --------------------------------------
##@ Helpers
help: ## Display this help
	@echo NOTE
	@echo '  The "build-node-ova" targets have analogue "clean-node-ova" targets for'
	@echo '  cleaning artifacts created from building OVAs using a local'
	@echo '  hypervisor.'
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-35s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

.PHONY: version
version: ## Display version of image-builder
	@echo $(IB_VERSION)

## --------------------------------------
## Dependencies
## --------------------------------------
##@ Dependencies

.PHONY: deps
## Installs/checks all dependencies
deps: deps-qemu

## Installs/checks dependencies for QEMU builds
.PHONY: deps-qemu
deps-qemu:
	hack/ensure-ansible.sh
	hack/ensure-packer.sh

## --------------------------------------
## Container variables
## --------------------------------------
REGISTRY ?= gcr.io/$(shell gcloud config get-value project)
STAGING_REGISTRY := gcr.io/k8s-staging-scl-image-builder
IMAGE_NAME ?= cluster-node-image-builder
CONTROLLER_IMG ?= $(REGISTRY)/$(IMAGE_NAME)
TAG ?= dev
ARCH ?= amd64
BASE_IMAGE ?= docker.io/library/ubuntu:focal

## --------------------------------------
## Packer flags
## --------------------------------------

# Set Packer color to true if not already set in env variables
# Only valid for builds
ifneq (,$(findstring build-, $(MAKECMDGOALS)))
	# A build target
	PACKER_COLOR ?= true
	PACKER_FLAGS += -color=$(PACKER_COLOR)
endif

# If FOREGROUND=1 then Packer will set headless to false, causing local builds
# to build in the foreground, with a UI. This is very useful when debugging new
# platforms or issues with existing ones.
ifeq (1,$(strip $(FOREGROUND)))
PACKER_FLAGS += -var="headless=false"
endif

# If ON_ERROR_ASK=1 then Packer will set -on-error to ask, causing the Packer
# build to pause when any error happens, instead of simply exiting. This is
# useful when debugging unknown issues logging into the remote machine via ssh.
ifeq (1,$(strip $(ON_ERROR_ASK)))
PACKER_FLAGS += -on-error=ask
endif

# ssh_private_key_file and ssh_public_key are needed to pass ssh keypair
# from its host to the packer guest machine, so boot managers like ignition
# could make use of the key in its config.
# SSH_PRIVATE_KEY_FILE is name of the file that contains the private key.
# SSH_PUBLIC_KEY_FILE is name of the file that contains the public key.
ifneq (,$(strip $(SSH_PRIVATE_KEY_FILE)))
PACKER_FLAGS += -var ssh_private_key_file="$(SSH_PRIVATE_KEY_FILE)"
endif

ifneq (,$(strip $(SSH_PUBLIC_KEY_FILE)))
PACKER_FLAGS += -var ssh_public_key="$(shell cat ${SSH_PUBLIC_KEY_FILE})"
endif

# If DEBUG=1 then Packer will set -debug, enabling debug mode for builds, providing
# more verbose logging
ifeq (1,$(strip $(DEBUG)))
PACKER_FLAGS += -debug
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
COMMON_NODE_VAR_FILES :=	packer/config/kubernetes.json \
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
PACKER_NODE_FLAGS := $(foreach f,$(abspath $(COMMON_NODE_VAR_FILES)),-var-file="$(f)" ) \
				$(PACKER_FLAGS)
ABSOLUTE_PACKER_VAR_FILES := $(foreach f,$(abspath $(PACKER_VAR_FILES)),-var-file="$(f)" )

## --------------------------------------
## Platform and version combinations
## --------------------------------------
ROCKYLINUX_VERSIONS     :=  rockylinux-9-uefi
ALMALINUX_VERSIONS		:=	almalinux-9
UBUNTU_VERSIONS			:=	ubuntu-2204

QEMU_AMD64_BUILD_NAMES			?=	qemu-ubuntu-2204 qemu-rockylinux-9-uefi qemu-almalinux-9
QEMU_ARM64_BUILD_NAMES			?=	qemu-ubuntu-2204-aarch64 qemu-rockylinux-9-uefi-aarch64 qemu-almalinux-9-aarch64

## --------------------------------------
## Dynamic build targets
## --------------------------------------
QEMU_AMD64_BUILD_TARGETS	:= $(addprefix build-,$(QEMU_AMD64_BUILD_NAMES))
QEMU_ARM64_BUILD_TARGETS	:= $(addprefix build-,$(QEMU_ARM64_BUILD_NAMES))
QEMU_AMD64_VALIDATE_TARGETS	:= $(addprefix validate-,$(QEMU_AMD64_BUILD_NAMES))
QEMU_ARM64_VALIDATE_TARGETS	:= $(addprefix validate-,$(QEMU_ARM64_BUILD_NAMES))

.PHONY: $(QEMU_AMD64_BUILD_TARGETS)
$(QEMU_AMD64_BUILD_TARGETS): deps-qemu
	packer build $(PACKER_NODE_FLAGS) -var-file="packer/config/amd64-args.json" -var-file="$(abspath packer/qemu/$(subst build-,,$@).json)" $(ABSOLUTE_PACKER_VAR_FILES) -except=flatcar packer/qemu/packer.json

.PHONY: $(QEMU_ARM64_BUILD_TARGETS)
$(QEMU_ARM64_BUILD_TARGETS): deps-qemu
	packer build $(PACKER_NODE_FLAGS) -var-file="packer/config/arm64-args.json" -var-file="$(abspath packer/qemu/$(subst build-,,$@).json)" $(ABSOLUTE_PACKER_VAR_FILES) -except=flatcar packer/qemu/packer.json

.PHONY: $(QEMU_AMD64_VALIDATE_TARGETS)
$(QEMU_AMD64_VALIDATE_TARGETS): deps-qemu
	packer validate $(PACKER_NODE_FLAGS) -var-file="packer/config/amd64-args.json" -var-file="$(abspath packer/qemu/$(subst validate-,,$@).json)" $(ABSOLUTE_PACKER_VAR_FILES) -except=flatcar packer/qemu/packer.json

.PHONY: $(QEMU_ARM64_VALIDATE_TARGETS)
$(QEMU_ARM64_VALIDATE_TARGETS): deps-qemu
	packer validate $(PACKER_NODE_FLAGS) -var-file="packer/config/arm64-args.json" -var-file="$(abspath packer/qemu/$(subst validate-,,$@).json)" $(ABSOLUTE_PACKER_VAR_FILES) -except=flatcar packer/qemu/packer.json


## --------------------------------------
## Dynamic clean targets
## --------------------------------------
QEMU_CLEAN_TARGETS := $(subst build-,clean-,$(QEMU_BUILD_TARGETS))
.PHONY: $(QEMU_CLEAN_TARGETS)
$(QEMU_CLEAN_TARGETS):
	rm -fr output/$(subst clean-qemu-,,$@)-kube*

## --------------------------------------
## Document dynamic build targets
## --------------------------------------
##@ Builds
build-qemu-ubuntu-2204: ## Builds Ubuntu 22.04 QEMU image
build-qemu-ubuntu-2204-aarch64: ## Builds Ubuntu 22.04 arm QEMU image
build-qemu-rockylinux-9-uefi: ## Builds Rocky 8 UEFI QEMU image
build-qemu-rockylinux-9-uefi-aarch64: ## Builds Rocky 8 UEFI arm QEMU image
build-qemu-almalinux-9: ## Builds AlmaLinux 8 QEMU image
build-qemu-almalinux-9-aarch64: ## Builds AlmaLinux 8 arm QEMU image
build-qemu-amd64-all: $(QEMU_AMD64_BUILD_TARGETS) ## Builds all amd64 Qemu images
build-qemu-arm64-all: $(QEMU_ARM64_BUILD_TARGETS) ## Builds all arm64 Qemu images
build-qemu-all: $(QEMU_AMD64_BUILD_TARGETS) $(QEMU_ARM64_BUILD_TARGETS) ## Builds all Qemu images

## --------------------------------------
## Document dynamic validate targets
## --------------------------------------
##@ Validate packer config
validate-qemu-ubuntu-2204: ## Validates Ubuntu 22.04 QEMU image packer config
validate-qemu-ubuntu-2204-aarch64: ## Validates Ubuntu 22.04 QEMU image packer config
validate-qemu-rockylinux-9-uefi: ## Validates Rocky Linux 8 UEFI QEMU image packer config
validate-qemu-rockylinux-9-uefi-aarch64: ## Validates Rocky Linux 8 UEFI QEMU image packer config
validate-qemu-almalinux-9: ## Validates Alma Linux 8 QEMU image packer config
validate-qemu-almalinux-9-aarch64: ## Validates Alma Linux 8 QEMU image packer config
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

## --------------------------------------
## Docker targets
## --------------------------------------
##@ Docker

.PHONY: docker-pull-prerequisites
docker-pull-prerequisites:
	# We must pre-pull images https://github.com/moby/buildkit/issues/1271
	docker pull docker/dockerfile:1.1-experimental
	docker pull $(BASE_IMAGE)

.PHONY: docker-build
docker-build: docker-pull-prerequisites ## Build the docker image for controller-manager
	DOCKER_BUILDKIT=1 docker build --build-arg PASSED_IB_VERSION=$(IB_VERSION) --build-arg ARCH=$(ARCH) --build-arg BASE_IMAGE=$(BASE_IMAGE) . -t $(CONTROLLER_IMG)-$(ARCH):$(TAG)

.PHONY: docker-push
docker-push: ## Push the docker image
	docker push $(CONTROLLER_IMG)-$(ARCH):$(TAG)

## --------------------------------------
## Test targets
## --------------------------------------
##@ Testing

## --------------------------------------
## Release targets
## --------------------------------------
##@ Release

.PHONY: release-staging
release-staging: ## Builds and push container images to the staging bucket.
	TAG=$(IB_VERSION) REGISTRY=$(STAGING_REGISTRY) $(MAKE) docker-build docker-push

## --------------------------------------
## Sort JSON
## --------------------------------------
##@ Sort JSON

.PHONY: json-sort
json_files = $(shell find . -type f -name "*.json" | sort -u)
json-sort: ## Sort all JSON files alphabetically
	@for f in $(json_files); do (cat "$$f" | jq -S '.' >> "$$f".sorted && mv "$$f".sorted "$$f") || exit 1 ; done
