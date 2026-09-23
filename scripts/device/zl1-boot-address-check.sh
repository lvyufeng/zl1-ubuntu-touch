#!/bin/sh
# zl1 boot-address check -- "who gave rndis0 its addresses on this boot, and when?" Read-only.
#
# Why this exists (docs/ubuntu-touch/88): the v63 debug keeper is the second heat source on this
# port (docs 72 section 4b: a full core, because its 1 Hz loop makes systemd daemon-reload every
# ~6 s). Retiring it was blocked on one unverified question -- "does a boot without the keeper still
# get an address?" -- because losing the address means losing SSH, and getting SSH back needs a
# finger on the power button.
#
# Reading the netwatch script answered the question: `restore_addrs()` was reachable only from the
# two heal stages, and a heal needs 45 s of failed host pings *and* uptime >= 90. So a keeper-less
# boot would have no SSH for ~135 s and the first fix would be a full RNDIS re-enumeration. Not
# fatal, but a worse boot every boot. The addresses are now re-asserted by the netwatch itself
# (`ensure_addrs()`, logged as `ADDRS: ...`), which is installed *before* the keeper is retired.
#
# This script answers whether that actually happened on the boot you are looking at. It reads the
# netwatch log, the live interface, and the keeper's state -- nothing else, and it writes nothing.
#
# The three verdicts are what decide the next move:
#
#   * ADDRS line, no heal before it   -> the new path works; the keeper can be retired (stage 2)
#   * no ADDRS line but a heal did it -> the old pathology: the addresses arrived ~135 s late via a
#                                        gadget re-enumeration. Do NOT retire the keeper yet.
#   * no ADDRS line and no heal, yet the addresses are there -> the keeper did it (it is still
#     running, which is expected in stage 1). The netwatch path is unproven -- inconclusive.
#
# Usage: zl1-boot-address-check.sh [--quiet] [--log FILE]
#   --quiet     verdict only
#   --log FILE  read a different netwatch log (default /userdata/zl1-netwatch.log)
#
# Exit codes: 0 = the netwatch configured them (keeper can be retired); 1 = it did not (read the
# reason in the output); 2 = not the zl1.

set -u

QUIET=0
NETLOG=/userdata/zl1-netwatch.log

while [ $# -gt 0 ]; do
  case "$1" in
  --quiet) QUIET=1; shift ;;
  --log) NETLOG="$2"; shift 2 ;;
  --help|-h) sed -n '2,33p' "$0"; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

say() { [ "$QUIET" = 1 ] && return 0; printf '%s\n' "$*"; }
always() { printf '%s\n' "$*"; }

model="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null | tr -d '\n')"
always "zl1 boot-address check :: uptime $(cut -d' ' -f1 /proc/uptime 2>/dev/null) s"
case "$model" in
*LE_ZL1*) always "== device: $model" ;;
*) always "== WARNING: device-tree model is \"$model\", not LE_ZL1. Stop."; exit 2 ;;
esac

# --- 1. live state ------------------------------------------------------------------------------

IFACE=""
for i in rndis0 usb0; do
  [ -e "/sys/class/net/$i" ] && { IFACE="$i"; break; }
done
if [ -z "$IFACE" ]; then
  always ""
  always "== no rndis0/usb0 interface at all."
  always "   Nothing to judge yet: either the gadget is not bound, or a heal is mid-flight."
  exit 1
fi

live="$(ip -4 addr show dev "$IFACE" 2>/dev/null | awk '/inet /{printf "%s ", $2}')"
say "== interface $IFACE: ${live:-<no IPv4>}"
for a in 192.168.2.15/24 10.15.19.82/24; do
  case " $live " in
  *" $a "*) say "   $a: present" ;;
  *) always "   $a: MISSING -- the host cannot reach this device on that address" ;;
  esac
done

# --- 2. the netwatch service --------------------------------------------------------------------

say ""
say "== the netwatch service (the thing that is supposed to own this now)"
nw_pid=""
for p in /proc/[0-9]*; do
  c=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
  case "$c" in *zl1-netwatch.sh*) nw_pid="${p#/proc/}"; break ;; esac
done
if [ -n "$nw_pid" ]; then
  # field 22 of /proc/<pid>/stat is starttime in clock ticks; HZ is 100 on this kernel, so the
  # process's own age in seconds is (uptime - starttime/100). Strip comm first: it is
  # parenthesised and may contain spaces (the trap from doc 81).
  st=$(awk '{ sub(/^[^)]*\) /, ""); print $20 }' "/proc/$nw_pid/stat" 2>/dev/null)
  age=""
  [ -n "$st" ] && age="$(( $(cut -d. -f1 /proc/uptime) - st / 100 )) s ago"
  say "   running, pid $nw_pid${age:+ (started $age)}, unit: $(systemctl is-active zl1-netwatch 2>/dev/null || echo '<not a unit here>')"
else
  always "   NOT RUNNING. Without it nothing re-asserts the addresses, and nothing heals a stall."
  always "   That is the more urgent problem -- install it before anything else."
fi

# the address functions must be in the installed copy: this is what distinguishes "installed the
# fixed build" from "installed an older one", which sh -n cannot see (the 2026-09-19 lesson).
inst=/etc/systemd/system/zl1-netwatch.sh
if [ -r "$inst" ]; then
  if grep -q '^ensure_addrs()' "$inst"; then
    say "   installed build has ensure_addrs() -- the address path is in it"
  else
    always "   the INSTALLED build has no ensure_addrs(): it cannot configure the addresses."
    always "   Re-install with scripts/install-netwatch-service.sh --yes."
  fi
else
  say "   $inst not readable from here (TWRP-only path?); cannot check the installed build"
fi

# --- 3. this boot's section of the log ----------------------------------------------------------

say ""
say "== netwatch log: $NETLOG"

if [ ! -r "$NETLOG" ]; then
  always "   not readable. If the service just started, give it a few seconds; if it is missing"
  always "   entirely, the service is not installed."
  exit 1
fi

# The log appends across boots and every line is prefixed with the uptime it was written at. The
# `netwatch start` line is the boot boundary.
awk '
  / netwatch start / { n++; buf=""; start=$0; next }
  { if (n > 0) buf = buf $0 "\n" }
  END { printf "%s", buf }
' "$NETLOG" > /tmp/.bootaddrs.$$

if [ ! -s /tmp/.bootaddrs.$$ ]; then
  always "   no 'netwatch start' line in the log: it has never run on this device."
  rm -f /tmp/.bootaddrs.$$
  exit 1
fi

n_start=$(grep -c ' netwatch start ' "$NETLOG" 2>/dev/null)
say "   boots in this log: $n_start   (showing the newest)"

say ""
say "   the address line, if there is one:"
if grep -q '^[0-9.]*s ADDRS:' /tmp/.bootaddrs.$$; then
  grep '^[0-9.]*s ADDRS:' /tmp/.bootaddrs.$$ | sed 's/^/   | /'
  addrs_line=$(grep '^[0-9.]*s ADDRS:' /tmp/.bootaddrs.$$ | head -1)
  addrs_uptime=$(printf '%s' "$addrs_line" | sed 's/^\([0-9.]*\)s .*/\1/' | cut -d. -f1)
else
  addrs_line=""
  addrs_uptime=""
  always "   (none -- the netwatch did not configure the addresses on this boot)"
fi

say ""
say "   stalls and heals on this boot:"
if grep -qE '^[0-9.]*s (STALL|HEAL)' /tmp/.bootaddrs.$$; then
  grep -E '^[0-9.]*s (STALL|HEAL)' /tmp/.bootaddrs.$$ | head -12 | sed 's/^/   | /'
  first_heal=$(grep -E '^[0-9.]*s HEAL [AB]:' /tmp/.bootaddrs.$$ | head -1 | sed 's/^\([0-9.]*\)s .*/\1/' | cut -d. -f1)
else
  always "   (none)"
  first_heal=""
fi

# --- 4. who did it, and was the keeper there ----------------------------------------------------

say ""
say "== the keeper (stage 1 expects it to still be running; that is the safety net)"
k_pids=""
for p in /proc/[0-9]*; do
  c=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
  case "$c" in *zl1-debug-net.sh*) k_pids="$k_pids ${p#/proc/}" ;; esac
done
if [ -z "$k_pids" ]; then
  say "   not running"
else
  for p in $k_pids; do
    st=$(awk '{print $3}' "/proc/$p/stat" 2>/dev/null)
    case "$st" in
    T) say "   pid $p: SIGSTOPped (state T) -- not configuring anything" ;;
    *) say "   pid $p: state $st -- still running its 1 Hz loop" ;;
    esac
  done
fi

# --- 5. verdict ---------------------------------------------------------------------------------

always ""
always "== verdict"

# "the netwatch configured them, before any heal" is the only state that licenses stage 2.
if [ -n "$addrs_uptime" ]; then
  case "$first_heal" in
  "")  verdict="netwatch-configured"
       always "   The netwatch applied the addresses at uptime ${addrs_uptime}s, and no heal was"
       always "   needed to get there. Stage 1 is proven on this boot: the keeper is no longer the"
       always "   only thing that can configure this interface." ;;
  *)   if [ "$addrs_uptime" -le "$first_heal" ]; then
         verdict="netwatch-configured"
         always "   The netwatch applied the addresses at uptime ${addrs_uptime}s, before the first"
         always "   heal (uptime ${first_heal}s). Stage 1 is proven on this boot."
       else
         verdict="heal-first"
         always "   The addresses came at uptime ${addrs_uptime}s, but a heal fired first at"
         always "   ${first_heal}s -- so this boot still needed the old path. Investigate before"
         always "   retiring the keeper: read the STALL/HEAL lines above."
       fi ;;
  esac
elif [ -n "$first_heal" ]; then
  verdict="heal-first"
  always "   No ADDRS line, but a heal fired at uptime ${first_heal}s. That is the pathology docs 88"
  always "   describes: on a keeper-less boot the addresses would have arrived only here, ~135 s in,"
  always "   after a full RNDIS re-enumeration. Do NOT retire the keeper yet -- the installed build"
  always "   probably predates ensure_addrs() (see above)."
else
  verdict="inconclusive"
  always "   The addresses are present but the netwatch never logged configuring them, and no heal"
  always "   fired -- so the keeper is what configured them (it is still running, which is what"
  always "   stage 1 expects). This boot says nothing about the netwatch path."
  always "   To get a verdict: make sure the installed build has ensure_addrs(), re-run the boot,"
  always "   and read this again."
fi

say ""
say "   What this does NOT prove: it does not say the address was applied *early enough* to matter"
say "   (compare ${addrs_uptime:-?}s against how long the host took to reach the device), it does"
say "   not prove the host side resolves the pair (the host has its own static routes -- test with"
say "   a ping from the host), and one boot is one boot: the 2026-09-17 stall work needed a rate,"
say "   not a sample. Retire the keeper on a boot that reads 'netwatch-configured', and keep the"
say "   reinstall command to hand in case the next boot disagrees."

rm -f /tmp/.bootaddrs.$$
case "$verdict" in
netwatch-configured) exit 0 ;;
*) exit 1 ;;
esac
