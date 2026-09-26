#!/usr/bin/env bash
# zl1 camera-app test -- offline self-test. Host-side, touches no device, needs no phone.
#
# Why this exists. `scripts/host/zl1-camera-app-test.sh` is health-check item 1 and the only instrument
# for the one camera question still open (does the app's window reach the screen), and it was the last
# peripheral instrument with no offline verification -- the post-mortem, boot-address, orientation,
# thermal, installers, loc-fp and gps scripts all have one now. Writing this one found four defects, all
# of the shape this project keeps finding: a number or a verdict that cannot report what it claims.
#
#   1. the headline rate was 100x its own unit. `(b-a) * 100 / secs` against a header that calls the
#      column "ticks/s" and quotes the band as 1.2 / 20-50 (docs 68 section 5, HZ=100). So the absolute
#      gate `B >= 8` -- written to mean "8 ticks/s, well above the 1.2 baseline" -- was 0.08/s and could
#      not fail for anything but a stopped compositor. Section 3 pins the unit with literal numbers.
#   2. `n=$(grep -c PAT F || echo 0)`: grep -c prints "0" AND exits 1 on no match, so the fallback
#      appended a second "0", the value carried an embedded newline, and the evidence table printed a
#      stray line -- on exactly the rows that matter ('ASSERT' and 'caught signal' are supposed to be 0).
#   3. the verdict never used whether the app had launched. Step 3 knew and printed it; the verdict
#      ignored it, so a launcher failure came out as "the app is not being composited".
#   4. `--run-seconds` was documented as "must exceed 2 x --seconds" and never checked, although the
#      real requirement is --seconds + 8 (window B starts 6 s after the launch). Below it, the app is
#      killed mid-window and the verdict blames it.
#   Plus: the evidence table counted only `app.err`, calling it "the app's own evidence", although which
#   stream Qt/QML write to is not established by that script (docs 102/103's ownership rule) -- and a
#   window that could not be read produced no verdict line at all.
#
# Section 5 is the fifth thing, and it is not a defect this harness found in the old text -- it is the
# defect the instrument's FIRST DEVICE RUN exposed (2026-09-26): the script's verdict said "the app is
# not being composited, whatever it reports", which reads as a statement about the SHELL and was built
# from a measurement of the compositor alone. The app itself burned 0.1 ticks/s while it ran (eleven
# threads, the main one in binder_thread_read) -- it never painted, so the compositor had nothing to
# composite and its number was never about the app. Window B now reads BOTH rates over one sleep and
# the verdict separates the three worlds (never painted / painting but not composited / composited),
# with the app's threads' wchan and the session Mir socket's connection count printed beside them.
# Section 5 pins all of it with the fixture's own two rates, including the readings that FAILED
# (<unreadable>, never 0.0).
#
# How it works: **the transport stub IS the device.** `ssh` and `scp` strip their options and run the
# remote command locally, against a fake root, with the device's tools (lxc-info, busctl, pgrep,
# nsenter) stubbed and `sleep` acting as the clock -- it advances a fake /proc/<pid>/stat, so the two
# ticks windows produce real jiffies through the real awk field arithmetic. The fixture is therefore a
# device whose compositor burns a chosen number of jiffies per window.
#
# Usage: zl1-camera-app-test-selftest.sh [--keep]
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
SRC="$HERE/zl1-camera-app-test.sh"
LAUNCHER="$HERE/../device/zl1-camapp-launch.py"
[ -r "$SRC" ] || { echo "cannot read $SRC" >&2; exit 2; }
[ -r "$LAUNCHER" ] || { echo "cannot read $LAUNCHER" >&2; exit 2; }

W="${TMPDIR:-/tmp}/zl1-camera-selftest"
REPO="$W/repo"
FR="$W/dev"
STUB="$W/stub"
ACT="$W/actions"
rm -rf "$W"
mkdir -p "$REPO/scripts/host" "$REPO/scripts/device" "$STUB" \
         "$FR/proc/device-tree" "$FR/tmp" "$FR/userdata/zl1-hybris/lib" \
         "$FR/usr/share/click/preinstalled/camera.ubports/4.1.1" || exit 2

# --- the script under test, rewritten into the fake device ---------------------------------------
#
# Only DEVICE paths are rewritten (+ the one `kill`, see below): the transport runs the remote command
# locally, so everything the command touches has to live in the fake root. `$W/repo` mirrors the repo
# layout because the script derives `repo` from its own location and then reaches for two siblings
# (the launcher it scps, and the screenshot helper it runs by path).
#
# The /tmp rewrite uses `/tmp/zl1-camapp\.` -- a LITERAL dot, which is what keeps the launcher's own
# path (`/tmp/zl1-camapp-launch.py`, a `-`) out of the rewrite.
#
# The kill rewrite is single-quoted, and not for style: the line it targets sits INSIDE a double-quoted
# ssh command, so the file really contains `\$q` with a backslash -- and in a double-quoted sed script
# the shell eats that backslash, leaving a pattern that matches nothing. Silently: the sed exits 0, and
# the only symptom would be a REAL kill signalling a host process.
#
# **It replaced BOTH kill lines, and it is the reason a real defect got as far as the device.** The
# instrument used to send `kill \${p%/cmdline}`, i.e. `kill /proc/3957277`; the device's /bin/sh is dash
# and its kill builtin takes PROCESS IDS (`kill: /proc/3957277: arguments must be process or job IDs`,
# rc=1). The rewrite turned that into `"$STUB/kill" /proc/<pid>`, and the stub -- which this file writes --
# accepted anything, so the fixture AGREED with a form the device rejects, and the assertions below even
# REQUIRED it (`^kill /[^ ]*proc/[0-9]+$`). The stub now refuses a non-numeric pid the way dash does, and
# those assertions require `^kill [0-9]+$`: the fixture has the device's shape, not the shape the script
# happened to write.
sed -e "s#/proc/#$FR/proc/#g" \
    -e "s#/tmp/zl1-camapp\.#$FR/tmp/zl1-camapp.#g" \
    -e "s#/userdata/zl1-hybris/#$FR/userdata/zl1-hybris/#g" \
    -e "s#/usr/share/click/preinstalled/camera.ubports#$FR/usr/share/click/preinstalled/camera.ubports#g" \
    -e 's#kill \\$q 2>/dev/null#"'"$STUB"'/kill" \\$q 2>/dev/null#g' \
    -e 's#kill -9 \\$q 2>/dev/null#"'"$STUB"'/kill" -9 \\$q 2>/dev/null#g' \
    "$SRC" > "$REPO/scripts/host/zl1-camera-app-test.sh"
cp "$LAUNCHER" "$REPO/scripts/device/zl1-camapp-launch.py"
bash -n "$REPO/scripts/host/zl1-camera-app-test.sh" || { echo "the rewritten script does not parse" >&2; exit 2; }
# The landing count, because one missed path means the command reads THIS machine while every scenario
# still "passes" (the defect docs 98 found in its own harness). `/proc/` is the one that matters: the
# compositor walk, the ticks windows and the app walk all go through it.
n=$(grep -c '/proc/' "$SRC")
m=$(grep -c "$FR/proc/" "$REPO/scripts/host/zl1-camera-app-test.sh")
[ "$n" = "$m" ] || { echo "only $m of $n '/proc/' occurrences were rewritten" >&2; exit 2; }
grep -qF "$STUB/kill" "$REPO/scripts/host/zl1-camera-app-test.sh" \
  || { echo "the kill rewrite did not land (kill is a shell BUILTIN: a PATH stub cannot intercept it, and a real kill would signal a host process)" >&2; exit 2; }
grep -qF "APP_DIR=$FR/usr/share/click/preinstalled/camera.ubports/4.1.1" "$REPO/scripts/host/zl1-camera-app-test.sh" \
  || { echo "APP_DIR was not rewritten -- APP_BIN is derived from it, so the app walk would never match the fixture" >&2; exit 2; }

# --- the stubs -----------------------------------------------------------------------------------
#
# `ssh`: strip the connection options and the host, then run the remote command LOCALLY. `$*` is the
# single command argument ssh_d passes, so this is exactly what the device would have run. Newlines are
# flattened into the action log so that a whole invocation is ONE greppable line.
cat > "$STUB/ssh" <<EOF
#!/bin/sh
printf 'ssh %s\n' "\$(printf '%s' "\$*" | tr '\n' ' ')" >> "$ACT"
while [ \$# -gt 0 ]; do
  case "\$1" in -o) shift 2 ;; -*) shift ;; *) break ;; esac
done
[ \$# -gt 0 ] && shift          # the host
sh -c "\$*"
EOF
# `scp`: the two directions this script uses. A "host:" destination is a push into the fake device; a
# "host:" source is a pull of the app's own captured output, which is what the evidence table greps.
# Both remote paths were already rewritten into $FR by the sed above, so the prefix is added only when
# it is not already there -- prepending it twice is an easy way to make a pull of a real file look like
# an app that printed nothing.
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
# `sleep` IS the clock: it advances the compositor's utime (and is where the app is allowed to die). It
# records which call it is, so a scenario can give window A and window B different rates. Every variable
# that has to come from the run's environment is escaped (`\$`), because this heredoc is unquoted: an
# unescaped `$W_COM_PID` would be substituted at WRITE time, when it is empty, and the stat file would
# land in `$FR/proc//stat` -- a compositor whose ticks never move.
cat > "$STUB/sleep" <<EOF
#!/bin/sh
printf 'sleep %s\n' "\$*" >> "$ACT"
n=\$(( \$(cat "$W/sleepc" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$W/sleepc"
inc=\$(sed -n "\${n}p" "$W/rates" 2>/dev/null); inc=\${inc:-0}
total=\$(( \$(cat "$W/ticks" 2>/dev/null || echo 0) + inc )); echo "\$total" > "$W/ticks"
# utime is post-strip field 12 and stime field 13; the comm deliberately CONTAINS A SPACE (allowed by
# the kernel, up to 15 chars) so that the sub() which strips it is exercised rather than assumed.
if [ "\$FAKE_COM_STAT" = 0 ] && [ "\$n" -ge 4 ]; then
  # The compositor's stat becomes unreadable AFTER the startup sleep (call 4): window A is read
  # normally, window B's compositor reading fails. Removing it from the start would be simpler and would
  # break the fixture in a way that looks like a defect in the instrument -- the window-A ssh command
  # exits BEFORE its sleep when the stat cannot be read, so the sleep counter shifts and every later
  # rate in rates.app lands on the wrong window (which reads back as "the app burned 0.0/s"). The rates
  # are indexed by sleep CALL, so a fixture that skips one silently renumbers all the others.
  # (The stderr redirect goes BEFORE the ">" on every write below: redirections are applied left to
  # right, so with 2>/dev/null after it, a failed write prints on the instrument's own stderr and, in
  # dash, takes this stub down with it.)
  rm -f "$FR/proc/\$W_COM_PID/stat" 2>/dev/null
else
  {
    printf '%s (lomiri system-c) S' "\$W_COM_PID"
    i=1; while [ "\$i" -le 10 ]; do printf ' %s' "\$i"; i=\$((i+1)); done
    printf ' %s 0' "\$total"
    i=14; while [ "\$i" -le 50 ]; do printf ' %s' "\$i"; i=\$((i+1)); done
    printf '\n'
  } 2>/dev/null > "$FR/proc/\$W_COM_PID/stat"
fi
# The app's OWN stat, advanced by its own rate list, and written only while the app's cmdline exists: a
# dead process has no /proc entry, and a fixture that kept the stat alive after the app "died" would
# hand window B a rate for a process that is not there -- which is the reading the instrument refuses
# to take (it wants "-", because 0 means "the app burned no CPU", a different statement).
# FAKE_APP_STAT=0 makes the stat unreadable while the process stays alive: that is the "a reading that
# failed is not an app that did nothing" branch.
if [ -f "$FR/proc/\$FAKE_APP_PID/cmdline" ] && [ "\$FAKE_APP_STAT" != 0 ]; then
  inca=\$(sed -n "\${n}p" "$W/rates.app" 2>/dev/null); inca=\${inca:-0}
  ta=\$(( \$(cat "$W/appticks" 2>/dev/null || echo 0) + inca )); echo "\$ta" > "$W/appticks"
  {
    printf '%s (lomiri-camera-a) S' "\$FAKE_APP_PID"
    i=1; while [ "\$i" -le 10 ]; do printf ' %s' "\$i"; i=\$((i+1)); done
    printf ' %s 0' "\$ta"
    i=14; while [ "\$i" -le 50 ]; do printf ' %s' "\$i"; i=\$((i+1)); done
    printf '\n'
  } 2>/dev/null > "$FR/proc/\$FAKE_APP_PID/stat"
elif [ "\$FAKE_APP_STAT" = 0 ]; then
  rm -f "$FR/proc/\$FAKE_APP_PID/stat" 2>/dev/null
fi
# The app's own captured output, installed here so that it is in place before step 6 pulls it (the
# launch is backgrounded through setsid, so nothing guarantees when -- or whether -- it has run).
[ -f "$W/app.out.fixture" ] && cat "$W/app.out.fixture" > "$FR/tmp/zl1-camapp.out"
[ -f "$W/app.err.fixture" ] && cat "$W/app.err.fixture" > "$FR/tmp/zl1-camapp.err"
# The app APPEARS when the launch step's sleep runs (call 3) and stays: that is what the launch step's
# own walk reads one second after the fork. S_LAUNCH=0 is a launcher that exited immediately, so no app
# ever appears -- which the launch step reports as "NOT launched".
if [ "\$n" = 3 ] || [ "\$n" = 4 ]; then
  [ "\$FAKE_LAUNCH" != 0 ] && cp "$W/app.cmdline.fixture" "$FR/proc/\$FAKE_APP_PID/cmdline" 2>/dev/null
fi
# Model the app dying while the 6 s of QML/EGL startup pass (call 4 is that sleep).
if [ "\$n" = 4 ]; then
  case "\$FAKE_ALIVE" in
  1) cp "$W/app.cmdline.fixture" "$FR/proc/\$FAKE_APP_PID/cmdline" 2>/dev/null ;;
  0) rm -f "$FR/proc/\$FAKE_APP_PID/cmdline" ;;
  esac
fi
# The session's Mir socket: the app's connection is there while it is alive, and gone once it is
# stopped. The pairing (before / during / after) is what attributes the delta to the app, so a fixture
# that never moved the count could not tell a working pairing from three prints of the same number.
if [ -f "$FR/proc/\$FAKE_APP_PID/cmdline" ]; then
  cp "$W/mir.withapp" "$FR/proc/net/unix" 2>/dev/null
else
  cp "$W/mir.before" "$FR/proc/net/unix" 2>/dev/null
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
# The launcher must NOT actually run: it setuids to 32011 and would exec the real app. It is recorded
# and simulated -- the app's presence is the fixture cmdline, which is what the script's own walk reads.
cat > "$STUB/nsenter" <<EOF
#!/bin/sh
printf 'nsenter %s\n' "\$(printf '%s' "\$*" | tr '\n' ' ')" >> "$ACT"
exit 0
EOF
cat > "$STUB/kill" <<EOF
#!/bin/sh
printf 'kill %s\n' "\$*" >> "$ACT"
# **A NON-NUMERIC OPERAND IS REFUSED, because that is what the device does.** dash's kill builtin is not
# bash's: \`kill /proc/3957277\` answers \`kill: /proc/3957277: arguments must be process or job IDs\` and
# exits 1, signalling nothing. Measured on the zl1 on 2026-09-26 (docs 180). A stub that accepted a path
# would make the instrument's own stop look like it worked while nothing was ever signalled -- which is
# exactly how a real device run reported \`STILL RUNNING after SIGKILL\` about a process a numeric kill
# ends in the same second. The instrument's \`2>/dev/null\` is modelled too: the operand is checked, not
# the message.
for a in "\$@"; do
  case "\$a" in
  -9|-15|-TERM|-KILL|-[A-Za-z]*) continue ;;
  ''|*[!0-9]*) exit 1 ;;
  esac
done
# **THE STUB IS WHERE A HOST'S \`timeout\` CANNOT REACH -- the instrument's stop always escalates, and the
# stub's job is to make BOTH branches of that escalation reachable.** Which branch a device takes is a
# reading, not a fixture's business: the run of 2026-09-26 printed \`app stopped: stopped by SIGTERM\`, so
# on the device the FIRST signal is the one that works. The 22 minutes of leftover that made an earlier
# version of this tree claim the app "ignores SIGTERM" was a stop that never sent a signal at all (docs
# 180's operand defect), not a signal the app shrugged off -- so \`FAKE_SIGTERM_WORKS=1\` reproduces the
# DEVICE, and the default (0) is the harder fixture, kept because "stopped by SIGTERM" would otherwise
# always win and the escalation below would be untestable.
#
# Whichever signal ends it, the /proc entry goes with it (and with it the stat and the Mir connection),
# which is what the "after" count and the NEXT run's premise check read.
if [ "\$FAKE_SIGTERM_WORKS" != 0 ] && [ "\$1" != -9 ]; then
  rm -f "$FR/proc/\$FAKE_APP_PID/cmdline" "$FR/proc/\$FAKE_APP_PID/stat" 2>/dev/null
  exit 0
fi
case "\$1" in
-9) rm -f "$FR/proc/\$FAKE_APP_PID/cmdline" "$FR/proc/\$FAKE_APP_PID/stat" 2>/dev/null ;;
esac
exit 0
EOF
cat > "$STUB/identify" <<EOF
#!/bin/sh
printf 'PNG 1080x1920 1080x1920+0+0 8-bit sRGB 2c 12345B 0.000u 0:00.000\n'
exit 0
EOF
chmod +x "$STUB"/*
export ACT W FR

# The screenshot helper, which the script runs by path from its own repo: a stub, because the real one
# ssh's and grabs. Both behaviours, so that "the grab failed" is a reachable branch and not a comment.
write_shot_stub() { # $1 = ok|fail
  cat > "$REPO/scripts/host/zl1-screenshot.sh" <<EOF
#!/bin/sh
printf 'screenshot %s\n' "\$*" >> "$ACT"
out=""
while [ \$# -gt 0 ]; do case "\$1" in --out) out="\$2"; shift 2 ;; *) shift ;; esac; done
[ -n "\$out" ] && printf 'not really a png\n' > "\$out"
[ "$1" = ok ] && exit 0 || exit 1
EOF
  chmod +x "$REPO/scripts/host/zl1-screenshot.sh"
}

# --- fixtures ------------------------------------------------------------------------------------
SHELL_PID=5000
COMP_PID=6000
CONTAINER_PID=700
APP_PID=6100
APP_BIN_FAKE="$FR/usr/share/click/preinstalled/camera.ubports/4.1.1/lomiri-camera-app"

# /proc/net/unix as the kernel prints it. Field 6 is the state -- 01 for the listener, 03 for an
# established connection -- and the path is the last field, so a counter that forgot the state column or
# ignored the path prints a different number against THIS fixture (the `bus` rows exist for exactly
# that: the same shape, another path).
mir_unix() { # $1 = number of established connections on the session's Mir socket
  printf 'Num       RefCount Protocol Flags    Type St Inode Path\n'
  printf '0000000000000000: 00000002 00000000 00010000 0001 01 309655 /run/user/32011/mir_socket\n'
  i=1
  while [ "$i" -le "$1" ]; do
    printf '0000000000000000: 00000003 00000000 00000000 0001 03 %s /run/user/32011/mir_socket\n' "$((100000 + i))"
    i=$((i + 1))
  done
  printf '0000000000000000: 00000002 00000000 00010000 0001 01 76460 /run/user/32011/bus\n'
  printf '0000000000000000: 00000003 00000000 00000000 0001 03 76461 /run/user/32011/bus\n'
}
mir_unix 4 > "$W/mir.before"       # the session before the app starts
mir_unix 5 > "$W/mir.withapp"      # ... and with the app's own connection established

# The device-tree model, with its trailing NUL, as the guard's `tr -d '\0'` expects to find it. Without
# this the default fixture is a broken device and every scenario reads "this is not the zl1".
printf '%s\0' 'MSM 8996pro + PMI8996 LE_ZL1' > "$FR/proc/device-tree/model"
# A real /proc/<pid>/cmdline is NUL-separated, not newline-separated -- the walk's `tr '\0' ' '` is why
# the fixture has to be, too.
printf '%s\0--foo\0' "$APP_BIN_FAKE" > "$W/app.cmdline.fixture"
printf '(ii) 1 1\n' > "$W/outputs.on"
printf '(ii) 0 0\n' > "$W/outputs.off"
# The app's own output, in the streams the real ones land in. zl1-camapp-launch.py writes its own
# messages with `file=sys.stderr` ("launching ...", "dropped to uid ..."), and Qt's message handler --
# which is where console.log ends up -- writes to stderr too, so a real app.out is usually EMPTY. That
# is why the probe counts BOTH files, and it is also why this fixture puts ONE line in app.out: with an
# all-zero out column the harness could not tell "the column is read" from "the column is hardcoded",
# which is exactly the defect it exists to catch. The line is constructed, and it makes one row read
# "2 err 1 out" -- two different numbers, so a table that either hardcodes a column or reads one file
# twice prints something this fixture can fail on.
cat > "$W/app.err.fixture" <<'EOF'
launching /usr/share/click/preinstalled/camera.ubports/4.1.1/lomiri-camera-app (APP_ID=camera.ubports_camera_4.1.1) with 41 environment variables from the session
dropped to uid 32011 gid 32011
Creating a QMirClientScreen now
Creating a QMirClientScreen now
Camera app directory "/usr/share/click/preinstalled/camera.ubports/4.1.1"
Added camera "0"
Added camera "1"
** Application is now active
EOF
cat > "$W/app.out.fixture" <<'EOF'
lomiri-camera-app: Creating a QMirClientScreen
EOF

# --- the checks ----------------------------------------------------------------------------------
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
want()    { if grep -Eq -- "$1" <<< "$2"; then ok "$3"; else bad "$3"; sed 's/^/        | /' <<< "$2"; fi; }
notwant() { if grep -Eq -- "$1" <<< "$2"; then bad "$3"; grep -E -- "$1" <<< "$2" | sed 's/^/        | /'; else ok "$3"; fi; }
wantl()   { if grep -qF -- "$1" <<< "$2"; then ok "$3"; else bad "$3"; sed 's/^/        | /' <<< "$2"; fi; }
# The rate the script printed for a window, from its own "LABEL jiffies rate" line.
# The script prints its note on the SAME line ("A 12 1.0   (label jiffies ticks_per_second; ...)"), so
# this must not test NF==3: it checks the two numeric columns and nothing else.
win3() { printf '%s\n' "$OUT" | awk -v l="$1" '$1==l && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9.]+$/ {print $3; exit}'; }

RUN_SECS=30
S_CONTAINER=$CONTAINER_PID; S_SHELL=$SHELL_PID
S_ALIVE=1; S_RATE_A=12; S_RATE_B=240
# The healthy device, every time. The flags that select a BROKEN device are passed through run()'s
# environment at run time (S_ALIVE, S_CONTAINER, S_SHELL) or written into the fake root after this call
# (the model, the missing app cmdline, the display state) -- NOT set as variables before it, because
# env_reset overwrites them and the scenario then silently tests the healthy device instead.
env_reset() {
  S_CONTAINER=$CONTAINER_PID; S_SHELL=$SHELL_PID
  S_ALIVE=1; S_RATE_A=12; S_RATE_B=240; S_RATE_APP=84; S_APP_STAT=1; S_COM_STAT=1
  S_LAUNCH=1
  write_shot_stub ok
  rm -f "$W/display-on" "$W/ticks" "$W/sleepc"
  # sleeps in order: 3 (step 1), <A> (window A), 1 (step 3), 6 (step 3 end), <B> (window B), 1 (step 6)
  printf '0\n%s\n0\n0\n%s\n0\n' "$S_RATE_A" "$S_RATE_B" > "$W/rates"
  # The app's own jiffies, on the same call indices. Only the window B sleep (call 5) matters: window B
  # is where the app's stat is read, at both ends of the same sleep. 84 jiffies over 12 s is 7.0/s --
  # above the 5/s the instrument calls "painting", so the default fixture is an app that paints and the
  # scenarios that are about the COMPOSITOR's branches are about an app that is drawing.
  printf '0\n0\n0\n0\n%s\n0\n' "$S_RATE_APP" > "$W/rates.app"
  rm -f "$W/appticks"
  rm -rf "$FR/proc/$APP_PID" "$FR/proc/$COMP_PID" "$FR/proc/net"
  mkdir -p "$FR/proc/$SHELL_PID" "$FR/proc/net" "$FR/proc/$APP_PID/task" "$FR/proc/$COMP_PID"
  printf '/usr/sbin/lomiri-system-compositor --enable\n' > "$FR/proc/$COMP_PID/cmdline"
  # The shell's own environment is where the instrument reads the session's Mir socket from
  # (MIR_SERVER_FILE, the real device's value on 2026-09-26). NUL-separated, like a real environ.
  printf 'DESKTOP_SESSION=ubuntu-touch\0MIR_SERVER_FILE=/run/user/32011/mir_socket\0' > "$FR/proc/$SHELL_PID/environ"
  cp "$W/mir.before" "$FR/proc/net/unix"
  # The app's own /proc entry: cmdline for the walk, stat and task/ for the "state=" and "threads="
  # fields of the alive line (an empty state reads as a dead process to a human, and the harness would
  # then be testing a device nobody ever sees). The four wchan names are the ones this app really had on
  # 2026-09-26 -- main thread in binder_thread_read, the rest in futex/poll -- and two of them are the
  # same symbol so that the COUNT is exercised and not just the list.
  # NO app process: the fixture's app appears when the LAUNCH step runs (at sleep call 3), exactly as
  # on the device. It used to be present from the start -- invisible until the instrument grew a premise
  # check ("is an app already running?"), which under the old fixture would have refused every scenario.
  rm -f "$FR/proc/$APP_PID/cmdline" "$FR/proc/$APP_PID/stat"
  for t in 1 2 3 4; do mkdir -p "$FR/proc/$APP_PID/task/$t"; done
  printf 'futex_wait_queue_me'  > "$FR/proc/$APP_PID/task/1/wchan"
  printf 'futex_wait_queue_me'  > "$FR/proc/$APP_PID/task/2/wchan"
  printf 'binder_thread_read'  > "$FR/proc/$APP_PID/task/3/wchan"
  printf 'poll_schedule_timeout' > "$FR/proc/$APP_PID/task/4/wchan"
  rm -f "$FR/proc/$APP_PID/cmdline.keep"
  # ActiveOutputs answers $W/outputs.off while no display-on marker exists -- i.e. it is what the run
  # FINDS (the healthy default is off, which is the state every previous camera run was made in).
  printf '(ii) 0 0\n' > "$W/outputs.off"
  printf '(ii) 1 1\n' > "$W/outputs.on"
  OUTDIR="$W/out"; rm -rf "$OUTDIR"; mkdir -p "$OUTDIR"
  printf '%s\0' 'MSM 8996pro + PMI8996 LE_ZL1' > "$FR/proc/device-tree/model"
}
run() { # $1 = extra arguments for the script (may be empty)
  : > "$ACT"
  OUT="$( cd "$W" && env PATH="$STUB:$PATH" ZL1_HOST=fake \
      FAKE_CONTAINER="$S_CONTAINER" FAKE_SHELL="$S_SHELL" FAKE_ALIVE="$S_ALIVE" \
      FAKE_APP_PID="$APP_PID" FAKE_APP_STAT="$S_APP_STAT" FAKE_COM_STAT="$S_COM_STAT" \
      FAKE_LAUNCH="$S_LAUNCH" W_COM_PID="$COMP_PID" \
      FAKE_SIGTERM_WORKS="${SIGTERM_WORKS:-0}" \
      bash "$REPO/scripts/host/zl1-camera-app-test.sh" \
        --seconds 12 --run-seconds "$RUN_SECS" --outdir "$OUTDIR" \
        --extra-args "--mode=x" $1 2>&1 )"
  RC=$?
}

echo "zl1 camera-app test -- offline self-test"
echo "  script under test: $SRC"
echo "  fake device:       $FR"
echo

# ==================================================================================================
echo "== 1. the guard: not the zl1, and nothing is touched =="
# ==================================================================================================
env_reset
printf '%s\0' 'Some Other Phone' > "$FR/proc/device-tree/model"
run ""
[ "$RC" = 1 ] && ok "a different device-tree model exits 1" || bad "it exited $RC on the wrong device"
want 'this is not the zl1' "$OUT" "and says which model it saw"
[ -s "$ACT" ] || bad "the guard should read the model over ssh -- no action at all means it never checked"
notwant '^busctl .*call' "$(cat "$ACT")" "and it turns no display on for a device it just refused"
[ -e "$OUTDIR/shot-during-app.png" ] && bad "it wrote a screenshot on the wrong device" || ok "and grabs nothing"

# ==================================================================================================
echo
echo "== 2. the parameter guard: the app must outlive window B (it was never checked) =="
# ==================================================================================================
env_reset
RUN_SECS=10   # window B starts 6 s after the launch and lasts 12, so 10 kills the app mid-window
run ""
[ "$RC" = 2 ] && ok "--run-seconds below seconds+6+2 is refused with exit 2" || bad "it exited $RC instead of refusing"
want 'is too small for --seconds' "$OUT" "and names the flag and what it is too small for"
want 'want --run-seconds >= 18' "$OUT" "with the number it needs (--seconds + 6)"
[ -s "$ACT" ] && { bad "it touched the device before refusing:"; head -3 "$ACT" | sed 's/^/        | /'; } \
              || ok "and it refuses before touching the device at all (not one ssh)"
RUN_SECS=30
env_reset

# ==================================================================================================
echo
echo "== 3. the ticks unit: jiffies per second, and the gate that was 100x too weak =="
# ==================================================================================================
# The unit must be the documented one: 12 jiffies over a 12 s window IS 1.0 ticks/s (docs 68 section
# 5's idle baseline), not 100.0.
env_reset
run ""
A_RATE="$(win3 A)"; B_RATE="$(win3 B)"
[ "$A_RATE" = "1.0" ] && ok "12 jiffies over 12 s is reported as 1.0 ticks/s (the documented unit)" \
                     || bad "the A window printed '$A_RATE', want 1.0 -- the old code printed 100.0 here"
[ "$B_RATE" = "20.0" ] && ok "and 240 jiffies as 20.0 (inside the 20-50/s band, docs 68)" \
                      || bad "the B window printed '$B_RATE', want 20.0"
want 'compositor with no client: +1\.0/s' "$OUT" "the verdict quotes the baseline in that unit"
want 'compositor with the app: +20\.0/s' "$OUT" "and window B beside it"
want 'the compositor is doing work for the app' "$OUT" "B >= 4A and B >= 8 -> composited"

# The distinction the old arithmetic could not make: a compositor that is *barely* moving. Under
# (b-a)*100/secs this reads 8.0 -> 250.0 and passes BOTH gates ("composited"); in the documented unit it
# is 0.1 -> 2.5, which is over 4x the baseline and nowhere near the 8/s bar.
env_reset
printf '0\n1\n0\n0\n30\n0\n' > "$W/rates"
run ""
[ "$(win3 A)" = "0.1" ] && ok "a nearly idle window is reported as 0.1 ticks/s, not 8" || bad "A printed '$(win3 A)', want 0.1"
[ "$(win3 B)" = "2.5" ] && ok "and its partner as 2.5, not 250" || bad "B printed '$(win3 B)', want 2.5"
want 'inconclusive' "$OUT" "so it is inconclusive: over 4x the baseline but under the 8/s bar"
notwant 'the compositor is doing work for the app' "$OUT" "and it does not claim the app is being composited"

# The other two branches of the ratio test.
env_reset
printf '0\n12\n0\n0\n18\n0\n' > "$W/rates"
run ""
want 'NO extra compositor work' "$OUT" "B <= A + 2 -> the app's window is not being composited"
env_reset
printf '0\n12\n0\n0\n720\n0\n' > "$W/rates"
run ""
want 'the compositor is doing work for the app' "$OUT" "and a large B still passes (60/s)"

# ==================================================================================================
echo
echo "== 4. the app's own state decides what the numbers mean =="
# ==================================================================================================
# The launcher failed: step 3 says so. The verdict used to ignore it and announce "the app is not being
# composited" -- a verdict about an app that never existed.
env_reset
S_LAUNCH=0    # the launcher exited immediately: no app process ever appears
run ""
want 'NOT launched' "$OUT" "step 3 reports that the launcher exited immediately"
want 'the app NEVER STARTED' "$OUT" "and the verdict says THAT"
notwant 'the app is not being composited' "$OUT" "it does not blame the compositor for a launcher failure"
want 'not a compositor one' "$OUT" "and it points at the launcher and its own output instead"
notwant "the app's own rate: " "$OUT" "with no app process there is no app rate line at all (not a zero)"

# It launched and then died before window B ended.
env_reset
S_ALIVE=0
run ""
want 'launched pid' "$OUT" "step 3 found the app"
want 'NOT running at the end of window B' "$OUT" "and window B says the app is gone"
want 'about the display, not about the app' "$OUT" "with what that means for the number above it"
notwant 'the app NEVER STARTED' "$OUT" "the two failure modes are not confused for one another"

env_reset
run ""
want 'alive pid=' "$OUT" "with a healthy run, the app is alive at the end of window B"
notwant 'NEVER STARTED' "$OUT" "and neither failure line appears"
notwant 'NOT running at the end' "$OUT" "in either form"

# ==================================================================================================
echo
echo "== 5. the app's own rate: the reading whose absence produced a verdict about the wrong subject =="
# ==================================================================================================
# 2026-09-26, the instrument's first device run: it printed "NO extra compositor work: the app is not
# being composited, whatever it reports" -- a sentence about the SHELL, built from a measurement of the
# compositor. Measured afterwards by hand, the app itself burned **0.1 ticks/s**: it never painted, so
# the compositor had nothing to composite and its number was never about the app. Window B now reads
# both rates over one sleep, and these scenarios pin the three worlds apart: the app is painting, the
# app is not painting, and the app's own reading failed.
env_reset
run ""
want "the app's own rate: 7.0/s" "$OUT" "the app's own rate is printed, in the same unit as the compositor's"
want "the app's own burn: +7.0/s" "$OUT" "and it stands in the verdict block beside the two compositor numbers"
want 'app threads waiting in: futex_wait_queue_me 2, ' "$OUT" "the threads' wchan is printed, counted, and most frequent first"
want 'the session Mir socket: +4 before the launch, 5 while it ran, 4 after it was stopped' "$OUT" "and the Mir connection count appears and disappears with the app"

# The real reading, replayed: an app that burns 1 jiffy in the window (0.1/s), under the SAME two
# compositor numbers that section 3 reads as "composited".
env_reset
printf '0\n0\n0\n0\n1\n0\n' > "$W/rates.app"
run ""
want "the app's own rate: 0.1/s" "$OUT" "an app that burned 0.1/s is read as such"
want 'the app is NOT PAINTING' "$OUT" "and a busy compositor under it is reported as NOT the app's work"
want 'that work is NOT the app.s' "$OUT" "with the sentence that says so"
notwant 'the compositor is doing work for the app' "$OUT" "the ratio test must NOT be applied: B=240 against A=12 is 'composited' in section 3"
notwant "the app's window is being composited" "$OUT" "and nothing anywhere claims the app is being composited"

# The same idle app under a compositor that stayed at its baseline -- the reading that was taken.
env_reset
printf '0\n12\n0\n0\n18\n0\n' > "$W/rates"
printf '0\n0\n0\n0\n1\n0\n' > "$W/rates.app"
run ""
want 'THE APP NEVER PAINTED' "$OUT" "an app that did nothing over an idle compositor is 'the app never painted'"
want 'a measurement of the DISPLAY, not of the app' "$OUT" "with what the compositor's number is then a measurement of"
notwant 'NO extra compositor work' "$OUT" "and NOT the old sentence, which read as a statement about the shell"
notwant 'the app is not being composited' "$OUT" "in either of its forms"

# Between the two lines: above 1/s (not idle) and under 5/s (not obviously painting).
env_reset
printf '0\n0\n0\n0\n24\n0\n' > "$W/rates.app"     # 2.0/s
run ""
want "the app's own rate: 2.0/s" "$OUT" "a rate between the two lines is still printed as a number"
want 'inconclusive: the app.s own rate is 2.0/s' "$OUT" "and the verdict refuses to choose a story"
notwant 'THE APP NEVER PAINTED' "$OUT" "it is not called idle"
notwant 'the compositor is doing work for the app' "$OUT" "and the compositor ratio is not consulted at all"

# The app's stat unreadable while the process is alive: a FAILED reading, not an app that did nothing.
env_reset
S_APP_STAT=0
run ""
want "the app's own rate: <unreadable>" "$OUT" "an app reading that failed is marked, never printed as 0.0"
want 'NO VERDICT about the app' "$OUT" "and the verdict says the reading failed"
notwant 'THE APP NEVER PAINTED' "$OUT" "it is not an app that did nothing"

# The app painting, and a compositor window that cannot be read. The app's own number stands on its own
# (it is a different measurement), so this is not "no verdict about the app".
env_reset
S_COM_STAT=0
run ""
want "the app's own rate: 7.0/s" "$OUT" "the app's own reading survives the compositor's failure"
want 'the app IS painting' "$OUT" "an app that is painting is still read as painting"
want "one or both of the compositor's windows could not be" "$OUT" "and it says which reading failed (the line wraps after 'be', so the pattern stops there)"
notwant 'NO VERDICT about the app' "$OUT" "a failed COMPOSITOR reading is not a failed app reading"
env_reset

# The session's Mir socket when the shell does not name one, and when /proc/net/unix cannot be read.
env_reset
printf 'DESKTOP_SESSION=ubuntu-touch\0' > "$FR/proc/$SHELL_PID/environ"
run ""
want 'session Mir socket: /run/user/32011/mir_socket' "$OUT" "with no MIR_SERVER_FILE, the launcher's own default is used"
want 'established connections before the launch: 4' "$OUT" "and the count still reads the real table"
env_reset
rm -f "$FR/proc/net/unix"
run ""
want 'established connections before the launch: <unreadable>' "$OUT" "an unreadable socket table says so"
notwant 'before the launch: 0' "$OUT" "0 is the same number as 'no connections' -- the two must not look alike"
env_reset

# ==================================================================================================
echo
echo "== 6. the evidence table: one number per cell, and BOTH streams =="
# ==================================================================================================
env_reset
run ""
TABLE="$(printf '%s\n' "$OUT" | sed -n '/the app.s own evidence/,/^== verdict/p')"
[ -n "$TABLE" ] || bad "the evidence table is not in the output at all"
# The defect: `grep -c ... || echo 0` gave a two-line value, so every zero row printed a stray "0".
grep -qE '^0$' <<< "$TABLE" \
  && bad "a stray '0' line is in the table (the two-line count is back)" \
  || ok "no stray line: every row is one line with both counts on it"
rows=$(printf '%s\n' "$TABLE" | grep -cE '^   (Creating a QMirClientScreen|Added camera|Application is now active|ASSERT|caught signal|not found) ')
[ "$rows" = 6 ] && ok "all six patterns have exactly one row each" || bad "the table has $rows pattern rows, want 6"
want 'ASSERT +0 err +0 out' "$TABLE" "a zero count is one number in each column"
want 'Added camera +2 err +0 out' "$TABLE" "a non-zero count is attributed to the file it came from"
want 'Creating a QMirClientScreen +2 err +1 out' "$TABLE" "and the second stream is read too: the row carries this file's own count, not the other's"
want "'Added camera' in app.err:" "$TABLE" "the matching lines are shown, with the file named"
notwant "'Added camera' in app.out:" "$TABLE" "and only for the file that has them"

# ==================================================================================================
echo
echo "== 7. the display: turned on, and left as it was found =="
# ==================================================================================================
env_reset
run ""
want 'ActiveOutputs before: \(ii\) 0 0' "$OUT" "it records the display state it found"
want 'ActiveOutputs now: \(ii\) 1 1' "$OUT" "turns it on for the measurement"
want 'display restored to: \(ii\) 0 0' "$OUT" "and puts it back on the way out (the EXIT trap)"
grep -q '^busctl .*TurnOn' "$ACT" && ok "the TurnOn is a real call" || bad "no TurnOn was issued"
grep -q '^busctl .*TurnOff' "$ACT" && ok "and the display is turned back off, because it started off" || bad "the display was left on"
grep -q '^kill ' "$ACT" && ok "the app is stopped through the kill stub (never a real pid)" || bad "step 6 did not try to stop the app"

env_reset
run "--keep-display"
notwant 'display restored to' "$OUT" "--keep-display leaves the display on for a human"
grep -q '^busctl .*TurnOff' "$ACT" && bad "--keep-display still issued a TurnOff" || ok "and issues no TurnOff at all"

env_reset
printf '(ii) 1 1\n' > "$W/outputs.off"   # the display was ALREADY on, which is the state it must keep
run ""
grep -q '^busctl .*TurnOn' "$ACT" && ok "a display that started ON is still turned on for the measurement" || bad "no TurnOn"
grep -q '^busctl .*TurnOff' "$ACT" && bad "a display that started ON was turned OFF at the end" || ok "and is left ON, because that is what it found"

# ==================================================================================================
echo
echo "== 8. the refusal branches, and the display that will not come on =="
# ==================================================================================================
env_reset
S_CONTAINER=""
run ""
[ "$RC" = 1 ] && ok "no container -> exit 1" || bad "no container exited $RC"
want 'error: no android container' "$OUT" "and it says which piece is missing"
env_reset
rm -f "$FR/proc/$COMP_PID/cmdline"
run ""
[ "$RC" = 1 ] && ok "no compositor -> exit 1" || bad "no compositor exited $RC"
want 'could not find the compositor process' "$OUT" "naming the cmdline it looked for"
env_reset
S_SHELL=""
run ""
[ "$RC" = 1 ] && ok "no shell -> exit 1" || bad "no shell exited $RC"
want 'no lomiri shell process' "$OUT" "and it asks whether the GUI is up at all"
# The display warning: 'no damage' and 'a dead display' must not look alike.
env_reset
printf '(ii) 0 0\n' > "$W/outputs.on"
run ""
want 'WARNING: the display did not report an active output' "$OUT" "a display that will not come on is a warning, not silence"
want "'no damage' and 'a dead display' look identical" "$OUT" "with the reason it matters spelled out"
want 'ActiveOutputs now: \(ii\) 0 0' "$OUT" "and the run continues (the warning is not a failure)"

# ==================================================================================================
echo
echo "== 9. the launch command: uid, namespace, preload, and the app it asks for =="
# ==================================================================================================
env_reset
run ""
LAUNCHLINE="$(grep '^ssh .*setsid nohup' "$ACT" 2>/dev/null | sed -n '1p')"
[ -n "$LAUNCHLINE" ] || bad "the launch command is not in the action log at all"
want 'nsenter -t 700 -p' "$LAUNCHLINE" "the app is started in the container's PID namespace"
want 'ZL1_AS_UID=32011' "$LAUNCHLINE" "as uid 32011, which the session bus requires (docs 80)"
want 'libcfi-shadow-init' "$LAUNCHLINE" "with the preload that took fixing (docs 80)"
want 'zl1-camapp-launch.py' "$LAUNCHLINE" "through the launcher, not the binary directly"
wantl '--mode=x' "$LAUNCHLINE" "and --extra-args reaches it"
wantl 'lomiri-camera-app' "$LAUNCHLINE" "for the app binary it was pointed at"
want 'compositor=6000' "$OUT" "the compositor pid came from the /proc walk, not from pgrep -f"
want 'shell=5000' "$OUT" "and the shell pid from pgrep -x lomiri"

# ==================================================================================================
echo
echo "== 10. the grab, the shot failure, and the flag surface =="
# ==================================================================================================
env_reset
run ""
want 'wrote .*shot-during-app.png .* bytes' "$OUT" "the grab is taken and its size printed"
want 'compare -metric NCC' "$OUT" "with the command that compares it to a reference"
want 'NOT proof of liveness' "$OUT" "and the reminder that a grab never proves liveness (docs 77)"
[ -s "$OUTDIR/shot-during-app.png" ] && ok "the PNG is where it said it was" || bad "the file is not there"
env_reset
write_shot_stub fail
run ""
want 'the grab failed' "$OUT" "a failed grab is reported as a fact about the grab"
want 'not about the app' "$OUT" "and explicitly not about the app"
[ "$RC" = 0 ] && ok "the run is not turned into an error by it" || bad "a failed grab exited $RC"
env_reset
run "--no-shot"
notwant 'shot-during-app.png' "$OUT" "--no-shot takes no grab"
notwant '^screenshot ' "$(cat "$ACT")" "and does not even call the helper"
env_reset
run "--nope"
[ "$RC" = 2 ] && ok "an unknown argument exits 2" || bad "unknown argument exited $RC"
env_reset
run "--help"
[ "$RC" = 0 ] && ok "--help exits 0" || bad "--help exited $RC"
want 'Usage: zl1-camera-app-test' "$OUT" "and prints the usage block it exists to print"
# Both ends of the range, because they fail in opposite directions and only one of them is loud: a range
# that starts too early prints the assignments (which reads as a stray line), while one that stops too
# short simply omits the last option -- and an option nobody documents is exactly an option nobody uses.
want '--outdir DIR' "$OUT" "including the LAST documented option (a range that stops short looks correct)"
notwant '^set -uo pipefail|^HOST=' "$OUT" "stopping after the header, not inside the assignments below it"

# ==================================================================================================
echo
echo "== 11. the premise (an app may already be running) and the stop that keeps one from being measured twice =="
# ==================================================================================================
# Measured on the device 2026-09-26: a run reported "the app's own rate: 0.1/s ... THE APP NEVER
# PAINTED" about a process started 22 minutes earlier by the run BEFORE it, while the evidence table
# printed the new process's first two lines. Two things made that possible: the launch step's walk takes
# the FIRST match, and the stop that was supposed to have ended the previous process HAD NEVER SIGNALLED
# ANYTHING (its operand was a /proc path and the device's shell is dash -- see the operand case below),
# while `timeout` sends SIGTERM and nothing else. So the premise is now a reading, and the stop escalates
# and reports what it needed -- an outcome the fixture below pins from BOTH sides.
env_reset
printf '%s\0--foo\0' "$APP_BIN_FAKE" > "$FR/proc/$APP_PID/cmdline"    # a leftover from an earlier run
run ""
[ "$RC" = 1 ] && ok "a leftover app makes the run refuse with exit 1" || bad "it exited $RC instead of refusing"
want 'a camera app is ALREADY running' "$OUT" "and it says what it found"
want 'REFUSING to measure' "$OUT" "in those words"
# The harness rewrites /proc/ into the fake root, so the path it prints is the fixture's -- the
# instrument prints /proc/<pid> on the device.
want "about $FR/proc/$APP_PID" "$OUT" "naming the pid this run would otherwise have measured"
want 'Nothing has been touched' "$OUT" "with the promise that nothing was touched"
notwant '^busctl .*call' "$(cat "$ACT")" "which is true: no display call was made"
notwant '^kill' "$(cat "$ACT")" "and nothing was signalled either"
notwant 'the app NEVER STARTED' "$OUT" "and the refusal is not confused with a launcher failure"

# The flag that turns the refusal into a decision.
env_reset
printf '%s\0--foo\0' "$APP_BIN_FAKE" > "$FR/proc/$APP_PID/cmdline"
run "--clean-first"
[ "$RC" = 0 ] && ok "--clean-first runs instead of refusing" || bad "--clean-first exited $RC"
want 'stopped by SIGKILL \(SIGTERM did not end it\)' "$OUT" "and reports that SIGKILL is what worked"
want '^kill [0-9]+$' "$(grep -m1 '^kill' "$ACT")" "SIGTERM is tried FIRST (a bare kill, no signal flag) and the operand is a NUMBER"
want '^kill -9 [0-9]+$' "$(grep -m1 '^kill -9' "$ACT")" "and SIGKILL only after SIGTERM did not work, also numeric"
want 'launched pid' "$OUT" "then the run proceeds and launches its own app"

# **And the fixture can reproduce the DEVICE'S own outcome.** With FAKE_SIGTERM_WORKS=1 the first signal
# ends the process -- which is what the run of 2026-09-26 printed -- so the same assertions that require
# the escalation above also have a fixture on the other side. Without this scenario, "stopped by
# SIGTERM" would be a string this harness could not produce at all, and the two branches of the stop
# would be one measured branch plus one invented one.
env_reset
SIGTERM_WORKS=1 run ""
want 'app stopped: stopped by SIGTERM' "$OUT" "and a device that dies to the FIRST signal says so (this is what the 2026-09-26 run printed)"
notwant '^kill -9 ' "$(cat "$ACT")" "and no SIGKILL is sent at all when SIGTERM was enough (the stub logs ^kill, so this is an invocation, not the text of the ssh command)"
notwant 'STILL RUNNING after SIGKILL' "$OUT" "so there is nothing to warn about"
SIGTERM_WORKS=0

# A healthy run still has to END the app: this is what makes the next run's premise true.
env_reset
run ""
want 'app stopped: stopped by SIGKILL \(SIGTERM did not end it\)' "$OUT" "a normal run reports the escalation too"
notwant 'STILL RUNNING after SIGKILL' "$OUT" "and the app is really gone"
want '^kill -9 [0-9]+$' "$(grep -m1 '^kill -9' "$ACT")" "the SIGKILL goes through the stub by path (kill is a builtin)"
notwant 'the stop at the end:' "$OUT" "so the verdict carries no warning about a leftover"

printf '%s\0' "$APP_BIN_FAKE" > "$FR/proc/$APP_PID/cmdline"
"$STUB/kill" "$FR/proc/$APP_PID" >/dev/null 2>&1
[ "$?" = 1 ] && ok "the kill stub REFUSES a path operand the way dash does (exit 1, signalling nothing)" \
             || bad "the kill stub accepted a path: a fixture that cannot say no cannot catch the mutant"
[ -e "$FR/proc/$APP_PID/cmdline" ] && ok "and a path-shaped kill leaves the process alive -- which is what the device printed" \
                                   || bad "a path-shaped kill removed the fixture's process; that is not the device's behaviour"
FAKE_APP_PID="$APP_PID" "$STUB/kill" -9 "$APP_PID" >/dev/null 2>&1
[ ! -e "$FR/proc/$APP_PID/cmdline" ] && ok "while a NUMERIC pid is signalled: the operand is the difference, not the signal" \
                                     || bad "a numeric pid was not signalled"
rm -f "$FR/proc/$APP_PID/stat" "$FR/proc/$APP_PID/cmdline" 2>/dev/null
# AND THE MUTANT IS RUN, not described: put the path-shaped operand back in the copy of the script
# under test and drive the same scenario. On the device the stop printed "STILL RUNNING after SIGKILL"
# while the process died to a numeric kill in the same second; here the mutant has to print the same
# thing, and the shipped run right above it must not.
cp "$REPO/scripts/host/zl1-camera-app-test.sh" "$W/shipped.sh"
# THE OPERAND IS THE WHOLE DEFECT, so the check on it is proved live from BOTH SIDES rather than being
# a pattern that looks right (the memory this tree already carries: "a sweep keyed on one name misses the
# rest" -- a predicate is only known to work if a fixture on each side has been put through it).
#
# `kill /proc/3957277` on the zl1 answers `kill: /proc/3957277: arguments must be process or job IDs`,
# rc=1, signalling nothing: the device's /bin/sh is dash, whose kill builtin takes process ids. The first
# device run of this version printed `STILL RUNNING after SIGKILL: /proc/3957277` for exactly that
# reason, and the stop's own `2>/dev/null` kept it quiet -- so the run reported "this app survives
# SIGKILL", which was not what happened. Before this, the stub accepted a path AND the assertions
# REQUIRED one (`^kill /[^ ]*proc/[0-9]+$`), i.e. the fixture agreed with a form the device rejects and
# the defect was invisible offline.
#
# This is why the mutant is not written as one here: `sed` cannot be trusted with this file's quoting
# (the operand is `\$q` inside a double-quoted ssh command, and the harness's own rewrite rules had to
# be single-quoted for the same reason). A mutation that silently fails to land is the defect the
# sections above are about, so the predicate is demonstrated on a string fixture instead.
printf 'kill %s\n' "$FR/proc/$APP_PID" > "$W/pathform.action"
printf 'kill %s\n' "$APP_PID"          > "$W/numform.action"
if grep -qE '^kill [0-9]+$' "$W/pathform.action"; then
  bad "the numeric-operand pattern matches a /proc path: the assertion on the stop is decoration"
else
  ok "the numeric-operand pattern REJECTS a path operand -- so the assertion on the stop is a check"
fi
grep -qE '^kill [0-9]+$' "$W/numform.action" \
  && ok "and accepts the numeric one, so it is not simply never matching" \
  || bad "the numeric-operand pattern does not match a numeric operand"

# The other half, live: the STUB refuses a non-numeric operand the way dash does and signals nothing.
env_reset
printf '%s\0' "$APP_BIN_FAKE" > "$FR/proc/$APP_PID/cmdline"
"$STUB/kill" "$FR/proc/$APP_PID" >/dev/null 2>&1
[ "$?" = 1 ] && ok "the kill stub REFUSES a path operand the way dash does (exit 1, signalling nothing)" \
             || bad "the kill stub accepted a path: a fixture that cannot say no cannot catch the mutant"
[ -e "$FR/proc/$APP_PID/cmdline" ] && ok "and a path-shaped kill leaves the process alive -- which is what the device printed" \
                                   || bad "a path-shaped kill removed the fixture's process; that is not the device's behaviour"
FAKE_APP_PID="$APP_PID" "$STUB/kill" -9 "$APP_PID" >/dev/null 2>&1
[ ! -e "$FR/proc/$APP_PID/cmdline" ] && ok "while a NUMERIC pid is signalled: the operand is the difference, not the signal" \
                                     || bad "a numeric pid was not signalled"
rm -f "$FR/proc/$APP_PID/stat" "$FR/proc/$APP_PID/cmdline" 2>/dev/null
env_reset
env_reset
env_reset

# An app that will not die is not measured around -- it is reported.
env_reset
run "--help"
wantl '--clean-first' "$OUT" "--help documents the flag (an option nobody documents is an option nobody uses)"

echo
echo "== the health check cites this harness's count, and that citation cannot drift =="
# `host/zl1-health-check.sh` is the first thing a human reads, and it names each harness WITH A CHECK
# COUNT. Those counts are typed by hand, so every time a harness gains an assertion its citation goes
# stale -- and a stale count in the first thing a reader sees is the same defect family as every other
# one in this project: an instrument whose report does not match its subject. It happened (the GPS
# citation still said 99 long after that harness had grown past 120) and nothing would ever have
# noticed, so every harness the health check cites now checks its own citation.
#
# No device needed: at this point PASS and FAIL are final, so this harness knows its own total.
HEALTH="$HERE/zl1-health-check.sh"
if [ -r "$HEALTH" ]; then
  cited=$(sed -e 's/always "/ /g' -e 's/"$//' "$HEALTH" | tr '\n' ' ' |
            sed -n 's/.*zl1-camera-app-test-selftest.sh[ ,(]*\([0-9][0-9]*\) checks.*/\1/p')
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
[ "$KEEP" = 1 ] || rm -rf "$W"
[ "$FAIL" = 0 ]
