#!/bin/sh
# zl1 EDL post-mortem -- "what killed the boot before this one?" Read-only, one command, and it is
# the FIRST thing to run once the device is back from EDL.
#
# Why this exists (docs/ubuntu-touch/86): the 2026-09-23 trip into Qualcomm EDL (docs 80 section 7)
# was never attributed. Nothing in that session wrote a partition, the boot image or a modem/radio
# partition, and no QDL/firehose tool was ever run -- so "the device is in EDL" was a state with
# known recovery (docs 49 section 6: long-press POWER) and no explanation. Reading the kernel tree
# that built the flashed image turned up one, and it is a hazard that is *armed by default*:
#
#   panic -> do_msm_restart() -> msm_restart_prepare(): set_dload_mode(download_mode && in_panic)
#   -> scm_set_dload_mode(SCM_DLOAD_MODE) -> msm_trigger_wdog_bite() -> reset with the dload flag set
#   -> the bootloader enters EDL instead of booting.
#
# Three configs make every step of that real on this device, and they are all `=y` in the zl1 build
# (lineage_zl1_defconfig, confirmed in the built out/target/product/zl1/obj/KERNEL_OBJ/.config):
# CONFIG_POWER_RESET_MSM (the driver), CONFIG_MSM_DLOAD_MODE (download_mode defaults to **1**),
# CONFIG_MSM_FORCE_WDOG_BITE_ON_PANIC (the reset is forced, not best-effort). There is a second,
# deliberately-invokable entry -- `reboot edl` -> enable_emergency_dload_mode() -- and a third that is
# OFF here (`dload_on_uvlo`, a PMIC module param that defaults to false).
#
# So the question has a witness, and this script reads it. Two, in fact:
#
#   1. **pstore/ramoops.** CONFIG_PSTORE_RAM + CONFIG_PSTORE_CONSOLE are enabled and the DT wires
#      ramoops (msm8996-le-common.dtsi: 1 MiB at 0x91500000, `android,ramoops-dump-oops = <0x1>`).
#      A panic's console and oops land in /sys/fs/pstore/. This is the only *surviving* witness --
#      the kmsg ring dies with the reset -- and it is why this script exists at all.
#   2. **The kmsg archive.** /userdata/zl1-kmsg/keep/boot-<boot_id>/ carries the previous boot forward
#      on the next UT boot (scripts/install-kmsg-drain.sh), so the boot that died is archived under
#      its own id, and its last snapshot is the tail of that boot. Coarser (the ring wraps in ~1 min
#      and the snapshots are periodic), but it is a second, independent witness.
#
# Read-only: it reads /proc, /sys, debugfs listings and files under /userdata/zl1-kmsg. It writes
# nothing anywhere except stdout. It never reboots, never writes a sysfs node, never touches a
# partition, and never runs a QDL/firehose tool (there is no software exit from EDL: the kernel that
# could run code is precisely what is not running).
#
# Usage: zl1-edl-postmortem.sh [--quiet] [--full]
#   --quiet   verdict and the discriminating lines only
#   --full    print the witness files whole instead of their tails (they are <= 64 KiB each)
#
# Exit codes: 0 ran; 1 one or more witnesses are unavailable (the report says which);
#             2 this does not look like the zl1 -- the report is not about our device.

set -u

QUIET=0
FULL=0

while [ $# -gt 0 ]; do
  case "$1" in
  --quiet) QUIET=1; shift ;;
  --full) FULL=1; shift ;;
  --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0" ; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

say() { [ "$QUIET" = 1 ] && return 0; printf '%s\n' "$*"; }
always() { printf '%s\n' "$*"; }

rc=0

# --- 0. is this our device? ---------------------------------------------------------------------

model="$(tr -d '\0' < /proc/device-tree/model 2>/dev/null | tr -d '\n')"
always "zl1 edl post-mortem :: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
case "$model" in
*LE_ZL1*) always "== device: $model" ;;
*)
  always "== WARNING: device-tree model is \"$model\", not LE_ZL1."
  always "   Everything below is about whatever this is, not about the zl1. Stop and re-check."
  exit 2 ;;
esac
say "   uptime $(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null) s   kernel $(uname -r 2>/dev/null)"
say "   this boot's id: $(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"

# --- 1. the mechanism, read from the device itself ----------------------------------------------
#
# /proc/config.gz is the on-device truth (CONFIG_IKCONFIG_PROC=y), and it is the honest way to answer
# "is the panic -> EDL path armed?" -- not the build tree, which is one `make` away from being wrong.

always ""
always "== 1. is the panic -> EDL path armed on THIS device"

cfg() {
  zcat /proc/config.gz 2>/dev/null | grep -E "^CONFIG_$1=" \
    || echo "CONFIG_$1=<absent from /proc/config.gz>"
}

if [ -r /proc/config.gz ]; then
  say "   $(cfg POWER_RESET_MSM)                # the pshold/restart driver"
  say "   $(cfg MSM_DLOAD_MODE)                 # download_mode defaults to 1"
  say "   $(cfg MSM_FORCE_WDOG_BITE_ON_PANIC)   # the panic reset is forced"
  say "   $(cfg PSTORE_RAM)                     # ramoops: the witness of section 2"
  say "   $(cfg PSTORE_CONSOLE)                 # console records too"
  say "   $(cfg IKCONFIG_PROC)                  # /proc/config.gz itself"
else
  always "   /proc/config.gz is not readable: cannot confirm the mechanism from the device."
  always "   (CONFIG_PSTORE_RAM may be present anyway -- section 2 will show it.)"
  rc=1
fi

# The live value. `download_mode=1` means "a panic arms EDL"; 0 means "a panic resets normally".
# Note it is NOT persistent: it is a compiled-in default of 1, re-applied at every boot by the
# driver's probe (set_dload_mode(download_mode)), so a runtime 0 lasts only until the next reboot.
dm=""
for p in /sys/module/*/parameters/download_mode; do
  [ -e "$p" ] || continue
  dm="$(cat "$p" 2>/dev/null)"
  say "   $p = ${dm:-<unreadable>}"
done
[ -n "$dm" ] || always "   no /sys/module/*/parameters/download_mode: the driver's param is not exposed (unexpected)"

say "   /sys/kernel/dload: $(ls /sys/kernel/dload 2>/dev/null | tr '\n' ' ')"
if [ -r /sys/kernel/dload/emmc_dload ]; then
  say "   emmc_dload = $(cat /sys/kernel/dload/emmc_dload 2>/dev/null)   (dload *type*, not the enable flag)"
fi

# --- 1b. and here is the part the build tree cannot answer ---------------------------------------
#
# The driver runs set_dload_mode() at probe time, and it reports two outcomes that decide whether
# this hazard is *live* on this device or merely present in the source:
#
#   "unable to find DT imem DLOAD mode node"    -> the IMEM magics are skipped (the DT reading above)
#   "Failed to set secure DLOAD mode: N"        -> and the TCSR/SCM write FAILED, i.e. the flag is
#                                                  never set and a panic would reset normally
#
# Where to look for them: they are printed at ~t=2 s and the kmsg **ring wraps within about a
# minute** (docs 58), so `dmesg` no longer has them. The only place they still exist is the earliest
# snapshot the drain script took this boot -- or, failing that, the earliest one in the newest archive.

D=/userdata/zl1-kmsg
K="$D/keep"
wd=""

early="$(ls -tr "$D"/boot-*.log 2>/dev/null | head -1)"
# `-d` is not optional here: without it `ls -tr "$K"/boot-*/` lists the *contents* of each archive
# directory, so the loop below ran `ls -tr "boot-0001.log"*.log` from the current directory and the
# fallback silently found nothing. Caught by scripts/host/zl1-edl-postmortem-selftest.sh, whose C2
# scenario reaches the driver's most valuable line through this path only.
[ -n "$early" ] || early="$(ls -dtr "$K"/boot-*/ 2>/dev/null | while read -r d; do ls -tr "$d"*.log 2>/dev/null | head -1; done | head -1)"

if [ -n "$early" ] && [ -f "$early" ]; then
  say "   earliest snapshot available: $early"
  for s in "unable to find DT imem DLOAD mode node" "unable to find DT imem EDLOAD mode node" \
           "Failed to set secure DLOAD mode" "Failed to set secure EDLOAD mode"; do
    if grep -qaF "$s" "$early" 2>/dev/null; then
      always "   *** the driver logged: \"$s\""
      case "$s" in "Failed to set secure"*) wd=1 ;; esac
    else
      say "   not in that snapshot: \"$s\""
    fi
  done
else
  say "   no snapshot available to look for the driver's own probe-time messages"
  say "   (that is not a finding -- the ring wraps, so t=2 s only exists in a very early snapshot)"
fi

# --- 2. witness one: pstore / ramoops -----------------------------------------------------------

always ""
always "== 2. witness one: /sys/fs/pstore (survives the reset, if the bootloader preserves it)"

# THE PATTERNS, SPLIT INTO TWO SETS, because this instrument's ONE set once called a healthy boot dead
# (docs 161). The list was
#   Kernel panic|Unable to handle kernel|Internal error|BUG:|WDOG|watchdog|Going down for restart|PC is at|Call trace|Unable to mount root
# and TWO of its alternatives are printed by a boot that is entirely well:
#   `msm_watchdog 9830000.qcom,wdt: MSM Watchdog Initialized`   matches bare `watchdog`
#   the backtrace that follows every boot-time WARNING             matches `Call trace`
# Measured on keep/boot-0488bd3c-.../boot-84s.log -- a boot that ran on and produced later snapshots, so
# it provably did not die: WARNING: x6, Call trace: x6, and Kernel panic / Unable to handle kernel /
# Internal error / BUG: / Going down for restart / PC is at / WDOG: watchdog bite / watchdog bite -- all 0.
# The first time this script ran on a device (2026-09-25) it printed `*** contains a death signature ***`
# and `FOUND: a kernel oops/panic is on record` for exactly that, i.e. for a boot-time WARNING -- and the
# verdict was nearly written down as the attribution of the EDL trip. So:
#
#   * the two ambiguous words moved OUT of the verdict and into a COUNTED reading. `Call trace` x6 is a
#     fact about a log; "a kernel oops is on record" is a claim this script may only make when it can
#     also NAME the line it read it from.
#   * every match now names its pattern (`matched '<pattern>'`), because a verdict whose pattern is
#     anonymous cannot be audited -- and an unauditable verdict is how the false positive survived a
#     hand-written harness as well as a device run.
#
# `PC is at` is kept in the verdict set even though it measured 0 on the healthy boot: it is a genuine
# oops marker (the CPU's faulting instruction), it just is not printed by the six WARNINGs above.
SIG='Kernel panic|Unable to handle kernel|Internal error|BUG:|Going down for restart|Unable to mount root|PC is at|WDOG: watchdog bite|watchdog bite'

# Print the COUNT of everything a healthy boot also prints, so "no signature" is a reading rather than a
# blank. Never a verdict: these two strings are in every real log this project has.
amb_note() { # file
  _ct=$(grep -ac 'Call trace' "$1" 2>/dev/null); _ct=${_ct:-0}
  _wd=$(grep -aci 'watchdog' "$1" 2>/dev/null); _wd=${_wd:-0}
  say "   not-as-a-signature: 'Call trace' x$_ct, 'watchdog' x$_wd  (a healthy boot prints both --"
  say "   6 and 2 on the 84s snapshot of a boot that provably did not die; docs 161)"
}

found=0

if [ ! -d /sys/fs/pstore ]; then
  always "   /sys/fs/pstore does not exist: ramoops is not registered in this kernel. No witness here."
  rc=1
else
  files="$(ls -A /sys/fs/pstore 2>/dev/null)"
  if [ -z "$files" ]; then
    always "   EMPTY. No oops on record."
    say "   Read this carefully: empty does NOT mean \"the last boot did not panic\". The ramoops"
    say "   region has to survive the reset for this file to exist at all, and on this device that"
    say "   is the bootloader's decision, which we have never verified. An empty pstore disproves"
    say "   nothing; it only removes this witness. Witness two is section 3."
  else
    always "   $(ls -l /sys/fs/pstore | awk 'NR>1 {printf "%s (%s bytes)  ", $9, $5}')"
    for f in /sys/fs/pstore/*; do
      [ -f "$f" ] || continue
      say ""
      say "   --- $f"
      _sig=$(grep -aoE "$SIG" "$f" 2>/dev/null | head -1)
      if [ -n "$_sig" ]; then
        found=1
        always "   *** contains a death signature *** matched '$_sig'"
        grep -aE "$SIG" "$f" 2>/dev/null | head -12 | sed 's/^/   | /'
        say "   --- (the whole record)"
        if [ "$FULL" = 1 ]; then cat "$f"; else tail -n 80 "$f"; fi | sed 's/^/   | /'
      else
        say "   no death signature in it (printing the tail; --full for all of it)"
        amb_note "$f"
        if [ "$FULL" = 1 ]; then cat "$f"; else tail -n 20 "$f"; fi | sed 's/^/   | /'
      fi
    done
  fi
fi

# --- 3. witness two: the kmsg archive of the boot that died --------------------------------------
#
# install-kmsg-drain.sh copies /userdata/zl1-kmsg/boot-*.log into keep/boot-<prev boot_id>/ at the
# start of every boot, so after a UT -> EDL -> UT round trip the newest archive under keep/ IS the
# boot that died, named by its own id.

always ""
always "== 3. witness two: the kmsg archive under /userdata/zl1-kmsg"

# D and K were set in section 1b.

if [ ! -d "$K" ]; then
  always "   $K does not exist: the drain script is not installed on this device. No witness here."
  rc=1
else
  say "   current-boot-id : $(cat "$K/current-boot-id" 2>/dev/null)"
  if [ -r "$K/archive.log" ]; then
    say "   archive.log (tail):"
    tail -n 5 "$K/archive.log" 2>/dev/null | sed 's/^/   | /'
  else
    say "   archive.log      : absent"
  fi
  say "   archives (in 'ls -dt' order -- which THIS device's clock makes arbitrary, docs 161):"
  ls -dt "$K"/boot-*/ "$K"/bad-*/ 2>/dev/null | head -8 | while IFS= read -r d; do
    printf '   %s  (%s files, newest %s)\n' "$d" \
      "$(ls "$d" 2>/dev/null | wc -l)" \
      "$(ls -t "$d" 2>/dev/null | head -1)"
  done

  # WHICH ARCHIVE IS THE BOOT THAT DIED: named by the drain's own log, NOT by `ls -dt` (docs 161).
  # This device's clock is wrong, so every archive directory carries the same mtime and `ls -dt` returns
  # an arbitrary order -- measured on 2026-09-25 over the four archives present: it ranked
  # boot-0488bd3c first and put the boot that ACTUALLY died, boot-92165447, LAST. The drain appends
  # `uptime prev=<boot_id> files=N` at every boot and the id it names is the boot that ran before this
  # one, so the LAST such line is the archive to read. `ls -dt` stays as a fallback and the report says
  # which rule answered, because "the newest archive" is a claim about the clock until proven otherwise.
  newest=""; _rule=""
  if [ -r "$K/archive.log" ]; then
    # NEWEST FIRST, AND THE FIRST ONE WHOSE ARCHIVE IS STILL THERE. The last `prev=` line is NOT the rule:
    # an archive can already have been pruned by the newest-4 rule, and the line still names it -- measured
    # on 2026-09-25, where the last line named boot-61c4abf0 (the LIVE boot, filed by a mid-boot restart of
    # the collector) and that directory had been pruned, so "the last line" would have fallen through and
    # the fallback would have answered a question about the clock. What is wanted is the NEWEST line whose
    # archive exists, which is the boot that ran before this one.
    _an=$(awk '/prev=/{line[++n]=$0}
                END{for(i=n;i>=1;i--) if (match(line[i],/prev=[0-9a-fA-F-]+/))
                      print substr(line[i], RSTART+5, RLENGTH-5)}' "$K/archive.log" 2>/dev/null |
          while IFS= read -r c; do
            [ -n "$c" ] && [ -d "$K/boot-$c" ] && { printf '%s\n' "$c"; break; }
          done)
    [ -n "$_an" ] && { newest="$K/boot-$_an/"; _rule="archive.log, the newest entry whose archive still exists"; }
  fi
  if [ -z "$newest" ]; then
    newest="$(ls -dt "$K"/boot-*/ 2>/dev/null | head -1)"
    _rule="ls -dt -- and this device's clock is wrong, so that order is arbitrary"
  fi
  if [ -z "$newest" ]; then
    always "   no keep/boot-*/ archive yet -- nothing was carried forward, so there is no witness"
    say "   for the previous boot. (It exists from the *second* boot after the drain install.)"
    rc=1
  else
    cur="$(cat "$K/current-boot-id" 2>/dev/null)"
    say "   chosen by: $_rule"
    case "$newest" in
    *"$cur"*) say "   and it is THIS boot's id -- the previous boot was not archived (a mid-boot restart"
               say "   of the collector files the live boot under its own id; docs 161). No candidate here." ;;
    *) say "   $(basename "$newest") is a *previous* boot: that is the candidate." ;;
    esac
    # full path, not the basename: the greps below do not run from inside the archive directory
    last="$newest$(ls -t "$newest" 2>/dev/null | head -1)"
    [ "$last" = "$newest" ] && last=""
    if [ -n "$last" ]; then
      say ""
      say "   --- $last  (the tail of that boot)"
      _sig=$(grep -aoE "$SIG" "$last" 2>/dev/null | head -1)
      if [ -n "$_sig" ]; then
        found=1
        always "   *** contains a death signature *** matched '$_sig'"
        grep -aE "$SIG" "$last" 2>/dev/null | head -12 | sed 's/^/   | /'
        say "   --- (the whole record)"
      else
        say "   no death signature; the last $( [ "$FULL" = 1 ] && echo all || echo 30) lines:"
        amb_note "$last"
      fi
      if [ "$FULL" = 1 ]; then cat "$last"; else tail -n 30 "$last"; fi | sed 's/^/   | /'
    fi
  fi
fi

# --- 4. verdict ---------------------------------------------------------------------------------

always ""
always "== verdict"

if [ "$found" = 1 ]; then
  always "   FOUND: a kernel oops/panic is on record, in the witness marked above -- the pattern it"
  always "   matched is named on the *** line, and THAT is the string to check by eye before believing"
  always "   this verdict. If the named pattern is not a panic in the line it matched, this is a false"
  always "   positive and the sentence below does not apply to your boot."
  always "   With download_mode=$dm and a forced watchdog bite on panic, that death resets the SoC with"
  always "   the dload flag set -- which is EDL. Check the timestamp and the content before calling it"
  always "   *the* cause (pstore keeps the most recent oops, not necessarily the one you want), but it"
  always "   is the first attribution this project has ever had for the 2026-09-23 trip: docs 80 section"
  always "   7 recorded the state and never the cause. Start from the oops itself, not from this line."
elif [ "$dm" = 1 ] && [ "$wd" = 1 ]; then
  say "   No oops on record. The config and download_mode say the hazard is armed -- BUT the driver"
  say "   logged that the secure/TZ write FAILED, so the dload flag is probably never actually set:"
  say "   a panic would then reset normally and this path is inert on this device. That single line"
  say "   (\"Failed to set secure DLOAD mode\") is the most valuable thing this script can find -- it"
  say "   downgrades a hazard, and it is the one thing the build tree cannot answer."
elif [ "$dm" = 1 ]; then
  say "   No oops on record -- and the hazard is ARMED (download_mode=1, watchdog bite forced on panic),"
  say "   so a panic *would* have gone to EDL. No witness is not evidence of no panic: pstore may not"
  say "   survive the reset on this device (never verified) and the kmsg ring wraps in ~1 minute."
  say "   Still unattributed. The other known entry is the deliberate one (\"reboot edl\" ->"
  say "   enable_emergency_dload_mode()); the UVLO-dload path is off (dload_on_uvlo defaults to false)."
else
  say "   No oops on record, and download_mode is ${dm:-unreadable}: the panic path is not armed as"
  say "   compiled, so a panic would have reset normally. Look outside the kernel -- but note the"
  say "   witnesses above may simply be unavailable on this device, which is not the same as empty."
fi

say ""
say "   What this does NOT prove: it does not prove pstore survives a reset on this device (nothing"
say "   has ever read it back across one), it cannot see a death that left no witness, and it says"
say "   nothing about *why* the kernel would have panicked -- for that, the oops itself is the"
say "   starting point, not the answer."

exit $rc
