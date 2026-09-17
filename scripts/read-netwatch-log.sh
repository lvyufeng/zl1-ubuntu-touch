#!/usr/bin/env bash
# Pull /data/zl1-netwatch.log from the device (TWRP) and summarise it.
#
# Prints the heal decisions and the stall evidence, which is what matters; the full
# sample stream is saved for later.

set -euo pipefail
SER="33e80afe"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="/mnt/data/zl1-backups/netwatch/${STAMP}"
mkdir -p "$OUT"

adb devices 2>/dev/null | awk -v s="$SER" '$1==s{found=1} END{exit found?0:1}' \
  || { echo "target $SER not visible in adb (need TWRP)" >&2; exit 1; }

adb -s "$SER" shell "ls -l /data/zl1-netwatch.log" | tr -d '\r'
adb -s "$SER" exec-out 'cat /data/zl1-netwatch.log' > "$OUT/zl1-netwatch.log"
echo "saved $OUT/zl1-netwatch.log ($(wc -c < "$OUT/zl1-netwatch.log") bytes, $(wc -l < "$OUT/zl1-netwatch.log") lines)"
echo

echo "=== samples: $(grep -c '^===== uptime' "$OUT/zl1-netwatch.log" || true)  last: $(grep '^===== uptime' "$OUT/zl1-netwatch.log" | tail -1)"
echo
echo "=== hardware snapshot (Phase 5 evidence) ==="
if grep -q '^===== hwcheck' "$OUT/zl1-netwatch.log"; then
  awk '/^===== hwcheck/{f=1} f' "$OUT/zl1-netwatch.log"
else
  echo "(none yet — the snapshot is taken 120s into a boot)"
fi
echo
echo "=== netwatch decisions ==="
grep -E 'netwatch start|STALL:|HEAL:|recovered on its own' "$OUT/zl1-netwatch.log" || echo "(none)"
echo
echo "=== host-ping transitions ==="
grep -E 'host-ping' "$OUT/zl1-netwatch.log" | awk '!seen[$2]++ {print NR": "$0}' | head -20
echo
echo "=== iface counters over time (rx_pkts tx_pkts) ==="
awk '/^--- iface ---/{getline; print NR": "$0}' "$OUT/zl1-netwatch.log" | awk '!seen[$2" "$3" "$4" "$5]++' | head -40
