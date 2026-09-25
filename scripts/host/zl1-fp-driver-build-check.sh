#!/usr/bin/env bash
# The fingerprint sensor the HAL opens has NO DRIVER -- what would it take to put one in?
#
# Why this exists
# ---------------
# docs 157 read the fingerprint's answer at the kernel layer, and the answer is per-block and opposite:
# this board's device tree declares TWO fingerprint blocks, and the kernel it boots builds a driver for
# exactly one of them -- `/soc/qcom,qbt1000` (CONFIG_MSM_QBT1000=y) and NOT
# `/soc/spi@7579000/goodixfp@0`, which is the Goodix sensor the container's HAL opens `/dev/goodix_fp`
# for (`# CONFIG_INPUT_GP5XX8 is not set`). Every fingerprint document in this project is about the
# layers ABOVE the driver; this is the layer below them, and it is empty for the HAL's sensor.
#
# That stage ended with a one-line sentence for the fix -- "make the kernel include that driver", i.e.
# a REBUILD plus a boot flash -- and a sentence is not a plan. A boot image is the most expensive thing
# in this project: it costs a physical press, it is the step that has ended in EDL before, and the
# project's rule is that a flash happens only with backups documented and a rollback that is one
# command. So before anyone edits a defconfig, the chain from "this option is off" to "this driver
# binds and creates /dev/goodix_fp" has to be MEASURED, link by link, offline.
#
# This is that measurement. It answers one question -- HOW FAR AWAY IS IT -- and it answers it with the
# build's own artefacts, not with a defconfig someone may have edited since:
#
#   1. THE OPTION     the Kconfig entry, its `depends on` line, and the state of every dependency IN
#                     THE BUILT CONFIG (the `.config` kbuild actually used, not a defconfig).
#   2. THE SOURCE     the driver files, the module name, the bus branch the preprocessor takes
#                     (USE_SPI_BUS vs USE_PLATFORM_BUS -- which decides `spi_driver` vs
#                     `platform_driver`, and therefore which sysfs path a probe must look at), and the
#                     of_match_table's compatible.
#   3. THE NODE       the device tree the BUILD produced -- every DTB whose `model` names THIS phone --
#                     and whether the node is there with the properties THE DRIVER ASKS FOR. That list
#                     is read out of the driver's own source (every `of_get_named_gpio()` and
#                     `regulator_get()` call), not out of a document: a requirement nobody wrote down
#                     is exactly the one that fails the probe.
#   4. COMPILES       the two translation units are compiled with THE BUILD'S OWN COMMAND LINE --
#                     recovered from the `.cmd` file kbuild leaves beside a sibling object -- into a
#                     temp directory. A link step (`ld -r`) follows, and every undefined symbol is
#                     resolved against the `vmlinux` that was built from this tree, so "it compiles"
#                     and "it belongs to THIS kernel" are two readings and not one.
#
# THE VERDICT IS A LADDER, and the rung names the FIRST link that is missing:
#
#   kernel-tree-missing / unreadable   a source, a config or a tree could not be read -- NOTHING is
#                                      claimed (exit 3). Every reading below it would be about a
#                                      different kernel than the one the phone boots.
#   driver-source-missing              the option exists but no file in this tree implements it (or the
#                                      file is present and EMPTY, which is the same rung: there is
#                                      nothing here that could carry the driver).
#   option-not-in-kconfig              no `config INPUT_GP5XX8` anywhere -- the option was removed.
#   dependency-off                     the option's own `depends on` lines are not all satisfied by
#                                      the built config, so it cannot be turned on at all.
#   match-table-differs                the driver's of_match_table does not carry the node's
#                                      compatible byte for byte: enabling it would build a driver that
#                                      matches nothing.
#   node-absent-from-the-dtb           this phone's built trees do not declare the node -- then the
#                                      config line is NOT the last link and the DTS is.
#   node-lacks-a-required-property     the node is there and the driver asks for a property it does
#                                      not have: `gf_parse_dts()` returns non-zero and the probe bails
#                                      BEFORE creating the character device. Names the property.
#   trees-partly-unreadable            a .dtb under the build output exists and could not be parsed, so
#                                      the node reading covers only the files that could be read. It sits
#                                      BEFORE "no tree names this phone" on purpose: "there is no such
#                                      tree" and "I could not read one" are different facts about
#                                      different things (the board, and this instrument).
#   driver-does-not-compile            names the file and the first diagnostic.
#   driver-has-unresolved-symbols      it compiles and does not link into THIS kernel. Names them.
#   not-verified-whether-it-compiles   the compile could not be attempted (no toolchain, or no sibling
#                                      `.cmd` to recover the flags from). A check that could not be
#                                      made is NOT a pass, and this rung says so out loud.
#   already-in-the-kernel              the built config has the option ON. What that means depends
#                                      on which question you are asking, and the verdict says which:
#                                      for "how far is this driver" the distance is ZERO; for the
#                                      premise this instrument was written under (docs 157 read the
#                                      RUNNING image and it said not set) it is a contradiction to be
#                                      explained before anything is built. Since docs 159 the option is
#                                      on DELIBERATELY, so the caveat now names the image instead: this
#                                      verdict is about the BUILD DIRECTORY, and the build directory is
#                                      not the image -- read the image (host/zl1-boot-image-kernel.sh).
#   one-config-line-away               every link is in place: the option is available and its
#                                      dependencies are satisfied, the driver is in this tree, it
#                                      matches the node's compatible exactly, this phone's built trees
#                                      carry the node with every property the driver asks for, and it
#                                      compiles and links against this kernel's vmlinux. The one
#                                      missing thing is the line in the config.
#
# AND THE TOP RUNG IS NOT A PROMISE. It says the SOFTWARE PATH is one line away. It does NOT say the
# sensor answers, that the HAL then works, or that flashing is safe -- the trust store, the store
# directory (docs 126), the TZ application and the sensor's own hardware are all above or below this
# line, and the fingerprint's device-side judgement (`setActiveGroup failed` going to zero) is
# untouched by anything here.
#
# Usage: zl1-fp-driver-build-check.sh [--src DIR] [--objdir DIR] [--config FILE] [--defconfig FILE]
#                                     [--dtb-dir DIR] [--boot IMG] [--quiet] [--keep] [--explain]
#   --src DIR       the kernel source tree (default: the tree that built the running kernel)
#   --objdir DIR    the kbuild output directory, for the built `.config` and the sibling `.cmd`
#   --config FILE   the BUILT config (default: <objdir>/.config) -- the one kbuild used
#   --defconfig F   the defconfig the build starts from (default: this board's)
#   --dtb-dir DIR   where the built .dtb files are (default: the build's qcom directory)
#   --boot IMG      the boot image whose APPENDED trees are cross-checked against the built ones
#                   (default: the v63 rebuilt image). Absent -> that one reading is SKIPPED, loudly.
#   --quiet         the verdict only, not the readings
#   --keep          keep the temp directory and print its path
#   --explain       what the verdict rungs mean and what this refuses to do
#
# Exit codes: 0 a verdict was reached (ANY rung, including the bad ones -- the verdict is the answer);
#             2 a required tool or input is missing; 3 an input could not be read.
#
# What this NEVER does: it does not run kbuild, does not configure, does not write one byte into the
# source tree or the build directory, does not flash, does not mount, and has no device code path at
# all -- the only thing it executes is a compiler and a linker, with their output inside a temp
# directory it removes. Compiling two files against headers that already exist is not building a boot
# image, and the distinction is the point: this instrument exists so that the decision to build one is
# made on a measured plan rather than on a sentence.

set -uo pipefail
export LC_ALL=C

SRC="${ZL1_KERNEL_SRC:-/mnt/data/halium-zl1-build/kernel/leeco/msm8996}"
OBJ="${ZL1_KERNEL_OBJ:-/mnt/data/halium-zl1-build/out/target/product/zl1/obj/KERNEL_OBJ}"
BOOT="${ZL1_BOOT_IMG:-/mnt/data/halium-zl1-candidates/halium-boot-zl1-v63-rebuilt.img}"
DTBD="${ZL1_DTB_DIR:-$OBJ/arch/arm64/boot/dts/qcom}"
TCBIN="${ZL1_TC_BIN:-/mnt/data/halium-zl1-build/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/bin}"
DEFCONF="${ZL1_DEFCONFIG:-$SRC/arch/arm64/configs/lineage_zl1_defconfig}"
KCFG="${ZL1_KERNEL_CONFIG:-$OBJ/.config}"
QUIET=0; KEEP=0; EXPLAIN=0

while [ $# -gt 0 ]; do
  case "$1" in
  --src)       SRC="${2?--src needs a path}"; shift 2 ;;
  --objdir)    OBJ="${2?--objdir needs a path}"; shift 2 ;;
  --config)    KCFG="${2?--config needs a path}"; shift 2 ;;
  --defconfig) DEFCONF="${2?--defconfig needs a path}"; shift 2 ;;
  --dtb-dir)   DTBD="${2?--dtb-dir needs a path}"; shift 2 ;;
  --boot)      BOOT="${2?--boot needs an image}"; shift 2 ;;
  --quiet)     QUIET=1; shift ;;
  --keep)      KEEP=1; shift ;;
  --explain)   EXPLAIN=1; shift ;;
  --help|-h)
    # The header VERBATIM, `#` and all -- the same lines `host/zl1-cli-usage-selftest.sh` derives with
    # the same awk, which is what makes `--help` a check on the manual rather than a paraphrase of it.
    awk 'NR==1{next} /^#/{print; next} {exit}' "$0"
    exit 0 ;;
  *) echo "unknown argument: $1 (--help for usage)" >&2; exit 2 ;;
  esac
done

# The driver's four names, and the option. They are here, once, because the whole point of docs 157 is
# that this block has FOUR names and not one of them is the compatible:
#   CONFIG_INPUT_GP5XX8  the option      gf_spi.c   the source file
#   goodix_fp            the driver .name            goodix,fingerprint  the compatible
OPT=CONFIG_INPUT_GP5XX8
DRVDIR="$SRC/drivers/input/goodixfp"
MAIN="$DRVDIR/gf_spi.c"
AUX="$DRVDIR/platform.c"
KCONF="$DRVDIR/Kconfig"
KMAKE="$DRVDIR/Makefile"
PMAKE="$SRC/drivers/input/Makefile"
PKCONF="$SRC/drivers/input/Kconfig"
COMPAT='goodix,fingerprint'
NODEPATH='/soc/spi@7579000/goodixfp@0'
SPIPATH='/soc/spi@7579000'
BIN="aarch64-linux-android"

W=$(mktemp -d "${TMPDIR:-/tmp}/zl1-fp-build.XXXXXX") || exit 2
cleanup() { [ "$KEEP" = 1 ] || rm -rf "$W"; }
trap cleanup EXIT

say()  { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
# The per-tree lines are printed with printf because they are columns, not sentences -- and that made
# `--quiet` a lie the first time it was asked for: the flag suppressed the `say` lines and every column
# kept coming. One helper, used by every column, is what makes the promise checkable.
sayf() { [ "$QUIET" = 1 ] || printf "$@"; }
head_() { [ "$QUIET" = 1 ] || { printf '\n'; printf '%s\n' "$*"; }; }
VMSG=""
V=""

exit_unreadable() { # rung, message
  V="$1"; VMSG="$2"
  printf '== verdict: %s\n' "$V"
  printf '   %s\n' "$VMSG"
  printf '\n   NOTHING IS CLAIMED. This is exit 3: an input could not be read, so every reading below it\n'
  printf '   would have been about a different kernel than the one the phone boots.\n'
  [ "$KEEP" = 1 ] && echo "kept: $W"
  exit 3
}
exit_missing_tool() { printf 'missing: %s\n' "$1" >&2; exit 2; }

if [ "$EXPLAIN" = 1 ]; then
  sed -n '/^# THE VERDICT IS A LADDER/,/^# What this NEVER does/p' "$0" | sed 's/^# \?//' | sed '$d'
  exit 0
fi

for t in python3 sha256sum awk grep sed mktemp; do
  command -v "$t" >/dev/null 2>&1 || exit_missing_tool "$t"
done

say "zl1 fingerprint driver -- how far is the HAL's sensor from having a driver at all"
say "  kernel source: $SRC"
say "  build dir:     $OBJ"
say "  built config:  $KCFG"
say "  built dtbs:    $DTBD"
say "  boot image:    $BOOT"
say "  note:          this host's bash has no 'local'; nothing here writes outside $W"
[ "$KEEP" = 1 ] && say "  temp dir:      $W (kept)"

# ==================================================================================================
# 0. Are the inputs there at all? Every one of them is a FILE the answer depends on, and a missing one
#    is exit 3 rather than a verdict -- the difference between "the driver is missing" and "I could not
#    look at the kernel" is the whole reason this project separates them.
# ==================================================================================================
MISSING=""
# The toolchain is NOT in this list, and that is deliberate: a cross compiler is not an input to the
# QUESTION (how far away is the driver), it is an instrument of one section. On a host without it,
# every static link is still measurable -- which is the whole reason the ladder has a rung below the top
# -- so its absence belongs to section 7 and to that rung, not to exit 3 that claims nothing at all.
for f in "$SRC/arch/arm64/configs" "$KCFG" "$DEFCONF" "$PMAKE" "$PKCONF"; do
  [ -e "$f" ] || MISSING="$MISSING $f"
done
[ -d "$SRC" ] || exit_unreadable unreadable-kernel-tree "$SRC is not a directory: this instrument reads the tree that built the running kernel, and it has not been pointed at one."
[ -n "$MISSING" ] && exit_unreadable unreadable-inputs "these inputs are not on this host:$MISSING"

# ==================================================================================================
# 1. Identity. docs 152: a reading is only as good as the identity of its input, and every one of these
#    paths can be rebuilt under the same name. The hashes travel with the verdict, and the harness
#    asserts that each one is printed -- a file read without one is a file this instrument cannot
#    defend a week from now.
# ==================================================================================================
head_ "== 1. the inputs, BY IDENTITY (a path can hold a different file tomorrow) =="
ident() { # label, file
  [ "$QUIET" = 1 ] && return 0
  if [ -r "$1" ]; then
    printf '   %-26s %10s  %s  %s\n' "$2" "$(wc -c < "$1" | tr -d ' ')" "$(sha256sum "$1" | cut -c1-16)" "${1##*/}"
  else
    printf '   %-26s %10s  %s  %s\n' "$2" "-" "(absent)" "${1##*/}"
  fi
}
say "   (16 hex digits of each sha256; the full digest is in the doc for the run that produced a verdict)"
ident "$MAIN"      "driver main"
ident "$AUX"       "driver platform"
ident "$KCONF"     "Kconfig"
ident "$KMAKE"     "Makefile"
ident "$DEFCONF"   "defconfig"
ident "$KCFG"      "built .config"
ident "$OBJ/vmlinux" "built vmlinux"
ident "$BOOT"      "boot image"
if [ -d "$DTBD" ]; then
  NDTB=0
  for d in "$DTBD"/*.dtb; do
    [ -f "$d" ] || continue
    ident "$d" "built dtb"
    NDTB=$((NDTB + 1))
  done
  say "   built dtbs found: $NDTB"
fi

# ==================================================================================================
# 2. The option. Four separate facts, and only the first is about the source tree:
#      (a) the Kconfig entry exists and what it DEPENDS ON
#      (b) every one of those dependencies is satisfied IN THE BUILT CONFIG
#      (c) the defconfig denies it (the line's shape, so a wrong one is visible)
#      (d) the BUILT config denies it -- this is the one that decides
#    (c) and (d) are kept apart on purpose: a defconfig is a file someone may have edited since, and the
#    config is what actually compiled. An instrument that read only the defconfig would be answering
#    about a file rather than about a kernel.
# ==================================================================================================
head_ "== 2. the option: is it AVAILABLE, and is it OFF in the kernel that booted =="
OPT_DEF=""; OPT_BUILT=""; DEPS=""; DEP_BAD=""
cfg_state() { # option, file -> y / m / NOT SET / absent
  # A config file spells every symbol `CONFIG_<name>` while a Kconfig `depends on` line spells it
  # `<name>`, so the prefix is added here rather than at each call site. Without it `depends on INPUT`
  # was looked up as `^INPUT=` in a file that says `CONFIG_INPUT=y` -- and the answer came back
  # "absent", which this instrument reports as a FAILED dependency. A dependency that reads as broken
  # because of a naming convention is the same defect as a wrong verdict (the first run of this file
  # said `dependency-off` about a kernel that has CONFIG_INPUT=y).
  case "$1" in CONFIG_*) ;; *) set -- "CONFIG_$1" "$2" ;; esac
  if [ ! -r "$2" ]; then printf 'UNREADABLE'; return; fi
  case "$(grep -E "^$1=|^# $1 is not set\$" "$2" 2>/dev/null | sed -n 1p)" in
  "$1=y") printf 'y (built in)' ;;
  "$1=m") printf 'm (a module)' ;;
  "# $1 is not set") printf 'NOT SET' ;;
  *) printf 'absent from this config' ;;
  esac
}
if [ -r "$KCONF" ]; then
  want_ln=$(grep -nE "^config[[:space:]]+${OPT#CONFIG_}[[:space:]]*\$" "$KCONF" | sed -n 1p)
  if [ -n "$want_ln" ]; then
    ln=${want_ln%%:*}
    say "   $KCONF:${ln}: $(sed -n "${ln}p" "$KCONF" | sed 's/^[[:space:]]*//')"
    DEPS=$(sed -n "$((ln + 1)),\$p" "$KCONF" | sed -n '1,/^config /p' | grep -E '^[[:space:]]*depends on ' |
           sed 's/^[[:space:]]*depends on //' | tr '\n' '|' | sed 's/|$//')
    if [ -z "$DEPS" ]; then say "   (it has NO 'depends on' line: nothing can gate it)"; else
      say "   depends on: $DEPS"
      # The dependencies are evaluated against the BUILT config, one by one, and each is printed with
      # its state. A dependency whose name is not in the config is reported as absent, not as satisfied:
      # 'the file did not mention it' and 'it is on' are different facts and only one of them is safe.
      for d in $(printf '%s\n' "$DEPS" | tr '|' ' '); do
        st=$(cfg_state "$d" "$KCFG")
        say "     $d = $st"
        case "$st" in y*|m*) ;; *) DEP_BAD="$DEP_BAD $d($st)" ;; esac
      done
    fi
  else
    say "   NO 'config ${OPT#CONFIG_}' entry in $KCONF"
  fi
else
  say "   $KCONF is not readable -- the option's own definition cannot be read"
fi
OPT_DEF=$(cfg_state "$OPT" "$DEFCONF")
OPT_BUILT=$(cfg_state "$OPT" "$KCFG")
say "   defconfig  ($DEFCONF): $OPT = $OPT_DEF"
say "   built cfg  ($KCFG): $OPT = $OPT_BUILT"

# ==================================================================================================
# 3. The source, and the three things about it that decide whether this is a one-line change.
#    The bus branch is not a detail: with USE_SPI_BUS the driver registers an spi_driver, with
#    USE_PLATFORM_BUS a platform_driver, and the sysfs path a probe must read is different for each --
#    docs 157's probe reports the former, and this is where that claim can be checked.
# ==================================================================================================
head_ "== 3. the driver in the source tree: which files, which module, which bus, which compatible =="
SRC_OK=1
EMPTY=""
for f in "$MAIN" "$AUX" "$KCONF" "$KMAKE"; do
  if [ -r "$f" ]; then say "   present: $f"; else say "   MISSING: $f"; SRC_OK=0; fi
done
# A source file that is PRESENT AND EMPTY is not the same reading as a file that is absent, but it is the
# same rung: there is nothing here that could carry the driver. It is called out because the alternative
# is worse -- an empty `gf_spi.c` has no `GF_SPIDEV_NAME`, so the match-table check reads "nothing" and
# the verdict would blame the COMPATIBLE for a file that was never written. This project has that shape
# recorded: a file's shape is not what it answers.
for f in "$MAIN" "$AUX"; do
  [ -e "$f" ] && [ ! -s "$f" ] && EMPTY="$EMPTY $f"
done
[ -n "$EMPTY" ] && say "   EMPTY (0 bytes):$EMPTY"
MODNAME=$(sed -n 's/^MODULE_NAME[[:space:]]*:=[[:space:]]*//p' "$KMAKE" 2>/dev/null | sed -n 1p)
MK_OBJ=$(grep -nE "obj-\\\$\($OPT\)" "$KMAKE" 2>/dev/null | sed -n 1p)
PMK_OBJ=$(grep -nE "obj-\\\$\($OPT\)" "$PMAKE" 2>/dev/null | sed -n 1p)
say "   module name:   ${MODNAME:-(none)}"
say "   its Makefile:  ${MK_OBJ:-no obj-\$($OPT) line}"
say "   parent:        ${PMK_OBJ:-no obj-\$($OPT) line in $PMAKE}"
# The composite object's members: `$(MODULE_NAME)-objs := gf_spi.o platform.o`. Read rather than assumed,
# because the line is where a source file would be left out -- and a file left out here compiles and then
# fails at LINK time, which is the reading in section 7.
# **The continuation line is the whole point.** The Makefile writes
#   $(MODULE_NAME)-objs := gf_spi.o \\
#                          platform.o
# and a one-line `sed -n ...p` reads `gf_spi.o` and stops -- so `platform.o` disappears from this
# reading while the file still compiles them both (section 7 compiles them by name). That is this
# project's recorded "an extractor that drops an item" shape, caught here on the first run: the reading
# said the driver is built from ONE file when it is built from two. `sed -n` with an address RANGE,
# joined, is what makes the list whole.
#
# AND THE LOOP MUST TEST `getline`'s RETURN VALUE. This Makefile's LAST line ends with a backslash and
# there is no line after it: `getline` at EOF returns 0 and LEAVES `$0` UNCHANGED, so a loop written as
# `while ($0 ~ /\\$/) { getline; ... }` spins forever on that last line. It did -- the instrument hung
# with no child process, which is what a wall-clock hang looks like from outside (this project has that
# shape recorded: a hang has no exit code, so it is found by coming back). `(getline) > 0` is the fix,
# and the trailing-backslash-at-EOF Makefile is why it is load-bearing rather than defensive.
OBJS=$(awk '/^\$\(MODULE_NAME\)-objs[[:space:]]*:=/ {
             sub(/^[^=]*:=[[:space:]]*/, "", $0); printf "%s ", $0
             while ($0 ~ /\\$/ && (getline) > 0) printf "%s ", $0
           }' "$KMAKE" 2>/dev/null |
       tr -d '\\' | tr -s ' \t' ' ' | sed 's/ *$//')
say "   built from:    ${OBJS:-?}"
BUS_SPI=$(grep -cE '^[[:space:]]*#define[[:space:]]+USE_SPI_BUS' "$DRVDIR/gf_spi.h" 2>/dev/null)
BUS_PLT=$(grep -cE '^[[:space:]]*#define[[:space:]]+USE_PLATFORM_BUS' "$DRVDIR/gf_spi.h" 2>/dev/null)
if [ "${BUS_SPI:-0}" -gt 0 ] 2>/dev/null; then
  say "   bus branch:    USE_SPI_BUS -- the driver registers an spi_driver, so a probe must read"
  say "                  /sys/bus/spi/drivers/<name>, and the DT node must sit under an SPI controller"
elif [ "${BUS_PLT:-0}" -gt 0 ] 2>/dev/null; then
  say "   bus branch:    USE_PLATFORM_BUS -- a platform_driver, and the SPI controller is NOT in the path"
else
  say "   bus branch:    NEITHER macro is defined -- the driver would not compile at all (the file's"
  say "                  #if/#elif around the driver struct has no fallback)"
fi
MATCH=$(grep -oE '^#define[[:space:]]+GF_SPIDEV_NAME[[:space:]]+"[^"]+"' "$MAIN" 2>/dev/null |
        sed -n 's/.*"\(.*\)"/\1/p' | sed -n 1p)
DEVNAME=$(grep -oE '^#define[[:space:]]+GF_DEV_NAME[[:space:]]+"[^"]+"' "$MAIN" 2>/dev/null |
        sed -n 's/.*"\(.*\)"/\1/p' | sed -n 1p)
INNAME=$(grep -oE '^#define[[:space:]]+GF_INPUT_NAME[[:space:]]+"[^"]+"' "$MAIN" 2>/dev/null |
        sed -n 's/.*"\(.*\)"/\1/p' | sed -n 1p)
say "   of_match_table: GF_SPIDEV_NAME = '${MATCH:-(not found)}'"
say "   driver .name:   '${DEVNAME:-(not found)}'   input device name: '${INNAME:-(not found)}'"
MATCH_OK=0
[ -n "$MATCH" ] && [ "$MATCH" = "$COMPAT" ] && MATCH_OK=1

# ==================================================================================================
# 4. What the DRIVER asks the device tree for, read out of the driver's own source.
#    This list is the instrument's spine: a probe that reads a hand-written list of properties is
#    reading a document. The two call shapes below are the only two ways this driver takes something
#    from the tree, and the second one's NAME is the property with `-supply` appended (regulator_get
#    resolves `<name>-supply`), which is a fact about the regulator core rather than about this driver.
# ==================================================================================================
head_ "== 4. what the driver ASKS THE TREE FOR (read out of its own source, not out of a document) =="
# **A property named inside `#if 0` is NOT required**, and getting this wrong is not a cosmetic error:
# `platform.c` asks for `goodix,gpio_pwr` inside an `#if 0` block, so a plain grep reports it as
# required -- and NO tree on this board has it, so every tree would be reported incomplete and the
# verdict would have been `node-missing-or-incomplete` about a tree that is fine. The preprocessor
# state is therefore reproduced (an `#if 0` opens a dead region, `#if`/`#ifdef` inside it nest, and
# `#endif` closes), and the same reader is used for both files so the two cannot disagree.
LIVE="$W/live.c"
strip_dead() { # file -> the file with `#if 0` regions removed
  awk '
    { line = $0 }
    /^[[:space:]]*#[[:space:]]*if[[:space:]]+0[[:space:]]*$/ { dead++; next }
    dead > 0 && /^[[:space:]]*#[[:space:]]*if/ { nest[dead]++; next }
    dead > 0 && /^[[:space:]]*#[[:space:]]*endif/ {
      if (nest[dead] > 0) { nest[dead]-- } else { dead-- }
      next
    }
    dead > 0 { next }
    { print line }
  ' "$1"
}
REQ=""
for f in "$MAIN" "$AUX"; do
  [ -r "$f" ] || continue
  strip_dead "$f" > "$LIVE"
  say "   $(printf '%-24s' "${f##*/}") $(wc -l < "$f" | tr -d ' ') lines, $(wc -l < "$LIVE" | tr -d ' ') of them live (the #if 0 regions above are not requirements)"
  for p in $(grep -oE 'of_get_named_gpio\([^,]+,[[:space:]]*"[^"]+"' "$LIVE" 2>/dev/null |
             sed -n 's/.*"\([^"]*\)"/\1/p' | sort -u); do
    REQ="$REQ $p"
  done
  for p in $(grep -oE 'regulator_get\([^,]+,[[:space:]]*"[^"]+"' "$LIVE" 2>/dev/null |
             sed -n 's/.*"\([^"]*\)"/\1/p' | sort -u); do
    REQ="$REQ ${p}-supply"
  done
done
REQ=$(printf '%s\n' $REQ | sort -u | tr '\n' ' ')
say "   required by the driver:${REQ:- (nothing -- it would bind on any node with the compatible)}"
# The one property the driver asks for that is NOT a gpio or a regulator, and the one that decides the
# input device's name rather than whether the probe survives. Listed separately so that a node missing
# one of THESE is not reported as a probe failure: the difference is the point.
say "   optional/extra in the tree: input-device-name (names the input device), spi-qup-id,"
say "   spi-max-frequency, pinctrl-names/pinctrl-N (the gpio states the pins are muxed to), gfvdda-supply"

# ==================================================================================================
# 5. The device tree the BUILD produced, per this phone's variants.
#    Every DTB whose `model` names LE_ZL1 is checked; a DTB that names the OTHER phone is reported and
#    not counted (the two boards' trees share one blob under a byte-identical root `compatible`, and
#    that mistake has been made here before). The SPI controller's own `status` is read as well: the
#    node's child cannot bind if its parent is disabled, and "no status property" means ENABLED in the
#    device tree -- so an absent property is a reading, not a gap.
# ==================================================================================================
head_ "== 5. the node, in every built tree that names THIS phone =="
DTBL="$W/dtbl.txt"
if [ ! -d "$DTBD" ]; then
  say "   $DTBD is not a directory -- THE NODE READING IS SKIPPED, which is NOT the same as 'the node is"
  say "   fine'. The verdict below says so."
  DTBL=""
else
  python3 - "$DTBD" "$NODEPATH" "$SPIPATH" "$COMPAT" "$REQ" > "$DTBL" 2>"$W/dtb.err" <<'PY'
import os, struct, sys, hashlib

dtbd, nodepath, spipath, compat, req = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
reqs = req.split()

def walk(data):
    """Return {(path, prop): bytes}. FDT_BEGIN_NODE carries its name INLINE; FDT_PROP is
    tag,len,nameoff then the value padded to 4 -- both were wrong in this project's first parser and
    both produced a plausible short tree, so both are written out here."""
    (magic, total, off_struct, off_strings, off_rsv, ver, lastc,
     bootcpu, size_strings, size_struct) = struct.unpack('>10I', data[:40])
    if magic != 0xd00dfeed:
        raise ValueError('bad magic %#x' % magic)
    end = off_struct + size_struct
    pos = off_struct
    path = []
    props = {}
    while pos < end:
        tok = struct.unpack('>I', data[pos:pos+4])[0]; pos += 4
        if tok == 1:
            e = data.index(b'\0', pos)
            path.append(data[pos:e].decode('utf-8', 'replace'))
            pos = (e + 1 + 3) & ~3
        elif tok == 2:
            if path: path.pop()
        elif tok == 3:
            ln, noff = struct.unpack('>II', data[pos:pos+8]); pos += 8
            val = data[pos:pos+ln]; pos = (pos + ln + 3) & ~3
            e = data.index(b'\0', off_strings + noff)
            props[('/'.join(path), data[off_strings+noff:e].decode('utf-8','replace'))] = val
        elif tok == 4:
            pass
        elif tok == 9:
            break
        else:
            raise ValueError('unknown FDT token %d at %d' % (tok, pos - 4))
    return props

n_zl1 = n_other = n_bad = 0
for f in sorted(os.listdir(dtbd)):
    if not f.endswith('.dtb'):
        continue
    raw = open(os.path.join(dtbd, f), 'rb').read()
    try:
        p = walk(raw)
    except Exception as e:
        # A .dtb that exists and cannot be read is a MISSING READING, and it must not be allowed to
        # read as "no tree names this phone": that sentence is a claim about the BOARD, and a file that
        # failed to parse is a claim about this instrument. It is counted here and turned into its own
        # rung below, because "there is no such tree" and "I could not read one" send an operator to
        # two different places.
        n_bad += 1
        print('DTB\t%s\tUNREADABLE\t%s' % (f, e))
        continue
    model = p.get(('', 'model'), b'').split(b'\0')[0].decode('utf-8', 'replace')
    h = hashlib.sha256(raw).hexdigest()[:16]
    if 'LE_ZL1' not in model:
        n_other += 1
        print('OTHER\t%s\t%s\t%s' % (f, model, h))
        continue
    n_zl1 += 1
    # the SPI controller the node hangs under: absent status == ENABLED, and that is stated, not assumed
    st = p.get((spipath, 'status'))
    status = 'absent (=enabled)' if st is None else st.split(b'\0')[0].decode('utf-8','replace')
    node = p.get((nodepath, 'compatible'))
    have = node.split(b'\0')[0].decode('utf-8','replace') if node is not None else '(absent)'
    miss = [r for r in reqs if (nodepath, r) not in p]
    print('ZL1\t%s\t%s\t%s\t%s\t%s\t%s' % (f, model, h, status, have, ','.join(miss) if miss else '-'))
print('COUNT\tzl1\t%d' % n_zl1)
print('COUNT\tother\t%d' % n_other)
print('COUNT\tunreadable\t%d' % n_bad)
PY
  if [ ! -s "$DTBL" ]; then
    say "   the FDT walk produced nothing: $(sed -n 1p "$W/dtb.err" 2>/dev/null)"
    say "   THE NODE READING DID NOT HAPPEN -- reported as such below, never as a pass."
    DTBL=""
  else
    grep '^ZL1' "$DTBL" | while IFS="$(printf '\t')" read -r _ f model h status have miss; do
      sayf '   %-42s %-34s sha=%s\n' "$f" "$model" "$h"
      sayf '     %-24s status: %s\n' "$SPIPATH" "$status"
      sayf '     %-24s compatible: %s   missing: %s\n' "$NODEPATH" "$have" "$miss"
    done
    grep '^OTHER' "$DTBL" | while IFS="$(printf '\t')" read -r _ f model h; do
      sayf '   (not this phone) %-28s %-30s sha=%s\n' "$f" "$model" "$h"
    done
    grep '^DTB	' "$DTBL" | while IFS="$(printf '\t')" read -r _ f why; do
      sayf '   UNREADABLE DTB: %s -- %s\n' "$f" "$why"
    done
    say "   $(grep -c '^ZL1' "$DTBL") tree(s) naming THIS phone, $(grep -c '^OTHER' "$DTBL") naming the other board"
  fi
fi

# ==================================================================================================
# 6. The trees APPENDED TO THE BOOT IMAGE, cross-checked against the built ones by sha256.
#    This is the reading that matters most and it is the one an instrument is most tempted to fake:
#    "the built DTB has the node" and "the DTB the phone BOOTS has the node" are two facts, and the
#    boot image is the one that runs. The append is walked separately (a DTB inside an image sits at a
#    file offset, and walking it as if the file began with it is the defect this project already
#    shipped once), and each appended tree is matched to a built `.dtb` by hash rather than by size.
# ==================================================================================================
head_ "== 6. the trees APPENDED TO THE BOOT IMAGE, and whether they are the ones just measured =="
if [ ! -r "$BOOT" ]; then
  say "   $BOOT is not readable: THE APPENDED TREES WERE NOT READ."
  say "   That is NOT 'the image is fine'. The verdict below says which reading is missing. To make it"
  say "   anyway, point --boot at an image, or --dtb-dir at the built output and read the caveat."
  APPDONE=0
else
  python3 - "$BOOT" "$DTBD" "$NODEPATH" "$COMPAT" > "$W/append.txt" 2>"$W/append.err" <<'PY'
import hashlib, os, struct, sys

boot, dtbd, nodepath, compat = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
data = open(boot, 'rb').read()

# The built .dtb hashes, so an appended tree is IDENTIFIED rather than assumed to be one of them.
built = {}
if os.path.isdir(dtbd):
    for f in sorted(os.listdir(dtbd)):
        if f.endswith('.dtb'):
            raw = open(os.path.join(dtbd, f), 'rb').read()
            built[hashlib.sha256(raw).hexdigest()] = f
            # An Android boot image appends a DTB that may carry a trailing padding, and this project has
            # recorded that the appended copy can differ by padding alone. Both the exact hash and the
            # longest common-prefix match are therefore computed and both are printed: a "differs" that
            # is 0 bytes of content is not the same finding as a tree that is another file.
            built['prefix:' + hashlib.sha256(raw).hexdigest()] = f

def walk(blob):
    """Walk a WHOLE FDT blob -- its own byte 0 is the magic. Slicing the blob out of the image FIRST is
    what makes this the same function for a file and for an append: an FDT's internal offsets are
    relative to its own start, and the first append in this image sits at 0xb4ae66, which is 2 mod 4."""
    (magic, total, off_struct, off_strings, off_rsv, ver, lastc,
     bootcpu, size_strings, size_struct) = struct.unpack('>10I', blob[:40])
    if magic != 0xd00dfeed:
        raise ValueError('bad magic %#x' % magic)
    # A SELF-CONSISTENCY CHECK, and it is not decoration: this image contains the byte sequence
    # d0 0d fe ed at offset 5 by coincidence, and without this the walker counts a boot-image header
    # field as a device tree that "could not be walked". Every real FDT satisfies the identity below
    # (the struct block and the strings block are adjacent and together make up the whole blob), so a
    # blob that fails it is not a tree and is not reported as one.
    if not (total >= 40 and off_struct >= 40
            and off_struct + size_struct == off_strings
            and off_strings + size_strings <= total):
        raise ValueError('not an FDT: the header does not describe a self-consistent blob')
    end = off_struct + size_struct
    pos = off_struct
    path = []
    props = {}
    while pos < end:
        tok = struct.unpack('>I', blob[pos:pos+4])[0]; pos += 4
        if tok == 1:
            e = blob.index(b'\0', pos)
            path.append(blob[pos:e].decode('utf-8', 'replace'))
            pos = (e + 1 + 3) & ~3
        elif tok == 2:
            if path: path.pop()
        elif tok == 3:
            ln, noff = struct.unpack('>II', blob[pos:pos+8]); pos += 8
            val = blob[pos:pos+ln]; pos = (pos + ln + 3) & ~3
            e = blob.index(b'\0', off_strings + noff)
            props[('/'.join(path), blob[off_strings+noff:e].decode('utf-8','replace'))] = val
        elif tok == 4:
            pass
        elif tok == 9:
            break
        else:
            raise ValueError('token %d' % tok)
    return props

found = 0
bad = 0
i = 0
while True:
    off = data.find(b'\xd0\x0d\xfe\xed', i)
    if off < 0:
        break
    i = off + 1
    try:
        total = struct.unpack('>I', data[off+4:off+8])[0]
        if total < 40 or off + total > len(data):
            continue
        blob = data[off:off+total]
        p = walk(blob)
        model = p.get(('', 'model'), b'').split(b'\0')[0].decode('utf-8', 'replace')
        if 'LE_ZL1' not in model and 'LE_X2' not in model:
            continue
    except Exception as e:
        # A magic that walks to a failure is COUNTED AND PRINTED, not swallowed: this walker's first
        # version failed on all five trees -- because it aligned an offset to 4 bytes in FILE
        # coordinates while an FDT's offsets are relative to its own blob, and the first append here
        # starts at 0xb4ae66 (2 mod 4) -- and `except: continue` turned a parser bug into "this image
        # contains no device trees". A reader that cannot say "I found something and could not read it"
        # is the defect, not the tree it failed on.
        bad += 1
        print('BAD\t0x%x\t%s' % (off, e))
        continue
    found += 1
    h = hashlib.sha256(blob).hexdigest()
    name = built.get(h, '')
    same = 'byte-identical to a built .dtb' if name else 'NOT byte-identical to any built .dtb'
    node = p.get((nodepath, 'compatible'))
    have = 'present' if node is not None else 'ABSENT'
    print('APP\t%d\t0x%x\t%d\t%s\t%s\t%s\t%s' % (found, off, total, model, h[:16], have, same))
print('COUNT\t%d' % found)
print('BADCOUNT\t%d' % bad)
PY
  if [ ! -s "$W/append.txt" ]; then
    say "   no tree could be walked inside $BOOT: $(sed -n 1p "$W/append.err" 2>/dev/null)"
    say "   THE APPENDED-TREE READING DID NOT HAPPEN -- reported as such below."
    APPDONE=0
  else
    grep '^APP' "$W/append.txt" | while IFS="$(printf '\t')" read -r _ n off size model h have same; do
      sayf '   #%-2s @%-10s %8s bytes  %-34s sha=%s\n' "$n" "$off" "$size" "$model" "$h"
      sayf '     %-24s %-8s   %s\n' "$NODEPATH" "$have" "$same"
    done
    APP_N=$(grep '^COUNT' "$W/append.txt" | sed -n 's/^COUNT\t//p')
    APP_BAD=$(grep '^BADCOUNT' "$W/append.txt" | sed -n 's/^BADCOUNT\t//p')
    # `^BAD<TAB>` and NOT `^BAD`: the count line is `BADCOUNT<TAB>0`, which starts with BAD, so the
    # broader pattern printed a phantom "MAGIC AT 0" from the summary line it was reading as a finding.
    grep '^BAD	' "$W/append.txt" | while IFS="$(printf '\t')" read -r _ off why; do
      sayf '   MAGIC AT %s THAT COULD NOT BE WALKED: %s\n' "$off" "$why"
    done
    say "   ${APP_N:-0} tree(s) walked inside the image, ${APP_BAD:-0} magic(s) that could not be walked"
    # **"I read the image and found no tree" is NOT the same reading as "the image has no tree in it."**
    # The only thing that turns this section into a reading is at least one tree actually walked; zero
    # is reported as a MISSING reading, which is what it is -- and the difference is not academic, it is
    # the exact confusion a parser bug produced here on the first run.
    if [ "${APP_N:-0}" = 0 ]; then
      say "   NO TREE INSIDE THE IMAGE COULD BE WALKED -- THE APPENDED-TREE READING DID NOT HAPPEN, and"
      say "   that is reported as a missing reading below rather than as an image without device trees."
      APPDONE=0
    else
      APPDONE=1
    fi
  fi
fi

# ==================================================================================================
# 7. Compile. The two translation units, with THE BUILD'S OWN COMMAND LINE.
#    The flags are recovered from the `.cmd` file kbuild leaves beside a sibling object in the same
#    directory -- so every -I, every -D and every warning flag is the one this kernel was compiled
#    with, and not a reconstruction. Reconstructing them is how a check passes on a host that would
#    never have built the real thing.
#
#    IF THEY CANNOT BE RECOVERED, OR THE TOOLCHAIN IS NOT HERE, THIS SECTION SAYS SO AND THE VERDICT
#    IS THE RUNG THAT MEANS "NOT VERIFIED" -- never the top one. "It should compile" is not a reading.
# ==================================================================================================
head_ "== 7. does it compile with THIS kernel's flags =="
CC="$TCBIN/real-$BIN-gcc"
LD="$TCBIN/${BIN}-ld"
NM="$TCBIN/${BIN}-nm"
CMD=""
for c in "$OBJ/drivers/input/.input.o.cmd" "$OBJ/drivers/input/.evdev.o.cmd"; do
  [ -r "$c" ] && CMD="$c" && break
done
if [ -z "$CMD" ]; then
  for c in $(find "$OBJ" -name '.*.o.cmd' 2>/dev/null | sort | sed -n '1,5p'); do
    [ -r "$c" ] && CMD="$c" && break
  done
fi
COMPILE="skipped"; COMPILE_WHY=""; UNRESOLVED=""
if [ ! -x "$CC" ]; then
  COMPILE_WHY="the cross compiler is not at $CC"
elif [ ! -x "$LD" ] || [ ! -x "$NM" ]; then
  COMPILE_WHY="the toolchain has no ld/nm beside the compiler at $TCBIN"
elif [ ! -r "$OBJ/vmlinux" ]; then
  COMPILE_WHY="$OBJ/vmlinux is not readable, so 'it links into THIS kernel' cannot be answered"
elif [ -z "$CMD" ]; then
  COMPILE_WHY="no sibling .o.cmd under $OBJ to recover this kernel's own command line from"
else
  say "   flags recovered from: $CMD"
  PYB="$W/flags.py"
  cat > "$PYB" <<'PY'
import re, sys
# **The literal double quotes must be REMOVED, and this is not cosmetics.** kbuild's recorded command
# line contains entries like `-D"KBUILD_STR(s)=#s"`: in a Makefile/recipe those quotes are SHELL quoting
# and the shell strips them before gcc sees the argument. Reproducing the line in a shell VARIABLE puts
# the quote characters INSIDE the value, so the shell no longer strips them, gcc receives
# `-D"KBUILD_STR(s)=#s"` and answers `error: macro names must be identifiers` -- a compile that fails
# for a reason that has nothing to do with the driver, which is the most dangerous kind of red. The
# extraction is therefore done with the same effect as the shell's: quotes removed.
line = [l for l in open(sys.argv[1]) if sys.argv[2] in l]
if not line:
    sys.exit(1)
line = line[0].rstrip('\n').split(':=', 1)[1].strip()
line = re.sub(r'^\S*gcc-wrapper\.py\s+', '', line)
line = re.sub(r'-Wp,-MD,\S+\s+', '-Wp,-MD,%s/${BASE}.d ' % sys.argv[3], line)
line = re.sub(r'\s-c\s+-o\s+\S+\s+\S+$', '', line)
i = line.index(sys.argv[2]) + len(sys.argv[2])
out = line[i:].strip().replace('"', '')
if out.count("'") % 2:
    sys.exit(1)
print(out)
PY
  FLAGS=$(python3 "$PYB" "$CMD" "$BIN-gcc" "$W") || FLAGS=""
  if [ -z "$FLAGS" ]; then
    COMPILE_WHY="the command line in $CMD could not be parsed"
  else
    COMPILE="ok"
    for f in gf_spi platform; do
      [ -r "$DRVDIR/$f.c" ] || { COMPILE="no-source"; COMPILE_WHY="$DRVDIR/$f.c is not readable"; break; }
      # The two -I entries kbuild adds for the directory being compiled are appended, because they are
      # what kbuild would pass and this driver includes its own header by name.
      OUT=$(cd "$OBJ" && PATH="$TCBIN:$PATH" "$CC" $FLAGS \
            -I"$DRVDIR" -I"drivers/input/goodixfp" -c "$DRVDIR/$f.c" -o "$W/$f.o" 2>&1)
      RC=$?
      if [ "$RC" = 0 ] && [ -s "$W/$f.o" ]; then
        say "   $f.c: rc=0, $(wc -c < "$W/$f.o" | tr -d ' ') bytes -> $W/$f.o"
      else
        COMPILE="failed"
        COMPILE_WHY="$f.c"
        say "   $f.c: rc=$RC -- IT DID NOT COMPILE. The first diagnostics:"
        printf '%s\n' "$OUT" | sed -n '1,8p' | sed 's/^/     | /'
        break
      fi
    done
  fi
fi
if [ "$COMPILE" = skipped ]; then
  say "   THE COMPILE WAS NOT ATTEMPTED: $COMPILE_WHY"
  say "   That is a MISSING READING, not a passing one -- the verdict below is the rung that says so."
fi

# ---- the link: it compiles AND it belongs to this kernel ------------------------------------------
if [ "$COMPILE" = ok ]; then
  head_ "== 8. does it LINK into the vmlinux that was built from this tree =="
  "$LD" -r -o "$W/gf.o" "$W/gf_spi.o" "$W/platform.o" 2>"$W/ld.err"
  if [ $? -ne 0 ]; then
    say "   ld -r FAILED: $(sed -n 1p "$W/ld.err")"
    COMPILE="failed"; COMPILE_WHY="the two objects do not combine (a source file is left out of the Makefile's objs list)"
  else
    say "   ld -r: $(wc -c < "$W/gf.o" | tr -d ' ') bytes of combined object"
    "$NM" -u "$W/gf.o" 2>/dev/null | awk '{print $2}' | sort -u > "$W/undef.txt"
    "$NM" --defined-only "$OBJ/vmlinux" 2>/dev/null | awk '{print $3}' | sort -u > "$W/defined.txt"
    UNRESOLVED=$(comm -23 "$W/undef.txt" "$W/defined.txt" | tr '\n' ' ')
    say "   undefined symbols in the driver: $(wc -l < "$W/undef.txt" | tr -d ' ')"
    say "   symbols DEFINED in the built vmlinux: $(wc -l < "$W/defined.txt" | tr -d ' ')"
    if [ -z "$UNRESOLVED" ]; then
      say "   every one of them resolves against this kernel's own vmlinux"
    else
      say "   UNRESOLVED: $UNRESOLVED"
    fi
  fi
fi

# ==================================================================================================
# 9. The verdict. First failed rung wins, and the order is the order in which a link can be missing:
#    from "the option cannot even be turned on" to "everything is in place".
# ==================================================================================================
head_ "== verdict =="
ZL1_N=0; GX_OK=0; GX_BAD=0; MISS_MERGED=""; DTB_BAD=0
if [ -n "$DTBL" ]; then
  ZL1_N=$(grep -c '^ZL1' "$DTBL")
  DTB_BAD=$(grep '^COUNT	unreadable' "$DTBL" | sed -n 's/^COUNT\tunreadable\t//p')
  DTB_BAD=${DTB_BAD:-0}
  while IFS="$(printf '\t')" read -r _ f model h status have miss; do
    if [ "$have" = "$COMPAT" ] && [ "$miss" = "-" ]; then GX_OK=$((GX_OK + 1)); else
      GX_BAD=$((GX_BAD + 1)); MISS_MERGED="$MISS_MERGED $f($have;missing:$miss)"
    fi
    case "$status" in disabled*) GX_BAD=$((GX_BAD + 1)); MISS_MERGED="$MISS_MERGED $f(spi-disabled)" ;; esac
  done <<EOF
$(grep '^ZL1' "$DTBL")
EOF
fi

if [ ! -r "$MAIN" ]; then
  V=driver-source-missing
  VMSG="the option's source is not in this tree: $MAIN is not readable. Whatever builds the image builds it from somewhere else."
elif [ -n "$EMPTY" ]; then
  V=driver-source-missing
  VMSG="the option's source is here and EMPTY:$EMPTY. A zero-byte file cannot carry the driver, and reading its (absent) of_match_table as a mismatch would blame the compatible for a file nobody wrote."
elif [ -z "$want_ln" ]; then
  V=option-not-in-kconfig
  VMSG="'config ${OPT#CONFIG_}' is not defined anywhere in $KCONF -- the option this kernel would need does not exist in it."
elif [ -n "$DEP_BAD" ]; then
  V=dependency-off
  VMSG="the option is defined but cannot be turned on: its own 'depends on' is not satisfied by the BUILT config --$DEP_BAD. Editing the config line would be ignored by kbuild, which is the quiet failure this rung exists for."
elif [ "$MATCH_OK" != 1 ]; then
  V=match-table-differs
  VMSG="the driver's of_match_table carries '${MATCH:-nothing}' and the node's compatible is '$COMPAT'. Enabling the option would build a driver that matches this node NEVER, and the reading would look like 'the driver is in and the sensor still does not work'."
elif [ -z "$DTBL" ]; then
  V=node-reading-not-made
  VMSG="THE DEVICE TREE COULD NOT BE READ, so whether this phone's built trees carry the node is UNKNOWN. It is not 'fine': the whole question is whether the config line is the last link, and the node is the link before it."
elif [ "$ZL1_N" = 0 ] && [ "$DTB_BAD" = 0 ]; then
  V=no-tree-for-this-phone
  VMSG="no DTB in $DTBD names LE_ZL1 -- either the build produced none, or this instrument was pointed at another board's output. Nothing here is about this phone."
elif [ "$GX_BAD" != 0 ]; then
  V=node-missing-or-incomplete
  VMSG="this phone's trees do not all carry a usable node:$MISS_MERGED. The DTS is a link in this chain, so the config line is NOT the last one."
elif [ "$DTB_BAD" != 0 ]; then
  V=trees-partly-unreadable
  VMSG="$DTB_BAD .dtb file(s) under $DTBD exist and could not be parsed, so the node reading covers only the files that could be read. This rung exists because 'no tree here names this phone' and 'a tree here could not be read' send an operator to two different places, and only one of them is a claim about the board."
elif [ "$OPT_BUILT" != "NOT SET" ]; then
  V=already-in-the-kernel
  VMSG="the BUILT config reads $OPT = $OPT_BUILT, so the DISTANCE measured here is ZERO: this build directory produces a kernel that carries the driver. Two things follow, and only one of them can be true at once. (1) If the option was switched on ON PURPOSE (docs 159 turned it on with one defconfig line), then this rung is the expected answer and the open question has MOVED: a build directory is not an image, so read the image you are about to boot -- host/zl1-boot-image-kernel.sh reads the config out of the Image itself. (2) If it was NOT, then docs 157's reading of the RUNNING image said not set, and something is off between this build directory and that image -- say which before anything is built."
elif [ "$COMPILE" = skipped ]; then
  V=not-verified-whether-it-compiles
  VMSG="every STATIC link is in place, and the two links that need a toolchain were not checked: $COMPILE_WHY. A check that could not be made is not a pass, so this is NOT the top rung."
elif [ "$COMPILE" = failed ]; then
  V=driver-does-not-compile
  VMSG="$COMPILE_WHY did not survive this kernel's own compile flags, so enabling the option would break the build rather than add a driver."
elif [ -n "$UNRESOLVED" ]; then
  V=driver-has-unresolved-symbols
  VMSG="it compiles and does not belong to THIS kernel: $UNRESOLVED. The symbol(s) above are undefined in the built vmlinux, which means the source here is not the source that built this image."
else
  V=one-config-line-away
  VMSG="every link is measurable and present. The option is defined and its dependencies are satisfied by the built config ($(printf '%s' "$DEPS" | tr '|' ' ') = on); the driver is in this tree and its of_match_table carries '$COMPAT' exactly; $GX_OK of $ZL1_N trees naming this phone carry the node with every property the driver asks for and their SPI controller enabled; and the driver compiles with this kernel's own flags and links with no unresolved symbol. The one missing thing is the config line."
fi

printf '== verdict: %s\n' "$V"
printf '   %s\n' "$VMSG"
if [ "$APPDONE" != 1 ]; then
  printf '\n   ONE READING IS MISSING AND THE VERDICT DOES NOT COVER IT: the trees appended to %s were\n' "${BOOT##*/}"
  printf '   not read, so whether the DTB THE PHONE BOOTS carries the node is unknown. The built trees\n'
  printf '   above are the build output; the append is what runs. Point --boot at an image to close it.\n'
fi
printf '\n   WHAT THIS IS NOT: a statement that the sensor works. The trust store, the store directory\n'
printf '   (docs 126), the TZ application and the sensor itself are all above or below this line, and the\n'
printf '   fingerprint is still "measured offline only" until the device-side judgement runs.\n'
printf '\n   identity: this verdict is about the files hashed in section 1, and about no others.\n'
[ "$KEEP" = 1 ] && echo "kept: $W"
[ "$V" = one-config-line-away ] && exit 0
exit 0
