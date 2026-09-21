# The zl1 dropped into EDL mid-session — 2026-09-21

While working on Phase 5 (display) the device went from a working Ubuntu Touch
boot straight to Qualcomm EDL. This is the raw record; the recovery is a
physical power-button reset, and nothing here was caused by a write to the
device.

## What the host saw

`usb 3-3` was the zl1 in its known-good state for about 1.7 hours:

```
[2067889.900482] usb 3-3: New USB device found, idVendor=18d1, idProduct=d001, bcdDevice= 3.18
[2067889.900496] usb 3-3: Product: zl1 V63 usbd-disabled RNDIS
[2067889.900499] usb 3-3: Manufacturer: Halium
[2067889.900502] usb 3-3: SerialNumber: 33e80afe-v63-usbd-disabled-rndis
[2067889.902817] rndis_host 3-3:1.0 usb0: register 'rndis_host' … RNDIS device
```

Then, with no intervening descriptor for Android or fastboot:

```
[2073989.138184] usb 3-3: USB disconnect, device number 7
[2073989.138356] rndis_host 3-3:1.0 usb0: unregister 'rndis_host' … RNDIS device
[2073990.567744] usb 3-3: new high-speed USB device number 20 using xhci_hcd
[2073990.718423] usb 3-3: New USB device found, idVendor=05c6, idProduct=9008, bcdDevice= 0.00
[2073990.718445] usb 3-3: Product: QUSB__BULK
[2073990.718449] usb 3-3: Manufacturer: Qualcomm CDMA Technologies MSM
[2073990.720276] usb 3-3: Qualcomm USB modem converter now attached to ttyUSB2
```

`05c6:9008` is Qualcomm's HS-USB QDLoader 9008, i.e. EDL. It stayed there.

## What is not known

The host sees only the disconnect — one USB port going away and one EDL device
arriving a second later. Whatever happened on the device is not observable from
this side, and it cannot be read now: EDL exposes no shell.

The load on the device at the time was high (load average ~10, sustained, from
the compositor's 60 s restart loop plus the container plus the tracing this
session was doing), and a `strace -f` of the compositor's whole startup was
running or had just been running. A kernel panic or watchdog reset under that
load is the obvious candidate. The earlier `dmesg` capture on the device did
contain a stack trace ending in `---[ end trace … ]---` in
`new_inode_pseudo` → `proc_get_inode` → `proc_lookup` → `do_sys_open`, which is
a warning rather than a panic, but it was there.

## Why this is not a brick

- No partition was written this session or in the work leading to it. Every
  change was a bind mount or a file under `/userdata`.
- `boot` still holds the verified v63 image, and the Android `boot.img`
  rollback is on the host with its hash.
- EDL is a *mode*, not a state of the flash. Nothing about the flash was
  changed by entering it.
- The safety rules forbid QFIL/`edl.py`-type tools in EDL. They are not needed
  here and were not used.

## Recovery

A physical power-button reset:

1. Press and hold **Power** for ~20 seconds (until the screen or the LED
   blinks), then release.
2. If that alone does not do it, hold **Volume Down + Power** for ~20 seconds.
   This may land in fastboot instead of rebooting — from fastboot a plain
   `fastboot reboot` (no `flash`) is enough, and the host already has the
   device filtered by serial `33e80afe`.
3. The device should come back up on the v63 Ubuntu Touch image, which exposes
   RNDIS only. The host side then needs `scripts/host-watch-usb0.sh`, and the
   display shims need `scripts/hybris-shims/install-hybris-shims.sh --mount`
   again — none of them survive a reboot, by design.
