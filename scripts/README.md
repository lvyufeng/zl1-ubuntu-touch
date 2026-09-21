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
| `hybris-crash-hunt.sh` | Runs a `/usr/bin/test_*` libhybris helper on the device, captures the kernel's core dump, rebuilds a sysroot out of the core's own `NT_FILE` list, and prints the faulting address, the nearest symbol, the faulting instruction and the frame-pointer chain. This is how the Phase 5 display failure was traced to `__ctype_get_mb_cur_max+8` inside Android `libc.so` — see [`../docs/ubuntu-touch/40-the-display-died-below-lomiri.md`](../docs/ubuntu-touch/40-the-display-died-below-lomiri.md). Needs `gdb-multiarch` on the host; needs nothing on the device (no compiler, no rootfs change — `core_pattern` is `/proc`, and cores land on `/userdata`). |

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
