#!/bin/bash
# Builds a Secure Boot-compatible installer ISO using live-boot.
#
# The ISO boots the full Ubuntu rootfs as a live environment (overlayfs over
# tmpfs). live-boot handles mounting. On boot, installer.service auto-launches
# installer-run.sh which partitions the target disk and extracts the live
# squashfs onto it — the squashfs doubles as the install payload.
#
# Usage: make-iso.sh <rootfs.tar> <output.iso>
set -euo pipefail

ROOTFS_TAR="${1:?missing rootfs.tar}"
OUT="${2:?missing output iso path}"

WORK=$(mktemp -d "${TMPDIR:-/var/tmp}/make-iso.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

ISO_ROOT="$WORK/iso"
mkdir -p "$ISO_ROOT"/{boot/grub,EFI/BOOT,EFI/ubuntu,live,installer,isolinux}

# --- Bootloader: signed EFI binaries from rootfs ---
tar -xf "$ROOTFS_TAR" -C "$WORK" --exclude='./dev/*' \
    "./usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed" \
    "./usr/lib/shim/shimx64.efi.signed.latest"
cp "$WORK/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed" "$ISO_ROOT/EFI/BOOT/grubx64.efi"
cp "$WORK/usr/lib/shim/shimx64.efi.signed.latest"             "$ISO_ROOT/EFI/BOOT/BOOTx64.efi"

# --- BIOS bootloader: isolinux ---
cp /usr/lib/ISOLINUX/isolinux.bin             "$ISO_ROOT/isolinux/"
cp /usr/lib/syslinux/modules/bios/ldlinux.c32 "$ISO_ROOT/isolinux/"
cat > "$ISO_ROOT/isolinux/isolinux.cfg" <<'EOF'
SERIAL 0 115200
DEFAULT install
PROMPT 0
TIMEOUT 100

LABEL install
    KERNEL /boot/vmlinuz
    APPEND initrd=/boot/initrd.img boot=live console=tty0 console=ttyS0,115200

LABEL auto
    KERNEL /boot/vmlinuz
    APPEND initrd=/boot/initrd.img boot=live mydistro.install=auto console=tty0 console=ttyS0,115200
EOF

# --- Kernel + initrd (with live-boot hooks baked in by update-initramfs) ---
# vmlinuz and initrd.img are symlinks — extract the real files
KERNEL=$(tar -tf "$ROOTFS_TAR" | grep '^./boot/vmlinuz-[0-9]' | head -1)
INITRD=$(tar -tf "$ROOTFS_TAR" | grep '^./boot/initrd.img-[0-9]' | head -1)
if [ -z "$INITRD" ]; then
    INITRD="./boot/initrd.img"  # fall back to the symlink itself
fi
tar -xf "$ROOTFS_TAR" -C "$WORK" --exclude='./dev/*' \
    "$KERNEL" \
    "$INITRD"
cp "$WORK/${KERNEL#./}"   "$ISO_ROOT/boot/vmlinuz"
cp "$WORK/${INITRD#./}"   "$ISO_ROOT/boot/initrd.img"

# --- Squashfs: the live rootfs that boots in RAM ---
echo "Building squashfs (this takes a minute)..."
SQUASH_ROOT="$WORK/squashfs-root"
mkdir -p "$SQUASH_ROOT"
tar -xf "$ROOTFS_TAR" -C "$SQUASH_ROOT" --exclude='./dev/*'
# The squashfs is only ever the live/installer environment. rootfs.raw
# (what install.sh writes to disk) keeps the rootfs hostname (mydistro).
echo live-boot > "$SQUASH_ROOT/etc/hostname"
mksquashfs "$SQUASH_ROOT" "$ISO_ROOT/live/filesystem.squashfs" \
    -comp zstd -Xcompression-level 9 -noappend -quiet
printf '%s' "$(du -sx --block-size=1 "$SQUASH_ROOT" | cut -f1)" \
    > "$ISO_ROOT/live/filesystem.size"

# --- Installer payload ---
# No separate rootfs image: install.sh extracts live/filesystem.squashfs.
install -m 0600 firstboot/machine.conf.example "$ISO_ROOT/installer/machine.conf"

# --- k3s air-gap images (copied to /data by install.sh) ---
K3S_IMAGES="vendor/k3s/images"
if [ -d "$K3S_IMAGES" ]; then
    mkdir -p "$ISO_ROOT/k3s-images"
    cp "$K3S_IMAGES"/*.tar.zst "$ISO_ROOT/k3s-images/"
    echo "Bundled k3s air-gap images."
fi

# --- GRUB config ---
# boot=live tells live-boot's initrd hook to find live/filesystem.squashfs.
# The signed Ubuntu grubx64.efi has a baked-in prefix of /EFI/ubuntu, so the
# config must live there. The search line re-roots to the ISO filesystem so
# kernel/initrd paths resolve even when booted from the ESP (USB/dd boot).
cat > "$ISO_ROOT/EFI/ubuntu/grub.cfg" <<'EOF'
serial --unit=0 --speed=115200
terminal_input serial console
terminal_output serial console

set timeout=10
set default=0

search --file --set=root /live/filesystem.squashfs

menuentry "Install MyDistro" {
    linux  /boot/vmlinuz boot=live console=tty0 console=ttyS0,115200
    initrd /boot/initrd.img
}

menuentry "Install MyDistro (automatic, NO confirmation)" {
    linux  /boot/vmlinuz boot=live mydistro.install=auto console=tty0 console=ttyS0,115200
    initrd /boot/initrd.img
}
EOF
cp "$ISO_ROOT/EFI/ubuntu/grub.cfg" "$ISO_ROOT/boot/grub/grub.cfg"

# --- Build ISO ---

# Create a FAT16 EFI System Partition image for El Torito UEFI boot.
# OVMF's El Torito driver mounts a FAT image as a virtual disk — it cannot
# load a bare EFI binary from the ISO9660 filesystem. 16 MiB is the minimum
# size mkfs.fat accepts for FAT16; FAT32 would need ~64 MiB to be in-spec.
ESP="$WORK/efi.img"
dd if=/dev/zero of="$ESP" bs=1M count=16 status=none
mkfs.fat -F 16 "$ESP" >/dev/null
mmd -i "$ESP" ::EFI ::EFI/BOOT ::EFI/ubuntu
mcopy -i "$ESP" "$ISO_ROOT/EFI/BOOT/BOOTx64.efi" ::EFI/BOOT/BOOTx64.efi
mcopy -i "$ESP" "$ISO_ROOT/EFI/BOOT/grubx64.efi" ::EFI/BOOT/grubx64.efi
mcopy -i "$ESP" "$ISO_ROOT/EFI/ubuntu/grub.cfg" ::EFI/ubuntu/grub.cfg

cp "$ESP" "$ISO_ROOT/boot/efi.img"

# El Torito catalog with two entries:
#   1. isolinux (platform BIOS)  — SeaBIOS / legacy boot, -boot-info-table is
#      only valid here (it patches the boot file, and would corrupt efi.img)
#   2. efi.img (platform UEFI, via -e) — no load-size/info-table options
xorriso -as mkisofs \
    -o "$OUT" \
    -V "MYDISTRO" \
    -R -r -J \
    -eltorito-boot isolinux/isolinux.bin \
    -eltorito-catalog isolinux/boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -eltorito-alt-boot \
    -e boot/efi.img \
    -no-emul-boot \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
    -isohybrid-gpt-basdat \
    -append_partition 2 0xef "$ESP" \
    "$ISO_ROOT"

echo "ISO: $OUT"
