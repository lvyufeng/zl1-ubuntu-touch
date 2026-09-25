#!/usr/bin/env bash
# zl1 governor-temperature A/B -- offline self-test. Host-side, touches no device, needs no phone.
#
# Why this exists. `scripts/device/zl1-governor-temp-ab.sh` writes the SAME four cpufreq files the second
# heat fix owns, twice, in order to price that fix in degrees. So the guarantee a read-only probe gets for
# free ("not one byte changed") is not available here, and the guarantee has to be a different one, stated
# exactly and checked:
#
#   1. THE SET OF FILES IT CAN WRITE IS A CLOSED, NAMED SET. Section 0 reads the redirect targets out of the
#      SHIPPED source with the comments stripped, and requires every one of them to be either the core list
#      or a file inside the script's own `mktemp -d`. Mutation m0 adds a fifth target and the harness has to
#      see it. What "the core list" means HERE is weaker than the ladder instrument's single `$PARAM` and
#      that is stated rather than glossed: the write target is a LOOP VARIABLE over the discovered cores, so
#      the whitelist accepts that variable's name -- and section 0 therefore also asserts that the list it
#      loops over comes from the cpufreq glob and from nowhere else.
#   2. --status WRITES NOTHING, byte-for-byte, and neither does any refusal -- even one given --yes.
#   3. THE HAPPY PATH ENDS WHERE IT STARTED: every core reads `interactive` again, the three states it
#      passes through are each PROVED by read-back inside the run's own output, and the tree is unchanged.
#   4. THE TRAP IS WHAT RESTORES IT. A run interrupted after the write, with the fix's value held by nobody
#      else, must leave every core on `interactive` -- so the restore is not the happy path's last line but a
#      trap that fires on a path nobody wrote by hand. m4 is the trap disarmed.
#   5. THE VERDICT CAN COME OUT AGAINST THE FIX (`no-detectable-cost`) and can be CALLED OFF BY ITS OWN
#      CONTROL WINDOW (`contaminated`). Both are scenarios, not paragraphs.
#   6. THE TWO REFUSALS THIS INSTRUMENT HAS AND ITS SIBLING DOES NOT are both scenarios with their own
#      mutation, because they are the whole difference between pricing a bool and pricing a governor: a
#      governor the kernel does not OFFER (silent at the write site, and it would read as "costs nothing"),
#      and cores that DISAGREE (there is then no window A to speak of).
#   7. THE WAIT DECIDES WHETHER THERE IS A CONTROL WINDOW AT ALL (docs 170, 171). A reading that comes back
#      makes window C a control and the run prints a price; a reading that does NOT come back inside the
#      bound makes the run print NO PRICE and skip window C entirely. Both are scenarios, and the mutation
#      that ignores the wait's answer has to be driven by the second one: every other scenario's reading
#      comes back, so a branch that never runs cannot be seen from the passing side.
#   8. THE RUN SAYS WHERE ITS OWN FILES ARE, AND CLEANS UP AFTER ITSELF. A plain run removes its scratch
#      directory and says which; --keep keeps it and says where; and the shipped source has exactly ONE
#      exit trap doing both the restore and the cleanup -- because a second `trap ... EXIT` REPLACES the
#      first, which is how the cleanup came to never run on the device (docs 170), silently. m10 disarms it
#      and the only assertion in this file that can see that is the one that counts leftovers.
#   9. THE WHOLE TABLE IS PRINTED. The device run printed twelve rows and said the rest were "in the archive"
#      -- a directory with a random suffix that nothing named. The version with a cap is mutation m8, and the
#      assertion it has to break is the table's OWN claim that every row is printed.
#
# How it works: **the stub directory IS the device**, the same construction this family's other harnesses
# use -- the script runs as itself against a fake root, with PATH for the child set to `$STUB:$MINBIN`. TWO
# THINGS ARE WORTH READING BEFORE CHANGING THIS FILE:
#
#   * THERE IS NO `tr` STUB HERE, and that is a property of the knob rather than an omission. The ladder
#     parameter is a bool module parameter, so sysfs stores `0` and RENDERS `N`; a text fixture cannot
#     express that, and its harness needs a `tr` that renders through the module's type (docs 163). A
#     governor name is stored and read back AS ITSELF -- so a plain text file IS the device here, and the
#     scenario below that writes a value and reads it back is asserting something the fixture can do
#     honestly. This was verified against the device on 2026-09-25: all four cores read `interactive`, and
#     `scaling_available_governors` is `interactive conservative ondemand userspace powersave performance`.
#   * THE INSTRUMENT STUB IS LOAD-BEARING. The experiment is "the zones move when the governor moves", so a
#     stub printing a fixed table would make every delta zero and every scenario would be testing the
#     absence of the thing it set up. This stub computes its table from THE FAKE GOVERNOR'S OWN VALUE plus a
#     per-window drift, so "pinning the cores costs 5.0 C" is a fact of the fixture that the verdict has to
#     recover -- and `FP_DRIFT` makes the same table warm up with NOTHING changed, which is what the control
#     window exists to catch.
#
# The instrument's output SHAPE is not invented: it is what the real `zl1-thermal.sh` printed on the device
# on 2026-09-25, including a zone line with a trailing note for a type its unit table does not know.
#
# Usage: zl1-governor-temp-ab-selftest.sh [--keep]
#   --keep   leave the fake device, the stubs and the rewritten script for inspection
#
# Exit codes: 0 every scenario behaved; 1 something did not; 2 the harness could not set up.

set -uo pipefail

KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
  --keep) KEEP=1; shift ;;
  --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; exit 0 ;;
  *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../device/zl1-governor-temp-ab.sh"
[ -r "$SRC" ] || { echo "cannot read $SRC" >&2; exit 2; }
# Kept for the tree check at the end: this harness rewrites the subject into a fake root and runs mutants of
# it, so "the shipped file is byte-identical afterwards" is the only thing standing between a fixture bug and
# a quiet edit of the thing under test (the family records one harness that replaced a 409-line instrument
# with one comment line while every assertion stayed green).
SRC_SHA_BEFORE=$(sha256sum "$SRC" | awk '{print $1}')

W="${TMPDIR:-/tmp}/zl1-governor-temp-ab-selftest"
FR="$W/root"
STUB="$W/stub"
MINBIN="$W/minbin"
ACT="$W/actions"
rm -rf "$W"
mkdir -p "$STUB" "$MINBIN" "$FR" || exit 2
: > "$ACT"

# `sh`, `sleep` and `date` are here because the SUBJECT calls them by name: it runs the instrument with
# `sh <path>`, it waits a settle with `sleep`, and it stamps its header with `date`. A curated sandbox PATH
# that lacks a tool silently disables the behaviour that needs it -- the family has recorded that trap twice.
# `chmod` is here for the read-only-core scenarios.
for t in awk cat chmod date grep head ls mktemp readlink rm sed sh sleep sort tr wc; do
  p="$(type -P "$t" 2>/dev/null)" || continue
  [ -n "$p" ] && ln -sf "$p" "$MINBIN/$t"
done
for t in awk cat chmod date grep head ls readlink sed sh sleep sort tr wc; do
  [ -x "$MINBIN/$t" ] || { echo "the sandbox bin is missing $t -- the harness cannot run the script honestly" >&2; exit 2; }
done
SH_BIN="$(type -P sh 2>/dev/null)"; [ -n "$SH_BIN" ] || SH_BIN=/bin/sh
[ -x "$SH_BIN" ] || { echo "no /bin/sh to run the subject with" >&2; exit 2; }

# --- the fake device ------------------------------------------------------------------------------
# FOUR cores, each with the two cpufreq files the instrument reads: the governor it changes, and the list of
# governors the kernel offers. The values are the device's own, read on 2026-09-25.
CY=4
# `gc_mk` is a FUNCTION and not a one-off loop, because one scenario REMOVES the whole tree (there are no
# cores at all) and every scenario after it needs it back. A fixture that can only be built at the top of the
# file makes the scenario that deletes it the last one that can run -- which is the shape `scen` below exists
# to prevent, and the first version of this file had exactly that bug: `refused-c` deleted the tree and the
# eleven scenarios after it all refused on a device with no cores.
# NO TRAILING NEWLINE, deliberately. The instrument writes a governor with `printf '%s'` (no newline), so a
# fixture that starts out holding `interactive\n` is a device whose bytes the FIRST write changes -- and the
# happy path's "the whole fake device is byte-for-byte as it was" then fails for a reason that has nothing to
# do with the experiment. That is exactly what it did the first time this file ran. (The real sysfs file does
# end in a newline; the instrument's write does not, and sysfs normalises. What this fixture has to model is
# the ROUND TRIP, and the round trip is what the assertion is about.)
gc_mk() {
  for i in 0 1 2 3; do
    mkdir -p "$FR/sys/devices/system/cpu/cpu$i/cpufreq"
    printf '%s' interactive > "$FR/sys/devices/system/cpu/cpu$i/cpufreq/scaling_governor"
    printf '%s' 'interactive conservative ondemand userspace powersave performance' \
      > "$FR/sys/devices/system/cpu/cpu$i/cpufreq/scaling_available_governors"
  done
}
gc_mk
gc_path() { printf '%s' "$FR/sys/devices/system/cpu/cpu$1/cpufreq/scaling_governor"; }
gc_set() { # a state, written to EVERY core as the device would hold it
  for i in 0 1 2 3; do printf '%s' "$1" > "$(gc_path "$i")"; done
}
gc_now() { tr -d '\n' < "$(gc_path 0)" 2>/dev/null; }
gc_each() { for i in 0 1 2 3; do printf ' cpu%s=%s' "$i" "$(tr -d '\n' < "$(gc_path "$i")")"; done; }
gc_all() { # true only when every core reads the SAME thing -- the state this experiment moves
  local v="" x
  for i in 0 1 2 3; do x=$(tr -d '\n' < "$(gc_path "$i")" 2>/dev/null)
    if [ -z "$v" ]; then v="$x"; elif [ "$v" != "$x" ]; then return 1; fi
  done
  [ "$v" = "$1" ]
}
gc_rm() { rm -rf "$FR/sys/devices/system/cpu"; }
gc_ro() { chmod 0444 "$(gc_path 0)"; }
gc_rw() { chmod 0644 "$(gc_path 0)"; }
# $1 = the value, $2 = "yes" to add it / anything else to remove it -- from EVERY core, and the OTHER value
# stays in the list. That last part is not a detail: the first version wrote a fixed list when removing, which
# dropped BOTH governors, so the scenario meant to test "the value the kernel does not offer" was really
# testing "neither value is offered" and the refusal it produced named the wrong one.
gc_offer() {
  for i in 0 1 2 3; do
    local p="$FR/sys/devices/system/cpu/cpu$i/cpufreq/scaling_available_governors"
    if [ "$2" = yes ]; then
      printf '%s' 'interactive conservative ondemand userspace powersave performance' > "$p"
    else
      case "$1" in
      performance) printf '%s' 'interactive conservative ondemand userspace powersave' > "$p" ;;
      interactive) printf '%s' 'conservative ondemand userspace powersave performance' > "$p" ;;
      *)           printf '%s' 'interactive conservative ondemand userspace powersave performance' > "$p" ;;
      esac
    fi
  done
}

# The panic -> EDL knob, which the instrument reads before anything else. It is a SECOND parameter under its
# own module directory, so the instrument's glob (`/sys/module/*/parameters/download_mode`) sees exactly what
# the device has: ONE. A fixture with none of them is a scenario of its own below.
mkdir -p "$FR/sys/module/msm_poweroff/parameters" "$FR/proc/device-tree"
DL="$FR/sys/module/msm_poweroff/parameters/download_mode"
dl_set() { printf '%s' "$1" > "$DL"; }
dl_rm()  { rm -f "$DL"; }
printf 'msm8996\0' > "$FR/proc/device-tree/compatible"
printf 'LeEco zl1\0' > "$FR/proc/device-tree/model"
gc_set interactive
dl_set 0

# --- the instrument, which is the load-bearing stub -------------------------------------------------
# QUOTED heredoc, and the fixture paths arrive as ENVIRONMENT at run time: an unquoted one would have bash eat
# the backslashes this stub needs to pass to awk. The table is a function of the fake governor and of the
# window number:
#
#     tsens zone i = BASE + i*0.5 + (DIFF if the cores are PINNED) + (DRIFT * (window - 1))
#
# so DIFF is "what pinning the cores costs" as a fact about the fake phone and DRIFT is "the phone warming up
# on its own". The window counter is a file, because the instrument is a process and cannot remember anything
# between calls -- which is also true of the real one.
#
# The stub reads cpu0's governor, and that is deliberate: it is the SAME single file the real thermal
# instrument would report in its `== cpufreq:` block, and it means a mutant that changes only one core shows
# up as a window that did not move rather than as a crash.
cat > "$STUB/zl1-thermal.sh" <<'EOF'
#!/bin/sh
v=$(cat "${FP_GOV:-/nonexistent}" 2>/dev/null)
case "$v" in performance) pinned=1 ;; *) pinned=0 ;; esac
n=$(cat "${FP_COUNT:-/nonexistent}" 2>/dev/null)
case "$n" in ''|*[!0-9]*) n=0 ;; esac
n=$((n + 1))
printf '%s' "$n" > "${FP_COUNT:-/dev/null}" 2>/dev/null
# THE COOLING MODEL, and it exists because the instrument now WAITS for the reading to come back before it
# reads the control window (docs 170). `FP_COOL` is the number of SAMPLES the intervention's excess survives
# after the cores are put back; `-1` means it never decays at all, which is the phone the first device run
# turned out to be. The counter is a file for the same reason the window counter is: the stub is a process,
# and it cannot remember anything between calls.
cool=$(cat "${FP_COOLFILE:-/nonexistent}" 2>/dev/null)
case "$cool" in ''|*[!0-9-]*) cool=n ;; esac   # `n` = this phone has never been pinned in this run
if [ "$pinned" = 1 ]; then
  cool="${FP_COOL:-1}"
  printf '%s' "$cool" > "${FP_COOLFILE:-/dev/null}" 2>/dev/null
elif [ "$cool" != n ]; then
  [ "$cool" -gt 0 ] 2>/dev/null && cool=$((cool - 1))
  printf '%s' "$cool" > "${FP_COOLFILE:-/dev/null}" 2>/dev/null
fi
printf 'window n=%s pinned=%s cool=%s\n' "$n" "$pinned" "$cool" >> "${FP_ACT:-/dev/null}"
awk -v b="$pinned" -v n="$n" -v base="${FP_BASE:-42.0}" -v diff="${FP_DIFF:-0}" -v drift="${FP_DRIFT:-0}" \
    -v other="${FP_OTHER_DIFF:-0}" -v cool="$cool" -v ct="${FP_COOL:-1}" -v nz="${FP_ZONES:-4}" '
  BEGIN {
    # The excess the intervention left behind: full while the cores are pinned, and decaying by one step per
    # sample afterwards. `ct < 0` is the phone whose heat does not decay inside the window at all -- which is
    # what the first device run measured (docs 170).
    if (b)                 exc = diff
    else if (cool == "n")  exc = 0
    else if (ct < 0)       exc = diff
    else if (ct == 0)      exc = 0
    else                   exc = diff * cool / ct
    hot = base + drift * (n - 1) + exc
    printf "zl1 thermal budget :: window %d :: read-only\n", n
    printf "  busy 0.80 of 4 cores (20%%), of which iowait 0.00 cores\n"
    printf "== thermal zones:\n"
    for (i = 0; i < nz; i++) printf "   thermal_zone%d tsens_tz_sensor%d             %.1f C\n", i, i, hot + i * 0.5
    printf "   thermal_zone0 bms                          35.7 C   <- type not in the unit table; assumed milli-degC (raw 35700)\n"
    printf "   thermal_zone22 pm8994_tz                    %.1f C\n", base + drift * (n - 1) + (b ? other : 0)
    printf "   hottest: tsens_tz_sensor0 %.1f C  (raw %d = deci-degC, of 38 zones; 1 flagged above)\n", hot, hot * 10
    printf "== cpufreq:\n   cpu0/cpufreq           governor=%s  cur=307200   kHz\n", (b ? "performance" : "interactive")
  }'
exit "${FP_INSTRUMENT_RC:-0}"
EOF
chmod +x "$STUB/zl1-thermal.sh"

# An instrument that answers nothing at all: section 5 and mutation m6 both need one.
cat > "$W/quiet-instrument.sh" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$W/quiet-instrument.sh"

# --- the script under test, rewritten into the fake device ------------------------------------------
# TWO PASSES through tokens, for the reason its siblings record: a one-pass rewrite is a cascade, and a
# cascaded path is a script reading something that cannot exist while every scenario still passes. It is a
# FUNCTION because a MUTATION has to be rewritten the same way before it can be run.
#
# `/sys/devices` is a token of its own and the order matters: `/sys/devices/system/cpu` must not be reached by
# the `/sys/module` rule, and it is not -- the two prefixes do not overlap. What DOES need care is that the
# FIRST pass is what counts the tokens, so a long pattern is listed before a short one.
rewrite() { # $1 = a source (shipped or mutated), $2 = where to write the fake-device copy
  sed -e 's#/sys/devices#__ZDEV__#g' \
      -e 's#/proc/device-tree#__ZDT__#g' \
      -e 's#/sys/module#__ZMOD__#g' "$1" > "$W/.pass1.sh"
  sed -e "s#__ZDEV__#$FR/sys/devices#g" \
      -e "s#__ZDT__#$FR/proc/device-tree#g" \
      -e "s#__ZMOD__#$FR/sys/module#g" "$W/.pass1.sh" > "$2"
}
RW="$W/governor-temp-ab.sh"
rewrite "$SRC" "$RW"
cp "$W/.pass1.sh" "$W/pass1.sh"
sh -n "$RW" || { echo "the rewritten script does not parse" >&2; exit 2; }
if grep -q -- '__Z' "$RW"; then
  echo "an unexpanded token is left in $RW:" >&2
  grep -n -- '__Z' "$RW" | sed -n '1,5p' >&2
  exit 2
fi
cnt() { grep -o -- "$1" "$2" 2>/dev/null | wc -l | tr -d ' '; }
TOK=$(cnt '__Z[A-Z0-9]*__' "$W/pass1.sh")
FRS=$(cnt "$FR" "$RW")
[ "$TOK" -gt 0 ] || { echo "pass 1 produced no tokens -- the rewrite matched nothing" >&2; exit 2; }
[ "$TOK" = "$FRS" ] || { echo "$TOK tokens in pass 1 became $FRS fake-root paths in pass 2" >&2; exit 2; }
for pair in "__ZDEV__:$FR/sys/devices" "__ZDT__:$FR/proc/device-tree" "__ZMOD__:$FR/sys/module"; do
  tok="${pair%%:*}"; path="${pair#*:}"
  [ "$(cnt "$tok" "$W/pass1.sh")" -gt 0 ] || { echo "$tok never appears in pass 1 -- that path is not in the script" >&2; exit 2; }
  [ "$(cnt "$tok" "$W/pass1.sh")" = "$(cnt "$path" "$RW")" ] \
    || { echo "$tok did not expand to $path exactly as many times as it appears" >&2; exit 2; }
done
grep -qF "$FR$FR" "$RW" && { echo "a rewrite cascaded: $FR appears twice in a row" >&2; exit 2; }
grep -qF "$FR/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor" "$RW" \
  || { echo "the cpufreq glob was not rewritten -- the script would write THIS host's governors" >&2; exit 2; }

# --- the run helpers ------------------------------------------------------------------------------
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
# The haystack reaches the reader DIRECTLY, and that is not a style choice: this harness sets `pipefail`, and
# `printf '%s\n' "$2" | grep -q` under pipefail reports the WRITER's death as the check's answer (docs 134 --
# the reader exits at the first match, the writer is killed by SIGPIPE, and the pipeline's status is 141).
want()    { if grep -Eq -- "$1" <<< "$2"; then ok "$3"; else bad "$3"; sed 's/^/        | /' <<< "$2"; fi; }
notwant() { if grep -Eq -- "$1" <<< "$2"; then bad "$3"; grep -E -- "$1" <<< "$2" | sed 's/^/        | /'; else ok "$3"; fi; }
# For the messages the subject WRAPS across lines. An assertion on a wrapped phrase is an assertion on where
# the wrap happens to fall -- a property of the message's length, not of what it says.
squash() { printf '%s' "$1" | tr '\n' ' ' | tr -s ' \t' ' '; }
wantsq() { local sq; sq=$(squash "$2"); if grep -Eq -- "$1" <<< "$sq"; then ok "$3"; else bad "$3"; sed 's/^/        | /' <<< "$2"; fi; }

# The whole fake device, hashed. "Writes nothing" is checked against THIS, so a write anywhere under the fake
# root -- including a new file -- changes the hash.
tree_hash() { (cd "$FR" && find . -type f -print0 | sort -z | xargs -0 sha256sum) | sha256sum | awk '{print $1}'; }

FP_DIFF=0; FP_DRIFT=0; FP_BASE=42.0; FP_OTHER_DIFF=0; FP_INSTRUMENT_RC=0; FP_COOL=1; FP_ZONES=4
scen() { # name -- reset the device to the healthy, installed state
  S="$W/out/$1"; rm -rf "$S"; mkdir -p "$S"
  FP_DIFF=0; FP_DRIFT=0; FP_BASE=42.0; FP_OTHER_DIFF=0; FP_INSTRUMENT_RC=0; FP_COOL=1; FP_ZONES=4
  gc_mk
  dl_set 0
  rm -f "$W/win.count" "$W/cool.count"
  : > "$ACT"
}
env_for() { printf '%s\n' "FP_GOV=$(gc_path 0)" "FP_COUNT=$W/win.count" "FP_COOLFILE=$W/cool.count" "FP_ACT=$ACT" \
  "FP_DIFF=$FP_DIFF" "FP_COOL=$FP_COOL" "FP_ZONES=$FP_ZONES" \
  "FP_DRIFT=$FP_DRIFT" "FP_BASE=$FP_BASE" "FP_OTHER_DIFF=$FP_OTHER_DIFF" "FP_INSTRUMENT_RC=$FP_INSTRUMENT_RC"; }

run() { # the script's own args...
  local e; e=$(env_for)
  OUT=$(env PATH="$STUB:$MINBIN" $e "$SH_BIN" "$RW" "$@" 2>&1); RC=$?
}
mutrun() { # mutant name, then the script's own args...
  local m="$1"; shift
  local e; e=$(env_for)
  OUT=$(env PATH="$STUB:$MINBIN" $e "$SH_BIN" "$W/mut-$m.rw.sh" "$@" 2>&1); RC=$?
}
# Killing a run a fixed number of seconds in tests the TIMER and not the trap. What the check needs is a kill
# somewhere the state is KNOWN, and the state worth knowing is "the cores are pinned": the only window in
# which a run that dies leaves an experiment behind. So this waits for the subject's OWN write to appear.
wait_pinned() { # up to 10 s for the subject to be in the pinned window; fails if it exits first
  local n=0
  while [ "$n" -lt 100 ]; do
    gc_all performance && return 0
    kill -0 "$BG_PID" 2>/dev/null || return 1
    sleep 0.1; n=$((n + 1))
  done
  return 1
}
kill_pinned() { # TERM the background run while the cores are provably pinned
  if wait_pinned; then kill -TERM "$BG_PID" 2>/dev/null
  else bad "  (the run left the pinned window before it could be interrupted)"; fi
}
runbg() { # outfile, script-path, args... -- background, so the trap can be interrupted
  local f="$1"; shift
  local s="$1"; shift
  local e; e=$(env_for)
  env PATH="$STUB:$MINBIN" $e "$SH_BIN" "$s" "$@" > "$f" 2>&1 &
  BG_PID=$!
}
mut() { # name, sed-script -- true only if the sed changes the SHIPPED source and the mutant parses
  if cmp -s <(sed "$2" "$SRC" 2>/dev/null) "$SRC"; then
    bad "mutation '$1': its sed matches no line of the SHIPPED script, so nothing is being tested"
    return 1
  fi
  sed "$2" "$SRC" > "$W/mut-$1.sh"
  cmp -s "$SRC" "$W/mut-$1.sh" && { bad "mutation '$1': it did not land"; return 1; }
  rewrite "$W/mut-$1.sh" "$W/mut-$1.rw.sh"
  sh -n "$W/mut-$1.rw.sh" 2>/dev/null || { bad "mutation '$1': the mutant does not parse"; return 1; }
  ok "mutation '$1': landed (it changes a line of the shipped script, and the mutant parses)"
  return 0
}
# The whitelist check, as a function, because TWO things run it: the shipped source (section 0) and a mutant
# that added a write target (m0). Returns the number of targets that are neither the core list nor inside
# $TMP -- and prints the distinct targets on stdout so the caller can assert on their names.
#
# Quoted AND unquoted targets, and the unquoted form is restricted to targets that LOOK like paths (`/` or
# `$`), because without that the `->` arrows in the script's own prose were read as writes and the sibling
# harness reported six offenders in a script that has none. `/dev/null` and `/dev/stderr` are sinks -- the
# error channel of a write and of a pipeline -- rather than places any state is written.
offenders() { # $1 = a source file
  local s="$W/.nocomments.sh"
  sed 's/#.*//' "$1" > "$s"
  grep -oE '>[ ]*("[^"]+"|[/$][^"[:space:]&|;)]*)' "$s" \
    | sed -e 's/^>[ ]*//' -e 's/^"//' -e 's/"$//' | sort -u > "$W/.targets"
  local n=0 t
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    case "$t" in '$zl1_g'|'$TMP'/*|/dev/null|/dev/stderr) : ;; *) n=$((n + 1)) ;; esac
  done < "$W/.targets"
  printf '%s' "$n"
}

echo "zl1 governor temperature A/B -- offline self-test"
echo "  script under test: $SRC"
echo "  fake device:       $FR"
echo

# ==================================================================================================
echo "== 0. what this script can write: every redirect target, out of the SHIPPED source =="
# ==================================================================================================
N_BAD=$(offenders "$SRC")
TARGETS=$(cat "$W/.targets")
[ -n "$TARGETS" ] || { echo "no redirect target found in $SRC -- the whitelist has nothing to check" >&2; exit 2; }
[ "$N_BAD" = 0 ] && ok "every redirect target is the core list or a file in the script's own mktemp dir" \
                 || bad "$N_BAD redirect target(s) point somewhere else entirely: $(cat "$W/.targets")"
want '^\$zl1_g$' "$TARGETS" "and the core's governor file IS one of them (so the whitelist is not empty of the point)"
want '^\$TMP/win\.' "$TARGETS" "and the instrument's output lands in \$TMP, not in a fixed path"
# The whitelist accepts a LOOP VARIABLE, which is weaker than accepting one named path -- so what it loops
# over is checked too: the list must come from the cpufreq glob, and every write must go through the variable
# that glob fills. Both halves are asserted on the SHIPPED source with comments stripped.
want 'for zl1_g in /sys/devices/system/cpu/cpu\*/cpufreq/scaling_governor' "$(cat "$W/.nocomments.sh")" \
  "and the variable it whitelists is filled from the cpufreq glob and not from anywhere else"
N_GOV_WRITES=$(grep -c 'printf .%s. "\$zl1_want" > "\$zl1_g"' "$W/.nocomments.sh")
[ "$N_GOV_WRITES" = 1 ] && ok "and there is exactly ONE place that writes a governor (the read-back loop is not a write)" \
                        || bad "$N_GOV_WRITES governor writes in the shipped source, expected 1"
# ONE EXIT TRAP, and it does both jobs. A POSIX shell keeps ONE action per condition, so a second `trap ... EXIT`
# silently REPLACES the first: that is how the cleanup came to never run on the device (docs 170), and it is
# invisible from the passing side because every assertion about the RESTORE still holds. Static, on the shipped
# source, because the failure mode is "the line that should be there is not".
N_EXIT_TRAPS=$(grep -c '^trap .* EXIT$' "$W/.nocomments.sh")
[ "$N_EXIT_TRAPS" = 1 ] && ok "the shipped source sets exactly ONE EXIT trap (a second would cancel the first)" \
                        || bad "$N_EXIT_TRAPS EXIT traps in the shipped source, expected 1"
want 'trap .do_restore; cleanup. EXIT' "$(cat "$W/.nocomments.sh")" "and that trap does BOTH the restore and the cleanup"
# The word the run must not use: it points at the run's own scratch directory without naming it, and the path
# has a random suffix. `run_window` and the table header both used it before docs 170.
notwant 'archive' "$(cat "$W/.nocomments.sh")" "and nothing in the run calls its scratch directory an 'archive'"

# ==================================================================================================
echo
echo "== 1. --status: read-only, writes nothing byte-for-byte, and says what a run would do =="
# ==================================================================================================
scen status
H0=$(tree_hash)
run --status --thermal "$STUB/zl1-thermal.sh"
H1=$(tree_hash)
[ "$RC" = 0 ] && ok "--status exits 0" || bad "--status exited $RC"
[ "$H0" = "$H1" ] && ok "and the fake device is byte-for-byte identical afterwards" || bad "--status changed the device"
want 'a run would do this \(--status writes nothing\)' "$OUT" "it says what a run would do without doing it"
want 'window C.*the control' "$OUT" "and names the third window as the control, which is the experiment's design"
notwant 'COST-MEASURED|NO DETECTABLE COST' "$OUT" "and it prints no verdict from a run it did not make"
[ ! -s "$ACT" ] && ok "and it ran no window (the instrument was never called)" || bad "the instrument ran during --status"
want "cores:       4 " "$OUT" "and it says how many cores it found, because a renamed path and a missing knob look alike"

# ==================================================================================================
echo
echo "== 2. the refusals: each one on its own, nothing written, and the right one named =="
# ==================================================================================================
# A. the panic -> EDL escalation, in TWO shapes: a knob that READS 1, and NO knob at all -- because the
# instrument treats them the same and they mean different things on the device. "Cannot be checked" is not
# "satisfied": that sentence is the whole reason the missing case has its own scenario.
scen refused-a
dl_set 1
H0=$(tree_hash)
run --yes --thermal "$STUB/zl1-thermal.sh"
H1=$(tree_hash)
[ "$RC" = 3 ] && ok "a panic that would arm EDL: exit 3 (refused)" || bad "an armed panic guard exited $RC, expected 3"
want 'REFUSED \(A\)' "$OUT" "and it names A"
wantsq 'A PANIC WOULD ARM EDL' "$OUT" "and says what the state means"
want 'install-no-edl-on-panic\.sh --install' "$OUT" "and names the one command that fixes it"
[ "$H0" = "$H1" ] && ok "and it wrote nothing" || bad "an armed panic guard still wrote to the device"

scen refused-a-none
dl_rm
run --yes --thermal "$STUB/zl1-thermal.sh"
[ "$RC" = 3 ] && ok "no download_mode parameter at all: exit 3 (refused)" || bad "it exited $RC, expected 3"
want 'REFUSED \(A\)' "$OUT" "and it names A"
wantsq 'cannot be checked' "$OUT" "and says that 'cannot be checked' is not 'satisfied'"
want 'install-no-edl-on-panic\.sh --install' "$OUT" "and names the same remedy"

scen refused-b
H0=$(tree_hash)
run --yes --thermal "$W/no-such-instrument.sh"
H1=$(tree_hash)
[ "$RC" = 3 ] && ok "no instrument: exit 3 (refused)" || bad "no instrument exited $RC, expected 3"
want 'REFUSED \(B\)' "$OUT" "and it names B"
want 'scp zl1-thermal\.sh' "$OUT" "and says how the instrument gets there (it is pushed, not installed)"
[ "$H0" = "$H1" ] && ok "and it wrote nothing even though --yes was given" || bad "a refusal wrote to the device"
gc_all interactive && ok "the cores still read interactive" || bad "the cores are now$(gc_each)"

# C, in its FIRST shape: there are no cores at all.
scen refused-c
gc_rm
H0=$(tree_hash)
run --yes --thermal "$STUB/zl1-thermal.sh"
H1=$(tree_hash)
[ "$RC" = 3 ] && ok "no cpufreq governors at all: exit 3" || bad "no governors exited $RC, expected 3"
want 'REFUSED \(C\)' "$OUT" "and it names C"
wantsq 'no [^ ]*/sys/devices/system/cpu/cpu\*/cpufreq/scaling_governor' "$OUT" "and says the knob is not there"
[ "$H0" = "$H1" ] && ok "and it wrote nothing" || bad "a missing knob still wrote something"

# C, in its SECOND shape: the file exists and is not writable.
scen refused-c-ro
gc_ro
run --yes --thermal "$STUB/zl1-thermal.sh"
gc_rw
[ "$RC" = 3 ] && ok "a governor file that is not writable: exit 3" || bad "a read-only core exited $RC, expected 3"
want 'not-writable' "$OUT" "and it says which core is not writable, before any write"

# C, in its THIRD shape -- THE ONE THIS INSTRUMENT HAS AND ITS SIBLING DOES NOT. The file is writable and the
# value it would be written with is not offered by the kernel, so the write cannot land; a script that
# trusted the write would go on to compare two identical states and report "this cause costs nothing". The
# check is on BOTH values: a fix value the kernel does not offer is just as fatal, one line earlier.
scen refused-c-notoffered
gc_offer performance no
H0=$(tree_hash)
run --yes --thermal "$STUB/zl1-thermal.sh"
H1=$(tree_hash)
[ "$RC" = 3 ] && ok "a value the kernel does not offer: exit 3 (refused)" || bad "an unoffered governor exited $RC, expected 3"
want 'REFUSED \(C\)' "$OUT" "and it names C"
want 'no-performance' "$OUT" "and names WHICH value is missing, per core"
wantsq 'a write that cannot land' "$OUT" "and says why that matters: it would be measured as costing nothing"
[ "$H0" = "$H1" ] && ok "and it wrote nothing" || bad "an unoffered value still wrote to the device"
gc_offer performance yes

scen refused-c-notoffered-fix
gc_offer interactive no
run --yes --thermal "$STUB/zl1-thermal.sh"
[ "$RC" = 3 ] && ok "the FIX's own value missing is refused too (one line earlier)" || bad "it exited $RC, expected 3"
want 'no-interactive' "$OUT" "and it names that value, not the other one"
gc_offer performance yes

# D, in its FIRST shape: the cores disagree. There is no window A to speak of, and "mixed" is not "not
# installed" -- the remedy is different, so the message is different.
scen refused-d-mixed
gc_set performance
printf '%s' interactive > "$(gc_path 2)"
H0=$(tree_hash)
run --yes --thermal "$STUB/zl1-thermal.sh"
H1=$(tree_hash)
[ "$RC" = 3 ] && ok "cores that disagree: exit 3 (refused)" || bad "mixed cores exited $RC, expected 3"
want 'REFUSED \(D\)' "$OUT" "and it names D"
wantsq 'the cores do not agree' "$OUT" "and says they disagree rather than saying the fix is missing"
want 'cpu0=performance' "$OUT" "and prints what each core actually reads"
[ "$H0" = "$H1" ] && ok "and it wrote nothing" || bad "refusal D wrote to the device"

# D, in its SECOND shape: the cause is still installed on every core.
scen refused-d-pinned
gc_set performance
H0=$(tree_hash)
run --yes --thermal "$STUB/zl1-thermal.sh"
H1=$(tree_hash)
[ "$RC" = 3 ] && ok "the cores already pinned: exit 3" || bad "pinned cores exited $RC, expected 3"
want 'REFUSED \(D\)' "$OUT" "and it names D"
wantsq 'would not be the state the fix installs' "$OUT" "and says WHY window A would be the wrong state"
want 'reboot' "$OUT" "and names the boot-time unit as the other remedy"
[ "$H0" = "$H1" ] && ok "and it wrote nothing" || bad "refusal D wrote to the device"
gc_set interactive

# The same-value write proof is the last thing before a run. It is NOT the offer check (it passes on any file
# that is writable); what it buys is discovering a file that cannot be written BEFORE the state is changed.
# It cannot be exercised by a real write failure here -- this harness runs unprivileged, so `-w` and the write
# agree on every fixture that can be built -- so it is pinned as two asserts on the SHIPPED source, comments
# stripped: the proof exists, and it comes BEFORE the write whose value changes.
# Two traps in this one assertion, both measured in the sibling harness. (1) `want` matches its SECOND
# argument as TEXT, so a file path has to be `cat`ed. (2) These patterns are EREs, and in GNU grep a BARE `$`
# in the middle of a pattern does not match a literal `$`: the pattern `printf '%s' "$P"` does NOT match the
# text `printf '%s' "$P"`. Written in single quotes as `\$`, it does.
want 'write_gov "\$S_PROOF_BEFORE"' "$(cat "$W/.nocomments.sh")" \
  "the same-value write proof is in the shipped source"
awk '/S_PROOF_BEFORE=\$\(gov_state\)/{p=NR} /write_gov "\$BLOCKED_GOV"/{i=NR} END{ exit !(p && i && p < i) }' "$W/.nocomments.sh" \
  && ok "and it comes BEFORE the write that changes the value" \
  || bad "the proof is not before the changing write in the shipped source"

# ==================================================================================================
echo
echo "== 3. the happy path: three proved states, a delta table, and the device back where it started =="
# ==================================================================================================
scen happy
FP_DIFF=5.0
H0=$(tree_hash)
run --yes --seconds 1 --settle 0 --settle-back 0 --thermal "$STUB/zl1-thermal.sh"
H1=$(tree_hash)
[ "$RC" = 0 ] && ok "the run exits 0" || bad "the run exited $RC"
want 'wrote .performance. to all 4 core\(s\) and read .performance. back' "$OUT" \
  "the intervention is proved on every core by read-back, and no rendering is involved (a governor reads as itself)"
want 'wrote .interactive. to all 4 core\(s\) and read .interactive. back' "$OUT" "and so is the undo"
want 'wrote .interactive. back to all 4 core\(s\) and read .interactive.' "$OUT" \
  "and the same-value proof writes what the cores already hold, and requires the same back"
want 'final state.*read .interactive.' "$OUT" "and the final state is checked once more, on its own line"
want 'COST-MEASURED' "$OUT" "the verdict is cost-measured"
want 'largest warming from A to B on any tsens zone: 5\.0 C' "$OUT" "and the number is the one the fixture put there"
want 'from A to C \(the control, same state as A\):   0\.0 C' "$OUT" "and the control window came back to where it started"
want '^   thermal_zone1 tsens_tz_sensor1 +42\.5 +47\.5 +42\.5 +\+5\.0 +\+0\.0' "$OUT" \
  "the per-zone table carries A, B, C and both deltas"
want '^   thermal_zone0 bms ' "$OUT" "and a zone the governor did not move is still in the table"
want 'panic guard: disarmed \(1 parameter\(s\) read 0\)' "$OUT" \
  "a DISARMED panic guard is reported in the header, so the gate is not silent when it passes"
want 'A\. panic guard: all 1 download_mode parameter\(s\) read 0' "$OUT" \
  "and the refusal section says which parameter was checked and what it read"
want 'threshold this experiment calls a cost: 0\.2 C' "$OUT" "and the threshold is printed, so the verdict can be argued with"
want 'ambient is not controlled' "$OUT" "and the caveat is printed with the verdict, not left to the reader"
gc_all interactive && ok "every core is back on interactive" || bad "the cores are now$(gc_each)"
[ "$H0" = "$H1" ] && ok "and the whole fake device is byte-for-byte as it was before the run" || bad "the run left the tree changed"
[ "$(cat "$W/win.count" 2>/dev/null)" = 3 ] && ok "exactly three windows were taken" || bad "the instrument ran $(cat "$W/win.count" 2>/dev/null) time(s), not 3"
want 'This run used: --seconds 1 --settle 0 --settle-back 0 --poll 10' "$OUT" \
  "and the settings it ran with are printed with the caveat, so nobody has to guess which design this was"

# ==================================================================================================
echo
echo "== 3b. the wait: window C is a CONTROL only if the reading came back first (docs 170) =="
# ==================================================================================================
# The first device run of this instrument read A 40.9 -> B 47.7 -> C 48.0 and came back CONTAMINATED, and
# the shape of that contamination is what these two scenarios are about: the phone never came back down, so
# the control window read the intervention's own heat. A control window can only catch a drift that VANISHES
# by the time it is read, so the run waits -- and a reading that does not come back is its own verdict.
scen wait-returns
FP_DIFF=5.0; FP_COOL=1
H0=$(tree_hash)
run --yes --seconds 1 --settle 0 --settle-back 4 --poll 1 --thermal "$STUB/zl1-thermal.sh"
H1=$(tree_hash)
[ "$RC" = 0 ] && ok "the reading came back, so the run is a measurement: exit 0" || bad "the wait-returns run exited $RC"
want 'IT CAME BACK' "$OUT" "it says the reading came back"
want 'IT CAME BACK: 43\.5 C after 1s, against window A.s 43\.5 C' "$OUT" \
  "and prints HOW LONG it took and both numbers -- the wait is a measurement, not a delay"
want 'is therefore a CONTROL and not a second reading of the same heat' "$OUT" \
  "and says what that buys: window C is a control because of it"
want 'COST-MEASURED' "$OUT" "and the control window then did its job"
want 'from A to C \(the control, same state as A\):   0\.0 C' "$OUT" "with C back where A was"
[ "$(cat "$W/win.count" 2>/dev/null)" = 4 ] && ok "four instrument calls: three windows and ONE wait sample" \
  || bad "the instrument ran $(cat "$W/win.count" 2>/dev/null) time(s): A, B, one sample, C was expected"
[ "$H0" = "$H1" ] && ok "and the fake device is byte-for-byte as it was" || bad "the wait-returns run left the tree changed"

scen no-return
FP_DIFF=5.0; FP_COOL=-1
H0=$(tree_hash)
run --yes --seconds 1 --settle 0 --settle-back 3 --poll 1 --thermal "$STUB/zl1-thermal.sh"
H1=$(tree_hash)
[ "$RC" = 1 ] && ok "a phone whose heat does not decay inside the bound: exit 1" || bad "the no-return run exited $RC, expected 1"
want 'IT DID NOT COME BACK within 3s' "$OUT" "it says the reading did not come back, and inside which bound"
want 'NO RETURN' "$OUT" "the verdict is no-return"
want 'PRINTS NO PRICE' "$OUT" "and it says the run prints no price rather than a number"
want 'the intervention.s warming has not decayed \(thermal mass\)' "$OUT" \
  "and names BOTH things this can mean, because the instrument cannot tell them apart"
notwant 'COST-MEASURED|NO DETECTABLE COST|CONTAMINATED' "$OUT" "so no other verdict appears anywhere in the output"
notwant 'window C -- the CONTROL' "$OUT" "and window C was never read at all"
want '^   zone       type                        A      B     B-A' "$OUT" \
  "the table is the TWO windows it did take, with its own header"
want '^   thermal_zone1 tsens_tz_sensor1 +42\.5 +47\.5 +\+5\.0' "$OUT" \
  "and it still prints the warming it saw, so the run is not empty"
[ "$(cat "$W/win.count" 2>/dev/null)" = 5 ] && ok "five instrument calls: A, B and three bounded samples, and NO C" \
  || bad "the instrument ran $(cat "$W/win.count" 2>/dev/null) time(s): A, B and 3 samples were expected"
gc_all interactive && ok "and the cores are back on interactive -- it stopped early, it did not stop restoring" \
                   || bad "the cores are now$(gc_each)"
[ "$H0" = "$H1" ] && ok "and the fake device is byte-for-byte as it was" || bad "the no-return run left the tree changed"

# ==================================================================================================
echo
echo "== 3c. what the run leaves behind, and whether it says where (docs 170) =="
# ==================================================================================================
# The defect this section exists for was found ON THE DEVICE, not by reading the script: the version with
# `trap 'rm -rf "$TMP"' EXIT` early and `trap 'do_restore' EXIT` later never cleaned up at all -- the second
# EXIT trap replaces the first -- and the message that said "the whole table is in the archive" named no path.
# So both halves are asserted: a plain run removes its directory AND says so, and --keep keeps it AND says where.
scen cleanup
FP_DIFF=5.0
run --yes --seconds 1 --settle 0 --settle-back 0 --thermal "$STUB/zl1-thermal.sh"
P=$(awk '/was removed/{ sub(/ was removed.*/, ""); print $NF }' <<< "$OUT")
[ -n "$P" ] && ok "a plain run says which scratch directory it removed" || bad "nothing in the output names the scratch directory it removed"
[ -n "$P" ] && [ ! -e "$P" ] && ok "and it really is gone ($P)" || bad "the scratch directory is still on this host: ${P:-<unnamed>}"

scen keep
FP_DIFF=5.0
run --yes --seconds 1 --settle 0 --settle-back 0 --keep --thermal "$STUB/zl1-thermal.sh"
P=$(awk '/--keep: this run/{ sub(/ \(deltas.*/, ""); print $NF }' <<< "$OUT")
[ -n "$P" ] && ok "--keep names the directory" || bad "--keep does not name the directory"
[ -d "$P" ] && ok "and it is still there ($P)" || bad "the directory --keep promised is not there: ${P:-<unnamed>}"
[ -f "$P/deltas" ] && ok "with the delta table in it, which is what 'the whole table' was pointing at" \
                   || bad "the kept directory has no deltas file"
[ -f "$P/win.A" ] && [ -f "$P/win.B" ] && [ -f "$P/win.C" ] && ok "and the three windows it took" \
                   || bad "the kept directory is missing a window"
rm -rf "$P"
[ ! -e "$P" ] && ok "and the harness cleaned up after itself" || bad "the harness left $P behind"

# THE WHOLE TABLE, not the top N. The device run printed twelve rows and told the reader the rest were "in
# the archive"; with the path unnamed that was the same as printing nothing.
scen wholetable
FP_DIFF=5.0; FP_ZONES=13
run --yes --seconds 1 --settle 0 --settle-back 0 --thermal "$STUB/zl1-thermal.sh"
NROWS=$(grep -cE '^   thermal_zone[0-9]+ ' <<< "$OUT")
NCLAIM=$(sed -n 's/.*(\([0-9][0-9]*\) zone(s) in this table.*/\1/p' <<< "$OUT")
[ -n "$NCLAIM" ] && ok "the table states how many rows it has ($NCLAIM)" || bad "the table states no row count"
[ -n "$NCLAIM" ] && [ "$NROWS" = "$NCLAIM" ] && ok "and every one of them is printed ($NROWS lines)" \
  || bad "the table claims $NCLAIM row(s) and printed $NROWS"
want '^   thermal_zone12 tsens_tz_sensor12 ' "$OUT" "including the thirteenth zone, which the old truncation cut"
notwant 'the whole table is in the archive' "$OUT" "and nothing claims a table is somewhere else"
notwant 'more; the whole' "$OUT" "and there is no '... N more' line at all"

# ==================================================================================================
echo
echo "== 4. the verdict can come out AGAINST the fix, and can be called off by its own control =="
# ==================================================================================================
scen nocost
FP_DIFF=0.1
run --yes --seconds 1 --settle 0 --settle-back 0 --thermal "$STUB/zl1-thermal.sh"
[ "$RC" = 0 ] && ok "a governor worth less than the resolution: exit 0" || bad "it exited $RC"
want 'NO DETECTABLE COST' "$OUT" "and the verdict is no-detectable-cost -- the script coming out against itself"
want 'coming out AGAINST the fix it was built around' "$OUT" "said out loud, so the verdict is not read as a failure"

scen drift
# The phone warms 1.0 C per window with NOTHING changed, and pinning the cores is worth 1.5 C. A two-window
# A/B would report 2.5 C as the governor's price; the control window is the only thing that can tell.
FP_DIFF=1.5
FP_DRIFT=1.0
run --yes --seconds 1 --settle 0 --settle-back 0 --thermal "$STUB/zl1-thermal.sh"
[ "$RC" = 1 ] && ok "a drifting phone: exit 1 (a statement about the run)" || bad "the drift scenario exited $RC, expected 1"
want 'CONTAMINATED' "$OUT" "and the verdict is contaminated"
want 'the SAME state as A -- is still 2\.0 C' "$OUT" "with the control window's own number beside it"
want 'was not caused by it' "$OUT" "and it says the warming was not caused by the governor"

scen otherzone
# pm8994 (the power rails) runs 10 C hotter with the cores pinned while the tsens zones move 5 C. The verdict
# is about the SoC's OWN sensors; a rail that follows the charger is not one of them.
FP_DIFF=5.0
FP_OTHER_DIFF=10.0
run --yes --seconds 1 --settle 0 --settle-back 0 --thermal "$STUB/zl1-thermal.sh"
want 'largest warming from A to B on any tsens zone: 5\.0 C' "$OUT" \
  "the maximum is taken over the tsens zones, not over every zone in the table"
notwant 'largest warming from A to B on any tsens zone: 10\.0' "$OUT" "so a hotter rail is not reported as the SoC's answer"
want '^   thermal_zone22 pm8994_tz +42\.0 +52\.0 +42\.0 +\+10\.0 +\+0\.0' "$OUT" \
  "while that zone is still IN the table, so the reader can see it"

# ==================================================================================================
echo
echo "== 5. an instrument that answers nothing: no table, no verdict =="
# ==================================================================================================
scen empty
run --yes --seconds 1 --settle 0 --settle-back 0 --thermal "$W/quiet-instrument.sh"
[ "$RC" = 1 ] && ok "an instrument that prints no zones: exit 1" || bad "the empty-instrument run exited $RC, expected 1"
want 'NO ZONE WAS READABLE IN ALL THREE WINDOWS' "$OUT" "and it says there is no table rather than printing a delta of zeros"
notwant 'COST-MEASURED|NO DETECTABLE COST' "$OUT" "and it prints no verdict at all"
gc_all interactive && ok "and the cores were still put back" || bad "the cores are now$(gc_each)"

# ==================================================================================================
echo
echo "== 6. the trap: what is left on a path nobody wrote by hand =="
# ==================================================================================================
scen interrupt
FP_DIFF=5.0
runbg "$S/interrupt.txt" "$RW" --yes --seconds 1 --settle 3 --settle-back 0 --thermal "$STUB/zl1-thermal.sh"
kill_pinned
gc_all performance && ok "the kill landed in the pinned window (every core really reads performance)" \
                   || bad "the kill did not land in the pinned window -- nothing about the trap is being tested"
wait "$BG_PID"; BG_RC=$?
OUT=$(cat "$S/interrupt.txt" 2>/dev/null)
[ "$BG_RC" != 0 ] && ok "an interrupted run comes back non-zero (rc=$BG_RC)" \
                  || bad "the interrupted run exited 0 -- a signal that does not end the run"
notwant 'the state it started in' "$OUT" \
  "and it did not reach its closing line, so nothing overwrote the restore on the way out"
gc_all interactive && ok "and every core is back on interactive -- the trap, not the happy path, restored it" \
                   || bad "the interrupt left the cores at$(gc_each)"
want '\[trap\]' "$OUT" "and the trap says so out loud, on the way out"
want 'verified by read-back' "$OUT" "with its own read-back rather than a promise"

# ==================================================================================================
echo
echo "== 7. the mutations: each one must change what the checks above observe =="
# ==================================================================================================
# (m0) a fifth redirect target: the whitelist in section 0 is the only thing that can see it.
if mut m0-addwrite 's#^set -u$#set -u\nprintf x > /tmp/zl1-governor-temp-ab-evil.txt#'; then
  N2=$(offenders "$W/mut-m0-addwrite.sh")
  [ "$N2" = 1 ] && ok "mutation 'a fifth write target': the whitelist sees it (the check in section 0 is live)" \
                || bad "the mutant's extra redirect was not seen ($N2 offenders)"
  want 'zl1-governor-temp-ab-evil' "$(cat "$W/.targets")" "and the offending path is named, not just counted"
fi
# (m1) the control window ignored: the drift scenario's warming is reported as the governor's price.
if mut m1-nocontrol 's#if (ca >= ba / 2)                 { print "contaminated"; exit }#if (0)                              { print "contaminated"; exit }#'; then
  scen mut-m1
  FP_DIFF=1.5; FP_DRIFT=1.0
  mutrun m1-nocontrol --yes --seconds 1 --settle 0 --settle-back 0 --thermal "$STUB/zl1-thermal.sh"
  [ "$RC" = 0 ] && ok "mutation 'control ignored': the drifting phone now reads as a result (the check is live)" \
                || bad "the 'control ignored' mutant exited $RC"
  want 'COST-MEASURED' "$OUT" "and it prints the drift as if the governor had done it"
  notwant 'CONTAMINATED' "$OUT" "with nothing anywhere saying the third window disagreed"
fi
# (m2) the resolution removed: something this experiment cannot resolve is reported as a cost.
if mut m2-threshold 's#if (ba < 0.2)                     { print "no-detectable-cost"; exit }#if (0)                              { print "no-detectable-cost"; exit }#'; then
  scen mut-m2
  FP_DIFF=0.1
  mutrun m2-threshold --yes --seconds 1 --settle 0 --settle-back 0 --thermal "$STUB/zl1-thermal.sh"
  want 'COST-MEASURED' "$OUT" "mutation 'no threshold': 0.1 C -- one step of the instrument -- is reported as a cost"
fi
# (m3) THE INTERVENTION MADE A NO-OP: the read-back is what catches it, and without it the run would go on to
# measure two identical states and print a number for a change it never made. This mutant stands in for every
# version of "the write did not land" -- it is the same branch the unoffered-governor case takes on the device.
if mut m3-noreadback 's#^    printf .%s. "\$zl1_want" > "\$zl1_g" 2>/dev/null || return 1$#    : #'; then
  scen mut-m3
  FP_DIFF=5.0
  mutrun m3-noreadback --yes --seconds 1 --settle 0 --settle-back 0 --thermal "$STUB/zl1-thermal.sh"
  [ "$RC" = 4 ] && ok "mutation 'write that did not land': exit 4, refused to print a verdict" \
                || bad "the no-op mutant exited $RC, expected 4"
  want 'THE INTERVENTION DID NOT LAND' "$OUT" "and the message is the one that would otherwise hide a real experiment"
  notwant '^   -> ' "$OUT" "and it printed no verdict at all"
  gc_all interactive && ok "and the cores are where the experiment found them (it never moved them)" \
                     || bad "the no-op mutant left the cores at$(gc_each)"
fi
# (m4) the trap disarmed: `do_restore` returns without doing anything, so an interrupted run leaves every core
# pinned with nothing holding the fix's value. This is what makes section 6's check mean something.
if mut m4-notrap 's#^  \[ "\$WROTE" = 1 \] || return 0$#  return 0#'; then
  scen mut-m4
  FP_DIFF=5.0
  runbg "$S/trap.txt" "$W/mut-m4-notrap.rw.sh" --yes --seconds 1 --settle 3 --settle-back 0 --thermal "$STUB/zl1-thermal.sh"
  kill_pinned
  wait "$BG_PID" 2>/dev/null
  gc_all performance && ok "mutation 'trap disarmed': the interrupt leaves the cores PINNED (the trap is the restorer)" \
                     || bad "the 'trap disarmed' mutant left the cores at$(gc_each)"
fi
# (m5) THE OFFER CHECK REMOVED -- the refusal that is specific to this knob. Every other scenario's cores DO
# offer `performance`, so a check that can never flag anything is invisible from the passing side; the mutant
# has to be driven by the scenario that HAS something to flag (the value removed from the kernel's list) and
# seen to stop refusing.
if mut m5-nooffer 's@gov_offered "\$zl1_g" "\$BLOCKED_GOV" ||@: ||@'; then
  scen mut-m5
  gc_offer performance no
  FP_DIFF=5.0
  mutrun m5-nooffer --yes --seconds 1 --settle 0 --settle-back 0 --thermal "$STUB/zl1-thermal.sh"
  notwant 'REFUSED \(C\)' "$OUT" "mutation 'no offer check': a governor the kernel does not offer no longer refuses"
  want 'COST-MEASURED|NO DETECTABLE COST|CONTAMINATED' "$OUT" \
    "and the run proceeds -- which is the whole cost of the mutant, on a device where the write would not land"
  gc_offer performance yes
fi
# (m7) the panic gate removed: every other scenario has the knob reading 0, so a comparison that can never
# flag anything is invisible from the passing side -- and the device this experiment would then run on is one
# where a mistake costs a 10-20 s power hold instead of a reboot.
if mut m7-nopanic 's@^  \[ "\$zl1_v" = 0 \] || DL_BAD=@  : || DL_BAD=@'; then
  scen mut-m7
  dl_set 1
  FP_DIFF=5.0
  mutrun m7-nopanic --yes --seconds 1 --settle 0 --settle-back 0 --thermal "$STUB/zl1-thermal.sh"
  notwant 'REFUSED \(A\)' "$OUT" "mutation 'no panic gate': an armed panic guard no longer refuses (the gate is live)"
  want 'COST-MEASURED|NO DETECTABLE COST|CONTAMINATED' "$OUT" \
    "and the run proceeds -- which is the whole cost of the mutant, on a device where it must not"
  dl_set 0
fi
# (m6) the empty-table guard removed: no reading at all becomes a verdict of zeros.
if mut m6-notable 's#^if \[ ! -s "\$TMP/deltas" \]; then$#if false; then#;s#^if \[ -z "\$TSENS" \]; then$#if false; then#'; then
  scen mut-m6
  mutrun m6-notable --yes --seconds 1 --settle 0 --settle-back 0 --thermal "$W/quiet-instrument.sh"
  want 'COST-MEASURED|NO DETECTABLE COST' "$OUT" \
    "mutation 'no table guard': an instrument that printed nothing still produces a verdict"
  want 'NO DETECTABLE COST' "$OUT" \
    "and with no zones at all the number it prices is an empty string, read as 0 -- the guards are what stop it"
fi
# (m8) THE TABLE TRUNCATED AGAIN -- the device run's own defect, put back. Section 3c asserts the row count
# against the table's own claim, so a cap at two rows has to be visible: it is not "a shorter table", it is a
# table with holes that nothing names.
if mut m8-truncate "s#^sort -k6,6gr \"\$TMP/deltas\" | awk '{#sort -k6,6gr \"\$TMP/deltas\" | awk 'NR <= 2 {#"; then
  scen mut-m8
  FP_DIFF=5.0; FP_ZONES=13
  mutrun m8-truncate --yes --seconds 1 --settle 0 --settle-back 0 --thermal "$STUB/zl1-thermal.sh"
  NR2=$(grep -cE '^   thermal_zone[0-9]+ ' <<< "$OUT")
  NR2CLAIM=$(sed -n 's/.*(\([0-9][0-9]*\) zone(s) in this table.*/\1/p' <<< "$OUT")
  want 'sorted by B-A; every one is printed' "$OUT" \
    "mutation 'table truncated': the line claiming EVERY row is printed is still there -- that is the cost"
  [ "$NR2" -lt "$NR2CLAIM" ] && ok "while only $NR2 of the $NR2CLAIM row(s) printed, so the claim and the table disagree" \
                             || bad "the truncation did not take: $NR2 rows printed against a claim of $NR2CLAIM"
fi
# (m9) THE WAIT'S ANSWER IGNORED: the no-return phone gets a verdict anyway. Every other scenario's reading
# COMES BACK, so a branch that never runs cannot be seen from the passing side -- the mutant has to be driven
# by the scenario that has a reading which does not, and it has to be seen to print a price.
if mut m9-ignorewait 's#^  if \[ "\$RETURNED" = 1 \]; then$#  if true; then#'; then
  scen mut-m9
  FP_DIFF=5.0; FP_COOL=-1
  mutrun m9-ignorewait --yes --seconds 1 --settle 0 --settle-back 3 --poll 1 --thermal "$STUB/zl1-thermal.sh"
  notwant 'NO RETURN' "$OUT" "mutation 'wait ignored': the no-return phone no longer produces that verdict"
  want 'COST-MEASURED|CONTAMINATED|NO DETECTABLE COST' "$OUT" \
    "and it prints a PRICE instead -- the whole cost of the mutant, on a phone where there is no control"
fi
# (m10) THE CLEANUP DISARMED -- the device's own defect, one step in: the trap keeps the restore and drops the
# cleanup, so the scratch directory survives every run. Section 3c is what can see it, and note that NOTHING
# about the restore changes: every other assertion in this file still passes on this mutant.
if mut m10-nocleanup "s#^trap 'do_restore; cleanup' EXIT\$#trap 'do_restore' EXIT#"; then
  scen mut-m10
  FP_DIFF=5.0
  # FILES, not here-strings: `comm -13 <<< "" <<< "$AFTER"` reports "missing operand" when the first side is
  # empty, which reads as "no leftover" -- a false pass on the one scenario that has to have one.
  find /tmp -maxdepth 1 -type d -name 'zl1-governor-temp-ab.*' 2>/dev/null | sort > "$W/.left.before"
  mutrun m10-nocleanup --yes --seconds 1 --settle 0 --settle-back 0 --thermal "$STUB/zl1-thermal.sh"
  find /tmp -maxdepth 1 -type d -name 'zl1-governor-temp-ab.*' 2>/dev/null | sort > "$W/.left.after"
  notwant 'was removed' "$OUT" "mutation 'cleanup disarmed': the run no longer says it removed anything"
  comm -13 "$W/.left.before" "$W/.left.after" > "$W/.left.new"
  if [ -s "$W/.left.new" ]; then
    ok "and it left its scratch directory on this host, silently: $(tr '\n' ' ' < "$W/.left.new")"
    xargs -r rm -rf < "$W/.left.new"
  else
    bad "no directory was left behind, so the cleanup is not what section 3c is testing"
  fi
fi

# ==================================================================================================
echo
echo "== 8. this harness did not edit the tree it tests =="
# ==================================================================================================
SRC_SHA_AFTER=$(sha256sum "$SRC" | awk '{print $1}')
[ "$SRC_SHA_BEFORE" = "$SRC_SHA_AFTER" ] \
  && ok "$(basename "$SRC") is byte-identical to what it was before this run" \
  || bad "$(basename "$SRC") CHANGED during this run -- a fixture is writing into the repository"
[ ! -e /tmp/zl1-governor-temp-ab-evil.txt ] \
  && ok "and the mutant's extra write target does not exist -- m0 is INSPECTED, never run" \
  || bad "something wrote the mutant's target, so the whitelist check is not the only thing watching"

# ==================================================================================================
echo
echo "== 9. the citation in the health check is checked by the thing it cites =="
# ==================================================================================================
HEALTH="$HERE/zl1-health-check.sh"
if [ -r "$HEALTH" ]; then
  cited=$(sed -e 's/always "/ /g' -e 's/"$//' "$HEALTH" | tr '\n' ' ' |
            sed -n 's/.*zl1-governor-temp-ab-selftest\.sh[ ,(]*\([0-9][0-9]*\) checks.*/\1/p')
  total=$((PASS + FAIL + 1))
  if [ -z "$cited" ]; then
    bad "the health check does not cite this harness's count -- either the citation is gone or its wording changed"
  elif [ "$cited" = "$total" ]; then
    ok "the health check cites $cited checks, and this run has exactly that many"
  else
    bad "the health check cites $cited checks, but this harness has $total -- fix host/zl1-health-check.sh"
  fi
else
  bad "cannot read $HEALTH -- its citation is unchecked"
fi

echo
if [ "$KEEP" = 1 ]; then
  echo "kept: $W (the rewritten script, the stubs, the mutants, the fake device)"
else
  rm -rf "$W"
fi
printf 'pass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
exit 0
