#!/bin/bash
# install-ofono-binder.sh -- give ofono the modem this port has always had and never enumerated.
#
# WHAT WAS WRONG (measured on the device 2026-09-25, docs 168). The modem was never missing: the
# subsystem is ONLINE, the firmware is at /vendor/firmware_mnt/image, rild runs and the Android
# radio HAL is registered and live in the container (lshal's FIRST table:
# `Y android.hardware.radio@1.1::IRadio/slot1` and `/slot2`). What was missing was every one of the
# three things ofono needs to reach it. Each is independently fatal, and each failed silently.
#
#   1. THE PLUGIN. `ofonod-wrapper` picks the ofono plugin by asking
#      `device-info get OfonoPlugin` and defaulting to the **ril** plugin otherwise. On this port
#      that command **segfaults for every key** (exit 139) -- `device-info` links
#      `libandroid-properties.so.1`, and a host process cannot complete an Android property read
#      here (the same crash, at the same place, is reproducible from python3 with ctypes: it maps
#      `/dev/__properties__/property_info` and `/properties_serial`, then dies at si_addr=0xb00).
#      So the wrapper always takes the `else` branch: it disables the **binder** plugin and enables
#      ril -- the one plugin that cannot work on this Android. Measured on the running ofonod's
#      /proc/<pid>/maps: `rilplugin.so` and `rilbinderplugin.so` are loaded, `binderplugin.so` is
#      not.
#
#      Why ril cannot work: `rilplugin.so` is libgrilio over a **socket**, and
#      /etc/ofono/ril_subscription.conf points it at `socket=/dev/socket/rild`. That socket does
#      not exist and cannot be made to: the vendor image's only rild service file,
#      `/vendor/etc/init/rild.legacy.rc`, declares **no `socket rild` directive** (the whole file
#      is nine lines: class/user/group/capabilities), and /dev/socket/qmux_radio/ holds only
#      qcril_radio_config0|1 and rild_sync_0|1. `rilbinderplugin.so` wants the pre-Android-8
#      `rild` **binder service**, which HIDL-era rild does not register either.
#
#   2. THE NAMESPACE. Every Android binder, and therefore every HAL lookup over /dev/hwbinder, only
#      completes between processes in the **same PID namespace** (docs 43, 55, 60, 62 -- this is
#      the fifth service behind that same wall). Measured with the identical ofonod command line:
#        host namespace:      `[gbinder] WARNING: registerForNotifications(
#                              android.hardware.radio.config@1.0::IRadioConfig) failed`
#        container namespace: `[gbinder-radio] Connected to android.hardware.radio@1.1::IRadio/slot1`
#                             `[gbinder-radio] Connected to android.hardware.radio@1.1::IRadio/slot2`
#      So ofonod has to run through `zl1-ns-exec`, exactly like bluebinder and sensorfwd.
#
#   3. THE CONFIG. With the plugin and the namespace right, the binder plugin still refuses:
#      `Missing path for slot slot1` / `slot2`. `binderplugin.so` reads **/etc/ofono/binder.conf**
#      (upstream: mer-hybris/ofono-binder-plugin, whose README says "For reliable startup,
#      /etc/ofono/binder.conf has to list all expected slots"), and `path` -- the ofono modem
#      object path -- "must appear in the section(s) for the respective slot(s)". Two device
#      specifics go with it: the plugin's `radioInterface` defaults to **1.2** and this device
#      registers only 1.0 and 1.1, and the slots are `slot1`/`slot2`. /etc/ofono is on the
#      read-only image and is **not** in /etc/fstab's bind whitelist (`/var/lib/ofono` is, which is
#      ofono's storage, not its config), so the file is supplied through the unit file instead --
#      `BindPaths=` gives ofonod a private /etc/ofono that shadows the read-only one without
#      mounting anything globally.
#
# THE PROOF this installer is built around, obtained at runtime before it was written (private
# bus, container namespace, binder.conf in place):
#
#   busctl --address=unix:path=$B call org.ofono / org.ofono.Manager GetModems
#   a(oa{sv}) 2 "/ril_0" "Online" b false "Powered" b true "Revision" s "MPSS.TH.2.0.c1.9.1-00044"
#               "Serial" s "861579037654648" ... "/ril_1" ... "Serial" s "861579037654655" ...
#
# Two modems, each with the modem processor's real firmware revision and a real IMEI. Before this,
# `GetModems` answered `a(oa{sv}) 0` on every boot of this port.
#
# WHAT THIS SCRIPT DOES NOT DO. It does not touch the modem partition, any block device, or any
# Android image; it writes three regular files (a drop-in, a config dir on /userdata, and the
# config file in it). It does not set `extPlugin` -- the QTI extension
# (`qtibinderpluginext.so`, which is installed and loaded standalone) is what carries IMS/VoLTE
# specifics, and it is not needed to enumerate a modem. `--remove` puts ofono back exactly where
# the image left it, and the fix is one `systemctl restart` either way: no reboot is involved.
#
# Usage: install-ofono-binder.sh --install | --remove | --status
# Env: ZL1_HOST (default root@10.15.19.82)

set -uo pipefail

DEV="${ZL1_HOST:-root@10.15.19.82}"
STAGE=/userdata/zl1-ofono
WRAPPER=/userdata/zl1-hybris/bin/zl1-ns-exec
DROPIN=/etc/systemd/system/ofono.service.d/zz-zl1-ofono.conf
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$DEV")
SCP=(scp -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

# The plugin list, passed to ofonod as `-P` (disable). It is the shipped wrapper's list plus every
# spelling of the two ril plugins, because ofono's name matching is not obvious and getting it
# wrong is silent: `-P ril` prints BOTH "Excluding RIL modem driver" and "Excluding Sailfish OS RIL
# plugin", while `-P rilbinder` prints neither -- so the only faithful reading is "add the
# spellings", since a name that matches no plugin is inert (measured: `-P rilplugin` and
# `-P rilbinderplugin` change nothing). The list must NOT contain `binder`: that is the plugin we
# are here to enable, and `-P binder` is exactly what the shipped wrapper does to it.
NOPLUGINS='stktest,sap,udev,dun,smart,hfp,hfp_bluez5,provision,ril,rilplugin,rilbinder,rilbinderplugin'

guard() {
  "${SSH[@]}" 'grep -qa msm8996 /proc/device-tree/compatible' 2>/dev/null ||
    { echo "not the zl1 (no msm8996 in /proc/device-tree/compatible) -- refusing" >&2; exit 1; }
}

# The config file. `radioInterface=1.1` is not a preference: this device registers
# android.hardware.radio 1.0 and 1.1 only, and the plugin defaults to 1.2.
binder_conf() {
  cat <<'EOF'
# /etc/ofono/binder.conf for the zl1 -- supplied by install-ofono-binder.sh, see its header.
#
# The binder plugin's own defaults: the slot list comes from hwservicemanager (which is why the
# slots are named slot1/slot2 here -- those are the service instance names), `path` is the ofono
# modem object path and must be given per slot, and `radioInterface` defaults to 1.2 while this
# device registers 1.0 and 1.1.

[Settings]
# Listed so ofono does not start before the modem adaptation and miss a slot (upstream README:
# "For reliable startup, /etc/ofono/binder.conf has to list all expected slots").
ExpectSlots=slot1,slot2

[slot1]
path=/ril_0
radioInterface=1.1

[slot2]
path=/ril_1
radioInterface=1.1
EOF
}

case "${1:-}" in
--install)
  guard
  "${SSH[@]}" "test -x $WRAPPER" 2>/dev/null || {
    echo "refusing: $WRAPPER is not on the device. It is the container-PID-namespace wrapper and" >&2
    echo "nothing here can work without it. Install it first:" >&2
    echo "  scripts/hybris-shims/install-container-ns-services.sh --install" >&2
    exit 1
  }

  # The payload: a private /etc/ofono. The image's own files are copied rather than re-created, so
  # `main.conf` (whose [ModemManager] AutoSelectDataSim is the one setting here that is not a
  # default) keeps whatever the image ships.
  tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
  binder_conf > "$tmp"
  sed -i '/./,$!d' "$tmp"
  "${SSH[@]}" "mkdir -p $STAGE/etc && cp -a /etc/ofono/main.conf /etc/ofono/phonesim.conf \
    /etc/ofono/ril_subscription.conf $STAGE/etc/ 2>/dev/null; ls -l $STAGE/etc/"
  # No `2>/dev/null` on the push: the first version of this line had one, and an undefined SCP
  # array (the bug it was hiding) reached the operator as "could not push binder.conf" with the
  # real error thrown away. A refusal that does not say why is the failure mode this repo keeps
  # writing instruments about.
  "${SCP[@]}" "$tmp" "$DEV:$STAGE/etc/binder.conf" ||
    { echo "refusing: could not push binder.conf" >&2; exit 1; }
  "${SSH[@]}" "chmod 644 $STAGE/etc/binder.conf"

  # The drop-in. `ExecStart=` first: the shipped lxc-android-config drop-in points ExecStart at
  # ofonod-wrapper, and systemd applies drop-ins in one lexicographic order, so `zz-` wins and an
  # empty assignment is what clears the earlier value.
  #
  # BindPaths= is doing the work /etc/fstab does for the paths it whitelists: ofonod gets a private
  # mount namespace in which /etc/ofono is $STAGE/etc. Nothing global is mounted, nothing is
  # hidden from any other process, and the namespace is inherited by zl1-ns-exec's child (that
  # wrapper only enters the PID namespace, never the mount one).
  "${SSH[@]}" "mkdir -p /etc/systemd/system/ofono.service.d && cat > $DROPIN <<'UNIT'
[Service]
# BindPaths= hides the read-only /etc/ofono from ofonod only. $STAGE/etc holds the image's
# main.conf/phonesim.conf/ril_subscription.conf plus the binder.conf this port needs.
BindPaths=$STAGE/etc:/etc/ofono
Environment=OFONO_SYSTEM_APNDB_PATH=/usr/share/lineageos-apndb/apns-conf.xml
# The shipped drop-in runs ofonod-wrapper, which asks a segfaulting device-info which plugin to
# use and picks ril. This is that list with the binder plugin enabled instead.
ExecStart=
ExecStart=$WRAPPER /usr/sbin/ofonod -P $NOPLUGINS --nodetach
UNIT
systemctl daemon-reload && systemctl reset-failed ofono >/dev/null 2>&1; systemctl restart ofono"
  echo
  echo "installed. ofono is restarting; verifying..."
  sleep 12
  "${SSH[@]}" 'bash -s' <<'REMOTE'
echo "  unit:     $(systemctl is-active ofono 2>&1)  ($(systemctl show -p MainPID --value ofono))"
echo "  cmdline:  $(systemctl show -p ExecStart --value ofono | sed "s/.*argv\[\]=//; s/ ;.*//")"
echo -n "  GetModems: "
busctl --system call org.ofono / org.ofono.Manager GetModems 2>&1 | head -c 220; echo
REMOTE
  echo
  echo "  A modem is present iff that line starts with 'a(oa{sv}) 2'. The device detail (IMEI,"
  echo "  firmware revision, SIM state) is: $0 --status"
  ;;
--remove)
  guard
  "${SSH[@]}" "rm -f $DROPIN && rmdir /etc/systemd/system/ofono.service.d 2>/dev/null
    systemctl daemon-reload; systemctl reset-failed ofono >/dev/null 2>&1; systemctl restart ofono
    sleep 8
    echo \"  unit:      \$(systemctl is-active ofono 2>&1)\"
    echo \"  cmdline:   \$(systemctl show -p ExecStart --value ofono | sed 's/.*argv\\[\\]=//; s/ ;.*//')\"
    echo -n \"  GetModems: \"; busctl --system call org.ofono / org.ofono.Manager GetModems 2>&1 | head -c 80; echo"
  echo
  echo "  ofono is back on the image's own wrapper (which picks the ril plugin, whose socket"
  echo "  /dev/socket/rild this Android never creates). The payload in $STAGE is left in place;"
  echo "  remove it with: ssh $DEV rm -rf $STAGE"
  ;;
--status)
  guard
  "${SSH[@]}" "STAGE='$STAGE' WRAPPER='$WRAPPER' DROPIN='$DROPIN' bash -s" <<'REMOTE'
set -u
echo "boot_id: $(cat /proc/sys/kernel/random/boot_id)"
echo
# WHICH PROCESS IS OFONOD. `MainPID` is not it once the wrapper is in place: systemd's main PID is
# **nsenter**, which forks (that is how a PID namespace is entered at all -- setns only affects
# children created afterwards), and ofonod is that child. Reading the plugin map or the PID
# namespace from MainPID therefore answers about nsenter, and answered "the binder plugin is not
# loaded" on the very boot where two modems were enumerated, because nsenter's maps contain no
# plugin at all.
#
# The unit's cgroup holds every process in the unit, and on this device the hierarchy is **cgroup
# v1** (`/sys/fs/cgroup/` has blkio/cpu/cpuacct/... and there is no `cgroup.procs` under the unified
# path), so the listing is at `systemd/<ControlGroup>/cgroup.procs`. Both layouts are tried. A
# `/proc` scan is deliberately NOT the fallback: it would have to guess between an ofonod this unit
# started and any stray one, while `MainPID` at least cannot be the wrong unit.
CG=$(systemctl show -p ControlGroup --value ofono 2>/dev/null)
P=""
for procs in "/sys/fs/cgroup/systemd$CG/cgroup.procs" "/sys/fs/cgroup$CG/cgroup.procs"; do
  [ -r "$procs" ] || continue
  for q in $(cat "$procs" 2>/dev/null); do
    case "$(tr '\0' ' ' < "/proc/$q/cmdline" 2>/dev/null)" in
      *ofonod*) P=$q;;
    esac
  done
  [ -n "$P" ] && break
done
if [ -z "$P" ]; then
  P=$(systemctl show -p MainPID --value ofono)
  echo "   (no ofonod in the unit cgroup; falling back to MainPID $P, which may be the wrapper)"
fi
echo "== 1. the plugin ofono is actually running"
if [ -n "$P" ] && [ -r "/proc/$P/maps" ]; then
  grep -ao "/[^ ]*ofono-sailfish/plugins/[a-z]*\.so" "/proc/$P/maps" 2>/dev/null | sort -u |
    sed 's/^/   mapped: /'
  # The slash in the pattern is not decoration: `rilbinderplugin.so` contains the substring
  # `binderplugin.so`, so an unanchored grep reports the binder plugin as loaded on a boot where
  # the only thing mapped is the ril-over-binder one -- the exact wrong answer this line exists to
  # give. Measured, before the anchor was added.
  case "$(grep -ac '/binderplugin\.so' "/proc/$P/maps" 2>/dev/null)" in
    0) echo "   -> binderplugin.so is NOT loaded: no HIDL radio HAL can be reached.";;
    *) echo "   -> binderplugin.so IS loaded.";;
  esac
  echo "   running: $(tr '\0' ' ' < "/proc/$P/cmdline" 2>/dev/null)"
else
  echo "   ofono has no main PID (not running)"
fi
echo "   unit ExecStart: $(systemctl show -p ExecStart --value ofono | sed 's/.*argv\[\]=//; s/ ;.*//')"
echo
echo "== 2. the namespace it runs in, and the wall that makes it necessary"
A=$(lxc-info -n android -pH 2>/dev/null | head -1)
[ -n "$A" ] && echo "   android container pid: $A   (ofonod must be a descendant of it)" ||
  echo "   android container: NOT RUNNING"
if [ -n "$P" ]; then
  Pns=$(readlink "/proc/$P/ns/pid" 2>/dev/null)
  Ans=$(readlink "/proc/$A/ns/pid" 2>/dev/null)
  echo "   ofonod pid ns: ${Pns##*:}   container pid ns: ${Ans##*:}"
  [ "$Pns" = "$Ans" ] && echo "   -> same PID namespace: HAL lookups can complete." ||
    echo "   -> DIFFERENT PID namespace: every IRadio::getService() returns null."
fi
echo "   the socket the ril plugin would need: $(ls -l /dev/socket/rild 2>&1 | head -1)"
echo "   what /dev/socket/qmux_radio/ really holds: $(ls /dev/socket/qmux_radio/ 2>/dev/null | tr '\n' ' ')"
echo
echo "== 3. the config the binder plugin reads"
if [ -r "$STAGE/etc/binder.conf" ]; then
  echo "   $STAGE/etc/binder.conf:"
  sed 's/^/   | /' "$STAGE/etc/binder.conf"
else
  echo "   $STAGE/etc/binder.conf: ABSENT"
fi
[ -r "$DROPIN" ] && { echo "   drop-in $DROPIN:"; sed 's/^/   | /' "$DROPIN"; } ||
  echo "   drop-in $DROPIN: ABSENT"
echo
echo "== the answer that matters"
echo -n "   GetModems: "
busctl --system call org.ofono / org.ofono.Manager GetModems 2>&1 | head -c 400; echo
REMOTE
  ;;
--help|-h)
  # The header whatever its current length, not a fixed line range: a range truncates the usage
  # text the moment the header grows past it (docs 104, 108), and `zl1-cli-usage-selftest.sh`
  # sweeps every `*.sh` in this tree for exactly that shape. It also appends a line to a copy of
  # the header and requires the printed block to grow by one, which a range cannot do.
  awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; exit 0;;
*)
  echo "unknown argument: ${1:-} (try --help)" >&2
  exit 2;;
esac
