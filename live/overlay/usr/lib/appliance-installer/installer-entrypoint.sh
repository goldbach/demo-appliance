#!/bin/bash
# Entry point for the install, launched by installer.service inside the live
# environment. Mounts the installer medium, discovers the target disk, then
# execs install.sh from the medium. Unattended — see the Ctrl-C window below.
set -euo pipefail

log()  { echo "[installer] $*"; }
die()  { echo "[installer] ERROR: $*" >&2; exit 1; }

# /live/medium-device was written by the initrd live boot script.
# It tells us which block device is the installer USB/optical drive.
LIVE_DEV_FILE="/live/medium-device"
LIVE_DEV=""
[ -f "$LIVE_DEV_FILE" ] && LIVE_DEV=$(cat "$LIVE_DEV_FILE")

# Mount the installer medium (the device that holds live/filesystem.squashfs
# — which doubles as the install payload — and installer/machine.conf).
MEDIUM_MOUNT=/run/installer/medium
mkdir -p "$MEDIUM_MOUNT"

find_installer_medium() {
    local dev mnt="$MEDIUM_MOUNT"
    # Try the known live device first, then scan
    for dev in "$LIVE_DEV" /dev/sr0 /dev/sr1 \
               /dev/sda /dev/sdb /dev/sdc /dev/sdd \
               /dev/vda /dev/nvme0n1 /dev/nvme1n1; do
        [ -n "$dev" ] && [ -b "$dev" ] || continue
        mount -o ro "$dev" "$mnt" 2>/dev/null || continue
        if [ -f "$mnt/live/filesystem.squashfs" ]; then
            echo "$dev"
            return 0
        fi
        umount "$mnt" 2>/dev/null
    done
    return 1
}

log "Locating installer medium..."
MEDIUM_DEV=$(find_installer_medium) || die "installer payload not found on any device"
ROOTFS_IMAGE="$MEDIUM_MOUNT/installer/rootfs.raw.zst"
MACHINE_CONF="$MEDIUM_MOUNT/installer/machine.conf"
[ -f "$ROOTFS_IMAGE" ] || die "rootfs image missing on installer medium"
log "Medium: $MEDIUM_DEV"

echo ""
echo "======================================================"
echo "  Appliance Installer"
echo "======================================================"
echo ""

# Collect candidate target disks — exclude removable and the live medium
DISKS=()
for dev in /sys/block/sd* /sys/block/nvme* /sys/block/vd*; do
    [ -d "$dev" ] || continue
    name=$(basename "$dev")
    full="/dev/$name"
    removable=$(cat "$dev/removable" 2>/dev/null || echo 0)
    [ "$removable" = "1" ] && continue
    [ "$full" = "$MEDIUM_DEV" ] && continue
    DISKS+=("$full")
done

if [ ${#DISKS[@]} -eq 0 ]; then
    die "no suitable target disk found"
fi

# Unattended: exactly one candidate disk or bail — never guess what to wipe
if [ ${#DISKS[@]} -gt 1 ]; then
    die "need exactly one candidate disk, found ${#DISKS[@]}: ${DISKS[*]}"
fi
DISK="${DISKS[0]}"

echo ""
log "Install target : $DISK (auto-detected)"
log "Rootfs image   : $ROOTFS_IMAGE"
echo ""
echo "WARNING: ALL DATA ON $DISK WILL BE ERASED."
echo ""
# Unattended by design — the sleep is only a Ctrl-C window for a watching dev
log "Starting in 5 seconds..."
sleep 5

export ROOTFS_IMAGE
export MACHINE_CONF

# install.sh and its steps are baked into this live env, so they are present
# however the node booted — ISO, USB or PXE. The medium stays mounted
# throughout: rootfs.raw.zst and machine.conf are still read from it.
exec bash /usr/lib/appliance-installer/install.sh "$DISK"
