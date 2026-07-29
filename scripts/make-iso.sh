#!/bin/bash
# Builds a Secure Boot-compatible installer ISO using live-boot.
#
# The ISO boots the full Ubuntu rootfs as a live environment (overlayfs over
# tmpfs). live-boot handles mounting. On boot, installer.service auto-launches
# installer-run.sh which partitions the target disk and extracts the live
# squashfs onto it — the squashfs doubles as the install payload.
#
# UEFI boot works on amd64 and arm64; BIOS (isolinux) is amd64-only.
#
# Usage: [ARCH=arm64] make-iso.sh <rootfs.tar[.zst]> <output.iso>
set -euo pipefail

ROOTFS_TAR="${1:?missing rootfs.tar}"
OUT="${2:?missing output iso path}"
ARCH="${ARCH:-$(dpkg --print-architecture)}"

# EFI naming: amd64 → grubx64/shimx64/BOOTx64, arm64 → grubaa64/shimaa64/BOOTAA64.
# grub spells its platform with the kernel arch on x86 (x86_64-efi) but the
# Debian arch on arm (arm64-efi, never aarch64).
case "$ARCH" in
    amd64) ARCH_KERNEL="${ARCH_KERNEL:-x86_64}";  EFI=x64;  GRUB_PLATFORM="$ARCH_KERNEL-efi"; SERIAL_TTY=ttyS0 ;;
    arm64) ARCH_KERNEL="${ARCH_KERNEL:-aarch64}"; EFI=aa64; GRUB_PLATFORM="$ARCH-efi";        SERIAL_TTY=ttyAMA0 ;;
    *) echo "[make-iso] ERROR: unsupported ARCH '$ARCH' (amd64|arm64)" >&2; exit 1 ;;
esac
BOOT_EFI="BOOT${EFI^^}.efi"
GRUB_EFI="grub${EFI}.efi"
CONSOLE="console=tty0 console=$SERIAL_TTY,115200"

WORK=$(mktemp -d "${TMPDIR:-/var/tmp}/make-iso.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

ISO_ROOT="$WORK/iso"
mkdir -p "$ISO_ROOT"/{boot/grub,EFI/BOOT,EFI/ubuntu,live,installer}

# --- Bootloader: signed EFI binaries from rootfs ---
# shim ships as .signed.latest on amd64 but plain .signed on some arches —
# take whichever the rootfs has (sort puts .latest last).
SHIM_PATH=$(tar -tf "$ROOTFS_TAR" \
    | grep -E "^\./usr/lib/shim/shim${EFI}\.efi\.signed(\.latest)?$" \
    | sort | tail -1)
[ -n "$SHIM_PATH" ] || { echo "[make-iso] ERROR: no signed shim in rootfs" >&2; exit 1; }
GRUB_PATH="./usr/lib/grub/$GRUB_PLATFORM-signed/$GRUB_EFI.signed"
tar -xf "$ROOTFS_TAR" -C "$WORK" --exclude='./dev/*' \
    "$GRUB_PATH" \
    "$SHIM_PATH"
cp "$WORK/${GRUB_PATH#./}" "$ISO_ROOT/EFI/BOOT/$GRUB_EFI"
cp "$WORK/${SHIM_PATH#./}" "$ISO_ROOT/EFI/BOOT/$BOOT_EFI"

# --- BIOS bootloader: isolinux (amd64 only — arm64 has no BIOS) ---
if [ "$ARCH" = amd64 ]; then
    mkdir -p "$ISO_ROOT/isolinux"
    cp /usr/lib/ISOLINUX/isolinux.bin             "$ISO_ROOT/isolinux/"
    cp /usr/lib/syslinux/modules/bios/ldlinux.c32 "$ISO_ROOT/isolinux/"
    cat > "$ISO_ROOT/isolinux/isolinux.cfg" <<EOF
SERIAL 0 115200
DEFAULT install
PROMPT 0
TIMEOUT 100

LABEL install
    KERNEL /boot/vmlinuz
    APPEND initrd=/boot/initrd.img boot=live $CONSOLE

LABEL auto
    KERNEL /boot/vmlinuz
    APPEND initrd=/boot/initrd.img boot=live appliance.install=auto $CONSOLE
EOF
fi

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
# (what install.sh writes to disk) keeps the rootfs hostname (appliance).
echo live-boot > "$SQUASH_ROOT/etc/hostname"
mksquashfs "$SQUASH_ROOT" "$ISO_ROOT/live/filesystem.squashfs" \
    -comp zstd -Xcompression-level 9 -noappend -quiet
printf '%s' "$(du -sx --block-size=1 "$SQUASH_ROOT" | cut -f1)" \
    > "$ISO_ROOT/live/filesystem.size"

# --- Installer payload ---
# No separate rootfs image: install.sh extracts live/filesystem.squashfs.
install -m 0600 firstboot/machine.conf.example "$ISO_ROOT/installer/machine.conf"

# --- k3s air-gap images (copied to /data by install.sh) ---
K3S_IMAGES="vendor/k3s/$ARCH/images"
if [ -d "$K3S_IMAGES" ]; then
    mkdir -p "$ISO_ROOT/k3s-images"
    cp "$K3S_IMAGES"/*.tar.zst "$ISO_ROOT/k3s-images/"
    echo "Bundled k3s air-gap images."
fi

# --- GRUB config ---
# boot=live tells live-boot's initrd hook to find live/filesystem.squashfs.
# The signed Ubuntu grub EFI binary has a baked-in prefix of /EFI/ubuntu, so
# the config must live there. The search line re-roots to the ISO filesystem
# so kernel/initrd paths resolve even when booted from the ESP (USB/dd boot).
# grub's `serial` command only knows ioport UARTs — amd64 only.
GRUB_SERIAL=""
if [ "$ARCH" = amd64 ]; then
    GRUB_SERIAL='serial --unit=0 --speed=115200
terminal_input serial console
terminal_output serial console'
fi
cat > "$ISO_ROOT/EFI/ubuntu/grub.cfg" <<EOF
$GRUB_SERIAL

set timeout=10
set default=0

search --file --set=root /live/filesystem.squashfs

menuentry "Install Appliance" {
    linux  /boot/vmlinuz boot=live $CONSOLE
    initrd /boot/initrd.img
}

menuentry "Install Appliance (automatic, NO confirmation)" {
    linux  /boot/vmlinuz boot=live appliance.install=auto $CONSOLE
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
mcopy -i "$ESP" "$ISO_ROOT/EFI/BOOT/$BOOT_EFI" "::EFI/BOOT/$BOOT_EFI"
mcopy -i "$ESP" "$ISO_ROOT/EFI/BOOT/$GRUB_EFI" "::EFI/BOOT/$GRUB_EFI"
mcopy -i "$ESP" "$ISO_ROOT/EFI/ubuntu/grub.cfg" ::EFI/ubuntu/grub.cfg

cp "$ESP" "$ISO_ROOT/boot/efi.img"

# El Torito catalog:
#   amd64: isolinux (platform BIOS) + efi.img (platform UEFI, via -e).
#     -boot-info-table is only valid on the BIOS entry (it patches the boot
#     file, and would corrupt efi.img); isohybrid MBR makes dd'd USBs boot.
#   arm64: UEFI entry only — no BIOS, no isolinux, no isohybrid MBR.
# -append_partition exposes the ESP as a real partition for USB/dd boot.
XORRISO_ARGS=(
    -o "$OUT"
    -V "APPLIANCE"
    -R -r -J
)
if [ "$ARCH" = amd64 ]; then
    XORRISO_ARGS+=(
        -eltorito-boot isolinux/isolinux.bin
        -eltorito-catalog isolinux/boot.cat
        -no-emul-boot
        -boot-load-size 4
        -boot-info-table
        -eltorito-alt-boot
    )
fi
XORRISO_ARGS+=(
    -e boot/efi.img
    -no-emul-boot
)
if [ "$ARCH" = amd64 ]; then
    XORRISO_ARGS+=(
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin
        -isohybrid-gpt-basdat
    )
fi
XORRISO_ARGS+=( -append_partition 2 0xef "$ESP" )

xorriso -as mkisofs "${XORRISO_ARGS[@]}" "$ISO_ROOT"

echo "ISO: $OUT ($ARCH)"
