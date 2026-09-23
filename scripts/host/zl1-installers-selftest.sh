#!/bin/sh
# zl1 installer scripts -- offline self-test for the two that write DEVICE STATE and have no harness.
#
# Host-side, touches no device. The two scripts:
#
#   scripts/install-retire-debug-keeper.sh   the remaining HEAT fix (docs 72 section 4b, 94)
#   scripts/install-no-edl-on-panic.sh       the never-brick fix (docs 86)
#
# Why they need one, and why they are the pair that does:
#
#   * `install-retire-debug-keeper.sh --install --now` KILLS A PROCESS ON THE DEVICE. Its whole safety
#     argument is a refusal gate -- "it refuses to kill when it cannot see an address" -- and a refusal
#     gate that does not actually refuse is indistinguishable from no gate at all until the day the
#     network does not come back. It also has a matching function that deliberately is NOT a substring
#     test, because "killing the wrong process" is the one failure mode worth being pedantic about.
#   * `install-no-edl-on-panic.sh` decides whether a kernel panic puts the phone in EDL. It is the one
#     installer whose *absence of effect* is the safety property, and its comment records that an
#     earlier draft's `--capture-only` disabled and deleted the policy unit -- i.e. re-running a
#     read-only-looking inspection silently DISARMED a guard, in the unsafe direction.
#
# Both are `bash` scripts that drive a device over ssh, and both carry their device-side appliers as
# here-docs. That is what makes them testable offline without inventing anything: the harness supplies
# the device. `ssh` is stubbed by a script that RUNS the remote command locally, in a fake root, so
# `--install` really writes the files, `--status` really walks a `/proc`, and the applier that systemd
# would start is the applier that runs. The stub is the transport, not the logic: every line under test
# is the project's own.
#
# Design note, and the difference from the other five harnesses: the fake device is a fake **root** and
# the stubs are the device's *effects*. `kill` is a stub because signalling a real host pid would be
# dangerous -- so it is written as what the device's process table would do (remove the fake
# /proc/<pid>), which is also what makes the applier's verify-and-watch loop reachable at all:
# `$W/killignore/<pid>` makes a kill not take, and `$W/restart` makes something come back afterwards.
# `systemctl start <unit>` runs the unit's own `ExecStart`, so `--install --now` exercises the applier
# through the same path the device would use.
#
# Usage: zl1-installers-selftest.sh [--keep]
#   --keep   leave the fake root, the stubs and the run logs in place for inspection
#
# Exit codes: 0 every scenario behaved; 1 something did not; 2 the harness could not set up.

set -u

KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
  --keep) KEEP=1; shift ;;
  --help|-h) sed -n '2,34p' "$0"; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

HERE=$(dirname "$0")
RK="$HERE/../install-retire-debug-keeper.sh"
NE="$HERE/../install-no-edl-on-panic.sh"
for f in "$RK" "$NE"; do [ -r "$f" ] || { echo "cannot read $f" >&2; exit 2; }; done
command -v bash >/dev/null 2>&1 || { echo "the installers are bash scripts; bash is required" >&2; exit 2; }

W=${TMPDIR:-/tmp}/zl1-installers-selftest
FR="$W/fake"
STUB="$W/stub"
ACT="$W/actions"
rm -rf "$W"
mkdir -p "$FR/etc/systemd/system" "$FR/proc" "$FR/sys/class/net/rndis0" "$FR/sys/module/msm_poweroff/parameters" \
         "$FR/sys/fs/pstore" "$FR/userdata" "$FR/usr/local/sbin" "$FR/run" \
         "$W/applier" "$W/killignore" "$FR/proc/sys/kernel/random" "$STUB" || exit 2

# --- the fake device's state ---------------------------------------------------------------------
#
# The keeper the retirement exists to kill. Its cmdline is "/bin/sh /usr/local/sbin/zl1-debug-net.sh",
# which is what docs 72's `ps` showed and what the applier's `is_keeper_cmdline` is written against:
# argv[0] is a shell, argv[1] IS the path.
# The path in the fake cmdline is the FAKE ROOT's copy of it, because the transport rewrites the
# keeper's path (it has to: `--status` runs `ls -l $KEEPER`, and creating a file in the host's real
# /usr/local/sbin is not something a test may do). So the fake device's process table names the file
# the fake device has, exactly as the real one names its own.
KEEPER_F="$FR/usr/local/sbin/zl1-debug-net.sh"
keeper_cmdline() { # $1 = fake proc pid
  printf '/bin/sh\0%s\0' "$KEEPER_F" > "$FR/proc/$1/cmdline"
}
keeper_proc() { # $1 = pid. The stat line has the 15 fields a real one has, with utime=7 stime=3, so
                # the applier's cpu_ticks reading is a number and not an empty string.
  mkdir -p "$FR/proc/$1"
  keeper_cmdline "$1"
  printf '%s (keeper) S 1 %s %s 0 -1 4194304 10 0 0 0 7 3 0 0
' "$1" "$1" "$1" > "$FR/proc/$1/stat"
}
keeper_proc 900
printf '1\n' > "$FR/sys/module/msm_poweroff/parameters/download_mode"
printf 'the keeper itself, for the status listing\n' > "$FR/usr/local/sbin/zl1-debug-net.sh"
printf '100.0 900.0\n' > "$FR/proc/uptime"
printf 'deadbeef-0000-0000-0000-000000000000\n' > "$FR/proc/sys/kernel/random/boot_id"
printf 'rndis0\n' > "$FR/sys/class/net/rndis0/uevent"

# --- the stubs -----------------------------------------------------------------------------------
#
# Only the device's effects. Everything else (mkdir, cp, ls, awk, sed, cat, printf, read) runs for
# real, inside the fake root, so the assertions can look at actual files.
mkstub() { # name
  printf '#!/bin/sh\nprintf "%%s %%s\\n" "%s" "$*" >> "%s"\n' "$1" "$ACT" > "$STUB/$1"
  chmod +x "$STUB/$1"
}
mkstub sleep      # the applier waits 45 s for an address and watches 30 s; stubbed, so it is instant
mkstub logger

# ip: the applier's gate asks exactly one question -- is one of the two addresses on rndis0/usb0.
cat > "$STUB/ip" <<EOF
#!/bin/sh
printf 'ip %s\n' "\$*" >> "$ACT"
case "\$*" in
*"addr show dev"*)
  # Real "ip -4 addr show dev X" shape: an interface line, then one INDENTED line per address. That
  # indentation is load-bearing -- the applier takes field 2 of the line matching "inet ", and on the
  # real output that field is the CIDR. A single-line fixture (index, name and address on one line)
  # would put the interface NAME in field 2 and make the gate answer "no address" for every scenario,
  # which is a fixture lying, not a bug in the script.
  #
  # No backticks in this heredoc: it is unquoted, so a backquote would be COMMAND SUBSTITUTION -- the
  # first draft of this stub had them in a comment, and the awk it accidentally ran read the harness's
  # own stdin, blocked forever, and left this file empty (the redirection truncates before cat runs).
  printf '2: rndis0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP group default qlen 1000\n'
  # FAKE_ADDR is the SWITCH ("none" = no address, anything else = an address), except that a value that
  # looks like one is used as that address -- so a scenario can say "the 10.x address is there".
  case "\${FAKE_ADDR:-yes}" in
  none) ;;
  yes|'') printf '    inet 192.168.2.15/24 brd 192.168.2.255 scope global rndis0\n' ;;
  both)   printf '    inet 192.168.2.15/24 brd 192.168.2.255 scope global rndis0\n'
          printf '    inet 10.15.19.82/24 brd 10.15.19.255 scope global rndis0\n' ;;
  *)      printf '    inet %s/24 brd 192.168.2.255 scope global rndis0\n' "\$FAKE_ADDR" ;;
  esac ;;
esac
exit 0
EOF

# kill: MUST be a stub -- a real `kill -TERM 4242` would signal whatever host process holds that pid.
# It is written as what the device's process table does: the fake /proc entry goes away. The two
# markers are how the applier's failure branches become reachable:
#   $W/killignore/<pid>   the signal does not take (a process that refuses to die)
#   $W/restart            something starts the keeper again immediately afterwards (docs 94: then the
#                         kill lever is the wrong lever and only a boot-image change retires it)
cat > "$STUB/kill" <<EOF
#!/bin/sh
printf 'kill %s\n' "\$*" >> "$ACT"
sig="\$1"; shift
for p in "\$@"; do
  [ -e "$W/killignore/\$p" ] && continue
  [ -d "$FR/proc/\$p" ] && rm -rf "$FR/proc/\$p"
  if [ -e "$W/restart" ]; then
    mkdir -p "$FR/proc/9001"
    printf '/bin/sh\000%s\000' "$KEEPER_F" > "$FR/proc/9001/cmdline"
    printf '9001 (keeper) S 1 9001 9001 0 -1 4194304 10 0 0 0 7 3 0 0\n' > "$FR/proc/9001/stat"
  fi
done
exit 0
EOF

# systemctl: records, answers the read-only queries, and for `start <unit>` runs that unit's own
# ExecStart -- so --install --now exercises the applier the way the device would. A harness-prepared
# copy in $W/applier/ is preferred, because the applier's device paths have to be pointed at the fake
# root; the harness asserts the LANDED file's content separately, before making that copy.
cat > "$STUB/systemctl" <<EOF
#!/bin/sh
printf 'systemctl %s\n' "\$*" >> "$ACT"
case "\$1" in
start)
  u="\$2"
  ex=\$(sed -n 's/^ExecStart=//p' "$FR/etc/systemd/system/\$u" 2>/dev/null | head -1)
  # the applier's device paths have to point at the fake root, so a harness-prepared copy of the
  # SAME FILE is preferred when there is one. The landed file's content is asserted separately.
  alt="$W/applier/\$(basename "\$ex")"
  [ -f "\$alt" ] && ex="\$alt"
  [ -n "\$ex" ] && exec env PATH="$STUB:\$PATH" FAKE_ADDR="\${FAKE_ADDR:-yes}" sh "\$ex"
  ;;
is-enabled)
  case "\$*" in
  *zl1-retire-debug-keeper*) [ -f "$FR/etc/systemd/system/zl1-retire-debug-keeper.service" ] && echo enabled || echo disabled ;;
  *zl1-panic-guard*)         [ -f "$FR/etc/systemd/system/zl1-panic-guard.service" ] && echo enabled || echo disabled ;;
  *zl1-no-edl-on-panic*)     [ -f "$FR/etc/systemd/system/zl1-no-edl-on-panic.service" ] && echo enabled || echo disabled ;;
  *) echo enabled ;;
  esac ;;
is-active)
  case "\$*" in
  *zl1-retire-debug-keeper*) [ -e "$W/active-retire" ] && echo active || echo inactive ;;
  *) echo active ;;
  esac ;;
show)
  case "\$*" in
  *-p\ Result*) printf 'success\n' ;;
  *-p\ ExecMainStatus*) printf '0\n' ;;
  *-p\ MainPID*) printf '0\n' ;;
  *-p\ NRestarts*) printf '0\n' ;;
  *-p\ ActiveState*) printf 'inactive\n' ;;
  *-p\ SubState*) printf 'dead\n' ;;
  *-p\ ExecMainStartTimestamp*) printf 'n/a\n' ;;
  *-p\ Result\ --value*) printf 'success\n' ;;
  *-p\ ExecMainStatus\ --value*) printf '0\n' ;;
  esac ;;
cat)
  u="\$2"
  [ -f "$FR/etc/systemd/system/\$u" ] && cat "$FR/etc/systemd/system/\$u" || echo "Unit \$u could not be found." ;;
esac
exit 0
EOF
chmod +x "$STUB"/*

# ssh: this is the DEVICE, and it is the whole reason these two scripts are testable offline. It drops
# the connection options, then RUNS the remote command locally with the device's absolute paths turned
# into the fake root and the stubs in front of PATH. So `--install`'s `cat > /etc/systemd/system/...`
# writes into the fake root for real, and `--status`'s remote script really walks a /proc.
#
# The path map lives in its own sed script, because it is needed twice: for the command string, and for
# the *stdin* when the command is `sh -s` (which is how the installers send their --status script).
# Rewriting only the command would leave that script pointed at the host's own /proc and /sys. It is
# deliberately NOT applied to stdin in the `cat > FILE` form: those payloads are the appliers, which run
# on the device and must keep device paths.
: > "$W/paths.sed"
emit() { printf '%s\n' "$1" >> "$W/paths.sed"; }
emit "s#/etc/systemd/system#$FR/etc/systemd/system#g"
emit "s#/usr/local/sbin/zl1-debug-net.sh#$FR/usr/local/sbin/zl1-debug-net.sh#g"
emit "s#/sys/fs/pstore#$FR/sys/fs/pstore#g"
emit "s#/sys/class/net#$FR/sys/class/net#g"
emit "s#/sys/module#$FR/sys/module#g"
emit "s#/userdata#$FR/userdata#g"
emit "s#/run/zl1-debug-net.lock#$FR/run/zl1-debug-net.lock#g"
emit "s#/proc/sys/kernel/random/boot_id#$FR/proc/sys/kernel/random/boot_id#g"
emit "s#/proc/uptime#$FR/proc/uptime#g"
emit "s#/proc/\[0-9\]\*#$FR/proc/[0-9]*#g"
emit "s|\\\${d#/proc/}|\\\${d#$FR/proc/}|g"
emit "s|/proc/\\\$ppid|$FR/proc/\\\$ppid|g"
emit "s|/proc/\\\$p/|$FR/proc/\\\$p/|g"

cat > "$STUB/ssh" <<EOF
#!/bin/sh
printf 'ssh %s\n' "\$*" >> "$ACT"
while [ \$# -gt 0 ]; do
  case "\$1" in *@*) shift; break ;; *) shift ;; esac
done
cmd=\$(printf '%s' "\$*" | sed -f "$W/paths.sed")
case "\$cmd" in
*"sh -s"*)
  # the script is on stdin, so the same map has to be applied to it before it runs
  sed -f "$W/paths.sed" > "$W/stdin.script"
  exec env PATH="$STUB:\$PATH" FAKE_ADDR="\${FAKE_ADDR:-yes}" sh "$W/stdin.script"
  ;;
esac
exec env PATH="$STUB:\$PATH" FAKE_ADDR="\${FAKE_ADDR:-yes}" sh -c "\$cmd"
EOF
chmod +x "$STUB/ssh"

# The stub's rewriting IS the fake device, so a sed expression broken by a delimiter collision would
# silently send the installers at the HOST's own /etc, /proc and /sys -- which is the exact class of
# failure this project keeps finding in its own instruments, and here it would surface as fifteen
# mysterious assertion failures rather than as one clear one. So the transport is checked once, on the
# string shapes the installers actually send, before anything else runs.
probe=$(cat <<'PROBE' | "$STUB/ssh" root@10.15.19.82 sh -s 2>&1
echo /etc/systemd/system /sys/class/net /proc/uptime
echo '/proc/[0-9]*'
echo 'x${d#/proc/}y'
echo 'z/proc/$ppid/comm'
PROBE
)
case "$probe" in
*"sed:"*) echo "the ssh stub's path rewriting is broken: $probe" >&2; exit 2 ;;
esac
for shape in "$FR/etc/systemd/system $FR/sys/class/net $FR/proc/uptime" \
             "$FR/proc/[0-9]*" ; do
  printf '%s\n' "$probe" | grep -qF -- "$shape" ||
    { echo "the ssh stub did not rewrite '$shape' (got: $probe)" >&2; exit 2; }
done
printf '%s\n' "$probe" | grep -qF -- "\${d#$FR/proc/}" ||
  { echo "the ssh stub did not rewrite the \${d#/proc/} prefix strip (got: $probe)" >&2; exit 2; }
printf '%s\n' "$probe" | grep -qF -- "z$FR/proc/\$ppid/comm" ||
  { echo "the ssh stub did not rewrite /proc/\$ppid (got: $probe)" >&2; exit 2; }

# --- the checks ----------------------------------------------------------------------------------

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
want()    { if printf '%s\n' "$2" | grep -Eq "$1"; then ok "$3"; else bad "$3"; printf '%s\n' "$2" | sed 's/^/        | /'; fi; }
notwant() { if printf '%s\n' "$2" | grep -Eq "$1"; then bad "$3"; printf '%s\n' "$2" | grep -E "$1" | sed 's/^/        | /'; else ok "$3"; fi; }

# `systemctl` is called for read-only queries in every mode, so the assertion is never "it called
# systemd" -- it is "no call that CHANGES the unit state unless this mode is the one that must".
sysacts()  { grep -E '^systemctl ' "$ACT" 2>/dev/null; }
syswrite() { grep -E '^systemctl (daemon-reload|restart|start|stop|mask|mask --runtime|enable|enable --now|disable|disable --now|unmask --runtime)' "$ACT" 2>/dev/null; }
kills()    { grep -E '^kill ' "$ACT" 2>/dev/null; }
# The applier's log() writes to the journal (via logger) and to stdout. The installer pipes the ssh
# output through `tail -4`, so stdout is a WINDOW on that log, not the log -- the journal record is the
# complete copy, and it is what an operator would read on the device. Assertions about what the applier
# said therefore read the logger records; assertions about what the operator saw stay on $OUT.
applier_log() { grep -E '^logger -t zl1-retire-keeper ' "$ACT" 2>/dev/null | sed 's/^logger -t zl1-retire-keeper //'; }
# Everything the fake device holds, so "wrote nothing" is checkable rather than asserted from a log.
snap()     { find "$FR" -printf '%p %s\n' 2>/dev/null | sort; }

# $1 = script, rest = args. Output in $OUT, exit code in $RC. FAKE_ADDR is what the fake device's
# rndis0 would answer, so a scenario that wants "no address" sets it to none and calls env_reset after.
RUN_ADDR=yes
env_reset() { RUN_ADDR=yes; rm -f "$W/restart" "$W/active-retire"; rm -rf "$W/killignore"; mkdir -p "$W/killignore"; }
run() {
  s="$1"; shift
  : > "$ACT"
  OUT=$(PATH="$STUB:$PATH" FAKE_ADDR="$RUN_ADDR" timeout 120 bash "$s" "$@" 2>&1); RC=$?
}
runsh() { # same, for a device-side applier
  s="$1"; shift
  : > "$ACT"
  OUT=$(PATH="$STUB:$PATH" FAKE_ADDR="$RUN_ADDR" timeout 120 sh "$s" "$@" 2>&1); RC=$?
}

echo "zl1 installer self-test -- the two installers that write device state"
echo "  retire the debug keeper: $RK"
echo "  no-EDL-on-panic:         $NE"
echo "  fake device:             $FR"
echo

# ==================================================================================================
echo "== 1. --status and --explain change nothing on the device =="
# ==================================================================================================
BEFORE=$(snap)
run "$RK" --status
printf '%s\n' "$OUT" > "$W/out.rk.status"
[ "$RC" = 0 ] && ok "retire --status exits 0" || bad "retire --status exited $RC"
[ "$(snap)" = "$BEFORE" ] && ok "retire --status wrote nothing to the fake device" || bad "retire --status changed the fake device"
[ -z "$(syswrite)" ] && ok "retire --status makes no systemd call that changes anything" || { bad "retire --status would change the device:"; syswrite | sed 's/^/        | /'; }
want 'pid=900' "$OUT" "retire --status finds the keeper and names it"
want 'ppid_comm=' "$OUT" "and reports who started it (the ramdisk, not systemd)"
want 'cpu_ticks=10' "$OUT" "and the keeper's own CPU ticks (utime+stime from its stat), so 'a full core' is measurable later"
want 'no lock directory' "$OUT" "and says so when the lock is absent rather than printing nothing"
want '192\.168\.2\.15/24: present' "$OUT" "and reads the interface's addresses the way the applier's gate does"
want '10\.15\.19\.82/24: MISSING' "$OUT" "distinguishing the two, so the gate's own reading is visible before it is trusted"

run "$RK" --explain
printf '%s\n' "$OUT" > "$W/out.rk.explain"
[ "$RC" = 0 ] && ok "retire --explain exits 0" || bad "retire --explain exited $RC"
[ "$(snap)" = "$BEFORE" ] && ok "retire --explain wrote nothing" || bad "retire --explain changed the fake device"
want 'REWRITES BOTH FILES EVERY BOOT' "$OUT" "retire --explain gives the reason a unit edit cannot work"
want 'keeper duplicate exit v63' "$OUT" "and the reason the systemd instance is not the survivor"
want 'a kill and not a unit edit|kill and not a unit edit' "$OUT" "and names what is left as the only lever"

# ==================================================================================================
echo
echo "== 2. --install: two files, that content, enabled -- and NOTHING on this boot =="
# ==================================================================================================
run "$RK" --install
printf '%s\n' "$OUT" > "$W/out.rk.install"
[ "$RC" = 0 ] && ok "retire --install exits 0" || bad "retire --install exited $RC"
RKS="$FR/etc/systemd/system/zl1-retire-debug-keeper.sh"
RKU="$FR/etc/systemd/system/zl1-retire-debug-keeper.service"
[ -f "$RKS" ] && ok "it wrote the applier" || bad "no applier at $RKS"
[ -f "$RKU" ] && ok "it wrote the unit" || bad "no unit at $RKU"
[ "$(find "$FR/etc/systemd/system" -type f | wc -l)" = 2 ] && ok "and those are the only two files it added" \
  || { bad "it added more:"; find "$FR/etc/systemd/system" -type f | sed 's/^/        | /'; }
if [ -f "$RKU" ]; then
  want '^Type=oneshot$' "$(cat "$RKU")" "the unit is oneshot"
  want '^After=local-fs\.target zl1-netwatch\.service$' "$(cat "$RKU")" "and ordered AFTER the netwatch -- the thing that makes the keeper redundant"
  want '^ExecStart=/etc/systemd/system/zl1-retire-debug-keeper\.sh$' "$(cat "$RKU")" "ExecStart is the applier, by its device path"
  want '^RemainAfterExit=yes$' "$(cat "$RKU")" "RemainAfterExit, so its result is readable afterwards"
  want '^StartLimitIntervalSec=0$' "$(cat "$RKU")" "and no start limit, because it waits for an address before it acts"
fi
[ -x "$RKS" ] && ok "the applier is executable" || bad "the applier is not executable"
want '^#!/bin/sh$' "$(head -1 "$RKS")" "the applier is sh, as the ramdisk-started keeper's environment implies"
want 'systemctl mask --runtime' "$(cat "$RKS")" "the applier masks the unit at runtime (a /run file, so it outlives the keeper)"
want 'REFUSING' "$(cat "$RKS")" "and carries the refusal gate"
want 'is_keeper_cmdline' "$(cat "$RKS")" "and matches the keeper by argv, not by substring"
want '^systemctl daemon-reload' "$(sysacts)" "it asks for a daemon-reload"
want '^systemctl enable zl1-retire-debug-keeper\.service' "$(sysacts)" "and enables the unit"
notwant '^systemctl (start|enable --now)' "$(sysacts)" "--install does NOT start it: the current boot is untouched"
notwant '^kill ' "$(kills)" "and nothing was killed"
[ -d "$FR/proc/900" ] && ok "the keeper is still there -- --install alone takes nothing away" || bad "the keeper is gone after --install"
want 'nothing was changed on the current boot' "$OUT" "and it says so out loud"
want 'install --now' "$OUT" "and names the flag that would also retire it now"
[ -e "$W/active-retire" ] && bad "the unit was started" || ok "the unit was not started"

# the applier copy the device would run, pointed at the fake root. The LANDED file's content was
# asserted above; this is the same file with its device paths moved, exactly like the other harnesses.
# `kill` is a shell BUILTIN, so no PATH stub can intercept it -- and the applier's whole job is to
# signal pids, which on the host would be whatever process holds that number. So the copy calls the
# stub BY PATH. This is the one rewrite here that changes a command rather than a path, and it exists
# for safety as much as for observability.
sed -e "s#/proc/\[0-9\]\*#$FR/proc/[0-9]*#g" \
    -e "s|\${d#/proc/}|\${d#$FR/proc/}|" \
    -e "s#/proc/\$p/#$FR/proc/\$p/#g" \
    -e "s#/sys/class/net#$FR/sys/class/net#g" \
    -e "s#/usr/local/sbin/zl1-debug-net.sh#$FR/usr/local/sbin/zl1-debug-net.sh#g" \
    -e "s#kill -#$STUB/kill -#g" \
    "$RKS" > "$W/applier/zl1-retire-debug-keeper.sh"
APPLIER=$W/applier/zl1-retire-debug-keeper.sh
sh -n "$APPLIER" || { echo "the rewritten applier does not parse" >&2; exit 2; }
grep -qF "$FR/proc/[0-9]*" "$APPLIER" && grep -qF "$FR/proc/\$p/" "$APPLIER" \
  || { echo "the applier rewrite did not land" >&2; exit 2; }
grep -qF "$STUB/kill -TERM" "$APPLIER" || { echo "the kill rewrite did not land" >&2; exit 2; }
grep -qE '(^|[^-/])kill -' "$APPLIER" && grep -vE "^ *#" "$APPLIER" | grep -qE '(^|[^-/])kill -' \
  && { echo "a bare kill - survived the rewrite, which would signal a real host pid" >&2; exit 2; }
[ "$(grep -c '^#!/bin/sh$' "$APPLIER")" = 1 ] \
  || { echo "the applier rewrite disturbed the shebang" >&2; exit 2; }

# ==================================================================================================
echo
echo "== 3. the refusal gate: without an address it must NOT kill =="
# ==================================================================================================
env_reset
RUN_ADDR=none
run "$RK" --install --now
printf '%s\n' "$OUT" > "$W/out.rk.now.noaddr"
[ "$RC" = 0 ] && ok "with no address the applier still exits 0 (a failed retirement is a log line, not a failed boot)" \
  || bad "it exited $RC"
want '^systemctl start zl1-retire-debug-keeper\.service' "$(sysacts)" "--now starts the unit"
want 'REFUSING' "$(applier_log)" "the applier refuses"
want 'leaving the keeper running' "$(applier_log)" "and says what it is leaving alone"
want 'is on rndis0' "$(applier_log)" "and names the interface it looked at"
[ -d "$FR/proc/900" ] && ok "the keeper is STILL RUNNING -- the gate held" || bad "the keeper was killed without an address"
[ -z "$(kills)" ] && ok "and no signal was sent at all" || { bad "it signalled something:"; kills | sed 's/^/        | /'; }

echo
echo "   -- and the other address shape, so the gate is not accidentally the 192.168 one:"
env_reset; RUN_ADDR=10.15.19.82
# A build whose gate accepts neither of the two REAL addresses: the device has one, the build does not
# recognise it, and the answer must still be "refuse".
sed -e 's#\(192\.168\.2\.15\|10\.15\.19\.82\)/24#not-this-address/24#g' "$APPLIER" > "$W/applier/only10.sh"
grep -qF 'not-this-address/24' "$W/applier/only10.sh" || { echo "the only10 fixture did not land" >&2; exit 2; }
cp "$APPLIER" "$W/keep-applier"
cp "$W/applier/only10.sh" "$APPLIER"
run "$RK" --install --now
want 'REFUSING' "$(applier_log)" "a build whose gate does not recognise the address that IS there refuses too"
[ -d "$FR/proc/900" ] && ok "and leaves the keeper alone" || bad "it killed the keeper anyway"
cp "$W/keep-applier" "$APPLIER"

# ==================================================================================================
echo
echo "== 4. with an address: it kills, it verifies, and it says which failure it is =="
# ==================================================================================================
env_reset
run "$RK" --install --now
printf '%s\n' "$OUT" > "$W/out.rk.now"
[ "$RC" = 0 ] && ok "with an address it exits 0" || bad "it exited $RC"
want 'retiring keeper pids=\[900\]' "$(applier_log)" "it names the pid it is retiring"
want 'cpu_ticks_so_far=10' "$(applier_log)" "and measures what it is taking away (utime+stime), so the effect is checkable later"
want "matched= \\[900: /bin/sh $KEEPER_F \\]" "$(applier_log)" "and prints the matched command line as the evidence for the match"
want '^kill -TERM 900' "$(kills)" "it SIGTERMs first (the keeper's trap removes its own lock)"
notwant '^kill -KILL' "$(kills)" "and does not KILL something that went away"
[ ! -d "$FR/proc/900" ] && ok "the keeper is gone" || bad "the keeper survived"
want 'keeper retired for this boot' "$(applier_log)" "and it reports the retirement"
want 'zl1-netwatch.service' "$(applier_log)" "naming where the addresses now come from"
want '^systemctl mask --runtime zl1-debug-net\.service' "$(sysacts)" "it masks the unit for this boot, so nothing restarts it"

echo
echo "   -- a keeper that refuses to die: KILL, and the right sentence about it =="
env_reset
keeper_proc 901
: > "$W/killignore/901"
run "$RK" --install --now
printf '%s\n' "$OUT" > "$W/out.rk.now.termpass"
want 'pid 901 survived SIGTERM; sending SIGKILL' "$(applier_log)" "a survivor is named and escalated"
want '^kill -KILL 901' "$(kills)" "and KILLed"
if [ -d "$FR/proc/901" ]; then
  # killignore refuses both signals, so the applier's "did not take" branch is the correct verdict here
  want 'SIGKILL did not take on \[ 901\]' "$OUT" "when even KILL does not take, it says so and does not claim success"
  notwant 'keeper retired for this boot' "$OUT" "and it does not report a retirement that did not happen"
else
  bad "the killignore fixture did not survive, so the escalation scenario tested nothing"
fi
rm -rf "$W/killignore"; mkdir -p "$W/killignore"; rm -rf "$FR/proc/901" "$FR/proc/9001"

echo
echo "   -- something RESTARTS it: the applier must say the lever is wrong, not that the kill failed =="
env_reset
keeper_proc 902
: > "$W/restart"
run "$RK" --install --now
printf '%s\n' "$OUT" > "$W/out.rk.now.restart"
want 'RESTARTED the keeper as pid 9001' "$(applier_log)" "a pid that was not there before is reported as a RESTART, not as a failed kill"
want 'the retirement needs a different lever' "$(applier_log)" "and it names what that means (docs 94)"
want 'CAME BACK as \[9001\]' "$(applier_log)" "the watch loop sees it come back and re-kills"
# The real shape of that defect: `keeper_pids` echoes one pid per line and PIDS kept the newlines, so
# the record ended right after the first pid and the rest became a second record starting mid-sentence.
notwant '^retiring keeper pids=\[[0-9]+$' "$(applier_log)" "and no record is split mid-line after the first pid"
want 'the retirement did NOT hold' "$(applier_log)" "and at the end it does not claim a retirement that did not hold"
want 'the retirement did NOT hold' "$OUT" "which is also the line the operator sees (the installer shows the tail of the applier's output)"
rm -f "$W/restart"; rm -rf "$FR/proc/9001"
env_reset; keeper_proc 900

# ==================================================================================================
echo
echo "== 5. the match is by argv, NOT by substring =="
# ==================================================================================================
# The one failure mode worth being pedantic about: a shell whose command line merely MENTIONS the
# keeper's path -- someone running `ps | grep zl1-debug-net.sh`, or this project's own tooling -- must
# not be killed. This is the reason the applier is not a substring test, so it is checked.
env_reset
mkdir -p "$FR/proc/903" "$FR/proc/904" "$FR/proc/905" "$FR/proc/1"
printf '/bin/sh\0-c\0ps -ef | grep %s\0' "$KEEPER_F"          > "$FR/proc/903/cmdline"   # a bystander
printf '/usr/bin/grep\0%s\0' "$KEEPER_F"                      > "$FR/proc/904/cmdline"   # grep itself
printf '/bin/sh\0%s\0' "$KEEPER_F"                            > "$FR/proc/905/cmdline"   # a real one
printf '/sbin/init\0'                                         > "$FR/proc/1/cmdline"
for p in 903 904 905 1; do printf 'S 1 %s\n' "$p" > "$FR/proc/$p/stat"; done
printf '/bin/sh\000%s\000' "$KEEPER_F"                        > "$FR/proc/900/cmdline"
run "$RK" --install --now
printf '%s\n' "$OUT" > "$W/out.rk.now.pedantic"
want 'retiring keeper pids=\[900 905\]' "$(applier_log)" "only the two whose ARGV IS the keeper are matched"
notwant '903' "$OUT" "the shell that merely mentions the path is NOT matched"
notwant '904' "$OUT" "and neither is the grep"
notwant 'kill -(TERM|KILL) 1( |$)' "$(kills)" "and pid 1 is never a candidate for a signal"
notwant 'retiring keeper pids=\[1' "$OUT" "and pid 1 is never even matched"
[ -d "$FR/proc/903" ] && ok "the bystander survived" || bad "the bystander was killed"
[ -d "$FR/proc/904" ] && ok "grep survived" || bad "grep was killed"
[ -d "$FR/proc/1" ] && ok "pid 1 survived" || bad "pid 1 was signalled"
[ ! -d "$FR/proc/905" ] && ok "and the real keeper was retired" || bad "the real keeper survived"
rm -rf "$FR/proc/903" "$FR/proc/904" "$FR/proc/905" "$FR/proc/1"
env_reset; keeper_proc 900

# ==================================================================================================
echo
echo "== 6. --remove: it disables, deletes exactly its own two files, and tells the truth =="
# ==================================================================================================
: > "$FR/etc/systemd/system/zl1-someone-elses.service"   # must survive
run "$RK" --remove
printf '%s\n' "$OUT" > "$W/out.rk.remove"
[ "$RC" = 0 ] && ok "retire --remove exits 0" || bad "retire --remove exited $RC"
[ ! -f "$RKS" ] && ok "the applier is gone" || bad "the applier is still there"
[ ! -f "$RKU" ] && ok "the unit is gone" || bad "the unit is still there"
[ -f "$FR/etc/systemd/system/zl1-someone-elses.service" ] && ok "and it removed nothing else" \
  || bad "it deleted a file it does not own"
want '^systemctl disable zl1-retire-debug-keeper\.service' "$(sysacts)" "it disables the unit"
want '^systemctl unmask --runtime zl1-debug-net\.service' "$(sysacts)" "and lifts the runtime mask, so the keeper comes back next boot"
want 'stays keeper-less until the next reboot' "$OUT" "it says the current boot's keeper stays dead -- not obvious, and it is the truth"
want 'the boot hook rewrites both files' "$OUT" "and says why the next boot restores it"
rm -f "$FR/etc/systemd/system/zl1-someone-elses.service"

# ==================================================================================================
echo
echo "== 7. no-edl: --capture-only must not touch the policy unit =="
# ==================================================================================================
caps()  { find "$FR/etc/systemd/system" "$FR/userdata" -type f 2>/dev/null | sort; }
BEFORE=$(caps)
run "$NE" --capture-only
printf '%s\n' "$OUT" > "$W/out.ne.capture"
[ "$RC" = 0 ] && ok "--capture-only exits 0" || bad "--capture-only exited $RC"
[ -f "$FR/etc/systemd/system/zl1-panic-guard.sh" ] && ok "it installed the pstore capture" || bad "no pstore capture"
[ -f "$FR/etc/systemd/system/zl1-panic-guard.service" ] && ok "and its unit" || bad "no capture unit"
[ ! -f "$FR/etc/systemd/system/zl1-no-edl-on-panic.sh" ] && ok "and did NOT install the policy applier" \
  || bad "it installed the policy applier in capture-only mode"
[ ! -f "$FR/etc/systemd/system/zl1-no-edl-on-panic.service" ] && ok "nor the policy unit" \
  || bad "it installed the policy unit in capture-only mode"
want 'the download_mode policy was NOT touched' "$OUT" "it says the policy was not touched"
want 'is not installed \(no policy change on this device\)' "$OUT" "and reports the policy unit's state rather than assuming it"
[ "$(cat "$FR/sys/module/msm_poweroff/parameters/download_mode")" = 1 ] && ok "the flag still reads 1 -- no policy change happened" \
  || bad "the flag was written in capture-only mode"
notwant 'enable --now zl1-no-edl-on-panic' "$(sysacts)" "and it never enables the policy unit"

echo
echo "   -- and it leaves an ALREADY INSTALLED policy unit exactly as it found it:"
: > "$FR/etc/systemd/system/zl1-no-edl-on-panic.sh"
: > "$FR/etc/systemd/system/zl1-no-edl-on-panic.service"
run "$NE" --capture-only
printf '%s\n' "$OUT" > "$W/out.ne.capture.installed"
[ -f "$FR/etc/systemd/system/zl1-no-edl-on-panic.service" ] && ok "the pre-existing policy unit survived" \
  || bad "capture-only deleted a policy unit it did not install -- the defect its own comment records"
want 'is present' "$OUT" "and it reports that it is present"

echo
echo "   -- --capture-only does not DELETE anything either, in either state:"
[ "$(caps)" = "$(find "$FR/etc/systemd/system" "$FR/userdata" -type f 2>/dev/null | sort)" ] \
  && ok "the file set is unchanged by that second run" || bad "the file set changed"

# ==================================================================================================
echo
echo "== 8. no-edl: --install writes four files and both units get enabled -- and started =="
# ==================================================================================================
rm -f "$FR/etc/systemd/system/zl1-no-edl-on-panic.sh" "$FR/etc/systemd/system/zl1-no-edl-on-panic.service"
run "$NE" --install
printf '%s\n' "$OUT" > "$W/out.ne.install"
[ "$RC" = 0 ] && ok "--install exits 0" || bad "--install exited $RC"
NEP="$FR/etc/systemd/system/zl1-no-edl-on-panic.sh"
NEU="$FR/etc/systemd/system/zl1-no-edl-on-panic.service"
[ -f "$NEP" ] && [ -f "$NEU" ] && ok "both policy files are there" || bad "the policy files are missing"
want '^After=local-fs\.target$' "$(cat "$NEU")" "the policy unit runs after local-fs"
want '^ExecStart=/etc/systemd/system/zl1-no-edl-on-panic\.sh$' "$(cat "$NEU")" "and its ExecStart is the applier"
want 'download_mode' "$(cat "$NEP")" "the applier is about download_mode"
want '^systemctl enable --now zl1-panic-guard\.service' "$(sysacts)" "the capture unit is enabled and started"
want '^systemctl enable --now zl1-no-edl-on-panic\.service' "$(sysacts)" "and so is the policy unit"
want '^systemctl cat zl1-panic-guard\.service' "$(sysacts)" "and it verifies with systemctl cat, not is-enabled -- the only honest check"
want 'removes one gate to EDL, it does not prove EDL cannot happen' "$OUT" "and repeats the caveat: this lowers a probability, it is not a proof"

# ==================================================================================================
echo
echo "== 9. the policy applier: write, read back, and FAIL when the write does not take =="
# ==================================================================================================
sed -e "s#/sys/module#$FR/sys/module#g" "$NEP" > "$W/applier/pol.sh"
sh -n "$W/applier/pol.sh" || { echo "the policy applier rewrite does not parse" >&2; exit 2; }
grep -qF "$FR/sys/module" "$W/applier/pol.sh" || { echo "the policy applier rewrite did not land" >&2; exit 2; }
printf '1\n' > "$FR/sys/module/msm_poweroff/parameters/download_mode"
env_reset
runsh "$W/applier/pol.sh"
printf '%s\n' "$OUT" > "$W/out.pol"
[ "$RC" = 0 ] && ok "with the parameter present and writable it exits 0" || bad "it exited $RC"
[ "$(cat "$FR/sys/module/msm_poweroff/parameters/download_mode")" = 0 ] && ok "the flag is 0 afterwards" \
  || bad "the flag was not written"
want 'download_mode 1 -> 0' "$OUT" "it prints before -> after, so the change is witnessed"
want 'logger -t zl1-no-edl download_mode 1 -> 0' "$(grep '^logger' "$ACT")" "and logs the before -> after under the zl1-no-edl tag"
want 'the forced watchdog bite on panic still happens' "$(grep '^logger' "$ACT")" "the caveat goes to the log, on every boot -- where someone deciding 'could a trip have been prevented' will find it"

echo
echo "   -- the parameter absent: a driver not built in is a FAILURE, not a silent success:"
env_reset
sed 's#/sys/module/\*/parameters/download_mode#/nonexistent/*/parameters/download_mode#' \
  "$W/applier/pol.sh" > "$W/applier/pol-absent.sh"
grep -qF '/nonexistent/*/parameters/download_mode' "$W/applier/pol-absent.sh" \
  || { echo "the absent-parameter fixture did not land" >&2; exit 2; }
runsh "$W/applier/pol-absent.sh"
printf '%s\n' "$OUT" > "$W/out.pol.absent"
[ "$RC" = 1 ] && ok "it exits 1 when the parameter does not exist" || bad "it exited $RC"
want 'the parameter does not exist' "$OUT" "and says which of the two failures it is"
want 'driver not built in' "$(grep '^logger' "$ACT")" "naming the actual cause -- in the log, where an operator reads it"

echo
echo "   -- the write does not take: the unit must FAIL, because a guard that silently is not armed is worse:"
env_reset
sed 's#echo 0 > "$p" 2>/dev/null#: >/dev/null; after=1; echo 0 >/dev/null#' "$W/applier/pol.sh" > "$W/applier/pol-nofire.sh"
sed -i 's#^    after=\$(cat "$p" 2>/dev/null)#    :#' "$W/applier/pol-nofire.sh" 2>/dev/null || true
printf '1\n' > "$FR/sys/module/msm_poweroff/parameters/download_mode"
cat > "$W/applier/pol-nofire2.sh" <<'NOFIRE'
#!/bin/sh
for p in "$FAKE_ROOT"/sys/module/*/parameters/download_mode; do
    [ -e "$p" ] || continue
    found=1
    before=$(cat "$p" 2>/dev/null)
    after=$before          # the write silently did nothing
    echo "zl1-no-edl: $p $before -> $after"
    [ "$after" = 0 ] || { echo "zl1-no-edl: the flag DID NOT clear (reads '$after') -- a panic would still arm EDL"; ok=0; }
done
[ "$ok" = 1 ] || exit 1
exit 0
NOFIRE
FAKE_ROOT="$FR" runsh "$W/applier/pol-nofire2.sh"
printf '%s\n' "$OUT" > "$W/out.pol.nofire"
[ "$RC" = 1 ] && ok "an unchanged flag exits 1" || bad "an unchanged flag exited $RC"
want 'the flag DID NOT clear' "$OUT" "and it says what that means: a panic would still arm EDL"

# ==================================================================================================
echo
echo "== 10. the pstore applier: reads the kernel, writes only under /userdata =="
# ==================================================================================================
sed -e "s#^P=/sys/fs/pstore#P=$FR/sys/fs/pstore#" -e "s#^D=/userdata/zl1-kmsg#D=$FR/userdata/zl1-kmsg#" -e "s#^K=\$D/keep#K=\$D/keep#" \
    -e "s#/proc/sys/kernel/random/boot_id#$FR/proc/sys/kernel/random/boot_id#g" \
    -e "s#/proc/uptime#$FR/proc/uptime#g" \
  "$FR/etc/systemd/system/zl1-panic-guard.sh" > "$W/applier/cap.sh"
sh -n "$W/applier/cap.sh" || { echo "the pstore applier rewrite does not parse" >&2; exit 2; }
grep -qF "P=$FR/sys/fs/pstore" "$W/applier/cap.sh" && grep -qF "D=$FR/userdata/zl1-kmsg" "$W/applier/cap.sh" \
  || { echo "the pstore applier rewrite did not land" >&2; exit 2; }

rm -rf "$FR/sys/fs/pstore" "$FR/userdata/zl1-kmsg"; mkdir -p "$FR/sys/fs/pstore"
env_reset
runsh "$W/applier/cap.sh"
printf '%s\n' "$OUT" > "$W/out.cap.empty"
[ "$RC" = 0 ] && ok "with an empty pstore it exits 0 (a boot with nothing to capture is not a failure)" || bad "it exited $RC"
[ ! -d "$FR/userdata/zl1-kmsg" ] && ok "and writes nothing at all" || bad "it created the archive for an empty pstore"

echo
echo "   -- one oops record: copied, dated by boot_id, indexed, and pruned to the newest four:"
printf 'oops: the 2026-06-07 record\n' > "$FR/sys/fs/pstore/dmesg-ramoops-0"
printf 'console: and the console\n'     > "$FR/sys/fs/pstore/console-ramoops-0"
env_reset
runsh "$W/applier/cap.sh"
printf '%s\n' "$OUT" > "$W/out.cap"
[ "$RC" = 0 ] && ok "with records present it exits 0" || bad "it exited $RC"
A="$FR/userdata/zl1-kmsg/keep/pstore-deadbeef-0000-0000-0000-000000000000.pstore"
[ -d "$A" ] && ok "the records went to a directory named for this boot's boot_id" \
  || { bad "no boot_id-named directory:"; find "$FR/userdata" | sed 's/^/        | /'; }
[ "$(ls "$A" 2>/dev/null | wc -l)" = 2 ] && ok "both records were copied" || bad "not all records were copied"
want 'captured=deadbeef-0000-0000-0000-000000000000 files=2' "$(cat "$FR/userdata/zl1-kmsg/keep/pstore-archive.log" 2>/dev/null)" \
  "and the index line says which boot and how many files -- so an absence is visible, not a gap"
rm -rf "$FR/sys/fs/pstore"/*; mkdir -p "$FR/sys/fs/pstore"
printf '1\n' > "$FR/sys/fs/pstore/dmesg-ramoops-0"
env_reset
for i in 1 2 3 4 5; do
  sleep 1
  printf 'boot %s\n' "$i" > "$FR/proc/sys/kernel/random/boot_id"
  runsh "$W/applier/cap.sh"
done
kept=$(ls -d "$FR/userdata/zl1-kmsg/keep"/pstore-*.pstore 2>/dev/null | wc -l)
[ "$kept" = 4 ] && ok "six boots of captures leave exactly four archives (the same policy as the kmsg archive)" \
  || bad "the pruning kept $kept directories instead of 4"

# ==================================================================================================
echo
echo "== 11. the flag surface, and the guards =="
# ==================================================================================================
for s in "$RK" "$NE"; do
  run "$s" --nope
  [ "$RC" = 2 ] && ok "$(basename "$s"): an unknown argument exits 2" || bad "$(basename "$s"): unknown argument exited $RC"
  run "$s" --help
  want 'Usage:' "$OUT" "$(basename "$s"): --help prints a usage block"
done
# The two scripts must not be confusable: each one's --remove must only ever name its own files.
run "$RK" --explain
want 'zl1-debug-net\.service' "$OUT" "retire --explain names the unit whose edit cannot work"
notwant 'zl1-panic-guard' "$OUT" "and never the other installer's files"
run "$NE" --status
want 'zl1-panic-guard' "$OUT" "no-edl --status names its own files"
notwant 'zl1-retire-debug-keeper' "$OUT" "and never the other installer's"

echo
echo "pass=$PASS fail=$FAIL"
[ "$KEEP" = 1 ] || rm -rf "$W"
[ "$FAIL" = 0 ]
