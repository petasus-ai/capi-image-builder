#!/bin/bash
# Release blocks that still hold deleted-file data so `qemu-img convert` can drop
# them from the shipped qcow2. The sysprep role does the deleting (apt/dnf caches,
# package lists, superseded kernels, logs, /tmp); on accelerator images the freeze
# role deletes package metadata again after it. Without a trim those blocks keep
# their stale contents, convert sees them as data, and compresses them in.
#
# Requires the drive to be attached with discard=unmap (packer `disk_discard`).
#
# Packer invokes this as `bash <path>`, so a `#!/bin/bash -x` shebang would be an
# inert comment -- tracing has to be `set -x`.
set -x

# On EL hosts sudoers' secure_path is /sbin:/bin:/usr/sbin:/usr/bin and fstrim
# lives in /usr/sbin. Set PATH explicitly rather than depend on a distro's policy.
PATH=/usr/sbin:/sbin:/usr/bin:/bin:$PATH
export PATH

# The guest's view of the drive's discard geometry, logged for diagnosis only.
# It cannot confirm that the reclaim works: qemu's scsi-hd advertises UNMAP to the
# guest whatever the backend's discard mode is, so DISC-GRAN/DISC-MAX read the same
# with discard=ignore, and the trim below then reports the same byte counts while
# qemu throws every request away. Only the built artifact's size shows the effect.
lsblk -D || true

sync

# -a skips filesystems that cannot discard rather than failing, so this degrades
# to a no-op on a guest where it does not apply. On UEFI targets it reports that
# the vfat /boot/efi does not support the operation; that is expected, not an
# error. The per-mount counts -v prints are free space this asked the device to
# release, NOT bytes saved in the artifact.
fstrim -av || true
