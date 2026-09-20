#!/usr/bin/env bash
# Stage 2.4 + 2.5 in one run, once the device is in TWRP.
#
# Stage 2.4 wants three consecutive cold boots with the same result. Stage 2.5 wants a
# deliberately bad image flashed, confirmed failed, then the stock boot restored and the
# device confirmed back. Both are currently blocked only on the device being reachable.
#
# The steps below are ordered so that the riskiest one comes last. A cold boot is
# reversible (the boot partition is untouched); the rollback drill writes the boot
# partition twice on purpose. If anything goes wrong early, nothing has been risked.
#
#   1. install the integrity-checked watchdog, record-only, and verify it on the device
#   2. cold boot #2 — count it
#   3. cold boot #3 — count it
#   4. cold boot #4 — count it
#   5. rollback drill: bad image -> confirm failed -> stock boot.img -> confirm back
#
# This script never flashes anything until step 5, and step 5 goes through
# flash-boot-image.sh and stage2-rollback-boot.sh, both of which verify hashes first.
#
# Usage: run-stage24-and-25.sh [--skip-drill]
#   Run it with the device in TWRP. It waits for TWRP at the start.

set -uo pipefail
ROOT=/mnt/data/zl1-bb10
SER="33e80afe"
WAIT_TWRP=7200
SKIP_DRILL=0
[[ "${1:-}" == "--skip-drill" ]] && SKIP_DRILL=1

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$ROOT/stage24-25-${STAMP}.log"
log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }
in_recovery() { [[ "$(adb devices 2>/dev/null | awk -v s="$SER" '$1==s{print $2}')" == "recovery" ]]; }
has_gadget()  { lsusb -d 18d1:d001 >/dev/null 2>&1; }
in_edl()      { lsusb | grep -q '05c6:9008'; }
wait_for()    { local d=$(( SECONDS + $1 )); while (( SECONDS < d )); do "$2" && return 0; sleep 5; done; return 1; }

# Wait for SSH, not for the gadget. The link appearing is not the same as the system
# being up — on 2026-09-19 a check ran 20 s after RNDIS appeared and reported three
# failures against a device that was fine.
ssh_ready() {
    timeout 12 ssh -o BatchMode=yes -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 root@10.15.19.82 'true' 2>/dev/null
}

cold_boot() {  # cold_boot <n> <note>
    local n="$1" note="$2"
    log "=== cold boot #$n ==="
    adb -s "$SER" shell 'rm -f /data/zl1-netwatch.log; sync; reboot' >/dev/null 2>&1 || { log "reboot failed"; return 1; }
    if ! wait_for 300 ssh_ready; then
        log "cold boot #$n: SSH never came up within 300 s"
        if in_edl; then log "  and the device is in EDL"; fi
        return 1
    fi
    log "cold boot #$n: SSH is up"
    "$ROOT/scripts/verify-over-ssh.sh" --note "$note" >>"$LOG" 2>&1
    local rc=$?
    log "cold boot #$n: verify rc=$rc"
    return $rc
}

log "=== Stage 2.4 + 2.5 run; log $LOG ==="
log "waiting for TWRP"
wait_for "$WAIT_TWRP" in_recovery || { log "timed out waiting for TWRP"; exit 1; }
log "TWRP up"

# ---------------------------------------------------------------- step 1 ------
log "=== 1. install the watchdog (integrity-checked, record-only, verified on device) ==="
if ! NETWATCH_NOHEAL=1 "$ROOT/scripts/install-netwatch-service.sh" --yes --noheal >>"$LOG" 2>&1; then
  log "install refused or failed — see $LOG"; exit 1
fi
chk() { adb -s "$SER" shell "$1" | tr -d '\r'; }
[[ -n "$(chk 'ls /data/zl1-netwatch-noheal 2>/dev/null')" ]] || { log "FATAL: record-only marker missing"; exit 1; }
[[ "$(chk 'grep -c "^heal_rebind_function()" /data/system-data/etc/systemd/system/zl1-netwatch.sh')" = "1" ]] \
  || { log "FATAL: installed script missing functions"; exit 1; }
[[ "$(chk 'grep -c "^POLICY_TABLES=" /data/system-data/etc/systemd/system/zl1-netwatch.sh')" = "1" ]] \
  || { log "FATAL: installed script missing the three-table fix"; exit 1; }
log "installed and verified on the device"

# ------------------------------------------------------- steps 2, 3, 4 --------
ok=0
for n in 2 3 4; do
  if cold_boot "$n" "cold boot #$n (stage 2.4)"; then
    ok=$((ok + 1))
    log "cold boot #$n: PASSED"
  else
    log "cold boot #$n: FAILED — stopping the 2.4 sequence here rather than continuing,"
    log "  because 2.4 asks for CONSECUTIVE boots and a failure breaks the run"
    break
  fi
done
log "=== Stage 2.4: $ok of 3 new boots passed (trial #1 in the ledger was already counted) ==="

if (( ok < 3 )); then
  log "not all three passed; not starting the rollback drill on an unclear system"
  log "log: $LOG"
  exit 1
fi

# ---------------------------------------------------------------- step 5 ------
if (( SKIP_DRILL )); then
  log "=== Stage 2.5 skipped (--skip-drill) ==="
  log "log: $LOG"
  exit 0
fi

log "=== 5. rollback drill ==="
log "this writes the boot partition twice on purpose. If it is interrupted between the"
log "two, the device is left on the bad image and needs a manual power-cycle."
"$ROOT/scripts/stage2-rollback-drill.sh" --yes >>"$LOG" 2>&1
drill_rc=$?
log "drill rc=$drill_rc"
if (( drill_rc == 0 )); then
  log "=== Stage 2.5 PASSED ==="
else
  log "=== Stage 2.5 inconclusive or failed — read $LOG ==="
fi
log "log: $LOG"
exit "$drill_rc"
