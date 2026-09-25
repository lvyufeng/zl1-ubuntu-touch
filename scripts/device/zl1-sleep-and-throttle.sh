#!/bin/sh
# zl1 sleep and throttle -- is the SoC ALLOWED to sleep, and what does the kernel do about the heat?
# Read-only. This is the third question about this device's heat, and nobody has asked it.
#
# The first two questions already have answers and, as of 2026-09-24, neither answer is installed:
#
#   * SOMETHING IS BURNING CPU. The v63 debug keeper shells out to systemctl every second and holds
#     about a core of this four-core SoC (docs 72, 94, 99); `install-retire-debug-keeper.sh` retires it.
#   * THE CORES ARE PINNED. The image ships every core on the `performance` governor, i.e. min == max ==
#     the top rung forever (docs 99); `install-cpufreq-governor.sh` puts them on a scaling governor.
#
# Both of those are about the DEMAND side. This script reads the SUPPLY side: whether the hardware's own
# low-power ladder is being used at all. It exists because the offline images say something nobody had
# looked at:
#
#   * The device tree describes a full low-power ladder for this SoC -- `soc/qcom,lpm-levels` with
#     system-wfi / system-ret / system-fpc (whole-SoC wait-for-interrupt, retention, full power
#     collapse), pwr-l2-* and perf-l2-* for the two clusters' L2, and per-CPU levels (wfi / retention /
#     power collapse). Those nodes are in EVERY zl1 DTB in the boot image, and `qcom,use-psci` is set.
#   * And EVERY zl1 boot cmdline -- the stock MIUI-derived one recorded in docs 20, and the port's v63
#     images which inherit it verbatim -- carries:
#
#         lpm_levels.sleep_disabled=1
#
#     The decompressed boot kernel says what that knob IS, and the answer was corrected on 2026-09-24
#     after this script's first version had it wrong: it is a MODULE PARAMETER of the built-in
#     lpm_levels driver, not a __setup boot argument. In the kernel's __param section the entry
#     decodes as {name, ops, mode, arg} with mode **0664** -- owner-writable -- so its sysfs file
#     exists and can be changed while the device runs:
#
#         /sys/module/lpm_levels/parameters/sleep_disabled
#
#     (The entry right beside it, `cpuidle.off`, is 0444: settable on the command line only. The
#     asymmetry matters, because it is the difference between "this needs a new boot image and a
#     flash" and "this is a write".) That is why section 1 reads BOTH the cmdline and this file -- one
#     says what the boot was TOLD, the other says what the driver HAS now, and they can disagree.
#     The byte-level reading and its calibration are in
#     docs/ubuntu-touch/evidence/lpm-sleep-disabled-param-2026-09-24.txt. A SoC that is told not to
#     sleep stays warm while it is doing nothing -- a different symptom from "a process is burning a
#     core", and neither of the two fixes above would touch it.
#
# THAT IS A HYPOTHESIS WITH A NAMED MECHANISM, not a finding. What this script does is measure the
# CONSEQUENCE rather than the parameter: the parameter's name is only evidence, the cpuidle counters are
# evidence of behaviour. A boot with `sleep_disabled=1` whose deep-state time counters are still moving
# would refute the mechanism; a boot whose counters sit at zero is the mechanism having its effect. The
# semantics of the parameter itself USED TO BE UNREADABLE FROM HERE, and that is no longer true: the
# kernel source that built this image is on the host, and `scripts/host/zl1-lpm-sleep-semantics.sh` reads
# the gate out of it (docs 153 -- the parameter makes cpu_power_select() return level index 0, and index 0
# is a bare wfi(), so the ladder is removed from the top rather than a shallower state being chosen).
# THIS script still claims nothing about the mechanism: it measures what is HAPPENING, and the two are
# different kinds of evidence on purpose.
#
# THE SAFETY LINE, and it is the same one as its siblings:
#   * it writes NOTHING -- no sysfs node, no property, no module, no service, no signal;
#   * it is never even TEMPTED to, and this one needs saying out loud: the cpuidle `disable` files, the
#     thermal zones' `mode`/`policy` and now `lpm_levels/parameters/sleep_disabled` itself ARE writable,
#     and they are exactly the files a script like this would normally "fix" while it is there. The
#     last one is the fix for the very question this script asks. It READS it. Changing it is a
#     decision, not a reading, and nothing here takes it;
#   * it opens no block device and unbinds nothing (unbinding cnss on this device is an EDL trip,
#     docs 49).
#
# Usage (on the device, as root):
#   zl1-sleep-and-throttle.sh [--status] [--quiet] [--explain]
#     --status   (default) the readings and the verdict
#     --quiet    the section headings, the boot identity and the verdict -- no readings at all
#     --explain  what each reading decides, and change nothing
#
# Exit codes: 0 every cause was measured; 1 at least one cause is UNKNOWN (a reading could not be
#             taken -- that is not the same as a cause being absent); 2 not the zl1.

set -u

MODE=status
QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
  --status) MODE=status; shift ;;
  --quiet) QUIET=1; shift ;;
  --explain) MODE=explain; shift ;;
  --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
hdr() { printf '\n== %s\n' "$*"; }
always() { printf '%s\n' "$*"; }

# The device guard, the same one the modem probe and the location probe use. `compatible` and not a
# model string: every reading below compares against this port's own numbers and a different SoC would
# report different ones as if they were zl1 readings.
grep -qa msm8996 /proc/device-tree/compatible 2>/dev/null ||
  { echo "not the zl1 (no msm8996 in /proc/device-tree/compatible) -- refusing" >&2; exit 2; }

# `rd` never returns an empty string: a missing file, an empty file and a command that could not run are
# three different answers and this repository has paid for conflating them more than once (docs 117).
rd() { # $1 = path
  if [ -r "$1" ]; then
    v=$(tr -d '\n' < "$1" 2>/dev/null)
    printf '%s' "${v:-EMPTY}"
  else
    printf 'UNREADABLE'
  fi
}
ex() { [ -e "$1" ] && printf 'present' || printf 'MISSING'; }
# THE PARAMETER'S OWN ALPHABET, and this probe reads it for the same reason the two writers write it:
# `sleep_disabled` is declared `static bool` with a `module_param_named(..., bool, ...)` in
# drivers/cpuidle/lpm-levels.c, so the sysfs `show` renders the stored value through the parameter's
# TYPE. The file stores 0 and this file's `rd` returns Y/N, so a reader that asks "is it 0?" asks the
# wrong question and gets a confident wrong answer -- here it would have called a ladder that is ALLOWED
# "OFF", which is the exact inversion of the reading this probe exists to publish. (docs 163: the same
# comparison made the fix's trial refuse a write that had worked, and made the installer report it as
# not installed.) OFF is the three spellings a bool accepts for false; ON is the four for true; anything
# else is a value that is not a state and is reported as such rather than folded into either.
is_off() { case "$1" in 0|N|n|off) return 0 ;; *) return 1 ;; esac; }
is_on()  { case "$1" in 1|Y|y|on)  return 0 ;; *) return 1 ;; esac; }
# A number, or the word that says why there is no number. Never a bare 0 for "could not read" -- that is
# the defect this whole family of scripts keeps recording, and here it would read as "the counters say
# the SoC never slept", which is the very conclusion the script exists to test.
rdn() { # $1 = path
  if [ ! -r "$1" ]; then printf 'UNREADABLE'; return 0; fi
  v=$(tr -d '\n' < "$1" 2>/dev/null)
  case "$v" in
  ''|*[!0-9]*) printf 'NOT-A-NUMBER' ;;
  *) printf '%s' "$v" ;;
  esac
}
# The same "(none)" discipline as the modem probe: `grep ... | sed ... || say none` never reaches its
# none-branch, because in a pipeline the status is the LAST command's and sed succeeds on empty input.
show() { # $1 = file, $2 = ERE, $3 = the "(none: ...)" text, $4 = tail -n
  [ "$QUIET" = 1 ] && return 0
  local out
  out=$(grep -aiE -- "$2" "$1" 2>/dev/null | tail -n "${4:-15}")
  if [ -n "$out" ]; then printf '%s\n' "$out" | sed 's/^/   | /'; else printf '   | %s\n' "$3"; fi
}

if [ "$MODE" = explain ]; then
  cat <<'EOF'
zl1 sleep and throttle -- what each reading decides, and why it is this reading

  1. WHAT THIS BOOT WAS TOLD, AND WHAT THE DRIVER HAS NOW.
     Two readings, because they are two different questions and they can disagree:
       /proc/cmdline, the power-related parameters only, printed as whole lines because the value is
       the point (`lpm_levels.sleep_disabled=1` is a sentence; "the parameter is present" is not);
       and /sys/module/lpm_levels/parameters/sleep_disabled, which is the driver's live value.
     The first is what the boot was GIVEN. The second is what the driver HAS, and it is the one a fix
     would write -- it is mode 0664, so it can be changed while the device runs, with no new boot
     image and no flash (docs 121's correction; the calibration that establishes the mode is in
     evidence/lpm-sleep-disabled-param-2026-09-24.txt).
     This script READS both and writes neither. The `parameters/` directory is listed generically --
     a parameter whose name differs from what this script expects must show up as an extra line, not
     disappear because nothing matched.

  2. THE LADDER THE HARDWARE ACTUALLY HAS.
     /proc/device-tree/soc/qcom,lpm-levels, walked for every level's label and latency. This is read
     from the LIVE device tree, not from a DTB in this repository, because the port may boot a
     different one of the boot image's five DTBs.
     A ladder that EXISTS and is not being used is a different finding from a ladder that is not there,
     so both halves are printed before either is judged.

  3. THE CONSEQUENCE, WHICH IS THE ACTUAL EVIDENCE.
     cpuidle's counters: the driver, and for every CPU every state's name, usage, time and disable flag.
     The parameter's name is evidence about intent; these counters are evidence about behaviour. The
     deepest state's share is printed as a RATIO, because the sysfs ABI's unit for `time` is not stated
     in the file and a ratio cancels whatever it is -- this device reports three different units for
     three different thermal zones, so an unlabelled counter is not to be trusted with arithmetic
     (docs 96 is that lesson).
     Note what this section READS and does not write: `cpuidle/state*/disable` is a writable file whose
     whole purpose is to stop a state being used, and `thermal_zone*/mode` and `policy` are writable in
     the same way. Those three are the files a script like this would normally "fix" in passing. They
     are read here, and changing them is a decision this script does not take.

  4. WHAT THE KERNEL IS DOING ABOUT IT.
     /sys/module/msm_thermal/parameters/* listed generically (this script does not assume the
     parameter names), and /sys/class/thermal/cooling_device* -- because "there are no cooling devices
     registered" is the state `install-cpufreq-governor.sh` noted in prose, and it means the
     cooling-device half of the kernel's thermal framework has nothing to throttle.

  5. THE THERMAL ZONES AS THE KERNEL SEES THEM -- and deliberately NOT their temperatures.
     Zone count, type, mode and policy. `mode` is the one that matters and the one nobody reads: a zone
     in mode `disabled` is a zone whose trips cannot fire. The TEMPERATURES are not printed here on
     purpose: the zones on this device do not share a unit, and `zl1-thermal.sh` owns the table that
     says which is which. A second copy of that table is a second chance to get it wrong.

  6. THE cpufreq SIDE AS IT IS RIGHT NOW.
     Every core's governor and its current/min/max frequencies, and whether the core is online. This is
     the "which half of the known heat is installed" reading: `performance` means the governor fix is
     not in, and the images' own default is `performance`.

  7. THE VERDICT names each of the three known causes with a state of its own -- PRESENT, ABSENT or
     UNKNOWN -- because they are independent and "the phone is hot" does not say which one is running.
     UNKNOWN is what a reading that could not be taken produces, and it makes the script exit 1: it is
     an answer about the instrument, not about the phone.
EOF
  exit 0
fi

always "zl1 sleep and throttle (read-only)"
always "  boot: $(rd /proc/sys/kernel/random/boot_id)"
always "  kernel: $(rd /proc/sys/kernel/osrelease)"

# ==================================================================================================
hdr "1. what this boot was told, and what the driver has now"
# ==================================================================================================
# Initialised before the reads rather than inside their branches: with `set -u` a variable that a
# branch did not reach is a crash, and a crash in the verdict is the worst place for one.
CMDLINE_OK=0; LPM_PARAM_OK=0
CAUSE_LPM=unknown; CAUSE_LPM_SYSFS=unknown; SLEEP_DISABLED=; SYSFS_SD=; LPMPAR=/sys/module/lpm_levels/parameters
# The power-related parameters, by name, as whole lines. `grep -a` because /proc/cmdline is not a text
# file as far as some tools are concerned, and a read that returns nothing must not read as "no
# parameters were set" -- so the read is proved first and the none-branch is named.
if [ -r /proc/cmdline ]; then
  CMDLINE_OK=1
  say "   the power-related parameters this boot was given:"
  CMDHITS=$(tr ' ' '\n' < /proc/cmdline 2>/dev/null | grep -aE '^(lpm_levels|cpuidle|ehci-hcd|qcom_lpm|idle)\.' )
  if [ -n "$CMDHITS" ]; then printf '%s\n' "$CMDHITS" | sed 's/^/     /'
  else say "     (none: this boot was given no lpm_levels.*/cpuidle.*/ehci-hcd.* parameter)"; fi
  # The one this script is about, named separately so its absence is an explicit reading rather than a
  # line that was not there to notice.
  if printf '%s\n' "$CMDHITS" | grep -qa '^lpm_levels\.sleep_disabled='; then
    SLEEP_DISABLED=$(printf '%s\n' "$CMDHITS" | sed -n 's/^lpm_levels\.sleep_disabled=//p' | head -n 1)
    say "   -> lpm_levels.sleep_disabled = ${SLEEP_DISABLED:-EMPTY}"
    case "$SLEEP_DISABLED" in
    0) say "      (0 = the parameter is set to allow sleeping; section 3 still decides what happens)";;
    *) say "      (non-zero = this boot asked for the low-power modes to be OFF. What that DOES is read"
       say "       out of the driver's own source on the host -- scripts/host/zl1-lpm-sleep-semantics.sh,"
       say "       docs 153: level 0, which is a bare wfi(). This script measures the effect, not the"
       say "       mechanism, and it is still the effect that section 3 reports.)";;
    esac
    CAUSE_LPM="cmdline-asked"
  else
    say "   -> lpm_levels.sleep_disabled is NOT set on this boot"
    CAUSE_LPM="cmdline-clean"
  fi
else
  CMDLINE_OK=0
  say "   /proc/cmdline: UNREADABLE. What this boot was told is therefore UNKNOWN -- which is not the"
  say "   same as 'no parameter was set', and the verdict says UNKNOWN rather than ABSENT (docs 117)."
  CAUSE_LPM="unknown"
fi

# --------------------------------------------------------------------------------------------------
# The SAME question from the other side, and the correction this script owes its own first version:
# `lpm_levels.sleep_disabled` is not a __setup boot argument, it is a module parameter of the built-in
# lpm_levels driver with mode 0664 -- i.e. this file exists and is WRITABLE on a running device.
#
# It is read here and NOT written. It is the most tempting file in the whole script -- it is the fix
# for the question the script is asking -- which is exactly why the line is drawn here rather than
# somewhere more convenient. The directory is listed generically so an unexpected parameter name is a
# line of output instead of a silence.
# --------------------------------------------------------------------------------------------------
if [ -d "$LPMPAR" ]; then
  LPM_PARAM_OK=1
  say "   /sys/module/lpm_levels/parameters/ (read, not written):"
  LPMLS=$(ls -1 "$LPMPAR" 2>/dev/null | tr '\n' ' ')
  if [ -n "$LPMLS" ]; then say "     $LPMLS"
  else say "     (none: the directory is there and holds no parameters)"; fi
  if [ -e "$LPMPAR/sleep_disabled" ]; then
    SYSFS_SD=$(rd "$LPMPAR/sleep_disabled")
    CAUSE_LPM_SYSFS="read"
    SYSFS_MODE=$(ls -l "$LPMPAR/sleep_disabled" 2>/dev/null | awk '{print $1}')
    say "   -> sleep_disabled = $SYSFS_SD  (mode ${SYSFS_MODE:-UNREADABLE})"
    case "$SYSFS_SD" in
    0|N|n|off) say "      (this is this file's rendering of 0: the driver's ladder is ALLOWED. Section 3"
               say "       still decides whether it is used.)";;
    1|Y|y|on)  say "      (this is this file's rendering of 1: the driver has it OFF, right now. Non-zero"
               say "       is what the cmdline asks for too.)";;
    *) say "      (neither OFF (0/N/off) nor ON (1/Y/on) -- reported as read, not interpreted)";;
    esac
  else
    say "   -> $LPMPAR/sleep_disabled: MISSING on this boot."
    say "      The parameter is in the kernel (mode 0664 in the __param section), so its absence here"
    say "      is a reading about the DRIVER on this boot -- e.g. lpm-levels did not probe -- and NOT"
    say "      about the knob. The verdict reports UNKNOWN for this half rather than ABSENT."
    CAUSE_LPM_SYSFS="unknown"
  fi
else
  LPM_PARAM_OK=0
  say "   $LPMPAR: MISSING. Either the driver is not in this kernel (it is: the __param entry is in"
  say "   the boot image) or it did not register -- which is itself a reading. UNKNOWN, not ABSENT."
  CAUSE_LPM_SYSFS="unknown"
fi
# The two halves read together, because a disagreement is the interesting case: the cmdline says what
# the boot was told, the sysfs file says what the driver has, and if they differ then somebody wrote to
# it (which is what the fix does) or the driver never consumed it.
if [ "$CMDLINE_OK" = 1 ] && [ "$LPM_PARAM_OK" = 1 ]; then
  CMD_ASKED=no
  case "$CAUSE_LPM" in cmdline-asked) CMD_ASKED=yes ;; esac
  SYS_ON=other
  if is_off "$SYSFS_SD"; then SYS_ON=no
  elif is_on "$SYSFS_SD"; then SYS_ON=yes
  fi
  if [ "$SYS_ON" = other ]; then
    say "   => the driver's value ('$SYSFS_SD') is not one this script can read as a state, so the two"
    say "      halves are NOT compared -- they are reported side by side above and left as they are."
  elif [ "$CMD_ASKED" = yes ] && [ "$SYS_ON" = yes ]; then
    say "   => both agree the ladder is OFF (cmdline asked for it; the driver has it off)."
  elif [ "$CMD_ASKED" = no ] && [ "$SYS_ON" = no ]; then
    say "   => both agree the ladder is ALLOWED. If section 3 still shows no deep-state time, then the"
    say "      ladder being off is NOT the explanation and this cause is refuted for this boot."
  elif [ "$CMD_ASKED" = no ] && [ "$SYS_ON" = yes ]; then
    say "   => they DISAGREE: this boot's cmdline did not ask for sleep to be off, and the driver has"
    say "      it off anyway. Something wrote to $LPMPAR/sleep_disabled."
  else
    say "   => they DISAGREE: the cmdline asked for sleep to be off and the driver has it ON. That is"
    say "      what a fix that writes to $LPMPAR/sleep_disabled looks like from here."
  fi
fi

# ==================================================================================================
hdr "2. the low-power ladder the hardware has"
# ==================================================================================================
# Read from the LIVE device tree. The path is written out rather than globbed at the top level: a glob
# would silently match nothing on a kernel that names the node differently, and "nothing matched" is
# exactly the reading that must not be confused with "there is no ladder".
LPMDT=/proc/device-tree/soc/qcom,lpm-levels
LPM_EXISTS=$(ex "$LPMDT")
LPM_LEVELS=0
# A RECURSIVE walk, and it is recursive for a reason worth writing down: the first version globbed three
# fixed depths, and the DT's shape defeated it. The levels do NOT all sit at the same depth -- the
# whole-SoC ones are `qcom,pm-cluster@0/qcom,pm-cluster-level@N`, the two L2 clusters add a level of
# nesting, and the per-CPU ones are under a `qcom,pm-cpu` node whose own children are `@N` -- so a fixed
# pattern found the L2 and per-CPU levels and silently missed the three deepest system levels, which are
# precisely the ones this script is about. A walk that MISSES levels reports a shorter ladder than the
# hardware declared and nothing says so. (The offline harness caught it: it asserts a specific system
# level by name, and that assertion is why the shape is now walked instead of guessed.)
lpm_walk() { # $1 = a directory in the lpm-levels subtree
  for d in "$1"/*; do
    [ -d "$d" ] || continue
    case "$(basename "$d")" in
    qcom,pm-cluster-level@*|qcom,pm-cpu-level@*)
      LPM_LEVELS=$((LPM_LEVELS + 1))
      say "     $(printf '%-22s' "$(basename "$d")") label=$(printf '%-14s' "$(rd "$d/label")") latency-us=$(rd "$d/qcom,latency-us")"
      ;;
    esac
    lpm_walk "$d"
  done
}
say "   ${LPMDT}: ${LPM_EXISTS}"
if [ -d "$LPMDT" ]; then
  say "   the levels it declares (label, latency):"
  lpm_walk "$LPMDT"
  if [ "$LPM_LEVELS" = 0 ]; then
    say "     (the node exists but no level matched -- that is NOT 'there are no levels': the walk found"
    say "      nothing, and a walk that finds nothing is a reading about this instrument)"
  else
    say "   -> ${LPM_LEVELS} level(s) declared. A ladder that exists is what makes section 3's counters"
    say "      meaningful: with no levels declared, a zero counter would say nothing about the boot."
  fi
else
  say "   -> no lpm-levels node on this boot. Section 3's counters still measure whether the CPUs idle"
  say "      at all, but they cannot be compared against a declared ladder."
fi

# ==================================================================================================
hdr "3. the consequence: what the cpuidle counters say actually happened"
# ==================================================================================================
CPUIDLE_OK=0
DRV=$(rd /sys/devices/system/cpu/cpuidle/current_driver)
say "   cpuidle driver: ${DRV}"
if [ "$DRV" = UNREADABLE ]; then
  say "     -> no driver file: cpuidle may be off entirely (the kernel's own parameter table accepts"
  say "        cpuidle.off -- see section 1) or this kernel exposes none here."
fi
CPU_GLOB=/sys/devices/system/cpu/cpu[0-9]*
CPUS=0
for c in $CPU_GLOB; do
  [ -d "$c/cpuidle" ] || continue
  CPUS=$((CPUS + 1))
  n=$(basename "$c")
  [ "$QUIET" = 0 ] && say "   ${n}:"
  # NOTE the shape of this loop: the counters are TALLIED whatever the verbosity, and only the PRINTING
  # is guarded. An earlier version `continue`d the whole body under --quiet, which left the tallies at
  # their initial values -- so a --quiet run's verdict reported the cpuidle cause as UNKNOWN on a device
  # the same run had just read. --quiet may change what is shown; it may not change what is decided.
  tot=0; tot_ok=1; deep_name=UNKNOWN; deep_time=UNKNOWN; deep_idx=-1; idx=-1
  for s in "$c"/cpuidle/state[0-9]*; do
    [ -d "$s" ] || continue
    idx=$((idx + 1))
    nm=$(rd "$s/name"); us=$(rdn "$s/usage"); tm=$(rdn "$s/time"); dis=$(rd "$s/disable")
    [ "$QUIET" = 0 ] && say "     state${idx} $(printf '%-14s' "$nm") usage=$(printf '%-10s' "$us") time=$(printf '%-12s' "$tm") disable=${dis}"
    case "$tm" in
    UNREADABLE|NOT-A-NUMBER) tot_ok=0 ;;
    *) tot=$((tot + tm)) ;;
    esac
    # The DEEPEST state is the one with the largest index: sysfs numbers them shallowest first, and the
    # last directory in the sorted glob is that one.
    deep_name="$nm"; deep_time="$tm"; deep_idx=$idx
  done
  if [ "$idx" -lt 0 ]; then
    say "     -> this CPU has a cpuidle directory with no state directories in it: nothing to count."
  elif [ "$tot_ok" = 1 ] && [ "$deep_time" != UNREADABLE ] && [ "$deep_time" != NOT-A-NUMBER ]; then
    CPUIDLE_OK=1
    if [ "$tot" -gt 0 ]; then
      say "     -> deepest state (state${deep_idx}, ${deep_name}) holds $((deep_time * 100 / tot))% of this CPU's counted idle time"
    else
      say "     -> every counter on this CPU is 0: it has not entered even state0 since boot"
    fi
  else
    say "     -> a counter on this CPU could not be read as a number, so its share is NOT computed. A"
    say "        share made from an unreadable counter would be a number about this script."
  fi
done
if [ "$CPUS" = 0 ]; then
  say "   no CPU exposes a cpuidle directory -- cpuidle is not present on this boot, so the 'is the SoC"
  say "   sleeping' question has NO answer from counters. That is UNKNOWN, not zero."
fi

# ==================================================================================================
hdr "4. what the kernel is doing about the heat"
# ==================================================================================================
# Generic listing on purpose: this script must not assume the parameter names of a kernel it did not
# build. Each file's contents are printed with its own name beside them.
MTH=/sys/module/msm_thermal
if [ -d "$MTH" ]; then
  say "   ${MTH} is present (the driver is loaded; its DT node carries poll-ms, the trip temperatures,"
  say "   and qcom,freq-mitigation-value -- the kernel-side mitigation this port has never measured):"
  if [ "$QUIET" = 0 ]; then
    for f in "$MTH"/parameters/*; do
      [ -e "$f" ] || continue
      say "     $(printf '%-34s' "$(basename "$f")") $(rd "$f")"
    done
  fi
else
  say "   ${MTH} is ABSENT: the msm_thermal driver is not loaded on this boot. The device tree has a"
  say "   node for it, so this is a driver that did not bind rather than a device without one."
fi

COOL=0
for c in /sys/class/thermal/cooling_device[0-9]*; do
  [ -d "$c" ] || continue
  COOL=$((COOL + 1))
  say "   $(printf '%-20s' "$(basename "$c")") type=$(printf '%-20s' "$(rd "$c/type")") cur=$(printf '%-6s' "$(rd "$c/cur_state")") max=$(rd "$c/max_state")"
done
if [ "$COOL" = 0 ]; then
  say "   cooling devices: NONE REGISTERED. The kernel's cooling-device framework has nothing to throttle"
  say "   with, so any mitigation on this device is the driver's own path (above) or nothing."
else
  say "   cooling devices: ${COOL}"
fi

# ==================================================================================================
hdr "5. the thermal zones as the kernel sees them -- mode and policy, NOT temperature"
# ==================================================================================================
ZONES=0
ZONE_DISABLED=0
for z in /sys/class/thermal/thermal_zone[0-9]*; do
  [ -d "$z" ] || continue
  ZONES=$((ZONES + 1))
  md=$(rd "$z/mode")
  case "$md" in disabled) ZONE_DISABLED=$((ZONE_DISABLED + 1));; esac
  say "   $(printf '%-34s' "$(basename "$z")") type=$(printf '%-18s' "$(rd "$z/type")") mode=$(printf '%-10s' "$md") policy=$(rd "$z/policy")"
done
if [ "$ZONES" = 0 ]; then
  say "   no thermal zones at all: this kernel exposes none, so nothing here can trip on temperature."
else
  say "   zones: ${ZONES}; disabled: ${ZONE_DISABLED}"
  say "   temperatures are deliberately NOT printed: the zones on this device use three different units"
  say "   (docs 96) and zl1-thermal.sh owns the table that says which zone uses which."
fi

# ==================================================================================================
hdr "6. the cpufreq side, right now"
# ==================================================================================================
# This is the "is the governor fix installed" reading. `performance` on every core is the image's own
# default and is what docs 99 measured; a scaling governor means somebody changed it.
GOV_PERF=0
CORES=0
for c in $CPU_GLOB; do
  [ -d "$c/cpufreq" ] || continue
  CORES=$((CORES + 1))
  n=$(basename "$c")
  on=$(rd "$c/online")
  [ "$on" = UNREADABLE ] && on="(no online file: cpu0 cannot be offlined)"
  gov=$(rd "$c/cpufreq/scaling_governor")
  case "$gov" in performance) GOV_PERF=$((GOV_PERF + 1));; esac
  say "   $(printf '%-8s' "$n") online=$(printf '%-16s' "$on") governor=$(printf '%-14s' "$gov") cur=$(printf '%-10s' "$(rd "$c/cpufreq/scaling_cur_freq")") min=$(printf '%-10s' "$(rd "$c/cpufreq/scaling_min_freq")") max=$(rd "$c/cpufreq/scaling_max_freq")"
done
if [ "$CORES" = 0 ]; then
  say "   no CPU exposes cpufreq -- the governor question has NO answer on this boot."
fi

# ==================================================================================================
hdr "7. verdict"
# ==================================================================================================
# Three independent causes, each with a state of its own. `UNKNOWN` is deliberately not folded into
# ABSENT: an unread counter is a fact about this instrument, and this repository has four scripts that
# had to learn that one at a time (docs 117).
UNK=0
always "   cause 1 -- the cores are pinned on a fixed frequency (docs 99):"
case "$CORES" in
0) always "     UNKNOWN: no CPU exposed cpufreq, so nothing was read."; UNK=1 ;;
*)
  if [ "$GOV_PERF" -gt 0 ]; then
    always "     PRESENT: ${GOV_PERF} of ${CORES} cpu(s) are on the 'performance' governor, i.e. pinned."
    always "     The fix is install-cpufreq-governor.sh --install (mine changes scaling, nothing else)."
  else
    always "     ABSENT: no core is on 'performance' (${GOV_PERF}/${CORES}); a scaling governor is in."
  fi
  ;;
esac
always "   cause 2 -- something is burning CPU (docs 72/94):"
always "     NOT MEASURED HERE, ON PURPOSE: that needs a tick-delta window over /proc/<pid>/stat, and"
always "     zl1-thermal.sh measures exactly that (its --ab mode is the doc 72 A/B). Read it there; a"
always "     second implementation of the same window is a second chance to get the arithmetic wrong."
always "   cause 3 -- the SoC is not allowed to use its low-power modes:"
# The verdict is built on the SYFS reading when there is one, because that is what the driver has NOW --
# the cmdline reading is what the boot was told, and the two can differ (section 1 says when). This is
# the correction docs 121 had to make: the parameter is a module parameter with mode 0664, so the file
# exists on a running device and a fix is a write to it rather than a new boot image.
case "$CAUSE_LPM_SYSFS" in
read)
  if [ "$CMDLINE_OK" != 1 ]; then
    always "     (The cmdline half is UNKNOWN -- /proc/cmdline could not be read -- so what this boot was"
    always "      TOLD is not known. The reading below is the driver's live value, and it is the one that"
    always "      decides this cause: it is what a fix would change.)"
  fi
  if is_off "$SYSFS_SD"; then
    always "     ABSENT AT THE PARAMETER: ${LPMPAR}/sleep_disabled reads ${SYSFS_SD}, which is this file's"
    always "     rendering of 0 -- so the driver's ladder is ALLOWED right now. Section 3's counters are"
    always "     what say whether it is then used."
    if [ "$CAUSE_LPM" = cmdline-asked ]; then
      always "     (Note the disagreement with section 1: this boot's cmdline asked for it off and the"
      always "      driver has it on, so SOMETHING WROTE TO IT after boot -- that is the shape of the fix.)"
    fi
  else
    always "     PRESENT AT THE PARAMETER: ${LPMPAR}/sleep_disabled reads ${SYSFS_SD} -- the driver has"
    always "     the low-power modes OFF right now, and that file is mode 0664, i.e. WRITABLE while the"
    always "     device runs. So the fix for this cause is a WRITE, not a new boot image: no flash and no"
    always "     reboot, and it can be measured and reverted inside one boot."
    case "$CPUIDLE_OK" in
    1) always "     Section 3's counters say whether it is having its effect. Read the two together: the"
       always "     parameter is evidence about intent, the counters are evidence about behaviour, and if"
       always "     the counters are still moving the parameter is not having its effect." ;;
    0) always "     LIKELY, BUT UNMEASURED: the parameter says the ladder is off and the cpuidle counters"
       always "     could not be read, so the effect was NOT measured. UNKNOWN, not proven."; UNK=1 ;;
    esac
  fi
  ;;
unknown)
  always "     UNKNOWN: ${LPMPAR}/sleep_disabled could not be read, so what the driver has NOW is not"
  always "     known -- and that is the half a fix would touch."
  case "$CAUSE_LPM" in
  unknown) always "     (/proc/cmdline was unreadable too, so neither half of this question has an answer.)" ;;
  *) always "     (/proc/cmdline WAS readable: this boot was given lpm_levels.sleep_disabled=${SLEEP_DISABLED:-<unset>}.)" ;;
  esac
  UNK=1
  ;;
esac
always "   and the kernel's own side, for completeness:"
if [ "$COOL" = 0 ]; then
  always "     there are no cooling devices registered, so there is no cooling-device throttling to tune;"
else
  always "     ${COOL} cooling device(s) registered."
fi
if [ "$ZONE_DISABLED" -gt 0 ]; then
  always "     ${ZONE_DISABLED} thermal zone(s) are in mode 'disabled' -- their trips cannot fire."
fi
if [ "$UNK" != 0 ]; then
  always "   -> UNANSWERED IN PART: at least one cause is UNKNOWN above. That is a statement about the"
  always "      readings, not about the phone, and it exits 1 for that reason."
  exit 1
fi
always "   -> every cause was measured on this boot; the states above are what it is doing."
exit 0
