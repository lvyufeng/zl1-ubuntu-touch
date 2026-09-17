#!/usr/bin/env bash
# Pull the device-side v63 monitor log (and friends) with the device in TWRP.
#
# The monitor appends to /userdata/zl1-v63-monitor.log, which is on the
# persistent partition, so it survives a boot that goes wrong. That makes it the
# only record of what a failed boot did — read it before reflashing anything.
#
# Read-only. Usage: collect-v63-monitor-log.sh

set -euo pipefail
SER="33e80afe"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="/mnt/data/zl1-backups/monitor-logs/${STAMP}"
mkdir -p "$OUT"

adb devices 2>/dev/null | awk -v s="$SER" '$1==s{found=1} END{exit found?0:1}' \
  || { echo "target $SER not visible in adb" >&2; exit 1; }

for f in /data/zl1-v63-monitor.log /data/rootfs-head.bin; do
  base="$(basename "$f")"
  echo "--- $base"
  adb -s "$SER" shell "ls -l $f 2>/dev/null" | tr -d '\r'
done

adb -s "$SER" exec-out 'cat /data/zl1-v63-monitor.log' > "$OUT/zl1-v63-monitor.log"
ls -l "$OUT/zl1-v63-monitor.log"
sha256sum "$OUT/zl1-v63-monitor.log"
grep -c . "$OUT/zl1-v63-monitor.log" || true
echo "saved: $OUT/zl1-v63-monitor.log"
echo "--- last 5 lines ---"
tail -5 "$OUT/zl1-v63-monitor.log"
