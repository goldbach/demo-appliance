#!/bin/bash
# Builds the base rootfs tarball using mmdebstrap: stock Ubuntu plus the
# vendored third-party binaries, and nothing appliance-specific. This is the
# slow, network-bound half of the payload build — everything that makes it an
# *appliance* (units, hostname, admin user, presets) is applied on top by
# build-rootfs.sh, which needs no network and runs in seconds.
#
# Rebuild this only when the package list, the dpkg excludes, or K3S_VERSION
# change. The installer/live environment is a separate build — see build-live.sh.
# Runs unprivileged via user namespaces (--mode=unshare).
# The .tar.zst extension makes mmdebstrap emit a zstd-compressed tarball;
# downstream tar -x/-t auto-detect the compression.
#
# Usage: ./scripts/build-base-rootfs.sh [output.tar.zst]
set -euo pipefail

BUILD="${BUILD:-build}"
ARCH="${ARCH:-$(dpkg --print-architecture)}"
OUTPUT="${1:-$BUILD/base-rootfs-$ARCH.tar.zst}"
SUITES="resolute"

# amd64 lives on archive.ubuntu.com; every other arch on ports.ubuntu.com
case "$ARCH" in
    amd64) MIRROR_URL="http://archive.ubuntu.com/ubuntu/" ;;
    arm64) MIRROR_URL="http://ports.ubuntu.com/ubuntu-ports/" ;;
    *) echo "[build-base-rootfs] ERROR: unsupported ARCH '$ARCH' (amd64|arm64)" >&2; exit 1 ;;
esac
MIRROR="deb $MIRROR_URL $SUITES main restricted universe multiverse"

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
    # admin account (created by rootfs.d/10-admin-user.sh)
    sudo
)

log() { echo "[build-base-rootfs] $*"; }

export TMPDIR="${TMPDIR:-/var/tmp}"
mkdir -p "$BUILD"

# Vendored third-party binaries. These are not built from anything in this repo
# — fetch-k3s.sh downloads and sha256-verifies them into vendor/ at the pinned
# K3S_VERSION. They live in the base layer rather than the overlay because they
# are large and change only on a deliberate version bump.
VENDOR_K3S="vendor/k3s/$ARCH/bin/k3s"
[ -x "$VENDOR_K3S" ] || { log "ERROR: missing $VENDOR_K3S (run 'make fetch')"; exit 1; }

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
    --customize-hook='mkdir -p "$1/usr/local/bin"' \
    --customize-hook="copy-in $VENDOR_K3S /usr/local/bin/" \
    --customize-hook='chroot "$1" update-initramfs -u' \
    "$SUITES" "$OUTPUT" "$MIRROR"

log "Base rootfs tar: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
