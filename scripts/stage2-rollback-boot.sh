#!/usr/bin/env bash
# Stage 2 rollback — put the original Android boot image back on the device.
#
# Run this if the V63 image does not cold-boot. It restores the boot partition
# to the 2026-06-07 backup, which was verified byte-identical to the boot
# partition the device carried on 2026-09-16, so this returns the device to
# exactly the state it was in before Stage 2.
#
# If fastboot is not reachable, the same image can be written from TWRP:
#   adb -s 33e80afe push boot.img /tmp/boot.img
#   adb -s 33e80afe shell 'dd if=/tmp/boot.img of=/dev/block/bootdevice/by-name/boot'
#
# Usage: stage2-rollback-boot.sh --yes

set -euo pipefail

SER="33e80afe"
IMG="/mnt/data/zl1-backups/2026-06-07-adb-root-staged/boot.img"
SHA="a06d6508499ee37a03effea1e6bec1d04f23843fd44d198a49fb3e07cb5778ef"

[[ "${1:-}" == "--yes" ]] || { echo "refusing without --yes" >&2; exit 2; }

got="$(sha256sum "$IMG" | awk '{print $1}')"
[[ "$got" == "$SHA" ]] || { echo "rollback image hash mismatch: $got" >&2; exit 1; }

for _ in $(seq 1 30); do
  timeout 5 fastboot devices 2>/dev/null | awk -v s="$SER" '$1==s{found=1} END{exit found?0:1}' && break
  sleep 2
done
timeout 5 fastboot devices 2>/dev/null | awk -v s="$SER" '$1==s{found=1} END{exit found?0:1}' \
  || { echo "target $SER not in fastboot" >&2; exit 1; }

timeout 180 fastboot -s "$SER" flash boot "$IMG"
timeout 60 fastboot -s "$SER" reboot || true
echo "rollback flashed; device rebooting into the stock Android boot image"
