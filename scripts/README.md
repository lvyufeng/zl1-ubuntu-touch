# scripts/ — zl1 Halium / Ubuntu Touch tooling

Everything here runs on the host against the `zl1` (LeEco Pro3, MSM8996), except
`device/zl1-netwatch.sh`, which runs on the device.

Two rules hold across the whole directory:

- **Every device operation filters on serial `33e80afe`.** An unrelated Xiaomi
  (`4a2fe00b`) shares the USB bus; a script that acted on "the first 18d1 device"
  would act on the wrong phone.
- **Scripts that write to the device require `--yes`** and verify image hashes
  before touching anything. Read-only scripts do not.

See [`../docs/ubuntu-touch/00-safety.md`](../docs/ubuntu-touch/00-safety.md) for the
partition rules, and
[`../docs/ubuntu-touch/17-adaptation-plan.md`](../docs/ubuntu-touch/17-adaptation-plan.md)
for what each stage is trying to establish.

## Device inspection and backup (read-only)

| Script | Purpose |
| --- | --- |
| `device-readonly-inventory.sh` | Read-only device inventory. No flashing, no `dd`, no block writes. |
| `backup-partitions-adb.sh` | Back up allowlisted partitions by streaming reads over `adb exec-out`. |
| `backup-partitions-adb-staged.sh` | Same, but stages each image in `/data/local/tmp` first. Works around Magisk/ADB stdout corruption seen when streaming large block devices directly. |
| `backup-partitions-twrp.sh` | Partition backup via TWRP instead of a booted Android. |
| `stage0-backup-userdata-cache.sh` | Stage 0. Images `userdata` (26.1 GB) in resumable 512 MiB chunks and cross-checks it against a device-side SHA256. |
| `collect-v63-monitor-log.sh` | Pull the device-side v63 monitor log out of TWRP. It lives on the persistent partition, so it is the only record of what a failed boot did. |
| `read-netwatch-log.sh` | Pull `/userdata/zl1-netwatch.log` out of TWRP and print the watchdog's heal decisions and stall evidence. |

## Stage 2 — the scripts that write to the device

| Script | Purpose |
| --- | --- |
| `stage2-flash-boot-and-verify.sh` | Flash the known-good v63 boot image with `fastboot flash boot`, then bring up host RNDIS and verify both device IPs plus the HTTP status server. Enforces the rollback and v63 image hashes first. |
| `flash-boot-image.sh` | Generic form of the above: flashes a named image, refusing anything not listed in `/mnt/data/halium-zl1-candidates/SHA256SUMS`. |
| `stage2-rollback-boot.sh` | Put the original Android `boot.img` back. This is the undo for the two above. |
| `stage2-rollback-drill.sh` | Stage 2.5: flash a documented-bad image, confirm it fails, then restore the stock `boot.img` and confirm the device boots again. Needs several minutes and one human key press in the middle. |
| `stage2b-restore-android-system.sh` | Put the 4 GB Android system image back at `/data/system.img`. Without it the initramfs cannot build `/android` and the LXC container never starts. Writes a regular file onto userdata; no partition is touched. |

## Verification

| Script | Purpose |
| --- | --- |
| `verify-device-online.sh` | Wait for the device gadget, set up host RNDIS, ping both device IPs and fetch the status page. Read-only. |
| `stage2-coldboot-trial.sh` | After a power-on: verify the boot and append a row to [`../docs/ubuntu-touch/stage2-coldboot-trials.md`](../docs/ubuntu-touch/stage2-coldboot-trials.md). This is how Stage 2.4's "three consecutive cold boots" gets recorded. |
| `container-ab-test.sh` | A/B: hide `/data/system.img` so the Android container cannot start, measure the link, then restore it and measure again. Tests whether the container is what kills the link — see [`../docs/ubuntu-touch/30-outbound-drops-before-the-queue.md`](../docs/ubuntu-touch/30-outbound-drops-before-the-queue.md). |
| `netwatch-cycle-supervisor.sh` | Drive repeated unattended boots and collect the stalls-per-boot statistics. Possible because the device now returns itself to TWRP and TWRP answers adb. This is how "did the patch help?" gets answered — it is a question about a rate, not one boot. |
| `host-watch-usb0.sh` | Keep the host side of the RNDIS link correct while the device boots. The gadget re-binds several times in the first seconds, and each rebind destroys and recreates `usb0` with a new MAC and no addresses, so a one-shot `ip addr add` only works by luck. It also binds `rndis_host` to the zl1 gadget explicitly, because a gadget the driver declined to claim produces no `usb0` at all — indistinguishable from a device that never booted. |

## Host side: making `usb0` appear by itself

| Script | Purpose |
| --- | --- |
| `host/99-zl1-rndis.rules` | udev rule (Phase 3.1): on `18d1:d001`, run the helper below. Replaces the "a watcher must happen to be running" arrangement — on 2026-09-20 none was, and a 14.7-hour cold boot was judged a failure because of it. |
| `host/zl1-rndis-udev-helper.sh` | Binds `rndis_host` to the zl1's interface and gives `usb0` its two host addresses. Re-checks the serial (`33e80afe`) before touching anything, so a device that merely shares the USB ID is skipped. Logs to `/var/log/zl1-rndis-udev.log`. |
| `host/install-zl1-udev-rule.sh` | Installs/removes those two into `/etc/udev/rules.d/` and `/usr/local/sbin/`. |

## Getting in and out of the device

| Script | Purpose |
| --- | --- |
| `enter-recovery-from-ut.sh` | Phase 2.5's other half: get from a running Ubuntu Touch into TWRP with **no key press**, by writing `boot-recovery` into `misc` (what Android's own `reboot recovery` does). 20 s, measured 2026-09-21. Refuses to reboot unless the command reads back correctly — a reboot without it is a reboot loop, not a degraded version of the feature. |
| `stage2-rollback-resume.sh` | Pick up the rollback drill after its wait for a human key press expires. Waits as long as it takes, then runs the same hash-verified rollback. |

## On-device runtime

| Script | Purpose |
| --- | --- |
| `device/zl1-netwatch.sh` | Runs on the device. Samples the RNDIS gadget's own counters, the interface counters and the routing state into `/userdata/zl1-netwatch.log`, and **re-asserts the gadget** when it detects the intermittent transmit stall. Can also ask the bootloader for recovery after a configurable delay. |
| `install-kmsg-drain.sh` | `--install` / `--remove` / `--status` / `--read [LINES]` / `--follow-on` / `--follow-off`. Keeps the **boot** half of the kernel log, which is otherwise unreachable: `journalctl -k` returns 1 line (journald is not capturing `/dev/kmsg`), and the ring is small and the noise is fast — measured on the device, ~3470 lines / ~249 KiB, growing **not at all** while idle but ~3480 lines per 3 s (~90 KiB/s) while the host is talking, so the earliest surviving line can be only ~10 s old. The noise is `tx_complete` WARN stack traces from our own uether patch, triggered by host traffic — which is exactly why the boot messages are still catchable, but only before anything starts talking to the device. So this is not a follow-the-log drainer: a `DefaultDependencies=no`, `Before=sysinit.target`, `Type=simple` unit snapshots the **whole** ring (via `dmesg`, i.e. `SYSLOG_ACTION_READ_ALL`) at ~0/5/15/35/75/155/315 s of uptime and then exits — a couple of MiB per boot, no eMMC wear. `--read` greps every snapshot and the optional live log for `cnss|wlan|wcnss|qca6174|ar6320|qcacld`, which is the table in [`../docs/ubuntu-touch/51-what-the-wlan-driver-wants-read-from-its-own-source.md`](../docs/ubuntu-touch/51-what-the-wlan-driver-wants-read-from-its-own-source.md). `--follow-on` re-enables a continuous `dmesg -W` trace for the rare case of watching a driver live — off by default because of the eMMC cost. Two failure modes are documented in [`../docs/ubuntu-touch/52-the-gui-and-touch-confirmed-by-the-user.md`](../docs/ubuntu-touch/52-the-gui-and-touch-confirmed-by-the-user.md) and guarded against here: `while read` over `/dev/kmsg` exits immediately having read nothing (a partial read of a record is `EINVAL`), so the follower uses `dmesg -W`; and a leading blank line before the shebang makes systemd report `Exec format error` / `status=203/EXEC`, so the script asserts the first line of what it pushes starts with `#!`. Installed and running on the device; the boot-time half is verified by the next reboot. |
| `install-netwatch-service.sh` | With the device in TWRP, installs that watchdog as a systemd unit under `/userdata/system-data/etc/systemd/`. Persistent, and no rootfs change needed — the rootfs is read-only at runtime, but `/etc/systemd/system` is a writable-path bind mount. Backs up `misc` first. |
| `twrp-one-shot-setup.sh` | Waits for TWRP, installs the watchdog, fixes SSH, sets the "return to recovery after N seconds" marker, and reboots. Optionally flashes a given boot image. One button press sets up everything after it. |
| `fix-policy-routing.sh` | Installs the netwatch build that carries the policy-routing fix. The rule itself is added at boot by netwatch, because netd reinstalls its rules as the container restarts. |
| `fix-ssh-authorized-keys.sh` | **The SSH fix.** Points `AuthorizedKeysFile` at `/etc/ssh/authorized_keys.d/%u`, a persistent writable-path, instead of a user's home directory. Run from TWRP. |
| `fix-ssh-sshd-config.sh` | June attempt: appends `PermitRootLogin`/`PasswordAuthentication` to the userdata `sshd_config`. Kept for the record; superseded — it never touched `AuthorizedKeysFile`. |
| `install-ssh-to-userdata.sh` | June attempt: writes the key to `/userdata/root/.ssh`, which is **not** where `/root` resolves (it comes from `/userdata/system-data/root`). Kept for the record; superseded by `fix-ssh-authorized-keys.sh`. |
| `zl1-status-server-enhanced.py` | HTTP status server with a command-execution endpoint; deployed into the ramdisk at `/usr/local/sbin/`. |

## Finding out *where* the device crashed

| Script | Purpose |
| --- | --- |
| `hybris-crash-hunt.sh` | Runs a libhybris helper on the device (any `/usr/bin/test_*`, or a full command path such as `/usr/share/ubuntu-touch-session/lsc-wrapper`), captures the kernel's core dump, rebuilds a sysroot out of the core's own `NT_FILE` list, and prints the faulting address, the nearest symbol, the faulting instruction and the frame-pointer chain. `HYBRIS_TEST_PRELOAD` sets the run's `LD_PRELOAD`, `HYBRIS_TEST_ARGS` appends arguments. This is how the Phase 5 display failure was traced to `__ctype_get_mb_cur_max+8` inside Android `libc.so` — see [`../docs/ubuntu-touch/40-the-display-died-below-lomiri.md`](../docs/ubuntu-touch/40-the-display-died-below-lomiri.md). Needs `gdb-multiarch` on the host; needs nothing on the device (no compiler, no rootfs change — `core_pattern` is `/proc`, and cores land on `/userdata`). |
| `hybris-crash-hunt.sh --from-pid PID` | The same analysis for a process that **hangs** instead of crashing: `SIGABRT` it, which makes the kernel write the core, and everything after that is identical. `RLIMIT_CORE` belongs to the target process, so the script calls `prlimit --pid … --core=unlimited` first — without it no core is written and the newest `core.*` is the *previous* session's, which analyses perfectly and means nothing. It also verifies the core's name is `core.<comm>.<pid>`, and reads `/proc/PID/exe` before the kill because `comm` is truncated to 15 characters. This is how the Phase 5 hang was traced to `waitForHwServiceManager` — see [`../docs/ubuntu-touch/42-the-wait-that-could-never-finish.md`](../docs/ubuntu-touch/42-the-wait-that-could-never-finish.md). |

## The bionic TLS-slot shim

On aarch64 glibc the thread pointer's slot 1 (`TP+8`) is `tcbhead_t::private`, which glibc never
reads or writes — and that is where bionic keeps `TLS_SLOT_THREAD_ID`. Nothing in this libhybris
fills it, so `__get_thread()` is NULL and any `__get_bionic_tls()` read crashes. These two build
and install a superset of `libtls-padding.so` that fills the slot. See
[`../docs/ubuntu-touch/41-bionic-tls-slot-is-never-filled.md`](../docs/ubuntu-touch/41-bionic-tls-slot-is-never-filled.md).

| Script | Purpose |
| --- | --- |
| `tlsfix/tlsfix.c` | The shim: the original 128-byte TLS padding, a constructor that points `TP+8` at a zeroed fake `pthread_internal_t`, **and a `pthread_create` interposer** that fills the slot on every thread created later — the constructor only reaches the thread it runs on. Freestanding (`-nostdlib`); the only libc entry points are `malloc`/`free`/`dlsym`, and both failures fall back to the real `pthread_create`. |
| `tlsfix/build-tlsfix.sh` | Cross-builds it with `clang --target=aarch64-linux-gnu` + `lld`, then checks the result really has a `PT_TLS` segment, an `DT_INIT_ARRAY` entry, the `tls_padding` symbol, an exported `pthread_create`, and **no version definition** (a versioned `pthread_create` would not bind glibc's `pthread_create@GLIBC_2.34` references and the interposer would silently never run). |
| `tlsfix/install-tlsfix.sh` | `--mount` / `--unmount` / `--status`. `--mount` `scp`s the build to `/userdata/zl1-tlsfix/shadow/` and bind-mounts it over `/usr/lib/aarch64-linux-gnu/libtls-padding.so`, which is the one file `lsc-wrapper` preloads — lightdm builds the compositor's environment itself, so an `LD_LIBRARY_PATH` on `lightdm.service` never reaches it, but replacing that file does. Runtime only: gone after a reboot, and `--unmount` undoes it. |

    Three details in `hybris-crash-hunt.sh` are worth knowing before trusting a trace
that came out of it. First, the offset it reports for a frame is the ELF's
link-time vaddr, obtained by taking the address's file offset from `NT_FILE` and
mapping it through the module's own program headers — **not** `address − mapping
start`, which is only the same thing when the mapping covering the start of the
file has `p_vaddr == 0` (`libc.so` yes, `libhidltransport.so` no: 0xa000). Second,
for a run, `SIGABRT` on a process whose `RLIMIT_CORE` is 0 produces no core at all,
and the script then finds the newest one lying around. Third, and for the same
reason: the script picks the core by **time** (`touch` a stamp, then `find -newer`),
never by name — the kernel truncates `%e` to 15 characters, so
`/usr/bin/lomiri-location-serviced` writes `core.lomiri-location.<pid>`, and a
name-based match silently falls back to a stale core from a previous boot. On
2026-09-21 that stale core analysed perfectly and reproduced doc 45's Mir fault in
a different process; see [`../docs/ubuntu-touch/49-two-cores-that-are-not-tls-wifi-stuck-at-wcnss-and-a-trip-into-edl.md`](../docs/ubuntu-touch/49-two-cores-that-are-not-tls-wifi-stuck-at-wcnss-and-a-trip-into-edl.md).

## The Android-side libraries the stock image is missing

`libui_compat_layer.so`, `libhwc2_compat_layer.so` and `libhidltransport.so` are
Android-side objects that the host graphics stack reaches through libhybris, and
the stock LeEco image either does not have them or has one that cannot work
here. These scripts fetch the link-time inputs, build the objects and put them
in front of the compositor. See
[`../docs/ubuntu-touch/42-the-wait-that-could-never-finish.md`](../docs/ubuntu-touch/42-the-wait-that-could-never-finish.md)
and
[`../docs/ubuntu-touch/43-binder-does-not-cross-a-pid-namespace.md`](../docs/ubuntu-touch/43-binder-does-not-cross-a-pid-namespace.md).

| Script | Purpose |
| --- | --- |
| `hybris-shims/fetch-android-libs.sh` | Copies the device's `/android/system/lib64` libraries out to `out/stubs/`. Read-only against the device. They are link-time inputs, so the shim's ABI is the device's ABI rather than a guess. |
| `hybris-shims/build-hybris-shims.sh` | Builds `libui_compat_layer.so` from the Halium tree with the AOSP prebuilt clang (standalone: it names the header paths Soong would have supplied), and produces the patched `libhidltransport.so`. Both steps verify the result's shape — soname, exported symbols, and that the patch changed at most four bytes and the file length not at all. Deterministic for a given `ld.lld`. |
| `hybris-shims/build-hwc2-compat-layer.sh` | Builds `libhwc2_compat_layer.so` with the Android build system, because that one is a HIDL `composer@2.1` client and needs hidl-gen's output. Checks the three host prerequisites that each cost a confusing failure — ImageMagick (`bootanimation`'s `$(error)` fires during product config), a `python` → python2.7 shim (two Soong genrules are still Python 2), and `ALLOW_MISSING_DEPENDENCIES=true` (unrelated lineage modules abort kati). Prints the symbols the rootfs's `libhwc2.so.1` looks up that this build does not export; it does not NULL-check those, so a missing one is a jump to address 0. |
| `hybris-shims/build-platform-api-libs.sh` | Builds `libubuntu_application_api.so` and `libbiometry_fp_api.so` — the Android-side halves of the libhybris bridge for GPS and fingerprint, which this port had never built. Both `Android.mk` were already in the build graph (`out/.module_paths/Android.mk.list`), so this is one `m` request, not a patch; nothing in `device/leeco/zl1/` ever named either module in `PRODUCT_PACKAGES`, which is why ninja never built them. Same three host prerequisites as `build-hwc2-compat-layer.sh`, plus two traps it adds: `envsetup.sh` must be sourced with `set +u` (it indexes one past an array on purpose and bash ≥ 4.4 aborts the `source`), and the result must be taken from `system/lib64` — the product out also holds an arm copy under the same name, which builds fine and fails only at load. Prints which GPS backend went in (`BOARD_HAS_LEGACY_GPS_HAL` chooses silently), which decides whether the library talks to the HIDL gnss service or the old `hardware/gnss.h` shim. See [`../docs/ubuntu-touch/55-*`](../docs/ubuntu-touch/55-the-bridge-libraries-built-and-hwbinder-does-not-cross-pid-namespaces-either.md). |
| `hybris-shims/install-platform-api-libs.sh` | `--install` / `--remove` / `--status`. Stages the two libraries in `/userdata/zl1-hybris/lib/` and gives `lomiri-location-service` and `biometryd` a **second** drop-in carrying `HYBRIS_LD_LIBRARY_PATH` — second so that it and `install-system-tls-preload.sh` cannot clobber each other, since systemd merges drop-ins. These are system units and do not go through `lsc-wrapper`, which is why the compositor could see that directory and they could not. Took both from `failed (Result: signal)` to `active` and closed the `pc=0x0` class. `--status` reports four separate things — library present, variable set, unit active, and whether the running process actually mapped the library — because only the last one distinguishes "the symbol resolved" from "the service is happy". See [`../docs/ubuntu-touch/55-*`](../docs/ubuntu-touch/55-the-bridge-libraries-built-and-hwbinder-does-not-cross-pid-namespaces-either.md). |
| `hybris-shims/install-container-ns-services.sh` | `--install [unit…]` / `--remove` / `--status`. Runs `lomiri-location-service` and `biometryd` inside the container's PID namespace, because Android binder — both `/dev/binder` and `/dev/hwbinder` — only completes a transaction between two processes in the same one. Doc 43 found that for binder; doc 55 measured it for hwbinder (`lshal` from the host: 0 registered services; from the container: 134). The compositor has been living with it since doc 43 via `lsc-wrapper`; these are plain system units, so nothing did it for them. Installs one shared wrapper plus an `ExecStart=` override per unit — the `zz-` prefix on that drop-in is load-bearing, since `lomiri-location-service` already has an `ExecStart=` reset in `lxc-android-config.conf` and systemd applies drop-ins in one lexicographic order across all directories. `-p` only, never `-F` (`setns` affects future children only, so `-F` leaves the process behind and every `pthread_create` fails with EINVAL — fatal for two GLib-threaded services); no `nsenter` sweep, because cgroups are orthogonal to PID namespaces and systemd's `KillMode=control-group` already kills the child that moved; and a hard failure rather than a fallback if the container is down, because a service in the wrong namespace claims its D-Bus name and reports `active` while doing nothing. `--status` reports four separate things, including which namespace the real process is in (looked up by `comm`, not via MainPID — ExecStart is `nsenter` and the process that moved is its child) and whether the success strings have appeared in the container's logcat. See [`../docs/ubuntu-touch/56-*`](../docs/ubuntu-touch/56-the-two-services-move-into-the-containers-pid-namespace.md). |
| `hybris-shims/make-lsc-wrapper.sh` | Regenerates `lsc-wrapper.zl1` from the device's original as two hunks, so the delta stays reviewable and a rootfs that moved on shows up as a hash mismatch rather than a silently patched file. `--check` verifies the tracked copy is current. |
| `hybris-shims/install-hybris-shims.sh` | `--mount` / `--unmount` / `--status`. Stages the libraries in `/userdata/zl1-hybris/lib/`, bind-mounts `lsc-wrapper.zl1` over `/usr/share/ubuntu-touch-session/lsc-wrapper`, ensures the TLS-slot mount, and restarts lightdm. The mounted wrapper is what sets `HYBRIS_LD_LIBRARY_PATH` (how the Android linker is told to search `/userdata/zl1-hybris/lib` **before** `/system/lib64`) and what puts the compositor in the container's PID namespace. |
| `hybris-shims/lsc-wrapper.orig`, `lsc-wrapper.zl1` | The device's wrapper and the patched copy, both tracked, so the delta is reviewable. `--mount` refuses to run if the device's file is neither of them (rootfs moved on) unless `FORCE=1`. |
| `hybris-shims/free-container-display.sh` | `--apply` / `--status` / `--explain`. Undoes two things the **v63 boot image does to itself**: the three same-length string substitutions its LXC mount hook bind-mounts over `hwservicemanager`, `qseecomd` and both `libc.so` (which is why no HAL in the container ever registered), and the container's SurfaceFlinger holding the QCOM composer's single client slot (which is why the host compositor could not create a client). Runtime-only, and dies with the container — the hook runs on every `lxc-start`. See [`../docs/ubuntu-touch/44-the-v63-image-sabotages-its-own-container.md`](../docs/ubuntu-touch/44-the-v63-image-sabotages-its-own-container.md). |

| `hybris-shims/install-container-desabotage.sh` | `--install` / `--remove` / `--status`. Makes `free-container-display.sh` **persistent**: installs a supervisor at `/userdata/zl1-container-fix/apply.sh` plus a `multi-user.target` unit, so the four over-mounts are lifted and the container's SurfaceFlinger stopped again every time the container restarts. Persistent *without touching the boot image* because `/etc/systemd/system` is one of the rootfs's writable-paths, bind-mounted from `/userdata/system-data/etc/systemd`. The device script is written by this one, so there is one copy of the logic and it lives here. |

| `hybris-shims/install-wlan-bringup.sh` | `--install` / `--remove` / `--status` / `--trigger`. Loads the QCA6174 by writing `sta` to `/sys/module/wlan/parameters/fwpath`, which is the driver's only entry point when qcacld is built into the kernel: `hdd_module_init()` is literally `return 0;` with the comment "Driver initialization is delayed to fwpath_changed_handler", and nothing on this device wrote it — `init.qcom.rc` only chowns the attribute, expecting a userspace writer (normally the wifi HAL, which needs the Android framework). Writing it produced `wlan0`, `FW:4.1.2.57`, `HW:QCA6174_REV3_2` and took `cnss-prealloc` from 0 to 600 Kb used. The value is a trigger, not a path: `hdd_get_fwpath()` has one caller that only compares the first two characters to `"ap"`, and the real firmware directory is the kernel's `firmware_class/parameters/path`. The parameter buffer is 20 bytes (`BUF_LEN`), which is why a 21-character path returns ENOSPC. The device script waits for `/vendor/firmware_mnt/image/qwlan30.bin` to be readable before triggering, because the chip firmware goes through the kernel loader and a cold-boot trigger that fires too early looks like a firmware failure. See [`../docs/ubuntu-touch/54-wifi-the-driver-was-waiting-for-an-fwpath-write-nobody-did.md`](../docs/ubuntu-touch/54-wifi-the-driver-was-waiting-for-an-fwpath-write-nobody-did.md). |
| `hybris-shims/check-android-bridge-libs.sh` | `[--dev] [ELF…]`. Answers "why did this service jump to address 0". Some host libraries do not link their Android side — they reach it at runtime through `android_dlopen("libxxx.so")` + `android_dlsym("u_xxx")`, and the bridge NULL-checks the *cached* pointer but not the one it just resolved, so a missing symbol is `br x16` with `x16=0` rather than an error path. The core reads `pc 0x0`, `si_addr=0`, `lr` just past a `bl …@plt`. The static half needs no device: the library name and the required `u_` symbols are plain strings in the host library's rodata (default list: `liblomiri-location-service`, `libbiometry`, `libubuntu_platform_hardware_api`, `libhwc2`). `--dev` checks those names under the `android_dlopen` search paths and byte-scans each for the required symbols — a MISSING verdict is trustworthy, a present one can be a false positive. This is the same class `build-hwc2-compat-layer.sh` warns about ("it does not NULL-check those, so a missing one is a jump to address 0"); it now also explains `lomiri-location-serviced` on the real `gps::Provider` and `biometryd`. See [`../docs/ubuntu-touch/50-the-pc-zero-is-a-bridge-symbol-that-resolved-to-null.md`](../docs/ubuntu-touch/50-the-pc-zero-is-a-bridge-symbol-that-resolved-to-null.md). |
| `hybris-shims/free-gpu-devices.sh` | `--apply` / `--restore` / `--status` / `--explain`. Opens the GPU to the session user: `/dev/ion` and `/dev/kgsl-3d0` are created `crw------- root:root` by devtmpfs, and the Lomiri session runs as `phablet`, so `eglInitialize()` fails with `EGL_NOT_INITIALIZED` and Mir reports the misleading `could not select EGL config`. `--status` prints the mode bits **and** what the session user actually gets (`test_egl_configs` run through `su phablet` with the doc-45 environment), because mode bits alone do not answer it. Runtime-only — devtmpfs, back to 0600 after a reboot. See [`../docs/ubuntu-touch/46-the-gui-runs-dev-ion-was-root-only.md`](../docs/ubuntu-touch/46-the-gui-runs-dev-ion-was-root-only.md). |

| `hybris-shims/install-system-tls-preload.sh` | `--install` / `--remove` / `--status`. Gives every **system** service that loads an Android library the TLS shim, as a drop-in on the `/etc/systemd/system` writable-path. Only the compositor and the session had it (docs 41/45), and seven services were sitting in `failed (Result: signal)` — all SIGSEGV, all the same bionic TLS slot. Two rules: scan enabled units whose `ExecStart` binary mentions `libhybris` (over-approximates — snapd gets one it does not need; harmless), plus a curated list for the five whose Android side is a runtime plugin and so has no such string in the binary (`sensorfwd`, `urfkill`, `hfd-service`, `lomiri-location-service`, `biometryd`). Also has to `reset-failed` before starting, because a unit that exhausted `Restart=` is not restarted by `start`. See [`../docs/ubuntu-touch/48-the-tls-fault-was-killing-seven-system-services.md`](../docs/ubuntu-touch/48-the-tls-fault-was-killing-seven-system-services.md). |
| `hybris-shims/install-host-hybris-fix.sh` | `--install` / `--remove` / `--status`. The **host half** of the persistence, companion to `install-container-desabotage.sh`. A 10 s watchdog unit that re-asserts the three file overlays (`lsc-wrapper`, `libtls-padding.so`, `lomiri-greeter-wrapper`, all staged on `/userdata`) and opens `/dev/kgsl-3d0` + `/dev/ion`, then starts lightdm once the system has settled. Re-asserts rather than acts once, because a lost bind mount is the doc-41 SEGV coming back; gated so it never restarts lightdm before 90 s of uptime or more than once per 120 s, since a compositor that has not come up yet during boot is not a failure. `--status` prints each overlay's source hash and whether it is mounted, **and** what the session user actually gets. See [`../docs/ubuntu-touch/47-the-screen-comes-back-by-itself.md`](../docs/ubuntu-touch/47-the-screen-comes-back-by-itself.md). |
| `hybris-shims/lomiri-greeter-wrapper.zl1` | The device's `/usr/bin/lomiri-greeter-wrapper` with the same two `export`s `lsc-wrapper` carries. Tracked so a reboot restores what was reviewed rather than whatever was last left in `/userdata`. |

### What the container does to itself

`free-container-display.sh --explain` prints this, but it is worth having here too,
because every symptom it causes looks like a different bug. The v63 image's
`lxc.hook.mount` script copies four Android binaries into a tmpfs, changes one
string in each to another of the **same length**, and bind-mounts them back over
the originals:

| file | string | becomes |
| --- | --- | --- |
| `system/bin/hwservicemanager` | `hwservicemanager.ready` | `zlservicemanager/ready` |
| `vendor/bin/qseecomd` | `sys.listeners.registered` | `zl1.listeners.registered` |
| `system/lib64/libc.so`, `system/lib/libc.so` | `/dev/socket/property_service` | `/dev/socket/property_servicf` |

The shape checks all pass — same size, same inode? No: the giveaway is `st_dev`.
`stat -c '%d %i'` on `/system/lib64/libc.so` from inside the container's mount
namespace reports a tmpfs device, while the file at `/android/system/lib64/libc.so`
reports `1800` (`7:8`, `/dev/loop1`). Same path, same mount point, two different
`st_dev` values means something is mounted on top of it. They were V25/V28/V29/V30
diagnostics and they were never taken back out; see
[`../docs/ubuntu-touch/44-the-v63-image-sabotages-its-own-container.md`](../docs/ubuntu-touch/44-the-v63-image-sabotages-its-own-container.md) §3.

### Why the compositor has to run in the container's PID namespace

Android's binder does not complete a transaction between processes in different
PID namespaces. `/dev/binder` and `/dev/hwbinder` are the same kernel devices
on both sides (the LXC config bind-mounts them), and the same binary proves it:

```sh
$ /android/system/bin/service list                                  # host PID ns
Found 0 services:
$ nsenter -t $$ -p -- /android/system/bin/service list              # control: our own ns
Found 0 services:
$ nsenter -t "$(lxc-info -n android -pH)" -p -- /android/system/bin/service list
Found 19 services:
```

The second run is the control that rules nsenter itself out. So the wrapper
`nsenter -p`s the compositor into the container's namespace first — without
`-F`/`--no-fork`, because `setns` on a PID namespace only affects future
children: with `-F` the process stays in the parent namespace while its children
go to the new one, and `pthread_create` then fails with `EINVAL`.


## Halium 9 build tree

| Script | Purpose |
| --- | --- |
| `setup-halium9-tree.sh` | Initialise the external Halium 9 build tree for zl1. |
| `sync-halium9-tree.sh` | Sync the external build tree. |
| `patch-halium9-build-tree.sh` | Reproducible local fixes needed by the historical `halium-leeco` zl1 tree. Touches only the external tree, never the phone. Idempotent. |
| `patch-uether-tx-wakeup.sh` | Experimental: fixes the confirmed fact that `netif_wake_queue()` in the kernel's `u_ether.c` is reachable only from `tx_complete()`, so one lost completion leaves the transmit queue stopped for the rest of the boot. `--apply` / `--remove` / `--status`; removal is byte-exact. See [`../docs/ubuntu-touch/23-uether-tx-wakeup-patch.md`](../docs/ubuntu-touch/23-uether-tx-wakeup-patch.md). |
| `verify-halium-kernel-config.sh` | Check Halium-relevant kernel config options. Read-only. |
| `build-halium-boot.sh` | Build the Halium boot artifact. Pins `KBUILD_BUILD_*` so two clean builds agree byte-for-byte — see [`../docs/ubuntu-touch/19-phase1-reproducible-build.md`](../docs/ubuntu-touch/19-phase1-reproducible-build.md). |
| `gen-candidate-manifest.sh` | Regenerate [`../manifests/halium-boot-candidates.md`](../manifests/halium-boot-candidates.md) from `/mnt/data/halium-zl1-candidates/`, and write that directory's `SHA256SUMS`. |
| `make-v63-boot-image.sh` | **Rebuild the known-good v63 image from tracked source.** Applies the five-entry initramfs delta under `../boot/v63/` to the reproducible baseline, then verifies the result is content-identical to the v63 binary (kernel, DTBs, cmdline, and all 322 initramfs entries with their modes). `--kernel-from` puts that initramfs onto a different kernel — e.g. the transmit-wakeup one. See [`../docs/ubuntu-touch/24-reproducible-working-image.md`](../docs/ubuntu-touch/24-reproducible-working-image.md). |
| `patch-uether-tx-wakeup.sh` | Experimental: Derive a boot image that adds `zl1_debug_shell=1` to the cmdline — kernel and ramdisk untouched. That flag makes the ramdisk start a busybox telnetd on port 23, which is the only way to get a shell on a device that exposes RNDIS but not adb. |
| `make-halium-diagnostic-boot-images.sh` | Build host-side diagnostic Android boot images from existing images. |
| `make-halium-nonblocking-usb-debug-boot.sh` | Diagnostic boot image that brings up initramfs USB RNDIS/telnet early but still continues the normal boot path. |
| `make-halium-postswitch-debug-boot.sh` | Diagnostic boot image that also installs `/tmp/zl1-debug-init` in the Ubuntu rootfs just before `switch_root`. |

## Ubuntu Touch rootfs and image staging

| Script | Purpose |
| --- | --- |
| `create-ubports-rootfs-img.sh` | Build a host-side `rootfs.img` from an official UBports system-image tarball. |
| `derive-halium-android-system-img.sh` | Derive the Halium Android `system.img` candidate from the trusted staged backup. Does not modify the original backup. |
| `stage-halium-userdata-images-adb.sh` | Push images to Android `/data` as regular files (`/data/rootfs.img`, `/data/system.img`). No block-device writes, no fastboot. |

## boot-experiments/

The per-iteration `watch-and-boot` drivers used while hunting for a boot
configuration that survives on this device. Each one encodes the serial
(`33e80afe`) and an absolute image path, so they are a record of what was tried
rather than a general-purpose tool. Highest-numbered is newest:

- `v55` … `v60` — USB attribution / fakebind / packaging experiments
- `v61` … `v63` — post-init monitor and keeper variants; **v63 (`netd` disabled) is the configuration that gave stable RNDIS network access**
- `v64` … `v66` — attempts to make that configuration persistent in production
- `v67-quick-boot.sh` — quick `fastboot boot` of the v67 image
- `retest-v64.sh`, `test-v73.sh` — re-test drivers for the v64 and v73 images

These all use `fastboot boot`, which the plan has since retired: it does not
persist, it leaves dirty state, and it twice dropped the device into EDL. They
are kept as the record of what was tried, not as the way to do it now.

Image build inputs live in untracked `tmp-v*/` directories at the repo root
(see the ignore rules in `../.gitignore`); the resulting `.img` files are not
tracked either.
