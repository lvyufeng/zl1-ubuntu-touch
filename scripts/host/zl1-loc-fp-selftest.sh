#!/bin/sh
# zl1 location-request + fingerprint-probe -- offline self-test. Host-side, touches no device.
#
# Why these two together: they are the instruments for the two pieces of hardware that still have no
# fix at all (docs 82/83/93), they are items 2b and 3 of the post-recovery order, and **each of them
# has exactly one mode that writes to the device** -- `--enable-testing` installs a permission bypass
# that lets anything on the phone obtain its location, `--create-store-dir` creates a directory in
# Android's own /data. Everything else in both scripts is read-only, and the property that matters
# most is therefore the one nothing on the host can observe by accident: **the write does not happen
# unless it was asked for, and what was written is what gets undone.**
#
# Design note, and the difference from the other harnesses here: this one does NOT stub the writes.
# It rewrites the two write *destinations* (the drop-in directory, the QML path) into a fake root and
# lets the real `mkdir`/`cat >`/`rm` run, then asserts the fake root's state. That is a stronger
# statement than an action log -- "the file the script claims to have written exists and holds
# exactly this line" is checkable, while "a stub was called" is not. Only the commands that must not
# act (systemctl) or must answer for a device that is not here (lxc-info, nsenter, logcat, getprop,
# qmlscene, sleep) are stubbed.
#
# Two defects came out of writing this, both fixed (docs 97):
#   * `--quiet --enable-testing` installed the permission bypass with NO notice anywhere, because the
#     consent warning went through say(), which --quiet suppresses;
#   * `--create-store-dir` created BOTH candidate paths while section 2 had already decided which one
#     biometryd passes, and its undo line named only one of them.
#
# Usage: zl1-loc-fp-selftest.sh [--keep]
#   --keep   leave the fake root, the rewritten scripts and the stub bin in place for inspection
#
# Exit codes: 0 every scenario behaved; 1 something did not; 2 the harness could not set up.

set -u

KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
  --keep) KEEP=1; shift ;;
  --help|-h) sed -n '2,30p' "$0"; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

HERE=$(dirname "$0")
LOC="$HERE/../device/zl1-location-request.sh"
FP="$HERE/../device/zl1-fingerprint-probe.sh"
for f in "$LOC" "$FP"; do [ -r "$f" ] || { echo "cannot read $f" >&2; exit 2; }; done

W=${TMPDIR:-/tmp}/zl1-loc-fp-selftest
FR="$W/fake"
STUB="$W/stub"
ACT="$W/actions"
rm -rf "$W"
mkdir -p "$FR/proc/device-tree" "$FR/etc/systemd/system" "$FR/usr/bin" "$FR/usr/lib/qt5/bin" \
         "$FR/dev" "$FR/sys/fs/selinux" "$FR/proc/4242" "$FR/proc/4242/root/data/system/users/0" \
         "$FR/proc/4242/fd" "$W/tmp" "$STUB" "$W/exists" "$W/files" "$W/ls" "$W/props" \
         "$FR/proc/1/ns" || exit 2
printf 'qcom,msm8996\n' > "$FR/proc/device-tree/compatible"

# The v63 stub over /usr/bin/getprop, which is what the real port has: a shell script with no custom.*
# case. The probe's own detector looks for the shebang -- this is the branch that must fire.
#
# **This binary is on biometryd's decision path.** biometryd does not read the Android property area;
# it runs `core::posix::exec("/usr/bin/getprop", {key}, ...)` (property_store.cpp:26) -- an absolute
# path to this exact file. So a scenario that wants biometryd to take the >27 branch has to give the
# UT-side getprop an answer, and `ut_getprop` is how. Leaving it as the stub is the real port.
ut_getprop_stub() { printf '#!/bin/sh\n# no-attach diagnostic stub\nexit 0\n' > "$FR/usr/bin/getprop"; chmod +x "$FR/usr/bin/getprop"; }
ut_getprop() { # $1 = first_api_level answer ('' = the stub's behaviour: no output)
  if [ -z "${1:-}" ]; then
    ut_getprop_stub
  else
    printf '#!/bin/sh\ncase "$1" in ro.product.first_api_level) echo %s ;; ro.build.version.sdk) echo %s ;; esac\nexit 0\n' "$1" "${2:-}" > "$FR/usr/bin/getprop"
    chmod +x "$FR/usr/bin/getprop"
  fi
}
ut_getprop
printf '#!/bin/sh\nexit 0\n' > "$FR/usr/lib/qt5/bin/qmlscene"
chmod +x "$FR/usr/bin/getprop" "$FR/usr/lib/qt5/bin/qmlscene"

# A fake HAL process in the fake /proc, so the probes' process walk finds one and the branch that
# reads its uid, its namespaces and the store paths through /proc/<pid>/root is the one exercised.
printf 'android.hardware.biometrics.fingerprint@2.1-service\x00' > "$FR/proc/4242/cmdline"
cat > "$FR/proc/4242/status" <<'EOF'
Name:	android.hardware.biometrics.fingerprint@2.1-service
Uid:	1000	1000	1000	1000
Gid:	1005	1005	1005	1005
EOF
printf '# the container init, for the namespace comparisons\n' > "$FR/proc/4242/root/x"
# The mount-namespace comparison needs real symlinks, not files: readlink is what the probe calls.
# In every scenario the container pid and the HAL pid are the same 4242, which is the honest default
# (the HAL runs inside the container); section 9 drives the differ branch with its own fixture.
mkdir -p "$FR/proc/4242/ns"
ln -sf 'mnt:[4026532000]' "$FR/proc/4242/ns/mnt"
ln -sf 'pid:[4026532001]' "$FR/proc/4242/ns/pid"
# the daemon's maps, so "is the bridge library loaded" has something to find (section 4 of --status)
printf '7f000000-7f001000 r-xp 00000000 fe:00 1 /usr/lib/aarch64-linux-gnu/libubuntu_platform_hardware_api.so\n' \
  > "$FR/proc/4242/maps"

# --- the stub bin --------------------------------------------------------------------------------
#
# Only what must not act, or must answer for a device that is not here. Everything else (awk, grep,
# sed, cat, ls, tr, cut, date, readlink -- and the writes themselves) runs for real, inside the fake
# root, so that the assertions can look at actual files.
mkstub() { # name
  printf '#!/bin/sh\nprintf "%%s %%s\\n" "%s" "$*" >> "%s"\n' "$1" "$ACT" > "$STUB/$1"
  chmod +x "$STUB/$1"
}
mkstub sleep
# systemctl: records every call AND answers the read-only queries, so the branches that read a unit's
# state are reached -- "no pid to inspect" would hide the bridge-library check entirely.
cat > "$STUB/systemctl" <<EOF
#!/bin/sh
printf 'systemctl %s\n' "\$*" >> "$ACT"
case "\$*" in
*"show -p ExecMainPID"*) printf '4242\n' ;;
*"show -p ExecStart"*)   printf '{ path=/usr/libexec/lxc-android-config/lomiri-location-serviced-wrapper ; argv[]=/usr/libexec/lxc-android-config/lomiri-location-serviced-wrapper --provider gps::Provider ; ignore_errors=no }\n' ;;
*"show -p NRestarts"*)   printf '0\n' ;;
*"is-enabled"*)          printf 'enabled\n' ;;
*"is-active"*)           printf 'active\n' ;;
*"status"*)              printf '  a canned unit status block\n' ;;
esac
exit 0
EOF
chmod +x "$STUB/systemctl"

cat > "$STUB/lxc-info" <<EOF
#!/bin/sh
printf 'lxc-info %s\n' "\$*" >> "$ACT"
case "\${FAKE_CONTAINER_PID:-4242}" in none) ;; *) printf '%s\n' "\${FAKE_CONTAINER_PID:-4242}" ;; esac
exit 0
EOF

# nsenter: records, and answers every question the scripts ask through the container -- the six
# properties, "does this path exist" (`test -e`) / "is it a regular file" (`test -f`), the `ls`
# listings, and the binder service list. A scenario sets up an answer by creating a file, never by
# teaching the stub a fact:
#   $W/props/<key>                        the value of `getprop <key>`
#   $W/exists/<path, / -> _>              `test -e <path>` succeeds
#   $W/files/<path, / -> _>               `test -f <path>` succeeds
#   $W/ls/<path, / -> _>                  the output of `ls -... <path>`
#   $W/services.txt                       the output of `/system/bin/service list`
# This is why the path key is the whole path and not its basename: the fingerprint section asks about
# /data/gf_data and /data/system/users/0/fpdata in the same run, and a basename key would make one
# answer stand for the other.
cat > "$STUB/nsenter" <<EOF
#!/bin/sh
printf 'nsenter %s\n' "\$*" >> "$ACT"
case "\$*" in
*"getprop ro.product.first_api_level"*) printf '%s' "\$FAKE_FAL" ;;
*"getprop ro.build.version.sdk"*)       printf '%s' "\$FAKE_SDK" ;;
*"getprop "*)
  k="\${*##*getprop }"; k="\${k%% *}"
  cat "$W/props/\$k" 2>/dev/null ;;
*"service list"*) cat "$W/services.txt" 2>/dev/null ;;
*"test -e "*|*"test -f "*)
  t="\${*##*test -}"; p="\${t#? }"; p="\${p%% *}"
  case "\$t" in f*) d=files ;; *) d=exists ;; esac
  [ -n "\$p" ] && [ -e "$W/\$d/\$(printf '%s' "\$p" | tr / _)" ] && exit 0
  exit 1 ;;
*" ls "*|*"ls -"*)
  p="\${*##* }"
  cat "$W/ls/\$(printf '%s' "\$p" | tr / _)" 2>/dev/null ;;
esac
exit 0
EOF

cat > "$STUB/lshal" <<EOF
#!/bin/sh
printf 'lshal %s\n' "\$*" >> "$ACT"
printf '%s\n' 'android.hardware.biometrics.fingerprint@2.1::IBiometricsFingerprint/default'
exit 0
EOF

cat > "$STUB/logcat" <<EOF
#!/bin/sh
printf 'logcat %s\n' "\$*" >> "$ACT"
cat "$W/logcat.txt" 2>/dev/null
exit 0
EOF

cat > "$STUB/getprop" <<EOF
#!/bin/sh
printf 'getprop %s\n' "\$*" >> "$ACT"
exit 0
EOF
cat > "$STUB/setprop" <<EOF
#!/bin/sh
printf 'setprop %s\n' "\$*" >> "$ACT"
exit 0
EOF
cat > "$STUB/qmlscene" <<EOF
#!/bin/sh
printf 'qmlscene %s\n' "\$*" >> "$ACT"
printf 'ZL1POS ready name=lomiri valid=false active=true supportedMethods=0\n'
printf 'ZL1POS tick active=true valid=false err=0 lat=none\n'
exit 0
EOF
chmod +x "$STUB"/*

# --- the scripts under test ---------------------------------------------------------------------
#
# Only the destinations of the writes and the paths the guards read are moved. `sh -n` plus a landed
# check per rewrite, because a rewrite that silently misses is an untested copy -- the failure mode
# doc 95 records for the post-mortem harness.
rewrite() { # $1 src, $2 dst
  sed -e "s#/proc/device-tree/compatible#$FR/proc/device-tree/compatible#g" \
      -e "s#/proc/\[0-9\]\*#$FR/proc/[0-9]*#g" \
      -e "s|\${p#/proc/}|\${p#$FR/proc/}|g" \
      -e "s#/proc/\$H#$FR/proc/\$H#g" \
      -e "s#/proc/\$gxp#$FR/proc/\$gxp#g" \
      -e "s#/proc/\$_pid#$FR/proc/\$_pid#g" \
      -e "s#/proc/\$A#$FR/proc/\$A#g" \
      -e "s#/etc/systemd/system#$FR/etc/systemd/system#g" \
      -e "s#^QML=/tmp/#QML=$W/tmp/#" \
      -e "s#/usr/bin/getprop#$FR/usr/bin/getprop#g" \
      -e "s#/usr/lib/qt5/bin/qmlscene#$FR/usr/lib/qt5/bin/qmlscene#g" \
      -e "s#/dev/goodix_fp#$FR/dev/goodix_fp#g" \
      -e "s#/sys/fs/selinux#$FR/sys/fs/selinux#g" \
      "$1" > "$2" || return 1
  sh -n "$2" || return 1
  return 0
}
rewrite "$LOC" "$W/loc.sh" || { echo "the rewritten location script does not parse" >&2; exit 2; }
rewrite "$FP"  "$W/fp.sh"  || { echo "the rewritten fingerprint script does not parse" >&2; exit 2; }
grep -qF "$FR/proc/device-tree/compatible" "$W/loc.sh" && grep -qF "$FR/proc/device-tree/compatible" "$W/fp.sh" \
  || { echo "the zl1-guard rewrite did not land" >&2; exit 2; }
# double-quoted so $FR expands and ${UNIT} does not -- the point is that the file still says ${UNIT}.d
grep -qF "DROPIN_DIR=$FR/etc/systemd/system/\${UNIT}.d" "$W/loc.sh" \
  || { echo "the drop-in directory rewrite did not land (and it must still be \${UNIT}.d -- the FULL unit name, which systemd requires)" >&2; exit 2; }
grep -qF "QML=$W/tmp/zl1-location-request.qml" "$W/loc.sh" \
  || { echo "the QML path rewrite did not land" >&2; exit 2; }
grep -qF "$FR/proc/[0-9]*" "$W/fp.sh" || { echo "the process-walk rewrite did not land" >&2; exit 2; }
# Stronger, and it is the check that would have caught a real gap: a `/proc/$something` the rewrite
# does not know about stays pointed at THIS machine, so the branch that reads it silently reads
# nothing and the scenario passes vacuously. Count every `/proc/<var>` and every moved one; they must
# be equal, or a path was left behind.
for s in "$W/loc.sh" "$W/fp.sh"; do
  all=$(grep -o '/proc/\$' "$s" | wc -l)
  moved=$(grep -oF "$FR/proc/\$" "$s" | wc -l)
  if [ "$all" != "$moved" ]; then
    echo "$(basename "$s"): $((all - moved)) /proc/<var> path(s) were NOT moved into the fake root:" >&2
    grep -n '/proc/\$' "$s" | grep -vF "$FR/proc/\$" | sed 's/^/  /' >&2
    exit 2
  fi
done

DROPIN="$FR/etc/systemd/system/lomiri-location-service.service.d"
TESTING="$DROPIN/zl1-testing.conf"
QMLF="$W/tmp/zl1-location-request.qml"

# --- the checks ----------------------------------------------------------------------------------

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
want()    { if printf '%s\n' "$2" | grep -Eq "$1"; then ok "$3"; else bad "$3"; printf '%s\n' "$2" | sed 's/^/        | /'; fi; }
notwant() { if printf '%s\n' "$2" | grep -Eq "$1"; then bad "$3"; printf '%s\n' "$2" | grep -E "$1" | sed 's/^/        | /'; else ok "$3"; fi; }
# The stub log. `systemctl` is called for read-only queries in every mode (is-active, show, status),
# so "did not call systemd" is the wrong assertion -- what must not happen is a call that changes the
# device: a daemon-reload, a restart, a mask, a stop.
sysacts() { grep -E '^systemctl ' "$ACT" 2>/dev/null; }
syswrite() { grep -E '^systemctl (daemon-reload|restart|start|stop|mask|enable|disable|reload)' "$ACT" 2>/dev/null; }

# $1 = script, rest = args. stdout+stderr in $OUT, exit code in $RC (124 = it hung). The three
# FAKE_* values are what the device would have answered through lxc-info/nsenter, so a scenario that
# wants a different device state sets them and calls env_reset afterwards.
RUN_FAL=27; RUN_SDK=27; RUN_PID=4242
env_reset() { RUN_FAL=27; RUN_SDK=27; RUN_PID=4242; ut_getprop; }
run() {
  s="$1"; shift
  : > "$ACT"
  OUT=$(PATH="$STUB:$PATH" FAKE_FAL="$RUN_FAL" FAKE_SDK="$RUN_SDK" FAKE_CONTAINER_PID="$RUN_PID" \
        timeout 60 sh "$s" "$@" 2>&1); RC=$?
}

echo "zl1 location-request + fingerprint-probe -- offline self-test"
echo "  scripts under test: $LOC"
echo "                      $FP"
echo "  fake root:          $FR"
echo

# ==================================================================================================
echo "== 1. --status: read-only, and it says the true thing about the two levers =="
# ==================================================================================================
run "$W/loc.sh" --status
printf '%s\n' "$OUT" > "$W/out.status"
[ "$RC" = 0 ] && ok "--status exits 0" || bad "--status exited $RC"
[ -z "$(syswrite)" ] && ok "--status makes no systemd call that changes anything" \
                    || { bad "--status would change the device:"; syswrite | sed 's/^/        | /'; }
[ -d "$DROPIN" ] && bad "--status created the drop-in directory" || ok "--status created nothing on disk"
want 'com\.lomiri\.location\.Service' "$OUT" "--status asks the bus who owns the service"
want 'v63 STUB' "$OUT" "--status detects the v63 getprop stub (which is what makes both doc 82 levers dead)"
want 'custom\.location\.testing' "$OUT" "--status names the property the wrapper reads"
want 'libubuntu_platform_hardware_api' "$OUT" "--status looks for the bridge library in the daemon"
want 'not mapped|MAPPED' "$OUT" "--status answers that question rather than skipping it"

# ==================================================================================================
echo
echo "== 2. --explain: prints the two drop-ins, installs neither =="
# ==================================================================================================
run "$W/loc.sh" --explain
printf '%s\n' "$OUT" > "$W/out.explain"
[ "$RC" = 0 ] && ok "--explain exits 0" || bad "--explain exited $RC"
[ ! -d "$DROPIN" ] && ok "--explain wrote nothing (the drop-in directory still does not exist)" \
                   || bad "--explain created the drop-in directory"
[ -z "$(syswrite)" ] && ok "--explain makes no systemd call that changes anything" || bad "--explain would change the device"
want 'TRUST_STORE_PERMISSION_MANAGER_IS_RUNNING_UNDER_TESTING=1' "$OUT" "--explain prints gate 1's drop-in"
want 'lomiri-location-service\.service\.d' "$OUT" "--explain spells the directory with the FULL unit name"
want 'PERMISSION BYPASS' "$OUT" "--explain says out loud what A is"
want 'still behind gate 1' "$OUT" "--explain keeps the fake-coordinate drop-in behind gate 1 (the second reason it never worked)"
want '^ *ExecStart=$' "$OUT" "--explain shows the bare ExecStart= that resets the list"

# ==================================================================================================
echo
echo "== 3. --enable-testing: one file, that content, that restart -- and a notice nobody can silence =="
# ==================================================================================================
run "$W/loc.sh" --enable-testing
printf '%s\n' "$OUT" > "$W/out.enable"
[ "$RC" = 0 ] && ok "--enable-testing exits 0" || bad "--enable-testing exited $RC"
[ -d "$DROPIN" ] && ok "it created the drop-in directory" || bad "no drop-in directory"
# The file itself, not a stub log: this is the permission bypass, so its exact content matters.
if [ -f "$TESTING" ]; then
  ok "it wrote $TESTING"
  got=$(grep -v '^ *#\|^$\|^\[Service\]$' "$TESTING")
  [ "$got" = 'Environment=TRUST_STORE_PERMISSION_MANAGER_IS_RUNNING_UNDER_TESTING=1' ] \
    && ok "the drop-in holds exactly that one Environment= line under [Service] and nothing else" \
    || { bad "the drop-in content is [$got]"; sed 's/^/        | /' "$TESTING"; }
else
  bad "the drop-in was not written at all"
fi
[ "$(ls "$DROPIN" | tr -d ' ')" = "zl1-testing.conf" ] && ok "that is the only file it added" \
  || { bad "the directory holds more than that:"; ls "$DROPIN" | sed 's/^/        | /'; }
want '^systemctl daemon-reload' "$(sysacts)" "and it asks for a daemon-reload"
want '^systemctl restart lomiri-location-service\.service' "$(sysacts)" "and restarts exactly that one unit"
# `(?!...)` is not ERE, so a pattern using it matches nothing and the check passes vacuously. The real
# assertion is a count: exactly one restart, and it names that unit.
[ "$(sysacts | grep -c '^systemctl restart')" = 1 ] && ok "and it is the only unit it restarts" \
  || { bad "it restarted more than one unit:"; sysacts | grep '^systemctl restart' | sed 's/^/        | /'; }
want 'PERMISSION BYPASS' "$OUT" "it says what it is doing"

echo
echo "   -- the notice under --quiet, which is the defect this round found:"
run "$W/loc.sh" --enable-testing --quiet
printf '%s\n' "$OUT" > "$W/out.enable.quiet"
want 'PERMISSION BYPASS' "$OUT" "--quiet --enable-testing STILL says it is installing a permission bypass"
want 'anything on the device can obtain' "$OUT" "and still says what that means"
want 'disable-testing' "$OUT" "and still names the way back"
notwant 'is-enabled|ExecStart|drop-ins  ' "$OUT" "--quiet did suppress the read-only analysis, so this is not just 'quiet is broken'"
[ -f "$TESTING" ] && ok "and the bypass really was installed, so the notice was needed" \
                  || bad "the bypass was not installed, so this scenario proves nothing"

# ==================================================================================================
echo
echo "== 4. --disable-testing: removes that one file, and only when it is there =="
# ==================================================================================================
: > "$DROPIN/zl1-dummy.conf"     # the other drop-in must survive
run "$W/loc.sh" --disable-testing
printf '%s\n' "$OUT" > "$W/out.disable"
[ ! -f "$TESTING" ] && ok "it removed the testing drop-in" || bad "the testing drop-in is still there"
[ -f "$DROPIN/zl1-dummy.conf" ] && ok "it left the fake-coordinate drop-in alone" \
                               || bad "it removed zl1-dummy.conf as well"
want '^systemctl restart lomiri-location-service\.service' "$(sysacts)" "it restarts the unit, so gate 1 closes now"
want 'removed' "$OUT" "it reports the removal"

echo
echo "   -- and with nothing installed: nothing removed, and no false claim:"
rm -f "$DROPIN/zl1-dummy.conf"; rmdir "$DROPIN" 2>/dev/null
run "$W/loc.sh" --disable-testing
printf '%s\n' "$OUT" > "$W/out.disable.absent"
[ ! -d "$DROPIN" ] && ok "with nothing installed it created nothing" || bad "it created the drop-in directory"
notwant '^removed ' "$OUT" "it does not claim to have removed anything"
want 'nothing to remove' "$OUT" "it says there was nothing to remove"
want '^systemctl restart lomiri-location-service\.service' "$(sysacts)" "and still restarts the unit (unambiguous state, no write involved)"

# ==================================================================================================
echo
echo "== 5. --request: writes the client and nothing else =="
# ==================================================================================================
rm -f "$QMLF"
run "$W/loc.sh" --request --seconds 5
printf '%s\n' "$OUT" > "$W/out.request"
[ "$RC" = 0 ] && ok "--request exits 0" || bad "--request exited $RC"
[ -f "$QMLF" ] && ok "it wrote the client to its own /tmp path" || bad "no QML client was written"
if [ -f "$QMLF" ]; then
  want 'name: "lomiri"' "$(cat "$QMLF")" "the client asks for the lomiri plugin (the key from the .so's own metadata)"
  want 'deadlineMs: 5000' "$(cat "$QMLF")" "--seconds 5 reached the client's own deadline"
  want 'PositionSource' "$(cat "$QMLF")" "it is a PositionSource, so the marshalling is the library's, not a guess"
fi
[ ! -d "$DROPIN" ] && ok "--request installed no drop-in (it only measures)" || bad "--request created the drop-in directory"
[ -z "$(syswrite)" ] && ok "--request makes no systemd call that changes anything" || bad "--request would change the device"
want 'ZL1POS' "$OUT" "it prints the client's own lines unaltered"
want 'supportedMethods=0' "$OUT" "including the one that means 'plugin loaded, no backend'"
want 'gate 1' "$OUT" "and it states which gate state the result is to be read against"

# ==================================================================================================
echo
echo "== 6. the zl1 guard and the flag surface (see the device these must refuse on) =="
# ==================================================================================================
printf 'qcom,msm8997\n' > "$FR/proc/device-tree/compatible"
run "$W/loc.sh" --enable-testing
[ "$RC" = 1 ] && ok "not-the-zl1 exits 1 rather than proceeding" || bad "not-the-zl1 exited $RC"
[ ! -d "$DROPIN" ] && ok "and on the wrong device it wrote nothing" || bad "it installed the bypass on the wrong device"
run "$W/fp.sh" --create-store-dir
[ "$RC" = 1 ] && ok "the fingerprint probe refuses too" || bad "the fingerprint probe exited $RC"
printf 'qcom,msm8996\n' > "$FR/proc/device-tree/compatible"

for s in "$W/loc.sh" "$W/fp.sh"; do
  run "$s" --nope
  [ "$RC" = 2 ] && ok "$(basename "$s"): an unknown argument exits 2" || bad "$(basename "$s"): unknown argument exited $RC"
  run "$s" --help
  want 'Usage|--' "$OUT" "$(basename "$s"): --help prints a usage block"
done
msg=$(PATH="$STUB:$PATH" sh "$W/loc.sh" --seconds 2>&1 >/dev/null | head -1)
case "$msg" in
*"parameter not set"*|*"unbound variable"*) bad "'--seconds' with no value aborted the shell: $msg" ;;
*) ok "'--seconds' with no value does not abort the shell (this script defaults it)" ;;
esac

# ==================================================================================================
echo
echo "== 7. fingerprint: the default run writes nothing at all =="
# ==================================================================================================
printf 'setActiveGroup failed: SYS_EINVAL\nStart biometrics\nConnected to IBiometricsFingerprint::2.1 service\n' > "$W/logcat.txt"
run "$W/fp.sh"
printf '%s\n' "$OUT" > "$W/out.fp"
[ "$RC" = 0 ] && ok "the default run exits 0" || bad "the default run exited $RC"
[ -z "$(syswrite)" ] && ok "the default run makes no systemd call that changes anything" || bad "the default run would change the device"
[ ! -d "$FR/data/system/users/0/fpdata" ] && ok "and it created no store directory" || bad "it created one"
want 'read-only' "$OUT" "it announces that it is read-only when --create-store-dir is not given"
want 'access\(W_OK\) with uid=1000' "$OUT" "it states the real question: access() with the HAL's own uid"
want 'same mount namespace as the container' "$OUT" "it compares the HAL's mount namespace against the container's for real"
want '/data/system/users/0/fpdata' "$OUT" "and lists the path biometryd actually passes"
want 'MISSING  /data/system/users/0/fpdata' "$OUT" "whose absence is the finding"
want 'setActiveGroup failed' "$OUT" "it counts the caller's line"
want 'Bad path length' "$OUT" "and the HAL's own line, whose being zero is the evidence"
want 'Start biometrics' "$OUT" "and the line that puts the failure after openHal()"
want 'both empty/garbage, so atoi\(""\)=0 and biometryd takes the <=27 branch' "$OUT" "it says WHY biometryd lands on <=27 (its own read answers nothing), not why the device would"
want 'biometryd execs .*usr/bin/getprop -- a shell script' "$OUT" "and states that biometryd's OWN read comes from the UT-side getprop, which is the v63 stub's shape"
want "biometryd's ACTUAL reason on this port" "$OUT" "so the reason it gives for the <=27 branch is biometryd's, not the device's"
want 'the Android side, for cross-check only \(biometryd never reads this\)' "$OUT" "and it labels the container read as a cross-check, because biometryd does not read it"
want 'vendor.img build.prop: 23' "$OUT" "with the offline-known value (2026-06-07 vendor.img) next to it, so the two readings can be compared"
want 'AGREES with the reading above' "$OUT" "and it says when the two independent readings agree, which is what makes the write safe"

# ==================================================================================================
echo
echo "== 8. --create-store-dir: ONE path, decided by section 2, with its own undo =="
# ==================================================================================================
run "$W/fp.sh" --create-store-dir
printf '%s\n' "$OUT" > "$W/out.fp.create"
want 'mkdir -p /data/system/users/0/fpdata' "$(cat "$ACT")" "level 27 -> it creates /data/system/users/0/fpdata"
notwant 'mkdir -p /data/vendor_de/0/fpdata' "$(cat "$ACT")" "and NOT the other candidate (the defect this round fixed)"
want 'created /data/system/users/0/fpdata' "$OUT" "it reports what it created"
want 'UNDO: nsenter -t 4242 -m -- rmdir /data/system/users/0/fpdata' "$OUT" "the undo names the path it created"
want 'NOT created: /data/vendor_de/0/fpdata' "$OUT" "and it says which path it deliberately did not create"
notwant 'UNDO:.*vendor_de' "$OUT" "the undo does not name a path that was never created"

echo
echo "   -- the >27 branch is reached only when biometryd's OWN read says so:"
# This is the defect this round fixed in the probe. The old section 2 read the CONTAINER's
# /system/bin/getprop and decided from that; biometryd reads the UT-side /usr/bin/getprop. Set the two
# to disagree and the difference is visible: the container says 29 here, and with the real port's stub
# in place the probe must still create the <=27 path, because that is what biometryd will pass.
RUN_FAL=29; RUN_SDK=29
ut_getprop_stub
run "$W/fp.sh" --create-store-dir
printf '%s\n' "$OUT" > "$W/out.fp.create29.containeronly"
want 'mkdir -p /data/system/users/0/fpdata' "$(cat "$ACT")" "container says 29 but the UT getprop is the stub -> biometryd passes <=27, and that is the path created"
notwant 'mkdir -p /data/vendor_de/0/fpdata' "$(cat "$ACT")" "NOT the path the container's value would suggest (the old probe's answer)"
want 'DISAGREES with the reading above' "$OUT" "and it says the two readings disagree instead of silently picking one"

echo
echo "   -- and when biometryd's own getprop answers >27, the other path is taken:"
RUN_FAL=29; RUN_SDK=29
ut_getprop 29 29
run "$W/fp.sh" --create-store-dir
printf '%s\n' "$OUT" > "$W/out.fp.create29"
want 'it DOES answer' "$OUT" "it reports that the UT getprop answers (so the level is a real read, not a default)"
want 'level 29 > 27' "$OUT" "and reads the level from biometryd's own source"
want 'mkdir -p /data/vendor_de/0/fpdata' "$(cat "$ACT")" "level 29 -> it creates /data/vendor_de/0/fpdata"
notwant 'mkdir -p /data/system/users/0/fpdata' "$(cat "$ACT")" "and not the <=27 path"
want 'UNDO: nsenter -t 4242 -m -- rmdir /data/vendor_de/0/fpdata' "$OUT" "with the matching undo"
want 'AGREES with the reading above' "$OUT" "and both readings agree here"

echo
echo "   -- the real 2026-09-23 shape: the stub says nothing, the device says 23, both <=27:"
RUN_FAL=23; RUN_SDK=28
ut_getprop_stub
run "$W/fp.sh" --create-store-dir
printf '%s\n' "$OUT" > "$W/out.fp.create.truth"
want 'ro.product.first_api_level -> 23' "$OUT" "the container reports the value the real vendor.img build.prop carries"
want 'AGREES with the reading above' "$OUT" "and it says so explicitly"
want 'mkdir -p /data/system/users/0/fpdata' "$(cat "$ACT")" "so the path is certain from two independent readings"

echo
echo "   -- an unreadable property lands on the SAME path a correct Android 8 would use:"
RUN_FAL=; RUN_SDK=
run "$W/fp.sh" --create-store-dir
want 'atoi\(""\)=0' "$OUT" "it explains that atoi(\"\")=0"
want 'mkdir -p /data/system/users/0/fpdata' "$(cat "$ACT")" "and creates the <=27 path, as biometryd would"

echo
echo "   -- already there: no mkdir, no chown, no chmod -- and it does not pretend otherwise:"
: > "$W/exists/_data_system_users_0_fpdata"
env_reset
run "$W/fp.sh" --create-store-dir
printf '%s\n' "$OUT" > "$W/out.fp.create.exists"
notwant 'mkdir ' "$(cat "$ACT")" "with the directory present it creates nothing"
notwant 'chown |chmod ' "$(cat "$ACT")" "and changes no ownership or mode"
want 'exists already' "$OUT" "it says the directory was already there"

echo
echo "   -- the uid it would chown to comes from the HAL, so no HAL means no write:"
rm -f "$W/exists/_data_system_users_0_fpdata"
RUN_PID=none
run "$W/fp.sh" --create-store-dir
printf '%s\n' "$OUT" > "$W/out.fp.create.nohal"
[ "$RC" = 1 ] && ok "with no container it exits 1" || bad "with no container it exited $RC"
notwant 'mkdir ' "$(cat "$ACT")" "and writes nothing at all"
want 'aborted' "$OUT" "it says it aborted rather than reporting a success"

echo
# ==================================================================================================
echo
echo "== 9. fingerprint: the chain UNDER the wrapper (docs 98) -- two stores, two silences =="
# ==================================================================================================
# What this section is for: the wrapper HAL section 1 inspects is only the OUTER third. Underneath it,
# hw_get_module("fingerprint") picks a module by AOSP's variant order, that module is itself a client
# of a binder service provided by gx_fpd, and the real Goodix code lives one more layer down with a
# store of its OWN (/data/gf_data, which it creates with fs_mkdirs). So the wrapper's access() gate is
# necessary and not sufficient, and "is the daemon up" and "which module got picked" are two further
# ways for this to be silently dead.
#
env_reset   # section 8 left RUN_PID=none behind, and every check below needs a container
# The fixtures below are the container's answers: the four variant properties, the two module files in
# the container's /vendor, and the listing. Nothing is taught to the stub as a fact -- each answer is
# a file, so a scenario says what the device would say.
printf 'msm8996' > "$W/props/ro.hardware"
printf 'msm8996' > "$W/props/ro.product.board"
printf 'msm8996' > "$W/props/ro.board.platform"
# ro.arch deliberately has no answer: an unset variant property must be reported, not dropped.
: > "$W/files/_vendor_lib64_hw_fingerprint.msm8996.so"
: > "$W/files/_vendor_lib64_hw_gxfingerprint5118m.default.so"
cat > "$W/ls/_vendor_lib64_hw" <<'LS'
total 812
-rw-r--r-- 1 root root  41232 2020-01-01 00:00 fingerprint.msm8996.so
-rw-r--r-- 1 root root 845944 2020-01-01 00:00 gxfingerprint5118m.default.so
-rw-r--r-- 1 root root   9216 2020-01-01 00:00 sensors.msm8996.so
LS

echo
echo "   -- nothing else on the device yet: the two silences are both reported as present:"
run "$W/fp.sh"
printf '%s\n' "$OUT" > "$W/out.fp.chain"
want 'ro\.product\.board     = msm8996' "$OUT" "it reads the variant properties inside the container, not the host's getprop stub"
want 'ro\.arch              = <unset>' "$OUT" "and reports an unset one as unset rather than omitting it"
want 'variant match: /vendor/lib64/hw/fingerprint\.msm8996\.so' "$OUT" "it picks the module AOSP's variant order picks"
want 'binder' "$OUT" "and says what that module is, including that its binder client is one library down"
want 'FingerPrintService' "$OUT" "and names the service that client looks up"
want 'the modules present, as the container sees them' "$OUT" "it lists what is really in the container's /vendor, so 'which module' is an observation"
want 'fingerprint\.msm8996\.so +41232 bytes' "$OUT" "with the size of the module it picked"
want 'gxfingerprint5118m\.default\.so +845944 bytes' "$OUT" "and of the Goodix HAL underneath it"
notwant 'sensors\.msm8996\.so' "$OUT" "the listing is filtered to the fingerprint modules, so it stays readable"
want 'no fingerprint\.default\.so' "$OUT" "it notes the absent AOSP fallback"
want 'gx_fpd: NOT RUNNING' "$OUT" "it checks the daemon the picked module needs -- silence #2"
want 'not registered' "$OUT" "and whether FingerPrintService is on the container's binder"
want 'MISSING  /data/gf_data' "$OUT" "and the Goodix HAL's own store, which is not the path biometryd passes"
want 'MISSING .*dev/goodix_fp' "$OUT" "and the device node that store is reached through"
want 'nsenter -t 4242 -m -- test -e /data/gf_data' "$(cat "$ACT")" "the store questions go through the CONTAINER's mount namespace"

echo
echo "   -- and with the daemon up and the second store present, both change:"
: > "$W/exists/_data_gf_data"
printf -- '-rwx------ 2 system system 4096 2020-01-01 00:00 /data/gf_data\n' > "$W/ls/_data_gf_data"
printf 'FingerPrintService: []\n' > "$W/services.txt"
mkdir -p "$FR/proc/7777"
printf 'gx_fpd\0' > "$FR/proc/7777/cmdline"
printf 'Uid:\t1000\t1000\t1000\t1000\n' > "$FR/proc/7777/status"
run "$W/fp.sh"
printf '%s\n' "$OUT" > "$W/out.fp.chain.up"
want 'gx_fpd: pid 7777 +uid=1000' "$OUT" "gx_fpd is found by its cmdline, with its uid"
notwant 'gx_fpd: NOT RUNNING' "$OUT" "and the 'not running' verdict is gone"
want 'FingerPrintService: \[\]' "$OUT" "the binder service list is read through the container's pid namespace"
notwant '-> not registered' "$OUT" "so the registered case is not reported as absent"
want 'EXISTS   /data/gf_data' "$OUT" "and the second store is now reported present"
rm -rf "$FR/proc/7777"

echo
echo "   -- the check with teeth: does the resolution really have to go through the container?"
# The point of the whole section. /vendor is the CONTAINER's tree; this script runs on the UT side,
# where that path is a different tree (or absent). So the mutant below -- the same rewritten script
# with `nsenter -t "$A" -m -- test -f` replaced by the host's own `test -f`, which is exactly what the
# first draft of this section did -- reports "no variant match" for a container that plainly has the
# module. If the mutant still found it, the checks above would be measuring nothing.
sed 's#nsenter -t "$A" -m -- test -f#test -f#' "$W/fp.sh" > "$W/fp.hostpath.sh"
if grep -qF 'test -f "$d/fingerprint.$v.so"' "$W/fp.hostpath.sh" && \
   ! grep -qF 'nsenter -t "$A" -m -- test -f' "$W/fp.hostpath.sh"; then
  ok "the mutation landed (the mutant tests the HOST's /vendor, not the container's)"
  run "$W/fp.hostpath.sh"
  printf '%s\n' "$OUT" > "$W/out.fp.hostpath"
  notwant '-> variant match' "$OUT" "on the host's /vendor the very same script finds NO module"
  want 'no variant match' "$OUT" "and says so, which is the false 'the HAL is not installed' verdict"
else
  bad "the mutation did not land, so the check above proves nothing"
fi

echo
echo "   -- and the one namespace answer that changes what every path above MEANS:"
mkdir -p "$FR/proc/5555/ns"
ln -sf 'mnt:[4026539999]' "$FR/proc/5555/ns/mnt"
RUN_PID=5555
run "$W/fp.sh"
printf '%s\n' "$OUT" > "$W/out.fp.nsdiffer"
want 'a DIFFERENT mount namespace from the container' "$OUT" "a differing mount namespace is called out, not glossed over"
notwant 'same mount namespace as the container' "$OUT" "and it does not say 'same' when it is not"
rm -rf "$FR/proc/5555"; env_reset

echo
echo "pass=$PASS fail=$FAIL"
[ "$KEEP" = 1 ] || rm -rf "$W"
[ "$FAIL" = 0 ]
