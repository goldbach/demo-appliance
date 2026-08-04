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

# tar --owner/--group instead of `cp -a`: the checkout's files belong to the
# build user, and `cp -a` would faithfully preserve that ownership into the
# image — the uid-501 bug (commit 9b80098, and the comment block in
# scripts/make-image.sh). Forcing 0:0 here makes the result independent of who
# ran the build.
#
# --no-overwrite-dir: the overlay necessarily carries parent directories it does
# not own (./etc, ./usr/lib, ...). Without this, their mode and mtime in the
# image would be whatever the git checkout happens to have.
log "copying $OVERLAY -> $ROOT"
tar -C "$OVERLAY" --owner=0 --group=0 -cf - . | tar -C "$ROOT" --no-overwrite-dir -xf -

# git cannot track empty directories, so these can't live in the overlay — a
# .gitkeep placeholder would be copied into the image along with everything else.
#   /data              mountpoint for the data partition (see installer.d/50-config.sh)
#   /usr/lib/appliance where install.sh drops firstboot.sh + firstboot.d/
# Explicit -m: mkdir would otherwise apply the build user's umask (0002 on
# Ubuntu), giving group-writable system directories.
log "creating empty dirs"
install -d -m 0755 "$ROOT/data" "$ROOT/usr/lib/appliance"
