#!/usr/bin/env bash
# Fix the stall: give Ubuntu Touch's traffic a route lookup that finds rndis0.
#
# Root cause, established 2026-09-19 from a netwatch netsnap captured on the device
# (docs/ubuntu-touch/35-the-policy-routing-rule-that-kills-the-link.md):
#
# Android's netd installs this policy routing set, in the network namespace it shares
# with Ubuntu Touch (`lxc.namespace.keep = net user`):
#
#     0:     from all lookup local
#     10000: from all fwmark 0xc0000/0xd0000 lookup 99
#     10500: from all iif lo oif dummy0 uidrange 0-0 lookup 1003
#     13000: from all fwmark 0x10063/0x1ffff iif lo lookup 97
#     14000: from all iif lo oif dummy0 lookup 1003
#     15000: from all fwmark 0/0x10000 lookup 99
#     16000: from all fwmark 0/0x10000 lookup 98
#     17000: from all fwmark 0/0x10000 lookup 97
#     32000: from all unreachable
#
# UT's packets carry no fwmark, so they match 15000/16000/17000, which select tables 99,
# 98 and 97 — and those tables are EMPTY. The lookup finds nothing, falls through, and
# rule 32000 declares the packet unreachable. The packet is never constructed, so
# eth_start_xmit is never called: that is why tx_pkts and the driver's tx_pkts_rcvd are
# exactly equal and no netdev counter moves.
#
# ip route get 192.168.2.100 answers "Network is unreachable" while the main table holds
# "192.168.2.0/24 dev rndis0". The routes are fine; the rules hide them.
#
# The fix is one rule ahead of netd's, selecting the main table, which does have the
# routes. It runs from netwatch because netd installs its rules partway into the boot —
# 2.4 seconds was enough to go from working to dead on 2026-09-18.
#
# Usage: fix-policy-routing.sh --yes          (device in TWRP: install into netwatch)
#        fix-policy-routing.sh --yes --remove

set -uo pipefail
SER="33e80afe"
SRC="/mnt/data/zl1-bb10/scripts/device/zl1-netwatch.sh"
# The patched netwatch is kept as a separate file rather than editing in place, so the
# original stays intact if this turns out to be wrong.
DEST_NAME="zl1-netwatch.sh"

[[ "${1:-}" == "--yes" ]] || { echo "refusing without --yes" >&2; exit 2; }

adb devices 2>/dev/null | awk -v s="$SER" '$1==s{found=1} END{exit found?0:1}' \
  || { echo "target $SER not visible in adb (need TWRP)" >&2; exit 1; }

if [[ "${2:-}" == "--remove" ]]; then
  echo "Nothing to remove on the device: the rule is added at runtime by netwatch and"
  echo "disappears on reboot. To stop netwatch adding it, install the unpatched script."
  exit 0
fi

[[ -f "$SRC" ]] || { echo "missing $SRC" >&2; exit 1; }
grep -q 'zl1: policy routing fix' "$SRC" || { echo "the netwatch source has no policy-routing fix; patch it first" >&2; exit 1; }

echo "== this only installs the patched script; the rule itself is added at boot =="
adb -s "$SER" push "$SRC" "/data/system-data/etc/systemd/system/$DEST_NAME" >/dev/null
adb -s "$SER" shell "chmod 0755 /data/system-data/etc/systemd/system/$DEST_NAME; ls -l /data/system-data/etc/systemd/system/$DEST_NAME" | tr -d '\r'
adb -s "$SER" shell sync || true
echo
echo "== installed. Reboot into UT; the rule is added within ~15 s of the interface"
echo "   coming up, and netwatch logs whether it took:"
echo "   grep 'policy routing' /data/zl1-netwatch.log"
