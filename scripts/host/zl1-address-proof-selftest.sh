#!/bin/sh
# zl1 address-owner proof -- offline self-test. Host-side, touches no device and no host interface.
#
# Why this exists: `scripts/device/zl1-address-owner-proof.sh` is a WRITE-CAPABLE probe -- it SIGSTOPs
# the v63 debug keeper and removes one address from rndis0, and the thing it is measuring is the
# address path that keeps SSH alive. `zl1-the-two-write-capable-probes` is the standing rule for this
# shape: a probe with a mode that writes gets its writing behaviour covered before the device sees it.
#
# The device it protects is the one in EDL. So every scenario here runs the REAL script against a fake
# root, with a stub `ip`, two real processes whose cmdlines carry the two names the script searches
# /proc for, and a fake netwatch log. The SIGSTOP/SIGCONT are real -- `kill` is not stubbed -- because
# "the keeper is stopped" and "the keeper is running again" are exactly the properties that must not
# be simulated.
#
# Usage: zl1-address-proof-selftest.sh [--keep]
#
# Exit codes: 0 every scenario behaved; 1 something did not; 2 the harness itself could not run.

set -u

KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
  --keep) KEEP=1; shift ;;
  --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

HERE=$(dirname "$0")
# Overridable so the mutation runs below can point the same harness at a deliberately broken copy.
# A harness that has only ever been run against a script that works has not been tested.
SRC="${ZL1_PROOF_SRC:-$HERE/../device/zl1-address-owner-proof.sh}"
[ -r "$SRC" ] || { echo "cannot read $SRC" >&2; exit 2; }

W=${TMPDIR:-/tmp}/zl1-addrproof-selftest
FR="$W/fake"
rm -rf "$W"
mkdir -p "$FR/proc" "$FR/sys/class/net/rndis0" "$FR/etc/systemd/system" "$FR/userdata" "$W/bin" || exit 2

printf 'LE_ZL1\x00' > "$FR/proc/model"

# The script under test with every device path pointed into the fake root. The /proc/<pid>/stat reads
# are deliberately NOT rewritten: the pids below are real, so their state is read from the real /proc,
# which is the only way "SIGSTOPped -> T -> resumed -> S" can be true rather than asserted.
sed -e "s#/proc/device-tree/model#$FR/proc/model#g" \
    -e "s#/proc/\[0-9\]\*#$FR/proc/[0-9]*#g" \
    -e "s|\${p#/proc/}|\${p#$FR/proc/}|g" \
    -e "s#/sys/class/net/\$i#$FR/sys/class/net/\$i#g" \
    -e "s#^LOG=/userdata/zl1-netwatch.log#LOG=$FR/userdata/zl1-netwatch.log#" \
    -e "s#^INST=/etc/systemd/system/zl1-netwatch.sh#INST=$FR/etc/systemd/system/zl1-netwatch.sh#" \
    "$SRC" > "$W/proof.sh" || exit 2
sh -n "$W/proof.sh" || { echo "the rewritten copy does not parse -- fix that first" >&2; exit 2; }

# --- the fake device's two moving parts: `ip` and the process table --------------------------------
#
# `ip` is a stub over a one-line state file, so a scenario can say exactly what the interface carries
# and can watch the script put the address back. The output shape copies the real tool (`inet` is the
# first field of the line) because the script's awk reads field 2 of it.
cat > "$W/bin/ip" <<STUB
#!/bin/sh
S="$FR/ipstate"
[ -f "\$S" ] || : > "\$S"
[ "\${1:-}" = "-4" ] && shift
case "\${1:-} \${2:-}" in
"addr show")
  for a in \$(cat "\$S"); do echo "    inet \$a brd 0.0.0.0 scope global rndis0"; done ;;
"addr del")
  grep -vx "\${3:-}" "\$S" > "\$S.new" 2>/dev/null; mv "\$S.new" "\$S" ;;
"addr add")
  grep -qx "\${3:-}" "\$S" 2>/dev/null || echo "\${3:-}" >> "\$S" ;;
esac
exit 0
STUB
chmod +x "$W/bin/ip"

# The detached self-revert is spawned with `setsid`, and nothing on this host can see it afterwards --
# except a wrapper. This records each armed timer (its pid and the command it will run) and then hands
# off to the real setsid, so the scenarios can (a) assert the arming happened with the right target,
# (b) clean up after themselves, and (c) prove the detach actually detaches. Without this the timers
# pile up across scenarios and their late `kill -CONT` lands on recycled pids -- which is how the base
# run first started failing S2 with "NOT stopped", for a reason that had nothing to do with the script.
cat > "$W/bin/setsid" <<STUB2
#!/bin/sh
printf '%s %s\n' "\$\$" "\$*" >> "$W/timers"
exec /usr/bin/setsid "\$@"
STUB2
chmod +x "$W/bin/setsid"
timers_armed() { wc -l < "$W/timers" 2>/dev/null | tr -d ' '; }
# Kill everything a scenario armed, and start counting again. Called per scenario, never globally: a
# timer armed by scenario N must not be able to touch a pid spawned by scenario N+1.
cleanup_timers() {
  if [ -s "$W/timers" ]; then
    while read -r tpid trest; do
      [ -n "$tpid" ] && kill -TERM "$tpid" 2>/dev/null
    done < "$W/timers"
  fi
  : > "$W/timers"
}
: > "$W/timers"
PATH="$W/bin:$PATH"; export PATH

PROBE=192.168.2.15/24

serial=0
mk_netwatch() {   # a real process whose cmdline carries the name the script looks for
  # The installed file is written FIRST, before the process starts -- which is the real order (the
  # install happens, then a reboot starts the watchdog) and the order that does NOT trip the
  # file-is-newer-than-the-process warning. S10 is the other order on purpose.
  printf '#!/bin/sh\n# the installed build\nensure_addrs() {\n  :\n}\n' > "$FR/etc/systemd/system/zl1-netwatch.sh"
  # A fresh copy per scenario, with a unique suffix. `cp` onto a binary that a previous scenario's
  # process is still exec'ing fails with ETXTBSY ("Text file busy"), and the copy is what makes the
  # process's /proc/<pid>/stat real, so a silently stale copy is a silently stale scenario. The name
  # still CONTAINS zl1-netwatch.sh, which is all the script under test matches on.
  serial=$((serial + 1))
  cp /bin/sleep "$W/zl1-netwatch.sh.$serial" || return 1
  "$W/zl1-netwatch.sh.$serial" 300 >/dev/null 2>&1 &
  nw=$!
  wait_for_proc "$nw"
  ln -sfn "/proc/$nw" "$FR/proc/$nw"
}
mk_keeper() {
  serial=$((serial + 1))
  cp /bin/sleep "$W/zl1-debug-net.sh.$serial" || return 1
  "$W/zl1-debug-net.sh.$serial" 300 >/dev/null 2>&1 &
  kp=$!
  wait_for_proc "$kp"
  ln -sfn "/proc/$kp" "$FR/proc/$kp"
}
wait_for_proc() {  # the symlink and the /proc read must not race the fork
  n=0
  while [ ! -r "/proc/$1/cmdline" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
}
drop_procs() {
  cleanup_timers
  for pr in ${nw:-} ${kp:-}; do [ -n "$pr" ] && kill -TERM "$pr" 2>/dev/null; done
  # Wait for them to actually go, then empty the WHOLE fake process table -- not only the two names
  # this function tracks. A scenario that left an untracked process behind (a failed copy, a
  # background proof run) would otherwise be found by the NEXT scenario's /proc walk, and "the
  # netwatch is not running" (S5c) and "the keeper is already gone" (S6) would quietly stop meaning
  # what they say.
  n=0
  while [ "$n" -lt 30 ]; do
    alive=0
    for pr in ${nw:-} ${kp:-}; do [ -n "$pr" ] && [ -d "/proc/$pr" ] && alive=1; done
    [ "$alive" = 0 ] && break
    sleep 0.1; n=$((n + 1))
  done
  # Only the numeric entries: $FR/proc also holds the device-tree `model` file the identity guard
  # reads, and a plain `*` swallowde it -- which made EVERY scenario exit 2 as "not the zl1", for a
  # reason that looked like a script defect.
  rm -f "$FR/proc"/[0-9]* 2>/dev/null
  nw=""; kp=""
}
state_of() { awk '{print $3}' "/proc/$1/stat" 2>/dev/null; }

# A stand-in for the netwatch's 2 s sample loop: after $1 seconds it writes the address back into the
# fake interface state, and -- if $2 is "log" -- appends the ADDRS line it would have written.
mk_restorer() {
  ( sleep "$1"
    grep -qx "$PROBE" "$FR/ipstate" 2>/dev/null || echo "$PROBE" >> "$FR/ipstate"
    [ "${2:-log}" = log ] && echo "$(cut -d. -f1 /proc/uptime).00s ADDRS: uptime=$(cut -d. -f1 /proc/uptime) iface=rndis0 now='$PROBE 10.15.19.82/24'" >> "$FR/userdata/zl1-netwatch.log"
  ) >/dev/null 2>&1 &
  restore_pid=$!
}

PASS=0
FAIL=0
SKIP=0
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }

out=""; rc=0
run_proof() {  # all arguments pass through; sets $out and $rc
  out=$(timeout 90 sh "$W/proof.sh" "$@" 2>&1); rc=$?
}

expect() {  # $1 wanted verdict name, $2 description (rc is checked by the caller)
  case "$out" in
  *"== verdict: $1"*) ok "$2 -> $1 (exit $rc)" ;;
  *) bad "$2 -> wanted verdict '$1' (exit $rc)"; printf '%s\n' "$out" | sed 's/^/        /' ;;
  esac
}

echo "zl1 address-owner proof -- offline self-test"
echo "  script under test: $SRC"
echo "  fake root:         $FR"
echo

# --- the safety properties, read out of the source before any scenario runs ------------------------

echo "== what the script may not do =="
# The words may appear in comments and in messages ("A reboot loads the new one"); what must not
# appear is the COMMAND -- so this matches a command position, not the word.
for pat in 'sysrq-trigger' 'kexec' '/dev/block'; do
  if grep -q "$pat" "$SRC"; then
    bad "the script mentions '$pat' -- a probe that removes an address must not be able to read a partition or ask the kernel for a reboot"
  else
    ok "no '$pat' anywhere in the script"
  fi
done
if grep -nE '(^|[;|&(])[[:space:]]*(busybox[[:space:]]+)?(reboot|poweroff|halt)([[:space:];|&)]|$)' "$SRC"; then
  bad "a reboot/poweroff/halt COMMAND appears in the script (the word in a message is fine, the command is not)"
else
  ok "no reboot/poweroff/halt command anywhere in the script"
fi
if grep -q 'systemctl' "$SRC"; then
  bad "the script mentions systemctl -- a probe must not change a unit"
else
  ok "no 'systemctl' anywhere in the script"
fi

# The signal order is the safety property: the self-revert must be ARMED before the keeper is told to
# stop, or a killed script leaves the device with no address provider.
ln_arm=$(grep -n 'REVERT_AFTER=' "$SRC" | head -1 | cut -d: -f1)
ln_stop=$(grep -n 'kill -STOP' "$SRC" | head -1 | cut -d: -f1)
if [ -n "$ln_arm" ] && [ -n "$ln_stop" ] && [ "$ln_arm" -lt "$ln_stop" ]; then
  ok "the self-revert timer is armed (line $ln_arm) before the first SIGSTOP (line $ln_stop)"
else
  bad "the SIGSTOP (line ${ln_stop:-none}) does not come after the revert arming (line ${ln_arm:-none}) -- a killed script would leave the keeper stopped"
fi

# Only one address may ever be removed, and it must be the literal -- never the one SSH arrives on.
# Comments and messages are excluded: the header and the diagnosis name the call in prose, and a
# probe's own error message about 'ip addr del' is not a second call. So the pattern is a COMMAND
# POSITION, the same shape the reboot check above uses.
cmd_del='(^|[;|&(])[[:space:]]*ip[[:space:]]+addr[[:space:]]+del'
dels=$(grep -cE "$cmd_del" "$SRC")
case "$dels" in
1) ok "exactly one 'ip addr del' as a command in the script" ;;
*) bad "'ip addr del' appears $dels times as a command: more than one place can take an address away" ;;
esac
if grep -E "$cmd_del" "$SRC" | grep -qv 'PROBE_ADDR'; then
  bad "the 'ip addr del' does not remove PROBE_ADDR -- an address other than the literal could be taken away"
else
  ok "the only 'ip addr del' command removes \$PROBE_ADDR"
fi
if grep -qE 'KEEP_ADDR.*addr del|addr del.*KEEP_ADDR' "$SRC"; then
  bad "KEEP_ADDR (the SSH address) is reachable by 'addr del'"
else
  ok "the SSH address is never the operand of 'addr del'"
fi

echo
echo "== S1: the netwatch notices and puts it back =="
drop_procs
mk_netwatch; mk_keeper
printf '%s\n%s\n' "$PROBE" 10.15.19.82/24 > "$FR/ipstate"
: > "$FR/userdata/zl1-netwatch.log"
printf '1.10s netwatch start pid=%s heal=1 stall=45s\n' "$nw" >> "$FR/userdata/zl1-netwatch.log"
mk_restorer 2 log
run_proof --yes --wait 20
expect proof-obtained "S1"
[ "$rc" = 0 ] || bad "S1: exit was $rc, wanted 0"
grepx=$(grep -c 'ADDRS:' "$FR/userdata/zl1-netwatch.log")
[ "$grepx" = 1 ] && ok "S1: the harness wrote exactly one ADDRS line (the assertion below has teeth)" \
                 || bad "S1: the log holds $grepx ADDRS lines, so 'a new line was found' proves nothing"
case "$out" in
*"the address was back"*) ok "S1: it reports how long the netwatch took" ;;
*) bad "S1: no 'the address was back' line" ;;
esac
wait "$restore_pid" 2>/dev/null
if grep -q "kill -CONT $kp" "$W/timers"; then
  ok "S1: the self-revert was armed against the keeper pid ($(timers_armed) timer(s))"
else
  bad "S1: no armed timer targets pid $kp -- the keeper could be left stopped"
fi
[ "$(state_of "$kp")" = S ] && ok "S1: the keeper is running again (state S) after the probe" \
                            || bad "S1: the keeper is in state $(state_of "$kp"), not S, after the probe"
grep -qx "$PROBE" "$FR/ipstate" && ok "S1: the address is on the interface at the end" \
                              || bad "S1: the address is gone at the end"

echo
echo "== S2: nothing restores it -- the script must restore it itself, and say so =="
drop_procs
mk_netwatch; mk_keeper
printf '%s\n%s\n' "$PROBE" 10.15.19.82/24 > "$FR/ipstate"
printf '1.10s netwatch start pid=%s heal=1 stall=45s\n' "$nw" > "$FR/userdata/zl1-netwatch.log"
run_proof --yes --wait 5
expect proof-failed "S2"
[ "$rc" = 1 ] || bad "S2: exit was $rc, wanted 1"
case "$out" in
*"STILL missing -- putting"*) ok "S2: the undo says it is putting the address back" ;;
*) bad "S2: the undo did not report restoring the address" ;;
esac
case "$out" in
*"did NOT come back within 5s"*) ok "S2: it reports the window it waited, from --wait" ;;
*) bad "S2: the wait window is not named in the output" ;;
esac
case "$out" in
*"OLD build"*) ok "S2: it points at the stale-running-build explanation" ;;
*) bad "S2: the failure output does not mention the old-build possibility" ;;
esac
grep -qx "$PROBE" "$FR/ipstate" && ok "S2: the address is back on the interface (by the script)" \
                              || bad "S2: the address was LEFT OFF the interface"
[ "$(state_of "$kp")" = S ] && ok "S2: the keeper was resumed (state S)" \
                            || bad "S2: the keeper is in state $(state_of "$kp"), not S"

echo
echo "== S3: an old ADDRS line is NOT evidence (the offset anchor) =="
drop_procs
mk_netwatch; mk_keeper
printf '%s\n%s\n' "$PROBE" 10.15.19.82/24 > "$FR/ipstate"
# The log already ends with an ADDRS line from earlier in this boot. The restorer puts the address
# back but writes NO line -- so the only line in the file is the stale one, and a script that anchored
# on "any ADDRS line" would call this proof-obtained.
printf '1.10s netwatch start pid=%s heal=1 stall=45s\n9.40s ADDRS: uptime=9 iface=rndis0 now=%s\n' "$nw" "$PROBE" \
  > "$FR/userdata/zl1-netwatch.log"
mk_restorer 2 nolog
run_proof --yes --wait 20
wait "$restore_pid" 2>/dev/null
expect proof-unclear "S3"
[ "$rc" = 1 ] || bad "S3: exit was $rc, wanted 1 (a stale line must not license the retirement)"
case "$out" in
*"no new ADDRS line"*) ok "S3: it says the line was not new" ;;
*) bad "S3: it did not distinguish the stale line from a new one" ;;
esac

echo
echo "== S4: the address cannot be taken away -- nothing is measured, the keeper still comes back =="
drop_procs
mk_netwatch; mk_keeper
printf '%s\n%s\n' "$PROBE" 10.15.19.82/24 > "$FR/ipstate"
printf '1.10s netwatch start pid=%s heal=1 stall=45s\n' "$nw" > "$FR/userdata/zl1-netwatch.log"
cp "$W/bin/ip" "$W/bin/ip.real"
# A del that silently does nothing, while `addr show` still reports the address -- the state a real
# `ip addr del` leaves behind when it cannot do the job. A stub that broke `addr show` as well would
# make the read-back untestable, because "the address is gone" and "the tool stopped answering" would
# look the same (the shape docs 107 section 6 is about).
cat > "$W/bin/ip" <<STUB
#!/bin/sh
case "\$*" in *"addr del"*) exit 0 ;; esac
exec "$W/bin/ip.real" "\$@"
STUB
chmod +x "$W/bin/ip"
run_proof --yes --wait 5
mv "$W/bin/ip.real" "$W/bin/ip"
[ "$rc" = 2 ] || bad "S4: exit was $rc, wanted 2 (not armed)"
case "$out" in
*"STILL there after 'ip addr del'"*) ok "S4: it reads the address back instead of assuming the del landed" ;;
*) bad "S4: a 'del' that did nothing was not noticed" ;;
esac
[ "$(state_of "$kp")" = S ] && ok "S4: the keeper was resumed even on the not-armed path" \
                            || bad "S4: the keeper is in state $(state_of "$kp")"

echo
echo "== S5: not armed -- the three preconditions =="
drop_procs
mk_netwatch; mk_keeper
printf '%s\n%s\n' "$PROBE" 10.15.19.82/24 > "$FR/ipstate"
printf '1.10s netwatch start\n' > "$FR/userdata/zl1-netwatch.log"

run_proof --wait 5                      # no --yes
[ "$rc" = 2 ] && case "$out" in
  *"refusing without --yes"*) ok "S5a: a probe that stops a process refuses without --yes" ;;
  *) bad "S5a: no --yes, but the refusal was not the --yes one" ;;
esac || bad "S5a: exit was $rc without --yes, wanted 2"
[ "$(state_of "$kp")" = S ] || bad "S5a: the keeper was touched without --yes"

printf '#!/bin/sh\n# an older build\nrestore_addrs() {\n  :\n}\n' > "$FR/etc/systemd/system/zl1-netwatch.sh"
run_proof --yes --wait 5
[ "$rc" = 2 ] || bad "S5b: exit was $rc for a build with no ensure_addrs(), wanted 2"
case "$out" in
*"has no ensure_addrs()"*) ok "S5b: an installed build without ensure_addrs() is refused, not measured" ;;
*) bad "S5b: the missing-ensure_addrs refusal did not fire" ;;
esac
printf '#!/bin/sh\n# the installed build\nensure_addrs() {\n  :\n}\n' > "$FR/etc/systemd/system/zl1-netwatch.sh"

rm -f "$FR/proc/$nw"                    # the netwatch is not running
run_proof --yes --wait 5
[ "$rc" = 2 ] || bad "S5c: exit was $rc with no netwatch running, wanted 2"
case "$out" in
*"netwatch is NOT RUNNING"*) ok "S5c: no netwatch -> refuse and name the installer" ;;
*) bad "S5c: a missing netwatch was not reported as the reason" ;;
esac
ln -sfn "/proc/$nw" "$FR/proc/$nw"

echo
echo "== S6: the keeper is already gone -- that IS the configuration being asked about =="
drop_procs
mk_netwatch
printf '%s\n%s\n' "$PROBE" 10.15.19.82/24 > "$FR/ipstate"
printf '1.10s netwatch start pid=%s heal=1 stall=45s\n' "$nw" > "$FR/userdata/zl1-netwatch.log"
mk_restorer 2 log
run_proof --yes --wait 20
wait "$restore_pid" 2>/dev/null
expect proof-obtained "S6"
case "$out" in
*"debug keeper is NOT running"*) ok "S6: it says the keeper is absent rather than stopping nothing" ;;
*) bad "S6: the keeper-absent case is not reported" ;;
esac
case "$out" in
*"keeper resumed"*) bad "S6: it claims to have resumed a keeper that was never running" ;;
*) ok "S6: no resume is reported when nothing was stopped" ;;
esac
[ "$rc" = 0 ] || bad "S6: exit was $rc, wanted 0"

echo
echo "== S7: the wrong device =="
drop_procs
printf 'Some Other Device\x00' > "$FR/proc/model"
run_proof --yes --wait 5
[ "$rc" = 2 ] || bad "S7: exit was $rc on a non-zl1 model, wanted 2"
case "$out" in
*"not LE_ZL1"*) ok "S7: a device-tree model that is not LE_ZL1 stops it" ;;
*) bad "S7: the identity guard did not fire" ;;
esac
printf 'LE_ZL1\x00' > "$FR/proc/model"

echo
echo "== S8: --wait needs a number =="
run_proof --yes --wait
[ "$rc" = 2 ] || bad "S8: exit was $rc for '--wait' with no value, wanted 2"
case "$out" in
*"--wait needs a SECONDS argument"*) ok "S8: '--wait' with no value -> a message and exit 2" ;;
*) bad "S8: '--wait' with no value -> [$out]" ;;
esac
run_proof --yes --wait 2
[ "$rc" = 2 ] || bad "S8: exit was $rc for '--wait 2', wanted 2"
case "$out" in
*"below 5 s"*) ok "S8: a window shorter than the sample loop is refused" ;;
*) bad "S8: '--wait 2' was not refused" ;;
esac
run_proof --bogus
[ "$rc" = 2 ] || bad "S8: exit was $rc for an unknown flag, wanted 2"

echo
echo "== S9: --help prints the whole header, not a fixed range =="
run_proof --help
# The header only: `grep -c '^#'` would count the inline comments further down the file too, and then
# the count could never match however much of the header --help printed (the docs 104 trap, one level
# up).
n_hdr=$(awk 'NR==1{next} /^#/{n++; next} {exit} END{print n+0}' "$SRC")
n_shown=$(printf '%s\n' "$out" | grep -c '^#')
[ "$n_shown" = "$n_hdr" ] && ok "S9: --help printed all $n_hdr header lines" \
                         || bad "S9: --help printed $n_shown of $n_hdr header lines"
case "$out" in
*"10.15.19.82/24"*) ok "S9: the header states the address that is never touched" ;;
*) bad "S9: the header does not name the SSH address" ;;
esac

echo
echo "== S10: the running watchdog predates the installed file =="
# The installer deliberately does not restart the watchdog (docs 111), so right after an install the
# process in memory is the OLD build while the file on disk is the new one -- and then this proof
# fails for a reason that has nothing to do with the mechanism. That is the confusing first run the
# age line exists to explain, so it must actually appear.
drop_procs
mk_netwatch; mk_keeper
printf '%s\n%s\n' "$PROBE" 10.15.19.82/24 > "$FR/ipstate"
printf '1.10s netwatch start pid=%s heal=1 stall=45s\n' "$nw" > "$FR/userdata/zl1-netwatch.log"
# 3 s, not 1: the comparison in the script is between two second-floored timestamps and carries about
# a second of slop, so a 1 s gap is indistinguishable from the rounding -- which made this scenario
# flaky, which made the script's own threshold 2 s (see the comment there).
sleep 3
printf '#!/bin/sh\n# the installed build, written AFTER the process started\nensure_addrs() {\n  :\n}\n' \
  > "$FR/etc/systemd/system/zl1-netwatch.sh"
run_proof --yes --wait 5
case "$out" in
*"NEWER than the running process"*) ok "S10: it says the process in memory is the old build, and why" ;;
*) bad "S10: a file newer than the running watchdog was not reported" ;;
esac
case "$out" in
*"A reboot loads the new"*) ok "S10: it names the fix (a reboot), not just the symptom" ;;
*) bad "S10: the old-build warning does not say what to do" ;;
esac

echo
echo "== S11: the netwatch logs it and the address does not stick =="
# The other half of the verdict: a new ADDRS line with NO address. That is not a success and it is not
# a silence either -- restore_addrs() ran and the add failed -- so it has to be told apart from S2.
# Without this scenario the verdict could be decided by the log line alone and nothing would notice.
drop_procs
mk_netwatch; mk_keeper
printf '%s\n%s\n' "$PROBE" 10.15.19.82/24 > "$FR/ipstate"
printf '1.10s netwatch start pid=%s heal=1 stall=45s\n' "$nw" > "$FR/userdata/zl1-netwatch.log"
( sleep 2
  echo "$(cut -d. -f1 /proc/uptime).00s ADDRS: uptime=$(cut -d. -f1 /proc/uptime) iface=rndis0 now='$PROBE 10.15.19.82/24'" >> "$FR/userdata/zl1-netwatch.log"
) >/dev/null 2>&1 &
restore_pid=$!
run_proof --yes --wait 8
wait "$restore_pid" 2>/dev/null
expect proof-failed "S11"
case "$out" in
*"did not stick"*) ok "S11: a logged restore that did not land is its own failure, named" ;;
*) bad "S11: a new ADDRS line with no address was judged as something other than 'not sticking'" ;;
esac
case "$out" in
*"== verdict: proof-obtained"*) bad "S11: the log line alone was enough for a pass" ;;
*) ok "S11: the log line alone is NOT enough for a pass" ;;
esac

echo
echo "== S12: the script is KILLED while it waits -- that is the case the timer exists for =="
# The most important property in the file, and the only one a normal scenario cannot reach: if the SSH
# session drops (or the script is killed) between the SIGSTOP and the undo, the exit trap never runs, so
# the keeper is resumed only by the DETACHED timer. This kills the script there on purpose and asserts
# the state it leaves behind -- stopped, address still off -- and that the armed timer is alive.
drop_procs
mk_netwatch; mk_keeper
printf '%s\n%s\n' "$PROBE" 10.15.19.82/24 > "$FR/ipstate"
printf '1.10s netwatch start pid=%s heal=1 stall=45s\n' "$nw" > "$FR/userdata/zl1-netwatch.log"
sh "$W/proof.sh" --yes --wait 20 > "$W/bg.out" 2>&1 &
bg=$!
# Wait for the setup it performs (stop the keeper, take the address) instead of guessing a duration:
# a fixed sleep makes this scenario pass or fail on machine load, not on the script.
n=0
while [ "$(grep -c "$PROBE" "$FR/ipstate" 2>/dev/null)" != 0 ] && [ "$n" -lt 60 ]; do
  sleep 0.25; n=$((n + 1))
done
sleep 1
t_stop=$(state_of "$kp")
t_addr=$(grep -c "$PROBE" "$FR/ipstate")
kill -9 "$bg" 2>/dev/null
wait "$bg" 2>/dev/null
sleep 1
[ "$t_stop" = T ] && ok "S12: the keeper was stopped before the kill (the scenario is set up)" \
                 || bad "S12: the keeper was in state '$t_stop' before the kill -- the setup raced"
[ "$t_addr" = 1 ] && bad "S12: the address was already gone before the kill -- the check below would pass for the wrong reason" \
                  || ok "S12: the address had been removed before the kill (so a restored one is a real restore)"
[ "$(state_of "$kp")" = T ] && ok "S12: after kill -9 the keeper is STILL stopped (the exit trap did not run)" \
                           || bad "S12: the keeper was resumed by something other than the timer -- this test proves nothing"
grep -qx "$PROBE" "$FR/ipstate" && bad "S12: the address came back although the script was killed" \
                               || ok "S12: the address is still off, as it must be with the script gone"
tpid=$(awk '{print $1}' "$W/timers" 2>/dev/null | head -1)
if [ -n "$tpid" ] && [ -d "/proc/$tpid" ]; then
  ok "S12: the detached timer (pid $tpid) is alive and will resume the keeper"
else
  bad "S12: no armed timer survived the kill -- a dropped SSH session would leave the keeper stopped"
fi
grep -q "kill -CONT $kp" "$W/timers" 2>/dev/null && ok "S12: and it targets the keeper pid, not something else" \
                                                || bad "S12: the surviving timer does not target pid $kp"
# Undo by hand, then hand the timer's clean-up back to drop_procs.
kill -CONT "$kp" 2>/dev/null
ip addr add "$PROBE" dev rndis0 2>/dev/null
[ "$(state_of "$kp")" = S ] && ok "S12: the keeper is running again once it is resumed" \
                           || bad "S12: the keeper did not resume on SIGCONT"

echo
echo "== the health check cites this harness's count, and that citation cannot drift =="
# Same rule as the GPS harness's section 12 (docs 110): the health check names each harness with a
# hand-typed check count, and a stale number there fails nothing. This one is compared against the run.
HEALTH="$HERE/zl1-health-check.sh"
if [ ! -r "$HEALTH" ]; then
  printf 'SKIP  %s is not readable, so there is no citation to check\n' "$HEALTH"
  SKIP=$((SKIP + 1))
else
  cited=$(sed -e 's/always "/ /g' -e 's/"$//' "$HEALTH" | tr '\n' ' ' |
            sed -n 's/.*zl1-address-proof-selftest\.sh[ ,(]*\([0-9][0-9]*\) checks.*/\1/p')
  total=$((PASS + FAIL + 1))
  if [ -n "$cited" ] && [ "$cited" = "$total" ]; then
    ok "the health check cites $cited checks, and this run has $total (the citation is live)"
  else
    bad "the health check cites '${cited:-nothing}' checks for this harness; this run has $total"
  fi
fi

drop_procs
echo
echo "pass=$PASS fail=$FAIL${SKIP:+ skip=$SKIP}"
[ "$KEEP" = 1 ] || rm -rf "$W"
[ "$FAIL" = 0 ]
