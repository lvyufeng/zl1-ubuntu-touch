#!/usr/bin/env bash
# zl1 sleep and throttle -- offline self-test. Host-side, touches no device, needs no phone.
#
# Why this exists. `scripts/device/zl1-sleep-and-throttle.sh` asks whether the SoC is ALLOWED to use its
# low-power modes, and its whole value rests on one distinction that is easy to lose:
#
#   A COUNTER THAT COULD NOT BE READ IS NOT A ZERO.
#
# A cpuidle `time` file that is missing, empty or non-numeric must never be reported as "the SoC never
# slept" -- that is the conclusion the script exists to test, and reaching it from an unreadable file is
# the defect class this repository has now recorded in five instruments (docs 117). So the harness holds
# the probe to four things, in this order of importance:
#
#   1. UNREADABLE IS NOT ZERO, AND THE VERDICT SAYS SO. Scenarios remove the cpuidle counters, make one
#      non-numeric, and hide the cmdline; each must produce UNKNOWN and exit 1, and none may print a
#      share (a percentage made from an unreadable counter is a number about the script).
#   2. IT WRITES NOTHING -- and here that needs a specific tooth. This probe reads files that ARE
#      writable on the real device: `cpuidle/state*/disable`, `thermal_zone*/mode` and `policy`. Those
#      are precisely the files a script like this would "fix" in passing, so the static guard covers
#      them and a mutation that writes one must make it fail.
#   3. --quiet CHANGES WHAT IS SHOWN, NOT WHAT IS DECIDED. A quiet run decides the same verdict as a
#      loud one on the same device. (The first draft got this wrong: its per-CPU loop `continue`d under
#      --quiet, so the tallies stayed at their initial values and a quiet run reported the cpuidle cause
#      as UNKNOWN on a device it had just read successfully.)
#   4. THE LADDER IS READ FROM THE LIVE DEVICE TREE -- including the two different node shapes it has
#      (`qcom,pm-cluster-level@*` and `qcom,pm-cpu/qcom,pm-cpu-level@*`), because a walk that finds
#      nothing must report a walk that found nothing and not "the hardware has no low-power modes".
#
# How it works: **the stub directory IS the device.** The probe runs as itself with a fake root and the
# tools it calls stubbed; PATH for the child is `$STUB:$MINBIN`, and MINBIN is a sandbox of symlinks to
# the real coreutils -- the same construction as its siblings, so a tool that is not in the sandbox
# cannot silently be this host's.
#
# Usage: zl1-sleep-and-throttle-selftest.sh [--keep]
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
SRC="$HERE/../device/zl1-sleep-and-throttle.sh"
[ -r "$SRC" ] || { echo "cannot read $SRC" >&2; exit 2; }

W="${TMPDIR:-/tmp}/zl1-sleep-and-throttle-selftest"
# `root`, not `dev`: the fake root's own path must not contain a path the rewriter hunts for, or the
# replacement text gets rewritten in turn -- the cascade one of this family's harnesses found twice.
FR="$W/root"
STUB="$W/stub"
MINBIN="$W/minbin"
ACT="$W/actions"
rm -rf "$W"
mkdir -p "$STUB" "$MINBIN" || exit 2

# --- the sandbox PATH ------------------------------------------------------------------------------
for t in awk basename cat cut head ls sed sort tail tr uniq wc grep; do
  p="$(type -P "$t" 2>/dev/null)" || continue
  [ -n "$p" ] && ln -sf "$p" "$MINBIN/$t"
done
for t in awk grep ls sed tail tr wc; do
  [ -x "$MINBIN/$t" ] || { echo "the sandbox bin is missing $t -- the harness cannot run the probe honestly" >&2; exit 2; }
done
SH_BIN="$(type -P sh 2>/dev/null)"; [ -n "$SH_BIN" ] || SH_BIN=/bin/sh
[ -x "$SH_BIN" ] || { echo "no /bin/sh to run the probe with" >&2; exit 2; }

# --- the script under test, rewritten into the fake device -----------------------------------------
#
# TWO PASSES through tokens, for the reason its siblings record: a one-pass rewrite is a cascade, and a
# cascaded path is a script reading something that cannot exist while every scenario still passes.
# `/proc/cmdline` is rewritten as a whole path rather than through the `/proc/` rule, because the probe
# reads it by name and a rule that turned it into `$FR/proc/cmdline` would still be right -- but naming
# it here keeps this list the complete set of device paths the probe touches, which is what the count
# invariant below checks.
P1="$W/pass1.sh"
sed -e 's#/proc/cmdline#__ZC__#g' \
    -e 's#/proc/device-tree#__ZDT__#g' \
    -e 's#/sys/devices/system/cpu#__ZCPU__#g' \
    -e 's#/sys/module/msm_thermal#__ZMT__#g' \
    -e 's#/sys/module/lpm_levels#__ZLL__#g' \
    -e 's#/sys/class/thermal#__ZTH__#g' \
    -e 's#/proc/#__ZP__#g' \
    -e 's#/sys/#__ZS__#g' "$SRC" > "$P1"

RW="$W/sleep-and-throttle.sh"
sed -e "s#__ZC__#$FR/proc/cmdline#g" \
    -e "s#__ZDT__#$FR/proc/device-tree#g" \
    -e "s#__ZCPU__#$FR/sys/devices/system/cpu#g" \
    -e "s#__ZMT__#$FR/sys/module/msm_thermal#g" \
    -e "s#__ZLL__#$FR/sys/module/lpm_levels#g" \
    -e "s#__ZTH__#$FR/sys/class/thermal#g" \
    -e "s#__ZP__#$FR/proc/#g" \
    -e "s#__ZS__#$FR/sys/#g" "$P1" > "$RW"
sh -n "$RW" || { echo "the rewritten probe does not parse" >&2; exit 2; }
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
# And the three paths the whole probe is built around, named individually: a token that expanded by the
# wrong rule would still satisfy the count above.
for pair in "__ZC__:$FR/proc/cmdline" "__ZDT__:$FR/proc/device-tree" "__ZCPU__:$FR/sys/devices/system/cpu" \
            "__ZMT__:$FR/sys/module/msm_thermal" "__ZLL__:$FR/sys/module/lpm_levels" \
            "__ZTH__:$FR/sys/class/thermal"; do
  tok="${pair%%:*}"; path="${pair#*:}"
  [ "$(cnt "$tok" "$P1")" -gt 0 ] || { echo "$tok never appears in pass 1 -- that path is not in the probe" >&2; exit 2; }
  [ "$(cnt "$tok" "$P1")" = "$(cnt "$path" "$RW")" ] \
    || { echo "$tok did not expand to $path exactly as many times as it appears" >&2; exit 2; }
done
grep -qF "$FR$FR" "$RW" && { echo "a rewrite cascaded: $FR appears twice in a row" >&2; exit 2; }
grep -qF "$FR/proc/$FR" "$RW" && { echo "a rewrite cascaded into the fake root's own proc/" >&2; exit 2; }
grep -qF "LPMDT=$FR/proc/device-tree/soc/qcom,lpm-levels" "$RW" \
  || { echo "the lpm-levels node path was not rewritten -- section 2 is the point of the script" >&2; exit 2; }
grep -qF "CPU_GLOB=$FR/sys/devices/system/cpu/cpu[0-9]*" "$RW" \
  || { echo "the cpu glob was not rewritten -- the probe would read THIS host's cpus" >&2; exit 2; }
grep -qF "LPMPAR=$FR/sys/module/lpm_levels/parameters" "$RW" \
  || { echo "the lpm_levels parameters dir was not rewritten -- section 1 would read THIS host's" >&2; exit 2; }

# --- the static safety guard, and its teeth --------------------------------------------------------
#
# The same rule as its siblings -- a redirect into /sys, /proc or a block device; dd/mkfs/mount/umount/
# fstrim/modprobe/insmod/rmmod/setprop/tee in COMMAND POSITION; a state-changing systemctl verb -- and
# the same arrow exclusion, because these probes write their readings as `-> /proc/cmdline ...` and a
# guard that fires on the probe's own prose is a guard somebody will weaken.
#
# This probe's teeth are aimed at the files it reads that ARE writable: `cpuidle/state*/disable`,
# `thermal_zone*/mode`, `thermal_zone*/policy`. "Read the mode" and "set the mode" differ by one
# character in the shell, and the guard has to be able to tell them apart.
WRITE_RE='(^|[;&|(`]|\$\()[[:space:]]*(dd|mkfs(\.ext4)?|mount|umount|fstrim|modprobe|insmod|rmmod|setprop|tee)[[:space:]]|(^|[^-])>>?[[:space:]]*/(sys|proc|dev/block)|systemctl[[:space:]]+(start|stop|restart|enable|disable|mask|daemon-reload)'
MOUNT_LIST_RE='\$\(mount([[:space:]]+2>/dev/null)?[[:space:]]*\|'
writes_in() { grep -nE -- "$WRITE_RE" "$1" 2>/dev/null | grep -vE -- "$MOUNT_LIST_RE"; }

# --- the fake device -------------------------------------------------------------------------------
#
# The fixture is written ONCE with every switch in it, so a scenario changes the device and that change
# is the ONLY difference. Three units of state live here and they are deliberately separable:
#   FAKE_CPUIDLE   clean | no-states | nonnumeric | nodir | zero   (section 3)
#   FAKE_LPM       full | no-node | empty                          (section 2)
#   FAKE_CMDLINE   lpm | clean | no-sleep-key | missing            (section 1, the cmdline half)
#   FAKE_LPMPAR    one | zero | nofile | nodir                     (section 1, the sysfs half)
# and every switch defaults to the coherent, real-device shape (a full ladder, a cmdline that carries
# lpm_levels.sleep_disabled=1, the driver parameter reading 1, counters that move) so that a scenario
# which forgets to set one is testing the baseline rather than an accident.
cat > "$W/reset.sh" <<EOF
#!/bin/sh
set -u
rm -rf "$FR"
mkdir -p "$FR/proc/device-tree/soc" "$FR/proc/sys/kernel/random" \\
         "$FR/sys/devices/system/cpu/cpuidle" "$FR/sys/module/msm_thermal/parameters" \\
         "$FR/sys/class/thermal" 2>/dev/null
# NOT $FR/sys/module/lpm_levels: FAKE_LPMPAR=nodir has to be able to leave it absent, and a
# directory created unconditionally here would make that scenario test the wrong thing.
printf '%s\\0' "\${FAKE_COMPAT:-qcom,msm8996pro}" > "$FR/proc/device-tree/compatible"
printf '4.9.186-perf+\\n' > "$FR/proc/sys/kernel/osrelease"
printf 'aaaa-bbbb-cccc\\n' > "$FR/proc/sys/kernel/random/boot_id"

# --- section 1: what this boot was told ---------------------------------------------------------
case "\${FAKE_CMDLINE:-lpm}" in
missing) : ;;
clean)
  printf 'androidboot.hardware=qcom ehci-hcd.park=3 lpm_levels.sleep_time_override=0 apparmor=1 security=apparmor firmware_class.path=/vendor/firmware_mnt/image loop.max_part=7\\n' > "$FR/proc/cmdline" ;;
no-sleep-key)
  printf 'androidboot.hardware=qcom lpm_levels.menu_select=0 cpuidle.off=0 loop.max_part=7\\n' > "$FR/proc/cmdline" ;;
*)
  printf 'androidboot.hardware=qcom ehci-hcd.park=3 lpm_levels.sleep_disabled=1 lpm_levels.sleep_time_override=0 cma=32M@0-0xffffffff apparmor=1 security=apparmor firmware_class.path=/vendor/firmware_mnt/image loop.max_part=7\\n' > "$FR/proc/cmdline" ;;
esac

# --- section 1, the other half: what the DRIVER has now -------------------------------------------
# \`/sys/module/lpm_levels/parameters/sleep_disabled\` -- the corrected reading (docs 121, and the
# calibration that establishes the file is mode 0664 is in
# docs/ubuntu-touch/evidence/lpm-sleep-disabled-param-2026-09-24.txt). Real shape by default: the
# directory exists and the parameter reads 1, which is what the cmdline asked for. The scenarios where
# the two halves DISAGREE are the ones worth having, so this switch is deliberately separate from
# FAKE_CMDLINE -- and it is the file the FIX would write, which is why the guard's next tooth is here.
case "\${FAKE_LPMPAR:-one}" in
nodir) : ;;
nofile) mkdir -p "$FR/sys/module/lpm_levels/parameters" ;;
zero)
  mkdir -p "$FR/sys/module/lpm_levels/parameters"
  printf '0\\n' > "$FR/sys/module/lpm_levels/parameters/sleep_disabled"
  printf '0\\n' > "$FR/sys/module/lpm_levels/parameters/menu_select" ;;
*)
  mkdir -p "$FR/sys/module/lpm_levels/parameters"
  printf '1\\n' > "$FR/sys/module/lpm_levels/parameters/sleep_disabled"
  printf '0\\n' > "$FR/sys/module/lpm_levels/parameters/menu_select" ;;
esac

# --- section 2: the ladder the hardware has -----------------------------------------------------
# The real shape, taken from the DTBs in the boot image: a nested tree with the system cluster at the
# top, two L2 clusters under it, and the per-CPU levels under each L2 cluster.
L="$FR/proc/device-tree/soc/qcom,lpm-levels"
# \`mkdir -p "\$1"\` and not \`mkdir -p "\$(dirname "\$1")"\`: this is a device-tree node, so the DIRECTORY is
# the level and the files go inside it. The first draft created the parent and then wrote into a
# directory it had never made, which is the fixture failing in a way that would have made section 2
# report a walk that found nothing -- i.e. a fake device that quietly tests the ABSENCE of the thing the
# scenario set up.
lv() { mkdir -p "\$1"; printf '%s\\0' "\$2" > "\$1/label"; printf '%s\\0' "\$3" > "\$1/qcom,latency-us"; }
case "\${FAKE_LPM:-full}" in
no-node) : ;;
empty) mkdir -p "\$L" ;;
*)
  mkdir -p "\$L"
  : > "\$L/qcom,use-psci"
  lv "\$L/qcom,pm-cluster@0/qcom,pm-cluster-level@0" system-wfi 100
  lv "\$L/qcom,pm-cluster@0/qcom,pm-cluster-level@1" system-ret 350
  lv "\$L/qcom,pm-cluster@0/qcom,pm-cluster-level@2" system-fpc 11000
  lv "\$L/qcom,pm-cluster@0/qcom,pm-cluster@0/qcom,pm-cluster-level@0" pwr-l2-wfi 40
  lv "\$L/qcom,pm-cluster@0/qcom,pm-cluster@0/qcom,pm-cluster-level@2" pwr-l2-fpc 700
  lv "\$L/qcom,pm-cluster@0/qcom,pm-cluster@0/qcom,pm-cpu/qcom,pm-cpu-level@0" cpu-wfi 20
  lv "\$L/qcom,pm-cluster@0/qcom,pm-cluster@0/qcom,pm-cpu/qcom,pm-cpu-level@2" cpu-pc 80
  lv "\$L/qcom,pm-cluster@0/qcom,pm-cluster@1/qcom,pm-cluster-level@2" perf-l2-fpc 800
  ;;
esac

# --- section 3: the counters -------------------------------------------------------------------
printf 'qcom-cpuidle\\n' > "$FR/sys/devices/system/cpu/cpuidle/current_driver"
# Four cores, three states each, shallowest first. The values are the SHAPE that matters: the deep state
# holds a real share of the counted time in the baseline, so "the deep state's share is printed" is a
# check that can pass and whose number means something.
mkstate() { # dir name usage time disable
  mkdir -p "\$1"; printf '%s\\n' "\$2" > "\$1/name"; printf '%s\\n' "\$3" > "\$1/usage"
  printf '%s\\n' "\$4" > "\$1/time"; [ -n "\$5" ] && printf '%s\\n' "\$5" > "\$1/disable"
}
case "\${FAKE_CPUIDLE:-clean}" in
nodir) : ;;
*)
  for c in 0 1 2 3; do
    mkdir -p "$FR/sys/devices/system/cpu/cpu\$c/cpuidle"
    case "\${FAKE_CPUIDLE:-clean}" in
    no-states) : ;;
    nonnumeric)
      mkstate "$FR/sys/devices/system/cpu/cpu\$c/cpuidle/state0" wfi 100 5000 0
      mkstate "$FR/sys/devices/system/cpu/cpu\$c/cpuidle/state1" retention 10 BAD 0
      mkstate "$FR/sys/devices/system/cpu/cpu\$c/cpuidle/state2" pc 2 900 0 ;;
    zero)
      mkstate "$FR/sys/devices/system/cpu/cpu\$c/cpuidle/state0" wfi 0 0 0
      mkstate "$FR/sys/devices/system/cpu/cpu\$c/cpuidle/state1" retention 0 0 0
      mkstate "$FR/sys/devices/system/cpu/cpu\$c/cpuidle/state2" pc 0 0 0 ;;
    *)
      mkstate "$FR/sys/devices/system/cpu/cpu\$c/cpuidle/state0" wfi 100000 500000 0
      mkstate "$FR/sys/devices/system/cpu/cpu\$c/cpuidle/state1" retention 4000 100000 0
      mkstate "$FR/sys/devices/system/cpu/cpu\$c/cpuidle/state2" pc 2000 400000 1 ;;
    esac
  done
  # cpu0 has no \`online\` file on a real device (it cannot be offlined), and cpu3 is offline here so
  # the "online" reading has both a present and an absent case to print.
  printf '0\\n' > "$FR/sys/devices/system/cpu/cpu3/online"
  ;;
esac

# --- sections 4/5/6: the driver, the zones, the cooling devices, cpufreq -------------------------
mkdir -p "$FR/sys/module/msm_thermal/parameters"
printf 'Y\\n' > "$FR/sys/module/msm_thermal/parameters/cores_mitigation"
printf '90\\n' > "$FR/sys/module/msm_thermal/parameters/limit_temp_degC"
printf '768000\\n' > "$FR/sys/module/msm_thermal/parameters/freq_mitig_value"
mkdir -p "$FR/sys/class/thermal/thermal_zone0" "$FR/sys/class/thermal/thermal_zone1"
printf 'tsens_tz_sensor1\\n' > "$FR/sys/class/thermal/thermal_zone0/type"
printf 'enabled\\n'  > "$FR/sys/class/thermal/thermal_zone0/mode"
printf 'step_wise\\n' > "$FR/sys/class/thermal/thermal_zone0/policy"
printf '999999\\n'     > "$FR/sys/class/thermal/thermal_zone0/temp"
printf 'pm8994_tz\\n'  > "$FR/sys/class/thermal/thermal_zone1/type"
printf 'enabled\\n'    > "$FR/sys/class/thermal/thermal_zone1/mode"
printf 'step_wise\\n'  > "$FR/sys/class/thermal/thermal_zone1/policy"
printf '30000\\n'      > "$FR/sys/class/thermal/thermal_zone1/temp"
case "\${FAKE_ZONEDIS:-0}" in 1) printf 'disabled\\n' > "$FR/sys/class/thermal/thermal_zone1/mode" ;; esac
# No cooling devices by default: that is the real device's state and the one the governor installer
# recorded in prose. FAKE_COOL=2 registers two of them so the other branch has a scenario too.
case "\${FAKE_COOL:-0}" in
0) : ;;
*) for i in 0 1; do
     mkdir -p "$FR/sys/class/thermal/cooling_device\$i"
     printf 'cpu-isolate\\n' > "$FR/sys/class/thermal/cooling_device\$i/type"
     printf '0\\n'           > "$FR/sys/class/thermal/cooling_device\$i/cur_state"
     printf '3\\n'           > "$FR/sys/class/thermal/cooling_device\$i/max_state"
   done ;;
esac
case "\${FAKE_GOV:-performance}" in
none) : ;;
*) for c in 0 1 2 3; do
     mkdir -p "$FR/sys/devices/system/cpu/cpu\$c/cpufreq"
     # \`\${FAKE_GOV:-performance}\` and NOT \`\$FAKE_GOV\`: the harness exports the switch as an EMPTY
     # string, and inside the case arm a bare \$FAKE_GOV writes a single newline -- a governor of "".
     # The byte-for-byte manifest check above is what found this: the fixture changed across two runs
     # that should have been identical, because the arm and its own case label disagreed about the
     # default.
     printf '%s\\n' "\${FAKE_GOV:-performance}" > "$FR/sys/devices/system/cpu/cpu\$c/cpufreq/scaling_governor"
     printf '2150400\\n' > "$FR/sys/devices/system/cpu/cpu\$c/cpufreq/scaling_cur_freq"
     printf '307200\\n'  > "$FR/sys/devices/system/cpu/cpu\$c/cpufreq/scaling_min_freq"
     printf '2150400\\n' > "$FR/sys/devices/system/cpu/cpu\$c/cpufreq/scaling_max_freq"
   done ;;
esac
exit 0
EOF
chmod +x "$W/reset.sh"

# --- the checks ------------------------------------------------------------------------------------
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
want() { if printf '%s\n' "$2" | grep -Eq -- "$1"; then ok "$3"; else bad "$3"; printf '%s\n' "$2" | grep -n . | sed 's/^/        | /'; fi; }
notwant() { if printf '%s\n' "$2" | grep -Eq -- "$1"; then bad "$3"; printf '%s\n' "$2" | grep -E -- "$1" | sed 's/^/        | /'; else ok "$3"; fi; }
# The verdict is the LAST section, so it is extracted from its own header to the end of the output.
# Anchored on the numbered header and not on the first `->` line anywhere: this probe prints `->` in
# earlier sections, and an extractor that took the first of those would make every verdict assertion
# about a different paragraph.
verdict() { printf '%s\n' "$1" | sed -n '/^== [0-9][0-9]*\. *verdict$/,$p'; }

export FAKE_COMPAT= FAKE_CMDLINE= FAKE_LPM= FAKE_LPMPAR= FAKE_CPUIDLE= FAKE_ZONEDIS= FAKE_COOL= FAKE_GOV=

run() { # $1 = extra arguments (may be empty)
  : > "$ACT"
  "$W/reset.sh"
  # The interpreter by FULL PATH, and `sh`, which is how it runs on the device. `env PATH=... bash`
  # cannot work once PATH is the sandbox: env looks the program up in the NEW PATH.
  # The NULs are stripped from the captured output because the fixture writes device-tree files the way
  # the real ones are written -- with a NUL terminator -- and the probe is expected to read through it.
  # A NUL left in OUT would make grep treat the capture as binary; that is a fact about the harness's
  # string handling, not about the probe, so it is removed here rather than avoided in the fixture.
  OUT="$( env PATH="$STUB:$MINBIN" "$SH_BIN" "$RW" $1 2>&1 | tr -d '\000' )"
  RC=${PIPESTATUS[0]}
}

echo "zl1 sleep and throttle -- offline self-test"
echo "  script under test: $SRC"
echo "  fake device:       $FR"
echo

# ==================================================================================================
echo "== 0. it writes NOTHING -- statically, and then by measuring the device it ran on =="
# ==================================================================================================
HITS="$(writes_in "$SRC")"
if [ -z "$HITS" ]; then
  ok "the shipped probe contains no write to /sys, /proc, a block device, a module or a unit"
else
  bad "the probe contains a write:"
  printf '%s\n' "$HITS" | sed 's/^/        | /'
fi
# Tooth 1: the shape that is most likely here, because this probe reads three WRITABLE files --
# `thermal_zone*/mode` is `enabled`/`disabled` and setting it is one redirect away.
sed 's#^  md=$(rd "$z/mode")$#  md=$(rd "$z/mode"); printf "disabled" > /sys/class/thermal/thermal_zone0/mode#' "$SRC" > "$W/mut-zone.sh"
if cmp -s "$SRC" "$W/mut-zone.sh"; then
  bad "the zone-mode mutation did not land (its sed matches no line), so the guard below proves nothing"
else
  ok "the zone-mode mutation really differs from the shipped file"
  MUT="$(writes_in "$W/mut-zone.sh")"
  if [ -n "$MUT" ]; then
    ok "the guard CATCHES a write to a thermal zone's mode"
    want 'thermal_zone0/mode' "$MUT" "and names the line it found"
  else
    bad "the write guard did not catch a zone mode being set -- it cannot fail, so the check above proves nothing"
  fi
fi
# Tooth 2: the cpuidle `disable` file, which the probe reads and must never write.
sed 's#^    nm=\$(rd "\$s/name"); us=\$(rdn "\$s/usage"); tm=\$(rdn "\$s/time"); dis=\$(rd "\$s/disable")$#    printf "1" > /sys/devices/system/cpu/cpu0/cpuidle/state2/disable#' "$SRC" > "$W/mut-disable.sh"
if cmp -s "$SRC" "$W/mut-disable.sh"; then
  bad "the cpuidle-disable mutation did not land, so that half of the guard proves nothing"
else
  D="$(writes_in "$W/mut-disable.sh")"
  if [ -n "$D" ]; then ok "the guard CATCHES a write to a cpuidle state's disable flag"; else
    bad "the guard let a cpuidle write through"
  fi
fi
# Tooth 2b, and the most tempting write in the whole script: the parameter IS the fix for the question
# this probe asks. `echo 0 > /sys/module/lpm_levels/parameters/sleep_disabled` is one character away from
# the read on the line above it, and a "did the ladder come back" experiment is exactly what somebody
# would be holding in their head while reading this file.
sed 's#^    SYSFS_SD=$(rd "$LPMPAR/sleep_disabled")$#    SYSFS_SD=$(rd "$LPMPAR/sleep_disabled"); printf "0" > /sys/module/lpm_levels/parameters/sleep_disabled#' "$SRC" > "$W/mut-lpmp.sh"
if cmp -s "$SRC" "$W/mut-lpmp.sh"; then
  bad "the sleep_disabled mutation did not land, so that half of the guard proves nothing"
else
  L="$(writes_in "$W/mut-lpmp.sh")"
  if [ -n "$L" ]; then
    ok "the guard CATCHES a write to the lpm_levels parameter -- the fix this probe must not perform"
    want 'lpm_levels/parameters/sleep_disabled' "$L" "and names the line it found"
  else
    bad "the guard let a write to sleep_disabled through -- and that write IS the fix, which is why it must not be here"
  fi
fi

# Tooth 3: the other direction -- an arrow before a path is prose, not a redirect. Without this, the
# rule could be "widened" until it caught the probe's own readings and then removed.
printf 'say "     -> /proc/cmdline could not be read"\n' > "$W/mut-arrow.txt"
[ -z "$(writes_in "$W/mut-arrow.txt")" ] \
  && ok "an arrow before a path is prose, not a write" \
  || bad "an arrow before a path is read as a redirect, so the probe's own readings fail the guard"
printf 'x > /proc/sys/kernel/foo\necho 1 >/sys/module/bar/baz\n' > "$W/mut-redir.txt"
[ -n "$(writes_in "$W/mut-redir.txt")" ] \
  && ok "and a real redirect is still caught, spaced and unspaced" \
  || bad "the redirect rule no longer catches a redirect -- the arrow exclusion went too far"

# Tooth 4, and the strongest one, because the regex has a known blind spot: it only sees writes to an
# ABSOLUTE device path. A script can write `/sys/...` through a variable -- `printf 1 > "$s/disable"` --
# and no regular expression over the source can tell that from a read, because the information is in
# what `$s` was assigned. So the check that actually covers every form is BEHAVIOURAL: run the probe
# against the fake device and require that not one byte of it changed. A file created, deleted,
# resized or edited anywhere under the fake root fails this, whatever the source looked like.
#
# (Both checks are here for that reason. The static one names the line when it fires, which is what a
# human wants at review time; this one is what makes the guarantee true.)
snap() { # $1 = the directory to fingerprint
  ( cd "$1" 2>/dev/null && find . -printf '%y %p %s\n' | sort && find . -type f -exec md5sum {} + 2>/dev/null | sort )
}
FAKE_GOV=performance run ""
SNAP_A="$(snap "$FR")"
run ""
SNAP_B="$(snap "$FR")"
if [ -n "$SNAP_A" ] && [ "$SNAP_A" = "$SNAP_B" ]; then
  ok "a full run left the fake device BYTE-FOR-BYTE identical ($(printf '%s\n' "$SNAP_A" | wc -l | tr -d ' ') lines of manifest)"
else
  bad "the fake device changed across a run -- the probe writes something:"
  diff <(printf '%s\n' "$SNAP_A") <(printf '%s\n' "$SNAP_B") | head -10 | sed 's/^/        | /'
fi
# And the manifest must be able to SEE a change, or the check above proves nothing. `--quiet` is used so
# this does not depend on the probe's own behaviour: the fixture is edited between the two snapshots.
run "--quiet"
S1="$(snap "$FR")"
printf 'disabled\n' > "$FR/sys/class/thermal/thermal_zone0/mode"
S2="$(snap "$FR")"
[ "$S1" != "$S2" ] && ok "and the manifest notices a one-byte change to a file the probe reads" \
                   || bad "the manifest cannot see a one-byte edit, so the check above proves nothing"

# ==================================================================================================
echo
echo "== 1. the guard: not the zl1 =="
# ==================================================================================================
FAKE_COMPAT=qcom,sdm845 run ""
[ "$RC" = 2 ] && ok "a different SoC exits 2" || bad "it exited $RC on the wrong device"
want 'not the zl1' "$OUT" "and says what it is refusing"
notwant 'cpuidle driver' "$OUT" "and reads nothing beyond the guard"
FAKE_COMPAT=

# ==================================================================================================
echo
echo "== 2. --explain reads nothing and says what each reading decides =="
# ==================================================================================================
run "--explain"
[ "$RC" = 0 ] && ok "--explain exits 0" || bad "--explain exited $RC"
want "THE CONSEQUENCE, WHICH IS THE ACTUAL EVIDENCE" "$OUT" "it explains that the counters are the evidence"
want 'a second chance to get it wrong' "$OUT" "and why the temperatures are NOT re-printed here"
want 'cpuidle/state\*/disable' "$OUT" "and names the files it deliberately does not write"
want 'lpm_levels/parameters/sleep_disabled' "$OUT" "including the one that IS the fix, by its full path"
want 'no new boot' "$OUT" "and says why that one matters: the fix is a write, not a boot image"
notwant 'cpuidle driver:' "$OUT" "--explain reads no device file"

# ==================================================================================================
echo
echo "== 3. the baseline: the real device's shape, read end to end =="
# ==================================================================================================
run ""
[ "$RC" = 0 ] && ok "the baseline run exits 0" || bad "it exited $RC"
want 'lpm_levels.sleep_disabled = 1' "$OUT" "the boot's sleep_disabled value is printed as a value"
want 'this boot asked for the low-power modes to be OFF' "$OUT" "and read as what it says"
want 'soc/qcom,lpm-levels: present' "$OUT" "the live ladder node is reported present"
want 'qcom,pm-cluster-level@1 +label=system-ret +latency-us=350' "$OUT" \
  "a system level is read with its label and its declared latency"
want 'qcom,pm-cpu-level@2 +label=cpu-pc +latency-us=80' "$OUT" \
  "AND the per-CPU shape is walked too (the tree has two different level shapes)"
want '8 level\(s\) declared' "$OUT" "and the count is stated"
want 'cpuidle driver: qcom-cpuidle' "$OUT" "the cpuidle driver is named"
want 'deepest state \(state2, pc\) holds 40%' "$OUT" "the deepest state's share is computed as a ratio"
want 'online=\(no online file: cpu0 cannot be offlined\)' "$OUT" "cpu0's missing online file is named, not printed as a blank"
want "cpu3 +online=0" "$OUT" "and an offline core is printed as offline"
want 'cores_mitigation +Y' "$OUT" "the msm_thermal parameters are listed GENERICALLY with their values"
want 'freq_mitig_value +768000' "$OUT" "including one the script could not have known the name of"
want 'cooling devices: NONE REGISTERED' "$OUT" "no cooling devices is reported as the state it is"
want 'tsens_tz_sensor1' "$OUT" "the zones are listed by type"
want 'step_wise' "$OUT" "with their policy"
want 'temperatures are deliberately NOT printed' "$OUT" "and the script says why it prints no temperature"
notwant '999999' "$OUT" "so no raw zone temperature is printed at all"
want 'governor=performance' "$OUT" "the governor is read per core"
want 'PRESENT: 4 of 4 cpu\(s\) are on the .performance. governor' "$(verdict "$OUT")" \
  "and the verdict states the pinned-core cause as PRESENT"

# ==================================================================================================
echo
echo "== 4. the ladder: a node that exists with no levels is not 'the hardware has none' =="
# ==================================================================================================
FAKE_LPM=no-node run ""
want 'no lpm-levels node on this boot' "$OUT" "a missing node says so"
want 'cannot be compared against a declared ladder' "$OUT" "and says what that costs the counters"
notwant 'level\(s\) declared' "$OUT" "and does not claim a ladder it did not read"
FAKE_LPM=empty run ""
want 'the node exists but no level matched' "$OUT" "a node with no levels reports the WALK, not the hardware"
want 'a walk that finds nothing is a reading about this instrument' "$OUT" "and names which side of the reading that is"
FAKE_LPM=

# ==================================================================================================
echo
echo "== 5. UNREADABLE IS NOT ZERO -- the three shapes, and what each must NOT say =="
# ==================================================================================================
# (a) The device tree exists but the probe cannot see the counters at all (no cpuidle directories).
FAKE_CPUIDLE=nodir run ""
want 'no CPU exposes a cpuidle directory' "$OUT" "no cpuidle at all is reported as no cpuidle"
want 'That is UNKNOWN, not zero' "$OUT" "and it says which of the two that is"
want 'LIKELY, BUT UNMEASURED' "$(verdict "$OUT")" "the verdict refuses to conclude from a parameter alone"
want 'UNKNOWN, not proven' "$(verdict "$OUT")" "in those words"
[ "$RC" = 1 ] && ok "and it exits 1 (an answer about the instrument, not the phone)" || bad "it exited $RC"
notwant 'every counter on this CPU is 0' "$OUT" "and it never prints 'the counters are 0' about counters it did not read"
# (b) A directory per CPU with no state directories in it -- present, and empty.
FAKE_CPUIDLE=no-states run ""
want 'has a cpuidle directory with no state directories in it' "$OUT" "an empty cpuidle dir says exactly that"
notwant 'every counter on this CPU is 0' "$OUT" "and is not rounded to 'the counters are 0'"
FAKE_CPUIDLE=
# (c) One non-numeric counter, which the share arithmetic must refuse rather than coerce.
FAKE_CPUIDLE=nonnumeric run ""
want 'could not be read as a number' "$OUT" "a non-numeric counter is reported as such"
want 'NOT computed' "$OUT" "and the share is explicitly not computed"
want 'a number about this script' "$OUT" "with the reason"
notwant 'holds [0-9]+% of this CPU' "$OUT" "no share is printed for a CPU whose counter was unreadable"
FAKE_CPUIDLE=
# (d) The true all-zero case: counters that ARE readable and are zero. This one IS a finding, and it
# must be reachable -- a probe that treats every zero as unreadable is as broken as the reverse.
FAKE_CPUIDLE=zero run ""
want 'every counter on this CPU is 0: it has not entered even state0 since boot' "$OUT" \
  "readable-and-zero is reported as a real reading"
notwant 'holds 0%' "$OUT" "and no share is invented for a CPU whose counters are all zero"
notwant 'could not be read as a number' "$OUT" "and it is not confused with an unreadable counter"
[ "$RC" = 0 ] && ok "a fully-read run exits 0 even when the news is bad" || bad "it exited $RC"
FAKE_CPUIDLE=

# ==================================================================================================
echo
echo "== 6. section 1's TWO halves: the cmdline and the live parameter, kept apart =="
# ==================================================================================================
# Section 1 reads the same question from two places, and docs 121's correction is why: the cmdline is
# what the boot was TOLD, `/sys/module/lpm_levels/parameters/sleep_disabled` is what the DRIVER has, and
# the second one is mode 0664 -- writable -- so it is the half a fix touches. They can disagree, and
# every disagreement shape has to land on its own reading rather than on the nearest one.
#
# (a) The key absent from the cmdline while the driver still reads 1: they DISAGREE, and the verdict
#     must follow the LIVE reading. Reporting ABSENT here would be the same mistake as reporting a zero
#     for a counter that could not be read.
FAKE_CMDLINE=no-sleep-key run ""
want 'lpm_levels.sleep_disabled is NOT set on this boot' "$OUT" "the key absent is reported as absent"
want 'lpm_levels.menu_select=0' "$OUT" "while the OTHER power parameters are still printed"
want 'PRESENT AT THE PARAMETER' "$(verdict "$OUT")" "but the verdict follows the LIVE parameter, not the cmdline"
want 'they DISAGREE' "$OUT" "and section 1 says the two halves disagree"
notwant 'lpm_levels.sleep_disabled = ' "$OUT" "and it does not print a cmdline value it did not read"
FAKE_CMDLINE=
# (b) Both halves agree the ladder is ALLOWED: a cmdline without the key AND the parameter reading 0.
#     This is the only shape that earns ABSENT, and it has to be reachable.
FAKE_CMDLINE=clean FAKE_LPMPAR=zero run ""
want 'ABSENT AT THE PARAMETER' "$(verdict "$OUT")" "cmdline clean and parameter 0: that is ABSENT"
want 'both agree the ladder is ALLOWED' "$OUT" "section 1 reads the two together and says so"
[ "$RC" = 0 ] && ok "and it exits 0 (an absent cause is a measurement, not an unknown)" || bad "it exited $RC"
FAKE_CMDLINE=
# (c) The reverse disagreement, which is what the FIX LOOKS LIKE: the cmdline still asks for the ladder
#     off and the driver has it on. The script must name that shape rather than call it a contradiction.
FAKE_LPMPAR=zero run ""
want 'sleep_disabled = 0' "$OUT" "the live parameter's value is printed as a value"
want 'they DISAGREE' "$OUT" "with the cmdline still asking for it off"
want 'the shape of the fix' "$(verdict "$OUT")" "and the verdict names what wrote to it"
FAKE_LPMPAR=
# (d) The directory present and the parameter absent: the driver did not register it on this boot. That
#     is not the same as "the ladder is allowed", so it must be UNKNOWN and exit 1.
FAKE_LPMPAR=nofile run ""
want 'sleep_disabled: MISSING on this boot' "$OUT" "a missing parameter file says so"
want 'a reading about the DRIVER on this boot' "$OUT" "and says which side of the reading that is"
want 'UNKNOWN: .*could not be read' "$(verdict "$OUT")" "the verdict carries UNKNOWN for that half"
[ "$RC" = 1 ] && ok "a missing parameter file exits 1" || bad "it exited $RC"
FAKE_LPMPAR=
# (e) The whole lpm_levels module directory absent -- a different fault from (d), same verdict.
FAKE_LPMPAR=nodir run ""
want 'MISSING. Either the driver is not in this kernel' "$OUT" "an absent module directory is named"
want 'UNKNOWN: .*could not be read' "$(verdict "$OUT")" "and is UNKNOWN, not ABSENT"
[ "$RC" = 1 ] && ok "an absent lpm_levels directory exits 1" || bad "it exited $RC"
FAKE_LPMPAR=
# (f) The cmdline unreadable while the driver's value IS readable: the live half answers the question, so
#     this run exits 0 -- and it must SAY that the other half is unknown rather than stay silent about it.
FAKE_CMDLINE=missing run ""
want '/proc/cmdline: UNREADABLE' "$OUT" "an unreadable cmdline says so"
want 'UNKNOWN rather than ABSENT' "$OUT" "and is not read as 'no parameter was set'"
want 'The cmdline half is UNKNOWN' "$(verdict "$OUT")" "the verdict notes which half it could not read"
want 'it is what a fix would change' "$(verdict "$OUT")" "and says which half decides"
[ "$RC" = 0 ] && ok "and the readable half is enough to decide, so it exits 0" || bad "it exited $RC"
FAKE_CMDLINE=
# (g) Both halves unreadable is the only shape that makes this cause unanswerable from either side.
FAKE_CMDLINE=missing FAKE_LPMPAR=nodir run ""
want 'neither half of this question has an answer' "$(verdict "$OUT")" "both halves unreadable says exactly that"
[ "$RC" = 1 ] && ok "and it exits 1" || bad "it exited $RC"
FAKE_CMDLINE= FAKE_LPMPAR=

echo "== 7. the kernel's own side: cooling devices, disabled zones, and the governor direction =="
# ==================================================================================================
FAKE_COOL=2 run ""
want 'cooling devices: 2' "$OUT" "registered cooling devices are counted"
want 'cooling_device0 +type=cpu-isolate +cur=0 +max=3' "$OUT" "and listed with their state"
notwant 'NONE REGISTERED' "$OUT" "and not reported as none"
FAKE_COOL=
FAKE_ZONEDIS=1 run ""
want '1 thermal zone\(s\) are in mode .disabled.' "$(verdict "$OUT")" \
  "a zone in mode 'disabled' is called out in the verdict -- its trips cannot fire"
notwant 'enabled' "$(verdict "$OUT")" "and the enabled default is not reported as disabled"
FAKE_ZONEDIS=
# The governor ABSENT direction: the fix installed is the state the verdict must name as ABSENT.
FAKE_GOV=ondemand run ""
want 'ABSENT: no core is on .performance.' "$(verdict "$OUT")" "a scaling governor reads as the cause ABSENT"
want 'governor=ondemand' "$OUT" "and the governor's name is still printed"
FAKE_GOV=none run ""
want 'UNKNOWN: no CPU exposed cpufreq' "$(verdict "$OUT")" "no cpufreq at all is UNKNOWN, not ABSENT"
[ "$RC" = 1 ] && ok "and that exits 1" || bad "it exited $RC"
FAKE_GOV=

# ==================================================================================================
echo
echo "== 8. --quiet keeps the headings, the boot identity and the verdict -- and the SAME decision =="
# ==================================================================================================
run "--quiet"
want 'boot: aaaa-bbbb-cccc' "$OUT" "--quiet keeps the boot identity"
want '== 3\. the consequence' "$OUT" "and the section headings"
notwant 'state0 ' "$OUT" "--quiet drops the per-state counter lines"
notwant 'system-ret' "$OUT" "and the ladder listing"
notwant 'cores_mitigation' "$OUT" "and the driver parameter listing"
want '== 7\. verdict' "$OUT" "--quiet still prints the verdict"
want 'PRESENT: 4 of 4 cpu\(s\) are on the .performance. governor' "$(verdict "$OUT")" \
  "and the verdict is the one the readings support -- not UNKNOWN"
run ""
LOUD_RC=$RC
run "--quiet"
[ "$RC" = "$LOUD_RC" ] && ok "--quiet and a loud run exit the same code on the same device" \
                       || bad "--quiet exited $RC where a loud run exited $LOUD_RC"
# And the UNANSWERED branch must survive --quiet too: that is the one a reader must never miss.
FAKE_CPUIDLE=nodir run "--quiet"
want 'LIKELY, BUT UNMEASURED' "$(verdict "$OUT")" "--quiet still prints the UNANSWERED verdict"
[ "$RC" = 1 ] && ok "with its exit code" || bad "it exited $RC"
FAKE_CPUIDLE=

# ==================================================================================================
echo
echo "== 9. the health check cites this harness's count, and that citation cannot drift =="
# ==================================================================================================
HEALTH="$HERE/zl1-health-check.sh"
if [ -r "$HEALTH" ]; then
  cited=$(tr '\n' ' ' < "$HEALTH" | sed -n 's/.*zl1-sleep-and-throttle-selftest\.sh[^0-9]*\([0-9][0-9]*\) checks.*/\1/p')
  total=$((PASS + FAIL + 1))
  if [ -z "$cited" ]; then
    bad "the health check does not cite this harness's count -- the citation is gone or its wording changed"
  elif [ "$cited" = "$total" ]; then
    ok "the health check cites $cited checks, and this run has exactly that many"
  else
    bad "the health check cites $cited checks, but this harness has $total -- fix host/zl1-health-check.sh"
  fi
else
  bad "cannot read $HEALTH -- its citation is unchecked"
fi

echo
echo "pass=$PASS fail=$FAIL"
[ "$KEEP" = 1 ] || rm -rf "$W"
[ "$FAIL" = 0 ]
