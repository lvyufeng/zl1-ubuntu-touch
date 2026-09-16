#!/usr/bin/env bash
# Stage 2 — flash the known-good V63 Halium boot image and verify it survives a
# cold boot.
#
# This is the first script in the project that WRITES to the device. Read the
# safety notes in docs/ubuntu-touch/00-safety.md and the Stage 2 section of
# docs/ubuntu-touch/17-adaptation-plan.md before running it.
#
# Preconditions it enforces itself:
#   * the target serial 33e80afe is present (the unrelated Xiaomi 4a2fe00b is
#     never acceptable, and is explicitly rejected)
#   * the rollback image (the original Android boot.img) hashes to the value
#     recorded on 2026-06-07, and the device's boot partition was verified
#     byte-identical to it on 2026-09-16
#   * the V63 image hashes to the value recorded at build time
#
# If any check fails the script exits without touching the device.
#
# Usage: stage2-flash-boot-and-verify.sh --yes

set -euo pipefail

SER="33e80afe"
OTHER_SER="4a2fe00b"

ROLLBACK_IMG="/mnt/data/zl1-backups/2026-06-07-adb-root-staged/boot.img"
ROLLBACK_SHA="a06d6508499ee37a03effea1e6bec1d04f23843fd44d198a49fb3e07cb5778ef"

V63_IMG="/mnt/data/halium-zl1-candidates/halium-boot-zl1-v63-usbd-disabled.img"
V63_SHA="ab574bd337fa8dfe25b21b90bb8bc9ea39a1ea12907d286bed788e8f92e57576"

HOST_IPS=("192.168.2.100/24" "10.15.19.100/24")
DEV_IPS=("192.168.2.15" "10.15.19.82")
RNDIS_VIDPID="18d1:d001"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="/mnt/data/zl1-bb10/stage2-flash-${STAMP}.log"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }
die() { log "FAIL: $*"; exit 1; }

[[ "${1:-}" == "--yes" ]] || die "refusing to flash without --yes"

# ---------------------------------------------------------------- preflight --
log "=== preflight ==="

sha_of() { sha256sum "$1" | awk '{print $1}'; }

[[ -f "$ROLLBACK_IMG" ]] || die "rollback image missing: $ROLLBACK_IMG"
got="$(sha_of "$ROLLBACK_IMG")"
[[ "$got" == "$ROLLBACK_SHA" ]] || die "rollback image hash mismatch: $got"
log "rollback boot.img OK  $ROLLBACK_SHA"

[[ -f "$V63_IMG" ]] || die "v63 image missing: $V63_IMG"
got="$(sha_of "$V63_IMG")"
[[ "$got" == "$V63_SHA" ]] || die "v63 image hash mismatch: $got"
log "v63 image OK         $V63_SHA"

# The zl1 target must be the only 18d1/05c6 device we act on. If the Xiaomi is
# the only thing on the bus, refuse — this is the trap that cost an earlier
# session its device state.
if timeout 10 adb devices 2>/dev/null | awk -v s="$OTHER_SER" '$1==s{found=1} END{exit found?0:1}'; then
  log "note: unrelated device $OTHER_SER (Xiaomi) is on the bus — ignoring it"
fi

have_target() {
  timeout 10 adb devices 2>/dev/null | awk -v s="$SER" '$1==s{found=1} END{exit found?0:1}' \
  || timeout 10 fastboot devices 2>/dev/null | awk -v s="$SER" '$1==s{found=1} END{exit found?0:1}'
}
have_target || die "target $SER not visible in adb or fastboot"
log "target $SER present"

# ------------------------------------------------------------- to bootloader --
if timeout 10 adb devices 2>/dev/null | awk -v s="$SER" '$1==s{found=1} END{exit found?0:1}'; then
  adb_st="$(timeout 10 adb -s "$SER" get-state 2>/dev/null | tr -d '\r')"
  log "adb state=$adb_st — rebooting to bootloader"
  timeout 30 adb -s "$SER" reboot bootloader >>"$LOG" 2>&1 || true
fi

log "waiting for fastboot on $SER"
for _ in $(seq 1 60); do
  if timeout 5 fastboot devices 2>/dev/null | awk -v s="$SER" '$1==s{found=1} END{exit found?0:1}'; then
    break
  fi
  sleep 2
done
timeout 5 fastboot devices 2>/dev/null | awk -v s="$SER" '$1==s{found=1} END{exit found?0:1}' \
  || die "target $SER did not appear in fastboot"

# ------------------------------------------------------------------- flash --
log "=== flashing boot ==="
timeout 180 fastboot -s "$SER" flash boot "$V63_IMG" 2>&1 | tee -a "$LOG"
log "flash done; rebooting"
timeout 60 fastboot -s "$SER" reboot >>"$LOG" 2>&1 || true

# ------------------------------------------------------- host RNDIS plumbing --
log "=== waiting for the device RNDIS gadget ==="
# v63's cmdline carries zl1_init_delay=30, so allow well past that before
# deciding the boot failed.
found=""
for i in $(seq 1 150); do
  if lsusb -d "$RNDIS_VIDPID" >/dev/null 2>&1; then found=1; break; fi
  sleep 2
done
[[ -n "$found" ]] || die "device never presented $RNDIS_VIDPID; check the device screen / try the rollback"

# The gadget advertises bInterfaceClass=255 (vendor specific) so rndis_host does
# not always auto-probe. Loading it needs root — a bare `modprobe` returns
# "Operation not permitted" on this host, which would silently leave usb0
# missing and make a successful flash look like a failure.
if ! lsmod | grep -q '^rndis_host'; then
  sudo -n modprobe rndis_host || log "warning: could not load rndis_host"
fi

for i in $(seq 1 30); do
  ip link show usb0 >/dev/null 2>&1 && break
  sleep 1
done

# Fallback for hosts where the driver is loaded but did not claim the
# interface: bind it explicitly through usbnet's sysfs new_id hook.
if ! ip link show usb0 >/dev/null 2>&1; then
  log "usb0 did not appear — trying an explicit rndis_host bind"
  if [[ -d /sys/bus/usb/drivers/rndis_host ]]; then
    echo "$RNDIS_VIDPID" | sudo -n tee /sys/bus/usb/drivers/rndis_host/new_id >/dev/null 2>&1 || true
  fi
  for i in $(seq 1 15); do
    ip link show usb0 >/dev/null 2>&1 && break
    sleep 1
  done
fi

ip link show usb0 >/dev/null 2>&1 || die "usb0 never appeared on the host"

sudo -n ip link set usb0 up || die "cannot bring usb0 up (need passwordless sudo)"
for a in "${HOST_IPS[@]}"; do
  ip addr show dev usb0 | grep -q "${a%%/*}" || sudo -n ip addr add "$a" dev usb0
done
ip -br addr show usb0 | tee -a "$LOG"

# ------------------------------------------------------------------ verify --
log "=== verifying ==="
ok=0
for ip in "${DEV_IPS[@]}"; do
  for _ in $(seq 1 20); do
    if ping -c1 -W1 "$ip" >/dev/null 2>&1; then log "ping $ip OK"; ok=$((ok+1)); break; fi
    sleep 2
  done
done

http=""
for _ in $(seq 1 10); do
  http="$(timeout 5 curl -fsS --max-time 4 http://10.15.19.82:8080/ 2>/dev/null || true)"
  [[ -n "$http" ]] && break
  sleep 3
done
if [[ -n "$http" ]]; then
  log "HTTP 8080 responded"
  printf '%s\n' "$http" | head -20 | tee -a "$LOG"
else
  log "HTTP 8080 did not respond"
fi

log "=== result: ping_ok=$ok/2 http=$([[ -n "$http" ]] && echo yes || echo no) ==="
log "rollback if needed:  fastboot -s $SER flash boot $ROLLBACK_IMG"
log "log: $LOG"

[[ "$ok" -eq 2 && -n "$http" ]] || exit 1
