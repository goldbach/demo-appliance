#!/bin/bash
# Bakes the admin account into the image. Same credentials on every box built
# with these values — fine for the demo phase, see TODO "Baked-in admin user".
#
# Usage: 10-admin-user.sh <rootfs-dir>   (run inside build-rootfs.sh's fakeroot)
set -euo pipefail

ROOT="${1:?missing rootfs dir}"

# Overridable from the environment:
#   ADMIN_PASSWORD=hunter2 make rootfs
ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-appliance}"

log() { echo "[10-admin-user] $*"; }

# --prefix edits the /etc/* files under the target tree directly, which fakeroot
# can follow and which works when the payload arch differs from the builder's.
#
# Hashing here and passing to useradd -p keeps this working across every shadow
# release the build runs on — Ubuntu 24.04 on the GitHub runner through 26.04
# on the Lima builder.
log "creating $ADMIN_USERNAME (group sudo)"
ADMIN_HASH=$(echo "$ADMIN_PASSWORD" | openssl passwd -6 -stdin)
useradd --prefix "$ROOT" -m -s /bin/bash -G sudo -p "$ADMIN_HASH" "$ADMIN_USERNAME"
