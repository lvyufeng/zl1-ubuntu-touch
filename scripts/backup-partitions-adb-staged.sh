#!/usr/bin/env bash
set -euo pipefail

# Back up allowlisted partitions with rooted ADB by first writing each image to a
# temporary file on /data/local/tmp, then adb-pulling that file to the host.
# This avoids Magisk/ADB exec-out stdout corruption observed when streaming large
# block devices directly. It still performs no writes to device block devices and
# contains no flash commands. It does write temporary regular files to userdata.

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 /host/backup-dir [adb-serial]" >&2
  exit 2
fi

OUT_DIR=$(realpath -m "$1")
SERIAL="${2:-${ADB_SERIAL:-}}"
REMOTE_TMP_DIR="${REMOTE_TMP_DIR:-/data/local/tmp/zl1-partition-backup}"
ALLOWLIST=(boot recovery system vendor persist modem dsp bluetooth fsg fsc modemst1 modemst2 xbl xblbak aboot abootbak tz tzbak rpm rpmbak hyp hypbak devcfg devcfgbak keymaster keymasterbak cmnlib cmnlibbak cmnlib64 cmnlib64bak splash)

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

remote_sh() {
  adb_s shell "$@" | tr -d '\r'
}

remote_su() {
  # Feed the command through a root shell on stdin. Passing complex commands as
  # `adb shell su -c "$cmd"` is not safe here: adb/Android shell can split on
  # semicolons before `su` sees the full command, causing dd to run unprivileged.
  adb_s shell su -c sh <<EOF | tr -d '\r'
$1
EOF
}

mkdir -p "$OUT_DIR"

printf 'Mode: Android/Magisk ADB staged pull\n'
printf 'Target serial: %s\n' "$SERIAL"
printf 'Output dir: %s\n' "$OUT_DIR"
printf 'Remote temp dir: %s\n' "$REMOTE_TMP_DIR"
printf 'This writes temporary regular files under /data/local/tmp, pulls them, then deletes them.\n'
printf 'It does not write to device block devices and contains no flash commands.\n'
read -r -p 'Type STAGED_BACKUP to continue: ' ans
[[ "$ans" == "STAGED_BACKUP" ]] || { echo "Cancelled"; exit 1; }

: > "$OUT_DIR/SHA256SUMS"
: > "$OUT_DIR/partition-sizes.txt"
: > "$OUT_DIR/backup-log.txt"

cleanup_remote_tmp() {
  remote_su "rm -f '$REMOTE_TMP_DIR'/*.img '$REMOTE_TMP_DIR'/*.partial 2>/dev/null || true" >/dev/null 2>&1 || true
}

remote_su "mkdir -p '$REMOTE_TMP_DIR'"
trap cleanup_remote_tmp EXIT

success_count=0
fail_count=0
skip_count=0

for part in "${ALLOWLIST[@]}"; do
  path=$(remote_sh "readlink -f /dev/block/bootdevice/by-name/$part 2>/dev/null || readlink -f /dev/block/platform/*/by-name/$part 2>/dev/null || true")
  if [[ -z "$path" ]]; then
    echo "SKIP $part: not found" | tee -a "$OUT_DIR/backup-log.txt"
    ((skip_count+=1))
    continue
  fi

  node=$(basename "$path")
  size=$(remote_sh "blockdev --getsize64 '$path' 2>/dev/null || awk '\$4==\"$node\" {print \$3*1024}' /proc/partitions 2>/dev/null || true")
  if [[ ! "$size" =~ ^[0-9]+$ || "$size" == "0" ]]; then
    echo "FAIL $part: could not determine size for $path" | tee -a "$OUT_DIR/backup-log.txt"
    ((fail_count+=1))
    continue
  fi

  echo "$part $path $size" >> "$OUT_DIR/partition-sizes.txt"
  echo "Backing up $part from $path ($size bytes)" | tee -a "$OUT_DIR/backup-log.txt"

  remote_file="$REMOTE_TMP_DIR/${part}.img"
  rm -f "$OUT_DIR/${part}.img" "$OUT_DIR/${part}.img.partial"

  # Create exact-size temp image on userdata. conv=fsync ensures data reaches
  # storage before adb pull starts.
  if ! remote_su "rm -f '$remote_file' '$remote_file.partial'; dd if='$path' of='$remote_file.partial' bs=4096 2>/dev/null; sync '$remote_file.partial' 2>/dev/null || sync; mv '$remote_file.partial' '$remote_file'; chmod 644 '$remote_file' 2>/dev/null || true" >/dev/null; then
    echo "FAIL $part: remote dd failed" | tee -a "$OUT_DIR/backup-log.txt"
    remote_su "rm -f '$remote_file' '$remote_file.partial'" >/dev/null || true
    ((fail_count+=1))
    continue
  fi

  remote_size=$(remote_sh "stat -c '%s' '$remote_file' 2>/dev/null || wc -c < '$remote_file' 2>/dev/null || true")
  if [[ "$remote_size" != "$size" ]]; then
    echo "FAIL $part: remote expected $size bytes, got $remote_size bytes" | tee -a "$OUT_DIR/backup-log.txt"
    remote_su "rm -f '$remote_file' '$remote_file.partial'" >/dev/null || true
    ((fail_count+=1))
    continue
  fi

  if ! adb_s pull "$remote_file" "$OUT_DIR/${part}.img.partial" >/dev/null; then
    echo "FAIL $part: adb pull failed" | tee -a "$OUT_DIR/backup-log.txt"
    rm -f "$OUT_DIR/${part}.img.partial"
    remote_su "rm -f '$remote_file' '$remote_file.partial'" >/dev/null || true
    ((fail_count+=1))
    continue
  fi

  mv "$OUT_DIR/${part}.img.partial" "$OUT_DIR/${part}.img"
  actual=$(stat -c '%s' "$OUT_DIR/${part}.img")
  remote_su "rm -f '$remote_file' '$remote_file.partial'" >/dev/null || true

  if [[ "$actual" != "$size" ]]; then
    echo "FAIL $part: pulled expected $size bytes, got $actual bytes" | tee -a "$OUT_DIR/backup-log.txt"
    rm -f "$OUT_DIR/${part}.img"
    ((fail_count+=1))
    continue
  fi

  sha256sum "$OUT_DIR/${part}.img" | tee -a "$OUT_DIR/SHA256SUMS"
  ((success_count+=1))
done

remote_su "rmdir '$REMOTE_TMP_DIR' 2>/dev/null || true" >/dev/null || true

echo "Backups complete: $OUT_DIR"
echo "Summary: success=$success_count fail=$fail_count skip=$skip_count" | tee -a "$OUT_DIR/backup-log.txt"
if [[ "$fail_count" != "0" || "$success_count" == "0" ]]; then
  exit 1
fi
