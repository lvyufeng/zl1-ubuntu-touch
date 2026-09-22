#!/usr/bin/env bash
# Run the camera test binary on the zl1, in the container's PID namespace, with the two preloads the
# port needs -- and with service-stub running, which is what the camera needs first.
#
# Three things have to be true at once for /usr/bin/test_camera to reach the camera at all:
#
#   1. It must run *inside the container's PID namespace* (zl1-ns-exec / nsenter -p, never -F).
#      Android binder only completes a transaction between two processes in the same PID namespace;
#      from the host, cameraserver's replies come back empty.
#   2. LD_PRELOAD must have libtls-padding.so (bionic's TLS_SLOT_THREAD_ID is never filled in a
#      glibc host -- docs/ubuntu-touch/41) and libcfi-shadow-init.so (libcamera.so.1 is built with
#      cross-DSO CFI, and hybris' dlopen does not prime the shadow -- scripts/cfi-shadow).
#   3. service-stub must be running (scripts/android-fw-stubs/run-on-device.sh). Without it,
#      cameraserver's connect() blocks forever inside checkPermission()'s untimed retry loop while
#      holding CameraService::mServiceLock, and then refuses the client anyway because no
#      system_server ever told it which device users may connect.
#   4. libis_compat_layer.so must be in /userdata/zl1-hybris/lib (scripts/hybris-shims). test_camera
#      calls android_input_stack_initialize() after it connects -- it wants a touch listener so a
#      tap can take a picture -- and the host's libis.so.1 dlopens that compat layer to do it. It is
#      a DT_NEEDED of test_camera, and hybris' wrapper does not NULL-check the handle it fails to
#      open, so without the layer the program dies of SIGSEGV (exit 139) right there.
#
# Usage:
#   run-camera-test.sh [--timeout SECONDS] [--no-input-stack] [extra test_camera args...]
#
# --no-input-stack is the measurement mode: the camera without the input stack in the same process
# (no-input-stack.so, see scripts/android-fw-stubs/no-input-stack.c). It is how the camera is
# measured while the input layer has a problem of its own, and it is labelled as such in the output
# rather than being the way this is meant to run.
#
# Output goes to /userdata/zl1-camera/<date>/ on the device, filtered: libtls-padding.so prints a
# block of 'c' padding and a tlsfix2 line per thread, which would otherwise be most of the file.

set -euo pipefail

DEV_HOST="${ZL1_HOST:-10.15.19.82}"
DIR=/userdata/zl1-camera
SECS=60
args=()
# The two preloads the port needs are not optional; this one is. --no-input-stack adds
# no-input-stack.so, the LD_PRELOAD instrument that answers the six android_input_stack_* entry
# points itself, so libis.so.1 never dlopens the real input compat layer and whatever is wrong with
# that layer cannot be mistaken for something wrong with the camera. See no-input-stack.c.
PRELOAD="/usr/lib/aarch64-linux-gnu/libtls-padding.so /userdata/zl1-hybris/lib/libcfi-shadow-init.so"
# A crash loses whatever stdio had buffered, and test_camera writes its progress with printf to a
# file -- block buffered, so a run that dies early leaves an empty file and looks like a run that
# never printed anything. --line-buffered puts stdbuf in front of it; the diagnostic value of
# "the last line it printed" is the whole reason to run this.
PREFIX=""
while [ $# -gt 0 ]; do
  case "$1" in
  --timeout) SECS="$2"; shift 2 ;;
  --line-buffered) PREFIX="stdbuf -oL "; shift ;;
  --no-input-stack)
    PRELOAD="$PRELOAD /userdata/zl1-hybris/lib/no-input-stack.so"
    shift
    ;;
  *) args+=("$1"); shift ;;
  esac
done

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10)
# The ssh call has to outlast the timeout test_camera runs under, plus the log reading after it --
# otherwise this script kills the run it just started and reports nothing.
TMO="${ZL1_TIMEOUT:-$((SECS + 90))}"
ssh_d() { timeout "$TMO" ssh "${SSH_OPTS[@]}" "root@$DEV_HOST" "$@"; }

expect_model="MSM 8996pro + PMI8996 LE_ZL1"
model="$(ssh_d "tr -d '\\0' < /proc/device-tree/model 2>/dev/null" || true)"
case "$model" in
*"$expect_model"*) ;;
*) echo "error: this is not the zl1: device-tree model is \"$model\"" >&2; exit 1 ;;
esac

# test_camera has no timeout of its own and is exactly the kind of program that hangs when a binder
# call never returns, so it always runs under one.
cmd="${PREFIX}/usr/bin/test_camera ${args[*]:-}"
printf '== running: %s\n' "$cmd"

ssh_d "A=\$(lxc-info -n android -pH 2>/dev/null | head -1)
        [ -n \"\$A\" ] || { echo 'error: no android container' >&2; exit 1; }
        d=$DIR/\$(date +%Y%m%d-%H%M%S 2>/dev/null || echo run); mkdir -p \$d
        # a hung test_camera from an earlier run would still be holding a binder connection
        p=\$(pgrep -f '^/usr/bin/test_camera' 2>/dev/null); [ -n \"\$p\" ] && { echo \"  killing stale test_camera \$p\"; kill -9 \$p; }
        # test_camera does not only talk to the camera: after connect() it opens the input stack and
        # then renders the preview into a Wayland surface through hybris EGL, so it needs the running
        # session compositor. Root can connect to the socket the phone own user created, which is
        # what this is (nsenter needs root anyway).
        W=\$(ls /run/user/*/wayland-0 2>/dev/null | head -1)
        if [ -n \"\$W\" ]; then
          XR=\${W%/wayland-0}; WD=wayland-0
        else
          XR=; WD=
        fi
        echo \"== wayland: XDG_RUNTIME_DIR=\$XR WAYLAND_DISPLAY=\$WD\"
        echo \"== output in \$d on the device\"
        nsenter -t \$A -p -- timeout $SECS env \\
          HYBRIS_LD_LIBRARY_PATH=/userdata/zl1-hybris/lib:/system/lib64:/odm/lib64:/vendor/lib64 \\
          LD_PRELOAD='$PRELOAD' \\
          GTK_MODULES= HOME=/root XDG_RUNTIME_DIR=\"\$XR\" WAYLAND_DISPLAY=\"\$WD\" \\
          $cmd > \$d/out 2> \$d/err
        echo \"== exit=\$?\"
        # the tls shim's own diagnostics are most of the bytes and none of the answer
        grep -avE '^c+\$|^tlsfix2 ' \$d/err | tail -40 | sed 's/^/err| /'
        tail -40 \$d/out | sed 's/^/out| /'
        # What success looks like: test_camera prints this once the preview is running, and then it
        # renders frames until the timeout kills it. It never takes a picture -- there is no
        # take_picture() call in it at all -- so a JPEG is not the thing to look for.
        echo '== reached the preview?'
        grep -aq 'Started camera preview' \$d/out && echo '  yes: Started camera preview.' || echo '  no'
        echo '== any image written?'
        ls -l \$d/*.jpeg \$d/*.jpg /tmp/*.jpeg /tmp/*.jpg /tmp/shot_* 2>/dev/null || echo '  none'
        echo '== what cameraserver did, from its own log:'
        tail -25 /userdata/zl1-fw-stubs/service-stub.log 2>/dev/null | sed 's/^/  /'
        echo '== cameraserver logcat, last camera lines:'
        nsenter -t \$A -p -- /system/bin/logcat -b main -d -v brief 2>/dev/null | grep -a -iE 'camera' | tail -15"
