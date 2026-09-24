#!/bin/sh
# zl1 post-recovery capture -- offline self-test.
#
# Host-side, touches no device. The subject is `scripts/host/zl1-post-recovery-capture.sh`, whose whole
# job is to run OTHER scripts in the right order and keep what they said. So there are two things to
# hold it to, and neither is about a peripheral:
#
#   1. THE ORDER, AND THE REFUSAL. Step 0 (the pstore/kmsg post-mortem) has to run FIRST, because
#      `/sys/fs/pstore` only holds the previous oops until the next reset; the boot-address verdict has
#      to come from THIS boot's netwatch log; and none of it may run at all when the device is in EDL,
#      because there is no device to run it on and a script that "tries anyway" is how a session gets
#      lost. The EDL refusal is therefore asserted twice: by the verdict text, and by the fact that no
#      ssh and no scp was made.
#   2. THE ARCHIVE, AND WHAT IS *NOT* IN IT. Every step's output has to survive as a file, with an
#      index and a checksum, because the boot it describes cannot be revisited. And the DEFAULT set has
#      to contain nothing that writes: the one step that does (`install-no-edl-on-panic.sh
#      --capture-only`, which copies pstore onto /userdata at every boot) is behind --with-capture.
#
# The transport is stubbed exactly as in the sibling harnesses -- the `ssh`/`scp` stub *is* the device --
# with one addition that this script needs and the others do not: because it CALLS other scripts, those
# callees are replaced by recording stubs (they have their own harnesses; what is under test here is
# that they are invoked, in order, with the right arguments, and that their output is kept). The
# rewritten paths are then cross-checked against the real repository, so a misspelt callee name cannot
# hide behind the rewrite -- a step pointing at a file that does not exist would otherwise look exactly
# like a step that ran and said nothing.
#
# The device fixture is deliberately the shape the identity block reads: a keeper process in
# `/proc/<pid>`, a boot_id, an uptime, and a `systemctl --failed` that answers.
#
# Usage: zl1-post-recovery-capture-selftest.sh [--keep]
#   --keep   leave the fake root, the stubs and the archive in place for inspection
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
SRC="$HERE/zl1-post-recovery-capture.sh"
[ -r "$SRC" ] || { echo "cannot read $SRC" >&2; exit 2; }
REPO=$(cd "$HERE/../.." && pwd)

W=${TMPDIR:-/tmp}/zl1-post-recovery-capture-selftest
FR="$W/fake"          # the fake DEVICE
CAL="$W/callees"      # the recording stand-ins for the scripts this one calls
STUB="$W/stub"
ACT="$W/actions"
rm -rf "$W"
mkdir -p "$FR/proc/sys/kernel/random" "$FR/tmp" "$FR/userdata" "$STUB" "$W/fake-repo/scripts/host" \
         "$CAL/device" "$CAL/host" "$W/out" || exit 2

# --- the fake device ------------------------------------------------------------------------------
printf 'deadbeef-1111-2222-3333-444444444444\n' > "$FR/proc/sys/kernel/random/boot_id"
printf '412.55 1201.30\n' > "$FR/proc/uptime"

# The keeper, exactly as docs 72's `ps` showed it: argv[0] is a shell and argv[1] IS the path. The
# identity block matches on the full command line, so the fixture has to have that shape or the two
# numbers the block exists to capture (pid and ticks) come out empty and nothing notices.
KEEPER_PATH=/usr/local/sbin/zl1-debug-net.sh
mkdir -p "$FR/proc/900"
printf '/bin/sh\0%s\0' "$KEEPER_PATH" > "$FR/proc/900/cmdline"
printf '900 (zl1-debug-net) S 1 900 900 0 -1 4194304 10 0 0 0 41 17 0 0\n' > "$FR/proc/900/stat"
# A bystander whose command line merely MENTIONS the keeper: the block must not count it.
mkdir -p "$FR/proc/901"
printf '/usr/bin/grep\0%s\0' "$KEEPER_PATH" > "$FR/proc/901/cmdline"
printf '901 (grep) S 1 901 901 0 -1 4194304 10 0 0 0 5 5 0 0\n' > "$FR/proc/901/stat"

# --- the stubs ------------------------------------------------------------------------------------
# lsusb: the FIRST question the script asks, and the one that decides whether anything runs. An EDL
# device has no serial number, so the two states are distinguishable only by the vendor id -- which is
# why the fixture answers both questions rather than just "is it there".
# `lsusb -d ID` is a FILTER: it exits non-zero when no device matches, which is exactly the test the
# script's first question is. A stub that printed and exited 0 for everything would report EDL for a
# healthy device -- and the first version of this fixture did exactly that, which is why the whole
# default run "refused" and sixty-odd assertions failed at once. The filter IS the check; faking it is
# faking the answer.
cat > "$STUB/lsusb" <<EOF
#!/bin/sh
printf 'lsusb %s\n' "\$*" >> "$ACT"
want_id=
[ "\$1" = -d ] && want_id="\$2"
case "\${FP_STATE:-present}" in
edl) have_id=05c6:9008; line='Bus 003 Device 127: ID 05c6:9008 Qualcomm, Inc. Gobi Wireless Modem (QDL mode)' ;;
*)   have_id=18d1:4ee7; line='Bus 003 Device 042: ID 18d1:4ee7 Google Inc.' ;;
esac
if [ -n "\$want_id" ]; then
  [ "\$want_id" = "\$have_id" ] || exit 1
  printf '%s\n' "\$line"; exit 0
fi
printf '%s\n' "\$line"
exit 0
EOF

cat > "$STUB/systemctl" <<EOF
#!/bin/sh
printf 'systemctl %s\n' "\$*" >> "$ACT"
case "\$*" in
*--failed*) [ -n "\${FP_FAILED_UNITS:-}" ] && printf '%s\n' "\$FP_FAILED_UNITS"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$STUB"/*

# The device's serial: the script looks for a directory under /sys/bus/usb/devices with a `serial`
# file. The fixture for that is a real directory, because that IS the check.
# The serial is written by the lsusb stub's scenario, because the two questions are really the same
# question: an EDL device presents no serial, so the lookup finds nothing, and a healthy one has it.
# `serial_off` is for the third state -- something is on the bus, but not the device we want.
SERDIR="$FR/sys/bus/usb/devices/3-3"
mkdir -p "$SERDIR"
printf '%s\n' "33e80afe" > "$SERDIR/serial"
serial_on()  { rm -rf "$FR/sys/bus/usb/devices"; mkdir -p "$SERDIR"; printf '%s\n' "${FP_SERIAL:-33e80afe}" > "$SERDIR/serial"; }
serial_off() { rm -rf "$FR/sys/bus/usb/devices"; }

# ssh: the device. It drops the connection options, maps the device's absolute paths into the fake
# root, and runs the rest for real -- so the identity block really walks a /proc and the two numbers
# it prints are measurements of the fixture rather than strings the harness handed it.
: > "$W/paths.sed"
emit() { printf '%s\n' "$1" >> "$W/paths.sed"; }
emit "s#/proc/sys/kernel/random/boot_id#$FR/proc/sys/kernel/random/boot_id#g"
emit "s#/proc/uptime#$FR/proc/uptime#g"
emit "s#/proc/\[0-9\]\*#$FR/proc/[0-9]*#g"
# `/tmp` LAST would be a bug, and it was one: every other rule's replacement text contains $FR, which
# is itself under /tmp, so a later `s#/tmp/#...#g` rewrites the text the earlier rules just produced and
# the device path comes out double-prefixed (`.../fake/tmp/.../fake/proc/uptime`). The rule is therefore
# anchored on the shape this script actually sends -- `sh /tmp/<script>` -- which cannot match inside the
# fake prefix, and the probe below asserts that no double prefix survives.
emit "s#sh /tmp/#sh $FR/tmp/#g"
# The `${p#/proc/}` prefix strip: without it the identity block prints the fake root's path as if it
# were the pid, so "keeper pids: <a path>" passes a human eye and fails the assertion that the number is
# a number. (The sibling harnesses carry the same rule for the same reason.)
emit "s|\${p#/proc/}|\${p#$FR/proc/}|g"

cat > "$STUB/ssh" <<EOF
#!/bin/sh
# ONE line per call: the commands this script sends are multi-line shell programs, and \`printf '%s\n'\`
# would put their bodies on their own lines -- where \`grep '^ssh '\` cannot see them, which is every
# assertion in this file that reads an ssh command.
printf 'ssh %s\n' "\$(printf '%s' "\$*" | tr '\n' ' ')" >> "$ACT"
while [ \$# -gt 0 ]; do
  case "\$1" in *@*) shift; break ;; *) shift ;; esac
done
# the reachability probe: 'true'. Answered from the environment, so "the device is on the bus but SSH
# is not up yet" is a reachable scenario instead of an untested branch.
case "\$*" in true) [ "\${FP_SSH:-yes}" = yes ] && exit 0 || exit 1 ;; esac
cmd=\$(printf '%s' "\$*" | sed -f "$W/paths.sed")
# FP_STUB_PATH exists so the "this device has no timeout(1)" branch can be RUN rather than read: with a
# PATH of our own we decide whether \`command -v timeout\` succeeds, which is the whole branch condition.
exec env PATH="\${FP_STUB_PATH:-$STUB:\$PATH}" FP_STATE="\${FP_STATE:-present}" sh -c "\$cmd"
EOF

# scp: pushes a callee stand-in into the fake device's /tmp, and records the SOURCE path -- so "it
# pushed the real script and not something it invented" is checkable.
cat > "$STUB/scp" <<EOF
#!/bin/sh
printf 'scp %s\n' "\$*" >> "$ACT"
# \`-o NAME=VALUE\` is TWO argv entries and only the first begins with a dash, so a filter that skips
# "anything starting with -" still leaves \`BatchMode=yes\` in the list -- and then the pair it takes as
# src/dst is two option values, the copy fails, and every device step reports "could not copy". The
# option's VALUE has to be skipped with it.
args=""; skip=0
for a in "\$@"; do
  if [ "\$skip" = 1 ]; then skip=0; continue; fi
  case "\$a" in -o) skip=1; continue ;; -*) continue ;; esac
  args="\$args \$a"
done
set -- \$args
src="\$1"; dst="\$2"
base=\$(basename "\$dst")
cp "\$src" "$FR/tmp/\$base" || exit 1
exit 0
EOF
chmod +x "$STUB/ssh" "$STUB/scp"

# --- the callees ----------------------------------------------------------------------------------
#
# Recording stand-ins. Each one prints a line that says which script ran and with what arguments, so
# the ORDER and the ARGUMENTS are both assertable, and exits with a code the scenario chooses. The real
# scripts have their own harnesses; what is under test here is that this script calls them at all, in
# the right order, and keeps what they said.
#
# `FP_RC_<name>` chooses a callee's exit code, which is how "a failing step does not stop the capture"
# is tested. `FP_SLEEP_<name>` makes it slow, which is how the interrupt handler is tested.
callee() { # relative path, marker name
  mkdir -p "$CAL/$(dirname "$1")"
  # Each callee records its invocation in $ACT as well as printing it: the printed line goes into the
  # ARCHIVE (which is what the operator reads), and the $ACT line is what makes the ORDER assertable
  # without parsing the archive. The first version only printed, and every order assertion failed while
  # the archive was correct -- a harness reading the wrong place for the right fact.
  cat > "$CAL/$1" <<EOF
#!/bin/sh
printf 'CALLEE $2 args=%s\n' "\$*" | tee -a "$ACT"
[ -n "\${FP_SLEEP_$2:-}" ] && sleep "\${FP_SLEEP_$2}"
rc=\$(printf '%s' "\${FP_RC_$2:-0}")
[ -n "\$rc" ] || rc=0
echo "CALLEE $2: done rc=\$rc"
printf 'CALLEE $2 rc=%s\n' "\$rc" >> "$ACT"
exit "\$rc"
EOF
  chmod +x "$CAL/$1"
}
callee device/zl1-edl-postmortem.sh        EDLPM
callee device/zl1-boot-address-check.sh    BOOTADDR
callee device/zl1-modem-probe.sh           MODEM
callee device/zl1-sleep-and-throttle.sh    SLEEP
callee device/zl1-lmh-probe.sh             LMH
callee device/zl1-leds-probe.sh            LEDS
callee device/zl1-vibrator-probe.sh        VIBR
callee device/zl1-gps-probe.sh             GPS
callee device/zl1-fingerprint-probe.sh     FP
callee device/zl1-orientation-axes.sh      ORIENT
callee ../install-retire-debug-keeper.sh   KEEPER
callee ../install-no-edl-on-panic.sh       NOEDL
callee host/zl1-health-check.sh            HEALTH

# The script under test, rewritten so $(HERE)/../device/... and $(HERE)/../install-... resolve to the
# recording stubs. ONLY those two prefixes are touched: everything else (the ssh/scp calls, the /tmp
# pushes, the argument handling) is the real code.
CAP="$W/fake-repo/scripts/host/zl1-post-recovery-capture.sh"
sed -e "s#\"\$HERE/../device/#\"$CAL/device/#g" \
    -e "s#\"\$HERE/../install-#\"$CAL/../install-#g" \
    -e "s#\"\$HERE/zl1-health-check.sh\"#\"$CAL/host/zl1-health-check.sh\"#g" \
    -e "s#/sys/bus/usb/devices/#$FR/sys/bus/usb/devices/#g" \
    "$SRC" > "$CAP"
chmod +x "$CAP"
sh -n "$CAP" 2>/dev/null || bash -n "$CAP" || { echo "the rewritten script does not parse" >&2; exit 2; }

# The rewrites are the fake environment, and a rewrite that silently did not land would send the script
# at the REAL scripts -- i.e. at the real device-dependent installers. So they are counted, and the
# callee names are cross-checked against the repository: every path the rewritten script will call has
# to correspond to a file that exists in the real tree. Without that, a misspelt callee is
# indistinguishable from a callee that ran and printed nothing.
for pat in "$CAL/device/" "$CAL/../install-" "$CAL/host/zl1-health-check.sh" "$FR/sys/bus/usb/devices/"; do
  grep -qF "$pat" "$CAP" || { echo "the rewrite to '$pat' did not land" >&2; exit 2; }
done

# The ssh stub's map is the fake device, so it is checked on the shapes this script sends -- including
# the one that IS a bug if it appears: a replacement re-processed by a later expression.
probe=$(printf 'sh /tmp/zl1-edl-postmortem.sh\n/proc/uptime\n/proc/sys/kernel/random/boot_id\n/proc/[0-9]*\n' |
        sed -f "$W/paths.sed")
case "$probe" in
*"sed:"*) echo "the ssh stub's map is broken: $probe" >&2; exit 2 ;;
esac
printf '%s\n' "$probe" | grep -qF "sh $FR/tmp/zl1-edl-postmortem.sh" ||
  { echo "the map did not rewrite 'sh /tmp/...' (got: $probe)" >&2; exit 2; }
printf '%s\n' "$probe" | grep -qF "$FR/proc/uptime" ||
  { echo "the map did not rewrite /proc/uptime (got: $probe)" >&2; exit 2; }
# THE one that matters: a double prefix means a replacement was rewritten by a later rule, and the
# failure it produces is a device script reading a path that does not exist rather than an error.
if printf '%s\n' "$probe" | grep -qF "$FR/tmp/zl1-post-recovery-capture-selftest"; then
  echo "the ssh stub's map double-applies (got: $probe)" >&2; exit 2
fi
for rel in device/zl1-edl-postmortem.sh device/zl1-boot-address-check.sh device/zl1-modem-probe.sh \
           device/zl1-gps-probe.sh device/zl1-fingerprint-probe.sh device/zl1-orientation-axes.sh \
           install-retire-debug-keeper.sh install-no-edl-on-panic.sh host/zl1-health-check.sh; do
  [ -f "$REPO/scripts/$rel" ] || { echo "the script calls scripts/$rel, which does not exist" >&2; exit 2; }
done

# --- the checks -----------------------------------------------------------------------------------

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
want()    { if printf '%s\n' "$2" | grep -Eq -- "$1"; then ok "$3"; else bad "$3"; printf '%s\n' "$2" | sed 's/^/        | /'; fi; }
notwant() { if printf '%s\n' "$2" | grep -Eq -- "$1"; then bad "$3"; printf '%s\n' "$2" | grep -E -- "$1" | sed 's/^/        | /'; else ok "$3"; fi; }

sshacts()  { grep -E '^ssh ' "$ACT" 2>/dev/null; }
scpacts()  { grep -E '^scp ' "$ACT" 2>/dev/null; }
# The order the callees ran in, as one line each. This is the assertion the whole harness exists for.
# The ORDER list, and the alternation is the harness's own blind spot: a callee whose marker is not in
# this list RAN and is invisible to every assertion below it. Adding `04b-modem` to the subject without
# adding MODEM here made a six-step run read as "exactly five steps" while a step really did run -- the
# extractor-drops-an-item shape this tree has recorded before. So the list is checked against the
# markers that actually appear: an unknown CALLEE name is a setup failure, not a silent omission.
CALLEE_NAMES='EDLPM|BOOTADDR|KEEPER|HEALTH|MODEM|SLEEP|LMH|LEDS|VIBR|GPS|FP|ORIENT|NOEDL'
order()    { grep -E "^CALLEE ($CALLEE_NAMES) args=" "$ACT" 2>/dev/null; }
callee_names_ok() { # every CALLEE <NAME> line in $ACT must be one this file knows how to look for
  local unknown
  unknown=$(sed -n 's/^CALLEE \([A-Z0-9]*\) .*/\1/p' "$ACT" 2>/dev/null | sort -u |
              grep -vxE "$CALLEE_NAMES" | tr '\n' ' ')
  [ -z "$unknown" ] || { echo "the run used callee marker(s) this harness cannot see: $unknown" >&2; return 1; }
  return 0
}
snap()     { find "$FR" -printf '%p %s\n' 2>/dev/null | sort; }

# $1 = outdir, rest = extra args. FP_STATE / FP_SSH / FP_RC_* set the device's state.
run() {
  od="$1"; shift
  : > "$ACT"
  case "${FP_STATE:-present}" in
  absent) serial_off ;;
  *)      serial_on ;;
  esac
  OUT=$(PATH="$STUB:$PATH" FP_STATE="${FP_STATE:-present}" FP_SSH="${FP_SSH:-yes}" \
        FP_STUB_PATH="${FP_STUB_PATH:-}" \
        FP_SERIAL="${FP_SERIAL:-33e80afe}" \
        FP_SLEEP_EDLPM="${FP_SLEEP_EDLPM:-}" FP_SLEEP_BOOTADDR="${FP_SLEEP_BOOTADDR:-}" \
        FP_RC_EDLPM="${FP_RC_EDLPM:-}" FP_RC_BOOTADDR="${FP_RC_BOOTADDR:-}" \
        timeout 120 bash "$CAP" --outdir "$od" "$@" 2>&1); RC=$?
  # The blind-spot guard, at the one place every scenario routes through: if the subject calls a callee
  # this file does not know how to look for, say so HERE rather than letting every count assertion below
  # quietly under-count. (Except EDL/absent runs, which call nothing -- `$ACT` is empty and that is fine.)
  callee_names_ok || { echo "the fixture/order list is out of date -- fix the harness" >&2; exit 2; }
}
# The same, but left running, so a signal can be delivered to it. $BGPID is its pid and $W/out.bg gets
# its output. No `timeout` wrapper: the signal has to reach the script itself, and whether `timeout`
# forwards one is a second thing that could be wrong while the assertion looked right.
run_bg() {
  od="$1"; shift
  : > "$ACT"
  serial_on
  PATH="$STUB:$PATH" FP_STATE=present FP_SSH=yes FP_SERIAL="${FP_SERIAL:-33e80afe}" \
    FP_SLEEP_EDLPM="${FP_SLEEP_EDLPM:-}" FP_SLEEP_BOOTADDR="${FP_SLEEP_BOOTADDR:-}" \
    bash "$CAP" --outdir "$od" "$@" > "$W/out.bg" 2>&1 &
  BGPID=$!
}
# Bound the wait for a signalled process, so a trap that never fires shows up as rc=137 rather than as a
# harness that hangs (docs 107 section 6: an instrument that cannot report is not an instrument).
wait_bg() {
  i=0
  while [ "$i" -lt 15 ]; do kill -0 "$BGPID" 2>/dev/null || break; sleep 1; i=$((i + 1)); done
  kill -9 "$BGPID" 2>/dev/null
  wait "$BGPID" 2>/dev/null; RC=$?
}
reset_rc() { FP_RC_EDLPM=; FP_RC_BOOTADDR=; FP_SLEEP_EDLPM=; FP_SLEEP_BOOTADDR=; }

echo "zl1 post-recovery capture -- offline self-test"
echo "  subject: $SRC"
echo "  fake device: $FR   (serial 33e80afe, keeper pid 900)"
echo "  callees are recording stand-ins in $CAL; the real ones have their own harnesses"
echo

# ==================================================================================================
echo "== 1. the flag surface, and the rewrite guard =="
# ==================================================================================================
: > "$ACT"
OUT=$(PATH="$STUB:$PATH" bash "$CAP" --nope 2>&1); RC=$?
[ "$RC" = 2 ] && ok "an unknown argument exits 2" || bad "unknown argument exited $RC"
OUT=$(PATH="$STUB:$PATH" bash "$CAP" --help 2>&1); RC=$?
[ "$RC" = 0 ] && ok "--help exits 0" || bad "--help exited $RC"
want 'Usage: zl1-post-recovery-capture' "$OUT" "and prints its usage block from the header"
want 'READ-ONLY BY DEFAULT' "$OUT" "which states the property the rest of this file checks"
msg=$(PATH="$STUB:$PATH" bash "$CAP" --outdir 2>&1 >/dev/null | head -1); rc=$?
case "$msg" in
*"unbound variable"*) bad "--outdir with no value aborted the shell: $msg" ;;
*"--outdir needs a DIRECTORY"*) ok "--outdir with no value names the flag instead of aborting the shell" ;;
*) bad "--outdir with no value said neither: $msg" ;;
esac

# ==================================================================================================
echo
echo "== 2. in EDL it must refuse, and touch NOTHING =="
# ==================================================================================================
FP_STATE=edl
OD="$W/out/edl"
rm -rf "$OD"
BEFORE=$(snap)
run "$OD"
printf '%s\n' "$OUT" > "$W/out.edl"
[ "$RC" = 2 ] && ok "with the device in EDL it exits 2" || bad "it exited $RC"
want 'the device is NOT reachable: edl' "$OUT" "naming the mode it found"
want '05c6:9008' "$OUT" "and the USB id that identifies it"
want 'PHYSICAL AND ONLY PHYSICAL' "$OUT" "and saying the next move is a finger, not a command"
want 'long-press POWER for 10-20 s' "$OUT" "with the actual instruction"
[ "$(snap)" = "$BEFORE" ] && ok "the fake device is unchanged" || bad "it changed the fake device"
[ -z "$(sshacts)" ] && ok "it made NO ssh call at all" || { bad "it SSHed to a device in EDL:"; sshacts | sed 's/^/        | /'; }
[ -z "$(scpacts)" ] && ok "and pushed nothing" || bad "it scp'd to a device in EDL"
[ -z "$(order)" ] && ok "and ran none of the steps" || bad "it ran steps against a device in EDL"
[ ! -d "$OD" ] && ok "and created no archive directory -- there is nothing to archive" || bad "it created $OD"
want 'NOTHING WAS RUN' "$OUT" "and says so, so the refusal cannot be mistaken for a failed capture"

echo
echo "   -- and the same for 'no device on the bus' (the other phone shares this bus, docs 33):"
FP_STATE=absent
run "$W/out/absent"
printf '%s\n' "$OUT" > "$W/out.absent"
[ "$RC" = 2 ] && ok "with no device on the bus it exits 2" || bad "it exited $RC"
want 'NOT reachable: absent' "$OUT" "and distinguishes 'absent' from 'edl'"
want '4a2fe00b' "$OUT" "and names the other phone as the thing to rule out"
[ -z "$(order)" ] && ok "and ran nothing" || bad "it ran steps with no device"

echo
echo "   -- and a device that is on the bus but has no SSH yet (a boot still in progress):"
FP_STATE=present; FP_SSH=no
run "$W/out/nossh"
printf '%s\n' "$OUT" > "$W/out.nossh"
[ "$RC" = 2 ] && ok "with the serial present and ssh down it exits 2" || bad "it exited $RC"
want 'SSH does not answer yet' "$OUT" "and says it may still be booting, rather than 'absent'"
want 'zl1-rndis-recover\.sh' "$OUT" "and points at the OTHER known failure, the host-side enum (docs 76)"
[ -z "$(order)" ] && ok "and ran nothing" || bad "it ran steps before SSH answered"
FP_SSH=yes

echo
echo "   -- the SERIAL MATCH, which is the bug the first real run found:"
# The gadget's serial is not `33e80afe`, it is `33e80afe-v63-usbd-disabled-rndis` -- the id followed by
# the image that produced it. The first version compared with `=` and therefore reported ABSENT for a
# phone that was up, SSHable and answering ping: the most expensive possible false negative, on the one
# boot that cannot be revisited. So this pair is the test -- the right device WITH its suffix must be
# accepted, and the OTHER phone on this bus must not be (docs 33, and the reason the rule is "match
# the serial", not "is anything there").
FP_STATE=present
FP_SERIAL=33e80afe-v63-usbd-disabled-rndis
ODS="$W/out/prefixed"
rm -rf "$ODS"
run "$ODS" --no-orientation --skip-probes
printf '%s\n' "$OUT" > "$W/out.prefixed"
[ "$RC" != 2 ] && ok "a serial with the image suffix is the device (exit $RC, not a refusal)" \
  || bad "the prefixed serial was reported as not reachable -- that is the first-run bug"
want 'boot_id: deadbeef' "$OUT" "and the run really proceeded"
FP_SERIAL=4a2fe00b
FP_STATE=present
run "$W/out/otherphone"
printf '%s\n' "$OUT" > "$W/out.otherphone"
[ "$RC" = 2 ] && ok "the OTHER phone's serial alone is 'absent' (exit 2)" || bad "it exited $RC"
want 'NOT reachable: absent' "$OUT" "and it is absent, not present-and-confusing"
[ -z "$(order)" ] && ok "and nothing ran against the wrong phone" || bad "it ran steps against the other phone"
FP_SERIAL=33e80afe

# ==================================================================================================
echo
echo "== 3. the default run: the read-only chain, in the only order that works =="
# ==================================================================================================
FP_STATE=present; reset_rc
OD="$W/out/default"
run "$OD"
printf '%s\n' "$OUT" > "$W/out.default"
[ "$RC" = 0 ] && ok "the default run exits 0" || bad "it exited $RC"
want 'boot_id: deadbeef-1111-2222-3333-444444444444' "$OUT" "it reads this boot's identity first"
# Read from the ARCHIVE, not from stdout: the identity block is redirected to 00-identity.txt, so an
# assertion on $OUT would be asserting about a line the operator only sees if they open the file. (The
# boot_id passes either way, because the header repeats it -- which is exactly the kind of coincidence
# that makes a wrong assertion look right.)
want 'keeper pids: 900 ' "$(cat "$OD/00-identity.txt")" "the identity block captures the keeper's pid"
want 'keeper cpu ticks \(utime\+stime\): 58' "$(cat "$OD/00-identity.txt")" "and its accumulated ticks (41+17), the number that only exists before the kill"
want 'uptime: 412\.55' "$(cat "$OD/00-identity.txt")" "and the boot's uptime"
notwant '901' "$(cat "$OD/00-identity.txt")" "and not the bystander whose cmdline only MENTIONS the keeper"

# THE ORDER. Step 0 first is not a preference: /sys/fs/pstore holds the previous oops only until the
# next reset, so anything that runs before it is borrowing against evidence that cannot be re-read.
O=$(order | sed 's/ args=.*//')
printf '%s\n' "$O" > "$W/out.order"
want '^CALLEE EDLPM$' "$(printf '%s\n' "$O" | sed -n '1p')" "step 0 (the post-mortem) runs FIRST"
want '^CALLEE BOOTADDR$' "$(printf '%s\n' "$O" | sed -n '2p')" "then the boot-address verdict"
want '^CALLEE KEEPER$' "$(printf '%s\n' "$O" | sed -n '3p')" "then the keeper's status (read-only)"
want '^CALLEE HEALTH$' "$(printf '%s\n' "$O" | sed -n '4p')" "then the health check"
want '^CALLEE MODEM$' "$(printf '%s\n' "$O" | sed -n '5p')" "then the modem probe (docs 120) -- read-only, so it is in the DEFAULT set"
want '^CALLEE SLEEP$' "$(printf '%s\n' "$O" | sed -n '6p')" "then the sleep/throttle probe (docs 121) -- the SUPPLY side of the heat, also read-only"
want '^CALLEE LMH$' "$(printf '%s\n' "$O" | sed -n '7p')" "then the hardware limiter probe (docs 138) -- the HARDWARE side of the heat, and write-free"
want '^CALLEE LEDS$' "$(printf '%s\n' "$O" | sed -n '8p')" "then the LEDs probe (docs 139) -- the two blocks a finger touches first, and write-free"
want '^CALLEE VIBR$' "$(printf '%s\n' "$O" | sed -n '9p')" "then the vibrator probe (docs 140) -- and it is also the step that says WHICH BOARD's tree this boot got"
want '^CALLEE ORIENT$' "$(printf '%s\n' "$O" | sed -n '10p')" "then the orientation survey"
[ "$(order | wc -l)" = 10 ] && ok "exactly ten steps -- the five read-only probes ARE among them and the 05/06 pair are NOT" \
  || { bad "it ran $(order | wc -l) steps:"; order | sed 's/^/        | /'; }
# docs 116: the probes are skipped by default. This is the assertion that makes the default a fact
# rather than a comment, and it is on the ORDER list rather than on stdout, so a default that flipped
# back without anyone noticing cannot pass on a printed line that still says "skipped".
notwant '^CALLEE (GPS|FP)$' "$(printf '%s\n' "$O")" "neither probe runs by default (docs 116)"
# docs 120: the MODEM probe IS in the default set -- it is read-only and never opens a block device, so
# it belongs with 01/02 rather than with the 05/06 pair. Asserted on the ORDER, so a default that flipped
# back cannot pass on a printed line.
want '^CALLEE MODEM$' "$(printf '%s\n' "$O")" "the modem probe runs by default"
notwant '^CALLEE NOEDL' "$(order)" "and NOT the one step that writes"

echo
echo "   -- the arguments each step got, which is where a silent misuse would show:"
want '^CALLEE KEEPER args=--status$' "$(order)" "the keeper is asked with --status, the read-only mode"
want '^CALLEE HEALTH args=$' "$(order)" "the health check is run bare (its own defaults are the survey)"
want '^CALLEE EDLPM args=$' "$(order)" "the post-mortem is run bare -- its flags would narrow it"
want '^CALLEE ORIENT args=$' "$(order)" "and the orientation step is the SURVEY, not the decisive --portrait-up run"
notwant 'CALLEE .*args=.*--portrait-up' "$(order)" "which needs a person holding the phone still, so it is not run here"
notwant 'CALLEE .*args=.*--install' "$(order)" "and no step is invoked with --install"

echo
echo "   -- the device scripts were PUSHED, by their real paths:"
want "scp .*$CAL/device/zl1-edl-postmortem\.sh root@10\.15\.19\.82:/tmp/zl1-edl-postmortem\.sh" "$(scpacts)" \
  "the post-mortem is pushed to /tmp by name, and the source is the path the script resolved"
want 'zl1-boot-address-check\.sh' "$(scpacts)" "and the boot-address check"
want 'zl1-modem-probe\.sh' "$(scpacts)" "and the modem probe, which is in the default set"
want 'zl1-sleep-and-throttle\.sh' "$(scpacts)" "and the sleep/throttle probe, which is in the default set too (docs 121)"
want 'zl1-lmh-probe\.sh' "$(scpacts)" "and the LMH probe (docs 138), also in the default set -- it writes nothing at all"
want 'zl1-leds-probe\.sh' "$(scpacts)" "and the LEDs probe (docs 139), in the default set for the same reason"
want 'zl1-vibrator-probe\.sh' "$(scpacts)" "and the vibrator probe (docs 140), whose board line re-reads every other reading in the archive"
want 'sh /tmp/zl1-edl-postmortem\.sh' "$(sshacts)" "and run from /tmp, which is where the health check sends them too"
[ "$(scpacts | wc -l)" = 8 ] && ok "eight pushes: the eight DEVICE steps, and no more" \
  || { bad "it pushed $(scpacts | wc -l) files:"; scpacts | sed 's/^/        | /'; }

# ==================================================================================================
echo
echo "== 4. the archive: everything survives as a file, with an index and a checksum =="
# ==================================================================================================
[ -f "$OD/INDEX.txt" ] && ok "the index exists" || bad "no INDEX.txt"
[ -f "$OD/SHA256SUMS" ] && ok "and the checksums" || bad "no SHA256SUMS"
[ -f "$OD/00-identity.txt" ] && ok "the identity block is archived" || bad "no 00-identity.txt"
for f in 01-edl-postmortem 02-boot-address 03-keeper-status 04-health-check 04b-modem 04c-sleep-throttle 04d-lmh 04e-leds 04f-vibrator 07-orientation; do
  [ -s "$OD/$f.txt" ] && ok "step output archived: $f.txt" || bad "missing or empty $f.txt"
done
for f in 05-gps-probe 06-fingerprint; do
  [ ! -e "$OD/$f.txt" ] && ok "and no file pretends a skipped probe ran: $f.txt" \
    || bad "$f.txt exists although the probe did not run"
done
want '^boot_id: deadbeef-1111-2222-3333-444444444444$' "$(cat "$OD/INDEX.txt")" "the index names the boot it describes"
want '^with_capture: 0' "$(cat "$OD/INDEX.txt")" "and whether the writing step was included"
want '^01-edl-postmortem +0 +01-edl-postmortem\.txt$' "$(cat "$OD/INDEX.txt")" "and lists each step with its exit code and its file"
( cd "$OD" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ) && ok "the checksums verify" || bad "SHA256SUMS does not verify"
# The archive must contain what the callee SAID, not a summary of it: that is the whole point.
want 'CALLEE EDLPM: done rc=0' "$(cat "$OD/01-edl-postmortem.txt")" "a step's own output is what is archived"
want 'lines -> 01-edl-postmortem\.txt' "$OUT" "and the operator is told the file, not just 'ok'"

echo
echo "   -- and a second capture of the SAME boot lands in the same directory:"
run "$OD"
[ -f "$OD/INDEX.txt" ] && ok "the index is rewritten in place" || bad "the second run lost the index"
[ "$(find "$OD" -name '*-*.txt' | wc -l)" = 11 ] && ok "and the file set does not grow (11 archived outputs, not 22)" \
  || { bad "the second run added files:"; find "$OD" -name '*-*.txt' | sed 's/^/        | /'; }

# ==================================================================================================
echo
echo "== 5. the flags that change the SET, and what they must not change =="
# ==================================================================================================
OD2="$W/out/skip"
# The DEFAULT is the skipped set (docs 116), so this scenario runs with NO FLAG AT ALL -- that is the
# assertion: the probes have never produced a fix, and the last two boots that ended in EDL both had
# the fingerprint probe as the last thing running. A default that has to be remembered is not a
# default, so the check is that a bare invocation leaves them out.
run "$OD2"
printf '%s\n' "$OUT" > "$W/out.skip"
[ "$RC" = 0 ] && ok "a plain run exits 0" || bad "it exited $RC"
notwant '^CALLEE (GPS|FP)' "$(order)" "the two probes are not run BY DEFAULT"
# docs 120: the MODEM probe is in the default set, and this pair of assertions is the whole point of
# putting it there -- it must RUN by default, and the flag whose NAME says it skips probes must not
# silently skip this one either. A default that only exists in a comment is not a default (docs 116).
want '^CALLEE MODEM args=' "$(order)" "the modem probe IS run by default (read-only, opens no block device)"
[ "$(order | wc -l)" = 10 ] && ok "leaving ten steps" || bad "$(order | wc -l) steps ran"
want 'SKIPPED \(the default; --with-probes runs them\)' "$OUT" "and the skip is SAID, not silent"
want '04b-modem DID run' "$OUT" "and that this skip does NOT cover the modem probe is said too"
[ ! -e "$OD2/05-gps-probe.txt" ] && ok "and no file pretends the probe ran" || bad "an empty probe file was written"

echo
echo "   -- --skip-probes is kept as the old name for that default, and still works:"
OD2b="$W/out/skip2"
run "$OD2b" --skip-probes
printf '%s\n' "$OUT" > "$W/out.skip2"
[ "$RC" = 0 ] && ok "--skip-probes exits 0" || bad "it exited $RC"
notwant '^CALLEE (GPS|FP)' "$(order)" "and also skips them (the four documents that spell it out still work)"
want '^CALLEE MODEM' "$(order)" "while the modem probe still runs (the flag selects the DEFAULT set, which contains it)"
[ "$(order | wc -l)" = 10 ] && ok "leaving the same ten steps" || bad "$(order | wc -l) steps ran"

echo
echo "   -- --with-probes is how the two probes ARE run, and it says so:"
OD2c="$W/out/withprobes"
run "$OD2c" --with-probes --no-orientation
printf '%s\n' "$OUT" > "$W/out.withprobes"
[ "$RC" = 0 ] && ok "--with-probes exits 0" || bad "it exited $RC"
want '^CALLEE GPS' "$(order)" "the GPS probe runs"
want '^CALLEE FP' "$(order)" "and the fingerprint probe"
[ -f "$OD2c/05-gps-probe.txt" ] && ok "with a file per probe" || bad "no probe output was archived"

echo
echo "   -- --no-orientation, and --with-capture, and both together:"
OD3="$W/out/noorient"
run "$OD3" --no-orientation
notwant '^CALLEE ORIENT' "$(order)" "--no-orientation drops the orientation step"
want 'SKIPPED by --no-orientation' "$OUT" "and says so"

OD4="$W/out/withcapture"
run "$OD4" --with-capture
printf '%s\n' "$OUT" > "$W/out.withcapture"
[ "$RC" = 0 ] && ok "--with-capture exits 0" || bad "it exited $RC"
want '^CALLEE NOEDL args=--capture-only$' "$(order)" "the writing step runs, in its read-only-looking mode"
[ "$(order | wc -l)" = 11 ] && ok "eleven steps -- the ten of the default plus the one that writes" || bad "$(order | wc -l) steps ran"
want '^08-no-edl-capture +0' "$(cat "$OD4/INDEX.txt")" "and it is listed in the index"
want '^with_capture: 1' "$(cat "$OD4/INDEX.txt")" "with the index recording that the archive is not read-only-only"

echo
echo "   -- and WITHOUT the flag the writing step is not merely unlisted, it is not run:"
run "$W/out/withoutcapture"
notwant '^CALLEE NOEDL' "$(order)" "the step that writes is not run by default"
want 'NOT run, and it is the one that writes' "$OUT" "and the operator is told it exists and why it did not run"
want '\-\-capture-only' "$OUT" "by name, so the decision is theirs"
# The advice names the two halves of the panic installer SEPARATELY, because only one of them outlasts
# the boot -- and the line used to name only --capture-only, i.e. the half that does NOT arm the policy.
# These three assertions are the distinction itself: both flags are named, and the durable half is called
# out as the one that makes the next boot safer rather than as an equivalent alternative.
want 'install-no-edl-on-panic\.sh --install' "$OUT" "and the DURABLE half of it is named too, not just the evidence half"
want 'OUTLASTS THE BOOT' "$OUT" "with the distinction stated: only the policy half survives a reboot"
want 'prerequisite A of the LPM' "$OUT" "and why it matters beyond this boot -- it is the trial's refusal A"
want 'does not remove the path' "$OUT" "while doc 86's caution travels with it (it lowers a probability)"

# ==================================================================================================
echo
echo "== 6. a failing step does not stop the capture, and does not hide =="
# ==================================================================================================
# The evidence in this list is only readable once. Stopping at the first bad verdict would mean losing
# the rest of it and needing another physical press -- so a failure is recorded and reported, and the
# remaining steps still run.
FP_RC_BOOTADDR=1
OD5="$W/out/failing"
run "$OD5"
FP_RC_BOOTADDR=
printf '%s\n' "$OUT" > "$W/out.failing"
[ "$RC" = 1 ] && ok "with one step failing the run exits 1" || bad "it exited $RC"
want 'FAILED rc=1' "$OUT" "the failing step is named, with its code"
want '^02-boot-address +1' "$(cat "$OD5/INDEX.txt")" "and the index carries the code"
[ -s "$OD5/02-boot-address.txt" ] && ok "its output is still archived" || bad "a failed step's output was dropped"
want 'CALLEE BOOTADDR: done rc=1' "$(cat "$OD5/02-boot-address.txt")" "and it is the step's own output"
want '^CALLEE HEALTH' "$(order)" "the steps AFTER it still ran -- the evidence is not thrown away"
[ "$(order | wc -l)" = 10 ] && ok "all ten ran (the default set; no 05/06 probe is in it)" || bad "$(order | wc -l) steps ran"
want 'FAILED \(their output is archived' "$OUT" "and the summary says the archive is still worth reading"
want 'netwatch-configured' "$OUT" "while the next-move text still explains what 02 decides"
notwant 'capture complete: 6 steps ran, 0 failed' "$OUT" "and it does not claim a clean capture"

echo
echo "   -- and a step that fails only in its PUSH (scp) is reported as such, not as a silence:"
# --------------------------------------------------------------------------------------------------
rm -rf "$W/out/pushfail"
mkdir -p "$W/stubnoscp"
cp "$STUB"/* "$W/stubnoscp/" 2>/dev/null || true
cat > "$W/stubnoscp/scp" <<EOF
#!/bin/sh
printf 'scp %s\n' "\$*" >> "$ACT"
exit 1
EOF
chmod +x "$W/stubnoscp/scp"
: > "$ACT"
OUT=$(PATH="$W/stubnoscp:$PATH" FP_STATE=present timeout 120 bash "$CAP" --outdir "$W/out/pushfail" 2>&1); RC=$?
printf '%s\n' "$OUT" > "$W/out.pushfail"
[ "$RC" = 1 ] && ok "an un-pushable device script fails the run" || bad "it exited $RC"
want 'could not copy zl1-edl-postmortem\.sh to the device' "$(cat "$W/out/pushfail/01-edl-postmortem.txt")" \
  "the file says the copy failed, rather than being empty"

# ==================================================================================================
echo
echo "== 7. no device-side step may run unbounded, and an interrupt must still leave the record =="
# ==================================================================================================
# This section exists because of what the first real run did. One device-side step spun a child at 94 %
# of a core for 11+ minutes, at load ~9, and that boot ended in Qualcomm EDL -- and the run itself was
# then killed by a timeout with 00-06 on disk and NO index and NO checksums (docs 108). Two properties
# come out of that: the bound is on the DEVICE, and the archive survives an interrupt.
FP_STATE=present; reset_rc
ODT="$W/out/steplimit"
run "$ODT" --step-limit 30
printf '%s\n' "$OUT" > "$W/out.steplimit"
[ "$RC" = 0 ] && ok "--step-limit 30 still exits 0" || bad "it exited $RC"
want 'timeout -k 5 30 sh .*zl1-edl-postmortem\.sh' "$(sshacts)" "the DEVICE runs the step under timeout(1)"
# The modem probe runs BY DEFAULT (docs 120), so the bound is what makes that safe; a step added to the
# default set without it would be the one unbounded device step in the set, which is the shape of 108.
want 'timeout -k 5 30 sh .*zl1-modem-probe\.sh' "$(sshacts)" "and so does the modem probe, which is in the default set"
notwant 'timeout -k 5 240' "$(sshacts)" "and the default is not also there"
want '^with_capture: 0 .*step_limit: 30s$' "$(cat "$ODT/INDEX.txt")" "the index records the bound it ran under"
# The bound is on the device, not on the ssh client: a host-side `timeout` around ssh would leave the
# device-side process running and only stop waiting for it, which is the opposite of the fix.
notwant '^timeout .*ssh ' "$(sshacts)" "and it is not a host-side timeout around ssh"
want 'command -v timeout' "$(sshacts)" "the step is guarded rather than assumed"
want 'NOT TIME-BOUNDED' "$(sshacts)" "and a device without timeout(1) says so instead of running silently unbounded"

echo
echo "   -- that 'no timeout(1)' branch, RUN rather than read:"
# A PATH of our own that deliberately has no `timeout` in it. Without this the branch is two lines
# nobody has ever executed -- which is the shape of most of the defects in docs 106/107 section 6.
BINONLY="$W/binonly"
rm -rf "$BINONLY"; mkdir -p "$BINONLY"
for t in sh dash bash cat tr awk sed grep egrep basename wc tee cp mv rm mkdir rmdir ls find date \
         sleep chmod stat id dirname head tail cut sort uniq expr env test true false kill; do
  p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$BINONLY/$t"
done
cp "$STUB/lsusb" "$STUB/systemctl" "$STUB/scp" "$BINONLY/" 2>/dev/null || true
# The ssh stub too, but the copy must be the one that honours FP_STUB_PATH -- and it must not be able to
# find `timeout` inside $BINONLY, which is the whole point.
cp "$STUB/ssh" "$BINONLY/ssh"
if PATH="$BINONLY" command -v timeout >/dev/null 2>&1; then
  bad "the restricted PATH still has a timeout(1): this test would prove nothing"
else
  ok "the restricted PATH has no timeout(1) -- the fallback branch is reachable"
fi
ODN="$W/out/notimeout"
rm -rf "$ODN"
: > "$ACT"
OUT=$(PATH="$STUB:$PATH" FP_STATE=present FP_SSH=yes FP_STUB_PATH="$BINONLY" \
      timeout 120 bash "$CAP" --outdir "$ODN" --skip-probes --no-orientation 2>&1); RC=$?
printf '%s\n' "$OUT" > "$W/out.notimeout"
[ "$RC" = 0 ] && ok "with no timeout(1) the capture still completes (exit 0)" || bad "it exited $RC"
want 'THIS STEP IS NOT TIME-BOUNDED' "$(cat "$ODN/01-edl-postmortem.txt")" "and the step's own output says the bound is missing"
[ "$(order | wc -l)" = 9 ] && ok "all nine steps still ran" || bad "$(order | wc -l) steps ran"

echo
echo "   -- an interrupt mid-step: the archive is written anyway"
# THE case the first real run lost. The signal is delivered while a step is running, which is exactly
# when a foreground-only script would not act on it (measured on this host: a TERM during a foreground
# `sleep 20` is handled 20 s later, during a `wait` immediately).
FP_STATE=present; reset_rc
ODI="$W/out/interrupted"
rm -rf "$ODI"
FP_SLEEP_BOOTADDR=30
run_bg "$ODI"
sleep 4
kill -TERM "$BGPID" 2>/dev/null
wait_bg
printf '%s\n' "$(cat "$W/out.bg")" > "$W/out.interrupted"
[ "$RC" = 3 ] && ok "a TERM mid-step exits 3, a code of its own (not 1 'a step failed', not 2 'nothing ran')" \
  || bad "an interrupted run exited $RC (137 means the trap never fired)"
want 'INTERRUPTED: archived what had run' "$(cat "$W/out.bg")" "it says so"
[ -f "$ODI/INDEX.txt" ] && ok "INDEX.txt exists even though the run never reached the archive step" || bad "no INDEX.txt after the interrupt"
[ -f "$ODI/SHA256SUMS" ] && ok "and SHA256SUMS" || bad "no SHA256SUMS after the interrupt"
want '^INTERRUPTED: yes' "$(cat "$ODI/INDEX.txt")" "the index records that this is a partial capture"
want '^01-edl-postmortem +0' "$(cat "$ODI/INDEX.txt")" "the step that DID finish is listed with its code"
# The step the signal landed in the middle of: it is listed, with `?` for an rc it never produced and its
# file marked partial. Omitting it would leave the operator unable to tell WHICH step was cut off.
want '^02-boot-address +\? ' "$(cat "$ODI/INDEX.txt")" "the interrupted step is named, with no rc claimed"
want 'partial: the interrupt landed here' "$(cat "$ODI/INDEX.txt")" "and its file is marked partial"
notwant '^0[3-9]-' "$(cat "$ODI/INDEX.txt")" "and no step that never started is listed"
( cd "$ODI" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ) && ok "the partial archive verifies" || bad "the partial checksums do not verify"
[ ! -e "$ODI/07-orientation.txt" ] && ok "and no file pretends a step ran that never did" || bad "a step file exists for a step that never ran"
FP_SLEEP_BOOTADDR=

# ==================================================================================================
echo
echo "== 8. what this harness does NOT test, and says so =="
# ==================================================================================================
printf 'SKIP  what the steps themselves decide. Their callees here are recording stand-ins: the\n'
printf '      post-mortem, the boot-address verdict, the probes and the health check each have their own\n'
printf '      offline harness (see the table in scripts/README.md), and this file checks only that they\n'
printf '      are called, in order, with these arguments, and that their output is kept.\n'
printf 'SKIP  the device-side truth behind each step: whether pstore really holds an oops, whether the\n'
printf '      netwatch really configured the addresses. Those need the boot itself.\n'
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
            sed -n 's/.*zl1-post-recovery-capture-selftest.sh[ ,(]*\([0-9][0-9]*\) checks.*/\1/p')
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
echo "pass=$PASS fail=$FAIL skip=2 (named above)"
[ "$KEEP" = 1 ] || rm -rf "$W"
[ "$FAIL" = 0 ]
