#!/usr/bin/env bash
set -euo pipefail

MODE="adb"
MODE_LABEL="Android/Magisk ADB"

# Back up allowlisted partitions by streaming reads over ADB exec-out.
# No writes to device block devices. No flashing.

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 /host/backup-dir [adb-serial]" >&2
  exit 2
fi

OUT_DIR=$(realpath -m "$1")
SERIAL="${2:-${ADB_SERIAL:-}}"
ALLOWLIST=(boot recovery system vendor persist modem dsp bluetooth fsg fsc modemst1 modemst2 xbl xblbak aboot abootbak tz tzbak rpm rpmbak hyp hypbak devcfg devcfgbak keymaster keymasterbak cmnlib cmnlibbak cmnlib64 cmnlib64bak dtbo vbmeta splash)

pick_serial() {
  mapfile -t rows < <(adb devices -l | awk 'NR>1 && $2=="device" {print $0}')
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
  else
    adb devices -l >&2
    echo "Pass serial explicitly: $0 /backup/dir <serial>" >&2
    exit 1
  fi
}

[[ -n "$SERIAL" ]] || pick_serial
adb_s() { adb -s "$SERIAL" "$@"; }

mkdir -p "$OUT_DIR"

printf 'Mode: %s\n' "$MODE_LABEL"
printf 'Target serial: %s\n' "$SERIAL"
printf 'Output dir: %s\n' "$OUT_DIR"
printf 'This script streams partition reads to the host with adb exec-out.\n'
printf 'It does not write to device block devices and contains no flash commands.\n'
if [[ "$MODE" == "adb" ]]; then
  printf 'Android mode may require Magisk/root approval for su. If su is denied, privileged partitions cannot be read.\n'
fi
read -r -p 'Type BACKUP to continue: ' ans
[[ "$ans" == "BACKUP" ]] || { echo "Cancelled"; exit 1; }

: > "$OUT_DIR/SHA256SUMS"
: > "$OUT_DIR/partition-sizes.txt"
: > "$OUT_DIR/backup-log.txt"

remote_sh() {
  adb_s shell "$@" | tr -d '\r'
}

stream_partition() {
  local path=$1
  local out=$2
  local expected_size=${3:-}
  local tmp="${out}.partial"
  local actual=0
  local status=0
  rm -f "$tmp"

  # Stream exact partition bytes to the host. Magisk `su` over `adb exec-out` can
  # append extra bytes after block reads on this device; host-side truncation to
  # blockdev's reported size prevents oversized/corrupt backups. This still only
  # reads from the device and never writes device block nodes.
  if [[ "$expected_size" =~ ^[0-9]+$ && "$expected_size" != "0" ]]; then
    set +e
    set +o pipefail
    if [[ "$MODE" == "adb" && "${USE_SU:-1}" == "1" ]]; then
      adb_s exec-out su -c "dd if='$path' bs=4096 2>/dev/null" | head -c "$expected_size" > "$tmp"
    else
      adb_s exec-out sh -c "dd if='$path' bs=4096 2>/dev/null" | head -c "$expected_size" > "$tmp"
    fi
    status=$?
    set -o pipefail
    set -e

    actual=$(stat -c '%s' "$tmp" 2>/dev/null || echo 0)
    if [[ "$actual" != "$expected_size" ]]; then
      rm -f "$tmp"
      return 1
    fi
    mv "$tmp" "$out"
    return 0
  fi

  # Fallback for unknown sizes.
  set +e
  if [[ "$MODE" == "adb" && "${USE_SU:-1}" == "1" ]]; then
    adb_s exec-out su -c "dd if='$path' bs=4096 2>/dev/null" > "$tmp"
  else
    adb_s exec-out sh -c "dd if='$path' bs=4096 2>/dev/null" > "$tmp"
  fi
  status=$?
  set -e

  if [[ $status -ne 0 ]]; then
    rm -f "$tmp"
    return "$status"
  fi
  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$out"
}

for part in "${ALLOWLIST[@]}"; do
  path=$(remote_sh "readlink -f /dev/block/bootdevice/by-name/$part 2>/dev/null || readlink -f /dev/block/platform/*/by-name/$part 2>/dev/null || true")
  if [[ -z "$path" ]]; then
    echo "SKIP $part: not found" | tee -a "$OUT_DIR/backup-log.txt"
    continue
  fi

  node=$(basename "$path")
  size=$(remote_sh "blockdev --getsize64 '$path' 2>/dev/null || awk '\$4==\"$node\" {print \$3*1024}' /proc/partitions 2>/dev/null || true")
  echo "$part $path $size" >> "$OUT_DIR/partition-sizes.txt"
  echo "Backing up $part from $path" | tee -a "$OUT_DIR/backup-log.txt"

  if stream_partition "$path" "$OUT_DIR/${part}.img" "$size"; then
    actual=$(stat -c '%s' "$OUT_DIR/${part}.img")
    if [[ -n "$size" && "$size" != "0" && "$actual" != "$size" ]]; then
      echo "WARN $part: expected $size bytes, got $actual bytes" | tee -a "$OUT_DIR/backup-log.txt"
    fi
    sha256sum "$OUT_DIR/${part}.img" | tee -a "$OUT_DIR/SHA256SUMS"
  else
    echo "FAIL $part: read failed" | tee -a "$OUT_DIR/backup-log.txt"
    rm -f "$OUT_DIR/${part}.img" "$OUT_DIR/${part}.img.partial"
  fi
done

echo "Backups complete: $OUT_DIR"
