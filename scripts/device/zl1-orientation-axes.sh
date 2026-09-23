#!/bin/sh
# zl1-orientation-axes -- why does the shell go landscape when the phone lies flat?
#
# Why this exists (docs 91): two docs recorded the symptom and neither could name the link that flips
# up/down.
#
#   * doc 71 section 5: the orientation value is 6 while the phone is flat, screen up, and the
#     accelerometer reads z ~ +1015 mG. In the six-position vocabulary that sensorfw's own
#     interpreter uses, 5 is face up and 6 is face down -- so the two disagree.
#   * doc 70 section 5: qtmir maps that value to Qt::InvertedLandscapeOrientation, which is where
#     the user-visible "it keeps going landscape" comes from.
#
# Offline it is possible to say which link *can* be at fault, because the data path is not a guess:
# `local.OrientationSensor` is sensorfw's own object (`liborientationsensor-qt5.so`), its chain is
# `orientationchain`, and that chain joins the **accelerometer** chain plus the
# `orientationinterpreter` filter (`processFace()`, `rotateToPortrait()`, `THRESHOLD_PORTRAIT`, and
# the symbol `accelerometer/orientationinterpreter join failed`). The adaptors in this package that
# are *named* orientation/rotation/georotation emit `CompassData` -- degrees, not a 1..6 position --
# so they cannot be producing this value. Between the adaptor's ring buffer and the classifier the
# only conversion is `[accelerometer] transformation_matrix`, read by `libaccelerometerchain-qt5.so`
# and **the identity** in `30-hidl.conf`. That is the one candidate, and it is one line.
#
# What this script does is measure the pair that decides it, and nothing else:
#
#   accelerometer z (sign and magnitude)   x   the classifier's value (5 or 6)
#
# Both are unambiguous: |z| ~ 1000 with the phone flat, and 5/6 are face up/face down. So:
#
#   z > 0 (screen up, the Android convention) + classifier 6 (face down)  -> the frame reaching the
#                                                                            classifier is inverted
#   z > 0 + classifier 5                                                  -> it agrees; look elsewhere
#
# Therefore: run it with --flat-up while the phone lies flat, screen up, on a table. If the summary
# says INVERTED, the candidate fix is `[accelerometer] transformation_matrix = "1,0,0,0,1,0,0,0,-1"`
# and `--explain` prints the reversible way to try it. This script never makes that change.
#
# It holds two sensor sessions for the length of the run and reads properties. It writes nothing,
# starts and stops no service, and touches no partition. It does NOT restart the sensor stack: if the
# samples are stale (`sample age` in the seconds-to-minutes, or `never stamped`), run
# scripts/device/zl1-sensors-recover.sh first -- that is docs 78's ordering, and it is the repair.
#
# Usage: zl1-orientation-axes.sh [--flat-up] [--seconds N] [--interval N] [--explain] [--quiet]
#   --flat-up      you are telling it the phone is lying flat, screen up, right now
#   --seconds N    how long to sample (default 30)
#   --interval N   seconds between samples (default 1)
#   --explain      print the reversible procedure for the candidate fix, and exit
#   --quiet        only the summary and the verdict

set -u

SVC=com.nokia.SensorService
MGR=/SensorManager
SECONDS_TO_RUN=30
INTERVAL=1
FLAT_UP=0
EXPLAIN=0
QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --flat-up)  FLAT_UP=1; shift ;;
    --seconds)  SECONDS_TO_RUN="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --explain)  EXPLAIN=1; shift ;;
    --quiet)    QUIET=1; shift ;;
    *) echo "unknown argument $1 (try --help)" >&2; exit 2 ;;
  esac
done

say() { [ "$QUIET" = 1 ] || echo "$*"; }

if [ "$EXPLAIN" = 1 ]; then
  cat <<'EXPLAIN'
The candidate fix, and it is reversible:

  /etc/sensorfw is a read-only image (docs 64 section 6), so the config cannot be edited in place.
  sensorfwd takes `-c=P, --config-file=<path>` (docs 71 section 7.2), so the edit is a copy:

    1. copy the live config to /userdata and change ONE line in the [accelerometer] section:
         /etc/sensorfw/sensord.conf            (and sensord.conf.d/30-hidl.conf for the current value)
         transformation_matrix = "1,0,0,0,1,0,0,0,-1"     <- the candidate: negate z
    2. point the service at it with a drop-in on the writable /etc path
         /etc/systemd/system/sensorfwd.service.d/99-accel-matrix.conf
         [Service]
         ExecStart=
         ExecStart=/usr/sbin/sensorfwd <the original arguments> --config-file=/userdata/sensorfw/sensord.conf
       (repeat the original ExecStart line exactly -- a bare `ExecStart=` empties the list, and a
        drop-in directory that is not named <unit>.service.d is silently inert)
    3. restart sensorfwd IN DOCS 78's ORDER, never on its own: a bare `systemctl restart sensorfwd`
       can kill the container's sensors HAL (docs 71 section 3) -- scripts/device/zl1-sensors-recover.sh
       is the fixed sequence, and it is also the undo if the stack does not come back.
    4. re-run this script with --flat-up. The prediction is specific and falsifiable: the same flat,
       screen-up sample classifies as 5 (face up) instead of 6.

  Undo: remove the drop-in, `systemctl daemon-reload`, restart in docs 78's order. Nothing outside
  /userdata and the writable /etc path is written, and no partition or boot image is involved.

  Why this is one line and not a guess: the only conversion between the accelerometer adaptor's
  buffer and the classifier is this matrix (libaccelerometerchain-qt5.so reads
  `accelerometer/transformation_matrix`), and today it is the identity -- i.e. nothing corrects
  anything. The magnetometer section in the same file is NOT the identity (it negates x), which is
  the same kind of correction for the same kind of reason.

This script does not make the change. It is a behaviour change to the running sensor stack, and the
measurement above has to say INVERTED first.
EXPLAIN
  exit 0
fi

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
ts_of() { printf '%s' "$1" | sed -n 's/.*uint64 \([0-9][0-9]*\).*/\1/p'; }
age_of() {
  _t=$(ts_of "$1")
  [ -n "$_t" ] || { printf '?'; return; }
  [ "$_t" = 0 ] && { printf 'never'; return; }
  awk -v n="$(now_us)" -v t="$_t" 'BEGIN { printf "%d", (n - t) / 1000000 }'
}

# --- what the config says the matrix is, so the run carries its own evidence ----------------------
say "== the running configuration (read-only; /etc/sensorfw is a read-only image)"
for f in /etc/sensorfw/sensord.conf /etc/sensorfw/sensord.conf.d/*.conf; do
  [ -f "$f" ] || continue
  _m=$(awk '
    /^\[/ { sec=$0 }
    /^[ \t]*transformation_matrix/ { if (sec ~ /accelerometer/) print $0 }
  ' "$f" 2>/dev/null | sed 's/^[ \t]*//')
  _a=$(awk '/^\[/ { sec=$0 } /^[ \t]*accelerometeradaptor/ { print $0 }' "$f" 2>/dev/null | sed 's/^[ \t]*//')
  [ -n "$_a" ] && say "   $f: $_a"
  [ -n "$_m" ] && say "   $f: $_m"
done
say ""

# --- hold sessions for two sensors (docs 60: this is the third call, `start`, that matters) ------
sleep "$SECONDS_TO_RUN" & KEEPER=$!
trap 'kill $KEEPER 2>/dev/null' EXIT INT TERM

for n in orientationsensor accelerometersensor; do
  call "$MGR" local.SensorManager.loadPlugin "$n" >/dev/null
  sid=$(call "$MGR" local.SensorManager.requestSensor "$n" "$KEEPER" |
        sed -n 's/^(\([-0-9][0-9]*\),)$/\1/p')
  case "$n" in
    orientationsensor)  call /SensorManager/orientationsensor local.OrientationSensor.start "$sid" >/dev/null ;;
    accelerometersensor) call /SensorManager/accelerometersensor local.AccelerometerSensor.start "$sid" >/dev/null ;;
  esac
done

say "   uptime    orient  orient age    accelerometer x y z (mG)                accel age"
say "  --------   ------  -----------   ------------------------------------   ---------"

f5_pos=0; f5_neg=0; f6_pos=0; f6_neg=0; flat=0
i=0
while [ "$i" -lt "$SECONDS_TO_RUN" ]; do
  o=$(call /SensorManager/orientationsensor org.freedesktop.DBus.Properties.Get local.OrientationSensor orientation)
  a=$(call /SensorManager/accelerometersensor org.freedesktop.DBus.Properties.Get local.AccelerometerSensor xyz)
  ov=$(printf '%s' "$o" | sed -n 's/.*uint32 \([0-9][0-9]*\).*/\1/p')
  # The xyz property comes back as a struct wrapped in a variant, and the exact punctuation depends
  # on the gdbus version (`(uint64 123, 5, -3, 1015)`, `(<...>,)`, ...). Rather than pin a shape,
  # take the integers: the timestamp is first and x, y, z are the last three.
  nums=$(printf '%s' "$a" | tr -cs '0-9-' '\n' | grep -v '^$' | grep -v '^-$')
  az=$(printf '%s\n' "$nums" | tail -1)
  ay=$(printf '%s\n' "$nums" | tail -2 | head -1)
  ax=$(printf '%s\n' "$nums" | tail -3 | head -1)
  [ "$(printf '%s\n' "$nums" | grep -c .)" -ge 4 ] || { ax=""; ay=""; az=""; }
  printf '  %8s   %-6s  %-11s   %8s %8s %8s   %s\n' \
    "$(cut -d. -f1 /proc/uptime)" "${ov:-?}" "$(age_of "$o")" "${ax:-?}" "${ay:-?}" "${az:-?}" "$(age_of "$a")"
  # Only |z| >= 800 mG is "flat": 5 and 6 are the face positions, and off-flat the pair says nothing.
  if [ -n "$ov" ] && [ -n "$az" ]; then
    case "$az" in -*) sign=neg ;; *) sign=pos ;; esac
    mag=${az#-}
    if [ "$mag" -ge 800 ] 2>/dev/null; then
      flat=$((flat + 1))
      case "$ov:$sign" in
        5:pos) f5_pos=$((f5_pos + 1)) ;;
        5:neg) f5_neg=$((f5_neg + 1)) ;;
        6:pos) f6_pos=$((f6_pos + 1)) ;;
        6:neg) f6_neg=$((f6_neg + 1)) ;;
      esac
    fi
  fi
  i=$((i + INTERVAL))
  [ "$i" -lt "$SECONDS_TO_RUN" ] && sleep "$INTERVAL"
done

say ""
say "flat samples (|z| >= 800 mG): $flat"
say "   classifier 5 (face up)   with z > 0: $f5_pos      with z < 0: $f5_neg"
say "   classifier 6 (face down) with z > 0: $f6_pos      with z < 0: $f6_neg"
say ""

if [ "$flat" = 0 ]; then
  say "No flat sample. 5 and 6 are the two face positions, so the pair only means something while the"
  say "phone lies flat. Put it flat on a table, screen up, and run again with --flat-up. If every"
  say "sample above is stale (a growing 'accel age', or 0), the stack is the docs 78 fault, not this"
  say "one: run scripts/device/zl1-sensors-recover.sh first."
  exit 1
fi

if [ "$FLAT_UP" = 0 ]; then
  say "That is the measurement, but not the verdict: it does not know where the phone was. Run again"
  say "with --flat-up while the phone lies flat, screen up, on a table (nothing else has to hold"
  say "still -- the classifier reports a position, not a rate)."
  exit 0
fi

# The verdict. Ground truth from --flat-up: the phone is flat, screen up, so the expected value is 5.
# Every branch below is written so that a *counter* decides it, and each fires only on its own
# combination -- an earlier version tested "saw a 6 with z > 0" without requiring "never saw a 6 with
# z < 0", so a run where both signs produced 6 (i.e. the classifier is not tracking the sign at all)
# was reported as the clean INVERTED case. The synthetic run that alternated the sign caught it.
if [ "$f6_pos" -ge 1 ] && [ "$f6_neg" = 0 ] && [ "$f5_pos" = 0 ] && [ "$f5_neg" = 0 ]; then
  say "INVERTED. You said the phone was flat, screen up, and the accelerometer agrees (z > 0, the"
  say "Android convention: +z is out of the screen when the device faces up). The classifier read that"
  say "same stream as 6 = face down. So the frame that reaches the classifier is inverted on z, and"
  say "the only conversion between the accelerometer adaptor's buffer and the classifier is"
  say "[accelerometer] transformation_matrix -- which is the identity above, i.e. nothing is being"
  say "corrected. Candidate fix: \"1,0,0,0,1,0,0,0,-1\".  Run --explain for the reversible way to try"
  say "it; this script does not make the change."
  exit 3
fi

if [ "$f6_pos" -ge 1 ] && { [ "$f5_neg" -ge 1 ] || [ "$f6_neg" -ge 1 ]; }; then
  say "The sign of z moved while the classifier stayed at 6, so the two are not simply opposite. Read"
  say "the table above: what the classifier is tracking is not (only) the sign of z. If the phone did"
  say "not move during the run, that is a real disagreement worth recording -- keep the output."
  exit 2
fi

if { [ "$f5_pos" -ge 1 ] && [ "$f6_pos" = 0 ]; }; then
  say "AGREES. Flat, screen up (z > 0) classified as 5 = face up, which is the right answer. The frame"
  say "is not inverted, so the landscape problem is somewhere else: look at what qtmir does with the"
  say "value (docs 70 section 5 -- 6 maps to InvertedLandscape, and 5 is the value it never saw)."
  exit 0
fi

if [ "$f6_neg" -ge 1 ] && [ "$f6_pos" = 0 ]; then
  say "AMBIGUOUS, and it is the important case: the classifier said 6 = face down while z was"
  say "NEGATIVE for a phone you reported screen up. That means this port's accelerometer reports the"
  say "gravity convention (+z into the screen) rather than Android's. The classifier is then"
  say "*consistent* with its own input, and the question becomes which convention the whole stack is"
  say "written against -- do not change the matrix on this output alone. Keep this table."
  exit 2
fi

say "Mixed. Read the table: with the phone flat and still, one column should be constant. If both"
say "moved, something else is driving the classifier -- keep this output and compare it against"
say "docs/ubuntu-touch/71 (the power-key replay)."
exit 2
