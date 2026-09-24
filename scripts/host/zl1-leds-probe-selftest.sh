#!/usr/bin/env bash
# zl1 LEDs probe -- offline self-test. Host-side, touches no device, needs no phone.
#
# Why this exists. `scripts/device/zl1-leds-probe.sh` closes two of the twelve gaps doc 137 found -- the
# notification LED and the camera torch -- and it is the first probe in this tree whose reading is a
# COMPARISON: the device tree DECLARES names (`linux,name`, `qcom,led-name`) and the LED core REGISTERS
# entries, so the interesting failure is a declaration with no registration. That makes the fixture's job
# unusually precise, and it makes three things worth holding the probe to:
#
#   1. IT WRITES NOTHING, checked statically AND with teeth. Every LED in the class is drivable by writing
#      `brightness` (and the flash driver has a `strobe`), and a probe that "just checked the torch works"
#      would be doing the write this project keeps out of readings. The guard refuses a redirect into /sys,
#      /proc or /dev and a state-changing command in command position; the mutation is exactly the tempting
#      one -- `echo 1 > /sys/class/leds/led:torch_0/brightness` -- and the probe's own prose about lighting
#      an LED must not trip it.
#   2. A NAME DECLARED ON A NODE IS NOT A NAME DECLARED ON A CHILD. This board does both: the WLED node
#      carries `linux,name = "wled"` itself, while every PMIC LED and flash channel is a child. The first
#      draft read only the children, which meant `wled` was never in the comparison -- so a node could be
#      missing from the class and the report would not notice, silently. There is a scenario and an
#      assertion for each shape, because the defect is invisible in the shape that works.
#   3. AN IDLE LED IS NOT A FAULT. Brightness 0 with trigger none is what an idle phone looks like, so the
#      verdict may not treat it as anything. The two rungs that are evidence are "the entry is absent" and
#      "a driver has no bound device"; everything else is printed and qualified.
#
# How it works: **the stub directory IS the device.** The probe runs as itself against a fake root, with the
# device's tools stubbed and PATH sandboxed to `$STUB:$MINBIN`, where MINBIN holds symlinks to the real
# coreutils. The sandbox matters here for the same reason it did for the modem and LMH probes: this host is
# not the device, and a probe that fell through to a real path would read THIS laptop's /proc and report it
# as the phone's.
#
# Usage: zl1-leds-probe-selftest.sh [--keep]
#   --keep   leave the fake device, the stubs and the rewritten probe for inspection
#
# `ZL1_LEDS_PROBE_SRC=/path` runs the whole thing against another copy of the subject, which is how a
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
SRC="${ZL1_LEDS_PROBE_SRC:-$HERE/../device/zl1-leds-probe.sh}"
[ -r "$SRC" ] || { echo "cannot read the subject: $SRC" >&2; exit 2; }

W="${TMPDIR:-/tmp}/zl1-leds-probe-selftest"
# `root`, not `dev`: the fake root's path must not itself contain a path the rewriter hunts for, or the
# replacement text gets rewritten in turn (the trap docs 120 records for its sibling harnesses).
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
# A count, asserted as a number rather than as a substring: "8 entries" and "18 entries" both contain "8".
count_is() { # $1 = text, $2 = ERE, $3 = expected count, $4 = label
  local n; n=$(grep -cE -- "$2" <<< "$1")
  if [ "$n" = "$3" ]; then ok "$4"; else bad "$4 (expected $3, counted $n)"; fi
}

# --- the sandbox PATH ------------------------------------------------------------------------------
# `type -P`, not `command -v`: in a shell whose profile has made one of these a function, `command -v`
# prints the NAME rather than a path and the symlink would point at itself.
for t in awk basename cat cut dirname head sed sort tail tr uniq wc grep; do
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
# TWO PASSES in two FILES, so each rule is counted where it ran. A one-pass rewrite cascades: the `/sys/`
# inside `/proc/sys/kernel/random/boot_id` would be replaced by the `/proc/` rule and then the `/sys/` rule
# would hit the result. Pass 1 turns each root into a token that cannot itself be a device path; pass 2
# expands the tokens, and nothing in a replacement can be re-matched by a rule that already ran.
A1="$W/pass1a.sh"; P1="$W/pass1.sh"; RW="$W/leds-probe.sh"
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
for need in "$FR/proc/device-tree/compatible" "$FR/proc/uptime" "$FR/proc/version" \
  "$FR/proc/sys/kernel/random/boot_id" "$FR/sys/class/leds" "$FR/sys/bus"; do
  grep -qF "$need" "$RW" || { echo "$need is not in the rewritten probe -- it would read this host, or a reading is gone" >&2; exit 2; }
done

# --- the static safety guard, and its teeth --------------------------------------------------------
#
# What counts as a write: a redirect into /sys, /proc or /dev; and dd/tee/setprop/modprobe/insmod/rmmod/
# mount/umount/mkfs **in command position**, where command position means the first word of a statement --
# the start of a line, or just after `;`, `&&`, `||`, `|`, `(`, `then`, `do` or `else`. Requiring a
# statement boundary and not just "after a space" is what keeps the probe's own prose ("that test is its own
# step", "lighting one is a WRITE") from being read as code.
#
# Two exemptions, each of which has to be there for the same reason, and each of which is itself asserted:
#   * `>/dev/null` is not a write to the device's filesystem. This port's shell is /bin/sh, where
#     `2>/dev/null` is the only way to be quiet, so those occurrences are stripped before matching.
#   * a HEREDOC BODY IS TEXT. The probe's `--explain` page describes writing to `brightness` and to
#     `strobe` in a sentence, and `strobe` is not a state-changing command but `mount`-like prose is what
#     the rule would trip on if the body were not blanked. The bodies are blanked first, keeping the line
#     count so a real hit still reports its own line number.
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
# The teeth, and the first one is the write this probe is most plausibly tempted into: the torch test.
printf '%s\n' '# a fixture for the redirect rule: the torch test this probe deliberately does not do' \
  'echo 1 > /sys/class/leds/led:torch_0/brightness' > "$W/teeth-torch.sh"
printf '%s\n' '# a fixture for the command-position rule' \
  'mount -t debugfs none /sys/kernel/debug' > "$W/teeth-cmd.sh"
printf '%s\n' '# prose that must not be read as code' \
  "cat <<'EOF'" \
  'lighting one is a WRITE -- brightness, or the flash driver'"'"'s strobe -- and this probe does not write' \
  'EOF' \
  'say "the arrow -> /sys/class/leds/red/brightness is how this page writes a path"' > "$W/teeth-prose.sh"
want 'led:torch_0/brightness' "$(write_sites "$W/teeth-torch.sh")" \
  "the guard catches a redirect into a brightness knob (the torch test, as a fixture)"
want 'debugfs' "$(write_sites "$W/teeth-cmd.sh")" "and catches a state-changing command in command position"
notwant '.' "$(write_sites "$W/teeth-prose.sh")" \
  "and does not punish prose that names an arrow before a /sys path, or a heredoc about writing brightness"
want 'brightness' "$(grep -aE -- 'strobe -- and this probe' "$W/teeth-prose.sh")" \
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
# Device-tree properties are BYTES (a NUL-terminated string list), so the fixture writes the NUL too.
dtp() { mkdir -p "$(dirname "$1")"; printf '%s\0' "$2" > "$1"; }

# The names the device tree declares on this board, in the two shapes it uses:
#   node-level   the WLED node carries `linux,name = "wled"` itself
#   child-level  `qcom,rgb_0` -> red / green / blue, `qcom,led_mpp_2` -> button-backlight,
#                `qcom,torch_*` / `qcom,flash_0` -> `led:torch_*` / `led:flash_0`
DECLARED_ALL='red green blue button-backlight wled led:flash_0 led:torch_0 led:torch_1'
# The subset with the `led:` prefix, which is leds-qpnp-flash.c's half and gets its own rung.
FLASH_ALL='led:flash_0 led:torch_0 led:torch_1'
# The subset that is NOT the flash half.
OTHER_ALL='red green blue button-backlight wled'

# `LE` is the set of declared names to give an entry in /sys/class/leds; LED_DIR_OFF removes the directory
# entirely. Everything else about the fixture is identical, so a difference in the verdict can only come
# from what the class contains.
scen() {
  SCEN="$1"
  rm -rf "$FR"
  mkdir -p "$FR/proc/sys/kernel/random" "$FR/proc/device-tree" "$FR/sys/kernel" \
    "$FR/sys/bus/spmi/drivers" "$FR/sys/bus/platform/drivers"

  printf 'qcom,msm8996-mtp\0qcom,msm8996\0qcom,mtp\0' > "$FR/proc/device-tree/compatible"
  [ "$SCEN" = not-zl1 ] && printf 'qcom,sdm845\0' > "$FR/proc/device-tree/compatible"
  printf '11111111-2222-3333-4444-555555555555\n' > "$FR/proc/sys/kernel/random/boot_id"
  printf '1234.56 5678.90\n' > "$FR/proc/uptime"
  printf 'Linux version 4.4.205 (build) #1 SMP\n' > "$FR/proc/version"

  # The drivers, on BOTH buses, because that is where they really are: the three QPNP LED drivers are SPMI
  # drivers and the camera flash consumer is a platform driver. `qcom,qpnp-flash-led` deliberately gets NO
  # bound device, which is how "a driver directory with nothing attached" is asserted.
  SPMI="$FR/sys/bus/spmi/drivers"
  for d in qcom,leds-qpnp qcom,qpnp-flash-led qcom,qpnp-wled; do
    mkdir -p "$SPMI/$d"; touch "$SPMI/$d/bind" "$SPMI/$d/unbind" "$SPMI/$d/uevent"
  done
  mkdir -p "$SPMI/qcom,leds-qpnp/400f000.qcom,spmi:qcom,pmi8994@3:qcom,leds@d000"
  mkdir -p "$SPMI/qcom,qpnp-wled/400f000.qcom,spmi:qcom,pmi8994@3:qcom,leds@d800"
  mkdir -p "$FR/sys/bus/platform/drivers/qcom,camera-flash/qcom,camera-flash"
  touch "$FR/sys/bus/platform/drivers/qcom,camera-flash/bind" \
    "$FR/sys/bus/platform/drivers/qcom,camera-flash/unbind" \
    "$FR/sys/bus/platform/drivers/qcom,camera-flash/uevent"

  # The device tree's declaration. Absent entirely for `no-dt-node`, which is the "which image booted" rung.
  if [ "$SCEN" != no-dt-node ] && [ "$SCEN" != not-zl1 ]; then
    L="$FR/proc/device-tree/soc/qcom,spmi@400f000"
    dtp "$L/qcom,pm8994@0/qcom,leds@a100/compatible" 'qcom,leds-qpnp'
    dtp "$L/qcom,pm8994@0/qcom,leds@a100/status" 'okay'
    dtp "$L/qcom,pm8994@0/qcom,leds@a100/qcom,led_mpp_2/linux,name" 'button-backlight'
    dtp "$L/qcom,pmi8994@3/qcom,leds@d000/compatible" 'qcom,leds-qpnp'
    dtp "$L/qcom,pmi8994@3/qcom,leds@d000/status" 'okay'
    dtp "$L/qcom,pmi8994@3/qcom,leds@d000/label" 'rgb'
    # present-but-empty property: this is what makes leds-qpnp.c register the extra `rgb` classdev
    mkdir -p "$L/qcom,pmi8994@3/qcom,leds@d000"; : > "$L/qcom,pmi8994@3/qcom,leds@d000/qcom,rgb-sync"
    dtp "$L/qcom,pmi8994@3/qcom,leds@d000/qcom,rgb_0/linux,name" 'red'
    dtp "$L/qcom,pmi8994@3/qcom,leds@d000/qcom,rgb_1/linux,name" 'green'
    dtp "$L/qcom,pmi8994@3/qcom,leds@d000/qcom,rgb_2/linux,name" 'blue'
    dtp "$L/qcom,pmi8994@3/qcom,leds@d300/compatible" 'qcom,qpnp-flash-led'
    dtp "$L/qcom,pmi8994@3/qcom,leds@d300/status" 'okay'
    dtp "$L/qcom,pmi8994@3/qcom,leds@d300/qcom,flash_0/qcom,led-name" 'led:flash_0'
    dtp "$L/qcom,pmi8994@3/qcom,leds@d300/qcom,torch_0/qcom,led-name" 'led:torch_0'
    dtp "$L/qcom,pmi8994@3/qcom,leds@d300/qcom,torch_1/qcom,led-name" 'led:torch_1'
    # The NODE-level shape, which is the one the first draft missed.
    dtp "$L/qcom,pmi8994@3/qcom,leds@d800/compatible" 'qcom,qpnp-wled'
    dtp "$L/qcom,pmi8994@3/qcom,leds@d800/status" 'okay'
    dtp "$L/qcom,pmi8994@3/qcom,leds@d800/linux,name" 'wled'
    dtp "$L/qcom,pmi8994@3/qcom,leds@d800/linux,default-trigger" 'bkl-trigger'
    dtp "$FR/proc/device-tree/soc/qcom,camera-flash/compatible" 'qcom,camera-flash'
    dtp "$FR/proc/device-tree/soc/qcom,camera-flash/label" 'leds-lm3643'
  fi

  # The class. `LE` names the entries to create; the rgb and flash entries get the driver-specific
  # attributes their own drivers add, which is what identifies them without guessing.
  case "$SCEN" in
  not-zl1 | no-dt-node | no-led-class) LE='' ;;
  no-flash-class) LE="$OTHER_ALL" ;;
  declared-names-missing) LE='red wled button-backlight led:flash_0 led:torch_0' ;;
  *) LE="$DECLARED_ALL" ;;
  esac
  # The class DIRECTORY is created for every scenario except the two where the device tree is what is
  # missing: an empty directory and a missing one are different readings (the probe says "present but EMPTY"
  # for one and "MISSING" for the other) and only keeping both makes that distinction assertable.
  mkdir -p "$FR/sys/class/leds"
  if [ -n "$LE" ]; then
    for n in $LE; do
      d="$FR/sys/class/leds/$n"; mkdir -p "$d"
      printf '0\n' > "$d/brightness"
      printf '255\n' > "$d/max_brightness"
      printf 'none rc-feedback [none] timer heartbeat\n' > "$d/trigger"
      # The attributes each driver REALLY adds, so the fixture has the shape the probe will meet:
      #   leds-qpnp-flash.c  `strobe`/`reg_dump`/`max_allowed_current`/`enable_current_derate`
      #   leds-qpnp-wled.c   its own dump/dim/ramp files (the classdev is named `wled`)
      #   leds-qpnp.c rgb    the LPG group, which on this vendor kernel also has `on_off_ms`/`rgb_start`
      #   leds-qpnp.c mpp    the LPG group WITHOUT `rgb_blink`/`on_off_ms`, which is only for rgb-sync
      case "$n" in
      led:*) for a in strobe reg_dump max_allowed_current enable_current_derate; do printf '0\n' > "$d/$a"; done ;;
      wled) for a in dump_regs dim_mode fs_curr_ua start_ramp ramp_ms ramp_step; do printf '0\n' > "$d/$a"; done ;;
      button-backlight) for a in blink lut_flags duty_pcts start_idx ramp_step_ms pwm_us led_mode strobe; do printf '0\n' > "$d/$a"; done ;;
      *) for a in blink on_off_ms rgb_start lut_flags duty_pcts start_idx ramp_step_ms pwm_us; do printf '0\n' > "$d/$a"; done ;;
      esac
    done
  fi
  # `qcom,rgb-sync` makes leds-qpnp.c register one MORE classdev, called `rgb`, and that is where
  # `rgb_blink` lives. It is part of the real shape, so the fixture has it: a fixture without it would let
  # the probe's "registered but NOT declared" reading go untested in the very case that produces it.
  if [ "$SCEN" != no-flash-class ] && [ "$SCEN" != declared-names-missing ] && [ -n "$LE" ]; then
    d="$FR/sys/class/leds/rgb"; mkdir -p "$d"
    printf '0\n' > "$d/brightness"; printf '255\n' > "$d/max_brightness"
    printf 'none [none] timer\n' > "$d/trigger"
    printf '0\n' > "$d/rgb_blink"
  fi
  # `driven`: one entry is on and claimed by a trigger, so the "driven now" reading has something to name
  # and the verdict must NOT change because of it (an LED being on is not a rung).
  if [ "$SCEN" = driven ]; then
    printf '255\n' > "$FR/sys/class/leds/red/brightness"
    printf 'none [heartbeat] timer\n' > "$FR/sys/class/leds/red/trigger"
  fi
  if [ "$SCEN" = unmounted-class ]; then rm -rf "$FR/sys/class"; fi

  # The kernel log. `unreadable` makes BOTH readers fail -- the only honest way to reach "not read".
  LOGMODE=normal
  case "$SCEN" in
  not-zl1 | no-dt-node) LOGMODE=empty ;;
  log-unreadable) LOGMODE=unreadable ;;
  esac
  case "$SCEN" in
  registered | driven | unmounted-class)
    { printf '[    0.000000] Booting Linux on physical CPU 0x0\n'
      printf '[    1.100000] qcom,leds-qpnp 400f000.qcom,spmi:qcom,pmi8994@3:qcom,leds@d000: registered rgb\n'
      printf '[    1.100200] qcom,qpnp-wled 400f000.qcom,spmi:qcom,pmi8994@3:qcom,leds@d800: wled ready\n'
      printf '[   30.000000] random: crng init done\n'; } > "$W/kernel.log" ;;
  log-quiet)
    { printf '[    0.000000] Booting Linux on physical CPU 0x0\n'
      printf '[   30.000000] random: crng init done\n'; } > "$W/kernel.log" ;;
  log-failing)
    : > "$W/kernel.log" ;;
  *) : > "$W/kernel.log" ;;
  esac
  # `log-failing` gets its own body: a log that mentions LEDs and a registration failure.
  if [ "$SCEN" = log-failing ]; then
    { printf '[    0.000000] Booting Linux on physical CPU 0x0\n'
      printf '[    1.100000] qcom,qpnp-flash-led: Unable to read flash name\n'
      printf '[    1.100100] qcom,leds-qpnp: Unable to register led\n'
      printf '[   30.000000] random: crng init done\n'; } > "$W/kernel.log"
  fi
  if [ "$SCEN" = log-unreadable ]; then : > "$W/kernel.log"; fi
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
scen registered
nonempty "the rewritten probe has content" "$(cat "$RW")"
OUT=$(run --help)
want '^# zl1 LEDs probe' "$OUT" "--help prints the probe's own header"
want 'this probe does not write' "$(run --explain)" "--explain says the probe lights nothing, so the torch test is not a side effect"
if ( run --help >/dev/null ); then ok "--help exits 0"; else bad "--help did not exit 0"; fi

# ==================================================================================================
echo "== 2. every rung, one scenario each =="
# ==================================================================================================
scen not-zl1
OUT=$(run); RC=$?
[ "$RC" = 2 ] && ok "a non-zl1 device tree exits 2" || bad "a non-zl1 device tree exited $RC, not 2"
want 'not the zl1 .* refusing' "$OUT" "and refuses by name rather than reading another SoC's LEDs"
notwant 'verdict' "$OUT" "and reaches no verdict at all"

scen no-dt-node
OUT=$(run); RC=$?
want '== verdict: no-device-tree-nodes' "$OUT" "a boot whose device tree declares no LEDs says so"
want 'declares no LEDs' "$OUT" "naming what is missing"
want 'WHICH IMAGE BOOTED' "$OUT" "and attributing it to the DTB this boot used, which doc 137 showed differs between the sets"
[ "$RC" = 1 ] && ok "and exits 1" || bad "the no-node verdict exited $RC, not 1"

scen no-led-class
OUT=$(run); RC=$?
want '== verdict: no-led-class' "$OUT" "an empty LED class is its own rung"
want 'present but EMPTY' "$OUT" "and says the directory is empty rather than that it is missing"
want 'LEDS_CLASS=y' "$OUT" "and says this is not a config gap, citing the defconfig"
want 'driver directory with no bound device' "$OUT" "and points at the driver section as the next move"
[ "$RC" = 1 ] && ok "and exits 1" || bad "no-led-class exited $RC, not 1"

scen unmounted-class
OUT=$(run); RC=$?
want '== verdict: no-led-class' "$OUT" "a MISSING class directory reaches the same rung"
want 'MISSING' "$OUT" "and says so, which is the reading the EMPTY case cannot give"
[ "$RC" = 1 ] && ok "and exits 1" || bad "the missing-class verdict exited $RC, not 1"

scen declared-names-missing
OUT=$(run); RC=$?
want '== verdict: declared-names-missing' "$OUT" "a declared non-flash name with no entry is its own rung"
want 'green +NOT in' "$OUT" "and the missing names are printed one by one, so the reader does not have to diff two lists"
want 'not the flash half' "$OUT" "and the verdict says explicitly that this is not the flash half"
[ "$RC" = 1 ] && ok "and exits 1" || bad "declared-names-missing exited $RC, not 1"

scen no-flash-class
OUT=$(run); RC=$?
want '== verdict: no-flash-class' "$OUT" "the flash half missing is its own rung, not one more missing name"
want 'qcom,qpnp-flash-led' "$OUT" "naming the SPMI driver that owns that half"
want 'camera stack' "$OUT" "and the platform-side consumer that binds the other end"
want 'led:torch_0 +NOT in' "$OUT" "with the missing flash names printed"
[ "$RC" = 1 ] && ok "and exits 1" || bad "no-flash-class exited $RC, not 1"

scen registered
OUT=$(run); RC=$?
want '== verdict: registered' "$OUT" "every declared name registered is the healthy rung"
want 'notification RGB declared: +red green blue' "$OUT" "with the notification half named as such"
want 'torch/flash declared: +led:flash_0 led:torch_0 led:torch_1' "$OUT" "and the flash half too"
[ "$RC" = 0 ] && ok "and exits 0" || bad "the healthy verdict exited $RC, not 0"

# ==================================================================================================
echo "== 3. declared on a NODE vs declared on a CHILD (the defect the first draft had) =="
# ==================================================================================================
scen registered
OUT=$(run)
# `wled` is declared on the node itself; `button-backlight` on a child; `red` on a child of a third node.
# All three shapes must reach the comparison, or a node can be absent from the class with nothing said.
want '^     wled +registered' "$OUT" "a name declared on the NODE ITSELF reaches the comparison and is checked"
want '^     button-backlight +registered' "$OUT" "as does a name declared on a CHILD"
want '^     red +registered' "$OUT" "and one on a child of a node found by a different glob"
want 'node name:   linux,name = wled' "$OUT" "with the node-level reading printed where it came from"
count_is "$(printf '%s\n' "$OUT" | sed -n '/declared, and registered/,$p')" '^     .+ registered$' 8 \
  "all eight declared names are compared -- not seven, and not nine"
# And the comparison is a comparison: absent names must be printed on the same table.
scen declared-names-missing
OUT=$(run)
count_is "$(printf '%s\n' "$OUT" | sed -n '/declared, and registered/,$p')" '^     .+ registered$' 5 \
  "with two names absent, five are registered and the other two are named as missing"

# ==================================================================================================
echo "== 4. the entry listing: the drivers' own attributes, and the trigger's current value =="
# ==================================================================================================
scen registered
OUT=$(run)
want '^     red +brightness=0 max_brightness=255 trigger=none$' "$OUT" \
  "an entry is listed with its brightness, its max_brightness, and the trigger CURRENTLY in effect"
notwant 'rc-feedback' "$OUT" "and not the whole page of available triggers"
want 'attrs:.*rgb_blink' "$OUT" "the rgb entry's attributes come from leds-qpnp.c and are listed"
want 'attrs:.*reg_dump' "$OUT" "and the flash entry's from leds-qpnp-flash.c"
want 'attrs:.*dim_mode' "$OUT" "and the backlight's from leds-qpnp-wled.c -- three drivers, told apart by what is really there"
notwant '^     wled +.*reg_dump' "$OUT" "so the halves are told apart by their attributes, not by their names"
notwant '^     button-backlight +.*rgb_blink' "$OUT" \
  "and an MPP entry is NOT credited with rgb_blink, which only the rgb-sync classdev has"
count_is "$(printf '%s\n' "$OUT" | sed -n '/the LED class/,/declared, and registered/p')" '^     .+ brightness=' 9 \
  "every entry in the class is listed, including the one the device tree never names"
# The mirror reading, and its real instance: leds-qpnp.c registers a classdev called `rgb` because the node
# carries `qcom,rgb-sync`, and the device tree never names it. A one-way comparison would have hidden it.
want 'registered but NOT declared: rgb' "$OUT" \
  "an entry the device tree does not declare is reported too -- the class is not just the declared list"

# ==================================================================================================
echo "== 5. the drivers, on every bus, and which of them has anything attached =="
# ==================================================================================================
want 'qcom,leds-qpnp +bus=spmi bound:.*leds@d000' "$OUT" "an SPMI LED driver is found with its bound device"
want 'qcom,qpnp-wled +bus=spmi bound:.*leds@d800' "$OUT" "and the backlight driver too"
want 'qcom,camera-flash +bus=platform bound: qcom,camera-flash' "$OUT" \
  "and the camera flash consumer on the PLATFORM bus -- globbing one bus would have made it invisible"
want 'qcom,qpnp-flash-led +bus=spmi bound: NONE' "$OUT" \
  "and a driver directory with nothing attached prints NONE rather than a blank"
count_is "$OUT" 'qcom,qpnp-flash-led +bus=' 1 \
  "the flash driver is listed ONCE although two globs match it (led and flash both match its name)"

# ==================================================================================================
echo "== 6. an idle LED is not a fault, and an unreadable log is not a rung =="
# ==================================================================================================
scen registered
OUT=$(run)
want 'driven now: nothing' "$OUT" "an idle phone is reported as nothing driven"
want '== verdict: registered' "$OUT" "and that is still the healthy rung -- brightness 0 is not a finding"
notwant 'verdict: .*(idle|quiet|no-)' "$OUT" "with no verdict invented for it"
scen driven
OUT=$(run); RC=$?
want 'driven now:.*red\(brightness=255\)' "$OUT" "an LED that IS on is named, with the reading that shows it"
want 'driven now:.*red\(trigger=heartbeat\)' "$OUT" "and the trigger that claimed it is named too"
want '== verdict: registered' "$OUT" "and the verdict is unchanged: being on is a reading, not a rung"
[ "$RC" = 0 ] && ok "and still exits 0" || bad "the driven scenario exited $RC, not 0"

scen log-unreadable
OUT=$(run); RC=$?
want 'the kernel log could not be read' "$OUT" "an unreadable kernel log says so"
want 'so this section is NOT READ' "$OUT" "and is named as not read rather than printed empty"
want 'No verdict below rests on it' "$OUT" "and the probe says why it is not a rung here, unlike its thermal sibling"
want '== verdict: registered' "$OUT" "with the verdict unchanged -- no reading here comes from the log"
[ "$RC" = 0 ] && ok "and exits 0" || bad "the unreadable-log scenario exited $RC, not 0"

# ==================================================================================================
echo "== 7. the log block, when it can be read =="
# ==================================================================================================
scen log-failing
OUT=$(run)
want 'Unable to read flash name' "$OUT" "a flash driver that could not read its name is surfaced from the log"
want 'Unable to register led' "$OUT" "and one that could not register"
scen log-quiet
OUT=$(run)
want 'the kernel log mentions no LED driver this boot' "$OUT" "a readable log with no LED lines prints the named (none: ...) line"
want 'no LED registration failure' "$OUT" "and the failure block prints its own named (none: ...) line"
scen log-unreadable
want 'not read: the kernel log could not be read' "$(run)" "while an unreadable log prints a named absence instead of a blank"

# ==================================================================================================
echo "== 8. --quiet, and the exit-code contract =="
# ==================================================================================================
scen registered
Q=$(run --quiet); F=$(run)
want '== verdict: registered' "$Q" "--quiet still prints the verdict (a verdict is not a reading)"
want 'boot id:' "$Q" "--quiet still prints which boot this is (a verdict with no boot identity is not attributable)"
want 'driven now:' "$Q" "--quiet keeps the reading the verdict qualifies"
notwant 'compatible:' "$Q" "--quiet drops the device-tree detail"
want 'compatible:' "$F" "and the full run has it"
notwant 'brightness=' "$Q" "--quiet drops the per-entry listing"
scen no-flash-class
Q=$(run --quiet)
want '== verdict: no-flash-class' "$Q" "--quiet prints a failing verdict too"
want 'led:torch_0 +NOT in' "$Q" "and keeps the missing names the verdict points at, which --quiet must not delete"
scen not-zl1
want 'not the zl1' "$(run --quiet)" "--quiet does not suppress the refusal"

# ==================================================================================================
echo "== 9. the shipped probe is still write-free, and the mutation proves the guard has teeth =="
# ==================================================================================================
notwant '>[[:space:]]*/tmp/' "$(cat "$SRC")" "the shipped probe writes no scratch file in /tmp either"
notwant '\bmktemp\b' "$(cat "$SRC")" "and creates no temporary file at all"
want 'LOG_TEXT=\$\(dmesg' "$(cat "$SRC")" "the kernel log is captured into a variable (the write-free way to read it twice)"
# The mutation: the torch test, which is precisely the write a probe about LEDs would be tempted into.
sed 's#^    cur=\$(rd "\$d/trigger")#    printf 1 > /sys/class/leds/led:torch_0/brightness#' "$SRC" > "$W/mut-write.sh"
if cmp -s "$SRC" "$W/mut-write.sh"; then
  bad "the mutation did not apply -- the seed line it edits is gone, so this check would test nothing"
else
  ok "the mutation applied to the shipped source"
  want 'led:torch_0/brightness' "$(write_sites "$W/mut-write.sh")" \
    "and a mutation that lights the torch is caught by the guard"
fi

# ==================================================================================================
echo "== 10. this harness's own citation =="
# ==================================================================================================
# A count typed by hand in the first thing a human reads goes stale the moment this file grows, so this
# harness reads its own citation out of the health check and compares it with what it just ran.
HEALTH="$HERE/zl1-health-check.sh"
if [ -r "$HEALTH" ]; then
  cited=$(sed -e 's/always "/ /g' -e 's/"$//' "$HEALTH" | tr '\n' ' ' |
            sed -n 's/.*zl1-leds-probe-selftest.sh[ ,(]*\([0-9][0-9]*\) checks.*/\1/p')
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
