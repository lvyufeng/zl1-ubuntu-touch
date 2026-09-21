#!/usr/bin/env bash
# Why a Halium service jumps to address 0: its hybris bridge resolved a NULL.
#
# libhybris has two ways of reaching Android code. The ordinary one is a DT_NEEDED link
# through the Android linker. The other one is the "u_" bridge: the host library calls
# `android_dlopen("libsomething.so")` + `android_dlsym(handle, "u_something_do")` at
# runtime and then jumps straight at the result. `libubuntu_platform_hardware_api.so`
# does this for every `u_hardware_*` (it dlopens `libubuntu_application_api.so`),
# `libbiometry.so` does it for `u_hardware_biometry_*` (it dlopens
# `libbiometry_fp_api.so`), and the graphics stack does it for the compat layers.
#
# The bridge caches the pointer and has a NULL check on the *cached* value, but not on the
# value it just resolved. So a `dlsym` that returns NULL is not an error path — it is
# `br x16` with x16=0, and the core reads:
#
#     pc 0x0   si_addr=0x0   lr <host lib>+<right after bl ...@plt>
#
# That is a different signature from a NULL *data* pointer (si_addr would be a small
# offset) and from the bionic TLS fault (`__ctype_get_mb_cur_max+8`). It is what
# `build-hwc2-compat-layer.sh` warns about for libhwc2.so.1 — "it does not NULL-check
# those, so a missing one is a jump to address 0" — and it is what killed
# `lomiri-location-serviced` (only on the real gps::Provider) and `biometryd` on
# 2026-09-21. See docs/ubuntu-touch/50-*.
#
# The two halves of the question:
#   * which Android library is missing, or which symbol inside it is not exported;
#   * and the bridge needs *all* of them, so one missing symbol is enough to crash.
#
# The host half of the answer needs no device: the library name and the symbol names are
# plain strings in the host library's rodata. The device half is a file-exists test plus a
# string scan of the Android library, since the device has no readelf.
#
# Usage: check-android-bridge-libs.sh [--dev] [ELF...]
#        (no ELF given = the set this port has hit so far)
#
# Env: ZL1_HOST (default root@10.15.19.82)

set -uo pipefail
DEV="${ZL1_HOST:-root@10.15.19.82}"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$DEV")

# Where libhybris' android_dlopen looks. HYBRIS_LD_LIBRARY_PATH is what lsc-wrapper sets;
# the container's own paths are the ones a *system service* (which never goes through
# lsc-wrapper) gets, and they are why the services and the compositor can disagree.
ANDROID_PATHS="/android/system/lib64 /android/vendor/lib64 /android/odm/lib64 /system/lib64 /vendor/lib64 /odm/lib64 /usr/lib/aarch64-linux-gnu"

want_dev=0
elfs=()
for a in "$@"; do
  case "$a" in
    --dev) want_dev=1;;
    *)     elfs+=("$a");;
  esac
done
if [ ${#elfs[@]} -eq 0 ]; then
  # The bridge users this port has actually been bitten by, plus the graphics ones the
  # scripts/README notes call out. Missing files are skipped with a note, not an error:
  # this list is a convenience, an explicit argument is the supported use.
  elfs=(
    /usr/lib/aarch64-linux-gnu/liblomiri-location-service.so.3.0.0
    /usr/lib/aarch64-linux-gnu/libbiometry.so.2.0.0
    /usr/lib/aarch64-linux-gnu/libubuntu_platform_hardware_api.so.4.0.0
    /usr/lib/aarch64-linux-gnu/libhwc2.so.1
  )
fi

# A bridge user names its Android library and its symbols as literal strings, so the
# static question is answered by reading them out. `strings` is not guaranteed present, so
# this is a byte scan. Library names are the strings that look like a bare soname; the
# symbols are the `u_` ones. Both are over-approximate on purpose — the cost of checking
# one library too many is one extra file-exists test.
scan() {
  python3 - "$1" <<'PY'
import re, sys
d = open(sys.argv[1], 'rb').read()
libs, syms = [], []
for m in re.finditer(rb'[ -~]{5,}', d):
    s = m.group().decode()
    if s.startswith('lib') and s.endswith('.so') and '/' not in s:
        libs.append(s)
    elif re.fullmatch(r'u_[A-Za-z0-9_]+', s):
        syms.append(s)
print('LIBS ' + ' '.join(sorted(set(libs))))
print('SYMS ' + ' '.join(sorted(set(syms))))
PY
}

printf '%-56s %s\n' 'HOST LIBRARY' 'ANDROID BRIDGE'
for elf in "${elfs[@]}"; do
  [ -f "$elf" ] || { printf '%-56s %s\n' "$(basename "$elf")" '(not on this host — pass a path from a crash-hunt sysroot)'; continue; }
  out="$(scan "$elf")"
  libs="$(sed -n 's/^LIBS //p' <<<"$out")"
  syms="$(sed -n 's/^SYMS //p' <<<"$out")"
  printf '%-56s %s\n' "$(basename "$elf")" "${libs:-<none found>}  ($(wc -w <<<"$syms") u_ symbols)"
done

[ "$want_dev" = 1 ] || { echo; echo "Add --dev to check those names inside the container (read-only)."; exit 0; }

"${SSH[@]}" 'grep -qa msm8996 /proc/device-tree/compatible' 2>/dev/null ||
  { echo "not the zl1 (no msm8996 in /proc/device-tree/compatible) — refusing" >&2; exit 1; }

echo
echo "== on the device =="
# One ssh per host library, not one per symbol: the scan below is a handful of file tests
# and greps, and doing them one round-trip at a time turns a two-second check into a
# minute of latency. The library and symbol names go in as environment variables, which is
# what lets the heredoc be quoted — the same escaping lesson as
# install-system-tls-preload.sh.
#
# The symbol test is a byte scan of the Android library, not readelf: the device has no
# readelf, and an exported symbol is present verbatim in .dynstr. A false positive is
# possible (a name appearing in a second string table), so a MISSING verdict is the
# trustworthy one — and a missing symbol is exactly the crash being chased.
for elf in "${elfs[@]}"; do
  [ -f "$elf" ] || continue
  out="$(scan "$elf")"
  libs="$(sed -n 's/^LIBS //p' <<<"$out")"
  syms="$(sed -n 's/^SYMS //p' <<<"$out")"
  [ -n "$syms" ] || continue
  echo
  echo "--- $(basename "$elf")  needs $(wc -w <<<"$syms") u_ symbols"
  "${SSH[@]}" "LIBS='$libs' SYMS='$syms' PATHS='$ANDROID_PATHS' bash -s" <<'REMOTE'
for lib in $LIBS; do
    found=""
    for p in $PATHS; do
        # -e, not -f: a dangling symlink under a container path is itself a finding, and
        # it should read as "present but broken" rather than disappear into MISSING.
        if [ -e "$p/$lib" ]; then found="$p/$lib"; break; fi
    done
    if [ -z "$found" ]; then
        printf '    %-28s MISSING (not under any android_dlopen path)\n' "$lib"
        continue
    fi
    printf '    %-28s present at %s\n' "$lib" "$found"
    miss=""
    for s in $SYMS; do
        grep -qa "$s" "$found" 2>/dev/null || miss="$miss $s"
    done
    if [ -n "$miss" ]; then
        printf '        NOT EXPORTED:%s\n' "$miss"
        echo  '        ^ any one of these makes the bridge jump to address 0'
    else
        echo "        all $(echo $SYMS | wc -w) symbols present"
    fi
done
REMOTE
done
