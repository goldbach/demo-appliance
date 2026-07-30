#!/bin/bash
set -euo pipefail
apt-get update
apt-get install -y --no-install-recommends \
    mmdebstrap \
    uidmap \
    xorriso \
    isolinux \
    syslinux-common \
    squashfs-tools \
    zstd \
    curl \
    ca-certificates \
    make \
    dosfstools \
    mtools \
    e2fsprogs \
    qemu-system-x86 \
    qemu-system-arm \
    ovmf \
    qemu-efi-aarch64
rm -rf /var/lib/apt/lists/*

# /dev/kvm is root:kvm 0660 — without this, `make boot*` silently falls
# back to TCG. Re-entering the shell is NOT enough under Lima: sessions
# ride a persistent SSH master connection whose groups are fixed at
# connect time, so the VM must be restarted.
if [ -n "${SUDO_USER:-}" ] && ! id -nG "$SUDO_USER" | grep -qw kvm; then
    usermod -aG kvm "$SUDO_USER"
    echo "==============================================================" >&2
    echo " Added $SUDO_USER to the kvm group." >&2
    echo " RESTART THE VM for it to take effect, from the host:" >&2
    echo "     limactl restart builder" >&2
    echo " (bare-metal Linux: log out and back in)" >&2
    echo " Otherwise QEMU falls back to slow TCG emulation." >&2
    echo "==============================================================" >&2
fi
