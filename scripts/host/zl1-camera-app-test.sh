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
# **AND THE APP'S OWN RATE IS MEASURED TOO, because one number cannot tell two failures apart.** The
# first device run of this instrument (2026-09-26, boot 2fbf9f8e) printed "NO extra compositor work:
# the app is not being composited, whatever it reports" -- and that sentence is a statement about the
# *compositor* made from a measurement of the compositor alone. The app's own CPU was measured
# afterwards by hand and it was **0.1 ticks/s**: eleven threads, every one of them asleep (the main
# thread in `binder_thread_read`), the process having printed `Added camera 0/1` and
# `Application is now active` and then done essentially nothing. A window that is never painted cannot
# raise the compositor's rate, so "not composited" was true and misleading at the same time: the
# question it was taken to answer -- is the shell stacking the app's surface? -- had not been asked.
# The three states are now separated, with the numbers that separate them printed:
#
#     app idle  + compositor idle  -> the app never painted: the compositor number is about the display
#     app busy  + compositor idle  -> the app paints and the shell does not composite it (stacking)
#     app busy  + compositor busy  -> composited
#
# **AND THE PREMISE IS READ BEFORE ANYTHING IS MEASURED: no camera app may already be running.** Window
# A is "the display with NO camera app", the launch step finds the app by walking /proc and taking the
# first match, and step 6 is what ends it -- so a leftover process from an earlier run is not a detail,
# it is the thing this run would measure. Measured 2026-09-26: a run reported "the app's own rate:
# 0.1/s ... THE APP NEVER PAINTED" about a process started **22 minutes earlier** by the run before it
# (same pid, ppid = a `timeout` that had already fired), while the evidence table printed the NEW
# process's first two lines. The app **ignores SIGTERM** -- `timeout` sends nothing else, and the stop
# step used a bare `kill` -- so a leftover survives every run that does not escalate. The premise is
# therefore a reading (`--clean-first` stops a leftover with SIGTERM, then SIGKILL, and verifies),
# and the stop itself escalates and says which signal was needed.
#
# Two supporting readings come with it, both cheap and both things the earlier verdict assumed away:
# the app's threads' `/proc/<pid>/task/*/wchan`, which says *where* an app that is not painting is
# waiting, and the number of established connections on the session's Mir socket (from the shell's own
# `MIR_SERVER_FILE`) before the launch, while the app runs, and after it is stopped -- so that "the app
# never reached the compositor" is answered by a number that appears and disappears with the app
# instead of being assumed. Reading an unreadable file stays unreadable: counts print `<unreadable>`
# rather than 0, because "there is no connection" and "I could not look" are different answers.
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
#   --clean-first    if a camera app is already running, stop it (SIGTERM, then SIGKILL) and verify it
#                    is gone before measuring, instead of refusing to run
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
CLEAN_FIRST=0
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
  --clean-first) CLEAN_FIRST=1; shift ;;
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

# The session's Mir socket, named by the shell's OWN environment (`MIR_SERVER_FILE`), and how many
# clients are connected to it. The count is read three times -- before the launch, while the app runs,
# and after it is stopped -- because a delta that appears and disappears with the app is evidence the
# app connected, while a single "one more than before" is a coincidence waiting to happen (the session
# has other clients). The path is not hardcoded: it is read from the shell, and only falls back to the
# launcher's own default when the shell does not name one.
#
# Quoting, because it is load-bearing: the awk program is in SINGLE quotes inside the host's
# double-quoted string, so the field references arrive at the device unexpanded (`$6` in a
# double-quoted remote command would be expanded by the device's shell before awk saw it), and the
# path is passed with `-v` so it never becomes part of the program.
mir_path() { # $1 = shell pid -> the socket the session's clients connect to
  ssh_d "tr '\\0' '\\n' < /proc/${1:-0}/environ 2>/dev/null | sed -n 's|^MIR_SERVER_FILE=||p' | head -1" \
    2>/dev/null | tr -d '\r' | tail -1
}
mir_conns() { # $1 = socket path -> established connections, or <unreadable>
  ssh_d "if [ -r /proc/net/unix ]; then
      awk -v p='$1' '\$6+0==3 {if (\$8==p) n++} END {print n+0}' /proc/net/unix 2>/dev/null
    else
      echo '<unreadable>'
    fi" 2>/dev/null | tail -1
}
# Where an app that is not painting is waiting. `/proc/<pid>/task/*/wchan` is the kernel symbol each
# thread is blocked in, and for this question it is the whole answer: a client that is blocked in
# `binder_thread_read` is waiting for a device, not for a frame to be composited. Counted per symbol,
# most frequent first. An empty wchan is dropped rather than printed as an empty name -- a line that
# says nothing is worse than no line, and the count of threads is already on the `app:` line above.
task_waits() { # $1 = pid -> "SYMBOL n, SYMBOL n, ..."
  ssh_d "for t in /proc/$1/task/*; do w=\$(cat \$t/wchan 2>/dev/null); [ -n \"\$w\" ] && printf '%s\n' \"\$w\"; done |
    sort | uniq -c | sort -rn | head -3 | awk '{printf \"%s%s %s\", (NR>1 ? \", \" : \"\"), \$2, \$1}'" 2>/dev/null | tail -1
}

# The app's presence, read the same way everywhere: argv[0] IS the app binary. `/proc` order is what the
# launch step's walk returns first, so `app_first` answers exactly the question "which process would
# this run end up measuring". The count is not the point -- the first match is.
app_first() { # -> "/proc/<pid>" of the first match, empty if none
  ssh_d "for p in /proc/[0-9]*/cmdline; do
      case \"\$(tr '\0' ' ' < \"\$p\" 2>/dev/null)\" in \"$APP_BIN \"*) echo \"\${p%/cmdline}\"; break ;; esac
    done" 2>/dev/null | tr -d '\r' | grep -E '^/proc/[0-9]+$' | tail -1
}
# Stop the app and PROVE it went: SIGTERM, a walk, SIGKILL, a walk again -- and report which signal was
# needed. This app ignores SIGTERM (2026-09-26: an app launched 22 minutes earlier was still in state S
# with 11 threads, long after the run that started it had "stopped" it and after its own `timeout` had
# fired), so a stop that does not escalate leaves a process behind that the NEXT run will measure. The
# two sleeps are also what the offline harness indexes its rate fixture by, which is why they are inside
# this function rather than sprinkled at the call sites.
stop_app() { # -> one line: nothing to stop / stopped by SIGTERM / stopped by SIGKILL (...) / STILL RUNNING
  ssh_d "gone() { for p in /proc/[0-9]*/cmdline; do
        case \"\$(tr '\0' ' ' < \"\$p\" 2>/dev/null)\" in \"$APP_BIN \"*) echo \"\${p%/cmdline}\"; return 0 ;; esac
      done; return 1; }
    [ -n \"\$(gone)\" ] || { echo 'nothing to stop'; exit 0; }
    for p in /proc/[0-9]*/cmdline; do
      case \"\$(tr '\0' ' ' < \"\$p\" 2>/dev/null)\" in \"$APP_BIN \"*) kill \${p%/cmdline} 2>/dev/null ;; esac
    done
    sleep 2
    left=\"\$(gone)\"
    if [ -n \"\$left\" ]; then
      for p in /proc/[0-9]*/cmdline; do
        case \"\$(tr '\0' ' ' < \"\$p\" 2>/dev/null)\" in \"$APP_BIN \"*) kill -9 \${p%/cmdline} 2>/dev/null ;; esac
      done
      sleep 1
      left=\"\$(gone)\"
      if [ -n \"\$left\" ]; then echo \"STILL RUNNING after SIGKILL: \$left\"; else echo 'stopped by SIGKILL (it ignored SIGTERM)'; fi
    else
      echo 'stopped by SIGTERM'
    fi" 2>/dev/null | tail -1
}

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

# --- 0.6 the premise: no camera app is running, and this run must not measure an earlier one ------

# Checked BEFORE the display is touched, so a refusal leaves the phone exactly as it was found.
PRE_APP="$(app_first)"
if [ -n "$PRE_APP" ]; then
  say ""
  say "== PREMISE: a camera app is ALREADY running ($PRE_APP)"
  if [ "$CLEAN_FIRST" = 0 ]; then
    say "   REFUSING to measure. Window A is 'the display with no camera app in it' and the launch step"
    say "   finds the app with a walk that returns the FIRST match, so this run would report numbers"
    say "   about $PRE_APP -- a process it did not start -- and the app it launches would be measured by"
    say "   nobody. Nothing has been touched: the display is as it was found and no app was signalled."
    say "   Either stop it by hand (kill -9 ${PRE_APP#/proc/}; this app ignores SIGTERM), or re-run with"
    say "   --clean-first, which stops it (SIGTERM, then SIGKILL), verifies, and then measures."
    exit 1
  fi
  say "   --clean-first: $(stop_app)"
  PRE_LEFT="$(app_first)"
  if [ -n "$PRE_LEFT" ]; then
    say "   REFUSING: $PRE_LEFT is still there after SIGTERM and SIGKILL. A process this script cannot"
    say "   stop is one it cannot measure around, and nothing has been started."
    exit 1
  fi
  say "   the app is gone: measuring from a clean premise"
fi

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
#
# **One place turns jiffies into a rate, because there are three rates now.** The compositor's baseline,
# the compositor's window with the app, and the app's own. A `-` (a reading that failed) stays a `-`: it
# is never divided into 0.0, because 0.0 is a number that means "this process did nothing".
rate_of() { # $1 jiffies or -, $2 seconds -> "N.N" or "-"
  case "$1" in ''|-|*[!0-9]*) printf '%s\n' "-"; return 0 ;; esac
  awk -v d="$1" -v s="$2" 'BEGIN{printf "%.1f", d/s}'
}
ticks_window() { # $1 label, $2 secs, $3 compositor pid, $4 app pid (empty = no app in this window)
  local label="$1" secs="$2" pid="$3" apid="${4:-}" res d da mark
  if [ -n "$apid" ]; then
    # BOTH rates come out of ONE window: the two deltas share the same sleep, so "the app was painting
    # while the compositor was not" is two readings of the SAME interval rather than of two intervals
    # seconds apart (this phone drifts several degrees in an hour and its rates drift with it -- docs
    # 167/177). The two readings are marked unreadable INDIVIDUALLY: a `-` here must never become 0,
    # because 0 is exactly the value that means "the app burned no CPU" -- the confusion this window
    # exists to remove.
    res="$(ssh_d "j() { awk '{ sub(/^[^)]*\) /, \"\"); print \$12+\$13 }' /proc/\$1/stat 2>/dev/null; }
      a=\$(j $pid); p=\$(j $apid)
      sleep $secs
      b=\$(j $pid); q=\$(j $apid)
      if [ -n \"\$a\" ] && [ -n \"\$b\" ]; then c=\$((b-a)); else c=-; fi
      if [ -n \"\$p\" ] && [ -n \"\$q\" ]; then z=\$((q-p)); else z=-; fi
      echo \"$label \$c \$z 2\"" | tail -1)"
  else
    res="$(ssh_d "j() { awk '{ sub(/^[^)]*\) /, \"\"); print \$12+\$13 }' /proc/\$1/stat 2>/dev/null; }
      a=\$(j $pid); [ -n \"\$a\" ] || { echo \"$label\"; exit 0; }
      sleep $secs
      b=\$(j $pid); [ -n \"\$b\" ] || { echo \"$label\"; exit 0; }
      echo \"$label \$((b-a)) - 1\"" | tail -1)"
  fi
  # The three shapes the caller can get back, and why each is distinct: `LABEL` alone (a window that
  # could not be read at all -- no numbers), `LABEL <jiffies> - 1` (the compositor only, this window had
  # no app), and `LABEL <jiffies|-> <jiffies|-> 2` (both, each of the two allowed to be `-` on its own).
  d="$(printf '%s' "$res" | awk '{print $2}')"
  da="$(printf '%s' "$res" | awk '{print $3}')"
  mark="$(printf '%s' "$res" | awk '{print $4}')"
  if [ "$mark" = 2 ]; then
    # BOTH columns are printed even when one of the two readings failed. They are two different
    # measurements, and dropping the app's because the compositor's failed is how the app's own number
    # disappears -- the same defect one layer down from the one this window was added for.
    printf '%s %s %s %s %s\n' "$label" "${d:--}" "$(rate_of "$d" "$secs")" "${da:--}" "$(rate_of "$da" "$secs")"
  else
    # An unreadable window stays unreadable: printing "0.0" here would make an ssh failure -- or a
    # /proc/<pid>/stat that could not be read -- look exactly like a process doing nothing, and the
    # verdict would then blame the app for it. A label-only answer reaches the caller as "no number".
    [ -n "$d" ] && [ "$d" != "-" ] || return 0
    printf '%s %s %s\n' "$label" "$d" "$(rate_of "$d" "$secs")"
  fi
}

state="$(read_state)"
A="$(printf '%s\n' "$state" | sed -n 's/^container=//p')"
COMP="$(printf '%s\n' "$state" | sed -n 's/^compositor=//p')"
SHELLPID="$(printf '%s\n' "$state" | sed -n 's/^shell=//p')"
OUT_BEFORE="$(printf '%s\n' "$state" | sed -n 's/^outputs=//p')"
# The socket the session's clients connect to, and how many are on it before this run starts. If the
# shell does not name one the fallback is the launcher's own default, which on this device IS the same
# socket (2026-09-26: the shell's environment says MIR_SERVER_FILE=/run/user/32011/mir_socket, and the
# app's accepted connection appeared on exactly that path).
MIRPATH="$(mir_path "$SHELLPID")"
[ -n "$MIRPATH" ] || MIRPATH="/run/user/32011/mir_socket"
MIR_BEFORE="$(mir_conns "$MIRPATH")"

say "container=$A  compositor=$COMP  shell=$SHELLPID"
say "ActiveOutputs before: ${OUT_BEFORE:-<unreadable>}"
say "session Mir socket: ${MIRPATH:-<unreadable>} -- established connections before the launch: ${MIR_BEFORE:-<unreadable>}"
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
[ "$A_TPS" = "-" ] && A_TPS=""

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
APP_PID=""
case "$LAUNCH" in
*"launched pid "*)
  APP_STARTED=1
  APP_PID="$(printf '%s\n' "$LAUNCH" | sed -n 's/.*launched pid \([0-9][0-9]*\).*/\1/p' | tail -1)"
  ;;
esac
say "   $LAUNCH"

# The app needs a few seconds to load QML and ask for EGL before it has anything to draw; sampling
# immediately would measure the compositor doing nothing and look like a failure.
sleep 6

# --- 4. window B: while the app runs ------------------------------------------------------------

say ""
say "== window B (${SECS}s): while the camera app runs"
# The app is in this window only if step 3 found it; when it did not, the window is the display's and
# says so by leaving the app columns as `-` (never a 0, which would read as "the app burned nothing").
B_RES="$(ticks_window B "$SECS" "$COMP" "$APP_PID")"
say "   $B_RES   (label jiffies ticks_per_second; HZ=100, so 1 tick/s is 1% of one core)"
B_TPS="$(printf '%s' "$B_RES" | awk '{print $3}')"
APP_JIFFIES="$(printf '%s' "$B_RES" | awk '{print $4}')"
APP_TPS="$(printf '%s' "$B_RES" | awk '{print $5}')"
# A `-` is a reading that failed; it becomes "no number" here so that every branch below tests
# emptiness rather than comparing against a dash (and so no code path can divide it).
[ "$B_TPS" = "-" ] && B_TPS=""
[ "$APP_TPS" = "-" ] && APP_TPS=""
if [ -n "$APP_PID" ]; then
  if [ -n "$APP_TPS" ]; then
    say "   the app's own rate: ${APP_TPS}/s  (pid $APP_PID, ${APP_JIFFIES} jiffies over the SAME ${SECS}s as B)"
  else
    say "   the app's own rate: <unreadable> (its /proc/$APP_PID/stat could not be read at both ends of the window)"
  fi
fi

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

# WHERE an app that is not painting is waiting. Read while it is alive (a dead process has no wchan),
# and printed whether or not it painted: when the verdict comes out "the app never painted", this line
# is the answer to the next question, and making the reader run a second command to get it is how that
# question gets left open.
if [ "$APP_ALIVE" = 1 ]; then
  say "   app threads waiting in: $(task_waits "${APP_PID:-0}")"
fi
# The connection count, read while the app is up. Together with the two reads around it, this is what
# says whether the app ever reached the session's Mir server -- a fact the old verdict assumed.
MIR_DURING="$(mir_conns "$MIRPATH")"
say "   session Mir socket: ${MIR_DURING:-<unreadable>} established connection(s) while it ran (before the launch: ${MIR_BEFORE:-<unreadable>})"

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

# The stop is not a formality: it is what makes the NEXT run's premise true. SIGTERM is ignored by this
# app, so the result of the escalation is printed rather than assumed -- `STILL RUNNING` here means the
# next run will refuse, which is the right failure (better than measuring this process twice).
STOP_RESULT="$(stop_app)"
say "   app stopped: $STOP_RESULT"
APP_GONE=0
case "$STOP_RESULT" in stopped\ by\ *) APP_GONE=1 ;; esac
MIR_AFTER="$(mir_conns "$MIRPATH")"
say "   session Mir socket: ${MIR_AFTER:-<unreadable>} established connection(s) after it was stopped"
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
say "   compositor with no client:   ${A_TPS:-<unreadable>}/s   (${A_RES#A })"
say "   compositor with the app:     ${B_TPS:-<unreadable>}/s   (${B_RES#B })"
say "   the app's own burn:          ${APP_TPS:-<unreadable>}/s   (pid ${APP_PID:-<none>}, over the SAME window as B)"
say "   the session Mir socket:      ${MIR_BEFORE:-<unreadable>} before the launch, ${MIR_DURING:-<unreadable>} while it ran, ${MIR_AFTER:-<unreadable>} after it was stopped"
if [ "$APP_GONE" = 0 ]; then
  say "   the stop at the end:          $STOP_RESULT -- the next run will REFUSE to measure until that"
  say "                                 process is gone, which is what keeps a leftover from being measured twice"
fi
# The app's own state comes first, because the two compositor numbers mean different things depending
# on it: if the app never started, or died before window B ended, or never painted, then window B
# measured the display and not the app, and no ratio between the two numbers is about the camera app.
# The states are mutually exclusive and are tested in that order -- "never started" is the strongest
# statement, and printing the "it died" note under it would only be noise (the app that never started is
# certainly not running either). The painting test sits immediately after them and before any
# compositor ratio, because a compositor ratio computed over an app that never drew is a number about
# the wrong subject -- that is the defect this whole block was rewritten for.
if [ "$APP_STARTED" = 0 ]; then
  say "   -> the app NEVER STARTED: the launcher exited immediately after the launch step, so there was"
  say "      no app window to composite and the numbers above are not a measurement of the camera app."
  say "      This is a launcher failure (uid, session bus, EGL, a missing binary), not a compositor one:"
  say "      read the evidence table and the launcher's own lines above before concluding anything."
elif [ "$APP_ALIVE" = 0 ]; then
  say "   -> the app is NOT running at the end of window B ($alive), so the window B number above is"
  say "      about the display, not about the app. Read the app's evidence above and the launcher output."
elif [ -z "${APP_TPS:-}" ]; then
  say "   -> NO VERDICT about the app: window B could not read the app's OWN CPU (its /proc stat was"
  say "      unreadable at one end of the window), so whether the compositor had anything to composite is"
  say "      unknown. A reading that failed is not an app that did nothing: check ssh and run it again."
elif awk -v r="$APP_TPS" 'BEGIN{exit !(r < 1.0)}'; then
  # The app burned essentially nothing -- so the compositor's numbers are not about the app. They still
  # have to be REPORTED, because "the app did nothing" and "the compositor did nothing" are two
  # different facts and only the first is about the app: a busy compositor under an app that never
  # painted is doing work for something else (the shell's own scene, another client), and printing "the
  # app is being composited" from that is how a number about the wrong subject gets published.
  if [ -n "${A_TPS:-}" ] && [ -n "${B_TPS:-}" ] &&
     awk -v a="$A_TPS" -v b="$B_TPS" 'BEGIN{exit !(b >= 4*a && b >= 8)}'; then
    say "   -> the app is NOT PAINTING: it burned ${APP_TPS} ticks/s itself while the compositor was"
    say "      busy (${B_TPS}/s against a ${A_TPS}/s baseline), so that work is NOT the app's. Nothing"
    say "      here says the app is being composited -- the app has drawn nothing to composite. Read the"
    say "      threads line above and the app's own stderr for what it is doing instead."
  else
    say "   -> THE APP NEVER PAINTED: the app itself burned ${APP_TPS} ticks/s over window B -- under 1%"
    say "      of one core across ${SECS} s of a live process ($alive). A client drawing a window cannot"
    say "      do that, so the compositor's number above is a measurement of the DISPLAY, not of the app:"
    say "      there was nothing to composite. The verdict here used to read 'the app is not being"
    say "      composited, whatever it reports' -- true, and taken as a statement about the shell, when"
    say "      the question it looks like it answers (is the shell stacking the app's surface?) had not"
    say "      been asked. Read the threads line above for where it is waiting, the Mir line for whether"
    say "      it ever reached the shell's server, and the app's own stderr for what it printed."
    if [ -z "${A_TPS:-}" ] || [ -z "${B_TPS:-}" ]; then
      say "      (The compositor's own windows could not both be read: A='${A_TPS:-}' B='${B_TPS:-}'.)"
    fi
  fi
elif awk -v r="$APP_TPS" 'BEGIN{exit !(r < 5.0)}'; then
  say "   -> inconclusive: the app's own rate is ${APP_TPS}/s -- above the 1/s 'it did nothing' line and"
  say "      under the 5/s this instrument treats as painting, so neither story is established. Read the"
  say "      threads line, the app's evidence and the grab before concluding anything."
elif [ -z "${A_TPS:-}" ] || [ -z "${B_TPS:-}" ]; then
  # Both window numbers are about the compositor, and one of them is missing: the app's own reading
  # still stands on its own (it is a different measurement), but there is nothing to compare it with.
  say "   -> the app IS painting (${APP_TPS}/s) but one or both of the compositor's windows could not be"
  say "      read (A='${A_TPS:-}' B='${B_TPS:-}'), so there is nothing to compare it against. Check that"
  say "      the compositor pid was found and that ssh returned: a failed measurement of the compositor"
  say "      is not a measurement of the app."
else
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
    say "      is 20-50/s against a 1.2/s idle baseline (docs 68 section 5), and the app is painting too"
    say "      (${APP_TPS}/s). Combined with the grab, that is 'the app's window is being composited'."
    say "      It is what a human should then confirm by looking at the phone (--keep-display)."
    ;;
  none)
    say "   -> NO extra compositor work while the app was painting (${APP_TPS}/s): the compositor is not"
    say "      compositing it. The app is drawing and the shell is not putting its surface in the scene --"
    say "      a stacking/visibility problem in the shell, NOT an app that did nothing (the reading that"
    say "      used to be printed here said the opposite, from a measurement of the compositor alone)."
    ;;
  *)
    say "   -> inconclusive: more work than the baseline but well under the 20-50/s band, from an app"
    say "      that is itself painting at ${APP_TPS}/s. Read the app's evidence above and the grab before"
    say "      concluding anything."
    ;;
  esac
fi

say ""
say "== what this does NOT prove"
say "   * that the picture is correct, or that the preview has frames in it -- only that the compositor"
say "     is drawing for the app and what the grab looks like"
say "   * anything about the camera pipeline itself: 'Added camera 0/1' is enumeration, not frames"
say "     (docs 80 section 6)"
say "   * that the app would behave the same when launched by lomiri-app-launch rather than by the"
say "     launcher script"
say "   * that the 1/s and 5/s lines the app's own rate is read against are MEASURED bands. They are"
say "     this instrument's thresholds for 'the app did nothing' and 'the app is painting' -- a client"
say "     known to be painting (test_camera, docs 77) has never been put through this same window, so"
say "     'the app burned 0.1/s' is a fact about the app and '5/s means painting' is a design choice"
say "   * anything about the connection itself, beyond the pairing: the count is of sockets on the"
say "     session's Mir path, which are the SHELL's accepted ones. A client's own socket carries no path"
say "     in /proc/net/unix (measured 2026-09-26: the app's 14 socket fds are all '03' with an empty"
say "     name), so this number cannot name the client -- it moves up when one connects and back down"
say "     when it exits, and it says nothing about whether a surface was mapped or a frame ever crossed it"
say ""
say "artifacts: $OUTDIR  (app.out, app.err${SHOT_PNG:+, shot-during-app.png})"
