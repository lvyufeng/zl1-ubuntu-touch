#!/usr/bin/env bash
# zl1 modem probe -- offline self-test. Host-side, touches no device, needs no phone.
#
# Why this exists. `scripts/device/zl1-modem-probe.sh` is the first instrument for the one subsystem this
# port has never looked at (telephony/modem), and it is the instrument with the worst failure mode if it
# is wrong in the usual way: a probe that reads an unreadable kernel log as "the driver said nothing"
# would report a dead modem as a quiet boot, which is how a whole subsystem stays unexamined for months.
# So the harness holds it to five things, in this order of importance:
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
#   5. THE STRINGS IT MATCHES ARE THE STRINGS THE IMAGE PRINTS. The probe reads the boot's own report by
#      matching text, and that text is printed by boot/patches/0200-halium-modem-firmware-mount.patch -- a
#      different file. One reworded report would turn its mount reading into "the initramfs said nothing",
#      which is docs 117's false negative arriving through the back door. Section 10 therefore takes every
#      `tell_kmsg` string OUT OF THE PATCH, classifies it (mount report / not), and makes the probe read the
#      patch's own wording -- so the typed fixtures elsewhere cannot drift from the shipped image unnoticed.
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
for t in awk basename cat cut head ls readlink sed sort tail tr uniq wc grep; do
  p="$(type -P "$t" 2>/dev/null)" || continue
  [ -n "$p" ] && ln -sf "$p" "$MINBIN/$t"
done
for t in awk grep ls readlink sed tail tr wc; do
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
# /firmware`, `for sl in /vendor /android /firmware`, and the firmware search PATHS) -- and the
# replacement KEEPS that space, or the list loses its separators and `for mp in A B C` becomes the single
# word `inABC`, which is a syntax error rather than a wrong reading. A bare `/firmware` rule would also hit
# `/lib/firmware`, so that one is written for the list element it means and not for the substring; the same
# is true of `/vendor` and `/android` against `/vendor/firmware_mnt` and `/android/vendor/firmware_mnt`,
# which is why those two rules come LAST -- sed applies the -e rules in order to each line, so the specific
# path is consumed before the general one can see it.
P1="$W/pass1.sh"
sed -e 's# /android/vendor/firmware_mnt# __ZA1__#g' \
    -e 's# /vendor/firmware_mnt# __ZM1__#g' \
    -e 's# /lib/firmware# __ZL1__#g' \
    -e 's# /firmware# __ZF1__#g' \
    -e 's#/var/lib/lxc#__ZLV__#g' \
    -e 's#/userdata/zl1-kmsg#__ZU__#g' \
    -e 's# /vendor# __ZV1__#g' \
    -e 's# /android# __ZA2__#g' \
    -e 's#/tmp/zl1-modem-klog.txt#__ZK__#g' \
    -e 's#/proc/#__ZP__#g' \
    -e 's#/sys/#__ZS__#g' \
    -e 's#/dev/#__ZD__#g' "$SRC" > "$P1"

RW="$W/modem-probe.sh"
sed -e "s#__ZA1__#$FR/android/vendor/firmware_mnt#g" \
    -e "s#__ZM1__#$FR/vendor/firmware_mnt#g" \
    -e "s#__ZL1__#$FR/lib/firmware#g" \
    -e "s#__ZF1__#$FR/firmware#g" \
    -e "s#__ZLV__#$FR/var/lib/lxc#g" \
    -e "s#__ZU__#$FR/userdata/zl1-kmsg#g" \
    -e "s#__ZV1__#$FR/vendor#g" \
    -e "s#__ZA2__#$FR/android#g" \
    -e "s#__ZK__#$W/klog-out.txt#g" \
    -e "s#__ZP__#$FR/proc/#g" \
    -e "s#__ZS__#$FR/sys/#g" \
    -e "s#__ZD__#$FR/dev/#g" "$P1" > "$RW"
sh -n "$RW" || { echo "the rewritten probe does not parse" >&2; exit 2; }

# A token left behind would be a path that silently cannot exist, so it is a setup failure, not a finding.
if grep -q -- '__Z' "$RW"; then
  echo "an unexpanded token is left in $RW:" >&2
  grep -n -- '__Z' "$RW" | sed -n '1,5p' >&2
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
# The paths added when the probe learned to read the boot cmdline, the symlink chain and halium's fstab.
# The first is exact; the other two are identities rather than counts, because a list element ` /vendor`
# is consumed by the SPECIFIC rule when it is followed by `/firmware_mnt` and by the general one when it
# is not -- so the total must be the two together, and a rule that stopped firing would show up here.
[ "$(cnt '/var/lib/lxc' "$SRC")" = "$(cnt '__ZLV__' "$P1")" ] \
  || { echo "the /var/lib/lxc rewrite did not cover every occurrence (halium's fstab glob)" >&2; exit 2; }
# The kmsg drain's snapshot directory, added when the probe learned to read the boot's own initramfs report
# out of the snapshot the drain takes while the boot is young. A miss here would have the probe read THIS
# HOST's /userdata, which does not exist -- so it would answer "the drain is not installed" on a device
# where it is.
[ "$(cnt '/userdata/zl1-kmsg' "$SRC")" = "$(cnt '__ZU__' "$P1")" ] \
  || { echo "the /userdata/zl1-kmsg rewrite did not cover every occurrence (the kmsg drain's snapshots)" >&2; exit 2; }
[ "$(cnt ' /firmware' "$SRC")" = "$(cnt '__ZF1__' "$P1")" ] \
  || { echo "the /firmware list-element rewrite did not cover every occurrence" >&2; exit 2; }
# This one caught a real leak the first time it ran: the built-in search list was written as
# `PATHS="/lib/firmware/updates/$KREL ..."` -- the FIRST element had a quote before it instead of a space,
# so it was never rewritten and the probe asked THIS HOST's /lib/firmware/updates whether it held the
# modem firmware. It answered MISSING, so nothing looked wrong; a host that HAD that directory would have
# been read as if it were the phone. The probe's list now starts with a space (`for d in $PATHS` ignores
# it) and this identity is what keeps every element covered.
[ "$(cnt ' /lib/firmware' "$SRC")" = "$(cnt '__ZL1__' "$P1")" ] \
  || { echo "the /lib/firmware rewrite missed an element (the list's first element has no leading space?)" >&2; exit 2; }
[ "$(cnt ' /vendor' "$SRC")" = "$(( $(cnt '__ZV1__' "$P1") + $(cnt '__ZM1__' "$P1") ))" ] \
  || { echo "the /vendor rewrite does not add up: bare + /vendor/firmware_mnt != every ' /vendor'" >&2; exit 2; }
[ "$(cnt ' /android' "$SRC")" = "$(( $(cnt '__ZA2__' "$P1") + $(cnt '__ZA1__' "$P1") ))" ] \
  || { echo "the /android rewrite does not add up: bare + /android/vendor/firmware_mnt != every ' /android'" >&2; exit 2; }
# And the cascade, named as itself: the fake root's own path appearing immediately after itself, or a
# device path landing INSIDE the fake root's proc/ directory.
grep -qF "$FR$FR" "$RW" && { echo "a rewrite cascaded: $FR appears twice in a row" >&2; exit 2; }
grep -qF "$FR/proc/$FR" "$RW" && { echo "a rewrite cascaded into the fake root's own proc/" >&2; exit 2; }
grep -qF "MSS_DIR=$FR/proc/device-tree/soc/qcom,mss@2080000" "$RW" \
  || { echo "MSS_DIR was not rewritten -- every later reading is compared against that node" >&2; exit 2; }
grep -qF "$FR/lib/firmware" "$RW" || { echo "the firmware search path was not rewritten" >&2; exit 2; }
grep -qF "$FR/var/lib/lxc/android/rootfs/fstab*" "$RW" \
  || { echo "the halium fstab glob was not rewritten -- the probe would read this host's /var/lib/lxc" >&2; exit 2; }
grep -qF "$W/klog-out.txt" "$RW" || { echo "the kernel-log scratch path was not rewritten" >&2; exit 2; }
grep -qF "$FR/userdata/zl1-kmsg" "$RW" \
  || { echo "the kmsg drain's directory was not rewritten -- the probe would read this host's /userdata" >&2; exit 2; }

# --- the static safety guard, and its teeth --------------------------------------------------------
#
# What counts as a write: a redirect into /sys, /proc or a block device; a state-changing systemctl verb;
# and dd/mkfs/mount/umount/fstrim/modprobe/insmod/rmmod/setprop/tee in COMMAND POSITION. Command position
# is required because the probe's own `--explain` text is prose about mounting, and a guard that trips on
# the words "mount point" in a sentence is a guard nobody would keep.
#
# A CLEARED RING IS A WRITE, and it is the one write this probe could make that destroys something with no
# other copy. The initramfs's report is written ONCE into the kernel ring, and the ring is the only place
# it lands -- so `dmesg -c` (or `-C`, `--clear`, `--read-clear`) is a write to the one piece of evidence
# the whole section exists to read. That is why it is in the same list as `dd`.
#
# It is in COMMAND POSITION for the same reason the verbs above are, and with ONE deliberate exclusion: the
# boundary for this rule is the start of a line or `;`/`&`/`|` or `$(`, and NOT a backtick or `(`. The
# probe's own header forbids the shape in a sentence, and the sentence writes it in backticks -- so a class
# that included a backtick would fire on the sentence forbidding the write, and that is the rule somebody
# deletes rather than fixes (the arrow rule's story, one line up). The teeth below prove both halves: a real
# `dmesg -c` is caught, and the sentence that forbids it is not read as one.
WRITE_RE='(^|[;&|(`]|\$\()[[:space:]]*(dd|mkfs(\.ext4)?|mount|umount|fstrim|modprobe|insmod|rmmod|setprop|tee)[[:space:]]|(^|[;&|]|\$\()[[:space:]]*dmesg[[:space:]]+(-[cC]|--clear|--read-clear)|(^|[^-])>>?[[:space:]]*/(sys|proc|dev/block)|systemctl[[:space:]]+(start|stop|restart|enable|disable|mask|daemon-reload)'
# `mount` needs one more rule, because it is two commands with one name: bare `mount` LISTS the mounts (a
# read, and the probe greps its output), while `mount -o bind A B` changes the system. The allowlist below
# is exactly the read form the probe uses -- a `mount` whose output is piped -- and the teeth section
# proves it discriminates by feeding the guard a bind mount as well as a redirect.
#
# The redirect rule excludes `->`: an arrow before a path is prose (the probe's own readings are written
# as `-> /proc/cmdline could not be read`), while a redirect needs the `>` in command position. The
# requirement is a character that is NOT `-` immediately before the `>` -- which still catches `x>/proc/y`
# (the `x` is that character) and `echo 1 > /proc/y` (a space is). A guard that trips on the probe's own
# prose would be "fixed" by weakening it, which is how a guard stops guarding; so it is made exact here
# and the teeth below prove the redirect shape is still caught.
#
# Reading is the job. Anything that changes state is out of scope BY DESIGN, not by omission.
MOUNT_LIST_RE='\$\(mount([[:space:]]+2>/dev/null)?[[:space:]]*\|'
writes_in() { grep -nE -- "$WRITE_RE" "$1" 2>/dev/null | grep -vE -- "$MOUNT_LIST_RE"; }
# The teeth need to prove the guard is not simply "any mention of mount": a bind mount has to be caught.
bindmount_in() { grep -nE -- 'mount[[:space:]]+-o[[:space:]]+bind' "$1" 2>/dev/null; }

# --- the stubs -------------------------------------------------------------------------------------
# The kernel log, THREE stubs for three sources, because the probe now reads the boot's own initramfs
# report out of whichever of them really carries the boot phase. Two properties matter for each:
#   * the content is the HARNESS's (`$W/klog.txt`, `$W/dmesg.txt`), never this laptop's ring -- a probe
#     reading the host's dmesg would answer about the wrong machine while every scenario "passed";
#   * a source CAN FAIL to answer, because "could not read" and "read and empty" must stay different.
# The old drain snapshot is what the probe reads FIRST, so its directory exists and holds one snapshot by
# default -- a device with the drain installed, which is the state the capture chain's other steps assume.
cat > "$STUB/journalctl" <<EOF
#!/bin/sh
printf 'journalctl %s\n' "\$(printf '%s' "\$*" | tr '\n' ' ')" >> "$ACT"
[ "\${FAKE_KLOG_RC:-0}" != 0 ] && exit "\${FAKE_KLOG_RC}"
cat "$W/klog.txt" 2>/dev/null
exit 0
EOF
cat > "$STUB/dmesg" <<EOF
#!/bin/sh
printf 'dmesg %s\n' "\$(printf '%s' "\$*" | tr '\n' ' ')" >> "$ACT"
[ "\${FAKE_DMESG_RC:-0}" != 0 ] && exit "\${FAKE_DMESG_RC}"
cat "$W/dmesg.txt" 2>/dev/null
exit 0
EOF
cat > "$STUB/lxc-info" <<EOF
#!/bin/sh
printf 'lxc-info %s\n' "\$*" >> "$ACT"
[ -n "\${FAKE_CONTAINER:-}" ] && printf '%s\n' "\$FAKE_CONTAINER"
exit 0
EOF
# nsenter: NO LONGER STUBBED AS A WORKING COMMAND (docs 162). The probe used to read the container's view
# by entering its mount namespace, and that is the call that hung it -- on 2026-09-25 the step outlived
# its device-side `timeout` and the phone reset a minute later. The replacement reads the same fact out of
# /proc/<pid>/mountinfo (fixtured in reset.sh above), so this stub is now a TRIPWIRE rather than a device:
# if any future edit puts a namespace entry back, the run does not quietly "pass" with a faked answer, it
# fails loudly and names itself.
cat > "$STUB/nsenter" <<EOF
#!/bin/sh
printf 'nsenter %s\n' "\$(printf '%s' "\$*" | tr '\n' ' ')" >> "$ACT"
printf 'THE HARNESS TRIPWIRE: this probe ran nsenter. The container is read via /proc/<pid>/mountinfo\n' >&2
exit 99
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
         "$FR/android/vendor" "$FR/android/firmware" "$FR/var/lib/lxc/android/rootfs" 2>/dev/null
# The rootfs's SYMLINKS, in the shape the port's own rootfs image has them: /vendor -> /android/vendor and
# /firmware -> /android/firmware (read out of the image with \`debugfs stat\`). The whole firmware question
# on this port turns on that chain, so a fixture whose /vendor is a plain directory would be testing a
# device that does not exist.
ln -sfn "$FR/android/vendor" "$FR/vendor"
ln -sfn "$FR/android/firmware" "$FR/firmware"
printf '%s\\0' "\${FAKE_COMPAT:-qcom,msm8996pro}" > "$FR/proc/device-tree/compatible"
printf 'qcom,pil-q6v55-mss\\0' > "$FR/proc/device-tree/soc/qcom,mss@2080000/compatible"
[ "\${FAKE_NO_FWNODE:-0}" = 1 ] || printf '%s\\0' "\${FAKE_FWNAME:-modem}" > "$FR/proc/device-tree/soc/qcom,mss@2080000/qcom,firmware-name"
[ "\${FAKE_NO_SELFAUTH:-0}" = 1 ] || : > "$FR/proc/device-tree/soc/qcom,mss@2080000/qcom,pil-self-auth"
printf 'ok\\0' > "$FR/proc/device-tree/soc/qcom,mss@2080000/status"
: > "$FR/sys/module/firmware_class/parameters/path"
# The RUNNING path is a different reading from the boot's, so it is switchable: empty by default (the
# stock device's value lives in the cmdline), and settable so "the two readings disagree" has a scenario.
if [ -n "\${FAKE_FWPATH_SYSFS:-}" ]; then printf '%s' "\$FAKE_FWPATH_SYSFS" > "$FR/sys/module/firmware_class/parameters/path"; fi
# The BOOT CMDLINE. This is the device's real one -- docs 20 records it from the stock boot image, and the
# v63 images inherit it verbatim -- with the fake root substituted so the path resolves into the fixture.
# The firmware path it carries is the one the whole probe is about, so the fixture carries it by default;
# the two switches produce the two other readings (no such key, and no such file at all).
if [ "\${FAKE_NO_CMDLINE:-0}" = 1 ]; then
  :
elif [ "\${FAKE_CMDLINE_NO_FWPATH:-0}" = 1 ]; then
  printf 'androidboot.hardware=qcom ehci-hcd.park=3 apparmor=1 security=apparmor loop.max_part=7\n' > "$FR/proc/cmdline"
else
  printf 'androidboot.hardware=qcom ehci-hcd.park=3 lpm_levels.sleep_disabled=1 cma=32M@0-0xffffffff androidboot.configfs=true apparmor=1 security=apparmor firmware_class.path=$FR/vendor/firmware_mnt/image loop.max_part=7\n' > "$FR/proc/cmdline"
fi
printf '4.9.186-perf+\n' > "$FR/proc/sys/kernel/osrelease"
printf 'aaaa-bbbb-cccc\n' > "$FR/proc/sys/kernel/random/boot_id"
# The subsystem-restart view: a modem that did NOT come up. That is the honest default -- this port has
# never shown it up, and the harness must not hand the probe a healthy modem and call that the baseline.
printf 'modem\n' > "$FR/sys/bus/msm_subsys/devices/subsys0/name"
printf 'OFFLINE\n' > "$FR/sys/bus/msm_subsys/devices/subsys0/state"
: > "$FR/dev/block/bootdevice/by-name/modem"
# Where the firmware is. \`path\` = only the KERNEL's built-in list; \`cmdfw\` = the directory the cmdline
# names, reached THROUGH the /vendor symlink (the real device shape: the FAT keeps the file one level
# down, in \`image/\`); \`mnt\` = at the mount point but not one level down where the cmdline points;
# \`both\` = both places.
case "\${FAKE_FW:-}" in
path|both)
  : > "$FR/lib/firmware/modem.mdt"; : > "$FR/lib/firmware/modem.b00"; : > "$FR/lib/firmware/mba.mbn" ;;
esac
case "\${FAKE_FW:-}" in
cmdfw|both)
  mkdir -p "$FR/android/vendor/firmware_mnt/image"
  : > "$FR/android/vendor/firmware_mnt/image/modem.mdt"
  : > "$FR/android/vendor/firmware_mnt/image/mba.mbn" ;;
mnt)
  mkdir -p "$FR/android/vendor/firmware_mnt"
  : > "$FR/android/vendor/firmware_mnt/modem.mdt" ;;
esac
# halium's fstab: the file its mount loop reads on the UT path, before it mounts anything. Present with
# the modem line by default, because that is the shape a mounted partition comes with; the two switches
# are the failure shapes (no modem line, and no file at all -- which makes the loop mount nothing).
if [ "\${FAKE_NO_FSTAB:-0}" != 1 ]; then
  if [ "\${FAKE_FSTAB_NO_MODEM:-0}" = 1 ]; then
    printf '/dev/block/bootdevice/by-name/system /system ext4 ro wait\n' > "$FR/var/lib/lxc/android/rootfs/fstab.qcom"
  else
    printf '/dev/block/bootdevice/by-name/system /system ext4 ro wait\n/dev/block/bootdevice/by-name/modem /vendor/firmware_mnt vfat ro,shortname=lower,uid=0,gid=1000,dmask=227,fmask=337 wait\n#endhalium\n' > "$FR/var/lib/lxc/android/rootfs/fstab.qcom"
  fi
fi
# THE CONTAINER'S OWN MOUNT TABLE (docs 162), read as a FILE rather than by entering the namespace. The
# probe used to run \`nsenter -t 700 -m -- ls -d\`; that call is where it HUNG on 2026-09-25 and the device
# reset about a minute later, so the fixture is now what the replacement reads: the kernel's own
# /proc/<pid>/mountinfo, whose field 5 is the mount point AS THAT PROCESS SEES IT. \`present\` puts the
# modem's line in it; the default is a table that exists and does not mention it (which is the reading
# "the container does not have this mounted", NOT "the table could not be read"); and
# \`FAKE_NO_CONTAINER_MOUNTINFO=1\` is the third state, where the table is absent altogether.
mkdir -p "$FR/proc/700/root/vendor"
if [ "\${FAKE_NO_CONTAINER_MOUNTINFO:-0}" != 1 ]; then
  printf '179 35 179:48 / / rw,relatime shared:1 - ext4 /dev/block/bootdevice/by-name/system rw\\n' > "$FR/proc/700/mountinfo"
  if [ "\${FAKE_CONTAINER_FWMNT:-}" = present ]; then
    printf '180 35 179:49 / /vendor/firmware_mnt rw,relatime shared:1 - vfat /dev/block/bootdevice/by-name/modem rw\\n' >> "$FR/proc/700/mountinfo"
    mkdir -p "$FR/proc/700/root/vendor/firmware_mnt"
  fi
fi
# The mount TABLE, and its text is the DEVICE's rather than the fixture's: on the device the line really
# reads /vendor/firmware_mnt, so that is what a faithful fixture prints.
: > "$W/mount.txt"
case "\${FAKE_FW:-}" in
cmdfw|mnt|both) printf '/dev/block/bootdevice/by-name/modem on /vendor/firmware_mnt type vfat (ro,shortname=lower)\n' > "$W/mount.txt" ;;
esac
# The TWO logs the probe can read the boot's own report out of, and they are different sources answering
# the same question, so the fixture keeps them apart.
#
#  * \`$W/dmesg.txt\` IS THE KERNEL RING, and it is the source the initramfs's report is really in (the
#    initramfs writes it to /dev/kmsg). The default is THE DEVICE AS IT IS TODAY: a boot whose initramfs
#    reported the fstab it was looking for and then said nothing more, because an empty glob is silent in
#    an image without the docs-154 patch. That default is what makes the two readings separable -- the
#    "the glob matched, OR this image has no report" state is exactly this boot.
#    The other shapes are the patched initramfs's own lines, written here with the patch's OWN wording
#    (\`initrd: \` is the prefix halium's tell_kmsg adds).
#  * \`$W/klog.txt\` IS WHAT \`journalctl -b -k\` ANSWERS. It is THIN by default -- one line that carries no
#    boot-phase marker -- because that is what this device was measured to do (the kmsg drain's header,
#    2026-09-21: the journal is not capturing /dev/kmsg at all). Keeping the default faithful is what makes
#    the guard testable: a source this thin must NOT be accepted as the boot's log.
RING_BOOT='Linux version 4.9.186-perf+ (android@build) #1 SMP PREEMPT
initrd: Halium rootfs is /tmpmnt/rootfs.img
initrd: mounting android system image from userdata partition
initrd: checking fstab /var/lib/lxc/android/rootfs/fstab* for additional mount points'
RING_PIL='msm_pil: pil-q6v55-mss: modem subsystem probe started'
case "\${FAKE_RING:-}" in
fallback_mounted)
  printf '%s\n%s\n%s\n%s\n%s\n' "\$RING_BOOT" \
    'initrd: fstab /var/lib/lxc/android/rootfs/fstab* matched NO file; using the one this initramfs carries: /zl1-android-fstab' \
    'initrd: checking mount label modem' \
    'initrd: mounting /dev/disk/by-partlabel/modem as /android/vendor/firmware_mnt -t vfat -o ro,shortname=lower' \
    "\$RING_PIL" > "$W/dmesg.txt" ;;
no_fallback)
  printf '%s\n%s\n%s\n' "\$RING_BOOT" \
    'initrd: fstab /var/lib/lxc/android/rootfs/fstab* matched NO file and no fallback is present: NOTHING WILL BE MOUNTED' \
    "\$RING_PIL" > "$W/dmesg.txt" ;;
fallback_nodevice)
  printf '%s\n%s\n%s\n' "\$RING_BOOT" \
    'initrd: fstab /var/lib/lxc/android/rootfs/fstab* matched NO file; using the one this initramfs carries: /zl1-android-fstab' \
    'initrd: no device for label modem: tried /dev/disk/by-partlabel/modem and /dev/disk/* -- this line is skipped' > "$W/dmesg.txt" ;;
fallback_mountfailed)
  printf '%s\n%s\n%s\n' "\$RING_BOOT" \
    'initrd: fstab /var/lib/lxc/android/rootfs/fstab* matched NO file; using the one this initramfs carries: /zl1-android-fstab' \
    'initrd: MOUNT FAILED: /dev/disk/by-partlabel/modem as /android/vendor/firmware_mnt -t vfat -o ro,shortname=lower' > "$W/dmesg.txt" ;;
fallback_nomount)
  printf '%s\n%s\n%s\n' "\$RING_BOOT" \
    'initrd: fstab /var/lib/lxc/android/rootfs/fstab* matched NO file; using the one this initramfs carries: /zl1-android-fstab' \
    "\$RING_PIL" > "$W/dmesg.txt" ;;
noinitrd)
  printf 'Linux version 4.9.186-perf+ (android@build) #1 SMP PREEMPT\n%s\nrandom early boot noise\n' "\$RING_PIL" > "$W/dmesg.txt" ;;
label_only)
  # THE REPORT WITHOUT ITS FIRST LINE. \`RING_BOOT\` carries the "checking fstab ..." line, so this shape has
  # to be built from the boot phase alone -- and it is a real one: the snapshot the drain takes WHILE THE LOOP
  # IS STILL RUNNING ends at the line it had reached, and that is what the uptime in its name is for. The
  # state chain asked only about the \`checking fstab\` line, so it called this "the initramfs said NOTHING".
  printf 'Linux version 4.9.186-perf+ (android@build) #1 SMP PREEMPT\ninitrd: checking mount label modem\n' > "$W/dmesg.txt" ;;
thin)
  # A source with content but NO boot-phase marker: exactly the shape the old guard accepted, because "the
  # file is not empty" is satisfied by one line of anything.
  printf 'random early boot noise\n' > "$W/dmesg.txt" ;;
*)
  printf '%s\n%s\n' "\$RING_BOOT" "\$RING_PIL" > "$W/dmesg.txt" ;;
esac
# FAKE_KLOG_QUIET keeps its old meaning -- "a boot in which the modem was silent" -- and it is expressed as
# a ring that still HAS the boot phase and no longer has the modem's line. A fixture that dropped the boot
# phase instead would test a different thing entirely: a source the probe must refuse to read (see
# FAKE_DMESG_RC below, which is that scenario).
[ "\${FAKE_KLOG_QUIET:-0}" = 1 ] && printf '%s\n' "\$RING_BOOT" > "$W/dmesg.txt"
printf 'systemd-journald: one line the journal happened to keep\n' > "$W/klog.txt"
# The kmsg drain. ABSENT by default, so the ring is the source the scenarios above drive; \`FAKE_DRAIN=early\`
# installs the snapshot the probe prefers -- which is the whole point of that unit, since it is taken while
# the boot is young and the ring is a buffer that wraps. Two snapshots, so the EARLIEST has to be chosen by
# the uptime in the name rather than by directory order or a lexical sort (boot-2s must beat boot-160s).
if [ "\${FAKE_DRAIN:-0}" = early ]; then
  mkdir -p "$FR/userdata/zl1-kmsg"
  printf 'Linux version 4.9.186-perf+ (android@build) #1 SMP PREEMPT\ninitrd: checking fstab /snapshot-taken-at-2s for additional mount points\n' > "$FR/userdata/zl1-kmsg/boot-2s.log"
  printf 'nothing here but the tail of the ring\n' > "$FR/userdata/zl1-kmsg/boot-160s.log"
fi
exit 0
EOF
chmod +x "$W/reset.sh"

# --- the checks ------------------------------------------------------------------------------------
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
want() { if grep -Eq -- "$1" <<< "$2"; then ok "$3"; else bad "$3"; grep -n . <<< "$2" | sed 's/^/        | /'; fi; }
notwant() { if grep -Eq -- "$1" <<< "$2"; then bad "$3"; grep -E -- "$1" <<< "$2" | sed 's/^/        | /'; else ok "$3"; fi; }
# The LITERAL pair, for text that is not a pattern: `grep -F` on a here-string, and NOT `printf ... | grep -q`.
# The pipe would be the shape this tree has a guard for (host/zl1-selftest-family-selftest.sh): a harness that
# sets `pipefail` and puts an early-exiting reader on the right of a pipe reports the WRITER's death as the
# check's answer. A here-string has no writer process to die.
wantF() { if grep -Fq -- "$1" <<< "$2"; then ok "$3"; else bad "$3"; printf '        | wanted: %s\n' "$1"; fi; }
notwantF() { if grep -Fq -- "$1" <<< "$2"; then bad "$3"; printf '        | %s\n' "$1"; else ok "$3"; fi; }
# The verdict is the LAST section, so it runs from its own header to the end of the output. Anchored on
# that header, not on the first `->` line anywhere: the probe prints `->` lines in earlier sections, and a
# verdict extractor that took the first of those would make every assertion about a different paragraph
# (docs 119 §5.2, defect 1). The heading is numbered ("== 7. verdict"), which is why this is a pattern and
# not an equality test -- the first draft's `^== verdict$` matched nothing and every verdict assertion was
# silently testing an empty string.
verdict() { printf '%s\n' "$1" | sed -n '/^== [0-9][0-9]*\. *verdict$/,$p'; }

# Which FAKE_* the probe's stubs must see (they are inherited by the stubbed commands the probe runs).
export FAKE_KLOG_RC=0 FAKE_DMESG_RC=0 FAKE_RING= FAKE_DRAIN= FAKE_CONTAINER=700 FAKE_OFONO= \
       FAKE_MODEMANAGER= FAKE_OFONO_OWNER= \
       FAKE_CONTAINER_FWMNT= FAKE_NO_CONTAINER_MOUNTINFO= FAKE_COMPAT= FAKE_FWNAME= FAKE_NO_FWNODE= FAKE_NO_SELFAUTH= \
       FAKE_FW= FAKE_KLOG_QUIET= FAKE_NO_CMDLINE= FAKE_CMDLINE_NO_FWPATH= FAKE_FWPATH_SYSFS= \
       FAKE_NO_FSTAB= FAKE_FSTAB_NO_MODEM=

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
# The third tooth, and it was added the first time the guard fired on the probe itself: the probe writes
# its readings as `-> /proc/cmdline could not be read`, which the old redirect rule read as `> /proc/...`.
# So the rule now excludes a `-` immediately before the `>`, and BOTH halves of that need proving -- the
# exclusion must not have neutered the rule, and an arrow must not still be read as a write.
printf 'x > /proc/sys/kernel/foo\necho 1 >/sys/module/bar/baz\n' > "$W/mut-redir.txt"
if [ -n "$(writes_in "$W/mut-redir.txt")" ]; then
  ok "the redirect rule still catches a redirect, spaced and unspaced"
else
  bad "the redirect rule no longer catches a redirect -- the arrow exclusion went too far"
fi
printf 'say "     -> /proc/cmdline could not be read"\n' > "$W/mut-arrow.txt"
[ -z "$(writes_in "$W/mut-arrow.txt")" ] \
  && ok "and an arrow before a path is prose, not a write" \
  || bad "an arrow before a path is still read as a redirect, so the probe's own readings fail the guard"

# The fourth tooth, for the write with no other copy: a CLEARED RING. The variant that matters is `-c`,
# because it is both the shortest spelling and the one an author reaches for while debugging ("start from a
# clean ring") -- on an instrument whose whole purpose is to read what the initramfs wrote there once.
printf 'dmesg -c > /dev/null\n' > "$W/mut-ringclear.txt"
if [ -n "$(writes_in "$W/mut-ringclear.txt")" ]; then
  ok "the guard CATCHES a cleared kernel ring (dmesg -c) -- the evidence with no other copy"
else
  bad "the guard let 'dmesg -c' through: the one write that destroys the report this section reads"
fi
# ...and the other half, which is the reason the rule needs command position at all: the probe's header
# forbids the shape in prose, and a rule that fired on that sentence is one somebody would delete.
printf '# NEVER CLEARS THE RING. `dmesg -c`/`-C`/`--clear` destroys the only copy\n' > "$W/mut-ringprose.txt"
[ -z "$(writes_in "$W/mut-ringprose.txt")" ] \
  && ok "and the sentence forbidding it is prose, not a write" \
  || bad "the guard reads the probe's own prose as a cleared ring"

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
want 'The fix is at the MOUNT' "$(verdict "$OUT")" "and names the fix, not a partition change"
notwant 'firmware_class.path in the boot image' "$(verdict "$OUT")" \
  "and does NOT blame the boot image, whose cmdline already names the right directory"
want 'NEVER a write to' "$(verdict "$OUT")" "including that the modem partition must never be written"
notwant 'NOT REACHABLE AND NOTHING' "$(verdict "$OUT")" "and does not fall through to the rung below"

FAKE_FW=both run ""
want 'THE FIRMWARE IS REACHABLE' "$(verdict "$OUT")" "both: the reachable rung wins over the mount rung"
FAKE_FW=

# ==================================================================================================
echo
echo "== 4b. the boot cmdline's path, the symlink chain, and the mount loop that would create it =="
# ==================================================================================================
# This section exists because the offline pass changed the probe's own hypothesis: the boot image does NOT
# leave the firmware path unset -- every zl1 cmdline carries `firmware_class.path=/vendor/firmware_mnt/image`
# (docs 20 recorded the stock one) -- and in the UT rootfs `/vendor` is a SYMLINK to `/android/vendor`. So
# the decisive readings are the cmdline's path, the chain it resolves through, and whether halium's
# mount loop had an fstab to read at all. All three are now readings the probe takes, so all three are
# asserted here -- and the fixture carries the real shapes (the symlink, the `image/` level, the fstab).
run ""
want "firmware_class.path on the BOOT cmdline: +${FR}/vendor/firmware_mnt/image" "$OUT" \
  "the path THIS BOOT was given is read from /proc/cmdline, not from the sysfs parameter"
want 'NOT RESOLVED' "$OUT" \
  "and with nothing mounted, the path does not resolve at all -- which is a reading, not an error"
want "   ${FR}/vendor +-> ${FR}/android/vendor$" "$OUT" "the symlink chain itself is printed, not assumed"
want 'boot: aaaa-bbbb-cccc' "$OUT" "and the boot identity is still printed next to it"
notwant "firmware_class.path on the BOOT cmdline: +UNREADABLE" "$OUT" "with a readable cmdline it is not reported unreadable"

# THE LEVEL DEFECT. The FAT's root holds IMAGE/, so on a mounted partition the file is `image/modem.mdt`
# -- one directory below the mount point -- and the probe's first version asked only the mount point,
# which reports MISSING for firmware that is right there. This scenario is that shape exactly.
FAKE_FW=cmdfw run ""
want 'THE FIRMWARE IS REACHABLE' "$(verdict "$OUT")" \
  "firmware in the cmdline's directory (through the symlink): reachable"
want '^     image/modem\.mdt +present$' "$OUT" "the file is found at the level it is really at (image/)"
want '^     modem\.mdt +MISSING$' "$OUT" \
  "while the bare mount point reports MISSING -- which is why both levels are asked"
want 'resolves to: .*android/vendor/firmware_mnt/image' "$OUT" \
  "and with the partition mounted, THAT path resolves through the /vendor symlink"
want 'on /vendor/firmware_mnt type vfat' "$OUT" "and the mount line is read as well"
notwant 'NOT REACHABLE AND NOTHING' "$(verdict "$OUT")" "so it does not fall to the nothing-mounted rung"

# halium's fstab, three shapes. The first is the coherent one (the partition is mounted, so the fstab is
# there and names it); the second is a fstab that exists and does not mention the modem; the third is the
# one that explains a silent total gap -- no file at all, and the loop's `cat` fails without a message.
want 'fstab.qcom exists; the line halium would mount this partition with' "$OUT" \
  "the fstab halium's loop reads is looked for, and found"
want '/vendor/firmware_mnt +vfat' "$OUT" "and the modem line in it is printed"
FAKE_FSTAB_NO_MODEM=1 run ""
want 'none: that fstab has no modem or firmware_mnt line' "$OUT" \
  "a fstab without a modem line says so instead of printing nothing"
FAKE_FSTAB_NO_MODEM=
FAKE_NO_FSTAB=1 run ""
want 'NO SUCH FILE' "$OUT" "no fstab at all is reported as no file, not as an empty listing"
want 'MOUNTED NOTHING THIS BOOT' "$OUT" "and it says what that makes the mount loop do"
notwant 'fstab.qcom exists' "$OUT" "and does not claim to have read a file that is not there"

# The cmdline readings that are NOT a path: absent key, unreadable file, and a disagreement with sysfs.
FAKE_CMDLINE_NO_FWPATH=1 run ""
want 'firmware_class.path on the BOOT cmdline: +EMPTY' "$OUT" "a cmdline without the key reads EMPTY"
want 'this boot was given no path at all' "$OUT" "and says what EMPTY means here"
want 'This boot was given no firmware_class.path at all' "$(verdict "$OUT")" \
  "the verdict uses the cmdline reading, and says so in its own words"
FAKE_CMDLINE_NO_FWPATH=
FAKE_NO_CMDLINE=1 run ""
want 'firmware_class.path on the BOOT cmdline: +UNREADABLE' "$OUT" "an unreadable /proc/cmdline reads UNREADABLE"
want 'what THIS BOOT was told is UNKNOWN' "$OUT" "and is not reported as 'no path was set'"
want 'What this boot was told is UNKNOWN' "$(verdict "$OUT")" "the verdict says the same thing"
notwant 'This boot was given no firmware_class.path at all' "$(verdict "$OUT")" \
  "and does NOT reach the EMPTY conclusion, which is a different reading"
FAKE_NO_CMDLINE=
FAKE_FWPATH_SYSFS=/some/other/place run ""
want 'and the RUNNING parameter does not match it' "$OUT" \
  "a sysfs value that differs from the boot's is called out as two answers, not averaged"
want 'some/other/place +modem\.mdt=MISSING' "$OUT" "and the running value is asked for the file too"
FAKE_FWPATH_SYSFS=

# And the verdict's last rung now names the path this boot was given, which is the sentence that turns
# "nothing is mounted" into a statement about a specific directory.
run ""
want 'What this boot WAS given points at' "$(verdict "$OUT")" \
  "the nothing-mounted verdict names the directory the kernel actually looked in"
want "${FR}/vendor/firmware_mnt/image +\(MISSING\)" "$(verdict "$OUT")" "and its existence, as a reading"
want 'halium.s mount loop reading an fstab that is not on this' "$(verdict "$OUT")" \
  "and the two mechanisms section 3 measures"

# ==================================================================================================
echo
echo "== 4c. the initramfs's OWN report -- the only witness to what the boot's mount loop did =="
# ==================================================================================================
# The change docs 154 shipped (boot/patches/0200-...) is invisible from the booted system: the UT rootfs
# image has no /scripts and no /zl1-android-fstab, and the initramfs is gone after switch_root. So the ONLY
# evidence that it ran is the initramfs's own kmsg report, and these scenarios are that evidence, in the
# states the shipped halium can produce. Each string below is the patch's OWN wording.
run ""
want 'source dmesg \(the live kernel ring' "$OUT" "the ring is read as a source, and named as one"
want 'CONTAINS THE BOOT PHASE' "$OUT" "and a source is only used when it really carries the boot phase"
want 'STATE: GLOB MATCHED, OR THIS IMAGE HAS NO REPORT' "$OUT" \
  "TODAY'S DEVICE: the loop reported the fstab it looked for and then said nothing -- which is an empty glob in an image without the report, OR a matched glob. The log cannot tell them apart, and it says so"
want 'THAT AMBIGUITY IS WHY THE REPORT WAS ADDED' "$OUT" "and names the ambiguity docs 154 removed"

# MOUNTED: the state the shipped image is built to produce.
FAKE_RING=fallback_mounted run ""
want 'STATE: MOUNTED' "$OUT" "the patched initramfs mounting the partition is recognised"
want 'matched NO file; using the one this initramfs carries' "$OUT" "and its own report line is shown, not summarised"
want 'as /android/vendor/firmware_mnt -t vfat' "$OUT" "including the mount line naming the device and the point"
want 'This is the reading that makes$' "$OUT" \
  "and it says what that does to section 3's listing of a CANDIDATE fstab"
notwant 'STATE: MOUNT FAILED' "$OUT" "and it is not confused with a failure"

# The three ways the mount can fail, and they are different next moves.
FAKE_RING=fallback_mountfailed run ""
want 'STATE: MOUNT FAILED' "$OUT" "a failed mount is its own state"
want 'It TRIED and the mount failed' "$OUT" "described as an attempt that failed, not as a missing file"
FAKE_RING=fallback_nodevice run ""
want 'STATE: DEVICE ABSENT' "$OUT" "a line whose device did not exist is its own state"
want 'points at the initramfs.s device population' "$OUT" "and points at udev, not at the partition"
FAKE_RING=no_fallback run ""
want 'STATE: NO FALLBACK -- the pre-fix silence, now audible' "$OUT" \
  "the report without a fallback is its own state, and it is the OLD behaviour made audible"
want 'That is the OLD behaviour made audible, not a device fault' "$OUT" "said in those words"
FAKE_RING=fallback_nomount run ""
want 'STATE: FALLBACK USED, NO MOUNT FOLLOWED' "$OUT" \
  "a fallback read with no mount after it is its own state -- a configuration answer, not a hardware one"

# NO INITRAMFS REPORT AT ALL: a usable log that simply has no initrd: line about a mount. It must NOT be
# read as "it mounted nothing".
FAKE_RING=noinitrd run ""
want 'STATE: NO INITRAMFS REPORT IN THIS LOG' "$OUT" "a boot log with no mount report says exactly that"
want 'It is not .it mounted nothing.' "$OUT" "and refuses the conclusion the absence would otherwise support"
notwant 'STATE: MOUNTED' "$OUT" "and claims no mount"

# THE REPORT PRESENT BUT INCOMPLETE. This is a state the probe was MISSING, and the defect was found here --
# by section 10, which drives each of the patch's report lines through the probe on its own: a log whose
# report starts at the mount label (a snapshot taken mid-loop, or a ring that wrapped) is not a boot whose
# initramfs said nothing, and the state chain -- which asked only about the `checking fstab` line -- said it
# was. It is asserted here as a scenario of its own, because a state added without one is a state nothing
# checks.
FAKE_RING=label_only run ""
want 'STATE: REPORT PRESENT, AND IT STOPS BEFORE THE MOUNT' "$OUT" \
  "a report that stops at the mount label is its own state"
notwant 'STATE: NO INITRAMFS REPORT IN THIS LOG' "$OUT" \
  "so it is NOT reported as a boot whose initramfs said nothing -- the false negative the old chain produced"
want 'checking mount label modem' "$OUT" "and the line the report does have is shown, not summarised"
want 'report IS in this log' "$OUT" "and the paragraph for that state explains what the shape means"

# THE DRAIN WINS WHEN IT EXISTS. It is a copy of the ring taken while the boot was young, so it is better
# evidence than the live ring -- and the EARLIEST snapshot is chosen by the uptime in its name, which is
# what the second half of this scenario proves (`boot-2s.log` must beat `boot-160s.log`).
FAKE_DRAIN=early run ""
want "source the kmsg drain's earliest snapshot \(.*boot-2s\.log\), taken while this boot was young" "$OUT" \
  "with the drain installed, the SNAPSHOT is the source, and the earliest one is picked by its uptime"
want 'snapshot-taken-at-2s' "$OUT" "and its CONTENT is what the rest of the section reads"
notwant 'source dmesg \(the live kernel ring' "$OUT" "and the live ring is not what was read"
notwant 'boot-160s.log' "$OUT" "with the LATER snapshot not chosen"

# ==================================================================================================
echo
echo "== 5. the UNANSWERED branches, which must never read as a negative =="
# ==================================================================================================
# (a) NO SOURCE CARRIED THIS BOOT. Every read of the log fails, so the load question has no answer. This is
# docs 117's case, and here it would otherwise say "the PIL driver logged nothing" about a log nobody read.
FAKE_KLOG_RC=1 FAKE_DMESG_RC=1 run ""
[ "$RC" = 1 ] && ok "with no readable source it exits 1" || bad "it exited $RC"
want 'NO SOURCE CARRIED THIS BOOT' "$OUT" "it says no source carried the boot"
want 'Every count below would be 0$' "$OUT" "and says the zeroes below are for that reason"
want 'UNANSWERED' "$(verdict "$OUT")" "the verdict is UNANSWERED"
notwant 'the PIL driver logged nothing' "$OUT" "and it does NOT claim the driver was silent"
notwant 'THE FIRMWARE IS NOT REACHABLE' "$(verdict "$OUT")" "and does not reach the port-problem conclusion either"
FAKE_KLOG_RC=0 FAKE_DMESG_RC=0

# (a2) THE GUARD THAT COULD NOT FAIL, which is the defect this section was fixed for. A source that answers
# with one line and no boot-phase marker satisfies "the file is not empty", so the OLD probe read it as a
# log, found nothing in it, and printed its reassurance -- about a boot it had never read. Both sources are
# thin here, and the reading must be UNANSWERED with the thinness NAMED. This is the assertion the previous
# version of the probe fails.
FAKE_RING=thin FAKE_KLOG_RC=0 run ""
[ "$RC" = 1 ] && ok "two thin sources: it exits 1 rather than answering" || bad "it exited $RC"
want 'NO boot-phase line' "$OUT" "a source with no boot phase is reported as thin"
want 'so it did NOT capture this boot' "$OUT" "and the reason is spelled out"
want 'NO SOURCE CARRIED THIS BOOT' "$OUT" "so no log is read at all"
notwant 'none: no firmware-load failure line' "$OUT" \
  "and it does NOT print the reassurance -- the false negative the old guard allowed"
want 'UNANSWERED' "$(verdict "$OUT")" "and the verdict is UNANSWERED"

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
# The third such site, and the shape changed in docs 162: the container's view is now read OUT OF THE
# KERNEL'S MOUNT TABLE rather than by entering the namespace. The two readings stay separable -- "the
# table was read and has no such entry" and "the table could not be read" are different sentences.
FAKE_CONTAINER_FWMNT= run ""
want 'no entry for .*/firmware_mnt in the container.s mount table' "$OUT" \
  "a container whose table does not mention the path says exactly that"
notwant '^   \| mounted: /vendor/firmware_mnt' "$OUT" "and does not read as a clean listing of a mount"
FAKE_CONTAINER_FWMNT=present run ""
want '^   \| mounted: /vendor/firmware_mnt' "$OUT" "when the table does have it, the mount is printed"
FAKE_CONTAINER_FWMNT=
FAKE_NO_CONTAINER_MOUNTINFO=1 run ""
want 'mountinfo could not be read' "$OUT" "and a table that cannot be read at all is its own third reading"
notwant 'no entry for /vendor/firmware_mnt' "$OUT" "which must not be worded as an empty table"
FAKE_NO_CONTAINER_MOUNTINFO=

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
FAKE_KLOG_RC=1 FAKE_DMESG_RC=1 run "--quiet"
want 'UNANSWERED' "$(verdict "$OUT")" "--quiet still prints the UNANSWERED verdict"
FAKE_KLOG_RC=0 FAKE_DMESG_RC=0

# ==================================================================================================
echo
echo "== 9. it never opens a block device, and never touches anything that resets a subsystem =="
# ==================================================================================================
run ""
notwant '(^| )(dd|mkfs|modprobe|insmod|rmmod) ' "$(cat "$ACT")" \
  "the actions taken name no block-device writer and no module operation"
notwant 'systemctl (start|stop|restart|enable|disable|mask)' "$(cat "$ACT")" \
  "and no systemctl verb that changes state"
# The ring-clear, asserted the SECOND way: not from the source text but from what the probe RAN. A `dmesg`
# whose arguments are recorded can be checked exactly, and this catches a clearing call however it is
# spelled in the script -- including one the static guard's command-position rule would not see.
notwant 'dmesg .*(-[cC]|--clear|--read-clear)' "$(cat "$ACT")" \
  "and it never CLEARS the ring (the initramfs's report has no other copy)"
want 'dmesg $' "$(cat "$ACT")" \
  "the ring is read with no arguments at all -- which is the only form that cannot clear it"
# THE CONTAINER IS READ, AND NOT ENTERED (docs 162). This assertion used to be `want 'nsenter -t 700 -m -- ls -d'`
# with a companion `notwant` for `-p`. Both are replaced by the stronger pair: the mount table must be read,
# and no nsenter may appear in the actions AT ALL. A `-p`-shaped exception is no longer needed because there
# is no longer a namespace to enter.
want 'its own mount table, read from' "$OUT" "the container's view is read as its own mount table"
notwant '(^|/)nsenter( |$)' "$(cat "$ACT")" \
  "and NOT by entering a namespace: that call is what hung this probe and reset the phone (docs 162)"
# The strongest form of the same claim, and the one that survives a future edit: the SOURCE contains no
# namespace entry at all. The ACT check above only sees what ran, and a probe that took a branch it did not
# take this run would still be carrying the call.
# The guard is on the CODE, not on the file: this probe's own header QUOTES the call it used to make
# (that is how a reader learns why it is gone), and this tree has already been bitten once by a grep that
# matched the prose naming a defect instead of the defect. So comments are stripped first, and the claim is
# about what would RUN.
notwant 'nsenter' "$(grep -v '^[[:space:]]*#' "$SRC")" \
  "and no EXECUTABLE line of the shipped probe mentions nsenter (comments may -- they explain the removal)"

# ==================================================================================================
echo
echo "== 10. the report strings the probe reads are the ones the patch PRINTS -- derived, not typed =="
# ==================================================================================================
# The probe answers "what did the initramfs actually do" by MATCHING TEXT, and the text it matches is
# printed by boot/patches/0200-halium-modem-firmware-mount.patch. Those two halves live in different files,
# so a reworded report -- one word changed in the patch -- would turn the probe's mount reading into "the
# initramfs said nothing", which is exactly the false negative docs 117 is about, and NOTHING in this tree
# would notice. The scenarios above type those strings BY HAND; this section takes them out of the patch
# instead and makes the probe read the patch's own wording.
#
# It is a CENSUS as well as a comparison: every `tell_kmsg` string in the patch must fall in one of the two
# buckets named below or the section fails -- so a report ADDED to the patch has to be classified here
# deliberately rather than being silently unasserted.
ZPATCH="$HERE/../../boot/patches/0200-halium-modem-firmware-mount.patch"
if [ ! -r "$ZPATCH" ]; then
  bad "cannot read boot/patches/0200-halium-modem-firmware-mount.patch -- the report strings this section derives are unchecked"
else
  # EVERY `tell_kmsg` argument in the patch, added lines and context lines alike: the report is the union of
  # what halium already said and what the patch adds, and the probe matches both (its "checking fstab" line
  # is a context line). The diff marker is stripped first, so a tab-indented context line is found too.
  ZSTR="$W/derived-strings.txt"
  sed -n 's/^.//; s/^[[:space:]]*tell_kmsg "\(.*\)"$/\1/p' "$ZPATCH" > "$ZSTR"
  ZN=$(grep -c . "$ZSTR" || true)
  # A floor, so an extractor that matched nothing cannot pass: the patch prints EIGHT today, and the number
  # is stated here rather than hidden in the assertion below.
  if [ "${ZN:-0}" -lt 8 ]; then
    bad "the patch yielded ${ZN:-0} tell_kmsg strings (8 today), so this section is not comparing what it thinks it is"
  else
    ok "the patch PRINTS $ZN report strings, and the checks below are driven by THESE -- not by strings typed here"
  fi
  # The two buckets, NAMED. `mount` strings are the ones the probe must print (they are its §4/§7 evidence
  # about the boot's own mount decisions); everything else the patch can print must NOT be printed by it.
  ZMOUNT_RE='checking fstab|matched NO file|checking mount label|no device for label|mounting |MOUNT FAILED'
  ZOTHER_RE='moving Android system to'
  # The device's own wording: the patch prints `$fstab`, the device prints the path. A variable that
  # survives this substitution would make the fixture a GUESS, so one that survives is a failure, not a skip.
  zexpand() {
    printf '%s\n' "$1" | sed \
      -e 's#\${mount_root}#/android#g' -e 's#\$mount_root#/android#g' \
      -e 's#\$zl1_fstab_fallback#/zl1-android-fstab#g' \
      -e 's#\$fstab#/var/lib/lxc/android/rootfs/fstab*#g' \
      -e 's#\$label#modem#g' \
      -e 's#\$path#/dev/disk/by-partlabel/modem#g' \
      -e 's#\$1#/dev/disk/by-partlabel/modem#g' \
      -e 's#\$2#vendor/firmware_mnt#g' -e 's#\$3#vfat#g' \
      -e 's#\$4#ro,shortname=lower#g'
  }
  zhdr='Linux version 4.9.186-perf+ (android@build) #1 SMP PREEMPT'
  ZRUN="$W/derived-ring.txt"
  ZSEEN_MOUNT=0
  ZSEEN_OTHER=0
  # Input redirection, not a pipe: a `while ... done < f` loop runs in THIS shell, so the counters and the
  # PASS/FAIL of each assertion are not lost in a subshell.
  while IFS= read -r zraw; do
    [ -n "$zraw" ] || continue
    zdev="initrd: $(zexpand "$zraw")"
    case "$zdev" in
    *'$'*) bad "a variable survived the substitution, so this fixture is a guess: $zdev" ; continue ;;
    esac
    if grep -Eq -- "$ZMOUNT_RE" <<< "$zraw"; then
      zbucket=mount
      ZSEEN_MOUNT=$((ZSEEN_MOUNT + 1))
    elif grep -Eq -- "$ZOTHER_RE" <<< "$zraw"; then
      zbucket=other
      ZSEEN_OTHER=$((ZSEEN_OTHER + 1))
    else
      bad "the patch prints a report this harness has not classified, so nothing asserts it: $zraw"
      continue
    fi
    printf '%s\n%s\n' "$zhdr" "$zdev" > "$ZRUN"
    : > "$ACT"
    "$W/reset.sh"
    cp "$ZRUN" "$W/dmesg.txt"
    OUT="$( env PATH="$STUB:$MINBIN" "$SH_BIN" "$RW" 2>&1 )"
    RC=$?
    if [ "$zbucket" = mount ]; then
      wantF "$zdev" "$OUT" "the probe prints the patch's own mount report, verbatim: $zdev"
      notwant 'STATE: NO INITRAMFS REPORT IN THIS LOG' "$OUT" \
        "and it is not reported as a boot whose initramfs said nothing"
    else
      notwantF "$zdev" "$OUT" \
        "a line the patch prints that is NOT about the mount is not read as one: $zdev"
    fi
  done < "$ZSTR"
  # The census is only a census if both buckets were actually filled; a `while` that read nothing, or one
  # whose bucket rule matched nothing, would otherwise leave every assertion above unrun.
  if [ "$ZSEEN_MOUNT" -ge 6 ] && [ "$ZSEEN_OTHER" -ge 1 ]; then
    ok "every one of the $ZN reports was classified: $ZSEEN_MOUNT about the mount (all asserted) and $ZSEEN_OTHER not"
  else
    bad "the buckets are empty or short (mount=$ZSEEN_MOUNT other=$ZSEEN_OTHER), so the loop above proved little"
  fi
  # The tooth, and it is the reason the checks above are a comparison rather than agreement with themselves:
  # reword ONE word of the patch's wording and the probe must stop reading that line -- if it still printed
  # it, then "it printed the line" would be true of any text at all and would mean nothing.
  ZMUT="initrd: MOUNT-FAILED: /dev/disk/by-partlabel/modem as /android/vendor/firmware_mnt -t vfat -o ro,shortname=lower"
  printf '%s\n%s\n' "$zhdr" "$ZMUT" > "$ZRUN"
  : > "$ACT"
  "$W/reset.sh"
  cp "$ZRUN" "$W/dmesg.txt"
  OUT="$( env PATH="$STUB:$MINBIN" "$SH_BIN" "$RW" 2>&1 )"
  RC=$?
  notwantF "$ZMUT" "$OUT" \
    "a reworded report ('MOUNT-FAILED') is NOT read as one -- so the checks above compare, they do not accept anything"
  want 'STATE: NO INITRAMFS REPORT IN THIS LOG' "$OUT" \
    "and a ring whose only report was reworded is honestly reported as having no report at all"
fi

# ==================================================================================================
echo
echo "== 11. the health check cites this harness's count, and that citation cannot drift =="
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
