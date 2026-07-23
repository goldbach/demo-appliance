#!/bin/bash
# Runs from the live ISO environment. Partitions the target disk,
# writes the rootfs to partition A, installs the bootloader, and reboots.
set -euo pipefail

DISK="${1:?usage: install.sh <disk> e.g. /dev/sda}"
ROOTFS_IMAGE="/run/installer/rootfs.raw.zst"
MACHINE_CONF="/run/installer/machine.conf"

# Sizes in MiB
EFI_SIZE=512
ROOTFS_SIZE=10240   # 10 GiB per A/B slot

log() { echo "[install] $*"; }

log "Target disk: $DISK"
log "Partitioning..."

parted -s "$DISK" \
    mklabel gpt \
    mkpart EFI    fat32  1MiB                       $((1 + EFI_SIZE))MiB \
    mkpart rootfs-a ext4 $((1 + EFI_SIZE))MiB      $((1 + EFI_SIZE + ROOTFS_SIZE))MiB \
    mkpart rootfs-b ext4 $((1 + EFI_SIZE + ROOTFS_SIZE))MiB $((1 + EFI_SIZE + ROOTFS_SIZE * 2))MiB \
    mkpart data    ext4  $((1 + EFI_SIZE + ROOTFS_SIZE * 2))MiB 100%

set 1 esp on

log "Formatting..."
mkfs.fat  -F32 -n EFI      "${DISK}1"
mkfs.ext4 -L   rootfs-a    "${DISK}2"
mkfs.ext4 -L   rootfs-b    "${DISK}3"
mkfs.ext4 -L   data        "${DISK}4"

log "Writing rootfs to partition A..."
zstd -d "$ROOTFS_IMAGE" --stdout | dd of="${DISK}2" bs=4M status=progress conv=fsync
resize2fs "${DISK}2"

log "Mounting for bootloader install..."
mount "${DISK}2" /mnt
mount "${DISK}1" /mnt/boot/efi
mount --bind /dev  /mnt/dev
mount --bind /proc /mnt/proc
mount --bind /sys  /mnt/sys

log "Installing GRUB (signed, Secure Boot compatible)..."
chroot /mnt grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot/efi \
    --bootloader-id=mydistro \
    --no-nvram
chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

log "Writing /etc/fstab..."
EFI_UUID=$(blkid -s UUID -o value "${DISK}1")
ROOT_UUID=$(blkid -s UUID -o value "${DISK}2")
DATA_UUID=$(blkid -s UUID -o value "${DISK}4")
cat > /mnt/etc/fstab <<EOF
UUID=$EFI_UUID  /boot/efi  vfat  umask=0077          0 1
UUID=$ROOT_UUID /          ext4  defaults,ro          0 1
UUID=$DATA_UUID /data      ext4  defaults,x-systemd.makefs 0 2
EOF

log "Copying machine config..."
install -m 0600 "$MACHINE_CONF" /mnt/etc/mydistro/machine.conf

log "Enabling first-boot unit..."
chroot /mnt systemctl enable firstboot.service

log "Unmounting..."
umount -R /mnt

log "Done. Rebooting in 5s..."
sleep 5
reboot
