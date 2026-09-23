#!/usr/bin/env bash
# Retire the v63 debug network keeper -- the second heat source on this port -- without flashing.
#
# Why this exists (docs/ubuntu-touch/72 section 4b, corrected by 94): `/usr/local/sbin/zl1-debug-net.sh`
# is a 1 Hz `/bin/sh` loop. Every second it rewrites `/run/systemd/system/zl1-debug-net.service`, calls
# `systemctl mask --runtime usb-moded.service` and `systemctl stop usb-moded.service`, walks
# `/proc/[0-9]*` in `kill_usb_managers`, forces the RNDIS gadget, and re-configures `usb0`/`rndis0`.
# The measured cost is **a full core** (an A/B with it SIGSTOPped: 1.84 -> 0.87 busy cores) and systemd
# daemon-reloading every ~6 s at ~2 s each; with it stopped, systemd used 1 s of CPU in 300 s and the
# SoC fell 5.5/6.1/2.7 C (tsens1/tsens8/pm8994) while the battery was still charging.
#
# Doc 72's plan for retiring it was: "its unit file is at /etc/systemd/system/zl1-debug-net.service and
# that path is writable, so point ExecStart at our own run-once bring-up". **That plan cannot work, and
# this file exists partly because of why** (docs 94, evidence in
# docs/ubuntu-touch/evidence/debug-keeper-retirement-2026-09-23.log):
#
#   * the v63 boot hook `zl1-postswitch-debug-init` **rewrites both files on every boot** -- the script
#     (`cat > "$ROOT/usr/local/sbin/zl1-debug-net.sh"`, line 313) and the unit
#     (`cat > "$ROOT/etc/systemd/system/zl1-debug-net.service"`, line 632, plus the two
#     `*.target.wants` symlinks at 648-649). `$ROOT="${rootmnt:-/root}"` is the real rootfs, so those
#     are the live paths. Editing either is undone at the next boot.
#   * a drop-in at `/etc/systemd/system/zl1-debug-net.service.d/` **would** survive (the hook does not
#     touch drop-in directories, and `/etc/systemd/system` outranks `/run/systemd/system`) -- but it
#     would not help, because **the systemd instance is not the one that survives.** The same hook also
#     starts the keeper directly, in the background, before systemd exists:
#
#         if [ -x /usr/local/sbin/zl1-debug-net.sh ]; then
#             /usr/local/sbin/zl1-debug-net.sh >/dev/kmsg 2>&1 &
#             log "started zl1 debug network keeper from init wrapper pid=$!"
#
#     (line 1587-1589). The keeper's lock is an atomic `mkdir /run/zl1-debug-net.lock`; the ramdisk
#     instance wins it, and when systemd later starts its own instance that one sees a live primary,
#     logs `keeper duplicate exit v63`, and exits **0** -- so `Restart=on-failure` never fires, and the
#     unit sits `inactive (dead)` for the rest of the boot. That is exactly doc 72's observation that
#     the unit "believed it exited after 67 ms".
#
# So the only retirement that needs no boot image is the one the keeper's own shape leaves open: the
# process is a plain shell script, started by the ramdisk, restarted by nothing, and its lock is
# removed by its own EXIT trap. **Kill it after boot and nothing brings it back** until the next boot.
#
# What makes that safe to do:
#   * the runtime mask that keeps `usb-moded` down is `ln -sfn /dev/null /run/systemd/system/usb-moded.service`
#     -- a `/run` file, so it survives the keeper's death for the rest of the boot. Killing the keeper
#     does not let usb-moded back in.
#   * the addresses are re-asserted by our own `zl1-netwatch.service` on every sample
#     (`ensure_addrs()`, logged as `ADDRS:`) -- installed *before* this, on purpose, so the first boot
#     that proves the new path is a boot where the keeper would have done the job anyway (docs 88).
#   * nothing here is durable in the unsafe direction: a reboot restores the keeper exactly.
#
# **And it refuses to kill when it cannot see an address.** The applier waits for `rndis0`/`usb0` to
# carry one of the two addresses and, if none appears, logs that and leaves the keeper running -- the
# conservative direction. Run `scripts/device/zl1-boot-address-check.sh` first and require the
# `netwatch-configured` verdict (exit 0) on the boot you just looked at; that is the gate doc 88 set.
#
# Installed on the `/etc/systemd/system` writable path (the same one every other unit of this port
# lives on: `/` is a read-only image and `/etc/systemd/system` resolves into the rw `/etc/writable`
# mount):
#
#   /etc/systemd/system/zl1-retire-debug-keeper.sh        the applier (plain shell, idempotent)
#   /etc/systemd/system/zl1-retire-debug-keeper.service   oneshot, after local-fs + the netwatch
#
# Usage: install-retire-debug-keeper.sh [--status] [--install] [--now] [--remove] [--explain]
#   --status   (default) read-only: who started the keeper, where it lives, what the unit says, and
#              whether the two addresses are there
#   --install  install both files and enable the unit. Changes **nothing on this boot**.
#   --now      with --install, also retire it on the current boot (one kill; the boot keeps running)
#   --remove   disable and delete both files. Says out loud that the current boot's keeper stays dead
#              until a reboot, because that is the truth and it is not obvious
#   --explain  print the design and the three things that make it safe; change nothing
#
# Nothing here flashes, writes a partition, or touches the boot image. The persistent writes are one
# shell script and one unit file on the rw /etc path.

set -u

HOST=${ZL1_HOST:-root@10.15.19.82}
SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 $HOST"
D=/etc/systemd/system
RK_SH=$D/zl1-retire-debug-keeper.sh
RK_UNIT=$D/zl1-retire-debug-keeper.service
KEEPER=/usr/local/sbin/zl1-debug-net.sh
UNIT=zl1-debug-net.service
ACTION=--status
WITH_NOW=0

while [ $# -gt 0 ]; do
  case "$1" in
    --status|--install|--remove|--explain) ACTION="$1"; shift ;;
    --now) WITH_NOW=1; shift ;;
    --help|-h) sed -n '2,84p' "$0"; exit 0 ;;
    *) echo "unknown argument $1 (try --help)" >&2; exit 2 ;;
  esac
done

if [ "$ACTION" = --explain ]; then
  cat <<'EXPLAIN'
Retiring the v63 debug keeper, and why it is a kill and not a unit edit.

doc 72 proposed editing /etc/systemd/system/zl1-debug-net.service to point ExecStart at a run-once
bring-up. That cannot work, and the reason is in the boot image:

  1. zl1-postswitch-debug-init REWRITES BOTH FILES EVERY BOOT
       line 313   cat > "$ROOT/usr/local/sbin/zl1-debug-net.sh"
       line 632   cat > "$ROOT/etc/systemd/system/zl1-debug-net.service"
       line 648   ln -sf ../zl1-debug-net.service "$ROOT/etc/systemd/system/sysinit.target.wants/..."
       line 649   ln -sf ../zl1-debug-net.service "$ROOT/etc/systemd/system/multi-user.target.wants/..."
     $ROOT="${rootmnt:-/root}" is the real rootfs, so those are the live paths and any edit is undone.

  2. A DROP-IN WOULD SURVIVE, BUT WOULD NOT HELP
     /etc/systemd/system/zl1-debug-net.service.d/ is not touched by the hook, and /etc/systemd/system
     outranks /run/systemd/system. But the systemd instance is not the survivor: the same hook starts
     the keeper directly, before systemd exists --

       line 1587  if [ -x /usr/local/sbin/zl1-debug-net.sh ]; then
       line 1588      /usr/local/sbin/zl1-debug-net.sh >/dev/kmsg 2>&1 &

     -- and the keeper's lock is an atomic `mkdir /run/zl1-debug-net.lock`. The ramdisk instance wins
     it; systemd's instance sees a live primary, logs `keeper duplicate exit v63`, and exits 0, so
     Restart=on-failure never fires and the unit stays inactive (dead). Hence docs 72's "the unit
     believed it exited after 67 ms".

  3. WHAT IS LEFT IS THE KEEPER'S OWN SHAPE
     It is a plain shell script started by the ramdisk, restarted by nothing, and its EXIT trap removes
     its own lock. Kill it after boot and nothing brings it back until the next boot.

Three things make that safe:
  * the usb-moded suppression is a /run mask (ln -sfn /dev/null /run/systemd/system/usb-moded.service),
    so it outlives the keeper for the rest of the boot;
  * zl1-netwatch.service re-asserts rndis0's addresses every sample (ensure_addrs(), logged as ADDRS:),
    and that was installed before this on purpose;
  * a reboot restores the keeper exactly -- nothing here is durable in the unsafe direction.

The applier waits for an address and refuses to kill if it never sees one. Run
scripts/device/zl1-boot-address-check.sh first and require netwatch-configured (exit 0) on the boot
you just looked at.
EXPLAIN
  exit 0
fi

# ---------------------------------------------------------------------------------------------
# the device-side applier. Plain shell, here-doc, like the other installers in this directory.
# ---------------------------------------------------------------------------------------------
read -r -d '' RK_EOF <<'RK'
#!/bin/sh
# Retire the v63 debug network keeper for THIS boot. Installed by scripts/install-retire-debug-keeper.sh
# -- read that file for why this is a kill and not a unit edit, and for what makes it safe.
#
# It refuses to kill unless rndis0/usb0 carries one of the two addresses: the whole premise is that our
# own netwatch can do the keeper's job, so "no address" means do not proceed. Always exits 0 -- a
# retirement that failed is a log line, not a failed boot.
KEEPER=/usr/local/sbin/zl1-debug-net.sh
UNIT=zl1-debug-net.service
WAIT_S=45
VERIFY_S=30

log() { logger -t zl1-retire-keeper "$*" 2>/dev/null; echo "zl1-retire-keeper: $*"; }

# Deliberately NOT a substring match on the whole cmdline. A shell whose command line merely mentions
# the keeper's path -- somebody running `ps | grep zl1-debug-net.sh`, or this project's own tooling --
# would match a substring test, and killing the wrong process is the one failure mode worth being
# pedantic about. So: argv[1] must BE the path, or argv[0] must be a shell and argv[1] the path.
# (The keeper is started as `/usr/local/sbin/zl1-debug-net.sh &` from the ramdisk, and it has a
# `#!/bin/sh` shebang, so its cmdline is "/bin/sh <path>" -- which is what docs 72's `ps` showed.)
is_keeper_cmdline() {
    set -- $(tr '\000' '\n' < "$1" 2>/dev/null)
    case "${1:-}" in
    "$KEEPER") return 0 ;;
    esac
    case "${1:-}" in
    */sh|*/dash|*/bash|*/busybox|sh|dash|bash|busybox)
        case "${2:-}" in
        "$KEEPER") return 0 ;;
        esac
        ;;
    esac
    return 1
}

keeper_pids() {
    for d in /proc/[0-9]*; do
        [ -d "$d" ] || continue
        p=${d#/proc/}
        [ "$p" = 1 ] && continue
        [ "$p" = "$$" ] && continue
        is_keeper_cmdline "$d/cmdline" && echo "$p"
    done
}

# A shell function's variables are its CALLER's -- there are no locals here. `iface()` used to be
# `for i in rndis0 usb0`, and `has_address()` is called from the wait loop, so the loop's counter was
# left holding the string "rndis0" every time round:
#
#   i=0; while [ "$i" -lt "$WAIT_S" ]; do has_address && break; sleep 1; i=$((i + 1)); done
#
# With rndis0 present -- i.e. always, on this port -- `i=$((i + 1))` is then arithmetic on "rndis0":
# dash prints "Illegal number: rndis0" and **exits the whole script** (status 2), so the applier died
# on its first iteration, before the refusal gate and before the kill, and `--install --now` would have
# reported a failed unit with nothing in the log. With neither interface present it was worse: `iface`
# echoed nothing, `i` became empty, `$(( + 1))` is 1, and the loop never advanced -- a spin at a full
# core, in the one script whose purpose is to give a core back. Found offline by
# scripts/host/zl1-installers-selftest.sh, which is also what keeps it found.
#
# So: every helper's variables are underscore-prefixed, and the counter has a name of its own.
iface() {
    for _i in rndis0 usb0; do
        [ -e "/sys/class/net/$_i" ] && { echo "$_i"; return; }
    done
}

has_address() {
    _if=$(iface)
    [ -n "$_if" ] || return 1
    _live=$(ip -4 addr show dev "$_if" 2>/dev/null | awk '/inet /{printf "%s ", $2}')
    case " $_live " in
    *" 192.168.2.15/24 "*) return 0 ;;
    *" 10.15.19.82/24 "*) return 0 ;;
    esac
    return 1
}

# 1. the gate: an address must exist before we take away the thing that used to provide one.
#    (`_w`, not `i`: see the note on iface() above -- this is the counter a helper used to clobber.)
_w=0
while [ "$_w" -lt "$WAIT_S" ]; do
    has_address && break
    sleep 1
    _w=$((_w + 1))
done
if ! has_address; then
    log "REFUSING: after ${WAIT_S}s neither 192.168.2.15/24 nor 10.15.19.82/24 is on $(iface) -- leaving the keeper running (docs 94)"
    exit 0
fi

# 2. make sure nothing can start it again this boot: the unit is a /run unit with Restart=on-failure,
#    and masking is a /run file too, so it dies with the boot either way.
systemctl mask --runtime "$UNIT" >/dev/null 2>&1 || true

# 3. what we are taking away, measured: the keeper's own CPU ticks, so the effect is checkable later
TICKS=0
# keeper_pids echoes one pid per line, so join them: `log` builds ONE line, and an embedded newline
# would split it into two journal records with the second starting mid-sentence. (Found by
# scripts/host/zl1-installers-selftest.sh, with two keeper processes -- which is the case this log line
# exists to make visible.)
PIDS=$(keeper_pids | tr '\n' ' ')
PIDS=${PIDS% }
CMDS=""
for p in $PIDS; do
    t=$(awk '{print $14 + $15}' "/proc/$p/stat" 2>/dev/null) || t=0
    TICKS=$((TICKS + ${t:-0}))
    c=$(tr '\000' ' ' < "/proc/$p/cmdline" 2>/dev/null)
    CMDS="$CMDS [$p: $c]"
done
if [ -z "$PIDS" ]; then
    log "no $KEEPER process found (unit masked for this boot anyway)"
    exit 0
fi
log "retiring keeper pids=[$PIDS] cpu_ticks_so_far=$TICKS (HZ=$(getconf CLK_TCK 2>/dev/null || echo 100)) uptime=$(cut -d. -f1 /proc/uptime)s matched=$CMDS"

# 4. TERM first: the keeper's EXIT/HUP/INT/TERM trap removes its own lock and exits 0, which is also
#    why systemd would not call this a failure. KILL only what refuses to go.
for p in $PIDS; do kill -TERM "$p" 2>/dev/null; done
sleep 2
survivors=""
for p in $(keeper_pids); do
    case " $PIDS " in
    *" $p "*) survivors="$survivors $p" ;;
    esac
done
for p in $survivors; do
    log "pid $p survived SIGTERM; sending SIGKILL"
    kill -KILL "$p" 2>/dev/null
done
sleep 1

# 5. verify, and be precise about which of the two failures it is -- they have different answers.
#    "a pid from the original set is still there" means the kill did not take; "a pid that was not
#    there before" means something is *starting* the keeper, and then the kill lever is the wrong
#    lever and only a boot-image change retires it (docs 94).
left=""
for p in $(keeper_pids); do
    case " $PIDS " in
    *" $p "*) left="$left $p" ;;
    *) log "something RESTARTED the keeper as pid $p -- SIGKILL was not the problem; the retirement needs a different lever (docs 94)"
       for q in $p; do kill -KILL "$q" 2>/dev/null; done ;;
    esac
done
if [ -n "$left" ]; then
    log "SIGKILL did not take on [$left] -- investigate; this boot is NOT retired (docs 94)"
    exit 0
fi
log "keeper gone; watching ${VERIFY_S}s in case something restarts it"
i=0
while [ "$i" -lt "$VERIFY_S" ]; do
    sleep 5
    back=$(keeper_pids | tr '\n' ' ')
    back=${back% }
    if [ -n "$back" ]; then
        log "keeper CAME BACK as [$back] -- re-killing; if this repeats, the kill lever is insufficient and only a boot-image change retires it (docs 94)"
        for p in $back; do kill -KILL "$p" 2>/dev/null; done
    fi
    i=$((i + 5))
done
if [ -n "$(keeper_pids)" ]; then
    log "keeper is back at the end of the watch; the retirement did NOT hold (docs 94)"
else
    log "keeper retired for this boot; usb-moded stays masked (/run), addresses come from zl1-netwatch.service"
fi
exit 0
RK

case "$ACTION" in
--status)
  $SSH "sh -s" <<STATUS
echo '== the keeper process(es) and who started them'
found=0
for d in /proc/[0-9]*; do
  [ -d "\$d" ] || continue
  p=\${d#/proc/}
  [ "\$p" = 1 ] && continue
  c=\$(tr '\\000' ' ' < "\$d/cmdline" 2>/dev/null || true)
  case "\$c" in
  *$KEEPER*)
    found=1
    ppid=\$(awk '{print \$4}' "\$d/stat" 2>/dev/null)
    pc=\$(tr -d '\\n' < "/proc/\$ppid/comm" 2>/dev/null || echo '?')
    pcmd=\$(tr '\\000' ' ' < "/proc/\$ppid/cmdline" 2>/dev/null || echo '?')
    cg=\$(sed -n 's/^0:://p' "\$d/cgroup" 2>/dev/null | head -1)
    upt=\$(awk '{printf "%d", \$1}' "\$d/stat" 2>/dev/null)
    ticks=\$(awk '{print \$14 + \$15}' "\$d/stat" 2>/dev/null)
    echo "  pid=\$p ppid=\$ppid ppid_comm=\$pc"
    echo "    ppid_cmd=\$pcmd"
    echo "    cgroup=\$cg"
    echo "    cpu_ticks=\$ticks (HZ=\$(getconf CLK_TCK 2>/dev/null || echo 100))"
    ;;
  esac
done
[ "\$found" = 1 ] || echo '  none running'

echo
echo '== the keeper lock (who owns the loop)'
if [ -d /run/zl1-debug-net.lock ]; then
  for f in pid ppid start_uptime ppid_comm ppid_cmdline pid1_comm pid1_cmdline; do
    [ -e "/run/zl1-debug-net.lock/\$f" ] && printf '  %s=%s\n' "\$f" "\$(cat "/run/zl1-debug-net.lock/\$f" 2>/dev/null)"
  done
else
  echo '  no lock directory'
fi

echo
echo '== the unit (systemd'"'"'s instance is expected to be dead: the ramdisk won the lock)'
systemctl show $UNIT -p MainPID -p NRestarts -p Result -p ActiveState -p SubState -p ExecMainStartTimestamp 2>/dev/null | sed 's/^/  /'
echo -n '  is-enabled: '; systemctl is-enabled $UNIT 2>&1 | head -1

echo
echo '== the two files the boot hook rewrites every boot'
ls -l $KEEPER $D/$UNIT 2>&1 | sed 's/^/  /'

echo
echo '== the addresses (the applier'"'"'s gate: it refuses to kill without one of these)'
IF=''
for i in rndis0 usb0; do [ -e "/sys/class/net/\$i" ] && { IF="\$i"; break; }; done
if [ -n "\$IF" ]; then
  live=\$(ip -4 addr show dev "\$IF" 2>/dev/null | awk '/inet /{printf "%s ", \$2}')
  echo "  \$IF: \${live:-<no IPv4>}"
  case " \$live " in *' 192.168.2.15/24 '*) echo '  192.168.2.15/24: present' ;; *) echo '  192.168.2.15/24: MISSING' ;; esac
  case " \$live " in *' 10.15.19.82/24 '*) echo '  10.15.19.82/24: present' ;; *) echo '  10.15.19.82/24: MISSING' ;; esac
else
  echo '  no rndis0/usb0 interface at all'
fi

echo
echo '== our retirement unit'
if [ -f $RK_UNIT ]; then
  systemctl show zl1-retire-debug-keeper.service -p ActiveState -p SubState -p Result -p ExecMainStartTimestamp 2>/dev/null | sed 's/^/  /'
  echo -n '  is-enabled: '; systemctl is-enabled zl1-retire-debug-keeper.service 2>&1 | head -1
else
  echo "  not installed ($RK_UNIT absent)"
fi

echo
echo '== what the boot-address check last said (the gate for installing this)'
if [ -f /etc/systemd/system/zl1-retire-debug-keeper.sh ]; then
  echo '  (installed: re-run scripts/device/zl1-boot-address-check.sh after a reboot and require netwatch-configured)'
else
  echo '  (nothing installed yet: run scripts/device/zl1-boot-address-check.sh first and require exit 0)'
fi
STATUS
  exit 0
  ;;

--install)
  $SSH "cat > $RK_SH" <<RK_APPLIER
$RK_EOF
RK_APPLIER
  $SSH "chmod 0755 $RK_SH; cat > $RK_UNIT" <<'RK_UNIT_EOF'
[Unit]
Description=zl1: retire the v63 debug network keeper for this boot (docs 94)
# DefaultDependencies=no + After=local-fs.target so it starts with the rest of the early units; After
# the netwatch, because the netwatch is what makes the keeper's job redundant, and the applier itself
# waits for an address before it does anything.
DefaultDependencies=no
After=local-fs.target zl1-netwatch.service
Before=multi-user.target
StartLimitIntervalSec=0

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/etc/systemd/system/zl1-retire-debug-keeper.sh
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target
RK_UNIT_EOF
  $SSH "systemctl daemon-reload
    systemctl enable zl1-retire-debug-keeper.service >/dev/null 2>&1
    systemctl daemon-reload
    echo 'installed:'
    ls -l $RK_SH $RK_UNIT
    systemctl is-enabled zl1-retire-debug-keeper.service 2>&1 | head -1" 2>&1 | tail -6
  if [ "$WITH_NOW" = 1 ]; then
    echo
    echo "== --now: retiring the keeper on the CURRENT boot (one kill; the boot keeps running)"
    $SSH "systemctl start zl1-retire-debug-keeper.service; systemctl show zl1-retire-debug-keeper.service -p Result -p ExecMainStatus | sed 's/^/  /'" 2>&1 | tail -4
  else
    echo
    echo "nothing was changed on the current boot. The keeper is retired from the NEXT boot on."
    echo "To retire it now as well: $0 --install --now"
  fi
  exit 0
  ;;

--remove)
  $SSH "systemctl disable zl1-retire-debug-keeper.service >/dev/null 2>&1
    rm -f $RK_UNIT $RK_SH
    systemctl daemon-reload
    systemctl unmask --runtime $UNIT >/dev/null 2>&1
    echo 'removed $RK_SH and $RK_UNIT; the runtime mask of $UNIT is lifted'" 2>&1 | tail -3
  echo
  echo "NOTE: a boot whose keeper was already killed stays keeper-less until the next reboot -- the"
  echo "      process is started by the ramdisk, not by systemd, so nothing restarts it now."
  echo "      The next boot restores it (the boot hook rewrites both files)."
  exit 0
  ;;
esac
