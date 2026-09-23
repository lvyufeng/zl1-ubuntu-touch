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
#   3. the log counts, **split by which process could have written each string** -- three of the eight
#      patterns used to be counted in logcat although they live in the UT-side daemon, whose messages
#      go to the journal, so their count was structurally 0 and read as "the provider was never
#      instantiated" (docs 102; section 3 below and evidence/gps-log-owners-2026-09-23.log)
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
  # The header is lines 1-43 (Usage is the last of them); line 45 is `set -u`. The range used to run
  # to 46, i.e. past the header into the variable assignments, so --help printed `set -u` and
  # `TEST_GPS=0` as if they were usage. scripts/host/zl1-gps-selftest.sh now asserts --help prints no
  # `set -u`, so the range cannot drift again unnoticed.
  --help|-h) sed -n '2,43p' "$0"; exit 0 ;;
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
  # The delimiter is `|`, not `/`: with `/`, the slash inside the REPLACEMENT ends the s command and
  # sed exits 1 with "unknown option to `s'" -- so this reading printed a sed error instead of a
  # value, and the wifi/cell switch was the one number this section never showed. (Found by
  # scripts/host/zl1-gps-selftest.sh, which is the only reason it is not still that way.)
  /usr/bin/lomiri-location-serviced-cli does_report_wifi_and_cell_ids get 2>&1 | sed 's|^|   wifi/cell: |'
  if [ "$QUIET" = 0 ]; then
    echo "   (its usage, verbatim, so a wrong subcommand above is visible as such:)"
    /usr/bin/lomiri-location-serviced-cli --help 2>&1 | head -12 | sed 's/^/   | /'
  fi
else
  echo "   /usr/bin/lomiri-location-serviced-cli missing"
fi

# --- 3. logcat: the branches in the source, not guesses ----------------------------------------

# **A string can only appear in the log of the process that contains it**, so the counts below are
# split by owner. This is not cosmetic. Of this section's eight patterns, TWO were counted in logcat
# although they live in the UT-side daemon, whose messages go to the journal -- so their count was
# structurally 0, and a 0 here reads as "the provider was never instantiated", which points the whole
# diagnosis at the wrong layer; and TWO were counted although the string is in no binary in any image,
# so their 0 was never evidence about anything. The other five are journal-side patterns that the
# previous version did not look for at all, i.e. the half of this chain that was never being counted.
# Where each string was found (offline, by grepping the images this port ships -- evidence:
# docs/ubuntu-touch/evidence/gps-log-owners-2026-09-23.log):
#
#   logcat (a process in the Android container)
#     libloc_api_v02.so                     locClientOpen failed
#                                           Failed to get features supported
#     android.hardware.gnss@1.0-impl-qti.so gnssSetCapabilitesCb
#   journal (a process on the UT side -- the daemon, or the library it loads)
#     /usr/bin/lomiri-location-serviced     Issue instantiating provider:
#                                           Instantiating and configuring
#     liblomiri-location-service.so.3       Remote service failed to start
#                                           Failed to inject reference time to chipset
#                                           ...providers/gps/android_hardware_abstraction_layer.cpp
#   neither, and that is why they are gone:
#     'set_gps_service_callbacks'   a SYMBOL name; the string is in no binary in any image. A count of
#                                   0 for it was never evidence about anything.
#     'Unable to get GPS service'   lives in libandroid_servers.so, i.e. the framework's
#                                   GnssLocationProvider -- Android's own location provider, which the
#                                   UT daemon does not go through (it calls IGnss::getService() HIDL
#                                   directly). Even where that library is present its 0 says nothing
#                                   about this path.

echo "== the log, split by which process could have written it (this device has no working RTC --"
echo "   docs 69 -- so ordering is not trustworthy; these are COUNTS, which do not depend on order)"
if [ -n "$A" ]; then
  dump=$(nsenter -t "$A" -p -m -- /system/bin/logcat -d -v brief 2>/dev/null)
  echo "   --- logcat (the container's vendor GPS HAL) ---"
  for pat in 'locClientOpen failed' \
             'Failed to checking QMI_LOC message supported' \
             'Failed to get features supported' \
             'gnssSetCapabilitesCb'; do
    printf '   %-46s %s\n' "$pat" "$(printf '%s\n' "$dump" | grep -ac "$pat")"
  done
  echo "   -- the last 8 logcat lines that mention gps/gnss/LocSvc:"
  printf '%s\n' "$dump" | grep -aiE 'gps|gnss|LocSvc' | tail -8 | cut -c1-140 | sed 's/^/   | /'
else
  echo "   --- logcat: skipped (no container: lxc-info gave nothing) ---"
fi

# The UT side. `journalctl -b -u` is boot-scoped rather than time-scoped, which is the only kind of
# journal query that survives a wrong clock; the counts are order-independent for the same reason.
echo "   --- journal of $UNIT (the daemon itself and the library it loads) ---"
jdump=$(journalctl -b -u "$UNIT" --no-pager -o cat 2>/dev/null)
if [ -z "$jdump" ]; then
  echo "   (empty or unreadable -- if the unit is active but this is empty, that itself is the finding:"
  echo "    the daemon writes its provider and HAL messages to stderr, which systemd journals)"
fi
for pat in 'Issue instantiating provider' \
           'Instantiating and configuring' \
           'Remote service failed to start' \
           'Failed to inject reference time' \
           'android_hardware_abstraction_layer'; do
  printf '   %-46s %s\n' "$pat" "$(printf '%s\n' "$jdump" | grep -ac "$pat")"
done
# The three gates of TrustStorePermissionManager (see zl1-location-request.sh for the model). Gate 1
# is a true short circuit, so a grant shows up as gates 2/3 being *absent*, not as a line of their
# own; gate 3's failure is the trust-store library's own message. Both are stderr -> journal.
for pat in 'Missing agent implementation' \
           'Cannot operate without an agent implementation' \
           'Client lacks permissions to access the service with the given criteria' \
           'Cannot create service for null permission manager'; do
  printf '   %-46s %s\n' "$pat" "$(printf '%s\n' "$jdump" | grep -ac "$pat")"
done
echo "   -- and the daemon's own environ, where gate 1's switch lives:"
# The value is captured before it is printed: `tr | grep | sed || echo "absent"` reports SED's status,
# which is 0 even when grep matched nothing, so the "absent" line could never be reached.
if [ -n "${dpid:-}" ]; then
  tsv=$(tr '\0' '\n' < "/proc/$dpid/environ" 2>/dev/null \
        | grep -a 'TRUST_STORE_PERMISSION_MANAGER_IS_RUNNING_UNDER_TESTING')
  if [ -n "$tsv" ]; then
    printf '     %s\n' "$tsv"
    echo "     -> gate 1 IS short-circuited: the trust store is not consulted at all (this is the"
    echo "        image's own bypass, and the only way it gets set on this port is a drop-in, because"
    echo "        the wrapper's getprop is the v63 stub -- see zl1-location-request.sh)"
  else
    echo "     (absent: gate 1 is NOT short-circuited, so the trust store decides)"
  fi
else
  echo "     (no daemon pid from section 1)"
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
