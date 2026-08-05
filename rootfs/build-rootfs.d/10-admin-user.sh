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
#
# The hash is computed here and passed to useradd -p. chpasswd --prefix would
# read better but is not portable enough: it works on the Lima builder
# (Ubuntu 26.04, shadow 4.17) and fails on the GitHub runner (Ubuntu 24.04).
log "creating $ADMIN_USERNAME (group sudo)"
ADMIN_HASH=$(echo "$ADMIN_PASSWORD" | openssl passwd -6 -stdin)
useradd --prefix "$ROOT" -m -s /bin/bash -G sudo -p "$ADMIN_HASH" "$ADMIN_USERNAME"
