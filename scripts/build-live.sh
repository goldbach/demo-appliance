#!/bin/bash
# Builds the micro live rootfs tarball using mmdebstrap: the minimal
# environment that boots the installer ISO and runs installer-run.sh.
# The appliance payload (what lands on disk) is build-rootfs.sh — this one
# only needs to see the install disk and run the installer steps.
# Runs unprivileged via user namespaces (--mode=unshare).
#
# Usage: ./scripts/build-live.sh [output.tar.zst]
set -euo pipefail

BUILD="${BUILD:-build}"
ARCH="${ARCH:-$(dpkg --print-architecture)}"
OUTPUT="${1:-$BUILD/live-rootfs-$ARCH.tar.zst}"
SUITES="resolute"

# amd64 lives on archive.ubuntu.com; every other arch on ports.ubuntu.com
case "$ARCH" in
    amd64) MIRROR_URL="http://archive.ubuntu.com/ubuntu/" ;;
    arm64) MIRROR_URL="http://ports.ubuntu.com/ubuntu-ports/" ;;
    *) echo "[build-live] ERROR: unsupported ARCH '$ARCH' (amd64|arm64)" >&2; exit 1 ;;
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

log() { echo "[build-live] $*"; }

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
    --customize-hook='mkdir -p "$1/etc/systemd/network" && printf "[Match]\nName=en* eth*\n\n[Network]\nDHCP=yes\n" > "$1/etc/systemd/network/20-wired.network"' \
    --customize-hook='echo live-boot > "$1/etc/hostname"' \
    --customize-hook='mkdir -p "$1/usr/lib/appliance"' \
    --customize-hook='mkdir -p "$1/etc/systemd/system"' \
    --customize-hook='copy-in installer/installer-run.sh /usr/lib/appliance/' \
    --customize-hook='copy-in units/installer.service /etc/systemd/system/' \
    --customize-hook='chroot "$1" update-initramfs -u' \
    --customize-hook='chroot "$1" systemctl preset-all' \
    "$SUITES" "$OUTPUT" "$MIRROR"

log "Live rootfs tar: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
