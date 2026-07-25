#!/bin/bash
# Runs once on first boot after install. Reads /etc/mydistro/machine.conf,
# configures k3s for the correct role, then disables itself.
set -euo pipefail

CONF=/etc/mydistro/machine.conf
K3S_CONFIG=/etc/rancher/k3s/config.yaml
AIRGAP_DIR=/data/k3s-images

log() { echo "[firstboot] $*"; }

if [[ ! -f "$CONF" ]]; then
    log "ERROR: $CONF not found — cannot configure node role"
    exit 1
fi

# shellcheck source=/dev/null
source "$CONF"
# Expected variables: ROLE (server|agent), CLUSTER_INIT (true|false),
#                     SERVER_URL, CLUSTER_TOKEN

log "Node role: $ROLE"

mkdir -p /etc/rancher/k3s /data/k3s-images

# Import air-gap images if present on the data partition
if compgen -G "$AIRGAP_DIR/*.tar.zst" > /dev/null; then
    log "Importing air-gap images..."
    mkdir -p /var/lib/rancher/k3s/agent/images
    cp "$AIRGAP_DIR"/*.tar.zst /var/lib/rancher/k3s/agent/images/
fi

case "$ROLE" in
    server)
        if [[ "${CLUSTER_INIT:-false}" == "true" ]]; then
            log "Bootstrapping new cluster..."
            cat > "$K3S_CONFIG" <<EOF
cluster-init: true
token: "${CLUSTER_TOKEN}"
data-dir: /data/k3s
EOF
        else
            log "Joining existing cluster as server..."
            cat > "$K3S_CONFIG" <<EOF
server: "${SERVER_URL}"
token: "${CLUSTER_TOKEN}"
data-dir: /data/k3s
EOF
        fi
        systemctl enable --now k3s-server.service
        ;;
    agent)
        log "Joining cluster as agent..."
        cat > "$K3S_CONFIG" <<EOF
server: "${SERVER_URL}"
token: "${CLUSTER_TOKEN}"
data-dir: /data/k3s
EOF
        systemctl enable --now k3s-agent.service
        ;;
    *)
        log "ERROR: unknown role '$ROLE' in $CONF"
        exit 1
        ;;
esac

log "Disabling firstboot unit..."
systemctl disable firstboot.service
rm -f /etc/systemd/system/multi-user.target.wants/firstboot.service
