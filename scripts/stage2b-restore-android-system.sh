#!/usr/bin/env bash
# Stage 2b — restore the Android system image at /data/system.img.
#
# Why this is needed: the zl1 v63 initramfs builds a tmpfs at /android only when
# it finds an Android system image. The three places it looks are
# /tmpmnt/system.img (= /data/system.img), /tmpmnt/android-rootfs.img, and
# /halium-system/var/lib/lxc/android/system.img. With none of them present,
# ANDROID_IMAGE_MODE becomes "unknown", /android stays on the read-only rootfs,
# and the Android LXC container cannot start. See
# docs/ubuntu-touch/21-stage2-first-cold-boot.md section 4.
#
# The image is written as a regular file onto userdata. No partition is written
# and no bootloader is involved.
#
# Run this with the device in TWRP or booted Android (i.e. with adb available).
#
# Usage: stage2b-restore-android-system.sh --yes

set -euo pipefail

SER="33e80afe"
OTHER_SER="4a2fe00b"

IMG="/mnt/data/halium-zl1-candidates/android-system-zl1-halium-candidate.img"
SHA="ec1d52fa36b37893b840e30a60dbbda4a54b0058bf258ab1b1d20ba8508142f8"
SIZE=4294967296
DEST="/data/system.img"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="/mnt/data/zl1-bb10/stage2b-restore-${STAMP}.log"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }
die() { log "FAIL: $*"; exit 1; }

[[ "${1:-}" == "--yes" ]] || die "refusing to write to the device without --yes"

log "=== Stage 2b: restore $DEST ==="

# ------------------------------------------------------------ preflight --
[[ -f "$IMG" ]] || die "image missing: $IMG"
got="$(sha256sum "$IMG" | awk '{print $1}')"
[[ "$got" == "$SHA" ]] || die "image hash mismatch: $got != $SHA"
[[ "$(stat -c%s "$IMG")" == "$SIZE" ]] || die "image size $(stat -c%s "$IMG") != $SIZE"
log "image OK  $SHA"

if adb devices 2>/dev/null | awk -v s="$OTHER_SER" '$1==s{found=1} END{exit found?0:1}'; then
  log "note: unrelated device $OTHER_SER (Xiaomi) is on the bus — ignoring it"
fi
adb devices 2>/dev/null | awk -v s="$SER" '$1==s{found=1} END{exit found?0:1}' \
  || die "target $SER not visible in adb; refusing to act on any other device"
state="$(adb -s "$SER" get-state 2>/dev/null | tr -d '\r')"
log "target $SER present, adb state=$state"

# Refuse to overwrite something unexpected.
existing="$(adb -s "$SER" shell "ls -l $DEST 2>/dev/null || true" | tr -d '\r')"
if [[ -n "$existing" ]]; then
  log "note: $DEST already exists: $existing"
  esize="$(adb -s "$SER" shell "stat -c %s $DEST 2>/dev/null || echo 0" | tr -d '\r')"
  if [[ "$esize" == "$SIZE" ]]; then
    log "$DEST already has the right size — hashing it to decide whether to copy"
    ehash="$(adb -s "$SER" shell "sha256sum $DEST" | awk '{print $1}' | tr -d '\r')"
    if [[ "$ehash" == "$SHA" ]]; then
      log "already correct ($ehash) — nothing to do"
      exit 0
    fi
    log "content differs ($ehash) — replacing"
  fi
fi

free_kb="$(adb -s "$SER" shell "df /data 2>/dev/null | tail -1 | awk '{print \$4}'" | tr -d '\r')"
log "free space on /data: ${free_kb:-?} KiB"

# --------------------------------------------------------------- transfer --
log "=== pushing $SIZE bytes (this takes several minutes) ==="
adb -s "$SER" push "$IMG" "$DEST" 2>&1 | tee -a "$LOG"

# --------------------------------------------------------------- verify --
log "=== verifying on the device ==="
esize="$(adb -s "$SER" shell "stat -c %s $DEST" | tr -d '\r')"
[[ "$esize" == "$SIZE" ]] || die "device copy is $esize bytes, want $SIZE"

log "hashing on the device (4 GB, a minute or two)"
ehash="$(adb -s "$SER" shell "sha256sum $DEST" | awk '{print $1}' | tr -d '\r')"
log "device sha256 $ehash"
[[ "$ehash" == "$SHA" ]] || die "device copy hashes to $ehash, want $SHA"

log "=== OK: $DEST is in place ==="
log "next: reboot and check the container. The device will expose RNDIS only, so"
log "verify from the host with:  scripts/verify-device-online.sh"
log "log: $LOG"
