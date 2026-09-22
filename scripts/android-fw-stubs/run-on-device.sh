#!/usr/bin/env bash
# Put service-stub on the zl1 and run it, so the camera can open.
#
# What this is for, in one paragraph: the camera in this Halium container cannot connect, and the
# reason is not the camera. cameraserver's connect() asks the framework four questions a phone
# answers with system_server and a Halium container cannot answer at all --
#
#   validateClientPermissionsLocked
#     -> checkPermission("android.permission.CAMERA")   -> checkService("permission")
#     -> mUidPolicy->isUidActive()
#     -> mAllowedUsers.find(clientUserId)               <- filled only by notifySystemEvent()
#        -> (inside that event) CameraUidPolicy::registerSelf -> checkService("activity")
#   connectHelper -> handleEvictionsLocked -> ProcessInfoService -> checkService("processinfo")
#
# -- and all four of `permission`, `appops`, `activity` and `processinfo` are registered by
# system_server, and mAllowedUsers is only ever written when system_server tells cameraserver which
# device users may connect. Without the first, checkPermission() spins in an untimed retry loop
# while holding CameraService::mServiceLock, so every later connect queues forever behind it;
# without the second, connect() is rejected with 'Access ... has been restricted'; without the third
# the user switch is never applied and connect() is rejected with "cannot connect from device user
# 0, currently allowed device users: "; without the fourth it fails with -110 (ETIMEDOUT).
# service-stub.c is all four, and it also sends the oneway notifySystemEvent(EVENT_USER_SWITCHED,
# {0}) that system_server would have sent. Its header has the device evidence for each, and the
# exact transactions.
#
# Why it has to run inside the container's PID namespace: servicemanager's SELinux hook calls
# selinux_check_access() with getpidcon(pid). From the host that pid is not resolvable and
# registration is refused with
#   ServiceManager: SELinux: getpidcon(pid=0) failed to retrieve pid context.
#   list_service() uid=0 - PERMISSION DENIED
# -- which is exactly what the device log says when a host process tries. `nsenter -p` (never
# -F) and the process is inside, where cameraserver can reach it.
#
# Usage:
#   run-on-device.sh                   deploy, (re)start, verify, show the log
#   run-on-device.sh --status          is it running, and what has it answered?
#   run-on-device.sh --stop            stop it (servicemanager drops the names with the node)
#   run-on-device.sh --foreground      run it in the foreground, for reading live transactions
#   run-on-device.sh --notify-user-switch
#                                      re-send the user-switch event, and then start the stub, so
#                                      this is the whole procedure after a cameraserver restart
#                                      (a restarted cameraserver comes back with an empty
#                                      mAllowedUsers and refuses every client until it is told again)
#
# Nothing here writes to a partition or to the container's own filesystem: the binary lives in
# /userdata/zl1-fw-stubs/ and is a runtime install only.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
BIN="$here/out/service-stub"
DEV_HOST="${ZL1_HOST:-10.15.19.82}"
DIR=/userdata/zl1-fw-stubs
LOG=$DIR/service-stub.log
RUNLOG=$DIR/service-stub.run.log
PIDFILE=$DIR/service-stub.pid
# Every name the camera stack asks for, in the order it asks. "activity" is what
# CameraUidPolicy::registerSelf() waits for inside notifySystemEvent, before the user switch that
# makes a client connectable is applied; "processinfo" is what CameraService::handleEvictionsLocked
# asks for the state and OOM score of every client holding a camera, and answers ETIMEDOUT after
# BINDER_ATTEMPT_LIMIT one-second retries without it. See service-stub.c for both.
SERVICES=(permission appops activity processinfo)
# Every call to the device is bounded. A device that is rebooting, or one hung service, must not be
# able to hang this script: `service list` (an app_process script) blocks for as long as its own
# binder calls do, which is how an earlier version of this file waited forever on the camera fix it
# had already installed correctly.
TMO="${ZL1_TIMEOUT:-45}"

# The target is identified by what it says it is, not by an address: a second, unrelated phone
# (serial 4a2fe00b) shares this USB bus and 10.15.19.82 is only a DHCP address on the RNDIS link.
expect_model="MSM 8996pro + PMI8996 LE_ZL1"

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10)
ssh_d() { timeout "$TMO" ssh "${SSH_OPTS[@]}" "root@$DEV_HOST" "$@"; }

die() { echo "error: $*" >&2; exit 1; }

# $1 = a shell snippet. Runs on the device with $A (the container's init pid, i.e. the host pid of
# the process whose PID namespace is the container's) already resolved and checked. Everything that
# goes near the container goes through this, so no snippet has to guess the pid.
on_device() {
  ssh_d 'A=$(lxc-info -n android -pH 2>/dev/null | head -1)
          case "$A" in ""|*[!0-9]*) echo "error: no android container (lxc-info gave \"$A\")" >&2; exit 1 ;; esac
          if [ ! -e "/proc/$A/ns/pid" ]; then
            echo "error: container init $A has no /proc/$A/ns/pid" >&2; exit 1
          fi
          echo "== container init host pid $A, namespace $(readlink /proc/$A/ns/pid)"
          '"$1"
}

running_pid() {
  ssh_d 'pgrep -f "^'"$DIR"'/service-stub" 2>/dev/null | head -1' 2>/dev/null || true
}

mode="${1:---run}"
case "$mode" in
--status)
  p="$(running_pid)"
  if [ -n "$p" ]; then echo "== running, host pid $p"; else echo "== not running"; fi
  # The stub's own log is the verification that matters: it is the process that called
  # checkService and saw whether the name came back. Nothing else on the device can be asked
  # cheaply -- `service list` needs an app_process and blocks on binder.
  on_device "tail -25 $LOG 2>&1 || echo '(no log yet)'"
  exit 0
  ;;
--stop)
  on_device 'p=$(pgrep -f "^'"$DIR"'/service-stub" 2>/dev/null); if [ -n "$p" ]; then
                echo "  stopping host pid $p"; kill $p 2>/dev/null || true; sleep 1
              fi
              p=$(pgrep -f "^'"$DIR"'/service-stub" 2>/dev/null); [ -n "$p" ] && kill -9 $p 2>/dev/null
              rm -f '"$PIDFILE"'
              echo "== stopped (servicemanager drops the names when the node dies)"'
  exit 0
  ;;
--run|--foreground|--notify-user-switch) ;;
*) die "usage: $0 [--status|--stop|--foreground|--notify-user-switch]" ;;
esac

[ -x "$BIN" ] || die "$BIN not built -- run $here/build.sh first"
# The sha the build printed. If this differs from the one under review, the byte-exact reasoning in
# service-stub.c no longer applies to what is about to run.
echo "== local binary"
sha256sum "$BIN"

echo "== identity"
# device-tree strings come back NUL-terminated; compare the text only
model="$(ssh_d "tr -d '\\0' < /proc/device-tree/model 2>/dev/null" || true)"
case "$model" in
*"$expect_model"*) ;;
*) die "this is not the zl1: device-tree model is \"$model\"" ;;
esac

# A previous instance would (a) hold the names with a dead node behind them, so the second
# addService would be refused with ALREADY_EXISTS, and (b) make the binary unwritable -- a running
# executable cannot be replaced, scp says "Text file busy". So stop before copying, always.
"$0" --stop >/dev/null 2>&1 || true

echo "== copying to $DIR"
ssh_d "mkdir -p $DIR"
# scp is a separate binary, so it needs the options spelled out rather than the array.
timeout "$TMO" scp "${SSH_OPTS[@]}" "$BIN" "root@$DEV_HOST:$DIR/service-stub"
ssh_d "chmod 755 $DIR/service-stub; ls -l $DIR/service-stub"

if [ "$mode" = "--notify-user-switch" ]; then
  echo "== re-sending the user-switch event"
  on_device "nsenter -t \$A -p -- $DIR/service-stub --notify-user-switch; echo \"exit=\$?\"
             tail -4 $LOG"
  # And then carry on to start the stub, because the --stop above took the serving instance down.
  # Leaving it down is not a smaller version of this: cameraserver's checkPermission() has the name
  # "permission" to ask and nobody to answer, and its retry loop is untimed and holds
  # CameraService::mServiceLock, so the next connect() blocks in binder_thread_read forever -- which
  # is exactly what a run did after this mode was first used: the client sat in binder_thread_read
  # with one thread while cameraserver answered nothing and the stub's log grew by nothing. The
  # user-switch event and the four services are two halves of one state and this mode has to leave
  # both in place.
  echo "== restarting the stub itself (see the note above)"
fi

if [ "$mode" = "--foreground" ]; then
  echo "== running in the foreground (ctrl-c here kills it); transactions appear below"
  on_device "nsenter -t \$A -p -- $DIR/service-stub ${SERVICES[*]}"
  exit $?
fi

echo "== starting inside the container PID namespace"
# setsid: the process has to outlive this ssh session, and needs no controlling terminal, so the
# binder read side is never cut short by a SIGHUP. The stub writes its own log
# (service-stub.c: LOGFILE); stderr goes to RUNLOG so a failure *before* that log opens is still
# visible.
on_device "if [ -x /usr/bin/setsid ]; then S=/usr/bin/setsid; else S=setsid; fi
           \$S nsenter -t \$A -p -- $DIR/service-stub ${SERVICES[*]} </dev/null >$RUNLOG 2>&1 &
           echo \$! > $PIDFILE
           sleep 4
           echo \"== host pid \$(cat $PIDFILE), state:\"
           cat /proc/\$(cat $PIDFILE)/stat 2>/dev/null | cut -d' ' -f3 || echo '  not running'"

echo "== the stub's own log"
on_device "cat $LOG 2>&1 || echo '(no log)'"
if ssh_d "grep -q 'does NOT resolve' $LOG 2>/dev/null"; then
  die "a name did not resolve -- servicemanager refused the registration; see $LOG"
fi

tail_note="$(ssh_d "tail -3 $LOG 2>/dev/null")"
cat <<EOF

== where this leaves the camera

The two names are answered and cameraserver has been told which users may connect, so the next
connect() should get all the way through validateClientPermissionsLocked. Run it, under the CFI
preload that is what lets libcamera.so.1 load at all:

  scripts/android-fw-stubs/run-camera-test.sh        (or by hand:)
  ssh root@$DEV_HOST 'nsenter -t \$(lxc-info -n android -pH) -p -- \\
    env HYBRIS_LD_LIBRARY_PATH=/userdata/zl1-hybris/lib:/system/lib64:/odm/lib64:/vendor/lib64 \\
        LD_PRELOAD="/usr/lib/aarch64-linux-gnu/libtls-padding.so /userdata/zl1-hybris/lib/libcfi-shadow-init.so" \\
    /usr/bin/test_camera'

then: $0 --status    (the request for "permission" is the one that was missing)

last log lines:
$tail_note
EOF
