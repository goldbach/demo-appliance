#!/bin/bash
# Bakes the admin account into the image. Same credentials on every box built
# with these values — fine for the demo phase, see TODO "Baked-in admin user".
#
# Usage: 10-admin-user.sh <rootfs-dir>   (run inside build-rootfs.sh's fakeroot)
set -euo pipefail

ROOT="${1:?missing rootfs dir}"
ADMIN_USERNAME="${ADMIN_USERNAME:?missing ADMIN_USERNAME}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:?missing ADMIN_PASSWORD}"

log() { echo "[10-admin-user] $*"; }

# --prefix edits the /etc/* files under the target tree directly, which fakeroot
# can follow and which works when the payload arch differs from the builder's.
# (shadow's --root chroots instead.)
log "creating $ADMIN_USERNAME (group sudo)"
useradd --prefix "$ROOT" -m -s /bin/bash -G sudo "$ADMIN_USERNAME"
echo "$ADMIN_USERNAME:$ADMIN_PASSWORD" | chpasswd --prefix "$ROOT"
