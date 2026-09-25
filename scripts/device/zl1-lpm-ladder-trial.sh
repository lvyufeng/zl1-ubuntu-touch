#!/bin/sh
# zl1 LPM ladder trial -- is `sleep_disabled` the thing that gates the SoC's low-power ladder?
#
# Read-only by default. With --apply it writes EXACTLY ONE FILE, and then puts it back.
#
# WHY THIS EXISTS (docs 121, and the correction in its section 5.5):
#
#   Every zl1 boot is given `lpm_levels.sleep_disabled=1` -- the stock MIUI-derived cmdline recorded in
#   docs 20, inherited verbatim by every v63 image. The same boot kernel says what that knob IS:
#   a MODULE PARAMETER of the built-in lpm_levels driver with mode 0664, i.e. writable while the device
#   runs (the entry beside it, `cpuidle.off`, is 0444 -- command line only). So the fix for this cause
#   does NOT need a new boot image and does NOT need a flash: it is
#
#       printf 0 > /sys/module/lpm_levels/parameters/sleep_disabled
#
#   That is what this script does, once, with a revert, and only when asked. docs 121 says twice that
#   the reading it rests on is a HYPOTHESIS: 0664 proves the file is writable, NOT that writing to it
#   changes what the SoC does. This script is the experiment that decides, and it is built to be able
#   to REFUTE the hypothesis rather than to demonstrate it -- see the verdict, section 6.
#
# WHY IT REFUSES, AND WHY THE REFUSALS ARE THE POINT:
#
#   On this device a hang is not a hang, it is an EDL trip that costs 10-20 s of holding the power
#   button and that only a person can end (docs 49 section 6). The ladder this experiment switches on
#   has, as far as every image in this repository shows, NEVER RUN on this device. So the experiment
#   is allowed to proceed only when three things are true, and each refusal names which one is not:
#
#     A. THE PANIC -> EDL ESCALATION IS DISARMED. `download_mode` (a 0644 module param of the poweroff
#        driver, compiled in as 1) is what turns a panic into a device that sits in EDL (docs 86).
#        `install-no-edl-on-panic.sh --install` writes 0 to it, and it clears EVERY such parameter. This
#        trial refuses unless every one of them reads 0 -- reading the first match would let the gate be
#        satisfied by a knob that is not the one the policy clears (docs 125; the device was measured to
#        expose exactly one, `/sys/module/msm_poweroff/parameters/download_mode`, so this is about the
#        gate being about the same thing the writer writes). This trial REFUSES to run without it,
#        because the difference is exactly "a hang reboots the phone" versus "a hang costs a finger".
#        It also means this trial never has to argue that it cannot hang.
#     B. THE COUNTERS ARE READABLE. The whole experiment is a before/after on cpuidle's usage/time, so a
#        boot where those cannot be read has nothing to measure. UNREADABLE IS NOT ZERO, and here a
#        zero would look exactly like "the ladder came on and was never entered".
#     C. NOTHING IS BURNING A CORE. The v63 debug keeper shells out to systemctl every second and holds
#        about a core of this four-core SoC (docs 72/94/99). A CPU that is never idle does not enter a
#        deep idle state -- so with the keeper running, "no deep-state time" would be a reading about
#        the KEEPER, not about `sleep_disabled`. That confounding is the whole reason this is a refusal
#        and not a warning; `--allow-keeper` overrides it and the verdict says the reading is confounded.
#     D. THE PARAMETER IS ON, i.e. the before-window is a BASELINE (docs 163). If it is already off,
#        somebody wrote it -- possibly a previous run of this script whose revert did not happen -- and
#        cpuidle's counters are cumulative since boot, so they already hold entries made while the ladder
#        was ALLOWED. The verdict's test is whether the deep state had EVER been entered before the write,
#        so on a boot like that the test answers about the previous writer. Measured 2026-09-25: this
#        state produced a REFUTED verdict that inverted its own data (0 entries in 4h42m with the
#        parameter on; 162874 in the 31 minutes after a previous run left it off). Nothing in this script
#        can clear a cumulative counter, so the remedy is `--revert` and a REBOOT -- the cmdline sets 1
#        again and the counters start at zero.
#
#   Every refusal leaves the device EXACTLY as it was: nothing is written before all of them are checked.
#
# THE SAFETY ARGUMENTS, and they are structural rather than promises:
#
#   * The write is one file, and it is not persistent. `sleep_disabled` is restored to 1 by the next
#     boot from the cmdline -- the same line that made it 1 in the first place -- so this experiment is
#     scoped to ONE boot by construction. There is nothing to "put back" across a reset, and a reboot is
#     therefore both the escape hatch and the undo.
#   * IT REVERTS ON EVERY EXIT PATH. A `trap` puts the parameter back on a normal end, on an error and
#     on INT/TERM/HUP, and a revert one-liner is written to a file ON THE DEVICE (/tmp) before the write,
#     so the usual way to lose this session -- the netwatch re-enumerating the USB gadget, docs 118 --
#     leaves the undo where the device can reach it and not only where the session could.
#     AND THE TRAP IS ARMED BY THE WRITE'S OWN REDIRECT, not by a read-back: the flag it gates on used to
#     be set AFTER the read-back check, so the path that leaves the file changed without knowing it is
#     exactly the path that left the trap disarmed. Measured on the device on 2026-09-25 -- the parameter
#     sat at N with this script's exit already behind it. See the comment at the write in section 6.
#   * The write path is PROVED before it is used to change anything: the current value is written back
#     to itself and read, and if the read-back does not match, this script stops having changed nothing.
#     A sysfs file that cannot be written is a fact to discover BEFORE the experiment, not after.
#     THAT PROOF IS NOT ABOUT THE ALPHABET, and it cannot be: writing back what was just read passes on a
#     file of any type. The one write whose value CHANGES is section 6, and it is compared as a STATE
#     (0/N/off versus 1/Y/on) rather than as a string -- `sleep_disabled` is a bool module parameter
#     (lpm-levels.c), so sysfs renders 0 as N and this script demanded the string it wrote instead.
#   * There is deliberately NO background timer, and the reason is the same fact: a value that does not
#     survive a reboot does not need one. Losing the session is not a state that needs undoing -- the
#     next boot is the undo -- and a timer that fires on its own is one more thing that can write to
#     this file without anybody deciding to. The `trap` covers every exit this script can take.
#
# WHAT IT DOES NOT DO: no block device is opened, no partition is written, nothing is flashed, no module
# is loaded or unloaded, no service is started or stopped, and no process is signalled. It reads the
# thermal zones but does NOT print their temperatures and does NOT measure heat -- `zl1-thermal.sh`
# owns that table and its units (docs 96), and a second copy of it is a second chance to get it wrong.
# The heat A/B around this experiment is `zl1-thermal.sh --ab` on either side of it.
#
# Usage (on the device, as root):
#   zl1-lpm-ladder-trial.sh [--status] [--apply] [--revert] [--settle SECS] [--keep] [--allow-keeper]
#     --status   (default) read everything, write nothing: the three prerequisites, whether the
#                before-window is a BASELINE (baseline D), the parameter, the counters, and what a trial
#                would do
#     --apply    run the trial: prerequisites + baseline, same-value write proof, write 0, settle, read
#                the counters, revert, verdict
#     --revert   put the parameter back to 1 and verify it (the one command to run if anything is odd)
#     --settle S seconds to wait between the write and the second reading (default 120)
#     --keep     do NOT revert at the end -- for a longer observation. The exact revert command is printed
#     --allow-keeper  proceed with the debug keeper running; the verdict marks the reading confounded
#     --explain  what each reading decides, and change nothing
#
# Exit codes: 0 the trial ran and the verdict is a measurement about the ladder -- including REFUTED, which is a measurement and comes out against the thing this script was built to test;
#             1 the verdict is INCONCLUSIVE or CONFOUNDED -- the run cannot be used as the answer (a statement about the trial, not about the phone);
#             2 not the zl1;
#             3 REFUSED -- a prerequisite or the baseline (D) is not met and nothing was written;
#             4 the write happened and something went wrong after it (the state and the revert are printed, and the trap has already tried to undo it).

set -u

MODE=status
SETTLE=120
KEEP=0
ALLOW_KEEPER=0
PARAM=
MYPID=$$

while [ $# -gt 0 ]; do
  case "$1" in
  --status) MODE=status; shift ;;
  --apply) MODE=apply; shift ;;
  --revert) MODE=revert; shift ;;
  --settle) SETTLE="${2:-}"; shift 2 ;;
  --keep) KEEP=1; shift ;;
  --allow-keeper) ALLOW_KEEPER=1; shift ;;
  --explain) MODE=explain; shift ;;
  --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

say() { printf '%s\n' "$*"; }
hdr() { printf '\n== %s\n' "$*"; }
bad() { printf '%s\n' "$*" >&2; }

# The device guard, the same one this repository's other probes use: `compatible`, not a model string.
grep -qa msm8996 /proc/device-tree/compatible 2>/dev/null ||
  { bad "not the zl1 (no msm8996 in /proc/device-tree/compatible) -- refusing"; exit 2; }

rd() { # a missing file, an empty file and a command that could not run are three different answers
  if [ -r "$1" ]; then v=$(tr -d '\n' < "$1" 2>/dev/null); printf '%s' "${v:-EMPTY}"
  else printf 'UNREADABLE'; fi
}
rdn() { # a number, or the word that says why there is no number -- never a bare 0 for "could not read"
  if [ ! -r "$1" ]; then printf 'UNREADABLE'; return 0; fi
  v=$(tr -d '\n' < "$1" 2>/dev/null)
  case "$v" in ''|*[!0-9]*) printf 'NOT-A-NUMBER' ;; *) printf '%s' "$v" ;; esac
}

# THE PARAMETER'S OWN ALPHABET. `sleep_disabled` is declared as
#
#     static bool sleep_disabled;
#     module_param_named(sleep_disabled, sleep_disabled, bool, S_IRUGO | S_IWUSR | S_IWGRP);
#
# in `drivers/cpuidle/lpm-levels.c` of the tree that built this kernel (lines 125-127), so the sysfs
# `show` renders the stored value THROUGH THE PARAMETER'S TYPE: the file stores 0/1 and reads back Y/N.
# Writing `0` and reading `N` is therefore a write that HELD, and nothing here may compare a value with
# its own rendering -- that comparison can only ever pass on a file with no type.
#
# This is measured, not reasoned. Until 2026-09-25 this script compared the read-back to the string it
# had written, so on the device it refused its own successful write (`read-back is 'N' (wanted 0)`),
# exited 4, and the third heat cause stayed uninstalled while the parameter sat at N for 13 minutes with
# nothing owning it. `scripts/host/zl1-lpm-sleep-semantics.sh` has quoted that module_param statement
# verbatim as "the one statement that carries the type" since docs 153 -- the tree knew, and its two
# writers did not ask.
#
# AND THE SAME-VALUE PROOF IN SECTION 5 CANNOT CATCH THIS, which is why it is the wrong place to look:
# writing back what was just read is alphabet-independent by construction, so it passes on any file. The
# alphabet only ever bites on the one write whose value CHANGES -- the write this whole script exists to
# make. `scripts/install-lpm-sleep-fix.sh` carries the same two readings for the same reason.
is_off() { case "$1" in 0|N|n|off) return 0 ;; *) return 1 ;; esac; }
is_on()  { case "$1" in 1|Y|y|on)  return 0 ;; *) return 1 ;; esac; }

# --------------------------------------------------------------------------------------------------
# The revert, and the trap that makes it happen on every exit path.
#
# `WROTE` is set the moment the parameter's value has actually been changed, and only then: the trap must
# never write the file on a refusal, on --status, or on a run that failed before the write -- those are
# the paths where "wrote nothing" is the guarantee being made, and a trap that fires anyway would break
# exactly the promise this script is built around. It also means the trap's own read-back is meaningful:
# it can only report an undo that was needed.
#
# `KEEP` is the one case where leaving 0 behind is the point, and the trap honours it -- so `--keep`
# cannot leave a value the script would otherwise put back while nobody is looking.
# --------------------------------------------------------------------------------------------------
WROTE=0
REVERT_CMD=printf_1_THE_PARAMETER_LATER   # replaced once the path is known; never run as it stands
do_revert() {
  [ "$WROTE" = 1 ] || return 0
  [ "$KEEP" = 1 ] && return 0
  printf '1' > "$PARAM" 2>/dev/null
  P_REVERT=$(rd "$PARAM")
  if is_on "$P_REVERT"; then
    say "   [trap] $PARAM put back to 1 (it reads '$P_REVERT'), verified by read-back."
  else
    bad "   [trap] THE REVERT DID NOT HOLD: $PARAM reads '$P_REVERT', which is not ON. Run --revert, and"
    bad "   note that the next boot sets it to 1 from the cmdline anyway."
  fi
}
trap 'do_revert' EXIT INT TERM HUP

if [ "$MODE" = explain ]; then
  cat <<'EOF'
zl1 LPM ladder trial -- what each reading decides, and why it is this reading

  1. THE PREREQUISITES, checked before anything is written. Each one is a way this experiment
     could produce a reading that MEANS SOMETHING ELSE:
       download_mode = 0        otherwise a hang is an EDL trip and not a reboot.
       cpuidle readable         otherwise "no deep-state time" is indistinguishable from an unread file.
       no debug keeper          otherwise a CPU that is never idle reports "the ladder was not entered"
                                for a reason that has nothing to do with the parameter being tested.
       the parameter is ON      otherwise the counters already hold entries made while the ladder was
                                ALLOWED, and "were the deep states entered before the write" answers
                                about whoever wrote 0 last instead of about this parameter. Measured
                                2026-09-25: that state produced a REFUTED verdict that inverted its
                                own data. The remedy is --revert and a reboot, because the counters are
                                cumulative since boot and nothing in this script can clear them.
     A fifth thing is reported and not gated: whether the deepest state is `disable`d. A state that is
     disabled by that separate mechanism cannot be expected to move whatever this script writes, so the
     verdict calls that case confounded instead of concluding anything from it.

  2. WHAT THE PARAMETER IS NOW: its value and its MODE. The mode is the reason this experiment exists
     at all -- 0664 is what makes it a write instead of a flash (docs 121 section 5.5).

  3. THE BEFORE READING. Every core's every cpuidle state's `usage` and `time`, recorded as the number
     it is. This is the half that makes a REFUTATION possible: if the deep states were ALREADY being
     entered before the write, then the parameter does not gate them, and the hypothesis is dead
     regardless of what happens after.

  4. THE SAME-VALUE WRITE. The current value is written back to itself and read. It changes nothing, and
     it is the only way to know that the file can be written and read before a change is made that
     depends on it. If it does not read back, this script stops WITHOUT having changed anything.

  5. THE WRITE, THE SETTLE, AND THE REVERT. A trap reverts on every exit path -- normal end, error,
     INT/TERM/HUP -- and the revert command is written to a file on the device before the write, so the
     undo survives the session. There is no background timer on purpose: the value does not survive a
     reboot, so a lost session is not a state that needs undoing, and a timer is one more thing that can
     write without anybody deciding to.

  6. THE AFTER READING AND THE VERDICT, which is a 2x2 over two questions and is deliberately able to
     come out against the hypothesis:
       were the deep states entered BEFORE?   x   were they entered AFTER?
       and, separately, WAS THERE ANY OPPORTUNITY: if even the shallowest state's usage did not move,
       the CPU was never idle during the window and the experiment says NOTHING (exit 1).
     The four answers are REFUTED / SUPPORTED (not proven) / INCONCLUSIVE / CONFOUNDED, and the words
     around them say which reading produced them. "The counters moved" is not proof of a mechanism: the
     counters are evidence about behaviour, the parameter is evidence about intent, and neither is the
     driver's source. (That source IS on the host -- scripts/host/zl1-lpm-sleep-semantics.sh reads the
     gate out of it, docs 153 -- and it says the parameter returns level index 0, a bare wfi(). That is
     WHY this script's job is the behaviour: the mechanism is already read, and the size of the effect is
     not something a source file can answer.)

  7. THE REVERT, on every exit path, with the read-back. And the one fact that makes all of this cheap:
     the value does not survive a reboot -- the next boot sets it to 1 from the cmdline again -- so a
     reboot is both the escape hatch and the undo.
EOF
  exit 0
fi

# ==================================================================================================
# find the parameter, and the panic -> EDL knob, by GLOB AND NOT BY NAME -- the real name was measured on
# 2026-09-24 (`msm_poweroff`, docs 125); the glob stays because it is robust to a renamed module, not
# because the name was ever in doubt
# ==================================================================================================
# Both are module params of drivers named after the vendor's own scheme, and docs 86 records that the
# poweroff driver's name was not what the string-search suggested. So they are discovered, and their
# absence is a named outcome rather than a silent skip.
find_param() { # $1 = the parameter's bare name
  for p in /sys/module/*/parameters/"$1"; do
    [ -e "$p" ] && { printf '%s' "$p"; return 0; }
  done
  return 1
}
PARAM=$(find_param sleep_disabled) || PARAM=

# ==================================================================================================
hdr "1. the three prerequisites (nothing is written until all three are checked)"
# ==================================================================================================
A_OK=0; B_OK=0; C_OK=0

# A. the panic -> EDL escalation. EVERY `download_mode` parameter is read, not the first one found: the
#    unit that arms this policy loops the same glob and FAILS ITSELF if any parameter did not clear
#    (`install-no-edl-on-panic.sh`), so a gate satisfied by the first match can be satisfied by a knob
#    that is not the one the policy clears -- and this gate is a refusal, so what it buys in that case is
#    exactly the finger it exists to save. The device as measured has ONE such parameter
#    (`/sys/module/msm_poweroff/parameters/download_mode`, = 1 at boot; real readings in
#    tmp-post-recovery-*/01-edl-postmortem.txt and docs 125), which is why this needs a scenario in the
#    harness rather than a memory here. Same reading, same reason, as the runbook's prerequisite A.
DL_N=0; DL_BAD=
for p in /sys/module/*/parameters/download_mode; do
  [ -e "$p" ] || continue
  DL_N=$((DL_N + 1))
  v=$(rd "$p")
  [ "$v" = 0 ] || DL_BAD="$DL_BAD $p=$v"
done
DL_BAD=${DL_BAD# }
if [ "$DL_N" = 0 ]; then
  say "   A. download_mode: NOT FOUND under /sys/module/*/parameters/."
  say "      READS AS: this cannot be checked, so it is not satisfied. install-no-edl-on-panic.sh is"
  say "      what arms it, and its absence here is a reading about this boot's drivers, not a licence."
elif [ -n "$DL_BAD" ]; then
  say "   A. A PANIC WOULD ARM EDL: $DL_BAD  (1 = the image default)"
  [ "$DL_N" -gt 1 ] && say "      ($DL_N download_mode parameter(s) exist, and the unit that arms this clears ALL of them.)"
  say "      Run: scripts/install-no-edl-on-panic.sh --install     # then re-run this"
else
  A_OK=1
  say "   A. A panic will NOT arm EDL: all $DL_N download_mode parameter(s) read 0 (docs 86)"
fi

# B. the counters. Counted exactly as the probe counts them, and for the same reason: a CPU with no
#    cpuidle directory is not a CPU whose counters are zero.
CPU_GLOB=/sys/devices/system/cpu/cpu[0-9]*
CPUS=0
for c in $CPU_GLOB; do
  [ -d "$c/cpuidle" ] || continue
  CPUS=$((CPUS + 1))
done
if [ "$CPUS" = 0 ]; then
  say "   B. cpuidle: NO CPU EXPOSES A cpuidle DIRECTORY -- there is nothing to measure, and 'no"
  say "      deep-state time' would be a reading about this file tree rather than about the SoC."
else
  B_OK=1
  say "   B. cpuidle: $CPUS cpu(s) expose counters (driver: $(rd /sys/devices/system/cpu/cpuidle/current_driver))"
fi

# C. the debug keeper. Matched by ARGV, exactly like install-retire-debug-keeper.sh: a shell whose command
#    line merely MENTIONS the keeper's path is not the keeper.
KEEPER_PIDS=
for d in /proc/[0-9]*; do
  [ -d "$d" ] || continue
  p=${d#/proc/}
  [ "$p" = 1 ] && continue
  [ "$p" = "$MYPID" ] && continue
  # `is_keeper_cmdline`'s rule, in one place: argv[1] IS the path, or argv[0] is a shell and argv[1] the
  # path. Deliberately not a substring match over the whole cmdline.
  set -- $(tr '\000' '\n' < "$d/cmdline" 2>/dev/null)
  a0=${1:-}; a1=${2:-}
  hit=0
  case "$a1" in */zl1-debug-net.sh) hit=1 ;; esac
  if [ "$hit" = 0 ]; then
    case "$a0" in
    */zl1-debug-net.sh) hit=1 ;;
    */sh|*/dash|*/bash|*/busybox|sh|dash|bash|busybox)
      case "$a1" in */zl1-debug-net.sh) hit=1 ;; esac ;;
    esac
  fi
  [ "$hit" = 1 ] && KEEPER_PIDS="$KEEPER_PIDS $p"
done
KEEPER_PIDS=${KEEPER_PIDS# }
if [ -z "$KEEPER_PIDS" ]; then
  C_OK=1
  say "   C. no v63 debug keeper is running (matched by argv, not by a substring of the cmdline)"
else
  say "   C. THE DEBUG KEEPER IS RUNNING: pid(s) $KEEPER_PIDS -- it holds about a core (docs 72/94/99),"
  say "      and a CPU that is never idle does not enter a deep idle state. Retire it first:"
  say "        scripts/install-retire-debug-keeper.sh --install --now --after-proof"
  say "      (--allow-keeper proceeds anyway; the verdict then says the reading is CONFOUNDED)"
fi

# ==================================================================================================
hdr "2. the parameter this trial would write"
# ==================================================================================================
if [ -z "$PARAM" ]; then
  say "   sleep_disabled: NOT FOUND under /sys/module/*/parameters/."
  say "   docs 121 section 5.5 found the __param entry in the boot kernel with mode 0664, so its absence"
  say "   on a RUNNING device is a reading about the driver on this boot (lpm-levels did not register),"
  say "   not about the knob. There is nothing for this trial to write, and that is not a refusal to"
  say "   explain away -- it is the answer to the question this script asks."
  PARAM_OK=0
  say "   -> the trial cannot run on this boot. Nothing was written."
  # --status and --explain report that and stop; --apply and --revert are refusals.
  case "$MODE" in
  revert) bad "refusing: there is no parameter file to revert"; exit 3 ;;
  apply)  bad "refusing: there is no parameter file to write"; exit 3 ;;
  *) exit 1 ;;
  esac
fi
PARAM_OK=1
P_BEFORE=$(rd "$PARAM")
P_MODE=$(ls -l "$PARAM" 2>/dev/null | awk '{print $1}')
say "   path:  $PARAM"
say "   value: $P_BEFORE        (Y/1 = the ladder is OFF; N/0 = it is ALLOWED -- this parameter is a"
say "                           BOOL, so sysfs renders what the file stores, and Y/N is what a reader"
say "                           sees on a device where 0/1 was written)"
say "   mode:  ${P_MODE:-UNREADABLE}   (0664 = writable while the device runs -- docs 121 section 5.5)"
REVERT_CMD="printf 1 > $PARAM"
# "IS THE BEFORE-WINDOW A BASELINE?" -- and this is the question the flag this line used to set was
# always meant to answer, except that it was ASSIGNED, PRINTED and then NEVER READ. Measured on the
# device on 2026-09-25, and the measurement is why it is now a refusal:
#
#   a previous run of this script wrote 0 and its refusal path (see section 6) did not revert, so this
#   boot had the ladder ALLOWED for 31 minutes before the next trial took its before-snapshot. cpuidle's
#   counters are CUMULATIVE since boot, so that snapshot read `state2 usage=162874` -- and the verdict's
#   whole test is "had the deep state EVER been entered before the write". It answered REFUTED, from a
#   window in which the parameter under test had not been 1 at all. The same boot's earlier reading (with
#   the parameter at 1 since boot, 4h42m) was `state1 usage=0 state2 usage=0`, and 127 seconds with the
#   ladder OFF after the revert moved neither counter -- so the verdict INVERTED its own data.
#
# `is_off` rather than a value comparison, for the reason at the top of this file. The mode check that
# used to sit here set the same dead flag; it is gone, because an unreadable mode is what section 5's
# same-value proof exists to catch and it catches it more precisely.
BASE_OK=1
if is_off "$P_BEFORE"; then
  BASE_OK=0
  say "   -> it is ALREADY off ('$P_BEFORE'). Either a fix is in, or somebody wrote it -- including a"
  say "      previous run of this script. THAT MAKES THIS BOOT'S COUNTERS UNUSABLE AS A BASELINE:"
  say "      cpuidle's counters are cumulative since boot, so they now hold entries made while the ladder"
  say "      was allowed, and the verdict's test is whether the deep state had EVER been entered before"
  say "      the write. Put it back with --revert and REBOOT: a boot whose cmdline reaches a driver that"
  say "      has never been written to is the clean one, and the counters start at zero there."
fi

# ==================================================================================================
hdr "3. the counters BEFORE"
# ==================================================================================================
# Recorded as numbers, never as a share: the ratio in the probe is a display of one CPU, and a ratio is
# useless for a DELTA across a window (a denominator that moves cannot be subtracted).
#
# AND --status WRITES NOTHING, which is a contract this section broke in its first version: it took the
# "before" snapshot unconditionally, so the read-only mode created a directory and a file inside /tmp.
# Nothing on the device was harmed by that and it is still the wrong contract: a mode that reports must
# be usable on a device nobody intends to touch, and its guarantee has to be "not one byte", not "not one
# byte that matters". So the snapshot is only taken in --apply, and --status lists the same lines to
# STDOUT through the same code (`-`), which is also what keeps the two listings identical.
counters_lines() { # the same lines the snapshot file holds, on stdout
  for c in $CPU_GLOB; do
    [ -d "$c/cpuidle" ] || continue
    n=$(basename "$c")
    for st in "$c"/cpuidle/state[0-9]*; do
      [ -d "$st" ] || continue
      si=$(basename "$st")
      printf '%s %s %s %s %s\n' "$n" "$si" "$(rd "$st/name")" "$(rdn "$st/usage")" "$(rdn "$st/time")"
    done
  done
}
snap_counters() { # $1 = a directory to write into, or `-` to print and write nothing
  if [ "$1" = - ]; then counters_lines; return 0; fi
  mkdir -p "$1" || return 1
  counters_lines > "$1/counters" || return 1
  return 0
}
SNAP_BEFORE=
CTR_BEFORE=
if [ "$B_OK" = 1 ]; then
  if [ "$MODE" = apply ]; then
    SNAP_BEFORE=/tmp/zl1-lpm-trial-before
    rm -rf "$SNAP_BEFORE"
    snap_counters "$SNAP_BEFORE" || { bad "could not record the before snapshot -- nothing has been changed"; exit 3; }
    CTR_BEFORE=$(cat "$SNAP_BEFORE/counters" 2>/dev/null)
  else
    CTR_BEFORE=$(snap_counters -)
  fi
  n=0
  while read -r cpu st nm us tm; do
    n=$((n + 1))
    [ "$n" -le 12 ] && say "   $cpu $st $(printf '%-12s' "$nm") usage=$(printf '%-10s' "$us") time=$tm"
  done <<EOF
$CTR_BEFORE
EOF
  [ "$n" -gt 12 ] && say "   ... ($n state(s) in total across $CPUS cpu(s))"
  # The deepest state, and whether it is disabled by the OTHER mechanism. Both are printed because the
  # verdict has to be able to say "confounded" instead of concluding from a state nothing can enter.
  # The first field is the cpu's NAME (cpu0), not its number: taking that for the index is how the first
  # version of this line reported state0 as "the deepest state", which then made every verdict a
  # statement about the shallowest one.
  DEEPEST=$(printf '%s\n' "$CTR_BEFORE" | awk '$1=="cpu0" && $2 ~ /^state[0-9]+$/ {sub(/state/,"",$2); print $2}' | sort -n | tail -1)
  DEEPEST=${DEEPEST:-0}
  DEEP_NAME=$(printf '%s\n' "$CTR_BEFORE" | awk -v d="state$DEEPEST" '$2==d{print $3}' | head -1)
  DEEP_DIS=$(rd "/sys/devices/system/cpu/cpu0/cpuidle/state$DEEPEST/disable")
  say "   the deepest state on cpu0: state$DEEPEST ($DEEP_NAME), disable=$DEEP_DIS"
else
  say "   (not read: prerequisite B is not satisfied)"
  DEEPEST=0; DEEP_NAME=UNKNOWN; DEEP_DIS=UNKNOWN
fi

if [ "$MODE" = status ]; then
  hdr "what a trial would do"
  say "   printf 0 > $PARAM          -> the ladder allowed"
  say "   wait ${SETTLE}s, read the counters again, then put it back to 1"
  say "   the value does NOT survive a reboot: the next boot sets it from the cmdline again, so the"
  say "   experiment is scoped to this boot and a reboot is both the escape hatch and the undo."
  if [ "$A_OK" = 1 ] && [ "$B_OK" = 1 ] && [ "$C_OK" = 1 ] && [ "$BASE_OK" = 1 ]; then
    say "   -> all three prerequisites are satisfied and the before-window is a baseline, so --apply would run it."
    exit 0
  fi
  say "   -> NOT all of them are satisfied (above). --apply would REFUSE, writing nothing."
  exit 0
fi

# ==================================================================================================
# --revert: the one command to run if anything is odd. No prerequisites, no experiment.
# ==================================================================================================
if [ "$MODE" = revert ]; then
  hdr "revert"
  if is_on "$P_BEFORE"; then
    say "   it already reads '$P_BEFORE', which is ON -- nothing to do."
    exit 0
  fi
  printf '1' > "$PARAM" || { bad "the write failed: $PARAM"; exit 4; }
  P_NOW=$(rd "$PARAM")
  if is_on "$P_NOW"; then
    say "   -> $PARAM put back to 1 (it reads '$P_NOW'), verified by read-back."
    exit 0
  fi
  bad "   -> the write did NOT hold: read-back is '$P_NOW', which is not ON (1/Y/on). docs 121's"
  bad "      calibration says this file is writable; a value that will not change here is a finding"
  bad "      about this boot's driver."
  exit 4
fi

# ==================================================================================================
# --apply
# ==================================================================================================
hdr "4. the refusals, on their own terms (each leaves the device exactly as it was)"
# ==================================================================================================
REFUSED=0
if [ "$A_OK" != 1 ]; then
  bad "   REFUSED (prerequisite A): a panic would still arm EDL. This trial is allowed to hang -- it is"
  bad "   not allowed to cost a finger. Nothing was written."
  REFUSED=1
fi
if [ "$B_OK" != 1 ]; then
  bad "   REFUSED (prerequisite B): no cpuidle counters, so there is no before/after to measure. Nothing"
  bad "   was written."
  REFUSED=1
fi
if [ "$C_OK" != 1 ] && [ "$ALLOW_KEEPER" != 1 ]; then
  bad "   REFUSED (prerequisite C): the debug keeper is running, so a CPU may never be idle and 'the"
  bad "   ladder was not entered' would be a reading about the keeper. Nothing was written."
  REFUSED=1
fi
if [ "$BASE_OK" != 1 ]; then
  bad "   REFUSED (baseline D): $PARAM is ALREADY off, so this boot's cpuidle counters hold entries made"
  bad "   while the ladder was allowed. The verdict's test is whether the deep state had EVER been"
  bad "   entered before the write, and on a boot like this that test answers about the PREVIOUS writer"
  bad "   rather than about the parameter. Nothing was written. Measured 2026-09-25: this exact state"
  bad "   produced a REFUTED verdict that inverted its own data -- 0 entries in 4h42m with the parameter"
  bad "   on, and 162874 in the 31 minutes since a previous run wrote 0 and did not revert. --revert,"
  bad "   then reboot, then run this on a boot whose cmdline is the first thing to touch the driver."
  REFUSED=1
fi
if [ "$REFUSED" = 1 ]; then
  say ""
  say "   Nothing was written and nothing was changed. Fix the item(s) above and re-run --apply."
  exit 3
fi
CONFOUNDED=0
[ "$C_OK" != 1 ] && CONFOUNDED=1
case "$DEEP_DIS" in
1) CONFOUNDED=1
   say "   NOTE: the deepest state (state$DEEPEST, $DEEP_NAME) is DISABLED by the other mechanism"
   say "   (cpuidle/state$DEEPEST/disable=1). Nothing this script writes can make it be entered, so if it"
   say "   does not move that is not evidence about sleep_disabled. The verdict will say so." ;;
esac
say "   all three prerequisites are satisfied and the before-window is a baseline, so this is a clean"
say "   measurement; proceeding$([ "$CONFOUNDED" = 1 ] && printf ' (with a confounder recorded)')"

# --- 5. the same-value write proof ------------------------------------------------------------------
hdr "5. the write path, proved BEFORE anything is changed"
# The current value, written back to itself. If the file cannot be written, or cannot be read back, this
# is where that is discovered -- with the device in the state it was already in.
#
# WHAT THIS PROOF CANNOT DO, said here so nobody looks for the alphabet in it: writing back what was just
# read is alphabet-independent by construction, so this line passes on a file with no type and on this
# bool alike. It proves writability and readability, which is what it says, and nothing about what the
# file will accept as a CHANGE -- that is section 6, and a reader who wants the type should look at the
# module_param declaration quoted at `is_off`.
printf '%s' "$P_BEFORE" > "$PARAM" 2>/dev/null
P_PROOF=$(rd "$PARAM")
if [ "$P_PROOF" != "$P_BEFORE" ]; then
  bad "   the same-value write did not read back: wanted '$P_BEFORE', got '$P_PROOF'."
  bad "   That is a fact about this boot's sysfs, not a licence to proceed. NOTHING WAS CHANGED -- the"
  bad "   write was the value the file already held."
  exit 3
fi
say "   wrote '$P_BEFORE' back to itself and read '$P_PROOF' -- the file is writable AND readable."
say "   (this says nothing about the ALPHABET a changed value is rendered in -- see section 6)"

# --- 6. the undo, put where the DEVICE can reach it, and then the write -----------------------------
hdr "6. the write, with the undo on the device rather than in this session"
# The usual way to lose this session is the netwatch's heal stage re-enumerating the USB gadget (docs
# 118). The value does not survive a reboot, so a lost session needs no rescue -- but an operator who
# still HAS a shell should not have to remember the path, so the one-liner is written out first.
REVERT_SH=/tmp/zl1-lpm-trial-revert.sh
printf '%s\n' '#!/bin/sh' "$REVERT_CMD" 'printf "%s\\n" "reverted: $(cat '"$PARAM"')"' > "$REVERT_SH" 2>/dev/null
if [ -s "$REVERT_SH" ]; then
  chmod +x "$REVERT_SH" 2>/dev/null
  say "   wrote the undo to $REVERT_SH (run it, or: sh $0 --revert)"
else
  say "   could not write $REVERT_SH -- the undo is: $REVERT_CMD"
fi
printf '0' > "$PARAM" || { bad "   the write failed"; exit 4; }
# WROTE IS SET FROM THE REDIRECT'S OWN SUCCESS, NOT FROM THE READ-BACK. It used to be set after the
# read-back check, which made the one path that most needs the trap -- a write that LANDED and read back
# as something other than the string that was written -- the one path that disarmed it: the script
# reported "the write did not hold", left the parameter changed, and its own undo declined to fire
# because the flag was still 0. Measured on the device on 2026-09-25: `sleep_disabled` read `N` thirteen
# minutes after that exit, with nothing owning the change. A guard keyed on the same comparison it is
# guarding is not a guard, and a redirect that returned means the file MAY hold something else now.
WROTE=1
P_AFTER_WRITE=$(rd "$PARAM")
if ! is_off "$P_AFTER_WRITE"; then
  bad "   the write did not hold: read-back is '$P_AFTER_WRITE', which is not OFF (0/N/off). The trap"
  bad "   reverts and this run stops -- a file that will not take the value is a finding about this"
  bad "   boot's driver. (A file with a TYPE renders what it stores: 0 is shown as N for a bool. This"
  bad "   branch is about a value that did not move, not about a spelling that surprised the reader.)"
  exit 4
fi
say "   wrote 0 and read '$P_AFTER_WRITE' back: the ladder is ALLOWED from this moment until the revert."
say "   ('$P_AFTER_WRITE' is this file's rendering of 0. The parameter is a bool, so sysfs shows Y/N"
say "    whatever spelling was written -- comparing against '0' here is what refused a good write before.)"
say "   revert now:            sh $0 --revert"
say "   or by hand:            $REVERT_CMD"

# --- 7. settle, then the after reading --------------------------------------------------------------
hdr "7. the window: ${SETTLE}s with the ladder allowed"
say "   letting the SoC be idle. Nothing else is measured during this window, and this script's own"
say "   sleep cannot wake a core."
sleep "$SETTLE"

hdr "8. the counters AFTER, and the deltas"
SNAP_AFTER=/tmp/zl1-lpm-trial-after
rm -rf "$SNAP_AFTER"
snap_counters "$SNAP_AFTER" || { bad "could not record the after snapshot -- reverting"; printf '1' > "$PARAM"; exit 4; }
DELTAS=/tmp/zl1-lpm-trial-deltas
# `: > file` and NOT the obvious spelling, and the reason is worth keeping: `:` is a SPECIAL BUILTIN, so
# a redirection error on it is FATAL -- the shell exits 2 on the spot, before the check below can run and
# before the script can say what happened. Measured, not assumed: with the deltas path pointing at a
# directory, `: > "$DELTAS"` ended the run with status 2, which the header defines as "not the zl1". The
# trap still reverted the parameter -- that half held -- but the exit code lied about why.
# `printf` is an ordinary builtin, so its failure is a status to check instead of a death.
if ! printf '' > "$DELTAS" 2>/dev/null; then
  bad "   the deltas could not be recorded ($DELTAS): an empty deltas file makes every counter read"
  bad "   UNKNOWN, and the verdict would then say 'inconclusive' for a reason that is not on the device."
  bad "   Stopping here; the trap puts the parameter back."
  exit 4
fi
# The delta is computed per (cpu, state), joined on the two keys. An unreadable counter on either side is
# reported as such rather than as a zero delta -- a zero here is the reading this whole experiment turns
# on, so it must never be manufactured by a failed read.
while read -r cpu st nm us tm; do
  b_us=$(awk -v c="$cpu" -v s="$st" '$1==c && $2==s {print $4}' "$SNAP_BEFORE/counters")
  b_tm=$(awk -v c="$cpu" -v s="$st" '$1==c && $2==s {print $5}' "$SNAP_BEFORE/counters")
  case "$us$b_us" in *[!0-9]*) dus=NOT-A-NUMBER ;; *) dus=$((us - b_us)) ;; esac
  case "$tm$b_tm" in *[!0-9]*) dtm=NOT-A-NUMBER ;; *) dtm=$((tm - b_tm)) ;; esac
  printf '%s %s %s %s %s\n' "$cpu" "$st" "$nm" "$dus" "$dtm" >> "$DELTAS"
  printf '   %-5s %-8s %-12s d_usage=%-12s d_time=%s\n' "$cpu" "$st" "$nm" "$dus" "$dtm"
done < "$SNAP_AFTER/counters"
# The deltas file is what the verdict reads. If it could not be written, every lookup below would come
# back empty and the verdict would say UNKNOWN -- honest, and reached for a reason nobody can see from
# the output. So it is checked here, where the failure can be named, and the trap reverts.
N_DELTAS=$(grep -c . "$DELTAS" 2>/dev/null)
N_AFTER=$(grep -c . "$SNAP_AFTER/counters" 2>/dev/null)
if [ "${N_DELTAS:-0}" = 0 ] || [ "${N_DELTAS:-0}" != "${N_AFTER:-x}" ]; then
  bad "   the deltas could not be recorded ($DELTAS: ${N_DELTAS:-0} line(s) for ${N_AFTER:-0} counter(s))"
  bad "   -- the verdict would be UNKNOWN for a reason that is not on the device. Stopping; the trap"
  bad "   puts the parameter back."
  exit 4
fi

# The three numbers the verdict rests on, each with its own "could not be read" spelling.
DEEP_DU=$(awk -v d="state$DEEPEST" '$2==d {print $4; exit}' "$DELTAS"); DEEP_DU=${DEEP_DU:-UNKNOWN}
DEEP_DT=$(awk -v d="state$DEEPEST" '$2==d {print $5; exit}' "$DELTAS"); DEEP_DT=${DEEP_DT:-UNKNOWN}
DEEP_BEFORE_U=$(awk -v d="state$DEEPEST" '$2==d {print $4; exit}' "$SNAP_BEFORE/counters"); DEEP_BEFORE_U=${DEEP_BEFORE_U:-UNKNOWN}
WFI_DU=$(awk '$2=="state0" {print $4; exit}' "$DELTAS"); WFI_DU=${WFI_DU:-UNKNOWN}

# --- 9. the revert ----------------------------------------------------------------------------------
hdr "9. the revert"
if [ "$KEEP" = 1 ]; then
  say "   --keep was given: $PARAM is LEFT at 0 (it reads '$P_AFTER_WRITE'), and the trap will not put it"
  say "   back either."
  say "   Put it back with:  $REVERT_CMD"
  say "   (it is not persistent anyway: the next boot sets it to 1 from the cmdline.)"
else
  do_revert
  WROTE=0        # so the trap at exit does not repeat it and cannot report a second time
  P_BACK=$(rd "$PARAM")
  if is_on "$P_BACK"; then
    say "   -> $PARAM is back to 1 (it reads '$P_BACK'), verified by read-back."
  else
    bad "   -> the revert did not hold: read-back is '$P_BACK', which is not ON. Run: sh $0 --revert"
    exit 4
  fi
fi

# --- 10. the verdict --------------------------------------------------------------------------------
# A 2x2 plus an opportunity test, and it is built so that REFUTED is reachable. Every branch names the
# reading it came from; none of them claims to know what the parameter does.
hdr "10. the verdict"
# THE LINE, AND WHY THERE IS ONE NOW. This section has always printed five named outcomes, and not one
# of them was printed as a LINE -- they were prose, separated by exit code. That is enough for a person
# and not enough for anything else: `install-lpm-sleep-fix.sh` may only install the fix when THIS trial
# has said the parameter gates the ladder, and a licence that has to be extracted from a sentence is the
# shape this repository has already recorded as a defect (docs 114: a substring gate accepted a sentence
# that merely CONTAINED the word). So each branch below prints
#
#     == verdict: <name>
#
# as a whole line, in the form every other probe in this tree uses, and the names are the ones the
# outcomes already had: refuted / supported-not-proven / not-supported / inconclusive / confounded.
# The prose stays, because the prose is what explains the name.
say "   before this boot's write, state$DEEPEST ($DEEP_NAME) had been entered $DEEP_BEFORE_U time(s)"
say "   during the window it was entered $DEEP_DU more time(s), for $DEEP_DT more of its counted time"
say "   the shallowest state (state0) moved $WFI_DU time(s) in the same window"

case "$DEEP_DU" in
UNKNOWN|NOT-A-NUMBER|"")
  say "   -> INCONCLUSIVE: the deepest state's counter could not be read across the window, so nothing"
  say "      here is a reading about the ladder. Exit 1."
  say "== verdict: inconclusive"
  exit 1 ;;
esac
case "$WFI_DU" in
UNKNOWN|NOT-A-NUMBER|"")
  say "   -> INCONCLUSIVE: the shallowest state's counter could not be read, so 'was there any idle"
  say "      opportunity at all' has no answer. Exit 1."
  say "== verdict: inconclusive"
  exit 1 ;;
esac

if [ "$DEEP_BEFORE_U" != 0 ] && [ "$DEEP_BEFORE_U" != UNKNOWN ]; then
  if [ "$CONFOUNDED" = 1 ]; then
    say "   -> CONFOUNDED: the deepest state had already been entered before the write, so the parameter"
    say "      is not what gates it -- but this boot also has a confounder recorded above (the keeper, or"
    say "      a disabled state), so the run is reported as confounded rather than as a clean refutation."
    say "== verdict: confounded"
  else
    say "   -> REFUTED: state$DEEPEST was ALREADY being entered before this script wrote anything"
    say "      ($DEEP_BEFORE_U time(s) since boot). So sleep_disabled=1 does not gate that state on this"
    say "      device, and the hypothesis that the ladder is switched off by this parameter is dead for"
    say "      it -- whatever the after-window shows. This is the reading that makes the experiment worth"
    say "      running: it can come out against the thing it was built to test."
    say "== verdict: refuted"
  fi
  exit 0
fi

if [ "$WFI_DU" = 0 ]; then
  say "   -> INCONCLUSIVE: no idle state moved at all in this window, so the CPU was never idle and the"
  say "      experiment says NOTHING about the ladder. (Something is busy -- and if the keeper is running"
  say "      this is exactly the confound prerequisite C exists for.) Exit 1."
  say "== verdict: inconclusive"
  exit 1
fi

if [ "$DEEP_DU" -gt 0 ]; then
  say "   -> SUPPORTED, NOT PROVEN: with the ladder allowed, state$DEEPEST was entered $DEEP_DU time(s)"
  say "      where it had been entered 0 times in the whole boot before. That is consistent with"
  say "      sleep_disabled gating the ladder, and it is not proof of it: nothing here measures whether"
  say "      the same opportunity would have entered it anyway, and no source file can measure that. (The"
  say "      semantics of the parameter are read from the driver's source on the host -- docs 153 -- so the"
  say "      open question was never what the parameter does; it is what the ladder is WORTH on this board.)"
  say "      What this DOES settle is that the ladder is reachable on this device at all, which no image"
  say "      here had ever shown."
  if [ "$CONFOUNDED" = 1 ]; then
    say "      CONFOUNDED, and it is stated here rather than left to the reader: a confounder recorded"
    say "      above (the keeper running, or the deepest state disabled) can produce this sign on its own,"
    say "      so this run is not the answer. Exit 1."
    say "== verdict: confounded"
    exit 1
  fi
  say "== verdict: supported-not-proven"
  exit 0
fi

if [ "$CONFOUNDED" = 1 ]; then
  say "   -> CONFOUNDED: the deepest state was not entered, and this boot has a confounder recorded above"
  say "      (the keeper running, or the state disabled) which explains that without the parameter. Exit 1."
  # AND THE CODE NOW MATCHES THE SENTENCE. This branch prints "Exit 1." and used to `exit 0`: the script's
  # own header defines exit 1 as "the verdict is INCONCLUSIVE or CONFOUNDED", and this is one of its two
  # CONFOUNDED branches. The same reading in the branch above -- deep state WAS entered, with a confounder
  # -- has always exited 1, so the two disagreed about the same word. It was found while building the
  # installer that reads this line, which is the point: a licence nobody can parse is a licence nobody
  # checks, and an exit code nobody checks drifts from its own manual.
  say "== verdict: confounded"
  exit 1
else
  say "   -> NOT SUPPORTED: state0 moved $WFI_DU time(s) -- so there WAS idle opportunity -- and"
  say "      state$DEEPEST was still entered 0 times with the ladder allowed. Either the parameter does"
  say "      not gate what it appears to gate, or this SoC's ladder needs something else as well. The"
  say "      driver's source IS readable from the host (docs 153: the gate returns level index 0, and index"
  say "      0 is a bare wfi() -- lpm_cpuidle_enter then carries that index into psci_enter_sleep, whose"
  say "      'if (!idx)' branch is the wfi). So a NOT SUPPORTED result here is not a source question; it is"
  say "      a fact about this board that the source cannot explain, and it is the interesting outcome."
  say "      Do not report this as the fix."
  say "== verdict: not-supported"
fi
exit 0
