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
