#!/usr/bin/env bash
# zl1 post-recovery capture -- ONE command, run the moment RNDIS comes back, that takes the evidence
# which is only readable on THIS boot, in the only order that works, and archives it.
#
# Why this exists: the boot after a trip to Qualcomm EDL is not repeatable, and neither is the physical
# act of getting there. Getting out of EDL needs a finger on the power button for 10-20 s (docs 49
# section 6 -- there is no software exit, and doc 89 shows a kernel panic lands there by itself), so
# every recovery boot is a scarce resource. Three things are true only during it:
#
#   * `/sys/fs/pstore` holds the previous oops UNTIL THE NEXT RESET (docs 86). This boot is the only
#     chance to read what killed the last one. Step 0.
#   * `/userdata/zl1-kmsg/`'s ring wraps in about a minute (docs 87), and the boot-address verdict has
#     to come from THIS boot's netwatch log, because a wrong verdict costs SSH and SSH costs another
#     press (docs 88). Step 0b.
#   * the debug keeper's pid and its accumulated CPU ticks are gone once it is retired (docs 94), so
#     "how much of a core was it" is a number that only exists before the kill.
#
# The health-check already prints all of this in the right order. This script is not a replacement for
# it -- it RUNS that order, so nobody has to retype six scp/ssh pairs while the kmsg ring is wrapping,
# and so the answers survive as files instead of as scrollback.
#
# READ-ONLY BY DEFAULT, and deliberately so: every step in the default set only reads. The ONE step
# that writes is `install-no-edl-on-panic.sh --capture-only` (it copies pstore onto /userdata at every
# boot, which is a write), and it is available only behind `--with-capture` so that the operator makes
# that decision explicitly. In the spirit of the rest of this directory it never flashes, never runs a
# QDL/firehose tool, never writes a sysfs node, and never restarts a service.
#
# If the device is still in EDL (or absent), it REFUSES and exits 2 without touching anything -- the
# answer then is a finger, and a script cannot help with that.
#
# Usage: zl1-post-recovery-capture.sh [--outdir DIR] [--with-capture] [--skip-probes] [--no-orientation]
#                                     [--step-limit SECS]
#
#   --outdir DIR        where to archive (default: repo tmp-post-recovery-<utc timestamp>/)
#   --with-capture      ALSO run install-no-edl-on-panic.sh --capture-only (a device write; opt-in)
#   --with-probes       RUN the GPS and fingerprint probes. They are SKIPPED BY DEFAULT: neither has
#                       ever produced a fix, they are the slowest steps, and the last two boots that
#                       ended in EDL both had the fingerprint probe as the last thing running (a
#                       correlation of two, not a cause -- see the note at the steps below)
#   --skip-probes       the old name for the default, kept because four documents spell it out. It does
#                       NOT skip the modem probe (step 04b), which is read-only and never opens a block
#                       device -- see the note at that step. The name is misleading and this line is
#                       the correction: it selects the DEFAULT set, and the default set now contains it.
#   --no-orientation    skip the orientation-axes probe (it needs a person holding the phone still)
#   --step-limit SECS   kill a DEVICE-side step that runs longer than this (default 240). See the note
#                       in the step runner: a device-side script that runs away is not a hypothetical,
#                       it is what put this phone in EDL on 2026-09-23 (docs 108).
#
# Exit codes:
#   0  everything in the set ran and every step's own verdict was acceptable
#   1  the capture completed but at least one step failed (its output is still archived -- read it)
#   2  the device is not reachable (EDL, no link, no SSH): NOTHING was run
#   3  the capture was INTERRUPTED: whatever had been collected is archived and indexed anyway
#
# Env: ZL1_HOST (default root@10.15.19.82), ZL1_SERIAL (default 33e80afe)

set -uo pipefail

HOST="${ZL1_HOST:-root@10.15.19.82}"
DEV="${ZL1_SERIAL:-33e80afe}"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 "$HOST")
SCP=(scp -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)

OUT=""
WITH_CAPTURE=0
# THE DEFAULT IS TO SKIP THEM (docs 116). They have never produced a fix -- neither GPS nor the
# fingerprint has ever returned anything -- and the last two boots that ended in Qualcomm EDL both had
# step 06 (the fingerprint probe) as the last thing running. That is a correlation of two, not a
# cause, and this file says so rather than claiming one; but the default of the command that runs on
# the boot you paid a finger for should be the part that only exists on that boot. `--with-probes` is
# how you ask for them, `--skip-probes` is kept as a no-op so the four documents that spell it out
# still work.
SKIP_PROBES=1
NO_ORIENTATION=0
STEP_LIMIT=240

while [ $# -gt 0 ]; do
  case "$1" in
  --outdir) OUT="${2?--outdir needs a DIRECTORY}"; shift 2 ;;
  --with-capture) WITH_CAPTURE=1; shift ;;
  --skip-probes) SKIP_PROBES=1; shift ;;
  --with-probes) SKIP_PROBES=0; shift ;;
  --no-orientation) NO_ORIENTATION=1; shift ;;
  --step-limit) STEP_LIMIT="${2?--step-limit needs SECONDS}"; shift 2 ;;
  --help|-h)
    # The header, whatever its current length -- not a fixed line range, which silently truncates the
    # usage text every time the header grows (the defect docs 104 records, in two other scripts).
    awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; exit 0 ;;
  *) echo "unknown argument ${1:-} (try --help)" >&2; exit 2 ;;
  esac
done

case "$STEP_LIMIT" in
""|*[!0-9]*) echo "--step-limit must be a whole number of seconds, not [$STEP_LIMIT]" >&2; exit 2 ;;
esac

PASS=0
FAIL=0
declare -a STEP_NAMES=() STEP_RC=() STEP_FILES=() STEP_BOOT=()
# The boot's identity is read ONCE at the top, and until 2026-09-25 nothing ever asked whether it was
# still that boot. These four are what that question needs to be answerable (docs 162).
BOOT_SWITCH=""          # "<step name>: <old id> -> <new id>" on the FIRST step that saw a change
BOOT_SWITCH_N=0         # how many steps ran under an identity that is NOT the one this archive is named for
BOOT_CHECKS=0
BOOT_CHECK_UNREADABLE=0

say()  { printf '%s\n' "$*"; }
note() { printf '   %s\n' "$*"; }

# --- 0. is there a device at all? ------------------------------------------------------------------
# The modes are not distinguishable by "ping fails" (docs 100's health check exists for that reason),
# so the FIRST question is asked of the host's USB tree, not of the network: an EDL device presents
# 05c6:9008 with NO serial number, so looking for the serial finds nothing and looking for the vendor
# id finds a phone that cannot be talked to.
edl_state() {
  if lsusb -d 05c6:9008 >/dev/null 2>&1; then echo edl; return; fi
  # PREFIX match, not equality -- and this was a real bug, found by the first run against the real
  # device: the gadget's serial is `33e80afe-v63-usbd-disabled-rndis`, i.e. the id followed by the
  # image that produced it. An `=` here reported "absent" for a phone that was up, SSHable, and
  # answering ping, i.e. the most expensive possible false negative on the one boot that cannot be
  # revisited. The health check has always matched on the prefix (that is the rule in
  # [[ignore-xiaomi-4a2fe00b]]: identify the target BY SERIAL, never by bare USB id).
  for d in /sys/bus/usb/devices/*/; do
    case "$(cat "$d/serial" 2>/dev/null)" in
    "$DEV"*) echo present; return ;;
    esac
  done
  echo absent
}

STATE=$(edl_state)
if [ "$STATE" != present ]; then
  say "zl1 post-recovery capture"
  say "  the device is NOT reachable: $STATE"
  case "$STATE" in
  edl)
    say
    say "  It is in Qualcomm EDL (05c6:9008 / QDL mode), which presents no serial number, so there is"
    say "  nothing here to address -- by design: doc 49 section 6, and no QDL/firehose tool may be run."
    say
    say "  THE NEXT MOVE IS PHYSICAL AND ONLY PHYSICAL:"
    say "      long-press POWER for 10-20 s, then wait for RNDIS (usb0) to come back."
    say "  Then run this script again -- it runs the read-only chain in the order that works."
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
  say "zl1 post-recovery capture"
  say "  the device is on the bus (serial $DEV) but SSH does not answer yet -- it may still be booting."
  say "  Wait for RNDIS and for ssh, then run this again. NOTHING WAS RUN."
  say
  say "  If the link is up but carries no traffic, that is the OTHER known failure and it lives on the"
  say "  HOST (docs 76): scripts/host/zl1-rndis-recover.sh re-enumerates the gadget without a reboot."
  exit 2
fi

# The boot's identity, read BEFORE anything else, because the archive is named for it and because a
# second capture of the same boot has to land in the same directory while a new boot must not.
BOOT_ID=$("${SSH[@]}" 'cat /proc/sys/kernel/random/boot_id 2>/dev/null' | tr -d '\r\n')
[ -n "$BOOT_ID" ] || BOOT_ID="unknown-$(date -u +%Y%m%dT%H%M%SZ)"

[ -n "$OUT" ] || OUT="$REPO/tmp-post-recovery-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT" || { echo "cannot create $OUT" >&2; exit 2; }
OUT=$(cd "$OUT" && pwd)

say "zl1 post-recovery capture"
say "  device:  $HOST (serial $DEV)"
say "  boot_id: $BOOT_ID"
say "  outdir:  $OUT"
say

# ==================================================================================================
# The archive. An index and a SHA256SUMS, because the point of the directory is that it is the record
# of a boot that cannot be revisited -- and a record nobody can check the integrity of is a liability
# the next time someone asks "did that really say that".
#
# It is a FUNCTION, it is defined HERE (before the first step, not after the last), and it is also the
# SIGINT/SIGTERM handler. The first real run of this script was killed by a timeout before it ever got
# to the archive: 00-06 were on disk and the directory had no INDEX.txt and no SHA256SUMS, so nothing
# tied the files together and nothing said which step had produced which. On a boot that cannot be
# revisited that is the whole loss. Interrupting now costs the steps not yet run and nothing else.
ARCHIVED=0
INTERRUPTED=0
archive() {
  [ "$ARCHIVED" = 1 ] && return 0
  ARCHIVED=1
  {
    printf '# zl1 post-recovery capture\n'
    printf 'boot_id: %s\n' "$BOOT_ID"
    printf 'device: %s (serial %s)\n' "$HOST" "$DEV"
    printf 'captured: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'with_capture: %s   skip_probes: %s   no_orientation: %s   step_limit: %ss\n' \
      "$WITH_CAPTURE" "$SKIP_PROBES" "$NO_ORIENTATION" "$STEP_LIMIT"
    # The identity is a READING, not a label (docs 162). The header keeps the id the archive is NAMED
    # for, and these two lines say whether the device was still that boot when the steps ran. A reader
    # who sees `boot_switch:` knows the bottom of this file describes a DIFFERENT phone state than the
    # top, which is the whole reason the step column below carries a boot mark per step.
    printf 'boot_check: %s of %s steps re-read the identity   changed: %s   unreadable: %s\n' \
      "$BOOT_CHECKS" "${#STEP_NAMES[@]}" "$BOOT_SWITCH_N" "$BOOT_CHECK_UNREADABLE"
    [ -n "$BOOT_SWITCH" ] && printf 'boot_switch: %s   <- every step marked CHANGED-BOOT ran under the second id\n' "$BOOT_SWITCH"
    [ "$INTERRUPTED" = 1 ] && printf 'INTERRUPTED: yes -- the steps below are all that ran\n'
    printf '\n# step                 rc   file\n'
    i=0
    while [ "$i" -lt "${#STEP_NAMES[@]}" ]; do
      # `:-` on EVERY array read, because this function is also the signal handler and a signal can
      # arrive between `STEP_NAMES+=(...)` and `STEP_RC+=(...)` -- i.e. in the middle of a step. Plain
      # `${STEP_RC[$i]}` then aborts the whole function under `set -u`, which is precisely the loss the
      # handler exists to prevent: the first version of it wrote an INDEX.txt and then died before
      # writing the SHA256SUMS next to it. Found by the harness's interrupt test, which is the only
      # thing that runs this function in that state.
      local rc_i="${STEP_RC[$i]:-?}"
      local f_i="${STEP_FILES[$i]:-${STEP_NAMES[$i]}.txt (partial: the interrupt landed here)}"
      # The boot mark, and `not-checked` is its own value rather than `same`: a step the check never
      # ran after (a signal between the step and the check) is not evidence of an unchanged boot.
      local b_i="${STEP_BOOT[$i]:-not-checked}"
      case "$b_i" in
      CHANGED) b_i="CHANGED-BOOT" ;;
      same)    b_i="same-boot" ;;
      esac
      printf '%-20s %3s   %-12s %s\n' "${STEP_NAMES[$i]}" "$rc_i" "$b_i" "$f_i"
      i=$((i + 1))
    done
    printf '\n# every step is read-only except 08-no-edl-capture, which only runs with --with-capture\n'
  } > "$OUT/INDEX.txt"
  ( cd "$OUT" && sha256sum ./*.txt 2>/dev/null > SHA256SUMS )
}

# `set -e` is deliberately not on, so a trap plus the final call are the only two ways the archive gets
# written. The handler archives first and exits 3 -- a DIFFERENT code from 1 ("a step failed") and 2
# ("nothing was run"), so a wrapper can tell "incomplete capture, but it is on disk" apart.
#
# It writes its own message to fd 9, NOT to stdout. A signal arrives while a step is running, and a
# step's ssh call carries `> $step.txt 2>&1` -- so plain `say` inside the handler lands in the middle
# of the interrupted step's output file, AND changes that file after `archive` has hashed it, which
# makes the partial archive fail its own `sha256sum -c`. Both were observed; the harness's
# `sha256sum -c` on the partial archive is what caught the second one.
RB_PID=""
on_signal() {
  INTERRUPTED=1
  # Stop the step that is IN FLIGHT before hashing what it is still writing to: a child that outlives
  # the parent keeps the step's output file open and appends to it later.
  if [ -n "$RB_PID" ]; then
    kill -TERM "$RB_PID" 2>/dev/null
    sleep 1
    kill -9 "$RB_PID" 2>/dev/null
    wait "$RB_PID" 2>/dev/null
  fi
  archive
  printf '\nINTERRUPTED: archived what had run into %s\n' "$OUT" >&9
  exit 3
}
exec 9>&1
trap on_signal INT TERM HUP

# Every long call goes through this, and it is not decoration. bash runs a TRAP for a signal only
# after the FOREGROUND command finishes; it runs it at once when the signal arrives during `wait`.
# Measured on this host: a TERM sent 2 s into a foreground `sleep 20` was handled at +20.0 s, and the
# same TERM during `sleep 20 & wait` at +2.0 s. So a foreground ssh call would make Ctrl-C wait out
# the very step it is trying to abandon -- and the step is bounded by the DEVICE's timeout, which is
# 240 s. Backgrounding is what makes the interrupt-handler above worth having.
#
# AND EVERY CALL IS BOUNDED ON THIS SIDE TOO (docs 161). The paragraph above explains why the call is
# backgrounded; it says nothing about how long it may live, and until 2026-09-25 NOTHING bounded the host
# half of a step. The device half has `timeout -k 5 $STEP_LIMIT` and that guard is real -- but it lives on
# the FAR SIDE of an ssh, and the failure this cost is not the device hanging: it is the SSH ITSELF never
# answering. Measured, on the boot that was spent: the identity block's `run_bg ssh` sat for 4m09s with no
# child running on the device at all -- the remote command had already finished and the client was simply
# stuck -- and this script's outer bound was 4775 s, so a dead socket could have eaten the boot. The next
# section (the bounded runner) is the fix; these two numbers are its two bounds.
RB_RC=0
# The backstop for a DEVICE call: strictly LOOSER than the device's own bound, because the device's
# timeout is the one that should fire -- its process-group signal is what reaches a step that spawned a
# child. This bound exists for the case where that timeout never gets to run: a dead socket, a dropped
# link, a wedged ssh.
HOST_BACKSTOP=$((STEP_LIMIT + 30))
# The bound for a PUSH, which is a small script over a link that is up: the same size the heat chain uses
# for its own read-backs. A step is not retried, so a slow-but-working link must not be cut off.
IO_LIMIT=60
# The bound on the ONE call that is not a step and not a push: the boot-identity re-read the step runner
# makes after every step (docs 162). It is short because it is one `cat` of a kernel file -- but NOT zero,
# because the whole reason it exists is a step that left the link wedged, and an unbounded check would
# hang exactly where the step did. It does not count toward the callee-derived bound in _cap_shape()
# below: that number exists to keep ONE STEP from being cut off mid-flight, and this call is not a step.
BOOT_CHECK_LIMIT=20
# AND THE UNBOUNDED RUNNER IS GONE, not merely avoided. It had five call sites and every one of them was a
# place a hung ssh could spend the boot; leaving it in the file as a thing somebody may call again is how
# docs 132's fix stopped at the runbook and never reached the callee it invokes. So there is exactly ONE
# runner now, it always takes a bound, and the harness asserts that no unbounded call exists in the source
# -- the hazard is removed from the tree rather than remembered as a convention.
#
# `timeout` on THIS side, in front of every call. `timeout` must exist here: the harness's sandbox PATH is
# built from real coreutils, and a host without timeout(1) could not have run the other bounded callers.
# THE TWO SIDES ARE TOLD APART BY A MARKER, not by an exit code: `timeout` exits 124 on expiry and the
# device's own `timeout` ALSO exits 124, so a step that reports "124" would otherwise be ambiguous about
# which machine gave up. The device-side wrapper prints `ZL1STEP-TIMEOUT device` when IT is the one that
# fired; a 124/137 with no such marker in the step's output is the host backstop.
run_bg_bound() { # bounded-call LIMIT SECONDS, then the command
  local lim="$1"; shift
  timeout -k 5 "$lim" "$@" &
  RB_PID=$!
  wait "$RB_PID"
  RB_RC=$?
  RB_PID=""
}

# --- the step runner -------------------------------------------------------------------------------
#
# Two kinds of step, and the difference is where the script lives:
#
#   device  a `sh` script that has to be copied to the device and run there (edl-postmortem,
#           boot-address-check, the probes). Pushing to /tmp is what the health-check already tells the
#           operator to do, and it is the only way these can run at all.
#   host    a script that already drives the device from here (the installers' --status modes, the
#           health check). Running it through the ssh stub would be a second, different mistake.
#
# A step that fails does NOT stop the capture. The evidence in this list is only read once, so
# getting the rest of it matters more than stopping at the first bad verdict -- which is why the
# failure is recorded and the exit code reports it at the end, instead of aborting.
step() { # name, kind, localpath, remote-args...
  local name="$1" kind="$2" src="$3"; shift 3
  local args="$*"
  local out="$OUT/$name.txt"
  say "-- $name"
  STEP_NAMES+=("$name")
  local rc=0
  case "$kind" in
  device)
    local base; base=$(basename "$src")
    run_bg_bound "$IO_LIMIT" "${SCP[@]}" "$src" "$HOST:/tmp/$base" >/dev/null 2>&1 || rc=90
    rc=$RB_RC
    if [ "$rc" = 0 ]; then
      # A DEVICE-SIDE bound, and it is on the device on purpose. `timeout` (GNU, and it is in the
      # rootfs -- /usr/bin/timeout) runs the command in its OWN PROCESS GROUP and signals the group
      # on expiry, which is the property that matters: on 2026-09-23 a device-side step spawned a
      # child that took one core for 11+ minutes and the phone ended in EDL. Killing only the shell
      # would have left that child running. `-k 5` is the same signal again if it ignores the first.
      #
      # And when timeout is NOT there the step still runs, but it says so in its own output rather
      # than being silently unbounded -- an absent guard must be visible, not inferred (docs 99).
      #
      # The `ZL1STEP-TIMEOUT device` line is the MARKER described at run_bg_bound: it is what lets the
      # note below say which machine ended the step instead of guessing from an exit code both sides use.
      run_bg_bound "$HOST_BACKSTOP" "${SSH[@]}" "
        if command -v timeout >/dev/null 2>&1; then
          timeout -k 5 $STEP_LIMIT sh /tmp/$base $args
          zr=\$?
          case \$zr in
            124|137) printf '%s\n' 'ZL1STEP-TIMEOUT device' >&2 ;;
          esac
          exit \$zr
        else
          printf '%s\n' 'NOTE: this device has no timeout(1): THIS STEP IS NOT TIME-BOUNDED.' >&2
          sh /tmp/$base $args
        fi" > "$out" 2>&1
      rc=$RB_RC
    else
      printf 'could not copy %s to the device\n' "$base" > "$out"
    fi
    ;;
  host)
    run_bg_bound "$HOST_BACKSTOP" bash "$src" "$@" > "$out" 2>&1
    rc=$RB_RC
    ;;
  esac
  STEP_RC+=("$rc")
  STEP_FILES+=("$(basename "$out")")
  if [ "$rc" = 0 ]; then
    PASS=$((PASS + 1)); note "ok   ($(wc -l < "$out") lines -> $(basename "$out"))"
  else
    FAIL=$((FAIL + 1)); note "FAILED rc=$rc -- its output is still archived, read it"
    # 124 is `timeout`'s own code, and it means something specific and actionable: the step did not
    # finish. Saying that here is the difference between "a verdict was bad" and "the phone is
    # probably at high load right now, go and look at 04". 137 is the -k 5 case.
    #
    # AND THERE ARE TWO `timeout`s NOW, one on each side of the ssh, both of which exit 124 (docs 161).
    # Which one fired is not a detail: "the device's own bound fired" is a reading about the PHONE, and
    # "the host backstop fired" is a reading about the LINK -- and until this line existed the note
    # below claimed the first for both. The device-side wrapper prints its marker into the step's own
    # output, so the question is answered by reading the file rather than by guessing from the code.
    case "$rc" in
    124)
      if grep -qa '^ZL1STEP-TIMEOUT device' "$out" 2>/dev/null; then
        note "        ^ the DEVICE's own timeout(1) ended this step at ${STEP_LIMIT}s. This is NOT a"
        note "          verdict, it is a hung device-side script -- check the load in 04."
      else
        note "        ^ the HOST BACKSTOP ended this step at ${HOST_BACKSTOP}s, with no marker from the"
        note "          device's own timeout(${STEP_LIMIT}s) in its output: the ssh never came back. This"
        note "          is a reading about the LINK, not about the phone -- the step's own output stops"
        note "          where the socket died."
      fi ;;
    137)
      if grep -qa '^ZL1STEP-TIMEOUT device' "$out" 2>/dev/null; then
        note "        ^ the DEVICE's timeout(1) -k 5 had to SIGKILL at ${STEP_LIMIT}s+5s."
      else
        note "        ^ the HOST BACKSTOP had to SIGKILL at ${HOST_BACKSTOP}s+5s: the ssh ignored TERM."
      fi ;;
    esac
    # The verdict that matters is usually the last non-empty line, and printing it here is the
    # difference between "something failed" and knowing what without opening a file.
    grep -av '^[[:space:]]*$' "$out" 2>/dev/null | tail -3 | sed 's/^/        | /'
  fi
  # ================================================================================================
  # DID THE PHONE COME BACK AS A DIFFERENT BOOT? (docs 162 -- the defect this capture was carrying)
  # ================================================================================================
  # On 2026-09-25 this capture ran while the device reset itself TWICE, and every reading after the
  # first reset was taken on a phone that was still coming up. It did not notice, and there was no
  # way for it to notice: the identity was read once, at the top, put in a variable, and then carried
  # -- so FOURTEEN readings (`04c` through `04o`, plus `07`) went into a directory named for a boot
  # that no longer existed, and the last nine of them were taken on a boot that had been up for 98
  # SECONDS. Eight of those nine answered `rc=1`, because a node that a boot has not yet created and a
  # node that does not exist print THE SAME WORDS. The archive says "boot_id: <the old one>".
  #
  # So the identity is now RE-READ after every step, bounded, and a change is a first-class reading:
  #   * the step that saw it is marked in INDEX.txt, and so is every step after it;
  #   * the first change is recorded with both ids, because "which boot was it before and which after"
  #     is what makes the boundary usable rather than merely known;
  #   * and an identity that could NOT be read is `unreadable`, which is not `same`. A check whose
  #     failure mode is the passing value is not a check (the shape docs 106/107 section 6 is made of).
  #
  # It runs on BOTH kinds of step, not just the device ones: a host step here is an installer's
  # --status, and the reason to ask after it is that it is the step whose ssh could have been the last
  # thing to see the old boot.
  local bid="" bstate="same" _bf
  _bf="/tmp/.zl1-bootid.$$"
  run_bg_bound "$BOOT_CHECK_LIMIT" "${SSH[@]}" \
    'cat /proc/sys/kernel/random/boot_id 2>/dev/null' > "$_bf" 2>/dev/null
  bid=$(tr -d '\r\n' < "$_bf" 2>/dev/null); rm -f "$_bf"
  BOOT_CHECKS=$((BOOT_CHECKS + 1))
  if [ -z "$bid" ]; then
    bstate="unreadable"; BOOT_CHECK_UNREADABLE=$((BOOT_CHECK_UNREADABLE + 1))
  elif [ "$bid" != "$BOOT_ID" ]; then
    bstate="CHANGED"; BOOT_SWITCH_N=$((BOOT_SWITCH_N + 1))
    [ -z "$BOOT_SWITCH" ] && BOOT_SWITCH="$name: $BOOT_ID -> $bid"
  fi
  STEP_BOOT+=("$bstate")
  case "$bstate" in
  CHANGED)
    say "   !! THE DEVICE IS A DIFFERENT BOOT NOW (boot_id $bid). It reset itself during this step."
    say "      Every reading from here on describes THAT boot -- and the earlier readings describe"
    say "      $BOOT_ID. A probe run against a phone that is still coming up answers \"the node is"
    say "      missing\" in exactly the words a genuinely absent piece of hardware produces, so nothing"
    say "      below this line may be read as inventory until the reset is accounted for."
    ;;
  unreadable)
    say "   ?? the boot's identity could not be re-read after this step (no answer within"
    say "      ${BOOT_CHECK_LIMIT}s). That is UNREADABLE, which is not the same as the same boot, and"
    say "      the steps below it are now of unknown attribution."
    ;;
  esac
  say
  return 0
}

say "=== the boot's identity, before anything can change it ==="
# THREE THINGS ABOUT THIS BLOCK, and the third is the one that cost a boot (docs 161):
#
#   1. It is BOUNDED, like every other call. Its bound is the host backstop because there is no device-side
#      `timeout` here to sit behind -- this is a bare ssh whose remote command is a handful of reads.
#   2. A missing reading is WRITTEN DOWN as missing rather than left out. Before this, a failed ssh left
#      00-identity.txt holding four lines, one short of the two it exists to record, with nothing in the
#      file to say so -- and the file is the artefact every later reading is dated against.
#   3. And it SAYS WHICH HALF FAILED, because the two halves mean different things: `uptime`/`kernel` coming
#      back while `keeper pids` does not is a reading about a loop over /proc (the keeper walk is ~650
#      `cmdline` reads, seconds of syscall work on this SoC); nothing coming back at all is the link.
{
  printf 'boot_id: %s\n' "$BOOT_ID"
  printf 'captured: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'host: %s\n' "$(uname -sr)"
  run_bg_bound "$HOST_BACKSTOP" "${SSH[@]}" '
    printf "uptime: %s\n" "$(cat /proc/uptime | tr "\n" " ")"
    printf "kernel: %s\n" "$(uname -r)"
    printf "keeper pids: %s\n" "$(for p in /proc/[0-9]*; do [ -r "$p/cmdline" ] || continue; case "$(tr "\0" " " < "$p/cmdline")" in "/bin/sh /usr/local/sbin/zl1-debug-net.sh "*) printf "%s " "${p#/proc/}";; esac; done)"
    printf "keeper cpu ticks (utime+stime): %s\n" "$(for p in /proc/[0-9]*; do [ -r "$p/cmdline" ] || continue; case "$(tr "\0" " " < "$p/cmdline")" in "/bin/sh /usr/local/sbin/zl1-debug-net.sh "*) awk "{print \$14+\$15}" "$p/stat";; esac; done)"
    printf "failed units: %s\n" "$(systemctl --failed --no-legend 2>/dev/null | wc -l)"
  ' 2>&1
  _irc=$RB_RC
  if [ "$_irc" != 0 ]; then
    case "$_irc" in
    124) printf 'identity: NOT READ -- the host backstop ended this ssh at %ss (the link, not the phone)\n' "$HOST_BACKSTOP" ;;
    137) printf 'identity: NOT READ -- the host backstop had to SIGKILL the ssh at %ss+5s\n' "$HOST_BACKSTOP" ;;
    *)   printf 'identity: NOT READ -- the ssh exited %s\n' "$_irc" ;;
    esac
    printf 'identity: THE LINES ABOVE THIS ONE ARE THE WHOLE OF WHAT CAME BACK. keeper pids and keeper\n'
    printf 'identity: cpu ticks are MISSING, and missing is not zero -- a keeper reading is not available\n'
    printf 'identity: from this boot. See docs 161 section 2.\n'
  fi
} > "$OUT/00-identity.txt" 2>&1
# The note reflects the exit code: an unconditional "ok" is the defect this line was, and it printed "ok"
# over the exact call that hung for four minutes.
if [ "${_irc:-0}" = 0 ]; then
  note "ok   (-> 00-identity.txt)"
else
  note "PARTIAL rc=$_irc -- 00-identity.txt is SHORT and says which readings are missing"
  FAIL=$((FAIL + 1))
fi
say

# ==================================================================================================
say "=== the read-only chain, in the order that works ==="
say
# Step 0 FIRST, and before anything else in this script has touched the device: pstore only holds the
# previous oops until the next reset, and the kmsg archive is what carries that boot's early log
# forward. Nothing above this line writes to the device, which is the reason the identity block is a
# read and the steps below are ordered the way they are.
step 01-edl-postmortem   device "$HERE/../device/zl1-edl-postmortem.sh"
step 02-boot-address     device "$HERE/../device/zl1-boot-address-check.sh"
step 03-keeper-status    host   "$HERE/../install-retire-debug-keeper.sh" --status
step 04-health-check     host   "$HERE/zl1-health-check.sh"
# 04b, and it is deliberately NOT in the 05/06 probe group below. The reason 05/06 are off by default is
# specific to them: one of the two has a write mode, both are the slowest steps, and the EDL correlation
# is with the fingerprint one. The modem probe (docs 120) has no write mode at all, never opens a block
# device -- it reads MOUNT POINTS, because modemst1/modemst2/fsg/fsc/persist hold the calibration and the
# IMEI -- and needs no person. That puts it in the same class as 01 and 02, which always run.
#
# It is here rather than in the health check's prose because THIS is the script a human runs after paying
# a finger for a boot, and telephony is the one subsystem whose device reading has never been taken. Its
# own bound comes from the step runner's timeout(1), like every other device step.
step 04b-modem          device "$HERE/../device/zl1-modem-probe.sh"
# 04c, and it is in the same class as 04b for the same reasons: read-only, never opens a block device, no
# person needed. It is the SUPPLY side of the heat question (docs 121) -- whether the SoC is allowed to
# use its low-power ladder -- and it exists because the offline images say every zl1 cmdline carries
# `lpm_levels.sleep_disabled=1` while every zl1 DTB describes the full ladder it turns off. That makes the
# phone warm while it is doing NOTHING, which neither of the two heat fixes in this repository touches.
#
# It has one property no other step here has, and the header of the probe says it too: it READS files that
# ARE writable on the device (cpuidle/state*/disable, thermal_zone*/mode and policy). It writes none of
# them, its offline harness proves that byte-for-byte against a fake device, and its verdict prints what
# it read rather than acting on it. Running it cannot change the device.
step 04c-sleep-throttle device "$HERE/../device/zl1-sleep-and-throttle.sh"
# 04d, and it is in the same class again: read-only, WRITES NOTHING AT ALL -- not even a scratch file --
# and needs no person. It is the HARDWARE side of the heat question (docs 138), where 04c is the supply
# side and install-cpufreq-governor.sh is the policy side. It exists because docs 137 enumerated this
# board's hardware from its own device trees and found that the SoC's hardware thermal limiter
# (/soc/qcom,lmh) had never been read by anything in this tree, on a machine whose user asks for the
# overheating to be fixed. LMH registers no thermal zone and is not a cooling device, which is WHY every
# thermal reader here missed it, so this step is the only way the thermals section of the archive can
# ever say whether the limiter came up.
#
# Its knobs ARE root-writable (`level` is 0600) and its block sits next to the secure world, so the
# no-write property is the one thing its harness spends most of its checks on: the stub directory is the
# device, one scenario per rung of lmh_probe()'s asymmetric failure paths, and a static guard whose teeth
# are a mutation that writes the level knob.
step 04d-lmh           device "$HERE/../device/zl1-lmh-probe.sh"
# 04e, same class a fourth time: read-only, write-free, no person. docs 137 found the notification LED and
# the camera torch had never been read by anything here, and docs 139 closed both with one probe -- a
# comparison of what the device tree DECLARES against what the LED core REGISTERED, which is the only
# reading on this board that can say a driver failed to register without guessing.
#
# It is worth a slot on the boot that cost a finger because the two blocks it reads are the two a person
# uses without thinking: the charging/notification LED and the torch. Its dangerous surface is small but
# real -- every LED is drivable by writing `brightness` -- so the probe writes nothing at all and its
# offline harness spends a mutation on exactly that write.
step 04e-leds          device "$HERE/../device/zl1-leds-probe.sh"
# 04f, same class a fifth time, and this one carries a correction worth having on the boot: read-only,
# write-free, no person. docs 140 found that the inventory's `vibrator` row had been naming the LeEco
# X2's second haptics chip -- the flashed image's appended blob carries BOTH boards' device trees under
# a byte-identical root `compatible`, so this probe reads `model` BEFORE anything else and reports which
# board's tree the running kernel was handed. On a boot that picked the wrong tree, that single line
# re-reads every other reading in this archive.
#
# Its dangerous surface is the sharpest of the five: /sys/class/timed_output/vibrator/enable is
# WRITABLE, and writing a millisecond count makes the phone buzz. So the probe writes nothing at all,
# and its verdict says the buzzing test is a separate step rather than a side effect of a reading.
step 04f-vibrator      device "$HERE/../device/zl1-vibrator-probe.sh"
# 04g, same class a sixth time: read-only, write-free, no person. docs 141 closed the LARGEST gap left in
# docs 137's list -- `video-codec`, twelve device-tree nodes -- with a probe that reads BOTH halves of the
# video core: the V4L2 half (msm_vidc_v4l2 registers a decoder and an encoder at /dev/video32 and
# /dev/video33) and the firmware half (venus's PIL node, whose firmware the peripheral loader has to have
# the secure world authenticate before anything can decode).
#
# It is worth a slot for one reading in particular, and it is the reading a naive probe gets wrong: NOTHING
# LOADS THAT FIRMWARE AT BOOT. The load happens when a client opens a video instance, so an idle boot
# shows the subsystem OFFLINE and that is the healthy state -- the probe separates "not loaded" from "load
# FAILED", and prints every subsystem's state, because the same loader serves the GPU's zap shader, the
# audio DSP and the sensor DSP on this board and one line cannot tell "venus is offline" from "the boot's
# firmware is offline".
#
# Its dangerous surface is a session: opening either video node is what loads the firmware, and the vidc
# platform device's `thermal_level`/`pwr_collapse_delay` are writable. So the probe writes nothing, and its
# offline harness spends its first mutation on exactly that write.
step 04g-video         device "$HERE/../device/zl1-video-probe.sh"
# 04h, same class a seventh time: read-only, write-free, no person. docs 142 closed the next gap on docs
# 137's list -- `sdcard`, which is not ONE device but TWO controllers that are not the same kind of thing.
# /soc/sdhci@7464900 is `qcom,nonremovable` (the vendor's name for it is `sdhc1`), and /soc/sdhci@74A4900
# carries `cd-gpios` -- a card-detect line -- so it is the REMOVABLE slot, and in every one of the 38
# device trees of all three sets it is `status = "disabled"`. So on this phone an EMPTY SLOT and A SLOT
# THIS KERNEL CANNOT DRIVE produce the same reading, and the probe says which of the two it is looking at
# instead of reporting a dead card reader.
#
# Two readings make it worth a slot. The first is the disabled slot itself: it is a DEVICE-TREE decision
# inside the boot image, not a runtime fault, and knowing which one you have changes the next move
# completely. The second is that the number does NOT identify the controller -- mmc core names a host from
# the lowest free id in an idr and this driver sets PROBE_PREFER_ASYNCHRONOUS, so `mmc0` is whatever probed
# first; the probe prints each mmcN with the PARENT DEVICE its number belongs to, and tells the two
# controllers apart by the parent.
#
# Its dangerous surface is the most tempting one in this whole file: everything in sight is writable (the
# driver's `disable_slots` bitmask, `force_ro` beside every block device), and the obvious "test" -- reading
# /dev/mmcblk0 to see whether it answers -- OPENS A BLOCK DEVICE, which this project does not do on this
# phone. So the probe reads /sys/block/*/size, /proc/partitions and /proc/mounts instead, writes nothing,
# and its offline harness spends its first mutation on exactly that write.
step 04h-sdcard        device "$HERE/../device/zl1-sdcard-probe.sh"
# 04i, same class an eighth time: read-only, write-free, no person. docs 143 closed the next gap on docs
# 137's list -- `usb-pd`, and it is not one device either: it is a MENU of four CC-logic chips on two i2c
# buses plus two vendor "driver" nodes, and the device tree ENABLES exactly two of the six
# (`tusb320@67` and `cclogic_dev@3d`, both on i2c@75b5000) while the kernel has a driver for NEITHER --
# while it HAS built the two drivers for the four nodes it disables. That is a build-time disagreement
# between the device tree and the kernel config, and it is why the port's state is UNDECIDED rather than
# merely unread: /sys/class/typec/typec_device/cc_state says `none`, and `none` is ALSO the correct value
# for "nothing is plugged in", so the probe names the WRITER before it lets a reader believe the value.
#
# Its surface is small and it is still named: the one module parameter in the block is mode 0664, so it
# LOOKS writable (cclogic.c passes a NULL setter and a write is refused with -EPERM), and tusb320.c
# registers a misc device whose fops are a write-class interface. The probe writes neither, opens neither,
# and its offline harness spends its first mutation on the parameter write.
step 04i-usbpd         device "$HERE/../device/zl1-usbpd-probe.sh"
# 04j, same class a ninth time: read-only, write-free, no person. docs 144 closed the next gap on docs 137's
# list -- `hdmi` -- and this one is a GENERATION question rather than a wiring one. The block is six
# descriptions and SEVEN nodes: two transmitters (`qcom,hdmi-tx` and `qcom,hdmi-tx-8996`) claiming the SAME
# MMIO window with a byte-identical `reg`, their two audio codec-rx children, a display child, a PLL and the
# `qcom,msm-dai-q6-hdmi` DAI the inventory row's own pattern had missed. The node the TREE is explicit about
# (`status = "ok"`) is the one no driver in this 3.18 kernel can bind; the node with NO `status` property --
# which the device tree reads as ENABLED -- is the one mdss_hdmi_tx.c matches. And that driver, when it
# binds, is given ONE of the eight gpios it asks for by name, because the five the other generation's node
# carries are spelled with a `-gpio` suffix `of_get_named_gpio` never asks for.
#
# Its surface is the largest in this file: the transmitter's own sysfs group (`hot_plug`, `hpd`, `edid`,
# `sim_mode` ...) plus the framebuffer attributes behind it (`dsi_write`, `trigger_reset`, `blank`), and a
# write to `hpd` or `hot_plug` CHANGES the port's state. The probe writes neither, opens nothing, and its
# offline harness spends its first mutation on exactly that write.
step 04j-hdmi           device "$HERE/../device/zl1-hdmi-probe.sh"
# 04k, same class a tenth time: read-only, write-free, no person. docs 145 closed the next gap on docs 137's
# list -- `wfd`, the writeback / screen-mirroring block -- and like the HDMI one it is not a device but a
# description spread over nodes. The panel (`qcom,mdss_wb`) points at its framebuffer (`qcom,mdss_fb_wfd`)
# with a PHANDLE, and `mdss_register_panel()` reads that phandle from the PANEL's own node: without it the
# driver logs "Unable to find fb node for device", returns -ENODEV, and its error path UNREGISTERS the
# switch it registered a moment earlier -- which is why `/sys/class/switch/wfd` existing is an end-to-end
# witness rather than one trace among several. The numbers that size the hardware are on two OTHER nodes
# (`qcom,mdss-wb-count` on the rotator, `qcom,mdss-wb-off` and `qcom,mdss-mixer-wb-off` on mdss_mdp), and
# one of the counts is not a number at all but the STRING `qcom,mdss-wfd-mode`, read twice with two
# different consequences.
#
# Its write surface is an ioctl, not a sysfs write: `/sys/class/switch/wfd/state` is
# `DEVICE_ATTR(state, S_IRUGO, state_show, NULL)` -- a NULL store, so a shell write is refused -- and the
# value is only ever set by `mdss_mdp_wb_set_mirr_hint()` through an MDP ioctl on the framebuffer device.
# The probe writes nothing, opens no framebuffer, and its harness's write-guard teeth include a `dd` onto
# `/dev/graphics/fbN`, which is the shell's nearest thing to that ioctl.
step 04k-wfd            device "$HERE/../device/zl1-wfd-probe.sh"

# 04l-nfc: the NFC controller. ONE node (`/soc/i2c@75b6000/nq@28`, `qcom,nq-nci`) that carries TWO
# generations of property names -- the five `nfc_parse_dt()` reads, and `nxp,p61-pwr` / `nxp,p61-rst`,
# which no .c, .h or Kconfig in this tree asks for -- and the two generations do not agree about the
# wiring: the driver's power enable is a TLMM pin and the unread one is a PMIC pin.
#
# The reading this step is here for is a CONFIG LINE: `config NFC_NQ` sits in drivers/nfc/Kconfig AFTER
# the `endmenu` of the menu that `depends on NFC`, so `CONFIG_NFC` does not gate it -- and the two kernels
# this project has in hand prove it. The vendor boot image's 3.18.120 kernel has `# CONFIG_NFC is not set`
# AND `CONFIG_NFC_NQ=y` (the driver is BUILT with the menu off); the v63 Halium kernel this port boots has
# both off. The same `CONFIG_NFC` line appears in both, so a reader who checked the obvious one would get
# the same answer from a kernel that has the driver and one that does not.
#
# Its write-class move is an ioctl on the device node (`NFC_SET_PWR`, 1 = on, 2 = download mode, 0 = off),
# and the node's own read()/write() speak NCI to the chip: the probe opens no device node at all. The
# harness's write-guard teeth include a `dd` onto `/dev/pn544` for exactly that.
step 04l-nfc            device "$HERE/../device/zl1-nfc-probe.sh"

# 04m-fm: the FM receiver. ONE node (`/soc/i2c@75b5000/silabs4705@11`, `silabs,si4705`), and this step
# exists because of ONE property on it: `status = "disabled"`. Every other block this project has
# instrumented carries NO status at all -- which the device tree reads as ENABLED -- and this node is the
# exception, in all 15 LE_ZL1 trees and all three sets. A node that is not okay is never instantiated by
# the i2c core, so there is no client, no bind and no radio device, whatever the kernel was built with.
#
# AND THE OBVIOUS EXPLANATION IS WRONG: `CONFIG_RADIO_SILABS=y` in BOTH of this project's kernels, the
# vendor 3.18.120 one AND the v63 Halium one this port boots. So this is NOT the `nfc` step's shape (a
# config line outside the menu that gates it, off in the shipping kernel) -- it is the mirror image: a
# driver that is present and a TREE that refuses the node. `config RADIO_SILABS` does sit inside
# `if RADIO_ADAPTERS && VIDEO_V4L2`, which is why the probe prints the whole chain rather than one line.
#
# Its write-class move is OPENING the device node: `silabs_fm_fops_open()` powers the chip up (both
# regulators, the pinctrl active state, the three gpios) and the first ioctl writes real commands over
# i2c -- and the v4l2 core puts ONE WRITABLE attribute on every radio device,
# `/sys/class/video4linux/radioN/debug` (`DEVICE_ATTR_RW`), a verbosity knob. The probe opens no device
# node and writes nothing, and the harness's write-guard teeth include both surfaces.
step 04m-fm             device "$HERE/../device/zl1-fm-radio-probe.sh"

# 04n-eeprom: the board's calibration memory. ONE node (`/soc/i2c@75b6000/at24@51`, `atmel,24c32`), and it
# is the LAST row of docs 137's list -- and the only one whose reading is that NOTHING IS MISSING.
# `CONFIG_EEPROM_AT24=y` in BOTH kernels in hand with `CONFIG_SYSFS=y`, and the node carries no `status`,
# so the tree leaves it enabled. There is no gap for a ladder to find here; what the ladder reports is HOW
# FAR THE CHAIN RAN.
#
# THE MATCH IS THE READING, and it travels through a name the tree never spells: `at24_of_match[]` has one
# entry (`atmel,24c32`) and the i2c driver's `.name` is `at24`, so the sysfs directory is `at24` while the
# CLIENT is the compatible with the vendor prefix STRIPPED (`of_modalias_node` -> `24c32`) -- which is an
# `at24_ids[]` entry, and that entry is where the chip's size, its 16-bit address flag and its 1-byte write
# cap all come from. A zero there is `-ENODEV` before the chip is touched.
#
# Its write surface is a READ-WRITE BINARY ATTRIBUTE, `/sys/bus/i2c/devices/8-0051/eeprom`: READING it
# issues i2c transfers, and writing it writes the chip -- a chip that holds a board's calibration or serial
# data. So this probe's claim is stronger than "it writes nothing": it reads the attribute's EXISTENCE and
# none of its contents, and it never opens `/dev/i2c-8`, which is the same slave by a driverless route.
# The harness carries a second static guard for exactly that, with its own teeth.
step 04n-eeprom          device "$HERE/../device/zl1-eeprom-probe.sh"

# 04o-fp-kernel: the fingerprint blocks AT THE KERNEL LAYER -- the layer every fingerprint document in this
# project sits ABOVE (docs 83/98/101/126 are all about the store directory, the HAL and the trust store).
# This board's device tree declares TWO fingerprint blocks, `/soc/spi@7579000/goodixfp@0`
# (`goodix,fingerprint`, the Goodix sensor the container's HAL opens `/dev/goodix_fp` for) and
# `/soc/qcom,qbt1000` (an ultrasonic QBT1000 on an SSC SPI port), and the config the RUNNING kernel was built
# with -- read out of `/proc/config.gz`, i.e. out of the kernel image itself -- builds a driver for exactly
# ONE of them (`CONFIG_MSM_QBT1000=y`; `CONFIG_INPUT_GP5XX8` is NOT SET). So the answer this step produces is
# per-block and the two are OPPOSITE, which is why it exists: "there is a fingerprint driver in this kernel"
# is TRUE here and "the fingerprint sensor the HAL opens has a driver" is FALSE, and a single sentence about
# "the fingerprint driver" averages them.
#
# READ-ONLY IN THE STRONGEST SENSE THIS PROJECT HAS: it opens NO device node at all, not even to look.
# qbt1000's `open()` runs an SNS QMI open + keep-alive and then an `scm_call2(TZ_BLSP_MODIFY_OWNERSHIP)` that
# HANDS THE SPI BLSP BLOCK TO THE SECURE WORLD (release() gives it back), and secure-world calls are the
# shape that has already cost this project a boot (docs 58). Its harness carries a canary in four fake device
# nodes, so a future revision that reads one is caught by the fixture rather than by the phone.
step 04o-fp-kernel       device "$HERE/../device/zl1-fp-kernel-probe.sh"

if [ "$SKIP_PROBES" = 0 ]; then
  step 05-gps-probe        device "$HERE/../device/zl1-gps-probe.sh"
  step 06-fingerprint      device "$HERE/../device/zl1-fingerprint-probe.sh"
else
  say "-- 05/06 probes: SKIPPED (the default; --with-probes runs them). Neither has ever produced a"
  say "   fix, and the last two boots that ended in EDL both had 06 as the last thing running. That is"
  say "   a correlation of two and NOT an attribution -- nothing here has read a cause -- but the boot"
  say "   this script runs on is the one that cost a finger, so the default is the evidence above."
  say "   (04b-modem DID run, and so did 04c-sleep-throttle, 04d-lmh, 04e-leds, 04f-vibrator,"
  say "   04g-video, 04h-sdcard, 04i-usbpd, 04j-hdmi, 04k-wfd, 04l-nfc, 04m-fm, 04n-eeprom and"
  say "   04o-fp-kernel: all fourteen are read-only and write nothing, so they are not in this group.)"
  say
fi

if [ "$NO_ORIENTATION" = 0 ]; then
  # Deliberately no --portrait-up / --seconds here: those are the DECISIVE run, and it needs a person
  # holding the phone still. This is the read-only survey, so that the decisive run is a second, small
  # step rather than something to remember to do.
  step 07-orientation      device "$HERE/../device/zl1-orientation-axes.sh"
else
  say "-- 07 orientation: SKIPPED by --no-orientation"
  say
fi

# ==================================================================================================
# The one step that writes, and it is opt-in. Kept OUT of the default set even though it is the
# cheapest way to make the NEXT trip attributable (docs 89): "read-only by default" is worth more than
# the convenience, because this script's whole promise is that running it cannot change the device.
if [ "$WITH_CAPTURE" = 1 ]; then
  say "=== --with-capture: the one step that WRITES (pstore -> /userdata at every boot) ==="
  step 08-no-edl-capture   host   "$HERE/../install-no-edl-on-panic.sh" --capture-only
else
  say "=== NOT run, and it is the one that writes (opt in with --with-capture) ==="
  note "scripts/install-no-edl-on-panic.sh --capture-only"
  note "  copies /sys/fs/pstore/* onto /userdata at every boot, so the NEXT trip is attributable."
  note "  It touches no policy (--install is what writes the download_mode flag, and this does not)."
  say
fi

# ==================================================================================================
# The archive is written here (and by the signal handler above, if one arrives first).
archive

say "=== archived ==="
say "  $OUT"
say "  INDEX.txt, SHA256SUMS, and one file per step"
say "  verify with:  ( cd $OUT && sha256sum -c SHA256SUMS )"
say
if [ "$FAIL" = 0 ]; then
  # THREE outcomes, not two. `unreadable` must not fall into the same-boot sentence: an identity that
  # did not come back is not evidence that the boot stayed the same, and a verdict that says "SAME
  # BOOT" because nothing *reported* a change is the failure mode this whole section exists to avoid.
  if [ "$BOOT_SWITCH_N" = 0 ] && [ "$BOOT_CHECK_UNREADABLE" = 0 ]; then
    say "capture complete: $PASS steps ran, 0 failed, and the device was the SAME BOOT at every step"
  elif [ "$BOOT_SWITCH_N" -gt 0 ]; then
    say "capture complete: $PASS steps ran, 0 failed -- BUT THE DEVICE RESET DURING THE RUN, so the"
    say "  steps below the switch describe a DIFFERENT boot from the one this archive is named for."
  else
    say "capture complete: $PASS steps ran, 0 failed -- but $BOOT_CHECK_UNREADABLE step(s) could not"
    say "  have their identity re-read, so 'the same boot throughout' is NOT established."
  fi
else
  say "capture complete: $PASS steps ran, $FAIL FAILED (their output is archived -- read the FAIL lines above)"
fi
# The reset gets its own paragraph, because it is the one reading here that changes how EVERY OTHER
# reading is to be read, and because the failure it causes is a false negative that looks like data:
# a probe run against a boot that is still coming up says "the node is missing" (docs 162).
if [ "$BOOT_SWITCH_N" -gt 0 ]; then
  say
  say "=== THE BOOT CHANGED UNDER THIS CAPTURE ==="
  say "  first seen at:  $BOOT_SWITCH"
  say "  steps affected: $BOOT_SWITCH_N of ${#STEP_NAMES[@]} (INDEX.txt marks each one CHANGED-BOOT)"
  say "  What it means:  those steps are readings of a boot that had just started, not of $BOOT_ID."
  say "  What it does NOT mean: that anything in them says a piece of hardware is absent. On the boot"
  say "  that produced this feature, eight probes answered rc=1 after the reset and every one of them"
  say "  was reading a node the new boot had not created yet."
fi
[ "$BOOT_CHECK_UNREADABLE" -gt 0 ] && {
  say
  say "  and $BOOT_CHECK_UNREADABLE step(s) could not have their identity re-read at all (no answer in"
  say "  ${BOOT_CHECK_LIMIT}s). UNREADABLE is not 'the same boot' -- INDEX.txt says so per step."
}
say
say "What to do with it:"
say "  * 01: whether the previous boot's death is now explained (pstore), and which of the two"
say "    witnesses is available -- read its verdict, not the whole dump."
say "  * 02: 'netwatch-configured' is the licence to retire the debug keeper (docs 88/94). Anything"
say "    else means do not, and its own text says which of the three states you are in."
say "  * 03+04: the keeper's measured CPU ticks, and the state of every unit the screen and the"
say "    sensors depend on. Read the health check's own next-command line."
say
say "  Then, and only then, the steps that WRITE -- each one is the operator's call, not this script's:"
say "      scripts/install-fingerprint-store-dir.sh --status     # read-only; then --install (docs 106)"
# The two halves of the panic installer are named SEPARATELY, and the reason is the whole point of this
# boot: --capture-only writes the pstore archive, and --install ALSO writes the policy that turns a panic
# into a reboot instead of a trip into EDL. Only the second one OUTLASTS this boot, which makes it the
# one write here that buys something for every future boot rather than for this one -- and it is
# prerequisite A of the LPM ladder trial (docs 122), whose own refusal says a hang must not cost a
# finger. This line said `--capture-only # or --with-capture above` and nothing else, i.e. the advice
# pointed at the half that does NOT arm the policy, on the one boot where arming it is nearly free.
# Doc 86's caution is carried with it rather than dropped: it lowers a probability, it does not remove
# the path, and nothing here may be cited as "EDL can no longer happen".
say "      scripts/install-no-edl-on-panic.sh --capture-only     # evidence only: pstore -> /userdata"
say "      scripts/install-no-edl-on-panic.sh --install          # ALSO the policy: download_mode -> 0 at"
say "                                                            # every boot. THIS IS THE HALF THAT"
say "                                                            # OUTLASTS THE BOOT -- the only write in"
say "                                                            # this list that makes the NEXT boot"
say "                                                            # safer, and prerequisite A of the LPM"
say "                                                            # ladder trial (docs 122). It LOWERS a"
say "                                                            # probability and does not remove the path"
say "                                                            # (docs 86); never cite it as \"EDL can no"
say "                                                            # longer happen\"."
say "      scripts/install-retire-debug-keeper.sh --install      # only if 02 said netwatch-configured"

[ "$FAIL" = 0 ]
