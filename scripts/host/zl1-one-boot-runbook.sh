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
#                                [--outdir DIR] [--settle SECS]
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
#
# Exit codes:
#   0  the sequence ran to the end and every step's own verdict was acceptable
#   1  the sequence stopped short -- a step failed, or a downstream precondition did NOT move -- and
#      the archive says which. Whatever ran before it is archived.
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

while [ $# -gt 0 ]; do
  case "$1" in
  --status) MODE=status; shift ;;
  --yes) MODE=run; shift ;;
  --apply-trial) APPLY_TRIAL=1; shift ;;
  --only) ONLY="${2?--only needs a STEP}"; shift 2 ;;
  --skip) SKIP="${SKIP:+$SKIP }${2?--skip needs a STEP}"; shift 2 ;;
  --outdir) OUT="${2?--outdir needs a DIRECTORY}"; shift 2 ;;
  --settle) SETTLE="${2?--settle needs SECONDS}"; shift 2 ;;
  --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; exit 0 ;;
  *) echo "unknown argument ${1:-} (try --help)" >&2; exit 2 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
note() { printf '   %s\n' "$*"; }

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

if ! "${SSH[@]}" true 2>/dev/null; then
  say "zl1 one-boot runbook"
  say "  the device is on the bus (serial $DEV) but SSH does not answer yet -- it may still be booting."
  say "  Wait for RNDIS and for ssh, then run this again. NOTHING WAS RUN."
  say
  say "  If the link is up but carries no traffic, that is the OTHER known failure and it lives on the"
  say "  HOST (docs 76): scripts/host/zl1-rndis-recover.sh re-enumerates the gadget without a reboot."
  exit 2
fi

BOOT_ID=$("${SSH[@]}" 'cat /proc/sys/kernel/random/boot_id 2>/dev/null' | tr -d '\r\n')
[ -n "$BOOT_ID" ] || BOOT_ID="unknown-$(date -u +%Y%m%dT%H%M%SZ)"

# ==================================================================================================
# The device readings this runbook turns on. Each is a READING of the state a step is supposed to
# change, taken from the device and never inferred from the step's own exit code: an installer that
# exits 0 and a knob that moved are two different facts, and the whole point of ordering the sequence
# is that the second one is what the LAST step depends on.
# ==================================================================================================
# `download_mode` -- the trial's prerequisite A. Discovered by GLOB, not by name, for the same reason
# the trial does it: doc 86 records that the poweroff driver's name was not what the string search
# suggested. It is a 0644 module parameter, so 0 means a panic reboots instead of arming EDL.
read_download_mode() {
  "${SSH[@]}" 'for p in /sys/module/*/parameters/download_mode; do
      [ -e "$p" ] && { printf "%s=%s" "$p" "$(cat "$p" 2>/dev/null)"; exit 0; }
    done; printf "NOT-FOUND"' 2>/dev/null | tr -d '\r\n'
}
# The debug keeper -- the trial's prerequisite C. Matched by ARGV, the same rule every other script here
# uses: a shell whose command line merely MENTIONS the keeper's path is not the keeper.
read_keeper() {
  "${SSH[@]}" 'n=0; for d in /proc/[0-9]*; do
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
    done; [ "$n" = 0 ] && printf "none"; printf "(%s)" "$n"' 2>/dev/null | tr -d '\r\n'
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
run_bg() { "$@" & RB_PID=$!; wait "$RB_PID"; RB_RC=$?; RB_PID=""; return "$RB_RC"; }

# --- the plan --------------------------------------------------------------------------------------
wanted() { # is this step in the set this run will execute?
  [ -n "$ONLY" ] && [ "$ONLY" != "$1" ] && return 1
  skipped "$1" && return 1
  return 0
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
  say "the trial's two hard prerequisites, as the DEVICE reads them right now:"
  DM=$(read_download_mode)
  KP=$(read_keeper)
  # `*=0` and not `0`, for the same reason as the run branch below: the reading is `<path>=<value>`.
  # Both spellings were wrong in the first version, in the same way, and the harness caught the run
  # branch first and the status branch second -- which is what a harness is for.
  case "$DM" in
  *=0) say "  A. download_mode: $DM   <- a panic will NOT arm EDL (prerequisite A is MET)";;
  NOT-FOUND) say "  A. download_mode: NOT FOUND under /sys/module/*/parameters/ -- A cannot be checked, so it is NOT met";;
  *) say "  A. download_mode: $DM   <- a panic WOULD arm EDL (A is NOT met; step 02 is what fixes it)";;
  esac
  case "$KP" in
  none*) say "  C. debug keeper: none -- C is MET";;
  *) say "  C. debug keeper: $KP   <- a CPU that is never idle does not enter a deep idle state, so C is NOT met (step 03 retires it)";;
  esac
  say "  B. cpuidle counters: not checked here -- the trial reads them itself, and UNREADABLE IS NOT ZERO."
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

# One step = one archive entry + one note that is a DEVICE READING, not the step's exit code. It also
# records the step in EXECUTION ORDER, which is checked against STEPS at the end -- see the note there.
step_done() { STEP_NAMES+=("$1"); STEP_RC+=("$2"); STEP_NOTE+=("$3"); EXECUTED+=("$1"); }
declare -a EXECUTED=()
run_step() { # name, human sentence, command...
  local name="$1" why="$2"; shift 2
  say "-- $name"
  note "$why"
  run_bg "$@" > "$OUT/$name.txt" 2>&1
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
  if [ -n "$SETTLE" ]; then
    run_step 03-heat-chain "the two known heat fixes, in their own order (the activate stage drops this session for ~90 s)" \
      "$HEAT" --yes --settle "$SETTLE"
  else
    run_step 03-heat-chain "the two known heat fixes, in their own order (the activate stage drops this session for ~90 s)" \
      "$HEAT" --yes
  fi
  rc=$?
  if [ "$rc" = 0 ]; then
    say "   -> rc=0"
    step_done 03-heat-chain 0 "ran to the end -- both halves in"
    PASS=$((PASS + 1))
  elif [ "$rc" = 1 ]; then
    # The heat chain's own 1 is "stopped short", and it distinguishes a REFUSAL (the proof did not
    # license the keeper kill -- the device is in the state the refusal describes) from a FAILURE. Its
    # archive says which, so this step records its code and lets the run continue to 04: the governor
    # half may well be in, and step 05 will read prerequisite C from the device either way.
    say "   -> rc=1 (stopped short -- its own archive says whether a step failed or the proof did not"
    say "      license the keeper kill; the fingerprint step does not depend on either)"
    step_done 03-heat-chain 1 "stopped short -- read its own archive; C is re-read from the device below"
    FAIL=$((FAIL + 1))
  else
    say "   -> rc=$rc"
    step_done 03-heat-chain "$rc" "the chain did not complete -- read 03-heat-chain.txt"
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
# `*=0` and NOT `0*`: the reading is `<path>=<value>`, so the value is at the END. The first version
# matched the value at the START, which meant A was reported unmet on every boot however the device
# read -- a check whose answer no scenario could change, found by the harness moving the flag.
case "$A_AFTER" in
*=0) note "prerequisite A is MET";;
UNREADABLE) note "A: UNREADABLE -- the link or the driver did not answer. A is NOT met.";;
*) note "A is NOT met -- step 05 will refuse on A, and the cause is 02 or the driver, not the trial";;
esac
case "$C_AFTER" in
none*) note "prerequisite C is MET";;
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
ACTUAL="${EXECUTED[*]:-}"
if [ "$ACTUAL" != "$EXPECTED" ]; then
  bad "   THE PLAN AND THE RUN DISAGREE -- this is a defect in this script, not on the device:"
  bad "   STEPS says : $EXPECTED"
  bad "   it ran     : $ACTUAL"
  bad "   Nothing was undoed; read the archive and fix this script before trusting the order."
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
if [ "$FAIL" = 0 ]; then
  say "one-boot runbook complete: $PASS step(s) ran, 0 failed"
else
  say "one-boot runbook stopped short: $PASS step(s) ran, $FAIL need your attention"
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
[ "$FAIL" = 0 ]
