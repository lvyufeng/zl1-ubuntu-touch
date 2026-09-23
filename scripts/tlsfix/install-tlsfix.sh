#!/usr/bin/env bash
# Put the bionic-TLS-slot shim in front of libtls-padding.so on the device, or take it away.
#
# Ubuntu Touch's /usr/share/ubuntu-touch-session/lsc-wrapper does
#     export LD_PRELOAD=libtls-padding.so
# before exec'ing lomiri-system-compositor. lightdm builds the compositor's environment
# itself, so an LD_LIBRARY_PATH set on lightdm.service does NOT reach it — but replacing
# that one file does, and a bind mount replaces it without writing to the read-only rootfs.
#
# This is a runtime change: it is gone after a reboot, and --unmount undoes it. Nothing
# persistent is touched, no partition is written.
#
# Usage: install-tlsfix.sh --mount | --unmount | --status
#
# Env: ZL1_HOST (default root@10.15.19.82 — the device's RNDIS address)

set -uo pipefail
DEV="${ZL1_HOST:-root@10.15.19.82}"
LIB=/usr/lib/aarch64-linux-gnu/libtls-padding.so
STAGE=/userdata/zl1-tlsfix/shadow/libtls-padding.so
here="$(cd "$(dirname "$0")" && pwd)"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$DEV")
SCP=(scp -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

# The device is the only thing at that address, but a wrong address would mean writing a
# bind mount onto somebody else's machine, so check the SoC first.
guard() {
  "${SSH[@]}" 'grep -qa msm8996 /proc/device-tree/compatible' 2>/dev/null ||
    { echo "not the zl1 (no msm8996 in /proc/device-tree/compatible) — refusing" >&2; exit 1; }
}

case "${1:-}" in
--mount)
  guard
  [ -f "$here/out/libtls-padding.so" ] || { echo "build it first: $here/build-tlsfix.sh" >&2; exit 1; }
  "${SSH[@]}" "mkdir -p $(dirname $STAGE)"
  "${SCP[@]}" "$here/out/libtls-padding.so" "$DEV:$STAGE" || exit 1
  # Unmount first so running this twice does not stack two bind mounts on one file.
  "${SSH[@]}" "umount $LIB 2>/dev/null; mount --bind $STAGE $LIB || exit 1
    echo 'mounted:'; findmnt -T $LIB | tail -1
    echo -n 'sha256 on device: '; sha256sum $LIB | cut -d' ' -f1"
  echo "now: systemctl reset-failed lightdm; systemctl restart lightdm"
  ;;
--unmount)
  guard
  "${SSH[@]}" "umount $LIB 2>/dev/null; echo -n 'after unmount: '; sha256sum $LIB | cut -d' ' -f1"
  ;;
--status)
  guard
  "${SSH[@]}" "findmnt -T $LIB | tail -1; echo -n 'sha256: '; sha256sum $LIB | cut -d' ' -f1
    echo -n 'lightdm: '; systemctl is-active lightdm
    echo -n 'compositor: '; pgrep -af lomiri-system-compositor | head -2"
  ;;
--help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0" ; exit 0 ;;   # printing the manual is not an error
# Everything else, including no argument at all, keeps this script's own exit code.
*)
  awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; exit 1;;
esac
