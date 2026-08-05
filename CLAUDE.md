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
make base             # just the base rootfs tarball (Ubuntu + vendored bins)
make rootfs           # payload rootfs tarball (base + rootfs/overlay + rootfs.d)
make live-base        # just the live base tarball (Ubuntu + kernel + live-boot)
make live             # live rootfs tarball (live base + live/overlay + live.d)
make fetch            # download k3s binary + airgap images (vendor/k3s/$ARCH)
make boot             # boot the built ISO in QEMU (UEFI, Secure Boot)
make boot-headless    # same, serial console — pick "serial console" grub entry
                      # manually (either arch; ISO defaults to display now)
PROXMOX_HOST=<host> make boot-proxmox   # throwaway Secure Boot VM on real Proxmox (amd64 only)

make iso ARCH=amd64   # cross build via Rosetta (only supported cross direction)
make clean            # rm -rf build/
make distclean        # clean + wipe vendor/ (forces k3s re-fetch)
```

`scripts/boot-utm.sh <iso>` is the macOS-only local equivalent of
`boot-proxmox`: a throwaway UTM VM instead of a remote Proxmox host,
arm64-only (no acceleration for amd64 under UTM on Apple Silicon), no Secure
Boot semantics. Unlike every other command above, **run it directly on the
Mac host, not inside `limactl shell builder`** — it's not a `make` target
because it needs UTM.app/`utmctl`, which have no path from the Lima guest
(unlike `boot-proxmox`, which reaches Proxmox over the network the guest also
has). VM creation goes through UTM's AppleScript scripting interface (`utmctl`
itself has no `create` subcommand, and its `attach`/`start --attach` are
no-ops on UTM 4.7.5); it attaches a display and boots straight into the ISO's
now-default display-primary grub entry, shown in UTM's own window — no grub
navigation needed. The VM's disk must be listed before the ISO in the
AppleScript `drives:` config (bootindex order) or it reinstalls in an
infinite loop after the first successful install instead of booting the
disk — see the comment in boot-utm.sh for how that was diagnosed.

There is no test suite. Validation is: build, then boot the ISO and watch the
installer + firstboot run to completion. **Which boot target actually works
depends on the arch:**

- **amd64** — `make boot` (graphical window) or `make boot-proxmox` for a real
  Secure Boot host. These are the working paths.
- **arm64** — `scripts/boot-utm.sh <iso>`, run on the **Mac host**, not in the
  builder VM. `make boot` does *not* work here: the arm64 branch of the
  Makefile sets `QEMU_UI := -nographic`, so it is the headless path below.
- **`make boot-headless` (either arch) is NOT READY** — see the comment on the
  target in the Makefile.

Serial/headless QEMU boots hang in the *live* env, reproducibly: the kernel
stops right after `Freeing initrd memory`, nothing is written to the target
disk, and the vCPU spins at ~100%. It reproduces on both grub entries, so it
is not just the console-ordering flip. Not diagnosed further — the display
paths above work, so this is a convenience gap, not a blocker. Don't read a
headless hang as a regression in whatever you just changed: the live env is
built by `build-live-base.sh`/`build-live.sh` and is independent of the
payload layers.

CI (`.github/workflows/`): `build.yml` runs `sudo make iso` on PRs and tags
(uploads the ISO artifact on tag pushes); `rootfs.yml` runs `make rootfs`
*without* sudo on every push to main, specifically to prove the unprivileged
`mmdebstrap --mode=unshare` path still works on GitHub runners (mirrors the
Lima builder's unprivileged-userns setup, not the sudo path). Since the payload
split, `make rootfs` covers both halves: that mmdebstrap run in
`build-base-rootfs.sh`, and the fakeroot customization layer in
`build-rootfs.sh`.

## Architecture: layered rootfs builds, not one

The ISO is assembled from several independently-built pieces — understanding
*why* they're split is the key to not breaking the iteration-cost story. Every
split exists to keep a frequently-edited thing off the slow path:

1. **Live base** (`scripts/build-live-base.sh` → `live-base-rootfs-$ARCH.tar.zst`)
   — stock Ubuntu, kernel, live-boot, disk tools, signed shim/grub (the last
   needed only so `make-iso.sh` can extract boot binaries from this tarball).
   No k3s, no ssh, no iptables — it never touches anything the payload needs.
2. **Live env** (`scripts/build-live.sh` → `live-rootfs-$ARCH.tar.zst`) — the
   live base with `live/overlay/` and `live/live.d/` applied: the installer
   entry point, its unit, hostname and networkd config.
3. **Base rootfs** (`scripts/build-base-rootfs.sh` → `base-rootfs-$ARCH.tar.zst`)
   — stock Ubuntu via mmdebstrap and nothing else: no vendored binaries, no
   appliance config. Slow and network-bound. Only the package list or the dpkg
   excludes should ever rebuild it — notably **not** a `K3S_VERSION` bump.
4. **Payload rootfs** (`scripts/build-rootfs.sh` → `appliance-rootfs-$ARCH.tar.zst`)
   → packed by `make-image.sh` into an ext4 partition image
   (`rootfs-$ARCH.raw.zst`) — the base with everything that makes it an
   appliance applied on top: `rootfs/overlay/` and `rootfs/rootfs.d/`, the
   latter including the vendored k3s binary (`05-vendor.sh`). No apt, no
   network, seconds rather than minutes. **This image is also what an A/B
   update writes into the inactive slot** — install and update share one
   artifact.
The ISO itself now carries only the payload image — no plain-file scripts, no
config. `machine.conf` is written at install time by `installer.d/50-config.sh`
from a built-in default (see TODO "machine.conf: resolve from the kernel
cmdline" for why that is temporary).

Where the install and firstboot logic live follows **where it runs**, not how
it is delivered: `install.sh` + `installer.d/` are baked into the live env
(`live/overlay/usr/lib/appliance-installer/`), `firstboot.sh` + `firstboot.d/` into the
payload image (`rootfs/overlay/usr/lib/appliance/`). Both are therefore present
however the node booted — including PXE, where there is no medium to read — and
firstboot logic now travels with the rootfs, so an A/B update refreshes it.

### The customization layers

Both halves are layered the same way, and the rules below apply to each:
`rootfs/{overlay,rootfs.d}` on top of the base rootfs, `live/{overlay,live.d}`
on top of the live base.


`build-rootfs.sh` and `build-live.sh` each re-execute themselves under
`fakeroot`, extract their base tar, run their `*.d/*.sh` steps in glob order
with the rootfs dir as `$1`, and repack. Three rules there are load-bearing:

- **One `fakeroot` session wraps everything.** Same idiom, and same reason, as
  `make-image.sh` and `make-iso.sh`: extraction, the steps, and the repack must
  all see one fake-ownership database, or root-owned files silently collapse to
  the build user (the uid-501 bug, commit `9b80098`). Two `fakeroot`
  invocations would each start an empty one. For the same reason `00-overlay.sh`
  pipes the overlay through `tar --owner=0 --group=0` instead of `cp -a`, which
  would carry the checkout's ownership into the image.
- **Steps must never `chroot`** — fakeroot cannot follow one in. Use the
  `--prefix` flag that shadow-utils' `useradd`/`chpasswd` provide and
  `systemctl --root=`, both of which operate on the target tree directly. A
  side benefit: cross-arch payloads need no Rosetta binfmt in this layer at all.
- **Not a user namespace.** `unshare --user --map-auto` looks like the natural
  fit but does not work on Ubuntu 24.04+: creating an unprivileged userns
  transitions into AppArmor's `unprivileged_userns` profile, whose blanket
  `audit deny capability` blocks the `CAP_CHOWN` that extracting a rootfs needs
  (and every mount, so `/dev` and `/proc` cannot be bind-mounted in either).
  mmdebstrap escapes this only because it ships its own
  `flags=(unconfined)` profile keyed to `/usr/bin/mmdebstrap`; nothing grants
  the same to a shell script.

Adding a static file to the image is a `git add` under `rootfs/overlay/` — the
tree mirrors the target layout, so `rootfs/overlay/etc/hostname` becomes
`/etc/hostname`. Only things needing logic (chroot calls, anything derived from
`vendor/`) earn a `rootfs.d/` step. Empty directories are the one exception:
git cannot track them, so `/data` is `mkdir`ed in `00-overlay.sh`.

**Do not put the k3s air-gap image tarballs in the overlay.** They are the one
vendored artifact that deliberately never enters *any* rootfs — see the air-gap
path below and the `TODO.md` rule. Dropping a `k3s-airgap-*.tar.zst` under
`rootfs/overlay/` would bake ~200 MB into both A/B slots and into every update
artifact, for bytes that dedupe in containerd's content store anyway.

Rebuild cost by what you touched:

| Change | Rebuild needed |
|---|---|
| `live/overlay/usr/lib/appliance-installer/*` (install.sh, installer.d/*) | `make live` → `iso` (no mmdebstrap) |
| `rootfs/overlay/*` (incl. firstboot.sh, firstboot.d/*), `rootfs/rootfs.d/*` | `make rootfs` → `image` → `iso` (no mmdebstrap) |
| `K3S_VERSION` bump (re-fetch, then re-install the binary) | `make fetch` → `rootfs` → `image` → `iso` (no mmdebstrap) |
| package list / dpkg excludes in `build-base-rootfs.sh` | `make base` → `rootfs` → `image` → `iso` |
| `live/overlay/*`, `live/live.d/*` | `make live` → `iso` (no mmdebstrap) |
| kernel/live package list in `build-live-base.sh` | `make live-base` → `live` → `iso` |

## Boot flow (install → firstboot → steady state)

1. **ISO boots** → `installer.service` (gated on `boot=live` in
   `/proc/cmdline`) runs `installer/installer-entrypoint.sh`: finds the installer
   medium by looking for `live/filesystem.squashfs`, discovers non-removable
   candidate disks (dies if it's not exactly one — never guesses which disk
   to wipe), waits 5s (a Ctrl-C window for a watching operator, not a
   confirmation prompt — install is unattended by design), then `exec`s
   `install.sh <disk>`.
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
   - `50-config.sh` — writes `/etc/fstab` and `/etc/appliance/machine.conf`
     (built-in default: single-node server), enables `firstboot.service`. The
     firstboot scripts themselves are already in the image.
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

### Air-gap image path (never enters a rootfs)

The k3s binary and its air-gap images are both vendored, but they travel by
completely different routes. The binary is installed into the payload rootfs by
`rootfs.d/05-vendor.sh`; the images ride the ISO as plain files and land on
`/data`:

```
scripts/fetch-k3s.sh   →  vendor/k3s/$ARCH/images/k3s-airgap-images-$ARCH-$K3S_VERSION.tar.zst
scripts/make-iso.sh    →  /k3s-images/ on the ISO
installer.d/60-airgap  →  /data/k3s-images/        (data partition, at install)
firstboot.d/10-k3s.sh  →  /data/k3s/agent/images/  (where k3s imports them)
```

Vendored downloads carry `K3S_VERSION` in their filenames — the artifact is its
own fetch stamp, so there is no marker file to drift, and old versions stay in
`vendor/` (switching `K3S_VERSION` back and forth costs no re-download).
Because several versions coexist there, anything reading `vendor/` must name the
pinned file rather than glob: `make-iso.sh` and `rootfs.d/05-vendor.sh` both do.
`05-vendor.sh` drops the version when installing, so the appliance always has a
plain `/usr/local/bin/k3s` and the units need no version-aware paths.

The rootfs carries the k3s *binary*; `/data` carries the *images*. Because they
are ISO-plain-files, swapping the image tarballs costs an ISO repack only — no
rootfs rebuild. `TODO.md` ("k3s airgap images across updates") has the rule for
keeping them in step with a k3s version bump across an A/B update.

## In-flight work: A/B updates

The partition layout (EFI + rootfs-a + rootfs-b + data) already exists, but the
update mechanism is unbuilt — **read `TODO.md` before touching anything
A/B-update/bootloader/rollback-related**, it has the current design decisions
and open blockers in detail. Short version of the division of labor: slot
selection is the bootloader's job (`root=PARTUUID=`), staging an update means a
raw write into the inactive slot by some updater (**which one is undecided** —
systemd-sysupdate, RAUC and friends are compared in TODO.md), and fallback is a
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
- Numbered step scripts (`installer.d/NN-*.sh`, `firstboot.d/NN-*.sh`,
  `rootfs/rootfs.d/NN-*.sh`, `live/live.d/NN-*.sh`) run in glob order and communicate via exported
  shell variables set by their parent entry point — not via files or return
  values. `rootfs.d` steps additionally take the rootfs directory as `$1`,
  deliberately matching an mmdebstrap `--customize-hook` signature so a step
  can move between the base and customization layers unedited.
- mmdebstrap runs are always `--mode=unshare` (unprivileged). Don't add a step
  that requires real root inside the chroot; use `--customize-hook='chroot "$1" ...'`
  patterns already used in `build-base-rootfs.sh`/`build-live.sh`. That chroot
  is available in the mmdebstrap layers only — `rootfs.d` steps run under
  fakeroot and must use `--prefix`/`--root` flags instead.
