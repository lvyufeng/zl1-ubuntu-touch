#!/usr/bin/env bash
# zl1 LPM ladder trial -- offline self-test. Host-side, touches no device, needs no phone.
#
# Why this exists. `scripts/device/zl1-lpm-ladder-trial.sh` is the first script in this repository that
# WRITES to a file the device cares about in order to MEASURE something. Every other instrument here is
# read-only and its harness ends at "not one byte changed"; that guarantee is not available for this one,
# so the guarantee has to be a different one and it has to be stated exactly:
#
#   THE SET OF FILES THIS SCRIPT CAN WRITE IS A CLOSED, NAMED SET -- and every path that leaves the
#   parameter changed is a path the caller asked for.
#
# Concretely, and in the order the scenarios below check it:
#
#   1. A WHITELIST, NOT A BLACKLIST. A read-only probe can be guarded by "no redirect into /sys", but
#      this one legitimately has one, so the check is that the redirect targets in the shipped source
#      are EXACTLY the four known paths (the parameter, the /tmp undo file, and the two counter
#      snapshots) -- and that a fifth one added by a mutation makes the harness fail. Section 0.
#   2. --status WRITES NOTHING, byte-for-byte (structure + sizes + md5). Section 1.
#   3. A REFUSAL WRITES NOTHING, byte-for-byte, EVEN WITH --apply. That is the whole promise of the
#      three prerequisites: the check is not that the script says "refused" but that the device is
#      identical afterwards. Each prerequisite is refused on its own, one at a time. Sections 3-6.
#   4. THE HAPPY PATH ENDS WHERE IT STARTED. After --apply the parameter reads 1 again, and the only
#      trace left in the fake device is the undo file the script wrote on purpose. Section 7.
#   5. THE TRAP IS THE THING THAT UNDOES IT. A run made to fail AFTER the write (the after-snapshot's
#      directory pre-created as a file) must leave the parameter at 1 and exit 4 -- so the undo is not
#      the happy path's last line, it is a trap that fires on a path nobody wrote by hand. Section 9.
#   6. --keep IS THE ONLY WAY TO LEAVE IT CHANGED, and it says so. Section 10.
#
# And the verdict is checked for being able to COME OUT AGAINST the hypothesis it was built to test --
# REFUTED is a scenario, not a paragraph. Section 11.
#
# How it works: **the stub directory IS the device**, the same construction as this family's other
# harnesses -- the probe runs as itself with a fake root and the tools it calls stubbed, and PATH for the
# child is `$STUB:$MINBIN` with MINBIN a sandbox of symlinks to the real coreutils. One stub here is
# load-bearing rather than convenient: `sleep` is what MOVES THE COUNTERS. The trial's whole measurement
# is a before/after across a settle window, so a stub that returns instantly with the counters unchanged
# would make every delta zero and every scenario would be testing the absence of the thing it set up.
# The stub advances the counters according to FAKE_IDLE instead.
#
# Usage: zl1-lpm-ladder-trial-selftest.sh [--keep]
#   --keep   leave the fake device, the stubs and the rewritten script for inspection
#
# Exit codes: 0 every scenario behaved; 1 something did not; 2 the harness could not set up.

set -uo pipefail

KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
  --keep) KEEP=1; shift ;;
  --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../device/zl1-lpm-ladder-trial.sh"
[ -r "$SRC" ] || { echo "cannot read $SRC" >&2; exit 2; }

W="${TMPDIR:-/tmp}/zl1-lpm-ladder-trial-selftest"
# `root`, not `dev`: the fake root's own path must not contain a path the rewriter hunts for.
FR="$W/root"
STUB="$W/stub"
MINBIN="$W/minbin"
ACT="$W/actions"
rm -rf "$W"
mkdir -p "$STUB" "$MINBIN" || exit 2

# --- the sandbox PATH ------------------------------------------------------------------------------
for t in awk basename cat cut head ls sed sort tail tr uniq wc grep chmod printf mkdir rm; do
  p="$(type -P "$t" 2>/dev/null)" || continue
  [ -n "$p" ] && ln -sf "$p" "$MINBIN/$t"
done
for t in awk grep ls sed tail tr wc; do
  [ -x "$MINBIN/$t" ] || { echo "the sandbox bin is missing $t -- the harness cannot run the trial honestly" >&2; exit 2; }
done
SH_BIN="$(type -P sh 2>/dev/null)"; [ -n "$SH_BIN" ] || SH_BIN=/bin/sh
[ -x "$SH_BIN" ] || { echo "no /bin/sh to run the trial with" >&2; exit 2; }

# --- the script under test, rewritten into the fake device -----------------------------------------
# TWO PASSES through tokens, for the reason its siblings record: a one-pass rewrite is a cascade, and a
# cascaded path is a script reading something that cannot exist while every scenario still passes.
P1="$W/pass1.sh"
sed -e 's#/proc/device-tree#__ZDT__#g' \
    -e 's#/proc/\[0-9\]\*#__ZGLOB__#g' \
    -e 's|\${d#/proc/}|\${d#__ZPROC__}|g' \
    -e 's#/sys/devices/system/cpu#__ZCPU__#g' \
    -e 's#/sys/module#__ZMOD__#g' \
    -e 's#/proc/#__ZPROC__#g' \
    -e 's#/tmp/zl1-lpm-trial#__ZTMP__#g' "$SRC" > "$P1"

RW="$W/lpm-ladder-trial.sh"
sed -e "s#__ZDT__#$FR/proc/device-tree#g" \
    -e "s#__ZGLOB__#$FR/proc/[0-9]*#g" \
    -e "s#__ZPROC__#$FR/proc/#g" \
    -e "s#__ZCPU__#$FR/sys/devices/system/cpu#g" \
    -e "s#__ZMOD__#$FR/sys/module#g" \
    -e "s#__ZTMP__#$FR/tmp/zl1-lpm-trial#g" "$P1" > "$RW"
sh -n "$RW" || { echo "the rewritten trial does not parse" >&2; exit 2; }
if grep -q -- '__Z' "$RW"; then
  echo "an unexpanded token is left in $RW:" >&2
  grep -n -- '__Z' "$RW" | head -5 >&2
  exit 2
fi

# The landing count, as the invariant its siblings use: every token in pass 1 must become exactly one
# fake-root path in pass 2. No per-path tally, because that cannot balance when one path is nested
# inside another (`/proc/device-tree` inside `/proc/`).
cnt() { grep -o -- "$1" "$2" 2>/dev/null | wc -l | tr -d ' '; }
TOK=$(cnt '__Z[A-Z0-9]*__' "$P1")
FRS=$(cnt "$FR" "$RW")
[ "$TOK" -gt 0 ] || { echo "pass 1 produced no tokens -- the rewrite matched nothing" >&2; exit 2; }
[ "$TOK" = "$FRS" ] || { echo "$TOK tokens in pass 1 became $FRS fake-root paths in pass 2" >&2; exit 2; }
for pair in "__ZDT__:$FR/proc/device-tree" "__ZCPU__:$FR/sys/devices/system/cpu" \
            "__ZMOD__:$FR/sys/module" "__ZTMP__:$FR/tmp/zl1-lpm-trial"; do
  tok="${pair%%:*}"; path="${pair#*:}"
  [ "$(cnt "$tok" "$P1")" -gt 0 ] || { echo "$tok never appears in pass 1 -- that path is not in the trial" >&2; exit 2; }
  [ "$(cnt "$tok" "$P1")" = "$(cnt "$path" "$RW")" ] \
    || { echo "$tok did not expand to $path exactly as many times as it appears" >&2; exit 2; }
done
grep -qF "$FR$FR" "$RW" && { echo "a rewrite cascaded: $FR appears twice in a row" >&2; exit 2; }
grep -qF "$FR/proc/$FR" "$RW" && { echo "a rewrite cascaded into the fake root's own proc/" >&2; exit 2; }
grep -qF "CPU_GLOB=$FR/sys/devices/system/cpu/cpu[0-9]*" "$RW" \
  || { echo "the cpu glob was not rewritten -- the trial would read THIS host's cpus" >&2; exit 2; }
grep -qF "REVERT_SH=$FR/tmp/zl1-lpm-trial-revert.sh" "$RW" \
  || { echo "the undo file's path was not rewritten -- the undo would land outside the fake device" >&2; exit 2; }
# The parameter path is DISCOVERED, not written: the trial must not assume the driver's module name, so
# the check is that the discovery survived the rewrite and not that a literal path is present.
grep -qF "for p in $FR/sys/module/*/parameters/\"\$1\"; do" "$RW" \
  || { echo "the parameter discovery was not rewritten -- section 2 would look at THIS host's modules" >&2; exit 2; }

# --- the checks ------------------------------------------------------------------------------------
PASS=0
FAIL=0
SKIPPED=0
ok() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
want() { if printf '%s\n' "$2" | grep -Eq -- "$1"; then ok "$3"; else bad "$3"; printf '%s\n' "$2" | grep -n . | sed 's/^/        | /'; fi; }
notwant() { if printf '%s\n' "$2" | grep -Eq -- "$1"; then bad "$3"; printf '%s\n' "$2" | grep -E -- "$1" | sed 's/^/        | /'; else ok "$3"; fi; }
# The verdict is the LAST section of the trial, so it is extracted from its own header. Anchored on the
# numbered header and not on the first `->` line anywhere: this script prints `->` in earlier sections.
verdict() { printf '%s\n' "$1" | sed -n '/^== 10\. the verdict$/,$p'; }
# Everything the fake device holds, so "wrote nothing" is checkable rather than asserted from a log.
snap() { ( cd "$1" 2>/dev/null && find . -printf '%y %p %s\n' | sort && find . -type f -exec md5sum {} + 2>/dev/null | sort ); }
param() { cat "$FR/sys/module/lpm_levels/parameters/sleep_disabled" 2>/dev/null | tr -d '\n'; }

# ==================================================================================================
# 0. THE WHITELIST: the set of files this script can write is exactly the one it declares
# ==================================================================================================
# A read-only probe is guarded by "no redirect into /sys" (its siblings' rule). This script HAS a
# legitimate redirect, so the blacklist would have to be weakened -- and a weakened blacklist is what a
# later edit walks through. The rule here is therefore a WHITELIST over every redirect target in the
# shipped source, and it is checked in both directions: the set must be non-empty, and it must contain
# nothing that was not declared.
#
# (`>>` counts: an append is a write. `2>` is a redirect only when its target is a path, which is why
# `/dev/null` has to be permitted by name.)
#
# TWO THINGS THIS CANNOT DO, stated here rather than discovered later: a redirect target that is a
# VARIABLE is opaque to any regex, and `->` contains a `>` so an arrow has to be removed before the
# extraction -- the same exclusion its siblings' guards carry, for the same reason. Both are handled
# rather than assumed: the arrows are deleted first (an arrow is never a redirect, so deleting it IS the
# exclusion), the FIRST redirect on each line is taken (`.*>` is greedy and would report the target of a
# later arrow), quotes and `$` prefixes are stripped, and the closure over variables comes from the
# declared set plus the assignment checks below -- not from pretending the regex proved it.
# Comment lines are not code: the trial's own header spells the fix out
# (`printf 0 > /sys/module/lpm_levels/parameters/sleep_disabled`), and an extractor that counted that as a
# write would report a target the script cannot reach -- and the whitelist would then be maintained
# against the comments rather than against the code. `>&2` is fd duplication, not a file. And a target can
# be followed by shell punctuation, which is not part of the path.
writes_in() { grep -vE '^[[:space:]]*#' "$1" 2>/dev/null | sed 's/->//g' | grep -nE '>>?[[:space:]]*[^[:space:]]+'; }
targets_in() {
  grep -vE '^[[:space:]]*#' "$1" 2>/dev/null \
    | sed 's/->//g' \
    | sed -n 's/^[^>]*>\+[[:space:]]*\([^[:space:]]*\).*/\1/p' \
    | sed 's/["'"'"']//g; s/[;)]*$//' \
    | grep -v '^$' | grep -v '^&' | sort -u
}
# The declared set, and each entry is checked twice: that it is written, and -- separately -- that the
# variable it names is assigned from a literal path. `$1/counters` is the snapshot helper's parameter;
# the helper is only legitimate because its call sites are asserted below, which is what closes it.
DECLARED='$PARAM
$REVERT_SH
$SNAP_BEFORE
$SNAP_AFTER
$DELTAS
$1/counters'
SHIPPED_TARGETS="$(targets_in "$SRC")"
if [ -z "$SHIPPED_TARGETS" ]; then
  bad "the shipped trial contains no redirect at all -- then it cannot be the script under test, and the"
  bad "whitelist below would be vacuous"
else
  ok "the shipped trial's redirect targets were extracted ($(printf '%s\n' "$SHIPPED_TARGETS" | wc -l | tr -d ' ') of them)"
  UNDECLARED=
  while IFS= read -r t; do
    [ -z "$t" ] && continue
    case "$t" in
    /dev/null) : ;;
    *)
      printf '%s\n' "$DECLARED" | grep -qxF -- "$t" || UNDECLARED="$UNDECLARED $t" ;;
    esac
  done <<EOF
$SHIPPED_TARGETS
EOF
  if [ -z "$UNDECLARED" ]; then
    ok "every redirect target is one of the declared paths ($(printf '%s\n' "$DECLARED" | wc -l | tr -d ' ') of them, plus /dev/null)"
  else
    bad "the trial writes to something outside its declared set:$UNDECLARED"
  fi
  # And that each declared path really is used: a whitelist nothing uses is a whitelist that would not
  # notice one of them being dropped. The two snapshots are used by being PASSED -- the helper is what
  # redirects into them -- so they are checked as arguments and not as targets, and that difference is
  # the point of the `$1/counters` entry above.
  while IFS= read -r t; do
    case "$t" in
    '$SNAP_BEFORE'|'$SNAP_AFTER')
      grep -qF "snap_counters \"$t\"" "$SRC" \
        && ok "the trial does use $t (as the snapshot helper's argument)" \
        || bad "the declared path $t is never used -- the whitelist does not describe this script" ;;
    *)
      printf '%s\n' "$SHIPPED_TARGETS" | grep -qxF -- "$t" \
        && ok "the trial does write $t" \
        || bad "the declared path $t is never written -- the whitelist does not describe this script" ;;
    esac
  done <<EOF
$DECLARED
EOF
fi
# The parameterised one is closed by its CALL SITES, which is the only honest way to close it: the
# helper writes into whatever directory it is given, so what has to be true is that the only directories
# ever given to it are the two snapshot paths -- plus the `-` form, which is the one that writes NOTHING
# and is what keeps --status a read-only mode.
SITES="$(grep -oE 'snap_counters [^ )]*' "$SRC" | grep -v '^snap_counters$' | sort -u)"
EXPECTED='snap_counters -
snap_counters "$SNAP_AFTER"
snap_counters "$SNAP_BEFORE"'
if [ "$SITES" = "$EXPECTED" ]; then
  ok "the snapshot helper's call sites are EXACTLY the two snapshots and the write-nothing form"
else
  bad "the snapshot helper is called from somewhere unexpected (the \$1/counters redirect is only closed"
  bad "for the two snapshot paths and the '-' form):"
  printf '%s\n' "$SITES" | sed 's/^/        | /'
fi
want 'snap_counters -' "$SITES" "including '-', the form that writes nothing and keeps --status read-only"
want 'SNAP_BEFORE=/tmp/zl1-lpm-trial-before' "$(grep -nE '^[[:space:]]*SNAP_BEFORE=' "$SRC")" "SNAP_BEFORE is a literal path"
want 'SNAP_AFTER=/tmp/zl1-lpm-trial-after' "$(grep -nE '^[[:space:]]*SNAP_AFTER=' "$SRC")" "SNAP_AFTER is a literal path"
want 'DELTAS=/tmp/zl1-lpm-trial-deltas' "$(grep -nE '^[[:space:]]*DELTAS=' "$SRC")" "DELTAS is a literal path"
want 'REVERT_SH=/tmp/zl1-lpm-trial-revert.sh' "$(grep -nE '^[[:space:]]*REVERT_SH=' "$SRC")" "the undo file is a literal path"
notwant 'counters.*/tmp/|/tmp/[a-z-]*counters' "$SHIPPED_TARGETS" "and no snapshot path is written outside the declared set"
# The tooth: a fifth target added by a mutation must break the whitelist. This is the write a later edit
# would most plausibly add, because the trial already knows how to write sysfs and this file is one line
# away from the counter it reads.
sed 's#^printf .%s. "$P_BEFORE" > "$PARAM" 2>/dev/null$#printf "disabled" > /sys/class/thermal/thermal_zone0/mode; printf "%s" "$P_BEFORE" > "$PARAM" 2>/dev/null#' "$SRC" > "$W/mut-extra.sh"
if cmp -s "$SRC" "$W/mut-extra.sh"; then
  bad "the extra-target mutation did not land (its sed matches no line), so the whitelist is not proven"
else
  ok "the extra-target mutation really differs from the shipped file"
  EXTRA="$(targets_in "$W/mut-extra.sh" | grep -vxF -e '/dev/null' -e '\$PARAM' -e '\$REVERT_SH' -e '\$SNAP_BEFORE' -e '\$SNAP_AFTER' -e '\$DELTAS' -e '\$1/counters' || true)"
  if printf '%s\n' "$EXTRA" | grep -q 'thermal_zone0/mode'; then
    ok "the whitelist CATCHES a fifth write target (a thermal zone's mode)"
  else
    bad "the whitelist let a fifth write target through -- a mutation adding one must fail this check"
  fi
fi
# The other direction: prose that is not a redirect must not be extracted as one. The trial's own output
# carries an arrow before a path in several places, and a whitelist that fired on those would be deleted
# by whoever hits it first.
printf 'say "   printf 0 would be the fix   -> %s          (the value)"\n' '$PARAM' > "$W/mut-prose.sh"
if [ -z "$(targets_in "$W/mut-prose.sh")" ]; then
  ok "an arrow in prose is not extracted as a redirect target"
else
  bad "prose was extracted as a redirect target: $(targets_in "$W/mut-prose.sh")"
fi
# And the same rule in the direction that matters for a guard: a REAL redirect is still extracted.
printf 'printf 0 > /sys/module/lpm_levels/parameters/sleep_disabled\n' > "$W/mut-real.sh"
printf 'x >> "$SNAP_AFTER/counters"\n' >> "$W/mut-real.sh"
want '/sys/module/lpm_levels/parameters/sleep_disabled' "$(targets_in "$W/mut-real.sh")" "a real redirect is still extracted"
want '\$SNAP_AFTER/counters' "$(targets_in "$W/mut-real.sh")" "and an append is extracted as one too"

# ==================================================================================================
# the fake device
# ==================================================================================================
# The fixture is written ONCE with every switch in it, so a scenario changes the device and that change
# is the ONLY difference. The switches, and what each is for:
#   FAKE_DL       0 | 1 | missing            prerequisite A: the panic -> EDL escalation
#   FAKE_CPUIDLE  clean | nodir              prerequisite B
#   FAKE_KEEPER   0 | 1                      prerequisite C, plus a bystander that must NOT be matched
#   FAKE_PARAM    1 | 0 | missing            the parameter's value
#   FAKE_DEEP_BEFORE  0 | N                  whether the deep state had entries BEFORE the write
#   FAKE_DEEP_DIS 0 | 1                      the deepest state disabled by the other mechanism
#   FAKE_IDLE     deep | shallow | none      what the settle window does to the counters
#   FAKE_AFTERFAIL 0 | 1                     make the after-snapshot fail, to reach the trap
# Every switch defaults to the coherent, real-device shape: the escalation disarmed, counters readable,
# no keeper, the parameter at 1, the deep state never yet entered, the deepest state not disabled, and a
# window in which the deep state IS entered once the ladder is allowed. So a scenario that forgets a
# switch is testing the baseline and not an accident.
cat > "$W/reset.sh" <<EOF
#!/bin/sh
set -u
rm -rf "$FR"
mkdir -p "$FR/proc/device-tree" "$FR/sys/devices/system/cpu/cpuidle" "$FR/tmp" \\
         "$FR/sys/module/lpm_levels/parameters" "$FR/sys/module/msm_mpoweroff/parameters" 2>/dev/null
printf '%s\\0' "\${FAKE_COMPAT:-qcom,msm8996pro}" > "$FR/proc/device-tree/compatible"
printf 'qcom-cpuidle\\n' > "$FR/sys/devices/system/cpu/cpuidle/current_driver"
# /proc is NOT created wholesale: the keeper scenarios add their own processes, and a directory that
# exists but holds nothing is a different reading from one that is absent.
mkdir -p "$FR/proc"

# --- prerequisite A: the panic -> EDL escalation -------------------------------------------------
# The module name is deliberately NOT the one docs 86's string search suggested (msm_mpoweroff, not
# msm_poweroff): the trial discovers it by glob, and a fixture named exactly as the trial expects would
# let a hard-coded path pass every scenario.
case "\${FAKE_DL:-0}" in
missing) : ;;
*) printf '%s\\n' "\${FAKE_DL:-0}" > "$FR/sys/module/msm_mpoweroff/parameters/download_mode" ;;
esac

# --- the parameter this trial writes ------------------------------------------------------------
case "\${FAKE_PARAM:-1}" in
missing) : ;;
*) printf '%s\\n' "\${FAKE_PARAM:-1}" > "$FR/sys/module/lpm_levels/parameters/sleep_disabled" ;;
esac
printf '0\\n' > "$FR/sys/module/lpm_levels/parameters/menu_select"
printf '0\\n' > "$FR/sys/module/lpm_levels/parameters/print_parsed_dt"

# --- prerequisites B: the counters --------------------------------------------------------------
# The values are the SHAPE that matters. The deep state (state2) has NO entries before the write by
# default, because that is the state the hypothesis says cannot be entered -- and FAKE_DEEP_BEFORE puts
# entries there, which is the reading that REFUTES the hypothesis.
DFU=\${FAKE_DEEP_BEFORE:-0}
case "\${FAKE_CPUIDLE:-clean}" in
nodir) : ;;
*)
  for c in 0 1 2 3; do
    mkdir -p "$FR/sys/devices/system/cpu/cpu\$c/cpuidle"
    for s in 0 1 2; do mkdir -p "$FR/sys/devices/system/cpu/cpu\$c/cpuidle/state\$s"; done
    printf 'wfi\\n'       > "$FR/sys/devices/system/cpu/cpu\$c/cpuidle/state0/name"
    printf 'retention\\n' > "$FR/sys/devices/system/cpu/cpu\$c/cpuidle/state1/name"
    printf 'pc\\n'        > "$FR/sys/devices/system/cpu/cpu\$c/cpuidle/state2/name"
    printf '100000\\n'    > "$FR/sys/devices/system/cpu/cpu\$c/cpuidle/state0/usage"
    printf '500000\\n'    > "$FR/sys/devices/system/cpu/cpu\$c/cpuidle/state0/time"
    printf '4000\\n'      > "$FR/sys/devices/system/cpu/cpu\$c/cpuidle/state1/usage"
    printf '100000\\n'    > "$FR/sys/devices/system/cpu/cpu\$c/cpuidle/state1/time"
    printf '%s\\n' "\$DFU" > "$FR/sys/devices/system/cpu/cpu\$c/cpuidle/state2/usage"
    printf '%s\\n' "\$DFU" > "$FR/sys/devices/system/cpu/cpu\$c/cpuidle/state2/time"
    printf '0\\n'         > "$FR/sys/devices/system/cpu/cpu\$c/cpuidle/state0/disable"
    printf '0\\n'         > "$FR/sys/devices/system/cpu/cpu\$c/cpuidle/state1/disable"
    printf '%s\\n' "\${FAKE_DEEP_DIS:-0}" > "$FR/sys/devices/system/cpu/cpu\$c/cpuidle/state2/disable"
  done ;;
esac

# --- prerequisite C: the keeper, and a bystander that merely mentions its path -------------------
# The keeper is matched by ARGV -- argv[1] IS the path, or argv[0] is a shell and argv[1] the path -- so
# the bystander (a shell whose command line greps for the path) must NOT count. A scenario that stopped
# at "did it refuse" would not notice the difference; the bystander is what makes it a reading.
if [ "\${FAKE_KEEPER:-0}" = 1 ]; then
  mkdir -p "$FR/proc/900" "$FR/proc/903"
  printf '/bin/sh\\0/usr/local/sbin/zl1-debug-net.sh\\0' > "$FR/proc/900/cmdline"
  printf '/bin/sh\\0-c\\0ps -ef | grep /usr/local/sbin/zl1-debug-net.sh\\0' > "$FR/proc/903/cmdline"
  printf 'S 1 900\\n' > "$FR/proc/900/stat"
  printf 'S 1 903\\n' > "$FR/proc/903/stat"
fi
exit 0
EOF
chmod +x "$W/reset.sh"

# --- the stubs -------------------------------------------------------------------------------------
# `sleep` is the load-bearing one: it MOVES THE COUNTERS. The trial's measurement is a before/after
# across a settle window, so a stub that returned instantly with the counters unchanged would make every
# delta zero -- and then "the ladder was not entered" would pass in every scenario, including the ones
# that set up an entry. The stub advances state0 (and state1/state2 per FAKE_IDLE) on every call, which
# is exactly what a real idle window does.
cat > "$STUB/sleep" <<EOF
#!/bin/sh
# \$1 = seconds. The real wait does not happen; the EFFECT of the window does.
bump() { # \$1 = state dir, \$2 = usage delta, \$3 = time delta
  [ -d "\$1" ] || return 0
  u=\$(cat "\$1/usage" 2>/dev/null); t=\$(cat "\$1/time" 2>/dev/null)
  case "\$u\$t" in *[!0-9]*|'') return 0 ;; esac
  printf '%s\\n' "\$((u + \$2))" > "\$1/usage"
  printf '%s\\n' "\$((t + \$3))" > "\$1/time"
}
for c in 0 1 2 3; do
  d=$FR/sys/devices/system/cpu/cpu\$c/cpuidle
  [ -d "\$d" ] || continue
  case "\${FAKE_IDLE:-deep}" in
  none) : ;;
  shallow)
    bump "\$d/state0" 1000 400000 ;;
  *)
    bump "\$d/state0" 1000 400000
    bump "\$d/state1" 50 30000
    bump "\$d/state2" 5 200000 ;;
  esac
done
printf 'sleep %s\\n' "\$1" >> "$ACT"
exit 0
EOF
chmod +x "$STUB/sleep"


export FAKE_COMPAT= FAKE_DL= FAKE_CPUIDLE= FAKE_KEEPER= FAKE_PARAM= FAKE_DEEP_BEFORE= FAKE_DEEP_DIS= \
       FAKE_IDLE= FAKE_AFTERFAIL=

# For the scenarios that are about state a previous run left behind (the --keep then --revert pair),
# `run` would reset the fake device first and destroy exactly the state under test.
runraw() { # $1 = extra arguments (may be empty) -- NO reset
  : > "$ACT"
  OUT="$( env PATH="$STUB:$MINBIN" "$SH_BIN" "$RW" $1 2>&1 | tr -d '\000' )"
  RC=${PIPESTATUS[0]}
}
run() { # $1 = extra arguments (may be empty)
  : > "$ACT"
  "$W/reset.sh"
  # The interpreter by FULL PATH, and `sh`, which is how it runs on the device. `env PATH=... bash`
  # cannot work once PATH is the sandbox: env looks the program up in the NEW PATH.
  # The NULs are stripped from the captured output because the fixture writes the device-tree file the
  # way the real one is written -- NUL terminated -- and a NUL left in OUT would make grep treat the
  # capture as binary. That is a fact about the harness's string handling, not about the trial.
  OUT="$( env PATH="$STUB:$MINBIN" "$SH_BIN" "$RW" $1 2>&1 | tr -d '\000' )"
  RC=${PIPESTATUS[0]}
}

echo "zl1 LPM ladder trial -- offline self-test"
echo "  script under test: $SRC"
echo "  fake device:       $FR"
echo

# ==================================================================================================
echo
echo "== 1. --status writes NOTHING, and --explain writes nothing and reads no device file =="
# ==================================================================================================
"$W/reset.sh"                      # the device has to exist before there is a "before"
BEFORE="$(snap "$FR")"
run "--status"
[ "$RC" = 0 ] && ok "--status exits 0" || bad "--status exited $RC"
[ "$(snap "$FR")" = "$BEFORE" ] && ok "--status wrote nothing to the fake device (byte-for-byte)" || bad "--status changed the fake device"
want 'A. A panic will NOT arm EDL' "$OUT" "--status reports the escalation as disarmed"
want 'B. cpuidle: 4 cpu' "$OUT" "--status counts the cpus that expose counters"
want 'C. no v63 debug keeper is running' "$OUT" "--status reports the keeper as absent"
want 'value: 1' "$OUT" "and reads the parameter's value"
want 'mode:' "$OUT" "and its mode, which is the whole reason the experiment exists"
want 'what a trial would do' "$OUT" "and says what a trial would do"
want '--apply would run it' "$OUT" "and that it would proceed on this device"
run "--explain"
[ "$RC" = 0 ] && ok "--explain exits 0" || bad "--explain exited $RC"
want 'WHITELIST|4\.' "$OUT" "it explains the readings it takes"
want 'REFUTED / SUPPORTED' "$OUT" "and names the verdicts, including the one against the hypothesis"
notwant 'value: 1' "$OUT" "--explain reads no device file"

# ==================================================================================================
echo
echo "== 2. the guard: not the zl1 =="
# ==================================================================================================
FAKE_COMPAT=qcom,sdm845 run "--status"
[ "$RC" = 2 ] && ok "a different SoC exits 2" || bad "it exited $RC on the wrong device"
want 'not the zl1' "$OUT" "and says what it is refusing"
notwant 'download_mode|sleep_disabled' "$OUT" "and reads nothing beyond the guard"
FAKE_COMPAT=
FAKE_COMPAT=qcom,sdm845 run "--apply"
[ "$RC" = 2 ] && ok "and --apply on the wrong SoC exits 2 as well" || bad "it exited $RC"
FAKE_COMPAT=

# ==================================================================================================
echo
echo "== 3. prerequisite A: a panic that would arm EDL is a REFUSAL, and nothing is written =="
# ==================================================================================================
FAKE_DL=1 run "--apply"
[ "$RC" = 3 ] && ok "download_mode=1 refuses with exit 3" || bad "it exited $RC"
want 'REFUSED \(prerequisite A\)' "$OUT" "and names which prerequisite refused"
want 'install-no-edl-on-panic\.sh --install' "$OUT" "and the command that would satisfy it"
want 'Nothing was written' "$OUT" "and says the device was left alone"
[ "$(param)" = 1 ] && ok "the parameter still reads 1" || bad "the parameter reads $(param)"
FAKE_DL=
# The same refusal WITHOUT --apply must not even reach the refusal: --status only reports.
FAKE_DL=1 run "--status"
want 'A PANIC WOULD ARM EDL' "$OUT" "--status reports it without refusing"
want 'would REFUSE' "$OUT" "and says --apply would refuse"
FAKE_DL=

# ==================================================================================================
echo
echo "== 4. prerequisite B: no counters is a REFUSAL, because there is nothing to measure =="
# ==================================================================================================
FAKE_CPUIDLE=nodir run "--apply"
[ "$RC" = 3 ] && ok "no cpuidle directory refuses with exit 3" || bad "it exited $RC"
want 'NO CPU EXPOSES A cpuidle DIRECTORY' "$OUT" "and says the counters are not merely zero"
want 'REFUSED \(prerequisite B\)' "$OUT" "and names the prerequisite"
[ "$(param)" = 1 ] && ok "the parameter still reads 1" || bad "the parameter reads $(param)"
FAKE_CPUIDLE=

# ==================================================================================================
echo
echo "== 5. prerequisite C: the keeper, and the bystander that must not be mistaken for it =="
# ==================================================================================================
FAKE_KEEPER=1 run "--apply"
[ "$RC" = 3 ] && ok "the keeper running refuses with exit 3" || bad "it exited $RC"
want 'REFUSED \(prerequisite C\)' "$OUT" "and names the prerequisite"
want 'pid\(s\) 900' "$OUT" "and names the pid it matched"
notwant '903' "$OUT" "and does NOT match the shell that merely greps for the path (argv, not substring)"
want 'install-retire-debug-keeper\.sh --install --now --after-proof' "$OUT" "and the command that would retire it"
[ "$(param)" = 1 ] && ok "the parameter still reads 1" || bad "the parameter reads $(param)"
# And --status reports the keeper without refusing, because a reading is not a decision.
FAKE_KEEPER=1 run "--status"
want 'THE DEBUG KEEPER IS RUNNING' "$OUT" "--status reports it"
notwant 'REFUSED' "$OUT" "and does not refuse in a read-only mode"
FAKE_KEEPER=
# --allow-keeper proceeds and the verdict says the result is confounded -- not that it is the answer.
FAKE_KEEPER=1 run "--apply --allow-keeper"
want 'with a confounder recorded' "$OUT" "--allow-keeper proceeds with the confounder stated"
want 'CONFOUNDED' "$(verdict "$OUT")" "and the verdict says CONFOUNDED rather than concluding"
[ "$RC" = 1 ] && ok "and a confounded run exits 1 (it cannot be used as the answer)" || bad "it exited $RC"
[ "$(param)" = 1 ] && ok "and the parameter is back to 1" || bad "the parameter reads $(param)"
FAKE_KEEPER=

# ==================================================================================================
echo
echo "== 6. the parameter absent is not a refusal to explain away -- it is the answer =="
# ==================================================================================================
FAKE_PARAM=missing run "--apply"
[ "$RC" = 3 ] && ok "no parameter file refuses with exit 3" || bad "it exited $RC"
want 'sleep_disabled: NOT FOUND' "$OUT" "and says the file is not there"
want 'a reading about the driver on this boot' "$OUT" "and reads it as a fact about this boot's driver"
FAKE_PARAM=missing run "--status"
[ "$RC" = 1 ] && ok "--status on a device with no parameter exits 1" || bad "it exited $RC"
want 'the trial cannot run on this boot' "$OUT" "and says the experiment has no subject here"
FAKE_PARAM=

# ==================================================================================================
echo
echo "== 7. the happy path: the write happens, and the parameter ends where it started =="
# ==================================================================================================
"$W/reset.sh"
BEFORE="$(snap "$FR")"
run "--apply --settle 3"
printf '%s\n' "$OUT" > "$W/out.apply"
[ "$RC" = 0 ] && ok "--apply exits 0" || bad "--apply exited $RC"
want 'all three prerequisites are satisfied' "$OUT" "it says all three prerequisites hold"
want 'wrote .1. back to itself and read .1.' "$OUT" "it PROVES the write path with a same-value write first"
want 'wrote 0 and read 0 back' "$OUT" "then writes 0 and verifies the read-back"
want 'is back to 1, verified by read-back' "$OUT" "and reverts, verified by read-back"
[ "$(param)" = 1 ] && ok "the parameter reads 1 again at the end" || bad "the parameter reads $(param)"
# The only trace left in the fake device is the undo file the trial wrote on purpose: the whitelist is
# checked against the actual after-state, not against the source text.
DIFF="$( ( cd "$FR" && find . -type f -printf '%p\n' | sort ) )"
printf '%s\n' "$DIFF" | grep -q 'tmp/zl1-lpm-trial-revert.sh' \
  && ok "the undo file is on the device, where a lost session can still reach it" \
  || bad "the undo file was not written -- the undo would only exist in this session"
grep -q 'printf 1 >' "$FR/tmp/zl1-lpm-trial-revert.sh" 2>/dev/null \
  && ok "and it contains the revert command" \
  || bad "the undo file does not contain the revert command"
# Apart from that one new file, the device must be byte-identical to before the run -- outside the set the
# run is ENTITLED to move. There are exactly three such paths, and each is named rather than waved past:
#   the undo file (new, on purpose), the parameter (0 then back to 1 -- asserted above by its VALUE), and
#   the cpuidle counters. The counters are the odd one out and the reason matters: they move because the
#   STUB's `sleep` advances them, i.e. because the fake device did something while the settle window ran.
#   That is the measurement, not a write by the script. The one thing the counters cost is a regex that
#   cannot tell "the device moved them" from "the script wrote them" -- so the exclusion is kept honest by
#   the second check below, which requires the set of differing paths to be EXACTLY this set: a stray write
#   anywhere else still fails, and so does one inside the excluded tree (e.g. a `state*/disable`).
EXCL='tmp/zl1-lpm-trial-revert.sh|tmp/zl1-lpm-trial-before|tmp/zl1-lpm-trial-after|tmp/zl1-lpm-trial-deltas'
ENTITLED="$EXCL|sys/devices/system/cpu/cpu./cpuidle/state.|sys/module/lpm_levels/parameters/sleep_disabled"
SNAP_A="$( snap "$FR" | grep -vE "$ENTITLED" )"
SNAP_B="$( printf '%s\n' "$BEFORE" | grep -vE "$ENTITLED" )"
[ -n "$SNAP_A" ] && [ "$SNAP_A" = "$SNAP_B" ] \
  && ok "outside the three named paths, the fake device is byte-for-byte what it was" \
  || bad "the run changed something besides the parameter and the undo file"
# The manifest mixes two line shapes (`f <path> <size>` and `<md5>  <path>`), so the path is field 2 of the
# first and the last field of the second; reducing both to a path is what makes the set comparable.
diffs() { diff <(printf '%s\n' "$SNAP_B") <(printf '%s\n' "$SNAP_A") | sed -n 's/^[<>] //p' \
  | awk '{print ($1 == "f") ? $2 : $NF}' | sort -u; }
DIFFSET="$( diffs | grep -vE "$ENTITLED" | grep -v '^$' )"
[ -z "$DIFFSET" ] \
  && ok "and inside them, only the parameter and the counters differ -- no third thing moved" \
  || { bad "a path outside the entitled set differs: $DIFFSET"; }
# The state whose `disable` no run may touch, asserted by content rather than by its absence from the list
# above: the fixture has a disabled deepest state only in the section-8 scenario, so here every one must
# still read the same 0 it started with.
want '' "$(cat "$FR/sys/devices/system/cpu/cpu0/cpuidle/state2/disable" 2>/dev/null)" \
  "and no cpuidle state was disabled or re-enabled by the run"
# The window really happened: the stub sleep was called with the settle value the trial was given.
grep -q '^sleep 3$' "$ACT" && ok "the settle window used the --settle value it was given" || bad "the settle value did not reach sleep"

# ==================================================================================================
echo
echo "== 8. the verdict can REFUTE the hypothesis it was built to test =="
# ==================================================================================================
# The deep state had entries BEFORE the write. That kills the hypothesis for that state whatever the
# window shows -- and it is the reading that makes this an experiment rather than a demonstration.
FAKE_DEEP_BEFORE=37 run "--apply --settle 3"
want 'REFUTED' "$(verdict "$OUT")" "a state already being entered before the write is a REFUTATION"
want 'ALREADY being entered before this script wrote anything' "$(verdict "$OUT")" "and says exactly that"
want '37 time\(s\) since boot' "$(verdict "$OUT")" "with the before-count it read, not a zero"
want 'can come out against the thing it was built to test' "$(verdict "$OUT")" "and says why that matters"
[ "$RC" = 0 ] && ok "a refutation is a measurement, so it exits 0" || bad "it exited $RC"
[ "$(param)" = 1 ] && ok "and the parameter is back to 1" || bad "the parameter reads $(param)"
FAKE_DEEP_BEFORE=
# Supported, not proven: no entries before, entries during the window with the ladder allowed.
run "--apply --settle 3"
want 'SUPPORTED, NOT PROVEN' "$(verdict "$OUT")" "entries appearing only after the write is SUPPORTED, not PROVEN"
want 'not proof of it' "$(verdict "$OUT")" "and it says so in those words"
[ "$RC" = 0 ] && ok "a supported reading exits 0" || bad "it exited $RC"
[ "$(param)" = 1 ] && ok "and the parameter is back to 1" || bad "the parameter reads $(param)"
# No opportunity: the CPU was never idle, so the experiment says nothing. This is the case the keeper
# would produce, and it must be INCONCLUSIVE rather than "the ladder is off".
FAKE_IDLE=none run "--apply --settle 3"
want 'no idle state moved at all in this window' "$(verdict "$OUT")" "no idle opportunity is named as such"
want 'INCONCLUSIVE' "$(verdict "$OUT")" "and the verdict is INCONCLUSIVE, not a conclusion"
want 'says NOTHING about the ladder' "$(verdict "$OUT")" "with the reason"
[ "$RC" = 1 ] && ok "and an inconclusive run exits 1" || bad "it exited $RC"
[ "$(param)" = 1 ] && ok "and the parameter is back to 1" || bad "the parameter reads $(param)"
FAKE_IDLE=
# Opportunity but no entry: state0 moved, the deep state did not. The honest answer is NOT SUPPORTED.
FAKE_IDLE=shallow run "--apply --settle 3"
want 'NOT SUPPORTED' "$(verdict "$OUT")" "idle opportunity without a deep entry is NOT SUPPORTED"
want 'Do not report this as the fix' "$(verdict "$OUT")" "and says not to report it as the fix"
[ "$RC" = 0 ] && ok "and it exits 0 -- it IS a measurement" || bad "it exited $RC"
FAKE_IDLE=
# The deepest state disabled by the other mechanism: nothing this script writes can move it, so the run
# is confounded rather than a refutation.
FAKE_DEEP_DIS=1 run "--apply --settle 3"
want 'is DISABLED by the other mechanism' "$OUT" "a disabled deepest state is reported before the write"
want 'CONFOUNDED' "$(verdict "$OUT")" "and the verdict is CONFOUNDED"
[ "$RC" = 1 ] && ok "a confounded run exits 1" || bad "it exited $RC"
FAKE_DEEP_DIS=

# ==================================================================================================
echo
echo "== 9. the TRAP is what undoes it: a failure AFTER the write still leaves 1 =="
# ==================================================================================================
# The failure is injected into the DELTAS file, and the choice matters: the trial `rm -rf`s its two
# snapshot paths before using them (so a file planted there is simply removed), and it writes the deltas
# exactly once and then reads them back in the verdict. A directory planted at that path makes the write
# fail, which is the one failure this path can produce that would OTHERWISE be invisible: an empty deltas
# file makes every counter read as UNKNOWN, and the verdict would say "inconclusive" for a reason that is
# not on the device at all. That is what the trial's own deltas check exists for, and this is its teeth.
"$W/reset.sh"
rm -rf "$FR/tmp/zl1-lpm-trial-deltas"; mkdir -p "$FR/tmp/zl1-lpm-trial-deltas"
: > "$ACT"
env PATH="$STUB:$MINBIN" FAKE_AFTERFAIL=1 "$SH_BIN" "$RW" --apply --settle 3 > "$W/out.trap" 2>&1
RC=$?
OUT="$(tr -d '\000' < "$W/out.trap")"
[ "$RC" = 4 ] && ok "a failure after the write exits 4" || bad "it exited $RC"
want 'the deltas could not be recorded' "$OUT" "and says which step failed, after the write"
want 'for a reason that is not on the device' "$OUT" "and why an unrecorded delta is worth stopping for"
want '\[trap\]' "$OUT" "the trap is what reports the undo"
[ "$(param)" = 1 ] && ok "and the parameter is back to 1 -- the trap is what did it" || bad "the parameter reads $(param)"
rm -f "$FR/tmp/zl1-lpm-trial-after"
# The trap must NOT write on a path that never wrote in the first place: a refusal must stay byte-for-byte.
FAKE_DL=1 run "--apply"
[ "$(param)" = 1 ] && ok "a refusal leaves 1, and the trap did not write either" || bad "the parameter reads $(param)"
FAKE_DL=

# ==================================================================================================
echo
echo "== 10. --keep is the ONLY way to leave it changed, and it says so =="
# ==================================================================================================
run "--apply --settle 3 --keep"
[ "$(param)" = 0 ] && ok "--keep leaves the parameter at 0" || bad "the parameter reads $(param)"
want 'is LEFT at 0' "$OUT" "and says it was left deliberately"
want 'trap will not put it back either' "$OUT" "including by the trap"
want 'not persistent anyway' "$OUT" "and reminds the operator it does not survive a reboot"
want 'printf 1 > ' "$OUT" "and prints the exact revert command"
# The state --keep left behind IS the state under test here, so these do not reset first.
runraw "--revert"
[ "$(param)" = 1 ] && ok "--revert puts the 0 that --keep left back to 1" || bad "the parameter reads $(param)"
want 'verified by read-back' "$OUT" "and verifies the read-back"
runraw "--revert"
want 'already reads 1' "$OUT" "--revert on a device already at 1 says there is nothing to do"
# A value that will not take the write is a finding, not a silent success -- and it is the one path in
# this script that must not report a revert it did not perform.
#
# There are TWO such paths next to each other and only one of them can be built here:
#
#   (i)  the write is REFUSED  -- `printf 1 > "$PARAM"` fails, line 403. Reachable: a 0444 file is the
#        same shape to the script as a driver that will not take the value. This is the one that runs.
#   (ii) the write SUCCEEDS and does not STICK -- the read-back is not 1, line 409. NOT reachable here:
#        making a write land and then vanish needs a mount or a driver, and no permission bit does it.
#        It is pinned in the SOURCE instead (below), on every host, so a later edit that deletes the
#        branch is still caught. That is stated as a SKIP and counted out loud, not left silent.
want 'the write did NOT hold' "$(cat "$SRC")" \
  "the branch for a write that succeeds and vanishes is pinned in the source (it cannot be built here)"
F="$FR/sys/module/lpm_levels/parameters/sleep_disabled"
printf '0\n' > "$F"; chmod a-w "$F" 2>/dev/null
if [ "$(param)" = 0 ] && ! printf '' > "$F" 2>/dev/null; then
  runraw "--revert"
  want 'the write failed' "$OUT" "a revert whose write is refused is reported, not claimed"
  [ "$RC" = 4 ] && ok "and it exits 4" || bad "it exited $RC"
  [ "$(param)" = 0 ] && ok "and it does not pretend: the parameter still reads 0" || bad "the parameter reads $(param)"
else
  printf 'SKIP  a refused write is not reachable on this host (uid %s can still write a 0444 file)\n' "$(id -u 2>/dev/null || echo '?')"
  printf 'SKIP  so the same three checks are made in the SOURCE instead -- the branches stay pinned either\n'
  printf 'SKIP  way, and the count above is the same on a host that can reach it and one that cannot.\n'
  SKIPPED=$((SKIPPED + 1))
  want 'the write failed' "$(cat "$SRC")" "the refused-write branch's message is in the source"
  want 'exit 4' "$(sed -n '400,412p' "$SRC")" "and it exits 4 rather than report a revert it did not perform"
  want 'if [ "$P_NOW" = 1 ]' "$(cat "$SRC")" "and the write is followed by a read-back, not an assumption"
fi
chmod u+w "$F" 2>/dev/null

# ==================================================================================================
echo
echo "== 11. --quiet is not a mode here, and the header's promises match the code =="
# ==================================================================================================
# This script has no --quiet: its output IS the measurement, and unlike the probes there is no second
# consumer of the exit code that wants the readings suppressed. An unknown argument must be refused, not
# ignored -- a typo in a --apply line must not run the trial with a default it did not ask for.
run "--quiet"
[ "$RC" = 2 ] && ok "an unknown argument exits 2" || bad "it exited $RC"
want 'unknown argument' "$OUT" "and says which argument it did not understand"
[ "$(param)" = 1 ] && ok "and nothing was written" || bad "the parameter reads $(param)"
# The four declared exit codes are all reachable, and each is named in the header. The header is the
# contract; a code the header does not mention is a code nobody can use.
want '^# Exit codes: 0 ' "$(cat "$SRC")" "the header declares the exit codes"
for c in 'REFUTED, which is a measurement' '3 REFUSED' '4 the write happened'; do
  want "$c" "$(cat "$SRC")" "and names: $c"
done

# ==================================================================================================
echo
echo "== 12. the health check cites this harness's count, and that citation cannot drift =="
# ==================================================================================================
# The extractor is this family's (docs 110) and it is deliberately not the obvious one. `grep -oE '[0-9]+'`
# over a line containing this script's NAME would match the `1` in `zl1-...` and the first version of this
# check did exactly that: it read a citation of 120 as "1" and announced a drift that was not there. The
# name has to be matched FIRST and the number taken from what follows it. `[ ,(]*` is the separator
# because the citation may be written `name, N checks` or `name (N checks)`; the whole file is flattened
# to one line first so a citation broken across two lines still counts.
HEALTH="$HERE/zl1-health-check.sh"
if [ -r "$HEALTH" ]; then
  CITED="$(sed -e 's/always "/ /g' -e 's/"$//' "$HEALTH" | tr '\n' ' ' \
    | sed -n 's/.*zl1-lpm-ladder-trial-selftest\.sh[ ,(]*\([0-9][0-9]*\) checks.*/\1/p')"
  # +1 because this check is itself one of the checks it is counting -- without it the count is short by
  # exactly one, which is a drift the guard would report forever.
  N=$((PASS + FAIL + 1))
  if [ -z "$CITED" ]; then
    bad "the health check does not cite this harness at all -- add it to the item that names the offline verification"
  elif [ "$CITED" = "$N" ]; then
    ok "the health check cites $N checks, which is what this harness has"
  else
    bad "the health check cites $CITED checks, but this harness has $N -- fix host/zl1-health-check.sh"
  fi
else
  bad "cannot read $HEALTH -- the citation check cannot run"
fi

echo
echo "pass=$PASS fail=$FAIL"
if [ "$KEEP" = 1 ]; then
  echo "kept: $W"
else
  rm -rf "$W"
fi
[ "$FAIL" = 0 ] || exit 1
exit 0
