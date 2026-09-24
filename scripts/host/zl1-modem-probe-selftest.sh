#!/usr/bin/env bash
# zl1 modem probe -- offline self-test. Host-side, touches no device, needs no phone.
#
# Why this exists. `scripts/device/zl1-modem-probe.sh` is the first instrument for the one subsystem this
# port has never looked at (telephony/modem), and it is the instrument with the worst failure mode if it
# is wrong in the usual way: a probe that reads an unreadable kernel log as "the driver said nothing"
# would report a dead modem as a quiet boot, which is how a whole subsystem stays unexamined for months.
# So the harness holds it to four things, in this order of importance:
#
#   1. IT WRITES NOTHING, AND THAT IS CHECKED STATICALLY AND WITH TEETH. The modem is not a driver you
#      can poke: the partitions beside it (`modemst1`/`modemst2`/`fsg`/`fsc`/`persist`) hold the
#      calibration and the IMEI, and a probe that opened one to "inspect" it is one typo from the write
#      this project's safety rules forbid absolutely. So there is a guard over the shipped source (no
#      redirect into /sys, /proc or a block device; no dd/mount/modprobe/systemctl-that-changes-state),
#      and a mutation that puts ONE such write back must make the guard fail. A guard that cannot fail is
#      the defect this tree keeps recording, so the mutation is part of the check.
#   2. A READING THAT COULD NOT BE TAKEN IS NOT A NEGATIVE ONE (docs 117). Two shapes here: the kernel
#      log unreadable (a failing `journalctl` prints nothing, and a quiet boot prints nothing), and the
#      firmware name unreadable (then no path comparison was ever made). The verdict must say UNANSWERED,
#      never "the PIL driver logged nothing" and never "the firmware is not on the search path".
#   3. THE FIRMWARE NAME COMES FROM THE DEVICE, not from a DTB in this repo. With the node absent the
#      probe must not fall back to the word "modem" and start comparing paths against a guess.
#   4. THE "(none)" LINES ACTUALLY PRINT. `grep PAT F | tail | sed || say none` never reaches its
#      none-branch -- in a pipeline the status is the LAST command's, and sed succeeds on empty input --
#      so a pattern that matched nothing would print nothing at all. Two of the probe's three such sites
#      were live defects found here (docs 120 §5); the harness asserts the named line appears.
#
# How it works: **the stub directory IS the device.** The probe runs as itself, with a fake root and the
# device's tools stubbed. PATH for the child is `$STUB:$MINBIN`, and MINBIN is a sandbox of symlinks to
# the handful of real coreutils the probe needs -- because this host HAS `gdbus` in /usr/bin, where the
# coreutils live too, so "hide the stub" would otherwise leave the REAL gdbus reachable and the probe
# would query this laptop's system bus. That leak is the one the GPS instrument's harness found in itself
# (docs 119 §5.2); here it is closed by construction rather than by remembering.
#
# Usage: zl1-modem-probe-selftest.sh [--keep]
#   --keep   leave the fake device, the stubs and the rewritten script for inspection
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
SRC="$HERE/../device/zl1-modem-probe.sh"
[ -r "$SRC" ] || { echo "cannot read $SRC" >&2; exit 2; }

W="${TMPDIR:-/tmp}/zl1-modem-probe-selftest"
# `root`, not `dev`: the fake root's path must not itself contain a path the rewriter hunts for, or the
# replacement text gets rewritten in turn. With the fake root at `$W/dev`, the `/proc/` rewrite produced
# `$W/dev/proc/...` and the `/dev/` rewrite then hit the `dev` in the middle of it, giving
# `$W/tmp/.../dev/dev/proc/` -- a script reading nothing, while every scenario still "passed".
FR="$W/root"
STUB="$W/stub"
MINBIN="$W/minbin"
ACT="$W/actions"
rm -rf "$W"
mkdir -p "$STUB" "$MINBIN" || exit 2

# --- the sandbox PATH ------------------------------------------------------------------------------
# The tools the probe's own shell code invokes for real (everything else it calls is stubbed). Missing one
# shows up as a shell error rather than as a wrong answer, so the list is generous.
# `type -P`, not `command -v`: in a shell whose profile has made `grep` a function, `command -v grep`
# prints the word "grep" rather than a path, and the symlink would then point at itself -- which is exactly
# the failure this loop guards against, arriving as a broken instead of a missing tool.
for t in awk basename cat cut head ls sed sort tail tr uniq wc grep; do
  p="$(type -P "$t" 2>/dev/null)" || continue
  [ -n "$p" ] && ln -sf "$p" "$MINBIN/$t"
done
for t in awk grep ls sed tail tr wc; do
  [ -x "$MINBIN/$t" ] || { echo "the sandbox bin is missing $t -- the harness cannot run the probe honestly" >&2; exit 2; }
done
SH_BIN="$(type -P sh 2>/dev/null)"; [ -n "$SH_BIN" ] || SH_BIN=/bin/sh
[ -x "$SH_BIN" ] || { echo "no /bin/sh to run the probe with" >&2; exit 2; }

# --- the script under test, rewritten into the fake device -----------------------------------------
#
# TWO PASSES, and the reason is a defect this harness found in its own first draft. A one-pass rewrite is
# a cascade: `/proc/sys/kernel/osrelease` had its `/proc/` replaced with the fake root and then had the
# `/sys/` inside `proc/sys/kernel` replaced too, giving `$FR/proc$FR/sys/kernel/osrelease` -- a path that
# cannot exist, in the identity block at the top, while every scenario downstream still "passed" because
# none of them asserts on it. So pass 1 swaps each device path for a TOKEN that cannot itself be a device
# path, and pass 2 expands the tokens. Nothing in a replacement text can be re-matched by a rule that has
# already run.
#
# Each pattern that is an element of a SPACE-SEPARATED LIST carries its leading space (`for mp in ...
# /firmware`, and the firmware search PATHS) -- and the replacement KEEPS that space, or the list loses
# its separators and `for mp in A B C` becomes the single word `inABC`, which is a syntax error rather
# than a wrong reading. A bare `/firmware` rule would also hit `/lib/firmware`, so that one is written for
# the list element it means and not for the substring.
P1="$W/pass1.sh"
sed -e 's# /android/vendor/firmware_mnt# __ZA1__#g' \
    -e 's# /vendor/firmware_mnt# __ZM1__#g' \
    -e 's# /lib/firmware# __ZL1__#g' \
    -e 's# /firmware# __ZF1__#g' \
    -e 's#/tmp/zl1-modem-klog.txt#__ZK__#g' \
    -e 's#/proc/#__ZP__#g' \
    -e 's#/sys/#__ZS__#g' \
    -e 's#/dev/#__ZD__#g' "$SRC" > "$P1"

RW="$W/modem-probe.sh"
sed -e "s#__ZA1__#$FR/android/vendor/firmware_mnt#g" \
    -e "s#__ZM1__#$FR/vendor/firmware_mnt#g" \
    -e "s#__ZL1__#$FR/lib/firmware#g" \
    -e "s#__ZF1__#$FR/firmware#g" \
    -e "s#__ZK__#$W/klog-out.txt#g" \
    -e "s#__ZP__#$FR/proc/#g" \
    -e "s#__ZS__#$FR/sys/#g" \
    -e "s#__ZD__#$FR/dev/#g" "$P1" > "$RW"
sh -n "$RW" || { echo "the rewritten probe does not parse" >&2; exit 2; }

# A token left behind would be a path that silently cannot exist, so it is a setup failure, not a finding.
if grep -q -- '__Z' "$RW"; then
  echo "an unexpanded token is left in $RW:" >&2
  grep -n -- '__Z' "$RW" | head -5 >&2
  exit 2
fi

# The landing count, and it is an invariant rather than a per-path tally. One missed path means the
# command reads THIS machine while every scenario still "passes" (docs 98 found exactly that in its own
# harness). Counting occurrences of `/sys/` in the source against `$FR/sys/` in the result does NOT work,
# and finding that out is why this is written as a count of TOKENS: the three `/sys/` in the probe that
# live inside `/proc/sys/kernel/...` are correctly not turned into `$FR/sys/`, they are part of the
# `$FR/proc/` prefix. So the invariant is the two passes agreeing with each other, which is exact:
# every token in pass 1 must appear as exactly one fake-root path in pass 2, and nothing else may.
cnt() { grep -o -- "$1" "$2" 2>/dev/null | wc -l | tr -d ' '; }
TOK=$(cnt '__Z[A-Z0-9]*__' "$P1")
# The one token whose expansion is NOT inside the fake root: the kernel-log scratch file (`__ZK__`), which
# becomes the harness's own path. It is counted separately rather than being allowed to blur the total,
# because a blob of slack in this number is exactly where a missed path would hide.
KLOG=$(cnt "$W/klog-out.txt" "$RW")
FRS=$(cnt "$FR" "$RW")
[ "$TOK" -gt 0 ] || { echo "pass 1 produced no tokens -- the rewrite matched nothing" >&2; exit 2; }
[ "$TOK" = "$((FRS + KLOG))" ] \
  || { echo "$TOK tokens in pass 1 became $FRS fake-root paths + $KLOG scratch paths in pass 2" >&2; exit 2; }
[ "$KLOG" -gt 0 ] || { echo "the kernel-log scratch path was not rewritten" >&2; exit 2; }
# The two paths the whole probe is built around, named individually: a token that expanded by the wrong
# rule would still satisfy the count above.
[ "$(cnt '__ZP__' "$P1")" = "$(cnt '/proc/' "$SRC")" ] \
  || { echo "the /proc/ rewrite did not cover every /proc/ in the source" >&2; exit 2; }
grep -o -- '/proc/sys/' "$SRC" | wc -l >/dev/null
[ "$(( $(cnt '/sys/' "$SRC") - $(cnt '/proc/sys/' "$SRC") ))" = "$(cnt '__ZS__' "$P1")" ] \
  || { echo "the /sys/ rewrite counted wrong (the ones inside /proc/sys/ are part of the /proc/ prefix)" >&2; exit 2; }
[ "$(cnt '/dev/' "$SRC")" = "$(cnt '__ZD__' "$P1")" ] \
  || { echo "the /dev/ rewrite did not cover every /dev/ in the source" >&2; exit 2; }
# And the cascade, named as itself: the fake root's own path appearing immediately after itself, or a
# device path landing INSIDE the fake root's proc/ directory.
grep -qF "$FR$FR" "$RW" && { echo "a rewrite cascaded: $FR appears twice in a row" >&2; exit 2; }
grep -qF "$FR/proc/$FR" "$RW" && { echo "a rewrite cascaded into the fake root's own proc/" >&2; exit 2; }
grep -qF "MSS_DIR=$FR/proc/device-tree/soc/qcom,mss@2080000" "$RW" \
  || { echo "MSS_DIR was not rewritten -- every later reading is compared against that node" >&2; exit 2; }
grep -qF "$FR/lib/firmware" "$RW" || { echo "the firmware search path was not rewritten" >&2; exit 2; }
grep -qF "$W/klog-out.txt" "$RW" || { echo "the kernel-log scratch path was not rewritten" >&2; exit 2; }

# --- the static safety guard, and its teeth --------------------------------------------------------
#
# What counts as a write: a redirect into /sys, /proc or a block device; a state-changing systemctl verb;
# and dd/mkfs/mount/umount/fstrim/modprobe/insmod/rmmod/setprop/tee in COMMAND POSITION. Command position
# is required because the probe's own `--explain` text is prose about mounting, and a guard that trips on
# the words "mount point" in a sentence is a guard nobody would keep.
#
# `mount` needs one more rule, because it is two commands with one name: bare `mount` LISTS the mounts (a
# read, and the probe greps its output), while `mount -o bind A B` changes the system. The allowlist below
# is exactly the read form the probe uses -- a `mount` whose output is piped -- and the teeth section
# proves it discriminates by feeding the guard a bind mount as well as a redirect.
#
# Reading is the job. Anything that changes state is out of scope BY DESIGN, not by omission.
WRITE_RE='(^|[;&|(`]|\$\()[[:space:]]*(dd|mkfs(\.ext4)?|mount|umount|fstrim|modprobe|insmod|rmmod|setprop|tee)[[:space:]]|>>?[[:space:]]*/(sys|proc|dev/block)|systemctl[[:space:]]+(start|stop|restart|enable|disable|mask|daemon-reload)'
MOUNT_LIST_RE='\$\(mount([[:space:]]+2>/dev/null)?[[:space:]]*\|'
writes_in() { grep -nE -- "$WRITE_RE" "$1" 2>/dev/null | grep -vE -- "$MOUNT_LIST_RE"; }
# The teeth need to prove the guard is not simply "any mention of mount": a bind mount has to be caught.
bindmount_in() { grep -nE -- 'mount[[:space:]]+-o[[:space:]]+bind' "$1" 2>/dev/null; }

# --- the stubs -------------------------------------------------------------------------------------
# The kernel log. FAKE_KLOG_RC non-zero is the scenario that matters: `journalctl` failing prints nothing,
# and the verdict must not read that as a boot in which the driver was silent.
cat > "$STUB/journalctl" <<EOF
#!/bin/sh
printf 'journalctl %s\n' "\$(printf '%s' "\$*" | tr '\n' ' ')" >> "$ACT"
[ "\${FAKE_KLOG_RC:-0}" != 0 ] && exit "\${FAKE_KLOG_RC}"
cat "$W/klog.txt" 2>/dev/null
exit 0
EOF
cat > "$STUB/lxc-info" <<EOF
#!/bin/sh
printf 'lxc-info %s\n' "\$*" >> "$ACT"
[ -n "\${FAKE_CONTAINER:-}" ] && printf '%s\n' "\$FAKE_CONTAINER"
exit 0
EOF
# nsenter: the container's view of the firmware mount point. It must not enter anything, and its ANSWER is
# switchable, because "the namespace said nothing" and "the path is absent" are different readings.
cat > "$STUB/nsenter" <<EOF
#!/bin/sh
printf 'nsenter %s\n' "\$(printf '%s' "\$*" | tr '\n' ' ')" >> "$ACT"
case "\${FAKE_CONTAINER_FWMNT:-}" in
present) printf '%s\n' "/vendor/firmware_mnt" ;;
esac
exit 0
EOF
cat > "$STUB/systemctl" <<EOF
#!/bin/sh
printf 'systemctl %s\n' "\$(printf '%s' "\$*" | tr '\n' ' ')" >> "$ACT"
case "\$*" in
*ofono*) printf '%s' "\${FAKE_OFONO:-}" ;;
*ModemManager*) printf '%s' "\${FAKE_MODEMANAGER:-}" ;;
esac
exit 0
EOF
cat > "$STUB/gdbus" <<EOF
#!/bin/sh
printf 'gdbus %s\n' "\$(printf '%s' "\$*" | tr '\n' ' ')" >> "$ACT"
[ -n "\${FAKE_OFONO_OWNER:-}" ] && printf "('%s',)\n" "\$FAKE_OFONO_OWNER"
exit 0
EOF
# mount: a TABLE, because the probe greps it. FAKE_FW=mnt|both puts the modem line in it.
cat > "$STUB/mount" <<EOF
#!/bin/sh
printf 'mount %s\n' "\$*" >> "$ACT"
[ -f "$W/mount.txt" ] && cat "$W/mount.txt"
exit 0
EOF
chmod +x "$STUB"/*
export ACT W

# --- the fake device, written ONCE with every switch in it -----------------------------------------
#
# The fixture is a script rather than a pile of inline writes because a scenario must be able to change the
# device and have that change be the ONLY difference. The GPS harness learned the hard way that a scenario
# deleting a fixture which the next scenario does not recreate means every later scenario is testing the
# deletion (docs 119 §5.2), so all of it lives here and every switch defaults to absent.
cat > "$W/reset.sh" <<EOF
#!/bin/sh
set -u
rm -rf "$FR"
mkdir -p "$FR/proc/device-tree/soc/qcom,mss@2080000" "$FR/proc/sys/kernel/random" \\
         "$FR/sys/module/firmware_class/parameters" "$FR/sys/bus/msm_subsys/devices/subsys0" \\
         "$FR/sys/class/net" "$FR/dev/block/bootdevice/by-name" "$FR/lib/firmware" \\
         "$FR/vendor/firmware_mnt" "$FR/firmware" 2>/dev/null
printf '%s\\0' "\${FAKE_COMPAT:-qcom,msm8996pro}" > "$FR/proc/device-tree/compatible"
printf 'qcom,pil-q6v55-mss\\0' > "$FR/proc/device-tree/soc/qcom,mss@2080000/compatible"
[ "\${FAKE_NO_FWNODE:-0}" = 1 ] || printf '%s\\0' "\${FAKE_FWNAME:-modem}" > "$FR/proc/device-tree/soc/qcom,mss@2080000/qcom,firmware-name"
[ "\${FAKE_NO_SELFAUTH:-0}" = 1 ] || : > "$FR/proc/device-tree/soc/qcom,mss@2080000/qcom,pil-self-auth"
printf 'ok\\0' > "$FR/proc/device-tree/soc/qcom,mss@2080000/status"
: > "$FR/sys/module/firmware_class/parameters/path"
printf '4.9.186-perf+\n' > "$FR/proc/sys/kernel/osrelease"
printf 'aaaa-bbbb-cccc\n' > "$FR/proc/sys/kernel/random/boot_id"
# The subsystem-restart view: a modem that did NOT come up. That is the honest default -- this port has
# never shown it up, and the harness must not hand the probe a healthy modem and call that the baseline.
printf 'modem\n' > "$FR/sys/bus/msm_subsys/devices/subsys0/name"
printf 'OFFLINE\n' > "$FR/sys/bus/msm_subsys/devices/subsys0/state"
: > "$FR/dev/block/bootdevice/by-name/modem"
# FAKE_FW=path puts the firmware on the KERNEL's search path; =mnt mounts only the partition; =both both.
case "\${FAKE_FW:-}" in
path|both)
  : > "$FR/lib/firmware/modem.mdt"; : > "$FR/lib/firmware/modem.b00"; : > "$FR/lib/firmware/mba.mbn" ;;
esac
case "\${FAKE_FW:-}" in
mnt|both) : > "$FR/vendor/firmware_mnt/modem.mdt"; : > "$FR/vendor/firmware_mnt/mba.mbn" ;;
esac
: > "$W/mount.txt"
case "\${FAKE_FW:-}" in
mnt|both) printf '/dev/block/bootdevice/by-name/modem on /vendor/firmware_mnt type vfat (ro,shortname=lower)\n' > "$W/mount.txt" ;;
esac
# The kernel log. The baseline mentions the modem but shows no failure, and is deliberately NOT empty: an
# all-empty baseline would make "the (none) line prints" untestable.
printf 'msm_pil: pil-q6v55-mss: modem subsystem probe started\n' > "$W/klog.txt"
[ "\${FAKE_KLOG_QUIET:-0}" = 1 ] && printf 'random early boot noise\n' > "$W/klog.txt"
exit 0
EOF
chmod +x "$W/reset.sh"

# --- the checks ------------------------------------------------------------------------------------
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
want() { if printf '%s\n' "$2" | grep -Eq -- "$1"; then ok "$3"; else bad "$3"; printf '%s\n' "$2" | grep -n . | sed 's/^/        | /'; fi; }
notwant() { if printf '%s\n' "$2" | grep -Eq -- "$1"; then bad "$3"; printf '%s\n' "$2" | grep -E -- "$1" | sed 's/^/        | /'; else ok "$3"; fi; }
# The verdict is the LAST section, so it runs from its own header to the end of the output. Anchored on
# that header, not on the first `->` line anywhere: the probe prints `->` lines in earlier sections, and a
# verdict extractor that took the first of those would make every assertion about a different paragraph
# (docs 119 §5.2, defect 1). The heading is numbered ("== 7. verdict"), which is why this is a pattern and
# not an equality test -- the first draft's `^== verdict$` matched nothing and every verdict assertion was
# silently testing an empty string.
verdict() { printf '%s\n' "$1" | sed -n '/^== [0-9][0-9]*\. *verdict$/,$p'; }

# Which FAKE_* the probe's stubs must see (they are inherited by the stubbed commands the probe runs).
export FAKE_KLOG_RC=0 FAKE_CONTAINER=700 FAKE_OFONO= FAKE_MODEMANAGER= FAKE_OFONO_OWNER= \
       FAKE_CONTAINER_FWMNT= FAKE_COMPAT= FAKE_FWNAME= FAKE_NO_FWNODE= FAKE_NO_SELFAUTH= \
       FAKE_FW= FAKE_KLOG_QUIET=

run() { # $1 = extra arguments (may be empty)
  : > "$ACT"
  "$W/reset.sh"
  # The interpreter is named by its FULL PATH and the probe runs under `sh`, which is how it runs on the
  # device (`#!/bin/sh`). `env PATH=... bash` cannot work once PATH is the sandbox: env looks up the
  # program in the NEW path, and neither the sandbox nor the stub directory contains a shell.
  OUT="$( env PATH="$STUB:$MINBIN" "$SH_BIN" "$RW" $1 2>&1 )"
  RC=$?
}

echo "zl1 modem probe -- offline self-test"
echo "  script under test: $SRC"
echo "  fake device:       $FR"
echo

# ==================================================================================================
echo "== 0. it writes NOTHING -- checked statically, and the guard has teeth =="
# ==================================================================================================
# The most important section, and it is first for that reason.
HITS="$(writes_in "$SRC")"
if [ -z "$HITS" ]; then
  ok "the shipped probe contains no write to /sys, /proc, a block device, a module or a unit"
else
  bad "the probe contains a write:"
  printf '%s\n' "$HITS" | sed 's/^/        | /'
fi
# The teeth. `: > /sys/module/...` is chosen because it parses, looks harmless, and is exactly the kind of
# line that creeps in ("just reset the path first").
sed 's#^say "   firmware_class.path: \${FWPARAM}"$#: > /sys/module/firmware_class/parameters/path#' "$SRC" > "$W/mut-write.sh"
if cmp -s "$SRC" "$W/mut-write.sh"; then
  bad "the mutation did not land (its sed matches no line), so the guard below proves nothing"
else
  ok "the mutation really differs from the shipped file"
  MUT="$(writes_in "$W/mut-write.sh")"
  if [ -n "$MUT" ]; then
    ok "the guard CATCHES a write that is put back (so the check above is live)"
    want 'firmware_class/parameters/path' "$MUT" "and names the line it found"
  else
    bad "the write guard did not catch a reintroduced write -- it cannot fail, so the check above proves nothing"
  fi
fi
# The second tooth, for the one verb with two meanings: a BIND MOUNT must be caught even though the
# probe legitimately runs `mount` to list. Without this, an allowlist for `mount` could be widened to
# "anything mentioning mount" and no check would notice.
sed 's#^MOUNT_HITS=\$(mount 2>/dev/null | grep#MOUNT_HITS=$(mount -o bind /vendor/firmware_mnt /lib/firmware | grep#' "$SRC" > "$W/mut-bind.sh"
if cmp -s "$SRC" "$W/mut-bind.sh"; then
  bad "the bind-mount mutation did not land, so the allowlist below proves nothing"
else
  BM="$(writes_in "$W/mut-bind.sh")"
  if [ -n "$BM" ]; then
    ok "the guard catches a BIND MOUNT -- so its mount allowlist is not 'any mention of mount'"
    want 'mount -o bind /vendor/firmware_mnt /lib/firmware' "$BM" "and names the mount it found"
    [ -n "$(bindmount_in "$SRC")" ] && bad "the shipped probe itself contains a bind mount" \
                                     || ok "and the shipped probe contains none"
  else
    bad "the guard let a bind mount through: its mount allowlist is too wide to mean anything"
  fi
fi

# ==================================================================================================
echo
echo "== 1. the guard: not the zl1 =="
# ==================================================================================================
FAKE_COMPAT=qcom,sdm845 run ""
[ "$RC" = 2 ] && ok "a different SoC exits 2" || bad "it exited $RC on the wrong device"
want 'not the zl1' "$OUT" "and says what it is refusing"
want 'msm8996' "$OUT" "naming the string it wanted"
notwant 'qcom,firmware-name' "$OUT" "and reads nothing beyond the guard"
notwant 'journalctl' "$(cat "$ACT")" "and runs no command at all"
FAKE_COMPAT=

# ==================================================================================================
echo
echo "== 2. --explain reads nothing and says why each reading decides =="
# ==================================================================================================
run "--explain"
[ "$RC" = 0 ] && ok "--explain exits 0" || bad "--explain exited $RC"
want "THE DEVICE TREE'S OWN NAME FOR THE FIRMWARE" "$OUT" "it explains the firmware-name reading"
want 'request_firmware' "$OUT" "and the search path"
want 'shortname=lower' "$OUT" "and why the FAT name is upper-case while the kernel asks for lower"
want 'THE VERDICT names the rung' "$OUT" "and what the verdict is for"
notwant 'journalctl' "$(cat "$ACT")" "--explain reads no log"
notwant 'lxc-info' "$(cat "$ACT")" "and does not look at the container"

# ==================================================================================================
echo
echo "== 3. the healthy readings: every section answers, and the name comes from the device =="
# ==================================================================================================
run ""
[ "$RC" = 0 ] && ok "a full read exits 0" || bad "it exited $RC"
want 'compatible       qcom,pil-q6v55-mss' "$OUT" "the compatible string is printed"
want 'qcom,firmware-name modem' "$OUT" "and the firmware name the kernel will ask for"
want 'present   .present = TZ authenticates' "$OUT" "the self-auth property is reported as present"
want 'msm_subsys modem: state=OFFLINE' "$OUT" "the subsystem-restart view is read by name AND state"
want 'rmnet netdevs: 0' "$OUT" "a netdev count that is a number, not a blank"
want 'the firmware is NOT on the kernel' "$OUT" "with no firmware files, it says the file is not on the path"

# The name comes from the DEVICE. Change the node's value and the probe must follow it, not the word
# "modem" that a DTB in this repo happens to carry.
FAKE_FWNAME=modem_pr_v2 run ""
want 'qcom,firmware-name modem_pr_v2' "$OUT" "the firmware name is taken from the DEVICE TREE, not assumed"
want 'modem_pr_v2.mdt=MISSING' "$OUT" "and the search path is compared against THAT name"
notwant 'modem.mdt=' "$OUT" "and not against the literal word modem"
FAKE_FWNAME=

# ==================================================================================================
echo
echo "== 4. the firmware reaching the path, and where the firmware actually is =="
# ==================================================================================================
FAKE_FW=path run ""
want 'the firmware IS reachable by name, at' "$OUT" "firmware on the search path: it says so"
want 'mba.mbn=present' "$OUT" "and reports the MBA as present too"
want 'THE FIRMWARE IS REACHABLE' "$(verdict "$OUT")" "the verdict names that rung"
notwant 'NOT CONCLUDED' "$OUT" "and does not hedge a question it answered"

FAKE_FW=mnt run ""
want 'on /vendor/firmware_mnt type vfat' "$OUT" "the partition's mount line is printed"
want 'THE PARTITION IS MOUNTED somewhere but the firmware is not on the kernel' "$(verdict "$OUT")" \
  "mounted but off the search path: the verdict says exactly that -- the port-problem branch"
want 'bind mount or a' "$(verdict "$OUT")" "and names the fix, not a partition change"
want 'never' "$(verdict "$OUT")" "including that the modem partition must never be written"
notwant 'NOT REACHABLE AND NOTHING' "$(verdict "$OUT")" "and does not fall through to the rung below"

FAKE_FW=both run ""
want 'THE FIRMWARE IS REACHABLE' "$(verdict "$OUT")" "both: the reachable rung wins over the mount rung"
FAKE_FW=

# ==================================================================================================
echo
echo "== 5. the two UNANSWERED branches, which must never read as a negative =="
# ==================================================================================================
# (a) the kernel log could not be read. This is docs 117's case, and here it would otherwise say "the PIL
# driver logged nothing" about a log nobody read.
FAKE_KLOG_RC=1 run ""
[ "$RC" = 1 ] && ok "an unreadable kernel log exits 1" || bad "it exited $RC"
want 'COULD NOT READ THE KERNEL LOG' "$OUT" "it says the log could not be read"
want 'is 0 for THAT reason' "$OUT" "and says the zeroes below are for that reason"
want 'UNANSWERED' "$(verdict "$OUT")" "the verdict is UNANSWERED"
notwant 'the PIL driver logged nothing' "$OUT" "and it does NOT claim the driver was silent"
notwant 'THE FIRMWARE IS NOT REACHABLE' "$(verdict "$OUT")" "and does not reach the port-problem conclusion either"
FAKE_KLOG_RC=0

# (b) the device tree did not name the firmware. Then every later comparison would be against a guess --
# and the draft DID compare against one: it printed "the firmware is NOT on the kernel's search path"
# after asking no directory for any file. The harness found that (docs 120 §5).
FAKE_NO_FWNODE=1 run ""
[ "$RC" = 1 ] && ok "no firmware-name in the device tree exits 1" || bad "it exited $RC"
want 'qcom,firmware-name UNREADABLE' "$OUT" "it reports the node as unreadable"
want 'did not name the modem firmware' "$(verdict "$OUT")" "the verdict says the boot did not name it"
want 'not checked: the firmware name is unknown' "$OUT" "no directory is asked for a file it cannot name"
want 'NOT CONCLUDED' "$OUT" "and the search-path section refuses to conclude"
notwant 'the firmware is NOT on the kernel' "$OUT" "so it never reports the comparison as a negative"
FAKE_NO_FWNODE=0

# ==================================================================================================
echo
echo "== 6. the (none) lines actually print -- the pipeline trap =="
# ==================================================================================================
# With a boot whose kernel log mentions nothing the probe greps for, BOTH "(none: ...)" lines must appear.
# This is the check that would have caught `grep ... | tail | sed || say none`, whose none-branch is dead.
FAKE_KLOG_QUIET=1 run ""
want 'none: the PIL driver logged nothing about the modem on this boot' "$OUT" \
  "a boot that logged nothing: the named (none) line IS printed for the pil/mss grep"
want 'none: no firmware-load failure line in this boot' "$OUT" "and for the firmware-failure grep"
# And the negative direction: with a matching line, the (none) for THAT pattern must be gone while the
# other pattern keeps its own -- a harness that only ever sees both-or-neither would not test the pairing.
FAKE_KLOG_QUIET=0 run ""
notwant 'none: the PIL driver logged nothing' "$OUT" "with a matching line, its own (none) line is gone"
want 'none: no firmware-load failure line in this boot' "$OUT" "while the OTHER pattern keeps its own (none) line"
# The third such site: the container's mount namespace answering nothing.
FAKE_CONTAINER_FWMNT= run ""
want "the container's mount namespace answered nothing" "$OUT" "an nsenter that answered nothing says so"
notwant '^   \| /vendor/firmware_mnt$' "$OUT" "and does not read as a clean listing of no mount"
FAKE_CONTAINER_FWMNT=present run ""
want '^   \| /vendor/firmware_mnt$' "$OUT" "when the namespace does answer, the path is printed"
FAKE_CONTAINER_FWMNT=

# ==================================================================================================
echo
echo "== 7. the UT side: an active daemon is not a modem =="
# ==================================================================================================
FAKE_OFONO=active run ""
want 'systemctl is-active ofono: active' "$OUT" "ofono's unit state is printed"
want 'org.ofono on the system bus: not owned' "$OUT" "and the bus name is read as NOT owned"
want 'did not get far enough to publish anything' "$OUT" "with the sentence that says what that means"
notwant 'gdbus is not on this device' "$OUT" "and it does not claim gdbus is missing"
FAKE_OFONO=

FAKE_OFONO_OWNER=:1.42 run ""
want 'org.ofono on the system bus: :1.42' "$OUT" "an owned bus name is printed as the owner"
notwant 'org.ofono on the system bus: not owned' "$OUT" "and not as 'not owned'"
FAKE_OFONO_OWNER=

# gdbus absent is a THIRD answer and must not be reported as "not owned". It is also the one scenario where
# this host's own /usr/bin/gdbus would silently take over if PATH were not sandboxed -- hence MINBIN.
mv "$STUB/gdbus" "$STUB/gdbus.hidden"
run ""
want 'gdbus is not on this device' "$OUT" "with no gdbus, it says the name was NOT READ"
want 'not .not owned.' "$OUT" "and explicitly that this is not the same as 'not owned'"
mv "$STUB/gdbus.hidden" "$STUB/gdbus"

# ==================================================================================================
echo
echo "== 8. --quiet keeps the headings, the boot identity and the verdict -- and nothing else =="
# ==================================================================================================
run "--quiet"
want 'boot: aaaa-bbbb-cccc' "$OUT" "--quiet keeps the boot identity (a verdict with no boot is not attributable)"
want '== 3\. where the modem firmware actually is' "$OUT" "and the section headings, so the verdict can be read"
notwant 'compatible       qcom' "$OUT" "--quiet drops the reading lines"
notwant 'pil-q6v5 ' "$OUT" "and the per-pattern counts"
notwant 'none: the PIL driver logged nothing' "$OUT" "and the (none) lines, which are readings like any other"
want '== 7\. verdict' "$OUT" "--quiet still prints the verdict's header"
want 'THE FIRMWARE IS NOT REACHABLE' "$(verdict "$OUT")" "and the verdict itself"
# The UNANSWERED branches are the ones a reader must never miss, so --quiet must keep them too.
FAKE_KLOG_RC=1 run "--quiet"
want 'UNANSWERED' "$(verdict "$OUT")" "--quiet still prints the UNANSWERED verdict"
FAKE_KLOG_RC=0

# ==================================================================================================
echo
echo "== 9. it never opens a block device, and never touches anything that resets a subsystem =="
# ==================================================================================================
run ""
notwant '(^| )(dd|mkfs|modprobe|insmod|rmmod) ' "$(cat "$ACT")" \
  "the actions taken name no block-device writer and no module operation"
notwant 'systemctl (start|stop|restart|enable|disable|mask)' "$(cat "$ACT")" \
  "and no systemctl verb that changes state"
want 'nsenter -t 700 -m -- ls -d' "$(cat "$ACT")" "the container is entered for its MOUNT TABLE only"
# `-p` as a FLAG, not as a substring: the fake root's own path contains "-probe", which a loose pattern
# reads as the PID-namespace flag and would make this assertion fail on a correct script.
notwant 'nsenter[^|]*-p([[:space:]]|$)' "$(cat "$ACT")" \
  "and NOT with -p (nothing here needs binder, and -p is the namespace that reaches it)"

# ==================================================================================================
echo
echo "== 10. the health check cites this harness's count, and that citation cannot drift =="
# ==================================================================================================
# `host/zl1-health-check.sh` is the first thing a human reads and it names each harness WITH A CHECK COUNT,
# typed by hand -- so every time a harness gains an assertion its citation goes stale and nothing notices.
# Every harness the page cites checks its own citation; this is that check.
HEALTH="$HERE/zl1-health-check.sh"
if [ -r "$HEALTH" ]; then
  cited=$(tr '\n' ' ' < "$HEALTH" | sed -n 's/.*zl1-modem-probe-selftest\.sh[^0-9]*\([0-9][0-9]*\) checks.*/\1/p')
  total=$((PASS + FAIL + 1))
  if [ -z "$cited" ]; then
    bad "the health check does not cite this harness's count -- the citation is gone or its wording changed"
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
