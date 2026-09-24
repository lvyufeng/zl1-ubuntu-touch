#!/usr/bin/env bash
# zl1 EEPROM probe -- offline self-test. Host-side, touches no device, needs no phone.
#
# Why this exists. `scripts/device/zl1-eeprom-probe.sh` is the instrument for the `eeprom` row of doc 137's
# gap list -- the LAST row with none -- and the readings that make that probe's design are these:
#
#   1. THIS IS THE ONE BLOCK WITH NOTHING MISSING, so the mutation that matters is not "read the other config
#      line" (the `nfc` block's defect) or "read the status the wrong way round" (the `fm-radio` block's) but
#      "blame the option BESIDE the right one": the near-miss driver `eeprom.c` has its own option,
#      `CONFIG_EEPROM_LEGACY`, which is NOT SET in either kernel -- and a probe that asked about THAT would
#      report a kernel that does not build this driver wherever the option is off. Mutation 1.
#   2. THE MATCH TRAVELS THROUGH A NAME THE TREE NEVER SPELLS (`atmel,24c32` -> `24c32`, vendor prefix
#      stripped), so the DRIVER DIRECTORY is `at24` while the CLIENT is `24c32`. Looking the driver up under
#      the id_table name (mutation 4) reddens on a device where it is registered, and the two readings in the
#      same report then disagree -- which is the shape of the defect.
#   3. THE NODE IS `compatible` PLUS `reg` AND NOTHING ELSE, while `at24_get_ofdata()` asks for `read-only`
#      and `pagesize` -- so the tree is silent about the only two things the driver can be told, and both
#      absences have consequences (writable attribute; page_size 1 -> 1 byte/write). The fixtures therefore
#      carry the tree's real two properties, and separate scenarios ADD each of the two the driver asks for,
#      because "the tree does not carry it" and "the tree carries it with a different value" are different
#      readings.
#   4. THE READ PATH AND THE WRITE PATH ARE THE SAME FILE, and this probe's whole safety claim is that it
#      reads the attribute's EXISTENCE and none of its contents. So this harness carries a SECOND static
#      guard -- for READS -- with its own teeth (`cat`, `od`, `dd` and a `wc -c <` of the attribute), because
#      the write guard every sibling harness has would not catch a probe that "just looked".
#   5. THE WORD IS NOT THE BLOCK: a scan for `eeprom` does not find this node at all. The `cameras` scenario
#      puts two `qcom,eeprom@N` nodes in the tree so that the count is a reading rather than a constant, and
#      mutation 10 makes the probe scan for `at24` instead -- which DOES find this node, and so claims the
#      word names the block.
#
# How it works: **the stub directory IS the device.** The probe runs as itself against a fake root, with the
# device's tools stubbed and PATH sandboxed to `$STUB:$MINBIN`. The rewrite covers `/proc/`, `/sys/` and
# `/dev/i2c` -- the last because this probe NAMES the userspace path to the same chip (`/dev/i2c-N`,
# `i2c-dev`) in its prose and in its write-guard paragraph, and a rewrite that covered only the roots it reads
# today would leave a future `> /dev/i2c-8` escaping to this laptop. `/dev/null` does not share that prefix
# and is asserted to survive.
#
# Usage: zl1-eeprom-probe-selftest.sh [--keep]
#   --keep   leave the fake device, the stubs and the rewritten probe for inspection
#
# `ZL1_EEPROM_PROBE_SRC=/path` runs the whole thing against another copy of the subject, which is how a
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
SRC="${ZL1_EEPROM_PROBE_SRC:-$HERE/../device/zl1-eeprom-probe.sh}"
[ -r "$SRC" ] || { echo "cannot read the subject: $SRC" >&2; exit 2; }

# THE NAME OF THIS DIRECTORY IS PART OF THE FIXTURE. The probe scans the tree for a WORD (`nodes_named`,
# which matches a node's path or its `compatible`) and prints how many nodes it found -- so a fake root whose
# path contains that word makes EVERY node match, and the count becomes a constant equal to the number of
# nodes in the fixture. The directory is therefore named with neither `eeprom`, nor `at24`, nor `24c32`:
# the block's three words, none of which may appear in a path the probe greps.
W="${TMPDIR:-/tmp}/zl1-selftest-fake-device"
# And `root`, not `dev`: the fake root's path must not itself contain a path the rewriter hunts for, or the
# replacement text gets rewritten in turn.
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
# The exit status is a reading too, and the top rung is the only one that may exit 0.
rc_is() { if [ "$1" = "$2" ]; then ok "and the exit status is $1"; else bad "expected exit $1, got $2"; fi; }

# --- the sandbox PATH ------------------------------------------------------------------------------
# `type -P`, not `command -v`: in a shell whose profile has made one of these a function, `command -v`
# prints the NAME rather than a path and the symlink would point at itself.
for t in awk basename cat cut dirname find grep head od readlink sed sort tail tr uniq wc; do
  p="$(type -P "$t" 2>/dev/null)" || continue
  [ -n "$p" ] || continue
  ln -sf "$p" "$MINBIN/$t"
  [ "$t" = find ] || ln -sf "$p" "$MINBIN_NOFIND/$t"
done
# The probe reads the tree with find(1), counts property cells with od(1), and shortens paths with
# basename(1)/dirname(1); a sandbox missing one of these would silently turn a reading into an absence. So
# each tool the probe calls is required by name before anything runs.
for t in awk basename cat cut dirname grep od sed tail tr wc find; do
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
# ONE PASS PER RULE and one file per pass, so each rule is counted where it ran. A single pass cascades: the
# `/sys/` inside `/proc/sys/kernel/random/boot_id` would be replaced by the `/proc/` rule and then the
# `/sys/` rule would hit the result. Pass 1 turns each root into a token that cannot itself be a device
# path; pass 2 expands the tokens, and nothing in a replacement can be re-matched by a rule that already
# ran.
cnt() { grep -o -- "$1" "$2" 2>/dev/null | wc -l | tr -d ' '; }
RW="$W/eeprom-probe.sh"
sed -e 's#/proc/#__ZP__#g' "$SRC" > "$W/pass1a.sh"
[ "$(cnt '/proc/' "$SRC")" = "$(cnt '__ZP__' "$W/pass1a.sh")" ] \
  || { echo "the /proc/ rewrite did not cover every /proc/ in the source" >&2; exit 2; }
[ "$(cnt '/proc/' "$W/pass1a.sh")" = 0 ] || { echo "a /proc/ survived pass 1 -- the probe would read this host" >&2; exit 2; }
sed -e 's#/sys/#__ZS__#g' "$W/pass1a.sh" > "$W/pass1b.sh"
[ "$(cnt '/sys/' "$W/pass1a.sh")" = "$(cnt '__ZS__' "$W/pass1b.sh")" ] \
  || { echo "the /sys/ rewrite did not cover every /sys/ in the source" >&2; exit 2; }
[ "$(cnt '/sys/' "$W/pass1b.sh")" = 0 ] || { echo "a /sys/ survived pass 1" >&2; exit 2; }
sed -e 's#/dev/i2c#__ZDI__#g' "$W/pass1b.sh" > "$W/pass1.sh"
[ "$(cnt '/dev/i2c' "$W/pass1b.sh")" = "$(cnt '__ZDI__' "$W/pass1.sh")" ] \
  || { echo "the /dev/i2c rewrite did not cover every occurrence" >&2; exit 2; }
[ "$(cnt '/dev/i2c' "$W/pass1.sh")" = 0 ] || { echo "a /dev/i2c survived pass 1" >&2; exit 2; }
MUSTNULL=$(cnt '2>/dev/null' "$SRC")
[ "$MUSTNULL" = "$(cnt '2>/dev/null' "$W/pass1.sh")" ] \
  || { echo "the rewrite touched /dev/null -- the probe's quiet redirects would break" >&2; exit 2; }
sed -e "s#__ZP__#$FR/proc/#g" -e "s#__ZS__#$FR/sys/#g" -e "s#__ZDI__#$FR/dev/i2c#g" "$W/pass1.sh" > "$RW"
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
for tok in __ZP__ __ZS__ __ZDI__; do
  [ "$(cnt "$tok" "$W/pass1.sh")" -gt 0 ] || { echo "no $tok token was produced -- that rule matched nothing" >&2; exit 2; }
done
grep -qF "$FR$FR" "$RW" && { echo "a rewrite cascaded: $FR appears twice in a row" >&2; exit 2; }
grep -qF "$FR/proc/$FR" "$RW" && { echo "a rewrite cascaded into the fake root's own proc/" >&2; exit 2; }
# The paths the probe's answers hang on, named -- a rule that silently stopped applying would be invisible
# to the counts above if its occurrences moved into a comment.
for need in "$FR/proc/device-tree/model" "$FR/proc/device-tree/compatible" \
  "$FR/proc/sys/kernel/random/boot_id" "$FR/proc/uptime" "$FR/proc/version" "$FR/proc/config.gz" \
  "$FR/sys/bus/i2c/drivers" "$FR/sys/bus/i2c/devices" "$FR/dev/i2c-"; do
  grep -qF "$need" "$RW" || { echo "$need is not in the rewritten probe -- it would read this host, or a reading is gone" >&2; exit 2; }
done
# One rewriting rule for the mutation runs, which are derived from the subject and so inherit its counts.
rewrite_into() { # $1 = source, $2 = output
  sed -e 's#/proc/#__ZP__#g' -e 's#/sys/#__ZS__#g' -e 's#/dev/i2c#__ZDI__#g' "$1" \
    | sed -e "s#__ZP__#$FR/proc/#g" -e "s#__ZS__#$FR/sys/#g" -e "s#__ZDI__#$FR/dev/i2c#g" > "$2"
}

# --- the static guards, and their teeth ------------------------------------------------------------
#
# What counts as a WRITE: a redirect into /sys, /proc or /dev; and dd/tee/setprop/modprobe/insmod/rmmod/
# mount/umount/mkfs **in command position**, where command position means the first word of a statement --
# the start of a line, or just after `;`, `&&`, `||`, `|`, `(`, `then`, `do` or `else`. Requiring a statement
# boundary and not just "after a space" is what keeps the probe's own prose from being read as code.
#
# Two exemptions, each of which has to be there for the same reason, and each of which is itself asserted:
#   * `>/dev/null` is not a write to the device's filesystem. This port's shell is /bin/sh, where
#     `2>/dev/null` is the only way to be quiet, so those occurrences are stripped before matching.
#   * a HEREDOC BODY IS TEXT. The probe's `--explain` page says in prose what the block's surfaces are, and
#     blanking the bodies first keeps that prose from being read as code while keeping the line count, so a
#     real hit still reports its own line number.
blank_heredocs() { awk '/<<.?EOF/{s=1} { if (s) print ""; else print $0 } /^EOF$/{s=0}' "$1"; }
strip_nulls() { sed -e 's#[0-9]\{0,\}>[[:space:]]*/dev/null##g' "$1"; }
WRITE_RE='[^-]>[[:space:]]*/(sys|proc|dev)/|(^|[;&|(]|(then|do|else))[[:space:]]*(dd|tee|setprop|modprobe|insmod|rmmod|mkfs(\.ext4)?|mount|umount)([[:space:]]|$)'
write_sites() { strip_nulls "$1" | blank_heredocs /dev/stdin | grep -nE -- "$WRITE_RE"; }
# WHAT COUNTS AS A READ OF THIS BLOCK'S DATA. The write guard above cannot see `cat`, and this probe's claim
# is stronger than "it does not write": it reads the attribute's EXISTENCE and none of its contents. So the
# commands that could read a file are looked for with the attribute's path, in one pass, with the same
# heredoc exemption -- and `rd` (this tree's own disciplined reader) is deliberately NOT in the list, because
# reading a device directory's `name`/`modalias` is exactly what the probe is allowed to do.
READ_RE='(^|[;&|(])[[:space:]]*(cat|od|head|tail|dd|wc|grep|tr|strings|hexdump)([[:space:]]|<)[^|]*/sys/bus/i2c/devices[^[:space:]]*eeprom'
read_sites() { blank_heredocs "$1" | grep -nE -- "$READ_RE"; }

echo "== 1. the rewrite, both guards' teeth, and the probe's own pages =="
W_SITES=$(write_sites "$SRC")
if [ -z "$W_SITES" ]; then
  ok "the shipped probe contains no write into /sys, /proc or /dev and no state-changing command"
else
  bad "the shipped probe contains what looks like a write:"
  sed 's/^/        | /' <<< "$W_SITES"
fi
R_SITES=$(read_sites "$SRC")
if [ -z "$R_SITES" ]; then
  ok "and no command in it reads the eeprom attribute -- the claim is 'existence, not contents'"
else
  bad "the shipped probe looks like it reads the attribute:"
  sed 's/^/        | /' <<< "$R_SITES"
fi
# The teeth. The write guard's fixtures are this block's real moves: the attribute is the chip's data and the
# same path serves both directions; and /dev/i2c-8 is the driverless route to the same slave.
printf '%s\n' 'printf 1 > /sys/bus/i2c/devices/8-0051/eeprom' > "$W/teeth-attr.sh"
printf '%s\n' 'dd if=/dev/zero of=/sys/bus/i2c/devices/8-0051/eeprom bs=1 count=1' > "$W/teeth-dd.sh"
printf '%s\n' 'printf 1 > /dev/i2c-8' > "$W/teeth-i2cdev.sh"
printf '%s\n' 'modprobe at24' > "$W/teeth-cmd.sh"
printf '%s\n' '# prose that must not be read as code' \
  "say \"the arrow -> /sys/bus/i2c/devices/8-0051/eeprom is how this page writes a path\"" \
  "cat <<'EOF'" \
  'overwriting would be write() on /sys/bus/i2c/devices/8-0051/eeprom, and 2>/dev/null quiets a command' \
  'EOF' > "$W/teeth-prose.sh"
want 'i2c/devices/8-0051/eeprom' "$(write_sites "$W/teeth-attr.sh")" \
  "the write guard catches a redirect into the attribute, which is the read path too (as a fixture)"
want 'dd if=/dev/zero of=/sys/bus/i2c/devices/8-0051/eeprom' "$(write_sites "$W/teeth-dd.sh")" \
  "and a dd that overwrites the chip one byte at a time"
want '/dev/i2c-8' "$(write_sites "$W/teeth-i2cdev.sh")" "and a write through the driverless route to the same slave"
want 'modprobe at24' "$(write_sites "$W/teeth-cmd.sh")" "and a state-changing command in command position"
notwant '.' "$(write_sites "$W/teeth-prose.sh")" \
  "and does not punish prose that names an arrow before a /sys path, or a heredoc about write()"
printf 'x=$(dmesg 2>/dev/null)\n' > "$W/teeth-null.sh"
want '/dev/null' "$(grep -E -- "$WRITE_RE" "$W/teeth-null.sh")" \
  "and without the /dev/null strip, the probe's own quiet-redirects WOULD be flagged"
notwant '.' "$(write_sites "$W/teeth-null.sh")" "while with the strip they are not"
# The READ guard's teeth, and -- just as important -- the one thing it must NOT flag: this tree's own `rd`,
# which reads a device directory's `name` and `modalias` on purpose.
printf '%s\n' 'cat /sys/bus/i2c/devices/8-0051/eeprom' > "$W/rteeth-cat.sh"
printf '%s\n' 'od -An -tu1 /sys/bus/i2c/devices/8-0051/eeprom' > "$W/rteeth-od.sh"
printf '%s\n' 'n=$(wc -c < /sys/bus/i2c/devices/8-0051/eeprom)' > "$W/rteeth-wc.sh"
printf '%s\n' 'n=$(rd /sys/bus/i2c/devices/8-0051/name)' > "$W/rteeth-ok.sh"
printf '%s\n' 'say "the attribute /sys/bus/i2c/devices/8-0051/eeprom is not read here"' > "$W/rteeth-prose.sh"
want 'eeprom$' "$(read_sites "$W/rteeth-cat.sh")" "the read guard catches a cat of the attribute"
want 'od -An' "$(read_sites "$W/rteeth-od.sh")" "and an od of it"
want 'wc -c <' "$(read_sites "$W/rteeth-wc.sh")" "and a wc -c into it"
notwant '.' "$(read_sites "$W/rteeth-ok.sh")" \
  "while reading the device directory's 'name' with this tree's own reader is NOT flagged"
notwant '.' "$(read_sites "$W/rteeth-prose.sh")" "and neither is a line that names the path in prose"
# The probe's header claims it writes NOTHING AT ALL, "not even a scratch file" -- a redirect into /tmp would
# escape the rule above, so the claim gets its own check.
notwant 'mktemp' "$SRC" "and the probe calls no mktemp, so 'not even a scratch file' is a claim about this file"
notwant '(^|[;&|])[[:space:]]*mkdir' "$SRC" "and creates no directory either"

# --- the fake device -------------------------------------------------------------------------------
#
# `scen` builds the whole fake root from nothing, so a scenario can never inherit the previous one's
# leftovers. Every file it does not create is ABSENT, which is the point: the probe must reach its verdict
# from what is there, not from what a copy left behind.
#
# Device-tree properties are BYTES: a string list is NUL-terminated, and a u32 is four big-endian bytes.
dtp() { mkdir -p "$(dirname "$1")"; printf '%s\0' "$2" > "$1"; }
# A u32 written as the four big-endian bytes it is. The escape has to be a FORMAT STRING (`printf "$2"`), not
# `printf '%s' "$2"` -- `%s` prints the characters `\000` literally, which reads back as not-a-u32 and makes
# every cell look absent.
dtu32p() { mkdir -p "$(dirname "$1")"; printf "$2" > "$1"; }
dtlistp() { mkdir -p "$(dirname "$1")"; printf "$2" > "$1"; }

MODEL_ZL1='Letv Technologies, Inc. MSM 8996pro + PMI8996 LE_ZL1-DVT1'
MODEL_X2='Letv Technologies, Inc. MSM 8996 v3 + PMI8996 LE_X2-PVT'

# THE BUS, and the ONE OTHER DEVICE the real tree puts on it: the NFC controller at 0x28, which is the block
# the stage before this one instrumented. It is a fixture rather than a comment because the probe NAMES it,
# and a report that listed one device on a bus carrying two would be a reading nobody checked.
i2c_bus_node() {
  B="$FR/proc/device-tree/soc/i2c@75b6000"
  dtp "$B/compatible" 'qcom,i2c-msm-v2'
  # reg = 0x075b6000, 0x1000 bytes: four cells, big-endian.
  dtu32p "$B/reg" '\000\007\133\000\000\000\020\000'
  dtu32p "$B/qcom,clk-freq-out" '\000\006\032\200'
  dtlistp "$B/pinctrl-names" 'i2c_active\000i2c_sleep\000'
  dtu32p "$B/qcom,disable-dma" ''
  dtp "$FR/proc/device-tree/aliases/i2c8" '/soc/i2c@75b6000'
  O="$B/nq@28"
  dtp "$O/compatible" 'qcom,nq-nci'
  dtu32p "$O/reg" '\000\000\000\050'
}
# THE EEPROM NODE, with the real cells read out of the 15 LE_ZL1 trees: `compatible` and `reg` and NOTHING
# ELSE. What the driver asks for and does not find (`read-only`, `pagesize`) is written by the caller's
# scenario, because that pair is what the scenarios are about.
eeprom_node() {
  N="$FR/proc/device-tree/soc/i2c@75b6000/at24@51"
  dtp "$N/compatible" 'atmel,24c32'
  # reg = 0x51 (81), one cell.
  dtu32p "$N/reg" '\000\000\000\121'
}
# The camera's on-chip memories, which is what a grep for the WORD finds instead of this node.
camera_eeprom_nodes() {
  C="$FR/proc/device-tree/soc/qcom,cci@a0c000"
  dtp "$C/qcom,eeprom@0/compatible" 'qcom,eeprom'
  dtp "$C/qcom,eeprom@1/compatible" 'qcom,eeprom'
}

# The kernel configs. BOTH kernels this project has in hand carry the driver, which is the point of this
# block: there is no missing piece here to find.
config_parents_body() {
  printf 'CONFIG_IKCONFIG=y\n'
  printf 'CONFIG_IKCONFIG_PROC=y\n'
  printf 'CONFIG_I2C=y\n'
  printf 'CONFIG_I2C_MSM_V2=y\n'
  printf 'CONFIG_I2C_CHARDEV=y\n'
  printf 'CONFIG_SYSFS=y\n'
}
config_full() {
  { printf '# Automatically generated file; DO NOT EDIT.\n'
    printf 'Linux/arm64 3.18.140 Kernel Configuration\n'
    config_parents_body
    printf 'CONFIG_EEPROM_AT24=y\n'
    printf '# CONFIG_EEPROM_LEGACY is not set\n'; } > "$W/kernel.config"
}
config_off() { # the option itself off with every parent on -- a state the board is NOT in
  { config_parents_body
    printf '# CONFIG_EEPROM_AT24 is not set\n'
    printf '# CONFIG_EEPROM_LEGACY is not set\n'; } > "$W/kernel.config"
}
config_nocdev() { # the driver on, the userspace path off
  { config_parents_body | grep -v 'CONFIG_I2C_CHARDEV'
    printf '# CONFIG_I2C_CHARDEV is not set\n'
    printf 'CONFIG_EEPROM_AT24=y\n'
    printf '# CONFIG_EEPROM_LEGACY is not set\n'; } > "$W/kernel.config"
}
config_nokey() { # the symbol absent from the file entirely
  { config_parents_body
    printf '# CONFIG_EEPROM_LEGACY is not set\n'; } > "$W/kernel.config"
}
cat > "$STUB/zcat" <<'STUBEOF'
#!/bin/sh
[ "${CFGMODE:-readable}" = unreadable ] && exit 1
cat "$CONFIGFILE"
STUBEOF
cat > "$STUB/gunzip" <<'STUBEOF'
#!/bin/sh
[ "${CFGMODE:-readable}" = unreadable ] && exit 1
cat "$CONFIGFILE"
STUBEOF
chmod +x "$STUB/zcat" "$STUB/gunzip"

# The run-time side: the i2c client (created by the core from the tree), the driver directory, the bind, and
# the device directory with the attribute the driver creates as its LAST statement.
client_present() { # $1 = the client's sysfs name
  mkdir -p "$FR/sys/bus/i2c/devices/$1"
  # THE `name` FILE IS THE STRIPPED COMPATIBLE, which is what the kernel registers a device-tree client
  # under: `atmel,24c32` -> `24c32`. A fixture that wrote the whole compatible here would hide the very
  # reading the probe prints.
  printf '24c32\n' > "$FR/sys/bus/i2c/devices/$1/name"
  printf 'of:Matmel,24c32C24c32\n' > "$FR/sys/bus/i2c/devices/$1/modalias"
  printf '\n' > "$FR/sys/bus/i2c/devices/$1/uevent"
}
driver_registered() {
  mkdir -p "$FR/sys/bus/i2c/drivers/at24"
  : > "$FR/sys/bus/i2c/drivers/at24/bind"
  : > "$FR/sys/bus/i2c/drivers/at24/unbind"
  : > "$FR/sys/bus/i2c/drivers/at24/uevent"
}
bind_client() { ln -sfn "$FR/sys/bus/i2c/devices/$1" "$FR/sys/bus/i2c/drivers/at24/$1"; }
# The attribute this driver creates, plus the `driver` symlink every bound device carries. The attribute's
# CONTENTS are never read by the probe, and this fixture writes a recognisable string into it so that a probe
# which echoed it would be caught by a check rather than by a promise.
attribute_created() { # $1 = the client's sysfs name
  ln -sfn "$FR/sys/bus/i2c/drivers/at24" "$FR/sys/bus/i2c/devices/$1/driver"
  printf 'CALIBRATION-DATA-DO-NOT-READ\n' > "$FR/sys/bus/i2c/devices/$1/eeprom"
}

scen() {
  SCEN="$1"
  rm -rf "$FR"
  mkdir -p "$FR/proc/sys/kernel/random" "$FR/proc/device-tree/soc" "$FR/proc/device-tree/aliases" \
    "$FR/sys/bus/i2c/drivers" "$FR/sys/bus/i2c/devices" "$FR/sys/bus/platform/drivers" \
    "$FR/sys/bus/platform/devices" "$FR/dev"

  printf '%s\0' "$MODEL_ZL1" > "$FR/proc/device-tree/model"
  printf 'qcom,msm8996-mtp\0qcom,msm8996\0qcom,mtp\0' > "$FR/proc/device-tree/compatible"
  printf '11111111-2222-3333-4444-555555555555\n' > "$FR/proc/sys/kernel/random/boot_id"
  printf '1234.56 5678.90\n' > "$FR/proc/uptime"
  printf 'Linux version 3.18.140 (build@zl1) #1 SMP\n' > "$FR/proc/version"

  CONFIGFILE="$W/kernel.config"
  CFGMODE=readable
  case "$SCEN" in
  config-off) config_off ;;
  config-nocdev) config_nocdev ;;
  config-nokey) config_nokey ;;
  *) config_full ;;
  esac
  case "$SCEN" in
  no-config) rm -f "$FR/proc/config.gz" ;;
  config-unreadable) CFGMODE=unreadable; cp "$W/kernel.config" "$FR/proc/config.gz" ;;
  config-nocdev-read) CFGMODE=unreadable; cp "$W/kernel.config" "$FR/proc/config.gz" ;;
  *) cp "$W/kernel.config" "$FR/proc/config.gz" ;;
  esac

  case "$SCEN" in
  unknown-model) printf 'Letv Technologies, Inc. LE_UNKNOWN-XYZ\0' > "$FR/proc/device-tree/model" ;;
  no-model) rm -f "$FR/proc/device-tree/model" ;;
  x2-tree) printf '%s\0' "$MODEL_X2" > "$FR/proc/device-tree/model" ;;
  # BOTH the soc/ and aliases/ directories go: with `aliases` left behind the find-less fallback still has
  # something to WALK, and "could not search" would be unreachable.
  bare-tree) rmdir "$FR/proc/device-tree/soc" "$FR/proc/device-tree/aliases" 2>/dev/null ;;
  esac

  case "$SCEN" in
  bare-tree) : ;;
  no-eeprom-node) i2c_bus_node ;;
  *) i2c_bus_node; eeprom_node ;;
  esac
  N="$FR/proc/device-tree/soc/i2c@75b6000/at24@51"
  case "$SCEN" in
  camera-nodes) camera_eeprom_nodes ;;
  esac
  # THE STATUS IS THE SCENARIO, AND THE ORDINARY CASE HERE IS *ABSENCE*. On this board the node carries no
  # `status` at all, which the device tree reads as enabled -- so the default fixture is the board's real
  # shape, and `status-okay` exists to check that the EXPLICIT spelling reads the same way. `node-disabled`
  # is the FM block's state, brought here because a probe that read this node the FM way would be wrong in
  # the other direction, which is the one mistake this pair of scenarios exists to catch.
  case "$SCEN" in
  bare-tree | no-eeprom-node | alien-node) : ;;
  node-disabled) dtp "$N/status" 'disabled' ;;
  status-okay) dtp "$N/status" 'okay' ;;
  *) : ;;
  esac
  case "$SCEN" in
  compatible-list) dtlistp "$N/compatible" 'atmel,24c16\000atmel,24c32\000' ;;
  bus-disabled) dtp "$FR/proc/device-tree/soc/i2c@75b6000/status" 'disabled' ;;
  no-alias) rm -f "$FR/proc/device-tree/aliases/i2c8" ;;
  read-only-property) dtu32p "$N/read-only" '' ;;
  pagesize-property) dtu32p "$N/pagesize" '\000\000\020\000' ;;
  pagesize-zero) dtu32p "$N/pagesize" '' ;;
  pagesize-long) dtu32p "$N/pagesize" '\000\000\020\000\000\000\004\000' ;;
  no-other-node) rm -rf "$FR/proc/device-tree/soc/i2c@75b6000/nq@28" ;;
  esac
  if [ "$SCEN" = alien-node ]; then dtp "$N/compatible" 'atmel,24c02'; fi

  # ---- the run-time side, from three questions: what the CORE makes (the client), what the DRIVER makes (a
  # directory when it registers, a symlink when its probe returns 0), and what the probe's own END makes (the
  # `eeprom` attribute).
  CLIENT_SYSFS=""; REG=yes; BIND=yes; ATTR=yes
  # THE DRIVER DIRECTORY IS *NOT* THE BIND, and the two are set separately on purpose: the driver registers
  # at module init whether or not any client exists, so every state that has a tree to bind -- including the
  # ones where the client or the bind is missing -- still has a registered driver. Only the states whose
  # kernel does not build it, or cannot say, lose the directory.
  case "$SCEN" in
  bare-tree | alien-node | no-eeprom-node) REG=no; BIND=no; ATTR=no ;;
  node-disabled) BIND=no; ATTR=no ;;
  bus-disabled | no-client) BIND=no; ATTR=no ;;
  # the driver IS registered and bound; what is missing is the LAST statement of its probe
  no-attr) ATTR=no ;;
  driver-unbound) BIND=no; ATTR=no ;;
  no-config | config-unreadable | config-nokey | config-off | driver-not-registered) REG=no; BIND=no; ATTR=no ;;
  esac
  case "$SCEN" in
  bare-tree | alien-node | no-eeprom-node | node-disabled | bus-disabled | no-client) CLIENT_SYSFS="" ;;
  client-other-bus) CLIENT_SYSFS=7-0051 ;;
  *) CLIENT_SYSFS=8-0051 ;;
  esac
  # The bus driver's own directory, whenever there is a tree for it to bind: a state that has a CLIENT also
  # has a registered i2c adapter.
  case "$SCEN" in
  bare-tree) : ;;
  *)
    mkdir -p "$FR/sys/bus/platform/devices/75b6000.i2c" "$FR/sys/bus/platform/drivers/i2c-msm-v2"
    : > "$FR/sys/bus/platform/drivers/i2c-msm-v2/bind"
    ln -sfn "$FR/sys/bus/platform/devices/75b6000.i2c" "$FR/sys/bus/platform/drivers/i2c-msm-v2/75b6000.i2c"
    ;;
  esac
  [ -n "$CLIENT_SYSFS" ] && client_present "$CLIENT_SYSFS"
  [ "$REG" = yes ] && driver_registered
  [ "$BIND" = yes ] && bind_client "$CLIENT_SYSFS"
  # The attribute is created only when the whole probe ran -- and `no-attr` is the state where the driver is
  # bound and the attribute is NOT there, which is its own rung.
  case "$SCEN" in
  bare-tree | alien-node | no-eeprom-node | node-disabled | bus-disabled | no-client | driver-unbound | no-attr | \
    no-config | config-unreadable | config-nokey | config-off | driver-not-registered) : ;;
  *) [ -n "$CLIENT_SYSFS" ] && attribute_created "$CLIENT_SYSFS" ;;
  esac

  # The userspace path to the same chip, one level below the driver.
  case "$SCEN" in
  dev-i2c-thisbus) : > "$FR/dev/i2c-8" ;;
  dev-i2c-other) : > "$FR/dev/i2c-3" ;;
  dev-i2c-both) : > "$FR/dev/i2c-3"; : > "$FR/dev/i2c-8" ;;
  esac

  # The kernel log. `log-unreadable` makes BOTH readers fail -- the only honest way to reach "not read".
  LOGMODE=normal
  [ "$SCEN" = log-unreadable ] && LOGMODE=unreadable
  case "$SCEN" in
  log-failing)
    { printf '[    0.000000] Booting Linux on physical CPU 0x0\n'
      printf '[    1.200000] at24 8-0051: page_size must not be 0!\n'
      printf '[    1.200000] at24: probe of 8-0051 failed with error -22\n'
      printf '[   30.000000] random: crng init done\n'; } > "$W/kernel.log"
    ;;
  log-quiet)
    { printf '[    0.000000] Booting Linux on physical CPU 0x0\n'
      printf '[   30.000000] random: crng init done\n'; } > "$W/kernel.log"
    ;;
  log-unreadable) : > "$W/kernel.log" ;;
  *)
    # A boot in which the driver bound and its LAST statement ran. The dev_info line is the one this probe
    # says is the only place the size and the writability appear.
    { printf '[    0.000000] Booting Linux on physical CPU 0x0\n'
      printf '[    1.150000] at24 8-0051: 4096 byte 24c32 EEPROM, writable, 1 bytes/write\n'
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

  # `no-device-tree` is the last state: the whole thing absent, which is the probe's exit-2 guard.
  [ "$SCEN" = no-device-tree ] && rm -rf "$FR/proc/device-tree"
  export LOGMODE LOGFILE="$W/kernel.log" CONFIGFILE CFGMODE
}

# `run` executes the rewritten probe as the fake device sees it. PATH is the sandbox FIRST, so a tool the
# probe needs and the sandbox lacks fails loudly instead of silently reaching this laptop's copy.
run() { ( cd "$W" && PATH="$STUB:$MINBIN" "$SH_BIN" "$RW" "$@" ) 2>&1; }
run_nofind() { ( cd "$W" && PATH="$STUB:$MINBIN_NOFIND" "$SH_BIN" "$RW" "$@" ) 2>&1; }
run_rc() { ( cd "$W" && PATH="$STUB:$MINBIN" "$SH_BIN" "$RW" "$@" ) >/dev/null 2>&1; printf '%s' "$?"; }
mut_run() { # $1 = mutated source, $2 = "nofind" for the sandbox without find(1)
  rewrite_into "$1" "$W/mutated.sh"
  sh -n "$W/mutated.sh" || { printf 'MUTATED SUBJECT DOES NOT PARSE\n'; return; }
  if [ "${2:-}" = nofind ]; then
    ( cd "$W" && PATH="$STUB:$MINBIN_NOFIND" "$SH_BIN" "$W/mutated.sh" ) 2>&1
  else
    ( cd "$W" && PATH="$STUB:$MINBIN" "$SH_BIN" "$W/mutated.sh" ) 2>&1
  fi
}
# THE FIXTURE THAT MUST NEVER BE READ. Every scenario writes CALIBRATION-DATA-DO-NOT-READ into the attribute,
# so a probe that printed its contents anywhere would be caught by a check rather than by a promise.
CANDATA='CALIBRATION-DATA-DO-NOT-READ'

# ==================================================================================================
echo "== 2. the probe's own pages =="
# ==================================================================================================
want '^# zl1 EEPROM probe' "$(run --help)" "--help prints the probe's own header"
want 'the only one where NOTHING is' "$(run --help)" "and the reading that makes this block different from every sibling"
want 'THE MATCH TRAVELS THROUGH A NAME THE TREE NEVER SPELLS' "$(run --help)" \
  "and the reading that makes it bind"
want 'THE READ PATH AND THE WRITE PATH ARE THE SAME FILE' "$(run --help)" "and the surface it refuses"
EX=$(run --explain)
nonempty "the explain page is not empty" "$EX"
want 'what each reading decides, and why it is this reading' "$EX" "--explain opens by saying what it is"
want '1\. THERE IS NOTHING MISSING HERE' "$EX" "and gives that difference as the first reading"
want '2\. IT BINDS ONLY BECAUSE TWO TABLES AGREE' "$EX" "and the match path as the second"
want 'VENDOR PREFIX STRIPPED' "$EX" "naming the mechanism the match travels through"
want '3\. THE TREE.S TWO PROPERTIES AND THE DRIVER.S TWO PROPERTIES DO NOT INTERSECT' "$EX" \
  "and the third: the tree answers neither of the two things the driver asks"
want '4\. THE READ PATH AND THE WRITE PATH ARE THE SAME FILE' "$EX" "and the surface that is one path"
want '5\. THE WORD IS NOT THE BLOCK' "$EX" "and the word that names three different things"
want 'whether the chip.s CONTENTS are' "$EX" "and what the probe does not claim"
notwant '== verdict:' "$EX" "and it prints the page and NO verdict (nothing was read)"
# `--explain` reads nothing, so it must work where there is nothing to read -- the device-tree guard runs
# after it on purpose.
scen no-device-tree
want 'THERE IS NOTHING MISSING HERE' "$(run --explain)" \
  "and the explain page still prints with no device tree to read (the guard runs after it)"
rc_is 0 "$(run_rc --explain)"
want 'here -- refusing \(this probe reads the device tree\)' "$(run)" "while a report with no device tree refuses"
rc_is 2 "$(run_rc)"
# --quiet is a documented mode, and an untested flag is a claim nobody checked.
scen idle
OUT=$(run --quiet)
want '== verdict: eeprom-exposed' "$OUT" "--quiet still prints the verdict"
want '1\. the i2c client .*8-0051: PRESENT' "$OUT" "and the witness the rung rests on"
notwant 'every property on this node' "$OUT" "while dropping the per-node property dump"

# ==================================================================================================
echo "== 3. board-first: which tree is this, before any hardware =="
# ==================================================================================================
scen idle
OUT=$(run)
nonempty "the report is not empty" "$OUT"
want 'model: +Letv Technologies, Inc. MSM 8996pro \+ PMI8996 LE_ZL1-DVT1' "$OUT" "a zl1 tree is named by its model"
want 'board: +LE_ZL1 -- this phone' "$OUT" "and read as this phone"
want 'kernel: +Linux version 3.18.140' "$OUT" "the running kernel is named"
want 'boot id: +11111111-2222-3333-4444-555555555555' "$OUT" "and the boot the readings belong to"

scen x2-tree
OUT=$(run)
want '== verdict: wrong-board-tree' "$OUT" "the X2's device tree is its own rung, checked before any hardware"
want 'an at24 node sits on an i2c bus in BOTH' "$OUT" "naming why the tree's shape cannot tell them apart"
want 'only .model. can' "$OUT" "and what can"

scen unknown-model
OUT=$(run)
want '== verdict: unknown-board' "$OUT" "a model that names neither board is not attributed to this phone"
want 'model: +Letv Technologies, Inc. LE_UNKNOWN-XYZ' "$OUT" "with the model it did read printed"

scen no-model
OUT=$(run)
want '== verdict: unknown-board' "$OUT" "an unreadable model reaches the same rung, not a crash"
want 'model: +absent' "$OUT" "and is printed as absent rather than as neither"

# ==================================================================================================
echo "== 4. the node: two properties, and the two the driver asks for that are not among them =="
# ==================================================================================================
scen idle
OUT=$(run)
want '/soc/i2c@75b6000/at24@51' "$OUT" "the EEPROM node is read by its path"
want 'compatible: +atmel,24c32' "$OUT" "with the compatible the driver matches on"
want 'status: +absent \(an absent status means ENABLED' "$OUT" \
  "a node with NO status is read as ENABLED, and the probe says which way round it read it"
want 'THIS node carries none, which' "$OUT" "naming it as the ordinary case rather than as a missing reading"
want 'read-only +absent, so the sysfs attribute is created WRITABLE' "$OUT" \
  "the FIRST of the two properties the driver asks for, and its consequence, is spelled out"
want 'the ONE thing the tree could say about this chip.s data' "$OUT" \
  "including that a tree which carried it could make the attribute read-only"
want 'pagesize +absent, so chip.page_size stays 1 and a single write is capped at 1' "$OUT" \
  "and the second, with the write cap it implies"
want 'AND THE TREE.S TWO PROPERTIES AND THE DRIVER.S TWO PROPERTIES DO NOT INTERSECT' "$OUT" \
  "with the intersection stated as the reading"
want 'compatible \+ reg, the driver asks for read-only \+ pagesize' "$OUT" "naming both sides"
want 'visible only in its own dev_info line' "$OUT" "and where the consequences ARE visible"
want 'THAT IS THE WHOLE DESCRIPTION: 2 properties' "$OUT" "and the node's whole property count, as a number"
want 'No gpios, no interrupts, no supplies and' "$OUT" "with what is NOT on it"
notwant "$CANDATA" "$OUT" "AND NOT ONE LINE OF THE ATTRIBUTE'S CONTENTS ANYWHERE IN THE REPORT"

scen status-okay
OUT=$(run)
want 'status: +okay' "$OUT" "the EXPLICIT spelling of enabled is printed as read"
want '== verdict: eeprom-exposed' "$OUT" "and reads the same way an absent status does"
notwant 'absent \(an absent status means ENABLED' "$OUT" \
  "so the two spellings are told apart in the report even though they mean the same thing"

scen node-disabled
OUT=$(run)
want 'status: +disabled' "$OUT" "the other direction is reachable too, for a tree that really says so"
want 'AND THIS IS THE WHOLE ANSWER FOR THIS BLOCK' "$OUT" "and is named as the whole answer"
want 'seeing .disabled. here' "$OUT" "with the reading that makes it surprising on this board"
want '== verdict: no-node-enabled' "$OUT" "so the rung is the node being switched off"
rc_is 1 "$(run_rc)"

scen compatible-list
OUT=$(run)
want 'compatible: +atmel,24c16 atmel,24c32 ' "$OUT" "a compatible list is printed whole"
want '== verdict: eeprom-exposed' "$OUT" "and a node found through a LATER entry is treated as the block"

# The two properties the driver asks for, PRESENT with a value: the other side of the same reading.
scen read-only-property
OUT=$(run)
want 'read-only +PRESENT as a boolean, so the attribute is created READ-ONLY' "$OUT" \
  "a tree that carries read-only is read through the PRESENCE test, not through a value"
want 'tests PRESENCE, not a value' "$OUT" "with the mechanism named"
want '== verdict: eeprom-exposed' "$OUT" "and it does not change how far the chain runs"

scen pagesize-property
OUT=$(run)
want 'pagesize += 4096, so chip.page_size is 4096' "$OUT" \
  "a pagesize the tree DOES carry is read as a number, and its consequence printed"
want 'This one is exactly 1 cells' "$OUT" "with the property's real length beside it"
want '== verdict: eeprom-exposed' "$OUT" "and a pagesize does not change how far the chain runs"

scen pagesize-zero
OUT=$(run)
want 'pagesize +PRESENT but EMPTY' "$OUT" \
  "a bare property is printed as PRESENT and empty -- NOT as the value 0 and not as absent"
want 'reads four bytes out' "$OUT" "with what the driver does with a zero-length property"
want 'chip.page_size is whatever those bytes are, NOT' "$OUT" "and the consequence, which is not page_size 1"
want 'A bare .pagesize. is a different tree from one that omits the property' "$OUT" \
  "naming the distinction the third branch exists for"

scen pagesize-long
OUT=$(run)
want 'pagesize +PRESENT but 2 cells -- NOT a single u32' "$OUT" \
  "an eight-byte pagesize is PRESENT, and its length is the reading"
want 'chip.page_size is$' "$OUT" "the first cell is taken"
want 'then takes the FIRST CELL of it' "$OUT" "with the mechanism named"
want '4096 here and the cells after it are never looked at' "$OUT" "and the value that would be used"
want 'AND THAT IS THE OPPOSITE OF THE FM' "$OUT" "and the contrast with the two-cell read next door"

# ==================================================================================================
echo "== 5. the word is not the block, read off the tree =="
# ==================================================================================================
scen camera-nodes
OUT=$(run)
want "AND THE WORD 'eeprom' DOES NOT NAME THIS BLOCK IN THE TREE AT ALL" "$OUT" \
  "the probe says so in words rather than leaving it to the reader"
want 'a scan for it finds' "$OUT" "and prints the scan"
want '  2 node' "$OUT" "with the count, which the fixtures make a reading rather than a constant"
want '/soc/qcom,cci@a0c000/qcom,eeprom@0' "$OUT" "and the paths it found, named"
want '/soc/qcom,cci@a0c000/qcom,eeprom@1' "$OUT" "both of them"
want 'NONE of them is this node -- this one is .at24@51.' "$OUT" "with this node explicitly not among them"
want 'CAMERA.s' "$OUT" "and the nodes it did find attributed to the camera"
want 'not by this driver' "$OUT" "including that they are not read by THIS driver"

scen camera-nodes-none
OUT=$(run)
want '\(none at all' "$OUT" "a tree with no other eeprom-named node says so in a named way"
want 'grep for the word finds nothing, while this node is' "$OUT" "and still names this node as the one it missed"

# ==================================================================================================
echo "== 6. the driver: how two tables agree, and the one beside it that cannot bind =="
# ==================================================================================================
scen idle
OUT=$(run)
want 'driver: +at24 ' "$OUT" "the driver's directory name -- the one sysfs is keyed by"
want '/sys/bus/i2c/drivers/at24: present, bound: 8-0051' "$OUT" "the driver is registered and bound"
want 'HOW THE TWO TABLES AGREE' "$OUT" "and the match path gets its own section"
want 'at24_of_match\[\] +has exactly ONE entry' "$OUT" "with the of_match table's single entry"
want 'the driver.s +\.name is "at24"' "$OUT" "and the driver's own name"
want 'i2c_match_id\(driver->id_table, client\)' "$OUT" "naming the call that runs"
want 'VENDOR PREFIX STRIPPED \(of_modalias_node\)' "$OUT" "and the stripping step"
want '"atmel,24c32" -> "24c32"' "$OUT" "with the transformation printed"
want 'IS an at24_ids\[\] entry' "$OUT" "and that the stripped name is IN the id table"
want 'a ZERO there returns -ENODEV before the chip is touched' "$OUT" "with the consequence of it not being"
want 'THE TWO TABLES ARE NOT ALTERNATIVES' "$OUT" "and the conclusion: a chain, not alternatives"
want 'THE STRIPPED NAME IS THE ONE THE KERNEL PRINTS' "$OUT" "plus which of the names the kernel uses"
want "never 'atmel,24c32', and never 'at24'" "$OUT" "naming all three places"
# The magic decoded, so the size is a reading rather than a number the probe typed.
want 'byte_len += BIT\(magic & 31\) += 4096 bytes' "$OUT" "the magic is decoded in the report"
want 'num_addresses = DIV_ROUND_UP\(4096, 65536\) = 1' "$OUT" "and the dummy-client count that follows from it"
want 'the multi-address machinery is INERT here' "$OUT" "with what that means for this part"
want 'write_max += min\(page_size, io_limit\) = min\(1, 128\) = 1 byte' "$OUT" "and the write cap"
# The near-miss, and the fact that it is not even built.
want 'eeprom  drivers/misc/eeprom/eeprom.c' "$OUT" "the driver beside it is printed"
want 'NO of_match_table at all' "$OUT" "with why it can never bind a node"
want 'its own sysfs attribute is ALSO named .eeprom.' "$OUT" "and the second reason a grep lands on it"
want 'option: +NOT SET' "$OUT" "AND that its own option is not set in this kernel"
want 'IS NOT IN THE' "$OUT" "which is stronger than 'cannot bind': it is not in the kernel"
want 'RUNNING KERNEL at all' "$OUT" "said in full, because that is the whole difference from a near miss that is built"
want 'A reader who grepped for .eeprom. would find this file' "$OUT" "and the mistake it exists to stop"

# ==================================================================================================
echo "== 7. the config chain, and why this block has nothing missing =="
# ==================================================================================================
scen idle
OUT=$(run)
want 'CONFIG_I2C +y \(built in\)' "$OUT" "the chain's first parent is read"
want 'CONFIG_SYSFS +y \(built in\)' "$OUT" "and the second"
want 'CONFIG_EEPROM_AT24 +y \(built in\)' "$OUT" "and the option itself"
want 'CONFIG_EEPROM_LEGACY +NOT SET' "$OUT" "and the near-miss driver's option, which is off"
want 'the OTHER .eeprom. driver.s' "$OUT" "named as such where it is printed"
want 'AND THIS OPTION IS GATED BY ITS MENU, in the ordinary way' "$OUT" \
  "and the probe says this one IS gated by its menu, in the ordinary way"
want "menu .EEPROM support." "$OUT" "naming the menu it sits in"
want 'depends on I2C && SYSFS' "$OUT" "and its own two parents"
want 'the NFC option sits AFTER the endmenu' "$OUT" "with the two exceptions elsewhere in the list"
want 'refused by the device tree while its option is on' "$OUT" "including the FM block's shape"
want 'AND ON THIS BOARD THERE IS NOTHING MISSING AT ALL' "$OUT" "and the board's own answer"
want 'no missing piece for a ladder to find' "$OUT" "said as the difference from every sibling"
want 'config.gz: yes present / yes permission-readable / yes expanded' "$OUT" \
  "the config file's three facts are printed separately"

scen config-off
OUT=$(run)
want 'CONFIG_EEPROM_AT24 +NOT SET' "$OUT" "the option off is printed as NOT SET"
want 'CONFIG_EEPROM_LEGACY +NOT SET' "$OUT" "while the near-miss option beside it is ALSO off"
want '== verdict: driver-not-built' "$OUT" "and the rung is the config"
want 'THE KERNEL.S OWN CONFIG DOES NOT BUILD IT' "$OUT" "with the cause named"
want 'TWO parents \(I2C and SYSFS\)' "$OUT" "and the warning to read the chain"
want 'if the device reports this rung the config being read is not the one the kernel booted with' "$OUT" \
  "plus the reading that would make it suspicious on this board"

scen config-nokey
OUT=$(run)
want 'CONFIG_EEPROM_AT24 +absent from the config' "$OUT" "a config without the symbol says so"
want '== verdict: driver-not-built' "$OUT" "and is still a kernel that does not build the driver"

scen no-config
OUT=$(run)
want 'config.gz: no present / no permission-readable / no expanded' "$OUT" "a missing config file is named as missing"
want 'CONFIG_EEPROM_AT24 +NOT READ' "$OUT" "so the column says NOT READ rather than NOT SET"
want 'which is a third state, and not .the option is off.' "$OUT" "and the third state is named"
want '== verdict: driver-not-registered' "$OUT" "and the verdict does not claim the kernel cannot build it"
notwant 'driver-not-built' "$OUT" "and never the rung that blames a config line nobody read"

scen config-unreadable
OUT=$(run)
want 'config.gz: yes present / yes permission-readable / no expanded' "$OUT" \
  "a config that is present and unexpandable says exactly that"
want 'CONFIG_EEPROM_AT24 +NOT READ' "$OUT" "and its column is NOT READ all the same"
want 'the verdict below rests on it and NOT' "$OUT" "with the verdict's basis named"

# ==================================================================================================
echo "== 8. the three witnesses, and the rungs =="
# ==================================================================================================
scen idle
OUT=$(run)
want '1\. the i2c client .*8-0051: PRESENT' "$OUT" "the FIRST witness is present"
want 'it is under EXACTLY the name derived above \(bus i2c8, address 0051\)' "$OUT" \
  "under exactly the name the alias and reg predict"
want "AND ITS 'name' FILE IS A READING OF ITS OWN" "$OUT" "and the client's name is a reading, not decoration"
want "it reads '24c32' -- not the tree's 'atmel,24c32' and not the driver's 'at24'" "$OUT" \
  "with all three names in one line"
want '2\. a device bound to .at24.' "$OUT" "the SECOND witness is the bind"
want '3\. the files in .*8-0051:' "$OUT" "the THIRD witness is the device directory"
want 'eeprom   <- THE ATTRIBUTE THIS DRIVER CREATES' "$OUT" "with the attribute itself pointed at"
want 'IT IS READ-WRITE AND IT IS NOT TOUCHED HERE' "$OUT" "and the surface named as untouched"
want 'reading it runs at24_bin_read\(\) ->' "$OUT" "with the read path spelled out"
want "are one path with two redirects" "$OUT" "and the conclusion that read and write are one path"
want 'AND THE ATTRIBUTE IS THE STRONGEST WITNESS HERE' "$OUT" "and why this witness is the strongest"
want 'sysfs_create_bin_file\(\) is the LAST thing' "$OUT" "naming the call and its position"
want 'THE NESTING IS THE READING' "$OUT" "the nesting is stated where the witnesses are"
want 'a chain that stops has' "$OUT" "including why the nesting matters on a board with nothing missing"
want 'WHAT THIS IS NOT: an answer to .is the EEPROM good.' "$OUT" "and what the top rung does not claim"
want 'AND THE ATTRIBUTE IS A DOOR, WHICH IS NOT A FAULT' "$OUT" "with the door-not-a-copy paragraph"
notwant "$CANDATA" "$OUT" "and STILL not one line of the attribute's contents"
rc_is 0 "$(run_rc)"

scen no-attr
OUT=$(run)
want 'there is NO .eeprom. file in it' "$OUT" "a bound driver with no attribute says so"
want 'its absence means the probe did not reach sysfs_create_bin_file' "$OUT" "with the call it did not reach"
want '== verdict: no-eeprom-attribute' "$OUT" "and that is its own rung"
want 'a statement before it failed' "$OUT" "with the cause named"

scen driver-unbound
OUT=$(run)
want '== verdict: driver-not-bound' "$OUT" "a registered driver with nothing attached is its own rung"
want 'at24_probe\(\) returns -ENODEV before touching the chip if the id_table entry.s driver_data is zero' "$OUT" \
  "with the QUIET failure this block invites named first"
want "'atmel,24c32' -> '24c32'" "$OUT" "and the stripping rule it depends on"
want 'I2C_FUNC_I2C' "$OUT" "plus the other ways the probe can fail, from the source"

scen no-client
OUT=$(run)
want '== verdict: no-client' "$OUT" "no client at all reaches the same rung"
want '/sys/bus/i2c/drivers/at24: present, bound: NONE' "$OUT" \
  "while the driver IS registered -- which is what makes the rung order a check"
want 'this node carries no status, so the i2c core SHOULD have instantiated' "$OUT" \
  "and the absence is named as NOT expected here, unlike the FM block's"
want 'points at the bus \(or the alias\)' "$OUT" "with the next move named"

scen bus-disabled
OUT=$(run)
want 'status: +disabled' "$OUT" "the i2c bus's own status is printed"
want '== verdict: no-client' "$OUT" "a bus the tree switches off is its own rung"
want 'NO CONFIG LINE FOR THE AT24 DRIVER CAN FIX THIS' "$OUT" "and the probe says no config line can fix it"

scen no-alias
OUT=$(run)
want 'alias: +none points at this controller' "$OUT" "a tree with no alias for this bus says so"
want 'looks for the ADDRESS instead' "$OUT" "and the probe falls back to the address"
want '1\. the i2c client .*8-0051: PRESENT' "$OUT" "so a client under an underivable bus number is FOUND"
want 'BUT NOT UNDER THE NAME DERIVED ABOVE' "$OUT" "and the probe says the name was not derivable"
want '== verdict: eeprom-exposed' "$OUT" "so the rung does not stop on a missing alias"

scen client-other-bus
OUT=$(run)
want '1\. the i2c client .*7-0051: PRESENT' "$OUT" "a client under another bus number is found by its address"
want 'BUT NOT UNDER THE NAME DERIVED ABOVE: i2c8 gives bus 8' "$OUT" "and the derived bus number is named"
want 'The client exists; the ALIAS is what is wrong.' "$OUT" "with the cause attributed to the alias"
want '== verdict: eeprom-exposed' "$OUT" "so a wrong bus number does not stop the ladder"

scen driver-not-registered
OUT=$(run)
want '== verdict: driver-not-registered' "$OUT" "a missing driver directory with the option ON is its own rung"
want 'NOT attributed to a config line here' "$OUT" "and the verdict does not blame the config"
want 'CONFIG_EEPROM_AT24 reads .y \(built in\).' "$OUT" "quoting the line that would have contradicted it"

# The bus, its alias, and the one other device on it.
scen idle
OUT=$(run)
want '/soc/i2c@75b6000' "$OUT" "the bus node is read by its path"
want 'alias: +i2c8 -> bus 8, so the i2c core will name the client' "$OUT" "the alias gives the bus number"
want "'8-0051' -- and THAT name is what the witness section looks for" "$OUT" "and the client's name is derived"
want 'reg: +81 \(0x51\) -- the i2c slave address' "$OUT" "the address is read as a number"
want 'AND A 24c32 ANSWERS AT 0x51 IN EVERY TREE THAT DESCRIBES ONE' "$OUT" \
  "and the address is tied to the part, not to this node"
want 'qcom,clk-freq-out: 400000 -- so this bus runs at 400000 Hz' "$OUT" "the bus speed is a reading"
want 'qcom,disable-dma is PRESENT, so this controller.s transfers are done WITHOUT DMA' "$OUT" \
  "and so is the controller's own DMA switch"
want 'AND THIS BUS CARRIES ANOTHER DEVICE: nq@28\(qcom,nq-nci\)' "$OUT" \
  "the other device on the bus is named, not counted"
want 'The other one is the NFC controller' "$OUT" "and identified as the block the previous stage instrumented"

scen no-other-node
OUT=$(run)
want 'this bus carries no other device in the tree' "$OUT" "a bus with one device says so instead"

# ==================================================================================================
echo "== 9. the second path to the same chip, one level below the driver =="
# ==================================================================================================
scen dev-i2c-thisbus
OUT=$(run)
want 'AND THE SAME CHIP HAS A SECOND PATH, ONE LEVEL BELOW THIS DRIVER, WHICH THIS PROBE DOES NOT TAKE' "$OUT" \
  "the driverless path is named where it exists"
want 'CONFIG_I2C_CHARDEV is y \(built in\)' "$OUT" "with the option that makes it possible"
want '/dev/i2c-8   <- THIS BUS' "$OUT" "and the node for THIS bus identified as such"
want 'NOT OPENED, and neither is any other' "$OUT" "and the refusal stated at the place a reader would try it"

scen dev-i2c-other
OUT=$(run)
want '/dev/i2c-3   \(not this block.s bus\)' "$OUT" "a node for another bus is printed without being claimed"
want '== verdict: eeprom-exposed' "$OUT" "and it does not change the verdict"

scen dev-i2c-both
OUT=$(run)
want '/dev/i2c-3   \(not this block.s bus\)' "$OUT" "two nodes are told apart"
want '/dev/i2c-8   <- THIS BUS' "$OUT" "and the right one is identified"

scen config-nocdev
OUT=$(run)
want 'AND THE SAME CHIP HAS NO USERSPACE PATH BELOW THIS DRIVER' "$OUT" \
  "a kernel without i2c-dev says so"
want 'CONFIG_I2C_CHARDEV is NOT SET' "$OUT" "naming the option"
want 'the sysfs attribute above is the' "$OUT" "and what that leaves as the only route"

scen no-config
OUT=$(run)
want 'AND WHETHER THE SAME CHIP HAS A SECOND, DRIVERLESS PATH IS NOT READ' "$OUT" \
  "an unreadable config does NOT claim there is no userspace path"
want 'the config could not be read' "$OUT" "with the reason named"
notwant 'i2c-dev is not available' "$OUT" "and never the claim that would follow from an unread option"

# ==================================================================================================
echo "== 10. the kernel log, where the size and the writability actually appear =="
# ==================================================================================================
scen idle
OUT=$(run)
want 'source: dmesg' "$OUT" "the reader the log came from is named"
want 'at24 8-0051: 4096 byte 24c32 EEPROM, writable, 1 bytes/write' "$OUT" "the driver's own dev_info line is matched"
want 'THE DRIVER.S OWN dev_info LINE IS THE ONLY PLACE THE SIZE AND THE WRITABILITY APPEAR' "$OUT" \
  "with the reason this section is a reading and not decoration"
want 'THREE of those four facts are properties this tree does NOT' "$OUT" \
  "and how many of those facts the tree could have carried"

scen log-failing
OUT=$(run)
want 'page_size must not be 0!' "$OUT" "the driver's own failure strings are matched"
want 'probe of 8-0051 failed with error -22' "$OUT" "including the probe failure"

scen log-quiet
OUT=$(run)
want '\(none: the kernel log names no at24 device this boot\)' "$OUT" \
  "a log with no at24 line prints a NAMED silence rather than nothing"
want '\(none: no at24 probe complaint in this boot.s log\)' "$OUT" "and the failure scan is a named silence too"

scen log-unreadable
OUT=$(run)
want 'the kernel log could not be read' "$OUT" "a log that cannot be read is a state of its own"
want 'this section is NOT READ' "$OUT" "and is named rather than read as a silence"
want 'NOTE WHAT IS LOST' "$OUT" "and what its absence costs on this block specifically"
want 'this block.s' "$OUT" "with the numbers named as unavailable rather than absent"
want '== verdict: eeprom-exposed' "$OUT" "so an unreadable log does not change the rung"

want "'at24' in the log plus 'disabled' in the tree is a contradiction worth chasing" "$(scen node-disabled; run)" \
  "and a log line against a disabled node is named as the contradiction it is"

# ==================================================================================================
echo "== 11. the tree-level rungs, and the two searches that must not print the same way =="
# ==================================================================================================
scen bare-tree
OUT=$(run)
want '== verdict: no-device-tree-node' "$OUT" "a tree with no nodes at all, searched with find, is an ABSENCE"
notwant 'tree-unscanned' "$OUT" "and not a search that could not run"

scen bare-tree
OUT=$(run_nofind)
want '== verdict: tree-unscanned' "$OUT" "the same tree with no find(1) is a search that could not run"
want "it is 'this probe could" "$OUT" "and the probe says so in its own words (the sentence wraps)"
want 'not look., and the two must not print the same way' "$OUT" "in the half that carries the point"
notwant 'no-device-tree-node' "$OUT" "and never printing as an absence"

scen alien-node
OUT=$(run)
want '== verdict: no-device-tree-node' "$OUT" "a node of the right shape with another compatible is an absence"
want 'On this board the node IS in all 15 of its trees' "$OUT" "with the reason that rung is surprising here"

scen alien-node
OUT=$(run_nofind)
want '== verdict: no-device-tree-node' "$OUT" "and with no find(1) it is STILL an absence, because the fallback walked"

scen no-eeprom-node
OUT=$(run)
want '== verdict: no-device-tree-node' "$OUT" "a tree that simply has no such node is the same rung"
want 'the running tree declares no EEPROM at all' "$OUT" "and it is printed as that"

# ==================================================================================================
echo "== 12. the mutations: each one has to redden something =="
# ==================================================================================================
# 1. THE OPTION BESIDE THE RIGHT ONE. `CONFIG_EEPROM_LEGACY` is the OTHER `eeprom` driver's option, and the
#    near miss is exactly what this block invites: a probe that asked about it would blame a config line that
#    has nothing to do with this node on a kernel that DOES build the driver it needs -- which is the shape
#    this block has no other way of producing, because here nothing really is off.
sed 's#^N_BUILT=$(cfg_opt CONFIG_EEPROM_AT24)$#N_BUILT=$(cfg_opt CONFIG_EEPROM_LEGACY)#' "$SRC" > "$W/mut-legacy.sh"
if cmp -s "$SRC" "$W/mut-legacy.sh"; then bad "the beside-the-right-one mutation did not apply"; else
  scen driver-not-registered
  OUT=$(mut_run "$W/mut-legacy.sh")
  notwant '== verdict: driver-not-registered' "$OUT" \
    "reading the option beside the right one loses the rung that blames no config line (the mutation)"
  want '== verdict: driver-not-built' "$OUT" \
    "and reports a kernel that DOES build the driver as one that does not"
  want 'CONFIG_EEPROM_AT24 +y \(built in\)' "$OUT" \
    "while the same page prints CONFIG_EEPROM_AT24 as built in -- the two readings contradict each other"
  want 'CONFIG_EEPROM_LEGACY +NOT SET' "$OUT" \
    "and both symbols are on the page, two lines apart, so the wrong one is visible as the wrong one"
fi

# 2. The LAST rung dropped: the attribute assumed rather than looked for.
sed 's#^elif \[ "\$ATTR_FOUND" = no \]; then$#elif false; then#' "$SRC" > "$W/mut-attrrung.sh"
if cmp -s "$SRC" "$W/mut-attrrung.sh"; then bad "the attribute-rung mutation did not apply"; else
  scen no-attr
  OUT=$(mut_run "$W/mut-attrrung.sh")
  notwant '== verdict: no-eeprom-attribute' "$OUT" "dropping the last rung loses that answer (the mutation)"
  want '== verdict: eeprom-exposed' "$OUT" \
    "and reports a probe that stopped before its last statement as one that finished"
  want 'there is NO .eeprom. file in it' "$OUT" "while the same report says the attribute is not there"
fi

# 3. The CLIENT rung dropped. The client is the i2c core's work, so a node with no client cannot be fixed by
#    any driver or config line -- which is why the ladder puts it above every driver rung.
sed 's#^elif \[ "\$CLIENT_FOUND" = no \]; then$#elif false; then#' "$SRC" > "$W/mut-clientrung.sh"
if cmp -s "$SRC" "$W/mut-clientrung.sh"; then bad "the client-rung mutation did not apply"; else
  scen no-client
  OUT=$(mut_run "$W/mut-clientrung.sh")
  notwant '== verdict: no-client' "$OUT" "dropping the client rung loses that answer (the mutation)"
  want '== verdict: driver-not-bound' "$OUT" \
    "and reports a driver that was never given a client as one whose probe failed"
  want 'the i2c client .*8-0051: ABSENT' "$OUT" \
    "while the same report says the client is absent -- the two readings disagree"
fi

# 4. The DRIVER NAME from the wrong one of the three. `24c32` is the CLIENT's name (the stripped compatible)
#    and it is NOT a directory in /sys/bus/i2c/drivers, where the name is the driver's own `at24`.
sed "s#printf 'at24\\\\tCONFIG_EEPROM_AT24#printf '24c32\\\\tCONFIG_EEPROM_AT24#" "$SRC" > "$W/mut-drvname.sh"
if cmp -s "$SRC" "$W/mut-drvname.sh"; then bad "the driver-name mutation did not apply"; else
  scen idle
  OUT=$(mut_run "$W/mut-drvname.sh")
  notwant 'driver: +at24 ' "$OUT" \
    "looking the driver up under the client's name loses the name sysfs is keyed by (the mutation)"
  want 'driver: +24c32 ' "$OUT" "and prints a name no directory carries"
  want '== verdict: driver-not-registered' "$OUT" "so a registered driver reads as one that never registered"
  want 'i2c/devices/8-0051: PRESENT' "$OUT" \
    "while the client is still there, so the two readings DISAGREE -- which is the shape of the defect"
fi

# 5. The endianness. A device-tree u32 is four BIG-ENDIAN bytes and this SoC is little-endian, so `od -tu4`
#    prints 0x51 as 0x51000000: a plausible number, and the client's name comes out wrong.
sed 's#_u_a \* 16777216 + _u_b \* 65536 + _u_c \* 256 + _u_d#_u_d * 16777216 + _u_c * 65536 + _u_b * 256 + _u_a#' \
  "$SRC" > "$W/mut-endian.sh"
if cmp -s "$SRC" "$W/mut-endian.sh"; then bad "the endianness mutation did not apply"; else
  scen idle
  OUT=$(mut_run "$W/mut-endian.sh")
  notwant 'reg: +81 \(0x51\)' "$OUT" "reading a big-endian cell in host order loses the address (the mutation)"
  want '== verdict: no-client' "$OUT" \
    "so a client that exists is looked for under a name that cannot exist, and the whole block reads as absent"
fi

# 6. "Could not search" collapsed into "not found". The one state that must never print like an absence.
sed 's#^  return 2$#  return 1#' "$SRC" > "$W/mut-scan.sh"
if cmp -s "$SRC" "$W/mut-scan.sh"; then bad "the scan mutation did not apply"; else
  scen bare-tree
  OUT=$(mut_run "$W/mut-scan.sh" nofind)
  notwant '== verdict: tree-unscanned' "$OUT" "collapsing could-not-search into not-found loses that state (the mutation)"
  want '== verdict: no-device-tree-node' "$OUT" "and prints an absence the probe cannot support"
fi

# 7. "Could not read" collapsed into "not set". The config that cannot be read is a third state; a probe that
#    reported it as the option being off would blame a config line it never read.
sed 's#printf .NOT READ.; return; fi#printf "NOT SET"; return; fi#' "$SRC" > "$W/mut-notread.sh"
if cmp -s "$SRC" "$W/mut-notread.sh"; then bad "the not-read mutation did not apply"; else
  scen no-config
  OUT=$(mut_run "$W/mut-notread.sh")
  notwant '== verdict: driver-not-registered' "$OUT" \
    "reporting an unreadable config as NOT SET loses the third state (the mutation)"
  want '== verdict: driver-not-built' "$OUT" "and blames a config line that was never read"
  want 'CONFIG_EEPROM_AT24 +NOT SET' "$OUT" "on a page whose own line above says the file was not expanded"
  want 'no expanded' "$OUT" "so the two readings contradict each other in the same report"
  # AND THE SAME MUTATION ON THE OTHER THIRD STATE: the userspace path. An unreadable config must not be
  # reported as a kernel without i2c-dev -- the same collapse, on the same page, one section lower.
  notwant 'AND WHETHER THE SAME CHIP HAS A SECOND, DRIVERLESS PATH IS NOT READ' "$OUT" \
    "and the userspace-path section loses its third state under the same mutation"
  want 'AND THE SAME CHIP HAS NO USERSPACE PATH BELOW THIS DRIVER' "$OUT" \
    "claiming instead that this chip has no userspace route at all"
  want 'i2c-dev is not available' "$OUT" \
    "on a page whose own line above says the config was never expanded"
fi

# 8. An absent `status` read as NOT enabled -- the mistake the FM block's probe guards against in the other
#    direction, and here it is the one that does NOT apply: this node is enabled BY ABSENCE.
sed 's#^  okay | ok | EMPTY | absent) NODE_EN=yes ;;$#  okay | ok) NODE_EN=yes ;;#' "$SRC" > "$W/mut-status.sh"
if cmp -s "$SRC" "$W/mut-status.sh"; then bad "the absent-status mutation did not apply"; else
  scen idle
  OUT=$(mut_run "$W/mut-status.sh")
  notwant '== verdict: eeprom-exposed' "$OUT" \
    "reading an absent status as off loses the top rung on a node the tree has enabled (the mutation)"
  want '== verdict: no-node-enabled' "$OUT" "and reports the tree as switching its own node off"
fi

# 9. The BUS'S OTHER DEVICE dropped. The tree puts two devices on this bus, and a report that listed one
#    would have a reading nobody checked -- and would hide that a bus-level fault is shared. The mutation
#    empties the loop rather than changing what it excludes, so `_others` stays empty and the report prints
#    the sentence meant for a bus with one device.
sed 's#^  for _o in "\$I2C_PARENT"/\*; do$#  for _o in; do#' "$SRC" > "$W/mut-otherdev.sh"
if cmp -s "$SRC" "$W/mut-otherdev.sh"; then bad "the other-device mutation did not apply"; else
  scen idle
  OUT=$(mut_run "$W/mut-otherdev.sh")
  notwant 'AND THIS BUS CARRIES ANOTHER DEVICE' "$OUT" \
    "dropping the other-device scan loses that reading (the mutation)"
  notwant 'nq@28' "$OUT" "and the second device on the bus disappears from the report"
  want 'and this bus carries no other device in the tree' "$OUT" \
    "while the report states, as a reading, that the bus carries one"
fi

# 10. THE WORD SCANNED FOR INSTEAD OF THE BLOCK. `eeprom` finds NO node in a tree shaped like this phone's --
#     that is the whole claim -- so a probe that scanned for the driver's word instead would find exactly ONE
#     (this node) and then print the sentence reserved for a tree where the word finds nothing, while naming
#     the node it claims the word missed.
sed 's#^  _nn_paths=$(nodes_named eeprom)$#  _nn_paths=$(nodes_named at24)#' "$SRC" > "$W/mut-word.sh"
if cmp -s "$SRC" "$W/mut-word.sh"; then bad "the word mutation did not apply"; else
  scen camera-nodes
  OUT=$(mut_run "$W/mut-word.sh")
  notwant '/soc/qcom,cci@a0c000/qcom,eeprom@0' "$OUT" \
    "scanning for the driver's word loses the camera nodes a reader's grep actually finds (the mutation)"
  want '  1 node' "$OUT" "leaving the block's own node as the single hit"
  want '\(none at all' "$OUT" \
    "and the sentence for a tree where the word finds nothing, printed about a tree where it finds this node"
  notwant 'NONE of them is this node' "$OUT" \
    "so the report no longer says the node it found is not one of them"
fi

# 11. The userspace path looked for BY NUMBER. The bus number is the ALIAS's answer and the tree can change
#     it, so a probe that read `/dev/i2c-8` would be right only while the alias says 8.
sed 's#for _dev in /dev/i2c-\*; do#for _dev in /dev/i2c-8; do#' "$SRC" > "$W/mut-bynumber.sh"
if cmp -s "$SRC" "$W/mut-bynumber.sh"; then bad "the by-number mutation did not apply"; else
  scen dev-i2c-other
  OUT=$(mut_run "$W/mut-bynumber.sh")
  notwant '/dev/i2c-3' "$OUT" \
    "looking the userspace node up by number loses a node that is there when the bus number is not 8 (the mutation)"
  want 'none: .*dev/i2c-\* does not exist here' "$OUT" "and reports it as nonexistent"
fi

# 12. The pagesize read as the SECOND cell. `at24_get_ofdata()` reads the FIRST cell of whatever
#     `of_get_property()` returned, so reading cell 2 of a two-cell property reports a number the driver
#     never sees -- a plausible value from the wrong cell, which is the harder failure to notice.
sed 's#^  _ps=$(dtu32 "\$NODE/pagesize")$#  _ps=$(dtcell "$NODE/pagesize" 2)#' "$SRC" > "$W/mut-cell.sh"
if cmp -s "$SRC" "$W/mut-cell.sh"; then bad "the cell mutation did not apply"; else
  scen pagesize-long
  OUT=$(mut_run "$W/mut-cell.sh")
  notwant 'chip.page_size is 4096' "$OUT" \
    "reading the second cell loses the value the driver would use (the mutation)"
  want '1024, so chip.page_size is 1024' "$OUT" \
    "and prints the other cell of the same property as if it were the first"
fi

# 13. The attribute's EXISTENCE read as its CONTENT. This is the mutation the READ guard exists for, and the
#     mutation spells the path OUT rather than going through the loop variable on purpose: the guard is a
#     static rule over this file, so it can see a path and cannot see `"$_f"`. A probe that reached the chip
#     through the variable would slip past the guard -- and be caught by the sentinel check below instead,
#     which is why the two are run together rather than one of them being trusted.
sed 's#^      ATTR_FOUND=yes$#      ATTR_FOUND=yes; say "      $(cat /sys/bus/i2c/devices/$CLIENT_ACTUAL/eeprom)"#' \
  "$SRC" > "$W/mut-readattr.sh"
if cmp -s "$SRC" "$W/mut-readattr.sh"; then bad "the read-the-attribute mutation did not apply"; else
  want 'cat /sys/bus/i2c/devices/.*eeprom' "$(read_sites "$W/mut-readattr.sh")" \
    "the READ guard catches a probe that reads the attribute into the report (as a fixture)"
  scen idle
  OUT=$(mut_run "$W/mut-readattr.sh")
  want "$CANDATA" "$OUT" \
    "and the mutation really does put the chip's contents on the page -- which is what the guard forbids"
fi

# ==================================================================================================
echo "== 13. this harness's own citation =="
# ==================================================================================================
# A count typed by hand in the first thing a human reads goes stale the moment this file grows, so this
# harness reads its own citation out of the health check and compares it with what it just ran.
HEALTH="$HERE/zl1-health-check.sh"
if [ -r "$HEALTH" ]; then
  # The number is the one immediately before ` checks`, taken from the matched text rather than from the
  # whole sentence: `grep -oE '[0-9]+'` over the match also finds the 1 in `zl1-`, which is how the first
  # version of this check on a sibling harness compared 1 against its own total. The first match is taken
  # with `sed -n 1p` and NOT with `head -n1`: this file sets pipefail, and a reader that exits early turns
  # the WRITER's SIGPIPE death into the pipeline's status -- a check that would report a failure of its own
  # extractor.
  match=$(tr '\n' ' ' < "$HEALTH" |
    grep -oE 'zl1-eeprom-probe-selftest\.sh[^0-9]*[0-9]+ checks' | sed -n 1p)
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
