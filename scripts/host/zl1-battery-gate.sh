#!/usr/bin/env bash
# Read the one number the whole remaining port is gated on: can this phone be powered on?
#
# Why this exists (docs 149, 150):
#
#   Every clause left in this project -- the two heat fixes running on hardware, the fingerprint store
#   directory, the modem, the camera, the orientation swap -- is gated on ONE boot, and that boot is
#   gated on ONE reading. The zl1's LK exposes exactly two battery variables (`battery-voltage` and
#   `battery-soc-ok`) and NOTHING in this tree read either of them: measured, `grep -rn battery-soc-ok
#   scripts/` matched no script at all. So the decision that costs the most if it is wrong was being
#   made from prose -- which is the exact shape this repo keeps converting into an instrument.
#
#   And the decision really is expensive on both sides. Powering on a genuinely flat pack can brown out
#   during the /data mount, which is one of the few ways to actually damage this device's eMMC. Not
#   powering on when the pack is fine spends a boot that costs a physical 10-20 s power hold to get back.
#
# What it measures, and what it REFUSES to claim:
#
#   It samples `battery-voltage` and `battery-soc-ok` N times over a window and reports the readings, the
#   min/max band and the trend. **`battery-voltage` IS IN MICROVOLTS** -- LK reports 2773000, which is
#   2.773 V, so the raw number is divided before anything is compared to anything (a script that compares
#   the raw figure against a millivolt threshold is off by 1000x, and the tree has already been bitten
#   once by a rate printed in 100x its unit, docs 104). The verdict is a DECISION TABLE, not a threshold
#   on one number:
#
#     soc-ok: yes at ANY sample                  -> CAN-BOOT     LK itself says the pack is OK
#     the LAST reading is above the earlier ones' band by >= NOISE_MV -> CHARGING   this port is winning
#     the LAST reading is below that band by >= NOISE_MV              -> DISCHARGING this port is LOSING
#     otherwise                                  -> FLAT WITHIN NOISE  not a direction
#
#   The rule is about the LAST reading against the RANGE the EARLIER ones established, and NOT about a
#   line fitted through the window. That is not a stylistic choice: the first version of this script
#   compared first-to-last and immediately reported DISCHARGING on a 4-second window whose own scatter
#   (2.921 -> 2.810, a 111 mV band) fully explained the 111 mV it called a trend. A trend that the
#   window's own band accounts for is a reading of the noise, and the fix is to require the final
#   reading to leave the earlier range by the margin rather than merely to differ from the first one.
#
#   Three refusals are built in, because each of them is a way a reading gets mistaken for an answer:
#
#   1. A SINGLE SAMPLE IS NOT A VERDICT. This LK's readings were measured swinging 148 mV across three
#      consecutive samples of an unchanged pack (2.773 - 2.921 V), which is wider than any trend a short
#      window could show. So --samples has a floor of 3, the noise band is PRINTED next to the trend, and
#      a trend smaller than --noise-mv is reported as FLAT rather than as a direction. An instrument that
#      reads noise as a slope is worse than one that says nothing.
#   2. A PARTIAL READ IS NOT A READ. If fewer samples came back than were asked for, the state is
#      UNREADABLE (exit 3) and NO verdict is printed -- never a slope computed over the survivors.
#   3. THE PORT IS PART OF THE ANSWER. The USB port path is read and printed with the readings, because
#      "this port does not net-charge it" and "this pack is dead" are different claims, and only the
#      first one is supported by a flat window measured on one port. The comparison that separates them
#      is a SECOND window on a DIFFERENT charger.
#
# The device is identified by SERIAL PREFIX (33e80afe), never by a bare USB id: an unrelated Xiaomi
# (serial 4a2fe00b, `18d1:4ee7`, product string MI 4LTE) shares this bus and is reported and ignored.
#
# READ-ONLY, and it says so out loud. It never boots, reboots, flashes, writes a partition, runs a
# downloader, or runs any QDL/firehose tool. It only calls `fastboot getvar`, which is a question.
#
# TWO FACTS ABOUT THIS DEVICE THAT CHANGE THE RIGHT ACTION (measured 2026-09-24, `getvar all`):
#   off-mode-charge:0          -- it does NOT charge in off mode; plugging a charger into a powered-off
#                                 zl1 makes it BOOT instead. So "power it off and charge it overnight"
#                                 is WRONG HERE, and it is the first thing anyone would try.
#   charger-screen-enabled:0   -- there is NO charging screen. A pack too low to boot looks simply
#                                 BLACK, with no indicator at all, so a black screen is not evidence
#                                 that the device is dead. Read this script instead of guessing.
#
# Usage: zl1-battery-gate.sh [--samples N] [--interval SECS] [--noise-mv N] [--quiet]
#   --samples N      how many readings to take (default 5, floor 3 -- see refusal 1)
#   --interval SECS  seconds between readings (default 15; the window is (N-1) x interval)
#   --noise-mv N     the trend that counts as a direction rather than as noise (default 100)
#   --quiet          print the verdict and the advice, not the sample table
#
# Exit codes:
#   0  a verdict was reached (CAN-BOOT, CHARGING, DISCHARGING or FLAT)
#   2  refused: bad argument, no zl1 on the bus, or the device is in EDL
#   3  UNREADABLE: the device is there but the readings did not come back -- NOT a pass
#
# What this NEVER does: boot, reboot, flash, write, erase, or run any downloader tool. If it says
# CAN-BOOT, powering on is still a person's decision and still needs that person's approval.

set -uo pipefail
export LC_ALL=C

SERIAL="${ZL1_SERIAL:-33e80afe}"
# The other phone on this bus. Named here so a report can say it was seen and skipped.
OTHER_SERIAL="${ZL1_OTHER_SERIAL:-4a2fe00b}"
EDL_ID=05c6:9008
SAMPLES=5
INTERVAL=15
NOISE_MV=100
QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
  --samples) SAMPLES="${2?--samples needs a number}"; shift 2 ;;
  --interval) INTERVAL="${2?--interval needs seconds}"; shift 2 ;;
  --noise-mv) NOISE_MV="${2?--noise-mv needs a number}"; shift 2 ;;
  --quiet) QUIET=1; shift ;;
  --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0" ; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

case "$SAMPLES"  in ''|*[!0-9]*) echo "error: --samples needs a whole number, got '$SAMPLES'" >&2; exit 2 ;; esac
case "$INTERVAL" in ''|*[!0-9]*) echo "error: --interval needs a whole number of seconds, got '$INTERVAL'" >&2; exit 2 ;; esac
case "$NOISE_MV" in ''|*[!0-9]*) echo "error: --noise-mv needs a whole number of millivolts, got '$NOISE_MV'" >&2; exit 2 ;; esac

# The floor is the point of refusal 1: two samples give a direction with no way to tell it from noise,
# and this LK's noise was measured WIDER than the trends worth acting on.
if [ "$SAMPLES" -lt 3 ]; then
  echo "error: --samples $SAMPLES is too few. This LK's readings were measured swinging about 120 mV" >&2
  echo "       between consecutive samples of an unchanged pack, so a two-sample slope is mostly noise." >&2
  echo "       The floor is 3; the default is 5." >&2
  exit 2
fi
if [ "$SAMPLES" -gt 60 ]; then
  echo "error: --samples $SAMPLES is beyond what a person will sit through; the ceiling is 60." >&2
  exit 2
fi

say()  { [ "$QUIET" = 1 ] && [ -n "${1:-}" ] && return 0; printf '%s\n' "$*"; }
adv()  { printf '%s\n' "$*"; }

if ! command -v fastboot >/dev/null 2>&1; then
  echo "REFUSED: no fastboot(1) on this host -- the battery variables live in the bootloader, so there" >&2
  echo "         is nothing to read. This is a HOST problem, not a reading about the device." >&2
  exit 2
fi

# --- is the device there at all, and in which mode? ------------------------------------------------
# Same three ways of being unreachable as the chain's own check, and the same order: EDL first, because
# EDL has NO SERIAL NUMBER, so a serial lookup finds nothing while a vendor-id lookup finds a phone that
# cannot answer. Then the serial PREFIX match over the host's USB tree.
MODE=absent
if timeout 10 lsusb -d "$EDL_ID" >/dev/null 2>&1; then
  MODE=edl
else
  for d in /sys/bus/usb/devices/*/; do
    case "$(cat "$d/serial" 2>/dev/null)" in
    "$SERIAL"*) MODE=present; break ;;
    esac
  done
fi
# The other phone, reported so nobody wonders whether it was confused for the target.
OTHER=no
for d in /sys/bus/usb/devices/*/; do
  case "$(cat "$d/serial" 2>/dev/null)" in
  "$OTHER_SERIAL"*) OTHER=yes; break ;;
  esac
done

say "zl1 battery gate"
say "  looking for serial prefix: $SERIAL"
say "  the other phone (serial $OTHER_SERIAL): $([ "$OTHER" = yes ] && echo 'present on the bus, IGNORED -- never identified by USB id' || echo 'not on the bus')"
say

case "$MODE" in
edl)
  say "REFUSED: the device is in Qualcomm EDL ($EDL_ID / QDL mode)."
  say
  say "  There is no serial number in EDL and no downloader tool may be run here."
  say "  NOT QFIL. NOT QSaharaServer. NOT fh_loader."
  say "  THE NEXT MOVE IS PHYSICAL: long-press POWER for 10-20 s, wait for RNDIS and ssh."
  exit 2
  ;;
absent)
  say "REFUSED: no device on this bus carries the serial prefix '$SERIAL'."
  say
  say "  Two ordinary reasons, and they need different moves:"
  say "    - the device is powered off, OR"
  say "    - the battery is flat enough that LK never brought the USB gadget up."
  say
  say "  IMPORTANT: on THIS device, powering it off does not charge it (off-mode-charge:0), and there"
  say "  is no charging screen (charger-screen-enabled:0) -- so a flat pack looks simply BLACK. If you"
  say "  powered it off to charge it, that cannot work here: plug the charger in and it will boot."
  exit 2
  ;;
present) ;;
*)
  say "REFUSED: the device-mode check produced no answer at all (MODE='$MODE'), which is not a pass." >&2
  exit 2
  ;;
esac

# Which fastboot target is it? `fastboot devices -l` gives the serial AND the port path, and the port is
# part of the answer (refusal 3): a flat window measured on ONE charger does not license "the pack is
# dead", only "this port does not net-charge it".
DEVLINE=$(timeout 20 fastboot devices -l 2>/dev/null | grep -m1 "^$SERIAL" || true)
PORT=$(printf '%s\n' "$DEVLINE" | sed -n 's/.* usb:\([^ ]*\).*/\1/p' | sed -n '1p')
case "$DEVLINE" in
"") say "REFUSED: the USB tree shows serial prefix '$SERIAL' but fastboot does not list it."
    say "  That is a real state (the gadget is up but not in fastboot), and it is not a battery reading:"
    say "  the two variables this script reads live in the BOOTLOADER, so a booted Ubuntu Touch answers"
    say "  neither. Nothing here is a reading about the pack."
    exit 2 ;;
esac
say "  fastboot target: $SERIAL   port: ${PORT:-unknown}"

# --- sample it -------------------------------------------------------------------------------------
RAW=""
OKN=0
i=1
while [ "$i" -le "$SAMPLES" ]; do
  V=$(timeout 20 fastboot -s "$SERIAL" getvar battery-voltage 2>&1 | sed -n 's/^battery-voltage: *//p' | sed -n '1p')
  S=$(timeout 20 fastboot -s "$SERIAL" getvar battery-soc-ok 2>&1 | sed -n 's/^battery-soc-ok: *//p' | sed -n '1p')
  case "$V" in ''|*[!0-9]*) V="" ;; esac
  case "$S" in yes|no) ;; *) S="" ;; esac
  if [ -n "$V" ] && [ -n "$S" ]; then
    RAW="$RAW$i $V $S
"
    OKN=$((OKN + 1))
  else
    RAW="$RAW$i - -
"
  fi
  i=$((i + 1))
  [ "$i" -le "$SAMPLES" ] && sleep "$INTERVAL"
done

# Volts, printed from the microvolts LK actually reports. Every number a person reads goes through this,
# so no threshold can be compared against the raw figure by accident.
fmtv() { awk -v u="$1" 'BEGIN{ if (u == "") { print "?" } else { printf "%.3f V", u / 1000000 } }'; }
# The noise threshold arrives in millivolts, because that is the unit a person reasons in; the arithmetic
# below is in LK's microvolts.
NOISE_UV=$(( NOISE_MV * 1000 ))

say
say "  the readings (this LK exposes NO current and NO charge-rate variable, only these two, and"
say "  battery-voltage is in MICROVOLTS -- 2773000 is 2.773 V):"
say "    #   voltage    soc-ok"
printf '%s' "$RAW" | while read -r n v s; do
  [ -z "${n:-}" ] && continue
  if [ "$v" = "-" ]; then say "    $n   (did not answer)"
  else say "    $n   $(fmtv "$v")      $s"; fi
done
say

# Refusal 2: a partial read is NOT a read. No slope is computed over the survivors.
if [ "$OKN" -ne "$SAMPLES" ]; then
  say "UNREADABLE: $OKN of $SAMPLES readings came back."
  say
  say "  No verdict is printed, and no slope is computed from the $OKN that did: a trend over whichever"
  say "  samples happened to answer is a reading of the link, not of the pack. This is NOT a pass and"
  say "  NOT a bad battery -- it is a question that went unanswered."
  say "  The usual cause is a USB link that dropped mid-window; re-run it."
  exit 3
fi

# --- the decision table ----------------------------------------------------------------------------
read -r FIRST_N FIRST_V FIRST_S <<EOF
$(printf '%s' "$RAW" | sed -n '1p')
EOF
read -r LAST_N LAST_V LAST_S <<EOF
$(printf '%s' "$RAW" | tail -n1)
EOF
BANDV=$(printf '%s' "$RAW" | awk '{print $2}' | sort -n | sed -n '1p')
BANDH=$(printf '%s' "$RAW" | awk '{print $2}' | sort -n | tail -n1)
BAND=$(( BANDH - BANDV ))
TREND=$(( LAST_V - FIRST_V ))
# The EARLIER readings' range, which is what the last one has to leave by the margin. `sed '$d'` drops the
# final line and reads to EOF, so it cannot turn a writer's SIGPIPE into this script's answer. (It is
# deliberately NOT `sed -n '$d'`: with auto-print suppressed a bare `d` prints nothing at all, which is
# correct sed and was measured here -- that empty string is what made the FIRST version of this script
# report CHARGING out of nothing, because bash arithmetic reads an empty operand as 0. The guard below is
# the real fix; the correct sed is the second half.)
EARLY=$(printf '%s' "$RAW" | sed '$d')
EMIN=$(printf '%s' "$EARLY" | awk '{print $2}' | sort -n | sed -n '1p')
EMAX=$(printf '%s' "$EARLY" | awk '{print $2}' | sort -n | tail -n1)
ABOVE=$(( LAST_V - EMAX ))
BELOW=$(( EMIN - LAST_V ))
WINDOW=$(( (SAMPLES - 1) * INTERVAL ))

# THE GUARD. Every operand the verdict turns on has to BE a number before any arithmetic runs on it:
# bash reads an empty operand as 0, so a failed extraction does not fail -- it invents a reading, and the
# invented one here was a 2847 mV "rise" that printed a CHARGING verdict. `LAST_V - EMAX` with an empty
# EMAX is exactly that, and it is the same shape as a host-side timeout arriving as an empty string and
# being printed as a verdict about the phone.
for _v in FIRST_V LAST_V EMIN EMAX BANDV BANDH; do
  eval "_x=\${$_v}"
  case "$_x" in
  ''|*[!0-9]*)
    say "UNREADABLE: the extraction of $_v produced '[$_x]', which is not a number."
    say
    say "  No verdict is printed. Bash arithmetic reads an empty operand as ZERO, so carrying on would"
    say "  not fail -- it would invent a reading, and the first version of this script did exactly that:"
    say "  an empty earlier-range made a flat window print a CHARGING verdict. This is NOT a pass and"
    say "  NOT a bad battery -- it is a defect in this script's own extraction, and it is named here so"
    say "  it cannot be mistaken for a measurement."
    exit 3
    ;;
  esac
done

say "  window: $WINDOW s ($SAMPLES readings every ${INTERVAL}s)"
say "  first: $(fmtv "$FIRST_V") (soc-ok $FIRST_S)   last: $(fmtv "$LAST_V") (soc-ok $LAST_S)"
say "  band:  $(fmtv "$BANDV") - $(fmtv "$BANDH")  = $(( BAND / 1000 )) mV of swing across the window"
say "  earlier readings' range: $(fmtv "$EMIN") - $(fmtv "$EMAX")  (the last one must LEAVE this by"
say "  >= ${NOISE_MV} mV for its direction to be a reading rather than noise; first-to-last is"
say "  $(( TREND / 1000 )) mV, which the band alone can explain)"
say

# soc-ok is LK's own answer and it outranks the arithmetic in BOTH directions: it is the bootloader
# saying it will let the device boot, and no slope over 60 s overrides that. Read through `sort -u`, not
# through an early-exiting reader: under `set -o pipefail` a `grep -q` that quits on its first match
# reports the WRITER's SIGPIPE, so the answer would be the death of the printer rather than the reading.
SOCS=$(printf '%s' "$RAW" | awk '{print $3}' | sort -u | tr '\n' ' ')
case "$SOCS" in *yes*) SOCYES=yes ;; *) SOCYES=no ;; esac

if [ "$SOCYES" = yes ]; then
  say "== verdict: CAN-BOOT"
  say "   soc-ok read 'yes' at least once in this window -- that is LK's own answer, and it is the"
  say "   bootloader saying it will allow the boot. The $(( TREND / 1000 )) mV trend is secondary to it."
  say
  say "   What this is NOT: a claim that the pack is healthy, or a licence to boot. Powering on is a"
  say "   person's decision and needs that person's approval -- and the pack should still be on a"
  say "   charger when it happens, because the first thing the boot does is mount /data."
  exit 0
fi

if [ "$ABOVE" -ge "$NOISE_UV" ]; then
  say "== verdict: CHARGING"
  say "   soc-ok is still 'no' ($OKN/$SAMPLES), but the LAST reading ($(fmtv "$LAST_V"))"
  say "   is $(( ABOVE / 1000 )) mV ABOVE the highest of the earlier ones ($(fmtv "$EMAX")), so it left"
  say "   their range by the margin -- that is a direction, not the window's own scatter, and this port"
  say "   is winning."
  say
  say "   DO NOT POWER IT OFF. On THIS device, off-mode-charge is 0: it does not charge in off mode, and"
  say "   plugging a charger into a powered-off zl1 makes it BOOT instead. Leave it as it is, on the"
  say "   charger, and re-run this script -- the number to watch is soc-ok going to 'yes'."
  exit 0
fi

if [ "$BELOW" -ge "$NOISE_UV" ]; then
  say "== verdict: DISCHARGING"
  say "   soc-ok is 'no' and the LAST reading ($(fmtv "$LAST_V")) is $(( BELOW / 1000 )) mV"
  say "   BELOW the lowest of the earlier ones ($(fmtv "$EMIN")), so it left their range by the margin"
  say "   -- that is a direction, not the window's own scatter. This port is LOSING."
  say
  say "   The port is part of the answer: this is a statement about THIS port, not about the pack. A"
  say "   laptop port can be current-limited below what this device draws in fastboot, and the measured"
  say "   history here is exactly that shape -- 3.586 V with soc-ok 'yes', then 0.81 V lost over about"
  say "   2.5 hours while attached to a laptop."
  say
  say "   NEXT MOVE: a WALL CHARGER, then re-run this script. And DO NOT power it off to charge it:"
  say "   off-mode-charge is 0 on this device, so it will not charge off -- it will just boot."
  say "   If a wall charger also loses ground, the question stops being about software."
  exit 0
fi

say "== verdict: FLAT WITHIN NOISE"
say "   soc-ok is 'no' and the LAST reading ($(fmtv "$LAST_V")) did not leave the earlier readings'"
say "   range ($(fmtv "$EMIN") - $(fmtv "$EMAX")) by the ${NOISE_MV} mV margin this script needs. The"
say "   window's own scatter was $(( BAND / 1000 )) mV, which is the same order as the $(( TREND / 1000 ))"
say "   mV first-to-last difference -- so that difference is explained by the noise and is not a trend."
say
say "   What that means, stated as narrowly as the reading allows: an unchanged-or-noise-level window on"
say "   port ${PORT:-unknown}. It is NOT evidence that the pack is dead, and it is NOT evidence that it"
say "   is charging. Those two are separated by a comparison this run cannot make by itself."
say
say "   NEXT MOVE: put it on a WALL CHARGER and re-run with a LONGER window (--samples 9 --interval 60"
say "   is 8 minutes). A rise bigger than ${NOISE_MV} mV on the wall charger answers the question; so"
say "   does soc-ok going to 'yes'. And DO NOT power it off to charge it -- off-mode-charge is 0 here,"
say "   so it will not charge off, it will boot."
exit 0
