#!/bin/bash
# Install step: remove live-environment and installer leftovers from the
# target.
set -euo pipefail

log() { echo "[install:cleanup] $*"; }

# live-boot only serves the installer medium; purging it also regenerates
# the initrd without live hooks. The installer scripts go too — installed
# nodes should not carry a disk-wiping entry point. Disk tools (parted,
# efibootmgr, ...) stay: useful for node maintenance and sysupdate.
log "Removing live-environment and installer leftovers..."
chroot /mnt apt-get purge -y live-boot live-boot-initramfs-tools
rm -f /mnt/etc/systemd/system/installer.service \
      /mnt/etc/systemd/system/multi-user.target.wants/installer.service \
      /mnt/usr/lib/appliance/installer-run.sh \
      /mnt/usr/lib/appliance/install.sh
rm -rf /mnt/usr/lib/appliance/installer.d
