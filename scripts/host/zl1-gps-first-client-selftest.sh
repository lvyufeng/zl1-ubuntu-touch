#!/usr/bin/env bash
# zl1 GPS first client -- offline self-test. Host-side, touches no device, needs no phone.
#
# Why this exists. `scripts/host/zl1-gps-first-client.sh` is the first instrument that ATTEMPTS the thing
# docs 93 and 105 established was never attempted: making the GPS door's first permitted client (the
# preinstalled weather app) actually ask for a position. Docs 105 left that as a command snippet in a
# document and recorded that the app has never been started on this device, so the script and its
# verification are written together -- and the verification is what decides whether the script's verdicts
# mean anything.
#
# What it holds the script to:
#
#   1. A READING THAT COULD NOT BE TAKEN IS NOT A NEGATIVE ONE (docs 117, and this is the whole reason
#      the harness has a journal-unreadable and a journal-shrank scenario): an unreadable `journalctl`
#      prints 0 lines, which is exactly what an empty journal prints, and the verdict would then say "the
#      app asked nothing" about a journal nobody read.
#   2. THE APP'S OWN STATE COMES FIRST. If the launcher failed, every zero below it is about a protocol
#      nobody ran -- the defect docs 104 found in the camera instrument, in the same shape.
#   3. THE FIRST CLIENT IS THE MIGRATE WRAPPER, not the bare binary (docs 105 section 6): the desktop
#      Exec is `lomiri-weather-app-migrate.py`, and running the binary directly skips its first-run setup.
#      Asserted on the command line that was actually sent, not on a comment.
#   4. THE SCRIPT READS THE APP'S TOGGLE AND DOES NOT WRITE IT, and its three answers are distinct: true,
#      false, and the two flavours of "could not look". Docs 105 section 6 records that the key's exact
#      location was INFERRED rather than measured, which is why there is no write mode to test.
#   5. IT PUTS THE DEVICE BACK: the app is stopped and the display returns to what the run found, unless
#      --keep-app/--keep-display say otherwise.
#
# How it works: **the transport stub IS the device.** `ssh` and `scp` strip their options and run the
# remote command locally against a fake root, with the device's tools (lxc-info, busctl, pgrep, nsenter,
# journalctl, systemctl, sqlite3) stubbed. The journal is a FILE whose length the fixture controls, which
# is what lets a scenario be "the journal could not be read" or "the journal shrank between the two
# readings" -- the two states that must not collapse into "nothing was logged".
#
# Usage: zl1-gps-first-client-selftest.sh [--keep]
#   --keep   leave the fake device, the stubs and the rewritten script for inspection
#
# Exit codes: 0 every scenario behaved; 1 something did not; 2 the harness could not set up.

set -uo pipefail

KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
  --keep) KEEP=1; shift ;;
  --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0" ; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/zl1-gps-first-client.sh"
LAUNCHER="$HERE/../device/zl1-camapp-launch.py"
PROBE="$HERE/../device/zl1-location-request.sh"
[ -r "$SRC" ] || { echo "cannot read $SRC" >&2; exit 2; }
[ -r "$LAUNCHER" ] || { echo "cannot read $LAUNCHER" >&2; exit 2; }
[ -r "$PROBE" ] || { echo "cannot read $PROBE" >&2; exit 2; }

W="${TMPDIR:-/tmp}/zl1-gps-first-client-selftest"
REPO="$W/repo"
FR="$W/dev"
STUB="$W/stub"
ACT="$W/actions"
rm -rf "$W"
mkdir -p "$REPO/scripts/host" "$REPO/scripts/device" "$STUB" \
         "$FR/proc/device-tree" "$FR/tmp" "$FR/userdata/zl1-hybris/lib" \
         "$FR/usr/share/click/preinstalled/weather.ubports/6.2.0" \
         "$FR/home/phablet/.local/share/weather.ubports/Databases" || exit 2

# --- the script under test, rewritten into the fake device ---------------------------------------
#
# Only DEVICE paths are rewritten. `$W/repo` mirrors the repo layout because the script derives `repo`
# from its own location and then reaches for two siblings (the launcher and the probe it scps).
#
# The `/tmp/zl1-...` rewrites use a LITERAL dot, which is what keeps `zl1-camapp-launch.py` (a `-`) from
# being caught by the `zl1-weather.` rule -- every one of these six patterns was checked for overlap.
#
# The kill rewrite is single-quoted, and not for style: the line it targets sits INSIDE a double-quoted
# ssh command, so the file really contains `\${p%/cmdline}` with a backslash -- and in a double-quoted sed
# script the shell eats that backslash, leaving a pattern that matches nothing. Silently: the sed exits 0,
# and the only symptom would be a REAL kill signalling a host process.
sed -e "s#/proc/#$FR/proc/#g" \
    -e "s#/tmp/zl1-camapp-launch\.py#$FR/tmp/zl1-camapp-launch.py#g" \
    -e "s#/tmp/zl1-location-request\.sh#$FR/tmp/zl1-location-request.sh#g" \
    -e "s#/tmp/zl1-weather\.#$FR/tmp/zl1-weather.#g" \
    -e "s#/tmp/zl1-logcat\.txt#$FR/tmp/zl1-logcat.txt#g" \
    -e "s#/tmp/zl1-jl\.txt#$FR/tmp/zl1-jl.txt#g" \
    -e "s#/userdata/zl1-hybris/#$FR/userdata/zl1-hybris/#g" \
    -e "s#/usr/share/click/preinstalled/weather.ubports#$FR/usr/share/click/preinstalled/weather.ubports#g" \
    -e "s#/home/phablet/.local/share/weather.ubports#$FR/home/phablet/.local/share/weather.ubports#g" \
    -e 's#\*) kill \\${p%/cmdline}#*) \\"'"$STUB"'/kill\\" \\${p%/cmdline}#' \
    "$SRC" > "$REPO/scripts/host/zl1-gps-first-client.sh"
cp "$LAUNCHER" "$REPO/scripts/device/zl1-camapp-launch.py"
# The device-side probe is staged by the script under test and then RUN by it (`--status`), and the
# transport runs it locally -- so its own `/proc/device-tree/compatible` guard would read THIS host's,
# find no msm8996 and refuse, and every scenario would report "the probe could not run": a fact about the
# harness, not about the script. It is rewritten into the fake root for the same reason as the subject.
# Only `/proc/` is rewritten: everything else it reads is a path the fake root does not have, so it
# reports those reads as unreadable, which is honest and is also what an incomplete device looks like.
sed -e "s#/proc/#$FR/proc/#g" "$PROBE" > "$REPO/scripts/device/zl1-location-request.sh"
bash -n "$REPO/scripts/device/zl1-location-request.sh" || { echo "the staged probe does not parse" >&2; exit 2; }
RW="$REPO/scripts/host/zl1-gps-first-client.sh"
bash -n "$RW" || { echo "the rewritten script does not parse" >&2; exit 2; }

# The landing count, because one missed path means the command reads THIS machine while every scenario
# still "passes" (the defect docs 98 found in its own harness). `/proc/` is the one that matters: the
# container walk, the app walk and the kill all go through it, and `kill` is a shell BUILTIN -- a PATH
# stub cannot intercept it, so the rewrite to $STUB/kill is the only thing standing between this harness
# and signalling a host process.
n=$(grep -c '/proc/' "$SRC"); m=$(grep -c "$FR/proc/" "$RW")
[ "$n" = "$m" ] || { echo "only $m of $n '/proc/' occurrences were rewritten" >&2; exit 2; }
grep -qF "$STUB/kill" "$RW" \
  || { echo "the kill rewrite did not land (kill is a shell BUILTIN, so a real kill would signal a host process)" >&2; exit 2; }
grep -qF "APP_DIR=$FR/usr/share/click/preinstalled/weather.ubports/6.2.0" "$RW" \
  || { echo "APP_DIR was not rewritten -- APP_BIN is derived from it, so the app walk would never match" >&2; exit 2; }
grep -qF "SET_DIR=$FR/home/phablet/.local/share/weather.ubports/Databases" "$RW" \
  || { echo "SET_DIR was not rewritten -- the settings read would look at the real /home" >&2; exit 2; }

# --- the stubs -----------------------------------------------------------------------------------
#
# `ssh`: strip the connection options and the host, then run the remote command LOCALLY. `$*` is the
# single command argument ssh_d passes, so this is exactly what the device would have run. Newlines are
# flattened in the action log so that a whole invocation is ONE greppable line.
cat > "$STUB/ssh" <<EOF
#!/bin/sh
printf 'ssh %s\n' "\$(printf '%s' "\$*" | tr '\n' ' ')" >> "$ACT"
while [ \$# -gt 0 ]; do
  case "\$1" in -o) shift 2 ;; -*) shift ;; *) break ;; esac
done
[ \$# -gt 0 ] && shift          # the host
sh -c "\$*"
EOF
# `scp`: a "host:" destination is a push into the fake device; a "host:" source is a pull. Both remote
# paths were already rewritten into $FR, so the prefix is added only when it is not already there --
# prepending it twice is an easy way to make a pull of a real file look like an app that printed nothing.
cat > "$STUB/scp" <<EOF
#!/bin/sh
printf 'scp %s\n' "\$(printf '%s' "\$*" | tr '\n' ' ')" >> "$ACT"
while [ \$# -gt 0 ]; do
  case "\$1" in -o) shift 2 ;; -*) shift ;; *) break ;; esac
done
src="\$1"; dst="\$2"
dev() { case "\$1" in *:*) p="\${1#*:}" ;; *) p="\$1" ;; esac
        case "\$p" in "$FR"/*) printf '%s\n' "\$p" ;; *) printf '%s\n' "$FR\$p" ;; esac; }
case "\$dst" in *:*) cp "\$src" "\$(dev "\$dst")" 2>/dev/null ;;
                 *) cp "\$(dev "\$src")" "\$dst" 2>/dev/null ;; esac
exit 0
EOF
# `sleep` IS the launch. It returns instantly (the run must not take 120 s) and, on the call that follows
# the launch, it installs the state the launch would have produced: the app's /proc entry, the app's own
# output, and the journal lines the daemon would have logged. Installing it here rather than inside the
# `nsenter` stub is deliberate -- the launch is backgrounded through `setsid nohup ... &`, so the nsenter
# stub and the walk that looks for the app race each other; the sleep between them does not.
#
# Calls, in order: 1 `sleep 3` (display), 2 `sleep 4` (after the launch), 3 `sleep $SECS` (the wait),
# 4 `sleep 1` (after the kill). Only call 2 installs anything.
cat > "$STUB/sleep" <<EOF
#!/bin/sh
printf 'sleep %s\n' "\$*" >> "$ACT"
n=\$(( \$(cat "$W/sleepc" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$W/sleepc"
if [ "\$n" = 2 ]; then
  if [ -f "$W/launch.cmdline" ]; then mkdir -p "$FR/proc/\$FAKE_APP_PID"; cp "$W/launch.cmdline" "$FR/proc/\$FAKE_APP_PID/cmdline"; fi
  [ -f "$W/launch.err" ] && cp "$W/launch.err" "$FR/tmp/zl1-weather.err"
  [ -f "$W/launch.out" ] && cp "$W/launch.out" "$FR/tmp/zl1-weather.out"
  [ -f "$W/launch.journal" ] && cat "$W/launch.journal" >> "$W/journal"
fi
exit 0
EOF
cat > "$STUB/lxc-info" <<EOF
#!/bin/sh
printf 'lxc-info %s\n' "\$*" >> "$ACT"
[ -n "\$FAKE_CONTAINER" ] && printf '%s\n' "\$FAKE_CONTAINER"
exit 0
EOF
cat > "$STUB/pgrep" <<EOF
#!/bin/sh
printf 'pgrep %s\n' "\$*" >> "$ACT"
for a in "\$@"; do case "\$a" in lomiri) [ -n "\$FAKE_SHELL" ] && { printf '%s\n' "\$FAKE_SHELL"; exit 0; }; exit 1 ;; esac; done
exit 1
EOF
# The display service. TurnOn/TurnOff are recorded AND change what ActiveOutputs answers, so "was the
# display left as it was found" is a fact about the fixture rather than an assertion about the stub log.
cat > "$STUB/busctl" <<EOF
#!/bin/sh
printf 'busctl %s\n' "\$(printf '%s' "\$*" | tr '\n' ' ')" >> "$ACT"
case "\$*" in
*ActiveOutputs*) if [ -e "$W/display-on" ]; then cat "$W/outputs.on"; else cat "$W/outputs.off"; fi ;;
*call*) case "\$*" in *TurnOn*) : > "$W/display-on" ;; *TurnOff*) rm -f "$W/display-on" ;; esac ;;
esac
exit 0
EOF
# Two call shapes: the LAUNCH (python3 zl1-camapp-launch.py) and the LOGCAT read. Both are simulated --
# the launcher setuids to 32011 and would exec the real app, and there is no container here to enter.
cat > "$STUB/nsenter" <<EOF
#!/bin/sh
printf 'nsenter %s\n' "\$(printf '%s' "\$*" | tr '\n' ' ')" >> "$ACT"
for a in "\$@"; do
  case "\$a" in
  *logcat*) [ -n "\$FAKE_LOGCAT_RC" ] && [ "\$FAKE_LOGCAT_RC" != 0 ] && exit "\$FAKE_LOGCAT_RC"
            cat "$W/logcat.txt" 2>/dev/null; exit 0 ;;
  esac
done
exit 0
EOF
# The journal is a FILE. `--no-pager -o cat` and the bare form both print it; anything else (a device
# whose journalctl cannot run) is FAKE_JOURNAL_RC non-zero, which is the scenario that must NOT come out
# as "the app asked nothing". FAKE_JOURNAL_SHRINK makes the FIRST call print the whole file and every
# later one a line shorter -- the real rotation a rotation-less line-offset mark cannot survive.
cat > "$STUB/journalctl" <<EOF
#!/bin/sh
printf 'journalctl %s\n' "\$(printf '%s' "\$*" | tr '\n' ' ')" >> "$ACT"
[ "\${FAKE_JOURNAL_RC:-0}" != 0 ] && exit "\$FAKE_JOURNAL_RC"
c=\$(( \$(cat "$W/jlc" 2>/dev/null || echo 0) + 1 )); echo "\$c" > "$W/jlc"
if [ "\${FAKE_JOURNAL_SHRINK:-0}" != 0 ] && [ "\$c" -gt 1 ]; then
  head -n "\${FAKE_JOURNAL_SHRINK}" "$W/journal" 2>/dev/null
  exit 0
fi
cat "$W/journal" 2>/dev/null
exit 0
EOF
cat > "$STUB/getprop" <<EOF
#!/bin/sh
printf 'getprop %s\n' "\$*" >> "$ACT"
exit 0
EOF
cat > "$STUB/gdbus" <<EOF
#!/bin/sh
printf 'gdbus %s\n' "\$(printf '%s' "\$*" | tr '\n' ' ')" >> "$ACT"
exit 1
EOF
cat > "$STUB/systemctl" <<EOF
#!/bin/sh
printf 'systemctl %s\n' "\$(printf '%s' "\$*" | tr '\n' ' ')" >> "$ACT"
case "\$*" in
*list-units*) printf '%s\n' "\$FAKE_AGENTS" ;;
*status*) printf '%s\n' "\$FAKE_AGENT_STATUS" ;;
esac
exit 0
EOF
cat > "$STUB/kill" <<EOF
#!/bin/sh
printf 'kill %s\n' "\$*" >> "$ACT"
exit 0
EOF
chmod +x "$STUB"/*
export ACT W FR

# The settings read is `command -v sqlite3` and then a query, so the stub has to exist for the two
# readable scenarios and be ABSENT for the third. Absence is done by deleting the file, because
# `command -v` is a shell builtin and consults PATH -- there is no PATH stub that makes a name absent.
cat > "$STUB/sqlite3" <<EOF
#!/bin/sh
printf 'sqlite3 %s\n' "\$(printf '%s' "\$*" | tr '\n' ' ')" >> "$ACT"
printf '%s\n' "\$FAKE_SETTING"
exit 0
EOF
chmod +x "$STUB/sqlite3"
# A PATH with one host directory removed, so that a tool THIS HOST happens to have looks ABSENT to the
# fake device. Without it the "no sqlite3" branch is unreachable and the harness reports a false result:
# this host has sqlite3 in ~/miniconda3/bin, that directory is on the PATH the stubbed device inherits, so
# `command -v sqlite3` succeeded, the REAL host binary ran against the empty fixture database, and the run
# printed `no-row` -- "the column has no row" -- while the scenario claimed to be testing absence.
drop_path_dir() { # $1 = the full path of a file to hide
  local d; d="$(dirname "$1")"
  printf '%s' "$STUB:$(printf '%s' "$PATH" | tr ':' '\n' | grep -vxF "$d" | tr '\n' ':')"
}

# --- fixtures ------------------------------------------------------------------------------------
SHELL_PID=5000
CONTAINER_PID=700
APP_PID=6100
APP_DIR_FR="$FR/usr/share/click/preinstalled/weather.ubports/6.2.0"
SET_DB_FR="$FR/home/phablet/.local/share/weather.ubports/Databases/0404df7c9de73501aad24e64d39120e1.sqlite"

# The device-tree model, with its trailing NUL, as the guard's `tr -d '\0'` expects to find it. And
# `compatible`, because the device-side location probe REFUSES to run on anything without msm8996 in it --
# without this fixture the probe's own guard fires and the script would report "the probe could not run"
# in every scenario, which is a fact about this harness rather than about the script under test.
printf '%s\0' 'MSM 8996pro + PMI8996 LE_ZL1' > "$FR/proc/device-tree/model"
printf 'qcom,msm8996pro\0' > "$FR/proc/device-tree/compatible"
printf '(ii) 1 1\n' > "$W/outputs.on"
printf '(ii) 0 0\n' > "$W/outputs.off"
# A real /proc/<pid>/cmdline is NUL-separated, not newline-separated -- the walk's `tr '\0' ' '` is why
# the fixture has to be, too. The app's own entry is installed by the sleep stub at call 2.
printf '%s\0\n' "$APP_DIR_FR/lomiri-weather-app" > "$W/launch.cmdline"
# The launch wrapper's message lands in stderr (the launcher writes with file=sys.stderr), and Qt's
# message handler -- where console.log ends up -- does too, so a real app.out is usually EMPTY. app.err
# therefore carries the evidence and app.out is deliberately given ONE line, so a table that read one
# file twice or hardcoded a column would print something this fixture can fail on.
cat > "$W/launch.err" <<'EOF'
launching /usr/bin/lomiri-weather-app-migrate.py (APP_ID=weather.ubports_weather_6.2.0) with 41 environment variables from the session
dropped to uid 32011 gid 32011
Creating a QMirClientScreen now
** Application is now active
EOF
printf 'lomiri-weather-app: Creating a QMirClientScreen\n' > "$W/launch.out"
# The journal BEFORE the run: a service that has been up and idle. Its length is the mark the delta is
# computed from, which is why it is non-empty (an empty journal would make "before" and "after" both 0 and
# the harness would not be testing the offset at all).
cat > "$W/journal.before" <<'EOF'
Started Lomiri location service.
Service is running.
EOF
# The journal AFTER a door that OPENED.
cat > "$W/journal.opened" <<'EOF'
handle_create_session_for_criteria: session created for criteria
start_position_updates: starting the gps provider
EOF
# The journal AFTER a gate said NO (docs 93 section 3.2: the client only ever sees Error.CreatingSession).
cat > "$W/journal.rejected" <<'EOF'
resolve_credentials_for_incoming_message: profile=lomiri-weather-app
Client lacks permissions to access the service with the given criteria
EOF
# The vendor HAL's side (docs 82: locClientOpen proves the QMI client opened; its failure is non-fatal).
printf 'E locClientOpen failed\n' > "$W/logcat.locclient"
printf 'I no location lines here\n' > "$W/logcat.quiet"
printf '(ii) Unit lomiri-location-service-trust-stored-wayland.service\n(ii) active\n' > "$W/agents"
printf 'lomiri-location-service-trust-stored-wayland.service - Wayland agent\n   Active: active (running)\n' > "$W/agent.status"

# --- the checks ----------------------------------------------------------------------------------
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
want()    { if grep -Eq -- "$1" <<< "$2"; then ok "$3"; else bad "$3"; sed 's/^/        | /' <<< "$2"; fi; }
notwant() { if grep -Eq -- "$1" <<< "$2"; then bad "$3"; grep -E -- "$1" <<< "$2" | sed 's/^/        | /'; else ok "$3"; fi; }
# The verdict BLOCK -- anchored on the script's own `== verdict` header, so it is the verdict and nothing
# else. Two earlier versions of this were wrong in the same direction and for instructive reasons: keeping
# only the lines that begin with `->` dropped every continuation line (where the "do not read these zeroes
# as X" warnings live), and starting at the FIRST `->` line anywhere in the output picked up an unrelated
# `-> the count below is 0 because IT COULD NOT RUN` note from the logcat section, several sections above
# the verdict. Both would have reported the script wrong when it was right.
verdict() { printf '%s\n' "$1" | sed -n '/^== verdict$/,$p' | sed '1d;/^== /,$d'; }

env_reset() {
  FAKE_CONTAINER=$CONTAINER_PID
  FAKE_SHELL=$SHELL_PID
  FAKE_APP_PID=$APP_PID
  FAKE_SETTING=true
  FAKE_AGENTS="$(cat "$W/agents")"
  FAKE_AGENT_STATUS="$(cat "$W/agent.status")"
  FAKE_LOGCAT_RC=0
  FAKE_JOURNAL_RC=0
  FAKE_JOURNAL_SHRINK=0
  FAKE_PATH="$STUB:$PATH"
  cat > "$STUB/sqlite3" <<EOF
#!/bin/sh
printf 'sqlite3 %s\n' "\$(printf '%s' "\$*" | tr '\n' ' ')" >> "$ACT"
printf '%s\n' "\$FAKE_SETTING"
exit 0
EOF
  chmod +x "$STUB/sqlite3"
  : > "$W/launch.journal"                 # nothing is logged unless a scenario says so
  cp "$W/journal.before" "$W/journal"
  cp "$W/logcat.quiet" "$W/logcat.txt"
  rm -f "$W/display-on" "$W/sleepc" "$W/jlc"
  # The app's /proc entry the launch would have left. Written HERE and not only once at the top, because
  # one scenario deletes it to model a launcher that exited -- and without this line every scenario after
  # that one inherited the deletion and tested "the app never started" while claiming to test the door.
  printf '%s\0\n' "$APP_DIR_FR/lomiri-weather-app" > "$W/launch.cmdline"
  rm -rf "$FR/proc/$APP_PID"
  : > "$SET_DB_FR"                        # the app's LocalStorage database, empty but readable
  printf '(ii) 0 0\n' > "$W/outputs.off"  # the display is off when found (the honest default)
  printf '(ii) 1 1\n' > "$W/outputs.on"
  printf '%s\0' 'MSM 8996pro + PMI8996 LE_ZL1' > "$FR/proc/device-tree/model"
  OUTDIR="$W/out"; rm -rf "$OUTDIR"; mkdir -p "$OUTDIR"
}

run() { # $1 = extra arguments (may be empty)
  : > "$ACT"
  OUT="$( cd "$W" && env PATH="$FAKE_PATH" ZL1_HOST=fake \
      FAKE_CONTAINER="$FAKE_CONTAINER" FAKE_SHELL="$FAKE_SHELL" FAKE_APP_PID="$FAKE_APP_PID" \
      FAKE_SETTING="$FAKE_SETTING" FAKE_AGENTS="$FAKE_AGENTS" FAKE_AGENT_STATUS="$FAKE_AGENT_STATUS" \
      FAKE_LOGCAT_RC="$FAKE_LOGCAT_RC" FAKE_JOURNAL_RC="$FAKE_JOURNAL_RC" \
      FAKE_JOURNAL_SHRINK="$FAKE_JOURNAL_SHRINK" \
      bash "$RW" --seconds 30 --outdir "$OUTDIR" $1 2>&1 )"
  RC=$?
}

echo "zl1 GPS first client -- offline self-test"
echo "  script under test: $SRC"
echo "  fake device:       $FR"
echo

# ==================================================================================================
echo "== 1. the guards: not the zl1, and a wait nobody could use =="
# ==================================================================================================
env_reset
printf '%s\0' 'Some Other Phone' > "$FR/proc/device-tree/model"
run ""
[ "$RC" = 1 ] && ok "a different device-tree model exits 1" || bad "it exited $RC on the wrong device"
want 'this is not the zl1' "$OUT" "and says which model it saw"
notwant '^busctl .*call' "$(cat "$ACT")" "it turns no display on for a device it just refused"
notwant 'nsenter' "$(cat "$ACT")" "and launches nothing on it"

env_reset
run "--seconds 10"
[ "$RC" = 2 ] && ok "--seconds 10 is refused with exit 2" || bad "it exited $RC instead of refusing"
want 'is too short -- a PERSON has to be able to read the prompt' "$OUT" \
  "and says why the number is too short (a person has to tap a toggle inside it)"
[ -s "$ACT" ] && { bad "it touched the device before refusing:"; head -3 "$ACT" | sed 's/^/        | /'; } \
              || ok "and it refuses before touching the device at all (not one ssh)"

# ==================================================================================================
echo
echo "== 2. the app never started: no reading about the door may be printed =="
# ==================================================================================================
env_reset
rm -f "$W/launch.cmdline"      # the launcher exited and left no /proc entry for the walk to find
run ""
want 'NOT launched' "$OUT" "it reports that the launcher did not leave a process"
V="$(verdict "$OUT")"
want 'THE APP NEVER STARTED' "$V" "the verdict is that the APP never started"
notwant 'ASKED NOTHING' "$V" "and NOT 'the app asked nothing' -- that would be a reading of a protocol nobody ran"
want 'Do not read the zero counts' "$V" "it says so in as many words, so a reader does not do it either"
# The wait is a person's time: with no app on screen there is nothing to tap, and 30 s of waiting would be
# 30 s of the run pretending to test something.
notwant '^sleep 30$' "$(cat "$ACT")" "and it does not sit out the --seconds wait with no app to tap"
want 'nothing to tap' "$OUT" "and it says the wait was skipped because there is nothing to tap"

# ==================================================================================================
echo
echo "== 3. the healthy run: the app starts, asks nothing, and the device is put back =="
# ==================================================================================================
env_reset
run ""
[ "$RC" = 0 ] && ok "the run exits 0" || bad "the run exited $RC"
want 'launched pid' "$OUT" "the app is reported launched"
V="$(verdict "$OUT")"
want 'THE APP ASKED NOTHING' "$V" "the verdict is that the app asked nothing"
notwant 'DOOR OPENED' "$V" "and NOT that the door opened"
want 'toggle' "$V" "and it points at the toggle as the likely reason"
# The launch command, as sent: the MIGRATE WRAPPER first (docs 105 section 6), the app id, and the
# container's PID namespace. Asserted on the command line that was actually sent, not on a comment.
want 'zl1-camapp-launch.py /usr/bin/lomiri-weather-app-migrate.py weather.ubports_weather_6.2.0' \
  "$(cat "$ACT")" "the launch runs the app's MIGRATE WRAPPER, not the bare binary (docs 105 section 6)"
want 'nsenter -t 700 -p' "$(cat "$ACT")" "inside the container's PID namespace"
want 'ZL1_AS_UID=32011' "$(cat "$ACT")" "as the session's own uid"
# And the device is put back.
want '^kill ' "$(cat "$ACT")" "the app is stopped at the end"
want '^busctl .*TurnOff' "$(cat "$ACT")" "and the display is turned back off (it was found off)"
want 'display: .ii. 0 0' "$OUT" "and the display state it restored to is printed"

# --keep-app / --keep-display must mean what they say.
env_reset
run "--keep-app --keep-display"
notwant '^kill ' "$(cat "$ACT")" "--keep-app leaves the app running"
notwant '^busctl .*TurnOff' "$(cat "$ACT")" "--keep-display leaves the display on"

# ==================================================================================================
echo
echo "== 4. the door OPENED: a session and the QMI client, and neither alone is enough =="
# ==================================================================================================
env_reset
cp "$W/journal.opened" "$W/launch.journal"
cp "$W/logcat.locclient" "$W/logcat.txt"
run ""
V="$(verdict "$OUT")"
want 'THE DOOR OPENED' "$V" "a new CreatingSession plus locClientOpen: the verdict is that the door opened"
notwant 'ASKED NOTHING' "$V" "and not that the app asked nothing"
notwant 'A GATE SAID NO' "$V" "and not that a gate refused"
want 'FIRST time on this port' "$V" "it says this is the first time anything asked the GPS for a position"
want 'does NOT yet prove' "$V" "and it says an opened door is not a fix"

env_reset
cp "$W/journal.opened" "$W/launch.journal"
run ""                               # the daemon logged something but the QMI client never appears
V="$(verdict "$OUT")"
notwant 'THE DOOR OPENED' "$V" "daemon log lines ALONE do not license 'the door opened'"
want 'SOMETHING WAS LOGGED' "$V" "they come out as 'something was logged, read the delta' instead"
want 'read journal-delta.txt' "$V" "and it points at the file rather than guessing what the lines mean"

env_reset
cp "$W/logcat.locclient" "$W/logcat.txt"   # the client opened, with the daemon silent
run ""
want 'THE DOOR OPENED' "$(verdict "$OUT")" "the QMI client opening IS the licence, on its own (docs 82)"

# ==================================================================================================
echo
echo "== 5. a gate said NO, and the count that could not be taken =="
# ==================================================================================================
env_reset
cp "$W/journal.rejected" "$W/launch.journal"
run ""
V="$(verdict "$OUT")"
want 'A GATE SAID NO' "$V" "'Client lacks permissions' in the delta: the verdict is that a gate refused"
want 'gate 2 or gate 3' "$V" "and it names WHICH gates that message can come from"
notwant 'DOOR OPENED' "$V" "and not that the door opened"
want 'agent.txt' "$V" "and it points at the agent's own unit as the thing to read next"

# The journal could not be read. This is the scenario docs 117 is about: `journalctl` failing prints no
# lines, which is what an empty journal prints, and the verdict must NOT be "the app asked nothing".
env_reset
FAKE_JOURNAL_RC=1
run ""
V="$(verdict "$OUT")"
want 'UNANSWERED' "$V" "an unreadable journal: the verdict is UNANSWERED"
notwant 'ASKED NOTHING' "$V" "and NOT 'the app asked nothing' (a command that could not run is not a zero)"
want 'NOT' "$V" "it says explicitly that this is not 'the door is shut'"

# The journal SHRANK between the mark and the second reading, so `tail -n +N` would return lines from
# BEFORE the launch -- and could hand the verdict an old CreatingSession.
env_reset
cp "$W/journal.opened" "$W/launch.journal"
FAKE_JOURNAL_SHRINK=1      # ONE line, against a mark of two: a real shrink, not a slow growth
run ""
V="$(verdict "$OUT")"
want 'UNANSWERED' "$V" "a journal that shrank: the verdict is UNANSWERED"
want 'not a valid mark' "$OUT" "and it says the line offset is not a valid mark"
notwant 'DOOR OPENED' "$V" "and it does not read the old lines as this run's evidence"

# ==================================================================================================
echo
echo "== 6. the logcat half failing is not 'the client stayed shut' =="
# ==================================================================================================
env_reset
FAKE_LOGCAT_RC=1
run ""
want 'LOGCAT-COULD-NOT-RUN' "$OUT" "a logcat that could not run says so"
want 'because IT COULD NOT RUN' "$OUT" "and says the 0 below it is for THAT reason"
V="$(verdict "$OUT")"
want 'THE APP ASKED NOTHING' "$V" "the verdict still reports what the journal said (it was readable)"

# ==================================================================================================
echo
echo "== 7. the app's toggle is READ, never written, and its three answers are distinct =="
# ==================================================================================================
env_reset
run ""
want "app's toggle:   true" "$OUT" "the toggle reads true when the database says so"
notwant '^sqlite3 .*insert\|^sqlite3 .*update' "$(cat "$ACT")" "and nothing WRITES it -- there is no write mode to test"

env_reset
FAKE_SETTING=false
run ""
want "app's toggle:   false" "$OUT" "the toggle reads false when the database says so"
# The two flavours of "could not look" are different from each other AND from false.
env_reset
rm -f "$STUB/sqlite3"
_host_sqlite3="$(command -v sqlite3 || true)"
[ -n "$_host_sqlite3" ] && FAKE_PATH="$(drop_path_dir "$_host_sqlite3")"
run ""
want 'cannot-read-no-sqlite3' "$OUT" "no sqlite3 on the device reads as 'could not look', not as false"
env_reset
rm -f "$SET_DB_FR"
run ""
want 'cannot-read-no-database' "$OUT" "no database reads as 'could not look', not as false"
want 'is NOT' "$OUT" "and the output says a cannot-read is not a false"

# ==================================================================================================
echo
echo "== 8. --quiet, and the prompt it must not silence =="
# ==================================================================================================
# The run does not work unless a person reads the hand-off and acts on it. `--quiet` means fewer read-only
# findings; it can never mean "do not tell me what to do with the phone" -- the same rule the location
# probe's own `warn()` exists to enforce.
env_reset
run "--quiet"
notwant 'locClientOpen lines' "$OUT" "--quiet drops the evidence tables"
want 'detect current location' "$OUT" "--quiet still prints the hand-off prompt, on stderr"
want 'THE APP ASKED NOTHING' "$(verdict "$OUT")" "and still prints the verdict"

# ==================================================================================================
echo
echo "== 9. the archive =="
# ==================================================================================================
env_reset
cp "$W/journal.opened" "$W/launch.journal"
run ""
for f in probe-before.txt journal-delta.txt logcat.txt agent.txt app.err app.out probe-after.txt; do
  [ -f "$OUTDIR/$f" ] || bad "the archive is missing $f"
done
ok "every evidence file is written into --outdir"
want 'start_position_updates' "$(cat "$OUTDIR/journal-delta.txt")" "the delta holds the NEW lines, and only those"
notwant 'Started Lomiri location service' "$(cat "$OUTDIR/journal-delta.txt")" \
  "and NOT the pre-run lines (the offset is what makes it a delta)"
[ -s "$OUTDIR/app.err" ] && ok "the app's own stderr was pulled into the archive" || bad "app.err is empty"

# ==================================================================================================
echo
echo "== 10. the health check cites this harness's count, and that citation cannot drift =="
# ==================================================================================================
# `host/zl1-health-check.sh` is the first thing a human reads and it names each harness WITH A CHECK
# COUNT, typed by hand -- so every time a harness gains an assertion its citation goes stale and nothing
# notices. Every harness the page cites checks its own citation; this is that check.
HEALTH="$HERE/zl1-health-check.sh"
if [ -r "$HEALTH" ]; then
  cited=$(sed -e 's/always "/ /g' -e 's/"$//' "$HEALTH" | tr '\n' ' ' |
            sed -n 's/.*zl1-gps-first-client-selftest\.sh[ ,(]*\([0-9][0-9]*\) checks.*/\1/p')
  total=$((PASS + FAIL + 1))
  if [ -z "$cited" ]; then
    bad "the health check does not cite this harness's count -- either the citation is gone or its wording changed"
  elif [ "$cited" = "$total" ]; then
    ok "the health check cites $cited checks, and this run has exactly that many"
  else
    bad "the health check cites $cited checks, but this harness has $total -- fix host/zl1-health-check.sh"
  fi
else
  bad "cannot read $HEALTH -- its citation is unchecked"
fi

echo
echo "pass=$PASS fail=$FAIL"
[ "$KEEP" = 1 ] || rm -rf "$W"
[ "$FAIL" = 0 ]
