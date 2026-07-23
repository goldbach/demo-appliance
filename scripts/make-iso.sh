#!/bin/bash
# Builds a Secure Boot-compatible installer ISO using live-boot.
#
# The ISO boots the full Ubuntu rootfs as a live environment (overlayfs over
# tmpfs). live-boot handles mounting. On boot, installer.service auto-launches
# installer-run.sh which partitions the target disk and writes rootfs.raw.zst.
#
# Usage: make-iso.sh <rootfs.raw.zst> <rootfs.tar> <output.iso>
set -euo pipefail

ROOTFS_ZST="${1:?missing rootfs.raw.zst}"
ROOTFS_TAR="${2:?missing rootfs.tar}"
OUT="${3:?missing output iso path}"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

ISO_ROOT="$WORK/iso"
mkdir -p "$ISO_ROOT"/{boot/grub,EFI/BOOT,live,installer}

# --- Bootloader: signed EFI binaries from rootfs ---
tar -xf "$ROOTFS_TAR" -C "$WORK" \
    "./usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed" \
    "./usr/lib/shim/shimx64.efi.signed.latest"
cp "$WORK/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed" "$ISO_ROOT/EFI/BOOT/grubx64.efi"
cp "$WORK/usr/lib/shim/shimx64.efi.signed.latest"             "$ISO_ROOT/EFI/BOOT/BOOTx64.efi"

# --- Kernel + initrd (with live-boot hooks baked in by update-initramfs) ---
tar -xf "$ROOTFS_TAR" -C "$WORK" \
    "./boot/vmlinuz" \
    "./boot/initrd.img"
cp "$WORK/boot/vmlinuz"    "$ISO_ROOT/boot/vmlinuz"
cp "$WORK/boot/initrd.img" "$ISO_ROOT/boot/initrd.img"

# --- Squashfs: the live rootfs that boots in RAM ---
echo "Building squashfs (this takes a minute)..."
SQUASH_ROOT="$WORK/squashfs-root"
mkdir -p "$SQUASH_ROOT"
tar -xf "$ROOTFS_TAR" -C "$SQUASH_ROOT"
mksquashfs "$SQUASH_ROOT" "$ISO_ROOT/live/filesystem.squashfs" \
    -comp zstd -Xcompression-level 9 -noappend -quiet
printf '%s' "$(du -sx --block-size=1 "$SQUASH_ROOT" | cut -f1)" \
    > "$ISO_ROOT/live/filesystem.size"

# --- Installer payload (rootfs image written to disk by install.sh) ---
cp "$ROOTFS_ZST" "$ISO_ROOT/installer/rootfs.raw.zst"
install -m 0600 firstboot/machine.conf.example "$ISO_ROOT/installer/machine.conf"

# --- GRUB config ---
# boot=live tells live-boot's initrd hook to find live/filesystem.squashfs.
# toram copies the squashfs to RAM so we can unmount the ISO during install.
cat > "$ISO_ROOT/boot/grub/grub.cfg" <<'EOF'
set timeout=10
set default=0

menuentry "Install MyDistro" {
    linux  /boot/vmlinuz boot=live quiet console=tty0 console=ttyS0,115200
    initrd /boot/initrd.img
}

menuentry "Install MyDistro (verbose)" {
    linux  /boot/vmlinuz boot=live console=tty0 console=ttyS0,115200
    initrd /boot/initrd.img
}
EOF

# --- Build ISO ---
xorriso -as mkisofs \
    -o "$OUT" \
    -V "MYDISTRO" \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
    -eltorito-alt-boot \
    -e EFI/BOOT/BOOTx64.efi \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    "$ISO_ROOT"

echo "ISO: $OUT"
