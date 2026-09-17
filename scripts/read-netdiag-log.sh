#!/usr/bin/env bash
# Pull /data/zl1-netdiag.log from the device (TWRP) and summarise it.
#
# The interesting part is the last ~60 seconds before rndis0 stops transmitting, so this
# prints the transition rather than the whole file.
#
# Usage: read-netdiag-log.sh

set -euo pipefail
SER="33e80afe"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="/mnt/data/zl1-backups/netdiag/${STAMP}"
mkdir -p "$OUT"

adb devices 2>/dev/null | awk -v s="$SER" '$1==s{found=1} END{exit found?0:1}' \
  || { echo "target $SER not visible in adb (need TWRP)" >&2; exit 1; }

adb -s "$SER" shell "ls -l /data/zl1-netdiag.log" | tr -d '\r'
adb -s "$SER" exec-out 'cat /data/zl1-netdiag.log' > "$OUT/zl1-netdiag.log"
echo "saved $OUT/zl1-netdiag.log ($(wc -c < "$OUT/zl1-netdiag.log") bytes, $(wc -l < "$OUT/zl1-netdiag.log") lines)"

echo
echo "=== how many samples, and the last one's uptime ==="
grep -c '^===== uptime' "$OUT/zl1-netdiag.log" || true
grep '^===== uptime' "$OUT/zl1-netdiag.log" | tail -1

echo
echo "=== where host-ping flipped ==="
grep -n 'host-ping' "$OUT/zl1-netdiag.log" | awk '!seen[$2]++ {print}' | head -20

echo
echo "=== last sample ==="
awk '/^===== uptime/{n=NR} END{print n}' "$OUT/zl1-netdiag.log" | xargs -I{} tail -n +{} "$OUT/zl1-netdiag.log"
