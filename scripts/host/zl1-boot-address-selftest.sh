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
# It also runs the log scan against a LARGE log under an `awk` that is not gawk, because the shape of
# the device's `awk` is what broke it (docs 108): the accumulator that cost one core for 11 minutes on
# the device runs in 0.4 s on the workstation that wrote it.
#
# Usage: zl1-boot-address-selftest.sh [--keep]
#   --keep   leave the fake root and the rewritten script in place for inspection
#
# Exit codes: 0 every scenario behaved; 1 something did not; 2 the harness itself could not run.

set -u

KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
  --keep) KEEP=1; shift ;;
  --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; exit 0 ;;
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
SKIP=0
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }

verdict_of() { # $1 log file -> prints the verdict name
  out=$(timeout 60 sh "$W/check.sh" --log "$FR/userdata/$1" 2>/dev/null); rc=$?   # rc 124 = it hung
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

echo "== the two shapes of 'inconclusive' =="
# Both are the same verdict and they are NOT the same situation, so they must not read the same.
# C above ran with no keeper in the fake /proc, i.e. the addresses came from somewhere this script
# cannot see. That must not be reported as "the keeper did it".
out=$(sh "$W/check.sh" --log "$FR/userdata/C.log" 2>/dev/null)
case "$out" in
*"the keeper is NOT running either"*) ok "C: with no keeper, it does not claim the keeper configured them" ;;
*) bad "C: an inconclusive reading with no keeper present still blames the keeper" ;;
esac

# I is the case that actually happens on a device in stage 1: the keeper IS running, so it won every
# race and the netwatch had nothing to do. The verdict stays inconclusive -- and the output has to say
# that this is the expected outcome rather than a failed attempt, because the thing it licensed was a
# device boot, and "re-run the boot" without that sentence is a re-roll of a sub-second race.
printf '1.10s netwatch start pid=812 heal=1 stall=45s\n5.00s sample rx=1 tx=1 frozen=0\n' \
  > "$FR/userdata/I.log"
mkdir -p "$FR/proc/813"
printf '#!/bin/sh\x00/usr/bin/sh\x00/usr/local/sbin/zl1-debug-net.sh\x00' > "$FR/proc/813/cmdline"
printf '813 (sh) S 1 813 813 0 -1 4194560 100 0 0 0 5 3 0 0 20 0 1 0 10000 0 0 0 0 0 0\n' \
  > "$FR/proc/813/stat"
out=$(sh "$W/check.sh" --log "$FR/userdata/I.log" 2>/dev/null); rc=$?
case "$out" in
*"netwatch never logged configuring"*) ok "I: keeper alive and nothing missing -> inconclusive (exit $rc)" ;;
*) bad "I: the keeper-alive inconclusive branch did not fire (exit $rc)" ;;
esac
[ "$rc" = 1 ] || bad "I: exit was $rc, wanted 1 (inconclusive must not license the retirement)"
case "$out" in
*"re-rolling"*) ok "I: it says re-running the boot is a re-roll, not a retry" ;;
*) bad "I: re-running the boot is still presented as the way to get a verdict" ;;
esac
case "$out" in
*"zl1-address-owner-proof.sh"*) ok "I: it names the deterministic measurement instead" ;;
*) bad "I: no route to a verdict other than another boot" ;;
esac
case "$out" in
*"the keeper is NOT running either"*) bad "I: with the keeper present it used the no-keeper wording" ;;
*) ok "I: the keeper-alive wording is the one it printed" ;;
esac
rm -rf "$FR/proc/813"

echo
echo "== a log with no boot boundary at all =="
# The header line the reader writes now exists even when the section holds nothing, so "no start
# line" and "a start line with nothing interesting under it" have to be told apart by the COUNT,
# not by the section file being empty. These two logs are that pair.
printf '3.00s sample rx=1 tx=1 frozen=0\n9.00s sample rx=2 tx=2 frozen=0\n' > "$FR/userdata/F.log"
out=$(sh "$W/check.sh" --log "$FR/userdata/F.log" 2>/dev/null); rc=$?
case "$out" in
*"has never run on this device"*) ok "F: no boundary anywhere -> 'has never run' (exit $rc)" ;;
*) bad "F: a log with no 'netwatch start' line was not reported as never-run" ;;
esac
[ "$rc" = 1 ] || bad "F: exit was $rc, wanted 1"

# G is the same log PLUS a boundary and nothing else: the section is empty of ADDRS/STALL/HEAL, and
# that must NOT read as "never run". This is the branch the streaming reader could have broken.
printf '1.10s netwatch start pid=812 heal=1 stall=45s\n3.00s sample rx=1 tx=1 frozen=0\n' \
  > "$FR/userdata/G.log"
out=$(sh "$W/check.sh" --log "$FR/userdata/G.log" 2>/dev/null)
case "$out" in
*"boots in this log: 1"*) ok "G: a boundary with nothing under it is still a boot" ;;
*) bad "G: 'boots in this log: 1' missing for a boundary-only section" ;;
esac
case "$out" in
*"has never run on this device"*) bad "G: an empty-but-present section was read as never-run" ;;
*) ok "G: it is not confused with a log that has no boundary" ;;
esac

echo
echo "== the cap =="
{
  echo '1.10s netwatch start pid=812 heal=1 stall=45s'
  i=0; while [ "$i" -lt 2500 ]; do echo "60.00s STALL: host unreachable for 45s"; i=$((i + 1)); done
} > "$FR/userdata/H.log"
out=$(sh "$W/check.sh" --log "$FR/userdata/H.log" 2>/dev/null)
case "$out" in
*"only the first 2000 ADDRS/STALL/HEAL lines were kept"*) ok "H: it says the section was cut at the cap" ;;
*) bad "H: 2500 interesting lines produced no cap advisory" ;;
esac

echo
echo "== the scan on a log the size of the real one, under the device's kind of awk =="
#
# The defect docs 108 records is not a wrong verdict, it is a scan that never finishes -- and it is
# invisible under the host's `awk`, whose `s = s x` append is done in place. Measured on a 2.2 MB
# single section: gawk ~0.0 s, mawk 43 s, busybox awk > 100 s at a larger size. So the test is run
# twice: once with the real script, and once with the OLD accumulator put back, and the second one
# is REQUIRED to time out. A harness that passes both would be testing nothing.
DEV_AWK=""
for a in mawk busybox; do
  if command -v "$a" >/dev/null 2>&1; then
    case "$a" in
    mawk) DEV_AWK="mawk" ;;
    busybox) busybox awk 'BEGIN{}' >/dev/null 2>&1 && DEV_AWK="busybox awk" ;;
    esac
    [ -n "$DEV_AWK" ] && break
  fi
done

if [ -z "$DEV_AWK" ]; then
  # Count the skip loud rather than quietly passing: without a non-gawk awk this section cannot fail,
  # and a section that cannot fail is not evidence (the lesson in docs 107 section 6).
  printf 'SKIP  no mawk and no busybox awk on this host: the quadratic scan cannot be reproduced here\n'
  SKIP=$((SKIP + 1))
else
  # One ~1.6 KB block per sample, exactly the shape the netwatch writes (scripts/device/zl1-netwatch.sh
  # sample()), and ONE boundary at the top -- so the newest section is the whole file, which is the
  # input that did the damage.
  BLOCK="$W/block.txt"
  cat > "$BLOCK" <<'EOF'
===== uptime X.00 12345.00 =====
--- iface ---
rx_bytes=123456 rx_packets=1000 tx_bytes=654321 tx_packets=900
--- gadget ---
state=CONFIGURED functions=rndis enable=1 iface=usb0
--- ip -s -s ---
    RX: bytes  packets  errors  dropped
    TX: bytes  packets  errors  dropped
--- addr ---
usb0  UP  192.168.2.100/24 10.15.19.100/24
--- route ---
default via 192.168.2.1 dev usb0
--- arp ---
IP address  HW type  Flags  HW address  Mask  Device
192.168.2.1  0x1  0x2  aa:bb:cc:dd:ee:ff  *  usb0
--- counters ---
tx_dropped=0 tx_errors=0 tx_aborted_errors=0 rx_dropped=0 rx_errors=0
--- container progress ---
lxc-start=RUNNING ueventd=RUNNING hwservicemanager=RUNNING servicemanager=RUNNING
vndservicemanager=RUNNING zygote=RUNNING netd=RUNNING
fwmarkd socket: present
EOF
  # 3000 blocks in one process, bounded memory: the block file is 2 KB.
  awk -v n=3000 '{ l[NR] = $0 } END { for (i = 0; i < n; i++) for (j = 1; j <= NR; j++) print l[j] }' \
      "$BLOCK" > "$W/big.body"
  { echo '1.10s netwatch start pid=812 heal=1 stall=45s'; cat "$W/big.body"; } > "$FR/userdata/BIG.log"
  bytes=$(wc -c < "$FR/userdata/BIG.log")

  # A PATH that resolves `awk` to the device's kind of awk, for the check script only.
  mkdir -p "$W/bin"
  case "$DEV_AWK" in
  mawk)   printf '#!/bin/sh\nexec mawk "$@"\n' > "$W/bin/awk" ;;
  *)      printf '#!/bin/sh\nexec busybox awk "$@"\n' > "$W/bin/awk" ;;
  esac
  chmod +x "$W/bin/awk"

  echo "  section: $bytes bytes, one boundary ($DEV_AWK as awk)"

  s=$(date +%s)
  out=$(PATH="$W/bin:$PATH" timeout 15 sh "$W/check.sh" --log "$FR/userdata/BIG.log" 2>/dev/null); rc=$?
  el=$(( $(date +%s) - s ))
  if [ "$rc" = 124 ]; then
    bad "BIG: the real script did NOT finish a $bytes-byte section in 15 s under $DEV_AWK (this is the docs 108 hang)"
  else
    case "$out" in
    *"boots in this log: 1"*)
      ok "BIG: a $bytes-byte section scanned under $DEV_AWK in ${el}s, verdict inconclusive (exit $rc)" ;;
    *) bad "BIG: the scan finished (${el}s, exit $rc) but did not report the boot" ;;
    esac
  fi

  # The mutation. Rather than rewrite the awk inside check.sh (three lines of quoting that would
  # rot), this runs the OLD body itself against the same log under the same awk, and the durable
  # regression assertion is that the body is GONE from the script. Both halves are needed: this one
  # says the log size is in the danger zone on this host, that one says the script is not in it.
  OLD_AWK='  / netwatch start / { n++; buf=""; next }
  { if (n > 0) buf = buf $0 "\n" }
  END { printf "%s", buf }'
  s=$(date +%s)
  PATH="$W/bin:$PATH" timeout 15 awk "$OLD_AWK" "$FR/userdata/BIG.log" >/dev/null 2>&1; rc=$?
  el=$(( $(date +%s) - s ))
  if [ "$rc" = 124 ]; then
    ok "BIG: the OLD accumulator is still over 15 s on this log under $DEV_AWK (${el}s) -- the size is decisive"
  else
    bad "BIG: the OLD accumulator finished in ${el}s (exit $rc): this log is too small to tell the two apart, so the line above proves nothing"
  fi

  if grep -v '^[[:space:]]*#' "$SRC" | grep -q 'buf = buf'; then
    bad "the accumulator ('buf = buf') is BACK in $SRC as code -- that is the docs 108 hang"
  else
    ok "the accumulator is gone from the script under test (the header may still name it)"
  fi
  grep -q 'kept <= cap' "$SRC" \
    && ok "the reader bounds what it keeps (the cap is in the script)" \
    || bad "the reader has no cap: nothing bounds the section it keeps"
fi

echo
echo "== the health check cites this harness's count, and that citation cannot drift =="
# scripts/host/zl1-health-check.sh tells the next reader how many checks this harness has, hand-typed.
# It went stale once already (docs 110) -- the GPS line said 99 while that harness had grown to 129 --
# and nothing noticed, because a stale number in a comment fails nothing. So the number is checked
# from here, against this run's own total.
HEALTH="$HERE/zl1-health-check.sh"
if [ -z "$DEV_AWK" ]; then
  # The BIG section is the one conditional block in this file (4 checks, or 1 SKIP on a host with no
  # non-gawk awk), so this total is host-dependent and the cited number is not the one this run would
  # produce. Count that SKIP out loud rather than comparing against a number that is right anyway.
  printf 'SKIP  no non-gawk awk here, so the BIG section was skipped and the total is host-dependent: the citation is not checked on this host\n'
  SKIP=$((SKIP + 1))
elif [ ! -r "$HEALTH" ]; then
  printf 'SKIP  %s is not readable, so there is no citation to check\n' "$HEALTH"
  SKIP=$((SKIP + 1))
else
  cited=$(sed -e 's/always "/ /g' -e 's/"$//' "$HEALTH" | tr '\n' ' ' |
            sed -n 's/.*zl1-boot-address-selftest\.sh[ ,(]*\([0-9][0-9]*\) checks.*/\1/p')
  total=$((PASS + FAIL + 1))
  if [ -n "$cited" ] && [ "$cited" = "$total" ]; then
    ok "the health check cites $cited checks, and this run has $total (the citation is live)"
  else
    bad "the health check cites '${cited:-nothing}' checks for this harness; this run has $total"
  fi
fi

echo
echo "pass=$PASS fail=$FAIL${SKIP:+ skip=$SKIP}"
[ "$KEEP" = 1 ] || rm -rf "$W"
[ "$FAIL" = 0 ]
