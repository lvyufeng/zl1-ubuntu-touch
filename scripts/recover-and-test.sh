#!/usr/bin/env bash
# Recover the device after the bad boot image, then run the test that was intended.
#
# Why this exists: on 2026-09-17 every image produced by make-v63-boot-image.sh carried
# the wrong kernel load address (0x10008000 instead of 0x80008000), so the bootloader
# loaded the kernel somewhere it could not run, the boot failed, and the SoC fell back to
# EDL. The device has that image in its boot partition right now, so a plain power-cycle
# would land it straight back in EDL.
#
# The builder is fixed and all three derived images are rebuilt with verified headers. But
# the recovery is ordered so that the first thing flashed is the *original* known-good
# image — not one this repo built — so that "the device is healthy again" is established
# before any new image is tested.
#
# Sequence, all from one power-cycle into TWRP:
#   1. flash halium-boot-zl1-v63-usbd-disabled.img  (the unmodified known-good image)
#   2. boot it with the netwatch recorder running and a recovery fallback 30 minutes out
#   3. when the device returns itself to TWRP, pull the netwatch log
#   4. then, and only then, flash the rebuilt noreassert image and boot that
#   5. when it returns to TWRP again, pull the log and compare the two
#
# If step 4 lands the device in EDL, the log from step 3 still exists on disk and the
# rollback is the same file as step 1.
#
# Usage: recover-and-test.sh [WAIT_TWRP_SECONDS]

set -uo pipefail
ROOT=/mnt/data/zl1-bb10
SER="33e80afe"
CAND=/mnt/data/halium-zl1-candidates
KNOWN_GOOD="$CAND/halium-boot-zl1-v63-usbd-disabled.img"
FIX_IMG="$CAND/halium-boot-zl1-v63-noreassert.img"
WAIT_TWRP="${1:-28800}"
RECOVERY_AFTER=1800

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$ROOT/recover-and-test-${STAMP}.log"
log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }

in_recovery() { [[ "$(adb devices 2>/dev/null | awk -v s="$SER" '$1==s{print $2}')" == "recovery" ]]; }
in_edl()      { lsusb | grep -q '05c6:9008'; }
has_gadget()  { lsusb -d 18d1:d001 >/dev/null 2>&1; }

wait_for() {  # wait_for <seconds> <predicate>
  local deadline=$(( SECONDS + $1 ))
  while (( SECONDS < deadline )); do "$2" && return 0; sleep 10; done
  return 1
}

log "=== recover-and-test start; log $LOG ==="
log "the device's boot partition holds the image with the bad load address, so it needs"
log "a power-cycle and then TWRP. On the phone: hold Power 15-20 s, then Volume Up + Power."

if in_edl; then
  log "device is in EDL right now (05c6:9008) — power-cycle required, waiting"
fi
wait_for "$WAIT_TWRP" in_recovery || { log "timed out waiting for TWRP"; exit 1; }
log "TWRP is up"

# ---------------------------------------------------------------- step 1+2 --
log "=== 1. flash the known-good image and boot it ==="
NETWATCH_NOHEAL=1 "$ROOT/scripts/twrp-one-shot-setup.sh" "$RECOVERY_AFTER" 600 "$KNOWN_GOOD" \
  >>"$LOG" 2>&1 || { log "step 1 failed"; exit 1; }
log "step 1 issued; waiting for the device to come up"

if wait_for 420 has_gadget; then
  log "the known-good image came up (RNDIS present) — the device is healthy"
else
  log "the known-good image did NOT bring up RNDIS within 420 s"
  if in_edl; then
    log "and the device is in EDL — something other than the image is wrong; stopping"
  else
    log "no EDL either; check the device screen"
  fi
  exit 1
fi

# ---------------------------------------------------------------- step 3 -----
log "=== 3. wait for it to return itself to TWRP, then pull the netwatch log ==="
if wait_for $((RECOVERY_AFTER + 900)) in_recovery; then
  log "back in TWRP"
  "$ROOT/scripts/read-netwatch-log.sh" >>"$LOG" 2>&1 || log "log pull failed"
  cp -f "$(ls -td /mnt/data/zl1-backups/netwatch/*/ 2>/dev/null | head -1)zl1-netwatch.log" \
        "$ROOT/tmp-netwatch-known-good.log" 2>/dev/null && log "saved known-good log"
else
  log "device did not return to TWRP in time; stopping before flashing anything new"
  exit 1
fi

# ---------------------------------------------------------------- step 4 -----
log "=== 4. flash the rebuilt noreassert image ==="
log "it differs from the known-good image in exactly one initramfs file, and its header"
log "is now verified against the reference"
NETWATCH_NOHEAL=1 "$ROOT/scripts/twrp-one-shot-setup.sh" "$RECOVERY_AFTER" 600 "$FIX_IMG" \
  >>"$LOG" 2>&1 || { log "step 4 failed"; exit 1; }
log "step 4 issued; waiting for the device to come up"

if wait_for 420 has_gadget; then
  log "noreassert came up — measuring"
else
  log "noreassert did NOT bring up RNDIS within 420 s"
  in_edl && log "device is in EDL: the image is bad, roll back with stage2-rollback-boot.sh"
  exit 1
fi

log "=== 5. measure, then wait for it to return to TWRP ==="
"$ROOT/scripts/measure-link-stability.sh" 10 >>"$LOG" 2>&1 || true
if wait_for $((RECOVERY_AFTER + 900)) in_recovery; then
  "$ROOT/scripts/read-netwatch-log.sh" >>"$LOG" 2>&1 || true
  cp -f "$(ls -td /mnt/data/zl1-backups/netwatch/*/ 2>/dev/null | head -1)zl1-netwatch.log" \
        "$ROOT/tmp-netwatch-noreassert.log" 2>/dev/null && log "saved noreassert log"
fi

log "=== done; compare tmp-netwatch-known-good.log and tmp-netwatch-noreassert.log ==="
log "log: $LOG"
