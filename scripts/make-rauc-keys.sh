#!/bin/bash
# Generates the RAUC signing key and certificate used to sign update bundles.
#
# Every bundle is signed, and the appliance checks that signature against a
# keyring before it will write anything into a slot. This pair is the
# demo-phase stand-in for a real CA: self-signed, generated on the build host,
# kept out of git by .gitignore's keys/*.pem. Regenerate by deleting it.
#
# Point RAUC_CERT/RAUC_KEY at a key held elsewhere to sign with something real.
#
# Usage: ./scripts/make-rauc-keys.sh
set -euo pipefail

CERT="${RAUC_CERT:?set RAUC_CERT (exported by the Makefile)}"
KEY="${RAUC_KEY:?set RAUC_KEY (exported by the Makefile)}"
SUBJECT="${RAUC_CERT_SUBJECT:-/O=demo-appliance/CN=demo-appliance development signing key}"
DAYS="${RAUC_CERT_DAYS:-3650}"

log() { echo "[make-rauc-keys] $*"; }

mkdir -p "$(dirname "$CERT")" "$(dirname "$KEY")"

log "generating a self-signed signing key, valid $DAYS days"
openssl req -x509 -newkey rsa:4096 -noenc \
    -keyout "$KEY" -out "$CERT" \
    -days "$DAYS" -subj "$SUBJECT" 2>/dev/null
chmod 0600 "$KEY"

log "key:  $KEY"
log "cert: $CERT"
log "DEVELOPMENT KEY — whoever holds it can sign a bundle the appliance accepts"
