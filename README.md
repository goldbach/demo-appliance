# Appliance

Minimal Ubuntu 26.04 (resolute) amd64 appliance with [k3s](https://k3s.io/).

## Prerequisites

**Linux (native amd64):**

```bash
# build deps
sudo ./scripts/install-build-deps.sh

# unprivileged chroot (needed for mmdebstrap --mode=unshare)
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $USER
```

**macOS (ARM64 via Lima):**

```bash
brew install limactl make
```

The Makefile uses a GNU Make 4.3+ feature (grouped targets, `&:`), which macOS's
built-in `/usr/bin/make` (3.81) can't parse — even for `lima-*` targets, since make
must parse the whole file before running anything. Put Homebrew's `make` ahead of
the system one on `PATH`:

```bash
export PATH="$(brew --prefix make)/libexec/gnubin:$PATH"
```

The Lima VM (`builder.yaml`) runs Ubuntu 26.04 on Apple Virtualization with Rosetta for amd64 translation. Dependencies are provisioned automatically.

## Building

**Linux:**

```bash
make iso          # full pipeline: fetch → rootfs → image → iso
make rootfs       # just the rootfs tarball
```

**macOS:**

```bash
make lima-iso     # full pipeline inside Lima VM
make lima-shell   # drop into the VM
```

## Build pipeline

| Step | Command | Output |
|------|---------|--------|
| `fetch` | Downloads k3s binary + airgap images | `vendor/k3s/` |
| `rootfs` | `mmdebstrap` creates Ubuntu rootfs tarball | `build/appliance-rootfs.tar` |
| `image` | Packs tarball into ext4 partition image | `build/rootfs-*.raw.zst` |
| `iso` | Builds Secure Boot installer ISO with GRUB + live-boot | `build/appliance-*.iso` |

## Configuration

| File | Purpose |
|------|---------|
| `Makefile` | Build targets and package list |
| `builder.yaml` | Lima VM config (ARM64 VZ + Rosetta, 4 CPU, 8GB RAM, 40GB disk) |
| `installer/` | Disk partitioning and bootloader install |
| `firstboot/` | First-boot node configuration |
| `units/` | systemd units (k3s, installer, firstboot) |
| `sysupdate/` | A/B OTA updates via systemd-sysupdate |
