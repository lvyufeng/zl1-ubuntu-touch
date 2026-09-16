# Next Steps: Peripheral Investigation with V72 Persistent Image

## Current Status (2026-06-15 09:57 UTC)

### ✅ Completed
- **Network access**: RNDIS stable, 192.168.2.15 + 10.15.19.82, verified working
- **SSH access**: root@10.15.19.82 working with authorized_keys in /root/.ssh/
- **V72 persistent image**: Built and ready (`tmp-v72-production-persistent/halium-boot-zl1-v72-persistent.img`, SHA256 b5f24948...)

### V72 Changes
- Extended monitoring loop: 420 ticks (7 min) → 86400 ticks (24 hours)
- This provides a **24-hour persistent access window** for peripheral work
- All version strings updated v63→v72
- Same kernel/config as V63, only ramdisk timeout changed

### Device Current State
**Powered off or suspended** — needs manual power button press to boot into fastboot.

## When Device is Available

### 1. Boot V72
```bash
# After device enters fastboot mode:
cd /mnt/data/zl1-bb10
fastboot boot tmp-v72-production-persistent/halium-boot-zl1-v72-persistent.img

# Host-side RNDIS setup (same as before):
sudo modprobe rndis_host
sudo ip link set usb0 up
sudo ip addr add 192.168.2.100/24 dev usb0
sudo ip addr add 10.15.19.100/24 dev usb0

# Wait ~30s, then SSH:
ssh root@10.15.19.82
```

### 2. Peripheral Investigation Plan

Once SSH is established, collect hardware inventory:

```bash
# Display / Framebuffer
ls -la /dev/fb*
cat /sys/class/graphics/fb*/name
cat /sys/class/graphics/fb*/modes
cat /sys/class/graphics/fb*/virtual_size

# Input devices (touchscreen, buttons)
ls -la /dev/input/
cat /proc/bus/input/devices
# Test: hexdump -C /dev/input/event* while touching screen

# GPU / DRM
ls -la /dev/dri/
ls -la /dev/graphics/
cat /sys/kernel/debug/dri/0/name 2>/dev/null

# Audio
ls -la /dev/snd/
cat /proc/asound/cards
cat /proc/asound/devices

# Sensors (accelerometer, gyro, light, proximity)
ls -la /dev/iio/
find /sys/bus/iio/devices/ -name "name" -exec sh -c 'echo -n "{}:  "; cat {}' \;

# Modem / RIL
ls -la /dev/smd* /dev/qmi* /dev/rmnet*
cat /sys/class/net/rmnet*/address 2>/dev/null

# WiFi / Bluetooth
ls -la /sys/class/net/wlan*
hciconfig -a 2>/dev/null

# Cameras
ls -la /dev/video* /dev/media*
v4l2-ctl --list-devices 2>/dev/null

# LEDs
ls /sys/class/leds/
cat /sys/class/leds/*/trigger

# Vibrator
ls -la /sys/class/timed_output/vibrator/

# GPS
ls -la /dev/gps* /dev/gnss*

# Power management
cat /sys/class/power_supply/*/uevent
```

### 3. Priority Order for Peripheral Enablement

1. **Display (framebuffer)** — critical for visual output
   - Check `/dev/fb0` exists and is writable
   - Test with: `cat /dev/urandom > /dev/fb0` (should show noise on screen)
   - Enable Mir display server if needed

2. **Touchscreen** — critical for input
   - Identify touch input device in `/proc/bus/input/devices`
   - Test with `evtest /dev/input/eventX`
   - Configure for Mir/Qt input

3. **Cellular modem** — for phone functionality
   - Check `/dev/smd*` nodes (Qualcomm SMD channels)
   - Start `ofono` or `ril-daemon`
   - Test with `mmcli` (ModemManager)

4. **WiFi** — for network connectivity
   - Check kernel driver loaded: `lsmod | grep wlan`
   - Bring up `wlan0`: `ip link set wlan0 up`
   - Scan: `iw wlan0 scan`

5. **Audio** — for calls/media
   - Check ALSA devices: `aplay -l`
   - Test playback: `speaker-test`

6. **Sensors** — for device orientation
   - Enable via `sensorfw` or directly via `/sys/bus/iio`

7. **Cameras, Bluetooth, GPS** — nice-to-have features

### 4. Common Ubuntu Touch / Halium Issues

- **Display not showing**: May need to start `unity-system-compositor` or `lomiri-app-launch`
- **Touch not working**: Input device permissions, need `input` group access
- **Modem not detected**: Missing firmware in `/vendor/firmware_mnt/image/`, or RIL daemon not started
- **WiFi missing**: Firmware not loaded, check `dmesg | grep -i wlan`

### Files
- V72 boot image: `tmp-v72-production-persistent/halium-boot-zl1-v72-persistent.img` (SHA256 b5f24948...)
- Rootfs (on device userdata): `/tmpmnt/rootfs.img` (8GB, has NM static configs + SSH enabled)
- V63 for reference: `tmp-v63-netd-disabled/halium-boot-zl1-v63-usbd-disabled.img`

### Task Status
- Task #107: "Enable and test phone peripherals" — IN PROGRESS
- Waiting for: Device manual power-on to fastboot
