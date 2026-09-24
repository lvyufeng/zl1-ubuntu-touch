#!/usr/bin/env bash
# Stage 2 verification — wait for the device's RNDIS gadget and prove it is
# reachable, without touching any partition.
#
# Use this for cold-boot repeats 2 and 3: power the device off and on, then run
# this. It is the same check stage2-flash-boot-and-verify.sh runs after flashing,
# split out so a reboot does not require re-running (or re-authorising) the flash.
#
# Exit 0 only when both device IPs answer ping AND the status server replies.
#
# Usage: verify-device-online.sh [--timeout SECONDS]

set -euo pipefail

SER="33e80afe"
OTHER_SER="4a2fe00b"

HOST_IPS=("192.168.2.100/24" "10.15.19.100/24")
DEV_IPS=("192.168.2.15" "10.15.19.82")
RNDIS_VIDPID="18d1:d001"
GADGET_WAIT="${1:+}"; GADGET_WAIT=180
[[ "${1:-}" == "--timeout" ]] && GADGET_WAIT="$2"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="/mnt/data/zl1-bb10/tmp-stage2-verify-${STAMP}"
mkdir -p "$OUT"
LOG="$OUT/verify.log"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }

if adb devices 2>/dev/null | awk -v s="$OTHER_SER" '$1==s{found=1} END{exit found?0:1}'; then
  log "note: unrelated device $OTHER_SER (Xiaomi) is on the bus — ignoring it"
fi

log "=== waiting up to ${GADGET_WAIT}s for the device RNDIS gadget ==="
found=""
for (( i = 0; i < GADGET_WAIT / 2; i++ )); do
  if lsusb -d "$RNDIS_VIDPID" >/dev/null 2>&1; then found=1; break; fi
  sleep 2
done
if [[ -z "$found" ]]; then
  log "FAIL: device never presented $RNDIS_VIDPID"
  log "      (if it never appears, see docs/ubuntu-touch/20-stage2-runbook.md section 6)"
  exit 1
fi
log "gadget $RNDIS_VIDPID present"

# Here-strings from here on: this script sets pipefail, and `lsmod | grep -q` reports the writer's
# death when the pattern IS there -- i.e. "rndis_host is not loaded" on a host that has it
# (docs/ubuntu-touch/136).
if ! grep -q '^rndis_host' <<< "$(lsmod)"; then
  sudo -n modprobe rndis_host || log "warning: could not load rndis_host"
fi
for _ in $(seq 1 30); do
  ip link show usb0 >/dev/null 2>&1 && break
  sleep 1
done
if ! ip link show usb0 >/dev/null 2>&1; then
  log "usb0 did not appear — trying an explicit rndis_host bind"
  if [[ -d /sys/bus/usb/drivers/rndis_host ]]; then
    echo "$RNDIS_VIDPID" | sudo -n tee /sys/bus/usb/drivers/rndis_host/new_id >/dev/null 2>&1 || true
  fi
  for _ in $(seq 1 15); do
    ip link show usb0 >/dev/null 2>&1 && break
    sleep 1
  done
fi
ip link show usb0 >/dev/null 2>&1 || { log "FAIL: usb0 never appeared on the host"; exit 1; }

sudo -n ip link set usb0 up
for a in "${HOST_IPS[@]}"; do
  grep -q "${a%%/*}" <<< "$(ip addr show dev usb0)" || sudo -n ip addr add "$a" dev usb0
done
ip -br addr show usb0 | tee -a "$LOG"

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
  printf '%s\n' "$http" > "$OUT/status-8080.txt"
  log "HTTP 8080 responded ($(printf '%s' "$http" | wc -c) bytes) -> $OUT/status-8080.txt"
else
  log "HTTP 8080 did not respond"
fi

# The status page carries the process summary. Look for the markers that mean
# the container is really up — never `lxc-ls`, which reports STOPPED here even
# while the container runs (see docs/ubuntu-touch/17-adaptation-plan.md 1.2).
if [[ -n "$http" ]]; then
  for pat in 'lxc-start' 'servicemanager' 'logd' 'systemd'; do
    if grep -q "$pat" <<< "$http"; then
      log "status page mentions: $pat"
    else
      log "status page does NOT mention: $pat"
    fi
  done
fi

log "=== result: ping_ok=$ok/2 http=$([[ -n "$http" ]] && echo yes || echo no) ==="
log "evidence: $OUT"
[[ "$ok" -eq 2 && -n "$http" ]]
