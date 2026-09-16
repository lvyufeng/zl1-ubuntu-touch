#!/usr/bin/env bash
set -euo pipefail

# Create a host-side Android system image candidate for Halium from the trusted
# staged backup. This script does not touch the phone and does not modify the
# original backup images. It copies system.img, reconstructs a stock-ish Android
# ramdisk from boot.img, then injects /boot/android-ramdisk.img and a first-pass
# /halium udev overlay into the copy.

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 /path/to/staged-backup-dir /path/to/output-system.img [/path/to/rootfs.img]" >&2
  exit 2
fi

BACKUP_DIR=$(realpath -m "$1")
OUT_IMG=$(realpath -m "$2")
ROOTFS_IMG=$(realpath -m "${3:-/mnt/data/ubports-rootfs/rootfs.img}")
SYSTEM_IMG="$BACKUP_DIR/system.img"
BOOT_IMG="$BACKUP_DIR/boot.img"

for f in "$SYSTEM_IMG" "$BOOT_IMG" "$ROOTFS_IMG"; do
  [[ -f "$f" ]] || { echo "Missing required file: $f" >&2; exit 1; }
done

if [[ -e "$OUT_IMG" && "${FORCE:-0}" != "1" ]]; then
  echo "Output already exists: $OUT_IMG" >&2
  echo "Set FORCE=1 to overwrite." >&2
  exit 1
fi

for cmd in abootimg gzip cpio xz debugfs e2fsck sha256sum file; do
  command -v "$cmd" >/dev/null || { echo "Missing required command: $cmd" >&2; exit 1; }
done

WORK=$(mktemp -d)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

mkdir -p "$(dirname "$OUT_IMG")"
rm -f "$OUT_IMG"

printf 'Copying system image to candidate: %s\n' "$OUT_IMG"
cp --sparse=always "$SYSTEM_IMG" "$OUT_IMG"

printf 'Extracting Android boot ramdisk\n'
mkdir -p "$WORK/boot-unpack" "$WORK/android-ramdisk-root"
(
  cd "$WORK/boot-unpack"
  abootimg -x "$BOOT_IMG" >/dev/null
)
RAMDISK="$WORK/boot-unpack/initrd.img"
[[ -s "$RAMDISK" ]] || { echo "Failed to extract boot ramdisk" >&2; exit 1; }

# If the boot image was patched by Magisk, it contains a stock init backup in
# .backup/init.xz. Extract it so the container ramdisk does not start Magisk.
if gzip -dc "$RAMDISK" | cpio -i --to-stdout .backup/init.xz > "$WORK/stock-init.xz" 2>/dev/null && [[ -s "$WORK/stock-init.xz" ]]; then
  if xz -dc "$WORK/stock-init.xz" > "$WORK/stock-init" 2>/dev/null && [[ -s "$WORK/stock-init" ]]; then
    STOCK_INIT=1
  else
    STOCK_INIT=0
  fi
else
  STOCK_INIT=0
fi

printf 'Repacking Android ramdisk without Magisk overlay\n'
(
  cd "$WORK/android-ramdisk-root"
  # Exclude Magisk private backup and overlay entries. cpio's -f option means
  # "extract all except patterns" in copy-in mode.
  gzip -dc "$RAMDISK" | cpio -id --no-preserve-owner -f '.backup*' 'overlay.d*' --quiet 2>/dev/null || true
  rm -rf .backup overlay.d
  if [[ "$STOCK_INIT" == "1" ]]; then
    cp "$WORK/stock-init" init
    chmod 0750 init
  fi
  find . | LC_ALL=C sort | cpio -o -H newc -R 0:0 --quiet | gzip -9 > "$WORK/android-ramdisk.img"
)
[[ -s "$WORK/android-ramdisk.img" ]] || { echo "Failed to repack Android ramdisk" >&2; exit 1; }

printf 'Preparing first-pass Halium udev overlay\n'
UDEV_RULES="$WORK/70-android.rules"
# oneplus3 is also MSM8996 and is present in the official UBports rootfs. This
# is only a first-pass diagnostic overlay for zl1; replace with generated zl1
# rules after first boot logs are available.
if ! debugfs -R "dump /usr/lib/lxc-android-config/70-oneplus3.rules $UDEV_RULES" "$ROOTFS_IMG" >/dev/null 2>&1 || [[ ! -s "$UDEV_RULES" ]]; then
  cat > "$UDEV_RULES" <<'RULES'
# Minimal fallback rules for early Halium diagnostics. Replace with zl1-specific rules.
ACTION=="add", KERNEL=="kgsl*", OWNER="system", GROUP="system", MODE="0666"
ACTION=="add", KERNEL=="ion", OWNER="system", GROUP="system", MODE="0664"
ACTION=="add", KERNEL=="qseecom", OWNER="system", GROUP="drmrpc", MODE="0660"
ACTION=="add", KERNEL=="video*", OWNER="system", GROUP="camera", MODE="0660"
ACTION=="add", KERNEL=="media*", OWNER="system", GROUP="camera", MODE="0660"
RULES
fi

MARKER="$WORK/README.zl1-halium-candidate"
cat > "$MARKER" <<'MARKER'
This /system/halium overlay was added to a copy of the staged zl1 system backup
for a first Ubuntu Touch / Halium diagnostic boot. The original backup image was
not modified.

Contents added:
- /boot/android-ramdisk.img: Android boot ramdisk repacked without Magisk overlay
- /halium/lib/udev/rules.d/70-android.rules: first-pass MSM8996 udev rules
MARKER

printf 'Injecting files into candidate ext4 image\n'
# Create directories. Ignore failures where a directory already exists.
for d in /boot /halium /halium/lib /halium/lib/udev /halium/lib/udev/rules.d; do
  debugfs -w -R "mkdir $d" "$OUT_IMG" >/dev/null 2>&1 || true
done
# Replace files if the output image is being recreated over an old copy.
for p in /boot/android-ramdisk.img /halium/lib/udev/rules.d/70-android.rules /halium/README.zl1-halium-candidate; do
  debugfs -w -R "rm $p" "$OUT_IMG" >/dev/null 2>&1 || true
done
debugfs -w -R "write $WORK/android-ramdisk.img /boot/android-ramdisk.img" "$OUT_IMG" >/dev/null
debugfs -w -R "write $UDEV_RULES /halium/lib/udev/rules.d/70-android.rules" "$OUT_IMG" >/dev/null
debugfs -w -R "write $MARKER /halium/README.zl1-halium-candidate" "$OUT_IMG" >/dev/null

printf 'Checking candidate filesystem\n'
e2fsck -f -y "$OUT_IMG" >/dev/null

printf '\n== candidate ==\n'
file "$OUT_IMG"
sha256sum "$OUT_IMG"
printf '\n== injected files ==\n'
debugfs -R 'stat /boot/android-ramdisk.img' "$OUT_IMG" 2>/dev/null | sed -n '1,20p'
debugfs -R 'stat /halium/lib/udev/rules.d/70-android.rules' "$OUT_IMG" 2>/dev/null | sed -n '1,20p'
printf '\nDone. Original backup was not modified.\n'
