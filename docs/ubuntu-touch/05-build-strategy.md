# Build strategy

## Recommendation

Start with the legacy Halium 9 flow. This best matches the old `zl1` community port and the connected device state: Android 9, Treble true, VNDK 28, A-only.

The modern UBports standalone device package flow is cleaner long-term, but it is not the fastest route to reproducing the known old LePro3 port.

## High-level build flow

Use an external build tree:

```text
/mnt/data/halium-zl1-build
```

Initialize Halium 9:

```bash
repo init -u https://github.com/Halium/android -b halium-9.0 --depth=1
mkdir -p .repo/local_manifests
cp /mnt/data/zl1-bb10/manifests/halium-9-zl1.xml .repo/local_manifests/zl1.xml
repo sync -c --force-sync --no-clone-bundle --no-tags -j8
```

Build target:

```bash
source build/envsetup.sh
lunch lineage_zl1-userdebug
mka halium-boot
```

If `halium-boot` is unavailable, try the legacy target:

```bash
mka hybris-boot
```

Expected output:

```text
out/target/product/zl1/halium-boot.img
```

or:

```text
out/target/product/zl1/hybris-boot.img
```

## Build environment caveats

Halium 9 / Android 9 may need older build tooling:

- Python 2 compatibility
- OpenJDK 8
- Android build packages
- large disk space, likely 150 GB or more
- enough RAM/swap, ideally 16 GB+

Use a controlled container or VM if the host distribution is too new.

## Do not flash in build phase

A successful build only produces an image and checksum. Testing on the phone is a separate phase gated by backups.

## Local build-tree patch

The `halium-leeco` `lineage_zl1.mk` inherits `$(SRC_TARGET_DIR)/product/halium.mk`, but the synced Halium 9 base uses a LineageOS 16 `build/make` tree that does not include this file. Apply the reproducible local patch before building:

```bash
scripts/patch-halium9-build-tree.sh /mnt/data/halium-zl1-build
```

This creates a minimal `build/target/product/halium.mk` in the external build tree. It does not touch the phone and is intended only to make boot-only targets such as `halium-boot` parse/build.
