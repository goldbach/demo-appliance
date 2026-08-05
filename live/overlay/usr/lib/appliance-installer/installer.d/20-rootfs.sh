#!/bin/bash
# Install step: write the rootfs image to slot A, grow it to fill the slot,
# and mount the target system at $TARGET.
set -euo pipefail

log() { echo "[install:rootfs] $*"; }

log "Writing rootfs image to $ROOTFS_A (this takes a few minutes)..."
zstd -dc "$ROOTFS_IMAGE" | dd of="$ROOTFS_A" bs=4M conv=fsync status=progress

# The image is shrunk to minimum size — grow it to fill the 10 GiB slot
e2fsck -fy "$ROOTFS_A"
resize2fs "$ROOTFS_A"

log "Mounting target rootfs..."
mkdir -p "$TARGET"
mount "$ROOTFS_A" "$TARGET"

mkdir -p "$TARGET/boot/efi"
mount "$EFI_PART" "$TARGET/boot/efi"
mount --bind /dev  "$TARGET/dev"
mount --bind /proc "$TARGET/proc"
mount --bind /sys  "$TARGET/sys"
mount --bind /sys/firmware/efi/efivars "$TARGET/sys/firmware/efi/efivars" 2>/dev/null || true
