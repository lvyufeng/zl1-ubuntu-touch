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
#   scripts/install-lpm-sleep-fix.sh         the THIRD heat fix (docs 160): every zl1 cmdline carries
#                                            `lpm_levels.sleep_disabled=1`, which removes the SoC's
#                                            whole low-power ladder, and the value does not survive a
#                                            reboot -- so the fix is a boot-time writer. It is the first
#                                            installer here whose LICENCE is a verdict line read out of
#                                            another instrument's archived output.
#
# Why they need one:
#
#   * `install-retire-debug-keeper.sh --install --now` KILLS A PROCESS ON THE DEVICE. Its safety
#     argument used to be a refusal gate -- "it refuses to kill when it cannot see an address" -- and
#     that gate could not fail: the keeper's own 1 Hz loop is what puts the address on the interface, so
#     the address is present BECAUSE OF the process being removed, on every boot a kill can happen on.
#     The gate that can fail is the other one, added by docs 114: the replacement (our netwatch) must be
#     deployed, carry `ensure_addrs()` and be active -- and the kill additionally needs --after-proof,
#     a measurement made seconds earlier rather than a memory of having run the boot-address check. A
#     refusal gate that does not actually refuse is indistinguishable from no gate at all until the day
#     the network does not come back, which is why sections 2b and 2c exist and why they have teeth
#     against the pre-fix build (66 failures, and 377 checks now). It also has a matching function that deliberately is NOT
#     a substring test, because "killing the wrong process" is the one failure mode worth being
#     pedantic about -- and the checks that prove it read the applier's DECISION (`matched=`) and not the
#     whole output, which carries a number no scenario controls (docs 121 section 5.4).
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
# Two fixtures are load-bearing in a way worth naming, because both were wrong first. The fake device's
# `is-active` printed the state and exited **0** -- and the applier's gate trusted the exit code, so the
# stub agreed with the script for no reason at all. Both halves are faithful now (the stub exits 3 for
# inactive, as systemd does; the gate reads the state). And the fake device's netwatch is a copy that
# scenarios move between `installed`, `absent`, `no-ensure` and `inactive`, because the retirement's
# gate and the netwatch installer's own section are correct about opposite states of the same
# directory. See the note on NMODE.
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
  --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0" ; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

HERE=$(dirname "$0")
RK="$HERE/../install-retire-debug-keeper.sh"
NE="$HERE/../install-no-edl-on-panic.sh"
CP="$HERE/../install-cpufreq-governor.sh"
NW="$HERE/../install-netwatch-service.sh"
LPM="$HERE/../install-lpm-sleep-fix.sh"
for f in "$RK" "$NE" "$CP" "$NW"; do [ -r "$f" ] || { echo "cannot read $f" >&2; exit 2; }; done
command -v bash >/dev/null 2>&1 || { echo "the installers are bash scripts; bash is required" >&2; exit 2; }

W=${TMPDIR:-/tmp}/zl1-installers-selftest
FR="$W/fake"
STUB="$W/stub"
ACT="$W/actions"
rm -rf "$W"
mkdir -p "$FR/etc/systemd/system" "$FR/proc" "$FR/sys/class/net/rndis0" "$FR/sys/module/msm_poweroff/parameters" \
         "$FR/sys/fs/pstore" "$FR/userdata" "$FR/usr/local/sbin" "$FR/run" \
         "$W/applier" "$W/killignore" "$FR/proc/sys/kernel/random" "$FR/proc/device-tree" "$STUB" || exit 2

# --- the fake device's state ---------------------------------------------------------------------
#
# The device-identity guard reads this. It is the same string the real device reports, and it is here
# because the transport maps /proc/device-tree into the fake root (see paths.sed): without it the guard
# would be satisfied or refused by the HOST's own /proc, and the section that tests it would be testing
# the harness's machine rather than the installer.
printf 'qcom,msm8996\n' > "$FR/proc/device-tree/compatible"
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
# --- the THIRD heat fix's device side (section 15) ------------------------------------------------
# The parameter every zl1 cmdline sets to 1: what the installer writes, and what the trial measures.
# It is under `lpm_levels` because that is the driver's own MODULE_PARAM_PREFIX -- and the installer
# DISCOVERS the path rather than assuming it, so the fixture has to have it where a real device would.
mkdir -p "$FR/sys/module/lpm_levels/parameters" "$FR/sys/devices/system/cpu/cpu0/cpuidle"
printf '1\n' > "$FR/sys/module/lpm_levels/parameters/sleep_disabled"
# The cmdline, as a map, because the installer reads BOTH sides and prints them next to each other: the
# cmdline is what the boot was TOLD, the file is what the driver HAS, and the disagreement between them
# is what the fix looks like. A fixture with only the file would make the "both sides" line untestable.
printf 'console=ttyMSM0,115200n8 lpm_levels.sleep_disabled=1 androidboot.hardware=qcom\n' > "$FR/proc/cmdline"
# Four cpuidle states, named as this board's kernel names them. `disable` is 0 on all four, and the
# harness asserts it stays 0: it is one of the four files this repository records as writable on the
# device, and changing it is a DECISION rather than a reading (docs 138).
for i in 0 1 2 3; do
  case $i in 0) n=wfi ;; 1) n=retention ;; 2) n=standalone_pc ;; 3) n=pc ;; esac
  mkdir -p "$FR/sys/devices/system/cpu/cpu0/cpuidle/state$i"
  printf '%s\n' "$n" > "$FR/sys/devices/system/cpu/cpu0/cpuidle/state$i/name"
  printf '%s\n' "$((1000 + i * 100))" > "$FR/sys/devices/system/cpu/cpu0/cpuidle/state$i/usage"
  printf '%s\n' "$((100000 + i * 10000))" > "$FR/sys/devices/system/cpu/cpu0/cpuidle/state$i/time"
  printf '0\n' > "$FR/sys/devices/system/cpu/cpu0/cpuidle/state$i/disable"
done
printf 'the keeper itself, for the status listing\n' > "$FR/usr/local/sbin/zl1-debug-net.sh"
printf '100.0 900.0\n' > "$FR/proc/uptime"
printf 'deadbeef-0000-0000-0000-000000000000\n' > "$FR/proc/sys/kernel/random/boot_id"
printf 'rndis0\n' > "$FR/sys/class/net/rndis0/uevent"

# The REPLACEMENT. This directory's reason to exist is that the applier's address test cannot fail --
# the keeper is what puts the address there -- so the gate that can fail is "is the thing that is
# supposed to take over actually deployed and running". That means the fixture has to look like a
# device where the netwatch WAS installed, or every "it kills" scenario below would be measuring a
# refusal instead. It is written with the real function name (`ensure_addrs`) because the check is
# `grep -q '^ensure_addrs()'` on the DEPLOYED file -- the same question install-netwatch-service.sh
# asks of the build it lands, at the other end of the device's life.
mkdir -p "$FR/etc/systemd/system"
cat > "$FR/etc/systemd/system/zl1-netwatch.sh" <<'NETWATCH_FIXTURE'
#!/bin/sh
# The netwatch, as installed. Only the shape the retirement's gate reads is reproduced here: the
# function that re-asserts the addresses, which is what makes the keeper redundant.
IFACES="rndis0 usb0"
ensure_addrs() {
    for i in $IFACES; do
        [ -e "/sys/class/net/$i" ] || continue
        ip -4 addr show dev "$i" | grep -q '192.168.2.15/24' || ip addr add 192.168.2.15/24 dev "$i"
        ip -4 addr show dev "$i" | grep -q '10.15.19.82/24' || ip addr add 10.15.19.82/24 dev "$i"
    done
}
while :; do ensure_addrs; sleep 2; done
NETWATCH_FIXTURE
chmod 0755 "$FR/etc/systemd/system/zl1-netwatch.sh"

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
  # A unit whose ExecStart is an INFINITE LOOP cannot be run by a fixture -- zl1-netwatch.sh is a
  # 'while :; do ensure_addrs; sleep 2; done' loop, and with 'sleep' stubbed that spins at a full core
  # forever and hangs the harness. So for that one unit the stub models the two facts the installer can
  # observe on a device instead of executing it: the service is active, and systemd knows when its main
  # process started (the ExecMainStartTimestampMonotonic arm below). Everything the --activate check
  # rests on is therefore a fixture, and every way for it to be wrong is a fixture too.
  #
  # NO BACKTICKS IN THIS COMMENT, and the same goes for every comment in this heredoc: it is unquoted,
  # so a backquote is COMMAND SUBSTITUTION. The file already warns about this further up, and this
  # comment is the second draft of the paragraph above -- the first one put the loop in backticks and
  # the harness hung here for its full timeout, printing 'ensure_addrs: not found' while it spun.
  case "\$u" in
  zl1-netwatch.service)
    if [ -e "$W/netwatch-inactive" ]; then
      printf 'netwatch-restart-refused\n' >> "$ACT"
      exit 1
    fi
    if [ -e "$W/netwatch-stale" ]; then
      # A RESTART THAT DID NOT TAKE: the process is a survivor of the build that was running before the
      # deployed file was written. On a device this is a restart that silently did nothing, and the
      # installer must FAIL rather than report the deployed build as live.
      printf 'netwatch-restart-noop\n' >> "$ACT"
      printf '5000000\n' > "$W/netwatch-mono"
      exit 0
    fi
    printf 'netwatch-restart\n' >> "$ACT"
    # Strictly later than the uptime the installer read immediately before the restart (100.0 s).
    # The awk field is ESCAPED because this heredoc is unquoted: written bare it would be the
    # HARNESS's own first argument,
    # and under 'set -u' with no arguments that is not an empty string -- it aborts the whole 'cat', so
    # the stub is never written and every systemctl call in every section silently returns nothing.
    # (Measured: that is exactly what happened, and it reddened 57 checks across sections 1-13.)
    awk '{printf "%d\n", (\$1 + 2) * 1000000}' "$FR/proc/uptime" > "$W/netwatch-mono"
    exit 0 ;;
  esac
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
    # Section 15's unit. Its applier has ONE device path (the parameter), so the rewritten copy in
    # $W/applier is the whole rewrite -- and the run is what makes the parameter really change, which is
    # what the installer then reads back.
    zl1-lpm-sleep-fix.service)
      ex=\$(sed -n 's/^ExecStart=//p' "$FR/etc/systemd/system/\$u" 2>/dev/null | head -1)
      alt="$W/applier/\$(basename "\$ex")"
      printf 'systemctl-ran-applier %s\n' "\$ex" >> "$ACT"
      if [ -n "\${FAKE_LPM_SKIP_APPLIER:-}" ]; then exit 0; fi
      if [ -f "\$alt" ]; then
        exec env PATH="$STUB:\$PATH" sh "\$alt"
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
  # THE EXIT CODE IS PART OF THE ANSWER. Real systemd's 'is-active' prints the state AND exits 3 when it
  # is not 'active'; this stub used to print 'inactive' and exit 0, and an applier gate written as
  # 'systemctl is-active X >/dev/null 2>&1 || refuse' passed straight through it -- a fixture whose
  # answer agreed with the script for no reason. Both halves are real now.
  case "\$*" in
  *zl1-retire-debug-keeper*) [ -e "$W/active-retire" ] && { echo active; exit 0; } || { echo inactive; exit 3; } ;;
  # The replacement's liveness is one of the applier's gate conditions, so it is an explicit fixture
  # and not a fall-through: a stub whose default answer is "active" is a fixture that agrees with
  # whatever the script asserts.
  *zl1-netwatch*)            [ -e "$W/netwatch-inactive" ] && { echo inactive; exit 3; } || { echo active; exit 0; } ;;
  *) echo active ;;
  esac ;;
show)
  case "\$*" in
  *-p\ Result*) printf 'success\n' ;;
  # A FIXTURE, not a constant: install-lpm-sleep-fix.sh decides its verdict from this value, so "the
  # unit ran and failed" has to be a state the harness can put the device in -- otherwise the check that
  # reads it could never be seen to fail (docs 114: a gate that cannot fail is not a gate). This arm is
  # the one that MATCHES -- the 'value' variant below is shadowed by it, which is how the first draft
  # of this fixture was written and why it did nothing.
  *-p\ ExecMainStatus*) [ -e "$W/lpm-execstatus" ] && cat "$W/lpm-execstatus" || printf '0\n' ;;
  *-p\ MainPID*) printf '0\n' ;;
  *-p\ NRestarts*) printf '0\n' ;;
  *-p\ ActiveState*) printf 'inactive\n' ;;
  *-p\ SubState*) printf 'dead\n' ;;
  # BEFORE the ExecMainStartTimestamp arm, which would otherwise swallow this name too (this stub
  # matches with shell patterns, and ExecMainStartTimestamp* covers ...Monotonic). --activate
  # uses this value to decide whether the running process read the deployed file, so it is a fixture
  # with a writable file behind it rather than a constant: on a device the number changes at every
  # restart, and a fixture that cannot change cannot test the check that reads it.
  *-p\ ExecMainStartTimestampMonotonic*)
    if [ -e "$W/netwatch-nomono" ]; then printf 'n/a\n'; else cat "$W/netwatch-mono" 2>/dev/null || printf '0\n'; fi ;;
  *-p\ ExecMainStartTimestamp*) printf 'n/a\n' ;;
  *-p\ Result\ --value*) printf 'success\n' ;;
  *-p\ ExecMainStatus\ --value*) [ -e "$W/lpm-execstatus" ] && cat "$W/lpm-execstatus" || printf '0\n' ;;
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
# --- the parameter's TYPE, in the one tool the applier reads it with ---------------------------------
# `cat` is the applier's reader (`got=$(cat "$p")`), so the type belongs here for the same reason the
# trial's belongs on `tr`: `sleep_disabled` is a `bool` module parameter (drivers/cpuidle/lpm-levels.c),
# so sysfs renders the stored 0 as N, and the applier's read-back has to compare STATES rather than the
# string it wrote. Everything that is not that one file is delegated, so this changes nothing else.
#
# THE DEFAULT IS THE REAL SHAPE (FAKE_LPM_BOOL=1). A fixture whose parameter is a plain text file cannot
# make the shipped applier and its pre-fix version behave differently, and that is not a hypothetical:
# until 2026-09-25 this harness's fixture was exactly that, and it reported "the parameter reads 0" over
# an applier that on the real device reported its own good write as a failure and exited 1 (docs 163).
# THE SWITCH IS A FILE AND NOT AN ENVIRONMENT VARIABLE, and that is deliberate: this stub is a
# GRANDCHILD of the harness (harness -> installer -> systemctl stub -> applier -> cat), and an env
# variable has to be propagated through three shells to reach it. A file cannot be lost on the way, and
# a control that silently fails to arrive is a control that proves nothing while looking green.
REAL_CAT="$(type -P cat)" || { echo "no real cat on this host" >&2; exit 2; }
cat > "$STUB/cat" <<EOF
#!/bin/sh
case "\${1:-}" in
*/parameters/sleep_disabled)
  if [ ! -e "$W/lpm-plain-parameter" ]; then
    v=\$($REAL_CAT "\$1" 2>/dev/null | sed 's/[[:space:]]*\$//')
    case "\$v" in
    0) printf 'N' ;;
    1) printf 'Y' ;;
    *) printf '%s' "\$v" ;;
    esac
    exit 0
  fi ;;
esac
exec $REAL_CAT "\$@"
EOF
chmod +x "$STUB"/*

mkdir -p "$W/probe/parameters"
printf '0' > "$W/.catprobe"
printf '0' > "$W/probe/parameters/sleep_disabled"
[ "$( PATH="$STUB:$PATH" cat "$W/.catprobe" )" = 0 ] \
  || { echo "the cat stub rendered a file that is not the parameter" >&2; exit 2; }
[ "$( PATH="$STUB:$PATH" cat "$W/probe/parameters/sleep_disabled" )" = N ] \
  || { echo "the cat stub does NOT render the parameter -- the alphabet scenarios would be vacuous" >&2; exit 2; }
: > "$W/lpm-plain-parameter"
[ "$( PATH="$STUB:$PATH" cat "$W/probe/parameters/sleep_disabled" )" = 0 ] \
  || { echo "the plain-parameter switch does not reach the stub -- the control would not be a control" >&2; exit 2; }
rm -rf "$W/.catprobe" "$W/probe" "$W/lpm-plain-parameter"

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
# The cmdline, for section 15. Unmapped it would read the HOST's cmdline, and the installer prints the
# cmdline and the parameter side by side -- so the reading would be about this laptop's boot.
emit "s#/proc/cmdline#$FR/proc/cmdline#g"
emit "s#/proc/\[0-9\]\*#$FR/proc/[0-9]*#g"
emit "s|\\\${d#/proc/}|\\\${d#$FR/proc/}|g"
emit "s|/proc/\\\$ppid|$FR/proc/\\\$ppid|g"
emit "s|/proc/\\\$p/|$FR/proc/\\\$p/|g"
# The device-identity guard. install-netwatch-service.sh --ssh asks for it before it writes anything,
# and unmapped it would read the HOST's /proc -- where there is no device tree at all, so the installer
# would refuse with "not the zl1, or unreachable" and every assertion below would be about the
# harness's own /proc rather than about the guard. (The installer is the only one in this harness that
# guards this way; install-fingerprint-store-dir.sh does too, and has its own selftest.)
emit "s#/proc/device-tree#$FR/proc/device-tree#g"

# The proof. `--now --after-proof` pushes it and then runs it, and the two have to land in different
# places or the push would overwrite the fixture. The push is `cat > /tmp/zl1-address-owner-proof.sh`,
# the run is `timeout ... sh /tmp/zl1-address-owner-proof.sh --yes`: the `--yes` rule is first, so it
# takes the invocation, and by the time the bare rule applies there is no occurrence left to match.
# The pushed bytes are the REAL script (asserted below: the transport is faithful), and it is never
# executed here -- the proof's own behaviour is what scripts/host/zl1-address-proof-selftest.sh covers,
# with 49 checks. What is under test in this file is the installer's handling of its VERDICT.
emit "s#/tmp/zl1-address-owner-proof.sh --yes#$W/proof-answer.sh --yes#g"
emit "s#/tmp/zl1-address-owner-proof.sh#$W/pushed-proof.sh#g"

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
*"cat > "*)
  # A payload arriving on stdin. The default is the honest transport: pass it through untouched (this is
  # the property the installers rely on -- the bytes written are the bytes sent, with no quoting or
  # expansion by the remote shell). FAKE_SSH_SHORT=N makes the transport drop the tail after N bytes,
  # which is the one failure a byte-count read-back exists to catch and which leaves no trace in the
  # file's existence afterwards.
  if [ -n "\${FAKE_SSH_SHORT:-}" ]; then
    f=\$cmd; f=\${f#*cat > }; f=\${f%% *}; f=\$(printf '%s' "\$f" | tr -d "'")
    head -c "\$FAKE_SSH_SHORT" > "\$f"
    exit 0
  fi ;;
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
# The pids the applier DECIDED to signal: the `matched=` field of the retirement line, and nothing else.
# "Not matched" has to be asserted against the decision, not against the whole output -- the same line
# carries `uptime=Ns` (a number no scenario controls) and a pid is three digits, so a substring test over
# the output says "no" or "yes" depending on what the clock read. That is the check this helper replaced.
matched_pids() { applier_log | sed -n 's/.*matched= //p' | grep -o '\[[0-9]*:' | tr -d '[:' | tr '\n' ' ' | sed 's/ $//'; }
# Everything the fake device holds, so "wrote nothing" is checkable rather than asserted from a log.
snap()     { find "$FR" -printf '%p %s\n' 2>/dev/null | sort; }

# $1 = script, rest = args. Output in $OUT, exit code in $RC. FAKE_ADDR is what the fake device's
# rndis0 would answer, so a scenario that wants "no address" sets it to none and calls env_reset after.
RUN_ADDR=yes; RUN_ADB_SERIAL=33e80afe
# The replacement, as it is on a device where the netwatch was installed. Kept as a copy so a scenario
# can take it away and put it back; every scenario starts from the installed state, because that is the
# only state in which "it kills" is the interesting answer.
cp "$FR/etc/systemd/system/zl1-netwatch.sh" "$W/netwatch.good"
# The value `systemctl show -p ExecMainStartTimestampMonotonic` reports, in microseconds since boot.
# Seeded to a process that started 5 s after boot -- EARLIER than this fake device's uptime (100.0 s) --
# so it means "the running process is a survivor of the previous build" and the `--activate` check must
# fail on it. Only a stub restart moves it forward. Defaulting to the passing case would be a fixture
# that agrees with the check for no reason (docs 114 section 6).
printf '5000000\n' > "$W/netwatch-mono"
netwatch_mode() { # installed | absent | no-ensure | inactive
  rm -f "$W/netwatch-inactive"
  case "$1" in
  installed) cp "$W/netwatch.good" "$FR/etc/systemd/system/zl1-netwatch.sh"
             chmod 0755 "$FR/etc/systemd/system/zl1-netwatch.sh" ;;
  absent)    rm -f "$FR/etc/systemd/system/zl1-netwatch.sh" ;;
  no-ensure) # an older build: it brings the interface up, but nothing RE-ASSERTS the addresses --
             # which is exactly the build install-netwatch-service.sh refuses to land (docs 88).
             printf '#!/bin/sh\n# older build: no ensure_addrs()\nbring_up() { ip link set "$1" up; }\n' \
               > "$FR/etc/systemd/system/zl1-netwatch.sh"
             chmod 0755 "$FR/etc/systemd/system/zl1-netwatch.sh" ;;
  inactive)  touch "$W/netwatch-inactive" ;;
  esac
}
# What the proof ANSWERS. The proof's own behaviour is covered by its own harness (49 checks); what is
# under test here is the installer's handling of the verdict, so the answer is a fixture. `obtained` is
# the default because that is the state a device must be in for a retirement to be licensed at all.
proof_answer() { # obtained | unclear | failed | not-armed | explode
  case "$1" in
  obtained)  printf '#!/bin/sh\nprintf "== verdict: proof-obtained\\n"\nexit 0\n' > "$W/proof-answer.sh" ;;
  unclear)   printf '#!/bin/sh\nprintf "== verdict: proof-unclear (exit 1)\\n"\nexit 1\n' > "$W/proof-answer.sh" ;;
  not-armed) printf '#!/bin/sh\nprintf "== verdict: not armed\\n"\nexit 2\n' > "$W/proof-answer.sh" ;;
  # The shape that makes the installer's check a check: it exits 0 and it says `proof-obtained`, but
  # NOT on the verdict line. A gate written as `grep -q proof-obtained` passes this; one written against
  # the exact line `== verdict: proof-obtained` does not. (Same lesson as the drill that asked a guard
  # for a string in neither version of a file -- docs 110.)
  explode)   printf '#!/bin/sh\nprintf "ran to the end without a verdict line; proof-obtained is what we wanted\\n"\nexit 0\n' > "$W/proof-answer.sh" ;;
  esac
  chmod 0755 "$W/proof-answer.sh"
}
# A scenario starts from a BOOT, and on this device that means the ramdisk has just started the keeper.
# So the reset recreates it rather than leaving whatever the previous scenario did to it -- which is a
# real defect this harness grew into: several scenarios KILL the keeper, and every scenario after the
# first one that did was measuring a device where the keeper had already been retired. (The two hand-
# written `env_reset; keeper_proc 900` pairs below were papering over exactly that.)
#
# NMODE is the fake device's netwatch state, and it is a variable rather than a constant because TWO
# sections of this file disagree about it -- and both are right. The retirement's gate asks whether the
# netwatch is deployed, so a boot where the answer is yes is the only one where "it kills" is the
# interesting outcome; the netwatch installer's own section asserts that it wrote NOTHING before --yes
# --ssh, which is only checkable on a device where nothing has deployed one. They write into the same
# directory ($FR/etc/systemd/system) because on the real device they are the same directory. Section 13
# sets NMODE=absent for exactly that reason, and nothing after it uses the retirement.
NMODE=installed
env_reset() {
  RUN_ADDR=yes; RUN_ADB_SERIAL=33e80afe; RUN_SSH_SHORT=""
  rm -f "$W/restart" "$W/active-retire"
  # The `--activate` fixtures. `netwatch-mono` is not optional state: a scenario that leaves a LATER
  # value behind would make the next scenario's "the process started after the restart" check pass for
  # a reason that has nothing to do with the script. It is reset to the value of a process that started
  # before this boot's uptime would allow -- i.e. a survivor -- so the default is the FAILING case and
  # a scenario has to earn the passing one by actually restarting.
  rm -f "$W/netwatch-stale" "$W/netwatch-nomono"
  printf '5000000\n' > "$W/netwatch-mono"
  rm -rf "$W/killignore"; mkdir -p "$W/killignore"
  rm -rf "$FR/proc"/9*
  keeper_proc 900
  netwatch_mode "$NMODE"
  proof_answer "${PANS:-obtained}"
}
run() {
  s="$1"; shift
  : > "$ACT"
  OUT=$(PATH="$STUB:$PATH" FAKE_ADDR="$RUN_ADDR" FAKE_ADB_SERIAL="$RUN_ADB_SERIAL" \
        FAKE_SSH_SHORT="${RUN_SSH_SHORT:-}" \
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
# The gate that CAN fail gets the same treatment as the one that cannot: --status has to be able to say
# "this device could not do the keeper's job", because that is the answer that decides whether the kill
# is licensed. Before docs 114 the applier had no such condition and --status had nothing to report.
want '== the REPLACEMENT' "$OUT" "--status asks the question the kill actually turns on"
want 'ensure_addrs\(\): present' "$OUT" "and finds the function in the deployed build"
want 'zl1-netwatch.service: active' "$OUT" "and that the replacement is running"
netwatch_mode absent
run "$RK" --status
want 'zl1-netwatch.sh: ABSENT' "$OUT" "with nothing deployed it says ABSENT, not silence"
want 'the gate refuses' "$OUT" "and says what that means for the kill"
netwatch_mode installed

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
# "the only two files it added" -- measured as a DIFFERENCE, not as a total. The total was equal to 2
# only while this directory happened to hold nothing else, and this harness now puts the REPLACEMENT
# there ($FR/etc/systemd/system/zl1-netwatch.sh, the thing the applier's gate asks about -- and on the
# real device it is the same directory, which is why the collision is real rather than an artefact).
# A total that is really "nothing else is here yet" is not a check on the installer.
find "$FR/etc/systemd/system" -type f | sort > "$W/eedir.before"
run "$RK" --install
printf '%s\n' "$OUT" > "$W/out.rk.install"
[ "$RC" = 0 ] && ok "retire --install exits 0" || bad "retire --install exited $RC"
RKS="$FR/etc/systemd/system/zl1-retire-debug-keeper.sh"
RKU="$FR/etc/systemd/system/zl1-retire-debug-keeper.service"
[ -f "$RKS" ] && ok "it wrote the applier" || bad "no applier at $RKS"
[ -f "$RKU" ] && ok "it wrote the unit" || bad "no unit at $RKU"
find "$FR/etc/systemd/system" -type f | sort > "$W/eedir.after"
comm -13 "$W/eedir.before" "$W/eedir.after" > "$W/eedir.added"
[ "$(grep -c . "$W/eedir.added")" = 2 ] && ok "and exactly two files were added by this run" \
  || { bad "it added $(grep -c . "$W/eedir.added") files:"; sed 's/^/        | /' "$W/eedir.added"; }
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
    -e "s#/etc/systemd/system/zl1-netwatch.sh#$FR/etc/systemd/system/zl1-netwatch.sh#g" \
    -e "s#/proc/uptime#$FR/proc/uptime#g" \
    -e "s#kill -#$STUB/kill -#g" \
    "$RKS" > "$W/applier/zl1-retire-debug-keeper.sh"
APPLIER=$W/applier/zl1-retire-debug-keeper.sh
sh -n "$APPLIER" || { echo "the rewritten applier does not parse" >&2; exit 2; }
# /proc/uptime was missing from this list, and it is the one that bit: the applier's retirement line
# prints `uptime=$(cut -d. -f1 /proc/uptime)s`, so it was printing the HOST's uptime -- 26 days on this
# machine -- into a log the assertions read. Nothing in the applier branches on it (it is a log field,
# not a gate), so no scenario was judged on a wrong clock; what it broke was an ASSERTION. `notwant
# '904' "$OUT"` searched the whole output for three digits, and a host uptime that happens to contain
# them fails it: at 22904xx the string is there and the check is red for 100 s out of every 1000, with
# nothing wrong on the device. (It was green in every earlier family run and red on this one.) Both
# halves are fixed: the copy now reads the fake device's uptime, and the pid assertions read the
# `matched=` field instead of the whole output.
grep -qF "$FR/proc/[0-9]*" "$APPLIER" && grep -qF "$FR/proc/\$p/" "$APPLIER" \
  && grep -qF "$FR/proc/uptime" "$APPLIER" \
  || { echo "the applier rewrite did not land" >&2; exit 2; }
# The replacement's path is a gate condition now, so an unmapped one would point the check at the
# HOST's /etc/systemd/system -- where there is no netwatch, making every kill scenario a refusal for a
# reason that has nothing to do with the script under test. This is a CHECK and not a setup abort: a
# build without the replacement gate at all (i.e. the pre-fix installer) has no such path to map, and
# aborting here would mean the harness could never be run against the defect it was written for -- the
# one thing that shows the harness has teeth (docs 107: an instrument that cannot be pointed at the
# broken build cannot report on it).
grep -qF "$FR/etc/systemd/system/zl1-netwatch.sh" "$APPLIER" \
  && ok "the applier's replacement check was mapped into the fake root" \
  || bad "the applier has no netwatch path in the fake root -- the replacement gate is absent from this build (or the rewrite did not land)"
grep -qE '^NETWATCH=/etc/systemd/system/' "$APPLIER" \
  && bad "a device-absolute netwatch path survived the rewrite -- the gate would read the HOST's /etc" \
  || ok "and no device-absolute copy of it survived the rewrite"
grep -qF "$STUB/kill -TERM" "$APPLIER" || { echo "the kill rewrite did not land" >&2; exit 2; }
grep -qE '(^|[^-/])kill -' "$APPLIER" && grep -vE "^ *#" "$APPLIER" | grep -qE '(^|[^-/])kill -' \
  && { echo "a bare kill - survived the rewrite, which would signal a real host pid" >&2; exit 2; }
[ "$(grep -c '^#!/bin/sh$' "$APPLIER")" = 1 ] \
  || { echo "the applier rewrite disturbed the shebang" >&2; exit 2; }

# ==================================================================================================
echo
echo "== 2b. THE LICENCE: --now cannot be reached without the proof =="
# ==================================================================================================
# The applier's address test cannot fail (the keeper is what puts the address there), so the question
# "may this boot lose the keeper" has to be answered by a measurement instead: stop the keeper, take an
# address away, and require the netwatch to put it back and say so. That is what --after-proof runs, and
# the point of these four scenarios is that the flag is REQUIRED -- not that the proof works, which its
# own 49-check harness covers.
env_reset
BEFORE=$(snap)
run "$RK" --install --now
printf '%s\n' "$OUT" > "$W/out.rk.now.nolicence"
[ "$RC" = 2 ] && ok "--now without --after-proof exits 2 (a refusal, not a failed attempt)" || bad "it exited $RC"
want 'refusing --now without --after-proof' "$OUT" "and says so in those words"
want '\-\-after-proof' "$OUT" "naming the flag that licenses it"
want 'the keeper is what puts the address there' "$OUT" "and explaining why the applier's own address test cannot be the gate"
want 'install-retire-debug-keeper.sh --install --now --after-proof' "$OUT" "and printing the exact command that would work"
# POSIX sh: no process substitution. `diff <(...) <(...)` is a bashism -- this file is `#!/bin/sh`, and
# the sibling harness died on its own line 126 for exactly this.
printf '%s\n' "$BEFORE" > "$W/snap.before"
snap > "$W/snap.after"
if [ "$(snap)" = "$BEFORE" ]; then
  ok "and it changed NOTHING on the device -- not the unit, not the keeper"
else
  bad "the refusal touched the device:"
  diff "$W/snap.before" "$W/snap.after" | sed 's/^/        | /' | head -6
fi
[ -d "$FR/proc/900" ] && ok "the keeper is still there" || bad "the keeper was killed by a refused call"
[ -z "$(syswrite)" ] && ok "and no systemd call that changes anything was made" || { bad "it called systemd to change state:"; syswrite | sed 's/^/        | /'; }
[ -z "$(kills)" ] && ok "and no signal" || bad "it signalled something"

echo
echo "   -- --after-proof without --now is also refused, because nothing else here kills anything:"
env_reset
BEFORE=$(snap)
run "$RK" --install --after-proof
[ "$RC" = 2 ] && ok "it exits 2" || bad "it exited $RC"
want 'only means anything with --now' "$OUT" "and says why"
[ "$(snap)" = "$BEFORE" ] && ok "and changed nothing" || bad "it changed the device"

echo
echo "   -- the proof is PUSHED (the real bytes) and its verdict is what decides:"
env_reset
run "$RK" --install --now --after-proof
[ "$RC" = 0 ] && ok "proof-obtained: the call exits 0" || bad "it exited $RC"
[ -f "$W/pushed-proof.sh" ] && ok "the proof script was pushed to the device" || bad "no proof was pushed"
cmp -s "$W/pushed-proof.sh" "$HERE/../device/zl1-address-owner-proof.sh" \
  && ok "and the bytes pushed are the repo's own proof script, unaltered" \
  || bad "the pushed payload is not the proof script"
want 'verdict: proof-obtained' "$OUT" "the verdict the proof gave is shown to the operator"
want '^systemctl start zl1-retire-debug-keeper\.service' "$(sysacts)" "and only then is the unit started"
[ ! -d "$FR/proc/900" ] && ok "so the keeper is retired" || bad "the keeper survived"

echo
echo "   -- a proof that does not come back proof-obtained must NOT license the kill:"
env_reset; proof_answer unclear
run "$RK" --install --now --after-proof
[ "$RC" = 1 ] && ok "proof-unclear: it exits 1" || bad "it exited $RC"
want 'REFUSING the kill' "$OUT" "it says it is refusing the kill"
want 'verdict: proof-unclear' "$OUT" "and shows the verdict it is refusing on"
notwant '^systemctl start zl1-retire-debug-keeper\.service' "$(sysacts)" "the unit is NOT started"
[ -d "$FR/proc/900" ] && ok "the keeper is still running -- a core is worth less than the link" || bad "it killed the keeper anyway"
[ -z "$(kills)" ] && ok "and nothing was signalled" || bad "it signalled something"

echo
echo "   -- and 'not armed' (exit 2) is a refusal too, not a pass:"
env_reset; proof_answer not-armed
run "$RK" --install --now --after-proof
[ "$RC" = 1 ] && ok "not-armed: the call fails rather than proceeding" || bad "it exited $RC"
[ -d "$FR/proc/900" ] && ok "and the keeper is still there" || bad "it killed the keeper"
notwant '^systemctl start zl1-retire-debug-keeper\.service' "$(sysacts)" "the unit was not started"

echo
echo "   -- the string in the wrong place: exit 0 and the words, but no verdict line"
# This is the fixture that makes the check a check. A gate written as `grep -q proof-obtained` passes
# this; one written against the verdict LINE does not. (The other harness in this repo learned the same
# thing about a gate asking for a string in neither version of a file -- docs 110/112.)
env_reset; proof_answer explode
run "$RK" --install --now --after-proof
[ "$RC" = 1 ] && ok "the sentence without the verdict does NOT license the kill" || bad "it exited $RC -- it was fooled by a substring"
[ -d "$FR/proc/900" ] && ok "and the keeper is still running" || bad "it killed the keeper"
notwant '^systemctl start zl1-retire-debug-keeper\.service' "$(sysacts)" "the unit was not started"

# ==================================================================================================
echo
echo "== 2c. the gate that CAN fail: the replacement must be deployed and running =="
# ==================================================================================================
# This is the defect this section exists for. The applier's address test cannot fail -- the keeper's own
# 1 Hz loop is what puts the address on the interface, so while the keeper is alive (which is every boot
# a kill can happen on) the address is there BECAUSE OF the process being removed. The only gate that
# can distinguish "the netwatch can do this job" from "the keeper is doing it right now" is the one that
# asks about the replacement. And the refusal has to be LOUD: an unarmed heat fix that logs a line and
# exits 0 is the failure docs 99 names, so it exits 1 and the unit lands in `systemctl --failed`.
#
# Every scenario here has an ADDRESS PRESENT. That is the point: the old gate is satisfied, and the
# refusal has to come from somewhere else.

echo
echo "   -- nothing deployed the replacement (the netwatch was never installed):"
env_reset; netwatch_mode absent
RUN_ADDR=yes
runsh "$APPLIER"
printf '%s\n' "$OUT" > "$W/out.rk.noreplacement"
[ "$RC" = 1 ] && ok "the applier exits 1 -- a FAILED unit, not a log line (docs 99)" || bad "it exited $RC"
want 'NOT ARMED' "$(applier_log)" "and says the heat fix is not armed, in those words"
want 'nothing on this device would re-create the addresses' "$(applier_log)" "naming the consequence"
notwant 'REFUSING' "$(applier_log)" "it is NOT the address gate that refused -- that gate is satisfied here"
[ -d "$FR/proc/900" ] && ok "the keeper is still running" || bad "it killed the keeper"
[ -z "$(kills)" ] && ok "and nothing was signalled" || bad "it signalled something"
[ -z "$(grep -E '^systemctl mask' "$ACT")" ] && ok "and it did not even mask the unit -- the gate is before that" \
  || bad "it masked the unit before refusing"

echo
echo "   -- an OLDER build: the script is deployed, but it has no ensure_addrs():"
# The exact build install-netwatch-service.sh refuses to land (docs 88) -- and the same question asked
# at the other end of the device's life.
env_reset; netwatch_mode no-ensure
runsh "$APPLIER"
[ "$RC" = 1 ] && ok "it refuses an older build too" || bad "it exited $RC"
want 'NOT ARMED' "$(applier_log)" "with the same sentence"
[ -d "$FR/proc/900" ] && ok "and the keeper is still running" || bad "it killed the keeper"

echo
echo "   -- deployed and carrying the function, but NOT RUNNING:"
env_reset; netwatch_mode inactive
runsh "$APPLIER"
[ "$RC" = 1 ] && ok "an inactive netwatch is not a replacement" || bad "it exited $RC"
want 'NOT ARMED' "$(applier_log)" "and it is the same refusal"
[ -d "$FR/proc/900" ] && ok "keeper still running" || bad "it killed the keeper"

echo
echo "   -- and through the real path (--install --now --after-proof), the refusal reaches the operator:"
env_reset; netwatch_mode absent
run "$RK" --install --now --after-proof
[ "$RC" = 0 ] && ok "the install itself still exits 0 -- the files landed, the unit is enabled" || bad "it exited $RC"
[ -d "$FR/proc/900" ] && ok "but the keeper is alive, so nothing was retired" || bad "it killed the keeper"
want 'NOT ARMED' "$OUT" "and the operator sees WHY, in the installer's own output"
[ -f "$RKS" ] && ok "the applier is on the device, so the next boot runs the gate again" || bad "no applier was installed"

echo
echo "   -- the replacement in place: the same call retires it (so the gate is not just a wall):"
env_reset; netwatch_mode installed
runsh "$APPLIER"
[ "$RC" = 0 ] && ok "with the replacement deployed and active it proceeds" || bad "it exited $RC"
[ ! -d "$FR/proc/900" ] && ok "and retires the keeper" || bad "the keeper survived"
want 'keeper retired for this boot' "$(applier_log)" "reporting the retirement"

# ==================================================================================================
echo
echo "== 3. the refusal gate: without an address it must NOT kill =="
# ==================================================================================================
env_reset
RUN_ADDR=none
run "$RK" --install --now --after-proof
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
run "$RK" --install --now --after-proof
want 'REFUSING' "$(applier_log)" "a build whose gate does not recognise the address that IS there refuses too"
[ -d "$FR/proc/900" ] && ok "and leaves the keeper alone" || bad "it killed the keeper anyway"
cp "$W/keep-applier" "$APPLIER"

# ==================================================================================================
echo
echo "== 4. with an address: it kills, it verifies, and it says which failure it is =="
# ==================================================================================================
env_reset
run "$RK" --install --now --after-proof
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
run "$RK" --install --now --after-proof
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
run "$RK" --install --now --after-proof
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
env_reset

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
run "$RK" --install --now --after-proof
printf '%s\n' "$OUT" > "$W/out.rk.now.pedantic"
want 'retiring keeper pids=\[900 905\]' "$(applier_log)" "only the two whose ARGV IS the keeper are matched"
# The helper's own emptiness guard FIRST: `notwant` on an empty string passes for the wrong reason, so
# "the decision was exactly these two pids" is asserted before anything is asserted to be absent from it.
want '^900 905$' "$(matched_pids)" "the decision names exactly two pids -- and it is read, not assumed"
notwant '903' "$(matched_pids)" "the shell that merely mentions the path is NOT matched"
notwant '904' "$(matched_pids)" "and neither is the grep"
# and the retirement line's uptime is the FAKE device's, which is the rewrite that was missing: read as
# the host's it printed whatever this laptop's uptime was (docs 121 §5.4).
want 'uptime=100s' "$(applier_log)" "the applier reads the fake device's uptime, not this host's"
notwant 'kill -(TERM|KILL) 1( |$)' "$(kills)" "and pid 1 is never a candidate for a signal"
notwant 'retiring keeper pids=\[1' "$OUT" "and pid 1 is never even matched"
[ -d "$FR/proc/903" ] && ok "the bystander survived" || bad "the bystander was killed"
[ -d "$FR/proc/904" ] && ok "grep survived" || bad "grep was killed"
[ -d "$FR/proc/1" ] && ok "pid 1 survived" || bad "pid 1 was signalled"
[ ! -d "$FR/proc/905" ] && ok "and the real keeper was retired" || bad "the real keeper survived"
rm -rf "$FR/proc/903" "$FR/proc/904" "$FR/proc/905" "$FR/proc/1"
env_reset

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
# From here the fake device is a device where NO netwatch has been deployed yet: that is the only state
# in which "it wrote nothing before --yes --ssh" is a statement about the installer rather than about
# what the rest of this harness left lying around. (See the note on NMODE.)
NMODE=absent
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
# ==================================================================================================
echo
echo "== 14. netwatch over ssh: the same directory through the LIVE bind mount, and no TWRP round trip =="
# ==================================================================================================
# Why this transport exists at all: `install-netwatch-service.sh` was the only unit installer in this
# directory that needed TWRP, and the unit it installs is the one whose `ensure_addrs()` is what makes
# retiring the v63 debug keeper safe -- i.e. the remaining HEAT fix. Every other installer here already
# reaches `/etc/systemd/system` over ssh on a booted device, so the TWRP requirement was buying nothing.
#
# What has to be held to, in order of how badly it fails if it is wrong:
#
#   1. **The path follows the transport.** Over ssh, `/data/system-data/...` is the ANDROID CONTAINER's
#      /data, not UT's userdata -- the same trap as the misc partition path differing between UT and
#      TWRP. A write there looks like success, reports success, and is gone (or worse, is in the wrong
#      filesystem). So the two trees are asserted to be disjoint, in both directions.
#   2. **The replacement is atomic.** The netwatch is very likely RUNNING, and `sh` reads a script from
#      the file as it executes it -- so a `cat > $DEST` would truncate the file under the live watchdog.
#      The assertion is on the recorded commands: the payload goes to `$DEST.new` and is `mv`d into
#      place, and NOTHING writes to `$DEST` directly.
#   3. **The misc backup is required, not taken.** No partition read over ssh (that would be a second
#      implementation of the cross-checked read), and no install at all without a verified one.
#
# The ssh fake device is the same one sections 1-12 use ($FR), which is the point: `/etc/systemd/system`
# there is already a real directory that other units are installed into.
FSD="$FR/etc/systemd/system"
FSH="$FSD/zl1-netwatch.sh"
FUNIT="$FSD/zl1-netwatch.service"

echo
echo "   -- with no verified misc backup it refuses, and says which route takes one:"
rm -rf "$W/misc"
env_reset
run "$NWC" --yes --ssh
printf '%s\n' "$OUT" > "$W/out.nwssh.nomisc"
[ "$RC" = 1 ] && ok "no verified misc backup -> exit 1" || bad "it exited $RC"
want 'refusing: --ssh needs the verified misc backup' "$OUT" "and it refuses by name"
want 'with the adb/TWRP route first' "$OUT" "naming the route that takes one"
[ ! -e "$FSH" ] && ok "and it wrote nothing" || bad "it installed without a misc backup"
want 'transport: ssh' "$OUT" "it says which transport it is using (so a wrong path cannot be silent)"

echo
echo "   -- a device that is not the zl1 is refused before anything is written:"
mkdir -p "$W/misc"; printf 'MISC-CONTENT' > "$W/misc/misc.img"
( cd "$W/misc" && sha256sum misc.img > SHA256SUMS )
mv "$FR/proc/device-tree/compatible" "$W/compatible.away"
rm -f "$FSH"
env_reset
run "$NWC" --yes --ssh
printf '%s\n' "$OUT" > "$W/out.nwssh.notzl1"
[ "$RC" = 1 ] && ok "no msm8996 in the device tree -> exit 1" || bad "it exited $RC"
want 'not the zl1' "$OUT" "and says the device is not the one it was pointed at"
[ ! -e "$FSH" ] && ok "and wrote nothing" || bad "it wrote to a device it had not identified"
mv "$W/compatible.away" "$FR/proc/device-tree/compatible"

echo
echo "   -- --ssh: the script, the unit and both symlinks land in the SSH tree:"
rm -f "$FSH" "$FUNIT"
rm -rf "$FSD/sysinit.target.wants/zl1-netwatch.service" "$FSD/multi-user.target.wants/zl1-netwatch.service"
env_reset
run "$NWC" --yes --ssh
printf '%s\n' "$OUT" > "$W/out.nwssh.install"
[ "$RC" = 0 ] && ok "--yes --ssh exits 0" || bad "it exited $RC"
want 'unit path: /etc/systemd/system$' "$OUT" "it prints the LIVE path it is writing to"
[ -f "$FSH" ] && ok "the script is at the ssh path" || bad "no script at $FSH"
cmp -s "$FSH" "$HERE/../device/zl1-netwatch.sh" \
  && ok "and it is byte-identical to the source (the stdin transport rewrites nothing)" \
  || bad "the installed script differs from the source"
[ -x "$FSH" ] && ok "and it is executable" || bad "not executable"
[ -f "$FUNIT" ] && ok "the unit is there" || bad "no unit"
[ -L "$FSD/sysinit.target.wants/zl1-netwatch.service" ] && ok "the sysinit symlink exists" \
  || bad "no sysinit symlink"
[ -L "$FSD/multi-user.target.wants/zl1-netwatch.service" ] && ok "and the multi-user one" \
  || bad "no multi-user symlink"
want '^ExecStart=/etc/systemd/system/zl1-netwatch\.sh$' "$(cat "$FUNIT")" \
     "ExecStart is the live path, which is what systemd runs on this port"
want '^WantedBy=sysinit\.target$' "$(cat "$FUNIT")" "and it is wanted by sysinit, so it starts before the container"

echo
echo "   -- and the TWRP tree is untouched: the path difference is the whole risk:"
# Section 13 left an install in the TWRP tree, so it is cleared first -- otherwise this asserts that a
# file the PREVIOUS section wrote is still there, which is a check that cannot fail while looking
# exactly like one that can.
rm -f "$NWR/data/system-data/etc/systemd/system/zl1-netwatch.sh" \
      "$NWR/data/system-data/etc/systemd/system/zl1-netwatch.service"
if [ -d "$NWR/data/system-data/etc/systemd/system" ]; then
  [ ! -e "$NWR/data/system-data/etc/systemd/system/zl1-netwatch.sh" ] \
    && ok "nothing was written into the adb/TWRP tree (where it would be the CONTAINER's /data)" \
    || bad "it wrote the script into the TWRP tree as well"
else
  ok "nothing was written into the adb/TWRP tree (it is not even created)"
fi
[ -z "$(grep '^adb ' "$ACT" 2>/dev/null)" ] && ok "and it never called adb" || bad "it used adb in ssh mode"
notwant 'exec-out' "$(grep '^ssh ' "$ACT" 2>/dev/null)" "and it never read a partition over ssh either"

echo
echo "   -- the payload is moved into place, never written onto the live path:"
SSHCMDS=$(grep '^ssh ' "$ACT" 2>/dev/null)
want 'mv -f' "$SSHCMDS" "it moves the new build into place (rename(2), which the running shell cannot see)"
want "cat > .*zl1-netwatch\.sh\.new" "$SSHCMDS" "the payload goes to the .new name first"
notwant "cat > '?$FSD/zl1-netwatch\.sh'?" "$SSHCMDS" "and NOTHING writes to the live path directly (a running sh reads its script from there)"
want 'wc -c' "$SSHCMDS" "it reads the byte count back from the device before believing the transfer"
want 'daemon-reload' "$SSHCMDS" "and reloads systemd, so the 'can systemd see it' check is not answered by the wrong reason"
want 'systemctl cat zl1-netwatch\.service' "$SSHCMDS" "it asks systemctl cat -- the only honest check that a unit is in effect (docs 63)"
want 'found \(systemd parsed it\)' "$OUT" "and reports that systemd parsed it"
notwant 'systemctl (restart|start|stop|enable|disable)' "$SSHCMDS" \
  "it restarts and enables NOTHING: the new build takes effect at the next boot"
want 'was NOT restarted' "$OUT" "and it says so, so nobody reads 'installed' as 'in effect now'"
want 'syncing' "$OUT" "it syncs before the caller reboots (the page-cache hazard the adb path records)"

echo
echo "   -- a transfer that drops bytes is caught on the DEVICE, before it can become the installed build:"
cp "$FSH" "$W/nwssh.good"
rm -f "$FSH"
env_reset
RUN_SSH_SHORT=2000
run "$NWC" --yes --ssh
printf '%s\n' "$OUT" > "$W/out.nwssh.short"
[ "$RC" = 1 ] && ok "a short transfer exits 1" || bad "it exited $RC"
want 'reads back as' "$OUT" "it names both byte counts"
[ ! -e "$FSH" ] && ok "and the live path is untouched" || bad "a short transfer was installed"
[ ! -e "$FSD/zl1-netwatch.sh.new" ] && ok "and the .new file is cleaned up" || bad "a partial .new was left behind"
RUN_SSH_SHORT=""

echo
echo "   -- --ssh --noheal touches the UT-side marker, not the TWRP-side one:"
env_reset
run "$NWC" --yes --ssh --noheal
printf '%s\n' "$OUT" > "$W/out.nwssh.noheal"
[ "$RC" = 0 ] && ok "--ssh --noheal exits 0" || bad "it exited $RC"
[ -e "$FR/userdata/zl1-netwatch-noheal" ] && ok "the marker is at /userdata/zl1-netwatch-noheal" \
  || bad "no marker in the ssh tree"
[ ! -e "$NWR/data/zl1-netwatch-noheal" ] && ok "and not in the TWRP tree" || bad "it used the TWRP path"
want 'record-only mode' "$OUT" "and it says which mode it installed"
env_reset
run "$NWC" --yes --ssh >/dev/null 2>&1
[ ! -e "$FR/userdata/zl1-netwatch-noheal" ] && ok "and a plain --ssh install removes it again (healing on)" \
  || bad "the noheal marker survived a healing install"

echo
echo "   -- --ssh --remove removes exactly its own four paths, and keeps the log:"
env_reset
run "$NWC" --yes --ssh --remove
printf '%s\n' "$OUT" > "$W/out.nwssh.remove"
[ "$RC" = 0 ] && ok "--ssh --remove exits 0" || bad "it exited $RC"
[ ! -e "$FSH" ] && [ ! -e "$FUNIT" ] && ok "the script and unit are gone" || bad "something survived"
[ ! -e "$FSD/sysinit.target.wants/zl1-netwatch.service" ] && ok "and the symlinks" || bad "a symlink survived"
want '/userdata/zl1-netwatch.log is left in place' "$OUT" "and it says the LOG survives: evidence is not configuration"
want 'transport: ssh' "$OUT" "with the ssh path, not the TWRP one"

echo
echo "   -- the argument surface: unknown flags are refused, not ignored:"
run "$NWC" --yes --nope
[ "$RC" = 2 ] && ok "an unknown argument exits 2" || bad "it exited $RC"
want 'unknown argument' "$OUT" "and names it"
run "$NWC" --ssh
printf '%s\n' "$OUT" > "$W/out.nwssh.noyes"
[ "$RC" = 2 ] && ok "and --ssh without --yes is still refused" || bad "it exited $RC"
want 'refusing without --yes' "$OUT" "by the same gate as the adb route"
run "$NWC" --yes --noheal --remove
[ "$RC" = 2 ] && ok "and two MODES at once are refused rather than the last one winning" || bad "it exited $RC"
want 'are different modes' "$OUT" "saying which two"
run "$NWC" --yes --remove --activate
[ "$RC" = 2 ] && ok "the same for --remove --activate (in the other order)" || bad "it exited $RC"

# ==================================================================================================
echo
echo "== 14b. --activate: make the DEPLOYED build the RUNNING one, and PROVE it is =="
# ==================================================================================================
# Why this mode exists: replacing a file does not change a process. After `--ssh` alone the deployed
# build carries `ensure_addrs()` while the process appending to the log is still the old one -- so the
# address-ownership proof would measure the OLD build and the retirement gate would decide on two facts
# about two different objects. Restarting closes that for one ssh round trip instead of one reboot, and
# on this device a reboot is not free: every boot can end in EDL, and leaving EDL takes a finger on the
# power button. The mode is therefore on the critical path of the HEAT fix, which is why it is held to
# the same standard as the rest of this file: "restarted" is not evidence, so it reads the answer back.
#
# The check has to be able to FAIL, and its failure has to mean one thing. It compares the monotonic
# start time of the running main process against the uptime read immediately BEFORE the restart, so
# "later" is a fact about this restart and not about the boot. Both are monotonic, so the device's
# broken wall clock (which already breaks journalctl ordering) is not involved.
echo "   -- --activate without --ssh is refused BEFORE the device probe:"
env_reset
run "$NWC" --yes --activate
[ "$RC" = 2 ] && ok "--activate without --ssh exits 2" || bad "it exited $RC"
want 'there is no systemd to restart' "$OUT" "and gives the reason that is actually wrong"
# The failure mode this avoids: the adb probe runs first and reports "target 33e80afe not visible in
# adb", which is true and about nothing. A refusal that names the wrong cause sends the operator to
# TWRP for a step that was never going to work over adb either.
notwant 'not visible in adb' "$OUT" "and does NOT send the operator to adb for an ssh-only mode"
[ -z "$(grep '^systemctl restart' "$ACT" 2>/dev/null)" ] && ok "and it restarted nothing" || bad "it restarted something"

echo
echo "   -- the deployed build must carry ensure_addrs(), or there is nothing worth activating:"
env_reset
netwatch_mode no-ensure
run "$NWC" --yes --ssh --activate
[ "$RC" = 1 ] && ok "an older build (no ensure_addrs()) -> exit 1" || bad "it exited $RC"
want 'has no ensure_addrs' "$OUT" "naming the function that is missing"
want 'retirement gate asks the file for that function' "$OUT" \
     "and why that is the same question the retirement gate will ask"
[ -z "$(grep '^systemctl restart' "$ACT" 2>/dev/null)" ] && ok "and it did not restart it" || bad "it restarted an unusable build"

echo
echo "   -- nothing deployed at all is refused, by name:"
env_reset
netwatch_mode absent
run "$NWC" --yes --ssh --activate
[ "$RC" = 1 ] && ok "no deployed script -> exit 1" || bad "it exited $RC"
want 'nothing deployed to activate' "$OUT" "and says so"
# NOT the script's own name: the harness runs the rewritten COPY ($W/nw.sh), so the command it prints
# is the copy's path. The flag pair is what identifies the command -- and the pattern deliberately does
# not START with a dash, because `want` hands it straight to grep, which would read it as an option.
want 'yes --ssh' "$OUT" "with the command that would deploy one"

echo
echo "   -- the misc backup is required here too: the thing being STARTED can write that partition:"
env_reset
netwatch_mode installed
mv "$W/misc" "$W/misc.away"
run "$NWC" --yes --ssh --activate
[ "$RC" = 1 ] && ok "no verified misc backup -> exit 1" || bad "it exited $RC"
want 'can write the misc partition' "$OUT" "naming the reason, which is about the service and not the transport"
mv "$W/misc.away" "$W/misc"

echo
echo "   -- the happy path: it restarts, it reads the answer back, and it says what it proves:"
env_reset
netwatch_mode installed
run "$NWC" --yes --ssh --activate
printf '%s\n' "$OUT" > "$W/out.nwssh.activate"
[ "$RC" = 0 ] && ok "--ssh --activate exits 0" || bad "it exited $RC"
want '^systemctl restart zl1-netwatch\.service' "$(sysacts)" "it restarted the unit"
want 'carries ensure_addrs\(\)' "$OUT" "after asking the DEPLOYED file for the function"
want 'started AFTER this restart' "$OUT" "and reports the monotonic comparison it made"
want 'would drop the ssh session' "$OUT" "with the warning about a heal re-enumerating the gadget"
want 'give it ~90 s to settle' "$OUT" "and the settling time, which is SETTLE_SECONDS and not a guess"
want 'zl1-address-owner-proof\.sh --yes' "$OUT" "and hands off to the measurement, which is the licence for the kill"
want 'was .* before' "$OUT" "it reports the state the service was in before it touched it"
# It must not CLAIM more than it measured. The arrangement question -- does the unit start early enough
# on a boot with no keeper -- is not answerable from a running boot, and the mode says so.
want "does NOT prove is that this boot's ARRANGEMENT" "$OUT" \
     "and states what it does not prove, so 'activated' is not read as 'the boot is fixed'"

echo
echo "   -- and the check CAN fail: a restart that did not take must not be reported as a new build:"
env_reset
netwatch_mode installed
touch "$W/netwatch-stale"      # the process is a survivor: its start predates the restart
run "$NWC" --yes --ssh --activate
printf '%s\n' "$OUT" > "$W/out.nwssh.stale"
[ "$RC" = 1 ] && ok "a restart that did not take -> exit 1" || bad "it exited $RC"
want 'BEFORE the restart' "$OUT" "naming the comparison that failed"
want 'survivor of the old build' "$OUT" "and what that means: the deployed build is not what is running"
notwant 'activated: zl1-netwatch.service is active' "$OUT" "and it does NOT claim success"
rm -f "$W/netwatch-stale"

echo
echo "   -- and when the instrument cannot report at all, it must FAIL rather than assume:"
env_reset
netwatch_mode installed
touch "$W/netwatch-nomono"      # `systemctl show -p ExecMainStartTimestampMonotonic` answers nothing
run "$NWC" --yes --ssh --activate
printf '%s\n' "$OUT" > "$W/out.nwssh.nomono"
[ "$RC" = 1 ] && ok "an unreadable start timestamp -> exit 1" || bad "it exited $RC"
want 'cannot read ExecMainStartTimestampMonotonic' "$OUT" "naming the value it could not read"
want 'Not claiming it is' "$OUT" "and refusing to claim what it cannot check (docs 99: an instrument must be able to report)"
notwant 'activated: zl1-netwatch.service is active' "$OUT" "and it does not claim success"
rm -f "$W/netwatch-nomono"

echo
echo "   -- a service that does not come back active is reported as the build's problem, not the restart's:"
env_reset
netwatch_mode installed
touch "$W/netwatch-inactive"
run "$NWC" --yes --ssh --activate
printf '%s\n' "$OUT" > "$W/out.nwssh.dead"
[ "$RC" = 1 ] && ok "it did not come back active -> exit 1" || bad "it exited $RC"
want 'did NOT come back active' "$OUT" "and says what it observed"
want 'A reboot would start the same build' "$OUT" \
     "and that a reboot is not a retry, so nobody spends one finding that out"
rm -f "$W/netwatch-inactive"

echo
echo "   -- the install path still restarts NOTHING: --activate is a separate act, not a new default:"
env_reset
netwatch_mode installed
run "$NWC" --yes --ssh
[ "$RC" = 0 ] && ok "a plain --ssh install still exits 0" || bad "it exited $RC"
notwant '^systemctl (restart|start|stop|enable|disable)' "$ACT" \
  "and it restarts and enables nothing -- replacing a file and restarting a service stay separate"
want 'was NOT restarted' "$OUT" "so the operator still has to ask for it, and is told they must"

# ==================================================================================================
# ==================================================================================================
echo
echo "== 15. lpm-sleep-fix: the THIRD heat fix, and the trial's own verdict is its licence =="
# ==================================================================================================
# What makes this installer different from its four siblings: its licence is not a state of the device,
# it is a LINE IN ANOTHER INSTRUMENT'S ARCHIVED OUTPUT. So the checks come in three groups -- the
# licence (which must refuse on every verdict but one), the two prerequisites that are about the DEVICE
# (the parameter must exist; a panic must not arm EDL, because this fix persists), and the verdict,
# which is read from the device rather than from any command's exit status.
extract_applier "$LPM" APPLIER_EOF "$W/applier/lpm.raw.sh"
# ONE device path, so the rewrite is one substitution -- and it is asserted, because a rewrite that
# matched nothing would leave the applier pointing at the HOST's /sys.
sed -e "s#/sys/module#$FR/sys/module#g" "$W/applier/lpm.raw.sh" > "$W/applier/zl1-lpm-sleep-fix.sh"
sh -n "$W/applier/zl1-lpm-sleep-fix.sh" || { echo "the rewritten lpm applier does not parse" >&2; exit 2; }
grep -qF "$FR/sys/module" "$W/applier/zl1-lpm-sleep-fix.sh" \
  || { echo "the lpm applier rewrite did not land -- it would write the HOST's /sys" >&2; exit 2; }
cp "$W/applier/zl1-lpm-sleep-fix.sh" "$W/applier/lpm.good.sh"

# The licence file. `lpm_licence` writes one, so each scenario states the VERDICT it is testing rather
# than assembling a file inline and getting its shape subtly wrong.
lpm_licence() { printf '%s\n' "$@" > "$W/trial-out.txt"; printf '%s' "$W/trial-out.txt"; }
# The device's side. `lpm_device` puts the three things a scenario varies back to a known state:
# the parameter (present at 1, absent, or not writable), the panic flag, and the unit's own exit status.
lpm_device() { # present | absent ; armed | disarmed
  rm -rf "$FR/sys/module/lpm_levels"; mkdir -p "$FR/sys/module/lpm_levels/parameters"
  [ "$1" = present ] && printf '1\n' > "$FR/sys/module/lpm_levels/parameters/sleep_disabled"
  printf '%s\n' "$([ "$2" = armed ] && echo 1 || echo 0)" > "$FR/sys/module/msm_poweroff/parameters/download_mode"
  rm -f "$W/lpm-execstatus"
  cp "$W/applier/lpm.good.sh" "$W/applier/zl1-lpm-sleep-fix.sh"
}
lpm_reset() { # the unit and the parameter, as a boot leaves them
  rm -f "$FR/etc/systemd/system/zl1-lpm-sleep-fix.service" "$FR/etc/systemd/system/zl1-lpm-sleep-fix.sh"
  lpm_device present disarmed
  printf '1\n' > "$FR/sys/module/lpm_levels/parameters/sleep_disabled"
}

# --- the licence: every verdict but one forbids the install, and none of them touches the device ----
# "No ssh at all" is the assertion that matters for all five: the licence is read from a file on THIS
# host, so a refused install must not have opened a connection in order to find that out.
for v in refuted not-supported inconclusive confounded; do
  lpm_reset
  L=$(lpm_licence "   -> something about the ladder" "== verdict: $v")
  run "$LPM" --install --after-trial "$L"
  [ "$RC" = 1 ] && ok "licence '$v' refuses with exit 1" || bad "licence '$v' exited $RC"
  want "verdict: $v" "$OUT" "  and the refusal names the verdict it read"
  [ -z "$(grep -E '^ssh ' "$ACT" 2>/dev/null)" ] \
    && ok "  and the device was never contacted -- the licence is read on the host" \
    || bad "  it opened a connection to the device before deciding on the licence"
  [ ! -e "$FR/etc/systemd/system/zl1-lpm-sleep-fix.service" ] \
    && ok "  and nothing was installed" || bad "  a refused licence still wrote the unit"
done
# The shape that makes the whole check a check: a file that CONTAINS the right words and does not have
# the right LINE. A gate written as `grep -q supported-not-proven` passes this one; a gate written
# against the whole line does not. (docs 114's lesson, and the same fixture the proof gate carries.)
lpm_reset
L=$(lpm_licence "a run whose supported-not-proven conclusion is not on a verdict line")
run "$LPM" --install --after-trial "$L"
[ "$RC" = 1 ] && ok "a file that merely CONTAINS the words is refused" || bad "it exited $RC"
[ -z "$(grep -E '^ssh ' "$ACT" 2>/dev/null)" ] && ok "  and still no connection" || bad "  it contacted the device"
# THE LAST LINE IS THE LICENCE, and this pair is the reason: an archive can hold more than one run.
lpm_reset
L=$(lpm_licence "== verdict: supported-not-proven" "== verdict: refuted")
run "$LPM" --install --after-trial "$L"
[ "$RC" = 1 ] && ok "a SUPPORTED that a later REFUTED supersedes is refused" || bad "it exited $RC"
want 'verdict: refuted' "$OUT" "  and it says which reading it refused on"
lpm_reset
L=$(lpm_licence "== verdict: refuted" "== verdict: supported-not-proven")
run "$LPM" --install --after-trial "$L"
# It INSTALLS here, and that is the assertion: the licence gate is what this pair is about, and the same
# device state that was refused a moment ago is accepted the moment the last verdict line says so.
[ "$RC" = 0 ] && ok "and the reverse order is accepted -- the LAST verdict line is the licence" || bad "it exited $RC on a good licence"
[ -f "$FR/etc/systemd/system/zl1-lpm-sleep-fix.service" ] && ok "  and it installed" || bad "  it did not install"
# No file, an unreadable file, and a file with no verdict line. Three different facts, three answers.
lpm_reset
run "$LPM" --install
[ "$RC" = 1 ] && ok "--install with no --after-trial refuses with exit 1" || bad "it exited $RC"
want 'needs --after-trial' "$OUT" "  and says what is missing"
run "$LPM" --install --after-trial "$W/does-not-exist.txt"
[ "$RC" = 1 ] && ok "an unreadable --after-trial refuses with exit 1" || bad "it exited $RC"
want 'cannot be read on this host' "$OUT" "  and says it could not be read"
L=$(lpm_licence "the trial refused on prerequisite C and wrote no verdict")
run "$LPM" --install --after-trial "$L"
[ "$RC" = 1 ] && ok "a file with NO verdict line refuses" || bad "it exited $RC"
want "holds no '== verdict" "$OUT" "  and says a run with no verdict is not a clean run"

# --- the two device prerequisites ------------------------------------------------------------------
# A: the parameter must EXIST. "NOT FOUND" is not "already off": a boot with no such parameter has
# nothing for this fix to write, and reporting that as success is the silent-success shape.
lpm_reset; lpm_device absent disarmed
L=$(lpm_licence "== verdict: supported-not-proven")
run "$LPM" --install --after-trial "$L"
[ "$RC" = 1 ] && ok "no sleep_disabled parameter refuses with exit 1" || bad "it exited $RC"
want 'no /sys/module/\*/parameters/sleep_disabled on the device' "$OUT" "  and says the parameter is not there"
want "not the same thing as 'it is already off'" "$OUT" "  and says why that is not the same as off"
[ ! -e "$FR/etc/systemd/system/zl1-lpm-sleep-fix.service" ] && ok "  and nothing was installed" || bad "  it installed anyway"
# B: a panic must not arm EDL. The trial is scoped to one boot by construction; this installer is not.
lpm_reset; lpm_device present armed
run "$LPM" --install --after-trial "$L"
[ "$RC" = 1 ] && ok "an ARMED download_mode refuses with exit 1 (the trial is one boot, this fix is every boot)" \
  || bad "it exited $RC"
want 'prerequisite A is not met' "$OUT" "  and names the prerequisite"
want 'install-no-edl-on-panic.sh --install' "$OUT" "  and names the command that meets it"
[ ! -e "$FR/etc/systemd/system/zl1-lpm-sleep-fix.service" ] && ok "  and nothing was installed" || bad "  it installed anyway"
# The same state is a READING for --status, which writes nothing and needs no licence.
before=$(snap)
run "$LPM" --status
[ "$RC" = 0 ] && ok "--status on an armed device exits 0 -- a reading is not a decision" || bad "it exited $RC"
want 'NOT met' "$OUT" "  and reports A as not met"
[ "$before" = "$(snap)" ] && ok "  and --status changed nothing on the device" || bad "  --status wrote something"

# --- the happy path, and the verdict read from the DEVICE -------------------------------------------
lpm_reset
L=$(lpm_licence "== verdict: supported-not-proven")
run "$LPM" --install --after-trial "$L"
[ "$RC" = 0 ] && ok "a good licence and a disarmed panic flag installs (exit 0)" || bad "it exited $RC"
printf '%s\n' "$OUT" | grep -qx '== verdict: installed' && ok "  and the verdict is 'installed'" || bad "  the verdict was not 'installed'"
[ -f "$FR/etc/systemd/system/zl1-lpm-sleep-fix.service" ] && ok "  the unit landed" || bad "  the unit did not land"
[ -f "$FR/etc/systemd/system/zl1-lpm-sleep-fix.sh" ] && ok "  and so did the applier" || bad "  the applier did not land"
grep -q 'WantedBy=multi-user.target' "$FR/etc/systemd/system/zl1-lpm-sleep-fix.service" \
  && ok "  the unit is wanted by multi-user.target" || bad "  the unit has no [Install] section"
grep -q 'ExecStart=/etc/systemd/system/zl1-lpm-sleep-fix.sh' "$FR/etc/systemd/system/zl1-lpm-sleep-fix.service" \
  && ok "  and it runs the applier the installer wrote" || bad "  the unit runs something else"
want 'systemctl-ran-applier /etc/systemd/system/zl1-lpm-sleep-fix.sh' "$(cat "$ACT")" "  the applier really ran (the stub runs ExecStart)"
[ "$(cat "$FR/sys/module/lpm_levels/parameters/sleep_disabled")" = 0 ] \
  && ok "  and it wrote 0 to the parameter -- the fix is armed on the fake device" \
  || bad "  the parameter reads $(cat "$FR/sys/module/lpm_levels/parameters/sleep_disabled")"
want 'systemctl enable --now zl1-lpm-sleep-fix.service' "$(cat "$ACT")" "  and the unit was enabled AND started"
# The parameter's `disable` file is one of the four this repository records as writable on the device.
[ "$(cat "$FR/sys/devices/system/cpu/cpu0/cpuidle/state3/disable")" = 0 ] \
  && ok "  and no cpuidle state was disabled -- the ladder's own nodes are not this fix's business" \
  || bad "  something disabled a cpuidle state"
# THE VERDICT IS ABOUT THE DEVICE, NOT ABOUT THE TRANSPORT. Every command above returned 0; the two
# scenarios below are the ones where the DEVICE says something went wrong, and they are why the verdict
# block asks rather than infers.
lpm_reset
printf '1\n' > "$W/lpm-execstatus"
run "$LPM" --install --after-trial "$L"
[ "$RC" = 1 ] && ok "ExecMainStatus != 0 -> exit 1, even though every command returned 0" || bad "it exited $RC"
want '== verdict: not-installed' "$OUT" "  and the verdict is 'not-installed'"
want 'ExecMainStatus' "$OUT" "  and it names the reading that failed"
rm -f "$W/lpm-execstatus"
# The applier runs, exits 0, and the parameter does NOT take the write. This is the defect
# install-cpufreq-governor.sh records, one installer over: the unit is `active` and the phone is as hot
# as it was. The mutation is in the APPLIER ONLY, so the installer's own code is the shipped one.
lpm_reset
sed 's#^    printf 0 > "\$p" 2>/dev/null#    : #' "$W/applier/lpm.good.sh" > "$W/applier/lpm.mut.sh"
grep -q '^    : ' "$W/applier/lpm.mut.sh" || { echo "the lpm applier mutation did not apply" >&2; exit 2; }
cp "$W/applier/lpm.mut.sh" "$W/applier/zl1-lpm-sleep-fix.sh"
run "$LPM" --install --after-trial "$L"
[ "$RC" = 1 ] && ok "a write that does not take -> exit 1 (the applier's own read-back is not enough)" || bad "it exited $RC"
want 'did not read back as OFF' "$OUT" "  and the verdict names the parameter that did not take it"
cp "$W/applier/lpm.good.sh" "$W/applier/zl1-lpm-sleep-fix.sh"

# --- the parameter's TYPE: the applier reads back a STATE, not the string it wrote ------------------
# Three readings of the SAME applier and the SAME fixture, and the middle one is the control:
#
#   1. with the type on (the real shape), the shipped applier succeeds and its message says OFF;
#   2. the PRE-FIX comparison -- `[ "$got" = 0 ]` in place of the `case` -- fails on that same fixture,
#      with the message the device printed on 2026-09-25: "did NOT take 0 (reads 'N')", exit 1;
#   3. with the type OFF (a plain text file, the shape this fixture used to have) the pre-fix applier
#      succeeds -- so the type, and nothing else, is what separates them.
#
# Without (3) this section would be a demonstration of its own setup: a fixture that cannot make two
# behaviours differ cannot test either.
lpm_reset
: > "$ACT"
runsh "$W/applier/zl1-lpm-sleep-fix.sh"
[ "$RC" = 0 ] && ok "with the type on, the applier exits 0 (a bool read-back is not a failure)" || bad "it exited $RC"
want 'OFF on 1 parameter' "$OUT" "  and reports the parameter as OFF, which is what N means"
notwant 'did NOT take' "$OUT" "  and never calls its own good write a failure"
[ "$($REAL_CAT "$FR/sys/module/lpm_levels/parameters/sleep_disabled")" = 0 ] \
  && ok "  and the file holds the raw 0 the applier wrote" \
  || bad "  the file holds $($REAL_CAT "$FR/sys/module/lpm_levels/parameters/sleep_disabled")"

sed 's#^    0|N|n|off) n=\$((n + 1)) ;;$#    0) n=$((n + 1)) ;;#' "$W/applier/lpm.good.sh" > "$W/applier/lpm.prefix.sh"
if cmp -s "$W/applier/lpm.good.sh" "$W/applier/lpm.prefix.sh"; then
  bad "the applier's alphabet mutation did not land (its sed matches no line), so nothing below is pinned"
else
  ok "the applier's alphabet mutation really differs from the shipped applier"
  # THE ORDER IS NOT COSMETIC: `lpm_reset` restores the GOOD applier into $W/applier, so a mutation
  # copied in before it is silently swapped back and the scenario then measures the shipped file while
  # reporting on the mutant. The first version of this block did exactly that and read `it exited 0`.
  lpm_reset
  cp "$W/applier/lpm.prefix.sh" "$W/applier/zl1-lpm-sleep-fix.sh"
  runsh "$W/applier/zl1-lpm-sleep-fix.sh"
  [ "$RC" = 1 ] && ok "the OLD comparison fails the same good write, with exit 1" || bad "it exited $RC"
  want "did NOT take 0 .reads 'N'." "$OUT" "  and says exactly what the device said -- the rendering, named as the fault"
  want 'the heat fix is NOT armed' "$OUT" "  and its exit code makes the unit FAIL on a phone that is fine"
  # The control: no type, and the old comparison is right again.
  lpm_reset
  cp "$W/applier/lpm.prefix.sh" "$W/applier/zl1-lpm-sleep-fix.sh"
  : > "$W/lpm-plain-parameter"
  runsh "$W/applier/zl1-lpm-sleep-fix.sh"
  [ "$RC" = 0 ] && ok "with NO type (a plain text file) the OLD comparison passes too -- the control" \
    || bad "the pre-fix applier exited $RC without a type, so the trio proves nothing"
  rm -f "$W/lpm-plain-parameter"
fi
cp "$W/applier/lpm.good.sh" "$W/applier/zl1-lpm-sleep-fix.sh"

# --- the applier on its own, and --remove -----------------------------------------------------------
# The applier is a real file that runs on the device, so it is run here against the fake root directly.
lpm_reset
: > "$ACT"
runsh "$W/applier/zl1-lpm-sleep-fix.sh"
[ "$RC" = 0 ] && ok "the applier alone exits 0 and writes 0" || bad "the applier exited $RC"
[ "$(cat "$FR/sys/module/lpm_levels/parameters/sleep_disabled")" = 0 ] && ok "  the parameter reads 0" || bad "  it does not"
rm -rf "$FR/sys/module/lpm_levels"
runsh "$W/applier/zl1-lpm-sleep-fix.sh"
[ "$RC" = 1 ] && ok "and with no parameter at all the applier FAILS rather than reporting success" || bad "it exited $RC"
want 'the heat fix is NOT armed' "$OUT" "  and says the heat fix is not armed"
lpm_reset
run "$LPM" --remove
[ "$RC" = 0 ] && ok "--remove exits 0" || bad "--remove exited $RC"
[ ! -e "$FR/etc/systemd/system/zl1-lpm-sleep-fix.service" ] && ok "  the unit is gone" || bad "  the unit is still there"
[ ! -e "$FR/etc/systemd/system/zl1-lpm-sleep-fix.sh" ] && ok "  and the applier is gone" || bad "  the applier is still there"
[ "$(cat "$FR/sys/module/lpm_levels/parameters/sleep_disabled")" = 1 ] \
  && ok "  and the parameter is back to 1 -- the undo is complete on this boot, not only from the next" \
  || bad "  the parameter reads $(cat "$FR/sys/module/lpm_levels/parameters/sleep_disabled")"
# The flag surface.
run "$LPM" --nonsense
[ "$RC" = 2 ] && ok "an unknown flag exits 2" || bad "it exited $RC"
run "$LPM" --explain
[ "$RC" = 0 ] && ok "--explain exits 0 and writes nothing" || bad "it exited $RC"
want 'refuted' "$OUT" "  and names the verdicts it refuses on"
lpm_reset

echo
echo "== the health check cites this harness's count, and that citation cannot drift =="
# The same guard every other harness here carries (docs 110). It is in this file because the health
# check now names it -- it did not, until docs 114: the offline verification of BOTH HALVES OF THE HEAT
# FIX was a harness the page never told anyone to run, which is most of the way to not having it.
HEALTH="$HERE/zl1-health-check.sh"
if [ -r "$HEALTH" ]; then
  cited=$(sed -e 's/always "/ /g' -e 's/"$//' "$HEALTH" | tr '\n' ' ' |
            sed -n 's/.*zl1-installers-selftest\.sh[ ,(]*\([0-9][0-9]*\) checks.*/\1/p')
  total=$((PASS + FAIL + 1))
  if [ -z "$cited" ]; then
    bad "the health check does not cite this harness's count -- either the citation is gone or its wording changed"
  elif [ "$cited" = "$total" ]; then
    ok "the health check cites $cited checks, and this run has exactly that many"
  else
    bad "the health check cites $cited checks, but this harness has $total -- fix host/zl1-health-check.sh"
  fi
else
  bad "cannot read $HEALTH -- its citations are unchecked"
fi

echo
echo "pass=$PASS fail=$FAIL$([ "$SKIP" != 0 ] && echo " skip=$SKIP (a check that COULD NOT run here; see the SKIP line above)")"
[ "$KEEP" = 1 ] || rm -rf "$W"
[ "$FAIL" = 0 ]
