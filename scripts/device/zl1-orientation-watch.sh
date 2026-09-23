#!/bin/sh
# zl1-orientation-watch -- watch the orientation sensor while you pick the phone up.
#
# Why this exists: "orientationsensor never produces" was on the port's broken list for two docs
# (70/71). It is not broken. Asked what it is, sensorfw answers:
#
#   description: "orientation of the device screen as 6 pre-defined positions"
#   type:        OrientationSensorChannel
#
# **CORRECTED (docs 91):** this value is NOT Android's DEVICE_ORIENTATION sensor (HIDL type 25) passed
# through. It is sensorfw's own `local.OrientationSensor`, and its chain is `orientationchain` =
# `accelerometerchain` + `orientationinterpreter` -- i.e. it is computed from the ACCELEROMETER. The
# adaptors in this package that are *named* orientation/rotation/georotation emit `CompassData`
# (degrees), so they cannot be producing a 1..6 position. Which matters here for one reason: it means
# the pair printed below is not two independent sensors, it is a value and its own input -- so when
# they disagree, `[accelerometer] transformation_matrix` (the identity today) is the one candidate,
# and `scripts/device/zl1-orientation-axes.sh` is the read-only way to decide it.
#
# What is unchanged: it is a **classifier of six discrete positions** (1 portrait, 2 landscape, 3
# reverse portrait, 4 reverse landscape, 5 face up, 6 face down), not a stream of angles, and a
# classifier of positions is **on-change by definition**: while the phone sits still there is nothing
# to report, so a probe that reads twice and sees the same value is describing correct behaviour, not
# a fault. The continuous sources are `rotationsensor` (x/y/z rotation in degrees) and `compasssensor`
# (north in degrees), both of which stream.
#
# So the question stops being "why is it silent" and becomes "what does it say, and is that right".
# This prints the classifier's value next to the accelerometer's, once a second, so the answer is a
# 30-second test anyone can do: run it, pick the phone up, turn it over, watch both columns.
#
#   * the classifier updates only when the position *changes* -- and it reports the new position,
#     not a rate, so a long run of identical lines is the expected shape while the phone is still;
#   * the accelerometer column is NOT an independent sensor (docs 91 -- it is this value's own input),
#     but it is still the right comparison: |z| ~ 1000 mG with +z means face up, -z face down, and
#     5 = face up, 6 = face down. If a flat, screen-up phone gives +z and the classifier says 6, the
#     two disagree, and that matters, because qml/`qtmir` reads THIS value to decide the shell's
#     orientation -- which is where the port's "it keeps going landscape" behaviour comes from
#     (docs 70/71). Use zl1-orientation-axes.sh for that verdict; this script is the wider watch.
#
# What it does to the device: asks `sensorfwd` for two sensors and holds the sessions for the length
# of the run, and reads properties. It writes nothing, starts and stops nothing, and touches no
# partition. It does NOT restart the sensor stack -- if every sensor is stale, use
# scripts/device/zl1-sensors-recover.sh first.
#
# Usage: zl1-orientation-watch.sh [--seconds N] [--interval N] [--quiet]
#   --seconds N   how long to watch (default 60)
#   --interval N  seconds between samples (default 1)

set -u

SVC=com.nokia.SensorService
MGR=/SensorManager
SECONDS_TO_WATCH=60
INTERVAL=1
QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --seconds)  SECONDS_TO_WATCH="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --quiet)    QUIET=1; shift ;;
    # --help prints this file's own header: the header IS the manual (it carries the Usage line),
    # and the length of it is not something a fixed line range can know.
    --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0" ; exit 0 ;;
    *) echo "unknown argument $1 (try --help)" >&2; exit 2 ;;
  esac
done

say() { [ "$QUIET" = 1 ] || echo "$*"; }
# this is the zl1 or it is not
case "$(tr -d '\0' < /proc/device-tree/model 2>/dev/null)" in
  *"MSM 8996pro + PMI8996 LE_ZL1"*) ;;
  *) echo "error: this is not the zl1" >&2; exit 1 ;;
esac

call() {
  _obj="$1"; _method="$2"; shift 2
  gdbus call --system --dest "$SVC" --object-path "$_obj" --method "$_method" "$@" 2>&1 | tail -1
}
now_us() { awk '{printf "%d", $1 * 1000000}' /proc/uptime; }
# first uint64 of a (timestamp_us, ...) tuple -- "0" means the adaptor never stamps its samples
ts_of() { printf '%s' "$1" | sed -n 's/.*uint64 \([0-9][0-9]*\).*/\1/p'; }
age_of() {
  _t=$(ts_of "$1")
  [ -n "$_t" ] || { printf '?'; return; }
  [ "$_t" = 0 ] && { printf 'never stamped'; return; }
  awk -v n="$(now_us)" -v t="$_t" 'BEGIN { printf "%d", (n - t) / 1000000 }'
}

# The session is what keeps the adaptors running, and sensorfw refcounts by pid, so it has to be
# held by a process that stays alive for the whole run.
sleep "$SECONDS_TO_WATCH" & KEEPER=$!
trap 'kill $KEEPER 2>/dev/null' EXIT INT TERM

for n in orientationsensor accelerometersensor; do
  call "$MGR" local.SensorManager.loadPlugin "$n" >/dev/null
  sid=$(call "$MGR" local.SensorManager.requestSensor "$n" "$KEEPER" |
        sed -n 's/^(\([-0-9][0-9]*\),)$/\1/p')
  if [ "$n" = orientationsensor ]; then
    call /SensorManager/orientationsensor local.OrientationSensor.start "$sid" >/dev/null
    OSID="$sid"
  else
    call /SensorManager/accelerometersensor local.AccelerometerSensor.start "$sid" >/dev/null
  fi
done
say "keeper pid $KEEPER, orientation session $OSID, watching ${SECONDS_TO_WATCH}s (interval ${INTERVAL}s, uptime $(cut -d. -f1 /proc/uptime)s)"
say ""
say "   uptime    orientation  sample age        accelerometer (mG)"
say "  --------   -----------  ----------------  ------------------------------"

i=0
changes=0
prev=""
seen=""
while [ "$i" -lt "$SECONDS_TO_WATCH" ]; do
  o=$(call /SensorManager/orientationsensor org.freedesktop.DBus.Properties.Get local.OrientationSensor orientation)
  a=$(call /SensorManager/accelerometersensor org.freedesktop.DBus.Properties.Get local.AccelerometerSensor xyz)
  ov=$(printf '%s' "$o" | sed -n 's/.*uint32 \([0-9][0-9]*\).*/\1/p')
  printf '  %8s   %-11s  %-16s  %s\n' "$(cut -d. -f1 /proc/uptime)" "${ov:-?}" "$(age_of "$o")" "$(printf '%s' "$a" | sed 's/^.*uint64 [0-9]*, //; s/)>,)$//')"
  [ "$ov" != "$prev" ] && [ -n "$prev" ] && changes=$((changes + 1))
  prev="$ov"
  case " $seen " in *" $ov "*) ;; *) [ -n "$ov" ] && seen="$seen $ov" ;; esac
  i=$((i + INTERVAL))
  [ "$i" -lt "$SECONDS_TO_WATCH" ] && sleep "$INTERVAL"
done

say ""
say "positions seen:${seen:- none}   changes: $changes"
case "$changes" in
  0) say "Nothing changed. If you did not move the phone, that is the classifier working: it reports a"
     say "position, not a rate. Move it (and turn it over) and run this again -- 5 is face up, 6 face"
     say "down, 1 portrait, 2 landscape, 3 reverse portrait, 4 reverse landscape." ;;
  *) say "The classifier changed $changes time(s) while you moved the phone -- it is alive, and the"
     say "value is a position. If a value disagrees with the accelerometer column (|z| ~ 1000 with +z"
     say "means face up, i.e. 5), one of the two frames is wrong; the value above is the one qtmir"
     say "reads to decide the shell's orientation." ;;
esac
