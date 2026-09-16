#!/usr/bin/env bash
set -euo pipefail

# Build host-side diagnostic Android boot images for zl1 Halium testing.
# This script does not talk to the phone, does not run fastboot, and does not
# write block devices. It only reads existing boot images and writes candidate
# boot images to an output directory.

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 /path/to/trusted-stock-boot.img /path/to/filtered-halium-boot.img /path/to/output-dir" >&2
  exit 2
fi

STOCK_BOOT=$(realpath -m "$1")
HALIUM_BOOT=$(realpath -m "$2")
OUT_DIR=$(realpath -m "$3")

for f in "$STOCK_BOOT" "$HALIUM_BOOT"; do
  [[ -f "$f" ]] || { echo "Missing boot image: $f" >&2; exit 1; }
done

require_cmd() {
  command -v "$1" >/dev/null || { echo "Missing required command: $1" >&2; exit 1; }
}
for cmd in abootimg mkbootimg python3 sha256sum stat; do
  require_cmd "$cmd"
done

mkdir -p "$OUT_DIR"
WORK_DIR=$(mktemp -d "$OUT_DIR/.make-diagnostic-boot.XXXXXX")
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

extract_cmdline() {
  python3 - "$1" <<'PY'
import sys
from pathlib import Path
cfg = Path(sys.argv[1])
for line in cfg.read_text().splitlines():
    if line.startswith('cmdline = '):
        print(line[len('cmdline = '):])
        break
else:
    raise SystemExit(f'cmdline not found in {cfg}')
PY
}

make_boot() {
  local kernel=$1
  local ramdisk=$2
  local cmdline=$3
  local output=$4

  mkbootimg \
    --kernel "$kernel" \
    --ramdisk "$ramdisk" \
    --cmdline "$cmdline" \
    --base 0x80000000 \
    --kernel_offset 0x00008000 \
    --ramdisk_offset 0x01000000 \
    --second_offset 0x00f00000 \
    --tags_offset 0x00000100 \
    --pagesize 4096 \
    --header_version 0 \
    -o "$output"
}

printf 'Mode: make host-side Halium diagnostic boot images\n'
printf 'Trusted stock boot: %s\n' "$STOCK_BOOT"
printf 'Filtered Halium boot: %s\n' "$HALIUM_BOOT"
printf 'Output directory: %s\n' "$OUT_DIR"
printf 'This script does not run adb/fastboot and does not touch the phone.\n\n'

abootimg -x "$STOCK_BOOT" \
  "$WORK_DIR/stock-bootimg.cfg" \
  "$WORK_DIR/stock-zImage" \
  "$WORK_DIR/stock-initrd.img" >/dev/null

abootimg -x "$HALIUM_BOOT" \
  "$WORK_DIR/halium-bootimg.cfg" \
  "$WORK_DIR/halium-zImage" \
  "$WORK_DIR/halium-initrd.img" >/dev/null

HALIUM_CMDLINE=$(extract_cmdline "$WORK_DIR/halium-bootimg.cfg")
DEBUG_CMDLINE="$HALIUM_CMDLINE debug break=premount"

HALIUM_DEBUG="$OUT_DIR/halium-boot-zl1-filtered-dtb-break-premount.img"
HYBRID_NORMAL="$OUT_DIR/hybrid-stock-kernel-halium-ramdisk.img"
HYBRID_DEBUG="$OUT_DIR/hybrid-stock-kernel-halium-ramdisk-break-premount.img"

make_boot "$WORK_DIR/halium-zImage" "$WORK_DIR/halium-initrd.img" "$DEBUG_CMDLINE" "$HALIUM_DEBUG"
make_boot "$WORK_DIR/stock-zImage" "$WORK_DIR/halium-initrd.img" "$HALIUM_CMDLINE" "$HYBRID_NORMAL"
make_boot "$WORK_DIR/stock-zImage" "$WORK_DIR/halium-initrd.img" "$DEBUG_CMDLINE" "$HYBRID_DEBUG"

printf 'Created diagnostic images:\n'
for img in "$HALIUM_DEBUG" "$HYBRID_NORMAL" "$HYBRID_DEBUG"; do
  printf '\n%s\n' "$img"
  printf '  size:   %s bytes\n' "$(stat -c '%s' "$img")"
  printf '  sha256: %s\n' "$(sha256sum "$img" | awk '{print $1}')"
done

printf '\nSuggested first diagnostic after the phone is back in fastboot:\n'
printf '  fastboot boot %s\n' "$HALIUM_DEBUG"
printf '\nIf that remains invisible, try the stock-kernel hybrid break image:\n'
printf '  fastboot boot %s\n' "$HYBRID_DEBUG"
printf '\nDo not flash these images unless separately reviewed and explicitly approved.\n'
