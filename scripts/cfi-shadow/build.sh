#!/usr/bin/env bash
# Build libcfi-shadow-init.so -- the LD_PRELOAD that primes bionic's cross-DSO CFI shadow for
# libhybris processes. See cfi-shadow-init.c for what it does and why it is needed.
#
# The odd part of this build is that there is no cross toolchain on this machine: no
# aarch64-linux-gnu-gcc, no glibc sysroot for aarch64. There does not need to be one. The shim
# declares the handful of libc functions it uses itself, includes no headers at all (-nostdinc),
# and links with -nostdlib, so the only thing it needs from a toolchain is an aarch64 code
# generator and a linker that can emit an aarch64 shared object -- clang and lld, which the Halium
# tree already ships under prebuilts/clang/. Every libc symbol it references (dlsym, mmap, open,
# read, write, close, getpid, memset) is left undefined and resolves at load time from the
# libc.so.6 the target process is already running.
#
# That is why the ELF comes out with DT_NEEDED empty: correct here, and worth not "fixing".
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

# The tree's clang is the one known to emit aarch64 lld output on this machine; the system clang
# works too, and is the fallback.
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
out="$here/out/libcfi-shadow-init.so"

echo "== clang:  $CLANG"
[ -n "$LDLID" ] && echo "== ld.lld: $LDLID"

# -fno-builtin matters: with -nostdinc the compiler still knows the libc names, and a memset the
# compiler emits is fine (it resolves at runtime) but a *loop* it decides to turn into memset for
# the shadow fill would be a needless call per 8 MiB -- keep the store loop explicit.
"$CLANG" --target=aarch64-linux-gnu \
  -nostdinc -nostdlib -fPIC -shared -O2 -Wall -Wextra \
  -fuse-ld=lld ${LDLID:+-B"$(dirname "$LDLID")"} \
  -Wl,-soname,libcfi-shadow-init.so \
  -o "$out" "$here/cfi-shadow-init.c"

# The checks below are not ceremony: each one is a way this can silently produce a file that loads
# and does nothing.
echo "== shape"
readelf -hW "$out" | awk '/Machine:/{print "   machine: " $2} /Type:/{print "   type:    " $2}'
readelf -dW "$out" | grep -q 'SONAME.*libcfi-shadow-init.so' ||
  { echo "error: no SONAME" >&2; exit 1; }
# Without DT_INIT_ARRAY the "loaded" constructor never runs and a silent log is ambiguous.
readelf -dW "$out" | grep -q 'INIT_ARRAY' ||
  { echo "error: no DT_INIT_ARRAY -- the constructor would not run" >&2; exit 1; }
# The interposition is the entire point; if this symbol is not exported the shim does nothing.
readelf --dyn-syms -W "$out" | grep -q 'GLOBAL .* android_dlopen' ||
  { echo "error: android_dlopen is not exported" >&2; exit 1; }
# DT_NEEDED must stay empty -- anything listed here would have to exist on the device.
needed="$(readelf -dW "$out" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')"
[ -z "$needed" ] || { echo "error: unexpected DT_NEEDED: $needed" >&2; exit 1; }

echo "== undefined (must all exist in the target's libc.so.6):"
readelf --dyn-syms -W "$out" | awk '$7=="UND" && $8!="" {print "   " $8}'

ls -l "$out"
sha256sum "$out"
