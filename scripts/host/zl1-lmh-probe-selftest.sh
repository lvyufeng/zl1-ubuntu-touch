#!/usr/bin/env bash
# zl1 LMH probe -- offline self-test. Host-side, touches no device, needs no phone.
#
# Why this exists. `scripts/device/zl1-lmh-probe.sh` is the first instrument for the SoC's hardware
# thermal limiter, which doc 137 found was read by nothing -- on a phone whose user asks for the
# overheating to be fixed. It is also the instrument with the most ways to be quietly wrong, because the
# driver's own failure paths are ASYMMETRIC: the sensor path is fatal, the profile path only warns, and
# the debug path fails silently under pr_debug. So "no node under /sys/kernel/debug" has three possible
# causes, and a probe that reported one of them would send the next reader to the wrong layer. The harness
# holds the probe to four things:
#
#   1. IT WRITES NOTHING, checked statically AND with teeth. The limiter's knobs are writable (`level` is
#      0600) and the block sits next to the secure world, so a probe that "just set the level" would be a
#      write to a thermal policy on a device that has already been to EDL. The guard refuses a redirect
#      into /sys, /proc or /dev and a state-changing command in command position; a mutation that puts ONE
#      such write back must make the guard fail, and the probe's own prose must not.
#   2. A READING THAT COULD NOT BE TAKEN IS NOT A NEGATIVE ONE. An unreadable kernel log must give
#      `bound-log-unreadable`, never a sensor count of zero; an unmounted debugfs must be printed as the
#      reason a monitor node is missing, never as "the driver did not create it".
#   3. THE VERDICT NAMES THE RUNG, and every rung has a scenario: no device-tree node, no driver, driver
#      unbound, bound with no sensors, bound with no profile, bound without the monitor path, and the
#      healthy one. Each is a different next move, so each is asserted by name AND by exit code.
#   4. THE "(none)" LINES ACTUALLY PRINT. `grep PAT F | tail | sed || say none` never reaches its
#      none-branch -- in a pipeline the status is the LAST command's and `sed` succeeds on empty input --
#      so a pattern that matched nothing would print nothing at all. That was a live defect in two sites
#      of the modem probe (docs 120 section 5); here the equivalent sites are asserted one by one.
#
# How it works: **the stub directory IS the device.** The probe runs as itself against a fake root, with
# the device's tools stubbed and PATH sandboxed to `$STUB:$MINBIN`, where MINBIN holds symlinks to the
# real coreutils. The sandbox matters here for the same reason it did for the modem probe: this host is
# not the device, and a probe that fell through to a real path would read THIS laptop's /proc and report
# it as the phone's.
#
# Usage: zl1-lmh-probe-selftest.sh [--keep]
#   --keep   leave the fake device, the stubs and the rewritten probe for inspection
#
# `ZL1_LMH_PROBE_SRC=/path` runs the whole thing against another copy of the subject, which is how a
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
SRC="${ZL1_LMH_PROBE_SRC:-$HERE/../device/zl1-lmh-probe.sh}"
[ -r "$SRC" ] || { echo "cannot read the subject: $SRC" >&2; exit 2; }

W="${TMPDIR:-/tmp}/zl1-lmh-probe-selftest"
# `root`, not `dev`: the fake root's path must not itself contain a path the rewriter hunts for, or the
# replacement text gets rewritten in turn. With the root under `$W/dev`, the `/proc/` rewrite produced
# `$W/dev/proc/...` and a later `/dev/` rule hit the `dev` in the middle of it (docs 120).
FR="$W/root"
STUB="$W/stub"
MINBIN="$W/minbin"
rm -rf "$W"
mkdir -p "$STUB" "$MINBIN" || exit 2

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
want() { if grep -Eq -- "$1" <<< "$2"; then ok "$3"; else bad "$3"; sed 's/^/        | /' <<< "$2"; fi; }
notwant() { if grep -Eq -- "$1" <<< "$2"; then bad "$3"; grep -E -- "$1" <<< "$2" | sed 's/^/        | /'; else ok "$3"; fi; }
# A check that passes for free on an empty string is not a check.
nonempty() { if [ -n "$2" ]; then ok "$1"; else bad "$1 -- the output was empty, so nothing below it can be trusted"; fi; }
# Ordering, for the one reading whose MEANING is its position: the debugfs mount state has to come before
# the monitor node, or a reader cannot tell "not mounted" from "the driver did not create it".
before() { # $1 = earlier ERE, $2 = later ERE, $3 = text, $4 = label
  # `sed -n 1p`, not `head -1`: under `set -o pipefail` a reader that exits after one line makes the
  # WRITER's death (SIGPIPE, 141) the pipeline's status, and this harness's own meta-check forbids the
  # shape (section 7b of zl1-selftest-family-selftest.sh). It is asserted there, and it caught this file.
  a=$(grep -nE -- "$1" <<< "$3" | sed -n 1p | cut -d: -f1)
  b=$(grep -nE -- "$2" <<< "$3" | sed -n 1p | cut -d: -f1)
  if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then ok "$4"
  else bad "$4 (first matched line $a, second $b)"; fi
}

# --- the sandbox PATH ------------------------------------------------------------------------------
# The tools the probe's own shell code invokes for real. `type -P`, not `command -v`: in a shell whose
# profile has made one of these a function, `command -v` prints the NAME rather than a path and the
# symlink would point at itself.
for t in awk basename cat cut head od sed sort tail tr uniq wc grep; do
  p="$(type -P "$t" 2>/dev/null)" || continue
  [ -n "$p" ] && ln -sf "$p" "$MINBIN/$t"
done
for t in awk grep head sed tail tr cut; do
  [ -x "$MINBIN/$t" ] || { echo "the sandbox bin is missing $t -- cannot run the probe honestly" >&2; exit 2; }
done
SH_BIN="$(type -P sh 2>/dev/null)"; [ -n "$SH_BIN" ] || SH_BIN=/bin/sh
[ -x "$SH_BIN" ] || { echo "no /bin/sh to run the probe with" >&2; exit 2; }

# --- the subject, rewritten into the fake device ---------------------------------------------------
#
# TWO PASSES, because a one-pass rewrite cascades: `/proc/sys/kernel/osrelease` has its `/proc/` replaced
# and then has the `/sys/` inside `proc/sys` replaced too, giving a path that cannot exist while every
# scenario still "passes". Pass 1 turns each device root into a TOKEN that cannot itself be a device path;
# pass 2 expands the tokens. Nothing in a replacement text can be re-matched by a rule that already ran.
#
# The token carries the trailing slash, so `__ZP__sys/kernel/...` has no `/sys/` left in it and the two
# rules do not depend on their order -- which is the difference between this and trusting the order.
#
# The two rules are applied in two FILES as well as two passes, so each can be counted where it ran:
# `/proc/sys/kernel/random/boot_id` contains a `/sys/`, so counting `/sys/` in the source and comparing it
# with the final token count is wrong by exactly the paths that cross the two roots -- which is the check
# that caught this harness the first time it ran. So each stage is counted against its own input, and each
# is asserted to have left NOTHING of its root behind.
A1="$W/pass1a.sh"; P1="$W/pass1.sh"; RW="$W/lmh-probe.sh"
sed -e 's#/proc/#__ZP__#g' "$SRC" > "$A1"
[ "$(grep -o -- '/proc/' "$SRC" | wc -l | tr -d ' ')" = "$(grep -o -- '__ZP__' "$A1" | wc -l | tr -d ' ')" ] \
  || { echo "the /proc/ rewrite did not cover every /proc/ in the source" >&2; exit 2; }
[ "$(grep -o -- '/proc/' "$A1" | wc -l | tr -d ' ')" = 0 ] \
  || { echo "a /proc/ survived pass 1 -- the probe would read this host" >&2; exit 2; }
sed -e 's#/sys/#__ZS__#g' "$A1" > "$P1"
[ "$(grep -o -- '/sys/' "$A1" | wc -l | tr -d ' ')" = "$(grep -o -- '__ZS__' "$P1" | wc -l | tr -d ' ')" ] \
  || { echo "the /sys/ rewrite did not cover every /sys/ in $A1" >&2; exit 2; }
[ "$(grep -o -- '/sys/' "$P1" | wc -l | tr -d ' ')" = 0 ] \
  || { echo "a /sys/ survived pass 1 -- the probe would read this host" >&2; exit 2; }
sed -e "s#__ZP__#$FR/proc/#g" -e "s#__ZS__#$FR/sys/#g" "$P1" > "$RW"
sh -n "$RW" || { echo "the rewritten probe does not parse" >&2; exit 2; }
chmod +x "$RW"

cnt() { grep -o -- "$1" "$2" 2>/dev/null | wc -l | tr -d ' '; }
if grep -q -- '__Z' "$RW"; then
  echo "an unexpanded token is left in $RW:" >&2; grep -n -- '__Z' "$RW" | sed -n '1,5p' >&2; exit 2
fi
# An invariant rather than a per-path tally: every token of pass 1 becomes exactly one fake-root path in
# pass 2, and nothing else may. A per-path count cannot see a MISSED path, and one missed path means the
# probe reads THIS machine while every scenario still passes (docs 98 found exactly that).
TOK=$(cnt '__Z[A-Z]*__' "$P1"); FRS=$(cnt "$FR" "$RW")
[ "$TOK" -gt 0 ] || { echo "pass 1 produced no tokens -- the rewrite matched nothing" >&2; exit 2; }
[ "$TOK" = "$FRS" ] || { echo "$TOK tokens in pass 1 became $FRS fake-root paths in pass 2" >&2; exit 2; }
# A token expanded by the wrong rule would still satisfy the count, so the two kinds are counted too.
[ "$(cnt '__ZP__' "$P1")" -gt 0 ] && [ "$(cnt '__ZS__' "$P1")" -gt 0 ] \
  || { echo "pass 1 produced no /proc/ or no /sys/ token -- one of the two rules matched nothing" >&2; exit 2; }
grep -qF "$FR$FR" "$RW" && { echo "a rewrite cascaded: $FR appears twice in a row" >&2; exit 2; }
grep -qF "$FR/proc/$FR" "$RW" && { echo "a rewrite cascaded into the fake root's own proc/" >&2; exit 2; }
# The paths the probe's answers hang on, named -- a rule that silently stopped applying would be invisible
# to the counts above if its occurrences moved into a comment.
for need in "$FR/proc/device-tree/compatible" "$FR/proc/uptime" "$FR/proc/mounts" "$FR/proc/interrupts" \
  "$FR/proc/version" "$FR/proc/sys/kernel/random/boot_id" "$FR/sys/bus/platform/drivers" \
  "$FR/sys/module/lmh_lite" "$FR/sys/class/msm_limits" "$FR/sys/kernel/debug"; do
  grep -qF "$need" "$RW" || { echo "$need is not in the rewritten probe -- it would read this host, or a reading is gone" >&2; exit 2; }
done

# --- the static safety guard, and its teeth --------------------------------------------------------
#
# What counts as a write: a redirect into /sys, /proc or /dev; and dd/tee/setprop/modprobe/insmod/rmmod/
# mount/umount/mkfs **in command position**, where command position means the first word of a statement --
# the start of a line, or just after `;`, `&&`, `||`, `|`, `(`, `then`, `do` or `else`.
#
# Requiring a STATEMENT BOUNDARY and not just "preceded by a space" is not cosmetic: the probe's own
# verdict text contains "Check the debugfs mount line above", and the first draft of this rule flagged that
# sentence. A guard that trips on a sentence is a guard somebody deletes the first time it wastes their
# afternoon, so the rule was tightened until the probe's prose passed it -- and the tightening is itself
# asserted below rather than assumed.
#
# Two exemptions, each of which has to be there for the same reason, and each of which is itself asserted:
#   * `>/dev/null` is not a write to the device's filesystem. This port's shell is /bin/sh, where
#     `2>/dev/null` is the only way to be quiet, so those occurrences are stripped before matching rather
#     than special-cased inside the pattern.
#   * a HEREDOC BODY IS TEXT. The probe's `--explain` page says "the mount state is read first, then mount
#     the debugfs" in a sentence, and `then mount` IS command position by the rule above. The bodies are
#     blanked first, keeping the line count so a real hit still reports its own line number.
#
# What is left is a heuristic with one known blind spot, stated rather than hidden: a command word that is
# neither at the start of a line nor after a statement boundary -- `x=1 mount /sys/y` -- is missed. That
# form appears nowhere in this tree; catching it would mean matching `mount` after any space, which is what
# made the guard flag the sentence above.
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

# The teeth. A guard that cannot fail is the defect this tree keeps recording, so a mutation that puts ONE
# write back must redden it -- and the prose fixture must NOT, or the guard would be weakened on the first
# false positive. Three fixtures, each aimed at one rule.
printf '%s\n' '# a fixture for the redirect rule' \
  'echo 0 > /sys/class/msm_limits/lmh-profile/level' > "$W/teeth-write.sh"
printf '%s\n' '# a fixture for the command-position rule' \
  'mount -t debugfs none /sys/kernel/debug' > "$W/teeth-cmd.sh"
printf '%s\n' '# a fixture whose PROSE must not be read as code' \
  "cat <<'EOF'" \
  'read the mount state first, then mount the debugfs to see the node' \
  'EOF' \
  'say "the arrow -> /sys/kernel/debug/lmh_monitor is how this page writes a path"' > "$W/teeth-prose.sh"
# The exact shape of the false positive the first draft had: the probe's own verdict text, where `mount` is
# a noun in a sentence rather than the first word of a statement.
printf '%s\n' 'VMSG="the profile is readable; Check the debugfs mount line above before blaming the driver."' \
  > "$W/teeth-noun.sh"

want 'msm_limits/lmh-profile/level' "$(write_sites "$W/teeth-write.sh")" \
  "the guard catches a redirect into a limiter knob (a fixture, so the guard is not a rubber stamp)"
want 'debugfs' "$(write_sites "$W/teeth-cmd.sh")" \
  "and catches a state-changing command in command position"
notwant '.' "$(write_sites "$W/teeth-prose.sh")" \
  "and does not punish prose that names an arrow before a /sys path, or mounting in a sentence"
notwant '.' "$(write_sites "$W/teeth-noun.sh")" \
  "and does not flag 'mount' as a noun mid-sentence, which is the false positive the first draft had"
want 'mount' "$(grep -aE -- '[[:space:]]mount[[:space:]]' "$W/teeth-noun.sh")" \
  "while a rule matching 'mount' after any space WOULD have flagged it (so the tightening is load-bearing)"
# Both exemptions are load-bearing, so each is shown to be doing work: the heredoc sentence IS command
# position without the blanking, and `2>/dev/null` IS a redirect into /dev without the strip.
want 'then mount the' "$(grep -aE -- "$WRITE_RE" "$W/teeth-prose.sh")" \
  "without the heredoc blanking that fixture's sentence WOULD be flagged (so the exemption is load-bearing)"
notwant 'then mount the' "$(blank_heredocs "$W/teeth-prose.sh")" "and blanking removes the body without changing the line count"
want 'the arrow -> /sys' "$(blank_heredocs "$W/teeth-prose.sh")" "while the line outside the heredoc is kept"
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
# The device-tree property files hold BYTES, not text (which is why the probe renders them with od), so
# the fixture writes raw bytes rather than numbers-as-strings.
dt_prop() { mkdir -p "$(dirname "$1")"; printf "$2" > "$1"; }

#  driver registered    every scenario except not-zl1 and no-driver
#  device bound         every scenario except not-zl1, no-driver, no-dt-node and unbound
#  profile present      the ones listed in its case below   (lmh_device_init, non-fatal if absent)
#  monitor present      the ones listed in its case below   (lmh_debug_init, non-fatal and quiet if absent)
#  debugfs mounted      every scenario except unmounted-debugfs (no scenario has the monitor without it)
#  kernel log           per scenario: the sensor lines, the SCM refusal, or unreadable
scen() {
  SCEN="$1"
  rm -rf "$FR"
  mkdir -p "$FR/proc/device-tree" "$FR/proc/sys/kernel/random" "$FR/sys/class" \
    "$FR/sys/bus/platform/drivers" "$FR/sys/kernel"

  printf 'qcom,msm8996-mtp\0qcom,msm8996\0qcom,mtp\0' > "$FR/proc/device-tree/compatible"
  [ "$SCEN" = not-zl1 ] && printf 'qcom,sdm845\0' > "$FR/proc/device-tree/compatible"
  if [ "$SCEN" != not-zl1 ] && [ "$SCEN" != no-dt-node ]; then
    dt_prop "$FR/proc/device-tree/soc/qcom,lmh/compatible" 'qcom,lmh_v1\0'
    dt_prop "$FR/proc/device-tree/soc/qcom,lmh/interrupts" '\x00\x00\x00\x17\x00\x00\x00\x04'
    dt_prop "$FR/proc/device-tree/soc/qcom,lmh/vdd-apss-supply" '\x00\x00\x01\xc4'
    dt_prop "$FR/proc/device-tree/soc/qcom,lmh/qcom,lmh-odcm-disable-threshold-mA" '\x00\x00\x03\x52'
  fi

  printf '11111111-2222-3333-4444-555555555555\n' > "$FR/proc/sys/kernel/random/boot_id"
  printf '1234.56 5678.90\n' > "$FR/proc/uptime"
  printf 'Linux version 4.4.205 (build) #1 SMP\n' > "$FR/proc/version"
  printf '  0:  GICv3  27 Level  arch_timer\n 55:  0  0  0  0  0  0  0  0  lmh-interrupt\n' > "$FR/proc/interrupts"
  if [ "$SCEN" = unmounted-debugfs ]; then
    printf '# nothing mounted here\n' > "$FR/proc/mounts"
  else
    # The mount SOURCE is a path in the fake root, because the probe compares it with the path it is about
    # to look at: a fixture carrying the real /sys would make every scenario read as "debugfs not
    # mounted", and the two scenarios this section exists to tell apart would look identical.
    printf 'nodev %s/sys/kernel/debug debugfs debugfs rw,nosuid,nodev,noexec,relatime 0 0\n' "$FR" > "$FR/proc/mounts"
  fi

  case "$SCEN" in not-zl1 | no-driver) ;; *)
    mkdir -p "$FR/sys/bus/platform/drivers/lmh-lite-driver"
    touch "$FR/sys/bus/platform/drivers/lmh-lite-driver/bind" \
      "$FR/sys/bus/platform/drivers/lmh-lite-driver/unbind" \
      "$FR/sys/bus/platform/drivers/lmh-lite-driver/uevent" ;;
  esac
  case "$SCEN" in not-zl1 | no-driver | no-dt-node | unbound) ;; *)
    mkdir -p "$FR/sys/bus/platform/drivers/lmh-lite-driver/2080000.qcom,lmh" ;;
  esac
  case "$SCEN" in
  healthy | bound-no-sensors | bound-profile-no-monitor | unmounted-debugfs | log-quiet | \
    log-unreadable | bound-log-unreadable)
    mkdir -p "$FR/sys/class/msm_limits/lmh-profile"
    printf '0\n' > "$FR/sys/class/msm_limits/lmh-profile/level"
    printf '12\n' > "$FR/sys/class/msm_limits/lmh-profile/total_levels"
    printf '0 1 2 3 4 5 6 7 8 9 10 11\n' > "$FR/sys/class/msm_limits/lmh-profile/available_levels" ;;
  esac
  case "$SCEN" in healthy | log-quiet | log-unreadable | bound-log-unreadable)
    mkdir -p "$FR/sys/kernel/debug/lmh_monitor/debug"
    printf '30\n' > "$FR/sys/kernel/debug/lmh_monitor/interrupt_poll_delay_msec"
    printf '1\n' > "$FR/sys/kernel/debug/lmh_monitor/hw_trace_enable"
    printf '250\n' > "$FR/sys/kernel/debug/lmh_monitor/hw_trace_interval"
    printf '\xde\xad\xbe\xef\x00\x01\x02\x03' > "$FR/sys/kernel/debug/lmh_monitor/debug/data"
    printf 'cfg\n' > "$FR/sys/kernel/debug/lmh_monitor/debug/config"
    printf 'types\n' > "$FR/sys/kernel/debug/lmh_monitor/debug/data_types"
    printf 'ctypes\n' > "$FR/sys/kernel/debug/lmh_monitor/debug/config_types" ;;
  esac

  # The kernel log, per scenario. `unreadable` makes BOTH readers fail, which is the only honest way to
  # reach the UNREAD rung: a reader that returns an empty string has to be told apart from one that does
  # not run at all.
  LOGMODE=normal
  case "$SCEN" in
  not-zl1 | no-dt-node | no-driver) LOGMODE=empty ;;
  log-unreadable | bound-log-unreadable) LOGMODE=unreadable ;;
  esac
  case "$SCEN" in
  healthy | unmounted-debugfs)
    { printf '[    0.000000] Booting Linux on physical CPU 0x0\n'
      printf '[    1.000000] lmh-lite-driver 2080000.qcom,lmh: chained irq\n'
      printf '[    1.100000] Registering sensor:[LMH_CPU0_0]\n'
      printf '[    1.100100] Registering sensor:[LMH_CPU1_1]\n'
      printf '[    1.200000] lmh 2080000.qcom,lmh: Zero throttling. Re-enabling interrupt\n'
      printf '[   30.000000] random: crng init done\n'; } > "$W/kernel.log" ;;
  unbound)
    { printf '[    0.000000] Booting Linux on physical CPU 0x0\n'
      printf '[    1.100000] lmh-lite-driver 2080000.qcom,lmh: SCM cmd:9 not available\n'
      printf '[    1.100100] lmh 2080000.qcom,lmh: Sensor Init failed. err:-19\n'
      printf '[   30.000000] random: crng init done\n'; } > "$W/kernel.log" ;;
  bound-no-sensors)
    { printf '[    0.000000] Booting Linux on physical CPU 0x0\n'
      printf '[    1.100000] lmh 2080000.qcom,lmh: LMH debug init failed. err:-19\n'
      printf '[   30.000000] random: crng init done\n'; } > "$W/kernel.log" ;;
  bound-no-profile)
    { printf '[    0.000000] Booting Linux on physical CPU 0x0\n'
      printf '[    1.100000] Registering sensor:[LMH_CPU0_0]\n'
      printf '[    1.100100] WARNING: Device Init failed. err:-6. LMH continues\n'
      printf '[   30.000000] random: crng init done\n'; } > "$W/kernel.log" ;;
  bound-profile-no-monitor)
    { printf '[    0.000000] Booting Linux on physical CPU 0x0\n'
      printf '[    1.100000] lmh-lite-driver 2080000.qcom,lmh: chained irq\n'
      printf '[    1.100100] Registering sensor:[LMH_CPU0_0]\n'
      printf '[   30.000000] random: crng init done\n'; } > "$W/kernel.log" ;;
  log-quiet)
    { printf '[    0.000000] Booting Linux on physical CPU 0x0\n'
      printf '[   30.000000] random: crng init done\n'; } > "$W/kernel.log" ;;
  *) : > "$W/kernel.log" ;;
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

# ==================================================================================================
echo "== 1. the rewrite, the safety scan, and the guard's teeth =="
# ==================================================================================================
scen healthy
nonempty "the rewritten probe has content" "$(cat "$RW")"
OUT=$(run --help)
want '^# zl1 LMH probe' "$OUT" "--help prints the probe's own header"
if ( run --help >/dev/null ); then ok "--help exits 0"; else bad "--help did not exit 0"; fi

# ==================================================================================================
echo "== 2. every rung of the driver's own failure tree, one scenario each =="
# ==================================================================================================
#
# The rungs are ordered by the driver, not by preference: the device tree first (nothing to bind to), then
# the bind (lmh_sensor_init is FATAL), then the log, then the three non-fatal outputs. Each rung is a
# different next move, so each is asserted by name AND by exit code.

scen not-zl1
OUT=$(run); RC=$?
[ "$RC" = 2 ] && ok "a non-zl1 device tree exits 2" || bad "a non-zl1 device tree exited $RC, not 2"
want 'not the zl1 .* refusing' "$OUT" "and refuses by name rather than reading another SoC's limiter"
notwant 'verdict' "$OUT" "and reaches no verdict at all"

scen no-dt-node
OUT=$(run); RC=$?
want '== verdict: no-device-tree-node' "$OUT" "a boot whose device tree has no LMH node says so"
want 'no \*lmh\* node under .*proc/device-tree' "$OUT" "naming what it searched for and did not find"
want 'WHICH IMAGE BOOTED' "$OUT" "and attributing it to the DTB the boot used, which doc 137 showed differs between the stock and rebuilt sets"
[ "$RC" = 1 ] && ok "and exits 1 -- nothing is broken that a reboot fixes" || bad "the no-node verdict exited $RC, not 1"

scen no-driver
OUT=$(run); RC=$?
want '== verdict: no-driver' "$OUT" "a kernel with no LMH driver says so"
want 'no LMH driver registered' "$OUT" "naming what is absent"
want 'CONFIG_LIMITS_LITE_HW=y' "$OUT" "and citing the defconfig that says it should have been there"
want 'software governor' "$OUT" "and saying what that leaves as the only thermal policy"
[ "$RC" = 2 ] && ok "and exits 2 (nothing further can be read)" || bad "no-driver exited $RC, not 2"

scen unbound
OUT=$(run); RC=$?
want '== verdict: not-bound' "$OUT" "a registered driver with nothing bound says so"
want 'bound device\(s\): NONE' "$OUT" "and prints the bound-device list as explicitly NONE, not as a blank"
want 'LMH_CTRL_QPMDA' "$OUT" "naming the secure-world commands whose absence is the prime suspect"
want 'scm_call -12' "$OUT" "and connecting it to the recorded cold-boot secure-world failure"
want 'SCM cmd:9 not available' "$OUT" "and printing the log line that says so, which is the evidence a reader has to act on"
[ "$RC" = 1 ] && ok "and exits 1" || bad "not-bound exited $RC, not 1"

scen healthy
OUT=$(run); RC=$?
want '== verdict: monitoring' "$OUT" "every Linux-side link up reads as monitoring"
want 'Registering sensor: lines: 2' "$OUT" "with the sensor count taken from the log"
want 'lmh-profile/level +0' "$OUT" "and the profile's files read"
want 'debug/data' "$OUT" "and the monitor path listed"
want 'lmh-interrupt' "$OUT" "and the interrupt row printed"
want 'debugfs mounted: yes \(nodev .*sys/kernel/debug' "$OUT" \
  "and the mount LINE it matched, rather than a field of it"
notwant 'source nodev' "$OUT" \
  "and never a field of that line labelled 'source' (field 1 of a mount line is the device, which for debugfs is the literal 'nodev')"
[ "$RC" = 0 ] && ok "and exits 0" || bad "the healthy verdict exited $RC, not 0"

# ==================================================================================================
echo "== 3. the asymmetric driver paths, which is why this probe reads rungs =="
# ==================================================================================================
#
# The three init paths in lmh_probe() fail differently -- fatal, warning, quiet -- so each combination that
# can exist gets its own scenario. This is the section that would catch a probe rewritten to read one flag
# and call it a day.

scen bound-no-profile
OUT=$(run); RC=$?
want '== verdict: bound-no-profile' "$OUT" "bound, sensors registered, but no profile is its own rung"
want 'LMH continues' "$OUT" "and the verdict quotes the driver's own word for that path being non-fatal"
want 'Registering sensor: lines: 1' "$OUT" "with the sensor count still read"
[ "$RC" = 1 ] && ok "and exits 1" || bad "bound-no-profile exited $RC, not 1"

scen bound-profile-no-monitor
OUT=$(run); RC=$?
want '== verdict: bound-profile-no-monitor' "$OUT" "a healthy limiter with no monitor path is its own rung"
want 'lmh_debug_init\(\)' "$OUT" "naming the driver function whose SCM gate is checked quietly"
want 'debugfs mounted: yes' "$OUT" "and printing the mount state, so a reader can tell the two causes apart"
[ "$RC" = 1 ] && ok "and exits 1" || bad "bound-profile-no-monitor exited $RC, not 1"

scen unmounted-debugfs
OUT=$(run); RC=$?
want 'debugfs mounted: NO' "$OUT" "with debugfs unmounted, the probe says so"
want 'NOT evidence about the driver' "$OUT" "and says explicitly that a missing node is then not evidence about the driver"
before 'debugfs mounted:' 'lmh_monitor:' "$OUT" \
  "and prints the mount state BEFORE the monitor node -- the only thing that tells the two causes apart"
want '== verdict: bound-profile-no-monitor' "$OUT" "reaching the same rung as the mounted case, because from the probe's side they are the same reading"
[ "$RC" = 1 ] && ok "and exits 1" || bad "unmounted-debugfs exited $RC, not 1"

scen bound-no-sensors
OUT=$(run); RC=$?
want '== verdict: bound-no-sensors' "$OUT" "a bound limiter with zero sensors reads as its own rung"
want 'control flow says should be impossible' "$OUT" "and the verdict says the driver's control flow calls that impossible, rather than believing either half"
[ "$RC" = 1 ] && ok "and exits 1" || bad "bound-no-sensors exited $RC, not 1"

# ==================================================================================================
echo "== 4. a reading that could not be taken is not a negative one =="
# ==================================================================================================
scen bound-log-unreadable
OUT=$(run); RC=$?
want '== verdict: bound-log-unreadable' "$OUT" "an unreadable kernel log is UNREAD, not zero sensors"
want 'NOT READ, which is not the same as zero' "$OUT" "and says so in the reading itself"
notwant 'Registering sensor: lines: 0' "$OUT" "and never prints a sensor count of 0 for a log it could not read"
want 'lmh-profile/level' "$OUT" "while everything that CAN be read still is -- the rungs below are unaffected"
[ "$RC" = 1 ] && ok "and exits 1" || bad "bound-log-unreadable exited $RC, not 1"

scen log-unreadable
OUT=$(run); RC=$?
want 'not read: the kernel log could not be read' "$OUT" "and the log-derived blocks print a named absence rather than nothing"
want '== verdict: bound-log-unreadable' "$OUT" "with the same verdict when the driver is otherwise fully up"

# ==================================================================================================
echo "== 5. the named (none: ...) lines actually print =="
# ==================================================================================================
#
# `grep PAT F | tail | sed || say none` never reaches its none-branch: in a pipeline the status is the LAST
# command's and `sed` succeeds on empty input. Two sites in the modem probe were live defects of exactly
# this shape (docs 120 section 5), so each site here is asserted by its own text.
scen healthy
notwant 'the kernel log mentions lmh nowhere' "$(run)" "with lmh lines in the log, the lmh block is not reported as empty"
scen log-quiet
OUT=$(run)
want 'the kernel log mentions lmh nowhere' "$OUT" "a readable log with no lmh in it prints the named (none: ...) line"
want 'no SCM-gate refusal' "$OUT" "and the SCM block prints its own named (none: ...) line"
want 'no sensor registration' "$OUT" "and the sensor block prints the third"
scen log-unreadable
want 'not read: the kernel log could not be read' "$(run)" "while an unreadable log says so instead of printing a blank"

# ==================================================================================================
echo "== 6. --quiet, and the exit-code contract =="
# ==================================================================================================
scen healthy
Q=$(run --quiet); F=$(run)
want '== verdict: monitoring' "$Q" "--quiet still prints the verdict (a verdict is not a reading)"
want 'boot id:' "$Q" "--quiet still prints which boot this is (a verdict with no boot identity is not attributable)"
want 'debugfs mounted: yes' "$Q" "--quiet keeps the reading the verdict rests on, and the mount state that qualifies it"
notwant 'compatible:' "$Q" "--quiet drops the device-tree detail"
want 'compatible:' "$F" "and the full run has it"
want 'NOT parsed' "$F" "the raw debug buffer is labelled unparsed in the full run"
notwant 'raw and NOT parsed' "$Q" "and --quiet drops the raw buffer together with its label"
scen unbound
Q=$(run --quiet)
want '== verdict: not-bound' "$Q" "--quiet prints a failing verdict too"
want 'SCM cmd:9 not available' "$Q" "and keeps the log evidence the failing verdict points at"
scen not-zl1
want 'not the zl1' "$(run --quiet)" "--quiet does not suppress the refusal"

# ==================================================================================================
echo "== 7. the shipped probe is still write-free, and a mutation proves the guard has teeth =="
# ==================================================================================================
notwant '>[[:space:]]*/tmp/' "$(cat "$SRC")" "the shipped probe writes no scratch file in /tmp either"
notwant '\bmktemp\b' "$(cat "$SRC")" "and creates no temporary file at all"
want 'LOG_TEXT=\$\(dmesg' "$(cat "$SRC")" "the kernel log is captured into a variable (the write-free way to read it twice)"
# The mutation: the write the probe is most plausibly tempted into, since `level` is the one knob the
# limiter exposes and it is writable by root.
sed 's#^always "   boot id:.*#printf 0 > /sys/class/msm_limits/lmh-profile/level#' "$SRC" > "$W/mut-write.sh"
if cmp -s "$SRC" "$W/mut-write.sh"; then
  bad "the mutation did not apply -- the seed line it edits is gone, so this check would test nothing"
else
  ok "the mutation applied to the shipped source"
  want 'msm_limits/lmh-profile/level' "$(write_sites "$W/mut-write.sh")" \
    "and a mutation that writes the limiter's level knob is caught by the guard"
fi

# ==================================================================================================
echo "== 8. this harness's own citation =="
# ==================================================================================================
# A count typed by hand in the first thing a human reads goes stale the moment this file grows, so this
# harness reads its own citation out of the health check and compares it with what it just ran.
HEALTH="$HERE/zl1-health-check.sh"
if [ -r "$HEALTH" ]; then
  cited=$(sed -e 's/always "/ /g' -e 's/"$//' "$HEALTH" | tr '\n' ' ' |
            sed -n 's/.*zl1-lmh-probe-selftest.sh[ ,(]*\([0-9][0-9]*\) checks.*/\1/p')
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
