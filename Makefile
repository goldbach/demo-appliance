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

ROOTFS_TAR  := $(BUILD)/appliance-rootfs-$(ARCH).tar
ROOTFS_RAW  := $(BUILD)/rootfs-$(ARCH).raw
ROOTFS_ZST  := $(ROOTFS_RAW).zst
ISO         := $(BUILD)/appliance-$(ARCH).iso
K3S_BIN     := vendor/k3s/$(ARCH)/bin/k3s
K3S_IMAGES  := vendor/k3s/$(ARCH)/images/k3s-airgap-images-$(ARCH).tar.zst
K3S_STAMP   := vendor/k3s/$(ARCH)/.fetched-$(K3S_VERSION)

.PHONY: all fetch rootfs image iso iso-info clean distclean clean-iso clean-rootfs lima-iso lima-image lima-rootfs lima-shell lima-iso-info lima-start lima-test lima-test-secure

all: iso

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

# --- Lima targets (ARM64 VM with Rosetta for amd64) ---

LIMA := limactl
LIMA_NAME := builder

lima-iso: | lima-start
	$(LIMA) shell --workdir /work $(LIMA_NAME) -- make iso VERSION=$(VERSION)

lima-image: | lima-start
	$(LIMA) shell --workdir /work $(LIMA_NAME) -- make image VERSION=$(VERSION)

lima-rootfs: | lima-start
	$(LIMA) shell --workdir /work $(LIMA_NAME) -- make rootfs

lima-shell: | lima-start
	$(LIMA) shell --workdir /work $(LIMA_NAME)

lima-iso-info: | lima-start
	$(LIMA) shell --workdir /work $(LIMA_NAME) -- make iso-info VERSION=$(VERSION)

lima-test: lima-iso | lima-start
	$(LIMA) shell --workdir /work $(LIMA_NAME) -- bash -c '\
		sudo apt-get install -y -qq qemu-system-x86 ovmf 2>/dev/null && \
		rm -f build/test-disk.raw && truncate -s 20G build/test-disk.raw && \
		cp -f /usr/share/OVMF/OVMF_VARS_4M.fd build/OVMF_VARS.fd && \
		qemu-system-x86_64 -machine q35 -m 4096 -nographic \
			-serial mon:stdio \
			-boot d \
			-drive file=build/appliance.iso,media=cdrom,if=ide \
			-drive file=build/test-disk.raw,format=raw,if=virtio \
			-drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
			-drive if=pflash,format=raw,file=build/OVMF_VARS.fd'

# Same as lima-test, but with Secure Boot enabled (secboot firmware +
# Microsoft keys pre-enrolled in the VARS). Verify with `bootctl status`.
lima-test-secure: lima-iso | lima-start
	$(LIMA) shell --workdir /work $(LIMA_NAME) -- bash -c '\
		sudo apt-get install -y -qq qemu-system-x86 ovmf 2>/dev/null && \
		rm -f build/test-disk.raw && truncate -s 20G build/test-disk.raw && \
		cp -f /usr/share/OVMF/OVMF_VARS_4M.ms.fd build/OVMF_VARS.secure.fd && \
		qemu-system-x86_64 -machine q35,smm=on -m 4096 -nographic \
			-global driver=cfi.pflash01,property=secure,value=on \
			-serial mon:stdio \
			-boot d \
			-drive file=build/appliance.iso,media=cdrom,if=ide \
			-drive file=build/test-disk.raw,format=raw,if=virtio \
			-drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd \
			-drive if=pflash,format=raw,file=build/OVMF_VARS.secure.fd'

lima-start:
	$(LIMA) start builder --tty=false 2>/dev/null || $(LIMA) start builder.yaml --tty=false 2>/dev/null || true
