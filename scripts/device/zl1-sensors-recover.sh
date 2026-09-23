#!/bin/sh
# zl1-sensors-recover -- bring the sensor stack back on the zl1 **without a reboot**.
#
# Why this exists (measured 2026-09-23, docs/ubuntu-touch/78-*.md and its evidence log):
#
#   For 8.2 hours every sensor on this port was STALE, and the reason was not the hardware, the
#   kernel or the SLPI: the container's sensors HAL had been replaced by init (uptime ~12.37 ks)
#   and the new instance was wedged inside one HIDL call -- the kernel's binder dump showed a
#   two-way `ISensors::batch()` (method code 4) sent by sensorfwd that the HAL had accepted and
#   never returned from, its main thread parked on a userspace futex. sensorfwd was holding a
#   proxy to a HAL that would never answer, so every property stayed at its last value.
#
#   The state is recoverable in a fixed order, and the order is the whole point:
#
#     1. kill the container's sensors HAL and let init start a fresh one. Its service name is
#        vendor.sensors-hal-1-0 (`class hal`, no oneshot, so init always restarts it).
#     2. WAIT until the fresh HAL is registered again -- its ISensors node exists in the binder
#        dump and hwservicemanager holds it.
#     3. only then restart sensorfwd, so the new client calls getService() when a live server is
#        already there.
#
#   Step 3 is the step docs/ubuntu-touch/71 tells you not to do, and the reason it is safe here is
#   the order. That doc measured (6/6) that sensorfwd's shutdown can take the HAL down with it --
#   the HAL logs `ISensors::poll() re-entry ... killing myself` when a client vanishes mid-poll --
#   and concluded, correctly, that a restart is a coin flip: whichever of the two registers first
#   decides whether anything streams. Doing step 1 first removes the coin: by step 3 the server is
#   already up, and the client is not polling a live HAL at the moment it stops (it is holding a
#   dead proxy), so the suicide trigger has nothing to fire on. Measured 2026-09-23: 0 of 1
#   restarts killed the HAL, and accelerometer, gyroscope and magnetometer all came back.
#
# What this does NOT fix: `orientationsensor`. It produced exactly one fresh sample -- 1.8 s after
# sensorfwd restarted, its first in 8.2 hours -- and then stopped again. `alssensor` has still
# never produced a sample at all. Both are reported, not papered over.
#
# Read-only on everything except: the HAL process (SIGKILL, which init is designed to survive) and
# the sensorfwd unit restart. No partition is written, no image is touched, nothing in the
# container's filesystem is modified, and the display is not touched at all.
#
# Usage: zl1-sensors-recover.sh [--status | --recover] [--wait N] [--no-probe] [--quiet]
#
#   --status    only look: the HAL's pid and age, whether anything but hwservicemanager holds its
#               ISensors node, whether an unanswered transaction is sitting on it, and what every
#               sensor's last sample was and how old it is. Changes nothing. (default)
#   --recover   do the three steps above, then probe again and report STREAMING/STALE per sensor.
#   --wait N    seconds to wait for the fresh HAL to re-register (default 30)
#   --no-probe  with --recover, skip the closing probe (the probe holds sessions for a few minutes)
#   --quiet     only the verdict lines
#
# Run it on the device (root@10.15.19.82), next to zl1-sensorfw-probe.sh -- it calls that script
# for the before/after verdict, and refuses to run without it rather than pretending to verify.

set -u

MODE=status
WAIT=30
PROBE=1
QUIET=0
DIR=$(dirname "$0")
PROBESH="$DIR/zl1-sensorfw-probe.sh"
# Every sensor the port knows about. The accelerometer and gyroscope are named explicitly because
# no bus object exists for them until someone asks, so the probe's own enumeration cannot see them.
SENSORS="accelerometersensor gyroscopesensor magnetometersensor orientationsensor"

while [ $# -gt 0 ]; do
  case "$1" in
    --status)  MODE=status; shift ;;
    --recover) MODE=recover; shift ;;
    --wait)    WAIT="$2"; shift 2 ;;
    --no-probe) PROBE=0; shift ;;
    --quiet)   QUIET=1; shift ;;
    # --help prints this file's own header: the header IS the manual (it carries the Usage line),
    # and the length of it is not something a fixed line range can know.
    --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0" ; exit 0 ;;
    *) echo "unknown argument $1 (try --help)" >&2; exit 2 ;;
  esac
done

say() { [ "$QUIET" = 1 ] || echo "$*"; }
STATE=/sys/kernel/debug/binder/state
SVC=com.nokia.SensorService
MGR=/SensorManager

# This is the zl1 or it is not -- never operate on a device identified by anything weaker.
model=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null)
case "$model" in
  *"MSM 8996pro + PMI8996 LE_ZL1"*) ;;
  *) echo "error: this is not the zl1: device-tree model is \"$model\"" >&2; exit 1 ;;
esac

A=$(lxc-info -n android -pH 2>/dev/null | head -1)
[ -n "$A" ] || { echo "error: no android container" >&2; exit 1; }

# comm is truncated to 15 characters by the kernel, which is exactly "sensors@1.0-ser". Matching on
# comm (not on a full command line) also keeps this from matching the pgrep/awk that is looking.
hal_pid() { ps -eo pid,comm 2>/dev/null | awk '$2 ~ /^sensors@1\.0-ser/ {print $1}' | head -1; }
now() { cut -d. -f1 /proc/uptime; }
# Start time of a pid, in seconds of uptime, from /proc/<pid>/stat field 22.
age_of() { awk -v n="$(now)" '{printf "%d", n - $22/100}' "/proc/$1/stat" 2>/dev/null; }

# The section of the binder dump that belongs to one pid. Anchor-tolerant: the dump's lines have
# been seen with trailing whitespace, and `$0 == "proc 938936"` fails on those.
section() {
  awk -v h="$1" 'BEGIN { p = "^proc " h " *$" }
                  $0 ~ p { f = 1; print; next }
                  /^proc / { f = 0 }
                  f { print }' "$STATE" 2>/dev/null
}
holders() { section "$1" | grep -a '^  node ' | sed 's/.*proc //'; }
# The transaction ids the HAL is *inside* right now. A live client always has one in flight while
# its call is being served, so a non-zero count is not by itself a fault -- what makes it the wedge
# is that the same id is still there later and the sample ages say nothing has come out since.
inflight() { section "$1" | sed -n 's/^    incoming transaction \([0-9]*\):.*/\1/p'; }
# ...so: which of them survive a few seconds. POSIX, because this runs under dash on the device.
stuck() {
  _a=$(inflight "$1")
  sleep 5
  _b=$(printf '%s' "$(inflight "$1")" | tr '\n' ' ')
  for _t in $_a; do
    case " $_b " in *" $_t "*) printf '%s ' "$_t" ;; esac
  done
}

probe() {
  if [ ! -f "$PROBESH" ]; then
    echo "error: $PROBESH is missing -- scp both scripts together (it is the verdict)" >&2
    exit 1
  fi
  # The probe needs the session keeper alive for the whole run, so the keep has to outlast
  # n_sensors * (settle + gap).
  set -- --settle 12 --gap 10 --keep 180
  for s in $SENSORS; do set -- "$@" --sensor "$s"; done
  sh "$PROBESH" "$@"
}

status() {
  H=$(hal_pid)
  if [ -z "$H" ]; then
    say "== container sensors HAL: NOT RUNNING (init's service name is vendor.sensors-hal-1-0)"
    say "   getprop init.svc.vendor.sensors-hal-1-0 = $(nsenter -t "$A" -p -m -- /system/bin/getprop init.svc.vendor.sensors-hal-1-0 2>/dev/null)"
    return
  fi
  say "== container sensors HAL: pid $H, age $(age_of "$H") s"
  say "== sensorfwd:             pid $(pgrep -x sensorfwd | tr '\n' ' ') ($(systemctl is-active sensorfwd 2>/dev/null))"
  if [ -r "$STATE" ]; then
    say "== ISensors node held by: $(holders "$H" | tr '\n' ' ')  (40677 is hwservicemanager; any other pid is a client)"
    say "== calls in flight on it: $(inflight "$H" | tr '\n' ' ')"
    say "   still in flight after 5 s: $(stuck "$H")"
    say "   (one in flight is normal while a client's call is being served; the wedge of"
    say "    2026-09-23 was one that never returned -- the same id after 6 s and still after 8.2 h."
    say "    The sample ages from the probe below are the verdict, not this line.)"
  else
    say "== $STATE is not readable -- cannot see the HIDL state (is debugfs mounted?)"
  fi
  say "== uptime: $(now) s"
  [ "$PROBE" = 1 ] && { say ""; probe; }
  return 0
}

recover() {
  H=$(hal_pid)
  [ -n "$H" ] || { echo "error: no container sensors HAL to restart" >&2; exit 1; }
  say "== step 0: before"
  say "   HAL pid $H (age $(age_of "$H") s), node held by: $(holders "$H" | tr '\n' ' ')"
  say "   calls in flight on it: $(inflight "$H" | tr '\n' ' ')"

  say "== step 1: kill the HAL, let init start a fresh one"
  kill -9 "$H"
  N=0
  while [ "$N" -lt "$WAIT" ]; do
    sleep 2
    N=$((N + 2))
    H2=$(hal_pid)
    [ -n "$H2" ] && [ "$H2" != "$H" ] && break
  done
  if [ -z "${H2:-}" ] || [ "$H2" = "$H" ]; then
    echo "error: no new HAL after ${WAIT}s (init's getprop: $(nsenter -t "$A" -p -m -- /system/bin/getprop init.svc.vendor.sensors-hal-1-0 2>/dev/null))" >&2
    exit 1
  fi
  say "   new HAL pid $H2 after ${N}s"

  say "== step 2: wait for it to register (hwservicemanager holding its node)"
  N=0
  while [ "$N" -lt "$WAIT" ]; do
    case " $(holders "$H2" | tr '\n' ' ') " in
      *" 40677 "*) break ;;
    esac
    sleep 2
    N=$((N + 2))
  done
  say "   ISensors node held by: $(holders "$H2" | tr '\n' ' ') after ${N}s"
  case " $(holders "$H2" | tr '\n' ' ') " in
    *" 40677 "*) ;;
    *) echo "error: the fresh HAL is not registered after ${WAIT}s -- stopping here rather than restarting the client against nothing" >&2; exit 1 ;;
  esac

  say "== step 3: now restart the client"
  systemctl restart sensorfwd.service || { echo "error: systemctl restart sensorfwd failed" >&2; exit 1; }
  sleep 5
  say "   sensorfwd pid $(pgrep -x sensorfwd | tr '\n' ' ') ($(systemctl is-active sensorfwd 2>/dev/null))"
  say "   HAL after the restart: $(hal_pid)  (docs 71 SS3: sensorfwd's shutdown can take it down)"
  say "   repowerd: $(pgrep -x repowerd | tr '\n' ' ') ($(systemctl is-active repowerd 2>/dev/null))"

  [ "$PROBE" = 1 ] || return 0
  say ""
  probe
}

say "zl1-sensors-recover: $MODE, uptime $(now) s"
case "$MODE" in
  status)  status ;;
  recover) recover ;;
esac
