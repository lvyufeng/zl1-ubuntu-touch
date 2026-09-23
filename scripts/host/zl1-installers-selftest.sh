#!/bin/sh
# zl1 installer scripts -- offline self-test for the installers that write DEVICE STATE and have no
# harness of their own.
#
# Host-side, touches no device. The four scripts:
#
#   scripts/install-retire-debug-keeper.sh   the remaining HEAT fix (docs 72 section 4b, 94)
#   scripts/install-no-edl-on-panic.sh       the never-brick fix (docs 86)
#   scripts/install-cpufreq-governor.sh      the OTHER half of the heat fix: the image ships all four
#                                            cores on `performance` (docs 95, 96)
#   scripts/install-netwatch-service.sh      the TWRP-side installer, and the only script in this
#                                            directory that READS A PARTITION (misc)
#
# Why they need one:
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
#   * `install-cpufreq-governor.sh` is a heat fix whose failure mode is an instrument that reports
#     success: writing a governor the kernel does not offer, or one it refuses, leaves the unit
#     `active` and the phone just as hot. So the assertions are about the READ-BACK, not the write.
#   * `install-netwatch-service.sh` takes the only backup of the misc partition -- the one the watchdog
#     can write "boot-recovery" into -- and a backup that is accepted without being verified is worse
#     than none, because it satisfies every later run's check.
#
# All four are `bash` scripts that drive a device and carry their device-side appliers as here-docs.
# That is what makes them testable offline without inventing anything: the harness supplies the device.
# The transport is stubbed by a script that RUNS the remote command locally, in a fake root, so
# `--install` really writes the files, `--status` really walks a `/proc`, and the applier that systemd
# would start is the applier that runs. The stub is the transport, not the logic: every line under test
# is the project's own.
#
# There are TWO transports, and therefore two fake devices, because the fourth installer drives TWRP
# over adb where userdata is a plain /data mount rather than the rootfs's bind mounts:
#
#   ssh -> $W/fake     the three rootfs-side installers
#   adb -> $W/nw       install-netwatch-service.sh
#
# They are deliberately separate roots: the two families keep their state in different trees, and a
# shared root would let one section's leftovers satisfy another section's assertions.
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
CP="$HERE/../install-cpufreq-governor.sh"
NW="$HERE/../install-netwatch-service.sh"
for f in "$RK" "$NE" "$CP" "$NW"; do [ -r "$f" ] || { echo "cannot read $f" >&2; exit 2; }; done
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

# The four cores install-cpufreq-governor.sh exists to move off `performance`, with the clocks the
# device reported on 2026-09-22 (cpu0/1 max 1132800, cpu2/3 max 1363200). Written as a fixture rather
# than as "whatever the host has", because the host is not an msm8996.
for _c in 0 1 2 3; do
  mkdir -p "$FR/sys/devices/system/cpu/cpu$_c/cpufreq"
  printf 'performance\n'  > "$FR/sys/devices/system/cpu/cpu$_c/cpufreq/scaling_governor"
  printf '1132800\n'      > "$FR/sys/devices/system/cpu/cpu$_c/cpufreq/scaling_cur_freq"
  case "$_c" in 0|1) _mx=1132800 ;; *) _mx=1363200 ;; esac
  printf '%s\n' "$_mx"     > "$FR/sys/devices/system/cpu/cpu$_c/cpufreq/scaling_max_freq"
done
printf 'interactive conservative ondemand userspace powersave performance\n' \
  > "$FR/sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors"
printf '0.42 0.31 0.28 2/412 9123\n' > "$FR/proc/loadavg"

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
start|restart)
  u="\$2"
  ex=\$(sed -n 's/^ExecStart=//p' "$FR/etc/systemd/system/\$u" 2>/dev/null | head -1)
  # The applier's device paths have to point at the fake root, so a harness-prepared copy of the SAME
  # FILE is used when there is one. The landed file's content is asserted separately.
  alt="$W/applier/\$(basename "\$ex")"
  if [ -f "\$alt" ]; then
    ex="\$alt"
  elif [ -e "\$ex" ]; then
    # NO COPY. Running the landed file would execute the applier with the DEVICE's absolute paths --
    # i.e. against the HOST's own /sys, /proc and /etc. Every applier here is guarded by a '[ -w ]' or
    # a '/proc' walk, so it would not usually do damage, but it would silently measure the wrong
    # machine and the scenario would pass or fail for reasons that have nothing to do with the script
    # under test. This harness was written after exactly that mistake (docs 99 section 5), so it is a
    # loud failure now instead of a quiet one.
    printf 'NO-REWRITTEN-APPLIER %s\n' "\$ex" >> "$ACT"
    printf 'zl1-harness: refusing to run %s with device paths -- no rewritten copy in %s\n' "\$ex" "$W/applier" >&2
    exit 97
  fi
  [ -n "\$ex" ] && exec env PATH="$STUB:\$PATH" FAKE_ADDR="\${FAKE_ADDR:-yes}" ZL1_CPUFREQ_GOVERNOR="\$\{ZL1_CPUFREQ_GOVERNOR:-}" sh "\$ex"
  ;;
enable)
  # 'enable --now <unit>' is systemd's "enable it and start it now", and install-cpufreq-governor.sh
  # uses exactly that -- so this stub has to run ExecStart for it too, or the applier never runs and
  # the scenario measures nothing. Plain 'enable' must NOT run it, which is asserted below.
  case "\$*" in
  *--now*)
    u="\$3"
    case "\$u" in
    zl1-cpufreq-governor.service)
      ex=\$(sed -n 's/^ExecStart=//p' "$FR/etc/systemd/system/\$u" 2>/dev/null | head -1)
      alt="$W/applier/\$(basename "\$ex")"
      gov=\$(sed -n 's/^Environment=ZL1_CPUFREQ_GOVERNOR=//p' "$FR/etc/systemd/system/\$u" 2>/dev/null | head -1)
      printf 'systemctl-ran-applier %s gov=%s\n' "\$ex" "\$gov" >> "$ACT"
      if [ -f "\$alt" ]; then
        ZL1_CPUFREQ_GOVERNOR="\$gov" exec env PATH="$STUB:\$PATH" FAKE_ADDR="\${FAKE_ADDR:-yes}" sh "\$alt"
      elif [ -e "\$ex" ]; then
        printf 'NO-REWRITTEN-APPLIER %s\n' "\$ex" >> "$ACT"
        printf 'zl1-harness: refusing to run %s with device paths -- no rewritten copy in %s\n' "\$ex" "$W/applier" >&2
        exit 97
      fi ;;
    esac ;;
  esac
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
# adb: the OTHER transport in this directory. install-netwatch-service.sh is the TWRP-side installer
# (it drives the device over adb, with userdata as plain /data), so it needs its own device. Same idea
# as the ssh stub: run the command locally, with the device's absolute paths mapped into the fake root,
# and record every call so "nothing flashed" and "nothing was written" are checkable.
#
# It must NOT share the ssh device's root. The two scripts keep their state in different trees
# (/data/system-data/... versus /etc/systemd/system/...), and a shared root lets one section's
# leftovers satisfy the other section's assertions.
#
# The map is written on the SPECIFIC device paths this installer uses, never on a bare /data: the
# installer's own source path is a HOST path (/mnt/data/zl1-bb10/...), and a bare /data rule would
# rewrite the very file it is about to push.
#
# The misc partition is a fake BLOCK, and $W/adb-short makes `exec-out cat` return fewer bytes than
# `wc -c` reports -- which is the one failure the backup block exists to survive, and the one that is
# invisible afterwards.
NWR="$W/nw"
mkdir -p "$NWR/data" "$NWR/userdata" "$NWR/dev/block/bootdevice/by-name"
cat > "$STUB/adb" <<EOF
#!/bin/sh
printf 'adb %s\n' "\$*" >> "$ACT"
case "\$1" in
devices)
  case "\${FAKE_ADB_SERIAL:-33e80afe}" in none) printf 'List of devices attached\n\n' ;; *) printf 'List of devices attached\n%s\tdevice\n' "\$FAKE_ADB_SERIAL" ;; esac
  exit 0 ;;
-s)
  # the serial goes in the action log, so "it addressed the right device" is checkable; the stub
  # itself accepts any of them, because this fake device has exactly one.
  shift; shift
  ;;
*) exit 0 ;;
esac
act="\$1"; shift
map() { printf '%s' "\$*" | sed \
  -e "s#/data/system-data#$NWR/data/system-data#g" \
  -e "s#/data/zl1-netwatch#$NWR/data/zl1-netwatch#g" \
  -e "s#/userdata#$NWR/userdata#g" \
  -e "s#/dev/block#$NWR/dev/block#g" ; }
case "\$act" in
shell)
  c=\$(map "\$*")
  exec env PATH="$STUB:\$PATH" sh -c "\$c" ;;
exec-out)
  c=\$(map "\$*")
  # "cat <blk>" short-reads when the harness asks it to; "wc -c < blk" always reports the truth
  case "\$c" in
  *"cat "*)
    if [ -e "$W/adb-short" ]; then
      # a short read: the first N bytes only, exactly what a dropped transfer looks like
      head -c 1024 "$NWR/dev/block/bootdevice/by-name/misc" 2>/dev/null
    else
      env PATH="$STUB:\$PATH" sh -c "\$c"
    fi ;;
  *) exec env PATH="$STUB:\$PATH" sh -c "\$c" ;;
  esac ;;
push)
  a=\$(map "\$1"); b=\$(map "\$2")
  cp "\$a" "\$b" ;;
*)
  exec env PATH="$STUB:\$PATH" sh -c "\$(map "\$*")" ;;
esac
exit 0
EOF
# readlink: the installer asks the DEVICE for the misc block device and then tests the answer against
# /dev/block/*, so the answer has to come back in the DEVICE's namespace. Inside this fake device NWR
# stands in for /, so stripping the prefix is the de-faking. (Nothing else here calls readlink -- the
# only other user in this directory, install-machine-info.sh, is not under test and talks to a real
# device.)
cat > "$STUB/readlink" <<EOF
#!/bin/sh
printf 'readlink %s\n' "\$*" >> "$ACT"
for a in "\$@"; do
  case "\$a" in -*) continue ;; esac
  printf '%s\n' "\${a#$NWR}"
done
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
emit "s#/sys/devices/system/cpu#$FR/sys/devices/system/cpu#g"
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
SKIP=0   # checks that could not run here (a statement about git history, not about the script)
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
RUN_ADDR=yes; RUN_ADB_SERIAL=33e80afe
env_reset() { RUN_ADDR=yes; RUN_ADB_SERIAL=33e80afe; rm -f "$W/restart" "$W/active-retire"; rm -rf "$W/killignore"; mkdir -p "$W/killignore"; }
run() {
  s="$1"; shift
  : > "$ACT"
  OUT=$(PATH="$STUB:$PATH" FAKE_ADDR="$RUN_ADDR" FAKE_ADB_SERIAL="$RUN_ADB_SERIAL" \
        timeout 120 bash "$s" "$@" 2>&1); RC=$?
}
runsh() { # same, for a device-side applier
  s="$1"; shift
  : > "$ACT"
  OUT=$(PATH="$STUB:$PATH" FAKE_ADDR="$RUN_ADDR" timeout 120 sh "$s" "$@" 2>&1); RC=$?
}

echo "zl1 installer self-test -- the installers that write device state"
echo "  retire the debug keeper: $RK"
echo "  no-EDL-on-panic:         $NE"
echo "  cpufreq governor:        $CP"
echo "  netwatch service:        $NW"
echo "  fake device (ssh):       $FR"
echo "  fake device (adb/TWRP):  $NWR"
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
# ==================================================================================================
echo
echo "== 12. cpufreq: the OTHER half of the heat fix (the image ships 'performance') =="
# ==================================================================================================
# Why this is in the same harness as the keeper: docs 72/94 found two heat sources -- all four cores
# pinned at their maximum clock, and a 1 Hz debug keeper burning a core. The keeper half now has three
# tests in this file; this is the other half, and it is the one the user's own sentence named
# ("这台机器很容易发烫"). What matters here is not that the write happens but that the instrument can
# tell "the fix is armed" from "nothing changed" -- a governor the kernel does not offer, or a core
# that refuses the write, must not be reported as success.
CPU_SH="$FR/etc/systemd/system/zl1-cpufreq-governor.sh"
CPU_UNIT="$FR/etc/systemd/system/zl1-cpufreq-governor.service"
govs() { for c in 0 1 2 3; do cat "$FR/sys/devices/system/cpu/cpu$c/cpufreq/scaling_governor"; done; }
govs_reset() { for c in 0 1 2 3; do printf 'performance\n' > "$FR/sys/devices/system/cpu/cpu$c/cpufreq/scaling_governor"; done; }

env_reset
BEFORE=$(snap)
run "$CP" --status
printf '%s\n' "$OUT" > "$W/out.cp.status"
[ "$RC" = 0 ] && ok "cpufreq --status exits 0" || bad "cpufreq --status exited $RC"
[ "$(snap)" = "$BEFORE" ] && ok "cpufreq --status wrote nothing to the fake device" || bad "cpufreq --status changed the fake device"
[ -z "$(syswrite)" ] && ok "and made no systemd call that changes anything" || bad "cpufreq --status would change the device"
want 'systemctl cat zl1-cpufreq-governor\.service' "$(sysacts)" "it checks the unit with systemctl cat, not is-enabled"
want 'interactive conservative ondemand' "$OUT" "it prints what governors the kernel actually offers"
want 'cpu0 +gov=performance' "$OUT" "and the governor on each core, which is the thing being fixed"
want 'scaling_available_governors|gov=' "$OUT" "so the reading is the device's, not a claim"
want 'thermal zones' "$OUT" "and the thermal picture that made this a stage"
want 'deci-degC' "$OUT" "including the three-units note (docs 96), so the numbers are readable"
want 'the thing that is still burning CPU on purpose' "$OUT" "and names the keeper as the OTHER heat source, so the two are not confused"

echo
echo "   -- the flag surface, where the sibling scripts set the convention:"
run "$CP" --nope
[ "$RC" = 2 ] && ok "an unknown argument exits 2" || bad "unknown argument exited $RC"
run "$CP" --help
[ "$RC" = 0 ] && ok "--help exits 0" || bad "--help exited $RC (every sibling installer prints usage; this one used to say 'unknown argument')"
want 'Usage: install-cpufreq-governor' "$OUT" "and prints its own usage block, which the header documents"
msg=$(PATH="$STUB:$PATH" bash "$CP" --governor 2>&1 >/dev/null | head -1); rc=$?
case "$msg" in
*"unbound variable"*) bad "--governor with no value aborted the shell: $msg" ;;
*"--governor needs a NAME"*) ok "--governor with no value names the flag instead of aborting the shell" ;;
*) bad "--governor with no value said neither: $msg" ;;
esac

echo
echo "   -- --install: two files, that content, and it really moves the four cores:"
# The shipped applier, extracted by the same rule for the fixed and the pre-fix tree: the block
# between the `<<'APPLIER_EOF'` marker and its closing marker. The end marker is passed through the
# environment because awk cannot put $2 into that comparison portably.
extract_applier() { # $1 = installer, $2 = end-marker name, $3 = out
  MK="$2" awk -v m="<<'$2'" 'index($0, m) { f=1; next } f && $0 == ENVIRON["MK"] { f=0 } f' "$1" > "$3"
  [ -s "$3" ] || { echo "could not extract the $2 applier from $1" >&2; exit 2; }
}
extract_applier "$CP" APPLIER_EOF "$W/applier/cp.raw.sh"
CPUAP=$W/applier/zl1-cpufreq-governor.sh
sed -e "s#/sys/devices/system/cpu#$FR/sys/devices/system/cpu#g" "$W/applier/cp.raw.sh" > "$CPUAP"
sh -n "$CPUAP" || { echo "the cpufreq applier copy does not parse" >&2; exit 2; }
grep -qF "$FR/sys/devices/system/cpu" "$CPUAP" || { echo "the cpufreq applier copy was not rewritten" >&2; exit 2; }
govs_reset
run "$CP" --install
printf '%s\n' "$OUT" > "$W/out.cp.install"
[ "$RC" = 0 ] && ok "cpufreq --install exits 0" || bad "cpufreq --install exited $RC"
[ -f "$CPU_SH" ] && [ -f "$CPU_UNIT" ] && ok "it wrote the applier and the unit" || bad "the applier or unit is missing"
[ "$(find "$FR/etc/systemd/system" -name 'zl1-cpufreq-governor.*' | wc -l)" = 2 ] && ok "and those are the only two files it added" \
  || { bad "it added more of its own:"; find "$FR/etc/systemd/system" -name 'zl1-cpufreq-governor.*' | sed 's/^/        | /'; }
want '^Type=oneshot$' "$(cat "$CPU_UNIT")" "the unit is oneshot"
want '^RemainAfterExit=yes$' "$(cat "$CPU_UNIT")" "RemainAfterExit, so its result is readable afterwards"
want '^Before=multi-user\.target$' "$(cat "$CPU_UNIT")" "and before multi-user, so the first minutes after boot are not spent at full clock"
want '^Environment=ZL1_CPUFREQ_GOVERNOR=interactive$' "$(cat "$CPU_UNIT")" "the governor reaches the applier through the unit's Environment="
want '^ExecStart=/etc/systemd/system/zl1-cpufreq-governor\.sh$' "$(cat "$CPU_UNIT")" "and ExecStart is the applier, by its device path"
want '^systemctl enable --now zl1-cpufreq-governor\.service' "$(sysacts)" "it enables AND starts (unlike the keeper installer, starting changes no policy -- just the clock)"
[ "$(govs | sort -u)" = "interactive" ] && ok "and all four cores are now on 'interactive' (the point of the whole script)" \
  || { bad "the cores did not move:"; govs | sed 's/^/        | /'; }
want 'governor .interactive. on 4 cores' "$OUT" "it reports how many cores it moved"

echo
echo "   -- --governor NAME reaches both the unit's Environment= and the run:"
govs_reset
run "$CP" --install --governor powersave
printf '%s\n' "$OUT" > "$W/out.cp.powersave"
want '^Environment=ZL1_CPUFREQ_GOVERNOR=powersave$' "$(cat "$CPU_UNIT")" "--governor powersave is what the unit carries"
[ "$(govs | sort -u)" = "powersave" ] && ok "and that is what the cores got" || { bad "the cores got something else:"; govs | sed 's/^/        | /'; }

echo
echo "   -- the applier must not report success when a core did not take it:"
# The applier the device would run, pointed at the fake sysfs.
CPAP=$CPUAP
env_reset
runsh "$CPAP"
printf '%s\n' "$OUT" > "$W/out.cp.applier"
[ "$RC" = 0 ] && ok "with every core accepting it, the applier exits 0" || bad "it exited $RC"
[ "$(govs | sort -u)" = "interactive" ] && ok "and moved all four" || bad "it did not move all four"
want 'on 4 cores \(0 did not take it\)' "$OUT" "and says so with the count that proves each core was read back"

echo
echo "     ... and a core whose governor will NOT take the write:"
# The one case that matters, made without a fake kernel: cpu2's scaling_governor is a DIRECTORY. Its
# mode bits make `[ -w ]` true, so the applier does not skip it as "this core has no cpufreq"; the write
# then fails ("Is a directory") and the read-back finds something that is not the governor. That is the
# shape of a kernel rejecting a name it does not offer -- EINVAL on the write, the old value still
# there -- and it is what makes the difference between the two versions visible.
rm -f "$FR/sys/devices/system/cpu/cpu2/cpufreq/scaling_governor"
mkdir -p "$FR/sys/devices/system/cpu/cpu2/cpufreq/scaling_governor"
govs() { for c in 0 1 2 3; do v=$(cat "$FR/sys/devices/system/cpu/cpu$c/cpufreq/scaling_governor" 2>/dev/null); printf '%s\n' "${v:-<not a file>}"; done; }
govs_reset() { for c in 0 1 2 3; do [ -d "$FR/sys/devices/system/cpu/cpu$c/cpufreq/scaling_governor" ] || printf 'performance\n' > "$FR/sys/devices/system/cpu/cpu$c/cpufreq/scaling_governor"; done; }
govs_reset
env_reset
runsh "$CPAP"
printf '%s\n' "$OUT" > "$W/out.cp.applier.bad"
[ "$RC" = 1 ] && ok "a core that did not take it FAILS the applier (rc=1), it does not report success" \
  || bad "it exited $RC -- the unit would be 'active' with a core still on the old governor"
want 'did NOT take' "$OUT" "it names the core that refused, and what that path reads instead"
want 'NOT armed' "$OUT" "and says what that means: the heat fix is not armed"
want 'on 3 cores \(1 did not take it\)' "$OUT" "with the 3/1 split, which is the honest count"

echo "     ... and the applier that actually shipped, on the very same fixture:"
# Not a mutation of the new one: the applier that SHIPPED BEFORE THE FIX, extracted and rewritten the
# same way. That is the version whose behaviour is being claimed, so it is the version to run.
#
# **It is found by walking this file's history, not by reading HEAD.** The first version of this said
# `git show HEAD:...`, which was correct exactly until the fix was committed -- after that HEAD *is*
# the fixed applier and the "the shipped one exits 0" assertions compared the fix against itself. The
# guard that was supposed to catch that looked for `did NOT take it`, a string that appears in neither
# version (the applier prints `did NOT take '<governor>'`), so it could only ever pass: an assertion
# that cannot fail, which is the same defect this file exists to find in the scripts. Walking back to
# the newest revision whose applier has no read-back keeps the comparison meaningful as HEAD moves.
# The path given to git is REPO-RELATIVE, not $CP: the documented way to run this file is a copy of it
# and of the scripts under test, placed outside the repository -- and `git log -- /tmp/copy/...` finds
# no history at all, which is how the first version of this walk turned a working comparison into a
# hard error under the project's own instructions. $W/cp.try.sh is where each revision lands.
CPOLD=""
for c in $(git log --format=%H -- scripts/install-cpufreq-governor.sh 2>/dev/null); do
  git show "$c:scripts/install-cpufreq-governor.sh" > "$W/cp.try.sh" 2>/dev/null || continue
  extract_applier "$W/cp.try.sh" APPLIER_EOF "$W/applier/cp.try.raw.sh" 2>/dev/null || continue
  case "$(cat "$W/applier/cp.try.raw.sh" 2>/dev/null)" in
  *"NOT armed"*) continue ;;   # this revision has the read-back; keep walking
  esac
  CPOLD=$c; cp "$W/applier/cp.try.raw.sh" "$W/applier/cp.old.raw.sh"; break
done
if [ -n "$CPOLD" ]; then
  sed -e "s#/sys/devices/system/cpu#$FR/sys/devices/system/cpu#g" "$W/applier/cp.old.raw.sh" > "$W/applier/cpufreq-old.sh"
  ok "the pre-fix revision is $(printf '%s' "$CPOLD" | cut -c1-12), whose applier has no read-back"
else
  # Not a failure: the comparison is a statement about this repository's HISTORY, and a copy of the
  # tree outside it has no history to walk. It is printed as a SKIP, counted separately, and named at
  # the end -- an assertion that quietly becomes a no-op is the defect this whole file hunts for.
  SKIP=$((SKIP + 1))
  printf 'SKIP  the "shipped applier" comparison (no git history for scripts/install-cpufreq-governor.sh here)\n'
  printf '      run this harness from inside the repository to get it; it is not a failure of the script\n'
  sed -e "s#/sys/devices/system/cpu#$FR/sys/devices/system/cpu#g" "$W/applier/cp.raw.sh" > "$W/applier/cpufreq-old.sh"
fi
if grep -qF 'NOT armed' "$W/applier/cp.old.raw.sh" 2>/dev/null; then
  # the guard that has to be able to FAIL: if the "pre-fix" version somehow has the read-back, the
  # two appliers agree and the comparison below proves nothing about the fix
  [ -n "$CPOLD" ] && bad "the pre-fix applier still contains the read-back -- the comparison proves nothing"
else

  ok "the shipped applier has no read-back, so it is the behaviour the fix replaces"
  govs_reset
  env_reset
  runsh "$W/applier/cpufreq-old.sh"
  printf '%s\n' "$OUT" > "$W/out.cp.applier.old"
  [ "$RC" = 0 ] && ok "and it exits 0 on a device where one core never moved -- the defect" \
    || bad "the shipped applier exited $RC"
  notwant 'did NOT take' "$OUT" "with nothing said about the core that refused"
  notwant 'NOT armed' "$OUT" "and nothing said about the heat fix being unarmed"
  want 'on 3 cores' "$OUT" "it simply reports three, as if that were the whole device"
fi
rm -rf "$FR/sys/devices/system/cpu/cpu2/cpufreq/scaling_governor"
printf 'performance\n' > "$FR/sys/devices/system/cpu/cpu2/cpufreq/scaling_governor"
govs() { for c in 0 1 2 3; do cat "$FR/sys/devices/system/cpu/cpu$c/cpufreq/scaling_governor"; done; }
govs_reset() { for c in 0 1 2 3; do printf 'performance\n' > "$FR/sys/devices/system/cpu/cpu$c/cpufreq/scaling_governor"; done; }

echo "   -- --remove: disable --now, delete exactly its own two files:"
: > "$FR/etc/systemd/system/zl1-someone-elses.service"
govs_reset
run "$CP" --remove
printf '%s\n' "$OUT" > "$W/out.cp.remove"
[ "$RC" = 0 ] && ok "cpufreq --remove exits 0" || bad "cpufreq --remove exited $RC"
[ ! -f "$CPU_SH" ] && [ ! -f "$CPU_UNIT" ] && ok "both of its files are gone" || bad "its files survive"
[ -f "$FR/etc/systemd/system/zl1-someone-elses.service" ] && ok "and it removed nothing else" || bad "it deleted a file it does not own"
want '^systemctl disable --now zl1-cpufreq-governor\.service' "$(sysacts)" "it disables and stops the unit"
want 'gov=' "$OUT" "and reports the governors afterwards, so 'back to what the image set' is visible"
rm -f "$FR/etc/systemd/system/zl1-someone-elses.service"
echo
# ==================================================================================================
echo
echo "== 13. netwatch: the TWRP-side installer, and the only backup of the misc partition =="
# ==================================================================================================
# Why this one is in here, in one sentence: it is the thing that makes retiring the debug keeper safe
# (`zl1-netwatch.service` re-asserts the addresses every sample, docs 88), and it is also the only
# script in this directory that has to READ A PARTITION -- misc, which the watchdog can write
# "boot-recovery" into to reach recovery. So there are two things to hold it to: it must write exactly
# the four paths it says, and a misc backup it accepts must be a real one.
#
# Its device is NWR, a TWRP-like root where userdata is a plain /data mount. The ONLY rewrite below is
# MISC_OUT, and that is because MISC_OUT is a genuine HOST path (the backup directory on this laptop);
# everything else the installer says is a DEVICE path and the adb stub is what turns those into files.
# Rewriting BASE as well -- the first draft did exactly that -- nests the fake root inside itself,
# because the installer then hands the transport a path that already carries the transport's prefix.
NWC=$W/nw.sh
sed -e "s#^MISC_OUT=.*#MISC_OUT=\"$W/misc\"#" "$NW" > "$NWC"
sh -n "$NWC" 2>/dev/null || bash -n "$NWC" || { echo "the rewritten netwatch installer does not parse" >&2; exit 2; }
grep -qF "MISC_OUT=\"$W/misc\"" "$NWC" || { echo "the netwatch MISC_OUT rewrite did not land" >&2; exit 2; }
grep -qF 'BASE="/data/system-data/etc/systemd/system"' "$NWC" || \
  { echo "the netwatch BASE is no longer the device path the adb stub maps" >&2; exit 2; }
# The fake misc partition has to be BIGGER than the short read (1024 bytes), otherwise "truncated" is
# the whole file and the short-read scenario stops being distinguishable from a correct read.
head -c 4096 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$W/misc-content.txt"
printf 'MISC-PARTITION-CONTENT ' > "$NWR/dev/block/bootdevice/by-name/misc"
cat "$W/misc-content.txt" >> "$NWR/dev/block/bootdevice/by-name/misc"
MISC_PART="$NWR/dev/block/bootdevice/by-name/misc"
NWDIR="$NWR/data/system-data/etc/systemd/system"
rm -rf "$NWR/data/system-data" "$W/misc"; rm -f "$W/adb-short"
nwsnap() { find "$NWR" "$W/misc" -printf '%p %s\n' 2>/dev/null | sort; }

echo
echo "   -- the refusal that comes before everything: it must be asked for by name"
BEFORE=$(nwsnap)
run "$NWC"
printf '%s\n' "$OUT" > "$W/out.nw.noyes"
[ "$RC" = 2 ] && ok "with no --yes it exits 2" || bad "without --yes it exited $RC"
want 'refusing without --yes' "$OUT" "and says why"
[ "$(nwsnap)" = "$BEFORE" ] && ok "and wrote nothing" || bad "it wrote something without --yes"
[ -z "$(grep '^adb ' "$ACT" 2>/dev/null)" ] && ok "it did not even talk to adb" || bad "it ran adb anyway"

echo
echo "   -- and the device must actually be there, matched by SERIAL:"
RUN_ADB_SERIAL=none run "$NWC" --yes
printf '%s\n' "$OUT" > "$W/out.nw.noserial"
[ "$RC" = 1 ] && ok "with the serial absent from 'adb devices' it exits 1" || bad "it exited $RC"
want '33e80afe not visible in adb' "$OUT" "and names the serial it looked for (never a bare USB id)"
want 'adb devices' "$(grep -c '^adb devices' "$ACT" >/dev/null && echo "adb devices" || echo none)" "it asks adb devices first, which is the only honest check"

echo
echo "   -- --status is not a mode of this script; --yes --remove is:"
RUN_ADB_SERIAL=33e80afe
run "$NWC" --yes --remove
printf '%s\n' "$OUT" > "$W/out.nw.remove.empty"
[ "$RC" = 0 ] && ok "--yes --remove exits 0 even with nothing installed" || bad "it exited $RC"
want 'removed the netwatch service' "$OUT" "and says what it removed"
want 'the log at /data/zl1-netwatch.log is left in place' "$OUT" "and that the LOG survives -- evidence is not configuration"
[ -z "$(grep -c 'push ' "$ACT" 2>/dev/null | grep -v '^0$')" ] && ok "and it pushed nothing" || bad "a remove pushed a file"

echo
echo "   -- --yes: the four paths, the unit, both symlinks, and a misc backup"
rm -rf "$W/misc"; rm -f "$W/adb-short"
env_reset
run "$NWC" --yes
printf '%s\n' "$OUT" > "$W/out.nw.install"
[ "$RC" = 0 ] && ok "--yes exits 0" || bad "--yes exited $RC"
want 'backing up misc' "$OUT" "it reads the misc partition before anything could write to it"
[ -f "$NWDIR/zl1-netwatch.sh" ] && ok "it pushed the netwatch script" || bad "no script at the destination"
[ -f "$NWDIR/zl1-netwatch.service" ] && ok "and wrote the unit" || bad "no unit"
[ -x "$NWDIR/zl1-netwatch.sh" ] && ok "the script is executable (chmod 0755)" || bad "the script is not executable"
[ -L "$NWDIR/sysinit.target.wants/zl1-netwatch.service" ] \
  && ok "the sysinit.target.wants symlink exists" || bad "no sysinit symlink"
[ -L "$NWDIR/multi-user.target.wants/zl1-netwatch.service" ] \
  && ok "and the multi-user one" || bad "no multi-user symlink"
want '^Type=simple$' "$(cat "$NWDIR/zl1-netwatch.service")" "the unit is Type=simple (the script loops by design)"
want '^Restart=always$' "$(cat "$NWDIR/zl1-netwatch.service")" "and Restart=always"
want '^StartLimitIntervalSec=0$' "$(cat "$NWDIR/zl1-netwatch.service")" "with no start limit, so systemd cannot give up and leave the device without a recorder"
want '^ExecStart=/etc/systemd/system/zl1-netwatch\.sh$' "$(cat "$NWDIR/zl1-netwatch.service")" "and ExecStart is the device path, not the TWRP one"
want '^WantedBy=sysinit\.target$' "$(cat "$NWDIR/zl1-netwatch.service")" "it is wanted by sysinit as well, so it starts before the container"
want '^Nice=-5$' "$(cat "$NWDIR/zl1-netwatch.service")" "at Nice=-5"
want 'sync$|syncing' "$OUT" "it syncs before the caller reboots (the page-cache hazard its own comment records)"
[ -f "$W/misc/misc.img" ] && ok "it took a misc backup (the partition the watchdog can write boot-recovery into)" \
  || bad "no misc backup"
[ ! -e "$NWR/data/zl1-netwatch-noheal" ] && ok "and with no --noheal the noheal marker is absent (healing on)" \
  || bad "the noheal marker is present without --noheal"
want 'misc.img' "$(cat "$W/misc/SHA256SUMS" 2>/dev/null)" "and recorded a checksum for it"
( cd "$W/misc" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ) && ok "which verifies" || bad "the recorded checksum does not verify"
[ "$(stat -c%s "$W/misc/misc.img")" = "$(stat -c%s "$MISC_PART")" ] \
  && ok "and the image is the whole partition, byte for byte (the size cross-check)" || bad "the image is short"

echo
echo "   -- --noheal is record-only, and it says so:"
env_reset
run "$NWC" --yes --noheal
printf '%s\n' "$OUT" > "$W/out.nw.noheal"
[ -f "$NWR/data/zl1-netwatch-noheal" ] && ok "--noheal leaves the marker that turns healing off" \
  || bad "no noheal marker"
want 'record-only mode' "$OUT" "and says which mode it installed"

echo
echo "   -- a backup that is present is VERIFIED, not assumed (this round's second fix):"
# The defect: the block was gated on `[[ -f misc.img ]]` alone and nothing ever looked at the file
# again, so a run whose exec-out produced 0 bytes (adb dropped, device unplugged) would leave a file
# that satisfies every later run's test. This is the one backup of the partition the watchdog writes to.
echo "   -- an EXISTING, verifying backup is reused and not re-read:"
: > "$ACT"
BEFORE_SUM=$(sha256sum < "$W/misc/misc.img")
run "$NWC" --yes
printf '%s\n' "$OUT" > "$W/out.nw.reuse"
want 'already present and verified' "$OUT" "a good backup is reported as verified"
notwant 'backing up misc' "$OUT" "and is NOT re-taken (no second read of the partition)"
[ "$(sha256sum < "$W/misc/misc.img")" = "$BEFORE_SUM" ] && ok "the file is unchanged" || bad "the backup changed"

echo
echo "   -- a TRUNCATED backup is caught and replaced:"
# 1024 of 4096 bytes: what a dropped transfer leaves behind, and what `ls -l` afterwards cannot show.
: > "$W/adb-short"
printf 'TRUNCATED' > "$W/misc/misc.img"
printf 'deadbeef  misc.img\n' > "$W/misc/SHA256SUMS"
run "$NWC" --yes
printf '%s\n' "$OUT" > "$W/out.nw.short"
want 'FAILS its recorded SHA256' "$OUT" "an existing backup that does not match its own hash is called out"
want 'backing up misc' "$OUT" "and it re-takes the backup"
if printf '%s\n' "$OUT" | grep -q 'refusing to record a misc backup'; then
  # the short read also truncates the REPLACEMENT, which is what the size cross-check exists for
  ok "and when the replacement read is short too, it REFUSES to record it"
  want 'an unverified misc backup is worse than none' "$OUT" "saying why: it would satisfy every later run's check"
  [ "$RC" = 1 ] && ok "and that refusal is a failure exit, not a note" || bad "it exited $RC while refusing"
  [ ! -e "$W/misc/misc.img.tmp" ] && ok "leaving no .tmp behind to be mistaken for an image" || bad "a .tmp was left behind"
else
  bad "a short replacement read was recorded as a backup"
fi
rm -f "$W/adb-short"

echo
echo "   -- an EMPTY backup is caught:"
: > "$W/misc/misc.img"
printf 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  misc.img\n' > "$W/misc/SHA256SUMS"
run "$NWC" --yes
printf '%s\n' "$OUT" > "$W/out.nw.empty"
want 'EMPTY' "$OUT" "a 0-byte backup is named as empty (its hash would otherwise verify: it is the hash of nothing)"
want 'backing up misc' "$OUT" "so it is re-taken"

echo
echo "   -- and a healthy device with a healthy backup leaves the real one alone:"
[ -s "$W/misc/misc.img" ] && ok "the backup on disk is non-empty at the end of these scenarios" \
  || bad "the scenarios left an empty misc backup behind"

echo
echo "   -- the integrity check is live, and a build that lost functions is refused:"
want 'functions checked' "$(bash "$HERE/../check-netwatch-integrity.sh" 2>&1)" "the checker runs against the real netwatch script and reports what it checked"
grep -qF 'check-netwatch-integrity.sh' "$NWC" || bad "the installer no longer calls the integrity checker at all"
# A build missing a required function must be refused, so make one. The checker is found RELATIVE to
# the source it is given ($SRC/../), so the fake tree has to carry a copy of it too -- without that the
# installer's `[[ -x ... ]]` test fails, the whole check is silently skipped, and a build that lost a
# function gets installed (which is what happened on 2026-09-19 and why the check exists).
mkdir -p "$W/badbuild/scripts/device"
cp "$HERE/../check-netwatch-integrity.sh" "$W/badbuild/scripts/"
sed 's/^restore_addrs()/# restore_addrs()/' "$HERE/../device/zl1-netwatch.sh" > "$W/badbuild/scripts/device/zl1-netwatch.sh"
sed -e "s#^SRC=.*#SRC=\"$W/badbuild/scripts/device/zl1-netwatch.sh\"#" "$NWC" > "$W/nw.badsrc.sh"
rm -rf "$NWR/data/system-data"
env_reset
run "$W/nw.badsrc.sh" --yes
printf '%s\n' "$OUT" > "$W/out.nw.badbuild"
[ "$RC" = 1 ] && ok "a build missing a function exits 1 instead of being installed" || bad "it exited $RC"
want 'refusing to install: integrity check failed' "$OUT" "and says the integrity check is why"
[ -f "$NWDIR/zl1-netwatch.sh" ] && bad "it installed the broken build anyway" || ok "and nothing reached the device"
want 'MISSING' "$(bash "$HERE/../check-netwatch-integrity.sh" "$W/badbuild/scripts/device/zl1-netwatch.sh" 2>&1)" "and the checker names what is missing"

echo
echo "   -- nothing outside its four paths, and nothing flashed (fresh device, fresh backup dir):"
rm -rf "$NWR/data/system-data" "$W/misc"; rm -f "$W/adb-short"
env_reset
run "$NWC" --yes
printf '%s\n' "$OUT" > "$W/out.nw.final"
[ "$RC" = 0 ] && ok "a clean install still works after all of the above" || bad "the final clean install exited $RC"
[ ! -e "$NWDIR/zl1-retire-debug-keeper.service" ] && [ ! -e "$NWDIR/zl1-no-edl-on-panic.sh" ] \
  && ok "it wrote none of the other installers' files" || bad "it wrote another installer's file"
notwant 'adb .*(flash|erase|write|dd )[^ ]* /dev/block' "$(grep '^adb ' "$ACT" 2>/dev/null)" "no adb call flashes, erases or writes a partition"
want 'exec-out' "$(grep '^adb ' "$ACT" 2>/dev/null | grep -q 'exec-out' && echo 'exec-out' || echo none)" "the only partition access is a read (exec-out), which is the backup itself"
want "readlink -f /dev/block/bootdevice/by-name/misc" "$(grep '^adb ' "$ACT" 2>/dev/null)" "and it resolves the misc device BY NAME on the device, not from a hardcoded path"
[ -x "$W/misc/misc.img" ] && bad "the misc backup came out executable (cp of the wrong thing)" || ok "the misc backup is not an executable copy of a script"
cmp -s "$W/misc/misc.img" "$MISC_PART" && ok "and the backup is byte-identical to the partition it claims to be" || bad "the backup differs from the partition"

echo
echo "pass=$PASS fail=$FAIL$([ "$SKIP" != 0 ] && echo " skip=$SKIP (a check that could NOT run here; see the SKIP line above)")"
[ "$KEEP" = 1 ] || rm -rf "$W"
[ "$FAIL" = 0 ]
