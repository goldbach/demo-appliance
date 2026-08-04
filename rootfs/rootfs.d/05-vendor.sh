#!/bin/bash
# Installs vendored third-party binaries into the rootfs. Nothing here is built
# from this repo — fetch-k3s.sh downloads and sha256-verifies them into vendor/
# at the pinned K3S_VERSION.
#
# This lives in the customization layer, not the base, so that bumping
# K3S_VERSION costs a `make rootfs` (seconds) rather than a full mmdebstrap.
#
# Usage: 05-vendor.sh <rootfs-dir>   (run inside build-rootfs.sh's fakeroot)
set -euo pipefail

ROOT="${1:?missing rootfs dir}"
ARCH="${ARCH:?missing ARCH}"
K3S_VERSION="${K3S_VERSION:?missing K3S_VERSION}"
VENDOR="vendor/k3s/$ARCH"

log() { echo "[05-vendor] $*"; }

# vendor/ holds every version ever fetched; pick the pinned one explicitly and
# drop the version from the installed name, so the appliance always has a plain
# /usr/local/bin/k3s and the units need no version-aware paths.
K3S_SRC="$VENDOR/bin/k3s-$K3S_VERSION"
[ -x "$K3S_SRC" ] || {
    log "ERROR: missing $K3S_SRC (run 'make fetch')" >&2
    exit 1
}

# Explicit -o/-g: the file in vendor/ belongs to the build user, and a plain
# copy would carry that ownership into the image — mmdebstrap's `copy-in` did
# exactly that, leaving /usr/local/bin/k3s owned by a uid that does not exist
# on the appliance.
log "installing k3s $K3S_VERSION"
install -D -m 0755 -o 0 -g 0 "$K3S_SRC" "$ROOT/usr/local/bin/k3s"
