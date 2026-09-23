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
  echo "thermal=$(for z in /sys/class/thermal/thermal_zone*; do [ -r "$z/temp" ] || continue; printf "%s:%s " "$(cat "$z/type" 2>/dev/null)" "$(cat "$z/temp" 2>/dev/null)"; done)"
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

# The temperature, and the trap that makes this line wrong if it is written the obvious way.
#
# "read thermal_zone1/temp and divide by 1000" is what this line used to do, and on this device it
# prints "0.6 C" while the SoC is at 55.8 C -- because **the zones do not share a unit** and only the
# zone's `type` says which one it is: tsens_tz_sensor* are deci-degC, pm8994_tz/battery are milli-degC,
# and msm_therm/quiet_therm/pa_therm*/emmc_therm are plain degC (measured 2026-09-22; the raw snapshot
# is docs/ubuntu-touch/evidence/thermal-2026-09-22.log section 7, the units section 9). Picking
# thermal_zone1 was itself arbitrary -- its number is the 1-based index of a tsens sensor.
#
# So: ask the device for every zone as type:temp (one ssh field, no arithmetic on the device) and scale
# here, where a wrong answer is visible. The table is the same one scripts/device/zl1-thermal.sh uses,
# and scripts/host/zl1-thermal-selftest.sh drives both with the same fake zones and asserts they agree,
# so the two copies cannot drift apart silently.
#
# Report the hottest zone by *scaled* value, with its raw value and unit on the line: on this device the
# hottest zone has the numerically SMALLEST raw reading (580 against the battery's 42500), so a reader
# who sees only "58.0 C" cannot tell a correct answer from a 100x one -- "raw 580 = deci-degC" can be
# checked in the head, and that is the whole point of printing it.
t="$(field thermal)"
say "   $(printf '%s\n' "$t" | awk '
  function zl1_scale(type,   f, u) {
    f = 1; u = "assumed-milli-degC"; flag = 0
    if      (type ~ /^tsens_tz_sensor[0-9]+$/)                             { f = 100;  u = "deci-degC" }
    else if (type == "pm8994_tz" || type == "battery")                     { f = 1;    u = "milli-degC" }
    else if (type ~ /^(msm_therm|quiet_therm|pa_therm[0-9]*|emmc_therm)$/) { f = 1000; u = "degC" }
    else flag = 1
    zl1_unit = u
    return f
  }
  { for (i = 1; i <= NF; i++) {
      split($i, p, ":"); if (p[2] == "") continue
      n++
      m = p[2] * zl1_scale(p[1])
      if (m < -40000 || m > 160000) { bad++; continue }
      if (++picked == 1 || m > hot) { hot = m; ht = p[1]; hr = p[2]; hu = zl1_unit; hf = flag }
    } }
  END {
    if (n == 0)  { print "thermal: no readable zone"; exit }
    if (!picked) { printf "thermal: %d zones, every one implausible -- the unit table is wrong\n", n; exit }
    printf "thermal: hottest of %d zones: %s %.1f C (raw %s = %s)", n, ht, hot/1000, hr, hu
    if (hf)      printf "; that zone is not in the unit table"
    if (skip)    printf ", %d excluded as implausible", skip
    print ""
  }')"
say "   cpu0 governor: $(field gov)"

# --- what to run next ---------------------------------------------------------------------------

always ""
always "== what is owed, in the order it has to be done (0-series first: each one is only"
always "== answerable by the boot you are on, or by the next one)"
always ""
always "   ONE COMMAND RUNS ALL OF IT, and that is the intended way (docs 107):"
always "       scripts/host/zl1-post-recovery-capture.sh"
always "   It walks the 0-series and the probes in the order below, archives every step's own output"
always "   into tmp-post-recovery-<timestamp>/ with an INDEX.txt (step / rc / file) and a SHA256SUMS,"
always "   captures the keeper's pid and CPU ticks BEFORE anything can retire it, and REFUSES with"
always "   exit 2 -- running nothing at all -- when the device is still in EDL. Everything in its"
always "   default set is read-only; the one step that writes (install-no-edl-on-panic.sh"
always "   --capture-only) needs --with-capture. --skip-probes drops the two probes when only the"
always "   evidence that dies with this boot matters. Every DEVICE-side step is bounded on the device"
always "   by timeout(1) -- itself a fix (docs 108): step 02's log scan was quadratic and ran 12 minutes"
always "   at 94% of a core on the first real run, which ended in EDL. --step-limit changes that bound."
always "   An interrupt now archives what has run and exits 3, so a stopped run still leaves its index."
always "   Behaviour pre-verified offline:"
always "   scripts/host/zl1-post-recovery-capture-selftest.sh, 122 checks, and five mutations each"
always "   make it fail (order swapped, refusal removed, the writing step in the default set, no"
always "   archive, a failing step aborting the chain). The steps below are what it runs, in order --"
always "   read them here for what each one decides, not as a manual to retype."
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
always "       so the keeper is no longer the only thing that can do it. exit 1 = do not retire it yet."
always "       Its verdict logic is pre-verifiable without the device: scripts/host/"
always "       zl1-boot-address-selftest.sh, 24 checks, runs the real script against synthetic netwatch"
always "       logs -- including two with two boots in the log, where reading the wrong section inverts"
always "       it. Read that before treating an 'inconclusive' as a failed attempt: with the keeper alive"
always "       the netwatch can only produce the ADDRS line by winning a sub-second race, so most boots"
always "       read that way, and re-running one is a re-roll rather than a retry. docs 112)"
always "   0b1. IF 0b read 'inconclusive', or you want the answer without another boot -- this measures"
always "       the same claim directly, in about half a minute, and undoes itself:"
always "                                                scripts/device/zl1-address-owner-proof.sh --yes"
always "       (it SIGSTOPs the keeper, takes 192.168.2.15/24 off rndis0, and requires the netwatch to"
always "        notice and put it back; then resumes the keeper and restores the address itself if the"
always "        netwatch did not. exit 0 = proof-obtained. The keeper cannot stay stopped -- a detached"
always "        'sleep; kill -CONT' is armed BEFORE the SIGSTOP, so a killed script or a dropped SSH"
always "        session still gets it back. Nothing is installed, no unit is touched, nothing persists."
always "        That path is write-capable and covered offline first: scripts/host/"
always "        zl1-address-proof-selftest.sh, 49 checks, and each of its nine mutations makes it fail)"
always "   0b2. IF 0b said the INSTALLED build has no ensure_addrs(), this is the step before it --"
always "       and it no longer needs TWRP (docs 111):"
always "                                                scripts/install-netwatch-service.sh --yes --ssh"
always "       (it writes /etc/systemd/system through the LIVE bind mount, which is the same directory"
always "       the adb/TWRP route reaches as /data/system-data/etc/systemd/system -- over ssh that"
always "       other name is the ANDROID CONTAINER s /data, so a wrong path here succeeds silently."
always "       It replaces the script of a RUNNING service atomically (.new + read-back + rename),"
always "       restarts nothing, and REQUIRES the verified misc backup rather than reading a partition."
always "       Then reboot -- the RUNNING watchdog keeps executing the old build until then -- and run"
always "       0b1, not 0b: the proof is deterministic where the boot verdict is a race (docs 112))"
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
always "   0d. and then the retirement itself, but ONLY once 0b printed netwatch-configured (docs 94)."
always "       The keeper is the port's second heat source -- a full core -- and it is retired by"
always "       KILLING it, not by editing its unit: the v63 boot hook recreates both the keeper script"
always "       and its unit on every boot, and the process that survives is the one the ramdisk started"
always "       before systemd, not systemd's own instance (which exits 0 on the held lock, so"
always "       Restart=on-failure never fires: doc 72's \"exited after 67 ms\")"
always "                                                scripts/install-retire-debug-keeper.sh --status"
always "      (read-only. --install changes NOTHING on the current boot and retires it from the next"
always "       reboot on; --install --now also kills it on this boot. Both are the user's call. The"
always "       applier refuses to kill unless rndis0/usb0 already carries one of the two addresses, and"
always "       it distinguishes \"SIGKILL did not take\" from \"something RESTARTED the keeper\" -- the"
always "       second would mean only a boot-image change retires it. Measure the effect with item 4)"
always "   1. GUI / camera on screen   ->  bash scripts/host/zl1-camera-app-test.sh --keep-display"
always "      (turns the display on, measures the compositor with and without the app, grabs a shot,"
always "       restores the display; doc 84. Look at the phone yourself when it says --keep-display)"
always "      (The number it prints is ticks/s -- jiffies per second from /proc/<pid>/stat, HZ=100, so"
always "       1 tick/s is 1% of one core -- and the band is ~1.2/s idle vs 20-50/s with a client."
always "       It used to print 100x that, which made the \"B >= 8\" gate 0.08/s. Read the verdict"
always "       lines, not just the two numbers: the app's OWN state decides what they mean (never"
always "       started / died before window B / NO VERDICT if a window could not be read), because a"
always "       launcher failure and \"the app is not being composited\" look identical otherwise. Its"
always "       logic is host-verifiable with no device: scripts/host/zl1-camera-app-test-selftest.sh"
always "       (79 checks, transport stubs are the device; 23 of them go red against the old script)."
always "       doc 104)"
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
always "       phone never moves the screen -- docs 92 sections 1/5. Nothing is changed by the probe."
always "       Its parsers are pre-verifiable without the device and without a hand: scripts/host/"
always "       zl1-orientation-axes-selftest.sh stubs gdbus and drives eight canned postures through"
always "       the real script -- worth running first, since the run below costs a person holding"
always "       still. It passes clean, so a surprising verdict is about the phone, not the parsing)"
always "   2. GPS                      ->  scp scripts/device/zl1-gps-probe.sh root@$IP:/tmp/ && \\"
always "                                   ssh root@$IP 'sh /tmp/zl1-gps-probe.sh'"
always "      (read-only: which switch is off, whether the QMI client ever opened, doc 82)"
always "      Read the two blocks as separated by OWNER, not as one table (docs 102): logcat is the"
always "      container's vendor HAL, the journal is this daemon and the library it loads. Two of the eight"
always "      patterns the old version counted were structurally 0 -- they cannot appear in logcat"
always "      -- and a 0 read as \"the provider was never instantiated\", pointing the diagnosis one layer"
always "      too low. Two more were in no binary in any image. If a count is 0 here, check it is a"
always "      pattern whose owner could write it at all before reading anything into it"
always "      Offline and device-free: scripts/host/zl1-gps-selftest.sh, 129 checks (its section 9 is"
always "      the image cross-check that keeps a nonexistent pattern from coming back). Writing it found"
always "      the two patterns that could never be evidence, the wifi/cell reading that sed never printed"
always "      (a `/` in the replacement ended the s command, so that switch was the one number this"
always "      probe never showed), and a gate-1 branch that could not be reached (`tr | grep | sed ||`"
always "      reports sed's status). Against the probe at e4cecba: 25 failures. The image cross-check"
always "      SKIPs loudly if the UT/Android/vendor mounts are not present -- a skip is a statement"
always "      about this host, but it is printed and counted, because that is the defect class this"
always "      project keeps finding)"
always "      IT NOW ENDS WITH A VERDICT (docs 109). It used to print nine sections and no bottom line, and"
always "      the first real capture was read as \"the GPS probe produced no verdict\" -- while those"
always "      sections held the deepest evidence the chain has ever had: on 2026-09-23 the log shows"
always "      locClientOpen failed = 0, Failed to get features supported = 2 and gnssSetCapabilitesCb = 2,"
always "      i.e. the container's vendor GPS HAL ran and its QMI client OPENED, and the UT adapter was"
always "      reached (u_hardware_gps_set_position_mode). So the door is not what is blocking. The verdict"
always "      names the rung the evidence stops at and exits 0 only for that state."
always "      AND IT NOW READS THE lshal LISTING (docs 110). The old text said the columns are not parsed"
always "      because nothing in this tree records what they mean -- true of the output, false of the"
always "      source: the image's build tree carries lshal (frameworks/native/cmds/lshal) and its literals"
always "      are verbatim in the built liblshal.so. The rule that makes the reading possible: `hash`, and"
always "      therefore the R column, is assigned in exactly ONE place, fetchBinderizedEntry(), i.e."
always "      lshal's FIRST table only -- so a row in table 1 means hwservicemanager lists it (registered)"
always "      and R=Y means it answered interfaceChain()/getHashChain() (live). By that reading the"
always "      2026-09-23 recording says the container's android.hardware.gnss@1.0::IGnss/default IS"
always "      registered, which was the one layer this probe used to be able to print and not judge."
always "   2b. and then the request (docs 93, CORRECTED by docs 109): the hardware entry points"
always "       u_hardware_gps_new/u_hardware_gps_start are reached from a client's StartPositionUpdates,"
always "       and a default-closed trust-store gate stands in front of them. The old text said \"the"
always "       request that has never been made at all\", and the recorded log no longer supports that:"
always "       u_hardware_gps_set_position_mode IS in it. What the counts cannot say is whether that came"
always "       from a client or from the daemon's own provider init -- read the probe's verdict first"
always "                                                scp scripts/device/zl1-location-request.sh root@$IP:/tmp/ && \\"
always "                                                ssh root@$IP 'sh /tmp/zl1-location-request.sh --status'"
always "      (read-only, per link: the effective ExecStart and its drop-ins, whether /usr/bin/getprop"
always "       is the v63 stub -- if it is, BOTH custom.location.* levers doc 82 recommends are dead by"
always "       construction -- whether the service and the trust-store agent are on the bus, and"
always "       whether the bridge library is mapped in the daemon. Then --request runs a"
always "       PositionSource{name:\"lomiri\"} client under qmlscene to actually ask for a position."
always "       --enable-testing opens gate 1 and is a REAL PERMISSION BYPASS (anything on the device"
always "       could then obtain its location): it is the user's call, and --disable-testing undoes it."
always "       It is a true short circuit in the installed library (docs 93 section 3.4): the other two"
always "       gates are never reached on that path, so no AppArmor profile has to be arranged)"
always "      AND A NAMED CLIENT EXISTS FOR IT (docs 105): the preinstalled Weather app"
always "      (weather.ubports_weather_6.2.0) is a QtPositioning client -- its QML has"
always "      `PositionSource { active: settings.detectCurrentLocation }` -- and its own AppArmor"
always "      profile already carries the \"location\" policy group. So the first request does not need"
always "      the bypass: launch it with the same launcher the camera uses, turn on \"detect current"
always "      location\", and watch the gate. Expect either a trust-store PROMPT on screen (one of two"
always "      mutually exclusive agents runs, MirAgent or WaylandAgent -- docs 105 section 4) or a"
always "      silent denial -- which is why `systemctl --user status` on the trust-stored unit has to be"
always "      read together with the daemon's journal. --enable-testing stays the fallback, not the first"
always "      move)"
always "      Both this and item 3 have exactly one mode that writes to the device, and both are covered"
always "      offline: scripts/host/zl1-loc-fp-selftest.sh, 180 checks. It has found three real defects in"
always "      those two probes (--quiet silencing the permission-bypass warning, --create-store-dir"
always "      creating BOTH candidates, and section 2 deciding the store path from the CONTAINER's getprop"
always "      while biometryd execs the UT-side one), plus three in ITSELF, all of the same shape:"
always "      **an assertion that passed while testing nothing.** Its nsenter stub never delivered logcat,"
always "      so the fingerprint probe's log section read an EMPTY dump in every scenario and every count"
always "      was 0 -- while the assertions passed, because they matched the pattern LABELS, which the"
always "      table prints whatever the count is. Its logcat fixture contained a string that exists in no"
always "      image (docs 103: the probe not only read the CALLER's setActiveGroup line out of the wrong"
always "      log, it read it from a log whose stub answered nothing). And the read/logcat query has to be"
always "      asserted through nsenter, since that is how the probe reaches it."
always "      (The three product defects it found:"
always "      --quiet used to silence the permission-bypass warning itself, --create-store-dir used to"
always "      create BOTH candidate store paths while its own section 2 had decided which one biometryd"
always "      passes, and section 2 itself decided that from the CONTAINER's getprop while biometryd"
always "      execs the UT-side /usr/bin/getprop (docs 101) -- so on a device with first_api_level >27"
always "      it would create a directory nothing reads. It now reads biometryd's own binary and prints"
always "      AGREE/DISAGREE against the container's value. Read the UNDO line against what was created"
always "      -- that correspondence is the whole check.)"
always "   3. fingerprint              ->  scp scripts/device/zl1-fingerprint-probe.sh root@$IP:/tmp/ && \\"
always "                                   ssh root@$IP 'sh /tmp/zl1-fingerprint-probe.sh'"
always "      (read-only: does the store directory exist through the HAL's own namespace, doc 83)"
always "      Its one write (--create-store-dir) now touches ONLY the path it determined biometryd passes,"
always "      and the UNDO it prints names that same path (doc 97; before, it created both candidates)"
always "      Section 2 now reads biometryd's OWN getprop and says AGREE/DISAGREE against the container's"
always "      value, so the two readings that decide the path can be compared (docs 101)"
always "      Section 4's counts are split by OWNER (docs 103): the caller's 'setActiveGroup failed' is"
always "      biometryd's line and is in its JOURNAL -- it can never appear in the container's logcat, so a"
always "      0 there used to read as 'the HAL never got the call', the opposite of what the probe's header"
always "      says. Read the two blocks as two logs. A 0 now only means something when the string could"
always "      appear in that log at all (five of the old patterns were in no binary in any image, two of"
always "      them misquoted -- the binary says Can't, not Can not)"
always "      AND A FIX NOW EXISTS, and it is the operator's call (docs 106):"
always "      scripts/install-fingerprint-store-dir.sh --status (read-only) then --install. It creates"
always "      the one directory system_server would have created (/data/system/users/0/fpdata, through"
always "      the host's view of the same ext4 at /var/lib/android-data), durably, via a oneshot unit"
always "      ordered before biometryd -- and the applier re-reads biometryd's own path rule every boot,"
always "      takes the owner from the HAL's real /proc uid, refuses to create anything if that"
always "      partition is not mounted, and exits 1 if the directory does not READ BACK as the owner"
always "      access(W_OK) needs. It writes two files under /etc/systemd/system and creates one"
always "      directory; it restarts nothing, flashes nothing, and does not create the other candidate."
always "      Run the probe in this item BEFORE and AFTER it: before, the directory is missing; after,"
always "      the question is whether biometryd's 'setActiveGroup failed' count falls to 0. Its own"
always "      behaviour is pre-verified without the device: scripts/host/zl1-fp-store-dir-selftest.sh,"
always "      131 checks -- and four mutations of the installer (no read-back, no refusal gate, a host"
always "      path one 'data' too long, a hardcoded path) each make it fail, which is the only thing"
always "      that makes the 130 mean anything)"
always "   4. heat                     ->  scp scripts/device/zl1-thermal.sh root@$IP:/tmp/ && \\"
always "                                   ssh root@$IP 'sh /tmp/zl1-thermal.sh --seconds 60 --top 15'"
always "      (doc 81; the sensor stack came back in doc 78 and its thermal cost has not been re-measured)"
always "      Read the hottest line, not just the number: the zones on this device use THREE different units"
always "      (tsens deci-degC, pm8994/battery milli-degC, msm_therm/quiet_therm plain degC), so it prints"
always "      the raw value and the unit too -- 'raw 580 = deci-degC' is the part you can check in your head,"
always "      and it is the part that was missing while this script reported the SoC at 0.6 C (doc 96)."
always "      Its arithmetic is pre-verifiable without the device: scripts/host/zl1-thermal-selftest.sh,"
always "      45 checks, all three units at once in a fake root, and the doc 72 A/B as an assertion)"

if [ "${failed:-0}" != 0 ]; then exit 1; fi
exit 0
