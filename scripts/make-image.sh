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

# Create ext4 image and populate from directory (no mount needed)
# Neutral fs label: the same image lands in slot A at install time and in
# slot B via sysupdate — slot identity lives in the GPT partition labels
# (rootfs-a / rootfs-b), not in the filesystem.
IMG="$TMPDIR/rootfs.raw"
truncate -s "${SIZE}M" "$IMG"

# The tarball correctly records root-owned files (mmdebstrap's unprivileged
# --mode=unshare build maps its user namespace back to real uid 0 in the
# tar), but a plain unprivileged `tar -x` here can't chown to uid 0 and
# silently extracts everything as the calling user instead — and mke2fs -d
# then bakes THAT wrong ownership into the image (e.g. /etc/sudoers ends up
# owned by the build user, and sudo on the installed appliance refuses to
# run). Both commands must run in the same fakeroot session so the faked
# ownership from the extraction is still in effect when mke2fs stats the
# directory — two separate `fakeroot` invocations would each start a fresh,
# empty fake-ownership database.
echo "Extracting rootfs..."
fakeroot -- bash -c '
    set -euo pipefail
    tar -xf "$1" -C "$2" --exclude="./dev/*"
    mkfs.ext4 -L rootfs -d "$2" "$3"
' _ "$SRC" "$ROOTFS_DIR" "$IMG"

e2fsck -f "$IMG" || true
resize2fs -M "$IMG"  # shrink to minimum

mv "$IMG" "$OUT"
zstd --rm -f -T0 -9 "$OUT"   # produces $OUT.zst
echo "Image: $OUT.zst"
