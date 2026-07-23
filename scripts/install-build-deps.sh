#!/bin/bash
set -euo pipefail
apt-get update
apt-get install -y --no-install-recommends \
    debootstrap \
    mkosi \
    systemd-container \
    xorriso \
    isolinux \
    squashfs-tools \
    zstd \
    curl \
    ca-certificates \
    make \
    dpkg-dev
rm -rf /var/lib/apt/lists/*

# mkosi cache directory — writable by all so non-root builds work
mkdir -p /var/cache/mkosi
chmod 777 /var/cache/mkosi

# Ubuntu 26.04 ships systemd-repart bundled inside the systemd package rather
# than as a separately-installable package. mkosi hardcodes systemd-repart in
# its bootstrap package list, so apt fails with "no installation candidate".
# Create a local apt repo with a dummy package to satisfy this.
COMPAT_REPO=/var/lib/mydistro-compat
mkdir -p "$COMPAT_REPO"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/DEBIAN"
cat > "$TMP/DEBIAN/control" <<'EOF'
Package: systemd-repart
Version: 999~compat
Architecture: amd64
Maintainer: local
Installed-Size: 0
Description: Compat shim — systemd-repart is bundled in systemd on Ubuntu 26.04
EOF
dpkg-deb --build --root-owner-group "$TMP" "$COMPAT_REPO/systemd-repart_999~compat_amd64.deb"

(cd "$COMPAT_REPO" && dpkg-scanpackages -m . > Packages)
