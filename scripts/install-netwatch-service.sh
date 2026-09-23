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
# Usage:
#   install-netwatch-service.sh --yes              install and enable (adb, needs TWRP)
#   install-netwatch-service.sh --yes --ssh        install and enable over SSH (device booted)
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
  --remove|--noheal) MODE="$1" ;;
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

[[ -f "$SRC" ]] || { echo "missing $SRC" >&2; exit 1; }

# Refuse to install a build that lost functions. `sh -n` cannot catch that, and on
# 2026-09-19 a build missing five of them was installed and used for a cold boot.
if [[ -x "$(dirname "$SRC")/../check-netwatch-integrity.sh" ]]; then
  "$(dirname "$SRC")/../check-netwatch-integrity.sh" "$SRC" || { echo "refusing to install: integrity check failed" >&2; exit 1; }
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
