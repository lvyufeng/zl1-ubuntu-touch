# Restore plan

Document and verify restore paths before testing.

## Boot restore

If a test boot image was flashed and Android no longer boots:

```bash
fastboot flash boot backup-boot.img
fastboot reboot
```

## Recovery restore

```bash
fastboot flash recovery backup-recovery.img
```

## System/vendor restore

Only if those partitions were modified and backups exist:

```bash
fastboot flash system backup-system.img
fastboot flash vendor backup-vendor.img
```

## Calibration partitions

Do not restore or modify `persist`, `modemst1`, `modemst2`, `fsg`, or `fsc` unless specifically recovering from damage and the backup is known-good. These partitions are device-specific.

## Required before testing

- known-good `boot` backup
- known-good `recovery` backup
- current Android ROM or TWRP backup available
- fastboot access confirmed
