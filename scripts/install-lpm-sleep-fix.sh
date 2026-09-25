#!/usr/bin/env bash
# Arm the THIRD heat fix: let the SoC use its own low-power ladder, on every boot.
#
# Why this exists (docs 121 and 153 for the cause, docs 122 for the experiment, docs 160 for this):
#
#   The heat has THREE measured, named causes and only two of them can be installed:
#
#     1. the v63 debug keeper, ~1 core of this 4-core SoC     -> install-retire-debug-keeper.sh
#     2. the image pins all four cores on `performance`       -> install-cpufreq-governor.sh
#     3. THE SoC IS NOT ALLOWED TO SLEEP                      -> *here*
#
#   Cause 3 is supply-side and neither of the other two can reach it. Every zl1 DTB carries a complete
#   `qcom,lpm-levels` ladder whose deepest rung (`system-fpc`, 11000 us) is a full power collapse of the
#   whole SoC, and every cmdline -- the stock MIUI-derived one this port inherited verbatim -- turns the
#   whole ladder off:
#
#       lpm_levels.sleep_disabled=1
#
#   That is a MODULE PARAMETER of the built-in `lpm_levels` driver with mode 0664, so it can be written
#   while the device runs (docs 153 reads the mechanism out of the shipped source: the gate returns level
#   index 0, and index 0 is a bare `wfi()` -- the ladder is removed from the TOP, not a shallower state
#   chosen). So the fix is a runtime write, not a flash, and not a new boot image.
#
#   **AND THAT IS THE WHOLE PROBLEM: THE WRITE DOES NOT SURVIVE A REBOOT.** The value comes back as 1
#   from the same cmdline that made it 1, so a one-off `printf 0 > ...` fixes this boot and no other.
#   `zl1-lpm-ladder-trial.sh --apply` writes it, measures, and puts it back BY CONSTRUCTION -- it is the
#   experiment, and a reboot is its undo. Until this script existed, nothing in this repository made the
#   third fix persist: the trial could say the ladder works and the next boot would be warm again. That
#   is why this installer's absence was a gap and not a preference.
#
# WHAT LICENSES IT, AND WHY THAT IS NOT A FORMALITY:
#
#   0664 proves the file is WRITABLE. It does not prove that writing to it changes what the SoC does --
#   docs 121 says that twice, and docs 122 built the trial with `REFUTED` as a reachable outcome for
#   exactly that reason. So this installer will not install on the strength of "the knob exists". It
#   requires the trial's own output, and it requires the LAST verdict line in it to be
#
#       == verdict: supported-not-proven
#
#   which is the only one of the trial's five outcomes that says both (a) the ladder is gated by this
#   parameter and (b) the run was clean. The other four each forbid the install, and the script says
#   which one it read:
#
#       refuted              the ladder was already in use with the parameter at 1 -> this parameter is
#                            not the fix, and installing a writer for it would be installing nothing
#       not-supported        idle opportunity existed and the deep state was still never entered -> the
#                            parameter does not gate what it appears to gate
#       inconclusive         the counters could not be read, or the CPU was never idle -> nothing was
#                            measured, and "I could not measure it" is not "it works"
#       confounded           a confounder (the keeper, or a disabled state) explains the result on its
#                            own, so the run is not the answer
#
#   THE LAST LINE, NOT ANY LINE. An archived trial output can hold more than one run (the runbook can be
#   invoked more than once a boot), and a licence taken from the first match would let a `SUPPORTED` from
#   an earlier run authorise an install after a later `REFUTED`. The most recent reading is the licence,
#   and this prints which line it used.
#
# THE OTHER PREREQUISITE, AND IT IS THE ONE THAT COSTS A FINGER IF IT IS NOT CHECKED:
#
#   The trial is scoped to ONE boot by construction, so a hang during it is bounded by the reboot. THIS
#   INSTALLER IS NOT: it makes the ladder active on EVERY boot from now on. On this board a kernel panic
#   escalates to EDL by default -- `download_mode` is a compiled-in 1 (docs 86), and the bootloader then
#   waits for a person to hold the power button. That escalation is disarmed by
#   `install-no-edl-on-panic.sh --install`, which the one-boot runbook runs as its step 02, one step
#   before the heat chain. This script therefore REFUSES unless every `download_mode` parameter reads 0,
#   for the same reason the trial does: from here on, "something goes wrong while the ladder is now
#   active" must be a reboot and not a device that sits in EDL.
#
# What this installs (both files new, on the `/etc/systemd/system` writable path -- `/` is a read-only
# image and `/etc/systemd/system` here resolves into the rw `/etc/writable` mount, which is where the
# units this port already added live):
#
#   /etc/systemd/system/zl1-lpm-sleep-fix.sh      the applier (also usable by hand)
#   /etc/systemd/system/zl1-lpm-sleep-fix.service oneshot, RemainAfterExit, WantedBy=multi-user.target
#
# The applier loops EVERY `/sys/module/*/parameters/sleep_disabled`, not the first one, and it FAILS if a
# write does not read back as OFF or if the parameter does not exist at all. Those two rules are not
# decoration: the same shape in `install-no-edl-on-panic.sh` is the reason that policy clears every
# `download_mode` parameter rather than one, and the read-back rule is the defect
# `install-cpufreq-governor.sh` records -- an applier that counted a write as done when `echo` returned
# reported the heat fix as armed while nothing had changed and the unit showed `active`.
#
# "OFF", AND NOT "0": `sleep_disabled` is a `bool` module parameter (drivers/cpuidle/lpm-levels.c), so the
# sysfs `show` renders 0 as `N`. Reading it back as the string `0` is a comparison between a value and its
# own rendering, and on 2026-09-25 it made this applier refuse a write that had worked -- see the comment
# inside it. The verdict block below reads the same way, for the same reason (docs 163).
#
# WHAT THIS DOES NOT DO, and the applier says it too: it does not touch the ladder's own nodes, does not
# enable or disable any cpuidle state, writes no thermal trip point, sets no frequency, and does not
# touch the keeper or the governor -- those are the other two fixes and they have their own installers.
# It does not flash anything, does not open a block device, does not reboot.
#
# Usage: install-lpm-sleep-fix.sh [--install --after-trial FILE] [--status] [--remove] [--quiet]
#   --install              install the unit, enable it and apply it now. REQUIRES --after-trial.
#   --after-trial FILE     the trial's archived output (on THIS host). The licence.
#   --status               read-only: is the fix in place, and what does the device say? (no licence)
#   --remove               disable the unit, delete both files, and put the parameter back to 1
#   --quiet                print the verdict and the read-back lines only
#   --explain              what each verdict means, and what this refuses to do
#
# Exit codes: 0 the action was carried out (or --status read the device); 1 the action was refused or the
#             read-back did not confirm it -- nothing is left half-installed, and the output says which;
#             2 the arguments were wrong, or the device could not be reached at all (nothing done).

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
HOST=${ZL1_HOST:-root@10.15.19.82}
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$HOST")

UNIT=/etc/systemd/system/zl1-lpm-sleep-fix.service
APPLIER=/etc/systemd/system/zl1-lpm-sleep-fix.sh
LICENCE='supported-not-proven'
ACTION=""
TRIAL=""
QUIET=0

say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
always() { printf '%s\n' "$*"; }
bad() { printf '%s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
  --install|--status|--remove) ACTION="$1"; shift ;;
  # NO APOSTROPHES INSIDE ${...}: an apostrophe in a parameter-expansion message inside a double-quoted
  # string desynchronises the shell's own quote tracking -- it answers "unexpected EOF while looking for
  # matching `'`" and points at a LATER line, which is a syntax error that sends you to the wrong file.
  # Measured on this host with a four-line file; the sibling installers use `${2?--flag needs a NAME}`,
  # which is why none of them ever hit it. The message still says what it is for.
  --after-trial) TRIAL="${2?--after-trial needs the FILE that the trial output was archived to}"; shift 2 ;;
  --quiet) QUIET=1; shift ;;
  --explain)
    # The anchors carry the '# ' because these are COMMENT lines: without it the range matches nothing
    # and --explain prints an empty page, which is an option doing the opposite of its manual.
    sed -n '/^# WHAT LICENSES IT/,/^# THE OTHER PREREQUISITE/p' "$0" | sed 's/^# \?//' | sed '$d'
    exit 0 ;;
  --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; exit 0 ;;
  *) echo "unknown argument: $1 (--help for usage)" >&2; exit 2 ;;
  esac
done

[ -n "$ACTION" ] || { echo "usage: $0 [--install --after-trial FILE] [--status] [--remove] (--help for the rest)" >&2; exit 2; }

# ==================================================================================================
# THE LICENCE, read HERE and not on the device
# ==================================================================================================
# The device has no copy of the trial's archive: the runbook captures the output over ssh into this
# host's run directory, and the licence is a decision, so it is read where the evidence is. A whole line
# (`grep -x`), because a substring gate on prose is the defect docs 114 recorded -- and the LAST one,
# because an archive can hold more than one run.
licence_line() {
  [ -n "$TRIAL" ] || { echo "NO-FILE"; return 0; }
  [ -r "$TRIAL" ] || { echo "UNREADABLE"; return 0; }
  # `|| true`: grep exits 1 when there is no match, and under `set -o pipefail` that would abort the
  # assignment and read as an I/O failure rather than as "this file holds no verdict".
  { grep -ax '== verdict: [a-z-]*' "$TRIAL" 2>/dev/null || true; } | tail -1 | sed 's/^== verdict: //'
}

if [ "$ACTION" = "--install" ]; then
  GOT=$(licence_line)
  case "$GOT" in
  "$LICENCE")
    say "licence: '$TRIAL' ends with '== verdict: $LICENCE' -- the trial says this parameter gates the ladder"
    say "         and that the run was clean, so the fix it measured is worth installing." ;;
  NO-FILE)
    bad "REFUSING: --install needs --after-trial FILE."
    bad "  This is not paperwork. 0664 proves the knob is WRITABLE; it does not prove that writing it changes"
    bad "  what the SoC does (docs 121), and the trial is the experiment built to be able to REFUTE that."
    bad "  Run the trial on the device and pass its archived output:"
    bad "      zl1-lpm-ladder-trial.sh --apply   (on the device; or the runbook's 05-trial)"
    bad "   Nothing was done. Exit 1."
    exit 1 ;;
  UNREADABLE)
    bad "REFUSING: --after-trial '$TRIAL' cannot be read on this host, so there is no licence to read."
    bad "  Nothing was done. Exit 1."
    exit 1 ;;
  "")
    bad "REFUSING: '$TRIAL' holds no '== verdict: ...' line at all."
    bad "  A trial output with no verdict line is not a clean run -- it is a run that did not reach its"
    bad "  verdict (a refusal, a timeout, a truncated capture). Nothing was done. Exit 1."
    exit 1 ;;
  *)
    bad "REFUSING: the trial's last verdict is '== verdict: $GOT', and the only outcome this installer"
    bad "  accepts is '== verdict: $LICENCE'. Run '$0 --explain' for what each of the five means; in short,"
    bad "  every other one either refutes the hypothesis (so there is nothing here to install), or says the"
    bad "  run could not be used as the answer (so this installer has nothing to go on)."
    bad "  The licence was read from: $TRIAL"
    bad "  Nothing was done. Exit 1."
    exit 1 ;;
  esac
fi

# ==================================================================================================
# the device has to answer, and the answer has to contain the thing being fixed
# ==================================================================================================
if ! "${SSH[@]}" true 2>/dev/null; then
  bad "REFUSING: cannot reach the device at $HOST over ssh. Nothing was done. Exit 2."
  exit 2
fi

# THE PARAMETER MUST EXIST, and it is discovered rather than assumed -- the driver's module name is a
# fact about the running kernel, not a constant this script may hard-code. "NOT FOUND" is not "already
# off": a boot with no such parameter has nothing for this fix to write, and reporting that as success
# is the silent-success shape this repository keeps recording.
PARAMS=$("${SSH[@]}" 'for p in /sys/module/*/parameters/sleep_disabled; do [ -e "$p" ] && echo "$p"; done' 2>/dev/null)
if [ -z "$PARAMS" ]; then
  bad "REFUSING: no /sys/module/*/parameters/sleep_disabled on the device."
  bad "  That is a fact about THIS boot's kernel (the driver is not loaded, or is built differently), and"
  bad "  it is not the same thing as 'it is already off'. Nothing was done. Exit 1."
  exit 1
fi
say "the parameter this fix writes:"
printf '%s\n' "$PARAMS" | sed 's/^/    /'

# prerequisite A, checked on the device, for the reason in the header: from here on the ladder is active
# on every boot, so a panic must not arm EDL. `--status` does not need it (a reading is not a decision)
# but says the state, because that is what a reader wants to know next.
DM=$("${SSH[@]}" 'for p in /sys/module/*/parameters/download_mode; do [ -e "$p" ] && printf "%s %s\n" "$p" "$(cat "$p" 2>/dev/null)"; done' 2>/dev/null)
DM_ARMED=0
if [ -z "$DM" ]; then
  DM_STATE="NOT FOUND"
else
  DM_STATE=$(printf '%s\n' "$DM" | awk '{printf "%s=%s ", $1, $2}')
  printf '%s\n' "$DM" | awk '$2 != 0 {found=1} END {exit !found}' && DM_ARMED=1
fi

if [ "$ACTION" = "--install" ] && [ "$DM_ARMED" = 1 ]; then
  bad "REFUSING: a panic would arm EDL on this boot (prerequisite A is not met):"
  printf '%s\n' "$DM" | sed 's/^/    /' >&2
  bad "  The trial is scoped to one boot and this installer is NOT: it makes the low-power ladder active on"
  bad "  every boot from now on, so 'something goes wrong' has to mean a reboot and not a device waiting in"
  bad "  EDL for a finger. Install the panic guard first, then come back:"
  bad "      scripts/install-no-edl-on-panic.sh --install"
  bad "  Nothing was done. Exit 1."
  exit 1
fi

# ==================================================================================================
# --status: read-only, and it says which of the two sides answers what
# ==================================================================================================
if [ "$ACTION" = "--status" ]; then
  say ""
  say "== the unit (systemctl cat is the only honest check that a unit is in effect)"
  "${SSH[@]}" "systemctl cat zl1-lpm-sleep-fix.service 2>&1 | head -20; echo; systemctl is-active zl1-lpm-sleep-fix.service; systemctl is-enabled zl1-lpm-sleep-fix.service; systemctl show zl1-lpm-sleep-fix.service -p ExecMainStatus -p Result -p NRestarts" 2>&1 | sed 's/^/    /'
  say ""
  say "== the parameter, from both sides (the cmdline is what the boot was TOLD; the file is what the"
  say "   driver HAS -- they can disagree, and a disagreement is what the fix looks like)"
  "${SSH[@]}" 'echo "cmdline: $(cat /proc/cmdline | tr " " "\n" | grep -E "^lpm_levels\.sleep_disabled=" || echo "(absent)")"
for p in /sys/module/*/parameters/sleep_disabled; do [ -e "$p" ] && printf "file:    %s = %s\n" "$p" "$(cat "$p")"; done' 2>&1 | sed 's/^/    /'
  say ""
  say "== prerequisite A: a panic must not arm EDL (the trial says why this gates a persistent fix)"
  say "    download_mode: $DM_STATE"
  say "    $([ "$DM_ARMED" = 1 ] && echo "NOT met -- a panic WOULD arm EDL; install-no-edl-on-panic.sh --install is what fixes it" || echo "met -- every download_mode parameter reads 0, or there is none on this device")"
  say ""
  say "== the counters this fix is about (sleep_disabled is the intent; these are the fact)"
  "${SSH[@]}" 'for d in /sys/devices/system/cpu/cpu0/cpuidle/state*; do [ -e "$d/name" ] && printf "    %-14s usage=%-10s time=%s%s\n" "$(cat $d/name)" "$(cat $d/usage 2>/dev/null)" "$(cat $d/time 2>/dev/null)" "$([ -r $d/disable ] && [ "$(cat $d/disable)" != 0 ] && echo "  <- DISABLED")"; done' 2>&1
  exit 0
fi

# ==================================================================================================
# --remove: the undo, and it is complete -- it puts the parameter back to the value the cmdline sets
# ==================================================================================================
if [ "$ACTION" = "--remove" ]; then
  say "removing the unit and both files, and putting the parameter back to 1 (the value every zl1 cmdline"
  say "sets) -- so the undo is not only 'from the next boot on' but on this boot too:"
  "${SSH[@]}" "systemctl disable --now zl1-lpm-sleep-fix.service 2>&1 | tail -1
rm -f $UNIT $APPLIER
systemctl daemon-reload
n=0
for p in /sys/module/*/parameters/sleep_disabled; do
  [ -e \"\$p\" ] || continue
  printf 1 > \"\$p\" 2>/dev/null
  printf '    %s = %s (read back)\n' \"\$p\" \"\$(cat \"\$p\" 2>/dev/null)\"
  n=\$((n + 1))
done
[ \"\$n\" -gt 0 ] || printf '    (no sleep_disabled parameter on this boot -- nothing to put back)\n'
echo removed" 2>&1
  exit 0
fi

# ==================================================================================================
# --install
# ==================================================================================================
say ""
say "== installing the applier and the unit"
"${SSH[@]}" "cat > $APPLIER" <<'APPLIER_EOF'
#!/bin/sh
# Let the SoC use its own low-power ladder. Installed by scripts/install-lpm-sleep-fix.sh -- see that
# file for why this exists (every zl1 cmdline carries `lpm_levels.sleep_disabled=1`, which removes the
# whole ladder INCLUDING the full power collapse of the SoC).
#
# Safe to run by hand at any time; it is idempotent and prints what it did.
#
# TWO RULES, and both are corrections of shapes this repository has recorded:
#
#   * IT LOOPS EVERY PARAMETER, not the first match. The driver's module name is a fact about the
#     running kernel, and a boot that exposed two would otherwise have one of them written and reported
#     as done (install-no-edl-on-panic.sh's applier loops its glob for the same reason).
#   * IT READS EVERY WRITE BACK, AND IT FAILS IF THERE IS NOTHING TO WRITE. An applier that counts
#     `echo` returning as success reported the heat fix as armed while nothing had changed and the unit
#     showed `active` (install-cpufreq-governor.sh). "No such file" is not "already off".
#   * AND IT READS THE WRITE BACK AS A STATE, NOT AS THE STRING IT WROTE. `sleep_disabled` is declared
#     `static bool` with `module_param_named(sleep_disabled, sleep_disabled, bool, ...)` in
#     drivers/cpuidle/lpm-levels.c, so the sysfs `show` renders the stored value through the parameter's
#     TYPE: writing 0 and reading back N is a write that HELD. Until 2026-09-25 this applier compared the
#     read-back to `0`, so on the device it reported "did NOT take 0 (reads 'N')", counted the write as
#     failed, exited 1 and made the unit FAIL -- while the parameter had in fact been turned off. The
#     same defect refused the trial's own good write (docs 163), and both are the shape of "a comparison
#     between a value and its own rendering": it can only ever pass on a file with no type.
#
# It deliberately does not touch the ladder's own nodes, any cpuidle state's `disable`, any thermal trip
# point, any frequency, or the keeper and the governor -- those are the other two heat fixes and they
# have their own installers.
n=0
bad=0
for p in /sys/module/*/parameters/sleep_disabled; do
    [ -e "$p" ] || continue
    printf 0 > "$p" 2>/dev/null
    got=$(cat "$p" 2>/dev/null)
    case "$got" in
    0|N|n|off) n=$((n + 1)) ;;
    *)
        bad=$((bad + 1))
        echo "zl1-lpm-sleep: $p did NOT take 0 (reads '$got', which is not OFF)"
        ;;
    esac
done
if [ "$n" = 0 ] && [ "$bad" = 0 ]; then
    logger -t zl1-lpm-sleep "no sleep_disabled parameter on this boot -- the heat fix is NOT armed"
    echo "zl1-lpm-sleep: no /sys/module/*/parameters/sleep_disabled on this boot -- the heat fix is NOT armed"
    exit 1
fi
logger -t zl1-lpm-sleep "wrote 0 to $n sleep_disabled parameter(s), $bad did not take it (read back)"
echo "zl1-lpm-sleep: OFF on $n parameter(s) ($bad did not take it)"
[ "$bad" = 0 ] || { echo "zl1-lpm-sleep: the heat fix is NOT armed on $bad parameter(s)"; exit 1; }
exit 0
APPLIER_EOF
"${SSH[@]}" "chmod +x $APPLIER; cat > $UNIT" <<'UNIT_EOF'
[Unit]
Description=zl1: let the SoC use its low-power ladder (every cmdline carries lpm_levels.sleep_disabled=1)
# The parameter is a module parameter of a built-in driver, so it exists as soon as the driver is in --
# but the boot's own cmdline is what sets it to 1, and that happens before userspace. Running this as
# early as the filesystem is up is therefore early enough and no earlier step would be any better.
After=local-fs.target
Before=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/etc/systemd/system/zl1-lpm-sleep-fix.sh

[Install]
WantedBy=multi-user.target
UNIT_EOF
"${SSH[@]}" "systemctl daemon-reload && systemctl enable --now zl1-lpm-sleep-fix.service" 2>&1 | tail -2

say ""
say "== the read-back, and it is the ONLY thing here that says the fix is in"
"${SSH[@]}" 'echo "--- systemctl cat (not is-enabled: a unit file that is present is not a unit that is in effect)"
systemctl cat zl1-lpm-sleep-fix.service 2>&1 | head -20
echo
systemctl is-active zl1-lpm-sleep-fix.service; systemctl show zl1-lpm-sleep-fix.service -p ExecMainStatus -p Result
echo
echo "--- the parameter, and the cmdline it disagrees with:"
echo "cmdline: $(cat /proc/cmdline | tr " " "\n" | grep -E "^lpm_levels\.sleep_disabled=" || echo "(absent)")"
for p in /sys/module/*/parameters/sleep_disabled; do [ -e "$p" ] && printf "file:    %s = %s\n" "$p" "$(cat "$p")"; done
echo
echo "--- the cpuidle states (the ladder the fix is supposed to make reachable):"
for d in /sys/devices/system/cpu/cpu0/cpuidle/state*; do [ -e "$d/name" ] && printf "    %-14s usage=%-10s time=%s%s\n" "$(cat $d/name)" "$(cat $d/usage 2>/dev/null)" "$(cat $d/time 2>/dev/null)" "$([ -r $d/disable ] && [ "$(cat $d/disable)" != 0 ] && echo "  <- DISABLED")"; done' 2>&1

# ==================================================================================================
# the verdict is read from the DEVICE, not from any command's exit status
# ==================================================================================================
# This block is why the file does not simply `exit $?`. Every command above returned 0 -- `ssh` did its
# job, `systemctl show` printed a line, the read-back loop ran -- and asserting "installed" from that is
# exactly the shape this repository has recorded over and over: a success that is a statement about the
# transport rather than about the phone. So the verdict is decided by ASKING THE DEVICE two questions
# with answers that can come back wrong:
#
#   * did the unit's own ExecStart exit 0 (ExecMainStatus)? That is the applier's read-back rule.
#   * does the parameter now read 0?
#
# Anything else -- an unreadable value, an empty answer, a missing line -- is reported as
# `not-installed` with the reading that failed, because "could not tell" is not "installed".
EXEC=$(  "${SSH[@]}" "systemctl show zl1-lpm-sleep-fix.service -p ExecMainStatus --value" 2>/dev/null )
ACT=$(   "${SSH[@]}" "systemctl is-active zl1-lpm-sleep-fix.service" 2>/dev/null )
VALUES=$( "${SSH[@]}" 'for p in /sys/module/*/parameters/sleep_disabled; do [ -e "$p" ] && cat "$p"; done' 2>/dev/null )

say ""
say "   the two answers the verdict is made of:"
say "     ExecMainStatus = ${EXEC:-<unreadable>}"
say "     is-active      = ${ACT:-<unreadable>}"
say "     the parameter  = $(printf '%s' "${VALUES:-<unreadable>}" | tr '\n' ' ')"

# Four questions, in order, each of which can come back wrong -- and `elif`, not four independent
# assignments, so the FIRST failure is the one that is reported rather than the last one evaluated.
# (An empty value fails every one of them, which is the point: unreadable is not installed.)
#
# THE FIRST QUESTION IS ASKED AS A STATE, NOT AS A NUMBER, for the reason the applier's own comment
# gives: the parameter is a `bool`, so a value of 0 comes back as `N` and `awk '$1 != 0'` would report
# the fix as not-installed on a device where it had worked. Three spellings mean OFF and the rest do not.
WHY=""
if [ -z "$VALUES" ]; then
  WHY="the parameter could not be read back at all -- no value came back, so there is nothing that says OFF"
elif ! printf '%s\n' "$VALUES" | awk '{v = tolower($1); if (v != "0" && v != "n" && v != "off") f = 1} END {exit f ? 1 : 0}'; then
  # EVERY value must be OFF. A device that exposed two parameters and had one of them refuse is NOT a
  # success -- the same rule the applier applies per file, checked here independently of its exit status.
  WHY="at least one parameter did not read back as OFF (0/N/off): $(printf '%s' "$VALUES" | tr '\n' ' ')"
elif [ "$EXEC" != 0 ]; then
  WHY="the unit ran and ExecMainStatus is '${EXEC:-<unreadable>}', not 0 -- the applier did not confirm its own writes"
elif [ "$ACT" != active ]; then
  WHY="the unit reads '${ACT:-<unreadable>}', not 'active'"
fi

if [ -z "$WHY" ]; then
  always "== verdict: installed"
  say "   The writer is installed, enabled, applied now, and the parameter READS BACK as OFF (the value"
  say "   shown above) on every parameter this boot exposes. It shows N and not 0 because the parameter is"
  say "   a bool module parameter: 0 is what was WRITTEN, N is what a reader SEES. WHAT THIS IS NOT: a"
  say "   statement that the phone runs cooler. The ladder is reachable now on every boot; whether the SoC"
  say "   USES the deep rungs is the cpuidle counters above, and a temperature change is a separate"
  say "   reading (zl1-thermal.sh --ab) with ambient, the battery and this boot's own history all in it."
  exit 0
fi
always "== verdict: not-installed"
bad "   $WHY"
bad "   Nothing here says the fix is armed. Read the output above; the undo is '$0 --remove'."
exit 1
