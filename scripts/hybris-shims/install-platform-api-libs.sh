#!/usr/bin/env bash
# Install the two Android-side bridge libraries that were never built, so the two remaining
# SIGSEGVs stop being `br x16` onto NULL.
#
# The state before this script: `libubuntu_platform_hardware_api.so` (host) calls
# android_dlopen("libubuntu_application_api.so") and `libbiometry.so` (host) calls
# android_dlopen("libbiometry_fp_api.so"), and neither Android library existed anywhere on
# the device — not under /android, /vendor, /odm or the host's own /system (docs 53). The two
# services that own them, `lomiri-location-service` (the gps::Provider) and `biometryd`, died
# with `pc=0x0 si_addr=0`, which is the libhybris bridge jumping at a symbol it resolved to
# NULL and never checked (docs 50).
#
# `build-platform-api-libs.sh` produces the two libraries; this puts them where the
# compositor's shims already live and points those two services at that directory.
#
# Two things are worth being explicit about:
#
#   * The drop-in here is a *second* file (`zl1-hybris-path.conf`), not an edit of the
#     `zl1-tls.conf` that install-system-tls-preload.sh writes. systemd merges drop-ins, so
#     both environment variables end up set, and re-running that script cannot clobber this
#     one — nor the other way round.
#
#   * HYBRIS_LD_LIBRARY_PATH is the same value lsc-wrapper exports for the compositor. The
#     compositor gets it from the wrapper because lightdm builds its environment itself; a
#     plain system unit has no such wrapper, which is exactly why these two services could not
#     see /userdata/zl1-hybris/lib even though the graphics stack could.
#
# Installing the libraries only makes the symbols resolve. Whether the container registers
# `android.hardware.gnss` and `android.hardware.biometrics.fingerprint` is a separate
# question, and `--status` deliberately reports the two separately.
#
# Usage: install-platform-api-libs.sh --install | --remove | --status
#
# Env: ZL1_HOST (default root@10.15.19.82)

set -uo pipefail
DEV="${ZL1_HOST:-root@10.15.19.82}"
STAGE=/userdata/zl1-hybris
LIBDIR=$STAGE/lib
here="$(cd "$(dirname "$0")" && pwd)"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$DEV")
SCP=(scp -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

# The services whose host library dlopens one of these two. Named, not discovered: they cannot
# be found by grepping their binaries for "libhybris" — they reach Android through a runtime
# plugin, which is the same reason install-system-tls-preload.sh has an EXTRA_UNITS list.
UNITS="lomiri-location-service biometryd"

LIBS="libubuntu_application_api.so libbiometry_fp_api.so"
PATHS=/userdata/zl1-hybris/lib:/system/lib64:/odm/lib64:/vendor/lib64

guard() {
  "${SSH[@]}" 'grep -qa msm8996 /proc/device-tree/compatible' 2>/dev/null ||
    { echo "not the zl1 (no msm8996 in /proc/device-tree/compatible) — refusing" >&2; exit 1; }
}

case "${1:-}" in
--install)
  guard
  for l in $LIBS; do
    [ -f "$here/out/$l" ] ||
      { echo "build them first: $here/build-platform-api-libs.sh" >&2; exit 1; }
  done

  "${SSH[@]}" "mkdir -p $LIBDIR"
  for l in $LIBS; do
    "${SCP[@]}" "$here/out/$l" "$DEV:$LIBDIR/$l" || exit 1
    printf '%-30s %s\n' "$l" "$(sha256sum "$here/out/$l" | cut -c1-16)"
  done
  "${SSH[@]}" "chmod 644 $LIBDIR/libubuntu_application_api.so $LIBDIR/libbiometry_fp_api.so"

  # The env var goes in via stdin rather than inside the heredoc, which is what keeps the
  # heredoc quoted and the escaping trivial — same shape as install-system-tls-preload.sh.
  "${SSH[@]}" "UNITS='$UNITS' HP='$PATHS' bash -s" <<'REMOTE'
set -u
for u in $UNITS; do
  mkdir -p "/etc/systemd/system/$u.service.d"
  cat > "/etc/systemd/system/$u.service.d/zl1-hybris-path.conf" <<EOF
[Service]
Environment=HYBRIS_LD_LIBRARY_PATH=$HP
EOF
done
systemctl daemon-reload
for u in $UNITS; do
  # reset-failed first: both units have already exhausted their restart budget.
  systemctl reset-failed "$u" >/dev/null 2>&1
  systemctl restart "$u"
done
sleep 20
for u in $UNITS; do
  printf '  %-32s %s\n' "$u" "$(systemctl is-active "$u" 2>&1)"
done
REMOTE
  echo
  echo "Verify with: $0 --status"
  ;;
--remove)
  guard
  "${SSH[@]}" "
    for u in $UNITS; do
      rm -f /etc/systemd/system/\$u.service.d/zl1-hybris-path.conf
      rmdir /etc/systemd/system/\$u.service.d 2>/dev/null
    done
    systemctl daemon-reload
    rm -f $LIBDIR/libubuntu_application_api.so $LIBDIR/libbiometry_fp_api.so
    echo 'removed the drop-ins and the two libraries. The services go back to jumping to 0.'"
  ;;
--status)
  guard
  # Quoted heredoc with the values in the environment, same as the other scripts here: an
  # unquoted one needs `\$` on every variable, and that escaping has broken this repo before.
  "${SSH[@]}" "LIBDIR='$LIBDIR' LIBS='$LIBS' UNITS='$UNITS' bash -s" <<'REMOTE'
set -u
echo "libraries in $LIBDIR:"
for l in $LIBS; do
  if [ -f "$LIBDIR/$l" ]; then
    printf '  %-30s %s  %s bytes\n' "$l" "$(sha256sum "$LIBDIR/$l" | cut -c1-16)" "$(stat -c %s "$LIBDIR/$l")"
  else
    printf '  %-30s ABSENT\n' "$l"
  fi
done
echo
echo 'HYBRIS_LD_LIBRARY_PATH (via the drop-in):'
for u in $UNITS; do
  printf '  %-32s %s\n' "$u" "$(systemctl show -p Environment --value "$u" 2>&1)"
done
echo
echo 'units:'
for u in $UNITS; do
  printf '  %-32s %s\n' "$u" "$(systemctl is-active "$u" 2>&1)"
done
echo
# The one check that distinguishes "the library resolved" from "the service is happy": if the
# process is up, the library must show up in its maps.
echo 'did the process actually map its Android library?'
for u in $UNITS; do
  pid=$(systemctl show -p MainPID --value "$u" 2>/dev/null)
  if [ -n "$pid" ] && [ "$pid" != 0 ]; then
    printf '  %-32s pid %-8s %s mapping(s)\n' "$u" "$pid" \
      "$(grep -c 'libubuntu_application_api\|libbiometry_fp_api' /proc/$pid/maps 2>/dev/null)"
  else
    printf '  %-32s not running — nothing to look at\n' "$u"
  fi
done
echo
echo 'what the unit says (the real error, if it is still failing):'
for u in $UNITS; do
  echo "--- $u"
  journalctl -u "$u" -b --no-pager -n 8 2>/dev/null | sed 's/^/  /'
done
REMOTE
  ;;
--help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0" ; exit 0 ;;   # printing the manual is not an error
# Everything else, including no argument at all, keeps this script's own exit code.
*)
  awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; exit 1;;
esac
