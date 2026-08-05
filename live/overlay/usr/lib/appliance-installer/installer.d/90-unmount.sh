#!/bin/bash
# Install step: unmount the target system.
set -euo pipefail

log() { echo "[install:unmount] $*"; }

log "Unmounting..."
umount -R "$TARGET"
