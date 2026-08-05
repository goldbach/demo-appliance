#!/bin/bash
# Copies live/overlay/ into the live rootfs, preserving its path layout: a file
# at live/overlay/etc/hostname lands at /etc/hostname. Adding a file to the live
# env is a `git add`, not an edit to this script.
#
# Usage: 00-overlay.sh <rootfs-dir>   (run inside build-live.sh's fakeroot)
set -euo pipefail

ROOT="${1:?missing rootfs dir}"
OVERLAY="${OVERLAY:-live/overlay}"

log() { echo "[build-live:00-overlay] $*"; }

# --owner/--group force 0:0: the checkout's files belong to the build user, and
# that ownership must not reach the image (the uid-501 bug, commit 9b80098, and
# the comment block in scripts/make-image.sh). mmdebstrap's copy-in used to
# leave installer.service and installer-entrypoint.sh owned by the build user.
#
# --no-overwrite-dir preserves the mode and mtime of parent directories the
# overlay merely passes through (./etc, ./usr/lib, ...).
log "copying $OVERLAY -> $ROOT"
tar -C "$OVERLAY" --owner=0 --group=0 -cf - . | tar -C "$ROOT" --no-overwrite-dir -xf -
