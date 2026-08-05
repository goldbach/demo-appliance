VERSION     ?= $(shell git describe --tags --always 2>/dev/null || echo dev)
K3S_VERSION := v1.36.2+k3s1
ARCH        ?= $(shell dpkg --print-architecture)
BUILD       := build

# kernel / uname -m spelling of ARCH
ifeq ($(ARCH),amd64)
ARCH_KERNEL := x86_64
else ifeq ($(ARCH),arm64)
ARCH_KERNEL := aarch64
else
$(error unsupported ARCH '$(ARCH)' (amd64|arm64))
endif

export K3S_VERSION ARCH ARCH_KERNEL

# --- File targets (make skips when output exists and is newer than deps) ---

# A failed recipe must not leave a partial output that later runs treat as
# up to date (e.g. a truncated tarball from an interrupted mmdebstrap).
.DELETE_ON_ERROR:

APPLIANCE_BASE_TAR := $(BUILD)/appliance-base-rootfs-$(ARCH).tar.zst
ROOTFS_TAR         := $(BUILD)/appliance-rootfs-$(ARCH).tar.zst
LIVE_BASE_TAR      := $(BUILD)/live-base-rootfs-$(ARCH).tar.zst
LIVE_TAR           := $(BUILD)/live-rootfs-$(ARCH).tar.zst
ROOTFS_RAW         := $(BUILD)/rootfs-$(ARCH).raw
ROOTFS_ZST         := $(ROOTFS_RAW).zst
ISO                := $(BUILD)/appliance-$(ARCH).iso
# Vendored downloads carry K3S_VERSION in their filenames: the artifact IS the
# stamp, so a version bump makes these targets "missing" and triggers a fetch.
# Old versions stay on disk, so switching back and forth costs no re-download.
K3S_BIN            := vendor/k3s/$(ARCH)/bin/k3s-$(K3S_VERSION)
K3S_IMAGES         := vendor/k3s/$(ARCH)/images/k3s-airgap-images-$(ARCH)-$(K3S_VERSION).tar.zst

# Scripts/units that get baked into the images or packed onto the ISO —
# editing them must trigger the right rebuild/repack. The rootfs overlay and
# step scripts hang off $(ROOTFS_TAR) only: they are applied by the fast
# customization layer, so touching them stays on the fast path.
ROOTFS_OVERLAY := $(shell find rootfs/overlay -type f 2>/dev/null)
ROOTFS_STEPS   := $(wildcard rootfs/build-rootfs.d/*.sh)
LIVE_OVERLAY   := $(shell find live/overlay -type f 2>/dev/null)
LIVE_STEPS     := $(wildcard live/build-live.d/*.sh)

.PHONY: all deps fetch live-base live base rootfs image iso iso-info clean distclean clean-iso clean-live-base clean-live clean-base clean-rootfs boot boot-headless boot-proxmox

all: iso

# one-time host setup (build tools; run again after the list changes)
deps:
	sudo ./scripts/install-build-deps.sh

# The version lives in the filenames, so a K3S_VERSION bump makes these targets
# missing and re-fetches, with no stamp file involved.
#
# fetch-k3s.sh always writes both outputs, which is what settles this rule after
# a single run — keep it that way if you touch it. Editing the script re-fetches
# (~12s) and cascades a payload/image/ISO rebuild, the price of catching a change
# to what gets fetched.
$(K3S_BIN) $(K3S_IMAGES) &: scripts/fetch-k3s.sh
	./scripts/fetch-k3s.sh

# Slow half: mmdebstrap from the network, fed only by the package list and the
# dpkg excludes, so a K3S_VERSION bump stays on the fast path below.
$(APPLIANCE_BASE_TAR): scripts/build-base-rootfs.sh
	./scripts/build-base-rootfs.sh

# Fast half: no network, seconds. Everything appliance-specific lands here,
# including the vendored k3s binary (build-rootfs.d/05-vendor.sh).
$(ROOTFS_TAR): $(APPLIANCE_BASE_TAR) $(K3S_BIN) $(ROOTFS_OVERLAY) $(ROOTFS_STEPS) scripts/build-rootfs.sh
	./scripts/build-rootfs.sh

# Same split as the payload above: mmdebstrap once, customization on top.
$(LIVE_BASE_TAR): scripts/build-live-base.sh
	./scripts/build-live-base.sh

$(LIVE_TAR): $(LIVE_BASE_TAR) $(LIVE_OVERLAY) $(LIVE_STEPS) scripts/build-live.sh
	./scripts/build-live.sh

$(ROOTFS_ZST): $(ROOTFS_TAR) ./scripts/make-image.sh
	./scripts/make-image.sh $< $(ROOTFS_RAW)

$(ISO): $(LIVE_TAR) $(ROOTFS_ZST) $(K3S_IMAGES) ./scripts/make-iso.sh
	./scripts/make-iso.sh $(LIVE_TAR) $(ROOTFS_ZST) $@

# Convenience aliases (for manual runs)

fetch: $(K3S_BIN) $(K3S_IMAGES)
live-base: $(LIVE_BASE_TAR)
live: $(LIVE_TAR)
base: $(APPLIANCE_BASE_TAR)
rootfs: $(ROOTFS_TAR)
image: $(ROOTFS_ZST)
iso: $(ISO)

iso-info: $(ISO)
	xorriso -indev "$<" -find / 2>/dev/null

clean:
	rm -rf $(BUILD)

# clean + drop fetched k3s artifacts (all arches) — forces a re-download
distclean: clean
	rm -rf vendor

clean-iso:
	rm -f $(ISO)

clean-live-base:
	rm -f $(LIVE_BASE_TAR)

clean-live:
	rm -f $(LIVE_TAR)

clean-base:
	rm -f $(APPLIANCE_BASE_TAR)

clean-rootfs:
	rm -f $(ROOTFS_TAR)

# --- Boot the ISO in QEMU (on macOS: run inside the builder VM, see README) ---
# accel=kvm:tcg picks KVM when the host arch matches, emulation otherwise.

ifeq ($(ARCH),amd64)
QEMU       := qemu-system-x86_64
# Secure Boot by default: smm + secure pflash, secboot firmware, Microsoft
# keys pre-enrolled in the VARS. Verify in the guest with `bootctl status`.
QEMU_OPTS  := -machine q35,smm=on,accel=kvm:tcg \
	-global driver=cfi.pflash01,property=secure,value=on
# graphical window — matches the ISO's amd64 console (tty0 last)
QEMU_UI    :=
QEMU_CDROM := -boot d -drive file=$(ISO),media=cdrom,if=ide
FW_CODE    := /usr/share/OVMF/OVMF_CODE_4M.secboot.fd
FW_VARS    := /usr/share/OVMF/OVMF_VARS_4M.ms.fd
else
# arm64 boots without Secure Boot — Ubuntu ships no MS-enrolled AAVMF vars
QEMU       := qemu-system-aarch64
QEMU_OPTS  := -machine virt,accel=kvm:tcg -cpu max
# serial on stdio — the arm64 builder VM is headless, always (not just for
# boot-headless below); pick the "serial console" grub entry manually since
# the ISO's default is now display-primary (see boot-headless's comment)
QEMU_UI    := -nographic -serial mon:stdio
# the virt machine has no IDE — attach the ISO via virtio-scsi
QEMU_CDROM := -device virtio-scsi-pci \
	-drive file=$(ISO),media=cdrom,if=none,id=cd0 \
	-device scsi-cd,drive=cd0,bootindex=0
FW_CODE    := /usr/share/AAVMF/AAVMF_CODE.fd
FW_VARS    := /usr/share/AAVMF/AAVMF_VARS.fd
endif

# 32G: 512M EFI + 2x 10G A/B slots + ~11G data
define QEMU_BOOT
	rm -f $(BUILD)/test-disk.raw && truncate -s 32G $(BUILD)/test-disk.raw
	cp -f $(FW_VARS) $(BUILD)/test-vars.fd
	$(QEMU) $(QEMU_OPTS) -m 4096 $(QEMU_UI) \
		$(QEMU_CDROM) \
		-drive file=$(BUILD)/test-disk.raw,format=raw,if=virtio \
		-drive if=pflash,format=raw,readonly=on,file=$(FW_CODE) \
		-drive if=pflash,format=raw,file=$(BUILD)/test-vars.fd
endef

boot: $(ISO)
	$(QEMU_BOOT)

# NOT READY YET — headless/serial testing is postponed (see scripts/boot-utm.sh
# and the console-default commit history for why). Both arches now default to
# the display-primary grub entry (scripts/make-iso.sh), so this needs picking
# "serial console" manually in the grub menu within its 10s timeout, on either
# arch, or there's nothing for the console to bind to.
#
# 2026-08-04: tried again on arm64 under KVM, still broken, and it is NOT the
# console-ordering flip. The live env hangs mid-boot: last output is
# "Freeing initrd memory", then no console output at all, 0 bytes ever written
# to the target disk, vCPU pegged at ~100%. Reproduced on BOTH grub entries
# (default, and "serial console" selected by injecting ESC-[B + CR over the
# serial line — confirmed applied, the kernel cmdline shows the swapped
# console= order). So the installer never starts; it is not merely invisible.
# Undiagnosed beyond that.
#
# NOTE this equally affects `make boot` on arm64, whose QEMU_UI is also
# -nographic — the working arm64 path is scripts/boot-utm.sh on the Mac host.
#
# Also still unconfirmed: QEMU_CDROM above gives the CD explicit bootindex=0
# with no bootindex on the virtio test-disk — boot-utm.sh hit an infinite
# reinstall-loop from that exact pattern (ISO winning boot priority forever
# after install); this target likely has the same latent bug, never reached.
boot-headless: QEMU_UI := -nographic -serial mon:stdio
boot-headless: $(ISO)
	$(QEMU_BOOT)

# Throwaway Secure Boot install-test VM on a Proxmox host (amd64 only —
# Proxmox runs x86). Needs PROXMOX_HOST in the env and root ssh access.
# Uploads the ISO, boots it with pre-enrolled MS keys, and destroys the VM
# when you hit Enter after testing. Interactive dev tool, not a CI gate.
boot-proxmox: $(ISO)
ifeq ($(ARCH),amd64)
	scripts/boot-proxmox.sh $(ISO)
else
	$(error boot-proxmox requires ARCH=amd64)
endif
