# LeEco zl1 OS Porting Notes

This repository tracks research and experiments for alternate operating systems on the LeEco Pro3 (`zl1`, `le_zl1`, Qualcomm MSM8996 / Snapdragon 821).

## Active track: Ubuntu Touch / Halium 9

The current focus is rebuilding Ubuntu Touch / Halium 9 boot support for `zl1` after older community prebuilt artifacts disappeared.

Known starting point:

- Device: LeEco Pro3 (`le_zl1` / `zl1`)
- Android base observed on the connected device: Android 9, SDK 28
- Treble: enabled
- VNDK: 28
- Slot layout: A-only / no slot suffix observed
- Boot state: orange

The recommended first approach is to reproduce the historical community Halium 9 path using Android 9 / LineageOS 16-era sources and the `halium-leeco` `halium-9.0` branches.

Start here:

- [`docs/ubuntu-touch/17-adaptation-plan.md`](docs/ubuntu-touch/17-adaptation-plan.md) — **the current adaptation plan**
- [`docs/ubuntu-touch/18-stage0-backup-record-2026-09-16.md`](docs/ubuntu-touch/18-stage0-backup-record-2026-09-16.md) — Stage 0: what is now backed up and how it was verified
- [`docs/ubuntu-touch/00-safety.md`](docs/ubuntu-touch/00-safety.md)
- [`docs/ubuntu-touch/05-build-strategy.md`](docs/ubuntu-touch/05-build-strategy.md)
- [`docs/ubuntu-touch/16-noble-systemd-lxc.md`](docs/ubuntu-touch/16-noble-systemd-lxc.md)
- [`docs/ubuntu-touch/V63-OPTIONC-CONFIRMED-WORKING.md`](docs/ubuntu-touch/V63-OPTIONC-CONFIRMED-WORKING.md) — the boot configuration that works
- [`scripts/README.md`](scripts/README.md) — host-side tooling
- [`manifests/halium-9-zl1.xml`](manifests/halium-9-zl1.xml) — pinned to exact commits
- [`manifests/halium-boot-candidates.md`](manifests/halium-boot-candidates.md) — every boot image built so far, by SHA256

## Repository layout

```
README.md                  this file
docs/ubuntu-touch/         stable notes: device baseline, safety, build strategy,
                           partition plan, root-cause write-ups
docs/session-notes/        chronological working notes from the bring-up sessions
manifests/                 repo manifests for the Halium 9 build tree
scripts/                   host-side tooling (backup, build, staging, status server)
scripts/boot-experiments/  per-iteration watch-and-boot drivers used during bring-up
```

Large or derived material is deliberately **not** tracked (see
[`.gitignore`](.gitignore)):

- `references/` — third-party upstream clones (BlackBerry kernel/android-utils,
  Raspberry-QNX). Research material only, each with its own `.git` directory.
- `tmp-*/` — scratch build directories: unpacked boot images, ramdisks, DTB dumps.
- `v4*/`, `v5*/`, `v6*/` — per-iteration boot log and device status captures.
- `recovery-diagnostics-*/` — device diagnostic dumps.
- `*.img`, `*.log` — built boot images and boot logs.

These regenerate from the scripts plus the device, so they stay out of history.

## Current status (2026-09-16)

The v63 boot image is a genuinely working configuration: under it the device runs
systemd as PID 1, the Android LXC container comes up with the full set of HALs, and
RNDIS networking stays up for ~9 minutes with both static IPs. See
[`docs/ubuntu-touch/17-adaptation-plan.md`](docs/ubuntu-touch/17-adaptation-plan.md)
for the evidence and for the plan that replaces the earlier boot-image trial-and-error
approach.

Two earlier conclusions have been corrected and are recorded in that document:

- `lxc-ls` reporting the android container as `STOPPED` is an artifact of
  `lxc-start -F` (foreground mode) and does **not** mean the container failed to start.
- The 2026-06-07 partition backup is complete for everything except `userdata`, and all
  31 images re-verified against `SHA256SUMS` (31/31 OK).

The device (serial `33e80afe`) is currently **in TWRP recovery**. Stage 0 of the plan is
done: `userdata` and `cache` are now backed up too
([`docs/ubuntu-touch/18-stage0-backup-record-2026-09-16.md`](docs/ubuntu-touch/18-stage0-backup-record-2026-09-16.md)),
and the boot partition was confirmed byte-identical to the 2026-06-07 backup, so
`fastboot flash boot` has a verified rollback. The earlier EDL incident is resolved; see
[`docs/session-notes/DEVICE-IN-EDL-2026-06-17.md`](docs/session-notes/DEVICE-IN-EDL-2026-06-17.md)
for what happened. Every script filters on serial `33e80afe` — the unrelated Xiaomi
`4a2fe00b` shares the USB bus and must be ignored.

## Historical track: BlackBerry 10 / QNX and BlackBerry Android

Earlier notes evaluated whether BlackBerry 10 / QNX or BlackBerry Android could be ported to `zl1`. Those tracks are currently paused. Existing reference clones under `references/` are research material only and are not a working `zl1` build tree.

## Goals

- Document the target device hardware, boot chain, partition layout, and firmware constraints.
- Preserve reproducible notes, manifests, scripts, and artifacts used during investigation.
- Prefer read-only inspection and reversible steps before any flashing or partition writes.
- Back up critical partitions before any write operation.

## Safety notes

- Do not flash anything until critical partitions are backed up and checksummed.
- Do not write to modem/EFS/persist-related partitions during experiments.
- Prefer `fastboot boot` over `fastboot flash` when the bootloader supports it.

  *Superseded 2026-09-16.* `fastboot boot` was the main testing method through v2–v73 and
  it is the reason those sessions produced so little: it does not persist, it leaves
  dirty state, and it twice dropped the device into EDL. Write `boot` with
  `fastboot flash boot` instead, and rely on the verified rollback image plus a known way
  into fastboot/TWRP. See
  [`docs/ubuntu-touch/17-adaptation-plan.md`](docs/ubuntu-touch/17-adaptation-plan.md) §1.5.
  `system`, `vendor`, `userdata`, and the modem/EFS partitions still must not be flashed
  until the restore procedure is written down.
- Keep the Android restore path documented before testing Ubuntu Touch images.
