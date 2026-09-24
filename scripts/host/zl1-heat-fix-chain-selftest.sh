#!/bin/sh
# zl1 heat-fix chain -- offline self-test.
#
# Host-side, touches no device. The subject is `scripts/host/zl1-heat-fix-chain.sh`, whose entire job is
# ORDER plus ONE refusal: five steps on one boot, where two of them are licensed only by the step before
# (the address-ownership proof licenses the kill; the kill is the ~1 core of the heat fix). Everything
# it calls already has its own harness -- this one holds it to the things that exist only here:
#
#   1. IT RUNS NOTHING WITHOUT --yes, and nothing at all when the device is unreachable. The second half
#      is asserted the same way the capture script's harness does it: by the VERDICT and by the fact
#      that no ssh/scp was made.
#   2. THE ORDER, INCLUDING THE WAIT. The 90 s settle is not decoration: the activated build may
#      re-enumerate the USB gadget, which drops the ssh session the rest of the chain runs over, so a
#      chain that skips the wait fails in the middle of the proof and looks like the proof's fault.
#   3. THE LICENCE IS A WHOLE LINE, NOT A WORD. Step 5 may only run when step 4 printed exactly
#      `== verdict: proof-obtained`. A verdict line that merely CONTAINS those words must not license a
#      kill (docs 114: the substring gate was the defect), and every other verdict -- including a
#      timeout and an empty output -- has to leave the keeper in place and say the phone is still
#      reachable.
#   4. IT STOPS, AND SAYS WHERE. A failing step must end the chain (unlike the capture script, whose
#      steps are independent readings) and leave an archive that names the step, its rc, and what the
#      device looks like at that moment.
#
# The transport is stubbed as in the sibling harnesses -- the `ssh`/`scp` stub *is* the device -- and the
# four callees are recording stand-ins. What the chain's own read-only status block reads on the device
# is NOT re-tested here (it is `ip`, `systemctl` and `/proc` on the fake device); what is under test is
# that the chain sends it, and what it does with the proof's answer.
#
# Usage: zl1-heat-fix-chain-selftest.sh [--keep]
#   --keep   leave the fake root, the stubs, the rewritten script and the mutants in place
#
# Exit codes: 0 every scenario behaved; 1 something did not; 2 the harness could not set up.

set -u

KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
  --keep) KEEP=1; shift ;;
  --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0" ; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

HERE=$(dirname "$0")
SRC="$HERE/zl1-heat-fix-chain.sh"
[ -r "$SRC" ] || { echo "cannot read $SRC" >&2; exit 2; }
REPO=$(cd "$HERE/../.." && pwd)

W=${TMPDIR:-/tmp}/zl1-heat-fix-chain-selftest
FR="$W/fake"          # the fake DEVICE
CAL="$W/callees"      # recording stand-ins for the four scripts this one drives
STUB="$W/stub"
ACT="$W/actions"
rm -rf "$W"
mkdir -p "$FR/sys/bus/usb/devices/3-3" "$FR/tmp" "$STUB" "$CAL/host" "$W/out" "$W/misc" \
         "$W/fake-repo/scripts/host" || exit 2
# The copy under test lives in a fake repo whose scripts/device holds a PER-FILE symlink to every real
# device script -- not a copy, and NOT a symlink to the whole directory.
#
# Why the proof is a symlink to the real file: the chain resolves it as $HERE/../device/<name>, so a
# copy in /tmp would refuse for a reason that has nothing to do with the chain, and replacing it with a
# stand-in would make "it pushed the REAL proof" (checked below) a statement about a fixture.
#
# Why the directory itself must NOT be a symlink -- this is a defect this harness had, found 2026-09-24
# by `git diff`: a directory symlink cannot tell "the file the chain really pushes" from "the file this
# harness owns a stand-in for". The A/B instrument is scp-ed from the same directory, and the line that
# plants its stand-in ran `mkdir -p` through that symlink (succeeds, silently) and then `>` . . .
# which wrote INTO THE REPOSITORY. `scripts/device/zl1-thermal.sh` was replaced by the one-line stub --
# 409 lines of the only heat instrument this project has, destroyed by its own offline test, with the
# harness's comment two lines above it still claiming the opposite. Per-file symlinks make the two
# cases distinguishable: the stub is a file this harness created, in its own tree.
# ABSOLUTE targets, because a relative symlink target resolves against the LINK's directory, not the
# harness's cwd -- which is how the first version pointed at $W/fake-repo/scripts/../device.
DEV_FAKE="$W/fake-repo/scripts/device"
mkdir -p "$DEV_FAKE" || exit 2
REAL_DEV=$(cd "$HERE/../device" && pwd)
REAL_THERMAL="$REAL_DEV/zl1-thermal.sh"
for f in "$REAL_DEV"/*; do
  b=$(basename "$f")
  [ "$b" = zl1-thermal.sh ] && continue   # its stand-in is written below, by this harness
  ln -s "$f" "$DEV_FAKE/$b"
done

# Every file this harness writes under its own fake repo goes through this, and it is a REFUSAL rather
# than a convention: `> path` through a symlink silently edits whatever it points at, and the only
# reason that is not happening above is that the loop skipped the one name -- a guard that would have
# to be re-read on every edit. This one cannot be forgotten: it is on the write.
wrote() { # path, content on stdin
  if [ -L "$1" ]; then
    echo "REFUSING to write through the symlink $1 -- this harness would be editing the tree it tests" >&2
    exit 2
  fi
  cat > "$1"
}

# The one thing this harness must not do to the repository, measured rather than intended: the real
# instrument is read once here and re-read at the end (section 9). The defect above passed every check
# in this file while destroying a 409-line script, so "no check could see it" is the point.
[ -r "$REAL_THERMAL" ] || { echo "cannot read $REAL_THERMAL" >&2; exit 2; }
REAL_THERMAL_BEFORE=$(sha256sum "$REAL_THERMAL" | awk '{print $1}')

# --- the fake device ------------------------------------------------------------------------------
# The serial directory IS the check (a real directory with a `serial` file), and the match is a PREFIX:
# the gadget reports `33e80afe-v63-usbd-disabled-rndis`. The fixture uses the FULL gadget id, so an
# equality test in the script -- which was a real bug once (docs 108) -- would read "absent" here.
printf '%s\n' '33e80afe-v63-usbd-disabled-rndis' > "$FR/sys/bus/usb/devices/3-3/serial"
serial_on()  { mkdir -p "$FR/sys/bus/usb/devices/3-3"; printf '%s\n' "${FP_SERIAL:-33e80afe-v63-usbd-disabled-rndis}" > "$FR/sys/bus/usb/devices/3-3/serial"; }
serial_off() { rm -rf "$FR/sys/bus/usb/devices"; }

# The read-back block the chain sends at the end of a run (and after a failure). One fixture, because
# the chain's use of it is the same in both places: it must APPEAR, and it must be archived.
cat > "$W/state.txt" <<'EOF'
netwatch: file=present fn=has-ensure_addrs unit=active
keeper: gone
addrs: 192.168.2.15=1 10.15.19.100=1
governors: interactive interactive interactive interactive
EOF

# The proof's output. It is a fixture FILE rather than a string the stub prints, because the thing under
# test is which verdict line the chain accepts -- and the cases differ only in that line.
proof_unclear() { printf '== the addresses, before and after\n   took 192.168.2.15 off rndis0\n== verdict: %s\n' "${1:-proof-unclear}" > "$W/proof.txt"; }
proof_obtained() { printf '== taking the address away\n== the netwatch noticed and logged a new line\n== verdict: proof-obtained\n' > "$W/proof.txt"; }
proof_obtained

# --- the stubs ------------------------------------------------------------------------------------
# lsusb: the answer to "is anything there", and it is a FILTER (`-d ID` exits non-zero when nothing
# matches), which is exactly the script's first question. A stub that always exited 0 would report EDL
# for a healthy device -- the fixture defect the capture harness records.
cat > "$STUB/lsusb" <<EOF
#!/bin/sh
printf 'lsusb %s\n' "\$*" >> "$ACT"
want_id=
[ "\$1" = -d ] && want_id="\$2"
case "\${FP_STATE:-present}" in
edl) have_id=05c6:9008 ;;
*)   have_id=18d1:d001 ;;
esac
if [ -n "\$want_id" ]; then
  [ "\$want_id" = "\$have_id" ] || exit 1
fi
printf 'Bus 003 Device 042: ID %s device\n' "\$have_id"
exit 0
EOF

# The A/B instrument. The chain scp's the script it finds at $HERE/../device/zl1-thermal.sh and runs it
# over ssh; the ssh stub answers it from the fixture below, which was captured by running the instrument
# ITSELF (on this host: --ab --hold 3), so the SHAPE the chain parses is the shape the instrument really
# prints rather than the shape that was assumed.
#
# The stand-in is a REGULAR FILE IN THIS HARNESS'S TREE, and the write goes through `wrote()` so it
# cannot become a write into the repository -- see the note at DEV_FAKE. What the chain must find there
# is a file that exists and can be pushed; the instrument's BEHAVIOUR is the ssh stub's job, because
# nothing in this harness can run a device script.
AB_FIX="$W/ab.txt"
wrote "$DEV_FAKE/zl1-thermal.sh" <<'EOF'
# the real instrument is scp-ed; this only has to exist and be readable
EOF
cat > "$AB_FIX" <<'ABEOF'
== window A done. Change ONE thing now; window B starts in 120s :: Thu Feb 11 18:00:00 EST 1970
== window B (after the change):
  busy 0.87 of 4 cores (22%), of which iowait 0.00 cores
== B minus A per process (ticks in the same 30s window; + = hotter, sorted by size):
      -182 v63-debug-init 817
        +4  lomiri 4211
   (processes in either top-10 list)
== B minus A per thermal zone (sorted by the size of the change, either direction):
   tsens_tz_sensor8 tsens_tz_sensor8          -5.5 C   (58.0 -> 52.5)
   tsens_tz_sensor1 tsens_tz_sensor1          -6.1 C   (55.8 -> 49.7)
   battery          battery                   -2.7 C   (42.5 -> 39.8)
ABEOF

cat > "$STUB/sleep" <<EOF
#!/bin/sh
printf 'sleep %s\n' "\$*" >> "$ACT"
# FP_REAL_SLEEP makes the wait real, which is how the interrupt (exit 3 + archive) is tested: an
# instant sleep would leave nothing to interrupt.
[ -n "\${FP_REAL_SLEEP:-}" ] && exec /bin/sleep "\$*"
exit 0
EOF

# ssh: records the command on ONE line (these remote programs are multi-line, and every assertion here
# greps for them), answers the reachability probe, and answers the two kinds of remote program the chain
# sends. The proof is answered from the fixture and its exit code from FP_RC_PROOF, which is how "the
# proof ran but its verdict is not the licence" is a scenario rather than a reading.
cat > "$STUB/ssh" <<EOF
#!/bin/sh
printf 'ssh %s\n' "\$(printf '%s' "\$*" | tr '\n' ' ')" >> "$ACT"
while [ \$# -gt 0 ]; do
  case "\$1" in *@*) shift; break ;; *) shift ;; esac
done
case "\$*" in
true) [ "\${FP_SSH:-yes}" = yes ] && exit 0 || exit 1 ;;
*random/boot_id*) printf 'deadbeef-1111-2222-3333-444444444444\n'; exit 0 ;;
*netwatch*) sl="\${FP_SLEEP_STATE:-}"; [ -n "\$sl" ] && [ "\$sl" != 0 ] && sleep "\$sl" >/dev/null 2>&1; cat "$W/state.txt"; exit 0 ;;
*zl1-address-owner-proof.sh*) cat "$W/proof.txt"; exit "\${FP_RC_PROOF:-0}" ;;
*zl1-thermal.sh*) sl="\${FP_SLEEP_AB:-}"; [ -n "\$sl" ] && [ "\$sl" != 0 ] && sleep "\$sl" >/dev/null 2>&1; cat "$AB_FIX"; exit "\${FP_RC_AB:-0}" ;;
esac
exit 0
EOF

# scp: pushes into the fake device's /tmp and records the SOURCE path, so "it pushed the proof and not
# something else" is checkable. `-o NAME=VALUE` is two argv entries and the VALUE has to be skipped with
# the name -- the capture harness's record of getting that wrong.
cat > "$STUB/scp" <<EOF
#!/bin/sh
printf 'scp %s\n' "\$*" >> "$ACT"
args=""; skip=0
for a in "\$@"; do
  if [ "\$skip" = 1 ]; then skip=0; continue; fi
  case "\$a" in -o) skip=1; continue ;; -*) continue ;; esac
  args="\$args \$a"
done
set -- \$args
cp "\$1" "$FR/tmp/\$(basename "\$2")" || exit 1
exit "\${FP_RC_SCP:-0}"
EOF
chmod +x "$STUB"/*

# --- the callees ----------------------------------------------------------------------------------
# One stand-in per script the chain drives. It records its invocation in $ACT (so the ORDER is
# assertable without parsing the archive) and prints a line that lands in the archive. FP_RC_<NAME>
# chooses the exit code, which is how "a failing step stops the chain" is tested.
# The second argument is a TAG, and it is not decoration: `${FP_RC_$1:-0}` looks like it would work and
# does not -- with $1 = `install-netwatch-service` the `-` inside the expanded name is parsed as the `:-`
# operator, so the stub exited with the literal string `netwatch-service:-0` ("Illegal number") and every
# step failed. A tag with no dash in it is the fix, and the same shape is why the sibling harnesses pass
# a marker name rather than deriving one.
callee() { # path-name, TAG
  cat > "$CAL/host/$1.sh" <<EOF
#!/bin/sh
printf 'CALLEE $1 args=%s\n' "\$*" | tee -a "$ACT"
rc=\$(printf '%s' "\${FP_RC_$2:-0}")
[ -n "\$rc" ] || rc=0
# A hook so a step can be made to take real time: the alignment check is about whether the WORK outlasts
# the HOLD, and an instant stand-in cannot make that happen.
sl=\$(printf '%s' "\${FP_SLEEP_$2:-0}"); [ -n "\$sl" ] && [ "\$sl" != 0 ] && sleep "\$sl"
echo "CALLEE $1: done rc=\$rc"
printf 'CALLEE $1 rc=%s\n' "\$rc" >> "$ACT"
exit "\$rc"
EOF
  chmod +x "$CAL/host/$1.sh"
}
callee install-netwatch-service NW
callee install-retire-debug-keeper RETIRE
callee install-cpufreq-governor CPUFREQ

# The proof runs ON the device, so its stand-in is the ssh stub's answer above; what has to exist is the
# FILE that gets pushed. The chain pushes the real one, so the real one has to be readable -- and it is
# cross-checked below against the repository rather than replaced by a stub, because "it pushed a script
# that exists" is part of the point.
PROOF_REAL="$HERE/../device/zl1-address-owner-proof.sh"
[ -r "$PROOF_REAL" ] || { echo "cannot read $PROOF_REAL" >&2; exit 2; }

# --- the script under test ------------------------------------------------------------------------
# Rewritten so the four callee paths resolve to the stand-ins, and so the boot-bus lookup reads the fake
# device. Only those are touched: the argument handling, the refusal order, the verdict comparison, the
# archive and the trap are the real code.
CHAIN="$W/fake-repo/scripts/host/zl1-heat-fix-chain.sh"
sed -e "s#\"\$HERE/../install-netwatch-service.sh\"#\"$CAL/host/install-netwatch-service.sh\"#g" \
    -e "s#\"\$HERE/../install-retire-debug-keeper.sh\"#\"$CAL/host/install-retire-debug-keeper.sh\"#g" \
    -e "s#\"\$HERE/../install-cpufreq-governor.sh\"#\"$CAL/host/install-cpufreq-governor.sh\"#g" \
    -e "s#/sys/bus/usb/devices/#$FR/sys/bus/usb/devices/#g" \
    "$SRC" > "$CHAIN"
chmod +x "$CHAIN"
bash -n "$CHAIN" || { echo "the rewritten script does not parse" >&2; exit 2; }

for pat in "$CAL/host/install-netwatch-service.sh" "$CAL/host/install-retire-debug-keeper.sh" \
           "$CAL/host/install-cpufreq-governor.sh" "$FR/sys/bus/usb/devices/"; do
  grep -qF "$pat" "$CHAIN" || { echo "the rewrite to '$pat' did not land" >&2; exit 2; }
done
# And the callee names are cross-checked against the real tree: a misspelt name would otherwise look
# exactly like a script that ran and said nothing.
for f in install-netwatch-service.sh install-retire-debug-keeper.sh install-cpufreq-governor.sh; do
  [ -r "$HERE/../$f" ] || { echo "the chain names $f, which does not exist in the tree" >&2; exit 2; }
done

# The misc backup: the real one, plus two broken ones for the preflight scenarios. The chain's rule is a
# COPY of the installer's (non-empty, a SHA256SUMS beside it, and it verifies), so all three arms are
# exercised -- the second one is the case the old `[ -f ]` gate could not see.
MISC="$W/misc"
( cd "$MISC" && head -c 4096 /dev/zero > misc.img && sha256sum misc.img > SHA256SUMS )
mkdir -p "$W/misc-truncated" && : > "$W/misc-truncated/misc.img"
cp -a "$MISC" "$W/misc-badsum" && printf 'not-the-hash  misc.img\n' > "$W/misc-badsum/SHA256SUMS"

# --- the checks -----------------------------------------------------------------------------------
PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
want()    { if printf '%s\n' "$2" | grep -Eq "$1"; then ok "$3"; else bad "$3"; printf '%s\n' "$2" | sed 's/^/        | /'; fi; }
notwant() { if printf '%s\n' "$2" | grep -Eq "$1"; then bad "$3"; printf '%s\n' "$2" | grep -E "$1" | sed 's/^/        | /'; else ok "$3"; fi; }
callees() { grep -E '^CALLEE ' "$ACT" 2>/dev/null; }
sshs()    { grep -E '^ssh ' "$ACT" 2>/dev/null; }
order()   { callees | sed -n 's/^CALLEE \([a-z-]*\) args=.*/\1/p' | tr '\n' ' '; }
slept()   { grep -E '^sleep ' "$ACT" 2>/dev/null | awk '{print $2}'; }

# $1 = the outdir to use, rest = args. FP_* choose the device state. Each scenario gets its OWN archive
# directory: sharing one would let a previous scenario's INDEX satisfy the next one's assertion, which is
# the same "leftover state" defect the sibling harnesses record.
run() { # outdir, args...
  o="$1"; shift
  : > "$ACT"
  OUT=$(PATH="$STUB:$PATH" FP_STATE="$FP_STATE" FP_SSH="$FP_SSH" FP_RC_PROOF="$FP_RC_PROOF" \
        FP_RC_NW="$FP_RC_NW" FP_RC_RETIRE="$FP_RC_RETIRE" FP_RC_CPUFREQ="$FP_RC_CPUFREQ" \
        ZL1_MISC_OUT="$MISC_OUT" FP_REAL_SLEEP="$FP_REAL_SLEEP" \
        FP_RC_AB="$FP_RC_AB" FP_SLEEP_RETIRE="$FP_SLEEP_RETIRE" FP_SLEEP_CPUFREQ="$FP_SLEEP_CPUFREQ" \
        FP_SLEEP_AB="$FP_SLEEP_AB" FP_SLEEP_STATE="$FP_SLEEP_STATE" FP_RC_SCP="$FP_RC_SCP" \
        timeout 120 bash "$CHAIN" --outdir "$o" "$@" 2>&1); RC=$?
}
run_bg_start() { # outdir, args... -- for the interrupt scenario
  o="$1"; shift
  : > "$ACT"
  PATH="$STUB:$PATH" FP_STATE="$FP_STATE" FP_SSH="$FP_SSH" FP_RC_PROOF="$FP_RC_PROOF" \
    FP_RC_NW="$FP_RC_NW" FP_RC_RETIRE="$FP_RC_RETIRE" FP_RC_CPUFREQ="$FP_RC_CPUFREQ" \
    ZL1_MISC_OUT="$MISC_OUT" FP_REAL_SLEEP="$FP_REAL_SLEEP" \
    bash "$CHAIN" --outdir "$o" "$@" > "$W/bg.out" 2>&1 &
  BG_PID=$!
}

FP_STATE=present
FP_SSH=yes
FP_RC_PROOF=0
MISC_OUT="$MISC"
FP_REAL_SLEEP=""
scen() { # name -- a fresh archive dir, and the default device state
  S="$W/out/$1"; rm -rf "$S"; mkdir -p "$S"
  FP_STATE=present; FP_SSH=yes; FP_RC_PROOF=0; MISC_OUT="$MISC"; FP_REAL_SLEEP=""
  FP_RC_AB=0; FP_SLEEP_RETIRE=0; FP_SLEEP_CPUFREQ=0
  FP_SLEEP_AB=""; FP_SLEEP_STATE=""; FP_RC_SCP=0
  FP_RC_NW=""; FP_RC_RETIRE=""; FP_RC_CPUFREQ=""
  proof_obtained
}

echo "zl1 heat-fix chain -- offline self-test"
echo "  script under test: $SRC"
echo "  fake device:       $FR"
echo

# ==================================================================================================
echo "== 1. --help and the plan: the header, and no --yes = no run =="
# ==================================================================================================
scen help
run "$S" --help
want 'heat-fix chain' "$OUT" "--help prints the usage block"
notwant 'set -uo pipefail' "$OUT" "and stops at the header, not in the code after it"
[ "$RC" = 0 ] && ok "--help exits 0" || bad "--help exited $RC"

scen plan
run "$S"
[ "$RC" = 2 ] && ok "no --yes: exit 2 (refused), not 0" || bad "no --yes exited $RC, expected 2"
want 'PLAN \(nothing was run' "$OUT" "it says it is a plan and that nothing was run"
want 'install-retire-debug-keeper.sh --install --now --after-proof' "$OUT" "the plan names step 5 in full"
want 'proof-obtained' "$OUT" "and says what licenses it"
[ -z "$(callees)" ] && ok "no installer was invoked" || bad "an installer ran without --yes"
[ "$(grep -c '^scp ' "$ACT")" = 0 ] && ok "and nothing was pushed to the device" || bad "scp ran without --yes"
[ "$(grep -c '^ssh ' "$ACT")" -le 2 ] && ok "the only ssh calls are the reachability probe (no write)" \
  || bad "more ssh calls than the probe: $(sshs | tr '\n' ';')"

# ==================================================================================================
echo
echo "== 2. --status: read-only, no --yes needed, and it answers the chain's four questions =="
# ==================================================================================================
scen status
run "$S" --status
[ "$RC" = 0 ] && ok "--status exits 0" || bad "--status exited $RC"
want 'netwatch: file=present fn=has-ensure_addrs unit=active' "$OUT" "it reports the netwatch file, its function and the unit"
want 'keeper: gone' "$OUT" "and whether the keeper is still there"
want 'addrs:.*192.168.2.15=1 10.15.19.100=1' "$OUT" "and whether the two addresses are on the interfaces"
want 'governors:' "$OUT" "and what the four cores are set to"
[ -z "$(callees)" ] && ok "--status runs no installer" || bad "--status invoked an installer"
want 'netwatch-file:' "$(sshs)" "the questions are asked ON the device, in one script"

# ==================================================================================================
echo
echo "== 3. the three ways of being unreachable: refuse, name the next move, run nothing =="
# ==================================================================================================
scen edl
FP_STATE=edl
run "$S" --yes
[ "$RC" = 2 ] && ok "EDL: exit 2" || bad "EDL exited $RC"
want 'long-press POWER' "$OUT" "it names the physical move, which is the only one there is"
# The text used to carry the negation in the PREVIOUS line ("no QDL/firehose / tool may be run here"),
# which rendered as a line that reads like permission to run one. It now says it in its own words, and
# the assertion is on those words rather than on a phrase the reader has to reassemble.
want 'no downloader' "$OUT" "it says a downloader may NOT be run"
want 'not QFIL' "$OUT" "and names the tools it is not offering, so 'no QDL' cannot be read as vagueness"
notwant 'run (QFIL|QSaharaServer|fh_loader)' "$OUT" "rather than offering one as a way out"
[ "$(grep -c '^ssh ' "$ACT")" = 0 ] && ok "no ssh call was made at all" || bad "it tried to reach a phone that cannot answer"
[ -z "$(callees)" ] && ok "and no installer ran" || bad "an installer ran while the device was in EDL"

scen absent
serial_off
run "$S" --yes
serial_on
[ "$RC" = 2 ] && ok "absent: exit 2" || bad "absent exited $RC"
want 'NOT reachable: absent' "$OUT" "it says the device is not on the bus"
want '4a2fe00b' "$OUT" "and names the other phone on this bus that must be ignored"
[ -z "$(callees)" ] && ok "and no installer ran" || bad "an installer ran with no device on the bus"

scen sshdown
FP_SSH=no
run "$S" --yes
[ "$RC" = 2 ] && ok "ssh down: exit 2" || bad "ssh down exited $RC"
want 'zl1-rndis-recover.sh' "$OUT" "it points at the HOST-side recovery (no key press needed for that one)"
[ -z "$(callees)" ] && ok "and no installer ran" || bad "an installer ran over a dead link"

# ==================================================================================================
echo
echo "== 4. the preflight: a misc backup that is not verified stops the chain BEFORE it writes =="
# ==================================================================================================
# The installer requires a verified backup and takes none over ssh. Checking it first is the whole point
# of the preflight: the alternative is discovering it after step 1 has already changed a unit.
scen miscempty
MISC_OUT="$W/misc-truncated"
run "$S" --yes
[ "$RC" = 2 ] && ok "an EMPTY misc.img: exit 2" || bad "empty misc: exited $RC"
want 'not usable' "$OUT" "it says the backup is not usable"
[ -z "$(callees)" ] && ok "and stops before step 1" || bad "it ran an installer with no usable backup"

scen miscbadsum
MISC_OUT="$W/misc-badsum"
run "$S" --yes
[ "$RC" = 2 ] && ok "a misc.img that FAILS its SHA256: exit 2" || bad "bad checksum: exited $RC"
want 'SHA256' "$OUT" "and the reason names the checksum, not merely the file"
[ -z "$(callees)" ] && ok "and stops before step 1" || bad "it ran an installer on an unverified backup"

scen miscok
run "$S" --yes
want 'misc backup verified' "$OUT" "a verified backup is reported as verified, and the chain proceeds"
[ -n "$(callees)" ] && ok "and it went on to run the steps" || bad "it refused a backup that is fine"

# ==================================================================================================
echo
echo "== 5. the order, the wait, and the licence =="
# ==================================================================================================
scen happy
run "$S" --yes
[ "$RC" = 0 ] && ok "the whole chain exits 0" || bad "the chain exited $RC"
GOT=$(order)
[ "$GOT" = "install-netwatch-service install-netwatch-service install-retire-debug-keeper install-cpufreq-governor " ] \
  && ok "the four installers ran in the order deploy -> activate -> retire -> governor" \
  || bad "the order was: $GOT"
want 'install-netwatch-service args=--yes --ssh$' "$(callees)" "step 1 is a deploy over ssh, with no --activate"
want 'install-netwatch-service args=--yes --ssh --activate$' "$(callees)" "step 2 activates, and proves the running build"
want 'install-retire-debug-keeper args=--install --now --after-proof$' "$(callees)" "step 5 carries the licence flag, so the applier re-measures rather than remembers"
want 'install-cpufreq-governor args=--install$' "$(callees)" "step 6 is the governor, which is the other half of the heat"
[ "$(slept)" = 90 ] && ok "and it waited the default 90 s before the proof" || bad "the settle was '$(slept)', not 90"
want 'sh /tmp/zl1-address-owner-proof.sh --yes' "$(sshs)" "the proof was run ON the device, with --yes (it stops a process)"
want 'scp .*zl1-address-owner-proof.sh' "$(cat "$ACT")" "and the REAL proof was pushed, not a stand-in"
# And that claim AS A MEASUREMENT: the scp stub copies into the fake device's /tmp, so the bytes the
# device would run can be compared with the file in this repository. The assertion above is about the
# NAME, which a stand-in called the same thing would satisfy just as well.
if cmp -s "$FR/tmp/zl1-address-owner-proof.sh" "$PROOF_REAL"; then
  ok "and what landed there is byte-identical to scripts/device/zl1-address-owner-proof.sh"
else
  bad "the pushed proof is not the repository's file (cmp differs, or nothing was copied)"
fi
# The archive: an index that names each step with its rc, and checksums that verify.
want '^01-netwatch-deploy *0' "$(cat "$S/INDEX.txt" 2>/dev/null)" "the index lists step 01 with its rc"
want '^06-cpufreq-governor *0' "$(cat "$S/INDEX.txt" 2>/dev/null)" "and step 06"
want '03-settle' "$(cat "$S/INDEX.txt" 2>/dev/null)" "the wait is a step of its own (a chain that skipped it would fail in the proof)"
( cd "$S" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ) && ok "the archive's checksums verify" || bad "the archive does not verify"
want 'keeper: gone' "$OUT" "and the final read-back is printed"

scen settle
run "$S" --yes --settle 5
[ "$(slept)" = 5 ] && ok "--settle 5 waits 5 s" || bad "--settle 5 waited '$(slept)'"

# ==================================================================================================
echo
echo "== 5b. the A/B: the chain measures the two fixes, and says when it could not =="
# ==================================================================================================
# Why this section exists: the chain changes the two things that make this phone hot. Its evidence used
# to be that the installers returned 0, which is the rule this whole sequence is built on applied to
# everything EXCEPT the thing the sequence is for. The A/B is wired in now, and what has to be true is
# that it RUNS, that its output is READ, and -- the part a naive version gets wrong -- that a
# measurement which did not happen is reported as not having happened.
scen ab
run "$S" --yes
[ "$RC" = 0 ] && ok "the chain with the A/B exits 0" || bad "it exited $RC"
want 'scp .*device/zl1-thermal.sh /tmp/zl1-thermal.sh|scp .*zl1-thermal.sh' "$(cat "$ACT")" \
  "the REAL instrument was pushed to the device"
want 'sh /tmp/zl1-thermal.sh --ab --seconds 30 --hold 120' "$(sshs)" \
  "and it was run with the two windows and the hold, as its own header prescribes"
want '^06b-heat-ab *0 *06b-heat-ab.txt' "$(cat "$S/INDEX.txt" 2>/dev/null)" \
  "the measurement is a row in the index, like every other step"
[ -f "$S/06b-heat-ab.txt" ] && ok "and its output is in the archive" || bad "no 06b-heat-ab.txt"
want '^== B minus A per process' "$(cat "$S/06b-heat-ab.txt")" "which holds the instrument's own output"
want 'ALIGNED: the work finished' "$(cat "$S/06b-heat-ab.txt")" \
  "and the bookkeeping says the windows straddle the work"
want 'tsens_tz_sensor8.*-5.5 C' "$OUT" "the per-zone difference is printed to the operator, not just archived"
want 'ALIGNED: window A is before either fix, window B after both' "$OUT" "with the alignment stated"
want 'Read it as a READING' "$OUT" "and the caveats printed beside the numbers"
want 'this chain prints no verdict on the heat itself' "$OUT" \
  "and it says out loud that it prints no verdict on the heat itself"
notwant 'verdict: heat-fixed' "$OUT" "because a temperature difference here licenses no such word"
# the A/B must straddle the FIXES, not the whole chain: it starts after the proof is decided and after
# the netwatch swap, which is the baseline the two named causes need.
A_ORDER=$(grep -n '^CALLEE ' "$ACT" | head -20 | tr '\n' ' ')
case "$A_ORDER" in
*"CALLEE install-retire-debug-keeper"*) ok "the fixes ran inside the hold (the retire step is there)" ;;
*) bad "the retire step is missing from the recording" ;;
esac

echo
echo "   -- --no-ab: the operator asked for no measurement, and it is printed as a CHOICE:"
scen ab-off
run "$S" --yes --no-ab
[ "$RC" = 0 ] && ok "the chain still runs and exits 0" || bad "it exited $RC"
want '^06b-heat-ab *skip' "$(cat "$S/INDEX.txt" 2>/dev/null)" "the index records 'skip', not a measurement"
want 'NOT MEASURED: --no-ab' "$OUT" "and the operator is told in words"
want 'This is a CHOICE, not a reading' "$(cat "$S/06b-heat-ab.txt")" "the archive says the same thing"
notwant 'zl1-thermal.sh' "$(cat "$ACT")" "and nothing was pushed or run"

echo
echo "   -- the instrument is not on this host: UNMEASURED, and named:"
scen ab-noinstrument
mv "$DEV_FAKE/zl1-thermal.sh" "$DEV_FAKE/zl1-thermal.sh.hidden"
run "$S" --yes
mv "$DEV_FAKE/zl1-thermal.sh.hidden" "$DEV_FAKE/zl1-thermal.sh"
[ "$RC" = 0 ] && ok "the chain still runs (a missing instrument is not a reason to skip the heat fixes)" \
  || bad "it exited $RC"
want '^06b-heat-ab *unusable' "$(cat "$S/INDEX.txt" 2>/dev/null)" "the index records 'unusable'"
want 'NOT MEASURED: the instrument could not be put on the device' "$OUT" "and says so"
want 'the effect of these two fixes is UNMEASURED on this boot' "$(cat "$S/06b-heat-ab.txt")" \
  "naming what is therefore unknown"
notwant 'zl1-thermal.sh --ab' "$(sshs)" "and the instrument was never run"

echo
echo "   -- the instrument ran, returned 0, and printed nothing: NOT a measurement:"
scen ab-empty
cp "$AB_FIX" "$W/ab.keep"; : > "$AB_FIX"
run "$S" --yes
cp "$W/ab.keep" "$AB_FIX"
[ "$RC" = 0 ] && ok "the chain still runs" || bad "it exited $RC"
want '^06b-heat-ab *empty' "$(cat "$S/INDEX.txt" 2>/dev/null)" \
  "the index does not record a 0 that would read as 'fine'"
want 'printed no difference section' "$OUT" "and the reason is the emptiness, not the exit code"
want 'Return 0 is not a measurement' "$OUT" "which is the rule this whole tree keeps recording"

echo
echo "   -- the instrument failed: the chain says which code, and still finishes:"
scen ab-failed
FP_RC_AB=7
run "$S" --yes
FP_RC_AB=0
[ "$RC" = 0 ] && ok "a failed measurement does not abort the chain" || bad "it exited $RC"
want '^06b-heat-ab *7' "$(cat "$S/INDEX.txt" 2>/dev/null)" "the index carries the instrument's own rc"
want 'the instrument ran and returned 7' "$OUT" "and the operator is told"

echo
echo "   -- the measurement the HOST gave up on: its own state, and NOT a failed instrument:"
# The A/B is a 180-second ssh by default, and every step of this chain runs on a link the chain itself
# re-enumerates -- so the state that matters most is the one where it never comes back. It must not be
# filed as `failed`: that reads "the instrument ran and said no", a claim about the phone nobody has
# evidence for. (FP_REAL_SLEEP makes the fixture's sleeps real -- without it the stubbed `sleep` returns
# instantly and nothing can outlast a bound.)
scen ab-timeout
FP_REAL_SLEEP=1
FP_SLEEP_AB=30
run "$S" --yes --settle 0 --ab-limit 2
FP_SLEEP_AB=""; FP_REAL_SLEEP=""
[ "$RC" = 0 ] && ok "a measurement the host gave up on does not abort the chain" || bad "it exited $RC"
want '^06b-heat-ab *124' "$(cat "$S/INDEX.txt" 2>/dev/null)" "the index carries timeout(1)'s own code"
want 'DID NOT FINISH' "$(cat "$S/INDEX.txt" 2>/dev/null)" "and one line explains what that code means, because a bare 124 reads as 'the instrument said 124'"
want 'NOT MEASURED, and NOT a refusal by the instrument' "$OUT" "the operator is told the HOST gave up, not that the instrument refused"
want 'the host gave up on it after 2s' "$OUT" "and the bound it gave up at is printed"
notwant 'the instrument ran and returned 124' "$OUT" "so it is NOT filed as a failed measurement (a claim about the phone nobody has evidence for)"

echo
echo "   -- and the instrument could not be put on the device: which rc, in the archive:"
scen ab-scprc
FP_RC_SCP=7
run "$S" --yes
FP_RC_SCP=0
want '^06b-heat-ab *unusable' "$(cat "$S/INDEX.txt" 2>/dev/null)" "a failed transfer is recorded as 'unusable', not as a measurement"
want 'scp of the instrument FAILED \(rc=7;' "$(cat "$S/06b-heat-ab.txt" 2>/dev/null)" "and the transport's own rc is in the file, so 'scp said 7' and 'scp was killed' are not the same reading"

echo
echo "   -- the measurement's bound is COMPUTED, so widening the measurement widens it:"
# A fixed bound would truncate a legitimate long measurement the moment somebody widened --ab-window or
# --ab-hold, and a bound that cannot be satisfied is the defect this tree records in the camera
# instrument (docs 104: a gate no run could pass). So what is asserted is the ARITHMETIC, printed.
scen ab-bound
run "$S" --yes --ab-window 5 --ab-hold 7
[ "$RC" = 0 ] && ok "a widened measurement still runs" || bad "it exited $RC"
want 'bounded at 77s \(2 x 5 \+ 7 \+ 60\)' "$OUT" "window 5 and hold 7 give a 77 s bound, printed as arithmetic"
notwant 'bounded at 120s' "$OUT" "not a fixed number that a wider measurement would then silently outlast"

echo
echo "   -- the work outlasted the hold: the deltas are declared CONTAMINATED, not published:"
# An instant stand-in cannot make the work outlast the hold, so this scenario shortens BOTH knobs and
# makes one step really take time. Without the alignment check the chain would print a temperature
# difference as the result of the fixes when window B still contained part of them.
scen ab-misaligned
FP_REAL_SLEEP=1
FP_SLEEP_RETIRE=2
run "$S" --yes --settle 0 --ab-window 0 --ab-hold 0
FP_REAL_SLEEP=""; FP_SLEEP_RETIRE=0
[ "$RC" = 0 ] && ok "the chain still runs" || bad "it exited $RC"
want 'NOT ALIGNED: window B began [0-9]*s BEFORE the work finished' "$(cat "$S/06b-heat-ab.txt")" \
  "the archive says the windows do not straddle the work"
want 'NOT ALIGNED: window B still contains part of the work' "$OUT" "and so does the operator's read-out"

# ==================================================================================================
echo
echo "== 6. the licence: a verdict that is not exactly 'proof-obtained' does not kill anything =="
# ==================================================================================================
scen unclear
proof_unclear proof-unclear
run "$S" --yes
[ "$RC" = 1 ] && ok "proof-unclear: exit 1 (a stopped chain, not a crash)" || bad "proof-unclear exited $RC"
notwant 'install-retire-debug-keeper' "$(order)" "the keeper was NOT retired"
# THE LICENCE'S SCOPE, asserted from both sides (docs 118 as amended): step 4 licenses the KILL, and
# only the kill. The governor changes cpufreq scaling, removes no process and touches no address, so a
# refusal must NOT lose it -- because the proof's verdict is a race and most boots will refuse.
want 'install-cpufreq-governor' "$(order)" "and the governor WAS installed anyway (it needs no licence from the proof)"
want 'other half needs NO licence' "$OUT" "with the reason said out loud, not left to be inferred"
want 'THE KEEPER IS STILL IN PLACE' "$OUT" "and the half that is MISSING is named as missing"
want 'governors: interactive' "$OUT" "the read-back was taken after the governor step"
want 'REFUSING TO RETIRE THE KEEPER' "$OUT" "it says so out loud"
want 'still owns the' "$OUT" "and says the keeper still owns the addresses, i.e. the phone is reachable"
want '^01-netwatch-deploy *0' "$(cat "$S/INDEX.txt" 2>/dev/null)" "and it left an archive that says how far it got"
want '^06-cpufreq-governor *0' "$(cat "$S/INDEX.txt" 2>/dev/null)" "which lists the governor as the step that DID run"
notwant '^05-retire-keeper' "$(cat "$S/INDEX.txt" 2>/dev/null)" "and does not list a step that was never attempted"

scen noverdict
printf 'the proof ran but printed no verdict line at all\n' > "$W/proof.txt"
run "$S" --yes
[ "$RC" = 1 ] && ok "no verdict line at all: exit 1" || bad "no verdict line exited $RC"
notwant 'install-retire-debug-keeper' "$(order)" "and nothing was killed"
want 'none: no verdict line' "$OUT" "the missing verdict is stated as missing, not as a failed proof"

scen substring
# The defect docs 114 fixed, one level up: a gate that greps for 'proof-obtained' anywhere accepts a
# sentence that merely contains it. The chain compares the whole line, so this must NOT license a kill.
proof_unclear 'proof-obtained (probably)'
run "$S" --yes
[ "$RC" = 1 ] && ok "a verdict line that only CONTAINS the words: exit 1" || bad "the substring verdict exited $RC"
notwant 'install-retire-debug-keeper' "$(order)" "and it did not license the kill (the whole-line rule)"

scen proofrc
scen proofrc
proof_obtained
FP_RC_PROOF=1
run "$S" --yes
[ "$RC" = 1 ] && ok "the verdict line is right but the proof exited 1: exit 1" || bad "rc=1 proof exited $RC"
notwant 'install-retire-debug-keeper' "$(order)" "and the kill waits for a proof that succeeded, not one that printed the word"

# ==================================================================================================
echo
echo "== 7. a failing step stops the chain, and says where it stopped =="
# ==================================================================================================
scen midfail
FP_RC_NW=1
run "$S" --yes
[ "$RC" = 1 ] && ok "step 1 failing: exit 1" || bad "a failing step exited $RC"
notwant 'install-cpufreq-governor' "$(order)" "nothing after it ran"
notwant 'zl1-address-owner-proof' "$(sshs)" "and the proof was not attempted on a device whose netwatch is not deployed"
want 'THE CHAIN STOPPED HERE' "$OUT" "the stop is stated as a stop"
want 'netwatch: file=' "$OUT" "and the device was read back, so the next reader knows what state it is in"
want '^01-netwatch-deploy *1' "$(cat "$S/INDEX.txt" 2>/dev/null)" "the archive records the failing rc"

# A failure later is the interesting one: it is the step whose predecessor DID run, so the run is stopped
# with the keeper untouched but the netwatch activated -- the state a person has to be told about.
scen latefail
FP_RC_RETIRE=1
run "$S" --yes
[ "$RC" = 1 ] && ok "step 5 failing: exit 1" || bad "step 5 failing exited $RC"
notwant 'install-cpufreq-governor' "$(order)" "the governor was not installed"
want '^04-proof *0' "$(cat "$S/INDEX.txt" 2>/dev/null)" "but the proof DID run, and the archive shows it"
want 'keeper: gone' "$OUT" "and the read-back after the failure is taken (the fixture says the keeper is gone)"

echo
echo "   -- a step that never comes back is its OWN state, not a failure of the step:"
# Every step here is an ssh on a link this chain re-enumerates, and a hung ssh does not fail, it hangs --
# and a boot bought with a physical power hold is what it spends, silently. So the bound, the state and
# the archive are the whole point: "did not finish" is a different claim about the device from "failed",
# and the next reader acts differently on it. The MUST-install half is what makes stopping mandatory here.
scen step-timeout
FP_REAL_SLEEP=1
FP_SLEEP_RETIRE=5
run "$S" --yes --settle 0 --step-limit 2
FP_SLEEP_RETIRE=0; FP_REAL_SLEEP=""
[ "$RC" = 1 ] && ok "a step that ran out of time: exit 1 (a stopped chain, not a crash)" || bad "it exited $RC"
want 'DID NOT FINISH: killed at 2s \(rc=124, timeout\(1\)\)' "$OUT" "the host-side reason is named, with the bound and the code"
want 'NOT a failure of the step' "$OUT" "and it is explicitly NOT filed as a failure of the step"
notwant 'FAILED rc=124' "$OUT" "the failure branch did not claim it, because that is a different claim about the phone"
want 'State of the device now:' "$OUT" "the device is read back anyway -- that is what the next reader needs"
want 'may be half-done ON THE DEVICE' "$OUT" "and the operator is warned that the step could have been mid-write"
want '^05-retire-keeper *124' "$(cat "$S/INDEX.txt" 2>/dev/null)" "the archive carries timeout(1)'s code"
want 'DID NOT FINISH' "$(cat "$S/INDEX.txt" 2>/dev/null)" "and the line above the table explains that 124 is not the step saying 124"
notwant 'install-cpufreq-governor' "$(order)" "nothing after the step that did not finish was run"

echo
echo "   -- the read-back is bounded too, and it says UNREADABLE rather than nothing:"
# A bound on the steps is defeated by an unbounded read-back after them: read_state IS an ssh, and it is
# the LAST thing every archiving path does. Hung there, the archive -- the thing the boot was spent for --
# would never be written. And printing nothing would be worse than useless: an empty value in INDEX.txt
# reads as "the device was asked and said nothing", which a host-side timeout is no evidence for.
scen state-timeout
FP_REAL_SLEEP=1
FP_RC_RETIRE=1
FP_SLEEP_STATE=5
run "$S" --yes --settle 0 --state-limit 2
FP_SLEEP_STATE=""; FP_REAL_SLEEP=""; FP_RC_RETIRE=""
[ "$RC" = 1 ] && ok "the failed step still stops the chain" || bad "it exited $RC"
[ -f "$S/INDEX.txt" ] && ok "and the archive is still written -- the read-back did not swallow it" || bad "no INDEX: the read-back swallowed the archive"
want 'UNREADABLE: the read-back did not answer within 2s' "$(cat "$S/INDEX.txt" 2>/dev/null)" "what could not be read is stated, with the bound"
want "the ssh was killed and the device was NOT read" "$(cat "$S/INDEX.txt" 2>/dev/null)" "and the silence is explicitly not reported as 'the device said nothing'"
notwant '^netwatch: file=' "$(cat "$S/INDEX.txt" 2>/dev/null)" "and no device state is invented"

# ==================================================================================================
echo
echo "== 8. an interrupt still leaves an archive, and exits 3 =="
# ==================================================================================================
scen interrupt
FP_REAL_SLEEP=1  # the settle becomes a real sleep, so there is something to interrupt
run_bg_start "$S" --yes --settle 30
sleep 2
kill -TERM "$BG_PID" 2>/dev/null
wait "$BG_PID" 2>/dev/null
RC=$?
[ "$RC" = 3 ] && ok "SIGTERM during the wait: exit 3 (its own code)" || bad "an interrupted chain exited $RC"
[ -f "$S/INDEX.txt" ] && ok "and it archived an INDEX anyway" || bad "an interrupted chain left no INDEX"
want 'INTERRUPTED' "$(cat "$S/INDEX.txt" 2>/dev/null)" "which says it was interrupted"
want '^02-netwatch-activate *0' "$(cat "$S/INDEX.txt" 2>/dev/null)" "and lists the steps that HAD finished"
FP_REAL_SLEEP=""

# ==================================================================================================
echo
echo "== 9. the mutations: each one must change what the checks above observe =="
# ==================================================================================================
# A harness that cannot fail is not a harness, and the cheapest honest way to show that is to break the
# subject on purpose and watch the failure appear. Each mutant is one sed, and what is asserted is the
# OBSERVABLE difference -- not merely that the harness would complain.
#
# The mutant is built from the REWRITTEN copy, not from the shipped file, and that is not a shortcut:
# the shipped file resolves its four callees as "$HERE/../install-*.sh", so a mutant made from it exits 2
# in its OWN preflight ("cannot read .../fake-repo/scripts/install-netwatch-service.sh") and every check
# below would be measuring that one fact instead of the mutation -- five checks failing with rc=2 and,
# worse, two of them (the notwant ones) PASSING because nothing ran. The rewrite touches only the four
# callee paths and the boot-bus lookup, so the lines being mutated are still the shipped lines, and
# mutate() asserts that: the same sed must also change the SHIPPED file, or the mutant is not a mutant
# of anything real.
CHAIN_DIR="$W/fake-repo/scripts/host"
mutate() { # name, sed-script -- returns 0 only if the mutation landed AND the subject would change
  if cmp -s <(sed "$2" "$SRC" 2>/dev/null) "$SRC"; then
    bad "mutation '$1': its sed matches no line of the SHIPPED script, so nothing is being tested"
    return 1
  fi
  sed "$2" "$CHAIN" > "$CHAIN_DIR/$1.sh"
  if cmp -s "$CHAIN" "$CHAIN_DIR/$1.sh"; then
    bad "mutation '$1': the sed would change the shipped file but not the subject -- it did not land"
    return 1
  fi
  if ! bash -n "$CHAIN_DIR/$1.sh" 2>/dev/null; then
    bad "mutation '$1': the mutant does not parse"
    return 1
  fi
  chmod +x "$CHAIN_DIR/$1.sh"
  ok "mutation '$1': landed (it changes a line of the shipped script, and the mutant parses)"
  return 0
}
mutant_run() { # mutant-file, outdir
  : > "$ACT"
  OUT=$(PATH="$STUB:$PATH" FP_STATE="$FP_STATE" FP_SSH=yes FP_RC_PROOF="$FP_RC_PROOF" \
        FP_RC_NW="$FP_RC_NW" FP_RC_RETIRE="$FP_RC_RETIRE" FP_RC_CPUFREQ="$FP_RC_CPUFREQ" \
        ZL1_MISC_OUT="$MISC_OUT" timeout 120 bash "$1" --outdir "$2" --yes 2>&1); RC=$?
}
# Every mutation below asserts, FIRST, that the mutant reached the steps. Without that line the two
# negative assertions in this section are satisfied by a mutant that refused before it did anything --
# a check that cannot fail, which is the defect this whole section exists to catch.

# (1) no settle: the chain would run the proof against a build that may be re-enumerating the gadget
# The pattern names BOTH lines of the wait (`sleep "$SETTLE" &` and the `wait $!` that makes it
# interruptible), because removing only the sleep would leave `wait` waiting for nothing -- and the
# first version of this sed matched a foreground `sleep "$SETTLE"` that the SIGTERM fix had since
# replaced, which is what the "matches no line of the shipped script" guard is for. (The trailing
# anchor is a bare `$`: GNU sed does not match a literal dollar written `\$` at the end of a pattern,
# which is why the first attempt at this one silently matched nothing.)
if mutate nosettle 's#^sleep "\$SETTLE" &$#: #
s#^wait \$!$#: #'; then
  scen mut-nosettle
  mutant_run "$CHAIN_DIR/nosettle.sh" "$S"
  [ -n "$(callees)" ] && ok "and it still reached the steps (an empty sleep is a change, not a refusal)" \
                      || bad "the 'no settle' mutant never got to step 1 (rc=$RC) -- the check below is vacuous"
  [ "$(slept)" = "" ] && ok "mutation 'no settle': the wait is gone (so the assertion that it IS 90 is live)" \
                      || bad "the 'no settle' mutation still slept '$(slept)'"
fi
# (2) the verdict accepted as a substring: the docs-114 defect, in this script
if mutate substring 's#^VERDICT=\$(grep -ax .*$#VERDICT=$(grep -a proof-obtained "$OUT/04-proof.txt" >/dev/null \&\& echo proof-obtained)#'; then
  scen mut-substring
  proof_unclear 'proof-obtained (probably)'
  mutant_run "$CHAIN_DIR/substring.sh" "$S"
  [ "$RC" = 0 ] && ok "mutation 'substring gate': a near-miss verdict now licenses the kill (the check is live)" \
                || bad "the 'substring gate' mutation did not change the outcome (rc=$RC)"
  want 'install-retire-debug-keeper' "$(order)" "and the keeper was killed on a verdict that only contains the words"
  proof_obtained
fi
# (3) the kill before the proof: the order is the licence
# The sed names the `"$RETIRE" ` prefix on purpose: the bare string `--install --now --after-proof` also
# occurs in the header comment and in the plan, so a sed on that alone would edit prose and leave the
# INVOCATION untouched -- a mutant that reports as landed and behaves exactly like the subject, which is
# how this check failed the first time it was run.
if mutate proofafter 's#"\$RETIRE" --install --now --after-proof#"$RETIRE" --install --now#'; then
  scen mut-proofafter
  mutant_run "$CHAIN_DIR/proofafter.sh" "$S"
  [ -n "$(callees)" ] && ok "and the mutant reached the steps, so the licence flag is what is being read" \
                      || bad "the 'drop --after-proof' mutant never got to step 1 (rc=$RC)"
  want 'install-retire-debug-keeper args=--install --now$' "$(callees)" \
    "mutation 'drop --after-proof': the applier is asked to kill without re-measuring"
fi
# (4) the preflight becomes the old `[ -f ]` gate
if mutate weakexist 's#^if ! MISC_WHY=\$(misc_backup_ok); then#if false; then #'; then
  scen mut-weakexist
  MISC_OUT="$W/misc-truncated"
  mutant_run "$CHAIN_DIR/weakexist.sh" "$S"
  [ -n "$(callees)" ] && ok "mutation 'weak preflight': an EMPTY backup no longer stops the chain (the check is live)" \
                      || bad "the 'weak preflight' mutation still refused (rc=$RC) -- it did not land"
  MISC_OUT="$MISC"
fi
# (5) the unreachable-device refusal removed
if mutate noedlrefuse 's#^STATE=\$(edl_state)$#STATE=present#'; then
  scen mut-noedlrefuse
  FP_STATE=edl
  mutant_run "$CHAIN_DIR/noedlrefuse.sh" "$S"
  [ "$(grep -c '^CALLEE' "$ACT")" != 0 ] && ok "mutation 'no EDL refusal': something ran against a phone in EDL (the check is live)" \
                                        || bad "the 'no EDL refusal' mutation ran nothing (rc=$RC) -- it did not land"
  FP_STATE=present
fi
# (6) the governor gated on the proof again: the over-gate docs 118's amendment removed
# The licence step 4 gives is for the KILL. This mutant puts it back in front of the governor -- the
# behaviour the chain had until the scope was corrected -- and the observable difference is that a boot
# whose proof is not clean installs NEITHER half of the heat fix. The sed joins the two lines of the
# invocation in the refusal branch (the `N`), so both the `step` wrapper and its argument line go.
if mutate nogovrefuse '/independent of the address proof/{N
s#.*#  : #}'; then
  scen mut-nogovrefuse
  proof_unclear proof-unclear
  mutant_run "$CHAIN_DIR/nogovrefuse.sh" "$S"
  [ "$RC" = 1 ] && ok "and it still stops (the refusal itself is untouched)" || bad "the over-gate mutant exited $RC"
  notwant 'install-cpufreq-governor' "$(order)" "mutation 'governor gated on the proof': half the heat fix is lost to a race"
  notwant '06-cpufreq-governor' "$(cat "$S/INDEX.txt" 2>/dev/null)" "and the archive does not claim it ran"
  proof_obtained
fi
# (7) the kill without the licence: the safety-critical direction of the same branch
# A mutation that makes the refusal branch fall through to step 5, i.e. a chain that kills the keeper on
# a proof that did not license it. This is the one that could cost the phone its addresses.
if mutate killanyway 's#^if \[ "\$PROOF_RC" != 0 \] || \[ "\$VERDICT" != "proof-obtained" \]; then#if false; then #'; then
  scen mut-killanyway
  proof_unclear proof-unclear
  mutant_run "$CHAIN_DIR/killanyway.sh" "$S"
  [ -n "$(callees)" ] && ok "and the mutant reached the steps, so the licence test is what is being read" \
                      || bad "the 'kill anyway' mutant never got to step 1 (rc=$RC)"
  want 'install-retire-debug-keeper args=--install --now --after-proof' "$(callees)" \
    "mutation 'kill anyway': the keeper is retired on a verdict that did not license it (the check is live)"
  proof_obtained
fi

# (8) the empty-output check removed: "the ssh returned 0" read as "a measurement was taken"
# This is the defect the A/B section exists for, one level down: an instrument that lands, runs, and
# prints nothing would be reported as a measurement. The sed deletes the whole elif branch, leaving the
# rc test -- which is what the first draft of this code did.
if mutate abnocontent '/^  elif ! grep -q .\^== B minus A per thermal zone/{N
s#.*#  : #}'; then
  scen mut-abnocontent
  cp "$AB_FIX" "$W/ab.keep"; : > "$AB_FIX"
  mutant_run "$CHAIN_DIR/abnocontent.sh" "$S"
  cp "$W/ab.keep" "$AB_FIX"
  [ -n "$(callees)" ] && ok "and the mutant reached the steps" || bad "the mutant never ran (rc=$RC)"
  # Positive, not merely absent: the corrupted state is that the empty run is recorded as a SUCCESS.
  want '^06b-heat-ab *0' "$(cat "$S/INDEX.txt" 2>/dev/null)" \
    "mutation 'no content check': an empty measurement is recorded as a success (the check is live)"
  notwant 'printed no difference section' "$OUT" "and nothing tells the operator it was empty"
fi
# (9) the alignment check removed: a contaminated window published as a result
if mutate abnoalign 's#^    if \[ "\$margin" -ge 0 \]; then#    if true; then #'; then
  scen mut-abnoalign
  FP_REAL_SLEEP=1; FP_SLEEP_RETIRE=2
  : > "$ACT"
  OUT=$(PATH="$STUB:$PATH" FP_STATE=present FP_SSH=yes FP_RC_PROOF=0 ZL1_MISC_OUT="$MISC_OUT" \
        FP_REAL_SLEEP=1 FP_SLEEP_RETIRE=2 timeout 120 bash "$CHAIN_DIR/abnoalign.sh" \
        --outdir "$S" --yes --settle 0 --ab-window 0 --ab-hold 0 2>&1); RC=$?
  FP_REAL_SLEEP=""; FP_SLEEP_RETIRE=0
  [ -n "$(callees)" ] && ok "and the mutant reached the steps" || bad "the mutant never ran (rc=$RC)"
  want 'ALIGNED' "$(cat "$S/06b-heat-ab.txt" 2>/dev/null)" \
    "mutation 'no alignment check': a window that still contained the work is reported as ALIGNED"
  notwant 'NOT ALIGNED' "$OUT" "and the operator is not warned"
fi
# (10) the caveat line removed: the numbers printed as if they were a verdict
if mutate abnoverdict '/^    say "   Read it as a READING/{N
s#.*#    : #}'; then
  scen mut-abnoverdict
  mutant_run "$CHAIN_DIR/abnoverdict.sh" "$S"
  [ -n "$(callees)" ] && ok "and the mutant reached the steps" || bad "the mutant never ran (rc=$RC)"
  notwant 'Read it as a READING' "$OUT" \
    "mutation 'no caveat': the deltas are printed with nothing saying what they are not (the check is live)"
  want 'tsens_tz_sensor8' "$OUT" "and the numbers ARE printed -- the caveat is the only thing missing"
fi

# (11) the step's wall-clock bound removed: a hung ssh would spend the boot silently
# What this mutation must NOT do is change the outcome of a run whose steps are fine -- so the scenario
# gives one step a real 5 s, which the bound cuts at 2. Without the bound the step simply SUCCEEDS late,
# and that is the defect: from the archive alone, "took five seconds" and "hung for the rest of the boot"
# are the same reading until somebody widens the bound.
if mutate stepbound 's#^  bound "\$STEP_LIMIT" "\$@"#  "$@"#'; then
  scen mut-stepbound
  : > "$ACT"
  OUT=$(PATH="$STUB:$PATH" FP_STATE=present FP_SSH=yes FP_RC_PROOF=0 ZL1_MISC_OUT="$MISC_OUT" \
        FP_REAL_SLEEP=1 FP_SLEEP_RETIRE=5 FP_SLEEP_AB="" FP_SLEEP_STATE="" FP_RC_SCP=0 \
        timeout 120 bash "$CHAIN_DIR/stepbound.sh" --outdir "$S" --yes --settle 0 --step-limit 2 2>&1); RC=$?
  [ "$RC" = 0 ] && ok "mutation 'no step bound': the chain finishes -- a step that outlasted its bound is recorded as a success" \
                || bad "the 'no step bound' mutant exited $RC (it did not land)"
  want '^05-retire-keeper *0' "$(cat "$S/INDEX.txt" 2>/dev/null)" "and the index says 0, which is what a hang would also look like (the check is live)"
  notwant 'DID NOT FINISH' "$OUT" "with nothing anywhere telling the operator it took longer than it was allowed to"
fi
# (12) the read-back's bound removed: the archive's last step can outlast the boot
if mutate statebound 's#bound "\$STATE_LIMIT" ##'; then
  scen mut-statebound
  : > "$ACT"
  OUT=$(PATH="$STUB:$PATH" FP_STATE=present FP_SSH=yes FP_RC_PROOF=0 ZL1_MISC_OUT="$MISC_OUT" \
        FP_REAL_SLEEP=1 FP_RC_RETIRE=1 FP_SLEEP_RETIRE=0 FP_SLEEP_STATE=5 FP_SLEEP_AB="" FP_RC_SCP=0 \
        timeout 120 bash "$CHAIN_DIR/statebound.sh" --outdir "$S" --yes --settle 0 --state-limit 2 2>&1); RC=$?
  FP_SLEEP_STATE=""; FP_REAL_SLEEP=""; FP_RC_RETIRE=""
  [ "$RC" = 1 ] && ok "mutation 'no read-back bound': the chain still stops" || bad "the 'no read-back bound' mutant exited $RC"
  notwant 'UNREADABLE' "$(cat "$S/INDEX.txt" 2>/dev/null)" "and the read-back that outlasted its bound is NOT declared unreadable (the check is live)"
  want '^netwatch: file=' "$(cat "$S/INDEX.txt" 2>/dev/null)" "the archive just waits it out and takes the reading -- which is right here and wrong on a stalled link"
fi

# ==================================================================================================
echo
echo "== 9c. this harness did not edit the tree it tests =="
# ==================================================================================================
# This section exists because it really happened, in this file, and NOTHING ELSE HERE COULD SEE IT: the
# stand-ins were planted through a directory symlink, so `>` wrote into the repository and replaced
# scripts/device/zl1-thermal.sh -- the only heat instrument this project has -- with a one-line comment.
# The run stayed green. Six sections of careful assertions cannot notice that the subject's own
# instrument was deleted by the fixture.
#
# So the claim is a hash, taken before the fixtures were built and re-taken here: asserts go red for a
# behaviour, this one goes red for the TREE. It hashes the one file rather than the directory, because
# the rest of the tree is edited by people between runs and a whole-directory comparison would fail for
# reasons that have nothing to do with this harness.
REAL_THERMAL_AFTER=$(sha256sum "$REAL_THERMAL" | awk '{print $1}')
if [ "$REAL_THERMAL_BEFORE" = "$REAL_THERMAL_AFTER" ]; then
  ok "scripts/device/zl1-thermal.sh is byte-identical to what it was before this run"
else
  bad "THIS RUN CHANGED $REAL_THERMAL -- a fixture write is landing in the repository, not in \$W"
fi
if [ -L "$DEV_FAKE/zl1-thermal.sh" ]; then
  bad "the instrument stand-in is a SYMLINK, so writing it edits whatever it points at"
else
  ok "the instrument stand-in is a regular file inside \$W, not a link into the tree"
fi
if [ -L "$DEV_FAKE/zl1-address-owner-proof.sh" ]; then
  ok "and the proof in the same directory is a link to the real one, so the push is the real thing"
else
  bad "the proof is not a link to the repository's file -- 'it pushed the REAL proof' is now about a fixture"
fi

# The guard is a mechanism, so exercise it: `wrote()` is handed a path that IS a symlink and must
# refuse. In a SUBSHELL, because the way it refuses is `exit 2` -- a guard that has stopped refusing
# must be recorded as a failed check, not allowed to end this harness where the defect would have.
#
# And NOT on a path into the repository. The first version of this check pointed `wrote()` at the proof
# link -- i.e. at scripts/device/ -- so a guard that had stopped refusing would have truncated a real
# device script: the check that exists to protect the tree damaging the tree, which is the defect one
# level down. The link is inside $W, and the file it points at is checked too, because "it refused" is
# the message and "nothing was written" is the property.
printf 'scratch\n' > "$W/guard-target"
ln -s "$W/guard-target" "$W/guard-link"
_g=$( (wrote "$W/guard-link" <<'X'
X
) 2>&1 ); _grc=$?
if [ "$_grc" = 2 ] && printf '%s' "$_g" | grep -q 'REFUSING to write through the symlink'; then
  ok "the write helper refuses a symlinked target, which is the mechanism that makes it unrepeatable"
else
  bad "wrote() did not refuse a symlink (rc=$_grc, said '$_g') -- the next fixture write could land in the tree"
fi
[ "$(cat "$W/guard-target")" = scratch ] && ok "and it wrote nothing -- the refusal is not just a message" \
  || bad "the guarded write went through anyway: \$W/guard-target now holds '$(cat "$W/guard-target")'"

# And can the hash check above fail at all? The only way to show a check like that is live is to let a
# write reach a tree it measures -- and doing that to the REAL file is the defect itself. So the
# demonstration runs on a scratch tree: a scratch repository, a directory symlink into it, and the same
# two lines this file used to have. What is shown is that the comparison DISCRIMINATES that write; that
# it is pointed at the right file is the check three lines up, against the repository's own bytes.
SCRATCH="$W/scratch"; mkdir -p "$SCRATCH/device" "$SCRATCH/fake"
printf 'the real instrument\n' > "$SCRATCH/device/zl1-thermal.sh"
_s_before=$(sha256sum "$SCRATCH/device/zl1-thermal.sh" | awk '{print $1}')
ln -s "$SCRATCH/device" "$SCRATCH/fake/device"
printf 'a stand-in\n' > "$SCRATCH/fake/device/zl1-thermal.sh"
_s_after=$(sha256sum "$SCRATCH/device/zl1-thermal.sh" | awk '{print $1}')
if [ "$_s_before" != "$_s_after" ]; then
  ok "a write through a directory symlink DOES change the measured file -- so the check above can fail"
else
  bad "the scratch write did not reach the symlinked file, so this demonstration proves nothing"
fi

# ==================================================================================================
echo
echo "== 10. the citation in the health check is checked by the thing it cites =="
# ==================================================================================================
# The health check names this harness WITH a hand-typed count, and docs 110 records one of those going
# stale with nothing to notice. Every harness that page names now checks its own citation; this is that
# check, and it is the reason the count in the page cannot drift away from this run.
HEALTH="$HERE/zl1-health-check.sh"
if [ -r "$HEALTH" ]; then
  cited=$(sed -e 's/always "/ /g' -e 's/"$//' "$HEALTH" | tr '\n' ' ' |
            sed -n 's/.*zl1-heat-fix-chain-selftest\.sh[ ,(]*\([0-9][0-9]*\) checks.*/\1/p')
  total=$((PASS + FAIL + 1))
  if [ -z "$cited" ]; then
    bad "the health check does not cite this harness's count -- either the citation is gone or its wording changed"
  elif [ "$cited" = "$total" ]; then
    ok "the health check cites $cited checks, and this run has exactly that many"
  else
    bad "the health check cites $cited checks, but this harness has $total -- fix host/zl1-health-check.sh"
  fi
else
  bad "cannot read $HEALTH -- its citation is unchecked"
fi

echo
if [ "$KEEP" = 1 ]; then
  echo "kept: $W (the rewritten chain, the stubs, the mutants, the archives)"
else
  rm -rf "$W"
fi
printf 'pass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
exit 0
