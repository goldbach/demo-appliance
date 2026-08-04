#!/bin/bash
# Installs vendored third-party binaries into the rootfs. Nothing here is built
# from this repo — fetch-k3s.sh downloads and sha256-verifies them into vendor/
# at the pinned K3S_VERSION.
#
# Runs in the customization layer, so bumping K3S_VERSION costs a `make rootfs`
# of a few seconds.
#
# Usage: 05-vendor.sh <rootfs-dir>   (run inside build-rootfs.sh's fakeroot)
set -euo pipefail

ROOT="${1:?missing rootfs dir}"
ARCH="${ARCH:?missing ARCH}"
K3S_VERSION="${K3S_VERSION:?missing K3S_VERSION}"
VENDOR="vendor/k3s/$ARCH"

log() { echo "[05-vendor] $*"; }

# vendor/ holds every version ever fetched, so pick the pinned one explicitly.
# The version is dropped on install: the appliance gets a plain
# /usr/local/bin/k3s and the units need no version-aware paths.
K3S_SRC="$VENDOR/bin/k3s-$K3S_VERSION"
[ -x "$K3S_SRC" ] || {
    log "ERROR: missing $K3S_SRC (run 'make fetch')" >&2
    exit 1
}

# Explicit -o/-g: the file in vendor/ belongs to the build user, and the image
# needs it root-owned.
log "installing k3s $K3S_VERSION"
install -D -m 0755 -o 0 -g 0 "$K3S_SRC" "$ROOT/usr/local/bin/k3s"
