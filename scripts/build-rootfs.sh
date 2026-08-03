#!/bin/bash
# Builds the Appliance payload rootfs tarball using mmdebstrap: the full
# node OS (k3s, ssh, grub) that install.sh writes to disk and
# systemd-sysupdate later writes on A/B updates. The installer/live
# environment is a separate minimal build — see build-live.sh.
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

# Baked-in admin account. Same credentials on every box built with these
# values — fine for the demo phase, see TODO "Baked-in admin user".
ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-appliance}"
export ADMIN_USERNAME ADMIN_PASSWORD

# amd64 lives on archive.ubuntu.com; every other arch on ports.ubuntu.com
case "$ARCH" in
    amd64) MIRROR_URL="http://archive.ubuntu.com/ubuntu/" ;;
    arm64) MIRROR_URL="http://ports.ubuntu.com/ubuntu-ports/" ;;
    *) echo "[build-rootfs] ERROR: unsupported ARCH '$ARCH' (amd64|arm64)" >&2; exit 1 ;;
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
    # admin account (baked in via customize hooks below)
    sudo
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
    --customize-hook='copy-in units/firstboot.service /etc/systemd/system/' \
    --customize-hook='copy-in units/k3s-server.service /etc/systemd/system/' \
    --customize-hook='copy-in units/k3s-agent.service /etc/systemd/system/' \
    --customize-hook='printf "disable k3s-server.service\ndisable k3s-agent.service\n" > "$1/usr/lib/systemd/system-preset/99-appliance.preset"' \
    --customize-hook='chroot "$1" useradd -m -s /bin/bash -G sudo "$ADMIN_USERNAME"' \
    --customize-hook='echo "$ADMIN_USERNAME:$ADMIN_PASSWORD" | chroot "$1" chpasswd' \
    --customize-hook='chroot "$1" update-initramfs -u' \
    --customize-hook='chroot "$1" systemctl preset-all' \
    "$SUITES" "$OUTPUT" "$MIRROR"

log "Rootfs tar: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
