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
  --help|-h) sed -n '2,18p' "$0"; exit 0 ;;
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
  out=$(PATH="$STUB:$PATH" sh "$W/check.sh" 2>&1); rc=$?
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

echo "== A: an oops in pstore (the primary witness) =="
run A
want A 0 "FOUND: a kernel oops/panic is on record" "attributed from pstore"

echo
echo "== B: pstore empty, the kmsg archive carries the death =="
run B
want B 0 "FOUND: a kernel oops/panic is on record" "attributed from the second witness"

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
echo "pass=$PASS fail=$FAIL"
[ "$KEEP" = 1 ] || rm -rf "$W"
[ "$FAIL" = 0 ]
