#!/bin/bash
# Converts a rootfs tar into a raw ext4 partition image.
# Uses mke2fs -d to populate without mounting (no root/losetup needed).
# Usage: make-image.sh <rootfs.tar[.zst]> <output.raw>
set -euo pipefail

SRC="${1:?missing rootfs tar}"
OUT="${2:?missing output path}"
SIZE="${IMAGE_SIZE_MB:-8192}"  # 8 GiB default; must fit in 10 GiB partition

TMPDIR=$(mktemp -d "${TMPDIR:-/var/tmp}/make-image.XXXXXX")
trap 'rm -rf "$TMPDIR"' EXIT

# Extract tar to a subdirectory (image file goes outside to avoid circular copy)
ROOTFS_DIR="$TMPDIR/rootfs"
mkdir "$ROOTFS_DIR"
echo "Extracting rootfs..."
tar -xf "$SRC" -C "$ROOTFS_DIR" --exclude='./dev/*'

# Create ext4 image and populate from directory (no mount needed)
IMG="$TMPDIR/rootfs.raw"
echo "Creating ext4 image..."
truncate -s "${SIZE}M" "$IMG"
mkfs.ext4 -L rootfs-a -d "$ROOTFS_DIR" "$IMG"

e2fsck -f "$IMG" || true
resize2fs -M "$IMG"  # shrink to minimum

mv "$IMG" "$OUT"
zstd --rm -f -T0 -9 "$OUT"   # produces $OUT.zst
echo "Image: $OUT.zst"
