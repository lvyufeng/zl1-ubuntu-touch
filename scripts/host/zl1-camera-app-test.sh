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
# is *correct*; that is what the grab is for, and the grab alone says nothing about liveness. The unit
# is jiffies per second from /proc/<pid>/stat (HZ=100, so 1 tick/s is 1% of one core) -- the first
# version of this script printed 100x that, which put the `B >= 8` gate at 0.08/s and made it
# unfalsifiable for anything but a stopped compositor.
#
# And the verdict now reads the app's own state FIRST: whether it launched, and whether it was still
# running at the end of window B. Without that, a launcher failure came out as "the app is not being
# composited" -- the instrument blaming the app for something it never got the chance to do.
#
# Usage: zl1-camera-app-test.sh [--seconds N] [--run-seconds N] [--no-shot] [--keep-display]
#                               [--extra-args "..."] [--outdir DIR]
#
#   --seconds N      length of each ticks window (default 12)
#   --run-seconds N  how long the app is left running (default 45). It must be at least
#                    --seconds + 6 + 2, because window B starts 6 s after the launch and lasts
#                    --seconds: below that the app is killed mid-window and the verdict would
#                    report "not composited" for a parameter mistake. Refused, not warned.
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
  --seconds) SECS="${2?--seconds needs a number}"; shift 2 ;;
  --run-seconds) RUN_SECS="${2?--run-seconds needs a number}"; shift 2 ;;
  --no-shot) SHOT=0; shift ;;
  --keep-display) KEEP_DISPLAY=1; shift ;;
  --extra-args) EXTRA="${2?--extra-args needs a value}"; shift 2 ;;
  --outdir) OUTDIR="${2?--outdir needs a directory}"; shift 2 ;;
  --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0" ; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

# The app is launched with `timeout $RUN_SECS` and window B starts 6 s later and lasts $SECS, so the
# app must still be alive at 6 + SECS. If it is not, the app is killed in the middle of window B and
# the verdict reads "NO extra compositor work" -- i.e. it blames the app for a parameter, which is the
# one thing this instrument must never do. The header used to say "must exceed 2 x --seconds", which
# is not the arithmetic (window A runs BEFORE the launch and does not need the app at all).
_min=$((SECS + 6 + 2))
if [ "$RUN_SECS" -lt "$_min" ]; then
  echo "error: --run-seconds $RUN_SECS is too small for --seconds $SECS" >&2
  echo "       the app is launched with 'timeout $RUN_SECS', window B starts 6 s later and lasts ${SECS}s," >&2
  echo "       so the app is killed mid-window and the verdict would blame it for a parameter." >&2
  echo "       want --run-seconds >= $((SECS + 6)) (this run needs >= $_min), or a smaller --seconds" >&2
  exit 2
fi

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
#
# **The rate is jiffies per second, and it is a DIVISION.** The first version printed
# `(b-a) * 100 / secs`, which is 100x the unit the same header calls "ticks/s" and 100x the numbers the
# band is quoted in (docs 68 section 5: 1.2 idle, 27.8 and 33-50 with a client, HZ=100, so 1 tick/s is
# 1% of one core). The consequence was not cosmetic: the absolute gate below (`B >= 8`) was written to
# mean "8 ticks/s, comfortably above the 1.2 baseline" and, as computed, meant 0.08 -- it could not
# fail for anything but a perfectly idle compositor, so only the ratio test was doing any work. The
# delta and the seconds now come back and the rate is computed here, in the documented unit.
ticks_window() { # $1 label, $2 secs, $3 pid -> "LABEL <jiffies> <ticks/s>"
  local label="$1" secs="$2" pid="$3" res d
  res="$(ssh_d "a=\$(awk '{ sub(/^[^)]*\) /, \"\"); print \$12+\$13 }' /proc/$pid/stat)
    sleep $secs
    b=\$(awk '{ sub(/^[^)]*\) /, \"\"); print \$12+\$13 }' /proc/$pid/stat)
    echo \"$label \$((b-a))\"" | tail -1)"
  d="$(printf '%s' "$res" | awk '{print $2}')"
  # An unreadable window stays unreadable: printing "0.0" here would make an ssh failure look exactly
  # like a compositor doing nothing, and the verdict would then blame the app for it.
  [ -n "$d" ] || return 0
  printf '%s %s %s\n' "$label" "$d" "$(awk -v d="$d" -v s="$secs" 'BEGIN{printf "%.1f", d/s}')"
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
say "   $A_RES   (label jiffies ticks_per_second; HZ=100, so 1 tick/s is 1% of one core)"
A_TPS="$(printf '%s' "$A_RES" | awk '{print $3}')"

# --- 3. launch the app ---------------------------------------------------------------------------

say ""
say "== launching $APP_ID (as uid 32011, container PID namespace, session environment)"
LAUNCH="$(ssh_d "rm -f /tmp/zl1-camapp.out /tmp/zl1-camapp.err
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
  [ -n \"\$found\" ] && echo \"launched pid \${found#/proc/}\" || echo 'NOT launched (the launcher exited immediately)'")"
# The step-3 answer is what decides whether the compositor numbers below are ABOUT THE APP at all.
# It was printed and then never used, so a launcher failure came out as "the app is not being
# composited" -- the instrument blaming the app for something it never got the chance to do.
APP_STARTED=0
case "$LAUNCH" in *"launched pid "*) APP_STARTED=1 ;; esac
say "   $LAUNCH"

# The app needs a few seconds to load QML and ask for EGL before it has anything to draw; sampling
# immediately would measure the compositor doing nothing and look like a failure.
sleep 6

# --- 4. window B: while the app runs ------------------------------------------------------------

say ""
say "== window B (${SECS}s): while the camera app runs"
B_RES="$(ticks_window B "$SECS" "$COMP")"
say "   $B_RES   (label jiffies ticks_per_second; HZ=100, so 1 tick/s is 1% of one core)"
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
APP_ALIVE=0
case "$alive" in *"alive pid="*) APP_ALIVE=1 ;; esac

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
# Exactly ONE number per count. `n=$(grep -c PAT F || echo 0)` looks harmless and is not: grep -c
# prints "0" AND exits 1 when nothing matches, so the fallback appends a second "0" and the value
# carries an embedded newline -- which the row below printed as a stray extra line, on exactly the
# rows that matter most ('ASSERT' and 'caught signal' are SUPPOSED to be 0, and a reader who sees a
# 0 on its own line cannot tell it from a row of the table).
count_in() { # $1 file, $2 pattern -> one number, always
  local n=
  [ -r "$1" ] && n="$(grep -ac -- "$2" "$1" 2>/dev/null)"
  printf '%s\n' "${n:-0}"
}
# **Both streams are counted, and the output says which one had it.** Which of stdout/stderr Qt and
# QML write to is not something this script establishes, and the launcher execs the app in place so
# the shell's redirections are what the app inherits (zl1-camapp-launch.py, os.execvpe). Counting one
# stream and calling it "the app's own evidence" is the error docs 102/103 are about: a count read
# from a source that may not contain the string, whose 0 then reads as "the app never got there".
say "== the app's own evidence (both streams; the columns say which file each count came from):"
say "   (which of the two a message lands in is not established here -- counts are per file on purpose)"
for pat in 'Creating a QMirClientScreen' 'Added camera' 'Application is now active' \
           'ASSERT' 'caught signal' 'not found'; do
  printf '   %-32s %4s err  %4s out\n' "$pat" \
    "$(count_in "$OUTDIR/app.err" "$pat")" "$(count_in "$OUTDIR/app.out" "$pat")"
done
for f in "$OUTDIR/app.err" "$OUTDIR/app.out"; do
  [ -s "$f" ] || continue
  n=$(count_in "$f" 'Added camera')
  [ "$n" = 0 ] && continue
  say "   -- 'Added camera' in $(basename "$f"):"
  grep -a 'Added camera' "$f" 2>/dev/null | head -2 | sed 's/^/   | /'
done

say ""
say "== verdict"
say "   compositor with no client:   ${A_TPS}/s   (${A_RES#A })"
say "   compositor with the app:     ${B_TPS}/s   (${B_RES#B })"
# The app's own state comes first, because the two compositor numbers mean different things depending
# on it: if the app never started, or died before window B ended, then window B measured the display
# and not the app, and no ratio between the two numbers is about the camera app. The three states are
# mutually exclusive and are tested in that order -- "never started" is the strongest statement, and
# printing the "it died" note under it would only be noise (the app that never started is certainly
# not running either).
if [ "$APP_STARTED" = 0 ]; then
  say "   -> the app NEVER STARTED: the launcher exited immediately after the launch step, so there was"
  say "      no app window to composite and the numbers above are not a measurement of the camera app."
  say "      This is a launcher failure (uid, session bus, EGL, a missing binary), not a compositor one:"
  say "      read the evidence table and the launcher's own lines above before concluding anything."
elif [ "$APP_ALIVE" = 0 ]; then
  say "   -> the app is NOT running at the end of window B ($alive), so the window B number above is"
  say "      about the display, not about the app. Read the app's evidence above and the launcher output."
elif [ -n "${A_TPS:-}" ] && [ -n "${B_TPS:-}" ]; then
  # Same two conditions, now in the unit they were written for: B at least 4x the baseline AND B
  # comfortably above idle (8 ticks/s = 8% of a core, against a 1.2/s baseline). awk because the rate
  # carries a decimal; `[ -ge ]` would refuse it.
  verdict_num="$(awk -v a="$A_TPS" -v b="$B_TPS" 'BEGIN{
      if (b >= 4*a && b >= 8) print "composited";
      else if (b <= a + 2)    print "none";
      else                    print "inconclusive";
    }')"
  case "$verdict_num" in
  composited)
    say "   -> the compositor is doing work for the app: the measured band for 'a client is rendering'"
    say "      is 20-50/s against a 1.2/s idle baseline (docs 68 section 5). Combined with the grab,"
    say "      that is 'the app's window is being composited'. It is what a human should then confirm"
    say "      by looking at the phone (--keep-display)."
    ;;
  none)
    say "   -> NO extra compositor work: the app is not being composited, whatever it reports. Either"
    say "      it has no visible window yet, or its surface is not reaching the shell."
    ;;
  *)
    say "   -> inconclusive: more work than the baseline but well under the 20-50/s band. Read the app's"
    say "      evidence above and the grab before concluding anything."
    ;;
  esac
else
  # Neither branch used to fire here, so a window that could not be read produced NO verdict line at
  # all -- a silent non-answer, which reads like a verdict that happened to be empty.
  say "   -> NO VERDICT: one of the two windows could not be read (A='${A_TPS:-}' B='${B_TPS:-}'), so"
  say "      there is nothing to compare. Check that the compositor pid was found and that ssh returned:"
  say "      a failed measurement is not a measurement of the app."
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
