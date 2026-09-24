#!/usr/bin/env bash
# zl1 camera stack reset -- offline self-test. Host-side, touches no device, needs no phone.
#
# Why this exists. `scripts/android-fw-stubs/camera-stack-reset.sh` is the procedure that has to run
# before any camera measurement, and it is the only device procedure here whose VERDICTS have been wrong
# twice. docs/ubuntu-touch/67 fixed the first: the user-switch check read `the name resolves` out of a
# path that never prints it, and warned on every clean run. This harness is for the second family, and it
# was found the way the family's other false verdicts were found (docs 134): a check that can fail on
# input which matches.
#
#   * `on_device '<a whole logcat dump>' | grep -q '<the line we are waiting for>'` reports the death of
#     the WRITER, not the reader's answer -- `grep -q` leaves at the first match, closes the pipe, the
#     dump dies of SIGPIPE, and the script's own `set -o pipefail` turns that into "the check failed".
#     Both waits asked that question thirty times each. With a dump larger than a pipe (64 KB) it is not a
#     race at all: every run. So a device whose log carried the registration line on its FIRST line read
#     as "the provider has not registered after 90s" -- the reading that sends somebody hunting a broken
#     HAL. The dump is captured first now, and section 3 runs the shipped script against a fixture dump
#     of several megabytes.
#   * the same shape sat in both user-switch verdicts (`printf '%s\n' "$last_notify" | grep -q ...`).
#   * and the enumeration wait, when it gave up, asked logcat a SECOND time for a diagnostic -- a
#     different question, three seconds later, with the same chance of being killed mid-answer.
#
# How it works: **the transport stub IS the device.** `ssh` strips its options and host and runs the
# remote command locally against a fake root, with the device's tools (`lxc-info`, `pgrep`, `nsenter`,
# `/system/bin/logcat`, `/system/bin/setprop`) stubbed and `sleep` acting as an instant clock that records
# WHO slept. So a scenario is "a device whose logcat dump says this, and whose stub log says that", and
# the size of that dump is a knob -- which is the whole point here.
#
# Usage: zl1-camera-stack-reset-selftest.sh [--keep]
#   --keep   leave the fake device, the stubs and the rewritten subject for inspection
#
# `ZL1_CAMERA_RESET_SRC=/path/to/script` runs the whole thing against another copy of the subject. That is
# how the pre-fix revision was measured (doc 135): the harness must go red on it, or it is not testing
# anything.
#
# Exit codes: 0 every scenario behaved; 1 something did not; 2 the harness could not set up.

set -uo pipefail

KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
  --keep) KEEP=1; shift ;;
  --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${ZL1_CAMERA_RESET_SRC:-$HERE/../android-fw-stubs/camera-stack-reset.sh}"
[ -r "$SRC" ] || { echo "cannot read the subject: $SRC" >&2; exit 2; }

W="${TMPDIR:-/tmp}/zl1-camera-reset-selftest"
REPO="$W/repo"
FR="$W/dev"
STUB="$W/stub"
ACT="$W/actions"
rm -rf "$W"
mkdir -p "$REPO" "$STUB" "$FR/proc/device-tree" "$FR/userdata/zl1-fw-stubs" "$FR/system/bin" || exit 2

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
want()    { if grep -Eq -- "$1" <<< "$2"; then ok "$3"; else bad "$3"; sed 's/^/        | /' <<< "$2"; fi; }
notwant() { if grep -Eq -- "$1" <<< "$2"; then bad "$3"; grep -E -- "$1" <<< "$2" | sed 's/^/        | /'; else ok "$3"; fi; }

# --- the subject, rewritten into the fake device ---------------------------------------------------
#
# The transport runs the remote command LOCALLY, so every device path it touches has to exist here. Three
# rewrites, and each one's landing is asserted below: `/proc/` (the model read), `/userdata/zl1-fw-stubs`
# (the stub's log) and `/system/bin/` (logcat, setprop).
sed -e "s#/proc/#$FR/proc/#g" \
    -e "s#/userdata/zl1-fw-stubs#$FR/userdata/zl1-fw-stubs#g" \
    -e "s#/system/bin/#$FR/system/bin/#g" \
    "$SRC" > "$REPO/camera-stack-reset.sh"
chmod +x "$REPO/camera-stack-reset.sh"
if bash -n "$REPO/camera-stack-reset.sh"; then
  ok "the rewritten subject parses"
else
  bad "the rewritten subject does not parse -- the harness cannot run"; exit 2
fi
for pair in "/proc/:$FR/proc/" "/userdata/zl1-fw-stubs:$FR/userdata/zl1-fw-stubs" "/system/bin/:$FR/system/bin/"; do
  n=$(grep -cF "${pair%%:*}" "$SRC"); m=$(grep -cF "${pair#*:}" "$REPO/camera-stack-reset.sh")
  if [ "$n" = "$m" ]; then
    ok "all $n '${pair%%:*}' occurrences were rewritten into the fake root"
  else
    bad "only $m of $n '${pair%%:*}' occurrences were rewritten -- the subject would touch the host"; exit 2
  fi
done

# The script deploys the stub through its sibling, and that sibling scp's to a device: it is a recording
# stand-in here. What is under test is that it is CALLED (after the enumeration) and what the script makes
# of what it says.
cat > "$REPO/run-on-device.sh" <<EOF
#!/bin/sh
printf 'run-on-device %s\n' "\$*" >> "$ACT"
case "\${FAKE_NOTIFY:-sent}" in
sent)      printf 'notify-user-switch: resolves media.camera\nnotify-user-switch: sent (oneway) EVENT_USER_SWITCHED\n' ;;
noservice) printf 'notify-user-switch: no such service -- cameraserver is not up\n' ;;
local)     printf 'notify-user-switch: it answered with a local object\n' ;;
esac
exit 0
EOF
chmod +x "$REPO/run-on-device.sh"

# --- the stubs -------------------------------------------------------------------------------------
#
# `ssh`: strip the connection options and the host, then run the remote command LOCALLY. The whole
# invocation is flattened onto one line of the action log, so "was the FULL service name restarted" and
# "did the wait re-dump the log" are single greppable facts.
cat > "$STUB/ssh" <<EOF
#!/bin/sh
printf 'ssh %s\n' "\$(printf '%s' "\$*" | tr '\n' ' ')" >> "$ACT"
while [ \$# -gt 0 ]; do
  case "\$1" in -o) shift 2 ;; -*) shift ;; *) break ;; esac
done
[ \$# -gt 0 ] && shift          # the host
sh -c ". $STUB/remote-pre.sh; \$*"
EOF
# The remote prelude. `kill` is a shell BUILTIN, so a PATH stub cannot intercept it, and the fixture's pid
# would be a REAL host pid -- 900 or 4711 on this machine. A function beats a regular builtin in dash and
# bash, so the remote `kill -9 <pid>` is recorded instead of delivered.
cat > "$STUB/remote-pre.sh" <<EOF
kill() { printf 'kill %s\n' "\$*" >> "$ACT"; }
EOF
# The container's pid, and the process list the script reads. `pgrep -x test_camera` is the stale client
# the reset starts by killing; `pgrep -a -f camera` is the "what is up" line printed after the restart.
cat > "$STUB/lxc-info" <<EOF
#!/bin/sh
printf 'lxc-info %s\n' "\$*" >> "$ACT"
printf '%s\n' "\${FAKE_CONTAINER:-700}"
exit 0
EOF
cat > "$STUB/pgrep" <<EOF
#!/bin/sh
printf 'pgrep %s\n' "\$*" >> "$ACT"
for a in "\$@"; do
  case "\$a" in
  test_camera) [ -n "\${FAKE_TESTCAM:-}" ] && { printf '%s\n' "\$FAKE_TESTCAM"; exit 0; }; exit 1 ;;
  esac
done
case "\$*" in *"-f camera"*) [ -n "\${FAKE_UP:-}" ] && { printf '%s\n' "\$FAKE_UP"; exit 0; }; exit 1 ;; esac
exit 1
EOF
# `nsenter` is asked to run the command inside the container's namespaces, which do not exist here: it runs
# it locally instead. The options before `--` are not meaningfully modelled.
cat > "$STUB/nsenter" <<EOF
#!/bin/sh
printf 'nsenter %s\n' "\$(printf '%s' "\$*" | tr '\n' ' ')" >> "$ACT"
while [ \$# -gt 0 ]; do
  case "\$1" in -t) shift 2 ;; -*) shift ;; --) shift; break ;; *) break ;; esac
done
[ \$# -gt 0 ] && exec "\$@"
exit 0
EOF
# The clock, and the only honest way to tell the two kinds of `sleep 3` apart: the waits' own `sleep 3` is
# a child of the SUBJECT (a bash process), while the `sleep 3` inside the provider-restart command is a
# child of the device-side shell the transport stub runs (`sh -c ...`). It is instant either way.
cat > "$STUB/sleep" <<EOF
#!/bin/sh
printf 'sleep %s parent=%s\n' "\$*" "\$(tr '\\0' ' ' < /proc/\$PPID/cmdline 2>/dev/null)" >> "$ACT"
exit 0
EOF
# The logcat the waits read, and the setprop the restarts go through. `-c` empties the buffer (the script's
# last step); `-b main -d -v brief` dumps whatever the scenario put in the file.
#
# Note the LAST line is the `cat` itself and there is no `exit 0` after it. That is not tidiness: a stub
# that ended with `exit 0` would report 0 for a `cat` that was killed by SIGPIPE, and the transport would
# then be unable to reproduce the very defect section 5 drives -- a fixture that cannot fail. It cost one
# run to notice, and the symptom was the mutant looking exactly like the fix.
cat > "$FR/system/bin/logcat" <<EOF
#!/bin/sh
printf 'logcat %s\n' "\$*" >> "$ACT"
case "\$*" in
*-c*) : > "$W/logcat.txt"; exit 0 ;;
esac
[ -f "$W/logcat.txt" ] || exit 0
cat "$W/logcat.txt"
EOF
cat > "$FR/system/bin/setprop" <<EOF
#!/bin/sh
printf 'setprop %s\n' "\$*" >> "$ACT"
exit 0
EOF
chmod +x "$STUB"/* "$FR/system/bin"/*
export ACT REPO W FR

# --- the two places this file has to SPELL the shape it forbids ------------------------------------
#
# The family's meta-harness (`zl1-selftest-family-selftest.sh` section 7b) forbids `<pipe> grep -q` and
# `<pipe> head` in ANY harness that sets pipefail -- including this one -- and it does not care that the two
# occurrences below are test data: one is a `sed` expression that BUILDS the shape for a mutant, the other
# is the filter that NAMES the inert forms in the shipped file. So `@` stands in for the pipe in both, and
# is translated where they are used. Same trick, same reason, as the meta-harness's own fixtures: a guard
# that has to be given an exemption for its own test data is a guard somebody switches off.
#
# (It really does fire: the first version of this file wrote both strings with a literal pipe and the
# meta-harness went red on it inside the family run -- which is the invariant working as designed.)
pipe() { tr '@' '|'; }
OLDPOLL_SED='s#^  if grep -q "\$PROVIDER_REGISTERED" <<< "\$dump"; then#  if on_device "$LOGCAT_DUMP" @ grep -q "$PROVIDER_REGISTERED"; then#'
INERT_ALT='pgrep -x test_camera @ head -1@lxc-info -n android -pH( 2>/dev/null)? @ head -1'

# --- fixtures --------------------------------------------------------------------------------------
#
# The device-tree model, with the trailing NUL the guard's `tr -d '\0'` expects.
printf '%s\0' 'MSM 8996pro + PMI8996 LE_ZL1' > "$FR/proc/device-tree/model"

# The two lines the two waits wait for. Where they sit IN the dump is the whole subject of section 3: a
# reader that leaves at the first match is what kills a writer that has not finished, so a match on line 1
# is the worst case, not a soft one.
PROVIDER_LINE='Registration complete for android.hardware.camera.provider@2.4::ICameraProvider'
ENUM_LINE='Camera provider legacy/0 ready with 2 camera devices'
registered()   { printf '%s\n%s\n' "$PROVIDER_LINE" "$ENUM_LINE"; }
unregistered() { printf 'QCamera3HWI: mm_channel_fsm_state: invalid state (1) for evt (6)\n'; }

# The dump the trap is built on: the two lines the waits want, on the FIRST two lines, followed by several
# megabytes of a log that looks like a log. Built once and copied into place per scenario, because the
# subject's last step CLEARS the buffer (`logcat -c`) -- so a scenario that reuses the previous run's
# fixture would be measuring an empty log, which is how the first version of section 5 reported a trap that
# did not reproduce.
BIGF="$W/big-dump.txt"
{ registered; seq 1 200000 | sed 's/^/logcat filler line /'; } > "$BIGF"
NBIG=$(wc -c < "$BIGF")

# The stub's own log, as the script's `tail -14` reads it. The LAST notify block is the one that counts
# (docs 67), so `stale` writes an older block that says the event was sent and a newer one that does not.
stublog() { # sent|noservice|local|silent|stale
  case "$1" in
  sent)      printf 'notifySystemEvent(EVENT_USER_SWITCHED) -> sent (oneway)\n' ;;
  noservice) printf 'notifySystemEvent(EVENT_USER_SWITCHED) -> no such service: media.camera\n' ;;
  local)     printf 'notifySystemEvent(EVENT_USER_SWITCHED) -> answered with a local object\n' ;;
  silent)    printf 'notifySystemEvent(EVENT_USER_SWITCHED) -> nothing at all\n' ;;
  stale)     printf 'notifySystemEvent(EVENT_USER_SWITCHED) -> sent (oneway)\n'
             printf 'notifySystemEvent(EVENT_USER_SWITCHED) -> no such service: media.camera\n' ;;
  esac > "$FR/userdata/zl1-fw-stubs/service-stub.log"
}

# --- running the subject ---------------------------------------------------------------------------
RUN="$REPO/camera-stack-reset.sh"
OUT=""; RC=0
reset() { # a healthy device, every time
  : > "$ACT"
  registered > "$W/logcat.txt"
  stublog sent
  # Exported, not merely set: the subject is a child process, and the stubs it runs are grandchildren. A
  # shell variable would quietly leave every FAKE_* at its default and the scenarios would differ only in
  # the parts this harness controls directly.
  FAKE_CONTAINER=700; FAKE_TESTCAM=900; FAKE_UP='1 mm-qcamera-daemon'; FAKE_NOTIFY=sent
  export FAKE_CONTAINER FAKE_TESTCAM FAKE_UP FAKE_NOTIFY
}
subj_run() { local bin="$1"; shift
  : > "$ACT"
  OUT="$(env PATH="$STUB:$PATH" "$bin" "$@" 2>&1)"; RC=$?
}
run() { subj_run "$RUN" "$@"; }
actions() { cat "$ACT"; }
# The waits' own sleeps, told apart from the one inside the provider-restart command by their parent.
slept() { grep -c "^sleep 3 parent=bash " "$ACT"; }
dumps() { grep -c '^logcat -b main -d' "$ACT"; }

# ==================================================================================================
echo "== 1. the guard: not the zl1, and nothing else is touched =="
# ==================================================================================================
reset
printf '%s\0' 'MSM 8996pro + PMI8996 SOMETHING_ELSE' > "$FR/proc/device-tree/model"
run
[ "$RC" = 1 ] && ok "a device that is not the zl1 exits 1" || bad "it exited $RC"
want 'this is not the zl1' "$OUT" "and says so"
[ "$(grep -c 'ssh ' <<< "$(actions)")" = 1 ] \
  && ok "with ONE call made (the model read) -- no restart, no kill, no logcat" \
  || bad "the guard let $(grep -c 'ssh ' <<< "$(actions)") calls through"
printf '%s\0' 'MSM 8996pro + PMI8996 LE_ZL1' > "$FR/proc/device-tree/model"

# ==================================================================================================
echo "== 2. the healthy path: the steps, in the one order that works =="
# ==================================================================================================
reset; run
[ "$RC" = 0 ] && ok "a healthy device exits 0" || bad "it exited $RC"
want 'provider registered' "$OUT" "the first wait sees the registration line"
want 'both cameras enumerated' "$OUT" "and the second sees both cameras"
want 'the user switch was applied' "$OUT" "the stub's log says the event was sent (oneway)"
want 'cleared' "$OUT" "and the main log buffer is cleared last"
want 'killed test_camera host pid 900' "$OUT" "the stale client is killed, and it says so on stdout"
A="$(actions)"
want '^kill -9 900$' "$A" "and the transport RECORDED the kill: \`kill\` is a shell builtin, so this is a function in the stub, not a PATH match"
pkill=$(grep -n 'pgrep -x test_camera' <<< "$A" | sed -n '1p' | cut -d: -f1)
pprov=$(grep -n 'ctl.restart vendor.camera-provider-2-4' <<< "$A" | sed -n '1p' | cut -d: -f1)
pcam=$(grep -n 'ctl.restart cameraserver' <<< "$A" | sed -n '1p' | cut -d: -f1)
pnotify=$(grep -n 'run-on-device' <<< "$A" | sed -n '1p' | cut -d: -f1)
pclear=$(grep -n 'logcat -b main -c' <<< "$A" | sed -n '1p' | cut -d: -f1)
[ -n "$pkill" ] && [ -n "$pprov" ] && [ "$pkill" -lt "$pprov" ] \
  && ok "the stale client is killed before the provider is restarted" || bad "the kill is not before the restart"
[ -n "$pprov" ] && [ -n "$pcam" ] && [ "$pprov" -lt "$pcam" ] \
  && ok "the PROVIDER is restarted before cameraserver (or cameraserver finds it half torn down)" \
  || bad "the provider restart is not first"
[ -n "$pcam" ] && [ -n "$pnotify" ] && [ "$pcam" -lt "$pnotify" ] \
  && ok "the notification comes after the restart, not before it" || bad "the notification is not after the restart"
[ -n "$pnotify" ] && [ -n "$pclear" ] && [ "$pnotify" -lt "$pclear" ] \
  && ok "and the log is cleared last, so the next run's wait starts from an empty buffer" || bad "the clear is not last"
# The prefix is load-bearing, and that is why it is asserted rather than assumed: `ctl.restart
# camera-provider-2-4` (no prefix) is accepted by setprop and silently does nothing.
notwant 'ctl.restart camera-provider-2-4' "$A" "the restart uses the FULL service name from the .rc"
want 'vendor.camera-provider-2-4' "$A" "which is the one setprop knows"
want 'nsenter -t 700 -p --' "$A" "the container's pid is used for the nsenter, not a host pid"
[ "$(dumps)" = 2 ] && ok "exactly one dump per wait, matched on the first pass (2 dumps, 0 sleeps)" \
                   || bad "the healthy run made $(dumps) dumps and $(slept) waits' sleeps"
[ "$(slept)" = 0 ] && ok "neither wait slept: both matched on the first pass" \
                   || bad "a wait slept $(slept) times on a device that answered immediately"

echo
echo "   -- --quiet: the flag its usage line promises, now that every line goes through say()"
reset; run --quiet
[ -z "$OUT" ] && ok "--quiet on a healthy device prints NOTHING (the remote echoes go through say too)" \
              || bad "--quiet printed: $OUT"
reset; run
want 'cleared' "$OUT" "and without --quiet the same run does print them (so the emptiness above is say(), not a step that was skipped)"

# ==================================================================================================
echo "== 3. the waits, against a dump LARGER THAN A PIPE =="
# ==================================================================================================
# This is the defect the harness was written for. `on_device '<a whole logcat dump>' | grep -q` reports the
# death of the WRITER when the reader leaves at the first match, and this script sets pipefail -- so a dump
# bigger than a pipe turns "the provider registered" into "the provider has not registered after 90s".
reset
cp "$BIGF" "$W/logcat.txt"
run
[ "$NBIG" -gt 1000000 ] && ok "the fixture dump is $NBIG bytes -- larger than any default pipe" \
                        || bad "the fixture dump is only $NBIG bytes, so the trap is vacuous"
want 'provider registered' "$OUT" "a registration line on the FIRST line of a $NBIG-byte dump is still seen"
want 'both cameras enumerated' "$OUT" "and so is the enumeration line on the second"
notwant 'has not registered after 90s' "$OUT" "the wait does NOT time out on a device that answered immediately"
notwant 'a run now would fail to connect' "$OUT" "and the second wait does not warn about a connect that would work"
[ "$(slept)" = 0 ] && ok "with no sleep at all: both matched on their first pass" \
                   || bad "a wait slept $(slept) times on a device that answered immediately"

echo
echo "   -- a device that really has not registered:"
reset; { unregistered; seq 1 40 | sed 's/^/logcat filler line /'; } > "$W/logcat.txt"; run
want 'has not registered after 90s' "$OUT" "the wait says so, after its 90 seconds"
want 'invalid state \(1\) for evt \(6\)' "$OUT" "and the enumeration's diagnostic tail is printed"
notwant 'logcat filler line' "$OUT" "showing only the QCamera lines, not the whole dump"
[ "$(slept)" = 60 ] && ok "with the full 30 attempts made by each wait (60 of the subject's own sleeps)" \
                    || bad "only $(slept) of the 60 sleeps happened -- a wait did not run 30 times"
[ "$(dumps)" = 60 ] && ok "and 60 dumps: the diagnostic read the dump that failed instead of asking again" \
                    || bad "$(dumps) dumps were made -- the giving-up path asked logcat a second time"

# ==================================================================================================
echo "== 4. the user-switch verdict: the LAST notify block is the one that counts =="
# ==================================================================================================
# docs 67 is the story: the first version read a line that path never prints and warned on every clean run.
# These are the four things the stub can leave in its log, and `stale` is the one that protects the
# extraction -- an older block that said "sent (oneway)" must not carry the verdict for a newer one.
reset; stublog noservice; run
want 'WARNING: cameraserver had not registered media.camera yet' "$OUT" "'no such service' is the WARNING, not the clean path"
want 'every connect\(\) will be refused' "$OUT" "and it says what that means for the run"
notwant 'the user switch was applied' "$OUT" "and does not claim the event landed"

reset; stublog local; run
want 'does not say the event was sent' "$OUT" "a stub answered with a local object is not a sent event"
want 'service-stub.log' "$OUT" "and the operator is pointed at the log to read"

reset; stublog silent; run
want 'does not say the event was sent' "$OUT" "a log that says nothing about it is also not a sent event"

reset; stublog stale; run
want 'WARNING: cameraserver had not registered media.camera yet' "$OUT" "an OLDER 'sent (oneway)' does not carry the verdict: the LAST block does"
notwant 'the user switch was applied' "$OUT" "so the clean path is not claimed on a stale reading"

echo
echo "   -- no stale client to kill:"
reset; FAKE_TESTCAM=""; run
want 'no stale test_camera' "$OUT" "an empty pgrep is reported as nothing to kill"
# `kill` is recorded by the transport stub's function, on its own line; the string `kill -9 "$p"` also
# appears inside the ssh action line, where it is the COMMAND TEXT and not an execution.
notwant '^kill ' "$(actions)" "and no kill is attempted"

# ==================================================================================================
echo "== 5. the mutations: each must change what a check above observes =="
# ==================================================================================================
# Every mutant is built from the REWRITTEN subject, by one `sed`, and the same `sed` is first required to
# match a line of the SHIPPED file -- otherwise a rename would leave the mutation silently testing nothing.
# It is written next to the subject, not in a subdirectory, because the script resolves its sibling
# `run-on-device.sh` relative to its OWN directory.
mutate() { # name, sed expression
  if cmp -s <(sed -e "$2" "$SRC") "$SRC"; then
    bad "mutation '$1': its sed matches no line of the shipped script, so nothing would be tested"
    return 1
  fi
  sed -e "$2" "$RUN" > "$REPO/mut-$1.sh"
  chmod +x "$REPO/mut-$1.sh"
  if cmp -s "$RUN" "$REPO/mut-$1.sh"; then
    bad "mutation '$1': the sed changes the shipped file but not the subject -- it did not land"
    return 1
  fi
  if ! bash -n "$REPO/mut-$1.sh" 2>/dev/null; then
    bad "mutation '$1': the mutant does not parse"
    return 1
  fi
  ok "mutation '$1': landed (a line of the shipped script is changed, and the mutant parses)"
  return 0
}

# (a) THE defect: the wait asks its question through a pipe again. With a dump larger than a pipe it is not
# a race -- the writer is killed, the reader's answer is thrown away, and the device is declared
# unregistered while its own log has the line on line 1.
if mutate oldpoll "$(pipe <<< "$OLDPOLL_SED")"; then
  reset; cp "$BIGF" "$W/logcat.txt"
  subj_run "$REPO/mut-oldpoll.sh"
  want 'has not registered after 90s' "$OUT" \
    "oldpoll, on a $NBIG-byte dump whose FIRST line is the registration: declares it unregistered"
  [ "$(slept)" = 30 ] && ok "and spends all 30 attempts of the first wait on an answer that was there" \
                      || bad "oldpoll slept $(slept) times -- the trap did not reproduce"
  reset; cp "$BIGF" "$W/logcat.txt"
  subj_run "$RUN"
  want 'provider registered' "$OUT" "while the shipped script reads the SAME dump and sees the line"
  [ "$(slept)" = 0 ] && ok "on its first pass, without sleeping once" \
                     || bad "the shipped script slept $(slept) times on the same dump"
fi

# (b) docs 67's regression: the verdict comes from anywhere in the tail rather than the last block.
if mutate anyblock 's#^if grep -q .sent (oneway). <<< "\$last_notify"; then#if grep -q "sent (oneway)" <<< "$tail"; then#'; then
  reset; stublog stale; subj_run "$REPO/mut-anyblock.sh"
  want 'the user switch was applied' "$OUT" "anyblock falls for the older block, which is exactly the false verdict docs 67 removed"
fi

# (c) the service name without its prefix: setprop accepts it and silently does nothing.
if mutate noprefix 's#ctl.restart vendor.camera-provider-2-4#ctl.restart camera-provider-2-4#'; then
  reset; subj_run "$REPO/mut-noprefix.sh"
  want 'ctl.restart camera-provider-2-4' "$(actions)" "noprefix restarts a service that does not exist (the shipped script does not)"
fi

# ==================================================================================================
echo "== 6. the shape, in the shipped file (the one thing this harness cannot see behaviourally here) =="
# ==================================================================================================
# Everything above is behavioural, and a behaviour proves only what the fixture made it do: a NEW
# verdict-bearing pipeline could be added to a path no scenario walks. So the file is also read.
risky() { grep -nE '\|[[:space:]]*(grep[[:space:]]+-[A-Za-z]*q|grep[[:space:]]+-[A-Za-z]*-[A-Za-z]*m|head([[:space:]]|$))' "$1" \
            | grep -vE '^[0-9]+:[[:space:]]*#'; }
R="$(risky "$SRC")"
# The five hits today are all `head -1` inside a string that is SENT TO THE DEVICE and run by its own sh,
# where pipefail is not set and the status is discarded -- inert, and left alone on purpose: rewriting
# four `head`s inside device commands would be a diff with no observable difference, on the procedure that
# has to run before every camera measurement. Anything else is a NEW verdict-shaped pipeline in a file
# that sets pipefail, which is what this section exists to catch.
STRAY="$(grep -vE "$(pipe <<< "$INERT_ALT")" <<< "$R")"
if [ -z "$STRAY" ]; then
  ok "every pipeline-early-exit left in the shipped file is one of the inert forms inside a device command"
else
  bad "a pipeline whose writer can be killed now feeds something in the shipped file:"
  sed 's/^/        | /' <<< "$STRAY"
fi
[ "$(grep -c . <<< "$R")" = 5 ] \
  && ok "five such lines, and they are the five this harness knows by name (a sixth gets read, not assumed)" \
  || bad "$(grep -c . <<< "$R") such lines: the file changed under this section's assumptions"

# Three fixtures, so the guard is a reading rather than a promise. The banned shape cannot be written
# literally in THIS file either: the family's meta-harness scans every harness that sets pipefail --
# including this one -- for it, and it does not care that this occurrence is test data. So `@` stands in
# for the pipe and is translated when the fixture is written.
{ printf '%s\n' 'set -uo pipefail'
  printf "if on_device 'logcat -b main -d' @ grep -q 'Registration complete'; then\n"
  printf '%s\n' '  :' 'fi'
  printf "%s\n" "# and on_device 'x' @ grep -q 'y' in a comment must not be counted"
} | tr '@' '|' > "$W/risky-fixture.sh"
{ printf '%s\n' 'set -uo pipefail'
  printf "dump=\$(on_device 'logcat -b main -d')\n"
  printf "if grep -q 'Registration complete' <<< \"\$dump\"; then\n"
  printf '%s\n' '  :' 'fi'
} > "$W/clean-fixture.sh"
want 'on_device' "$(risky "$W/risky-fixture.sh")" "the guard catches a verdict asked through a pipe (a fixture, so it is not a rubber stamp)"
notwant 'grep -q' "$(risky "$W/clean-fixture.sh")" "and does not punish the fix itself"
notwant 'comment must not be counted' "$(risky "$W/risky-fixture.sh")" "nor a mention of the shape in a comment (every explanation of this defect carries one)"

# ==================================================================================================
echo "== 7. this harness's own citation =="
# ==================================================================================================
HEALTH="$HERE/zl1-health-check.sh"
if [ -r "$HEALTH" ]; then
  cited=$(sed -e 's/always "/ /g' -e 's/"$//' "$HEALTH" | tr '\n' ' ' |
            sed -n 's/.*zl1-camera-stack-reset-selftest.sh[ ,(]*\([0-9][0-9]*\) checks.*/\1/p')
  total=$((PASS + FAIL + 1))
  if [ -z "$cited" ]; then
    bad "the health check no longer cites this harness's count -- either the citation is gone or its wording changed"
  elif [ "$cited" = "$total" ]; then
    ok "the health check cites $cited checks, and this run has exactly that many"
  else
    bad "the health check cites $cited checks, but this harness has $total -- fix host/zl1-health-check.sh"
  fi
else
  bad "cannot read $HEALTH -- its citations are unchecked"
fi

echo
echo "pass=$PASS fail=$FAIL"
if [ "$KEEP" = 1 ]; then
  echo "kept: $W"
else
  rm -rf "$W"
fi
[ "$FAIL" = 0 ]
