#!/usr/bin/env python3
# zl1-watch-input -- record every evdev event from every input device, decoded, to one file.
#
# The question this answers is "does the hardware report anything at all", and it has to be answered
# before any software explanation of the back key is worth writing: if the key controller never
# reports, the defect is in the driver or below it; if it reports and nothing acts on it, the defect
# is above. The two are indistinguishable from the GUI side -- both look like "the key does nothing".
#
# It must not disturb what it measures:
#
#   no grab:       EVIOCGRAB would take the device away from the compositor, so the very input it is
#                  trying to observe would stop reaching the thing that is supposed to act on it --
#                  and the phone would look even deader while it ran. It reads only.
#   no filtering:  every event type is logged, including the ones that look like noise (EV_MSC scan
#                  codes on the touchscreen, EV_ABS in the middle of a drag). A key press on this
#                  hardware arrives as a burst whose shape is part of the evidence.
#   one process:   eight devices in one select() loop, so the ordering between devices is real.
#
# Output goes to /userdata/zl1-input-watch.log (the persistent partition, so it survives whatever
# happens next).
#
# Usage: zl1-watch-input.py [--seconds N] [--log PATH]
#        default 1800 seconds; the file is truncated at start, not appended.

import os
import select
import struct
import sys
import time

EV_SYN, EV_KEY, EV_REL, EV_ABS, EV_MSC, EV_SW, EV_LED, EV_SND, EV_REP = range(9)
TYPES = {EV_SYN: "SYN", EV_KEY: "KEY", EV_REL: "REL", EV_ABS: "ABS", EV_MSC: "MSC",
         EV_SW: "SW", EV_LED: "LED", EV_SND: "SND", EV_REP: "REP"}

# The names that matter for this phone. Anything not here is printed as its number: a wrong name
# would be worse than no name.
ABS_NAMES = {0x00: "X", 0x01: "Y", 0x2F: "MT_SLOT", 0x35: "MT_POSX", 0x36: "MT_POSY",
             0x37: "MT_TRACKING", 0x39: "MT_TRACKING_ID", 0x3A: "MT_PRESSURE", 0x3D: "MT_TOOL"}
KEY_NAMES = {1: "ESC", 28: "ENTER", 102: "HOME", 114: "VOL-", 115: "VOL+", 116: "POWER",
             125: "META", 139: "MENU", 143: "WAKEUP", 158: "BACK", 172: "HOMEPAGE",
             217: "SEARCH", 330: "BTN_TOUCH", 580: "APPSELECT"}


def name_of(node):
    try:
        return open("/sys/class/input/%s/device/name" % os.path.basename(node)).read().strip()
    except OSError:
        return os.path.basename(node)


def main(argv):
    seconds = 1800.0
    logpath = "/userdata/zl1-input-watch.log"
    i = 0
    while i < len(argv):
        if argv[i] == "--seconds":
            seconds = float(argv[i + 1]); i += 2
        elif argv[i] == "--log":
            logpath = argv[i + 1]; i += 2
        else:
            print("unknown argument %s" % argv[i], file=sys.stderr); return 2

    nodes = []
    for n in sorted(os.listdir("/dev/input")):
        if n.startswith("event"):
            nodes.append("/dev/input/" + n)
    if not nodes:
        print("no input devices", file=sys.stderr)
        return 1

    fds = {}
    for node in nodes:
        try:
            fd = os.open(node, os.O_RDONLY | os.O_NONBLOCK)
        except OSError as e:
            print("cannot open %s: %s" % (node, e), file=sys.stderr)
            continue
        fds[fd] = (node, name_of(node))

    log = open(logpath, "w", buffering=1)
    start = time.time()
    log.write("=== watch v3 started, %d devices (NOT grabbed), %gs, every event type logged ===\n"
              % (len(fds), seconds))
    for fd, (node, name) in sorted(fds.items(), key=lambda kv: kv[1][0]):
        log.write("--- %s = %s\n" % (node, name))

    last_alive = 0.0
    last_scan = 0.0
    while time.time() - start < seconds:
        # Rescan for devices: it costs one listdir every few seconds, and it is the difference between
        # a watcher that can be tested (create a device while it runs, press, see it) and one that
        # silently watches a fixed list. Devices that go away are dropped when their read returns 0.
        if time.time() - last_scan >= 5:
            last_scan = time.time()
            for node in sorted(os.listdir("/dev/input")):
                if not node.startswith("event") or ("/dev/input/" + node) in [v[0] for v in fds.values()]:
                    continue
                try:
                    fd = os.open("/dev/input/" + node, os.O_RDONLY | os.O_NONBLOCK)
                except OSError:
                    continue
                fds[fd] = ("/dev/input/" + node, name_of("/dev/input/" + node))
                log.write("--- %s = %s (appeared)\n" % (fds[fd][0], fds[fd][1]))
        try:
            ready, _, _ = select.select(list(fds), [], [], 5.0)
        except InterruptedError:
            continue
        for fd in ready:
            node, name = fds[fd]
            try:
                data = os.read(fd, 24 * 64)  # a read boundary is not an event boundary: drain in bulk
            except OSError:
                continue
            if not data:
                # EOF: the device is gone. Keeping the fd would make select() report it readable
                # forever, which is a spin loop, not a watcher.
                log.write("--- %s = %s (gone)\n" % (node, name))
                os.close(fd)
                del fds[fd]
                continue
            for off in range(0, len(data) - 23, 24):
                _s, _us, etype, code, value = struct.unpack_from("<qqHHi", data, off)
                if etype == EV_SYN:
                    # SYN_REPORT carries nothing and ends a report; unnamed SYN_* values are the
                    # dropped-event markers and are worth seeing, so the value is printed too.
                    log.write("[%7.3f] %-16s SYN            %d\n" % (time.time() - start, name, code))
                    continue
                field = "."
                if etype == EV_ABS:
                    field = ABS_NAMES.get(code, "abs:0x%x" % code)
                elif etype == EV_KEY:
                    field = KEY_NAMES.get(code, "key:%d" % code)
                log.write("[%7.3f] %-16s %-3s %-14s %d\n"
                          % (time.time() - start, name, TYPES.get(etype, str(etype)), field, value))
        now = time.time() - start
        if now - last_alive >= 300:
            last_alive = now
            log.write("--- alive at t=%ds ---\n" % int(now))
    log.write("=== watch ended after %gs ===\n" % (time.time() - start))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
