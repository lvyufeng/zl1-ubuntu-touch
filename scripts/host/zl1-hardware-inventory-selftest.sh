#!/usr/bin/env bash
# zl1 hardware inventory -- offline self-test. Host-side, touches no device, needs no phone.
#
# Why this exists. `scripts/host/zl1-hardware-inventory.sh` answers a question the port has never asked
# -- *which hardware has no probe at all* -- by reading the device's own device trees offline, and then
# searching this tree for something that names each block. Both halves of that are claims that can be
# wrong in silence, and both halves were wrong in the first two runs:
#
#   * the block table used `|` as its field separator **and** `|` inside the token alternation, so
#     `read` split the rows in the wrong places: every row's DTB pattern was only its first alternative
#     and `kind` was never what the code branched on. The report was wrong about which hardware exists
#     and about how many rows count, and it printed a tidy table anyway.
#   * the script searched its own source for the tokens, so **every** block matched **this file** -- the
#     summary read "34 with an instrument, 0 with none", a report that cannot report a gap. Two more
#     false covers came from prose (the word "haptics" in a paragraph; "venus" in another) and two more
#     from the backup scripts, whose `ALLOWLIST` contains the partition names `modem` and `bluetooth`.
#
# So the harness is built the same way as this family's others: **fixtures that must produce a specific
# verdict**, and the strongest check is the one that says the report CAN say "none".
#
# How it works. Two fake roots, one per half:
#
#   * the PARSER is tested against synthetic device trees -- the FDT is a format, not a claim about this
#     board, so building one is honest. Both bugs found in the first walker get a node that exposes
#     them: `FDT_END` is token 9 and not 4 (`bad token 9` after 2105 nodes), and property padding is
#     `(len+3) & ~3` and not `(len+4) & ~3` (the latter misaligns by one byte whenever a value's length
#     is a multiple of 4, and returns a plausible, short tree).
#   * the CLASSIFIER is tested against a fake repo: a copy of the subject under `$FR`, a seven-row table,
#     a synthetic DTB, and fixture scripts whose only difference is *where* the token appears -- a code
#     line, a comment, an `echo`, a backup allowlist, the subject itself. Each has a required verdict,
#     so "a mention in prose is not an instrument" is a reading rather than a promise.
#
# Usage: zl1-hardware-inventory-selftest.sh [--keep]
#   --keep   leave the fake roots, the fixture DTBs and the fixtures for inspection
#
# `ZL1_HW_INVENTORY_SRC=/path` runs the whole thing against another copy of the subject, which is how a
# revision can be shown to fail.
#
# Exit codes: 0 every scenario behaved; 1 something did not; 2 the harness could not set up.

set -uo pipefail

KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
  --keep) KEEP=1; shift ;;
  --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${ZL1_HW_INVENTORY_SRC:-$HERE/zl1-hardware-inventory.sh}"
[ -r "$SRC" ] || { echo "cannot read the subject: $SRC" >&2; exit 2; }
ROOT="$(cd "$HERE/../.." && pwd)"
SNAP="$ROOT/docs/ubuntu-touch/hardware-compatibles.txt"

W="${TMPDIR:-/tmp}/zl1-hw-inventory-selftest"
FR="$W/frepo"
rm -rf "$W"
mkdir -p "$W" "$FR/scripts/host" "$FR/scripts" "$FR/tmp-dtb-analysis/stock/dtbs" "$W/dtbs" "$W/parser" || exit 2

PASS=0
FAIL=0
SKIP=0
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf 'SKIP  %s\n' "$1"; }
want()    { if grep -Eq -- "$1" <<< "$2"; then ok "$3"; else bad "$3"; sed 's/^/        | /' <<< "$2"; fi; }
notwant() { if grep -Eq -- "$1" <<< "$2"; then bad "$3"; grep -E -- "$1" <<< "$2" | sed 's/^/        | /'; else ok "$3"; fi; }
# A check that passes for free on an empty string is not a check, so `want` on a possibly-empty
# variable goes through here first. (docs 121: a substring assertion red 100 s in every 1000.)
nonempty() { if [ -n "$2" ]; then ok "$1"; else bad "$1 -- the output was empty, so nothing below it can be trusted"; fi; }

# ==================================================================================================
echo "== 1. the FDT walker, against synthetic trees =="
# ==================================================================================================
#
# The FDT binary format is small enough to build exactly, and building one is the only way to cover the
# two shapes that broke the first attempt: a token stream with a NOP in it (token 4, which is not END)
# and a property whose length is a multiple of 4 (where the wrong padding skips a byte and the walk
# silently returns fewer nodes).
cat > "$W/fdtbuild.py" <<'PY'
import json, struct, sys

def enc(v):
    if isinstance(v, list):
        if v and isinstance(v[0], int):
            return b''.join(struct.pack('>I', x) for x in v)
        return b''.join(s.encode() + b'\0' for s in v)
    if isinstance(v, str):
        return v.encode() + b'\0'
    raise SystemExit('unsupported property value: %r' % (v,))

def main(spec, out):
    strblob = bytearray()
    stroff = {}

    def sidx(name):
        if name not in stroff:
            stroff[name] = len(strblob)
            strblob.extend(name.encode() + b'\0')
        return stroff[name]

    body = bytearray()

    def emit(tok, payload=b''):
        body.extend(struct.pack('>I', tok))
        body.extend(payload)

    def pad():
        while len(body) % 4:
            body.append(0)

    def walk(n):
        emit(1, n.get('name', '').encode() + b'\0')
        pad()
        for _ in range(n.get('nops', 0)):
            emit(4)                              # FDT_NOP
        for k, v in n.get('props', {}).items():
            val = enc(v)
            emit(3, struct.pack('>II', len(val), sidx(k)) + val)
            pad()
        for c in n.get('children', []):
            walk(c)
        emit(2)                                  # FDT_END_NODE

    walk(spec)
    emit(9)                                      # FDT_END -- 9, not 4
    off_struct = 56
    hdr = struct.pack('>10I', 0xd00dfeed, 56 + len(body) + len(strblob), off_struct,
                      off_struct + len(body), 40, 17, 16, 0, len(strblob), len(body))
    with open(out, 'wb') as f:
        f.write(hdr + bytes(16) + bytes(body) + bytes(strblob))   # 40-byte header + empty rsvmap

main(json.loads(sys.argv[1]), sys.argv[2])
PY
[ -r "$W/fdtbuild.py" ] || { echo "cannot write the FDT builder" >&2; exit 2; }

# A tree that carries one of everything the walker has to get right, with real-length names and values:
# "soc\0" (4 bytes, no padding), "i2c\0" (4), "spmi\0" (5, pads to 8), a 4-byte compatible, an 8-byte
# reg, and a two-element compatible list.
TREE='{"name":"","props":{"compatible":["vendor,board","vendor,soc"],"#address-cells":[1],"#size-cells":[1]},
 "children":[
  {"name":"soc","props":{},"nops":1,"children":[
    {"name":"i2c","props":{"compatible":"vendor,i2c","reg":[1,2]},"children":[
      {"name":"touch","props":{"compatible":["vendor,ts","vendor,ts-v2"],"reg":[56]},"children":[]}]},
    {"name":"spmi","props":{"compatible":"vendor,spmi"},"children":[]}]},
  {"name":"pmic","props":{"compatible":"vendor,pmic"},"children":[]}]}'
python3 "$W/fdtbuild.py" "$TREE" "$W/dtbs/tree.dtb" || { echo "the fixture DTB could not be built" >&2; exit 2; }
[ -s "$W/dtbs/tree.dtb" ] && ok "the synthetic device tree builds (this is the fixture's own precondition)" || bad "the synthetic device tree is empty"

R=$(bash "$SRC" --dump-compatibles --dtb-dir "$W/dtbs" 2>/dev/null)
nonempty "the dump has content" "$R"
notwant 'PARSE-FAILED' "$R" "the synthetic tree parses without a token error"
want '^# zl1 device-tree compatibles -- GENERATED by' "$R" "the dump carries the provenance header that makes the snapshot traceable"
# `[[:space:]]`, not a literal tab or `\t`: the pattern has to mean "the separator" whether or not an
# editor has been near this file, and `\t` is not a tab in ERE.
want '^/soc/i2c/touch[[:space:]]vendor,ts[[:space:]]' "$R" "a node with two compatibles yields both (the real display nodes carry two driver generations each)"
want '^/soc/i2c/touch[[:space:]]vendor,ts-v2[[:space:]]' "$R" "and the second one too"
want '^/soc/i2c[[:space:]]vendor,i2c[[:space:]]' "$R" "the node after an 8-byte property is reached -- a length that is a multiple of 4 is where the wrong padding skips a byte"
want '^/soc/spmi[[:space:]]vendor,spmi[[:space:]]' "$R" "a node name of length 5 pads to 8 and the walk continues"
want '^/pmic[[:space:]]vendor,pmic[[:space:]]' "$R" "the LAST sibling is reached, after the whole first subtree (a misaligned walk loses the tail first)"
want '^/soc/i2c/touch[[:space:]]' "$R" "the FDT_NOP emitted right after /soc's name did not end the node -- token 4 is NOP, token 9 is END"
n=$(printf '%s\n' "$R" | grep -c 'vendor,')
[ "$n" = 7 ] && ok "all 7 compatible values in the fixture are found (a short tree is the padding bug's signature)" ||
  bad "found $n of 7 compatible values -- the walk is losing nodes"
want '# totals: 5 distinct paths, 7 path/compatible pairs \(7 rows with the board attached\), sets: dtbs' "$R" "and the totals are counted, not assumed (the snapshot's own header line)"

# A file that is not an FDT must be reported, never silently walked. An instrument that cannot report
# is this tree's oldest defect (docs 72), and this is the one place where the parser could hide one.
printf 'not a device tree at all, not even close' > "$W/dtbs/bogus.dtb"
OUT=$(bash "$SRC" --dump-compatibles --dtb-dir "$W/dtbs/bogus.dtb" 2>"$W/dtbs/err"); rc=$?
if [ "$rc" = 3 ]; then ok "a non-FDT file exits 3"; else bad "a non-FDT file exited $rc, not 3"; fi
want 'PARSE-FAILED' "$(cat "$W/dtbs/err")" "and says which file failed on stderr"
notwant 'vendor,' "$OUT" "and emits no compatibles from it -- a tree that did not parse is not a tree with no hardware"

# Two directories, so the set letter is not a constant: the real report leans on S/R/F to say which
# image a block's existence depends on.
mkdir -p "$W/dtbs2"
python3 "$W/fdtbuild.py" '{"name":"","props":{},"children":[{"name":"soc2","props":{"compatible":"other,board"},"children":[]}]}' "$W/dtbs2/other.dtb"
R=$(bash "$SRC" --dump-compatibles --dtb-dir "$W/dtbs/tree.dtb" --dtb-dir "$W/dtbs2/other.dtb" 2>/dev/null)
want '^/soc2	other,board	dtbs2	\?$' "$R" "a second --dtb-dir is tagged with its own directory, not the first one"

# ---- the board column, and the mistake it exists to stop --------------------------------
#
# Three trees that differ in NOTHING but their root `model`. That is not a hypothetical: the flashed
# boot image's appended blob carries this phone's trees **and 23 of the LeEco X2's**, and the two
# boards' root `compatible` is byte-identical (`qcom,msm8996-mtp\0qcom,msm8996\0qcom,mtp`). So every
# guard of the form `grep -qa msm8996 /proc/device-tree/compatible` -- which ~25 probes in this tree
# use -- is satisfied by the other phone's tree, and `model` is the ONLY reading that separates them.
# This is also where the report's old `vibrator` row came from: it credited this board with the X2's
# second haptics chip (`ti,drv2604l`). The checks below are about reading `model`, and then USING it.
#
# `[[:space:]]`, never a literal tab or `\t`: the pattern has to mean "the separator" whether or not an
# editor has been near this file, and GNU grep reads `\t` as the letter t.
#
# The three trees are deliberately ASYMMETRIC (two nodes for this phone, one each for the others), so
# that the three filter modes produce three different pairs of numbers. Equal counts would let a
# filter that does nothing pass every check below.
mkdir -p "$W/boards"
b13() { # $1 = file, $2 = model, $3.. = the nodes only this tree has
  local f=$1 m=$2 n kids=""
  shift 2
  for n in "$@"; do
    kids="$kids,{\"name\":\"$n\",\"props\":{\"compatible\":\"vendor,$n\"},\"children\":[]}"
  done
  python3 "$W/fdtbuild.py" "{\"name\":\"\",\"props\":{\"compatible\":[\"qcom,msm8996-mtp\",\"qcom,msm8996\",\"qcom,mtp\"],\"model\":\"$m\"},\"children\":[{\"name\":\"shared\",\"props\":{\"compatible\":\"vendor,shared\"},\"children\":[]}$kids]}" "$f"
}
b13 "$W/boards/zl.dtb" 'Letv Technologies, Inc. MSM 8996pro + PMI8996 LE_ZL1-DVT1' zlonly1 zlonly2
b13 "$W/boards/x2.dtb" 'Letv Technologies, Inc. MSM 8996 v3 + PMI8996 LE_X2-PVT' x2only
b13 "$W/boards/nb.dtb" 'Acme Reference Board' neither
BARG=()
for b in "$W/boards/zl.dtb" "$W/boards/x2.dtb" "$W/boards/nb.dtb"; do BARG+=(--dtb-dir "$b"); done
BD=$(bash "$SRC" --dump-compatibles "${BARG[@]}" 2>&1)
nonempty "the three-board dump has content" "$BD"
want '^#file[[:space:]].*/zl\.dtb[[:space:]]boards[[:space:]]z[[:space:]]Letv Technologies, Inc\. MSM 8996pro \+ PMI8996 LE_ZL1-DVT1$' "$BD" \
  "the board column is derived from the tree's own model, and the model is printed verbatim"
want '^#file[[:space:]].*/x2\.dtb[[:space:]]boards[[:space:]]x[[:space:]]Letv Technologies, Inc\. MSM 8996 v3 \+ PMI8996 LE_X2-PVT$' "$BD" \
  "and the other phone is a different letter with a different model, not the same one twice"
want '^#file[[:space:]].*/nb\.dtb[[:space:]]boards[[:space:]][?][[:space:]]Acme Reference Board$' "$BD" \
  "a tree whose model names neither board is a question mark -- it is not filed under one of them"
want '^# boards: boards[?] 1 boardsx 1 boardsz 1' "$BD" \
  "the per-DTB census counts files: one z, one x, one unidentified"
want '^/zlonly1[[:space:]]vendor,zlonly1[[:space:]]boards[[:space:]]z$' "$BD" "every data line carries its own tree's board"
n=$(printf '%s\n' "$BD" | grep -c '^/shared[[:space:]]vendor,shared[[:space:]]boards[[:space:]]')
[ "$n" = 3 ] && ok "and the same node in three trees is three rows -- the board is part of a row's identity, not decoration" ||
  bad "the shared node produced $n rows, not 3"
n=$(printf '%s\n' "$BD" | grep -c '^/neither[[:space:]]vendor,neither[[:space:]]boards[[:space:]][?]$')
[ "$n" = 1 ] && ok "the unidentifiable tree's own node is filed under the question mark, not under a board" ||
  bad "the unidentifiable tree's node was filed under something else"

BR=$(bash "$SRC" "${BARG[@]}" 2>/dev/null)
nonempty "the board-filtered report has content" "$BR"
want 'board:         THIS PHONE \(LE_ZL1\) only -- 5 of 6 paths' "$BR" \
  "the default report is this phone's trees only, and says how many paths the filter took away"
want 'nodes in the device tree: 5 distinct paths, 7 path/compatible pairs' "$BR" \
  "and the counts are the filtered ones: this phone's two trees plus the unidentified one"
BX=$(bash "$SRC" "${BARG[@]}" --board x2 2>/dev/null)
want 'board:         the OTHER PHONE \(LE_X2\) only -- 4 of 6 paths' "$BX" \
  "--board x2 reports on the other phone, and its counts differ from this phone's -- the filter has a direction"
BA=$(bash "$SRC" "${BARG[@]}" --board all 2>/dev/null)
want 'nodes in the device tree: 6 distinct paths, 8 path/compatible pairs' "$BA" \
  "--board all is the unfiltered count: the largest of the three, and equal to neither of them"
BO=$(bash "$SRC" "${BARG[@]}" --boards 2>/dev/null)
nonempty "the --boards table has content" "$BO"
want '^boards +z +[0-9a-f]{10} +[0-9]+ +Letv Technologies, Inc\. MSM 8996pro' "$BO" \
  "--boards is one line per DTB: set, board, sha256, size, model"
want '3 device tree\(s\); BRD z=LE_ZL1' "$BO" "and it counts the trees it printed"
# A row whose pattern matches only the OTHER phone's node is this report's own worst mistake, and it
# must not be reported as a gap (which would say "this phone has this hardware and nothing reads it")
# nor as a broken pattern. It is its own finding, and it is exactly what the old `vibrator` row was.
# Three rows, one per tree, so the direction of the filter is visible in the DTB node counts.
printf '%s\n' \
  'zlblock	vendor,zlonly	zzz_nothing_reads_this	HW	-' \
  'x2block	vendor,x2only	zzz_nothing_reads_this	HW	-' \
  'nbblock	vendor,neither	zzz_nothing_reads_this	HW	-' > "$W/table-boards.txt"
X=$(bash "$SRC" "${BARG[@]}" --table "$W/table-boards.txt" 2>/dev/null)
nonempty "the board-filtered table report has content" "$X"
want '^zlblock +2 +\*\*NONE\*\*' "$X" "this phone's block is counted with BOTH of its nodes"
want '^nbblock +1 +\*\*NONE\*\*' "$X" "the unidentified tree's block is counted too -- it is not dropped"
want 'Declared by another board only' "$X" "the other phone's block has its own section"
want '^  x2block +1 node\(s\), in boards/x -- declared by the LE_X2, a different phone$' "$X" \
  "and that row names the block, the count, the set and WHICH other board"
notwant '^x2block' "$X" "it is NOT in the block table -- nothing here says this phone has the hardware"
notwant '^  x2block +1 dtb node' "$X" "and it is not in the gap list either -- the two lists differ by their wording, so this is a reading and not a guess"
want 'blocks: 2 hardware -- 0 with a named instrument, \*\*2 with none\*\*' "$X" \
  "the counts are the two gaps; the other board's row is added to neither side (the table prints two rows, not three)"
want '1 row\(s\) matched only another board' "$X" "and the summary line says so"
Y=$(bash "$SRC" "${BARG[@]}" --table "$W/table-boards.txt" --board x2 2>/dev/null)
want '^x2block +1 +\*\*NONE\*\*' "$Y" "under the other board's filter the same row is an ordinary gap"
want '^  zlblock +2 node\(s\), in boards/z -- declared by the LE_ZL1 \(this phone\)$' "$Y" \
  "and this phone's row is now the one in the other-board section -- the row is not special, the filter is"
want '^nbblock +1 +\*\*NONE\*\*' "$Y" "and the unidentified row is a gap under BOTH filters -- which is what keeps a tree this report cannot identify from disappearing"
Z=$(bash "$SRC" "${BARG[@]}" --table "$W/table-boards.txt" --board all 2>/dev/null)
want '^zlblock +2 +\*\*NONE\*\*' "$Z" "with no filter, this phone's block is in the table"
want '^x2block +1 +\*\*NONE\*\*' "$Z" "and so is the other phone's, as a row of its own"
want 'blocks: 3 hardware -- 0 with a named instrument, \*\*3 with none\*\*' "$Z" \
  "and with no filter all three rows are gaps, so a row that moved out of the table under a filter is not lost"
notwant 'Declared by another board only' "$Z" "and there is no other-board section, because there is no other board in this report"

echo "== 2. the instrument search, against a fake repo =="
# ==================================================================================================
#
# The subject is copied into the fake root, so its own `ROOT` is the fake root and the search runs over
# the fixture scripts. Seven blocks, one per verdict this report can produce.
cp "$SRC" "$FR/scripts/host/zl1-hardware-inventory.sh"
bash -n "$FR/scripts/host/zl1-hardware-inventory.sh" || { echo "the copied subject does not parse" >&2; exit 2; }

{ printf '%s\n' '#!/bin/sh'
  printf '%s\n' '# a reading, on a line that runs:'
  printf '%s\n' 'x=$(cat /dev/fcode_FCODE_TOKEN)'
  printf '%s\n' '# and a mention in prose of FSTALE_TOKEN which is NOT in this file'
  printf '%s\n' 'printf "%s\n" "$x"'
} > "$FR/scripts/instr-code.sh"
{ printf '%s\n' '#!/bin/sh'
  printf '%s\n' '# FCOMMENT_TOKEN is named here and nowhere else: a comment that names a block is not an'
  printf '%s\n' '# instrument, which is exactly the false COVERED this section exists to prevent.'
  printf '%s\n' ':'
} > "$FR/scripts/instr-comment.sh"
{ printf '%s\n' '#!/bin/sh'
  printf '%s\n' 'echo "FECHO_TOKEN: not a reading either -- a printed string is prose"'
} > "$FR/scripts/instr-echo.sh"
{ printf '%s\n' '#!/bin/sh'
  printf '%s\n' 'ALLOWLIST=(boot recovery system vendor persist modem dsp bluetooth FECHO_TOKEN)'
} > "$FR/scripts/backup-partitions-adb.sh"

# The seven rows. The DTB patterns are matched against the fixture tree built below, and `fnonode` is
# deliberately given a pattern that matches nothing -- the report has a separate bucket for that, and
# a row that lands in it must not be counted as either covered or a gap.
printf '%s\n' \
  'fcode	fcode,dev	FCODE_TOKEN	HW	scripts/instr-code.sh' \
  'fcomment	fcomment,dev	FCOMMENT_TOKEN	HW	scripts/instr-comment.sh' \
  'fecho	fecho,dev	FECHO_TOKEN	HW	scripts/instr-echo.sh' \
  'fbackup	fbackup,dev	FECHO_TOKEN	HW	scripts/backup-partitions-adb.sh' \
  'fself	fself,dev	FCODE_TOKEN	HW	scripts/host/zl1-hardware-inventory.sh' \
  'fstale	fstale,dev	FSTALE_TOKEN	HW	scripts/instr-code.sh' \
  'fgap	fgap,dev	FGAP_TOKEN	HW	-' \
  'fmissing	fmissing,dev	FMISSING_TOKEN	HW	scripts/does-not-exist.sh' \
  'fnonode	nomatch_at_all_xyz	-	HW	-' \
  'finfra	finfra,dev	FINFRA_TOKEN	INFRA	-' > "$W/table.txt"

python3 "$W/fdtbuild.py" '{"name":"","props":{},"children":[
  {"name":"a@1","props":{"compatible":"fcode,dev"},"children":[]},
  {"name":"b@2","props":{"compatible":"fcomment,dev"},"children":[]},
  {"name":"c@3","props":{"compatible":"fecho,dev"},"children":[]},
  {"name":"d@4","props":{"compatible":"fbackup,dev"},"children":[]},
  {"name":"e@5","props":{"compatible":"fself,dev"},"children":[]},
  {"name":"f@6","props":{"compatible":"fstale,dev"},"children":[]},
  {"name":"g@7","props":{"compatible":"finfra,dev"},"children":[]},
  {"name":"h@8","props":{"compatible":"fmissing,dev"},"children":[]},
  {"name":"i@9","props":{"compatible":"fgap,dev"},"children":[]},
  {"name":"j@10","props":{"compatible":"funclaimed,dev"},"children":[]}]}' "$FR/tmp-dtb-analysis/stock/dtbs/fixture.dtb" \
  || { echo "the fixture repo DTB could not be built" >&2; exit 2; }

R=$(bash "$FR/scripts/host/zl1-hardware-inventory.sh" --table "$W/table.txt" 2>/dev/null)
nonempty "the fixture report has content" "$R"
# A token that appears only in a comment, only in a printed string, only in a backup allowlist, or
# only in the subject itself must all land on the SAME verdict -- NONE, nothing reads this block --
# and each of those four was a real false COVERED while this script was being written.
want '^fcode +1 +instr-code\.sh' "$R" "a token on a line that runs is an instrument"
want '^fcomment +1 +\*\*NONE\*\*' "$R" "a token that appears only in a COMMENT does not cover the block"
want '^fecho +1 +\*\*NONE\*\*' "$R" "nor one that appears only in a printed string"
want '^fbackup +1 +\*\*NONE\*\*' "$R" "nor one that appears only in the backup allowlist, whose ALLOWLIST names real hardware blocks (modem, dsp, bluetooth) as partition names"
want '^fself +1 +\*\*NONE\*\*' "$R" "nor one whose only match is the subject itself -- without that exclusion every block matched the table it was carrying, and the summary read 34 covered, 0 gaps"
want '^fstale +1 +\*\*NONE\*\*' "$R" "nor a named instrument that exists but no longer names its block"
# STALE is a different verdict and has to stay one: it means the file the table names is not there,
# which is a defect in the TABLE. Folding the cases above into it would hide the gaps.
want '^fmissing +1 +STALE: does-not-exist\.sh' "$R" "a named instrument that is not there is STALE -- the table's path is wrong"
notwant '^finfra' "$R" "an INFRA row is not printed as a block at all (it would bury the gaps)"
want 'fnonode +nomatch_at_all_xyz' "$R" "a DTB pattern that matches no node is its own bucket, not a covered block"
want 'blocks: 8 hardware -- 1 with a named instrument, \*\*6 with none\*\*, 1 STALE; plus 1 infrastructure rows' "$R" \
  "the counts are exactly the fixture's: 1 covered, 6 gaps, 1 STALE, 1 INFRA -- and fnonode in none of them"
want '^  fcomment +1 dtb node\(s\), in S -- instr-comment\.sh names it only in prose$' "$R" \
  "the gap list names the block, its node count, the set, and that the named file mentions it only in prose"
want '^  fstale +1 dtb node\(s\), in S -- instr-code\.sh names it only in prose$' "$R" "and the same for a file that is a real instrument but does not read this block"
want '^  fbackup +1 dtb node\(s\), in S -- backup-partitions-adb\.sh names it only in prose$' "$R" \
  "including the excluded backup allowlist, which is named so a reader can see where the match was"
want '^  fmissing +scripts/does-not-exist\.sh$' "$R" "and the STALE list names the file the table points at, so the broken path is visible"
want '^  fgap +1 dtb node\(s\), in S$' "$R" "and a row that names no instrument at all is a plain gap -- the report says nothing about a file it was never given"
notwant '^  fcode ' "$R" "and the COVERED block is not in the gap list"
want 'the device tree: 10 distinct paths, 10 path/compatible pairs' "$R" "the fixture tree's own totals are counted, not assumed"
# ---------------------------------------------------------------------------------------------
# THE PART OF THE BOARD THE TABLE DOES NOT NAME (docs 156). Every count above is about the rows,
# and the rows are a hand-written claim -- so a block nobody wrote a row for was not a gap, it was
# invisible. `j@10` is exactly that: it is in the fixture tree and NO row claims it. Before this
# reading existed there was nothing in the report that could have said so.
want 'the board this TABLE does not name' "$R" "the report carries the reading that bounds its own table"
want '1 distinct compatible\(s\) on this board are claimed by NO row \(1 path/compatible' "$R" \
  "and it counts the one compatible nothing claims -- ONE, not the number of DTB files the fixture has"
UN=$(bash "$FR/scripts/host/zl1-hardware-inventory.sh" --table "$W/table.txt" --unclaimed 2>/dev/null)
want '/tmp-dtb-analysis/stock/dtbs/j@10|j@10' "$UN" "and --unclaimed lists the node, with its path, so it can be triaged"
want 'funclaimed,dev' "$UN" "naming the compatible a human would have to write a row for"
notwant '^fcode' "$UN" "and it is NOT the block table -- a claimed row is not in this list"
# THE COUNTER-CASE, and it is what makes the reading able to be zero rather than always nonzero: with a
# row that claims the same node, the count falls to 0 and the report says so in words. A reading that
# cannot reach its own empty value is a reading whose non-empty value means nothing.
cp "$W/table.txt" "$W/table-claimed.txt"
printf '%s\n' 'funclaimed	funclaimed,dev	FCODE_TOKEN	HW	scripts/instr-code.sh' >> "$W/table-claimed.txt"
R0=$(bash "$FR/scripts/host/zl1-hardware-inventory.sh" --table "$W/table-claimed.txt" 2>/dev/null)
want '0 distinct compatible\(s\) on this board are claimed by NO row \(0 path/compatible' "$R0" \
  "a row that claims the node takes the count to zero -- the reading is a count, not a constant"
UN0=$(bash "$FR/scripts/host/zl1-hardware-inventory.sh" --table "$W/table-claimed.txt" --unclaimed 2>/dev/null)
want '\(none: every path/compatible pair on this board is claimed by some row\)' "$UN0" \
  "and the empty list says so out loud, because an empty list and a reading that did not run look the same"
# THE REFUSAL. The rows are joined into ONE alternation to measure what they do not cover, and an empty
# alternative in an ERE matches everything -- so a row with a blank pattern would report the whole board
# as named. It is refused for the same reason the empty instrument field was: it inverts the answer.


# A malformed table must be refused. A four-field row puts the instrument where `kind` belongs, leaves
# the instrument empty -- and an empty pattern makes `grep -x` match every line, so the row is reported
# COVERED with a blank column. That happened while this harness was being written.
printf '%s\n' 'x	y	TOK	HW' > "$W/table-bad.txt"
OUT=$(bash "$FR/scripts/host/zl1-hardware-inventory.sh" --table "$W/table-bad.txt" 2>&1); rc=$?
if [ "$rc" = 2 ]; then ok "a table row that is not 5 fields exits 2"; else bad "a malformed table row exited $rc, not 2"; fi
want '4 field\(s\)' "$OUT" "and says which row and how many fields"
notwant 'with a named instrument' "$OUT" "and produces no report at all"

# The OTHER malformed table, and the one the reading above made dangerous: five fields, but the DTB
# PATTERN is blank. An empty alternative in the joined alternation matches every string, so this row
# would report the whole board as named -- "0 compatibles claimed by no row" -- while the row itself
# would read as covering every node. Both halves of that are the answer inverted, so it is refused.
printf 'y\t\tTOK\tHW\t-\n' > "$W/table-nopat.txt"
OUT=$(bash "$FR/scripts/host/zl1-hardware-inventory.sh" --table "$W/table-nopat.txt" 2>&1); rc=$?
if [ "$rc" = 2 ]; then ok "a table row with no DTB pattern exits 2"; else bad "a blank pattern exited $rc, not 2"; fi
want 'no DTB pattern' "$OUT" "and says which row it is"
want 'would report the whole board as named' "$OUT" "and why an empty pattern is worse than a wrong one"

# The refusal must be about the harness's own seam too: no DTBs and no snapshot is a refusal with the
# two ways forward, not an empty table. Run it from the fake root, which has a DTB, and then from one
# that has none.
mkdir -p "$W/nodtb/scripts/host"
cp "$SRC" "$W/nodtb/scripts/host/zl1-hardware-inventory.sh"
OUT=$(bash "$W/nodtb/scripts/host/zl1-hardware-inventory.sh" 2>&1); rc=$?
if [ "$rc" = 2 ]; then ok "no device trees and no --snapshot exits 2"; else bad "no trees exited $rc, not 2"; fi
want 'No device trees found and no --snapshot given' "$OUT" "and says so"
want 'tmp-\*/ \(gitignored scratch\)' "$OUT" "and says why they are missing (the DTBs are gitignored, so a fresh clone has none)"
want 'snapshot docs/ubuntu-touch/hardware-compatibles\.txt' "$OUT" "and names the committed snapshot, which is the way out"

# ==================================================================================================
echo "== 3. the report over the committed snapshot =="
# ==================================================================================================
if [ ! -r "$SNAP" ]; then
  bad "the committed snapshot is missing: $SNAP -- the whole report is unverifiable without it"
else
  ok "the committed snapshot is readable"
  R=$(bash "$SRC" --snapshot "$SNAP" 2>/dev/null)
  nonempty "the report has content" "$R"
  want 'nodes in the device tree: 688 distinct paths, 705 path/compatible pairs' "$R" \
    "THIS PHONE's enumeration, counted (the two numbers differ: a node can carry several compatibles, and a path can appear twice in one DTB)"
  # THE BOUND ON "0 GAPS" (docs 156). Every count in this report is about the rows, and the rows are a
  # hand-written claim; this reading measures what the claim leaves out, against the same trees. The two
  # numbers are typed here on purpose -- if the table grows, or a pattern widens, they move and this
  # harness says so.
  want 'The part of the board this TABLE does not name' "$R" \
    "the report carries the reading that bounds its own summary, in the default mode and not behind a flag"
  want '135 distinct compatible\(s\) on this board are claimed by NO row \(230 path/compatible' "$R" \
    "and the bound is a number: 135 compatibles this table does not claim"
  want 'cannot appear in the gap list at all' "$R" \
    "with the reason it exists: a gap is a row that failed, and a missing row fails nothing"
  want 'cannot be complete in the other direction' "$R" \
    "and the reading's OWN blind spot is stated, so the number is not read as 'this is everything left'"
  # The reading is where the block CAME FROM, and the pair of assertions below is that story end to end:
  # `qcom,qbt1000` is on this board in every set, no row claimed it, and it is now a row -- so it is a
  # GAP in the table and NOT in the unclaimed list any more. `qcom,msm_tspp` is the one that was found
  # and left out, and the reason it is left out is written down in docs 156 rather than implied here.
  want 'qcom,msm_tspp' "$(bash "$SRC" --snapshot "$SNAP" --unclaimed 2>/dev/null)" \
    "the list names the blocks that were found and not taken: qcom,msm_tspp is one, on purpose"
  notwant 'qcom,qbt1000' "$(bash "$SRC" --snapshot "$SNAP" --unclaimed 2>/dev/null)" \
    "and it no longer names the one that became a row -- a claimed block leaves the list"
  # The board filter is not a detail of this report, it is the correction it exists to carry: the
  # flashed boot image's appended blob holds the LeEco X2's device trees too, and the two boards' root
  # `compatible` is byte-identical, so an unfiltered report credits this phone with another phone's
  # hardware. That is what the old `vibrator` row did (`ti,drv2604l`, the X2's second haptics chip).
  want 'board:         THIS PHONE \(LE_ZL1\) only -- 688 of 699 paths' "$R" \
    "and the report says which phone it is about, and how many paths the filter took away"
  want '23 DTBs in the blob describe the LE_X2' "$R" "naming the other phone and the size of its share of the blob"
  notwant 'drv2604l' "$R" "the other phone's haptics chip is nowhere in this phone's report"
  RA=$(bash "$SRC" --snapshot "$SNAP" --board all 2>/dev/null)
  want 'nodes in the device tree: 699 distinct paths, 725 path/compatible pairs' "$RA" \
    "--board all is the whole blob -- the unfiltered number is 11 paths larger, which is the other phone"
  # The row docs 156 found, and the gap it closed (docs 157). This one is different from every other
  # closure recorded in this file: the other rows were written by hand and got an instrument later,
  # while `fingerprint-spi` was found by a READING (every `compatible` no row claims) and then given
  # one. So this assertion is the whole shape in one line -- a derived reading produced a row, the row
  # gained an instrument, and the hand-typed count had to be edited by whoever wrote it. The bound
  # docs 156 put on the report survives the count going back to 0: **0 gaps is still a statement about
  # the ROWS**, and the same report prints, two lines down, how many compatibles on this board no row
  # claims at all.
  want '^blocks: 30 hardware -- 30 with a named instrument, \*\*0 with none\*\*, 0 STALE; plus 6 infrastructure rows' "$R" \
    "30 hardware blocks and all 30 read by something -- because the block docs 156 found now has an instrument"
  want '^fingerprint-spi +1 +zl1-fp-kernel-probe\.sh' "$R" \
    "by name: the row a measurement created, covered by the probe written for it (docs 157)"
  want '^eeprom +[0-9]+ +zl1-eeprom-probe\.sh' "$R" \
    "with the last one -- eeprom, nothing missing -- covered by name"
  # Two more gaps closed on 2026-09-24 (docs 139): the notification LED and the camera torch, by
  # scripts/device/zl1-leds-probe.sh. The number is typed by hand and must be edited by whoever closes a
  # gap -- that is the whole point of asserting it.
  for b in torch notification-led; do
    want "^ *$b +[0-9]+ +zl1-leds-probe\\.sh" "$R" "  $b is reported as covered, by name"
  done
  # The count moved on 2026-09-24 and that is the point of asserting it: docs 138 gave the FIRST of the
  # twelve a probe (thermal-lmh, the hardware thermal limiter), so the number below had to be edited by
  # hand, in this file, by whoever closed the gap. A coverage number that can change without a reader
  # noticing is the defect the whole inventory exists to catch.
  want '^thermal-lmh +[0-9]+ +zl1-lmh-probe\.sh' "$R" \
    "and the gap that was closed is reported as covered, by name -- not silently dropped from both lists"
  # The largest one left, closed on 2026-09-24 (docs 141): video-codec, twelve nodes, by
  # scripts/device/zl1-video-probe.sh. Asserted the same way as the two above -- by name and by count --
  # because the number in the summary is typed by hand and a count that can change without a reader
  # noticing is the defect the whole inventory exists to catch.
  want '^video-codec +12 +zl1-video-probe\.sh' "$R" \
    "video-codec -- the largest gap -- is reported as covered, by name, with its twelve nodes"
  # The next one closed, 2026-09-24 (docs 142): `sdcard`, TWO controllers that are not the same kind of
  # thing -- one non-removable and enabled, one removable with a `cd-gpios` and disabled in the tree -- by
  # scripts/device/zl1-sdcard-probe.sh. Asserted by name and by node count like the three above.
  want '^sdcard +2 +zl1-sdcard-probe\.sh' "$R" \
    "sdcard -- two controllers -- is reported as covered, by name, with both of its nodes"
  # The next one closed, 2026-09-24 (docs 143): `usb-pd`, which is not one device but a MENU of four
  # CC-logic chips plus two vendor platform nodes -- and the row's own pattern did not match the second of
  # the two nodes the tree ENABLES (`cclogic_dev`), so the count moved from 5 to 6 as well as the verdict
  # from NONE to covered. Asserted by name and by count like the four above.
  want '^usb-pd +6 +zl1-usbpd-probe\.sh' "$R" \
    "usb-pd -- six nodes, a menu rather than a device -- is reported as covered, by name, with all six"
  # The next one closed, 2026-09-24 (docs 144): `hdmi`, which is not one device either -- it is SIX
  # descriptions and SEVEN nodes, the seventh being the audio DAI the row's pattern had missed. The
  # covered count moved 6 -> 7 with the verdict, and the row names its instrument like the five above.
  want '^hdmi +7 +zl1-hdmi-probe\.sh' "$R" \
    "hdmi -- two transmitter generations on one window, plus the DAI the pattern missed -- is covered, by name, with all seven"
  # The next one closed, 2026-09-24 (docs 145): `wfd`, the writeback / screen-mirroring block. Its row's
  # pattern named TWO node names and the block has THREE, the third being `qcom,wb-display` -- a
  # display-manager child of the generation that has no code in this kernel -- so the covered count moved
  # 2 -> 3 with the verdict.
  want '^wfd +3 +zl1-wfd-probe\.sh' "$R" \
    "wfd -- the panel, its framebuffer and the display-manager child nothing binds -- is covered, by name"
  # The tenth gap closed, 2026-09-24 (docs 146): `nfc`. It is ONE node, and the node carries TWO
  # generations of property names -- the five the driver reads and two (`nxp,p61-pwr` / `nxp,p61-rst`)
  # that no .c, .h or Kconfig in this tree asks for -- on two different gpio controllers. The row names
  # its instrument like the six above, and the node count is asserted with it.
  want '^nfc +1 +zl1-nfc-probe\.sh' "$R" \
    "nfc -- one node, two property namespaces and two gpio controllers -- is covered, by name"
  notwant 'STALE: ' "$R" "and every named instrument still names its block -- this is the check that stops the table rotting"
  # The gaps, by name. These are the answer to "which hardware has no probe"; if one of them gains a
  # probe this goes red, and it should: the coverage number must not change without someone looking.
  # The eleventh gap closed, 2026-09-24 (docs 147): `fm-radio`. It is ONE node, and it is the ONLY block
  # in this whole table whose device tree switches it OFF -- `status = "disabled"` in all 15 LE_ZL1 trees
  # and all three sets -- while the driver that would bind it is built into BOTH kernels in hand. A row
  # that read the config would call this block one build option away from working.
  want '^fm-radio +1 +zl1-fm-radio-probe\.sh' "$R" \
    "fm-radio -- one node, switched off by the tree itself -- is covered, by name"
  # The TWELFTH and last gap closed, 2026-09-24 (docs 148): `eeprom`. It is the mirror image of the block
  # above it in every respect that matters here -- one node, NOTHING missing (the driver is built into BOTH
  # kernels and the tree leaves the node enabled), and the gap list reaches zero because of it.
  want '^eeprom +1 +zl1-eeprom-probe\.sh' "$R" \
    "eeprom -- one node, nothing missing, the last block with no instrument -- is covered, by name"
  # THE GAP LIST IS EMPTY AGAIN, AND THIS TIME IT IS EARNED. It reached zero on 2026-09-24 (docs 148),
  # stopped being zero when docs 156 added `fingerprint-spi` to the table BY MEASURING what the table
  # leaves out, and is zero again because docs 157 wrote the probe that reads that block. The three
  # assertions below are the closure, stated in the direction that can fail: the section is NOT printed,
  # the row is NOT a NONE, and the summary says 0 -- where a report that had simply lost the ability to
  # print a gap would pass a "0 gaps" check for the wrong reason.
  #
  # That last risk is why the fixture sections above matter more than this one: `blocks: 8 hardware --
  # 1 with a named instrument, **6 with none**` and the `fgap` rows are a report printing gaps on demand.
  # A report that CAN print a gap is the only one whose zero means anything, and that is asserted there,
  # on a fixture this file controls, rather than hoped for here.
  notwant 'No script in this tree names these blocks:' "$R" \
    "the gap section is NOT printed -- the block docs 156 found is read now (docs 157)"
  notwant 'fingerprint-spi +1 +\*\*NONE\*\*' "$R" "and the row it created is not reported as unread"
  want '30 with a named instrument, \*\*0 with none\*\*' "$R" \
    "with the count at zero -- and this zero is bounded by the reading two lines below it, which says how many compatibles on this board NO ROW CLAIMS AT ALL"
  notwant '^  eeprom +[0-9]+ dtb node\(s\), in ' "$R" \
    "and eeprom no longer appears among the gaps -- a gap that is closed must leave the section"
  # Both device-tree sets are in play, and one block exists in only one of them: the DTB a block came
  # from decides whether it is on this board at all.
  # The vibrator, and the correction that produced this column. The block is the PMI8994 haptics
  # block (`qcom,qpnp-haptic`), which is in EVERY set; the `ti,drv2604l` node that made the old report
  # say "rebuilt only" belongs to the other phone. So the row must be COVERED here with no set
  # qualifier, and the old claim must be gone.
  want '^vibrator +1 +zl1-vibrator-probe\.sh \(\+1\) +F R S$' "$R" \
    "the vibrator is this board's PMI8994 haptics block, in every set -- not the X2's ti,drv2604l -- and exactly one other file names it (the capture chain that runs it)"
  want '^touch +3 ' "$R" "three touch controllers on this phone's trees (one is the one the user's finger proved)"
  want '^audio-codec +69 +zl1-audio-test\.sh' "$R" "the audio block's 69 nodes are read by one named probe -- 66 until docs 156, when the row's pattern was found to miss the codec's own SLIM bus and the sound card, which its token list had named all along"
  # The same two rows under --board all: the difference IS the other phone. This is the reading that
  # makes "the filter is doing something" visible on the real data and not only in a fixture.
  want '^touch +6 ' "$RA" "the other phone adds three more touch controllers to the same row"
  want '^audio-codec +70 +zl1-audio-test\.sh' "$RA" "and one more audio node -- its second amplifier"
  want '^modem +7 +zl1-modem-probe\.sh' "$R" "and the modem by its own, not by whichever file alphabetically mentions 'modem' first"
  want '^usb +10 +zl1-rndis-recover\.sh' "$R" "the USB block is credited to the RNDIS recovery, which actually rebinds it"
  # Symmetry: under the other board's filter, this phone's own fingerprint node is the one that lands in
  # the other-board section. A mechanism that works in one direction only is a coincidence.
  RX=$(bash "$SRC" --snapshot "$SNAP" --board x2 2>/dev/null)
  want '^  fingerprint +1 node\(s\), in .* -- declared by the LE_ZL1 \(this phone\)$' "$RX" \
    "and under --board x2 this phone's fingerprint node is the one listed as the other board's"
  notwant '^fingerprint +1 +goodix' "$RX" "so it is not in the other board's own table -- the row moved, it did not disappear"
  notwant '^  fingerprint +1 dtb node' "$RX" "and not in its gap list either -- a block in the other phone's trees is neither covered nor missing here"

  # The modes have to be modes: --gaps is the tail of the full report, and --block is one row.
  G=$(bash "$SRC" --snapshot "$SNAP" --gaps 2>/dev/null)
  want 'with none' "$G" "--gaps prints the summary line"
  notwant '^display-panel' "$G" "--gaps does not print the covered blocks"
  B=$(bash "$SRC" --snapshot "$SNAP" --block audio-codec 2>/dev/null)
  n=$(printf '%s\n' "$B" | grep -c '^audio-codec')
  [ "$n" = 1 ] && ok "--block prints exactly one block row" || bad "--block printed $n block rows"
  want 'blocks: 1 hardware' "$B" "and counts only that one"
  want 'plus 0 infrastructure rows' "$B" "and does not count infrastructure it did not print"

  # ================================================================================================
  echo "== 4. the snapshot against the device trees it came from =="
  # ================================================================================================
  # Both of these need the DTBs, which are `tmp-*/` and gitignored. When they are here, the snapshot
  # is checkable; when they are not, that is a SKIP that is printed and counted, not a quiet pass.
  DTBROOTS=()
  for d in "$ROOT"/tmp-dtb-analysis/stock/dtbs "$ROOT"/tmp-dtb-analysis/rebuilt/dtbs "$ROOT"/tmp-dtb-filtered; do
    [ -d "$d" ] && DTBROOTS+=("$d")
  done
  if [ ${#DTBROOTS[@]} -eq 0 ]; then
    # Five skips, not one, because the cited total must not depend on what this host happens to have:
    # the five checks below are the five this stands in for, and a section that shrinks the count is a
    # section that breaks the citation check wherever the DTBs are absent.
    skip "(no device trees on this host) the dump from the live device trees has content"
    skip "(no device trees on this host) the committed snapshot is byte-identical to the DTBs"
    skip "(no device trees on this host) the snapshot report equals the DTB report"
    skip "(no device trees on this host) the snapshot records its sources with a sha256 each"
    skip "(no device trees on this host) every recorded sha256 matches the file on disk"
  else
    D=$(bash "$SRC" --dump-compatibles 2>/dev/null)
    nonempty "the dump from the live device trees has content" "$D"
    # Byte-for-byte: the snapshot is only useful if it says exactly what the DTBs say. Up to the header,
    # which is per-run provenance and is excluded on both sides.
    if [ "$(grep -v '^#' <<< "$D")" = "$(grep -v '^#' "$SNAP")" ]; then
      ok "the committed snapshot is byte-identical to what the DTBs on this host produce"
    else
      bad "the snapshot and the DTBs disagree -- regenerate it with --dump-compatibles"
      diff <(grep -v '^#' <<< "$D") <(grep -v '^#' "$SNAP") | sed -n '1,6p' | sed 's/^/        | /'
    fi
    RS=$(bash "$SRC" --snapshot "$SNAP" 2>/dev/null)
    RD=$(bash "$SRC" 2>/dev/null)
    if [ "$RS" = "$RD" ]; then
      ok "and the report is identical whether it is derived from the snapshot or from the DTBs"
    else
      bad "the snapshot path and the DTB path give different reports"
      diff <(printf '%s\n' "$RS") <(printf '%s\n' "$RD") | sed -n '1,6p' | sed 's/^/        | /'
    fi
    # The snapshot names each source file and its sha256. Verify them: a snapshot that cannot be traced
    # back to a revision is a table someone typed.
    mism=0; seen=0
    while IFS= read -r line; do
      f=$(sed -n 's/^#   source \([^ ]*\) .*sha256=\([0-9a-f]*\)$/\1/p' <<< "$line"); [ -n "$f" ] || continue
      h=$(sed -n 's/^#   source [^ ]* .*sha256=\([0-9a-f]*\)$/\1/p' <<< "$line")
      seen=$((seen + 1))
      [ -f "$ROOT/$f" ] || continue
      [ "$(sha256sum "$ROOT/$f" | cut -d' ' -f1)" = "$h" ] || { mism=$((mism + 1)); echo "        | $f" ; }
    done < "$SNAP"
    [ "$seen" -gt 0 ] && ok "the snapshot records $seen source device trees with a sha256 each" ||
      bad "the snapshot records no provenance -- it cannot be traced back to a revision"
    [ "$mism" = 0 ] && ok "every recorded sha256 matches the file on disk" ||
      bad "$mism recorded source(s) do not match the file on disk -- the snapshot is from another revision"
  fi
fi

# ==================================================================================================
echo "== 5. this harness's own citation =="
# ==================================================================================================
HEALTH="$HERE/zl1-health-check.sh"
if [ -r "$HEALTH" ]; then
  cited=$(sed -e 's/always "/ /g' -e 's/"$//' "$HEALTH" | tr '\n' ' ' |
            sed -n 's/.*zl1-hardware-inventory-selftest.sh[ ,(]*\([0-9][0-9]*\) checks.*/\1/p')
  total=$((PASS + FAIL + SKIP + 1))
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
echo "pass=$PASS fail=$FAIL skip=$SKIP"
if [ "$KEEP" = 1 ]; then
  echo "kept: $W"
else
  rm -rf "$W"
fi
[ "$FAIL" = 0 ]
