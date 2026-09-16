# Debugging Ubuntu Touch / Halium boot

## Host-side monitoring

```bash
dmesg -w
adb devices
fastboot devices
```

## SSH target

If Ubuntu Touch USB networking appears:

```bash
ssh phablet@10.15.19.82
```

## Early Halium telnet

If the initrd exposes early telnet:

```bash
telnet 192.168.2.15
cat diagnosis.log
```

## Logs to collect

Depending on what boots:

```bash
dmesg
journalctl
systemctl status
lxc-info -n android
lxc-ls --fancy
```

Potential persistent kernel logs:

```text
/proc/last_kmsg
/sys/fs/pstore/
```

## Current zl1 failure area after filtered-DTB image

The filtered ZL1 image is accepted by the bootloader, but the phone does not expose ADB, fastboot, QDL, USB networking, telnet, SSH, or ping during host polling. This points to a failure after bootloader handoff, before any useful host-visible Halium endpoint.

Next safer diagnostics should prefer:

1. A filtered Halium image with `debug break=premount` to force the initramfs panic/telnet path before userdata mount/fsck.
2. A stock-kernel + Halium-initramfs hybrid image with `debug break=premount` to separate Halium kernel problems from initramfs/USB-gadget problems.

Candidate-building script:

```bash
scripts/make-halium-diagnostic-boot-images.sh \
  /mnt/data/zl1-backups/2026-06-07-adb-root-staged/boot.img \
  /mnt/data/halium-zl1-candidates/halium-boot-zl1-filtered-dtb.img \
  /mnt/data/halium-zl1-candidates
```

Test only with `fastboot boot`; do not flash.

## Ubuntu Touch 24.04 / Noble Android LXC startup

The 24.04 `android9plus` rootfs uses systemd, not upstart, for Android LXC startup. The primary service is:

```text
/lib/systemd/system/lxc-android-config.service
ExecStart=/usr/libexec/lxc-android-config/start-android-container
```

For Android 9 it starts `lxc-start -n android -F` with `INIT_SECOND_STAGE=true /init` inside the container.

Use the official pre-start snippet directory for zl1-specific debug/init patching:

```text
/var/lib/lxc/android/pre-start.d/90-zl1-debug-init-patch
```

Do not replace Noble's official `/var/lib/lxc/android/pre-start.sh` or `/var/lib/lxc/android/config` unless a later failure proves it is necessary. See [`16-noble-systemd-lxc.md`](16-noble-systemd-lxc.md).

Current Noble-aware debug boot artifact:

```text
/mnt/data/halium-zl1-candidates/halium-boot-zl1-filtered-dtb-postswitch-debug-v15-noble-prestartd.img
SHA256: daef301af398f6751a9f4a930ce26854db161342b7f004150ce3874497cb80af
```

Temporary test command only:

```bash
fastboot boot /mnt/data/halium-zl1-candidates/halium-boot-zl1-filtered-dtb-postswitch-debug-v15-noble-prestartd.img
```

## Common failure areas

- wrong boot image offsets/page size
- DTB mismatch
- missing AppArmor or LXC kernel config
- rootfs/system image not found
- wrong `systempart=` or partition path
- vendor/system mismatch
- Android container cannot start
- systemd unit ordering or failed `lxc-android-config.service` prerequisites on 24.04
- graphics HAL / hwcomposer mismatch
- USB gadget/RNDIS failure
