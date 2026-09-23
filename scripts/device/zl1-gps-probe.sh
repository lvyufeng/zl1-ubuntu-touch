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
#   4. whether the GNSS HIDL service is even registered (`lshal`), read from inside the container.
#      The first capture could not read this, because nothing in THIS REPO recorded what lshal's
#      columns mean. The image's own build tree does: /mnt/data/halium-zl1-build/frameworks/native/
#      cmds/lshal, whose literals are verbatim in the built liblshal.so. That turns "the service is
#      registered" from a guess into a reading (docs 110), and section 4 below states the three rules
#      it is built on -- chiefly that `hash`, and therefore the R column, is assigned in exactly one
#      place, fetchBinderizedEntry(), i.e. lshal's FIRST table only.
#
# And then it states a VERDICT (section 6), because the first real capture archived all nine sections
# and nobody could say what they added up to. The verdict is built from the section-3 counts --
# strings that provably belong to the process whose log they are read out of -- plus the one section-4
# registration reading, and it names which rung of the chain the evidence stops at. It exits 0 only
# when the chain demonstrably reaches the container's vendor GPS HAL -- a positive finding about the
# layers above it, not a claim that GPS produces a fix.
#
# Nothing here writes: no property is set, no service is restarted, no /sys write, no file written
# outside /tmp. The one exception is `--test-gps`, which starts one GPS tracking session through
# /usr/bin/test_gps -- reversible, and it is off by default on purpose (it is the hardware half and
# belongs in its own run).
#
# Note on the optional hardware probe: it goes through the legacy gps.h HAL (hw_get_module("gps")),
# while the UT daemon goes through HIDL android.hardware.gnss@1.0 (vendor.qti.gnss@1.0-service ->
# LocSvc_ApiV02). They are not guaranteed to be the same implementation, so a success or a failure
# there does not translate by itself.
#
# Usage (on the device, as root): zl1-gps-probe.sh [--test-gps] [--seconds N] [--quiet]
#
# Exit codes: 0 = the chain reaches the container's vendor GPS HAL; 1 = a named blocker, or no evidence
# at all (section 6 says which); 2 = usage. Not the zl1 refuses with 1.

set -u

TEST_GPS=0
SECONDS_=25
QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
  --test-gps) TEST_GPS=1; shift ;;
  --seconds) SECONDS_="${2?--seconds needs a number}"; shift 2 ;;
  --quiet) QUIET=1; shift ;;
  # The header, whatever its current length -- not a fixed line range, which silently truncates the
  # usage text every time the header grows (docs 104; and this file had already drifted once, which is
  # why the older range's end is asserted against `TEST_GPS=`/`set -u` by host/zl1-gps-selftest.sh).
  --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; exit 0 ;;
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
# Captured rather than recomputed: section 6's verdict has to key on THIS reading, and a second
# readlink could disagree with the one printed above (the daemon can exec, or the container can be
# restarted between the two reads).
in_ns=unknown
if [ -n "$dpid" ]; then
  echo "== daemon pid $dpid  ns/pid $(readlink /proc/$dpid/ns/pid 2>/dev/null)"
  if [ -n "$A" ]; then
    echo "   container  pid $A  ns/pid $(readlink /proc/$A/ns/pid 2>/dev/null)"
    if [ "$(readlink /proc/$dpid/ns/pid 2>/dev/null)" = "$(readlink /proc/$A/ns/pid 2>/dev/null)" ]; then
      echo "   -> the daemon runs IN the container's PID namespace (what binder/hwbinder needs)"
      in_ns=yes
    else
      echo "   -> the daemon is in the HOST namespace: it cannot see the container's hwbinder services"
      in_ns=no
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
# Every count is captured into a variable and PRINTED FROM THAT VARIABLE, so the table and the verdict
# in section 6 cannot disagree: two places computing "the same" number is how a verdict ends up quoting a
# count that is not the one above it. `count_of` is the only place a count is produced, and the `case`
# inside each loop is what carries the number to the verdict.
#
# The two pattern LISTS stay written out as `for pat in '...' ... ; do` on purpose: they are the
# provenance table, and scripts/host/zl1-gps-selftest.sh extracts them straight out of this file to
# assert that no pattern appears in both (a string can only be written by the process that contains it).
count_of() { printf '%s\n' "$2" | grep -ac "$1"; }
n_cc_nomsg=0; n_cc_fail=0; n_cc_feat=0; n_cc_cap=0
if [ -n "$A" ]; then
  dump=$(nsenter -t "$A" -p -m -- /system/bin/logcat -d -v brief 2>/dev/null)
  echo "   --- logcat (the container's vendor GPS HAL) ---"
  for pat in 'locClientOpen failed' \
             'Failed to checking QMI_LOC message supported' \
             'Failed to get features supported' \
             'gnssSetCapabilitesCb'; do
    n=$(count_of "$pat" "$dump")
    printf '   %-46s %s\n' "$pat" "$n"
    case "$pat" in
    'locClientOpen failed')                        n_cc_fail=$n ;;
    'Failed to checking QMI_LOC message supported') n_cc_nomsg=$n ;;
    'Failed to get features supported')            n_cc_feat=$n ;;
    'gnssSetCapabilitesCb')                        n_cc_cap=$n ;;
    esac
  done
  echo "   -- the last 8 logcat lines that mention gps/gnss/LocSvc:"
  printf '%s\n' "$dump" | grep -aiE 'gps|gnss|LocSvc' | tail -8 | cut -c1-140 | sed 's/^/   | /'
  echo "   -- the UT adapter's own entry points, as the SAME dump recorded them (section 6 reads this:"
  echo "      it is the deepest rung of the chain):"
  # The prefix, not one symbol: `u_hardware_gps_*` is the UT-side adapter's whole surface, and those
  # strings live in /mnt/utrootfs/usr/lib/aarch64-linux-gnu/libubuntu_platform_hardware_api.so.4.0.0
  # (checked offline). They appear in LOGCAT rather than the journal because the container's hybris HAL
  # shim loads that same library -- which is exactly why this is NOT one of the four counted patterns
  # above: a UT-side library string is not a clean statement about either log. It is counted here, and
  # the verdict uses it only to say "the adapter was reached".
  n_adapter=$(count_of 'u_hardware_gps_' "$dump")
  printf '   %-46s %s\n' 'u_hardware_gps_* (the UT adapter, in logcat)' "$n_adapter"
else
  echo "   --- logcat: skipped (no container: lxc-info gave nothing) ---"
  n_adapter=0
fi

# The UT side. `journalctl -b -u` is boot-scoped rather than time-scoped, which is the only kind of
# journal query that survives a wrong clock; the counts are order-independent for the same reason.
echo "   --- journal of $UNIT (the daemon itself and the library it loads) ---"
jdump=$(journalctl -b -u "$UNIT" --no-pager -o cat 2>/dev/null)
if [ -z "$jdump" ]; then
  echo "   (empty or unreadable -- if the unit is active but this is empty, that itself is the finding:"
  echo "    the daemon writes its provider and HAL messages to stderr, which systemd journals)"
fi
# Captured into variables here because the verdict in section 6 keys on them (same one-source rule).
n_prov_issue=0; n_prov_inst=0; n_remote_fail=0; n_inject=0; n_ahl=0
for pat in 'Issue instantiating provider' \
           'Instantiating and configuring' \
           'Remote service failed to start' \
           'Failed to inject reference time' \
           'android_hardware_abstraction_layer'; do
  n=$(count_of "$pat" "$jdump")
  printf '   %-46s %s\n' "$pat" "$n"
  case "$pat" in
  'Issue instantiating provider')          n_prov_issue=$n ;;
  'Instantiating and configuring')         n_prov_inst=$n ;;
  'Remote service failed to start')        n_remote_fail=$n ;;
  'Failed to inject reference time')       n_inject=$n ;;
  'android_hardware_abstraction_layer')    n_ahl=$n ;;
  esac
done
# The three gates of TrustStorePermissionManager (see zl1-location-request.sh for the model). Gate 1
# is a true short circuit, so a grant shows up as gates 2/3 being *absent*, not as a line of their
# own; gate 3's failure is the trust-store library's own message. Both are stderr -> journal.
n_gate_refuse=0; n_gate_agent=0; n_gate_noagent=0; n_gate_nullpm=0
for pat in 'Missing agent implementation' \
           'Cannot operate without an agent implementation' \
           'Client lacks permissions to access the service with the given criteria' \
           'Cannot create service for null permission manager'; do
  n=$(count_of "$pat" "$jdump")
  printf '   %-46s %s\n' "$pat" "$n"
  case "$pat" in
  'Missing agent implementation')        n_gate_agent=$n ;;
  'Cannot operate without an agent implementation') n_gate_noagent=$n ;;
  'Client lacks permissions to access the service with the given criteria') n_gate_refuse=$n ;;
  'Cannot create service for null permission manager') n_gate_nullpm=$n ;;
  esac
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
p_testing=""
if [ -n "$A" ]; then
  for prop in custom.location.fake custom.location.lat custom.location.lon custom.location.testing; do
    v=$(nsenter -t "$A" -p -- /system/bin/getprop "$prop" 2>/dev/null | tr -d '\r')
    [ "$prop" = custom.location.testing ] && p_testing="$v"
    printf '   %-28s %s\n' "$prop" "${v:-<unset>}"
  done
fi

echo "== GNSS HIDL service registration (lshal, inside the container -- nsenter needs -p and -m)"
# THE READING, AND WHERE IT COMES FROM (docs 110). This section used to print the listing and refuse
# to read it, on the grounds that nothing in this tree recorded what the columns mean. That was true
# of the *output* and false of the *source*: the image's own build tree carries lshal at
# /mnt/data/halium-zl1-build/frameworks/native/cmds/lshal, and the built liblshal.so in
# android-system-zl1-halium-candidate.img contains its literals verbatim (checked: "Thread Use",
# "are you root?", "All binderized services"). So the columns are readable, and the rules are these:
#
#   * lshal prints THREE tables in this order, separated by blank lines, each introduced by a
#     description line that is a literal in liblshal.so:
#       1 "All binderized services (registered services through hwservicemanager)"
#       2 "All interfaces that getService() has ever return as a passthrough interface;"
#       3 "All available passthrough implementations (all -impl.so files)."
#   * the default columns (ListCommand.cpp: mSelectedColumns = {RELEASED, INTERFACE_NAME, THREADS,
#     SERVER_PID, CLIENT_PIDS}) are `R  Interface  Thread Use  Server  Clients`.
#   * R is TableEntry::isReleased(), and it reads `hash` -- and `hash` is assigned in exactly ONE
#     place in the whole source, fetchBinderizedEntry(), i.e. TABLE 1 ONLY. Hence:
#       row inside table 1  == hwservicemanager's list() returned that name == REGISTERED;
#       R = "Y"             == the object was fetched and answered interfaceChain() and
#                              getHashChain() over IPC == the service is live, not merely listed.
#   * table 2's own description says "The Server / Server CMD column can be ignored", which is why
#     the Server column is read here ONLY for a table-1 row.
n_gnss=0
n_binder_gnss=0
gnss_registered=unknown
gnss_answered="-"
gnss_server="-"
gnss_thread="-"
lshal_ran=0
if [ -n "$A" ]; then
  listing=$(nsenter -t "$A" -p -m -- lshal 2>/dev/null)
  [ -n "$listing" ] && lshal_ran=1
  # The whole listing is kept, not `grep gnss`: the blank lines are what separate the three tables,
  # and dropping them is what made the first capture unreadable (evidence/gps-probe-live-2026-09-23.txt).
  printf '%s\n' "$listing" | grep -ai 'gnss' | head -8 | sed 's/^/   /'
  n_gnss=$(printf '%s\n' "$listing" | grep -ac 'gnss')
  # "It listed nothing" and "it could not be asked" are different blockers, and the section-4 line and
  # the verdict both have to be able to say which one this boot is -- otherwise an absent `lshal` is
  # reported as a container with no GNSS HAL.
  [ "$lshal_ran" = 1 ] || echo "   lshal produced NO output at all: it is absent, or it cannot reach hwservicemanager"
  [ "$lshal_ran" = 1 ] && [ "$n_gnss" -eq 0 ] && echo "   (it ran, but there is no gnss entry in it)"

  reg_anchor=0
  reg_where=absent
  while IFS='=' read -r _k _v; do
    case "$_k" in
    anchor) reg_anchor="$_v" ;;
    where)  reg_where="$_v" ;;
    binder) n_binder_gnss="$_v" ;;
    rel)    gnss_answered="$_v" ;;
    srv)    gnss_server="$_v" ;;
    thr)    gnss_thread="$_v" ;;
    esac
  done <<EOF
$(printf '%s\n' "$listing" | awk -v s='android.hardware.gnss@1.0::IGnss/default' '
  /^[[:space:]]*$/ { inb = 0; next }
  /registered services through hwservicemanager/ { inb = 1; anchor = 1; next }
  {
    idx = 0
    for (i = 1; i <= NF; i++) if ($i == s) { idx = i; break }
    if (idx == 0) next
    # R is never empty, so an awk field index of 1 means the R column was the blank " " and
    # awk swallowed it with the leading whitespace.
    rel = (idx == 1) ? "-" : $1
    if (inb) { if (++hit == 1) { hrel = rel; hthr = $(idx + 1); hsrv = $(idx + 2) } }
    else     { if (++out == 1) { orel = rel; othr = $(idx + 1); osrv = $(idx + 2) } }
  }
  END {
    where = hit ? "in-table-1" : (out ? "outside-table-1" : "absent")
    rel2 = (hit ? hrel : orel); if (rel2 == "") rel2 = "-"
    srv2 = (hit ? hsrv : osrv); if (srv2 == "") srv2 = "-"
    thr2 = (hit ? hthr : othr); if (thr2 == "") thr2 = "-"
    printf "anchor=%d\nwhere=%s\nbinder=%d\nrel=%s\nsrv=%s\nthr=%s\n", \
           anchor + 0, where, hit + 0, rel2, srv2, thr2
  }')
EOF

  # The anchor line comes FIRST, before any row is believed: without it lshal's three tables cannot be
  # told apart, and `outside-table-1` would then read as "not registered" for a row that may in fact be
  # in the binderized table. A reading that cannot separate the tables must not produce either answer.
  if [ "$reg_anchor" != 1 ]; then
    gnss_registered=unknown
  else
    case "$reg_where" in
    in-table-1)      gnss_registered=yes ;;
    outside-table-1) gnss_registered=no ;;
    # With the anchor present, `absent` has exactly one meaning: the binderized table WAS found and
    # this service is not in it -- a located blocker, not an absence of evidence.
    *)               gnss_registered=no ;;
    esac
  fi

  printf '   %-16s %s\n' 'registered:' "$gnss_registered"
  case "$gnss_registered" in
  yes)
    echo "   A row for it is in lshal's FIRST table -- the one hwservicemanager fills -- and its R"
    echo "   column is '$gnss_answered': $(if [ "$gnss_answered" = Y ]; then echo 'the object was fetched and answered interfaceChain()/getHashChain(), so the service is LIVE, not just listed.'; else echo 'the hash was not read, so it answered the listing but not the hash query.'; fi)"
    printf '   %-16s %s / %s\n' 'Server/Threads:' "$gnss_server" "$gnss_thread"
    echo "   (Server is read here only because this row is in table 1; lshal's own description of"
    echo "    table 2 says its Server column can be ignored.)"
    ;;
  no)
    echo "   The service is NOT in the binderized table, so there is nothing for a HIDL request to"
    echo "   reach: $(if [ "$reg_where" = outside-table-1 ]; then echo 'it appears only OUTSIDE table 1 (a passthrough reference), which does not serve hwbinder callers.'; else echo "lshal's binderized table was found and has no row for it, while $n_gnss gnss line(s) exist elsewhere."; fi)"
    ;;
  *)
    if [ "$lshal_ran" = 1 ]; then
      echo "   lshal's three tables could not be told apart (the 'registered services through"
      echo "   hwservicemanager' anchor line is not in the listing), so registration is NOT decided"
      echo "   here. Nothing below in the verdict is allowed to build on it."
    else
      echo "   There is no listing to read: lshal produced no output at all. Registration is NOT decided"
      echo "   here, and the verdict must not read this as 'the container has no GNSS HAL'."
    fi
    ;;
  esac
  printf '   %-16s %s\n' 'gnss rows:' "$n_gnss in the listing, $n_binder_gnss in the binderized table"
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
  tg_rc=""
  if [ -x /usr/bin/test_gps ] && [ -n "$A" ]; then
    O=/tmp/zl1-gps-probe.test_gps
    # The same three things the camera path needs: the container's PID namespace, the TLS-slot preload
    # (bionic's TLS_SLOT_THREAD_ID is never filled in a glibc host), and hybris' library path with the
    # egl dirs and /userdata/zl1-hybris/lib in front.
    nsenter -t "$A" -p -- timeout "$SECONDS_" env \
      HYBRIS_LD_LIBRARY_PATH=/vendor/lib64/egl:/system/lib64/egl:/odm/lib64/egl:/userdata/zl1-hybris/lib:/system/lib64:/odm/lib64:/vendor/lib64 \
      LD_PRELOAD=/usr/lib/aarch64-linux-gnu/libtls-padding.so \
      /usr/bin/test_gps -c > "$O" 2>&1
    tg_rc=$?
    echo "   exit=$tg_rc  (124 = still tracking when the ${SECONDS_}s timer fired)"
    grep -avE '^c+$|^tlsfix2 ' "$O" | head -30 | sed 's/^/   | /'
  else
    echo "   (no /usr/bin/test_gps, or no container)"
  fi
fi

# --- 6. the verdict -----------------------------------------------------------------------------
#
# Everything above is evidence; this is the one paragraph a reader needs, and it exists because the
# first real capture (docs 108) archived all nine sections and nobody could say what they added up to --
# the run was read as "the GPS probe produced no verdict", while the sections themselves contained the
# deepest evidence this chain has ever had. An instrument that cannot state its own bottom line makes
# every reader re-derive it, and re-deriving it is where the answer was lost.
#
# The rungs are read off the COUNTS FROM SECTION 3, in the order the chain is traversed, plus the one
# reading from section 4 that is decided by lshal's own source (is the service REGISTERED). The two
# decisive log patterns live in /mnt/vendor-ro/lib64/libloc_api_v02.so, the container's vendor GPS HAL,
# so a nonzero count is proof that process ran -- and docs 82's source reading says which of the two
# means "its QMI client opened".
#
# The rungs, first match wins, and the order IS the claim:
#
#   no-container          the container does not answer -- nothing below it can be judged
#   wrong-namespace       the daemon is in the HOST PID namespace -- the chain never starts
#   trust-store-refused   a request was refused above the HAL
#   qmi-open-failed       the vendor HAL ran and its QMI client failed to open
#   reaches-vendor-hal    the vendor HAL ran, the client opened, the adapter was reached  [exit 0]
#   gnss-not-registered   nothing ran, and the listing says there is no service to call
#   no-gnss-listing       nothing ran, and there is not even a gnss row to look at
#   daemon-only           the daemon built providers; no request reached the HAL
#   no-evidence           this boot cannot say where the chain breaks
#
# `no-container` and `wrong-namespace` come before every log rung: when the container is absent (or
# invisible), no count can prove the chain ran, so quoting one would be quoting an impossible witness.
#
# Where the registration reading sits, and why: the logs say what RAN, registration says what UT can
# REACH, and a log line proving the vendor HAL ran is strictly deeper evidence than a listing -- so
# `reaches-vendor-hal` and `qmi-open-failed` come first and are not overruled by it. When the logs are
# SILENT, though, the listing is the only thing left that can name a blocker, so `gnss-not-registered`
# sits immediately above the two "nothing ran" rungs.
echo ""
echo "== verdict"
verdict=""
if [ -z "$A" ]; then
  verdict="no-container"
  echo "   The Android container does not answer (lxc-info gave nothing), so nothing in this chain can"
  echo "   be judged: every log below the UT daemon lives in that container."
elif [ "$in_ns" = no ]; then
  verdict="wrong-namespace"
  echo "   The location daemon is alive but in the HOST PID namespace, so it cannot see the container's"
  echo "   hwbinder services -- it fails before this chain starts. Fix the namespace first (docs 79)."
elif [ "$n_gate_refuse" -gt 0 ]; then
  verdict="trust-store-refused"
  echo "   A request was REFUSED by the trust store: 'Client lacks permissions to access the service"
  echo "   with the given criteria' appears $n_gate_refuse time(s), and gate 1's short-circuit switch is"
  echo "   $([ -n "${tsv:-}" ] && echo 'SET' || echo 'NOT set'). The chain stops above the HAL, so the"
  echo "   HAL's own state is not visible in this boot's log."
elif [ "$n_cc_fail" -gt 0 ]; then
  verdict="qmi-open-failed"
  echo "   The chain REACHED the container's vendor GPS HAL and its QMI client FAILED to open:"
  echo "   'locClientOpen failed' appears $n_cc_fail time(s). That is the one line in the HAL source"
  echo "   (LocApiV02.cpp) that sets the failure it returns -- so this is a real, located blocker."
elif [ "$n_cc_feat" -gt 0 ] || [ "$n_cc_cap" -gt 0 ]; then
  verdict="reaches-vendor-hal"
  echo "   The chain REACHES the container's vendor GPS HAL, and its QMI client OPENED:"
  if [ "$n_cc_feat" -gt 0 ]; then
    echo "   'Failed to get features supported' appears $n_cc_feat time(s), and it is logged from the"
    echo "   else-branch of locClientOpen() -- i.e. it can only be written after a successful open --"
    echo "   with 'locClientOpen failed' at $n_cc_fail. It is also not fatal (docs 82)."
  fi
  [ "$n_cc_cap" -gt 0 ] && echo "   'gnssSetCapabilitesCb' appears $n_cc_cap time(s): the vendor HAL is answering callbacks."
  [ "$n_adapter" -gt 0 ] && echo "   And the UT adapter was reached: $n_adapter line(s) carry 'u_hardware_gps_' (set_position_mode and"
  [ "$n_adapter" -gt 0 ] && echo "   friends), so this is not a case of nobody ever asking -- the request got below the daemon."
  # The registration reading STRENGTHENS this rung rather than deciding it: a process that logged is
  # not by itself a service anybody could call, and this is the one place the two can be tied together.
  case "$gnss_registered" in
  yes) echo "   And it is reachable, not merely running: android.hardware.gnss@1.0::IGnss/default has a row in"
       echo "   lshal's binderized table with R=$gnss_answered (Server $gnss_server), so hwservicemanager lists it."
       ;;
  no)  echo "   BUT it is NOT in lshal's binderized table: the process logged, yet hwservicemanager does not list"
       echo "   the interface, so a HIDL caller could not have reached it. Both statements can be true at once --"
       echo "   a process can open the QMI channel without serving the interface -- and this is that case."
       ;;
  *)   echo "   Registration could not be read this boot (section 4): the listing's tables were not separable."
       ;;
  esac
  # A fake fix must not be read as a fix: `custom.location.testing` is the test hook that makes the
  # provider hand out positions that did not come from the modem, and it is the same hook a
  # --enable-testing drop-in sets. Reporting it here is the difference between "a position arrived"
  # and "the modem produced a position".
  [ -n "$p_testing" ] && echo "   NOTE: custom.location.testing is SET ($p_testing) -- a position seen in this state may be the"
  [ -n "$p_testing" ] && echo "   test hook's and not the modem's."
  echo "   So the door is NOT what is blocking: look further down (what came back after the callbacks,"
  echo "   and whether a fix was ever produced) rather than at the layers above."
  echo "   NOT decidable from these counts: whether that call came from a client's"
  echo "   StartPositionUpdates or from the daemon's own provider init."
elif [ "$gnss_registered" = no ] && [ "$n_gnss" -gt 0 ] && [ -n "$A" ]; then
  verdict="gnss-not-registered"
  echo "   Nothing in either log shows the chain starting, and the listing names the reason: lshal's"
  echo "   binderized table (the one hwservicemanager fills) has NO row for"
  echo "   android.hardware.gnss@1.0::IGnss/default, while $n_gnss gnss line(s) exist elsewhere in the"
  echo "   listing. A request from the daemon has nothing to reach, so this is the layer to fix first."
elif [ "$n_gnss" -eq 0 ] && [ -n "$A" ]; then
  verdict="no-gnss-listing"
  echo "   Nothing in this chain has run, and the container's lshal does not even list a gnss entry."
  echo "   That is the state to fix first -- there is nothing above it to talk to."
  # Which of the two it is matters: an absent lshal is a blocker in the INSTRUMENT, and reporting it as
  # "the container has no GNSS HAL" would aim the fix at the wrong layer (section 4 says which).
  [ "$lshal_ran" = 1 ] || echo "   (NOTE: lshal produced no output at all this boot, so 'no gnss entry' may mean 'could"
  [ "$lshal_ran" = 1 ] || echo "    not be asked'. Fix that before concluding anything about the HAL.)"
  # This rung sits ABOVE daemon-only (docs 110), and the reason is that it was nearly dead code where
  # it was: a boot that logs any provider line at all -- which is most boots where the daemon runs --
  # reported `daemon-only`, even when the container had no GNSS HAL whatsoever. "The daemon ran and
  # nothing reached the HAL" is then a CONSEQUENCE of this rung, not a better name for it.
elif [ "$n_prov_inst" -gt 0 ] || [ "$n_ahl" -gt 0 ] || [ "$n_prov_issue" -gt 0 ]; then
  verdict="daemon-only"
  echo "   The location daemon ran and instantiated providers ($n_prov_inst 'Instantiating and"
  echo "   configuring', $n_prov_issue 'Issue instantiating provider'), but NOTHING in either log shows a"
  echo "   request reaching the vendor GPS HAL ($n_cc_feat, $n_cc_cap, $n_cc_fail). A provider being"
  echo "   created is not a position request -- that is the distinction docs 93 records."
  # Said here, not left to section 4: with a gnss row present, `gnss-not-registered` above would have
  # fired, so reaching this rung means the service the daemon would call IS registered -- which is
  # what makes "nothing reached it" a statement about the daemon rather than about the container.
  [ "$gnss_registered" = yes ] && echo "   (The container's IGnss/default IS registered, so what is missing is the request, not the service.)"
else
  verdict="no-evidence"
  echo "   No evidence in either log of a request having been made: this boot cannot say where the"
  echo "   chain breaks, only that it never started."
fi
echo ""
# The name, on its own line, because the explanation above is prose and prose cannot be grepped: the
# offline harness and any reader who comes back to an archived capture need one stable token that says
# which rung this boot stopped at.
echo "   VERDICT: $verdict"
echo ""
echo "   What this does NOT decide: whether that call came from a client's StartPositionUpdates or from"
echo "   the daemon's own provider init (the counts decide the layers, not the caller), the value of the"
echo "   Server/Threads columns OUTSIDE lshal's first table (lshal itself warns they can be stale --"
echo "   section 4 reads them for a table-1 row only), and whether a fix was ever produced. The counts"
echo "   are per-boot, and this device's clock is wrong (docs 69), so they are read as a boot-scoped set,"
echo "   never as a timeline."

case "$verdict" in
# exit 0: the chain demonstrably reaches the container's vendor GPS HAL. That is a POSITIVE finding
# about the layers above it, and it is why the capture will list this step as ok -- not a claim that
# GPS works (nothing here produces a fix).
reaches-vendor-hal) exit 0 ;;
# exit 1: a named blocker, or no evidence at all. The verdict above says which.
*) exit 1 ;;
esac
