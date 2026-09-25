#!/bin/sh
# zl1 ladder temperature A/B -- what does BLOCKING the SoC's low-power ladder COST, in degrees?
#
# Read-only by default. With --yes it writes EXACTLY ONE FILE twice: `1` (block the ladder) for one
# window, then `0` (allow it again) for the next, and it PROVES each of the three states by read-back.
#
# WHY THIS EXISTS (docs 121, 153, 160, 163, 164, 165, 166):
#
#   The third heat cause is that every cmdline on this device turns the SoC's low-power ladder off
#   (`lpm_levels.sleep_disabled=1`), and the fix is a runtime write of `0` to that module parameter --
#   `scripts/install-lpm-sleep-fix.sh`, installed on 2026-09-25 (docs 164). What has NEVER been measured
#   is the other sign of it: how many degrees the ladder is WORTH. The counters say it gates the deep
#   states (`state2` entered 0 times in a whole boot with the ladder blocked, +2478 in 120 s with it
#   allowed); they do not say what that buys on the thermal zones, and a fix whose effect is unknown is a
#   fix nobody can rank against the other two causes.
#
#   So this is the temperature half, and it runs in the direction the installer does not: it puts the
#   ladder BACK for one window and watches the zones. That is a write to the same file the installer
#   owns, which is why it is a script with refusals and a trap rather than a line typed into a session.
#
# WHY THREE WINDOWS AND NOT TWO:
#
#   A two-window A/B (before / after the write) cannot tell the ladder's effect from the phone simply
#   warming or cooling over the minute in between. This device idles at ~0.8 of 4 cores and drifts on its
#   own -- two runs of `zl1-thermal.sh` an hour apart read the hottest tsens zone at 45.6 C and 50.9 C with
#   nothing changed in between. So there is a THIRD window after the parameter is put back, and the verdict
#   uses it as a CONTROL: if the warming that appeared when the ladder was blocked is still there once it
#   is allowed again, then whatever warmed the phone was not the ladder, and the run says so instead of
#   reporting the difference as the effect. The middle window is the intervention; the third is the check
#   that the intervention MEANT something.
#
# WHY IT REFUSES:
#
#   Nothing is written until every refusal has passed, and each one names a way this reading could mean
#   something other than what it says:
#
#     A. THE INSTRUMENT IS ON THE DEVICE. `zl1-thermal.sh` owns the zone table and its units -- three
#        conventions at the same instant, and docs 96 records this repository dividing them all by 1000
#        and reporting the hottest SoC zone as 0.6 C. `scripts/host/zl1-heat-fix-chain.sh` scp's it to
#        /tmp/zl1-thermal.sh; if it is not readable this script has nothing to measure WITH.
#     B. THE PARAMETER EXISTS AND IS WRITABLE. A sysfs file that cannot be written is a fact to discover
#        BEFORE the experiment and not in the middle of it. (`sleep_disabled` is mode 0664 -- writable
#        while the device runs -- and that asymmetry with `cpuidle.off`'s 0444 is the whole reason the fix
#        is a write and not a flash, docs 121/153.)
#     C. WINDOW A IS THE FIX AS INSTALLED, i.e. the parameter is OFF (it reads `N`, the ladder allowed).
#        If it reads `Y` then the ladder is blocked, the 06 unit has not applied on this boot or something
#        wrote it back, and window A would not be the state this experiment exists to price. The remedy is
#        named: `--revert` here, or the boot-time unit, which re-applies on every boot.
#
#   The device guard is the one every probe here uses: `compatible`, not a model string.
#
# THE WRITE, AND WHY IT IS SAFE ENOUGH TO MAKE:
#
#   * ONE FILE, ONE BOOT. `sleep_disabled` is not persistent: the next boot sets it to 1 from the cmdline,
#     and 06-lpm-fix's unit then writes 0 again. So this experiment is scoped to one boot by construction,
#     and a reboot is both the escape hatch and the undo.
#   * IT RESTORES ON EVERY EXIT PATH, AND A SIGNAL ENDS THE RUN. A trap writes `0` back whenever the value
#     has actually been changed (`WROTE`), and only then -- so a refusal, --status, or a run that failed
#     before the write cannot write anything at all, which is the promise those paths make. The trap is
#     armed BY THE WRITE'S OWN REDIRECT and not by a read-back: docs 163 measured the other order, where the
#     path that left the file changed without knowing it was exactly the path that left the trap disarmed.
#     And a signal handler that only restores is not enough on its own -- the shell carries on after the
#     interrupted command, so an interrupted run would finish, exit 0, and overwrite the restore. The
#     handler exits 130, and `do_restore` clears `WROTE` only when its own read-back says the restore held,
#     so the exit trap that follows a signal gets a second attempt if the first one did not take. The
#     harness checks all of this by killing a run that is provably in the blocked window.
#   * THE STATE IS COMPARED AS A STATE, NEVER AS A STRING. `sleep_disabled` is a bool module parameter
#     (`static bool sleep_disabled; module_param_named(..., bool, ...)`, lpm-levels.c of the tree that
#     built this kernel), so sysfs renders 0 as `N` and 1 as `Y`. Comparing the read-back with the string
#     that was written is a comparison that can only pass on a file with no type -- and it made the
#     installer refuse its own successful write on 2026-09-25 (docs 163). The two helpers below are the
#     same two the trial carries, for the same reason.
#   * It also PROVES the write path before using it to change anything: the current value is written back
#     to itself and read. That proof is not about the alphabet and cannot be (it passes on any file) -- it
#     is about the file being writable at all.
#
# WHAT IT DOES NOT DO: no block device, no partition, no flash, no module load/unload, no service started
# or stopped, no signal to any process, and no process table parsing. It does not decide whether the ladder
# is a good idea; it prices it, and it can come out at zero.
#
# Usage (on the device, as root):
#   zl1-ladder-temp-ab.sh [--status] [--yes] [--seconds N] [--settle N] [--thermal PATH] [--revert]
#     --status  (default) read everything, write nothing: the refusals, the parameter, the cmdline, the
#               instrument, and what a run would do
#     --yes     run it: window A (as installed), write 1, settle, window B, write 0, settle, window C,
#               then the delta table, the controls and the verdict
#     --seconds N  length of each thermal window (default 45)
#     --settle N   seconds between a write and the window that measures it (default 20; the zones take
#                  seconds to tens of seconds to follow a change in idle power)
#     --thermal P  the instrument's path on the device (default /tmp/zl1-thermal.sh)
#     --revert     put the parameter back to 0 (the INSTALLED state) and verify it -- the one command to
#                  run if anything is odd
#     --explain    what each reading decides, and change nothing
#
# Exit codes: 0 a verdict that is a measurement about the phone (cost-measured OR no-detectable-cost --
#              the second one is this script coming out against the fix it was built around);
#             1 INCONCLUSIVE or CONTAMINATED -- a statement about the RUN and not about the phone;
#             2 not the zl1;
#             3 REFUSED -- a refusal is not met and nothing was written;
#             4 the write happened and something went wrong after it (the state and the restore are
#              printed, and the trap has already tried to undo it).

set -u

MODE=status
SECONDS_WIN=45
SETTLE=20
THERMAL=/tmp/zl1-thermal.sh
YES=0
WROTE=0

while [ $# -gt 0 ]; do
  case "$1" in
  --status) MODE=status; shift ;;
  --yes)    MODE=run; YES=1; shift ;;
  --seconds) SECONDS_WIN="${2?--seconds needs a number}"; shift 2 ;;
  --settle)  SETTLE="${2?--settle needs a number}"; shift 2 ;;
  --thermal) THERMAL="${2?--thermal needs a path}"; shift 2 ;;
  --revert) MODE=revert; shift ;;
  --explain) MODE=explain; shift ;;
  --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

say() { printf '%s\n' "$*"; }
hdr() { printf '\n== %s\n' "$*"; }
bad() { printf '%s\n' "$*" >&2; }

grep -qa msm8996 /proc/device-tree/compatible 2>/dev/null ||
  { bad "not the zl1 (no msm8996 in /proc/device-tree/compatible) -- refusing"; exit 2; }

# A missing file, an empty file and a command that could not run are three different answers, and the
# difference matters here: EMPTY is a parameter that answered nothing, and reading it as `0` would be
# reading "the ladder is allowed" off a file that said nothing at all.
rd() {
  if [ -r "$1" ]; then v=$(tr -d '\n' < "$1" 2>/dev/null); printf '%s' "${v:-EMPTY}"
  else printf 'UNREADABLE'; fi
}

# The parameter's two states, named for the PARAMETER and not for the ladder: `is_off` is sleep_disabled
# reading 0/N (sleep is NOT disabled, the ladder is ALLOWED) -- which is the installed state, and it is the
# baseline the trial's fourth refusal (docs 163) is about. Nothing in this file may compare a value with
# its own rendering; see the header.
is_off() { case "$1" in 0|N|n|off) return 0 ;; *) return 1 ;; esac; }
is_on()  { case "$1" in 1|Y|y|on)  return 0 ;; *) return 1 ;; esac; }

TMP=$(mktemp -d /tmp/zl1-ladder-temp-ab.XXXXXX) || exit 1
trap 'rm -rf "$TMP"' EXIT

# --- the restore, and the trap that makes it happen on every exit path ---------------------------------
# `WROTE` is set the moment the value has actually been CHANGED, and only then. The target is the INSTALLED
# state (0), not the boot's state (the cmdline says 1): what this script borrows must be given back as it
# found it, and it found the ladder allowed.
do_restore() {
  [ "$WROTE" = 1 ] || return 0
  printf '0' > "$PARAM" 2>/dev/null
  P_RESTORE=$(rd "$PARAM")
  if is_off "$P_RESTORE"; then
    WROTE=0   # cleared only when the READ-BACK says the restore held. A restore that did not hold stays owed,
              # so the exit trap after a signal gets a second attempt (bounded: one signal handler and one
              # exit trap), and the message below stays true when it says the trap will try again.
    say "   [trap] $PARAM put back to 0 (it reads '$P_RESTORE'), verified by read-back."
  else
    bad "   [trap] THE RESTORE DID NOT HOLD: $PARAM reads '$P_RESTORE', not 0/N. The exact command is"
    bad "   '$REVERT_CMD'; the next boot's 06-lpm-fix unit writes 0 again anyway, so this cannot outlive"
    bad "   one boot."
  fi
}
# A SIGNAL HAS TO END THE RUN, and the first version of this file did not. Trapping TERM and only
# restoring leaves the shell to CARRY ON after the interrupted `sleep`: the experiment finished, the undo
# overwrote the restore with the boot's own value, and the interrupted run exited 0 -- reporting itself as a
# complete run whose closing line, "the state it started in", was true only because it had run to the end.
# So the handler restores and then exits non-zero. `do_restore` clears `WROTE` only when its read-back says
# the restore held, so the EXIT trap (a separate trap, and it still runs) finds nothing left to undo after a
# restore that worked -- and gets a second attempt, without writing twice, after one that did not.
on_signal() {
  do_restore
  exit 130
}
trap 'do_restore' EXIT
trap 'on_signal' INT TERM HUP

# --- where the parameter is ---------------------------------------------------------------------------
# The path the installer writes, and the only name this repository has measured the device to expose
# (`/sys/module/lpm_levels/parameters/sleep_disabled`, docs 121/153). It is looked up rather than assumed,
# because a renamed module directory would otherwise leave this script writing into a file that does not
# exist -- and a wrong name and a missing parameter produce the same symptom, so the COUNT is printed too.
# The loop is at the top level with names of its own: /bin/sh has no locals, so a helper's loop variable is
# its caller's (a defect this repository has recorded).
PARAM_N=0; PARAM=none
for zl1_p in /sys/module/*/parameters/sleep_disabled; do
  [ -e "$zl1_p" ] || continue
  PARAM_N=$((PARAM_N + 1))
  if [ "$PARAM" = none ]; then PARAM="$zl1_p"; fi
done
REVERT_CMD="printf 0 > $PARAM"

if [ "$MODE" = explain ]; then
  cat <<'EOF'
zl1 ladder temperature A/B -- what each reading decides

  1. THE REFUSALS, checked before anything is written. Each is a way this experiment could produce a
     reading that means something else:
       the instrument is readable   otherwise there is no thermostat and no units, only raw sysfs numbers
                                    whose three conventions this repository has already got wrong once.
       the parameter is writable    a file that cannot be written is a fact to learn BEFORE the write.
       window A is the fix installed (sleep_disabled reads 0/N)   otherwise the ladder is already blocked
                                    and window A is not the state this experiment exists to price.
  2. WINDOW A, as installed: the zones with the ladder ALLOWED. Nothing has been written yet.
  3. THE INTERVENTION AND THE PROOF: write 1, read it back, and REQUIRE it to read as ON (1/Y). A write
     that did not land makes the next window a measurement of the unchanged state -- and it would read as
     "the ladder costs nothing", which is the one wrong answer that looks like a real one.
  4. WINDOW B: the zones with the ladder BLOCKED.
  5. THE UNDO, ALSO PROVED: write 0, read it back, require OFF (0/N).
  6. WINDOW C, the CONTROL: the zones with the ladder allowed again. If the warming seen in window B is
     still there in window C, the ladder did not cause it -- the phone drifted, or the load changed -- and
     the verdict says contaminated rather than reporting a number as the effect.
  7. THE VERDICT:
       cost-measured        B was warmer than A by more than this experiment's resolution, AND C came back
                            down (the third window did not keep the warming)
       no-detectable-cost   B was not warmer than A: the ladder is worth less than the resolution here
       contaminated         the warming persisted into C -- a statement about the RUN
     An intervention that did not land, or an undo that did not hold, is NOT a verdict at all: it exits 4
     with the state printed, because every number below it would be a comparison of two identical states.
     The resolution is 0.2 C, which is two steps of the instrument's own 0.1 C and is printed with the
     verdict, because a threshold nobody can see is a threshold nobody can argue with.
EOF
  exit 0
fi

hdr "zl1 ladder temperature A/B -- $(date -u +%Y-%m-%dT%H:%M:%SZ) UTC"
say "  device:      $(cat /proc/device-tree/model 2>/dev/null || echo unknown)"
say "  parameter:   $PARAM  ($PARAM_N match(es) on this device)"
say "  instrument:  $THERMAL"
say "  windows:     ${SECONDS_WIN}s each, ${SETTLE}s after each write"
case "$(rd /proc/cmdline)" in
*sleep_disabled=1*) say "  cmdline:     sleep_disabled=1 -- the boot was TOLD to block the ladder" ;;
*)                  say "  cmdline:     no sleep_disabled=1 in /proc/cmdline" ;;
esac

if [ "$MODE" = revert ]; then
  hdr "revert: put the parameter back to 0 (the INSTALLED state) and prove it"
  P_NOW=$(rd "$PARAM")
  say "   it reads '$P_NOW' now."
  if is_off "$P_NOW"; then
    say "   it is already 0/N -- nothing to do. Exit 0."
    exit 0
  fi
  WROTE=1   # armed before the write, deliberately: the trap's job starts when the file may have changed
  printf '0' > "$PARAM" || { bad "   the write failed: $PARAM"; exit 4; }
  P_NOW=$(rd "$PARAM")
  if is_off "$P_NOW"; then
    say "   wrote 0 and read '$P_NOW' back: the ladder is allowed again. Exit 0."
    WROTE=0   # verified: there is nothing left for the trap to undo
    exit 0
  fi
  bad "   THE REVERT DID NOT HOLD: $PARAM reads '$P_NOW', not 0/N, so the exact command is '$REVERT_CMD'."
  bad "   The next boot's 06-lpm-fix unit writes 0 again, so this cannot outlive one boot. On the host,"
  bad "   scripts/install-lpm-sleep-fix.sh --install --after-trial <the trial's archived output> re-arms"
  bad "   that unit and applies it now (there is no --now flag on the installer; --install is what applies it)."
  exit 4
fi

# --- the refusals --------------------------------------------------------------------------------------
hdr "the refusals, on their own terms (nothing is written until all of them have passed)"

REFUSED=0

if [ -r "$THERMAL" ]; then
  say "   A. instrument: readable ($THERMAL)"
else
  bad "   REFUSED (A): no readable instrument at $THERMAL. It owns the zone table AND its units --"
  bad "   three conventions at the same instant -- and a second copy of that is a second chance to get"
  bad "   it wrong (docs 96). Push it first, over the host: scp zl1-thermal.sh root@<device>:/tmp/"
  REFUSED=1
fi

if [ "$PARAM_N" -lt 1 ] 2>/dev/null; then
  bad "   REFUSED (B): no /sys/module/*/parameters/sleep_disabled on this device at all. Either this is"
  bad "   not the kernel this repository measured (docs 121/153 read the module_param statement out of"
  bad "   the tree that built it), or the driver is not built in. Nothing can be priced here."
  REFUSED=1
elif [ ! -w "$PARAM" ]; then
  bad "   REFUSED (B): $PARAM is not writable (mode 0664 is what makes this fix a write and not a flash)."
  REFUSED=1
else
  say "   B. parameter:  $PARAM is writable"
fi

P_BEFORE=$(rd "$PARAM")
if [ "$PARAM_N" -lt 1 ] 2>/dev/null; then
  : # B already refused; nothing to read
elif is_off "$P_BEFORE"; then
  say "   C. as installed: '$P_BEFORE' -- sleep is NOT disabled, the ladder is ALLOWED (this is window A)"
else
  bad "   REFUSED (C): $PARAM reads '$P_BEFORE', which is ON (1/Y): the ladder is BLOCKED, so window A"
  bad "   would not be the state the fix installs. Either 06-lpm-fix has not applied on this boot, or"
  bad "   something wrote it back. The remedy is --revert here and now, or just reboot: the boot's own"
  bad "   cmdline says 1 and the unit writes 0 again after it."
  REFUSED=1
fi

# The same-value write proof: the file is written with what it already holds and read back. It says nothing
# about the alphabet (it cannot -- see the header) and everything about the file being writable, and it is
# the reason a read-only sysfs file is discovered here and not after the value has been changed.
if [ "$REFUSED" = 0 ] && [ "$MODE" = run ]; then
  P_PROOF_BEFORE=$(rd "$PARAM")
  printf '%s' "$P_PROOF_BEFORE" > "$PARAM" 2>/dev/null
  P_PROOF=$(rd "$PARAM")
  if [ "$P_PROOF" != "$P_PROOF_BEFORE" ]; then
    bad "   REFUSED (B, proved): writing '$P_PROOF_BEFORE' back to $PARAM read back '$P_PROOF'. The file"
    bad "   is not writable in fact, whatever its mode says, and nothing has been changed."
    REFUSED=1
  else
    say "   B. write path: wrote '$P_PROOF_BEFORE' back to itself and read '$P_PROOF' -- writable."
  fi
fi

if [ "$REFUSED" = 1 ]; then
  hdr "REFUSED -- nothing was written, and the device is exactly as it was"
  exit 3
fi

if [ "$MODE" != run ]; then
  # --status: the refusals, the parameter and the cmdline, and what a run would do. Writes nothing.
  hdr "a run would do this (--status writes nothing)"
  say "   window A: the zones as installed, ${SECONDS_WIN}s"
  say "   write 1, prove it reads ON, wait ${SETTLE}s, window B, ${SECONDS_WIN}s"
  say "   write 0, prove it reads OFF, wait ${SETTLE}s, window C, ${SECONDS_WIN}s  (the control)"
  say "   then the per-zone deltas B-A and C-A and a verdict; the trap restores 0 on every exit path"
  exit 0
fi

# --- the windows ---------------------------------------------------------------------------------------
# One window is one run of the instrument. `--quiet` drops the per-process table: this experiment compares
# THERMAL ZONES and nothing in the process table changes its answer, while the table costs output and the
# busy figure it needs is in the summary line either way.
run_window() { # $1 = label
  sh "$THERMAL" --seconds "$SECONDS_WIN" --quiet > "$TMP/win.$1" 2>&1
  rc=$?
  [ "$rc" = 0 ] || bad "   NOTE: the instrument exited $rc in window $1 (its output is in the archive)"
  b=$(awk '/^[ ]+busy / { print $2; exit }' "$TMP/win.$1" 2>/dev/null)
  printf '%s\n' "${b:-unreadable}"
}

zones_of() { awk '$1 ~ /^thermal_zone[0-9]+$/ && $4 == "C" { print $1, $2, $3 }' "$1" 2>/dev/null; }

hdr "window A -- as installed (the ladder ALLOWED, nothing written yet)"
BUSY_A=$(run_window A)
say "   busy $BUSY_A of 4 cores; $(zones_of "$TMP/win.A" | wc -l | tr -d ' ') zone(s) read"

# THE INTERVENTION, and it is armed before the write: `WROTE=1` means "the file may have changed, so the
# trap owes it a value" -- docs 163 measured the other order (arming after the read-back) leaving the file
# changed with the trap disarmed.
WROTE=1
printf '1' > "$PARAM" || { bad "   the write to $PARAM FAILED; the trap will still try to restore 0"; exit 4; }
P_B=$(rd "$PARAM")
if is_on "$P_B"; then
  say "   wrote 1 and read '$P_B' back: the ladder is BLOCKED from here until the undo."
else
  bad "   THE INTERVENTION DID NOT LAND: wrote 1, read '$P_B', which is not ON (1/Y). Every number below"
  bad "   would be a comparison of two identical states -- i.e. it would read as 'the ladder costs"
  bad "   nothing'. Refusing to print a verdict; restoring 0 and exiting 4."
  exit 4
fi
sleep "$SETTLE"

hdr "window B -- the ladder BLOCKED (the one change this experiment makes)"
BUSY_B=$(run_window B)
say "   busy $BUSY_B of 4 cores"

printf '0' > "$PARAM" || { bad "   the restore write FAILED; the trap will try again on exit"; exit 4; }
P_C=$(rd "$PARAM")
if is_off "$P_C"; then
  say "   wrote 0 and read '$P_C' back: the ladder is ALLOWED again -- this is the state it started in."
  sleep "$SETTLE"
else
  bad "   THE RESTORE DID NOT HOLD: wrote 0, read '$P_C', which is not OFF (0/N). The trap will try again"
  bad "   on exit; refusing to print a verdict from an experiment whose undo failed. Exiting 4."
  exit 4
fi

hdr "window C -- the CONTROL: the ladder allowed again, so the third window is the same state as the first"
BUSY_C=$(run_window C)
say "   busy $BUSY_C of 4 cores"

# The undo is verified once more, and this is the line that decides whether the trap still owes anything.
P_END=$(rd "$PARAM")
if is_off "$P_END"; then
  WROTE=0
  say "   final state: $PARAM reads '$P_END' -- the fix is where this script found it."
else
  bad "   final state: $PARAM reads '$P_END', not 0/N -- leaving the trap armed to try again on exit."
fi

# --- the deltas ----------------------------------------------------------------------------------------
hdr "the per-zone deltas (the instrument's OWN numbers, in its own unit -- it normalised them)"
awk -v A="$TMP/win.A" -v B="$TMP/win.B" -v C="$TMP/win.C" '
  $1 ~ /^thermal_zone[0-9]+$/ && $4 == "C" {
    k = $1; type[k] = $2
    if (FILENAME == A) a[k] = $3 + 0; else if (FILENAME == B) b[k] = $3 + 0; else c[k] = $3 + 0
    if (!(k in seen)) { seen[k] = 1; order[++n] = k }
    next
  }
  END {
    for (i = 1; i <= n; i++) {
      k = order[i]
      if (!((k in a) && (k in b) && (k in c))) { missing++; continue }
      printf "%s %s %.1f %.1f %.1f %.1f %.1f\n", k, type[k], a[k], b[k], c[k], b[k] - a[k], c[k] - a[k]
    }
    if (missing) printf "# %d zone(s) were not readable in all three windows and are not in this table\n", missing > "/dev/stderr"
  }' "$TMP/win.A" "$TMP/win.B" "$TMP/win.C" > "$TMP/deltas" 2>"$TMP/deltas.note"
[ -s "$TMP/deltas.note" ] && { while IFS= read -r l; do say "   $l"; done < "$TMP/deltas.note"; }

if [ ! -s "$TMP/deltas" ]; then
  bad "   NO ZONE WAS READABLE IN ALL THREE WINDOWS: there is no delta table, so there is no reading."
  bad "   That is a statement about this run (and about the instrument), not about the ladder. Exit 1."
  exit 1
fi

say "   zone       type                        A      B      C     B-A    C-A"
sort -k6,6gr "$TMP/deltas" | awk 'NR <= 12 {
  printf "   %-10s %-22s %6.1f %6.1f %6.1f %+6.1f %+6.1f\n", $1, $2, $3, $4, $5, $6, $7 }' 
n_all=$(wc -l < "$TMP/deltas" | tr -d ' ')
[ "$n_all" -gt 12 ] && say "   ... $(($n_all - 12)) more; the whole table is in the archive (it is one line per zone)"

# --- the verdict ---------------------------------------------------------------------------------------
# The maximum is taken over the TSENS zones, which are the SoC's own sensors: battery and pm8994 follow the
# charger and the rails, and a delta there is a delta about the power supply rather than about the core.
TSENS=$(awk '$2 ~ /^tsens_tz_sensor/ { print }' "$TMP/deltas")
if [ -z "$TSENS" ]; then
  bad "   no tsens zone was readable in all three windows, and those are the SoC's own sensors. Exit 1."
  exit 1
fi
MAX_BA=$(printf '%s\n' "$TSENS" | sort -k6,6gr | head -1)
MAX_CA=$(printf '%s\n' "$TSENS" | sort -k7,7gr | head -1)
BA=$(printf '%s' "$MAX_BA" | awk '{ printf "%.1f", $6 }')
CA=$(printf '%s' "$MAX_CA" | awk '{ printf "%.1f", $7 }')
ZONE_BA=$(printf '%s' "$MAX_BA" | awk '{ print $1" ("$2")" }')
ZONE_CA=$(printf '%s' "$MAX_CA" | awk '{ print $1" ("$2")" }')

hdr "the verdict"
say "   window A was the ladder ALLOWED (the fix as installed); B was the ladder BLOCKED; C was allowed"
say "   again. Busy: A $BUSY_A, B $BUSY_B, C $BUSY_C of 4 cores (a READING, not a gate: the ladder works"
say "   on idle power, and this figure counts busy time, so the two are not expected to track)."
say "   the largest warming from A to B on any tsens zone: ${BA} C  ($ZONE_BA)"
say "   and from A to C (the control, same state as A):   ${CA} C  ($ZONE_CA)"
say "   the threshold this experiment calls a cost: 0.2 C -- two steps of the instrument's 0.1 C"
say ""

# `awk` compares the two numbers rather than the shell, which has no floating point at all (and would
# compare "10.0" and "9.0" as strings and agree with the wrong one).
VERDICT=$(awk -v ba="$BA" -v ca="$CA" '
  BEGIN {
    if (ba < 0.2)                     { print "no-detectable-cost"; exit }
    if (ca >= ba / 2)                 { print "contaminated"; exit }
    print "cost-measured"
  }')

if [ "$VERDICT" = no-detectable-cost ]; then
  say "   -> NO DETECTABLE COST: blocking the ladder did not warm the SoC by as much as this experiment can"
  say "      resolve. That is this script coming out AGAINST the fix it was built around: the third cause's"
  say "      value is in the deep-state counters (docs 164), not in these zones at this load."
  RC=0
elif [ "$VERDICT" = contaminated ]; then
  say "   -> CONTAMINATED: B was warmer than A by ${BA} C, but C -- the SAME state as A -- is still ${CA} C"
  say "      above A. So the warming did not come back with the ladder's state and was not caused by it: the"
  say "      phone drifted, or the load did. A statement about this RUN, not about the ladder."
  RC=1
else
  say "   -> COST-MEASURED: blocking the ladder warmed the hottest tsens zone by ${BA} C (${ZONE_BA}), and"
  say "      putting it back did not leave that warming behind (C is ${CA} C above A). At this load, that is"
  say "      what the third heat cause is worth in temperature."
  RC=0
fi

say ""
say "   Read it as a READING and not as the ladder's price in general: ambient is not controlled, the"
say "   battery's charging state is not controlled, and the third window can only catch a drift that"
say "   outlasts the second -- a drift that happens to peak in window B and vanish in C is indistinguishable"
say "   from this effect HERE, and is exactly what the control cannot rule out. The zones are the"
say "   instrument's numbers, normalised by it; this script does not divide anything."
say ""
say "   The parameter is $(rd "$PARAM") ($PARAM) -- the state it started in."
exit "$RC"
