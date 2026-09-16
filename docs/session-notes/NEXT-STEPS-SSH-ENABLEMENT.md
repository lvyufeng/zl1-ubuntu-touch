# Next Steps: Enable SSH in rootfs for full shell access

## Current Status (2026-06-15)
✅ **PRIMARY GOAL ACHIEVED**: Stable RNDIS network access to zl1 Ubuntu Touch
- Sustained connectivity: 192.168.2.15 + 10.15.19.82, 0% packet loss over 15 min
- Ping working: ~0.25ms latency
- Device proof: systemd=PID1, rndis0 UP continuously, never dropped
- Root cause identified: host-side needed manual rndis_host binding (device was always fine)

## What Still Needs Work
❌ **SSH (port 22) is closed** — sshd not enabled in the rootfs
- Current access: read-only HTTP status on port 8080 only
- Goal: interactive shell via `ssh phablet@10.15.19.82`

## Device Current State
The device completed its V63 keeper run (~15 min, ended at "DONE") and is now
**off or suspended** (not visible on USB). It needs a manual power-button press
to boot into recovery or fastboot.

## Plan to Enable SSH

### Step 1: Boot to recovery/fastboot
**ACTION REQUIRED**: Manually press power button to boot device into recovery
(or hold Vol- for fastboot). Then:
```bash
# Check when it reappears
adb devices          # recovery = adb
fastboot devices     # fastboot mode
```

### Step 2: Mount rootfs and enable sshd
Once in recovery (adb available):
```bash
# Mount userdata + loopback-mount the rootfs
adb shell "mount -t ext4 /dev/block/sda10 /tmpmnt"
adb shell "mkdir -p /mnt/rootfs; mount -o loop /tmpmnt/rootfs.img /mnt/rootfs"

# Enable sshd.service
adb shell "ln -sf /lib/systemd/system/ssh.service /mnt/rootfs/etc/systemd/system/multi-user.target.wants/ssh.service"

# Set phablet password OR add authorized_keys
# Option A: password (needs chroot or manual /etc/shadow edit - complex)
# Option B: authorized_keys (simpler)
adb push ~/.ssh/id_rsa.pub /tmp/authkey.pub
adb shell "mkdir -p /mnt/rootfs/home/phablet/.ssh"
adb shell "cat /tmp/authkey.pub > /mnt/rootfs/home/phablet/.ssh/authorized_keys"
adb shell "chown 32011:32011 /mnt/rootfs/home/phablet/.ssh/authorized_keys"  # phablet uid:gid
adb shell "chmod 600 /mnt/rootfs/home/phablet/.ssh/authorized_keys"

# Verify sshd_config permits key auth
adb shell "grep -E 'PubkeyAuthentication|PermitRootLogin' /mnt/rootfs/etc/ssh/sshd_config"

# Unmount cleanly
adb shell "umount /mnt/rootfs; umount /tmpmnt"
```

### Step 3: Reboot V63 and test SSH
```bash
# Boot V63 again
adb shell "reboot bootloader"
# (wait for fastboot)
fastboot boot tmp-v63-netd-disabled/halium-boot-zl1-v63-usbd-disabled.img

# Host-side: bind rndis_host + configure IP (same as before)
sudo modprobe rndis_host
sudo ip link set usb0 up
sudo ip addr add 192.168.2.100/24 dev usb0
sudo ip addr add 10.15.19.100/24 dev usb0

# Wait ~30s for Ubuntu Touch to finish booting, then:
ssh phablet@10.15.19.82      # should work now
# or:
ssh phablet@192.168.2.15
```

### Step 4: Verify and document
Once SSH works:
- Run `uname -a`, `systemctl status`, `ip a`, `lxc-ls -f` from inside
- Confirm NetworkManager, rndis0 IPs, systemd services
- Document the full access flow in the breakthrough doc

## Alternative: If recovery manual edit is hard
Pull rootfs.img to host, loopback-mount on host (with sudo loop + mount), edit,
push back. But that's an 8GB transfer each way, so the on-device recovery edit
is faster.

## Files
- Breakthrough doc: `docs/ubuntu-touch/V63-OPTIONC-CONFIRMED-WORKING.md`
- Memory: `/home/lvyufeng/.claude/projects/-mnt-data-zl1-bb10/memory/zl1-v63-optionc-access-working.md`
- V63 boot image: `tmp-v63-netd-disabled/halium-boot-zl1-v63-usbd-disabled.img`
- Rootfs (host): `/mnt/data/ubports-rootfs/24.04-2.x/rootfs-24.04-2.x-arm64-android9plus-zl1-host.img`
