# Halium source repositories

Use the `halium-leeco` source stack for the first rebuild attempt.

## Required projects

| Path | Repository | Branch |
|---|---|---|
| `device/leeco/zl1` | `https://github.com/halium-leeco/android_device_leeco_zl1` | `halium-9.0` |
| `device/leeco/msm8996-common` | `https://github.com/halium-leeco/android_device_leeco_msm8996-common` | `halium-9.0` |
| `kernel/leeco/msm8996` | `https://github.com/halium-leeco/android_kernel_leeco_msm8996` | `halium-9.0` |
| `vendor/leeco` | `https://github.com/halium-leeco/proprietary_vendor_leeco` | `halium-9.0` |

The local manifest is in:

```text
manifests/halium-9-zl1.xml
```

## Extra dependency

`android_device_leeco_msm8996-common` depends on:

```text
packages/resources/devicesettings
```

Check whether this is supplied by the Halium/Lineage base manifest. If not, add a matching LineageOS project to the local manifest.

## lxc-android note

`https://github.com/halium-leeco/lxc-android` has branches such as `halium-boot-changes` and `halium-boot-rebase`, but no direct `halium-9.0` branch. Do not blindly use `master`; first verify whether the Halium 9 base already supplies the necessary Android container changes.

## Expected product

The device product is expected to be:

```text
lineage_zl1-userdebug
```

The primary kernel defconfig is expected to be:

```text
kernel/leeco/msm8996/arch/arm64/configs/lineage_zl1_defconfig
```
