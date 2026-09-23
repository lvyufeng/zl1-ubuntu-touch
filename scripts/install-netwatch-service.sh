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
# Usage:
#   install-netwatch-service.sh --yes            install and enable
#   install-netwatch-service.sh --yes --remove   disable and delete
#   install-netwatch-service.sh --yes --noheal   install in record-only mode

set -euo pipefail

SER="33e80afe"
SRC="/mnt/data/zl1-bb10/scripts/device/zl1-netwatch.sh"
BASE="/data/system-data/etc/systemd/system"
DEST="$BASE/zl1-netwatch.sh"
UNIT="$BASE/zl1-netwatch.service"
WANTS_SYSINIT="$BASE/sysinit.target.wants"
WANTS_MULTI="$BASE/multi-user.target.wants"

[[ "${1:-}" == "--yes" ]] || { echo "refusing without --yes" >&2; exit 2; }
MODE="${2:-}"

adb devices 2>/dev/null | awk -v s="$SER" '$1==s{found=1} END{exit found?0:1}' \
  || { echo "target $SER not visible in adb (need TWRP)" >&2; exit 1; }

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
