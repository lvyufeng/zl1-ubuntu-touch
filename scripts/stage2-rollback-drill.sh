#!/usr/bin/env bash
# Stage 2.5 — rollback drill.
#
# The plan asks for this before it will call the route "safe": deliberately flash a boot
# image that does not work, confirm the device does not come up, then restore the stock
# boot.img and confirm the device is back. Until this has been done once on real
# hardware, "there is a verified rollback" is a claim about a file, not about the device.
#
# The "bad" image is a documented failure from the June sessions, not something invented
# here — it has already been observed to leave the device recoverable:
#
#   halium-boot-zl1-v67-from-v63-lxc-masked.img
#     18,022,400 bytes  cfce435a…
#     docs/session-notes/FAILURE-PATTERN-V64-V67.txt: "no ADB, no RNDIS, unknown state",
#     and the device was subsequently recovered from it.
#
# Every flash goes through scripts/flash-boot-image.sh, which verifies hashes and refuses
# to run without --yes. The rollback image is the one already verified byte-identical to
# what the device carried before Stage 2 started.
#
# Usage: stage2-rollback-drill.sh --yes
#
# Expect several minutes of waiting, and expect the device to be briefly unusable. Do not
# interrupt it part-way: if it is killed between the bad flash and the rollback, the
# device is left on the bad image, and only a fresh TWRP/fastboot session can fix that.

set -uo pipefail

SER="33e80afe"
ROOT=/mnt/data/zl1-bb10
BAD_IMG="/mnt/data/halium-zl1-candidates/halium-boot-zl1-v67-from-v63-lxc-masked.img"
BAD_SHA="cfce435a403f9f0435bcfc327b64b81fb30d3ae4c1b82cf4a23b1c166612fa8f"
ROLLBACK_IMG="/mnt/data/zl1-backups/2026-06-07-adb-root-staged/boot.img"
ROLLBACK_SHA="a06d6508499ee37a03effea1e6bec1d04f23843fd44d198a49fb3e07cb5778ef"
BAD_CONFIRM_SECONDS="${BAD_CONFIRM_SECONDS:-240}"   # how long to wait for the bad image to fail
GOOD_CONFIRM_SECONDS="${GOOD_CONFIRM_SECONDS:-420}" # how long to wait for Android to come back

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$ROOT/stage2-rollback-drill-${STAMP}.log"
log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }
die() { log "FAIL: $*"; exit 1; }

[[ "${1:-}" == "--yes" ]] || die "refusing to run the drill without --yes"

# --------------------------------------------------------------- preflight --
[[ -f "$BAD_IMG" ]] || die "bad image missing: $BAD_IMG"
got="$(sha256sum "$BAD_IMG" | awk '{print $1}')"
[[ "$got" == "$BAD_SHA" ]] || die "bad image hash mismatch: $got"
log "bad image OK      $(basename "$BAD_IMG")  $BAD_SHA"

got="$(sha256sum "$ROLLBACK_IMG" | awk '{print $1}')"
[[ "$got" == "$ROLLBACK_SHA" ]] || die "rollback image hash mismatch: $got"
log "rollback image OK $ROLLBACK_SHA"

adb devices 2>/dev/null | awk -v s="$SER" '$1==s{found=1} END{exit found?0:1}' \
  || die "target $SER not visible in adb (need TWRP)"
log "target $SER present; starting the drill"
log "the log for this run: $LOG"

# "Came up" for a Halium boot image means the RNDIS gadget appeared, NOT that adb did.
# Ubuntu Touch does not run adbd at all — it exposes RNDIS and nothing else — so an
# adb-based test reports failure for every UT image, including the known-good v63. The
# first version of this script had exactly that bug.
wait_for_halium() {
  local secs="$1" label="$2"
  local deadline=$(( SECONDS + secs ))
  while (( SECONDS < deadline )); do
    if lsusb -d 18d1:d001 >/dev/null 2>&1; then
      log "$label: RNDIS gadget present — the image booted"
      return 0
    fi
    if lsusb | grep -q '05c6:9008'; then
      log "$label: device fell to EDL (05c6:9008) rather than booting"
      return 2
    fi
    sleep 5
  done
  return 1
}

# The stock Android image does run adbd, so the rollback side is checked that way.
wait_for_android() {
  local secs="$1" label="$2"
  local deadline=$(( SECONDS + secs ))
  while (( SECONDS < deadline )); do
    if adb devices 2>/dev/null | awk -v s="$SER" '$1==s && $2=="device"{f=1} END{exit f?0:1}'; then
      log "$label: $SER came up as an adb device"
      return 0
    fi
    if lsusb -d 18d1:d001 >/dev/null 2>&1; then
      log "$label: RNDIS gadget present instead — that is a Halium image, not stock Android"
      return 2
    fi
    sleep 5
  done
  return 1
}

# ------------------------------------------------------- 1. the bad flash --
log "=== 1/4 flashing the known-bad image ==="
"$ROOT/scripts/flash-boot-image.sh" "$BAD_IMG" --yes >>"$LOG" 2>&1 || die "bad-image flash failed"

log "=== 2/4 confirming it does NOT come up (up to ${BAD_CONFIRM_SECONDS}s) ==="
wait_for_halium "$BAD_CONFIRM_SECONDS" "bad image"
bad_rc=$?
case "$bad_rc" in
  0) log "WARNING: the bad image produced an RNDIS gadget. That makes it a poor drill —"
     log "         check whether $BAD_IMG is still the image documented as failing." ;;
  2) log "the device fell to EDL instead of booting — that is a failure, but a harsher"
     log "         one than the documented symptom. Note it and continue to the rollback." ;;
  *) log "as expected: no RNDIS gadget within ${BAD_CONFIRM_SECONDS}s, so it did not boot"
     log "         enough to bring up USB at all" ;;
esac
log "the device needs a human to reach fastboot or TWRP now:"
log "  fastboot  = power off, hold Volume Down + Power"
log "  TWRP      = power off, hold Volume Up + Power"

# ------------------------------------------------------- 2. human in loop --
log "waiting up to 30 minutes for a human to bring the device to fastboot..."
deadline=$(( SECONDS + 1800 ))
while (( SECONDS < deadline )); do
  if timeout 5 fastboot devices 2>/dev/null | awk -v s="$SER" '$1==s{f=1} END{exit f?0:1}'; then
    log "fastboot is up"
    break
  fi
  if adb devices 2>/dev/null | awk -v s="$SER" '$1==s{print $2}' | grep -q recovery; then
    log "found the device in TWRP instead; switching it to fastboot"
    adb -s "$SER" reboot bootloader >/dev/null 2>&1 || true
    sleep 10
    continue
  fi
  sleep 10
done
timeout 5 fastboot devices 2>/dev/null | awk -v s="$SER" '$1==s{f=1} END{exit f?0:1}' \
  || die "timed out waiting for fastboot; the device is still on the bad image"

# ------------------------------------------------------- 3. the rollback --
log "=== 3/4 flashing the stock boot.img back ==="
"$ROOT/scripts/stage2-rollback-boot.sh" --yes >>"$LOG" 2>&1 || die "rollback flash failed"
log "rollback flashed"

# ------------------------------------------------------- 4. the proof --
log "=== 4/4 confirming the device is back (up to ${GOOD_CONFIRM_SECONDS}s) ==="
wait_for_android "$GOOD_CONFIRM_SECONDS" "rollback"
good_rc=$?
if [[ "$good_rc" -eq 0 ]]; then
  log "device back on stock Android: $(adb -s "$SER" shell getprop ro.build.fingerprint 2>/dev/null | tr -d '\r')"
  log "=== DRILL PASSED ==="
  log "log: $LOG"
  exit 0
fi

log "=== DRILL INCONCLUSIVE ==="
log "no adb within ${GOOD_CONFIRM_SECONDS}s after the rollback. The boot partition holds"
log "the stock image again (verified), so this is not a stuck bootloader, but check the"
log "device screen and try a fresh power-on before concluding anything."
log "log: $LOG"
exit 1
