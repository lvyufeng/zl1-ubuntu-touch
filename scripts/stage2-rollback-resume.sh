#!/usr/bin/env bash
# Stage 2.5, second half: put the stock boot.img back once a human has reached fastboot.
#
# This exists because the drill's own "wait for a human" window was 30 minutes, and the
# device is deliberately in a state where only a key press can help. When that window
# expires the drill exits — correctly, and leaving the device exactly where it was — but
# then nothing is watching for the key press any more. This waits for as long as it takes.
#
# The state this resumes from is the drill's step 2: the known-bad image
# halium-boot-zl1-v67-from-v63-lxc-masked.img (cfce435a…) is in the boot partition and
# confirmed not to boot. Step 3 is `stage2-rollback-boot.sh`, which re-verifies the stock
# image hash before writing it. Nothing here flashes anything else.
#
# Usage: stage2-rollback-resume.sh --yes [SECONDS]     (default: 6 hours)

set -uo pipefail

SER="33e80afe"
ROOT=/mnt/data/zl1-bb10
WAIT="${2:-21600}"
STOCK="/mnt/data/zl1-backups/2026-06-07-adb-root-staged/boot.img"
STOCK_SHA="a06d6508499ee37a03effea1e6bec1d04f23843fd44d198a49fb3e07cb5778ef"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$ROOT/stage2-rollback-resume-${STAMP}.log"
log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }
die() { log "FAIL: $*"; exit 1; }

[[ "${1:-}" == "--yes" ]] || die "refusing without --yes"

in_fastboot() { timeout 5 fastboot devices 2>/dev/null | awk -v s="$SER" '$1==s{f=1} END{exit f?0:1}'; }
in_recovery() { adb devices 2>/dev/null | awk -v s="$SER" '$1==s && $2=="recovery"{f=1} END{exit f?0:1}'; }
is_halium()   { lsusb -d 18d1:d001 >/dev/null 2>&1; }
in_edl()      { lsusb | grep -q '05c6:9008'; }

[[ -f "$STOCK" ]] || die "stock image missing: $STOCK"
got="$(sha256sum "$STOCK" | awk '{print $1}')"
[[ "$got" == "$STOCK_SHA" ]] || die "stock image hash mismatch: $got"
log "stock boot.img OK  $STOCK_SHA"

log "waiting up to ${WAIT}s for $SER to reach fastboot or TWRP"
log "  (fastboot = power off, hold Volume Down + Power;  TWRP = Volume Up + Power)"
deadline=$(( SECONDS + WAIT ))
reached=""
while (( SECONDS < deadline )); do
  if in_fastboot; then reached=fastboot; break; fi
  if in_recovery; then reached=recovery; break; fi
  # If it booted Ubuntu Touch instead, that is also a working device — but the drill
  # cannot be completed from there, so say so and keep waiting.
  if is_halium; then
    log "note: the device is up as a Halium image (RNDIS present), not Android and not"
    log "      fastboot. It is not stuck; if it is deliberately up, stop this script."
  fi
  if in_edl; then log "note: device is in EDL (05c6:9008) — do not use QFIL"; fi
  sleep 10
done
[[ -n "$reached" ]] || die "timed out after ${WAIT}s; the device is still on the bad image"
log "$SER reached $reached"

if [[ "$reached" == "recovery" ]]; then
  log "in TWRP; switching to fastboot"
  adb -s "$SER" reboot bootloader >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do in_fastboot && break; sleep 5; done
  in_fastboot || die "TWRP was up but it did not reach fastboot"
  log "fastboot is up"
fi

log "=== flashing the stock boot.img back ==="
"$ROOT/scripts/stage2-rollback-boot.sh" --yes >>"$LOG" 2>&1 || die "rollback flash failed"
log "rollback flashed; waiting for Android"

deadline=$(( SECONDS + 420 ))
while (( SECONDS < deadline )); do
  if adb devices 2>/dev/null | awk -v s="$SER" '$1==s && $2=="device"{f=1} END{exit f?0:1}'; then
    fp="$(adb -s "$SER" shell getprop ro.build.fingerprint 2>/dev/null | tr -d '\r')"
    log "device is back on stock Android: $fp"
    log "=== STAGE 2.5 PASSED ==="
    log "log: $LOG"
    exit 0
  fi
  if is_halium; then log "RNDIS gadget instead of adb — that is a Halium image, not stock"; fi
  sleep 5
done

log "=== INCONCLUSIVE ==="
log "the boot partition holds the stock image again (verified), so this is not a stuck"
log "bootloader, but adb did not appear within 420 s. Look at the screen and try a fresh"
log "power-on before concluding anything."
log "log: $LOG"
exit 1
