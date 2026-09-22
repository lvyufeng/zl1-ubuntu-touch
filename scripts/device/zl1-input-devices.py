#!/usr/bin/env python3
# zl1-input-devices -- what each /dev/input device *can* report, read from the kernel's own table.
#
# The companion of zl1-watch-input.py: that one shows what the hardware **does** report, this one
# shows what it **can** report. Both are needed, because "the back key does nothing" has two very
# different shapes and they look identical on screen:
#
#   * the key is in no device's KEY bitmap  -> the kernel driver never declares it; nothing can deliver
#     it and no amount of work above the driver helps;
#   * the key is in a bitmap and never fires -> the driver declares it but the hardware (or its
#     firmware) does not send it, or the wrong device is being watched.
#
# It reads /proc/bus/input/devices only -- no ioctl, no open of /dev/input, nothing that could disturb
# a running compositor -- and decodes the `B: KEY=` / `B: ABS=` / `B: REL=` bitmaps it finds there.
#
# Note on this phone: the capacitive keys are not necessarily on the key controller. `qbt1000_key_input`
# is one device and `synaptics_dsx` (the touchscreen) is another, and both register `Handlers=kbd` --
# so a back key delivered by the touch controller's firmware would arrive on the touchscreen's event
# node, not the key controller's. Print both.
#
# Usage: zl1-input-devices.py

import re
import sys

KEY_NAMES = {
    0: "RESERVED", 1: "ESC", 2: "1", 3: "2", 4: "3", 28: "ENTER", 42: "LEFTSHIFT",
    102: "HOME", 103: "UP", 105: "LEFT", 106: "RIGHT", 108: "DOWN", 113: "MUTE",
    114: "VOL-", 115: "VOL+", 116: "POWER", 125: "META", 139: "MENU", 142: "SLEEP",
    143: "WAKEUP", 152: "SCREENLOCK", 158: "BACK", 163: "NEXTSONG", 165: "PREVSONG",
    172: "HOMEPAGE", 212: "CAMERA", 217: "SEARCH", 226: "MEDIA", 240: "UNKNOWN",
}
ABS_NAMES = {
    0x00: "X", 0x01: "Y", 0x02: "Z", 0x2F: "MT_SLOT", 0x35: "MT_POSX", 0x36: "MT_POSY",
    0x37: "MT_TRACKING", 0x39: "MT_TRACKING_ID", 0x3A: "MT_PRESSURE", 0x3D: "MT_TOOL",
    0x18: "PRESSURE", 0x28: "MISC",
}
REL_NAMES = {0x00: "X", 0x01: "Y", 0x08: "WHEEL", 0x06: "HWHEEL"}
SW_NAMES = {0: "LID", 1: "TABLET", 2: "HEADPHONE", 4: "MICROPHONE", 5: "HEADSET", 0x10: "MUTE_DEV"}


def decode(hexbits, names, limit=40):
    if not hexbits:
        return "(none)"
    bits = int(hexbits.replace(" ", ""), 16)
    out = []
    for i in range(bits.bit_length()):
        if bits >> i & 1:
            out.append(names.get(i, "0x%x" % i))
    if not out:
        return "(bitmap present but empty)"
    shown = " ".join(out[:limit])
    return shown + ("  ... (%d total)" % len(out) if len(out) > limit else "")


def main():
    try:
        blocks = open("/proc/bus/input/devices").read().split("\n\n")
    except OSError as e:
        print("cannot read /proc/bus/input/devices: %s" % e, file=sys.stderr)
        return 1

    n_dev = 0
    for blk in blocks:
        if not blk.strip():
            continue
        m_name = re.search(r'N: Name="([^"]*)"', blk)
        if not m_name:
            continue
        n_dev += 1
        def field(pat):
            m = re.search(pat, blk)
            return m.group(1) if m else None

        print("=== %s" % m_name.group(1))
        print("    handlers    : %s" % (field(r'H: Handlers=(.*)') or "?"))
        print("    phys        : %s" % (field(r'P: Phys=(.*)') or "?"))
        print("    EV bitmap   : 0x%s" % (field(r'B: EV=([0-9a-f]+)') or "0"))
        print("    KEY         : %s" % decode(field(r'B: KEY=([0-9a-f ]+)'), KEY_NAMES))
        print("    ABS         : %s" % decode(field(r'B: ABS=([0-9a-f ]+)'), ABS_NAMES))
        print("    REL         : %s" % decode(field(r'B: REL=([0-9a-f ]+)'), REL_NAMES))
        print("    SW          : %s" % decode(field(r'B: SW=([0-9a-f ]+)'), SW_NAMES))
        print()

    print("%d devices. A key that appears in no KEY bitmap above cannot be delivered by anything." % n_dev)
    print("A key that appears in one and never fires in zl1-watch-input.py is a driver/firmware question.")


if __name__ == "__main__":
    sys.exit(main())
