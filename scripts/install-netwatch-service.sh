#!/usr/bin/env bash
# Install the zl1 netwatch service (recorder + self-healer), with the device in TWRP.
#
# Why this route and not the rootfs: the rootfs is mounted read-only at runtime, so
# anything dropped into it vanishes at the next boot. But /etc/systemd/system is one of
# the rootfs's writable-paths, bind-mounted from /userdata/system-data/etc/systemd — so a
# unit file placed there (from TWRP, where userdata is just /data) is persistent and
# takes effect on the next boot. That is code execution at boot without touching the
# rootfs, the ramdisk or any partition.
#
# The service writes /userdata/zl1-netwatch.log and, when it detects the intermittent
# transmit stall, re-asserts the RNDIS gadget. See scripts/device/zl1-netwatch.sh.
#
# TWO TRANSPORTS, and they are not interchangeable -- see below before using --ssh.
#
#   adb (default, the device in TWRP): userdata is a plain /data mount, so the unit goes to
#   /data/system-data/etc/systemd/system. This is the only route that also TAKES the misc backup,
#   because adb can read a partition and this is the last moment before a watchdog that can write
#   `boot-recovery` into misc gets installed.
#
#   --ssh (the device BOOTED, reached over the network): the same directory, but reached through the
#   live bind mount, i.e. /etc/systemd/system. Every other unit installer in this port already goes
#   this way (install-fingerprint-store-dir.sh, install-retire-debug-keeper.sh,
#   hybris-shims/install-container-desabotage.sh, ...), and it removes a whole TWRP round trip from
#   the one change that unblocks retiring the v63 debug keeper -- the heat fix.
#
#   **The path is per-transport and getting it wrong is silent.** Over SSH, BASE=/data/... is the
#   ANDROID CONTAINER's /data, not UT's userdata: the write would land in the container's own
#   filesystem, `adb push`-shaped output would look like success, and the boot would find no unit.
#   (The same shape as the misc partition path differing between UT and TWRP.) So the two are separate
#   variables, chosen by the transport, and each prints the path it is using.
#
#   --ssh REQUIRES a verified misc backup rather than taking one. Reading a raw partition over SSH
#   would be a second implementation of the cross-checked read the adb path already does, and a wrong
#   or truncated backup is worse than none (docs 100) -- so it refuses, by name, with the command that
#   takes one.
#
#   --ssh REPLACES THE SCRIPT OF A RUNNING SERVICE, and does it atomically. `sh` reads a script from
#   the file as it executes it, so a `cat > $DEST` would truncate the file under the live watchdog and
#   let it execute whatever arrived next. The write therefore goes to `$DEST.new`, is verified there,
#   and is moved into place with `mv` (rename(2)): the running shell keeps its descriptor on the old
#   inode and finishes the old build, while the new file appears whole. It is NOT restarted -- the new
#   build takes effect at the next boot, which is the boot that matters.
#
#   --ssh --activate MAKES THE DEPLOYED BUILD THE RUNNING ONE, ON THIS BOOT, AND PROVES IT IS.
#   Replacing a file does not change a process: after `--ssh` alone the deployed build is new and the
#   process writing the log is still the old one, so the address-ownership proof would measure the OLD
#   build and the retirement gate would still refuse. Restarting the unit is what closes that, and it
#   costs one ssh round trip instead of a reboot -- on a device whose every boot can end in EDL and
#   needs a finger on the power button to leave, that is the difference between one boot and two.
#
#   It is a separate mode rather than a flag on the install because replacing a file and restarting a
#   service are different acts with different failure modes, and because a restart is exactly what the
#   install path is designed NOT to do on its own (`sh` reading a script as it runs it).
#
#   "Restarted" is not evidence, so the mode also CHECKS. It reads `/proc/uptime` immediately before
#   the restart and then asks systemd for `ExecMainStartTimestampMonotonic` -- microseconds since boot
#   of when the running main process started -- and requires it to be strictly LATER than the uptime it
#   read. Both are monotonic, so the device's broken wall clock is not involved. Together with the
#   check that the DEPLOYED file carries `ensure_addrs()`, that is decisive: the deployed build has the
#   function, and the running process started after the restart, therefore it read the deployed file.
#   If the value cannot be read the mode FAILS rather than assuming (the instrument must be able to
#   report), and if it is earlier the process is a survivor of the old build and the mode exits 1.
#
#   What it does NOT prove is that this boot's ARRANGEMENT is right -- that the unit starts early
#   enough, before the Android container, to own the addresses without the keeper. Only a boot with no
#   keeper on it can show that (docs 112), and that boot comes last.
#
#   NOTE FOR THE OPERATOR: the freshly started netwatch is allowed to heal, and a heal re-enumerates
#   the USB gadget -- which drops the very ssh session the next step runs over. It never acts before
#   SETTLE_SECONDS (90) and only after 45 s of a frozen TX counter, so the practical rule is: give it
#   ~90 s to settle, then run the proof.
#
# Usage:
#   install-netwatch-service.sh --yes              install and enable (adb, needs TWRP)
#   install-netwatch-service.sh --yes --ssh        install and enable over SSH (device booted)
#   install-netwatch-service.sh --yes --ssh --activate   make the deployed build live on THIS boot
#   install-netwatch-service.sh --yes --remove     disable and delete
#   install-netwatch-service.sh --yes --ssh --remove
#   install-netwatch-service.sh --yes --noheal     install in record-only mode (either transport)
#
# Env: ZL1_HOST (default root@10.15.19.82) for --ssh.

set -euo pipefail

SER="33e80afe"
SRC="/mnt/data/zl1-bb10/scripts/device/zl1-netwatch.sh"
DEV="${ZL1_HOST:-root@10.15.19.82}"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$DEV")

TRANSPORT=adb
MODE=""
# Before the --yes gate on purpose: reading the manual is not an action, and requiring --yes to see the
# usage is how a script's own documentation becomes unreachable.
case "${1:-}" in
--help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0" ; exit 0 ;;
esac
[[ "${1:-}" == "--yes" ]] || { echo "refusing without --yes" >&2; exit 2; }
shift
while [[ $# -gt 0 ]]; do
  case "$1" in
  --ssh) TRANSPORT=ssh ;;
  --remove|--noheal|--activate)
    # One mode at a time. The last one used to win silently, which is how `--remove --noheal` would
    # have read as two harmless flags and acted as one of them; with --activate in the set that stops
    # being cosmetic, so a second mode is refused rather than overwritten.
    [[ -z "$MODE" ]] || { echo "refusing: $MODE and $1 are different modes -- give one" >&2; exit 2; }
    MODE="$1" ;;
  *) echo "unknown argument: $1 (try the header)" >&2; exit 2 ;;
  esac
  shift
done

# The two paths, per transport. Kept as separate assignments rather than one with a branch inside, so
# that `grep BASE=` in this file shows both and the next reader cannot assume one.
if [[ "$TRANSPORT" == "ssh" ]]; then
  BASE="/etc/systemd/system"
else
  BASE="/data/system-data/etc/systemd/system"
fi
DEST="$BASE/zl1-netwatch.sh"
UNIT="$BASE/zl1-netwatch.service"
WANTS_SYSINIT="$BASE/sysinit.target.wants"
WANTS_MULTI="$BASE/multi-user.target.wants"

if [[ "$MODE" == "--activate" && "$TRANSPORT" != "ssh" ]]; then
  # Before the device probe, not after it: probing would fail for a reason that has nothing to do with
  # what is wrong with the invocation ("not visible in adb"), and the real reason is one word long.
  echo "refusing: --activate needs --ssh. In TWRP there is no systemd to restart, and the unit path" >&2
  echo "  there is a mount of a filesystem nothing is running from. Activate on the booted device." >&2
  exit 2
fi

if [[ "$TRANSPORT" == "ssh" ]]; then
  "${SSH[@]}" 'grep -qa msm8996 /proc/device-tree/compatible' 2>/dev/null \
    || { echo "not the zl1 (no msm8996 in /proc/device-tree/compatible), or $DEV is unreachable - refusing" >&2; exit 1; }
  echo "transport: ssh ($DEV); unit path: $BASE"
else
  adb devices 2>/dev/null | awk -v s="$SER" '$1==s{found=1} END{exit found?0:1}' \
    || { echo "target $SER not visible in adb (need TWRP)" >&2; exit 1; }
  echo "transport: adb ($SER, TWRP); unit path: $BASE"
fi

if [[ "$TRANSPORT" == "ssh" && "$MODE" == "--remove" ]]; then
  "${SSH[@]}" "rm -f '$WANTS_SYSINIT/zl1-netwatch.service' '$WANTS_MULTI/zl1-netwatch.service' '$UNIT' '$DEST'"
  echo "removed the netwatch service (the log at /userdata/zl1-netwatch.log is left in place)"
  exit 0
fi

if [[ "$MODE" == "--remove" ]]; then
  adb -s "$SER" shell "rm -f '$WANTS_SYSINIT/zl1-netwatch.service' '$WANTS_MULTI/zl1-netwatch.service' '$UNIT' '$DEST'"
  echo "removed the netwatch service (the log at /data/zl1-netwatch.log is left in place)"
  exit 0
fi

# The local build, and the integrity check on it, are gates on an INSTALL. `--activate` pushes
# nothing -- it restarts a service and reads it back -- so requiring the source tree to be readable
# would be a gate on an unrelated fact (docs 114's shape: ask the question that can answer it).
if [[ "$MODE" != "--activate" ]]; then
  [[ -f "$SRC" ]] || { echo "missing $SRC" >&2; exit 1; }

  # Refuse to install a build that lost functions. `sh -n` cannot catch that, and on
  # 2026-09-19 a build missing five of them was installed and used for a cold boot.
  if [[ -x "$(dirname "$SRC")/../check-netwatch-integrity.sh" ]]; then
    "$(dirname "$SRC")/../check-netwatch-integrity.sh" "$SRC" || { echo "refusing to install: integrity check failed" >&2; exit 1; }
  fi
fi

# The watchdog can ask the bootloader for recovery by writing "boot-recovery" into the
# misc partition, and the healer can toggle the USB gadget. The 2026-06-07 backup set
# has no misc image, so take one before anything could write to that partition.
#
# **An existing image is VERIFIED, not assumed.** The first version skipped this whole block on
# `[[ -f "$MISC_OUT/misc.img" ]]` alone, and nothing ever checked the file's size or hash again -- so a
# run whose `exec-out` produced a 0-byte or truncated image (adb dropped, device unplugged, cat failed)
# would leave a file that satisfies every future run's `-f` test, and `sha256sum` would happily record
# the hash of nothing. That is the one backup of the partition the watchdog *writes into*, and the same
# shape this project has already been bitten by once (the `-exact` backup set, which verifies 31/31
# SHA256 and still cannot be mounted). So: an existing image is accepted only if it is non-empty AND its
# recorded hash still matches; otherwise it is re-taken, which is the safe direction.
MISC_OUT="/mnt/data/zl1-backups/2026-09-17-misc"
MISC_IMG="$MISC_OUT/misc.img"

misc_backup_ok() {
  [[ -s "$MISC_IMG" ]] || { echo "existing misc.img is EMPTY (size $(stat -c%s "$MISC_IMG" 2>/dev/null || echo '?'))" >&2; return 1; }
  [[ -f "$MISC_OUT/SHA256SUMS" ]] || { echo "existing misc.img has no SHA256SUMS to check it against" >&2; return 1; }
  ( cd "$MISC_OUT" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ) \
    || { echo "existing misc.img FAILS its recorded SHA256 (it is not the image it claims to be)" >&2; return 1; }
  return 0
}

# --- --activate: make the DEPLOYED build the RUNNING one, and check that it is --------------------
#
# Replacing a file does not change a process. After `--ssh` the deployed build carries
# `ensure_addrs()` while the process writing the log is still the old one -- so the address-ownership
# proof would measure the OLD build, and the retirement gate (which requires the service to be active
# AND the deployed file to carry the function) would pass on two facts about two different objects.
# A restart closes that, and it is one ssh round trip instead of a reboot.
if [[ "$MODE" == "--activate" ]]; then
  # The transport guard is above, before the device probe.
  # The thing being STARTED can write `boot-recovery` into misc the moment it runs, so the same
  # verified backup the ssh install requires is required here. It is a host-side file check.
  misc_backup_ok || {
    echo "refusing: --activate starts a service that can write the misc partition, and the verified" >&2
    echo "  backup at $MISC_IMG is not usable (above). Take one with the adb/TWRP route:  $0 --yes" >&2
    exit 1
  }
  "${SSH[@]}" "test -f '$DEST'" 2>/dev/null || {
    echo "refusing: $DEST is not on the device -- there is nothing deployed to activate." >&2
    echo "  Install it first:  $0 --yes --ssh" >&2
    exit 1
  }
  # Asking the DEPLOYED file, on the device, the same question the retirement gate asks it. Activating
  # a build without the function would gain nothing: the gate would still refuse, for the same reason.
  "${SSH[@]}" "grep -q '^ensure_addrs()' '$DEST'" || {
    echo "refusing: the deployed $DEST has no ensure_addrs(), so activating it changes nothing -- the" >&2
    echo "  retirement gate asks the file for that function and would refuse either way." >&2
    exit 1
  }
  echo "deployed build: $DEST carries ensure_addrs()"

  # ONE round trip: read the uptime, restart, wait for active, then ask systemd when the running
  # process started. The uptime is read BEFORE the restart, so "started later than that" is a fact
  # about this restart and not about the boot. Both values are MONOTONIC, so the device's wrong wall
  # clock (which journalctl ordering already suffers from) cannot affect the answer.
  ACT_OUT="$("${SSH[@]}" '
    u=$(cut -d" " -f1 /proc/uptime)
    was=$(systemctl is-active zl1-netwatch.service 2>/dev/null || true)
    systemctl restart zl1-netwatch.service 2>&1 || true
    i=0; st=""
    while [ "$i" -lt 30 ]; do
      st=$(systemctl is-active zl1-netwatch.service 2>/dev/null || true)
      [ "$st" = active ] && break
      i=$((i+1)); sleep 1
    done
    mono=$(systemctl show -p ExecMainStartTimestampMonotonic --value zl1-netwatch.service 2>/dev/null)
    pid=$(systemctl show -p MainPID --value zl1-netwatch.service 2>/dev/null)
    echo "was=$was"
    echo "state=$st"
    echo "mono=$mono"
    echo "pid=$pid"
    echo "pre_uptime=$u"
  ' 2>&1 | tr -d '\r')"
  printf '%s\n' "$ACT_OUT" | sed 's/^/  | /'
  fld() { printf '%s\n' "$ACT_OUT" | sed -n "s/^$1=//p" | tail -1; }
  WAS="$(fld was)"; STATE="$(fld state)"; MONO="$(fld mono)"; PRE="$(fld pre_uptime)"

  [[ "$STATE" == "active" ]] || {
    echo "the service did NOT come back active (state=${STATE:-unknown}). It was '$WAS' before." >&2
    echo "  A reboot would start the same build, so this is a property of the build, not of the" >&2
    echo "  restart. Its own output:" >&2
    "${SSH[@]}" "systemctl status zl1-netwatch.service --no-pager -n 20 2>&1" >&2 || true
    exit 1
  }

  # The instrument must be able to report. If systemd will not tell us when the process started, we
  # cannot say the deployed build is the running one -- and saying nothing while claiming success is
  # the defect this whole file's checks exist to avoid (docs 99).
  if ! printf '%s' "$MONO" | grep -qE '^[0-9]+$'; then
    echo "FAILED: cannot read ExecMainStartTimestampMonotonic (got '${MONO:-nothing}'), so there is no" >&2
    echo "  way to tell whether the running process is the deployed build. Not claiming it is." >&2
    exit 1
  fi
  if ! awk -v m="$MONO" -v u="$PRE" 'BEGIN{ exit !(m > u * 1000000) }'; then
    echo "FAILED: the running process started at ${MONO}us, BEFORE the restart (uptime was ${PRE}s)." >&2
    echo "  It is a survivor of the old build, so the deployed build is NOT what is running." >&2
    exit 1
  fi

  echo "activated: zl1-netwatch.service is active, and its main process started AFTER this restart"
  echo "  (monotonic ${MONO}us > uptime ${PRE}s at the restart), so it read the deployed file."
  echo "  was '$WAS' before; nothing else on the device was changed."
  echo
  echo "What it does NOT prove is that this boot's ARRANGEMENT is right -- that the unit starts early"
  echo "  enough, before the Android container, to own the addresses without the keeper. Only a boot with"
  echo "  no keeper on it can show that (docs 112), and that boot comes last."
  echo
  echo "NEXT: give it ~90 s to settle (SETTLE_SECONDS), because a heal re-enumerates the USB gadget and"
  echo "would drop the ssh session the next step runs over. Then measure it, which is also what licenses"
  echo "the keeper's retirement:   scripts/device/zl1-address-owner-proof.sh --yes"
  exit 0
fi

# --- the SSH transport: no TWRP, no partition read, and no window on a running script -------------
if [[ "$TRANSPORT" == "ssh" ]]; then
  # The backup is REQUIRED here, not taken. It is the same requirement the adb path satisfies by
  # reading the partition, and the reason it cannot be skipped is the watchdog being installed, not the
  # transport: this unit can write `boot-recovery` into misc. Taking one over SSH would be a second
  # implementation of that cross-checked read, so the honest move is to require the verified one.
  misc_backup_ok || {
    echo "refusing: --ssh needs the verified misc backup at $MISC_IMG, and it is not usable (above)." >&2
    echo "  Take one with the adb/TWRP route first:  $0 --yes        (device in TWRP)" >&2
    exit 1
  }
  echo "misc backup present and verified: $MISC_IMG ($(stat -c%s "$MISC_IMG") bytes)"

  "${SSH[@]}" "mkdir -p '$BASE' '$WANTS_SYSINIT' '$WANTS_MULTI'" \
    || { echo "cannot create $BASE on the device" >&2; exit 1; }

  # The script goes to $DEST.new, NOT to $DEST: the netwatch is very likely running right now, and a
  # shell reads a script from the file as it executes it. See the header.
  "${SSH[@]}" "cat > '$DEST.new'" < "$SRC" \
    || { echo "the transfer to $DEST.new failed" >&2; exit 1; }
  "${SSH[@]}" "chmod 0755 '$DEST.new'"

  # Read it back from the DEVICE before it is moved into place. A transfer that dropped bytes, or a
  # build without ensure_addrs(), is exactly what docs 88's `heal-first` verdict exists to catch -- and
  # catching it here means it never becomes the installed build at all.
  want_bytes="$(wc -c < "$SRC")"
  got_bytes="$("${SSH[@]}" "wc -c < '$DEST.new'" | tr -d '\r ')"
  [[ "$want_bytes" == "$got_bytes" ]] \
    || { echo "refusing: sent $want_bytes bytes, $DEST.new reads back as ${got_bytes:-nothing}" >&2
         "${SSH[@]}" "rm -f '$DEST.new'"; exit 1; }
  "${SSH[@]}" "grep -q '^ensure_addrs()' '$DEST.new'" \
    || { echo "refusing: the build that landed has no ensure_addrs() -- it cannot configure the addresses" >&2
         "${SSH[@]}" "rm -f '$DEST.new'"; exit 1; }
  echo "verified on the device: $got_bytes bytes, ensure_addrs() present"

  # rename(2): atomic, and the running watchdog keeps its descriptor on the old inode.
  "${SSH[@]}" "mv -f '$DEST.new' '$DEST'"
  got_bytes2="$("${SSH[@]}" "wc -c < '$DEST'" | tr -d '\r ')"
  [[ "$want_bytes" == "$got_bytes2" ]] \
    || { echo "refusing: after the move, $DEST reads back as ${got_bytes2:-nothing}, wanted $want_bytes" >&2; exit 1; }
  echo "installed $DEST ($got_bytes2 bytes)"

  if [[ "$MODE" == "--noheal" ]]; then
    "${SSH[@]}" "touch /userdata/zl1-netwatch-noheal"
    echo "record-only mode: /userdata/zl1-netwatch-noheal present"
  else
    "${SSH[@]}" "rm -f /userdata/zl1-netwatch-noheal"
  fi

  "${SSH[@]}" "cat > '$UNIT'" <<'EOF'
[Unit]
Description=zl1 network watchdog (recorder + RNDIS self-heal)
DefaultDependencies=no
After=local-fs.target
Before=multi-user.target
# The script loops forever by design, so any restart is a bug. Do not let systemd's
# start-limit give up on it and leave the device without a recorder.
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/etc/systemd/system/zl1-netwatch.sh
Restart=always
RestartSec=5
Nice=-5

[Install]
WantedBy=sysinit.target
WantedBy=multi-user.target
EOF

  "${SSH[@]}" "chmod 0644 '$UNIT'
    ln -sf '../zl1-netwatch.service' '$WANTS_SYSINIT/zl1-netwatch.service'
    ln -sf '../zl1-netwatch.service' '$WANTS_MULTI/zl1-netwatch.service'
    ls -l '$DEST' '$UNIT' '$WANTS_SYSINIT/zl1-netwatch.service' '$WANTS_MULTI/zl1-netwatch.service'" | tr -d '\r'

  # The only honest check that systemd can see a unit is `systemctl cat` (docs 63: seventeen drop-ins
  # existed and were never loaded). The unit was written after this boot's own load pass, so without a
  # reload it would legitimately be invisible -- and the report would say so for a reason that has
  # nothing to do with the install having worked.
  "${SSH[@]}" "systemctl daemon-reload" || true
  if "${SSH[@]}" "systemctl cat zl1-netwatch.service >/dev/null 2>&1"; then
    echo "systemctl cat zl1-netwatch.service: found (systemd parsed it)"
  else
    echo "systemctl cat zl1-netwatch.service: NOT FOUND -- systemd does not know this unit" >&2
  fi

  # The caller may reboot immediately, and the same page-cache hazard the adb path records applies here.
  echo "syncing..."
  "${SSH[@]}" "sync" || true

  echo
  echo "installed over ssh. It starts on the next boot and appends to /userdata/zl1-netwatch.log."
  echo "The RUNNING watchdog was NOT restarted: it keeps executing the build it started with, and the"
  echo "new one takes effect at the next boot -- which is the boot whose addresses have to be its job."
  exit 0
fi

if [[ -f "$MISC_IMG" ]] && misc_backup_ok; then
  echo "misc backup already present and verified: $MISC_IMG ($(stat -c%s "$MISC_IMG") bytes)"
else
  mkdir -p "$MISC_OUT"
  MISC_BLK="$(adb -s "$SER" shell 'readlink -f /dev/block/bootdevice/by-name/misc' | tr -d '\r')"
  if [[ -n "$MISC_BLK" && "$MISC_BLK" == /dev/block/* ]]; then
    echo "backing up misc ($MISC_BLK) -> $MISC_IMG"
    adb -s "$SER" exec-out "cat $MISC_BLK" > "$MISC_IMG.tmp"
    # Cross-check the copy against a SECOND, independent read of the same partition: same device, a
    # different round trip. A short read is exactly the failure this whole block exists to survive, and
    # it is invisible to `ls -l` afterwards.
    MISC_DEV_BYTES="$(adb -s "$SER" shell "wc -c < $MISC_BLK" 2>/dev/null | tr -d '\r ')"
    MISC_LOCAL_BYTES="$(stat -c%s "$MISC_IMG.tmp" 2>/dev/null || echo 0)"
    if [[ ! -s "$MISC_IMG.tmp" || -z "$MISC_DEV_BYTES" || "$MISC_LOCAL_BYTES" != "$MISC_DEV_BYTES" ]]; then
      rm -f "$MISC_IMG.tmp"
      echo "refusing to record a misc backup: read $MISC_LOCAL_BYTES bytes, the partition reports ${MISC_DEV_BYTES:-unknown}" >&2
      echo "  (an unverified misc backup is worse than none -- it would satisfy every later run's check)" >&2
      exit 1
    fi
    mv "$MISC_IMG.tmp" "$MISC_IMG"
    ls -l "$MISC_IMG"
    ( cd "$MISC_OUT" && sha256sum misc.img > SHA256SUMS )
    cat "$MISC_OUT/SHA256SUMS"
  else
    echo "warning: could not resolve the misc partition; skipping its backup" >&2
  fi
fi

adb -s "$SER" shell "mkdir -p '$BASE' '$WANTS_SYSINIT' '$WANTS_MULTI'"
adb -s "$SER" push "$SRC" "$DEST"
adb -s "$SER" shell "chmod 0755 '$DEST'"

if [[ "$MODE" == "--noheal" ]]; then
  adb -s "$SER" shell "echo 1 > /data/zl1-netwatch-noheal"
  echo "record-only mode: /data/zl1-netwatch-noheal present"
else
  adb -s "$SER" shell "rm -f /data/zl1-netwatch-noheal"
fi

# DefaultDependencies=no plus After=local-fs.target starts it as soon as the bind mounts
# exist, i.e. before the Android container — which is what the samples need to bracket.
adb -s "$SER" shell "cat > '$UNIT'" <<'EOF'
[Unit]
Description=zl1 network watchdog (recorder + RNDIS self-heal)
DefaultDependencies=no
After=local-fs.target
Before=multi-user.target
# The script loops forever by design, so any restart is a bug. Do not let systemd's
# start-limit give up on it and leave the device without a recorder.
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/etc/systemd/system/zl1-netwatch.sh
Restart=always
RestartSec=5
Nice=-5

[Install]
WantedBy=sysinit.target
WantedBy=multi-user.target
EOF

adb -s "$SER" shell "chmod 0644 '$UNIT'
  ln -sf '../zl1-netwatch.service' '$WANTS_SYSINIT/zl1-netwatch.service'
  ln -sf '../zl1-netwatch.service' '$WANTS_MULTI/zl1-netwatch.service'
  ls -l '$DEST' '$UNIT' '$WANTS_SYSINIT/zl1-netwatch.service' '$WANTS_MULTI/zl1-netwatch.service'" | tr -d '\r'

# The caller reboots immediately after this. If the writes were still in the page cache
# when the reset landed, systemd would come up without the unit and the boot would be
# wasted.
echo "syncing..."
adb -s "$SER" shell "sync" || true

echo
echo "installed. It starts on the next boot and appends to /data/zl1-netwatch.log."
echo "Read it from TWRP with:  scripts/read-netwatch-log.sh"
