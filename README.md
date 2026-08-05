# Appliance

Minimal Ubuntu 26.04 (resolute) appliance with [k3s](https://k3s.io/), for amd64 and arm64.

## Prerequisites

**Linux (native, amd64 or arm64):**

```bash
# build deps
sudo ./scripts/install-build-deps.sh

# unprivileged chroot (needed for mmdebstrap --mode=unshare)
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $USER
```

**macOS (Apple Silicon via Lima):**

Builds never run on the Mac itself — spin up the builder VM once, then work
inside it like any Linux box:

```bash
brew install lima
limactl start --tty=false builder.yaml   # one-time: creates the VM
                                         # (takes minutes on first run —
                                         #  image download + provisioning —
                                         #  then exits; VM keeps running)
limactl shell builder                 # drops you into the same directory
make deps                             # one-time, inside the VM
```

The VM (`builder.yaml`) runs Ubuntu 26.04 arm64 on Apple Virtualization with
Rosetta binfmt for amd64 binaries. It mounts your home at the same path
(clone the repo somewhere under `~`), and provisioning sets up the
subuid/subgid ranges mmdebstrap needs.

## Building

On macOS, first shell into the builder VM from the repo directory —
everything below runs there (or on any Linux box):

```bash
limactl shell builder
```

```bash
make iso              # full pipeline: fetch → rootfs + live → image → iso
make base             # just the base rootfs tarball (stock Ubuntu only)
make rootfs           # payload rootfs tarball (base + rootfs/overlay + rootfs.d)
make live             # just the micro live (installer) rootfs tarball
make boot             # boot the ISO in QEMU (UEFI; Secure Boot on amd64)
make boot-headless    # same on serial/stdio — the ISO's default grub entry
                      # is display-primary now, so pick "serial console"
                      # manually within its 10s timeout (either arch);
                      # headless/serial is postponed for now, see boot-utm.sh
PROXMOX_HOST=<host> make boot-proxmox
                      # throwaway Secure Boot install-test VM on a Proxmox
                      # host (amd64; destroys the VM when you hit Enter)
```

**On macOS only**, there's also a local equivalent of `boot-proxmox` that
doesn't need a Proxmox host: `scripts/boot-utm.sh` creates a throwaway UTM VM
and boots the arm64 ISO in it. Unlike everything else above, run it **on the
Mac host directly, not inside `limactl shell builder`** — UTM.app/`utmctl`
have no path from the Lima guest:

```bash
./scripts/boot-utm.sh build/appliance-arm64.iso
```

No Secure Boot involved (arm64 UEFI has no MS-key-enrollment concept to
emulate here); it just boots the installer under UTM's QEMU backend so you
can watch it run without a remote host. amd64 isn't supported this way — no
acceleration for it on Apple Silicon under UTM, only usable via `make
boot*` in the builder VM or `boot-proxmox` on real x86.

Builds target the host architecture by default — arm64 inside the builder VM.
The only supported cross build is amd64 on an arm64 host (Rosetta in the
builder VM); arm64 images are always built on arm64:

```bash
make iso ARCH=amd64   # in the builder VM: cross build via Rosetta
```

## Build pipeline

| Step | Command | Output |
|------|---------|--------|
| `fetch` | Downloads k3s binary + airgap images | `vendor/k3s/<arch>/` |
| `live` | `mmdebstrap` creates the micro live rootfs (installer env) | `build/live-rootfs-<arch>.tar.zst` |
| `rootfs` | `mmdebstrap` creates the payload rootfs tarball (node OS) | `build/appliance-rootfs-<arch>.tar.zst` |
| `image` | Packs payload tarball into ext4 partition image | `build/rootfs-<arch>.raw.zst` |
| `iso` | Builds Secure Boot installer ISO | `build/appliance-<arch>.iso` |

## Who ships what

The ISO carries three things, with very different rebuild costs:

1. **Live env** (`live/filesystem.squashfs`) — a minimal rootfs that boots
   the installer: kernel, systemd, disk tools, and `installer-entrypoint.sh`
   (medium/disk discovery, unattended). Nothing k3s-related.
2. **Payload image** (`installer/rootfs.raw.zst`) — the full node OS written
   to slot A: k3s, openssh, grub, systemd units. The same image
   systemd-sysupdate writes on A/B updates.
3. **Plain-file scripts** (`installer/install.sh`, `installer/installer.d/`,
   `installer/firstboot.sh`, `installer/firstboot.d/`,
   `installer/machine.conf`) — packed onto the ISO as-is. `installer-entrypoint.sh`
   re-execs `install.sh` from the mounted medium, and the install copies the
   firstboot scripts into the target. These are the files you edit most
   often, so they are deliberately *not* baked into either rootfs.

Iteration cost by change:

| Change | Rebuild |
|--------|---------|
| firstboot / installer script | `make iso` — squashfs of the micro live + repack (fast) |
| payload unit, config file, admin user | `make rootfs` → `image` → `iso` (no mmdebstrap) |
| k3s version bump | `make fetch` → `rootfs` → `image` → `iso` (no mmdebstrap) |
| payload package | `make base` (slow, rare) → `rootfs` → `image` → `iso` |
| kernel / live tooling | `make live` → `iso` |

## Configuration

| File | Purpose |
|------|---------|
| `Makefile` | Build targets and package list |
| `builder.yaml` | Lima VM config (ARM64 VZ + Rosetta, 4 CPU, 8GB RAM, 40GB disk) |
| `installer/` | Installer entrypoint + `installer.service` + `installer.d/` install steps (disk, bootloader, config) |
| `firstboot/` | First-boot entry point + `firstboot.d/` node-setup steps (k3s role) |
| `rootfs/overlay/` | File tree copied into the payload rootfs as-is (units, hostname, networkd, presets) |
| `rootfs/rootfs.d/` | Payload customization steps, glob order (overlay copy, admin user, presets) |
| `sysupdate/` | A/B OTA updates via systemd-sysupdate |
