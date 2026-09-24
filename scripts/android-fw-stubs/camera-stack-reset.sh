#!/usr/bin/env bash
# Put the camera stack back into the one state a measurement can start from.
#
# Every step here is a thing that has silently poisoned a run before:
#
#   1. A test_camera left over from an earlier run still holds a binder connection to cameraserver,
#      and cameraserver will refuse the next one with "too many other clients connecting".
#   2. The camera provider is restarted first, so the cameraserver started after it finds the HAL
#      already registered. A provider that survives the restart comes back half torn down, and the
#      HAL says so: 'mm_channel_fsm_state: invalid state (1) for evt (6)' and
#      'lock_acq: 363: failed to acquire lock'. The property's service name is the full one from
#      the .rc file -- "vendor.camera-provider-2-4", prefix included:
#          service vendor.camera-provider-2-4 /vendor/bin/hw/android.hardware.camera.provider@2.4-service
#      `ctl.restart camera-provider-2-4` (no prefix) is accepted by setprop and silently does
#      nothing, which is worse than failing.
#
#      Note also that the provider's pid must never be signalled from *inside* the container: /proc
#      there is the host's (the container has no procfs of its own), so pgrep prints host pids while
#      kill resolves them in the container's namespace -- the two do not agree, and the wrong
#      process gets the signal. Use this property, or kill the host pid from the host.
#   3. cameraserver has to be restarted to clear its client and event lists -- but a restarted
#      cameraserver comes back with an *empty* mAllowedUsers and refuses every client until
#      system_server tells it again (see run-on-device.sh).
#   4. That notification has to wait for cameraserver to register "media.camera" with
#      servicemanager. Sent too early it goes nowhere: the stub logs "no such service", the event is
#      lost, and every later connect() is rejected with
#          Callers from device user 0 are not currently allowed to connect to camera "1"
#      -- which reads like a permissions bug and is only ever a race in this sequence.
#   5. And a client must not connect before cameraserver has *enumerated the provider*, which is
#      later than the name resolving: the QCamera HAL takes about six seconds per camera to answer
#      getCameraInfo, and until that is done getNumberOfCameras() is 0. A run started in that window
#      fails with no diagnostic at all -- see the long note above the wait further down.
#   6. The stub on the device has to be one that registers all five names, "scheduling_policy"
#      included. Step 5 restarts it through run-on-device.sh, which copies the freshly built
#      out/service-stub over and starts it with that script's SERVICES list -- so this is also the
#      deploy step. It matters because the fifth name is asked for later, not at connect: an older
#      binary leaves the *preview* hanging instead, on
#          Camera3Device::configureStreamsLocked -> android::requestPriority
#          -> checkService("scheduling_policy") -> sleep(1), forever
#      which is the thread serving the client's startPreview. docs/ubuntu-touch/67 has the evidence.
#
# Nothing here writes to a partition or to the container's filesystem: cameraserver and the provider
# are runtime services under Android's own init, and this only restarts them. What it does write is
# /userdata/zl1-fw-stubs/service-stub, which is where the stub already lives.
#
# Usage:
#   camera-stack-reset.sh            reset and say what happened
#   camera-stack-reset.sh --quiet    reset, say only what went wrong

set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
DEV_HOST="${ZL1_HOST:-10.15.19.82}"
DIR=/userdata/zl1-fw-stubs
LOG=$DIR/service-stub.log
quiet=0
[ "${1:-}" = "--quiet" ] && quiet=1
# `say` is the only thing that writes to stdout. The remote commands' own output goes through it too (the
# echoes below are the operator's only feedback), which is what makes `--quiet` mean what its usage line
# says -- and an empty remote output then prints nothing, instead of a blank line.
say() { [ "$quiet" = 1 ] && return 0; [ -n "$1" ] || return 0; echo "$@"; }

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10)
on_device() { timeout 120 ssh "${SSH_OPTS[@]}" "root@$DEV_HOST" "$@"; }

model="$(on_device "tr -d '\\0' < /proc/device-tree/model 2>/dev/null" || true)"
case "$model" in
*"MSM 8996pro + PMI8996 LE_ZL1"*) ;;
*) echo "error: this is not the zl1: device-tree model is \"$model\"" >&2; exit 1 ;;
esac

say "== killing a stale test_camera"
say "$(on_device '
  p=$(pgrep -x test_camera | head -1)
  [ -n "$p" ] && { kill -9 "$p"; echo "   killed test_camera host pid $p"; } || echo "   no stale test_camera"
')"

# The provider goes first, so that the cameraserver started below finds it already registered.
# Restarting it second does work -- cameraserver picks a fresh provider up through
# CameraProviderManager's onDeviceStatusChanged -- but only after the enumeration below, and the
# whole point of that wait is to have nothing left to happen afterwards.
say "== restarting the camera provider (init brings mm-qcamera-daemon back with it)"
say "$(on_device '
  A=$(lxc-info -n android -pH 2>/dev/null | head -1)
  nsenter -t $A -p -- /system/bin/setprop ctl.restart vendor.camera-provider-2-4
  sleep 3
  nsenter -t $A -p -- pgrep -a -f "camera" | grep -v pgrep | sed "s/^/   up: /"
')"
# The provider is not ready when its process appears: it has to start mm-qcamera-daemon and then
# bring up two cameras, which the HAL does about six seconds apiece (the getCamInfo lines that
# straddle it). It says so itself, once, when its hwbinder interface is up -- that line is the gate
# for everything after it.
# The two waits below ask logcat the same question, thirty times each, and the answer is a whole log
# buffer -- megabytes of it. So the dump is captured FIRST and matched afterwards, and that is not a
# style choice: `on_device '<a whole logcat dump>' | grep -q '<the line we want>'` reports the death of
# the WRITER, not the reader's answer. `grep -q` leaves at the first match (that is what -q is for),
# which closes the pipe; the dump has not finished writing, so it dies of SIGPIPE; and `set -o pipefail`
# at the top of this file turns that into "this check failed". The reading is then "the provider has not
# registered after 90s" on a device whose own log has that line on its FIRST line -- which sends somebody
# looking for a broken HAL. It is not the rare shape of a race, either: with a dump bigger than a pipe
# (64 KB) it is every single run. docs/ubuntu-touch/135.
LOGCAT_DUMP='nsenter -t $(lxc-info -n android -pH | head -1) -p -- /system/bin/logcat -b main -d -v brief 2>/dev/null'
PROVIDER_REGISTERED='Registration complete for android.hardware.camera.provider@2.4::ICameraProvider'
CAMERASERVER_READY='Camera provider legacy/0 ready with 2 camera devices'

say "== waiting for the provider to register its HIDL interface"
pready=0
dump=""
for i in $(seq 1 30); do
  dump="$(on_device "$LOGCAT_DUMP")"
  if grep -q "$PROVIDER_REGISTERED" <<< "$dump"; then
    pready=1
    break
  fi
  sleep 3
done
[ "$pready" = 1 ] && say "   provider registered" || say "   provider has not registered after 90s"

say "== restarting cameraserver"
say "$(on_device '
  A=$(lxc-info -n android -pH 2>/dev/null | head -1)
  nsenter -t $A -p -- /system/bin/setprop ctl.restart cameraserver
  echo "   ctl.restart cameraserver"
')"

# The wait that this script exists for. A restarted cameraserver is *not* ready when it registers
# "media.camera": it enumerates the provider afterwards, and the QCamera HAL takes about six seconds
# per camera to answer getCameraInfo (see the 'getCamInfo: camera 0 resource cost is 100' lines
# either side of it). Until that finishes, CameraService has zero cameras -- so a client that
# connects in that window gets NULL from getNumberOfCameras(), which libhybris' compat layer turns
# into "Problem connecting to camera" with *no* error anywhere: no exception, no framework log, no
# binder transaction, because nothing was ever asked. That is what a run started too early looks
# like, and it is indistinguishable from a permissions failure unless you know to look here.
say "== waiting for cameraserver to enumerate both cameras"
ready=0
for i in $(seq 1 30); do
  dump="$(on_device "$LOGCAT_DUMP")"
  if grep -q "$CAMERASERVER_READY" <<< "$dump"; then
    ready=1
    break
  fi
  sleep 3
done
if [ "$ready" = 1 ]; then
  say "   both cameras enumerated"
else
  say "   cameraserver has not enumerated both cameras after 90s -- a run now would fail to connect"
  # The dump that just failed is the one to read: a second `logcat -d` three seconds later would be a
  # different question, and a second chance for the writer to be killed mid-answer.
  grep -aiE 'CameraProvider|camera devices|QCamera' <<< "$dump" | tail -6 | sed 's/^/   /'
fi

say "== telling the stub the user switched (this also restarts it)"
say "$("$here/run-on-device.sh" --notify-user-switch 2>&1 | grep -aE 'resolves|refused|no such service' | tail -2 | sed 's/^/   /')"
# Verify it, rather than trusting the message: the event is oneway, and a stub that could not
# resolve "media.camera" (or that was answered with a local object, which is not something to
# transact with) exits 1 without anything on the wire. Its own log is the only place that tells the
# two apart -- "no such service -- cameraserver is not up" and "it answered with a local object"
# against "sent (oneway)" -- and it has to be the *last* notify block that is read, not any
# "sent (oneway)" anywhere in the tail, because this runs after every reset and the file accumulates.
tail="$(on_device "tail -14 $LOG 2>/dev/null")"
last_notify="$(printf '%s\n' "$tail" |
  awk '/notifySystemEvent\(EVENT_USER_SWITCHED/{c=NR} {l[NR]=$0} END{for(i=c;i<=NR;i++) print l[i]}')"
if grep -q 'sent (oneway)' <<< "$last_notify"; then
  say "   the user switch was applied"
elif grep -q 'no such service' <<< "$last_notify"; then
  say "   WARNING: cameraserver had not registered media.camera yet -- the event went nowhere,"
  say "            which means every connect() will be refused with 'not currently allowed'"
else
  say "   WARNING: the stub's log does not say the event was sent -- read $LOG"
fi

say "== clearing the main log buffer"
say "$(on_device 'nsenter -t $(lxc-info -n android -pH | head -1) -p -- /system/bin/logcat -b main -c && echo "   cleared"')"
