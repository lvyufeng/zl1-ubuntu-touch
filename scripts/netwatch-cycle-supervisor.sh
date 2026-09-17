#!/usr/bin/env bash
# Drive repeated Ubuntu Touch boots unattended, and collect the statistics that decide
# whether the transmit-stall patch helps.
#
# Why this exists: the stall happens on roughly 1 boot in 4 (6 of 8 usable boots in the
# historical monitor log were fine), so "did the patch help?" is a question about a rate,
# not about one boot. Answering it needs many boots — far more than anyone will sit
# through. But the device can now return itself to TWRP:
#
#   * the netwatch service writes "boot-recovery" into misc after RECOVERY_AFTER seconds,
#     which is what Android's own `reboot recovery` does
#   * TWRP then answers adb, and `adb reboot` boots the system again
#
# so the whole cycle can run on its own. This script is the loop.
#
# Each cycle:
#   1. if the device is in TWRP, reboot it into the system
#   2. wait for the RNDIS gadget and the status page  -> a Stage 2.4 trial row
#   3. watch until it goes quiet or returns to TWRP
#   4. pull the netwatch log and record its verdict for that boot
#
# It never flashes anything. Flash the image you want to test first (or pass one here and
# it will be used for every cycle, since a flashed boot image persists).
#
# Usage: netwatch-cycle-supervisor.sh [CYCLES] [--image IMG]
#   CYCLES  how many boots to run (default 10)
#   --image flash this boot image once at the start, then leave it in place

set -uo pipefail

SER="33e80afe"
ROOT=/mnt/data/zl1-bb10
CYCLES=10
IMAGE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) IMAGE="$2"; shift 2 ;;
    ''|*[!0-9]*) echo "usage: $0 [CYCLES] [--image IMG]" >&2; exit 2 ;;
    *) CYCLES="$1"; shift ;;
  esac
done

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$ROOT/netwatch-cycles-${STAMP}.log"
OUT="/mnt/data/zl1-backups/netwatch-cycles/${STAMP}"
mkdir -p "$OUT"
log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }

dev_state()    { adb devices 2>/dev/null | awk -v s="$SER" '$1==s{print $2}'; }
have_adb()     { [[ -n "$(dev_state)" ]]; }
in_recovery()  { [[ "$(dev_state)" == "recovery" ]]; }
have_gadget()  { lsusb -d 18d1:d001 >/dev/null 2>&1; }
have_fastboot(){ timeout 5 fastboot devices 2>/dev/null | awk -v s="$SER" '$1==s{f=1} END{exit f?0:1}'; }
reachable()    { have_adb || have_fastboot; }

# Predicates are shell functions rather than `bash -c "..."` strings — the quoting for a
# nested awk inside a nested bash -c is exactly the kind of thing that works until the day
# it silently does not.
wait_for() {  # wait_for <seconds> <predicate-function>
  local secs="$1" pred="$2"
  local deadline=$(( SECONDS + secs ))
  while (( SECONDS < deadline )); do "$pred" && return 0; sleep 5; done
  return 1
}

if [[ -n "$IMAGE" ]]; then
  log "flashing $IMAGE once, before the cycles start"
  "$ROOT/scripts/flash-boot-image.sh" "$IMAGE" --yes >>"$LOG" 2>&1 \
    || { log "flash failed; aborting"; exit 1; }
  log "flash done"
fi

log "supervisor start: up to $CYCLES cycles; log $LOG; evidence $OUT"
log "the device must be reachable in adb (TWRP) or fastboot for a cycle to start"

for (( cycle = 1; cycle <= CYCLES; cycle++ )); do
  log "=== cycle $cycle/$CYCLES ==="

  # 1. get to a state where we can boot the system
  if have_fastboot; then
    log "in fastboot — rebooting"
    timeout 60 fastboot -s "$SER" reboot >>"$LOG" 2>&1 || true
  elif [[ "$(dev_state)" == "recovery" ]]; then
    log "in TWRP — rebooting into the system"
    adb -s "$SER" reboot >>"$LOG" 2>&1 || true
  elif [[ "$(dev_state)" == "device" ]]; then
    log "already booted into the system"
  else
    log "no adb and no fastboot for $SER — a human is needed (Volume Up + Power for TWRP)"
    log "waiting up to 60 minutes..."
    wait_for 3600 reachable \
      || { log "gave up waiting; stopping after $((cycle-1)) cycles"; break; }
    continue
  fi

  # 2. wait for the boot to become observable
  boot_t0=$SECONDS
  if ! wait_for 420 have_gadget; then
    log "cycle $cycle: no RNDIS gadget within 420s — this boot did not come up"
    printf '| %d | %s | NO GADGET | — | — | — | — |\n' "$cycle" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      >> "$OUT/trials.md"
    # Try to get back to recovery so the next cycle can run.
    if have_fastboot; then timeout 60 fastboot -s "$SER" reboot recovery >>"$LOG" 2>&1 || true; fi
    continue
  fi
  log "gadget up after $((SECONDS - boot_t0))s"

  # 3. verify via the same path the manual trials use, so the rows are comparable
  if "$ROOT/scripts/stage2-coldboot-trial.sh" --note "supervisor cycle $cycle" \
       --timeout 300 >>"$LOG" 2>&1; then
    log "cycle $cycle: boot verified"
  else
    log "cycle $cycle: boot came up but did not verify (see the trial row)"
  fi

  # 4. wait for the device to return itself to TWRP (netwatch writes boot-recovery)
  log "cycle $cycle: waiting for the device to return to recovery (up to 45 min)"
  if wait_for 2700 in_recovery; then
    log "cycle $cycle: back in TWRP — pulling the netwatch log"
    if "$ROOT/scripts/read-netwatch-log.sh" >>"$LOG" 2>&1; then
      latest="$(ls -td /mnt/data/zl1-backups/netwatch/*/ 2>/dev/null | head -1)"
      [[ -n "$latest" ]] && cp -f "$latest/zl1-netwatch.log" "$OUT/cycle-${cycle}-netwatch.log" 2>/dev/null
      verdict="$(grep -E 'STALL:|HEAL [AB]:' "$OUT/cycle-${cycle}-netwatch.log" 2>/dev/null | head -6 | tr '\n' '; ')"
      log "cycle $cycle: netwatch verdict: ${verdict:-no stall recorded}"
    fi
  else
    log "cycle $cycle: device did not return to recovery in time"
  fi
done

log "supervisor done after $CYCLES cycle(s)"
log "trials ledger: $ROOT/docs/ubuntu-touch/stage2-coldboot-trials.md"
log "stall counts across the run:"
grep -h 'STALL:' "$OUT"/cycle-*-netwatch.log 2>/dev/null | wc -l | xargs -I{} log "  total STALL lines: {}"
grep -h 'HEAL A:' "$OUT"/cycle-*-netwatch.log 2>/dev/null | wc -l | xargs -I{} log "  total heal-A: {}"
grep -h 'HEAL B:' "$OUT"/cycle-*-netwatch.log 2>/dev/null | wc -l | xargs -I{} log "  total heal-B: {}"
