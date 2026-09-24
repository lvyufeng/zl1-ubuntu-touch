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
#     The kernel's own parameter table (checked in the decompressed boot kernel: the strings
#     `lpm_levels.sleep_disabled`, `lpm_levels.sleep_time_override`, `lpm_levels.menu_select`,
#     `lpm_levels.lpm_prediction`, `cpuidle.off` sit together in one __setup table) accepts exactly that
#     knob. A SoC that is told not to sleep stays warm while it is doing nothing -- which is a different
#     symptom from "a process is burning a core", and neither of the two fixes above would touch it.
#
# THAT IS A HYPOTHESIS WITH A NAMED MECHANISM, not a finding. What this script does is measure the
# CONSEQUENCE rather than the parameter: the parameter's name is only evidence, the cpuidle counters are
# evidence of behaviour. A boot with `sleep_disabled=1` whose deep-state time counters are still moving
# would refute the mechanism; a boot whose counters sit at zero is the mechanism having its effect. The
# reading that would settle the semantics of the parameter itself is in the kernel source, which is not
# on this device -- so this script never claims to know what the parameter does, only what is happening.
#
# THE SAFETY LINE, and it is the same one as its siblings:
#   * it writes NOTHING -- no sysfs node, no property, no module, no service, no signal;
#   * it is never even TEMPTED to, and this one needs saying out loud: the cpuidle `disable` files and
#     the thermal zones' `mode`/`policy` ARE writable, and they are exactly the files a script like this
#     would normally "fix" while it is there. It reads them. Changing them is a decision, not a reading,
#     and nothing here takes it;
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

  1. WHAT THIS BOOT WAS TOLD.
     /proc/cmdline, for the power-related parameters only, and printed as whole lines because the value
     is the point (`lpm_levels.sleep_disabled=1` is a sentence; "the parameter is present" is not).
     This is the only place on a running device that records what the boot was given.

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
hdr "1. what this boot was told"
# ==================================================================================================
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
    *) say "      (non-zero = this boot asked for the low-power modes to be OFF. What that does is in"
       say "       the kernel source, which is not on this device; section 3 measures the effect.)";;
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
case "$CAUSE_LPM" in
unknown) always "     UNKNOWN: /proc/cmdline could not be read, so what this boot was told is not known."; UNK=1 ;;
cmdline-clean)
  always "     ABSENT AT THE PARAMETER: this boot was not given lpm_levels.sleep_disabled. Section 3's"
  always "     counters are what say whether the ladder is being used anyway."
  ;;
cmdline-asked)
  case "$CPUIDLE_OK" in
  1) always "     THE PARAMETER IS SET (section 1) and section 3 shows whether the deep states are used."
     always "     Read the two together: the parameter is evidence about intent, the counters are evidence"
     always "     about behaviour, and if the counters are moving the parameter is not having its effect." ;;
  0) always "     LIKELY, BUT UNMEASURED: the boot was told lpm_levels.sleep_disabled=<nonzero> and the"
     always "     cpuidle counters could not be read, so the effect was NOT measured. UNKNOWN, not proven."; UNK=1 ;;
  esac
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
