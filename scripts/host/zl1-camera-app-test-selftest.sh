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
  --help|-h) sed -n '2,33p' "$0"; exit 0 ;;
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
# ssh command, so the file really contains `\${p%/cmdline}` with a backslash -- and in a double-quoted
# sed script the shell eats that backslash, leaving a pattern that matches nothing. Silently: the sed
# exits 0, and the only symptom would be a REAL kill signalling a host process.
sed -e "s#/proc/#$FR/proc/#g" \
    -e "s#/tmp/zl1-camapp\.#$FR/tmp/zl1-camapp.#g" \
    -e "s#/userdata/zl1-hybris/#$FR/userdata/zl1-hybris/#g" \
    -e "s#/usr/share/click/preinstalled/camera.ubports#$FR/usr/share/click/preinstalled/camera.ubports#g" \
    -e 's#\*) kill \\${p%/cmdline}#*) \\"'"$STUB"'/kill\\" \\${p%/cmdline}#' \
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
{
  printf '%s (lomiri system-c) S' "\$W_COM_PID"
  i=1; while [ "\$i" -le 10 ]; do printf ' %s' "\$i"; i=\$((i+1)); done
  printf ' %s 0' "\$total"
  i=14; while [ "\$i" -le 50 ]; do printf ' %s' "\$i"; i=\$((i+1)); done
  printf '\n'
} > "$FR/proc/\$W_COM_PID/stat" 2>/dev/null
# The app's own captured output, installed here so that it is in place before step 6 pulls it (the
# launch is backgrounded through setsid, so nothing guarantees when -- or whether -- it has run).
[ -f "$W/app.out.fixture" ] && cat "$W/app.out.fixture" > "$FR/tmp/zl1-camapp.out"
[ -f "$W/app.err.fixture" ] && cat "$W/app.err.fixture" > "$FR/tmp/zl1-camapp.err"
# Model the app dying while the 6 s of QML/EGL startup pass (call 4 is that sleep).
if [ "\$n" = 4 ]; then
  case "\$FAKE_ALIVE" in
  1) cp "$W/app.cmdline.fixture" "$FR/proc/\$FAKE_APP_PID/cmdline" 2>/dev/null ;;
  0) rm -f "$FR/proc/\$FAKE_APP_PID/cmdline" ;;
  esac
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
want()    { if printf '%s\n' "$2" | grep -Eq -- "$1"; then ok "$3"; else bad "$3"; printf '%s\n' "$2" | sed 's/^/        | /'; fi; }
notwant() { if printf '%s\n' "$2" | grep -Eq -- "$1"; then bad "$3"; printf '%s\n' "$2" | grep -E -- "$1" | sed 's/^/        | /'; else ok "$3"; fi; }
wantl()   { if printf '%s\n' "$2" | grep -qF -- "$1"; then ok "$3"; else bad "$3"; printf '%s\n' "$2" | sed 's/^/        | /'; fi; }
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
  S_ALIVE=1; S_RATE_A=12; S_RATE_B=240
  write_shot_stub ok
  rm -f "$W/display-on" "$W/ticks" "$W/sleepc"
  # sleeps in order: 3 (step 1), <A> (window A), 1 (step 3), 6 (step 3 end), <B> (window B), 1 (step 6)
  printf '0\n%s\n0\n0\n%s\n0\n' "$S_RATE_A" "$S_RATE_B" > "$W/rates"
  rm -rf "$FR/proc/$APP_PID"
  mkdir -p "$FR/proc/$APP_PID/task" "$FR/proc/$COMP_PID"
  printf '/usr/sbin/lomiri-system-compositor --enable\n' > "$FR/proc/$COMP_PID/cmdline"
  # The app's own /proc entry: cmdline for the walk, stat and task/ for the "state=" and "threads="
  # fields of the alive line (an empty state reads as a dead process to a human, and the harness would
  # then be testing a device nobody ever sees).
  printf '%s\0--foo\0' "$APP_BIN_FAKE" > "$FR/proc/$APP_PID/cmdline.keep"
  printf 'R (lomiri-camera-a) S 1 1 1 0 -1 0 0 0 0 0 5 3 0 0 20 0 12 0 100 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n' > "$FR/proc/$APP_PID/stat"
  : > "$FR/proc/$APP_PID/task/1"
  mv "$FR/proc/$APP_PID/cmdline.keep" "$FR/proc/$APP_PID/cmdline"
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
      FAKE_APP_PID="$APP_PID" W_COM_PID="$COMP_PID" \
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
rm -f "$FR/proc/$APP_PID/cmdline"    # the launcher exited immediately: there is no app process at all
run ""
want 'NOT launched' "$OUT" "step 3 reports that the launcher exited immediately"
want 'the app NEVER STARTED' "$OUT" "and the verdict says THAT"
notwant 'the app is not being composited' "$OUT" "it does not blame the compositor for a launcher failure"
want 'not a compositor one' "$OUT" "and it points at the launcher and its own output instead"

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
echo "== 5. the evidence table: one number per cell, and BOTH streams =="
# ==================================================================================================
env_reset
run ""
TABLE="$(printf '%s\n' "$OUT" | sed -n '/the app.s own evidence/,/^== verdict/p')"
[ -n "$TABLE" ] || bad "the evidence table is not in the output at all"
# The defect: `grep -c ... || echo 0` gave a two-line value, so every zero row printed a stray "0".
printf '%s\n' "$TABLE" | grep -qE '^0$' \
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
echo "== 6. the display: turned on, and left as it was found =="
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
echo "== 7. the refusal branches, and the display that will not come on =="
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
echo "== 8. the launch command: uid, namespace, preload, and the app it asks for =="
# ==================================================================================================
env_reset
run ""
LAUNCHLINE="$(grep '^ssh .*setsid nohup' "$ACT" 2>/dev/null | head -1)"
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
echo "== 9. the grab, the shot failure, and the flag surface =="
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

echo
echo "pass=$PASS fail=$FAIL"
[ "$KEEP" = 1 ] || rm -rf "$W"
[ "$FAIL" = 0 ]
