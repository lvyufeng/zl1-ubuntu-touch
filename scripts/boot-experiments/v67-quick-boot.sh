#!/bin/bash
set -uo pipefail
TARGET_SERIAL="33e80afe"
BOOT_IMAGE="/mnt/data/halium-zl1-candidates/halium-boot-zl1-v67-from-v63-lxc-masked.img"
echo "V67 quick boot test"
adb -s "$TARGET_SERIAL" reboot bootloader 2>/dev/null || true
echo "Waiting for fastboot..."
sleep 5
fastboot -s "$TARGET_SERIAL" boot "$BOOT_IMAGE"
echo "Booted V67. Monitor manually:"
echo "  watch lsusb"
echo "  ping 192.168.2.15"
echo "  curl http://192.168.2.15:8080"
