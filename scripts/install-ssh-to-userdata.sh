#!/bin/bash
# Install SSH keys to USERDATA (not rootfs) - the correct location!
# Root cause: /root is bind-mounted from userdata at runtime

set -e
cd /mnt/data/zl1-bb10

echo "=== Install SSH keys to userdata (CORRECT location) ==="
echo "Step 1: Mount userdata"
adb -s 33e80afe shell "mkdir -p /tmpmnt; mount /dev/block/sda10 /tmpmnt 2>&1 && echo MOUNTED"

echo ""
echo "Step 2: Create /root/.ssh in USERDATA (not rootfs!)"
adb -s 33e80afe shell "mkdir -p /tmpmnt/root/.ssh; chmod 700 /tmpmnt/root/.ssh"

echo ""
echo "Step 3: Push and install authorized_keys"
adb -s 33e80afe push ~/.ssh/id_ed25519.pub /tmp/key.pub
adb -s 33e80afe shell "cat /tmp/key.pub > /tmpmnt/root/.ssh/authorized_keys; chmod 600 /tmpmnt/root/.ssh/authorized_keys"

echo ""
echo "Step 4: Verify installation"
adb -s 33e80afe shell "ls -la /tmpmnt/root/.ssh/"
adb -s 33e80afe shell "cat /tmpmnt/root/.ssh/authorized_keys"

echo ""
echo "Step 5: Unmount cleanly"
adb -s 33e80afe shell "sync; sync; umount /tmpmnt 2>&1 && echo UNMOUNTED"

echo ""
echo "=== SSH keys installed to USERDATA - should work now! ==="
echo "Next: reboot to fastboot, boot V63, test SSH"
