#!/bin/sh
# zl1 modem mount, offline -- self-test.
#
# Host-side, touches no device, and it cannot: the subject reads two IMAGE FILES. So the fixtures ARE
# images -- a real gzip'd cpio written by a helper, and a real ext4 filesystem built with mke2fs -d --
# because a fixture whose shape is a directory of text files would exercise neither parser.
#
# What is under test:
#
#   1. THE FOUR STATES OF THE VERDICT, as four device images: no fstab at all (the reading this project
#      expects), an fstab with a line for the modem, an fstab with none, and an image this instrument
#      cannot read. The last one must be UNREADABLE and must claim NOTHING.
#   2. THE MECHANISM IS QUOTED, NOT SUMMARISED. Section 1 of the subject prints the two call sites with
#      their line numbers out of the boot image's own `scripts/halium`, so the fixture's halium file is
#      what those lines come from -- and the assertions are on the lines, not on the fixture's file name.
#   3. THE cpio WALK, which is where this instrument really was wrong first. The `newc` rule is that NULs
#      follow the pathname so that the fixed header PLUS the pathname is a multiple of four; getting it
#      wrong does not fail, it returns a ONE-ENTRY listing. That is mutation (a), and the shipped script
#      is asserted against the same fixture it reddens.
#   4. IT IS READ-ONLY. Static, over the shipped file: no `debugfs -w`, no `mount`, no `fastboot`, no
#      `dd of=`, no downloader name. This instrument's whole claim is that it reads files.
#
# Usage: zl1-modem-mount-selftest.sh [--keep]
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
SRC="$HERE/zl1-modem-mount.sh"
[ -r "$SRC" ] || { echo "cannot read $SRC" >&2; exit 2; }
for t in python3 debugfs mke2fs gzip; do
  command -v "$t" >/dev/null 2>&1 || { echo "this harness needs $t to build its fixtures" >&2; exit 2; }
done

W=${TMPDIR:-/tmp}/zl1-modem-mount-selftest
rm -rf "$W"
mkdir -p "$W/fx" "$W/out" || exit 2
BASH_BIN=$(command -v bash) || exit 2

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$(( PASS + 1 )); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$(( FAIL + 1 )); printf 'FAIL  %s\n' "$1"; }
skip() { SKIP=$(( SKIP + 1 )); printf 'SKIP  %s\n' "$1"; }
want()   { if printf '%s' "$2" | grep -qF -- "$1"; then ok "$3"; else bad "$3"; printf '        | wanted: %s\n' "$1"; fi; }
wantre() { if printf '%s' "$2" | grep -qE -- "$1"; then ok "$3"; else bad "$3"; printf '        | wanted a match for: %s\n' "$1"; fi; }
notwant(){ if printf '%s' "$2" | grep -qF -- "$1"; then bad "$3"; printf '        | did NOT want: %s\n' "$1"; else ok "$3"; fi; }
rc_is()  { if [ "$RC" = "$1" ]; then ok "$2"; else bad "$2 (rc=$RC, wanted $1)"; printf '%s\n' "$OUT" | sed 's/^/        | /'; fi; }

# --- the fixture builders -------------------------------------------------------------------------
# One python helper, used for both directions: write a cpio, and read one back for the assertions. It is
# emitted ONCE here and the fixture images are built by calling it, so the harness and the subject agree
# about the format only because both implement the spec -- not because they share code.
cat > "$W/cpio.py" <<'PY'
import sys, gzip, os
def pad4(n):
    return (n + 3) & ~3
def data_off(namesize):
    return 110 + namesize + ((4 - ((110 + namesize) % 4)) % 4)
def header(name, mode, size):
    n = name.encode() + b'\x00'
    f = b'070701' + b'%08X' % 0 + b'%08X' % mode + b'%08X' % 0 + b'%08X' % 0
    f += b'%08X' % 1 + b'%08X' % 0 + b'%08X' % size + b'%08X' % 0 + b'%08X' % 0
    f += b'%08X' % 0 + b'%08X' % 0 + b'%08X' % len(n) + b'%08X' % 0
    assert len(f) == 110, len(f)
    blob = f + n
    blob += b'\x00' * ((4 - (len(blob) % 4)) % 4)
    return blob
def write(files, out):
    buf = b''
    for name, mode, data in files:
        if isinstance(data, str):
            data = data.encode()
        buf += header(name, mode, len(data)) + data + b'\x00' * ((4 - (len(data) % 4)) % 4)
    # trailer
    buf += header('TRAILER!!!', 0, 0)
    with open(out, 'wb') as fh:
        fh.write(gzip.compress(buf, 9))
if __name__ == '__main__':
    what = sys.argv[1]
    if what == 'list':          # list MODES: the harness' own reader, independent of the subject's
        d = open(sys.argv[2], 'rb').read()
        try:
            out = gzip.decompress(d)
        except Exception:
            import zlib
            dz = zlib.decompressobj(16 + zlib.MAX_WBITS)
            out = dz.decompress(d) + dz.flush()
        i = 0
        while i + 110 <= len(out):
            hdr = out[i:i+110]
            if not hdr.startswith(b'070701'):
                break
            size = int(hdr[54:62], 16); nsize = int(hdr[94:102], 16)
            name = out[i+110:i+110+nsize-1].decode('utf-8', 'replace')
            if name.startswith('./'):
                name = name[2:]
            if name == 'TRAILER!!!':
                break
            print(name)
            i = i + data_off(nsize) + pad4(size)
PY

# build_boot IMG HALIUM_TEXT -- a boot image-shaped file: one gzip'd cpio carrying scripts/halium.
build_boot() {
  python3 - "$1" "$2" <<'PY'
import sys, os
sys.path.insert(0, os.environ['FX'])
import cpio
txt = open(sys.argv[2]).read()
cpio.write([('scripts', 0o040755, ''), ('scripts/halium', 0o100755, txt)], sys.argv[1])
PY
}
# build_boot_broken IMG -- a boot image whose cpio carries no scripts/halium at all.
build_boot_broken() {
  python3 - "$1" <<'PY'
import sys, os
sys.path.insert(0, os.environ['FX'])
import cpio
cpio.write([('scripts', 0o040755, ''), ('scripts/other', 0o100755, '#!/bin/sh\n')], sys.argv[1])
PY
}
# build_android IMG RAMDISK  -- an ext4 image with /boot/android-ramdisk.img in it (or without, if the
# second argument is the word NONE). mke2fs -d populates it, so the subject's debugfs call really lands.
build_android() {
  d="$W/tree-$$.$1-$(date +%s%N)"
  rm -rf "$d"; mkdir -p "$d/boot"
  [ "$2" = NONE ] || cp "$2" "$d/boot/android-ramdisk.img"
  rm -f "$1"
  dd if=/dev/zero of="$1" bs=1M count=8 status=none
  mke2fs -F -q -t ext4 -d "$d" "$1" >/dev/null 2>&1
  rm -rf "$d"
}
# build_ramdisk OUT [fstab-text-file] -- the android ramdisk. With no second argument it carries NO fstab,
# which is the shape the real one has; the interesting entries are copied from the real listing.
build_ramdisk() {
  python3 - "$1" "$2" <<'PY'
import sys, os
sys.path.insert(0, os.environ['FX'])
import cpio
files = [
    ('.', 0o040755, ''),
    ('init', 0o100750, '# android init\n'),
    ('init.rc', 0o100640, 'on early-init\n'),
    ('vendor', 0o040755, ''),
    ('firmware', 0o120777, '/vendor/firmware_mnt'),
    ('dsp', 0o120777, '/vendor/dsp'),
    ('bt_firmware', 0o120777, '/vendor/bt_firmware'),
    ('system', 0o040755, ''),
]
if len(sys.argv) > 2 and sys.argv[2] != '-':
    files.append(('fstab.qcom', 0o100640, open(sys.argv[2]).read()))
cpio.write(files, sys.argv[1])
PY
}

export FX="$W/fx"
cp "$W/cpio.py" "$FX/cpio.py"

HALIUM="$W/halium.fixture"
cat > "$HALIUM" <<'EOF'
mount_android_partitions() {
	fstab=$1
	mount_root=$2
	real_userdata=$3
	tell_kmsg "checking fstab $fstab for additional mount points"
	cat ${fstab} | while read line; do
		set -- $line
		label=$(echo $1 | awk -F/ '{print $NF}')
		mkdir -p ${mount_root}/$2
		mount $path ${mount_root}/$2 -t $3 -o $4
	done
}
case "$1" in
	android) mount_android_partitions "${rootmnt}/fstab*" ${rootmnt} /tmpmnt ;;
	*) mount_android_partitions "${rootmnt}/var/lib/lxc/android/rootfs/fstab*" ${rootmnt}/android ${rootmnt}/userdata ;;
esac
EOF
printf '# a vendor fstab with a modem line\n/dev/block/bootdevice/by-name/modem  vendor/firmware_mnt  vfat  ro\n' > "$W/fstab-modem.txt"
printf '# a vendor fstab about something else\n/dev/block/bootdevice/by-name/persist  persist  ext4  ro\n' > "$W/fstab-other.txt"

RD_NONE="$W/rd-none.img";   build_ramdisk "$RD_NONE" -
RD_MODEM="$W/rd-modem.img"; build_ramdisk "$RD_MODEM" "$W/fstab-modem.txt"
RD_OTHER="$W/rd-other.img"; build_ramdisk "$RD_OTHER" "$W/fstab-other.txt"
IMG_RD_NONE="$W/system-none.img";   build_android "$IMG_RD_NONE" "$RD_NONE"
IMG_RD_MODEM="$W/system-modem.img"; build_android "$IMG_RD_MODEM" "$RD_MODEM"
IMG_RD_OTHER="$W/system-other.img"; build_android "$IMG_RD_OTHER" "$RD_OTHER"
IMG_NO_BOOT="$W/system-noboot.img"; build_android "$IMG_NO_BOOT" NONE
BOOT_OK="$W/boot-ok.img";           build_boot "$BOOT_OK" "$HALIUM"
BOOT_BROKEN="$W/boot-broken.img";   build_boot_broken "$BOOT_BROKEN"
# A rootfs fixture with a /vendor symlink, so section 4 is read rather than skipped.
mkdir -p "$W/roottree/var/lib/lxc/android/rootfs"
ln -s /android/vendor "$W/roottree/vendor"
ROOTFS_FX="$W/rootfs.img"
rm -f "$ROOTFS_FX"; dd if=/dev/zero of="$ROOTFS_FX" bs=1M count=8 status=none
mke2fs -F -q -t ext4 -d "$W/roottree" "$ROOTFS_FX" >/dev/null 2>&1

run() { # args...
  env -u ZL1_BOOT_IMG -u ZL1_ANDROID_IMG -u ZL1_ROOTFS_IMG \
    "$BASH_BIN" "$SRC" "$@" > "$W/out/last.txt" 2>&1
  RC=$?
  OUT=$(cat "$W/out/last.txt")
}
# The common case: the fixture boot image, one of the fixture system images, and an unreadable rootfs so
# the run is fast. Section 4 has its own scenario with a real one.
r() { run --boot "$BOOT_OK" --android "$1" --rootfs "$W/does-not-exist.img"; }

echo "zl1 modem mount -- offline self-test"
echo "  subject: $SRC"
echo

# ==================================================================================================
echo "== 1. its own manual, and its arguments =="
# ==================================================================================================
run --help; RC=$?
rc_is 0 "--help exits 0"
want 'halium'                "$OUT" "and prints this script's own header"
want 'THE LOOP IS EMPTY'     "$OUT" "including the verdicts it can reach"
want 'never writes, never mounts' "$OUT" "and what it never does"
run --nonsense; rc_is 2 "an unknown argument is refused"
# `${2?}` makes bash exit 1 with the message; what matters is that it is refused and NAMED, not the code.
run --boot; if [ "$RC" != 0 ] && printf '%s' "$OUT" | grep -qF -- '--boot needs a path'; then
  ok "an argument missing its value is refused, and the flag is named"
else bad "an argument with no value was not refused by name (rc=$RC)"; fi

# ==================================================================================================
echo
echo "== 2. the refusals that come before any reading =="
# ==================================================================================================
run --boot "$W/nope.img" --android "$IMG_RD_NONE"; rc_is 2 "a missing boot image is refused"
want 'REFUSED' "$OUT" "with REFUSED, not a verdict"
want 'whole input' "$OUT" "and the reason: the images ARE the input"
run --boot "$BOOT_OK" --android "$W/nope.img"; rc_is 2 "a missing android image is refused"

# A boot image whose cpio has no scripts/halium: the mechanism cannot be read, so nothing is claimed.
r "$IMG_RD_NONE" >/dev/null 2>&1   # warm-up so the next run is the interesting one
run --boot "$BOOT_BROKEN" --android "$IMG_RD_NONE" --rootfs "$W/x"; rc_is 3 "a boot image without scripts/halium is UNREADABLE"
want 'UNREADABLE' "$OUT" "and says so"
notwant '== verdict:' "$OUT" "and prints NO verdict about the mount loop"

# An android image with no /boot/android-ramdisk.img is not the image halium extracts from.
run --boot "$BOOT_OK" --android "$IMG_NO_BOOT" --rootfs "$W/x"; rc_is 3 "a system image without the ramdisk is UNREADABLE"
notwant '== verdict:' "$OUT" "and again claims nothing"

# ==================================================================================================
echo
echo "== 3. the mechanism is quoted out of the boot image =="
# ==================================================================================================
r "$IMG_RD_NONE" >/dev/null 2>&1
want 'mount_android_partitions "${rootmnt}/fstab*" ${rootmnt} /tmpmnt' "$OUT" "the first call site is printed verbatim"
want 'mount_android_partitions "${rootmnt}/var/lib/lxc/android/rootfs/fstab*"' "$OUT" "and the second, which is the one that runs"
want 'cat ${fstab} | while read line' "$OUT" "and the line that decides what an empty glob does"
want 'NEVER RUNS' "$OUT" "with the consequence spelled out"
want 'no else-branch and no message' "$OUT" "and that the silence has no else-branch"
# The line numbers come from the FIXTURE, and they are asserted as a shape rather than as numbers: what
# is being checked is that the reading is addressed, not which line the fixture happens to have.
wantre '^    [0-9]+:.*mount_android_partitions "\$\{rootmnt\}/fstab\*"' "$OUT" "the first call site is printed WITH its line number"
wantre '^    [0-9]+:.*rootfs/fstab\*' "$OUT" "and so is the second, which is the one that runs"

# ==================================================================================================
echo
echo "== 4. the four states of the verdict =="
# ==================================================================================================
# (a) NO fstab -- the real shape, and the reading this project expects.
r "$IMG_RD_NONE" >/dev/null 2>&1
rc_is 0 "no fstab is a verdict"
want '== verdict: THE LOOP IS EMPTY' "$OUT" "and the verdict is THE LOOP IS EMPTY"
want '(none -- and that is the reading' "$OUT" "with the empty list named as the reading, not left blank"
want 'entries in it: ' "$OUT" "and the entry count printed"
want 'firmware   PRESENT in the ramdisk root' "$OUT" "with the placeholder directory it was all for"
want 'ls -l /var/lib/lxc/android/rootfs/ | grep -c fstab' "$OUT" "and the one device-side command that would confirm it"
want 'neither is applied here' "$OUT" "and the two repairs named, with neither applied"

# (b) an fstab that NAMES the modem.
r "$IMG_RD_MODEM" >/dev/null 2>&1
want '== verdict: A LINE FOR THE MODEM IS THERE' "$OUT" "an fstab naming the modem is its own verdict"
want 'by-name/modem' "$OUT" "with the line itself printed"
notwant 'THE LOOP IS EMPTY' "$OUT" "and not the empty-loop verdict"

# (c) an fstab that names nothing relevant -- the same silence by another route.
r "$IMG_RD_OTHER" >/dev/null 2>&1
want '== verdict: NO LINE FOR THE MODEM' "$OUT" "an fstab without a modem line is a third state"
want 'by-name/persist' "$OUT" "with what it does name printed"
notwant 'THE LOOP IS EMPTY' "$OUT" "and not the empty-loop verdict"

# The fstab that IS there is listed TWICE in this branch, and for a reason: once in section 2's
# name-level listing (which entry names contain 'fstab') and once in the verdict's own list. Two is the
# reading; one would mean a section stopped printing.
N1=$(printf '%s' "$OUT" | grep -c 'fstab.qcom')
[ "$N1" = 2 ] && ok "and the fstab that IS there is listed by both the entry scan and the verdict ($N1)" \
              || bad "the fstab listing is off ($N1, wanted 2)"

# ==================================================================================================
echo
echo "== 5. the rootfs side, read from a real image =="
# ==================================================================================================
run --boot "$BOOT_OK" --android "$IMG_RD_NONE" --rootfs "$ROOTFS_FX" >/dev/null 2>&1
rc_is 0 "a readable rootfs image is read"
want "/vendor is a symlink" "$OUT" "the rootfs /vendor is reported as a symlink"
want "/android/vendor" "$OUT" "with its target, which is half of the firmware path"
notwant "not printed by this debugfs" "$OUT" "and the target really came out -- '?' would be a check that cannot report"
run --boot "$BOOT_OK" --android "$IMG_RD_NONE" --rootfs "$W/does-not-exist.img" >/dev/null 2>&1
want 'not readable' "$OUT" "an unreadable rootfs is reported as a section that was not read"

# ==================================================================================================
echo
echo "== 6. the cpio walk, which is where this instrument was wrong first =="
# ==================================================================================================
# The harness' OWN reader, over the same fixture the subject reads. If the two disagree the subject is
# wrong, and the count is what makes the disagreement visible -- a walk that is off by two bytes returns
# ONE entry and still looks like a listing.
MYN=$(python3 "$W/cpio.py" list "$RD_NONE" | grep -c .)
SN=$(printf '%s' "$OUT" | sed -n 's/.*entries in it: \([0-9]*\).*/\1/p' | sed -n '1p')
if [ -n "$SN" ] && [ "$MYN" = "$SN" ]; then
  ok "the subject's entry count ($SN) matches an independent walk over the same ramdisk ($MYN)"
else
  bad "the subject counted [$SN] where an independent walk counts $MYN -- one of the two is wrong"
fi
# And the fixture is not accidentally trivial: it must have more than a handful of entries, or the count
# above could match for the wrong reason.
[ "$MYN" -ge 8 ] && ok "and the fixture has $MYN entries, so the agreement is not two ones" \
                || bad "the fixture has only $MYN entries -- this check would pass on a broken walk"

mutate() { # name, sed-script
  sed "$2" "$SRC" > "$W/$1.sh" 2>/dev/null || { bad "mutation '$1': sed failed"; return 1; }
  if cmp -s "$W/$1.sh" "$SRC"; then
    bad "mutation '$1': its sed matches no line of the SHIPPED script, so nothing is being tested"
    return 1
  fi
  "$BASH_BIN" -n "$W/$1.sh" || { bad "mutation '$1': the mutant does not parse"; return 1; }
  ok "mutation '$1': landed (it changes a line of the shipped script, and the mutant parses)"
  return 0
}
runm() { "$BASH_BIN" "$W/$1.sh" --boot "$BOOT_OK" --android "$2" --rootfs "$W/x" > "$W/out/mut.txt" 2>&1; MRC=$?; MUT=$(cat "$W/out/mut.txt"); }

# (a) THE ALIGNMENT: the newc rule applied to the pathname field instead of to header+pathname. This is
# the defect this instrument really had, and its signature is a listing that collapses to one entry.
if mutate align 's#return 110 + namesize + ((4 - ((110 + namesize) % 4)) % 4)#return 110 + ((namesize + 3) \& ~3)#'; then
  runm align "$IMG_RD_NONE"
  SN2=$(printf '%s' "$MUT" | sed -n 's/.*entries in it: \([0-9]*\).*/\1/p' | sed -n '1p')
  # The same helper walks the BOOT image too, so a broken alignment usually announces itself as an
  # UNREADABLE boot image before it ever reaches the ramdisk count. Both are real signatures of the same
  # defect, and accepting only the count would have called the mutant a pass.
  if printf '%s' "$MUT" | grep -qF 'UNREADABLE: the boot image has no cpio member'; then
    ok "mutation 'the alignment rule': the walk cannot even find scripts/halium -- the offset IS the check"
  elif [ -n "$SN2" ] && [ "$SN2" != "$MYN" ]; then
    ok "mutation 'the alignment rule': the walk returns $SN2 entries instead of $MYN -- the count is the check"
  else
    bad "mutation 'the alignment rule': the walk still reports [$SN2] entries and no UNREADABLE -- the count is not reading the walk"
  fi
fi

# (b) THE PRESENCE TEST: with the fstab lookup made to fail, the empty-loop verdict is printed for an image
# that HAS an fstab. The three states must be distinguishable or the table is decoration.
if mutate nofstab 's#^if grep -qi .fstab. "\$RDLIST"; then#if false; then#'; then
  runm nofstab "$IMG_RD_MODEM"
  want '== verdict: THE LOOP IS EMPTY' "$MUT" "mutation 'the presence test': an image WITH an fstab is read as empty"
  r "$IMG_RD_MODEM" >/dev/null 2>&1
  want 'A LINE FOR THE MODEM IS THERE' "$OUT" "while the shipped script reaches the other verdict on the same image"
fi

# (c) THE CONTENT TEST: the verdict that distinguishes the two present-fstab states is the content read,
# so removing it must merge them.
if mutate nocontent 's#^  if grep -qE .firmware_mnt|modem|/vendor. "\$FSTAB_TXT"; then#  if false; then#'; then
  runm nocontent "$IMG_RD_MODEM"
  notwant 'A LINE FOR THE MODEM IS THERE' "$MUT" "mutation 'the content test': a named modem line stops being recognised"
  want 'NO LINE FOR THE MODEM' "$MUT" "and the two present-fstab states merge into one"
fi

# ==================================================================================================
echo
echo "== 6b. --quiet, which is a claim about the OUTPUT and was therefore never tested =="
# ==================================================================================================
# The subject documents `--quiet` as "print the verdict only, not the readings". Nothing tested it, so
# the shipped version did the OPPOSITE: its gate was `[ "$QUIET" = 1 ] && [ -n "$1" ] && return 0`, so
# the verdict (non-empty) was suppressed and the blank separator lines (empty) were printed -- and the
# readings that went through a `grep | sed` instead of through `say` printed too, because they never
# reached the gate. A documented option that no assertion mentions is an option, not a feature.
r "$IMG_RD_NONE" >/dev/null 2>&1                       # warm-up, so this is not the cold run
run --boot "$BOOT_OK" --android "$IMG_RD_NONE" --rootfs "$W/x" --quiet; rc_is 0 "--quiet still exits 0"
want '== verdict: THE LOOP IS EMPTY' "$OUT" "and it prints the verdict"
want '  read from:' "$OUT" "and the verdict carries the identity of the input it was read from"
notwant '== 1. the mechanism' "$OUT" "and NOT the section 1 readings"
notwant 'entries in it:' "$OUT" "nor the ramdisk listing"
notwant 'the entries this block turns on' "$OUT" "nor section 3's"
notwant 'in the UT rootfs image:' "$OUT" "nor section 4's"
# The other half, and the one the first fix missed: every line that reaches stdout WITHOUT going through
# `say` has to be gated too. The counters below are the ones those pipelines emit.
n_percent=$(printf '%s' "$OUT" | grep -c 'mount_android_partitions "' || true)
[ "$n_percent" = 0 ] && ok "and none of the lines that bypass \`say\` (the grep/awk pipelines) leaked" \
                     || bad "$n_percent line(s) reached stdout outside the quiet gate"
# It must not be quiet about the WRONG things either: a run whose verdict was also suppressed would look
# like a clean exit with no output, which is the most dangerous shape of all.
n_lines=$(printf '%s' "$OUT" | grep -c . || true)
[ "$n_lines" -ge 8 ] && ok "and the verdict block is $n_lines lines, not a truncated tail" \
                     || bad "only $n_lines non-blank line(s) with --quiet -- the verdict may have been suppressed"

# ==================================================================================================
echo
echo "== 7. it is a READ-ONLY instrument, and that is static =="
# ==================================================================================================
for pat in 'debugfs -w' 'mount -o' 'mount --' 'fastboot' 'dd of=' 'tune2fs' 'e2fsck'; do
  # The prose DOES name some of these -- it has to, to say what it never does -- so the claim checked is
  # the one that is true: every occurrence is inside a comment or a printed string, and none is a command.
  # (A grep for a defect's shape also matches the sentence forbidding it; this tree records that trap.)
  tot=$(grep -c -- "$pat" "$SRC")
  code=$(grep -n -- "$pat" "$SRC" | grep -vE ':[[:space:]]*#|say "|echo "' | grep -c .)
  if [ "$tot" = 0 ]; then ok "the shipped script never mentions '$pat', let alone runs it"
  elif [ "$code" = 0 ]; then ok "every mention of '$pat' ($tot) is prose or a comment, and none is a command"
  else bad "'$pat' appears $code time(s) OUTSIDE a comment or a printed string -- one of them is a command"; fi
done
# The three downloader names must not appear AT ALL, prose included: there is nothing here that needs to
# explain them, and unlike mount/fastboot this file has no reason to name them.
for pat in QFIL fh_loader QSaharaServer; do
  notwant "$pat" "$(cat "$SRC")" "the shipped script does not name '$pat' at all"
done
want 'debugfs -R' "$(cat "$SRC")" "it reads with debugfs -R, which is read-only by construction"
n=$(grep -c 'debugfs -R' "$SRC")
[ "$n" -ge 3 ] && ok "and makes $n such reads, so the surface is countable" || bad "only $n debugfs -R reads -- expected at least three"

# ==================================================================================================
echo
echo "== 8. this harness's own citation =="
# ==================================================================================================
HEALTH="$HERE/zl1-health-check.sh"
if [ -r "$HEALTH" ]; then
  match=$(tr '\n' ' ' < "$HEALTH" | grep -oE 'zl1-modem-mount-selftest\.sh[^0-9]*[0-9]+ checks' | sed -n 1p)
  cited=$(printf '%s\n' "$match" | sed -n 's/.*[^0-9]\([0-9][0-9]*\) checks$/\1/p')
  total=$(( PASS + FAIL + 1 ))
  if [ -z "$cited" ]; then
    bad "the health check no longer cites this harness's count -- either the citation is gone or its wording changed"
  elif [ "$cited" = "$total" ]; then
    ok "the health check cites $cited checks, and this run has exactly that many"
  else
    bad "the health check cites $cited checks, but this harness has $total -- fix host/zl1-health-check.sh"
  fi
else
  bad "cannot read $HEALTH -- its citations are unchecked"
fi

echo
if [ "$KEEP" = 1 ]; then echo "kept: $W"; else rm -rf "$W"; fi
printf 'pass=%s fail=%s skip=%s\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" = 0 ] || exit 1
exit 0
