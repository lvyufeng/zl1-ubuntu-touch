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
#
#   --outdir DIR        where to archive (default: repo tmp-post-recovery-<utc timestamp>/)
#   --with-capture      ALSO run install-no-edl-on-panic.sh --capture-only (a device write; opt-in)
#   --skip-probes       skip the GPS and fingerprint probes (they are the slowest steps, and neither
#                       has ever produced a fix, so on a boot where the evidence above matters more
#                       they are the ones to drop)
#   --no-orientation    skip the orientation-axes probe (it needs a person holding the phone still)
#
# Exit codes:
#   0  everything in the set ran and every step's own verdict was acceptable
#   1  the capture completed but at least one step failed (its output is still archived -- read it)
#   2  the device is not reachable (EDL, no link, no SSH): NOTHING was run
#
# Env: ZL1_HOST (default root@10.15.19.82), ZL1_SERIAL (default 33e80afe)

set -uo pipefail

HOST="${ZL1_HOST:-root@10.15.19.82}"
DEV="${ZL1_SERIAL:-33e80afe}"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$HOST")
SCP=(scp -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10)

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)

OUT=""
WITH_CAPTURE=0
SKIP_PROBES=0
NO_ORIENTATION=0

while [ $# -gt 0 ]; do
  case "$1" in
  --outdir) OUT="${2?--outdir needs a DIRECTORY}"; shift 2 ;;
  --with-capture) WITH_CAPTURE=1; shift ;;
  --skip-probes) SKIP_PROBES=1; shift ;;
  --no-orientation) NO_ORIENTATION=1; shift ;;
  --help|-h)
    # The header, whatever its current length -- not a fixed line range, which silently truncates the
    # usage text every time the header grows (the defect docs 104 records, in two other scripts).
    awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; exit 0 ;;
  *) echo "unknown argument ${1:-} (try --help)" >&2; exit 2 ;;
  esac
done

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
  for d in /sys/bus/usb/devices/*/; do
    if [ "$(cat "$d/serial" 2>/dev/null)" = "$DEV" ]; then echo present; return; fi
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
  local out="$OUT/$name.txt"
  say "-- $name"
  STEP_NAMES+=("$name")
  local rc=0
  case "$kind" in
  device)
    local base; base=$(basename "$src")
    "${SCP[@]}" "$src" "$HOST:/tmp/$base" >/dev/null 2>&1 || rc=90
    if [ "$rc" = 0 ]; then
      "${SSH[@]}" "sh /tmp/$base $*" > "$out" 2>&1 || rc=$?
    else
      printf 'could not copy %s to the device\n' "$base" > "$out"
    fi
    ;;
  host)
    bash "$src" "$@" > "$out" 2>&1 || rc=$?
    ;;
  esac
  STEP_RC+=("$rc")
  STEP_FILES+=("$(basename "$out")")
  if [ "$rc" = 0 ]; then
    PASS=$((PASS + 1)); note "ok   ($(wc -l < "$out") lines -> $(basename "$out"))"
  else
    FAIL=$((FAIL + 1)); note "FAILED rc=$rc -- its output is still archived, read it"
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
  "${SSH[@]}" '
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

if [ "$SKIP_PROBES" = 0 ]; then
  step 05-gps-probe        device "$HERE/../device/zl1-gps-probe.sh"
  step 06-fingerprint      device "$HERE/../device/zl1-fingerprint-probe.sh"
else
  say "-- 05/06 probes: SKIPPED by --skip-probes (they have never produced a fix; the evidence above"
  say "   is the part that only exists on this boot)"
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
# The archive. An index and a SHA256SUMS, because the point of the directory is that it is the record
# of a boot that cannot be revisited -- and a record nobody can check the integrity of is a liability
# the next time someone asks "did that really say that".
{
  printf '# zl1 post-recovery capture\n'
  printf 'boot_id: %s\n' "$BOOT_ID"
  printf 'device: %s (serial %s)\n' "$HOST" "$DEV"
  printf 'captured: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'with_capture: %s   skip_probes: %s   no_orientation: %s\n' "$WITH_CAPTURE" "$SKIP_PROBES" "$NO_ORIENTATION"
  printf '\n# step                 rc   file\n'
  i=0
  while [ "$i" -lt "${#STEP_NAMES[@]}" ]; do
    printf '%-20s %3s   %s\n' "${STEP_NAMES[$i]}" "${STEP_RC[$i]}" "${STEP_FILES[$i]}"
    i=$((i + 1))
  done
  printf '\n# every step is read-only except 08-no-edl-capture, which only runs with --with-capture\n'
} > "$OUT/INDEX.txt"
( cd "$OUT" && sha256sum ./*.txt 2>/dev/null > SHA256SUMS )

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
say "      scripts/install-no-edl-on-panic.sh --capture-only     # or --with-capture above"
say "      scripts/install-retire-debug-keeper.sh --install      # only if 02 said netwatch-configured"

[ "$FAIL" = 0 ]
