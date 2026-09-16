# Ubuntu Touch rootfs / GSI tracking

Status: 2026-06-07

The old LePro3 X72X / `zl1` community instructions referenced a UBports GSI-style installer, but the known historical URL is currently unavailable. Official UBports infrastructure still has Android 9 / arm64 system-image channels, but they are device-specific and do **not** include `zl1`.

## Candidate requirements

A replacement Ubuntu Touch userspace/rootfs path should match:

- architecture: arm64
- Android base: 9 / Halium 9
- VNDK: 28
- partition style: A-only Treble or a compatible userdata-based Halium layout
- device: Qualcomm MSM8996 / Snapdragon 821 family with Android vendor support
- no modem/EFS/persist writes

## Historical GSI status

| Candidate | URL | Date | Android base | A-only/A-B | Checksum | Trust level | Notes |
|---|---|---:|---|---|---|---|---|
| Historical UBports GSI installer v9 | `https://build.lolinet.com/file/halium/GSI/ubports_GSI_installer_v9.zip` | 2021 era | 9 | A/AB claimed by old reports | unknown | missing | Returned 404 during current research. |

The general lolinet GSI mirror is reachable, but it does not currently expose a UBports/Ubuntu Touch directory under `firmware/gsi/`.

## Official UBports system-image findings

Official system-image metadata is available at:

```text
https://system-image.ubports.com/channels.json
```

Relevant discovered channels:

| Channel | Exists | Device count observed | Notes |
|---|---:|---:|---|
| `16.04/arm64/android9/devel` | yes | 48 | Android 9 / arm64 device ports. |
| `16.04/arm64/android9/rc` | yes | 35 | Android 9 / arm64 release-candidate channel. |
| `16.04/arm64/android9/stable` | yes | 33 | Android 9 / arm64 stable channel. |
| `20.04/arm64/android9/*` | not observed | 0 | No matching Android 9 channels found in current metadata. |

`zl1` / `le_zl1` is not listed in the official channel metadata or the UBports Installer `v2/devices` list.

The Android 9 system-image model is not a single generic flashable GSI. A full image entry normally contains:

- common Ubuntu Touch rootfs payload: `ubports-*.tar.xz`
- device-specific payload: `device-*.tar.xz`
- sometimes a device-specific boot payload: `boot-*.tar.xz`
- keyring and version metadata

The common rootfs payload is reusable as a candidate input, but the device payloads for other devices are **not** directly compatible with `zl1`.

## Candidate table

| Candidate | URL / index | Channel | Checksum | Trust level | Usefulness for `zl1` | Notes |
|---|---|---|---|---|---|---|
| Official common UBports 16.04 Android 9 rootfs, OTA-25 | `https://system-image.ubports.com/pool/ubports-adcf0041722f9409869b3ffde1f1b6059687581073045c1c5d7b2ae7862c38cf.tar.xz` | `16.04/arm64/android9/stable` | `fb42e5938de7e3bc040e18e69766dc756284ec34f3bc0dd589f978d2ab47fa56` | official | promising rootfs input only | Downloaded to `/mnt/data/ubports-rootfs/ubports-16.04-arm64-android9-ota25.tar.xz`; size `369,259,968` bytes; SHA256 verified. Needs a `zl1`-compatible Android system image/device payload. |
| Official beryllium stable image metadata | `https://system-image.ubports.com/16.04/arm64/android9/stable/beryllium/index.json` | stable | metadata includes checksums | official | layout reference only | Contains common rootfs plus beryllium-specific device and boot payloads. Do not flash/use beryllium device payload on `zl1`. |
| Official cheeseburger stable image metadata | `https://system-image.ubports.com/16.04/arm64/android9/stable/cheeseburger/index.json` | stable | metadata includes checksums | official | layout/installer reference only | Installer config uses recovery + `systemimage:install`; device payload is OnePlus 5-specific. |
| Official UBports Installer configs | `https://github.com/ubports/installer-configs/tree/master/v2/devices` | n/a | n/a | official | reference only | No `zl1.yml` found. Android 9 ports select system-image channels and then run device-specific install steps. |

## What the rebuilt `halium-boot.img` expects

The rebuilt boot image includes the standard Halium initramfs. Its `scripts/halium` logic looks for a userdata-based installation layout:

- finds a data partition named one of: `userdata`, `UDA`, `DATAFS`, `USERDATA`
- mounts userdata at `/tmpmnt`
- identifies Ubuntu Touch / Halium rootfs by checking:
  - `/tmpmnt/rootfs.img`
  - `/tmpmnt/ubuntu.img`
  - `/tmpmnt/halium-rootfs/`
- identifies Android image by checking:
  - `/tmpmnt/system.img`
  - `/tmpmnt/android-rootfs.img`
  - `/halium-system/var/lib/lxc/android/system.img`
  - `/halium-system/var/lib/lxc/android/android-rootfs.img`

Therefore `fastboot boot halium-boot.img` alone is only a diagnostic boot unless the required rootfs and Android image are already present on userdata. Without them, the initramfs should not reach a usable Ubuntu Touch userspace.

Important: even temporary boot can write to userdata. The initramfs performs filesystem checks and may resize userdata before mounting it. Treat `fastboot boot` as requiring backups, not as perfectly read-only.

## Current conclusion

There is no confirmed ready-to-flash `zl1` Ubuntu Touch GSI/rootfs package yet.

Most promising path:

1. Use the official UBports 16.04 Android 9 common rootfs tarball as the Ubuntu userspace input.
2. Build or derive a `zl1`-compatible Android system image for the LXC Android container.
3. Place the resulting rootfs/system images on userdata only after backups are complete.
4. Boot the already-built `halium-boot.img` for diagnostics.

Possible ways to obtain the Android side:

| Approach | Pros | Cons |
|---|---|---|
| Build a `zl1` Halium/Android system image from source | Most correct/reproducible | The current source tree was only proven for `halium-boot`; full system image may need many more fixes/dependencies. |
| Derive `system.img` from the current Android 9 / LineageOS 16 system partition backup | Uses known-booting local Android base | Must be done after backup; may not include all Halium-specific overlays/configuration. |
| Recreate a UBports-style `zl1` device tarball and installer config | Long-term clean path | Requires more porting work and testing. |
| Use another official device payload | Easy to download | Not safe/compatible; should be used only as a reference for structure. |

## Safe next steps

1. Download the official common UBports rootfs tarball to the host and verify SHA256.
2. Do **not** install it yet.
3. Back up the phone partitions first, especially `boot`, `system`, `vendor`, `persist`, modem/EFS-related partitions, and boot chain partitions.
4. After backups, decide whether to:
   - build a `zl1` system image from source, or
   - create a host copy of the current Android `system` partition and test it as the Halium Android image.

No system/vendor/userdata flashing should happen at this stage.
