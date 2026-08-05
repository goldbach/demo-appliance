#!/bin/bash
# Entry point for the disk-install steps in installer.d/ next to this script
# (executed in glob order). Baked into the live env; called by
# installer-entrypoint.sh with ROOTFS_IMAGE and MACHINE_CONF set, both pointing
# at the mounted installer medium. ROOTFS_IMAGE is the same zstd-compressed
# partition image an A/B update writes into the inactive slot.
set -euo pipefail

export DISK="${1:?usage: install.sh <disk>}"
export ROOTFS_IMAGE="${ROOTFS_IMAGE:?ROOTFS_IMAGE not set}"
export MACHINE_CONF="${MACHINE_CONF:?MACHINE_CONF not set}"

# Partition layout (MiB) — shared by the preflight and partition steps
export EFI_SIZE=512
export ROOTFS_SIZE=10240   # 10 GiB per A/B slot

STEPS_DIR="$(dirname "$0")/installer.d"

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
