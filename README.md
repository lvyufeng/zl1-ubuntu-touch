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
- [`docs/ubuntu-touch/53-the-bridge-libraries-are-absent-and-were-never-built.md`](docs/ubuntu-touch/53-the-bridge-libraries-are-absent-and-were-never-built.md) — **doc 50's open question answered, and the answer is simpler than "a symbol is missing": neither bridge library exists anywhere on the device.** `check-android-bridge-libs.sh --dev` reports `libubuntu_application_api.so` and `libbiometry_fp_api.so` MISSING under every `android_dlopen` path, and a full `find / -xdev` (plus `/android /vendor /system`) finds nothing — not a search-path problem, and `android_dlopen` really is passed that name (`add x0,x0,#0x998` → `0x2998`, `w1=1` = `RTLD_LAZY`). The cause is that they were **never built**: the sources are sitting in the local Halium tree as `halium/platform-api/android/hybris/Android.mk` (`LOCAL_MODULE := libubuntu_application_api`) and `halium/biometryd/android/hybris/Android.mk` (`libbiometry_fp_api`), both already branched for Android 9, and every HIDL interface they need is present in `hardware/interfaces/` — while `out/target/product/zl1/system/lib64/` holds the built `libui_compat_layer.so` and `libhwc2_compat_layer.so` and nothing for these two, and `device/leeco/zl1/` never mentions either. So the next stage for GPS and fingerprint is the same shape as the graphics compat layers: wire the two Android.mk in, build, install into `/userdata/zl1-hybris/lib/` (where the compat layers already live, and where the patched `libhidltransport.so` — the hardest dependency — already is), and give the two **system** units `HYBRIS_LD_LIBRARY_PATH`, since unlike the compositor they do not go through `lsc-wrapper` and their drop-ins currently carry only `LD_PRELOAD`. Not done yet, and building them only makes the symbols resolve — whether `android.hardware.gnss`/`biometrics.fingerprint` actually register is a separate question
- [`docs/ubuntu-touch/52-the-gui-and-touch-confirmed-by-the-user.md`](docs/ubuntu-touch/52-the-gui-and-touch-confirmed-by-the-user.md) — **the user confirms it directly: the graphical interface is fine and the touchscreen works.** Everything since doc 44 had been indirect evidence (frames rendered, backlight, QML, Mir sockets), and docs 47/49/51 each listed "the screen's contents have never been verified by eye" as the outstanding gap; that is now closed, and so is the touch item doc 48 left open ("8 event nodes enumerated, one real touch missing"). It also closes a consequence noted in doc 48: once `repowerd` came alive it began blanking the backlight on an idle timeout, which was only a problem if nothing could wake it — touch can. Device-side corroboration read at the same moment: `synaptics_dsx` on `input3` with `Handlers=kbd mdss_fb kgsl mouse1 event3 cpufreq` and `PROP=2` (`INPUT_PROP_DIRECT`, i.e. screen coordinates, no cursor), `/dev/input/event3` owned by `root:android_input`, the shell running and `repowerd` active — configuration evidence only, the user's touch is what settles it. With display and touch confirmed, the graphics stage is done and what remains is peripheral by peripheral: Wi-Fi (no `wlan0`, WCNSS never powered up), GPS/fingerprint (`pc=0x0` = a libhybris bridge symbol that resolved to NULL), audio (`pulseaudio` down with the ALSA card present), and camera/modem/Bluetooth untested. Also rewrites `install-kmsg-drain.sh` around what the device actually does: the ring is ~3470 lines / ~249 KiB, grows **not at all** while idle and ~3480 lines per 3 s (~90 KiB/s) while the host is talking, so a continuous drainer would write ~8 GiB/day for logs that are already gone — it now takes a bounded set of early snapshots instead. Two traps it guards against: `while read` over `/dev/kmsg` exits immediately having read nothing (a partial record read is `EINVAL`, so the follower must use `dmesg -W`), and a blank line before the shebang makes systemd report `Exec format error` / `status=203/EXEC` with no hint of the cause
- [`docs/ubuntu-touch/51-what-the-wlan-driver-wants-read-from-its-own-source.md`](docs/ubuntu-touch/51-what-the-wlan-driver-wants-read-from-its-own-source.md) — **read the WLAN driver's requirements out of its own source, because the boot log does not exist yet and the kernel tree is on this machine** (`/mnt/data/halium-zl1-build/kernel/leeco/msm8996`, the same `3.18.140-lineage-gc2f6e859-dirty`). It re-reads doc 49's measurements against the code: `wlan_setup` returns `penv->revision_id`, whose only writer is a `pci_read_config_word` — so `50` means the PCIe link is up and the chip answers config reads, not that the chip is alive; `soc:wlan_en_vreg` is the `vdd-wlan-en` regulator, so this board enables WLAN through a regulator rather than a GPIO; and `cnss-prealloc` at 0% is qcacld's pool, i.e. the host driver never got that far. The bring-up chain is `hdd_module_init → if_pci → cnss_wlan_register_driver` (vreg on, WLAN_EN high, `pci_register_driver`) → `cnss_pci_probe` (which deliberately **returns success having put the chip back to sleep**) → `MSM_PCIE_RESUME` → `wdrv->probe()`, and `wlan0` only exists after that last step — a step that retries four times and logs nothing until the final `Failed to probe WLAN`. Lists the exact strings to grep in the captured boot log, the exact firmware filenames for `revision_id = 0x32` (`qwlan30/bdwlan30/otp30/utf30/utfbd30/epping30/evicted30.bin`), and warns that much of this path is `pr_debug`. Also pins down a red herring: `fw_image_setup`'s only effect is `cnss_setup_fw_image_table`, whose FTM/MISSION/BDATA modes want `qftm.bin`/`qwlan.bin`/`bdwlan.bin` — not the `*30.bin` files this chip uses, none of which are present — which is exactly why writing `1` returned `EINVAL` and why writing `0` "succeeded" (0 is not in the enum, so it is a silent no-op). Nothing on the device writes that attribute; it is a dead interface, not the missing step
- [`docs/ubuntu-touch/50-the-pc-zero-is-a-bridge-symbol-that-resolved-to-null.md`](docs/ubuntu-touch/50-the-pc-zero-is-a-bridge-symbol-that-resolved-to-null.md) — **the two `pc=0x0` cores are a libhybris bridge symbol that resolved to NULL**: some host libraries do not link their Android side, they reach it at runtime via `android_dlopen("libxxx.so")` + `android_dlsym("u_xxx")`, and the 348-byte forwarder `u_hardware_gps_new` in `libubuntu_platform_hardware_api.so.4.0.0` NULL-checks the *cached* pointer (`cbz x1, <slow path>` at `+0x1c`) but not the one it just resolved — `str x0,[x19,#120]` / `ldr x1,[x19,#120]` / `mov x16,x1` / `br x16` with no test in between. So `android_dlsym` returning NULL is not an error path, it is `pc=0x0`, and `lr` points just past `bl u_hardware_gps_new@plt` inside `HardwareAbstractionLayer::Impl::register_callbacks` — which is exactly why only the real `gps::Provider` crashes and `dummy::Provider` never touches Android. The library it dlopens is `libubuntu_application_api.so`; `biometryd` is the identical shape one layer over (`libbiometry.so` dlopens `libbiometry_fp_api.so` for its 14 `u_hardware_biometry_*`). This is the class `build-hwc2-compat-layer.sh` already warned about — "it does not NULL-check those, so a missing one is a jump to address 0" — which was fixed for the graphics compat layers and never looked at for these two. `scripts/hybris-shims/check-android-bridge-libs.sh` reads the library and symbol names straight out of the host ELF's rodata (no device needed) and with `--dev` checks them under the `android_dlopen` paths. On-device verification is still pending: the device was in EDL when this was written, and no `/android/...` path appears in either core's `NT_FILE` list, which is consistent with the bridge never having loaded but is not proof
- [`docs/ubuntu-touch/49-two-cores-that-are-not-tls-wifi-stuck-at-wcnss-and-a-trip-into-edl.md`](docs/ubuntu-touch/49-two-cores-that-are-not-tls-wifi-stuck-at-wcnss-and-a-trip-into-edl.md) — **the two services that still segfaulted are no longer dying at the TLS slot, Wi-Fi is stuck one layer below where doc 48 said, and a driver rebind put the device in EDL**: with the shim in place `lomiri-location-serviced` and `biometryd` now crash with `pc=0x0` / `si_addr=0` — an indirect call to a NULL function pointer — inside `liblomiri-location-service.so.3.0.0+0xdaa68` and `libbiometry.so.2.0.0+0xd6750` respectively, and the location service only does it on the real `gps::Provider` (the `dummy::Provider` run survives 20 s untouched), so the TLS fault is behind it and the GPS/HAL path is the new bug. Also fixes a real trap in `hybris-crash-hunt.sh`: it picked the core by name and `%e` is truncated to 15 characters, so it silently analysed a stale `core.MirServerThread` from a previous boot and reproduced doc 45 exactly — it now picks by timestamp. The Wi-Fi inventory is much more specific than doc 48's: `CONFIG_WLAN=y`/`CONFIG_CNSS=y`/`CONFIG_CNSS_PCI=y` and 1356 `hdd_*` symbols in `/proc/kallsyms` (nothing is missing, everything is built in), `0000:01:00.0` is a `168c:003e` QCA6174 already bound to `cnss_wlan_pci`, `firmware_class/parameters/path` is `/vendor/firmware_mnt/image` with `qwlan30.bin`/`bdwlan30.bin` actually there, and `cnss-daemon`/`wifi@1.0-service`/`wificond` are all running in the container — but there is no `wlan0` and `cnss-prealloc/status` reads **1888 Kb, all free**, so the WCNSS subsystem has never been powered up. Finally the incident: `echo soc:qcom,cnss > /sys/bus/platform/drivers/cnss/unbind` looked like a reversible runtime probe, and instead took the device from RNDIS straight to **EDL (`05c6:9008`)** at 18:37:47 — USB port rebind does not recover it and QFIL-class tools are ruled out, so it needs a physical power-button reset. Never unbind `cnss`/`cnss_pci` on this device
- [`docs/ubuntu-touch/48-the-tls-fault-was-killing-seven-system-services.md`](docs/ubuntu-touch/48-the-tls-fault-was-killing-seven-system-services.md) — **the same bionic-TLS fault was killing seven system services, not just the compositor**: after the GUI came up, `systemctl --failed` held `mechanicd  repowerd  sensorfwd  urfkill  hfd-service  lomiri-location-service  biometryd`, all `code=killed, signal=SEGV`. Docs 41/45 fixed the TLS slot for the compositor and the session and nothing else; these are the Halium services (power, sensors, rfkill, haptics, GPS, fingerprint) that call into Android through libhybris. An `LD_PRELOAD` drop-in on the `/etc/systemd/system` writable-path takes `mechanicd`, `repowerd`, `urfkill` and `hfd-service` straight to **active**, leaves `sensorfwd` no longer crashing but not ready, and `lomiri-location-service`/`biometryd` still segfaulting (next: cores, not guesses). Also carries the hardware inventory — display and touch enumerated, audio card present but pulseaudio down, camera/modem nodes present, `repowerd` now owns the backlight (it blanked to 0 on an idle timeout once it came alive, which is the display-power chain working, and it stays at 128 once set), and **no `wlan0`, no wireless module, firmware only in `/vendor/firmware_mnt`**. `scripts/hybris-shims/install-system-tls-preload.sh` scans for libhybris-linked units and adds a curated list for the five that load their Android HAL through a runtime plugin
- [`docs/ubuntu-touch/47-the-screen-comes-back-by-itself.md`](docs/ubuntu-touch/47-the-screen-comes-back-by-itself.md) — **the screen now survives a reboot, and the thing that nearly broke that is in the container's framework**: with both halves installed as boot units, a cold reboot re-laid all three file overlays and both GPU nodes at uptime 42 s and stopped the container's SurfaceFlinger at 62 s, and Lomiri was up with `backlight=128` at 127 s — no manual step. The same reboot also exposed a delayed hazard: stopping the container's SurfaceFlinger leaves Android's `system_server` in `I/ServiceManager: Waiting for service SurfaceFlinger...` forever, and `W/RescueParty: Noticed 2 events for UID 0 in last 126 sec` is the framework's crash-loop escalator, whose last level reboots into recovery. The device did land in TWRP (3.3.1-0) once, with `misc` reading all zeros afterwards (the BCB was consumed); nothing in the host's own scripts writes `boot-recovery` — grepping `/data/system-data/` finds only `zl1-netwatch.sh`, whose `RECOVERY_AFTER` marker file does not exist and whose log has no `RECOVERY:` line. Fixed by leaving the container at the HAL layer: `persist.sys.disable_rescue=true` plus `ctl.stop zygote`, which takes the HIDL count from 145 to 146, drops the load average from 14.0 to 8.9, and leaves zero `RescueParty`/`SurfaceFlinger` lines in the recent log. Both are now in the container watchdog. Everything the host needs is an init service, not a zygote child
- [`docs/ubuntu-touch/46-the-gui-runs-dev-ion-was-root-only.md`](docs/ubuntu-touch/46-the-gui-runs-dev-ion-was-root-only.md) — **the graphical interface runs**: `lomiri --mode=full-greeter` stays up for 98+ seconds with `[PERFORMANCE]: Last frame took 60 ms to render` in its log, QML loading, 49 user units running, both Mir sockets present, backlight 128. The last blocker was not libhybris, Mir or EGL — it was device node permissions: `/dev/ion` is `crw------- root root`, the session runs as `phablet`, so `eglInitialize()` failed with `EGL Error 3001` (`EGL_NOT_INITIALIZED`) and Mir reported it as `could not select EGL config`. `test_egl_configs` as root prints 68 configurations, as phablet prints `EGL Error 3001`; `chmod 666 /dev/ion` closes the gap (chmod'ing `/dev/kgsl-3d0` alone did not — ion is the one that matters). The system compositor never hit this because lightdm starts it as root. Runtime-only: both nodes are on devtmpfs and come back `0600 root:root` after a reboot. `scripts/hybris-shims/free-gpu-devices.sh` applies and checks it. Lists the five independent walls that had to fall, four of them on the host side
- [`docs/ubuntu-touch/45-the-shell-crashed-on-a-thread-then-picked-the-wrong-linker.md`](docs/ubuntu-touch/45-the-shell-crashed-on-a-thread-then-picked-the-wrong-linker.md) — **the Lomiri session's two failures were two different bugs wearing one log line**: `lomiri-full-greeter.service` (a systemd *user* unit started by `ubuntu-touch-session`, not the lightdm greeter session) starts Mir and then died `status=11/SEGV`. First: the bionic-TLS-slot shim's constructor only runs on the thread it is loaded on, so every `pthread_create`d thread got a zeroed TCB and `__get_thread()` returned NULL again — the kernel's own core filename gives it away (`core.MirServerThread.*`, the crash is on Mir's server thread). Fixed with a `pthread_create` interposer in the shim that fills `TP+8` before the new thread's entry point; the SEGV became a clean `status=1/FAILURE`. Second: with the crash gone the log showed `dlopen failed: library "libGLESv2_adreno.so" not found` — libhybris picks one of four linkers (`libhybris/linker/{mm,n,o,q}.so`) and **`q.so` has no `/vendor/lib64/egl` in its default search path while `o.so` does**; the compositor (working, `Adreno (TM) 530`) maps `o.so`, the shell maps `q.so`, with identical `HYBRIS_LD_LIBRARY_PATH` in both. Pinning `HYBRIS_LINKER=o` in a **unit-level** drop-in removes every `dlopen failed` line, and the failure moves on to Mir's `could not select EGL config` (`src/platforms/android/server/gl_context.cpp:127`). Also records where a user unit's environment actually comes from: `environment.d` does nothing, `[Manager] DefaultEnvironment=` takes but does not override an inherited variable, and only the unit's own `Environment=` wins — plus the `systemctl --user daemon-reload` that has to run as `phablet`, not root
- [`docs/ubuntu-touch/44-the-v63-image-sabotages-its-own-container.md`](docs/ubuntu-touch/44-the-v63-image-sabotages-its-own-container.md) — **the screen lights up, and the reason it never had was inside our own boot image**: the v63 LXC mount hook bind-mounts tmpfs copies of `hwservicemanager`, `qseecomd` and both `libc.so` over the real files with one *same-length* string changed in each — `hwservicemanager.ready` → `zlservicemanager/ready`, `sys.listeners.registered` → `zl1.listeners.registered`, `/dev/socket/property_service` → `/dev/socket/property_servicf`. They are V25/V28/V29/V30 diagnostic experiments frozen into the image by `0e95c3a`, and they are exactly the two "mysteries" doc 42 and 43 left open: no HAL can ever see `hwservicemanager.ready`, and every property write from inside the container fails with ENOENT on a socket path that does not exist. Found by noticing that the *same* binary at the *same* path has a different md5 and a different `st_dev` depending on the mount namespace, then reading `/proc/self/mountinfo` inside the container. Lifting the four over-mounts gives 145 registered HIDL services and zero `waiting another` lines; the second half is stopping the container's SurfaceFlinger, which holds the QCOM composer's single client slot (`ComposerHal.cpp:182 LOG_ALWAYS_FATAL("failed to create composer client")`), after which Mir reports `Active output [1] at (0, 0) is 1080x1920` with the Adreno 530 driver, the backlight goes to 128, and `/run/mir_socket` appears. Both halves are runtime-only and die with the container; making them permanent needs a new boot image. `scripts/hybris-shims/free-container-display.sh` applies and checks them
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
