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
    linux-image-generic initramfs-tools live-boot live-boot-initramfs-tools
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
    # installer (runs in the live env): partition, format, boot entry, extract
    parted dosfstools e2fsprogs efibootmgr squashfs-tools
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
    --customize-hook='mkdir -p "$1/data"' \
    --customize-hook='mkdir -p "$1/etc/systemd/network" && printf "[Match]\nName=en* eth*\n\n[Network]\nDHCP=yes\n" > "$1/etc/systemd/network/20-wired.network"' \
    --customize-hook='echo mydistro > "$1/etc/hostname"' \
    --customize-hook='mkdir -p "$1/usr/lib/mydistro"' \
    --customize-hook='mkdir -p "$1/etc/systemd/system"' \
    --customize-hook='copy-in vendor/k3s/bin/k3s /usr/local/bin/' \
    --customize-hook='copy-in installer/installer-run.sh /usr/lib/mydistro/' \
    --customize-hook='copy-in installer/install.sh /usr/lib/mydistro/' \
    --customize-hook='copy-in firstboot/firstboot.sh /usr/lib/mydistro/' \
    --customize-hook='copy-in units/installer.service /etc/systemd/system/' \
    --customize-hook='copy-in units/firstboot.service /etc/systemd/system/' \
    --customize-hook='copy-in units/k3s-server.service /etc/systemd/system/' \
    --customize-hook='copy-in units/k3s-agent.service /etc/systemd/system/' \
    --customize-hook='printf "disable k3s-server.service\ndisable k3s-agent.service\n" > "$1/usr/lib/systemd/system-preset/99-mydistro.preset"' \
    --customize-hook='chroot "$1" update-initramfs -u' \
    --customize-hook='chroot "$1" systemctl preset-all' \
    "$SUITES" "$OUTPUT" "$MIRROR"

log "Rootfs tar: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
