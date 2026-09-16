#!/usr/bin/env bash
# Stage 0 supplement — image the `userdata` partition from TWRP.
#
# The 2026-06-07 backup set covers 31 partitions but deliberately skipped
# `userdata` and `cache`. `userdata` is the one partition every earlier
# experiment wrote to, so without an image of it there is no way to undo a
# botched rootfs install. This script closes that gap.
#
# It only READS the device. Nothing is written to any partition.
#
# Why chunked: `adb exec-out cat /dev/block/sda10` was tried twice and both
# times died part-way (343 MB and 359 MB into the 8 GB file) while adb still
# reported exit 0 — TWRP's adbd drops long-lived streams. Reading the partition
# in 512 MiB windows with a resume-safe loop makes a dropped connection cost
# one chunk instead of the whole copy.
#
# `cache` is not re-copied: it is a single 256 MiB partition and the existing
# $OUT/cache.img is that raw image. The script verifies it against the device
# instead.
#
# Usage: stage0-backup-userdata-cache.sh --yes [--out DIR]

set -euo pipefail

SER="33e80afe"
OTHER_SER="4a2fe00b"

OUT="/mnt/data/zl1-backups/2026-09-16-recovery-supplement"
CHUNK_MIB=512
EXPECT_UD_BYTES=26144878592   # /dev/block/sda10 = 51064216 sectors x 512
EXPECT_CACHE_BYTES=268435456  # /dev/block/sda3  = 524288 sectors x 512

[[ "${1:-}" == "--yes" ]] && shift || { echo "refusing without --yes" >&2; exit 2; }
if [[ "${1:-}" == "--out" ]]; then OUT="$2"; fi

BLK_UD="/dev/block/bootdevice/by-name/userdata"
BLK_CACHE="/dev/block/bootdevice/by-name/cache"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "FAIL: $*"; exit 1; }

mkdir -p "$OUT"
LOG="$OUT/stage0-backup.log"

log "=== Stage 0 supplement: userdata image ==="
log "out dir: $OUT"

# ------------------------------------------------------------ target check --
if adb devices 2>/dev/null | awk -v s="$OTHER_SER" '$1==s{found=1} END{exit found?0:1}'; then
  log "note: unrelated device $OTHER_SER (Xiaomi) is on the bus — ignoring it"
fi
adb devices 2>/dev/null | awk -v s="$SER" '$1==s{found=1} END{exit found?0:1}' \
  || die "target $SER not visible in adb; refusing to act on any other device"
state="$(adb -s "$SER" get-state 2>/dev/null | tr -d '\r')"
log "target $SER present, adb state=$state"

# -------------------------------------------------------- resolve the block --
dev_size() {
  adb -s "$SER" shell "cat /sys/class/block/\$(basename \$(readlink -f $1))/size" | tr -d '\r'
}
ud_bytes=$(( $(dev_size "$BLK_UD") * 512 ))
cache_bytes=$(( $(dev_size "$BLK_CACHE") * 512 ))
log "userdata = $ud_bytes bytes, cache = $cache_bytes bytes"
[[ "$ud_bytes" == "$EXPECT_UD_BYTES" ]]       || die "userdata size changed: $ud_bytes != $EXPECT_UD_BYTES"
[[ "$cache_bytes" == "$EXPECT_CACHE_BYTES" ]] || die "cache size changed: $cache_bytes != $EXPECT_CACHE_BYTES"

# ------------------------------------------------------------- raw image --
# dd with bs=1MiB so skip/count land on whole MiB. toybox dd on this TWRP does
# not accept bs=1M (it reads the suffix as an illegal number), hence 1048576.
copy_partition() {
  local blk="$1" out="$2" total="$3" label="$4"
  local chunk_bytes=$(( CHUNK_MIB * 1048576 ))
  local chunks=$(( (total + chunk_bytes - 1) / chunk_bytes ))
  local i have expected want_mib attempt

  log "--- $label: $chunks chunks of ${CHUNK_MIB}MiB -> $out"
  : > "$out"
  for (( i = 0; i < chunks; i++ )); do
    expected=$(( (i + 1) * chunk_bytes ))
    (( expected > total )) && expected=$total
    want_mib=$(( ${CHUNK_MIB} ))
    if (( (i + 1) * chunk_bytes > total )); then
      want_mib=$(( (total - i * chunk_bytes) / 1048576 ))
    fi

    for attempt in 1 2 3 4 5; do
      adb -s "$SER" exec-out "dd if=$blk bs=1048576 skip=$(( i * CHUNK_MIB )) count=$want_mib 2>/dev/null" >> "$out" || true
      have="$(stat -c%s "$out")"
      [[ "$have" == "$expected" ]] && break
      log "  chunk $((i+1))/$chunks attempt $attempt: got $have, want $expected — retrying"
      truncate -s $(( i * chunk_bytes )) "$out"
      sleep 2
    done
    [[ "$(stat -c%s "$out")" == "$expected" ]] \
      || die "$label stalled at chunk $((i+1))/$chunks ($(stat -c%s "$out") bytes)"
    if (( (i + 1) % 8 == 0 || i + 1 == chunks )); then
      log "  $((i+1))/$chunks chunks, $(stat -c%s "$out") bytes"
    fi
  done
  [[ "$(stat -c%s "$out")" == "$total" ]] || die "$label size $(stat -c%s "$out") != $total"
  log "$label image complete: $(stat -c%s "$out") bytes"
}

copy_partition "$BLK_UD" "$OUT/userdata.img" "$ud_bytes" "userdata"

# ------------------------------------------------------- cross-check device --
# Hash the partition on the device itself so a silently short read cannot pass.
log "--- device-side hash (ground truth) ---"
ud_dev="$(adb -s "$SER" shell "sha256sum $BLK_UD" | awk '{print $1}' | tr -d '\r')"
log "device userdata sha256 $ud_dev"
ud_host="$(sha256sum "$OUT/userdata.img" | awk '{print $1}')"
log "host   userdata sha256 $ud_host"

log "--- cache: verify the existing raw image against the device ---"
cache_dev="$(adb -s "$SER" shell "sha256sum $BLK_CACHE" | awk '{print $1}' | tr -d '\r')"
cache_host="$(sha256sum "$OUT/cache.img" | awk '{print $1}')"
log "device cache sha256 $cache_dev"
log "host   cache sha256 $cache_host"

log "=== result ==="
rc=0
if [[ "$ud_dev" == "$ud_host" ]]; then log "userdata MATCH"; else log "userdata MISMATCH"; rc=1; fi
if [[ "$cache_dev" == "$cache_host" ]]; then log "cache MATCH"; else log "cache MISMATCH"; rc=1; fi
exit "$rc"
