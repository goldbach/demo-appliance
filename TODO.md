# TODO / ideas

## Split live-boot env from install payload

Currently `live/filesystem.squashfs` does double duty: it's both the booted
installer environment and the install payload (`install.sh` unsquashfs's it
straight onto the target disk). Idea: split into two images.

- **Live env** (boots the ISO, runs the installer): minimal. Drop containerd,
  k3s, and nvidia/amdgpu/wifi/bt/modem firmware unconditionally — it never
  touches a GPU or joins WiFi, only needs to see the install disk + a NIC.
- **Target payload** (what `install.sh` writes to disk): unchanged, full
  fat — keeps nvidia firmware etc. for AI workloads on cluster nodes.

Why it's safe to trim the live env independently: the target rootfs already
regenerates its own initrd/grub config fresh inside the chroot at install
time (see `6760d94` "fixes"), so the live kernel's module/firmware set is
already decoupled from what ends up installed.

Cost / scope if implemented:
- `build-rootfs.sh` parameterized or split (`build-rootfs.sh` /
  `build-live-rootfs.sh`) — shared base, divergent `PACKAGES` +
  `customize-hook`s.
- `make-iso.sh` emits two squashfs images instead of one (small
  `live/filesystem.squashfs` + full `installer/payload.squashfs`).
- `installer-run.sh` / `install.sh`: distinguish "medium I booted from"
  (still located via `live/filesystem.squashfs`) from "payload to unsquashfs"
  (new separate file on the same medium).
- Two `mmdebstrap` runs instead of one → build time roughly doubles.
- Does **not** meaningfully shrink total ISO size (no dedup between the two
  squashfs images) — the win is live-boot RAM/decompress time and
  decoupling "what's needed to install" from "what ends up on a node."

Scope as its own change; touches Makefile, both build scripts, make-iso.sh,
install.sh, installer-run.sh.
