#!/usr/bin/env bash
set -euo pipefail

# Stage Ubuntu Touch / Halium images onto Android userdata as regular files.
# This writes only /data/rootfs.img and /data/system.img (plus temporary files
# under /data/local/tmp while transferring). It does not write block devices and
# contains no fastboot/flash commands.

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 /path/to/rootfs.img /path/to/system.img [adb-serial]" >&2
  exit 2
fi

ROOTFS_IMG=$(realpath -m "$1")
SYSTEM_IMG=$(realpath -m "$2")
SERIAL="${3:-${ADB_SERIAL:-}}"
REMOTE_TMP_DIR="${REMOTE_TMP_DIR:-/data/local/tmp/zl1-halium-stage}"

for f in "$ROOTFS_IMG" "$SYSTEM_IMG"; do
  [[ -f "$f" ]] || { echo "Missing image: $f" >&2; exit 1; }
done

pick_serial() {
  mapfile -t rows < <(adb devices -l | awk 'NR>1 && $2=="device" {print $0}')
  local matches=() row serial dev model
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
    echo "Pass serial explicitly: $0 rootfs.img system.img <serial>" >&2
    exit 1
  fi
}

[[ -n "$SERIAL" ]] || pick_serial
adb_s() { adb -s "$SERIAL" "$@"; }
remote_sh() { adb_s shell "$@" | tr -d '\r'; }
remote_su() {
  adb_s shell su -c sh <<EOF | tr -d '\r'
$1
EOF
}

require_cmd() {
  command -v "$1" >/dev/null || { echo "Missing required command: $1" >&2; exit 1; }
}
for cmd in adb sha256sum stat awk; do require_cmd "$cmd"; done

printf 'Mode: stage Halium userdata images over ADB\n'
printf 'Target serial: %s\n' "$SERIAL"
printf 'Rootfs image: %s\n' "$ROOTFS_IMG"
printf 'Android system image: %s\n' "$SYSTEM_IMG"
printf 'Remote targets: /data/rootfs.img and /data/system.img\n'
printf 'Remote temp dir: %s\n' "$REMOTE_TMP_DIR"
printf 'This writes regular files on userdata only. It does not write block devices or flash anything.\n'
read -r -p 'Type HALIUM_STAGE to continue: ' ans
[[ "$ans" == "HALIUM_STAGE" ]] || { echo "Cancelled"; exit 1; }

rootfs_size=$(stat -c '%s' "$ROOTFS_IMG")
system_size=$(stat -c '%s' "$SYSTEM_IMG")
required=$((rootfs_size + system_size + 1073741824))
df_out=$(remote_sh "df -k /data 2>/dev/null || true")
free_kb=$(awk 'NR==2 {print $4}' <<<"$df_out")
if [[ ! "$free_kb" =~ ^[0-9]+$ ]]; then
  echo "Could not determine free space on /data" >&2
  echo "$df_out" >&2
  exit 1
fi
free_bytes=$((free_kb * 1024))
printf 'Free on /data: %s bytes\n' "$free_bytes"
printf 'Required with 1GiB margin: %s bytes\n' "$required"
if (( free_bytes < required )); then
  echo "Not enough free space on /data" >&2
  exit 1
fi

existing=$(remote_su "for f in /data/rootfs.img /data/system.img /data/ubuntu.img /data/android-rootfs.img; do [ -e \"\$f\" ] && echo \"\$f\"; done; true")
if [[ -n "$existing" && "${FORCE:-0}" != "1" ]]; then
  echo "Existing Halium image files found on device:" >&2
  echo "$existing" >&2
  echo "Set FORCE=1 to overwrite /data/rootfs.img and /data/system.img." >&2
  exit 1
fi

remote_su "rm -rf '$REMOTE_TMP_DIR'" >/dev/null || true
remote_sh "mkdir -p '$REMOTE_TMP_DIR'"

cleanup_tmp() {
  remote_su "rm -f '$REMOTE_TMP_DIR'/*.partial 2>/dev/null || true; rmdir '$REMOTE_TMP_DIR' 2>/dev/null || true" >/dev/null 2>&1 || true
}
trap cleanup_tmp EXIT

stage_one() {
  local local_img=$1
  local final_name=$2
  local remote_final="/data/$final_name"
  local remote_tmp="$REMOTE_TMP_DIR/$final_name.partial"
  local size sha remote_size remote_sha

  size=$(stat -c '%s' "$local_img")
  sha=$(sha256sum "$local_img" | awk '{print $1}')

  printf '\n== staging %s ==\n' "$final_name"
  printf 'local size: %s\n' "$size"
  printf 'local sha256: %s\n' "$sha"

  remote_su "rm -f '$remote_tmp' '$remote_final'" >/dev/null || true
  adb_s push "$local_img" "$remote_tmp"

  remote_size=$(remote_sh "stat -c '%s' '$remote_tmp' 2>/dev/null || wc -c < '$remote_tmp' 2>/dev/null || true")
  if [[ "$remote_size" != "$size" ]]; then
    echo "FAIL $final_name: temp size expected $size, got $remote_size" >&2
    exit 1
  fi

  remote_su "mv '$remote_tmp' '$remote_final'; chmod 0644 '$remote_final'; restorecon '$remote_final' 2>/dev/null || true; sync '$remote_final' 2>/dev/null || sync" >/dev/null

  remote_size=$(remote_su "stat -c '%s' '$remote_final' 2>/dev/null || wc -c < '$remote_final' 2>/dev/null || true")
  if [[ "$remote_size" != "$size" ]]; then
    echo "FAIL $final_name: final size expected $size, got $remote_size" >&2
    exit 1
  fi

  remote_sha_line=$(remote_su "sha256sum '$remote_final' 2>/dev/null || true")
  remote_sha=$(awk '{print $1}' <<<"$remote_sha_line")
  if [[ "$remote_sha" != "$sha" ]]; then
    echo "FAIL $final_name: sha256 expected $sha, got $remote_sha" >&2
    exit 1
  fi

  printf 'remote target: %s\n' "$remote_final"
  printf 'remote sha256 verified: %s\n' "$remote_sha"
}

stage_one "$ROOTFS_IMG" rootfs.img
stage_one "$SYSTEM_IMG" system.img

cleanup_tmp

printf '\n== final device files ==\n'
remote_su "ls -l /data/rootfs.img /data/system.img; sha256sum /data/rootfs.img /data/system.img"

printf '\nDone. Device userdata now has /data/rootfs.img and /data/system.img for Halium initramfs discovery.\n'
