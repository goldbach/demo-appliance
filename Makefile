VERSION     ?= $(shell git describe --tags --always 2>/dev/null || echo dev)
K3S_VERSION ?= v1.36.2+k3s1
BUILD       := build
BUILDER_IMG := mydistro-builder

export K3S_VERSION

.PHONY: fetch rootfs image iso clean builder docker-iso docker-shell

# --- Native Linux targets (run inside the build container) ---

fetch:
	./scripts/fetch-k3s.sh

rootfs: fetch
	mkosi --directory os --output-dir ../$(BUILD) build

image: rootfs
	./scripts/make-image.sh $(BUILD)/mydistro-rootfs.tar $(BUILD)/rootfs-$(VERSION).raw

iso: image
	./scripts/make-iso.sh $(BUILD)/rootfs-$(VERSION).raw $(BUILD)/mydistro-$(VERSION).iso

clean:
	rm -rf $(BUILD)

# --- Docker targets (use these on macOS) ---

builder:
	docker build --platform linux/amd64 -f Dockerfile.builder -t $(BUILDER_IMG) .

docker-iso: builder
	docker run --rm --privileged --platform linux/amd64 \
		-v "$(PWD)":/work \
		-e K3S_VERSION=$(K3S_VERSION) \
		-e VERSION=$(VERSION) \
		$(BUILDER_IMG) \
		make iso

docker-shell: builder
	docker run --rm -it --privileged --platform linux/amd64 \
		-v "$(PWD)":/work \
		-e K3S_VERSION=$(K3S_VERSION) \
		$(BUILDER_IMG) \
		bash
