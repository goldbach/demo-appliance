#!/bin/bash
# Builds a Secure Boot-compatible installer ISO using live-boot.
#
# The ISO boots the micro live rootfs (build-live.sh) as the installer
# environment (overlayfs over tmpfs). On boot, installer.service launches
# installer-entrypoint.sh, which re-execs install.sh from the installer medium.
# install.sh partitions the target disk and writes the bundled payload image
# (installer/rootfs.raw.zst — the same image an A/B update writes into the
# inactive slot) to slot A. Frequently-edited scripts (install.sh, installer.d/,
# firstboot.sh, firstboot.d/) are plain files on the ISO, so iterating on
# them only requires an ISO repack, not a rootfs rebuild.
#
# UEFI boot works on amd64 and arm64; BIOS (isolinux) is amd64-only.
#
# Usage: [ARCH=arm64] make-iso.sh <live.tar[.zst]> <rootfs.raw.zst> <output.iso>
set -euo pipefail

LIVE_TAR="${1:?missing live-rootfs.tar}"
ROOTFS_IMG="${2:?missing rootfs.raw.zst}"
OUT="${3:?missing output iso path}"
ARCH="${ARCH:-$(dpkg --print-architecture)}"
K3S_VERSION="${K3S_VERSION:?set K3S_VERSION (exported by the Makefile)}"

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
# The LAST console= owns /dev/console, where the interactive installer runs;
# the kernel mirrors boot messages to ALL listed consoles. Both orderings
# ship as separate menu entries: display-primary (the default, both arches —
# see scripts/boot-utm.sh for local Apple Silicon testing) and serial-primary
# as the alternate. Headless/serial setups (real headless hardware, the
# Lima builder VM's own `make boot`/`boot-headless`) are postponed for now;
# picking the serial alternate at the grub menu still works meanwhile.
CONSOLE_DISPLAY="console=$SERIAL_TTY,115200 console=tty0"
CONSOLE_SERIAL="console=tty0 console=$SERIAL_TTY,115200"
CONSOLE_DEFAULT="$CONSOLE_DISPLAY"

WORK=$(mktemp -d "${TMPDIR:-/var/tmp}/make-iso.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

ISO_ROOT="$WORK/iso"
mkdir -p "$ISO_ROOT"/{boot/grub,EFI/BOOT,EFI/ubuntu,live,installer}

# --- Bootloader: signed EFI binaries from the live rootfs ---
# shim ships as .signed.latest on amd64 but plain .signed on some arches —
# take whichever the tarball has (sort puts .latest last).
# `|| true`: no match must reach the guard below, not die silently here
# (set -e + pipefail would kill the script at this assignment)
SHIM_PATH=$(tar -tf "$LIVE_TAR" \
    | grep -E "^\./usr/lib/shim/shim${EFI}\.efi\.signed(\.latest)?$" \
    | sort | tail -1 || true)
[ -n "$SHIM_PATH" ] || { echo "[make-iso] ERROR: no signed shim in live rootfs" >&2; exit 1; }
GRUB_PATH="./usr/lib/grub/$GRUB_PLATFORM-signed/$GRUB_EFI.signed"
tar -xf "$LIVE_TAR" -C "$WORK" --exclude='./dev/*' \
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
    APPEND initrd=/boot/initrd.img boot=live $CONSOLE_DEFAULT
EOF
fi

# --- Kernel + initrd (with live-boot hooks baked in by update-initramfs) ---
# vmlinuz and initrd.img are symlinks — extract the real files
KERNEL=$(tar -tf "$LIVE_TAR" | grep '^./boot/vmlinuz-[0-9]' | head -1)
INITRD=$(tar -tf "$LIVE_TAR" | grep '^./boot/initrd.img-[0-9]' | head -1)
if [ -z "$INITRD" ]; then
    INITRD="./boot/initrd.img"  # fall back to the symlink itself
fi
tar -xf "$LIVE_TAR" -C "$WORK" --exclude='./dev/*' \
    "$KERNEL" \
    "$INITRD"
cp "$WORK/${KERNEL#./}"   "$ISO_ROOT/boot/vmlinuz"
cp "$WORK/${INITRD#./}"   "$ISO_ROOT/boot/initrd.img"

# --- Squashfs: the micro live rootfs that boots in RAM ---
# fakeroot: the tarball correctly records root-owned files (mmdebstrap's
# unprivileged --mode=unshare build maps its user namespace back to real
# uid 0 in the tar — see scripts/make-image.sh's identical fix for the
# payload rootfs), but a plain unprivileged `tar -x` can't chown to uid 0
# and silently extracts everything as the calling user instead; mksquashfs
# then bakes THAT wrong ownership into the live env (e.g. /etc/sudoers ends
# up owned by the build user, breaking sudo in the live installer shell).
# Extraction and mksquashfs must run in the same fakeroot session, or the
# faked ownership from the extraction is gone by the time mksquashfs stats
# the directory.
echo "Building squashfs (this takes a minute)..."
SQUASH_ROOT="$WORK/squashfs-root"
mkdir -p "$SQUASH_ROOT"
fakeroot -- bash -c '
    set -euo pipefail
    tar -xf "$1" -C "$2" --exclude="./dev/*"
    mksquashfs "$2" "$3" -comp zstd -Xcompression-level 9 -noappend -quiet
' _ "$LIVE_TAR" "$SQUASH_ROOT" "$ISO_ROOT/live/filesystem.squashfs"
printf '%s' "$(du -sx --block-size=1 "$SQUASH_ROOT" | cut -f1)" \
    > "$ISO_ROOT/live/filesystem.size"

# --- Installer payload: the A/B rootfs partition image + scripts ---
# The frequently-edited scripts live on the ISO as plain files: install.sh
# and firstboot.sh are re-exec'd / copied from the mounted medium at install
# time, so iterating on them never requires a rootfs rebuild.
install -m 0644 "$ROOTFS_IMG" "$ISO_ROOT/installer/rootfs.raw.zst"
install -m 0600 firstboot/machine.conf.example "$ISO_ROOT/installer/machine.conf"
install -m 0755 installer/install.sh "$ISO_ROOT/installer/install.sh"
cp -r installer/installer.d "$ISO_ROOT/installer/"
chmod 0755 "$ISO_ROOT/installer/installer.d"/*.sh
install -m 0755 firstboot/firstboot.sh "$ISO_ROOT/installer/firstboot.sh"
cp -r firstboot/firstboot.d "$ISO_ROOT/installer/"
chmod 0755 "$ISO_ROOT/installer/firstboot.d"/*.sh

# --- k3s air-gap images (copied to /data by install.sh) ---
# vendor/ keeps every version ever fetched, so name the pinned file exactly —
# these are ~217 MB each.
K3S_IMAGES="vendor/k3s/$ARCH/images/k3s-airgap-images-$ARCH-$K3S_VERSION.tar.zst"
if [ -f "$K3S_IMAGES" ]; then
    mkdir -p "$ISO_ROOT/k3s-images"
    cp "$K3S_IMAGES" "$ISO_ROOT/k3s-images/"
    echo "Bundled k3s air-gap images ($K3S_VERSION)."
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
{
cat <<EOF
$GRUB_SERIAL

set timeout=10
set default=0

search --file --set=root /live/filesystem.squashfs

menuentry "Install Appliance (unattended — ERASES the target disk)" {
    linux  /boot/vmlinuz boot=live $CONSOLE_DEFAULT
    initrd /boot/initrd.img
}
EOF
# Both arches default to display now; serial is the alternate for whenever
# headless/serial testing comes back into scope (see the note above).
cat <<EOF

menuentry "Install Appliance (serial console, unattended)" {
    linux  /boot/vmlinuz boot=live $CONSOLE_SERIAL
    initrd /boot/initrd.img
}
EOF
} > "$ISO_ROOT/EFI/ubuntu/grub.cfg"
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
