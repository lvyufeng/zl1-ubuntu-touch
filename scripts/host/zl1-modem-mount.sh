#!/usr/bin/env bash
# Why the modem's firmware is never found: halium's mount loop reads an fstab that does not exist.
#
# Why this exists (docs 120's open question, answered offline by docs 151):
#
#   Docs 120 narrowed the modem to ONE question and left it for the device: halium's mount loop reads
#   `${rootmnt}/var/lib/lxc/android/rootfs/fstab*`, `cat` on an unexpanded glob fails, the `while read`
#   body never executes, and NOTHING is mounted -- silently. Doc 120 then recorded that the ramdisk which
#   lands at that path could not be read offline ("那一份离线看不到"), so "does it carry an fstab" was
#   filed as a device-side `ls`.
#
#   THAT CAVEAT WAS WRONG, and this script is the correction. The ramdisk halium extracts lives at
#   `/boot/android-ramdisk.img` inside the Android SYSTEM image, and that image is on this laptop -- it is
#   the same 4 GB file that was pushed to the phone's `/data/system.img` (docs 21, and the restore script
#   names the same path). So the question is answerable with `debugfs` and a cpio listing, and it is.
#
# What it reads, in order, all read-only and all from FILES:
#
#   1. the BOOT image  -> the initrd -> `scripts/halium` -> the call site, verbatim, with line numbers.
#      That is the mechanism: the glob, the `cat`, and the loop that cannot run.
#   2. the ANDROID SYSTEM image -> `/boot/android-ramdisk.img` -> its cpio listing. This is the ramdisk
#      that ends up at the glob's directory, so its file list IS the answer to the question.
#   3. the UT ROOTFS image -> `/vendor` (a symlink) and `/var/lib/lxc/android/rootfs` (empty in the
#      shipped image: the ramdisk is `mount --move`d over it at boot).
#
# THE VERDICT IS A TABLE, not a yes/no, because "no fstab", "an fstab with no line for this" and "could
# not read it" are three different things and only the last one is not an answer:
#
#   THE LOOP IS EMPTY        no `fstab*` in the ramdisk -> the loop never runs -> nothing is mounted
#   NO LINE FOR THE MODEM    an fstab is there and says nothing about vendor/firmware_mnt
#   A LINE FOR THE MODEM     an fstab is there and names it -- then the question moves to the mount
#   UNREADABLE               an input could not be read -- NOTHING is claimed (exit 3)
#
# It never writes, never mounts, never flashes, and never touches the device: every path it opens is an
# image file on this laptop. It also does not PROPOSE to repair anything on hardware -- both repairs it
# names are device-side writes and are a person's decision.
#
# Usage: zl1-modem-mount.sh [--boot IMG] [--android IMG] [--rootfs IMG] [--quiet] [--keep]
#   --boot IMG       the halium boot image (default: the v63 rebuilt one in the candidates dir)
#   --android IMG    the Android system image (default: the staged candidate, i.e. /data/system.img)
#   --rootfs IMG     the UT host rootfs image (default: the 24.04-2.x zl1 host image)
#   --quiet          print the verdict only, not the readings
#   --keep           keep the unpacked ramdisk in the temp dir and print its path
#
# Exit codes: 0 a verdict was reached; 2 an input or a tool is missing; 3 an input could not be read.
#
# What this NEVER does: mount an image, write to any image, touch the device, or run a downloader tool.

set -uo pipefail
export LC_ALL=C

BOOT="${ZL1_BOOT_IMG:-/mnt/data/halium-zl1-candidates/halium-boot-zl1-v63-rebuilt.img}"
ANDROID="${ZL1_ANDROID_IMG:-/mnt/data/halium-zl1-candidates/android-system-zl1-halium-candidate.img}"
ROOTFS="${ZL1_ROOTFS_IMG:-/mnt/data/ubports-rootfs/24.04-2.x/rootfs-24.04-2.x-arm64-android9plus-zl1-host.img}"
QUIET=0
KEEP=0

while [ $# -gt 0 ]; do
  case "$1" in
  --boot) BOOT="${2?--boot needs a path}"; shift 2 ;;
  --android) ANDROID="${2?--android needs a path}"; shift 2 ;;
  --rootfs) ROOTFS="${2?--rootfs needs a path}"; shift 2 ;;
  --quiet) QUIET=1; shift ;;
  --keep) KEEP=1; shift ;;
  --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0" ; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

# --quiet keeps READINGS out and the VERDICT in, and the two have to be told apart explicitly: the
# first version gated every line through one predicate whose test was `[ -n "$1" ]`, which meant that
# under --quiet the verdict (non-empty) was suppressed and the blank separator lines (empty) were
# printed -- the option did the exact opposite of its own usage line, and nothing tested it. `SHOW`
# is set once a verdict block begins, so "readings" and "the answer" are different things in code and
# not just in the header.
SHOW=0
say() { [ "$QUIET" = 1 ] && [ "$SHOW" = 0 ] && return 0; printf '%s\n' "$*"; }
# ...and every printer that writes to STDOUT DIRECTLY -- a `grep | sed`, an `awk` -- has to go through
# the same gate. Those were the leak the first fix missed: `say` was only half of the output, and a
# --quiet that suppresses some lines and prints others is worse than one that prints everything,
# because its output looks like an answer.
quiet() { while IFS= read -r _l; do say "$_l"; done; }

# --- the tools, and the refusals that come before any reading --------------------------------------
for t in python3 debugfs gzip; do
  command -v "$t" >/dev/null 2>&1 || {
    echo "REFUSED: no $t(1) on this host. This instrument reads image FILES with it, so without it there" >&2
    echo "         is nothing to say -- this is a HOST problem, not a reading about the device." >&2
    exit 2
  }
done
for f in "$BOOT" "$ANDROID"; do
  [ -r "$f" ] || {
    echo "REFUSED: cannot read $f" >&2
    echo "         The images are the whole input. If they have moved, point at them with --boot/--android." >&2
    exit 2
  }
done
ROOTFS_OK=1
[ -r "$ROOTFS" ] || ROOTFS_OK=0

W=$(mktemp -d "${TMPDIR:-/tmp}/zl1-modem-mount.XXXXXX") || exit 2
cleanup() { [ "$KEEP" = 1 ] || rm -rf "$W"; }
trap cleanup EXIT HUP INT TERM

say "zl1 modem mount -- offline readings"
say "  READ-ONLY, HOST-SIDE, NO DEVICE: every path below is an image file on this laptop."
say "  boot image:    $BOOT"
say "  android image: $ANDROID"
say "  rootfs image:  $([ "$ROOTFS_OK" = 1 ] && echo "$ROOTFS" || echo "(not readable -- section 5 will say so)")"
say
# THE IDENTITY OF THE INPUT, printed with the reading and again with the verdict. This is not
# decoration: images here get REBUILT UNDER THE SAME FILENAME (the boot image this project runs is
# itself a rebuild that kept v63's name), so a reading that names only a path can be attributed to a
# file that is no longer the one it describes. `scripts/host/zl1-artifact-manifest.sh` checks the
# tracked record against the directory; this line binds THIS run to the bytes it actually read, which
# is what a later reader needs when the directory has moved on. docs 149's rule, one level down.
say "  the identity of what was read (sha256 and size, so this run can be traced to its input):"
for f in "$BOOT" "$ANDROID" "$ROOTFS"; do
  [ -r "$f" ] || continue
  say "    $(sha256sum -- "$f" | awk '{print $1}')  $(stat -c %s -- "$f")  $f"
done
say

# ==================================================================================================
say "== 1. the mechanism: what the boot image's halium script does =="
# ==================================================================================================
# The initrd is a gzip'd cpio. The gzip member is located by scanning for the magic and confirming the
# payload is cpio (070701), because a boot image also contains a kernel and DTB blobs and a naive "first
# gzip" scan finds those instead.
HALIUM_SRC="$W/halium.src"
python3 - "$BOOT" > "$HALIUM_SRC" <<'PY'
import sys, re, zlib
def pad4(n):
    return (n + 3) & ~3
def data_off(namesize):
    # newc: NULs follow the pathname so that (fixed header + pathname) is a multiple of four.
    return 110 + namesize + ((4 - ((110 + namesize) % 4)) % 4)
p = sys.argv[1]
d = open(p, 'rb').read()
found = None
for m in re.finditer(b'\x1f\x8b\x08', d):
    off = m.start()
    try:
        dz = zlib.decompressobj(16 + zlib.MAX_WBITS)
        out = dz.decompress(d[off:])
        out += dz.flush()
    except Exception:
        continue
    if not out.startswith(b'070701'):
        continue
    # cpio "newc" walk
    i = 0
    while i + 110 <= len(out):
        hdr = out[i:i+110]
        if not hdr.startswith(b'070701'):
            break
        try:
            filesize = int(hdr[54:62], 16)
            namesize = int(hdr[94:102], 16)
        except ValueError:
            break
        name = out[i+110:i+110+namesize-1].decode('utf-8', 'replace')
        data_at = i + data_off(namesize)
        data = out[data_at:data_at+filesize]
        if name.lstrip('./') == 'scripts/halium':
            found = data.decode('utf-8', 'replace')
            break
        i = data_at + pad4(filesize)
    if found:
        break
if found is None:
    print("__NOT_FOUND__")
else:
    sys.stdout.write(found)
PY
if grep -qF -- '__NOT_FOUND__' "$HALIUM_SRC"; then
  SHOW=1
  say "  UNREADABLE: the boot image has no cpio member carrying scripts/halium."
  say "  No claim is made about the mount loop: this instrument reads the SHIPPED script, not a memory"
  say "  of it, and a boot image laid out differently is a reading it cannot take."
  exit 3
fi
say "  the boot image's initrd carries scripts/halium, and it reads the fstab in exactly these places:"
say
grep -n 'fstab' "$HALIUM_SRC" | sed 's/^/    /' | quiet
say
# The call site that matters, quoted rather than summarised: a summary is a place for a mistake to live.
say "  the call site, verbatim:"
grep -n 'mount_android_partitions "' "$HALIUM_SRC" | sed 's/^/    /' | quiet
say
say "  and the part of mount_android_partitions that decides what happens when the glob matches nothing:"
awk '/^mount_android_partitions\(\)/,/^}/' "$HALIUM_SRC" | grep -n -E 'fstab=|cat \$\{fstab\}|while read|^}|tell_kmsg "checking fstab' | sed 's/^/    /' | quiet
say
say "  READ THAT AS THREE FACTS: the fstab argument is a GLOB; it is expanded unquoted; and the only"
say "  consumer of it is 'cat \${fstab} | while read line'. A glob that matches no file makes cat exit"
say "  non-zero AND PRINT NOTHING, so the loop body -- the mkdir and the mount -- never executes. There"
say "  is no else-branch and no message: an empty fstab and a missing fstab are the same silence."
say

# ==================================================================================================
say
say "== 2. the ramdisk that lands on that glob's directory =="
# ==================================================================================================
# halium's extract_android_ramdisk() unpacks /android-system/boot/android-ramdisk.img to /android-rootfs
# and the normal-boot path then does `mount --move /android-rootfs ${rootmnt}/var/lib/lxc/android/rootfs`
# -- i.e. THE LISTING BELOW IS THE LISTING OF THE GLOB'S DIRECTORY. That is the whole reason this
# instrument exists: the file list answers a question docs 120 filed as device-only.
RDLIST="$W/ramdisk.list"
debugfs -R 'dump /boot/android-ramdisk.img '"$W"'/android-ramdisk.img' "$ANDROID" >/dev/null 2>&1
if [ ! -s "$W/android-ramdisk.img" ]; then
  SHOW=1
  say "  UNREADABLE: $ANDROID has no readable /boot/android-ramdisk.img."
  say "  This image is not the one halium extracts from, so nothing here is a reading about the boot this"
  say "  project runs. (Which is a finding in itself -- but it is about the IMAGE, not the device.)"
  exit 3
fi
say "  the ramdisk: $(stat -c %s "$W/android-ramdisk.img") bytes, extracted read-only with debugfs"
python3 - "$W/android-ramdisk.img" > "$RDLIST" <<'PY'
import sys, gzip, io
def pad4(n):
    return (n + 3) & ~3
def data_off(namesize):
    # newc: NULs follow the pathname so that (fixed header + pathname) is a multiple of four.
    return 110 + namesize + ((4 - ((110 + namesize) % 4)) % 4)
d = open(sys.argv[1], 'rb').read()
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
    filesize = int(hdr[54:62], 16)
    namesize = int(hdr[94:102], 16)
    name = out[i+110:i+110+namesize-1].decode('utf-8', 'replace')
    if name.startswith('./'):
        name = name[2:]
    # `TRAILER!!!` is the archive's END MARKER, not an entry in it. Counting it would inflate the number
    # by one in a way no reader could see, which is the shape this whole file is about.
    if name == 'TRAILER!!!':
        break
    print(name)
    i = i + data_off(namesize)
    i = i + pad4(filesize)
PY
N_ENTRIES=$(grep -c . "$RDLIST")
# The CONTENT of every fstab* member, so the verdict can tell "an fstab with no line for this" from "an
# fstab that names it". A verdict that could not make that distinction would be reading the file NAME
# and calling it content.
FSTAB_TXT="$W/fstab.txt"
: > "$FSTAB_TXT"
python3 - "$W/android-ramdisk.img" > "$FSTAB_TXT" <<'PY'
import sys, gzip, zlib
def pad4(n):
    return (n + 3) & ~3
def data_off(namesize):
    return 110 + namesize + ((4 - ((110 + namesize) % 4)) % 4)
d = open(sys.argv[1], 'rb').read()
try:
    out = gzip.decompress(d)
except Exception:
    dz = zlib.decompressobj(16 + zlib.MAX_WBITS)
    out = dz.decompress(d) + dz.flush()
i = 0
while i + 110 <= len(out):
    hdr = out[i:i+110]
    if not hdr.startswith(b'070701'):
        break
    filesize = int(hdr[54:62], 16)
    namesize = int(hdr[94:102], 16)
    name = out[i+110:i+110+namesize-1].decode('utf-8', 'replace')
    if name.startswith('./'):
        name = name[2:]
    data_at = i + data_off(namesize)
    if 'fstab' in name:
        sys.stdout.write('# ' + name + '\n' + out[data_at:data_at+filesize].decode('utf-8', 'replace'))
    i = data_at + pad4(filesize)
PY
say "  entries in it: $N_ENTRIES"
say
say "  every entry whose NAME contains fstab:"
if grep -qi 'fstab' "$RDLIST"; then
  grep -i 'fstab' "$RDLIST" | sed 's/^/    /' | quiet
else
  say "    (none -- and that is the reading, not an empty list to scroll past)"
fi
say
say "  the entries this block turns on (the container's own view of the firmware directory):"
for e in vendor firmware dsp bt_firmware sys; do
  if grep -qx "$e" "$RDLIST"; then say "    $e   PRESENT in the ramdisk root"; else say "    $e   ABSENT"; fi
done
say

# ==================================================================================================
say
say "== 3. where the container's /vendor/firmware_mnt comes from =="
# ==================================================================================================
# In the ramdisk root, `firmware` and `dsp` and `bt_firmware` are SYMLINKS INTO `/vendor`, and `/vendor`
# is a REAL but EMPTY directory in the ramdisk -- i.e. it is a placeholder for exactly the mount the
# fstab loop was supposed to perform. So the two sides of the missing mount can be printed side by side.
# The python block below writes to STDOUT directly, so `say` never saw it -- which is exactly how
# --quiet leaked these lines while suppressing everything around them. They go through the same gate.
python3 - "$W/android-ramdisk.img" <<'PY' | while IFS= read -r _ln; do say "$_ln"; done
import sys, gzip, zlib
def pad4(n):
    return (n + 3) & ~3
def data_off(namesize):
    # newc: NULs follow the pathname so that (fixed header + pathname) is a multiple of four.
    return 110 + namesize + ((4 - ((110 + namesize) % 4)) % 4)
d = open(sys.argv[1], 'rb').read()
try:
    out = gzip.decompress(d)
except Exception:
    dz = zlib.decompressobj(16 + zlib.MAX_WBITS)
    out = dz.decompress(d) + dz.flush()
i = 0
want = {'vendor', 'firmware', 'dsp', 'bt_firmware'}
while i + 110 <= len(out):
    hdr = out[i:i+110]
    if not hdr.startswith(b'070701'):
        break
    mode = int(hdr[14:22], 16)
    filesize = int(hdr[54:62], 16)
    namesize = int(hdr[94:102], 16)
    name = out[i+110:i+110+namesize-1].decode('utf-8', 'replace')
    if name.startswith('./'):
        name = name[2:]
    data_at = i + data_off(namesize)
    if name in want:
        kind = 'symlink -> ' + out[data_at:data_at+filesize].decode('utf-8', 'replace') if (mode & 0o170000) == 0o120000 else 'directory'
        print(f"    {name:14s} {kind}")
    i = data_at + pad4(filesize)
PY
say

# ==================================================================================================
say
say "== 4. the rootfs side: the two symlinks the kernel's firmware path resolves through =="
# ==================================================================================================
if [ "$ROOTFS_OK" = 1 ]; then
  V=$(debugfs -R 'stat /vendor' "$ROOTFS" 2>/dev/null | sed -n 's/^Inode:.*Type: \(.*\)    Mode.*/\1/p' | sed -n '1p')
  # `debugfs -R cat` does NOT follow a link; `stat` prints a fast symlink's destination on its own
  # line, which is the reading that was being asked for. The first version printed '?', which is a
  # check that could not report.
  VT=$(debugfs -R 'stat /vendor' "$ROOTFS" 2>/dev/null | sed -n 's/^Fast link dest: //p' | sed -n '1p')
  say "  in the UT rootfs image: /vendor is a ${V:-?} whose target is '${VT:-?}'"
  say "  and /var/lib/lxc/android/rootfs in that image holds:"
  debugfs -R 'ls /var/lib/lxc/android/rootfs' "$ROOTFS" 2>/dev/null \
    | tr -s ' ' '\n' | grep -vE '^$|^\(|^[0-9]+$' | grep -vE '^\.\.?$' | sed 's/^/    /' | quiet || true
  say "  (empty is the shipped shape, and it is not a defect: the ramdisk is mount --move'd ON TOP of it"
  say "   at boot, which is what hides anything that image might otherwise have put there)"
else
  say "  (the rootfs image is not readable, so this section is not read -- check the path with --rootfs)"
fi
say

# ==================================================================================================
SHOW=1
say "== 5. the verdict =="
# ==================================================================================================
# Restated here so the verdict travels with its input: an archived verdict without the identity of
# what produced it is a sentence about an unnamed file.
say "  read from:"
for f in "$BOOT" "$ANDROID" "$ROOTFS"; do
  [ -r "$f" ] || continue
  say "    $(sha256sum -- "$f" | awk '{print $1}')  $f"
done
say
say
if grep -qi 'fstab' "$RDLIST"; then
  # An fstab IS there. Then the question moves one level down, and the answer is about its CONTENT --
  # which this instrument can only read if the ramdisk was unpacked, so it says what it can and no more.
  say "   The glob is NOT empty, so the loop DOES run -- which moves the question to the file's CONTENT."
  say "   Entries found:"
  grep -i 'fstab' "$RDLIST" | sed 's/^/     /'
  say
  say "   the lines in it that could put the firmware somewhere:"
  if grep -qE 'firmware_mnt|modem|/vendor' "$FSTAB_TXT"; then
    grep -nE 'firmware_mnt|modem|/vendor' "$FSTAB_TXT" | sed 's/^/     /'
    say
    say "== verdict: A LINE FOR THE MODEM IS THERE"
    say "   So the glob expands AND the file asks for the mount. If the firmware is still missing on the"
    say "   phone then the question is no longer this script's: it is the mount itself -- the device node,"
    say "   the filesystem type, or the options -- and that is read on the device, not from an image."
  else
    say "     (no line matches firmware_mnt/modem//vendor -- so here is every line the file DOES carry,"
    say "      because 'nothing matched' and 'nothing was read' look the same otherwise:)"
    grep -vE '^\s*#|^\s*$' "$FSTAB_TXT" | sed 's/^/     /'
    say
    say "== verdict: NO LINE FOR THE MODEM"
    say "   The loop RUNS and mounts whatever the file names, but it names nothing that would fill"
    say "   /vendor/firmware_mnt -- so the same silence arrives by a different route: a file that is"
    say "   present, is read, and does not mention this mount."
  fi
  exit 0
fi

say "== verdict: THE LOOP IS EMPTY"
say "   The ramdisk halium extracts -- the one that lands ON the glob's directory -- carries"
say "   $N_ENTRIES entries and NOT ONE of them has 'fstab' in its name. So:"
say
say "     'cat /var/lib/lxc/android/rootfs/fstab*'  ->  prints an error, exits non-zero"
say "     the 'while read' body                    ->  NEVER RUNS"
say "     the mkdir and the mount                  ->  never happen"
say "     the stderr                              ->  goes to the initrd's console, and the boot continues"
say
say "   Which is the mechanism docs 120 named as hypothesis (a) and left for the device: NOTHING IS"
say "   MOUNTED, AND NOTHING IS REPORTED. The container's /vendor/firmware_mnt -- the empty directory the"
say "   ramdisk carries for exactly this mount -- stays empty, so the modem firmware the kernel asks for"
say "   is not there to be loaded, however correct the path in the cmdline is."
say
say "   What this is NOT: a claim about the phone. It is a claim about two IMAGE FILES, and the images are"
say "   the ones this project staged and the one that was pushed to /data/system.img. The device-side"
say "   confirmation is one command, and it is the one docs 120 already wrote into the probe:"
say
say "     ls -l /var/lib/lxc/android/rootfs/ | grep -c fstab      # expect 0"
say
say "   If that ever reads non-zero, the image on the phone is NOT the image this was read from, and that"
say "   is the finding -- not a contradiction."
say
say "   THE REPAIRS, and neither is applied here because both are device side:"
say "     (a) give the ramdisk an fstab -- a file inside /data/system.img, i.e. a USERDATA-side write, not"
say "         a critical partition, but it means rewriting a 4 GB image the container boots from;"
say "     (b) make the boot script not depend on that file -- an initrd change, i.e. a 'fastboot flash"
say "         boot', which is what this project already does routinely and can roll back."
say "   Which one is right depends on which file the NEXT change wants to own, and that is a decision for"
say "   a person with the device in hand."
exit 0
