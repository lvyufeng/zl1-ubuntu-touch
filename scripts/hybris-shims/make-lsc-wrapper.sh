#!/usr/bin/env bash
# Regenerate lsc-wrapper.zl1 from the rootfs's lsc-wrapper.orig.
#
# lsc-wrapper is the only place the system compositor's environment can be set:
# lightdm builds that environment itself, so nothing set on lightdm.service
# reaches the compositor, but the wrapper *is* executed by lightdm. So the
# wrapper is where the Hybris search path and the PID-namespace fix have to go.
#
# Keeping it as a generated file with a two-hunk delta means the device's
# original stays reviewable next to it, and a rootfs that moved on shows up as a
# hash mismatch in install-hybris-shims.sh rather than as a silently patched
# file.
#
# Usage: make-lsc-wrapper.sh [--check]
#   --check  only verify that lsc-wrapper.zl1 matches what would be generated

set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
orig="$here/lsc-wrapper.orig"
out="$here/lsc-wrapper.zl1"

[ -f "$orig" ] || { echo "missing $orig" >&2; exit 1; }

python3 - "$orig" >"$out.tmp" <<'PY'
import sys

src = open(sys.argv[1]).read()

# --- hunk 1: the Android linker's search path -----------------------------
anchor = "export LD_PRELOAD=libtls-padding.so\n"
addition = """
# Halium resolves the Android-side libraries through HYBRIS_LD_LIBRARY_PATH.
# Without it the Android linker only searches /system/lib64, /odm/lib64 and
# /vendor/lib64. The stock LeEco image has no libui_compat_layer.so and no
# libhwc2_compat_layer.so, so put the copies built for this device first.
export HYBRIS_LD_LIBRARY_PATH=/userdata/zl1-hybris/lib:/system/lib64:/odm/lib64:/vendor/lib64
"""
assert src.count(anchor) == 1, "LD_PRELOAD line not found exactly once"
src = src.replace(anchor, anchor + addition)

# --- hunk 2: the PID namespace -------------------------------------------
old_exec = """exec lomiri-system-compositor \\
"""
new_exec = """# Android's binder only completes a transaction between two processes in the
# same PID namespace. The compositor runs in the host's; every Android HAL and
# both of binder's service managers (servicemanager, hwservicemanager) run in
# the LXC container's. A lookup across that boundary does not fail loudly -- the
# transaction is accepted and the reply comes back empty -- so every Android
# service looks absent. `service list` run from the host root reports "Found 0
# services:" while the same binary inside the container reports 19.
#
# nsenter -p forks, and it is the *child* that lands in the container's
# namespace (setns on a PID namespace only affects future children). Do not add
# -F/--no-fork: that makes the exec'd process stay in the parent namespace while
# its children go to the new one, and pthread_create then fails with EINVAL
# because a thread cannot share a thread group across the two.
#
# util-linux's nsenter does not always reap a child that lived in another PID
# namespace, so a round can leave one behind in do_wait with no children. They
# are inert, but each one holds the namespace open, so sweep the childless ones
# before starting another.
for p in $(pgrep -x nsenter 2>/dev/null); do
    [ -s "/proc/$p/task/$p/children" ] || kill -TERM "$p" 2>/dev/null
done

ANDROID_INIT_PID=$(lxc-info -n android -pH 2>/dev/null | head -1)
if [ -n "$ANDROID_INIT_PID" ] && [ -e "/proc/$ANDROID_INIT_PID/ns/pid" ]; then
    exec nsenter -t "$ANDROID_INIT_PID" -p -- /usr/sbin/lomiri-system-compositor \\
        $LSC_FLAGS \\
        --console-provider=vt \\
        --spinner=/usr/bin/lomiri-system-compositor-spinner \\
        "$@"
fi

exec lomiri-system-compositor \\
"""
assert src.count(old_exec) == 1, "exec line not found exactly once"
src = src.replace(old_exec, new_exec)

sys.stdout.write(src)
PY
rc=$?
if [ $rc -ne 0 ]; then rm -f "$out.tmp"; exit 1; fi

chmod 0755 "$out.tmp"
if [ "${1:-}" = "--check" ]; then
  if cmp -s "$out.tmp" "$out"; then
    echo "lsc-wrapper.zl1 is up to date"
    rm -f "$out.tmp"
    exit 0
  fi
  echo "lsc-wrapper.zl1 differs from what lsc-wrapper.orig generates:" >&2
  diff -u "$out" "$out.tmp" >&2 || true
  rm -f "$out.tmp"
  exit 1
fi

mv "$out.tmp" "$out"
echo "wrote $out"
sha256sum "$out"
