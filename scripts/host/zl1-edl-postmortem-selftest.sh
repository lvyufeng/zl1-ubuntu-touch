#!/bin/sh
# zl1 EDL post-mortem -- offline self-test. Host-side, touches no device.
#
# Why this exists: `scripts/device/zl1-edl-postmortem.sh` is the FIRST thing to run once the device is
# back from EDL (docs 86), and the boot it runs on is the only one where pstore is still readable --
# the kmsg ring wraps in about a minute and a reboot destroys the rest. It is also the script with the
# worst accident in this repo's history: a backtick inside a double-quoted `say` was command
# substitution, so the first version EXECUTED `reboot edl` while merely printing a report. On the
# phone that would have put the device straight back into EDL.
#
# So this harness runs the real script (sed-rewritten so its device paths point into a fake root)
# against seven synthetic device states, and checks three things per scenario: the verdict text, the
# exit code, and that nothing was executed or written. Read-only is a claim; this is the check.
#
# Usage: zl1-edl-postmortem-selftest.sh [--keep]
#   --keep   leave the fake root, the stub bin/ and the rewritten script for inspection
#
# Exit codes: 0 every scenario behaved; 1 something did not.

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
SRC="$HERE/../device/zl1-edl-postmortem.sh"
[ -r "$SRC" ] || { echo "cannot read $SRC" >&2; exit 2; }

W=${TMPDIR:-/tmp}/zl1-edlpm-selftest
FR="$W/fake"
STUB="$W/bin"
MARK="$W/EXECUTED"
rm -rf "$W"; mkdir -p "$FR" "$STUB" || exit 2

# --- the script under test, with its device paths pointed into the fake root ---------------------
#
# Only the operational occurrences are rewritten (the ones that read); a path that appears inside a
# printed string is left alone, so the report still reads like the report.

sed -e "s#< /proc/device-tree/model#< $FR/proc/device-tree/model#g" \
    -e "s#/proc/uptime#$FR/proc/uptime#g" \
    -e "s#/proc/sys/kernel/random/boot_id#$FR/proc/sys/kernel/random/boot_id#g" \
    -e "s#zcat /proc/config.gz#zcat $FR/proc/config.gz#g" \
    -e "s#\[ -r /proc/config.gz \]#[ -r $FR/proc/config.gz ]#g" \
    -e "s#/sys/module/\*/parameters/download_mode#$FR/sys/module/*/parameters/download_mode#g" \
    -e "s#/sys/kernel/dload#$FR/sys/kernel/dload#g" \
    -e "s#/sys/fs/pstore#$FR/sys/fs/pstore#g" \
    -e "s#^D=/userdata/zl1-kmsg#D=$FR/userdata/zl1-kmsg#" \
    "$SRC" > "$W/check.sh" || exit 2
sh -n "$W/check.sh" || { echo "the rewritten copy does not parse -- fix that first" >&2; exit 2; }
grep -q "^D=$FR/userdata/zl1-kmsg" "$W/check.sh" || { echo "the D= rewrite did not apply" >&2; exit 2; }

# --- the command guard --------------------------------------------------------------------------
#
# Nothing the post-mortem needs is in this list; everything in this list would change the device, or
# start something, or re-enter EDL. Each stub records its invocation instead of running, so a
# backtick accident shows up as a marker file rather than as an action.

for c in reboot poweroff halt qdl QSaharaServer fh_loader firehose fastboot adb dd mount umount \
         tee mkfs.ext4 mkfs.vfat systemctl nsenter lxc-start lxc-stop i2cset i2cget scp ssh flash; do
  printf '#!/bin/sh\nprintf "%%s %%s\\n" "$(basename "$0")" "$*" >> %s\nexit 0\n' "$MARK" > "$STUB/$c"
  chmod +x "$STUB/$c"
done

# --- the device states ---------------------------------------------------------------------------

setup() { # $1 = scenario name
  rm -rf "$FR/proc" "$FR/sys" "$FR/userdata"
  mkdir -p "$FR/proc/device-tree" "$FR/proc/sys/kernel/random" "$FR/sys" "$FR/userdata"
  printf 'LE_ZL1\x00' > "$FR/proc/device-tree/model"
  printf '412.55 300.10\n' > "$FR/proc/uptime"
  printf 'c0ffee00-1234-5678-9abc-def012345678\n' > "$FR/proc/sys/kernel/random/boot_id"
  mkdir -p "$FR/sys/module/msm_poweroff/parameters"
  printf '1\n' > "$FR/sys/module/msm_poweroff/parameters/download_mode"
  mkdir -p "$FR/sys/kernel/dload"
  printf 'emmc\n' > "$FR/sys/kernel/dload/emmc_dload"
  # gzip a plausible /proc/config.gz
  { printf 'CONFIG_POWER_RESET_MSM=y\nCONFIG_MSM_DLOAD_MODE=y\n'
    printf 'CONFIG_MSM_FORCE_WDOG_BITE_ON_PANIC=y\nCONFIG_PSTORE_RAM=y\n'
    printf 'CONFIG_PSTORE_CONSOLE=y\nCONFIG_IKCONFIG_PROC=y\n'; } > "$W/cfg.txt"
  gzip -c "$W/cfg.txt" > "$FR/proc/config.gz"

  case "$1" in
  A)  # a real oops in pstore, and the drain installed (both witnesses available -> exit 0)
      mkdir -p "$FR/sys/fs/pstore" "$FR/userdata/zl1-kmsg/keep/boot-live11"
      printf 'live11\n' > "$FR/userdata/zl1-kmsg/keep/current-boot-id"
      printf 'nothing interesting\n' > "$FR/userdata/zl1-kmsg/keep/boot-live11/boot-0001.log"
      { printf 'Panic at PC : 0xffffff8008123456\n'
        printf 'Kernel panic - not syncing: Unable to handle kernel paging request\n'
        printf 'PC is at zl1_do_something+0x44/0x100\nCall trace:\n'; } \
        > "$FR/sys/fs/pstore/dmesg-ramoops-0"
      ;;
  B)  # pstore registered but empty; the kmsg archive carries it
      mkdir -p "$FR/sys/fs/pstore" "$FR/userdata/zl1-kmsg/keep/boot-dead00"
      printf 'live11\n' > "$FR/userdata/zl1-kmsg/keep/current-boot-id"
      { printf '121.10s wifi up\n'
        printf '290.40s WDOG: watchdog bite, going down for restart\n'; } \
        > "$FR/userdata/zl1-kmsg/keep/boot-dead00/boot-last.log"
      ;;
  C)  # the driver's own probe-time line in THIS boot's earliest snapshot
      mkdir -p "$FR/sys/fs/pstore" "$FR/userdata/zl1-kmsg/keep/boot-live11"
      printf 'Failed to set secure DLOAD mode: -12\n' > "$FR/userdata/zl1-kmsg/boot-0001.log"
      printf 'nothing interesting\n' > "$FR/userdata/zl1-kmsg/keep/boot-live11/boot-0002.log"
      ;;
  C2) # the same line, but only in the newest ARCHIVE (the fallback at the `ls -tr` line)
      mkdir -p "$FR/sys/fs/pstore" "$FR/userdata/zl1-kmsg/keep/boot-prev01"
      { printf 'unable to find DT imem DLOAD mode node\n'
        printf 'Failed to set secure DLOAD mode: -12\n'; } \
        > "$FR/userdata/zl1-kmsg/keep/boot-prev01/boot-0002.log"
      ;;
  D)  # armed, nothing anywhere
      mkdir -p "$FR/sys/fs/pstore" "$FR/userdata/zl1-kmsg/keep/boot-prev01"
      printf 'nothing interesting\n' > "$FR/userdata/zl1-kmsg/keep/boot-prev01/boot-0003.log"
      ;;
  E)  # not armed: download_mode = 0
      mkdir -p "$FR/sys/fs/pstore" "$FR/userdata/zl1-kmsg/keep/boot-prev01"
      printf '0\n' > "$FR/sys/module/msm_poweroff/parameters/download_mode"
      printf 'nothing interesting\n' > "$FR/userdata/zl1-kmsg/keep/boot-prev01/boot-0004.log"
      ;;
  F)  # no witnesses at all: both directories missing
      ;;
  G)  # not the zl1
      printf 'Xiaomi\x00' > "$FR/proc/device-tree/model"
      ;;
  I)  # WHICH ARCHIVE IS THE BOOT THAT DIED, WHEN `ls -dt` AND THE DRAIN'S LOG DISAGREE (docs 161).
      # This device's clock is wrong, so EVERY archive directory carries the same mtime and `ls -dt` is an
      # arbitrary order -- measured on the device, where it ranked boot-0488bd3c first and put the boot
      # that actually died, boot-92165447, LAST. The rule is the drain's own log: the NEWEST `prev=` entry
      # whose archive still exists. So the fixture has to make the two rules disagree, and it also carries
      # the case that broke the first version of the rule -- a `prev=` line naming a boot whose archive has
      # already been pruned by the newest-4 rule, so "the last line" is not the answer either.
      #   mtime order (what `ls -dt` answers):  boot-old01   <- written LAST, so it ranks first, and it is WRONG
      #   the log, oldest first:                old01, dead00, gone99   <- gone99 has NO directory
      #   the only right answer:                dead00
      mkdir -p "$FR/sys/fs/pstore" "$FR/userdata/zl1-kmsg/keep/boot-dead00"
      printf 'live11\n' > "$FR/userdata/zl1-kmsg/keep/current-boot-id"
      { printf '121.10s wifi up\n'
        printf '290.40s WDOG: watchdog bite, going down for restart\n'; } \
        > "$FR/userdata/zl1-kmsg/keep/boot-dead00/boot-last.log"
      printf '10 prev=old01 files=1\n20 prev=dead00 files=1\n30 prev=gone99 files=1\n' \
        > "$FR/userdata/zl1-kmsg/keep/archive.log"
      # THE MTIMES ARE SET EXPLICITLY, not left to the order the statements run in: the two directories
      # would otherwise be created within the same millisecond and `ls -dt` would break the tie
      # arbitrarily -- which is the same broken clock this whole fixture is about. Measured after the
      # first version did exactly that: 'ls -dt' ranked boot-dead00 first, so the state passed its
      # assertions while being unable to tell the two rules apart.
      mkdir -p "$FR/userdata/zl1-kmsg/keep/boot-old01"
      printf 'nothing interesting\n' > "$FR/userdata/zl1-kmsg/keep/boot-old01/boot-0001.log"
      touch -t 202001010000.00 "$FR/userdata/zl1-kmsg/keep/boot-dead00"
      touch -t 202101010000.00 "$FR/userdata/zl1-kmsg/keep/boot-old01"
      ;;
  H)  # A HEALTHY BOOT, IN THE SHAPE A REAL BOOT LOG ACTUALLY HAS.
      # This is the fixture the harness was missing, and it is the whole of docs 161's section 5. Every
      # other "clean" state above is a file holding one invented line, and a real kernel log is not that:
      # measured on keep/boot-0488bd3c-.../boot-84s.log -- a boot that provably did not die, because it
      # produced five later snapshots -- it carries `WARNING:` x6 each followed by `Call trace:`, plus
      # the watchdog driver's own two init lines. `watchdog` and `Call trace` were both in the verdict
      # pattern, so on 2026-09-25 the instrument printed `*** contains a death signature ***` and
      # `FOUND: a kernel oops/panic is on record` for a healthy boot -- and that verdict was nearly
      # written down as the attribution of the EDL trip. A negative fixture that cannot reach the
      # detector proves nothing about the detector; this one is the real thing.
      mkdir -p "$FR/sys/fs/pstore" "$FR/userdata/zl1-kmsg/keep/boot-dead00"
      printf 'live11\n' > "$FR/userdata/zl1-kmsg/keep/current-boot-id"
      { printf '[    0.210092] msm_watchdog 9830000.qcom,wdt: wdog absent resource not present\n'
        printf '[    0.210400] msm_watchdog 9830000.qcom,wdt: MSM Watchdog Initialized\n'
        n=0
        while [ "$n" -lt 6 ]; do
          printf '[    1.612%03d] WARNING: CPU: 2 PID: 1 at drivers/clk/qcom/clk-rcg2.c:114 clk_rcg2_set_rate+0x1c/0x40\n' "$n"
          printf '[    1.613%03d] Call trace:\n' "$n"
          n=$((n + 1))
        done
        printf '[   70.246562] healthd: battery l=2(0) v=3899 t=40.2 h=2 st=2 otg=0 c=-1475(0) chg=USB_DCP\n'
        printf '[   81.170899] zl1-v63-monitor: event tick=26 uptime=80.82 state=DISCONNECTED functions=rndis\n'
      } > "$FR/userdata/zl1-kmsg/keep/boot-dead00/boot-last.log"
      ;;
  esac
}

# --- assertions ---------------------------------------------------------------------------------

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }

snapshot() { find "$FR" -printf '%p %s %T@\n' 2>/dev/null | sort; }

run() { # $1 = scenario; sets out, rc
  setup "$1"
  rm -f "$MARK"
  before="$(snapshot)"
  out=$(PATH="$STUB:$PATH" timeout 60 sh "$W/check.sh" 2>&1); rc=$?   # rc 124 = it hung
  after="$(snapshot)"
  if [ -f "$MARK" ]; then
    bad "$1: a mutating command was EXECUTED: $(tr '\n' ';' < "$MARK")"
  else
    ok "$1: no mutating command was invoked (23 stubs armed)"
  fi
  if [ "$before" = "$after" ]; then
    ok "$1: nothing under the device paths changed"
  else
    bad "$1: the fake root changed:"
    printf '%s\n' "$before" > "$W/before.txt"; printf '%s\n' "$after" > "$W/after.txt"
    diff "$W/before.txt" "$W/after.txt" | sed 's/^/        /' | head -6
  fi
}

want() { # $1 scenario, $2 wanted rc, $3 wanted substring, $4 description
  if [ "$rc" = "$2" ]; then ok "$1: exit $rc ($4)"; else bad "$1: exit $rc, wanted $2 ($4)"; fi
  case "$out" in
  *"$3"*) ok "$1: verdict says: $4" ;;
  *) bad "$1: the verdict never says [$3] ($4)"
     printf '%s\n' "$out" | sed -n '/== verdict/,$p' | head -6 | sed 's/^/        /' ;;
  esac
}

notwant() { # $1 scenario, $2 forbidden substring, $3 description
  case "$out" in
  *"$2"*) bad "$1: the verdict DOES say [$2] -- $3" ;;
  *) ok "$1: it does not say [$2] ($3)" ;;
  esac
}

echo "zl1 EDL post-mortem -- offline self-test"
echo "  script under test: $SRC"
echo "  fake root:         $FR"
echo

# NAMING THE PATTERN IS THE ASSERTION, not a decoration: the false positive on 2026-09-25 was a match
# whose pattern nobody could see. `matched 'Kernel panic'` makes a wrong attribution visible on the line
# it read, which is the only thing that separates this verdict from "the file contained some word".
echo "== A: an oops in pstore (the primary witness) =="
run A
want A 0 "FOUND: a kernel oops/panic is on record" "attributed from pstore"
want A 0 "matched 'Kernel panic'" "and the FOUND names the pattern it matched (docs 161)"

echo
echo "== B: pstore empty, the kmsg archive carries the death =="
run B
want B 0 "FOUND: a kernel oops/panic is on record" "attributed from the second witness"
want B 0 "matched 'WDOG: watchdog bite'" "the kmsg witness names its pattern too"

echo
echo "== C: the driver's own probe-time line in this boot's earliest snapshot =="
run C
want C 0 "downgrades a hazard" "armed but the TZ write failed -> the hazard is inert"

echo
echo "== C2: the same line, reachable only through the keep/ fallback =="
run C2
want C2 0 "downgrades a hazard" "the fallback snapshot lookup works"

echo
echo "== D: armed, and no witness anywhere =="
run D
want D 0 "Still unattributed" "no witness is not evidence of no panic"

echo
echo "== E: download_mode = 0 -- the path is not armed as compiled =="
run E
want E 0 "the panic path is not armed as" "the unarmed branch"

echo
echo "== F: no pstore directory and no kmsg directory at all =="
run F
want F 1 "No witness is not evidence of no panic" "exit 1, and the verdict still refuses to conclude"
notwant F "FOUND" "it must not invent an attribution"
notwant F "did not panic" "it must not read an unavailable witness as an absence"

echo
echo "== G: not the zl1 =="
run G
want G 2 "not LE_ZL1" "stops before reading anything as ours"

echo
echo "== I: two archives, and the one the drain names is not the one the clock ranks first (docs 161) =="
# NOTE: the `*` in the two assertions below is a LITERAL star, not a glob. `want`/`notwant` match with
# `case "$out" in *"$3"*)` and a QUOTED expansion is not re-read as a pattern, so a backslash written here
# would have to be present in the output -- which is how the first version of these two lines passed
# vacuously (the forbidden string was `\*previous\*` and no such string can ever be printed).
run I
# THE FIXTURE HAS TO DISAGREE WITH ITSELF, or this state proves nothing about the rule: `ls -dt` must rank
# boot-old01 first (the wrong boot) while the log names boot-dead00. If the mtime order ever came out the
# other way the assertions below would pass for the wrong reason, so it is checked rather than assumed.
ISETUP=$(ls -dt "$FR/userdata/zl1-kmsg/keep"/boot-*/ 2>/dev/null | sed -n 1p)
case "$ISETUP" in
*"$FR/userdata/zl1-kmsg/keep/boot-old01/") ok "I: the fixture does disagree -- 'ls -dt' ranks boot-old01 first, which is the wrong one" ;;
*) bad "I: 'ls -dt' ranked '$(basename "${ISETUP:-none}")', not boot-old01, so this state cannot tell the two rules apart" ;;
esac
want I 0 "chosen by: archive.log" "the archive is chosen by the drain's own log, not by the clock"
want I 0 "boot-dead00 is a *previous* boot" "and it is the boot the log names"
want I 0 "matched 'WDOG: watchdog bite'" "so the death in THAT archive is the one reported"
notwant I "boot-old01 is a *previous*" "the archive the clock ranks newest is NOT offered as the candidate"
notwant I "chosen by: ls -dt" "and the clock-based fallback is not the rule that answered"

echo
echo "== H: a HEALTHY boot, in the shape a real boot log has (docs 161) =="
run H
want H 0 "No oops on record" "six WARNINGs with their Call traces, and the watchdog's own init lines, are NOT a death"
notwant H "contains a death signature" "the two strings EVERY healthy boot prints are out of the verdict pattern"
want H 0 "not-as-a-signature: 'Call trace' x6, 'watchdog' x2" \
  "and they are printed as COUNTS instead, so 'no signature' is a reading rather than a blank"

echo
echo "== the count the health check cites for this harness =="
# THE DRIFT GUARD (docs 110, enforced tree-wide by cli-usage's section 4d): the health check names this
# harness WITH a hand-typed check count, and a hand-typed count is exactly the kind of claim that goes
# stale in silence. This harness is newly NAMED by the page in docs 161, so it now has to check its own
# citation -- `total` is PASS+FAIL+1 because the check below is itself a check.
HEALTH="$HERE/zl1-health-check.sh"
if [ -r "$HEALTH" ]; then
  match=$(tr '\n' ' ' < "$HEALTH" | grep -oE 'zl1-edl-postmortem-selftest\.sh[^0-9]*[0-9]+ checks' | sed -n 1p)
  cited=$(printf '%s\n' "$match" | sed -n 's/.*[^0-9]\([0-9][0-9]*\) checks$/\1/p')
  total=$((PASS + FAIL + 1))
  if [ -z "$cited" ]; then
    bad "zl1-health-check.sh does not cite this harness's count -- either the citation is gone or its wording changed"
  elif [ "$cited" = "$total" ]; then
    ok "the health check cites $cited checks, and this run has exactly that many"
  else
    bad "the health check cites $cited checks but this harness has $total -- fix host/zl1-health-check.sh"
  fi
else
  bad "cannot read $HEALTH -- its citations are unchecked"
fi

echo
echo "pass=$PASS fail=$FAIL"
[ "$KEEP" = 1 ] || rm -rf "$W"
[ "$FAIL" = 0 ]
