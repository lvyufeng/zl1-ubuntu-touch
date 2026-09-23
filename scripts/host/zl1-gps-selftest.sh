#!/bin/sh
# zl1 GPS probe -- offline self-test. Host-side, touches no device.
#
# Why this exists: `scripts/device/zl1-gps-probe.sh` is the instrument for the one peripheral whose
# chain has never produced a fix, and until 2026-09-23 three of its eight log patterns were counted in
# LOGCT while the process that writes them is a UT-side one -- whose stderr goes to the JOURNAL. A
# count of 0 in the wrong log reads as "the provider was never instantiated" and aims the whole
# diagnosis one layer too low, which is the same defect class as docs 99/100/101 (an instrument that
# cannot report the thing it exists to report).
#
# So the primary assertions here are about WHERE each number comes from, and they are made with two
# fixtures that deliberately give the same string different counts in the two logs: a string the probe
# reads from the wrong source prints a number that cannot match, which is a failing check rather than a
# plausible-looking 0.
#
# Second, and it needs no device: **the two pattern lists must be disjoint**, and every pattern must
# still be a string that exists in some binary of some image this port ships. The first is checked
# statically, out of the script text (a string that appears in both lists means one of its two owners
# is wrong); the second is checked against the images when they are mounted, and SKIPPED -- loudly,
# and counted separately -- when they are not, because an assertion that quietly becomes a no-op is
# the defect this file exists to find.
#
# Usage: zl1-gps-selftest.sh [--keep]
#   --keep   leave the fake root, the stubs and the rewritten script for inspection
#
# Exit codes: 0 every scenario behaved; 1 something did not; 2 the harness could not set up.

set -u

KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
  --keep) KEEP=1; shift ;;
  # The header, whatever its current length -- not a fixed line range, which silently truncates the
  # usage text every time the header grows (docs 104).
  --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

HERE=$(dirname "$0")
SRC="$HERE/../device/zl1-gps-probe.sh"
[ -r "$SRC" ] || { echo "cannot read $SRC" >&2; exit 2; }

W=${TMPDIR:-/tmp}/zl1-gps-selftest
FR="$W/fake"
STUB="$W/stub"
ACT="$W/actions"
rm -rf "$W"
mkdir -p "$FR/proc/device-tree" "$FR/proc/700" "$FR/proc/700/ns" "$FR/proc/700/fd" \
         "$FR/userdata" "$FR/tmp" "$FR/system/bin" "$FR/etc" "$FR/usr/bin" "$STUB" || exit 2

# --- the fake device -----------------------------------------------------------------------------
#
# Two processes: the container's init (pid 700) and the UT daemon. The daemon's comm is what the probe
# matches, and a real one is truncated to 15 characters, so the fixture is truncated too -- a fixture
# with the full name would let a `case lomiri-location*service` bug through.
printf 'qcom,msm8996\n' > "$FR/proc/device-tree/compatible"
printf 'lomiri-location\n' > "$FR/proc/700/comm"
printf ' 9 9 9 9\n' > "$FR/proc/700/stat"
: > "$FR/proc/700/cmdline"

# The daemon pid and the container pid are chosen by the scenario, so the fake /proc holds a daemon
# whose comm matches and the nsenter stub answers with the container pid.
#
# **/proc/<pid>/ns/pid is a SYMLINK, and readlink on a regular file prints NOTHING.** A fixture written
# with `>` therefore leaves both readlink calls empty, they compare equal, and every namespace verdict
# comes out "the same" -- for the wrong reason, while every namespace check passes. That is what the
# first version of this file did; hence `ln -sf` everywhere below.
daemon_pid() { printf '700\n'; }

DHOST_NS=pid:[1111]
DCONT_NS=pid:[2222]
ln -sf "$DHOST_NS" "$FR/proc/700/ns/pid"

mkdir -p "$FR/proc/699/ns"
ln -sf "$DCONT_NS" "$FR/proc/699/ns/pid"

# The unit, as `systemctl cat` would print it: the ExecStart override is the android-aware wrapper and
# the drop-in that set it is named, because that is the only honest check that the wrapper is in effect.
cat > "$W/unit.txt" <<'UNIT'
# /usr/lib/systemd/system/lomiri-location-service.service
[Unit]
Description=Location Services

[Service]
Type=dbus
BusName=com.lomiri.location.Service
ExecStart=/usr/libexec/lxc-android-config/lomiri-location-serviced-wrapper

# /usr/lib/systemd/system/lomiri-location-service.service.d/lxc-android-config.conf
[Service]
ExecStart=
ExecStart=/usr/libexec/lxc-android-config/lomiri-location-serviced-wrapper
UNIT

# --- the two logs, and why they carry DIFFERENT counts for the same string ------------------------
#
# Every pattern the probe counts appears in exactly one of these two files. A pattern the probe reads
# from the wrong file therefore prints 0 while the fixture plainly contains it, and the assertion below
# compares against the fixture's number rather than against "nonzero" -- so the failure is visible.
JOURNAL="$W/journal.txt"
LOGCT="$W/logcat.txt"
{
  printf 'Started Location Services.\n'
  printf 'Issue instantiating provider: gps\n'
  printf 'Issue instantiating provider: remote\n'
  printf 'Instantiating and configuring\n'
  printf 'Remote service failed to start\n'
  printf 'Failed to inject reference time to chipset.\n'
  printf 'Missing agent implementation.\n'
  printf 'Missing agent implementation.\n'
  printf 'Cannot operate without an agent implementation.\n'
  printf '../../src/location_service/com/lomiri/location/providers/gps/android_hardware_abstraction_layer.cpp\n'
} > "$JOURNAL"
{
  printf 'E/LocSvc_ApiV02: Failed to get features supported from QMI_LOC_GET_SUPPORTED_FEATURE_REQ_V02\n'
  printf 'E/LocSvc_ApiV02: Failed to get features supported from QMI_LOC_GET_SUPPORTED_FEATURE_REQ_V02\n'
  printf 'D/gnss: gnssSetCapabilitesCb capabilities=0x7f\n'
  printf 'E/LocSvc_api_v02: locClientOpen failed, status = 1\n'
  printf 'I/GnssLocationProvider: something gps\n'
} > "$LOGCT"

# --- the lshal listing ---------------------------------------------------------------------------
#
# A FIXTURE IN THE REAL SHAPE, and the shape is the point. lshal prints THREE tables, separated by
# blank lines, each introduced by a description line that is a literal in the image's own
# liblshal.so; the default rows are `R Interface Thread Use Server Clients`. The previous version of
# this file fed the stub a single bare line (`android.hardware.gnss@1.0::IGnss/default`) -- a shape no
# lshal produces -- so nothing it asserted could have been about a real listing.
#
# The three description lines below are copied verbatim out of
# /mnt/android-sys-test/lib64/liblshal.so, and the default rows are the 2026-09-23 recording
# (evidence/gps-probe-live-2026-09-23.txt). That is what makes the expected verdict a recorded fact
# rather than a guess about a device.
LSHAL="$W/lshal.txt"
LSHAL_MODE=registered
L_ROW_FMT='%-3s %-56s %-11s %-7s %s\n'
lshal_row() { printf "$L_ROW_FMT" "$@"; }
GNSS_DEFAULT='android.hardware.gnss@1.0::IGnss/default'
lshal_fixture() { # mode -> $LSHAL ; the three tables are built independently so a scenario can move
                  # exactly one thing: where the row is, or whether the anchor line is there at all
  t1_row=1; t2_row=1; t3_row=1; anchor=1
  case "$1" in
  registered) ;;
  # The numbers here are DELIBERATELY unique in the whole listing (909 / 7/9). An earlier version used
  # the recording's own 257/257, which the table-2 row also carries -- so an implementation that read
  # the Server column out of the wrong table still printed 257 and the check passed. A fixture whose
  # expected value can be produced by a wrong implementation is not a test.
  live)       t2_row=0 ;;
  unreleased) t2_row=0 ;;                        # in table 1, but R is blank: listed, hash not read
  unregistered) t1_row=0 ;;                      # in table 2 only -> outside-table-1
  norow)      t1_row=0; t2_row=0 ;;              # nowhere by name; only the I*/* aggregates remain
  noanchor)   anchor=0 ;;                        # the tables cannot be told apart -> unknown
  empty)      t1_row=0; t2_row=0; t3_row=0 ;;
  esac
  {
    [ "$anchor" = 1 ] && printf '%s\n' \
      'All binderized services (registered services through hwservicemanager)'
    lshal_row 'R' 'Interface' 'Thread Use' 'Server' 'Clients'
    if [ "$t1_row" = 1 ]; then
      case "$1" in
      live)       lshal_row 'Y' "$GNSS_DEFAULT" '7/9' '909' '42' ;;
      unreleased) lshal_row ' ' "$GNSS_DEFAULT" '7/9' '909' '42' ;;
      *)          lshal_row 'Y' "$GNSS_DEFAULT" 'N/A' 'N/A' ''
                  lshal_row 'Y' 'android.hardware.gnss@1.0::IGnss/gnss_vendor' 'N/A' 'N/A' ''
                  lshal_row 'Y' 'android.hidl.base@1.0::IBase/gnss_vendor' 'N/A' 'N/A' '' ;;
      esac
    fi
    # a non-gnss row is always here, so an empty table 1 is still a table that was FOUND and read
    lshal_row 'Y' 'android.hidl.manager@1.0::IServiceManager/default' 'N/A' 'N/A' ''
    printf '\n'
    printf '%s\n' 'All interfaces that getService() has ever return as a passthrough interface;'
    printf '%s\n' 'PIDs / processes shown below might be inaccurate because the process'
    printf '%s\n' 'might have relinquished the interface or might have died.'
    printf '%s\n' 'The Server / Server CMD column can be ignored.'
    printf '%s\n' "The Clients / Clients CMD column shows all process that have ever dlopen'ed "
    printf '%s\n' 'the library and successfully fetched the passthrough implementation.'
    lshal_row 'R' 'Interface' 'Thread Use' 'Server' 'Clients'
    [ "$t2_row" = 1 ] && lshal_row ' ' "$GNSS_DEFAULT" 'N/A' '257' '257'
    # `empty` has to mean empty: this row carries 'gnss' too, so leaving it in would make the
    # "the listing has no gnss at all" scenario impossible to build.
    [ "$1" = empty ] || lshal_row ' ' 'vendor.qti.gnss@1.0::ILocHidlGnss/gnss_vendor' 'N/A' '257' '257'
    printf '\n'
    printf '%s\n' 'All available passthrough implementations (all -impl.so files).'
    printf '%s\n' 'These may return subclasses through their respective HIDL_FETCH_I* functions.'
    lshal_row 'R' 'Interface' 'Thread Use' 'Server' 'Clients'
    [ "$t3_row" = 1 ] && {
      lshal_row ' ' 'android.hardware.gnss@1.0::I*/* (/vendor/lib/hw/) (-qti)' 'N/A' 'N/A' ''
      lshal_row ' ' 'android.hardware.gnss@1.0::I*/* (/vendor/lib64/hw/) (-qti)' 'N/A' 'N/A' '257'
    }
  } > "$LSHAL"
}

# --- the stubs ----------------------------------------------------------------------------------
mkstub() { # name
  printf '#!/bin/sh\nprintf "%%s %%s\\n" "%s" "$*" >> "%s"\n' "$1" "$ACT" > "$STUB/$1"
  chmod +x "$STUB/$1"
}
mkstub sleep

cat > "$STUB/systemctl" <<EOF
#!/bin/sh
printf 'systemctl %s\n' "\$*" >> "$ACT"
case "\$*" in
"cat "*) cat "$W/unit.txt" ;;
"is-active "*) printf '%s\n' "\${FAKE_ACTIVE:-active}" ;;
"status "*) printf '%s\n' "\${FAKE_STATUS:-  Active: active (running)}" ;;
esac
exit 0
EOF

cat > "$STUB/lxc-info" <<EOF
#!/bin/sh
printf 'lxc-info %s\n' "\$*" >> "$ACT"
[ "\${FAKE_CONTAINER:-yes}" = none ] || printf '%s\n' "\${FAKE_CONTAINER_PID:-699}"
exit 0
EOF

cat > "$STUB/journalctl" <<EOF
#!/bin/sh
printf 'journalctl %s\n' "\$*" >> "$ACT"
[ "\${FAKE_JOURNAL:-present}" = none ] || cat "$JOURNAL"
exit 0
EOF

# nsenter: the transport into the container. It runs the command locally with the stubs in front of
# PATH, so the probe's `/system/bin/logcat` and `/system/bin/getprop` are the harness's. The -m flag is
# recorded rather than emulated: "the probe asked with -m" is the claim, and a fake mount namespace
# would only be a second place to be wrong.
cat > "$STUB/nsenter" <<EOF
#!/bin/sh
printf 'nsenter %s\n' "\$*" >> "$ACT"
while [ \$# -gt 0 ]; do
  case "\$1" in --) shift; break ;; -*) shift ;; *) shift ;; esac
done
exec env PATH="$STUB:\$PATH" sh -c "\$*"
EOF

cat > "$FR/system/bin/logcat" <<EOF
#!/bin/sh
printf 'logcat %s\n' "\$*" >> "$ACT"
[ "\${FAKE_LOGCT:-present}" = none ] || cat "$LOGCT"
exit 0
EOF

cat > "$FR/system/bin/getprop" <<EOF
#!/bin/sh
printf 'getprop %s\n' "\$*" >> "$ACT"
case "\$1" in
custom.location.testing) printf '%s\n' "\${FAKE_TESTING:-}" ;;
custom.location.fake)    printf '%s\n' "\${FAKE_FAKEPROP:-}" ;;
custom.location.lat)     printf '%s\n' "\${FAKE_LAT:-}" ;;
custom.location.lon)     printf '%s\n' "\${FAKE_LON:-}" ;;
esac
exit 0
EOF

cat > "$STUB/lshal" <<EOF
#!/bin/sh
printf 'lshal %s\n' "\$*" >> "$ACT"
[ "\${FAKE_LSHAL:-present}" = none ] || cat "$LSHAL"
exit 0
EOF

cat > "$FR/usr/bin/lomiri-location-serviced-cli" <<EOF
#!/bin/sh
printf 'serviced-cli %s\n' "\$*" >> "$ACT"
case "\$*" in
*does_satellite_based_positioning*) printf '%s\n' "\$FAKE_SAT" ;;
*does_report_wifi_and_cell_ids*)    printf '%s\n' "\$FAKE_WIFI" ;;
*--help*) printf '%s\n' 'usage: lomiri-location-serviced-cli [-h] {does_satellite_based_positioning,does_report_wifi_and_cell_ids} {get,set}' ;;
esac
exit 0
EOF

cat > "$FR/usr/bin/test_gps" <<EOF
#!/bin/sh
printf 'test_gps %s\n' "\$*" >> "$ACT"
printf 'c\n'
exit 0
EOF

# The daemon's environ, which is where gate 1's switch lives (the unit's wrapper exports it and then
# `exec`s, so the daemon's environ is the place to look).
printf '%s\n' 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' > "$FR/proc/700/environ.normal"
printf '%s\n' 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
  'TRUST_STORE_PERMISSION_MANAGER_IS_RUNNING_UNDER_TESTING=1' > "$FR/proc/700/environ.testing"

chmod +x "$STUB"/* "$FR/system/bin"/* "$FR/usr/bin"/*

# --- the rewritten script ------------------------------------------------------------------------
#
# Only the OPERATIONAL paths. The pattern lists and every comment stay exactly as shipped, which is
# what makes the static assertions below assertions about the real file.
GP="$W/gps.sh"
sed -e "s#/proc/device-tree/compatible#$FR/proc/device-tree/compatible#g" \
    -e "s#/usr/bin/lomiri-location-serviced-cli#$FR/usr/bin/lomiri-location-serviced-cli#g" \
    -e "s#/usr/bin/test_gps#$FR/usr/bin/test_gps#g" \
    -e "s#/tmp/zl1-gps-probe.unit#$FR/tmp/zl1-gps-probe.unit#g" \
    -e "s#/tmp/zl1-gps-probe.test_gps#$FR/tmp/zl1-gps-probe.test_gps#g" \
    -e "s#/etc/gps.conf#$FR/etc/gps.conf#g" \
    -e "s#/system/bin/logcat#$FR/system/bin/logcat#g" \
    -e "s#/system/bin/getprop#$FR/system/bin/getprop#g" \
    -e "s#/proc/\\[0-9\\]\\*#$FR/proc/[0-9]*#g" \
    -e "s#/proc/\\\$dpid#$FR/proc/\\\$dpid#g" \
    -e "s#/proc/\\\$A#$FR/proc/\\\$A#g" \
    -e "s|\${p#/proc/}|\${p#$FR/proc/}|g" \
    "$SRC" > "$GP"
sh -n "$GP" || { echo "the rewritten GPS probe does not parse" >&2; exit 2; }
grep -qF "$FR/proc/[0-9]*" "$GP" || { echo "the /proc/[0-9]* rewrite did not land" >&2; exit 2; }
grep -qF "$FR/proc/\$dpid" "$GP" || { echo "the /proc/\$dpid rewrite did not land" >&2; exit 2; }
# and the landing count, because one missed path means the probe reads the HOST's /proc while every
# scenario still passes -- the defect docs 98 found in its own harness.
for k in '/proc/$dpid' '/proc/[0-9]*' '/etc/gps.conf'; do
  n=$(grep -c -F -- "$k" "$SRC")
  m=$(grep -c -F -- "$FR$k" "$GP")
  [ "$n" = "$m" ] || { echo "only $m of $n occurrences of $k were rewritten" >&2; exit 2; }
done
# The prefix strip is not a path, so it is counted by shape rather than by prefix. It matters the same
# way: unreplaced, `${p#/proc/}` does not strip the fake prefix, `dpid` becomes a full path, both
# readlink calls fail, and every namespace verdict comes out "same" for the wrong reason -- which is
# exactly what the first version of this harness did, and every one of those checks passed.
n=$(grep -c -F -- '${p#/proc/}' "$SRC")
m=$(grep -c -F -- '${p#'"$FR"'/proc/}' "$GP")
[ "$n" = "$m" ] && [ "$n" != 0 ] || { echo "only $m of $n '\${p#/proc/}' occurrences were rewritten" >&2; exit 2; }
printf 'qcom,msm8996\n' > "$FR/proc/device-tree/compatible"

# --- the checks ----------------------------------------------------------------------------------

PASS=0
FAIL=0
SKIP=0
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
want()    { if printf '%s\n' "$2" | grep -Eq "$1"; then ok "$3"; else bad "$3"; printf '%s\n' "$2" | sed 's/^/        | /'; fi; }
notwant() { if printf '%s\n' "$2" | grep -Eq "$1"; then bad "$3"; printf '%s\n' "$2" | grep -E "$1" | sed 's/^/        | /'; else ok "$3"; fi; }
count()   { printf '%s\n' "$2" | grep -c "$1"; }      # $2 is TEXT
countf()  { grep -c -- "$1" "$2" 2>/dev/null || true; }   # $2 is a FILE (without this, handing a text
                                                          # helper a PATH silently greps the path itself)
wantf()    { if grep -Eq -- "$1" "$2" 2>/dev/null; then ok "$3"; else bad "$3"; grep -E -- "$1" "$2" 2>/dev/null | sed 's/^/        | /'; fi; }
notwantf() { if grep -Eq -- "$1" "$2" 2>/dev/null; then bad "$3"; grep -E -- "$1" "$2" | sed 's/^/        | /'; else ok "$3"; fi; }
# What the probe printed for one pattern, as a number. The table is "   <pattern> <count>".
pcount() { printf '%s\n' "$OUT" | awk -v p="$1" 'index($0, p) && $NF ~ /^[0-9]+$/ { print $NF; exit }'; }
# `$FR/tmp/zl1-gps-probe.unit` is excluded on purpose: `systemctl cat` has to land somewhere and /tmp is
# where the script says it goes. Everything else in the fake root has to be untouched.
snap()   { find "$FR" -path "$FR/tmp/*" -prune -o -printf '%p %s\n' 2>/dev/null | sort; }

RUN_ACTIVE=active; RUN_CONTAINER=yes; RUN_JOURNAL=present; RUN_LOGCT=present
RUN_SAT=true; RUN_WIFI=false
env_reset() {
  RUN_ACTIVE=active; RUN_CONTAINER=yes; RUN_JOURNAL=present; RUN_LOGCT=present
  RUN_SAT=true; RUN_WIFI=false
  # The healthy state, and the default for every scenario below: the daemon IS in the container's PID
  # namespace. (Making the default the *mismatch* would mean every other section's fixture is a broken
  # device, and it is what made this section's first check assert the opposite of its own fixture.)
  ln -sf "$DCONT_NS" "$FR/proc/700/ns/pid"
  cp "$FR/proc/700/environ.normal" "$W/environ" 2>/dev/null
  rm -f "$FR/proc/700/environ"
  printf 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n' > "$FR/proc/700/environ"
  # Rebuilt here, not left over from the previous scenario: a lshal fixture that leaked across
  # scenarios would make the registration section's checks pass for the wrong reason.
  lshal_fixture registered
}
run() {
  : > "$ACT"
  OUT=$(PATH="$STUB:$PATH" FAKE_ACTIVE="$RUN_ACTIVE" FAKE_CONTAINER="$RUN_CONTAINER" \
        FAKE_JOURNAL="$RUN_JOURNAL" FAKE_LOGCT="$RUN_LOGCT" \
        FAKE_SAT="$RUN_SAT" FAKE_WIFI="$RUN_WIFI" \
        timeout 60 sh "$GP" "$@" 2>&1); RC=$?
}
# `LSHAL_MODE=x run` would not stick: an assignment in front of a FUNCTION is not required to survive
# into it (and bash restores it). So the fixture is rebuilt explicitly, by name.
run_lshal() { # mode [args...]
  lshal_fixture "$1"; shift
  run "$@"
}
env_reset

echo "zl1 GPS probe -- offline self-test"
echo "  script under test: $SRC"
echo "  fake device:       $FR"
echo

# ==================================================================================================
echo "== 1. the provenance rule, checked statically out of the shipped script =="
# ==================================================================================================
# This is the assertion that would have caught the defect, and it needs no fixture at all: a string can
# only be written by the process that contains it, so a pattern in BOTH lists means one of its two
# owners is wrong. The lists are extracted between their `for pat in` and the closing `; do`.
LOGLIST=$(sed -n "/^  for pat in 'locClientOpen failed'/,/; do/p" "$SRC")
JLIST=$(sed -n "/^for pat in 'Issue instantiating provider'/,/; do/p" "$SRC")
# Two shapes: the first pattern of each list sits on the `for pat in '...'` line, the rest on their own
# indented lines. The first version only matched the second shape, so **the first pattern of each list
# was silently dropped from every check below** -- including `locClientOpen failed`, the one pattern this
# probe's header says is the discriminating one. Exactly the defect class this file exists to find.
pats() {
  printf '%s\n' "$1" \
    | sed -n "s/^ *for pat in '\([^']*\)'.*/\1/p; s/^ *'\([^']*\)'.*/\1/p"
}
LPATS=$(pats "$LOGLIST"); JPATS=$(pats "$JLIST")
[ -n "$LPATS" ] && ok "the logcat pattern list was found in the shipped script" || bad "could not find the logcat pattern list (did the section move?)"
[ -n "$JPATS" ] && ok "and the journal list" || bad "could not find the journal pattern list"
echo "     logcat: $(printf '%s' "$LPATS" | tr '\n' ' ')"
echo "     journal: $(printf '%s' "$JPATS" | tr '\n' ' ')"
[ -z "$(printf '%s\n%s\n' "$LPATS" "$JPATS" | sort | uniq -d)" ] \
  && ok "no pattern is counted in both logs" \
  || { bad "a pattern is in both lists -- one of its two owners must be wrong:"; printf '%s\n%s\n' "$LPATS" "$JPATS" | sort | uniq -d | sed 's/^/        | /'; }

echo
echo "   -- and the two strings that were removed, with the reason (they can never be evidence):"
notwant "set_gps_service_callbacks" "$LPATS$JPATS" "the symbol name is no longer counted as a log line (it is a SYMBOL: in no binary in any image)"
notwant "Unable to get GPS service" "$LPATS$JPATS" "nor is the framework's own message (libandroid_servers.so / GnssLocationProvider -- not on this path)"
wantf "a SYMBOL name; the string is in no binary" "$SRC" "and the script says why, where the next person will read it"
wantf "it calls IGnss::getService\(\) HIDL" "$SRC" "including why the framework path is not this path"

# ==================================================================================================
echo
echo "== 2. the default run writes nothing =="
# ==================================================================================================
BEFORE=$(snap)
run
printf '%s\n' "$OUT" > "$W/out.default"
# Exit 1 IS the right answer for this fixture, and the assertion is spelled with its reason so it cannot
# be "fixed" back to 0 by the next person: the default logcat fixture contains `locClientOpen failed`
# once, which is the one line in the HAL source that returns a real failure -- so the verdict is
# `qmi-open-failed`, a NAMED blocker, and section 6 exits 1 for that. (The scenario where 0 is correct
# is the one whose count is 0 and whose features/capabilities lines are present: section 10 below.)
[ "$RC" = 1 ] && ok "the default run exits 1 (its fixture's logcat has locClientOpen failed)" \
  || bad "the default run exited $RC, wanted 1 (the fixture contains locClientOpen failed)"
[ "$(snap)" = "$BEFORE" ] && ok "and changed nothing in the fake device" || bad "the default run wrote something"
[ -z "$(grep -c '^test_gps' "$ACT" 2>/dev/null | grep -v '^0$')" ] && ok "and never touched the hardware half" || bad "it ran test_gps without being asked"
want 'read-only' "$OUT" "it announces that it is read-only"
want '== unit lomiri-location-service' "$OUT" "section 1 is about the unit"
want 'lomiri-location-serviced-wrapper' "$OUT" "it prints the ExecStart that is actually in effect"
want 'lxc-android-config\.conf' "$OUT" "and names the drop-in that set it"

# ==================================================================================================
echo
echo "== 3. every count comes from the log the string's OWNER writes to =="
# ==================================================================================================
# The fixtures give the same string different counts in the two logs, so a count read from the wrong
# source shows up as a wrong NUMBER rather than a plausible 0.
want 'logcat \(the container.s vendor GPS HAL\)' "$OUT" "the logcat block is labelled by owner"
want 'journal of lomiri-location-service' "$OUT" "and so is the journal block"
[ "$(pcount 'locClientOpen failed')" = "$(countf 'locClientOpen failed' "$LOGCT")" ] \
  && ok "locClientOpen failed: the count is the logcat fixture's ($(countf 'locClientOpen failed' "$LOGCT"))" \
  || bad "locClientOpen failed printed $(pcount 'locClientOpen failed'), the logcat fixture has $(countf 'locClientOpen failed' "$LOGCT")"
[ "$(pcount 'gnssSetCapabilitesCb')" = "$(countf 'gnssSetCapabilitesCb' "$LOGCT")" ] \
  && ok "gnssSetCapabilitesCb: from logcat" || bad "gnssSetCapabilitesCb printed $(pcount 'gnssSetCapabilitesCb')"
[ "$(pcount 'Issue instantiating provider')" = "$(countf 'Issue instantiating provider' "$JOURNAL")" ] \
  && ok "Issue instantiating provider: the journal fixture's count ($(countf 'Issue instantiating provider' "$JOURNAL"))" \
  || bad "Issue instantiating provider printed $(pcount 'Issue instantiating provider'), the journal has $(countf 'Issue instantiating provider' "$JOURNAL") -- this is the defect: it would be 0 in logcat"
[ "$(pcount 'Instantiating and configuring')" = "$(countf 'Instantiating and configuring' "$JOURNAL")" ] \
  && ok "Instantiating and configuring: from the journal" || bad "Instantiating and configuring printed $(pcount 'Instantiating and configuring')"
[ "$(pcount 'Remote service failed to start')" = "$(countf 'Remote service failed to start' "$JOURNAL")" ] \
  && ok "Remote service failed to start: from the journal" || bad "it printed $(pcount 'Remote service failed to start')"
[ "$(pcount 'Failed to inject reference time')" = "$(countf 'Failed to inject reference time' "$JOURNAL")" ] \
  && ok "Failed to inject reference time: from the journal" || bad "it printed $(pcount 'Failed to inject reference time')"
notwant '0 *(Issue instantiating provider|Instantiating and configuring)' "$OUT" \
  "and the fixture's journal strings are NOT reported as 0 (the shape the old version produced)"
want 'journalctl -b -u lomiri-location-service' "$(grep '^journalctl' "$ACT" 2>/dev/null)" "the journal query is boot-scoped (-b), the only kind that survives a wrong clock"
want 'no-pager' "$(grep '^journalctl' "$ACT" 2>/dev/null)" "and paged output is turned off"
want 'logcat -d' "$(grep '^logcat' "$ACT" 2>/dev/null)" "logcat is read as a dump, not a follow"

echo
echo "   -- the three trust-store gates, which only the journal can show:"
want 'Missing agent implementation' "$OUT" "gate 3's failure has a name in the output"
[ "$(pcount 'Missing agent implementation')" = "$(countf 'Missing agent implementation' "$JOURNAL")" ] \
  && ok "and the count is the journal's" || bad "it printed $(pcount 'Missing agent implementation')"
want 'Client lacks permissions' "$OUT" "so does gate 1/2's"
want 'Cannot create service for null permission manager' "$OUT" "and the third"

echo
echo "   -- and where gate 1's switch would be visible:"
env_reset
run
want 'gate 1 is NOT short-circuited' "$OUT" \
  "it looks for the bypass in the daemon's own environ (the wrapper execs, so that is where it lands)"
env_reset
printf 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\nTRUST_STORE_PERMISSION_MANAGER_IS_RUNNING_UNDER_TESTING=1\n' > "$FR/proc/700/environ"
run
want 'TRUST_STORE_PERMISSION_MANAGER_IS_RUNNING_UNDER_TESTING=1' "$OUT" \
  "and prints it when it IS set, so a short-circuited gate 1 is visible as such"

# ==================================================================================================
echo
echo "== 4. the two fixtures must stay distinguishable (the harness's own teeth) =="
# ==================================================================================================
# If a future edit made the two logs identical, every count assertion above would pass for the wrong
# reason. This is the check that keeps them from collapsing into one.
[ "$(countf 'Issue instantiating provider' "$LOGCT")" = 0 ] \
  && ok "the journal-only string is absent from the logcat fixture, so reading the wrong log cannot pass" \
  || bad "the fixtures overlap: the check above would no longer be able to fail"
[ "$(countf 'locClientOpen failed' "$JOURNAL")" = 0 ] \
  && ok "and the logcat-only string is absent from the journal fixture" \
  || bad "the fixtures overlap in the other direction too"

# ==================================================================================================
echo
echo "== 5. the namespace verdict, driven both ways =="
# ==================================================================================================
env_reset
run
want 'IN the container.s PID namespace' "$OUT" "a daemon in the container's namespace is reported as such"
# Both values are printed, and both are NON-EMPTY. This is the check that would have caught the
# regular-file fixture: readlink prints nothing for one, the two sides compare equal, and the verdict
# above comes out "in the container" for the wrong reason. The numbers here are the fixture's, so a
# verdict read off empties cannot match them.
want 'daemon pid 700  ns/pid pid:\[2222\]' "$OUT" "and the daemon's own ns value is shown, not blank"
want 'container  pid 699  ns/pid pid:\[2222\]' "$OUT" "with the container's alongside it"
env_reset
ln -sf 'pid:[3333]' "$FR/proc/700/ns/pid"
run
want 'HOST namespace' "$OUT" "a daemon in the host namespace is called out (it cannot see hwbinder)"
want 'cannot see the container.s hwbinder services' "$OUT" "with what that means for the HAL it needs"
want 'daemon pid 700  ns/pid pid:\[3333\]' "$OUT" "and the mismatch is visible in the values it printed"

echo
echo "   -- and with no daemon at all, and with no container:"
env_reset
rm -f "$FR/proc/700/comm"
printf 'something-else\n' > "$FR/proc/700/comm"
run
want 'daemon: not running' "$OUT" "a missing daemon is said, not assumed"
env_reset
printf 'lomiri-location\n' > "$FR/proc/700/comm"
RUN_CONTAINER=none run
want 'logcat: skipped' "$OUT" "with no container the logcat block says it is skipped"
notwant 'no gnss service registered' "$OUT" "and it does not claim to have looked for the HIDL service"
notwant 'namespace' "$OUT" "nor does it give a namespace verdict with no container pid to compare against"

# ==================================================================================================
echo
echo "== 6. the switches, the properties and the HIDL service =="
# ==================================================================================================
env_reset
run
want 'satellite: .*true' "$OUT" "it reads does_satellite_based_positioning through the UT's own client tool"
want 'wifi/cell: .*false' "$OUT" "and does_report_wifi_and_cell_ids"
want 'custom.location.testing' "$OUT" "it reads the four custom.* properties the wrapper uses"
want 'read INSIDE the container' "$OUT" "and says they are read inside the container, because the host getprop is a stub"
want 'lshal' "$(grep '^nsenter' "$ACT" 2>/dev/null | tail -1)" "it asks lshal about gnss"
want 'nsenter .*-p -m' "$(grep '^nsenter' "$ACT" 2>/dev/null | head -1)" "through the container's PID and mount namespaces"

# ==================================================================================================
echo
echo "== 7. the flag surface =="
# ==================================================================================================
run --nope
[ "$RC" = 2 ] && ok "an unknown argument exits 2" || bad "unknown argument exited $RC"
run --help
[ "$RC" = 0 ] && ok "--help exits 0" || bad "--help exited $RC"
want 'Usage .*zl1-gps-probe' "$OUT" "and prints the usage block"
# The range is a line number, so it drifts every time the header grows -- and it has already drifted
# past the header once. The negative assertion is what makes the range's end testable at all.
notwant 'set -u|TEST_GPS=' "$OUT" "and stops at the header, rather than printing the assignments after it"
msg=$(PATH="$STUB:$PATH" sh "$GP" --seconds 2>&1 >/dev/null | head -1)
case "$msg" in
*"unbound variable"*|*"parameter not set"*) bad "--seconds with no value aborted the shell: $msg" ;;
*"--seconds needs a number"*) ok "--seconds with no value names the flag instead of aborting the shell" ;;
*) bad "--seconds with no value said neither: $msg" ;;
esac

# ==================================================================================================
echo
echo "== 8. --test-gps is opt-in, and reaches the HAL the way the camera path does =="
# ==================================================================================================
env_reset
run --test-gps --seconds 1
want '^test_gps' "$(cat "$ACT")" "--test-gps runs test_gps"
want 'HYBRIS_LD_LIBRARY_PATH' "$(grep '^nsenter' "$ACT" 2>/dev/null)" "with hybris' library path in front"
want 'libtls-padding' "$(grep '^nsenter' "$ACT" 2>/dev/null)" "and the TLS-slot preload a glibc host needs"
notwant 'zul1-hybris' "$OUT" "and it does not invent a path"
env_reset
run
notwant 'HYBRIS_LD_LIBRARY_PATH' "$(grep '^nsenter' "$ACT" 2>/dev/null)" "the default run sets none of that, because it does not run the hardware half"

# ==================================================================================================
echo
echo "== 9. every pattern is still a string that exists in some image (SKIPPED, loudly, if they are not here) =="
# ==================================================================================================
# The other half of the header's claim, and the reason it is not folded into section 1: it needs the
# images. It is the ONLY check that a pattern is real -- section 1 proves each string sits in the right
# LIST, which is not the same as the string existing anywhere (that is exactly how two patterns that
# are in no binary in any image survived in this same table). Read-only, and skipped when the images
# are not mounted -- printed as a SKIP and counted separately, because an assertion that quietly
# becomes a no-op is the defect this whole file is about.
UT_IMG=${ZL1_UT_IMAGE:-/mnt/utrootfs}
AS_IMG=${ZL1_ANDROID_IMAGE:-/mnt/android-sys-test}
VE_IMG=${ZL1_VENDOR_IMAGE:-/mnt/vendor-ro}
_missing=""
for _m in "$UT_IMG" "$AS_IMG" "$VE_IMG"; do [ -d "$_m" ] || _missing="$_missing $_m"; done
if [ -n "$_missing" ]; then
  SKIP=$((SKIP + 1))
  printf 'SKIP  the image cross-check (%s not mounted here)\n' "${_missing# }"
  printf '      -> mount them read-only (docs 102 section 7) and re-run: nothing else checks that a pattern is a real string\n'
else
  # $LPATS is one pattern per line and the patterns contain spaces, so the split has to be by newline.
  _oldifs=$IFS; IFS='
'
  # The test is "did grep print a hit", NOT grep's exit status: some files inside these images are
  # unreadable to us (`/mnt/android-sys-test/bin/bootstat`, a few others), and grep reports that as
  # exit **2** -- so an exit-status test fails every pattern in the image with a permission error,
  # which is a harness bug that looks exactly like "these strings are nowhere". A hit is a hit.
  for _p in $LPATS; do
    if [ -n "$(grep -rlaF --exclude-dir=doc -- "$_p" "$AS_IMG" "$VE_IMG" 2>/dev/null | head -1)" ]; then
      ok "logcat-side: '$_p' exists in the Android images"
    else
      bad "logcat-side: '$_p' is counted in logcat but is in no file of the Android images -- its 0 would not be evidence"
    fi
  done
  for _p in $JPATS; do
    if [ -n "$(grep -rlaF --exclude-dir=doc -- "$_p" "$UT_IMG" 2>/dev/null | head -1)" ]; then
      ok "journal-side: '$_p' exists in the UT rootfs"
    else
      bad "journal-side: '$_p' is counted in the journal but is in no file of the UT rootfs"
    fi
  done
  IFS=$_oldifs
fi

# ==================================================================================================
echo
echo "== 10. the verdict: which rung of the chain does the evidence stop at (docs 108) =="
# ==================================================================================================
# Section 6 of the probe exists because the first real capture archived nine sections and the run was
# read as "the GPS probe produced no verdict" -- while those sections held the deepest evidence this
# chain has ever had. So the verdict is a decision, and a decision needs its branches tested. Each
# scenario below differs from the others in exactly one evidence source.
#
# The fixtures are written into the same two files the other sections use, so a scenario is "replace
# what the container logged, then run the real script again". Section 2's snapshot check is not
# repeated here: `snap` is about writes and this section writes only to the harness's own fake root.

# --- the rung the device was actually on, as RECORDED (verbatim numbers from the archive) -----------
# scripts/device/zl1-gps-probe.sh counts, and tmp-post-recovery-20260923T145530Z/05-gps-probe.txt is
# what the device really logged: locClientOpen failed = 0, Failed to get features supported = 2,
# gnssSetCapabilitesCb = 2, and the adapter's set_position_mode called. Nothing about this fixture is
# invented, which is the point: a fixture that cannot be produced by the device tests nothing.
cat > "$LOGCT" <<'EOF'
I/ubuntu_application_gps_hidl_for_hybris( 1757): set_gps_service_callbacks: called
D/PerMgrSrv(  338): GPS voting for modem
I/ubuntu_application_gps_hidl_for_hybris( 1757): gnssSetCapabilitesCb: called
I/ubuntu_application_gps_hidl_for_hybris( 1757): gnssSetSystemInfoCb: called
E/ubuntu_application_gps_hidl_for_hybris( 1757): Unable to initialize GNSS Xtra interface
I/ubuntu_application_gps_hidl_for_hybris( 1757): u_hardware_gps_set_position_mode: called
I/ubuntu_application_gps_hidl_for_hybris( 1757): set_position_mode: called
E/LocSvc_ApiV02: Failed to get features supported from QMI_LOC_GET_SUPPORTED_FEATURE_REQ_V02
E/LocSvc_ApiV02: Failed to get features supported from QMI_LOC_GET_SUPPORTED_FEATURE_REQ_V02
EOF
cat > "$JOURNAL" <<'EOF'
Instantiating and configuring
Instantiating and configuring
EOF
env_reset
run
printf '%s\n' "$OUT" > "$W/out.v.reaches"
[ "$RC" = 0 ] && ok "REACHES: the recorded state exits 0 -- the chain reaches the vendor HAL" \
  || bad "REACHES: exited $RC, wanted 0"
want 'REACHES the container.s vendor GPS HAL' "$OUT" "the verdict says the chain reaches the vendor HAL"
want 'QMI client OPENED' "$OUT" "and that the client opened (the reading docs 82 established)"
want 'not a case of nobody ever asking' "$OUT" "and that the adapter was reached, so 'nobody asked' is ruled out"
want 'u_hardware_gps_\* \(the UT adapter, in logcat\) +1' "$OUT" "quoting the adapter count from the table"
# The count is 1 and not 2 on purpose: the recording's next line is `set_position_mode: called`, which
# does NOT carry the adapter prefix. A fixture that inflated it would make the count look like a
# measurement of something else.
notwant 'u_hardware_gps_\* \(the UT adapter, in logcat\) +2' "$OUT" "and the count is the prefix's, not 'set_position_mode' twice"
want 'NOT decidable from these counts' "$OUT" "and saying what the counts cannot decide"
notwant 'trust-store' "$OUT" "with no trust-store claim, since no gate message is present"
# The one thing the probe must never do is claim the HAL is registered: it cannot read those columns.
# docs 110 replaced the old "the columns are not parsed on purpose" stance with a reading built on
# lshal's own source. These two assertions are the ones that changed meaning, so they are asserted the
# other way round now: the probe must READ the table and must say WHERE the reading came from.
want 'registered: *yes' "$OUT" "it reads the registration out of lshal's binderized table"
want "column is 'Y'" "$OUT" "and reports the R column, which is what makes the row a live service"
want 'Server is read here only because this row is in table 1' "$OUT" "and says which table the Server column is being read from"
notwant 'columns are not parsed' "$OUT" "and no longer claims it cannot read the listing (docs 110)"
# The registration reading is tied INTO the rung, not left beside it: a process that logged is not by
# itself a service anybody could call, and this is the only place the two statements meet.
want 'reachable, not merely running' "$OUT" "and the reaches-the-HAL rung states the registration reading with it"

echo
echo "   -- the fake-position hook must be visible in the verdict (a fake fix is not a fix):"
env_reset
FAKE_TESTING=1 run
want 'custom.location.testing is SET' "$OUT" "with the test hook set, the verdict says so"
env_reset

echo
echo "   -- a trust-store refusal is named, and comes before the HAL rungs:"
env_reset
cat > "$JOURNAL" <<'EOF'
Instantiating and configuring
Client lacks permissions to access the service with the given criteria
EOF
run
[ "$RC" = 1 ] && ok "REFUSED: exits 1" || bad "REFUSED: exited $RC, wanted 1"
want 'REFUSED by the trust store' "$OUT" "the verdict names the trust store"
# Two assertions, not one: the phrase wraps across a line, and a single-line regex that spans the
# wrap would be asserting the terminal's width. (The first version of this assertion did exactly
# that and failed while the output was right.)
want "gate 1's short-circuit switch is" "$OUT" "and reports gate 1's state, which decides whether the store is consulted at all"
want 'NOT set' "$OUT" "-- and that state is NOT set, so the trust store is the thing deciding"
notwant 'REACHES the container' "$OUT" "and does NOT claim the HAL rung, even though the logcat fixture still has the features lines"
# The ordering is the assertion, not the wording: a refusal above the HAL means the HAL's own state is
# not visible on this boot, so the trust-store branch must be reached first.
cat > "$JOURNAL" <<'EOF'
Client lacks permissions to access the service with the given criteria
EOF
env_reset
run
want 'The chain stops above the HAL' "$OUT" "and says the HAL's own state is not visible, rather than calling it broken"

echo
echo "   -- a daemon that instantiates providers and never reaches the HAL:"
env_reset
: > "$LOGCT"
cat > "$JOURNAL" <<'EOF'
Instantiating and configuring
Instantiating and configuring
Instantiating and configuring
EOF
run
[ "$RC" = 1 ] && ok "DAEMON-ONLY: exits 1" || bad "DAEMON-ONLY: exited $RC, wanted 1"
want 'instantiated providers' "$OUT" "the verdict names the daemon-only state"
want 'A provider being' "$OUT" "and draws the distinction the layer depends on: a provider is not a position request"
notwant 'REACHES the container' "$OUT" "and does not claim the HAL rung"

echo
echo "   -- the namespace check comes BEFORE every log rung:"
env_reset
ln -sf "$DHOST_NS" "$FR/proc/700/ns/pid"
run
[ "$RC" = 1 ] && ok "BAD-NS: exits 1" || bad "BAD-NS: exited $RC, wanted 1"
want 'in the HOST PID namespace' "$OUT" "the verdict names the namespace"
want 'it fails before this chain starts' "$OUT" "and says the chain never starts, so no log rung is quoted"
notwant 'REACHES the container.s vendor GPS HAL' "$OUT" "and the log rungs are not reached at all"

echo
echo "   -- and with no container there is nothing to judge:"
env_reset
RUN_CONTAINER=none run
[ "$RC" = 1 ] && ok "NO-CONTAINER: exits 1" || bad "NO-CONTAINER: exited $RC, wanted 1"
want 'container does not answer' "$OUT" "the verdict says so"
want 'logcat: skipped' "$OUT" "and the logcat table is skipped rather than printed as zeros"
notwant 'REACHES the container' "$OUT" "and no rung is claimed from a container that is not there"
env_reset

echo
echo "   -- the verdict is the LAST section, so it cannot be quoted before its evidence:"
vline=$(grep -n '^== verdict' "$W/out.v.reaches" | cut -d: -f1)
gline=$(grep -n '^== .*gps.conf' "$W/out.v.reaches" | cut -d: -f1)
[ -n "$vline" ] && [ "$vline" -gt "${gline:-999999}" ] && ok "the verdict comes after every evidence section" \
  || bad "the verdict is at line ${vline:-none}, gps.conf at ${gline:-none}"

echo
echo "== 11. reading the lshal listing: which table a row is in is the whole answer (docs 110) =="
# Each scenario below sets its OWN two logs as well as its own listing: without that they would inherit
# whatever section 10 left behind, and `empty`'s assertion (`no-gnss-listing`) depends on the journal
# being silent. A scenario that leans on its predecessor's fixture is a scenario that tests the wrong
# thing the day the predecessor changes.
silent_logs() { : > "$LOGCT"; : > "$JOURNAL"; }
# ==================================================================================================
# lshal prints THREE tables and only the first -- the one hwservicemanager fills -- means "registered".
# Every scenario below moves exactly ONE thing: where the row for android.hardware.gnss@1.0::IGnss/default
# sits, or whether the description line that names table 1 is present at all. The probe must answer
# yes / no / unknown, and `unknown` must never collapse into `no`: without the anchor line the tables
# cannot be told apart, and a row that is really in table 1 would read as unregistered.
#
# The fixtures come from the fixture builder above, whose description lines are copied out of the
# image's own liblshal.so -- so "the anchor is present" is a fact about a real binary, not a guess.

echo "   -- the row is in table 1 (the recorded device state):"
env_reset
silent_logs
run_lshal registered
printf '%s\n' "$OUT" > "$W/out.reg.registered"
want 'registered: *yes' "$OUT" "registered: yes"
want 'gnss rows: +[0-9]+ in the listing, [1-9][0-9]* in the binderized table' "$OUT" \
     "and it counts the rows inside that table, not just anywhere in the listing"

echo
echo "   -- the row is in table 2 only (a passthrough reference does not serve hwbinder callers):"
env_reset
silent_logs
run_lshal unregistered
want 'registered: *no' "$OUT" "registered: no"
want 'NOT in the binderized table' "$OUT" "and it names the table, not the service, as the reason"

echo
echo "   -- the row is nowhere by name, but the binderized table WAS found and read:"
env_reset
silent_logs
run_lshal norow
want 'registered: *no' "$OUT" "registered: no -- this is a located blocker, not an absence of evidence"

echo
echo "   -- a different lshal: no description line, so the tables cannot be told apart:"
env_reset
silent_logs
run_lshal noanchor
want 'registered: *unknown' "$OUT" "registered: unknown, NOT no"
want 'not in the listing' "$OUT" "and it says the anchor line is the thing that was missing"
notwant 'registered: *no' "$OUT" "so an unreadable listing is never reported as an unregistered service"

echo
echo "   -- a binderized row with unique thread and server numbers:"
env_reset
silent_logs
run_lshal live
want 'registered: *yes' "$OUT" "registered: yes"
# 909 / 7/9 appears NOWHERE else in the listing, so this is the one assertion a wrong Server source
# cannot satisfy by accident (see the fixture's comment).
want '909 / 7/9' "$OUT" "and the Server/Threads columns are quoted from THAT row (server / threads)"
notwant 'Server/Threads: *257' "$OUT" "with none of the table-2 numbers leaking into that line"

echo
echo "   -- a binderized row whose hash was not read (R blank): listed, but not confirmed live:"
env_reset
silent_logs
run_lshal unreleased
want 'registered: *yes' "$OUT" "registered: yes -- it is in the binderized table, so it IS registered"
want "column is '-'" "$OUT" "and the R column is reported as read (blank), not assumed to be Y"
want 'not the hash query' "$OUT" "and it says what a blank R does and does not mean"

echo
echo "   -- nothing at all: the listing is empty of gnss, which is its own verdict:"
env_reset
silent_logs
run_lshal empty
[ "$RC" = 1 ] && ok "EMPTY: exits 1" || bad "EMPTY: exited $RC, wanted 1"
want 'no-gnss-listing' "$OUT" "the verdict says there is no gnss entry to talk to"
notwant 'gnss-not-registered' "$OUT" "and it is NOT reported as an unregistered service (there is nothing to register)"

echo
echo "   -- and the two 'no' cases become the blocker when the logs are silent:"
# The unregistered fixture is run against the SILENT log (section 10's fixtures are replaced here by
# the default ones), because that is the only situation in which the registration reading is allowed
# to decide the verdict: a log line proving the vendor HAL ran is deeper evidence and outranks it.
env_reset
cat > "$LOGCT" <<'EOF'
I/SomethingElse: nothing about gnss at all
EOF
cat > "$JOURNAL" <<'EOF'
EOF
run_lshal unregistered
[ "$RC" = 1 ] && ok "SILENT+UNREGISTERED: exits 1" || bad "SILENT+UNREGISTERED: exited $RC, wanted 1"
want 'gnss-not-registered' "$OUT" "the verdict names the missing registration"
want 'nothing to reach' "$OUT" "and says why that stops the chain"
# ... and with the service registered, the same silent logs must NOT produce that verdict.
env_reset
cat > "$LOGCT" <<'EOF'
I/SomethingElse: nothing about gnss at all
EOF
run_lshal registered
notwant 'gnss-not-registered' "$OUT" "with the service registered, the same silent logs do NOT blame registration"
env_reset

echo
echo "   -- lshal absent entirely: 'could not be asked' is not 'has no GNSS HAL':"
env_reset
cat > "$LOGCT" <<'EOF'
I/SomethingElse: nothing about gnss at all
EOF
cat > "$JOURNAL" <<'EOF'
EOF
FAKE_LSHAL=none run
[ "$RC" = 1 ] && ok "NO-LSHAL: exits 1" || bad "NO-LSHAL: exited $RC, wanted 1"
want 'lshal produced NO output at all' "$OUT" "it says lshal could not be asked"
want "may mean 'could" "$OUT" "and the no-gnss-listing verdict refuses to blame the container for that"
want 'registered: *unknown' "$OUT" "with registration unknown, not no"
notwant 'registered: *no' "$OUT" "so an absent instrument never becomes a missing service"
env_reset

echo
echo "== 12. the health check cites this harness's count, and that citation cannot drift =="
# `zl1-health-check.sh` is what a human reads first, and it names each harness WITH A CHECK COUNT. Those
# counts are typed by hand, so every time a harness gains an assertion the citation goes stale -- and a
# stale count in the first thing a reader sees is the same defect family as every other one in this
# project (an instrument whose report does not match its subject). It happened here: the GPS citation
# still said 99 while the harness had grown to 123, and nothing would ever have noticed.
#
# This is the check that makes it impossible, and it needs no device: at this point in the run, PASS and
# SKIP are final, so this harness KNOWS its own total and can compare it with what the health check says.
# (The final summary line's own SKIP is not counted, which is why this section counts its own assertion
# in $PASS and nothing else.)
HEALTH="$HERE/zl1-health-check.sh"
if [ -r "$HEALTH" ]; then
  cited=$(sed -e 's/always "/ /g' -e 's/"$//' "$HEALTH" | tr '\n' ' ' |
            sed -n 's/.*zl1-gps-selftest.sh[ ,(]*\([0-9][0-9]*\) checks.*/\1/p')
  # +1 is THIS assertion: the number a reader cites is the `pass=` line the harness ends with,
  # so the check has to count itself or it would be off by one against its own run.
  total=$((PASS + FAIL + 1))
  if [ -z "$cited" ]; then
    bad "the health check no longer cites this harness's count -- either the citation is gone or its wording changed"
  elif [ "$cited" = "$total" ]; then
    ok "the health check cites $cited checks, and this run has exactly that many"
  else
    bad "the health check cites $cited checks, but this harness has $total -- fix scripts/host/zl1-health-check.sh"
  fi
else
  bad "cannot read $HEALTH -- its citations are unchecked"
fi

echo
echo "== 13. what this harness does NOT test, and says so =="
echo "SKIP  the device facts behind the verdict: whether the netwatch-style log really holds those lines,"
echo "      whether the container's lshal lists gnss, and whether lomiri's own gate is open. Those need"
echo "      the boot itself -- and the verdict's job is to say which of them to look at."
SKIP=$((SKIP + 1))
echo
echo "pass=$PASS fail=$FAIL$([ "$SKIP" != 0 ] && echo " skip=$SKIP (a check that could NOT run here)")"
[ "$KEEP" = 1 ] || rm -rf "$W"
# A SKIP is a statement about THIS host, not a defect (same rule as host/zl1-installers-selftest.sh) --
# but it is printed and counted so it cannot pass for a check that ran.
[ "$FAIL" = 0 ]
