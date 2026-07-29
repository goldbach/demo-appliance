#!/bin/bash
# Install step: partition the target disk and format EFI, rootfs-b and data.
# rootfs-a is not formatted — the image written by 20-rootfs.sh carries the
# filesystem (with its neutral "rootfs" fs label; slot identity is the GPT
# partition label). rootfs-b gets no image at install time; it is formatted
# to clear stale bytes from the disk's former life (mklabel rewrites the
# partition table, not partition contents — an unformatted slot B could show
# up in blkid with a duplicate UUID/label from a previous install).
set -euo pipefail

# Sizes in MiB
EFI_SIZE=512
ROOTFS_SIZE=10240   # 10 GiB per A/B slot

log() { echo "[install:partition] $*"; }

log "Partitioning $DISK..."

parted -s "$DISK" \
    mklabel gpt \
    mkpart EFI      fat32  1MiB                                     $((1 + EFI_SIZE))MiB \
    mkpart rootfs-a ext4   $((1 + EFI_SIZE))MiB                     $((1 + EFI_SIZE + ROOTFS_SIZE))MiB \
    mkpart rootfs-b ext4   $((1 + EFI_SIZE + ROOTFS_SIZE))MiB       $((1 + EFI_SIZE + ROOTFS_SIZE * 2))MiB \
    mkpart data     ext4   $((1 + EFI_SIZE + ROOTFS_SIZE * 2))MiB   100% \
    set 1 esp on

# Let udev settle
udevadm settle --timeout=10

log "Formatting..."
mkfs.fat  -F32 -n EFI      "$EFI_PART"
mkfs.ext4 -L   rootfs-b    "$ROOTFS_B"
mkfs.ext4 -L   data        "$DATA_PART"
