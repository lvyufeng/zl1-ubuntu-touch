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

- [`docs/ubuntu-touch/00-safety.md`](docs/ubuntu-touch/00-safety.md)
- [`docs/ubuntu-touch/05-build-strategy.md`](docs/ubuntu-touch/05-build-strategy.md)
- [`docs/ubuntu-touch/16-noble-systemd-lxc.md`](docs/ubuntu-touch/16-noble-systemd-lxc.md)
- [`docs/ubuntu-touch/V63-OPTIONC-CONFIRMED-WORKING.md`](docs/ubuntu-touch/V63-OPTIONC-CONFIRMED-WORKING.md) — the boot configuration that works
- [`scripts/README.md`](scripts/README.md) — host-side tooling
- [`manifests/halium-9-zl1.xml`](manifests/halium-9-zl1.xml)

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

## Current status (2026-06-17)

The device boots and reaches a working state under the v63 boot image, which is
the first configuration that gave stable RNDIS network access over USB from the
host. The v73 image (same kernel, ramdisk with an HTTP command endpoint) was
built and validated but left the device in Qualcomm EDL after a `fastboot boot`
attempt. The device needs a manual power-cycle to leave EDL, then can either be
retested with v73 or fell back to v63.

See [`docs/session-notes/DEVICE-IN-EDL-2026-06-17.md`](docs/session-notes/DEVICE-IN-EDL-2026-06-17.md)
for the recovery steps, and
[`docs/session-notes/STRATEGIC-ANALYSIS-NEXT-STEPS.md`](docs/session-notes/STRATEGIC-ANALYSIS-NEXT-STEPS.md)
for the plan after that. Critical partitions are still **not** backed up, so no
flashing should happen before that is done.

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
- Keep the Android restore path documented before testing Ubuntu Touch images.
