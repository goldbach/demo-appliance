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

ROOTFS_TAR  := $(BUILD)/appliance-rootfs-$(ARCH).tar.zst
LIVE_TAR    := $(BUILD)/live-rootfs-$(ARCH).tar.zst
ROOTFS_RAW  := $(BUILD)/rootfs-$(ARCH).raw
ROOTFS_ZST  := $(ROOTFS_RAW).zst
ISO         := $(BUILD)/appliance-$(ARCH).iso
K3S_BIN     := vendor/k3s/$(ARCH)/bin/k3s
K3S_IMAGES  := vendor/k3s/$(ARCH)/images/k3s-airgap-images-$(ARCH).tar.zst
K3S_STAMP   := vendor/k3s/$(ARCH)/.fetched-$(K3S_VERSION)

# Scripts/units that get baked into the images or packed onto the ISO —
# editing them must trigger the right rebuild/repack.
PAYLOAD_UNITS := units/firstboot.service units/k3s-server.service units/k3s-agent.service
ISO_SCRIPTS   := installer/install.sh $(wildcard installer/installer.d/*.sh) \
                 firstboot/firstboot.sh $(wildcard firstboot/firstboot.d/*.sh) \
                 firstboot/machine.conf.example

.PHONY: all deps fetch live rootfs image iso iso-info clean distclean clean-iso clean-live clean-rootfs boot boot-headless

all: iso

# one-time host setup (build tools; run again after the list changes)
deps:
	sudo ./scripts/install-build-deps.sh

# The stamp carries K3S_VERSION in its name, so a version bump makes it
# "missing" and triggers a re-fetch (which wipes the old vendor/k3s/$(ARCH)).
$(K3S_BIN) $(K3S_IMAGES) $(K3S_STAMP) &: scripts/fetch-k3s.sh
	./scripts/fetch-k3s.sh

$(ROOTFS_TAR): $(K3S_BIN) $(PAYLOAD_UNITS) scripts/build-rootfs.sh
	./scripts/build-rootfs.sh

$(LIVE_TAR): installer/installer-run.sh units/installer.service scripts/build-live.sh
	./scripts/build-live.sh

$(ROOTFS_ZST): $(ROOTFS_TAR) ./scripts/make-image.sh
	./scripts/make-image.sh $< $(ROOTFS_RAW)

$(ISO): $(LIVE_TAR) $(ROOTFS_ZST) $(K3S_IMAGES) $(ISO_SCRIPTS) ./scripts/make-iso.sh
	./scripts/make-iso.sh $(LIVE_TAR) $(ROOTFS_ZST) $@

# Convenience aliases (for manual runs)

fetch: $(K3S_BIN) $(K3S_IMAGES)
live: $(LIVE_TAR)
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

clean-live:
	rm -f $(LIVE_TAR)

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
# serial on stdio — the arm64 builder VM is headless
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

# Serial console on stdio, no window. On amd64 pick the "serial console"
# entry in the grub menu (the menu shows on serial too); arm64 is
# serial-primary already.
boot-headless: QEMU_UI := -nographic -serial mon:stdio
boot-headless: $(ISO)
	$(QEMU_BOOT)
