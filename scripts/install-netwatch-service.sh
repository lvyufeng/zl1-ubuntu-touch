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

# The watchdog can ask the bootloader for recovery by writing "boot-recovery" into the
# misc partition, and the healer can toggle the USB gadget. The 2026-06-07 backup set
# has no misc image, so take one before anything could write to that partition.
MISC_OUT="/mnt/data/zl1-backups/2026-09-17-misc"
if [[ ! -f "$MISC_OUT/misc.img" ]]; then
  mkdir -p "$MISC_OUT"
  MISC_BLK="$(adb -s "$SER" shell 'readlink -f /dev/block/bootdevice/by-name/misc' | tr -d '\r')"
  if [[ -n "$MISC_BLK" && "$MISC_BLK" == /dev/block/* ]]; then
    echo "backing up misc ($MISC_BLK) -> $MISC_OUT/misc.img"
    adb -s "$SER" exec-out "cat $MISC_BLK" > "$MISC_OUT/misc.img"
    ls -l "$MISC_OUT/misc.img"
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
