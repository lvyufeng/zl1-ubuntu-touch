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
# `readlink` is here for the ONE stub that needs to know which file it was handed: `tr` (below) does the
# device's type rendering, and it can only do it for the parameter. A curated PATH that lacks a tool
# silently disables any behaviour that needs it, which is the shape this repository has already recorded
# -- so the tool is added AND the stub is asserted to be able to tell the two files apart.
for t in awk basename cat cut head ls sed sort tail tr uniq wc grep chmod printf mkdir rm readlink; do
  p="$(type -P "$t" 2>/dev/null)" || continue
  [ -n "$p" ] && ln -sf "$p" "$MINBIN/$t"
done
for t in awk grep ls sed tail tr wc readlink; do
  [ -x "$MINBIN/$t" ] || { echo "the sandbox bin is missing $t -- the harness cannot run the trial honestly" >&2; exit 2; }
done
SH_BIN="$(type -P sh 2>/dev/null)"; [ -n "$SH_BIN" ] || SH_BIN=/bin/sh
[ -x "$SH_BIN" ] || { echo "no /bin/sh to run the trial with" >&2; exit 2; }
# The stubs delegate to the REAL binaries by absolute path, because inside the sandbox PATH is the
# sandbox and a bare name would find the stub again.
REAL_TR="$(type -P tr)"; [ -n "$REAL_TR" ] || { echo "no real tr on this host" >&2; exit 2; }

# --- the script under test, rewritten into the fake device -----------------------------------------
# TWO PASSES through tokens, for the reason its siblings record: a one-pass rewrite is a cascade, and a
# cascaded path is a script reading something that cannot exist while every scenario still passes.
#
# IT IS A FUNCTION because a MUTATION has to be rewritten the same way before it can be run: a section
# that edits the shipped source and then runs the UNREWRITTEN copy would read THIS HOST's /sys, and a
# section that asserts on a mutation without running it asserts about a file rather than about a
# behaviour. Every mutation this harness now runs goes through here.
rewrite() { # $1 = a trial source (shipped or mutated), $2 = where to write the fake-device copy
  sed -e 's#/proc/device-tree#__ZDT__#g' \
      -e 's#/proc/\[0-9\]\*#__ZGLOB__#g' \
      -e 's|\${d#/proc/}|\${d#__ZPROC__}|g' \
      -e 's#/sys/devices/system/cpu#__ZCPU__#g' \
      -e 's#/sys/module#__ZMOD__#g' \
      -e 's#/proc/#__ZPROC__#g' \
      -e 's#/tmp/zl1-lpm-trial#__ZTMP__#g' "$1" > "$W/.pass1.sh"
  sed -e "s#__ZDT__#$FR/proc/device-tree#g" \
      -e "s#__ZGLOB__#$FR/proc/[0-9]*#g" \
      -e "s#__ZPROC__#$FR/proc/#g" \
      -e "s#__ZCPU__#$FR/sys/devices/system/cpu#g" \
      -e "s#__ZMOD__#$FR/sys/module#g" \
      -e "s#__ZTMP__#$FR/tmp/zl1-lpm-trial#g" "$W/.pass1.sh" > "$2"
}
RW="$W/lpm-ladder-trial.sh"
P1="$W/pass1.sh"
rewrite "$SRC" "$RW"
cp "$W/.pass1.sh" "$P1"
sh -n "$RW" || { echo "the rewritten trial does not parse" >&2; exit 2; }
if grep -q -- '__Z' "$RW"; then
  echo "an unexpanded token is left in $RW:" >&2
  grep -n -- '__Z' "$RW" | sed -n '1,5p' >&2
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
want() { if grep -Eq -- "$1" <<< "$2"; then ok "$3"; else bad "$3"; grep -n . <<< "$2" | sed 's/^/        | /'; fi; }
notwant() { if grep -Eq -- "$1" <<< "$2"; then bad "$3"; grep -E -- "$1" <<< "$2" | sed 's/^/        | /'; else ok "$3"; fi; }
# The verdict is the LAST section of the trial, so it is extracted from its own header. Anchored on the
# numbered header and not on the first `->` line anywhere: this script prints `->` in earlier sections.
verdict() { printf '%s\n' "$1" | sed -n '/^== 10\. the verdict$/,$p'; }
# THE LINE, as opposed to the prose: the whole-line `== verdict: <name>` a caller can gate on. It is
# extracted with `grep -x`, i.e. the same whole-line rule the installer applies -- a test that accepted a
# substring would pass on a sentence that merely mentions the name (docs 114).
vline() { printf '%s\n' "$1" | grep -ax '== verdict: [a-z-]*' | tail -1 | sed 's/^== verdict: //'; }
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
      grep -qxF -- "$t" <<< "$DECLARED" || UNDECLARED="$UNDECLARED $t" ;;
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
      grep -qxF -- "$t" <<< "$SHIPPED_TARGETS" \
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
  if grep -q 'thermal_zone0/mode' <<< "$EXTRA"; then
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
#   FAKE_DL       0 | 1 | missing            prerequisite A: the panic -> EDL escalation (the real
#                                             module name, msm_poweroff)
#   FAKE_DL2      0 | 1                    a SECOND download_mode parameter that sorts after the first
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
         "$FR/sys/module/lpm_levels/parameters" "$FR/sys/module/msm_poweroff/parameters" 2>/dev/null
printf '%s\\0' "\${FAKE_COMPAT:-qcom,msm8996pro}" > "$FR/proc/device-tree/compatible"
printf 'qcom-cpuidle\\n' > "$FR/sys/devices/system/cpu/cpuidle/current_driver"
# /proc is NOT created wholesale: the keeper scenarios add their own processes, and a directory that
# exists but holds nothing is a different reading from one that is absent.
mkdir -p "$FR/proc"

# --- prerequisite A: the panic -> EDL escalation -------------------------------------------------
# The PRIMARY parameter carries the REAL module name, because on 2026-09-24 the device said what it is:
# \`/sys/module/msm_poweroff/parameters/download_mode = 1\`, read twice and archived in this repository
# (tmp-post-recovery-20260923T145530Z/01-edl-postmortem.txt:14 and
# tmp-post-recovery-20260924T013059Z/01-edl-postmortem.txt:13; docs 125). This fixture used to carry a
# fabricated near-miss name justified by doc 86's "never seen on a device" line -- which stopped being
# true the moment that capture was written, and which was also a misreading of 86 (86 said the name
# *should be* msm_poweroff and had not been confirmed; the device confirmed it).
#
# The glob tooth is kept, and made stronger, by FAKE_DL2: the trial reads EVERY parameter of that name,
# because the unit that arms the policy clears all of them and fails itself if any did not clear. So a
# decoy is a scenario -- with the primary at 0 and the decoy at 1, a reader that stops at the first match
# reports the gate SATISFIED on a boot where a panic would still arm EDL, i.e. it hands back exactly the
# finger the gate exists to save. The decoy sorts AFTER the primary on purpose (\`qcom_poweroff\`), so the
# primary is the first match and the two behaviours must disagree; the first decoy name tried
# (\`msm_mpoweroff\`) sorted BEFORE, both readers answered about the same parameter, and the mutation that
# removes the multi-match reading reddened everything except the check written for it.
case "\${FAKE_DL:-0}" in
missing) : ;;
*) printf '%s\\n' "\${FAKE_DL:-0}" > "$FR/sys/module/msm_poweroff/parameters/download_mode" ;;
esac
rm -rf "$FR/sys/module/qcom_poweroff"
case "\${FAKE_DL2:-}" in
"") : ;;
*) mkdir -p "$FR/sys/module/qcom_poweroff/parameters"
   printf '%s\\n' "\${FAKE_DL2}" > "$FR/sys/module/qcom_poweroff/parameters/download_mode" ;;
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

# --- the `tr` stub, which IS the parameter's type --------------------------------------------------
# The second load-bearing stub, and it exists because a fixture has to have the shape of the thing it
# stands for. `sleep_disabled` is declared `static bool` with a `module_param_named(..., bool, ...)` in
# drivers/cpuidle/lpm-levels.c, so the sysfs `show` renders what the file stores: the file holds 0 and a
# reader sees N. Every read the trial makes of that file goes through `rd()`, which is `tr -d '\n' < f`,
# so the rendering belongs on `tr` -- and putting it THERE rather than in the fixture is what keeps the
# two facts separable: the harness's own `param()` reads the same file with this shell's real `cat`, so a
# scenario can assert what the FILE holds while the script sees what the DEVICE says.
#
# THIS STUB IS WHY THE SECTION-6 DEFECT IS TESTABLE AT ALL. Until 2026-09-25 the fixture was a plain
# text file, which made the shipped script's `wanted 0` comparison and the fixed one's `is_off`
# behave IDENTICALLY -- a fixture that cannot make two behaviours differ cannot test either, and this
# harness reported 147 passes over a script that refused every good write on the real device.
#
# FAKE_STUCK is the second thing a plain text file cannot express: a write that LANDS and whose value
# does not take. That is what the device did on 2026-09-25 (for a different reason: the script misread a
# value that had taken), and it is the path whose comment in the trial used to say it was unreachable
# here. It renders Y whatever the file holds.
cat > "$STUB/tr" <<EOF
#!/bin/sh
in=\$(readlink /proc/self/fd/0 2>/dev/null)
case "\$in" in
*/parameters/sleep_disabled)
  case "\${FAKE_BOOL:-1}" in
  1)
    if [ "\${FAKE_STUCK:-0}" = 1 ]; then printf 'Y'; exit 0; fi
    v=\$(cat "\$in" 2>/dev/null | sed 's/[[:space:]]*\$//')
    case "\$v" in
    0) printf 'N' ;;
    1) printf 'Y' ;;
    *) printf '%s' "\$v" ;;
    esac
    exit 0 ;;
  esac ;;
esac
exec $REAL_TR "\$@"
EOF
chmod +x "$STUB/tr"
# The stub must be able to SEE the difference, and a `readlink` that resolved to nothing would make it
# delegate silently -- i.e. every alphabet scenario would pass while testing the plain-text fixture.
[ -x "$MINBIN/readlink" ] || { echo "the tr stub cannot tell the parameter from any other file" >&2; exit 2; }
printf 'N' > "$W/.stubprobe"
[ "$( "$STUB/tr" -d '\n' < "$W/.stubprobe" )" = 'N' ] \
  || { echo "the tr stub does not delegate for a file that is not the parameter" >&2; exit 2; }
printf '0' > "$W/.stubparam"
[ "$( "$STUB/tr" -d '\n' < "$W/.stubparam" )" = '0' ] \
  || { echo "the tr stub rendered a file that is not the parameter" >&2; exit 2; }
mkdir -p "$W/sys/module/lpm_levels/parameters"
printf '0' > "$W/sys/module/lpm_levels/parameters/sleep_disabled"
[ "$( "$STUB/tr" -d '\n' < "$W/sys/module/lpm_levels/parameters/sleep_disabled" )" = 'N' ] \
  || { echo "the tr stub does NOT render the parameter -- the alphabet scenarios would be vacuous" >&2; exit 2; }
rm -rf "$W/sys" "$W/.stubparam" "$W/.stubprobe"


export FAKE_COMPAT= FAKE_DL= FAKE_DL2= FAKE_CPUIDLE= FAKE_KEEPER= FAKE_PARAM= FAKE_DEEP_BEFORE= \
       FAKE_DEEP_DIS= FAKE_IDLE= FAKE_AFTERFAIL= FAKE_BOOL= FAKE_STUCK=

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
# The same, for a DIFFERENT script -- a mutation of the shipped one, rewritten into the same fake device.
# A mutation that is only grep'd is a statement about a file; a mutation that is RUN is a statement about
# a behaviour, and the sections below need the behaviour.
runscript() { # $1 = a rewritten script, $2 = extra arguments (may be empty)
  : > "$ACT"
  "$W/reset.sh"
  OUT="$( env PATH="$STUB:$MINBIN" "$SH_BIN" "$1" $2 2>&1 | tr -d '\000' )"
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
want 'value: Y' "$OUT" "and reads the parameter's value -- Y, because the file holds 1 and it is a bool"
want 'mode:' "$OUT" "and its mode, which is the whole reason the experiment exists"
want 'what a trial would do' "$OUT" "and says what a trial would do"
want '--apply would run it' "$OUT" "and that it would proceed on this device"
run "--explain"
[ "$RC" = 0 ] && ok "--explain exits 0" || bad "--explain exited $RC"
want 'WHITELIST|4\.' "$OUT" "it explains the readings it takes"
want 'REFUTED / SUPPORTED' "$OUT" "and names the verdicts, including the one against the hypothesis"
notwant 'value: Y' "$OUT" "--explain reads no device file"

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

# A is a reading of EVERY `download_mode` parameter, and not of the first one seen. The unit that arms
# this policy loops the same glob and FAILS ITSELF if any parameter did not clear, so a gate satisfied by
# the first match hands back exactly the finger it exists to save. FAKE_DL2 adds a second parameter that
# sorts AFTER the primary (`qcom_poweroff` > `msm_poweroff`), so the primary is the first match and a
# reader that stopped there must disagree with one that reads them all.
FAKE_DL=0 FAKE_DL2=1 run "--apply"
[ "$RC" = 3 ] && ok "a SECOND download_mode parameter at 1 refuses, even though the first reads 0" || bad "it exited $RC"
want 'REFUSED \(prerequisite A\)' "$OUT" "and it is the same refusal, on the same terms"
want 'qcom_poweroff' "$OUT" "and the report names the parameter that is armed, not only the one it read first"
[ "$(param)" = 1 ] && ok "and the parameter this trial writes still reads 1 -- the refusal wrote nothing" || bad "the parameter reads $(param)"
FAKE_DL=0 FAKE_DL2=0 run "--apply"
[ "$RC" != 3 ] && ok "with BOTH parameters at 0 the gate opens (the run gets past A)" || bad "it refused at A with both at 0"
FAKE_DL= FAKE_DL2=
# "NOT FOUND" means no such parameter anywhere, not "the one under the first name is absent".
FAKE_DL=missing FAKE_DL2=0 run "--status"
notwant 'NOT FOUND' "$OUT" "with the primary absent but another parameter present, A is not reported as untestable"
want 'all 1 download_mode parameter' "$OUT" "and it reports the one it found"
FAKE_DL= FAKE_DL2=

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
[ "$(vline "$OUT")" = confounded ] && ok "and the whole line is '== verdict: confounded'" || bad "the line is '$(vline "$OUT")'"
[ "$RC" = 1 ] && ok "and a confounded run exits 1 (it cannot be used as the answer)" || bad "it exited $RC"
[ "$(param)" = 1 ] && ok "and the parameter is back to 1" || bad "the parameter reads $(param)"
FAKE_KEEPER=
# THE OTHER CONFOUNDED BRANCH, and why it needs its own scenario: the keeper confounder above reaches
# the SUPPORTED branch (the deep state DID move in the window). The branch where the deep state did NOT
# move and a confounder is recorded is a different branch, and it printed "Exit 1." while exiting 0 --
# the script's own header defines exit 1 as "INCONCLUSIVE or CONFOUNDED", and this is one of its two
# CONFOUNDED branches. Nothing reached it, so nothing caught it. This is the scenario that does.
FAKE_KEEPER=1 FAKE_IDLE=shallow run "--apply --allow-keeper"
want 'CONFOUNDED' "$(verdict "$OUT")" "a confounder with NO deep entry is the other CONFOUNDED branch"
[ "$(vline "$OUT")" = confounded ] && ok "and its whole line is '== verdict: confounded' too" || bad "the line is '$(vline "$OUT")'"
[ "$RC" = 1 ] && ok "and it exits 1 -- the prose said 'Exit 1.' and the code used to exit 0, which is the defect this scenario exists for" || bad "it exited $RC"
[ "$(param)" = 1 ] && ok "and the parameter is back to 1" || bad "the parameter reads $(param)"
FAKE_KEEPER= FAKE_IDLE=

# ==================================================================================================
echo
echo "== 5b. the baseline: a parameter that is ALREADY off is a REFUSAL, because the counters are cumulative =="
# ==================================================================================================
# docs 163's second measurement, and the one the authorized run of 2026-09-25 produced: the verdict's test
# is "had the deep state EVER been entered before the write", cpuidle's counters are CUMULATIVE since boot,
# and so a boot on which something had already written 0 has counters holding entries made while the ladder
# was ALLOWED -- the verdict then answers about whoever wrote 0 last. On the device that read as REFUTED
# while the same boot's earlier reading (parameter at 1 since boot, 4h42m) was `state1 usage=0
# state2 usage=0`; 127 seconds with the ladder OFF moved neither counter. The verdict had inverted its data.
#
# The two `--apply` scenarios below are a PAIR, and the pair is the whole point: `0` is what a WRITER puts
# in the file, `N` is what a READER gets back (the tr stub renders it), and a guard keyed on the first is
# blind to a device that only ever shows the second. So the mutant is the guard as it would be written by
# somebody reading docs 121 rather than the source, and it must NOT refuse.
FAKE_PARAM=0 run "--apply"
[ "$RC" = 3 ] && ok "a parameter that is already 0 refuses with exit 3" || bad "it exited $RC"
want 'REFUSED \(baseline D\)' "$OUT" "and names the baseline as what refused"
want 'ALREADY off' "$OUT" "and says the state it found"
want 'cumulative since boot' "$OUT" "and why that makes the counters unusable rather than merely odd"
want 'REBOOT' "$OUT" "and the remedy -- the only one of these refusals whose fix is not a script"
want 'Nothing was written' "$OUT" "and says the device was left alone"
[ "$(param)" = 0 ] && ok "the parameter still reads 0 -- the refusal wrote nothing" || bad "the parameter reads $(param)"
# The same state SPELLED THE WAY THE DEVICE SPELLS IT. The fixture file holds `N`, which is what a device
# shows after a successful `printf 0`; `rd()` passes it through, so the trial reads `N`.
FAKE_PARAM=N run "--apply"
[ "$RC" = 3 ] && ok "the same state, in the device's own alphabet (N), refuses too" || bad "an N did not refuse: it exited $RC"
want 'REFUSED \(baseline D\)' "$OUT" "and it is the same refusal"
sed 's#^if is_off "$P_BEFORE"; then$#if [ "$P_BEFORE" = 0 ]; then#' "$SRC" > "$W/mut-baseline.sh"
if cmp -s "$SRC" "$W/mut-baseline.sh"; then
  bad "the baseline mutation did not land (its sed matches no line), so the pair above is not a measurement"
else
  ok "the baseline mutation really differs from the shipped file"
  rewrite "$W/mut-baseline.sh" "$W/mut-baseline.rw.sh"
  FAKE_PARAM=N runscript "$W/mut-baseline.rw.sh" "--apply --settle 3"
  [ "$RC" = 0 ] && ok "a guard written as \`= 0\` does NOT refuse on an N -- which is what makes the shipped one an alphabet" \
    || bad "the mutant exited $RC instead of running, so the pair above tested something else"
  [ "$(param)" = 1 ] && ok "and it ran the write and the revert, which is what 'not refused' means here" \
    || bad "the mutant's parameter reads $(param) -- it did not complete a write"
fi
FAKE_PARAM=
# --status reports it and does not refuse, exactly as it does for A and C: the refusal belongs to the write,
# and --status is the mode somebody runs while deciding whether to spend a boot on the sequence.
FAKE_PARAM=0 run "--status"
[ "$RC" = 0 ] && ok "--status on the same device exits 0" || bad "--status exited $RC"
want 'ALREADY off' "$OUT" "it reports the baseline as not met"
want 'NOT all of them are satisfied' "$OUT" "and says --apply would refuse, without refusing itself"
# And the remedy the refusal NAMES, exercised. A refusal that names a command nothing checks is a sentence.
FAKE_PARAM=0 run "--revert"
[ "$RC" = 0 ] && ok "--revert on that device exits 0" || bad "--revert exited $RC"
[ "$(param)" = 1 ] && ok "and puts the parameter back to 1" || bad "the parameter reads $(param)"
want 'is back to 1|put back to 1' "$OUT" "and says so, verified by read-back"
FAKE_PARAM=

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
want 'wrote .Y. back to itself and read .Y.' "$OUT" "it PROVES the write path with a same-value write first"
want "wrote 0 and read 'N' back" "$OUT" "then writes 0 and reads the N the device renders for it"
want "is back to 1 .it reads 'Y'., verified by read-back" "$OUT" "and reverts, verified by read-back"
[ "$(param)" = 1 ] && ok "the parameter reads 1 again at the end" || bad "the parameter reads $(param)"
# The only trace left in the fake device is the undo file the trial wrote on purpose: the whitelist is
# checked against the actual after-state, not against the source text.
DIFF="$( ( cd "$FR" && find . -type f -printf '%p\n' | sort ) )"
grep -q 'tmp/zl1-lpm-trial-revert.sh' <<< "$DIFF" \
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
echo "== 7a. the parameter has a TYPE: the file stores 0 and the device renders it N =="
# ==================================================================================================
# The section that would have caught the 2026-09-25 defect, and it is built as a PAIR so that it is a
# measurement rather than a demonstration of the thing it just set up:
#
#   * WITH THE TYPE (FAKE_BOOL=1, the default and the real shape) the shipped script must pass, and the
#     MUTATION that puts the old comparison back -- `!= 0` in place of `is_off` -- must exit 4 and say
#     `read-back is 'N'`, which is word-for-word what the device said;
#   * WITHOUT THE TYPE (FAKE_BOOL=0, a plain text file -- the shape this fixture used to have) BOTH must
#     pass, which is what makes the type the only difference between them.
#
# The second half is the control, and it is the point: a fixture that cannot make the two behaviours
# differ cannot test either one. On 2026-09-25 this harness reported 147 passes over a script that
# refused every good write on the real device, because its parameter file had no type.
"$W/reset.sh"
run "--apply --settle 3"
[ "$RC" = 0 ] && ok "with the type on, --apply exits 0 (a bool parameter is not a failure)" || bad "--apply exited $RC"
want "wrote 0 and read 'N' back" "$OUT" "and it treats the rendered N as OFF, which is what it means"
notwant 'the write did not hold' "$OUT" "and never reports its own good write as one that did not hold"
[ "$(param)" = 1 ] && ok "and the file is back to the raw 1 the trap wrote" || bad "the file reads $(param)"

sed 's#^if ! is_off "\$P_AFTER_WRITE"; then$#if [ "$P_AFTER_WRITE" != 0 ]; then#' "$SRC" > "$W/mut-wanted0.sh"
if cmp -s "$SRC" "$W/mut-wanted0.sh"; then
  bad "the alphabet mutation did not land (its sed matches no line), so nothing below is pinned"
else
  ok "the alphabet mutation really differs from the shipped trial"
  rewrite "$W/mut-wanted0.sh" "$W/mut-wanted0.rw.sh"
  sh -n "$W/mut-wanted0.rw.sh" || bad "the mutated trial does not parse -- the mutation is malformed"
  runscript "$W/mut-wanted0.rw.sh" "--apply --settle 3"
  [ "$RC" = 4 ] && ok "the OLD comparison refuses the same good write, with exit 4" || bad "it exited $RC"
  want "read-back is 'N'" "$OUT" "and names the rendering as the reason -- exactly what the device said"
  # The control. Same fixture, same two scripts, type removed: now there is nothing to disagree about.
  FAKE_BOOL=0 run "--apply --settle 3"
  [ "$RC" = 0 ] && ok "with NO type (the old fixture) the shipped script still passes -- the control" || bad "it exited $RC"
  want "wrote 0 and read '0' back" "$OUT" "and reads back the string it wrote, as a text file would"
  FAKE_BOOL=0 runscript "$W/mut-wanted0.rw.sh" "--apply --settle 3"
  [ "$RC" = 0 ] && ok "and the MUTATION passes there too -- so the TYPE is the only difference" \
    || bad "the mutation exited $RC without a type, so the pair proves nothing"
fi
FAKE_BOOL=

# ==================================================================================================
echo
echo "== 7b. the verdict LINE, which is what a caller may gate on =="
# ==================================================================================================
# Every branch prints `== verdict: <name>` as a WHOLE line, in the form this tree's other probes use.
# Before this stage none of the five outcomes was a line at all -- they were prose separated by exit
# code, which is enough for a person and not enough for anything that has to decide on it.
# A here-string and not a pipeline: under `set -o pipefail` a `printf | grep -q` reports the WRITER's
# SIGPIPE, so a match that IS there can be printed as a missing one (docs 134 measured it, 4 red runs in
# 100 at this size -- and this harness's own family meta-check scans every pipefail harness for exactly
# this shape and reddened on the first draft of this loop).
VSRC=$(sed 's/#.*//' "$SRC")
for n in refuted supported-not-proven not-supported inconclusive confounded; do
  if grep -Eq -- "== verdict: $n" <<< "$VSRC"; then
    ok "the subject can print '== verdict: $n'"
  else
    bad "'== verdict: $n' is not in the subject -- an outcome with no line is an outcome nothing can gate on"
  fi
done
# Exactly one, on every path that reaches the verdict at all: a second line would make "the last one
# wins" the rule, and that is not a rule, that is an accident.
run "--apply --settle 3"
[ "$(printf '%s\n' "$OUT" | grep -ac '== verdict: [a-z-]*')" = 1 ] \
  && ok "and a run prints exactly ONE verdict line, so 'the last one' is the only one" \
  || bad "this run printed $(printf '%s\n' "$OUT" | grep -ac '== verdict: [a-z-]*') verdict lines"
# The refusing paths must print NONE: a refusal is not a verdict about the ladder, and a line there
# would let the installer read "confounded" out of a run that never happened.
FAKE_PARAM=missing run "--apply"
[ "$(printf '%s\n' "$OUT" | grep -ac '== verdict: [a-z-]*')" = 0 ] \
  && ok "and a REFUSAL prints no verdict line at all (a refusal is not a reading about the ladder)" \
  || bad "a refusal printed a verdict line: $(vline "$OUT")"

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
[ "$(vline "$OUT")" = refuted ] && ok "and the whole line is '== verdict: refuted'" || bad "the line is '$(vline "$OUT")'"
[ "$RC" = 0 ] && ok "a refutation is a measurement, so it exits 0" || bad "it exited $RC"
[ "$(param)" = 1 ] && ok "and the parameter is back to 1" || bad "the parameter reads $(param)"
FAKE_DEEP_BEFORE=
# Supported, not proven: no entries before, entries during the window with the ladder allowed.
run "--apply --settle 3"
want 'SUPPORTED, NOT PROVEN' "$(verdict "$OUT")" "entries appearing only after the write is SUPPORTED, not PROVEN"
want 'not proof of it' "$(verdict "$OUT")" "and it says so in those words"
[ "$(vline "$OUT")" = supported-not-proven ] && ok "and the whole line is '== verdict: supported-not-proven'" || bad "the line is '$(vline "$OUT")'"
[ "$RC" = 0 ] && ok "a supported reading exits 0" || bad "it exited $RC"
[ "$(param)" = 1 ] && ok "and the parameter is back to 1" || bad "the parameter reads $(param)"
# No opportunity: the CPU was never idle, so the experiment says nothing. This is the case the keeper
# would produce, and it must be INCONCLUSIVE rather than "the ladder is off".
FAKE_IDLE=none run "--apply --settle 3"
want 'no idle state moved at all in this window' "$(verdict "$OUT")" "no idle opportunity is named as such"
want 'INCONCLUSIVE' "$(verdict "$OUT")" "and the verdict is INCONCLUSIVE, not a conclusion"
want 'says NOTHING about the ladder' "$(verdict "$OUT")" "with the reason"
[ "$(vline "$OUT")" = inconclusive ] && ok "and the whole line is '== verdict: inconclusive'" || bad "the line is '$(vline "$OUT")'"
[ "$RC" = 1 ] && ok "and an inconclusive run exits 1" || bad "it exited $RC"
[ "$(param)" = 1 ] && ok "and the parameter is back to 1" || bad "the parameter reads $(param)"
FAKE_IDLE=
# Opportunity but no entry: state0 moved, the deep state did not. The honest answer is NOT SUPPORTED.
FAKE_IDLE=shallow run "--apply --settle 3"
want 'NOT SUPPORTED' "$(verdict "$OUT")" "idle opportunity without a deep entry is NOT SUPPORTED"
want 'Do not report this as the fix' "$(verdict "$OUT")" "and says not to report it as the fix"
[ "$(vline "$OUT")" = not-supported ] && ok "and the whole line is '== verdict: not-supported'" || bad "the line is '$(vline "$OUT")'"
[ "$RC" = 0 ] && ok "and it exits 0 -- it IS a measurement" || bad "it exited $RC"
FAKE_IDLE=
# The deepest state disabled by the other mechanism: nothing this script writes can move it, so the run
# is confounded rather than a refutation.
FAKE_DEEP_DIS=1 run "--apply --settle 3"
want 'is DISABLED by the other mechanism' "$OUT" "a disabled deepest state is reported before the write"
want 'CONFOUNDED' "$(verdict "$OUT")" "and the verdict is CONFOUNDED"
[ "$(vline "$OUT")" = confounded ] && ok "and the whole line is '== verdict: confounded'" || bad "the line is '$(vline "$OUT")'"
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
echo "== 9b. what ARMS the trap: the write's own redirect, not the read-back it guards =="
# ==================================================================================================
# This section exists because the two halves of the 2026-09-25 defect are independent, and fixing either
# one alone leaves a hazard:
#
#   * the ALPHABET (section 7a) made the script refuse a write that had held;
#   * the FLAG made that refusal abandon the change. `WROTE=1` used to sit AFTER the read-back check, so
#     the one path that leaves the parameter changed without knowing it -- the read-back that says "did
#     not hold" while the write DID land -- was the one path that left the trap disarmed. Measured on the
#     device: `sleep_disabled` read N with the script's exit long behind it and nothing owning it.
#
# FAKE_STUCK is the fixture for it: the write LANDS (the file really holds 0) and the value that comes
# back is not OFF. A plain text file cannot express that, which is why the trial's own comment used to
# say this branch was unreachable here and pinned it in the source text instead. It is reachable now.
FAKE_BOOL=1 FAKE_STUCK=1 run "--apply --settle 3"
[ "$RC" = 4 ] && ok "a write that lands and does not take exits 4" || bad "it exited $RC"
want 'the write did not hold' "$OUT" "and says so"
want '\[trap\].*put back to 1' "$OUT" "and the TRAP puts it back, on the refusal path"
[ "$(param)" = 1 ] && ok "and the file is back to 1 -- the refusal did not abandon the change" \
  || bad "the file reads $(param): the refusal left the parameter changed"
FAKE_BOOL= FAKE_STUCK=

# The tooth, and it is the old arrangement: `WROTE=1` deleted, so the flag is only ever set where it used
# to be. Same fixture, same failure -- and this time the change is abandoned.
sed 's#^WROTE=1$##' "$SRC" > "$W/mut-noarm.sh"
if cmp -s "$SRC" "$W/mut-noarm.sh"; then
  bad "the WROTE mutation did not land (its sed matches no line), so the trap's arming is not pinned"
else
  ok "the WROTE mutation really differs from the shipped trial"
  # The shipped file has exactly one `^WROTE=1$`; if a later edit adds a second, deleting both would make
  # the mutation mean something else and this count is where that shows up.
  [ "$(grep -c '^WROTE=1$' "$SRC")" = 1 ] \
    && ok "and the shipped trial sets WROTE=1 in exactly one place" \
    || bad "the trial has $(grep -c '^WROTE=1$' "$SRC") 'WROTE=1' lines -- the mutation is not surgical"
  rewrite "$W/mut-noarm.sh" "$W/mut-noarm.rw.sh"
  FAKE_BOOL=1 FAKE_STUCK=1 runscript "$W/mut-noarm.rw.sh" "--apply --settle 3"
  [ "$RC" = 4 ] && ok "the UNARMED trap still reports the failure" || bad "it exited $RC"
  [ "$(param)" = 0 ] && ok "and it LEAVES the parameter changed -- which is what the flag's position buys" \
    || bad "the file reads $(param): the mutation did not reproduce the hazard"
  FAKE_BOOL= FAKE_STUCK=
fi

# ==================================================================================================
echo
echo "== 10. --keep is the ONLY way to leave it changed, and it says so =="
# ==================================================================================================
run "--apply --settle 3 --keep"
[ "$(param)" = 0 ] && ok "--keep leaves the parameter at 0" || bad "the parameter reads $(param)"
want 'is LEFT at 0' "$OUT" "and says it was left deliberately"
want 'will not put it' "$OUT" "including by the trap"
want 'not persistent anyway' "$OUT" "and reminds the operator it does not survive a reboot"
want 'printf 1 > ' "$OUT" "and prints the exact revert command"
# The state --keep left behind IS the state under test here, so these do not reset first.
runraw "--revert"
[ "$(param)" = 1 ] && ok "--revert puts the 0 that --keep left back to 1" || bad "the parameter reads $(param)"
want 'verified by read-back' "$OUT" "and verifies the read-back"
runraw "--revert"
want "already reads 'Y', which is ON" "$OUT" "--revert on a device already ON says there is nothing to do"
# A value that will not take the write is a finding, not a silent success -- and it is the one path in
# this script that must not report a revert it did not perform.
#
# There are TWO such paths next to each other, and they are now BOTH built here:
#
#   (i)  the write is REFUSED  -- `printf 1 > "$PARAM"` fails. A 0444 file is the same shape to the
#        script as a driver that will not take the value. This is the one that runs, unless the harness
#        is root (a root user can still write a 0444 file), in which case it is pinned in the source.
#   (ii) the write SUCCEEDS and does not STICK -- the read-back is not ON. This needed a MOUNT or a
#        driver to build until section 9b, and the comment here used to say so; FAKE_STUCK is that, in
#        the stub that owns the rendering, and section 9b runs it against the shipped `--apply` and
#        against the mutation that disarms the trap.
want 'the write did NOT hold' "$(cat "$SRC")" \
  "the branch for a write that succeeds and does not stick is in the source AND run in section 9b"
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
  want 'if is_on "$P_NOW"' "$(cat "$SRC")" "and the write is followed by a read-back, not an assumption"
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
echo "== 11b. this harness's own want() cannot be defeated by its writer =="
# ==================================================================================================
# MEASURED, not reasoned about, and it took a while to believe. While verifying docs 133 this harness
# reported a FAIL for a check whose haystack -- read back at the moment of failure -- DID hold the
# pattern: 36615 bytes, 647 lines, and the same `grep -Eq` re-run on the same string returned 0. The
# reader was not the tool that failed. `want` used to be `printf '%s\n' "$2" | grep -Eq -- "$1"`, and
# under `set -o pipefail` a pipeline's status is the last non-zero status ANYWHERE in it -- so when the
# reader exits at the first match (which is what -q is for) and the writer has not finished writing, the
# writer is killed by SIGPIPE and pipefail reports the WRITER's death as this check's answer. At the
# moment of failure `PIPESTATUS` was `printf=141 grep=0`: the pattern matched, and the check said no.
#
# It is a race -- 4 red runs in 100 here -- and it stops being a race the moment the haystack is bigger
# than a pipe: measured with a 2 MB haystack whose match is on line 1, the old shape failed 200/200 and
# handing the same string to grep with no writer process in between failed 0/200. So the trap below is
# deterministic on every host, with no load required: put the writer back in the pipeline and it fails
# every time. That is the whole point -- a check that only fails sometimes is a check nobody can act on.
BIG="$( { printf 'the first line is the one that matches\n'; seq 1 200000; } )"
NBIG=${#BIG}
[ "$NBIG" -gt 1000000 ] \
  && ok "the trap's haystack is $NBIG bytes, larger than any default pipe (so a writer in the pipeline must block)" \
  || bad "the trap's haystack is only $NBIG bytes -- it may fit in a pipe, and then the trap proves nothing"
want '^the first line is the one that matches$' "$BIG" \
  "a haystack larger than a pipe ($(printf '%s' "$BIG" | wc -c) bytes) with the match on its FIRST line"
notwant 'a pattern that is nowhere in the haystack' "$BIG" \
  "and the same haystack does not match a pattern that is not in it"
# The mechanism itself is NOT re-measured here, and that is deliberate: measuring it needs the exact shape
# the family now forbids (a writer on the left of an early-exiting reader), and a guard that has to carry
# an exemption for its own demonstration is worse than a demonstration that lives in the doc. The numbers
# above are from that measurement: `PIPESTATUS` printf=141 grep=0 at the failure, 4/100 runs here, 200/200
# false failures with a haystack this size and the match on line 1, 0/200 with the here-string.

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
