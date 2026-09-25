#!/usr/bin/env bash
# zl1 ONE-BOOT RUNBOOK -- the whole post-EDL sequence as one command, in the one order that works.
#
# WHY THIS EXISTS (and it is the same argument the heat-fix chain made for itself, one level up):
#
#   Getting out of EDL costs a PHYSICAL long press on POWER for 10-20 s, and a script cannot help with
#   that. So the boot that follows is a resource that was bought with a finger, and the way to waste it
#   is a list of five or six hand-typed commands that gets half-done and then abandoned. Doc 122 section
#   9 lists exactly that list. This is that list as one command.
#
#   The order is NOT a preference. It is FORCED, and each arrow has a reason that can be checked:
#
#     01 capture            FIRST, because three of the things it reads stop existing later in this
#                           very sequence: the debug keeper's pid and accumulated CPU ticks (step 03
#                           kills it) and the netwatch log that licenses that kill. Read-only.
#     02 panic guard        BEFORE anything that could panic, and it is the ONE step that outlasts the
#                           boot: `--install` writes a unit that clears `download_mode` at every boot,
#                           so one install makes every LATER boot start with panic->EDL disarmed. It
#                           also arms THIS boot (`systemctl enable --now` runs the applier now), which
#                           is what satisfies the LPM ladder trial's prerequisite A at step 05.
#     03 heat chain         before 05, because retiring the debug keeper here is what satisfies the
#                           trial's prerequisite C -- a CPU that is never idle does not enter a deep
#                           idle state, so the trial refuses while the keeper runs. This is also the
#                           step that can drop this session (its activate stage re-enumerates the USB
#                           gadget and waits 90 s for the netwatch to heal), which is why it is not
#                           first: everything that only exists on this boot is already on disk by then.
#     04 fingerprint        order-free, and placed here because it is a small unit install that reads
#                           back a directory; its verdict is a log count that can be read at leisure.
#     05 trial --status     LAST, and read-only. Its refusals are checked against what steps 02 and 03
#                           actually did, so this is the first moment in the boot where they can all be
#                           true at once. `--apply-trial` upgrades this one step to the write, and it is
#                           a SEPARATE flag on purpose: `--yes` authorizes the sequence, NOT a write to
#                           the SoC's power parameter.
#
# WHAT THIS ADDS OVER RUNNING THE FIVE BY HAND: it checks each step's result against the NEXT step's
#   precondition, from the device, as soon as that precondition becomes checkable -- `download_mode`
#   after 02, the keeper's absence after 03. Discovering at step 05 that A or C did not actually move
#   is discovering it at the end of the only boot there is; this fails loudly at the step that caused
#   it, and its verdict says which downstream step is now blocked.
#
# WHAT IT NEVER DOES, in any mode: reboot the device, flash anything, run a QDL/firehose tool, write a
#   partition, touch the forbidden partition set (modem/EFS/calibration), or run a trial write without
#   --apply-trial. Steps 02/03/04 DO write to the device -- that is what they are for -- and each one's
#   own installer carries its own refusals and its own read-back. This script adds no new safety
#   argument; it adds the ORDER and the arithmetic of one boot.
#
# Usage: zl1-one-boot-runbook.sh [--status] [--yes] [--apply-trial] [--only STEP] [--skip STEP]
#                                [--outdir DIR] [--settle SECS] [--step-limit SECS]
#                                [--state-limit SECS]
#   --status       (default) READ-ONLY: which steps are already done on this boot, and which of the
#                  trial's three prerequisites currently hold. Writes nothing, installs nothing.
#   --yes          run the sequence. Without it: print the plan for this boot and exit 2.
#   --apply-trial  at step 05, run the trial's --apply instead of --status. THE TRIAL WRITES TO THE
#                  SOC'S POWER PARAMETER (`lpm_levels.sleep_disabled`), it is the only write in this
#                  sequence that no installer owns, and it is the operator's decision -- so it is not
#                  implied by --yes. Refused unless the sequence reached step 05 with A and C met.
#   --only STEP    run just this step (and its prerequisites are NOT checked -- you are driving).
#   --skip STEP    leave this step out. Steps are named 01-capture, 02-panic-guard, 03-heat-chain,
#                  04-fingerprint, 05-trial.
#   --outdir DIR   where to archive (default: repo tmp-one-boot-<utc timestamp>/)
#   --settle SECS  passed through to the heat chain (its default is 90)
#   --step-limit SECS  wall-clock bound on ONE step (default 900). A step that outlasts it is reported
#                  as DID NOT FINISH -- not as a failure of the step, and not as a success -- because on
#                  this phone the next move is a physical power hold and nothing else. It has to be
#                  looser than the heat chain's own total (that chain bounds each of its steps itself);
#                  if you widen --settle or the chain's --ab-window/--ab-hold, widen this with it.
#
#                  THAT SENTENCE USED TO BE PROSE AND NOTHING MEASURED IT. Two steps here are ARCHIVING
#                  callees -- 01-capture and 03-heat-chain -- and each bounds its own steps from the
#                  inside, so each has a worst case that 900 s does not cover: the capture runs nineteen
#                  device steps at --step-limit 240 (4x over) and the chain's own total is larger still.
#                  Cutting either one off mid-flight does not fail it: it throws away the rest of what
#                  that boot was going to read, on a boot that cannot be re-run. So those two steps get a
#                  bound COMPUTED FROM THE CALLEE ITSELF, and this flag is their FLOOR, not their value.
#                  Both numbers are printed with the arithmetic that produced them.
#   --state-limit SECS  wall-clock bound on the ssh calls that are NOT steps (default 60): the
#                  reachability probe, the boot-id read, and the two readings that decide A and C. A
#                  bound on the steps is defeated by an unbounded call between them -- and a timeout that
#                  arrived as an empty string would be printed as a verdict ABOUT THE PHONE. So each of
#                  them reports "NOT READ ... the host gave up" as its own state.
#
# Exit codes:
#   0  the sequence ran to the end and every step's own verdict was acceptable
#   1  the sequence stopped short -- a step failed, or a step did not finish inside --step-limit, or a
#      downstream precondition did NOT move -- and the archive says which. Whatever ran before it is
#      archived.
#   2  refused: no --yes, or the device is not reachable (NOTHING was run, not even one ssh call)
#   3  interrupted: what had run is archived and indexed anyway
#
# Env: ZL1_HOST (default root@10.15.19.82), ZL1_SERIAL (default 33e80afe)

set -uo pipefail

HOST="${ZL1_HOST:-root@10.15.19.82}"
DEV="${ZL1_SERIAL:-33e80afe}"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 "$HOST")

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
CAP="$HERE/zl1-post-recovery-capture.sh"
PANIC="$HERE/../install-no-edl-on-panic.sh"
HEAT="$HERE/zl1-heat-fix-chain.sh"
FP="$HERE/../install-fingerprint-store-dir.sh"
TRIAL="$HERE/../device/zl1-lpm-ladder-trial.sh"

MODE=status
OUT=""
SETTLE=""
ONLY=""
SKIP=""
APPLY_TRIAL=0
# Every step here is one or more ssh calls to a device whose link the heat chain re-enumerates ON PURPOSE,
# and a hung ssh does not fail -- it hangs. On this phone the resource that spends is a boot that cost a
# physical 10-20 s power hold, and it spends it SILENTLY: the later steps never run and nothing is
# archived, so the boot cannot even be read afterwards. Hence a wall-clock bound on every step.
#
# The default is deliberately generous (900 s): step 03 is the heat chain, which legitimately waits
# --settle and then measures two sampling windows, and step 01 is a full read-only capture. The chain
# bounds EACH OF ITS OWN STEPS too (docs 131), so this is the backstop, not the mechanism -- but the
# backstop has to be looser than the chain's own total, or it would truncate a run that was working. If
# you widen --settle (passed through) or the chain's --ab-window/--ab-hold, widen this with it.
STEP_LIMIT=${ZL1_RB_STEP_LIMIT:-900}
# And the ssh calls that are NOT steps get one too, with the same name the heat chain uses for the same
# job: this runbook makes four of them outside `run_bg` -- the reachability probe, the boot-id read, and
# the two device readings that decide A and C. They are the same defect one level down again: a bound on
# the STEPS is defeated by an unbounded call between them, and a stalled link there means no archive, no
# verdict, and an empty string flowing into a `case` that turns it into a claim ABOUT THE PHONE.
STATE_LIMIT=${ZL1_RB_STATE_LIMIT:-60}


while [ $# -gt 0 ]; do
  case "$1" in
  --status) MODE=status; shift ;;
  --yes) MODE=run; shift ;;
  --apply-trial) APPLY_TRIAL=1; shift ;;
  --only) ONLY="${2?--only needs a STEP}"; shift 2 ;;
  --skip) SKIP="${SKIP:+$SKIP }${2?--skip needs a STEP}"; shift 2 ;;
  --outdir) OUT="${2?--outdir needs a DIRECTORY}"; shift 2 ;;
  --settle) SETTLE="${2?--settle needs SECONDS}"; shift 2 ;;
  --step-limit) STEP_LIMIT="${2?--step-limit needs SECONDS}"; shift 2 ;;
  --state-limit) STATE_LIMIT="${2?--state-limit needs SECONDS}"; shift 2 ;;
  --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; exit 0 ;;
  *) echo "unknown argument ${1:-} (try --help)" >&2; exit 2 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
note() { printf '   %s\n' "$*"; }

# Is timeout(1) here at all? Asked ONCE, at the top, because both bounded paths below need the answer and
# the first of them (the reachability probe) runs before the steps do.
HAVE_TIMEOUT=0
command -v timeout >/dev/null 2>&1 && HAVE_TIMEOUT=1

# The one way this script talks to the device OUTSIDE a step. Every direct ssh goes through here, so
# "is it bounded?" is answered by reading one function rather than by re-checking each call site -- and
# the harness asserts it behaviourally: a device stub that never answers makes the run COME BACK, and a
# mutant without this bound does not. On a timeout it returns timeout(1)'s own 124/137, and the callers
# below turn that into a state of its own rather than into an empty string.
#
# `bound` is the same helper the heat chain uses, and it is deliberately separate from `run_bg`'s inline
# `timeout`: a backgrounded `bound` would make the BACKGROUND PID the subshell's, not timeout's, and the
# signal handler kills that pid -- so an interrupt would report "stopped" while the step kept running.
bound() { # SECS, command...
  local secs="$1"; shift
  if [ "$HAVE_TIMEOUT" = 1 ]; then
    timeout -k 5 "$secs" "$@"
  else
    printf 'NOTE: no timeout(1) on this host -- THIS CALL IS NOT TIME-BOUNDED (limit was %ss)\n' "$secs" >&2
    "$@"
  fi
}
devssh() { bound "$STATE_LIMIT" "${SSH[@]}" "$@"; }
# 124 is timeout(1)'s code and 137 is its -k SIGKILL: both mean THE HOST GAVE UP, which is a fact about
# this machine and NOT a reading of the phone.
gave_up() { # rc
  case "$1" in 124|137) return 0 ;; *) return 1 ;; esac
}

# The five steps, in the one order. Kept as one list so `--skip`, `--only` and the archive cannot
# disagree about what the sequence IS: a step added to the plan and not to this list would be invisible
# to every check below, which is the "an extractor that drops an item" shape this tree has recorded
# twice (docs 120 section 7).
STEPS=(01-capture 02-panic-guard 03-heat-chain 04-fingerprint 05-trial)

skipped() {
  local s
  for s in $SKIP; do [ "$s" = "$1" ] && return 0; done
  return 1
}
# An unknown name is a refusal, not a no-op: `--skip 03-heatchain` (a typo) must not silently run the
# heat chain, and `--only 5-trial` must not silently run nothing.
for s in $SKIP $ONLY; do
  known=0
  for t in "${STEPS[@]}"; do [ "$s" = "$t" ] && known=1; done
  [ "$known" = 1 ] || { echo "unknown step [$s] -- the steps are: ${STEPS[*]}" >&2; exit 2; }
done

# ==================================================================================================
# 0. is there a device at all? -- asked of the HOST's USB tree first, and no ssh call until it answers
# ==================================================================================================
# The same gate, and the same two traps, as the capture's: an EDL device presents 05c6:9008 with NO
# serial, so a search for the serial finds nothing and a search for the vendor id finds a phone that
# cannot be talked to; and the gadget's serial is a PREFIX (`33e80afe-v63-usbd-disabled-rndis`), so an
# equality test reports "absent" for a phone that is up and answering -- the most expensive false
# negative available on a boot that cannot be revisited. The other phone on this bus (4a2fe00b) must
# still read as absent.
edl_state() {
  if lsusb -d 05c6:9008 >/dev/null 2>&1; then echo edl; return; fi
  local d
  for d in /sys/bus/usb/devices/*/; do
    case "$(cat "$d/serial" 2>/dev/null)" in
    "$DEV"*) echo present; return ;;
    esac
  done
  echo absent
}

STATE=$(edl_state)
if [ "$STATE" != present ]; then
  say "zl1 one-boot runbook"
  say "  the device is NOT reachable: $STATE"
  case "$STATE" in
  edl)
    say
    say "  It is in Qualcomm EDL (05c6:9008 / QDL mode), which presents no serial number, so there is"
    say "  nothing here to address -- by design (doc 49 section 6), and no QDL/firehose tool may be run."
    say
    say "  THE NEXT MOVE IS PHYSICAL AND ONLY PHYSICAL:"
    say "      long-press POWER for 10-20 s, then wait for RNDIS (usb0) to come back."
    say "  Then run THIS script: it is the whole sequence, in the order that works, one command."
    ;;
  absent)
    say
    say "  No device with serial $DEV is on the bus. If it is connected, this is the OTHER phone"
    say "  (serial 4a2fe00b shares this bus and must be ignored) or the cable."
    ;;
  esac
  say
  say "  NOTHING WAS RUN and nothing was written. Exit 2."
  exit 2
fi

devssh true >/dev/null 2>&1; PROBE_RC=$?
if [ "$PROBE_RC" != 0 ]; then
  say "zl1 one-boot runbook"
  say "  the device is on the bus (serial $DEV) but SSH does not answer yet -- it may still be booting."
  # AND "DOES NOT ANSWER" IS NOT ONE THING. A refused connection, a timeout in the TCP handshake and a
  # HOST-SIDE bound killing a stalled session all land here, and the move to make is different for each:
  # the last one means the link stopped carrying traffic, which is the host-side stall that has its own
  # repair (docs 76) and does NOT need the phone touched.
  if gave_up "$PROBE_RC"; then
    say "  AND IT DID NOT ANSWER WITHIN ${STATE_LIMIT}s: the ssh was killed by this script's own bound"
    say "  (timeout(1) rc=$PROBE_RC). That is a statement about THIS HOST, not about the phone -- the"
    say "  device may be up and running with a link that stopped carrying traffic. That shape has a"
    say "  repair that needs no key press and no reboot:  sudo scripts/host/zl1-rndis-recover.sh"
  fi
  say "  Wait for RNDIS and for ssh, then run this again. NOTHING WAS RUN."
  say
  say "  If the link is up but carries no traffic, that is the OTHER known failure and it lives on the"
  say "  HOST (docs 76): scripts/host/zl1-rndis-recover.sh re-enumerates the gadget without a reboot."
  exit 2
fi

_bid=$(devssh 'cat /proc/sys/kernel/random/boot_id 2>/dev/null'); _brc=$?
BOOT_ID=$(printf '%s' "$_bid" | tr -d '\r\n')
# "The reading came back empty" and "the host gave up on the reading" are two different facts, and the
# archive's `boot_id:` line is how a later reader ties this directory to a boot -- so neither may be
# written as a blank. The old fallback printed `unknown-<timestamp>`, which reads as a boot id nobody
# could match; this says which of the two happened.
[ -n "$BOOT_ID" ] || { if gave_up "$_brc"; then BOOT_ID="UNREADABLE(host gave up at ${STATE_LIMIT}s)"; else BOOT_ID="UNREADABLE(empty answer)"; fi; }

# ==================================================================================================
# The device readings this runbook turns on. Each is a READING of the state a step is supposed to
# change, taken from the device and never inferred from the step's own exit code: an installer that
# exits 0 and a knob that moved are two different facts, and the whole point of ordering the sequence
# is that the second one is what the LAST step depends on.
# ==================================================================================================
# `download_mode` -- the trial's prerequisite A. It is a 0644 module parameter, so 0 means a panic
# reboots instead of arming EDL.
#
# EVERY match is read, and not the first one. The unit that arms this policy clears all of them and
# FAILS ITSELF if any did not clear (`install-no-edl-on-panic.sh`'s applier loops the same glob and sets
# `ok=0` on a value that is not 0), so a reader that stopped at the first match would answer a question
# about a different knob than the writer touches: it could print "A is MET" on a boot where the unit
# itself reports the guard is NOT armed. On the device as measured there is exactly one --
# `/sys/module/msm_poweroff/parameters/download_mode`, = 1 at boot (a real reading, twice:
# tmp-post-recovery-*/01-edl-postmortem.txt and docs 125) -- so this is about not being wrong if that
# ever stops being true. The glob (rather than the name) is kept for the same reason every other script
# here globs it, and the archived reading is what retires the older justification: `msm_poweroff` IS the
# name the guess named. See docs 125.
#
# The output is ONE token of its own shape, because the verdict below is a `case` on it:
#   all=0 (N parameter(s))                  every parameter reads 0 -> A is met
#   ARMED <path>=<value>[ <path>=<value>]   at least one does not    -> A is NOT met, and which
#   NOT-FOUND                               the driver's param is not exposed at all
#   TIMEOUT                                 the HOST gave up (see below) -- not a reading at all
read_download_mode() {
  local raw rc
  raw=$(devssh 'n=0; bad=""
    for p in /sys/module/*/parameters/download_mode; do
      [ -e "$p" ] || continue
      v=$(cat "$p" 2>/dev/null); n=$((n + 1))
      [ "$v" = 0 ] || bad="${bad}${bad:+ }${p}=${v:-<unreadable>}"
    done
    if [ "$n" = 0 ]; then printf "NOT-FOUND"; exit 0; fi
    if [ -n "$bad" ]; then printf "ARMED %s" "$bad"; exit 0; fi
    printf "all=0 (%s parameter(s))" "$n"' 2>/dev/null); rc=$?
  # THE FOURTH TOKEN EXISTS BECAUSE THE OTHER THREE ARE ALL CLAIMS ABOUT THE PHONE. "Not 0" and "not
  # found" are readings; "the host killed the ssh at 60 s" is not, and without this token it arrived at
  # the verdict below as an EMPTY STRING -- which fell into the last branch and was printed as "A is
  # treated as NOT met", i.e. a host-side timeout presented as a device verdict. (Same rule as the heat
  # chain's read-back: an empty value must not read as "the device said nothing".)
  gave_up "$rc" && { printf 'TIMEOUT'; return 0; }
  printf '%s' "$raw" | tr -d '\r\n'
}
# The debug keeper -- the trial's prerequisite C. Matched by ARGV, the same rule every other script here
# uses: a shell whose command line merely MENTIONS the keeper's path is not the keeper.
read_keeper() {
  local raw rc
  raw=$(devssh 'n=0; for d in /proc/[0-9]*; do
      [ -d "$d" ] || continue
      p=${d#/proc/}; [ "$p" = "$$" ] && continue
      set -- $(tr "\000" "\n" < "$d/cmdline" 2>/dev/null)
      a0=${1:-}; a1=${2:-}; hit=0
      case "$a1" in */zl1-debug-net.sh) hit=1 ;; esac
      if [ "$hit" = 0 ]; then
        case "$a0" in
        */zl1-debug-net.sh) hit=1 ;;
        */sh|*/dash|*/bash|*/busybox|sh|dash|bash|busybox) case "$a1" in */zl1-debug-net.sh) hit=1 ;; esac ;;
        esac
      fi
      [ "$hit" = 1 ] && { n=$((n + 1)); printf "%s " "$p"; }
    done; [ "$n" = 0 ] && printf "none"; printf "(%s)" "$n"' 2>/dev/null); rc=$?
  # And the same fourth token, and here it matters more than anywhere else in this file: `none*` is the
  # ONLY branch that says C is MET, so a host-side timeout arriving as an empty string fell into the last
  # branch and was printed as "C is NOT met (step 03 retires it)" -- an instruction to re-run a step that
  # may have already worked, on the strength of a reading that never happened.
  gave_up "$rc" && { printf 'TIMEOUT'; return 0; }
  printf '%s' "$raw" | tr -d '\r\n'
}

# ==================================================================================================
# The archive. The same shape and the same reasons as the capture's: this is the record of a boot that
# cannot be revisited, and a record nobody can check the integrity of is a liability the next time
# somebody asks "did that really say that".
# ==================================================================================================
PASS=0; FAIL=0; declare -a STEP_NAMES=() STEP_RC=() STEP_NOTE=()
# Did the panic guard actually run IN THIS INVOCATION? The trial's write needs it, and "it was not
# skipped" is not the same question as "it ran": under `--only 05-trial` nothing armed it either, and
# that is the same hazard with a different spelling.
A_ARMED=0
INTERRUPTED=0; ARCHIVED=0

archive() {
  [ "$ARCHIVED" = 1 ] && return 0
  ARCHIVED=1
  {
    printf '# zl1 one-boot runbook\n'
    printf 'boot_id: %s\n' "$BOOT_ID"
    printf 'device: %s (serial %s)\n' "$HOST" "$DEV"
    printf 'ran: %s   mode: %s   apply_trial: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MODE" "$APPLY_TRIAL"
    # The bound each step got, with the arithmetic it came from. A `124` in the rc column is only readable
    # next to the number that produced it -- and for the two archiving steps that number is not the flag on
    # the command line, it is the callee's own worst case.
    printf 'bound per step: 02/04/05 = %ss (--step-limit)\n' "$STEP_LIMIT"
    printf '                01-capture = %ss  %s\n' "$(step_bound 01-capture)" "${CAP_WHY:-NOT COVERED: the callee shape could not be read, so this is the flat bound}"
    printf '              03-heat-chain = %ss  %s\n' "$(step_bound 03-heat-chain)" "${CHAIN_WHY:-NOT COVERED: the callee shape could not be read, so this is the flat bound}"
    [ -n "$ONLY" ] && printf 'only: %s\n' "$ONLY"
    [ -n "$SKIP" ] && printf 'skip: %s\n' "$SKIP"
    [ "$INTERRUPTED" = 1 ] && printf 'INTERRUPTED: yes -- the steps below are all that ran\n'
    printf '\n# step                 rc   what the device said afterwards\n'
    i=0
    while [ "$i" -lt "${#STEP_NAMES[@]}" ]; do
      # `:-` on EVERY array read, because this function is also the signal handler and a signal can
      # arrive between `STEP_RC+=(...)` and `STEP_NOTE+=(...)` -- i.e. in the middle of a step. Plain
      # `${STEP_NOTE[$i]}` then aborts the whole function under `set -u`, which is exactly the loss the
      # handler exists to prevent (the capture's handler died that way once; docs 108).
      printf '%-20s %3s   %s\n' "${STEP_NAMES[$i]:-?}" "${STEP_RC[$i]:-?}" "${STEP_NOTE[$i]:-(the interrupt landed here)}"
      i=$((i + 1))
    done
    printf '\n# 01 and 05 read; 02, 03 and 04 write, each with its own refusals and read-back.\n'
    printf '# 05 writes ONLY with --apply-trial.\n'
    # A bare `124` in the rc column reads as "the step said 124", which is not what happened. The steps
    # that ran out of time are named, in the archive, next to what the codes mean (the same rule the heat
    # chain's INDEX.txt follows -- docs 131).
    [ -n "${TIMED_OUT_STEPS:-}" ] && printf '\n# DID NOT FINISH: rc=124 is timeout(1), 137 its -k SIGKILL -- the host gave up at that step'\''s own\n# bound, which is the number in the table above and is NOT always --step-limit.\n# Neither a failure of the step nor a success, and NOTHING here read the device after it started:%s\n' "$TIMED_OUT_STEPS"
  } > "$OUT/INDEX.txt"
  ( cd "$OUT" && sha256sum ./*.txt 2>/dev/null > SHA256SUMS )
}
# The handler writes to fd 9, not stdout: a signal arrives while a step is running, and a step's output
# file is open -- a message there would land inside the interrupted step AND change the file after
# `archive` hashed it, which makes the partial archive fail its own `sha256sum -c`. Both were observed
# in the capture; the harness's `sha256sum -c` is what caught the second one.
RB_PID=""
on_signal() {
  INTERRUPTED=1
  if [ -n "$RB_PID" ]; then
    kill -TERM "$RB_PID" 2>/dev/null; sleep 1; kill -9 "$RB_PID" 2>/dev/null; wait "$RB_PID" 2>/dev/null
  fi
  archive
  printf '\nINTERRUPTED: archived what had run into %s\n' "$OUT" >&9
  exit 3
}
exec 9>&1
trap on_signal INT TERM HUP

# Every long call goes through this. bash runs a trap for a signal only after the FOREGROUND command
# finishes, and at once when the signal arrives during `wait` -- measured in the capture at +20.0 s
# foreground against +2.0 s under `wait`. The heat chain waits 90 s through this very path.
RB_RC=0
# `return "$RB_RC"` and NOT a bare trailing assignment: a function returns the status of its last
# command, and an assignment is always 0 -- so a caller that read `$?` after this got 0 for every step.
# The trial's step did exactly that, which meant the trial's own exit code (REFUTED vs REFUSED vs a
# failed write) was never reported at all. Found by the harness driving FP_RC_TRIAL.
#
# And every step is bounded in wall-clock time (see STEP_LIMIT above). The bound is applied HERE rather
# than inside `bound() &` because the background pid has to be `timeout`'s own: the signal handler kills
# that pid, and a wrapper function's pid would leave the timeout and the device call orphaned -- the
# interrupt path would report "stopped" while the step kept running.
#
# The bound is a LEADING ARGUMENT and not a global. It has to differ per step -- the two archiving steps
# carry a bound computed from the callee they wrap, the other three a flat one -- and a global holding the
# previous step's number is the shape this tree keeps recording (a variable outliving the call that set
# it, and /bin/sh having no locals). Nothing here is inherited: a caller that wants the flat bound simply
# does not pass --bound.
run_bg() {
  local lim="$STEP_LIMIT"
  if [ "${1:-}" = --bound ]; then lim="${2?--bound needs SECONDS}"; shift 2; fi
  if [ "$HAVE_TIMEOUT" = 1 ]; then
    timeout -k 5 "$lim" "$@" &
  else
    # Loud, and into the STEP's own file (run_step redirects both streams): an unbounded step is the
    # difference between "it failed" and "it could have hung forever and nobody would know".
    printf 'NOTE: no timeout(1) on this host -- THIS STEP IS NOT TIME-BOUNDED (the limit would have been %ss)\n' "$lim" >&2
    "$@" &
  fi
  RB_PID=$!; wait "$RB_PID"; RB_RC=$?; RB_PID=""; return "$RB_RC"
}

# --- the plan --------------------------------------------------------------------------------------
wanted() { # is this step in the set this run will execute?
  [ -n "$ONLY" ] && [ "$ONLY" != "$1" ] && return 1
  skipped "$1" && return 1
  return 0
}

# --- the HOST's read on whether step 03 can run at all ---------------------------------------------
#
# Section 0 answers "is there a device". This answers the other half, and it is the half this script was
# missing: **is there still a host?** Step 03 is the heat chain, and its FIRST move is
# `install-netwatch-service.sh --yes --ssh`, which refuses BY NAME unless it has a verified misc backup
# (`misc.img` non-empty, a `SHA256SUMS` beside it, and that hash still matching) and a source build that
# carries `ensure_addrs()`. Those are files on THIS machine, on a path that nothing in this runbook
# touches -- so a missing or stale one is invisible until step 03 refuses, and by then 01 and 02 have
# already run: the boot is half spent and the heat half is gone, on a boot that a finger paid for.
#
# **It is a reading, not an assumption.** The paths and the `ensure_addrs()` rule are READ OUT OF THE
# INSTALLER (`install-netwatch-service.sh`) rather than repeated here, because a second copy of a path
# is a second thing that can go stale -- that is docs 126's lesson one file over. If the extraction finds
# nothing, that is REPORTED as an unusable check, never as a pass: an extractor that silently matches
# nothing is the "check that cannot fail" shape this tree keeps finding.
HOST_MISC_IMG=""; HOST_MISC_SUMS=""
NW="$HERE/../install-netwatch-service.sh"
if [ -r "$NW" ]; then
  HOST_MISC_OUT=$(sed -n 's/^MISC_OUT="\(.*\)"$/\1/p' "$NW" | head -1)
  # MISC_IMG is written in the installer as `"$MISC_OUT/misc.img"`, so the FILE TEXT is not a path -- it
  # is a path EXPRESSION, and the first version of this read it back verbatim and got the literal
  # `$MISC_OUT/misc.img`. (Measured, by running that sed against the real installer.) So the two halves
  # are read separately and the FORM is required: directory from MISC_OUT, basename from the part of
  # MISC_IMG after `$MISC_OUT/`. A different form matches nothing and is reported below as an unusable
  # check rather than passed.
  _img=$(sed -n 's|^MISC_IMG="\$MISC_OUT/\(.*\)"$|\1|p' "$NW" | head -1)
  HOST_MISC_IMG=$([ -n "$_img" ] && [ -n "$HOST_MISC_OUT" ] && echo "$HOST_MISC_OUT/$_img")
  HOST_MISC_SUMS=$([ -n "$HOST_MISC_OUT" ] && echo "$HOST_MISC_OUT/SHA256SUMS")
  HOST_NW_SRC=$(sed -n 's/^SRC="\(.*\)"$/\1/p' "$NW" | head -1)
fi
# Returns 0 when step 03 can start; otherwise it prints the reasons, one per line.
host_for_step03() {
  local bad=0
  if [ ! -r "$NW" ]; then
    echo "cannot read $NW, so the preconditions of step 03 cannot be read either"
    return 1
  fi
  if [ -z "$HOST_MISC_IMG" ] || [ -z "$HOST_MISC_SUMS" ]; then
    echo "the misc-backup paths could not be read out of $NW (the MISC_OUT/MISC_IMG form it uses is not the one this reads)"
    bad=1
  else
    [ -s "$HOST_MISC_IMG" ] || { echo "the misc backup step 03 requires is missing or empty: $HOST_MISC_IMG"; bad=1; }
    if [ -z "$HOST_MISC_SUMS" ] || [ ! -f "$HOST_MISC_SUMS" ]; then
      echo "no SHA256SUMS beside it, so the backup cannot be shown to be the image it claims to be: $HOST_MISC_SUMS"
      bad=1
    elif [ -s "$HOST_MISC_IMG" ]; then
      ( cd "$(dirname "$HOST_MISC_IMG")" && sha256sum -c "$(basename "$HOST_MISC_SUMS")" >/dev/null 2>&1 ) \
        || { echo "the misc backup FAILS its recorded SHA256: $HOST_MISC_IMG (not the image it claims to be)"; bad=1; }
    fi
  fi
  if [ -z "${HOST_NW_SRC:-}" ]; then
    echo "the netwatch source path could not be read out of $NW"
    bad=1
  elif [ ! -r "$HOST_NW_SRC" ]; then
    echo "the netwatch build step 03 deploys is missing: $HOST_NW_SRC"
    bad=1
  elif ! grep -q '^ensure_addrs()' "$HOST_NW_SRC"; then
    echo "$HOST_NW_SRC has no ensure_addrs(), so deploying it would change nothing and 03 would refuse: $HOST_NW_SRC"
    bad=1
  fi
  [ "$bad" = 0 ]
}

# --- the WHOLE sequence's host readiness, not just step 03's ---------------------------------------
#
# `host_for_step03` answers a question about ONE step, and it was written for the argument that applies
# to all five: discovering on the boot that a file on THIS machine is missing costs the boot, and the
# boot is the one thing here that cannot be re-run. But steps 01, 02, 04 and 05 need host files just as
# much -- their own scripts -- and so does step 03's OWN body, which drives four more scripts the
# runbook never looks at (`install-retire-debug-keeper.sh`, `install-cpufreq-governor.sh`,
# `device/zl1-address-owner-proof.sh`, and `device/zl1-thermal.sh`). A missing capture script is found
# at 01, a missing trial at 05, and a missing thermal instrument is found at NO step at all: the chain
# degrades to `unusable`, prints that in the archive, and the boot ends with no measurement and no
# second chance.
#
# TWO KINDS, AND THE DIFFERENCE IS NOT COSMETIC. A missing SCRIPT means a step cannot run: that is a
# refusal, because a refusal costs nothing and a half-spent boot costs a finger. A missing INSTRUMENT
# means the step runs and the measurement is lost -- and refusing on that would throw away the whole
# heat fix (two installers that would have worked, plus the keeper kill) to protect a smaller loss than
# the one the refusal causes. So it is reported as a WARNING that names exactly what will be lost, the
# run proceeds, and the archive says `unusable` when it happens. That is docs 118's rule one file over:
# the licence step 4 gives is for the kill, and over-gating loses a set of steps that never needed it.
#
# WHICH IS WHICH IS READ OUT OF THE HEAT CHAIN, not decided here: the chain has its own readability loop
# (`for f in "$NW" "$RETIRE" "$CPUFREQ" "$PROOF"`) and the names in it are the ones it refuses on. Any
# other callee it defines is one it degrades on. A second copy of that policy here would be a second
# thing to go stale (docs 126), and if the extraction matches nothing the check reports itself UNUSABLE
# rather than passing -- the shape this tree keeps finding in checks that cannot fail.
CHAIN_CALLEES=""        # "NAME relative/path" per line, read out of the chain
CHAIN_HARD=""           # the names the chain itself refuses on
if [ -r "$HEAT" ]; then
  # `NAME="$HERE/../somewhere"`, and **$HERE means the CHAIN's directory, not this script's**: the two
  # happen to be the same directory in the real tree, and resolving with this script's $HERE would then be
  # right by accident -- which is exactly the kind of accident a fixture that puts them in different
  # directories catches. (It did: the first version resolved the chain's `../install-retire-...` against
  # the runbook's directory and refused for a file that was there all along, one directory over.)
  CHAIN_CALLEES=$(sed -n 's|^\([A-Z_][A-Z_0-9]*\)="\$HERE/\(.*\)"$|\1 \2|p' "$HEAT")
  # The names in the chain's own refusal loop, on ONE line: `for f in "$NW" "$RETIRE" ...; do`.
  CHAIN_HARD=$(sed -n '/^for f in /{s/^for f in //; s/; do.*//; s/"//g; s/\$//g; p; q;}' "$HEAT")
fi

# --- the two ARCHIVING callees' own worst cases, READ OUT OF THE CALLEES ---------------------------
#
# The header states the requirement ("it has to be looser than the heat chain's own total") and nothing
# measured it. It was written when the capture had SIX device steps; it has NINETEEN now (docs 157 added 04o), because every
# gap-closing stage since docs 138 added one, and no one re-read a number on another file. Measured:
#
#   capture  19 device steps, each bounded on the DEVICE at STEP_LIMIT 240 -> 19 x 245 + 120 = 4775 s
#   chain    settle 90 + 5 step sites x 305 + 2 bounded scps x 305 + the proof 180 + the A/B 240
#            + 4 read-backs x 65 + slack = 3145 s
#   runbook  one timeout(1) of 900 s over the WHOLE of either invocation -> 5.3x and 3.5x over
#
# and the consequence is not a failure, which is what makes it dangerous: a step inside either callee that
# HANGS is handled by the callee itself (it records it and moves on), so 900 s buys only the first three
# or four of the capture's nineteen readings and then SIGKILLs the rest -- including 04-health-check and
# the whole 04b..04o probe group -- on a boot that cost a finger and cannot be re-run.
#
# So the bound for these two steps is COMPUTED, from the callee's own numbers, the same way step 03's host
# preconditions are read out of the chain: a second copy of the arithmetic here would be a second thing to
# go stale. Every term is COUNTED FROM THE CALLEE'S SOURCE, and every count is taken the CONSERVATIVE way
# -- call sites rather than the invocations a given path takes, and the two steps the capture skips by
# default included anyway. Too loose costs elapsed time on a boot that is already spent; too tight costs
# the boot. `--step-limit` stays the FLOOR and the value for the other three steps, so an operator who
# raises it still gets a bigger bound -- but nothing can quietly make one of these two TIGHTER than the
# callee it wraps.
#
# Both directions of failure are loud. If a shape cannot be read, the step keeps the flat bound AND says
# so; that is NOT a pass, because the check that would have made it safe did not happen. The extractor
# reads the number out of a `NAME=` line, which is only sound while those lines keep their form, so the
# harness pins BOTH forms against the real files rather than trusting this comment.
CAP_BOUND=""; CAP_WHY=""
CHAIN_BOUND=""; CHAIN_WHY=""
_num() { # VARNAME, file -> the number the first `VARNAME=` line gives, or nothing
  # TWO FORMS, and neither is the other's superset: `SETTLE=90` and `STEP_LIMIT=240` are bare, while the
  # chain writes `STEP_LIMIT=${ZL1_STEP_LIMIT:-300}` -- so the number the script will USE is the part
  # after `:-`. The first version took the first run of digits on the line, which read `ZL1_STEP_LIMIT`
  # as `1`: a 1-second bound, out of a variable NAME. Both forms are pinned against the real files.
  grep -m1 "^$1=" "$2" 2>/dev/null \
    | sed -n -e 's/.*:-\([0-9][0-9]*\)}.*/\1/p' -e 's/^[^=]*=\([0-9][0-9]*\)$/\1/p' \
    | sed -n '1p'
}
_cap_shape() { # -> "DEVICE_STEPS PER_STEP_SECONDS"; non-zero when either cannot be read
  local n lim
  n=$(grep -cE '^ *step [0-9a-z-]+ +device ' "$CAP" 2>/dev/null)
  lim=$(_num STEP_LIMIT "$CAP")
  case "$n"   in ''|0|*[!0-9]*) return 1 ;; esac
  case "$lim" in ''|0|*[!0-9]*) return 1 ;; esac
  printf '%s %s\n' "$n" "$lim"
}
_chain_shape() { # -> "STEPS SCP_SITES PER_STEP SETTLE AB_WINDOW AB_HOLD STATE_LIMIT READBACKS PROOF_DEV"
  local n sc lim st w h sl rs pd
  n=$(grep -cE '^ *step [0-9]' "$HEAT" 2>/dev/null)
  # The host-bounded scp sites: the A/B's instrument and the proof's own script. Counted, not remembered
  # -- the proof's was NOT bounded until this change, and that is the same defect as this one, one file
  # over. `if ` is allowed in front because the proof's is the condition of an `if`.
  sc=$(grep -cE '(^|if ) *(bound "\$STEP_LIMIT" "\$\{SCP\[@\]\}")' "$HEAT" 2>/dev/null)
  rs=$(grep -cE '^ *read_state$' "$HEAT" 2>/dev/null)
  lim=$(_num STEP_LIMIT "$HEAT")
  st=$(_num SETTLE "$HEAT")
  w=$(_num AB_WINDOW "$HEAT")
  h=$(_num AB_HOLD "$HEAT")
  sl=$(_num STATE_LIMIT "$HEAT")
  pd=$(_num PROOF_DEV_LIMIT "$HEAT")
  for v in "$n" "$sc" "$rs" "$lim" "$st" "$w" "$h" "$sl" "$pd"; do
    case "$v" in ''|*[!0-9]*) return 1 ;; esac
  done
  printf '%s %s %s %s %s %s %s %s %s\n' "$n" "$sc" "$lim" "$st" "$w" "$h" "$sl" "$rs" "$pd"
}
if [ -r "$CAP" ]; then
  _s=$(_cap_shape)
  if [ $? -eq 0 ]; then
    _n=${_s%% *}; _l=${_s##* }
    # Each device step is bounded ON THE DEVICE with `-k 5`, so its own worst case is LIM+5; the identity
    # block, the archive and the three HOST steps ride in the slack. CONSERVATIVE ON PURPOSE: the two
    # probe steps the capture skips by default are counted anyway, because too loose costs elapsed time
    # and too tight costs the boot.
    CAP_BOUND=$(( _n * (_l + 5) + 120 ))
    CAP_WHY="$_n device steps x ($_l+5) + 120 of slack"
  fi
fi
if [ -r "$HEAT" ]; then
  _s=$(_chain_shape)
  if [ $? -eq 0 ]; then
    # A here-document rather than `set --`: this script's positional parameters are its ARGUMENTS, and
    # clobbering them to unpack a string is how a later `$1` quietly becomes something else.
    read -r _n _sc _l _st _w _h _sl _rs _pd <<EOF
$_s
EOF
    # The terms, in the order the chain runs them: the settle; EVERY `step` call site at its own bound (a
    # single path takes four of the five, and the sites are counted, which is the conservative side); the
    # two host-bounded scps; the proof's ssh (device-side plus one read-back of link slack); the A/B's
    # measurement at the SAME computed bound the chain itself uses (2 x window + hold + 60); and every
    # read-back site. A new call site anywhere in the chain grows this, because it is counted and not
    # listed. The 240 at the end is the slack for what is left: the two archives, the identity write, and
    # the SHA256SUMS.
    CHAIN_BOUND=$(( _st + (_n + _sc) * (_l + 5) + (_pd + _sl) + (_w * 2 + _h + 60) + _rs * (_sl + 5) + 240 ))
    CHAIN_WHY="settle $_st + ($_n step sites + $_sc bounded scps) x ($_l+5) + proof ($_pd+$_sl) + A/B (2x$_w+$_h+60) + $_rs read-backs x ($_sl+5) + 240 of slack"
  fi
fi

# Which bound a step gets. `max(flat, computed)`: the computed number is the callee's own worst case, so
# it can only ever LOOSEN a step -- nothing here can quietly make one of the two archiving steps tighter
# than the callee it wraps, which is the defect this whole block exists to close. A step with no computed
# shape (02, 04, 05 -- each one installer invocation) gets the flat bound unchanged.
#
# DEFINED HERE, next to the numbers it reads, and NOT beside run_step() further down: `--status` prints
# these bounds too and exits before reaching that point, so the first version called an undefined function
# and every `--status` scenario lost its output from there on. Found by the harness, which is the reason
# it asserts on --status at all.
step_bound() { # name -> SECONDS on stdout
  case "$1" in
  01-capture)    if [ -n "$CAP_BOUND" ] && [ "$CAP_BOUND" -gt "$STEP_LIMIT" ]; then printf '%s' "$CAP_BOUND"; return; fi ;;
  03-heat-chain) if [ -n "$CHAIN_BOUND" ] && [ "$CHAIN_BOUND" -gt "$STEP_LIMIT" ]; then printf '%s' "$CHAIN_BOUND"; return; fi ;;
  esac
  printf '%s' "$STEP_LIMIT"
}
# The three states a step's bound can be in, printed as ONE line so the number is never left to be
# inferred: the shape was read and it wins; the shape was read and the floor is higher (so the floor is
# what applies -- and saying which is the difference between "covered" and "covered by accident"); or the
# shape could not be read at all, which is NOT a pass.
step_bound_line() { # name -> one line for --status
  local comp="" why="" flat="$STEP_LIMIT" eff
  case "$1" in
  01-capture)    comp="$CAP_BOUND";   why="$CAP_WHY" ;;
  03-heat-chain) comp="$CHAIN_BOUND"; why="$CHAIN_WHY" ;;
  esac
  eff=$(step_bound "$1")
  if [ -z "$comp" ]; then
    printf '%ss   THE CALLEE SHAPE COULD NOT BE READ -- this is the flat --step-limit, and the step is NOT covered' "$eff"
  elif [ "$comp" -gt "$flat" ]; then
    printf '%ss   computed from the callee: %s' "$eff" "$why"
  else
    printf '%ss   the callee computes to %ss (%s), under the flat floor, so the floor is what applies' "$eff" "$comp" "$why"
  fi
}

# The chain writes its callees as `$HERE/../install-*.sh`, so the resolved path has a `..` in it. A
# message somebody reads at 2 a.m. should not make them resolve that in their head, and a check that
# asserts the path should assert the file, not the journey to it. Resolved textually as far as it can be:
# if the parent does not exist the original is returned, because then the path IS the finding.
_abs() { # path
  local d b
  d=$(dirname "$1"); b=$(basename "$1")
  if [ -d "$d" ]; then ( cd "$d" 2>/dev/null && printf '%s/%s' "$(pwd)" "$b" ); else printf '%s' "$1"; fi
}
# Returns 0 when the sequence can start. One reason per line, PREFIXED, so the caller cannot confuse the
# two kinds -- the whole point of the function is that they are not the same.
host_ready() {
  local bad=0 step path name rel
  # (a) each step's own script. Skipped steps are not checked: a step this run will not take cannot fail,
  #     and refusing on it would make `--skip` unusable on exactly the host where it is the way through.
  while read -r step path; do
    [ -n "$step" ] || continue
    wanted "$step" || continue
    [ -r "$path" ] || { echo "HARD $step cannot start: its own script is not readable: $path"; bad=1; }
  done <<EOF
01-capture $CAP
02-panic-guard $PANIC
03-heat-chain $HEAT
04-fingerprint $FP
05-trial $TRIAL
EOF
  if wanted 03-heat-chain; then
    # (b) what step 03's own body will drive. Read out of the chain above.
    if [ -z "$CHAIN_CALLEES" ] || [ -z "$CHAIN_HARD" ]; then
      # NOT a pass. An extractor that matched nothing leaves both sides empty, and "nothing to check"
      # would read exactly like "everything is there" -- the check-that-cannot-fail shape.
      echo "UNUSABLE the heat chain's callees could not be read out of $HEAT, so whether step 03 can start is UNKNOWN (not a pass)"
      bad=1
    else
      CHAIN_DIR=$(dirname "$HEAT")
      while read -r name rel; do
        [ -n "$name" ] || continue
        path=$(_abs "$CHAIN_DIR/$(printf '%s' "$rel")")
        if ! printf '%s\n' "$CHAIN_HARD" | grep -qw "$name"; then
          # The chain runs without this one -- it says so in the archive instead. Warn, never refuse.
          [ -r "$path" ] || echo "SOFT 03-heat-chain will run but its MEASUREMENT WILL NOT: $name ($path) is not readable, so the chain will report the A/B as unusable -- the two heat fixes still install"
          continue
        fi
        [ -r "$path" ] || { echo "HARD 03-heat-chain cannot start: $name is not readable: $path"; bad=1; }
      done <<EOF
$CHAIN_CALLEES
EOF
    fi
    # (c) and the two conditions the chain's own FIRST move refuses on, read out of the installer.
    while IFS= read -r r; do
      [ -n "$r" ] && { echo "HARD $r"; bad=1; }
    done <<EOF2
$(host_for_step03)
EOF2
  fi
  # (d) the two COMPUTED bounds. A shape that could not be read is not a pass: the step will still run,
  #     on the flat --step-limit, which is the number measured to be too tight for both of these callees.
  #     It is not a refusal either -- a bound that is too loose costs elapsed time and nothing else, and
  #     refusing here would throw the whole boot away to protect a smaller loss than the refusal causes
  #     (the same rule as the HARD/SOFT split above). What must not happen is silence.
  wanted 01-capture && [ -z "$CAP_BOUND" ] && echo "UNUSABLE 01-capture's own worst case could not be read out of $CAP, so its bound is the flat ${STEP_LIMIT}s -- if that callee runs more device steps than that covers, this run can cut it off mid-flight and lose the rest of the boot's readings"
  wanted 03-heat-chain && [ -z "$CHAIN_BOUND" ] && echo "UNUSABLE 03-heat-chain's own worst case could not be read out of $HEAT, so its bound is the flat ${STEP_LIMIT}s -- if the chain's own total is larger than that, this run can cut it off mid-flight"
  [ "$bad" = 0 ]
}

# --- --status: the plan AND the live state of the three prerequisites ------------------------------
# Read-only, and it answers the one question a person with a booted phone actually has: what is left to
# do on THIS boot? An installer already installed reads as installed, so re-running the sequence is
# safe and this is how you tell that it is safe.
if [ "$MODE" = status ]; then
  say "zl1 one-boot runbook -- STATUS (read-only; nothing is written and nothing is installed)"
  say "  device:  $HOST (serial $DEV)"
  say "  boot_id: $BOOT_ID"
  say
  say "the sequence, in the only order that works:"
  say "  01-capture       read-only   three readings stop existing later in this same boot"
  say "  02-panic-guard   WRITES      the one step that outlasts the boot; arms A for step 05"
  say "  03-heat-chain    WRITES      retires the keeper, which arms C for step 05"
  say "  04-fingerprint   WRITES      a directory + a unit; its verdict is a log count"
  say "  05-trial         reads       last, because only here can A and C both be true"
  say
  say "the bound each step gets (this is the number that decides whether a step is cut off mid-flight):"
  say "  01-capture     $(step_bound_line 01-capture)"
  say "  02/04/05       ${STEP_LIMIT}s   flat (--step-limit); each is one installer invocation, with no"
  say "                            callee of its own to read a shape out of"
  say "  03-heat-chain  $(step_bound_line 03-heat-chain)"
  say "  a step that outlasts its bound is DID NOT FINISH -- not a failure, and not a success"
  say
  say "the trial's two hard prerequisites, as the DEVICE reads them right now:"
  DM=$(read_download_mode)
  KP=$(read_keeper)
  # The `case` is on the reader's own token, and there is deliberately NO fall-through that could read a
  # near-miss as a pass. Both earlier spellings here were wrong in the same way (`0*`, then `*=0`: the
  # value position), and this file has already been bitten twice by a reading whose shape the verdict
  # assumed rather than checked. So the only branch that says MET is the one the reader prints when every
  # parameter reads 0.
  case "$DM" in
  all=0*) say "  A. download_mode: $DM   <- every parameter reads 0: a panic will NOT arm EDL (prerequisite A is MET)";;
  NOT-FOUND) say "  A. download_mode: NOT FOUND under /sys/module/*/parameters/ -- A cannot be checked, so it is NOT met";;
  ARMED*) say "  A. download_mode: $DM   <- a panic WOULD arm EDL (A is NOT met; step 02 is what fixes it)";;
  TIMEOUT) say "  A. download_mode: NOT READ -- the host gave up on the ssh at ${STATE_LIMIT}s, so this says";
    say "     NOTHING about the phone: the parameter may read 0 and it may not. Treat it as not met for";
    say "     step 05 (which will refuse), but the thing to fix is the LINK, not the driver: docs 76.";;
  *) say "  A. download_mode: $DM   <- the reading is not a shape this script knows, so A is treated as NOT met";;
  esac
  case "$KP" in
  none*) say "  C. debug keeper: none -- C is MET";;
  TIMEOUT) say "  C. debug keeper: NOT READ -- the host gave up on the ssh at ${STATE_LIMIT}s. This is not";
    say "     'no keeper': nothing here says whether one is running, and step 03 may well have worked.";;
  *) say "  C. debug keeper: $KP   <- a CPU that is never idle does not enter a deep idle state, so C is NOT met (step 03 retires it)";;
  esac
  say "  B. cpuidle counters: not checked here -- the trial reads them itself, and UNREADABLE IS NOT ZERO."
  say
  HOST_BAD=$(host_ready)
  CASE_HARD=$(printf '%s\n' "$HOST_BAD" | grep '^HARD ' || true)
  CASE_SOFT=$(printf '%s\n' "$HOST_BAD" | grep '^SOFT ' || true)
  CASE_UNK=$(printf '%s\n' "$HOST_BAD" | grep '^UNUSABLE ' || true)
  if [ -z "$CASE_HARD$CASE_SOFT$CASE_UNK" ]; then
    say "  host: every step this run would take can start from this machine"
  else
    [ -n "$CASE_HARD" ] && { say "  host: the run WILL REFUSE before step 01 -- these cannot start:"; \
      printf '%s\n' "$CASE_HARD" | sed 's/^HARD /        * /'; }
    [ -n "$CASE_UNK" ] && { say "  host: a check could not be made, which is NOT a pass:"; \
      printf '%s\n' "$CASE_UNK" | sed 's/^UNUSABLE /        * /'; }
    [ -n "$CASE_SOFT" ] && { say "  host: WARNINGS -- the run proceeds, and something will be missing:"; \
      printf '%s\n' "$CASE_SOFT" | sed 's/^SOFT /        * /'; }
  fi
  say
  say "  Nothing was written. To run it:   $0 --yes"
  say "  To also run the trial's write:   $0 --yes --apply-trial   (a decision, not a reading)"
  exit 0
fi

# ==================================================================================================
# The run
# ==================================================================================================
[ -n "$OUT" ] || OUT="$REPO/tmp-one-boot-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT" || { echo "cannot create $OUT" >&2; exit 2; }
OUT=$(cd "$OUT" && pwd)

say "zl1 one-boot runbook"
say "  device:  $HOST (serial $DEV)"
say "  boot_id: $BOOT_ID"
say "  outdir:  $OUT"
say

# The host's own precondition, checked BEFORE step 01 -- see host_ready(). Refusing here costs nothing;
# refusing at the step that needs the file costs every step before it, and the boot.
HOST_BAD=$(host_ready)
HOST_HARD=$(printf '%s\n' "$HOST_BAD" | grep '^HARD ' || true)
HOST_SOFT=$(printf '%s\n' "$HOST_BAD" | grep '^SOFT ' || true)
HOST_UNK=$(printf '%s\n' "$HOST_BAD" | grep '^UNUSABLE ' || true)
if [ -n "$HOST_UNK" ]; then
  # A check that could not be made is NOT a pass, and it is not a refusal either: the operator is told
  # that this run's host check has a hole in it and then chooses. What must not happen is silence.
  say "NOTE: part of the host check could not be made -- this run is NOT verified against it:"
  printf '%s\n' "$HOST_UNK" | sed 's/^UNUSABLE /  * /'
  say
fi
if [ -n "$HOST_HARD" ]; then
  say "REFUSING, before anything ran: a step of this run cannot start on THIS HOST."
  printf '%s\n' "$HOST_HARD" | sed 's/^HARD /  * /'
  say
  say "  Nothing was run and nothing was written. This is not a device problem, and the boot is"
  say "  untouched -- fix the host, or leave that step out and run the rest:"
  say "      $0 --yes --skip <the step named above>"
  exit 2
fi
if [ -n "$HOST_SOFT" ]; then
  # NOT a refusal, and the reason is on the line: refusing would cost the whole boot's heat fix to
  # protect a smaller loss than the refusal causes (see host_ready).
  say "WARNING: the run will proceed, and this is what it will not be able to do:"
  printf '%s\n' "$HOST_SOFT" | sed 's/^SOFT /  * /'
  say
fi
say "-- host check: every step this run takes can start from this machine"

# One step = one archive entry + one note that is a DEVICE READING, not the step's exit code. It also
# records the step in EXECUTION ORDER, which is checked against STEPS at the end -- see the note there.
# ONE place decides what a step's rc means for the record, so the five steps cannot disagree about it --
# and so the bound added above is explained in all five without five copies of the sentence. 124 is
# timeout(1)'s own code and 137 is its -k SIGKILL: the step DID NOT FINISH, which is a different claim
# about the device from "the step failed". It is counted apart from FAIL (see the totals below) because
# a run that stopped one step short is not the same reading as a run whose step said no.
N_TIMED_OUT=0; TIMED_OUT_STEPS=""
step_done() { # name, rc, note
  local rc="$2" nt="$3"
  case "$rc" in
  124|137)
    N_TIMED_OUT=$((N_TIMED_OUT + 1)); TIMED_OUT_STEPS="$TIMED_OUT_STEPS $1"
    # THE STEP'S OWN BOUND, not the flat flag: for 01 and 03 the two are different numbers, and a report
    # that names the wrong one sends the reader to the wrong line. `step_bound` is the single place that
    # decides it, which is also the single place that could get it wrong.
    local b; b=$(step_bound "$1")
    nt="$nt -- DID NOT FINISH: the host gave up at ${b}s (timeout(1) rc=$rc). That is not a failure of the step and not a reading of the device: whatever it was doing may be half-done ON THE PHONE, and nothing here read the state after it."
    say "   -> DID NOT FINISH: killed at ${b}s (rc=$rc, timeout(1)). This is NOT a failure of the"
    say "      step and NOT a success. Its output so far is $1.txt; anything it was writing may be half-done." ;;
  esac
  STEP_NAMES+=("$1"); STEP_RC+=("$rc"); STEP_NOTE+=("$nt")
  # EXECUTED is the steps that RAN, so a `skip` row is recorded in the archive and NOT in this list --
  # see the plan check at the end of this file for what comparing the wrong two lists cost.
  case "$rc" in skip) ;; *) EXECUTED+=("$1") ;; esac
}
declare -a EXECUTED=()
run_step() { # name, human sentence, command...
  local name="$1" why="$2"; shift 2
  say "-- $name"
  note "$why"
  local b; b=$(step_bound "$name")
  # Printed, not inferred: this is the number that decides whether the step is cut off mid-flight, and the
  # derivation is on the same line as it.
  case "$name" in
  01-capture|03-heat-chain) note "   bound: $(step_bound_line "$name")" ;;
  esac
  run_bg --bound "$b" "$@" > "$OUT/$name.txt" 2>&1
  return "$RB_RC"
}
# The two facts the LAST step turns on, re-read from the device after the step that is supposed to move
# them. A step that exits 0 and a knob that did not move is the failure this runbook exists to catch
# EARLY: found at step 05 it costs the boot, found here it costs the step.
A_AFTER=""; C_AFTER=""
say "-- 02-panic-guard will be judged by: download_mode == 0"
say "-- 03-heat-chain  will be judged by: no keeper in /proc (matched by argv)"
say

# --- 01 -------------------------------------------------------------------------------------------
if wanted 01-capture; then
  # The capture archives into a directory of its OWN inside ours, so its INDEX.txt survives next to
  # this one's -- two records of the same boot, and neither can overwrite the other.
  if run_step 01-capture "read-only: post-mortem FIRST, then the boot's own readings (04b modem, 04c sleep)" \
      "$CAP" --outdir "$OUT/capture"; then
    say "   -> rc=0"; step_done 01-capture 0 "read-only; its own archive is in capture/ inside this one"
    PASS=$((PASS + 1))
  else
    rc=$?
    say "   -> rc=$rc  (its own archive says which step failed; the chain below still runs)"
    step_done 01-capture "$rc" "a step inside the capture failed -- read its own INDEX.txt"
    FAIL=$((FAIL + 1))
  fi
else
  say "-- 01-capture skipped"
  step_done 01-capture skip "skipped by the operator -- the boot's one-shot readings are NOT archived"
fi
say

# --- 02 -------------------------------------------------------------------------------------------
if wanted 02-panic-guard; then
  if run_step 02-panic-guard "install the panic guard (WRITES two unit files on the rw /etc path)" \
      "$PANIC" --install; then
    say "   -> rc=0"
    A_ARMED=1
    step_done 02-panic-guard 0 "installed; the unit is enabled --now, so it applies to THIS boot too"
    PASS=$((PASS + 1))
  else
    rc=$?
    say "   -> rc=$rc"
    step_done 02-panic-guard "$rc" "the installer failed -- read 02-panic-guard.txt"
    FAIL=$((FAIL + 1))
  fi
else
  say "-- 02-panic-guard skipped"
  step_done 02-panic-guard skip "skipped by the operator"
fi
say

# --- 03 -------------------------------------------------------------------------------------------
if wanted 03-heat-chain; then
  # AND IT ARCHIVES INSIDE OURS, for the reason step 01 does and this step did not: the chain makes its
  # own archive (INDEX.txt, the per-step files, and `06b-heat-ab.txt` -- the A/B measurement it takes
  # around the two fixes) and, left alone, it puts that at `$REPO/tmp-heat-fix-<timestamp>/`, which is a
  # SECOND directory for the same boot, BESIDE this archive rather than inside it, and one that
  # `.gitignore`'s `tmp-*/` covers -- so it is scratch that nothing in this boot's INDEX names and
  # nothing preserves. On a boot that cannot be re-run, the reading landing where the boot's own record
  # does not point is the "found late" failure this whole script exists to prevent (docs 107/124).
  if [ -n "$SETTLE" ]; then
    run_step 03-heat-chain "the two known heat fixes, in their own order (the activate stage drops this session for ~90 s)" \
      "$HEAT" --yes --settle "$SETTLE" --outdir "$OUT/03-heat-chain"
  else
    run_step 03-heat-chain "the two known heat fixes, in their own order (the activate stage drops this session for ~90 s)" \
      "$HEAT" --yes --outdir "$OUT/03-heat-chain"
  fi
  rc=$?
  if [ "$rc" = 0 ]; then
    say "   -> rc=0"
    step_done 03-heat-chain 0 "ran to the end -- both halves in; its own archive (with the A/B reading) is in 03-heat-chain/ inside this one"
    PASS=$((PASS + 1))
  elif [ "$rc" = 1 ]; then
    # The heat chain's own 1 is "stopped short", and it distinguishes a REFUSAL (the proof did not
    # license the keeper kill -- the device is in the state the refusal describes) from a FAILURE. Its
    # archive says which, so this step records its code and lets the run continue to 04: the governor
    # half may well be in, and step 05 will read prerequisite C from the device either way.
    say "   -> rc=1 (stopped short -- its own archive says whether a step failed or the proof did not"
    say "      license the keeper kill; the fingerprint step does not depend on either)"
    step_done 03-heat-chain 1 "stopped short -- its own archive is in 03-heat-chain/ inside this one; C is re-read from the device below"
    FAIL=$((FAIL + 1))
  else
    say "   -> rc=$rc"
    step_done 03-heat-chain "$rc" "the chain did not complete -- read 03-heat-chain.txt and 03-heat-chain/INDEX.txt"
    FAIL=$((FAIL + 1))
  fi
else
  say "-- 03-heat-chain skipped"
  step_done 03-heat-chain skip "skipped by the operator"
fi
say

# --- the two device readings, taken HERE so that a failure is attributed to the step that caused it ---
# `set -u` and a dropped ssh session are the reason this is not inside the branches above: the heat
# chain's activate stage deliberately re-enumerates the gadget, so the first ssh after it may be the
# first one on a NEW link. A failed read is reported as UNREADABLE, never as a value.
A_AFTER=$(read_download_mode 2>/dev/null); [ -n "$A_AFTER" ] || A_AFTER="UNREADABLE"
C_AFTER=$(read_keeper 2>/dev/null); [ -n "$C_AFTER" ] || C_AFTER="UNREADABLE"
say "== the device, after the steps that were supposed to move it"
say "   download_mode : $A_AFTER"
say "   debug keeper  : $C_AFTER"
# The case is on the reader's OWN token now (`all=0 (N parameter(s))`), not on the value position: the
# earlier version matched `*=0` against a single `<path>=<value>` line, and the version before that
# matched `0*`, i.e. the value at the START -- so A was reported unmet on every boot however the device
# read. That was a check whose answer no scenario could change, and the harness found it by moving the
# flag. An explicit token makes the shape checkable instead of positional.
case "$A_AFTER" in
all=0*) note "prerequisite A is MET -- every download_mode parameter reads 0";;
ARMED*) note "A is NOT met -- the parameter(s) named above do not read 0, so a panic would still arm EDL; the cause is 02 or the driver, not the trial";;
TIMEOUT) note "A: NOT READ -- the host gave up on the ssh at ${STATE_LIMIT}s. That is a fact about this machine and NOT a reading, so it is not evidence about A in either direction; step 05 will refuse on it. The link is the thing to fix (docs 76), not 02.";;
UNREADABLE) note "A: UNREADABLE -- the link or the driver did not answer. A is NOT met.";;
NOT-FOUND) note "A is NOT met -- no /sys/module/*/parameters/download_mode on this device, so the policy unit could not arm itself either.";;
*) note "A is NOT met -- step 05 will refuse on A, and the cause is 02 or the driver, not the trial";;
esac
case "$C_AFTER" in
none*) note "prerequisite C is MET";;
TIMEOUT) note "C: NOT READ -- the host gave up on the ssh at ${STATE_LIMIT}s, so nothing here says whether a keeper is running. Step 03 may have worked; do NOT re-run it on the strength of this line.";;
UNREADABLE) note "C: UNREADABLE. C is NOT met.";;
*) note "C is NOT met -- step 05 will refuse on C, and the cause is 03, not the trial";;
esac
say

# --- 04 -------------------------------------------------------------------------------------------
if wanted 04-fingerprint; then
  if run_step 04-fingerprint "create the missing store directory (WRITES a directory in Android's /data + a unit)" \
      "$FP" --install; then
    say "   -> rc=0"
    step_done 04-fingerprint 0 "installed; the verdict is journalctl -b -u biometryd | grep -c 'setActiveGroup failed' going to 0"
    PASS=$((PASS + 1))
  else
    rc=$?
    say "   -> rc=$rc  (its applier exits 1 unless the directory reads back as the uid/mode access(W_OK) needs)"
    step_done 04-fingerprint "$rc" "the installer failed or its read-back did not hold -- read 04-fingerprint.txt"
    FAIL=$((FAIL + 1))
  fi
else
  say "-- 04-fingerprint skipped"
  step_done 04-fingerprint skip "skipped by the operator"
fi
say

# --- 05 -------------------------------------------------------------------------------------------
# The trial runs ON THE DEVICE, so this step pushes it and runs it there -- the same two commands doc
# 122 spells out by hand.
TRIAL_MODE=--status
[ "$APPLY_TRIAL" = 1 ] && TRIAL_MODE=--apply
if wanted 05-trial; then
  if [ "$APPLY_TRIAL" = 1 ] && [ "$A_ARMED" != 1 ]; then
    # This is the one refusal in this script that is about THIS script: applying the trial writes to the
    # SoC's power parameter, and its prerequisite A is what step 02 arms. Applying without having armed
    # it is the combination that trades a finger for a measurement -- and note that the check is "did it
    # RUN", not "was it not skipped", because `--only 05-trial` is the same hazard with a different
    # spelling.
    say "-- 05-trial REFUSED: --apply-trial was given, but 02-panic-guard did not run in this invocation."
    note "A hang here is an EDL trip, and the panic guard is what makes it a reboot instead. The trial"
    note "refuses on A too, so this is the same answer one step earlier and without the write. Two"
    note "options: run the sequence so that 02 runs, or drop --apply-trial and read it first."
    step_done 05-trial refused "REFUSED: --apply-trial without 02 having run -- nothing was written"
    FAIL=$((FAIL + 1))
  else
    say "-- 05-trial ($TRIAL_MODE)"
    run_bg scp -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR -o ConnectTimeout=10 "$TRIAL" "$HOST:/tmp/zl1-lpm-ladder-trial.sh"
    if [ "$RB_RC" != 0 ]; then
      say "   -> could not copy the trial to the device"
      step_done 05-trial "$RB_RC" "the trial could not be pushed -- nothing was run"
      FAIL=$((FAIL + 1))
    else
      # A DEVICE-SIDE bound, for the reason the capture records: `timeout` gives the command its own
      # process group and signals the group, which is what stops a runaway CHILD. --apply settles for
      # 120 s by default, so the bound has to be generous; --status returns in seconds.
      BOUND=300
      [ "$TRIAL_MODE" = "--apply" ] && BOUND=600
      run_bg "${SSH[@]}" "if command -v timeout >/dev/null 2>&1; then timeout -k 5 $BOUND sh /tmp/zl1-lpm-ladder-trial.sh $TRIAL_MODE
        else printf '%s\n' 'NOTE: this device has no timeout(1): THIS STEP IS NOT TIME-BOUNDED.' >&2; sh /tmp/zl1-lpm-ladder-trial.sh $TRIAL_MODE; fi" \
        > "$OUT/05-trial.txt" 2>&1
      rc=$?
      case "$rc" in
      0) say "   -> rc=0 (a measurement -- and REFUTED would also be 0: it is a reading, not a failure)"
         step_done 05-trial 0 "ran; the verdict is its own -- REFUTED is a measurement, not a failure"
         PASS=$((PASS + 1)) ;;
      1) say "   -> rc=1 (INCONCLUSIVE or CONFOUNDED -- a statement about the run, not about the phone)"
         step_done 05-trial 1 "inconclusive/confounded -- read 05-trial.txt before concluding anything"
         FAIL=$((FAIL + 1)) ;;
      3) say "   -> rc=3 (REFUSED: one of its three prerequisites is not met -- its text names which, and"
         say "      the readings above say whether that is about THIS boot or about the driver)"
         step_done 05-trial 3 "REFUSED -- its own output names which prerequisite, and nothing was written"
         FAIL=$((FAIL + 1)) ;;
      *) say "   -> rc=$rc"
         step_done 05-trial "$rc" "the trial did not complete -- read 05-trial.txt"
         FAIL=$((FAIL + 1)) ;;
      esac
    fi
  fi
else
  say "-- 05-trial skipped"
  step_done 05-trial skip "skipped by the operator"
fi

# ==================================================================================================
# The plan and the execution are two independent things in this file -- STEPS is a list, and the order is
# the sequence of `if wanted ...` blocks below it -- so they are CHECKED AGAINST EACH OTHER rather than
# trusted to agree. Without this, editing the run order leaves STEPS listing the old one, `--skip`/`--only`
# validation keeps passing, and the archive records a plan nobody executed. (A mutation that swapped two
# entries of STEPS produced ZERO failures before this check existed, which is how it was found: a check
# whose answer no scenario can change is not a check.)
# ==================================================================================================
EXPECTED=""
for t in "${STEPS[@]}"; do wanted "$t" && EXPECTED="$EXPECTED $t"; done
EXPECTED=${EXPECTED# }
# ACTUAL is the steps that RAN, and it is a different list from the steps that were RECORDED: every
# skipped step gets a `step_done <name> skip` row too (the archive has to say "not in this boot's plan"),
# and comparing the wanted list against the recorded one made ANY `--skip` look like a plan/run
# disagreement. Measured at HEAD: `--yes --skip 03-heat-chain` reported "1 failed" and exited 1 -- and the
# refusal branch above recommends `--skip <step>` to an operator whose host is missing a file, so the
# advice this script gives produced a failure that was not real.
ACTUAL="${EXECUTED[*]:-}"
if [ "$ACTUAL" != "$EXPECTED" ]; then
  # AND THIS BRANCH USED TO CALL `bad`, which is a HARNESS function and does not exist here. So the one
  # branch whose whole job is to say "this script is wrong" printed four `bad: command not found` lines
  # into the step's own file and no diagnosis at all -- an instrument that cannot report what it exists to
  # report (docs 72), in the file that reports on the others.
  say "   THE PLAN AND THE RUN DISAGREE -- this is a defect in this script, not on the device:"
  say "   STEPS says : $EXPECTED"
  say "   it ran     : $ACTUAL"
  say "   Nothing was undoed; read the archive and fix this script before trusting the order."
  FAIL=$((FAIL + 1))
  step_done plan-mismatch 1 "the declared order and the executed order disagree -- a defect in this script"
fi

archive

say
say "=== archived ==="
say "  $OUT"
say "  INDEX.txt, SHA256SUMS, and one file per step"
say "  verify with:  ( cd $OUT && sha256sum -c SHA256SUMS )"
say
# The two numbers have to be two different facts, and they were not: every caller counts a non-zero rc as
# a failure (it cannot know about the bound -- the classification lives in step_done, one place), so a
# step that ran out of time would be counted TWICE: once as "failed" and once as "did not finish". It is
# taken back out of FAIL here rather than in ten caller branches, and the harness pins the resulting line
# so the two can never silently merge again.
FAIL=$((FAIL - N_TIMED_OUT))
if [ "$FAIL" = 0 ] && [ "$N_TIMED_OUT" = 0 ]; then
  say "one-boot runbook complete: $PASS step(s) ran, 0 failed"
else
  say "one-boot runbook did not complete: $PASS step(s) ran, $FAIL failed, $N_TIMED_OUT did not finish"
  [ "$N_TIMED_OUT" != 0 ] && say "  the bound was the one named above each step (--step-limit ${STEP_LIMIT}s for 02/04/05, and the"
  [ "$N_TIMED_OUT" != 0 ] && say "  callee's own computed worst case for 01/03, see INDEX.txt); a step that outlasted it is NOT a"
  [ "$N_TIMED_OUT" != 0 ] && say "  failure of the step -- but the boot is spent, so read that step's own file and the archive"
fi
say
say "What to do with it:"
say "  * 01: whether the previous boot's death is explained, and which of the two witnesses is there."
say "  * 02: it is the one step that outlasts the boot, so it is the one step worth doing even on a"
say "    boot where nothing else works out."
say "  * 03: read ITS archive. '1' means the chain stopped short, and its own text says whether a step"
say "    failed or the address proof did not license the keeper kill."
say "  * 04: the verdict is a log count, not a feeling --"
say "    journalctl -b -u biometryd | grep -c 'setActiveGroup failed'  should go to 0."
say "  * 05: its verdict IS the answer to the third heat cause. REFUTED is a result."
[ "$FAIL" = 0 ] && [ "$N_TIMED_OUT" = 0 ]
