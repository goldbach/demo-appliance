#!/bin/bash
# Packs the payload rootfs image into a signed RAUC update bundle (.raucb).
#
# This is the A/B update artifact. It carries the very same ext4 image that
# installer.d/20-rootfs.sh writes into slot A at install time — install and
# update stay one artifact, just delivered two ways.
#
# A bundle is a squashfs holding the slot image plus a manifest, signed with a
# detached CMS signature. format=verity adds a dm-verity hash tree, so the
# appliance verifies the payload as it reads it rather than trusting one
# up-front checksum.
#
# Usage: ./scripts/make-bundle.sh <rootfs.raw.zst> <output.raucb>
set -euo pipefail

SRC="${1:?missing rootfs image (build/rootfs-\$ARCH.raw.zst)}"
OUT="${2:?missing output bundle path}"

ARCH="${ARCH:?set ARCH (exported by the Makefile)}"
VERSION="${VERSION:?set VERSION (exported by the Makefile)}"
COMPATIBLE="${RAUC_COMPATIBLE:?set RAUC_COMPATIBLE (exported by the Makefile)}"
CERT="${RAUC_CERT:?set RAUC_CERT (exported by the Makefile)}"
KEY="${RAUC_KEY:?set RAUC_KEY (exported by the Makefile)}"

log() { echo "[make-bundle] $*"; }

command -v rauc >/dev/null || { log "ERROR: rauc not installed (run 'make deps')"; exit 1; }
[ -f "$CERT" ] || { log "ERROR: missing signing cert $CERT (run 'make rauc-keys')"; exit 1; }
[ -f "$KEY" ] || { log "ERROR: missing signing key $KEY (run 'make rauc-keys')"; exit 1; }

export TMPDIR="${TMPDIR:-/var/tmp}"
WORK=$(mktemp -d "$TMPDIR/make-bundle.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/bundle"
mkdir -p "$STAGE"

# The slot image goes in uncompressed: rauc writes it to the partition
# verbatim, and the squashfs wrapped around it does the compressing.
log "decompressing $SRC"
zstd -dc "$SRC" > "$STAGE/rootfs.ext4"

# compatible must equal the string in the appliance's /etc/rauc/system.conf or
# it rejects the bundle — that check is what keeps an image off hardware it was
# not built for.
cat > "$STAGE/manifest.raucm" <<EOF
[update]
compatible=$COMPATIBLE
version=$VERSION

[bundle]
format=verity

[image.rootfs]
filename=rootfs.ext4
EOF

log "compatible: $COMPATIBLE"
log "version:    $VERSION"

# rauc refuses to overwrite an existing bundle.
rm -f "$OUT"
rauc bundle --cert="$CERT" --key="$KEY" "$STAGE" "$OUT"

log "Bundle: $OUT ($(du -h "$OUT" | cut -f1))"
