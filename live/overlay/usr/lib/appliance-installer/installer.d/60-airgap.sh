#!/bin/bash
# Install step: copy k3s air-gap images (if any) to the data partition.
set -euo pipefail

log() { echo "[install:airgap] $*"; }

log "Copying k3s air-gap images to data partition..."
mount "$DATA_PART" "$TARGET/data" 2>/dev/null || true
if [ -d "$TARGET/data" ]; then
    mkdir -p "$TARGET/data/k3s-images"
    if [ -d "$(dirname "$ROOTFS_IMAGE")/../k3s-images" ]; then
        cp -v "$(dirname "$ROOTFS_IMAGE")"/../k3s-images/*.tar.zst "$TARGET/data/k3s-images/" || true
    fi
    umount "$TARGET/data"
fi
