#!/bin/sh
# zl1 GPS probe -- read the four things that decide where the GPS line is broken. Read-only.
#
# Why these four (docs/ubuntu-touch/82): the recorded framing was "the QMI channel to the modem fails"
# because of this log line --
#
#   E/LocSvc_ApiV02(239): open:413:11]: Failed to get features supported from
#                                      QMI_LOC_GET_SUPPORTED_FEATURE_REQ_V02.
#
# -- and that is a misreading. In the HAL source (device/leeco/msm8996-common/location/
# loc_api/loc_api_v02/LocApiV02.cpp) that message is logged inside the `else` branch of
# `locClientOpen()`, i.e. **it can only appear when the QMI client opened successfully**, and the
# failure is neither fatal nor returned: `open()` sets rtv = FAILURE in exactly one place, the
# `locClientOpen` failure branch, which logs "locClientOpen failed, status = ...". So the question is
# not "does the QMI channel work" but "did that other line ever appear", and the action that has never
# happened is `gnssStart` / `u_hardware_gps_start` -- which only runs once somebody asks for a
# position.
#
# Hence, in order of how cheap they are:
#
#   1. what the unit actually executes, and where the daemon actually runs
#      (`systemctl cat` is the only honest check that the drop-in wrapper is in effect)
#   2. the two switches the UT side has, read through its own client tool:
#      `does_satellite_based_positioning` and `does_report_wifi_and_cell_ids`. The tool cannot request
#      a position -- that is the point of reading it first: if satellite positioning is `false`, that
#      alone explains a HAL that was never started
#   3. the logcat counts, including the discriminating `locClientOpen failed` and the two other
#      branches in the same function
#   4. whether the GNSS HIDL service is even registered (`lshal`), read from inside the container
#
# Nothing here writes: no property is set, no service is restarted, no /sys write, no file written
# outside /tmp. The one exception is `--test-gps`, which starts one GPS tracking session through
# /usr/bin/test_gps -- reversible, and it is off by default on purpose (it is the hardware half and
# belongs in its own run).
#
# Note on `test_gps`: it goes through the legacy gps.h HAL (hw_get_module("gps")), while the UT daemon
# goes through HIDL android.hardware.gnss@1.0 (vendor.qti.gnss@1.0-service -> LocSvc_ApiV02). They
# are not guaranteed to be the same implementation, so a success or a failure here does not translate
# by itself.
#
# Usage (on the device, as root): zl1-gps-probe.sh [--test-gps] [--seconds N] [--quiet]

set -u

TEST_GPS=0
SECONDS_=25
QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
  --test-gps) TEST_GPS=1; shift ;;
  --seconds) SECONDS_="${2?--seconds needs a number}"; shift 2 ;;
  --quiet) QUIET=1; shift ;;
  --help|-h) sed -n '2,48p' "$0"; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

grep -qa msm8996 /proc/device-tree/compatible 2>/dev/null ||
  { echo "not the zl1 (no msm8996 in /proc/device-tree/compatible) -- refusing" >&2; exit 1; }

A=$(lxc-info -n android -pH 2>/dev/null | head -1)
UNIT=lomiri-location-service

echo "zl1 GPS probe :: $(date) :: read-only$([ "$TEST_GPS" = 1 ] && echo ' + one test_gps tracking session')"

# --- 1. the unit and where the daemon runs -----------------------------------------------------

echo "== unit $UNIT"
if systemctl cat "$UNIT" >/tmp/zl1-gps-probe.unit 2>/dev/null; then
  grep -a '^ExecStart' /tmp/zl1-gps-probe.unit | sed 's/^/   /'
  # The drop-in is what points ExecStart at the android-aware wrapper. Print which file it came from.
  grep -aoE '/[^ ]*\.service\.d/[^ ]*\.conf' /tmp/zl1-gps-probe.unit | sort -u | sed 's/^/   drop-in: /'
else
  echo "   (systemctl cat failed -- unit not found?)"
fi
systemctl is-active "$UNIT" 2>/dev/null | sed 's/^/   ActiveState: /'
[ "$QUIET" = 1 ] || systemctl status "$UNIT" --no-pager -n 5 2>/dev/null | sed 's/^/   | /'

# The daemon's comm is truncated to 15 chars, so match the prefix, not the whole name.
dpid=$(for p in /proc/[0-9]*; do
         c=$(cat "$p/comm" 2>/dev/null)
         case "$c" in lomiri-location*) echo "${p#/proc/}"; break ;; esac
       done)
if [ -n "$dpid" ]; then
  echo "== daemon pid $dpid  ns/pid $(readlink /proc/$dpid/ns/pid 2>/dev/null)"
  if [ -n "$A" ]; then
    echo "   container  pid $A  ns/pid $(readlink /proc/$A/ns/pid 2>/dev/null)"
    if [ "$(readlink /proc/$dpid/ns/pid 2>/dev/null)" = "$(readlink /proc/$A/ns/pid 2>/dev/null)" ]; then
      echo "   -> the daemon runs IN the container's PID namespace (what binder/hwbinder needs)"
    else
      echo "   -> the daemon is in the HOST namespace: it cannot see the container's hwbinder services"
    fi
  fi
  echo "   environ (the ones that matter):"
  tr '\0' '\n' < "/proc/$dpid/environ" 2>/dev/null |
    grep -aE '^(HYBRIS|LD_PRELOAD|ANDROID|TMPDIR|PATH=)' | sed 's/^/     /'
else
  echo "== daemon: not running (no comm matching lomiri-location*)"
fi

# --- 2. the two switches the UT side has -------------------------------------------------------

echo "== switches (lomiri-location-serviced-cli -- it cannot request a position, only read/set these)"
if [ -x /usr/bin/lomiri-location-serviced-cli ]; then
  /usr/bin/lomiri-location-serviced-cli does_satellite_based_positioning get 2>&1 | sed 's/^/   satellite: /'
  /usr/bin/lomiri-location-serviced-cli does_report_wifi_and_cell_ids get 2>&1 | sed 's/^/   wifi/cell: /'
  if [ "$QUIET" = 0 ]; then
    echo "   (its usage, verbatim, so a wrong subcommand above is visible as such:)"
    /usr/bin/lomiri-location-serviced-cli --help 2>&1 | head -12 | sed 's/^/   | /'
  fi
else
  echo "   /usr/bin/lomiri-location-serviced-cli missing"
fi

# --- 3. logcat: the branches in the source, not guesses ----------------------------------------

echo "== container logcat (whole ring buffer, so pre-change lines are in here too)"
if [ -n "$A" ]; then
  dump=$(nsenter -t "$A" -p -m -- /system/bin/logcat -d -v brief 2>/dev/null)
  # Every string below is a literal from the C++ on this device (docs 82 section 1), the four from
  # docs 56's status check (kept, so the two tools agree), and the GPS service acquisition pair.
  for pat in 'locClientOpen failed' \
             'Failed to checking QMI_LOC message supported' \
             'Failed to get features supported' \
             'Unable to get GPS service' \
             'set_gps_service_callbacks' \
             'gnssSetCapabilitesCb' \
             'Instantiating and configuring' \
             'Issue instantiating provider'; do
    printf '   %-48s %s\n' "$pat" "$(printf '%s\n' "$dump" | grep -ac "$pat")"
  done
  echo "   -- the last 8 lines that mention gps/gnss/location:"
  printf '%s\n' "$dump" | grep -aiE 'gps|gnss|LocSvc|location' | tail -8 | cut -c1-140 | sed 's/^/   | /'
else
  echo "   (no container: lxc-info gave nothing)"
fi

# --- 4. properties and the HIDL service --------------------------------------------------------

echo "== Android properties (read INSIDE the container: the host's getprop is a stub)"
if [ -n "$A" ]; then
  for prop in custom.location.fake custom.location.lat custom.location.lon custom.location.testing; do
    v=$(nsenter -t "$A" -p -- /system/bin/getprop "$prop" 2>/dev/null | tr -d '\r')
    printf '   %-28s %s\n' "$prop" "${v:-<unset>}"
  done
fi

echo "== GNSS HIDL service registration (lshal, inside the container -- it needs -p and -m)"
if [ -n "$A" ]; then
  nsenter -t "$A" -p -m -- lshal 2>/dev/null | grep -ai 'gnss' | head -8 | sed 's/^/   /'
  n=$(nsenter -t "$A" -p -m -- lshal 2>/dev/null | grep -aci 'gnss')
  [ "$n" -gt 0 ] || echo "   (no gnss service registered)"
fi

echo "== /etc/gps.conf (XTRA servers only -- no SUPL lines; affects AGPS, not standalone)"
if [ -r /etc/gps.conf ]; then
  md5sum /etc/gps.conf 2>/dev/null | sed 's/^/   /'
  [ "$QUIET" = 1 ] || sed 's/^/   | /' /etc/gps.conf
else
  echo "   (absent)"
fi

# --- 5. optional: the hardware half ------------------------------------------------------------

if [ "$TEST_GPS" = 1 ]; then
  echo "== /usr/bin/test_gps -c  (starts one tracking session; legacy gps.h HAL, not the HIDL one)"
  if [ -x /usr/bin/test_gps ] && [ -n "$A" ]; then
    O=/tmp/zl1-gps-probe.test_gps
    # The same three things the camera path needs: the container's PID namespace, the TLS-slot preload
    # (bionic's TLS_SLOT_THREAD_ID is never filled in a glibc host), and hybris' library path with the
    # egl dirs and /userdata/zl1-hybris/lib in front.
    nsenter -t "$A" -p -- timeout "$SECONDS_" env \
      HYBRIS_LD_LIBRARY_PATH=/vendor/lib64/egl:/system/lib64/egl:/odm/lib64/egl:/userdata/zl1-hybris/lib:/system/lib64:/odm/lib64:/vendor/lib64 \
      LD_PRELOAD=/usr/lib/aarch64-linux-gnu/libtls-padding.so \
      /usr/bin/test_gps -c > "$O" 2>&1
    echo "   exit=$?  (124 = still tracking when the ${SECONDS_}s timer fired)"
    grep -avE '^c+$|^tlsfix2 ' "$O" | head -30 | sed 's/^/   | /'
  else
    echo "   (no /usr/bin/test_gps, or no container)"
  fi
fi
