#!/bin/bash
# Install step: write /etc/fstab for the installed system, describing the
# filesystems 10-partition.sh created and 20-rootfs.sh mounted.
set -euo pipefail

log() { echo "[install:fstab] $*"; }

log "Writing /etc/fstab..."
# root stays rw for now: firstboot, ssh host keys, timesync etc. need writable
# /etc and /var. ro root comes back with the A/B work, together with the
# writable-path plumbing (/data-backed overlays) it requires.
EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")
ROOT_UUID=$(blkid -s UUID -o value "$ROOTFS_A")
DATA_UUID=$(blkid -s UUID -o value "$DATA_PART")
cat > "$TARGET/etc/fstab" <<EOF
UUID=$EFI_UUID   /boot/efi  vfat  umask=0077                    0 1
UUID=$ROOT_UUID  /          ext4  defaults                       0 1
UUID=$DATA_UUID  /data      ext4  defaults,x-systemd.makefs      0 2
EOF
