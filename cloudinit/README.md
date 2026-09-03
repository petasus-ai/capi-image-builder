# Cloud-init Seed

`packer.init` is the `cidata` ISO the QEMU builder attaches as a CD-ROM
(`cloud_init_image` in `packer/qemu/packer.json`). It sets the `builder`
account's password and enables password SSH, which is how Packer's communicator
gets its first connection into an unmodified upstream cloud image. Packer's
`shutdown_command` locks that account again before the image is captured.

`user-data` and `meta-data` are what the ISO is built from. After editing
either, rebuild it and commit the result:

```bash
cd cloudinit
genisoimage -output packer.init -volid cidata -joliet -rock user-data meta-data
```
