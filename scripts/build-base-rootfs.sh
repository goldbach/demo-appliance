#!/bin/bash
# Builds the appliance base rootfs tarball using mmdebstrap: stock Ubuntu and
# nothing else. This is the slow, network-bound half of the payload build — everything
# that makes it an *appliance* (vendored binaries, units, hostname, admin user,
# presets) is applied on top by build-rootfs.sh, which needs no network and
# runs in seconds.
#
# Rebuild this only when the package list or the dpkg excludes change — a
# K3S_VERSION bump stays in the customization layer, where
# rootfs/build-rootfs.d/05-vendor.sh installs the k3s binary.
# The installer/live environment is a separate pair of builds — see
# build-live-base.sh and build-live.sh.
# Runs unprivileged via user namespaces (--mode=unshare).
# The .tar.zst extension makes mmdebstrap emit a zstd-compressed tarball;
# downstream tar -x/-t auto-detect the compression.
#
# Usage: ./scripts/build-base-rootfs.sh [output.tar.zst]
set -euo pipefail

BUILD="${BUILD:-build}"
ARCH="${ARCH:-$(dpkg --print-architecture)}"
OUTPUT="${1:-$BUILD/appliance-base-rootfs-$ARCH.tar.zst}"
SUITE="${SUITE:?set SUITE (exported by the Makefile)}"
MIRROR_URL="${MIRROR_URL:?set MIRROR_URL (exported by the Makefile)}"
# multiverse is deliberately absent: it carries software Ubuntu may not
# freely redistribute, and these images ship to customers. Leaving it out turns
# "a dependency quietly pulled something non-redistributable in" into a build
# failure at the moment it happens.
MIRROR="deb $MIRROR_URL $SUITE main restricted universe"

PACKAGES=(
    # kernel / boot
    linux-image-generic initramfs-tools
    # init / system
    systemd systemd-resolved systemd-sysv systemd-timesyncd udev dbus
    # certs (k3s pulls images over TLS)
    ca-certificates
    # ssh
    openssh-server
    # k3s host deps: netlink tools, kube-proxy iptables/conntrack, modprobe
    iproute2 iptables conntrack kmod
    # node maintenance: partition, format, EFI boot entry, A/B update images
    parted dosfstools e2fsprogs efibootmgr zstd
    # bootloader (Secure Boot); install runs grub-install chrooted, so the
    # binaries must live in the payload, not the live env
    "grub-efi-${ARCH}-signed" shim-signed
    # minimal ops: ps/free/sysctl
    procps
    # runtime deps:
    jq curl ansible skopeo
    # admin account (created by build-rootfs.d/10-admin-user.sh)
    sudo
)

log() { echo "[build-base-rootfs] $*"; }

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

log "Base rootfs tar: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
