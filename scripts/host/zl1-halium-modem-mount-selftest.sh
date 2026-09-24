#!/bin/sh
# zl1 halium modem-firmware mount -- offline self-test.
#
# Host-side, touches no device. The subject is boot/patches/0200-halium-modem-firmware-mount.patch:
# the patch that gives the initramfs an fstab of its own AND makes halium's three silences audible.
# What this harness does that a text diff cannot: it APPLIES the patch and then RUNS the patched
# shell, with `mount` replaced, asserting on what the function DOES -- which directory it creates,
# which device it names, and what it says when it cannot do it.
#
# WHY THE FIXTURE IS THE REAL FILE AND NOT A SYNTHETIC ONE. The subject is the function halium's
# initramfs runs, statement for statement. A fixture written as a summary of it would exercise a
# function nobody ships, so the fixture is scripts/host/fixtures/halium-02dd7445: the `scripts/halium`
# entry as it exists inside the boot image the device runs (21943 bytes, sha256 02dd7445...). Its
# identity is asserted twice -- against the hash recorded here, and, when the candidate images are on
# this laptop, against the image itself, byte for byte.
#
# THE UNPATCHED FILE IS THE CONTROL, not a sed mutation. Every assertion that a report APPEARS is
# paired with the same run against the unpatched fixture, which must NOT produce it. A harness that
# cannot go red on the script it was written to fix is not evidence.
#
# Usage: zl1-halium-modem-mount-selftest.sh [--keep]
#
# Exit codes: 0 every scenario behaved; 1 something did not; 2 the harness could not set up.

set -u

KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
  --keep) KEEP=1; shift ;;
  --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
PATCH="$REPO/boot/patches/0200-halium-modem-firmware-mount.patch"
FIXTURE="$REPO/scripts/host/fixtures/halium-02dd7445"
FIXTURE_SHA=02dd7445f272564ce2379ffa2fc9ef8bbdf8c414f39b9316d824f4bf2a507acd
CAND=/mnt/data/halium-zl1-candidates
REF_IMG="$CAND/halium-boot-zl1-v63-rebuilt.img"
NEW_IMG="$CAND/halium-boot-zl1-v63-modemfw.img"

for f in "$PATCH" "$FIXTURE"; do
  [ -r "$f" ] || { echo "cannot read $f" >&2; exit 2; }
done
for t in patch sha256sum awk sed diff cmp cpio gzip python3; do
  command -v "$t" >/dev/null 2>&1 || { echo "this harness needs $t" >&2; exit 2; }
done

W=${TMPDIR:-/tmp}/zl1-halium-modem-mount-selftest
[ "$KEEP" = 1 ] || rm -rf "$W"
mkdir -p "$W" || exit 2

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }
skip() { SKIP=$((SKIP+1)); printf 'SKIP  %s\n' "$1"; }
has()  { if printf '%s' "$2" | grep -qF -- "$1"; then ok "$3"; else bad "$3"; printf '        | wanted: %s\n' "$1"; fi; }
hasnot(){ if printf '%s' "$2" | grep -qF -- "$1"; then bad "$3"; printf '        | did NOT want: %s\n' "$1"; else ok "$3"; fi; }
eq()   { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got [$1], wanted [$2])"; fi; }

say() { printf '\n== %s\n' "$1"; }

# ==================================================================================================
say "1. the fixture is the file the device's boot image carries"
# ==================================================================================================
GOT=$(sha256sum "$FIXTURE" | awk '{print $1}')
eq "$FIXTURE_SHA" "$GOT" "the fixture hashes to the recorded value (21943 bytes, the unpatched entry)"

# Extract the same entry out of the image the port runs, when those images are on this laptop.
extract_entry() { # extract_entry IMG ENTRY OUTDIR -> 0 on success
  python3 - "$1" "$2" "$3" <<'PY'
import struct, sys, subprocess
img, entry, outdir = sys.argv[1], sys.argv[2], sys.argv[3]
d = open(img, 'rb').read()
assert d[:8] == b'ANDROID!', 'not an Android boot image'
ks, kaddr, rs, raddr, ss, saddr, tags, page = struct.unpack_from('<8I', d, 8)
pg = lambda n: (n + page - 1) // page
blob = d[page * (1 + pg(ks)):][:rs]
# The ramdisk is a gzip stream, so it goes to `zcat` AS IT IS: decompressing here and then feeding
# `zcat` would decompress twice, which fails, and a fixture check that cannot extract is a check
# that reports the fixture is wrong.
subprocess.run(['sh', '-c', 'zcat | cpio -idm --quiet', '_'], input=blob, cwd=outdir, check=True)
PY
}
if [ -r "$REF_IMG" ]; then
  mkdir -p "$W/img_ref"
  if extract_entry "$REF_IMG" scripts/halium "$W/img_ref" 2>"$W/extract.err"; then
    if cmp -s "$W/img_ref/scripts/halium" "$FIXTURE"; then
      ok "the fixture is byte-identical to scripts/halium inside $(basename "$REF_IMG")"
    else
      bad "the fixture DIFFERS from the image's scripts/halium -- the fixture is stale"
      printf '        | fixture %s\n        | image   %s\n' "$GOT" "$(sha256sum "$W/img_ref/scripts/halium" | awk '{print $1}')"
    fi
  else
    bad "could not extract scripts/halium from $(basename "$REF_IMG")"
  fi
else
  skip "no $REF_IMG on this laptop: the fixture's identity rests on the recorded hash alone"
fi

# ==================================================================================================
say "2. the patch applies, and adds exactly two things"
# ==================================================================================================
mkdir -p "$W/patched/scripts"
cp "$FIXTURE" "$W/patched/scripts/halium"
if ( cd "$W/patched" && patch -p1 --forward --silent < "$PATCH" ) >"$W/patch.log" 2>&1; then
  ok "patch -p1 --forward --silent applies cleanly (the builder's own command)"
else
  bad "the patch did not apply"
  sed 's/^/        | /' "$W/patch.log"
fi
[ -f "$W/patched/zl1-android-fstab" ] && ok "it adds zl1-android-fstab" || bad "zl1-android-fstab was not added"

# What the patch touches, from the patch itself: two paths, no more.
TOUCHED=$(awk '/^\+\+\+ /{print $2}' "$PATCH" | sed 's|^b/||' | sort)
eq "$(printf 'scripts/halium\nzl1-android-fstab')" "$TOUCHED" "the patch changes exactly scripts/halium and adds zl1-android-fstab"

# Applying it twice must not silently double anything: the second application is refused.
if ( cd "$W/patched" && patch -p1 --forward --silent < "$PATCH" ) >"$W/patch2.log" 2>&1; then
  bad "the patch applied a SECOND time -- a rebuild that patches twice would double its work"
else
  ok "a second application is refused (so the build path cannot apply it twice)"
fi

if [ -r "$NEW_IMG" ]; then
  mkdir -p "$W/img_new"
  if extract_entry "$NEW_IMG" scripts/halium "$W/img_new" 2>>"$W/extract.err"; then
    if cmp -s "$W/img_new/scripts/halium" "$W/patched/scripts/halium"; then
      ok "the built image's patched script IS this harness's patched script, byte for byte"
    else
      bad "the built image and this harness patched the file differently"
    fi
    if [ -f "$W/img_new/zl1-android-fstab" ] && cmp -s "$W/img_new/zl1-android-fstab" "$W/patched/zl1-android-fstab"; then
      ok "the built image's fstab is this harness's fstab, byte for byte"
    else
      bad "the built image's zl1-android-fstab differs from the one this harness builds"
    fi
  else
    bad "could not extract scripts/halium from $(basename "$NEW_IMG")"
  fi
else
  skip "no $NEW_IMG on this laptop: the harness's patch is not compared against a built image"
fi

# ==================================================================================================
say "3. the patched function, run -- with mount replaced"
# ==================================================================================================
# The function under test, taken out of whichever file is being exercised. It is a whole function
# and it contains no nested closing brace, so the end of the function is the first line that is `}`.
extract_fn() { # extract_fn FILE OUT
  awk '/^mount_android_partitions\(\)/{f=1} f{print} f && /^\}$/{exit}' "$1" > "$2"
  [ -s "$2" ] || echo "MISSING" > "$2"
}

cat > "$W/drive.sh" <<'DRIVER'
#!/bin/sh
# Runs the function under test in a sandbox: the fstab file, the mount root and the fallback are all
# paths the harness owns, `tell_kmsg` records instead of writing /dev/kmsg, and `mount` is replaced
# so that no real mount is attempted and the command line it WOULD have run is recorded.
FUNCS=$1; FSTAB=$2; ROOT=$3; FALLBACK=$4; TELL=$5; CALLS=$6; RC=$7
. "$FUNCS"
tell_kmsg() { printf '%s\n' "$1" >> "$TELL"; }
mount() { printf '%s\n' "$*" >> "$CALLS"; return "${RC:-0}"; }
mount_android_partitions "$FSTAB" "$ROOT/android" "$ROOT/userdata" "$FALLBACK"
DRIVER

# scenario NAME FILE FSTAB_GLOB FALLBACK_PATH MOUNT_RC -> sets TELL, CALLS, ROOT
scenario() {
  _name=$1; _file=$2; _glob=$3; _fb=$4; _rc=$5
  extract_fn "$_file" "$W/fn.$_name.sh"
  rm -rf "$W/s.$_name"; mkdir -p "$W/s.$_name/root/android" "$W/s.$_name/root/userdata"
  : > "$W/s.$_name/tell"; : > "$W/s.$_name/calls"
  RC="$_rc" sh "$W/drive.sh" "$W/fn.$_name.sh" "$_glob" "$W/s.$_name/root" "$_fb" \
      "$W/s.$_name/tell" "$W/s.$_name/calls" "$_rc" >"$W/s.$_name/out" 2>&1
  TELL=$(cat "$W/s.$_name/tell")
  # halium writes the mount point as ${mount_root}/$2, and $2 begins with a slash, so every target
  # carries `//`. Normalise it here: this harness asserts on PATHS, not on one concatenation idiom.
  CALLS=$(sed 's|//|/|g' "$W/s.$_name/calls")
  ROOT="$W/s.$_name/root"
}

PATCHED="$W/patched/scripts/halium"
NOPE="$W/nothing-here/fstab*"

# (a) the glob matches nothing and no fallback was given: the silence that started all of this.
#     "Nothing was mounted" cannot be asserted as "no mount call at all": the function always ends by
#     bind-mounting a cache, so the assertion is that nothing about the MODEM was mounted.
scenario nofallback "$PATCHED" "$NOPE" "" 0
has 'matched NO file and no fallback is present: NOTHING WILL BE MOUNTED' "$TELL" \
    "an unmatched glob with no fallback says so"
hasnot 'firmware_mnt' "$CALLS" "  ... and nothing is mounted for it"
hasnot 'by-partlabel/modem' "$TELL" "  ... and it does not pretend to have read a line"

# (b) the glob matches nothing and the fallback this initramfs carries is there.
scenario fallback "$PATCHED" "$NOPE" "$W/patched/zl1-android-fstab" 0
has "using the one this initramfs carries: $W/patched/zl1-android-fstab" "$TELL" \
    "an unmatched glob WITH a fallback says which file it used instead"
has 'checking mount label modem' "$TELL" \
    "  ... and the fallback's line is really read (the label it carries, not the glob's)"

# (c) the glob matches: the fallback must be ignored, which is what keeps this a no-op for a device
#     whose Android ramdisk does have an fstab.
printf '/dev/disk/by-partlabel/somewhere    /somewhere    ext4    ro\n' > "$W/real.fstab"
scenario matchedglob "$PATCHED" "$W/real.fstab*" "$W/patched/zl1-android-fstab" 0
has 'checking mount label somewhere' "$TELL" "a glob that matches is read as before"
hasnot 'checking mount label modem' "$TELL" "  ... and the fallback is NOT read when the glob matched"
hasnot 'matched NO file' "$TELL" "  ... and nothing claims the glob was empty"

# (d) the shipped fstab line, with its source pointed at a device that exists -- the device it names
#     (/dev/disk/by-partlabel/modem) is a partition of a phone, not of a laptop.
sed 's|^/dev/disk/by-partlabel/modem|'"$W"'/modem.dev|' "$W/patched/zl1-android-fstab" > "$W/fb.device"
: > "$W/modem.dev"
scenario device "$PATCHED" "$NOPE" "$W/fb.device" 0
has "$W/modem.dev $W/s.device/root/android/vendor/firmware_mnt -t vfat -o ro,shortname=lower,uid=0,gid=1000,dmask=227,fmask=337" "$CALLS" \
    "the device the fstab NAMES is the one used, with this initramfs's own options"
has 'checking mount label modem.dev' "$TELL" "  ... and the line's own label is what is looked up"

# (e) THE POINT OF THE WHOLE PATCH: the mount point lands where the kernel looks. The cmdline says
#     firmware_class.path=/vendor/firmware_mnt/image and the UT rootfs reaches that through /vendor ->
#     /android/vendor, so /android/vendor/firmware_mnt has to be a real directory afterwards.
if [ -d "$ROOT/android/vendor/firmware_mnt" ]; then
  ok "the mount point /android/vendor/firmware_mnt exists afterwards (the path the kernel resolves)"
else
  bad "the mount point was not created -- the kernel's firmware path would resolve nowhere"
fi
# (f) and the carrier of that path is a REAL directory, not a link into the Android system image:
#     halium's own fallback (`ln -sf system/vendor`) must not have been taken, because a link there
#     would resolve into the read-only system image, where the directory cannot be created.
if [ -L "$ROOT/android/vendor" ]; then
  bad "/android/vendor was left a SYMLINK -- the mount point would resolve into the Android image"
else
  ok "/android/vendor is a real directory, so the mount point is on this mount root"
fi

# (g) a line whose device is nowhere: the third silence, now said out loud. This is the run of the
#     SHIPPED line, unmodified -- /dev/disk/by-partlabel/modem does not exist on a laptop.
scenario absent "$PATCHED" "$NOPE" "$W/patched/zl1-android-fstab" 0
has 'no device for label modem' "$TELL" "a line whose device does not exist is reported, not skipped in silence"
hasnot 'firmware_mnt' "$CALLS" "  ... and nothing is mounted for it"

# (h) a mount that fails: reported, and the boot is not aborted (no `set -e` in this initramfs).
scenario mntfail "$PATCHED" "$NOPE" "$W/fb.device" 32
has 'MOUNT FAILED:' "$TELL" "a failed mount is reported"
has 'firmware_mnt' "$TELL" "  ... with the mount point in the report"

# ==================================================================================================
say "4. the control -- the same runs against the UNPATCHED file"
# ==================================================================================================
# Every report asserted above has to be ABSENT here, or the assertions are measuring the harness.
UNPATCHED="$FIXTURE"
scenario old_nofb "$UNPATCHED" "$NOPE" "" 0
hasnot 'matched NO file' "$TELL" "the unpatched file says NOTHING when the glob matches nothing"
hasnot 'firmware_mnt' "$CALLS" "  ... and mounts nothing (which is why nothing was mounted on this device)"
hasnot 'checking mount label' "$TELL" "  ... the loop body never runs, and nothing says so"

# With a glob that DOES match, the unpatched file reads a real fstab -- so "it mounts nothing" is not
# for lack of a file. What it does with a line whose device is absent is the second silence.
scenario old_absent "$UNPATCHED" "$W/real.fstab*" "" 0
has 'checking mount label somewhere' "$TELL" \
    "the unpatched file does read an fstab that exists"
hasnot 'no device for label' "$TELL" "  ... and a line whose device is absent is a silent 'continue'"

scenario old_fail "$UNPATCHED" "$W/real.fstab*" "" 32
hasnot 'MOUNT FAILED' "$TELL" "the unpatched file says nothing when a mount fails"

# The fallback argument the unpatched file cannot take: passing a fourth argument must not make it
# mount anything, because it never looks at it.
scenario old_fb "$UNPATCHED" "$NOPE" "$W/patched/zl1-android-fstab" 0
hasnot 'using the one this initramfs carries' "$TELL" "  ... and it has no notion of a fallback fstab"
hasnot 'checking mount label' "$TELL" "  ... the fourth argument changes nothing for it"

# ==================================================================================================
say "5. what the shipped fstab line IS -- the safety assertion"
# ==================================================================================================
LINE=$(grep -v '^#' "$W/patched/zl1-android-fstab" | grep -v '^$')
eq 1 "$(printf '%s\n' "$LINE" | wc -l | tr -d ' ')" "the shipped fstab carries exactly one mount line"
eq "/dev/disk/by-partlabel/modem    /vendor/firmware_mnt    vfat    ro,shortname=lower,uid=0,gid=1000,dmask=227,fmask=337" "$LINE" \
    "that line is the modem partition at /vendor/firmware_mnt, mounted READ-ONLY"
case "$LINE" in
  *ro,*) ok "the mount is read-only" ;;
  *) bad "the mount is not read-only" ;;
esac
SRC=$(printf '%s\n' "$LINE" | awk '{print $1}')
eq "modem" "$(printf '%s\n' "$SRC" | awk -F/ '{print $NF}')" \
    "the partition it mounts is the modem partition, by name"
# The forbidden list, against the SOURCE only: this is the one partition the project does want
# mounted, read-only, and nothing else may appear here.
for p in persist fsg fsc modemst1 modemst2 boot recovery misc dsp bluetooth userdata system cache; do
  case "$SRC" in
    */"$p") bad "the shipped fstab's source is the FORBIDDEN partition: $p" ;;
  esac
done
ok "and its source names none of persist/fsg/fsc/modemst*/boot/recovery/misc/dsp/bluetooth/userdata/system/cache"

# ==================================================================================================
say "6. neither shipped file can reach a device"
# ==================================================================================================
for f in "$PATCHED" "$W/patched/zl1-android-fstab"; do
  bad_hits=0
  for n in fastboot adb 'ssh ' 'dd of=' edl QFIL qdl; do
    if grep -qF -- "$n" "$f"; then bad_hits=$((bad_hits+1)); printf '        | %s contains %s\n' "$(basename "$f")" "$n"; fi
  done
  if [ "$bad_hits" = 0 ]; then ok "$(basename "$f") contains no device-touching command name"; else bad "$(basename "$f") mentions a device-touching command name"; fi
done

# ==================================================================================================
say "7. this harness's own citation"
# ==================================================================================================
# A count typed into another file is a claim about this run. docs 110's guard: read it back and
# compare, so a harness that grows without its citation fails HERE rather than being believed.
HEALTH="$HERE/zl1-health-check.sh"
if [ -r "$HEALTH" ]; then
  match=$(tr '\n' ' ' < "$HEALTH" | grep -oE 'zl1-halium-modem-mount-selftest\.sh[^0-9]*[0-9]+ checks' | sed -n 1p)
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

say "summary"
if [ "$KEEP" = 1 ]; then echo "kept: $W"; else rm -rf "$W"; fi
printf 'pass=%s fail=%s skip=%s\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" = 0 ] || exit 1
exit 0
