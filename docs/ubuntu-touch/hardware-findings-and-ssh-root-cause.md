# Hardware Findings from HTTP Status Endpoint

## System Services Running ✅
- **sensorfwd**: Sensor framework daemon (active)
- **display-powersave**: Display power management
- **systemd-udevd**: Device manager
- **systemd-logind**: Login manager
- **dbus-daemon**: System message bus
- **lxc-monitord**: LXC container monitor

## Network Interfaces
- **rndis0**: UP, carrier=1 ✅ (USB networking - working)
- **rmnet_ipa0**: DOWN (cellular modem interface - present but inactive)
- **lo**: UP (loopback)
- **bond0, dummy0, sit0**: DOWN (virtual interfaces)

## Key Filesystem Mounts (from /dev/sda10 userdata)
Bind-mounted to rootfs from userdata:
- `/etc/ssh` - SSH configuration
- `/root` - Root home directory  
- `/home` - User homes
- `/etc/NetworkManager/system-connections` - Network configs
- `/etc/systemd/system` - Systemd unit files
- `/var/lib/bluetooth` - Bluetooth data directory (exists)

## Observations

### What Works ✓
1. **Network**: rndis0 functional, stable RNDIS connection
2. **Sensors**: sensorfwd daemon running
3. **System**: systemd, udev, dbus all active
4. **Display power**: display-powersave-blocker active

### What's Present But Inactive
1. **rmnet_ipa0**: Modem network interface exists but DOWN
2. **Bluetooth**: `/var/lib/bluetooth` mounted, but no bluetoothd process seen
3. **SSH**: Port 22 open, sshd running, but publickey auth systematically fails

### Not Observable (Would Need SSH/Shell Access)
- Framebuffer devices (/dev/fb*)
- Input devices (/dev/input/event*)
- Audio devices (/dev/snd/*)
- Camera devices (/dev/video*)
- WiFi interfaces (wlan*)
- GPU/DRM devices
- Sensor device nodes
- LED controls
- GPS devices

## SSH Access Issue - ROOT CAUSE IDENTIFIED

Looking at mounts: `/etc/ssh` and `/root` are **bind-mounted from userdata**.

**Critical discovery**: When we edit `/mnt/rootfs/root/.ssh/authorized_keys` in recovery, we're editing the **rootfs image**, but at runtime these paths are **overlaid by bind-mounts from userdata**.

The SSH daemon reads from the **bind-mounted** `/root/.ssh/`, not from the rootfs `/root/.ssh/`!

### Solution
Authorized_keys must be placed in **userdata**, not rootfs:
```bash
# In recovery:
mount /dev/block/sda10 /tmpmnt
mkdir -p /tmpmnt/root/.ssh
cat key.pub > /tmpmnt/root/.ssh/authorized_keys
chmod 700 /tmpmnt/root/.ssh
chmod 600 /tmpmnt/root/.ssh/authorized_keys
umount /tmpmnt
```

This explains why all attempts failed - we were editing the wrong location!
