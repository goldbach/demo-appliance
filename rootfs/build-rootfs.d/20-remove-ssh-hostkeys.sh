#!/bin/bash
# Removes the SSH host keys that openssh-server's postinst generated during the
# base build. Left in place, every appliance built from a given image would
# answer with the same host key.
#
# Regeneration needs no code of ours: sshd-keygen.service ships enabled and
# ordered Before=ssh.service, and runs `ssh-keygen -A` when ConditionFirstBoot
# holds — which it does, because /etc/machine-id ships empty. `ssh-keygen -A`
# only creates keys that are missing, so removing them here is what lets it act.
#
# Usage: 20-remove-ssh-hostkeys.sh <rootfs-dir>   (run inside build-rootfs.sh's fakeroot)
set -euo pipefail

ROOT="${1:?missing rootfs dir}"

log() { echo "[20-remove-ssh-hostkeys] $*"; }

shopt -s nullglob
KEYS=("$ROOT"/etc/ssh/ssh_host_*)
shopt -u nullglob

if [ ${#KEYS[@]} -gt 0 ]; then
    log "removing ${#KEYS[@]} baked-in host key files"
    rm -f "${KEYS[@]}"
else
    log "no baked-in host keys present"
fi
