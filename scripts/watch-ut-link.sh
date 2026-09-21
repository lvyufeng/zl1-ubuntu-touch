#!/usr/bin/env bash
# Sample the zl1 link every 2 s and report reachability plus a device-side health line.
#
# Usage: watch-ut-link.sh [SECONDS] [OUTFILE]
#
# Kept as a file rather than a shell one-liner so that `pkill -f` on it matches only the
# watcher, and so the device uptime in the output is the device's, not the host's — an
# earlier inline version labelled the host's uptime as if it were the device's.

set -uo pipefail
SECS="${1:-1800}"
OUT="${2:-/mnt/data/zl1-bb10/tmp-ut-stability.log}"
DEV=10.15.19.82

SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=6 root@$DEV)

deadline=$(( SECONDS + SECS ))
while (( SECONDS < deadline )); do
  if ping -c1 -W1 "$DEV" >/dev/null 2>&1; then s=OK; else s=FAIL; fi
  # One SSH round trip per sample is fine at 0.5 Hz, and it is the only way to get the
  # device's own view: link, container, and whether the policy tables still hold.
  info="$(timeout 12 "${SSH[@]}" '
    up=$(cut -d" " -f1 /proc/uptime)
    rp=$(awk -v i=rndis0: "\$1==i{print \$3}" /proc/net/dev 2>/dev/null)
    ta=0; for tb in 99 98 97; do n=$(ip route show table $tb 2>/dev/null | wc -l); ta=$((ta+n)); done
    c=$(lxc-info -n android -p -H 2>/dev/null | tr -d "[:space:]")
    cb=no; [ -n "$c" ] && [ -e "/proc/$c/root/dev/.coldboot_done" ] && cb=yes
    z=$(pgrep -c -f zygote 2>/dev/null || echo 0)
    echo "up=$up rx=$rp routes=$ta coldboot=$cb zygote=$z"
  ' 2>/dev/null)"
  printf '%s %s %s\n' "$(date -u +%H:%M:%S)" "$s" "${info:-ssh-failed}"
  sleep 2
done >>"$OUT" 2>&1
