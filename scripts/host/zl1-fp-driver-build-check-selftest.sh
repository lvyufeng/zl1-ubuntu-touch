#!/usr/bin/env bash
# Host-side selftest for scripts/host/zl1-fp-driver-build-check.sh -- offline, no device, no kbuild.
#
# What this asserts, and why each half is needed
# ---------------------------------------------
# The subject answers ONE question -- how far the HAL's fingerprint sensor is from having a driver at all
# -- and its answer is a LADDER of rungs whose top one is `one-config-line-away`. That top rung is the
# kind of answer this project has been burned by: a check that cannot fail reads exactly like a check
# that passed. So both directions are asserted:
#
#   * ON A FIXTURE this file controls, every rung is REACHED, by breaking one link at a time. A rung
#     nothing can reach is not a rung, it is a sentence.
#   * ON THE REAL TREE, the top rung is actually produced, and each of its load-bearing readings (the
#     compile, the link against the built vmlinux, and 5 of 5 trees) is present as a LINE.
#
# Six mutations then break ONE thing each in the SUBJECT (not in the fixture) and must redden a NAMED
# assertion, so a rung reached by accident cannot pass for one that is computed. Four of the six are
# defects this instrument's own first runs produced:
#
#   1. the `depends on INPUT` lookup without the `CONFIG_` prefix   -> every kernel reads dependency-off
#   2. a one-line reader for `$(MODULE_NAME)-objs`                  -> `platform.o` disappears
#   3. no `#if 0` stripping                                         -> dead code becomes a requirement
#   4. FDT offsets taken in FILE coordinates instead of the blob's  -> five real trees "do not exist"
#   5. the `getline` loop without its return-value test             -> the subject hangs for ever
#   6. the shell quoting left in the recovered compile flags        -> a compile that fails for no reason
#
# (5) is asserted the way this project records a hang has to be: the MUTATED run must be the one that
# does not come back, and the subject must come back on the same fixture. (6) is asserted as a rung,
# because a compile that fails for a reason unrelated to the driver is the most dangerous kind of red.
#
# WHAT THIS DOES NOT TEST: that the device-side fingerprint judgement changes, that a BUILD of the image
# succeeds, or that flashing is safe. The subject's top rung says the software path is one config line
# away and says nothing about any of those -- and this file asserts that the subject PRINTS those
# caveats rather than leaving them to the reader.

set -uo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/zl1-fp-driver-build-check.sh"

case "${1:-}" in
--help|-h)
  # Its own header, verbatim -- the shape `host/zl1-cli-usage-selftest.sh` requires of every script the
  # health check names, and it is not decoration: that harness runs `--help` before it runs anything else,
  # so a script with no handler would be run for real. It is answered BEFORE the subject is looked for,
  # because that harness also copies this file to a temp directory to check that the printed block GROWS
  # with the header -- and a copy has no neighbour, so a guard that ran first would answer nothing and
  # the growth test would read 0.
  awk 'NR==1{next} /^#/{print; next} {exit}' "$0"
  exit 0 ;;
esac

[ -r "$SRC" ] || { echo "the subject is not readable: $SRC" >&2; exit 2; }

KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1
W=$(mktemp -d "${TMPDIR:-/tmp}/zl1-fpbc-selftest.XXXXXX") || exit 2
cleanup() { [ "$KEEP" = 1 ] || rm -rf "$W"; }
trap cleanup EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
# No `-q` and no `| head` anywhere below: under `set -o pipefail` a reader that exits at its first match
# can kill the writer with SIGPIPE and turn a match into a failure. grep without -q reads all of stdin.
want()   { if printf '%s\n' "$2" | grep -E -- "$1" >/dev/null 2>&1; then ok "$3"; else bad "$3"; printf '%s\n' "$2" | sed -n '1,12p' | sed 's/^/        | /'; fi; }
notwant(){ if printf '%s\n' "$2" | grep -E -- "$1" >/dev/null 2>&1; then bad "$3"; printf '%s\n' "$2" | grep -E -- "$1" | sed 's/^/        | /'; else ok "$3"; fi; }
wantf()  { case "$2" in *"$1"*) ok "$3" ;; *) bad "$3" ;; esac; }
verdict(){ printf '%s\n' "$2" | sed -n 's/^== verdict: //p' | sed -n 1p; }

echo "zl1 fingerprint driver build-check -- selftest"
echo "  subject: $SRC"
echo "  temp:    $W"

# ==================================================================================================
# The fixture: a kernel tree and a kbuild output directory small enough to read, shaped exactly like the
# real ones in the four places the answer depends on -- the Kconfig entry and its dependency, the
# Makefile's two-level wiring WITH THE TRAILING BACKSLASH, the driver's own names and its device-tree
# requirements (including one inside an `#if 0`), and a device tree. A fixture that tidied any of those
# away could not catch a defect in the reading that depends on it.
# ==================================================================================================
mkdtb() { # FILE  MODEL  COMPATIBLE  SPI-STATUS(empty for none)
python3 - "$@" <<'PY'
import struct, sys
path, model, compat, status = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
# The strings block is assembled AS THE NAMES ARE EMITTED, so each nameoff is a BYTE OFFSET into it --
# not an index into a list. Getting that wrong makes every property name read as garbage, and the walker
# then reports a tree that is missing every property the driver asks for: a fixture defect that looks
# exactly like a finding about the board.
stb = bytearray()
offs = {}
def soff(n):
    if n not in offs:
        offs[n] = len(stb)
        stb.extend(n.encode() + b'\0')
    return offs[n]
props = []
def prop(p, n, v):
    props.append((p, n, v if isinstance(v, bytes) else v.encode() + b'\0'))
prop('', 'model', model)
prop('', '#address-cells', struct.pack('>I', 1))
prop('', '#size-cells', struct.pack('>I', 1))
prop('soc', '#address-cells', struct.pack('>I', 1))
prop('soc/spi@7579000', 'compatible', 'qcom,spi-qup-v2')
if status:
    prop('soc/spi@7579000', 'status', status)
prop('soc/spi@7579000/goodixfp@0', 'compatible', compat)
prop('soc/spi@7579000/goodixfp@0', 'goodix,gpio_irq', struct.pack('>III', 28, 121, 1))
prop('soc/spi@7579000/goodixfp@0', 'goodix,gpio_reset', struct.pack('>III', 28, 31, 0))
prop('soc/spi@7579000/goodixfp@0', 'gfvdda-supply', struct.pack('>I', 1))
prop('soc/spi@7579000/goodixfp@0', 'input-device-name', 'gf318m')
sb = bytearray()
def begin(name):
    sb.extend(struct.pack('>I', 1) + name.encode() + b'\0' + b'\0' * ((4 - (len(name) + 1) % 4) % 4))
def endnode():
    sb.extend(struct.pack('>I', 2))
def emit(p_, n, v):
    sb.extend(struct.pack('>III', 3, len(v), soff(n)) + v + b'\0' * ((4 - len(v) % 4) % 4))
_prefix = ''
for node in ('', 'soc', 'spi@7579000', 'goodixfp@0'):
    begin(node)
    _prefix = node if not _prefix else _prefix + '/' + node
    for (p_, n, v) in props:
        if p_ == _prefix:
            emit(p_, n, v)
for _ in range(4):
    endnode()
sb.extend(struct.pack('>I', 9))
blob = struct.pack('>10I', 0xd00dfeed, 56 + len(sb) + len(stb), 56, 56 + len(sb), 40,
                   0x11, 0x10, 0, len(stb), len(sb)) + b'\0' * 16 + bytes(sb) + bytes(stb)
open(path, 'wb').write(blob)
PY
}

mk_fixture() { # [model] [compatible] [spi-status] [option: notset|on]
  local model="${1:-Letv Technologies, Inc. MSM 8996pro + PMI8996 LE_ZL1-DVT1}"
  local compat="${2:-goodix,fingerprint}"
  local spist="${3:-}"
  local optst="${4:-notset}"
  rm -rf "$W/fx"
  mkdir -p "$W/fx/src/drivers/input/goodixfp" "$W/fx/src/arch/arm64/configs" \
           "$W/fx/obj/arch/arm64/boot/dts/qcom"
  cat > "$W/fx/src/drivers/input/goodixfp/gf_spi.h" <<'EOF'
#define  USE_SPI_BUS	1
/*#define  USE_PLATFORM_BUS     1*/
EOF
  cat > "$W/fx/src/drivers/input/goodixfp/gf_spi.c" <<'EOF'
#include "gf_spi.h"
#define GF_SPIDEV_NAME     "goodix,fingerprint"
#define GF_DEV_NAME            "goodix_fp"
#define	GF_INPUT_NAME	    "gf318m"
static int gf_probe(struct spi_device *spi)
{
	gf_dev->vreg = regulator_get(&spi->dev, "gfvdda");
	return 0;
}
static int gf_parse_dts(struct gf_dev *gf_dev)
{
#if 0
	gf_dev->pwr_gpio = of_get_named_gpio(dev, "goodix,gpio_pwr", 0);
#endif
	of_get_named_gpio(dev, "goodix,gpio_reset", 0);
	of_get_named_gpio(dev, "goodix,gpio_irq", 0);
	return 0;
}
EOF
  cat > "$W/fx/src/drivers/input/goodixfp/platform.c" <<'EOF'
#include "gf_spi.h"
int gf_parse_dts(struct gf_dev *gf_dev) { return 0; }
EOF
  sed -i "s/\"goodix,fingerprint\"/\"$compat\"/" "$W/fx/src/drivers/input/goodixfp/gf_spi.c"
  cat > "$W/fx/src/drivers/input/goodixfp/Kconfig" <<'EOF'
config INPUT_GP5XX8
	tristate "Goodix GP5XX8 driver support"
	depends on INPUT
	help
	  fixture
EOF
  # The Makefile's LAST line ends with a backslash, exactly as the real one does. That is what turns the
  # naive `getline` loop into a hang; a fixture without it could not catch defect 5.
  printf 'MODULE_NAME := gf\nobj-$(CONFIG_INPUT_GP5XX8) := $(MODULE_NAME).o\n\n$(MODULE_NAME)-objs := gf_spi.o \\\n                       platform.o \\\n' \
    > "$W/fx/src/drivers/input/goodixfp/Makefile"
  printf 'obj-$(CONFIG_INPUT_GP5XX8)\t+= goodixfp/\n' > "$W/fx/src/drivers/input/Makefile"
  printf 'menu "Input device support"\nendmenu\n' > "$W/fx/src/drivers/input/Kconfig"
  if [ "$optst" = on ]; then
    printf 'CONFIG_INPUT=y\nCONFIG_INPUT_GP5XX8=y\n' > "$W/fx/obj/.config"
  else
    printf 'CONFIG_INPUT=y\n# CONFIG_INPUT_GP5XX8 is not set\n' > "$W/fx/obj/.config"
  fi
  cp "$W/fx/obj/.config" "$W/fx/src/arch/arm64/configs/lineage_zl1_defconfig"
  mkdtb "$W/fx/obj/arch/arm64/boot/dts/qcom/le_zl1-dvt1.dtb" "$model" "$compat" "$spist"
}

fxargs() {
  printf '%s\n' --src "$W/fx/src" --objdir "$W/fx/obj" --config "$W/fx/obj/.config" \
    --defconfig "$W/fx/src/arch/arm64/configs/lineage_zl1_defconfig" \
    --dtb-dir "$W/fx/obj/arch/arm64/boot/dts/qcom" --boot /nonexistent-boot.img "$@"
}
fxrun() { OUT=$(bash "$SRC" $(fxargs "$@") 2>&1); RC=$?; }
# A tree hash, so "it does not write into the tree it reads" is a reading and not a promise.
snap() { (cd "$1" && find . -type f | sort | while IFS= read -r f; do sha256sum "$f"; done) | sha256sum | cut -c1-16; }

# ==================================================================================================
echo
echo "== 1. the fixture reaches the rung it earns, and every reading below it is a LINE =="
# ==================================================================================================
mk_fixture; BEFORE=$(snap "$W/fx"); fxrun; AFTER=$(snap "$W/fx")
[ "$RC" = 0 ] && ok "exit 0 on a fixture (a verdict is not an error: the verdict IS the answer)" || bad "it exited $RC"
[ "$BEFORE" = "$AFTER" ] && ok "the fixture tree is byte-identical after the run ($BEFORE) -- it reads the tree and writes nothing into it" \
  || bad "THE FIXTURE TREE CHANGED: $BEFORE -> $AFTER"
V=$(verdict "" "$OUT")
[ "$V" = not-verified-whether-it-compiles ] && ok "with no .cmd and no vmlinux, the rung is 'not-verified-whether-it-compiles' -- the compile cannot be attempted and that is NOT the top rung" \
  || bad "the fixture's rung was '$V'"
want 'THE COMPILE WAS NOT ATTEMPTED' "$OUT" "and the missing reading is named"
want 'vmlinux is not readable' "$OUT" "with why"
want 'A check that could not be made is not a pass' "$OUT" "the rung's own message says the rule out loud"
wantf 'its Makefile:  2:obj-$(CONFIG_INPUT_GP5XX8) := $(MODULE_NAME).o' "$OUT" "the fixture's own Makefile wiring is read (line number and all)"
wantf 'parent:        1:obj-$(CONFIG_INPUT_GP5XX8)' "$OUT" "and the parent Makefile's line too"
wantf 'module name:   gf' "$OUT" "the module name comes from MODULE_NAME, not from a guess"
want 'built from:    gf_spi.o platform.o$' "$OUT" "BOTH objects are read, across the continuation line"
want 'bus branch:    USE_SPI_BUS' "$OUT" "the bus branch is read out of the header, not assumed"
wantf "of_match_table: GF_SPIDEV_NAME = 'goodix,fingerprint'" "$OUT" "the compatible is read out of the driver's own #define"
want 'required by the driver:gfvdda-supply goodix,gpio_irq goodix,gpio_reset' "$OUT" "the device-tree requirements are read out of the driver's own source"
notwant 'goodix,gpio_pwr' "$OUT" "and the one inside \`#if 0\` is NOT among them"
wantf '/soc/spi@7579000/goodixfp@0 compatible: goodix,fingerprint   missing: -' "$OUT" "the fixture tree carries the node with every requirement"
want '1 tree\(s\) naming THIS phone, 0 naming the other board' "$OUT" "one tree, and it is this phone's"
want 'depends on: INPUT' "$OUT" "the Kconfig dependency is read"
want 'INPUT = y \(built in\)' "$OUT" "and evaluated against the CONFIG-side spelling, which is \`CONFIG_INPUT\` and not \`INPUT\`"
wantf 'CONFIG_INPUT_GP5XX8 = NOT SET' "$OUT" "the option is off in the fixture's built config"
want 'WHAT THIS IS NOT: a statement that the sensor works' "$OUT" "and the caveat rides with every verdict, including this one"

# ==================================================================================================
echo
echo "== 2. every rung is reachable: one broken link at a time =="
# ==================================================================================================
mk_fixture "Letv Technologies, Inc. MSM 8996pro + PMI8996 LE_ZL1-DVT1" "goodix,fp-v2"; fxrun
[ "$(verdict "" "$OUT")" = match-table-differs ] && ok "a driver whose of_match_table is not the node's compatible -> match-table-differs (the config line would build a driver that matches nothing)" \
  || bad "rung was '$(verdict "" "$OUT")'"
want 'matches this node NEVER' "$OUT" "and the message says why that rung sits above the config line"

mk_fixture "Letv Technologies, Inc. MSM 8996pro + PMI8996 LE_X2-PVT"; fxrun
[ "$(verdict "" "$OUT")" = no-tree-for-this-phone ] && ok "a tree naming the OTHER phone -> no-tree-for-this-phone (nothing here is about this board)" \
  || bad "rung was '$(verdict "" "$OUT")'"
want 'not this phone' "$OUT" "and the other board's tree is PRINTED as such rather than dropped"

mk_fixture "Letv Technologies, Inc. MSM 8996pro + PMI8996 LE_ZL1-DVT1" "goodix,fingerprint" "disabled"; fxrun
[ "$(verdict "" "$OUT")" = node-missing-or-incomplete ] && ok "an SPI controller the tree DISABLES -> node-missing-or-incomplete: a child cannot bind under a disabled parent, and that link is before the config line" \
  || bad "rung was '$(verdict "" "$OUT")'"
wantf 'spi-disabled' "$OUT" "with the reason named in the verdict"

mk_fixture "Letv Technologies, Inc. MSM 8996pro + PMI8996 LE_ZL1-DVT1" "goodix,fingerprint" "" "on"; fxrun
[ "$(verdict "" "$OUT")" = already-in-the-kernel ] && ok "a built config that ALREADY has the option on -> already-in-the-kernel, which is a contradiction with docs 157 and not a success" \
  || bad "rung was '$(verdict "" "$OUT")'"
want 'this instrument is the wrong one' "$OUT" "and the message says the instrument is the wrong one rather than hinting at success"

mk_fixture; rm -f "$W/fx/src/drivers/input/goodixfp/gf_spi.c"; fxrun
[ "$(verdict "" "$OUT")" = driver-source-missing ] && ok "no source file -> driver-source-missing" || bad "rung was '$(verdict "" "$OUT")'"

mk_fixture; : > "$W/fx/src/drivers/input/goodixfp/gf_spi.c"; fxrun
[ "$(verdict "" "$OUT")" = driver-source-missing ] && ok "an EMPTY source file is the same rung, so 'the file is here' is never read as 'the driver is here'" \
  || bad "rung was '$(verdict "" "$OUT")'"

mk_fixture; printf 'x\n' > "$W/fx/src/drivers/input/goodixfp/Kconfig"; fxrun
[ "$(verdict "" "$OUT")" = option-not-in-kconfig ] && ok "no \`config INPUT_GP5XX8\` line -> option-not-in-kconfig" || bad "rung was '$(verdict "" "$OUT")'"

mk_fixture; printf '# CONFIG_INPUT is not set\n# CONFIG_INPUT_GP5XX8 is not set\n' > "$W/fx/obj/.config"; fxrun
[ "$(verdict "" "$OUT")" = dependency-off ] && ok "a dependency the BUILT config does not satisfy -> dependency-off, the rung for a config line kbuild would silently ignore" \
  || bad "rung was '$(verdict "" "$OUT")'"
want 'INPUT = NOT SET' "$OUT" "with the dependency printed in its own state"

mk_fixture; rm -f "$W/fx/obj/arch/arm64/boot/dts/qcom/le_zl1-dvt1.dtb"; fxrun
[ "$(verdict "" "$OUT")" = no-tree-for-this-phone ] && ok "a readable DTB directory with no DTB in it is a claim about the BOARD (no tree names it), which is a different sentence from 'I could not read one'" \
  || bad "rung was '$(verdict "" "$OUT")'"

mk_fixture; printf 'this is not a device tree\n' > "$W/fx/obj/arch/arm64/boot/dts/qcom/garbage.dtb"; fxrun
[ "$(verdict "" "$OUT")" = trees-partly-unreadable ] && ok "a .dtb that EXISTS and cannot be parsed -> trees-partly-unreadable: a file that failed to parse must never read as 'no tree names this board'" \
  || bad "rung was '$(verdict "" "$OUT")'"
want 'UNREADABLE DTB: garbage.dtb' "$OUT" "and the file that could not be read is named"
want 'could not be read' "$OUT" "with the distinction spelled out in the verdict"

mk_fixture; fxrun --dtb-dir "$W/no-such-dtb-dir"
[ "$(verdict "" "$OUT")" = node-reading-not-made ] && ok "no readable DTB directory at all -> node-reading-not-made: 'I could not look' is not 'the node is fine'" \
  || bad "rung was '$(verdict "" "$OUT")'"
want 'THE NODE READING IS SKIPPED' "$OUT" "and the missing reading is said out loud"

fxrun --src /nonexistent-kernel-tree
[ "$RC" = 3 ] && ok "an unreadable kernel tree exits 3" || bad "it exited $RC"
[ "$(verdict "" "$OUT")" = unreadable-kernel-tree ] && ok "with a rung that claims NOTHING, because every reading below it would have been about another kernel" \
  || bad "rung was '$(verdict "" "$OUT")'"
want 'NOTHING IS CLAIMED' "$OUT" "and it says so in those words"

mk_fixture; rm -f "$W/fx/src/drivers/input/Kconfig"; fxrun
[ "$RC" = 3 ] && ok "a missing parent Kconfig exits 3" || bad "it exited $RC"
[ "$(verdict "" "$OUT")" = unreadable-inputs ] && ok "as unreadable-inputs, naming the file" || bad "rung was '$(verdict "" "$OUT")'"

# ==================================================================================================
echo
echo "== 3. the six mutations: each breaks ONE thing in the SUBJECT and must redden a named assertion =="
# ==================================================================================================
mkdir -p "$W/mut"
mut() { # name, old-text, new-text, [tail-marker: apply this replacement only after this text]
  python3 - "$SRC" "$W/mut/$1.sh" "$2" "$3" "${4:-}" <<'PY'
import sys
src, dst, old, new, tail = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
orig = open(src).read()
s = orig
if tail:
    if tail not in s:
        sys.exit(2)
    i = s.index(tail)
    head, rest = s[:i], s[i:]
    if old not in rest:
        sys.exit(2)
    s = head + rest.replace(old, new, 1)
else:
    if old not in s:
        sys.exit(2)
    s = s.replace(old, new, 1)
if s == orig:
    sys.exit(3)
open(dst, 'w').write(s)
PY
  case $? in
  0) ok "mutation '$1' applied" ;;
  2) bad "mutation '$1' COULD NOT BE APPLIED: its target text is not in the subject (the reading it guards has been rewritten -- re-derive the mutation before trusting the rung)" ;;
  3) bad "mutation '$1' did not change the subject" ;;
  *) bad "mutation '$1' failed unexpectedly" ;;
  esac
}
mutrun() { # mutated script [args...]
  local m="$1"; shift
  if [ $# = 0 ]; then OUT=$(bash "$m" $(fxargs) 2>&1); else OUT=$(bash "$m" "$@" 2>&1); fi
  RC=$?
}

# (1) the `CONFIG_` prefix. Without it `depends on INPUT` is looked up as `^INPUT=` in a file that says
#     `CONFIG_INPUT=y`, the answer comes back "absent", and EVERY kernel reads as dependency-off.
mut noconfigprefix '  case "$1" in CONFIG_*) ;; *) set -- "CONFIG_$1" "$2" ;; esac' '  :'
if [ -r "$W/mut/noconfigprefix.sh" ]; then
  mk_fixture; mutrun "$W/mut/noconfigprefix.sh"
  [ "$(verdict "" "$OUT")" = dependency-off ] && ok "  without the prefix a SATISFIED dependency is reported UNSATISFIED, so the prefix is load-bearing and not decoration" \
    || bad "  the mutation did not change the rung ('$(verdict "" "$OUT")')"
  want 'INPUT = absent from this config' "$OUT" "  and the reported state is 'absent', which is the tell"
fi

# (2) the continuation line. A one-line reader takes `gf_spi.o` and stops, so the reading says the driver
#     is built from one file when it is built from two -- this project's "an extractor that drops an item"
#     shape, invisible unless the reader is asserted.
mut onelined 'while ($0 ~ /\\$/ && (getline) > 0) printf "%s ", $0' '_ = 0'
if [ -r "$W/mut/onelined.sh" ]; then
  mk_fixture; mutrun "$W/mut/onelined.sh"
  want 'built from:    gf_spi.o$' "$OUT" "  the mutated reader reads ONE object"
  notwant 'built from:    gf_spi.o platform.o' "$OUT" "  so 'both objects' is a reading of the continuation line and of nothing else"
fi

# (3) the `#if 0` strip. Without it `goodix,gpio_pwr` -- dead code, and in no tree on this board -- is
#     required of every tree, so every tree is "incomplete" and the verdict is about a tree that is fine.
mut nodeadstrip '    dead > 0 { next }' '    dead > 0 { }'
if [ -r "$W/mut/nodeadstrip.sh" ]; then
  mk_fixture; mutrun "$W/mut/nodeadstrip.sh"
  want 'required by the driver:.*goodix,gpio_pwr' "$OUT" "  the mutated reader requires a property that exists only in dead code"
  want 'missing: goodix,gpio_pwr' "$OUT" "  so a tree that is fine is reported incomplete"
  [ "$(verdict "" "$OUT")" = node-missing-or-incomplete ] && ok "  and the verdict becomes a false red about the DTS" || bad "  rung was '$(verdict "" "$OUT")'"
fi

# (4) the alignment defect. The fixture's image puts its DTB at 0x1002 -- 2 mod 4, the shape the real image
#     has (0xb4ae66) -- so an offset aligned in FILE coordinates walks off the sliced blob and fails.
mk_fixture
python3 - "$W/fx" <<'PY'
import os, sys
fx = sys.argv[1]
dtb = open(os.path.join(fx, 'obj/arch/arm64/boot/dts/qcom/le_zl1-dvt1.dtb'), 'rb').read()
pad = b'ANDROID!' + b'\x00' * 4090          # 4098 bytes: 2 mod 4, so the blob starts at 0x1002
assert len(pad) % 4 == 2
open(os.path.join(fx, 'boot.img'), 'wb').write(pad + dtb)
PY
OUT=$(bash "$SRC" $(fxargs --boot "$W/fx/boot.img") 2>&1)
want '^   #1  @0x1002 ' "$OUT" "an appended tree at 0x1002 -- 2 mod 4 -- IS walked, and at the offset it is at"
want 'goodixfp@0 present    byte-identical to a built .dtb' "$OUT" "and it is IDENTIFIED against the built .dtb by hash, not assumed to be one of them"
want '0 magic\(s\) that could not be walked' "$OUT" "with nothing left unwalkable, so the self-consistency check and the walk agree"
notwant 'ONE READING IS MISSING' "$OUT" "and the appended reading is not reported as missing"
python3 - "$SRC" "$W/mut/filealign.sh" <<'PY'
import sys
s = open(sys.argv[1]).read()
# The append walker is the LAST of the two: its header lines are textually identical to the DTB walker's,
# so every replacement below is anchored at the END of the file. (An earlier version of this mutation
# anchored on `while True:` -- which is the SCAN loop, and it CALLS the walker rather than containing it,
# so the mutation found nothing and the assertion it guards would have been silently untested.)
for old, new in (('    end = off_struct + size_struct', '    end = off_struct + size_struct + base'),
                 ('    pos = off_struct', '    pos = off_struct + base'),
                 ('off_strings + noff', 'off_strings + noff + base'),
                 ('        p = walk(blob)', '        p = walk(blob, off)')):
    i = s.rindex(old)
    s = s[:i] + new + s[i + len(old):]
assert 'def walk(blob):' in s
s = s.replace('def walk(blob):', 'def walk(blob, base=0):', 1)
open(sys.argv[2], 'w').write(s)
PY
if [ -s "$W/mut/filealign.sh" ] && ! cmp -s "$SRC" "$W/mut/filealign.sh"; then
  ok "mutation 'filealign' applied (the append walk takes its offsets in FILE coordinates)"
  mk_fixture
  python3 - "$W/fx" <<'PY'
import os, sys
fx = sys.argv[1]
dtb = open(os.path.join(fx, 'obj/arch/arm64/boot/dts/qcom/le_zl1-dvt1.dtb'), 'rb').read()
open(os.path.join(fx, 'boot.img'), 'wb').write(b'ANDROID!' + b'\x00' * 4090 + dtb)
PY
  mutrun "$W/mut/filealign.sh" $(fxargs --boot "$W/fx/boot.img")
  want '0 tree\(s\) walked inside the image, 1 magic\(s\) that could not be walked' "$OUT" "  with offsets taken in FILE coordinates the walk leaves the blob and the tree is not found -- the defect that reported five real trees as absent"
  want 'NO TREE INSIDE THE IMAGE COULD BE WALKED' "$OUT" "  and that is reported as a MISSING reading rather than as an image without device trees"
  notwant '^   #1  @0x1002 ' "$OUT" "  no tree is found at all under the mutation"
else
  bad "mutation 'filealign' COULD NOT BE APPLIED (the append walker has been rewritten -- re-derive it)"
fi
# A magic that is a coincidence (the real image has one) must not be reported as an unreadable tree.
python3 - "$W/fx/boot2.img" <<'PY'
import sys
open(sys.argv[1], 'wb').write(b'\xd0\x0d\xfe\xed' + b'\x00' * 60)
PY
OUT=$(bash "$SRC" $(fxargs --boot "$W/fx/boot2.img") 2>&1)
notwant 'MAGIC AT' "$OUT" "an image whose only magic is a coincidence is NOT reported as a tree that could not be walked"
want 'NO TREE INSIDE THE IMAGE COULD BE WALKED' "$OUT" "and the appended reading is reported as not made, which is what it is"

# (5) the hang. The `getline` loop on a Makefile whose last line ends with a backslash never returns, and
#     a hang has no exit code -- so the assertion is that the run COMES BACK, and that the MUTATED run is
#     the one that does not.
mut hang 'while ($0 ~ /\\$/ && (getline) > 0) printf "%s ", $0' 'while ($0 ~ /\\$/) { getline; printf "%s ", $0 }'
if [ -r "$W/mut/hang.sh" ]; then
  mk_fixture
  timeout -k 2 20 bash "$W/mut/hang.sh" $(fxargs) >/dev/null 2>&1; HRC=$?
  [ "$HRC" = 124 ] && ok "  the mutated script HANGS on a Makefile whose last line ends with a backslash (killed at 20 s, rc=124) -- so the fix is load-bearing" \
    || bad "  the mutated script returned rc=$HRC, so the fixture cannot see the hang it exists for"
  mk_fixture
  timeout -k 2 60 bash "$SRC" $(fxargs) >/dev/null 2>&1; TRC=$?
  [ "$TRC" != 124 ] && ok "  and the subject COMES BACK on the same fixture (rc=$TRC)" || bad "  the subject itself hung"
fi

# ==================================================================================================
echo
echo "== 4. what this instrument must never do, asserted over the shipped file =="
# ==================================================================================================
CODE=$(sed 's/#.*//' "$SRC")
for pat in 'fastboot' 'adb ' 'ssh ' 'scp ' 'flash' 'mount' 'reboot' 'QFIL' 'edl\.py' 'mkfs' '(^|[[:space:]])dd[[:space:]]'; do
  if printf '%s\n' "$CODE" | grep -E -- "$pat" >/dev/null 2>&1; then
    bad "the subject's CODE matches '$pat' -- it must have no device path at all"
  else
    ok "no '$pat' in the subject's code"
  fi
done
# Every redirection to an ABSOLUTE path in the code, listed. The only one allowed is /dev/null: the source
# tree, the build directory and the boot image are inputs, and an instrument that writes into them is not
# an instrument any more.
REDIR=$(printf '%s\n' "$CODE" | grep -oE '>>?[[:space:]]*"?/[A-Za-z0-9_./$-]+' | sed 's/>>\?[[:space:]]*"\?//' | sort -u | tr '\n' ' ' | sed 's/ *$//')
[ "$REDIR" = /dev/null ] && ok "the only absolute path the subject redirects to is /dev/null (found: '$REDIR')" \
  || bad "the subject redirects to absolute paths other than /dev/null: '$REDIR'"
wantf 'W=$(mktemp -d' "$CODE" "its temp dir is created with mktemp -d, not with a fixed name"
wantf 'trap cleanup EXIT' "$CODE" "and it is removed on exit"
wantf 'does not write one byte into the' "$(cat "$SRC")" "and the refusal is written down in the file itself"
wantf 'does not flash, does not mount' "$(cat "$SRC")" "including the list of things it does not do"

# ==================================================================================================
echo
echo "== 5. the REAL tree: the top rung, and the readings that make it one =="
# ==================================================================================================
# This is the half that cannot live in a fixture: the compile needs the toolchain, the link needs a real
# vmlinux, and the trees must be the ones a build actually produced. It doubles as an EXPIRY CHECK -- if
# someone turns the option on, this reddens and they have to say why.
RSRC="${ZL1_KERNEL_SRC:-/mnt/data/halium-zl1-build/kernel/leeco/msm8996}"
ROBJ="${ZL1_KERNEL_OBJ:-/mnt/data/halium-zl1-build/out/target/product/zl1/obj/KERNEL_OBJ}"
RDTB="$ROBJ/arch/arm64/boot/dts/qcom"
if [ -d "$RSRC" ] && [ -d "$ROBJ" ] && [ -d "$RDTB" ]; then
  ROUT=$(timeout -k 5 900 bash "$SRC" 2>&1); RRC=$?
  [ "$RRC" = 0 ] && ok "the subject runs against the real tree (rc=0)" || bad "against the real tree it exited $RRC"
  RV=$(verdict "" "$ROUT")
  [ "$RV" = one-config-line-away ] && ok "and the verdict is 'one-config-line-away' -- measured here, not read back from a document" \
    || bad "the real tree's verdict is '$RV'"
  wantf 'CONFIG_INPUT_GP5XX8 = NOT SET' "$ROUT" "the BUILT config has the option off"
  want 'INPUT = y \(built in\)' "$ROUT" "and the option's only dependency is satisfied"
  want 'built from:    gf_spi.o platform.o$' "$ROUT" "the real Makefile's continuation line is read whole"
  want 'required by the driver:gfvdda-supply goodix,gpio_irq goodix,gpio_reset' "$ROUT" "the real driver's requirements, with the dead one excluded"
  want '5 tree\(s\) naming THIS phone, 0 naming the other board' "$ROUT" "all five of this phone's built trees, and none of the other board's"
  notwant 'UNREADABLE DTB' "$ROUT" "and every one of them could be parsed"
  wantf 'missing: -' "$ROUT" "every one of them carries a usable node"
  want '5 of 5 trees naming this phone carry the node' "$ROUT" "and the verdict counts them rather than asserting it in prose"
  want 'gf_spi.c: rc=0' "$ROUT" "the real driver COMPILES with the build's own recovered flags"
  want 'platform.c: rc=0' "$ROUT" "both of its translation units do"
  want 'kernel.s own vmlinux' "$ROUT" "and every undefined symbol resolves against the vmlinux built from this tree"
  want '5 tree\(s\) walked inside the image' "$ROUT" "the boot image's appended trees are walked"
  want 'byte-identical to a built .dtb' "$ROUT" "each one IDENTIFIED against the built output by hash, not assumed"
  want 'goodixfp@0 present' "$ROUT" "with the node present in the trees the image actually carries"
  notwant 'ONE READING IS MISSING' "$ROUT" "and no reading is missing, so the caveat is absent -- which is what makes it a reading when it is there"

  # the last rung: a vmlinux that defines nothing. "It compiles" and "it belongs to THIS kernel" are two
  # readings, and this is the one where the second fails. The objdir is the real one with every entry
  # SYMLINKED except vmlinux, because kbuild's recovered flags carry RELATIVE -I paths (the driver is
  # compiled with `cd $OBJ`), so a hand-made objdir fails at the compile for a reason that has nothing to
  # do with symbols -- the first version of this test did exactly that and blamed the driver.
  mkdir -p "$W/unres"
  for e in "$ROBJ"/* "$ROBJ"/.[!.]*; do
    [ -e "$e" ] || continue
    b="${e##*/}"
    case "$b" in vmlinux|.config|.config.old) continue ;; esac
    ln -sfn "$e" "$W/unres/$b"
  done
  printf 'CONFIG_INPUT=y\n# CONFIG_INPUT_GP5XX8 is not set\n' > "$W/unres/.config"
  printf 'not an ELF, and it defines nothing\n' > "$W/unres/vmlinux"
  UOUT=$(timeout -k 5 900 bash "$SRC" --src "$RSRC" --objdir "$W/unres" --config "$W/unres/.config" \
         --defconfig "$RSRC/arch/arm64/configs/lineage_zl1_defconfig" --boot /nonexistent 2>&1)
  [ "$(verdict "" "$UOUT")" = driver-has-unresolved-symbols ] && ok "a vmlinux that defines nothing -> driver-has-unresolved-symbols: it compiles and does not belong to this kernel" \
    || bad "the last rung produced '$(verdict "" "$UOUT")'"
  want 'UNRESOLVED: ' "$UOUT" "and the symbols are named rather than counted"

  # the quote-stripping defect (6): kbuild's recorded line carries `-D"KBUILD_STR(s)=#s"`, and reproducing
  # it in a shell VARIABLE without removing those quotes makes gcc fail for a reason that has nothing to
  # do with the driver -- a false red about the driver, which is the most dangerous kind of red.
  mut quoteflags "out = line[i:].strip().replace('\"', '')" 'out = line[i:].strip()'
  if [ -r "$W/mut/quoteflags.sh" ]; then
    QOUT=$(timeout -k 5 900 bash "$W/mut/quoteflags.sh" 2>&1)
    [ "$(verdict "" "$QOUT")" = driver-does-not-compile ] && ok "  with the shell quoting left in the flags the compile fails and the verdict blames the DRIVER -- the false red the strip exists to prevent" \
      || bad "  the quote mutation landed on '$(verdict "" "$QOUT")'"
    want 'macro names must be identifiers' "$QOUT" "  and the diagnostic is the one the quotes produce"
  fi

  # the rule stated in the subject's own header, end to end: with no toolchain the verdict must drop off
  # the top rung rather than quietly standing on readings that were never made.
  mkdir -p "$W/notc"
  NOOUT=$(ZL1_TC_BIN="$W/notc" timeout -k 5 900 bash "$SRC" --quiet 2>&1)
  [ "$(verdict "" "$NOOUT")" = not-verified-whether-it-compiles ] && ok "with no toolchain the REAL tree drops off the top rung to 'not-verified-whether-it-compiles'" \
    || bad "with no toolchain the verdict was '$(verdict "" "$NOOUT")'"
  # and the same rule for an objdir the flags cannot be recovered from: there is nothing to compile FROM.
  # A vmlinux is present here so that the reason that fires is the missing `.cmd`, not the missing kernel.
  mkdir -p "$W/nocmd"
  printf 'CONFIG_INPUT=y\n# CONFIG_INPUT_GP5XX8 is not set\n' > "$W/nocmd/.config"
  printf 'not an ELF\n' > "$W/nocmd/vmlinux"
  ZOUT=$(timeout -k 5 900 bash "$SRC" --objdir "$W/nocmd" --config "$W/nocmd/.config" \
         --dtb-dir "$RDTB" --quiet 2>&1)
  want 'no sibling .o.cmd under' "$ZOUT" "and with no .o.cmd at all the reason names the file it could not recover the flags from"
else
  bad "the real kernel tree, its build dir or its DTB output is not on this host, so the top rung CANNOT BE CHECKED here -- and a skip is not a pass (set ZL1_KERNEL_SRC / ZL1_KERNEL_OBJ)"
fi

# ==================================================================================================
echo
echo "== 6. --quiet, --help, --explain, and the count the health check cites =="
# ==================================================================================================
mk_fixture
QOUT=$(bash "$SRC" $(fxargs --quiet) 2>&1)
notwant '^== 1\.|^== 2\.|^== 3\.|sha=|msm8996|LE_ZL1' "$QOUT" "--quiet prints no readings (the first version's column printers ignored the flag)"
notwant 'built from|depends on|of_match_table' "$QOUT" "and none of the section bodies leak through"
want '^== verdict: ' "$QOUT" "but the verdict is still there"
HELP=$(bash "$SRC" --help 2>&1)
want '^# The fingerprint sensor the HAL opens has NO DRIVER' "$HELP" "--help prints the header, read out of the file itself"
want 'one-config-line-away' "$HELP" "including the top rung it can reach"
want 'What this NEVER does' "$HELP" "and what it refuses to do"
want 'Exit codes: 0 a verdict was reached' "$HELP" "and the exit-code contract"
notwant '^[^#]' "$HELP" "and every line of it is the file's own comment (the shape the CLI harness runs every named script through)"
EX=$(bash "$SRC" --explain 2>&1)
[ "$EX" != "$HELP" ] && ok "--help and --explain print different sections of the file" || bad "the two flags print the same thing"
EX=$(bash "$SRC" --explain 2>&1)
want 'THE VERDICT IS A LADDER' "$EX" "--explain prints the ladder and its rungs"
want 'trees-partly-unreadable' "$EX" "including the rung that separates 'no tree here' from 'a tree here could not be read'"
want 'AND THE TOP RUNG IS NOT A PROMISE' "$EX" "and the paragraph that says what the top rung does not claim"
BOGUS=$(bash "$SRC" --not-a-flag 2>&1); BRC=$?
[ "$BRC" = 2 ] && ok "an unknown argument exits 2" || bad "an unknown argument exited $BRC"
want 'unknown argument' "$BOGUS" "and says which one"

# The health check names every harness WITH a hand-typed count, and docs 110 records one of those going
# stale with nothing noticing. Each harness therefore checks its OWN citation, so adding a check here
# means editing the page in the same commit -- and the failure names the page to fix.
HEALTH="$HERE/zl1-health-check.sh"
if [ -r "$HEALTH" ]; then
  match=$(tr '\n' ' ' < "$HEALTH" | grep -oE 'zl1-fp-driver-build-check-selftest\.sh[^0-9]*[0-9]+ checks' | sed -n 1p)
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
