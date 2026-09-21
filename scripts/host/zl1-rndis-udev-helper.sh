#!/usr/bin/env bash
# Bind rndis_host to the zl1's Halium gadget and give its usb0 interface addresses.
#
# Run by udev (see 99-zl1-rndis.rules), so it must be quick, must not depend on anything
# that may not be in udev's environment, and must be safe to run concurrently with itself
# — the zl1 re-binds its gadget several times in the first seconds of boot, so udev will
# fire this repeatedly and the invocations will overlap.
#
# Why this exists at all: rndis_host does not always claim the zl1's RNDIS interface on
# its own. When it does not, no usb0 appears, and "no usb0" is indistinguishable from "the
# device never booted" — which is how a 14.7-hour cold boot came to be judged as a failed
# one (docs/ubuntu-touch/37-the-trial-that-had-no-peer.md). Doing this in udev rather than
# in a watcher script means it also works when no watcher happens to be running.
#
# It matches on the serial, never on the USB ID alone: an unrelated Xiaomi on this bus
# presents the *same* 18d1:4ee7 as the zl1 in stock Android.

set -u

ZL1_SERIAL="33e80afe"
ZL1_ID="18d1:d001"          # the zl1's Halium/RNDIS gadget
HOST_IPS=("192.168.2.100/24" "10.15.19.100/24")
LOG=/var/log/zl1-rndis-udev.log

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG" 2>/dev/null || true; }

# udev hands us the interface name in $1 when the rule matches an interface; fall back to
# searching sysfs so the script is also usable by hand.
ifc="${1:-}"
if [[ -z "$ifc" ]]; then
  for d in /sys/bus/usb/devices/*; do
    [ -r "$d/idVendor" ] || continue
    [[ "$(cat "$d/idVendor" 2>/dev/null)"  == "18d1" ]] || continue
    [[ "$(cat "$d/idProduct" 2>/dev/null)" == "d001" ]] || continue
    [[ "$(cat "$d/serial" 2>/dev/null)"    == "$ZL1_SERIAL" ]] || continue
    ifc="$(ls -d "$d":* 2>/dev/null | head -1)"
    ifc="${ifc##*/}"
    break
  done
fi
[[ -n "$ifc" ]] || exit 0

# Refuse if the serial is not the target's. This is the check that keeps an
# identical-looking Xiaomi from being configured as if it were the zl1.
#
# Match on the *prefix*, not equality. The zl1 does not always report the bare serial:
# in v63's RNDIS mode it reports `33e80afe-v63-usbd-disabled-rndis`. The first version of
# this script required `33e80afe` exactly and therefore skipped the zl1 itself — logged as
# "skip 3-3:1.1: serial [33e80afe-v63-usbd-disabled-rndis] is not 33e80afe", which is a
# fine illustration of a guard that is stricter than the thing it guards.
dev="${ifc%%:*}"
serial="$(cat "/sys/bus/usb/devices/$dev/serial" 2>/dev/null || true)"
case "$serial" in
  "$ZL1_SERIAL"*) ;;
  *) log "skip $ifc: serial [${serial:-none}] does not start with $ZL1_SERIAL"; exit 0 ;;
esac

modprobe rndis_host 2>/dev/null || true
if [ ! -e "/sys/bus/usb/drivers/rndis_host/$ifc" ]; then
  printf '%s' "$ifc" | tee /sys/bus/usb/drivers/rndis_host/bind >/dev/null 2>&1 || true
  log "bound rndis_host to $ifc"
fi

# usb0 is created a moment after the bind. Wait for it, but not indefinitely — udev kills
# long-running helpers and a stuck one would be worse than a missing address.
for _ in $(seq 1 20); do
  [ -e /sys/class/net/usb0 ] && break
  sleep 0.25
done
[ -e /sys/class/net/usb0 ] || { log "$ifc bound but usb0 never appeared"; exit 0; }

ip link set usb0 up 2>/dev/null || true
for a in "${HOST_IPS[@]}"; do
  ip addr show dev usb0 2>/dev/null | grep -q "${a%%/*}" && continue
  ip addr add "$a" dev usb0 2>/dev/null && log "usb0: added $a"
done
log "usb0 up: $(ip -br addr show usb0 2>/dev/null | tr -s ' ')"
