#!/usr/bin/env bash
# Does the UT camera app's window reach the screen -- and is it live? One command, from the host.
#
# Why this exists. Two things were established separately and never joined (docs 80 and 77):
#
#   * the UT camera app now starts (docs 80): it connects to Mir, gets hybris' EGL, builds its QML,
#     enumerates both cameras ("Added camera 0/1") and stays up -- but every one of those runs had the
#     **display off** (ActiveOutputs 0 0), so nothing was ever said about what is on the screen;
#   * the criterion for "something is on the screen and alive" was measured in docs 68 §5 and 77: with
#     the display ON, the compositor (lomiri-system-compositor) burns ~1.2 ticks/s with no client and
#     20-50 ticks/s while a client is rendering -- and **a screenshot never proves liveness**, because
#     a dead client's last frame stays in the shell's scene (pixel-identical grabs, NCC 0.997, even
#     after a TurnOn/sleep/re-grab cycle).
#
# So this script runs the protocol end to end and reports the two measurements side by side, which is
# what neither of the earlier runs did: compositor CPU (liveness) *and* a grab (what it looks like),
# with the display state recorded at every step. It also leaves the display as it found it.
#
# What it does, in order:
#   0. guard on the device-tree model (this is not a generic script)
#   1. record ActiveOutputs, then TurnOn (reversible, DBus, the shell's own display service)
#   2. window A: compositor ticks/s with the display ON and **no** camera app  -> the baseline
#   3. launch the app (scripts/device/zl1-camapp-launch.py, in the container's PID namespace, as the
#      session's own uid, with the session's own environment) in the background
#   4. window B: compositor ticks/s and the app's process state while it runs
#   5. a shell grab (scripts/host/zl1-screenshot.sh) so there is a picture to look at
#   6. TurnOff (back to what step 1 found) and stop the app
#   7. a verdict, with the numbers it is based on, and an explicit list of what it does NOT prove
#
# Reading the result: window B >> window A (the measured band is ~1.2/s vs 20-50/s) means the
# compositor is doing work for the app -- frames are reaching it. Window B ~= window A means the app's
# window is not being composited, whatever the QML thinks it is doing. Neither number says the picture
# is *correct*; that is what the grab is for, and the grab alone says nothing about liveness.
#
# Usage: zl1-camera-app-test.sh [--seconds N] [--run-seconds N] [--no-shot] [--keep-display]
#                               [--extra-args "..."] [--outdir DIR]
#
#   --seconds N      length of each ticks window (default 12)
#   --run-seconds N  how long the app is left running (default 45; must exceed 2 x --seconds)
#   --no-shot        skip the screenshot step
#   --keep-display   do not TurnOff at the end (for a human to look at the phone)
#   --extra-args     extra arguments for the app binary (e.g. "--mode=barcode-reader")
#   --outdir DIR     where to keep the app's stdout/stderr locally (default /tmp/zl1-camera-app-<ts>)

set -uo pipefail

HOST="${ZL1_HOST:-root@10.15.19.82}"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10)
SECS=12
RUN_SECS=45
SHOT=1
KEEP_DISPLAY=0
EXTRA=""
OUTDIR=""
APP_DIR=/usr/share/click/preinstalled/camera.ubports/4.1.1
APP_BIN=$APP_DIR/lomiri-camera-app
APP_ID=camera.ubports_camera_4.1.1

while [ $# -gt 0 ]; do
  case "$1" in
  --seconds) SECS="$2"; shift 2 ;;
  --run-seconds) RUN_SECS="$2"; shift 2 ;;
  --no-shot) SHOT=0; shift ;;
  --keep-display) KEEP_DISPLAY=1; shift ;;
  --extra-args) EXTRA="$2"; shift 2 ;;
  --outdir) OUTDIR="$2"; shift 2 ;;
  --help|-h) sed -n '2,52p' "$0"; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

[ -n "$OUTDIR" ] || OUTDIR="/tmp/zl1-camera-app-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUTDIR"

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"

ssh_d() { timeout "$((RUN_SECS + 180))" ssh "${SSH_OPTS[@]}" "$HOST" "$@"; }
say() { printf '%s\n' "$*"; }

# --- 0. guard: this must be the zl1, and this must not be the wrong device on the bus -------------

model="$(ssh_d "tr -d '\\0' < /proc/device-tree/model 2>/dev/null" || true)"
case "$model" in
*"MSM 8996pro + PMI8996 LE_ZL1"*) ;;
*) say "error: this is not the zl1: device-tree model is \"$model\"" >&2; exit 1 ;;
esac

say "zl1 camera app on screen :: outdir $OUTDIR"

# The launcher has to be on the device. Stage it rather than assuming a previous run left it there,
# because a stale copy would silently run the old logic.
scp -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "$repo/scripts/device/zl1-camapp-launch.py" "$HOST:/tmp/zl1-camapp-launch.py" ||
  { say "error: could not copy zl1-camapp-launch.py to the device" >&2; exit 1; }

# --- the device-side pieces, in one round trip where possible ------------------------------------

read_state() {
  ssh_d 'A=$(lxc-info -n android -pH 2>/dev/null | head -1)
    C=$(for p in /proc/[0-9]*; do
          [ -r "$p/cmdline" ] || continue
          c=$(tr "\0" " " < "$p/cmdline" 2>/dev/null)
          case "$c" in /usr/sbin/lomiri-system-compositor*) echo "${p#/proc/}"; break ;; esac
        done)
    S=$(pgrep -x lomiri | head -1)
    echo "container=$A"
    echo "compositor=$C"
    echo "shell=$S"
    echo "outputs=$(busctl --system get-property com.lomiri.SystemCompositor.Display \
        /com/lomiri/SystemCompositor/Display com.lomiri.SystemCompositor.Display ActiveOutputs 2>/dev/null)"'
}

# pgrep -f is unreliable on this device for the compositor (docs 68 section 5: it matches nothing), so
# the pid is found by walking /proc and matching the whole cmdline. The ticks come from /proc/<pid>/stat
# fields 14+15 (HZ=100) -- never from top, whose instantaneous percentages cannot be added up. The comm
# field is stripped with sub() first: it is parenthesised and may contain a space, which would shift the
# utime/stime fields onto the wrong numbers (the same trap docs 81 records for the thermal instrument).
ticks_window() {
  local label="$1" secs="$2" pid="$3"
  ssh_d "a=\$(awk '{ sub(/^[^)]*\) /, \"\"); print \$12+\$13 }' /proc/$pid/stat)
    sleep $secs
    b=\$(awk '{ sub(/^[^)]*\) /, \"\"); print \$12+\$13 }' /proc/$pid/stat)
    echo \"$label \$((b-a)) \$(( (b-a) * 100 / $secs ))\"" | tail -1
}

state="$(read_state)"
A="$(printf '%s\n' "$state" | sed -n 's/^container=//p')"
COMP="$(printf '%s\n' "$state" | sed -n 's/^compositor=//p')"
SHELLPID="$(printf '%s\n' "$state" | sed -n 's/^shell=//p')"
OUT_BEFORE="$(printf '%s\n' "$state" | sed -n 's/^outputs=//p')"

say "container=$A  compositor=$COMP  shell=$SHELLPID"
say "ActiveOutputs before: ${OUT_BEFORE:-<unreadable>}"
[ -n "$A" ] || { say "error: no android container" >&2; exit 1; }
[ -n "$COMP" ] || { say "error: could not find the compositor process (cmdline '\''/usr/sbin/lomiri-system-compositor --enable'\'')" >&2; exit 1; }
[ -n "$SHELLPID" ] || { say "error: no lomiri shell process -- is the GUI up?" >&2; exit 1; }

restore_display() {
  if [ "$KEEP_DISPLAY" = 0 ]; then
    # Back to what step 1 found. Off is the state every previous camera run was made in, so putting it
    # back is the conservative choice; --keep-display is for a human who wants to look at the phone.
    case "$OUT_BEFORE" in
    *"1 "*) ssh_d 'busctl --system call com.lomiri.SystemCompositor.Display \
        /com/lomiri/SystemCompositor/Display com.lomiri.SystemCompositor.Display TurnOn s "zl1-camapp-test"' >/dev/null 2>&1 ;;
    *) ssh_d 'busctl --system call com.lomiri.SystemCompositor.Display \
        /com/lomiri/SystemCompositor/Display com.lomiri.SystemCompositor.Display TurnOff s "zl1-camapp-test"' >/dev/null 2>&1 ;;
    esac
    say "display restored to: $(ssh_d 'busctl --system get-property com.lomiri.SystemCompositor.Display \
        /com/lomiri/SystemCompositor/Display com.lomiri.SystemCompositor.Display ActiveOutputs 2>/dev/null')"
  fi
}
trap restore_display EXIT INT TERM

# --- 1. display on (reversible; this is the shell's own display service) -------------------------

say ""
say "== turning the display on"
ssh_d 'busctl --system call com.lomiri.SystemCompositor.Display \
    /com/lomiri/SystemCompositor/Display com.lomiri.SystemCompositor.Display TurnOn s "zl1-camapp-test"' \
  >/dev/null 2>&1
sleep 3
OUT_ON="$(ssh_d 'busctl --system get-property com.lomiri.SystemCompositor.Display \
    /com/lomiri/SystemCompositor/Display com.lomiri.SystemCompositor.Display ActiveOutputs 2>/dev/null')"
say "ActiveOutputs now: $OUT_ON"
case "$OUT_ON" in
*"1 "*) ;;
*) say "WARNING: the display did not report an active output. The clicks below will still run, but"
   say "         'no damage' and 'a dead display' look identical, so read the result with that in mind." ;;
esac

# --- 2. window A: the baseline, display ON, no camera app ----------------------------------------

say ""
say "== window A (${SECS}s): display ON, no camera app -- the baseline doc 68 section 5 measured at ~1.2/s"
A_RES="$(ticks_window A "$SECS" "$COMP")"
say "   $A_RES   (label ticks ticks_per_second)"
A_TPS="$(printf '%s' "$A_RES" | awk '{print $3}')"

# --- 3. launch the app ---------------------------------------------------------------------------

say ""
say "== launching $APP_ID (as uid 32011, container PID namespace, session environment)"
ssh_d "rm -f /tmp/zl1-camapp.out /tmp/zl1-camapp.err
  setsid nohup nsenter -t $A -p -- timeout $RUN_SECS env ZL1_AS_UID=32011 \
    ZL1_PRELOAD_EXTRA='/userdata/zl1-hybris/lib/libcfi-shadow-init.so /userdata/zl1-hybris/lib/crash-dump.so' \
    python3 /tmp/zl1-camapp-launch.py $APP_BIN $APP_ID $APP_DIR $SHELLPID $EXTRA \
    > /tmp/zl1-camapp.out 2> /tmp/zl1-camapp.err < /dev/null &
  sleep 1
  # pgrep -f is unreliable on this device (docs 68 section 5), so find the app by walking /proc.
  found=
  for p in /proc/[0-9]*/cmdline; do
    case \"\$(tr '\0' ' ' < \"\$p\" 2>/dev/null)\" in \"$APP_BIN \"*) found=\${p%/cmdline}; break ;; esac
  done
  [ -n \"\$found\" ] && echo \"launched pid \${found#/proc/}\" || echo 'NOT launched (the launcher exited immediately)'"

# The app needs a few seconds to load QML and ask for EGL before it has anything to draw; sampling
# immediately would measure the compositor doing nothing and look like a failure.
sleep 6

# --- 4. window B: while the app runs ------------------------------------------------------------

say ""
say "== window B (${SECS}s): while the camera app runs"
B_RES="$(ticks_window B "$SECS" "$COMP")"
say "   $B_RES   (label ticks ticks_per_second)"
B_TPS="$(printf '%s' "$B_RES" | awk '{print $3}')"

alive="$(ssh_d "found=; for p in /proc/[0-9]*/cmdline; do
    case \"\$(tr '\0' ' ' < \"\$p\" 2>/dev/null)\" in \"$APP_BIN \"*) found=\${p%/cmdline}; break ;; esac
  done
  if [ -n \"\$found\" ]; then
    pid=\${found#/proc/}
    echo \"alive pid=\$pid state=\$(awk '{print \$3}' /proc/\$pid/stat) threads=\$(ls /proc/\$pid/task 2>/dev/null | wc -l)\"
  else
    echo 'NOT RUNNING (it exited before the window ended -- read app.err)'
  fi")"
say "   app: $alive"

# --- 5. the grab --------------------------------------------------------------------------------

SHOT_PNG=""
if [ "$SHOT" = 1 ]; then
  say ""
  say "== a shell grab (what it looks like; NOT proof of liveness -- docs 77)"
  SHOT_PNG="$OUTDIR/shot-during-app.png"
  if bash "$repo/scripts/host/zl1-screenshot.sh" --out "$SHOT_PNG" --quiet; then
    say "   wrote $SHOT_PNG ($(stat -c %s "$SHOT_PNG" 2>/dev/null) bytes)"
    if command -v identify >/dev/null 2>&1; then
      identify "$SHOT_PNG" 2>/dev/null | sed 's/^/   /'
    fi
  else
    say "   the grab failed -- that is a fact about the grab, not about the app"
  fi
  say "   compare it to a known reference with:  compare -metric NCC <ref> $SHOT_PNG null: 2>&1"
  say "   (~0.9 = same picture; the shell's scene keeps a dead client's last frame, docs 77)"
fi

# --- 6. collect the app's own output ------------------------------------------------------------

ssh_d "for p in /proc/[0-9]*/cmdline; do
    case \"\$(tr '\0' ' ' < \"\$p\" 2>/dev/null)\" in \"$APP_BIN \"*) kill \${p%/cmdline} 2>/dev/null ;; esac
  done
  sleep 1
  echo stopped" >/dev/null 2>&1
scp -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "$HOST:/tmp/zl1-camapp.out" "$OUTDIR/app.out" 2>/dev/null || true
scp -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "$HOST:/tmp/zl1-camapp.err" "$OUTDIR/app.err" 2>/dev/null || true

# --- 7. the verdict ----------------------------------------------------------------------------

say ""
say "== the app's own evidence (from $OUTDIR/app.err):"
for pat in 'Creating a QMirClientScreen' 'Added camera' 'Application is now active' \
           'ASSERT' 'caught signal' 'not found'; do
  n=$(grep -ac "$pat" "$OUTDIR/app.err" 2>/dev/null || echo 0)
  printf '   %-32s %s\n' "$pat" "$n"
done
grep -a 'Added camera' "$OUTDIR/app.err" 2>/dev/null | head -2 | sed 's/^/   | /'

say ""
say "== verdict"
say "   compositor with no client:   ${A_TPS}/s   (${A_RES#A })"
say "   compositor with the app:     ${B_TPS}/s   (${B_RES#B })"
if [ -n "${A_TPS:-}" ] && [ -n "${B_TPS:-}" ]; then
  if [ "$B_TPS" -ge $((A_TPS * 4)) ] && [ "$B_TPS" -ge 8 ]; then
    say "   -> the compositor is doing work for the app: the measured band for 'a client is rendering'"
    say "      is 20-50/s against a 1.2/s idle baseline (docs 68 section 5). Combined with the grab,"
    say "      that is 'the app's window is being composited'. It is what a human should then confirm"
    say "      by looking at the phone (--keep-display)."
  elif [ "$B_TPS" -le $((A_TPS + 2)) ]; then
    say "   -> NO extra compositor work: the app is not being composited, whatever it reports. Either"
    say "      it has no visible window yet, or its surface is not reaching the shell."
  else
    say "   -> inconclusive: more work than the baseline but well under the 20-50/s band. Read the app's"
    say "      stderr above and the grab before concluding anything."
  fi
fi

say ""
say "== what this does NOT prove"
say "   * that the picture is correct, or that the preview has frames in it -- only that the compositor"
say "     is drawing for the app and what the grab looks like"
say "   * anything about the camera pipeline itself: 'Added camera 0/1' is enumeration, not frames"
say "     (docs 80 section 6)"
say "   * that the app would behave the same when launched by lomiri-app-launch rather than by the"
say "     launcher script"
say ""
say "artifacts: $OUTDIR  (app.out, app.err${SHOT_PNG:+, shot-during-app.png})"
