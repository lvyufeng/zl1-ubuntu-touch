#!/bin/sh
# zl1 orientation probe -- offline self-test. Host-side, touches no device.
#
# Why this exists: `scripts/device/zl1-orientation-axes.sh` answers the user's "it keeps going
# landscape" report (docs 70/91/92) and its AXES-SWAPPED / AXES-INVERTED verdict is the ONLY thing that
# licenses an accelerometer matrix trial. The run needs a person: the phone held still, upright in
# portrait, screen facing them, for the whole window -- so a parser bug here wastes a human step, not
# just a command. And the script is mostly parsers: it shells out to `gdbus` and then extracts a uint32
# from one reply and three floats from another with sed/awk (`ts_of`, `ov_of`, `xyz_of`, the |g| axis
# picker), and the verdict is a count of the values that came out.
#
# So this harness puts a stub `gdbus` in front of PATH, feeds the script canned D-Bus replies for every
# posture, and checks the verdict AND the exit code AND the table the human will read. The script under
# test is the real one, sed-rewritten so its device paths point into a fake root.
#
# Usage: zl1-orientation-axes-selftest.sh [--keep]
#   --keep   leave the fake root, the stub and the rewritten script for inspection
#
# Exit codes: 0 every scenario behaved; 1 something did not.

set -u

KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
  --keep) KEEP=1; shift ;;
  --help|-h) sed -n '2,16p' "$0"; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

HERE=$(dirname "$0")
SRC="$HERE/../device/zl1-orientation-axes.sh"
[ -r "$SRC" ] || { echo "cannot read $SRC" >&2; exit 2; }

W=${TMPDIR:-/tmp}/zl1-orient-selftest
FR="$W/fake"
STUB="$W/bin"
REP="$W/replies"
rm -rf "$W"; mkdir -p "$FR" "$STUB" "$REP" || exit 2

# --- the script under test, device paths pointed into the fake root ------------------------------

sed -e "s#< /proc/device-tree/model#< $FR/proc/device-tree/model#g" \
    -e "s#/proc/uptime#$FR/proc/uptime#g" \
    -e "s#for f in /etc/sensorfw/sensord.conf /etc/sensorfw/sensord.conf.d/\*.conf#for f in $FR/etc/sensorfw/sensord.conf $FR/etc/sensorfw/sensord.conf.d/*.conf#g" \
    "$SRC" > "$W/check.sh" || exit 2
sh -n "$W/check.sh" || { echo "the rewritten copy does not parse -- fix that first" >&2; exit 2; }
grep -q "for f in $FR/etc/sensorfw" "$W/check.sh" || { echo "the sensord.conf rewrite did not apply" >&2; exit 2; }

# --- the device state: the model string the script insists on, plus a config to read -------------

mkdir -p "$FR/proc/device-tree" "$FR/etc/sensorfw/sensord.conf.d"
printf 'MSM 8996pro + PMI8996 LE_ZL1\x00' > "$FR/proc/device-tree/model"
printf '412.55 300.10\n' > "$FR/proc/uptime"
cat > "$FR/etc/sensorfw/sensord.conf.d/30-hidl.conf" <<'EOF'
[sensors]
accelerometeradaptor = hidl
[accelerometer]
transformation_matrix = "1,0,0,0,1,0,0,0,1"
EOF

# --- the gdbus stub -----------------------------------------------------------------------------
#
# The script only ever asks the sensor service for three things, so the stub answers by method and
# object path. The two property replies come from files, so each scenario is one file write.

cat > "$STUB/gdbus" <<'STUBEOF'
#!/bin/sh
# stub gdbus: answer com.nokia.SensorService's three calls from $REP, never touch a bus
obj=""; method=""
while [ $# -gt 0 ]; do
  case "$1" in
  --object-path) obj="$2"; shift 2 ;;
  --method)      method="$2"; shift 2 ;;
  *) shift ;;
  esac
done
case "$method" in
org.freedesktop.DBus.Properties.Get)
  case "$obj" in
  */orientationsensor)  cat "$REP/orientation" 2>/dev/null || echo "()" ;;
  */accelerometersensor) cat "$REP/xyz" 2>/dev/null || echo "()" ;;
  *) echo "()" ;;
  esac ;;
local.SensorManager.requestSensor) echo "(7,)" ;;          # the sid the script sed-extracts
local.SensorManager.loadPlugin)    echo "(true,)" ;;
*.start)                           echo "()" ;;
*)                                 echo "()" ;;
esac
STUBEOF
python3 - "$STUB/gdbus" "$REP" <<'PYEOF'
import sys
p, rep = sys.argv[1], sys.argv[2]
s = open(p).read().replace('$REP', rep)
open(p, "w").write(s)
PYEOF
chmod +x "$STUB/gdbus"
grep -q "$REP/orientation" "$STUB/gdbus" || { echo "the stub's reply path did not get baked in" >&2; exit 2; }

# --- scenarios ----------------------------------------------------------------------------------

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }

# a reply for an orientation property: (uint64 ts, uint32 value) -- the shape docs 70 recorded
orient() { printf '(<uint64 %s>, <uint32 %s>)\n' "$1" "$2" > "$REP/orientation"; }
# a reply for xyz: the timestamp first, then three doubles (xyz_of drops everything up to the first comma)
xyz()    { printf '(<uint64 4907939888, %s, %s, %s>,)\n' "$1" "$2" "$3" > "$REP/xyz"; }
xyzraw() { printf '%s\n' "$1" > "$REP/xyz"; }

run() { # $1 = label, rest = arguments
  label="$1"; shift
  # the script polls for --seconds; a loop that never exits is a bug too, and it must fail the test
  # rather than hang the harness (rc 124 = the timeout fired)
  out=$(PATH="$STUB:$PATH" timeout 30 sh "$W/check.sh" "$@" 2>&1); rc=$?
}

want() { # $1 label, $2 wanted rc, $3 wanted substring, $4 description
  if [ "$rc" = "$2" ]; then ok "$1: exit $rc ($4)"; else bad "$1: exit $rc, wanted $2 ($4)"; fi
  case "$out" in
  *"$3"*) ok "$1: verdict says: $4" ;;
  *) bad "$1: no [$3] in the output ($4)"; printf '%s\n' "$out" | tail -6 | sed 's/^/        /' ;;
  esac
}

notwant() { # $1 label, $2 forbidden substring, $3 description
  case "$out" in
  *"$2"*) bad "$1: it DOES say [$2] -- $3" ;;
  *) ok "$1: it does not say [$2] ($3)" ;;
  esac
}

table_has() { # $1 label, $2 ERE the printed table row must match, $3 description
  if printf '%s\n' "$out" | grep -Eq "$2"; then
    ok "$1: the printed table shows $3"
  else
    bad "$1: no table row matches [$2] ($3)"
    printf '%s\n' "$out" | grep -E '^ +[0-9]+ +[0-9?]' | head -3 | sed 's/^/        /'
  fi
}

echo "zl1 orientation probe -- offline self-test"
echo "  script under test: $SRC"
echo "  fake root:         $FR"
echo

echo "== the decisive run: upright portrait =="
orient 4907939888 4; xyz 0.0 9.8 0.0
run "portrait-ok" --portrait-up --seconds 1
want portrait-ok 0 "AXES-OK" "4 = BottomDown, the whole axis family is ruled out"
table_has portrait-ok "^ +[0-9]+ +4 +Portrait " "value 4 and the Qt consequence Portrait"
table_has portrait-ok " y\\+1$" "the axis carrying the ~1 g (y here)"
notwant portrait-ok "AXES-SWAPPED" "an upright phone must not be called swapped"

echo
echo "== 1/2 with the g on x: the axes are exchanged =="
orient 4907939888 2; xyz 9.8 0.0 0.0
run "swapped" --portrait-up --seconds 1
want swapped 3 "AXES-SWAPPED" "the only verdict that licenses a matrix trial"
table_has swapped " x\\+1$" "the g on x while the phone is upright"
table_has swapped "^ +[0-9]+ +2 +InvertedLandscape " "value 2's Qt consequence"

echo
echo "== 3 with the g on y: same axis, 180 out =="
orient 4907939888 3; xyz 0.0 9.8 0.0
run "inverted" --portrait-up --seconds 1
want inverted 4 "AXES-INVERTED" "BottomUp -> an upside-down screen, not landscape"

echo
echo "== flat, and it says so: 6 is a face value, which qtmir ignores by design =="
orient 4907939888 6; xyz 0.0 0.0 9.8
run "flat-face" --flat-up --seconds 1
want flat-face 0 "FLAT, and the value is a face value" "the documented flat conclusion"
table_has flat-face " z\\+1$" "the g on z, which is what makes it a face reading"
notwant flat-face "AXES-SWAPPED" "a flat phone cannot license a matrix change"

echo
echo "== the same flat reading but --portrait-up: the phone was not held up =="
orient 4907939888 6; xyz 0.0 0.0 9.8
run "not-upright" --portrait-up --seconds 1
want not-upright 5 "Not upright" "a face value with --portrait-up is not a verdict"

echo
echo "== the accelerometer reply does not parse: no verdict means anything =="
orient 4907939888 4; xyzraw '(<uint64 4907939888>,)'
run "no-accel" --portrait-up --seconds 1
want no-accel 1 "No accelerometer sample parsed at all" "the guard that caught this script's first version"
table_has no-accel "\\? +\\? +\\? +\\?$" "the accel column printed as unknown"

echo
echo "== the punctuation drift fallback (ov_of takes the last integer when 'uint32' is gone) =="
printf '(<uint64 4907939888>, 4)\n' > "$REP/orientation"; xyz 0.0 9.8 0.0
run "drift" --portrait-up --seconds 1
want drift 0 "AXES-OK" "the value is still read when the reply's punctuation changes"

echo
echo "== no posture flag: measurement only, no verdict =="
orient 4907939888 4; xyz 0.0 9.8 0.0
run "no-flag" --seconds 1
want no-flag 0 "That is the measurement, but not the verdict" "the script refuses to conclude"
notwant no-flag "AXES-OK" "and it does not guess"

echo
echo "== the running configuration it prints (the identity matrix is not this bug) =="
orient 4907939888 4; xyz 0.0 9.8 0.0
run "config" --seconds 1
want config 0 "transformation_matrix" "the matrix line is found in the conf.d file"
case "$out" in
*'accelerometeradaptor = hidl'*) ok "config: the adaptor line is printed too" ;;
*) bad "config: the adaptor line is missing" ;;
esac

echo
echo "== --explain changes nothing and names the two verdicts that license a change =="
run explain --explain
want explain 0 "sensorfwd" "the reversible procedure is printed"
notwant explain "== the running configuration" "it does not run a measurement"

echo
echo "== a value flag with no value must not abort the shell =="
msg=$(sh "$W/check.sh" --portrait-up --seconds 2>&1 >/dev/null | head -1)
case "$msg" in
*"--seconds needs a number"*) ok "'--seconds' with no value -> a message and a clean exit" ;;
*) bad "'--seconds' with no value -> [$msg]" ;;
esac

echo
echo "pass=$PASS fail=$FAIL"
[ "$KEEP" = 1 ] || rm -rf "$W"
[ "$FAIL" = 0 ]
