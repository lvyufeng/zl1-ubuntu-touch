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
# **`inconclusive` is the expected verdict on most keeper-alive boots, and that is not a retry.**
# `ensure_addrs()` logs only when an address was missing, and the keeper re-adds both every second --
# so on a boot where the keeper is alive the netwatch gets an ADDRS line only by winning a race whose
# window is under a second wide. Re-running the boot is re-rolling that race. The keeper-less boot
# being asked about does not have the race at all (nothing else would configure the interface), which
# is why the measurement to run is the one that removes the keeper's contribution on purpose:
#
#   scripts/device/zl1-address-owner-proof.sh --yes      (stops the keeper, one address, see below)
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
# The keeper's FULL path, because the rule at section 4 compares whole argv elements against it rather
# than searching for the name (docs 179).
KEEPER_PATH=/usr/local/sbin/zl1-debug-net.sh
# The netwatch's, for the same rule in section 2 (its unit execs exactly this, scripts/install-netwatch-service.sh).
NW_PATH=/etc/systemd/system/zl1-netwatch.sh

while [ $# -gt 0 ]; do
  case "$1" in
  --quiet) QUIET=1; shift ;;
  --log) NETLOG="${2?--log needs a FILE argument}"; shift 2 ;;
  --help|-h)
    # The header whatever its current length, not `sed -n '2,33p'` -- a fixed line range silently
    # truncates the usage text the moment the header grows past it (docs 104, and docs 108 for the
    # two places it was still wrong).
    awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; exit 0 ;;
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
# MATCHED BY ARGV TOO, and for the same reason as the keeper below (docs 179): this decides whether the
# page says "running, pid N" or "NOT RUNNING -- install it before anything else", and a process that
# merely MENTIONS the netwatch is not it. The path is what the unit execs (ExecStart in
# scripts/install-netwatch-service.sh), and a shebang script is exec'd as <interpreter> <script>.
nw_pid=""
for p in /proc/[0-9]*; do
  [ -d "$p" ] || continue
  [ "${p#/proc/}" = "$$" ] && continue
  set -- $(tr '\0' '\n' < "$p/cmdline" 2>/dev/null)
  a0=${1:-}; a1=${2:-}; hit=0
  case "$a1" in "$NW_PATH") hit=1 ;; esac
  if [ "$hit" = 0 ]; then
    case "$a0" in
    "$NW_PATH") hit=1 ;;
    */sh|*/dash|*/bash|*/busybox|sh|dash|bash|busybox) case "$a1" in "$NW_PATH") hit=1 ;; esac ;;
    esac
  fi
  [ "$hit" = 1 ] && { nw_pid="${p#/proc/}"; break; }
done
if [ -n "$nw_pid" ]; then
  # field 22 of /proc/<pid>/stat is starttime in clock ticks; HZ is 100 on this kernel, so the
  # process's own age in seconds is (uptime - starttime/100). Strip comm first: it is
  # parenthesised and may contain spaces (the trap from doc 81).
  st=$(awk '{ sub(/^[^)]*\) /, ""); print $20 }' "/proc/$nw_pid/stat" 2>/dev/null)
  age=""
  [ -n "$st" ] && age="$(( $(cut -d. -f1 /proc/uptime) - st / 100 )) s ago"
  # `systemctl is-active` prints "inactive" AND exits non-zero, so a `|| echo` after it printed both
  # the state and the fallback. Capture instead: an empty capture means systemctl is not set up here.
  u=$(systemctl is-active zl1-netwatch 2>/dev/null)
  say "   running, pid $nw_pid${age:+ (started $age)}, unit: ${u:-<not a unit here>}"
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
#
# ONE STREAMING PASS, and it prints ONLY the lines section 3 and 4 look at.
#
# It used to accumulate the newest section into a string (`buf = buf $0 "\n"`) and print it from
# END. That is quadratic in the section's length whenever `awk` has no in-place append, and the
# `awk` a `#!/bin/sh` script gets on this rootfs is one of those. Measured on the host with a
# 36 MB single section (the shape this log really has: a ~1.6 KB block every 5 s, and a boundary
# only when the service starts, so the newest section is the whole tail of the file):
#
#     gawk   0.41 s        <- which is why nobody saw this from a workstation
#     mawk   > 120 s, killed, nothing written out
#
# On 2026-09-23 the device ran this at 94 % of a core for 11+ minutes on a 63 MB log, at load ~9,
# and that boot ended in Qualcomm EDL (docs 108). The section size on the device was never
# measured, because the device it was running on is the one that went to EDL.
#
# The count now comes out of the same pass, so the 63 MB is read once instead of twice, and `CAP`
# bounds what is kept, so no log can make this file -- or the greps below -- large.
#
# The kept lines are held until END and printed there, but that is NOT the old accumulator: only the
# newest section survives (`kept` resets at every boundary, so the array is overwritten and the loop
# at the end ignores the stale tail), and it is capped, so its size is O(CAP) and not O(section). The
# first version of this fix printed each line as it was matched and so leaked the PREVIOUS boots'
# ADDRS/HEAL lines into the newest section's verdict -- the harness caught it as scenario C.
CAP=2000   # ADDRS/STALL/HEAL lines are rare; the report shows 1 of the first and 12 of the second
SEC=/tmp/.bootaddrs.$$
awk -v cap="$CAP" '
  / netwatch start / { n++; kept=0; next }
  n > 0 && /^[0-9.]+s (ADDRS|STALL|HEAL)/ { if (++kept <= cap) keep[kept] = $0 }
  END {
    for (i = 1; i <= kept; i++) print keep[i]
    printf "#section boots=%d kept=%d cap=%d\n", n, kept + 0, cap
  }
' "$NETLOG" > "$SEC"

# A section that exists but holds no ADDRS/STALL/HEAL line now leaves a file with ONE line (the
# header), where it used to leave an empty one -- so emptiness can no longer mean "the service has
# never run". That verdict is read out of the header instead, and an unreadable header is its own
# answer rather than being folded into "no start line".
n_start=$(sed -n 's/^#section boots=\([0-9][0-9]*\) kept=.*$/\1/p' "$SEC" 2>/dev/null)
if [ -z "$n_start" ]; then
  always "   the log could not be scanned: the reader produced no header. Is '$NETLOG' readable,"
  always "   and does the awk on this device handle it?"
  rm -f "$SEC"
  exit 1
fi
n_kept=$(sed -n 's/^#section boots=[0-9][0-9]* kept=\([0-9][0-9]*\) .*$/\1/p' "$SEC" 2>/dev/null)

if [ "$n_start" = 0 ]; then
  always "   no 'netwatch start' line in the log: it has never run on this device."
  rm -f "$SEC"
  exit 1
fi

say "   boots in this log: $n_start   (showing the newest)"
[ "${n_kept:-0}" -gt "$CAP" ] && always "   (only the first $CAP ADDRS/STALL/HEAL lines were kept)"

say ""
say "   the address line, if there is one:"
if grep -q '^[0-9.]*s ADDRS:' "$SEC"; then
  grep '^[0-9.]*s ADDRS:' "$SEC" | sed 's/^/   | /'
  addrs_line=$(grep '^[0-9.]*s ADDRS:' "$SEC" | head -1)
  addrs_uptime=$(printf '%s' "$addrs_line" | sed 's/^\([0-9.]*\)s .*/\1/' | cut -d. -f1)
else
  addrs_line=""
  addrs_uptime=""
  always "   (none -- the netwatch did not configure the addresses on this boot)"
fi

say ""
say "   stalls and heals on this boot:"
if grep -qE '^[0-9.]*s (STALL|HEAL)' "$SEC"; then
  grep -E '^[0-9.]*s (STALL|HEAL)' "$SEC" | head -12 | sed 's/^/   | /'
  first_heal=$(grep -E '^[0-9.]*s HEAL [AB]:' "$SEC" | head -1 | sed 's/^\([0-9.]*\)s .*/\1/' | cut -d. -f1)
else
  always "   (none)"
  first_heal=""
fi

# --- 4. who did it, and was the keeper there ----------------------------------------------------

say ""
say "== the keeper (stage 1 expects it to still be running; that is the safety net)"
# MATCHED BY ARGV, NOT BY SUBSTRING (docs 179). This is a READING, and the reading it produces goes into
# the verdict below -- a phantom keeper would be printed as "still running its 1 Hz loop" and would make
# the netwatch look like it had a safety net it does not have (or, in the other direction, hide the
# keeper's absence). The substring form matched any process whose command line merely MENTIONS the name,
# including whatever shell is running this program over ssh. Measured on the phone 2026-09-26: the health
# check's twin of this loop reported the reader's own pid (`keeper pid 3545508` beside `my pid: 3545508`)
# on a boot with no keeper at all.
#
# The rule is the one install-retire-debug-keeper.sh's is_keeper_cmdline() uses: a whole argv element
# EQUALS the path, or argv[0] is a shell and argv[1] is the path (docs 94), with this shell's pid skipped.
k_pids=""
for p in /proc/[0-9]*; do
  [ -d "$p" ] || continue
  [ "${p#/proc/}" = "$$" ] && continue
  set -- $(tr '\0' '\n' < "$p/cmdline" 2>/dev/null)
  a0=${1:-}; a1=${2:-}; hit=0
  case "$a1" in "$KEEPER_PATH") hit=1 ;; esac
  if [ "$hit" = 0 ]; then
    case "$a0" in
    "$KEEPER_PATH") hit=1 ;;
    */sh|*/dash|*/bash|*/busybox|sh|dash|bash|busybox) case "$a1" in "$KEEPER_PATH") hit=1 ;; esac ;;
    esac
  fi
  [ "$hit" = 1 ] && k_pids="$k_pids ${p#/proc/}"
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
  if [ -n "$k_pids" ]; then
    always "   The addresses are present but the netwatch never logged configuring them, and no heal"
    always "   fired -- so the keeper is what configured them (it is still running, which is what"
    always "   stage 1 expects). This boot says nothing about the netwatch path."
    always ""
    always "   AND ON A KEEPER-ALIVE BOOT IT GENERALLY CANNOT SAY ANYTHING. The keeper re-adds both"
    always "   addresses every second (its loop calls configure_iface on rndis0), and ensure_addrs()"
    always "   logs 'ADDRS:' ONLY when something was missing -- so the netwatch gets a line only if"
    always "   one of its 2 s samples lands in the gap between an address going missing and the"
    always "   keeper's next 1 Hz tick. That gap is somewhere between tens of milliseconds and one"
    always "   second, and its length has not been measured. So this verdict is a race outcome, not a"
    always "   failed attempt: re-running the boot until it reads 'netwatch-configured' is re-rolling"
    always "   a coin, and each roll is a device boot."
    always ""
    always "   That race closes the moment the keeper is gone -- which is the case actually being"
    always "   asked about, and the reason it does not bear on the answer. So measure the thing where"
    always "   it is deterministic instead:"
    always "     scripts/device/zl1-address-owner-proof.sh --yes"
    always "   It stops the keeper, takes ONE address away, and requires the netwatch to notice and"
    always "   put it back; then it resumes the keeper, and restores the address itself if the"
    always "   netwatch did not."
  else
    always "   The addresses are present, the netwatch never logged configuring them, and no heal"
    always "   fired -- but the keeper is NOT running either, so something else applied them (a"
    always "   manual 'ip addr add', the container, or a build without a working ensure_addrs())."
    always "   This boot does not show that the netwatch can do it."
    always "     scripts/device/zl1-address-owner-proof.sh --yes      # measures it directly"
  fi
fi

say ""
say "   What this does NOT prove: it does not say the address was applied *early enough* to matter"
say "   (compare ${addrs_uptime:-?}s against how long the host took to reach the device), it does"
say "   not prove the host side resolves the pair (the host has its own static routes -- test with"
say "   a ping from the host), and one boot is one boot: the 2026-09-17 stall work needed a rate,"
say "   not a sample. Retire the keeper on a boot that reads 'netwatch-configured', and keep the"
say "   reinstall command to hand in case the next boot disagrees."

rm -f "$SEC"
case "$verdict" in
netwatch-configured) exit 0 ;;
*) exit 1 ;;
esac
