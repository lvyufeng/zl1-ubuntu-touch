#!/usr/bin/env bash
# Build service-stub -- a static aarch64 binary that serves the Android framework services a Halium
# container does not have (see service-stub.c for which, and why the camera needs them).
#
# There is no cross toolchain on this machine and none is needed: the program is freestanding, with
# no libc (its syscalls are inline asm), no dynamic linker, and no dependencies at all. clang and
# ld.lld from the Halium tree -- or the system's -- are enough.
#
# The result being *static* is the point: a binary with DT_NEEDED entries would have to be loaded by
# the target's libc, and this has to run from the host, from inside nsenter, and from the
# container's own shell without caring which libc is underneath.
#
# Usage: build.sh [--clang PATH] [--ldlld PATH]

set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
TREE="${ZL1_ANDROID_TREE:-/mnt/data/halium-zl1-build}"

CLANG="${CLANG:-}"
LDLID="${LDLID:-}"
while [ $# -gt 0 ]; do
  case "$1" in
  --clang) CLANG="$2"; shift 2 ;;
  --ldlld) LDLID="$2"; shift 2 ;;
  *) echo "usage: build.sh [--clang PATH] [--ldlld PATH]" >&2; exit 1 ;;
  esac
done

if [ -z "$CLANG" ]; then
  for c in "$TREE"/prebuilts/clang/host/linux-x86/clang-4639204/bin/clang "$(command -v clang || true)"; do
    [ -x "$c" ] && { CLANG="$c"; break; }
  done
fi
[ -n "$CLANG" ] && [ -x "$CLANG" ] || { echo "no clang found (set --clang)" >&2; exit 1; }

if [ -z "$LDLID" ]; then
  for l in "$TREE"/prebuilts/clang/host/linux-x86/clang-4639204/bin/ld.lld "$(command -v ld.lld || true)"; do
    [ -x "$l" ] && { LDLID="$l"; break; }
  done
fi

mkdir -p "$here/out"
out="$here/out/service-stub"

echo "== clang:  $CLANG"
[ -n "$LDLID" ] && echo "== ld.lld: $LDLID"

# -ffreestanding -fno-builtin: nothing from libc, including the memcpy/memset clang would otherwise
# generate for the struct copies (service-stub.c defines its own).
# -fno-stack-protector: otherwise a large local array emits a call to __stack_chk_fail, which does
# not exist here.
# -static -no-pie: no dynamic linker involvement at all.
"$CLANG" --target=aarch64-linux-gnu \
  -ffreestanding -fno-builtin -fno-stack-protector -nostdinc -nostdlib \
  -static -no-pie -O2 -Wall -Wextra \
  -fuse-ld=lld ${LDLID:+-B"$(dirname "$LDLID")"} \
  -Wl,-e,_start -Wl,--build-id=none \
  -o "$out" "$here/service-stub.c"

# Each check is a way this could produce a file that loads and does nothing, or worse, does not load.
echo "== shape"
readelf -hW "$out" | awk '/Machine:/{print "   machine: " $2} /Type:/{print "   type:    " $2} /Entry point/{print "   entry:   " $4}'
readelf -dW "$out" 2>/dev/null | grep -q NEEDED &&
  { echo "error: DT_NEEDED is not empty -- this must not depend on a libc" >&2; exit 1; }
readelf -dW "$out" 2>/dev/null | grep -q INTERP &&
  { echo "error: PT_INTERP is set -- this must not need a dynamic linker" >&2; exit 1; }
readelf -sW "$out" | grep -q ' _start$' ||
  { echo "error: no _start symbol" >&2; exit 1; }
readelf -sW "$out" | grep -q ' service_stub_main$' ||
  { echo "error: no service_stub_main symbol" >&2; exit 1; }
und="$(readelf -sW "$out" | awk '$7=="UND" && $8!="" {print $8}' | sort -u)"
[ -z "$und" ] || { echo "error: undefined symbols (there is no libc to resolve them):" >&2; echo "$und" >&2; exit 1; }

echo "== no undefined symbols, no dynamic section: this is a freestanding static binary"
ls -l "$out"
sha256sum "$out"

# The second artifact: the LD_PRELOAD instrument that takes the Android input stack out of a
# test_camera run, so the camera can be measured without the input stack's own problems in the way.
# See no-input-stack.c -- it is a measurement instrument, not a replacement for the real layer.
out_noinput="$here/out/no-input-stack.so"
echo
echo "== no-input-stack.so (LD_PRELOAD instrument for run-camera-test.sh)"
"$CLANG" --target=aarch64-linux-gnu \
  -ffreestanding -fno-builtin -fno-stack-protector -nostdinc -nostdlib \
  -shared -fPIC -O2 -Wall -Wextra \
  -fuse-ld=lld ${LDLID:+-B"$(dirname "$LDLID")"} \
  -Wl,-soname,no-input-stack.so -Wl,--build-id=none \
  -o "$out_noinput" "$here/no-input-stack.c"

readelf -dW "$out_noinput" | grep -q NEEDED &&
  { echo "error: DT_NEEDED is not empty -- it must not depend on a libc" >&2; exit 1; }
readelf -dW "$out_noinput" | grep -q 'SONAME.*\[no-input-stack.so\]' ||
  { echo "error: no SONAME" >&2; exit 1; }
# Every entry point libis.so.1 would have forwarded, so the LD_PRELOAD really does cover the set.
for s in android_input_stack_initialize android_input_stack_loop_once android_input_stack_start \
         android_input_stack_start_waiting_for_flag android_input_stack_stop \
         android_input_stack_shutdown; do
  readelf --dyn-syms -W "$out_noinput" | awk -v s="$s" '$4=="FUNC" && $8==s {found=1} END{exit !found}' ||
    { echo "error: $out_noinput does not export $s" >&2; exit 1; }
done
echo "== exports all six android_input_stack_* entry points, no DT_NEEDED"
ls -l "$out_noinput"
sha256sum "$out_noinput"
