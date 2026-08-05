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
SUITE="${SUITE:?set SUITE (exported by the Makefile)}"
MIRROR_URL="${MIRROR_URL:?set MIRROR_URL (exported by the Makefile)}"
# multiverse is deliberately absent: it carries software Ubuntu may not
# freely redistribute, and these images ship to customers. Leaving it out turns
# "a dependency quietly pulled something non-redistributable in" into a build
# failure at the moment it happens.
MIRROR="deb $MIRROR_URL $SUITE main restricted universe"

PACKAGES=(
    # kernel / live boot. linux-firmware-minimal satisfies linux-image-generic's
    # "linux-firmware | linux-firmware-minimal" dependency: the installer only
    # needs to see disk + NIC, not GPU/wifi/bt firmware (~800 MB saved).
    linux-image-generic linux-firmware-minimal initramfs-tools live-boot live-boot-initramfs-tools
    # init / system
    systemd systemd-resolved systemd-sysv udev dbus
    # installer: partition, format, write rootfs image
    parted dosfstools e2fsprogs zstd
    # A/B updates: `rauc install` writes a signed bundle into a slot.
    # rauc-service carries the systemd unit and D-Bus policy — the CLI is a
    # D-Bus client that drives that daemon, so both halves are needed.
    rauc rauc-service
    # signed boot binaries — make-iso.sh extracts shim/grub/kernel/initrd
    # from this tarball; grub is never run inside the live env itself
    "grub-efi-${ARCH}-signed" shim-signed
    # minimal ops: ps/free/sysctl
    procps
)

log() { echo "[build-live-base] $*"; }

export TMPDIR="${TMPDIR:-/var/tmp}"
mkdir -p "$BUILD"

log "Suite:  $SUITE ($ARCH)"
log "Mirror: $MIRROR_URL"

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
    "$SUITE" "$OUTPUT" "$MIRROR"

log "Live base rootfs tar: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
