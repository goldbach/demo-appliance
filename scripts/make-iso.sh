#!/bin/bash
# Wraps the rootfs image in a bootable installer ISO using Ubuntu's signed
# GRUB shim (Secure Boot compatible). Requires xorriso and the ubuntu-grub
# signed binaries to be present on the build host.
#
# Usage: make-iso.sh <rootfs.raw.zst> <rootfs.tar> <output.iso>
set -euo pipefail

ROOTFS="${1:?missing rootfs raw image}"
ROOTFS_TAR="${2:?missing rootfs tar}"
OUT="${3:?missing output iso path}"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

ISO_ROOT="$WORK/iso"
mkdir -p "$ISO_ROOT"/{boot/grub,EFI/BOOT,installer}

# --- Bootloader — extract signed EFI binaries from the rootfs tar ---
tar -xf "$ROOTFS_TAR" -C "$WORK" \
    "./usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed" \
    "./usr/lib/shim/shimx64.efi.signed.latest"
cp "$WORK/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed" "$ISO_ROOT/EFI/BOOT/grubx64.efi"
cp "$WORK/usr/lib/shim/shimx64.efi.signed.latest"             "$ISO_ROOT/EFI/BOOT/BOOTx64.efi"

# --- GRUB config ---
cat > "$ISO_ROOT/boot/grub/grub.cfg" <<'EOF'
set timeout=5
set default=0

menuentry "Install MyDistro" {
    linux  /boot/vmlinuz quiet console=tty0 console=ttyS0,115200 ---
    initrd /boot/initrd.img
}
EOF

# --- Kernel + initrd (from Ubuntu ISO or build host) ---
# TODO: copy from a known-good Ubuntu 26.04 minimal live ISO or build with mkosi
cp /boot/vmlinuz   "$ISO_ROOT/boot/vmlinuz"
cp /boot/initrd.img "$ISO_ROOT/boot/initrd.img"

# --- Installer payload ---
cp "$ROOTFS" "$ISO_ROOT/installer/rootfs.raw.zst"   # already compressed by make-image.sh
install -m 0755 installer/install.sh "$ISO_ROOT/installer/install.sh"
install -m 0600 firstboot/machine.conf.example "$ISO_ROOT/installer/machine.conf"

# --- Build ISO ---
xorriso -as mkisofs \
    -o "$OUT" \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
    -eltorito-alt-boot \
    -e EFI/BOOT/BOOTx64.efi \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    "$ISO_ROOT"

echo "ISO: $OUT"
