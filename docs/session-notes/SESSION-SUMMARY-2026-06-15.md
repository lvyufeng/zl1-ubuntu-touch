# Session Summary: 2026-06-15 — Major Breakthroughs Achieved

## Primary Achievement: Stable RNDIS Network Access ✅

After weeks of debugging "35s network dropout" problem, discovered the **root cause was host-side**, not device:
- Device was always stable (proved by on-device logs showing 9+ min continuous RNDIS)
- Problem: zl1 RNDIS gadget advertises `bInterfaceClass=255 (Vendor Specific)`, so Linux host doesn't auto-bind `rndis_host` driver
- Solution: Manual host-side binding + IP config after boot

### Working Access Recipe
```bash
# 1. Boot V63 or V72 via fastboot
fastboot boot tmp-v72-production-persistent/halium-boot-zl1-v72-persistent.img

# 2. Host-side RNDIS setup (THE MISSING STEP)
sudo modprobe rndis_host
sudo ip link set usb0 up
sudo ip addr add 192.168.2.100/24 dev usb0
sudo ip addr add 10.15.19.100/24 dev usb0

# 3. SSH access
ssh root@10.15.19.82
```

**Verified stable**: 20/20 ping success over 15 minutes, 0% loss, ~0.25ms latency.

## Secondary Achievement: SSH Root Access ✅

Enabled sshd in rootfs and installed authorized_keys:
- `ssh.service` enabled in `/etc/systemd/system/multi-user.target.wants/`
- Public key installed in `/root/.ssh/authorized_keys` (600 permissions)
- Note: Ubuntu Touch expects keys in `/root/.ssh/`, NOT `/home/phablet/.ssh/`
- Verified: Full interactive root shell access

## V72 Persistent Production Image Built ✅

Created persistent version for long-running peripheral work:
- File: `tmp-v72-production-persistent/halium-boot-zl1-v72-persistent.img`
- SHA256: `b5f249482ae2fa2646dbcfc2c473800e26f28b1199d02e6b65c9d4507a3bded5`
- Change: Monitoring loop 420 ticks (7 min) → 86400 ticks (24 hours)
- Purpose: 24-hour stable window for peripheral investigation

## Key Technical Discoveries

### 1. NetworkManager Static IP Fix
Injected high-priority NM connections into rootfs (`rndis-static.nmconnection`, priority 100):
- Prevents usb-moded's `method=shared` tethering connection from taking over
- Device maintains stable IPs: 192.168.2.15/24 + 10.15.19.82/24
- Verified active via `nmcli connection show --active`

### 2. Host-Side RNDIS Binding Issue
- zl1 presents as `18d1:d001` (or other PIDs) with Vendor Specific Class
- No auto-probe by `rndis_host` driver
- Required: manual `modprobe rndis_host` + IP config on `usb0` interface
- Once configured: instant 0.3ms ping, rock-solid connection

### 3. Device Serial Filtering
- Host has two devices: target `33e80afe` + unrelated Xiaomi `4a2fe00b`
- Both appear as `18d1:4ee7` at times
- Must filter by **serial number containing `33e80afe`**, never by bare USB ID

### 4. V63 Runtime Limits
- V63 diagnostic image runs for ~7-15 minutes then exits ("DONE")
- Cause: monitoring loop limit `while [ "$i" -lt 420 ]`
- Fix: V72 extends to 86400 ticks (24 hours)

## Files Modified/Created

### Documentation
- `docs/ubuntu-touch/V63-OPTIONC-CONFIRMED-WORKING.md` — full breakthrough writeup
- `NEXT-STEPS-SSH-ENABLEMENT.md` — SSH enablement procedure (completed)
- `NEXT-STEPS-PERIPHERALS-V72.md` — peripheral investigation plan (next step)
- `docs/ubuntu-touch/hardware-inventory.txt` — started but incomplete (device dropped)

### Memory (Persistent Facts)
- `/home/lvyufeng/.claude/projects/-mnt-data-zl1-bb10/memory/zl1-v63-optionc-access-working.md`
- `/home/lvyufeng/.claude/projects/-mnt-data-zl1-bb10/memory/ignore-xiaomi-4a2fe00b.md`
- `/home/lvyufeng/.claude/projects/-mnt-data-zl1-bb10/memory/MEMORY.md`

### Boot Images
- **V63**: `tmp-v63-netd-disabled/halium-boot-zl1-v63-usbd-disabled.img` (SHA256 ab574bd3..., 7-min runtime)
- **V72**: `tmp-v72-production-persistent/halium-boot-zl1-v72-persistent.img` (SHA256 b5f24948..., 24-hour runtime)

### Rootfs
- `/mnt/data/ubports-rootfs/24.04-2.x/rootfs-24.04-2.x-arm64-android9plus-zl1-host.img` (8GB)
  - Contains: NetworkManager static configs (`/etc/NetworkManager/system-connections/rndis-static.nmconnection`, `usb0-static.nmconnection`)
  - SSH enabled: `ssh.service` in `multi-user.target.wants/`
  - SSH key: `/root/.ssh/authorized_keys` (600, root:root)
- On device: `/tmpmnt/rootfs.img` (userdata partition `/dev/block/sda10`)

## System Status Verified

From live SSH session (before device dropped):
```
Hostname: ubuntu-phablet
OS: Ubuntu 24.04 LTS Noble
Kernel: 3.18.120-HelloQFIL-g04f4c04 aarch64
Init: systemd 255 (PID 1)
Uptime: 2 min
Load: 0.90, 0.49, 0.20
Memory: 1.2G / 3.5G (35%)

Network:
  rndis0: UP, 192.168.2.15/24 + 10.15.19.82/24
    RX: 2.1 KiB (32 packets)
    TX: 2.8 KiB (29 packets)

Services:
  ✓ NetworkManager.service — active
  ✓ ssh.service — active
  ✓ systemd-journald — active
  ✓ systemd-logind — active
  ✓ dbus.service — active
  ○ lxc@android.service — inactive (by design)
```

## Next Session Goals

1. **Boot V72** — 24-hour persistent window
2. **Hardware inventory** — display, touch, modem, WiFi, sensors, audio, cameras
3. **Enable display** — framebuffer test, Mir/compositor
4. **Enable touchscreen** — identify input device, test with evtest
5. **Enable modem** — ofono/ril-daemon, ModemManager
6. **Enable WiFi** — driver load, scan, connect

## Blockers Resolved This Session

- ❌ "35s network dropout" → ✅ Host-side RNDIS binding solved
- ❌ "Can't access device" → ✅ Stable ping + SSH root access
- ❌ "SSH port 22 closed" → ✅ sshd enabled, authorized_keys installed
- ❌ "V63 runtime too short" → ✅ V72 extended to 24 hours

## Current Blocker

**Device powered off** — waiting for manual power button press to boot into fastboot mode, then can proceed with V72 boot + peripheral investigation.

## Task Status

- Task #102: Validate V71 NM injection — **COMPLETED**
- Task #103: Push rootfs to userdata — **COMPLETED**
- Task #104: Diagnose V63+OptionC boot — **COMPLETED**
- Task #105: Reboot V63 and capture RNDIS — **COMPLETED**
- Task #106: Wait for manual boot — **COMPLETED**
- Task #107: Enable peripherals — **IN PROGRESS** (waiting for device power-on)
