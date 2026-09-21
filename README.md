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
- [`docs/ubuntu-touch/31-ruled-out-and-what-to-read-next.md`](docs/ubuntu-touch/31-ruled-out-and-what-to-read-next.md)
- [`docs/ubuntu-touch/32-counterexample-38-minute-boot.md`](docs/ubuntu-touch/32-counterexample-38-minute-boot.md)
- [`docs/ubuntu-touch/33-the-container-restart-loop.md`](docs/ubuntu-touch/33-the-container-restart-loop.md)
- [`docs/ubuntu-touch/34-correction-the-100-percent-was-the-watchdog.md`](docs/ubuntu-touch/34-correction-the-100-percent-was-the-watchdog.md)
- [`docs/ubuntu-touch/35-the-policy-routing-rule-that-kills-the-link.md`](docs/ubuntu-touch/35-the-policy-routing-rule-that-kills-the-link.md) — **root cause found**: Android's netd installs `from all unreachable` at pref 32000, and Ubuntu Touch's unmarked packets fall into it — **the 100% was my own watchdog healing every 84 s**; with it off the same image measures 0.3% — why the container restarts every ~65 s, and why a stable link is currently a side effect of Android failing to start — a boot that ran 38 minutes without stalling, which contradicts the "always dies at 50 s" reading — what has been eliminated and the four commands that will settle it — the stall mechanism: outbound packets are dropped before the device queue, and the evidence points at Android's netd in the shared network namespace — **current status: what is done, what is blocked, and the one key press that unblocks it**
- [`docs/ubuntu-touch/43-binder-does-not-cross-a-pid-namespace.md`](docs/ubuntu-touch/43-binder-does-not-cross-a-pid-namespace.md) — **the host cannot reach any Android binder service, and that is why the display never came up**: `/dev/binder` and `/dev/hwbinder` are the same kernel devices in the host and in the LXC container, but the *same* binary run from the host root reports `Found 0 services:` while `nsenter -p` into the container's PID namespace reports `Found 19 services:` — PID namespace is the only variable (a control run into the host's own namespace still reports 0). So every lookup of `display.qservice`, `servicemanager` or `hwservicemanager` from the compositor completes at the syscall level and comes back empty. Fixed by running the compositor inside the container's PID namespace from `lsc-wrapper` — with two traps: `nsenter -F` is wrong (`setns` on a PID namespace only affects future children, so the process stays behind and `pthread_create` fails with EINVAL), and the guard must be `[ -e ]` not `[ -d ]` because `/proc/PID/ns/pid` is a symlink to nsfs. Also: `libhwc2_compat_layer.so` is now built for real out of the Halium tree (`build-hwc2-compat-layer.sh`; three host prerequisites — ImageMagick, Python 2 for the Soong genrules, `ALLOW_MISSING_DEPENDENCIES`). And the container's own logcat shows *hundreds* of Android processes stuck on `hwservicemanager.ready`, so no HAL service ever registers — that, not libhybris, is the next blocker. `scripts/hybris-shims/` builds, installs and documents the whole set (runtime bind mounts, nothing persistent)
- [`docs/ubuntu-touch/42-the-wait-that-could-never-finish.md`](docs/ubuntu-touch/42-the-wait-that-could-never-finish.md) — **the compositor starts and then blocks forever, and the line it blocks on is known**: with `libui_compat_layer.so` supplied, `lomiri-system-compositor` gets all the way into `eglInitialize` and stops in `android::base::WaitForProperty("hwservicemanager.ready")`, reached from `waitForHwServiceManager()`. That property is never set on this device (the container's property service refuses every write, so `hwservicemanager` never sets it), the retry loop has no bound, and libhybris deliberately skips its property hooks at SDK ≥ 27 — so from a host process the wait can only ever block. A forced core off the running process (`hybris-crash-hunt.sh --from-pid`, which needs `prlimit` because `RLIMIT_CORE` belongs to the process, not the shell) gives the whole chain frame by frame. Fixed with a 4-byte patch to a *copy* of `libhidltransport.so` (`waitForHwServiceManager` → `ret`) placed ahead of `/system/lib64` on `HYBRIS_LD_LIBRARY_PATH`. Also documents that `/usr/bin/getprop` on this device is a no-op stub installed by the v63 debug image, so shell property reads lie. `scripts/hybris-shims/` fetches, builds and installs the whole set (runtime bind mount, nothing persistent)
- [`docs/ubuntu-touch/41-bionic-tls-slot-is-never-filled.md`](docs/ubuntu-touch/41-bionic-tls-slot-is-never-filled.md) — **the display blocker, explained and experimentally fixed**: on aarch64 glibc the thread pointer's slot 1 (`TP+8`) is `tcbhead_t::private`, which glibc never touches — and that is exactly bionic's `TLS_SLOT_THREAD_ID`. In a glibc host it is always 0, so `__get_thread()` is NULL and every `__get_bionic_tls()` read faults at `0xb00`. The only code that fills the slot is bionic's `__libc_init_main_thread()`, which lives in the Android linker (`linker64` has exactly one `msr tpidr_el0`; libhybris' `o.so` has zero) and is compiled out under `DISABLED_FOR_HYBRIS_SUPPORT`. A superset of `libtls-padding.so` that fills the slot makes `lightdm` go from `failed` to **active** and `lomiri-system-compositor` stop dying at 0.44 s; it also exposes the next blocker, the Halium-side `libui_compat_layer.so` missing from the stock Android image. `scripts/tlsfix/` builds and installs the shim (runtime bind mount, nothing persistent)
- [`docs/ubuntu-touch/40-the-display-died-below-lomiri.md`](docs/ubuntu-touch/40-the-display-died-below-lomiri.md) — **the screen does not light up, and Lomiri is not the reason**: `lomiri-system-compositor` is SIGSEGV'd by something *below* Mir, and the upstream libhybris helpers crash identically (`test_hwcomposer` / `test_egl` / `test_glesv2` / `test_lights` all rc=139, only `test_dlopen` and `getprop` survive). A core dump puts the fault in Android `libc.so!__ctype_get_mb_cur_max+8` — `ldr x8,[x8,#2816]` with `x8 == 0`, i.e. `__get_bionic_tls()` on a NULL `__get_thread()`: **bionic's per-thread slot is not established in a glibc host process**, and libhybris' `o.so` linker never calls `__libc_init_main_thread` (`__linker_init` is compiled out under `DISABLED_FOR_HYBRIS_SUPPORT`). Also: the property-area "staleness" theory is refuted (host and container share one tmpfs, same inode), and the linker-variant / `LD_PRELOAD` / SDK-override workarounds all fail. `scripts/hybris-crash-hunt.sh` reproduces the whole analysis
- [`docs/ubuntu-touch/39-the-container-was-up-all-along.md`](docs/ubuntu-touch/39-the-container-was-up-all-along.md) — **the container was never stuck**: `coldboot_done` was being read from `lxc-start`'s root, which is the *host* root, so the check reported "stuck before coldboot_done" on every sample of every boot for days. `lxc-info -p` gives the container's own init, and the marker was there all along. On 2026-09-21 the container came fully up (`coldboot_done`, zygote, netd, fwmarkd) **while the link stayed alive** — a combination that had never occurred before
- [`docs/ubuntu-touch/38-stage25-rollback-drill.md`](docs/ubuntu-touch/38-stage25-rollback-drill.md) — **Stage 2.5 passed**: a documented-bad image was flashed, confirmed not to boot, and the stock `boot.img` restored by hash — the device is not bricked, `/data` is intact, and TWRP is now reachable from Ubuntu Touch in 20 s via the `misc` bootloader command, no key press needed. The caveat: stock Android brings up adbd but never reaches `sys.boot_completed` (zygote never starts), which the drill wrote down as its own finding rather than folding into a pass
- [`docs/ubuntu-touch/37-the-trial-that-had-no-peer.md`](docs/ubuntu-touch/37-the-trial-that-had-no-peer.md) — **the "failed" cold boot that was counted on 2026-09-20 was measured with nothing at the other end**: `rx_packets` was 0 at all 10205 samples over 14.7 hours because no host-side watcher was running; the three-table fix is stable (netd never cleared it), and the cold-boot driver had itself been unable to reboot past the first trial
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

**Stage 2.4 and 2.5 are both done** (2026-09-21): three consecutive cold boots with the
same result, and a rollback drill that flashed a known-bad image, confirmed it failed, and
restored the stock `boot.img` by hash. The device is on stock Android at the moment, with
the Ubuntu Touch staging files intact on `/data`. See
[`docs/ubuntu-touch/38-stage25-rollback-drill.md`](docs/ubuntu-touch/38-stage25-rollback-drill.md)
and [`docs/ubuntu-touch/stage2-coldboot-trials.md`](docs/ubuntu-touch/stage2-coldboot-trials.md).

The device (serial `33e80afe`) has **run Ubuntu Touch from a flashed boot partition** —
the first time this port survived a real cold boot. Stage 0 and Stage 1 of the plan are
done:

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

**The device exposes only RNDIS, not adb**, so everything after a boot is done over SSH
(`ssh root@10.15.19.82`) or, when the device is in recovery, over adb. The device-side
watchdog is installed, SSH works, and cold-boot trials are now driven end to end over SSH
by [`scripts/run-stage24-and-25.sh`](scripts/run-stage24-and-25.sh) — including the
reboots, which is what the earlier adb-based driver could not do.

The step that was missing is on **this** side of the cable. A trial is only a trial once
the host's `usb0` is configured; with nothing at the other end the device records
`rx_packets=0` for its whole life and looks exactly like a stall. Every trial now starts
[`scripts/host-watch-usb0.sh`](scripts/host-watch-usb0.sh) first and waits for the host to
see `usb0` go away and come back. See
[`docs/ubuntu-touch/37-the-trial-that-had-no-peer.md`](docs/ubuntu-touch/37-the-trial-that-had-no-peer.md).

The running tally of Stage 2.4 trials, and which of them count, is in
[`docs/ubuntu-touch/stage2-coldboot-trials.md`](docs/ubuntu-touch/stage2-coldboot-trials.md).

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
