#!/bin/bash
set -uo pipefail
TARGET="33e80afe"
V64_IMG="/mnt/data/halium-zl1-candidates/halium-boot-zl1-v64-production-no-android.img"
echo "Re-testing V64 (previously max_stable=4)"
adb -s "$TARGET" reboot bootloader 2>/dev/null || true
sleep 6
if fastboot devices 2>/dev/null | grep -q "$TARGET"; then
    fastboot -s "$TARGET" boot "$V64_IMG"
    echo "V64 booted. Monitoring for 90 seconds..."
    for i in {1..18}; do
        sleep 5
        echo "--- $((i*5))s ---"
        lsusb 2>/dev/null | grep -E "Halium|18d1:d001" && echo "RNDIS present" || echo "no RNDIS"
        ping -c1 -W1 192.168.2.15 >/dev/null 2>&1 && echo "PING OK" || echo "ping fail"
    done
else
    echo "ERROR: fastboot not available"
    exit 1
fi
