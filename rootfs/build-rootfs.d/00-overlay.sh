#!/bin/bash
# Copies rootfs/overlay/ into the rootfs, preserving its path layout: a file at
# rootfs/overlay/etc/hostname lands at /etc/hostname. Adding a file to the image
# is a `git add`, not an edit to this script.
#
# Usage: 00-overlay.sh <rootfs-dir>   (run inside build-rootfs.sh's fakeroot)
set -euo pipefail

ROOT="${1:?missing rootfs dir}"
OVERLAY="${OVERLAY:-rootfs/overlay}"

log() { echo "[00-overlay] $*"; }

# --owner/--group force 0:0: the checkout's files belong to the build user, and
# that ownership must not reach the image (the uid-501 bug, commit 9b80098, and
# the comment block in scripts/make-image.sh).
#
# --no-overwrite-dir preserves the mode and mtime of parent directories the
# overlay merely passes through (./etc, ./usr/lib, ...).
log "copying $OVERLAY -> $ROOT"
tar -C "$OVERLAY" --owner=0 --group=0 -cf - . | tar -C "$ROOT" --no-overwrite-dir -xf -

# git cannot track empty directories, so /data is created here rather than
# living in the overlay — it is the mountpoint for the data partition
# (see installer.d/50-config.sh). Explicit -m holds it at 0755 regardless of
# the build user's umask.
log "creating empty dirs"
install -d -m 0755 "$ROOT/data"
