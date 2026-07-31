#!/usr/bin/env bash
#
# boot-utm.sh — install-test the appliance ISO in a throwaway local UTM VM.
#
# Local equivalent of boot-proxmox.sh, for Apple Silicon Macs: no Secure Boot
# semantics here (there's no Microsoft-key-enrollment concept to emulate for
# arm64 UEFI the way boot-proxmox.sh sets up for amd64) — this just boots the
# ISO under UTM's QEMU backend (Virtualization.framework-accelerated) so you
# can eyeball the installer + firstboot run without leaving your Mac.
#
# Must run directly on the Mac host, NOT inside `limactl shell builder`:
# UTM.app / utmctl are host-only GUI-app tooling with no path from the Lima
# guest (unlike boot-proxmox.sh, which reaches Proxmox over a real network
# connection the guest also has). This script is deliberately not a `make`
# target for the same reason — the Makefile's shell assumptions (dpkg,
# mmdebstrap, etc.) are Linux-guest-only.
#
# utmctl has no `create` subcommand (utmapp/UTM#6691), so the VM is created
# via UTM's AppleScript scripting interface instead, with a display attached;
# utmctl handles start/stop/delete once it exists, and the VM's console shows
# in UTM's own window. (An earlier version of this script drove the arm64
# ISO's serial console instead via a pty — utmctl's `attach` subcommand turned
# out to be a no-op on UTM 4.7.5 ["attach command is not implemented yet!"],
# so make-iso.sh now offers a "(display console, unattended)" grub entry for
# this VM to select, alongside the still-default serial one.)
#
# Usage:
#   ./scripts/boot-utm.sh <iso>
#
# Tunables (env): VM_MEM_MB (default 4096), VM_CORES (default 4),
#   VM_DISK_MB (default 32768 — 512M EFI + 2x 10G A/B slots + data, MiB
#   here vs. boot-proxmox.sh's VM_DISK_GB since that's the unit UTM's
#   scripting interface takes).
#
set -euo pipefail

ISO="${1:-}"
if [ -z "$ISO" ] || [ ! -f "$ISO" ]; then
  echo "usage: ./scripts/boot-utm.sh <iso>" >&2
  exit 2
fi
ISO="$(cd "$(dirname "$ISO")" && pwd)/$(basename "$ISO")"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "ERROR: boot-utm.sh runs on the Mac host directly — not inside 'limactl shell builder'." >&2
  exit 2
fi

UTMCTL=/Applications/UTM.app/Contents/MacOS/utmctl
[ -x "$UTMCTL" ] || { echo "ERROR: UTM.app not found at /Applications/UTM.app" >&2; exit 2; }

# UTM on Apple Silicon only accelerates the host's own architecture
# (Virtualization.framework); an amd64 guest here would run under QEMU's
# TCG software emulation with no Rosetta-style speedup (Rosetta only
# translates Linux userspace binaries inside Lima, not whole-system QEMU
# emulation) — impractically slow. Use `make boot`/`boot-headless` inside
# the builder VM for amd64, or boot-proxmox.sh on real x86 hardware.
case "$(basename "$ISO")" in
  *arm64*) ARCH=aarch64 ;;
  *amd64*)
    echo "ERROR: boot-utm.sh only supports the arm64 ISO — an amd64 guest" >&2
    echo "       under UTM on Apple Silicon has no acceleration and is" >&2
    echo "       impractically slow. Use 'make boot'/'boot-headless' in the" >&2
    echo "       Lima builder VM, or boot-proxmox.sh on real x86 hardware." >&2
    exit 2
    ;;
  *)
    echo "ERROR: can't infer arch from ISO filename: $ISO" >&2
    exit 2
    ;;
esac

VM_MEM_MB="${VM_MEM_MB:-4096}"
VM_CORES="${VM_CORES:-4}"
VM_DISK_MB="${VM_DISK_MB:-32768}"

# Namespaced + randomized per run, same reasoning as boot-proxmox.sh: several
# devs (or several concurrent runs by one dev) shouldn't collide or clobber
# each other's throwaway VM.
DEV_USER="$(printf '%s' "${USER:-$(id -un)}" \
  | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//;s/-*$//')"
DEV_USER="${DEV_USER:-dev}"
VM_NAME="appliance-test-$DEV_USER-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"

# Warn about (but never touch) leftover test VMs from earlier runs that
# didn't get cleaned up — mirrors boot-proxmox.sh's leftover check.
leftovers="$("$UTMCTL" list 2>/dev/null | awk -v p="appliance-test-$DEV_USER-" 'index($0, p) > 0')"
if [ -n "$leftovers" ]; then
  echo "NOTE: existing $DEV_USER test VMs in UTM (not touched):"
  echo "$leftovers"
fi

# Network interfaces are left unspecified so UTM applies its own default
# (Shared/NAT) — this is just an installer smoke test, not a cluster-join
# test, so exact network config isn't load-bearing here.
#
# A display is attached because the arm64 ISO's grub menu now offers a
# "(display console, unattended)" entry alongside the default serial one
# (make-iso.sh) — without a display device UTM starts the VM with -vga none
# and there's nothing to see. Plain virtio-gpu-pci, not the -gl (OpenGL
# passthrough) variant some UTM scripting examples use: this console is pure
# text output, no 3D/compositor need, and GL passthrough depends on the
# host's SPICE/EGL pipeline actually working — needless fragility here.
#
# Disk listed BEFORE the ISO in `drives`, matching boot-proxmox.sh's
# disk-first/CD-second order: UTM assigns qemu bootindex by drive-list
# position, and unlike Proxmox's OVMF, this UTM build doesn't let
# grub-install's runtime NVRAM BootOrder edit override an ISO-first
# bootindex — an ISO-first VM just reboots back into the installer forever
# after a successful install (confirmed: install completes, reboots, lands
# back on "BdsDxe: starting Boot0001 ... USB HARDDRIVE", loops indefinitely).
# Disk-first relies on plain OVMF fallthrough instead (empty disk isn't
# bootable → falls through to the ISO on the first boot only; once the disk
# has a real bootloader, it wins on every later boot) — the same mechanism
# boot-proxmox.sh already depends on, no NVRAM-priority assumption needed.
echo "Creating UTM VM $VM_NAME..."
VM_ID="$(osascript <<EOF
tell application "UTM"
    set isoFile to POSIX file "$ISO"
    set newVM to make new virtual machine with properties {backend:qemu, configuration:{name:"$VM_NAME", architecture:"$ARCH", memory:$VM_MEM_MB, cpu cores:$VM_CORES, drives:{{guest size:$VM_DISK_MB}, {removable:true, source:isoFile}}, displays:{{hardware:"virtio-gpu-pci"}}}}
    return id of newVM
end tell
EOF
)"
if [ -z "$VM_ID" ]; then
  echo "ERROR: UTM did not return a VM id. If this is the first run, check" >&2
  echo "       System Settings > Privacy & Security > Automation and allow" >&2
  echo "       this terminal app to control UTM." >&2
  exit 1
fi

# From here on the VM exists: stop + delete it on any exit (Ctrl-C, the VM
# shutting itself down, or a failure), so throwaway VMs never pile up.
cleanup() {
  echo ""
  echo "Stopping and deleting VM $VM_NAME ($VM_ID)..."
  "$UTMCTL" stop --force "$VM_ID" >/dev/null 2>&1 || true
  "$UTMCTL" delete "$VM_ID" || true
}
trap cleanup EXIT

echo "Starting $VM_NAME (UTM window should open automatically)..."
"$UTMCTL" start "$VM_ID"

echo ""
echo "In the UTM window's grub menu, the default entry is still serial-only —"
echo "arrow down to \"Install Appliance (display console, unattended)\" and"
echo "press Enter. The install itself is unattended (a 5s Ctrl-C window, then"
echo "it proceeds and erases the target disk) — this just gives you a"
echo "graphical view of it instead of a serial one."
echo ""
read -r -p "Press Enter here when done to stop and destroy the VM... "
