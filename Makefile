VERSION     ?= $(shell git describe --tags --always 2>/dev/null || echo dev)
K3S_VERSION ?= v1.36.2+k3s1
BUILD       := build

export K3S_VERSION

.PHONY: fetch rootfs image iso clean lima-iso lima-shell lima-start

# --- Native Linux targets (run inside the Lima VM) ---

fetch:
	./scripts/fetch-k3s.sh

rootfs: fetch
	mmdebstrap \
		--mode=unshare \
		--skip=check/qemu \
		--variant=minbase \
		--architectures=amd64 \
		--format=tar \
		--include="systemd systemd-resolved systemd-sysv systemd-timesyncd udev dbus \
			ca-certificates apt-transport-https \
			openssh-server \
			iproute2 iputils-ping iptables nftables bridge-utils ethtool dnsutils tcpdump socat netcat-openbsd \
			conntrack kmod nfs-common open-iscsi \
			containerd \
			grub-efi-amd64-signed shim-signed \
			curl wget vim less jq htop lsof strace bash-completion psmisc procps util-linux zstd" \
		--dpkgopt='path-exclude=/usr/share/man/*' \
		--dpkgopt='path-exclude=/usr/share/locale/*' \
		--dpkgopt='path-include=/usr/share/locale/locale.alias' \
		--dpkgopt='path-exclude=/usr/share/doc/*' \
		--customize-hook='chroot "$$1" systemctl preset-all' \
		resolute $(BUILD)/mydistro-rootfs.tar \
		"deb http://archive.ubuntu.com/ubuntu/ resolute main restricted universe multiverse"

image: rootfs
	./scripts/make-image.sh $(BUILD)/mydistro-rootfs.tar $(BUILD)/rootfs-$(VERSION).raw

iso: image
	./scripts/make-iso.sh $(BUILD)/rootfs-$(VERSION).raw.zst $(BUILD)/mydistro-rootfs.tar $(BUILD)/mydistro-$(VERSION).iso

clean:
	rm -rf $(BUILD)

# --- Lima targets (ARM64 VM with Rosetta for amd64) ---

LIMA := limactl
LIMA_NAME := builder

lima-iso: | lima-start
	$(LIMA) shell --workdir /work $(LIMA_NAME) -- make iso K3S_VERSION=$(K3S_VERSION) VERSION=$(VERSION)

lima-rootfs: | lima-start
	$(LIMA) shell --workdir /work $(LIMA_NAME) -- make rootfs K3S_VERSION=$(K3S_VERSION)

lima-shell: | lima-start
	$(LIMA) shell --workdir /work $(LIMA_NAME)

lima-start:
	$(LIMA) start builder --tty=false 2>/dev/null || $(LIMA) start builder.yaml --tty=false 2>/dev/null || true
