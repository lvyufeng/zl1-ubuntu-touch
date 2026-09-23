#!/bin/sh
# Quiet the v63 debug network keeper -- stop it without touching the boot path.
#
# `/usr/local/sbin/zl1-debug-net.sh` (docs 72) is an orphaned `/bin/sh` on this port. Its 1 Hz loop
# runs `systemctl mask --runtime usb-moded.service` and `systemctl stop usb-moded.service` **every
# second**, which makes systemd daemon-reload every ~6 s at ~2 s each, and it costs 6.6% of a core on
# its own. Measured with it SIGSTOPped: **systemd used 1 second of CPU in 300 s**, zero reloads, and the
# SoC fell 5.5/6.1/2.7 C (tsens1/tsens8/pm8994) while the battery was still charging.
#
# **It is stopped with a signal on purpose, not disabled.** The keeper is also what configures `rndis0`
# at boot (`192.168.2.15/24` and `10.15.19.82/24`, announced with `arping -A`), and "a boot without the
# keeper still gets an address" is unverified -- so this script does **not** mask its unit and does not
# change what happens at boot. It cannot: `systemctl` does not manage that process at all, because the
# script daemonizes itself and its unit believes it exited after 67 ms. SIGSTOP is the only handle, and
# it is instantly reversible.
#
# What keeps the network up while it is stopped: `zl1-netwatch.service` (ours). It has a 45 s stall
# detector and a heal path that unbinds/rebinds the RNDIS function and re-applies the addresses
# (`restore_addrs()`), so the exposure is bounded rather than silent -- but read what "bounded" meant
# before 2026-09-23: `restore_addrs()` was reachable **only** from the heal stages, and a heal needs
# 45 s of failed host pings *and* uptime >= 90 s. A keeper-less boot therefore had no address and no
# SSH for ~135 s, and the first thing that fixed it was a full RNDIS re-enumeration (docs 88). The
# netwatch now re-asserts the addresses itself every sample (`ensure_addrs()`, logged as `ADDRS:`),
# which is what makes retiring this keeper a small step instead of a gamble -- and it was installed
# *before* the keeper is retired, so the first boot that proves the new path is a boot where the
# keeper would have done the job anyway.
#
# Before retiring it, run `scripts/device/zl1-boot-address-check.sh` and require the
# `netwatch-configured` verdict (exit 0) on the boot you just looked at.
#
# Usage (on the device): zl1-quiet-debug-keeper.sh --stop | --resume | --status [--wait SECONDS]
#   --stop    SIGSTOP the keeper and verify it is in state T
#   --resume  SIGCONT it (the network is then hammered every second again)
#   --status  print the keeper's state, its CPU over 20 s, and whether reloads are happening
#   --wait N  with --stop, sleep N seconds first (lets a boot bring-up finish)
#
# After a reboot the keeper is running again -- there is nothing persistent here by design; re-run
# `--stop`.

set -u

KEEPER_NAME=zl1-debug-net.sh
FAILS=0

keeper_pids() {
  for p in /proc/[0-9]*; do
    [ -r "$p/cmdline" ] || continue
    c=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
    case "$c" in *"$KEEPER_NAME"*) printf '%s\n' "${p#/proc/}" ;; esac
  done
}

state_of() {
  awk '{print $3}' "/proc/$1/stat" 2>/dev/null
}

cpu_ticks() {
  awk '{print $14+$15}' "/proc/$1/stat" 2>/dev/null
}

show_status() {
  pids=$(keeper_pids)
  if [ -z "$pids" ]; then
    echo "keeper: not running (nothing named $KEEPER_NAME)"
  else
    for p in $pids; do
      st=$(state_of "$p")
      a=$(cpu_ticks "$p"); sleep 20; b=$(cpu_ticks "$p")
      case "$st" in
        T) verdict="STOPPED (signal) -- burning nothing" ;;
        R|S) verdict="RUNNING -- ~$(( (b - a) * 5 ))% of one core, plus a reload every ~6 s" ;;
        *) verdict="state $st" ;;
      esac
      printf 'keeper pid %s: state=%s  cpu over 20s=%s ticks  %s\n' "$p" "$st" "$((b - a))" "$verdict"
    done
  fi
  echo "netwatch (the reactive self-heal that replaces it): $(pgrep -f zl1-netwatch.sh | tr '\n' ' ')"
  echo "last daemon-reload: $(journalctl -b -o short-monotonic --no-pager -n 2000 2>/dev/null | grep 'Reloading requested' | tail -1 | sed 's/.*systemd\[1\]: //')"
  echo "load: $(cut -d' ' -f1 /proc/loadavg)"
}

WAIT=0
ACTION=${1:---status}
[ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
  case "$1" in
    --wait) WAIT="$2"; shift 2 ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done

case "$ACTION" in
  --stop)
    [ "$WAIT" -gt 0 ] && { echo "waiting ${WAIT}s for the boot bring-up to finish first"; sleep "$WAIT"; }
    for p in $(keeper_pids); do
      kill -STOP "$p" 2>/dev/null || { echo "could not SIGSTOP $p"; FAILS=$((FAILS + 1)); continue; }
      echo "SIGSTOP $p -> state $(state_of "$p")"
    done
    [ "$FAILS" = 0 ] || exit 1
    ;;
  --resume)
    for p in $(keeper_pids); do
      kill -CONT "$p" 2>/dev/null && echo "SIGCONT $p -> state $(state_of "$p")"
    done
    ;;
  --status) : ;;
  *) echo "usage: $0 --stop | --resume | --status [--wait SECONDS]" >&2; exit 2 ;;
esac

show_status
