#!/bin/bash
# Install step: generate this machine's SSH host keys.
#
# openssh-server's postinst creates host keys when the package is installed. For
# us that happened once, during the base build, so the same keys would reach
# every appliance — build-rootfs.d/20-remove-ssh-hostkeys.sh strips them. This
# step recreates them per machine, which is exactly what a normal install gets
# from that postinst running on the target itself.
#
# `ssh-keygen -A` is what the distro's own sshd-keygen.service runs, and it only
# creates keys that are missing, so it is idempotent. That unit cannot do the job
# here: it is gated on ConditionFirstBoot, which never holds on this image —
# root is mounted ro, so PID1 cannot persist /etc/machine-id, installs a
# transient one and never sets the first-boot flag. See TODO "SSH host keys".
#
# Entropy comes from the live env's /dev, bind-mounted into the target by
# 20-rootfs.sh.
set -euo pipefail

log() { echo "[install:ssh-hostkeys] $*"; }

log "Generating host keys..."
chroot "$TARGET" ssh-keygen -A
