#!/bin/bash
# Builds the micro live rootfs tarball: the minimal environment that boots the
# installer ISO and runs installer-entrypoint.sh.
#
# This is the *customization* layer. It takes the base tarball built by
# build-live-base.sh (Ubuntu + kernel + live-boot) and applies everything that
# makes it the installer environment. No apt, no network — editing the
# installer entry point or its unit costs seconds here instead of a full
# mmdebstrap.
#
# Customization comes from two places, in this order:
#   live/overlay/        a file tree mirroring the target layout, copied in
#                        as-is
#   live/build-live.d/   numbered scripts, run in glob order, each given the
#                        rootfs directory as $1 (same signature as an mmdebstrap
#                        --customize-hook, so steps can move between layers)
#
# Runs unprivileged under a single fakeroot session — the same idiom as
# build-rootfs.sh, make-image.sh and make-iso.sh, and for the same reason:
# extraction, the customization steps, and the repack all share one
# fake-ownership database, which is what keeps root-owned files root-owned (the
# uid-501 bug, commit 9b80098). Each fakeroot invocation starts that database
# empty, hence one.
#
# Steps therefore stay inside that session, using the --prefix/--root flags
# shadow-utils and systemctl provide (fakeroot cannot follow a chroot).
#
# The appliance payload (what lands on disk) is build-rootfs.sh — this one only
# needs to see the install disk and run the installer steps.
#
# Usage: ./scripts/build-live.sh [output.tar.zst]
set -euo pipefail

# Set once we have re-executed ourselves inside the fakeroot session.
INNER=0
if [ "${1:-}" = "--inner" ]; then
    INNER=1
    shift
fi

BUILD="${BUILD:-build}"
ARCH="${ARCH:-$(dpkg --print-architecture)}"
BASE="${LIVE_BASE_TAR:-$BUILD/live-base-rootfs-$ARCH.tar.zst}"
OUTPUT="${1:-$BUILD/live-rootfs-$ARCH.tar.zst}"

OVERLAY="${OVERLAY:-live/overlay}"
STEPS_DIR="${STEPS_DIR:-live/build-live.d}"
export OVERLAY ARCH

# The live tar is an intermediate: make-iso.sh extracts it immediately, pulls
# the kernel/initrd/shim/grub out of it and squashes the rest at zstd -9. Only
# that squashfs ships on the ISO, so compressing this one hard buys nothing.
ZSTD_LEVEL="${ZSTD_LEVEL:-1}"

log() { echo "[build-live] $*"; }

export TMPDIR="${TMPDIR:-/var/tmp}"

if [ "$INNER" = 0 ]; then
    [ -f "$BASE" ] || { log "ERROR: missing live base rootfs $BASE (run 'make live-base')"; exit 1; }
    [ -d "$OVERLAY" ] || { log "ERROR: missing overlay dir $OVERLAY"; exit 1; }
    mkdir -p "$BUILD"

    log "entering fakeroot"
    exec fakeroot -- "$0" --inner "$OUTPUT"
fi

# --- Everything below runs inside the fakeroot session ---

WORK=$(mktemp -d "$TMPDIR/build-live.XXXXXX")
ROOT="$WORK/rootfs"
mkdir -p "$ROOT"
trap 'rm -rf "$WORK"' EXIT

# /dev round-trips intact: fakeroot fakes the mknod on the way in and re-emits
# the device nodes on the way out.
log "extracting $BASE"
tar -C "$ROOT" -xf "$BASE"

shopt -s nullglob
for step in "$STEPS_DIR"/*.sh; do
    log "run $step"
    "$step" "$ROOT"
done
shopt -u nullglob

# --numeric-owner records ids rather than names, so the ids survive intact
# through make-iso.sh's plain `tar -xf`, independent of the build host's
# /etc/passwd.
log "packing $OUTPUT"
tar -C "$ROOT" --numeric-owner -cf - . | zstd -T0 -"$ZSTD_LEVEL" -f -o "$OUTPUT"

log "Live rootfs tar: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
