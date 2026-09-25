#!/usr/bin/env bash
# zl1 ladder-temperature A/B -- offline self-test. Host-side, touches no device, needs no phone.
#
# Why this exists. `scripts/device/zl1-ladder-temp-ab.sh` writes the SAME module parameter the third heat
# fix owns, twice, in order to price that fix in degrees. So the guarantee a read-only probe gets for free
# ("not one byte changed") is not available here, and the guarantee has to be a different one, stated
# exactly and checked:
#
#   1. THE SET OF FILES IT CAN WRITE IS A CLOSED, NAMED SET. Section 0 reads the redirect targets out of
#      the SHIPPED source with the comments stripped, and requires every one of them to be either the
#      parameter or a file inside the script's own `mktemp -d`. Mutation m0 adds a fifth target and the
#      harness has to see it.
#   2. --status WRITES NOTHING, byte-for-byte, and neither does any refusal -- even one given --yes.
#      Sections 1 and 2 hash the whole fake device around those runs.
#   3. THE HAPPY PATH ENDS WHERE IT STARTED: the parameter reads N again, the three states it passes
#      through are each PROVED by read-back inside the run's own output, and the tree is unchanged.
#      Section 3.
#   4. THE TRAP IS WHAT RESTORES IT. A run interrupted after the write, with the fix's value held by
#      nobody else, must leave the parameter at 0/N -- so the restore is not the happy path's last line
#      but a trap that fires on a path nobody wrote by hand. Section 6, and m4 is the trap disarmed.
#   5. THE VERDICT CAN COME OUT AGAINST THE FIX (`no-detectable-cost`) and can be CALLED OFF BY ITS OWN
#      CONTROL WINDOW (`contaminated`). Both are scenarios, not paragraphs. Sections 4.
#
# How it works: **the stub directory IS the device**, the same construction this family's other harnesses
# use -- the script runs as itself against a fake root, with PATH for the child set to `$STUB:$MINBIN` and
# MINBIN a sandbox of symlinks to the real coreutils. ONE STUB HERE IS LOAD-BEARING RATHER THAN
# CONVENIENT: the instrument. The whole experiment is "the zones move when the ladder's state moves", so a
# stub printing a fixed table would make every delta zero and every scenario would be testing the absence
# of the thing it set up. This stub computes its table from THE FAKE PARAMETER'S OWN VALUE plus a
# per-window drift, so "the ladder costs 5.0 C" is a fact of the fixture that the verdict has to recover
# -- and `FP_DRIFT` makes the same table warm up with NOTHING changed, which is what the control window
# exists to catch.
#
# The instrument's output SHAPE is not invented: it is what the real `zl1-thermal.sh` printed on the device
# on 2026-09-25 (evidence/three-heat-causes-installed-steady-state-2026-09-25.log), including a zone line
# with a trailing note for a type its unit table does not know, and the `hottest:` line.
#
# Usage: zl1-ladder-temp-ab-selftest.sh [--keep]
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
SRC="$HERE/../device/zl1-ladder-temp-ab.sh"
[ -r "$SRC" ] || { echo "cannot read $SRC" >&2; exit 2; }
# Kept for the tree check at the end: this harness rewrites the subject into a fake root and runs mutants
# of it, so "the shipped file is byte-identical afterwards" is the only thing standing between a fixture
# bug and a quiet edit of the thing under test (the family records one harness that replaced a 409-line
# instrument with one comment line while every assertion stayed green).
SRC_SHA_BEFORE=$(sha256sum "$SRC" | awk '{print $1}')

W="${TMPDIR:-/tmp}/zl1-ladder-temp-ab-selftest"
# `root`, not `dev`: the fake root's own path must not contain a path the rewriter hunts for.
FR="$W/root"
STUB="$W/stub"
MINBIN="$W/minbin"
ACT="$W/actions"
rm -rf "$W"
mkdir -p "$STUB" "$MINBIN" "$FR" || exit 2
: > "$ACT"

# `sh`, `sleep` and `date` are here because the SUBJECT calls them by name: it runs the instrument with
# `sh <path>`, it waits a settle with `sleep`, and it stamps its header with `date`. A curated sandbox PATH
# that lacks a tool silently disables the behaviour that needs it -- the family has recorded that trap
# twice -- so the tools the subject names are in the sandbox and the `sh` is the same interpreter the
# harness runs the subject with.
for t in awk cat date grep head ls mktemp readlink rm sed sh sleep sort tr wc; do
  p="$(type -P "$t" 2>/dev/null)" || continue
  [ -n "$p" ] && ln -sf "$p" "$MINBIN/$t"
done
for t in awk cat date grep head ls readlink sed sh sleep sort tr wc; do
  [ -x "$MINBIN/$t" ] || { echo "the sandbox bin is missing $t -- the harness cannot run the script honestly" >&2; exit 2; }
done
REAL_TR="$(type -P tr)"; [ -n "$REAL_TR" ] || { echo "no real tr on this host" >&2; exit 2; }
SH_BIN="$(type -P sh 2>/dev/null)"; [ -n "$SH_BIN" ] || SH_BIN=/bin/sh
[ -x "$SH_BIN" ] || { echo "no /bin/sh to run the subject with" >&2; exit 2; }

# --- the fake device ------------------------------------------------------------------------------
# The parameter is a bool module parameter, so the FILE stores 0/1 and a reader RENDERS that as N/Y
# (docs 163). The fixture keeps the two apart, because the first version did not and every "was it put
# back?" assertion then compared a stored `0` with a rendered `N` -- see `fp_raw` for the one place the
# stored byte is the thing being asserted about.
mkdir -p "$FR/sys/module/lpm_levels/parameters" "$FR/proc/device-tree"
FP="$FR/sys/module/lpm_levels/parameters/sleep_disabled"
fp_set() { # a state, written as the DEVICE stores it: `fp_set N` puts a 0 in the file, as sysfs would
  case "$1" in N|n|0|off) printf '0' > "$FP" ;; Y|y|1|on) printf '1' > "$FP" ;; *) printf '%s' "$1" > "$FP" ;; esac
}
fp_now() { "$STUB/tr" -d '\n' < "$FP" 2>/dev/null; }   # the DEVICE's alphabet: what a reader gets
fp_raw() { cat "$FP" 2>/dev/null; }                     # the stored byte, for the one assertion about it
fp_rm()  { rm -f "$FP"; }

# The panic -> EDL knob, which the instrument reads before anything else now. It is a SECOND parameter
# under its own module directory, so the instrument's glob (`/sys/module/*/parameters/download_mode`)
# sees exactly what the device has: ONE. A fixture with none of them is a scenario of its own below.
mkdir -p "$FR/sys/module/msm_poweroff/parameters"
DL="$FR/sys/module/msm_poweroff/parameters/download_mode"
dl_set() { printf '%s' "$1" > "$DL"; }
dl_rm()  { rm -f "$DL"; }
printf 'msm8996\0' > "$FR/proc/device-tree/compatible"
printf 'LeEco zl1\0' > "$FR/proc/device-tree/model"
printf 'console=tty0 lpm_levels.sleep_disabled=1 androidboot.foo=bar\n' > "$FR/proc/cmdline"
fp_set N
dl_set 0

# --- the instrument, which is the load-bearing stub -------------------------------------------------
# QUOTED heredoc, and the fixture paths arrive as ENVIRONMENT at run time: an unquoted one would have bash
# eat the backslashes this stub needs to pass to awk, and the family has a round of failures from exactly
# that (docs 104). The table is a function of the fake parameter and of the window number:
#
#     tsens zone i = BASE + i*0.5 + (DIFF if the ladder is BLOCKED) + (DRIFT * (window - 1))
#
# so DIFF is "what the ladder costs" as a fact about the fake phone and DRIFT is "the phone warming up on
# its own". The window counter is a file, because the instrument is a process and cannot remember anything
# between calls -- which is also true of the real one.
cat > "$STUB/zl1-thermal.sh" <<'EOF'
#!/bin/sh
v=$(cat "${FP_PARAM:-/nonexistent}" 2>/dev/null)
case "$v" in 1|Y|y) blocked=1 ;; *) blocked=0 ;; esac
n=$(cat "${FP_COUNT:-/nonexistent}" 2>/dev/null)
case "$n" in ''|*[!0-9]*) n=0 ;; esac
n=$((n + 1))
printf '%s' "$n" > "${FP_COUNT:-/dev/null}" 2>/dev/null
printf 'window n=%s blocked=%s\n' "$n" "$blocked" >> "${FP_ACT:-/dev/null}"
awk -v b="$blocked" -v n="$n" -v base="${FP_BASE:-42.0}" -v diff="${FP_DIFF:-0}" -v drift="${FP_DRIFT:-0}" \
    -v other="${FP_OTHER_DIFF:-0}" '
  BEGIN {
    hot = base + drift * (n - 1) + (b ? diff : 0)
    printf "zl1 thermal budget :: window %d :: read-only\n", n
    printf "  busy 0.80 of 4 cores (20%%), of which iowait 0.00 cores\n"
    printf "== thermal zones:\n"
    for (i = 0; i < 4; i++) printf "   thermal_zone%d tsens_tz_sensor%d             %.1f C\n", i, i, hot + i * 0.5
    printf "   thermal_zone0 bms                          35.7 C   <- type not in the unit table; assumed milli-degC (raw 35700)\n"
    printf "   thermal_zone22 pm8994_tz                    %.1f C\n", base + drift * (n - 1) + (b ? other : 0)
    printf "   hottest: tsens_tz_sensor0 %.1f C  (raw %d = deci-degC, of 38 zones; 1 flagged above)\n", hot, hot * 10
    printf "== cpufreq:\n   cpu0/cpufreq           governor=interactive  cur=307200   kHz\n"
  }'
exit "${FP_INSTRUMENT_RC:-0}"
EOF
chmod +x "$STUB/zl1-thermal.sh"

# An instrument that answers nothing at all: section 5 and mutation m6 both need one. It is a FILE and not
# a one-off command line, because the subject takes the instrument's PATH as an argument -- and a fixture
# that has to be spelled inline is a fixture no assertion can point at.
cat > "$W/quiet-instrument.sh" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$W/quiet-instrument.sh"

# --- the `tr` stub: THE DEVICE'S TYPE RENDERING, and a write that does not take ----------------------
# `sleep_disabled` is a bool module parameter, so the file STORES 0/1 and the kernel's sysfs `show`
# RENDERS them as N/Y (docs 163). A plain text fixture cannot express that: it would hold whatever was
# written and hand a reader back a `1`, which is precisely the comparison that made this repository refuse
# its own successful write on 2026-09-25. So the rendering lives in the one tool the script reads the
# parameter WITH (`rd` is `tr -d '\n' < file`), and the stub delegates to the real `tr` for every other
# file -- which the three probes below check, because a `readlink` that resolved to nothing would make
# every alphabet scenario pass while testing a plain-text fixture.
#
# FAKE_STUCK is the second thing a text file cannot express: a write that LANDS and whose value does not
# take. With FAKE_STUCK=N the parameter renders `N` whatever the file holds, which is how a scenario can
# reach the "the intervention did not land" branch -- a branch this harness would otherwise have to leave
# to an assert on the source.
cat > "$STUB/tr" <<EOF
#!/bin/sh
in=\$(readlink /proc/self/fd/0 2>/dev/null)
case "\$in" in
*/parameters/sleep_disabled)
  case "\${FAKE_STUCK:-}" in
  N) printf 'N'; exit 0 ;;
  esac
  v=\$(cat "\$in" 2>/dev/null | sed 's/[[:space:]]*\$//')
  case "\$v" in
  0) printf 'N' ;;
  1) printf 'Y' ;;
  *) printf '%s' "\$v" ;;
  esac
  exit 0 ;;
esac
exec $REAL_TR "\$@"
EOF
chmod +x "$STUB/tr"
printf 'N' > "$W/.stubprobe"
[ "$( "$STUB/tr" -d '\n' < "$W/.stubprobe" )" = 'N' ] \
  || { echo "the tr stub does not delegate for a file that is not the parameter" >&2; exit 2; }
printf '0' > "$FP"
[ "$( "$STUB/tr" -d '\n' < "$FP" )" = 'N' ] \
  || { echo "the tr stub does NOT render the parameter as N -- every alphabet scenario would be vacuous" >&2; exit 2; }
printf '1' > "$FP"
[ "$( "$STUB/tr" -d '\n' < "$FP" )" = 'Y' ] \
  || { echo "the tr stub does not render a stored 1 as Y -- the intervention proof would be untestable" >&2; exit 2; }
[ "$( FAKE_STUCK=N "$STUB/tr" -d '\n' < "$FP" )" = 'N' ] \
  || { echo "FAKE_STUCK=N does not force the rendered N -- the 'did not land' scenario would be vacuous" >&2; exit 2; }
fp_set N

# --- the script under test, rewritten into the fake device ------------------------------------------
# TWO PASSES through tokens, for the reason its siblings record: a one-pass rewrite is a cascade, and a
# cascaded path is a script reading something that cannot exist while every scenario still passes. It is a
# FUNCTION because a MUTATION has to be rewritten the same way before it can be run.
rewrite() { # $1 = a source (shipped or mutated), $2 = where to write the fake-device copy
  sed -e 's#/proc/device-tree#__ZDT__#g' \
      -e 's#/proc/cmdline#__ZCMD__#g' \
      -e 's#/sys/module#__ZMOD__#g' "$1" > "$W/.pass1.sh"
  sed -e "s#__ZDT__#$FR/proc/device-tree#g" \
      -e "s#__ZCMD__#$FR/proc/cmdline#g" \
      -e "s#__ZMOD__#$FR/sys/module#g" "$W/.pass1.sh" > "$2"
}
RW="$W/ladder-temp-ab.sh"
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
for pair in "__ZDT__:$FR/proc/device-tree" "__ZMOD__:$FR/sys/module" "__ZCMD__:$FR/proc/cmdline"; do
  tok="${pair%%:*}"; path="${pair#*:}"
  [ "$(cnt "$tok" "$W/pass1.sh")" -gt 0 ] || { echo "$tok never appears in pass 1 -- that path is not in the script" >&2; exit 2; }
  [ "$(cnt "$tok" "$W/pass1.sh")" = "$(cnt "$path" "$RW")" ] \
    || { echo "$tok did not expand to $path exactly as many times as it appears" >&2; exit 2; }
done
grep -qF "$FR$FR" "$RW" && { echo "a rewrite cascaded: $FR appears twice in a row" >&2; exit 2; }
grep -qF "$FR/sys/module/*/parameters/sleep_disabled" "$RW" \
  || { echo "the parameter glob was not rewritten -- the script would read THIS host's /sys" >&2; exit 2; }

# --- the run helpers ------------------------------------------------------------------------------
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
# The haystack reaches the reader DIRECTLY, and that is not a style choice: this harness sets `pipefail`,
# and `printf '%s\n' "$2" | grep -q` under pipefail reports the WRITER's death as the check's answer (docs
# 134 -- the reader exits at the first match, the writer is killed by SIGPIPE, and the pipeline's status is
# 141). The trial's harness was fixed to this form in the same stage; the first version of THIS file was
# written with the old one and the family's invariant section caught it, which is what that section is for.
want()    { if grep -Eq -- "$1" <<< "$2"; then ok "$3"; else bad "$3"; sed 's/^/        | /' <<< "$2"; fi; }
notwant() { if grep -Eq -- "$1" <<< "$2"; then bad "$3"; grep -E -- "$1" <<< "$2" | sed 's/^/        | /'; else ok "$3"; fi; }
# For the messages the subject WRAPS across lines. An assertion on a wrapped phrase is an assertion on
# where the wrap happens to fall -- a property of the message's length, not of what it says -- and two
# refusal messages here are long enough to wrap inside the phrase that matters. These match the message
# with its whitespace collapsed, so the assertion is about the words.
squash() { printf '%s' "$1" | tr '\n' ' ' | tr -s ' \t' ' '; }
wantsq() { local sq; sq=$(squash "$2"); if grep -Eq -- "$1" <<< "$sq"; then ok "$3"; else bad "$3"; sed 's/^/        | /' <<< "$2"; fi; }

# The whole fake device, hashed. "Writes nothing" is checked against THIS, so a write anywhere under the
# fake root -- including a new file -- changes the hash.
tree_hash() { (cd "$FR" && find . -type f -print0 | sort -z | xargs -0 sha256sum) | sha256sum | awk '{print $1}'; }

FP_DIFF=0; FP_DRIFT=0; FP_BASE=42.0; FP_OTHER_DIFF=0; FP_INSTRUMENT_RC=0; FAKE_STUCK=""
scen() { # name -- reset the device to the healthy, installed state
  S="$W/out/$1"; rm -rf "$S"; mkdir -p "$S"
  FP_DIFF=0; FP_DRIFT=0; FP_BASE=42.0; FP_OTHER_DIFF=0; FP_INSTRUMENT_RC=0; FAKE_STUCK=""
  fp_set N
  dl_set 0
  rm -f "$W/win.count"
  : > "$ACT"
}
env_for() { printf '%s\n' "FP_PARAM=$FP" "FP_COUNT=$W/win.count" "FP_ACT=$ACT" "FP_DIFF=$FP_DIFF" \
  "FP_DRIFT=$FP_DRIFT" "FP_BASE=$FP_BASE" "FP_OTHER_DIFF=$FP_OTHER_DIFF" "FP_INSTRUMENT_RC=$FP_INSTRUMENT_RC" \
  "FAKE_STUCK=$FAKE_STUCK"; }

run() { # the script's own args...
  local e; e=$(env_for)
  OUT=$(env PATH="$STUB:$MINBIN" $e "$SH_BIN" "$RW" "$@" 2>&1); RC=$?
}
mutrun() { # mutant name, then the script's own args...
  local m="$1"; shift
  local e; e=$(env_for)
  OUT=$(env PATH="$STUB:$MINBIN" $e "$SH_BIN" "$W/mut-$m.rw.sh" "$@" 2>&1); RC=$?
}
# Killing a run a fixed number of seconds in tests the TIMER and not the trap. The first version killed 2 s
# in, by which time the run had already passed the window -- and it passed for the wrong reason too: the
# signal handler restored and then the shell CARRIED ON to the end of the experiment (that is the defect the
# script now fixes with a handler that exits). What the check needs is a kill somewhere the state is KNOWN,
# and the state worth knowing is "the ladder is blocked": the only window in which a run that dies leaves an
# experiment behind. So these wait for the subject's OWN write to appear in the parameter.
wait_blocked() { # up to 10 s for the subject to be in the blocked window; fails if it exits first
  local n=0
  while [ "$n" -lt 100 ]; do
    [ "$(fp_raw)" = 1 ] && return 0
    kill -0 "$BG_PID" 2>/dev/null || return 1
    sleep 0.1; n=$((n + 1))
  done
  return 1
}
kill_blocked() { # TERM the background run while the ladder is provably blocked
  if wait_blocked; then kill -TERM "$BG_PID" 2>/dev/null
  else bad "  (the run left the blocked window before it could be interrupted)"; fi
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
# The whitelist check, as a function, because TWO things run it: the shipped source (section 0) and a
# mutant that added a write target (m0). Returns the number of targets that are neither the parameter nor
# inside $TMP -- and prints the distinct targets on stdout so the caller can assert on their names.
offenders() { # $1 = a source file
  local s="$W/.nocomments.sh"
  sed 's/#.*//' "$1" > "$s"
  # Quoted AND unquoted targets: the shipped script happens to quote all of its, and the first version of
  # this grep only saw quoted ones -- so the m0 mutant, written with an unquoted path, was invisible and the
  # check reported 0 offenders on a mutant that had just added a fifth write target. `>&n` is an fd
  # duplication and has no path. The unquoted form is restricted to targets that LOOK like paths (`/` or
  # `$`), because without that the `->` arrows in the script's own prose (`-> COST-MEASURED:`,
  # `>=` in the awk) were read as writes and section 0 reported six offenders in a script that has none.
  # `/dev/null` and `/dev/stderr` are sinks -- the error channel of a write and of a pipeline -- rather
  # than places any state is written, which is the only thing this whitelist is about.
  grep -oE '>[ ]*("[^"]+"|[/$][^"[:space:]&|;)]*)' "$s" \
    | sed -e 's/^>[ ]*//' -e 's/^"//' -e 's/"$//' | sort -u > "$W/.targets"
  local n=0 t
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    case "$t" in '$PARAM'|'$TMP'/*|/dev/null|/dev/stderr) : ;; *) n=$((n + 1)) ;; esac
  done < "$W/.targets"
  printf '%s' "$n"
}

echo "zl1 ladder temperature A/B -- offline self-test"
echo "  script under test: $SRC"
echo "  fake device:       $FR"
echo

# ==================================================================================================
echo "== 0. what this script can write: every redirect target, out of the SHIPPED source =="
# ==================================================================================================
# A read-only probe can be guarded with "no redirect into /sys"; this one legitimately has one, so the
# check is a WHITELIST: every `> target` in the shipped source, comments stripped (a comment citing a path
# is not a write), must be the parameter or a file inside the script's own mktemp directory.
N_BAD=$(offenders "$SRC")
TARGETS=$(cat "$W/.targets")
[ -n "$TARGETS" ] || { echo "no redirect target found in $SRC -- the whitelist has nothing to check" >&2; exit 2; }
[ "$N_BAD" = 0 ] && ok "every redirect target is the parameter or a file in the script's own mktemp dir" \
                 || bad "$N_BAD redirect target(s) point somewhere else entirely: $(cat "$W/.targets")"
want '^\$PARAM$' "$TARGETS" "and the parameter IS one of them (so the whitelist is not empty of the point)"
want '^\$TMP/win\.' "$TARGETS" "and the instrument's output lands in \$TMP, not in a fixed path"

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

# ==================================================================================================
echo
echo "== 2. the refusals: each one on its own, nothing written, and the right one named =="
# ==================================================================================================
# A. the panic -> EDL escalation, in TWO shapes: a knob that READS 1, and NO knob at all -- because the
# instrument treats them the same and they mean different things on the device. "Cannot be checked" is
# not "satisfied": that sentence is the whole reason the missing case has its own scenario.
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
[ "$(fp_now)" = N ] && ok "the parameter still reads N" || bad "the parameter is now $(fp_now)"

scen refused-c
fp_rm
H0=$(tree_hash)
run --yes --thermal "$STUB/zl1-thermal.sh"
H1=$(tree_hash)
[ "$RC" = 3 ] && ok "no parameter at all: exit 3" || bad "no parameter exited $RC, expected 3"
want 'REFUSED \(C\)' "$OUT" "and it names C"
wantsq 'no [^ ]*/sys/module/\*/parameters/sleep_disabled' "$OUT" "and says the parameter is not there"
[ "$H0" = "$H1" ] && ok "and it wrote nothing" || bad "a missing parameter still wrote something"
fp_set N

scen refused-c-ro
chmod 0444 "$FP"
run --yes --thermal "$STUB/zl1-thermal.sh"
chmod 0644 "$FP"
[ "$RC" = 3 ] && ok "a parameter that is not writable: exit 3" || bad "read-only parameter exited $RC, expected 3"
want 'not writable' "$OUT" "and it says the file is not writable, before any write"

scen refused-d
fp_set Y
H0=$(tree_hash)
run --yes --thermal "$STUB/zl1-thermal.sh"
H1=$(tree_hash)
[ "$RC" = 3 ] && ok "the ladder already blocked: exit 3" || bad "ladder-blocked exited $RC, expected 3"
want 'REFUSED \(D\)' "$OUT" "and it names D"
wantsq 'window A would not be the state the fix installs' "$OUT" "and says WHY window A would be the wrong state"
want 'reboot' "$OUT" "and names the boot-time unit as the other remedy"
[ "$H0" = "$H1" ] && ok "and it wrote nothing" || bad "refusal D wrote to the device"
fp_set N

# The same-value proof is the last thing before a run. It is NOT the alphabet check (it passes on any
# file); what it buys is discovering a file that cannot be written BEFORE the value is changed. It cannot
# be exercised by a real write failure here -- this harness runs unprivileged, so `-w` and the write agree
# on every fixture that can be built -- so it is pinned as two asserts on the SHIPPED source, comments
# stripped: the proof exists, and it comes BEFORE the one write whose value changes.
# Two traps in this one assertion, both measured. (1) `want` matches its SECOND argument as TEXT, so a file
# path has to be `cat`ed -- passing the name compared the pattern with a path string. (2) These patterns are
# EREs, and in GNU grep a BARE `$` in the middle of a pattern does not match a literal `$`: the pattern
# `printf '%s' "$P"` does NOT match the text `printf '%s' "$P"`. Written in single quotes as `\$`, it does.
want 'printf .%s. "\$P_PROOF_BEFORE" > "\$PARAM"' "$(cat "$W/.nocomments.sh")" \
  "the same-value write proof is in the shipped source"
awk '/P_PROOF_BEFORE=\$\(rd/{p=NR} /printf .1. > "\$PARAM"/{i=NR} END{ exit !(p && i && p < i) }' "$W/.nocomments.sh" \
  && ok "and it comes BEFORE the write that changes the value" \
  || bad "the proof is not before the changing write in the shipped source"

# ==================================================================================================
echo
echo "== 3. the happy path: three proved states, a delta table, and the device back where it started =="
# ==================================================================================================
scen happy
FP_DIFF=5.0
H0=$(tree_hash)
run --yes --seconds 1 --settle 0 --thermal "$STUB/zl1-thermal.sh"
H1=$(tree_hash)
[ "$RC" = 0 ] && ok "the run exits 0" || bad "the run exited $RC"
want 'wrote 1 and read .Y. back' "$OUT" "the intervention is proved in the device's OWN alphabet (Y, not 1)"
want 'wrote 0 and read .N. back' "$OUT" "and so is the undo (N, not 0)"
want 'final state.*reads .N.' "$OUT" "and the final state is checked once more, on its own line"
want 'COST-MEASURED' "$OUT" "the verdict is cost-measured"
want 'largest warming from A to B on any tsens zone: 5\.0 C' "$OUT" "and the number is the one the fixture put there"
want 'from A to C \(the control, same state as A\):   0\.0 C' "$OUT" "and the control window came back to where it started"
want '^   thermal_zone1 tsens_tz_sensor1 +42\.5 +47\.5 +42\.5 +\+5\.0 +\+0\.0' "$OUT" \
  "the per-zone table carries A, B, C and both deltas"
want '^   thermal_zone0 bms ' "$OUT" "and a zone the ladder did not move is still in the table"
want 'panic guard: disarmed \(1 parameter\(s\) read 0\)' "$OUT" \
  "a DISARMED panic guard is reported in the header, so the gate is not silent when it passes"
want 'A\. panic guard: all 1 download_mode parameter\(s\) read 0' "$OUT" \
  "and the refusal section says which parameter was checked and what it read"
want 'threshold this experiment calls a cost: 0\.2 C' "$OUT" "and the threshold is printed, so the verdict can be argued with"
want 'ambient is not controlled' "$OUT" "and the caveat is printed with the verdict, not left to the reader"
[ "$(fp_now)" = N ] && ok "the parameter is back to N (a render of the stored 0, $(fp_raw))" \
                    || bad "the parameter is now $(fp_now) (stored '$(fp_raw)')"
[ "$H0" = "$H1" ] && ok "and the whole fake device is byte-for-byte as it was before the run" || bad "the run left the tree changed"
[ "$(cat "$W/win.count" 2>/dev/null)" = 3 ] && ok "exactly three windows were taken" || bad "the instrument ran $(cat "$W/win.count" 2>/dev/null) time(s), not 3"

# ==================================================================================================
echo
echo "== 4. the verdict can come out AGAINST the fix, and can be called off by its own control =="
# ==================================================================================================
scen nocost
FP_DIFF=0.1
run --yes --seconds 1 --settle 0 --thermal "$STUB/zl1-thermal.sh"
[ "$RC" = 0 ] && ok "a ladder worth less than the resolution: exit 0" || bad "it exited $RC"
want 'NO DETECTABLE COST' "$OUT" "and the verdict is no-detectable-cost -- the script coming out against itself"
want 'coming out AGAINST the fix it was built around' "$OUT" "said out loud, so the verdict is not read as a failure"

scen drift
# The phone warms 1.0 C per window with NOTHING changed, and the ladder is worth 1.5 C. A two-window A/B
# would report 2.5 C as the ladder's price; the control window is the only thing that can tell.
FP_DIFF=1.5
FP_DRIFT=1.0
run --yes --seconds 1 --settle 0 --thermal "$STUB/zl1-thermal.sh"
[ "$RC" = 1 ] && ok "a drifting phone: exit 1 (a statement about the run)" || bad "the drift scenario exited $RC, expected 1"
want 'CONTAMINATED' "$OUT" "and the verdict is contaminated"
want 'the SAME state as A -- is still 2\.0 C' "$OUT" "with the control window's own number beside it"
want 'was not caused by it' "$OUT" "and it says the warming was not caused by the ladder"

scen otherzone
# pm8994 (the power rails) runs 10 C hotter with the ladder blocked while the tsens zones move 5 C. The
# verdict is about the SoC's OWN sensors; a rail that follows the charger is not one of them.
FP_DIFF=5.0
FP_OTHER_DIFF=10.0
run --yes --seconds 1 --settle 0 --thermal "$STUB/zl1-thermal.sh"
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
run --yes --seconds 1 --settle 0 --thermal "$W/quiet-instrument.sh"
[ "$RC" = 1 ] && ok "an instrument that prints no zones: exit 1" || bad "the empty-instrument run exited $RC, expected 1"
want 'NO ZONE WAS READABLE IN ALL THREE WINDOWS' "$OUT" "and it says there is no table rather than printing a delta of zeros"
notwant 'COST-MEASURED|NO DETECTABLE COST' "$OUT" "and it prints no verdict at all"
[ "$(fp_now)" = N ] && ok "and the parameter was still put back" || bad "the parameter is now $(fp_now)"

# ==================================================================================================
echo
echo "== 6. the trap: what is left on a path nobody wrote by hand =="
# ==================================================================================================
scen interrupt
FP_DIFF=5.0
runbg "$S/interrupt.txt" "$RW" --yes --seconds 1 --settle 3 --thermal "$STUB/zl1-thermal.sh"
kill_blocked
[ "$(fp_raw)" = 1 ] && ok "the kill landed in the blocked window (the parameter really holds 1)" \
                    || bad "the kill did not land in the blocked window -- nothing about the trap is being tested"
wait "$BG_PID"; BG_RC=$?
OUT=$(cat "$S/interrupt.txt" 2>/dev/null)
[ "$BG_RC" != 0 ] && ok "an interrupted run comes back non-zero (rc=$BG_RC)" \
                  || bad "the interrupted run exited 0 -- a signal that does not end the run"
notwant 'the state it started in' "$OUT" \
  "and it did not reach its closing line, so nothing overwrote the restore on the way out"
[ "$(fp_now)" = N ] && ok "and the parameter is back at N -- the trap, not the happy path, restored it" \
                    || bad "the interrupt left the parameter at $(fp_now) (stored '$(fp_raw)')"
want '\[trap\]' "$OUT" "and the trap says so out loud, on the way out"
want 'verified by read-back' "$OUT" "with its own read-back rather than a promise"

# ==================================================================================================
echo
echo "== 7. the mutations: each one must change what the checks above observe =="
# ==================================================================================================
# (m0) a fifth redirect target: the whitelist in section 0 is the only thing that can see it.
if mut m0-addwrite 's#^set -u$#set -u\nprintf x > /tmp/zl1-ladder-temp-ab-evil.txt#'; then
  N2=$(offenders "$W/mut-m0-addwrite.sh")
  [ "$N2" = 1 ] && ok "mutation 'a fifth write target': the whitelist sees it (the check in section 0 is live)" \
                || bad "the mutant's extra redirect was not seen ($N2 offenders)"
  want 'zl1-ladder-temp-ab-evil' "$(cat "$W/.targets")" "and the offending path is named, not just counted"
fi
# (m1) the control window ignored: the drift scenario's warming is reported as the ladder's price.
if mut m1-nocontrol 's#if (ca >= ba / 2)                 { print "contaminated"; exit }#if (0)                              { print "contaminated"; exit }#'; then
  scen mut-m1
  FP_DIFF=1.5; FP_DRIFT=1.0
  mutrun m1-nocontrol --yes --seconds 1 --settle 0 --thermal "$STUB/zl1-thermal.sh"
  [ "$RC" = 0 ] && ok "mutation 'control ignored': the drifting phone now reads as a result (the check is live)" \
                || bad "the 'control ignored' mutant exited $RC"
  want 'COST-MEASURED' "$OUT" "and it prints the drift as if the ladder had done it"
  notwant 'CONTAMINATED' "$OUT" "with nothing anywhere saying the third window disagreed"
fi
# (m2) the resolution removed: something this experiment cannot resolve is reported as a cost.
if mut m2-threshold 's#if (ba < 0.2)                     { print "no-detectable-cost"; exit }#if (0)                              { print "no-detectable-cost"; exit }#'; then
  scen mut-m2
  FP_DIFF=0.1
  mutrun m2-threshold --yes --seconds 1 --settle 0 --thermal "$STUB/zl1-thermal.sh"
  want 'COST-MEASURED' "$OUT" "mutation 'no threshold': 0.1 C -- one step of the instrument -- is reported as a cost"
fi
# (m3) the intervention compared as a STRING: the docs-163 defect at this script's most load-bearing
# check. The write succeeds and the device renders it `Y`, so a string comparison reports a successful
# write as one that never landed -- and the run stops with rc=4.
if mut m3-alphabet 's#if is_on "\$P_B"; then#if [ "\$P_B" = 1 ]; then#'; then
  scen mut-m3
  FP_DIFF=5.0
  mutrun m3-alphabet --yes --seconds 1 --settle 0 --thermal "$STUB/zl1-thermal.sh"
  [ "$RC" = 4 ] && ok "mutation 'string comparison': a write that HELD is reported as one that did not (rc=4)" \
                || bad "the alphabet mutant exited $RC, expected 4"
  want 'THE INTERVENTION DID NOT LAND' "$OUT" "and the message is the one that would hide a real experiment"
  [ "$(fp_now)" = N ] && ok "and the trap still put the parameter back, so even this mutant leaves no state" \
                      || bad "the alphabet mutant left the parameter at $(fp_now)"
fi
# (m4) the trap disarmed: the restore is a no-op, so an interrupted run leaves the ladder blocked with
# nothing holding the fix's value. This is what makes section 6's check mean something.
if mut m4-notrap 's#^  printf .0. > "\$PARAM" 2>/dev/null$#  : #'; then
  scen mut-m4
  FP_DIFF=5.0
  runbg "$S/trap.txt" "$W/mut-m4-notrap.rw.sh" --yes --seconds 1 --settle 3 --thermal "$STUB/zl1-thermal.sh"
  kill_blocked
  wait "$BG_PID" 2>/dev/null
  [ "$(fp_now)" = Y ] && ok "mutation 'trap disarmed': the interrupt leaves the ladder BLOCKED (the trap is the restorer)" \
                      || bad "the 'trap disarmed' mutant left the parameter at $(fp_now) (stored '$(fp_raw)')"
fi
# (m5) the restore's read-back compared as a string: the same defect one function over.
if mut m5-restorealphabet 's#^  if is_off "\$P_RESTORE"; then$#  if [ "$P_RESTORE" = 0 ]; then#'; then
  # Through the INTERRUPT, deliberately: on the happy path the run verifies its own undo and clears
  # `WROTE`, so the trap returns early and this mutant's wrong comparison is never reached -- a mutant that
  # leaves no trace is not a mutant of the trap.
  scen mut-m5
  FP_DIFF=5.0
  runbg "$S/m5.txt" "$W/mut-m5-restorealphabet.rw.sh" --yes --seconds 1 --settle 3 --thermal "$STUB/zl1-thermal.sh"
  kill_blocked
  wait "$BG_PID" 2>/dev/null
  OUT=$(cat "$S/m5.txt" 2>/dev/null)
  want 'THE RESTORE DID NOT HOLD' "$OUT" \
    "mutation 'restore alphabet': a restore that HELD (the file reads N) is reported as a failure"
  [ "$(fp_now)" = N ] && ok "and the parameter was in fact restored -- only the message was wrong" \
                      || bad "the restore did not happen at all"
fi
# (m7) the panic gate removed: every other scenario has the knob reading 0, so a comparison that can
# never flag anything is invisible from the passing side -- and the device this experiment would then run
# on is one where a mistake costs a 10-20 s power hold instead of a reboot. The mutant must therefore be
# driven by the scenario that HAS something to flag (dl_set 1) and must be seen to stop refusing.
if mut m7-nopanic 's@^  \[ "\$zl1_v" = 0 \] || DL_BAD=@  : || DL_BAD=@'; then
  scen mut-m7
  dl_set 1
  FP_DIFF=5.0
  mutrun m7-nopanic --yes --seconds 1 --settle 0 --thermal "$STUB/zl1-thermal.sh"
  notwant 'REFUSED \(A\)' "$OUT" "mutation 'no panic gate': an armed panic guard no longer refuses (the gate is live)"
  want 'COST-MEASURED|NO DETECTABLE COST|CONTAMINATED' "$OUT" \
    "and the run proceeds -- which is the whole cost of the mutant, on a device where it must not"
  dl_set 0
fi

# (m6) the empty-table guard removed: no reading at all becomes a verdict of zeros.
if mut m6-notable 's#^if \[ ! -s "\$TMP/deltas" \]; then$#if false; then#;s#^if \[ -z "\$TSENS" \]; then$#if false; then#'; then
  scen mut-m6
  mutrun m6-notable --yes --seconds 1 --settle 0 --thermal "$W/quiet-instrument.sh"
  want 'COST-MEASURED|NO DETECTABLE COST' "$OUT" \
    "mutation 'no table guard': an instrument that printed nothing still produces a verdict"
  want 'NO DETECTABLE COST' "$OUT" \
    "and with no zones at all the number it prices is an empty string, read as 0 -- the guards are what stop it"
fi

# ==================================================================================================
echo
echo "== 8. this harness did not edit the tree it tests =="
# ==================================================================================================
SRC_SHA_AFTER=$(sha256sum "$SRC" | awk '{print $1}')
[ "$SRC_SHA_BEFORE" = "$SRC_SHA_AFTER" ] \
  && ok "$(basename "$SRC") is byte-identical to what it was before this run" \
  || bad "$(basename "$SRC") CHANGED during this run -- a fixture is writing into the repository"
[ ! -e /tmp/zl1-ladder-temp-ab-evil.txt ] \
  && ok "and the mutant's extra write target does not exist -- m0 is INSPECTED, never run" \
  || bad "something wrote the mutant's target, so the whitelist check is not the only thing watching"

# ==================================================================================================
echo
echo "== 9. the citation in the health check is checked by the thing it cites =="
# ==================================================================================================
HEALTH="$HERE/zl1-health-check.sh"
if [ -r "$HEALTH" ]; then
  cited=$(sed -e 's/always "/ /g' -e 's/"$//' "$HEALTH" | tr '\n' ' ' |
            sed -n 's/.*zl1-ladder-temp-ab-selftest\.sh[ ,(]*\([0-9][0-9]*\) checks.*/\1/p')
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
