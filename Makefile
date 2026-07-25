VERSION     ?= $(shell git describe --tags --always 2>/dev/null || echo dev)
K3S_VERSION ?= v1.36.2+k3s1
BUILD       := build

export K3S_VERSION

# --- File targets (make skips when output exists and is newer than deps) ---

ROOTFS_TAR  := $(BUILD)/mydistro-rootfs.tar
ROOTFS_RAW  := $(BUILD)/rootfs.raw
ROOTFS_ZST  := $(ROOTFS_RAW).zst
ISO         := $(BUILD)/mydistro.iso

.PHONY: all rootfs image iso iso-info clean clean-iso lima-iso lima-image lima-rootfs lima-shell lima-iso-info lima-start lima-test

all: iso

$(ROOTFS_TAR): scripts/build-rootfs.sh
	./scripts/build-rootfs.sh

$(ROOTFS_ZST): $(ROOTFS_TAR) ./scripts/make-image.sh
	./scripts/make-image.sh $< $(ROOTFS_RAW)

$(ISO): $(ROOTFS_ZST) $(ROOTFS_TAR) ./scripts/make-iso.sh
	./scripts/make-iso.sh $< $(ROOTFS_TAR) $@

# Convenience aliases (for manual runs)

rootfs: $(ROOTFS_TAR)
image: $(ROOTFS_ZST)
iso: $(ISO)

iso-info: $(ISO)
	xorriso -indev "$<" -find / 2>/dev/null

clean:
	rm -rf $(BUILD)

clean-iso:
	rm -f $(ISO)

# --- Lima targets (ARM64 VM with Rosetta for amd64) ---

LIMA := limactl
LIMA_NAME := builder

lima-iso: | lima-start
	$(LIMA) shell --workdir /work $(LIMA_NAME) -- make iso K3S_VERSION=$(K3S_VERSION) VERSION=$(VERSION)

lima-image: | lima-start
	$(LIMA) shell --workdir /work $(LIMA_NAME) -- make image K3S_VERSION=$(K3S_VERSION) VERSION=$(VERSION)

lima-rootfs: | lima-start
	$(LIMA) shell --workdir /work $(LIMA_NAME) -- make rootfs K3S_VERSION=$(K3S_VERSION)

lima-shell: | lima-start
	$(LIMA) shell --workdir /work $(LIMA_NAME)

lima-iso-info: | lima-start
	$(LIMA) shell --workdir /work $(LIMA_NAME) -- make iso-info K3S_VERSION=$(K3S_VERSION) VERSION=$(VERSION)

lima-test: lima-iso | lima-start
	$(LIMA) shell --workdir /work $(LIMA_NAME) -- bash -c '\
		sudo apt-get install -y -qq qemu-system-x86 ovmf 2>/dev/null && \
		rm -f build/test-disk.raw && truncate -s 20G build/test-disk.raw && \
		cp -f /usr/share/OVMF/OVMF_VARS_4M.fd build/OVMF_VARS.fd && \
		qemu-system-x86_64 -machine q35 -m 4096 -nographic \
			-serial mon:stdio \
			-boot d \
			-drive file=build/mydistro.iso,media=cdrom,if=ide \
			-drive file=build/test-disk.raw,format=raw,if=virtio \
			-drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
			-drive if=pflash,format=raw,file=build/OVMF_VARS.fd'

lima-start:
	$(LIMA) start builder --tty=false 2>/dev/null || $(LIMA) start builder.yaml --tty=false 2>/dev/null || true
