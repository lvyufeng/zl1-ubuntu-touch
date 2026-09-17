#!/usr/bin/env bash
# Wait for the zl1 to show up in TWRP, then install the netdiag service.
#
# Purpose: the device exposes RNDIS only once Ubuntu Touch is running, so the
# only way to get from a wedged UT boot back to a shell is someone holding
# Volume Up + Power. That costs a human round trip every time. This does the
# setup that removes the need for all the later ones.
#
# Once netdiag is installed, the sampler can write "boot-recovery" into misc
# after a configurable delay, so the device returns itself to TWRP and its log
# can be read without anyone touching it.
#
# Usage: wait-for-twrp-and-install-netdiag.sh [SECONDS]   (default 3600)

set -uo pipefail
SER="33e80afe"
DEADLINE=$(( SECONDS + ${1:-3600} ))

echo "waiting up to ${1:-3600}s for $SER in TWRP ..."
while (( SECONDS < DEADLINE )); do
  st="$(adb devices 2>/dev/null | awk -v s="$SER" '$1==s{print $2}')"
  if [[ "$st" == "recovery" ]]; then
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) TWRP is up — installing netdiag"
    cd /mnt/data/zl1-bb10
    if ./scripts/install-netdiag-service.sh --yes; then
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) netdiag installed"
      echo "NOTE: to get the log without another button press, create the marker:"
      echo "  adb -s $SER shell 'echo 300 > /data/zl1-netdiag-reboot-recovery'"
      echo "then reboot. The sampler will ask the bootloader for recovery after 300 s."
      exit 0
    else
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) install failed" >&2
      exit 1
    fi
  fi
  sleep 10
done
echo "timed out waiting for TWRP" >&2
exit 1
