#!/bin/bash
# Downloads the k3s binary and air-gap image tarball for a pinned version.
# Run this before `make base`. Output lands in vendor/k3s/$ARCH/, from where the
# two halves take different routes: build-base-rootfs.sh copies the *binary*
# into the base rootfs, while make-iso.sh puts the *images* on the ISO as plain
# files (installer.d/60-airgap.sh then writes them to /data). Air-gap images are
# deliberately never baked into a rootfs — see TODO.md.
#
# Usage: K3S_VERSION=v1.30.2+k3s1 [ARCH=arm64] ./scripts/fetch-k3s.sh
set -euo pipefail

K3S_VERSION="${K3S_VERSION:?set K3S_VERSION e.g. v1.30.2+k3s1}"
ARCH="${ARCH:-$(dpkg --print-architecture)}"
BASE_URL="https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION}"
VENDOR="vendor/k3s/$ARCH"

# k3s release assets carry the arch suffix everywhere except the amd64 binary
case "$ARCH" in
    amd64) BIN_ASSET=k3s ;;
    arm64) BIN_ASSET=k3s-arm64 ;;
    *) echo "[fetch-k3s] ERROR: unsupported ARCH '$ARCH' (amd64|arm64)" >&2; exit 1 ;;
esac

log() { echo "[fetch-k3s] $*"; }

# Version stamp: skip when this exact version is already fetched; anything
# else (other version, partial fetch) is wiped and re-fetched.
STAMP="$VENDOR/.fetched-$K3S_VERSION"
if [[ -f "$STAMP" ]]; then
    log "Already fetched $K3S_VERSION ($ARCH), skipping. Delete $VENDOR to force re-fetch."
    exit 0
fi

rm -rf "$VENDOR"
mkdir -p "$VENDOR/bin" "$VENDOR/images"

log "Version: $K3S_VERSION ($ARCH)"

# Download everything flat into $VENDOR so sha256sum can find files by name
log "Fetching checksums..."
curl -fsSL "$BASE_URL/sha256sum-$ARCH.txt" -o "$VENDOR/sha256sum-$ARCH.txt"

log "Fetching k3s binary..."
curl -fsSL "$BASE_URL/$BIN_ASSET" -o "$VENDOR/$BIN_ASSET"

log "Fetching air-gap images..."
curl -fsSL "$BASE_URL/k3s-airgap-images-$ARCH.tar.zst" \
    -o "$VENDOR/k3s-airgap-images-$ARCH.tar.zst"

# Verify before moving anything into place
log "Verifying checksums..."
(cd "$VENDOR" && sha256sum --check --ignore-missing "sha256sum-$ARCH.txt")

# Organise into subdirs for rootfs copy and ISO build
chmod +x "$VENDOR/$BIN_ASSET"
mv "$VENDOR/$BIN_ASSET"                           "$VENDOR/bin/k3s"
mv "$VENDOR/k3s-airgap-images-$ARCH.tar.zst"     "$VENDOR/images/"

touch "$STAMP"

log "Done."
log "  bin/k3s                                   → baked into rootfs at /usr/local/bin/k3s"
log "  images/k3s-airgap-images-$ARCH.tar.zst   → bundled on ISO, written to /data/k3s-images/"
