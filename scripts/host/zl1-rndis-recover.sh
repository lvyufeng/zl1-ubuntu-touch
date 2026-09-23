#!/usr/bin/env bash
# Get the host's RNDIS link to the zl1 back, from the host, without touching the device.
#
# Why this exists: on 2026-09-23 the link died mid-session and **the device was fine the whole time.**
# A long-running camera-stack reset on the device stopped producing traffic, SSH went to "No route to
# host", and the host's `usb0` still had both addresses, the gadget still answered USB control
# requests (descriptors and serial read fine), and the device-side watchdog `zl1-netwatch.service` was
# running and never decided to heal anything -- because **from the device's own point of view nothing
# was wrong**: its `rndis0` showed TX 63 MB / 63625 packets, RX 3.5 MB / 40202 packets, and
# `tx_dropped=0 tx_errors=0 rx_dropped=0 rx_errors=0`, i.e. all-zero error counters, while the host
# received literally nothing (`rx_packets` frozen). A stall that only exists in the *host's* receive
# direction is invisible to a detector that watches the device's transmit counters.
#
# The fix that worked was a host-side USB re-enumeration, and it needed no reboot, no replug and no
# key press: the device kept its uptime across it. That makes this the cheapest way to get back in,
# and it is worth having as a script rather than as something to re-derive by hand under pressure.
#
# The escalation, in order, each step followed by a real end-to-end test (ping, then an SSH that
# actually reads something). It stops as soon as the link works:
#
#   1. bring `usb0` up and re-apply the two host addresses (completely harmless, and enough when the
#      interface was merely recreated without addresses);
#   2. unbind/rebind `rndis_host` on the gadget's interfaces (re-initialises the RNDIS data channel);
#   3. **re-enumerate the gadget** with the `authorized` 0 -> 1 toggle. This is the step that fixed
#      the 2026-09-23 stall. It is the same thing the device sees on every boot, and it does not cut
#      power to the phone (the battery keeps it running; the uptime proves it -- 38532 s across the
#      recovery);
#   4. as a last resort, unbind/rebind the whole USB device from the host's `usb` driver. Only run
#      with `--force`: it is the closest thing to a replug, and if the gadget does not come back on
#      its own the next step is a physical power cycle.
#
# Everything here is a **host-side** USB operation. No device storage is read or written, no
# partition is touched, and the device is never asked to do anything (it cannot be asked: this is the
# tool you reach for when you cannot reach it).
#
# Safety of the target: it matches on serial `33e80afe` (prefix match -- in this mode the zl1 reports
# `33e80afe-v63-usbd-disabled-rndis`), never on the bare USB ID. An unrelated Xiaomi on this bus
# presents the same 18d1:4ee7 in stock Android, and acting on it would be acting on the wrong phone.
#
# Needs root for the sysfs writes; it re-executes itself under sudo if it is not already root.
#
# Usage: zl1-rndis-recover.sh [--status] [--force] [--quiet]

set -u

ZL1_SERIAL="33e80afe"
HOST_IPS=("192.168.2.100/24" "10.15.19.100/24")
DEV_IPS=("10.15.19.82" "192.168.2.15")
LOG=/var/log/zl1-rndis-recover.log
STATUS_ONLY=0
FORCE=0
QUIET=0

for a in "$@"; do
  case "$a" in
    --status) STATUS_ONLY=1 ;;
    --force)  FORCE=1 ;;
    --quiet)  QUIET=1 ;;
    *) echo "unknown argument $a" >&2; exit 2 ;;
  esac
done

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG" 2>/dev/null || true; }
say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; log "$*"; }

if [ "$(id -u)" != 0 ]; then
  exec sudo -n "$0" "$@"
fi

# The whole script runs as root (it writes to sysfs), but the SSH check must not: root's
# ~/.ssh is not the account whose key the device authorises. Without this, `link_ok` fails on a
# perfectly good link -- in BatchMode it gets "Permission denied (publickey)" and reports the link
# dead. So remember whose key to use before anything else.
SSH_KEY_ARGS=""
if [ -n "${SUDO_USER:-}" ]; then
  user_home=$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)
  for k in "$user_home"/.ssh/id_ed25519 "$user_home"/.ssh/id_ecdsa "$user_home"/.ssh/id_rsa; do
    [ -f "$k" ] && { SSH_KEY_ARGS="-i $k -o IdentitiesOnly=yes"; break; }
  done
  [ -n "$SSH_KEY_ARGS" ] || say "WARNING: no ssh key found for $SUDO_USER -- the SSH half of the link test will fail"
fi

# ---- find the gadget, by serial ---------------------------------------------------------------
dev=""
for d in /sys/bus/usb/devices/*; do
  [ -r "$d/idVendor" ] || continue
  [ "$(cat "$d/idVendor" 2>/dev/null)" = "18d1" ] || continue
  [ "$(cat "$d/idProduct" 2>/dev/null)" = "d001" ] || continue
  case "$(cat "$d/serial" 2>/dev/null || true)" in
    "$ZL1_SERIAL"*) dev="${d##*/}"; break ;;
  esac
done
if [ -z "$dev" ]; then
  say "no zl1 gadget on the bus (no 18d1:d001 with serial starting $ZL1_SERIAL)"
  say "this is not something this script can fix: check the cable and the port, then the device"
  exit 1
fi
say "zl1 gadget at usb/$dev (serial $(cat /sys/bus/usb/devices/$dev/serial))"

# ---- what does it look like right now ---------------------------------------------------------
report() {
  say "  usb0: $(ip -br addr show usb0 2>/dev/null | tr -s ' ' || echo 'absent')"
  say "  driver bindings: $(ls /sys/bus/usb/drivers/rndis_host/ 2>/dev/null |
        grep -vE 'bind|module|new_id|remove_id|uevent|unbind' | tr '\n' ' ')"
  say "  usb0 counters: rx=$(cat /sys/class/net/usb0/statistics/rx_packets 2>/dev/null) tx=$(cat /sys/class/net/usb0/statistics/tx_packets 2>/dev/null)"
}

# The test has to be end to end: an ICMP reply, and then a read that proves something is executing on
# the device. `ping` alone can be answered by a stale ARP entry in some setups, and an SSH banner
# exchange can complete against a half-dead link, so the check reads a value.
#
# The ping is retried rather than sent once: after a stall the ARP entry for the device is usually
# FAILED or absent, so the *first* packet is spent on ARP resolution and a single-packet ping with a
# 2 s deadline reports "down" on a link that came back perfectly. (The first version of this script
# did exactly that and told a working link it was dead -- which, for a recovery tool, is the worst
# possible bug: it would have gone on to re-enumerate a healthy device.)
link_ok() {
  ping -c 3 -i 0.3 -W 3 "${DEV_IPS[0]}" >/dev/null 2>&1 || return 1
  for host in "${DEV_IPS[@]}"; do
    out=$(timeout 15 ssh $SSH_KEY_ARGS -o BatchMode=yes -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o ConnectTimeout=6 "root@$host" \
            "cut -d' ' -f1 /proc/uptime" 2>/dev/null) || continue
    case "$out" in
      [0-9]*) say "  link is up via $host (device uptime ${out}s)"; return 0 ;;
    esac
  done
  return 1
}

report
if [ "$STATUS_ONLY" = 1 ]; then
  if link_ok; then exit 0; else say "  status: the link is NOT carrying traffic"; exit 1; fi
fi
if link_ok; then say "nothing to do"; exit 0; fi
say "the link is not carrying traffic -- escalating"

# ---- 1. interface up + addresses -----------------------------------------------------------------
say "step 1: bring usb0 up and re-apply the host addresses"
if [ -e /sys/class/net/usb0 ]; then
  ip link set usb0 up 2>/dev/null || true
  for a in "${HOST_IPS[@]}"; do
    ip addr show dev usb0 2>/dev/null | grep -q "${a%%/*}" || ip addr add "$a" dev usb0 2>/dev/null || true
  done
  sleep 2
  link_ok && { say "recovered at step 1"; exit 0; }
else
  say "  usb0 does not exist yet -- step 2 will create it"
fi

# ---- 2. rebind rndis_host -----------------------------------------------------------------------
say "step 2: unbind/rebind rndis_host on the gadget's interfaces"
ifaces=$(ls -d /sys/bus/usb/devices/"$dev":* 2>/dev/null | sed 's|.*/||')
for i in $ifaces; do
  [ -e /sys/bus/usb/drivers/rndis_host/"$i" ] && echo "$i" > /sys/bus/usb/drivers/rndis_host/unbind 2>/dev/null || true
done
sleep 1
for i in $ifaces; do
  [ -e /sys/bus/usb/drivers/rndis_host/"$i" ] || echo "$i" > /sys/bus/usb/drivers/rndis_host/bind 2>/dev/null || true
done
sleep 3
[ -e /sys/class/net/usb0 ] && {
  ip link set usb0 up 2>/dev/null || true
  for a in "${HOST_IPS[@]}"; do
    ip addr show dev usb0 2>/dev/null | grep -q "${a%%/*}" || ip addr add "$a" dev usb0 2>/dev/null || true
  done
}
sleep 2
link_ok && { say "recovered at step 2"; exit 0; }

# ---- 3. re-enumerate the gadget -------------------------------------------------------------------
# `authorized` is the kernel's own switch for "may this device be used". Toggling it makes the host
# re-enumerate from scratch, which is what revives a data channel that is stuck with clean counters
# on both sides. It does not cut power, and it does not touch anything inside the device.
say "step 3: re-enumerate the gadget (authorized 0 -> 1). This is what fixed the 2026-09-23 stall."
echo 0 > /sys/bus/usb/devices/"$dev"/authorized 2>/dev/null || say "  could not write authorized=0"
sleep 3
echo 1 > /sys/bus/usb/devices/"$dev"/authorized 2>/dev/null || say "  could not write authorized=1"
sleep 5
[ -e /sys/class/net/usb0 ] && {
  ip link set usb0 up 2>/dev/null || true
  for a in "${HOST_IPS[@]}"; do
    ip addr show dev usb0 2>/dev/null | grep -q "${a%%/*}" || ip addr add "$a" dev usb0 2>/dev/null || true
  done
  sleep 2
}
link_ok && { say "recovered at step 3"; exit 0; }

# ---- 4. last resort: rebind the whole USB device --------------------------------------------------
if [ "$FORCE" != 1 ]; then
  say "step 4 (whole-device unbind/rebind) NOT attempted -- pass --force to try it"
  say "everything else has failed; report this and consider a physical power cycle"
  report
  exit 1
fi
say "step 4 (--force): unbind/rebind the USB device itself"
echo "$dev" > /sys/bus/usb/drivers/usb/unbind 2>/dev/null || say "  could not unbind $dev"
sleep 4
echo "$dev" > /sys/bus/usb/drivers/usb/bind   2>/dev/null || say "  could not bind $dev back"
sleep 6
[ -e /sys/class/net/usb0 ] && {
  ip link set usb0 up 2>/dev/null || true
  for a in "${HOST_IPS[@]}"; do
    ip addr show dev usb0 2>/dev/null | grep -q "${a%%/*}" || ip addr add "$a" dev usb0 2>/dev/null || true
  done
  sleep 2
}
if link_ok; then say "recovered at step 4"; exit 0; fi

say "could not recover the link from the host. The device is very likely still running (check whether"
say "the gadget still answers USB control requests); the next step is a power cycle by hand."
report
exit 1
