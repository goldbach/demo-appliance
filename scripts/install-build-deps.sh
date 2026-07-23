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
    zstd \
    curl \
    ca-certificates \
    make
rm -rf /var/lib/apt/lists/*

# mkosi cache directory — writable by all so non-root builds work
mkdir -p /var/cache/mkosi
chmod 777 /var/cache/mkosi
