#!/bin/bash
# Applies systemd presets. Must run last: it enables installer.service, which
# 00-overlay.sh drops in.
#
# Usage: 90-preset.sh <rootfs-dir>   (run inside build-live.sh's fakeroot)
set -euo pipefail

ROOT="${1:?missing rootfs dir}"

log() { echo "[live:90-preset] $*"; }

# preset-all only manipulates symlinks under the given tree, so the host
# systemctl with --root does the job and stays inside fakeroot.
log "systemctl preset-all"
systemctl preset-all --root="$ROOT"
