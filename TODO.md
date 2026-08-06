# TODO / ideas

## Split live-boot env from install payload

**Implemented 2026-07-29**, with a better outcome than sketched below: the
payload was already a partition image (`installer/rootfs.raw.zst`), not a
squashfs, so the split *does* shrink the ISO — the full rootfs no longer
appears twice.

- **Live env** — minimal mmdebstrap build: kernel, systemd, disk tools,
  live-boot, `installer-entrypoint.sh` + `installer.service`. No k3s, no
  iptables. Shim/grub signed binaries are included only so `make-iso.sh` can
  extract the ISO boot files from the live tar.
- **Payload** — unchanged full node OS. Lost `live-boot*` (the installer's
  initrd-purge step went with it).

**Superseded 2026-08-05 by the layered split** (see CLAUDE.md "Architecture"),
which changed both the file names and where the logic lives:

- Each half became two builds — `build-live-base.sh` + `build-live.sh`, and
  `build-base-rootfs.sh` + `build-rootfs.sh` — so package-list changes and
  overlay edits no longer cost the same.
- **The ISO no longer carries loose scripts.** `install.sh` + `installer.d/`
  are baked into the live env (`live/overlay/usr/lib/appliance-installer/`),
  `firstboot.sh` + `firstboot.d/` into the payload image
  (`rootfs/overlay/usr/lib/appliance/`) — split by *where the code runs*, so
  both are present however the node booted, PXE included. The ISO holds the
  payload image and the k3s air-gap tarballs, nothing else.
- Rebuild cost moved with them: firstboot edits are now `make rootfs` → `image`
  → `iso`, not an ISO repack. Installer edits stay at `make live` → `iso`.

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
- The hostname blocker is gone: `live-boot` is in `build-live-base.sh`'s
  package list and the hostname comes from `live/overlay/`. Remaining blocker:
  `make-iso.sh` still needs the tar to pull standalone
  kernel/initrd/grub/shim files (`tar -tf`/`tar -xf` would become
  `unsquashfs -f -d dest image path...` — doable, but a rewrite, not a
  deletion).

## A/B rootfs updates (design chat 2026-07-29)

Partition layout already exists (`installer.d/10-partition.sh`: EFI +
rootfs-a + rootfs-b + data). Division of labor established in the chat:
**slot selection is the bootloader's job** (`root=PARTUUID=` on the kernel
cmdline — nothing in systemd picks A vs B), **staging the update is an
updater's job** (raw block write into the inactive slot, refusing the booted
one — RAUC, as of 2026-08-06), and **fallback/boot-counting is a bootloader
feature** (systemd-boot has it built in; GRUB doesn't — see below).

### Update mechanism — RAUC (chosen 2026-08-06)

Acted on, not merely picked: `rauc` + `rauc-service` are in both the payload
and the live env, `rauc` is a build dep, and `make bundle` produces a signed
verity bundle. What is *configured* on the appliance is still nothing — see
"Going full RAUC" below for the remaining work. The candidate comparison is
kept as the decision record.

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

**Not taken (sysupdate), kept so it is not re-litigated:** `MatchPattern` needs
a version in the artifact name (`@v` is its only pattern variable, installed
versions tracked in GPT partition labels) plus `InstancesMax=2`, and a publish
side of `rootfs-<ver>.raw.zst` + `SHA256SUMS`. RAUC needs none of that — the
version lives in the bundle manifest, and `make bundle` already stamps
`$(VERSION)` into both the manifest and the `.raucb` filename.

**Was a blocker for sysupdate, dissolved by RAUC:** `make-image.sh` still emits
`rootfs-$ARCH.raw.zst` with no version in the name. That is fine now — the
bundle carries the version. Still worth a version-stamped image name if a
PXE/network install ever needs the raw image URL-addressable.

### Going full RAUC — what's left

**In place (2026-08-06):** `rauc`+`rauc-service` in the payload and the live
env, `rauc` as a build dep, `make bundle` / `make rauc-keys` / `make
bundle-info`. The bundle is `verity` format and its `rootfs.ext4` is
byte-identical to the image the ISO installs (checksums compared, 2026-08-06) —
install and update genuinely share one artifact.

**None of it does anything yet.** There is no `/etc/rauc/system.conf` and no
keyring on the appliance, so `rauc status` on an installed box reports nothing.
Work in dependency order:

**1. `system.conf` — generated, not a static overlay file.**

```ini
[system]
compatible=demo-appliance-<arch>
bootloader=grub
grubenv=/boot/efi/EFI/appliance/grubenv
data-directory=/data/rauc

[keyring]
path=/etc/rauc/keyring.pem

[slot.rootfs.0]
device=/dev/disk/by-partlabel/rootfs-a
type=ext4
bootname=A
resize=true

[slot.rootfs.1]
device=/dev/disk/by-partlabel/rootfs-b
type=ext4
bootname=B
resize=true
```

- `compatible` embeds `$ARCH`, so this cannot be a plain `rootfs/overlay/` file
  — it needs a `build-rootfs.d` step (same shape as `05-vendor.sh`). It must
  equal `RAUC_COMPATIBLE` from the Makefile; have the step read the exported
  value rather than spelling the string twice.
- `device=` by **partlabel**, not `/dev/sdaN`. The GPT labels `10-partition.sh`
  already sets are the stable anchor across sda/vda/nvme; `install.sh`'s
  string-concatenation device naming must not leak into the installed system.
- `resize=true` is RAUC's own answer to the grow problem in point 5 — no
  post-install hook needed.
- `data-directory` on `/data`: slot status has to survive the slot being
  overwritten, so it must not be per-slot.

**2. Keyring into the image.** `keys/rauc-dev-cert.pem` →
`/etc/rauc/keyring.pem`, another `build-rootfs.d` step. Decide before shipping:
a baked-in dev cert means whoever holds `keys/rauc-dev-key.pem` can update every
box ever built. Same problem family as "Baked-in admin user" below — decide
both at once.

**3. Bootloader rework.** The largest piece; details in "Boot side" below.
RAUC's GRUB backend expects `ORDER` plus `<bootname>_OK` / `<bootname>_TRY` in
grubenv (so `bootname=A` ⇒ `A_OK`, `A_TRY`), and GRUB's scripting cannot reach
the env implicitly — the config needs explicit `load_env --file=` /
`save_env --file=`. RAUC ships a reference `grub.cfg` in `contrib/`; start from
that rather than inventing the variable dance.

**4. Per-slot state — the real blocker.** `21-fstab.sh`, `40-ssh-hostkeys.sh`
and `50-config.sh` all write into `$TARGET`, i.e. slot A. RAUC writes a
*pristine image* into B, which contains none of them: no fstab, no host keys,
no `machine.conf`. Worse, **both slots end up with the same filesystem UUID** —
`make-image.sh` runs `mkfs.ext4` once at build time, so the UUID is baked into
the image and lands in whichever slot receives it. `21-fstab.sh` writes
`UUID=$ROOT_UUID / ext4`, which becomes ambiguous the moment slot B exists;
resolution then depends on enumeration order. Root must come from
`root=PARTUUID=` on the cmdline (PARTUUIDs are per-partition and genuinely
distinct), and the fstab `/` line must stop keying on the fs UUID. Fix belongs
with "Shared state on `/data`" below.

**5. `10-partition.sh`.** Replace `mkfs.ext4 -L rootfs-b "$ROOTFS_B"` with
`wipefs -a "$ROOTFS_B"`. The comment's stated goal is clearing stale
signatures, which is exactly what wipefs does; the filesystem is overwritten
wholesale on the first update, and the `rootfs-b` *fs* label silently becomes
`rootfs` (the image's neutral label) as soon as RAUC writes the slot. Keep the
GPT partition labels — they are what point 1 depends on. Nothing else in the
layout needs to change.

**6. Install path — `rauc install` cannot run in the live env.** It picks the
target by first identifying the *booted* slot from the kernel cmdline; the
installer boots from ISO, so nothing matches and there is no target group. The
RAUC docs have no rescue/installer story. Options: keep the `dd` in
`20-rootfs.sh` (status quo, and the bundle stays purely an update artifact), or
ship the bundle on the ISO and `rauc mount` it so the installer `dd`s out of a
signature- and verity-checked mountpoint. `rauc write-slot` is the wrong tool —
it takes a bare image, "bypassing all update logic" including signature
verification, so it buys nothing over `dd`.

**7. Mark-good service.** A unit on the installed system that health-checks
(k3s up, node Ready, system pods Running) and calls `rauc status mark-good`.
Because GRUB's fallback is one-shot with no try-counting, this unit must *fail
actively* — reboot — when the checks do not pass.

**8. Secure Boot limit, accepted going in.** shim verifies GRUB, but `grub.cfg`
and `grubenv` on the ESP are **not** signature-covered: anyone who can write the
ESP can redirect the boot. Inherent to GRUB-based A/B, and the strongest
argument for the systemd-boot + UKI alternative listed above.

**Open:** `VERSION` currently defaults to `git describe`, so bundles carry
strings like `with-lima-x86-targets-64-g755b219` in the manifest — set it
explicitly for anything handed out. Production signing key custody is
undecided.

### Boot side — the missing glue (GRUB)

- Relocate `/boot/grub` onto the ESP (symlink `/boot/grub` →
  `/boot/efi/grub`, re-run `grub-install`) so GRUB core's baked-in fs UUID
  becomes the ESP's — today it points at slot A, so slot B's grub.cfg would
  never be read.
- Replace the generated config with a **hand-written grub.cfg on the ESP**:
  two entries (A/B) selecting the partition by PARTUUID and passing
  `root=PARTUUID=...`, with explicit `load_env --file=` / `save_env --file=`
  over RAUC's `ORDER` / `A_OK` / `A_TRY` / `B_OK` / `B_TRY`. `grubenv` lives on
  the ESP too — shared, GRUB-writable, and outside both slots.
  `grub-mkconfig` drops out of `30-bootloader.sh` entirely: its job is
  enumerating kernels on one root, which is the wrong model here.
  The *logic* is static, but `parted` assigns PARTUUIDs randomly per install,
  so the installer expands a template rather than copying a file verbatim.
- Update protocol, with RAUC driving it: `rauc install` writes the inactive
  slot and sets grubenv itself (no hand-rolled `grub-reboot` /
  `grub-set-default`) → reboot → mark-good service on the new slot health-checks
  and calls `rauc status mark-good`, which sets `<bootname>_OK`. Failure path:
  the slot never marks good, and the next boot falls back. Limitation vs
  systemd-boot: one try per slot, no counting — so the mark-good unit must
  *fail actively* (reboot) when checks don't pass.
- Alternative considered: `bootctl install` (systemd-boot) gives boot
  counting + `systemd-bless-boot` for free; stays an option if the GRUB
  emulation gets hairy.

### Shared state on `/data` (bind mounts, not symlinks)

Symlinks break under atomic-rename writers (`passwd`, `shadow`,
`machine-id`) — use bind mounts, ordered before consumers. Allowlist, never
share `/etc` wholesale (image owns os-release/PAM/nsswitch/presets).

- `/etc/machine-id` → store at `/data/machine-id`, copy in early boot
  before `systemd-machine-id-commit.service`.
- SSH host keys → persist to `/data`. **Only persistence is left.** Keys
  openssh-server's postinst baked in are removed at build time
  (`rootfs/build-rootfs.d/20-remove-ssh-hostkeys.sh`) and regenerated per
  machine at install time (`installer.d/40-ssh-hostkeys.sh`, 2026-08-05).

  **`ConditionFirstBoot` cannot be used on this image — confirmed, don't retry
  it.** `sshd-keygen.service` would normally cover this, but the first boot's
  journal shows why it never runs:

  ```
  systemd[1]: Installed transient '/etc/machine-id' file.
  systemd[1]: first-boot-complete.target ... skipped, unmet ConditionFirstBoot=yes
  systemd[1]: Starting systemd-machine-id-commit.service ...
  systemd[1]: sshd-keygen.service ... skipped, unmet ConditionFirstBoot=yes
  ```

  `grub-mkconfig` emits `ro`, so PID1 cannot write `/etc/machine-id`; it
  installs a transient one and never sets the first-boot flag.
  `machine_id_setup()` runs inside PID1 init, *before* the unit graph exists,
  so `systemd-remount-fs.service` is necessarily too late — a chicken-and-egg
  no image with an empty machine-id and `ro` root can win.
  `systemd-machine-id-commit.service` persists the ID afterwards, which is why
  machine-id looks healthy while first-boot never fired. A stock Ubuntu install
  never hits this: its host keys come from the postinst running *on the target*,
  so first-boot is not load-bearing there. Our install step restores exactly
  that behaviour.

  **Consequence until `/data` persistence lands:** `/etc/ssh` is per-slot and
  the installer does not run for a RAUC-written slot B, so **slot B boots
  with no host keys at all and sshd fails to start** — worse than key rotation.
  This makes persistence a hard blocker for A/B, not a nicety. Same fix and same
  early-boot ordering as `/etc/machine-id` above; do them together.
- **The same trap, for every install-time-generated file.** Host keys are just
  the one already debugged: `21-fstab.sh` and `50-config.sh` also write only
  into slot A, so a RAUC-written B has no fstab and no `machine.conf` either.
  Treat "written by an `installer.d` step" as the marker for "missing in slot
  B" and audit the whole directory, rather than fixing these one at a time.
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
  `ConditionPathExists=/data/appliance/role.server` / `role.worker`;
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
  rebooting into the new slot. Delivery options: a RAUC install hook that
  stages it out of the bundle, or the USB/management-agent flow copying it
  alongside the bundle. A hook keeps the pairing atomic but puts ~200 MB back
  into the bundle — the thing the tarballs are on `/data` to avoid — so the
  out-of-band copy is probably right, with the hook only *checking* the file
  is present. If missed,
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
- **Still open, same root cause: the fs *UUID* is baked in too.** `mkfs.ext4`
  runs once at build time, so every slot written from a given image shares one
  filesystem UUID — neutral labels do not help here. Anything resolving
  `UUID=` or `LABEL=rootfs` becomes ambiguous once slot B is populated; use
  PARTUUID (see "Going full RAUC" point 4).
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
  install `dd` on SSDs) and before RAUC writes the inactive slot — the latter
  is a RAUC install hook, not something the installer can do. Full-size images
  were the alternative (zstd makes the zeroed tail ~free in the artifact) but
  discard is one line in each place.

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
directory; the ISO now carries only the payload image and the k3s air-gap
tarballs.

**What that costs:** the file is the only genuinely per-node input
(`ROLE`, `CLUSTER_INIT`, `SERVER_URL`, `CLUSTER_TOKEN`), and it is no longer
editable without a rebuild. Installing a *worker* means editing the heredoc and
running `make live` + `iso`. Acceptable for the demo phase, not for the field.

**Way forward — resolve at install time, in priority order:**

1. **Kernel cmdline** — `appliance.role=`, `appliance.cluster-init=`,
   `appliance.server=`, `appliance.token=`. Gives PXE a config channel it does
   not have today (there is no medium to read), and lets one image produce both
   servers and workers.
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

`rootfs/build-rootfs.d/10-admin-user.sh` bakes `$ADMIN_USERNAME` (default
`admin`, sudo group) with the fixed `$ADMIN_PASSWORD` (default `appliance`,
hashed on the build host with `openssl passwd -6`) into the payload image:
every box built from the same invocation shares credentials, and password
ssh login is enabled. Acceptable for the demo phase only. Later, pick one:

- Per-device credentials via `machine.conf` + firstboot — blocked on `/etc`
  persistence across A/B slots (see "Shared state on `/data`"): a
  firstboot-created user exists only in slot A's `/etc` today.
- At minimum: force a password change on first login (`chage -d 0`), and/or
  disable ssh password auth in favor of an `authorized_keys` drop from
  `machine.conf` (keys on `/data` per the shared-state plan). The hash half is
  already done — the step hashes with `openssl passwd -6` and passes
  `useradd -p`, because `chpasswd --prefix` does not exist on the 24.04
  shadow-utils the GitHub runners carry.
- Decide together with RAUC's signing key custody ("Going full RAUC" point 2):
  both are "one secret, baked into every box we ship" questions.
