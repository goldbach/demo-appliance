#!/bin/bash
# Removes the SSH host keys that openssh-server's postinst generated during the
# base build. Left in place, every appliance built from a given image would
# answer with the same host key.
#
# Per-machine keys are generated at install time by
# installer.d/40-ssh-hostkeys.sh. The distro's sshd-keygen.service would
# normally cover this, but it is gated on ConditionFirstBoot, which never holds
# on this image — see the comment there and TODO "SSH host keys".
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
