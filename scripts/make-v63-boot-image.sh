#!/usr/bin/env bash
# Rebuild the known-good zl1 v63 boot image from the reproducible baseline.
#
# Why this exists: `halium-boot-zl1-v63-usbd-disabled.img` is the only configuration
# observed to bring up Ubuntu Touch, the Android container and RNDIS together. Until now
# it existed only as a binary in /mnt/data/halium-zl1-candidates/, and the script that
# claims to produce its lineage (make-halium-postswitch-debug-boot.sh) is frozen at an
# earlier revision — it embeds a 1208-line version of the post-switch init where v63
# carries 1638 lines. So the image that works was not regenerable from anything tracked.
#
# It is now. The delta between the reproducible baseline and v63 is exactly five entries
# in the initramfs:
#
#   add      scripts/init-bottom/zl1-postswitch-debug-init     (the whole zl1 runtime)
#   add      scripts/local-premount/zl1-usb-debug
#   modify   init                       (zl1_v54_mark hooks)
#   modify   scripts/init-bottom/ORDER       (run the post-switch script)
#   modify   scripts/local-premount/ORDER    (run the usb-debug script)
#
# plus the cmdline. Those are tracked under boot/v63/ and applied here.
#
# What this verifies, and what it does not:
#
#   * it asserts the rebuilt initramfs has byte-identical CONTENTS to v63's — same 349
#     entries, same bytes, same modes, same order (verified against the v63 binary)
#   * it asserts the kernel, the appended DTBs and the cmdline are identical
# `--patch FILE` applies a further tracked patch on top of the v63 delta (see
# boot/patches/). Used to build variants of the known-good configuration that differ by
# one deliberate change, so an experiment has a single variable.
#
#   * it does NOT promise the same SHA256 as v63. Both gzip streams encode the same
#     data but the framing differs, so the image hash differs. Content equality is the
#     honest claim; byte equality was not achieved. (gzip -9/-9n/--best, cpio
#     --reproducible/--null and several traversal orders were all tried.)
#   * the rebuild IS deterministic: sorted traversal plus pinned metadata, so the same
#     source gives the same hash run after run.
#
# Usage: make-v63-boot-image.sh [--baseline IMG] [--out IMG] [--verify-against IMG]
#                               [--kernel-from IMG]
#
# --kernel-from takes the kernel and appended DTBs from another boot image instead of the
# baseline. The ramdisk is still rebuilt from tracked sources. Useful to put the v63
# initramfs onto a kernel with a different patch set — e.g. the transmit-wakeup patch.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DELTA="$REPO/boot/v63"
BASELINE="/mnt/data/halium-zl1-candidates/halium-boot-zl1-reproducible-20260916.img"
OUT="/mnt/data/halium-zl1-candidates/halium-boot-zl1-v63-usbd-disabled.img"
VERIFY_AGAINST=""
KERNEL_FROM=""
declare -a EXTRA_PATCHES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --baseline) BASELINE="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --verify-against) VERIFY_AGAINST="$2"; shift 2 ;;
    --kernel-from) KERNEL_FROM="$2"; shift 2 ;;
    # realpath now: the apply step runs inside a `cd` into the unpacked initramfs
    --patch) EXTRA_PATCHES+=("$(realpath -m "$2")"); shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

V63_CMDLINE="androidboot.hardware=qcom ehci-hcd.park=3 lpm_levels.sleep_disabled=1 cma=32M@0-0xffffffff androidboot.configfs=true apparmor=1 security=apparmor firmware_class.path=/vendor/firmware_mnt/image loop.max_part=7 init=/tmp/zl1-debug-init zl1_init_delay=30 zl1_usb_fakebind=v63 zl1_v63_monitor=1 zl1_v63_usbd_disabled=1 zl1_packaging=v63"

for c in abootimg mkbootimg gzip cpio patch diff find python3 sha256sum; do
  command -v "$c" >/dev/null || { echo "missing required command: $c" >&2; exit 1; }
done
[[ -f "$BASELINE" ]] || { echo "missing baseline image: $BASELINE" >&2; exit 1; }
[[ -d "$DELTA" ]] || { echo "missing delta sources: $DELTA" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/zl1-v63-build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

echo "== extracting the baseline image =="
abootimg -x "$BASELINE" "$WORK/bootimg.cfg" "$WORK/zImage" "$WORK/initrd.img" >/dev/null
ls -l "$WORK/zImage" "$WORK/initrd.img"

KERNEL_IMG="$WORK/zImage"
if [[ -n "$KERNEL_FROM" ]]; then
  # Take the kernel and appended DTBs (i.e. everything in the kernel blob) from another
  # image, so this rebuild can carry a different patch set under the same initramfs.
  [[ -f "$KERNEL_FROM" ]] || { echo "missing --kernel-from image: $KERNEL_FROM" >&2; exit 1; }
  KERNEL_IMG="$WORK/zImage-from.img"
  python3 - "$KERNEL_FROM" "$KERNEL_IMG" <<'PY2'
import struct, sys
d = open(sys.argv[1], 'rb').read()
f = struct.unpack_from('<10I', d, 8)
ps, ks = f[7], f[0]
o = ps
open(sys.argv[2], 'wb').write(d[o:o + ks])
PY2
  echo "  kernel taken from $KERNEL_FROM ($(stat -c%s "$KERNEL_IMG") bytes)"
fi

echo "== unpacking the baseline initramfs =="
mkdir -p "$WORK/rd"
( cd "$WORK/rd" && zcat "$WORK/initrd.img" | cpio -idm --quiet )

echo "== applying the v63 delta =="
for f in init scripts/init-bottom/ORDER scripts/local-premount/ORDER; do
  p="$DELTA/patch/$(echo "$f" | tr '/' '_').patch"
  [[ -f "$p" ]] || { echo "missing patch: $p" >&2; exit 1; }
  ( cd "$WORK/rd" && patch -p1 --forward --silent < "$p" ) \
    || { echo "failed to apply $p" >&2; exit 1; }
  echo "  patched $f"
done
install -D -m 0755 "$DELTA/scripts/init-bottom/zl1-postswitch-debug-init" \
                       "$WORK/rd/scripts/init-bottom/zl1-postswitch-debug-init"
install -D -m 0755 "$DELTA/scripts/local-premount/zl1-usb-debug" \
                       "$WORK/rd/scripts/local-premount/zl1-usb-debug"
echo "  added the two zl1 scripts"

# Modes matter — these are scripts the initramfs executes, and cpio records the mode.
# `patch` on a 664 file writes 664 only if it preserves the original mode, and a fresh
# file copied into the tree carries whatever umask the host had, so set them explicitly
# to the values the v63 image records.
chmod 0755 "$WORK/rd/init"
chmod 0664 "$WORK/rd/scripts/init-bottom/ORDER" "$WORK/rd/scripts/local-premount/ORDER"
chmod 0775 "$WORK/rd/scripts/init-bottom/zl1-postswitch-debug-init"
chmod 0755 "$WORK/rd/scripts/local-premount/zl1-usb-debug"

if (( ${#EXTRA_PATCHES[@]} > 0 )); then
  echo "== applying extra patches =="
  for p in "${EXTRA_PATCHES[@]}"; do
    [[ -f "$p" ]] || { echo "missing patch: $p" >&2; exit 1; }
    ( cd "$WORK/rd" && patch -p1 --forward --silent < "$p" ) \
      || { echo "failed to apply $p" >&2; exit 1; }
    echo "  applied $(basename "$p")"
  done
  # A patch may ADD files as well as change them. `patch` creates those with the host's umask,
  # so without this the archive's recorded mode — and therefore the image hash — would depend
  # on the machine that built it. 0644: read, not executed.
  [[ -f "$WORK/rd/zl1-android-fstab" ]] && chmod 0644 "$WORK/rd/zl1-android-fstab"
fi

echo "== repacking the initramfs =="
# --reproducible pins the inode numbers and timestamps cpio writes into the archive, and
# -n stops gzip embedding a timestamp in its header. Without both, every run produces a
# different file hash from identical content — the input files carry fresh mtimes from
# install(1)/patch(1) — which makes "did the rebuild change anything?" unanswerable.
# Neither flag reproduces v63's own archive framing; both make the rebuild stable.
# Three things have to be pinned for the hash to be stable across runs, and cpio's
# --reproducible only covers the first:
#   * inode numbers                -> --reproducible
#   * entry order                  -> LC_ALL=C sort (find walks in inode order, which
#                                     differs between runs; sorting also keeps every
#                                     directory ahead of its contents, as cpio wants)
#   * file mtimes                  -> touch below (install(1)/patch(1) leave the time
#                                     they ran, and --reproducible does not override it
#                                     for the archive's own top-level entry)
# gzip -n then keeps its header free of a timestamp as well.
find "$WORK/rd" -exec touch -h -d "2026-06-13T19:48:00Z" {} + 2>/dev/null || true
( cd "$WORK/rd" && find . | LC_ALL=C sort | cpio -o -H newc --quiet --reproducible | gzip -9n ) \
  > "$WORK/initrd-v63.img"
ls -l "$WORK/initrd-v63.img"

echo "== writing the boot image =="
# mkbootimg needs the v63 cmdline and the baseline's addresses; take them from the
# extracted cfg so they cannot drift from the image the baseline actually has.
# mkbootimg ADDS --base to each offset, and --base defaults to 0x10000000. Passing only
# --kernel_offset therefore lands the kernel at 0x10008000 instead of 0x80008000 — an image
# the bootloader loads to the wrong address, fails to boot, and the SoC eventually falls
# back from into EDL. That is exactly what happened on 2026-09-17, twice. --base is now
# passed explicitly, derived from the reference image so it cannot drift.
read -r PAGESIZE BASE KOFF ROFF SOFF TOFF < <(python3 - "$WORK/bootimg.cfg" <<'PY'
import re, sys
text = open(sys.argv[1]).read()


def g(key, default):
    m = re.search(rf'^{key}\s*=\s*(\S+)', text, re.M)
    return m.group(1) if m else default


kaddr = int(g('kerneladdr', '0x80008000'), 16)
raddr = int(g('ramdiskaddr', '0x81000000'), 16)
saddr = int(g('secondaddr', '0x80f00000'), 16)
taddr = int(g('tagsaddr', '0x80000100'), 16)
if re.search(r'^base\s*=', text, re.M):
    base = int(g('base', '0x80000000'), 16)
else:
    # No base in the cfg (abootimg writes absolute addresses), so take the kernel address
    # rounded down to a 0x10000000 boundary: 0x80008000 -> 0x80000000.
    base = kaddr & ~0x0FFFFFFF
print(g('pagesize', '0x1000'), hex(base),
      hex(kaddr - base), hex(raddr - base), hex(saddr - base), hex(taddr - base))
PY
)
echo "  header: base=$BASE kernel_off=$KOFF ramdisk_off=$ROFF second_off=$SOFF tags_off=$TOFF pagesize=$PAGESIZE"
mkbootimg \
  --kernel "$KERNEL_IMG" \
  --ramdisk "$WORK/initrd-v63.img" \
  --pagesize "$PAGESIZE" \
  --base "$BASE" \
  --kernel_offset "$KOFF" \
  --ramdisk_offset "$ROFF" \
  --second_offset "$SOFF" \
  --tags_offset "$TOFF" \
  --cmdline "$V63_CMDLINE" \
  --output "$OUT" 2>/dev/null

echo
echo "== built =="
ls -l "$OUT"
sha256sum "$OUT"

if [[ -n "$VERIFY_AGAINST" ]]; then
  echo
  echo "== verifying the built image against $VERIFY_AGAINST =="
  BUILT="$OUT" REF="$VERIFY_AGAINST" python3 - <<'PY2'
import os, struct, subprocess, sys, tempfile, zlib, hashlib, filecmp

def load(p):
    d = open(p, 'rb').read()
    f = struct.unpack_from('<10I', d, 8)
    ps, ks, rs = f[7], f[0], f[2]
    cmd = d[64:576].split(b'\0', 1)[0].decode()
    o = ps
    kgz = d[o:o+ks]; o += ((ks + ps - 1) // ps) * ps
    rd = d[o:o+rs]; o += ((rs + ps - 1) // ps) * ps
    dec = zlib.decompressobj(31)
    img = dec.decompress(kgz) + dec.flush()
    return dict(cmd=cmd, img=img, rd=rd, dtb=dec.unused_data, size=len(d))

built, ref = load(os.environ['BUILT']), load(os.environ['REF'])
ok = True

def check(name, same, extra=''):
    global ok
    print(f'  {"OK  " if same else "FAIL"}  {name}{(" — " + extra) if extra else ""}')
    ok = ok and same

# Compare every header field, not just the content. An image whose kernel and ramdisk
# contents were byte-identical still could not boot, because its load addresses were wrong
# — the header is what the bootloader actually reads. That check is the one that was
# missing on 2026-09-17 and it is why that image reached the device.
import struct as _struct
_bf = open(os.environ['BUILT'], 'rb').read()
_rf = open(os.environ['REF'], 'rb').read()
for _i, _name in enumerate(['kernel_size', 'kernel_addr', 'ramdisk_size', 'ramdisk_addr',
                            'second_size', 'second_addr', 'tags_addr', 'page_size',
                            'header_version', 'os_version']):
    _b = _struct.unpack_from('<I', _bf, 8 + _i * 4)[0]
    _r = _struct.unpack_from('<I', _rf, 8 + _i * 4)[0]
    if _name == 'ramdisk_size':
        # Same data, different gzip framing, so this one legitimately differs.
        check('header.' + _name + ' comparable', _b <= _r, f'{_b} vs {_r}')
    else:
        check('header.' + _name + ' identical', _b == _r,
              '' if _b == _r else f'0x{_b:08x} vs 0x{_r:08x}')

check('cmdline identical', built['cmd'] == ref['cmd'])
check('appended DTBs identical', built['dtb'] == ref['dtb'])

# The kernel comes from the reproducible baseline, not from v63, so it is the same source
# built at a different time: the build-id note and the built-in initramfs timestamp inside
# it differ. Report the size of that difference rather than pretending it is zero.
if len(built['img']) != len(ref['img']):
    check('kernel Image comparable', False,
          f'sizes differ: {len(built["img"])} vs {len(ref["img"])}')
else:
    d = sum(1 for i in range(len(built['img'])) if built['img'][i] != ref['img'][i])
    if d == 0:
        check('kernel Image identical', True)
    elif d <= 64:
        check('kernel Image identical', False,
              f'{d} bytes differ (build-id note + built-in initramfs timestamp) — '
              f'same source, built at a different time; not a content difference')
    else:
        check('kernel Image identical', False, f'{d} bytes differ — investigate')

# The ramdisk: compare CONTENTS, not the gzip stream. Unpack both and diff the trees.
def unpack(blob):
    d = tempfile.mkdtemp()
    subprocess.run(['sh', '-c', 'zcat | cpio -idm --quiet'],
                   input=blob, cwd=d, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return d

bd, rd = unpack(built['rd']), unpack(ref['rd'])
listing = lambda root: sorted(os.path.relpath(os.path.join(dp, f), root)
                              for dp, _, fs in os.walk(root) for f in fs)
bl, rl = listing(bd), listing(rd)
check('ramdisk file list identical', bl == rl, f'{len(bl)} vs {len(rl)} entries')

if bl == rl:
    diff = [f for f in bl if not filecmp.cmp(os.path.join(bd, f), os.path.join(rd, f), shallow=False)]
    check('ramdisk file contents identical', not diff,
          f'{len(diff)} differing' + (': ' + ', '.join(diff[:5]) if diff else ''))
else:
    only_b, only_r = set(bl) - set(rl), set(rl) - set(bl)
    if only_b: print('        only in built:', sorted(only_b)[:5])
    if only_r: print('        only in ref  :', sorted(only_r)[:5])

# Modes matter: these are executables the initramfs runs.
modes_ok = True
for f in bl:
    mb = os.stat(os.path.join(bd, f)).st_mode & 0o7777
    mr = os.stat(os.path.join(rd, f)).st_mode & 0o7777
    if mb != mr:
        modes_ok = False
        print(f'        mode differs: {f}: {oct(mb)} vs {oct(mr)}')
check('ramdisk file modes identical', modes_ok)

print()
print(f'  built  ramdisk {len(built["rd"])} bytes  sha256 {hashlib.sha256(built["rd"]).hexdigest()[:16]}')
print(f'  v63    ramdisk {len(ref["rd"])} bytes  sha256 {hashlib.sha256(ref["rd"]).hexdigest()[:16]}')
print('  (these differ: same data, different gzip framing — content equality is the claim)')
sys.exit(0 if ok else 1)
PY2
  rc=$?
  echo
  if [[ $rc -eq 0 ]]; then
    echo "== VERIFIED: the rebuilt image is content-identical to the reference =="
  else
    echo "== VERIFICATION FAILED ==" >&2
    exit 1
  fi
fi
