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
# The copy under test lives in a fake repo whose scripts/device is a SYMLINK to the real one: the chain
# resolves the proof as $HERE/../device/zl1-address-owner-proof.sh, so a copy in /tmp would refuse for a
# reason that has nothing to do with the chain -- and a symlink keeps "it pushed the REAL proof" true
# rather than replacing it with a stand-in (the harness's own cross-check below depends on that).
# ABSOLUTE, because $HERE is whatever path the harness was invoked with and a relative symlink target is
# resolved against the LINK's directory, not the harness's cwd -- which is how the first version pointed
# at $W/fake-repo/scripts/../device and refused with "cannot read .../host/../device/...".
ln -s "$(cd "$HERE/../device" && pwd)" "$W/fake-repo/scripts/device"

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
*netwatch*) cat "$W/state.txt"; exit 0 ;;
*zl1-address-owner-proof.sh*) cat "$W/proof.txt"; exit "\${FP_RC_PROOF:-0}" ;;
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
exit 0
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
echo "== 6. the licence: a verdict that is not exactly 'proof-obtained' does not kill anything =="
# ==================================================================================================
scen unclear
proof_unclear proof-unclear
run "$S" --yes
[ "$RC" = 1 ] && ok "proof-unclear: exit 1 (a stopped chain, not a crash)" || bad "proof-unclear exited $RC"
notwant 'install-retire-debug-keeper' "$(order)" "the keeper was NOT retired"
notwant 'install-cpufreq-governor' "$(order)" "and the chain stopped there rather than running the next step anyway"
want 'REFUSING TO RETIRE THE KEEPER' "$OUT" "it says so out loud"
want 'still owns the' "$OUT" "and says the keeper still owns the addresses, i.e. the phone is reachable"
want '^01-netwatch-deploy *0' "$(cat "$S/INDEX.txt" 2>/dev/null)" "and it left an archive that says how far it got"

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
