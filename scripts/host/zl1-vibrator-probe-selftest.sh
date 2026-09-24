#!/usr/bin/env bash
# zl1 vibrator probe -- offline self-test. Host-side, touches no device, needs no phone.
#
# Why this exists. `scripts/device/zl1-vibrator-probe.sh` is the probe that came with a CORRECTION: doc 137
# listed `vibrator` as a gap matched by the node /soc/i2c@75b7000/drv2604l@5a (compatible ti,drv2604l, "only
# in the rebuilt set"), and that node belongs to a DIFFERENT PHONE whose device trees are appended to the
# same flashed boot image. This board's vibrator is the PMI8994 haptics block (qcom,qpnp-haptic), which is in
# all three device-tree sets and which nothing here had ever read. Four things are therefore worth holding
# the probe to, and each of them is a scenario below:
#
#   1. WHICH BOARD'S TREE IS RUNNING COMES FIRST. Both boards' trees carry the IDENTICAL root compatible
#      (`qcom,msm8996-mtp\0qcom,msm8996\0qcom,mtp`), so the guard every sibling probe uses cannot tell them
#      apart; `model` can. On the X2's tree this very block is `status = disabled`, so the board reading and
#      the hardware reading agree -- and a probe that checked the hardware first would report a driver
#      problem on a phone it is not even looking at.
#   2. IT WRITES NOTHING, checked statically AND with teeth. `/sys/class/timed_output/vibrator/enable` is the
#      file a vibrator HAL writes a millisecond count to, so "just check it buzzes" is one `printf` away, and
#      the mutation is exactly that printf.
#   3. A NODE THAT COULD NOT BE SEARCHED IS NOT A NODE THAT IS ABSENT. The probe finds the node by scanning
#      for its `compatible` (doc 137's lesson: a node's path is a thing that moves), so it has to keep "find(1)
#      is missing and no known shape exists" apart from "the tree has no such node". The scenario runs with a
#      sandbox that has no `find` at all, which is the only honest way to reach that state.
#   4. A DEVICE-TREE u32 IS BIG-ENDIAN. `od -tu4` on this little-endian host prints 0x00000e74 (3700 mV) as
#      0x740e0000 -- a number that looks like a reading and is not one. The fixture writes the real bytes and
#      asserts the value, so a byte-order regression reddens a check instead of a reader.
#
# How it works: **the stub directory IS the device.** The probe runs as itself against a fake root, with the
# device's tools stubbed and PATH sandboxed to `$STUB:$MINBIN`, where MINBIN holds symlinks to the real
# coreutils. The sandbox matters here as much as it did for the modem, LMH and LED probes: this host is not
# the device, and a probe that fell through to a real path would read THIS laptop's /proc and report it as
# the phone's.
#
# Usage: zl1-vibrator-probe-selftest.sh [--keep]
#   --keep   leave the fake device, the stubs and the rewritten probe for inspection
#
# `ZL1_VIBRATOR_PROBE_SRC=/path` runs the whole thing against another copy of the subject, which is how a
# revision (or a mutation) is shown to fail.
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
SRC="${ZL1_VIBRATOR_PROBE_SRC:-$HERE/../device/zl1-vibrator-probe.sh}"
[ -r "$SRC" ] || { echo "cannot read the subject: $SRC" >&2; exit 2; }

W="${TMPDIR:-/tmp}/zl1-vibrator-probe-selftest"
# `root`, not `dev`: the fake root's path must not itself contain a path the rewriter hunts for, or the
# replacement text gets rewritten in turn (the trap docs 120 records for its sibling harnesses).
FR="$W/root"
STUB="$W/stub"
MINBIN="$W/minbin"
MINBIN_NOFIND="$W/minbin-nofind"
rm -rf "$W"
mkdir -p "$STUB" "$MINBIN" "$MINBIN_NOFIND" || exit 2

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
want() { if grep -Eq -- "$1" <<< "$2"; then ok "$3"; else bad "$3"; sed 's/^/        | /' <<< "$2"; fi; }
notwant() { if grep -Eq -- "$1" <<< "$2"; then bad "$3"; grep -E -- "$1" <<< "$2" | sed 's/^/        | /'; else ok "$3"; fi; }
# A check that passes for free on an empty string is not a check.
nonempty() { if [ -n "$2" ]; then ok "$1"; else bad "$1 -- the output was empty, so nothing below it can be trusted"; fi; }
# A count, asserted as a number rather than as a substring: "8 entries" and "18 entries" both contain "8".
count_is() { # $1 = text, $2 = ERE, $3 = expected count, $4 = label
  local n; n=$(grep -cE -- "$2" <<< "$1")
  if [ "$n" = "$3" ]; then ok "$4"; else bad "$4 (expected $3, counted $n)"; fi
}

# --- the sandbox PATH ------------------------------------------------------------------------------
# `type -P`, not `command -v`: in a shell whose profile has made one of these a function, `command -v`
# prints the NAME rather than a path and the symlink would point at itself.
for t in awk basename cat cut dirname find grep head od sed sort tail tr uniq wc; do
  p="$(type -P "$t" 2>/dev/null)" || continue
  [ -n "$p" ] || continue
  ln -sf "$p" "$MINBIN/$t"
  [ "$t" = find ] || ln -sf "$p" "$MINBIN_NOFIND/$t"
done
for t in awk grep head od sed tail tr cut find; do
  [ -x "$MINBIN/$t" ] || { echo "the sandbox bin is missing $t -- cannot run the probe honestly" >&2; exit 2; }
done
# The second sandbox exists to make ONE state reachable: a device whose kernel has no find(1). Without it,
# "the tree could not be searched" is unreachable and the check that separates it from an absence tests
# nothing.
[ -e "$MINBIN_NOFIND/find" ] && { echo "the no-find sandbox has a find in it" >&2; exit 2; }
[ -x "$MINBIN_NOFIND/tr" ] || { echo "the no-find sandbox is not usable" >&2; exit 2; }
SH_BIN="$(type -P sh 2>/dev/null)"; [ -n "$SH_BIN" ] || SH_BIN=/bin/sh
[ -x "$SH_BIN" ] || { echo "no /bin/sh to run the probe with" >&2; exit 2; }

# --- the subject, rewritten into the fake device ---------------------------------------------------
#
# TWO PASSES in two FILES, so each rule is counted where it ran. A one-pass rewrite cascades: the `/sys/`
# inside `/proc/sys/kernel/random/boot_id` would be replaced by the `/proc/` rule and then the `/sys/` rule
# would hit the result. Pass 1 turns each root into a token that cannot itself be a device path; pass 2
# expands the tokens, and nothing in a replacement can be re-matched by a rule that already ran.
A1="$W/pass1a.sh"; P1="$W/pass1.sh"; RW="$W/vibrator-probe.sh"
rewrite() { # $1 = source, $2 = output
  sed -e 's#/proc/#__ZP__#g' "$1" > "$W/pass1a.sh"
  sed -e 's#/sys/#__ZS__#g' "$W/pass1a.sh" > "$W/pass1.sh"
  sed -e "s#__ZP__#$FR/proc/#g" -e "s#__ZS__#$FR/sys/#g" "$W/pass1.sh" > "$2"
}
sed -e 's#/proc/#__ZP__#g' "$SRC" > "$A1"
cnt() { grep -o -- "$1" "$2" 2>/dev/null | wc -l | tr -d ' '; }
[ "$(cnt '/proc/' "$SRC")" = "$(cnt '__ZP__' "$A1")" ] \
  || { echo "the /proc/ rewrite did not cover every /proc/ in the source" >&2; exit 2; }
[ "$(cnt '/proc/' "$A1")" = 0 ] || { echo "a /proc/ survived pass 1 -- the probe would read this host" >&2; exit 2; }
sed -e 's#/sys/#__ZS__#g' "$A1" > "$P1"
[ "$(cnt '/sys/' "$A1")" = "$(cnt '__ZS__' "$P1")" ] \
  || { echo "the /sys/ rewrite did not cover every /sys/ in $A1" >&2; exit 2; }
[ "$(cnt '/sys/' "$P1")" = 0 ] || { echo "a /sys/ survived pass 1 -- the probe would read this host" >&2; exit 2; }
sed -e "s#__ZP__#$FR/proc/#g" -e "s#__ZS__#$FR/sys/#g" "$P1" > "$RW"
sh -n "$RW" || { echo "the rewritten probe does not parse" >&2; exit 2; }
chmod +x "$RW"
if grep -q -- '__Z' "$RW"; then
  echo "an unexpanded token is left in $RW:" >&2; grep -n -- '__Z' "$RW" | sed -n '1,5p' >&2; exit 2
fi
# An invariant rather than a per-path tally: every token of pass 1 becomes exactly one fake-root path in
# pass 2, and nothing else may. A per-path count cannot see a MISSED path, and one missed path means the
# probe reads THIS machine while every scenario still passes (docs 98 found exactly that).
TOK=$(cnt '__Z[A-Z]*__' "$P1"); FRS=$(cnt "$FR" "$RW")
[ "$TOK" -gt 0 ] || { echo "pass 1 produced no tokens -- the rewrite matched nothing" >&2; exit 2; }
[ "$TOK" = "$FRS" ] || { echo "$TOK tokens in pass 1 became $FRS fake-root paths in pass 2" >&2; exit 2; }
[ "$(cnt '__ZP__' "$P1")" -gt 0 ] && [ "$(cnt '__ZS__' "$P1")" -gt 0 ] \
  || { echo "pass 1 produced no /proc/ or no /sys/ token -- one of the two rules matched nothing" >&2; exit 2; }
grep -qF "$FR$FR" "$RW" && { echo "a rewrite cascaded: $FR appears twice in a row" >&2; exit 2; }
grep -qF "$FR/proc/$FR" "$RW" && { echo "a rewrite cascaded into the fake root's own proc/" >&2; exit 2; }
# The paths the probe's answers hang on, named -- a rule that silently stopped applying would be invisible
# to the counts above if its occurrences moved into a comment.
for need in "$FR/proc/device-tree/model" "$FR/proc/device-tree/compatible" "$FR/proc/uptime" \
  "$FR/proc/version" "$FR/proc/sys/kernel/random/boot_id" "$FR/sys/bus/spmi/drivers" \
  "$FR/sys/class/timed_output"; do
  grep -qF "$need" "$RW" || { echo "$need is not in the rewritten probe -- it would read this host, or a reading is gone" >&2; exit 2; }
done

# --- the static safety guard, and its teeth --------------------------------------------------------
#
# What counts as a write: a redirect into /sys, /proc or /dev; and dd/tee/setprop/modprobe/insmod/rmmod/
# mount/umount/mkfs **in command position**, where command position means the first word of a statement --
# the start of a line, or just after `;`, `&&`, `||`, `|`, `(`, `then`, `do` or `else`. Requiring a
# statement boundary and not just "after a space" is what keeps the probe's own prose ("the buzzing test is
# a separate step") from being read as code.
#
# Two exemptions, each of which has to be there for the same reason, and each of which is itself asserted:
#   * `>/dev/null` is not a write to the device's filesystem. This port's shell is /bin/sh, where
#     `2>/dev/null` is the only way to be quiet, so those occurrences are stripped before matching.
#   * a HEREDOC BODY IS TEXT. The probe's `--explain` page describes writing a millisecond count into
#     `enable` in a sentence, and blanking the bodies first keeps that prose from being read as code while
#     keeping the line count, so a real hit still reports its own line number.
blank_heredocs() { awk '/<<.?EOF/{s=1} { if (s) print ""; else print $0 } /^EOF$/{s=0}' "$1"; }
strip_nulls() { sed -e 's#[0-9]\{0,\}>[[:space:]]*/dev/null##g' "$1"; }
WRITE_RE='[^-]>[[:space:]]*/(sys|proc|dev)/|(^|[;&|(]|(then|do|else))[[:space:]]*(dd|tee|setprop|modprobe|insmod|rmmod|mkfs(\.ext4)?|mount|umount)([[:space:]]|$)'
write_sites() { strip_nulls "$1" | blank_heredocs /dev/stdin | grep -nE -- "$WRITE_RE"; }

W_SITES=$(write_sites "$SRC")
if [ -z "$W_SITES" ]; then
  ok "the shipped probe contains no write into /sys, /proc or /dev and no state-changing command"
else
  bad "the shipped probe contains what looks like a write:"
  sed 's/^/        | /' <<< "$W_SITES"
fi
# The teeth, and the first one is the write this probe is most plausibly tempted into: making it buzz.
printf '%s\n' '# a fixture for the redirect rule: the buzz test this probe deliberately does not do' \
  'printf 1000 > /sys/class/timed_output/vibrator/enable' > "$W/teeth-buzz.sh"
printf '%s\n' '# a fixture for the command-position rule' \
  'insmod /tmp/qpnp_haptic.ko' > "$W/teeth-cmd.sh"
printf '%s\n' '# prose that must not be read as code' \
  "cat <<'EOF'" \
  'making the phone buzz is a WRITE -- a millisecond count into enable -- and this probe does not write' \
  'EOF' \
  'say "the arrow -> /sys/class/timed_output/vibrator/enable is how this page writes a path"' > "$W/teeth-prose.sh"
want 'vibrator/enable' "$(write_sites "$W/teeth-buzz.sh")" \
  "the guard catches a redirect into the timed_output enable knob (the buzz test, as a fixture)"
want 'qpnp_haptic' "$(write_sites "$W/teeth-cmd.sh")" "and catches a state-changing command in command position"
notwant '.' "$(write_sites "$W/teeth-prose.sh")" \
  "and does not punish prose that names an arrow before a /sys path, or a heredoc about writing enable"
want 'millisecond count into enable' "$(grep -aE -- 'millisecond count into enable' "$W/teeth-prose.sh")" \
  "while the heredoc that says so is present in the fixture (so the exemption is doing work, not hiding a miss)"
printf 'x=$(dmesg 2>/dev/null)\n' > "$W/teeth-null.sh"
want '/dev/null' "$(grep -aE -- "$WRITE_RE" "$W/teeth-null.sh")" \
  "and without the /dev/null strip, the probe's own quiet-redirects WOULD be flagged"
notwant '.' "$(write_sites "$W/teeth-null.sh")" "while with the strip they are not"

# --- the fake device -------------------------------------------------------------------------------
#
# `scen` builds the whole fake root from nothing, so a scenario can never inherit the previous one's
# leftovers -- the trap docs 128 section 9c records. Every file it does not create is ABSENT, which is the
# point: the probe must reach its verdict from what is there, not from what a copy left behind.
#
# Device-tree properties are BYTES: a string list is NUL-terminated, and a u32 is four big-endian bytes.
dtp() { mkdir -p "$(dirname "$1")"; printf '%s\0' "$2" > "$1"; }
dtu32p() { mkdir -p "$(dirname "$1")"; printf "$2" > "$1"; }

# The two boards' root properties, exactly as the flashed blob carries them: IDENTICAL `compatible`, and a
# `model` that is the only thing telling them apart.
MODEL_ZL1='Letv Technologies, Inc. MSM 8996pro + PMI8996 LE_ZL1-DVT1'
MODEL_X2='Letv Technologies, Inc. MSM 8996 v3 + PMI8996 LE_X2-PVT'

# The haptics node's real properties, from a ZL1 DTB: actuator lra, play-mode direct, sine wave, vmax
# 0x00000e74 = 3700 mV. The bytes are written literally, because that is what a device tree holds.
hap_node() { # $1 = node dir, $2 = status, $3 = wave-shape
  dtp "$1/compatible" 'qcom,qpnp-haptic'
  dtp "$1/status" "$2"
  dtp "$1/qcom,actuator-type" 'lra'
  dtp "$1/qcom,play-mode" 'direct'
  dtp "$1/qcom,wave-shape" "$3"
  dtu32p "$1/qcom,vmax-mv" '\000\000\016\164'
  dtu32p "$1/qcom,ilim-ma" '\000\000\001\364'
  dtu32p "$1/qcom,wave-play-rate-us" '\000\000\000\005'
  dtu32p "$1/qcom,wave-rep-cnt" '\000\000\000\001'
  dtu32p "$1/qcom,wave-samp-rep-cnt" '\000\000\000\000'
  : > "$1/qcom,use-play-irq"
}

scen() {
  SCEN="$1"
  rm -rf "$FR"
  mkdir -p "$FR/proc/sys/kernel/random" "$FR/proc/device-tree" "$FR/sys/kernel" \
    "$FR/sys/bus/spmi/drivers" "$FR/sys/class"

  printf '%s\0' "$MODEL_ZL1" > "$FR/proc/device-tree/model"
  printf 'qcom,msm8996-mtp\0qcom,msm8996\0qcom,mtp\0' > "$FR/proc/device-tree/compatible"
  printf '11111111-2222-3333-4444-555555555555\n' > "$FR/proc/sys/kernel/random/boot_id"
  printf '1234.56 5678.90\n' > "$FR/proc/uptime"
  printf 'Linux version 4.4.205 (build) #1 SMP\n' > "$FR/proc/version"

  L="$FR/proc/device-tree/soc/qcom,spmi@400f000/qcom,pmi8994@3"

  # A ZL1 tree declares the PMI8994 haptics node and NO ti,drv2604l node; an X2 tree is the other way round,
  # and its copy of the haptics node is `disabled` with a square wave. That contrast is the whole reason the
  # board reading is a rung, so the fixture contains both.
  case "$SCEN" in
  unknown-model) printf 'Letv Technologies, Inc. LE_UNKNOWN-XYZ\0' > "$FR/proc/device-tree/model" ;;
  no-model) rm -f "$FR/proc/device-tree/model" ;;
  x2-tree)
    printf '%s\0' "$MODEL_X2" > "$FR/proc/device-tree/model"
    hap_node "$L/qcom,haptic@c000" disabled square
    dtp "$FR/proc/device-tree/soc/i2c@75b7000/drv2604l@5a/compatible" 'ti,drv2604l'
    dtp "$FR/proc/device-tree/soc/i2c@75b7000/drv2604l@5a/status" 'ok'
    ;;
  no-dt-node | no-find-no-shape) : ;;
  node-disabled) hap_node "$L/qcom,haptic@c000" disabled sine ;;
  *) hap_node "$L/qcom,haptic@c000" okay sine ;;
  esac

  # The SPMI driver. `qcom,qpnp-haptic` is the vendor kernel's own driver name, comma and all, and the bound
  # device is the symlink inside it -- a directory with nothing attached is its own rung.
  D="$FR/sys/bus/spmi/drivers/qcom,qpnp-haptic"
  case "$SCEN" in
  no-driver-dir) : ;;
  driver-not-bound) mkdir -p "$D"; touch "$D/bind" "$D/unbind" "$D/uevent" ;;
  *)
    mkdir -p "$D/400f000.qcom,spmi:qcom,pmi8994@3:qcom,haptic@c000"
    touch "$D/bind" "$D/unbind" "$D/uevent"
    ;;
  esac

  # The timed_output entry: `enable` is the file a HAL writes, and the attributes are qpnp-haptic.c's own
  # sysfs group -- which is what identifies the owner without guessing.
  case "$SCEN" in
  no-timed-output) : ;;
  timed-output-other-name)
    mkdir -p "$FR/sys/class/timed_output/something-else"
    printf '0\n' > "$FR/sys/class/timed_output/something-else/enable"
    ;;
  *)
    T="$FR/sys/class/timed_output/vibrator"; mkdir -p "$T"
    printf '0\n' > "$T/enable"
    for a in wf_s0 wf_s1 wf_s2 wf_s3 wf_s4 wf_s5 wf_s6 wf_s7 wf_update wf_rep wf_s_rep play_mode \
      dump_regs ramp_test min_max_test; do printf '0\n' > "$T/$a"; done
    ;;
  esac
  # `other-driver-owns-entry`: the entry exists but carries the X2's drv2604l driver's attributes instead of
  # qpnp-haptic's. That is the shape in which "which driver owns this entry" is the reading that decides.
  if [ "$SCEN" = other-driver-owns-entry ]; then
    T="$FR/sys/class/timed_output/vibrator"
    rm -f "$T"/wf_s* "$T/wf_update" "$T/wf_rep" "$T/wf_s_rep" "$T/play_mode" "$T/dump_regs" \
      "$T/ramp_test" "$T/min_max_test"
  fi
  # `driven`: the vibrator is running. A reading, not a rung -- being on must not change the verdict.
  if [ "$SCEN" = driven ]; then printf '1000\n' > "$FR/sys/class/timed_output/vibrator/enable"; fi

  # The kernel log. `unreadable` makes BOTH readers fail -- the only honest way to reach "not read".
  LOGMODE=normal
  case "$SCEN" in log-unreadable) LOGMODE=unreadable ;; esac
  : > "$W/kernel.log"
  case "$SCEN" in
  registered | driven | other-driver-owns-entry)
    { printf '[    0.000000] Booting Linux on physical CPU 0x0\n'
      printf '[    1.100000] qcom,qpnp-haptic: qpnp_haptic_probe: probed, LRA, sine wave\n'
      printf '[   30.000000] random: crng init done\n'; } > "$W/kernel.log"
    ;;
  log-failing)
    { printf '[    0.000000] Booting Linux on physical CPU 0x0\n'
      printf '[    1.100000] qcom,qpnp-haptic: Unable to read vmax\n'
      printf '[    1.100100] qcom,qpnp-haptic: DT parsing failed\n'
      printf '[   30.000000] random: crng init done\n'; } > "$W/kernel.log"
    ;;
  log-quiet)
    { printf '[    0.000000] Booting Linux on physical CPU 0x0\n'
      printf '[   30.000000] random: crng init done\n'; } > "$W/kernel.log"
    ;;
  esac
  cat > "$STUB/dmesg" <<'STUBEOF'
#!/bin/sh
[ "${LOGMODE:-normal}" = unreadable ] && exit 1
cat "$LOGFILE"
STUBEOF
  cat > "$STUB/journalctl" <<'STUBEOF'
#!/bin/sh
[ "${LOGMODE:-normal}" = unreadable ] && exit 1
cat "$LOGFILE"
STUBEOF
  chmod +x "$STUB/dmesg" "$STUB/journalctl"
  export LOGMODE LOGFILE="$W/kernel.log"
}

# `run` executes the rewritten probe as the fake device sees it. PATH is the sandbox FIRST, so a tool the
# probe needs and the sandbox lacks fails loudly instead of silently reaching this laptop's copy.
run() { ( cd "$W" && PATH="$STUB:$MINBIN" "$SH_BIN" "$RW" "$@" ) 2>&1; }
# The same, on a device that has no find(1): the only way to reach "the tree could not be searched".
run_nofind() { ( cd "$W" && PATH="$STUB:$MINBIN_NOFIND" "$SH_BIN" "$RW" "$@" ) 2>&1; }
# The same again, for a MUTATED copy of the subject: rewritten the same way, run against the scenario that
# was built last. $3 = nofind to run it on the sandbox without find(1).
mut_run() { # $1 = mutated source, $3 = nofind
  rewrite "$1" "$W/mutated.sh"
  sh -n "$W/mutated.sh" || { printf 'MUTATED SUBJECT DOES NOT PARSE\n'; return; }
  if [ "${3:-}" = nofind ]; then
    ( cd "$W" && PATH="$STUB:$MINBIN_NOFIND" "$SH_BIN" "$W/mutated.sh" ) 2>&1
  else
    ( cd "$W" && PATH="$STUB:$MINBIN" "$SH_BIN" "$W/mutated.sh" ) 2>&1
  fi
}

# ==================================================================================================
echo "== 1. the rewrite, the safety scan, and the guard's teeth =="
# ==================================================================================================
scen registered
nonempty "the rewritten probe has content" "$(cat "$RW")"
OUT=$(run --help)
want '^# zl1 vibrator probe' "$OUT" "--help prints the probe's own header"
want 'it is a separate step, and it needs its own review' "$(run --explain)" "--explain says the buzz is a write and a separate step, so it is not a side effect of a reading"
if ( run --help >/dev/null ); then ok "--help exits 0"; else bad "--help did not exit 0"; fi

# ==================================================================================================
echo "== 2. the board reading, which comes first =="
# ==================================================================================================
scen registered
OUT=$(run)
want 'model: +Letv Technologies, Inc. MSM 8996pro' "$OUT" "a zl1 tree is named by its model"
want 'board: +LE_ZL1 -- this phone' "$OUT" "and read as this phone"
want 'also present: no ti,drv2604l node' "$OUT" \
  "with the other board's vibrator node reported absent by name, rather than left as a silence"

scen x2-tree
OUT=$(run); RC=$?
want '== verdict: wrong-board-tree' "$OUT" "the X2's device tree is its own rung, checked before any hardware"
want 'board: +LE_X2 -- NOT this phone' "$OUT" "and it says which board it is looking at"
want 'the bootloader picked the other phone' "$OUT" "naming the cause rather than the symptom"
want "msm8996., which both trees carry byte for byte" "$OUT" \
  "and stating why the sibling probes' guard cannot see this: the identical root compatible"
want 'also present:.*drv2604l' "$OUT" "with the other board's vibrator node reported, since it is present here"
want 'the LE_X2.s vibrator, not this phone' "$OUT" "and labelled as the other board's, not this one's"
want 'status: +disabled' "$OUT" "and this block's own status on that tree is printed"
[ "$RC" = 1 ] && ok "and exits 1" || bad "the wrong-board verdict exited $RC, not 1"

scen unknown-model
OUT=$(run)
want '== verdict: unknown-board' "$OUT" "a model that names neither board is not attributed to this phone"
want 'board: +neither LE_ZL1 nor LE_X2' "$OUT" "and is reported as neither rather than assumed to be a zl1"
want 'cannot be attributed to this phone' "$OUT" "with the verdict saying the attribution is what is missing"

scen no-model
OUT=$(run)
want '== verdict: unknown-board' "$OUT" "an unreadable model reaches the same rung, not a crash"
want 'board: +UNKNOWN' "$OUT" "and is named as unreadable rather than as neither"
want 'could not be read' "$OUT" "with the reason given"

# ==================================================================================================
echo "== 3. every hardware rung, one scenario each =="
# ==================================================================================================
scen no-dt-node
OUT=$(run); RC=$?
want '== verdict: no-device-tree-node' "$OUT" "a tree with no qcom,qpnp-haptic node says so"
want 'declares no PMI8994 haptics peripheral' "$OUT" "naming what is missing"
want 'all three device-tree sets' "$OUT" \
  "and stating that this is NOT a which-image-booted question, unlike the LEDs' own rung"
want 'scanned for the compatible' "$OUT" "with the scan named, so the reading does not rest on a guessed path"
[ "$RC" = 1 ] && ok "and exits 1" || bad "the no-node verdict exited $RC, not 1"

scen node-disabled
OUT=$(run); RC=$?
want '== verdict: node-disabled' "$OUT" "a declared node with status != okay is its own rung"
want 'its status is .disabled.' "$OUT" "quoting the status it read"
want "the LE_X2.s copy of this block" "$OUT" "and pointing at the board question before the driver question"
[ "$RC" = 1 ] && ok "and exits 1" || bad "node-disabled exited $RC, not 1"

scen driver-not-bound
OUT=$(run); RC=$?
want '== verdict: driver-not-bound' "$OUT" "a driver directory with nothing attached is its own rung"
want 'bound devices: NONE' "$OUT" "printed as NONE rather than as a blank"
want 'name the property it could not read' "$OUT" "and the verdict sends the reader to the log for the reason"
[ "$RC" = 1 ] && ok "and exits 1" || bad "driver-not-bound exited $RC, not 1"

scen no-driver-dir
OUT=$(run); RC=$?
want '== verdict: driver-not-bound' "$OUT" "a driver that never registered reaches the same rung"
want 'MISSING -- the driver did not register' "$OUT" "with the directory's absence stated, which is not the same as empty"
want 'CONFIG_QPNP_HAPTIC=y' "$OUT" "and the defconfig cited, so 'missing' is not read as 'not built in'"
[ "$RC" = 1 ] && ok "and exits 1" || bad "no-driver-dir exited $RC, not 1"

scen no-timed-output
OUT=$(run); RC=$?
want '== verdict: no-timed-output' "$OUT" "a bound driver with no timed_output entry is its own rung"
want 'timed_output registration failed' "$OUT" "and the verdict quotes the driver's own error string for it"
[ "$RC" = 1 ] && ok "and exits 1" || bad "no-timed-output exited $RC, not 1"

scen timed-output-other-name
OUT=$(run); RC=$?
want '== verdict: no-timed-output' "$OUT" "an entry under a DIFFERENT name does not count"
want 'found:.*something-else' "$OUT" "and the name that IS there is printed, so the reader can see it"
[ "$RC" = 1 ] && ok "and exits 1" || bad "the other-name scenario exited $RC, not 1"

scen registered
OUT=$(run); RC=$?
want '== verdict: registered' "$OUT" "node okay, driver bound and the entry present is the healthy rung"
[ "$RC" = 0 ] && ok "and exits 0" || bad "the healthy verdict exited $RC, not 0"

# ==================================================================================================
echo "== 4. a node that could not be SEARCHED is not a node that is absent =="
# ==================================================================================================
scen no-find-no-shape
OUT=$(run_nofind); RC=$?
want '== verdict: tree-unscanned' "$OUT" "with no find(1) and no known node shape, the probe says it could not look"
want 'could not be searched for a compatible at all' "$OUT" "in those words"
want "NOT 'there is no haptics node'" "$OUT" "and says explicitly that this is not an absence"
notwant 'no-device-tree-node' "$OUT" "so it never reports the absence rung it cannot support"
[ "$RC" = 1 ] && ok "and exits 1" || bad "tree-unscanned exited $RC, not 1"
scen registered
OUT=$(run_nofind); RC=$?
want '== verdict: registered' "$OUT" \
  "while the same probe WITH the node present but no find(1) still finds it through the fallback globs"
want 'node: +/soc/qcom,spmi@400f000/qcom,pmi8994@3/qcom,haptic@c000' "$OUT" "and prints the node it found"
[ "$RC" = 0 ] && ok "and exits 0" || bad "the no-find-but-node-present scenario exited $RC, not 0"

# ==================================================================================================
echo "== 5. a device-tree u32 is BIG-ENDIAN, and a wrong length is not a number =="
# ==================================================================================================
scen registered
OUT=$(run)
want 'vmax-mv: +3700' "$OUT" "a 4-byte big-endian property is read as its value, not byte-swapped"
want 'ilim-ma: +500' "$OUT" "and so is a second one"
notwant '740e0000' "$OUT" "with the byte-swapped form nowhere in the report"
# The failure mode of a length change is a plausible number, so the fixture makes the property 3 bytes and
# the probe must say so instead of reading three bytes as if they were four.
scen registered
printf '\000\016\164' > "$FR/proc/device-tree/soc/qcom,spmi@400f000/qcom,pmi8994@3/qcom,haptic@c000/qcom,vmax-mv"
OUT=$(run)
want 'vmax-mv: +not-a-u32.3 bytes.' "$OUT" "a property that is not four bytes says so rather than printing a number"
notwant 'vmax-mv: +[0-9]' "$OUT" "and prints no number at all for it"

# ==================================================================================================
echo "== 6. the entry, the attributes that identify its owner, and the driven reading =="
# ==================================================================================================
scen registered
OUT=$(run)
want 'entries: vibrator' "$OUT" "the timed_output entry is listed by name"
want 'vibrator +enable=0' "$OUT" "with its enable value, which is what a HAL writes"
want 'attrs:.*wf_s0' "$OUT" "and qpnp-haptic.c's own attributes"
want 'attrs:.*wf_update' "$OUT" "including the group's second half"
notwant 'attrs: +none .not qpnp-haptic' "$OUT" \
  "so the group is RECOGNISED -- an attribute list that had drifted would print 'none' here"
scen other-driver-owns-entry
OUT=$(run); RC=$?
want 'attrs: +none .not qpnp-haptic.s group.' "$OUT" \
  "an entry owned by the other board's driver is reported as NOT this driver's, by its attributes"
want '== verdict: registered' "$OUT" "and the verdict is about the entry's existence, which is what it read"
[ "$RC" = 0 ] && ok "and exits 0" || bad "the other-driver scenario exited $RC, not 0"
scen driven
OUT=$(run); RC=$?
want 'vibrator +enable=1000' "$OUT" "a vibrator that IS running is reported with its value"
want '== verdict: registered' "$OUT" "and the verdict is unchanged: being on is a reading, not a rung"
[ "$RC" = 0 ] && ok "and still exits 0" || bad "the driven scenario exited $RC, not 0"

# ==================================================================================================
echo "== 7. an unreadable log is not a rung, and a readable one is filtered =="
# ==================================================================================================
scen log-unreadable
OUT=$(run); RC=$?
want 'the kernel log could not be read' "$OUT" "an unreadable kernel log says so"
want 'so this section is NOT READ' "$OUT" "and is named as not read rather than printed empty"
want 'every reading this probe decides' "$OUT" "and says why it is not a rung here"
want '== verdict: registered' "$OUT" "with the verdict unchanged -- no reading here comes from the log"
[ "$RC" = 0 ] && ok "and exits 0" || bad "the unreadable-log scenario exited $RC, not 0"

scen log-failing
OUT=$(run)
want 'Unable to read vmax' "$OUT" "a driver that could not read a property is surfaced from the log"
want 'DT parsing failed' "$OUT" "and a probe that gave up on the device tree"
scen log-quiet
OUT=$(run)
want 'the kernel log mentions no haptics driver this boot' "$OUT" "a readable log with no haptics lines prints its named (none: ...) line"
want 'no haptics probe failure' "$OUT" "and the failure block prints its own named (none: ...) line"
scen log-unreadable
want 'not read: the kernel log could not be read' "$(run)" "while an unreadable log prints a named absence instead of a blank"

# ==================================================================================================
echo "== 8. --quiet, and the exit-code contract =="
# ==================================================================================================
scen registered
Q=$(run --quiet); F=$(run)
want '== verdict: registered' "$Q" "--quiet still prints the verdict (a verdict is not a reading)"
want 'boot id:' "$Q" "--quiet still prints which boot this is (a verdict with no boot identity is not attributable)"
want 'model:' "$Q" "--quiet still prints which board's tree this is (the first rung survives --quiet)"
want 'entries: vibrator' "$Q" "--quiet keeps the reading the verdict qualifies"
notwant 'compatible:' "$Q" "--quiet drops the device-tree detail"
want 'compatible:' "$F" "and the full run has it"
notwant 'attrs:' "$Q" "--quiet drops the per-entry attribute listing"
want 'attrs:' "$F" "which the full run keeps"
scen no-timed-output
Q=$(run --quiet)
want '== verdict: no-timed-output' "$Q" "--quiet prints a failing verdict too"
want 'vibrator HAL needs' "$Q" "and keeps the explanation the verdict rests on, which --quiet must not delete"
OUT=$(run --bogus); RC=$?
want 'unknown argument' "$OUT" "an unknown argument is refused by name"
[ "$RC" = 2 ] && ok "and exits 2, so a typo cannot be read as a reading" || bad "an unknown argument exited $RC, not 2"

# ==================================================================================================
echo "== 9. the shipped probe is still write-free, and the mutation proves the guard has teeth =="
# ==================================================================================================
notwant '>[[:space:]]*/tmp/' "$(cat "$SRC")" "the shipped probe writes no scratch file in /tmp either"
notwant '\bmktemp\b' "$(cat "$SRC")" "and creates no temporary file at all"
want 'LOG_TEXT=\$\(dmesg' "$(cat "$SRC")" "the kernel log is captured into a variable (the write-free way to read it twice)"
# The mutation: the buzz test, which is precisely the write a probe about haptics would be tempted into.
sed 's#^    EN=\$(rd "\$d/enable")#    printf 1000 > /sys/class/timed_output/vibrator/enable#' "$SRC" > "$W/mut-write.sh"
if cmp -s "$SRC" "$W/mut-write.sh"; then
  bad "the mutation did not apply -- the seed line it edits is gone, so this check would test nothing"
else
  ok "the mutation applied to the shipped source"
  want 'vibrator/enable' "$(write_sites "$W/mut-write.sh")" \
    "and a mutation that makes the phone buzz is caught by the guard"
fi

# ==================================================================================================
echo "== 10. the mutations that are readings, not writes =="
# ==================================================================================================
# Each of these is a way the probe could still LOOK right, and each must redden a check: a mutation that
# reddens nothing means the scenario it edits is not being tested. The scenario is rebuilt before the
# mutated subject runs, so the two subjects see the same device.
# 1. The board guard: test the root `compatible` -- which BOTH trees carry -- instead of `model`. This is
#    not hypothetical: it is the guard its ~25 siblings use today.
sed -e 's#^case "\$MODEL" in#case "$MODEL$COMPAT" in#' \
  -e 's#^\*LE_ZL1\*) BOARD=zl1 ;;#*LE_ZL1*|*qcom,msm8996*) BOARD=zl1 ;;#' "$SRC" > "$W/mut-board.sh"
if cmp -s "$SRC" "$W/mut-board.sh"; then bad "the board mutation did not apply"; else
  scen x2-tree
  OUT=$(mut_run "$W/mut-board.sh")
  notwant '== verdict: wrong-board-tree' "$OUT" \
    "a guard that tests msm8996 instead of model stops seeing the other board's tree (the mutation)"
  want '== verdict: node-disabled' "$OUT" "and lands on a hardware rung instead, which is the whole failure mode"
fi
# 2. The status check dropped: a node the kernel will not probe would report as a driver problem.
sed 's#^elif \[ -n "\$HAP" \] && \[ "\$ST" != okay \] && \[ "\$ST" != ok \]; then#elif [ -n "$HAP" ] \&\& false; then#' \
  "$SRC" > "$W/mut-status.sh"
if cmp -s "$SRC" "$W/mut-status.sh"; then bad "the status mutation did not apply"; else
  scen node-disabled
  OUT=$(mut_run "$W/mut-status.sh")
  notwant '== verdict: node-disabled' "$OUT" "dropping the status check stops the disabled node being a rung (the mutation)"
fi
# 3. An empty `bound devices` read as fine: a driver directory with nothing attached would pass.
sed 's#^elif \[ -z "\$DRV_BOUND" \]; then#elif false; then#' "$SRC" > "$W/mut-bound.sh"
if cmp -s "$SRC" "$W/mut-bound.sh"; then bad "the bound-device mutation did not apply"; else
  scen driver-not-bound
  OUT=$(mut_run "$W/mut-bound.sh")
  notwant '== verdict: driver-not-bound' "$OUT" \
    "treating an unattached driver as fine stops the rung that says nothing was probed (the mutation)"
fi
# 4. "Could not search" collapsed into "not found": the state that must never print like an absence.
sed 's#^  \[ "\$_nw_any" = 1 \] && return 1#  return 1#' "$SRC" > "$W/mut-scan.sh"
if cmp -s "$SRC" "$W/mut-scan.sh"; then bad "the scan mutation did not apply"; else
  scen no-find-no-shape
  OUT=$(mut_run "$W/mut-scan.sh" nofind)
  notwant '== verdict: tree-unscanned' "$OUT" "collapsing could-not-search into not-found loses that state (the mutation)"
  want '== verdict: no-device-tree-node' "$OUT" "and prints an absence the probe cannot support"
fi
# 5. The byte order: `od -tu4` on a little-endian host, which is the mistake that looks like a reading.
sed 's#_u_a \* 16777216 + _u_b \* 65536 + _u_c \* 256 + _u_d#_u_d * 16777216 + _u_c * 65536 + _u_b * 256 + _u_a#' \
  "$SRC" > "$W/mut-endian.sh"
if cmp -s "$SRC" "$W/mut-endian.sh"; then bad "the endianness mutation did not apply"; else
  scen registered
  OUT=$(mut_run "$W/mut-endian.sh")
  notwant 'vmax-mv: +3700' "$OUT" "combining the four bytes in the host's order loses the real value (the mutation)"
  want 'vmax-mv: +1947[0-9]*' "$OUT" "and prints a number of the right SHAPE and the wrong value"
fi
# 6. The other board's node note dropped: the reading that says WHICH TREE this is.
sed "s#^  say \"     -- this is the LE_X2's vibrator#  : \"     -- this is the LE_X2's vibrator#" \
  "$SRC" > "$W/mut-note.sh"
if cmp -s "$SRC" "$W/mut-note.sh"; then bad "the note mutation did not apply"; else
  scen x2-tree
  OUT=$(mut_run "$W/mut-note.sh")
  notwant 'the LE_X2.s vibrator, not this phone' "$OUT" \
    "silencing the other board's node removes the reading that says which tree this is (the mutation)"
  want '== verdict: wrong-board-tree' "$OUT" "while the board rung itself still stands on the model"
fi

# ==================================================================================================
echo "== 11. this harness's own citation =="
# ==================================================================================================
# A count typed by hand in the first thing a human reads goes stale the moment this file grows, so this
# harness reads its own citation out of the health check and compares it with what it just ran.
HEALTH="$HERE/zl1-health-check.sh"
if [ -r "$HEALTH" ]; then
  cited=$(sed -e 's/always "/ /g' -e 's/"$//' "$HEALTH" | tr '\n' ' ' |
            sed -n 's/.*zl1-vibrator-probe-selftest.sh[ ,(]*\([0-9][0-9]*\) checks.*/\1/p')
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
if [ "$KEEP" = 1 ]; then echo "kept: $W"; else rm -rf "$W"; fi
[ "$FAIL" = 0 ]
