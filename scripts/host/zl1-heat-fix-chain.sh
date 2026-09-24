#!/usr/bin/env bash
# zl1 heat-fix chain -- the whole second half of "why is it hot", as ONE command on ONE boot.
#
# Why this exists (docs 118, and the shape is docs 107's one level up):
#
#   The heat is two known, measured causes, and BOTH fixes are installed by a chain of five steps that
#   must run on a booted device, in an order where two of them are only licensed by the step before:
#
#     1. install-netwatch-service.sh --yes --ssh          deploy the build that has ensure_addrs()
#     2. install-netwatch-service.sh --yes --ssh --activate  make it the RUNNING build, and prove it
#     3. (settle)                                        the new build self-heals by re-enumerating the
#                                                        USB gadget -- which drops the ssh session
#                                                        this chain is running over
#     4. zl1-address-owner-proof.sh --yes                the proof that the NETWATCH owns the addresses
#     5. install-retire-debug-keeper.sh --install --now --after-proof   kill the v63 keeper (~1 core)
#     6. install-cpufreq-governor.sh --install           the other half: the governor, not the process
#
#   Steps 4-6 are the ones with consequences: 5 removes a process, and the recovery if 4 was wrong is a
#   finger on the power button (there is no software way back into a phone with no address). Every
#   step here is offline-verified with its own harness, and each one REFUSES on its own terms -- this
#   script adds no new safety argument, it only adds the ORDER and the ARITHMETIC OF ONE BOOT.
#
#   AND THE PROOF LICENSES STEP 5, NOT STEP 6. That distinction is the one place this chain does not
#   simply stop at the first thing that did not go its way. What step 4 tests is whether something still
#   owns rndis0's addresses, because the keeper is what owns them today and retiring it is what could
#   leave them owned by nothing -- so a proof that does not come back `proof-obtained` leaves the keeper
#   ALONE, and the device in the known-good state the refusal describes. Step 6 has no such dependency:
#   the governor installer changes cpufreq scaling, removes no process, touches no address and restarts
#   nothing (its own header says it deliberately does NOT stop the keeper). Gating it on the proof would
#   therefore lose BOTH halves of the heat fix on every boot whose proof is not clean -- and docs 112
#   measured that the verdict is a RACE, with `inconclusive` the expected reading on most boots. So the
#   non-proven branch installs the governor and reports exactly which half is in. A step that RAN and
#   FAILED is a different case and still stops the chain, because a failure leaves the device in a state
#   nobody has read; a refusal leaves it in the one this chain just described.
#
#   On this device a boot is not free: every boot can end in EDL, and leaving EDL takes 10-20 s of
#   holding the power button (docs 49 section 6). A chain of five hand-run commands with a 90 s wait in
#   the middle is exactly the shape that gets half-done and then abandoned -- and half-done, in this
#   chain, means the addresses are owned by nothing. So the one thing this script buys is that the
#   chain either finishes or reports exactly where it stopped and what state that leaves.
#
# Usage: zl1-heat-fix-chain.sh --yes [--settle SECS] [--outdir DIR] [--status] [--quiet]
#   --yes            REQUIRED to run the chain. Without it: print the plan, write nothing, exit 2.
#   --settle SECS    seconds to wait after --activate before the proof (default 90: the netwatch
#                    needs SETTLE_SECONDS before its heal stage may re-enumerate the gadget, and this
#                    chain's ssh session is on that gadget)
#   --outdir DIR     where to archive (default: repo tmp-heat-fix-<utc timestamp>/)
#   --status         read-only: where is the chain on this boot? (no --yes needed, writes nothing)
#   --quiet          print only the verdicts
#
# Exit codes: 0 the chain ran to the end; 1 the chain stopped short -- a step failed, or the proof did
#             not license step 5 -- and the archive says which, and whether the governor half went in;
#             2 refused -- no --yes, or the device is not reachable; 3 interrupted (its own code, and an
#             interrupt still archives what ran).
#
# What it never does, in any mode: reboot the device, flash anything, run a QDL/firehose tool, write a
# partition, or touch the forbidden partition set. Step 1's own installer requires a VERIFIED misc
# backup and takes none here; this script checks that the backup exists before it starts, so that a
# boot is not spent discovering it half-way down the chain.

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)

DEV=${ZL1_SERIAL:-33e80afe}
HOST=${ZL1_HOST:-root@10.15.19.82}
IP=${ZL1_IP:-10.15.19.82}
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$HOST")
SCP=(scp -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10)

NW="$HERE/../install-netwatch-service.sh"
RETIRE="$HERE/../install-retire-debug-keeper.sh"
CPUFREQ="$HERE/../install-cpufreq-governor.sh"
PROOF="$HERE/../device/zl1-address-owner-proof.sh"
# The verified misc backup. This is the INSTALLER's path and the installer's rule (lines 181-188 of
# scripts/install-netwatch-service.sh): non-empty, a SHA256SUMS beside it, and it passes that file.
# It is duplicated here and not re-invented -- the point is to spend no boot discovering it half-way
# down the chain -- and if the two ever disagree THE INSTALLER WINS: its refusal is the one that
# protects the partition it can write to.
MISC_OUT=${ZL1_MISC_OUT:-/mnt/data/zl1-backups/2026-09-17-misc}
MISC_BACKUP="$MISC_OUT/misc.img"

YES=0
STATUS=0
QUIET=0
SETTLE=90
OUT=""

while [ $# -gt 0 ]; do
  case "$1" in
  --yes) YES=1; shift ;;
  --status) STATUS=1; shift ;;
  --quiet) QUIET=1; shift ;;
  --settle) SETTLE="${2?--settle needs SECONDS}"; shift 2 ;;
  --outdir) OUT="${2?--outdir needs a DIRECTORY}"; shift 2 ;;
  --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0" ; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

say()  { [ "$QUIET" = 1 ] && [ -n "${1:-}" ] && return 0; printf '%s\n' "${*:-}"; }
note() { printf '   %s\n' "$*"; }

for f in "$NW" "$RETIRE" "$CPUFREQ" "$PROOF"; do
  [ -r "$f" ] || { echo "cannot read $f" >&2; exit 2; }
done

# --- is there a device at all? ---------------------------------------------------------------------
# The same three ways of being unreachable as the capture script, and the same order of questions: the
# host's USB tree first, because EDL has NO SERIAL NUMBER and a serial lookup finds nothing while a
# vendor-id lookup finds a phone that cannot be talked to. The serial match is a PREFIX (the gadget
# reports 33e80afe-v63-usbd-disabled-rndis) and never a bare USB id: an unrelated Xiaomi, 4a2fe00b,
# shares this bus.
edl_state() {
  if lsusb -d 05c6:9008 >/dev/null 2>&1; then echo edl; return; fi
  for d in /sys/bus/usb/devices/*/; do
    case "$(cat "$d/serial" 2>/dev/null)" in
    "$DEV"*) echo present; return ;;
    esac
  done
  echo absent
}

STATE=$(edl_state)
if [ "$STATE" != present ]; then
  say "zl1 heat-fix chain"
  say "  the device is NOT reachable: $STATE"
  case "$STATE" in
  edl)
    say
    say "  It is in Qualcomm EDL (05c6:9008 / QDL mode). There is no software exit, and no downloader"
    say "  tool may be run here: not QFIL, not QSaharaServer, not fh_loader and not any fastboot write."
    say "  THE NEXT MOVE IS PHYSICAL: long-press POWER for 10-20 s, wait for RNDIS and ssh, then run"
    say "  this script again."
    ;;
  absent)
    say "  No device with serial $DEV is on the bus (the other phone on this bus is 4a2fe00b and must"
    say "  be ignored). Check the cable and the port."
    ;;
  esac
  say "  NOTHING WAS RUN and nothing was written. Exit 2."
  exit 2
fi

if ! "${SSH[@]}" true 2>/dev/null; then
  say "zl1 heat-fix chain"
  say "  the device is on the bus (serial $DEV) but SSH does not answer. It may still be booting, or the"
  say "  host-side RNDIS stall may be in effect -- that one lives on the HOST and needs no key press:"
  say "      sudo scripts/host/zl1-rndis-recover.sh --status   # then without --status"
  say "  NOTHING WAS RUN. Exit 2."
  exit 2
fi

BOOT_ID=$("${SSH[@]}" 'cat /proc/sys/kernel/random/boot_id 2>/dev/null' | tr -d '\r\n')
[ -n "$BOOT_ID" ] || BOOT_ID="unknown-$(date -u +%Y%m%dT%H%M%SZ)"

# --- --status: where is the chain on this boot? ----------------------------------------------------
# Read-only, and it answers the four questions the chain is about, in the chain's own order. It is here
# so that "run it and see" is never the first thing a person does to a phone they cannot easily reboot.
if [ "$STATUS" = 1 ]; then
  say "zl1 heat-fix chain -- status (read-only)"
  say "  device:  $HOST (serial $DEV)"
  say "  boot_id: $BOOT_ID"
  say
  ST=$("${SSH[@]}" '
    f=/etc/systemd/system/zl1-netwatch.sh
    printf "netwatch-file: %s\n" "$([ -x "$f" ] && echo present || echo MISSING)"
    printf "netwatch-fn:   %s\n" "$(grep -qc "^ensure_addrs()" "$f" 2>/dev/null && echo has-ensure_addrs || echo MISSING)"
    printf "netwatch-unit: %s\n" "$(systemctl is-active zl1-netwatch.service 2>/dev/null || true)"
    k=""
    for p in /proc/[0-9]*; do
      c=$(tr "\0" " " < "$p/cmdline" 2>/dev/null) || continue
      case "$c" in *zl1-debug-init*|*zl1-debug-keeper*) k="${p#/proc/}"; break ;; esac
    done
    printf "keeper:        %s\n" "${k:-gone}"
    printf "addr2:         %s\n" "$(ip -4 -br addr show rndis0 2>/dev/null | grep -c "192.168.2.15")"
    printf "addr19:        %s\n" "$(ip -4 -br addr show usb0 2>/dev/null | grep -c "10.15.19.100")"
    g=""
    for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
      [ -r "$c" ] || continue
      g="$g $(cat "$c" 2>/dev/null)"
    done
    printf "governors:    %s\n" "${g# }"
  ' 2>/dev/null | tr -d '\r')
  printf '%s\n' "$ST" | sed 's/^/  /'
  say
  say "  read it as the chain: the netwatch file must carry ensure_addrs() BEFORE the keeper is retired,"
  say "  and the keeper being gone with the addresses still present is the end state the third step buys."
  exit 0
fi

if [ "$YES" != 1 ]; then
  say "zl1 heat-fix chain -- PLAN (nothing was run; pass --yes to run it)"
  say
  say "  device:  $HOST (serial $DEV)  boot_id $BOOT_ID"
  say
  say "  1. install-netwatch-service.sh --yes --ssh"
  say "       writes /etc/systemd/system/zl1-netwatch.{sh,service} on the device (over ssh, to the"
  say "       LIVE bind mount of that directory), atomically: the payload lands as .new and is renamed"
  say "       over the old inode, because a running sh reads its script from that file."
  say "       Requires a VERIFIED misc backup: $MISC_BACKUP (checked before the chain starts)"
  say "  2. install-netwatch-service.sh --yes --ssh --activate"
  say "       restarts the unit and PROVES the running build is the deployed one, by requiring"
  say "       ExecMainStartTimestampMonotonic to be later than the /proc/uptime read before the restart."
  say "  3. wait ${SETTLE}s"
  say "       the new build may re-enumerate the USB gadget (that is the self-heal), which drops THIS"
  say "       ssh session -- so the chain waits before it needs the link again."
  say "  4. zl1-address-owner-proof.sh --yes   (on the device)"
  say "       stops the keeper, takes 192.168.2.15 off rndis0, and requires the NETWATCH to put it back"
  say "       and to log a new line. Writes nothing durable; it does SIGSTOP/SIGCONT a process."
  say "  5. install-retire-debug-keeper.sh --install --now --after-proof"
  say "       ONLY if step 4 printed exactly '== verdict: proof-obtained'. Installs the retirement unit"
  say "       and kills the keeper on this boot -- the ~1 core of this 4-core SoC (docs 72 section 4b)."
  say "  6. install-cpufreq-governor.sh --install"
  say "       the other half of the heat fix: the image pins all four cores on 'performance'."
  say "       This one is NOT licensed by step 4 and runs even when step 4 refuses -- it changes cpufreq"
  say "       scaling, removes no process and touches no address. docs 112 measured the proof verdict as a"
  say "       race, so a boot whose proof is not clean still gets this half of the fix."
  say
  say "  It reboots nothing, flashes nothing, and writes no partition. Exit 2 (nothing was run)."
  exit 2
fi

# --- the archive, and the interrupt handler (same contract as the capture script) -----------------
# A record of a boot that cannot be revisited has to say which step produced which file and whether it
# is intact; and an interrupt must still leave that. On SIGINT/SIGTERM the handler archives what ran and
# exits 3 -- because the state of a half-finished chain is the most useful thing this script can leave
# behind, and the step that was interrupted is listed with `?` rather than omitted.
ARCHIVED=0
INTERRUPTED=0
STEP_NAMES=()
STEP_RC=()
STEP_FILES=()

archive() {
  [ "$ARCHIVED" = 1 ] && return 0
  ARCHIVED=1
  {
    printf '# zl1 heat-fix chain\n'
    printf 'boot_id: %s\n' "$BOOT_ID"
    printf 'device: %s (serial %s)\n' "$HOST" "$DEV"
    printf 'ran: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'settle: %ss   misc_backup: %s\n' "$SETTLE" "$MISC_BACKUP"
    [ "$INTERRUPTED" = 1 ] && printf 'INTERRUPTED: yes -- the steps below are all that ran\n'
    printf '\n# step                    rc   file\n'
    i=0
    while [ "$i" -lt "${#STEP_NAMES[@]}" ]; do
      printf '%-24s %-4s %s\n' "${STEP_NAMES[$i]}" "${STEP_RC[$i]}" "${STEP_FILES[$i]}"
      i=$((i + 1))
    done
    printf '\n# what the device said when the chain stopped\n'
    if [ -n "${FINAL_STATE:-}" ]; then printf '%s\n' "$FINAL_STATE"; else printf 'no read-back was taken\n'; fi
  } > "$OUT/INDEX.txt" 2>/dev/null
  ( cd "$OUT" 2>/dev/null && sha256sum ./*.txt > SHA256SUMS 2>/dev/null )
}
on_signal() { INTERRUPTED=1; say ""; say "INTERRUPTED -- archiving what ran (the device is wherever the last step left it)"; archive; exit 3; }
trap on_signal INT TERM HUP

[ -n "$OUT" ] || OUT="$REPO/tmp-heat-fix-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT" || { echo "cannot create $OUT" >&2; exit 2; }
OUT=$(cd "$OUT" && pwd)

say "zl1 heat-fix chain"
say "  device:  $HOST (serial $DEV)"
say "  boot_id: $BOOT_ID"
say "  outdir:  $OUT"
say

# --- the read-back the index ends with ------------------------------------------------------------
# Read-only, and taken at the END (and again on failure). It is the difference between "step 5 failed"
# and "step 5 failed and the addresses are still there, so the phone is reachable" -- which is the only
# question anyone asks after a failure in this chain.
read_state() {
  FINAL_STATE=$("${SSH[@]}" '
    f=/etc/systemd/system/zl1-netwatch.sh
    printf "netwatch: file=%s fn=%s unit=%s\n" \
      "$([ -x "$f" ] && echo present || echo MISSING)" \
      "$(grep -qc "^ensure_addrs()" "$f" 2>/dev/null && echo has-ensure_addrs || echo MISSING)" \
      "$(systemctl is-active zl1-netwatch.service 2>/dev/null || true)"
    k=""
    for p in /proc/[0-9]*; do
      c=$(tr "\0" " " < "$p/cmdline" 2>/dev/null) || continue
      case "$c" in *zl1-debug-init*|*zl1-debug-keeper*) k="${p#/proc/}"; break ;; esac
    done
    printf "keeper: %s\n" "${k:-gone}"
    printf "addrs: 192.168.2.15=%s 10.15.19.100=%s\n" \
      "$(ip -4 -br addr show rndis0 2>/dev/null | grep -c "192.168.2.15")" \
      "$(ip -4 -br addr show usb0 2>/dev/null | grep -c "10.15.19.100")"
    g=""
    for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
      [ -r "$c" ] || continue
      g="$g$(cat "$c" 2>/dev/null) "
    done
    printf "governors: %s\n" "${g% }"
  ' 2>/dev/null | tr -d '\r')
  printf '%s\n' "$FINAL_STATE" | sed 's/^/     | /'
}

# --- the step runner ------------------------------------------------------------------------------
# Unlike the capture script, a failing step here DOES stop the chain: these steps are not independent
# readings, they are a licence chain -- running step 5 after a failed step 4 is the exact thing the
# whole design forbids. So the runner stops, reads the device back, archives, and exits 1.
FAILED=0
step() { # name, description, command...
  local name="$1" desc="$2"; shift 2
  local out="$OUT/$name.txt"
  say "-- $desc"
  STEP_NAMES+=("$name")
  "$@" > "$out" 2>&1
  local rc=$?
  STEP_RC+=("$rc")
  STEP_FILES+=("$(basename "$out")")
  if [ "$rc" = 0 ]; then
    note "ok   -> $(basename "$out")"
  else
    note "FAILED rc=$rc -- its output is archived in $(basename "$out"):"
    grep -av '^[[:space:]]*$' "$out" 2>/dev/null | tail -4 | sed 's/^/        | /'
    say ""
    say "  THE CHAIN STOPPED HERE. Everything after this step was NOT run, and what it would have been"
    say "  licensed by is now unknown -- do not run the next step by hand until you have read $name."
    say "  State of the device now:"
    read_state
    archive
    say "  archive: $OUT"
    exit 1
  fi
  say ""
}

# --- 0. the preflight the chain needs BEFORE it writes anything ------------------------------------
# Step 1's installer refuses without a verified misc backup, and it is right to. Checking it here means
# a boot is not spent finding out half-way down; it is read-only (the file must exist and be non-empty,
# there must be a SHA256SUMS beside it, and it must pass that file -- the same three rules the installer
# applies, because a gate that only checked "the file exists" would be satisfied by a truncated image,
# which is a lesson this project has had to write down more than once).
misc_backup_ok() {
  [ -s "$MISC_BACKUP" ] || { echo "empty or missing"; return 1; }
  [ -f "$MISC_OUT/SHA256SUMS" ] || { echo "no SHA256SUMS beside it"; return 1; }
  ( cd "$MISC_OUT" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ) || { echo "it FAILS its recorded SHA256"; return 1; }
  return 0
}
if ! MISC_WHY=$(misc_backup_ok); then
  say "REFUSING: the verified misc backup is not usable -- $MISC_WHY"
  say "  Step 1 changes a unit that can write 'boot-recovery' into misc, and its installer requires a"
  say "  VERIFIED misc backup rather than taking one (reading a raw partition over ssh would be a"
  say "  second, divergent implementation of the checked adb/TWRP read). The rule is the installer's;"
  say "  this only checks it before the chain starts. Take one with:  $NW --yes    (the adb/TWRP route)"
  say "  Nothing was run. Exit 2."
  exit 2
fi
say "misc backup verified: $MISC_BACKUP ($(stat -c%s "$MISC_BACKUP") bytes)"

# ==================================================================================================
say "== 1/6  deploy the netwatch build that has ensure_addrs()"
# ==================================================================================================
step 01-netwatch-deploy "deploy the netwatch (ssh, atomic, nothing restarted)" \
  "$NW" --yes --ssh

# ==================================================================================================
say "== 2/6  make the DEPLOYED build the RUNNING one, and prove it"
# ==================================================================================================
step 02-netwatch-activate "activate + prove the running build (monotonic timestamp)" \
  "$NW" --yes --ssh --activate

# ==================================================================================================
say "== 3/6  settle ${SETTLE}s (the new build may re-enumerate the gadget this ssh runs over)"
# ==================================================================================================
# This is a step in its own right and it is archived like one, because "the chain waited 90 s here" is
# a fact the next reader needs -- a chain that skips it will drop its own ssh session in the middle of
# the proof, and the failure will look like the proof's fault.
# In the BACKGROUND, then `wait`, and that is not a style choice: bash defers a trap until the
# foreground command returns, so `sleep N` in the foreground makes an interrupt take N seconds to be
# honoured -- the capture script measured exactly this on an ssh call (trap at +20.0 s foreground
# against +2.0 s under `wait`). On a 90 s settle that is the difference between "interrupted" and
# "interrupted ninety seconds from now".
sleep "$SETTLE" &
wait $!
STEP_NAMES+=("03-settle"); STEP_RC+=("0"); STEP_FILES+=("03-settle.txt")
printf 'waited %ss before the proof: the activated build may re-enumerate the USB gadget, which drops\nthis chain ssh session (docs 115 section 4).\n' "$SETTLE" > "$OUT/03-settle.txt"
note "slept ${SETTLE}s"

# ==================================================================================================
say "== 4/6  the address-ownership proof (decides whether the keeper may be retired)"
# ==================================================================================================
# Run the same way the health check tells a person to run it: copy it to the device and run it there.
# `timeout` is used on the DEVICE for the same reason the capture script does (GNU timeout signals the
# process GROUP, which is what stops a runaway child), and its output goes to the archive because the
# verdict line in it is the licence for step 5.
PROOF_BASE=$(basename "$PROOF")
say "-- scp + run $PROOF_BASE --yes"
STEP_NAMES+=("04-proof")
if "${SCP[@]}" "$PROOF" "$HOST:/tmp/$PROOF_BASE" > "$OUT/04-proof.txt" 2>&1; then
  "${SSH[@]}" "if command -v timeout >/dev/null 2>&1; then timeout -k 5 120 sh /tmp/$PROOF_BASE --yes; else sh /tmp/$PROOF_BASE --yes; fi" >> "$OUT/04-proof.txt" 2>&1
  PROOF_RC=$?
else
  PROOF_RC=90
fi
STEP_RC+=("$PROOF_RC"); STEP_FILES+=("04-proof.txt")
VERDICT=$(grep -ax '== verdict: [a-z-]*' "$OUT/04-proof.txt" 2>/dev/null | tail -1 | sed 's/^== verdict: //')
say "   verdict: ${VERDICT:-<none: no verdict line in the output>}"
say ""
if [ "$PROOF_RC" != 0 ] || [ "$VERDICT" != "proof-obtained" ]; then
  # `proof-obtained` is the whole licence, and it is compared as a WHOLE LINE (docs 114: a substring
  # gate accepted a sentence that merely contained the word). Everything else -- proof-unclear, a
  # refusal, an empty output, a timeout -- leaves the keeper in place, which is the safe state.
  say "  REFUSING TO RETIRE THE KEEPER: the proof did not print '== verdict: proof-obtained' (rc=$PROOF_RC)."
  say "  That is not a failure of the chain, it is the chain working: the keeper still owns the"
  say "  addresses, so the phone is reachable and nothing needs a finger. Read 04-proof.txt, and use"
  say "  docs 112 (the verdict is a race, and 'inconclusive' is the expected reading on most boots)."
  say ""
  # AND THE OTHER HALF STILL GOES IN. What step 4 licenses is RETIRING THE KEEPER -- it tests whether
  # something still owns rndis0's addresses, and the keeper is what owns them. The governor has no such
  # dependency: it changes cpufreq scaling, removes no process, touches no address and restarts nothing
  # (its own header says it deliberately does not stop the keeper). Since docs 112 measured the verdict
  # as a RACE whose expected reading is `inconclusive`, gating step 6 on step 4 would mean most boots
  # install NEITHER heat fix when only one of them needs a licence. So it runs here, on the branch that
  # refuses the kill, and the output says plainly which half is in.
  #
  # This is NOT the same as the rule that a failing step stops the chain, and the difference is the
  # state the device is left in: a step that RAN and FAILED leaves a state nobody has read, and stopping
  # is right; a refusal leaves the state this branch just described -- keeper alive, addresses owned,
  # phone reachable.
  say "== 6/6  the heat fix's other half needs NO licence from the proof -- installing it anyway"
  step 06-cpufreq-governor "install the governor unit and apply it (independent of the address proof)" \
    "$CPUFREQ" --install
  say ""
  say "  State of the device now:"
  read_state
  archive
  say "  archive: $OUT"
  say "  THE KEEPER IS STILL IN PLACE: ~1 core of this 4-core SoC is still going to it, and retiring it"
  say "  needs a boot whose proof prints exactly '== verdict: proof-obtained'. The governor half IS in."
  say "  Exit 1: the chain did not finish, and this archive says which half did."
  exit 1
fi

# ==================================================================================================
say "== 5/6  retire the v63 debug keeper  (~1 core of this 4-core SoC)"
# ==================================================================================================
step 05-retire-keeper "install the retirement unit and kill the keeper on this boot" \
  "$RETIRE" --install --now --after-proof

# ==================================================================================================
say "== 6/6  the other half: the cpufreq governor (the image pins all four cores on performance)"
# ==================================================================================================
step 06-cpufreq-governor "install the governor unit and apply it" \
  "$CPUFREQ" --install

# ==================================================================================================
say "== the chain finished -- what the device says now"
# ==================================================================================================
read_state
archive
say "  archive: $OUT"
say ""
say "  Read the governors line: four identical names means the applier read its writes back (docs 99 --"
say "  the first version printed 'on 0 cores' and exited 0). And 'keeper: gone' with both addresses"
say "  still 1 is the end state this chain exists to reach."
exit 0
