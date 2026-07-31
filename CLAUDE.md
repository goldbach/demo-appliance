# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A shell-script/Makefile pipeline that builds a minimal Ubuntu 26.04 ("resolute")
appliance image bundling [k3s](https://k3s.io/), for amd64 and arm64. There is
no application source code here — everything is bash, Make, and mmdebstrap
customize-hooks. Output is a Secure Boot-capable installer ISO that partitions
a disk, writes a node OS image, and configures k3s (server or agent) on first
boot.

## Build environment

Builds never run on macOS directly.

```bash
brew install lima
limactl start --tty=false builder.yaml   # one-time VM setup
limactl shell builder                    # drops into the mirrored repo dir
make deps                                # one-time, inside the VM
```

`builder.yaml` runs Ubuntu 26.04 arm64 under Apple Virtualization with Rosetta
binfmt (for amd64 cross builds) and nested KVM (M3+/macOS 15+, for `make boot*`
to use hardware acceleration instead of slow TCG). On native Linux, skip Lima
and run `sudo ./scripts/install-build-deps.sh` + subuid/subgid setup directly
(see README).

## Common commands

```bash
make iso              # full pipeline: fetch → rootfs + live → image → iso
make rootfs           # just the payload rootfs tarball
make live             # just the micro live (installer) rootfs tarball
make fetch            # download k3s binary + airgap images (vendor/k3s/$ARCH)
make boot             # boot the built ISO in QEMU (UEFI, Secure Boot)
make boot-headless    # same, serial console (pick "serial console" grub entry on amd64)
PROXMOX_HOST=<host> make boot-proxmox   # throwaway Secure Boot VM on real Proxmox (amd64 only)

make iso ARCH=amd64   # cross build via Rosetta (only supported cross direction)
make clean            # rm -rf build/
make distclean        # clean + wipe vendor/ (forces k3s re-fetch)
```

There is no test suite. Validation is: build, then `make boot`/`make boot-headless`
(or `make boot-proxmox` for a real Secure Boot host) and watch the installer +
firstboot run to completion.

CI (`.github/workflows/`): `build.yml` runs `sudo make iso` on PRs and tags
(uploads the ISO artifact on tag pushes); `rootfs.yml` runs `make rootfs`
*without* sudo on every push to main, specifically to prove the unprivileged
`mmdebstrap --mode=unshare` path still works on GitHub runners (mirrors the
Lima builder's unprivileged-userns setup, not the sudo path).

## Architecture: two rootfs builds, not one

The ISO carries two independently-built mmdebstrap outputs plus a set of plain
files — understanding *why* they're split is the key to not breaking the
iteration-cost story:

1. **Live env** (`scripts/build-live.sh` → `live-rootfs-$ARCH.tar.zst`) — boots
   the installer. Kernel, systemd, live-boot, disk tools, signed shim/grub
   (needed only so `make-iso.sh` can extract boot binaries from this tarball).
   No k3s, no ssh, no iptables — it never touches anything the payload needs.
2. **Payload rootfs** (`scripts/build-rootfs.sh` → `appliance-rootfs-$ARCH.tar.zst`)
   → packed by `make-image.sh` into an ext4 partition image
   (`rootfs-$ARCH.raw.zst`) — this is the actual node OS: k3s binary, sshd,
   grub-efi-signed, the baked-in admin user. **This same image is what
   systemd-sysupdate writes into the inactive slot on A/B updates** — install
   and update share one artifact.
3. **Plain files on the ISO** (`installer/install.sh`, `installer/installer.d/`,
   `firstboot/firstboot.sh`, `firstboot/firstboot.d/`, `machine.conf`) — copied
   onto the ISO as-is by `make-iso.sh`, never baked into either rootfs. These
   are the files you'll edit most often, so editing them only costs an ISO
   repack (fast), not a rootfs rebuild (slow, mmdebstrap from scratch).

Rebuild cost by what you touched:

| Change | Rebuild needed |
|---|---|
| `installer/install.sh`, `installer.d/*`, `firstboot.sh`, `firstboot.d/*` | `make iso` only |
| package list / customize-hooks in `build-rootfs.sh` | `make rootfs` → `image` → `iso` |
| kernel/live tooling in `build-live.sh` | `make live` → `iso` |

## Boot flow (install → firstboot → steady state)

1. **ISO boots** → `installer.service` (gated on `boot=live` in
   `/proc/cmdline`) runs `installer/installer-run.sh`: finds the installer
   medium by looking for `live/filesystem.squashfs`, discovers non-removable
   candidate disks, confirms with the operator (or skips confirmation if
   `appliance.install=auto` is on the cmdline — but only when exactly one
   candidate disk exists), then `exec`s `install.sh <disk>`.
2. **`install.sh`** exports partition-layout vars (`EFI_SIZE`, `ROOTFS_SIZE`,
   `EFI_PART`/`ROOTFS_A`/`ROOTFS_B`/`DATA_PART`) and runs every script in
   `installer/installer.d/` in glob order:
   - `00-preflight.sh` — sanity checks (block device, UEFI-only, disk size,
     zstd image integrity) before anything touches the disk.
   - `10-partition.sh` — GPT: EFI + rootfs-a + rootfs-b + data. Only rootfs-b
     and data get formatted here; rootfs-a's filesystem comes from the image
     itself (see partition-label vs fs-label note in that file).
   - `20-rootfs.sh` — `zstd -dc | dd` the payload image into rootfs-a, grow
     it, mount at `/mnt`.
   - `30-bootloader.sh` — `chroot grub-install` (Secure Boot, no `--no-nvram`
     so it registers an EFI boot entry ahead of removable media).
   - `50-config.sh` — writes `/etc/fstab`, copies `machine.conf` to
     `/etc/appliance/`, installs the firstboot scripts into the target, enables
     `firstboot.service`.
   - `60-airgap.sh` — copies bundled k3s air-gap image tarballs to the data
     partition.
   - `90-unmount.sh` — `umount -R /mnt`.
   Then reboots.
3. **First boot of the installed system**: `firstboot.service` (gated on
   `/etc/appliance/machine.conf` existing and `firstboot-done` NOT existing)
   runs `firstboot.sh`, which sources `machine.conf` (`ROLE`, `CLUSTER_INIT`,
   `SERVER_URL`, `CLUSTER_TOKEN`) into the environment and runs
   `firstboot.d/10-k3s.sh`, which writes `/etc/rancher/k3s/config.yaml` for
   the node's role and enables `k3s-server.service` or `k3s-agent.service`.
   Firstboot then disables itself.

`k3s-server.service`/`k3s-agent.service` both use `data-dir: /data/k3s` — air-gap
images must land in `/data/k3s/agent/images`, **not** the k3s default
`/var/lib/rancher/k3s/...` (that path is per-slot rootfs and wouldn't survive
an A/B update).

## In-flight work: A/B updates

The partition layout (EFI + rootfs-a + rootfs-b + data) already exists, but the
update mechanism is only partially wired — **read `TODO.md` before touching
anything sysupdate/bootloader/rollback-related**, it has the current design
decisions and open blockers in detail. Short version of the division of
labor: slot selection is GRUB's job (`root=PARTUUID=`), staging an update is
`systemd-sysupdate`'s job (raw write to the inactive slot), fallback is a
bootloader feature GRUB doesn't have natively (unlike systemd-boot) — the glue
for grubenv-based one-shot fallback + a mark-good health check is not yet
implemented. Also unresolved: `/data` is not slot-scoped, so an OS rollback
does not roll back k3s's on-disk state — see the TODO's "Caveat: rollback is
OS-level only".

## Known temporary state (do not treat as bugs to silently fix)

- `build-rootfs.sh` bakes a fixed admin user/password (`admin`/`appliance`,
  passwordless-sudo capable, ssh password auth enabled) into every image.
  Documented as demo-phase-only in `TODO.md` ("Baked-in admin user") — don't
  "fix" this without checking that section first, there's a chosen direction.
- Root filesystem is mounted rw (`50-config.sh` fstab), not yet read-only;
  this is intentional until the `/data`-backed overlay work lands.
- SSH host keys are currently baked into the image at build time (not
  regenerated/persisted per-machine) — flagged as a TODO, not yet fixed.

## Conventions in this repo

- Every build/install/firstboot script is `set -euo pipefail` and logs via a
  `log() { echo "[prefix] $*"; }` helper with a script-specific prefix — match
  this style in new scripts rather than introducing a different logging
  convention.
- `ARCH` is always `amd64` or `arm64` (Debian arch spelling); scripts that need
  the kernel/uname spelling derive `ARCH_KERNEL` (`x86_64`/`aarch64`)
  themselves rather than accepting it as a separate input where avoidable.
- Numbered step scripts (`installer.d/NN-*.sh`, `firstboot.d/NN-*.sh`) run in
  glob order and communicate via exported shell variables set by their parent
  entry point — not via files or return values.
- mmdebstrap runs are always `--mode=unshare` (unprivileged). Don't add a step
  that requires real root inside the chroot; use `--customize-hook='chroot "$1" ...'`
  patterns already used in `build-rootfs.sh`/`build-live.sh`.
