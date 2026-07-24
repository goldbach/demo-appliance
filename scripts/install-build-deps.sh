#!/bin/bash
set -euo pipefail
apt-get update
apt-get install -y --no-install-recommends \
    debootstrap \
    mmdebstrap \
    systemd-container \
    xorriso \
    isolinux \
    squashfs-tools \
    zstd \
    curl \
    ca-certificates \
    make \
    dpkg-dev \
    parted \
    dosfstools \
    e2fsprogs
rm -rf /var/lib/apt/lists/*
