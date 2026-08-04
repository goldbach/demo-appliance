#!/bin/bash
# Downloads the k3s binary and air-gap image tarball for a pinned version.
# Run this before `make rootfs`. Output lands in vendor/k3s/$ARCH/, from where
# the two halves take different routes: rootfs/rootfs.d/05-vendor.sh installs
# the *binary* into the payload rootfs, while make-iso.sh puts the *images* on
# the ISO as plain files (installer.d/60-airgap.sh then writes them to /data).
# Air-gap images are deliberately never baked into a rootfs — see TODO.md.
#
# Normally invoked by make, which skips it entirely when the versioned files
# already exist. Running it directly always re-downloads — that is the way to
# force a re-fetch.
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

# The installed artifacts carry the version in their filenames, so they are
# their own stamp — no separate marker file to drift out of sync. Old versions
# are kept: switching K3S_VERSION back and forth costs no re-download.
#
# There is deliberately no "already fetched, skipping" guard here: deciding
# whether a fetch is needed is the Makefile's job (these paths are its targets,
# and it runs this recipe only when one is missing). Keeping a second copy of
# that decision in here would mean two mechanisms answering the same question.
# So this script is unconditional, which also makes running it directly the
# natural way to force a re-fetch.
BIN_OUT="$VENDOR/bin/k3s-$K3S_VERSION"
IMAGES_OUT="$VENDOR/images/k3s-airgap-images-$ARCH-$K3S_VERSION.tar.zst"

mkdir -p "$VENDOR/bin" "$VENDOR/images"

log "Version: $K3S_VERSION ($ARCH)"

# Staging dir, not $VENDOR itself: upstream asset names are fixed (sha256sum
# looks files up by name) but $VENDOR now holds several versions side by side,
# so downloading flat into it would collide. A partial or failed download is
# also discarded here rather than left half-written next to good artifacts.
WORK=$(mktemp -d "${TMPDIR:-/var/tmp}/fetch-k3s.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

log "Fetching checksums..."
curl -fsSL "$BASE_URL/sha256sum-$ARCH.txt" -o "$WORK/sha256sum-$ARCH.txt"

log "Fetching k3s binary..."
curl -fsSL "$BASE_URL/$BIN_ASSET" -o "$WORK/$BIN_ASSET"

log "Fetching air-gap images..."
curl -fsSL "$BASE_URL/k3s-airgap-images-$ARCH.tar.zst" \
    -o "$WORK/k3s-airgap-images-$ARCH.tar.zst"

# Verify before moving anything into place
log "Verifying checksums..."
(cd "$WORK" && sha256sum --check --ignore-missing "sha256sum-$ARCH.txt")

# Only now publish under versioned names. rootfs.d/05-vendor.sh strips the
# version again when installing to /usr/local/bin/k3s.
chmod +x "$WORK/$BIN_ASSET"
mv "$WORK/$BIN_ASSET"                          "$BIN_OUT"
mv "$WORK/k3s-airgap-images-$ARCH.tar.zst"     "$IMAGES_OUT"

log "Done."
log "  ${BIN_OUT#"$VENDOR/"}    → installed into rootfs as /usr/local/bin/k3s"
log "  ${IMAGES_OUT#"$VENDOR/"} → bundled on ISO, written to /data/k3s-images/"
