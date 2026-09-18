#!/usr/bin/env bash
# One power-cycle into TWRP: redeploy the recorder, capture the netfilter state across
# the link break, and get the log back.
#
# Why: the link dies 40-60 s into every boot and the packets that vanish leave no trace
# on any netdev counter, which means they are dropped before the device queue —
# netfilter, or a policy-routing rule. docs/ubuntu-touch/31-ruled-out-and-what-to-read-next.md
# narrows it to Android's netd, which shares the network namespace and starts at exactly
# that time. Four commands decide it, and netwatch now takes them ten times across the
# break.
#
# This script does NOT flash anything. Nothing about the boot image is implicated.
#
# Steps:
#   1. deploy netwatch in record-only mode (no heals, so nothing disturbs the measurement)
#   2. make sure no recovery marker is set (that feature rebooted the device 5 times
#      yesterday before I understood it)
#   3. test whether writing boot-recovery into misc actually works, because if it does the
#      device can come back to TWRP by itself and this needs only one button press
#   4. boot UT, let it run long enough to capture the break
#   5. read the netwatch log and print the netfilter snapshots
#
# Usage: run-netsnap-cycle.sh [WAIT_TWRP_SECONDS]

set -uo pipefail
ROOT=/mnt/data/zl1-bb10
SER="33e80afe"
WAIT_TWRP="${1:-28800}"
RUN_SECONDS="${RUN_SECONDS:-420}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$ROOT/netsnap-cycle-${STAMP}.log"
log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }

in_recovery() { [[ "$(adb devices 2>/dev/null | awk -v s="$SER" '$1==s{print $2}')" == "recovery" ]]; }
has_gadget()  { lsusb -d 18d1:d001 >/dev/null 2>&1; }
wait_for() { local d=$(( SECONDS + $1 )); while (( SECONDS < d )); do "$2" && return 0; sleep 5; done; return 1; }

log "=== netsnap cycle start; log $LOG ==="
log "waiting for TWRP (on the phone: hold Power 15-20 s, then Volume Up + Power)"
wait_for "$WAIT_TWRP" in_recovery || { log "timed out waiting for TWRP"; exit 1; }
log "TWRP up"

log "=== 1. deploy the recorder (record-only: no heals, so nothing disturbs the sample) ==="
NETWATCH_NOHEAL=1 "$ROOT/scripts/install-netwatch-service.sh" --yes >>"$LOG" 2>&1 \
  || { log "install failed"; exit 1; }
log "installed"

log "=== 2. clear any recovery marker ==="
adb -s "$SER" shell 'rm -f /data/zl1-netwatch-reboot-recovery; echo cleared' | tr -d '\r'
adb -s "$SER" shell 'rm -f /data/zl1-netwatch.log; echo "netwatch log cleared"' | tr -d '\r'

log "=== 3. does the misc write actually work? ==="
MISC="$(adb -s "$SER" shell 'readlink -f /dev/block/bootdevice/by-name/misc' | tr -d '\r')"
log "misc block: $MISC"
SAVED=""
if [[ -n "$MISC" && "$MISC" == /dev/block/* ]]; then
  # Preserve whatever is there so the test cannot corrupt anything.
  adb -s "$SER" shell "dd if=$MISC of=/tmp/misc.bak bs=4096 count=256 2>/dev/null; echo saved" | tr -d '\r'
  adb -s "$SER" shell "printf 'boot-recovery' > $MISC; sync; dd if=$MISC bs=1 count=16 2>/dev/null | tr -d '\\000'; echo" | tr -d '\r'
  READBACK="$(adb -s "$SER" shell "dd if=$MISC bs=1 count=16 2>/dev/null" | tr -d '\000\r')"
  log "read back: [$READBACK]"
  if [[ "$READBACK" == *boot-recovery* ]]; then
    log "misc write WORKS — the device can return itself to recovery, only one press needed"
    adb -s "$SER" shell "dd if=/tmp/misc.bak of=$MISC bs=4096 count=256 2>/dev/null; sync; echo restored" | tr -d '\r'
    log "restored misc from the backup taken above"
    adb -s "$SER" shell "echo $RUN_SECONDS > /data/zl1-netwatch-reboot-recovery; cat /data/zl1-netwatch-reboot-recovery" | tr -d '\r'
    AUTO_RETURN=yes
  else
    log "misc write does NOT stick — the device will need a manual power-cycle afterwards"
    AUTO_RETURN=no
  fi
else
  log "could not resolve the misc block; skipping the test"
  AUTO_RETURN=no
fi

log "=== 4. boot UT and let it run for ${RUN_SECONDS}s ==="
adb -s "$SER" shell 'reboot'
wait_for 420 has_gadget || log "warning: no RNDIS gadget appeared"
log "device booted; waiting ${RUN_SECONDS}s for the break to be captured"
sleep "$RUN_SECONDS"

if [[ "${AUTO_RETURN:-no}" == yes ]]; then
  log "waiting for the device to return to TWRP by itself"
  wait_for 600 in_recovery && log "it came back on its own" || log "it did not come back; a power-cycle is needed"
else
  log "a power-cycle is needed to read the log: hold Power 15-20 s, then Volume Up + Power"
  wait_for "$WAIT_TWRP" in_recovery || { log "giving up"; exit 1; }
fi

log "=== 5. read the log ==="
OUT="$ROOT/tmp-netsnap-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT"
adb -s "$SER" exec-out 'cat /data/zl1-netwatch.log' > "$OUT/zl1-netwatch.log" 2>/dev/null
log "log: $OUT/zl1-netwatch.log ($(wc -c < "$OUT/zl1-netwatch.log") bytes)"
echo "$OUT" > /tmp/netsnap-latest

log "=== the netfilter snapshots, in time order ==="
grep -E '^===== (netsnap|uptime)|host reachable at this snapshot|^--- ip rule|^--- route get|^[0-9]+: |Network is unreachable|^blackhole|^unreachable' "$OUT/zl1-netwatch.log" \
  | head -80 | tee -a "$LOG"

log "cycle done; full log at $OUT/zl1-netwatch.log"
