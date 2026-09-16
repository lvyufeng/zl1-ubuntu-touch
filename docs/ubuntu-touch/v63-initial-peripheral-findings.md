# V63 Initial Peripheral Findings (2026-06-15)

## Network Status ✓
- rndis0: UP, carrier=1, working
- rmnet_ipa0: DOWN (cellular modem interface, not active)

## Services Running
- sensorfwd: ACTIVE (sensor framework daemon)
- systemd: PID 1, running

## SSH Access Issue
- Port 22: OPEN
- Problem: publickey auth fails
- Root cause: /root/.ssh/authorized_keys may not have persisted or wrong permissions
- Workaround needed: Re-enter recovery, re-apply SSH keys, reboot

## Next Steps
1. Fix SSH access (critical for detailed investigation)
2. Once SSH works, collect: /dev/fb*, /proc/bus/input/devices, /dev/snd/*, /sys/class/leds/
3. Test display: cat /dev/urandom > /dev/fb0
4. Enable modem: check /dev/smd*, start ofono/ril
