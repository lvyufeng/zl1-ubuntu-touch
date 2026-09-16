# Backup record: 2026-06-07 staged rooted ADB backup

Trusted backup completed using Magisk-authorized ADB root with staged pulls.

```text
Device serial: 33e80afe
Device: LeEco Pro3 / le_zl1
Backup directory: /mnt/data/zl1-backups/2026-06-07-adb-root-staged
Method: dd each allowlisted partition to /data/local/tmp/zl1-partition-backup, adb pull the temporary regular file, then delete it
Image count: 31
Total bytes: 5375631360
Total size: 5.01 GiB
Result: success=31 fail=0 skip=0
```

This staged backup is the current trusted baseline before any Ubuntu Touch / Halium boot test.

## Why staged backup was required

The first direct streaming backup directories must not be trusted:

- `/mnt/data/zl1-backups/2026-06-07-adb-root`
  - Direct `adb exec-out su -c dd` stream.
  - Produced oversized boot/recovery images.
- `/mnt/data/zl1-backups/2026-06-07-adb-root-exact`
  - Direct stream truncated on the host to exact partition sizes.
  - Image sizes matched, but `system.img` later failed ext4 parsing/fsck checks and sample block comparison showed stream corruption in the middle of the file.

Do not use either direct-stream directory as a restore source unless there is no alternative and the specific image is independently verified.

## Verification performed

Host-side checks on the staged backup:

```text
.img files: 31
.partial files: 0
SHA256SUMS lines: 31
partition-sizes.txt lines: 31
All image sizes matched blockdev-reported sizes.
All expected images had SHA256 entries.
Remote temporary directory: removed
```

Filesystem/image checks:

```text
boot.img:     Android boot image, 64 MiB
recovery.img: Android boot image, 64 MiB
system.img:   ext4 label=system, size 4,294,967,296 bytes
vendor.img:   ext4 label=vendor, size 649,523,200 bytes
persist.img:  ext4, size 33,554,432 bytes, needs journal recovery because it was live-mounted
```

`e2fsck -n` on `system.img` and `vendor.img` only reported inode bitmap padding warnings, not the severe group descriptor corruption seen in the invalid direct-stream backup. `persist.img` reported expected journal recovery warning because it was copied from a live mounted ext4 filesystem.

Additional validation:

- `debugfs` could list `/` and read `/build.prop` from staged `system.img`.
- `debugfs` could list `/` and read `/build.prop` and `/etc/fstab.qcom` from staged `vendor.img`.
- Deterministic 4096-byte sample blocks from live `/dev/block/bootdevice/by-name/system` matched the host staged `system.img` at these block numbers: `0`, `1`, `2`, `16`, `1024`, `8192`, `65536`, `262143`, `524288`, `900000`, `1048575`.

## Android system image notes

The staged Android `system.img` appears to be a valid backup of the currently installed Android 9 system partition:

```text
ro.build.version.release=9
ro.build.version.sdk=28
ro.product.model=LeEco Pro3
ro.product.name=ZL1_CN
ro.product.device=le_zl1
ro.build.fingerprint=LeEco/ZL1_CN/le_zl1:9/PKQ1.181007.001/9.11.13:user/release-keys
```

However, it is not directly sufficient as a Halium Android container image in the current form:

- `/boot/android-ramdisk.img` is missing from `system.img`.
- `/halium` overlay content is missing from `system.img`.
- The Halium initramfs `system.img` path calls `extract_android_ramdisk`, which expects `/android-system/boot/android-ramdisk.img` when `ANDROID_IMAGE_MODE=system`.

Therefore, before first Ubuntu Touch boot layout, create a separate derived Android container image or otherwise inject the required Android ramdisk/halium pieces into a copy. Do not modify this backup image in place.

## Backed up partitions

| Partition | Source block device | Size bytes | Size MiB | SHA256 |
|---|---|---:|---:|---|
| `boot` | `/dev/block/sde18` | 67108864 | 64.00 | `a06d6508499ee37a03effea1e6bec1d04f23843fd44d198a49fb3e07cb5778ef` |
| `recovery` | `/dev/block/sde20` | 67108864 | 64.00 | `25d4b3a865f612a8e38233579f4464c90f32c36b08a8ed761949de35430c7d95` |
| `system` | `/dev/block/sde19` | 4294967296 | 4096.00 | `1045472d40a9702ecd27d2a9459f1cc57a49fdeeeb3e43e6fe82dfc8f1d6171a` |
| `vendor` | `/dev/block/sde34` | 649523200 | 619.43 | `029c8e6047a6a8908ef3a069ebf49046dad2c3f676fbdfe6528d15e5067308ef` |
| `persist` | `/dev/block/sda2` | 33554432 | 32.00 | `958024a7ccc42114619efd35939f02d5da20f22474c8407a0f9bed31a866ee31` |
| `modem` | `/dev/block/sde12` | 115343360 | 110.00 | `ea7f9ca1f19a72550da980c907e4b400b8a40aaf3af4a8f36eb0fd44d45dca81` |
| `dsp` | `/dev/block/sde13` | 16777216 | 16.00 | `5c5060ab494de8e9db8a0bfc563cf339fd21026fe33b5a927684311d06d350bb` |
| `bluetooth` | `/dev/block/sde22` | 1048576 | 1.00 | `f45bfa8c71c8a647ae629a0853b5e588c12b82665140486ac70767653c520139` |
| `fsg` | `/dev/block/sde7` | 2097152 | 2.00 | `394f5915ab3f58dc82b878532670c29b0ef1eff256a6f6a443c47e6a362a4205` |
| `fsc` | `/dev/block/sdf5` | 4096 | 0.00 | `1b6393b8569585dc3118fc2fc051ec99e91e62f1dc1e57d8df3d4a9ff3fe51ce` |
| `modemst1` | `/dev/block/sdf1` | 2097152 | 2.00 | `50bcd0b3f7dcc99696f9d9dbcc479857b090b1c1adba4cf188330fd1a532a653` |
| `modemst2` | `/dev/block/sdf3` | 2097152 | 2.00 | `c1e5bda57cafb062e82d90b2e407d9ca1481132bba974477a8325230701586d6` |
| `xbl` | `/dev/block/sdb1` | 4149248 | 3.96 | `d149c68c5674610a6f13f2fe777efb1162053c8ca67e58a742e900287018c755` |
| `xblbak` | `/dev/block/sdc1` | 4149248 | 3.96 | `d149c68c5674610a6f13f2fe777efb1162053c8ca67e58a742e900287018c755` |
| `aboot` | `/dev/block/sde16` | 1048576 | 1.00 | `08ea3e13730735d1e3c50494a8a02c788c39f37bdaf951d59afefaa942516757` |
| `abootbak` | `/dev/block/sde17` | 1048576 | 1.00 | `08ea3e13730735d1e3c50494a8a02c788c39f37bdaf951d59afefaa942516757` |
| `tz` | `/dev/block/sde3` | 2097152 | 2.00 | `f7abd3394cc44bd17a5498c45cf966d6e9ff1d778069038cf9d693168f87c8f7` |
| `tzbak` | `/dev/block/sde4` | 2097152 | 2.00 | `f7abd3394cc44bd17a5498c45cf966d6e9ff1d778069038cf9d693168f87c8f7` |
| `rpm` | `/dev/block/sde1` | 524288 | 0.50 | `ce2ad535065d2bc78bd06b02753cf70719ca74d875011e514521d5ddf8922f0b` |
| `rpmbak` | `/dev/block/sde2` | 524288 | 0.50 | `ce2ad535065d2bc78bd06b02753cf70719ca74d875011e514521d5ddf8922f0b` |
| `hyp` | `/dev/block/sde5` | 524288 | 0.50 | `cf5e777809456a0f25abdf66d5e1fcb06713031d4bb852796eaccd076ed3c7bd` |
| `hypbak` | `/dev/block/sde6` | 524288 | 0.50 | `cf5e777809456a0f25abdf66d5e1fcb06713031d4bb852796eaccd076ed3c7bd` |
| `devcfg` | `/dev/block/sda6` | 131072 | 0.12 | `07684c0ca544b8a18879686fecc55c9c70296a8cba9996856d8c0f1a8e6f1b75` |
| `devcfgbak` | `/dev/block/sda7` | 131072 | 0.12 | `91ccb02e55d5eb7e3bf8222f31ad55793c63be030ab4333f9d75698060d061f8` |
| `keymaster` | `/dev/block/sde23` | 524288 | 0.50 | `e0c1a50b42933e687b05eb47bf9b336c5332202bdc0f28fe22b75d5fc27b454c` |
| `keymasterbak` | `/dev/block/sde24` | 524288 | 0.50 | `e0c1a50b42933e687b05eb47bf9b336c5332202bdc0f28fe22b75d5fc27b454c` |
| `cmnlib` | `/dev/block/sde25` | 262144 | 0.25 | `936294dea35094d19871c15515770702bab9361ef3bf643f1eef990db6457df3` |
| `cmnlibbak` | `/dev/block/sde26` | 262144 | 0.25 | `936294dea35094d19871c15515770702bab9361ef3bf643f1eef990db6457df3` |
| `cmnlib64` | `/dev/block/sde27` | 262144 | 0.25 | `64f0c90a3e8fb4159a74fa1b0ef9b965aaa9860540843991e9920321ace639ce` |
| `cmnlib64bak` | `/dev/block/sde28` | 262144 | 0.25 | `64f0c90a3e8fb4159a74fa1b0ef9b965aaa9860540843991e9920321ace639ce` |
| `splash` | `/dev/block/sde32` | 104857600 | 100.00 | `ef66e7546252867a5fc5c1dffe6d8a57e97cfd9ecbe4d3eac49411bdcd99e3a4` |

## Critical restore note

Keep this backup directory intact. If recovery is needed, restore only the specific partition required. Never write modem/EFS/persist partitions unless there is a clear, reviewed reason and no safer alternative.
