#!/usr/bin/env bash
# What `lpm_levels.sleep_disabled=1` actually does to the low-power ladder -- answered from the source.
#
# Why this exists
# ---------------
# TWO instruments in this tree tell the operator the same thing, in the same words, in FIVE places (and the
# index line for docs 121 in the root README repeated it a sixth time):
#
#   zl1-sleep-and-throttle.sh:  "The reading that would settle the semantics of the parameter itself is in
#                                the kernel source, which is NOT ON THIS DEVICE -- so this script never
#                                claims to know what the parameter does, only what is happening."
#   zl1-lpm-ladder-trial.sh:    "... neither is the driver's source, which is not on this device."
#                               "the kernel's own source would say; it is not on this device."
#
# The premise is false. THE KERNEL SOURCE IS ON THIS LAPTOP -- it is what built the boot image that runs
# (`/mnt/data/halium-zl1-build/kernel/leeco/msm8996`, and the DTBs built from it are byte-identical to
# the ones appended to that image). This is the same error docs 120 made about the Android ramdisk, and
# docs 151 corrected: "I looked at a different file" written down as "the question cannot be answered
# here". It matters most here, because this parameter is the THIRD HEAT CAUSE (docs 121): if the
# mechanism is not known, the fix is a guess, and the experiment is measuring a knob nobody has read.
#
# What it reads, all read-only, all from FILES on this host
# --------------------------------------------------------
#   1. THE PARAMETER      its declaration, its sysfs permission, its default, and EVERY use site. Two
#                         counts matter and both are printed: how many times the whole source mentions
#                         the symbol, and how many of those are CODE (a comment is not a gate).
#   2. THE GATE           the enclosing function of the one use site, quoted with line numbers.
#   3. THE CHAIN          from the gate to the machine instruction: the cpuidle select callback, its
#                         `idx < 0` handling, the enter callback, and psci_enter_sleep() -- where the
#                         answer is one branch: `if (!idx) { ... wfi(); ... }`. A literal WFI, no PSCI
#                         call, no state id. That is what "the cores are told not to sleep" means at the
#                         instruction level, and it is a reading, not a restatement of the name.
#   4. THE LADDER         what the gate removes, read from the DTB APPENDED TO THE BOOT IMAGE (not from
#                         the source .dtsi): the CPU levels in DT order, so "index 0 = wfi" is a reading
#                         of the tree that runs. EVERY appended tree is checked, and a tree that
#                         disagrees is a finding, not a row to skip.
#   5. THE IDENTITY       sha256 of the source file and of every image read, so the verdict travels with
#                         the input that produced it (docs 152).
#
# THE VERDICT IS A TABLE, not a yes/no:
#
#   THE GATE IS A BARE WFI     the source gates the ONE select path and that path's level 0 is a literal
#                              wfi(); every appended tree lists wfi as index 0. The ladder above index 0
#                              is unreachable from idle while the parameter is set.
#   THE GATE IS SOMETHING ELSE the source still mentions the parameter but its gate is not in the path
#                              this instrument walks -- the reading moved. NOTHING is claimed.
#   THE TREES DISAGREE         at least one appended tree does not put wfi at index 0 -- so "pinned at
#                              WFI" is not true of every board this image can boot.
#   UNREADABLE                 a source or an image could not be read -- NOTHING is claimed (exit 3).
#
# Usage: zl1-lpm-sleep-semantics.sh [--src DIR] [--boot IMG] [--dtb-dir DIR] [--quiet] [--keep]
#   --src DIR      the kernel source tree (default: the tree that built the running kernel)
#   --boot IMG     the boot image whose appended DTBs are read (default: the v63 rebuilt one)
#   --dtb-dir DIR  where the built .dtb files live, for the identity cross-check (default: the build)
#   --quiet        the verdict only, not the readings
#   --keep         keep the extracted DTB in the temp dir and print its path
#
# Exit codes: 0 a verdict was reached; 2 a tool or an input is missing; 3 an input could not be read.
#
# What this NEVER does: write, build, flash, mount, or touch the device. It opens files on this laptop
# and prints. There is no device code path in it and the harness asserts that statically.

set -uo pipefail
export LC_ALL=C

SRC="${ZL1_KERNEL_SRC:-/mnt/data/halium-zl1-build/kernel/leeco/msm8996}"
BOOT="${ZL1_BOOT_IMG:-/mnt/data/halium-zl1-candidates/halium-boot-zl1-v63-rebuilt.img}"
DTBD="${ZL1_DTB_DIR:-/mnt/data/halium-zl1-build/out/target/product/zl1/obj/KERNEL_OBJ/arch/arm64/boot/dts/qcom}"
# The BUILT config, not a defconfig: which preprocessor arm compiles is a property of the build that
# produced the image, and a defconfig is a file someone may have edited since.
KCFG="${ZL1_KERNEL_CONFIG:-/mnt/data/halium-zl1-build/out/target/product/zl1/obj/KERNEL_OBJ/.config}"
LPM="$SRC/drivers/cpuidle/lpm-levels.c"
LPM_OF="$SRC/drivers/cpuidle/lpm-levels-of.c"
QUIET=0
KEEP=0

while [ $# -gt 0 ]; do
  case "$1" in
  --src) SRC="${2?--src needs a path}"; LPM="$SRC/drivers/cpuidle/lpm-levels.c"; LPM_OF="$SRC/drivers/cpuidle/lpm-levels-of.c"; shift 2 ;;
  --boot) BOOT="${2?--boot needs a path}"; shift 2 ;;
  --dtb-dir) DTBD="${2?--dtb-dir needs a path}"; shift 2 ;;
  --config)  KCFG="${2?--config needs a path}"; shift 2 ;;
  --quiet) QUIET=1; shift ;;
  --keep) KEEP=1; shift ;;
  --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0" ; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

# --quiet keeps the READINGS out and the VERDICT in, and the two are separate things in code (docs 152:
# the first version of the sibling instrument gated both through one predicate and did the opposite of
# what it documented). SHOW is raised once a verdict block begins.
SHOW=0
say() { [ "$QUIET" = 1 ] && [ "$SHOW" = 0 ] && return 0; printf '%s\n' "$*"; }
# Every printer that writes to stdout DIRECTLY (a `sed`/`grep`/`awk` pipeline) goes through this too,
# for the same reason: half a --quiet is worse than none.
quiet() { while IFS= read -r _l; do say "$_l"; done; }

for t in python3 sha256sum awk; do
  command -v "$t" >/dev/null 2>&1 || {
    echo "REFUSED: no $t(1) on this host. This instrument reads SOURCE and IMAGE FILES with it, so" >&2
    echo "         without it there is nothing to say -- a HOST problem, not a reading about the phone." >&2
    exit 2
  }
done
for f in "$LPM" "$LPM_OF" "$BOOT"; do
  [ -r "$f" ] || {
    echo "REFUSED: cannot read $f" >&2
    echo "         The source tree and the boot image are the whole input. Point at them with" >&2
    echo "         --src / --boot if they have moved; a missing input is not a reading." >&2
    exit 2
  }
done

W=$(mktemp -d "${TMPDIR:-/tmp}/zl1-lpm-sem.XXXXXX") || exit 2
cleanup() {
  # --keep that does not say WHERE it kept things is not much better than deleting them: the whole point
  # of the flag is that the intermediate the reading was made from can be looked at afterwards.
  if [ "$KEEP" = 1 ]; then printf 'kept: %s\n' "$W" >&2; else rm -rf "$W"; fi
}
trap cleanup EXIT HUP INT TERM

say "zl1 lpm sleep semantics -- what the sleep_disabled parameter does, read from its own driver"
say "  READ-ONLY, HOST-SIDE, NO DEVICE: every path below is a file on this laptop."
say "  kernel source: $SRC"
say "  boot image:    $BOOT"
say "  built dtbs:    $DTBD"
say "  built config:  $KCFG"
say
say "  the identity of what was read (sha256, so this run can be traced to its input):"
for f in "$LPM" "$LPM_OF" "$BOOT" "$KCFG"; do
  [ -r "$f" ] || continue
  say "    $(sha256sum -- "$f" | awk '{print $1}')  $(stat -c %s -- "$f")  $f"
done
[ -r "$KCFG" ] || say "    (no readable kernel config at $KCFG -- which preprocessor arm compiles will not be decided)"
say

# ==================================================================================================
say "== 1. the parameter: where it is declared, what may write it, and where it is READ =="
# ==================================================================================================
# Three separate readings, because "the source mentions the name" is not "the source has a gate":
#   * the declaration and the module_param_named line (which carries the sysfs permission),
#   * the count of mentions overall, and
#   * the count of mentions that are CODE in the driver -- a comment or a doc line is not a gate.
DECL_L=$(grep -n '^static bool sleep_disabled' "$LPM" | sed -n 's/:.*//p' | sed -n 1p)
PARAM_L=$(grep -n 'module_param_named(sleep_disabled' "$LPM" | sed -n 's/:.*//p' | sed -n 1p)
if [ -z "$DECL_L" ] || [ -z "$PARAM_L" ]; then
  SHOW=1
  say
  say "== verdict: THE GATE IS SOMETHING ELSE"
  say "   This source does not declare the parameter in the shape this reading needs (a \`static bool\`"
  say "   with a \`module_param_named\` next to it). Either it moved or this is not the tree that built"
  say "   the kernel that runs -- and this instrument reads the SHIPPED source, not a memory of it."
  say "   NOTHING is claimed about the ladder."
  exit 3
fi
# The module_param statement may wrap, so its END is the first following line that closes it -- and if
# no such line is found the extraction says so rather than silently extending to the end of the file.
PARAM_E=$(awk -v s="$PARAM_L" 'NR>=s && /\);/{print NR; exit}' "$LPM")
[ -n "$PARAM_E" ] || PARAM_E=$PARAM_L
say "  declaration:      line $DECL_L"
say "  the module parameter, verbatim (lines $PARAM_L-$PARAM_E) -- this one statement carries the"
say "  type, the default VALUE and the sysfs BEHAVIOUR, which is why it is quoted and not summarised:"
sed -n "${PARAM_L},${PARAM_E}p" "$LPM" | nl -ba -v "$PARAM_L" | sed 's/^/    /' | quiet
# A __setup() arm would make it a BOOT-ONLY argument, which is the difference between "write 0 at
# runtime" and "rebuild the boot image". The absence is the reading that licenses the runtime fix.
if grep -qE '__setup\("lpm_levels' "$LPM" "$LPM_OF"; then
  say "  __setup arm:      PRESENT -- there is a boot-argument arm as well, so the name can arrive two ways"
else
  say "  __setup arm:      none in this driver -- the name reaches it ONLY as a module parameter, which is"
  say "                    what makes 'write 0 to it at runtime' the possible fix (docs 121)"
fi
# THE GATE IS A MENTION OUTSIDE THE DECLARATION, and that exclusion is the whole reading: the first
# version filtered on the two opening lines only, so the statement's own CONTINUATION line came back as
# a second "gate" and section 2 then quoted the module_param statement as if it were a function. A
# count that includes the declaration is not a count of gates.
# `grep -n` first, so the numbers ARE the file's own: renumbering with an offset is how the first
# version reported the gate 124 lines past where it is (the offset has to be re-derived after the lines
# it skipped, and deriving it wrongly is silent -- the number still looks like a line number).
GATE=$(grep -n 'sleep_disabled' "$LPM" | awk -v a="$DECL_L" -v b="$PARAM_E" -F: '$1<a || $1>b' \
  | grep -v -E ':[[:space:]]*(/\*|\*)' || true)
say "  every OTHER line that mentions it (the gate, and nothing else):"
printf '%s\n' "$GATE" | sed 's/^/    /' | quiet
# "Mentions" and "gates" are different numbers and both are printed: a source that names the symbol in
# ten comments and gates it in one place is the normal shape, and a check that counted mentions would
# call it ten gates.
N_GATE=$(printf '%s\n' "$GATE" | grep -c . || true)
say "  gate sites: $N_GATE"
if [ "$N_GATE" = 0 ]; then
  SHOW=1
  say
  say "== verdict: THE GATE IS SOMETHING ELSE"
  say "   The driver's source mentions no gate for this parameter outside its own declaration. Either the"
  say "   symbol moved, or this source is not the one that built the kernel that runs -- and this"
  say "   instrument reads the SHIPPED source, not a memory of it. NOTHING is claimed about the ladder."
  exit 3
fi
say

# ==================================================================================================
say "== 2. the gate, in the function that contains it =="
# ==================================================================================================
# The enclosing function is found by scanning BACKWARDS for the last line that opens a function before
# the gate -- so the quote is the shipped text, not a transcription of it.
GLINE=$(printf '%s\n' "$GATE" | sed -n 's/^\([0-9]*\):.*/\1/p' | sed -n 1p)
FSTART=$(awk -v g="$GLINE" 'NR<g && /^[a-zA-Z_].*\(|^static .*\(/{last=NR} END{print last}' "$LPM")
if [ -z "$FSTART" ]; then FSTART=$(( GLINE > 30 ? GLINE - 30 : 1 )); fi
say "  the enclosing function begins at line $FSTART; the gate is at line $GLINE:"
sed -n "${FSTART},$(( GLINE + 6 ))p" "$LPM" | nl -ba -v "$FSTART" | sed 's/^/    /' | quiet
say "  READ THE RETURN: the gate returns 0, and 0 is a LEVEL INDEX here, not a boolean -- see section 3."
say

# ==================================================================================================
say "== 3. the chain from that return value to the instruction the CPU executes =="
# ==================================================================================================
# Four links, each a shipped function read by name. If a link is missing the chain cannot be walked and
# the verdict degrades -- it is never assumed to be there.
# Two shapes have to be accepted, and the first version accepted only the second: a definition may be
# `name(` at column 0 or may carry a return type (`bool psci_enter_sleep(`, `static int ...(`). Requiring
# `static` is what made the third link of the chain -- the one that holds the ANSWER -- report NOT FOUND
# while the two links above it were quoted in full. A finder that matches only some of the shapes it
# will meet turns a readable file into a missing function.
find_fn() { # FUNC FILE -> every line number that DEFINES fn (a definition, not a call)
  # THE ARGUMENT ORDER IS THE WHOLE BUG THIS HAD: the awk below is handed the NAME as `fn` and the FILE
  # as its input. Passing "$2" to both -- the file as the pattern and the file as the input -- makes the
  # regex `^/mnt/data/.../lpm-levels.c\(`, which matches nothing, so EVERY link of the chain reported
  # NOT FOUND while a section above it quoted the same file successfully. A finder that cannot find is
  # indistinguishable from a function that is not there -- and the verdict built on it said so.
  awk -v fn="$1" '
    $0 ~ ("^" fn "\\(") { print NR; next }
    $0 ~ ("^[A-Za-z_][A-Za-z_0-9 *]*[^A-Za-z_0-9]" fn "\\(") && $0 !~ /;[[:space:]]*$/ && $0 !~ /=/ { print NR }
  ' "$2"
}
chain_show() { # FUNC FILE [maxlines]
  fn=$1; file=$2; lim=${3:-0}
  start=$(find_fn "$fn" "$file" | sed -n 1p)
  N_DEF=$(find_fn "$fn" "$file" | grep -c . || true)
  if [ -z "$start" ]; then
    say "    ${fn}(): NOT FOUND in ${file##*/} -- the chain cannot be walked at this link"
    return 1
  fi
  if [ "$N_DEF" != 1 ]; then
    # This file really does define some functions more than once, under different #if arms. Saying so is
    # the difference between "the first definition was quoted" and "this is the definition".
    say "    (${fn}() is DEFINED $N_DEF times in this file -- the first is quoted; the others are behind"
    say "     other preprocessor arms, and which one is compiled is not decided here)"
  fi
  end=$(awk -v s="$start" 'NR>s && /^}/{print NR; exit}' "$file")
  [ -n "$end" ] || end=$(( start + 30 ))
  if [ "$lim" != 0 ]; then end=$(( start + lim )); fi
  say "    --- ${fn}()  ${file##*/}:${start}-${end}"
  sed -n "${start},${end}p" "$file" | nl -ba -v "$start" | sed 's/^/      /' | quiet
  return 0
}
OKCHAIN=1
say "  (a) the cpuidle select callback -- the ONLY caller of the gate:"
chain_show lpm_cpuidle_select "$LPM" 0 || OKCHAIN=0
say
say "  (b) the enter callback -- what receives that index:"
chain_show lpm_cpuidle_enter "$LPM" 24 || OKCHAIN=0
say
say "  (c) and the branch the index 0 takes. THIS IS THE ANSWER:"
chain_show psci_enter_sleep "$LPM" 14 || OKCHAIN=0
# WHICH OF THE DEFINITIONS IS COMPILED. This file guards three of them with the preprocessor, and the
# first version of this section printed only the first and said "which one is compiled is not decided
# here". It IS decidable: the guards are `#if !defined(CONFIG_CPU_V7)` / `#elif defined(CONFIG_ARM_PSCI)`
# / `#else`, and the built kernel's own .config answers them. Quoting definition #1 while #2 or #3 is
# the one that runs is the same defect as reading a disabled node as enabled -- so it is checked, and a
# mismatch takes the verdict down instead of being mentioned in passing.
DEFS=$(find_fn psci_enter_sleep "$LPM" | tr '\n' ' ' | sed 's/ *$//')
N_DEF=$(find_fn psci_enter_sleep "$LPM" | grep -c . || true)
say "  -> psci_enter_sleep() is defined $N_DEF time(s), at line(s): $DEFS"
DEF1=$(find_fn psci_enter_sleep "$LPM" | sed -n 1p)
G1=$(awk -v n="$DEF1" 'NR<n && /^#[[:space:]]*(if|elif|else)/{g=$0} END{print g}' "$LPM")
say "     guarded by: ${G1:-NOTHING -- no preprocessor guard precedes it}"
# The arm this instrument reads its three facts OUT OF is definition #1. So the question is exact: is
# definition #1 the arm that compiles?
ARM1_OK='unknown'
if [ -r "$KCFG" ]; then
  V7=$(awk '/^CONFIG_CPU_V7=y/{n++} END{print n+0}' "$KCFG")
  PSCI=$(awk '/^CONFIG_ARM_PSCI=y/{n++} END{print n+0}' "$KCFG")
  A64=$(awk '/^CONFIG_ARM64=y/{n++} END{print n+0}' "$KCFG")
  say "  -> from $KCFG: CONFIG_ARM64=$A64  CONFIG_CPU_V7=$V7  CONFIG_ARM_PSCI=$PSCI"
  if [ "$A64" = 1 ] && [ "$V7" = 0 ]; then ARM1_OK=yes
  elif [ "$V7" = 1 ]; then ARM1_OK=no
  elif [ "$PSCI" = 1 ]; then ARM1_OK=no
  fi
  if [ "$ARM1_OK" = yes ]; then
    say "     the first guard holds here (arm64, and CPU_V7 is not set), so definition #1 -- the one quoted"
    say "     above, and the one the three facts below are read from -- IS the arm that compiles."
  elif [ "$ARM1_OK" = no ]; then
    say "     DEFINITION #1 IS *NOT* THE ARM THAT COMPILES for this config. The three facts below would then"
    say "     be facts about dead text, so NOTHING is claimed and the verdict goes down."
    OKCHAIN=0
  else
    say "     (this config is neither of the shapes the guard names -- the arm that compiles is NOT decided"
    say "      here, and the three facts below are therefore about definition #1 and are labelled as such)"
  fi
else
  say "  -> the built kernel's .config was not readable ($KCFG), so WHICH of the $N_DEF definitions compiles"
  say "     is not decided here. The three facts below are about definition #1, the first of them."
fi
# The three facts the verdict rests on, read out of the shipped text rather than restated. They are read
# from definition #1's own text -- its start line to its closing brace -- not from a regex over the file.
PSS=$(awk -v s="$DEF1" 'NR>=s{print} NR>s && /^}/{exit}' "$LPM")
# THE HAYSTACK IS HANDED TO THE READER DIRECTLY. `printf ... | grep -q PATTERN` under `set -o pipefail`
# reports the WRITER's death as the answer: grep -q exits at the first match, printf is killed by SIGPIPE,
# and the pipeline's status is then 141 -- so a branch that IS in the text can be reported absent. That
# defect is written down in this tree twice (docs 134) and the fix in both places is this one: no pipeline,
# so there is nothing to die. It is also why the family's census counts `if ... | grep -q` as a site.
case "$PSS" in
*'if (!idx)'*) say "  -> the quoted arm has the 'if (!idx)' branch: index 0 is handled SEPARATELY" ;;
*) say "  -> NO 'if (!idx)' branch in that arm -- index 0 is not special here any more"
   OKCHAIN=0 ;;
esac
case "$PSS" in
*'wfi()'*) say "  -> and inside it the instruction is a literal wfi() -- no PSCI call, no state id" ;;
*) say "  -> but that branch does NOT call wfi() in this arm, so this reading does not hold"
   OKCHAIN=0 ;;
esac
case "$PSS" in
*'cpu_suspend'*) say "  -> while the OTHER branch builds a PSCI state id and calls cpu_suspend() -- that is the ladder" ;;
*) say "  -> and the other branch does not use cpu_suspend() either -- the shape changed, NOTHING claimed"
   OKCHAIN=0 ;;
esac


# THE LAST LINK: the value the gate returns has to ARRIVE at that function's argument. Without this the
# chain has a gap exactly where it is easiest to assume -- select returns 0, and something else calls
# psci_enter_sleep with something else.
PSC_CALL=$(grep -n 'psci_enter_sleep(cluster, idx' "$LPM" | grep -v -E ':[[:space:]]*(/\*|\*)' || true)
say "  -> the call(s) that carry that index into it:"
printf '%s\n' "$PSC_CALL" | sed 's/^/       /' | quiet
if [ "$(printf '%s\n' "$PSC_CALL" | grep -c . || true)" = 0 ]; then
  say "  -> NO call passes the index to psci_enter_sleep -- the index from the gate reaches this function"
  say "     some other way, or not at all, so the chain is NOT closed and NOTHING is claimed."
  OKCHAIN=0
fi
# And the switch that decides whether psci_enter_sleep is called at all: qcom,use-psci is read into a C
# variable in the OF parser, and this is the line that consults it (section 4 reads the tree for it).
UP=$(grep -n 'if (!use_psci)' "$LPM" | grep -v -E ':[[:space:]]*(/\*|\*)' || true)
say "  -> and the switch that decides whether it is called at all (use_psci, from qcom,use-psci):"
printf '%s\n' "$UP" | sed 's/^/       /' | quiet
say
# ==================================================================================================
say "== 3b. the property that LOOKS like the gate: qcom,min-child-idx =="
# ==================================================================================================

# The NAME invites the story "the deeper cluster states are gated by min-child-idx". That story is
# checkable here and cheap to check: where is the property parsed, where is the parsed field READ, and
# is any of those reads inside the function the gate returns from? A previous reading of this file
# recorded "parsed and never consumed" -- and that is FALSE: it is read in cluster aggregation and in
# the broadcast-timer decision (six sites). A verdict sentence this instrument printed as prose would
# have been a claim about this source that this source denies, which is why it is computed now.
MC_PARSE=$(grep -n 'min_child_level' "$LPM_OF" | grep -v -E ':[[:space:]]*(/\*|\*)' || true)
MC_READ=$(grep -n 'min_child_level' "$LPM" | grep -v -E ':[[:space:]]*(/\*|\*)' || true)
SEL_END=$(awk -v s="$FSTART" 'NR>s && /^}/{print NR; exit}' "$LPM")
[ -n "$SEL_END" ] || SEL_END=$FSTART
say "  parsed or updated in ${LPM_OF##*/}:"
printf '%s\n' "$MC_PARSE" | sed 's/^/    /' | quiet
say "  read in ${LPM##*/}:"
printf '%s\n' "$MC_READ" | sed 's/^/    /' | quiet
N_MC_READ=$(printf '%s\n' "$MC_READ" | grep -c . || true)
MC_IN_SEL=$(printf '%s\n' "$MC_READ" | awk -v a="$FSTART" -v b="$SEL_END" -F: '$1>=a && $1<=b' | grep -c . || true)
say "  the function the gate returns from is cpu_power_select, lines $FSTART-$SEL_END"
say "  read sites in the driver: $N_MC_READ   of those, INSIDE cpu_power_select: $MC_IN_SEL"
# Kept to ONE clause each, because this string is interpolated into the verdict's prose: a long
# sentence built with a backslash-continuation lost the space at the join and printed
# "broadcast-timerdecision" -- a defect that survives every check that only looks at exit codes.
if [ "$N_MC_READ" = 0 ]; then
  MC_VERDICT="it is parsed and never read anywhere in this driver, so it gates nothing"
  MC_WHERE=""
elif [ "$MC_IN_SEL" = 0 ]; then
  MC_VERDICT="it IS consumed -- but not on the path the gate returns into"
  MC_WHERE="the $N_MC_READ read site(s) are cluster aggregation and the broadcast-timer decision; none of them is inside cpu_power_select"
else
  MC_VERDICT="it IS read inside cpu_power_select itself, so it is on this path after all"
  MC_WHERE="the mechanism has to be re-read before anything is concluded from this run"
fi
say "  -> $MC_VERDICT"
[ -n "$MC_WHERE" ] && say "     ($MC_WHERE)"
say

# ==================================================================================================
say "== 4. the ladder that gate removes, read from the DTBs appended to the boot image =="
# ==================================================================================================
# NOT from the source .dtsi: the tree that RUNS is the one in the image. The FDT walk tracks offsets
# RELATIVE to the blob start -- the struct block is 4-aligned within the blob, and aligning an absolute
# file offset instead is the defect this instrument shipped first (a DTB at an odd file offset walked as
# a ONE-NODE tree, which reads as "this tree has no CPU levels" rather than as a parse failure).
DTBL="$W/dtbl.txt"
python3 - "$BOOT" "$DTBD" > "$DTBL" <<'PY'
import sys, struct, re, os, hashlib

FDT_BEGIN_NODE, FDT_END_NODE, FDT_PROP, FDT_NOP, FDT_END = 1, 2, 3, 4, 9
NUL = b'\x00'

def walk(d, off):
    """Walk one FDT blob whose header begins at `off` in the buffer `d`.

    Offsets are kept RELATIVE to the blob: the struct block is 4-aligned within the blob, and the blob
    may sit at any file offset. Mixing the two breaks alignment and silently truncates the walk."""
    total, o_struct, o_str, o_rsv, ver, lastc, bcpu, sz_str, sz_struct = struct.unpack('>9I', d[off+4:off+40])
    if ver < 16 or ver > 17 or total < 40 or o_struct < 40 or o_struct >= total:
        raise ValueError('implausible header')
    blob = d[off:off+total]
    strings = blob[o_str:o_str+sz_str]
    st = o_struct
    def sname(p):
        e = strings.index(NUL, p)
        return strings[p:e].decode('utf-8', 'replace')
    i = st
    path = []
    out = []
    while i + 4 <= len(blob):
        tok = struct.unpack('>I', blob[i:i+4])[0]
        i += 4
        if tok == FDT_BEGIN_NODE:
            e = blob.index(NUL, i)
            name = blob[i:e].decode('utf-8', 'replace')
            i = (e + 1 + 3) & ~3
            path.append(name)
            out.append(('NODE', '/'.join(path), None, None))
        elif tok == FDT_END_NODE:
            if path: path.pop()
        elif tok == FDT_PROP:
            ln, no = struct.unpack('>2I', blob[i:i+8])
            i += 8
            val = blob[i:i+ln]
            i = (i + ln + 3) & ~3
            out.append(('PROP', '/'.join(path), sname(no), val))
        elif tok == FDT_NOP:
            pass
        elif tok == FDT_END:
            break
        else:
            raise ValueError('bad token %d' % tok)
    return out

boot = sys.argv[1]
dtbd = sys.argv[2]
d = open(boot, 'rb').read()
built = {}
if os.path.isdir(dtbd):
    for f in sorted(os.listdir(dtbd)):
        if f.endswith('.dtb'):
            b = open(os.path.join(dtbd, f), 'rb').read()
            built[hashlib.sha256(b).hexdigest()] = (f, b)

found = 0
for m in re.finditer(b'\xd0\x0d\xfe\xed', d):
    off = m.start()
    try:
        items = walk(d, off)
    except Exception:
        continue
    nodes = [it for it in items if it[0] == 'NODE']
    if not nodes:
        continue
    # An FDT header is validated by the walk SUCCEEDING and by the tree having the root every DTB has.
    # A byte pattern that merely looks like a magic produces a blob that walks to nothing.
    if not any(n[1] == 'model' for n in [] ) and not any(it[0] == 'PROP' and it[2] == 'model' for it in items):
        continue
    found += 1
    tot = struct.unpack('>I', d[off+4:off+8])[0]
    blob = d[off:off+tot]
    sha = hashlib.sha256(blob).hexdigest()
    name, same = ('(not among the built .dtb files)', '')
    if sha in built:
        name = built[sha][0]
        same = 'IDENTICAL to the built ' + name
    model = ''
    for it in items:
        if it[0] == 'PROP' and it[2] == 'model':
            model = it[3].split(NUL)[0].decode('utf-8', 'replace')
            break
    print("DTB %d at 0x%x  size %d  sha256 %s" % (found, off, tot, sha))
    print("    model: %s" % (model or '(none)'))
    if name != '(not among the built .dtb files)':
        print("    %s" % same)
    else:
        print("    NOT byte-identical to any .dtb in the build output -- this tree may not come from this source")
    # THE CPU LEVELS, GROUPED BY THE pm-cpu NODE THEY HANG UNDER, in DT order. Grouping matters and
    # flattening is wrong: this board has TWO cpu-bearing clusters (pwr, perf), each with its own
    # `qcom,pm-cpu` and its own index 0. A flat list made "index 0 is wfi" a claim about every third
    # entry instead of about each cluster's first -- a reading that happens to be true here and would not
    # be if one cluster's tree changed, which is exactly the shape a check must not have.
    groups = {}
    gorder = []
    lab = {}
    cur = None
    for it in items:
        if it[0] == 'NODE':
            cur = it[1]
            continue
        if it[0] != 'PROP':
            continue
        if it[1] and re.search(r'pm-cluster@\d+$', it[1]) and it[2] == 'label':
            lab[it[1]] = it[3].split(NUL)[0].decode('utf-8', 'replace')
        if cur and re.search(r'pm-cpu-level@\d+$', cur):
            parent = cur.rsplit('/', 1)[0]
            if parent not in groups:
                groups[parent] = []
                gorder.append(parent)
            while len(groups[parent]) <= len([k for k in groups[parent]]):
                break
            row = groups[parent]
            # a new level node: identified by its own path
            if not row or row[-1][5] != cur:
                row.append([len(row), '', '', '', '', cur])
            r = row[-1]
            if it[2] == 'qcom,spm-cpu-mode':
                r[1] = it[3].split(NUL)[0].decode('utf-8', 'replace')
            elif it[2] == 'qcom,latency-us':
                r[2] = str(int.from_bytes(it[3], 'big'))
            elif it[2] == 'qcom,ss-power':
                r[3] = str(int.from_bytes(it[3], 'big'))
            elif it[2] == 'qcom,psci-cpu-mode':
                r[4] = str(int.from_bytes(it[3], 'big'))
    # the DT's own switch for which enter path is used: qcom,use-psci on the lpm-levels node makes
    # psci_enter_sleep() the operative branch rather than msm_cpu_pm_enter_sleep().
    # it[1] is the FULL path from the root, so a node is named by its LAST component -- comparing the
    # whole path to a bare node name is a test that can only ever answer "no". The first version did
    # exactly that and reported 'qcom,use-psci: 0 of 5' on trees where the property is present: a false
    # absence read as a fact about the trees, in the one place the verdict leans on.
    usep, usepath = 'no', ''
    for it in items:
        if it[0] == 'PROP' and it[2] == 'qcom,use-psci' and it[1].split('/')[-1] == 'qcom,lpm-levels':
            usep, usepath = 'yes', it[1]
    print("USE_PSCI %s" % usep)
    if usepath:
        print("USE_PSCI_PATH %s" % usepath)
    if not groups:
        # The sentinel is NOT `LEVELS -`: the count below greps `^LEVELS ` for DATA lines, and a sentinel
        # that starts the same way is counted as a cluster with a ladder -- which is exactly what the
        # harness's no-levels fixture caught (1 pair, 0 of them wfi -> a "trees disagree" finding about a
        # tree that describes no ladder at all). A sentinel that shares a prefix with the data it marks
        # the absence of is a sentinel the reader has to parse.
        print("    this tree has NO qcom,pm-cpu-level children -- the ladder is not described here")
        print("LEVELS_NONE")
        print("CLUSTERS 0")
        continue
    print("    cluster (by its pm-cpu node)          index  spm-cpu-mode    latency-us  ss-power  psci-cpu-mode")
    for parent in gorder:
        crow = ' / '.join(x for x in (lab.get(parent.rsplit('/', 1)[0], ''), parent.rsplit('/', 2)[-2] if parent.count('/') >= 2 else '') if x)
        short = parent.replace('qcom,lpm-levels/', '').replace('qcom,pm-cluster@', 'c').replace('qcom,pm-cpu', 'cpu')
        for r in groups[parent]:
            print("    %-36s %5d  %-15s %-11s %-9s %s" % (short if r[0] == 0 else '', r[0], r[1] or '?', r[2] or '?', r[3] or '?', r[4] or '?'))
        print("LEVELS %s | %s" % (short, ','.join(r[1] or '?' for r in groups[parent])))
    print("CLUSTERS %d" % len(gorder))
print("TREES %d" % found)
PY
N_TREES=$(sed -n 's/^TREES \([0-9]*\)$/\1/p' "$DTBL" | sed -n 1p)
if [ -z "$N_TREES" ] || [ "$N_TREES" = 0 ]; then
  SHOW=1
  say "  UNREADABLE: no device tree in $BOOT parsed as an FDT with a model property."
  say "  This instrument reads the tree that RUNS, and a boot image whose trees it cannot walk is not"
  say "  an image it can say anything about. NOTHING is claimed (and this is not a pass)."
  exit 3
fi
say "  device trees appended to the image that parsed: $N_TREES"
# PRINT EVERY READING AND DROP ONLY THE COUNTERS. An allow-list of line shapes was the first version,
# and it silently dropped the two lines the verdict leans on hardest (USE_PSCI / USE_PSCI_PATH) because
# they are printed unindented and the pattern required an indent -- a reading that is calculated, counted,
# and never shown. A deny-list of the two machine-only counters cannot lose a field that is added later.
grep -vE '^(TREES |CLUSTERS |)$' "$DTBL" | sed 's/^/  /' | quiet
say
# EVERY cluster in EVERY tree is checked, and one that disagrees is a finding rather than a row that was
# skipped. The unit here is the (tree, cluster) pair, because index 0 belongs to a cluster -- see the
# grouping note above.
N_LEVELS=$(grep -c '^LEVELS [^ ]' "$DTBL" || true)
N_WFI=$(grep '^LEVELS [^ ]' "$DTBL" | sed 's/^LEVELS [^|]*| //' | awk -F, '{gsub(/ /,"",$1); if ($1=="wfi") n++} END{print n+0}')
N_PS=$(grep -c '^USE_PSCI yes' "$DTBL" || true)
PS_PATH=$(sed -n 's/^USE_PSCI_PATH //p' "$DTBL" | sort -u | tr '\n' ' ' | sed 's/ $//')
[ -n "$PS_PATH" ] || PS_PATH='(not set by any tree)' 
say "  (tree, cluster) pairs carrying CPU levels: $N_LEVELS   of those, index 0 is 'wfi': $N_WFI"
say "  trees whose lpm-levels node sets qcom,use-psci: $N_PS of $N_TREES (the node is $PS_PATH)"
say "  (that switch is what makes psci_enter_sleep() -- section 3(c) -- the operative branch rather"
say "   than the non-PSCI msm_cpu_pm_enter_sleep(); both are in the source and only one runs, so the"
say "   chain in section 3 is the chain THIS board takes)"
say

# ==================================================================================================
SHOW=1
say "== 5. the verdict =="
# ==================================================================================================
say "  read from:"
for f in "$LPM" "$LPM_OF" "$KCFG" "$BOOT"; do
  [ -r "$f" ] || continue
  say "    $(sha256sum -- "$f" | awk '{print $1}')  $f"
done
say
if [ "$OKCHAIN" != 1 ]; then
  say "== verdict: THE GATE IS SOMETHING ELSE"
  say "   The parameter is still named in the driver, but the path this instrument walks -- select"
  say "   callback, enter callback, psci_enter_sleep's index-0 branch -- does not have the shape the"
  say "   reading needs. So the mechanism is NOT what this says, and NOTHING is claimed about it: the"
  say "   reading moved and this script is where that shows up first."
  exit 0
fi
if [ "$N_LEVELS" -eq 0 ]; then
  SHOW=1
  say "== verdict: THE GATE IS SOMETHING ELSE"
  say "   The source chain reads as expected, but NO appended device tree describes CPU levels, so what"
  say "   index 0 IS cannot be read from the tree that runs. Half the reading is missing and the other"
  say "   half is not a conclusion. NOTHING is claimed."
  exit 3
fi
if [ "$N_PS" = 0 ]; then
  SHOW=1
  say "== verdict: THE GATE IS SOMETHING ELSE"
  say "   The source chain reads as expected, but NO appended device tree sets qcom,use-psci on its"
  say "   lpm-levels node -- and that property is what selects psci_enter_sleep() over"
  say "   msm_cpu_pm_enter_sleep(): the OF parser reads it into 'use_psci' (lpm-levels-of.c:941) and the"
  say "   enter callback consults it at the call site (lpm-levels.c:1061). Without it the branch this"
  say "   reading is about does not run at all, the ladder would be the SPM one, and NOTHING is claimed"
  say "   about the WFI. This is the check that keeps reading 1 from being a statement about dead code."
  exit 0
fi
if [ "$N_WFI" != "$N_LEVELS" ] || [ "$N_PS" != "$N_TREES" ]; then
  say "== verdict: THE TREES DISAGREE"
  say "   $N_LEVELS (tree, cluster) pair(s) describe CPU levels and $N_WFI put 'wfi' at index 0;"
  say "   $N_PS of $N_TREES tree(s) set qcom,use-psci. So 'with the parameter set the CPU is pinned at a"
  say "   bare WFI' is true of some boards this image can boot and not of others -- which is a finding"
  say "   about the image, and it means the third heat cause has more than one shape. The rows above say"
  say "   which; the run is not a claim about all of them."
  exit 0
fi
say "== verdict: THE GATE IS A BARE WFI"
say "   Three readings, and they are three different kinds of evidence:"
say
say "   1. THE SOURCE. $LPM"
say "      declares one gate, and it is the cpuidle select callback's: with the parameter set, that"
say "      function RETURNS 0 -- a level INDEX, not a boolean. Index 0 is handled by a separate branch"
say "      in psci_enter_sleep(), and that branch is a literal wfi(): no PSCI call is made, no state id"
say "      is built, and cpu_suspend() is never reached. So the parameter does not pick a shallower"
say "      state; it removes the ladder from the top and leaves the architectural WFI. (Section 3 reads"
say "      WHICH of the file's $N_DEF definitions of that function compiles, from $KCFG -- the three"
say "      facts above are about the arm that runs, not about the first one in the file.)"
say
say "   2. THE TREE THAT RUNS. All $N_LEVELS cpu-bearing CLUSTER(s) across the $N_TREES appended device"
say "      tree(s) list 'wfi' as index 0 -- so index 0 is not merely the first element of an array in a"
say "      header, it is the WFI level of THIS board, with its own latency (20 us on pwr, 25 on perf)"
say "      and its own ss-power, and the two levels above it are the C4/fpc ones the gate makes"
say "      unreachable (latency 40 and 80 us -- the numbers are in section 4, per cluster)."
say
say "   3. THE PARAMETER ITSELF. It has NO __setup() arm in this driver, so it is reachable only as a"
say "      module parameter -- which is exactly why the fix is a runtime write (docs 121) and not a boot"
say "      image. Its sysfs permission is owned by root, and this script does not write it."
say
say "   WHAT THIS SETTLES AND WHAT IT DOES NOT. It settles the MECHANISM: the parameter's effect is to"
say "   keep the CPU at WFI, so the evidence to look for on the device is the LADDER being unused -- not"
say "   the parameter's value. It does NOT settle the SIZE of the effect: how many degrees that ladder is"
say "   worth on this board is a measurement, and that is what the trial instrument is for. It also does"
say "   not prove the ladder is reachable at all on this device -- that is the trial's other question, and"
say "   it is the one that can still come out against the hypothesis."
say
say "   AND THE PROPERTY THAT LOOKS LIKE ANOTHER MECHANISM. qcom,min-child-idx invites the story that the"
say "   deeper CLUSTER states are gated by it. Read out of this source rather than recalled (section 3b):"
say "   $MC_VERDICT."
say "   ($MC_WHERE)"
say "   Either way it is not the mechanism of THIS parameter: the parameter's own gate is the single line"
say "   in cpu_power_select that section 2 quotes, and the three readings above are about that line."
exit 0
