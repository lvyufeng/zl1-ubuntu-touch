# Backup procedure

This procedure reads partitions and stores images on the host. It must not write to block devices.

## 1. Inventory

```bash
scripts/device-readonly-inventory.sh
```

Confirm the target serial is the LeEco Pro3 / `le_zl1`.

## 2. Prepare host backup directory

```bash
mkdir -p /mnt/data/zl1-backups/YYYY-MM-DD
```

## 3. Confirm root-capable read path

Recovery/TWRP is preferred for backing up partitions that are mounted or active during Android runtime.

Current Android-mode observation on 2026-06-07:

```text
adb root -> adbd cannot run as root in production builds
/sbin/su -> ./magisk
su -c id -> Permission denied
```

So Android-mode partition backup requires granting Magisk root to ADB shell on the phone first. If Magisk root is not granted, use recovery/TWRP ADB instead.

## 4. Run backup script

ADB Android mode after Magisk root is granted: use the staged pull script.

```bash
scripts/backup-partitions-adb-staged.sh /mnt/data/zl1-backups/YYYY-MM-DD 33e80afe
```

On this device, direct `adb exec-out su -c dd` streaming through Magisk was observed to corrupt large stdout streams. The direct streaming script is therefore not trusted for Android/Magisk mode unless each image is independently verified against live block samples.

TWRP/recovery mode, if booted into a recovery environment without Magisk stdout stream corruption:

```bash
scripts/backup-partitions-twrp.sh /mnt/data/zl1-backups/YYYY-MM-DD 33e80afe
```

Estimated size for the current allowlisted backup set is about 5.01 GiB. `/mnt/data` had about 391 GiB free during the latest check.

## 5. Verify

Confirm every produced `.img` has:

- nonzero size
- expected size compared to `/proc/partitions`
- SHA256 checksum recorded in `SHA256SUMS`

## 6. Do not proceed without boot backup

Before any `fastboot boot` or `fastboot flash boot`, confirm:

```text
backup-boot.img exists and has a recorded SHA256
```
