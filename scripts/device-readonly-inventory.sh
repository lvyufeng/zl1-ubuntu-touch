#!/usr/bin/env bash
set -euo pipefail

# Read-only inventory for LeEco Pro3 zl1. No flashing, no dd, no block writes.

SERIAL="${ADB_SERIAL:-${1:-}}"

pick_serial() {
  mapfile -t rows < <(adb devices -l | awk 'NR>1 && $2=="device" {print $0}')
  if [[ ${#rows[@]} -eq 0 ]]; then
    echo "No online ADB devices found" >&2
    exit 1
  fi

  local matches=()
  local row serial dev model
  for row in "${rows[@]}"; do
    serial=$(awk '{print $1}' <<<"$row")
    dev=$(sed -n 's/.*device:\([^ ]*\).*/\1/p' <<<"$row")
    model=$(sed -n 's/.*model:\([^ ]*\).*/\1/p' <<<"$row")
    if [[ "$dev" == "le_zl1" || "$dev" == "zl1" || "$model" == "LeEco_Pro3" ]]; then
      matches+=("$serial")
    fi
  done

  if [[ ${#matches[@]} -eq 1 ]]; then
    SERIAL="${matches[0]}"
    return
  fi

  echo "Unable to auto-select exactly one zl1 device." >&2
  echo "Connected devices:" >&2
  adb devices -l >&2
  echo "Pass serial explicitly: $0 <serial> or ADB_SERIAL=<serial> $0" >&2
  exit 1
}

adb_s() {
  adb -s "$SERIAL" "$@"
}

if [[ -z "$SERIAL" ]]; then
  pick_serial
fi

printf '== selected device ==\n'
adb_s devices -l | awk -v s="$SERIAL" '$1==s || NR==1 {print}'

printf '\n== properties ==\n'
props=(
  ro.product.device
  ro.product.vendor.device
  ro.product.model
  ro.product.name
  ro.product.brand
  ro.hardware
  ro.board.platform
  ro.build.version.release
  ro.build.version.sdk
  ro.build.version.security_patch
  ro.treble.enabled
  ro.vndk.version
  ro.vendor.build.version.release
  ro.boot.verifiedbootstate
  ro.boot.flash.locked
  ro.boot.slot_suffix
  ro.build.ab_update
  ro.build.system_root_image
  ro.boot.bootdevice
)
for p in "${props[@]}"; do
  v=$(adb_s shell getprop "$p" 2>/dev/null | tr -d '\r')
  printf '%s=%s\n' "$p" "$v"
done

printf '\n== battery ==\n'
adb_s shell dumpsys battery 2>/dev/null | sed -n '1,40p' || true

printf '\n== by-name partitions ==\n'
adb_s shell 'ls -l /dev/block/bootdevice/by-name 2>/dev/null || ls -l /dev/block/platform/*/by-name 2>/dev/null || true'

printf '\n== proc partitions ==\n'
adb_s shell 'cat /proc/partitions 2>/dev/null || true'

printf '\n== mounts ==\n'
adb_s shell 'cat /proc/mounts 2>/dev/null || true'

printf '\n== treble/vintf indicators ==\n'
adb_s shell 'ls -ld /vendor /system/vendor 2>/dev/null; ls /system/bin/hwservicemanager /vendor/manifest.xml /system/manifest.xml /vendor/etc/vintf/manifest.xml /system/etc/vintf/manifest.xml 2>/dev/null || true'
