#!/usr/bin/env bash
# Derive a boot image that enables the zl1 debug telnet shell.
#
# The v63 ramdisk reads `zl1_debug_shell=1` from the kernel cmdline
# (scripts/init-bottom/zl1-postswitch-debug-init) and, when it is present,
# also starts `busybox telnetd -l /bin/sh` on port 23. Without it there is no
# way to get a shell on the device: UT exposes only the RNDIS gadget, so there
# is no adb, and the HTTP status server is read-only.
#
# The change is a literal append into the boot image's 512-byte cmdline field,
# which is NUL-padded — the kernel and ramdisk are untouched, so this is v63
# plus one cmdline argument and nothing else. The `ANDROID!` header carries no
# checksum, so the result is a valid image; it is verified with unpack_bootimg.
#
# Usage: make-zl1-debug-shell-boot.sh <SRC_IMG> <DST_IMG>

set -euo pipefail

SRC="${1:?usage: $0 <src.img> <dst.img>}"
DST="${2:?usage: $0 <src.img> <dst.img>}"
EXTRA="zl1_debug_shell=1"

[[ -f "$SRC" ]] || { echo "no such image: $SRC" >&2; exit 1; }

DST="$DST" SRC="$SRC" EXTRA="$EXTRA" python3 - <<'PY'
import os, struct, sys

src, dst, extra = os.environ['SRC'], os.environ['DST'], os.environ['EXTRA']
data = bytearray(open(src, 'rb').read())

assert data[:8] == b'ANDROID!', 'not an Android boot image'
page_size = struct.unpack_from('<I', data, 8 + 7 * 4)[0]
header_version = struct.unpack_from('<I', data, 8 + 8 * 4)[0]
assert header_version == 0, f'unexpected header version {header_version}'

# header v0: char cmdline[512] at offset 64
CMD_OFF, CMD_LEN = 64, 512
field = data[CMD_OFF:CMD_OFF + CMD_LEN]
cur = field.split(b'\0', 1)[0]
if extra.encode() in cur.split():
    print('already present:', cur.decode())
    if src != dst:
        open(dst, 'wb').write(bytes(data))
    sys.exit(0)

new = cur + b' ' + extra.encode()
if len(new) + 1 > CMD_LEN:
    sys.exit(f'cmdline would not fit: {len(new)} > {CMD_LEN - 1}')
data[CMD_OFF:CMD_OFF + CMD_LEN] = new + b'\0' * (CMD_LEN - len(new))
open(dst, 'wb').write(bytes(data))
print('cmdline now:')
print(' ', new.decode())
PY

echo "--- verifying the derived image"
# Verify by reading the cmdline field back, not by unpack_bootimg's exit status
# (it returns non-zero on this header even when it parses the image fine).
DST="$DST" python3 - <<'PY2'
import os
d = open(os.environ['DST'], 'rb').read()
cmd = d[64:576].split(b'\0', 1)[0].decode()
assert 'zl1_debug_shell=1' in cmd.split(), 'flag missing from the derived image'
print('OK: derived image carries zl1_debug_shell=1')
PY2

sha256sum "$SRC" "$DST"
