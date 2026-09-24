#!/usr/bin/env bash
# zl1 one-boot runbook -- offline self-test. Host-side, touches no device, needs no phone.
#
# Why this exists. `scripts/host/zl1-one-boot-runbook.sh` is the only script here whose whole content is
# an ORDER: it runs five steps whose sequence is forced (01 must precede 03 because 03 destroys what 01
# reads; 02 and 03 must precede 05 because each arms one of 05's refusals). An order is exactly the kind
# of thing a harness checks well and a human checks badly, so what is asserted here is:
#
#   1. NOTHING RUNS when the device is not there -- and no ssh or scp call is even made. Section 1.
#   2. The five steps run IN THE ONE ORDER, with the arguments each callee's own contract requires.
#      Section 3.
#   3. `--skip` and `--only` select, and an UNKNOWN step name is refused rather than treated as a
#      no-op -- because `--skip 03-heatchain` (a typo) must not silently run the heat chain. Section 4.
#   4. THE TWO DEVICE READINGS ARE READINGS. After 02 the harness changes `download_mode` in the fake
#      device and the note must follow; after 03 it adds a keeper and the note must follow. This is the
#      runbook's whole addition over a hand-typed list, so it is the section that matters most. Section 5.
#   5. `--apply-trial` is refused unless 02 RAN IN THIS INVOCATION (not "was not skipped" -- under
#      `--only 05-trial` nothing armed it either), and when it is allowed, step 05 uses --apply. Section 6.
#   6. A step that fails does not stop the ones after it, and the exit code still reports it. Section 7.
#   7. The archive: an INDEX.txt whose rows are the steps that ran, and a SHA256SUMS that verifies.
#      Section 8.
#   8. An interrupt archives what ran and exits 3. Section 9.
#   9. `--status` WRITES NOTHING -- proven byte-for-byte over a fake device, not by grepping the source.
#      Section 2.
#
# How it works: the same transport discipline as this family's other harnesses -- the stub directory IS
# the device, `lsusb` and `ssh`/`scp` are stubs, and the FOUR CALLEES are recording stand-ins (each has
# its own harness; what is under test here is that they are called, in order, with the right arguments).
# The callee rewrite is checked to have LANDED and is cross-checked against the real tree, so a misspelt
# callee cannot hide behind it.
#
# Usage: zl1-one-boot-runbook-selftest.sh [--keep]
#   --keep   leave the fake root, the stand-ins and the archives in place

set -uo pipefail

for a in "$@"; do
  case "$a" in
  --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; exit 0 ;;
  --keep) ;;
  *) echo "unknown argument $a (try --help)" >&2; exit 2 ;;
  esac
done

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
W=${TMPDIR:-/tmp}/zl1-one-boot-runbook-selftest
KEEP=0
[ "${1:-}" = --keep ] && KEEP=1
rm -rf "$W"; mkdir -p "$W" || exit 2

PASS=0; FAIL=0; SKIPPED=0
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
want()    { case "$2" in *"$1"*) ok "$3" ;; *) bad "$3"; printf '        | wanted to find: %s\n' "$1" ;; esac; }
notwant() { case "$2" in *"$1"*) bad "$3"; printf '        | did not want: %s\n' "$1" ;; *) ok "$3" ;; esac; }

FR="$W/fake"; STUB="$W/stub"; CAL="$W/callees"
mkdir -p "$FR" "$STUB" "$CAL" "$W/out"
# The recording the stubs write into. EXPORTED, because the stubs and the stand-ins are child processes
# and an unexported variable would leave every order assertion searching a file that nothing writes --
# which reads exactly like "the order is wrong".
ACT="$W/act"; export ACT
: > "$ACT"
# Where an outdir-less stand-in archives. NOT the repository root: see the callee stub's fallback.
FALLBACK="$W/fallback"; export FP_FALLBACK_DIR="$FALLBACK"
rm -rf "$FALLBACK"

# --- the fake device ------------------------------------------------------------------------------
# Only the two things the runbook itself reads, plus the two paths the callee stand-ins do not touch:
# the trial runs on the "device", and the ssh stub maps the runbook's device-side commands into here.
printf 'aaaaaaaa-1111-2222-3333-444444444444\n' > "$FR/boot_id"

# A `download_mode` parameter, discovered by GLOB exactly as the runbook discovers it.
#
# The PRIMARY one carries the REAL name, because on 2026-09-24 the device finally said what it is:
# `/sys/module/msm_poweroff/parameters/download_mode = 1`, read twice and archived in this repository
# (tmp-post-recovery-20260923T145530Z/01-edl-postmortem.txt:14 and
# tmp-post-recovery-20260924T013059Z/01-edl-postmortem.txt:13; see docs 125). This fixture used to carry
# a FABRICATED name, on the reasoning that a fixture using the expected name would pass while the glob
# was broken -- which was the right worry, answered the wrong way: a fixture with an invented shape
# cannot show that the reader works on the shape the device actually has, and doc 86's "the real path was
# never seen on a device" stopped being true the moment that capture was taken.
#
# The glob tooth is kept, and made stronger, by a SECOND module directory: the runbook now reads EVERY
# match (the policy unit clears all of them and fails itself if any did not clear), so a decoy is a
# scenario rather than a comment -- with `msm_poweroff` at 0 and the decoy at 1, a reader that stopped at
# the first match reports A MET and a reader hard-coded to one name cannot even see the count.
DM_PRIMARY="$FR/sys/module/msm_poweroff/parameters"
# The decoy sorts AFTER the primary on purpose: the glob expands alphabetically, so a decoy named
# `msm_mpoweroff` (the first name tried here) came FIRST and the scenario could not tell a reader that
# takes the first match apart from one that reads them all -- both would have reported on the same
# parameter, and the mutation proved it by reddening everything except the check it was written for.
# With `qcom_poweroff` the primary is the first match, so "first match only" and "every match" must
# disagree. A fixture that cannot make two behaviours differ is the "tested nothing" shape this tree
# keeps recording.
DM_DECOY="$FR/sys/module/qcom_poweroff/parameters"
mkdir -p "$DM_PRIMARY"
# `dm_set` writes ONLY the primary and takes the decoy away, because "exactly one parameter" is the shape
# the device was measured to have -- so every scenario that does not ask for two runs on the real shape,
# and `reset` gets it for free.
dm_set()   { printf '%s\n' "$1" > "$DM_PRIMARY/download_mode"; rm -rf "$FR/sys/module/qcom_poweroff"; }
dm_decoy() { mkdir -p "$DM_DECOY"; printf '%s\n' "$1" > "$DM_DECOY/download_mode"; }
dm_set 1

keeper_dir="$FR/proc/900"
mkdir -p "$keeper_dir"
keep_on()  { mkdir -p "$keeper_dir"; printf '/bin/sh\0/usr/local/sbin/zl1-debug-net.sh\0' > "$keeper_dir/cmdline"; }
keep_off() { rm -rf "$keeper_dir"; }
keeper_gone() { rm -rf "$FR/proc"; mkdir -p "$FR/proc"; }

# A bystander whose command line merely MENTIONS the keeper path: the runbook matches by ARGV and must
# not count it. This is the same rule every other script here uses, and a substring match is the defect
# it was written to avoid.
mkdir -p "$FR/proc/901"
printf '/usr/bin/grep\0/usr/local/sbin/zl1-debug-net.sh\0' > "$FR/proc/901/cmdline"

# --- the stubs ------------------------------------------------------------------------------------
# lsusb: the FIRST question, and the one that decides whether anything runs. `lsusb -d ID` is a FILTER
# that exits non-zero when nothing matches -- a stub that printed and exited 0 for everything would
# report EDL for a healthy device, which is the false-negative the capture's harness recorded.
cat > "$STUB/lsusb" <<EOF
#!/bin/sh
printf 'lsusb %s\n' "\$*" >> "$ACT"
want_id=; [ "\$1" = -d ] && want_id="\$2"
case "\${FP_STATE:-present}" in
edl)    have_id=05c6:9008; line='Bus 003 Device 020: ID 05c6:9008 Qualcomm, Inc. Gobi Wireless Modem (QDL mode)' ;;
absent) have_id=18d1:4ee7; line='Bus 003 Device 042: ID 18d1:4ee7 Google Inc.' ;;
*)      have_id=18d1:4ee7; line='Bus 003 Device 042: ID 18d1:4ee7 Google Inc.' ;;
esac
if [ -n "\$want_id" ]; then
  [ "\$want_id" = "\$have_id" ] || exit 1
  printf '%s\n' "\$line"; exit 0
fi
printf '%s\n' "\$line"; exit 0
EOF

# The serial directory: the runbook looks for a /sys/bus/usb/devices/*/serial whose value STARTS WITH
# the device's id, because the gadget really reports `33e80afe-v63-usbd-disabled-rndis` and an equality
# test reports "absent" for a phone that is up (the capture's harness records that as a real bug).
serial_on()  { rm -rf "$FR/sys/bus/usb/devices"; mkdir -p "$FR/sys/bus/usb/devices/3-3"; printf '%s\n' "33e80afe-v63-usbd-disabled-rndis" > "$FR/sys/bus/usb/devices/3-3/serial"; }
serial_off() { rm -rf "$FR/sys/bus/usb/devices"; }
serial_other() { rm -rf "$FR/sys/bus/usb/devices"; mkdir -p "$FR/sys/bus/usb/devices/3-4"; printf '%s\n' "4a2fe00b" > "$FR/sys/bus/usb/devices/3-4/serial"; }
serial_on

# A PATH sandbox with the real coreutils and nothing else. The list is deliberately explicit rather than
# inherited: an inherited PATH would let a scenario reach a tool the subject did not ask for, and the
# FIRST version of this list was short by `mkdir` -- which made every run die with "cannot create <outdir>"
# and every scenario look like a refusal. `sh` is here because the stubs are shell, and `tee` because the
# stand-ins record through it.
MINBIN="$W/minbin"; mkdir -p "$MINBIN"
# `timeout` is in this list because the subject BOUNDS every step with it: a sandbox without it would
# silently exercise the other branch (the loud "THIS STEP IS NOT TIME-BOUNDED" note) in every scenario, so
# the bound itself -- and any mutation of it -- would be invisible to this file. The second sandbox below
# exists precisely so that branch is a scenario rather than an accident.
for t in cat sed grep awk tr printf cut sort sha256sum md5sum ls date basename dirname mkdir rm find head tail wc tee sh env uniq timeout; do
  p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$MINBIN/$t"
done
# A REAL sleep, not a no-op: the interrupt scenario kills the run while a step is in flight, and a stub
# that returned instantly would make that kill land after everything had already finished -- a scenario
# that tests the absence of the thing it set up.
printf '%s\n' '#!/bin/sh' "exec $(command -v sleep) \"\$@\"" > "$MINBIN/sleep"; chmod +x "$MINBIN/sleep"
# The same sandbox WITHOUT timeout(1), for the branch that has to SAY it is unbounded: a host without
# timeout(1) is not a refusal, but an unbounded step is a fact the reader of the archive must be told.
MINBIN_NT="$W/minbin-notimeout"; rm -rf "$MINBIN_NT"; mkdir -p "$MINBIN_NT"
for f in "$MINBIN"/*; do b=$(basename "$f"); [ "$b" = timeout ] && continue; ln -sf "$f" "$MINBIN_NT/$b"; done
[ -e "$MINBIN_NT/timeout" ] && { echo "the no-timeout sandbox still has timeout(1)" >&2; exit 2; }

# ssh: the device. It drops the connection options, maps the runbook's device-side absolute paths into
# the fake root, and runs the rest FOR REAL -- so the two readings the runbook turns on are measurements
# of the fixture, and not strings the harness handed it.
: > "$W/paths.sed"
emit() { printf '%s\n' "$1" >> "$W/paths.sed"; }
emit "s#/sys/module/\*/parameters/download_mode#$FR/sys/module/*/parameters/download_mode#g"
emit "s#/proc/\[0-9\]\*#$FR/proc/[0-9]*#g"
emit "s|\${d#/proc/}|\${d#$FR/proc/}|g"
emit "s#/proc/sys/kernel/random/boot_id#$FR/boot_id#g"
# The trial is copied to /tmp and run there. Anchored on the shape this script actually sends, because a
# bare `s#/tmp/#...#g` would re-process the earlier rules' own replacement text (the capture's harness
# records that as a real bug producing a double prefix).
emit "s#sh /tmp/zl1-lpm-ladder-trial.sh#sh $CAL/device/zl1-lpm-ladder-trial.sh#g"

cat > "$STUB/ssh" <<EOF
#!/bin/sh
# Drop the connection options: everything up to the host, then the command.
while [ \$# -gt 0 ]; do
  case "\$1" in
  -o) shift 2 ;;
  -*) shift ;;
  *) break ;;
  esac
done
host="\$1"; shift
cmd="\$*"
printf 'ssh %s\n' "\$cmd" >> "$ACT"
# FP_SSH_HANG_ON: NEVER ANSWER. Not "fail" -- hang, which is the whole point: a stalled link does not
# return a non-zero code, it holds the session open, and every bound this project has added exists for
# that shape and no other. The stub sleeps far longer than any bound a scenario sets, so a call that is
# bounded comes back and one that is not does not.
if [ -n "\${FP_SSH_HANG_ON:-}" ]; then
  case "\$cmd" in *"\$FP_SSH_HANG_ON"*) exec sleep 600 ;; esac
fi
case "\$cmd" in
true) [ "\${FP_SSH_DOWN:-0}" = 1 ] && exit 255; exit 0 ;;
esac
[ "\${FP_SSH_DOWN:-0}" = 1 ] && exit 255
# FP_SSH_DIE_ON: fail only for commands CONTAINING this string. The whole-link failure (FP_SSH_DOWN)
# refuses before any step runs, so it cannot test what happens when the link dies AFTER the steps --
# which is the real case, because the heat chain's activate stage re-enumerates the gadget.
if [ -n "\${FP_SSH_DIE_ON:-}" ]; then
  case "\$cmd" in *"\$FP_SSH_DIE_ON"*) exit 255 ;; esac
fi
mapped=\$(printf '%s\n' "\$cmd" | sed -f "$W/paths.sed")
case "\$mapped" in *"sed:"*) printf 'SSH-MAP-BROKEN: %s\n' "\$mapped"; exit 9 ;; esac
PATH="$MINBIN:\$PATH" exec sh -c "\$mapped"
EOF

cat > "$STUB/scp" <<EOF
#!/bin/sh
while [ \$# -gt 0 ]; do
  case "\$1" in
  -o) shift 2 ;;
  -*) shift ;;
  *) break ;;
  esac
done
src="\$1"
printf 'scp %s\n' "\$src" >> "$ACT"
exit "\${FP_SCP_RC:-0}"
EOF
chmod +x "$STUB"/*

# --- the recording stand-ins -----------------------------------------------------------------------
# Each prints a line saying which script ran and with what arguments (so ORDER and ARGUMENTS are both
# assertable) and exits with a code the scenario chooses. `FP_RC_<NAME>` picks the code.
callee() { # relative path, marker
  mkdir -p "$CAL/$(dirname "$1")"
  cat > "$CAL/$1" <<EOF
#!/bin/sh
printf 'CALLEE $2 args=%s\n' "\$*" | tee -a "$ACT"
[ -n "\${FP_SLEEP_$2:-}" ] && sleep "\${FP_SLEEP_$2}"
rc=\$(printf '%s' "\${FP_RC_$2:-0}"); [ -n "\$rc" ] || rc=0
# Outdir-aware, and it models the REAL scripts instead of a convenient fiction. Only TWO of the five
# make an archive of their own -- the capture and the heat chain -- so only those two are given this
# behaviour; the three installers write device state and archive nothing, and a stand-in that made them
# archive would be inventing a shape the subject cannot be judged against.
case "$2" in CAPTURE|HEAT) marker_files=1 ;; *) marker_files=0 ;; esac
if [ "\$marker_files" = 1 ]; then
  # Given --outdir DIR it archives INTO DIR (what the real chain does: INDEX.txt plus 06b-heat-ab.txt,
  # the A/B reading). Given none it makes a directory of its OWN somewhere else, which is what the chain
  # does when it defaults to \$REPO/tmp-heat-fix-<timestamp>/ -- and that is the shape the subject has to
  # be judged against. The fallback is an env var and NOT \$PWD, because a scenario that leaves an
  # untracked file in the repository makes the FAMILY runner (docs 129) redden for a reason that has
  # nothing to do with this subject.
  out=; want=0
  for a in "\$@"; do
    if [ "\$want" = 1 ]; then out="\$a"; want=0; continue; fi
    [ "\$a" = --outdir ] && want=1
  done
  [ -n "\$out" ] || out="\${FP_FALLBACK_DIR:-/tmp/zl1-rb-fallback}"
  mkdir -p "\$out" 2>/dev/null
  printf 'CALLEE $2 INDEX\n' > "\$out/INDEX.txt"
  printf 'CALLEE $2 ab-reading\n' > "\$out/06b-heat-ab.txt"
fi
printf 'CALLEE $2 rc=%s\n' "\$rc" >> "$ACT"
exit "\$rc"
EOF
  # THE HEAT CHAIN'S STAND-IN CARRIES THE CHAIN'S OWN SHAPE, and that is not decoration: since the
  # runbook checks the whole sequence's host readiness BEFORE step 01, it reads the chain's callees OUT OF
  # THE CHAIN (`NAME="$HERE/..."` plus the `for f in ...` loop the chain refuses on). A stand-in without
  # those lines would leave that extraction empty, the runbook would report its own check as UNUSABLE, and
  # the HARD/SOFT split -- the thing that decides whether a missing file costs the boot -- would be
  # exercised by NOTHING. A fixture that cannot make two behaviours differ tests neither.
  if [ "$2" = HEAT ]; then
    cat >> "$CAL/$1" <<'CHAINSHAPE'
HERE=$(cd "$(dirname "$0")" && pwd)
NW="$HERE/../install-netwatch-service.sh"
RETIRE="$HERE/../install-retire-debug-keeper.sh"
CPUFREQ="$HERE/../install-cpufreq-governor.sh"
PROOF="$HERE/../device/zl1-address-owner-proof.sh"
THERMAL="$HERE/../device/zl1-thermal.sh"
for f in "$NW" "$RETIRE" "$CPUFREQ" "$PROOF"; do
  [ -r "$f" ] || { echo "cannot read $f" >&2; exit 2; }
done
CHAINSHAPE
  fi
  chmod +x "$CAL/$1"
}
callee host/zl1-post-recovery-capture.sh    CAPTURE
callee ../install-no-edl-on-panic.sh        PANIC
callee host/zl1-heat-fix-chain.sh           HEAT
callee ../install-fingerprint-store-dir.sh  FP
callee device/zl1-lpm-ladder-trial.sh       TRIAL

CALLEE_NAMES='CAPTURE|PANIC|HEAT|FP|TRIAL'
order() { grep -E "CALLEE ($CALLEE_NAMES) args=" "$ACT" 2>/dev/null; }
# Every `CALLEE <NAME>` line must be one this file knows how to look for: an unknown marker is a SETUP
# failure, not a silent omission. This is the "extractor that drops an item" shape that doc 120 records
# costing a whole section its sight: a step added to the subject without being added here was invisible
# to every assertion below it.
unknown_markers() {
  sed -n 's/CALLEE \([A-Z0-9]*\) args=.*/\1/p' "$ACT" 2>/dev/null | sort -u | grep -vxE "$CALLEE_NAMES" | tr '\n' ' '
}

# --- step 03's HOST-side preconditions, as a fixture -------------------------------------------------
#
# The runbook now refuses BEFORE step 01 when the heat chain could not start -- its first move is
# `install-netwatch-service.sh --yes --ssh`, which refuses by name unless it has a verified misc backup
# and a build carrying `ensure_addrs()`. Those are files on the HOST, and the subject READS their paths
# out of that installer rather than repeating them (a second copy of a path is a second thing that can
# go stale). So the harness has to provide the installer, and it must provide it with the FORM the reader
# expects (`MISC_IMG="$MISC_OUT/misc.img"`) -- a fixture in a different form would exercise the
# "extraction matched nothing" branch and prove nothing about the READY path.
#
# This is a fixture and not the real installer ON PURPOSE: pointing the subject at the real one would
# make every scenario's verdict a statement about THIS laptop, and the ready/broken branches could not
# both be driven.
NWF="$W/fake-repo/scripts/install-netwatch-service.sh"
mkdir -p "$(dirname "$NWF")"
{
  printf '#!/usr/bin/env bash\n'
  printf '# fixture for the harness: the same three variable FORMS the real installer uses\n'
  printf 'MISC_OUT="%s"\n' "$W/fake-misc"
  printf 'MISC_IMG="$MISC_OUT/misc.img"\n'
  printf 'SRC="%s"\n' "$W/fake-src/zl1-netwatch.sh"
} > "$NWF"
mkdir -p "$W/fake-misc" "$W/fake-src"
host_fixture_ok() { # the state every scenario starts from: a host that CAN run step 03
  rm -rf "$W/fake-misc"; mkdir -p "$W/fake-misc"
  head -c 262144 /dev/zero > "$W/fake-misc/misc.img"
  ( cd "$W/fake-misc" && sha256sum misc.img > SHA256SUMS )
  printf '#!/bin/sh\nensure_addrs() { :; }\n' > "$W/fake-src/zl1-netwatch.sh"
  # The chain stand-in's OWN callees, at exactly the paths its `NAME="$HERE/..."` lines resolve to (it
  # lives in $CAL/host, so `../install-x` is $CAL/install-x and `../device/x` is $CAL/device/x). They
  # exist so the readiness check has something to READ, and so a scenario can take one away -- which is
  # the only way to show the HARD/SOFT split is real.
  chain_callees_ok
}
chain_callees_ok() {
  mkdir -p "$CAL/device"
  for f in install-netwatch-service.sh install-retire-debug-keeper.sh install-cpufreq-governor.sh; do
    [ -r "$CAL/$f" ] || printf '#!/bin/sh\n: chain callee %s\n' "$f" > "$CAL/$f"
  done
  [ -r "$CAL/device/zl1-address-owner-proof.sh" ] \
    || printf '#!/bin/sh\n: the address-ownership proof\n' > "$CAL/device/zl1-address-owner-proof.sh"
  [ -r "$CAL/device/zl1-thermal.sh" ] \
    || printf '#!/bin/sh\n: the thermal instrument\n' > "$CAL/device/zl1-thermal.sh"
  chmod +x "$CAL"/install-*.sh "$CAL/device/"*.sh 2>/dev/null
}
host_fixture_ok

# --- the rewritten subject -------------------------------------------------------------------------
SRC="$HERE/zl1-one-boot-runbook.sh"
RB="$W/fake-repo/scripts/host/zl1-one-boot-runbook.sh"
mkdir -p "$(dirname "$RB")"
sed -e "s#^CAP=\"\$HERE/#CAP=\"$CAL/host/#" \
    -e "s#^PANIC=\"\$HERE/../install-#PANIC=\"$CAL/../install-#" \
    -e "s#^HEAT=\"\$HERE/#HEAT=\"$CAL/host/#" \
    -e "s#^FP=\"\$HERE/../install-#FP=\"$CAL/../install-#" \
    -e "s#^TRIAL=\"\$HERE/../device/#TRIAL=\"$CAL/device/#" \
    -e "s#/sys/bus/usb/devices/#$FR/sys/bus/usb/devices/#g" \
    "$SRC" > "$RB"
chmod +x "$RB"
bash -n "$RB" || { echo "the rewritten subject does not parse" >&2; exit 2; }

# A rewrite that silently did not land would send the subject at the REAL scripts -- i.e. at the real
# installers. So each is asserted, AND cross-checked against the real tree, so a misspelt callee is
# distinguishable from a callee that ran and printed nothing.
for pair in "$CAL/host/zl1-post-recovery-capture.sh:scripts/host/zl1-post-recovery-capture.sh" \
            "$CAL/../install-no-edl-on-panic.sh:scripts/install-no-edl-on-panic.sh" \
            "$CAL/host/zl1-heat-fix-chain.sh:scripts/host/zl1-heat-fix-chain.sh" \
            "$CAL/../install-fingerprint-store-dir.sh:scripts/install-fingerprint-store-dir.sh" \
            "$CAL/device/zl1-lpm-ladder-trial.sh:scripts/device/zl1-lpm-ladder-trial.sh"; do
  pat=${pair%%:*}; rel=${pair##*:}
  grep -qF "$pat" "$RB" || { echo "the rewrite to '$pat' did not land" >&2; exit 2; }
  [ -f "$REPO/$rel" ] || { echo "the callee $rel does not exist in the tree" >&2; exit 2; }
done
# The new precondition fixture is cross-checked the same way: the FORM the reader parses has to be the
# form the real installer writes, or this fixture proves nothing about the real thing.
grep -q '^MISC_IMG="\$MISC_OUT/misc.img"$' "$NWF" || { echo "the fixture's MISC_IMG form changed" >&2; exit 2; }
grep -q '^MISC_IMG="\$MISC_OUT/misc.img"$' "$REPO/scripts/install-netwatch-service.sh" \
  || { echo "the REAL installer no longer writes MISC_IMG in the form the runbook parses -- the reader is now checking nothing" >&2; exit 2; }
grep -q '^MISC_OUT="' "$REPO/scripts/install-netwatch-service.sh" || { echo "the real installer has no MISC_OUT=" >&2; exit 2; }
grep -q '^SRC="'    "$REPO/scripts/install-netwatch-service.sh" || { echo "the real installer has no SRC=" >&2; exit 2; }

# The subject derives its repo root from its own location, so -- rewritten under $W/fake-repo -- its
# archives land there. One helper, because the nested substitutions this replaces were both wrong AND
# unreadable.
OUTROOT="$W/fake-repo"
# `sed -n '1p'` and not `head -1`: this file sets pipefail, and a reader that exits at the first match
# reports the WRITER's death (ls, killed by SIGPIPE) as this function's status. sed reads to EOF.
latest_archive() { ls -dt "$OUTROOT"/tmp-one-boot-* 2>/dev/null | sed -n '1p'; }
# `bash` by ABSOLUTE path: PATH is the sandbox below, which deliberately has no shell in it, so a bare
# `bash` here is 127 -- and 127 from every scenario reads exactly like "the subject refuses everything".
BASH_BIN=$(command -v bash)
run()  { : > "$ACT"; rm -rf "$OUTROOT"/tmp-one-boot-*; OUT=$(env PATH="$STUB:$MINBIN" "$BASH_BIN" "$RB" "$@" 2>&1); RC=$?; }
run_no_timeout() { # the same, on a host whose PATH has no timeout(1)
  : > "$ACT"; rm -rf "$OUTROOT"/tmp-one-boot-*; OUT=$(env PATH="$STUB:$MINBIN_NT" "$BASH_BIN" "$RB" "$@" 2>&1); RC=$?
}
reset() { : > "$ACT"; dm_set 1; keep_on; serial_on; rm -rf "$W/out"; mkdir -p "$W/out"; rm -rf "$FALLBACK"; FP_SSH_HANG_ON=""; }
# A run whose device NEVER ANSWERS, under the harness's OWN hard kill. This is how a bound is tested
# behaviourally rather than by grepping for `timeout`: with the bound the subject returns, without it the
# subject hangs and this `timeout` is what ends the experiment -- and the hang is the observable, because
# a stalled ssh has no exit code to assert on.
HANG_KILL=${HANG_KILL:-15}
run_hang() { # args...
  : > "$ACT"; rm -rf "$OUTROOT"/tmp-one-boot-*
  OUT=$(env PATH="$STUB:$MINBIN" FP_SSH_HANG_ON="${FP_SSH_HANG_ON:-true}" \
        timeout -k 5 "$HANG_KILL" "$BASH_BIN" "$RB" "$@" 2>&1); RC=$?
}

echo "zl1 one-boot runbook -- offline self-test"
echo "  subject: $SRC"
echo "  fake device: $FR"
echo

# ==================================================================================================
echo "== 1. no device, no calls at all =="
# ==================================================================================================
# The device is not there in three different ways, and the promise is the same in all of them: NOTHING
# runs and not one ssh or scp is made. That is asserted against the recording, not against the prose.
reset; FP_STATE=edl FP_SSH_DOWN=1 run --yes
[ "$RC" = 2 ] && ok "an EDL device refuses with exit 2" || bad "it exited $RC"
want 'long-press POWER' "$OUT" "and says the next move is the physical one"
want 'nothing was written' "$OUT" "and that nothing was written"
# The promise is "no ssh and no scp", not "no call at all": the lsusb filter IS how the script knows
# the device is in EDL, so it must be made. An assertion of the stronger claim would have been wrong.
notwant 'ssh ' "$(cat "$ACT")" "and made no ssh call -- the device is not there to be asked"
notwant 'scp ' "$(cat "$ACT")" "and no scp call either"
want 'lsusb -d 05c6:9008' "$(cat "$ACT")" "while the lsusb filter that establishes EDL IS made, because that is the question"

# "absent" needs BOTH: nothing matching the vendor id AND no serial directory. Leaving the serial in
# place is the fixture answering a question the scenario did not ask -- which is how this scenario first
# came out reading "SSH does not answer" instead of "no device".
reset; serial_off; FP_STATE=absent FP_SSH_DOWN=1 run --yes
[ "$RC" = 2 ] && ok "a bus with no zl1 on it refuses with exit 2" || bad "it exited $RC"
want '4a2fe00b' "$OUT" "and names the other phone as the thing to ignore"

# The serial is a PREFIX on the real gadget, so the healthy case must not read as absent. This is the
# false negative the capture's harness records as a real bug (an equality test reported "absent" for a
# phone that was up and answering).
reset; FP_SSH_DOWN=1 run --yes
[ "$RC" = 2 ] && ok "a present-but-unreachable device refuses with exit 2" || bad "it exited $RC"
want 'SSH does not answer' "$OUT" "and distinguishes 'on the bus' from 'not there'"
want 'zl1-rndis-recover.sh' "$OUT" "and points at the HOST-side recovery, because that is where the other failure lives"
notwant 'CALLEE' "$(order)" "and no callee ran"

reset; serial_other; FP_SSH_DOWN=1 run --yes
[ "$RC" = 2 ] && ok "the OTHER phone on the bus (4a2fe00b) still reads as absent" || bad "it exited $RC"
serial_on

# ==================================================================================================
echo
echo "== 2. --status writes NOTHING, and the flag surface refuses what it does not know =="
# ==================================================================================================
# --status is the mode a person runs first, and it reads two files on the device. It writes nothing --
# and that is proven the way this family proves it, byte-for-byte, because a regex over the source
# cannot tell a read from `printf 1 > "$s/download_mode"`.
# The flag is set to 0 HERE, before the snapshot, because the scenario is "the device says 0" -- the
# fixture's default is 1, and a scenario that forgets to move it is testing the baseline rather than the
# reading. (The first version of this section did exactly that: it asserted A is met while reset() had
# just written 1, so the assertion and the fixture disagreed and only the assertion was wrong.)
reset; dm_set 0
BEFORE=$( ( cd "$FR" && find . -printf '%y %p %s\n' | sort && find . -type f -exec md5sum {} + | sort ) )
run --status
[ "$RC" = 0 ] && ok "--status exits 0 on a reachable device" || bad "it exited $RC"
want 'prerequisite A is MET' "$OUT" "it reads download_mode and reports A as met when the device says 0"
AFTER=$( ( cd "$FR" && find . -printf '%y %p %s\n' | sort && find . -type f -exec md5sum {} + | sort ) )
[ "$BEFORE" = "$AFTER" ] && ok "and the fake device is byte-for-byte what it was" || bad "--status changed the fake device"
notwant 'CALLEE' "$(order)" "and no callee ran in --status"
# The reading must FOLLOW the device, not the fixture's default: with the flag at 1 the same mode must
# say A is not met. This is the same discipline as section 5, applied to the read-only mode.
dm_set 1
run --status
want 'A is NOT met' "$OUT" "and with the flag back at 1 it says A is not met -- the note follows the device"

run --not-a-flag
[ "$RC" = 2 ] && ok "an unknown argument exits 2" || bad "it exited $RC"
want 'unknown argument' "$OUT" "and says which one it did not understand"
run --yes --only 99-nope
[ "$RC" = 2 ] && ok "an unknown STEP name exits 2 rather than running nothing" || bad "it exited $RC"
want 'unknown step' "$OUT" "and lists the steps it does know"
run --yes --skip 03-heatchain
[ "$RC" = 2 ] && ok "a TYPO in a step name is refused, not treated as a no-op" || bad "it exited $RC"
want 'unknown step' "$OUT" "so a mistyped --skip cannot silently run the step it meant to leave out"

# ==================================================================================================
echo
echo "== 3. the five steps, in the one order =="
# ==================================================================================================
reset; run --yes
want 'CALLEE CAPTURE args=--outdir' "$(order | sed -n '1p')" "step 01 runs FIRST, and the capture is told where to archive"
want 'CALLEE PANIC args=--install' "$(order | sed -n '2p')" "then the panic guard, installed"
want 'CALLEE HEAT args=--yes --outdir' "$(order | sed -n '3p')" "then the heat chain, in its --yes mode, and TOLD WHERE TO ARCHIVE"
want 'CALLEE FP args=--install' "$(order | sed -n '4p')" "then the fingerprint store directory"
want 'CALLEE TRIAL args=--status' "$(order | sed -n '5p')" "and LAST the trial, READ-ONLY by default"
[ "$(order | wc -l)" = 5 ] && ok "exactly five steps -- no step runs twice and none is smuggled in" || bad "$(order | wc -l) callee call(s) ran"
[ "$RC" = 0 ] && ok "and the run exits 0" || bad "it exited $RC"
# The capture archives INSIDE ours, so its INDEX.txt is not overwritten by ours -- two records of the
# same boot. A shared outdir would silently lose one of them.
want '--outdir' "$(order | sed -n '1p')" "the capture is given an outdir rather than sharing ours by accident"
OD1=$(latest_archive)
want 'capture/' "$(cat "$OD1/INDEX.txt" 2>/dev/null)" "and the capture's own archive is named as living inside ours"
# The heat chain's archive, which is the ONE thing this script must not get wrong about step 03: the chain
# takes an A/B measurement around the two fixes and writes it to `06b-heat-ab.txt` inside its OWN archive,
# and left alone it puts that archive at `$REPO/tmp-heat-fix-<timestamp>/` -- a second directory for the
# same boot, BESIDE this one, covered by .gitignore's `tmp-*/`, named by nothing in this INDEX. On a boot
# that cannot be re-run, the reading landing where the boot's own record does not point is the "found
# late" failure this whole script exists to prevent. So the assertion is two-sided: the reading IS inside
# the boot's archive, and it is NOT in the directory the chain would have chosen by itself.
[ -f "$OD1/03-heat-chain/06b-heat-ab.txt" ] \
  && ok "step 03's own archive -- including the A/B reading -- lands INSIDE this boot's archive" \
  || bad "03-heat-chain/06b-heat-ab.txt is not inside $OD1: the measurement is beside the archive, not in it"
[ -f "$OD1/03-heat-chain/INDEX.txt" ] && ok "with the chain's own INDEX.txt beside it, so two records of the same boot survive" \
  || bad "the chain's own INDEX.txt is not inside the boot's archive"
want '03-heat-chain/' "$(cat "$OD1/INDEX.txt" 2>/dev/null)" "and the boot's INDEX names that directory, so a reader following it finds the reading"
[ ! -f "$FALLBACK/06b-heat-ab.txt" ] \
  && ok "and NOTHING was archived into the directory an outdir-less step would have made for itself" \
  || bad "a step archived outside the boot's own archive, into $FALLBACK"
# The subject's own plan list and its execution order are checked against EACH OTHER by the subject, and
# that check is asserted here because it is the only thing standing between "the order is enforced" and
# "the order is a comment". A mutation that swaps two entries of STEPS changes nothing about what runs --
# which is exactly why it produced ZERO failures before the subject grew this check.
notwant 'THE PLAN AND THE RUN DISAGREE' "$OUT" "and the declared order and the executed order agree in the subject"
unknown_markers >/dev/null 2>&1
[ -z "$(unknown_markers)" ] && ok "every stand-in that ran is one this harness knows how to look for" \
  || bad "the subject ran a step this harness cannot see: $(unknown_markers)"
# --settle is passed through, because the heat chain's default (90 s) is the gap the netwatch needs and
# this script must not quietly shorten it.
reset; run --yes --settle 12
want 'CALLEE HEAT args=--yes --settle 12 --outdir' "$(order | sed -n '3p')" "--settle reaches the heat chain unchanged, and the outdir is not lost when --settle is given"

# ==================================================================================================
echo
echo "== 4. --skip and --only select, and the archive records it =="
# ==================================================================================================
reset; run --yes --skip 03-heat-chain
want 'CALLEE CAPTURE' "$(order | sed -n '1p')" "with 03 skipped, 01 still runs"
want 'CALLEE PANIC'  "$(order | sed -n '2p')" "then 02"
want 'CALLEE FP'     "$(order | sed -n '3p')" "and the step after the skipped one runs -- a skip is not a stop"
notwant 'CALLEE HEAT' "$(order)" "while the skipped step does not run"
OD2=$(latest_archive)
want '03-heat-chain' "$(cat "$OD2/INDEX.txt" 2>/dev/null)" "and the INDEX records the step rather than omitting it"
want 'skip' "$(cat "$OD2/INDEX.txt" 2>/dev/null)" "with its status as skipped -- an absent row would read as 'not in the plan'"
reset; run --yes --only 04-fingerprint
[ "$(order | wc -l)" = 1 ] && ok "--only runs exactly the one step" || bad "$(order | wc -l) step(s) ran"
want 'CALLEE FP args=--install' "$(order)" "and it is the one that was asked for"

# ==================================================================================================
echo
echo "== 5. the two device readings are READINGS, and they follow the device =="
# ==================================================================================================
# This is the whole addition over a hand-typed list: after the step that is supposed to move a knob, the
# runbook re-reads that knob FROM THE DEVICE and says whether the LAST step's precondition is now true.
# A check whose answer the scenario cannot change is not a check, so both are moved here.
reset; dm_set 0; run --yes
want 'prerequisite A is MET' "$OUT" "with download_mode 0 the run reports A as met"
reset; dm_set 1; run --yes
want 'A is NOT met' "$OUT" "with download_mode 1 the SAME run reports A as not met -- the note is a reading"
want 'the cause is 02 or the driver' "$OUT" "and it attributes the failure to the step that should have moved it"
reset; keeper_gone; run --yes
want 'prerequisite C is MET' "$OUT" "with no keeper in /proc the run reports C as met"
reset; keep_on; run --yes
want 'C is NOT met' "$OUT" "with the keeper running it reports C as not met"
want 'the cause is 03' "$OUT" "and attributes it to the heat chain, not to the trial"

# A is a reading of EVERY `download_mode` parameter, and not of the first one seen. The policy unit that
# arms A loops the same glob and FAILS ITSELF if any parameter did not clear, so a reader that stopped at
# the first match answers a question about a different knob than the writer touches: it can print A MET on
# a boot where the unit itself reports the guard is NOT armed. The device has exactly one parameter today
# (measured, docs 125), which is why this needs a scenario rather than a memory.
reset; dm_set 0; dm_decoy 1; run --yes
want 'A is NOT met' "$OUT" "with a SECOND download_mode parameter at 1, A is not met even though the first reads 0"
want 'qcom_poweroff' "$OUT" "and the report names the parameter that is armed, rather than only the one it read first"
reset; dm_set 0; dm_decoy 0; run --yes
want 'prerequisite A is MET' "$OUT" "with BOTH parameters at 0 it is met"
want 'all=0 (2 parameter(s))' "$OUT" "and the reading says how many it looked at -- a count a hard-coded single path could not produce"
reset; dm_set 0; run --status
want 'all=0 (1 parameter(s))' "$OUT" "and on the device's real shape -- one parameter -- --status says so"
# Both readings must be UNREADABLE rather than a value when the link dies -- because the heat chain's own
# activate stage re-enumerates the gadget, so the first ssh after it can fail, and a value invented there
# would be the worst possible answer.
# The link dying AFTER the steps is the real case (the heat chain's activate stage re-enumerates the
# gadget), so the stub fails only the reading commands. A reading that came back as a value here would be
# the worst possible answer: it would be invented.
reset; FP_SSH_DIE_ON=download_mode run --yes
want 'UNREADABLE' "$OUT" "when the link dies after the steps, the readings say UNREADABLE and not a value"
want 'A: UNREADABLE' "$OUT" "for A specifically"
reset; FP_SSH_DIE_ON=cmdline run --yes
want 'C: UNREADABLE' "$OUT" "and the same for C when it is the keeper read that fails"

# ==================================================================================================
echo
echo "== 6. --apply-trial is a separate decision, and it is refused when 02 did not run =="
# ==================================================================================================
# The trial writes to the SoC's power parameter. The panic guard is what makes a hang a reboot instead
# of an EDL trip, so applying the trial without having armed it is the one combination this script
# refuses on its own account -- and the check is "did 02 RUN", not "was 02 not skipped": under
# `--only 05-trial` nothing armed it either.
reset; run --yes --skip 02-panic-guard --apply-trial
[ "$RC" = 1 ] && ok "skipping the panic guard and applying the trial exits 1" || bad "it exited $RC"
want 'REFUSED: --apply-trial was given, but 02-panic-guard did not run' "$OUT" "and says why, in those terms"
want 'read it first' "$OUT" "and names the alternative: read it first rather than write it"
notwant 'CALLEE TRIAL args=--apply' "$(order)" "and the trial was NOT run in its writing mode"
reset; run --yes --only 05-trial --apply-trial
[ "$RC" = 1 ] && ok "the same refusal fires under --only 05-trial, where 02 was neither skipped nor run" || bad "it exited $RC"
want 'did not run in this invocation' "$OUT" "because the question is whether it RAN, not whether it was skipped"
reset; run --yes --apply-trial
want 'CALLEE TRIAL args=--apply' "$(order | sed -n '5p')" "with 02 having run, the trial gets --apply"
notwant 'CALLEE TRIAL args=--status' "$(order)" "and not --status"
# A verdict of REFUTED is a measurement, so the trial's own 0 must not be reported as a failure.
reset; FP_RC_TRIAL=0 run --yes --apply-trial
want 'REFUTED would also be 0' "$OUT" "and its own 0 is called a measurement, not a pass"
reset; FP_RC_TRIAL=1 run --yes
want 'INCONCLUSIVE or CONFOUNDED' "$OUT" "while its 1 is called a statement about the run, not the phone"
reset; FP_RC_TRIAL=3 run --yes
want 'REFUSED' "$OUT" "and its 3 is reported as a refusal with nothing written"

# ==================================================================================================
echo
echo "== 7. a step that fails does not stop the ones after it, and the exit code says so =="
# ==================================================================================================
reset; FP_RC_HEAT=1 run --yes
[ "$RC" = 1 ] && ok "a step that stops short makes the run exit 1" || bad "it exited $RC"
want 'CALLEE FP args=--install' "$(order | sed -n '4p')" "and the NEXT step still runs -- the same rule the capture follows"
want 'CALLEE TRIAL' "$(order | sed -n '5p')" "and so does the last one"
want 'stopped short' "$OUT" "and the human-facing line says the run stopped short"
# A step that failed BEFORE the two readings must not turn them into invented values.
reset; FP_RC_PANIC=90 run --yes
want 'A is NOT met' "$OUT" "a failed panic-guard install leaves A unmet, read from the device rather than assumed"

# ==================================================================================================
echo
echo "== 7b. a step that outlasts --step-limit: its own state, and the run goes ON =="
# ==================================================================================================
# Every step here is one or more ssh calls on a link the heat chain re-enumerates ON PURPOSE, and a hung
# ssh does not fail -- it hangs. The boot that pays for it cost a physical 10-20 s power hold, so the
# bound is the difference between "the boot is spent" and "the boot is spent and says where".
#
# AND THE RUN GOES ON. That is the deliberate difference from the heat chain (docs 131), whose steps are a
# LICENCE CHAIN and stop it: the five steps here are independent readings, so a step that did not finish
# must not cost the four that have nothing to do with it -- the same rule section 7 asserts for a step
# that FAILS. What must not happen is that anybody reads it as one of those two things.
reset
FP_SLEEP_FP=5 run --yes --step-limit 2
[ "$RC" = 1 ] && ok "a step that did not finish: exit 1 (the run did not complete)" || bad "it exited $RC"
want 'DID NOT FINISH: killed at 2s (rc=124, timeout(1))' "$OUT" "the host-side reason is named, with the bound and the code"
want 'This is NOT a failure of the' "$OUT" "and it is explicitly NOT filed as a failure of the step"
want 'NOT a success' "$OUT" "nor as a success -- the device state after it is unread, and that is said"
want 'CALLEE TRIAL' "$(order | sed -n '5p')" "and the LAST step still ran: a step that ran out of time does not cost the others"
OD7=$(latest_archive)
# The two ROWS are read with grep -E and not with `want`: this harness's `want` is a GLOB match (see its
# definition), where an anchored pattern is the literal `^` and the check would pass for the wrong reason.
# Written that way first, run, and caught here -- which is the whole reason the patterns are pinned.
grep -qE '^04-fingerprint +124' "$OD7/INDEX.txt" 2>/dev/null \
  && ok "the archive carries timeout(1)'s code, not a code the step chose" \
  || bad "the INDEX does not record 124 for 04-fingerprint"
grep -qE '^01-capture +0' "$OD7/INDEX.txt" 2>/dev/null \
  && ok "the steps that DID run are still recorded as having run" \
  || bad "the INDEX lost the rows of the steps that ran"
want 'DID NOT FINISH' "$(cat "$OD7/INDEX.txt" 2>/dev/null)" "and one line explains what that code means, because a bare 124 reads as 'the step said 124'"
want 'DID NOT FINISH: the host gave up at 2s' "$(cat "$OD7/INDEX.txt" 2>/dev/null)" "the row's own note says which bound was hit, so the next reader does not have to infer it"
want 'Neither a failure of the step nor a success' "$(cat "$OD7/INDEX.txt" 2>/dev/null)" "with the same sentence the reader needs, in the record itself"
want '1 did not finish' "$OUT" "and the totals count it apart from the failures"
want 'one-boot runbook did not complete: 4 step(s) ran, 0 failed, 1 did not finish' "$OUT" \
  "the exact line: four of the five ran, none FAILED, one did not finish -- the same step must not be counted as both"
( cd "$OD7" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ) && ok "and the archive still verifies" || bad "the archive fails its own sha256sum -c"

echo
echo "   -- on a host with no timeout(1), an unbounded step SAYS SO:"
# Not a refusal -- the run is still worth doing -- but "the step could have hung forever and nobody would
# know" is exactly the fact the archive has to carry, and a silent fallback would be the "instrument that
# cannot report" defect in the one place it costs a boot. The note goes into the STEP's own file, because
# that is where somebody reading about this step will be.
reset
run_no_timeout --yes
[ "$RC" = 0 ] && ok "a host without timeout(1) still runs the whole sequence" || bad "it exited $RC"
OD7b=$(latest_archive)
want 'THIS STEP IS NOT TIME-BOUNDED' "$(cat "$OD7b/02-panic-guard.txt" 2>/dev/null)" "and the step's own file says the bound was not applied"
want 'the limit would have been 900s' "$(cat "$OD7b/02-panic-guard.txt" 2>/dev/null)" "naming the bound that would have applied, not merely being silent"

# ==================================================================================================
echo
echo "== 7c. the ssh calls that are NOT steps are bounded too, and they say so =="
# ==================================================================================================
# A bound on the STEPS is defeated by an unbounded call between them. This runbook makes four of those:
# the reachability probe, the boot-id read, and the two readings that decide A and C. And they are worse
# than the steps were, because their output does not go to a file -- it goes into a `case` that turns it
# into a VERDICT ABOUT THE PHONE. A host-side timeout arriving there as an empty string was printed as
# "A is treated as NOT met" and "C is NOT met (step 03 retires it)", i.e. an instruction to re-run a step
# that may have already worked, on the strength of a reading that never happened.
#
# The scenarios therefore HANG the device rather than failing it (FP_SSH_HANG_ON in the ssh stub): a
# stalled link does not return a non-zero code, it holds the session open, and a hang is the only shape
# these bounds exist for. The harness's own `timeout` is what turns "did not come back" into a reading.
echo
echo "   -- a link that never answers, at the very first call:"
reset; FP_SSH_HANG_ON=true
run_hang --yes --state-limit 2
FP_SSH_HANG_ON=""
[ "$RC" = 2 ] && ok "the run COMES BACK (exit 2) instead of hanging -- the bound is doing the work" \
               || bad "it exited $RC; 124 means it hung and the harness had to kill it"
want 'IT DID NOT ANSWER WITHIN 2s' "$OUT" "and it says the host's own bound is what ended it"
want 'a statement about THIS HOST, not about the phone' "$OUT" "explicitly not a claim about the device"
want 'zl1-rndis-recover.sh' "$OUT" "and it names the repair that needs no key press -- a stalled link is not a dead phone"
notwant 'CALLEE' "$(order)" "nothing was run, so nothing was written"

echo
echo "   -- the same hang later, at a reading whose answer becomes a verdict:"
# The probe and the boot-id read answer; the download_mode read never does. `--status` is the read-only
# mode, and it is the one a person runs first -- so the hang lands on the line that decides A.
reset; FP_SSH_HANG_ON=download_mode
run_hang --status --state-limit 2
FP_SSH_HANG_ON=""
[ "$RC" = 0 ] && ok "--status still answers (exit 0) rather than hanging" || bad "it exited $RC (124 = it hung)"
want 'A. download_mode: NOT READ' "$OUT" "and A is reported as NOT READ, which is a fact about the host"
want 'the host gave up on the ssh at 2s' "$OUT" "naming the bound that was hit"
notwant 'A is treated as NOT met' "$OUT" "NOT as 'the reading is not a shape this script knows' -- the empty-string fall-through it used to land in"
notwant 'a panic WOULD arm EDL' "$OUT" "and certainly not as an ARMED reading, which would be invented"

echo
echo "   -- and the keeper reading, where the wrong branch is the dangerous one:"
# `none*` is the only branch that says C is MET, so anything else says C is NOT met -- including, before
# this, a host-side timeout. That reads as "step 03 did not work", and the move it invites is re-running
# step 03 on a boot where it may have worked perfectly.
reset; FP_SSH_HANG_ON=cmdline
run_hang --status --state-limit 2
FP_SSH_HANG_ON=""
[ "$RC" = 0 ] && ok "--status comes back" || bad "it exited $RC (124 = it hung)"
want 'C. debug keeper: NOT READ' "$OUT" "C is reported as NOT READ"
want 'may well have worked' "$OUT" "and it says so, instead of telling the operator to re-run step 03"
notwant 'C is NOT met' "$OUT" "so the dangerous branch -- 'step 03 did not work' -- is not taken on a non-reading"

echo
echo "   -- with --yes, the reading after the steps says the same thing, in the archive:"
reset; FP_SSH_HANG_ON=download_mode
run_hang --yes --state-limit 2
FP_SSH_HANG_ON=""
[ "$RC" = 0 ] && ok "the sequence still completes" || bad "it exited $RC"
want 'A: NOT READ' "$OUT" "the post-step note says NOT READ, not UNREADABLE-with-a-value-shaped-claim"
want 'a fact about this machine and NOT a reading' "$OUT" "with the distinction said out loud"
want 'boot_id: aaaaaaaa-1111' "$(cat "$(latest_archive)/INDEX.txt" 2>/dev/null)" "and the boot-id read (which answered) is in the archive as its real value"
# The other side of that pair: when the FIRST call is what hangs, the archive still carries a boot id
# line -- and it must say the read did not happen rather than print a plausible-looking substitute. The
# old fallback was `unknown-<timestamp>`, which reads as an id nobody could ever match.
reset; FP_SSH_HANG_ON=true
run_hang --yes --state-limit 2
FP_SSH_HANG_ON=""
OD7c=$(latest_archive)
[ -z "$OD7c" ] && ok "a run that never reached a step wrote no archive at all (there was nothing to record)" \
              || bad "it left an archive at $OD7c"
notwant 'unknown-20' "$OUT" "and nowhere does it print an 'unknown-<timestamp>' as if it were a boot id"

echo
echo "   -- and the invariant is pinned, so a new call site cannot appear unbounded:"
# The scenarios above are BEHAVIOURAL -- they hang the device and see whether the run comes back. This is
# the static half, and it is here because behaviour can only show a path that a scenario happens to take:
# a fifth direct ssh call added next year would not be covered by anything above unless a scenario drove
# it. So the ARRAY ITSELF is the thing constrained: `${SSH[@]}` may appear in exactly two places -- the
# definition of `devssh`, which bounds it, and the one call that hands it to `run_bg`, which also bounds
# it. The count is asserted rather than the list, so an added occurrence is a red and not a silent pass.
# (This is doc 131 section 6's "the other harnesses were hand-scanned, and that is not a mechanism",
# one file over: the scan is now a check that runs every time this harness does.)
SSHSITES=$(grep -n '\${SSH\[@\]}' "$SRC" 2>/dev/null)
NSITES=$(printf '%s\n' "$SSHSITES" | grep -c . )
[ "$NSITES" = 2 ] && ok "the subject uses \${SSH[@]} in exactly 2 places, both of them bounded" \
                  || bad "\${SSH[@]} appears $NSITES times in the shipped runbook -- a new direct call site must be routed through devssh"
want 'devssh() { bound "$STATE_LIMIT" "${SSH[@]}" "$@"; }' "$SSHSITES" "one is devssh, which bounds it"
want 'run_bg "${SSH[@]}"' "$SSHSITES" "the other is handed to run_bg, which bounds it too"
# And the same fact the other way round, which is the one that actually protects: REMOVE the two bounded
# occurrences and NOTHING may be left. A count alone would pass on a file where the count is right and the
# lines are different; here the survivor set has to be empty, and it is compared with grep -E rather than
# with this harness's glob-matching `want` (an anchored or bracketed pattern there matches as a glob).
LEFT=$(grep -n '\${SSH\[@\]}' "$SRC" 2>/dev/null | grep -vE 'devssh\(\)|run_bg "\$\{SSH' || true)
[ -z "$LEFT" ] && ok "and with those two removed, no \${SSH[@]} call site is left unbounded" \
              || { bad "these \${SSH[@]} uses are neither devssh nor run_bg -- route them through devssh:"; printf '%s\n' "$LEFT" | sed 's/^/        | /'; }

# ==================================================================================================
echo
echo "== 8. the archive: an index of what ran, and checksums that verify =="
# ==================================================================================================
reset; run --yes >/dev/null
OD=$(latest_archive)
[ -n "$OD" ] && ok "the run archived into $OD" || bad "no archive directory was created"
[ -f "$OD/INDEX.txt" ] && ok "with an INDEX.txt" || bad "no INDEX.txt"
want '01-capture' "$(cat "$OD/INDEX.txt" 2>/dev/null)" "naming the first step"
want '05-trial' "$(cat "$OD/INDEX.txt" 2>/dev/null)" "and the last one"
want 'boot_id: ' "$(cat "$OD/INDEX.txt" 2>/dev/null)" "and the boot it belongs to, because that is the whole point of the directory"
n=0; for f in 01-capture 02-panic-guard 03-heat-chain 04-fingerprint 05-trial; do [ -f "$OD/$f.txt" ] && n=$((n + 1)); done
[ "$n" = 5 ] && ok "and one file per step" || bad "only $n of 5 step files exist"
( cd "$OD" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ) && ok "and the SHA256SUMS verifies" || bad "sha256sum -c failed"
# The archive is written by a function that is ALSO the signal handler, so a second call must be a
# no-op rather than a rewrite -- otherwise a late signal could truncate a good index.
want '01 and 05 read' "$(cat "$OD/INDEX.txt" 2>/dev/null)" "and it says which steps read and which write"

# ==================================================================================================
echo
echo "== 9. an interrupt archives what ran and exits 3 =="
# ==================================================================================================
# The first real run of its sibling was killed with the steps on disk and no index at all. Same handler,
# same promise, and the interesting half is that the archive is COMPLETE enough to verify.
reset; rm -rf "$OUTROOT"/tmp-one-boot-*
env PATH="$STUB:$MINBIN" FP_SLEEP_HEAT=8 "$BASH_BIN" "$RB" --yes > "$W/int.out" 2>&1 &
RP=$!
sleep 2
kill -TERM "$RP" 2>/dev/null
wait "$RP"; RC=$?
OUT="$W/int.out"
[ "$RC" = 3 ] && ok "an interrupt exits 3, a code of its own" || bad "it exited $RC"
OD3=$(latest_archive)
[ -f "$OD3/INDEX.txt" ] && ok "and it archived what had run" || bad "no INDEX.txt after the interrupt"
want 'INTERRUPTED' "$(cat "$OD3/INDEX.txt" 2>/dev/null)" "and the index says so"
( cd "$OD3" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ) \
  && ok "and the partial archive verifies -- a handler that writes into a step's file breaks this" \
  || bad "the partial archive fails its own sha256sum -c"

# ==================================================================================================
echo
echo "== 9b. the HOST's own precondition: a broken host refuses BEFORE step 01 =="
# ==================================================================================================
# Why this section exists: a refusal at step 03 costs the two steps before it, and the boot is the one
# thing here that cannot be re-run. So the check belongs before 01, and it has to be provable in BOTH
# directions -- a host that can run step 03 must proceed, and a host that cannot must refuse with NO
# callee having run at all.
host_fixture_ok
run --status
want "every step this run would take can start from this machine" "$OUT" \
  "--status: with a good host it says so, about the WHOLE sequence and not just step 03"
run --yes
want "host check: every step this run takes can start from this machine" "$OUT" \
  "and the run prints the same line before step 01"
want 'CALLEE CAPTURE' "$(cat "$ACT")" "with a good host the sequence still runs"

echo
echo "   -- the misc backup is gone:"
host_fixture_ok; rm -f "$W/fake-misc/misc.img"
run --status
want "the run WILL REFUSE before step 01" "$OUT" "--status reports it as a refusal, before anything is run"
run --yes
[ "$RC" = 2 ] && ok "the run exits 2" || bad "the run exited $RC"
want 'REFUSING, before anything ran' "$OUT" "and it says so before step 01"
want 'the misc backup step 03 requires is missing or empty' "$OUT" "naming the file it looked for"
want "$W/fake-misc/misc.img" "$OUT" "by its full path"
[ -z "$(order)" ] && ok "and NO step ran at all" || { bad "a step ran anyway: $(order)"; }
notwant 'CALLEE' "$(cat "$ACT")" "the device was not asked to do anything"
# What IS true about the archive: the outdir is created before the check (so the boot_id is on record),
# and it must hold no INDEX -- a directory with no index is "the run stopped before step 01", which is
# exactly the claim, and asserting the stronger "nothing was created" would be asserting something false.
arc=$(latest_archive)
[ -n "$arc" ] && [ ! -f "$arc/INDEX.txt" ] && ok "and the archive has no INDEX.txt -- the run stopped before step 01" \
  || bad "the archive looks like a completed run: ${arc:-<none>}"

echo
echo "   -- the backup is there but is not the image it claims to be:"
host_fixture_ok
printf 'not the same bytes\n' >> "$W/fake-misc/misc.img"
run --yes
[ "$RC" = 2 ] && ok "a backup that fails its own SHA256 is a refusal, not a warning" || bad "it exited $RC"
want 'FAILS its recorded SHA256' "$OUT" "and the reason is the hash, not the file's existence"
[ -z "$(order)" ] && ok "and again no step ran" || bad "a step ran: $(order)"

echo
echo "   -- the build step 03 would deploy has no ensure_addrs():"
host_fixture_ok
printf '#!/bin/sh\nnothing_useful() { :; }\n' > "$W/fake-src/zl1-netwatch.sh"
run --yes
[ "$RC" = 2 ] && ok "a build that cannot configure the addresses is a refusal" || bad "it exited $RC"
want 'has no ensure_addrs()' "$OUT" "and it says which property of the file is missing"
[ -z "$(order)" ] && ok "and no step ran" || bad "a step ran: $(order)"

echo
echo "   -- skipping 03 must still be possible on a broken host (it is a host problem, not a device one):"
host_fixture_ok; rm -f "$W/fake-misc/misc.img"
run --yes --skip 03-heat-chain
[ "$RC" != 2 ] && ok "with 03 skipped the run is not refused (exit $RC)" || bad "it refused even though 03 was skipped"
notwant 'REFUSING, before anything ran' "$OUT" "and it does not print the refusal"
want 'CALLEE CAPTURE' "$(cat "$ACT")" "the other steps run"

echo
echo "   -- the reader reads the INSTALLER, so a form it does not know is reported, never passed:"
host_fixture_ok
printf 'MISC_OUT="%s"\nMISC_IMG="${MISC_OUT}/misc.img"\nSRC="%s"\n' "$W/fake-misc" "$W/fake-src/zl1-netwatch.sh" > "$NWF"
run --yes
[ "$RC" = 2 ] && ok "a MISC_IMG form the reader does not parse is a refusal" || bad "it exited $RC -- an unparsed path was treated as a pass"
want 'the MISC_OUT/MISC_IMG form it uses is not the one this reads' "$OUT" "and the message says the extraction is what failed, not the backup"
[ -z "$(order)" ] && ok "and no step ran" || bad "a step ran: $(order)"
# restore the form the reader knows, so nothing after this section inherits the odd one
{
  printf '#!/usr/bin/env bash\n'
  printf 'MISC_OUT="%s"\n' "$W/fake-misc"
  printf 'MISC_IMG="$MISC_OUT/misc.img"\n'
  printf 'SRC="%s"\n' "$W/fake-src/zl1-netwatch.sh"
} > "$NWF"
host_fixture_ok

# ==================================================================================================
echo
echo "== 9c. the WHOLE sequence's host readiness, and the two kinds of missing =="
# ==================================================================================================
# Section 9b proves the one check that existed (step 03's installer-read preconditions). This section is
# the generalisation: every step's own script, AND step 03's own callees, are files on THIS machine, and
# discovering one missing costs the boot a finger bought. Two properties matter more than the enumeration:
#
#   * A MISSING SCRIPT IS A REFUSAL, A MISSING INSTRUMENT IS A WARNING. Refusing because the thermal
#     instrument is absent would throw away the whole heat fix -- two installers that would have worked
#     and the keeper kill -- to protect a smaller loss than the refusal causes. So the split is asserted
#     from BOTH sides, and the mutation is the interesting direction: make the instrument a refusal and
#     the boot is lost to it.
#   * A STEP THIS RUN WILL NOT TAKE CANNOT FAIL. `--skip` / `--only` must keep working on exactly the
#     host where they are the way through, so a missing script for a skipped step must not refuse.
host_fixture_ok

echo
echo "   -- a step's OWN script is gone:"
TRIAL_BAK="$W/trial.bak"; cp "$CAL/device/zl1-lpm-ladder-trial.sh" "$TRIAL_BAK"
rm -f "$CAL/device/zl1-lpm-ladder-trial.sh"
run --yes
[ "$RC" = 2 ] && ok "the run refuses before step 01 (exit 2)" || bad "it exited $RC"
want '05-trial cannot start: its own script is not readable' "$OUT" "naming the step and what is missing"
want 'REFUSING, before anything ran' "$OUT" "as a refusal, not a warning"
[ -z "$(order)" ] && ok "and NO step ran -- not even the four whose scripts are fine" || bad "a step ran: $(order)"
run --status
want 'the run WILL REFUSE before step 01' "$OUT" "--status says the same, so the read-only check is the whole answer"
cp "$TRIAL_BAK" "$CAL/device/zl1-lpm-ladder-trial.sh"; chmod +x "$CAL/device/zl1-lpm-ladder-trial.sh"

echo
echo "   -- a step that will NOT be taken cannot fail:"
rm -f "$CAL/device/zl1-lpm-ladder-trial.sh"
run --yes --skip 05-trial
[ "$RC" != 2 ] && ok "--skip 05-trial is still the way through (exit $RC)" || bad "it refused on a step it was told to skip"
notwant 'REFUSING, before anything ran' "$OUT" "and it does not claim the host is broken"
want 'CALLEE CAPTURE' "$(cat "$ACT")" "while the steps that DO run still run"
run --yes --only 01-capture
[ "$RC" != 2 ] && ok "--only 01-capture likewise (exit $RC)" || bad "it exited $RC"
notwant '05-trial cannot start' "$OUT" "and the untaken step is not named as broken"
cp "$TRIAL_BAK" "$CAL/device/zl1-lpm-ladder-trial.sh"; chmod +x "$CAL/device/zl1-lpm-ladder-trial.sh"
host_fixture_ok

echo
echo "   -- a script STEP 03'S OWN BODY drives is gone, which the runbook never used to look at:"
RETIRE_BAK="$W/retire.bak"; cp "$CAL/install-retire-debug-keeper.sh" "$RETIRE_BAK"
rm -f "$CAL/install-retire-debug-keeper.sh"
run --yes
[ "$RC" = 2 ] && ok "refused before step 01 (exit 2)" || bad "it exited $RC"
want '03-heat-chain cannot start: RETIRE is not readable' "$OUT" "naming the chain's own variable and file"
want "$CAL/install-retire-debug-keeper.sh" "$OUT" "by the path the CHAIN resolves it to"
[ -z "$(order)" ] && ok "and nothing ran" || bad "a step ran: $(order)"
# And it is resolved against the CHAIN's directory, not the runbook's. The two are the same directory in
# the real tree -- so resolving with the wrong one is right by accident there and wrong here, which is
# exactly what a fixture that separates them is for. (The first version did resolve it wrongly and
# refused for a file that was there all along, one directory over.)
notwant "scripts/install-retire-debug-keeper.sh" "$OUT" "and NOT against the runbook's own directory"
cp "$RETIRE_BAK" "$CAL/install-retire-debug-keeper.sh"; chmod +x "$CAL/install-retire-debug-keeper.sh"

echo
echo "   -- the INSTRUMENT is gone, and that must NOT cost the boot:"
THERMAL_BAK="$W/thermal.bak"; cp "$CAL/device/zl1-thermal.sh" "$THERMAL_BAK"
rm -f "$CAL/device/zl1-thermal.sh"
run --yes
[ "$RC" != 2 ] && ok "the run PROCEEDS (exit $RC) -- a missing instrument is not a reason to lose the heat fix" \
              || bad "it refused; refusing here throws away two installers and the keeper kill"
want 'WARNING: the run will proceed' "$OUT" "it is a WARNING, said out loud before step 01"
want 'its MEASUREMENT WILL NOT' "$OUT" "naming exactly what will be lost"
want 'the A/B as unusable' "$OUT" "and what the chain will say instead, so the archive is not a surprise"
want 'CALLEE HEAT args=--yes' "$(cat "$ACT")" "and the chain still runs"
cp "$THERMAL_BAK" "$CAL/device/zl1-thermal.sh"; chmod +x "$CAL/device/zl1-thermal.sh"
run --status
notwant 'WARNING' "$OUT" "with the instrument back, no warning -- so the warning is a reading, not a fixed line"

echo
echo "   -- and a check that CANNOT be made is not a pass:"
# The extraction reads the chain's callees out of the chain. A chain whose shape this reader does not
# know leaves the extraction empty, and "nothing to check" would read exactly like "everything is there".
# So it is reported as UNUSABLE (and the run proceeds, naming the hole) -- never as a clean host.
CHAIN_BAK="$W/chain.bak"; cp "$CAL/host/zl1-heat-fix-chain.sh" "$CHAIN_BAK"
printf '#!/bin/sh\nprintf "CALLEE HEAT args=%%s\\n" "$*"\nexit 0\n' > "$CAL/host/zl1-heat-fix-chain.sh"
chmod +x "$CAL/host/zl1-heat-fix-chain.sh"
run --yes
[ "$RC" != 2 ] && ok "a chain shape it cannot read does not refuse on its own" || bad "it exited $RC"
want 'could not be made -- this run is NOT verified against it' "$OUT" "and it says the check has a HOLE, rather than nothing"
want "the heat chain's callees could not be read out of" "$OUT" "naming what could not be read"
run --status
want 'which is NOT a pass' "$OUT" "--status says the same, in the same words"
cp "$CHAIN_BAK" "$CAL/host/zl1-heat-fix-chain.sh"; chmod +x "$CAL/host/zl1-heat-fix-chain.sh"
host_fixture_ok

# ==================================================================================================
echo
echo "== 10. --help prints the header, and the header is the contract =="
# ==================================================================================================
reset; run --help
[ "$RC" = 0 ] && ok "--help exits 0" || bad "it exited $RC"
# A substring that fits on ONE printed line: the header wraps, and `want` is a substring match over the
# whole output, so a phrase spanning two lines can never match however true it is.
want 'WHAT IT NEVER DOES' "$OUT" "--help prints the header's own words"
want '01 capture' "$OUT" "including the forced order and the reason for each arrow"
notwant '#!/usr/bin/env bash' "$OUT" "and not the shebang or any code"
# The exit codes are a contract, and a code the header does not mention is one nobody can use.
for c in '2  refused' '1  the sequence stopped short' '3  interrupted'; do
  want "$c" "$(cat "$SRC")" "the header declares: $c"
done
want 'THE TRIAL WRITES TO THE' "$(cat "$SRC")" "and it says out loud that --apply-trial is the write"

# ==================================================================================================
# ==================================================================================================
echo
echo "== 10b. the mutations: each one must change what the checks above observe =="
# ==================================================================================================
# This harness had no in-file mutation until now: doc 127 measured the two it quotes by hand (cp the
# subject aside, sed it, run, restore), which is a procedure and not a mechanism -- the same distinction
# the family now enforces everywhere else (docs 129). The subject here is the REWRITTEN copy, so a
# mutation has to land on both: asserted to change the SHIPPED file first, or the mutant is not a mutant.
# BESIDE the rewritten subject, not in a directory of their own: the subject resolves its siblings as
# \$HERE/../install-*.sh and \$HERE/../../scripts/, so a mutant in \$W/mut would refuse for a reason that
# has nothing to do with the mutation -- measured, not reasoned about: the first version of this block put
# them in \$W/mut and every mutant exited 2 with "cannot read .../mut/../install-netwatch-service.sh".
MUTDIR="$W/fake-repo/scripts/host"; mkdir -p "$MUTDIR"
mutate() { # name, sed-script
  if cmp -s <(sed "$2" "$SRC" 2>/dev/null) "$SRC"; then
    bad "mutation '$1': its sed matches no line of the SHIPPED script, so nothing is being tested"
    return 1
  fi
  sed "$2" "$RB" > "$MUTDIR/$1.sh"
  if cmp -s "$RB" "$MUTDIR/$1.sh"; then
    bad "mutation '$1': the sed changes the shipped file but not the subject -- it did not land"
    return 1
  fi
  bash -n "$MUTDIR/$1.sh" 2>/dev/null || { bad "mutation '$1': the mutant does not parse"; return 1; }
  chmod +x "$MUTDIR/$1.sh"
  ok "mutation '$1': landed (it changes a line of the shipped script, and the mutant parses)"
  return 0
}
mutrun() { # mutant path, args...
  MUT="$1"; shift
  : > "$ACT"; rm -rf "$OUTROOT"/tmp-one-boot-*
  MOUT=$(env PATH="$STUB:$MINBIN" "$BASH_BIN" "$MUT" "$@" 2>&1); MRC=$?
}

# The one this section is for: step 03 stops being told where to archive. The observable difference is
# not "an argument is missing" -- it is that the boot's measurement is no longer inside the boot's record.
if mutate nooutdir 's# --outdir "\$OUT/03-heat-chain"##'; then
  mutrun "$MUTDIR/nooutdir.sh" --yes
  [ "$MRC" = 0 ] && ok "mutation 'no outdir for step 03': the run still exits 0" || bad "the mutant exited $MRC"
  MOTD=$(latest_archive)
  [ ! -f "$MOTD/03-heat-chain/06b-heat-ab.txt" ] \
    && ok "and the A/B reading is NO LONGER inside the boot's archive (the check is live)" \
    || bad "the reading is still inside the archive -- the assertion above is not measuring the outdir"
  [ -f "$FALLBACK/06b-heat-ab.txt" ] \
    && ok "and it went where an untold step puts it: a directory of its own, named by nothing" \
    || bad "the reading vanished rather than landing outside the archive -- the two-sided assertion is broken"
  [ "$MRC" = 0 ] && notwant 'CALLEE HEAT args=--yes --outdir' "$(order)" \
    "and the chain was invoked without an outdir, which is the change itself"
fi

# The other one this section is for: the bound that makes a hung step say so instead of spending a boot in
# silence. The scenario gives ONE step a real 5 s and a 2 s bound; without the bound the step simply
# succeeds late and the archive says 0, which is what a hang would also say.
if mutate notimeout 's#^    timeout -k 5 "\$STEP_LIMIT" "\$@" &$#    "$@" \&#'; then
  FP_SLEEP_FP=5 mutrun "$MUTDIR/notimeout.sh" --yes --step-limit 2
  FP_SLEEP_FP=""
  [ "$MRC" = 0 ] && ok "mutation 'no step bound': the run completes -- a step that outlasted its bound is a pass" \
                 || bad "the 'no step bound' mutant exited $MRC (it did not land)"
  MOTD7=$(latest_archive)
  grep -qE '^04-fingerprint +0' "$MOTD7/INDEX.txt" 2>/dev/null \
    && ok "and the index says 0 for it, which is exactly what a hang would have said (the check is live)" \
    || bad "the mutant did not record 04-fingerprint as 0 -- the scenario is not measuring the bound"
  notwant 'DID NOT FINISH' "$MOUT" "with nothing anywhere telling the operator it took longer than it was allowed to"
fi

echo
# The bound on the calls that are NOT steps. Removing it makes the subject HANG where the subject comes
# back -- which is the only observable a stalled link has, since it produces no exit code and no output.
# `muthang` therefore runs the mutant under the harness's own kill and asserts the KILL is what ended it.
muthang() { # mutant, args... -- the mutant, against a device that never answers
  MUT="$1"; shift
  : > "$ACT"; rm -rf "$OUTROOT"/tmp-one-boot-*
  MOUT=$(env PATH="$STUB:$MINBIN" FP_SSH_HANG_ON="${FP_SSH_HANG_ON:-true}" \
         timeout -k 5 "$HANG_KILL" "$BASH_BIN" "$MUT" "$@" 2>&1); MRC=$?
}
if mutate nodevbound 's#^devssh() { bound "\$STATE_LIMIT" #devssh() { #'; then
  reset; FP_SSH_HANG_ON=true
  muthang "$MUTDIR/nodevbound.sh" --yes --state-limit 2
  FP_SSH_HANG_ON=""
  [ "$MRC" = 124 ] && ok "mutation 'no bound on the non-step calls': the run HANGS, and only the harness's own kill ends it (the check is live)" \
                    || bad "the mutant exited $MRC -- it did not hang, so the bound is not what the scenarios above are measuring"
fi
# And the guard that turns "the host gave up" into a token, rather than letting it reach the verdict as an
# empty string. Without it the reading is empty, falls into the last branch, and is printed as a claim
# about the phone -- the exact defect this section exists for.
if mutate notimeouttoken 's#^  gave_up "\$rc" && { printf .TIMEOUT.; return 0; }$#  : #'; then
  reset; FP_SSH_HANG_ON=download_mode
  muthang "$MUTDIR/notimeouttoken.sh" --status --state-limit 2
  FP_SSH_HANG_ON=""
  [ "$MRC" != 124 ] && ok "mutation 'no timeout token': the run still comes back (the bound itself is untouched)" \
                    || bad "the mutant hung -- the wrong thing was mutated"
  want 'A is treated as NOT met' "$MOUT" "mutation 'no timeout token': a host-side timeout is printed as 'A is treated as NOT met' -- a verdict about the phone (the check is live)"
  notwant 'NOT READ' "$MOUT" "with nothing anywhere saying the phone was never read"
fi

# The SOFT branch: make the missing instrument a REFUSAL, and see the boot get thrown away for it. The
# HARD/SOFT split is carried by the PREFIX the check prints (that is what the caller switches on), so the
# mutation changes that word -- a mutation of `bad=` instead would change nothing observable, because the
# caller never refuses on `bad` (measured: that was the first version of this mutation, and the mutant
# exited 0 and installed the heat fix, i.e. it proved nothing).
if mutate hardinstrument 's#|| echo "SOFT 03-heat-chain#|| echo "HARD 03-heat-chain#'; then
  reset; host_fixture_ok
  THERMAL_BAK2="$W/thermal2.bak"; cp "$CAL/device/zl1-thermal.sh" "$THERMAL_BAK2"
  rm -f "$CAL/device/zl1-thermal.sh"
  mutrun "$MUTDIR/hardinstrument.sh" --yes
  cp "$THERMAL_BAK2" "$CAL/device/zl1-thermal.sh"; chmod +x "$CAL/device/zl1-thermal.sh"
  [ "$MRC" = 2 ] && ok "mutation 'the instrument made a refusal': the run REFUSES -- the whole heat fix is lost to a missing measuring tool (the check is live)" \
                || bad "the mutant exited $MRC; the SOFT/HARD split is not what the checks above are measuring"
  notwant 'CALLEE HEAT' "$(cat "$ACT")" "and the chain never ran, so the two fixes were never installed"
fi
# And the report for a check that could not be made: silence it, and a host that was never verified
# reports itself as ready. (Mutating the extraction instead changes nothing observable -- the empty
# extraction still reaches the UNUSABLE branch and is still printed. Measured: that mutant reported the
# hole exactly like the subject, so it proved nothing about the sentence this scenario asserts.)
if mutate nocallees 's#^      echo "UNUSABLE .*$#      : #'; then
  reset; host_fixture_ok
  CHAIN_BAK2="$W/chain2.bak"; cp "$CAL/host/zl1-heat-fix-chain.sh" "$CHAIN_BAK2"
  printf '#!/bin/sh\nprintf "CALLEE HEAT args=%%s\\n" "$*"\nexit 0\n' > "$CAL/host/zl1-heat-fix-chain.sh"
  chmod +x "$CAL/host/zl1-heat-fix-chain.sh"
  mutrun "$MUTDIR/nocallees.sh" --yes
  cp "$CHAIN_BAK2" "$CAL/host/zl1-heat-fix-chain.sh"; chmod +x "$CAL/host/zl1-heat-fix-chain.sh"
  [ "$MRC" != 2 ] && ok "mutation 'no extraction': the run proceeds" || bad "the mutant exited $MRC"
  notwant 'NOT verified against it' "$MOUT" "mutation 'no extraction': a check that could not be made is SILENT -- the run reports itself ready on a chain it never read (the check is live)"
fi

echo "== 11. the health check cites this harness's count, and that citation cannot drift =="
# ==================================================================================================
# The extractor is this family's (docs 110) and deliberately not the obvious one: `grep -oE '[0-9]+'`
# over a line containing this script's NAME matches the `1` in `zl1-...` and reads a citation of 89 as
# "1". The name has to be matched FIRST and the number taken from what follows it; `[ ,(]*` because the
# citation may be written `name, N checks` or `name (N checks)`, and the whole file is flattened to one
# line so a citation broken across two string literals still counts.
HEALTH="$HERE/zl1-health-check.sh"
if [ -r "$HEALTH" ]; then
  CITED="$(sed -e 's/always "/ /g' -e 's/"$//' "$HEALTH" | tr '\n' ' ' \
    | sed -n 's/.*zl1-one-boot-runbook-selftest\.sh[ ,(]*\([0-9][0-9]*\) checks.*/\1/p')"
  N=$((PASS + FAIL + 1))
  if [ -z "$CITED" ]; then
    bad "the health check does not cite this harness at all -- add it to the item that names the offline verification"
  elif [ "$CITED" = "$N" ]; then
    ok "the health check cites $N checks, which is what this harness has"
  else
    bad "the health check cites $CITED checks, but this harness has $N -- fix host/zl1-health-check.sh"
  fi
else
  bad "cannot read $HEALTH -- the citation check cannot run"
fi

echo
echo "pass=$PASS fail=$FAIL"
if [ "$KEEP" = 1 ]; then echo "kept: $W"; else rm -rf "$W"; fi
[ "$FAIL" = 0 ] || exit 1
exit 0
