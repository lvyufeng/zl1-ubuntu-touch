#!/usr/bin/env bash
# Get from a running Ubuntu Touch to TWRP without touching the device.
#
# Ubuntu Touch runs no adbd, so the only channels out of it are SSH (once the link is up)
# and the bootloader command in `misc`. Writing `boot-recovery` there is what Android's
# own `reboot recovery` does, and it is the same mechanism the device-side watchdog uses
# for its RECOVERY_AFTER option — see scripts/device/zl1-netwatch.sh and
# docs/ubuntu-touch/26-gadget-reassert-every-2-minutes.md.
#
# This matters for the rollback drill and for every stage after it: without it, reaching
# TWRP costs a physical key press, and a stage that needs a key press at both ends cannot
# be driven unattended.
#
# The write is verified by reading it back, exactly as the watchdog does, and the first
# 2048 bytes of `misc` are saved to the host first. If the read-back does not match, the
# device is NOT rebooted — a reboot with no bootloader command just boots the system
# again, which is a reboot loop rather than a degraded version of this feature.
#
# Usage: enter-recovery-from-ut.sh [--yes] [--no-reboot]
#   --no-reboot  only stage the command; the next reboot for any reason will use it.

set -uo pipefail

SER="33e80afe"
DEV_HOST="root@10.15.19.82"
ROOT=/mnt/data/zl1-bb10
BACKUP_DIR="/mnt/data/zl1-backups/2026-09-21-misc-commands"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="$ROOT/enter-recovery-${STAMP}.log"
NO_REBOOT=0
[[ "${1:-}" == "--no-reboot" || "${2:-}" == "--no-reboot" ]] && NO_REBOOT=1

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }
die() { log "FAIL: $*"; exit 1; }

[[ "${1:-}" == "--yes" || "${1:-}" == "--no-reboot" ]] || die "refusing without --yes"

ssh_cmd() {
  timeout 30 ssh -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 "$DEV_HOST" "$@" 2>/dev/null
}
ssh_ready() { ssh_cmd true; }

ssh_ready || die "the device is not answering SSH — this script starts from a running Ubuntu Touch"
log "Ubuntu Touch is up: uptime $(ssh_cmd 'cut -d" " -f1 /proc/uptime')"

# ------------------------------------------------------------------ the block --
# Ubuntu Touch does not create /dev/block/*; udev names the partitions under
# /dev/disk/by-partlabel/ and the node itself is /dev/sdaNN. TWRP and Android instead use
# /dev/block/bootdevice/by-name/. Ask the device which of these exists rather than
# assuming either world.
MISC=""
for cand in /dev/disk/by-partlabel/misc /dev/block/bootdevice/by-name/misc \
            /dev/block/sda4 /dev/sda4; do
  if ssh_cmd "test -e $cand"; then MISC="$(ssh_cmd "readlink -f $cand" | tr -d '\r')"; break; fi
done
[[ -n "$MISC" ]] || die "could not find the misc partition"
log "misc resolves to $MISC"

mkdir -p "$BACKUP_DIR"
BEFORE="$BACKUP_DIR/misc-first2048-${STAMP}.bin"
if ssh_cmd "dd if=$MISC bs=512 count=4 2>/dev/null" > "$BEFORE" 2>/dev/null && [[ -s "$BEFORE" ]]; then
  log "saved the first 2048 bytes of misc to $BEFORE"
  sha256sum "$BEFORE" | tee -a "$LOG"
else
  log "WARNING: could not save misc before writing; continuing (the full partition backup"
  log "         from 2026-09-17 is at /mnt/data/zl1-backups/2026-09-17-misc/misc.img)"
fi

# Current command, if any. Do not overwrite a command that is already pending without
# saying so — a misc that already says `boot-recovery` means something else put it there.
cur="$(ssh_cmd "dd if=$MISC bs=1 count=32 2>/dev/null | tr -d '\\000'" | tr -d '\r')"
log "command in misc before: [${cur}]"

# -------------------------------------------------------------------- write ---
ssh_cmd "printf 'boot-recovery' > $MISC && sync" || die "could not write $MISC"
back="$(ssh_cmd "dd if=$MISC bs=1 count=16 2>/dev/null | tr -d '\\000'" | tr -d '\r')"
[[ "$back" == boot-recovery ]] || die "read back [$back] — the write did not take; NOT rebooting"
log "wrote and verified boot-recovery in $MISC"

if (( NO_REBOOT )); then
  log "staged only (--no-reboot): the next reboot will go to recovery"
  exit 0
fi

# ------------------------------------------------------------------- reboot ---
log "rebooting; the device should come up in TWRP"
ssh_cmd 'sync; reboot' || true

deadline=$(( SECONDS + 300 ))
while (( SECONDS < deadline )); do
  if adb devices 2>/dev/null | awk -v s="$SER" '$1==s && $2=="recovery"{f=1} END{exit f?0:1}'; then
    log "TWRP is up on $SER"
    log "log: $LOG"
    exit 0
  fi
  sleep 5
done
log "no TWRP within 300 s."
log "  If the device instead booted Ubuntu Touch again, the bootloader did not act on the"
log "  command; check whether the command is still in misc and read it back with:"
log "    ssh $DEV_HOST \"dd if=$MISC bs=1 count=32 | tr -d '\\\\000'\""
log "log: $LOG"
exit 1
