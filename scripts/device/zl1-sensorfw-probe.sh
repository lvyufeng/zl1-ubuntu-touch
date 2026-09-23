#!/bin/sh
# zl1-sensorfw-probe -- ask sensorfw what sensors it has, and whether they are actually streaming.
#
# Why this exists: on 2026-09-22 the accelerometer was reported as "not registered in sensorfw",
# and that was wrong. sensorfw loads sensor *plugins* on demand, and the two calls are separate:
#
#     loadPlugin(name)         -> loads the plugin, returns true/false
#     requestSensor(name, pid) -> asks for a plugin that is ALREADY loaded, returns a session id
#
# Calling requestSensor first answers `-1` with `"requested sensor id 'x' not registered"` --
# which reads exactly like "this device has no sensor x". It means "you did not load it yet".
# The bus objects appear as a side effect of the load, so `busctl tree` shows only the sensors
# someone has already asked for -- again reading like a hardware inventory. This script makes the
# two calls in the right order, and that ordering is the whole point of it existing.
#
# The second half of the question is the one that actually matters: **is the sensor producing
# samples?** `isValid = true` does not distinguish a live sensor from a corpse -- a value captured
# in an earlier boot still has `isValid = true`. sensorfw reports each value as (timestamp_us,
# values...), and that timestamp is the uptime in microseconds at which the *sample* was produced,
# so the honest discriminator is not "did the value change between two reads" but **how old is the
# value**. A sensor whose last sample is 40 s old and one whose last sample is from a previous boot
# (thousands of seconds) both look "frozen" to a two-read test, and they are different diseases.
# So every value is read twice, the age of each reading is printed, and the verdict is:
#
#     STREAMING  a new sample arrived between the two reads
#     SLOW       no new sample in the window, but the last one is recent (adaptor may still be
#                spinning up: the measured first-sample latency after a load is ~10-20 s)
#     STALE      the last sample is old -- printed in seconds, so "40 s" and "from the last boot"
#                are distinguishable at a glance
#
# Two honest caveats, both measured:
#   * **This script perturbs what it measures.** loadPlugin starts adaptors, and an adaptor start
#     is itself what makes this hardware emit a sample (see the docs). So a STREAMING verdict right
#     after a load proves the plugin is wired up, not that the sensor runs continuously by itself.
#   * **Because of that latency, too small a --gap reports a false FROZEN.** The default is 10 s of
#     settle after the load and 8 s between reads; raise `--settle` if a sensor looks dead.
#
# Read-only on the device: it loads plugins and asks for sensors (in-memory state in a running
# daemon) and reads properties. It writes nothing and touches no partition. It never restarts
# sensorfwd -- restarting sensorfwd is what kills the container's sensors HAL (see docs 71).
#
# Usage: zl1-sensorfw-probe.sh [--load-all] [--sensor NAME] [--settle N] [--gap N] [--keep N]
#   --load-all   loadPlugin() for every sensor name sensorfw reports as available, first
#   --sensor N   also test /SensorManager/N even if no bus object for it exists yet (repeatable:
#                a sensor nothing subscribes to cannot be seen by the enumeration)
#   --settle N   seconds to wait after load+request before the first read (default 10)
#   --gap N      seconds between the two readings of each sensor (default 8)
#   --keep N     seconds to hold the requesting session open (default 60). The session is what
#                keeps the adaptor running -- sensorfw refcounts by pid and logs
#                `refs: 0 running: false` when the last one goes away, so too short a --keep can
#                make a live sensor look frozen.

SVC=com.nokia.SensorService
MGR=/SensorManager
SETTLE=10
GAP=8
KEEP=60
LOAD_ALL=0
# Sensors to test even when no bus object for them exists yet. `busctl tree` can only show the
# objects someone has already asked for, so a sensor nothing subscribes to is invisible to the
# enumeration below -- measured 2026-09-23: after a sensorfwd restart the tree held only
# alssensor/magnetometersensor/orientationsensor (what repowerd asks for), and the accelerometer
# and gyroscope could not be measured at all without naming them. --sensor NAME, repeatable.
EXTRA=""

while [ $# -gt 0 ]; do
  case "$1" in
    --load-all) LOAD_ALL=1; shift ;;
    --sensor)   EXTRA="$EXTRA $2"; shift 2 ;;
    --settle) SETTLE="$2"; shift 2 ;;
    --gap)    GAP="$2";    shift 2 ;;
    --keep)   KEEP="$2";   shift 2 ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done

# All arguments matter: loadPlugin takes a name and Properties.Get takes two, so the helper has to
# forward the rest of argv. Passing them inside one string makes gdbus see a method name with
# spaces in it, which fails in a way that looks like the method does not exist.
call() {
  _obj="$1"; _method="$2"; shift 2
  gdbus call --system --dest "$SVC" --object-path "$_obj" --method "$_method" "$@" 2>&1 | tail -1
}

now_us() { awk '{printf "%d", $1 * 1000000}' /proc/uptime; }

# Age of a reading, in seconds, from its (timestamp_us, ...) tuple. Prints "?" when there is no
# timestamp to read (an all-zero value, or an error string).
ts_of() { printf '%s' "$1" | sed -n 's/.*uint64 \([0-9][0-9]*\).*/\1/p'; }
age_of() {
  _ts=$(ts_of "$1")
  [ -n "$_ts" ] || { printf '?'; return; }
  awk -v n="$(now_us)" -v t="$_ts" 'BEGIN { d = (n - t) / 1000000; if (d < 0) d = 0; printf "%d", d }'
}

# One sensor: measure, then say which of the three states it is in.
report() {
  _obj="$1"; _iface="$2"; _prop="$3"
  _settle="$4"; _gap="$5"
  sleep "$_settle"
  _a=$(call "$_obj" org.freedesktop.DBus.Properties.Get "$_iface" "$_prop")
  _agea=$(age_of "$_a")
  sleep "$_gap"
  _b=$(call "$_obj" org.freedesktop.DBus.Properties.Get "$_iface" "$_prop")
  _ageb=$(age_of "$_b")
  printf '    %s.%s\n' "$_iface" "$_prop"
  # "last sample 42000 s ago" is a lie when the timestamp is 0: it means "never stamped", not
  # "stamped at boot". Say which (see the timestamp-0 branch below).
  _tag_a="last sample $_agea s ago"; [ "$(ts_of "$_a")" = 0 ] && _tag_a="no timestamp (the adaptor leaves it 0)"
  _tag_b="last sample $_ageb s ago"; [ "$(ts_of "$_b")" = 0 ] && _tag_b="no timestamp (the adaptor leaves it 0)"
  printf '      read #1: %s   (%s)\n' "$_a" "$_tag_a"
  printf '      read #2: %s   (%s)\n' "$_b" "$_tag_b"
  # An adaptor that never stamps its samples leaves the timestamp at 0, which every age test reads
  # as "never" -- but the value can still be live. Measured 2026-09-23: local.ALSSensor.lux is
  # (0, 94) -> (0, 98) -> (0, 97), i.e. its second field moves while the timestamp stays 0, so the
  # honest answer is "the value moves and the adaptor never stamps it", not "never had a sample".
  if [ "$(ts_of "$_b")" = 0 ]; then
    if [ "$_a" != "$_b" ]; then
      printf '      => STREAMING (the value moves, but the timestamp is 0 -- this adaptor never stamps its samples)\n'
    else
      printf '      => STALE     (timestamp 0: this adaptor never stamps its samples, and the value did not move either)\n'
    fi
  elif [ "$_a" != "$_b" ]; then
    printf '      => STREAMING (a new sample arrived within %ss)\n' "$_gap"
  elif [ "$_ageb" != "?" ] && [ "$_ageb" -lt $(( _gap + _settle + 5 )) ]; then
    printf '      => SLOW      (no new sample in %ss, but the last one is only %ss old)\n' "$_gap" "$_ageb"
  else
    printf '      => STALE     (no new sample in %ss; the last one is %ss old)\n' "$_gap" "$_ageb"
  fi
}

# The session has to be held by a process that stays alive for the whole run.
sleep "$KEEP" &
KEEPER=$!
trap 'kill $KEEPER 2>/dev/null' EXIT INT TERM

echo "sensorfw probe: keeper pid $KEEPER, settle ${SETTLE}s, gap ${GAP}s, keep ${KEEP}s, uptime $(cut -d. -f1 /proc/uptime)s"
echo

if [ "$LOAD_ALL" = 1 ]; then
  echo "=== loadPlugin() for every sensor plugin sensorfw reports as available ==="
  call "$MGR" local.SensorManager.availableSensorPlugins |
    tr -d "[]()'" | tr ',' '\n' | tr -d ' ' | while read -r n; do
      [ -n "$n" ] || continue
      printf '  loadPlugin(%-22s) = %s\n' "$n" "$(call "$MGR" local.SensorManager.loadPlugin "$n")"
    done
  echo
fi

echo "=== the sensors sensorfw currently exports ==="
OBJS=$(busctl --system tree "$SVC" 2>/dev/null |
       sed -n 's/^ *[|`-]*[├└]─ *\(\/SensorManager\/[a-z]*\)$/\1/p' | sort -u)
# ...plus whatever --sensor named, which is the only way to reach a sensor nothing subscribes to.
for _n in $EXTRA; do
  case " $(printf '%s' "$OBJS" | tr '\n' ' ') " in
    *" /SensorManager/$_n "*) ;;
    *) OBJS="$OBJS
/SensorManager/$_n" ;;
  esac
done
OBJS=$(printf '%s\n' "$OBJS" | sed '/^$/d' | sort -u)
if [ -z "$OBJS" ]; then
  echo "  (none -- nothing has been loaded yet; try --load-all)"
  exit 0
fi

for obj in $OBJS; do
  name=${obj##*/}
  printf '\n--- %s\n' "$obj"

  # Load first, then request -- the order that works, and the reason this script exists.
  printf '    loadPlugin(%-20s) -> %s\n' "$name" "$(call "$MGR" local.SensorManager.loadPlugin "$name")"
  printf '    requestSensor(pid %-10s) -> %s\n' "$KEEPER" "$(call "$MGR" local.SensorManager.requestSensor "$name" "$KEEPER")"

  INTRO=$(gdbus introspect --system --dest "$SVC" --object-path "$obj" 2>/dev/null)
  iface=$(printf '%s\n' "$INTRO" | sed -n 's/^ *interface \(local\.[A-Za-z]*Sensor\) {.*/\1/p' | head -1)
  # The value property is the readonly one whose signature starts with `t` (the timestamp) and is
  # not one of the housekeeping fields. Matching on the *signature* rather than on a name list is
  # what keeps this working for sensors whose value property is named something unexpected.
  pname=$(printf '%s\n' "$INTRO" |
          sed -n 's/^ *readonly (\(t[a-z]*\)) \([a-zA-Z]*\) = .*/\2/p' | head -1)
  [ -n "$iface" ] && [ -n "$pname" ] || { printf '    (no timestamped value property)\n'; continue; }

  # requestSensor returns a session id, and the sensor only produces samples once that session is
  # `start()`ed -- requestSensor alone creates the object and the session, not the stream. This is
  # the third call in the sequence and the one that is easiest to forget: without it a perfectly
  # healthy sensor reports a value from the last time *someone else* started it, which reads as
  # "frozen".
  sid=$(call "$MGR" local.SensorManager.requestSensor "$name" "$KEEPER" |
        sed -n 's/^(\([-0-9][0-9]*\),)$/\1/p')
  if [ -n "$sid" ] && [ "$sid" -ge 0 ] 2>/dev/null; then
    printf '    %s.start(%s) -> %s\n' "$iface" "$sid" "$(call "$obj" "$iface.start" "$sid")"
  fi

  report "$obj" "$iface" "$pname" "$SETTLE" "$GAP"
done

echo
echo "STALE means the adaptor is up and the value has not moved; it does not say why. Compare the"
echo "age against the uptime above: an age in the thousands of seconds with an uptime only a few"
echo "thousand seconds means the value came from an earlier boot, i.e. this sensorfw daemon has"
echo "never received a sample from this sensor. If EVERY sensor is STALE and a running container"
echo "sensors HAL is newer than the newest sample, the client is holding a dead proxy -- that state"
echo "is recoverable without a reboot, in a fixed order (kill the HAL, wait for the new one to"
echo "register, THEN restart sensorfwd); scripts/device/zl1-sensors-recover.sh does exactly that,"
echo "and docs/ubuntu-touch/78-*.md has the measurement. Do not restart sensorfwd alone and hope:"
echo "docs/ubuntu-touch/71 SS3/SS4 measured that its shutdown can take the HAL with it (6/6 then,"
echo "0/1 in the 2026-09-23 recovery, where the HAL was restarted first) and that which of the two"
echo "wins the race decides whether anything streams at all."
