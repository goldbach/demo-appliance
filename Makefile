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
ROOTFS_RAW  := $(BUILD)/rootfs-$(ARCH).raw
ROOTFS_ZST  := $(ROOTFS_RAW).zst
ISO         := $(BUILD)/appliance-$(ARCH).iso
K3S_BIN     := vendor/k3s/$(ARCH)/bin/k3s
K3S_IMAGES  := vendor/k3s/$(ARCH)/images/k3s-airgap-images-$(ARCH).tar.zst
K3S_STAMP   := vendor/k3s/$(ARCH)/.fetched-$(K3S_VERSION)

.PHONY: all deps fetch rootfs image iso iso-info clean distclean clean-iso clean-rootfs test test-secure test-deps

all: iso

# one-time host setup (build tools; run again after the list changes)
deps:
	sudo ./scripts/install-build-deps.sh

# The stamp carries K3S_VERSION in its name, so a version bump makes it
# "missing" and triggers a re-fetch (which wipes the old vendor/k3s/$(ARCH)).
$(K3S_BIN) $(K3S_IMAGES) $(K3S_STAMP) &: scripts/fetch-k3s.sh
	./scripts/fetch-k3s.sh

$(ROOTFS_TAR): $(K3S_BIN) scripts/build-rootfs.sh
	./scripts/build-rootfs.sh

$(ROOTFS_ZST): $(ROOTFS_TAR) ./scripts/make-image.sh
	./scripts/make-image.sh $< $(ROOTFS_RAW)

$(ISO): $(ROOTFS_TAR) $(K3S_IMAGES) ./scripts/make-iso.sh
	./scripts/make-iso.sh $(ROOTFS_TAR) $@

# Convenience aliases (for manual runs)

fetch: $(K3S_BIN) $(K3S_IMAGES)
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

clean-rootfs:
	rm -f $(ROOTFS_TAR)

# --- QEMU boot test (on macOS: run inside the builder VM, see README) ---
# accel=kvm:tcg picks KVM when the host arch matches, emulation otherwise.

ifeq ($(ARCH),amd64)
QEMU_PKGS  := qemu-system-x86 ovmf
QEMU       := qemu-system-x86_64
QEMU_OPTS  := -machine q35,accel=kvm:tcg
QEMU_CDROM := -boot d -drive file=$(ISO),media=cdrom,if=ide
FW_CODE    := /usr/share/OVMF/OVMF_CODE_4M.fd
FW_VARS    := /usr/share/OVMF/OVMF_VARS_4M.fd
else
QEMU_PKGS  := qemu-system-arm qemu-efi-aarch64
QEMU       := qemu-system-aarch64
QEMU_OPTS  := -machine virt,accel=kvm:tcg -cpu max
# the virt machine has no IDE — attach the ISO via virtio-scsi
QEMU_CDROM := -device virtio-scsi-pci \
	-drive file=$(ISO),media=cdrom,if=none,id=cd0 \
	-device scsi-cd,drive=cd0,bootindex=0
FW_CODE    := /usr/share/AAVMF/AAVMF_CODE.fd
FW_VARS    := /usr/share/AAVMF/AAVMF_VARS.fd
endif

test-deps:
	sudo apt-get install -y -qq $(QEMU_PKGS) 2>/dev/null

test: $(ISO) test-deps
	rm -f $(BUILD)/test-disk.raw && truncate -s 20G $(BUILD)/test-disk.raw
	cp -f $(FW_VARS) $(BUILD)/test-vars.fd
	$(QEMU) $(QEMU_OPTS) -m 4096 -nographic \
		-serial mon:stdio \
		$(QEMU_CDROM) \
		-drive file=$(BUILD)/test-disk.raw,format=raw,if=virtio \
		-drive if=pflash,format=raw,readonly=on,file=$(FW_CODE) \
		-drive if=pflash,format=raw,file=$(BUILD)/test-vars.fd

# Same as test, but with Secure Boot enabled (secboot firmware + Microsoft
# keys pre-enrolled in the VARS). Verify with `bootctl status`.
# amd64 only: Ubuntu ships no MS-enrolled AAVMF vars for arm64.
test-secure: $(ISO) test-deps
ifeq ($(ARCH),amd64)
	rm -f $(BUILD)/test-disk.raw && truncate -s 20G $(BUILD)/test-disk.raw
	cp -f /usr/share/OVMF/OVMF_VARS_4M.ms.fd $(BUILD)/test-vars.secure.fd
	$(QEMU) -machine q35,smm=on,accel=kvm:tcg -m 4096 -nographic \
		-global driver=cfi.pflash01,property=secure,value=on \
		-serial mon:stdio \
		$(QEMU_CDROM) \
		-drive file=$(BUILD)/test-disk.raw,format=raw,if=virtio \
		-drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd \
		-drive if=pflash,format=raw,file=$(BUILD)/test-vars.secure.fd
else
	$(error test-secure requires ARCH=amd64)
endif
