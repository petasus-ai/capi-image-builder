# Cluster API Image Builder for Petasus

A fork of [kubernetes-sigs/image-builder](https://image-builder.sigs.k8s.io/capi/capi.html)
that builds the golden node images Petasus KaaS clusters boot from. Packer builds
a QEMU guest from an upstream cloud image, Ansible provisions it into a
kubeadm-ready node, and CI wraps the resulting qcow2 in a container-disk image and
publishes it together with an SBOM, a vulnerability report and a signed provenance
attestation.

Upstream's provider matrix (AWS, Azure, vSphere, OCI, …) is left in the tree but
unused: this fork builds the QEMU targets only.

## What It Builds

| Registry repository | Guest OS | Architectures |
|---|---|---|
| `quay.io/edgestack/ubuntu-2404-kube` | Ubuntu 24.04 | `amd64`, `aarch64` |
| `quay.io/edgestack/rocky-9-uefi-kube` | Rocky Linux 9 (UEFI) | `amd64`, `aarch64` |

**Tag grammar:** `v<major>.<minor>.<patch>[-<accelerator>]-<arch>`, where the
version is the Kubernetes version the image ships and the accelerator is `doca` or
`rebellions` when present. A tag without an architecture suffix is the multi-arch
manifest list built from the per-arch tags:

```
v1.36.3-amd64             plain, x86
v1.36.3-doca-aarch64      NVIDIA DOCA/OFED + CUDA, arm64
v1.36.3-rebellions-amd64  Rebellions ATOM driver, x86
v1.36.3                   manifest list over both architectures
```

Consumers of these tags — the Petasus catalog in particular — parse this grammar,
so a new variant token has to be agreed with them before it is published: unknown
tags are dropped from the catalog UI rather than rendered.

## Supported Operating Systems

**Host (build machine)**

* Rocky Linux. The firmware paths in `packer/config/*-args.json` are EL paths,
  and Packer's `qemu-system` handling is unreliable on Ubuntu hosts. CI runs on
  self-hosted Rocky runners.

**Guest**

* Ubuntu 24.04 (x86, ARM)
* Rocky Linux 9 (x86, ARM)

Base images are not pinned to a build date. The var files under `packer/qemu/`
point at the distros' latest channels — Ubuntu `releases/noble/release/`, Rocky
`GenericCloud-Base.latest` — and set `iso_checksum` to the upstream checksum
**file** rather than a literal hash, so Packer downloads the current image and
verifies it against what the distro published for that build. No edit is needed
when upstream cuts a new image.

## How to Use

**1. Install dependencies** (Ansible and Packer, both version-pinned)

```bash
make deps-qemu
```

**2. Build an image**

```bash
make build-qemu-ubuntu-2404             # Ubuntu 24.04, x86
make build-qemu-ubuntu-2404-aarch64     # Ubuntu 24.04, arm64
make build-qemu-rockylinux-9-uefi       # Rocky 9, x86
make build-qemu-rockylinux-9-uefi-aarch64
make build-qemu-amd64-all               # every x86 target
```

The artifact lands in `output/<build_name>-kube-<kubernetes-version>/`, alongside
the `components.json` the manifest role writes.

**3. Validate Packer configuration without building**

```bash
make validate-all
```

**4. Clean up**

```bash
make clean-qemu           # built images
make clean-packer-cache   # downloaded base images
```

Component versions come from the var files in `packer/config/` —
`kubernetes.json`, `containerd.json`, `cni.json` — which the Makefile passes to
every build. Override them with `PACKER_VAR_FILES` or `PACKER_FLAGS` rather than
editing the committed files.

## Build Pipeline

`ansible/node.yml` runs these roles in order:

```
setup*                repos, dist-upgrade, base packages
node                  sysctls, kernel modules, swap off, auditd
kernel                full upgrade + reboot into the newest kernel
providers                                    ← every kmod build below targets it
containerd
kubernetes            kubelet/kubeadm/kubectl; pre-pulls the control-plane images
load_additional_…     optional extra images and executables
<custom roles>        optional, via custom_role_names
cni
addons
security
customize
nvidia/doca           ┐
nvidia/cuda           │ accel_provider = nvidia
ddn, vast             ┘
rebellions              accel_provider = rebellions
manifest              collects the component inventory
sysprep               kernel cleanup, cache purge, machine-id and log reset
freeze                  accel_provider = nvidia; must stay last

* setup is a meta dependency of node, not a separate entry in node.yml
```

`manifest` runs second-to-last so every component is installed before it takes
inventory, and `sysprep` runs last because it starts removing the traces that
inventory reads.

Goss runs after Ansible as a Packer provisioner; its specs live in `packer/goss/`.

## Kernel Currency

The `kernel` role runs early — right after `node`, before every role that builds a
kernel module — and on **every** build, regardless of distro or whether an
accelerator was selected:

1. **Full system upgrade**, which installs the newest kernel the distro offers
   (`dnf upgrade` on EL, `apt full-upgrade` on Ubuntu — `full`, because a kernel
   ABI bump arrives as a *new* `linux-image-<abi>` package that a plain upgrade
   would never install).
2. **Reboot into it**, but only when the newest installed kernel differs from the
   running one, then re-gather facts so `ansible_kernel` reflects the kernel the
   image will actually boot.

The reboot is the point. Kernel packages are install-only: an upgrade lays the new
kernel down but leaves the old one running, while grub will default to the new
one. Without the reboot an image ships a kernel that its DOCA/OFED, NVIDIA, DDN
lustre, VAST and OVS datapath modules were never built against, and the roles that
pin headers to `ansible_kernel` pin them to the wrong version.

Two supporting changes make this work:

* The `setup` role no longer holds the kernel back. It used to `apt-mark hold` the
  `linux-image-virtual` meta packages and exclude `kernel*`/`kmod*` from the EL
  update, which is what kept images on their base image's kernel.
* Packer passes SSH keepalives to Ansible, so the provisioner's proxy connection
  survives the reboot.

**Superseded kernels are removed at sysprep.** Neither `apt autoremove` nor
`dnf autoremove` clears the previous kernel — on Ubuntu the base image's kernel is
marked manual, and on EL install-only packages are governed by `installonly_limit`
— so `sysprep/tasks/kernel_cleanup.yml` removes them explicitly, matching by ABI
so flavour-less packages of the running kernel (`linux-headers-6.8.0-136`)
survive. Beyond disk size, each retired kernel keeps generating its own CVE
matches — roughly 1,900 for one Ubuntu kernel — for a kernel the image will never
boot.

The cleanup asserts that the running kernel is the newest installed and refuses to
touch it, so a reboot that silently did not happen fails the build instead of
shipping a kernel/module mismatch.

All of this is build-time currency. On accelerator images the kernel that comes
out of it is then pinned for the life of the image — see [Upgrade Freeze](#upgrade-freeze).

## Accelerator Variants

`accel_provider` in `packer/config/common.json` selects the accelerator stack; the
variant workflows patch it before building. `nvidia` pulls in `nvidia/doca`,
`nvidia/cuda`, `ddn` and `vast`; `rebellions` pulls in the Rebellions driver role.

**DOCA-OFED is built through DKMS**, not by compiling the `mlnx-ofa_kernel` RPM
with `doca-kernel-support`. On kernels newer than NVIDIA's qualified list that
compile fails in `mlx5_dpll` — an unused SyncE clock-sync module broken by
backported `dpll_ffo_param` signatures — and takes the whole OFED build with it.
Now that the kernel role installs the newest distro kernel on every build, that is
the common case rather than the exception.

The role therefore installs the `doca-ofed` profile, prunes `mlx5_dpll` from the
DKMS source, deregisters the unused iser/isert/srp modules, and runs an explicit
`dkms autoinstall -k <running>` — a failed `%post` DKMS build does not fail the
rpm transaction, so that explicit pass is what actually produces the modules.
`dkms status` then gates the build, dumping `make.log` compile errors into the
Ansible output on failure.

## Upgrade Freeze

Accelerator images ship kernel modules built against the exact kernel they boot —
DOCA/OFED, the prebuilt Lustre client, the source-compiled VAST NFS client — and
sysprep has removed every other kernel, so there is no fallback boot entry if an
upgrade breaks the set. `rdma-core` and `libibverbs` make it worse: they also
exist in the distro repositories, where a routine OS patch would replace the
OFED-built copies with stock ones.

The `freeze` role bakes that policy into the image so a plain `apt upgrade` /
`dnf upgrade` on a running node cannot do by accident what only a rebuild is
supported to do on purpose:

* **Ubuntu** — an apt pin file at `Pin-Priority: -1`, which blocks new versions
  *and* new package names (the next kernel ABI arrives under a name that does not
  exist yet), plus `apt-mark hold` over the installed matches so the resolver
  cannot remove them either and `apt-mark showhold` shows operators what is
  frozen.
* **EL** — an `exclude=` list in `dnf.conf`.
* **Both** — a dry-run upgrade after pinning that fails the build if any frozen
  package still appears in the plan, catching a glob typo while a build is cheap.

It runs on `accel_provider=nvidia` images only, and it must stay the **last** role
in `ansible/node.yml`. Everything before it still moves packages — including
sysprep's kernel cleanup, which the freeze would veto, since apt refuses
unattended changes to held packages and `dnf exclude=` hides packages from
`remove` as well as from `upgrade`. Running last also means the hold list captures
the surviving kernel's packages rather than the ones cleanup is about to delete.

NVIDIA driver and CUDA packages are deliberately **not** pinned. This builder's
`nvidia/cuda` role only preps the node (nouveau off, build dependencies); the GPU
driver itself arrives at runtime through the GPU Operator, and pinning `nvidia-*`
would block that legitimate install. This is where the role diverges from
edgestack-image-builder's, which does ship a host driver.

The escape hatch is deliberate and explicit — remove the pin file or the exclude
line — so that lifting the freeze is a decision someone makes, not something an
unattended patch run does silently.

## Image Metadata Labels

Labels live on the arch-specific manifests; the multi-arch manifest list carries
none of its own.

**`ai.petasus.components`** — a JSON array of `{"name", "version"}` for a curated
set of components actually installed in the guest (kernel, Kubernetes, containerd,
runc, CNI plugins, DOCA OFED, NVIDIA driver, CUDA, DCGM, storage clients …). The
catalog lives in `ansible/roles/manifest/defaults/main.yml`; versions are read from
the guest's package database at build time, so bumping a component version needs
no catalog change. Consumers match on these names with vendor/role rules, so keep
them stable and use recognizable product names for new entries.

**`ai.petasus.disk`** — the disk geometry `scripts/disk-metadata.sh` measures with
`qemu-img`:

```json
{"virtualSizeBytes":42949672960,"virtualSizeGi":40,"minPvcSizeGi":43,
 "minPvcSize":"43Gi","filesystemOverhead":0.055}
```

CDI sizes a DataVolume against the disk's **virtual** size and, on a
filesystem-mode PVC, additionally reserves `CDIConfig.filesystemOverhead`, so the
request has to be strictly larger than the image. `minPvcSize` is the floor CDI
accepts, not a working VM size — cloud-init grows the root filesystem to fill the
volume, so anything sizing a long-lived VM should add its own headroom.

```bash
skopeo inspect docker://quay.io/edgestack/ubuntu-2404-kube:v1.36.3-amd64 \
  | jq -r '.Labels["ai.petasus.disk"]' | jq -r .minPvcSize
```

Labels are part of the image config, so they cannot be added to an already-pushed
tag without changing its manifest digest — which the SBOM, vulnerability and
signature mirrors are keyed by. Images built before a label existed cannot be
backfilled with it.

## Supply Chain

Three stages run after the image push, wired into every build job by the
`.github/actions/supply-chain` composite action. All three run **after** the push
and the manifest list update, so none of them can block publishing; each has a
`*_strict` workflow input controlling whether its failure fails the job.

The scripts are shared verbatim with
[edgestack-image-builder](https://github.com/petasus-ai/edgestack-image-builder) —
`scripts/supply-chain.conf` is the only file holding builder-specific values, so
fixes move between the two repositories with a plain diff. Keep it that way.

Portal documents go to the public mirror `petasus-ai/edgestack-image-sbom`, keyed
by the per-arch manifest digest:

```
<repository>/sha256-<digest-hex>.spdx.json        SBOM        (immutable)
<repository>/sha256-<digest-hex>.vuln.json        CVE report  (mutable)
<repository>/sha256-<digest-hex>.signature.json   signature   (immutable)
```

### SBOM

`scripts/sbom-pipeline.sh` mounts the qcow2 read-only with `guestmount`, scans it
with syft, attaches the SPDX 2.3 JSON to the image with `cosign attach sbom`, and
publishes a copy to the mirror. The guest is never modified — the qcow2 is hashed
before and after and the build fails if it changed.

* **Package-level only.** File cataloging is disabled and file entries are
  stripped, but package↔package relationships are deliberately preserved: grype
  uses syft's ownership relationships to recognise that a pip `cryptography` is
  owned by an OS `python3-cryptography` and collapse the duplicate. Publishing
  fails above 50 MB.
* **Cataloger selection.** `linux-kernel-cataloger` is off — it emits a synthetic
  `linux-kernel` package that duplicates what `linux-image-*`/`kernel-core`
  already describe, only fires on x86 (so the same image produced different SBOMs
  per architecture), and made grype match that one entry against the entire Linux
  CVE set. `python-package-cataloger` is off because it reads *declared*
  dependencies; installed Python packages are still catalogued.
* **`/var/lib/containerd` is excluded.** containerd's overlayfs snapshotter leaves
  every image `kubeadm config images pull` fetched extracted on disk, dpkg
  database included. Cataloguing those makes syft report nested packages as host
  packages, and grype then resolves them against the *host's* distro feed — a
  Debian bookworm `libc6` out of the registry.k8s.io images was reported as
  fixable by an Ubuntu `2.39-0ubuntuN` that no `apt upgrade` can ever apply.
  Scanning the pre-pulled images properly means scanning them *as images*, in
  their own distro context, which is a separate stage rather than a filter here.
* **No duplicate entries.** sysprep runs `apt-get clean`, not `autoclean`.
  autoclean keeps the archive of the version actually installed, and syft
  catalogued each of those a second time from the `.deb` — with a different purl
  from the dpkg-derived entry, so no consumer could merge the two.
* **Idempotency.** The stage is a no-op when the digest already has an SBOM;
  `SBOM_FORCE=true` bypasses that for manual repair.
* **Fallback.** libguestfs boots its appliance with a kernel from the local
  environment, so a guest filesystem newer than the runner's kernel fails
  host-side inspection. The pipeline retries the scan inside a Fedora container
  whose newer kernel backs the appliance, built once per runner.

### Vulnerability (CVE) Report

`scripts/vuln-pipeline.sh` scans the **published SBOM** with grype. Unlike the
SBOM this document is mutable — the same image gains CVEs as advisories are
published — so it is overwritten whenever it is re-scanned with a newer grype DB.

Three classifications are added on top of grype's output, all there to stop the
report demanding fixes that cannot be performed:

* **`fix.availableInDistro` / `fix.distroLatest`** (`scripts/distro-fix-check.sh`).
  grype has no Rocky feed and matches EL clones against RHEL's. That is right
  about whether a CVE applies but wrong about the fix being available: Rocky
  rebuilds Red Hat's errata days-to-weeks later, so a fully upgraded Rocky image
  shows fixes that exist in no Rocky repository. The check reads the distro's own
  package index and reports the newest version it actually publishes.
* **`artifact.vendored`** — a package whose every location sits under a `_vendor/`
  directory is a copy bundled inside another package, not an install of its own.
  `jaraco.context` and `wheel` under
  `/usr/lib/python3/dist-packages/setuptools/_vendor/` were reported as actionable
  High findings although apt has no such packages to upgrade.
* **`artifact.frozen`** — a package covered by the upgrade freeze. On a frozen
  image these are fixed by rebuilding the image, not by patching the node, and
  the report says so rather than pointing at an upgrade the pins will refuse. A
  frozen image is recognised from its own SBOM via `FREEZE_MARKER_REGEX`, and the
  covered names come from `FREEZE_PKG_REGEX`; both live in `supply-chain.conf`
  and must be kept in step with the glob lists in `roles/freeze/defaults/main.yml`.

### Provenance & Signing

`scripts/provenance-pipeline.sh` signs the pushed image with cosign (keyless, via
the workflow's OIDC token), attaches a SLSA v1 provenance attestation, and
publishes a field-whitelisted signature summary to the mirror.

The attestation itself is never mirrored: its `builder.id` is the workflow URI,
which names the private builder repository. Publishing it verbatim would
contradict the redaction policy, and publishing a modified copy would make the
mirror differ from the document that was actually signed — indistinguishable from
tampering on a page whose purpose is trust. It stays in the registry, complete and
unmodified, where `cosign verify-attestation` reads it.

Per-arch digests only. A manifest index is refused: its digest changes whenever
either architecture is rebuilt with `docker manifest create --amend`, so an index
signature would go stale immediately.

### Tooling

syft, grype and cosign are version-pinned in their scripts and verified at run
time, so a runner's preinstalled binary cannot change the output. cosign stays on
the 2.x line because the portal contract relies on `attach sbom` / `download sbom`,
deprecated in 3.x. Runners additionally need `libguestfs-tools`, `skopeo`, `jq`
and `docker`.

## CI Workflows

The build workflows run on self-hosted Linux runners (x64 and arm64) and are
triggered either by `workflow_dispatch` or by pushing a `v*.*.*` tag, in which
case the tag name is the Kubernetes version to build.

| Workflow | Builds |
|---|---|
| `main.yaml` | plain images, both distros and architectures |
| `doca_image.yaml` | `-doca` variants (`accel_provider=nvidia`) |
| `rebellions.yaml` | `-rebellions` variants |
| `auto-kube-release.yaml` | nothing — daily detector that dispatches the two build workflows when upstream publishes a Kubernetes patch we have not built (`scripts/pending-kube-builds.py`) |
| `auto-remediate.yaml` | nothing — daily detector that dispatches rebuilds for images whose readiness grade a rebuild would restore (see below) |
| `check-sigstore-egress.yaml` | pre-flight: can the runners reach Fulcio, Rekor and the TUF CDN? Read-only, credential-free, no signing |

Each build job produces the qcow2, wraps it in an Alpine-based container-disk
image carrying the labels described above, pushes the per-arch tag, amends the
multi-arch manifest list, and then runs the supply-chain action.

### Auto-Remediation (rebuild-to-patch)

`auto-remediate.yaml` (daily, after the SBOM mirror's re-scan) runs
`scripts/auto-remediate.sh` — the security twin of `auto-kube-release.yaml`:
that one rebuilds because upstream Kubernetes moved, this one rebuilds because
the distro shipped a security fix the image lacks. It grades the **newest
patch of every published series** (per distro and flavour; older patches stay
published but are not what operators deploy) with `scripts/grade.mjs` and
dispatches `main.yaml` / `doca_image.yaml` for combos with actionable
Critical/High findings. Since the vulnerability pipeline reports
`fix.availableInDistro`, those are by construction findings whose fix the
distro really publishes — a rebuild is guaranteed to clear them, republish the
tags, and stand the loop down.

`grade.mjs` is a **vendored, dependency-free copy of the catalog portal's
grading formula** (`petasus-image-catalog`: `vuln.ts` fold/track +
`readiness.ts` ladders + `grade-summary.ts` projection), shared byte-identical
with edgestack-image-builder. A portal change to the formula must be mirrored
into both copies, bumping `GRADE_FORMULA_VERSION` everywhere; verify a sync by
diffing the CLIs' output on the same reports.

Safety rails: at most `MAX_DISPATCH` (4) dispatches per run, a 72h per-combo
cooldown (`.github/auto-remediate-state.json`, committed by the workflow), and
a per-workflow busy hold snapshotted before dispatching — same pattern as
`auto-kube-release.yaml`. `-cilium` tags never match (that branch owns its own
schedule) and `EXCLUDE_KEY_REGEX` can retire combos from the loop.

**Ships in dry-run**: it only maintains the `auto-remediate` tracking issue
(closed automatically when everything grades clean). Go live by setting the
repository variable `AUTO_REMEDIATE_DRY_RUN=false`; set it back to `true` to
pause. No secrets beyond the built-in `GITHUB_TOKEN`.

## Repository Layout

```
ansible/            provisioning roles; node.yml is the entry point
packer/qemu/        per-target Packer var files + packer.json
packer/config/      component versions shared by every build
packer/goss/        post-build test specs
scripts/            supply-chain pipelines and CI helpers
hack/               dependency bootstrapping
.github/            build workflows and the supply-chain composite action
```

`README-flatcar.md` documents the inherited Flatcar path, which this fork does not
build.
