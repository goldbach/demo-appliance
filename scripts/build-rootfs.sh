#!/bin/bash
# Builds the Appliance rootfs tarball using mmdebstrap.
# Runs unprivileged via user namespaces (--mode=unshare).
# The .tar.zst extension makes mmdebstrap emit a zstd-compressed tarball;
# downstream tar -x/-t auto-detect the compression.
#
# Usage: ./scripts/build-rootfs.sh [output.tar.zst]
set -euo pipefail

BUILD="${BUILD:-build}"
ARCH="${ARCH:-$(dpkg --print-architecture)}"
OUTPUT="${1:-$BUILD/appliance-rootfs-$ARCH.tar.zst}"
SUITES="resolute"

# amd64 lives on archive.ubuntu.com; every other arch on ports.ubuntu.com
case "$ARCH" in
    amd64) MIRROR_URL="http://archive.ubuntu.com/ubuntu/" ;;
    arm64) MIRROR_URL="http://ports.ubuntu.com/ubuntu-ports/" ;;
    *) echo "[build-rootfs] ERROR: unsupported ARCH '$ARCH' (amd64|arm64)" >&2; exit 1 ;;
esac
MIRROR="deb $MIRROR_URL $SUITES main restricted universe multiverse"

PACKAGES=(
    # kernel / boot
    linux-image-generic initramfs-tools live-boot live-boot-initramfs-tools
    # init / system
    systemd systemd-resolved systemd-sysv systemd-timesyncd udev dbus
    # certs (k3s pulls images over TLS)
    ca-certificates
    # ssh
    openssh-server
    # k3s host deps: netlink tools, kube-proxy iptables/conntrack, modprobe
    iproute2 iptables conntrack kmod
    # installer (runs in the live env) + node maintenance:
    # partition, format, write rootfs image, EFI boot entry
    parted dosfstools e2fsprogs efibootmgr
    # bootloader (Secure Boot)
    "grub-efi-${ARCH}-signed" shim-signed
    # minimal ops: ps/free/sysctl; zstd for A/B update images
    procps zstd
)

log() { echo "[build-rootfs] $*"; }

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
    --customize-hook='mkdir -p "$1/usr/local/bin"' \
    --customize-hook='mkdir -p "$1/data"' \
    --customize-hook='mkdir -p "$1/etc/systemd/network" && printf "[Match]\nName=en* eth*\n\n[Network]\nDHCP=yes\n" > "$1/etc/systemd/network/20-wired.network"' \
    --customize-hook='echo appliance > "$1/etc/hostname"' \
    --customize-hook='mkdir -p "$1/usr/lib/appliance"' \
    --customize-hook='mkdir -p "$1/etc/systemd/system"' \
    --customize-hook="copy-in vendor/k3s/$ARCH/bin/k3s /usr/local/bin/" \
    --customize-hook='copy-in installer/installer-run.sh /usr/lib/appliance/' \
    --customize-hook='copy-in installer/install.sh /usr/lib/appliance/' \
    --customize-hook='copy-in firstboot/firstboot.sh /usr/lib/appliance/' \
    --customize-hook='copy-in units/installer.service /etc/systemd/system/' \
    --customize-hook='copy-in units/firstboot.service /etc/systemd/system/' \
    --customize-hook='copy-in units/k3s-server.service /etc/systemd/system/' \
    --customize-hook='copy-in units/k3s-agent.service /etc/systemd/system/' \
    --customize-hook='printf "disable k3s-server.service\ndisable k3s-agent.service\n" > "$1/usr/lib/systemd/system-preset/99-appliance.preset"' \
    --customize-hook='chroot "$1" update-initramfs -u' \
    --customize-hook='chroot "$1" systemctl preset-all' \
    "$SUITES" "$OUTPUT" "$MIRROR"

log "Rootfs tar: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
