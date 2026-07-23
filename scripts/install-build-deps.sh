#!/bin/bash
set -euo pipefail
apt-get update
apt-get install -y --no-install-recommends \
    mkosi \
    debootstrap \
    systemd-container \
    e2fsprogs \
    dosfstools \
    parted \
    xorriso \
    isolinux \
    grub-efi-amd64-signed \
    shim-signed \
    zstd \
    curl \
    ca-certificates \
    make
rm -rf /var/lib/apt/lists/*
