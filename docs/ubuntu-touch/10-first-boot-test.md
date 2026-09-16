# First boot test plan

This is not part of the first build pass. It is only allowed after backups and explicit approval.

## Preferred order

1. Confirm `boot` backup and checksum.
2. Confirm fastboot access.
3. Try temporary boot first if supported:

```bash
fastboot boot halium-boot.img
```

4. Watch host logs:

```bash
dmesg -w
```

5. If temporary boot is unsupported, stop and reassess before flashing.

## Flashing boot

Only after explicit approval:

```bash
fastboot flash boot halium-boot.img
```

Do not flash `system` or `vendor` until the Ubuntu Touch rootfs/GSI method is known and backups are complete.

## Success indicators

- kernel starts
- USB networking appears
- early telnet or SSH appears
- Ubuntu Touch / Halium init progresses
- display or Lomiri starts eventually

## 2026-06-07 diagnostic status

Three temporary `fastboot boot` attempts have been made; nothing has been flashed.

1. Initial rebuilt image failed at the bootloader with `remote: 'dtb not found'`.
2. ZL1-product image with unfiltered/mixed DTBs was accepted far enough to drop the phone into visible Qualcomm 9008/QDL; it recovered after a physical reboot.
3. Filtered five-DTB ZL1 image was accepted by fastboot (`Booting OKAY`) but the phone did not enumerate as ADB, fastboot, QDL, USB networking, or ping target during polling.

Detailed record: `docs/ubuntu-touch/15-boot-diagnostics-2026-06-07.md`.

Do not repeat blind normal boots yet. After the phone is recovered to Android/fastboot, the next test should be a diagnostic image with `debug break=premount`, still via `fastboot boot` only.
