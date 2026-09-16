# Ubuntu Touch / Halium safety rules

This track rebuilds Ubuntu Touch / Halium 9 support for LeEco Pro3 `zl1`. Treat every device write as potentially destructive.

## Hard rules

1. No flashing before critical partitions are backed up and checksummed.
2. No writes to modem/EFS/calibration partitions.
3. No `fastboot flash system`, `fastboot flash vendor`, TWRP ROM install, or rootfs install until backups and restore steps are documented.
4. Prefer read-only inventory first.
5. Prefer temporary boot with `fastboot boot` before flashing `boot`, if the bootloader supports it.
6. Confirm the target device before every device operation; another ADB device may be connected.
7. Keep large source trees and backups outside this notes repository.

## Current risk profile

The current goal is to rebuild a missing boot artifact. Building source and creating scripts is safe. Flashing the resulting boot image is not part of the first pass.

Highest-risk partitions:

- `modemst1`, `modemst2`, `fsg`, `fsc`
- `persist`
- `modem`, `dsp`, `bluetooth`
- boot-chain partitions such as `abl`, `tz`, `rpm`, `hyp`, `devcfg`, `keymaster`, `cmnlib`, `cmnlib64` if present

These should be backed up and then left untouched.

## Safe phases

- Documentation: safe.
- Read-only inventory: safe.
- Source sync/build in external tree: safe for the phone.
- Partition backup by reading block devices: low risk but must be done carefully.
- Temporary boot: medium risk.
- Flashing boot: medium risk if boot backup is valid.
- Flashing system/vendor: high risk and requires explicit review.
