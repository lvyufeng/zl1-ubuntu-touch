#!/usr/bin/env python3
# zl1-inject-input -- make the device think a finger touched it, or a key was pressed.
#
# Why this exists: on the zl1 the GUI is the host-side lomiri/lomiri-system-compositor, so an input
# event has to travel kernel evdev -> Mir's input platform -> the shell, and the shell acts on it.
# "The back key does not work" is a complaint about that whole chain, and there was no way to ask
# *where* in it the event stops: the hardware half (does the key controller report anything at all)
# needs a human finger on the phone, and the software half needs the opposite -- an event that is
# known to be well-formed, injected below the point of suspicion. That is this script.
#
# It is the same instrument for both halves of the split, because it feeds the *kernel* input layer:
#
#   kernel sees it: yes, always. It arrives exactly like a real device's events (uinput is a kernel
#                   evdev device), so if a key injected here does nothing, the defect is above evdev
#                   -- in Mir/repowerd/the shell -- and not in the key controller or its driver.
#   readers see it:  libinput (and therefore Mir) picks up new devices through udev/inotify, so the
#                   injection also *introduces* a device. That makes this a test of "does the
#                   compositor take input from a device it did not see at startup", which is a
#                   different question from "does it take input at all". Real devices are open from
#                   startup; keep both in mind when reading a null result.
#
# Nothing is written anywhere except /dev/uinput, and the device disappears when this process closes
# it -- there is no state on the device that outlives the call. It cannot brick anything: the worst
# case is a stuck key, which is why every action here ends with the matching release.
#
# Usage:
#   zl1-inject-input.py --tap X Y                  one touch down+up at (X, Y), panel coordinates
#   zl1-inject-input.py --swipe X1 Y1 X2 Y2        a drag; --ms N sets the duration (default 250)
#   zl1-inject-input.py --key CODE                 press and release one key; --hold-ms N (default 60)
#   zl1-inject-input.py --keys CODE,CODE,...       several, in order
#   zl1-inject-input.py --devices                  create both virtual devices and just report what
#                                                  the kernel made of them, then exit (a smoke test
#                                                  for whether uinput works on this kernel at all)
#
# --keep-seconds N (default 1) holds the virtual device open that long after the last event. It has
# to outlive the event by a moment or a reader may drop the events with the device; and a long keep
# is how you answer "did the compositor even take this device" -- while it is open, look for
# /dev/input/eventN in the compositor's /proc/<pid>/fd.
#
# Key codes are the Linux ones: 116 power, 115/114 volume up/down, 158 back, 102 home, 139 menu,
# 28 enter, 1 escape, 125 left meta. `--key 158` is the back button.

import fcntl
import os
import struct
import sys
import time

# linux/uinput.h, computed the way _IOC does on aarch64 (dir<<30 | size<<16 | type<<8 | nr).
UI_SET_EVBIT = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_SET_ABSBIT = 0x40045567
UI_SET_PROPBIT = 0x4004556E
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502

EV_SYN, EV_KEY, EV_ABS = 0x00, 0x01, 0x03
SYN_REPORT = 0x00
BTN_TOUCH = 0x14A
ABS_MT_SLOT = 0x2F
ABS_MT_POSITION_X = 0x35
ABS_MT_POSITION_Y = 0x36
ABS_MT_TRACKING_ID = 0x39
INPUT_PROP_DIRECT = 0x01

# The panel is 1080x1920 (fbset: mode "1080x1920-57"), and Mir scales a touch device's absolute
# range onto the output -- so a virtual device that declares that same range needs no conversion.
PANEL_W, PANEL_H = 1080, 1920

# struct input_event on a 64-bit kernel: timeval (2x8) + type + code + value = 24 bytes, no padding.
def _event(fd, etype, code, value):
    fd.write(struct.pack("<qqHHi", 0, 0, etype, code, value))


def _syn(fd):
    _event(fd, EV_SYN, SYN_REPORT, 0)


# struct uinput_user_dev, the pre-4.5 way of describing a device: name, id, ff_effects_max, then
# four ABS_CNT-sized arrays (max, min, fuzz, flat) -- 80 + 8 + 4 + 4*64*4 = 1116 bytes.
ABS_CNT = 64
def _user_dev(name, bustype, vendor, product, version, absmax):
    buf = bytearray()
    buf += name.encode()[:79].ljust(80, b"\0")
    buf += struct.pack("<HHHH", bustype, vendor, product, version)
    buf += struct.pack("<I", 0)
    for _ in range(4):
        for i in range(ABS_CNT):
            buf += struct.pack("<i", absmax.get(i, 0) if _ == 0 else 0)
    return bytes(buf)


def open_uinput():
    return open("/dev/uinput", "wb", buffering=0)


def make_touch(name="zl1-diag-touch"):
    fd = open_uinput()
    fcntl.ioctl(fd.fileno(), UI_SET_EVBIT, EV_KEY)
    fcntl.ioctl(fd.fileno(), UI_SET_EVBIT, EV_ABS)
    fcntl.ioctl(fd.fileno(), UI_SET_EVBIT, EV_SYN)
    fcntl.ioctl(fd.fileno(), UI_SET_KEYBIT, BTN_TOUCH)
    # INPUT_PROP_DIRECT is what makes libinput call this a touchscreen rather than a touchpad --
    # without it the events arrive as relative pointer motion and nothing on the greeter reacts.
    fcntl.ioctl(fd.fileno(), UI_SET_PROPBIT, INPUT_PROP_DIRECT)
    for axis in (ABS_MT_SLOT, ABS_MT_POSITION_X, ABS_MT_POSITION_Y, ABS_MT_TRACKING_ID):
        fcntl.ioctl(fd.fileno(), UI_SET_ABSBIT, axis)
    fd.write(_user_dev(name, 0x03, 0x1234, 0x5678, 1,
                       {ABS_MT_POSITION_X: PANEL_W - 1, ABS_MT_POSITION_Y: PANEL_H - 1,
                        ABS_MT_SLOT: 9, ABS_MT_TRACKING_ID: 65535}))
    fcntl.ioctl(fd.fileno(), UI_DEV_CREATE)
    return fd


def make_keyboard(name="zl1-diag-keys"):
    fd = open_uinput()
    fcntl.ioctl(fd.fileno(), UI_SET_EVBIT, EV_KEY)
    fcntl.ioctl(fd.fileno(), UI_SET_EVBIT, EV_SYN)
    # Every key this script can send has to be declared, or the kernel drops it as unsupported.
    for code in (1, 28, 102, 114, 115, 116, 125, 139, 158, 172, 217, 224, 580):
        fcntl.ioctl(fd.fileno(), UI_SET_KEYBIT, code)
    fd.write(_user_dev(name, 0x03, 0x1234, 0x5679, 1, {}))
    fcntl.ioctl(fd.fileno(), UI_DEV_CREATE)
    return fd


def node_names():
    """What the kernel called the devices this process just created."""
    found = []
    try:
        for e in sorted(os.listdir("/sys/class/input")):
            if not e.startswith("event"):
                continue
            try:
                name = open("/sys/class/input/%s/device/name" % e).read().strip()
            except OSError:
                continue
            if name.startswith("zl1-diag"):
                found.append("%s = %s" % (e, name))
    except OSError:
        pass
    return found


def touch(fd, x, y, ms):
    """One finger down, move in steps, up. A tap is this with ms=0."""
    _event(fd, EV_ABS, ABS_MT_SLOT, 0)
    _event(fd, EV_ABS, ABS_MT_TRACKING_ID, 1)
    _event(fd, EV_ABS, ABS_MT_POSITION_X, x)
    _event(fd, EV_ABS, ABS_MT_POSITION_Y, y)
    _event(fd, EV_KEY, BTN_TOUCH, 1)
    _syn(fd)
    if ms:
        time.sleep(0.02)  # let the down be seen on its own; Mir treats a zero-length drag as a tap
        steps = max(2, int(ms / 20))
        for i in range(1, steps + 1):
            _event(fd, EV_ABS, ABS_MT_POSITION_X, x)
            _event(fd, EV_ABS, ABS_MT_POSITION_Y, y)
            _syn(fd)
            time.sleep(ms / 1000.0 / steps)
    _event(fd, EV_KEY, BTN_TOUCH, 0)
    _event(fd, EV_ABS, ABS_MT_TRACKING_ID, -1)
    _syn(fd)


def main(argv):
    if not argv:
        print(__doc__ or "", file=sys.stderr)
        return 2
    act, rest = argv[0], argv[1:]

    opts = {}
    positional = []
    i = 0
    while i < len(rest):
        if rest[i].startswith("--"):
            opts[rest[i]] = rest[i + 1] if i + 1 < len(rest) and not rest[i + 1].startswith("--") else "1"
            i += 2
        else:
            positional.append(rest[i])
            i += 1

    if act == "--devices":
        t = make_touch()
        k = make_keyboard()
        time.sleep(0.5)  # udev/libinput need a moment to notice a device that existed for 0 ms
        print("created: %s" % (", ".join(node_names()) or "nothing appeared in /sys/class/input"))
        print("uinput works on this kernel: yes")
        k.close()
        t.close()
        return 0

    if act == "--tap":
        x, y = int(positional[0]), int(positional[1])
        fd = make_touch()
        time.sleep(0.3)
        touch(fd, x, y, 0)
        print("tapped (%d, %d)" % (x, y))
    elif act == "--swipe":
        x1, y1, x2, y2 = (int(v) for v in positional[:4])
        ms = int(opts.get("--ms", "250"))
        fd = make_touch()
        time.sleep(0.3)
        _event(fd, EV_ABS, ABS_MT_SLOT, 0)
        _event(fd, EV_ABS, ABS_MT_TRACKING_ID, 1)
        _event(fd, EV_ABS, ABS_MT_POSITION_X, x1)
        _event(fd, EV_ABS, ABS_MT_POSITION_Y, y1)
        _event(fd, EV_KEY, BTN_TOUCH, 1)
        _syn(fd)
        steps = max(4, ms // 10)
        for i in range(1, steps + 1):
            _event(fd, EV_ABS, ABS_MT_POSITION_X, x1 + (x2 - x1) * i // steps)
            _event(fd, EV_ABS, ABS_MT_POSITION_Y, y1 + (y2 - y1) * i // steps)
            _syn(fd)
            time.sleep(ms / 1000.0 / steps)
        _event(fd, EV_KEY, BTN_TOUCH, 0)
        _event(fd, EV_ABS, ABS_MT_TRACKING_ID, -1)
        _syn(fd)
        print("swiped (%d, %d) -> (%d, %d) over %d ms" % (x1, y1, x2, y2, ms))
    elif act in ("--key", "--keys"):
        codes = positional[0] if act == "--key" else positional[0]
        codes = [int(c) for c in codes.split(",")]
        hold = int(opts.get("--hold-ms", "60"))
        fd = make_keyboard()
        time.sleep(0.3)
        for code in codes:
            _event(fd, EV_KEY, code, 1)
            _syn(fd)
            time.sleep(hold / 1000.0)
            _event(fd, EV_KEY, code, 0)
            _syn(fd)
            time.sleep(0.05)
            print("sent key %d" % code)
    else:
        print("unknown action %s" % act, file=sys.stderr)
        return 2

    time.sleep(float(opts.get("--keep-seconds", "1.0")))
    fd.close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
