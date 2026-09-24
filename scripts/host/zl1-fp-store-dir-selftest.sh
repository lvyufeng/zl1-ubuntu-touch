#!/bin/sh
# zl1 fingerprint store directory -- offline self-test for the FIX shipped by
# `scripts/install-fingerprint-store-dir.sh` (docs 106).
#
# Host-side, touches no device. There is no separate "installers" home for this one because its fake
# device is a different machine: the four installers in `zl1-installers-selftest.sh` all live on the
# UT rootfs, and this one has to be tested against a device that also has **Android's data partition
# mounted at /var/lib/android-data**, a biometrics HAL process with a namespace of its own, and a
# `getprop` that answers (or, on this port, does not).
#
# Why it needs a harness at all -- three properties, none of which is visible from reading the script:
#
#   1. IT WRITES THE VERY THING THAT HAS BEEN THE BLOCKER. `setActiveGroup failed: SYS_EINVAL` is a
#      silent `access(W_OK)` on a directory that does not exist (docs 83). Creating that directory is
#      the fix, and a fix that is applied by a script whose failure mode is "it ran and nothing
#      changed" is exactly the class of thing this project keeps finding in its own instruments. So
#      the applier READS BACK what the directory says and exits 1 on a mismatch, and this file checks
#      that it really does -- including the shape the real device can produce (a HAL running as a uid
#      the applier cannot give the directory to).
#   2. IT DERIVES THE PATH FROM A RULE THAT IS BROKEN ON THIS DEVICE. biometryd's `<= 27` branch is
#      taken because the UT-side `getprop` is a v63 stub that answers nothing and `atoi("") = 0` (docs
#      101). The applier re-reads that rule every boot on purpose. A version that hardcoded the path
#      would be right today and wrong the day the stub is repaired -- so the harness runs the applier
#      with three different getprop answers and asserts which directory it picks for each.
#   3. ITS REFUSAL GATE IS THE SAFETY PROPERTY. The applier must never create the directory when the
#      Android data partition is not mounted, because then it would create it on the read-only rootfs
#      and every later check would be a lie about a mount point.
#
# The transport stub IS the device, as in the other harnesses (docs 99/100): `ssh` drops the
# connection options and RUNS the remote command locally against a fake root with the stubs in front of
# PATH. Two details are specific to this script and are the reason it could not share a harness:
#
#   * the installer sends `cat > FILE` with the payload on STDIN, so the map is applied to the COMMAND
#     and never to the payload -- which is what lets the landed file's content be asserted, and what
#     means the landed applier still carries DEVICE paths. The stub therefore REFUSES to run an applier
#     that was not rewritten, exactly like its sibling (docs 99 section 5: running a landed applier
#     means running it against the HOST's own /proc and /etc).
#   * the applier is invoked by the installer itself (`/bin/sh '$APPLIER'`, the "run it now" step), not
#     by `systemctl start`, so the interception is on the command rather than on a unit's ExecStart.
#
# Usage: zl1-fp-store-dir-selftest.sh [--keep]
#   --keep   leave the fake root, the stubs and the run logs in place for inspection
#
# Exit codes: 0 every scenario behaved; 1 something did not; 2 the harness could not set up.

set -u

KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
  --keep) KEEP=1; shift ;;
  --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0" ; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

HERE=$(dirname "$0")
FP="$HERE/../install-fingerprint-store-dir.sh"
[ -r "$FP" ] || { echo "cannot read $FP" >&2; exit 2; }
command -v bash >/dev/null 2>&1 || { echo "the installer is a bash script; bash is required" >&2; exit 2; }

W=${TMPDIR:-/tmp}/zl1-fp-store-dir-selftest
FR="$W/fake"
STUB="$W/stub"
ACT="$W/actions"
FAILSTUB="$W/failstub"
rm -rf "$W"
mkdir -p "$FR/etc/systemd/system" "$FR/proc" "$FR/usr/bin" "$FR/var/lib/android-data" \
         "$W/applier" "$STUB" "$FAILSTUB" "$W/hold" || exit 2

# --- the fake device ------------------------------------------------------------------------------
#
# The Android data partition. It is a DIRECTORY here rather than a mount, because the applier's gate is
# the `/proc/mounts` line, not the mount itself -- the line is what the device has and what the gate
# reads, so the fixture for it is the line.
MOUNTS="$FR/proc/mounts"
cat > "$MOUNTS" <<EOF
/dev/sda10 $FR/var/lib/android-data ext4 rw,relatime 0 0
/dev/sda10 $FR/etc/systemd/system ext4 rw,relatime 0 0
tmpfs /run tmpfs rw,nosuid,nodev,mode=755 0 0
EOF
printf 'leeco,zl1\0qcom,msm8996pro\0' > "$FR/proc/device-tree-compatible.tmp"
mkdir -p "$FR/proc/device-tree"
mv "$FR/proc/device-tree-compatible.tmp" "$FR/proc/device-tree/compatible"

# The biometrics HAL. Its uid is the HARNESS's uid, so that the directory the applier creates (owned by
# whoever creates it, because a non-root chown to an unknown uid is refused) is owned by the uid the
# fake HAL reports -- which is the AGREE case, and the one the real device is in (root, 1000).
#
# Its namespace: /proc/<pid>/root is the process's root, and inside the container that root has /data
# bind-mounted from the same ext4. So the fixture makes `$FR/proc/<pid>/root/data` a symlink to the
# partition, which is what the container has.
HALPID=1234
HALUID=$(id -u)
mkdir -p "$FR/proc/$HALPID"
printf '/system/bin/hw/android.hardware.biometrics.fingerprint@2.1-service\0' > "$FR/proc/$HALPID/cmdline"
printf 'Name:\tandroid.hardware.biometrics.fingerprint@2.1-service\nUid:\t%s\t%s\t%s\t%s\nGid:\t%s\t%s\t%s\t%s\n' \
  "$HALUID" "$HALUID" "$HALUID" "$HALUID" "$HALUID" "$HALUID" "$HALUID" "$HALUID" > "$FR/proc/$HALPID/status"
mkdir -p "$FR/proc/$HALPID/root"
ln -sfn "$FR/var/lib/android-data" "$FR/proc/$HALPID/root/data"

# The UT-side getprop. THE DEFAULT IS THE DEVICE, and that is a correction (docs 126): this fixture used
# to answer NOTHING when its values file was absent, and the comment here called that "the v63 stub
# shape". It is not. The stub the boot hook installs ANSWERS `ro.build.version.sdk` (hardcoded 28) and
# has NO arm for `ro.product.first_api_level` -- so the fallback is answered and the first choice is not,
# which is what puts biometryd on the `> 27` branch. The device said so twice
# (tmp-post-recovery-*/06-fingerprint.txt). A fixture whose default is a device that does not exist is
# how four documents came to name the wrong store directory, so the values file is now the way to model
# a DIFFERENT getprop (a repaired one, or Android's own) and the absent file means the real stub.
cat > "$FR/usr/bin/getprop" <<'EOF'
#!/bin/sh
V="$(dirname "$0")/getprop.values"
if [ -f "$V" ]; then
  case "$1" in
  ro.product.first_api_level) sed -n 's/^first_api_level=//p' "$V" ;;
  ro.build.version.sdk)       sed -n 's/^sdk=//p' "$V" ;;
  *) exit 0 ;;
  esac
  exit 0
fi
case "$1" in
ro.build.version.sdk)       printf '%s\n' 28 ;;
ro.product.first_api_level) : ;;    # the stub's OMISSION, and the reason the branch flips
*) [ -n "${2:-}" ] && printf '%s\n' "$2" ;;
esac
exit 0
EOF
chmod +x "$FR/usr/bin/getprop"

# The journal the fingerprint daemon writes. The caller's line is biometryd's own string in its own
# journal -- never logcat (docs 103).
cat > "$W/journal.biometryd" <<'EOF'
[1600000000.1] setActiveGroup failed: SYS_EINVAL
[1600000000.2] setActiveGroup failed: SYS_EINVAL
EOF

# --- the stubs ------------------------------------------------------------------------------------
#
# Only the device's effects. Everything else (mkdir, cp, ls, awk, sed, cat, stat, read) runs for real
# inside the fake root, so the assertions can look at actual files.
mkstub() { # name, recorded line
  printf '#!/bin/sh\nprintf "%%s %%s\\n" "%s" "$*" >> "%s"\n' "$1" "$ACT" > "$STUB/$1"
  chmod +x "$STUB/$1"
}
mkstub logger

cat > "$STUB/systemctl" <<EOF
#!/bin/sh
printf 'systemctl %s\n' "\$*" >> "$ACT"
case "\$1" in
cat)
  u="\$2"
  if [ -f "$FR/etc/systemd/system/\$u" ]; then cat "$FR/etc/systemd/system/\$u"; exit 0; fi
  echo "Unit \$u could not be found." >&2; exit 1 ;;
enable)
  u="\${2#--now }"
  mkdir -p "$FR/etc/systemd/system/multi-user.target.wants"
  ln -sfn "../\$u" "$FR/etc/systemd/system/multi-user.target.wants/\$u" ;;
disable)
  u="\$2"
  rm -f "$FR/etc/systemd/system/multi-user.target.wants/\$u" ;;
is-enabled)
  if [ -e "$FR/etc/systemd/system/multi-user.target.wants/\$2" ]; then echo enabled; else echo disabled; fi ;;
is-active)
  if [ -e "$W/active-fp" ]; then echo active; else echo inactive; fi ;;
show)
  case "\$*" in
  *-p\ Before*)     printf 'biometryd.service\n' ;;
  *-p\ ActiveState*) printf 'active\n' ;;
  *-p\ SubState*)    printf 'running\n' ;;
  *-p\ NRestarts*)   printf '3\n' ;;
  esac ;;
daemon-reload|start|restart|stop|mask|unmask) ;;
esac
exit 0
EOF

cat > "$STUB/journalctl" <<EOF
#!/bin/sh
printf 'journalctl %s\n' "\$*" >> "$ACT"
case "\$*" in
*-u\ biometryd*) cat "$W/journal.biometryd" 2>/dev/null ;;
esac
exit 0
EOF

cat > "$STUB/lxc-info" <<EOF
#!/bin/sh
printf 'lxc-info %s\n' "\$*" >> "$ACT"
printf '%s\n' "$HALPID"
EOF

cat > "$STUB/nsenter" <<EOF
#!/bin/sh
printf 'nsenter %s\n' "\$*" >> "$ACT"
# The container's SELinux state. Permissive is what this port has measured; --status prints it so the
# "no restorecon" decision is checked rather than assumed.
case "\$*" in
*getenforce*) printf '%s\n' "\${FP_ENFORCE:-Permissive}" ;;
esac
exit 0
EOF
chmod +x "$STUB"/*

# A second stub directory, used by ONE scenario, holding a `chown` that always fails. It models the
# silent failure the applier's read-back exists for: `chown ... 2>/dev/null` that the kernel refused.
printf '#!/bin/sh\nexit 1\n' > "$FAILSTUB/chown"
chmod +x "$FAILSTUB/chown"

# ssh: this is the DEVICE. It drops the connection options, maps the device's absolute paths into the
# fake root, and runs the rest for real.
#
# The map is applied to the COMMAND only. That is the point rather than a shortcut: the installer sends
# its two files with `cat > FILE` and the payload on stdin, so the payload must NOT be rewritten -- a
# landed applier carrying fake-root paths would mean the harness had changed the thing under test, and
# it would hide the fact that the applier runs with device paths on a device.
#
# And because the payload keeps device paths, the run-now step has to be INTERCEPTED: `/bin/sh <the
# landed applier>` would otherwise run against the HOST's /proc, /etc and /var. It is redirected to a
# rewritten copy when one exists, and refused loudly when one does not -- the same guard as
# zl1-installers-selftest.sh, and it exists because the alternative is a test that quietly measures the
# wrong machine.
: > "$W/paths.sed"
emit() { printf '%s\n' "$1" >> "$W/paths.sed"; }
emit "s#/etc/systemd/system#$FR/etc/systemd/system#g"
emit "s#/usr/bin/getprop#$FR/usr/bin/getprop#g"
emit "s#/var/lib/android-data#$FR/var/lib/android-data#g"
emit "s#/proc/device-tree/compatible#$FR/proc/device-tree/compatible#g"
emit "s#/proc/mounts#$FR/proc/mounts#g"
emit "s#/proc/\[0-9\]\*#$FR/proc/[0-9]*#g"
emit "s|/proc/\\\$H|$FR/proc/\\\$H|g"
emit "s|\\\${p#/proc/}|\\\${p#$FR/proc/}|g"

cat > "$STUB/ssh" <<EOF
#!/bin/sh
printf 'ssh %s\n' "\$*" >> "$ACT"
while [ \$# -gt 0 ]; do
  case "\$1" in *@*) shift; break ;; *) shift ;; esac
done
# a command that is only an assignment prefix (the installer never sends one) must not be lost
cmd=\$(printf '%s' "\$*" | sed -f "$W/paths.sed")
plain=\$(printf '%s' "\$cmd" | tr -d "'")
case "\$plain" in
/bin/sh\ *)
  copy="$W/applier/zl1-fp-store-dir.sh"
  rest=\${plain#/bin/sh }
  case "\$rest" in
  *zl1-fp-store-dir.sh)
    if [ -f "\$copy" ]; then
      printf 'REDIRECTED-APPLIER %s\n' "\$rest" >> "$ACT"
      exec env PATH="\${FP_EXTRA_STUB:+\$FP_EXTRA_STUB:}$STUB:\$PATH" sh "\$copy"
    fi
    printf 'NO-REWRITTEN-APPLIER %s\n' "\$rest" >> "$ACT"
    printf 'zl1-harness: refusing to run %s with device paths -- no rewritten copy in %s\n' "\$rest" "$W/applier" >&2
    exit 97
    ;;
  esac ;;
esac
exec env PATH="\${FP_EXTRA_STUB:+\$FP_EXTRA_STUB:}$STUB:\$PATH" sh -c "\$cmd"
EOF
chmod +x "$STUB/ssh"

# The stub's rewriting IS the fake device, so a sed expression broken by a delimiter collision would
# send the installer at the HOST's own /etc, /proc and /var. So the transport is checked once, on the
# exact string shapes this script sends, before anything else runs.
#
# The shapes are sent the way the installer sends them: as one COMMAND argument, not on stdin. (This
# installer never uses `sh -s`: its two files go out as `cat > FILE` payloads, which are deliberately
# NOT rewritten, and its --status script is a single argument.)
#
# The two shapes with a `$` in them are echoed inside SINGLE quotes, so the probe prints the text the
# mapping produced instead of what the remote shell would expand `$H` and `${p#/proc/}` into. A probe
# that expands them can only ever report "" and would pass while the mapping did nothing.
q="'"
PROBE_SCRIPT="echo /etc/systemd/system /var/lib/android-data /usr/bin/getprop
echo /proc/mounts /proc/device-tree/compatible
echo ${q}/proc/[0-9]*${q}
echo ${q}/proc/\$H/root/data${q}
echo ${q}x\${p#/proc/}y${q}"
probe=$("$STUB/ssh" root@10.15.19.82 "$PROBE_SCRIPT" 2>&1)
case "$probe" in
*"sed:"*) echo "the ssh stub's path rewriting is broken: $probe" >&2; exit 2 ;;
esac
for shape in "$FR/etc/systemd/system $FR/var/lib/android-data $FR/usr/bin/getprop" \
             "$FR/proc/mounts $FR/proc/device-tree/compatible" \
             "$FR/proc/[0-9]*" \
             "$FR/proc/\$H/root/data" \
             "x\${p#$FR/proc/}y" ; do
  printf '%s\n' "$probe" | grep -qF -- "$shape" ||
    { echo "the ssh stub did not rewrite '$shape' (got: $probe)" >&2; exit 2; }
done

# The applier the device would run, extracted from the installer by the marker its heredoc uses and
# pointed at the fake root -- the pattern of zl1-installers-selftest.sh, and the reason the landed
# file's content is asserted separately (the two are different objects on purpose).
extract_applier() { # $1 = installer, $2 = end-marker name, $3 = out
  MK="$2" awk -v m="<<'$2'" 'index($0, m) { f=1; next } f && $0 == ENVIRON["MK"] { f=0 } f' "$1" > "$3"
  [ -s "$3" ] || { echo "could not extract the $2 applier from $1" >&2; exit 2; }
}
RAW="$W/applier/fp.raw.sh"
extract_applier "$FP" APPLIER_EOF "$RAW"
APPLIER="$W/applier/zl1-fp-store-dir.sh"
rewrite_applier() {
  sed -e "s#/var/lib/android-data#$FR/var/lib/android-data#g" \
      -e "s#/usr/bin/getprop#$FR/usr/bin/getprop#g" \
      -e "s#/proc/mounts#$FR/proc/mounts#g" \
      -e "s#/proc/\[0-9\]\*#$FR/proc/[0-9]*#g" \
      -e "s|\${p#/proc/}|\${p#$FR/proc/}|g" \
      "$RAW" > "$APPLIER"
  sh -n "$APPLIER" || { echo "the rewritten applier does not parse" >&2; exit 2; }
}
rewrite_applier
grep -qF "$FR/var/lib/android-data" "$APPLIER" || { echo "the applier rewrite did not land" >&2; exit 2; }
grep -qF "$FR/proc/[0-9]*" "$APPLIER" || { echo "the applier proc rewrite did not land" >&2; exit 2; }

# --- the checks -----------------------------------------------------------------------------------

PASS=0
FAIL=0
SKIP=0
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
want()    { if printf '%s\n' "$2" | grep -Eq -- "$1"; then ok "$3"; else bad "$3"; printf '%s\n' "$2" | sed 's/^/        | /'; fi; }
notwant() { if printf '%s\n' "$2" | grep -Eq -- "$1"; then bad "$3"; printf '%s\n' "$2" | grep -E -- "$1" | sed 's/^/        | /'; else ok "$3"; fi; }

SYSD="$FR/etc/systemd/system"
# WHICH path is the DEVICE's answer, on the device's own fixture (docs 126): the UT-side stub answers
# ro.build.version.sdk = 28 and omits ro.product.first_api_level, so biometryd takes the `> 27` branch.
# `TARGET` is therefore /data/vendor_de/0/fpdata -- the one the HAL is handed and the one the fix
# creates. The other candidate is a scenario (section 7), never the default.
TARGET="$FR/var/lib/android-data/vendor_de/0/fpdata"
OTHER="$FR/var/lib/android-data/system/users/0/fpdata"
sysacts()  { grep -E '^systemctl ' "$ACT" 2>/dev/null; }
syswrite() { grep -E '^systemctl (daemon-reload|restart|start|stop|mask|unmask|enable|disable)' "$ACT" 2>/dev/null; }
snap()     { find "$FR" -printf '%p %s\n' 2>/dev/null | sort; }
# everything the installer wrote under a tree, for "exactly its own files" claims
ours()     { find "$SYSD" -maxdepth 1 -name 'zl1-fp-store-dir.*' | sort; }

# $1 = script, rest = args. The installer talks through the ssh stub; FP_EXTRA_STUB is how a scenario
# puts a failing `chown` in front of an applier without changing the applier.
RUN_EXTRA=""
run() {
  s="$1"; shift
  : > "$ACT"
  OUT=$(PATH="$STUB:$PATH" FP_EXTRA_STUB="$RUN_EXTRA" timeout 120 bash "$s" "$@" 2>&1); RC=$?
}
runapplier() { # runs the rewritten applier directly, as the device's systemd would
  : > "$ACT"
  OUT=$(PATH="${RUN_EXTRA:+$RUN_EXTRA:}$STUB:$PATH" timeout 120 sh "$APPLIER" 2>&1); RC=$?
}
# the state the fake device is in at the start of a scenario: partition mounted, no directory, no unit,
# the v63 stub getprop, the HAL running
fresh() {
  RUN_EXTRA=""
  rm -rf "$SYSD" "$FR/var/lib/android-data" "$FR/proc/$HALPID/root/data"
  mkdir -p "$SYSD" "$FR/var/lib/android-data" "$FR/proc/$HALPID/root"
  ln -sfn "$FR/var/lib/android-data" "$FR/proc/$HALPID/root/data"
  printf 'leeco,zl1\0qcom,msm8996pro\0' > "$FR/proc/device-tree/compatible"
  rm -f "$FR/usr/bin/getprop.values"; chmod +x "$FR/usr/bin/getprop"
  printf '/system/bin/hw/android.hardware.biometrics.fingerprint@2.1-service\0' > "$FR/proc/$HALPID/cmdline"
  printf 'Name:\tandroid.hardware.biometrics.fingerprint@2.1-service\nUid:\t%s\t%s\t%s\t%s\n' \
    "$HALUID" "$HALUID" "$HALUID" "$HALUID" > "$FR/proc/$HALPID/status"
  cat > "$MOUNTS" <<EOF
/dev/sda10 $FR/var/lib/android-data ext4 rw,relatime 0 0
/dev/sda10 $FR/etc/systemd/system ext4 rw,relatime 0 0
EOF
  rm -f "$W/active-fp"
}
mounts_off() { printf 'tmpfs /run tmpfs rw 0 0\n' > "$MOUNTS"; }

echo "zl1 fingerprint store directory -- offline self-test for the fix"
echo "  installer under test: $FP"
echo "  fake device:          $FR   (Android data at $FR/var/lib/android-data)"
echo "  HAL in the fixture:   pid $HALPID, uid $HALUID (the harness's own uid: see the file header)"
echo

# ==================================================================================================
echo "== 1. the fake device is the shape the script expects =="
# ==================================================================================================
fresh
[ -x "$FR/usr/bin/getprop" ] && ok "the fake UT-side getprop is executable" || bad "no fake getprop"
[ -z "$("$FR/usr/bin/getprop" ro.product.first_api_level)" ] \
  && ok "and it OMITS ro.product.first_api_level -- the stub's omission, which is what flips the branch" \
  || bad "the device's stub does not answer that key, but the fixture does"
[ "$("$FR/usr/bin/getprop" ro.build.version.sdk)" = 28 ] \
  && ok "while it ANSWERS ro.build.version.sdk = 28, which is why the branch is > 27 and not empty (docs 126)" \
  || bad "the fixture's sdk answer is not the device's"
[ -d "$FR/proc/$HALPID/root/data" ] && ok "the HAL's namespace resolves /data to the Android partition" \
  || bad "the HAL's root/data symlink is missing"
grep -q "biometrics.fingerprint" "$FR/proc/$HALPID/cmdline" && ok "and its cmdline is the one the script matches" \
  || bad "the fake HAL's cmdline does not match the script's pattern"
grep -q "var/lib/android-data" "$MOUNTS" && ok "the partition is in /proc/mounts" || bad "the mounts fixture is wrong"

# ==================================================================================================
echo
echo "== 2. the flag surface, and the device guard =="
# ==================================================================================================
fresh
run "$FP" --nope
[ "$RC" = 2 ] && ok "an unknown argument exits 2" || bad "unknown argument exited $RC"
run "$FP" --help
[ "$RC" = 0 ] && ok "--help exits 0" || bad "--help exited $RC"
want 'Usage: install-fingerprint-store-dir' "$OUT" "and prints its own usage block"
want 'access\(W_OK\)' "$OUT" "which names the branch this fix is about"
# The guard is the first thing every mode does, and on the wrong device it must stop before the ssh
# call that would follow it -- so this is also a check that the guard runs FIRST.
printf 'xiaomi,whatever\0qcom,msm8916\0' > "$FR/proc/device-tree/compatible"
run "$FP" --status
[ "$RC" = 1 ] && ok "on a device that is not the zl1 it exits 1" || bad "it exited $RC"
want 'not the zl1' "$OUT" "and says what it looked for, rather than failing somewhere later"
[ -z "$(grep -E '^ssh ' "$ACT" 2>/dev/null | grep -v device-tree)" ] \
  && ok "and it stopped before any other ssh call" || { bad "it went on to talk to the device:"; grep -E '^ssh ' "$ACT" | sed 's/^/        | /'; }

# ==================================================================================================
echo
echo "== 3. the PRE-FIX state: the directory is missing and --status says so =="
# ==================================================================================================
# This is the teeth. Every claim below is "the fix created X and a device without the fix does not have
# X", and the state before --install is the device without the fix.
fresh
[ ! -d "$TARGET" ] && ok "before anything: the directory biometryd passes does NOT exist (the blocker)" \
  || bad "the fixture already has the directory, so nothing here could be tested"
BEFORE=$(snap)
run "$FP" --status
printf '%s\n' "$OUT" > "$W/out.status.before"
[ "$RC" = 0 ] && ok "--status exits 0" || bad "--status exited $RC"
[ "$(snap)" = "$BEFORE" ] && ok "--status writes nothing to the fake device" || bad "--status changed the fake device"
[ -z "$(syswrite)" ] && ok "and makes no systemd call that changes anything" || { bad "--status would change the device:"; syswrite | sed 's/^/        | /'; }
want "root/data/vendor_de/0/fpdata MISSING - this is the directory access\(\) fails on" "$OUT" \
  "it reports the missing directory by asking through the HAL's OWN namespace"
want 'HAL: pid 1234 uid=' "$OUT" "and names the HAL process and the uid it runs as"
want '-> level \(28\) > 27' "$OUT" "it resolves the path the way biometryd does, and shows the level it read"
want "ro.product.first_api_level = ''" "$OUT" \
  "printing the UNANSWERED first choice, which is the omission that flips the branch (docs 126)"
want "ro.build.version.sdk + = '28'" "$OUT" "and the fallback the stub DOES answer, which is where the 28 comes from"
want 'the other candidate .*system/users/0/fpdata : not created, by design' "$OUT" \
  "and the path it deliberately does NOT create is stated, not omitted (docs 97)"
want '/var/lib/android-data is mounted' "$OUT" "and the partition question is answered from /proc/mounts"
want 'lines matching .setActiveGroup failed. in this boot journal: 2' "$OUT" \
  "and the caller's own failure count, from biometryd's JOURNAL (never logcat, docs 103)"
want 'state: active / running   NRestarts: 3' "$OUT" "with the daemon's state and restart count"
want 'Permissive' "$OUT" "and the container's SELinux state, so 'no restorecon' is a checked assumption"
want 'systemctl cat zl1-fp-store-dir\.service: NOT FOUND' "$OUT" "it says the unit is not installed"

run "$FP" --explain
printf '%s\n' "$OUT" > "$W/out.explain"
[ "$RC" = 0 ] && ok "--explain exits 0" || bad "--explain exited $RC"
[ "$(snap)" = "$BEFORE" ] && ok "--explain writes nothing" || bad "--explain changed the fake device"
want 'system_server' "$OUT" "it names the thing whose job this was"
want 'fpDir\.mkdir\(\) \+ restorecon' "$OUT" "and quotes what Android actually does, so the fix is a copy of it"
want 'stats the directory afterwards' "$OUT" "and states that the write alone is not reported as a fix"
want 'the OTHER candidate' "$OUT" "and what it deliberately does not create"
want 'behind on purpose' "$OUT" "and what --remove leaves behind, before anyone runs it"

# ==================================================================================================
echo
echo "== 4. --install: exactly two files, that content, enabled, and the directory really created =="
# ==================================================================================================
fresh
run "$FP" --install
printf '%s\n' "$OUT" > "$W/out.install"
[ "$RC" = 0 ] && ok "--install exits 0" || bad "--install exited $RC"
APP="$SYSD/zl1-fp-store-dir.sh"
UNT="$SYSD/zl1-fp-store-dir.service"
[ -f "$APP" ] && ok "it wrote the applier" || bad "no applier at $APP"
[ -f "$UNT" ] && ok "and the unit" || bad "no unit at $UNT"
[ "$(ours)" = "$(printf '%s\n%s' "$APP" "$UNT" | sort)" ] && ok "and those are the only two files it added" \
  || { bad "it added more of its own:"; ours | sed 's/^/        | /'; }
# The payload must not have been touched by the transport: the landed applier carries DEVICE paths,
# because it is the file that runs on the device. (The harness's own copy is the rewritten one, and the
# stub refuses to run the landed file -- section 9.)
want '^MNT=/var/lib/android-data$' "$(cat "$APP")" "the landed applier still carries the DEVICE path, not the harness's"
notwant "$FR" "$(cat "$APP")" "and nothing of the fake root leaked into it"
want '^#!/bin/sh$' "$(head -1 "$APP")" "it is an sh script"
want 'chmod 0770' "$(cat "$APP")" "it sets the mode access(W_OK) needs"
want 'REFUSING' "$(cat "$APP")" "and carries the refusal gate for an unmounted partition"
want 'MISMATCH' "$(cat "$APP")" "and the read-back that makes a silent failure impossible"
want 'access\(W_OK\)' "$(cat "$APP")" "naming what the read-back is for"
if [ -f "$UNT" ]; then
  want '^Type=oneshot$' "$(cat "$UNT")" "the unit is oneshot"
  want '^RemainAfterExit=yes$' "$(cat "$UNT")" "RemainAfterExit, so its result stays readable"
  want '^RequiresMountsFor=/var/lib/android-data$' "$(cat "$UNT")" "ordered after the Android data mount"
  want '^After=lxc-android-config\.service$' "$(cat "$UNT")" "and after the port's container-configuration point"
  want '^Before=biometryd\.service$' "$(cat "$UNT")" "and BEFORE biometryd, which is what calls setActiveGroup"
  want '^ExecStart=/bin/sh /etc/systemd/system/zl1-fp-store-dir\.sh$' "$(cat "$UNT")" "with the applier as its ExecStart, by DEVICE path"
  want '^WantedBy=multi-user\.target$' "$(cat "$UNT")" "and it is wanted by multi-user"
fi
want '^systemctl enable zl1-fp-store-dir\.service$' "$(sysacts)" "it enables the unit"
want '^systemctl cat zl1-fp-store-dir\.service$' "$(sysacts)" "and verifies with systemctl cat, not is-enabled (docs 63)"
[ -L "$SYSD/multi-user.target.wants/zl1-fp-store-dir.service" ] && ok "the enable created the wants symlink" \
  || bad "no multi-user.target.wants symlink"
[ -d "$TARGET" ] && ok "THE DIRECTORY EXISTS: this is the fix" || bad "the directory was not created"
[ ! -e "$OTHER" ] && ok "and the other candidate was NOT created (docs 97)" || bad "it created both paths"
want 'The directory is in place' "$OUT" "and it reports the applier's own run as a success"
want 'created  /vendor_de/0/fpdata' "$OUT" "the applier says 'created', not 'checked'"
want 'api_level 28 > 27' "$OUT" "naming the rule it followed, so the reason the path is this one is on screen"
want 'from the HAL process 1234' "$OUT" "and taking the owner from the HAL's own /proc entry"
want 'read back: uid=' "$OUT" "and prints the read-back, so the fix is measured and not asserted"
notwant 'MISMATCH' "$OUT" "with no mismatch on a healthy device"
want "$FR/var/lib/android-data/vendor_de/0/fpdata: " "$OUT" "and lists both candidates, from the host path"
want 'absent \(and must stay absent' "$OUT" "naming the second one as absent rather than leaving it blank"
[ "$(find "$FR/var/lib/android-data" -mindepth 1 | sort)" = "$(printf '%s\n%s\n%s\n' \
    "$FR/var/lib/android-data/vendor_de" \
    "$FR/var/lib/android-data/vendor_de/0" \
    "$TARGET" | sort)" ] \
  && ok "and it created exactly the three directories that one path needs, nothing else in the partition" \
  || { bad "the partition does not hold exactly the selected path:"; find "$FR/var/lib/android-data" | sed 's/^/        | /'; }

echo
echo "   -- and --install changes NOTHING else: no restart, no flash, no other partition"
notwant '^systemctl (start|restart|stop|mask|unmask)' "$(sysacts)" "it starts and stops nothing: the retry logic belongs to biometryd"
notwant 'flash|fastboot|edl|firehose|dd ' "$OUT" "and nothing in its output mentions a flash"

# ==================================================================================================
echo
echo "== 5. --status after the fix: AGREE, and the two questions it answers =="
# ==================================================================================================
run "$FP" --status
printf '%s\n' "$OUT" > "$W/out.status.after"
[ "$RC" = 0 ] && ok "--status exits 0 with the fix installed" || bad "--status exited $RC"
want 'present: .*etc/systemd/system/zl1-fp-store-dir\.service' "$OUT" "it reports the unit as present"
want 'systemctl cat zl1-fp-store-dir\.service: found' "$OUT" "and that systemd can read it"
want 'is-enabled: enabled' "$OUT" "and that it is enabled"
want 'AGREE: the directory the rule selects is the one on disk' "$OUT" \
  "and that the installed directory is the one biometryd's rule selects -- the cross-check"
want 'root/data/vendor_de/0/fpdata EXISTS' "$OUT" "the directory now exists as the HAL sees it"
want 'AGREE: owned by the uids of the HAL itself' "$OUT" "and its owner matches the HAL's uid (the access(W_OK) test)"
want 'host view: ' "$OUT" "with the host-side view of the same directory"
want 'the other candidate .*: not created, by design' "$OUT" "and the second candidate is still absent, and said to be"

echo
echo "   -- while the HAL is not running, it says what it would fall back to:"
mv "$FR/proc/$HALPID/cmdline" "$W/hold/cmdline"
run "$FP" --status
printf '%s\n' "$OUT" > "$W/out.status.nohal"
want 'HAL: not running' "$OUT" "with no matching cmdline it says the HAL is not running"
want 'the applier would use 1000 \(user system\)' "$OUT" "and names the fallback uid, so the absence is not silent"
mv "$W/hold/cmdline" "$FR/proc/$HALPID/cmdline"

# ==================================================================================================
echo
echo "== 6. the refusal gate: with the partition NOT mounted it must create nothing =="
# ==================================================================================================
# The safety property. Without it the applier would create the directory on the read-only rootfs and
# every later check would be a lie about a mount point.
fresh
mounts_off
runapplier
printf '%s\n' "$OUT" > "$W/out.refuse"
[ "$RC" = 1 ] && ok "the applier exits 1 when the partition is not mounted" || bad "it exited $RC"
want "REFUSING: $FR/var/lib/android-data is not mounted" "$OUT" "and says exactly which path it refused"
want 'would not be the Android data partition' "$OUT" "and why creating it there would be wrong"
[ ! -e "$SYSD/zl1-fp-store-dir.sh" ] && ok "and nothing at all was written" || bad "it wrote a file anyway"
echo
echo "   -- and --status reports the same thing rather than guessing:"
run "$FP" --status
printf '%s\n' "$OUT" > "$W/out.status.nomount"
want '/var/lib/android-data is NOT mounted: the applier would refuse to create anything' "$OUT" \
  "the read-only report says the applier would refuse, which is the gate's own sentence"

# ==================================================================================================
echo
echo "== 7. WHICH path: the applier follows biometryd's rule, re-read every boot =="
# ==================================================================================================
# The getprop answers, in order of how much they are about THIS device. The first is the device itself
# and needs no values file at all -- it is the fixture's default. The rest model getprops this device does
# not have (a repaired one, Android's own, a garbage one), which is the point of re-reading the rule: a
# hardcoded path is right on exactly one of these and the shipped applier has to be right on all of them.
# The header used to say "the `<= 27` branch is taken TODAY because the read is broken"; the device
# answers 28 and takes the `> 27` branch, and docs 126 has the two readings.
say_getprop() { printf 'first_api_level=%s\nsdk=%s\n' "$1" "$2" > "$FR/usr/bin/getprop.values"; }

echo
echo "   -- THE DEVICE'S OWN SHAPE: no values file, which is the stub the boot hook installs:"
fresh
runapplier
printf '%s\n' "$OUT" > "$W/out.device"
want 'api_level 28 > 27' "$OUT" \
  "the stub's own answers (first_api_level omitted, sdk 28) put the applier on the > 27 branch"
want 'created  /vendor_de/0/fpdata' "$OUT" "and it creates /data/vendor_de/0/fpdata -- the directory the HAL is handed"
[ -d "$TARGET" ] && ok "which is the directory biometryd passes on this device" || bad "it did not create the device's path"
[ ! -e "$OTHER" ] && ok "and it did NOT create the <= 27 one, which nothing would read here" || bad "it created both paths"

echo
echo "   -- a getprop answering 29 (a repaired one, or a newer device):"
fresh
say_getprop 29 29
runapplier
printf '%s\n' "$OUT" > "$W/out.api29"
want 'api_level 29 > 27' "$OUT" "a getprop answering 29 makes the applier take the > 27 branch"
want 'created  /vendor_de/0/fpdata' "$OUT" "and it works on /data/vendor_de/0/fpdata"
[ -d "$TARGET" ] && ok "the vendor_de directory is the one it created" || bad "it did not create the vendor_de one"
[ ! -e "$OTHER" ] && ok "and it did NOT create the system/users/0 one" || bad "it created both paths"

echo
echo "   -- and --status says DISAGREE when the directory on disk is not the one the rule selects:"
# The rule is re-read: the applier answered 29 and made the vendor_de directory; now the rule says 0, so
# the directory biometryd would pass is the system/users/0 one -- and only the other one is there. This
# is the state a device lands in if the getprop answer ever changes under an installed fix, which is
# exactly why the rule is re-read rather than resolved once.
say_getprop 0 0
run "$FP" --status
printf '%s\n' "$OUT" > "$W/out.status.disagree"
want '-> level \(0\) <= 27' "$OUT" "--status re-reads the rule and now finds the <= 27 branch"
want 'DISAGREE: the rule selects /data/system/users/0/fpdata, but only /data/vendor_de/0/fpdata exists' "$OUT" \
  "so it says the directory on disk is not the one biometryd will pass"
want 'Re-run --install to make the selected one' "$OUT" "and names the fix for that state"
want 'the other candidate DOES exist' "$OUT" "and says out loud that the directory nothing reads is present"

echo
echo "   -- and with neither on disk it says so, rather than reporting a fix:"
fresh
run "$FP" --status
printf '%s\n' "$OUT" > "$W/out.status.neither"
want 'NEITHER exists: the fix is not installed for either path' "$OUT" \
  "a device with no directory at all is not reported as AGREE or DISAGREE"

echo
echo "   -- the answer that is not a number takes the same branch an empty answer does:"
fresh
say_getprop 'garbage' ''
runapplier
want 'api_level 0 <= 27' "$OUT" "atoi() of garbage is 0, exactly like atoi(\"\") -- both take <= 27"
[ -d "$OTHER" ] && ok "and the system/users/0 directory is the one created" || bad "it created the wrong path"

echo
echo "   -- and a getprop that is not executable is the same as one that answers nothing:"
fresh
chmod -x "$FR/usr/bin/getprop"
runapplier
want 'api_level 0 <= 27' "$OUT" "an unusable getprop still lands on the <= 27 branch, as biometryd would"
[ -d "$OTHER" ] && ok "and the directory is still the right one" || bad "it picked the wrong path"
chmod +x "$FR/usr/bin/getprop"

echo
echo "   -- while a build whose rule has been replaced by a CONSTANT gets it wrong on the same device:"
# The mutation check, stated as a scenario rather than as an assertion about the source: replace the
# comparison with `if :;`, which is what "hardcode the path" means. The device, the getprop answer and
# the applier are all identical to the scenario above -- only the rule is gone -- so whatever differs is
# the rule. Without this, "the path is derived" is a claim about the text.
fresh
say_getprop 29 29
sed 's#^if \[ "\$api" -le 27 \]; then$#if :; then#' "$APPLIER" > "$W/applier/hardcoded.sh"
grep -qF 'if :; then' "$W/applier/hardcoded.sh" || { echo "the hardcoded-path fixture did not land" >&2; exit 2; }
: > "$ACT"
OUT=$(PATH="$STUB:$PATH" timeout 120 sh "$W/applier/hardcoded.sh" 2>&1); RC=$?
printf '%s\n' "$OUT" > "$W/out.hardcoded"
want 'api_level 29 <= 27' "$OUT" "the constant build prints a reason that contradicts itself, which is the tell"
want 'created  /system/users/0/fpdata' "$OUT" "and works on the path level 29 does not select"
[ -d "$OTHER" ] && ok "so on the SAME fixture it creates a directory biometryd will never pass" \
  || bad "the fixture did not behave"
[ ! -e "$TARGET" ] && ok "and not the one the shipped applier made, which is the whole difference" \
  || bad "the fixture leaked between the two runs"

# ==================================================================================================
echo
echo "== 8. the read-back: a directory that merely EXISTS is not the fix =="
# ==================================================================================================
# The shape the real device can produce: the HAL runs as a uid the applier cannot give the directory
# to (a non-root applier, or a HAL from a different user). Every write "succeeds", the directory exists,
# and access(W_OK) still fails -- so this must be reported as a failure and exit 1.
fresh
printf 'Name:\thw\nUid:\t0\t0\t0\t0\n' > "$FR/proc/$HALPID/status"     # the HAL reads as uid 0
mkdir -p "$TARGET"                                                       # and the directory already exists
runapplier
printf '%s\n' "$OUT" > "$W/out.mismatch"
[ "$RC" = 1 ] && ok "it exits 1 when the directory does not read back as the caller's" \
  || bad "it exited $RC -- 'the directory exists' was reported as a fix"
want "MISMATCH: .*is uid=$HALUID mode=770, not 0/770" "$OUT" "naming what it got and what access(W_OK) needs"
want 'the directory EXISTS but this is NOT the fix' "$OUT" "and saying the one thing an operator must not conclude"
want 'checked  /vendor_de/0/fpdata' "$OUT" "it took the 'checked' branch, because the directory was already there"

echo
echo "   -- and a chown the kernel refuses is caught by the same read-back:"
fresh
mkdir -p "$TARGET"; chmod 0777 "$TARGET"
RUN_EXTRA="$FAILSTUB"
runapplier
RUN_EXTRA=""
printf '%s\n' "$OUT" > "$W/out.mismatch.chown"
[ "$RC" = 0 ] && ok "with the HAL's own uid it still exits 0, because chown was not needed" \
  || bad "it exited $RC with a failing chown and nothing else wrong"
want "REPAIRED: it was " "$OUT" "and the repair is reported: the mode it found was not the mode it needs"
[ "$(stat -c %a "$TARGET")" = 770 ] && ok "and the mode really is 770 afterwards" || bad "the mode is $(stat -c %a "$TARGET")"

echo
echo "   -- a directory that is ALREADY right is left alone:"
fresh
mkdir -p "$TARGET"; chmod 0770 "$TARGET"
runapplier
printf '%s\n' "$OUT" > "$W/out.idempotent"
[ "$RC" = 0 ] && ok "the second run exits 0" || bad "it exited $RC"
want 'checked  /vendor_de/0/fpdata' "$OUT" "it takes the 'checked' branch, not 'created'"
notwant 'REPAIRED' "$OUT" "and does not claim a repair it did not make"

# ==================================================================================================
echo
echo "== 9. the safety guard: the landed applier must never be run with device paths =="
# ==================================================================================================
# The applier's own paths are DEVICE paths, and running it on the host would make it create
# /var/lib/android-data on the LAPTOP -- and, worse, the test would then be measuring the wrong machine.
# So the stub refuses. This is asserted rather than assumed: the guard is removed and the run-now step
# has to fail loudly instead of quietly doing the wrong thing.
fresh
rm -f "$APPLIER"
run "$FP" --install
printf '%s\n' "$OUT" > "$W/out.noapplier"
want 'NO-REWRITTEN-APPLIER' "$(grep '^NO-REWRITTEN-APPLIER' "$ACT" 2>/dev/null)" \
  "with no rewritten copy the stub refuses to run the landed applier"
want 'refusing to run .* with device paths' "$OUT" "and says so in the run's own output, not just in a log"
want 'THE APPLIER EXITED 97' "$OUT" "and the installer reports that failure instead of a fix"
notwant 'The directory is in place' "$OUT" "it does not tell the operator the fingerprint is fixed"
[ ! -e /var/lib/android-data ] && ok "and nothing was created on THIS host (the guard's whole purpose)" \
  || bad "/var/lib/android-data exists on the host: the guard did not hold"
# The two files were still written -- --install is not atomic, and this is what that looks like.
[ -f "$SYSD/zl1-fp-store-dir.sh" ] && ok "the applier is still on the device (the run failed, the write did not)" \
  || bad "the applier is not there"
rewrite_applier

# ==================================================================================================
echo
echo "== 10. --remove: its own three paths, and the directory left behind on purpose =="
# ==================================================================================================
fresh
run "$FP" --install >/dev/null 2>&1
[ -d "$TARGET" ] && ok "the fix is installed before the removal is tested" || bad "the setup install did nothing"
: > "$SYSD/zl1-someone-elses.service"
BEFORE_OTHER=$(cat "$SYSD/zl1-someone-elses.service")
run "$FP" --remove
printf '%s\n' "$OUT" > "$W/out.remove"
[ "$RC" = 0 ] && ok "--remove exits 0" || bad "--remove exited $RC"
[ ! -f "$APP" ] && ok "the applier is gone" || bad "the applier is still there"
[ ! -f "$UNT" ] && ok "the unit is gone" || bad "the unit is still there"
[ ! -e "$SYSD/multi-user.target.wants/zl1-fp-store-dir.service" ] && ok "and the wants symlink" \
  || bad "the wants symlink survives"
[ -f "$SYSD/zl1-someone-elses.service" ] && [ "$(cat "$SYSD/zl1-someone-elses.service")" = "$BEFORE_OTHER" ] \
  && ok "and it removed nothing else" || bad "it deleted or changed a file it does not own"
want '^systemctl disable --now zl1-fp-store-dir\.service' "$(sysacts)" "it disables and stops the unit"
want 'removed /etc/systemd/system/zl1-fp-store-dir\.service' "$OUT" "it names each path it removed"
[ -d "$TARGET" ] && ok "THE DIRECTORY SURVIVES: removing it would break the fingerprint again" \
  || bad "it deleted the directory"
want 'the directory was NOT removed' "$OUT" "and it says so rather than leaving the reader to guess"
want 'rmdir /var/lib/android-data/vendor_de/0/fpdata' "$OUT" "printing the exact undo, as a DEVICE path"
want 'ls -A' "$OUT" "with the emptiness check that has to come first"
# The other file must not be touched by a second remove either: --remove is idempotent and does not
# own anything else.
run "$FP" --remove
[ "$RC" = 0 ] && ok "a second --remove also exits 0" || bad "the second --remove exited $RC"
[ -f "$SYSD/zl1-someone-elses.service" ] && ok "and still removed nothing of anyone else's" || bad "it deleted someone else's file"
rm -f "$SYSD/zl1-someone-elses.service"

# ==================================================================================================
echo
echo "== 11. what this cannot test, and says so =="
# ==================================================================================================
# The device facts the fix rests on. They are checkable only on the device, and a harness that quietly
# skipped them would read as if they had been checked.
SKIP=$((SKIP + 1))
printf 'SKIP  that biometryd really passes the path the rule picks, and that setActiveGroup then returns\n'
printf '      0. Both are device facts (docs 83 measured the first offline, the second never): the\n'
printf '      instrument is scripts/device/zl1-fingerprint-probe.sh, run after this fix is installed.\n'
SKIP=$((SKIP + 1))
printf 'SKIP  that access(W_OK) passes once the owner matches. It follows from the HAL source, but the\n'
printf '      HAL has never been observed succeeding on this device.\n'
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
            sed -n 's/.*zl1-fp-store-dir-selftest.sh[ ,(]*\([0-9][0-9]*\) checks.*/\1/p')
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
echo "pass=$PASS fail=$FAIL$([ "$SKIP" != 0 ] && echo " skip=$SKIP (device facts, named above)")"
[ "$KEEP" = 1 ] || rm -rf "$W"
[ "$FAIL" = 0 ]
