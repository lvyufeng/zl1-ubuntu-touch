#!/bin/sh
# zl1 location request -- open the GPS door and find out whether the hardware was ever asked.
#
# Why this exists (docs/ubuntu-touch/93): the GPS question has been read as "the QMI channel is
# broken" and as "no client ever asked". The second reading is right, but not for the reason it was
# written down with. Offline, from the rootfs image alone, the chain is:
#
#   StartPositionUpdates (D-Bus, on a session object)
#     -> session::Implementation::start_position_updates      (0x8f0e4)
#     -> providers::gps::Provider::start_position_updates     (0xe7f10)
#     -> HardwareAbstractionLayer::start_positioning          (0xdaa80, a VIRTUAL call; the vtable
#                                                              slot is the only .text reference to
#                                                              it, at .data.rel.ro 0x15e580)
#     -> Impl::register_callbacks -> u_hardware_gps_new        (0xdaa40, `bl 0x33a70`)
#     ->                            u_hardware_gps_start       (`b 0x33610`)
#
# Both hardware entry points live inside start_positioning() and nowhere else, so the daemon's
# *startup* touches no hardware at all. Nothing has to be wrong with the HAL for u_hardware_gps_* to
# have never run.
#
# In front of that door sits a lock that is checked before any session object exists:
#
#   service/skeleton.cpp, handle_create_session_for_criteria()
#     resolve_credentials_for_incoming_message()   (aa_gettaskcon -> AppArmor profile)
#     permission_manager->check_permission_for_credentials()
#     on reject -> throw "Client lacks permissions to access the service with the given criteria"
#                  client sees only Error.CreatingSession / "Error creating session"
#
# The manager is TrustStorePermissionManager (debian/rules builds with -DENABLE_TRUST_STORE=ON), and
# it has three gates, all of which end in `rejected`:
#
#   1. is_running_under_testing()  -- env TRUST_STORE_PERMISSION_MANAGER_IS_RUNNING_UNDER_TESTING == 1
#   2. credentials.profile non-empty -- empty means aa_gettaskcon could not name the caller's label
#   3. the trust-store agent's answer -- every exception is swallowed into `rejected`
#
# Gate 1 is a true short circuit, read out of the *installed* library (0xd6110, 892 B): it returns
# granted at 0xd6370 before the profile is ever read at 0xd61f4, and `default_feature()` and the
# agent's virtual call are behind that read. So gates 2 and 3 cannot veto a caller that has already
# passed gate 1, no AppArmor profile has to be arranged for the experiment, and because the unit's
# wrapper ends in `exec`, the unit's environment *is* the daemon's environment -- an Environment=
# drop-in is enough. (see docs/ubuntu-touch/evidence/location-chain-2026-09-23.log section 3f)
#
# Gate 1 is the bypass the image itself ships: the unit's wrapper sets that variable when
# `getprop custom.location.testing` is "true". On this port it never is, because the v63 boot image
# installs a /bin/sh stub over /usr/bin/getprop on every boot and that stub has no `custom.*` case --
# `custom.location.testing` and `custom.location.fake` both fall to `*)` and, since the wrapper passes
# no default, print nothing. `setprop` is a no-op in the same script. So BOTH of the levers docs 82
# recommends are unreachable as shipped, and the wrapper always runs its `else` branch, i.e.
# `--provider gps::Provider --provider remote::Provider`, with the bypass off.
#
# This script therefore does three things, in that order of authority:
#
#   --status           (default) read-only: say which of the three gates is closed and whether the
#                      daemon is even on the bus. Writes nothing.
#   --request          make the request. Runs a QtPositioning client (`PositionSource`, plugin
#                      "lomiri") under qmlscene with the offscreen platform, because the client
#                      library is already built and knows how to marshal Criteria -- so nothing here
#                      has to guess a D-Bus signature. Writes only /tmp/zl1-location-request.qml.
#   --enable-testing   open gate 1 with a drop-in and restart the unit. THIS IS A PERMISSION BYPASS:
#   --disable-testing  while it is in place, anything on the device can obtain the device's location.
#                      It is the image's own testing switch, it is reversible by the command next to
#                      it, and it is a trade that belongs to the user -- do not enable it to "see what
#                      happens". --explain prints both drop-ins and changes nothing.
#
# Usage (on the device, as root):
#   zl1-location-request.sh [--status] [--request [--seconds N]] [--enable-testing] [--disable-testing]
#                           [--explain] [--quiet]
#
# Read-only in the default and --request modes: no property set, no service restarted, no /sys write,
# nothing written outside /tmp. --enable-testing/--disable-testing are the only mutating modes and both
# write exactly one file under /etc/systemd/system plus a daemon-reload and a restart of one unit.

set -u

MODE=status
SECONDS_=30
QUIET=0

UNIT=lomiri-location-service.service
DROPIN_DIR=/etc/systemd/system/${UNIT}.d
TESTING_DROPIN=${DROPIN_DIR}/zl1-testing.conf
DUMMY_DROPIN=${DROPIN_DIR}/zl1-dummy.conf
QML=/tmp/zl1-location-request.qml
WRAPPER=/usr/libexec/lxc-android-config/lomiri-location-serviced-wrapper

while [ $# -gt 0 ]; do
  case "$1" in
  --status) MODE=status; shift ;;
  --request) MODE=request; shift ;;
  --enable-testing) MODE=enable; shift ;;
  --disable-testing) MODE=disable; shift ;;
  --explain) MODE=explain; shift ;;
  --seconds) SECONDS_="${2:-30}"; shift; [ $# -gt 0 ] && shift ;;
  --quiet) QUIET=1; shift ;;
  --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0" ; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

grep -qa msm8996 /proc/device-tree/compatible 2>/dev/null ||
  { echo "not the zl1 (no msm8996 in /proc/device-tree/compatible) -- refusing" >&2; exit 1; }

say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
# The consent notice, which --quiet must not silence. This script has exactly one mode that takes
# something away from the user -- --enable-testing installs a permission bypass that lets anything on
# the device obtain its location -- and that notice was being printed through say(), i.e. it vanished
# under --quiet and the bypass got installed with nothing said. "Be quieter" means fewer read-only
# findings, never "do not tell me what I am about to give up"; the same rule the post-mortem harness
# exists to enforce on the other side (a mode that acts must be the one thing that still speaks).
warn() { printf '%s\n' "$*" >&2; }
hdr() { [ "$QUIET" = 1 ] || printf '\n== %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------------------------

# The v63 boot hook overwrites /usr/bin/getprop with a /bin/sh stub on every boot. Detect the stub,
# not the property: if this is a script, every `custom.*` answer below is worthless.
getprop_is_stub() {
  head -c 2 /usr/bin/getprop 2>/dev/null | grep -q '#!' && return 0
  grep -qa 'no-attach diagnostic' /usr/bin/getprop 2>/dev/null && return 0
  return 1
}

# gdbus is the only D-Bus CLI this image is known to carry; busctl/dbus-send are not assumed.
name_owner() {
  have gdbus || { printf 'gdbus-not-available'; return; }
  gdbus call --system --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
    --method org.freedesktop.DBus.GetNameOwner "$1" 2>/dev/null |
    sed -n "s/.*'\(.*\)'.*/\1/p"
}

unit_prop() {
  systemctl show -p "$2" --value "$1" 2>/dev/null
}

# The service's pid, and whether it shares PID 1's namespace (the bridge libraries only work with
# the container's binder, so this matters -- docs 55/56).
service_ns() {
  _pid="$(unit_prop "$UNIT" ExecMainPID)"
  case "$_pid" in ''|0) printf 'no pid'; return ;; esac
  _a="$(readlink /proc/$_pid/ns/pid 2>/dev/null)"
  _b="$(readlink /proc/1/ns/pid 2>/dev/null)"
  if [ -n "$_a" ] && [ "$_a" = "$_b" ]; then printf 'pid %s, host namespace' "$_pid"
  elif [ -n "$_a" ]; then printf 'pid %s, OTHER namespace than pid 1' "$_pid"
  else printf 'pid %s (namespace unreadable)' "$_pid"; fi
}

status_body() {
  hdr "1. the unit, and what it actually executes"
  say "  is-enabled : $(systemctl is-enabled "$UNIT" 2>&1)"
  say "  is-active  : $(systemctl is-active "$UNIT" 2>&1)"
  say "  runs as    : $(service_ns)"
  # `systemctl cat` is the only honest check that a drop-in is in effect.
  _exec="$(unit_prop "$UNIT" ExecStart | sed -n 's/.*argv\[\]=\([^;]*\).*/\1/p')"
  [ -n "$_exec" ] || _exec="$(unit_prop "$UNIT" ExecStart)"
  say "  ExecStart  : $_exec"
  if [ -d "$DROPIN_DIR" ]; then
    say "  drop-ins   : $(ls "$DROPIN_DIR" 2>/dev/null | tr '\n' ' ')"
  else
    say "  drop-ins   : none (${DROPIN_DIR} does not exist)"
  fi
  say "  wrapper    : $WRAPPER"

  hdr "2. the two levers the wrapper reads (docs 82) -- and why neither can fire here"
  if getprop_is_stub; then
    say "  /usr/bin/getprop IS THE v63 STUB (a shell script, not the libhybris binary)"
    say "    -> every custom.* answer below is empty by construction, not by property value"
  else
    say "  /usr/bin/getprop looks like the real binary (unexpected on this port)"
  fi
  say "  getprop custom.location.testing = '$(getprop custom.location.testing 2>/dev/null)'  (needs 'true')"
  say "  getprop custom.location.fake    = '$(getprop custom.location.fake 2>/dev/null)'  (needs 'true')"
  say "  setprop                         = no-op in the same boot hook, so they cannot be set either"
  say "  conclusion: gate 1 (the testing bypass) is OFF and cannot be switched on via the property"

  hdr "3. the service and the trust store on the system bus"
  _svc="$(name_owner com.lomiri.location.Service)"
  case "$_svc" in
  ''|gdbus-not-available) say "  com.lomiri.location.Service          : NOT OWNED (nobody is listening)" ;;
  *) say "  com.lomiri.location.Service          : owned by $_svc" ;;
  esac
  _ts="$(name_owner core.trust.dbus.Agent.LomiriLocationService)"
  case "$_ts" in
  ''|gdbus-not-available) say "  core.trust.dbus.Agent.LomiriLocationService : not owned (gate 3 has nobody to ask)" ;;
  *) say "  core.trust.dbus.Agent.LomiriLocationService : owned by $_ts" ;;
  esac

  hdr "4. the bridge library, mapped into the daemon"
  _pid="$(unit_prop "$UNIT" ExecMainPID)"
  case "$_pid" in ''|0) say "  no pid to inspect" ;; *)
    if grep -qa libubuntu_platform_hardware_api /proc/$_pid/maps 2>/dev/null; then
      say "  libubuntu_platform_hardware_api: MAPPED in pid $_pid (the gps::Provider half is loaded)"
    else
      say "  libubuntu_platform_hardware_api: not mapped in pid $_pid"
    fi
  ;; esac

  hdr "5. what the daemon has to say (read per unit, not with journalctl -n: the clock is wrong)"
  systemctl status --no-pager -n 20 "$UNIT" 2>&1 | sed 's/^/  /'

  hdr "6. what is still missing"
  say "$MISSING_HINT"
}

# ---------------------------------------------------------------------------------------------
# modes
# ---------------------------------------------------------------------------------------------

MISSING_HINT="read the three gates above; --explain prints the two drop-ins that open gate 1"

if [ "$MODE" = status ]; then
  status_body
  exit 0
fi

if [ "$MODE" = explain ]; then
  cat <<EOF
Two drop-ins, both on the writable /etc/systemd/system whitelist. The directory must carry the FULL
unit name: ${UNIT}.d . A bare lomiri-location-service.d/ is silently inert.

A. open gate 1 (the image's own testing switch), so that ANY caller can create a session:
   ${TESTING_DROPIN}
     [Service]
     Environment=TRUST_STORE_PERMISSION_MANAGER_IS_RUNNING_UNDER_TESTING=1
   THIS IS A PERMISSION BYPASS. While it is in place, anything on the device can obtain the device's
   location. Reversible with: $0 --disable-testing

B. run the whole UT stack on a fake coordinate, with no Android involved (docs 82's A/B):
   ${DUMMY_DROPIN}
     [Service]
     ExecStart=
     ExecStart=/usr/bin/lomiri-location-serviced --bus system --provider dummy::Provider \\
               --dummy::Provider::ReferenceLocationLat=51.505660 \\
               --dummy::Provider::ReferenceLocationLon=-0.099850
   The bare ExecStart= resets the list; without it systemd appends a second command. This is exactly
   what the wrapper would have run had getprop been readable.
   Note B is still behind gate 1: dummy::Provider goes through the same permission check, so without
   A a client still gets "Error creating session". That is a second, independent reason the
   fake-location experiment could never have produced a result on this port.

Neither is applied here. After A (or after removing it):
   systemctl daemon-reload && systemctl restart ${UNIT}
EOF
  exit 0
fi

if [ "$MODE" = enable ]; then
  warn "This installs a PERMISSION BYPASS: while it is in place, anything on the device can obtain"
  warn "the device's location. It is the image's own testing switch and it is reversible with"
  warn "  $0 --disable-testing"
  mkdir -p "$DROPIN_DIR" || { echo "cannot create $DROPIN_DIR" >&2; exit 1; }
  cat > "$TESTING_DROPIN" <<'EOF'
[Service]
Environment=TRUST_STORE_PERMISSION_MANAGER_IS_RUNNING_UNDER_TESTING=1
EOF
  say "wrote $TESTING_DROPIN"
  systemctl daemon-reload || true
  systemctl restart "$UNIT" || true
  sleep 3
  say "restarted $UNIT; gate 1 is now open for every caller"
  say "run: $0 --request"
  exit 0
fi

if [ "$MODE" = disable ]; then
  if [ -f "$TESTING_DROPIN" ]; then
    rm -f "$TESTING_DROPIN"
    say "removed $TESTING_DROPIN"
  else
    say "nothing to remove ($TESTING_DROPIN absent)"
  fi
  systemctl daemon-reload || true
  systemctl restart "$UNIT" || true
  say "restarted $UNIT; gate 1 is closed again"
  exit 0
fi

# ---- --request --------------------------------------------------------------------------------
# The client. The plugin key is "lomiri" (from the .so's own metadata: "Keys": ["lomiri"],
# "Provider": "lomiri", "Position": true), and PositionSource is exported as QtPositioning
# PositionSource 5.0. Signals used here (positionChanged, sourceErrorChanged, validityChanged,
# updateTimeout) are the ones libQt5PositioningQuick.so.5.15.13 registers.
say "gate 1 status first (a request that is rejected is itself the measurement):"
if [ -f "$TESTING_DROPIN" ]; then
  say "  ${TESTING_DROPIN} present -> gate 1 open"
else
  say "  ${TESTING_DROPIN} absent  -> gate 1 closed; expect Error creating session"
  say "  (that outcome still tells you the door was reached and the lock refused)"
fi

cat > "$QML" <<EOF
import QtQuick 2.0
import QtPositioning 5.0

Item {
    property int deadlineMs: $((SECONDS_ * 1000))

    PositionSource {
        id: src
        name: "lomiri"
        updateInterval: 1000
        active: true

        onPositionChanged: console.log("ZL1POS position lat=" + position.coordinate.latitude +
                                       " lon=" + position.coordinate.longitude +
                                       " valid=" + position.isValid +
                                       " acc=" + position.horizontalAccuracy +
                                       " ts=" + position.timestamp)
        onSourceErrorChanged: console.log("ZL1POS sourceError=" + sourceError)
        onValidityChanged: console.log("ZL1POS valid=" + valid)
        onUpdateTimeout: console.log("ZL1POS updateTimeout")
        Component.onCompleted: console.log("ZL1POS ready name=" + name + " valid=" + valid +
                                           " active=" + active +
                                           " supportedMethods=" + supportedPositioningMethods)
    }

    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: console.log("ZL1POS tick active=" + src.active + " valid=" + src.valid +
                                 " err=" + src.sourceError +
                                 " lat=" + (src.position && src.position.isValid
                                           ? src.position.coordinate.latitude : "none"))
    }
    Timer {
        interval: deadlineMs
        running: true
        onTriggered: { console.log("ZL1POS deadline, quitting"); Qt.quit() }
    }
}
EOF

_pid_before="$(unit_prop "$UNIT" ExecMainPID)"
_restarts_before="$(unit_prop "$UNIT" NRestarts)"

say ""
say "starting the client for ${SECONDS_}s: /usr/lib/qt5/bin/qmlscene (offscreen), plugin 'lomiri'"
if [ ! -x /usr/lib/qt5/bin/qmlscene ]; then
  echo "no /usr/lib/qt5/bin/qmlscene on this image -- cannot make the request" >&2
  exit 1
fi

QT_QPA_PLATFORM=offscreen \
QML2_IMPORT_PATH=/usr/lib/aarch64-linux-gnu/qt5/qml \
XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}" \
HOME="${HOME:-/root}" \
  /usr/lib/qt5/bin/qmlscene "$QML" 2>&1 | sed 's/^/  /'

_pid_after="$(unit_prop "$UNIT" ExecMainPID)"
_restarts_after="$(unit_prop "$UNIT" NRestarts)"

say ""
say "after the request:"
say "  ExecMainPID ${_pid_before} -> ${_pid_after}"
say "  NRestarts   ${_restarts_before} -> ${_restarts_after}"
[ "$_restarts_after" != "$_restarts_before" ] &&
  say "  NOTE the daemon restarted -- read its log below for why"
say ""
say "how to read this:"
say "  ZL1POS ready ... supportedMethods=0        -> the plugin loaded but no backend (wrong plugin name?)"
say "  tick active=true valid=false, never a position, no sourceError -> the session was refused"
say "  sourceError != 0                           -> read the daemon's log for the reason"
say "  a position arrives                         -> CreateSessionForCriteria passed AND"
say "                                                StartPositionUpdates ran AND"
say "                                                u_hardware_gps_start was called (docs 93 section 2)"
say ""
say "the daemon's own view (this is where 'Client lacks permissions...' would appear):"
systemctl status --no-pager -n 30 "$UNIT" 2>&1 | sed 's/^/  /'
say ""
say "if a session was created, its object path is under /com/lomiri/location/Service:"
if have gdbus; then
  gdbus call --system --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
    --method org.freedesktop.DBus.GetNameOwner com.lomiri.location.Service 2>&1 | sed 's/^/  /'
  gdbus introspect --system --dest com.lomiri.location.Service \
    --object-path /com/lomiri/location/Service 2>&1 | sed -n '1,40p' | sed 's/^/  /'
else
  say "  (gdbus not available)"
fi

exit 0
