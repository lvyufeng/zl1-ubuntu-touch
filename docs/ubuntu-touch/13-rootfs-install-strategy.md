# Rootfs install strategy for zl1 Halium 9

This document sketches the next phase after successfully rebuilding `halium-boot.img`. It is not an instruction to flash yet.

## Current state

Built boot artifact:

```text
/mnt/data/halium-zl1-build/out/target/product/zl1/halium-boot.img
SHA256: 49113e509ab49a881894d04a13f70adb62a19d53f8bcd1e34e5cb04135da0aa4
```

The image contains the standard Halium initramfs and expects the actual Ubuntu Touch userspace and Android container image to be available separately, usually from userdata.

## Why boot image alone is not enough

The Halium initramfs searches userdata for one of these rootfs layouts:

```text
/tmpmnt/rootfs.img
/tmpmnt/ubuntu.img
/tmpmnt/halium-rootfs/
```

It also searches for the Android container image:

```text
/tmpmnt/system.img
/tmpmnt/android-rootfs.img
/halium-system/var/lib/lxc/android/system.img
/halium-system/var/lib/lxc/android/android-rootfs.img
```

If these are missing, `fastboot boot halium-boot.img` may only reach initramfs panic/debug, not Ubuntu Touch.

## Candidate inputs

### Ubuntu userspace/rootfs

Use official UBports Android 9 arm64 rootfs payload as the preferred starting point:

```text
URL:    https://system-image.ubports.com/pool/ubports-adcf0041722f9409869b3ffde1f1b6059687581073045c1c5d7b2ae7862c38cf.tar.xz
Size:   369,259,968 bytes
SHA256: fb42e5938de7e3bc040e18e69766dc756284ec34f3bc0dd589f978d2ab47fa56
Source: 16.04/arm64/android9/stable, OTA-25 era
```

This is common Ubuntu Touch userspace, not a complete `zl1` device image.


### Rootfs image already created on host

A first host-only ext4 image has been created from the verified UBports rootfs tarball:

```text
Path:   /mnt/data/ubports-rootfs/rootfs.img
Size:   4,294,967,296 bytes / 4096 MiB
SHA256: 799bdad9a54fc581ad2ba0bda46c71eb7f94c9b2140136bc06e581a318e7fb87
Label:  UBPORTS_ROOTFS
State:  clean ext4
```

Verified key paths inside the image:

```text
/sbin/init -> upstart
/etc/system-image/writable-paths
/var/lib/lxc/android/config
/var/lib/lxc/android/rootfs/
```

During host-side extraction GNU tar printed many `acl_set_file_at: Operation not supported` warnings because the temporary staging directory/fakeroot environment could not materialize POSIX ACLs. The image was still created and fsck-clean, but for a later production-quality install this should be revisited, ideally by using the official UBports system-image installer flow or by creating the rootfs image in an environment that can preserve ACLs exactly.

### Android container image

Still needed. Options:

1. **Build from source**
   - Target likely starts from the current Halium/Lineage source tree.
   - More correct, but may need many fixes beyond the boot-only build.

2. **Derive from local Android 9 system partition backup**
   - Use a copy of the phone's currently working Android 9 `system` image as the Android side.
   - The trusted staged backup is now available at `/mnt/data/zl1-backups/2026-06-07-adb-root-staged/system.img`.
   - The staged image is a valid ext4 backup and sample blocks match the live device, but it is not directly sufficient as a Halium Android container image because `/boot/android-ramdisk.img` and `/system/halium` overlay content are missing.
   - Next step: derive a separate candidate Android container image from this backup plus extracted Android boot ramdisk / Halium overlay material. Do not modify the backup image in place.

3. **Recreate a UBports device payload**
   - Long-term clean path.
   - Requires adding `zl1` device overlay/config and possibly UBports Installer metadata.

Do not use another phone's `device-*.tar.xz` payload except as a structural reference.

## Proposed low-risk workflow

### Phase A — Host-only download and verification

Download the official common rootfs on the host only:

```bash
mkdir -p /mnt/data/ubports-rootfs
cd /mnt/data/ubports-rootfs
curl -L -o ubports-16.04-arm64-android9-ota25.tar.xz \
  https://system-image.ubports.com/pool/ubports-adcf0041722f9409869b3ffde1f1b6059687581073045c1c5d7b2ae7862c38cf.tar.xz
sha256sum ubports-16.04-arm64-android9-ota25.tar.xz
```

Expected SHA256:

```text
fb42e5938de7e3bc040e18e69766dc756284ec34f3bc0dd589f978d2ab47fa56
```

This does not touch the phone.

### Phase B — Partition backup

Before any boot/install test, back up partitions with the staged rooted-ADB script or recovery script:

```bash
scripts/device-readonly-inventory.sh
mkdir -p /mnt/data/zl1-backups/YYYY-MM-DD
scripts/backup-partitions-adb-staged.sh /mnt/data/zl1-backups/YYYY-MM-DD 33e80afe
```

TWRP/recovery backup is preferred if available, but Android/Magisk direct stdout streaming is not trusted on this device; use staged pull in Android mode.

Minimum critical partitions:

```text
boot recovery system vendor persist modem dsp bluetooth fsg fsc modemst1 modemst2
xbl xblbak aboot abootbak tz tzbak rpm rpmbak hyp hypbak devcfg devcfgbak
keymaster keymasterbak cmnlib cmnlibbak cmnlib64 cmnlib64bak splash
```

### Phase C — Create host-side images

After backups, create/test images on the host first:

- `rootfs.img` from the UBports rootfs tarball.
- `system.img` or `android-rootfs.img` for the Android container.

The historical `halium-install` tooling expects roughly:

```text
rootfs.tar[.gz]
system.img
```

and can create userdata-based images, but it writes to the device when run normally. For this project, prefer adapting the image creation steps host-side first, then review any device-side writes separately.

### Phase D — First diagnostic boot

Only after backups and explicit approval:

```bash
fastboot boot /mnt/data/halium-zl1-build/out/target/product/zl1/halium-boot.img
```

For initramfs debugging:

```bash
fastboot boot halium-boot.img -c break=premount
```

Then check whether telnet appears:

```bash
telnet 192.168.2.15
```

Note: even temporary boot is not guaranteed read-only because the initramfs can fsck/resize/mount userdata.

## Open questions

- Can the current phone's LineageOS 16 `system` partition backup be used directly as Halium `system.img`?
- Does the `zl1` Android system image need Halium-specific overlays under `/system/halium`?
- Is a complete old `ubports_GSI_installer_v9.zip` mirror still available somewhere?
- Is it easier to build `systemimage`/`system.img` from the synced Halium tree than to adapt the current phone image?
