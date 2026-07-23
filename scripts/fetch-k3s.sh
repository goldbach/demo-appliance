#!/bin/bash
# Downloads the k3s binary and air-gap image tarball for a pinned version.
# Run this before `make rootfs`. Output lands in vendor/k3s/ which mkosi
# picks up via ExtraTrees, and the ISO build picks up images separately.
#
# Usage: K3S_VERSION=v1.30.2+k3s1 ./scripts/fetch-k3s.sh
set -euo pipefail

K3S_VERSION="${K3S_VERSION:?set K3S_VERSION e.g. v1.30.2+k3s1}"
ARCH=amd64
BASE_URL="https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION}"
VENDOR="vendor/k3s"

mkdir -p "$VENDOR/bin" "$VENDOR/images"

log() { echo "[fetch-k3s] $*"; }

log "Version: $K3S_VERSION"

# --- Checksums first so we can verify everything ---
log "Fetching checksums..."
curl -fsSL "$BASE_URL/sha256sum-$ARCH.txt" -o "$VENDOR/sha256sum-$ARCH.txt"

# --- Binary ---
log "Fetching k3s binary..."
curl -fsSL "$BASE_URL/k3s" -o "$VENDOR/bin/k3s"
chmod +x "$VENDOR/bin/k3s"

# --- Air-gap images ---
# These are NOT baked into the rootfs (too large). The ISO build picks them
# up from vendor/k3s/images/ and the installer writes them to /data/k3s-images/.
# firstboot.sh imports them into k3s on first boot.
log "Fetching air-gap images..."
curl -fsSL "$BASE_URL/k3s-airgap-images-$ARCH.tar.zst" \
    -o "$VENDOR/images/k3s-airgap-images-$ARCH.tar.zst"

# --- Verify ---
log "Verifying checksums..."
(cd "$VENDOR" && sha256sum --check --ignore-missing "sha256sum-$ARCH.txt")

log "Done. Artifacts in $VENDOR/"
log "  bin/k3s                              → baked into rootfs at /usr/local/bin/k3s"
log "  images/k3s-airgap-images-$ARCH.tar.zst → bundled on ISO, written to /data/k3s-images/"
