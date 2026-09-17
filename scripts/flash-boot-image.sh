#!/usr/bin/env bash
# Flash an arbitrary boot image to the zl1, with the safety rails kept on.
#
# This is the generic form of stage2-flash-boot-and-verify.sh: same serial
# filtering, same refusal to act without --yes, same verified rollback, but the
# image is a parameter so diagnostic images can be flashed without editing a
# script.
#
# It refuses any image that is not in /mnt/data/halium-zl1-candidates/SHA256SUMS,
# so a half-written or mistyped file cannot reach the device.
#
# Usage: flash-boot-image.sh <IMAGE> --yes
#        flash-boot-image.sh --list

set -euo pipefail

SER="33e80afe"
OTHER_SER="4a2fe00b"
CAND="/mnt/data/halium-zl1-candidates"
SUMS="$CAND/SHA256SUMS"
ROLLBACK_IMG="/mnt/data/zl1-backups/2026-06-07-adb-root-staged/boot.img"
ROLLBACK_SHA="a06d6508499ee37a03effea1e6bec1d04f23843fd44d198a49fb3e07cb5778ef"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="/mnt/data/zl1-bb10/flash-boot-${STAMP}.log"
log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }
die() { log "FAIL: $*"; exit 1; }

if [[ "${1:-}" == "--list" ]]; then
  [[ -f "$SUMS" ]] && awk '{printf "  %s  %s\n", $1, $2}' "$SUMS" || echo "  (no SHA256SUMS yet)"
  exit 0
fi

IMG="${1:?usage: $0 <IMAGE> --yes}"
[[ "${2:-}" == "--yes" ]] || die "refusing to flash without --yes"

# ---------------------------------------------------------------- preflight --
[[ -f "$IMG" ]] || die "image missing: $IMG"
[[ -f "$SUMS" ]] || die "no SHA256SUMS in $CAND — refusing to flash an unverified image"

want="$(awk -v f="$IMG" '$2==f{print $1}' "$SUMS")"
if [[ -z "$want" ]]; then
  # allow matching by basename too
  want="$(awk -v f="$(basename "$IMG")" '{n=split($2,a,"/"); if (a[n]==f) print $1}' "$SUMS" | head -1)"
fi
[[ -n "$want" ]] || die "$(basename "$IMG") is not listed in $SUMS"

got="$(sha256sum "$IMG" | awk '{print $1}')"
[[ "$got" == "$want" ]] || die "image hash mismatch: $got != $want"
log "image OK  $(basename "$IMG")  $got"

[[ -f "$ROLLBACK_IMG" ]] || die "rollback image missing: $ROLLBACK_IMG"
got="$(sha256sum "$ROLLBACK_IMG" | awk '{print $1}')"
[[ "$got" == "$ROLLBACK_SHA" ]] || die "rollback image hash mismatch: $got"
log "rollback OK  $ROLLBACK_SHA"

if adb devices 2>/dev/null | awk -v s="$OTHER_SER" '$1==s{found=1} END{exit found?0:1}'; then
  log "note: unrelated device $OTHER_SER (Xiaomi) is on the bus — ignoring it"
fi

have_adb()    { timeout 10 adb devices    2>/dev/null | awk -v s="$SER" '$1==s{found=1} END{exit found?0:1}'; }
have_fastboot(){ timeout 10 fastboot devices 2>/dev/null | awk -v s="$SER" '$1==s{found=1} END{exit found?0:1}'; }

have_adb || have_fastboot || die "target $SER not visible in adb or fastboot"
log "target $SER present"

if have_adb; then
  log "adb state=$(adb -s "$SER" get-state 2>/dev/null | tr -d '\r') — rebooting to bootloader"
  timeout 30 adb -s "$SER" reboot bootloader >>"$LOG" 2>&1 || true
fi

log "waiting for fastboot on $SER"
for _ in $(seq 1 60); do have_fastboot && break; sleep 2; done
have_fastboot || die "target $SER did not appear in fastboot"

# ------------------------------------------------------------------- flash --
log "=== flashing $(basename "$IMG") ==="
timeout 180 fastboot -s "$SER" flash boot "$IMG" 2>&1 | tee -a "$LOG"
log "flash done; rebooting"
timeout 60 fastboot -s "$SER" reboot >>"$LOG" 2>&1 || true

log "rollback if needed:  fastboot -s $SER flash boot $ROLLBACK_IMG"
log "log: $LOG"
