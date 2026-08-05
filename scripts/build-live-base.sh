#!/bin/bash
# Builds the live base rootfs tarball using mmdebstrap: stock Ubuntu plus the
# kernel and live-boot tooling, and nothing installer-specific. This is the
# slow, network-bound half of the live build — the installer entry point, its
# unit and the network/hostname config are applied on top by build-live.sh,
# which needs no network and runs in seconds.
#
# Rebuild this only when the package list or the dpkg excludes change.
# The appliance payload (what lands on disk) is a separate pair of builds —
# see build-base-rootfs.sh and build-rootfs.sh.
# Runs unprivileged via user namespaces (--mode=unshare).
#
# Usage: ./scripts/build-live-base.sh [output.tar.zst]
set -euo pipefail

BUILD="${BUILD:-build}"
ARCH="${ARCH:-$(dpkg --print-architecture)}"
OUTPUT="${1:-$BUILD/live-base-rootfs-$ARCH.tar.zst}"
SUITES="resolute"

# amd64 lives on archive.ubuntu.com; every other arch on ports.ubuntu.com
case "$ARCH" in
    amd64) MIRROR_URL="http://archive.ubuntu.com/ubuntu/" ;;
    arm64) MIRROR_URL="http://ports.ubuntu.com/ubuntu-ports/" ;;
    *) echo "[build-live-base] ERROR: unsupported ARCH '$ARCH' (amd64|arm64)" >&2; exit 1 ;;
esac
MIRROR="deb $MIRROR_URL $SUITES main restricted universe multiverse"

PACKAGES=(
    # kernel / live boot. linux-firmware-minimal satisfies linux-image-generic's
    # "linux-firmware | linux-firmware-minimal" dependency: the installer only
    # needs to see disk + NIC, not GPU/wifi/bt firmware (~800 MB saved).
    linux-image-generic linux-firmware-minimal initramfs-tools live-boot live-boot-initramfs-tools
    # init / system
    systemd systemd-resolved systemd-sysv udev dbus
    # installer: partition, format, write rootfs image
    parted dosfstools e2fsprogs zstd
    # signed boot binaries — make-iso.sh extracts shim/grub/kernel/initrd
    # from this tarball; grub is never run inside the live env itself
    "grub-efi-${ARCH}-signed" shim-signed
    # minimal ops: ps/free/sysctl
    procps
)

log() { echo "[build-live-base] $*"; }

export TMPDIR="${TMPDIR:-/var/tmp}"
mkdir -p "$BUILD"

# shellcheck disable=SC2016
mmdebstrap \
    --mode=unshare \
    --skip=check/qemu \
    --variant=minbase \
    --architectures="$ARCH" \
    --include="${PACKAGES[*]}" \
    --dpkgopt='path-exclude=/usr/share/man/*' \
    --dpkgopt='path-exclude=/usr/share/locale/*' \
    --dpkgopt='path-include=/usr/share/locale/locale.alias' \
    --dpkgopt='path-exclude=/usr/share/doc/*' \
    --customize-hook='chroot "$1" update-initramfs -u' \
    "$SUITES" "$OUTPUT" "$MIRROR"

log "Live base rootfs tar: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
