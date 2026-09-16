# V63 + Option C — CONFIRMED WORKING (device-side proof)

## BREAKTHROUGH (2026-06-15)

The Ubuntu Touch boot **SUCCEEDS** and RNDIS stays up. The previous "V63 loses
connectivity at 35s" conclusion was a **host-side observation artifact** —
the device was fine all along.

### Proof: `zl1-v63-monitor.log` (pulled from device userdata)

This is the V63 keeper's own on-device log, persisted to
`/userdata/zl1-v63-monitor.log`. It shows:

- `pid1=[systemd|/sbin/init]` — **Ubuntu Touch systemd is PID 1** (full boot
  reached, NOT just initrd)
- `rndis0 UP  192.168.2.15/24 10.15.19.82/24` — **both static IPs applied**
  (the NetworkManager `rndis-static.nmconnection` injection in the rootfs
  WORKED)
- routes present: `192.168.2.0/24 dev rndis0 src 192.168.2.15`,
  `10.15.19.0/24 dev rndis0 src 10.15.19.82`
- `state=CONFIGURED functions=rndis enable=1 rndis0(...carrier=1,op=up...)`
  from **tick=1 (uptime 6.58s)** continuously to **DONE uptime=537.94s** —
  RNDIS sustained ~9 minutes, never dropped
- `lxc=[android State: STOPPED]` — Android LXC stopped by design (V63 usbd-
  disabled variant)

### The REAL problem: host-side RNDIS enumeration

When V63 runs, the device exposes an RNDIS gadget with USB product string
"zl1 V63 usbd-disabled RNDIS" and serial `33e80afe-v63-usbd-disabled-rndis`.
The device is up at 192.168.2.15 / 10.15.19.82 for ~9 minutes. But the **Linux
host never binds a driver** to the device's RNDIS interface because the gadget
advertises **`bInterfaceClass=255 (Vendor Specific Class)`** rather than
standard RNDIS/CDC, so `rndis_host` doesn't auto-probe. No host `usbN`
interface appears, so ping/ssh from host fails — even though the device is
fully reachable.

### CONFIRMED END-TO-END (2026-06-15, second boot)

Reproduced the full access path:

1. Booted V63 via `fastboot boot`.
2. On host, device appears as `18d1:d001` (sometimes other pid) with serial
   `33e80afe-v63-usbd-disabled-rndis`. A host `usb0` interface auto-appeared
   with driver `rndis_host` (once `modprobe rndis_host` / new_id was prodded).
3. On host:
   ```
   sudo ip link set usb0 up
   sudo ip addr add 192.168.2.100/24 dev usb0
   sudo ip addr add 10.15.19.100/24 dev usb0
   ping 192.168.2.15   # 0.3ms, 0% loss
   ping 10.15.19.82    # 0.3ms, 0% loss
   ```
4. **20/20 ping success over 60s, sustained well past 35s — STABLE.**
5. Live status from device `curl http://10.15.19.82:8080/` returns:
   - `proc 1 status: Name: systemd` (Ubuntu Touch fully up)
   - `rndis0 UP 192.168.2.15/24 10.15.19.82/24`
   - `/dev/sda10 /etc/ssh ext4 rw` (ssh dir present, bind-mounted)
   - NetworkManager, lxc-monitord, systemd-journal, dbus, logind all active

### What does NOT yet work

- **SSH (port 22) is refused** — sshd not running / not enabled (Ubuntu Touch
  default; needs developer-mode enable). `/etc/ssh` exists in rootfs though, so
  enabling ssh is a rootfs edit.
- ADB over TCP (5555) not open.
- The only open service is the V63 keeper's python status endpoint on **8080**
  (read-only HTTP status dump).

To get a real shell next, enable sshd in the rootfs (drop an enabled
`sshd.service` symlink + set a phablet password / authorized_keys), push the
modified rootfs.img again, and reboot.

### How to actually access the device

On the host, when the V63 RNDIS device appears (`lsusb` serial
`33e80afe-v63-usbd-disabled-rndis`, or just a new `18d1:????` vendor-specific
interface with no Driver), manually bind the driver:

```bash
# find the interface with no driver
lsusb -t   # look for Class=Vendor Specific, Driver=(empty)
# bind rndis_host to it
echo <rndis_host module path> > /sys/bus/usb/drivers/rndis_host/bind
# or use usbvid:pid with modprobe trick / sysfs new_id
echo "18d1 ????" > /sys/bus/usb/drivers/rndis_host/new_id
```

Then a `usb0`/`enx...` interface appears; configure host IP 192.168.2.100/24
(or 10.15.19.100/24) and `ssh phablet@10.15.19.82` / `192.168.2.15`.

### Boot recipe that works (Option C)

1. userdata (sda10) must be ext4 with `/tmpmnt/rootfs.img` = the 8G
   `rootfs-24.04-2.x-arm64-android9plus-zl1-host.img` which contains
   `/etc/NetworkManager/system-connections/{rndis-static,usb0-static}.nmconnection`
   (mode 0600, autoconnect-priority=100, IPs 192.168.2.15+10.15.19.82)
2. `fastboot boot tmp-v63-netd-disabled/halium-boot-zl1-v63-usbd-disabled.img`
   (SHA256 ab574bd3..., RAM boot, no flash). V63 cmdline has
   `init=/tmp/zl1-debug-init` + `zl1_v63_monitor=1`; NOTE it has **no
   `datapart=`**, so Halium's datapart block is skipped — V63's own wrapper
   does USB setup. This is fine; the wrapper still mounts the rootfs.
3. Device boots to systemd, rndis0 comes up. ~9 min window.
4. Host must bind rndis_host during that window (see above).

### Key files

- V63 boot image: `tmp-v63-netd-disabled/halium-boot-zl1-v63-usbd-disabled.img`
- V63 keeper log (THE proof): `tmp-v71-rootfs-nm-inject/pstore/zl1-v63-monitor-from-device.log`
- Modified 8G rootfs: `/mnt/data/ubports-rootfs/24.04-2.x/rootfs-24.04-2.x-arm64-android9plus-zl1-host.img`
- Monitor script: `tmp-v71-rootfs-nm-inject/monitor-v63-optionC.sh`

### Unrelated device to IGNORE

`4a2fe00b` = Xiaomi "MI 4LTE" cancro, also on this host's USB bus as
`18d1:4ee7`. Earlier monitoring scripts matched it by USB ID and falsely
reported "target present". Always filter by **serial `33e80afe`**, never by
bare `18d1:4ee7`. See [[ignore-xiaomi-4a2fe00b]].
