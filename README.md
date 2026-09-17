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

- [`docs/ubuntu-touch/25-status-2026-09-17.md`](docs/ubuntu-touch/25-status-2026-09-17.md)
- [`docs/ubuntu-touch/30-outbound-drops-before-the-queue.md`](docs/ubuntu-touch/30-outbound-drops-before-the-queue.md)
- [`docs/ubuntu-touch/31-ruled-out-and-what-to-read-next.md`](docs/ubuntu-touch/31-ruled-out-and-what-to-read-next.md) — what has been eliminated and the four commands that will settle it — the stall mechanism: outbound packets are dropped before the device queue, and the evidence points at Android's netd in the shared network namespace — **current status: what is done, what is blocked, and the one key press that unblocks it**
- [`docs/ubuntu-touch/17-adaptation-plan.md`](docs/ubuntu-touch/17-adaptation-plan.md) — the adaptation plan
- [`docs/ubuntu-touch/18-stage0-backup-record-2026-09-16.md`](docs/ubuntu-touch/18-stage0-backup-record-2026-09-16.md) — Stage 0: what is now backed up and how it was verified
- [`docs/ubuntu-touch/19-phase1-reproducible-build.md`](docs/ubuntu-touch/19-phase1-reproducible-build.md) — Phase 1: the build is now byte-for-byte reproducible, and why the old target SHA was wrong
- [`docs/ubuntu-touch/20-stage2-runbook.md`](docs/ubuntu-touch/20-stage2-runbook.md) — Stage 2: how to flash boot, how to verify, how to roll back
- [`docs/ubuntu-touch/21-stage2-first-cold-boot.md`](docs/ubuntu-touch/21-stage2-first-cold-boot.md) — Stage 2 result: the flash+cold-boot works, and why the container does not
- [`docs/ubuntu-touch/22-stage2-coldboot-results.md`](docs/ubuntu-touch/22-stage2-coldboot-results.md) — Stage 2 result: with `/data/system.img` restored the Android container runs too; the remaining flakiness is on the host side
- [`docs/ubuntu-touch/23-uether-tx-wakeup-patch.md`](docs/ubuntu-touch/23-uether-tx-wakeup-patch.md) — a kernel-side mitigation candidate for the intermittent transmit stall, and what it does and does not prove
- [`docs/ubuntu-touch/24-reproducible-working-image.md`](docs/ubuntu-touch/24-reproducible-working-image.md) — the known-good v63 image is now rebuildable from tracked source, and verified against the binary
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
systemd as PID 1, RNDIS networking stays up with both static IPs, and — on the
2026-06-13 boot — the Android LXC container came up with the full set of HALs. See
[`docs/ubuntu-touch/17-adaptation-plan.md`](docs/ubuntu-touch/17-adaptation-plan.md)
for the evidence and for the plan that replaces the earlier boot-image trial-and-error
approach.

Three earlier conclusions have been corrected and are recorded in that document:

- `lxc-ls` reporting the android container as `STOPPED` is an artifact of
  `lxc-start -F` (foreground mode) and does **not** mean the container failed to start.
- The 2026-06-07 partition backup is complete for everything except `userdata`, and all
  31 images re-verified against `SHA256SUMS` (31/31 OK).
- `fastboot boot` is not the safe option it looks like; see the safety notes below.

The device (serial `33e80afe`) is now **running Ubuntu Touch from a flashed boot
partition** — the first time this port has survived a real cold boot. Stage 0 and
Stage 1 of the plan are done:

- [`docs/ubuntu-touch/18-stage0-backup-record-2026-09-16.md`](docs/ubuntu-touch/18-stage0-backup-record-2026-09-16.md) — `userdata` and `cache` are now backed up and byte-verified against the device
- [`docs/ubuntu-touch/19-phase1-reproducible-build.md`](docs/ubuntu-touch/19-phase1-reproducible-build.md) — two clean rebuilds produce an identical `halium-boot.img`
- [`docs/ubuntu-touch/21-stage2-first-cold-boot.md`](docs/ubuntu-touch/21-stage2-first-cold-boot.md) — the first `fastboot flash boot` + cold boot: systemd as PID 1, RNDIS up with no drops
- [`docs/ubuntu-touch/22-stage2-coldboot-results.md`](docs/ubuntu-touch/22-stage2-coldboot-results.md) — restoring `/data/system.img` brings the Android container up too; that session ran 20 minutes with `lxc-ls` reporting RUNNING throughout

The earlier EDL incident is resolved; see
[`docs/session-notes/DEVICE-IN-EDL-2026-06-17.md`](docs/session-notes/DEVICE-IN-EDL-2026-06-17.md).
Every script filters on serial `33e80afe` — the unrelated Xiaomi `4a2fe00b` shares the
USB bus and must be ignored.

The known-good v63 image is now rebuildable from tracked source rather than existing only
as a binary, and every rebuild is content-verified against it:
[`docs/ubuntu-touch/24-reproducible-working-image.md`](docs/ubuntu-touch/24-reproducible-working-image.md).

A kernel-side mitigation candidate for the stall is built and reproducible:
[`docs/ubuntu-touch/23-uether-tx-wakeup-patch.md`](docs/ubuntu-touch/23-uether-tx-wakeup-patch.md).

What still does not work: **the device's RNDIS transmit path wedges on about 1 boot in 4.**
It is intermittent, not systematic — 6 of 8 boots in the historical monitor log carried
0.3–1.9 MB, and the one boot right after a stalled one was fine. The device's own `/proc/net/dev` counters show RX
climbing to the end (the host's ARP requests keep arriving) while TX freezes after one
HTTP response. `carrier=1` and `operstate=up` are not evidence that the data path is
alive — that misreading is what produced the earlier "stable for 9 minutes" claim. See
`22-stage2-coldboot-results.md` §5.

**The device exposes only RNDIS, not adb**, and it is currently sitting in a stalled boot,
so it needs one physical key combination before anything else can happen: Volume Up + Power
for TWRP. A watcher is already running and will do the rest —
`scripts/twrp-one-shot-setup.sh` installs a device-side watchdog that records the counters
and re-asserts the gadget when the transmit path stalls, fixes SSH, and sets the device to
return itself to TWRP after a configurable delay. After that one press, the loop runs
without human input.

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
