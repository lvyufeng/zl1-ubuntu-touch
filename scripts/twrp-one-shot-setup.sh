#!/usr/bin/env bash
# One button press, then the device drives itself.
#
# Run this and press Volume Up + Power on the zl1. It waits for TWRP, then:
#   1. backs up the misc partition (the 2026-06-07 set has no misc image)
#   2. installs the netdiag sampler as a persistent systemd unit
#   3. drops the marker that makes the sampler ask the bootloader for recovery
#      after RECOVERY_AFTER seconds, so its log can be read without a button
#   4. reboots into Ubuntu Touch
#
# From then on the cycle is: UT boots and logs -> after RECOVERY_AFTER the
# device returns itself to TWRP -> read the log -> install the next image.
# No further human input is needed unless the device stops booting at all.
#
# Usage: twrp-one-shot-setup.sh [RECOVERY_AFTER_SECONDS]   (default 900)

set -uo pipefail
SER="33e80afe"
RECOVERY_AFTER="${1:-900}"
WAIT_TWRP="${2:-3600}"
ROOT=/mnt/data/zl1-bb10

echo "== waiting up to ${WAIT_TWRP}s for $SER in TWRP =="
echo "   (on the phone: power off, then hold Volume Up + Power)"
deadline=$(( SECONDS + WAIT_TWRP ))
while (( SECONDS < deadline )); do
  st="$(adb devices 2>/dev/null | awk -v s="$SER" '$1==s{print $2}')"
  if [[ "$st" == "recovery" ]]; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) TWRP up"
    break
  fi
  sleep 10
done
adb devices 2>/dev/null | awk -v s="$SER" '$1==s{print $2}' | grep -q recovery \
  || { echo "timed out waiting for TWRP" >&2; exit 1; }

echo "== 1/4 misc backup =="
"$ROOT/scripts/install-netdiag-service.sh" --yes || { echo "install failed" >&2; exit 1; }

echo "== 2/4 marker: recover after ${RECOVERY_AFTER}s =="
adb -s "$SER" shell "echo $RECOVERY_AFTER > /data/zl1-netdiag-reboot-recovery; cat /data/zl1-netdiag-reboot-recovery" | tr -d '\r'

echo "== 3/4 confirm what is in place =="
adb -s "$SER" shell 'ls -l /data/system-data/etc/systemd/system/zl1-netdiag.* /data/system-data/etc/systemd/system/*.wants/zl1-netdiag.service /data/zl1-netdiag-reboot-recovery 2>&1' | tr -d '\r'

echo "== 4/4 rebooting into Ubuntu Touch =="
adb -s "$SER" reboot
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) rebooting; the device should return to TWRP by itself in ~${RECOVERY_AFTER}s"
