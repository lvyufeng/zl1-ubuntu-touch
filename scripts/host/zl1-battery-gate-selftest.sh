#!/bin/sh
# zl1 battery gate -- offline self-test.
#
# Host-side, touches no device. The subject is `scripts/host/zl1-battery-gate.sh`, which reads the two
# variables that gate whether this phone can be powered on at all. The transport is stubbed the way its
# siblings stub ssh -- here the `fastboot` stub IS the bootloader -- and the fake `lsusb` and the fake
# `/sys/bus/usb/devices` IS the bus. The stubs are driven by FIXTURE FILES per scenario, so each verdict
# is produced by a device shape rather than by a string in an assert.
#
# What is under test, and why each one is here rather than in the script's own reading:
#
#   1. THE DECISION TABLE, as four separate device shapes. A rising pack, a falling one, a flat one and
#      one where LK says soc-ok -- four fixtures, four verdicts, each asserted on the verdict LINE.
#   2. THE UNIT. `battery-voltage` is in MICROVOLTS. A script that compares the raw figure against a
#      millivolt threshold is wrong by 1000x, and this tree has already shipped a rate printed in 100x
#      its unit (docs 104). So there are two assertions in opposite directions: a printed reading must
#      read `2.921 V`, and it must NOT read `2921000 V`.
#   3. THE THREE REFUSALS. A single sample, a partial read, and an unreadable extraction are three
#      different ways a number gets mistaken for an answer, and each has its own scenario. The third is
#      not hypothetical: the FIRST version of this script extracted the earlier readings with
#      `sed -n '$d'`, which prints nothing at all with auto-print suppressed, and bash arithmetic then
#      read that empty string as ZERO -- so a flat window printed `CHARGING` and described a 2847 mV
#      rise out of nothing. That defect is now a mutation (section 6), because a check that only ever
#      sees the fixed script would not have caught it either.
#   4. THE NOISE IS THE WINDOW'S OWN. The comparison is the LAST reading against the range the EARLIER
#      ones established, not a line through the window. The first version compared first-to-last and
#      reported DISCHARGING on a four-second window whose own scatter (111 mV) fully explained the
#      111 mV it called a trend. Mutation (b) restores that comparison and must flip the flat fixture.
#   5. IT NEVER MOVES THE DEVICE. Static, over the shipped file: no boot, reboot, flash, erase, oem
#      command, and no downloader tool name. This is a READ-ONLY instrument and that is its whole claim.
#
# Usage: zl1-battery-gate-selftest.sh [--keep]
#   --keep   leave the fixtures, the stubs and the rewritten subject in place
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
SRC="$HERE/zl1-battery-gate.sh"
[ -r "$SRC" ] || { echo "cannot read $SRC" >&2; exit 2; }

W=${TMPDIR:-/tmp}/zl1-battery-gate-selftest
FR="$W/fake"          # the fake bus and the fake /sys tree
DEV="$W/dev"          # the fixture the fastboot stub answers from
STUB="$W/stub"
OUT="$W/out"
BG="$W/battery-gate.sh"
rm -rf "$W"
mkdir -p "$FR/sys/bus/usb/devices/3-3" "$FR/sys/bus/usb/devices/3-4" "$DEV" "$STUB" "$OUT" || exit 2

BASH_BIN=$(command -v bash) || { echo "no bash on this host" >&2; exit 2; }

# --- the stubs ------------------------------------------------------------------------------------
# `fastboot` reads a fixture: `present` decides whether `devices -l` lists anything at all, `serial` and
# `port` are what it prints, and each `getvar battery-*` pops the next line of `$DEV/<var>`. A line of
# `-` means the device DID NOT ANSWER -- the stub prints nothing, and the subject must record that rather
# than fill it in.
cat > "$STUB/fastboot" <<'STUBEOF'
#!/bin/sh
D="$FAKE_DIR"
case "$*" in
*"devices -l"*)
  [ -f "$D/present" ] || exit 0
  printf '%s   fastboot usb:%s\n' "$(cat "$D/serial")" "$(cat "$D/port")"
  exit 0 ;;
esac
var=""
for a in "$@"; do case "$a" in battery-*) var="$a" ;; esac; done
[ -n "$var" ] || exit 0
n=$(cat "$D/n-$var" 2>/dev/null || echo 0)
n=$(( n + 1 ))
printf '%s' "$n" > "$D/n-$var"
line=$(sed -n "${n}p" "$D/$var" 2>/dev/null)
case "${line:-}" in ''|-) exit 0 ;; esac
printf '%s: %s\n' "$var" "$line"
STUBEOF
# `lsusb` answers only the EDL vendor id, and only when the fixture says so.
cat > "$STUB/lsusb" <<'STUBEOF'
#!/bin/sh
[ -f "$FAKE_DIR/edl" ] && exit 0
exit 1
STUBEOF
# The subject sleeps between samples; the fixtures are instantaneous, so the wait is stubbed out -- and
# it has to be stubbed rather than shortened, because a real sleep would make this file's runtime the
# sum of its scenarios' windows.
cat > "$STUB/sleep" <<'STUBEOF'
#!/bin/sh
exit 0
STUBEOF
chmod +x "$STUB/fastboot" "$STUB/lsusb" "$STUB/sleep"
for t in awk sed sort tr tail cat grep timeout; do
  p=$(command -v "$t") || { echo "this host has no $t" >&2; exit 2; }
  ln -s "$p" "$STUB/$t"
done
export FAKE_DIR="$DEV"

# The bus. The zl1's serial is the full gadget id at 3-3, and the unrelated Xiaomi is a SECOND directory
# with its own serial -- which is how the subject's "IGNORED" line is a reading rather than a sentence.
printf '%s\n' '33e80afe-v63-usbd-disabled-rndis' > "$FR/sys/bus/usb/devices/3-3/serial"
printf '%s\n' '4a2fe00b'                       > "$FR/sys/bus/usb/devices/3-4/serial"

# Rewritten so the boot-bus lookup reads the fake /sys. That path is the ONLY thing touched: the argument
# handling, the sampling, the arithmetic, the decision table and the refusals are the real code.
sed -e "s#/sys/bus/usb/devices/#$FR/sys/bus/usb/devices/#g" "$SRC" > "$BG"
chmod +x "$BG"
grep -qF "$FR/sys/bus/usb/devices/" "$BG" || { echo "the /sys rewrite did not land" >&2; exit 2; }
"$BASH_BIN" -n "$BG" || { echo "the rewritten subject does not parse" >&2; exit 2; }

# --- scenario machinery ---------------------------------------------------------------------------
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$(( PASS + 1 )); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$(( FAIL + 1 )); printf 'FAIL  %s\n' "$1"; }
skip() { SKIP=$(( SKIP + 1 )); printf 'SKIP  %s\n' "$1"; }
want()   { if printf '%s' "$2" | grep -qF -- "$1"; then ok "$3"; else bad "$3"; printf '        | wanted: %s\n        | in: [%s]\n' "$1" "$2"; fi; }
notwant(){ if printf '%s' "$2" | grep -qF -- "$1"; then bad "$3"; printf '        | did NOT want: %s\n' "$1"; else ok "$3"; fi; }

# reset puts the bus back to "the zl1 is in fastboot and nothing else is wrong", which is the shipped
# shape of a boot from a finger.
reset() {
  rm -rf "$DEV"/* "$FR/sys/bus/usb/devices/3-3"
  mkdir -p "$DEV" "$FR/sys/bus/usb/devices/3-3"
  printf '%s\n' '33e80afe-v63-usbd-disabled-rndis' > "$FR/sys/bus/usb/devices/3-3/serial"
  printf '%s\n' '33e80afe' > "$DEV/serial"
  printf '%s\n' '3-3'      > "$DEV/port"
  : > "$DEV/present"
}
# shape VOLTAGES SOCS -- one line per sample, `-` meaning the device did not answer.
shape() {
  printf '%s\n' "$1" > "$DEV/battery-voltage"
  printf '%s\n' "$2" > "$DEV/battery-soc-ok"
}
run() { # args...
  env PATH="$STUB" "$BASH_BIN" "$BG" "$@" > "$OUT/last.txt" 2>&1
  RC=$?
  LAST=$(cat "$OUT/last.txt")
}
R()  { run "$@"; }
rc_is() { if [ "$RC" = "$1" ]; then ok "$2"; else bad "$2 (rc=$RC, wanted $1)"; printf '%s\n' "$LAST" | sed 's/^/        | /'; fi; }

echo "zl1 battery gate -- offline self-test"
echo "  subject: $SRC"
echo

# ==================================================================================================
echo "== 1. it prints its own manual, and the manual carries the unit =="
# ==================================================================================================
run --help; RC=$?
rc_is 0 "--help exits 0"
want 'Read the one number the whole remaining port is gated on' "$LAST" "and prints this script's own header"
want 'IS IN MICROVOLTS' "$LAST" "including the unit, because the raw figure is 1000x the volts"
want 'off-mode-charge:0' "$LAST" "and the fact that changes the right action when the pack is low"
want 'charger-screen-enabled:0' "$LAST" "and the one that explains a black screen with no indicator"
want 'never boots, reboots, flashes' "$LAST" "and the claim that it moves nothing"

# ==================================================================================================
echo
echo "== 2. the arguments it refuses =="
# ==================================================================================================
reset; run --samples 2;    rc_is 2 "a two-sample window is refused"
want 'floor is 3' "$LAST" "with the floor named"
want 'swinging' "$LAST" "and the reason named: this LK's own scatter is wider than the trend"
reset; run --samples 0;    rc_is 2 "--samples 0 is refused"
reset; run --samples 61;   rc_is 2 "a window beyond a person's patience is refused"
reset; run --interval x;   rc_is 2 "a non-numeric interval is refused"
reset; run --noise-mv x;   rc_is 2 "a non-numeric noise margin is refused"
reset; run --nonsense;     rc_is 2 "an unknown argument is refused"
reset; shape '2921000
2810000
2847000' 'no
no
no'
run --samples 3 --interval 0; rc_is 0 "three samples with no wait is allowed -- the floor is on COUNT, not on duration"

# ==================================================================================================
echo
echo "== 3. the ways it refuses to read at all, which are not readings =="
# ==================================================================================================
# No fastboot on the host: a HOST problem, and the subject must say so rather than call it a flat pack.
reset
NOFB="$W/nofb"; mkdir -p "$NOFB"
for t in awk sed sort tr tail cat grep timeout; do ln -s "$(command -v "$t")" "$NOFB/$t"; done
cp "$STUB/lsusb" "$STUB/sleep" "$NOFB/"
env PATH="$NOFB" "$BASH_BIN" "$BG" --samples 3 > "$OUT/last.txt" 2>&1; RC=$?; LAST=$(cat "$OUT/last.txt")
rc_is 2 "with no fastboot(1) it refuses"
want 'HOST problem' "$LAST" "and names it as a host problem, not as a reading about the device"

# EDL: no serial number exists there, so it is a refusal with a physical next move.
reset; : > "$DEV/edl"
run --samples 3; rc_is 2 "in EDL it refuses"
want 'Qualcomm EDL' "$LAST" "naming the mode"
want 'NOT QFIL' "$LAST" "and naming the first tool it must never run"
want 'NOT QSaharaServer' "$LAST" "the second"
want 'NOT fh_loader' "$LAST" "the third"
want 'long-press POWER' "$LAST" "with the physical next move"

# Absent: two ordinary reasons, and the off-mode-charge fact that decides what to do about it.
reset; rm -rf "$FR/sys/bus/usb/devices/3-3"
run --samples 3; rc_is 2 "with no zl1 on the bus it refuses"
want 'no device on this bus carries the serial prefix' "$LAST" "naming what it looked for"
want 'powering it off does not charge it' "$LAST" "and the fact that makes 'charge it overnight' wrong"

# The OTHER phone is on the bus in every scenario above -- and it is reported, never used.
reset; run --samples 3 >/dev/null 2>&1
want '4a2fe00b' "$LAST" "the unrelated Xiaomi is reported by serial"
want 'IGNORED -- never identified by USB id' "$LAST" "and named as ignored, with the rule"
reset; rm -rf "$FR/sys/bus/usb/devices/3-4"
run --samples 3 >/dev/null 2>&1
want 'not on the bus' "$LAST" "and with it removed, the report says so -- the line is a reading, not a sentence"

# The bus sees the serial but fastboot does not list it: a real state, and not a battery reading.
reset; rm -f "$DEV/present"
run --samples 3; rc_is 2 "with the gadget up but not in fastboot it refuses"
want 'live in the BOOTLOADER' "$LAST" "naming why a booted system cannot answer these two variables"

# ==================================================================================================
echo
echo "== 4. the four device shapes, and the verdict each one earns =="
# ==================================================================================================
reset; shape '3100000
3100000
3100000' 'yes
yes
yes'
run --samples 3 --interval 0; rc_is 0 "soc-ok yes is a verdict"
want '== verdict: CAN-BOOT' "$LAST" "and the verdict is CAN-BOOT"
want 'LK' "$LAST" "with the bootloader named as the source"
want 'needs that person' "$LAST" "and the reminder that powering on is a person's decision"

# Rising: the LAST reading must be above the range the EARLIER ones established, by the margin.
reset; shape '3100000
3120000
3260000' 'no
no
no'
run --samples 3 --interval 0; rc_is 0 "a rising pack is a verdict"
want '== verdict: CHARGING' "$LAST" "and the verdict is CHARGING"
want 'ABOVE the highest of the earlier ones' "$LAST" "stated as leaving the earlier range, not as a slope"
want 'DO NOT POWER IT OFF' "$LAST" "with the one action that would be wrong on THIS device"

# Falling.
reset; shape '3300000
3260000
3120000' 'no
no
no'
run --samples 3 --interval 0; rc_is 0 "a falling pack is a verdict"
want '== verdict: DISCHARGING' "$LAST" "and the verdict is DISCHARGING"
want 'BELOW the lowest of the earlier ones' "$LAST" "stated as leaving the earlier range"
want 'WALL CHARGER' "$LAST" "with the next move named"

# Flat within noise -- the shape the device on the bench actually has.
reset; shape '2921000
2810000
2847000' 'no
no
no'
run --samples 3 --interval 0; rc_is 0 "a flat pack is a verdict"
want '== verdict: FLAT WITHIN NOISE' "$LAST" "and the verdict says the window shows no direction"
want "earlier readings' range: 2.810 V - 2.921 V" "$LAST" "with BOTH bounds printed -- this line read '? - ?' when the extraction was broken"
want 'scatter was' "$LAST" "and the window's own scatter stated beside the first-to-last difference"
want 'NOT evidence that the pack is dead' "$LAST" "and the claim limited to what one port can support"
want 'WALL CHARGER' "$LAST" "with the comparison that would separate the two readings named"

# The noise must EXCEED the margin, and the margin is a threshold a caller can move.
reset; shape '3000000
3000000
3110000' 'no
no
no'
run --samples 3 --interval 0; rc_is 0 "a 110 mV rise is a direction at the default margin"
want '== verdict: CHARGING' "$LAST" "and it is read as one"
reset; shape '3000000
3000000
3110000' 'no
no
no'
run --samples 3 --interval 0 --noise-mv 200; rc_is 0 "the same fixture with a 200 mV margin is not"
want '== verdict: FLAT WITHIN NOISE' "$LAST" "so the margin is what decides, and it is the caller's"

# ==================================================================================================
echo
echo "== 5. the unit, and a partial read =="
# ==================================================================================================
reset; shape '2921000
2810000
2847000' 'no
no
no'
run --samples 3 --interval 0 >/dev/null 2>&1
want '2.921 V' "$LAST" "a raw microvolt reading is printed as volts"
notwant '2921000 V' "$LAST" "and NOT as the raw figure with a volt sign after it"
want 'MICROVOLTS' "$LAST" "with the unit spelled out where the table is printed"
want '2773000 is 2.773 V' "$LAST" "and worked through on the real number"

# A partial read is NOT a read: no verdict, and specifically no slope over the survivors.
reset; shape '3100000
-
3260000' 'no
no
no'
run --samples 3 --interval 0; rc_is 3 "one silent sample makes the whole window UNREADABLE"
want 'UNREADABLE: 2 of 3 readings came back' "$LAST" "counting what came back out of what was asked"
want 'did not answer' "$LAST" "and showing the line that did not answer"
notwant '== verdict:' "$LAST" "and printing NO verdict at all"
want 'not of the pack' "$LAST" "naming that a trend over the survivors would be a reading of the link"

# ==================================================================================================
echo
echo "== 6. the two defects this script really had, as mutations =="
# ==================================================================================================
# A mutation is only a mutation if it changes the SHIPPED file. Both of these do, and both were real.
mutate() { # name, sed-script
  sed "$2" "$SRC" > "$W/$1.sh" 2>/dev/null || { bad "mutation '$1': sed failed"; return 1; }
  if cmp -s "$W/$1.sh" "$SRC"; then
    bad "mutation '$1': its sed matches no line of the SHIPPED script, so nothing is being tested"
    return 1
  fi
  sed -e "s#/sys/bus/usb/devices/#$FR/sys/bus/usb/devices/#g" "$W/$1.sh" > "$W/$1-run.sh"
  "$BASH_BIN" -n "$W/$1-run.sh" || { bad "mutation '$1': the mutant does not parse"; return 1; }
  ok "mutation '$1': landed (it changes a line of the shipped script, and the mutant parses)"
  return 0
}
runmut() { # name
  env PATH="$STUB" "$BASH_BIN" "$W/$1-run.sh" --samples 3 --interval 0 > "$OUT/mut.txt" 2>&1
  MRC=$?
  MUT=$(cat "$OUT/mut.txt")
}

FLATV='2921000
2810000
2847000'
FLATS='no
no
no'

# (a) THE COMPARISON THE FIRST VERSION USED: first-to-last against the margin, instead of the last
# reading against the earlier range. The fixture has to be a shape where the two DISAGREE, or the
# mutation proves nothing: here the window ends AT the earlier minimum, so the last reading left their
# range by zero and is flat -- while first-to-last is a 110 mV fall, which is the whole reason the rule
# was changed.
EQUIV='2921000
2810000
2810000'
if mutate trendcompare 's/^if \[ "\$BELOW" -ge "\$NOISE_UV" \]; then$/if [ "$TREND" -le "-$NOISE_UV" ]; then/'; then
  reset; shape "$EQUIV" "$FLATS"; runmut trendcompare
  want '== verdict: DISCHARGING' "$MUT" "mutation 'first-to-last comparison': a window ending at the earlier minimum reads as a fall"
  notwant 'FLAT WITHIN NOISE' "$MUT" "and no longer says the window shows no direction"
  reset; shape "$EQUIV" "$FLATS"
  run --samples 3 --interval 0 >/dev/null 2>&1
  want '== verdict: FLAT WITHIN NOISE' "$LAST" "while the shipped script calls the same fixture flat -- so the check is live"
fi

# (b) THE EXTRACTION DEFECT THAT REALLY HAPPENED: `sed -n '$d'` prints nothing, the empty string enters
# the arithmetic as zero, and a verdict comes out of nothing. What must appear instead is a refusal.
if mutate empextract "s#sed '\\\$d'#sed -n '\\\$d'#"; then
  reset; shape "$FLATV" "$FLATS"; runmut empextract
  want 'UNREADABLE' "$MUT" "mutation 'the empty extraction': the window is refused"
  notwant '== verdict:' "$MUT" "and NO verdict is printed from the empty operand"
  want 'reads an empty operand as ZERO' "$MUT" "with the reason named, so it cannot be mistaken for a measurement"
fi

# (c) THE MARGIN IN THE WRONG UNIT: comparing microvolts against the millivolt number makes the threshold
# 1000x too small, so the flat fixture's own noise clears it.
DRIFT='3000000
3000000
3001000'
if mutate unitfold 's/^NOISE_UV=\$(( NOISE_MV \* 1000 ))$/NOISE_UV=$NOISE_MV/'; then
  reset; shape "$DRIFT" "$FLATS"; runmut unitfold
  want '== verdict: CHARGING' "$MUT" "mutation 'the margin in the wrong unit': a 1 mV drift clears the folded threshold"
  reset; shape "$DRIFT" "$FLATS"
  run --samples 3 --interval 0 >/dev/null 2>&1
  notwant '== verdict: CHARGING' "$LAST" "while the shipped script does not -- 1 mV is far under its 100 mV margin"
  want '== verdict: FLAT WITHIN NOISE' "$LAST" "and calls it what it is"
fi

# ==================================================================================================
echo
echo "== 7. it is a READ-ONLY instrument, and that is static =="
# ==================================================================================================
# Not a behaviour: a property of the shipped file. A `fastboot` subcommand that changes the device has no
# business in a script whose whole output is a reading -- and the names matter, because the one that has
# to be absent is the one that would be used in EDL.
for pat in 'fastboot flash' 'fastboot reboot' 'fastboot erase' 'fastboot boot' 'fastboot oem' \
           'fastboot format' 'fastboot update' 'dd if=' '> /dev/block'; do
  notwant "$pat" "$(cat "$SRC")" "the shipped script never runs '$pat'"
done
# The three downloader names DO occur -- in the sentence that forbids them. So the claim checked is the
# one that is true: every mention is a prohibition. A grep for a defect's shape also matches the prose
# naming it, which is the trap this tree already records about its own README.
for pat in QFIL QSaharaServer fh_loader; do
  tot=$(grep -c "$pat" "$SRC")
  prh=$(grep "$pat" "$SRC" | grep -c 'NOT \|not ')
  if [ "$tot" = 0 ]; then bad "$pat is named nowhere, so the EDL refusal does not forbid it"
  elif [ "$tot" = "$prh" ]; then ok "every mention of '$pat' ($tot) is inside a prohibition, and none is an invocation"
  else bad "'$pat' appears $tot times and only $prh are prohibitions -- one of them is an invocation"; fi
done
want 'fastboot -s "$SERIAL" getvar battery-voltage' "$(cat "$SRC")" "it calls getvar for the voltage"
want 'fastboot -s "$SERIAL" getvar battery-soc-ok' "$(cat "$SRC")" "and for soc-ok"
want 'fastboot devices -l' "$(cat "$SRC")" "and reads the port from the bus, because the port is part of the answer"
n=$(grep -c 'fastboot -s "\$SERIAL" getvar' "$SRC")
[ "$n" = 2 ] && ok "and makes exactly $n getvar-shaped reads, both named, so the surface is countable" \
             || bad "it makes $n getvar-shaped reads where 2 are expected -- the claim is unverified"

# The harness's own guard, in the idiom its siblings use: the shipped file must be byte-identical after
# this run. A harness that rewrites the tree it tests is the defect docs 128 records.
want 'never' "$(cat "$SRC")" "and says what it never does, in its own header"

# ==================================================================================================
echo
echo "== 8. this harness's own citation =="
# ==================================================================================================
# A count typed by hand in the first thing a human reads goes stale the moment this file grows, so this
# harness reads its own citation out of the health check and compares it with what it just ran. The
# number is taken from the matched text rather than from the whole sentence (`grep -oE '[0-9]+'` over the
# match also finds the 1 in `zl1-`, which is how a sibling harness once compared 1 against its own total),
# and the first match is taken with `sed -n 1p` rather than `head -n1`, because an early-exiting reader
# turns its writer's SIGPIPE death into the pipeline's status.
HEALTH="$HERE/zl1-health-check.sh"
if [ -r "$HEALTH" ]; then
  match=$(tr '\n' ' ' < "$HEALTH" |
    grep -oE 'zl1-battery-gate-selftest\.sh[^0-9]*[0-9]+ checks' | sed -n 1p)
  cited=$(printf '%s\n' "$match" | sed -n 's/.*[^0-9]\([0-9][0-9]*\) checks$/\1/p')
  total=$(( PASS + FAIL + 1 ))
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
if [ "$KEEP" = 1 ]; then echo "kept: $W"; else rm -rf "$W"; fi
printf 'pass=%s fail=%s skip=%s\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" = 0 ] || exit 1
exit 0
