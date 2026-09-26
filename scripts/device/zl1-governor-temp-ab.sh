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
# THE SECOND DEVICE RUN PRINTED A PRICE, AND IT WAS AN ARTIFACT (docs 172). It read A 49.6 -> B 47.0 -> C 41.9
# on the phone's hottest zone -- the phone FELL 7.7 C across the run -- and still printed COST-MEASURED 3.5 C,
# because THREE things about the wait above were wrong together:
#   (1) the comparison was ONE-SIDED (`sample - A <= MARGIN`), so a reading 4.2 C BELOW window A counted as
#       "came back", and the run went on to read a control window that was nowhere near window A's state;
#   (2) it compared the HOTTEST ZONE, and the hottest zone CHANGES HANDS while a run goes on -- window A's
#       hottest was thermal_zone12 at 49.6 C while the first sample's maximum came from a different zone at
#       45.4 C, so the test compared one zone's number against another's without saying so;
#   (3) there was no check that the phone was holding still BEFORE window A was read, so window A was a point
#       on a falling curve -- and a falling curve is what made (1) fire.
# THREE THINGS CHANGED, and they are one idea: this instrument now refuses to price a phone that is not
# holding still, before it starts and before its control window.
#   (a) `max_dev` replaces the hottest-zone comparison: the largest ABSOLUTE difference from window A on any
#       tsens zone, reported with its SIGN and with the zone's name, so the reader can see the direction.
#   (b) the pre-hold (`--settle-start`, default 300 s): two readings POLL apart must agree on EVERY tsens zone
#       to within MARGIN before window A is read at all. A phone that never holds still is its own verdict
#       (`no-plateau`, exit 1) and, because it is refused BEFORE window A, that run writes nothing.
#   (c) the post-wait uses `max_dev` too, so "the reading came back" means every zone is where it was.
#
# THE TWO HOLDS' UNITS WERE BOTH WRONG, AND IT IS THE SAME MISTAKE TWICE (docs 174, from the third device run
# of docs 173). The first device run with the version above came back NO RETURN, and reading its own timing
# found the two defects:
#   (1) A BOUND IN THE WRONG SECONDS. `--settle-back 240` took 798 s of wall clock, because the bound counted
#       the seconds the loop SLEPT while every sample cost this device about 23 s more (the instrument walks
#       /proc after its window is over: a 10 s sample costs about 33 s end to end). The run took 1009 s and
#       the --status text promised 12 minutes. Both holds are now bounded in now_s()'s seconds -- real
#       elapsed seconds, from /proc/uptime because the RTC reads 1970 -- and each hold PRINTS the wall clock
#       it spent, so the next run can be planned from a measurement instead of an estimate.
#   (2) A RATE COMPARED AGAINST A DISPLACEMENT. The pre-hold tested "two readings POLL apart agree within
#       MARGIN", which is a rate: 0.5 C per 10 s is 3 C per MINUTE, and a phone certified by that test had
#       moved 4.1 C by the time the run was done. What MARGIN is, and always was for the wait before C, is a
#       displacement -- how far from its own window A reading a zone may be before the difference cannot be
#       attributed. So the pre-hold now asks what the movement it just saw PROJECTS TO over the run's own
#       span, and refuses when that reaches MARGIN. Nothing else about the design changed, and that is the
#       finding (docs 173, section 6.1): on this phone the bar is unreachable, so the thing to change is the
#       design -- cancel the drift instead of requiring its absence.
#
# THE THREE-WINDOW DESIGN CANNOT PRICE THIS PHONE, SO THERE IS A SECOND ONE (docs 175, from docs 173/174).
# A/B/C requires the phone to HOLD STILL: window C is a control only if it reads window A's state, the pre-hold
# now enforces what that costs, and on this phone the bar it needs is 0.012 C per interval -- because the
# phone's own movement inside one run (4 C) is larger than the effect being priced (about 2 C). The third
# device run's own numbers say what to do about it: that movement is MONOTONE (a phone cooling towards ambient
# after a load), and a monotone drift that is present in BOTH halves of a PAIR cancels in their difference.
# So `--pairs N` runs N pairs of (fix window, pinned window), back to back, and reads the per-pair difference
# d_i = B_i - A_i -- with the ORDER INSIDE A PAIR ALTERNATING (pair 1 fix-then-pinned, pair 2 the other way
# round), because with every pair in the same order the pinned window is always one window LATER than its own
# fix window and one window of the phone's drift lands in EVERY difference with the same sign. Two things come
# with the pairing, and neither was available before:
#   * AN ERROR BAR, measured. The scatter of d_i across the pairs IS the noise, so the verdict is a mean with
#     its own standard error against the 0.2 C resolution -- not a threshold that has to be satisfied by a
#     phone at rest. Three verdicts come out of it: `cost-measured` when mean - 2 se clears the resolution,
#     `no-detectable-cost` when mean + 2 se is under it, and `inconclusive` when the interval spans it (which
#     is a statement about the RUN: it says how many more pairs the scatter would allow).
#   * A CONTROL THAT USES THE SAME SPANS. The FIX windows' own movement, in C per window, is the drift this
#     design cancels, measured over the very same minutes -- and the design's balance (where each half sat in
#     time) is computed from the order the run RECORDED taking, so the two numbers beside the reading are a
#     measurement rather than a claim.
# WHAT IT DOES NOT GIVE: the lag. The zones follow the power through the SoC's thermal time constant, which is
# still unmeasured (docs 173, section 8), so if that constant is comparable to the window length the reported
# effect is SMALLER than the true one. The pairing cancels drift, not lag, and the verdict says so.
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
#     zl1-governor-temp-ab.sh --settle-start N --settle-back N --poll N --margin C
#                                                 the TWO holds: one before window A, one before window C.
#                                                 Both bounds are WALL CLOCK (docs 174), and --margin C is a
#                                                 DISPLACEMENT over the whole run, so the pre-hold's bar for
#                                                 one interval of --poll is --margin x poll / run span.
#                                                 AT THE DEFAULTS: pre-hold up to 300 s + 45 + 20 + 45 + 20 +
#                                                 wait up to 240 + 45 s is about 13 minutes, and every second
#                                                 of it is waiting or reading -- the device is written twice.
#                                                 The run PRINTS the wall clock it actually took, because the
#                                                 instrument's own samples are inside these bounds (a 10 s
#                                                 window costs this device about 23 s: docs 173, section 5).
#     zl1-governor-temp-ab.sh --pairs N           THE ALTERNATING DESIGN (docs 175): N pairs of
#                                                 (fix window, pinned window), back to back, with the
#                                                 ORDER INSIDE A PAIR ALTERNATING (pair 1 fix-then-pinned,
#                                                 pair 2 pinned-then-fix, ...) so that the two halves sit at
#                                                 the same mean position in time. The verdict is the MEAN of
#                                                 the per-pair differences with the PAIR-TO-PAIR SCATTER as
#                                                 its own error bar. It does NOT need the phone to hold still
#                                                 -- a drift present in both halves of a pair cancels in the
#                                                 difference -- so it has no pre-hold and no wait, and
#                                                 --settle-start, --settle-back, --poll and --margin do not
#                                                 apply to it. Its own defaults are 30 s windows and a 5 s
#                                                 settle; six pairs is about ten minutes of wall clock, which
#                                                 the run prints. It needs 3..30 pairs (three for a scatter,
#                                                 and a bound so the run can be planned).
#     zl1-governor-temp-ab.sh --keep              leave the run's own files and print where they are
#     zl1-governor-temp-ab.sh --revert            put every core back on `interactive` and prove it
#     zl1-governor-temp-ab.sh --explain           what each reading decides, and change nothing
#
# Exit codes: 0 a verdict that is a measurement about the phone (cost-measured OR no-detectable-cost --
#             the second one is this script coming out against the fix it was built around);
#             1 NO-PLATEAU, NO-RETURN, INCONCLUSIVE or CONTAMINATED -- a statement about the RUN and not about
#             the phone;
#             2 not the zl1;
#             3 REFUSED -- a refusal is not met and nothing was written;
#             4 the write happened and something went wrong after it (the state and the restore are
#             printed, and the trap has already tried to undo it).
#             `no-plateau` is the only one of these that happens with NOTHING written: it is refused before
#             window A, i.e. before the experiment's first write.

set -u

MODE=status
SECONDS_WIN=45
SETTLE=20
SEC_GIVEN=0
SET_GIVEN=0
THERMAL=/tmp/zl1-thermal.sh
YES=0
WROTE=0
KEEP=0
NO_RETURN=0
# THE ALTERNATING DESIGN (docs 175), and it exists because the three windows above have now been measured to
# be unable to price this phone (docs 173/174): A/B/C needs the phone to HOLD STILL, this phone moves 4 C
# inside one run, and the effect being priced is about 2 C. The third run's own numbers say why that is fatal
# to A/B/C and not to a paired design: the drift is MONOTONE (the phone cools towards ambient after a load),
# and a monotone drift that is present in both halves of a PAIR cancels in the difference of the pair.
# So `--pairs N` runs N pairs of (fix window, pinned window) back to back with the ORDER ALTERNATING inside a
# pair -- A1 B1 B2 A2 A3 B3 ... -- and the reading is the per-pair difference d_i = B_i - A_i. Alternating the
# order is not decoration: with every pair in the same order the pinned window is always one window LATER than
# its own fix window, so one window of the phone's drift lands inside every difference with the same sign, and
# the mean is biased by exactly that much. Alternating puts the two halves at the same mean position in time,
# and the residual imbalance is printed as a number. What A/B/C could not give and this does is an ERROR BAR:
# the scatter of d_i across the pairs is a DIRECT estimate of the noise, so the verdict is a mean with its own
# standard error against the 0.2 C resolution, instead of a threshold that has to be satisfied by a phone at
# rest. PAIRS=0 keeps the three-window design, which is still the control and the reason this design exists.
PAIRS=0
# The paired design's own defaults, used only when --pairs is given and --seconds/--settle are not: it needs
# MORE windows (2N of them), so each has to be shorter, and the run is sized in the --status text.
PAIR_SECONDS=30
PAIR_SETTLE=5
# THE WAIT. The first device run of this instrument (2026-09-25, docs 170) came back CONTAMINATED for a
# reason the design had not named: 45 s after the undo the SoC was still ~7 C above window A, so the control
# window started on a phone that had not shed the intervention's heat -- and a control window can only catch
# a drift that VANISHES by the time it is read. Waiting for the reading to COME BACK, with a bound, is not a
# nicety: it is what makes the third window a control instead of a second reading of the thermal mass. The
# wait is itself a measurement and the run prints how long it took. `--settle-back 0` turns it off, which
# restores the old (weaker) behaviour on purpose -- with the wait off, `contaminated` is the likely verdict
# and the operator should know that is a property of the design and not of the governor.
SETTLE_BACK=240
# THE PRE-HOLD. The second device run (docs 172) started on a phone that was falling 4.2 C per ten seconds,
# which is what turned the one-sided comparison above from a subtlety into a wrong price. Waiting for two
# readings to AGREE before window A is read is what makes window A a state rather than a point on a curve --
# and it is refused before the intervention, so a phone that never holds still costs no write at all.
SETTLE_START=300
POLL=10
MARGIN=0.5
# THE BAR IS NOT THE SAMPLE INTERVAL (docs 174). "How far from its window A reading a zone may be before this
# run cannot attribute the difference to the governor" is what the wait before window C has always tested, and
# it is a DISPLACEMENT -- it is spent over the run. The pre-hold tested `two readings POLL apart within
# MARGIN` instead, and that is a RATE bar: 0.5 C per 10 s is 3 C per minute, or 30 C over a ten-minute run,
# against a resolution of 0.2 C. It certified a phone that had moved 2.4 C per minute as "holding still", and
# that phone then moved 4.1 C (docs 173, section 6). So the bar for one interval of G is MARGIN x G / RUN_SPAN
# -- and RUN_SPAN is defined BELOW the argument loop, because a span computed before --seconds and
# --settle-back are read would be the defaults' span and not this run's.
# bar_of GAP MARGIN SPAN -- the displacement one interval of GAP may use out of a bar of MARGIN over SPAN.
# %.4f and not %.1f because the point of this number is that it is SMALLER than the instrument's own 0.1 C
# step: rounding it to one decimal would print 0.0 and hide exactly the thing it exists to show.
bar_of() {
  awk -v g="$1" -v m="$2" -v s="$3" 'BEGIN { if (s + 0 <= 0) { print m; exit } printf "%.4f", m * g / s }'
}
# proj_of DEV GAP SPAN -- what a movement of DEV in GAP projects to over SPAN. The absolute difference is
# taken here too, so a phone that is falling fast projects as a big number in the same way one that is
# climbing does: the sign is printed beside it, the size is what the bar is spent on.
proj_of() {
  d=$(dev_abs "$1")
  awk -v d="$d" -v g="$2" -v s="$3" 'BEGIN { if (g + 0 <= 0) { print d; exit } printf "%.1f", d * s / g }'
}

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
  --seconds) SECONDS_WIN="${2?--seconds needs a number}"; SEC_GIVEN=1; shift 2 ;;
  --settle)  SETTLE="${2?--settle needs a number}"; SET_GIVEN=1; shift 2 ;;
  --pairs)   PAIRS="${2?--pairs needs a number}"; shift 2 ;;
  --settle-start) SETTLE_START="${2?--settle-start needs a number}"; shift 2 ;;
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

# THE TWO DESIGNS' SETTINGS, resolved HERE because every number they are made of arrives as an argument: the
# version that computed the span beside the defaults above reported 415 s for a run whose settings were
# 1/0/0/1, and the pre-hold's bar is derived from it (docs 174). "Was it given" is the only way to know which
# design's defaults the operator wants, and a non-numeric --pairs is validated FIRST and before any arithmetic
# on it -- otherwise the shell aborts inside the expansion below instead of reaching a message.
case "$PAIRS" in
''|*[!0-9]*) echo "--pairs needs a whole number (got '$PAIRS')" >&2; exit 2 ;;
esac
if [ "$PAIRS" -gt 0 ] && { [ "$PAIRS" -lt 3 ] || [ "$PAIRS" -gt 30 ]; }; then
  echo "--pairs $PAIRS: the alternating design needs 3..30 pairs -- at least three so that the scatter of the differences estimates a noise, and no more than thirty so that the run can be planned from its wall clock." >&2
  exit 2
fi
if [ "$PAIRS" -gt 0 ] 2>/dev/null; then
  [ "$SEC_GIVEN" = 1 ] || SECONDS_WIN="$PAIR_SECONDS"
  [ "$SET_GIVEN" = 1 ] || SETTLE="$PAIR_SETTLE"
fi
# The paired design's own arithmetic, printed by `--status` and quoted in the verdict's caveat: 2N windows,
# each one costing its own length plus this instrument's walk of /proc (measured at about 13 s on a 10 s
# sample: docs 173, section 5), plus a settle after every one of the 2N writes.
PAIR_SPAN=$((PAIRS * 2 * (SECONDS_WIN + SETTLE + 13)))
# The three-window design's span: from the start of window A to the end of window C. It is left at 0 in the
# paired mode rather than computed from settings that will never be used, and the header prints it only then.
RUN_SPAN=0
[ "$PAIRS" -gt 0 ] || RUN_SPAN=$((SECONDS_WIN * 3 + SETTLE * 2 + SETTLE_BACK))

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

# THE CLOCK, and it is /proc/uptime rather than the RTC. This device's clock reads 1970-02-13 (docs 173,
# section 8), so every date this script prints is wrong -- while uptime advances at the right rate and never
# STEPS. That last property is the one that matters here: both holds below are bounded in the seconds this
# returns, and a clock that jumps (an NTP step on a phone whose time is 56 years out) would end a hold early
# or late for a reason that has nothing to do with the phone's temperature. `date +%s` is the fallback rather
# than the first choice, and it is a fallback that prints a wrong date, which is why it is only reached when
# /proc/uptime cannot be read at all.
now_s() {
  zl1_u=$(awk 'NR == 1 { printf "%d", $1 }' /proc/uptime 2>/dev/null)
  case "$zl1_u" in ''|*[!0-9]*) zl1_u=$(date +%s 2>/dev/null) ;; esac
  printf '%s' "${zl1_u:-0}"
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
  2. THE PRE-HOLD, and it decides whether there is anything here to measure at all. Two readings must agree
     on EVERY tsens zone, and the bar is not a rate: MARGIN C is a DISPLACEMENT over the WHOLE RUN, so one
     interval of G is allowed MARGIN x G / RUN_SPAN -- and on a phone that moves measurably at all, that
     number is smaller than the instrument's own 0.1 C step, which is the point. The hold waits up to
     SETTLE_START seconds of WALL CLOCK for it. A window read on a moving phone is not a state, it is a point
     on a curve -- the same drift then sits inside every delta below it, and it cannot be told from the
     governor. The second device run (docs 172) read window A on a phone falling 4.2 C per ten seconds; the
     third (docs 173) certified one moving 2.4 C per minute as "holding still" with a bar that was a rate,
     and that phone moved another 4.1 C before the run was over. A phone that never holds still enough is the
     verdict `no-plateau`, and because this happens BEFORE window A it is the one exit from this script that
     writes nothing at all. It also PRINTS what it saw and what that projects to, because that projection is
     the number that says the three-window design cannot price this phone (docs 173, section 6.1).
  3. WINDOW A, as installed: the zones with all four cores on 'interactive'. Nothing has been written yet.
  4. THE INTERVENTION AND THE PROOF: write 'performance' to every core, read every core back, and REQUIRE
     all of them to read it. A write that landed on three of four would make the next window a measurement
     of a quarter of the change -- and would read as a smaller cost, i.e. as a real number.
  5. WINDOW B: the zones with the cores pinned, i.e. the image's own state, the second heat cause put back.
  6. THE UNDO, ALSO PROVED: write 'interactive' to every core and require every core to read it.
  7. THE WAIT, and this is what makes the next step a CONTROL. Window C reads the same GOVERNOR as A, which
     is not the same thing as reading the same STATE: pinning the cores warms the SoC, and thermal mass does
     not care that the governor was put back 20 s ago. The first device run of this instrument (docs 170)
     read A 40.9 -> B 47.7 -> C 48.0 and came back CONTAMINATED for exactly that reason. So after the undo
     the run waits for EVERY tsens zone to come back to within MARGIN of its OWN window A reading, up to
     SETTLE_BACK seconds OF WALL CLOCK (docs 174: the bound used to count the seconds the loop slept, so 240
     of them cost 798 s), polling every POLL, and PRINTS HOW LONG IT TOOK. That number is the phone's thermal
     behaviour under this intervention, and it is worth having on its own.
     EVERY ZONE, and the difference is ABSOLUTE. The second device run (docs 172) tested the HOTTEST zone
     and tested it ONE-SIDED, so a reading 4.2 C BELOW window A read as "came back" -- and the hottest zone
     is a maximum over 23 numbers that move by different amounts, so following it compares one zone's number
     with another zone's and calls the difference a return. Both halves are the same defect: the test was of
     something other than "this zone is where it was".
  8. WINDOW C, the CONTROL: the fix's state again, read only once every zone is back. If the warming seen in
     window B is still there in window C -- after the wait said it had gone -- the governor did not cause it
     and the verdict says contaminated rather than reporting a number as the effect.
  9. THE VERDICT:
       cost-measured        B was warmer than A by more than this experiment's resolution, AND C came back
                            down (the third window did not keep the warming)
       no-detectable-cost   B was not warmer than A: pinning the cores is worth less than the resolution
                            here -- which is this script coming out against the fix it was built around
       contaminated         the warming persisted into C -- a statement about the RUN
       no-return            some zone did not come back within SETTLE_BACK of its own window A reading, so
                            there IS no control window and the run prints NO PRICE. Two things look like
                            this -- the intervention's warming has not decayed, or the phone moved by more
                            than MARGIN on its own, in either direction -- and the instrument cannot tell
                            them apart. Both are statements about the phone.
       no-plateau           the phone never held still ENOUGH for SETTLE_START seconds (wall clock) before
                            window A: two readings did not agree closely enough that what it just saw
                            projects to less than MARGIN over the run's own span. Nothing was written.
                            (--settle-start 0 disables this hold; --margin N raises the displacement.)
     An intervention that did not land, or an undo that did not hold, is NOT a verdict at all: it exits 4
     with the state printed, because every number below it would be a comparison of two identical states.
     The resolution is 0.2 C, which is two steps of the instrument's own 0.1 C and is printed with the
     verdict, because a threshold nobody can see is a threshold nobody can argue with.
     BOTH HOLDS ARE BOUNDED IN WALL CLOCK and the run prints what it spent, because on this device the
     instrument's own samples are inside those bounds and not beside them: a 10 s sample costs about 33 s
     end to end. The version that counted sleeps promised 12 minutes and took 17 (docs 173, section 5).
     --settle-back 0 turns the WAIT off and restores the old design: window C then starts on a phone that
     may still be holding the intervention's heat, and 'contaminated' becomes a property of that setting.
     --settle-start 0 turns the PRE-HOLD off and restores the older design still: window A is then a point
     on whatever curve the phone is on, which is the setting that printed docs 172's artifact.
 10. THE ALTERNATING DESIGN (`--pairs N`, docs 175), and it exists because steps 1-9 were MEASURED to be
     unable to price this phone. Three device runs produced a CONTAMINATED, an artifact and a refusal, and
     the third run's own timing says why: the phone moves about 4 C inside one run (it is cooling towards
     ambient after a load) while the effect being priced is about 2 C, and A/B/C needs window A and window C
     to be THE SAME STATE for the control to mean anything. No threshold fixes that -- docs 174's bar makes
     it exact: a phone that moves at all cannot pass the pre-hold, so the design has to stop requiring the
     phone to hold still.
     WHAT CANCELS INSTEAD: the phone's own movement is MONOTONE, and a monotone movement present in both
     halves of a pair cancels in their difference. So the run takes N pairs, each one window on the fix and
     one on the pinned value, each window SECONDS_WIN long with SETTLE after every proved write, and reads
     d_i = B_i - A_i per zone. THE ORDER INSIDE A PAIR ALTERNATES -- pair 1 is fix-then-pinned, pair 2 is
     pinned-then-fix -- and that is load-bearing: with a fixed order the pinned window is always one window
     later than its own fix window, so one window of the phone's drift sits inside EVERY difference with the
     same sign and the mean is biased by it. Alternating the order puts the two halves at the same mean
     position in time, and the residual imbalance is printed as a number of windows and in C.
       the verdict      the MEAN of d_i, with the SCATTER of d_i across the pairs as its standard error (se
                        = sd/sqrt(N)). Three outcomes: `cost-measured` when mean - 2 se clears the 0.2 C
                        resolution, `no-detectable-cost` when mean + 2 se is under it, `inconclusive` when the
                        interval spans it. The last one is a statement about the RUN, and it says how many
                        more pairs the scatter would need.
       the control      the FIX windows' own movement, in C PER WINDOW: the drift this design cancels,
                        measured over the very same minutes rather than assumed away. Beside it, the
                        design's BALANCE -- where each half sat in time -- which is what makes the cancelling
                        an arithmetic property rather than a hope.
       the primary zone the hottest tsens zone in the FIRST window, declared before any intervention. The
                        full per-zone table is printed with every mean and se, and the largest of those means
                        is marked as chosen AFTER the fact -- the largest of 23 means sits about 2 se above
                        zero even when nothing is happening, which is exactly the shape that printed docs 172's
                        3.5 C.
       what it cannot do the LAG. The zones follow the power through the SoC's thermal time constant, which
                        is still unmeasured (docs 173, section 8). A window comparable to that constant
                        reports a SMALLER effect than the truth; the pairing cancels drift, not lag.
     Only the paired design is affected by `--pairs`: without it this script is the three-window design and
     nothing about the words above changes.
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
say "  design:      $(if [ "$PAIRS" -gt 0 ]; then echo "the ALTERNATING design (docs 175): $PAIRS pair(s) of (fix window, pinned window) with the order alternating inside each pair, and the scatter of the per-pair differences is the error bar"; else echo "the THREE-WINDOW design (docs 169): A (fix) -> B (pinned) -> C (fix again, the control)"; fi)"
say "  windows:     ${SECONDS_WIN}s each, ${SETTLE}s after each write"
if [ "$PAIRS" -gt 0 ]; then
  say "  the run:     2 x ${PAIRS} = $((PAIRS * 2)) window(s) and the same number of proved writes; estimated wall clock ${PAIR_SPAN}s (each window costs its ${SECONDS_WIN}s plus this instrument's walk of /proc, about 13s)"
  say "  not used:    --settle-start, --settle-back, --poll and --margin belong to the three-window design. This one does NOT need the phone to hold still -- that is the whole point -- so it has no pre-hold and no wait."
else
  say "  holds:       $(if [ "$SETTLE_START" = 0 ]; then echo "pre-hold OFF"; else echo "up to ${SETTLE_START}s of wall clock before A"; fi), up to ${SETTLE_BACK}s of wall clock before C, at a ${MARGIN} C displacement bar; run span ${RUN_SPAN}s (one ${POLL}s interval may use $(bar_of "$POLL" "$MARGIN" "$RUN_SPAN") C)"
fi
say "  states:      $(if [ "$PAIRS" -gt 0 ]; then echo "the two halves of every pair: fix '$FIX_GOV' (installed) versus pinned '$BLOCKED_GOV' (the image's own value)"; else echo "A/C '$FIX_GOV' (the fix, installed)  B '$BLOCKED_GOV' (the image's own value)"; fi)"
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
  if [ "$PAIRS" -gt 0 ]; then
    say "   ALTERNATING (--pairs ${PAIRS}): $((PAIRS * 2)) window(s) in $PAIRS pair(s), each pair one window on the"
    say "   fix ('${FIX_GOV}') and one on the image's own setting ('${BLOCKED_GOV}'), ${SECONDS_WIN}s each and ${SETTLE}s after every"
    say "   one of the $((PAIRS * 2)) proved writes. The ORDER INSIDE A PAIR ALTERNATES -- pair 1 is fix-then-pinned,"
    say "   pair 2 pinned-then-fix, and so on -- which is what puts the two halves at the same mean position in"
    say "   time; with a fixed order every difference would carry one window of the phone's own drift."
    say "   The reading is the MEAN of the per-pair difference '${BLOCKED_GOV}' minus '${FIX_GOV}', and its error bar is"
    say "   their SCATTER: a phone that drifts is priced instead of refused, because the drift cancels in the"
    say "   mean and the residual is printed beside it (the fix windows' own C-per-window movement, and the"
    say "   design's balance). So is a phone on which the scatter is too big to resolve anything: the verdict"
    say "   can be 'inconclusive', which the three-window design had no way to say."
    say "   Estimated wall clock ${PAIR_SPAN}s (about $((PAIR_SPAN / 60)) minutes): each window costs its ${SECONDS_WIN}s plus this"
    say "   instrument's walk of /proc, measured at about 13s on a 10s sample (docs 173, section 5). The run"
    say "   prints what it took."
    say "   NO pre-hold and NO wait: they exist to make window A a STATE, which a paired difference does not need"
    say "   (--settle-start, --settle-back, --poll and --margin do not apply to this design). What it cannot fix"
    say "   is LAG: the zones follow the power through the SoC's thermal time constant, still unmeasured, so a"
    say "   window comparable to that constant reports a SMALLER effect than the truth."
    say "   the trap restores '$FIX_GOV' on every exit path, and removes $TMP unless --keep"
    exit 0
  fi
  if [ "$SETTLE_START" = 0 ]; then
    say "   pre-hold: OFF (--settle-start 0) -- window A is read immediately, whatever the phone is doing"
  else
    say "   pre-hold: up to ${SETTLE_START}s of WALL CLOCK for two readings to agree on every tsens zone that"
    say "   what the second one just saw projects to less than ${MARGIN} C over this run's ${RUN_SPAN}s -- i.e. at"
    say "   most $(bar_of "$POLL" "$MARGIN" "$RUN_SPAN") C in one ${POLL}s interval. Refused BEFORE window A if they never"
    say "   do, so that exit writes"
  fi
  say "   window A: the zones as installed ('$FIX_GOV' on all $CPU_N cores), ${SECONDS_WIN}s"
  say "   write '$BLOCKED_GOV' to every core, prove all of them read it, wait ${SETTLE}s, window B, ${SECONDS_WIN}s"
  say "   write '$FIX_GOV' back, prove all of them read it, then WAIT (up to ${SETTLE_BACK}s of wall clock) for"
  if [ "$SETTLE_BACK" = 0 ]; then
    say "   every tsens zone to return to within ${MARGIN} C of its OWN window A reading -- WAIT DISABLED"
    say "   (--settle-back 0), so window C starts on a phone that may still be holding the intervention's heat."
  else
    say "   every tsens zone to return to within ${MARGIN} C of its own window A reading, and say how long"
    say "   that took"
  fi
  say "   window C, ${SECONDS_WIN}s (the control); then the per-zone deltas B-A and C-A and a verdict"
  say "   BOUNDS ARE WALL CLOCK and the run prints what it spent. Every sample costs its own window PLUS this"
  say "   instrument's walk of /proc, which a 10 s sample measured at about 13 s more (docs 173, section 5),"
  say "   so a ${SECONDS_WIN}s window costs about $((SECONDS_WIN + 13))s end to end -- the old bound counted sleeps and"
  say "   --settle-back 240 cost 798 s."
  say "   the trap restores '$FIX_GOV' on every exit path, and removes $TMP unless --keep"
  exit 0
fi

# --- the windows ---------------------------------------------------------------------------------------
# One window is one run of the instrument. `--quiet` drops the per-process table: this experiment compares
# THERMAL ZONES and nothing in the process table changes its answer, while the table costs output and the
# busy figure it needs is in the summary line either way.
run_window() { # $1 = label -- prints "<busy> <wall clock seconds>"
  zl1_w0=$(now_s)
  sh "$THERMAL" --seconds "$SECONDS_WIN" --quiet > "$TMP/win.$1" 2>&1
  rc=$?
  zl1_wall=$(( $(now_s) - zl1_w0 ))
  if [ "$rc" != 0 ]; then
    # The path is named, and the evidence is KEPT, because the interesting case is the one where something
    # went wrong -- and an error whose evidence is deleted on the way out is an error nobody can look at.
    KEEP=1
    bad "   NOTE: the instrument exited $rc in window $1; its output is $TMP/win.$1 (kept: --keep is forced on"
    bad "   when a window fails, because that file is the only copy)"
  fi
  b=$(awk '/^[ ]+busy / { print $2; exit }' "$TMP/win.$1" 2>/dev/null)
  printf '%s %s\n' "${b:-unreadable}" "$zl1_wall"
}
# ONE WINDOW, BOOKED. `run_window` is always called inside `$( )`, which is a SUBSHELL: an accumulator set in
# there is lost, and the first version of this bookkeeping printed "0s in 0 window(s)" for exactly that reason
# (the one place those numbers were visible was the line that was wrong). So the wall clock comes back as
# OUTPUT and is booked here, at the top level.
win() { # $1 = label; leaves the busy figure in WIN_BUSY and the wall clock added to WIN_WALL
  zl1_two=$(run_window "$1")
  WIN_BUSY=${zl1_two%% *}
  WIN_WALL=$((WIN_WALL + ${zl1_two##* }))
  WIN_N=$((WIN_N + 1))
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
# The NAME of the hottest tsens zone in one instrument output -- the same zone `hot_tsens` returns the
# temperature of, for the one caller that needs to keep pointing at it (the alternating design's
# pre-registered zone, docs 175). Empty output means NOT READABLE, as everywhere else here.
hot_zone() {
  awk '$1 ~ /^thermal_zone[0-9]+$/ && $2 ~ /^tsens_tz_sensor/ && $4 == "C" {
         if (!seen || $3 + 0 > m) { m = $3 + 0; z = $1; seen = 1 } }
       END { if (seen) printf "%s", z }' "$1" 2>/dev/null
}
# max_dev FILE_A FILE_B -- how far apart two instrument outputs are, ZONE BY ZONE.
#
# This is the comparison both holds are decided on, and it is not the same comparison this script used to
# make. Until docs 172 the test was `the hottest tsens zone in this sample - the hottest tsens zone in
# window A`, and that has two defects that were measured on the device together:
#   * it is ONE-SIDED. A phone that came back 4.2 C COLDER than window A read as "came back", because
#     "colder" passed `sample - A <= MARGIN` -- and the run then read a control window that was nowhere
#     near the state of window A, and printed a price. The difference here is ABSOLUTE, so back means back.
#   * "the hottest zone" CHANGES HANDS while a run goes on (it is the maximum of 23 numbers that move by
#     different amounts), so the test compared the number of ONE zone against the number of ANOTHER and
#     called that difference a return. Here every zone is compared with ITSELF, by name.
# Output: "<absolute>|<signed>|<zone> (<type>)", or nothing when the two outputs share no tsens zone -- the
# caller treats "nothing" as NOT A READING rather than as zero, which is what this repository does with
# every empty answer. The sign is carried because it is the whole of docs 172: "5.0 C below" and "5.0 C
# above" are different findings about the phone, and a message that prints only "5.0 C" hides which one it saw.
max_dev() {
  awk -v A="$1" -v B="$2" '
    $1 ~ /^thermal_zone[0-9]+$/ && $2 ~ /^tsens_tz_sensor/ && $4 == "C" {
      k = $1; type[k] = $2
      if (FILENAME == A) { a[k] = $3 + 0; next }
      if (!(k in a)) next
      d = ($3 + 0) - a[k]
      sd = d
      if (d < 0) d = -d
      if (!seen || d > m) { m = d; mz = k; mt = type[k]; ms = sd; seen = 1 }
    }
    END { if (seen) printf "%.1f|%.1f|%s (%s)", m, ms, mz, mt }' "$1" "$2" 2>/dev/null
}
# One field out of a max_dev answer, by name, so the call sites do not each invent their own parsing.
dev_abs()   { printf '%s' "${1%%|*}"; }
dev_signed(){ zl1_r=${1#*|}; printf '%s' "${zl1_r%%|*}"; }
dev_where() { printf '%s' "${1#*|*|}"; }

# WHAT THE INSTRUMENT ITSELF COSTS, per sample, on THIS run -- and it is a difference between two numbers the
# run counted rather than a constant: `HOLD_WALL - HOLD_SLEEP` is everything the holds spent that was not the
# sleep they asked for, which on this device is the instrument walking /proc after every window. Printed as a
# whole number of seconds, and printed as "no sample was taken" when the holds took none, because 0/0 is not 0.
per_sample() {
  if [ "$HOLD_SAMPLES" -lt 1 ]; then printf 'no sample was taken'
  else printf '%ss per sample' "$(( (HOLD_WALL - HOLD_SLEEP) / HOLD_SAMPLES ))"; fi
}
# THE RUN'S OWN WALL CLOCK, on every exit path that got as far as measuring (docs 173, section 5). It exists
# because both bounds are in now_s() seconds and the instrument's samples are INSIDE them: an operator reading
# "--settle-back 240" has to be able to tell 240 s of run from 240 sleeps, and the only honest version of that
# number is the one this run measured. It is called by the refusals too, so a run that stops early still says
# what stopping early cost.
cost_line() {
  # The per-window figure is computed with a guard rather than a ternary inside the expansion: a run that
  # took no window at all would divide by zero, and a script that dies on its way out of a refusal loses the
  # refusal. 0/0 is not 0, so the guard says which case it is.
  zl1_per=0
  [ "$WIN_N" -gt 0 ] && zl1_per=$((WIN_WALL / WIN_N))
  say "   WALL CLOCK: this attempt took $(( $(now_s) - RUN_T0 ))s: ${WIN_WALL}s in ${WIN_N} window(s), ${HOLD_WALL}s in"
  if [ "$PAIRS" -gt 0 ]; then
    say "   the holds -- and this design has NONE (--pairs): the ${WIN_N} window(s) above are the whole run, ${zl1_per}s each"
    say "   against the ${SECONDS_WIN}s asked for. Every bound above is in THESE seconds."
  else
    say "   the holds. The holds asked for ${HOLD_SLEEP}s of sleep and spent the rest waiting on the instrument"
    say "   itself, $(per_sample). Every bound above is in THESE seconds, not in sleeps."
  fi
}

# --- the pre-hold: a phone that is not holding still cannot be priced ----------------------------------
# THE SECOND HALF OF THE SAME IDEA as the wait before C, and it exists for the same measured reason (docs 172).
# The second device run read window A on a phone that was falling 4.2 C per ten seconds -- so A, B and C were
# three points on a curve rather than three states, the drift was as large as the effect being priced, and the
# run printed a number anyway. A control window cannot fix that: the drift is there in EVERY window, including
# the first. So window A is read only once two readings agree on EVERY tsens zone closely ENOUGH, with a bound.
# This hold is refused BEFORE window A, which makes `no-plateau` the one verdict in this script that happens
# with the device untouched: nothing has been written at that point but the same-value proof, which writes back
# the value the cores already held.
#
# "CLOSELY ENOUGH" IS A DISPLACEMENT OVER THE RUN AND NOT A RATE OVER THE SAMPLE (docs 174). The third device
# run passed this hold -- the phone was certified as "holding still" at 0.4 C per ten seconds -- and then moved
# 4.1 C before the run was over, because 0.5 C per 10 s is 3 C per MINUTE: a bar that permits 30 C over a
# ten-minute run cannot certify anything about a 0.2 C resolution. So the bar is bar_of(POLL, MARGIN,
# RUN_SPAN), and what the hold decides on is proj_of: what the movement it just saw projects to over the whole
# span. It is deliberately hard to pass, and on this phone it is expected to refuse (docs 173, section 6.1).
PLATEAU=1
PRE_WAITED=0
PRE_DEV=
PRE_GAP=0
PRE_BAR=0
# WHAT THE RUN SPENDS, AND IT IS COUNTED RATHER THAN ESTIMATED (docs 173, section 5). `HOLD_SLEEP` and
# `HOLD_SAMPLES` separate the two things a sample costs -- the sleep the loop asks for, and the instrument
# itself -- and that difference is what `cost_line` prints at the end. `RUN_T0` is the start of the measured
# part of the run (the refusals above are not part of it).
RUN_T0=$(now_s)
WIN_WALL=0
WIN_N=0
HOLD_WALL=0
HOLD_SLEEP=0
HOLD_SAMPLES=0
# THE PRE-HOLD BELONGS TO THE THREE-WINDOW DESIGN AND IS SKIPPED IN PAIRED MODE (docs 175). It exists to make
# window A a STATE, and a paired difference does not need one: the comparison is between the two windows of a
# pair, and the drift it removes is the drift the pairing is FOR. Running it here would spend the phone's
# whole pre-hold budget establishing that this phone does not hold still -- a fact the paired design has
# stopped depending on. It is a first branch and not a guard around the section so that the two designs'
# settings cannot both be half-applied.
if [ "$PAIRS" -gt 0 ]; then
  : # the paired design below: no pre-hold, and window A.1 is read before any intervention
elif [ "$SETTLE_START" = 0 ]; then
  hdr "the pre-hold -- OFF (--settle-start 0)"
  say "   Window A is read immediately, whatever this phone is doing. That is the design that printed a price"
  say "   on a phone falling 4.2 C in ten seconds (docs 172), so 'no-plateau' cannot happen here -- which"
  say "   makes THIS setting the thing that decides whether the run below prices a state or a curve."
else
  hdr "the pre-hold -- is this phone holding still ENOUGH, before a window is read at all?"
  say "   ${MARGIN} C is a DISPLACEMENT and not a rate: it is how far from its window A reading a zone may be"
  say "   before this run can no longer attribute the difference to the governor (that is what the wait before"
  say "   window C has always tested). So over this run's ${RUN_SPAN}s one interval of ${POLL}s may use"
  say "   $(bar_of "$POLL" "$MARGIN" "$RUN_SPAN") C of it, and what this hold decides on is what the movement it just saw PROJECTS"
  say "   TO over the whole span. Two readings, on EVERY tsens zone, up to ${SETTLE_START}s of WALL CLOCK. A phone"
  say "   that never holds still enough cannot be priced, and this is refused before the intervention: this is"
  say "   the one exit from this script that writes nothing at all."
  ADV=$POLL
  [ "$ADV" -ge 1 ] 2>/dev/null || ADV=1
  PRE_PH=1
  PRE_PREV=""
  PLATEAU=0
  PRE_T0=$RUN_T0
  PRE_LAST_T=$PRE_T0
  while [ "$(( $(now_s) - PRE_T0 ))" -lt "$SETTLE_START" ]; do
    sleep "$ADV"
    HOLD_SLEEP=$((HOLD_SLEEP + ADV))
    sh "$THERMAL" --seconds "$ADV" --quiet > "$TMP/pre.$PRE_PH" 2>&1
    HOLD_SAMPLES=$((HOLD_SAMPLES + 1))
    PRE_NOW_T=$(now_s)
    PRE_GAP=$((PRE_NOW_T - PRE_LAST_T))
    PRE_LAST_T=$PRE_NOW_T
    PRE_WAITED=$((PRE_NOW_T - PRE_T0))
    if [ -n "$PRE_PREV" ]; then
      PRE_DEV=$(max_dev "$PRE_PREV" "$TMP/pre.$PRE_PH")
      PRE_BAR=$(bar_of "$PRE_GAP" "$MARGIN" "$RUN_SPAN")
      # An unreadable sample is not agreement: skipping it (rather than treating "" as 0) keeps the loop
      # going, and the bound still ends it.
      if [ -n "$PRE_DEV" ] &&
         awk -v d="$(dev_abs "$PRE_DEV")" -v m="$PRE_BAR" 'BEGIN { exit (d <= m) ? 0 : 1 }'; then
        PLATEAU=1
        break
      fi
    fi
    PRE_PREV="$TMP/pre.$PRE_PH"
    if [ "$PRE_PH" = 1 ]; then PRE_PH=2; else PRE_PH=1; fi
  done
  HOLD_WALL=$((HOLD_WALL + $(now_s) - PRE_T0))
  if [ "$PLATEAU" = 1 ]; then
    say "   IT IS HOLDING STILL ENOUGH: after ${PRE_WAITED}s of wall clock, the largest change on any tsens zone"
    say "   in the last ${PRE_GAP}s was $(dev_abs "$PRE_DEV") C (signed $(dev_signed "$PRE_DEV") C, on $(dev_where "$PRE_DEV"))"
    say "   -- projected over this run's ${RUN_SPAN}s that is $(proj_of "$PRE_DEV" "$PRE_GAP" "$RUN_SPAN") C, inside the ${MARGIN} C bar."
    say "   Window A below is a STATE, not a point on a curve -- which is what makes B and C comparable to it."
  else
    bad "   NO PLATEAU within ${SETTLE_START}s of wall clock: two readings ${PRE_GAP}s apart never agreed closely"
    bad "   enough to price this run. The largest change it still saw was $(dev_abs "${PRE_DEV:-0.0|0.0|}") C (signed"
    bad "   $(dev_signed "${PRE_DEV:-0.0|0.0|}") C, on $(dev_where "${PRE_DEV:-0.0|0.0|}")) -- projected over this run's ${RUN_SPAN}s"
    bad "   that is $(proj_of "${PRE_DEV:-0.0|0.0|}" "$PRE_GAP" "$RUN_SPAN") C, against the ${MARGIN} C this experiment can attribute."
    bad ""
    bad "   The bar is not the sample interval, it is what this run can resolve: one interval of ${PRE_GAP}s is"
    bad "   allowed ${PRE_BAR} C of it, and this phone used more than that. A window read on a moving phone is a"
    bad "   point on a curve: the same drift would sit inside every delta below it, and the number this run"
    bad "   could print would be the drift PLUS the governor, with no way to tell them apart from the windows"
    bad "   alone. THIS RUN PRINTS NO PRICE and stops HERE."
    bad ""
    bad "   What it does establish is about the PHONE and about the DESIGN: this phone does not hold still at"
    bad "   the timescale of a run, and a three-window A/B/C requires it to (docs 173, section 6.1). That is"
    bad "   the number the next design has to beat, and it is worth having."
    bad "   NOTHING WAS WRITTEN: this is refused before window A, and the only write this script has made is"
    bad "   the same-value proof, which writes back the value the cores already held (state '$(gov_state)')."
    bad "   To measure anyway: --settle-start 0 runs the old design, and --margin N raises the displacement"
    bad "   this run is allowed; both are printed by whatever run follows this one."
    cost_line
    exit 1
  fi
fi

# --- the alternating design (docs 175) ------------------------------------------------------------------
# WHY THERE IS A SECOND DESIGN, in one paragraph. The three-window design below needs window A to be a STATE:
# it holds the phone still before A and waits for the reading to come back before C. Docs 174 made that
# requirement executable arithmetic -- on this phone one 10 s interval may use 0.012 C of the 0.5 C bar, which
# is below the instrument's own 0.1 C step -- so a phone that moves at all is refused in the first interval.
# The REQUIREMENT is the problem, not the bar: the design asks for a noise of zero, and this phone does not
# have one. This design does not ask. It pairs, and then it MEASURES the noise.
#
# The shape: `A B A B ...`, N pairs of (fix window, pinned window), each write proved by read-back. The
# reading is the per-pair difference d_i = B_i - A_i. Every slow movement -- the phone warming as the run
# goes on, the ambient, the battery, the SoC's own timescale -- is in BOTH halves of a pair and cancels in
# the difference; and the SCATTER of the d_i is a direct estimate of the noise, which is the thing this
# design has and the three-window one never had. The verdict is then an interval against a bar, and it can
# come out INCONCLUSIVE -- an answer the old design could not give, because it had no error bar to give it.
#
# The primary zone is declared in the FIRST window, before any intervention, because the largest of N means
# sits a couple of standard errors above zero even when nothing happened: that is exactly the shape docs 172
# printed as a price, and pre-registering is what stops this design from reprinting it.
#
# What it is honest about: this cancels DRIFT, not LAG. The zones follow the power through the SoC's thermal
# time constant (still unmeasured, docs 173 section 8), so a window comparable to that constant reports a
# SMALLER effect than the truth -- a bias toward the fix looking cheaper, never dearer.
#
# The loop is at the top level and every counter is the script's own, because /bin/sh has no locals and a
# counter accumulated inside a helper is not a counter (docs 174 section 4.3).
if [ "$PAIRS" -gt 0 ]; then
  hdr "the alternating design -- ${PAIRS} pair(s) of (fix '${FIX_GOV}', pinned '${BLOCKED_GOV}')"
  say "   Every pair is two proved writes and two windows of ${SECONDS_WIN}s, with ${SETTLE}s after each write. The"
  say "   reading is the difference '${BLOCKED_GOV}' minus '${FIX_GOV}' WITHIN a pair, so whatever the phone does"
  say "   over the ~$((PAIR_SPAN / 60)) minutes of this run it does to both halves of a pair and cancels in the difference."
  say "   NO pre-hold and NO wait: neither window has to be a STATE, because the comparison is between two"
  say "   windows ${SECONDS_WIN}s apart rather than between readings taken $((${PAIRS} * 2)) windows apart."
  say "   The risk is held the other way round from the three-window design: pinning is written, settled and"
  say "   held for exactly ONE window, then the fix is written back -- so the phone is never more than one"
  say "   window away from the state this script found it in."

  # TAKING ONE SLOT: write the slot's governor, prove the read-back, settle, read one window. It is a
  # function because the two slots of a pair are the same action with a different value, and because the
  # ORDER they are taken in is what balances the design (see the loop). Every name it uses is prefixed: /bin/sh
  # has no locals, so an unprefixed loop variable here would be its caller's.
  take_slot() { # $1 = the governor, $2 = the window label; leaves the busy figure in SLOT_BUSY
    WROTE=1   # armed BEFORE the write: from here a core may hold a different value, so the trap owes it one
    if write_gov "$1"; then
      :
    else
      bad "   THE WRITE DID NOT LAND in window ${2}: after writing '$1' the cores read '$(gov_state)'. The rest"
      bad "   of this run would compare two identical states, which reads as 'the governor costs nothing' --"
      bad "   the one wrong answer that looks real. Refusing to print a verdict; the trap restores, exit 4."
      exit 4
    fi
    sleep "$SETTLE"
    win "$2"; SLOT_BUSY=$WIN_BUSY
    # THE ORDER THE RUN ACTUALLY TOOK, recorded as it goes rather than recomputed from the design. The
    # balance below is computed from THIS file, so a run that took its pairs in the wrong order reports the
    # imbalance it created instead of the one its arithmetic expected.
    printf '%s\n' "$2" >> "$TMP/order"
    say "      ${2}: '$1' proved on all ${CPU_N} core(s), ${SECONDS_WIN}s, busy ${SLOT_BUSY} of 4"
  }

  PRE_REG=1
  PZ=
  zl1_i=1
  while [ "$zl1_i" -le "$PAIRS" ]; do
    # THE ORDER INSIDE A PAIR ALTERNATES -- pair 1 is (fix, pinned), pair 2 is (pinned, fix), pair 3 (fix,
    # pinned) ... -- and this is not decoration, it is what makes the design BALANCED. With every pair in the
    # same order, the pinned window is always taken one window LATER than its own fix window, so the phone's
    # own drift over one window lands inside every difference with the same sign and the mean of the
    # differences is biased by exactly that: the reading would be the effect PLUS one window of drift.
    # Alternating the order puts the fix windows and the pinned windows at the SAME mean position in time, so
    # the drift cancels in the mean of ALL the differences instead of only between pairs -- and the balance is
    # printed below as a number, so this is checkable rather than asserted.
    if [ $((zl1_i % 2)) = 1 ]; then zl1_first=fix; else zl1_first=pinned; fi
    say "   pair ${zl1_i}/${PAIRS}: ${zl1_first} window first, then the other one"
    if [ "$zl1_first" = fix ]; then
      take_slot "$FIX_GOV" "A.${zl1_i}"
      # THE PRE-REGISTERED ZONE, taken from the FIRST window of the run and never revisited: A.1 is a fix
      # window read before any pinned write, so this is a zone chosen before the intervention, not after it.
      [ -n "$PZ" ] || PZ=$(hot_zone "$TMP/win.A.${zl1_i}")
      take_slot "$BLOCKED_GOV" "B.${zl1_i}"
    else
      take_slot "$BLOCKED_GOV" "B.${zl1_i}"
      take_slot "$FIX_GOV" "A.${zl1_i}"
    fi
    zl1_i=$((zl1_i + 1))
  done

  # THE UNDO, proved like every other write here, and `WROTE=0` only once the read-back says it held.
  if write_gov "$FIX_GOV"; then
    WROTE=0
    say "   the pairs are done: all ${CPU_N} core(s) read '${FIX_GOV}' -- the state this run started in."
  else
    bad "   THE RESTORE DID NOT HOLD after the last pair: the cores read '$(gov_state)'. The trap will try"
    bad "   again on exit; refusing to print a verdict from a run whose undo failed. Exiting 4."
    exit 4
  fi

  # --- the reading: one difference per pair, TSENS zones only -------------------------------------------
  # TSENS only, for the reason the three-window verdict takes its maximum over those and not over the whole
  # table: the battery and the pm8994 rails follow the charger, so a difference there is about the power
  # supply rather than about the SoC. The pair index is carried so that the scatter is per-zone and the
  # control (A to A) can be computed from the same file.
  zl1_i=1
  : > "$TMP/pair.a"
  : > "$TMP/pair.b"
  while [ "$zl1_i" -le "$PAIRS" ]; do
    awk -v i="$zl1_i" '$1 ~ /^thermal_zone[0-9]+$/ && $2 ~ /^tsens_tz_sensor/ && $4 == "C" { print i, $1, $2, $3 }' \
      "$TMP/win.A.${zl1_i}" >> "$TMP/pair.a"
    awk -v i="$zl1_i" '$1 ~ /^thermal_zone[0-9]+$/ && $2 ~ /^tsens_tz_sensor/ && $4 == "C" { print i, $1, $2, $3 }' \
      "$TMP/win.B.${zl1_i}" >> "$TMP/pair.b"
    zl1_i=$((zl1_i + 1))
  done

  # mean, standard error and count per zone -- `se = sd / sqrt(n)`, and `sd` from the sum of squares rather
  # than a second pass. A zone with fewer than 2 usable pairs has no scatter and is left out with a line
  # saying so: a mean with no error bar is not a reading this design can use.
  awk -v A="$TMP/pair.a" -v B="$TMP/pair.b" -v NP="$PAIRS" '
    {
      i = $1; z = $2
      if (FILENAME == A) av[i "|" z] = $4 + 0; else bv[i "|" z] = $4 + 0
      if (!(z in type)) { type[z] = $3; order[++nz] = z }
    }
    END {
      for (j = 1; j <= nz; j++) {
        z = order[j]; m = 0; s = 0; s2 = 0
        for (i = 1; i <= NP; i++) {
          k = i "|" z
          if (!((k in av) && (k in bv))) continue
          d = bv[k] - av[k]; m++; s += d; s2 += d * d
        }
        if (m < 2) { few++; continue }
        mean = s / m
        var = (s2 - m * mean * mean) / (m - 1)
        if (var < 0) var = 0
        printf "%s %s %.2f %.2f %d\n", z, type[z], mean, sqrt(var / m), m
      }
      if (few) printf "# %d tsens zone(s) had fewer than 2 usable pair(s) and are not in this table\n", few > "/dev/stderr"
    }' "$TMP/pair.a" "$TMP/pair.b" > "$TMP/pairs" 2>"$TMP/pairs.note"

  if [ ! -s "$TMP/pairs" ]; then
    bad "   NO TSENS ZONE WAS READABLE IN TWO PAIRS: there is no reading, so there is no verdict to print."
    bad "   That is a statement about this run and about the instrument, not about the governor. Exit 1."
    cost_line
    exit 1
  fi
  [ -s "$TMP/pairs.note" ] && { while IFS= read -r l; do say "   $l"; done < "$TMP/pairs.note"; }
  NZ=$(wc -l < "$TMP/pairs" | tr -d ' ')

  # The primary zone, or -- if window A.1 had no readable tsens zone at all -- the largest mean AFTER the
  # fact, said out loud as the weaker evidence it is. Silence here would let every run pick its winner.
  if [ -z "$PZ" ]; then
    PRE_REG=0
    PZ=$(sort -k3,3gr "$TMP/pairs" | head -1 | awk '{ print $1 }')
  fi
  PR=$(awk -v z="$PZ" '$1 == z { print; exit }' "$TMP/pairs")
  if [ -z "$PR" ]; then
    bad "   the pre-registered zone ${PZ:-<none>} has fewer than 2 usable pairs, so this run has no primary"
    bad "   reading -- and the whole point of declaring it in the first window is that it cannot be swapped"
    bad "   for one that does. Nothing is printed as a verdict from this run. Exit 1."
    cost_line
    exit 1
  fi
  PT=$(printf '%s' "$PR" | awk '{ print $2 }')
  PM=$(printf '%s' "$PR" | awk '{ print $3 }')
  PSE=$(printf '%s' "$PR" | awk '{ print $4 }')
  PN=$(printf '%s' "$PR" | awk '{ print $5 }')
  PR_STATS=$(awk -v m="$PM" -v se="$PSE" 'BEGIN { printf "%.2f %.2f", m - 2 * se, m + 2 * se }')
  LO=${PR_STATS%% *}
  HI=${PR_STATS##* }

  # The control: how fast the FIX windows were moving on their own, pair to pair. This is the drift the
  # pairing cancels, measured over the same minutes as the reading -- and its size is why the three-window
  # design could not price this phone at all (docs 174, section 6.1).
  #
  # The rate is per WINDOW and not per interval, because the intervals are not all the same length: the
  # alternating order puts consecutive fix windows 1 or 3 windows apart, and a mean over unequal intervals
  # would be a mean of two different quantities. Dividing each difference by its own gap turns them all into
  # the same thing: the phone's C per window. The gap comes from `$TMP/aidx`, WHICH IS THE RUN'S OWN RECORD
  # of where each fix window sat -- not from the design's arithmetic -- so a run that did not take its pairs
  # in the intended order gets the rate of the run it actually made.
  awk '{ n++; if ($1 ~ /^A\./) { sub(/^A\./, "", $1); print $1, n } }' "$TMP/order" > "$TMP/aidx" 2>/dev/null
  awk -v A="$TMP/pair.a" -v AP="$TMP/aidx" -v NP="$PAIRS" '
    FILENAME == AP { apos[$1 + 0] = $2 + 0; next }
    {
      v[$1 "|" $2] = $4 + 0
      if (!($2 in seen)) { seen[$2] = 1; order[++nz] = $2; typ[$2] = $3 }
    }
    END {
      for (j = 1; j <= nz; j++) {
        z = order[j]; m = 0; s = 0
        for (i = 1; i < NP; i++) {
          k0 = i "|" z; k1 = (i + 1) "|" z
          if (!((k0 in v) && (k1 in v))) continue
          if (!((i in apos) && ((i + 1) in apos))) continue
          g = apos[i + 1] - apos[i]
          if (g <= 0) continue
          d = (v[k1] - v[k0]) / g; m++; s += d
        }
        if (m < 1) continue
        mean = s / m; a = mean; if (a < 0) a = -a
        printf "%s %s %.2f %d %.2f\n", z, typ[z], mean, m, a
      }
    }' "$TMP/aidx" "$TMP/pair.a" > "$TMP/drift"

  hdr "the per-pair differences (the reading) -- tsens zones only, and the primary zone is marked"
  say "   zone       type                    mean    se     n"
  sort -k3,3gr "$TMP/pairs" | awk -v pz="$PZ" '{
    m = ($1 == pz) ? "  <- PRE-REGISTERED (hottest zone of window A.1, before any write)" : ""
    printf "   %-10s %-22s %+6.2f %5.2f %3d%s\n", $1, $2, $3, $4, $5, m }'
  say "   (${NZ} tsens zone(s) in this table; every one is printed. The scatter above is the error bar this"
  say "   design has and the three-window one did not: it is MEASURED from the pairs, not assumed to be zero.)"

  if [ -s "$TMP/drift" ]; then
    DR_MAX=$(sort -k5,5gr "$TMP/drift" | head -1)
    DR_RATE=$(printf '%s' "$DR_MAX" | awk '{ printf "%.2f", $5 }')
    DR_SGN=$(printf '%s' "$DR_MAX" | awk '{ printf "%+.2f", $3 }')
    DR_ZONE=$(printf '%s' "$DR_MAX" | awk '{ print $1 }')
    DR_N=$(printf '%s' "$DR_MAX" | awk '{ print $4 }')
    hdr "the control: how fast the phone was moving on its OWN, measured between the '${FIX_GOV}' windows"
    say "   zone       type                    C per window   n"
    sort -k5,5gr "$TMP/drift" | awk '{ printf "   %-10s %-22s %+14.2f %3d\n", $1, $2, $3, $4 }'
    say "   The fastest is ${DR_SGN} C per window on ${DR_ZONE}, over ${DR_N} interval(s) between fix windows. This is"
    say "   the drift the pairing removes from the reading, and it is the number that says the pairing is doing"
    say "   work rather than decorating the answer: it is measured over the same minutes as the reading."
    DRIFT_LINE="the phone moved up to ${DR_RATE} C per window on its own (on ${DR_ZONE}), and the pairing removes that"
  else
    DRIFT_LINE="no two fix windows could be compared, so this run did NOT measure the phone's own drift"
    DR_RATE=
    bad "   NOTE: no zone was readable in two consecutive fix windows, so the control above is missing: this"
    bad "   run prices the governor against a drift it did not measure."
  fi

  # --- the design's balance, computed rather than asserted -----------------------------------------------
  # Every claim this design makes about drift rests on the two halves of the run sitting at the same mean
  # position in TIME. `$TMP/order` is the order the run ACTUALLY took, one line per window, so this is a
  # reading of the run and not a restatement of the design -- a run whose pairs came out in the wrong order
  # reports the imbalance it created. The residual is turned into degrees with the drift measured above, so
  # "balanced" is falsifiable rather than a claim.
  BAL=$(awk '
    { n++; if ($1 ~ /^A\./) { sa += n; na++ } else if ($1 ~ /^B\./) { sb += n; nb++ } }
    END {
      if (na < 1 || nb < 1) { printf "none none none"; exit }
      d = sb / nb - sa / na
      if (d < 0) d = -d
      printf "%.2f %.2f %.2f", sa / na, sb / nb, d
    }' "$TMP/order" 2>/dev/null)
  BAL_A=${BAL%% *}; zl1_r=${BAL#* }; BAL_B=${zl1_r%% *}; BAL_IMB=${BAL##* }
  say ""
  if [ "$BAL_A" = none ]; then
    bad "   THE DESIGN'S BALANCE COULD NOT BE COMPUTED: the run did not record both an A and a B window. The"
    bad "   drift cancelling below rests on this, so read the reading with that in mind."
    BAL_SENT="and the balance this design depends on could NOT be computed -- see above"
  else
    say "   THE DESIGN'S BALANCE: the fix windows sat at mean position ${BAL_A} in the run and the pinned"
    say "   windows at ${BAL_B}, so the imbalance is ${BAL_IMB} window(s). Every difference above is taken between a"
    say "   fix window and a pinned window whose ORDER ALTERNATES, which is what keeps that number small: with"
    say "   a FIXED order inside the pair it would be 1.00 window, and every difference would carry one window"
    say "   of the drift."
    if [ -n "$DR_RATE" ]; then
      say "   At the fastest drift measured above (${DR_RATE} C per window), ${BAL_IMB} window(s) of imbalance is worth"
      say "   about $(awk -v i="$BAL_IMB" -v r="$DR_RATE" 'BEGIN { printf "%.2f", i * r }') C of the reading."
    fi
    BAL_SENT="and they sat at mean positions ${BAL_A} and ${BAL_B} in the run, an imbalance of ${BAL_IMB} window(s) -- the alternating order is what keeps those together, and the balance line above is the check"
  fi

  # --- the verdict --------------------------------------------------------------------------------------
  # Two standard errors, against the same 0.2 C bar the three-window verdict uses -- the bar is the
  # instrument's resolution and is a property of the phone, not of the design. The three outcomes are
  # different STATEMENTS, and the middle one is the one the old design could not make:
  VERDICT=$(awk -v m="$PM" -v se="$PSE" -v res=0.2 '
    BEGIN {
      lo = m - 2 * se; hi = m + 2 * se
      if (lo >= res) { print "cost-measured"; exit }
      if (hi < res)  { print "no-detectable-cost"; exit }
      print "inconclusive"
    }')

  hdr "the verdict (the alternating design)"
  if [ "$PRE_REG" = 1 ]; then
    say "   the primary zone was PRE-REGISTERED, in the first window of the run and before any '${BLOCKED_GOV}'"
    say "   write: ${PZ} (${PT}). Nothing below chose it from the data -- and that matters, because the largest of"
    say "   the ${NZ} means above would sit about two standard errors above zero with no effect at all. That is the"
    say "   shape docs 172 printed as a price."
  else
    say "   WARNING: window A.1 had no readable tsens zone, so no zone could be pre-registered. The primary"
    say "   zone below is ${PZ} (${PT}) -- the largest mean AFTER the fact, which is the weakest kind of evidence"
    say "   this design can produce. Read it as a hypothesis for the next run and not as this run's reading."
  fi
  say "   the mean of ${PN} pair difference(s) on it:  ${PM} C   (standard error ${PSE} C)"
  say "   so the two-standard-error interval is [${LO}, ${HI}] C, and this experiment calls 0.2 C a cost."
  say "   the control, over the same minutes: ${DRIFT_LINE}."
  say ""
  if [ "$VERDICT" = cost-measured ]; then
    say "   -> COST-MEASURED: pinning all four cores is worth ${PM} C on ${PZ} (${PT}), and the whole two-standard-error"
    say "      interval [${LO}, ${HI}] is above the 0.2 C this experiment can resolve. At this load, and with the"
    say "      phone's own drift cancelled by the pairing rather than assumed absent, that is what the second"
    say "      heat cause costs in temperature."
    RC=0
  elif [ "$VERDICT" = no-detectable-cost ]; then
    say "   -> NO DETECTABLE COST: the whole interval is under the 0.2 C this experiment can resolve -- pinning"
    say "      all four cores did not warm this phone by anything this run can see. That is this script coming"
    say "      out AGAINST the fix it was built around: as a reading it says the second heat cause's value is"
    say "      in the clock and in long-run power, not in these zones at this load."
    RC=0
  else
    say "   -> INCONCLUSIVE: the interval [${LO}, ${HI}] reaches across the 0.2 C this experiment calls a cost, so"
    say "      these ${PN} pair(s) cannot separate 'the governor costs nothing' from 'it costs something'. That is"
    say "      a statement about the DATA and not about the governor -- and it is exactly the answer the"
    say "      three-window design could not give, because it had no error bar to report it with."
    # What it would take, from this run's own scatter: n scales as (se / target)^2, and the target is the se
    # that would put the lower end of the interval on the bar. Printed rather than acted on: this design
    # spends a boot per run, so the number belongs to the operator.
    NEED=$(awk -v m="$PM" -v se="$PSE" -v n="$PN" -v res=0.2 '
      BEGIN {
        target = (m - res) / 2
        if (target <= 0) { print "the mean is not above the bar at all, so no number of pairs would help: raise the effect (a load) or the window"; exit }
        if (se <= 0) { print "3 (this run measured no scatter at all, which cannot be right -- treat it as a defect)"; exit }
        k = n * (se / target) ^ 2
        printf "%d", (k > int(k) ? int(k) + 1 : int(k))
      }')
    case "$NEED" in
    ''|*[!0-9]*) say "      What it would take: ${NEED}." ;;
    *)           say "      At this scatter that would need about ${NEED} pair(s); each pair costs about $((2 * (SECONDS_WIN + SETTLE + 13)))s of"
                 say "      wall clock here, and 3 is the fewest this design allows (--pairs checks that)."
                 # A number larger than the design's own ceiling is a statement about the RUN and not a plan:
                 # `--pairs` refuses more than 30, so saying "run 60 pairs" without saying that would be
                 # advice this instrument cannot take.
                 if [ "$NEED" -gt 30 ] 2>/dev/null; then
                   say "      That is MORE than the 30 pairs --pairs allows, so at this scatter the answer is not"
                   say "      more pairs: it is a bigger effect (a load) or a longer window (which costs lag)."
                 fi ;;
    esac
    RC=1
  fi
  say ""
  say "   Read it as a READING and not as the governor fix's price in general: ambient is not controlled, the"
  say "   battery's charging state is not controlled, and the load is whatever the phone was doing -- which is"
  say "   why the busy figure is printed for every window above. What this design DOES control is the phone's"
  say "   own drift, two ways: the two halves of a pair are ${SECONDS_WIN}s apart instead of a run apart,"
  say "   ${BAL_SENT}."
  say "   What it cannot control is LAG: ${SECONDS_WIN}s may be short against the SoC's thermal time constant (still"
  say "   unmeasured), so this design can UNDER-report the cost. A longer window trades that bias for more"
  say "   drift inside a pair, and the control above is how the trade is checked."
  say "   The zones are the instrument's numbers, normalised by it; this script does not divide."
  say "   This run used: --pairs ${PAIRS} --seconds ${SECONDS_WIN} --settle ${SETTLE}."
  say "   The cores read '$(gov_state)'$(gov_list) -- the state it started in."
  cost_line
  exit "$RC"
fi

hdr "window A -- as installed (every core on '$FIX_GOV', nothing written yet)"
win A; BUSY_A=$WIN_BUSY
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
win B; BUSY_B=$WIN_BUSY
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
WAITED=0; DEV=; DEV_ABS=; DEV_SGN=; DEV_WHERE=; DIR=; RETURNED=0
if [ -z "$W_A" ]; then
  bad "   window A had no readable tsens zone at all, so there is no reading for this to come back to. The"
  bad "   wait is skipped and the verdict below cannot be trusted; that is a statement about the instrument."
elif [ "$SETTLE_BACK" = 0 ]; then
  say "   --settle-back 0: THE WAIT IS OFF. Window C will start immediately after the undo, so if the"
  say "   intervention's heat has not decayed by then the control window cannot separate it from the"
  say "   governor -- which is what the first device run of this instrument measured (docs 170). The verdict"
  say "   below is read with that limitation, and 'contaminated' is a property of THIS setting."
else
  say "   window A's hottest tsens zone: ${W_A} C. Waiting up to ${SETTLE_BACK}s of WALL CLOCK (every ${POLL}s,"
  say "   and the seconds THIS waits for are the clock's, samples and all: docs 174) for EVERY tsens zone to"
  say "   come back to within ${MARGIN} C of its OWN window A reading before window C reads anything. Every"
  say "   zone, and not just the hottest one: the hottest zone CHANGES HANDS while a run goes on, so a test"
  say "   that follows it compares one zone's number with another's and calls it a return (docs 172 -- the"
  say "   second device run passed that test while being 4.2 C down)."
  # `--poll 0` would spin the loop forever (the bound would never be spent), so a sample always costs at least
  # one second -- and the number that goes into the message is the clock's, not the one asked for.
  ADV=$POLL
  [ "$ADV" -ge 1 ] 2>/dev/null || ADV=1
  WAIT_T0=$(now_s)
  while [ "$(( $(now_s) - WAIT_T0 ))" -lt "$SETTLE_BACK" ]; do
    sleep "$ADV"
    HOLD_SLEEP=$((HOLD_SLEEP + ADV))
    sh "$THERMAL" --seconds "$ADV" --quiet > "$TMP/back" 2>&1
    HOLD_SAMPLES=$((HOLD_SAMPLES + 1))
    WAITED=$(( $(now_s) - WAIT_T0 ))
    DEV=$(max_dev "$TMP/win.A" "$TMP/back")
    # An unreadable sample is not a returned reading: skipping it (rather than treating "" as 0 or as a
    # return) keeps the loop going, and the bound still ends it.
    [ -n "$DEV" ] || continue
    DEV_ABS=$(dev_abs "$DEV"); DEV_SGN=$(dev_signed "$DEV"); DEV_WHERE=$(dev_where "$DEV")
    case "$DEV_SGN" in -*) DIR="BELOW window A's reading of the SAME zone" ;; *) DIR="ABOVE window A's reading of the SAME zone" ;; esac
    if awk -v d="$DEV_ABS" -v m="$MARGIN" 'BEGIN { exit (d <= m) ? 0 : 1 }'; then
      RETURNED=1
      break
    fi
  done
  HOLD_WALL=$((HOLD_WALL + $(now_s) - WAIT_T0))
  if [ "$RETURNED" = 1 ]; then
    say "   IT CAME BACK: every tsens zone is within ${MARGIN} C of its own window A reading after ${WAITED}s of"
    say "   wall clock -- the largest difference was ${DEV_ABS} C (${DEV_SGN} C, on ${DEV_WHERE}). Window C below is"
    say "   therefore a CONTROL and not a second reading of the same heat."
  else
    bad "   IT DID NOT COME BACK within ${SETTLE_BACK}s of wall clock: the largest difference from window A is"
    bad "   ${DEV_ABS} ${DIR} (${DEV_SGN} C, on ${DEV_WHERE}). Two things can look like this and this instrument"
    bad "   cannot tell them apart: the intervention's warming has not decayed (thermal mass), or the phone"
    bad "   moved on its own by more than the margin while the run went on -- in EITHER direction. BOTH are"
    bad "   statements about this RUN and about the phone. Neither is a price for the governor, so THIS RUN"
    bad "   PRINTS NO PRICE: there is no control window to compare against, and window C is not read at all."
    bad ""
    bad "   What it does establish is the phone's own thermal behaviour under this intervention, and that is"
    bad "   worth having: it is the number a longer wait would have to beat. If you want the price anyway,"
    bad "   --settle-back 0 runs the old design and --margin N raises the displacement bar; both are printed"
    bad "   in the verdict so nobody has to guess which one was used."
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
  say "   -> NO RETURN: some tsens zone did not come back to within ${MARGIN} C of its own window A reading"
  say "      within ${SETTLE_BACK}s (the largest difference was ${DEV_ABS} C ${DIR}), so window C would not"
  say "      have read window A's state -- it would have read whatever the run did to the phone after A."
  say "      This run therefore PRINTS NO PRICE for the second heat cause, and that is the correct answer:"
  say "      the number the old design would have printed from A and B alone (the largest warming above) is"
  say "      not the governor's cost, it is the governor's cost PLUS however far the phone moved on its own"
  say "      -- and this instrument has just measured that the phone moved further than it can resolve."
  say ""
  say "   What this run DOES establish is about the phone: after the intervention was undone, the zones were"
  say "   still ${DEV_ABS} C away from their window A readings ${SETTLE_BACK}s later. That is the number a"
  say "   longer wait or a bigger margin would have to beat, and it is printed with the setting that produced"
  say "   it."
  say ""
  say "   The cores read '$(gov_state)'$(gov_list) -- the state it started in."
  cost_line
  exit 1
fi

hdr "window C -- the CONTROL: the fix's state again, so the third window is the same state as the first"
win C; BUSY_C=$WIN_BUSY
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
  cost_line
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
say "   battery's charging state is not controlled, and BOTH of the other two windows are what the two holds"
say "   above made them (the pre-hold projected the phone's own movement over this run's ${RUN_SPAN}s and found it"
say "   inside ${MARGIN} C before window A, and the wait found every zone back within ${MARGIN} C of it before"
say "   window C; what each measured is printed above)."
say "   The zones are the instrument's numbers, normalised by it; this script does not divide."
say "   This run used: --seconds ${SECONDS_WIN} --settle ${SETTLE} --settle-start ${SETTLE_START}"
say "   --settle-back ${SETTLE_BACK} --poll ${POLL} --margin ${MARGIN}."
say ""
say "   The cores read '$(gov_state)'$(gov_list) -- the state it started in."
cost_line
exit "$RC"
