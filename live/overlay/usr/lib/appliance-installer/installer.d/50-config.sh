#!/bin/bash
# Install step: write the machine config and enable firstboot.
set -euo pipefail

log() { echo "[install:config] $*"; }

# Demo default: a single-node server with a placeholder token. Installing a
# worker, or setting a real token, currently means editing this heredoc and
# rebuilding the live env — see TODO "machine.conf: resolve from the kernel
# cmdline" for the intended replacement.
log "Writing machine config..."
mkdir -p "$TARGET/etc/appliance"
install -m 0600 /dev/null "$TARGET/etc/appliance/machine.conf"
cat > "$TARGET/etc/appliance/machine.conf" <<'EOF'
# Written by installer.d/50-config.sh. Consumed by firstboot.sh.

# Role of this node: server | worker
ROLE=server

# Set to true only on the first server node in a new cluster.
# All subsequent nodes (servers and workers) set this to false.
CLUSTER_INIT=true

# URL of the first server node. Required when CLUSTER_INIT=false.
# SERVER_URL=https://192.168.1.10:6443

# Shared secret for nodes to join the cluster.
# Generate with: openssl rand -hex 32
CLUSTER_TOKEN=changeme
EOF

# firstboot.sh and firstboot.d/ are baked into the payload image
# (rootfs/overlay/usr/lib/appliance/), so they arrive with the rootfs and an
# A/B update refreshes them along with everything else. Nothing to copy here.

log "Enabling first-boot unit..."
chroot "$TARGET" systemctl enable firstboot.service
