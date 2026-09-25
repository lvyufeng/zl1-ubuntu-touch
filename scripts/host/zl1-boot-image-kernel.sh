#!/usr/bin/env bash
# What kernel is inside this boot image, and does ITS OWN CONFIG carry the driver?
#
# Why this exists
# ---------------
# docs 157 settled the fingerprint's question by reading the config THAT IS INSIDE THE KERNEL IMAGE --
# not a defconfig on a laptop -- and docs 158 measured the distance from there to a driver. Both of those
# readings were made with a one-off: a command somebody typed, whose output went into a document. The
# reading itself was never a tool, so nothing in this tree can answer "what does the kernel in the image
# I am about to flash say" without a person retyping it -- and the whole point of this project's boot
# economy is that the image is the expensive thing and it is shared by rote (docs 152: an image gets
# REBUILT UNDER THE SAME FILENAME).
#
# So this is that reading, as a tool. Given a boot image it opens read-only and answers:
#
#   1. THE HEADER      an Android boot image: page size, kernel/ramdisk/second sizes, the cmdline. The
#                      kernel BLOB is what the bootloader loads, and on this board it is `Image.gz-dtb`:
#                      one gzip member (the kernel) with the board's device trees appended after it.
#   2. THE KERNEL      the blob's own sha256, and the sha256 and size of the DECOMPRESSED Image -- the
#                      thing a linker produced and a bootloader will run.
#   3. THE CONFIG      `CONFIG_IKCONFIG_PROC=y` means the kernel carries its own config, and it is
#                      findable in the flat Image between `IKCFG_ST` and `IKCFG_ED`. This reads THAT --
#                      the same bytes the device would answer with at `/proc/config.gz`.
#   4. THE DRIVER      whether the driver's own identifying strings are IN the decompressed kernel. A
#                      config line says what was asked for; a string in the Image says what is there.
#                      They are two readings and this prints both, because the interesting failure is
#                      exactly when they disagree.
#   5. --diff A B      TWO readings, in this order, and the order matters. (a) THE LAYERS: which of the
#                      layers this tool reads -- the whole image, the kernel blob, the decompressed
#                      Image, the appended device trees, the ramdisk, the cmdline -- moved between the
#                      two. (b) THE OPTIONS: which of the kernel's own config options changed state.
#                      This is the reading that makes "the only change is the one line I made" a fact
#                      rather than an intention, and both halves are computed from the two images.
#
#                      (a) exists because (b) alone answers a NARROWER question than the tool's name.
#                      The config is ONE layer: two images can print `0 option(s) differ` while their
#                      RAMDISKS are completely different -- which is exactly what the pair
#                      `-fpdriver` / `-fpdriver-modemfw` does, because the first changes the kernel and
#                      the second changes the initramfs. A reader who diffs two boot images and sees
#                      only the config will conclude they are the same, and be wrong about the half
#                      that boots. Neither half is a verdict on its own: the layer table says WHICH
#                      files moved, the option list says WHAT moved inside the kernel.
#
# THE DISTINCTION THIS FILE EXISTS TO KEEP: "this kernel's config does not mention the option" and "this
# kernel carries NO embedded config at all" are different facts, about different things, and a tool that
# prints one for the other is this project's most-recorded defect. A kernel without IKCONFIG answers
# `NOT EMBEDDED` and never `not set`. In the same way a truncated or non-boot file gets a verdict that
# claims nothing rather than a config full of absence.
#
# What this NEVER does: it opens no device, runs no kbuild, and writes nothing outside a temp directory.
# It is an image reader -- the thing you point at a file on this laptop.
#
# Usage: zl1-boot-image-kernel.sh [--watch OPT ...] [--diff] IMG [IMG ...]
#                                     [--quiet] [--json] [--keep] [--explain]
#   --watch OPT     an extra config option to report the state of (repeatable). The defaults are the
#                   fingerprint's four names plus the two blocks docs 157 separated.
#   --diff          with exactly two images: print which layer moved (image, kernel blob, Image,
#                   appended device trees, ramdisk, cmdline) and then every config option whose state
#                   differs. `--quiet` does not suppress either -- this flag IS the reading.
#   --quiet         the verdicts only, not the readings.
#   --json          one JSON object per image on stdout (for anything that wants to read this).
#   --keep          keep the temp directory and print its path.
#   --explain       what the verdicts mean and what this refuses to do.
#
# Exit codes: 0 the reading was made (whatever it says); 2 a required tool is missing or the arguments
#             are wrong; 3 an image could not be read at all -- NOTHING is claimed about it.

set -uo pipefail
export LC_ALL=C

QUIET=0; KEEP=0; EXPLAIN=0; JSON=0; DIFF=0
WATCH="CONFIG_INPUT_GP5XX8 CONFIG_MSM_QBT1000 CONFIG_INPUT_FPC1020 CONFIG_INPUT CONFIG_IKCONFIG CONFIG_IKCONFIG_PROC"
IMGS=""

while [ $# -gt 0 ]; do
  case "$1" in
  --watch)  WATCH="$WATCH ${2?--watch needs an option name}"; shift 2 ;;
  --diff)   DIFF=1; shift ;;
  --quiet)  QUIET=1; shift ;;
  --json)   JSON=1; shift ;;
  --keep)   KEEP=1; shift ;;
  --explain)
    sed -n '/^# THE DISTINCTION THIS FILE/,/^# Usage:/p' "$0" | sed 's/^# \?//' | sed '$d'
    exit 0 ;;
  --help|-h)
    awk 'NR==1{next} /^#/{print; next} {exit}' "$0"
    exit 0 ;;
  -*) echo "unknown argument: $1 (--help for usage)" >&2; exit 2 ;;
  *)  IMGS="$IMGS $1"; shift ;;
  esac
done

[ -n "$IMGS" ] || { echo "usage: $0 [--watch OPT] [--diff] IMG [IMG ...] (--help for the rest)" >&2; exit 2; }
W=$(mktemp -d "${TMPDIR:-/tmp}/zl1-bootimg.XXXXXX") || exit 2
cleanup() { [ "$KEEP" = 1 ] || rm -rf "$W"; }
trap cleanup EXIT

say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }

for t in python3 sha256sum; do
  command -v "$t" >/dev/null 2>&1 || { echo "missing: $t" >&2; exit 2; }
done

# The reader. One python program, because every step of it is a byte format with a self-consistency
# check available, and each of those checks is a defect this project has shipped before:
#   * the boot header's page size decides where every section starts, and a wrong one silently reads the
#     SECOND half of the kernel as the ramdisk;
#   * `Image.gz-dtb` is a gzip stream WITH APPENDED DATA -- `gzip -d` on the whole file refuses it, and
#     reading the whole file as the kernel would hash 2 MB of device trees as if they were code. A
#     decompression object exposes `.unused_data`, which is exactly the boundary;
#   * the embedded config is not the whole story of where `IKCFG_ST` appears: it is searched in the flat
#     Image, and `IKCFG_ED` must come AFTER it, and the bytes between must actually inflate.
# A reader that cannot say "I found the marker and the bytes after it are not a gzip stream" cannot
# report the difference between a kernel without a config and a marker in the middle of a string table.
cat > "$W/read.py" <<'PY'
import hashlib, json, os, struct, sys, zlib

ANDROID_MAGIC = b'ANDROID!'

def u32(b, o):
    return struct.unpack('<I', b[o:o+4])[0]

def read_boot(path):
    """The Android boot image header, plus the kernel blob. Sizes are checked against the file."""
    d = open(path, 'rb').read()
    if d[:8] != ANDROID_MAGIC:
        raise ValueError('not an Android boot image: the first 8 bytes are %r, not %r' % (d[:8], ANDROID_MAGIC))
    if len(d) < 44:
        raise ValueError('shorter than a boot image header (%d bytes)' % len(d))
    kernel_size = u32(d, 8)
    kernel_addr = u32(d, 12)
    ramdisk_size = u32(d, 16)
    ramdisk_addr = u32(d, 20)
    second_size = u32(d, 24)
    second_addr = u32(d, 28)
    tags_addr = u32(d, 32)
    page_size = u32(d, 36)
    # The field at 40 is `dt_size` in header version 0 and `header_version` in v1+. On this board the
    # page size and the segment sizes settle it: a v0 image has dt_size == 0 and puts the DTBs in the
    # kernel blob, which is what `Image.gz-dtb` IS. Both are printed so the reader is not the judge.
    field40 = u32(d, 40)
    header_version = u32(d, 44) if len(d) >= 48 else 0
    cmdline = d[64:64+512].split(b'\0')[0].decode('utf-8', 'replace')
    name = d[48:64].split(b'\0')[0].decode('utf-8', 'replace')
    if page_size not in (2048, 4096, 8192, 16384, 32768, 65536):
        raise ValueError('page size %d is not a power-of-two page this format uses' % page_size)
    def pages(n):
        return (n + page_size - 1) // page_size
    koff = page_size
    roff = koff + pages(kernel_size) * page_size
    soff = roff + pages(ramdisk_size) * page_size
    if kernel_size == 0 or koff + kernel_size > len(d):
        raise ValueError('the header claims a %d-byte kernel, which does not fit in %d bytes' % (kernel_size, len(d)))
    if ramdisk_size and roff + ramdisk_size > len(d):
        raise ValueError('the header claims a %d-byte ramdisk, which does not fit' % ramdisk_size)
    return {
        'file': path, 'size': len(d), 'sha256': hashlib.sha256(d).hexdigest(),
        'page_size': page_size, 'kernel_size': kernel_size, 'ramdisk_size': ramdisk_size,
        'kernel_addr': kernel_addr, 'ramdisk_addr': ramdisk_addr, 'tags_addr': tags_addr,
        'second_size': second_size, 'field40': field40, 'header_version': header_version,
        'name': name, 'cmdline': cmdline,
        'kernel': d[koff:koff+kernel_size],
        'kernel_sha256': hashlib.sha256(d[koff:koff+kernel_size]).hexdigest(),
        'ramdisk_sha256': hashlib.sha256(d[roff:roff+ramdisk_size]).hexdigest() if ramdisk_size else '',
    }

def gunzip_member(blob):
    """The FIRST gzip member, and the bytes after it. `unused_data` is the boundary between the kernel
    and the device trees appended after it -- there is no other way to find it.
    The zlib error is caught and re-worded on purpose: `invalid distance code` is a message about a
    DECODER, and the fact this instrument has to report is about the FILE -- that the blob is not one
    complete member. A raw zlib string in a verdict sends the reader to the wrong layer."""
    d = zlib.decompressobj(16 + zlib.MAX_WBITS)
    try:
        out = d.decompress(blob)
        out += d.flush()
    except zlib.error as e:
        raise ValueError('the kernel blob is not one complete gzip member (%s)' % e)
    if not d.eof:
        raise ValueError('the kernel blob is not one complete gzip member (it ends mid-stream)')
    return out, d.unused_data

def embedded_config(image):
    """The kernel's own config, out of the flat Image. CONFIG_IKCONFIG writes it as the marker IKCFG_ST,
    a gzip stream, and the marker IKCFG_ED. Returns (text, why-not) -- and 'why-not' is never '' when
    the text is ''."""
    i = image.find(b'IKCFG_ST')
    if i < 0:
        return '', 'the kernel image contains no IKCFG_ST marker: this kernel was built without CONFIG_IKCONFIG'
    j = image.find(b'IKCFG_ED', i)
    if j < 0:
        return '', 'IKCFG_ST is present and IKCFG_ED is not after it: the marker is not the config'
    raw = image[i+8:j]
    # Two layouts exist: the older one is the gzip stream directly, the newer prefixes an 8-byte length.
    # Both are tried, and which one worked is part of the reading rather than a detail.
    for skip in (0, 8):
        try:
            txt = zlib.decompressobj(16 + zlib.MAX_WBITS).decompress(raw[skip:])
        except Exception:
            continue
        if txt.startswith(b'#') or b'CONFIG_' in txt[:200]:
            return txt.decode('utf-8', 'replace'), ''
    return '', 'the bytes between IKCFG_ST and IKCFG_ED inflate to nothing that looks like a config'

def strings_in(image, needles):
    """A config line says what was ASKED FOR; a string in the Image says what is THERE. They are two
    readings. This is the second one, and it is a plain search -- reported as found/not found and never
    as a claim about behaviour."""
    return {n: (image.find(n.encode()) >= 0) for n in needles}

img = sys.argv[1]
watch = [w for w in sys.argv[2].split() if w]
# The four names a driver compiled into the Image carries. `gf_spi.c` is NOT one of them and is here on
# purpose: it is the driver's own SOURCE FILENAME, and a `__FILE__` that only reaches the Image through
# debug output is not in an optimised build. It is a CONTROL -- a needle that is reachable and expected
# to read "not found" -- so the found/not-found column is visibly a comparison rather than a column that
# always says FOUND. The first run printed it in the same list as the other four with no such label,
# which reads as four findings and one partial failure on a kernel where nothing is wrong.
needles = ['goodix_fp', 'gf318m', 'goodix,fingerprint', 'goodix_fp_spi']
controls = ['gf_spi.c']
out = {'errors': []}
try:
    info = read_boot(img)
    image, appended = gunzip_member(info['kernel'])
    info['image_size'] = len(image)
    info['image_sha256'] = hashlib.sha256(image).hexdigest()
    info['appended_size'] = len(appended)
    info['appended_sha256'] = hashlib.sha256(appended).hexdigest() if appended else ''
    info['appended_fdts'] = appended.count(b'\xd0\x0d\xfe\xed')
    del info['kernel']
    try:
        cfg, why = embedded_config(image)
    except Exception as e:
        cfg, why = '', 'the embedded-config read failed: %s' % e
    info['config_text'] = cfg
    info['config_why'] = why
    opts = {}
    for w in watch:
        # A config file spells a symbol `CONFIG_FOO`; the caller may pass either spelling, so the
        # prefix is added here and the option is reported under the name it was asked about.
        name = w if w.startswith('CONFIG_') else 'CONFIG_' + w
        if not cfg:
            opts[w] = 'NO CONFIG EMBEDDED'
        elif ('\n%s=y\n' % name) in '\n' + cfg or cfg.startswith('%s=y\n' % name):
            opts[w] = 'y'
        elif ('\n%s=m\n' % name) in '\n' + cfg or cfg.startswith('%s=m\n' % name):
            opts[w] = 'm'
        elif ('# %s is not set' % name) in cfg:
            opts[w] = 'not set'
        else:
            opts[w] = 'absent from this config'
    info['options'] = opts
    info['strings'] = strings_in(image, needles)
    info['control'] = strings_in(image, controls)
    info['ok'] = True
except Exception as e:
    out['errors'].append(str(e))
    info = {'ok': False, 'error': str(e)}
out.update(info)
print(json.dumps(out))
PY

n=0; rc_all=0
seen=""
for img in $IMGS; do
  [ -r "$img" ] || { echo "unreadable image: $img (nothing is claimed about it)" >&2; rc_all=3; continue; }
  J=$(python3 "$W/read.py" "$img" "$WATCH" 2>"$W/err") || {
    echo "could not read $img: $(sed -n 1p "$W/err")" >&2; rc_all=3; continue; }
  ok=$(printf '%s' "$J" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("ok"))')
  if [ "$ok" != "True" ]; then
    err=$(printf '%s' "$J" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("error",""))')
    echo "== $img"
    echo "   UNREADABLE: $err"
    echo "   NOTHING IS CLAIMED about this file. That is not 'a kernel without a driver'."
    rc_all=3
    continue
  fi
  n=$((n + 1)); seen="$seen $img"
  if [ "$JSON" = 1 ]; then
    printf '%s\n' "$J"
    continue
  fi
  say "== $img"
  say "   file: $(printf '%s' "$J" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("%d bytes  sha256=%s" % (d["size"], d["sha256"][:16]))')"
  printf '%s' "$J" > "$W/one.json"
  # The columns are printed with `printf` and not through `say`, because `say` prints its arguments as
  # ONE `%s` -- a format string handed to it would come out verbatim (the first run of this file printed
  # `page=%s kernel=%s ...` followed by the values, which reads as a reading and is the format string).
  [ "$QUIET" = 1 ] || printf '   boot header: page=%s kernel=%s ramdisk=%s second=%s field@40=%s\n' \
      "$(python3 -c 'import json;d=json.load(open("'$W'/one.json"));print(d["page_size"])')" \
      "$(python3 -c 'import json;d=json.load(open("'$W'/one.json"));print(d["kernel_size"])')" \
      "$(python3 -c 'import json;d=json.load(open("'$W'/one.json"));print(d["ramdisk_size"])')" \
      "$(python3 -c 'import json;d=json.load(open("'$W'/one.json"));print(d["second_size"])')" \
      "$(python3 -c 'import json;d=json.load(open("'$W'/one.json"));print(d["field40"])')"
  say "   cmdline: $(python3 -c 'import json;d=json.load(open("'$W'/one.json"));c=d["cmdline"][:110];print(c + ("..." if len(d["cmdline"])>110 else ""))')"
  say "   kernel blob (what the bootloader loads): sha256=$(python3 -c 'import json;d=json.load(open("'$W'/one.json"));print(d["kernel_sha256"][:16])')"
  say "   decompressed Image: $(python3 -c 'import json;d=json.load(open("'$W'/one.json"));print("%d bytes  sha256=%s" % (d["image_size"], d["image_sha256"][:16]))')"
  say "   appended after it:  $(python3 -c 'import json;d=json.load(open("'$W'/one.json"));print("%d bytes, %d FDT magic(s)  sha256=%s" % (d["appended_size"], d["appended_fdts"], d["appended_sha256"][:16]))')"
  say "   ramdisk: sha256=$(python3 -c 'import json;d=json.load(open("'$W'/one.json"));print(d["ramdisk_sha256"][:16] or "(none)")')"
  why=$(printf '%s' "$J" | python3 -c 'import json,sys; print(json.load(sys.stdin)["config_why"])')
  if [ -n "$why" ]; then
    say "   THE KERNEL'S OWN CONFIG: NOT EMBEDDED -- $why"
    say "   So the option states below are UNKNOWN, not 'not set'. Those are different facts."
  else
    say "   the kernel's own config: $(printf '%s' "$J" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["config_text"]))') bytes, read from the Image itself (the same bytes the device answers at /proc/config.gz)"
  fi
  printf '%s' "$J" | python3 -c '
import json,sys
d=json.load(sys.stdin)
for k,v in d["options"].items():
    print("     %-26s %s" % (k, v))' | while IFS= read -r l; do say "$l"; done
  say "   the driver, IN the image (a config line says what was asked for; this says what is there):"
  printf '%s' "$J" | python3 -c '
import json,sys
d=json.load(sys.stdin)
print("     " + "  ".join("%s=%s" % (k, "FOUND" if v else "not found") for k,v in d["strings"].items()))' | while IFS= read -r l; do say "$l"; done
  # The control is printed on its own line, labelled, because it is EXPECTED to read "not found" and a
  # reader who does not know that reads it as a partial failure (see the note where it is defined).
  printf '%s' "$J" | python3 -c '
import json,sys
d=json.load(sys.stdin)
c=d.get("control",{})
if c:
    print("     control (expected not found -- a source FILENAME is not in an optimised Image): "
          + "  ".join("%s=%s" % (k, "FOUND" if v else "not found") for k,v in c.items()))' | while IFS= read -r l; do say "$l"; done
  # The verdict is about the IMAGE, and the two facts that make it are printed above it.
  V=$(printf '%s' "$J" | python3 -c '
import json,sys
d=json.load(sys.stdin)
if d["config_why"]:
    print("config-not-embedded")
elif d["options"].get("CONFIG_INPUT_GP5XX8") == "y":
    print("carries-the-driver" if d["strings"].get("goodix_fp") else "config-says-y-and-the-image-disagrees")
else:
    print("does-not-carry-the-driver")')
  # The verdict is NOT a reading: `--quiet` suppresses the readings and keeps this line, because a
  # `--quiet` that prints nothing is an option doing the opposite of its manual (docs 152). The first
  # draft printed it through `say`, so `--quiet` produced a single blank line -- which reads as "no
  # problem found" to anything that only looks at whether output came back.
  printf '   -> %s\n' "$V"
done

if [ "$DIFF" = 1 ]; then
  set -- $seen
  if [ "$#" != 2 ]; then
    say ""
    say "== --diff needs exactly two READABLE images; $# were read ($*)"
    rc_all=2
  else
    a="$1"; b="$2"
    python3 "$W/read.py" "$a" "$WATCH" > "$W/a.json"
    python3 "$W/read.py" "$b" "$WATCH" > "$W/b.json"
    say ""
    say "== the layers this tool reads, and which of them MOVED between the two images"
    say "   (the option list below answers a NARROWER question than this one: two images can have"
    say "    identical kernels and completely different ramdisks, so read both.)"
    python3 - "$W/a.json" "$W/b.json" <<'PYEOF'
import json, sys
A = json.load(open(sys.argv[1])); B = json.load(open(sys.argv[2]))

def short(v, n=16):
    v = str(v or '')
    return v[:n] if v else '(none)'

# EVERY LAYER THIS TOOL ACTUALLY READS. The label is what a reader has to be able to name; the two keys
# are the JSON fields on each side -- they are the same field name today, and they are listed per side
# because that is what makes a row a comparison rather than a lookup.
rows = [
    ('boot image (whole file)',                 'sha256',          'sha256'),
    ('kernel blob (what the bootloader loads)', 'kernel_sha256',   'kernel_sha256'),
    ('decompressed Image',                      'image_sha256',    'image_sha256'),
    ('appended device trees',                   'appended_sha256', 'appended_sha256'),
    ('ramdisk',                                 'ramdisk_sha256',  'ramdisk_sha256'),
    ('cmdline',                                 'cmdline',         'cmdline'),
]
# The device-tree row carries its FDT count, because `(none)` on BOTH sides is also how an image with no
# appended trees reads -- and "both have none" must not look like "both have the same trees".
#
# AND THE COMPARISON IS ON THE FULL VALUE, NEVER ON WHAT IS DISPLAYED. This is not a style point: the
# first cut of this table compared the TRUNCATED strings, and the cmdline row printed
# `androidboot.hard  androidboot.hard  same` for two images whose cmdlines are 493 characters long and
# differ further in. A display width that silently decides the verdict is the same defect this table was
# written to remove, one layer down -- so the pair compared is (full, full) and only the pair PRINTED is
# shortened, with the width named under the table.
labelled = []
for label, ka, kb in rows:
    if label.startswith('appended'):
        label = '%s (%s FDT)' % (label, A.get('appended_fdts'))
    labelled.append((label, str(A.get(ka) or ''), str(B.get(kb) or '')))
w = max(len(r[0]) for r in labelled)
wv = min(16, max(len(short(r[1])) for r in labelled), max(len(short(r[2])) for r in labelled))
moved = []
for label, fa, fb in labelled:
    same = (fa == fb)
    if not same:
        moved.append(label)
    print('   %-*s  %-*s %-*s %s' % (w, label, wv, short(fa, wv), wv, short(fb, wv),
                                     'same' if same else 'DIFFERS'))
print('   (the first %d characters of each value are shown; the comparison above is on the WHOLE value,' % wv)
print('    and the full hashes are printed in the per-image sections above)')
if not moved:
    print('   -> no layer this tool reads differs: at every layer above the two images are identical')
else:
    print('   -> %d of %d layers differ: %s' % (len(moved), len(labelled), '; '.join(moved)))
    if any(m.startswith('ramdisk') for m in moved):
        # THE SENTENCE THIS TABLE EXISTS FOR. A reader who diffs two boot images and sees only the option
        # list will read `0 option(s) differ` as "these two images are the same" -- and be wrong about the
        # half that boots. Measured on the pair `-fpdriver` / a kernel+ramdisk rebuild of it: identical
        # kernels, identical device trees, identical cmdline, and two completely different ramdisks.
        print('      (a ramdisk difference is INVISIBLE to the option list below: the config is one layer)')
PYEOF
    say ""
    say "== the options that DIFFER between the two kernels' own configs"
    say "   (this is computed from the two IMAGES, so it needs no defconfig to agree with -- and it answers"
    say "    a NARROWER question than the layer table above: the config is one layer of the image)"
    python3 - "$W/a.json" "$W/b.json" <<'PY'
import json, sys
A = json.load(open(sys.argv[1])); B = json.load(open(sys.argv[2]))
ta, tb = A.get('config_text',''), B.get('config_text','')
if not ta or not tb:
    print('   ONE OF THE TWO KERNELS CARRIES NO CONFIG: cannot be made, and that is reported rather')
    print('   than shown as an empty difference -- because an empty difference is exactly what "the')
    print('   two kernels were built from the same config" looks like.')
    sys.exit(0)
da = dict(l.split('=', 1) if '=' in l else (l, '') for l in ta.splitlines() if l and not l.startswith('#'))
db = dict(l.split('=', 1) if '=' in l else (l, '') for l in tb.splitlines() if l and not l.startswith('#'))
na = set(l[2:].split(' is not set')[0] for l in ta.splitlines() if l.startswith('# ') and 'is not set' in l)
nb = set(l[2:].split(' is not set')[0] for l in tb.splitlines() if l.startswith('# ') and 'is not set' in l)
def state(name, d, n):
    return d.get(name, 'not set' if name in n else '(absent)')
keys = sorted(set(da) | set(db) | na | nb)
diff = [(k, state(k, da, na), state(k, db, nb)) for k in keys if state(k, da, na) != state(k, db, nb)]
print('   %d option(s) differ:' % len(diff))
for k, x, y in diff:
    print('     %-34s %-12s -> %s' % (k, x, y))
if not diff:
    print('     (none -- the two kernels were built from the same config)')
PY
  fi
fi

if [ "$n" = 0 ]; then
  echo "no image could be read: every reading in this run is about nothing (exit 3)" >&2
  exit 3
fi
[ "$KEEP" = 1 ] && echo "kept: $W"
exit $rc_all
