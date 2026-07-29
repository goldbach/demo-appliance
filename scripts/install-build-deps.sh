#!/bin/bash
set -euo pipefail
apt-get update
apt-get install -y --no-install-recommends \
    mmdebstrap \
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
    e2fsprogs
rm -rf /var/lib/apt/lists/*
