#!/bin/bash
# First-boot step: configure k3s for the node's role and start it.
# Expects ROLE (server|worker), CLUSTER_INIT, SERVER_URL and CLUSTER_TOKEN
# in the environment (exported by firstboot.sh from machine.conf).
set -euo pipefail

K3S_CONFIG=/etc/rancher/k3s/config.yaml
AIRGAP_DIR=/data/k3s-images

log() { echo "[firstboot:k3s] $*"; }

log "Node role: $ROLE"

mkdir -p /etc/rancher/k3s /data/k3s-images

# Stage air-gap images where k3s imports them at startup. With
# data-dir=/data/k3s that is /data/k3s/agent/images — NOT the default
# /var/lib/rancher/k3s path (that would land on the per-slot rootfs).
if compgen -G "$AIRGAP_DIR/*.tar.zst" > /dev/null; then
    log "Staging air-gap images..."
    mkdir -p /data/k3s/agent/images
    cp "$AIRGAP_DIR"/*.tar.zst /data/k3s/agent/images/
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
    worker)
        log "Joining cluster as worker..."
        cat > "$K3S_CONFIG" <<EOF
server: "${SERVER_URL}"
token: "${CLUSTER_TOKEN}"
data-dir: /data/k3s
EOF
        systemctl enable --now k3s-worker.service
        ;;
    *)
        log "ERROR: unknown role '$ROLE'"
        exit 1
        ;;
esac
