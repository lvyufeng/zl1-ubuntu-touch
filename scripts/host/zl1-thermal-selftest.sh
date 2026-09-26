#!/bin/sh
# zl1 thermal instrument (+ the health check's heat line) -- offline self-test. Host-side, no device.
#
# Why this exists: "这台机器很容易发烫" is one of the four things this port is for, and the *only*
# instrument for it is scripts/device/zl1-thermal.sh. Every number in docs 72/81 came out of that
# script's arithmetic, and the script had never been run against anything but /proc and /sys on a
# machine whose zones happen to all be milli-degC -- which is the one thing this device is not.
#
# So this drives the real script against a fake device root built from the device's OWN snapshot
# (docs/ubuntu-touch/evidence/thermal-2026-09-22.log), and asserts what a person reads: the per-zone
# table, the `hottest:` line, the A/B deltas, the flags, the exits. It is the same harness shape as
# host/zl1-boot-address-selftest.sh and host/zl1-orientation-axes-selftest.sh: sed-rewrite only the
# *operational* paths of the real script into a fake root, run that copy, assert the output, the exit
# code, and that nothing was written outside the fake root.
#
# The fake root has one thing no real machine has here: **three thermal conventions at once** --
# tsens_tz_sensor* in deci-degC, pm8994_tz/battery in milli-degC, msm_therm/quiet_therm/emmc_therm in
# plain degC -- which is what makes the arithmetic testable at all. The A/B scenario reproduces the
# exact numbers doc 72's conclusion rests on (tsens 558 -> 503 / 580 -> 519), so the assertion is that
# the doc-72 result survives the instrument, not merely that some number changed.
#
# Usage: zl1-thermal-selftest.sh [--keep]
#   --keep   leave the fake root and the rewritten scripts in place for inspection
#
# Exit codes: 0 every scenario behaved; 1 something did not; 2 the harness could not set up.

set -u

KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
  --keep) KEEP=1; shift ;;
  --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0" ; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

HERE=$(dirname "$0")
SRC="$HERE/../device/zl1-thermal.sh"
HC="$HERE/zl1-health-check.sh"
[ -r "$SRC" ] || { echo "cannot read $SRC" >&2; exit 2; }
[ -r "$HC" ] || { echo "cannot read $HC" >&2; exit 2; }

W=${TMPDIR:-/tmp}/zl1-thermal-selftest
FR="$W/fake"
STUB="$W/stub"
rm -rf "$W"
mkdir -p "$FR/proc" "$FR/sys/class/thermal" "$FR/sys/fs/cgroup" "$FR/sys/bus/usb/devices/3-3" \
         "$FR/sys/class/net/usb0" "$FR/sys/devices/system/cpu" "$W/tmp" "$STUB" || exit 2

# --- the fake device root ------------------------------------------------------------------------

# /proc: four cores, a load average, memory, and a loadavg/stat pair the ticker will keep moving.
printf 'processor\t: 0\nprocessor\t: 1\nprocessor\t: 2\nprocessor\t: 3\n' > "$FR/proc/cpuinfo"
printf '9892.55 300.10\n' > "$FR/proc/uptime"
printf '6.76 6.04 5.38 3/412 12345\n' > "$FR/proc/loadavg"
printf 'MemTotal:        3867268 kB\nMemFree:          162120 kB\nMemAvailable:     190000 kB\nSwapTotal:             0 kB\nSwapFree:              0 kB\n' > "$FR/proc/meminfo"
printf 'cpu  200 0 100 4000 20 0 0 0\nctxt 50000\n' > "$FR/proc/stat"

# Four processes. comm never contains a space (the script reads /proc/<pid>/comm, not stat's comm,
# for exactly that reason) and the state sits where the script's strip-and-$1 expects it.
fake_proc() { # pid comm utime stime state
  printf '%s (%s) %s 0 %s %s 0 -1 4194560 100 0 0 0 %s %s 0 0 20 0 1 0 100 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n' \
    "$1" "$2" "$5" "$1" "$1" "$3" "$4" > "$FR/proc/$1/stat"
  printf '%s\n' "$2" > "$FR/proc/$1/comm"
}
mkdir -p "$FR/proc/1" "$FR/proc/812" "$FR/proc/8885" "$FR/proc/1696"
fake_proc 1    systemd     5     3   S
fake_proc 812  keeper      8     2   S
fake_proc 8885 sensorfwd   11    4   S
fake_proc 1696 composer    3     1   D     # the D-state counter has to have something to find

# cpufreq: the governor doc 72 installed, with the frequencies doc 72 recorded.
for c in 0 1 2 3; do
  d="$FR/sys/devices/system/cpu/cpu$c/cpufreq"
  mkdir -p "$d"
  printf 'interactive\n' > "$d/scaling_governor"
  if [ "$c" -lt 2 ]; then printf '307200\n' > "$d/scaling_cur_freq"; printf '1132800\n' > "$d/scaling_max_freq"
  else                   printf '902400\n' > "$d/scaling_cur_freq"; printf '1363200\n' > "$d/scaling_max_freq"; fi
done

# The USB gadget, so the health check's router gets past its first question.
printf '18d1\n'    > "$FR/sys/bus/usb/devices/3-3/idVendor"
printf '4ee7\n'    > "$FR/sys/bus/usb/devices/3-3/idProduct"
printf '33e80afe\n' > "$FR/sys/bus/usb/devices/3-3/serial"
printf 'zl1\n'     > "$FR/sys/bus/usb/devices/3-3/product"
printf 'LeEco\n'   > "$FR/sys/bus/usb/devices/3-3/manufacturer"
printf 'up\n'      > "$FR/sys/class/net/usb0/operstate"
printf '1\n'       > "$FR/sys/class/net/usb0/carrier"

# --- the thermal zones, which is what this harness is about ---------------------------------------
#
# HOT: the device's own snapshot, 2026-09-22, section 7 of the evidence log.
# COOL: the same device five minutes after the debug keeper was SIGSTOPped (section 7 t1) -- the
#       measurement doc 72's conclusion is made of.
hot_zones() {
  mkzone thermal_zone1  tsens_tz_sensor1  558
  mkzone thermal_zone8  tsens_tz_sensor8  580
  mkzone thermal_zone21 pm8994_tz         49125
  mkzone thermal_zone22 battery           42500
  mkzone thermal_zone23 msm_therm         49
  mkzone thermal_zone24 quiet_therm       50
}
cool_zones() {
  mkzone thermal_zone1  tsens_tz_sensor1  503
  mkzone thermal_zone8  tsens_tz_sensor8  519
  mkzone thermal_zone21 pm8994_tz         46434
  mkzone thermal_zone22 battery           42200
  mkzone thermal_zone23 msm_therm         46
  mkzone thermal_zone24 quiet_therm       47
}
mkzone() { # zone-dir-name type raw
  mkdir -p "$FR/sys/class/thermal/$1"
  printf '%s\n' "$2" > "$FR/sys/class/thermal/$1/type"
  printf '%s\n' "$3" > "$FR/sys/class/thermal/$1/temp"
}
clear_zones() { rm -rf "$FR"/sys/class/thermal/thermal_zone*; }
hot_zones

# --- the fixture's clock -------------------------------------------------------------------------
#
# /proc/uptime used to sit at ONE value for the whole harness, and that is not a shape this phone has.
# It silently disabled the clock half of docs 177: every window measured 0.00 s and fell back to the
# requested length, so the fallback was the only path any scenario ever exercised, and the measurement
# itself was never run. Both tickers write .new + mv: the instrument reads these files at arbitrary
# instants, and a torn read of the clock would hand it a window of 9892 seconds.
#
# `clock_loop` moves only the clock (the mean scenario needs nothing else). `rate_loop` also ticks
# /proc/stat and burns ticks in four processes -- but it does NOT walk the whole fake process table on
# every tick, because with 450 fake workers on disk the harness's own ticker would spend the window
# forking, and that load is not the thing being measured. `rate_loop 0` leaves the clock where it is,
# which is how the fallback path gets its own scenario.
clock_loop() {
  cl_n=0
  while [ -f "$W/ticking" ]; do
    printf '%s 0.00\n' "$(cut -d' ' -f1 /proc/uptime)" > "$FR/proc/uptime.new"
    mv "$FR/proc/uptime.new" "$FR/proc/uptime"
    cl_n=$((cl_n + 1))
    sleep 0.05
  done
}
rate_loop() { # $1 = 1 to move the clock too, 0 to leave it frozen
  rl_clock="$1"; rl_n=0
  while [ -f "$W/ticking" ]; do
    if [ "$rl_clock" = 1 ]; then
      printf '%s 0.00\n' "$(cut -d' ' -f1 /proc/uptime)" > "$FR/proc/uptime.new"
      mv "$FR/proc/uptime.new" "$FR/proc/uptime"
    fi
    rl_n=$((rl_n + 1))
    printf 'cpu  %d 0 %d %d %d 0 0 0\nctxt %d\n' \
      $((200 + rl_n * 40)) $((100 + rl_n * 20)) $((4000 + rl_n * 100)) 20 $((50000 + rl_n * 100)) \
      > "$FR/proc/stat.new"
    mv "$FR/proc/stat.new" "$FR/proc/stat"
    for rl_p in 1 812 8885 1696; do
      [ -f "$FR/proc/$rl_p/stat" ] && bump_proc "$FR/proc/$rl_p/stat" 12 6
    done
    sleep 0.05
  done
}

# --- the scripts under test, with only their operational paths moved ------------------------------
#
# `-e "s#/proc/stat#...#"` also rewrites the two /proc/stat literals inside read_stat, which is where
# doc 81's own bug lived (a short format string made the awk abort and left a one-line file). Scenario
# D drives that assertion on purpose.
sed -e "s#/proc/uptime#$FR/proc/uptime#g" \
    -e "s#/proc/loadavg#$FR/proc/loadavg#g" \
    -e "s#/proc/cpuinfo#$FR/proc/cpuinfo#g" \
    -e "s#/proc/stat#$FR/proc/stat#g" \
    -e "s#/proc/meminfo#$FR/proc/meminfo#g" \
    -e "s#/proc/\[0-9\]\*#$FR/proc/[0-9]*#g" \
    -e "s|\${p#/proc/}|\${p#$FR/proc/}|g" \
    -e "s#/sys/fs/cgroup/memory#$FR/sys/fs/cgroup/memory#g" \
    -e "s#/sys/class/thermal/thermal_zone\*#$FR/sys/class/thermal/thermal_zone*#g" \
    -e "s#/sys/devices/system/cpu/cpu\[0-9\]\*#$FR/sys/devices/system/cpu/cpu[0-9]*#g" \
    -e "s|\${c#/sys/devices/system/cpu/}|\${c#$FR/sys/devices/system/cpu/}|g" \
    -e "s#/tmp/zl1-thermal.XXXXXX#$W/tmp/zl1-thermal.XXXXXX#g" \
    "$SRC" > "$W/th.sh" || exit 2
sh -n "$W/th.sh" || { echo "the rewritten instrument does not parse -- fix that first" >&2; exit 2; }
for landed in "$FR/proc/stat" "$FR/proc/[0-9]*" "$FR/sys/class/thermal/thermal_zone*" "$W/tmp/zl1-thermal.XXXXXX"; do
  grep -qF "$landed" "$W/th.sh" || { echo "the rewrite of $landed did not land" >&2; exit 2; }
done
grep -qF "/proc/stat/" "$W/th.sh" && { echo "rewrite is too greedy: it hit a path that is not /proc/stat" >&2; exit 2; }

sed -e "s#/sys/bus/usb/devices#$FR/sys/bus/usb/devices#g" \
    -e "s#/sys/class/net#$FR/sys/class/net#g" \
    "$HC" > "$W/hc.sh" || exit 2
bash -n "$W/hc.sh" || { echo "the rewritten health check does not parse" >&2; exit 2; }

# --- command stubs -------------------------------------------------------------------------------
#
# The health check shells out to ping/ip/ssh. None of them may reach anything here: `ping` and `ip`
# answer for the fake interface, and `ssh` prints the canned device fields -- including the thermal
# line the device-side loop would have produced, so the host-side arithmetic is what gets tested.
# $MARK is replaced with the real path below (a stub that expands an inherited variable would inherit
# the *script's* environment instead of this one -- the trap the orientation harness hit).
cat > "$STUB/ip" <<'EOF'
#!/bin/sh
printf 'ip %s\n' "$*" >> "$MARK/called"
printf 'usb0  UNKNOWN  10.15.19.82/24\n'
EOF
cat > "$STUB/ping" <<'EOF'
#!/bin/sh
printf 'ping %s\n' "$*" >> "$MARK/called"
exit 0
EOF
cat > "$STUB/ssh" <<'EOF'
#!/bin/sh
printf 'ssh %s\n' "$*" >> "$MARK/called"
case "$*" in
*"echo ok"*) echo ok ;;                       # the check that the session answers at all
*)           cat "$MARK/device-fields" ;;
esac
EOF
sed -i "s#\$MARK#$W#g" "$STUB/ip" "$STUB/ping" "$STUB/ssh"
chmod +x "$STUB/ip" "$STUB/ping" "$STUB/ssh"
grep -q "$W/device-fields" "$STUB/ssh" || { echo "the stubs' mark path did not get baked in" >&2; exit 2; }

cat > "$W/device-fields" <<'EOF'
model=M
modelname=LE_ZL1
uptime=9892
kernel=4.4.205
host=le_zl1
failed=0
lxc=12345
outputs=none
unit_sensorfwd=active
unit_repowerd=active
unit_lightdm=active
keeper=
thermal=tsens_tz_sensor1:558 tsens_tz_sensor8:580 pm8994_tz:49125 battery:42500 msm_therm:49 quiet_therm:50
gov=interactive
load=6.76 6.04 5.38
adb=
EOF

# --- the checks ----------------------------------------------------------------------------------

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
want() { # regex, output, description
  if printf '%s\n' "$2" | grep -Eq "$1"; then ok "$3"
  else bad "$3"; printf '%s\n' "$2" | sed 's/^/        | /'; fi
}
notwant() {
  if printf '%s\n' "$2" | grep -Eq "$1"; then bad "$3"; printf '%s\n' "$2" | grep -E "$1" | sed 's/^/        | /'
  else ok "$3"; fi
}
field() { printf '%s\n' "$1" | grep -E "$2"; }

run_th() { # extra args -> stdout in $OUT, exit code in $RC
  OUT=$(timeout 90 sh "$W/th.sh" "$@" 2>&1); RC=$?
}

echo "zl1 thermal instrument -- offline self-test"
echo "  script under test: $SRC"
echo "  fake root:         $FR"
echo

# ==================================================================================================
echo "== 1. the unit table: three conventions in one snapshot =="
# ==================================================================================================
# Before the table existed, this run printed the SoC at 0.6 C/0.0 C and named the battery the hottest
# zone. Every assertion below is a value the evidence log states for that same device instant.

run_th --seconds 1 --quiet
printf '%s\n' "$OUT" > "$W/out.A"

want '^ +thermal_zone8 +tsens_tz_sensor8 +58\.0 C$'            "$OUT" "tsens8 580 -> 58.0 C (deci-degC)"
want '^ +thermal_zone1 +tsens_tz_sensor1 +55\.8 C$'            "$OUT" "tsens1 558 -> 55.8 C"
want '^ +thermal_zone21 pm8994_tz +49\.1 C$'                   "$OUT" "pm8994_tz 49125 -> 49.1 C (milli-degC, unchanged)"
want '^ +thermal_zone22 battery +42\.5 C$'                     "$OUT" "battery 42500 -> 42.5 C"
want '^ +thermal_zone23 msm_therm +49\.0 C$'                   "$OUT" "msm_therm 49 -> 49.0 C (plain degC)"
want '^ +thermal_zone24 quiet_therm +50\.0 C$'                 "$OUT" "quiet_therm 50 -> 50.0 C"
want 'hottest: tsens_tz_sensor8 58\.0 C  \(raw 580 = deci-degC, of 6 zones\)' \
                                                               "$OUT" "the hottest zone is the SoC, named, with its raw value and unit"
# The three shapes the old arithmetic produced. Each is asserted as text that must NOT appear, because
# "0.6 C" is a plausible-looking number and that is exactly what made the bug quiet.
notwant 'tsens_tz_sensor[0-9]+ +0\.[0-9] C'                    "$OUT" "no tsens zone is reported in single-digit C"
notwant 'msm_therm +0\.[0-9] C'                                "$OUT" "msm_therm is not reported as 0.x C"
notwant 'hottest: (pm8994_tz|battery|msm_therm|quiet_therm)'   "$OUT" "the hottest zone is not a board/battery zone"

# ==================================================================================================
echo
echo "== 2. a table that goes stale has to be loud =="
# ==================================================================================================
# zs_temp is not in the table (a driver this port does not have yet); emmc_therm IS, but reporting the
# milli value a driver that switched units would produce. One must be flagged as an assumption, the
# other as implausible -- and the implausible one must not be allowed to win the hottest pick.
clear_zones; hot_zones
mkzone thermal_zone25 zs_temp     41500
mkzone thermal_zone26 emmc_therm  40000

run_th --seconds 1 --quiet
printf '%s\n' "$OUT" > "$W/out.B"

want '^ +thermal_zone25 zs_temp +41\.5 C +<- type not in the unit table' "$OUT" "an unknown type is flagged, not assumed silently"
want '^ +thermal_zone26 emmc_therm +40000\.0 C +<- IMPLAUSIBLE as degC: raw 40000' \
                                                               "$OUT" "a 1000x-mis-scaled zone is flagged IMPLAUSIBLE"
want 'hottest: tsens_tz_sensor8 58\.0 C'                       "$OUT" "an implausible zone does not win the hottest pick"
want 'of 8 zones'                                              "$OUT" "the summary still reports every zone it read"
want '1 implausible, left out of the pick'                     "$OUT" "and says how many it left out of the pick"

echo
echo "   -- and when nothing is believable:"
clear_zones
mkzone thermal_zone26 emmc_therm 40000
run_th --seconds 1 --quiet
want 'hottest: none -- every readable zone was flagged implausible' "$OUT" "it refuses to name a hottest zone rather than inventing one"
clear_zones; hot_zones

# ==================================================================================================
echo
echo "== 3. the A/B has to reproduce the doc 72 measurement, not merely move =="
# ==================================================================================================
# The keeper is SIGSTOPped 5 s in: the zones change to the t1 column of the evidence log, and process
# 812 stops accumulating. This is the shape doc 72 section 6 used, and the numbers here are its numbers.
rm -f "$W/bump-keeper"
: > "$W/bump-keeper"    # window A: the keeper burns
: > "$W/ticking"

bump_proc() { # stat file, utime delta, stime delta
  tf="$1"; du="$2"; ds="$3"
  cur=$(awk '{ sub(/^[^)]*\) /, ""); print $12, $13 }' "$tf")
  cu=${cur% *}; cs=${cur#* }
  pid=${tf%/stat}; pid=${pid##*/}
  comm=$(cat "$(dirname "$tf")/comm")
  state=$(awk '{ sub(/^[^)]*\) /, ""); print $1 }' "$tf")
  fake_proc "$pid" "$comm" $((cu + du)) $((cs + ds)) "$state"
}
tick_loop() {
  n=0
  while [ -f "$W/ticking" ]; do
    n=$((n + 1))
    printf 'cpu  %d 0 %d %d %d 0 0 0\nctxt %d\n' \
      $((200 + n * 40)) $((100 + n * 20)) $((4000 + n * 100)) 20 $((50000 + n * 100)) > "$FR/proc/stat.new"
    mv "$FR/proc/stat.new" "$FR/proc/stat"
    for p in "$FR"/proc/[0-9]*; do
      [ -f "$p/stat" ] || continue
      bump_proc "$p/stat" 4 2
    done
    [ -f "$W/bump-keeper" ] && bump_proc "$FR/proc/812/stat" 40 0
    sleep 0.5
  done
}

tick_loop &
TICKER=$!
sleep 0.5
timeout 90 sh "$W/th.sh" --ab --seconds 2 --hold 6 --top 10 > "$W/out.AB" 2>&1 &
TH=$!
sleep 5
rm -f "$W/bump-keeper"      # "change ONE thing": the keeper stops burning
cool_zones                  # and the device cools, as it did in the evidence log
wait $TH; RC=$?
rm -f "$W/ticking"; wait $TICKER 2>/dev/null
AB=$(cat "$W/out.AB")

[ "$RC" = 0 ] && ok "the A/B run exits 0 (rc=$RC)" || bad "the A/B run exited $RC"
want '^ +thermal_zone8 +tsens_tz_sensor8 +-6\.1 C +\(58\.0 -> 51\.9\)'  "$AB" "tsens8: -6.1 C (58.0 -> 51.9) -- doc 72's headline, not +0.0"
want '^ +thermal_zone1 +tsens_tz_sensor1 +-5\.5 C +\(55\.8 -> 50\.3\)'  "$AB" "tsens1: -5.5 C (55.8 -> 50.3)"
want '^ +thermal_zone23 msm_therm +-3\.0 C +\(49\.0 -> 46\.0\)'         "$AB" "msm_therm: -3.0 C"
want '^ +thermal_zone21 pm8994_tz +-2\.7 C +\(49\.1 -> 46\.4\)'         "$AB" "pm8994_tz: -2.7 C"
want '^ +thermal_zone22 battery +-0\.3 C +\(42\.5 -> 42\.2\)'           "$AB" "battery: -0.3 C"
notwant '\+0\.0 C'                                                       "$AB" "no delta is rounded to +0.0 C"
# Ordering is the part the units used to decide: by RAW values the battery's -300 outranked
# msm_therm's -3, so the second-largest real change sorted last with the largest-looking number.
ABZ=$(printf '%s\n' "$AB" | sed -n '/^== B minus A per thermal zone/,$p')
order=$(printf '%s\n' "$ABZ" | grep -E '^ +thermal_zone[0-9]+ ' | awk '{print $2}' | tr '\n' ' ')
case "$order" in
"tsens_tz_sensor8 tsens_tz_sensor1 "*) ok "the biggest mover comes first (order: ${order% })" ;;
*) bad "delta ordering: got [$order]" ;;
esac
case "$order" in
*"battery ") ok "the smallest mover is last (the battery's 0.3 C drift, not the 6.1 C drop)" ;;
*) bad "expected the battery last, got: [$order]" ;;
esac
want '^ +-[0-9]+ +keeper ' "$AB" "a process that STOPPED burning is reported (it is absent from window B's top list)"

# ==================================================================================================
echo
echo "== 3b. the window's temperature is a MEAN over the window, not its last instant (docs 176/177) =="
# ==================================================================================================
# Six device runs of the paired governor instrument used this table to price the second heat cause and
# printed +2.03 / -0.58 / +2.48 / +5.88 / +2.27 / +2.30 C on one phone on one boot. The table was a
# SINGLE sample of the window's last instant, and thermal_zone18 walked 41.7 -> 45.6 -> 43.7 inside its
# own 48 s window. The fixture below is that shape, made deterministic: the zone steps 800 -> 400
# halfway through a six-sample window, so the mean has to land STRICTLY between them while a snapshot
# can only ever print one end. The span line is alignment-proof -- 400 raw = 40.0 C whatever the
# samples landed on -- which is why the span is asserted exactly and the value only by its range.
mean_scenario() { # $1 = the script to run; leaves the tsens8 value in MEAN_V, the walk in MEAN_W, the output in MEAN_OUT
  clear_zones; hot_zones
  mkzone thermal_zone8 tsens_tz_sensor8 800
  (
    n=0
    while [ "$n" -lt 8 ]; do
      n=$((n + 1))
      if [ "$n" -ge 4 ]; then printf '400\n' > "$FR/sys/class/thermal/thermal_zone8/temp"
      else                   printf '800\n' > "$FR/sys/class/thermal/thermal_zone8/temp"; fi
      sleep 1
    done
  ) &
  ZT=$!
  : > "$W/ticking"
  clock_loop & ZC=$!
  sleep 0.2
  MEAN_OUT=$(timeout 90 sh "$1" --seconds 6 --quiet 2>&1); MEAN_RC=$?
  rm -f "$W/ticking"; wait "$ZC" 2>/dev/null
  wait "$ZT" 2>/dev/null
  MEAN_V=$(printf '%s\n' "$MEAN_OUT" | grep -E '^ +thermal_zone8 ' | awk '{print $3}' | head -1)
  MEAN_W=$(printf '%s\n' "$MEAN_OUT" | sed -n 's/.*walked over \([0-9]*\)s of this window.*/\1/p')
}

mean_scenario "$W/th.sh"
[ "$MEAN_RC" = 0 ] && ok "a window whose zones move still exits 0 (rc=$MEAN_RC)" || bad "that run exited $MEAN_RC"
want '^ +thermal_zone8 +tsens_tz_sensor8 +[0-9.]+ C$' "$MEAN_OUT" "the zone is reported at all"
case "$MEAN_V" in
40.0|80.0) bad "the window reports its LAST instant ($MEAN_V) -- that is the defect docs 177 fixes" ;;
"")        bad "no value for thermal_zone8 at all" ;;
*)         ok "the window reports neither end of the step ($MEAN_V) -- it is an average, not a sample" ;;
esac
awk -v v="$MEAN_V" 'BEGIN { exit !(v + 0 > 40.0 && v + 0 < 80.0) }' \
  && ok "and that value is strictly inside the range the zone moved through" \
  || bad "the value $MEAN_V is not between 40.0 and 80.0"
want 'mean of 6 sample\(s\) walked over [0-9]+s of this window' "$MEAN_OUT" \
     "the table says it is a mean, of how many samples, over how many seconds"
[ "$MEAN_W" = 6 ] && ok "and the walk really spanned the 6s it was asked for (the fixture's clock moves now)" \
                  || bad "the walk spanned ${MEAN_W}s, not 6s -- the fixture's clock is not moving, or a sample's cost was added to its sleep"
want 'the widest zone moved 40\.0 C -- thermal_zone8' "$MEAN_OUT" \
     "and how far the widest zone moved across those samples (400 raw = 40.0 C, alignment-proof)"
want '1 zone\(s\) moved 0\.2 C or more across it' "$MEAN_OUT" \
     "a zone whose own scatter is 40 C is called out, not left for the reader to notice"
# One sample long: the mean has to degrade to exactly the old behaviour rather than to something new.
clear_zones; hot_zones
run_th --seconds 1 --quiet
want 'mean of 1 sample\(s\)'                                   "$OUT" "a one-second window is one sample, and says so"
want '^ +thermal_zone8 +tsens_tz_sensor8 +58\.0 C$'            "$OUT" "and that sample is the reading it always was (58.0 C)"

# ... and the mutation that puts the snapshot back must be caught by the assertions above. The
# mutation is one command NAME: `zone_mean` becomes `zone_read`, which ignores the samples file and
# takes one reading. Proved to have landed before it is trusted (a mutation that silently does not
# apply is a green run that tested nothing).
sed 's#^  zone_mean "\$zmean" > "\$TMP/zones.now"$#  zone_read > "$TMP/zones.now"#' \
  "$W/th.sh" > "$W/th.snapshot.sh"
if grep -q '^  zone_read > "\$TMP/zones.now"$' "$W/th.snapshot.sh"; then
  ok "the snapshot mutation landed in the copy under test"
  mean_scenario "$W/th.snapshot.sh"
  case "$MEAN_V" in
  40.0|80.0) ok "the mutant IS caught: reading one instant prints an end of the step ($MEAN_V)" ;;
  *)         bad "the mutant was NOT caught (it read $MEAN_V) -- these assertions cannot fail" ;;
  esac
else
  bad "the snapshot mutation did not apply -- the run below would prove nothing"
fi
clear_zones; hot_zones

# ==================================================================================================
echo
echo "== 3c. every rate is divided by the seconds the window MEASURED (docs 177) =="
# ==================================================================================================
# The ticks are the difference of two /proc/stat reads that bracket a window made of the zone walk AND
# two walks of /proc; the divisor used to be the number the caller typed. On the device the 38-zone walk
# costs 0.30 s and one walk of 621 processes costs 4.58 s, so `--seconds 10` read /proc/stat 20.7 s apart
# and divided by 10 -- every "/s" this instrument printed was 2.07x the truth. Offline that is visible
# only if the fixture has the two things the device has: a clock that MOVES, and a table worth walking.
# 450 extra pids cost about 1.4 s per walk here, and 400 extra zones make one sample cost about 0.8 s --
# which is also what turns the sample loop's own correction (the sleep is reduced by the sample's cost)
# into a difference rather than a rounding error.
many_procs() {
  i=0
  while [ "$i" -lt "$1" ]; do
    i=$((i + 1))
    mkdir -p "$FR/proc/$((9000 + i))"
    fake_proc "$((9000 + i))" "worker$i" 3 1 S
  done
}
drop_many_procs() { rm -rf "$FR"/proc/9[0-9][0-9][0-9]; }
bulk_zones() {
  i=0
  while [ "$i" -lt "$1" ]; do
    i=$((i + 1))
    mkzone "thermal_zone$((100 + i))" "tsens_tz_sensor$((100 + i))" 450
  done
}
measured_scenario() { # $1 = the script to run, $2 = the seconds to ask for -> MEAS_RC/SUM/TOP/WALK/OUT
  : > "$W/ticking"
  rate_loop 1 & RLP=$!
  sleep 0.3
  MEAS_OUT=$(timeout 120 sh "$1" --seconds "$2" --top 3 2>&1); MEAS_RC=$?
  rm -f "$W/ticking"; wait "$RLP" 2>/dev/null
  MEAS_SUM=$(printf '%s\n' "$MEAS_OUT" | grep -E '^  user .*ticks,')
  MEAS_TOP=$(printf '%s\n' "$MEAS_OUT" | grep -E '^ +[0-9]+ ticks +[0-9.]+/s ' | head -1)
  MEAS_WALK=$(printf '%s\n' "$MEAS_OUT" | sed -n 's/.*walked over \([0-9]*\)s of this window.*/\1/p')
}

many_procs 450
bulk_zones 400
measured_scenario "$W/th.sh" 3
MEAS_X=$(printf '%s\n' "$MEAS_SUM" | sed -n 's/.*ticks, \([0-9.]*\) s measured).*/\1/p')
MEAS_T=$(printf '%s\n' "$MEAS_TOP" | awk '{print $1}')
MEAS_R=$(printf '%s\n' "$MEAS_TOP" | awk '{print $3}' | tr -d '/s')
# The mutants below re-run `measured_scenario`, which overwrites every MEAS_* variable, so the real
# run's walk is kept here before the first mutation can reach it (a mutant compared against itself is
# a check that cannot fail).
REAL_WALK=$MEAS_WALK

[ "$MEAS_RC" = 0 ] && ok "a run on a moving clock exits 0 (rc=$MEAS_RC)" || bad "that run exited $MEAS_RC"
want '\([0-9]+ ticks, [0-9]+\.[0-9] s measured\)' "$MEAS_SUM" \
     "the window prints the seconds it MEASURED, to a decimal -- not the whole number it was asked for"
awk -v x="$MEAS_X" 'BEGIN { exit !(x + 0 > 3.5) }' \
  && ok "and that number is longer than the 3s asked for (${MEAS_X}s): the two walks are inside the window" \
  || bad "the window measured ${MEAS_X}s -- not longer than the 3s it was asked for, so the walks are not being counted"
[ "$MEAS_WALK" = 3 ] \
  && ok "while the SAMPLE walk is the 3s asked for (each sample's cost is subtracted from its own sleep)" \
  || bad "the sample walk spanned [${MEAS_WALK}]s, not 3s"
case "$MEAS_T" in
''|*[!0-9]*) bad "no per-process rate line to check the divisor on" ;;
*) if [ "$MEAS_T" -gt 20 ]; then ok "the fixture's own process burned $MEAS_T ticks in the window"
   else bad "the top row burned only [$MEAS_T] ticks -- too few to divide"; fi ;;
esac
awk -v r="$MEAS_R" -v t="$MEAS_T" -v x="$MEAS_X" 'BEGIN { exit !(r * x > t * 0.99 && r * x < t * 1.01) }' \
  && ok "the printed rate reproduces those ticks over the MEASURED ${MEAS_X}s, and not over anything else" \
  || bad "the printed rate ${MEAS_R}/s x ${MEAS_X}s does not reproduce $MEAS_T ticks -- the divisor is wrong"
awk -v r="$MEAS_R" -v t="$MEAS_T" 'BEGIN { exit !(r * 3 < t * 0.9) }' \
  && ok "and the 3s it was ASKED for would not reproduce them -- the divisor is the measurement, not the request" \
  || bad "the printed rate is the ticks over the 3s asked for, not over the window measured"

# ... and the mutation that puts the wrong bar back, caught by TWO of the assertions above. It is the
# faithful one: the pre-fix source said `secs="$SECONDS_WIN"` in `verdict` and `s="$SECONDS_WIN"` in
# `top_list`, and this restores exactly those two. (It moves the printed number as well as the divisor,
# because `verdict` prints the same variable it divides by -- so both are asserted, and a mutation that
# only moved one of them could not exist here.)
sed -e 's#-v secs="$(wsecs "$label")" #-v secs="$SECONDS_WIN" #' \
    -e 's#awk -v s="$(wsecs "$label")" #awk -v s="$SECONDS_WIN" #' \
    "$W/th.sh" > "$W/th.req.sh"
if grep -q 'secs="\$SECONDS_WIN"' "$W/th.req.sh" && grep -q 'awk -v s="\$SECONDS_WIN"' "$W/th.req.sh"; then
  ok "the requested-bar mutation landed in the copy under test"
  measured_scenario "$W/th.req.sh" 3
  MR_X=$(printf '%s\n' "$MEAS_SUM" | sed -n 's/.*ticks, \([0-9.]*\) s measured).*/\1/p')
  MR_T=$(printf '%s\n' "$MEAS_TOP" | awk '{print $1}')
  MR_R=$(printf '%s\n' "$MEAS_TOP" | awk '{print $3}' | tr -d '/s')
  # The mutant's rate must be EXACTLY the ticks over the 3 s it asked for -- and that same rate over the
  # ${MEAS_X}s the window really measured would be a very different number, which is what makes the
  # divisor visible. (Compared as ratios against the REAL run's window, because the two runs have
  # different tick counts; an absolute comparison here would be two numbers about two different runs.)
  awk -v r="$MR_R" -v t="$MR_T" -v real="$MEAS_X" \
      'BEGIN { exit !(r * 3 > t * 0.99 && r * 3 < t * 1.01 && r * real > t * 1.4) }' \
    && ok "the mutant IS caught: its rate (${MR_R}/s) is exactly the $MR_T ticks over the 3s asked for (over the ${MEAS_X}s measured it would be far higher)" \
    || bad "the mutant was NOT caught (rate ${MR_R}/s, ticks ${MR_T}, real window ${MEAS_X}s) -- these assertions cannot fail"
  awk -v x="$MR_X" -v real="$MEAS_X" 'BEGIN { exit !(x + 0 < real + 0) }' \
    && ok "and the window it PRINTS is the request too ([${MR_X}]s where the real run measured ${MEAS_X}s)" \
    || bad "the mutant printed [${MR_X}]s -- wrong mutation"
else
  bad "the requested-bar mutation did not apply -- the run below would prove nothing"
fi

drop_many_procs
sed 's#^    sleep "\$zl1_rest"$#    sleep 1#' "$W/th.sh" > "$W/th.nosleep.sh"
if grep -q '^    sleep 1$' "$W/th.nosleep.sh"; then
  ok "the uncorrected-sleep mutation landed in the copy under test"
  measured_scenario "$W/th.nosleep.sh" 3
  NS_WALK=$(printf '%s\n' "$MEAS_OUT" | sed -n 's/.*walked over \([0-9]*\)s of this window.*/\1/p')
  case "$NS_WALK" in
  ''|*[!0-9]*) bad "the uncorrected-sleep mutant printed no walk at all" ;;
  *) if [ "$NS_WALK" -ge $((REAL_WALK + 1)) ]; then
       ok "the mutant IS caught: its window walks ${NS_WALK}s for the same 3s asked for (the real one walked ${REAL_WALK}s)"
     else bad "the mutant was NOT caught (walk ${NS_WALK}s vs the real ${REAL_WALK}s) -- the fixture's samples are too cheap to tell"; fi ;;
  esac
else
  bad "the uncorrected-sleep mutation did not apply -- the sample's cost is not being tested"
fi

# Last: the path a STOPPED clock has to take. Everything above runs with a clock that moves, so this is
# the one scenario that leaves it where it is -- and the fixture's own ticker (stat only, no clock) keeps
# the CPU side moving so a rate line still exists to be read. A clock that does not move must not become
# a division by zero, and it must not be reported as a measurement either.
clear_zones; hot_zones
: > "$W/ticking"
tick_loop & TICKER=$!
sleep 0.5
run_th --seconds 2
rm -f "$W/ticking"; wait $TICKER 2>/dev/null
want '\([0-9]+ ticks, 2\.0 s REQUESTED -- the clock did not advance\)' "$OUT" \
     "on a stopped clock the window says REQUESTED, not 'measured'"
want 'REQUESTED length, 2s, and not by a measured one' "$OUT" \
     "and it names the fallback on stderr, where a bar that is not the window has to be visible"
want 'context switches [0-9]+/s' "$OUT" "and it still prints a rate -- a stopped clock is not a division by zero"
[ "$RC" = 0 ] && ok "the stopped-clock run exits 0 (rc=$RC)" || bad "the stopped-clock run exited $RC"

# ==================================================================================================
echo
echo "== 4. read_stat's own guard (doc 81's second bug) =="
# ==================================================================================================
printf 'ctxt 50000\n' > "$FR/proc/stat"
run_th --seconds 1
want 'read_stat got 1 lines, not 2' "$OUT" "a /proc/stat with no aggregate cpu line aborts loudly"
[ "$RC" = 1 ] && ok "and it exits 1 (got $RC)" || bad "it exited $RC, wanted 1"
printf 'cpu  200 0 100 4000 20 0 0 0\nctxt 50000\n' > "$FR/proc/stat"

# ==================================================================================================
echo
echo "== 5. flags, on a shell that has 'set -u' =="
# ==================================================================================================
msg=$(sh "$W/th.sh" --seconds 2>&1 >/dev/null | head -1)
case "$msg" in
*"--seconds needs a number"*) ok "'--seconds' with no value -> a message naming the flag" ;;
*) bad "'--seconds' with no value -> [$msg]" ;;
esac
case "$msg" in
*"parameter not set"*|*"unbound variable"*) bad "'--seconds' aborted the shell: $msg" ;;
*) ok "'--seconds' with no value does not abort the shell" ;;
esac
sh "$W/th.sh" --help > "$W/help" 2>&1
want 'zl1-thermal.sh --ab --hold 30' "$(cat "$W/help")" "--help prints the usage block"
sh "$W/th.sh" --nope > "$W/nope" 2>&1
[ $? = 2 ] && ok "an unknown argument exits 2" || bad "an unknown argument did not exit 2"
want 'deci-degC' "$(sed -n '2,49p' "$SRC")" "the usage block itself carries the unit trap (the next reader needs it)"

run_th --seconds 1 --quiet
notwant '^== window A, top' "$OUT" "--quiet keeps the per-process table out"
want '== cpufreq:'          "$OUT" "--quiet keeps the rest of the report"

# ==================================================================================================
echo
echo "== 6. read-only: nothing written outside the fake root, nothing left behind =="
# ==================================================================================================
before=$(find "$FR" -printf '%p %s %T@\n' 2>/dev/null | sort | md5sum)
run_th --seconds 1 --quiet
after=$(find "$FR" -printf '%p %s %T@\n' 2>/dev/null | sort | md5sum)
[ "$before" = "$after" ] && ok "the fake /proc and /sys are byte-identical after a run" \
                        || { bad "a run wrote into the fake device root"; find "$FR" -newer "$W/out.A" -printf '        | %p\n'; }
[ -z "$(ls -A "$W/tmp" 2>/dev/null)" ] && ok "the script's temp dir is removed on exit (the EXIT trap works)" \
                                       || bad "left behind: $(ls -A "$W/tmp")"

# ==================================================================================================
echo
echo "== 7. the health check's heat line, on the same zones =="
# ==================================================================================================
# The first number a person reads after a rescue. It used to read thermal_zone1 -- a tsens sensor --
# and divide by 1000, so it said "0.6 C" while the SoC was at 55.8 C.
clear_zones; hot_zones
run_th --seconds 1 --quiet        # the instrument, on the same zones, for the agreement check
rm -f "$W/called"
HC_OUT=$(PATH="$STUB:$PATH" ZL1_HOST=root@10.15.19.82 timeout 60 bash "$W/hc.sh" 2>&1); HC_RC=$?

# --- the page must PRINT its prose, not RUN it ----------------------------------------------------
#
# Found on 2026-09-24 by a stray empty file in the repository root, and the cause is a shell trap that
# this page walked into seven times: **backticks inside a double-quoted string are command
# substitution**, so every emphasised word in the page's prose was being executed as a command when the
# line was printed. Three real symptoms, none of them visible in stdout: `\`/\`` ran `bash: /: Is a
# directory` and the printed sentence silently LOST the character; `` `tr | grep | sed ||` `` was an
# incomplete command, so the substitution failed and the rest of that printed line vanished; and
# `` `nsenter -m -- test` `` / `` `systemctl --user status` `` were commands on the host, run by a page
# whose entire purpose is to be read-only. The prose is escaped now (`\``), and the two symptoms are
# checked HERE, behaviourally, because a grep for a backtick would have to re-implement the quoting
# rules it is trying to police: the page is run in a directory of its own with stderr kept SEPARATE,
# and both must come back empty -- an executed fragment lands in one or the other.
HC_CWD="$W/cwd"; mkdir -p "$HC_CWD"
( cd "$HC_CWD" && PATH="$STUB:$PATH" ZL1_HOST=root@10.15.19.82 timeout 60 bash "$W/hc.sh" \
    > /dev/null 2> "$W/hc.err" )
if [ -s "$W/hc.err" ]; then
  bad "the page writes to stderr -- its prose may be executing (first line: $(head -1 "$W/hc.err"))"
else
  ok "the page prints its prose without executing any of it (stderr is empty)"
fi
HC_LEFTOVER=$(ls -A "$HC_CWD" 2>/dev/null)
[ -z "$HC_LEFTOVER" ] && ok "and it created no file in the directory it ran in" \
  || bad "it left something behind in its working directory: $HC_LEFTOVER"
# The run above only covers the sections THIS fixture reaches. The static half covers the rest: an
# unescaped backtick anywhere in the page's prose is an execution waiting for its line to be printed, so
# it is refused wherever it sits -- every section, not just the ones a fake root can walk into. (When
# this check was written, it failed on the two lines that DOCUMENT the defect: the same trap, twice, in
# the text describing it.)
UNESC=$(grep -nE '^always ".*[^\\]`' "$HC" 2>/dev/null | head -3)
[ -z "$UNESC" ] && ok "and no unescaped backtick survives in the page's prose, printed or not" \
  || { bad "unescaped backticks in the page's prose -- those lines execute when they are printed"
       printf '%s\n' "$UNESC" | sed 's/^/        | /'; }
printf '%s\n' "$HC_OUT" > "$W/out.hc"
want 'thermal: hottest of 6 zones: tsens_tz_sensor8 58\.0 C \(raw 580 = deci-degC\)' "$HC_OUT" \
     "the health check reports the SoC at 58.0 C with its raw value"
# Scoped to the heat line itself, not to the whole output: the router's own *prose* explains the bug it
# used to have ("reported the SoC at 0.6 C"), and an assertion over the whole output would trip on that
# explanation -- which is the brittleness the orientation harness hit with literal substrings.
HC_HEAT=$(printf '%s\n' "$HC_OUT" | grep -E '^   thermal: ' | head -1)
[ -n "$HC_HEAT" ] && ok "the heat line is present and labelled" || bad "no 'thermal:' line"
notwant 'thermal_zone1' "$HC_HEAT" "it no longer reports a zone by its index"
notwant '0\.6 C'        "$HC_HEAT" "and the heat line never prints the 0.6 C it used to"
[ "$HC_RC" = 0 ] && ok "the health check still exits 0 on this fixture" || bad "it exited $HC_RC"
grep -q 'ip -4 -br addr show usb0' "$W/called" 2>/dev/null && ok "it asked the stub for the interface address" \
                                                          || bad "the ip stub was never called"
# The two copies of the table must agree on the same input, which is what stops them drifting: the
# health check scales 6 zones on the host, the instrument scales the same 6 in its own loop.
th_hot=$(printf '%s\n' "$OUT" | grep -E '^   hottest:' )
hc_hot=$(printf '%s\n' "$HC_OUT" | grep -E 'thermal: hottest' )
printf '%s\n' "$th_hot" | grep -q 'tsens_tz_sensor8 58\.0 C' && printf '%s\n' "$hc_hot" | grep -q 'tsens_tz_sensor8 58\.0 C' \
  && ok "the instrument and the health check agree on the hottest zone and its value" \
  || bad "they disagree: instrument [$th_hot] health check [$hc_hot]"

echo
echo "== the health check cites this harness's count, and that citation cannot drift =="
# `host/zl1-health-check.sh` is the first thing a human reads, and it names each harness WITH A CHECK
# COUNT. Those counts are typed by hand, so every time a harness gains an assertion its citation goes
# stale -- and a stale count in the first thing a reader sees is the same defect family as every other
# one in this project: an instrument whose report does not match its subject. It happened (the GPS
# citation still said 99 long after that harness had grown past 120) and nothing would ever have
# noticed, so every harness the health check cites now checks its own citation.
#
# No device needed: at this point PASS and FAIL are final, so this harness knows its own total.
HEALTH="$HERE/zl1-health-check.sh"
if [ -r "$HEALTH" ]; then
  cited=$(sed -e 's/always "/ /g' -e 's/"$//' "$HEALTH" | tr '\n' ' ' |
            sed -n 's/.*zl1-thermal-selftest.sh[ ,(]*\([0-9][0-9]*\) checks.*/\1/p')
  total=$((PASS + FAIL + 1))
  if [ -z "$cited" ]; then
    bad "the health check no longer cites this harness's count -- either the citation is gone or its wording changed"
  elif [ "$cited" = "$total" ]; then
    ok "the health check cites $cited checks, and this run has exactly that many"
  else
    bad "the health check cites $cited checks, but this harness has $total -- fix host/zl1-health-check.sh"
  fi
else
  bad "cannot read $HEALTH -- its citations are unchecked"
fi

echo
echo "pass=$PASS fail=$FAIL"
[ "$KEEP" = 1 ] || rm -rf "$W"
[ "$FAIL" = 0 ]
