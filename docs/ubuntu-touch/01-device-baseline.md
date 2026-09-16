# Device baseline

Observed target device facts refreshed with `scripts/device-readonly-inventory.sh`:

| Field | Value |
|---|---|
| ADB serial | `33e80afe` |
| Model | LeEco Pro3 |
| Android device | `le_zl1` |
| Product name | `ZL1_CN` |
| SoC/platform | Qualcomm MSM8996 / Snapdragon 821 family |
| Hardware | `qcom` |
| Android version | 9 |
| SDK | 28 |
| Security patch | 2019-10-01 |
| Treble | `true` |
| VNDK | 28 |
| Slot suffix | empty / A-only observed |
| Boot state | `orange` |
| Boot device | `624000.ufshc` |
| Battery at latest inventory | 100%, USB powered |

The device is connected alongside another ADB device in this lab, so scripts must require or auto-select the `le_zl1` serial rather than assuming `adb` has only one target.

## Current storage/mount observations

- Boot block device path family: `/dev/block/bootdevice/by-name/*`
- `/system`: `/dev/block/platform/soc/624000.ufshc/by-name/system`, ext4, read-only
- `/vendor`: `/dev/block/platform/soc/624000.ufshc/by-name/vendor`, ext4, read-only
- `/data`: `/dev/block/bootdevice/by-name/userdata`, ext4
- `/system/vendor` is a symlink to `/vendor`
- VINTF manifests exist under `/system/etc/vintf/manifest.xml` and `/vendor/etc/vintf/manifest.xml`
- No `dtbo` or `vbmeta` partition was visible in the latest by-name listing.

## Important visible partitions

| Partition | Block node | Approx size from `/proc/partitions` |
|---|---|---:|
| `xbl` | `sdb1` | 4052 KiB |
| `xblbak` | `sdc1` | 4052 KiB |
| `rpm` | `sde1` | 512 KiB |
| `tz` | `sde3` | 2048 KiB |
| `hyp` | `sde5` | 512 KiB |
| `fsg` | `sde7` | 2048 KiB |
| `modem` | `sde12` | 112640 KiB |
| `dsp` | `sde13` | 16384 KiB |
| `aboot` | `sde16` | 1024 KiB |
| `boot` | `sde18` | 65536 KiB |
| `system` | `sde19` | 4194304 KiB |
| `recovery` | `sde20` | 65536 KiB |
| `bluetooth` | `sde22` | 1024 KiB |
| `keymaster` | `sde23` | 512 KiB |
| `cmnlib` | `sde25` | 256 KiB |
| `cmnlib64` | `sde27` | 256 KiB |
| `splash` | `sde32` | 102400 KiB |
| `vendor` | `sde34` | 634300 KiB |
| `persist` | `sda2` | 32768 KiB |
| `cache` | `sda3` | 262144 KiB |
| `userdata` | `sda10` | 25532108 KiB |
| `modemst1` | `sdf1` | 2048 KiB |
| `modemst2` | `sdf3` | 2048 KiB |
| `fsc` | `sdf5` | 4 KiB |

## Commands used for future refresh

Use the read-only inventory script:

```bash
scripts/device-readonly-inventory.sh
```

Important properties to confirm before any operation:

```bash
adb shell getprop ro.product.device
adb shell getprop ro.product.model
adb shell getprop ro.build.version.release
adb shell getprop ro.build.version.sdk
adb shell getprop ro.treble.enabled
adb shell getprop ro.vndk.version
adb shell getprop ro.boot.verifiedbootstate
adb shell getprop ro.boot.slot_suffix
adb shell ls -l /dev/block/bootdevice/by-name
```
