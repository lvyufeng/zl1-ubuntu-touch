#!/usr/bin/env bash
# Build crash-dump.so -- the LD_PRELOAD that turns "exit 139" into a report with a backtrace and
# /proc/self/maps. See crash-dump.c for what it does and why the device needs it.
#
# Same shape as scripts/cfi-shadow/build.sh, and for the same reason: there is no aarch64 cross
# toolchain on this machine, so the shim includes no headers (-nostdinc), declares the three libc
# functions it uses itself, and links with -nostdlib. Everything it needs from a toolchain is an
# aarch64 code generator (clang) and an aarch64 linker (lld), both of which the Halium tree already
# ships. The three libc symbols are left undefined and resolve at load time from the libc.so.6 the
# target process is already running -- which is why DT_NEEDED is empty, and correct.
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
out="$here/out/crash-dump.so"

echo "== clang:  $CLANG"
[ -n "$LDLID" ] && echo "== ld.lld: $LDLID"

"$CLANG" --target=aarch64-linux-gnu \
  -nostdinc -nostdlib -fPIC -shared -O2 -Wall -Wextra \
  -fuse-ld=lld ${LDLID:+-B"$(dirname "$LDLID")"} \
  -Wl,-soname,crash-dump.so \
  -o "$out" "$here/crash-dump.c"

# Each check below is a way this can silently produce a file that loads and does nothing.
echo "== shape"
readelf -hW "$out" | awk '/Machine:/{print "   machine: " $2} /Type:/{print "   type:    " $2}'
# Read once, then match the text: both gates below expect their pattern to BE there, and
# `readelf ... | grep -q PAT` reports the WRITER's SIGPIPE death under this script's `set -o pipefail`
# -- i.e. "no SONAME" for a library that has one (docs/ubuntu-touch/136).
dyn="$(readelf -dW "$out")"
grep -q 'SONAME.*crash-dump.so' <<< "$dyn" ||
  { echo "error: no SONAME" >&2; exit 1; }
# Without DT_INIT_ARRAY the handler is never installed and a run that crashes normally looks the
# same as a run that crashes with this preloaded -- the exact ambiguity this exists to remove.
grep -q 'INIT_ARRAY' <<< "$dyn" ||
  { echo "error: no DT_INIT_ARRAY -- the constructor would not run" >&2; exit 1; }
needed="$(sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' <<< "$dyn")"
[ -z "$needed" ] || { echo "error: unexpected DT_NEEDED: $needed" >&2; exit 1; }

# The undefined set is asserted exactly, not merely listed. Two of the three are the backtrace pair,
# and if a build ever drops them the report silently loses its most useful half; an unexpected fourth
# name would mean the file no longer loads on the device at all.
echo "== undefined (must all exist in the target's libc.so.6)"
undef="$(readelf --dyn-syms -W "$out" | awk '$7=="UND" && $8!="" {print $8}' | sort -u)"
echo "$undef" | sed 's/^/   /'
expected="$(printf '%s\n' backtrace backtrace_symbols_fd signal | sort -u)"
[ "$undef" = "$expected" ] ||
  { echo "error: undefined symbols are not the expected three" >&2; exit 1; }

ls -l "$out"
sha256sum "$out"
