#!/bin/sh
# zl1 governor temperature A/B -- price the SECOND heat cause on the device, in degrees.
#
# WHAT IT PRICES. The v63 image ships all four cores pinned on the `performance` governor; the fix
# (`install-cpufreq-governor.sh`, installed 2026-09-25, docs 164) writes `interactive` and holds it with a
# unit that re-arms on every boot. That fix has been in place since docs 164 and **its own effect was never
# measured** -- docs 167 says so out loud in its section 5: the run that priced the third cause covered
# causes (1) and (2) as a background and priced (3) alone.
#
# This is the same three-window design as the ladder instrument (docs 166), for the same measured reason: the
# phone DRIFTS (45.6 -> 50.9 C in an hour with nothing changed), so two windows cannot separate a cause from
# the drift. A (as installed) -> write the pre-fix value -> B -> put it back -> C (the control, A's state
# again). The verdict is a SIGN TABLE, not a number: if B is warm and C comes back down, the warming belongs
# to the governor; if C stays warm, the run was contaminated and the script says so instead of reporting a
# number.
#
# THE WAIT BEFORE C (docs 170). The first device run came back CONTAMINATED, and not for the reason the design
# had named: pinning the cores warmed the SoC and 45 s of the fix's state did not shed it, so C read 48.0 C
# against A's 40.9 C. A control window can only catch a drift that VANISHES by the time it is read, so the run
# now WAITS for the reading to come back within MARGIN of window A, with a bound (SETTLE_BACK), and PRINTS how
# long it took. A reading that never comes back is its own verdict (`no-return`, exit 1) and the run prints NO
# PRICE -- which is the honest answer, because "the intervention's heat has not decayed" and "the phone
# drifted more than the margin" look identical here, and neither is a price for the governor.
#
# THE KNOB IS FOUR FILES, NOT ONE, and that is the whole difference from the ladder instrument. There is no
# `tr` alphabet here (a governor name is stored and read back as itself) and no module parameter: the state
# is `/sys/devices/system/cpu/cpuN/cpufreq/scaling_governor`, one per core, and "the fix is installed" means
# ALL FOUR read `interactive`. A write that lands on three of four cores is a fourth of an experiment, which
# is why every core is written, read back, and required to agree -- and why the count of cores is printed.
#
# WHAT IT DOES NOT DO. It writes four governor files and nothing else. No partition, no block device, no
# module parameter, no service restart, no reboot. The value it writes back is the FIX's own value
# (`interactive`), so the device is left exactly where it was found -- and even if it were not, the boot's
# own zl1-cpufreq-governor unit writes `interactive` again on the next boot. It removes its own scratch
# directory on the way out unless `--keep`, and the restore and the cleanup are ONE trap: the version that
# had two EXIT traps never cleaned up at all, silently, because the second replaces the first (docs 170).
#
# Usage:
#     zl1-governor-temp-ab.sh --status            the refusals, the state, and what a run would do (writes nothing)
#     zl1-governor-temp-ab.sh --yes               run the experiment (this is the write)
#     zl1-governor-temp-ab.sh --seconds N --settle N --thermal PATH
#     zl1-governor-temp-ab.sh --settle-back N --poll N --margin C
#                                                 the WAIT between the undo and the control window (see below)
#     zl1-governor-temp-ab.sh --keep              leave the run's own files and print where they are
#     zl1-governor-temp-ab.sh --revert            put every core back on `interactive` and prove it
#     zl1-governor-temp-ab.sh --explain           what each reading decides, and change nothing
#
# Exit codes: 0 a verdict that is a measurement about the phone (cost-measured OR no-detectable-cost --
#             the second one is this script coming out against the fix it was built around);
#             1 NO-RETURN, INCONCLUSIVE or CONTAMINATED -- a statement about the RUN and not about the phone;
#             2 not the zl1;
#             3 REFUSED -- a refusal is not met and nothing was written;
#             4 the write happened and something went wrong after it (the state and the restore are
#             printed, and the trap has already tried to undo it).

set -u

MODE=status
SECONDS_WIN=45
SETTLE=20
THERMAL=/tmp/zl1-thermal.sh
YES=0
WROTE=0
KEEP=0
NO_RETURN=0
# THE WAIT. The first device run of this instrument (2026-09-25, docs 170) came back CONTAMINATED for a
# reason the design had not named: 45 s after the undo the SoC was still ~7 C above window A, so the control
# window started on a phone that had not shed the intervention's heat -- and a control window can only catch
# a drift that VANISHES by the time it is read. Waiting for the reading to COME BACK, with a bound, is not a
# nicety: it is what makes the third window a control instead of a second reading of the thermal mass. The
# wait is itself a measurement and the run prints how long it took. `--settle-back 0` turns it off, which
# restores the old (weaker) behaviour on purpose -- with the wait off, `contaminated` is the likely verdict
# and the operator should know that is a property of the design and not of the governor.
SETTLE_BACK=240
POLL=10
MARGIN=0.5

# The two states, named for the FIX and not for the governor: FIX_GOV is what the installer writes and what
# window A must already be; BLOCKED_GOV is the image's own value, i.e. the cause put back. Nothing here
# compares a value with a rendering of it -- a governor name is stored as itself -- but the write is still
# PROVED by read-back, because a governor the kernel does not offer makes the write fail silently and leave
# the old value in place, and that failure reads exactly like "the governor costs nothing".
FIX_GOV=interactive
BLOCKED_GOV=performance

while [ $# -gt 0 ]; do
  case "$1" in
  --status) MODE=status; shift ;;
  --yes)    MODE=run; YES=1; shift ;;
  --seconds) SECONDS_WIN="${2?--seconds needs a number}"; shift 2 ;;
  --settle)  SETTLE="${2?--settle needs a number}"; shift 2 ;;
  --settle-back) SETTLE_BACK="${2?--settle-back needs a number}"; shift 2 ;;
  --poll)    POLL="${2?--poll needs a number}"; shift 2 ;;
  --margin)  MARGIN="${2?--margin needs a temperature}"; shift 2 ;;
  --keep)    KEEP=1; shift ;;
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
# difference matters here: EMPTY is a file that answered nothing, and reading it as "the fix is installed"
# would be reading a state off a file that said nothing at all.
rd() {
  if [ -r "$1" ]; then v=$(tr -d '\n' < "$1" 2>/dev/null); printf '%s' "${v:-EMPTY}"
  else printf 'UNREADABLE'; fi
}

TMP=$(mktemp -d /tmp/zl1-governor-temp-ab.XXXXXX) || exit 1
# NO EXIT TRAP HERE, and that is the fix for a defect the first device run found (docs 170). This line used
# to be `trap 'rm -rf "$TMP"' EXIT`, and the restore installs `trap 'do_restore' EXIT` further down -- which
# REPLACES it, because a POSIX shell keeps ONE action per condition. So the cleanup never ran once: every
# invocation leaked its scratch directory, including the read-only `--status`, and the message that says
# "the whole table is in the archive" pointed at a path nothing printed. The two are ONE trap now, set where
# the restore is set, so they cannot cancel each other; `--keep` is the only way to opt out of the cleanup.
cleanup() {
  if [ "$KEEP" = 1 ]; then
    say ""
    say "   --keep: this run's scratch directory is $TMP (deltas, deltas.note, win.A/B/C, back)."
    return 0
  fi
  rm -rf "$TMP"
  say ""
  say "   the scratch directory $TMP was removed (--keep leaves it instead, and a failed window forces it on)."
}

# --- the cores, found rather than assumed --------------------------------------------------------------
# The glob is the only name this repository has measured the device to expose, and it is looked up for the
# same reason the ladder instrument looks up its parameter: a renamed path and a missing knob produce the
# same symptom, so the COUNT is printed too. The loop is at the top level with names of its own -- /bin/sh
# has no locals, so a helper's loop variable is its caller's, which is a defect this repository has recorded.
CPU_N=0; CPUS=""
for zl1_g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  [ -e "$zl1_g" ] || continue
  CPU_N=$((CPU_N + 1))
  CPUS="$CPUS $zl1_g"
done
CPUS=${CPUS# }
FIRST_CPU=
for zl1_g in $CPUS; do FIRST_CPU=$zl1_g; break; done
REVERT_CMD="for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do printf '%s' $FIX_GOV > \$g; done"

# write_gov VALUE -- write it to EVERY core, then read every core back. Prints nothing and returns 0 only
# when every core reads what was written. The read-back is the point: a governor the kernel does not offer
# is refused by the write, the file keeps its old value, and a script that trusted the write would go on to
# measure two identical states and report "this cause costs nothing".
write_gov() {
  zl1_want="$1"
  for zl1_g in $CPUS; do
    printf '%s' "$zl1_want" > "$zl1_g" 2>/dev/null || return 1
  done
  for zl1_g in $CPUS; do
    [ "$(rd "$zl1_g")" = "$zl1_want" ] || return 1
  done
  return 0
}
# gov_state -- one word for the whole machine: the value every core agrees on, `mixed` if they disagree, or
# `none` if there are no cores at all. "All four cores read the same thing" IS the state this experiment
# moves, so a machine whose cores disagree has no window A to speak of.
gov_state() {
  zl1_s=none
  for zl1_g in $CPUS; do
    zl1_v=$(rd "$zl1_g")
    if [ "$zl1_s" = none ]; then zl1_s="$zl1_v"
    elif [ "$zl1_s" != "$zl1_v" ]; then zl1_s=mixed; fi
  done
  printf '%s' "$zl1_s"
}
# The core's NAME, out of its path -- and NOT by stripping `/cpu` off the front. Both obvious forms are wrong
# on this path and both were measured here: the path contains `/cpu` TWICE (`.../system/cpu/cpu0/cpufreq/...`)
# and a third time in `/cpufreq`, so `${p#*/cpu}` removes up to the first one and leaves `/cpu0/...`, while
# `${p##*/cpu}` removes up to the LAST one and leaves `req/scaling_governor`. The first version of this printed
# `cpu=` beside every value -- an empty name, in a diagnostic whose whole job is to say WHICH core. Removing
# the known suffix and taking the last component has no such ambiguity.
cpu_name() {
  zl1_c=${1%/cpufreq/scaling_governor}
  printf '%s' "${zl1_c##*/}"
}
gov_list() {
  for zl1_g in $CPUS; do
    printf ' %s=%s' "$(cpu_name "$zl1_g")" "$(rd "$zl1_g")"
  done
}
# does the kernel OFFER this governor on this core? Read from scaling_available_governors, which is the
# file the kernel fills with what it will accept. A value that is not in there is a write that cannot land,
# so it is refused before anything is written rather than discovered as "the intervention did not land".
gov_offered() { # $1 = the governor file, $2 = the value
  zl1_avail="${1%/scaling_governor}/scaling_available_governors"
  [ -r "$zl1_avail" ] || return 1
  for zl1_w in $(cat "$zl1_avail" 2>/dev/null); do [ "$zl1_w" = "$2" ] && return 0; done
  return 1
}

# --- the restore, and the trap that makes it happen on every exit path ---------------------------------
# `WROTE` is set the moment a core's value may have CHANGED, and only then. The target is the FIX's value
# (`interactive`), not the boot's: what this script borrows must be given back as it found it, and it found
# the fix installed.
do_restore() {
  [ "$WROTE" = 1 ] || return 0
  if write_gov "$FIX_GOV"; then
    WROTE=0   # cleared only when the READ-BACK says the restore held, so the exit trap after a signal gets a
              # second, bounded attempt rather than a second write on a restore that already worked
    say "   [trap] every core put back on '$FIX_GOV' (state now '$(gov_state)'), verified by read-back."
  else
    bad "   [trap] THE RESTORE DID NOT HOLD: the cores read '$(gov_state)'. The exact command is"
    bad "   '$REVERT_CMD'; the boot's own zl1-cpufreq-governor unit writes '$FIX_GOV' again on the next"
    bad "   boot, so this cannot outlive one boot."
  fi
}
# A SIGNAL HAS TO END THE RUN. A trapped signal does not end a POSIX sh run: the shell resumes after the
# interrupted command, so a restore-only handler lets the experiment finish over its own undo, overwrite the
# restore with the boot's value and exit 0 -- reporting itself as a complete run. The handler restores and
# then exits non-zero. `do_restore` clears `WROTE` only when its read-back says the restore held, so the
# EXIT trap (a separate trap, and it still runs) finds nothing to undo after a restore that worked.
on_signal() {
  do_restore
  exit 130
}
# ONE EXIT TRAP, doing BOTH jobs -- restore first, then cleanup -- because two EXIT traps cannot coexist:
# the second replaces the first, silently, and that is exactly how the cleanup came to never run (docs 170).
# `on_signal` restores and exits 130; the EXIT trap then runs too, finds `WROTE=0` (do_restore clears it only
# when its read-back said the restore held) and cleans up.
trap 'do_restore; cleanup' EXIT
trap 'on_signal' INT TERM HUP

if [ "$MODE" = explain ]; then
  cat <<'EOF'
zl1 governor temperature A/B -- what each reading decides

  1. THE REFUSALS, checked before anything is written. Each is a way this experiment could produce a
     reading that means something else -- except the first, which is about whether a mistake is survivable:
       a panic does NOT arm EDL     every download_mode parameter reads 0. This writes a live power knob,
                                    so without it 'a hang reboots the phone' becomes 'a hang costs a finger'
                                    (the trial's refusal A, docs 122, and docs 166's section 7 for the day
                                    this exact gate was missing from a copy of that experiment)
       the instrument is readable   otherwise there is no thermostat and no units, only raw sysfs numbers
                                    whose three conventions this repository has already got wrong once
       the cores are writable, and BOTH values are offered on EVERY core   a governor the kernel does not
                                    offer is a write that cannot land; that failure would read as 'this
                                    cause costs nothing', which is the one wrong answer that looks real
       window A is the fix installed (every core reads 'interactive')   otherwise the cores are already
                                    pinned and window A is not the state this experiment exists to price
  2. WINDOW A, as installed: the zones with all four cores on 'interactive'. Nothing has been written yet.
  3. THE INTERVENTION AND THE PROOF: write 'performance' to every core, read every core back, and REQUIRE
     all of them to read it. A write that landed on three of four would make the next window a measurement
     of a quarter of the change -- and would read as a smaller cost, i.e. as a real number.
  4. WINDOW B: the zones with the cores pinned, i.e. the image's own state, the second heat cause put back.
  5. THE UNDO, ALSO PROVED: write 'interactive' to every core and require every core to read it.
  6. THE WAIT, and this is what makes the next step a CONTROL. Window C reads the same GOVERNOR as A, which
     is not the same thing as reading the same STATE: pinning the cores warms the SoC, and thermal mass does
     not care that the governor was put back 20 s ago. The first device run of this instrument (docs 170)
     read A 40.9 -> B 47.7 -> C 48.0 and came back CONTAMINATED for exactly that reason. So after the undo
     the run waits for the hottest tsens zone to come back to within MARGIN of window A, up to SETTLE_BACK
     seconds, polling every POLL, and PRINTS HOW LONG IT TOOK. That number is the phone's thermal behaviour
     under this intervention, and it is worth having on its own.
  7. WINDOW C, the CONTROL: the fix's state again, read only once the reading has come back. If the warming
     seen in window B is still there in window C -- after the wait said it had gone -- the governor did not
     cause it and the verdict says contaminated rather than reporting a number as the effect.
  8. THE VERDICT:
       cost-measured        B was warmer than A by more than this experiment's resolution, AND C came back
                            down (the third window did not keep the warming)
       no-detectable-cost   B was not warmer than A: pinning the cores is worth less than the resolution
                            here -- which is this script coming out against the fix it was built around
       contaminated         the warming persisted into C -- a statement about the RUN
       no-return            the reading did not come back within SETTLE_BACK, so there IS no control window
                            and the run prints NO PRICE. Two things look like this -- the intervention's
                            warming has not decayed, or the phone drifted by more than MARGIN -- and the
                            instrument cannot tell them apart. Both are statements about the phone.
     An intervention that did not land, or an undo that did not hold, is NOT a verdict at all: it exits 4
     with the state printed, because every number below it would be a comparison of two identical states.
     The resolution is 0.2 C, which is two steps of the instrument's own 0.1 C and is printed with the
     verdict, because a threshold nobody can see is a threshold nobody can argue with.
     --settle-back 0 turns the wait OFF and restores the old design: window C then starts on a phone that
     may still be holding the intervention's heat, and 'contaminated' becomes a property of that setting.
EOF
  exit 0
fi

# --- the panic -> EDL escalation, read HERE because the header reports it -------------------------------
# A. It is checked first because it is about whether a hang is SURVIVABLE rather than about whether the
# reading is good. EVERY `download_mode` parameter is read rather than the first one found: the unit that
# arms this policy loops the same glob and fails itself if any of them did not clear, so a gate satisfied by
# the first match can be satisfied by a knob the policy does not clear. An UNREADABLE knob is not a disarmed
# escalation, so it lands in the same bucket as a knob that reads 1.
DL_N=0; DL_BAD=
for zl1_d in /sys/module/*/parameters/download_mode; do
  [ -e "$zl1_d" ] || continue
  DL_N=$((DL_N + 1))
  zl1_v=$(rd "$zl1_d")
  [ "$zl1_v" = 0 ] || DL_BAD="$DL_BAD $zl1_d=$zl1_v"
done
DL_BAD=${DL_BAD# }

hdr "zl1 governor temperature A/B -- $(date -u +%Y-%m-%dT%H:%M:%SZ) UTC"
say "  device:      $(cat /proc/device-tree/model 2>/dev/null || echo unknown)"
say "  cores:       $CPU_N (${CPUS:-none})"
say "  instrument:  $THERMAL"
say "  windows:     ${SECONDS_WIN}s each, ${SETTLE}s after each write"
say "  states:      A/C '$FIX_GOV' (the fix, installed)  B '$BLOCKED_GOV' (the image's own value)"
say "  panic guard: $(if [ "$DL_N" = 0 ]; then echo "NO download_mode PARAMETER -- a panic would arm EDL"; \
                     elif [ -n "$DL_BAD" ]; then echo "ARMED ($DL_BAD) -- a panic would arm EDL"; \
                     else echo "disarmed ($DL_N parameter(s) read 0) -- a panic reboots"; fi)"
say "  now:        $(gov_state)$(gov_list)"

if [ "$MODE" = revert ]; then
  hdr "revert: put every core back on '$FIX_GOV' (the INSTALLED state) and prove it"
  S_NOW=$(gov_state)
  say "   the state is '$S_NOW' now."
  if [ "$S_NOW" = "$FIX_GOV" ]; then
    say "   already '$FIX_GOV' on every core -- nothing to do. Exit 0."
    exit 0
  fi
  WROTE=1   # armed before the write, deliberately: the trap's job starts when a file may have changed
  if write_gov "$FIX_GOV"; then
    say "   wrote '$FIX_GOV' to all $CPU_N core(s) and read '$(gov_state)' back. Exit 0."
    WROTE=0   # verified: there is nothing left for the trap to undo
    exit 0
  fi
  bad "   THE REVERT DID NOT HOLD: the cores read '$(gov_state)', not '$FIX_GOV'. The exact command is"
  bad "   '$REVERT_CMD'. The boot's own zl1-cpufreq-governor unit writes '$FIX_GOV' again on the next boot,"
  bad "   so this cannot outlive one boot; on the host, scripts/install-cpufreq-governor.sh --install"
  bad "   re-arms that unit and applies it now."
  exit 4
fi

# --- the refusals --------------------------------------------------------------------------------------
hdr "the refusals, on their own terms (nothing is written until all of them have passed)"

REFUSED=0

if [ "$DL_N" = 0 ]; then
  bad "   REFUSED (A): no /sys/module/*/parameters/download_mode on this device, so the panic -> EDL"
  bad "   escalation cannot be checked, and 'cannot be checked' is not satisfied. A hang while this"
  bad "   experiment has the cores pinned would then be an EDL trip rather than a reboot. Arm it first:"
  bad "   scripts/install-no-edl-on-panic.sh --install"
  REFUSED=1
elif [ -n "$DL_BAD" ]; then
  bad "   REFUSED (A): A PANIC WOULD ARM EDL -- $DL_BAD  (1 = the image default). This script writes live"
  bad "   cpufreq knobs, and the difference is 'a hang reboots the phone' versus 'a hang costs a finger'."
  bad "   Arm it first: scripts/install-no-edl-on-panic.sh --install     # then re-run this"
  [ "$DL_N" -gt 1 ] && bad "   ($DL_N download_mode parameter(s) exist; the unit that arms this clears ALL of them.)"
  REFUSED=1
else
  say "   A. panic guard: all $DL_N download_mode parameter(s) read 0 -- a panic reboots, not EDL"
fi

if [ -r "$THERMAL" ]; then
  say "   B. instrument: readable ($THERMAL)"
else
  bad "   REFUSED (B): no readable instrument at $THERMAL. It owns the zone table AND its units -- three"
  bad "   conventions at the same instant -- and a second copy of that is a second chance to get it wrong"
  bad "   (docs 96). Push it first, over the host: scp zl1-thermal.sh root@<device>:/tmp/"
  REFUSED=1
fi

# C. every core writable, and BOTH values offered on EVERY core. The offer check is what makes this refusal
# different from the ladder's: a bool parameter either exists or does not, while a governor can exist as a
# file and still refuse the value, and that refusal is silent at the write site.
if [ "$CPU_N" -lt 1 ] 2>/dev/null; then
  bad "   REFUSED (C): no /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor on this device at all."
  bad "   Either the cpufreq core is not built in or the driver did not bind, and nothing about the second"
  bad "   heat cause can be priced without a core whose governor can be changed."
  REFUSED=1
else
  C_BAD=
  for zl1_g in $CPUS; do
    zl1_c=$(cpu_name "$zl1_g")
    [ -w "$zl1_g" ] || C_BAD="$C_BAD $zl1_c=not-writable"
    gov_offered "$zl1_g" "$FIX_GOV"     || C_BAD="$C_BAD $zl1_c=no-$FIX_GOV"
    gov_offered "$zl1_g" "$BLOCKED_GOV" || C_BAD="$C_BAD $zl1_c=no-$BLOCKED_GOV"
  done
  if [ -n "$C_BAD" ]; then
    bad "   REFUSED (C):$C_BAD"
    bad "   Every core must be writable AND must offer both '$FIX_GOV' and '$BLOCKED_GOV' (read from each"
    bad "   core's scaling_available_governors). A governor the kernel does not offer is a write that"
    bad "   cannot land, and a write that did not land would be measured as 'this cause costs nothing'."
    REFUSED=1
  else
    say "   C. cores:      all $CPU_N are writable and offer both '$FIX_GOV' and '$BLOCKED_GOV'"
  fi
fi

S_BEFORE=$(gov_state)
if [ "$CPU_N" -lt 1 ] 2>/dev/null; then
  : # C already refused; nothing to read
elif [ "$S_BEFORE" = "$FIX_GOV" ]; then
  say "   D. as installed: all $CPU_N core(s) read '$S_BEFORE' -- the fix is in place (this is window A)"
elif [ "$S_BEFORE" = mixed ]; then
  bad "   REFUSED (D): the cores do not agree --$(gov_list)"
  bad "   'all four cores on the same governor' IS the state this experiment moves, so a machine whose"
  bad "   cores disagree has no window A. Re-run with --revert if that is what you want, then try again."
  REFUSED=1
else
  bad "   REFUSED (D): the cores read '$S_BEFORE', not '$FIX_GOV': the second heat cause is still installed,"
  bad "   so window A would not be the state the fix installs and this experiment would be pricing the"
  bad "   image's own setting against itself. Either zl1-cpufreq-governor has not applied on this boot, or"
  bad "   something wrote it back. The remedy is --revert here and now, or just reboot: the unit writes"
  bad "   '$FIX_GOV' again after it."
  REFUSED=1
fi

# The same-value write proof: every core is written with what it already holds and read back. It says nothing
# about whether the OTHER value would land (refusal C does that) and everything about the file being
# writable in fact, and it is the reason a core that lies about its mode is found here rather than after the
# state has been changed.
if [ "$REFUSED" = 0 ] && [ "$MODE" = run ]; then
  S_PROOF_BEFORE=$(gov_state)
  if write_gov "$S_PROOF_BEFORE"; then
    say "   C. write path: wrote '$S_PROOF_BEFORE' back to all $CPU_N core(s) and read '$S_PROOF_BEFORE'"
    say "                  back -- writable in fact, and every core agrees on what it read."
  else
    bad "   REFUSED (C, proved): writing '$S_PROOF_BEFORE' back to the cores read '$(gov_state)'. The files"
    bad "   are not writable in fact, whatever their mode says, and nothing has been changed."
    REFUSED=1
  fi
fi

if [ "$REFUSED" = 1 ]; then
  hdr "REFUSED -- nothing was written, and the device is exactly as it was"
  exit 3
fi

if [ "$MODE" != run ]; then
  # --status: the refusals, the state, and what a run would do. Writes nothing.
  hdr "a run would do this (--status writes nothing)"
  say "   window A: the zones as installed ('$FIX_GOV' on all $CPU_N cores), ${SECONDS_WIN}s"
  say "   write '$BLOCKED_GOV' to every core, prove all of them read it, wait ${SETTLE}s, window B, ${SECONDS_WIN}s"
  say "   write '$FIX_GOV' back, prove all of them read it, then WAIT (up to ${SETTLE_BACK}s, every ${POLL}s) for"
  if [ "$SETTLE_BACK" = 0 ]; then
    say "   the reading to return to within ${MARGIN} C of window A -- WAIT DISABLED (--settle-back 0), so window C"
    say "   starts on a phone that may still be holding the intervention's heat."
  else
    say "   the reading to return to within ${MARGIN} C of window A, and say how long that took"
  fi
  say "   window C, ${SECONDS_WIN}s (the control); then the per-zone deltas B-A and C-A and a verdict"
  say "   the trap restores '$FIX_GOV' on every exit path, and removes $TMP unless --keep"
  exit 0
fi

# --- the windows ---------------------------------------------------------------------------------------
# One window is one run of the instrument. `--quiet` drops the per-process table: this experiment compares
# THERMAL ZONES and nothing in the process table changes its answer, while the table costs output and the
# busy figure it needs is in the summary line either way.
run_window() { # $1 = label
  sh "$THERMAL" --seconds "$SECONDS_WIN" --quiet > "$TMP/win.$1" 2>&1
  rc=$?
  if [ "$rc" != 0 ]; then
    # The path is named, and the evidence is KEPT, because the interesting case is the one where something
    # went wrong -- and an error whose evidence is deleted on the way out is an error nobody can look at.
    KEEP=1
    bad "   NOTE: the instrument exited $rc in window $1; its output is $TMP/win.$1 (kept: --keep is forced on"
    bad "   when a window fails, because that file is the only copy)"
  fi
  b=$(awk '/^[ ]+busy / { print $2; exit }' "$TMP/win.$1" 2>/dev/null)
  printf '%s\n' "${b:-unreadable}"
}

zones_of() { awk '$1 ~ /^thermal_zone[0-9]+$/ && $4 == "C" { print $1, $2, $3 }' "$1" 2>/dev/null; }
# The hottest TSENS zone in one instrument output, or nothing at all. TSENS only, for the same reason the
# verdict takes its maximum over those and not over the table: the battery and the pm8994 rails follow the
# charger, so "the hottest zone" there would be a reading about the power supply. Empty output means NOT
# READABLE, and every caller treats that as its own answer rather than as zero.
hot_tsens() {
  awk '$1 ~ /^thermal_zone[0-9]+$/ && $2 ~ /^tsens_tz_sensor/ && $4 == "C" {
         if (!seen || $3 + 0 > m) { m = $3 + 0; seen = 1 } }
       END { if (seen) printf "%.1f", m }' "$1" 2>/dev/null
}

hdr "window A -- as installed (every core on '$FIX_GOV', nothing written yet)"
BUSY_A=$(run_window A)
say "   busy $BUSY_A of 4 cores; $(zones_of "$TMP/win.A" | wc -l | tr -d ' ') zone(s) read"

# THE INTERVENTION, and it is armed before the write: `WROTE=1` means "a core may have changed, so the trap
# owes it a value" -- docs 163 measured the other order (arming after the read-back) leaving the file changed
# with the trap disarmed.
WROTE=1
if write_gov "$BLOCKED_GOV"; then
  say "   wrote '$BLOCKED_GOV' to all $CPU_N core(s) and read '$(gov_state)' back: the cores are PINNED from"
  say "   here until the undo (this is the image's own state -- the second heat cause put back)."
else
  bad "   THE INTERVENTION DID NOT LAND: after writing '$BLOCKED_GOV' the cores read '$(gov_state)'. Every"
  bad "   number below would be a comparison of two identical states -- i.e. it would read as 'the governor"
  bad "   costs nothing'. Refusing to print a verdict; restoring '$FIX_GOV' and exiting 4."
  exit 4
fi
sleep "$SETTLE"

hdr "window B -- the cores PINNED (the one change this experiment makes)"
BUSY_B=$(run_window B)
say "   busy $BUSY_B of 4 cores"

if write_gov "$FIX_GOV"; then
  say "   wrote '$FIX_GOV' to all $CPU_N core(s) and read '$(gov_state)' back: this is the state it started in."
  sleep "$SETTLE"
else
  bad "   THE RESTORE DID NOT HOLD: after writing '$FIX_GOV' the cores read '$(gov_state)'. The trap will try"
  bad "   again on exit; refusing to print a verdict from an experiment whose undo failed. Exiting 4."
  exit 4
fi

# --- the wait: does the reading COME BACK before the control window reads it? ---------------------------
# Window C is a control only if it reads the SAME state as A. It reads the same GOVERNOR, which is not the
# same thing: pinning the cores warms the SoC, and thermal mass does not care that the governor was put back.
# The first device run (docs 170) read A 40.9 -> B 47.7 -> C 48.0 -- the whole run warmed and C never came
# back -- and a control window cannot tell that from an intervention that really did cost 6.8 C. So the run
# now WAITS for the reading to return within $MARGIN of window A, with a bound, and PRINTS HOW LONG.
# The wait is not a settling delay: it is the measurement that makes the third window mean something, and a
# reading that never comes back is its own result -- about the phone's thermal mass, not about the governor.
hdr "the wait -- does window A's reading come back before the control window reads it?"
W_A=$(hot_tsens "$TMP/win.A")
WAITED=0; W_NOW=; RETURNED=0
if [ -z "$W_A" ]; then
  bad "   window A had no readable tsens zone at all, so there is no reading for this to come back to. The"
  bad "   wait is skipped and the verdict below cannot be trusted; that is a statement about the instrument."
elif [ "$SETTLE_BACK" = 0 ]; then
  say "   --settle-back 0: THE WAIT IS OFF. Window C will start immediately after the undo, so if the"
  say "   intervention's heat has not decayed by then the control window cannot separate it from the"
  say "   governor -- which is what the first device run of this instrument measured (docs 170). The verdict"
  say "   below is read with that limitation, and 'contaminated' is a property of THIS setting."
else
  say "   window A's hottest tsens zone: ${W_A} C. Waiting up to ${SETTLE_BACK}s (every ${POLL}s) for it to come"
  say "   back to within ${MARGIN} C of that before window C reads anything."
  # `--poll 0` would spin the loop forever (`WAITED` would never advance), so a sample always costs at least
  # one second -- and the count that goes into the message is that same number, not the one asked for.
  ADV=$POLL
  [ "$ADV" -ge 1 ] 2>/dev/null || ADV=1
  while [ "$WAITED" -lt "$SETTLE_BACK" ]; do
    sleep "$ADV"
    WAITED=$((WAITED + ADV))
    sh "$THERMAL" --seconds "$ADV" --quiet > "$TMP/back" 2>&1
    W_NOW=$(hot_tsens "$TMP/back")
    # An unreadable sample is not a returned reading: skipping it (rather than treating "" as 0 or as a
    # return) keeps the loop going, and the bound still ends it.
    [ -n "$W_NOW" ] || continue
    if awk -v a="$W_A" -v n="$W_NOW" -v m="$MARGIN" 'BEGIN { exit ((n - a) <= m) ? 0 : 1 }'; then
      RETURNED=1
      break
    fi
  done
  if [ "$RETURNED" = 1 ]; then
    say "   IT CAME BACK: ${W_NOW} C after ${WAITED}s, against window A's ${W_A} C (margin ${MARGIN} C). Window C"
    say "   below is therefore a CONTROL and not a second reading of the same heat."
  else
    bad "   IT DID NOT COME BACK within ${SETTLE_BACK}s: the hottest tsens zone is ${W_NOW:-unreadable} C against"
    bad "   window A's ${W_A} C, i.e. more than ${MARGIN} C above it. Two things can look like this and this"
    bad "   instrument cannot tell them apart: the intervention's warming has not decayed (thermal mass), or"
    bad "   the phone warmed on its own by more than the margin while the run went on. BOTH are statements"
    bad "   about this RUN and about the phone. Neither is a price for the governor, so THIS RUN PRINTS NO"
    bad "   PRICE: there is no control window to compare against, and window C is not read at all."
    bad ""
    bad "   What it does establish is the phone's own thermal behaviour under this intervention, and that is"
    bad "   worth having: it is the number a longer wait would have to beat. If you want the price anyway,"
    bad "   --settle-back 0 runs the old design and --margin N loosens the bar; both are printed in the"
    bad "   verdict so nobody has to guess which one was used."
    NO_RETURN=1
  fi
fi

if [ "$NO_RETURN" = 1 ]; then
  hdr "no window C -- there is no control window in this run, so there is no verdict to print"
  S_END=$(gov_state)
  if [ "$S_END" = "$FIX_GOV" ]; then
    WROTE=0   # verified: nothing is left for the trap to undo, exactly as on the normal path
    say "   the cores are back on '$S_END'$(gov_list) -- the state this script found them in."
  else
    bad "   the cores read '$S_END', not '$FIX_GOV' -- leaving the trap armed to try again on exit."
  fi
  say "   The run stops here with a table of the TWO windows it did take, because the third is only a control"
  say "   while it reads the same STATE as the first one -- and the wait above just measured that it would not."
  awk -v A="$TMP/win.A" -v B="$TMP/win.B" '
    $1 ~ /^thermal_zone[0-9]+$/ && $4 == "C" {
      k = $1; type[k] = $2
      if (FILENAME == A) a[k] = $3 + 0; else b[k] = $3 + 0
      if (!(k in seen)) { seen[k] = 1; order[++n] = k }
      next
    }
    END {
      for (i = 1; i <= n; i++) {
        k = order[i]
        if (!((k in a) && (k in b))) { missing++; continue }
        printf "%s %s %.1f %.1f %.1f\n", k, type[k], a[k], b[k], b[k] - a[k]
      }
      if (missing) printf "# %d zone(s) were not readable in both windows and are not in this table\n", missing > "/dev/stderr"
    }' "$TMP/win.A" "$TMP/win.B" > "$TMP/deltas" 2>"$TMP/deltas.note"
  [ -s "$TMP/deltas.note" ] && { while IFS= read -r l; do say "   $l"; done < "$TMP/deltas.note"; }
  if [ -s "$TMP/deltas" ]; then
    say "   zone       type                        A      B     B-A"
    sort -k5,5gr "$TMP/deltas" | awk '{ printf "   %-10s %-22s %6.1f %6.1f %+6.1f\n", $1, $2, $3, $4, $5 }'
  else
    bad "   no zone was readable in both windows either, so not even the two-window table exists."
  fi
  hdr "the verdict"
  say "   -> NO RETURN: the reading did not come back to within ${MARGIN} C of window A within ${SETTLE_BACK}s,"
  say "      so window C would not have read window A's state -- it would have read the heat the intervention"
  say "      left behind. This run therefore PRINTS NO PRICE for the second heat cause, and that is the"
  say "      correct answer: the number the old design would have printed from A and B alone (the largest"
  say "      warming above) is not the governor's cost, it is the governor's cost PLUS whatever part of the"
  say "      phone's own warming had not decayed."
  say ""
  say "   What this run DOES establish is about the phone: the intervention's warming (or the phone's own"
  say "   drift) outlasted ${SETTLE_BACK}s at a ${MARGIN} C bar. That is the number a longer wait or a bigger"
  say "   margin would have to beat, and it is printed with the setting that produced it."
  say ""
  say "   The cores read '$(gov_state)'$(gov_list) -- the state it started in."
  exit 1
fi

hdr "window C -- the CONTROL: the fix's state again, so the third window is the same state as the first"
BUSY_C=$(run_window C)
say "   busy $BUSY_C of 4 cores"

# The undo is verified once more, and this is the line that decides whether the trap still owes anything.
S_END=$(gov_state)
if [ "$S_END" = "$FIX_GOV" ]; then
  WROTE=0
  say "   final state: all $CPU_N core(s) read '$S_END' -- the fix is where this script found it."
else
  bad "   final state: the cores read '$S_END', not '$FIX_GOV' -- leaving the trap armed to try again on exit."
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
  bad "   That is a statement about this run (and about the instrument), not about the governor. Exit 1."
  exit 1
fi

say "   zone       type                        A      B      C     B-A    C-A"
# THE WHOLE TABLE, not the top twelve. The version that printed twelve and said "... N more; the whole table
# is in the archive" named a directory with a random suffix that nothing printed -- so for the operator it
# was the same as printing nothing, and the first device run (docs 170) is how that was found. 38 rows is
# nothing on a terminal, and if the table is worth keeping it is worth printing.
sort -k6,6gr "$TMP/deltas" | awk '{
  printf "   %-10s %-22s %6.1f %6.1f %6.1f %+6.1f %+6.1f\n", $1, $2, $3, $4, $5, $6, $7 }'
say "   ($(wc -l < "$TMP/deltas" | tr -d ' ') zone(s) in this table, sorted by B-A; every one is printed.)"

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
say "   window A was the fix installed ('$FIX_GOV'); B was the cores PINNED ('$BLOCKED_GOV'); C was '$FIX_GOV'"
say "   again. Busy: A $BUSY_A, B $BUSY_B, C $BUSY_C of 4 cores (a READING, not a gate: a governor changes"
say "   the clock a core runs at, and this figure counts busy TIME, so the two are not expected to track)."
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
  say "   -> NO DETECTABLE COST: pinning all four cores did not warm the SoC by as much as this experiment"
  say "      can resolve. That is this script coming out AGAINST the fix it was built around: the governor"
  say "      fix's value would be in long-run power and in the clock itself, not in these zones at this load."
  RC=0
elif [ "$VERDICT" = contaminated ]; then
  say "   -> CONTAMINATED: B was warmer than A by ${BA} C, but C -- the SAME state as A -- is still ${CA} C"
  say "      above A. So the warming did not come back with the governor's state and was not caused by it: the"
  say "      phone drifted, or the load did. A statement about this RUN, not about the governor."
  RC=1
else
  say "   -> COST-MEASURED: pinning all four cores warmed the hottest tsens zone by ${BA} C (${ZONE_BA}), and"
  say "      putting the fix back did not leave that warming behind (C is ${CA} C above A). At this load, that"
  say "      is what the second heat cause is worth in temperature."
  RC=0
fi

say ""
say "   Read it as a READING and not as the governor fix's price in general: ambient is not controlled, the"
say "   battery's charging state is not controlled, and window C is a control only to the extent that the wait"
say "   above found the reading back (it waited ${SETTLE_BACK}s at a ${MARGIN} C bar, and what it measured is"
say "   printed above). The zones are the instrument's numbers, normalised by it; this script does not divide."
say "   This run used: --seconds ${SECONDS_WIN} --settle ${SETTLE} --settle-back ${SETTLE_BACK} --poll ${POLL}"
say "   --margin ${MARGIN}."
say ""
say "   The cores read '$(gov_state)'$(gov_list) -- the state it started in."
exit "$RC"
