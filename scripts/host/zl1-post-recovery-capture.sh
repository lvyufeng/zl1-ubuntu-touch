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
declare -a STEP_NAMES=() STEP_RC=() STEP_FILES=()

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
      printf '%-20s %3s   %s\n' "${STEP_NAMES[$i]}" "$rc_i" "$f_i"
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
RB_RC=0
run_bg() {
  "$@" &
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
    run_bg "${SCP[@]}" "$src" "$HOST:/tmp/$base" >/dev/null 2>&1 || rc=90
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
      run_bg "${SSH[@]}" "
        if command -v timeout >/dev/null 2>&1; then
          timeout -k 5 $STEP_LIMIT sh /tmp/$base $args
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
    run_bg bash "$src" "$@" > "$out" 2>&1
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
    case "$rc" in
    124) note "        ^ that is timeout(1): the step did not finish in ${STEP_LIMIT}s. This is NOT a" \
              ; note "          verdict, it is a hung device-side script -- check the load in 04." ;;
    137) note "        ^ that is timeout(1) -k: it had to be SIGKILLed at ${STEP_LIMIT}s+5s." ;;
    esac
    # The verdict that matters is usually the last non-empty line, and printing it here is the
    # difference between "something failed" and knowing what without opening a file.
    grep -av '^[[:space:]]*$' "$out" 2>/dev/null | tail -3 | sed 's/^/        | /'
  fi
  say
  return 0
}

say "=== the boot's identity, before anything can change it ==="
{
  printf 'boot_id: %s\n' "$BOOT_ID"
  printf 'captured: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'host: %s\n' "$(uname -sr)"
  run_bg "${SSH[@]}" '
    printf "uptime: %s\n" "$(cat /proc/uptime | tr "\n" " ")"
    printf "kernel: %s\n" "$(uname -r)"
    printf "keeper pids: %s\n" "$(for p in /proc/[0-9]*; do [ -r "$p/cmdline" ] || continue; case "$(tr "\0" " " < "$p/cmdline")" in "/bin/sh /usr/local/sbin/zl1-debug-net.sh "*) printf "%s " "${p#/proc/}";; esac; done)"
    printf "keeper cpu ticks (utime+stime): %s\n" "$(for p in /proc/[0-9]*; do [ -r "$p/cmdline" ] || continue; case "$(tr "\0" " " < "$p/cmdline")" in "/bin/sh /usr/local/sbin/zl1-debug-net.sh "*) awk "{print \$14+\$15}" "$p/stat";; esac; done)"
    printf "failed units: %s\n" "$(systemctl --failed --no-legend 2>/dev/null | wc -l)"
  ' 2>&1
} > "$OUT/00-identity.txt" 2>&1
note "ok   (-> 00-identity.txt)"
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

if [ "$SKIP_PROBES" = 0 ]; then
  step 05-gps-probe        device "$HERE/../device/zl1-gps-probe.sh"
  step 06-fingerprint      device "$HERE/../device/zl1-fingerprint-probe.sh"
else
  say "-- 05/06 probes: SKIPPED (the default; --with-probes runs them). Neither has ever produced a"
  say "   fix, and the last two boots that ended in EDL both had 06 as the last thing running. That is"
  say "   a correlation of two and NOT an attribution -- nothing here has read a cause -- but the boot"
  say "   this script runs on is the one that cost a finger, so the default is the evidence above."
  say "   (04b-modem DID run, and so did 04c-sleep-throttle, 04d-lmh, 04e-leds, 04f-vibrator,"
  say "   04g-video, 04h-sdcard and 04i-usbpd: all eight are read-only and write nothing, so they are"
  say "   not in this group.)"
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
  say "capture complete: $PASS steps ran, 0 failed"
else
  say "capture complete: $PASS steps ran, $FAIL FAILED (their output is archived -- read the FAIL lines above)"
fi
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
