#!/bin/bash
# Final focused SSH fix - edit sshd_config in userdata
set -e
cd /mnt/data/zl1-bb10

echo "=== Final SSH Fix: Edit sshd_config in USERDATA ==="
echo ""

echo "Step 1: Mount userdata"
adb -s 33e80afe shell "mkdir -p /tmpmnt; mount /dev/block/sda10 /tmpmnt 2>&1 && echo MOUNTED"

echo ""
echo "Step 2: Check current sshd_config location"
echo "Checking /tmpmnt/etc/ssh/sshd_config (userdata bind-mount location)..."
adb -s 33e80afe shell "ls -la /tmpmnt/etc/ssh/sshd_config 2>&1"

echo ""
echo "Step 3: Backup current sshd_config"
adb -s 33e80afe shell "cp /tmpmnt/etc/ssh/sshd_config /tmpmnt/etc/ssh/sshd_config.backup 2>&1"

echo ""
echo "Step 4: Check current PermitRootLogin setting"
adb -s 33e80afe shell "grep -i PermitRootLogin /tmpmnt/etc/ssh/sshd_config 2>&1 || echo 'PermitRootLogin not found'"

echo ""
echo "Step 5: Add/modify SSH settings"
adb -s 33e80afe shell "cat >> /tmpmnt/etc/ssh/sshd_config <<'EOF_SSH_CONFIG'

# Added by zl1 SSH fix
PermitRootLogin yes
PubkeyAuthentication yes
PasswordAuthentication yes
EOF_SSH_CONFIG
"

echo ""
echo "Step 6: Verify changes"
adb -s 33e80afe shell "tail -10 /tmpmnt/etc/ssh/sshd_config"

echo ""
echo "Step 7: Unmount"
adb -s 33e80afe shell "sync; sync; umount /tmpmnt 2>&1 && echo UNMOUNTED"

echo ""
echo "=== SSH config modified! ==="
echo "Next: Reboot to fastboot → Boot V63 → Test SSH"
