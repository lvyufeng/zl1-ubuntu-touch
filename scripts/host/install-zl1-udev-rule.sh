#!/usr/bin/env bash
# Install (or remove) the host-side udev rule that brings up usb0 for the zl1 by itself.
#
# This is Phase 3.1 of docs/ubuntu-touch/17-adaptation-plan.md. Until now the host side of
# the RNDIS link was configured by scripts/host-watch-usb0.sh, which works but only while
# it is running — and on 2026-09-20 it was not running, which is how a 14.7-hour cold boot
# came to be judged as a failed one. A udev rule has no such state.
#
# Installs two files:
#   /etc/udev/rules.d/99-zl1-rndis.rules
#   /usr/local/sbin/zl1-rndis-udev-helper.sh
#
# Usage: install-zl1-udev-rule.sh [--yes] [--remove]

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULE_SRC="$HERE/99-zl1-rndis.rules"
HELPER_SRC="$HERE/zl1-rndis-udev-helper.sh"
RULE_DST="/etc/udev/rules.d/99-zl1-rndis.rules"
HELPER_DST="/usr/local/sbin/zl1-rndis-udev-helper.sh"

# Reading the manual is not an action, so --help comes before the --yes gate: a script whose own
# header documents a Usage line should be able to print that header without being handed a
# permission flag first. (This is the one script the health check names that could not.)
case "${1:-}" in
--help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0" ; exit 0 ;;
esac

[[ "${1:-}" == "--yes" || "${1:-}" == "--remove" ]] || { echo "refusing without --yes" >&2; exit 2; }

if [[ "${1:-}" == "--remove" ]]; then
  sudo -n rm -f "$RULE_DST" "$HELPER_DST"
  sudo -n udevadm control --reload-rules
  echo "removed $RULE_DST and $HELPER_DST"
  echo "note: /var/log/zl1-rndis-udev.log is left in place"
  exit 0
fi

[[ -f "$RULE_SRC" && -f "$HELPER_SRC" ]] || { echo "missing source files next to this script" >&2; exit 1; }

sudo -n install -m 0755 "$HELPER_SRC" "$HELPER_DST"
sudo -n install -m 0644 "$RULE_SRC"   "$RULE_DST"
sudo -n touch /var/log/zl1-rndis-udev.log
sudo -n udevadm control --reload-rules
sudo -n udevadm trigger --subsystem-match=usb || true

echo "installed:"
echo "  $RULE_DST"
echo "  $HELPER_DST"
echo
echo "test it against the xiaomi (must be skipped, not configured):"
echo "  sudo $HELPER_DST 3-10:1.0 ; tail -1 /var/log/zl1-rndis-udev.log"
echo "test it against the zl1 in Ubuntu Touch:"
echo "  sudo $HELPER_DST ; tail -3 /var/log/zl1-rndis-udev.log ; ip -br addr show usb0"
