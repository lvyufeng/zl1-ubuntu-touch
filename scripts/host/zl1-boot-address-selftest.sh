#!/bin/sh
# zl1 boot-address check -- offline self-test. Host-side, touches no device.
#
# Why this exists: `scripts/device/zl1-boot-address-check.sh` returns the verdict that licenses
# retiring the v63 debug keeper (docs 88, docs 94). "netwatch-configured" -> the keeper can be killed
# at boot; "heal-first" -> the boot still needs the old path and nothing should change. That is a
# device decision made from a log, the device is expensive to get back (a keeper-less boot with no
# address means no SSH, and getting SSH back needs a finger on the power button), and the script is
# 240 lines of log parsing that had never been run against anything but /proc and one real log.
#
# So this runs the verdict logic against six synthetic logs BEFORE the boot that matters. It uses the
# script's own --log flag (that is what the flag is for) and rewrites the device paths into a fake
# root, so the real script is the thing under test -- not a copy of its logic.
#
# Usage: zl1-boot-address-selftest.sh [--keep]
#   --keep   leave the fake root and the rewritten script in place for inspection
#
# Exit codes: 0 every scenario behaved; 1 something did not.

set -u

KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
  --keep) KEEP=1; shift ;;
  --help|-h) sed -n '2,20p' "$0"; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

HERE=$(dirname "$0")
SRC="$HERE/../device/zl1-boot-address-check.sh"
[ -r "$SRC" ] || { echo "cannot read $SRC" >&2; exit 2; }

W=${TMPDIR:-/tmp}/zl1-ba-selftest
FR="$W/fake"
rm -rf "$W"
mkdir -p "$FR/proc/device-tree" "$FR/sys/class/net/rndis0" "$FR/etc/systemd/system" \
         "$FR/userdata" "$FR/proc/812" || exit 2

# The device's own shape: this model string is what the script's zl1 guard looks for.
printf 'LE_ZL1\x00'   > "$FR/proc/device-tree/model"
printf '412.55 300.10\n' > "$FR/proc/uptime"

# A netwatch process, so the /proc walk and the process-age arithmetic (field 22 after stripping the
# parenthesised comm -- the doc 81 trap) are exercised too. starttime 10000 ticks = 100 s, so against
# an uptime of 412 the age must read 312 s.
printf '#!/bin/sh\x00/usr/bin/sh\x00/etc/systemd/system/zl1-netwatch.sh\x00' > "$FR/proc/812/cmdline"
printf '812 (sh) S 1 812 812 0 -1 4194560 100 0 0 0 5 3 0 0 20 0 1 0 10000 0 0 0 0 0 0\n' \
  > "$FR/proc/812/stat"
printf '#!/bin/sh\n# the installed build\nensure_addrs() {\n  :\n}\n' \
  > "$FR/etc/systemd/system/zl1-netwatch.sh"

# The script under test, with every device path pointed into the fake root. Nothing else is changed:
# this is a sed rewrite of the real file, so the verdict logic and the exit codes are the real ones.
sed -e "s#/proc/device-tree/model#$FR/proc/device-tree/model#g" \
    -e "s#/proc/uptime#$FR/proc/uptime#g" \
    -e "s#/proc/\[0-9\]\*#$FR/proc/[0-9]*#g" \
    -e "s|\${p#/proc/}|\${p#$FR/proc/}|g" \
    -e "s#\"/proc/\$nw_pid/stat\"#\"$FR/proc/\$nw_pid/stat\"#g" \
    -e "s#\"/proc/\$p/stat\"#\"$FR/proc/\$p/stat\"#g" \
    -e "s#/sys/class/net/\$i#$FR/sys/class/net/\$i#g" \
    -e "s#/etc/systemd/system/zl1-netwatch.sh#$FR/etc/systemd/system/zl1-netwatch.sh#g" \
    -e "s#^NETLOG=/userdata/zl1-netwatch.log#NETLOG=$FR/userdata/zl1-netwatch.log#" \
    "$SRC" > "$W/check.sh" || exit 2
sh -n "$W/check.sh" || { echo "the rewritten copy does not parse -- fix that first" >&2; exit 2; }

# --- the netwatch logs, one per scenario ---------------------------------------------------------
#
# Every line of a real netwatch log begins with the uptime it was written at (log() in
# scripts/device/zl1-netwatch.sh), and `netwatch start` is the boot boundary. The uptime RESETS each
# boot, which is why C and D below exist: the newest section must be judged alone.

cat > "$FR/userdata/A.log" <<'EOF'
1.10s netwatch start pid=812 heal=1 stall=45s max_heals=8 recovery_after=600s
2.10s sample rx=1 tx=1 frozen=0
4.30s policy routing fix in place: 10.15.19.0/24 dev rndis0
9.40s ADDRS: uptime=9 iface=rndis0 now='192.168.2.15/24 10.15.19.82/24'
11.40s sample rx=9 tx=9 frozen=0
EOF

cat > "$FR/userdata/B.log" <<'EOF'
1.10s netwatch start pid=812 heal=1 stall=45s max_heals=8
5.00s sample rx=3 tx=3 frozen=0
50.00s STALL: host unreachable for 45s; iface=rndis0 tx_pkts=12 rx_pkts=90
51.00s HEAL A: enable=0/1 on the gadget
52.00s HEAL A: done; state=configured functions=rndis enable=1 iface=rndis0
76.00s HEAL: host reachable again after 45s unreachable
150.00s ADDRS: uptime=150 iface=rndis0 now='192.168.2.15/24 10.15.19.82/24'
EOF

cat > "$FR/userdata/C.log" <<'EOF'
1.10s netwatch start pid=700 heal=1 stall=45s
9.40s ADDRS: uptime=9 iface=rndis0 now='192.168.2.15/24 10.15.19.82/24'
3000.00s sample rx=99 tx=99 frozen=0
1.10s netwatch start pid=812 heal=1 stall=45s
5.00s sample rx=1 tx=1 frozen=0
10.00s policy routing fix in place: 10.15.19.0/24 dev rndis0
EOF

cat > "$FR/userdata/D.log" <<'EOF'
1.10s netwatch start pid=700 heal=1 stall=45s
50.00s STALL: host unreachable for 45s
51.00s HEAL A: enable=0/1 on the gadget
3000.00s sample rx=99 tx=99 frozen=0
1.10s netwatch start pid=812 heal=1 stall=45s
9.40s ADDRS: uptime=9 iface=rndis0 now='192.168.2.15/24 10.15.19.82/24'
11.00s sample rx=9 tx=9 frozen=0
EOF

cat > "$FR/userdata/E.log" <<'EOF'
1.10s netwatch start pid=812 heal=1 stall=45s
50.00s STALL: host unreachable for 45s
51.00s HEAL B: unbind/rebind the rndis function
90.00s HEAL: host reachable again after 45s unreachable
EOF

# --- the checks ----------------------------------------------------------------------------------

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }

verdict_of() { # $1 log file -> prints the verdict name
  out=$(sh "$W/check.sh" --log "$FR/userdata/$1" 2>/dev/null); rc=$?
  case "$out" in
  *"The netwatch applied the addresses"*) v=netwatch-configured ;;
  *"but a heal fired first"*)             v=heal-first ;;
  *"No ADDRS line, but a heal fired"*)    v=heal-first ;;
  *"netwatch never logged configuring"*)  v=inconclusive ;;
  *)                                      v="?" ;;
  esac
}

expect() { # $1 log, $2 wanted verdict, $3 wanted rc, $4 description
  verdict_of "$1"
  if [ "$v" = "$2" ] && [ "$rc" = "$3" ]; then
    ok "$4 -> $v (exit $rc)"
  else
    bad "$4 -> got $v (exit $rc), wanted $2 (exit $3)"
    printf '%s\n' "$out" | sed -n '/== verdict/,+3p' | sed 's/^/        /'
  fi
}

echo "zl1 boot-address check -- offline self-test"
echo "  script under test: $SRC"
echo "  fake root:         $FR"
echo

echo "== verdict logic =="
expect A.log netwatch-configured 0 "A: the netwatch configured it, no heal"
expect B.log heal-first 1 "B: the addresses arrived only after a heal"
expect C.log inconclusive 1 "C: the newest boot says nothing (an older one did)"
expect D.log netwatch-configured 0 "D: the newest boot is clean (an older one healed)"
expect E.log heal-first 1 "E: a heal and no addresses at all"

echo
echo "== the netwatch's own state line =="
out=$(sh "$W/check.sh" --log "$FR/userdata/D.log" 2>/dev/null)
case "$out" in
*"running, pid 812 (started 312 s ago)"*) ok "the process age comes from field 22 after stripping comm" ;;
*) bad "no 'started 312 s ago' (uptime 412, starttime 10000 ticks)"; printf '%s\n' "$out" | grep running | sed 's/^/        /' ;;
esac
n=$(printf '%s\n' "$out" | grep -c 'not a unit here\|^inactive$')
[ "$n" -le 1 ] && ok "the unit state prints once (not twice when systemctl prints and fails)" \
              || bad "the unit state printed $n times"

echo
echo "== the stale-install branch (an installed build without ensure_addrs) =="
printf '#!/bin/sh\n# an older installed build\nrestore_addrs() {\n  :\n}\n' > "$FR/etc/systemd/system/zl1-netwatch.sh"
out=$(sh "$W/check.sh" --log "$FR/userdata/D.log" 2>/dev/null)
case "$out" in
*"INSTALLED build has no ensure_addrs"*) ok "it says so and points at the reinstall" ;;
*) bad "the stale-build branch did not fire" ;;
esac

echo
echo "== a flag with no value must not abort the shell =="
msg=$(sh "$W/check.sh" --log 2>&1 >/dev/null | head -1)
case "$msg" in
*"--log needs a FILE argument"*) ok "'--log' with no value -> a message and a clean exit" ;;
*) bad "'--log' with no value -> [$msg]" ;;
esac
# an explicit empty value is let through (the guard is ${2?...}, not ${2:?...}), exactly as before the
# guard existed: the script then reports the log as unreadable. What must never happen is a shell error.
out=$(sh "$W/check.sh" --log "" 2>&1)
case "$out" in
*"parameter not set"*|*"unbound variable"*) bad "'--log \"\"' aborted the shell: $out" ;;
*) ok "'--log \"\"' is handled without a shell error (it reports the log unreadable)" ;;
esac

echo
echo "pass=$PASS fail=$FAIL"
[ "$KEEP" = 1 ] || rm -rf "$W"
[ "$FAIL" = 0 ]
