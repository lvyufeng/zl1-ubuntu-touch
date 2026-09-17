#!/usr/bin/env bash
# Install the zl1 netdiag sampler as a systemd service, with the device in TWRP.
#
# Why this route and not the rootfs: the rootfs is mounted read-only at runtime, so
# anything dropped into it vanishes at the next boot. But /etc/systemd/system is one of
# the writable-paths, bind-mounted from /userdata/system-data/etc/systemd — so a unit
# file placed there (from TWRP, where userdata is just /data) is persistent and takes
# effect on the next boot. That is code execution at boot without touching the rootfs,
# the ramdisk or any partition.
#
# The script writes to /userdata/zl1-netdiag.log, which is the same partition, so the
# record survives the boot that goes wrong. Read it with scripts/read-netdiag-log.sh.
#
# Usage:
#   install-netdiag-service.sh --yes            install and enable
#   install-netdiag-service.sh --yes --remove   disable and delete

set -euo pipefail

SER="33e80afe"
SRC="/mnt/data/zl1-bb10/scripts/device/zl1-netdiag.sh"
DEST_DIR="/data/system-data/etc/systemd/system"
DEST="$DEST_DIR/zl1-netdiag.sh"
UNIT="$DEST_DIR/zl1-netdiag.service"
WANTS_SYSINIT="/data/system-data/etc/systemd/system/sysinit.target.wants"
WANTS_MULTI="/data/system-data/etc/systemd/system/multi-user.target.wants"

[[ "${1:-}" == "--yes" ]] || { echo "refusing without --yes" >&2; exit 2; }

adb devices 2>/dev/null | awk -v s="$SER" '$1==s{found=1} END{exit found?0:1}' \
  || { echo "target $SER not visible in adb (need TWRP)" >&2; exit 1; }

if [[ "${2:-}" == "--remove" ]]; then
  adb -s "$SER" shell "rm -f '$WANTS_SYSINIT/zl1-netdiag.service' '$WANTS_MULTI/zl1-netdiag.service' '$UNIT' '$DEST'"
  echo "removed the netdiag service (the log at /data/zl1-netdiag.log is left in place)"
  exit 0
fi

[[ -f "$SRC" ]] || { echo "missing $SRC" >&2; exit 1; }

# The sampler can ask the bootloader for recovery by writing "boot-recovery" into the
# misc partition. The 2026-06-07 backup set does not include misc, so take a copy before
# anything could write to it.
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

adb -s "$SER" shell "mkdir -p '$DEST_DIR' '$WANTS_SYSINIT' '$WANTS_MULTI'"
adb -s "$SER" push "$SRC" "$DEST"
adb -s "$SER" shell "chmod 0755 '$DEST'"

# DefaultDependencies=no plus an explicit After=local-fs.target gets it running as early
# as the bind mounts exist — before the Android container, which is what we want to
# bracket. Enabled from both sysinit and multi-user so it starts as early as possible
# and keeps running regardless of which target is reached.
adb -s "$SER" shell "cat > '$UNIT'" <<'EOF'
[Unit]
Description=zl1 network diagnostic sampler
DefaultDependencies=no
After=local-fs.target
Before=multi-user.target

[Service]
Type=simple
ExecStart=/etc/systemd/system/zl1-netdiag.sh
Restart=always
RestartSec=5
Nice=-5

[Install]
WantedBy=sysinit.target
WantedBy=multi-user.target
EOF

adb -s "$SER" shell "chmod 0644 '$UNIT'
  ln -sf '../zl1-netdiag.service' '$WANTS_SYSINIT/zl1-netdiag.service'
  ln -sf '../zl1-netdiag.service' '$WANTS_MULTI/zl1-netdiag.service'
  ls -l '$DEST' '$UNIT' '$WANTS_SYSINIT/zl1-netdiag.service' '$WANTS_MULTI/zl1-netdiag.service'" | tr -d '\r'

echo
echo "installed. It will start on the next boot and append to /data/zl1-netdiag.log."
echo "Read it from TWRP with:  scripts/read-netdiag-log.sh"
