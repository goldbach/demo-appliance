#!/bin/bash
# Creates dummy .deb packages to satisfy build-time apt dependencies that
# don't exist as separately-installable packages in Ubuntu 26.04.
#
# In Ubuntu 26.04, systemd-repart is bundled inside the systemd package rather
# than shipped as a standalone package. mkosi always tries to install it;
# this dummy satisfies that without pulling in anything extra.
set -euo pipefail

OUT="${BUILD:-build}/dummy-pkgs"
mkdir -p "$OUT"

make_dummy() {
    local name="$1"
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN
    mkdir -p "$tmp/DEBIAN"
    cat > "$tmp/DEBIAN/control" <<EOF
Package: $name
Version: 999~nodistro
Architecture: amd64
Maintainer: local-build
Description: Dummy package
 $name is bundled inside another package on this OS version.
 This dummy satisfies the build-time dependency without installing anything.
EOF
    dpkg-deb --build --root-owner-group "$tmp" "$OUT/${name}_999~nodistro_amd64.deb"
    echo "Created: $OUT/${name}_999~nodistro_amd64.deb"
}

make_dummy systemd-repart
