#!/usr/bin/env bash
# Build the two Android-side objects that the stock LeEco image is missing or
# gets wrong, and that the host-side graphics stack expects:
#
#   libui_compat_layer.so   — the C wrapper around android::GraphicBuffer that
#                             libhybris' host libui.so dlopens.
#   libhidltransport.so     — the stock one, with android::hardware::
#                             waitForHwServiceManager() replaced by `ret`.
#
# Why the second one is patched rather than rebuilt is in
# docs/ubuntu-touch/42-*.md: this device's Android container never sets
# hwservicemanager.ready, that function waits for it in an unbounded loop, and
# libhybris deliberately does not hook the property functions at SDK >= 27 — so
# from a host process the wait can never succeed and only ever blocks. Making it
# return immediately turns an infinite hang into a failed lookup, which is what
# the caller already handles.
#
# Nothing here touches the device. Output goes to <here>/out/.
#
# Usage: build-hybris-shims.sh
# Env:   HALIUM_TREE  Halium 9 build tree (default /mnt/data/halium-zl1-build)
#        STUBS        where fetch-android-libs.sh put the originals

set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
T="${HALIUM_TREE:-/mnt/data/halium-zl1-build}"
STUBS="${STUBS:-$here/out/stubs}"
out="$here/out"
mkdir -p "$out"

CLANG="$T/prebuilts/clang/host/linux-x86/clang-4691093/bin/clang"
[ -x "$CLANG" ] || { echo "no clang in $T (set HALIUM_TREE)" >&2; exit 1; }

# The bundled ld.lld in that clang predates aarch64 --fix-cortex-a53-843419,
# which the driver passes unconditionally. Use a host lld instead. It has to be
# reachable as a file named exactly "ld.lld" in a -B directory — a -B directory
# holding "ld.lld-15" is not found, and clang then silently falls back to its own
# bundled linker and fails with the very error this avoids.
lldsrc=""
for c in ld.lld ld.lld-20 ld.lld-19 ld.lld-18 ld.lld-17 ld.lld-16 ld.lld-15 ld.lld-14; do
  p="$(command -v "$c" 2>/dev/null)" && { lldsrc="$p"; break; }
done
[ -n "$lldsrc" ] || { echo "need a host ld.lld (install lld)" >&2; exit 1; }
linkerdir="$out/ldshim"
mkdir -p "$linkerdir"
ln -sf "$lldsrc" "$linkerdir/ld.lld"
echo "ld.lld: $lldsrc"

# ---------------------------------------------------------------------------
# 1. libui_compat_layer.so
# ---------------------------------------------------------------------------
# Header search paths: the AOSP build gets these from Android.mk/Soong; building
# the module standalone means naming them. They are exactly the set the compile
# needs — the list is what iterating on "fatal error: '…' file not found"
# produced, in that order.
INC=(
  -nostdinc++ "-isystem" "$T/external/libcxx/include"
  "-I$T/bionic/libc/include"
  "-I$T/bionic/libc/kernel/uapi"
  "-I$T/bionic/libc/kernel/uapi/asm-arm64"
  "-I$T/bionic/libc/kernel/android/uapi"
  "-I$T/system/core/libcutils/include"
  "-I$T/system/core/libutils/include"
  "-I$T/system/libhwbinder/include"
  "-I$T/frameworks/native/include"
  "-I$T/frameworks/native/libs/nativebase/include"
  "-I$T/frameworks/native/libs/arect/include"
  "-I$T/system/core/libsystem/include"
  "-I$T/system/core/liblog/include"
  "-I$T/hardware/libhardware/include"
  "-I$T/halium/libhybris/hybris/include"
)
# The AOSP tree always builds crtbegin_so.o/crtend_so.o from the NDK; the clang
# prebuilt here does not carry them. r16's are the newest in the tree.
CRT="$T/prebuilts/ndk/r16/platforms/android-24/arch-arm64/usr/lib"
[ -f "$CRT/crtbegin_so.o" ] || { echo "no NDK crt objects in $CRT" >&2; exit 1; }

SRC="$T/halium/libhybris/compat/ui/ui_compatibility_layer.cpp"
[ -f "$SRC" ] || { echo "$SRC not found — is this a Halium tree?" >&2; exit 1; }
[ -d "$STUBS" ] || { echo "run fetch-android-libs.sh first (no $STUBS)" >&2; exit 1; }

echo "== libui_compat_layer.so"
"$CLANG" --target=aarch64-linux-android28 -fPIC -O2 -std=gnu++14 -c "${INC[@]}" \
  -DANDROID_VERSION_MAJOR=9 -DANDROID_VERSION_MINOR=0 -DANDROID_VERSION_PATCH=0 \
  "$SRC" -o "$out/ui_compat.o"
"$CLANG" --target=aarch64-linux-android28 -B "$linkerdir" -fuse-ld=lld -nostdlib \
  -Wl,-shared,-soname,libui_compat_layer.so -Wl,--allow-shlib-undefined \
  "$CRT/crtbegin_so.o" "$out/ui_compat.o" "$CRT/crtend_so.o" \
  -L "$STUBS" -lui -lutils -lcutils -lbinder -lhardware -llog -lc++ -lc -lm -ldl \
  "$T/prebuilts/clang/host/linux-x86/clang-4691093/lib64/clang/6.0.2/lib/linux/libclang_rt.builtins-aarch64-android.a" \
  -o "$out/libui_compat_layer.so"
rm -f "$out/ui_compat.o"

# The host libui.so dlopens it by this name and looks up these symbols.
readelf -dW "$out/libui_compat_layer.so" | grep -q 'SONAME.*libui_compat_layer.so' \
  || { echo "wrong SONAME" >&2; exit 1; }
for s in graphic_buffer_new_sized graphic_buffer_get_width graphic_buffer_lock; do
  readelf --dyn-syms -W "$out/libui_compat_layer.so" | grep -q " $s\$" \
    || { echo "missing exported symbol $s" >&2; exit 1; }
done

# ---------------------------------------------------------------------------
# 2. libhidltransport.so, patched
# ---------------------------------------------------------------------------
echo "== libhidltransport.so (patched)"
python3 - "$STUBS/libhidltransport.so" "$out/libhidltransport.so" <<'PY'
import struct, sys

SRC, DST = sys.argv[1], sys.argv[2]
SYM = '_ZN7android8hardware23waitForHwServiceManagerEv'
RET = bytes.fromhex('c0035fd6')            # aarch64 `ret`

# The vaddr comes from the symbol table, not from a hardcoded number: the patch
# must land on the function again if the device's library is ever replaced.
import subprocess, re
syms = subprocess.run(['readelf', '--dyn-syms', '-W', SRC],
                      capture_output=True, text=True, check=True).stdout
m = re.search(r'^\s*\d+:\s+([0-9a-f]+)\s+\d+\s+FUNC\s+GLOBAL\s+DEFAULT\s+\d+\s+' + re.escape(SYM) + r'$',
              syms, re.M)
if not m:
    sys.exit(f'{SYM} not found in {SRC}')
vaddr = int(m.group(1), 16)

d = bytearray(open(SRC, 'rb').read())

# vaddr -> file offset, through the file's own program headers (the first LOAD
# does not have p_vaddr == 0 on every Android library).
e_phoff, = struct.unpack_from('<Q', d, 0x20)
e_phentsize, e_phnum = struct.unpack_from('<HH', d, 0x36)
foff = None
for i in range(e_phnum):
    o = e_phoff + i * e_phentsize
    if struct.unpack_from('<I', d, o)[0] != 1:            # PT_LOAD
        continue
    p_offset, = struct.unpack_from('<Q', d, o + 8)
    p_vaddr,  = struct.unpack_from('<Q', d, o + 16)
    p_filesz, = struct.unpack_from('<Q', d, o + 32)
    if p_vaddr <= vaddr < p_vaddr + p_filesz:
        foff = p_offset + (vaddr - p_vaddr)
        break
if foff is None:
    sys.exit(f'{SYM} at {vaddr:#x} is in no PT_LOAD segment')

before = bytes(d[foff:foff+4])
if before == RET:
    sys.exit('already patched')

d[foff:foff+4] = RET
open(DST, 'wb').write(d)

import hashlib
print(f"   {SYM} at vaddr {vaddr:#x} -> file offset {foff:#x}: {before.hex(' ')} -> ret")
print(f"   sha256 {hashlib.sha256(d).hexdigest()}")
PY

# Only the four bytes may differ, and the soname must survive: the Android linker
# picks this file by soname, so a changed one would simply not be used.
orig_sha="$(sha256sum "$STUBS/libhidltransport.so" | cut -d' ' -f1)"
if cmp -s "$STUBS/libhidltransport.so" "$out/libhidltransport.so"; then
  echo "patched copy is identical to the original — nothing was changed" >&2; exit 1
fi
# cmp exits 1 when the files differ, which is the expected case here.
n=$( { cmp -l "$STUBS/libhidltransport.so" "$out/libhidltransport.so" || true; } | wc -l )
# `ret` shares its second byte with the `sub sp, sp, #…` it replaces, so up to
# four bytes change, not exactly four.
[ "$n" -ge 1 ] && [ "$n" -le 4 ] || { echo "expected at most 4 differing bytes, found $n" >&2; exit 1; }
[ "$(stat -c%s "$STUBS/libhidltransport.so")" = "$(stat -c%s "$out/libhidltransport.so")" ] \
  || { echo "the patched file changed length" >&2; exit 1; }
readelf -dW "$out/libhidltransport.so" | grep -q 'SONAME.*libhidltransport.so' \
  || { echo "wrong SONAME" >&2; exit 1; }
echo "   original sha256 $orig_sha ($(stat -c%s "$STUBS/libhidltransport.so") bytes, 4 changed)"

echo
sha256sum "$out/libui_compat_layer.so" "$out/libhidltransport.so"
