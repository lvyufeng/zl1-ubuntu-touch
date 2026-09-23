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
| `host/zl1-rndis-recover.sh` | Host-side only. `--status` / `--force` / `--quiet`. Gets the RNDIS link back **without touching the device** when it stalls: re-applies the addresses, then unbind/rebinds `rndis_host`, then re-enumerates the gadget with the `authorized` 0 -> 1 toggle (the step that fixed the 2026-09-23 stall -- it is the same USB reset the device sees on every boot and it does not cut power), and with `--force` unbinds/rebinds the whole USB device as a last resort. Each step is followed by a real end-to-end test (a 3-packet ping *and* an SSH that reads `/proc/uptime`), and it stops at the first step that works. Matches the gadget on the serial prefix `33e80afe`, never on the USB ID. Every step is a host sysfs write -- no device storage is touched and the device is never asked to do anything. See [`../docs/ubuntu-touch/76-a-stalled-link-is-a-host-side-problem.md`](../docs/ubuntu-touch/76-a-stalled-link-is-a-host-side-problem.md). |
| `host/zl1-health-check.sh` | The first command of every stage. Classifies the device into one of four states and routes to the right tool: **not on the bus** / **EDL** (`05c6:9008` — physical reset only, a long power press; docs 49 §6) / **RNDIS present but not carrying traffic** (a *host-side* problem, docs 76 — hand it to `zl1-rndis-recover.sh`) / **reachable**. Past the link it runs the self-check: device-tree model contains `LE_ZL1`, `adb devices` has no `33e80afe`, `systemctl --failed` empty, the container running (`lxc-info`, never `lxc-ls` — that lies about a running container), the `sensorfwd`/`repowerd`/`lightdm` trio (docs 69: repowerd dies unless it starts after sensorfwd's READY=1), `ActiveOutputs`, the debug keeper's state (docs 72), the thermal zone and cpu0's governor. Then it prints what is owed with the commands: the **EDL post-mortem** first (docs 86 — the only boot that can still answer what killed the last one), then **who configured `rndis0`'s addresses on this boot** (docs 88 — the verdict that licenses retiring the debug keeper, a full core and the port's second heat source), then **the panic → EDL path**, split into the half that costs nothing (`install-no-edl-on-panic.sh --capture-only`: start saving pstore, which nothing saves today) and the half that is a device write and must be offered rather than assumed (`--install`), then the four measurements. Read-only: it pings, SSHes and reads; it never runs the RNDIS recovery for you, never writes a sysfs node, never flashes. `--quiet` / `--no-ssh`; exit 0 = self-check passed, 1 = reachable with warnings, 2 = unreachable. Its EDL branch was exercised against the real device; its classifier against synthetic USB tables including the Xiaomi that must be ignored. |
| `host/install-zl1-udev-rule.sh` | Installs/removes those two into `/etc/udev/rules.d/` and `/usr/local/sbin/`. |

## Getting in and out of the device

| Script | Purpose |
| --- | --- |
| `enter-recovery-from-ut.sh` | Phase 2.5's other half: get from a running Ubuntu Touch into TWRP with **no key press**, by writing `boot-recovery` into `misc` (what Android's own `reboot recovery` does). 20 s, measured 2026-09-21. Refuses to reboot unless the command reads back correctly — a reboot without it is a reboot loop, not a degraded version of the feature. |
| `stage2-rollback-resume.sh` | Pick up the rollback drill after its wait for a human key press expires. Waits as long as it takes, then runs the same hash-verified rollback. |

## On-device runtime

| Script | Purpose |
| --- | --- |
| `device/zl1-netwatch.sh` | Runs on the device. Samples the RNDIS gadget's own counters, the interface counters and the routing state into `/userdata/zl1-netwatch.log`, and **re-asserts the gadget** when it detects the intermittent transmit stall. It also re-asserts the two device-side addresses every sample (`ensure_addrs()`, logged as `ADDRS:` only when something was actually missing) -- the same shape, and for the same reason, as the policy routing it re-asserts: a heal, or the gadget re-binding, can take them away just as `netd` takes the rules away. That is what makes retiring the v63 debug keeper a small step instead of a gamble: before it, `restore_addrs()` was reachable only from the heal stages, so a keeper-less boot had no address for ~135 s and was then fixed by a full RNDIS re-enumeration (docs 88). Can also ask the bootloader for recovery after a configurable delay. |
| `install-kmsg-drain.sh` | `--install` / `--remove` / `--status` / `--read [LINES]` / `--bad` / `--follow-on` / `--follow-off`. Keeps the **boot** half of the kernel log, which is otherwise unreachable: `journalctl -k` returns 1 line (journald is not capturing `/dev/kmsg`), and the ring is small and the noise is fast — measured on the device, ~3470 lines / ~249 KiB, growing **not at all** while idle but ~3480 lines per 3 s (~90 KiB/s) while the host is talking, so the earliest surviving line can be only ~10 s old. The noise is `tx_complete` WARN stack traces from our own uether patch, triggered by host traffic — which is exactly why the boot messages are still catchable, but only before anything starts talking to the device. So this is not a follow-the-log drainer: a `DefaultDependencies=no`, `Before=sysinit.target`, `Type=simple` unit snapshots the **whole** ring (via `dmesg`, i.e. `SYSLOG_ACTION_READ_ALL`) at ~0/5/15/35/75/155/315 s of uptime and then exits — a couple of MiB per boot, no eMMC wear. **The set is no longer discarded at the next boot** (2026-09-21): the previous boot's snapshots are archived to `keep/boot-<boot_id>/` before the wipe, newest 4 kept, and a boot whose ring contains `Invalid firmware metadata` or `scm_call failed.*ret: -12` copies itself to `keep/bad-<boot_id>/` as soon as the signature appears (never pruned). Both exist for the same reason: the one cold boot whose secure world refused had its early half deleted by this script's own `rm -f boot-*.log`, leaving only ring-buffer tails starting at t=288 s and t=102 s, so the t<49 s diff [`../docs/ubuntu-touch/58-*`](../docs/ubuntu-touch/58-one-cold-boot-where-the-secure-world-refused-and-three-firmwares-did-not-load.md) §4 asks for could not be made. The archive naming uses the *previous* boot's id, remembered in `keep/current-boot-id`. Snapshots are denser early (sampled at ~0/5/10/15/25/45/85/165/325 s). `--bad` is the §4 query: for every archived boot it prints the secure-world lines and a func-id/errno tally, always over that archive's **earliest** snapshot. `--status` reports the archives and each one's earliest file. See [`../docs/ubuntu-touch/59-the-boot-log-was-deleted-by-its-own-collector.md`](../docs/ubuntu-touch/59-the-boot-log-was-deleted-by-its-own-collector.md). `--read` greps every snapshot (this boot's and every archive's) and the optional live log for `cnss|wlan|wcnss|qca6174|ar6320|qcacld`, which is the table in [`../docs/ubuntu-touch/51-what-the-wlan-driver-wants-read-from-its-own-source.md`](../docs/ubuntu-touch/51-what-the-wlan-driver-wants-read-from-its-own-source.md). `--follow-on` re-enables a continuous `dmesg -W` trace for the rare case of watching a driver live — off by default because of the eMMC cost. Two failure modes are documented in [`../docs/ubuntu-touch/52-the-gui-and-touch-confirmed-by-the-user.md`](../docs/ubuntu-touch/52-the-gui-and-touch-confirmed-by-the-user.md) and guarded against here: `while read` over `/dev/kmsg` exits immediately having read nothing (a partial read of a record is `EINVAL`), so the follower uses `dmesg -W`; and a leading blank line before the shebang makes systemd report `Exec format error` / `status=203/EXEC`, so the script asserts the first line of what it pushes starts with `#!`. Installed and running on the device; the boot-time half is verified by the next reboot. |
| `install-machine-info.sh` | `--install` / `--remove` / `--status`. Stops the device calling itself "Generic device". `update-machine-info-from-deviceinfo` was never broken: `dbus-monitor --system` shows it does `GetAll` on `org.freedesktop.hostname1`, then `SetChassis`, and **never calls `SetPrettyHostname`** — it writes the pretty hostname only when the current one is **empty**, and this image ships `/etc/machine-info` with `PRETTY_HOSTNAME="Generic device"` (a placeholder **no package owns** — `dpkg -S` finds no path). So `--install` reads the real name from `device-info` first (and refuses if there is none, since blanking the line would leave the machine nameless), saves the image default to `/userdata/zl1-machine-info/image-default.machine-info` **once**, strips the stale line and lets the unit fill it from deviceinfo. `--status` prints the deviceinfo view, systemd's view and **the content of the saved default**, because a first version of this script created the backup *after* the fix and thus saved the already-correct file, making `--remove` a no-op. Two facts about `/etc` on this port that any future file edit needs: `/` is a **read-only** ext4 image and only a whitelist under `/etc` is bind-mounted rw from `/dev/sda10` (`/etc/writable`, `/etc/systemd/system`, `/etc/ssh`, …); **`/etc/machine-info` is a symlink into `/etc/writable`**, so `sed -i /etc/machine-info` fails — GNU sed writes its temp file next to the symlink, in a read-only directory — and the real path must be resolved first. Also: no new file can be created in `/etc`, so backups live in `/userdata/`. This script deliberately does **not** add a deviceinfo yaml or a `SensorfwConfig` — see [`../docs/ubuntu-touch/64-*`](../docs/ubuntu-touch/64-the-last-unit-was-not-failing-it-was-obeying.md) for why both would be wrong. |
| `install-repowerd-ordering.sh` | `--install` / `--remove` / `--status`. Stops `repowerd` dying at boot, by making it wait for `sensorfwd`. `repowerd` was `failed (Result: signal)` / `code=killed, status=11/SEGV` for a whole boot and `com.lomiri.Repowerd` was absent from the system bus — and since **nothing else on this port owns idle/screen policy**, that is both "the screen goes dark" and "nothing can bring it back", i.e. the user's "黑屏了 / 都没反应". It is a **race, not a missing feature**: the shipped unit has **no ordering against `sensorfwd.service`** (`After=lxc-android-config.service dbus.socket`) and is **`Restart=no`**, while `repowerd`'s sensorfw backend calls `load_plugin()` at startup with a **10 s** timeout and `sensorfwd` is `Type=notify` and does not reach `READY=1` until 13.25 s in — so the call timed out, `repowerd` fell back to `NullLightSensor`, and SEGV'd 3 s later, permanently. (The fallback is not the crash: the same `NullHBM` / `NullPerformanceBooster` fallbacks happen on the runs that survive.) The drop-in is `After=sensorfwd.service` + `Wants=sensorfwd.service` (ordering after a `Type=notify` unit means after its `READY=1`, bounded by `DefaultTimeoutStartSec`) plus `Restart=on-failure` / `RestartSec=5` as the net, because `sensorfwd` restarts ~3 more times after its first READY until the container's sensor HAL settles. **Verified by re-running the race, not by reading `is-active`** (`Type=dbus` printed `Started` and died 3 s later once before): both units stopped, `systemctl start repowerd` leaves `sensorfwd.service start running` / `repowerd.service start waiting` in the job list, `Started sensorfwd` [1739.422] precedes `Starting repowerd` [1739.445] by 23 ms, `load_plugin` succeeds (the `minLimit`/`maxLimit` pair, which appears exactly once per successful load), no stall, no SEGV, and 24 minutes later `com.lomiri.Repowerd` / `.Settings` / `com.canonical.Unity.Screen` are all on the bus. With it alive the display comes back through `repowerd`'s own interface — `keepDisplayOn` takes `ActiveOutputs` 0 0 → 1 0, `backlight` 0 → 118, `msm_fb_panel_status` `suspend` → `alive`. Deliberately not done: no `SensorfwConfig`, no device yaml (doc 64 §5), and no attempt to switch the sensorfw light sensor off — there is no such knob (`/etc/default/repowerd` is all comments and `/usr/sbin/repowerd` has no long options at all). See [`../docs/ubuntu-touch/69-repowerd-died-on-a-startup-race-with-sensorfwd.md`](../docs/ubuntu-touch/69-repowerd-died-on-a-startup-race-with-sensorfwd.md). |
| `install-cpufreq-governor.sh` | `--install` / `--remove` / `--status` / `--governor NAME`. Puts the four CPU cores on a scaling governor instead of the `performance` the image ships — all four cores were pinned at `scaling_max_freq` (1132800/1132800/1363200/1363200) with `cur == max`, i.e. burning full power while idle, which is the single biggest avoidable heat source on a battery-powered msm8996. `interactive` is the choice because this kernel has no `schedutil` and `interactive` is what these Qualcomm kernels normally default to; idle cores then sit at 307200/460800 MHz. It writes two files on the writable `/etc/systemd/system` path (a `Type=oneshot` unit that runs `Before=multi-user.target` and an idempotent applier you can also run by hand) and **does not** touch `scaling_max_freq`, `min_freq`, or any thermal trip point — the device registers **no cooling devices at all**, so there is no kernel throttling to tune. Verified with `systemctl cat` (the only honest check a unit is in effect), `Result=success`, and reading `scaling_governor` back. See [`../docs/ubuntu-touch/72-the-heat-was-the-governor-and-a-debug-keeper.md`](../docs/ubuntu-touch/72-the-heat-was-the-governor-and-a-debug-keeper.md). |
| `install-no-edl-on-panic.sh` | `--status` (default) / `--install` / `--capture-only` / `--remove`. Closes the **one** automatic path from a kernel panic to Qualcomm EDL that can be closed without flashing: doc 86 showed that `download_mode` is a compiled-in **1** (`drivers/power/reset/msm-poweroff.c:63`) and that a panic makes `msm_restart_prepare()` set the dload flag before the forced watchdog bite (`:278`), so the SoC resets into the download loader instead of booting. `echo 0 > /sys/module/*/parameters/download_mode` uses **the driver's own 0644 `module_param_call`** (`:95`, validated at `:191`) and changes nothing else — every ordinary shutdown already evaluates it to `set_dload_mode(0)` (`:279`), and the flag is re-armed to the image's default at probe. Because a claim needs a witness it also installs a **read-only** boot unit that copies `/sys/fs/pstore/*` into `/userdata/zl1-kmsg/keep/pstore-<boot_id>.pstore/` (newest 4 kept, indexed in `pstore-archive.log`) — nothing captured pstore before this; `install-kmsg-drain.sh` handles the kmsg ring, which dies with the reset. Both appliers are idempotent shell on the writable `/etc/systemd/system` path; no partition, no boot image. The policy applier **verifies by read-back and exits 1 if the flag did not clear** — a guard that silently is not armed would be worse than a failed unit, which at least shows up in `systemctl --failed`. `--capture-only` never touches the policy unit (an earlier draft disarmed an installed guard while "just looking", i.e. in the unsafe direction). **It does not prove EDL cannot happen**: the forced watchdog bite is untouched and whether this bootloader treats a watchdog reset as a download-mode trigger independently of the flag has never been tested. Attribute a trip with `device/zl1-edl-postmortem.sh`, never by assuming this unit prevented it. See [`../docs/ubuntu-touch/89-one-gate-to-edl-is-closed-and-it-is-reversible.md`](../docs/ubuntu-touch/89-one-gate-to-edl-is-closed-and-it-is-reversible.md). |
| `install-netwatch-service.sh` | With the device in TWRP, installs that watchdog as a systemd unit under `/userdata/system-data/etc/systemd/`. Persistent, and no rootfs change needed — the rootfs is read-only at runtime, but `/etc/systemd/system` is a writable-path bind mount. Backs up `misc` first. |
| `twrp-one-shot-setup.sh` | Waits for TWRP, installs the watchdog, fixes SSH, sets the "return to recovery after N seconds" marker, and reboots. Optionally flashes a given boot image. One button press sets up everything after it. |
| `fix-policy-routing.sh` | Installs the netwatch build that carries the policy-routing fix. The rule itself is added at boot by netwatch, because netd reinstalls its rules as the container restarts. |
| `fix-ssh-authorized-keys.sh` | **The SSH fix.** Points `AuthorizedKeysFile` at `/etc/ssh/authorized_keys.d/%u`, a persistent writable-path, instead of a user's home directory. Run from TWRP. |
| `fix-ssh-sshd-config.sh` | June attempt: appends `PermitRootLogin`/`PasswordAuthentication` to the userdata `sshd_config`. Kept for the record; superseded — it never touched `AuthorizedKeysFile`. |
| `install-ssh-to-userdata.sh` | June attempt: writes the key to `/userdata/root/.ssh`, which is **not** where `/root` resolves (it comes from `/userdata/system-data/root`). Kept for the record; superseded by `fix-ssh-authorized-keys.sh`. |
| `zl1-status-server-enhanced.py` | HTTP status server with a command-execution endpoint; deployed into the ramdisk at `/usr/local/sbin/`. |

## Measuring input, one layer at a time

"The back key does not work" is a statement about the whole chain `key controller → driver →
evdev → libinput/Mir → the shell`, and from the GUI side every break in it looks identical. These
two split it in half: an event known to be well-formed, injected **below** the point of suspicion,
and a watcher that records what the **hardware** actually reports. See
[`../docs/ubuntu-touch/68-the-camera-stage-was-one-cookie-in-the-stub.md`](../docs/ubuntu-touch/68-the-camera-stage-was-one-cookie-in-the-stub.md) §7.

| Script | Purpose |
| --- | --- |
| `device/zl1-watch-input.py` | Runs on the device. Opens **every** `/dev/input/event*` and logs every event, decoded, to `/userdata/zl1-input-watch.log`. Three deliberate choices: **no `EVIOCGRAB`** (grabbing would take the device away from the compositor, so the very input it is measuring would stop reaching the thing that is supposed to act on it, and the phone would look even deader while it ran); **no filtering** (a key press on this hardware arrives as a burst whose shape is part of the evidence); **one `select()` loop over all eight devices**, so inter-device ordering is real. Rescans `/dev/input` every 5 s (so a device created while it runs is picked up — that is what makes it testable) and drops a device on EOF rather than spinning on it. |
| `device/zl1-input-devices.py` | Runs on the device. Prints what each `/dev/input` device **can** report, decoded from `/proc/bus/input/devices` alone — no ioctl, no open of `/dev/input`, nothing that could disturb a running compositor. It is the companion of the watcher: that one shows what the hardware *does* report, this one what it *can*, and "the back key does nothing" has two shapes that look identical on screen — the key is in no device's `KEY` bitmap (driver never declares it, nothing above the driver can help) versus it is declared and never fires (driver/firmware). **Its first result already moved the search**: `synaptics_dsx`, the *touchscreen*, declares exactly 6 keys and **`BACK`(158) `HOMEPAGE`(172) `WAKEUP`(143) are among them** — the capacitive back/recent keys are part of the touch controller on this phone, so they will arrive on the touchscreen's event node, not on `qbt1000_key_input` (whose 225-key bitmap is the garbage `0xfe` pattern and is not evidence of anything). Note the decode convention: the kernel prints the bitmap as space-separated 64-bit words with the **low word last**, so the word order has to be reversed before indexing, or every key comes out shifted. |
| `device/zl1-watch-input.py` + `device/zl1-input-devices.py` (confirmed) | Together they closed the back-key question on 2026-09-22 with the user's own fingers: 51 s of real use, 3146 events, **`KEY BACK` down/up pairs on `synaptics_dsx`** and **zero events from `qbt1000_key_input`** in the whole window. The capability dump had said the touchscreen declares `BACK`/`HOMEPAGE`/`WAKEUP`; the watcher then showed it *sends* them too, so the detector is not the suspect and the remaining gap is the shell (`grep -rn "Qt\.Key_Back\b" /usr/share/lomiri/` is **empty** — the shell has no handler for it anywhere; the three files that look like hits are `Key_Backtab`/`Key_Backspace`, and there is no `strings(1)` on this device, so binary searches need `grep -a`). See [`../docs/ubuntu-touch/73-the-user-fingers-settled-the-back-key.md`](../docs/ubuntu-touch/73-the-user-fingers-settled-the-back-key.md). |
| `device/zl1-shell-back-key-apply.sh` | Runs on the device **at boot** (from `zl1-shell-back-key.service`, installed by `install-shell-back-key.sh --persist`). Mounts the patched `Shell.qml` over the read-only image, with four ordered guards — a `/userdata/zl1-shell-back-key.disabled` sentinel (the escape hatch: touch it over SSH and reboot to get the stock shell back), overlay missing/empty, overlay without the patch marker, and a **read-back** of the marker from the target path after mounting (it must never trust the mount table — see the two tooling bugs in its comments and in doc 75 §6). Logs every decision with the device's uptime to `/userdata/zl1-shell-back-key.log`. |
| `device/zl1-inject-input.py` | Runs on the device. `--tap X Y` / `--swipe` / `--key CODE` / `--keys` / `--devices`, via `/dev/uinput` — so the injected event is a **kernel** evdev event and travels the same road a real one does. `make_touch()` sets `INPUT_PROP_DIRECT` so libinput calls it a touchscreen rather than a touchpad; without that the events arrive as relative pointer motion and nothing on the greeter reacts. `--keep-seconds N` holds the device open, which is how "did the compositor even take this device" gets answered (look for `/dev/input/eventN` in the compositor's `/proc/<pid>/fd`) — and `--repeat N --every MS` exists because a process that creates a device, uses it once and closes it **cannot be watched**: a reader only sees a device after it exists. Nothing is written anywhere but `/dev/uinput`; the worst case is a stuck key, which is why every action ends with the matching release. **The load-bearing negative result is in the header**: injection cannot drive this GUI, because the compositor opens all `event*` at startup and does not hotplug input devices afterwards (doc 68 §6). |

## The back key

The chain above ended in a real break, and it was not in the input layer: nothing in the shell handled
`Qt.Key_Back`, so the key arrived and died. It now does what the Home key does, and the whole path from
"the user pressed it" to "the app minimized" is in doc 75 — including the two attempts that failed
differently: one threw `TypeError` (the call is a signal handler inside `Stage.qml`, not a public
function) and one ran clean with **no effect at all** (window decorations, hence minimizing, only exist
when the shell's mode is `windowed`; the phone runs `staged`). Silent no-ops are harder to find than
errors, so every change here has to be confirmed by a human pressing the key.

| Script | Purpose |
| --- | --- |
| `install-shell-back-key.sh` | `--install` builds a patched `Shell.qml` on `/userdata`, lints stock vs patched and diffs the diagnostics (a new error would mean a black screen), and bind-mounts it over the read-only `/usr/share/lomiri/Shell.qml`; the patch is an exact-anchor replacement that refuses to run unless the anchor appears exactly once, and `--install` always unmounts first so it rebuilds from the stock file rather than from its own output. `--remove` unmounts, `--status` reports the mount and the keys the shell has logged, `--persist` installs the boot unit, `--unpersist` removes it. See [`../docs/ubuntu-touch/75-the-back-key-works.md`](../docs/ubuntu-touch/75-the-back-key-works.md). |
| `device/zl1-shell-back-key-apply.sh` | The boot-time half, run by `zl1-shell-back-key.service`. |

## Measuring the sensor pipeline (three calls, not two)

sensorfw is asked for a sensor in **three** steps, and skipping any of them produces a wrong answer
rather than an error:

```
loadPlugin(name)          -> loads the plugin; (true,) / (false,)
requestSensor(name, pid)  -> creates a session and the bus object; returns a session id, or -1
<iface>.start(sessionId)  -> the session actually starts producing samples
```

`requestSensor` before `loadPlugin` answers `-1` with `requested sensor id 'x' not registered`, which
reads like "this device has no sensor x"; and a sensor that was never `start()`ed still answers
`isValid = true` with a legal `(timestamp, value)` — the value from the last time *someone else*
started it, which reads like "the sensor is frozen". Both were mistaken for hardware faults on
2026-09-22 and both were measurement bugs. See
[`../docs/ubuntu-touch/71-the-sensors-stream-the-restart-kills-the-hal.md`](../docs/ubuntu-touch/71-the-sensors-stream-the-restart-kills-the-hal.md).

The other half of the measurement is the **age** of a reading, not "did it change": sensorfw's value
is `(timestamp_us, ...)` where the timestamp is the uptime in microseconds at which the *sample* was
produced, so `now - timestamp` separates "40 s old" from "from a previous boot" — and those are
different diseases that a two-read comparison cannot tell apart.

| Script | Purpose |
| --- | --- |
| `device/zl1-quiet-debug-keeper.sh` | `--stop` / `--resume` / `--status` / `--wait N`. Runs on the device. Silences the v63 debug network keeper (`/usr/local/sbin/zl1-debug-net.sh`) **without touching the boot path** — measured cost: **a full core** (a 15 s A/B gives busy 0.87 cores stopped vs 1.84 running; the first estimate of "6.6% of a core" counted only the keeper's own ticks and missed its `systemctl` children and pid 1's daemon-reloads), and it runs `systemctl mask --runtime usb-moded.service` and `systemctl stop usb-moded.service` **every second**, which makes systemd daemon-reload every ~6 s at ~2 s each. With it SIGSTOPped: **systemd used 1 s of CPU in 300 s**, zero reloads, load 6.76 → 6.04, and the SoC fell 5.5/6.1/2.7 °C (tsens1/tsens8/pm8994) *while the battery was still charging*. It is a **signal, not a mask, on purpose**: the keeper is also what gives `rndis0` its addresses at boot, `systemctl` cannot manage the process at all (the script daemonizes, so its unit thinks it exited after 67 ms), and a boot without the keeper is unverified — so this only changes the running state, is reversible with `--resume`, and comes back after a reboot. Our own `zl1-netwatch.sh` (45 s stall detector + `restore_addrs()`) is the net that keeps the network up in the meantime. See [`../docs/ubuntu-touch/72-the-heat-was-the-governor-and-a-debug-keeper.md`](../docs/ubuntu-touch/72-the-heat-was-the-governor-and-a-debug-keeper.md). |
| `device/zl1-sensorfw-probe.sh` | Runs on the device. `--load-all` / `--sensor NAME` / `--settle N` / `--gap N` / `--keep N`. Does all three calls per sensor and prints each reading's **age** in seconds, then judges `STREAMING` (a new sample arrived inside the window) / `SLOW` (none in the window, but the last one is fresh — the shape of an adaptor still spinning up: the measured first-sample latency after a `start` is 10-20 s) / `STALE` (with the age, so "40 s" and "from the last boot" are distinguishable). Reads only: it loads plugins, asks for sensors and reads properties, and it writes nothing. `--sensor NAME` (repeatable) is the only way to reach a sensor nobody subscribes to, because the enumeration is `busctl tree` and a bus object exists only once someone has asked — measured 2026-09-23: after a `sensorfwd` restart the tree held only `alssensor`/`magnetometersensor`/`orientationsensor` (what repowerd asks for), and the accelerometer and gyroscope could not be measured at all without naming them. Timestamp 0 is reported as **"no timestamp"**, not as an enormous age: `alssensor` leaves its timestamp at 0 while its level moves (94 → 96 → 98 → 97), so the verdict separates "no timestamp but the value moves" from "no timestamp and frozen". Two things it says about itself in its header, both measured: it **perturbs what it measures** (loading a plugin starts an adaptor, and an adaptor start is itself what makes this hardware emit a sample), and **restart `sensorfwd` only through `device/zl1-sensors-recover.sh`** — one `systemctl restart sensorfwd` can make the container's sensors HAL kill itself and leave sensorfw holding a connection to the corpse (docs 71 §3; but 0 of 1 in the 2026-09-23 recovery, where the HAL was restarted first — see docs 78 §4). |
| `device/zl1-sensors-recover.sh` | Runs on the device, next to `zl1-sensorfw-probe.sh` (it calls it and refuses to run without it, rather than pretending to verify). `--status` / `--recover` / `--wait N` / `--no-probe` / `--quiet`. Puts the whole sensor stack back **without a reboot**, in the order that matters: kill the container's sensors HAL (`init` always restarts it — the service is `vendor.sensors-hal-1-0`, `class hal`, no `oneshot`), **wait until the fresh one is registered** (its ISensors node is in `/sys/kernel/debug/binder/state` and hwservicemanager holds it), *then* restart `sensorfwd`. Doing it in that order is what makes docs 71 §4's coin flip deterministic: by the time the client restarts, a live server is already there, and it is not polling a live HAL as it stops, so the suicide trigger has nothing to fire on. Measured 2026-09-23 (docs 78): with the clock fixed 8.2 hours of silence, accelerometer + gyroscope + magnetometer all STREAMING again within minutes. `--status` is read-only and prints the HAL's pid/age, who holds its ISensors node (any pid other than `40677` = hwservicemanager is a client), the calls in flight **and whether they are still there 5 s later** (one in flight is normal while a call is being served; the wedge was one that never returned — but the sample ages are the verdict, not this line). It does **not** fix `orientationsensor` (one sample 1.8 s after the restart, then frozen) or `alssensor`, and it says so instead of papering over them. |
| `device/zl1-orientation-watch.sh` | Runs on the device. `--seconds N` / `--interval N` / `--quiet`. Prints one line per second: uptime, the orientation classifier's **position**, how old that sample is, and the accelerometer's three axes — then a summary of which positions were seen and how many times it changed. This is the 30-second test for the one question about this sensor that measurement cannot settle: the classifier reports **6** (face down) while the accelerometer holds z at **+1010 mG** (face up in Android's frame), so either its classification or its numbering differs from AOSP's, and that is visible only while someone picks the phone up and turns it over. It matters: qtmir reads this value to decide the shell's orientation, and doc 71 measured 6 being mapped to `Qt::InvertedLandscapeOrientation` (docs 70/71 — "the shell keeps going landscape"). Read-only: two sensor sessions and property reads, no restart, nothing written. NOTE an `orientationsensor` reading of STALE is expected: it is a **six-position on-change classifier** (`description: 'orientation of the device screen as 6 pre-defined positions'`, HIDL `SENSOR_TYPE_DEVICE_ORIENTATION = 25`), not an angle stream, so "no new sample while the phone sits still" is correct behaviour and the probe's age test can never say anything else about it (docs 79). Use `device/zl1-sensorfw-probe.sh --sensor rotationsensor --sensor compasssensor` for continuous angles. |
| `device/zl1-orientation-axes.sh` | Runs on the device, **read-only**. `--flat-up` / `--seconds N` / `--interval N` / `--explain` / `--quiet`. The verdict script for the port's oldest visible bug: the shell goes landscape because the orientation value is 6 while the phone lies flat, screen up. Doc 91 established offline *where that value comes from* -- not Android's orientation sensor but sensorfw's own `orientationinterpreter` (a six-position classifier) reading the **accelerometer**, which is why the two columns are a value and its own input rather than two sensors -- and that the only conversion between the adaptor's buffer and the classifier is `[accelerometer] transformation_matrix`, currently the **identity**. So this script samples the pair that decides it (the classifier's 5/6 against the sign of the accelerometer's z, restricted to |z| >= 800 mG so an off-flat phone cannot vote) and, given `--flat-up`, returns one of four verdicts: `INVERTED` (exit 3, and then the candidate fix is negating z), `AGREES` (exit 0 -- look at qtmir's mapping instead), `AMBIGUOUS` (exit 2 -- the accelerometer reports the gravity convention, which is not something to change a matrix over), or no flat sample (exit 1 -- run `zl1-sensors-recover.sh` first if the ages are growing). It prints the live `[accelerometer]` config lines it is reasoning about so the run carries its own evidence, and `--explain` prints the reversible procedure without doing it. It changes nothing: no config, no restart. Seven scenarios exercised against stubbed `gdbus` output, including four different struct-in-variant punctuation shapes; that run caught a real bug, where the `INVERTED` branch fired on a run whose z sign alternated, i.e. exactly the case that must *not* be reported as a clean inversion. |

## The debug keeper, and who owns the device address

`/usr/local/sbin/zl1-debug-net.sh` is the v63 image's debug network keeper, and it is the second heat
source on this port: its 1 Hz loop runs `systemctl mask --runtime usb-moded.service` every second,
which makes systemd daemon-reload every ~6 s, and it costs **a full core** (docs 72 section 4b — busy
0.87 cores with it SIGSTOPped, 1.84 with it running). Retiring it was blocked on one fear: it is also
what gives `rndis0` its two addresses at boot, and losing the address means losing SSH, which means a
finger on the power button. Docs 88 answers the underlying question — `restore_addrs()` in the
netwatch had exactly two call sites, both inside the heal stages, so a keeper-less boot would have had
no address for ~135 s and then been fixed by a full RNDIS re-enumeration. The netwatch now owns the
addresses too, and this script is the verdict on whether that actually happened.

| Script | Purpose |
| --- | --- |
| `device/zl1-quiet-debug-keeper.sh` | `--stop` / `--resume` / `--status` / `--wait N`. Runs on the device. It SIGSTOPs the keeper — deliberately with a signal, not by masking its unit, because the script daemonizes and `systemctl` does not manage that process at all (its unit believes it exited after 67 ms). After a reboot it is running again; re-run `--stop`. Nothing here is persistent by design. `--status` also prints the keeper's CPU over 20 s and the last `Reloading requested` line. |
| `device/zl1-boot-address-check.sh` | Runs on the device, read-only. Answers the one question that licenses retiring the v63 debug keeper: **who configured `rndis0`'s addresses on this boot, and when?** It splits `/userdata/zl1-netwatch.log` per boot (`netwatch start` is the boundary; every line carries its uptime), then reports the `ADDRS:` line and its uptime, any `STALL`/`HEAL` lines, the keeper's state (`T` or still looping), whether the netwatch unit is running, and -- because `sh -n` cannot see a deleted function -- whether the **installed** build under `/etc/systemd/system/` actually contains `ensure_addrs()`. Three verdicts, only the first of which gives permission: `netwatch-configured` (exit 0: the addresses came from the netwatch, before any heal), `heal-first` (exit 1: they arrived ~135 s late via a gadget re-enumeration -- do not retire the keeper), `inconclusive` (exit 1: the keeper did it, which is what stage 1 expects). Four synthetic logs exercised, including one with two boots in it, where reading the older boot's heal would invert the verdict. `--quiet` / `--log FILE`. |

## Does the camera app's window reach the screen? (one command, two measurements)


Docs 80 and 77 each proved half of this and never met: the UT camera app starts, but every run so far
had the **display off**; and the criterion for "on screen and alive" is the compositor's own CPU with
the display ON (docs 68 §5: ~1.2 ticks/s idle, 20–50/s while a client renders) — **a screenshot never
proves liveness**, because a dead client's last frame stays in the shell's scene (docs 77: pixel-
identical grabs, NCC 0.997). One number alone misleads either way, so this reports both, side by side.

| Script | Purpose |
| --- | --- |
| `host/zl1-camera-app-test.sh` | Runs from the host. Guards on the device-tree model, copies the launcher over, records `ActiveOutputs`, turns the display **on**, measures window A (display ON, no app — the baseline), launches the app in the container's PID namespace as uid 32011 with the session's environment, measures window B while it runs, takes a shell grab, stops the app and **restores the display to what it found** (`--keep-display` leaves it on for a human). The verdict has three branches, not two — composited, no extra work, and inconclusive — because a number between the baseline and the 20–50/s band is exactly what docs 80's failure modes produce, and the honest answer there is to read the app's stderr and the grab. It finds both the compositor and the app by walking `/proc` (never `pgrep -f`, which is unreliable here — docs 68 §5) and strips `comm` before reading utime/stime (docs 81's trap). `--seconds` / `--run-seconds` / `--no-shot` / `--keep-display` / `--extra-args` / `--outdir`. **Never executed on the device** — staged and syntax-checked only, and its verdict branches were checked with synthetic numbers. |

## Reading the fingerprint line (`SYS_EINVAL` is a missing directory)

Doc 64 §9 left "`setActiveGroup failed: SYS_EINVAL`, not fixed". Four files read in order make it one
line (doc 83): the HAL has two `SYS_EINVAL` returns and **only the first logs anything**
(`BiometricsFingerprint.cpp:215-228` — the path-length check logs, the `access(storePath, W_OK)` check
is silent, which is why the device log shows only the caller's message); the caller
(`halium/biometryd/src/biometry/devices/android.cpp:590-598`) *hardcodes* the path per API level
(`/data/system/users/0/fpdata/` at `<= 27`, `/data/vendor_de/0/fpdata/` above); and in real Android
that directory is created by **`system_server`** (`FingerprintService.java:1605-1620`, and it returns
without calling `setActiveGroup` at all if `mkdir` fails) — which this port does not have, so nobody
creates it.

| Script | Purpose |
| --- | --- |
| `device/zl1-fingerprint-probe.sh` | Runs on the device. Read-only unless `--create-store-dir`. Finds the HAL by its cmdline (`biometrics.fingerprint*service`, rather than guessing the 15-char `comm`), reports its uid/gid and `ns/pid`/`ns/mnt`, and answers the decisive question the way `access()` means it: **the store paths resolved through the HAL's own mount namespace** (`/proc/<pid>/root/data/...`) with the HAL's **own uid** from `/proc/<pid>/status` — ENOENT and EACCES are different diagnoses with the same symptom. Also: which of biometryd's two paths applies (properties read **inside** the container), the logcat counts for the branches in the C++ — including `Bad path length` and `Start biometrics`, i.e. **lines that should be there and are not** — the fingerprint HIDL registration, `/dev/goodix_fp`, and SELinux's `enforce`. `--create-store-dir` performs the single write, which is exactly what Android's own `FingerprintService` does, inside the container's namespace, with the `rmdir` undo printed; `/data` here is Android's own data partition (`/dev/sda10[/android-data]`), not one of the forbidden partitions and not a flash. |

## Reading the GPS line (four cheap questions before touching anything)

The recorded framing — "the QMI channel to the modem fails" — was a misreading of one log line, and it
was settled by reading the HAL source rather than the log (doc 82). In `LocApiV02.cpp` the message
`Failed to get features supported from QMI_LOC_GET_SUPPORTED_FEATURE_REQ_V02` is logged inside the
`else` branch of `locClientOpen()`, so it **can only appear when the QMI client opened**, it is not
fatal, and `open()` returns FAILURE in exactly one place: the branch that logs `locClientOpen failed`.
The action that has never happened is `gnssStart` / `u_hardware_gps_start`, and the most likely reason
is that nobody has ever asked for a position — the UT daemon's own client tool cannot ask, it only
reads and writes two switches.

| Script | Purpose |
| --- | --- |
| `device/zl1-gps-probe.sh` | Runs on the device. Read-only unless `--test-gps`. Prints: the unit's **real** `ExecStart` and which drop-in supplied it (`systemctl cat`, the only honest check that the android-aware wrapper is in effect), the daemon's pid and whether it is in the container's PID namespace (compared by `ns/pid`), the two switches through `lomiri-location-serviced-cli` (plus its usage verbatim, so a wrong subcommand shows up as such), the container logcat counts for the branches in the C++ — including the discriminating `locClientOpen failed` — the `custom.location.*` properties read **inside** the container, whether a GNSS HIDL service is registered at all (`lshal` under `nsenter -p -m`), and `/etc/gps.conf`. `--test-gps` additionally runs `/usr/bin/test_gps -c` with the TLS preload and the hybris library path: it starts one tracking session through the legacy `gps.h` HAL, which is **not** guaranteed to be the same implementation the HIDL path uses, so neither a pass nor a fail translates by itself. |

The lever worth knowing about before running any of it: the daemon's wrapper has a `custom.location.fake`
branch that runs the **whole UT location stack on a fake coordinate** (`dummy::Provider` +
`custom.location.lat/lon`), with no Android GPS involved. That is what separates "the UT side is fine"
from "the HAL is broken" — at the cost of one restart of a D-Bus-activated service.

## Measuring the heat (and it is a delta, not a temperature)

An absolute temperature on this phone says nothing — the battery is charging and the ambient changes.
Doc 72 answered "what is burning" with hand-run commands, and its conclusion came from the
**difference** between two windows (SIGSTOPping the debug keeper dropped tsens1/tsens8/pm8994 by
5.5/6.1/2.7 C), so the instrument below exists to make that shape reproducible: one window, then
`--ab` for the deltas either side of changing one thing. Two rules it encodes, both learned the hard
way in doc 72: `top`'s instantaneous percentages on this kernel cannot be added up, so every CPU
number is `/proc/<pid>/stat` fields 14+15 accumulated over a window (HZ=100, integer deltas); and
**`iowait` is kept apart from user/sys**, because "2.4 cores in the kernel" turned out to be iowait
accounting.

| Script | Purpose |
| --- | --- |
| `device/zl1-thermal.sh` | Runs on the device. `--seconds N` / `--top N` / `--ab` / `--hold N` / `--quiet`. One window: how many cores are busy and in what (user/sys/irq/softirq/**iowait**), context switches/s, loadavg, **D-state thread count**, the top N processes by tick delta, every thermal zone with the hottest named, every core's governor/cur/max, and memory (`MemTotal`/`MemAvailable`/`Swap` -- `MemAvailable` is the number doc 72 never read, and `top`'s `used` is not pressure). The container's memory is looked for where it actually lives (`/sys/fs/cgroup/memory/lxc/*/`); when this kernel has no memory hierarchy at all it says so rather than printing the hierarchy's ROOT -- which is the whole system, not the container, and is the mistake doc 72 section 8 made (docs 87: a container-side `free` reports this device's MemTotal, because `CONFIG_MEMCG` is off and the rootfs ships no lxcfs). `--ab` runs a second window after a plain `sleep` (never a keypress — it runs over ssh) and prints the per-process and per-thermal-zone **differences**, which is the whole point. Process names are read from `/proc/<pid>/comm`, not from `/proc/<pid>/stat`'s parenthesised field, which may contain a space and would shift the utime/stime fields onto the wrong process. Read-only: writes only to `/tmp`. Verified end to end on the host's kernel (x86, 88 cores) — the run that verified it also caught a format-string bug one `%s` short that printed a plausible-looking but completely wrong answer, now an assertion — but **not** on the zl1, whose thermal-zone/cpufreq/cgroup paths are the unverified part. See [`../docs/ubuntu-touch/81-the-heat-line-has-an-instrument-now.md`](../docs/ubuntu-touch/81-the-heat-line-has-an-instrument-now.md). |

## Measuring the audio path (the speaker)

The chain is `paplay -> pulseaudio sink.primary_output (module-droid-card, Active Port
output-speaker) -> android.hardware.audio@2.0-service in the container -> snd_device(2:
speaker-stereo) + mixer path "low-latency-playback smartpa" -> the MSM8996 `TERT_MI2S_RX` backend`,
i.e. the audio leaves the SoC over the **tertiary MI2S to an external smart amplifier**, not through
the internal WCD9335 speaker PA. Every link of that has been read back on 2026-09-22 and none of it
is broken (doc 74); what no measurement here can decide is whether the speaker is **audible** — that
needs the user's ear, and the test script is built to be run while they are holding the phone.

Two traps, both recorded because both produce a wrong answer rather than an error:

* **The host's `amixer` cannot read this card** (`amixer -c 0` -> "Mixer load sysdefault:0 error: No
  such device"), while `/system/bin/tinymix` runs straight from the host (Halium symlinks
  `/system -> /android/system`) and prints all 2392 controls. Reaching for `amixer` here concludes
  "no codec". And unlike the sensors HAL, reading the codec needs **no** `nsenter` — do not carry
  that rule over.
* **A 440 Hz test tone is not a fair audibility test** on a small phone speaker; the first attempt
  used one at amplitude 12000/32767 and silence there would prove nothing. Use ~2 kHz at high
  amplitude.

| Script | Purpose |
| --- | --- |
| `device/zl1-audio-test.sh` | Runs on the device. `--seconds N` / `--hz F` / `--amp A` / `--sink NAME` / `--status`. Plays a generated tone through the normal PulseAudio path and reads the codec **during** playback and again after it, so the two columns show whether the HAL actually configured the amplifier (playing: `MultiMedia5` On, `Speaker Volume 5`, `Digital Gain 56`, `Boost 9V`, channel enables On; idle: Off / 1 / 40 / 6.5V / Off). `--status` is read-only. See [`../docs/ubuntu-touch/74-the-speaker-path-is-complete-in-software.md`](../docs/ubuntu-touch/74-the-speaker-path-is-complete-in-software.md). |

## Finding out *where* the device crashed

| Script | Purpose |
| --- | --- |
| `hybris-crash-hunt.sh` | Runs a libhybris helper on the device (any `/usr/bin/test_*`, or a full command path such as `/usr/share/ubuntu-touch-session/lsc-wrapper`), captures the kernel's core dump, rebuilds a sysroot out of the core's own `NT_FILE` list, and prints the faulting address, the nearest symbol, the faulting instruction and the frame-pointer chain. `HYBRIS_TEST_PRELOAD` sets the run's `LD_PRELOAD`, `HYBRIS_TEST_ARGS` appends arguments. This is how the Phase 5 display failure was traced to `__ctype_get_mb_cur_max+8` inside Android `libc.so` — see [`../docs/ubuntu-touch/40-the-display-died-below-lomiri.md`](../docs/ubuntu-touch/40-the-display-died-below-lomiri.md). Needs `gdb-multiarch` on the host; needs nothing on the device (no compiler, no rootfs change — `core_pattern` is `/proc`, and cores land on `/userdata`). |
| `hybris-crash-hunt.sh --from-pid PID` | The same analysis for a process that **hangs** instead of crashing: `SIGABRT` it, which makes the kernel write the core, and everything after that is identical. `RLIMIT_CORE` belongs to the target process, so the script calls `prlimit --pid … --core=unlimited` first — without it no core is written and the newest `core.*` is the *previous* session's, which analyses perfectly and means nothing. It also verifies the core's name is `core.<comm>.<pid>`, and reads `/proc/PID/exe` before the kill because `comm` is truncated to 15 characters. This is how the Phase 5 hang was traced to `waitForHwServiceManager` — see [`../docs/ubuntu-touch/42-the-wait-that-could-never-finish.md`](../docs/ubuntu-touch/42-the-wait-that-could-never-finish.md). |

## Why the device was in EDL (a kernel panic goes there by default)

Doc 80 §7 recorded the 2026-09-23 trip into Qualcomm EDL and never attributed it. Reading the kernel
tree that built the flashed image turned up a path that needs nothing from anyone: **a kernel panic**.
`download_mode` is a compiled-in **1**, and `CONFIG_MSM_FORCE_WDOG_BITE_ON_PANIC=y` forces the reset
that follows it, so the SoC comes back up with the dload flag set and the bootloader enters EDL
instead of booting. `reboot edl` does the same thing deliberately; the PMIC undervoltage path
(`dload_on_uvlo`) is off. There is **no software exit**: EDL runs the SoC's boot ROM, so the kernel
that would run any "leave EDL" code is precisely what is not running — a long power press, or
nothing. Two witnesses survive the reset, and they are what this reads: **pstore/ramoops** (enabled,
and wired in the DT: 1 MiB at `0x91500000` with `android,ramoops-dump-oops`), and the kmsg archive
the drain script keeps (`keep/boot-<boot_id>/`, which after a UT → EDL → UT round trip holds the boot
that died). See [`../docs/ubuntu-touch/86-edl-has-a-cause-a-panic-and-the-evidence-survives.md`](../docs/ubuntu-touch/86-edl-has-a-cause-a-panic-and-the-evidence-survives.md).

| Script | Purpose |
| --- | --- |
| `device/zl1-edl-postmortem.sh` | Runs on the device, and it is the **first thing after the device comes back from EDL**. Read-only. It asks the device itself (`/proc/config.gz`, not the build tree) whether the panic → EDL path is armed and what `download_mode` is, then reads both witnesses — `/sys/fs/pstore/*` and the newest `keep/boot-*/` archive's last snapshot — against one set of death signatures (`Kernel panic`, `Unable to handle kernel`, `WDOG`, `Going down for restart`, …) and gives a three-branch verdict. An **empty pstore proves nothing** (ramoops has to survive the reset for the file to exist at all, and that has never been verified on this device), so "no witness" is reported as "no witness" with exit 1, never as "no panic". `--quiet` / `--full`; exit 0 = ran, 1 = a witness could not be read, 2 = not the zl1. Its branches were exercised against a synthetic tree; **that run caught two real bugs**, the worse being a backtick inside a double-quoted `say` that was command substitution, so the script **executed `reboot edl`** — harmless on the host, and on the phone it would have put the device straight into EDL. |

## Auditing the two Android images offline (no device, and it answers real questions)

The container's Android side is two images this port already has on the host: the **vendor partition**
(`vendor.img`) and the **Android system** the container mounts (`system.img`, and the identical
`android-system-zl1-halium-candidate.img` at `/data/system.img`). Almost everything about why a vendor
process fails to start is decided inside those two files, which means it can be answered while the
phone is in EDL, unplugged, or in a drawer. The trap is that "the library is there" is not a link
test — a `DT_NEEDED` is a **class-free soname**, so the question is always "*is there a library of
this ELF class, in a directory this class searches?*". That is what this script asks, for every
executable and every library at once, and then it separates what matters from what does not: an
*executable* with an unresolved dependency is a failure init will repeat forever, while a *library*
nothing references is just a file left behind. See
[`../docs/ubuntu-touch/90-the-one-process-that-cannot-link-and-it-is-32-bit.md`](../docs/ubuntu-touch/90-the-one-process-that-cannot-link-and-it-is-32-bit.md).

Two facts about the backups themselves, both found the hard way on 2026-09-23 and both worth knowing
before reaching for one:

* **Use `2026-06-07-adb-root-staged`, never `2026-06-07-adb-root-exact`.** The `-exact` copy passes
  its own `SHA256SUMS` (31/31 OK) and its filesystems are still unopenable (`mount(2): Structure
  needs cleaning`, and `debugfs` sees garbage in the inode table). A checksum proves the bytes were
  not corrupted in transit; it does not prove the bytes are a filesystem. The script refuses the
  `-exact` path with a warning, and its default is the staged one.
* `system.img` and the `-candidate.img` written to `/data/system.img` are the **same image** (same
  filesystem UUID), so auditing one audits the container's `/system`.

| Script | Purpose |
| --- | --- |
| `host/zl1-vendor-link-audit.sh` | Read-only, host-side, no device. Mounts the two images with `loop,ro,noload` (no journal replay, nothing written), then for every ELF under `bin/` and `lib*/` resolves each `DT_NEEDED` against the same-class sonames in `/vendor/lib{64}` + `/system/lib{64}`, and reports two lists. **Executables**: each broken one is cross-referenced against the init `.rc` that names it, so the report distinguishes "init will restart this forever" from "nothing starts it, it is a dead file" — the whole point, since the images carry both. **Libraries**: each broken one is cross-referenced against its referencers, printed with *their* ELF class, because a 64-bit referencer needs the 64-bit sibling and does not make the 32-bit file a fault. Exit 0 = no init-started executable is broken, 1 = at least one is. `--exec-only` / `--quiet` / `--vendor DIR --system DIR` for already-mounted trees / `--images DIR`. Its findings on the stock images: exactly one started process cannot link (`/vendor/bin/vsimd`, 32-bit, needs the 32-bit `libQSEEComAPI.so`, which exists nowhere — see doc 90), and two binaries nothing starts (`mdm_helper`, `mdm_helper_proxy`, missing `libmdmimgload.so`). Its **first version was flaky** — the same image reported different unrelated executables as broken from run to run, because membership was tested with `printf | grep -qx` under `set -o pipefail`, whose exit status is not a reliable boolean; the `case`-pattern version is stable across runs. A finding list that changes between identical runs would have invented port faults. |

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

## Starting a UT app from the host (and the EGL underneath it)

An app is not `test_camera`: it is a Qt process whose EGL goes through the glvnd dispatcher
(`libEGL.so.1.1.0` → `/usr/share/glvnd/egl_vendor.d/10_libhybris.json` first, `50_mesa.json` second),
whereas the shell and `test_camera` either bypass glvnd (Mir's own platform plugins dlopen
`libEGL_libhybris.so.0` directly) or are raw Wayland clients. There is **no wayland QPA plugin** on
this rootfs, so `ubuntumirclient` is the only platform plugin a Qt app here can use. Three things
have to be right at once — the container's PID namespace, **the running session's own environment**
(read from `/proc/<shell pid>/environ`; a hand-built environment reproduces the EGL assertion), and
running **as the session's uid** (`ZL1_AS_UID=32011`; the session bus rejects any other peer) — and
getting them wrong looks like a platform fault. See
[`../docs/ubuntu-touch/80-the-ut-camera-app-starts-and-our-preload-was-breaking-egl.md`](../docs/ubuntu-touch/80-the-ut-camera-app-starts-and-our-preload-was-breaking-egl.md).

| Script | Purpose |
| --- | --- |
| `device/zl1-camapp-launch.py` | Runs on the device. Launches one app with the session's environment: it reads `/proc/<shell pid>/environ` (NUL-separated, which the device's dash cannot do), drops the shell's `MIR_SERVER_*`/`QT_QPA_PLATFORM`, sets `MIR_SOCKET` + `QT_QPA_PLATFORM=ubuntumirclient`, `chdir`s into the app's package (the app finds its own QML from the current directory), then `setgid`/`setuid`s to `ZL1_AS_UID` as the **last** step (root has to read the environment and the runtime dir first). `ZL1_SET_<NAME>=<value>` overrides one session variable for an experiment, `ZL1_PRELOAD_EXTRA` appends to `LD_PRELOAD`, and arguments after the shell pid are passed to the target — which is how the EGL probe below runs. |
| `device/zl1-egl-probe.py` | Runs on the device (through the launcher). Reimplements qtmir's EGL initialisation in ctypes, with no Qt and no app in the picture: what `libEGL_libhybris.so.0` actually exports, who glvnd gives `EGL_DEFAULT_DISPLAY` to, what `mir_connect_sync` + `mir_connection_get_egl_native_display` return, and whether `eglInitialize` succeeds. This is the tool that separated "the platform is broken" from "this app is broken" — and then found the difference: the same binary and environment initialise hybris' EGL fine **without** `libcfi-shadow-init.so` preloaded and fail with it. |
| `cfi-shadow/cfi-shadow-init.c` | Fixed 2026-09-23. It resolved the real `android_dlopen` with `dlsym(RTLD_NEXT, "android_dlopen")` only. `RTLD_NEXT` searches the objects after this one in the **global** scope, and `libhybris-common.so.1` also arrives inside the **local** scope of a library glvnd dlopens (`libEGL_libhybris.so.0`), which `RTLD_NEXT` cannot see — so the shim answered **NULL to every hybris dlopen in the process** and cached that failure permanently. `test_camera` never saw it (it has `libcamera.so.1` as a `DT_NEEDED`, so the global scope was populated before the first call); every Qt app did, as hybris' EGL stopping half-way and glvnd falling through to Mesa, which needs `/dev/dri` and cannot work here. `resolve_real()` now falls back to `dlopen("libhybris-common.so.1", RTLD_NOW\|RTLD_GLOBAL)`, logs which route was needed, and `prime()` returning 0 leaves the state un-primed so the next call retries. Build with `cfi-shadow/build.sh`; the previous binary is kept on the device as `libcfi-shadow-init.so.orig-20260923`. |

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
| `hybris-shims/install-container-ns-services.sh` | `--install [unit…]` / `--remove` / `--status`. Runs `lomiri-location-service`, `biometryd`, `sensorfwd` and `bluebinder` inside the container's PID namespace, because Android binder — both `/dev/binder` and `/dev/hwbinder` — only completes a transaction between two processes in the same one. Doc 43 found that for binder; doc 55 measured it for hwbinder (`lshal` from the host: 0 registered services; from the container: 134), doc 60 measured it a third time for `sensorfwd` — same binary, same 25 s, `Could not find remote object for sensor service. Trying to reconnect` in the host namespace vs `Connected to sensor 1.0 service` plus the device's whole sensor inventory in the container's — and doc 62 a fourth time for `bluebinder` (`Failed to connect to bluetooth binder service` vs `Successfully initialized vhci bluetooth` and an `hci0`). **The rule is not "move anything that talks to Android": it is "move anything whose path goes through binder"** — `pulseaudio` runs in the host namespace and is fine, because the droid audio HAL is loaded in-process via libhybris; `grep -a libgbinder <binary>` tells you which is which. Doc 62 measured it a fourth time for `bluebinder` (`Failed to connect to bluetooth binder service` in the host namespace vs `Successfully initialized vhci bluetooth` and an `hci0` in the container's). **The rule is not "move anything that talks to Android": it is "move anything whose path goes through binder"** — `pulseaudio` runs in the host namespace and is fine, because the droid audio HAL is loaded in-process via libhybris and never touches binder; `grep -a libgbinder <binary>` tells you which is which. The compositor has been living with it since doc 43 via `lsc-wrapper`; these are plain system units, so nothing did it for them. Installs one shared wrapper plus an `ExecStart=` override per unit — the `zz-` prefix on that drop-in is load-bearing, since `lomiri-location-service` already has an `ExecStart=` reset in `lxc-android-config.conf` and systemd applies drop-ins in one lexicographic order across all directories. `-p` only, never `-F` (`setns` affects future children only, so `-F` leaves the process behind and every `pthread_create` fails with EINVAL — fatal for all three, which are threaded); no `nsenter` sweep, because cgroups are orthogonal to PID namespaces and systemd's `KillMode=control-group` already kills the child that moved; and a hard failure rather than a fallback if the container is down, because a service in the wrong namespace claims its D-Bus name and reports `active` while doing nothing. **Two things `sensorfwd` needs that the other two do not, both found the hard way (doc 60):** the wrapper itself requires `CAP_SYS_ADMIN` (`setns()` requires it for every namespace type — `!ns_capable(current_user_ns(), CAP_SYS_ADMIN)` → `-EPERM`) *and* `CAP_SYS_PTRACE` (its own `[ -e /proc/<container-init>/ns/pid ]` test; `/proc/<pid>/ns/*` is readable only for a process you may ptrace), neither alone enough, so `unit_extra` widens that unit's bounding set and the wrapper re-narrows after `setns` with `setpriv --bounding-set=-sys_admin,-sys_ptrace,-setpcap` (needs `CAP_SETPCAP` in the widened set; verified to land on `CapBnd: 000000100000000a`, exactly the unit's original three caps). That step is opt-in via `ZL1_NS_DROP_CAPS=1` so it cannot affect the two services that already work. And `Type=notify` needs `NotifyAccess=all`, because `nsenter -p` **forks**: READY=1 arrives from a PID systemd will not accept from the main one (`Got notification message from PID …, but reception only permitted for main PID …`). `--status` reports five things, including which namespace the real process is in (looked up by `comm`, not via MainPID — ExecStart is `nsenter` and the process that moved is its child) and whether the success strings have appeared in the container's logcat; its `sensorfwd` block deliberately greps for `Hybris sensor manager initialized` rather than `Connected to sensor 1.0 service`, because the latter is only printed at `--log-level=debug` while the unit runs at `warning` and counting it reports 0 on a healthy service. It also sets `StartLimitIntervalSec=0` and `RestartSec=5` per unit, because all three exit *cleanly* while waiting for something that arrives late in the boot (the user session's trust-store agent; the fingerprint HAL's readiness; the sensors HAL) and systemd's default limit of 5 starts per 10 s turns "late" into "never" — read the doc before changing those. It also installs `zl1-bt-wait`, which exists because bluebinder ships `ExecStartPre=/usr/bin/droid/bluebinder_wait.sh` and that script can never exit on this port: it polls `getprop | grep 'init.svc.*bluetooth'`, `/usr/bin/getprop` on the host is a 1352-byte stub that prints nothing for a bare `getprop`, and the real `getprop.orig-zl1` returns 0 lines from the host too — the property area is per-container, like binder — so `TimeoutStartSec` killed it every 60 s. `zl1-bt-wait` asks inside the container instead. The bluebinder drop-in also raises `TimeoutStartSec` to 240 (the BT HAL is up at t≈45.7 s per `ro.boottime.vendor.bluetooth-1-0-qti: [45723205437]`), sets `NotifyAccess=all`, and sets `StartLimitIntervalSec=0` in `[Unit]` because the shipped unit writes it in `[Service]` where systemd ignores it and `StartLimitBurst`. See [`../docs/ubuntu-touch/56-*`](../docs/ubuntu-touch/56-the-two-services-move-into-the-containers-pid-namespace.md), [`../docs/ubuntu-touch/57-*`](../docs/ubuntu-touch/57-boot-verification-the-two-services-come-up-by-themselves.md) and [`../docs/ubuntu-touch/60-*`](../docs/ubuntu-touch/60-sensorfwd-was-the-third-service-behind-the-same-wall.md) and [`../docs/ubuntu-touch/62-*`](../docs/ubuntu-touch/62-bluetooth-two-things-that-read-from-the-wrong-place.md). |
| `hybris-shims/make-lsc-wrapper.sh` | Regenerates `lsc-wrapper.zl1` from the device's original as two hunks, so the delta stays reviewable and a rootfs that moved on shows up as a hash mismatch rather than a silently patched file. `--check` verifies the tracked copy is current. |
| `hybris-shims/install-hybris-shims.sh` | `--mount` / `--unmount` / `--status`. Stages the libraries in `/userdata/zl1-hybris/lib/`, bind-mounts `lsc-wrapper.zl1` over `/usr/share/ubuntu-touch-session/lsc-wrapper`, ensures the TLS-slot mount, and restarts lightdm. The mounted wrapper is what sets `HYBRIS_LD_LIBRARY_PATH` (how the Android linker is told to search `/userdata/zl1-hybris/lib` **before** `/system/lib64`) and what puts the compositor in the container's PID namespace. |
| `hybris-shims/lsc-wrapper.orig`, `lsc-wrapper.zl1` | The device's wrapper and the patched copy, both tracked, so the delta is reviewable. `--mount` refuses to run if the device's file is neither of them (rootfs moved on) unless `FORCE=1`. |
| `hybris-shims/free-container-display.sh` | `--apply` / `--status` / `--explain`. Undoes two things the **v63 boot image does to itself**: the three same-length string substitutions its LXC mount hook bind-mounts over `hwservicemanager`, `qseecomd` and both `libc.so` (which is why no HAL in the container ever registered), and the container's SurfaceFlinger holding the QCOM composer's single client slot (which is why the host compositor could not create a client). Runtime-only, and dies with the container — the hook runs on every `lxc-start`. See [`../docs/ubuntu-touch/44-the-v63-image-sabotages-its-own-container.md`](../docs/ubuntu-touch/44-the-v63-image-sabotages-its-own-container.md). |

| `hybris-shims/install-container-desabotage.sh` | `--install` / `--remove` / `--status`. Makes `free-container-display.sh` **persistent**: installs a supervisor at `/userdata/zl1-container-fix/apply.sh` plus a `multi-user.target` unit, so the four over-mounts are lifted and the container's SurfaceFlinger stopped again every time the container restarts. Persistent *without touching the boot image* because `/etc/systemd/system` is one of the rootfs's writable-paths, bind-mounted from `/userdata/system-data/etc/systemd`. The device script is written by this one, so there is one copy of the logic and it lives here. Every line of `/userdata/zl1-container-fix.log` now carries an 8-character `boot_id` and each boot opens with a `=== boot <id>: container-fix starting` marker: the file is appended to with rotation and so spans many boots, and with only `uptime` on each line there was no way to tell which lines belonged to the boot under investigation — which is what [`../docs/ubuntu-touch/58-*`](../docs/ubuntu-touch/58-one-cold-boot-where-the-secure-world-refused-and-three-firmwares-did-not-load.md) §4 needs to answer. That tagging is also what named the race: `apply()` starts at t≈41–42 s and finishes at t≈54–62 s, so the container's PIL firmware loads at t≈47.8–48.2 s land inside it, half a second after `ctl.restart qseecomd`. See [`../docs/ubuntu-touch/59-the-boot-log-was-deleted-by-its-own-collector.md`](../docs/ubuntu-touch/59-the-boot-log-was-deleted-by-its-own-collector.md). |

| `hybris-shims/install-wlan-bringup.sh` | `--install` / `--remove` / `--status` / `--trigger`. Loads the QCA6174 by writing `sta` to `/sys/module/wlan/parameters/fwpath`, which is the driver's only entry point when qcacld is built into the kernel: `hdd_module_init()` is literally `return 0;` with the comment "Driver initialization is delayed to fwpath_changed_handler", and nothing on this device wrote it — `init.qcom.rc` only chowns the attribute, expecting a userspace writer (normally the wifi HAL, which needs the Android framework). Writing it produced `wlan0`, `FW:4.1.2.57`, `HW:QCA6174_REV3_2` and took `cnss-prealloc` from 0 to 600 Kb used. The value is a trigger, not a path: `hdd_get_fwpath()` has one caller that only compares the first two characters to `"ap"`, and the real firmware directory is the kernel's `firmware_class/parameters/path`. The parameter buffer is 20 bytes (`BUF_LEN`), which is why a 21-character path returns ENOSPC. The device script waits for `/vendor/firmware_mnt/image/qwlan30.bin` to be readable before triggering, because the chip firmware goes through the kernel loader and a cold-boot trigger that fires too early looks like a firmware failure. See [`../docs/ubuntu-touch/54-wifi-the-driver-was-waiting-for-an-fwpath-write-nobody-did.md`](../docs/ubuntu-touch/54-wifi-the-driver-was-waiting-for-an-fwpath-write-nobody-did.md). |
| `hybris-shims/check-android-bridge-libs.sh` | `[--dev] [ELF…]`. Answers "why did this service jump to address 0". Some host libraries do not link their Android side — they reach it at runtime through `android_dlopen("libxxx.so")` + `android_dlsym("u_xxx")`, and the bridge NULL-checks the *cached* pointer but not the one it just resolved, so a missing symbol is `br x16` with `x16=0` rather than an error path. The core reads `pc 0x0`, `si_addr=0`, `lr` just past a `bl …@plt`. The static half needs no device: the library name and the required `u_` symbols are plain strings in the host library's rodata (default list: `liblomiri-location-service`, `libbiometry`, `libubuntu_platform_hardware_api`, `libhwc2`). `--dev` checks those names under the `android_dlopen` search paths and byte-scans each for the required symbols — a MISSING verdict is trustworthy, a present one can be a false positive. This is the same class `build-hwc2-compat-layer.sh` warns about ("it does not NULL-check those, so a missing one is a jump to address 0"); it now also explains `lomiri-location-serviced` on the real `gps::Provider` and `biometryd`. See [`../docs/ubuntu-touch/50-the-pc-zero-is-a-bridge-symbol-that-resolved-to-null.md`](../docs/ubuntu-touch/50-the-pc-zero-is-a-bridge-symbol-that-resolved-to-null.md). |
| `hybris-shims/free-gpu-devices.sh` | `--apply` / `--restore` / `--status` / `--explain`. Opens the GPU to the session user: `/dev/ion` and `/dev/kgsl-3d0` are created `crw------- root:root` by devtmpfs, and the Lomiri session runs as `phablet`, so `eglInitialize()` fails with `EGL_NOT_INITIALIZED` and Mir reports the misleading `could not select EGL config`. `--status` prints the mode bits **and** what the session user actually gets (`test_egl_configs` run through `su phablet` with the doc-45 environment), because mode bits alone do not answer it. Runtime-only — devtmpfs, back to 0600 after a reboot. See [`../docs/ubuntu-touch/46-the-gui-runs-dev-ion-was-root-only.md`](../docs/ubuntu-touch/46-the-gui-runs-dev-ion-was-root-only.md). |

| `hybris-shims/install-system-tls-preload.sh` | `--install` / `--remove` / `--status`. Gives every **system** service that loads an Android library the TLS shim, as a drop-in on the `/etc/systemd/system` writable-path. Only the compositor and the session had it (docs 41/45), and seven services were sitting in `failed (Result: signal)` — all SIGSEGV, all the same bionic TLS slot. Two rules: scan enabled units whose `ExecStart` binary mentions `libhybris` (over-approximates — snapd gets one it does not need; harmless), plus a curated list for the five whose Android side is a runtime plugin and so has no such string in the binary (`sensorfwd`, `urfkill`, `hfd-service`, `lomiri-location-service`, `biometryd`). Also has to `reset-failed` before starting, because a unit that exhausted `Restart=` is not restarted by `start`. **The scan follows the library graph too, since `update-machine-info-from-deviceinfo`:** a binary can reach libhybris *through another host library* (that one goes `libdeviceinfo.so.0 → libandroid-properties.so.1 → libhybris-common.so.1`), so `uses_hybris()` greps the file, and on a miss takes every `lib*.so*` string in it, resolves each through `ldconfig -p`, and recurses — depth-limited to 4, a string scan because `readelf`/`objdump`/`strings` are all absent on the device. **Two path bugs made the writing half lie for a whole day, both worth knowing because they both look like success:** the name had `.service` stripped for the guard and appended again for the path (every scanned unit became `foo.service.service` and was skipped), and the drop-in directory was built from the bare name — **systemd only reads `<full-unit-name>.d`, so `foo.d` is never loaded at all**. Both are now fixed by normalising the name once in `add()`, and the discriminators are in the doc: `systemctl cat <unit>` is what tells you a drop-in is in effect, and a file existing does not. `--install`/`--remove` sweep the stale `foo.d` directories a buggy version left behind; `--status` reports them separately as STRAY rather than counting them. See [`../docs/ubuntu-touch/48-the-tls-fault-was-killing-seven-system-services.md`](../docs/ubuntu-touch/48-the-tls-fault-was-killing-seven-system-services.md) and [`../docs/ubuntu-touch/63-*`](../docs/ubuntu-touch/63-the-last-failed-unit-two-bugs-in-the-installer-that-faked-it.md). |
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
