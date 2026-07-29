#!/bin/bash
# Runs inside the live environment. Mounts the installer medium, discovers the
# target disk, confirms with the field engineer, then delegates to install.sh.
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

# Selected via the boot menu entry: skip all confirmation prompts
AUTO=no
grep -q "appliance.install=auto" /proc/cmdline && AUTO=yes

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

if [ ${#DISKS[@]} -eq 1 ]; then
    DISK="${DISKS[0]}"
    log "Target disk: $DISK (auto-detected)"
elif [ "$AUTO" = yes ]; then
    # never guess which disk to wipe
    die "appliance.install=auto needs exactly one candidate disk, found ${#DISKS[@]}"
else
    echo "Available disks:"
    for i in "${!DISKS[@]}"; do
        name=$(basename "${DISKS[$i]}")
        size_sectors=$(cat "/sys/block/$name/size" 2>/dev/null || echo 0)
        size_gib=$(awk "BEGIN { printf \"%.0f\", $size_sectors * 512 / 1073741824 }")
        echo "  $((i+1)). ${DISKS[$i]}  (${size_gib} GiB)"
    done
    echo ""
    read -r -p "Select disk number [1]: " sel
    sel="${sel:-1}"
    DISK="${DISKS[$((sel-1))]}"
fi

echo ""
log "Install target : $DISK"
log "Rootfs image   : $ROOTFS_IMAGE"
echo ""
echo "WARNING: ALL DATA ON $DISK WILL BE ERASED."
echo ""
if [ "$AUTO" = yes ]; then
    log "appliance.install=auto — proceeding without confirmation"
else
    read -r -p "Type 'yes' to continue: " confirm
    [ "$confirm" = "yes" ] || { echo "Aborted."; exit 1; }
fi
echo ""

export ROOTFS_IMAGE
export MACHINE_CONF

# install.sh and its steps live on the medium as plain files (not baked into
# the live env), so iterating on them only needs an ISO repack. The medium
# stays mounted throughout — rootfs.raw.zst is read from it.
exec bash "$MEDIUM_MOUNT/installer/install.sh" "$DISK"
