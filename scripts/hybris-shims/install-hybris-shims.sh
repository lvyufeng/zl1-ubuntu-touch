#!/usr/bin/env bash
# Put the Android-side shims in front of the system compositor, or take them away.
#
# Three runtime pieces make the compositor start on this device. None of them is
# persistent and none of them writes to a partition:
#
#   /userdata/zl1-hybris/lib/libui_compat_layer.so   from libhybris compat/ui
#   /userdata/zl1-hybris/lib/libhidltransport.so     stock, 4 bytes patched
#   /usr/share/ubuntu-touch-session/lsc-wrapper      bind-mounted, patched copy
#
# The last one is the injection point. lightdm builds the compositor's
# environment itself, so nothing set on lightdm.service reaches it — but the
# wrapper is executed by lightdm, so it can set LD_PRELOAD (for the TLS-slot
# shim) and HYBRIS_LD_LIBRARY_PATH (which is how the Android linker is told to
# look in /userdata/zl1-hybris/lib *before* /system/lib64).
#
# A patched copy of the wrapper is mounted rather than a directory: the rootfs is
# a read-only image, and one file is a smaller thing to keep honest. The device's
# original is hash-checked against scripts/hybris-shims/lsc-wrapper.orig first,
# so a rootfs that has moved on is refused rather than silently overridden.
#
# Usage: install-hybris-shims.sh --mount | --unmount | --status
#
# Env: ZL1_HOST (default root@10.15.19.82), FORCE=1 to allow a drifted wrapper

set -uo pipefail
DEV="${ZL1_HOST:-root@10.15.19.82}"
STAGE=/userdata/zl1-hybris
LIBDIR=$STAGE/lib
WRAPPER=/usr/share/ubuntu-touch-session/lsc-wrapper
here="$(cd "$(dirname "$0")" && pwd)"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$DEV")
SCP=(scp -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

guard() {
  "${SSH[@]}" 'grep -qa msm8996 /proc/device-tree/compatible' 2>/dev/null ||
    { echo "not the zl1 (no msm8996 in /proc/device-tree/compatible) — refusing" >&2; exit 1; }
}

sha_of() { sha256sum "$1" | cut -d' ' -f1; }

case "${1:-}" in
--mount)
  guard
  for f in "$here/out/libui_compat_layer.so" "$here/out/libhidltransport.so"; do
    [ -f "$f" ] || { echo "build them first: $here/build-hybris-shims.sh" >&2; exit 1; }
  done

  # The file at that path is the *mounted* one once this has run, so both states
  # are legitimate: the rootfs's original, or our patched copy still mounted.
  want="$(sha_of "$here/lsc-wrapper.orig")"
  mounted="$(sha_of "$here/lsc-wrapper.zl1")"
  have="$("${SSH[@]}" "sha256sum $WRAPPER" | cut -d' ' -f1 | tr -d '\r')"
  if [ "$have" != "$want" ] && [ "$have" != "$mounted" ] && [ "${FORCE:-}" != 1 ]; then
    cat >&2 <<EOF
the device's $WRAPPER is neither the file this script was written against nor
our patched copy still mounted:
  device:     $have
  expected:   $want  (rootfs original)
              $mounted  (our patched copy)
Re-read it, re-apply the delta into lsc-wrapper.zl1, and try again — or FORCE=1
to override, having looked at what changed.
EOF
    exit 1
  fi

  "${SSH[@]}" "mkdir -p $LIBDIR"
  for f in libui_compat_layer.so libhidltransport.so; do
    "${SCP[@]}" "$here/out/$f" "$DEV:$LIBDIR/$f" || exit 1
  done
  # 0755 before the copy, not after: lightdm reports a non-executable wrapper as
  # "not found in path", which reads like a missing file rather than a mode.
  cp "$here/lsc-wrapper.zl1" "$here/out/lsc-wrapper"
  chmod 0755 "$here/out/lsc-wrapper"
  "${SCP[@]}" "$here/out/lsc-wrapper" "$DEV:$STAGE/lsc-wrapper" || exit 1

  "${SSH[@]}" "
    chmod 0755 $STAGE/lsc-wrapper
    umount $WRAPPER 2>/dev/null
    mount --bind $STAGE/lsc-wrapper $WRAPPER || exit 1
    echo 'wrapper:'; findmnt -T $WRAPPER | tail -1
    echo -n 'wrapper sha256: '; sha256sum $WRAPPER | cut -d' ' -f1
    for f in libui_compat_layer.so libhidltransport.so; do
      echo -n \"lib \$f: \"; sha256sum $LIBDIR/\$f | cut -d' ' -f1
    done"

  # The TLS-slot shim is a separate bind mount on the same path LD_PRELOAD names.
  ( cd "$here/../tlsfix" && ./install-tlsfix.sh --mount ) || exit 1

  echo "-- restarting lightdm"
  "${SSH[@]}" 'systemctl reset-failed lightdm; systemctl restart lightdm; sleep 12
    echo -n "lightdm: "; systemctl is-active lightdm
    pgrep -af "^lomiri-system-compositor" | head -1'
  ;;
--unmount)
  guard
  "${SSH[@]}" "
    umount $WRAPPER 2>/dev/null
    echo -n 'wrapper now: '; sha256sum $WRAPPER | cut -d' ' -f1"
  ( cd "$here/../tlsfix" && ./install-tlsfix.sh --unmount )
  echo "the staged libraries in $LIBDIR are inert without the wrapper and are left in place"
  ;;
--status)
  guard
  "${SSH[@]}" "
    echo '== mounts'
    findmnt -T $WRAPPER | tail -1
    findmnt -T /usr/lib/aarch64-linux-gnu/libtls-padding.so | tail -1
    echo '== hashes on the device'
    sha256sum $WRAPPER /usr/lib/aarch64-linux-gnu/libtls-padding.so $LIBDIR/*.so 2>/dev/null
    echo '== display stack'
    echo -n 'lightdm:    '; systemctl is-active lightdm
    P=\$(pgrep -f '^lomiri-system-compositor' | head -1)
    if [ -n \"\$P\" ]; then
      printf 'compositor: pid %s, up %ss\n' \"\$P\" \"\$(ps -o etimes= -p \$P | tr -d ' ')\"
      echo -n '  libhidltransport in use: '; grep -oE '/[A-Za-z0-9_/.-]*libhidltransport\.so' /proc/\$P/maps | sort -u | head -1
    else
      echo 'compositor: not running'
    fi
    echo '== last compositor output'
    tail -6 /var/log/lightdm/unity-system-compositor.log"
  ;;
*)
  sed -n '2,25p' "$0"; exit 1;;
esac
