#!/bin/bash
# Builds the MyDistro rootfs tarball using mmdebstrap.
# Runs unprivileged via user namespaces (--mode=unshare).
#
# Usage: ./scripts/build-rootfs.sh [output.tar]
set -euo pipefail

BUILD="${BUILD:-build}"
OUTPUT="${1:-$BUILD/mydistro-rootfs.tar}"
SUITES="resolute"
MIRROR="deb http://archive.ubuntu.com/ubuntu/ $SUITES main restricted universe multiverse"

PACKAGES=(
    # kernel / boot
    linux-image-generic initramfs-tools
    # init / system
    systemd systemd-resolved systemd-sysv systemd-timesyncd udev dbus
    # certs / transport
    ca-certificates apt-transport-https
    # ssh
    openssh-server
    # network
    iproute2 iputils-ping iptables nftables bridge-utils
    ethtool dnsutils tcpdump socat netcat-openbsd
    # k3s deps
    conntrack kmod nfs-common open-iscsi
    # container runtime (k3s bundles its own, but needed for image prep)
    containerd
    # bootloader (Secure Boot)
    grub-efi-amd64-signed shim-signed
    # tools
    curl wget vim less jq htop lsof strace
    bash-completion psmisc procps util-linux zstd
)

log() { echo "[build-rootfs] $*"; }

export TMPDIR="${TMPDIR:-/var/tmp}"
mkdir -p "$BUILD"

# shellcheck disable=SC2016
mmdebstrap \
    --mode=unshare \
    --skip=check/qemu \
    --variant=minbase \
    --architectures=amd64 \
    --format=tar \
    --include="${PACKAGES[*]}" \
    --dpkgopt='path-exclude=/usr/share/man/*' \
    --dpkgopt='path-exclude=/usr/share/locale/*' \
    --dpkgopt='path-include=/usr/share/locale/locale.alias' \
    --dpkgopt='path-exclude=/usr/share/doc/*' \
    --customize-hook='mkdir -p "$1/usr/local/bin"' \
    --customize-hook='mkdir -p "$1/usr/lib/mydistro"' \
    --customize-hook='mkdir -p "$1/etc/systemd/system"' \
    --customize-hook='copy-in vendor/k3s/bin/k3s /usr/local/bin/' \
    --customize-hook='copy-in firstboot /usr/lib/mydistro/' \
    --customize-hook='copy-in installer /usr/lib/mydistro/' \
    --customize-hook='copy-in units /etc/systemd/system/' \
    --customize-hook='chroot "$1" update-initramfs -u' \
    --customize-hook='chroot "$1" systemctl preset-all' \
    "$SUITES" "$OUTPUT" "$MIRROR"

log "Rootfs tar: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
