# Boot diagnostics record — 2026-06-07

Target: LeEco Pro3 `zl1` / `le_zl1` / MSM8996.

Safety state:

- No boot image has been flashed.
- Tests used temporary `fastboot boot` only.
- No modem/EFS/persist writes were performed.
- Trusted staged partition backup exists at `/mnt/data/zl1-backups/2026-06-07-adb-root-staged`.
- Ubuntu Touch/Halium images are staged as regular userdata files only:
  - `/data/rootfs.img`
  - `/data/system.img`

## Userdata images staged before boot tests

`/data/rootfs.img`:

```text
Size:   4,294,967,296 bytes
SHA256: 799bdad9a54fc581ad2ba0bda46c71eb7f94c9b2140136bc06e581a318e7fb87
Source: /mnt/data/ubports-rootfs/rootfs.img
```

`/data/system.img`:

```text
Size:   4,294,967,296 bytes
SHA256: ec1d52fa36b37893b840e30a60dbbda4a54b0058bf258ab1b1d20ba8508142f8
Source: /mnt/data/halium-zl1-candidates/android-system-zl1-halium-candidate.img
```

Both remote files were pushed over ADB as regular files and verified by remote SHA256.

## Attempt 1: first rebuilt Halium boot image

Artifact:

```text
Path:   /mnt/data/halium-zl1-build/out/target/product/zl1/halium-boot.img
Size:   25,264,128 bytes
SHA256: 49113e509ab49a881894d04a13f70adb62a19d53f8bcd1e34e5cb04135da0aa4
```

Result:

```text
Sending 'boot.img' (24672 KB) OKAY
Booting FAILED (remote: 'dtb not found')
```

Diagnosis:

The kernel defconfig selected the wrong LeEco product variant:

```text
CONFIG_PRODUCT_LE_X2=y
# CONFIG_PRODUCT_LE_ZL1 is not set
```

This produced a boot image whose appended DTB set did not satisfy the zl1 bootloader.

## Attempt 2: ZL1 product selected, but unfiltered DTB output

Intermediate artifact:

```text
Size:   27,230,208 bytes
SHA256: 847dee6baa6a2db461c64148f635e616eb3ade946d95e5a12ea80bbabfdd1ad2
DTBs:   28
```

Result:

- The bootloader no longer reported `dtb not found`.
- The device entered Qualcomm 9008/QDL mode:

```text
05c6:9008 Qualcomm, Inc. Gobi Wireless Modem (QDL mode)
iProduct: QUSB__BULK
```

Recovery:

- USB reset did not recover it.
- A physical reboot restored normal Android boot.

Diagnosis:

Although `CONFIG_PRODUCT_LE_ZL1=y` was set, `CONFIG_BUILD_ARM64_APPENDED_DTB_IMAGE_NAMES=""` caused the kernel Makefile to append every generated DTB under the output `dts/` directory. Stale X2 DTBs from previous builds were included with ZL1 DTBs. This mixed 28-DTB image is not safe to retry.

## Attempt 3: filtered five-DTB ZL1 image

Saved artifact:

```text
Path:   /mnt/data/halium-zl1-candidates/halium-boot-zl1-filtered-dtb.img
Size:   17,997,824 bytes
SHA256: cd5cf3c1a715821eb6d63e390abcde4d64bb9f844c52c77ef055c2017fbab109
DTBs:   5
```

The explicit DTB list is:

```text
qcom/msm8996pro-pmi8996-le_zl1-dvt1
qcom/msm8996-v3-pmi8996-le_zl1-dvt1
qcom/msm8996pro-pmi8996-le_zl1-na
qcom/msm8996-v3-pmi8996-le_zl1-evt
qcom/msm8996pro-pmi8996-le_zl1-pvt
```

Observed DTB IDs:

```text
00: msm-id <0x131 0x10000>, pmic-id <0x20009 0x10013 0x0 0x0>, board-id <0x8 0xa2>
01: msm-id <0xf6 0x30001>,  pmic-id <0x20009 0x10013 0x0 0x0>, board-id <0x8 0xa2>
02: msm-id <0x131 0x10000>, pmic-id <0x20009 0x10013 0x0 0x0>, board-id <0x8 0xa4>
03: msm-id <0xf6 0x30001>,  pmic-id <0x20009 0x10013 0x0 0x0>, board-id <0x8 0xa1>
04: msm-id <0x131 0x10000>, pmic-id <0x20009 0x10013 0x0 0x0>, board-id <0x8 0xa5>
```

These match the stock boot DTB board-id set/order.

Temporary boot command used:

```bash
fastboot boot /mnt/data/halium-zl1-candidates/halium-boot-zl1-filtered-dtb.img
```

Fastboot result:

```text
Sending 'boot.img' (17576 KB) OKAY [  0.505s]
Booting                 OKAY [  0.396s]
Finished. Total time: 0.922s
```

Post-boot observation after polling:

- Target `33e80afe` did not appear in ADB.
- Target did not appear in fastboot.
- Target did not appear as 9008/QDL.
- No USB network interface appeared.
- `192.168.2.15` and `10.15.19.82` did not respond.
- Only the other connected device was visible:

```text
4a2fe00b device usb:3-10 product:cancro model:MI_4LTE device:cancro
```

A later host check still showed only the other Android device and no fastboot/QDL/USB-network target.

## Current conclusion

The DTB selection problem is fixed: the filtered image is accepted by the bootloader and no longer drops immediately to visible 9008/QDL.

The remaining failure is after bootloader handoff. Likely categories:

1. Halium kernel hangs before USB gadget is initialized.
2. Initramfs starts but never reaches a panic/break path that exposes telnet/RNDIS.
3. Rootfs/userdata discovery or filesystem handling blocks before visible USB setup.
4. USB gadget setup is incompatible with this kernel/configuration.
5. Device is displaying or waiting locally without enumerating over USB.

Do not repeat blind normal boots yet.

## Next safer diagnostic path

Prepare diagnostic boot images locally, without touching phone partitions:

1. `halium-boot-zl1-filtered-dtb-break-premount.img`
   - Same filtered Halium kernel/DTBs and Halium initramfs.
   - Adds `debug break=premount` to the cmdline.
   - Should enter initramfs panic/telnet before userdata mount/fsck.

2. `hybrid-stock-kernel-halium-ramdisk-break-premount.img`
   - Uses the trusted stock boot kernel+appended DTBs.
   - Uses the Halium initramfs.
   - Adds `debug break=premount`.
   - Helps distinguish a Halium kernel/USB issue from an initramfs/gadget issue.

Testing these still requires recovering the target to Android or fastboot first. Continue using `fastboot boot`; do not flash.
