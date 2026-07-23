#!/bin/bash
# Rebuild the initrd so our custom live-boot hook and squashfs/overlay
# modules are included. Runs inside the image after ExtraTrees are applied.
set -euo pipefail
update-initramfs -u -k all
