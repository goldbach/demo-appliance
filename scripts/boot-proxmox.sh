#!/usr/bin/env bash
#
# boot-proxmox.sh — install-test the appliance ISO in a throwaway Proxmox VM
# under Secure Boot.
#
# Creates a VM on $PROXMOX_HOST (driven via ssh root@host + qm), boots it
# from the uploaded ISO and leaves the interactive install (disk confirm) to
# you in the Proxmox web console. The in-guest reboot at the end of the
# install stays inside the same VM, so the installed system then boots from
# disk under full Secure Boot enforcement — verifying the target OS boot
# chain, not just the ISO's. When you're done, press Enter here and the VM
# is destroyed again.
#
# What enforces Secure Boot in the VM config:
#   - machine q35 + bios ovmf: Proxmox runs the SMM-enabled OVMF build with
#     the protected pflash setup (same firmware family as `make boot`).
#   - efidisk0 ...,efitype=4m,pre-enrolled-keys=1: EFI vars disk pre-enrolled
#     with the Microsoft UEFI CA certs and SecureBoot=enabled. Without
#     enrolled keys the firmware is in setup mode and enforces nothing.
#
# Usage:
#   PROXMOX_HOST=<host> boot-proxmox.sh <iso>
#
# Tunables (env): PROXMOX_VMID (default: auto-allocated), PROXMOX_ISO_STORAGE
#   (default local), PROXMOX_DISK_STORAGE (default local-lvm), PROXMOX_BRIDGE
#   (default vmbr0), VM_CORES (default 4), VM_MEM_MB (default 8192),
#   VM_DISK_GB (default 32 — 512M EFI + 2x 10G A/B slots + data).
#
set -euo pipefail

ISO="${1:-}"
if [ -z "$ISO" ] || [ ! -f "$ISO" ]; then
  echo "usage: PROXMOX_HOST=<host> boot-proxmox.sh <iso>" >&2
  exit 2
fi

if [ -z "${PROXMOX_HOST:-}" ]; then
  echo "ERROR: PROXMOX_HOST is not set" >&2
  exit 2
fi

echo "Using Proxmox host: $PROXMOX_HOST"
echo "(tip: passwordless runs need your ssh key in root@$PROXMOX_HOST's" \
     "authorized_keys - e.g. ssh-copy-id root@$PROXMOX_HOST)"

ISO_STORAGE="${PROXMOX_ISO_STORAGE:-local}"
DISK_STORAGE="${PROXMOX_DISK_STORAGE:-local-lvm}"
BRIDGE="${PROXMOX_BRIDGE:-vmbr0}"

# Namespace the uploaded ISO per local user, so devs sharing a Proxmox host
# don't overwrite each other's ISO. Sanitized to lowercase alphanumerics and
# hyphens since Proxmox VM names must be DNS-like (and it keeps the remote
# ISO filename shell-safe).
DEV_USER="$(printf '%s' "${USER:-$(id -un)}" \
  | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//;s/-*$//')"
DEV_USER="${DEV_USER:-dev}"
REMOTE_ISO="$DEV_USER-$(basename "$ISO")"

# Every run gets its own uniquely named VM, so the same dev can run several
# test instances concurrently. The random suffix is only for humans telling
# instances apart in the UI - cleanup tracks the VMID this run created, and
# never touches other VMs. (od instead of tr over /dev/urandom: an early-
# exiting pipe consumer would SIGPIPE-kill the script under pipefail.)
VM_NAME="appliance-test-$DEV_USER-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"

pve() {
  ssh "root@$PROXMOX_HOST" "$@"
}

# Warn about (but never touch) leftover test VMs from earlier runs that
# didn't get cleaned up - other instances may be in active use, so removal
# is a manual decision: qm destroy <id> --purge --destroy-unreferenced-disks
leftovers="$(pve "qm list" | awk -v p="appliance-test-$DEV_USER-" 'index($2, p)==1 {print "  " $1 "  " $2}')"
if [ -n "$leftovers" ]; then
  echo "NOTE: existing $DEV_USER test VMs on $PROXMOX_HOST (not touched):"
  echo "$leftovers"
fi

VMID="${PROXMOX_VMID:-$(pve "pvesh get /cluster/nextid")}"

# rsync skips the transfer when size+mtime already match the remote copy,
# delta-transfers only changed blocks against the previous upload otherwise,
# and -P keeps partial transfers so an interrupted upload resumes. The ISO
# deliberately stays on the host after the run (bounded at one per dev) - it
# is the delta basis that makes the next upload cheap.
echo "Uploading $REMOTE_ISO to $PROXMOX_HOST..."
rsync -P "$ISO" "root@$PROXMOX_HOST:/var/lib/vz/template/iso/$REMOTE_ISO"

# From here on the VM exists: destroy it on any exit (Enter, Ctrl-C, or a
# failure), so unique-named instances never pile up as orphans.
cleanup() {
  echo "Destroying VM $VMID ($VM_NAME)..."
  pve "qm stop $VMID --timeout 30" >/dev/null 2>&1 || true
  # || true: if qm create half-failed there may be nothing to destroy, and
  # the trap must not turn that into a confusing secondary error.
  pve "qm destroy $VMID --purge --destroy-unreferenced-disks" || true
}

# Boot order relies on OVMF fallthrough: on the first boot the empty scsi0
# disk is not bootable, so firmware falls through to the installer CD; after
# the in-guest reboot at the end of the install, the now-bootable disk wins
# and the installed system comes up (still under Secure Boot).
echo "Creating VM $VMID ($VM_NAME)..."
trap cleanup EXIT
pve "qm create $VMID \
  --name $VM_NAME \
  --machine q35 \
  --bios ovmf \
  --efidisk0 $DISK_STORAGE:1,efitype=4m,pre-enrolled-keys=1 \
  --scsihw virtio-scsi-pci \
  --scsi0 $DISK_STORAGE:${VM_DISK_GB:-32} \
  --ide2 $ISO_STORAGE:iso/$REMOTE_ISO,media=cdrom \
  --boot order='scsi0;ide2' \
  --cpu host \
  --cores ${VM_CORES:-4} \
  --memory ${VM_MEM_MB:-8192} \
  --net0 virtio,bridge=$BRIDGE \
  --ostype l26 \
  --vga virtio"

pve "qm start $VMID"

echo ""
echo "VM $VMID is booting the ISO under Secure Boot."
echo "Open the console to drive the interactive install steps:"
echo ""
echo "  https://$PROXMOX_HOST:8006/#v1:0:=qemu/$VMID"
echo ""
read -r -p "Press Enter here when done to stop and destroy the VM... "
