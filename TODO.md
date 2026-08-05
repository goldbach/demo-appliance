# TODO / ideas

## Split live-boot env from install payload

**Implemented 2026-07-29**, with a better outcome than sketched below: the
payload was already a partition image (`installer/rootfs.raw.zst`), not a
squashfs, so the split *does* shrink the ISO — the full rootfs no longer
appears twice.

- **Live env** (`scripts/build-live.sh` → `live/filesystem.squashfs`):
  minimal mmdebstrap build — kernel, systemd, disk tools, live-boot,
  `installer-entrypoint.sh` + `installer.service`. No k3s, ssh, iptables, certs.
  Shim/grub signed binaries are included only so `make-iso.sh` can extract
  the ISO boot files from the live tar.
- **Payload** (`scripts/build-rootfs.sh` → `installer/rootfs.raw.zst`):
  unchanged full node OS. Lost `live-boot*` (the installer's initrd-purge
  step went with it) and all installer/firstboot scripts.
- **Scripts on the ISO as plain files** (`/installer/`): `install.sh`,
  `installer.d/`, `firstboot.sh`, `firstboot.d/`, `machine.conf`.
  `installer-entrypoint.sh` re-execs `install.sh` from the mounted medium; the
  install copies the firstboot scripts into the target. Iterating on
  firstboot/installer logic = `make iso` repack only, no rootfs rebuild.

Original sketch (kept for the follow-on notes): live env would drop
containerd, k3s, and nvidia/amdgpu/wifi/bt/modem firmware unconditionally —
it never touches a GPU or joins WiFi, only needs to see the install disk +
a NIC. Payload keeps nvidia firmware etc. for AI workloads. (Firmware
partially addressed: the live env uses `linux-firmware-minimal`, which
satisfies `linux-image-generic`'s "linux-firmware | linux-firmware-minimal"
dep and covers disk/NIC — live squashfs ~335 MB vs ~1.1 GB with full
firmware. Whether `-minimal` covers the certified box's NIC needs a
real-hardware install test; if not, add the specific firmware files back.)

### Follow-on: mmdebstrap --format=squashfs

Now that the live/target split exists, the live `mmdebstrap` run could
stream straight to squashfs instead of tar, dropping `make-iso.sh`'s
separate `mksquashfs` pass.

- `mmdebstrap 1.5.7` (confirmed in the `builder` VM) supports
  `--format=squashfs` natively, but via `tar2sqfs` (needs `squashfs-tools-ng`,
  not the `squashfs-tools` we have) rather than `mksquashfs`. Its default is
  `--compressor xz --block-size 1048576`, not the `zstd -Xcompression-level 9`
  used today, and there's no `--format-options` flag to change it — keeping
  zstd means bypassing the shortcut with a manual
  `mmdebstrap | mmtarfilter | tar2sqfs --compressor zstd` pipe instead.
- The hostname blocker is gone: `build-live.sh` bakes `live-boot` in via its
  own `customize-hook` (the split's whole point). Remaining blocker:
  `make-iso.sh` still needs the tar to pull standalone
  kernel/initrd/grub/shim files (`tar -tf`/`tar -xf` would become
  `unsquashfs -f -d dest image path...` — doable, but a rewrite, not a
  deletion).

## A/B rootfs updates (design chat 2026-07-29)

Partition layout already exists (`install.sh`: EFI + rootfs-a + rootfs-b +
data). Division of labor established in the chat: **slot selection is the
bootloader's job** (`root=PARTUUID=` on the kernel cmdline — nothing in
systemd picks A vs B), **staging the update is an updater's job** (raw block
write into the inactive slot, refusing the booted one — *which* updater is
still open, see below), and **fallback/boot-counting is a bootloader feature**
(systemd-boot has it built in; GRUB doesn't — see below).

### Update mechanism — UNDECIDED (sysupdate / RAUC / friends)

`sysupdate/10-rootfs.conf` was **deleted 2026-08-05**. It was a sketch that
shipped nowhere: no Makefile target referenced it, it was not on the ISO nor in
either rootfs, `systemd-sysupdate` is not even in the payload's package list,
and its `MatchPattern` did not match anything we build. Keeping it around made
an unbuilt design look like wired config. The options live here instead.

**Requirements, whichever tool wins:**

- Writes a whole rootfs image into the *inactive* slot; never the booted one.
- Trial boot + automatic rollback when the new slot fails to come up.
- Works air-gapped (USB / local path), not only over HTTP.
- Keeps Secure Boot intact — today that means the signed shim + GRUB chain.
- Consumes the same artifact `install.sh` writes, version-stamped (see below).

**Candidates:**

- **systemd-sysupdate** — declarative, ships with systemd, whole-file transfers
  (no deltas), picks the non-booted instance itself. Would need adding to the
  payload; it is not installed today. Leaves fallback entirely to the
  bootloader, which is the expensive half given GRUB (below).
- **RAUC** — purpose-built A/B updater: signed bundles, slot definitions,
  install hooks, and bootloader integration that *includes* boot counting for
  GRUB/U-Boot/EFI. Buys us the fallback story we would otherwise hand-roll in
  grubenv. Cost: new dependency and a bundle format; its GRUB integration still
  leans on grubenv underneath, so it is a better-tested version of the same
  trick rather than a different mechanism.
- **SWUpdate** — same niche as RAUC, heavier Yocto heritage. Only worth
  evaluating if RAUC's bundle model does not fit.
- **systemd-boot instead of GRUB** — not an updater, but it deletes the reason
  we need the grubenv dance at all: native boot counting (`+N-M` entry
  suffixes) plus `systemd-bless-boot` for mark-good. Trade: redoing the Secure
  Boot signing story that shim+GRUB currently gives us off the shelf.
- **U-Boot** — native `bootcount`/`altbootcmd` fallback, but it is an embedded
  bootloader and this appliance targets UEFI server hardware (amd64 + arm64,
  Secure Boot). Almost certainly out of scope; listed so it stops coming up.

**Decision axes:** (1) does the bootloader provide trial-boot/rollback
natively, or do we hand-roll it; (2) how much Secure Boot work it costs;
(3) air-gap delivery; (4) how much new dependency lands in the payload.

**If we land on systemd-sysupdate**, the config notes from the deleted file
still apply:

- `MatchPattern=rootfs-@{other}` is not real sysupdate syntax. Alternation
  is automatic: match by partition type (`MatchPartitionType=root-x86-64`)
  or a label pattern, and sysupdate writes whichever instance is not backing
  `/`. `@v` (version) is the only pattern variable; installed versions are
  tracked in GPT partition labels.
- Add `InstancesMax=2` to pin the two-slot scheme.
- Publish side: static dir with `rootfs-<ver>.raw.zst` + `SHA256SUMS`
  (+ optional `SHA256SUMS.gpg`); USB air-gap = `Path=file://` override.

**Blocker common to every candidate:** `make-image.sh` emits
`rootfs-$ARCH.raw.zst` — arch, no version — so nothing can match on a version
today. It needs a version-stamped name, the same pattern `vendor/` now uses
where the filename carries the version and doubles as the fetch stamp. That
also makes the image URL-addressable, which a PXE/network install would want —
it needs the identical artifact, fetched rather than found on a medium.

### Boot side — the missing glue (GRUB)

- Relocate `/boot/grub` onto the ESP (symlink `/boot/grub` →
  `/boot/efi/grub`, re-run `grub-install`) so GRUB core's baked-in fs UUID
  becomes the ESP's — today it points at slot A, so slot B's grub.cfg would
  never be read.
- Replace generated config with a **static hand-written grub.cfg on the
  ESP**: two entries (A/B) selecting partition by PARTUUID and passing
  `root=PARTUUID=...`; `load_env` / `next_entry` / `saved_entry` dance at
  the top; `grubenv` lives on the ESP too (shared, GRUB-writable, untouched
  by the updater). Written once by `install.sh`, never regenerated by
  `grub-mkconfig`.
- Update protocol: the updater writes B → `grub-reboot 'Appliance B'`
  (one-shot: next boot only, then auto-returns to default) → mark-good
  service on the new slot runs health checks (k3s up, node Ready) →
  `grub-set-default` makes it permanent. Failure path: watchdog or
  `panic=10` reboots → back on A automatically. Limitation vs systemd-boot:
  one-reboot fallback, no try-counting — so the mark-good unit must *fail
  actively* (reboot) if health checks don't pass.
- Alternative considered: `bootctl install` (systemd-boot) gives boot
  counting + `systemd-bless-boot` for free; stays an option if the GRUB
  emulation gets hairy.

### Shared state on `/data` (bind mounts, not symlinks)

Symlinks break under atomic-rename writers (`passwd`, `shadow`,
`machine-id`) — use bind mounts, ordered before consumers. Allowlist, never
share `/etc` wholesale (image owns os-release/PAM/nsswitch/presets).

- `/etc/machine-id` → store at `/data/machine-id`, copy in early boot
  before `systemd-machine-id-commit.service`.
- SSH host keys → persist to `/data`. Also: keys are currently **baked into
  the image** (openssh-server postinst runs during mmdebstrap) — delete at
  end of `build-rootfs.sh`, `ssh-keygen -A` + persist in firstboot.
- `machine.conf`, k3s `config.yaml` (`K3S_CONFIG_FILE`), hostname, per-node
  netplan, admin `authorized_keys` → `/data`.
- `/var/log/journal` → `/data` (`Storage=persistent`): cross-slot logs, so
  after a rollback the failed slot's journal is still there.
- Minor: `random-seed`, timesync clock.

### Firstboot refactor — runs once per machine, idempotent

- Stamp moves `/var/lib/appliance/firstboot-done` → `/data` (today it's
  per-slot). Keep the script idempotent for factory-reset / DR re-runs.
- Unit enablement out of firstboot: `systemctl enable` writes into the
  *slot's* `/etc`, so slot B would boot with no k3s. Instead enable **both**
  k3s units in the image and gate with
  `ConditionPathExists=/data/appliance/role.server` / `role.agent`;
  firstboot just writes the role stamp.
- Fixed (2026-07-29): airgap images were copied to
  `/var/lib/rancher/k3s/agent/images` (default data-dir, i.e. the per-slot
  rootfs); firstboot now stages them in `/data/k3s/agent/images` where k3s
  with `data-dir: /data/k3s` actually scans at startup.

### k3s airgap images across updates

- Tarballs stay on `/data`, never baked into the rootfs: ~200 MB per update
  artifact (whole-image updates, no deltas) ×2 slots, for bytes
  that dedupe in the shared containerd content store anyway. Rootfs carries
  the k3s *binary*; `/data` carries the *images*.
- Rule: an update shipping a different k3s version ⇒ the matching
  `k3s-airgap-<ver>.tar.zst` must be in `/data/k3s/agent/images/` **before**
  `grub-reboot` into the new slot. Delivery options: a second sysupdate
  transfer (`Type=regular-file` targeting that dir) or the
  USB/management-agent flow copies it alongside the rootfs image. If missed,
  the mark-good health check (node Ready, system pods Running) should fail
  the trial boot and fall back — A/B catches this class of mistake.
- Rollback safety comes from the content store being shared and additive:
  both slots' image sets coexist in `/data/k3s/agent/containerd`. Never
  prune tarballs or `crictl rmi` as part of the update flow; manual prune
  only once the old slot is retired. (kubelet image GC fires only under
  disk pressure.)
- k3s redeploys its pinned addons (coredns, local-path, ...) via
  `/data/k3s/server/manifests` for whichever version is running — on
  rollback it rewrites them back and the images are already in the store.
- Workload images have the same airgap problem with no A/B machinery around
  them — defer the decision: tarball drops to the same dir vs a small
  registry mirror on `/data`.

### Image build nits

- Fixed (2026-07-29): `make-image.sh` labeled every image `rootfs-a` — now
  uses the neutral `rootfs`; slot identity is the GPT partition label, so an
  image landing in slot B no longer claims to be A.
- `resize2fs -M` shrinks the image but root is rw for now → add
  `x-systemd.growfs` to the root fstab entry (or fixed-size images later
  when root goes ro).
- Free-block tail: a shrunk image written into a 10 GiB slot leaves the old
  slot's bytes in what become free blocks after growfs. Filesystem-consistent
  (growfs rewrites all metadata; free blocks are never readable via files),
  but raw-readable with disk access — matters only while secrets live on the
  slot (machine.conf/CLUSTER_TOKEN today, baked-in ssh host keys until the
  `/data` move). Same property at install: slot A's tail holds the disk's
  former life.
  **Chosen fix (deferred): `blkdiscard` before every image write** — in
  `10-partition.sh` after repartitioning (whole disk, also speeds up the
  install `dd` on SSDs) and in the sysupdate flow (inactive slot before
  writing the update). Full-size images were the alternative (zstd makes the
  zeroed tail ~free in the artifact) but discard is one line in each place.

### Caveat: rollback is OS-level only

`/data` doesn't roll back with the slot. A newer k3s on slot B may migrate
the etcd datastore / on-disk formats, and slot A's older k3s can then refuse
the data. Rule: k3s version bumps are the committed part of an update —
`k3s etcd-snapshot` to `/data` before updating; OS rollback is only free
within the same k3s version. (Relevant for the planned control-plane
failover mode: embedded etcd members carry state across slots.)

## machine.conf: resolve from the kernel cmdline (way forward)

**Now (2026-08-05):** `installer.d/50-config.sh` writes
`/etc/appliance/machine.conf` from a heredoc — single-node server,
`CLUSTER_INIT=true`, `CLUSTER_TOKEN=changeme`. The `machine.conf.example`
template that used to ride the ISO is gone, and with it the `installer/`
directory; the ISO now carries only `rootfs.raw.zst`.

**What that costs:** the file is the only genuinely per-node input
(`ROLE`, `CLUSTER_INIT`, `SERVER_URL`, `CLUSTER_TOKEN`), and it is no longer
editable without a rebuild. Installing an *agent* means editing the heredoc and
running `make live` + `iso`. Acceptable for the demo phase, not for the field.

**Way forward — resolve at install time, in priority order:**

1. **Kernel cmdline** — `appliance.role=`, `appliance.cluster-init=`,
   `appliance.server=`, `appliance.token=`. Gives PXE a config channel it does
   not have today (there is no medium to read), and lets one image produce both
   servers and agents.
2. **A `machine.conf` on the installer medium**, if present — restores the
   edit-the-USB-stick workflow for the ISO/USB case.
3. **Built-in defaults** — what 50-config.sh writes today, so a bare boot with
   no arguments still installs successfully.

Fold this into `50-config.sh`; it already owns writing the file. Note the steps
run via `bash "$step"` in subshells, so a separate generator step could not
export the result to a later one — a fixed path or in-place write is required
either way.

**Security caveat to resolve with it:** `appliance.token=` on the cmdline is
world-readable via `/proc/cmdline` and lands in bootloader config. Options: a
one-shot token that k3s rotates, fetching the token from a URL given on the
cmdline, or accepting it only from the medium. Same problem family as
"Baked-in admin user" below — worth deciding once, for both.

## Baked-in admin user (temporary — fix before shipping)

`build-rootfs.sh` bakes `$ADMIN_USERNAME` (default `admin`, sudo group) with
the fixed `$ADMIN_PASSWORD` (default `appliance`) into the payload image:
every box built from the same invocation shares credentials, and password
ssh login is enabled. Acceptable for the demo phase only. Later, pick one:

- Per-device credentials via `machine.conf` + firstboot — blocked on `/etc`
  persistence across A/B slots (see "Shared state on `/data`"): a
  firstboot-created user exists only in slot A's `/etc` today.
- At minimum: commit a crypt hash instead of cleartext
  (`useradd -p "$(openssl passwd -6 ...)"`), force a password change on
  first login (`chage -d 0`), and/or disable ssh password auth in favor of
  an `authorized_keys` drop from `machine.conf` (keys on `/data` per the
  shared-state plan).
