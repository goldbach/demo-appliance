#!/bin/bash
# Runs once on first boot after install. Entry point for the first-boot
# steps in /usr/lib/appliance/firstboot.d/ (executed in glob order).
# Reads /etc/appliance/machine.conf, exports it for the steps, then
# disables itself.
set -euo pipefail

CONF=/etc/appliance/machine.conf
STEPS_DIR=/usr/lib/appliance/firstboot.d

log() { echo "[firstboot] $*"; }

if [[ ! -f "$CONF" ]]; then
    log "ERROR: $CONF not found — cannot configure node"
    exit 1
fi

# Export config (ROLE, CLUSTER_INIT, SERVER_URL, CLUSTER_TOKEN, ...)
# for the step scripts.
set -a
# shellcheck source=/dev/null
source "$CONF"
set +a

for step in "$STEPS_DIR"/*.sh; do
    log "Running step: $(basename "$step")"
    bash "$step"
done

log "Disabling firstboot unit..."
systemctl disable firstboot.service
rm -f /etc/systemd/system/multi-user.target.wants/firstboot.service
