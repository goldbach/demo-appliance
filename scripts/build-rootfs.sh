#!/bin/bash
# Builds the Appliance payload rootfs tarball: the full node OS that install.sh
# writes to disk and systemd-sysupdate later writes on A/B updates.
#
# This is the *customization* layer. It takes the base tarball built by
# build-base-rootfs.sh (stock Ubuntu + vendored binaries), applies everything
# that makes it an appliance, and repacks. No apt, no network — editing a unit
# file or the admin user costs seconds here instead of a full mmdebstrap.
#
# Customization comes from two places, in this order:
#   rootfs/overlay/    a file tree mirroring the target layout, copied in as-is
#   rootfs/rootfs.d/   numbered scripts, run in glob order, each given the
#                      rootfs directory as $1 (same signature as an mmdebstrap
#                      --customize-hook, so steps can move between layers)
#
# Runs unprivileged under a single fakeroot session — the same idiom as
# make-image.sh and make-iso.sh, and for the same reason: extraction, the
# customization steps, and the repack must all see one fake-ownership database,
# or root-owned files silently collapse to the build user (the uid-501 bug,
# commit 9b80098). Two fakeroot invocations would each start an empty one.
#
# Steps must therefore never chroot: fakeroot cannot follow them in. Use the
# --prefix/--root flags that shadow-utils and systemctl provide instead. This
# is also what lets an amd64 payload be customized on an arm64 builder without
# involving Rosetta binfmt at all.
#
# Usage: ./scripts/build-rootfs.sh [output.tar.zst]
set -euo pipefail

# Set once we have re-executed ourselves inside the fakeroot session.
INNER=0
if [ "${1:-}" = "--inner" ]; then
    INNER=1
    shift
fi

BUILD="${BUILD:-build}"
ARCH="${ARCH:-$(dpkg --print-architecture)}"
BASE="${BASE_TAR:-$BUILD/base-rootfs-$ARCH.tar.zst}"
OUTPUT="${1:-$BUILD/appliance-rootfs-$ARCH.tar.zst}"

OVERLAY="${OVERLAY:-rootfs/overlay}"
STEPS_DIR="${STEPS_DIR:-rootfs/rootfs.d}"
# Steps read these from the environment (05-vendor.sh needs ARCH to find the
# right vendor/ subdir), matching the installer.d/firstboot.d convention.
export OVERLAY ARCH

# Baked-in admin account, consumed by rootfs.d/10-admin-user.sh. Same
# credentials on every box built with these values — fine for the demo phase,
# see TODO "Baked-in admin user".
ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-appliance}"
export ADMIN_USERNAME ADMIN_PASSWORD

# The payload tar is an intermediate: make-image.sh decompresses it immediately
# and re-compresses the finished ext4 image at -9. Only that image ships on the
# ISO, so spending time compressing this one buys nothing.
ZSTD_LEVEL="${ZSTD_LEVEL:-1}"

log() { echo "[build-rootfs] $*"; }

export TMPDIR="${TMPDIR:-/var/tmp}"

if [ "$INNER" = 0 ]; then
    [ -f "$BASE" ] || { log "ERROR: missing base rootfs $BASE (run 'make base')"; exit 1; }
    [ -d "$OVERLAY" ] || { log "ERROR: missing overlay dir $OVERLAY"; exit 1; }
    mkdir -p "$BUILD"

    log "entering fakeroot"
    exec fakeroot -- "$0" --inner "$OUTPUT"
fi

# --- Everything below runs inside the fakeroot session ---

WORK=$(mktemp -d "$TMPDIR/build-rootfs.XXXXXX")
ROOT="$WORK/rootfs"
mkdir -p "$ROOT"
trap 'rm -rf "$WORK"' EXIT

# /dev round-trips intact: fakeroot fakes the mknod on the way in and re-emits
# the device nodes on the way out, so the payload tar keeps the same 8 char
# devices mmdebstrap put in the base.
log "extracting $BASE"
tar -C "$ROOT" -xf "$BASE"

shopt -s nullglob
for step in "$STEPS_DIR"/*.sh; do
    log "run $step"
    "$step" "$ROOT"
done
shopt -u nullglob

# --numeric-owner: store ids, not names. The build host's /etc/passwd has no
# bearing on the target's, and downstream make-image.sh extracts with a plain
# `tar -xf` that would otherwise re-resolve names against the host.
log "packing $OUTPUT"
tar -C "$ROOT" --numeric-owner -cf - . | zstd -T0 -"$ZSTD_LEVEL" -f -o "$OUTPUT"

log "Rootfs tar: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
