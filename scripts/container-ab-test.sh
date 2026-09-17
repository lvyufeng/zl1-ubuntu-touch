#!/usr/bin/env bash
# A/B test: is the Android container what kills the link?
#
# Evidence pointing at it (docs/ubuntu-touch/30-outbound-drops-before-the-queue.md):
#
#   * the LXC config shares the network namespace (`lxc.namespace.keep = net user`), so
#     Android's network configuration acts on the stack rndis0 lives in
#   * the kernel log shows netd coming up (/dev/socket/fwmarkd, x_tables messages)
#   * the break lands 40-60 s into every boot, which is when the container starts
#   * the one boot where the container could not start — no /data/system.img — kept the
#     link usable for 8+ minutes
#
# That last one is the correlation I dismissed too quickly earlier. This makes it a
# controlled experiment: the container's absence is the only variable, and it is switched
# by renaming a file rather than by changing any image.
#
# Two boots, one button press each, and the two measurements are directly comparable.
#
# Usage: container-ab-test.sh [--yes]        (run it with the device in TWRP)
#
#   phase A : rename /data/system.img away, boot, measure, and report
#   phase B : put it back, boot, measure, and report
#
# It stops between phases so the result can be read before spending the second boot.

set -uo pipefail
ROOT=/mnt/data/zl1-bb10
SER="33e80afe"
SYSIMG=/data/system.img
HIDDEN=/data/system.img.abtest
MEASURE_MIN="${MEASURE_MIN:-10}"

[[ "${1:-}" == "--yes" ]] || { echo "refusing without --yes" >&2; exit 2; }

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$ROOT/container-ab-${STAMP}.log"
log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }

in_recovery() { [[ "$(adb devices 2>/dev/null | awk -v s="$SER" '$1==s{print $2}')" == "recovery" ]]; }
has_gadget()  { lsusb -d 18d1:d001 >/dev/null 2>&1; }
wait_for() { local d=$(( SECONDS + $1 )); while (( SECONDS < d )); do "$2" && return 0; sleep 5; done; return 1; }

state_of_systemimg() {
  adb -s "$SER" shell "if [ -f $SYSIMG ]; then echo present; elif [ -f $HIDDEN ]; then echo hidden; else echo missing; fi" | tr -d '\r'
}

log "=== container A/B test; log $LOG ==="
in_recovery || { log "device is not in TWRP (need adb recovery). Volume Up + Power."; exit 1; }

case "$(state_of_systemimg)" in
  present) log "phase A: /data/system.img is present — hiding it" ;;
  hidden)  log "phase A already applied (/data/system.img.abtest exists) — skipping the rename" ;;
  *)       log "neither $SYSIMG nor $HIDDEN exists — cannot run this test"; exit 1 ;;
esac

# ---------------------------------------------------------------- phase A -----
if [[ "$(state_of_systemimg)" == "present" ]]; then
  adb -s "$SER" shell "mv $SYSIMG $HIDDEN && sync && ls -l $HIDDEN" | tr -d '\r'
fi
log "system.img state now: $(state_of_systemimg)"
log "booting WITHOUT the container — expect the link to stay usable if the hypothesis holds"

adb -s "$SER" shell 'reboot'
wait_for 420 has_gadget || { log "no gadget after the boot; stopping"; exit 1; }
log "device is up; measuring for ${MEASURE_MIN} minutes"
"$ROOT/scripts/measure-link-stability.sh" "$MEASURE_MIN" "$ROOT/tmp-ab-no-container.csv" 2>&1 | tee -a "$LOG"

log "phase A done. Bring the device back to TWRP and re-run to do phase B:"
log "  the device will be in UT; power-cycle and hold Volume Up + Power"
log "  then:  $0 --yes"
log "phase A csv: $ROOT/tmp-ab-no-container.csv"

# If we are already back in TWRP (unlikely in one run), continue into phase B.
if in_recovery; then
  log "already in TWRP — continuing to phase B"
  adb -s "$SER" shell "mv $HIDDEN $SYSIMG && sync && ls -l $SYSIMG" | tr -d '\r'
  log "system.img state now: $(state_of_systemimg)"
  log "booting WITH the container — expect the link to die at ~50 s"
  adb -s "$SER" shell 'reboot'
  wait_for 420 has_gadget || { log "no gadget after the boot; stopping"; exit 1; }
  "$ROOT/scripts/measure-link-stability.sh" "$MEASURE_MIN" "$ROOT/tmp-ab-with-container.csv" 2>&1 | tee -a "$LOG"
  log "phase B csv: $ROOT/tmp-ab-with-container.csv"
  log "compare the two csv summaries — that is the experiment"
else
  log "not in TWRP; phase B needs a power-cycle + Volume Up + Power, then re-running this"
fi
