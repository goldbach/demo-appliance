#!/bin/bash
# Install step: install GRUB (Secure Boot signed) into the target.
set -euo pipefail

log() { echo "[install:bootloader] $*"; }

case "$(uname -m)" in
    x86_64)  GRUB_TARGET=x86_64-efi ;;
    aarch64) GRUB_TARGET=arm64-efi ;;
    *) log "ERROR: unsupported machine $(uname -m)" >&2; exit 1 ;;
esac

# No --no-nvram: grub-install registers an "appliance" EFI boot entry and puts
# it first in BootOrder, so the box boots from disk after install even with
# the installer medium still attached (firmware prefers removable media).
log "Installing GRUB..."
chroot /mnt grub-install \
    --target="$GRUB_TARGET" \
    --efi-directory=/boot/efi \
    --bootloader-id=appliance
chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
