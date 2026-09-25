#!/usr/bin/env bash
# Host-side selftest for scripts/host/zl1-boot-image-kernel.sh -- offline, no device, no build.
#
# What this asserts
# -----------------
# The subject answers a question that was previously answered by hand, once, into a document: WHAT DOES
# THE KERNEL INSIDE THIS BOOT IMAGE SAY ABOUT ITSELF. Its whole value is one distinction -- "this
# kernel's config does not mention the option" versus "this kernel carries no config at all" -- and a
# tool that prints the second as the first is this project's most-recorded defect. So the assertions are
# built around exactly that, from both directions:
#
#   * THE FIXTURES ARE IMAGES THE HARNESS BUILDS ITSELF, byte by byte, in this file's own format
#     implementation: a real gzip member (the kernel) with a real device tree APPENDED after it, a real
#     `IKCFG_ST`/`IKCFG_ED` config blob inside it, and a real Android boot header with page padding.
#     Nothing about the format is taken from the subject, so a subject that reads the format wrongly
#     cannot make the fixture agree with it.
#   * EVERY VERDICT IS REACHED, including the two that are NOT verdicts about the kernel: an image that
#     cannot be read at all (exit 3, nothing claimed) and a kernel with no embedded config (the option
#     states are UNKNOWN, and must never print as `not set`).
#   * MUTATIONS break ONE thing each in the SUBJECT and must redden a NAMED assertion. Five of them are
#     the defects this reader's first draft actually had or would have had: reading the whole kernel blob
#     as the Image (the appended device trees become code), searching `IKCFG_ED` from zero instead of
#     after `IKCFG_ST`, hard-coding the page size, folding "no config" into "not set", and printing an
#     empty difference when one of the two images carries no config to compare.
#
# WHAT THIS DOES NOT TEST: that the kernel boots, that the driver binds, or that flashing is safe. It
# tests that the READING is honest -- that what the tool says about an image is a fact about that image.

set -uo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/zl1-boot-image-kernel.sh"

case "${1:-}" in
--help|-h)
  awk 'NR==1{next} /^#/{print; next} {exit}' "$0"
  exit 0 ;;
esac

[ -r "$SRC" ] || { echo "the subject is not readable: $SRC" >&2; exit 2; }
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1
W=$(mktemp -d "${TMPDIR:-/tmp}/zl1-bootimg-selftest.XXXXXX") || exit 2
cleanup() { [ "$KEEP" = 1 ] || rm -rf "$W"; }
trap cleanup EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
want()   { if printf '%s\n' "$2" | grep -E -- "$1" >/dev/null 2>&1; then ok "$3"; else bad "$3"; printf '%s\n' "$2" | sed -n '1,14p' | sed 's/^/        | /'; fi; }
notwant(){ if printf '%s\n' "$2" | grep -E -- "$1" >/dev/null 2>&1; then bad "$3"; printf '%s\n' "$2" | grep -E -- "$1" | sed 's/^/        | /'; else ok "$3"; fi; }
wantf()  { case "$2" in *"$1"*) ok "$3" ;; *) bad "$3" ;; esac; }
verdict(){ printf '%s\n' "$2" | sed -n 's/^   -> //p' | sed -n 1p; }

echo "zl1 boot image kernel -- selftest"
echo "  subject: $SRC"
echo "  temp:    $W"

# ==================================================================================================
# The fixture writer. Every fixture in this file is an image assembled here: the Android boot header,
# a gzip member, the device trees appended after it, and an embedded config built from whatever options
# the caller names. `mkimage` takes a spec of the form `--opt NAME=STATE` (y / m / notset) plus
# `--nostrings`, `--noconfig`, `--badconfig`, `--noappend`.
# ==================================================================================================
cat > "$W/mkimage.py" <<'PY'
import gzip, io, os, struct, sys, zlib

def gz(b):
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode='wb', mtime=0) as f:
        f.write(b)
    return buf.getvalue()

def fdt(model):
    """A minimal but real FDT: the reader must hand the appended bytes back as a SEPARATE thing, and the
    only way to make that checkable is for them to be a valid tree that names itself."""
    strings = []
    def soff(n):
        if n not in strings:
            strings.append(n)
        return strings.index(n)
    sb = b''
    sb += struct.pack('>I', 1) + b'\0' + b'\0' * 3
    v = model.encode() + b'\0'
    sb += struct.pack('>III', 3, len(v), soff('model')) + v + b'\0' * ((4 - len(v) % 4) % 4)
    sb += struct.pack('>I', 2) + struct.pack('>I', 9)
    stb = b''.join(s.encode() + b'\0' for s in strings)
    return struct.pack('>10I', 0xd00dfeed, 56 + len(sb) + len(stb), 56, 56 + len(sb), 40,
                       0x11, 0x10, 0, len(stb), len(sb)) + b'\0' * 16 + sb + stb

def build(out, opts, strings_on=True, config_mode='ok', header='ok', append=True, page=4096,
          truncate=0, kernel_extra=b'', earlyed=False, badpage=False, cutmember=0, oversize=0):
    lines = ['#', '# Automatically generated file; DO NOT EDIT.', '#']
    for name, state in opts.items():
        lines.append('%s=y' % name if state == 'y' else '# %s is not set' % name)
    cfg = ('\n'.join(lines) + '\n').encode()
    if config_mode == 'ok':
        blob = b'IKCFG_ST' + gz(cfg) + b'IKCFG_ED'
    elif config_mode == 'lenprefixed':
        blob = b'IKCFG_ST' + struct.pack('<Q', len(gz(cfg))) + gz(cfg) + b'IKCFG_ED'
    elif config_mode == 'garbage':
        blob = b'IKCFG_ST' + b'\x00' * 64 + b'IKCFG_ED'
    else:
        blob = b''
    # The linker's own content: some filler, the config blob, and (when asked) the driver's strings. The
    # filler is deliberately not compressible-to-nothing so the sizes move when the fixture changes.
    filler = bytes(range(256)) * 8
    strs = b'goodix_fp\x00gf318m\x00goodix,fingerprint\x00goodix_fp_spi\x00' if strings_on else b''
    # `--earlyed` plants a SECOND `IKCFG_ED` INSIDE THE FLAT IMAGE, before `IKCFG_ST`. The reader's slice
    # is `[after ST, first ED]`; a reader that searches ED from byte zero finds this one and slices an
    # empty span. (This is a fixture the harness must build here: planting it by editing the finished
    # FILE does not work, because the file is compressed and the marker is not in it -- the first draft
    # of this mutation did exactly that, found nothing, and left the assertion it guards untested.)
    early = b'IKCFG_ED' + b'\x00' * 24 if earlyed else b''
    image = filler + early + b'\n' + blob + b'\n' + strs + kernel_extra
    if cutmember:
        # A gzip member that ENDS EARLY: the header is told the shorter length, so the only thing wrong
        # with the fixture is that the member is incomplete -- which is the reading under test.
        k = bytearray(gz(image))
        k = k[:len(k) - cutmember]
        kernel = bytes(k) + (fdt('Letv LE_ZL1-DVT1') if append else b'')
    else:
        kernel = gz(image) + (fdt('Letv LE_ZL1-DVT1') if append else b'')
    d = bytearray()
    if header == 'badmagic':
        d += b'NOPE!!\x00\x00'
    else:
        d += b'ANDROID!'
    d += struct.pack('<8I', len(kernel) + oversize, 0x80008000, 0, 0x81000000, 0, 0xf00000, 0x80000100, page)
    d += struct.pack('<II', 0, 0x00000000)          # dt_size / os_version
    d += struct.pack('<I', 0) + b'\x00' * 12        # id
    d += b'\x00' * 16                                # name
    d += b'androidboot.hardware=qcom' + b'\x00' * 512
    d += b'\x00' * 1024                              # extra_cmdline
    n = len(d)
    d += b'\x00' * ((page - n % page) % page if page else 0)
    d += kernel + b'\x00' * ((page - len(kernel) % page) % page if page else 0)
    if badpage:
        # A page size the format does not allow (not a power of two), on an otherwise PERFECT image: the
        # layout is the valid 4096 one and only the header's claim is wrong. That is what makes it a test
        # of the header check rather than of the arithmetic downstream of it.
        struct.pack_into('<I', d, 36, 6144)
    if truncate:
        d = d[:len(d) - truncate]
    open(out, 'wb').write(bytes(d))

out = sys.argv[1]
opts = {}
strings_on, config_mode, header, append, page, truncate = True, 'ok', 'ok', True, 4096, 0
earlyed, badpage, cutmember, oversize = False, False, 0, 0
i = 2
while i < len(sys.argv):
    a = sys.argv[i]
    if a == '--opt':
        k, v = sys.argv[i+1].split('=', 1); opts[k] = v; i += 2
    elif a == '--nostrings': strings_on = False; i += 1
    elif a == '--noconfig':  config_mode = 'none'; i += 1
    elif a == '--lenprefixed': config_mode = 'lenprefixed'; i += 1
    elif a == '--badconfig': config_mode = 'garbage'; i += 1
    elif a == '--badmagic':  header = 'badmagic'; i += 1
    elif a == '--noappend':  append = False; i += 1
    elif a == '--earlyed':   earlyed = True; i += 1
    elif a == '--badpage':   badpage = True; i += 1
    elif a == '--cutmember': cutmember = int(sys.argv[i+1]); i += 2
    elif a == '--oversize':  oversize = int(sys.argv[i+1]); i += 2
    elif a == '--page':      page = int(sys.argv[i+1]); i += 2
    elif a == '--truncate':  truncate = int(sys.argv[i+1]); i += 2
    else:
        raise SystemExit('mkimage: unknown argument %r' % a)
build(out, opts, strings_on, config_mode, header, append, page, truncate, b'', earlyed, badpage,
      cutmember, oversize)
PY

mk() { python3 "$W/mkimage.py" "$@"; }
FP_OFF='--opt CONFIG_INPUT_GP5XX8=notset --opt CONFIG_MSM_QBT1000=y --opt CONFIG_INPUT=y'
run() { OUT=$(bash "$SRC" "$@" 2>&1); RC=$?; }

# ==================================================================================================
echo
echo "== 1. every verdict is reached, and the two non-verdicts stay apart =="
# ==================================================================================================
mk "$W/with.img" --opt CONFIG_INPUT_GP5XX8=y --opt CONFIG_MSM_QBT1000=y --opt CONFIG_INPUT=y
run "$W/with.img"
[ "$RC" = 0 ] && ok "exit 0 on a readable image (the reading was made; that is the success condition)" || bad "it exited $RC"
[ "$(verdict "" "$OUT")" = carries-the-driver ] && ok "an image whose config says y and whose Image carries the strings -> carries-the-driver" \
  || bad "verdict was '$(verdict "" "$OUT")'"
want 'CONFIG_INPUT_GP5XX8 *y' "$OUT" "and the option is printed in its own state"
want 'goodix_fp=FOUND' "$OUT" "and the driver strings are reported as found"
want 'appended after it:.*1 FDT magic' "$OUT" "the appended device tree is counted as its own thing, with its own size"
want 'the kernel.s own config' "$OUT" "the config is read from the Image, and said to be"

mk "$W/without.img" $FP_OFF
run "$W/without.img"
[ "$(verdict "" "$OUT")" = does-not-carry-the-driver ] && ok "the option off -> does-not-carry-the-driver" || bad "verdict was '$(verdict "" "$OUT")'"
want 'CONFIG_INPUT_GP5XX8 *not set' "$OUT" "with the state named, not merely absent"

# THE PAIR THE WHOLE FILE IS ABOUT. A config line says what was ASKED FOR; a string in the Image says
# what is THERE. An image whose config says y and whose Image does not carry the driver is the one
# reading that a tool could paper over in either direction.
mk "$W/lie.img" --opt CONFIG_INPUT_GP5XX8=y --opt CONFIG_INPUT=y --nostrings
run "$W/lie.img"
[ "$(verdict "" "$OUT")" = config-says-y-and-the-image-disagrees ] \
  && ok "a config that says y with NO driver in the Image -> a verdict of its own: the two readings are kept apart instead of one standing for the other" \
  || bad "verdict was '$(verdict "" "$OUT")'"
want 'goodix_fp=not found' "$OUT" "and the Image's own answer is printed next to the config's"

# "the option is not mentioned" and "there is no config here" are DIFFERENT FACTS. This is the assertion
# that keeps a tool from answering a question about a board with a silence about itself.
mk "$W/nocfg.img" --noconfig
run "$W/nocfg.img"
[ "$(verdict "" "$OUT")" = config-not-embedded ] && ok "a kernel with no embedded config -> config-not-embedded" || bad "verdict was '$(verdict "" "$OUT")'"
want 'NO CONFIG EMBEDDED' "$OUT" "and the option state is reported as UNKNOWN"
want 'CONFIG_INPUT_GP5XX8 *NO CONFIG EMBEDDED' "$OUT" "for the fingerprint option specifically"
notwant 'CONFIG_INPUT_GP5XX8 *not set' "$OUT" "and NOT as 'not set' -- that is the defect this pair exists for"
want 'UNKNOWN, not .not set' "$OUT" "with the difference said out loud"

mk "$W/garb.img" --badconfig
run "$W/garb.img"
[ "$(verdict "" "$OUT")" = config-not-embedded ] && ok "a marker that is present and does not inflate -> config-not-embedded, not a config full of absence" \
  || bad "verdict was '$(verdict "" "$OUT")'"
want 'inflate to nothing that looks like a config' "$OUT" "with the reason being about the bytes, not about the kernel"

mk "$W/lenp.img" --lenprefixed --opt CONFIG_INPUT_GP5XX8=y --opt CONFIG_INPUT=y
run "$W/lenp.img"
[ "$(verdict "" "$OUT")" = carries-the-driver ] && ok "the LENGTH-PREFIXED config layout is read too (two layouts exist and the reader tries both)" \
  || bad "verdict was '$(verdict "" "$OUT")'"

echo
echo "== 2. an image that cannot be read claims NOTHING (exit 3) =="
# ==================================================================================================
mk "$W/badmagic.img" --badmagic $FP_OFF
run "$W/badmagic.img"
[ "$RC" = 3 ] && ok "a file that is not an Android boot image exits 3" || bad "it exited $RC"
want 'UNREADABLE' "$OUT" "and says so"
want 'NOTHING IS CLAIMED' "$OUT" "and claims nothing -- never 'a kernel without a driver'"
notwant 'CONFIG_INPUT_GP5XX8' "$OUT" "and prints no option state at all (there is no kernel to have one)"

mk "$W/trunc.img" $FP_OFF --oversize 400000
run "$W/trunc.img"
[ "$RC" = 3 ] && ok "an image whose header claims 400000 more kernel bytes than are there exits 3" || bad "it exited $RC"
want 'does not fit in' "$OUT" "with the header's own numbers as the reason"

mk "$W/badpage.img" $FP_OFF --badpage
run "$W/badpage.img"
[ "$RC" = 3 ] && ok "an image whose layout is valid but whose header claims a page size the format does not allow exits 3" || bad "it exited $RC"
want 'page size' "$OUT" "and the page size is named"

run /nonexistent-image.img
[ "$RC" = 3 ] && ok "a missing file exits 3" || bad "it exited $RC"
want 'unreadable image' "$OUT" "named as an unreadable image"

echo
echo "== 3. the kernel is the gzip MEMBER and the device trees are what follows it =="
# ==================================================================================================
# `Image.gz-dtb` is one gzip member with an FDT appended. Reading the whole blob as the kernel would put
# 2 MB of device trees into the Image -- and the reading would still LOOK right, because the config is
# found in the middle of it. The check is the boundary itself.
mk "$W/app.img" --opt CONFIG_INPUT_GP5XX8=y --opt CONFIG_INPUT=y
run "$W/app.img"
want 'appended after it:.*1 FDT magic' "$OUT" "the appended device tree is reported as a SEPARATE thing, with its own size and hash"
A_SIZE=$(printf '%s\n' "$OUT" | sed -n 's/.*appended after it: *\([0-9]*\) bytes.*/\1/p' | sed -n 1p)
[ "${A_SIZE:-0}" -gt 100 ] 2>/dev/null && ok "and that size is not zero ($A_SIZE bytes) -- the boundary was found rather than assumed" \
  || bad "the appended size came back as '${A_SIZE:-empty}'"
mk "$W/noapp.img" --opt CONFIG_INPUT_GP5XX8=y --opt CONFIG_INPUT=y --noappend
run "$W/noapp.img"
want 'appended after it: *0 bytes, 0 FDT magic' "$OUT" "and an image with nothing appended reports zero rather than the kernel's own bytes"

# a kernel blob whose gzip stream is cut: the member must be COMPLETE, and a reader that accepted an
# incomplete one would hand back a truncated Image and read a config out of the wreckage. The cut is made
# by the fixture builder, not by editing the finished file -- the earlier draft parsed the FILE's own
# header to find the member, which is the very thing under test, and the fixture it produced was a file
# smaller than one page.
mk "$W/trunc-member.img" --opt CONFIG_INPUT_GP5XX8=y --opt CONFIG_INPUT=y --cutmember 64
run "$W/trunc-member.img"
[ "$RC" = 3 ] && ok "a kernel blob that ends mid-member exits 3 rather than yielding a truncated Image" || bad "it exited $RC"
want 'not one complete gzip member' "$OUT" "and says exactly that"

echo
echo "== 4. --diff: from the two IMAGES, not from the two defconfigs =="
# ==================================================================================================
mk "$W/a.img" $FP_OFF
mk "$W/b.img" --opt CONFIG_INPUT_GP5XX8=y --opt CONFIG_MSM_QBT1000=y --opt CONFIG_INPUT=y
run --diff "$W/a.img" "$W/b.img"
want '1 option\(s\) differ' "$OUT" "--diff finds exactly ONE differing option when exactly one differs"
want 'CONFIG_INPUT_GP5XX8 *notset|-  *not set *-> y|not set *-> y' "$OUT" "and names it, with both states"
notwant 'CONFIG_MSM_QBT1000 *not set *->' "$OUT" "and does not report the options that agree"
mk "$W/c.img" --opt CONFIG_INPUT_GP5XX8=y --opt CONFIG_MSM_QBT1000=y --opt CONFIG_INPUT=y --opt CONFIG_INPUT_EVDEV=y
run --diff "$W/b.img" "$W/c.img"
want '1 option\(s\) differ' "$OUT" "still one when a second option is added to only one side"
want 'CONFIG_INPUT_EVDEV' "$OUT" "and it is the added one"
run --diff "$W/a.img" "$W/a.img"
want '0 option\(s\) differ' "$OUT" "--diff on one image twice reports zero differences"
want 'same config' "$OUT" "and says why zero is the right answer here"
# AN EMPTY DIFFERENCE AND AN UNMAKABLE ONE ARE DIFFERENT. A kernel with no config cannot be compared,
# and printing '0 differ' for it would be the same defect one level up.
run --diff "$W/a.img" "$W/nocfg.img"
want 'cannot be made' "$OUT" "and a comparison against a kernel with no config says the comparison CANNOT be made"
notwant '0 option\(s\) differ' "$OUT" "rather than printing an empty difference -- which is what 'the two kernels agree' looks like"
run --diff "$W/a.img"
[ "$RC" = 2 ] && ok "--diff with one image is refused (exit 2) rather than silently comparing nothing" || bad "it exited $RC"

echo
echo "== 5. the mutations: each breaks ONE thing in the SUBJECT and must redden a NAMED assertion =="
# ==================================================================================================
mkdir -p "$W/mut"
mut() { # name, old, new
  python3 - "$SRC" "$W/mut/$1.sh" "$2" "$3" <<'PY'
import sys
src, dst, old, new = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
s0 = open(src).read()
if old not in s0:
    sys.exit(2)
s = s0.replace(old, new, 1)
if s == s0:
    sys.exit(3)
open(dst, 'w').write(s)
PY
  case $? in
  0) ok "mutation '$1' applied" ;;
  2) bad "mutation '$1' COULD NOT BE APPLIED: its target text is gone (re-derive it before trusting the assertion it guards)" ;;
  *) bad "mutation '$1' did not change the subject" ;;
  esac
}
mutrun() { local m="$1"; shift; OUT=$(bash "$m" "$@" 2>&1); RC=$?; }

# (a) read the WHOLE kernel blob as the Image -- the appended device trees become code
mut wholeblob "    image, appended = gunzip_member(info['kernel'])" "    image, appended = info['kernel'], b''"
if [ -r "$W/mut/wholeblob.sh" ]; then
  mutrun "$W/mut/wholeblob.sh" "$W/app.img"
  want 'appended after it: *0 bytes' "$OUT" "  reading the whole blob puts nothing 'after' the kernel -- the boundary the file exists to find is gone"
  notwant '1 FDT magic' "$OUT" "  and the device tree it really has is no longer counted"
fi

# (b) search IKCFG_ED from zero instead of after IKCFG_ST
mut edfromzero "    j = image.find(b'IKCFG_ED', i)" "    j = image.find(b'IKCFG_ED')"
if [ -r "$W/mut/edfromzero.sh" ]; then
  mutrun "$W/mut/edfromzero.sh" "$W/b.img"
  want 'CONFIG_INPUT_GP5XX8 *y' "$OUT" "  with no earlier ED marker the two searches agree, so this mutation is invisible until one is there"
  mk "$W/two.img" --opt CONFIG_INPUT_GP5XX8=y --opt CONFIG_INPUT=y --earlyed
  mutrun "$W/mut/edfromzero.sh" "$W/two.img"
  [ "$(verdict "" "$OUT")" = config-not-embedded ] && ok "  with an earlier ED marker the mutated reader slices the wrong span and LOSES the config the original reads" \
    || bad "  the mutation still read a config ('$(verdict "" "$OUT")')"
  run "$W/two.img"
  [ "$(verdict "" "$OUT")" = carries-the-driver ] && ok "  and the ORIGINAL reads that same fixture correctly, so the earlier marker is a real trap and not a broken fixture" \
    || bad "  the original also failed on the fixture ('$(verdict "" "$OUT")')"
fi

# (c) ignore the header's page size
mut fixedpage "    if page_size not in (2048, 4096, 8192, 16384, 32768, 65536):" "    page_size = 4096
    if False:"
if [ -r "$W/mut/fixedpage.sh" ]; then
  mutrun "$W/mut/fixedpage.sh" "$W/badpage.img"
  [ "$RC" = 0 ] && ok "  a hard-coded page size turns an impossible header into a confident reading (exit 0 where the original exits 3)" \
    || bad "  the mutation still refused (exit $RC)"
  notwant 'page size' "$OUT" "  and the page size is no longer named"
fi

# (d) fold "no config" into "not set" -- the defect the whole file is about
mut noconfigasnotset "        if not cfg:
            opts[w] = 'NO CONFIG EMBEDDED'" "        if not cfg:
            opts[w] = 'not set'"
if [ -r "$W/mut/noconfigasnotset.sh" ]; then
  mutrun "$W/mut/noconfigasnotset.sh" "$W/nocfg.img"
  want 'CONFIG_INPUT_GP5XX8 *not set' "$OUT" "  with the two facts folded, a kernel that carries NO config reports the option as NOT SET"
  notwant 'NO CONFIG EMBEDDED' "$OUT" "  and the state that was UNKNOWN is gone from the output"
fi

# (e) print an empty difference when one side has no config to compare
mut emptydiff "if not ta or not tb:" "if False:"
if [ -r "$W/mut/emptydiff.sh" ]; then
  mutrun "$W/mut/emptydiff.sh" --diff "$W/a.img" "$W/nocfg.img"
  notwant 'cannot be made' "$OUT" "  with the guard gone, the sentence that says the comparison CANNOT be made is gone"
  want '[1-9][0-9]* option\(s\) differ' "$OUT" "  and what is printed instead is a pile of differences that are an artefact of the missing config -- a comparison that was never made, reported as findings"
fi

echo
echo "== 6. what this must never do, asserted over the shipped file =="
# ==================================================================================================
CODE=$(sed 's/#.*//' "$SRC")
for pat in 'fastboot' 'adb ' 'ssh ' 'scp ' 'flash' 'mount' 'reboot' 'QFIL' 'mkfs'; do
  if printf '%s\n' "$CODE" | grep -E -- "$pat" >/dev/null 2>&1; then
    bad "the subject's CODE matches '$pat' -- an image reader has no device path"
  else
    ok "no '$pat' in the subject's code"
  fi
done
REDIR=$(printf '%s\n' "$CODE" | grep -oE '>>?[[:space:]]*"?/[A-Za-z0-9_./$-]+' | sed 's/>>\?[[:space:]]*"\?//' | sort -u | tr '\n' ' ' | sed 's/ *$//')
[ "$REDIR" = /dev/null ] && ok "the only absolute path it redirects to is /dev/null (found: '$REDIR')" \
  || bad "it redirects to absolute paths: '$REDIR'"
wantf 'W=$(mktemp -d' "$CODE" "its temp dir is made with mktemp -d"
wantf 'trap cleanup EXIT' "$CODE" "and removed on exit"
wantf 'opens no device' "$(cat "$SRC")" "and the refusal is written down in the file"

echo
echo "== 7. the REAL images: the candidate, and the image the project boots =="
# ==================================================================================================
# This is the half a fixture cannot do: these are the files, with the hashes the record carries. It is
# also the stage's own claim, asserted here so that a rebuild of either image reddens rather than
# silently changing what the tool says.
CAND=/mnt/data/halium-zl1-candidates
FP="$CAND/halium-boot-zl1-v63-fpdriver.img"
V63="$CAND/halium-boot-zl1-v63-rebuilt.img"
if [ -r "$FP" ] && [ -r "$V63" ]; then
  run "$FP"
  [ "$(verdict "" "$OUT")" = carries-the-driver ] && ok "the candidate image (v63-fpdriver) reads as carries-the-driver" || bad "verdict was '$(verdict "" "$OUT")'"
  wantf 'CONFIG_INPUT_GP5XX8        y' "$OUT" "its own embedded config says the option is y"
  wantf 'goodix_fp=FOUND' "$OUT" "and the driver is in its Image"
  # The CONTROL needle reads 'not found' on a healthy kernel, so it has to be LABELLED as a control --
  # otherwise four FOUNDs and one 'not found' on the same line read as a partial failure. The label is
  # asserted, because a comment in the subject is not a fact about its output.
  wantf 'control (expected not found' "$OUT" "and the needle that is EXPECTED to miss is labelled a control, so it does not read as a failure"
  wantf 'gf_spi.c=not found' "$OUT" "and it is the source filename, which an optimised Image does not carry"
  run "$V63"
  [ "$(verdict "" "$OUT")" = does-not-carry-the-driver ] && ok "the image the project boots (v63-rebuilt) reads as does-not-carry-the-driver" \
    || bad "verdict was '$(verdict "" "$OUT")'"
  # THE STAGE'S CENTRAL READING: the only difference between the two, in the two images' own configs.
  run --diff "$FP" "$V63"
  want '1 option\(s\) differ' "$OUT" "and the two images' own configs differ in EXACTLY ONE option -- that is what makes this a single-variable change"
  want 'CONFIG_INPUT_GP5XX8' "$OUT" "and the option that differs is the fingerprint's"
  # the parts that must NOT differ: the ramdisk and the appended device trees are byte-identical
  R_FP=$(printf '%s\n' "$OUT" | grep -o 'ramdisk: sha256=[0-9a-f]*' | sed -n 1p)
  [ -n "$R_FP" ] || bad "the ramdisk hash was not printed"
  A_FP=$(printf '%s\n' "$OUT" | grep -o 'appended after it:.*sha256=[0-9a-f]*' | sed -n 1p)
  [ -n "$A_FP" ] || bad "the appended-blob hash was not printed"
  R63=$(bash "$SRC" "$V63" 2>&1 | grep -o 'ramdisk: sha256=[0-9a-f]*' | sed -n 1p)
  A63=$(bash "$SRC" "$V63" 2>&1 | grep -o 'appended after it:.*sha256=[0-9a-f]*' | sed -n 1p)
  [ "$R_FP" = "$R63" ] && ok "the two images' RAMDISKS are byte-identical ($R_FP) -- the initramfs is not a variable" \
    || bad "the ramdisks differ: '$R_FP' vs '$R63'"
  [ "$A_FP" = "$A63" ] && ok "and their FIVE appended device trees are byte-identical ($(printf '%s' "$A_FP" | sed 's/.*sha256=//')) -- the device tree is not a variable either" \
    || bad "the appended blobs differ: '$A_FP' vs '$A63'"
else
  bad "the candidate or the reference image is not on this host, so the stage's own reading CANNOT BE CHECKED here (looked for $FP and $V63)"
fi

# ==================================================================================================
echo
echo "== 8. the flags, and the count the health check cites =="
# ==================================================================================================
run "$W/without.img" --quiet
notwant 'boot header|cmdline|kernel blob|decompressed|appended after' "$OUT" "--quiet prints no readings"
want '^   -> does-not-carry-the-driver' "$OUT" "but the verdict is still there"
run "$W/with.img" --json
want '"ok": true' "$OUT" "--json prints one object per image"
want '"options"' "$OUT" "with the option states in it"
H=$(bash "$SRC" --help 2>&1)
want '^# What kernel is inside this boot image' "$H" "--help prints the header verbatim"
notwant '^[^#]' "$H" "and every line of it is the file's own comment"
E=$(bash "$SRC" --explain 2>&1)
want 'THE DISTINCTION THIS FILE' "$E" "--explain prints the section that names what it refuses to blur"
B=$(bash "$SRC" --nonsense 2>&1); BRC=$?
[ "$BRC" = 2 ] && ok "an unknown flag exits 2" || bad "it exited $BRC"
# Under `set -o pipefail` a pipeline takes the FIRST command's exit status as well, so this must not be a
# pipeline: the subject exits 2 on purpose when it has no image, and `| grep` would have reported the
# harness's own trap as a missing usage line (this project has that shape recorded).
NOARG=$(bash "$SRC" 2>&1)
want 'usage:' "$NOARG" "and with no image it prints a usage line rather than reading nothing"

HEALTH="$HERE/zl1-health-check.sh"
if [ -r "$HEALTH" ]; then
  match=$(tr '\n' ' ' < "$HEALTH" | grep -oE 'zl1-boot-image-kernel-selftest\.sh[^0-9]*[0-9]+ checks' | sed -n 1p)
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
printf 'pass=%s fail=%s skip=0\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] && echo "== verdict: all green" || echo "== verdict: $FAIL failing"
[ "$KEEP" = 1 ] && echo "kept: $W"
[ "$FAIL" = 0 ] || exit 1
exit 0
