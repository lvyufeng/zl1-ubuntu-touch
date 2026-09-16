# Partition backup plan

Backups are mandatory before any boot or flash test.

## Backup location

Use a host-side directory outside this repo, for example:

```text
/mnt/data/zl1-backups/<date-or-build-id>/
```

Do not store large partition images in this git repository.

## Minimum backup set

Back up these partitions if they exist on the device:

- `boot`
- `recovery`
- `system`
- `vendor`
- `persist`
- `modem`
- `dsp`
- `bluetooth`
- `fsg`
- `fsc`
- `modemst1`
- `modemst2`
- `xbl`
- `xblbak`
- `aboot`
- `abootbak`
- `tz`
- `tzbak`
- `rpm`
- `rpmbak`
- `hyp`
- `hypbak`
- `devcfg`
- `devcfgbak`
- `keymaster`
- `keymasterbak`
- `cmnlib`
- `cmnlibbak`
- `cmnlib64`
- `cmnlib64bak`
- `splash`

The latest inventory did not show `dtbo` or `vbmeta`, but the backup scripts skip missing partitions automatically.

## Current partition map highlights

From the latest read-only inventory:

- `boot` -> `/dev/block/sde18`, 65536 KiB
- `recovery` -> `/dev/block/sde20`, 65536 KiB
- `system` -> `/dev/block/sde19`, 4194304 KiB
- `vendor` -> `/dev/block/sde34`, 634300 KiB
- `persist` -> `/dev/block/sda2`, 32768 KiB
- `modem` -> `/dev/block/sde12`, 112640 KiB
- `dsp` -> `/dev/block/sde13`, 16384 KiB
- `bluetooth` -> `/dev/block/sde22`, 1024 KiB
- `modemst1` -> `/dev/block/sdf1`, 2048 KiB
- `modemst2` -> `/dev/block/sdf3`, 2048 KiB

## Verification

For every backup:

- record source partition path
- record image size
- compute SHA256
- keep restore command documented

Example checksum command on host:

```bash
sha256sum boot.img
```

## Restore readiness

Before testing any new boot image, confirm that `boot.img` backup exists, has the expected size, and has a recorded checksum.
