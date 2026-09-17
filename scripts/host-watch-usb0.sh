#!/usr/bin/env bash
# Keep the host-side RNDIS plumbing correct while the zl1 boots.
#
# The device re-binds its USB gadget several times in the first seconds of boot
# (the v63 keeper's 64 "reasserting android_usb" lines all land between uptime
# 3.7 s and 4.1 s). Each rebind is a USB disconnect/reconnect, so the host's
# `usb0` is destroyed and recreated with a *new* MAC and with its addresses
# gone. A one-shot `ip addr add` therefore only works if it happens to land
# after the last rebind — which is why cold-boot verification was flaky even
# though the device was healthy the whole time.
#
# This watches for that and re-applies the configuration every time usb0
# (re)appears. Read-only with respect to the device; it only configures the
# host interface.
#
# Usage: host-watch-usb0.sh [SECONDS]     (default 600; 0 = until killed)

set -uo pipefail

SECONDS_TO_RUN="${1:-600}"
HOST_IPS=("192.168.2.100/24" "10.15.19.100/24")
DEV_IPS=("192.168.2.15" "10.15.19.82")
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="/mnt/data/zl1-bb10/tmp-host-usb0-${STAMP}.log"

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }

last_mac=""
declare -A announced=()

setup() {
  sudo -n ip link set usb0 up 2>/dev/null
  for a in "${HOST_IPS[@]}"; do
    ip addr show dev usb0 2>/dev/null | grep -q "${a%%/*}" || sudo -n ip addr add "$a" dev usb0 2>/dev/null
  done
}

log "watching usb0 for ${SECONDS_TO_RUN}s (0 = forever); log: $LOG"
start=$SECONDS
while :; do
  if [[ "$SECONDS_TO_RUN" != "0" ]] && (( SECONDS - start >= SECONDS_TO_RUN )); then break; fi

  if ip link show usb0 >/dev/null 2>&1; then
    mac="$(cat /sys/class/net/usb0/address 2>/dev/null)"
    state="$(cat /sys/class/net/usb0/operstate 2>/dev/null)"
    carrier="$(cat /sys/class/net/usb0/carrier 2>/dev/null)"
    if [[ "$mac" != "$last_mac" ]]; then
      log "usb0 $mac appeared (operstate=$state carrier=${carrier:-?}) — configuring"
      setup
      last_mac="$mac"
      unset announced
      declare -A announced=()
      sleep 2
      log "  $(ip -br addr show usb0 2>/dev/null)"
    else
      # Same session, but make sure it is still up and still has its addresses.
      [[ "$(cat /sys/class/net/usb0/operstate 2>/dev/null)" == "down" ]] && { log "usb0 $mac went down — reconfiguring"; setup; }
      for a in "${HOST_IPS[@]}"; do
        ip addr show dev usb0 2>/dev/null | grep -q "${a%%/*}" || { log "usb0 $mac lost ${a%%/*} — reconfiguring"; setup; break; }
      done
    fi

    # Re-probe on every pass, not only until the first success. The device-side watchdog
    # decides whether its transmit path is alive by pinging us, so keeping a trickle of
    # host traffic going means the link is exercised from both ends; and a probe that
    # starts failing again is itself the signal that something changed.
    for ip in "${DEV_IPS[@]}"; do
      if ping -c1 -W1 "$ip" >/dev/null 2>&1; then
        if [[ -z "${announced[$ip]:-}" ]]; then
          log "  ping $ip OK"
          announced[$ip]=1
        fi
      else
        if [[ -n "${announced[$ip]:-}" ]]; then
          log "  ping $ip FAILED (was OK)"
          unset "announced[$ip]"
        fi
      fi
    done
  else
    if [[ -n "$last_mac" ]]; then
      log "usb0 disappeared"
      last_mac=""
      unset announced
      declare -A announced=()
    fi
  fi

  sleep 1
done
log "watcher done"
