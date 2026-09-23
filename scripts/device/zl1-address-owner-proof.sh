#!/bin/sh
# zl1 address-owner proof -- make the netwatch prove, on this device, that it can configure rndis0.
#
# Why this exists (docs 112, and the gate in docs 88/94): retiring the v63 debug keeper is licensed by
# `zl1-boot-address-check.sh` reading `netwatch-configured`, and that verdict needs an `ADDRS:` line
# in the netwatch log. But `ensure_addrs()` logs ONLY when an address was missing, while the keeper
# re-adds both addresses every second -- so on a keeper-alive boot the netwatch can produce that line
# only by winning a race whose window is under a second wide. `inconclusive` is therefore the EXPECTED
# verdict on most boots, and re-running the boot re-rolls the race rather than retrying anything.
#
# The race exists only BECAUSE the keeper is there. In the configuration the gate is actually asking
# about -- a boot with no keeper -- nothing else configures the interface, so `addrs_ok` is false at
# the first sample that sees rndis0 and the ADDRS line is deterministic. This script puts the device
# into that configuration for a few seconds, on purpose, and watches what happens:
#
#   1. SIGSTOP the keeper. It cannot configure anything while stopped, and SIGCONT is instant.
#   2. Take ONE address off the interface -- 192.168.2.15/24, never the SSH address (see below).
#   3. Watch for the address to come back, and for a NEW `ADDRS:` line. Only the netwatch could have
#      done it: the only other writer on this device is stopped.
#   4. ALWAYS undo: resume the keeper, and re-add the address here if the netwatch did not.
#
# Three things are deliberately NOT configurable:
#
#  * The address removed is a literal in this file. `10.15.19.82/24` is the one the host reaches SSH
#    over (ZL1_HOST=root@10.15.19.82, scripts/install-netwatch-service.sh) and no flag can reach it.
#    Even in the case this is written to avoid -- someone SSHed in on the other address -- the
#    exposure is bounded: the detached revert timer below and the keeper's own 1 Hz loop each put it
#    back within about a second.
#  * The keeper cannot stay stopped. A detached `sleep; kill -CONT` is armed BEFORE the SIGSTOP, with
#    a margin past the wait, so a dropped SSH session, a `kill -9` of this script, or a host that
#    vanishes does not leave the device without an address provider. Resuming it early is harmless: a
#    second SIGCONT on a running process does nothing.
#  * Nothing is installed, no unit is written, no partition is read or written, and the boot path is
#    untouched. After a reboot the keeper is running again regardless -- there is nothing persistent
#    in this script, by design.
#
# What it proves, and what it does not. It proves the INSTALLED build's address path runs and works on
# this device with nothing else in the way -- the mechanism the retirement depends on. It is not a
# boot: it does not prove the unit starts early enough on a real boot, and it does not prove the host
# resolves the pair. One boot with the keeper retired is still the only thing that proves those, and
# this is what makes that boot a measured step instead of a gamble.
#
# A FAILED proof right after an install is expected and is diagnosed rather than just reported: the
# installer does NOT restart the running watchdog (docs 111), so the process in memory can still be
# the old build while the file on disk has `ensure_addrs()`. The output prints both, and says which
# one it thinks you are looking at.
#
# Usage: zl1-address-owner-proof.sh --yes [--wait SECONDS] [--quiet]
#   --yes            required: this stops a process and removes an address
#   --wait SECONDS   how long to give the netwatch to react (default 30)
#   --quiet          the verdict only
#
# Exit codes: 0 = proof-obtained; 1 = proof-unclear or proof-failed (read the reason); 2 = not armed
# (wrong device, no interface, no netwatch, or the address could not be removed) -- and in every one
# of those cases the keeper was never stopped and nothing was left changed.

set -u

PROBE_ADDR=192.168.2.15/24      # the one this script takes away. The other address is never touched.
KEEP_ADDR=10.15.19.82/24        # the SSH address (ZL1_HOST). Named so the rule above is legible.
LOG=/userdata/zl1-netwatch.log
INST=/etc/systemd/system/zl1-netwatch.sh
KEEPER_NAME=zl1-debug-net.sh
HZ=100                          # this kernel's USER_HZ, as scripts/device/zl1-boot-address-check.sh assumes

QUIET=0
WAIT=30
YES=0
while [ $# -gt 0 ]; do
  case "$1" in
  --yes)   YES=1; shift ;;
  --quiet) QUIET=1; shift ;;
  --wait)  WAIT="${2?--wait needs a SECONDS argument}"; shift 2 ;;
  --help|-h)
    # The header whatever its length, not a fixed line range (docs 104).
    awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done
case "$WAIT" in
*[!0-9]*|"") echo "--wait needs a whole number of seconds, got '$WAIT'" >&2; exit 2 ;;
esac
[ "$WAIT" -ge 5 ] || { echo "--wait below 5 s cannot see a 2 s sample loop; refusing" >&2; exit 2; }
# The gate on the whole idea: this stops a process on a live device and takes an address off the
# interface SSH arrives through the same netdev as. Nothing below runs without an explicit --yes.
[ "$YES" = 1 ] || {
  echo "refusing without --yes: this SIGSTOPs the debug keeper and removes $PROBE_ADDR from rndis0 for up to ${WAIT}s" >&2
  echo "  Read the header for what it undoes and why the keeper cannot stay stopped." >&2
  exit 2
}

say() { [ "$QUIET" = 1 ] && return 0; printf '%s\n' "$*"; }
always() { printf '%s\n' "$*"; }

# Everything the cleanup touches is initialised here, because `set -u` would abort inside the trap
# otherwise -- and a trap that aborts is a keeper left stopped and an address left missing.
IFACE=""
KEEPER_PIDS=""
STOPPED=""
REMOVED=0
VERDICT_RC=2

addr_present() {  # -> 0 if $PROBE_ADDR is on $IFACE right now
  case " $(ip -4 addr show dev "$IFACE" 2>/dev/null | awk '/inet /{printf "%s ", $2}') " in
  *" $PROBE_ADDR "*) return 0 ;;
  *) return 1 ;;
  esac
}

# The undo path, and the reason this script is safe to run at all. It runs on every exit -- normal,
# interrupted, or after an error -- and it is idempotent, because `stty`-shaped traps are not the only
# way to reach it twice.
cleanup() {
  [ -n "$IFACE" ] || return 0
  if [ "$REMOVED" = 1 ] && ! addr_present; then
    always ""
    always "== undo: the address is STILL missing -- putting $PROBE_ADDR back here"
    ip addr add "$PROBE_ADDR" dev "$IFACE" 2>/dev/null
    if addr_present; then
      always "   restored by this script (so the probe failed, but the interface is as it was)"
    else
      always "   COULD NOT restore it. The keeper is about to be resumed and re-adds it within a"
      always "   second; if this line is the last thing you see, check the link from the host."
    fi
  fi
  for kp in $STOPPED; do
    kill -CONT "$kp" 2>/dev/null
  done
  if [ -n "$STOPPED" ]; then
    say "   keeper resumed:$(for kp in $STOPPED; do printf ' %s(%s)' "$kp" "$(awk '{print $3}' "/proc/$kp/stat" 2>/dev/null)"; done)"
  fi
  return 0
}

trap 'cleanup' 0
trap 'always "interrupted -- undoing"; exit 130' 1 2 15

# --- 1. identity and the two things that must be here --------------------------------------------

model="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null | tr -d '\n')"
case "$model" in
*LE_ZL1*) always "zl1 address-owner proof :: device $model, uptime $(cut -d' ' -f1 /proc/uptime 2>/dev/null)s" ;;
*) always "== WARNING: device-tree model is \"$model\", not LE_ZL1. Stop."; exit 2 ;;
esac

for i in rndis0 usb0; do
  [ -e "/sys/class/net/$i" ] && { IFACE="$i"; break; }
done
if [ -z "$IFACE" ]; then
  always "   no rndis0/usb0 interface: the gadget is not bound, so there is nothing to prove yet."
  exit 2
fi

nw_pid=""
for p in /proc/[0-9]*; do
  c=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
  case "$c" in *zl1-netwatch.sh*) nw_pid="${p#/proc/}"; break ;; esac
done
if [ -z "$nw_pid" ]; then
  always "   the netwatch is NOT RUNNING, and it is the thing under test. Install it first:"
  always "     scripts/install-netwatch-service.sh --yes --ssh"
  exit 2
fi

if ! ip -4 addr show dev "$IFACE" 2>/dev/null | awk '/inet /{print $2}' | grep -qx "$PROBE_ADDR"; then
  always "   $PROBE_ADDR is not on $IFACE, so there is nothing to take away. The interface currently"
  always "   has: $(ip -4 addr show dev "$IFACE" 2>/dev/null | awk '/inet /{printf "%s ", $2}')"
  always "   Wait for the keeper to settle and run this again."
  exit 2
fi

say "== interface $IFACE, netwatch pid $nw_pid"

# A running `sh` executes the script it started with, and the installer deliberately does not restart
# the watchdog (docs 111) -- so after an install the process in memory can be the old build while the
# file on disk is the new one. Both numbers come from the same clock, so their ORDER is meaningful
# even though this device's absolute time is not trustworthy; that order is what is reported, and it
# is a warning and not a refusal, because a wrong clock could make the comparison meaningless and a
# refusal that can never clear is worse than a measurement that explains itself.
if [ -r "$INST" ]; then
  if grep -q '^ensure_addrs()' "$INST"; then
    say "   installed build has ensure_addrs()"
  else
    always "   the INSTALLED build has no ensure_addrs(): it cannot configure the addresses, so this"
    always "   probe can only fail. Re-install first (scripts/install-netwatch-service.sh --yes)."
    exit 2
  fi
  inst_m="$(stat -c %Y "$INST" 2>/dev/null || echo "")"
  nw_st="$(awk '{ sub(/^[^)]*\) /, ""); print $20 }' "/proc/$nw_pid/stat" 2>/dev/null)"
  up="$(cut -d. -f1 /proc/uptime 2>/dev/null)"
  if [ -n "$inst_m" ] && [ -n "$nw_st" ] && [ -n "$up" ]; then
    nw_age=$(( up - nw_st / HZ ))
    nw_epoch=$(( $(date +%s) - nw_age ))
    # Two coarse timestamps, both floored to the second, and `nw_age` is itself floored (uptime to
    # seconds, starttime to ticks/100) -- so the pair carries about a second of slop either way. The
    # threshold is therefore 2 s, not 1: a real install-then-reboot gap is minutes, while a 1 s
    # difference is indistinguishable from the rounding.
    if [ "$inst_m" -ge "$(( nw_epoch + 2 ))" ]; then
      say "   the installed file is NEWER than the running process ($((inst_m - nw_epoch))s newer):"
      say "   the watchdog in memory is the OLD build, so expect this to fail. A reboot loads the new"
      say "   one; then run this again."
    else
      say "   the running process started after the installed file was written (age ${nw_age}s) -- it"
      say "   should be the new build."
    fi
  fi
else
  always "   $INST is not readable from here, so the installed build could not be checked."
fi

# --- 2. the keeper ---------------------------------------------------------------------------------

for p in /proc/[0-9]*; do
  c=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
  case "$c" in *"$KEEPER_NAME"*) KEEPER_PIDS="$KEEPER_PIDS ${p#/proc/}" ;; esac
done

if [ -z "$KEEPER_PIDS" ]; then
  always ""
  always "   the debug keeper is NOT running. That is the configuration being asked about, so the"
  always "   measurement below is the real one -- anything that restores the address from here on is"
  always "   the netwatch, because there is nothing else."
else
  say ""
  say "   keeper:$(for kp in $KEEPER_PIDS; do printf ' %s' "$kp"; done) -- stopping it for at most ${WAIT}s"
fi

# The log offset, taken BEFORE anything changes. A line that was already in the file is not evidence,
# and the log is the only place the netwatch says what it did.
off_before=0
if [ -r "$LOG" ]; then
  off_before=$(wc -c < "$LOG" 2>/dev/null || echo 0)
else
  always "   $LOG is not readable: the ADDRS line cannot corroborate anything, and this run will"
  always "   have to rest on the address itself coming back."
fi

# --- 3. arm, stop, remove --------------------------------------------------------------------------

# Armed BEFORE the SIGSTOP, and detached with setsid so it survives this script being killed or the
# SSH session dropping. This is the whole reason the keeper cannot be left stopped.
REVERT_AFTER=$(( WAIT + 60 ))
for kp in $KEEPER_PIDS; do
  if command -v setsid >/dev/null 2>&1; then
    setsid sh -c "sleep $REVERT_AFTER; kill -CONT $kp 2>/dev/null" >/dev/null 2>&1 &
  else
    sh -c "sleep $REVERT_AFTER; kill -CONT $kp 2>/dev/null" >/dev/null 2>&1 &
  fi
done
[ -n "$KEEPER_PIDS" ] && say "   a self-revert is armed: whichever way this script ends, the keeper is resumed within ${REVERT_AFTER}s even if nobody is watching"

for kp in $KEEPER_PIDS; do
  kill -STOP "$kp" 2>/dev/null || always "   could not SIGSTOP pid $kp"
done

# Read the state back. A SIGSTOP that did not land must not be assumed to have landed -- the whole
# measurement rests on the keeper not being able to configure anything from here on (docs 107).
if [ -n "$KEEPER_PIDS" ]; then
  sleep 1
  for kp in $KEEPER_PIDS; do
    case "$(awk '{print $3}' "/proc/$kp/stat" 2>/dev/null)" in
    T) STOPPED="$STOPPED $kp" ;;
    *) always "   pid $kp is NOT stopped (state $(awk '{print $3}' "/proc/$kp/stat" 2>/dev/null)) -- aborting rather than measuring a lie"
       exit 2 ;;
    esac
  done
  say "   keeper stopped and read back:$(for kp in $STOPPED; do printf ' %s=T' "$kp"; done)"
fi

say ""
say "== removing $PROBE_ADDR from $IFACE (KEEP_ADDR $KEEP_ADDR is not touched, by construction)"
ip addr del "$PROBE_ADDR" dev "$IFACE" 2>/dev/null
if addr_present; then
  always "   the address is STILL there after 'ip addr del' -- nothing was proven, and the keeper is"
  always "   about to be resumed."
  exit 2
fi
REMOVED=1
t_removed=$(cut -d. -f1 /proc/uptime 2>/dev/null)
say "   gone (uptime ${t_removed}s). Watching for up to ${WAIT}s..."

# --- 4. wait for the only other writer on the device ------------------------------------------------

came_back=0
n=0
while [ "$n" -lt "$WAIT" ]; do
  sleep 1
  n=$((n + 1))
  if addr_present; then came_back=$(( n )); break; fi
done

# --- 5. the log, read once ------------------------------------------------------------------------

# ONE linear pass, no accumulator (docs 108), and anchored to the byte offset taken before anything
# changed -- so an ADDRS line from an earlier boot, or from earlier in this one, cannot be counted.
new_line=""
if [ -r "$LOG" ]; then
  new_line=$(awk -v off="$off_before" '
    { if (n >= off && /ADDRS:/) { print; exit } n += length($0) + 1 }
  ' "$LOG" 2>/dev/null)
fi

say ""
say "== what happened while the keeper was stopped"
if [ "$came_back" != 0 ]; then
  say "   the address was back ${came_back}s after it was removed."
else
  always "   the address did NOT come back within ${WAIT}s."
fi
if [ -n "$new_line" ]; then
  say "   new ADDRS line: $new_line"
elif [ -r "$LOG" ]; then
  always "   no new ADDRS line in $LOG."
else
  say "   $LOG was not readable, so there is no line to show."
fi

# --- 6. verdict ------------------------------------------------------------------------------------

if [ "$came_back" != 0 ] && [ -n "$new_line" ]; then
  VERDICT_RC=0
  always ""
  always "== verdict: proof-obtained"
  always "   With the only other writer on this device stopped, the netwatch noticed $PROBE_ADDR was"
  always "   missing and put it back (${came_back}s), and said so in its log. The address path of the"
  always "   INSTALLED build runs and works here, which is what docs 88 needed before the keeper can"
  always "   be retired."
  always "   Still not a boot: this does not show the unit starts early enough on a real boot, and it"
  always "   does not show the host resolves the pair. The keeper-less boot is that test."
elif [ "$came_back" != 0 ]; then
  VERDICT_RC=1
  always ""
  always "== verdict: proof-unclear (exit 1)"
  always "   The address came back with the keeper stopped, but the netwatch logged NO new ADDRS line"
  always "   about it. Something restored it, and the netwatch is the only writer that should have --"
  always "   so either this build restores without logging (an older one: check the installed file's"
  always "   ensure_addrs, above), or the log is not where this script is looking. Do not treat this"
  always "   as proof until the line is there."
else
  VERDICT_RC=1
  always ""
  always "== verdict: proof-failed (exit 1)"
  if [ -n "$new_line" ]; then
    always "   The netwatch LOGGED an ADDRS line, but the address is not on $IFACE -- it noticed and"
    always "   its restore did not stick. That is a different failure from a silent one: read"
    always "   restore_addrs() in scripts/device/zl1-netwatch.sh and the line above."
  else
    always "   The netwatch neither restored $PROBE_ADDR nor logged trying. In order of likelihood:"
    always "   1. it is running the OLD build (the installer does not restart it -- see the age line"
    always "      above) -- reboot, which loads the new one, and run this again;"
    always "   2. it is not sampling at all (its unit is dead, or it is inside a heal), which the"
    always "      netwatch log's own sample lines will show."
  fi
fi

say ""
say "   Undo runs now regardless of the verdict: the keeper is resumed and the address is put back"
say "   if it is still missing. Nothing here survives a reboot."
exit "$VERDICT_RC"
