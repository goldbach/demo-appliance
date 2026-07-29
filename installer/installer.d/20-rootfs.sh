#!/bin/bash
# Install step: write the rootfs image to slot A, grow it to fill the slot,
# and mount the target system at /mnt.
set -euo pipefail

log() { echo "[install:rootfs] $*"; }

log "Writing rootfs image to $ROOTFS_A (this takes a few minutes)..."
zstd -dc "$ROOTFS_IMAGE" | dd of="$ROOTFS_A" bs=4M conv=fsync status=progress

# The image is shrunk to minimum size — grow it to fill the 10 GiB slot
e2fsck -fy "$ROOTFS_A"
resize2fs "$ROOTFS_A"

log "Mounting target rootfs..."
mount "$ROOTFS_A" /mnt

mkdir -p /mnt/boot/efi
mount "$EFI_PART" /mnt/boot/efi
mount --bind /dev  /mnt/dev
mount --bind /proc /mnt/proc
mount --bind /sys  /mnt/sys
mount --bind /sys/firmware/efi/efivars /mnt/sys/firmware/efi/efivars 2>/dev/null || true
