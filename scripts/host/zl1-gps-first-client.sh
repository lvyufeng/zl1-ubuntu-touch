#!/usr/bin/env bash
# Make the GPS door's first permitted client actually ask for a position, and report which gate answered.
#
# Why this exists (docs 105, and the shape is the camera test one level over):
#
#   Docs 93 settled that the GPS hardware entry points (`u_hardware_gps_new`/`u_hardware_gps_start`) are
#   reached only from a *virtual* HAL call inside `StartPositionUpdates`, so the daemon's own startup
#   touches no hardware and nothing has to be broken for them never to have run. Docs 105 found who can
#   knock: the PREINSTALLED weather app (click `weather.ubports`, app id `weather.ubports_weather_6.2.0`)
#   contains `import QtPositioning` and a `PositionSource { active: settings.detectCurrentLocation }`,
#   and its own AppArmor profile carries the `location` policy group -- so the system-supported path needs
#   NO bypass, unlike `device/zl1-location-request.sh --enable-testing`, which installs a real permission
#   bypass. And docs 105 left the device-side half as a command SNIPPET in a document.
#
#   That last part is the reason this script exists rather than a paragraph: a run that has never happened,
#   spelled out in prose, is the exact shape this repo keeps converting into an instrument. Docs 105
#   section 6 is also explicit that the weather app has NEVER been started on this device.
#
# What it does, in order:
#   0. guard on the device-tree model (this is not a generic script)
#   1. read the state read-only: the container, the shell, the three gates (via the device-side read-only
#      probe), which trust-stored agent is the one that runs, the app's own setting, and which app is running
#   2. turn the display on -- a person has to tap one toggle, and the screen and touch are confirmed working
#   3. mark the journal by LINE OFFSET, then launch the weather app the camera round's launcher way,
#      through its migrate script first (the desktop Exec is `lomiri-weather-app-migrate.py`, and running
#      the binary directly skips its first-run setup)
#   4. wait --seconds (default 120) while the person turns on "detect current location" in the app
#   5. read the door again: the NEW journal lines only, the probe's status, the agent unit, the app's
#      own stderr -- and the container's side of the QMI client
#   6. stop the app, restore the display
#   7. a verdict that names WHICH of the three gates answered, or says the question went unanswered
#
# The three gates (docs 93 section 3, docs 112), in the order they are checked:
#   1. the daemon's own testing switch  -- an env var the wrapper sets from `getprop custom.location.testing`,
#      which the v63 boot image's `getprop` STUB makes unreachable (docs 117): always off here
#   2. the caller's AppArmor profile being non-empty -- the reason a root qmlscene client is rejected and
#      the weather app is not
#   3. the trust-store agent's answer -- every exception in it is swallowed into `rejected`, so the client
#      only ever sees `Error.CreatingSession`, which is why this script reads the DAEMON's journal
#
# Usage: zl1-gps-first-client.sh [--seconds N] [--keep-app] [--keep-display] [--outdir DIR] [--quiet]
#   --seconds N      how long the app is left up for the person to tap the toggle (default 120)
#   --keep-app       leave the app running at the end (for a human who wants to keep looking)
#   --keep-display   do not restore the display at the end
#   --outdir DIR     where to keep the evidence (default /tmp/zl1-gps-first-client-<ts>)
#   --quiet          print the verdict lines and the console prompt, not the evidence tables
#
# What this NEVER does: install anything, write a partition, enable the permission bypass, write the app's
# settings file, restart the location service, or reboot. The one setting that has to change is changed by
# a PERSON in the app's own UI -- not by writing into the app's Qt LocalStorage database, because docs 105
# section 6 records that the exact read location of that key was INFERRED rather than measured, and a
# guessed write into a live sqlite settings store is how an app loses its settings. The script reads the
# setting if it can and says so if it cannot (`cannot read` and `false` are different answers).

set -uo pipefail

HOST="${ZL1_HOST:-root@10.15.19.82}"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10)
SECS=120
KEEP_APP=0
KEEP_DISPLAY=0
QUIET=0
OUTDIR=""

APP_DIR=/usr/share/click/preinstalled/weather.ubports/6.2.0
APP_BIN=$APP_DIR/lomiri-weather-app
APP_ID=weather.ubports_weather_6.2.0
MIGRATE=/usr/bin/lomiri-weather-app-migrate.py
# The app's LocalStorage database, whose path docs 105 section 3 derived from the migrate script's own
# md5-of-the-application-name rule. READ ONLY, and only to report whether the toggle is already on.
SET_DIR=/home/phablet/.local/share/weather.ubports/Databases
SET_DB=0404df7c9de73501aad24e64d39120e1.sqlite

while [ $# -gt 0 ]; do
  case "$1" in
  --seconds) SECS="${2?--seconds needs a number}"; shift 2 ;;
  --keep-app) KEEP_APP=1; shift ;;
  --keep-display) KEEP_DISPLAY=1; shift ;;
  --outdir) OUTDIR="${2?--outdir needs a directory}"; shift 2 ;;
  --quiet) QUIET=1; shift ;;
  --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0" ; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

case "$SECS" in ''|*[!0-9]*) echo "error: --seconds needs a whole number, got '$SECS'" >&2; exit 2 ;; esac
# The app is launched under `timeout`, and a person has to find one toggle inside that window. Below a
# minute the run reliably measures "nobody had time", which is not a fact about the GPS pipeline.
if [ "$SECS" -lt 30 ]; then
  echo "error: --seconds $SECS is too short -- a PERSON has to be able to read the prompt and find the" >&2
  echo "       toggle in the app. The default is 120; the floor is 30." >&2
  exit 2
fi

[ -n "$OUTDIR" ] || OUTDIR="/tmp/zl1-gps-first-client-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUTDIR" || { echo "cannot create $OUTDIR" >&2; exit 2; }

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"

say()  { [ "$QUIET" = 1 ] && [ -n "${1:-}" ] && return 0; printf '%s\n' "$*"; }
# The console prompt is the one thing --quiet must not silence: this run does not work unless a person
# reads it and acts, and a silent "waiting 120 s" is indistinguishable from a hung script.
prompt() { printf '%s\n' "$*" >&2; }
vout() { printf '%s\n' "$*"; }

ssh_d() { timeout "$((SECS + 240))" ssh "${SSH_OPTS[@]}" "$HOST" "$@"; }
scp_d() { scp -q "${SSH_OPTS[@]}" "$1" "$HOST:$2"; }

# --- 0. guard: this must be the zl1 ---------------------------------------------------------------
# Seen through ssh, so there is no "wrong device on the bus" question here (the serial rule matters for
# anything that looks the phone up in /sys). What this catches is running the whole protocol against the
# Xiaomi, or against a zl1 that has booted something else.
model="$(ssh_d "tr -d '\\0' < /proc/device-tree/model 2>/dev/null" || true)"
case "$model" in
*"MSM 8996pro + PMI8996 LE_ZL1"*) ;;
*) echo "error: this is not the zl1: device-tree model is \"$model\"" >&2; exit 1 ;;
esac

say "zl1 GPS first client :: the weather app asks, and we watch which gate answers"
say "  host:   $HOST"
say "  outdir: $OUTDIR"
say ""

# Stage both device-side pieces every time: a stale copy would silently run the old logic.
scp_d "$repo/scripts/device/zl1-camapp-launch.py" /tmp/zl1-camapp-launch.py ||
  { echo "error: could not copy zl1-camapp-launch.py to the device" >&2; exit 1; }
scp_d "$repo/scripts/device/zl1-location-request.sh" /tmp/zl1-location-request.sh ||
  { echo "error: could not copy zl1-location-request.sh to the device" >&2; exit 1; }

# --- 1. the state, read-only ----------------------------------------------------------------------
# One round trip. Every read here distinguishes "the command could not run" from "it answered nothing"
# (docs 117): the two look identical in a captured-empty string, and an instrument that reports the first
# as the second is the defect this repo has now written down five times.
read_state() {
  ssh_d 'A=$(lxc-info -n android -pH 2>/dev/null | head -1)
    S=$(pgrep -x lomiri | head -1)
    echo "container=${A:-COULD-NOT-RUN}"
    echo "shell=${S:-COULD-NOT-RUN}"
    echo "outputs=$(busctl --system get-property com.lomiri.SystemCompositor.Display \
        /com/lomiri/SystemCompositor/Display com.lomiri.SystemCompositor.Display ActiveOutputs 2>/dev/null)"
    # The app, by walking /proc: pgrep -f is unreliable on this device (docs 68 section 5). Matched on the
    # app DIRECTORY as well as the binary, because the desktop Exec runs the migrate wrapper first and a
    # failed migrate leaves the pid carrying the wrapper cmdline.
    found=
    for p in /proc/[0-9]*/cmdline; do
      c=$(tr "\0" " " < "$p" 2>/dev/null)
      case "$c" in *'"$APP_DIR"'*|*lomiri-weather-app*) found=${p%/cmdline}; break ;; esac
    done
    echo "app=${found:-not-running}"
    # Which trust-stored agent is the one that runs: two mutually exclusive units, conditions that are
    # negations of each other (docs 105 section 4). The difference is only WHO raises the prompt, and a
    # prompt nobody sees is one of the ways gate 3 answers `rejected`.
    echo "agents=$(systemctl --user list-units --no-legend "lomiri-location-service-trust-stored*" 2>/dev/null \
        | awk "{print \$1, \$4}" | tr "\n" ";")"
    # The app`s own toggle, READ ONLY. `sqlite3` may not exist on this device and the database is a live
    # Qt LocalStorage store; the honest output has three values, and "cannot-read" is one of them.
    if [ -r "'"$SET_DIR/$SET_DB"'" ] && command -v sqlite3 >/dev/null 2>&1; then
      v=$(sqlite3 "'"$SET_DIR/$SET_DB"'" \
          "select value from ItemTable where key like \"%detectCurrentLocation%\";" 2>/dev/null | head -1)
      echo "setting=${v:-no-row}"
    elif [ -r "'"$SET_DIR/$SET_DB"'" ]; then
      echo "setting=cannot-read-no-sqlite3"
    else
      echo "setting=cannot-read-no-database"
    fi'
}

state="$(read_state)"
field() { printf '%s\n' "$state" | sed -n "s/^$1=//p"; }
A="$(field container)"
SHELLPID="$(field shell)"
OUT_BEFORE="$(field outputs)"
APP_BEFORE="$(field app)"
AGENTS="$(field agents)"
SETTING="$(field setting)"

say "== the device, before anything"
say "   container:      $A"
say "   shell pid:      $SHELLPID"
say "   display:        ${OUT_BEFORE:-<unreadable>}"
say "   weather app:    $APP_BEFORE"
say "   trust agents:   ${AGENTS:-<nothing listed>}"
say "   app's toggle:   $SETTING   <-- read-only; 'cannot-read-*' is NOT 'false'"
say ""

for pair in "container:$A" "shell:$SHELLPID"; do
  case "$pair" in *:COULD-NOT-RUN)
    echo "error: could not read the ${pair%%:*} -- the device is up but this is not a running UT session." >&2
    echo "       Nothing was launched. (EDL, a boot still in progress and a dead shell all look like this" >&2
    echo "       from here: run scripts/host/zl1-health-check.sh.)" >&2
    exit 1 ;;
  esac
done

# --- the read-only gate probe, run device-side -----------------------------------------------------
# `--status` reports which of the three gates is closed. Its own zero-vs-could-not-run distinction is
# kept: an unreadable probe is reported as UNANSWERED and never as "the door is shut".
probe_status() {
  ssh_d 'if [ -r /tmp/zl1-location-request.sh ]; then
      sh /tmp/zl1-location-request.sh --status 2>&1; echo "PROBE-RC=$?"
    else
      echo "PROBE-COULD-NOT-RUN: /tmp/zl1-location-request.sh is not on the device"
    fi' || echo "PROBE-COULD-NOT-RUN: ssh returned non-zero"
}
say "== the three gates, read-only (device/zl1-location-request.sh --status)"
# ONE call, read twice. The first version ran the probe once for the archive and once for the screen, so
# the two could disagree -- and the reader would have no way to tell which of them the archive holds.
PROBE_BEFORE="$(probe_status)"
printf '%s\n' "$PROBE_BEFORE" > "$OUTDIR/probe-before.txt"
printf '%s\n' "$PROBE_BEFORE" | tail -3 | sed 's/^/   /'
say ""

# --- 2. the display on, because a person has to use the phone ---------------------------------------
restore_display() {
  [ "$KEEP_DISPLAY" = 1 ] && return 0
  case "$OUT_BEFORE" in
  *"1 "*) ssh_d 'busctl --system call com.lomiri.SystemCompositor.Display \
      /com/lomiri/SystemCompositor/Display com.lomiri.SystemCompositor.Display TurnOn s "zl1-gps-first-client"' >/dev/null 2>&1 ;;
  *) ssh_d 'busctl --system call com.lomiri.SystemCompositor.Display \
      /com/lomiri/SystemCompositor/Display com.lomiri.SystemCompositor.Display TurnOff s "zl1-gps-first-client"' >/dev/null 2>&1 ;;
  esac
}
say "== turning the display on (the toggle below is tapped by a person, not written by this script)"
ssh_d 'busctl --system call com.lomiri.SystemCompositor.Display \
    /com/lomiri/SystemCompositor/Display com.lomiri.SystemCompositor.Display TurnOn s "zl1-gps-first-client"' \
  >/dev/null 2>&1
sleep 3
say "   display now: $(ssh_d 'busctl --system get-property com.lomiri.SystemCompositor.Display \
    /com/lomiri/SystemCompositor/Display com.lomiri.SystemCompositor.Display ActiveOutputs 2>/dev/null')"
say ""

# --- 3. mark the journal, then launch ---------------------------------------------------------------
# BY LINE OFFSET, not by timestamp: this device's wall clock is wrong and `journalctl -n`'s ordering lies
# with it (docs 64, and the same rule docs 69/91 apply). A count taken immediately before the launch and
# subtracted after it is a fact about this boot and does not involve the clock at all.
JL="lomiri-location-service"
# Prints a COUNT, or the literal COULD-NOT-RUN. The two must not collapse into one number (docs 117): a
# journalctl that cannot run prints 0 lines to stdout, which is exactly what a genuinely empty journal
# prints, and the verdict below would then say "the app asked nothing" about a journal nobody read.
# ONE journalctl call, not two. The two-call form (one to prove it runs, one to count) is a real defect
# and not just waste: every call is a reading, and a reading that happens to land on a rotating journal
# makes the mark itself unstable -- the offline harness models exactly that, and with two calls per mark
# the shrink it injected was reached twice inside a single mark and cancelled out.
jlines() {
  ssh_d "if journalctl -b -u $JL --no-pager -o cat > /tmp/zl1-jl.txt 2>/dev/null; then
      wc -l < /tmp/zl1-jl.txt
    else
      echo COULD-NOT-RUN
    fi" 2>/dev/null | tr -d ' \r\n'
}
BEFORE_N="$(jlines)"
case "$BEFORE_N" in ''|*[!0-9]*) say "   WARNING: the location service's journal could not be read at all, so the door reading" >&2
  say "            below cannot be made. The verdict will say UNANSWERED, not 'the app asked nothing'." >&2 ;;
esac

say "== launching $APP_ID through its migrate script, as the session's own uid"
# The desktop Exec is `lomiri-weather-app-migrate.py lomiri-weather-app`, and the migrate script
# `os.execvp`s the real binary -- so passing the WRAPPER as the binary is what makes the app start the way
# a launcher would start it. Docs 105 section 6: running the binary directly skips it, and the first run
# then misses whatever the migration sets up.
LAUNCH="$(ssh_d "rm -f /tmp/zl1-weather.out /tmp/zl1-weather.err
  setsid nohup nsenter -t $A -p -- timeout $((SECS + 120)) env ZL1_AS_UID=32011 \
    ZL1_PRELOAD_EXTRA='/userdata/zl1-hybris/lib/libcfi-shadow-init.so /userdata/zl1-hybris/lib/crash-dump.so' \
    python3 /tmp/zl1-camapp-launch.py $MIGRATE $APP_ID $APP_DIR $SHELLPID lomiri-weather-app \
    > /tmp/zl1-weather.out 2> /tmp/zl1-weather.err < /dev/null &
  sleep 4
  found=
  for p in /proc/[0-9]*/cmdline; do
    c=\$(tr '\0' ' ' < \"\$p\" 2>/dev/null)
    case \"\$c\" in *'$APP_DIR'*|*lomiri-weather-app*) found=\${p%/cmdline}; break ;; esac
  done
  [ -n \"\$found\" ] && echo \"launched pid \${found#/proc/}\" || echo 'NOT launched (the launcher exited immediately)'")"
APP_STARTED=0
case "$LAUNCH" in *"launched pid "*) APP_STARTED=1 ;; esac
say "   $LAUNCH"
say ""

# --- 4. the wait, and what the person has to do -----------------------------------------------------
say "== the hand-off"
if [ "$APP_STARTED" = 1 ]; then
  prompt "   ----------------------------------------------------------------"
  prompt "   ON THE PHONE: the weather app should be on screen. Open its"
  prompt "   settings and turn ON \"detect current location\"."
  prompt "   Then leave the phone alone. Waiting ${SECS}s ..."
  prompt "   ----------------------------------------------------------------"
else
  prompt "   The app did NOT start, so there is nothing to tap. The ${SECS}s wait is skipped;"
  prompt "   read /tmp/zl1-weather.err in the archive before concluding anything about the door."
  SECS=0
fi

# Background + wait, so a signal is honoured promptly rather than after the whole wait (docs 118: bash
# defers a trap until the foreground command returns -- measured at +20.0 s foreground vs +2.0 s here).
[ "$SECS" -gt 0 ] && { sleep "$SECS" & wait $!; }

# --- 5. read the door ------------------------------------------------------------------------------
say ""
say "== the door, after the request"
AFTER_N="$(jlines)"
# The mark is only a mark if both readings are numbers AND the journal did not shrink between them. A
# journal that lost lines would make `tail -n +N` return lines from BEFORE the launch -- i.e. it could
# hand the verdict an old `CreatingSession` and report "the door opened" about a run that asked nothing.
# So when the mark is not trustworthy the door is reported UNANSWERED, which is the honest answer.
MARK_OK=1
case "$BEFORE_N" in ''|*[!0-9]*) MARK_OK=0 ;; esac
case "$AFTER_N" in ''|*[!0-9]*) MARK_OK=0 ;; esac
if [ "$MARK_OK" = 1 ] && [ "$AFTER_N" -lt "$BEFORE_N" ]; then
  MARK_OK=0
  say "   WARNING: the journal SHRANK ($BEFORE_N -> $AFTER_N lines). The line offset is not a valid mark"
  say "            for this run, so the door cannot be read from it; the dump below is the tail only."
fi
newlines() {
  if [ "$MARK_OK" = 1 ]; then
    ssh_d "journalctl -b -u $JL --no-pager -o cat 2>/dev/null | tail -n +$((BEFORE_N + 1))"
  else
    ssh_d "journalctl -b -u $JL --no-pager -o cat 2>/dev/null | tail -40"
  fi
}
newlines > "$OUTDIR/journal-delta.txt" 2>&1
NEW_N="$(grep -ac . "$OUTDIR/journal-delta.txt" 2>/dev/null)"
say "   new journal lines from $JL: ${NEW_N:-0}   (saved to journal-delta.txt)"

# The evidence each gate leaves, counted in ONE stream at a time and with its source named (docs 102/103:
# a count read from a file that cannot contain the string reads as "it never happened").
count_in() { local n=; [ -r "$1" ] && n="$(grep -ac -- "$2" "$1" 2>/dev/null)"; printf '%s\n' "${n:-0}"; }
say ""
# INFORMATION, not a licence. The positive licence for "the door opened" is `locClientOpen` and it is
# read from the container (below), because that string was MEASURED on this device (docs 82) while the
# daemon's own wording for a session it accepted has never been. Putting a guessed success string in a
# table like this one and then letting the verdict read the table is how an instrument comes to report a
# string it has never seen -- the mistake docs 102/103 are about, one layer up.
say "   the daemon's own words, as a count (informational -- see the licence below):"
for pat in 'Client lacks permissions' 'Error[. ]+[Cc]reating[Ss]ession' \
           'start_position_updates' 'permission' 'session' 'position'; do
  printf '   %-28s %4s\n' "$pat" "$(count_in "$OUTDIR/journal-delta.txt" "$pat")"
done
say ""
say "   the container's side of the QMI client (logcat, the vendor HAL):"
# The same could-not-run distinction as the journal, for the same reason: an empty logcat file would
# otherwise be read as "the client never opened" when what happened is that logcat never ran.
ssh_d 'A=$(lxc-info -n android -pH 2>/dev/null | head -1)
  if [ -z "$A" ]; then echo "LOGCAT-COULD-NOT-RUN: no android container"; exit 0; fi
  nsenter -t "$A" -p -m -- /system/bin/logcat -d -v brief > /tmp/zl1-logcat.txt 2>/dev/null
  rc=$?
  if [ "$rc" != 0 ]; then echo "LOGCAT-COULD-NOT-RUN: logcat exited $rc"; exit 0; fi
  grep -aiE "locClient|gps|location" /tmp/zl1-logcat.txt | tail -12' \
  > "$OUTDIR/logcat.txt" 2>&1
LC_RAN=1
case "$(cat "$OUTDIR/logcat.txt" 2>/dev/null)" in *LOGCAT-COULD-NOT-RUN*) LC_RAN=0 ;; esac
LC_N="$(count_in "$OUTDIR/logcat.txt" 'locClientOpen')"
if [ "$LC_RAN" = 0 ]; then
  say "   $(grep -a 'LOGCAT-COULD-NOT-RUN' "$OUTDIR/logcat.txt" | head -1)"
  say "   -> the count below is 0 because IT COULD NOT RUN, not because the client stayed shut."
else
  say "   locClientOpen lines: $LC_N   <-- THE LICENCE for 'the door opened'. docs 82 measured this"
  say "                     string on this device; it proves the QMI client OPENED, and its failure is"
  say "                     non-fatal -- what had never happened was a client asking at all"
  [ "$LC_N" -gt 0 ] && grep -a 'locClientOpen' "$OUTDIR/logcat.txt" | head -2 | sed 's/^/   | /'
fi

say ""
say "   gate 3's agent, and the app's own words:"
ssh_d 'systemctl --user status "lomiri-location-service-trust-stored*.service" 2>&1 | head -20' \
  > "$OUTDIR/agent.txt" 2>&1
sed -n '1,6p' "$OUTDIR/agent.txt" | sed 's/^/   | /'
scp -q "${SSH_OPTS[@]}" "$HOST:/tmp/zl1-weather.err" "$OUTDIR/app.err" 2>/dev/null || true
scp -q "${SSH_OPTS[@]}" "$HOST:/tmp/zl1-weather.out" "$OUTDIR/app.out" 2>/dev/null || true
[ -f "$OUTDIR/app.err" ] || : > "$OUTDIR/app.err"
[ -f "$OUTDIR/app.out" ] || : > "$OUTDIR/app.out"
for f in "$OUTDIR/app.err" "$OUTDIR/app.out"; do
  printf '   %-24s %4s ASSERT  %4s caught-signal\n' "$(basename "$f")" \
    "$(count_in "$f" 'ASSERT')" "$(count_in "$f" 'caught signal')"
done

probe_status > "$OUTDIR/probe-after.txt" 2>&1
say ""
say "   the three gates, read-only, AFTER the request (probe-after.txt):"
grep -a 'gate\|Gate\|permission\|trust\|testing' "$OUTDIR/probe-after.txt" 2>/dev/null | head -8 | sed 's/^/   | /'

# --- 6. stop the app, restore the display ----------------------------------------------------------
if [ "$KEEP_APP" = 0 ]; then
  ssh_d "for p in /proc/[0-9]*/cmdline; do
      c=\$(tr '\0' ' ' < \"\$p\" 2>/dev/null)
      case \"\$c\" in *'$APP_DIR'*|*lomiri-weather-app*) kill \${p%/cmdline} 2>/dev/null ;; esac
    done
    sleep 1
    echo stopped" >/dev/null 2>&1
  say ""
  say "== the app was stopped (--keep-app leaves it running)"
fi
trap restore_display EXIT INT TERM
restore_display
say "   display: $(ssh_d 'busctl --system get-property com.lomiri.SystemCompositor.Display \
    /com/lomiri/SystemCompositor/Display com.lomiri.SystemCompositor.Display ActiveOutputs 2>/dev/null')"

# --- 7. the verdict --------------------------------------------------------------------------------
say ""
# vout, not say: the verdict is what --quiet is FOR. It used to go through say(), so --quiet printed the
# verdict lines with no header -- which is also what left the harness unable to find the block at all.
vout "== verdict"
# The app's own state decides what the evidence means, and it is tested FIRST: if it never started, then
# every zero above is about a protocol that was never run, and no reading of them is about the GPS
# pipeline. Same rule as the camera instrument (docs 104), and the reason it exists there.
REJ="$(count_in "$OUTDIR/journal-delta.txt" 'Client lacks permissions')"
# The order is the order of authority, and the first two branches exist so that a reading that COULD NOT
# BE TAKEN is never reported as a reading that came back negative (docs 117). "The app never started"
# comes first because it invalidates the other three: every zero under it is about a protocol nobody ran.
if [ "$APP_STARTED" = 0 ]; then
  vout "   -> THE APP NEVER STARTED. Nothing was asked, so nothing here is a reading about the door."
  vout "      This is a launcher failure (uid, session bus, the migrate wrapper, EGL): read app.err."
  vout "      Do not read the zero counts above as 'no client asked' -- the client never ran."
elif [ "$MARK_OK" = 0 ]; then
  vout "   -> UNANSWERED. The journal's line mark for this run is not trustworthy (the journal could not"
  vout "      be read, or it shrank), so there is no evidence either way about the door. This is NOT"
  vout "      'the door is shut' (docs 117: a command that could not run is not a zero), and it is not"
  vout "      'the app asked nothing' either. Re-run once the journal is readable."
elif [ "$REJ" -gt 0 ]; then
  vout "   -> A GATE SAID NO, and it is gate 2 or gate 3: the daemon logged"
  vout "      'Client lacks permissions to access the service with the given criteria'. The client only"
  vout "      ever sees Error.CreatingSession, so read the agent's unit in agent.txt: if no agent is"
  vout "      active, or it raised a prompt nobody could see, that is gate 3 answering 'rejected'."
  vout "      The app's AppArmor profile carries the 'location' group, so gate 2 should not be the one."
elif [ "$LC_N" -gt 0 ]; then
  vout "   -> THE DOOR OPENED. The container logged locClientOpen, i.e. the QMI client was opened -- and"
  vout "      that code is reachable only from u_hardware_gps_new/u_hardware_gps_start (docs 93), which"
  vout "      run only inside a session's start_position_updates. So a client asked, and the door moved."
  vout "      This is the FIRST time on this port that anything asked the GPS for a position."
  vout "      What it does NOT yet prove: that a FIX came out. A position needs satellites, and the"
  vout "      next reading is whether the HAL reports one -- see the journal and logcat in the archive."
elif [ "$NEW_N" -gt 0 ]; then
  vout "   -> SOMETHING WAS LOGGED but nothing about a session or a permission: read journal-delta.txt."
  vout "      The service noticed the app without creating a session for it."
else
  vout "   -> THE APP ASKED NOTHING (the journal gained no lines at all). The most likely reason is the"
  vout "      toggle: 'detect current location' was still off, or the app was not actually on screen."
  vout "      The app's toggle read at the start was: $SETTING"
  vout "      That read is only evidence when it says true or false -- 'cannot-read-*' means the script"
  vout "      could not look, which is not the same answer."
  [ "$LC_RAN" = 0 ] && vout "      And note the logcat line above: that half could not be read at all."
fi

say ""
say "== what this does NOT prove"
say "   * that a position fix was obtained -- an opened door is not a fix (docs 82/93)"
say "   * that the toggle was actually on: this script does not read the app's UI state, and the"
say "     settings read above is best-effort and read-only (docs 105 section 6: that key's exact"
say "     location was inferred, not measured)"
say "   * that the same thing happens when the app is started by lomiri-app-launch rather than by"
say "     the launcher script"
say "   * anything about the hardware itself. Every earlier reading said the GPS half was never ASKED;"
say "     this run is the asking. Whether the answer comes back is the next question."
say ""
say "artifacts: $OUTDIR"
