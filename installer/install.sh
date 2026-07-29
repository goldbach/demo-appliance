#!/bin/bash
# Entry point for the disk-install steps in /usr/lib/appliance/installer.d/
# (executed in glob order). Called by installer-run.sh with ROOTFS_IMAGE and
# MACHINE_CONF set. ROOTFS_IMAGE is the same zstd-compressed partition image
# that systemd-sysupdate writes on A/B updates.
set -euo pipefail

export DISK="${1:?usage: install.sh <disk>}"
export ROOTFS_IMAGE="${ROOTFS_IMAGE:?ROOTFS_IMAGE not set}"
export MACHINE_CONF="${MACHINE_CONF:?MACHINE_CONF not set}"

STEPS_DIR=/usr/lib/appliance/installer.d

log() { echo "[install] $*"; }

# Resolve partition device names — handles both /dev/sdaN and /dev/nvme0n1pN
PSEP=""
[[ "$DISK" == *nvme* || "$DISK" == *mmcblk* ]] && PSEP="p"
export EFI_PART="${DISK}${PSEP}1"
export ROOTFS_A="${DISK}${PSEP}2"
export ROOTFS_B="${DISK}${PSEP}3"
export DATA_PART="${DISK}${PSEP}4"

log "Target: $DISK"

for step in "$STEPS_DIR"/*.sh; do
    log "Running step: $(basename "$step")"
    bash "$step"
done

log "Installation complete. Rebooting in 5 seconds..."
sleep 5
reboot
