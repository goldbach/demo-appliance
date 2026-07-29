#!/bin/bash
# Partitions the target disk, writes the rootfs, installs the bootloader.
# Called by installer-run.sh with SQUASHFS_IMAGE and MACHINE_CONF set.
set -euo pipefail

DISK="${1:?usage: install.sh <disk>}"
SQUASHFS_IMAGE="${SQUASHFS_IMAGE:?SQUASHFS_IMAGE not set}"
MACHINE_CONF="${MACHINE_CONF:?MACHINE_CONF not set}"

# Sizes in MiB
EFI_SIZE=512
ROOTFS_SIZE=10240   # 10 GiB per A/B slot

log() { echo "[install] $*"; }

# Resolve partition device name — handles both /dev/sdaN and /dev/nvme0n1pN
part() {
    local disk="$1" n="$2"
    if [[ "$disk" == *nvme* || "$disk" == *mmcblk* ]]; then
        echo "${disk}p${n}"
    else
        echo "${disk}${n}"
    fi
}

log "Target: $DISK"
log "Partitioning..."

parted -s "$DISK" \
    mklabel gpt \
    mkpart EFI      fat32  1MiB                                          $((1 + EFI_SIZE))MiB \
    mkpart rootfs-a ext4   $((1 + EFI_SIZE))MiB                         $((1 + EFI_SIZE + ROOTFS_SIZE))MiB \
    mkpart rootfs-b ext4   $((1 + EFI_SIZE + ROOTFS_SIZE))MiB           $((1 + EFI_SIZE + ROOTFS_SIZE * 2))MiB \
    mkpart data     ext4   $((1 + EFI_SIZE + ROOTFS_SIZE * 2))MiB       100% \
    set 1 esp on

# Let udev settle
udevadm settle --timeout=10

EFI_PART=$(part "$DISK" 1)
ROOTFS_A=$(part "$DISK" 2)
ROOTFS_B=$(part "$DISK" 3)
DATA_PART=$(part "$DISK" 4)

log "Formatting..."
mkfs.fat  -F32 -n EFI      "$EFI_PART"
mkfs.ext4 -L   rootfs-a    "$ROOTFS_A"
mkfs.ext4 -L   rootfs-b    "$ROOTFS_B"
mkfs.ext4 -L   data        "$DATA_PART"

log "Mounting target rootfs..."
mount "$ROOTFS_A" /mnt

log "Extracting rootfs from squashfs (this takes a few minutes)..."
unsquashfs -f -d /mnt "$SQUASHFS_IMAGE"

# The squashfs carries the live environment's hostname; the installed
# system gets the distro default back.
echo appliance > /mnt/etc/hostname

mkdir -p /mnt/boot/efi
mount "$EFI_PART" /mnt/boot/efi
mount --bind /dev  /mnt/dev
mount --bind /proc /mnt/proc
mount --bind /sys  /mnt/sys
mount --bind /sys/firmware/efi/efivars /mnt/sys/firmware/efi/efivars 2>/dev/null || true

log "Installing GRUB (Secure Boot signed)..."
case "$(uname -m)" in
    x86_64)  GRUB_TARGET=x86_64-efi ;;
    aarch64) GRUB_TARGET=arm64-efi ;;
    *) echo "[install] ERROR: unsupported machine $(uname -m)" >&2; exit 1 ;;
esac
# No --no-nvram: grub-install registers an "appliance" EFI boot entry and puts
# it first in BootOrder, so the box boots from disk after install even with
# the installer medium still attached (firmware prefers removable media).
chroot /mnt grub-install \
    --target="$GRUB_TARGET" \
    --efi-directory=/boot/efi \
    --bootloader-id=appliance
chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

log "Removing live-environment leftovers..."
# live-boot only serves the installer medium; purging it also regenerates
# the initrd without live hooks. The installer scripts go too — installed
# nodes should not carry a disk-wiping entry point. Disk tools (parted,
# efibootmgr, ...) stay: useful for node maintenance and sysupdate.
chroot /mnt apt-get purge -y live-boot live-boot-initramfs-tools
rm -f /mnt/etc/systemd/system/installer.service \
      /mnt/etc/systemd/system/multi-user.target.wants/installer.service \
      /mnt/usr/lib/appliance/installer-run.sh \
      /mnt/usr/lib/appliance/install.sh

log "Writing /etc/fstab..."
# root stays rw for now: firstboot, ssh host keys, timesync etc. need writable
# /etc//var. ro root comes back with the A/B work, together with the
# writable-path plumbing (/data-backed overlays) it requires.
EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")
ROOT_UUID=$(blkid -s UUID -o value "$ROOTFS_A")
DATA_UUID=$(blkid -s UUID -o value "$DATA_PART")
cat > /mnt/etc/fstab <<EOF
UUID=$EFI_UUID   /boot/efi  vfat  umask=0077                    0 1
UUID=$ROOT_UUID  /          ext4  defaults                       0 1
UUID=$DATA_UUID  /data      ext4  defaults,x-systemd.makefs      0 2
EOF

log "Copying machine config..."
mkdir -p /mnt/etc/appliance
install -m 0600 "$MACHINE_CONF" /mnt/etc/appliance/machine.conf

log "Enabling first-boot unit..."
chroot /mnt systemctl enable firstboot.service

log "Copying k3s air-gap images to data partition..."
mount "$DATA_PART" /mnt/data 2>/dev/null || true
if [ -d /mnt/data ]; then
    mkdir -p /mnt/data/k3s-images
    if [ -d "$(dirname "$SQUASHFS_IMAGE")/../k3s-images" ]; then
        cp -v "$(dirname "$SQUASHFS_IMAGE")"/../k3s-images/*.tar.zst /mnt/data/k3s-images/ || true
    fi
    umount /mnt/data
fi

log "Unmounting..."
umount -R /mnt

log "Installation complete. Rebooting in 5 seconds..."
sleep 5
reboot
