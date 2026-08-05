#!/bin/bash
# Install step: sanity checks before anything touches the disk. Fails fast
# with a clear message instead of dying halfway through a partial install.
set -euo pipefail

log()  { echo "[install:preflight] $*"; }
fail() { log "ERROR: $*"; exit 1; }

[ -b "$DISK" ]          || fail "$DISK is not a block device"
[ -r "$ROOTFS_IMAGE" ]  || fail "rootfs image not readable: $ROOTFS_IMAGE"

for tool in parted blockdev udevadm mkfs.fat mkfs.ext4 e2fsck resize2fs zstd; do
    command -v "$tool" >/dev/null || fail "missing tool in live env: $tool"
done

# The appliance is UEFI-only — a BIOS-booted installer would produce an
# unbootable disk (30-bootloader.sh installs EFI grub + an NVRAM boot entry)
[ -d /sys/firmware/efi ] || fail "not booted via UEFI — the appliance requires UEFI firmware"

# Target disk must not be in use
if grep -q "^$DISK" /proc/mounts; then
    fail "$DISK has mounted partitions"
fi

# Big enough for EFI + both A/B slots + at least 1 GiB data?
REQUIRED_MIB=$((1 + EFI_SIZE + ROOTFS_SIZE * 2 + 1024))
DISK_MIB=$(( $(blockdev --getsize64 "$DISK") / 1048576 ))
[ "$DISK_MIB" -ge "$REQUIRED_MIB" ] || \
    fail "$DISK is ${DISK_MIB} MiB, need at least ${REQUIRED_MIB} MiB"

# Catch a corrupt image (bad USB copy) before it is half-written to disk
log "Verifying rootfs image integrity..."
zstd -t "$ROOTFS_IMAGE" || fail "rootfs image is corrupt: $ROOTFS_IMAGE"

# Diagnostic only — not a pass/fail check. Ownership here is the live env's,
# not the target's, but a stray non-root owner is a useful signal that
# something upstream (mmdebstrap hook, ISO repack) went wrong.
log "Live env /etc ownership:"
ls -ld /etc
for f in /etc/passwd /etc/shadow /etc/gshadow /etc/sudoers; do
    [ -e "$f" ] && ls -l "$f"
done

log "OK: $DISK (${DISK_MIB} MiB), UEFI boot, payload image present"
