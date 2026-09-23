#!/bin/sh
# zl1-orientation-axes -- which way is the phone, and does the sensor stack agree?
#
# Why this exists (docs 92; it replaces the premise of docs 91's version of this script):
#
#   * The shell sitting in landscape is a real symptom (docs 70/71), and for two docs the
#     guess was "the accelerometer's z is inverted, so a flat screen-up phone is reported
#     as face down (6) instead of face up (5)". That guess is WRONG, and it is checkable
#     offline from the binaries in the rootfs:
#       - sensorfw's own enum (PoseData::Orientation) numbers FaceUp = 6, FaceDown = 5 --
#         the opposite of Qt's QOrientationReading, where FaceUp = 5, FaceDown = 6. So the
#         device reporting 6 for a flat, screen-up phone was CORRECT all along.
#       - OrientationInterpreter::processFace() assigns 6 when z > 0: 6 is the face-up
#         value, by construction.
#       - the QtSensors sensorfw backend translates sensorfw -> Qt through a six-entry
#         table that preserves every NAME (sensorfw 6 FaceUp -> Qt 5 FaceUp).
#       - qtmir handles four of the six Qt values and sends FaceUp/FaceDown to
#         "() - unknown orientation.", leaving m_currentOrientation untouched: a FLAT
#         phone never moves the screen, by design. That is also what the device's own
#         journal shows (docs 70 section 2) -- the steady state is "unknown orientation."
#     So neither the flat phone nor the z sign can explain a landscape screen, and the
#     old "negate z" fix would have changed nothing.
#
#   * What is left is the other two axes, and therefore THIS measurement. The end-to-end
#     chain for this port (native orientation portrait, from the 1080x1920 geometry):
#
#         sensorfw value   name          what the screen gets
#         -------------    -----------   ---------------------------------------------
#              1           LeftUp        Qt::LandscapeOrientation
#              2           RightUp       Qt::InvertedLandscapeOrientation
#              3           BottomUp      Qt::InvertedPortraitOrientation
#              4           BottomDown    Qt::PortraitOrientation
#              5           FaceDown      nothing (qtmir logs "unknown orientation.")
#              6           FaceUp        nothing (qtmir logs "unknown orientation.")
#
#     In sensorfw's vocabulary, rotation is atan(y/...) in portrait mode and atan(x/...)
#     in landscape mode, so BottomUp/BottomDown is the SIGN of y and LeftUp/RightUp the
#     sign of x. With this port's accelerometer convention (verified: a flat screen-up
#     phone reads z ~ +1015 mG, docs 71 section 6), a phone held UPRIGHT IN PORTRAIT
#     should read y ~ +1 g and therefore classify as 4 = BottomDown = Portrait.
#
#     That is the decisive sample, and it is the one no doc has ever taken:
#
#       --portrait-up, value 4  ->  AXES-OK: the axes are where the stack expects them,
#                                   and the landscape is a *latching/delivery* question
#                                   (the last accepted reading was a landscape one and
#                                   nothing corrects it while the phone is flat) -- not
#                                   an axis fault.
#       --portrait-up, value 1 or 2  ->  AXES-SWAPPED: x and y are exchanged (a 90
#                                   confusion), which makes an upright phone classify as
#                                   a landscape position. One line of
#                                   [accelerometer] transformation_matrix.
#       --portrait-up, value 3  ->  AXES-INVERTED: the pair is 180 out; that shows up as
#                                   an upside-down portrait screen.
#       --portrait-up, value 5 or 6  ->  the phone is not upright (it is flat); hold it
#                                   up and run again.
#
# The script also prints, per sample, which axis is carrying the ~1 g, so the table can be
# read against the phone in your hand rather than trusted.
#
# What it does to the device: asks sensorfwd for two sensors and holds the sessions for
# the length of the run, and reads properties. It writes nothing, starts and stops
# nothing, and touches no partition. It does NOT restart the sensor stack -- if the
# accelerometer column looks dead or stale, run scripts/device/zl1-sensors-recover.sh
# first (that is docs 78's ordering, and it is the repair).
#
# Usage: zl1-orientation-axes.sh [--portrait-up] [--flat-up] [--seconds N] [--interval N]
#                                [--explain] [--quiet]
#   --portrait-up  you are telling it the phone is held upright in portrait, screen
#                  facing you -- this is the decisive run
#   --flat-up      you are telling it the phone is lying flat, screen up
#   --seconds N    how long to sample (default 30)
#   --interval N   seconds between samples (default 1)
#   --explain      print the table and the reversible way to try the matrix, then exit
#   --quiet        only the summary and the verdict

set -u

SVC=com.nokia.SensorService
MGR=/SensorManager
SECONDS_TO_RUN=30
INTERVAL=1
PORTRAIT_UP=0
FLAT_UP=0
EXPLAIN=0
QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --portrait-up) PORTRAIT_UP=1; shift ;;
    --flat-up)     FLAT_UP=1; shift ;;
    --seconds)     SECONDS_TO_RUN="${2?--seconds needs a number}"; shift 2 ;;
    --interval)    INTERVAL="${2?--interval needs a number}"; shift 2 ;;
    --explain)     EXPLAIN=1; shift ;;
    --quiet)       QUIET=1; shift ;;
    # The header, whatever its length -- every other script in this tree answers --help this way,
    # and a fixed line range silently truncates (or leaks code) the moment the header changes.
    --help|-h)     awk 'NR==1{next} /^#/{print; next} {exit}' "$0" ; exit 0 ;;
    *) echo "unknown argument $1 (try --help)" >&2; exit 2 ;;
  esac
done

say() { [ "$QUIET" = 1 ] || echo "$*"; }

if [ "$EXPLAIN" = 1 ]; then
  cat <<'EXPLAIN'
The end-to-end table, for this port (native orientation: portrait, from 1080x1920):

   sensorfw   name          Qt (QtSensors)   qtmir -> screen
   --------   -----------   --------------   --------------------------------------
      1       LeftUp        LeftUp(3)        LandscapeOrientation
      2       RightUp       RightUp(4)       InvertedLandscapeOrientation
      3       BottomUp      TopDown(2)       InvertedPortraitOrientation
      4       BottomDown    TopUp(1)         PortraitOrientation
      5       FaceDown      FaceDown(6)      no change ("unknown orientation.")
      6       FaceUp        FaceUp(5)        no change ("unknown orientation.")

  So a flat, screen-up phone reports 6, Qt calls it FaceUp, and qtmir ignores it on
  purpose -- the flat position cannot move the screen. An upright portrait phone should
  report 4 and get PortraitOrientation. Run this script with --portrait-up and read the
  verdict before touching anything. If it says AXES-OK, the axes are fine and the
  landscape is not an accelerometer problem at all.

  If (and only if) it says AXES-SWAPPED or AXES-INVERTED, the candidate fix is one line,
  and it is reversible:

    /etc/sensorfw is a read-only image (docs 64 section 6), so the config cannot be
    edited in place. sensorfwd takes `-c=P, --config-file=<path>` (docs 71 section 7.2),
    so the edit is a copy:

      1. copy the live config to /userdata and change ONE line in [accelerometer]:
           transformation_matrix = "..."    (the value the verdict names)
      2. point the service at it with a drop-in on the writable /etc path
           /etc/systemd/system/sensorfwd.service.d/99-accel-matrix.conf
           [Service]
           ExecStart=
           ExecStart=/usr/sbin/sensorfwd <the original arguments> --config-file=/userdata/sensorfw/sensord.conf
         (repeat the original ExecStart line exactly -- a bare `ExecStart=` empties the
          list, and a drop-in directory that is not named <unit>.service.d is silently
          inert)
      3. restart sensorfwd IN DOCS 78's ORDER, never on its own: a bare
         `systemctl restart sensorfwd` can kill the container's sensors HAL (docs 71
         section 3); scripts/device/zl1-sensors-recover.sh is the fixed sequence, and it
         is also the undo if the stack does not come back.
      4. re-run this script with --portrait-up. The prediction is specific: the same
         upright sample must become 4 (BottomDown), and the shell must go portrait.

    Undo: remove the drop-in, `systemctl daemon-reload`, restart in docs 78's order.
    Nothing outside /userdata and the writable /etc path is written, and no partition or
    boot image is involved.

  This script does not make the change: it changes visible screen behaviour, and the
  verdict has to say AXES-SWAPPED/AXES-INVERTED first.
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
# the orientation property is a (tu): take the uint32. If the punctuation ever changes,
# fall back to the last integer in the reply rather than to nothing.
ov_of() {
  _v=$(printf '%s' "$1" | sed -n 's/.*uint32 \([0-9][0-9]*\).*/\1/p')
  [ -n "$_v" ] || _v=$(printf '%s' "$1" | tr -cs '0-9' '\n' | grep . | tail -1)
  printf '%s' "${_v:-}"
}
# xyz is ((uint64 ts, x, y, z),)-ish and the fields are FLOATS. Drop everything up to the
# first comma (the timestamp), split on commas, and from each field take the integer part:
# on " -1.56" that is -1, on " 1016.0)>,)" that is 1016. Three fields or nothing.
xyz_of() {
  _rest=${1#*,}
  [ "$_rest" != "$1" ] || { printf ''; return; }
  printf '%s' "$_rest" | tr ',' '\n' |
    sed -n 's/^[^0-9-]*\(-\{0,1\}[0-9][0-9]*\).*/\1/p' | tr '\n' ' '
}
# the composition, so the printed value explains itself
consequence() {
  case "$1" in
    1) printf 'Landscape' ;;
    2) printf 'InvertedLandscape' ;;
    3) printf 'InvertedPortrait' ;;
    4) printf 'Portrait' ;;
    5|6) printf 'ignored (face)' ;;
    *) printf 'unknown to qtmir' ;;
  esac
}

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
say "   (an identity matrix means nothing is corrected; see the header for what the"
say "    library does with it, and docs 92 for why that is not this bug)"
say ""

# --- hold sessions for two sensors (the third call, `start`, is the one that matters) ---
sleep "$SECONDS_TO_RUN" & KEEPER=$!
trap 'kill $KEEPER 2>/dev/null' EXIT INT TERM

for n in orientationsensor accelerometersensor; do
  call "$MGR" local.SensorManager.loadPlugin "$n" >/dev/null
  sid=$(call "$MGR" local.SensorManager.requestSensor "$n" "$KEEPER" |
        sed -n 's/^(\([-0-9][0-9]*\),)$/\1/p')
  case "$n" in
    orientationsensor)    call /SensorManager/orientationsensor local.OrientationSensor.start "$sid" >/dev/null ;;
    accelerometersensor)  call /SensorManager/accelerometersensor local.AccelerometerSensor.start "$sid" >/dev/null ;;
  esac
done

say "   uptime    value  -> screen           accel x y z (int part)  |g| axis"
say "  --------   -----  ------------------   ------------------------   ----------"

n4=0; n3=0; n12=0; nface=0; nundef=0; nasample=0
i=0
while [ "$i" -lt "$SECONDS_TO_RUN" ]; do
  o=$(call /SensorManager/orientationsensor org.freedesktop.DBus.Properties.Get local.OrientationSensor orientation)
  a=$(call /SensorManager/accelerometersensor org.freedesktop.DBus.Properties.Get local.AccelerometerSensor xyz)
  ov=$(ov_of "$o")
  xyz=$(xyz_of "$a")
  ax=$(printf '%s' "$xyz" | awk '{print $1}')
  ay=$(printf '%s' "$xyz" | awk '{print $2}')
  az=$(printf '%s' "$xyz" | awk '{print $3}')
  # which axis is carrying the ~1 g, and with which sign -- so the table can be read
  # against the phone in your hand
  axis="?"
  if [ -n "${ax:-}" ] && [ -n "${ay:-}" ] && [ -n "${az:-}" ]; then
    nasample=$((nasample + 1))
    axis=$(awk -v x="$ax" -v y="$ay" -v z="$az" 'BEGIN {
      xm = (x<0 ? -x : x); ym = (y<0 ? -y : y); zm = (z<0 ? -z : z);
      if (zm >= xm && zm >= ym) { printf "z%+d", (z<0 ? -1 : 1) }
      else if (ym >= xm)        { printf "y%+d", (y<0 ? -1 : 1) }
      else                      { printf "x%+d", (x<0 ? -1 : 1) }
    }')
    [ -n "$axis" ] || axis="?"
  fi
  printf '  %8s   %-5s  %-18s   %8s %8s %8s   %s\n' \
    "$(cut -d. -f1 /proc/uptime)" "${ov:-?}" "$(consequence "${ov:-}")" \
    "${ax:-?}" "${ay:-?}" "${az:-?}" "$axis"
  case "${ov:-}" in
    4) n4=$((n4 + 1)) ;;
    3) n3=$((n3 + 1)) ;;
    1|2) n12=$((n12 + 1)) ;;
    5|6) nface=$((nface + 1)) ;;
    0|'') nundef=$((nundef + 1)) ;;
  esac
  i=$((i + INTERVAL))
  [ "$i" -lt "$SECONDS_TO_RUN" ] && sleep "$INTERVAL"
done

say ""
say "samples with a value: 4(BottomDown)=$n4  3(BottomUp)=$n3  1/2(LeftUp/RightUp)=$n12" \
    " 5/6(face)=$nface  none/0=$nundef   accel samples=$nasample"
say ""

# --- no flag: just the measurement, no verdict ---------------------------------------
if [ "$PORTRAIT_UP" = 0 ] && [ "$FLAT_UP" = 0 ]; then
  say "That is the measurement, but not the verdict: it does not know where the phone was."
  say "The decisive run is --portrait-up, with the phone held upright in portrait, screen"
  say "facing you: an upright phone should read 4 (BottomDown -> Portrait). See the header,"
  say "or run --explain for the table and the reversible way to try the matrix."
  exit 0
fi

# No verdict can be trusted if the accelerometer column never parsed: the value alone
# cannot say which way the phone was, and a half-dead stack is docs 78's fault, not this
# one. This is the check that would have caught the first version of this script.
if [ "$nasample" = 0 ]; then
  say "No accelerometer sample parsed at all, so the orientation value cannot be read"
  say "against the phone's actual pose -- and no verdict here would mean anything. If the"
  say "accel column is '?' on every line, the sensor stack is the docs 78 fault: run"
  say "scripts/device/zl1-sensors-recover.sh and then this again."
  exit 1
fi

# --- flat: documented, and it cannot move the screen ---------------------------------
if [ "$FLAT_UP" = 1 ]; then
  if [ "$nface" -ge 1 ] && [ "$n12" = 0 ] && [ "$n3" = 0 ] && [ "$n4" = 0 ]; then
    say "FLAT, and the value is a face value (5 or 6) -- which is what a flat phone should"
    say "report. Note what that means: qtmir ignores both of the face values by design, so"
    say "THIS MEASUREMENT CANNOT DECIDE ANYTHING. A flat phone never moves the screen, and"
    say "\"6\" is not a face-down/inverted reading -- sensorfw numbers FaceUp as 6 and"
    say "Qt numbers it 5, and the sensorfw backend translates between them by name (docs"
    say "92). If the shell is landscape right now, the cause is elsewhere: run again with"
    say "--portrait-up, and read docs 92 section 1."
    exit 0
  fi
  say "You said the phone was flat, but the value is not a face value (5/6). Either the"
  say "phone is not flat (|z| has to dominate for processFace to fire at all), or the"
  say "stack is not reporting. Keep the table above."
  exit 2
fi

# --- portrait: the decisive verdict ---------------------------------------------------
if [ "$n4" -ge 1 ] && [ "$n12" = 0 ] && [ "$n3" = 0 ]; then
  say "AXES-OK. You said the phone was upright in portrait, and it reported 4 = BottomDown,"
  say "which is exactly what this stack expects (rotation is atan(y/...) in portrait mode,"
  say "and 4 is the y > 0 case). The chain turns that into Qt::PortraitOrientation, so the"
  say "accelerometer axes are NOT the reason the shell sits landscape, and the identity"
  say "[accelerometer] transformation_matrix is not a defect. What remains is latching:"
  say "qtmir only moves the screen for the four edge positions, and while the phone lies"
  say "flat it gets FaceUp/FaceDown and changes nothing (docs 92 section 1). Keep this"
  say "output -- it rules out the whole axis family of explanations."
  exit 0
fi

if [ "$n12" -ge 1 ] && [ "$n4" = 0 ] && [ "$n3" = 0 ]; then
  say "AXES-SWAPPED. You said the phone was upright in portrait, and it reported 1 or 2"
  say "(LeftUp/RightUp) -- a landscape position. With the phone held the way you say, that"
  say "means x and y are exchanged somewhere before the classifier: sensorfw decides"
  say "portrait vs landscape by the sign of y and atan(y/...) while the phone is upright,"
  say "so if it sees x instead, an upright phone looks like a phone on its side. Candidate"
  say "fix: an [accelerometer] transformation_matrix that swaps the two -- run --explain"
  say "for the reversible procedure, and do not make the change from this output alone:"
  say "the phone must have been still, upright and screen-facing-you for the whole run."
  exit 3
fi

if [ "$n3" -ge 1 ] && [ "$n4" = 0 ] && [ "$n12" = 0 ]; then
  say "AXES-INVERTED. You said the phone was upright in portrait, and it reported 3"
  say "(BottomUp) -- the same axis, 180 out. That shows up as an upside-down portrait"
  say "screen, not as landscape: y is negated, so 4 and 3 are swapped. Candidate fix: a"
  say "transformation_matrix negating y (see --explain). Check that the phone was really"
  say "screen-up and upright and not, say, upside down on a stand."
  exit 4
fi

if [ "$nface" -ge 1 ] && [ "$n4" = 0 ] && [ "$n3" = 0 ] && [ "$n12" = 0 ]; then
  say "Not upright. Every sample is a face value (5/6), which means the phone was flat"
  say "(|z| >= 300 mG dominates and processFace took over). Hold it upright in portrait,"
  say "screen facing you, and run again -- that is the only run that decides anything."
  exit 5
fi

say "Mixed or empty. Read the table above: while the phone is still, one value should"
say "dominate. If nothing ever arrives (accel samples = 0, or the accel column is ?), the"
say "stack is the docs 78 fault, not this one -- run scripts/device/zl1-sensors-recover.sh"
say "first. If values with no accel accompaniment alternate, that is worth keeping as-is;"
say "compare it against docs 70 (the power-key replay) and docs 92."
exit 2
