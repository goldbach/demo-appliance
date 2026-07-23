#!/bin/bash
# Converts a mkosi rootfs tar into a raw ext4 partition image.
# Usage: make-image.sh <rootfs.tar> <output.raw>
set -euo pipefail

SRC="${1:?missing rootfs tar}"
OUT="${2:?missing output path}"
SIZE="${IMAGE_SIZE_MB:-8192}"  # 8 GiB default; must fit in 10 GiB partition

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

IMG="$TMPDIR/rootfs.raw"
truncate -s "${SIZE}M" "$IMG"
mkfs.ext4 -L rootfs-a "$IMG"

MNT="$TMPDIR/mnt"
mkdir "$MNT"
mount -o loop "$IMG" "$MNT"
tar -xf "$SRC" -C "$MNT"
umount "$MNT"

e2fsck -f "$IMG" || true
resize2fs -M "$IMG"  # shrink to minimum

mv "$IMG" "$OUT"
zstd --rm -T0 -9 "$OUT"      # produces $OUT.zst
echo "Image: $OUT.zst"
