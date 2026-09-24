#!/usr/bin/env bash
# zl1 sdcard probe -- offline self-test. Host-side, touches no device, needs no phone.
#
# Why this exists. `scripts/device/zl1-sdcard-probe.sh` is the instrument for the `sdcard` row of doc 137's
# gap list, and the block behind that row is not one device: it is TWO controllers, and they are not the
# same kind of thing. /soc/sdhci@7464900 is `qcom,nonremovable` (the vendor's name for it is `sdhc1`) and
# /soc/sdhci@74A4900 carries `cd-gpios` -- a card-detect line -- and is therefore the REMOVABLE slot
# (`sdhc2`). Four readings make this probe's design, and each is a scenario below:
#
#   1. THE REMOVABLE SLOT IS SWITCHED OFF IN THE DEVICE TREE. On the zl1 it is `status = "disabled"`, in all
#      38 trees of the three sets, so the kernel creates no platform device for it at all. An EMPTY SLOT
#      and "a slot this kernel cannot drive" are the same reading, and the probe has to say which one it is
#      looking at rather than reporting a dead card reader.
#   2. THE SLOT INDEX COMES FROM THE ALIAS, AND THE mmcN NUMBER DOES NOT IDENTIFY THE CONTROLLER. The driver
#      reads its slot from the `sdhc` alias and refuses without one ("Failed to get slot index"), and mmc
#      core names a host from the lowest free id in an idr -- with PROBE_PREFER_ASYNCHRONOUS, so which
#      controller is `mmc0` is NOT decided by the device tree. So the fixtures give the card a number and a
#      PARENT that would disagree if the number were trusted, and the probe must read the parent.
#   3. `cd-gpios` IS THREE CELLS AND THE FIRST IS A PHANDLE. `<&tlmm 95 1>` is gpio 95 on whatever node
#      carries phandle 28, active low. Printing the number alone leaves the reader to guess the controller,
#      and reading the property as ONE u32 gives a plausible wrong number -- so the fixture writes the real
#      bytes and asserts both the resolution and the polarity.
#   4. IT WRITES NOTHING, AND THE OBVIOUS "TEST" IS A WRITE. `force_ro` on a block device, the driver's
#      `disable_slots` bitmask (0644, read once at probe time), or simply OPENING /dev/mmcblk0 -- and this
#      project does not open block devices on this phone. The static guard covers redirects and
#      state-changing commands, and the mutation that must redden it is the force_ro write.
#
# How it works: **the stub directory IS the device.** The probe runs as itself against a fake root, with the
# device's tools stubbed and PATH sandboxed to `$STUB:$MINBIN`, where MINBIN holds symlinks to the real
# coreutils. The rewrite covers `/proc/`, `/sys/` and `/dev/mmcblk` -- the last one because the probe NAMES
# block devices in its prose and its verdicts, and a rename that re-rooted only the two roots it reads today
# would leave a future `/dev/mmcblk0` read escaping to this laptop.
#
# Usage: zl1-sdcard-probe-selftest.sh [--keep]
#   --keep   leave the fake device, the stubs and the rewritten probe for inspection
#
# `ZL1_SDCARD_PROBE_SRC=/path` runs the whole thing against another copy of the subject, which is how a
# revision (or a mutation) is shown to fail.
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
SRC="${ZL1_SDCARD_PROBE_SRC:-$HERE/../device/zl1-sdcard-probe.sh}"
[ -r "$SRC" ] || { echo "cannot read the subject: $SRC" >&2; exit 2; }

W="${TMPDIR:-/tmp}/zl1-sdcard-probe-selftest"
# `root`, not `dev`: the fake root's path must not itself contain a path the rewriter hunts for, or the
# replacement text gets rewritten in turn (the trap its sibling harnesses record).
FR="$W/root"
STUB="$W/stub"
MINBIN="$W/minbin"
MINBIN_NOFIND="$W/minbin-nofind"
rm -rf "$W"
mkdir -p "$STUB" "$MINBIN" "$MINBIN_NOFIND" || exit 2

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
want() { if grep -Eq -- "$1" <<< "$2"; then ok "$3"; else bad "$3"; sed 's/^/        | /' <<< "$2"; fi; }
notwant() { if grep -Eq -- "$1" <<< "$2"; then bad "$3"; grep -E -- "$1" <<< "$2" | sed 's/^/        | /'; else ok "$3"; fi; }
wantf() { if grep -qF -- "$1" <<< "$2"; then ok "$3"; else bad "$3"; sed 's/^/        | /' <<< "$2"; fi; }
notwantf() { if grep -qF -- "$1" <<< "$2"; then bad "$3"; grep -F -- "$1" <<< "$2" | sed 's/^/        | /'; else ok "$3"; fi; }
# A check that passes for free on an empty string is not a check.
nonempty() { if [ -n "$2" ]; then ok "$1"; else bad "$1 -- the output was empty, so nothing below it can be trusted"; fi; }

# --- the sandbox PATH ------------------------------------------------------------------------------
# `type -P`, not `command -v`: in a shell whose profile has made one of these a function, `command -v`
# prints the NAME rather than a path and the symlink would point at itself.
for t in awk basename cat cut dirname find grep head od readlink sed sort tail tr uniq wc; do
  p="$(type -P "$t" 2>/dev/null)" || continue
  [ -n "$p" ] || continue
  ln -sf "$p" "$MINBIN/$t"
  [ "$t" = find ] || ln -sf "$p" "$MINBIN_NOFIND/$t"
done
# The probe reads a card's parent device with `readlink`; a sandbox without it would silently turn every
# parent into "(no device symlink)" and every scenario would still pass. So each tool the probe calls is
# required by name before anything runs.
for t in awk basename cat cut dirname grep head od readlink sed tail tr wc find; do
  [ -x "$MINBIN/$t" ] || { echo "the sandbox bin is missing $t -- cannot run the probe honestly" >&2; exit 2; }
done
# The second sandbox exists to make ONE state reachable: a device whose kernel has no find(1). Without it,
# "the tree could not be searched" is unreachable and the check that separates it from an absence tests
# nothing.
[ -e "$MINBIN_NOFIND/find" ] && { echo "the no-find sandbox has a find in it" >&2; exit 2; }
[ -x "$MINBIN_NOFIND/tr" ] || { echo "the no-find sandbox is not usable" >&2; exit 2; }
SH_BIN="$(type -P sh 2>/dev/null)"; [ -n "$SH_BIN" ] || SH_BIN=/bin/sh
[ -x "$SH_BIN" ] || { echo "no /bin/sh to run the probe with" >&2; exit 2; }

# --- the subject, rewritten into the fake device ---------------------------------------------------
#
# ONE PASS PER RULE and one file per pass, so each rule is counted where it ran. A single pass cascades:
# the `/sys/` inside `/proc/sys/kernel/random/boot_id` would be replaced by the `/proc/` rule and then the
# `/sys/` rule would hit the result. Pass 1 turns each root into a token that cannot itself be a device
# path; pass 2 expands the tokens, and nothing in a replacement can be re-matched by a rule that already
# ran.
#
# THREE RULES. `/proc/` carries the device tree, the cmdline, the partitions, the mounts and the uptime;
# `/sys/` carries the driver, its module parameters, the mmc_host class and the block devices; and
# `/dev/mmcblk` is here even though the probe only NAMES block devices today -- a rename that re-rooted
# only what the probe reads right now would leave a future `/dev/mmcblk0` read escaping to this laptop, and
# that is the defect this whole rewrite exists to prevent. `/dev/null` does not share the prefix.
cnt() { grep -o -- "$1" "$2" 2>/dev/null | wc -l | tr -d ' '; }
rewrite() { # $1 = source, $2 = output
  sed -e 's#/proc/#__ZP__#g' "$1" > "$W/pass1a.sh"
  sed -e 's#/sys/#__ZS__#g' "$W/pass1a.sh" > "$W/pass1b.sh"
  sed -e 's#/dev/mmcblk#__ZBM__#g' "$W/pass1b.sh" > "$W/pass1.sh"
  sed -e "s#__ZP__#$FR/proc/#g" -e "s#__ZS__#$FR/sys/#g" -e "s#__ZBM__#$FR/dev/mmcblk#g" \
    "$W/pass1.sh" > "$2"
}
RW="$W/sdcard-probe.sh"
sed -e 's#/proc/#__ZP__#g' "$SRC" > "$W/pass1a.sh"
[ "$(cnt '/proc/' "$SRC")" = "$(cnt '__ZP__' "$W/pass1a.sh")" ] \
  || { echo "the /proc/ rewrite did not cover every /proc/ in the source" >&2; exit 2; }
[ "$(cnt '/proc/' "$W/pass1a.sh")" = 0 ] || { echo "a /proc/ survived pass 1 -- the probe would read this host" >&2; exit 2; }
sed -e 's#/sys/#__ZS__#g' "$W/pass1a.sh" > "$W/pass1b.sh"
[ "$(cnt '/sys/' "$W/pass1a.sh")" = "$(cnt '__ZS__' "$W/pass1b.sh")" ] \
  || { echo "the /sys/ rewrite did not cover every /sys/ in the source" >&2; exit 2; }
[ "$(cnt '/sys/' "$W/pass1b.sh")" = 0 ] || { echo "a /sys/ survived pass 1" >&2; exit 2; }
sed -e 's#/dev/mmcblk#__ZBM__#g' "$W/pass1b.sh" > "$W/pass1.sh"
[ "$(cnt '/dev/mmcblk' "$W/pass1b.sh")" = "$(cnt '__ZBM__' "$W/pass1.sh")" ] \
  || { echo "the /dev/mmcblk rewrite did not cover every occurrence" >&2; exit 2; }
[ "$(cnt '/dev/mmcblk' "$W/pass1.sh")" = 0 ] || { echo "a /dev/mmcblk survived pass 1" >&2; exit 2; }
# `2>/dev/null` must stay behind untouched: rewriting it would make every quiet redirect try to create a
# file in the fake root, and the probe would fail in a way that looks like a scenario problem.
MUSTNULL=$(cnt '2>/dev/null' "$SRC")
[ "$MUSTNULL" = "$(cnt '2>/dev/null' "$W/pass1.sh")" ] \
  || { echo "the rewrite touched /dev/null -- the probe's quiet redirects would break" >&2; exit 2; }
rewrite "$SRC" "$RW"
sh -n "$RW" || { echo "the rewritten probe does not parse" >&2; exit 2; }
chmod +x "$RW"
if grep -q -- '__Z' "$RW"; then
  echo "an unexpanded token is left in $RW:" >&2; grep -n -- '__Z' "$RW" | sed -n '1,5p' >&2; exit 2
fi
# An invariant rather than a per-path tally: every token of pass 1 becomes exactly one fake-root path in
# pass 2, and nothing else may. A per-path count cannot see a MISSED path, and one missed path means the
# probe reads THIS machine while every scenario still passes.
TOK=$(cnt '__Z[A-Z]*__' "$W/pass1.sh"); FRS=$(cnt "$FR" "$RW")
[ "$TOK" -gt 0 ] || { echo "pass 1 produced no tokens -- the rewrite matched nothing" >&2; exit 2; }
[ "$TOK" = "$FRS" ] || { echo "$TOK tokens in pass 1 became $FRS fake-root paths in pass 2" >&2; exit 2; }
for tok in __ZP__ __ZS__ __ZBM__; do
  [ "$(cnt "$tok" "$W/pass1.sh")" -gt 0 ] || { echo "no $tok token was produced -- that rule matched nothing" >&2; exit 2; }
done
grep -qF "$FR$FR" "$RW" && { echo "a rewrite cascaded: $FR appears twice in a row" >&2; exit 2; }
grep -qF "$FR/proc/$FR" "$RW" && { echo "a rewrite cascaded into the fake root's own proc/" >&2; exit 2; }
# The paths the probe's answers hang on, named -- a rule that silently stopped applying would be invisible
# to the counts above if its occurrences moved into a comment.
for need in "$FR/proc/device-tree/model" "$FR/proc/device-tree/compatible" "$FR/proc/device-tree/aliases" \
  "$FR/proc/cmdline" "$FR/proc/partitions" "$FR/proc/mounts" "$FR/proc/uptime" \
  "$FR/sys/bus/platform/drivers/sdhci_msm" "$FR/sys/class/mmc_host" "$FR/sys/block/mmcblk" \
  "$FR/sys/module/sdhci_msm/parameters"; do
  grep -qF "$need" "$RW" || { echo "$need is not in the rewritten probe -- it would read this host, or a reading is gone" >&2; exit 2; }
done

# --- the static safety guard, and its teeth --------------------------------------------------------
#
# What counts as a write: a redirect into /sys, /proc or /dev; and dd/tee/setprop/modprobe/insmod/rmmod/
# mount/umount/mkfs **in command position**, where command position means the first word of a statement --
# the start of a line, or just after `;`, `&&`, `||`, `|`, `(`, `then`, `do` or `else`. Requiring a
# statement boundary and not just "after a space" is what keeps the probe's own prose from being read as
# code.
#
# Two exemptions, each of which has to be there for the same reason, and each of which is itself asserted:
#   * `>/dev/null` is not a write to the device's filesystem. This port's shell is /bin/sh, where
#     `2>/dev/null` is the only way to be quiet, so those occurrences are stripped before matching.
#   * a HEREDOC BODY IS TEXT. The probe's `--explain` page says in prose what is NOT done, and blanking the
#     bodies first keeps that prose from being read as code while keeping the line count, so a real hit
#     still reports its own line number.
blank_heredocs() { awk '/<<.?EOF/{s=1} { if (s) print ""; else print $0 } /^EOF$/{s=0}' "$1"; }
strip_nulls() { sed -e 's#[0-9]\{0,\}>[[:space:]]*/dev/null##g' "$1"; }
WRITE_RE='[^-]>[[:space:]]*/(sys|proc|dev)/|(^|[;&|(]|(then|do|else))[[:space:]]*(dd|tee|setprop|modprobe|insmod|rmmod|mkfs(\.ext4)?|mount|umount)([[:space:]]|$)'
write_sites() { strip_nulls "$1" | blank_heredocs /dev/stdin | grep -nE -- "$WRITE_RE"; }

W_SITES=$(write_sites "$SRC")
if [ -z "$W_SITES" ]; then
  ok "the shipped probe contains no write into /sys, /proc or /dev and no state-changing command"
else
  bad "the shipped probe contains what looks like a write:"
  sed 's/^/        | /' <<< "$W_SITES"
fi
# The teeth, and the first one is the write this probe is most plausibly tempted into: unlocking the write
# protect, or flipping the driver's disable_slots bitmask.
printf '%s\n' '# a fixture for the redirect rule: the write-protect unlock this probe does not do' \
  'printf 0 > /sys/block/mmcblk0/force_ro' > "$W/teeth-ro.sh"
printf '%s\n' '# a fixture for the second redirect rule: the driver knob' \
  'printf 0 > /sys/module/sdhci_msm/parameters/disable_slots' > "$W/teeth-slots.sh"
printf '%s\n' '# a fixture for the command-position rule' \
  'mount /dev/mmcblk0p1 /mnt' > "$W/teeth-cmd.sh"
printf '%s\n' '# prose that must not be read as code' \
  "cat <<'EOF'" \
  'reading /dev/mmcblk0 to see whether it answers is a WRITE-class move -- it OPENs a block device -- and this project does not do that' \
  'EOF' \
  'say "the arrow -> /sys/block/mmcblk0/size is how this page writes a path"' > "$W/teeth-prose.sh"
want 'force_ro' "$(write_sites "$W/teeth-ro.sh")" \
  "the guard catches a redirect into the write-protect lock (the unlock test, as a fixture)"
want 'disable_slots' "$(write_sites "$W/teeth-slots.sh")" "and one into the driver's slot bitmask"
want 'mount .dev/mmcblk0p1' "$(write_sites "$W/teeth-cmd.sh")" "and catches a state-changing command in command position"
notwant '.' "$(write_sites "$W/teeth-prose.sh")" \
  "and does not punish prose that names an arrow before a /sys path, or a heredoc about opening a block device"
wantf 'it OPENs a block device' "$(cat "$W/teeth-prose.sh")" \
  "while the heredoc that says so IS in the fixture (so the exemption is doing work, not hiding a miss)"
printf 'x=$(dmesg 2>/dev/null)\n' > "$W/teeth-null.sh"
want '/dev/null' "$(grep -E -- "$WRITE_RE" "$W/teeth-null.sh")" \
  "and without the /dev/null strip, the probe's own quiet-redirects WOULD be flagged"
notwant '.' "$(write_sites "$W/teeth-null.sh")" "while with the strip they are not"

# --- the fake device -------------------------------------------------------------------------------
#
# `scen` builds the whole fake root from nothing, so a scenario can never inherit the previous one's
# leftovers. Every file it does not create is ABSENT, which is the point: the probe must reach its verdict
# from what is there, not from what a copy left behind.
#
# Device-tree properties are BYTES: a string list is NUL-terminated, and a u32 is four big-endian bytes.
dtp() { mkdir -p "$(dirname "$1")"; printf '%s\0' "$2" > "$1"; }
# A u32, written as the four big-endian bytes it is. The escape has to be a FORMAT STRING (`printf "$2"`),
# not `printf '%s' "$2"` -- `%s` prints the six characters `\000` literally, which reads back as
# not-a-u32(14 bytes) and makes every phandle look unresolved.
dtu32p() { mkdir -p "$(dirname "$1")"; printf "$2" > "$1"; }

# The two boards' root properties, exactly as the flashed blob carries them: IDENTICAL `compatible`, and a
# `model` that is the only thing telling them apart.
MODEL_ZL1='Letv Technologies, Inc. MSM 8996pro + PMI8996 LE_ZL1-DVT1'
MODEL_X2='Letv Technologies, Inc. MSM 8996 v3 + PMI8996 LE_X2-PVT'

# The non-removable controller (/soc/sdhci@7464900, alias sdhc1), with the real properties from a ZL1 DTB:
# status ok, bus width 8, HS400_1p8v/HS200_1p8v/DDR_1p8v, `qcom,nonremovable` present and EMPTY (it is a
# boolean property, so its value is zero bytes), inline crypto through phandle 297, a SEVEN-cell
# qcom,clk-rates whose first entry is 400 kHz -- which is why the probe prints the list and not the head --
# and a pinctrl group, because a controller whose pins are in no group cannot talk to anything however okay
# its status is.
sdhc1_node() { # $1 = node dir, $2 = status
  dtp "$1/compatible" 'qcom,sdhci-msm'
  dtp "$1/status" "$2"
  dtp "$1/qcom,msm-bus,name" 'sdhc1'
  printf '\000\000\000\010' > "$1/qcom,bus-width"
  printf 'HS400_1p8v\0HS200_1p8v\0DDR_1p8v\0' > "$1/qcom,bus-speed-mode"
  # 400000 20000000 25000000 50000000 96000000 192000000 384000000, big-endian, four bytes each.
  printf '\000\006\032\200\001\061\055\000\001\175\170\100\002\372\360\200\005\270\330\000\013\161\260\000\026\343\140\000' \
    > "$1/qcom,clk-rates"
  # 300000000, 150000000 -- a u32 LIST too, and reading it with the STRING helper is how it looks absent.
  printf '\021\341\243\000\010\360\321\200' > "$1/qcom,ice-clk-rates"
  printf '\000\000\001\051' > "$1/sdhc-msm-crypto"
  : > "$1/qcom,nonremovable"
  dtp "$1/pinctrl-names" 'active'
  printf '\000\000\001\053' > "$1/pinctrl-0"
}
# The removable controller (/soc/sdhci@74A4900, alias sdhc2): bus width 4, the SD speed modes, NO
# `qcom,nonremovable`, and `cd-gpios = <&tlmm 95 1>` -- three cells, the first a phandle, the last the
# polarity flag (1 = GPIO_ACTIVE_LOW).
sdhc2_node() { # $1 = node dir, $2 = status
  dtp "$1/compatible" 'qcom,sdhci-msm'
  dtp "$1/status" "$2"
  dtp "$1/qcom,msm-bus,name" 'sdhc2'
  printf '\000\000\000\004' > "$1/qcom,bus-width"
  printf 'SDR12\0SDR25\0SDR50\0DDR50\0SDR104\0' > "$1/qcom,bus-speed-mode"
  printf '\000\006\032\200\001\061\055\000' > "$1/qcom,clk-rates"
  printf '\000\000\000\034\000\000\000\137\000\000\000\001' > "$1/cd-gpios"
  dtp "$1/pinctrl-names" 'active'
  printf '\000\000\001\065' > "$1/pinctrl-0"
}
# The pinctrl controller `cd-gpios` points at. Its phandle is what turns "gpio 95" into "gpio 95 ON THIS
# CONTROLLER", which is the reading the probe exists to print.
tlmm_node() { # $1 = the phandle, as big-endian bytes
  DT="$FR/proc/device-tree/soc/pinctrl@01010000"
  dtp "$DT/compatible" 'qcom,msm8996-pinctrl'
  dtu32p "$DT/phandle" "$1"
  dtu32p "$DT/#gpio-cells" '\000\000\000\002'
  : > "$DT/gpio-controller"
}

scen() {
  SCEN="$1"
  rm -rf "$FR"
  mkdir -p "$FR/proc/sys/kernel/random" "$FR/proc/device-tree/soc" "$FR/proc/device-tree/aliases" \
    "$FR/sys/bus/platform/drivers" "$FR/sys/class" "$FR/sys/block" "$FR/sys/module" "$FR/dev"

  printf '%s\0' "$MODEL_ZL1" > "$FR/proc/device-tree/model"
  printf 'qcom,msm8996-mtp\0qcom,msm8996\0qcom,mtp\0' > "$FR/proc/device-tree/compatible"
  printf '11111111-2222-3333-4444-555555555555\n' > "$FR/proc/sys/kernel/random/boot_id"
  printf '1234.56 5678.90\n' > "$FR/proc/uptime"
  printf 'Linux version 3.18.140 (build) #1 SMP\n' > "$FR/proc/version"
  # The boot's cmdline: the stock/v63 shape, which carries NO androidboot.bootdevice= token -- that is what
  # makes sdhci_msm_is_bootdevice() return TRUE and keeps the slot-1 gate from firing.
  if [ "$SCEN" = bootdevice-token ]; then
    printf 'console=tty0 androidboot.bootdevice=7464900.sdhci androidboot.serialno=33e80afe\n' > "$FR/proc/cmdline"
  else
    printf 'console=tty0 androidboot.hardware=qcom firmware_class.path=/vendor/firmware_mnt/image\n' > "$FR/proc/cmdline"
  fi
  # Partitions and mounts: the port's own storage is NOT on this controller, so the mmc rows are absent and
  # the sda rows carry the rootfs. That contrast is a reading, so the fixture has it.
  printf 'major minor  #blocks  name\n\n   8        0   61071360 sda\n   8        1       8192 sda1\n   8       10   10485760 sda10\n' \
    > "$FR/proc/partitions"
  printf '/dev/sda10 /etc ext4 rw,relatime 0 0\n' > "$FR/proc/mounts"

  case "$SCEN" in
  unknown-model) printf 'Letv Technologies, Inc. LE_UNKNOWN-XYZ\0' > "$FR/proc/device-tree/model" ;;
  no-model) rm -f "$FR/proc/device-tree/model" ;;
  x2-tree) printf '%s\0' "$MODEL_X2" > "$FR/proc/device-tree/model" ;;
  esac

  # The aliases. The driver reads the slot index from here, not from the node path -- so the fixture spells
  # the mapping out and the probe prints it.
  if [ "$SCEN" != no-aliases ]; then
    dtp "$FR/proc/device-tree/aliases/sdhc1" '/soc/sdhci@7464900'
    dtp "$FR/proc/device-tree/aliases/sdhc2" '/soc/sdhci@74A4900'
  fi

  S1="$FR/proc/device-tree/soc/sdhci@7464900"
  S2="$FR/proc/device-tree/soc/sdhci@74A4900"
  case "$SCEN" in
  bare-tree | no-dt-node) : ;;
  # A node in the RIGHT SHAPE and with the WRONG compatible. This is the only scenario in which a scan
  # without find(1) is a scan that HAPPENED and found nothing: the bare tree above matches no shape, so it
  # can only report "could not look", which is a different state.
  alien-node) dtp "$FR/proc/device-tree/soc/sdhci@9999999/compatible" 'qcom,alien-sdhci' ;;
  all-disabled) sdhc1_node "$S1" disabled; sdhc2_node "$S2" disabled ;;
  # A tree where the REMOVABLE controller is the enabled one: the probe must then not claim the slot is off.
  removable-enabled) sdhc1_node "$S1" disabled; sdhc2_node "$S2" ok ;;
  no-cd-gpios) sdhc1_node "$S1" ok; sdhc2_node "$S2" disabled; rm -f "$S2/cd-gpios" ;;
  # ONE node only, so a `bus width:` line in the report can only be this node's.
  bad-cell) sdhc1_node "$S1" ok; printf '\000\000\010' > "$S1/qcom,bus-width" ;;
  *) sdhc1_node "$S1" ok; sdhc2_node "$S2" disabled ;;
  esac
  case "$SCEN" in
  bare-tree | no-dt-node | alien-node) : ;;
  *) tlmm_node '\000\000\000\034' ;;
  esac
  # `ambiguous-phandle`: a second node carries the same phandle, which a hand-built tree can do. The probe
  # must say AMBIGUOUS rather than pick one -- a wrong controller is a wrong gpio number.
  if [ "$SCEN" = ambiguous-phandle ]; then
    dtu32p "$FR/proc/device-tree/soc/other-gpio/phandle" '\000\000\000\034'
  fi

  # The driver. `no-driver-dir` is the directory's absence; `driver-not-bound` is the same directory with
  # nothing attached, which is a DIFFERENT reading (the driver registered and nothing probed).
  D="$FR/sys/bus/platform/drivers/sdhci_msm"
  case "$SCEN" in
  bare-tree | no-dt-node | no-driver-dir) : ;;
  driver-not-bound) mkdir -p "$D"; touch "$D/bind" "$D/unbind" "$D/uevent" ;;
  *)
    mkdir -p "$D/7464900.sdhci"
    touch "$D/bind" "$D/unbind" "$D/uevent"
    # The removable controller is `status = disabled`, so its platform device does not exist -- the fixture
    # is faithful and does NOT create 74a4900.sdhci unless the scenario enables that slot.
    [ "$SCEN" = removable-enabled ] && mkdir -p "$D/74a4900.sdhci"
    ;;
  esac
  if [ "$SCEN" != no-module-params ]; then
    mkdir -p "$FR/sys/module/sdhci_msm/parameters"
    printf '0\n' > "$FR/sys/module/sdhci_msm/parameters/disable_slots"
    printf 'N\n' > "$FR/sys/module/sdhci_msm/parameters/nocmdq"
  fi

  # The mmc hosts. `no-mmc-host` is an EMPTY class directory -- a different reading from a missing one,
  # which is why the directory exists and holds nothing.
  case "$SCEN" in
  no-mmc-host) mkdir -p "$FR/sys/class/mmc_host" ;;
  bare-tree | no-dt-node | all-disabled | no-driver-dir | driver-not-bound) : ;;
  *)
    # mmc0 is the NON-REMOVABLE controller (parent 7464900.sdhci), and the number is deliberately the
    # "wrong" one against the alias: the alias says slot 1, the idr handed out 0. That is the shape the
    # probe must survive by reading the PARENT rather than the number.
    mkdir -p "$FR/sys/class/mmc_host/mmc0" "$FR/sys/bus/platform/devices/7464900.sdhci"
    ln -s "../../../platform/7464900.sdhci" "$FR/sys/class/mmc_host/mmc0/device"
    ln -s "$D" "$FR/sys/bus/platform/devices/7464900.sdhci/driver" 2>/dev/null || true
    if [ "$SCEN" = card ] || [ "$SCEN" = card-and-removable ]; then
      C="$FR/sys/class/mmc_host/mmc0/mmc0:0001"
      mkdir -p "$C"
      printf 'SL64G\n' > "$C/name"
      printf 'MMC\n' > "$C/type"
      printf '08/2016\n' > "$C/date"
      printf '0x0\n' > "$C/fwrev"
      printf '0x0\n' > "$C/hwrev"
      printf '0x1234abcd\n' > "$C/serial"
      printf '0x000015\n' > "$C/manfid"
      printf '0x0100\n' > "$C/oemid"
      printf '0x8\n' > "$C/prv"
      printf '0x01\n' > "$C/life_time"
      printf '0x00\n' > "$C/pre_eol_info"
    fi
    if [ "$SCEN" = card-and-removable ]; then
      # A second host, the removable one, WITH a card -- so the probe must report BOTH the disabled slot
      # (as a tree fact) and an enumerated card (as the verdict).
      mkdir -p "$FR/sys/class/mmc_host/mmc1"
      ln -s "../../../platform/74a4900.sdhci" "$FR/sys/class/mmc_host/mmc1/device"
      C="$FR/sys/class/mmc_host/mmc1/mmc1:aaaa"
      mkdir -p "$C"
      printf 'SD32G\n' > "$C/name"
      printf 'SD\n' > "$C/type"
      printf '01/2020\n' > "$C/date"
      printf '0xdeadbeef\n' > "$C/serial"
    fi
    ;;
  esac

  # The block devices. `size` is in 512-byte sectors, the one unit /sys/block documents; `force_ro` is the
  # writable lock the probe must not touch.
  if [ "$SCEN" = card ] || [ "$SCEN" = card-and-removable ]; then
    mkdir -p "$FR/sys/block/mmcblk0/mmcblk0p1" "$FR/sys/block/mmcblk0/mmcblk0p2"
    printf '61071360\n' > "$FR/sys/block/mmcblk0/size"
    printf '0\n' > "$FR/sys/block/mmcblk0/ro"
    printf '0\n' > "$FR/sys/block/mmcblk0/force_ro"
    printf 'major minor  #blocks  name\n\n   8        0   61071360 sda\n 179        0   30535680 mmcblk0\n 179        1     524288 mmcblk0p1\n' \
      > "$FR/proc/partitions"
    printf '/dev/sda10 /etc ext4 rw,relatime 0 0\n/dev/mmcblk0p1 /media/card vfat rw 0 0\n' > "$FR/proc/mounts"
  fi

  # The kernel log. `log-unreadable` makes BOTH readers fail -- the only honest way to reach "not read".
  LOGMODE=normal
  [ "$SCEN" = log-unreadable ] && LOGMODE=unreadable
  case "$SCEN" in
  card | card-and-removable)
    { printf '[    0.000000] Booting Linux on physical CPU 0x0\n'
      printf '[    1.200000] mmc0: SDHCI controller on 7464900.sdhci [7464900.sdhci] using ADMA 64-bit\n'
      printf '[    1.900000] mmc0: new high speed MMC card at address 0001\n'
      printf '[    1.910000] mmcblk0: mmc0:0001 SL64G 29.1 GiB\n'
      printf '[   30.000000] random: crng init done\n'; } > "$W/kernel.log"
    ;;
  log-failing)
    { printf '[    0.000000] Booting Linux on physical CPU 0x0\n'
      printf '[    1.200000] mmc0: Timeout waiting for hardware interrupt.\n'
      printf '[    1.210000] mmc0: error -110 whilst initialising MMC card\n'
      printf '[   30.000000] random: crng init done\n'; } > "$W/kernel.log"
    ;;
  log-quiet)
    { printf '[    0.000000] Booting Linux on physical CPU 0x0\n'
      printf '[   30.000000] random: crng init done\n'; } > "$W/kernel.log"
    ;;
  log-unreadable) : > "$W/kernel.log" ;;
  *)
    { printf '[    0.000000] Booting Linux on physical CPU 0x0\n'
      printf '[    1.100000] sdhci_msm 7464900.sdhci: sdhci_msm_probe: ICE device is not enabled\n'
      printf '[    1.200000] mmc0: SDHCI controller on 7464900.sdhci [7464900.sdhci] using ADMA 64-bit\n'
      printf '[   30.000000] random: crng init done\n'; } > "$W/kernel.log"
    ;;
  esac
  cat > "$STUB/dmesg" <<'STUBEOF'
#!/bin/sh
[ "${LOGMODE:-normal}" = unreadable ] && exit 1
cat "$LOGFILE"
STUBEOF
  cat > "$STUB/journalctl" <<'STUBEOF'
#!/bin/sh
[ "${LOGMODE:-normal}" = unreadable ] && exit 1
cat "$LOGFILE"
STUBEOF
  chmod +x "$STUB/dmesg" "$STUB/journalctl"
  export LOGMODE LOGFILE="$W/kernel.log"
}

# `run` executes the rewritten probe as the fake device sees it. PATH is the sandbox FIRST, so a tool the
# probe needs and the sandbox lacks fails loudly instead of silently reaching this laptop's copy.
run() { ( cd "$W" && PATH="$STUB:$MINBIN" "$SH_BIN" "$RW" "$@" ) 2>&1; }
# The same, on a device that has no find(1): the only way to reach "the tree could not be searched".
run_nofind() { ( cd "$W" && PATH="$STUB:$MINBIN_NOFIND" "$SH_BIN" "$RW" "$@" ) 2>&1; }
# The same again, for a MUTATED copy of the subject: rewritten the same way, then run against whatever
# scenario was built last. $2 = nofind to run it on the sandbox without find(1).
mut_run() { # $1 = mutated source, $2 = nofind
  rewrite "$1" "$W/mutated.sh"
  sh -n "$W/mutated.sh" || { printf 'MUTATED SUBJECT DOES NOT PARSE\n'; return; }
  if [ "${2:-}" = nofind ]; then
    ( cd "$W" && PATH="$STUB:$MINBIN_NOFIND" "$SH_BIN" "$W/mutated.sh" ) 2>&1
  else
    ( cd "$W" && PATH="$STUB:$MINBIN" "$SH_BIN" "$W/mutated.sh" ) 2>&1
  fi
}

# ==================================================================================================
echo "== 1. the rewrite, the safety scan, and the guard's teeth =="
# ==================================================================================================
scen idle
nonempty "the rewritten probe has content" "$(cat "$RW")"
OUT=$(run --help)
want '^# zl1 sdcard probe' "$OUT" "--help prints the probe's own header"
want 'a separate, reviewed' "$(run --explain)" "--explain says making the slot work is a write and a separate step"
want 'an empty slot' "$(run --explain)" "and names the state a naive reading would call a dead reader"
if ( run --help >/dev/null ); then ok "--help exits 0"; else bad "--help did not exit 0"; fi

# ==================================================================================================
echo "== 2. the board reading, which comes first =="
# ==================================================================================================
scen idle
OUT=$(run)
want 'model: +Letv Technologies, Inc. MSM 8996pro' "$OUT" "a zl1 tree is named by its model"
want 'board: +LE_ZL1 -- this phone' "$OUT" "and read as this phone"

scen x2-tree
OUT=$(run); RC=$?
want '== verdict: wrong-board-tree' "$OUT" "the X2's device tree is its own rung, checked before any hardware"
want 'board: +LE_X2 -- NOT this phone' "$OUT" "and it says which board it is looking at"
want 'the bootloader picked the other phone' "$OUT" "naming the cause rather than the symptom"
[ "$RC" = 1 ] && ok "and exits 1" || bad "the wrong-board verdict exited $RC, not 1"

scen unknown-model
OUT=$(run)
want '== verdict: unknown-board' "$OUT" "a model that names neither board is not attributed to this phone"
want 'board: +neither LE_ZL1 nor LE_X2' "$OUT" "and is reported as neither rather than assumed to be a zl1"

scen no-model
OUT=$(run)
want '== verdict: unknown-board' "$OUT" "an unreadable model reaches the same rung, not a crash"
want 'board: +UNKNOWN' "$OUT" "and is named as unreadable rather than as neither"

# ==================================================================================================
echo "== 3. every rung, one scenario each =="
# ==================================================================================================
scen no-dt-node
OUT=$(run); RC=$?
want '== verdict: no-device-tree-node' "$OUT" "a tree with no qcom,sdhci-msm node says so"
want 'no node in this device tree carries compatible qcom,sdhci-msm' "$OUT" "naming what is missing"
want 'whole tree is scanned' "$OUT" "with the scan named, so the reading does not rest on a guessed path"
[ "$RC" = 1 ] && ok "and exits 1" || bad "the no-node verdict exited $RC, not 1"

scen all-disabled
OUT=$(run); RC=$?
want '== verdict: all-controllers-disabled' "$OUT" "a tree whose controllers are all disabled is its own rung"
want 'no platform device for any of them' "$OUT" "and the verdict says what that costs"
want 'a DEVICE-TREE decision inside the boot image, not a runtime fault' "$OUT" "and which kind of problem it is"
[ "$RC" = 1 ] && ok "and exits 1" || bad "all-disabled exited $RC, not 1"

scen no-driver-dir
OUT=$(run); RC=$?
want '== verdict: driver-not-bound' "$OUT" "a driver that never registered is its own rung"
want 'MISSING -- the driver did not register at all' "$OUT" "with the directory's absence stated, which is not the same as empty"
want 'CONFIG_MMC_SDHCI_MSM=y' "$OUT" "and the defconfig cited, so 'missing' is not read as 'not built in'"
[ "$RC" = 1 ] && ok "and exits 1" || bad "no-driver-dir exited $RC, not 1"

scen driver-not-bound
OUT=$(run); RC=$?
want '== verdict: driver-not-bound' "$OUT" "a driver directory with nothing attached reaches the same rung"
want 'bound devices: NONE .the driver registered, nothing was probed.' "$OUT" "printed as NONE rather than as a blank"
[ "$RC" = 1 ] && ok "and exits 1" || bad "driver-not-bound exited $RC, not 1"

scen no-mmc-host
OUT=$(run); RC=$?
want '== verdict: no-mmc-host' "$OUT" "a bound driver with no host registered is its own rung"
want 'did not reach mmc_add_host' "$OUT" "and the verdict names the stage that failed"
want 'the log section names which' "$OUT" "sending the reader to the log for the reason"
[ "$RC" = 1 ] && ok "and exits 1" || bad "no-mmc-host exited $RC, not 1"

scen idle
OUT=$(run); RC=$?
want '== verdict: no-card' "$OUT" "hosts up and nothing behind them is its own rung"
want 'no mmcN:XXXX child and no .*block/mmcblkN' "$OUT" "with both readings named, not just one"
want 'the card initialisation did not complete' "$OUT" "and what it means for the NON-REMOVABLE controller"
[ "$RC" = 1 ] && ok "and exits 1" || bad "the no-card verdict exited $RC, not 1"

scen card
OUT=$(run); RC=$?
want '== verdict: card-enumerated' "$OUT" "a card with a block device behind it is the healthy rung"
want 'exists with a size' "$OUT" "and says why: the block layer registered a medium"
want 'mounting is a write to the device' "$OUT" "with the verdict keeping the filesystem question separate"
[ "$RC" = 0 ] && ok "and exits 0" || bad "the card verdict exited $RC, not 0"

# ==================================================================================================
echo "== 4. a node that could not be SEARCHED is not a node that is absent =="
# ==================================================================================================
scen bare-tree
OUT=$(run_nofind); RC=$?
want '== verdict: tree-unscanned' "$OUT" "with no find(1) and no known node shape, the probe says it could not look"
want 'could not be searched for a compatible at all' "$OUT" "in those words"
want 'NOT .the tree declares no controller' "$OUT" "and says explicitly that this is not an absence"
notwant 'no-device-tree-node' "$OUT" "so it never reports the absence rung it cannot support"
[ "$RC" = 1 ] && ok "and exits 1" || bad "tree-unscanned exited $RC, not 1"
# The other side of that distinction: the same sandbox where a node of the RIGHT SHAPE is present and its
# compatible is not one of ours. That is a search that HAPPENED and found nothing, and it must report the
# ABSENCE -- not the inability. (A tree with no such node at all cannot be told from "could not look" once
# find(1) is gone, and the probe must not pretend otherwise.)
scen alien-node
OUT=$(run_nofind); RC=$?
want '== verdict: no-device-tree-node' "$OUT" \
  "a sandbox with no find(1) but a node of the right SHAPE is a search that happened and found none"
want 'whole tree is scanned' "$OUT" "with the scan named"
notwant 'tree-unscanned' "$OUT" "and it does not fall back to the inability, which a node shape rules out"
[ "$RC" = 1 ] && ok "and exits 1" || bad "the nofind alien-node scenario exited $RC, not 1"
# And a tree that HAS both nodes: the scan must find BOTH, which is where a found-flag that leaked between
# iterations stops at the first.
scen idle
OUT=$(run_nofind); RC=$?
want '== verdict: no-card' "$OUT" \
  "the same sandbox over a tree that HAS both nodes is a search that found them (so nothing got stuck)"
want '/soc/sdhci@7464900' "$OUT" "and prints the first controller it found"
want '/soc/sdhci@74A4900' "$OUT" \
  "and the second, which is a DIFFERENT node -- a scan whose found-flag leaked from the first would have stopped at one"
[ "$RC" = 1 ] && ok "and exits 1 (this rung is about the card, not the search)" || bad "the no-find-but-nodes-present scenario exited $RC, not 1"

# ==================================================================================================
echo "== 5. a device-tree u32 is BIG-ENDIAN, cells are not one number, and a length is a reading =="
# ==================================================================================================
scen idle
OUT=$(run)
want 'bus width: +8 bit' "$OUT" "a 4-byte big-endian property is read as its value, not byte-swapped"
notwant '134217728' "$OUT" "with the byte-swapped form of 8 nowhere in the report"
want 'clock rates: +400000 20000000 25000000 50000000 96000000 192000000 384000000' "$OUT" \
  "and a LIST property prints EVERY cell, in order, starting at its real first entry"
notwant 'clock rates: +400000$' "$OUT" "so the head alone is not the reading"
want 'ice clock rates: +300000000 150000000' "$OUT" \
  "and the ICE clock list is read as cells too -- read as a STRING list it prints dots and looks absent"
# The failure mode of a length change is a plausible number, so the fixture makes the property 3 bytes and
# the probe must say so instead of reading three bytes as if they were four.
scen bad-cell
OUT=$(run)
want 'bus width: +not-a-u32.3 bytes.' "$OUT" "a property that is not four bytes says so rather than printing a number"
notwant 'bus width: +[0-9]' "$OUT" "and prints no number at all for it (this scenario has ONE node, so the line can only be its own)"

# ==================================================================================================
echo "== 6. cd-gpios is three cells, the first is a phandle, and the last is a polarity =="
# ==================================================================================================
scen idle
OUT=$(run)
want 'card detect: phandle 28 = /soc/pinctrl@01010000, gpio 95, active low' "$OUT" \
  "the card-detect line is resolved THROUGH its phandle, with its gpio and its polarity"
want 'slot: +REMOVABLE .has cd-gpios.' "$OUT" "and the controller that carries it is named as the removable one"
want 'slot: +non-removable .qcom,nonremovable.' "$OUT" \
  "while the other controller is named as non-removable from its own property"
notwant 'card detect: phandle 28 = unresolved' "$OUT" "so the resolution is not silently failing"
want "pinctrl: +names='active.*groups=" "$OUT" "and the pin group is read, because a controller in no group cannot talk"
scen no-cd-gpios
OUT=$(run)
want 'card detect: none' "$OUT" "a controller with no cd-gpios says so rather than printing an empty value"
want 'slot: +unspecified' "$OUT" "and its slot kind is named as unspecified instead of being guessed"
scen ambiguous-phandle
OUT=$(run)
want 'phandle 28 = AMBIGUOUS.2.' "$OUT" \
  "a phandle carried by TWO nodes is reported as ambiguous rather than resolved to one of them"

# ==================================================================================================
echo "== 7. the aliases, the driver, and the reading that the NUMBER does not identify a controller =="
# ==================================================================================================
scen idle
OUT=$(run)
want 'sdhc aliases: +sdhc1=/soc/sdhci@7464900 sdhc2=/soc/sdhci@74A4900' "$OUT" \
  "the sdhc aliases are printed, because the driver reads its slot index from them"
scen no-aliases
OUT=$(run)
want 'sdhc aliases: +NONE' "$OUT" "a tree with no sdhc alias says NONE"
want 'Failed to get slot index' "$OUT" "and names the driver's own refusal for it"
scen idle
OUT=$(run)
want 'bound devices: +7464900.sdhci' "$OUT" "the bound list names the device by its address, not by an mmc number"
notwant 'bound devices:.*74a4900' "$OUT" \
  "and the DISABLED controller's device is not among them -- the tree disabled it, so it does not exist"
want 'disable_slots +0' "$OUT" "the driver's own slot bitmask is read"
want 'S_IRUGO\|S_IWUSR. = 0644: WRITABLE, and this probe writes neither' "$OUT" \
  "and named as writable and untouched, because it IS a write"
scen no-module-params
OUT=$(run)
want 'parameters: MISSING' "$OUT" "a driver with no parameters directory says so rather than printing nothing"
scen bootdevice-token
OUT=$(run)
want 'androidboot.bootdevice=7464900.sdhci' "$OUT" \
  "a cmdline that DOES carry the boot-device token has it printed, because it is what gates slot 1"
notwant 'carries no androidboot.bootdevice= token' "$OUT" "instead of the named absence"
scen idle
OUT=$(run)
want 'carries no androidboot.bootdevice= token' "$OUT" \
  "and a cmdline WITHOUT it prints the named absence -- which is the case that leaves the gate unfired"

# ==================================================================================================
echo "== 8. the hosts, the card, and the block device =="
# ==================================================================================================
scen idle
OUT=$(run)
want 'hosts: mmc0' "$OUT" "the host the kernel registered is printed by number"
want 'parent device: 7464900.sdhci' "$OUT" \
  "WITH the parent device its number belongs to -- the number is allocation order, not the tree's"
want 'card: +NONE' "$OUT" "a host with no card says NONE rather than printing an empty block"
want 'ALLOCATION ORDER, not device-tree order' "$OUT" \
  "and the reason is stated, because a reader would otherwise take mmc0 for the first node"
want 'no mmc block device exists on this boot' "$OUT" "and the block section names the absence"
scen card
OUT=$(run)
want 'hosts: mmc0' "$OUT" "a card-bearing boot still prints its host"
want 'card: +mmc0:0001' "$OUT" "and the card is printed as the host's CHILD, which is where it lives"
want 'name +SL64G' "$OUT" "with the card's own registers -- a reading the card itself produced"
want 'date +08/2016' "$OUT" "including the date it reports"
want 'serial +0x1234abcd' "$OUT" "and its serial"
want 'size: +61071360 sectors' "$OUT" "and the block device's size, in the unit /sys/block documents"
want 'ro: +0' "$OUT" "and the read-only flag"
want 'force_ro: +0 +.WRITABLE' "$OUT" "and the writable lock, named as writable and untouched"
want 'partitions: +mmcblk0p1 mmcblk0p2' "$OUT" "and the partitions, read from /sys rather than from the medium"
want 'does NOT open .*dev/mmcblk' "$OUT" "and the reading is taken without opening the block device"
want '/proc/partitions, mmc rows' "$OUT" "with the same thing cross-checked in /proc/partitions"
want '30535680 mmcblk0' "$OUT" "where the mmc row really is"
want 'mmcblk0p1 /media/card' "$OUT" "and a mount of an mmc device, when one exists"
scen card-and-removable
OUT=$(run); RC=$?
want 'hosts: mmc0 mmc1' "$OUT" "BOTH hosts are listed when both exist"
want 'parent device: 74a4900.sdhci' "$OUT" "and the second one's number is tied to its own parent"
want 'card: +mmc1:aaaa' "$OUT" "with the card on the removable controller"
want '== verdict: card-enumerated' "$OUT" "and the verdict is the enumerated-card rung"
[ "$RC" = 0 ] && ok "and exits 0" || bad "card-and-removable exited $RC, not 0"

# ==================================================================================================
echo "== 9. the removable slot: a tree fact, said separately from any fault =="
# ==================================================================================================
scen idle
OUT=$(run)
want 'THE REMOVABLE SLOT IS SWITCHED OFF IN THE DEVICE TREE' "$OUT" \
  "the disabled slot gets its own paragraph, so it cannot be read as part of a fault"
want '1 of 2 controllers carry a' "$OUT" "with the count of removable controllers"
want 'In all 38 device trees of the three sets' "$OUT" "and the fact that it is NOT a zl1 quirk"
want 'a device-tree change inside the boot image' "$OUT" "with what switching it on would actually cost"
scen removable-enabled
OUT=$(run)
notwant 'THE REMOVABLE SLOT IS SWITCHED OFF' "$OUT" \
  "while a tree whose removable controller IS enabled does not claim the slot is off"
scen all-disabled
OUT=$(run)
want 'THE REMOVABLE SLOT IS SWITCHED OFF' "$OUT" "and the paragraph still appears when every controller is off"

# ==================================================================================================
echo "== 10. the log, and an unreadable log is not a rung =="
# ==================================================================================================
scen log-quiet
OUT=$(run)
want 'the kernel log mentions no mmc host, sdhci or mmcblk this boot' "$OUT" \
  "a readable log with no mmc lines prints its named (none: ...) line"
want 'no card-initialisation or probe failure' "$OUT" "and the failure block prints its own named (none: ...) line"
scen log-failing
OUT=$(run)
want 'whilst initialising' "$OUT" "a card initialisation that failed is surfaced"
want 'Timeout waiting for hardware interrupt' "$OUT" "including the controller's own timeout string"
want 'error -110' "$OUT" "with the error code, which is the readable part"
scen idle
OUT=$(run)
want 'ICE device is not enabled' "$OUT" \
  "and a probe line from a DRIVER that came up is surfaced, because it is the driver's own account"
scen log-unreadable
OUT=$(run); RC=$?
want 'the kernel log could not be read' "$OUT" "an unreadable kernel log says so"
want 'so this section is NOT READ' "$OUT" "and is named as not read rather than printed empty"
want '== verdict: no-card' "$OUT" "with the verdict unchanged -- no rung here comes from the log"
[ "$RC" = 1 ] && ok "and its exit code is the rung's, not the log's" || bad "the unreadable-log scenario exited $RC, not 1"

# ==================================================================================================
echo "== 11. --quiet, and the exit-code contract =="
# ==================================================================================================
scen card
Q=$(run --quiet); F=$(run)
want '== verdict: card-enumerated' "$Q" "--quiet still prints the verdict (a verdict is not a reading)"
want 'boot id:' "$Q" "--quiet still prints which boot this is (a verdict with no boot identity is not attributable)"
want 'model:' "$Q" "--quiet still prints which board's tree this is (the first rung survives --quiet)"
want 'hosts: mmc0' "$Q" "--quiet keeps the host reading the verdict rests on"
notwant 'compatible:' "$Q" "--quiet drops the device-tree detail"
want 'compatible:' "$F" "and the full run has it"
notwant 'pinctrl:' "$Q" "--quiet drops the per-node detail"
want 'pinctrl:' "$F" "which the full run keeps"
OUT=$(run --bogus); RC=$?
want 'unknown argument' "$OUT" "an unknown argument is refused by name"
[ "$RC" = 2 ] && ok "and exits 2, so a typo cannot be read as a reading" || bad "an unknown argument exited $RC, not 2"

# ==================================================================================================
echo "== 12. the shipped probe is still write-free, and the mutation proves the guard has teeth =="
# ==================================================================================================
notwantf '> /tmp/' "$(cat "$SRC")" "the shipped probe writes no scratch file in /tmp either"
notwantf 'mktemp' "$(cat "$SRC")" "and creates no temporary file at all"
wantf 'LOG_TEXT=$(dmesg' "$(cat "$SRC")" "the kernel log is captured into a variable (the write-free way to read it twice)"
# The mutation: unlocking the write protect, which is precisely the write a probe about storage is tempted
# into, and the one that would change the medium if it were ever run on a real device.
sed 's#^  SZ=\$(rd "\$b/size")#  printf 0 > /sys/block/mmcblk0/force_ro; SZ=$(rd "$b/size")#' "$SRC" > "$W/mut-write.sh"
if cmp -s "$SRC" "$W/mut-write.sh"; then
  bad "the mutation did not apply -- the seed line it edits is gone, so this check would test nothing"
else
  ok "the mutation applied to the shipped source"
  want 'force_ro' "$(write_sites "$W/mut-write.sh")" \
    "and a mutation that unlocks the write protect is caught by the guard"
fi

# ==================================================================================================
echo "== 13. the mutations that are readings, not writes =="
# ==================================================================================================
# Each of these is a way the probe could still LOOK right, and each must redden a check: a mutation that
# reddens nothing means the scenario it edits is not being tested. The scenario is rebuilt before the
# mutated subject runs, so the two subjects see the same device.
# 1. The board guard: test the root `compatible` -- which BOTH trees carry -- instead of `model`. This is
#    not hypothetical: it is the guard this project's sibling probes use today.
sed -e 's#^case "\$MODEL" in#case "$MODEL$COMPAT" in#' \
  -e 's#^\*LE_ZL1\*) BOARD=zl1 ;;#*LE_ZL1*|*qcom,msm8996*) BOARD=zl1 ;;#' "$SRC" > "$W/mut-board.sh"
if cmp -s "$SRC" "$W/mut-board.sh"; then bad "the board mutation did not apply"; else
  scen x2-tree
  OUT=$(mut_run "$W/mut-board.sh")
  notwant '== verdict: wrong-board-tree' "$OUT" \
    "a guard that tests msm8996 instead of model stops seeing the other board's tree (the mutation)"
  want '== verdict: no-card' "$OUT" "and lands on a hardware rung instead, which is the whole failure mode"
fi
# 2. The status check dropped: a controller the kernel will not create a device for would report as a
#    driver problem, sending the reader to the wrong subsystem.
sed 's#case "\$ST" in okay | ok | EMPTY) ENABLED=yes ;; \*) ENABLED=no ;; esac#case "$ST" in *) ENABLED=yes ;; esac#' \
  "$SRC" > "$W/mut-status.sh"
if cmp -s "$SRC" "$W/mut-status.sh"; then bad "the status mutation did not apply"; else
  scen all-disabled
  OUT=$(mut_run "$W/mut-status.sh")
  notwant '== verdict: all-controllers-disabled' "$OUT" \
    "dropping the status check stops an all-disabled tree being a rung (the mutation)"
fi
# 3. An empty `bound devices` read as fine: a driver directory with nothing attached would pass.
sed 's#^elif \[ -z "\$DRV_BOUND" \]; then#elif false; then#' "$SRC" > "$W/mut-bound.sh"
if cmp -s "$SRC" "$W/mut-bound.sh"; then bad "the bound-device mutation did not apply"; else
  scen driver-not-bound
  OUT=$(mut_run "$W/mut-bound.sh")
  notwant '== verdict: driver-not-bound' "$OUT" \
    "treating an unattached driver as fine stops the rung that says nothing was probed (the mutation)"
fi
# 4. "Could not search" collapsed into "not found": the state that must never print like an absence.
sed 's#^  \[ "\$_nc_any" = 1 \] && return 1#  return 1#' "$SRC" > "$W/mut-scan.sh"
if cmp -s "$SRC" "$W/mut-scan.sh"; then bad "the scan mutation did not apply"; else
  scen bare-tree
  OUT=$(mut_run "$W/mut-scan.sh" nofind)
  notwant '== verdict: tree-unscanned' "$OUT" "collapsing could-not-search into not-found loses that state (the mutation)"
  want '== verdict: no-device-tree-node' "$OUT" "and prints an absence the probe cannot support"
fi
# 5. The byte order: `od -tu4` on a little-endian host, which is the mistake that looks like a reading.
sed 's#_u_a \* 16777216 + _u_b \* 65536 + _u_c \* 256 + _u_d#_u_d * 16777216 + _u_c * 65536 + _u_b * 256 + _u_a#' \
  "$SRC" > "$W/mut-endian.sh"
if cmp -s "$SRC" "$W/mut-endian.sh"; then bad "the endianness mutation did not apply"; else
  scen idle
  OUT=$(mut_run "$W/mut-endian.sh")
  notwant 'bus width: +8 bit' "$OUT" "combining the four bytes in the host's order loses the real value (the mutation)"
  want 'bus width: +134217728' "$OUT" "and prints a number of the right SHAPE and the wrong value"
fi
# 6. The removable-slot paragraph silenced. This is the reading a card-less phone depends on: without it,
#    "the slot is switched off in the tree" is indistinguishable from "the reader is broken".
sed 's#^  always "   THE REMOVABLE SLOT IS SWITCHED OFF IN THE DEVICE TREE (\$N_REMOVABLE of \$N_NODES controllers carry a"#  : "   THE REMOVABLE SLOT IS SWITCHED OFF IN THE DEVICE TREE ($N_REMOVABLE of $N_NODES controllers carry a"#' \
  "$SRC" > "$W/mut-note.sh"
if cmp -s "$SRC" "$W/mut-note.sh"; then bad "the removable-slot mutation did not apply"; else
  scen idle
  OUT=$(mut_run "$W/mut-note.sh")
  notwant 'THE REMOVABLE SLOT IS SWITCHED OFF' "$OUT" \
    "silencing the slot paragraph removes the reading that keeps the slot from looking like a fault (the mutation)"
  want '== verdict: no-card' "$OUT" "while the verdict itself still stands"
fi
# 7. The numbers-are-allocation-order note silenced: a reader would take mmc0 for the tree's first node.
sed 's#^  say "   the number is ALLOCATION ORDER, not device-tree order#  : "   the number is ALLOCATION ORDER, not device-tree order#' \
  "$SRC" > "$W/mut-order.sh"
if cmp -s "$SRC" "$W/mut-order.sh"; then bad "the order-note mutation did not apply"; else
  scen idle
  OUT=$(mut_run "$W/mut-order.sh")
  notwant 'ALLOCATION ORDER, not device-tree order' "$OUT" \
    "silencing the allocation-order note removes the correction that the NUMBER identifies nothing (the mutation)"
  want 'parent device: 7464900.sdhci' "$OUT" "while the parent-device reading still stands"
fi
# 8. The phandle resolution dropped: `cd-gpios` would print three numbers and leave the controller to guess.
sed 's#^      CD_CTRL=\$(phandle_node "\$(dtcell "\$p/cd-gpios" 1)")#      CD_CTRL="(not resolved)"#' "$SRC" > "$W/mut-ph.sh"
if cmp -s "$SRC" "$W/mut-ph.sh"; then bad "the phandle mutation did not apply"; else
  scen idle
  OUT=$(mut_run "$W/mut-ph.sh")
  notwant 'phandle 28 = /soc/pinctrl@01010000' "$OUT" \
    "not resolving the phandle leaves the gpio controller unnamed (the mutation)"
  want 'gpio 95' "$OUT" "while the gpio number itself is still printed -- the wrong-answer-of-the-right-shape case"
fi

# ==================================================================================================
echo "== 14. this harness's own citation =="
# ==================================================================================================
# A count typed by hand in the first thing a human reads goes stale the moment this file grows, so this
# harness reads its own citation out of the health check and compares it with what it just ran.
HEALTH="$HERE/zl1-health-check.sh"
if [ -r "$HEALTH" ]; then
  # The number is the one immediately before ` checks`, taken from the matched text rather than from the
  # whole sentence: `grep -oE '[0-9]+'` over the match also finds the 1 in `zl1-`, which is how the first
  # version of this check compared 1 against 158. The first match is taken with `sed -n 1p` and NOT with
  # `head -n1`: this file sets pipefail, and a reader that exits early turns the WRITER's SIGPIPE death into
  # the pipeline's status -- a check that would report a failure of its own extractor.
  match=$(tr '\n' ' ' < "$HEALTH" |
    grep -oE 'zl1-sdcard-probe-selftest\.sh[^0-9]*[0-9]+ checks' | sed -n 1p)
  cited=$(printf '%s\n' "$match" | sed -n 's/.*[^0-9]\([0-9][0-9]*\) checks$/\1/p')
  total=$((PASS + FAIL + 1))
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
echo "pass=$PASS fail=$FAIL"
if [ "$KEEP" = 1 ]; then echo "kept: $W"; else rm -rf "$W"; fi
[ "$FAIL" = 0 ]
