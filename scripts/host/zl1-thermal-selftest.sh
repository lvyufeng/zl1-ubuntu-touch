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
