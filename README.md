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
limactl shell builder                 # drops you into the same directory
sudo ./scripts/install-build-deps.sh  # one-time, inside the VM
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
make iso              # full pipeline: fetch → rootfs → image → iso
make rootfs           # just the rootfs tarball
make test             # boot the ISO in QEMU (UEFI)
make test-secure      # same with Secure Boot enabled (amd64 only)
```

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
| `rootfs` | `mmdebstrap` creates Ubuntu rootfs tarball | `build/appliance-rootfs-<arch>.tar` |
| `image` | Packs tarball into ext4 partition image | `build/rootfs-<arch>.raw.zst` |
| `iso` | Builds Secure Boot installer ISO with GRUB + live-boot | `build/appliance-<arch>.iso` |

## Configuration

| File | Purpose |
|------|---------|
| `Makefile` | Build targets and package list |
| `builder.yaml` | Lima VM config (ARM64 VZ + Rosetta, 4 CPU, 8GB RAM, 40GB disk) |
| `installer/` | Disk partitioning and bootloader install |
| `firstboot/` | First-boot node configuration |
| `units/` | systemd units (k3s, installer, firstboot) |
| `sysupdate/` | A/B OTA updates via systemd-sysupdate |
