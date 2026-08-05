#!/bin/bash
# Applies systemd presets — enables the distro default unit set, and leaves the
# k3s units off per 99-appliance.preset. Must run last: it reads the preset file
# that 00-overlay.sh drops in, and enables units 00-overlay.sh installed.
#
# Usage: 90-preset.sh <rootfs-dir>   (run inside build-rootfs.sh's fakeroot)
set -euo pipefail

ROOT="${1:?missing rootfs dir}"

log() { echo "[90-preset] $*"; }

# preset-all only manipulates symlinks under the given tree, so the host
# systemctl with --root does the job and stays inside fakeroot.
log "systemctl preset-all"
systemctl preset-all --root="$ROOT"
