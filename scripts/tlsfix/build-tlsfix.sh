#!/usr/bin/env bash
# Build the bionic-TLS-slot shim: a drop-in superset of libtls-padding.so.
#
# Why: on aarch64 glibc the thread pointer's slot 1 (TP+8) is tcbhead_t::private, which
# glibc never touches — and that is exactly where bionic keeps TLS_SLOT_THREAD_ID. In a
# glibc host process it therefore stays 0, __get_thread() returns NULL, and every
# __get_bionic_tls() read faults at 0xb00. The only code that fills the slot is bionic's
# __libc_init_main_thread(), which lives in the Android linker and is compiled out of
# libhybris' linker plugin. See docs/ubuntu-touch/41-bionic-tls-slot-is-never-filled.md.
#
# The result is named libtls-padding.so on purpose: Ubuntu Touch's lsc-wrapper already
# does `export LD_PRELOAD=libtls-padding.so`, so replacing that file (or bind-mounting
# over it) is what gets the shim into the system compositor.
#
# Usage: build-tlsfix.sh [OUTDIR]

set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-$here/out}"
mkdir -p "$out"

command -v clang >/dev/null || { echo "need clang on the host" >&2; exit 1; }
clang --target=aarch64-linux-gnu -shared -fPIC -nostdlib -fno-stack-protector -O2 \
      -fuse-ld=lld -o "$out/libtls-padding.so" "$here/tlsfix.c"

# The replacement must keep the shape the original has: a 128-byte TLS block and an
# initialiser. Check that, so a silent toolchain change cannot make it useless.
# Every gate below expects its pattern to BE there, so `readelf ... | grep -q PAT` would report the
# WRITER's SIGPIPE death instead of the reader's answer (this script sets pipefail): grep leaves at the
# first match, readelf is still writing, and the gate says "no tls_padding symbol" for a library that
# has one (docs/ubuntu-touch/136). Read each output once and match the text.
prog="$(readelf -lW "$out/libtls-padding.so")"
dyn="$(readelf -dW "$out/libtls-padding.so")"
sym="$(readelf -sW "$out/libtls-padding.so")"
grep -q TLS <<< "$prog" || { echo "no PT_TLS segment" >&2; exit 1; }
grep -q INIT_ARRAY <<< "$dyn" || { echo "no DT_INIT_ARRAY" >&2; exit 1; }
grep -q "TLS.*tls_padding" <<< "$sym" || { echo "no tls_padding symbol" >&2; exit 1; }
# The constructor only reaches the main thread; every thread created later needs the
# interposer, so a missing pthread_create means the fix silently covers one thread again.
grep -q "FUNC.*pthread_create" <<< "$sym" || { echo "pthread_create not exported" >&2; exit 1; }
# ...and it must have no version definition, or a versioned reference from glibc
# (pthread_create@GLIBC_2.34) would not bind to it and the interposer would never run.
if grep -q "Version definition" <<< "$(readelf -VW "$out/libtls-padding.so")"; then
  echo "the shim is versioned; the interposer would not bind" >&2; exit 1
fi

echo "built $out/libtls-padding.so"
sha256sum "$out/libtls-padding.so"
