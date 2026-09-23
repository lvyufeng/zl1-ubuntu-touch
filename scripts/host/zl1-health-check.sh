#!/usr/bin/env bash
# Is the zl1 back, and is it in a state worth starting a stage from? One command, first thing.
#
# Why this exists: every stage of this port begins with the same ten-minute hand-check -- is it on the
# bus, which mode is it in, is `usb0` carrying traffic, does SSH answer, is the container up, are the
# units that own the screen and the sensors alive, is the keeper still stopped, how hot is it -- and
# after 2026-09-23 there is a fourth possibility that changes everything: **the device is in Qualcomm
# EDL**, unreachable, waiting for a finger. Re-deriving that under pressure is how a session gets off
# to a bad start, and the modes are not distinguishable by "ping fails".
#
# It is deliberately a *router*: it tells you which of the known states you are in and which one
# command to run next, rather than trying everything itself. The two recovery paths it points at
# already exist and are better than anything reimplemented here:
#
#   * RNDIS present but no traffic  -> scripts/host/zl1-rndis-recover.sh  (host-side re-enumeration;
#     docs 76: the stall lives on the host and the device is fine -- the device kept its uptime)
#   * EDL                           -> nothing software; a long power press (docs 49 section 6: that
#     is how it came back last time, and neither a USB rebind nor waiting did anything)
#
# Read-only with respect to the device: it pings, it SSHes and reads, it inspects the host's USB tree.
# It never writes a sysfs node, never flashes, never runs a QDL/firehose tool, and it does not run the
# RNDIS recovery for you (that is a write to the host's USB stack, and it is a separate decision).
#
# Usage: zl1-health-check.sh [--quiet] [--no-ssh]
#   --quiet   only the verdict and the next command
#   --no-ssh  stop after the USB/link survey (useful when SSH is known to be wedged)
#
# Exit codes: 0 the device is up and the self-check passed; 1 up but something in the check failed;
#             2 not reachable (EDL, no link, or absent).

set -uo pipefail

HOST="${ZL1_HOST:-root@10.15.19.82}"
IP="${ZL1_IP:-10.15.19.82}"
SERIAL_PREFIX="${ZL1_SERIAL:-33e80afe}"
QUIET=0
NO_SSH=0

while [ $# -gt 0 ]; do
  case "$1" in
  --quiet) QUIET=1; shift ;;
  --no-ssh) NO_SSH=1; shift ;;
  --help|-h) sed -n '2,30p' "$0"; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

say() { [ "$QUIET" = 1 ] && [ "$1" != "" ] && return 0; printf '%s\n' "$*"; }
always() { printf '%s\n' "$*"; }

# --- the device on the host's USB tree -----------------------------------------------------------

# Print "<bus-port> <vid:pid> <serial> <product> <manufacturer>" for every USB device, one per line,
# so the classification below is one loop rather than several greps that can disagree.
usb_table() {
  for d in /sys/bus/usb/devices/*/; do
    v=$(cat "$d/idVendor" 2>/dev/null) || continue
    p=$(cat "$d/idProduct" 2>/dev/null) || continue
    printf '%s %s:%s %s %s %s\n' "$(basename "$d")" "$v" "$p" \
      "$(cat "$d/serial" 2>/dev/null | tr -d '\n')" \
      "$(cat "$d/product" 2>/dev/null | tr -d '\n')" \
      "$(cat "$d/manufacturer" 2>/dev/null | tr -d '\n')"
  done
}

MODE="absent"
PORT=""
DETAIL=""

while read -r port vidpid serial product mfr; do
  case "$vidpid" in
  # 05c6:9008 is the SoC's emergency download loader. No serial, product QUSB__BULK. This is the state
  # docs 49 section 5 fell into and docs 80 section 7 fell into again.
  05c6:9008)
    MODE="edl"; PORT="$port"; DETAIL="$product $mfr" ;;
  # The RNDIS gadget the port boots into. The serial is the *only* safe discriminator (docs 76): an
  # unrelated Xiaomi on this bus can present the same IDs.
  *)
    case "$serial" in
    "$SERIAL_PREFIX"*)
      MODE="rndis"; PORT="$port"; DETAIL="$vidpid serial=$serial" ;;
    esac ;;
  esac
done < <(usb_table)

# --- report + route ------------------------------------------------------------------------------

NS="$(date +%Y-%m-%dT%H:%M:%S)"
always "zl1 health check :: $NS"

case "$MODE" in
absent)
  always "== device: NOT ON THE USB BUS"
  always "   Nothing with serial $SERIAL_PREFIX* and nothing in EDL (05c6:9008) is present."
  always "   - if the phone is off, press power once;"
  always "   - if it is on but not enumerating, try another port or cable (this port is $PORT);"
  always "   - check the host is not holding a stale gadget:  lsusb -d 05c6: -d 18d1:"
  always ""
  always "next: plug it in and re-run this script"
  exit 2 ;;

edl)
  always "== device: IN QUALCOMM EDL (05c6:9008, $DETAIL, port $PORT)"
  say "   The SoC is in the emergency download loader. There is no network, no SSH, no shell:"
  say "   the only thing this port does is wait for a firehose downloader, which this project"
  say "   does not use (\"在 EDL 中不要使用 QFIL 类工具\" -- and nothing here has ever written a"
  say "   partition, so there is nothing to download anyway)."
  say ""
  always "   RECOVERY IS PHYSICAL, and it is the procedure that worked on this device:"
  always "     ** long-press POWER for 10-20 s **   (docs/ubuntu-touch/49 section 6 -- that is how it"
  always "     came back from the previous EDL trip; a USB unbind/rebind and simply waiting were both"
  always "     tried and both did nothing)"
  say "   Then it should re-appear as the RNDIS gadget (port may change); re-run this script."
  say "   After it boots, the self-check below runs by itself; the two things that prove it is the"
  say "   right device are the device-tree model and that \`adb devices\` has no $SERIAL_PREFIX."
  say ""
  say "   Do NOT: run QFIL/qdl/firehose, unbind cnss/cnss_pci (docs 49: that is what caused one of"
  say "   these), or flash anything. There is no software exit from EDL on this device."
  always ""
  always "next: long-press POWER 10-20 s, then re-run this script"
  exit 2 ;;

rndis)
  always "== device: ON THE BUS as the RNDIS gadget (port $PORT, $DETAIL)"
  ;;
esac

# The host side: rndis_host must be bound and usb0 must exist with our addresses.
IFACE=""
for i in /sys/class/net/*/; do
  n=$(basename "$i")
  case "$n" in
  usb*|enx*) IFACE="$n" ;;
  esac
done
say "== host interface: ${IFACE:-<none>}"
if [ -z "$IFACE" ]; then
  always "   no usb0/enx* interface: rndis_host is not bound to the gadget."
  always "   that is a host-side problem and it has its own tool (docs 76 -- the device is fine):"
  always "     sudo scripts/host/zl1-rndis-recover.sh"
  always "   or make it automatic:  scripts/host/install-zl1-udev-rule.sh"
  exit 2
fi

addr="$(ip -4 -br addr show "$IFACE" 2>/dev/null | awk '{print $3}')"
say "   $IFACE: ${addr:-<no IPv4>}"
say "   link: $(cat /sys/class/net/$IFACE/operstate 2>/dev/null)  carrier: $(cat /sys/class/net/$IFACE/carrier 2>/dev/null)"

# A ping is not a link test on its own (docs 76: the stall is in the host's *receive* direction while
# the device's own counters look perfect). So: ping, then an SSH that actually reads something.
if ! timeout 6 ping -c 2 -W 3 "$IP" >/dev/null 2>&1; then
  always "   ping $IP: no reply"
  always ""
  always "   That is the known host-side stall shape (docs/ubuntu-touch/76): the device is running"
  always "   and its counters are clean; what is broken is the host's receive direction. Do not reboot"
  always "   the phone for this. Run the host-side recovery, which needs no replug and no key press:"
  always "     sudo scripts/host/zl1-rndis-recover.sh --status     # look first"
  always "     sudo scripts/host/zl1-rndis-recover.sh              # escalate until it carries traffic"
  exit 2
fi
say "   ping $IP: ok"

if [ "$NO_SSH" = 1 ]; then
  always ""
  always "next: --no-ssh was given; re-run without it for the self-check"
  exit 0
fi

ssh_d() {
  timeout 20 ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=8 "$HOST" "$@" 2>/dev/null
}

if ! out="$(ssh_d 'echo ok')" || [ "$out" != ok ]; then
  always "   ssh $HOST: no answer (ping worked, so this is the link or the session, not the device)"
  always "     sudo scripts/host/zl1-rndis-recover.sh"
  exit 2
fi
say "   ssh: ok"

# --- the self-check -----------------------------------------------------------------------------

# One SSH round trip for everything cheap, so a slow link does not turn this into a two-minute wait.
CHK="$(ssh_d '
  echo "model=$(tr -d "\0" < /proc/device-tree/compatible 2>/dev/null | tr -d "\n")"
  echo "modelname=$(tr -d "\0" < /proc/device-tree/model 2>/dev/null | tr -d "\n")"
  echo "uptime=$(awk "{printf \"%d\", \$1}" /proc/uptime)"
  echo "kernel=$(uname -r)"
  echo "host=$(hostname)"
  echo "failed=$(systemctl --failed --no-legend --no-pager 2>/dev/null | grep -ac .)"
  echo "lxc=$(lxc-info -n android -pH 2>/dev/null | head -1)"
  echo "outputs=$(busctl --system get-property com.lomiri.SystemCompositor.Display /com/lomiri/SystemCompositor/Display com.lomiri.SystemCompositor.Display ActiveOutputs 2>/dev/null)"
  for u in sensorfwd repowerd lightdm; do
    echo "unit_$u=$(systemctl is-active $u 2>/dev/null)"
  done
  echo "keeper=$(for p in /proc/[0-9]*; do c=$(tr "\0" " " < $p/cmdline 2>/dev/null); case \"$c\" in *zl1-debug-net.sh*) echo \"$(awk "{print \$3}" $p/stat)\"; break ;; esac; done)"
  echo "thermal=$(cat /sys/class/thermal/thermal_zone1/temp 2>/dev/null)"
  echo "gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
  echo "load=$(cut -d\" \" -f1-3 /proc/loadavg)"
  adb devices 2>/dev/null | sed -n "s/^\(.*\)\tdevice$/adb=\1/p"
' )"

field() { printf '%s\n' "$CHK" | sed -n "s/^$1=//p"; }

model="$(field model)"
if [ "$model" = "M\n" ] || [ -z "$model" ]; then
  model="$(field modelname)"
fi
say "== device: $(field modelname)  [$(field kernel)]  uptime $(field uptime) s  load $(field load)"
case "$(field modelname)" in
*"LE_ZL1"*) say "   model check: this is the zl1" ;;
*) always "   WARNING: device-tree model is \"$(field modelname)\" -- not the zl1. Stop." ; exit 1 ;;
esac

adb_ser="$(field adb)"
if [ -n "$adb_ser" ]; then
  always "   WARNING: adb sees \"$adb_ser\". On this port the self-check wants no adb device for the"
  always "   zl1 (docs 49 section 6), because that is the stock-Android appearance, not the UT one."
fi

failed="$(field failed)"
[ "${failed:-0}" = 0 ] && say "   units: no failures" || always "   WARNING: $failed failed unit(s):  systemctl --failed"

lxc="$(field lxc)"
[ -n "$lxc" ] && say "   container: RUNNING (pid $lxc)" || always "   WARNING: no android container (lxc-info gave nothing)"

for u in sensorfwd repowerd lightdm; do
  s="$(field unit_$u)"
  case "$s" in
  active) say "   $u: active" ;;
  *) always "   WARNING: $u is ${s:-absent} (docs 69: repowerd dies unless it starts after sensorfwd's READY=1; it is the only owner of screen policy)" ;;
  esac
done

say "   display: ActiveOutputs $(field outputs)"
keeper="$(field keeper)"
case "$keeper" in
T) say "   debug keeper: STOPPED (state T) -- the quieter runtime state, docs 72" ;;
"") say "   debug keeper: not running" ;;
*) say "   debug keeper: RUNNING (state $keeper) -- it costs ~a core and makes systemd reload every ~6s; scripts/device/zl1-quiet-debug-keeper.sh --stop" ;;
esac

t="$(field thermal)"
[ -n "$t" ] && say "   thermal_zone1: $(awk -v m="$t" 'BEGIN{printf "%.1f", m/1000}') C" || say "   thermal_zone1: unreadable"
say "   cpu0 governor: $(field gov)"

# --- what to run next ---------------------------------------------------------------------------

always ""
always "== what is owed, in the order it has to be done (0-series first: each one is only"
always "== answerable by the boot you are on, or by the next one)"
always "   0. what killed the boot before this one -->  ONCE, and before the rest (docs 86):"
always "                                                scp scripts/device/zl1-edl-postmortem.sh root@$IP:/tmp/ && \\"
always "                                                ssh root@$IP 'sh /tmp/zl1-edl-postmortem.sh'"
always "      (read-only: pstore + the kmsg archive. A kernel panic on this device resets straight into"
always "       EDL -- download_mode=1 and a forced watchdog bite on panic -- so the trip of 2026-09-23"
always "       has a witness, and this is the boot where it is still readable)"
always "   0b. who configured rndis0's addresses on this boot (docs 88), which is what licenses"
always "       retiring the debug keeper -- a full core, and the second heat source on this port:"
always "                                                scp scripts/device/zl1-boot-address-check.sh root@$IP:/tmp/ && \\"
always "                                                ssh root@$IP 'sh /tmp/zl1-boot-address-check.sh'"
always "      (exit 0 = netwatch-configured: the addresses came from our own service, before any heal,"
always "       so the keeper is no longer the only thing that can do it. exit 1 = do not retire it yet)"
always "   0c. the automatic panic -> EDL path, which is armed by default (docs 89). Two halves, and"
always "       the first one is free: it only starts saving evidence that nothing saves today"
always "                                                scripts/install-no-edl-on-panic.sh --capture-only"
always "       and the second one is a device write -- offer it, do not assume it:"
always "                                                scripts/install-no-edl-on-panic.sh --install"
always "      (--capture-only copies /sys/fs/pstore/* onto /userdata at every boot and touches no"
always "       policy; --install also writes 0 to the download_mode module parameter, read-back"
always "       verified, and FAILS the unit if the flag did not clear. It removes ONE gate: the forced"
always "       watchdog bite is untouched and whether this bootloader enters EDL independently of the"
always "       flag is untested, so a trip can still happen and is still attributed by 0. above)"
always "   1. GUI / camera on screen   ->  bash scripts/host/zl1-camera-app-test.sh --keep-display"
always "      (turns the display on, measures the compositor with and without the app, grabs a shot,"
always "       restores the display; doc 84. Look at the phone yourself when it says --keep-display)"
always "   1b. the orientation value -- the \"it keeps going landscape\" bug (docs 92, which corrects"
always "       91), and it needs one hand: the phone UPRIGHT IN PORTRAIT, screen facing you"
always "                                                scp scripts/device/zl1-orientation-axes.sh root@$IP:/tmp/ && \\"
always "                                                ssh root@$IP 'sh /tmp/zl1-orientation-axes.sh --seconds 30 --portrait-up'"
always "      (read-only, changes nothing. An upright phone should report 4 = BottomDown, which this"
always "       stack turns into PortraitOrientation; that verdict is AXES-OK and it retires the whole"
always "       \"fix the accelerometer matrix\" family. 1 or 2 = AXES-SWAPPED (the only case that"
always "       licenses a matrix trial, and --explain prints the reversible way to run it), 3 ="
always "       AXES-INVERTED, 5/6 = the phone was flat, so hold it up and run again. NOTE the flat"
always "       run (--flat-up) can decide NOTHING: qtmir ignores FaceUp/FaceDown by design, so a flat"
always "       phone never moves the screen -- docs 92 sections 1/5. Nothing is changed by the probe)"
always "   2. GPS                      ->  scp scripts/device/zl1-gps-probe.sh root@$IP:/tmp/ && \\"
always "                                   ssh root@$IP 'sh /tmp/zl1-gps-probe.sh'"
always "      (read-only: which switch is off, whether the QMI client ever opened, doc 82)"
always "   3. fingerprint              ->  scp scripts/device/zl1-fingerprint-probe.sh root@$IP:/tmp/ && \\"
always "                                   ssh root@$IP 'sh /tmp/zl1-fingerprint-probe.sh'"
always "      (read-only: does the store directory exist through the HAL's own namespace, doc 83)"
always "   4. heat                     ->  scp scripts/device/zl1-thermal.sh root@$IP:/tmp/ && \\"
always "                                   ssh root@$IP 'sh /tmp/zl1-thermal.sh --seconds 60 --top 15'"
always "      (doc 81; the sensor stack came back in doc 78 and its thermal cost has not been re-measured)"

if [ "${failed:-0}" != 0 ]; then exit 1; fi
exit 0
