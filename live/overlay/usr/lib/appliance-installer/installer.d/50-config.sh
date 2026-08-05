#!/bin/bash
# Install step: write /etc/fstab and the machine config, enable firstboot.
set -euo pipefail

log() { echo "[install:config] $*"; }

log "Writing /etc/fstab..."
# root stays rw for now: firstboot, ssh host keys, timesync etc. need writable
# /etc//var. ro root comes back with the A/B work, together with the
# writable-path plumbing (/data-backed overlays) it requires.
EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")
ROOT_UUID=$(blkid -s UUID -o value "$ROOTFS_A")
DATA_UUID=$(blkid -s UUID -o value "$DATA_PART")
cat > /mnt/etc/fstab <<EOF
UUID=$EFI_UUID   /boot/efi  vfat  umask=0077                    0 1
UUID=$ROOT_UUID  /          ext4  defaults                       0 1
UUID=$DATA_UUID  /data      ext4  defaults,x-systemd.makefs      0 2
EOF

# Demo default: a single-node server with a placeholder token. Installing an
# worker, or setting a real token, currently means editing this heredoc and
# rebuilding the live env — see TODO "machine.conf: resolve from the kernel
# cmdline" for the intended replacement.
log "Writing machine config..."
mkdir -p /mnt/etc/appliance
install -m 0600 /dev/null /mnt/etc/appliance/machine.conf
cat > /mnt/etc/appliance/machine.conf <<'EOF'
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
chroot /mnt systemctl enable firstboot.service
