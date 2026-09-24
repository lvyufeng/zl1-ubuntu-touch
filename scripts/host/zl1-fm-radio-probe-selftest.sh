#!/usr/bin/env bash
# zl1 FM radio probe -- offline self-test. Host-side, touches no device, needs no phone.
#
# Why this exists. `scripts/device/zl1-fm-radio-probe.sh` is the instrument for the `fm-radio` row of doc
# 137's gap list, and the readings that make that probe's design are these:
#
#   1. THE TREE SWITCHES THIS NODE OFF, AND THE LADDER RESTS ON IT. `/soc/i2c@75b5000/silabs4705@11`
#      (`silabs,si4705`) carries `status = "disabled"` in all 15 LE_ZL1 trees and all three sets, while every
#      other block this project has instrumented carries NO status at all (which the device tree reads as
#      ENABLED). So `node-disabled` is the state this board is really in, and the `disabled-read-as-enabled`
#      mutation -- the opposite of the absent-status mistake every sibling probe guards against -- is the
#      defect this block invites.
#   2. AND THE OBVIOUS EXPLANATION IS WRONG. `CONFIG_RADIO_SILABS=y` in BOTH kernels in hand, so the driver IS
#      built; the tree is what refuses the node. `config-off` is therefore a state the board is NOT in, and
#      the `config-parent-read` mutation (reading RADIO_ADAPTERS instead) reddens on it -- because here the
#      option genuinely sits INSIDE the menu that gates it, unlike the `nfc` block next door.
#   3. THREE GPIOS, TWO FATAL, AND TWO REGULATORS, NEITHER FATAL. `reset-absent` and `int-absent` fail the
#      chain; `status-absent` and `no-supply` must still reach the TOP rung. The `status-gpio-fatal` mutation
#      turns that split into a check instead of a claim.
#   4. THE VOLTAGE PROPERTIES ARE READ AS EXACTLY TWO CELLS, so `voltage-odd` (three cells) is FATAL even
#      though the supply beside it is not. The fixture writes the board's own `<3300000 3300000>` and
#      `<1800000 1800000>`.
#   5. THE IDENTITY IS THE `name` FILE AND THE NUMBER IS AN ALLOCATION. `RADIO_NR` is -1, so v4l2 allocates
#      the first free number: the `radio-number` scenario puts this block's device at radio3 with another
#      device at radio0, and the `radio-by-number` mutation is what makes "identified by its number" a check
#      that can fail.
#   6. FOUR NAMES AND A DRIVER THAT CAN NEVER BIND. The compatible `silabs,si4705`; the i2c driver `.name`
#      `silabs-fm` (the only sysfs path); the i2c_device_id `radio-silabs`; and `radio-silabs` again as the
#      v4l2 device name. The `driver-by-id-table-name` mutation looks the driver up under the id_table name,
#      and `si470x` -- the driver beside it, with NO of_match_table -- is printed as what a grep for `si470`
#      would confuse it with.
#
# How it works: **the stub directory IS the device.** The probe runs as itself against a fake root, with the
# device's tools stubbed and PATH sandboxed to `$STUB:$MINBIN`. The rewrite covers `/proc/`, `/sys/` and
# `/dev/radio` -- the last because this probe NAMES that device node in its prose and in its write-guard
# paragraph, and a rewrite that covered only the roots it reads today would leave a future `> /dev/radio0`
# escaping to this laptop. `/dev/null` does not share that prefix and is asserted to survive.
#
# Usage: zl1-fm-radio-probe-selftest.sh [--keep]
#   --keep   leave the fake device, the stubs and the rewritten probe for inspection
#
# `ZL1_FM_RADIO_PROBE_SRC=/path` runs the whole thing against another copy of the subject, which is how a
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
SRC="${ZL1_FM_RADIO_PROBE_SRC:-$HERE/../device/zl1-fm-radio-probe.sh}"
[ -r "$SRC" ] || { echo "cannot read the subject: $SRC" >&2; exit 2; }

W="${TMPDIR:-/tmp}/zl1-fm-radio-probe-selftest"
# `root`, not `dev`: the fake root's path must not itself contain a path the rewriter hunts for, or the
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
# The probe reads the tree with find(1), resolves phandles with it, counts property cells with od(1), and
# shortens paths with basename(1)/dirname(1); a sandbox missing one of these would silently turn a reading
# into an absence. So each tool the probe calls is required by name before anything runs.
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
RW="$W/fm-radio-probe.sh"
sed -e 's#/proc/#__ZP__#g' "$SRC" > "$W/pass1a.sh"
[ "$(cnt '/proc/' "$SRC")" = "$(cnt '__ZP__' "$W/pass1a.sh")" ] \
  || { echo "the /proc/ rewrite did not cover every /proc/ in the source" >&2; exit 2; }
[ "$(cnt '/proc/' "$W/pass1a.sh")" = 0 ] || { echo "a /proc/ survived pass 1 -- the probe would read this host" >&2; exit 2; }
sed -e 's#/sys/#__ZS__#g' "$W/pass1a.sh" > "$W/pass1b.sh"
[ "$(cnt '/sys/' "$W/pass1a.sh")" = "$(cnt '__ZS__' "$W/pass1b.sh")" ] \
  || { echo "the /sys/ rewrite did not cover every /sys/ in the source" >&2; exit 2; }
[ "$(cnt '/sys/' "$W/pass1b.sh")" = 0 ] || { echo "a /sys/ survived pass 1" >&2; exit 2; }
sed -e 's#/dev/radio#__ZDR__#g' "$W/pass1b.sh" > "$W/pass1.sh"
[ "$(cnt '/dev/radio' "$W/pass1b.sh")" = "$(cnt '__ZDR__' "$W/pass1.sh")" ] \
  || { echo "the /dev/radio rewrite did not cover every occurrence" >&2; exit 2; }
[ "$(cnt '/dev/radio' "$W/pass1.sh")" = 0 ] || { echo "a /dev/radio survived pass 1" >&2; exit 2; }
MUSTNULL=$(cnt '2>/dev/null' "$SRC")
[ "$MUSTNULL" = "$(cnt '2>/dev/null' "$W/pass1.sh")" ] \
  || { echo "the rewrite touched /dev/null -- the probe's quiet redirects would break" >&2; exit 2; }
sed -e "s#__ZP__#$FR/proc/#g" -e "s#__ZS__#$FR/sys/#g" -e "s#__ZDR__#$FR/dev/radio#g" "$W/pass1.sh" > "$RW"
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
for tok in __ZP__ __ZS__ __ZDR__; do
  [ "$(cnt "$tok" "$W/pass1.sh")" -gt 0 ] || { echo "no $tok token was produced -- that rule matched nothing" >&2; exit 2; }
done
grep -qF "$FR$FR" "$RW" && { echo "a rewrite cascaded: $FR appears twice in a row" >&2; exit 2; }
grep -qF "$FR/proc/$FR" "$RW" && { echo "a rewrite cascaded into the fake root's own proc/" >&2; exit 2; }
# The paths the probe's answers hang on, named -- a rule that silently stopped applying would be invisible
# to the counts above if its occurrences moved into a comment.
for need in "$FR/proc/device-tree/model" "$FR/proc/device-tree/compatible" \
  "$FR/proc/sys/kernel/random/boot_id" "$FR/proc/uptime" "$FR/proc/version" "$FR/proc/config.gz" \
  "$FR/sys/bus/i2c/drivers" "$FR/sys/bus/i2c/devices" "$FR/sys/class/video4linux" "$FR/dev/radio"; do
  grep -qF "$need" "$RW" || { echo "$need is not in the rewritten probe -- it would read this host, or a reading is gone" >&2; exit 2; }
done
# One rewriting rule for the mutation runs, which are derived from the subject and so inherit its counts.
rewrite_into() { # $1 = source, $2 = output
  sed -e 's#/proc/#__ZP__#g' -e 's#/sys/#__ZS__#g' -e 's#/dev/radio#__ZDR__#g' "$1" \
    | sed -e "s#__ZP__#$FR/proc/#g" -e "s#__ZS__#$FR/sys/#g" -e "s#__ZDR__#$FR/dev/radio#g" > "$2"
}

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
#   * a HEREDOC BODY IS TEXT. The probe's `--explain` page says in prose what the block's write-class move
#     is, and blanking the bodies first keeps that prose from being read as code while keeping the line
#     count, so a real hit still reports its own line number.
blank_heredocs() { awk '/<<.?EOF/{s=1} { if (s) print ""; else print $0 } /^EOF$/{s=0}' "$1"; }
strip_nulls() { sed -e 's#[0-9]\{0,\}>[[:space:]]*/dev/null##g' "$1"; }
WRITE_RE='[^-]>[[:space:]]*/(sys|proc|dev)/|(^|[;&|(]|(then|do|else))[[:space:]]*(dd|tee|setprop|modprobe|insmod|rmmod|mkfs(\.ext4)?|mount|umount)([[:space:]]|$)'
write_sites() { strip_nulls "$1" | blank_heredocs /dev/stdin | grep -nE -- "$WRITE_RE"; }

echo "== 1. the rewrite, the guard's teeth, and the probe's own pages =="
W_SITES=$(write_sites "$SRC")
if [ -z "$W_SITES" ]; then
  ok "the shipped probe contains no write into /sys, /proc or /dev and no state-changing command"
else
  bad "the shipped probe contains what looks like a write:"
  sed 's/^/        | /' <<< "$W_SITES"
fi
# The two surfaces this block's probe calls out in its own header: opening the device node, which POWERS THE
# CHIP UP; and the one writable attribute a radio device has, which is a v4l2 verbosity knob.
printf '%s\n' 'printf 1 > /dev/radio0' > "$W/teeth-dev.sh"
printf '%s\n' 'printf 2 > /sys/class/video4linux/radio0/debug' > "$W/teeth-debug.sh"
printf '%s\n' 'printf 1 > /sys/bus/i2c/devices/7-0011/name' > "$W/teeth-i2c.sh"
printf '%s\n' 'dd if=fm.bin of=/dev/radio0 bs=1 count=4' > "$W/teeth-dd.sh"
printf '%s\n' 'modprobe radio-silabs' > "$W/teeth-cmd.sh"
printf '%s\n' '# prose that must not be read as code' \
  "say \"the arrow -> /sys/class/video4linux/radio0/debug is how this page writes a path\"" \
  "cat <<'EOF'" \
  'tuning would be ioctl(/dev/radio0, VIDIOC_S_HW_FREQ_SEEK) on an open fd, and 2>/dev/null is how this port quiets a command' \
  'EOF' > "$W/teeth-prose.sh"
want 'radio0' "$(write_sites "$W/teeth-dev.sh")" "the guard catches a redirect into the radio device node (as a fixture)"
want 'video4linux/radio0/debug' "$(write_sites "$W/teeth-debug.sh")" "and one into the writable debug attribute this block really has"
want 'i2c/devices/7-0011/name' "$(write_sites "$W/teeth-i2c.sh")" "and one into a client's own i2c attribute"
want 'dd if=fm.bin of=/dev/radio0' "$(write_sites "$W/teeth-dd.sh")" \
  "and a dd straight onto the device node, which is the shell's nearest thing to the ioctl this block's write-class move really is"
want 'modprobe radio-silabs' "$(write_sites "$W/teeth-cmd.sh")" "and a state-changing command in command position"
notwant '.' "$(write_sites "$W/teeth-prose.sh")" \
  "and does not punish prose that names an arrow before a /sys path, or a heredoc about an ioctl"
wantf 'ioctl(/dev/radio0, VIDIOC_S_HW_FREQ_SEEK)' "$(cat "$W/teeth-prose.sh")" \
  "while the heredoc that says so IS in the fixture (so the exemption is doing work, not hiding a miss)"
printf 'x=$(dmesg 2>/dev/null)\n' > "$W/teeth-null.sh"
want '/dev/null' "$(grep -E -- "$WRITE_RE" "$W/teeth-null.sh")" \
  "and without the /dev/null strip, the probe's own quiet-redirects WOULD be flagged"
notwant '.' "$(write_sites "$W/teeth-null.sh")" "while with the strip they are not"
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

# The gpio controllers, the clock controller and the three pinmux groups. Every node carries BOTH `phandle`
# and `linux,phandle`, as every node on this board does -- that pair is the trap the phandle mutation
# targets.
ctls_nodes() {
  C="$FR/proc/device-tree/soc/pinctrl@01010000"
  dtp "$C/compatible" 'qcom,msm8996-pinctrl'
  dtu32p "$C/#gpio-cells" '\000\000\000\002'
  dtu32p "$C/phandle" '\000\000\000\034'
  dtu32p "$C/linux,phandle" '\000\000\000\034'
  # The pinmux groups, NAMED FOR THIS BLOCK'S PINS -- and the names are a reading, because the driver looks
  # its states up BY STRING: silabs_fm_pinctrl_init() asks for "pmx_fm_active"/"pmx_fm_suspend". Each state
  # gets its own phandle (252..257, as the tree writes them), because a shared one would resolve as
  # AMBIGUOUS and `pinctrl-1` would not resolve at all.
  _ct_i=0
  for st in active suspend; do
    for g in pmx_fm_int/fm_int pmx_fm_status/fm_status_int pmx_fm_rst/fm_rst; do
      _ct_ph=$((252 + _ct_i)); _ct_i=$((_ct_i + 1))
      dtu32p "$C/$g/$st/phandle" "$(printf '\\000\\000\\000\\%03o' "$_ct_ph")"
      dtu32p "$C/$g/$st/linux,phandle" "$(printf '\\000\\000\\000\\%03o' "$_ct_ph")"
    done
  done
  P="$FR/proc/device-tree/soc/qcom,spmi@400f000/qcom/pm8994@0/gpios"
  dtp "$P/compatible" 'qcom,qpnp-pin'
  dtu32p "$P/#gpio-cells" '\000\000\000\002'
  dtu32p "$P/phandle" '\000\000\000\035'
  dtu32p "$P/linux,phandle" '\000\000\000\035'
  dtp "$P/label" 'pm8994-gpio'
  G="$FR/proc/device-tree/soc/qcom,gcc@300000"
  dtp "$G/compatible" 'qcom,gcc-8996-v3'
  dtu32p "$G/phandle" '\000\000\000\112'
  dtu32p "$G/linux,phandle" '\000\000\000\112'
}
# THE TWO SUPPLIES, one of each kind. `rome_vreg` is a `regulator-fixed` -- a PMIC GPIO driving a fixed
# supply -- and `pm8994_s4` is an RPM-controlled rail. That difference is the reading the supply section
# exists for, so both are fixtures rather than one.
supplies_nodes() {
  V="$FR/proc/device-tree/soc/rome_vreg"
  dtp "$V/compatible" 'regulator-fixed'
  dtp "$V/regulator-name" 'rome_vreg'
  dtu32p "$V/enable-active-high" ''
  dtu32p "$V/gpio" '\000\000\000\035\000\000\000\011\000\000\000\000'
  dtu32p "$V/startup-delay-us" '\000\000\017\240'
  dtu32p "$V/phandle" '\000\000\000\373'
  dtu32p "$V/linux,phandle" '\000\000\000\373'
  R="$FR/proc/device-tree/soc/qcom,rpm-smd/rpm-regulator-smpa4/regulator-s4"
  dtp "$R/compatible" 'qcom,rpm-smd-regulator'
  dtp "$R/regulator-name" 'pm8994_s4'
  # 1800000 uV = 0x001B7740, written as the four big-endian bytes it is (the same value the FM node's
  # silabs,vdd-supply-voltage carries, so the two readings agree as they do on the real tree).
  dtu32p "$R/regulator-min-microvolt" '\000\033\167\100'
  dtu32p "$R/regulator-max-microvolt" '\000\033\167\100'
  dtp "$R/status" 'okay'
  dtu32p "$R/phandle" '\000\000\000\372'
  dtu32p "$R/linux,phandle" '\000\000\000\372'
}
# THE BUS, which is a node of its own because the CLIENT's existence depends on it.
i2c_bus_node() {
  B="$FR/proc/device-tree/soc/i2c@75b5000"
  dtp "$B/compatible" 'qcom,i2c-msm-v2'
  dtu32p "$B/reg" '\000\007\133\000\000\000\020\000'
  dtp "$FR/proc/device-tree/aliases/i2c7" '/soc/i2c@75b5000'
  # ANOTHER BLOCK ON THE SAME BUS: the CC-logic node, which is its own row of the gap list. It is here so
  # that "what is on this bus" is a reading with more than one answer.
  O="$B/cclogic_dev@3d"
  dtp "$O/compatible" 'cypress,cyccg'
  dtu32p "$O/cc1_pwr_gpio" '\000\000\000\034\000\000\000\074\000\000\000\000'
}
# THE FM NODE, with the real cells read out of the 15 LE_ZL1 trees. Its `status` is written by the scenario,
# not here, because that property is what the scenarios are about.
fm_node() {
  N="$FR/proc/device-tree/soc/i2c@75b5000/silabs4705@11"
  dtp "$N/compatible" 'silabs,si4705'
  # reg = 17 (0x11), one cell -- and 0x11 is what makes the client's sysfs name `7-0011`, because the kernel
  # formats it `%d-%04x`.
  dtu32p "$N/reg" '\000\000\000\021'
  dtu32p "$N/silabs,reset-gpio" '\000\000\000\034\000\000\000\047\000\000\000\000'
  dtu32p "$N/silabs,int-gpio" '\000\000\000\034\000\000\000\046\000\000\000\000'
  dtu32p "$N/silabs,status-gpio" '\000\000\000\034\000\000\000\116\000\000\000\000'
  dtu32p "$N/interrupt-parent" '\000\000\000\034'
  dtu32p "$N/interrupts" '\000\000\000\000\000\000\000\001'
  dtlistp "$N/interrupt-names" 'silabs_fm_int\000silabs_status_int\000'
  # The interrupt-map that routes child irq 0 -> TLMM gpio 38 (flag 2, edge falling) and child irq 1 -> TLMM
  # gpio 78 (flag 1, edge rising): the SAME two pins the driver reads as its own gpios.
  dtu32p "$N/interrupt-map" '\000\000\000\000\000\000\000\034\000\000\000\046\000\000\000\002\000\000\000\001\000\000\000\034\000\000\000\116\000\000\000\001'
  dtu32p "$N/interrupt-map-mask" '\377\377\377\377'
  dtu32p "$N/va-supply" '\000\000\000\373'
  # 3300000 uV = 0x00325AA0 and 1800000 uV = 0x001B7740, each as the four big-endian bytes it is.
  dtu32p "$N/silabs,va-supply-voltage" '\000\062\132\240\000\062\132\240'
  dtu32p "$N/vdd-supply" '\000\000\000\372'
  dtu32p "$N/silabs,vdd-supply-voltage" '\000\033\167\100\000\033\167\100'
  dtlistp "$N/pinctrl-names" 'pmx_fm_active\000pmx_fm_suspend\000'
  dtu32p "$N/pinctrl-0" '\000\000\000\374\000\000\000\375\000\000\000\376'
  dtu32p "$N/pinctrl-1" '\000\000\000\377\000\000\000\400\000\000\000\401'
}

# The kernel configs. THE POINT OF THESE is that `CONFIG_RADIO_SILABS=y` is in BOTH of this project's
# kernels, so the tempting explanation for this block ("the driver is not built") is wrong on the board --
# and the chain around it is a REAL chain, unlike the `nfc` block's option outside its menu.
# THE PARENTS WITHOUT THE OPTION, because `config_off` needs the option's own line to be the ONLY one
# carrying that symbol: a fixture that wrote `CONFIG_RADIO_SILABS=y` and then `# ... is not set` would make
# cfg_opt's match two lines, and "two lines" is neither state.
config_parents_body() {
  printf 'CONFIG_IKCONFIG=y\n'
  printf 'CONFIG_IKCONFIG_PROC=y\n'
  printf 'CONFIG_I2C=y\n'
  printf 'CONFIG_I2C_MSM_V2=y\n'
  printf 'CONFIG_MEDIA_SUPPORT=y\n'
  printf 'CONFIG_MEDIA_RADIO_SUPPORT=y\n'
  printf 'CONFIG_VIDEO_DEV=y\n'
  printf 'CONFIG_VIDEO_V4L2=y\n'
  printf 'CONFIG_RADIO_ADAPTERS=y\n'
}
config_full() {
  { printf '# Automatically generated file; DO NOT EDIT.\n'
    printf 'Linux/arm64 3.18.140 Kernel Configuration\n'
    config_parents_body
    printf 'CONFIG_RADIO_SILABS=y\n'; } > "$W/kernel.config"
}
config_off() { # the option itself off with every parent on -- a state the board is NOT in
  { config_parents_body
    printf '# CONFIG_RADIO_SILABS is not set\n'; } > "$W/kernel.config"
}
config_parent_off() { # a parent off while the option reads on -- which Kconfig would not build
  { printf 'CONFIG_IKCONFIG=y\n'
    printf 'CONFIG_IKCONFIG_PROC=y\n'
    printf 'CONFIG_I2C=y\n'
    printf 'CONFIG_MEDIA_SUPPORT=y\n'
    printf 'CONFIG_MEDIA_RADIO_SUPPORT=y\n'
    printf 'CONFIG_VIDEO_DEV=y\n'
    printf 'CONFIG_VIDEO_V4L2=y\n'
    printf '# CONFIG_RADIO_ADAPTERS is not set\n'
    printf 'CONFIG_RADIO_SILABS=y\n'; } > "$W/kernel.config"
}
config_nokey() { # the symbol absent from the file entirely
  { printf 'CONFIG_IKCONFIG=y\n'
    printf 'CONFIG_IKCONFIG_PROC=y\n'
    printf 'CONFIG_MEDIA_SUPPORT=y\n'
    printf 'CONFIG_MEDIA_RADIO_SUPPORT=y\n'
    printf 'CONFIG_VIDEO_V4L2=y\n'
    printf 'CONFIG_RADIO_ADAPTERS=y\n'; } > "$W/kernel.config"
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
# the v4l2 radio device.
client_present() { # $1 = the client's sysfs name
  mkdir -p "$FR/sys/bus/i2c/devices/$1"
  printf '%s\n' "$1" > "$FR/sys/bus/i2c/devices/$1/name"
  printf 'of:Nsilabs4705T<NULL>Csilabs,si4705\n' > "$FR/sys/bus/i2c/devices/$1/modalias"
}
driver_registered() {
  mkdir -p "$FR/sys/bus/i2c/drivers/silabs-fm"
  : > "$FR/sys/bus/i2c/drivers/silabs-fm/bind"
  : > "$FR/sys/bus/i2c/drivers/silabs-fm/unbind"
  : > "$FR/sys/bus/i2c/drivers/silabs-fm/uevent"
}
bind_client() { ln -sfn "$FR/sys/bus/i2c/devices/$1" "$FR/sys/bus/i2c/drivers/silabs-fm/$1"; }
# A v4l2 device: the DIRECTORY is the allocated number, and the `name` FILE is the identity. `debug` is the
# one writable attribute this block has, and it is written here with a value so that a probe echoing it would
# be visible.
video_device() { # $1 = directory name, $2 = the vdev name, $3 = index
  mkdir -p "$FR/sys/class/video4linux/$1"
  printf '%s\n' "$2" > "$FR/sys/class/video4linux/$1/name"
  printf '81:%s\n' "$3" > "$FR/sys/class/video4linux/$1/dev"
  printf '%s\n' "$3" > "$FR/sys/class/video4linux/$1/index"
  printf '0\n' > "$FR/sys/class/video4linux/$1/debug"
}

scen() {
  SCEN="$1"
  rm -rf "$FR"
  mkdir -p "$FR/proc/sys/kernel/random" "$FR/proc/device-tree/soc" "$FR/proc/device-tree/aliases" \
    "$FR/sys/bus/i2c/drivers" "$FR/sys/bus/i2c/devices" "$FR/sys/bus/platform/drivers" \
    "$FR/sys/bus/platform/devices" "$FR/sys/class/video4linux" "$FR/dev"

  printf '%s\0' "$MODEL_ZL1" > "$FR/proc/device-tree/model"
  printf 'qcom,msm8996-mtp\0qcom,msm8996\0qcom,mtp\0' > "$FR/proc/device-tree/compatible"
  printf '11111111-2222-3333-4444-555555555555\n' > "$FR/proc/sys/kernel/random/boot_id"
  printf '1234.56 5678.90\n' > "$FR/proc/uptime"
  printf 'Linux version 3.18.140 (build@zl1) #1 SMP\n' > "$FR/proc/version"

  CONFIGFILE="$W/kernel.config"
  CFGMODE=readable
  case "$SCEN" in
  config-off) config_off ;;
  config-parent-off) config_parent_off ;;
  config-nokey) config_nokey ;;
  *) config_full ;;
  esac
  case "$SCEN" in
  no-config) rm -f "$FR/proc/config.gz" ;;
  config-unreadable) CFGMODE=unreadable; cp "$W/kernel.config" "$FR/proc/config.gz" ;;
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
  no-fm-node) i2c_bus_node; ctls_nodes; supplies_nodes ;;
  *) i2c_bus_node; fm_node; ctls_nodes; supplies_nodes ;;
  esac
  N="$FR/proc/device-tree/soc/i2c@75b5000/silabs4705@11"
  # THE STATUS IS THE SCENARIO. The board's own tree says `disabled`; `node-enabled` is the fixture's
  # counterfactual (a tree that leaves the node on), and `absent-status` is the third state -- no property at
  # all, which is what every OTHER block this project has probed carries.
  case "$SCEN" in
  bare-tree | no-fm-node | alien-node) : ;;
  node-disabled) dtp "$N/status" 'disabled' ;;
  absent-status) : ;;
  *) dtp "$N/status" 'okay' ;;
  esac
  case "$SCEN" in
  compatible-list) dtlistp "$N/compatible" 'silabs,fm-generic\000silabs,si4705\000' ;;
  bus-disabled) dtp "$FR/proc/device-tree/soc/i2c@75b5000/status" 'disabled' ;;
  no-alias) rm -f "$FR/proc/device-tree/aliases/i2c7" ;;
  reset-absent) rm -f "$N/silabs,reset-gpio" ;;
  int-absent) rm -f "$N/silabs,int-gpio" ;;
  status-absent) rm -f "$N/silabs,status-gpio" ;;
  gpio-short) dtu32p "$N/silabs,reset-gpio" '\000\000\000\034\000\000\000\047\000' ;;
  no-supply) rm -f "$N/va-supply" "$N/vdd-supply" ;;
  voltage-odd) dtu32p "$N/silabs,va-supply-voltage" '\000\062\140\140\000\062\140\140\000\000\000\000' ;;
  voltage-absent) rm -f "$N/silabs,vdd-supply-voltage" ;;
  pinctrl-renamed) dtlistp "$N/pinctrl-names" 'fm_active\000fm_suspend\000' ;;
  esac
  if [ "$SCEN" = alien-node ]; then dtp "$N/compatible" 'ti,fm-generic'; fi

  # ---- the run-time side, from three questions: what the CORE makes (the client), what the DRIVER makes (a
  # directory when it registers, a symlink when its probe returns 0), and what the probe's own END makes (the
  # registered v4l2 radio device).
  CLIENT_SYSFS=""; REG=yes; BIND=yes; RADIODEV=yes
  case "$SCEN" in
  bare-tree | alien-node | no-fm-node) REG=no; BIND=no; RADIODEV=no ;;
  # the tree refuses the node: no client -- while the DRIVER IS REGISTERED, which is what makes the rung
  # order a check rather than a coincidence
  node-disabled) BIND=no; RADIODEV=no ;;
  bus-disabled | no-client) BIND=no; RADIODEV=no ;;
  # the fatal reads, and the two-cell voltage rule
  reset-absent | int-absent | gpio-short | voltage-odd | voltage-absent | driver-unbound) BIND=no; RADIODEV=no ;;
  no-radio-dev | no-video4linux) RADIODEV=no ;;
  no-config | config-unreadable | config-nokey | config-off | config-parent-off | \
    driver-not-registered) REG=no; BIND=no; RADIODEV=no ;;
  esac
  case "$SCEN" in
  bare-tree | alien-node | no-fm-node | node-disabled | bus-disabled | no-client) CLIENT_SYSFS="" ;;
  client-other-bus) CLIENT_SYSFS=6-0011 ;;
  *) CLIENT_SYSFS=7-0011 ;;
  esac
  # The bus driver's own directory, whenever there is a tree for it to bind: a state that has a CLIENT also
  # has a registered i2c adapter.
  case "$SCEN" in
  bare-tree) : ;;
  *)
    mkdir -p "$FR/sys/bus/platform/devices/75b5000.i2c" "$FR/sys/bus/platform/drivers/i2c-msm-v2"
    : > "$FR/sys/bus/platform/drivers/i2c-msm-v2/bind"
    ln -sfn "$FR/sys/bus/platform/devices/75b5000.i2c" "$FR/sys/bus/platform/drivers/i2c-msm-v2/75b5000.i2c"
    ;;
  esac
  [ -n "$CLIENT_SYSFS" ] && client_present "$CLIENT_SYSFS"
  [ "$REG" = yes ] && driver_registered
  [ "$BIND" = yes ] && bind_client "$CLIENT_SYSFS"
  # The v4l2 class. `radio-number` puts THIS block's device at radio3 with another device at radio0, so
  # identifying it by a number is a check that can fail: RADIO_NR is -1, so the number is an allocation.
  case "$SCEN" in
  bare-tree | alien-node | no-fm-node | no-video4linux) : ;;
  radio-number)
    [ "$RADIODEV" = yes ] && video_device radio3 radio-silabs 3
    video_device radio0 tuner-something 0
    ;;
  *) [ "$RADIODEV" = yes ] && video_device radio0 radio-silabs 0 ;;
  esac
  [ "$SCEN" = no-video4linux ] && rmdir "$FR/sys/class/video4linux"

  # The kernel log. `log-unreadable` makes BOTH readers fail -- the only honest way to reach "not read".
  LOGMODE=normal
  [ "$SCEN" = log-unreadable ] && LOGMODE=unreadable
  case "$SCEN" in
  log-failing)
    { printf '[    0.000000] Booting Linux on physical CPU 0x0\n'
      printf '[    1.200000] silabs-fm 7-0011: silabs-reset-gpio not provided in device tree\n'
      printf '[    1.200000] silabs-fm 7-0011: Parsing DT failed(-19)\n'
      printf '[   30.000000] random: crng init done\n'; } > "$W/kernel.log"
    ;;
  log-quiet)
    { printf '[    0.000000] Booting Linux on physical CPU 0x0\n'
      printf '[   30.000000] random: crng init done\n'; } > "$W/kernel.log"
    ;;
  log-unreadable) : > "$W/kernel.log" ;;
  *)
    # A boot in which the driver came up and the FM device registered. It also carries the v4l2 core's own
    # registration line, which is not this block's driver speaking.
    { printf '[    0.000000] Booting Linux on physical CPU 0x0\n'
      printf '[    1.150000] silabs-fm 7-0011: silabs_fm_pinctrl_init success\n'
      printf '[    1.160000] radio-silabs: registered v4l2 device\n'
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

# ==================================================================================================
echo "== 2. the probe's own pages =="
# ==================================================================================================
want '^# zl1 FM radio probe' "$(run --help)" "--help prints the probe's own header"
want 'THE TREE SWITCHES THIS NODE OFF, EXPLICITLY, IN EVERY SET' "$(run --help)" \
  "and the first of the six readings it is built around"
want 'AND THE OBVIOUS EXPLANATION IS WRONG' "$(run --help)" "and the explanation that is wrong"
want 'AND THE FOURTH NAME, WHICH IS THE ONE IN /dev' "$(run --help)" "and the four names, named in the header"
EX=$(run --explain)
nonempty "the explain page is not empty" "$EX"
want 'what each reading decides, and why it is this reading' "$EX" "--explain opens by saying what it is"
want '1\. THE TREE SWITCHES THIS NODE OFF\.' "$EX" "and gives the disabled status as the first reading"
want 'The i2c core never instantiates a node that is not okay' "$EX" "with the mechanism behind it"
want '2\. AND THE OBVIOUS EXPLANATION IS WRONG' "$EX" "and names the tempting wrong answer"
want 'in BOTH kernels in hand' "$EX" "with the config line both kernels really carry"
want 'mirror image of the .nfc. block' "$EX" "and the block it is the mirror image of"
want '3\. THIS OPTION IS GATED BY ITS MENU\.' "$EX" "and the fourth reading: the menu that DOES gate this one"
want '4\. THE NODE DESCRIBES ITS INTERRUPTS TWICE' "$EX" "and the interrupt described twice"
want '5\. THREE GPIOS, TWO FATAL, AND TWO REGULATORS, NEITHER FATAL\.' "$EX" "and the fatal/lenient split"
want '6\. THE WRITE-CLASS MOVE IS OPENING THE DEVICE\.' "$EX" "and the write-class move"
want 'si470x' "$EX" "and the driver that can never bind this node"
want 'WHAT THIS CANNOT SAY: whether FM radio works' "$EX" "and what the probe does not claim"
notwant '== verdict:' "$EX" "and it prints the page and NO verdict (nothing was read)"
# `--explain` reads nothing, so it must work where there is nothing to read -- the device-tree guard runs
# after it on purpose.
scen no-device-tree
want 'THE TREE SWITCHES THIS NODE OFF' "$(run --explain)" \
  "and the explain page still prints with no device tree to read (the guard runs after it)"
rc_is 0 "$(run_rc --explain)"
want 'here -- refusing \(this probe reads the device tree\)' "$(run)" "while a report with no device tree refuses"
rc_is 2 "$(run_rc)"
# --quiet is a documented mode, and an untested flag is a claim nobody checked.
scen node-enabled
OUT=$(run --quiet)
want '== verdict: radio-registered' "$OUT" "--quiet still prints the verdict"
want '1\. the i2c client .*7-0011: PRESENT' "$OUT" "and the witness the rung rests on"
notwant 'other properties on this node' "$OUT" "while dropping the per-node property dump"

# ==================================================================================================
echo "== 3. board-first: which tree is this, before any hardware =="
# ==================================================================================================
scen node-enabled
OUT=$(run)
nonempty "the report is not empty" "$OUT"
want 'model: +Letv Technologies, Inc. MSM 8996pro \+ PMI8996 LE_ZL1-DVT1' "$OUT" "a zl1 tree is named by its model"
want 'board: +LE_ZL1 -- this phone' "$OUT" "and read as this phone"
want 'kernel: +Linux version 3.18.140' "$OUT" "the running kernel is named"
want 'boot id: +11111111-2222-3333-4444-555555555555' "$OUT" "and the boot the readings belong to"

scen x2-tree
OUT=$(run)
want '== verdict: wrong-board-tree' "$OUT" "the X2's device tree is its own rung, checked before any hardware"
want 'the FM node is at the same path in both' "$OUT" "naming why the tree's shape cannot tell them apart"
want 'only .model. can' "$OUT" "and what can"

scen unknown-model
OUT=$(run)
want '== verdict: unknown-board' "$OUT" "a model that names neither board is not attributed to this phone"
want 'model: +Letv Technologies, Inc. LE_UNKNOWN-XYZ' "$OUT" "with the model it did read printed"

scen no-model
OUT=$(run)
want '== verdict: unknown-board' "$OUT" "an unreadable model reaches the same rung, not a crash"
want 'model: +absent' "$OUT" "and is printed as absent rather than as neither"
want 'could not be read' "$OUT" "with the sentence that says why the attribution cannot be made"

# ==================================================================================================
echo "== 4. THE READING THIS BLOCK IS ABOUT: the tree switches its own node off =="
# ==================================================================================================
# The board's own tree, byte for byte: status = disabled, with the driver registered (which is what the
# v63 kernel's CONFIG_RADIO_SILABS=y means) and no client.
scen node-disabled
OUT=$(run)
want '/soc/i2c@75b5000/silabs4705@11' "$OUT" "the FM node is read by its path, not assumed"
want 'compatible: +silabs,si4705' "$OUT" "with the compatible the driver matches on"
want 'status: +disabled' "$OUT" "and the status the BOARD's own tree carries"
want 'AND THIS IS THE WHOLE ANSWER FOR THIS BLOCK' "$OUT" "which is named as the whole answer"
want 'NO BUILD OPTION CAN CHANGE THAT' "$OUT" "including that no build option would change it"
want 'Every other' "$OUT" "and the contrast with the other nodes this project has read (the sentence wraps, so it is matched in pieces)"
want 'node this project has instrumented declares no status at all' "$OUT" "in the half that carries the point"
want '== verdict: no-node-enabled' "$OUT" "so the rung is the node being switched off"
want 'THE DEVICE TREE SWITCHES THIS BLOCK OFF' "$OUT" "and the verdict's first words say so"
want 'CONFIG_RADIO_SILABS is y \(built in\)' "$OUT" "with the config quoted as evidence it is NOT a build problem"
want 'the same node exists in all 15 of this phone.s trees' "$OUT" "and that the node is in every one of its trees"
want 'the opposite kind of move from the config line another block on this board needs' "$OUT" \
  "and the contrast with the block whose fix IS a config line"
want '1\. the i2c client .*7-0011: ABSENT' "$OUT" "the first witness is absent"
want 'THAT IS THE EXPECTED READING AND NOT A FAULT OF THE BUS' "$OUT" "and is named as expected rather than as a bus fault"
want 'i2c/drivers/silabs-fm: present, bound: NONE' "$OUT" \
  "while the driver IS registered -- so the rung order, not the driver, is what answered"
want 'NONE of them reads .radio-silabs.' "$OUT" "and the v4l2 class is walked and read as containing no FM device"
rc_is 1 "$(run_rc)"

# The counterfactual: the same tree with the node left on. This is what every other rung is read against,
# and it is what proves the status rung is not standing in for something else.
scen node-enabled
OUT=$(run)
want 'status: +okay' "$OUT" "a tree that leaves the node on prints that status"
want '== verdict: radio-registered' "$OUT" "and reaches the top rung"
want 'driver: +silabs-fm ' "$OUT" "with the driver's directory name -- the one sysfs is keyed by"
want 'by of_match "silabs,si4705" \(its i2c_device_id is "radio-silabs" and its VIDEO DEVICE is also named "radio-silabs"\)' "$OUT" \
  "and all four names of the block on one line"
want '/sys/bus/i2c/drivers/silabs-fm: present, bound: 7-0011' "$OUT" "the driver is registered and bound"
want '1\. the i2c client .*7-0011: PRESENT' "$OUT" "the FIRST witness is present"
want 'it is under EXACTLY the name derived above \(bus i2c7, address 0011\)' "$OUT" \
  "under exactly the name the alias and reg predict"
want 'name=radio-silabs' "$OUT" "the THIRD witness is the v4l2 device, found by its NAME"
want 'AND radio0 IS THIS BLOCK.S' "$OUT" "with the identity stated"
want 'the DIRECTORY is a number v4l2 allocated' "$OUT" "and the number named as an allocation"
want 'RADIO_NR is -1 in this driver' "$OUT" "with the reason the number cannot be the identity"
want 'video_register_device\(\) is the LAST thing silabs_fm_probe\(\) does' "$OUT" \
  "and the reason this witness is the strongest one"
want 'THE NESTING IS THE READING' "$OUT" "the nesting is stated where the witnesses are"
want 'AND THE CHIP IS STILL POWERED DOWN, WHICH IS NOT A FAULT' "$OUT" \
  "with the chip's power state named even on the top rung"
want 'silabs_fm_fops_open\(\)' "$OUT" "and the function that would power it, named as not called"
want 'WHAT THIS IS NOT: an answer to .does FM radio work.' "$OUT" "and what the top rung does not claim"
rc_is 0 "$(run_rc)"

# The third state: NO status property at all, which is what every other block on this board carries.
scen absent-status
OUT=$(run)
want 'status: +absent \(an absent status means enabled; this node carries none\)' "$OUT" \
  "a node with no status at all is read as enabled, and the probe says which way round it read it"
want '== verdict: radio-registered' "$OUT" "so it reaches the top rung"

# A node found through a LATER entry of its compatible list.
scen compatible-list
OUT=$(run)
want 'compatible: +silabs,fm-generic silabs,si4705 ' "$OUT" "a compatible list is printed whole"
want '== verdict: radio-registered' "$OUT" "and a node found through a LATER entry is treated as the block"

# ==================================================================================================
echo "== 5. the config chain, and why it is NOT this block's problem =="
# ==================================================================================================
scen node-enabled
OUT=$(run)
want 'CONFIG_MEDIA_RADIO_SUPPORT +y \(built in\)' "$OUT" "the chain's first parent is read"
want 'CONFIG_VIDEO_V4L2 +y \(built in\)' "$OUT" "and the second"
want 'CONFIG_RADIO_ADAPTERS +y \(built in\)' "$OUT" "and the menuconfig"
want 'CONFIG_RADIO_SILABS +y \(built in\)' "$OUT" "and the option itself"
want 'AND THIS OPTION IS GATED BY ITS MENU, UNLIKE THE ONE IN THE BLOCK NEXT DOOR' "$OUT" \
  "and the probe says this one IS gated by its menu"
want 'sits INSIDE .if RADIO_ADAPTERS && VIDEO_V4L2.' "$OUT" "naming the place in Kconfig"
want 'every parent in the chain has to be on, which is why four lines are' "$OUT" \
  "and why four lines are printed rather than one"
want 'config NFC_NQ. sits AFTER the' "$OUT" "and the contrast with the option that does not (the sentence wraps)"
want 'endmenu of the menu that depends on NFC' "$OUT" "in the half that carries the point"
want 'AND ON THIS BOARD THE WHOLE CHAIN IS ON' "$OUT" "and the board's own answer"
want 'is WRONG, and no build option would change anything' "$OUT" "including that the tempting explanation is wrong"
want 'config.gz: yes present / yes permission-readable / yes expanded' "$OUT" \
  "the config file's three facts are printed separately"

# The option off with every parent on: the rung the board is NOT on, and the one the mutation targets.
scen config-off
OUT=$(run)
want 'CONFIG_RADIO_SILABS +NOT SET' "$OUT" "the option off is printed as NOT SET"
want 'CONFIG_RADIO_ADAPTERS +y \(built in\)' "$OUT" "while its menuconfig is on -- so the rung is about the option"
want '== verdict: driver-not-built' "$OUT" "and that is its own rung"
want 'THE KERNEL.S OWN CONFIG DOES NOT BUILD IT' "$OUT" "with the cause named as the config"
want 'Check the CHAIN above before believing it' "$OUT" "and a warning to read the chain, not the one line"
want 'if the device reports this rung the config being read is not the one the kernel booted with' "$OUT" \
  "plus the reading that would make this rung suspicious on this board"

# A parent off while the option reads on -- which Kconfig would not produce, but a config we did not write
# can.
scen config-parent-off
OUT=$(run)
want 'CONFIG_RADIO_ADAPTERS +NOT SET' "$OUT" "a parent off is printed"
want 'CONFIG_RADIO_SILABS +y \(built in\)' "$OUT" "while the option reads on"
want '== verdict: driver-not-registered' "$OUT" "and the verdict does NOT blame the option, because the option is on"
notwant 'driver-not-built' "$OUT" "so it never says the kernel does not build it"

scen config-nokey
OUT=$(run)
want 'CONFIG_RADIO_SILABS +absent from the config' "$OUT" "a config without the symbol says so"
want '== verdict: driver-not-built' "$OUT" "and is still a kernel that does not build the driver"

scen no-config
OUT=$(run)
want 'config.gz: no present / no permission-readable / no expanded' "$OUT" "a missing config file is named as missing"
want 'the kernel config could NOT be read' "$OUT" "and is printed as a state of its own"
want 'CONFIG_RADIO_SILABS +NOT READ' "$OUT" "so the column says NOT READ rather than NOT SET"
want '== verdict: driver-not-registered' "$OUT" "and the verdict does not claim the kernel cannot build it"
notwant 'driver-not-built' "$OUT" "and never the rung that blames a config line nobody read"

scen config-unreadable
OUT=$(run)
want 'config.gz: yes present / yes permission-readable / no expanded' "$OUT" \
  "a config that is present and unexpandable says exactly that"
want 'CONFIG_RADIO_SILABS +NOT READ' "$OUT" "and its column is NOT READ all the same"
want 'the verdict below rests on it and' "$OUT" "with the verdict's basis named"

# ==================================================================================================
echo "== 6. the node's own reads: gpios, interrupts, supplies, pinctrl =="
# ==================================================================================================
scen node-enabled
OUT=$(run)
want 'silabs,reset-gpio +phandle 28 = /soc/pinctrl@01010000, gpio 39, active high' "$OUT" \
  "the reset gpio resolves to the TLMM controller"
want 'silabs,int-gpio +phandle 28 = /soc/pinctrl@01010000, gpio 38' "$OUT" "and the interrupt pin"
want 'silabs,status-gpio +phandle 28 = /soc/pinctrl@01010000, gpio 78' "$OUT" "and the status pin"
want 'FATAL IN THE STRONGEST WAY' "$OUT" "the reset gpio is named fatal in the driver's own way"
want 'the driver returns the GPIO.S OWN NEGATIVE' "$OUT" "including that the driver returns the gpio's errno"
want 'OPTIONAL: a missing one is a FMDERR' "$OUT" "and the status gpio is named optional"
want 'the tree on the FATAL reads: NONE MISSING -- the two fatal gpios are present and valid' "$OUT" \
  "the fatal reads are summarised as present"
want 'interrupts +\[u32 cells: 0 1 \]' "$OUT" "the interrupts are read as cells, not as text"
want 'interrupt-names: silabs_fm_int silabs_status_int' "$OUT" "and the interrupt names as strings"
want 'interrupt-parent +\[u32 cells: 28 \]' "$OUT" "and the parent cell as a number"
want 'THE DRIVER' "$OUT" "and the interrupt-map is named as something no driver acts on"
want 'ACT.*S ON NEITHER' "$OUT" "in the half that says it is ignored"
want 'it ignores interrupt-map and calls gpio_to_irq' "$OUT" "with the mechanism the driver uses instead"
# The two supplies: one fixed regulator (a gpio switch) and one RPM rail -- the difference is the reading.
want 'va-supply +phandle 251 = /soc/rome_vreg \(label rome_vreg\)' "$OUT" \
  "the analog supply resolves to its own node, named by its regulator-name"
want 'A FIXED REGULATOR, i.e. a GPIO SWITCH RATHER THAN A RAIL' "$OUT" \
  "and a fixed regulator is named as a gpio switch"
want 'gpio = phandle 29 = .*pm8994-gpio., gpio 9, active high' "$OUT" "with the PMIC gpio it is driven by"
want 'enable-active-high is PRESENT \(a boolean\)' "$OUT" "and the polarity it is driven with"
want 'startup-delay-us: 4000' "$OUT" "and the delay the driver must wait"
want 'vdd-supply +phandle 250 = .*regulator-s4 \(label pm8994_s4\)' "$OUT" "the digital supply resolves"
want 'AN RPM-CONTROLLED RAIL' "$OUT" "and an RPM rail is named as one"
want 'the RPM, not the CPU, owns the' "$OUT" "including that this supply cannot be read from the SoC"
want 'silabs,va-supply-voltage as EXACTLY TWO CELLS: 2 cells there' "$OUT" \
  "the voltage property's cell count is printed"
want 'and this tree has exactly that' "$OUT" "and the tree is said to satisfy it"
want 'AND NEITHER regulator IS FATAL, WHICH IS THE OPPOSITE OF THE GPIOS ABOVE' "$OUT" \
  "and the two supplies are named as NOT fatal"
want 'But the VOLTAGE' "$OUT" "with the property beside them named as the fatal half (the sentence wraps)"
want 'PROPERTY beside each one IS read as exactly two cells' "$OUT" "in the half that carries it"
# The pinmux groups, whose names the driver looks up BY STRING.
want 'pinctrl-names: pmx_fm_active pmx_fm_suspend ' "$OUT" "the pinmux names are read"
want 'pinctrl-0 \(the ACTIVE state\): +/soc/pinctrl@01010000/pmx_fm_int/fm_int/active, /soc/pinctrl@01010000/pmx_fm_status/fm_status_int/active, /soc/pinctrl@01010000/pmx_fm_rst/fm_rst/active' "$OUT" \
  "and all THREE cells of the active state are resolved"
want 'pinctrl-1 \(the suspend state\): /soc/pinctrl@01010000/pmx_fm_int/fm_int/suspend, /soc/pinctrl@01010000/pmx_fm_status/fm_status_int/suspend, /soc/pinctrl@01010000/pmx_fm_rst/fm_rst/suspend' "$OUT" \
  "and all THREE cells of the suspend state, so the two same-named groups of each pin are told apart"
want 'AN RPM-CONTROLLED RAIL: min \[u32 cells: 1800000 \] uV' "$OUT" \
  "and the RPM rail's own voltage is read out of its node, not assumed"
want 'LOOKS UP THESE TWO NAMES BY STRING' "$OUT" "and the probe says the driver matches them by string"
want 'pinctrl_lookup_state' "$OUT" "naming the call"
want 'that is NOT fatal either' "$OUT" "and that a mismatch is not fatal either"
# The bus, its alias, and the other block on it.
want '/soc/i2c@75b5000' "$OUT" "the bus node is read by its path"
want 'alias: +i2c7 -> bus 7, so the i2c core will name the client' "$OUT" "the alias gives the bus number"
want "'7-0011' -- and THAT name is what the witness section looks for" "$OUT" "and the client's name is derived from it"
want 'reg: +17 \(0x11\) -- the i2c slave address' "$OUT" "the address is read as a number"
want 'AND THIS BUS CARRIES ANOTHER BLOCK TOO: cclogic_dev@3d\(cypress,cyccg\)' "$OUT" \
  "the other node on the same bus is named, so 'what is on this bus' is not one device"

# ==================================================================================================
echo "== 7. the rungs, and the two readings that must NOT be fatal =="
# ==================================================================================================
scen reset-absent
OUT=$(run)
want 'silabs,reset-gpio +absent' "$OUT" "the fatal reset gpio missing is printed"
want 'the tree on the FATAL reads: silabs,reset-gpio' "$OUT" "and summarised"
want '== verdict: driver-not-bound' "$OUT" "which is why the driver is not bound"
want 'AND THE TREE ITSELF IS THE CAUSE: it is missing or invalid on silabs,reset-gpio' "$OUT" \
  "named in the verdict itself rather than only above"

scen int-absent
OUT=$(run)
want 'silabs,int-gpio +absent' "$OUT" "the interrupt pin missing is the other fatal read"
want 'the tree on the FATAL reads: silabs,int-gpio' "$OUT" "and is summarised the same way"

# A gpio property that is not a whole number of cells.
scen gpio-short
OUT=$(run)
want 'silabs,reset-gpio +not-a-gpio\(9 bytes\)' "$OUT" "a gpio that is not whole cells says so"
want 'the tree on the FATAL reads: silabs,reset-gpio' "$OUT" "and counts as a missing fatal read"
want '== verdict: driver-not-bound' "$OUT" "so the driver cannot bind"

# The three-cell voltage property: the read is EXACTLY two cells, so this fails.
scen voltage-odd
OUT=$(run)
want 'silabs,va-supply-voltage as EXACTLY TWO CELLS: 3 cells there' "$OUT" "three cells is printed as three"
want 'AND THIS IS NOT TWO CELLS' "$OUT" "and named as the failing case"
want 'TRUNCATED and a shorter one FAILS the -EINVAL check' "$OUT" "with the reason a longer property is silently truncated"
want 'the tree on the FATAL reads: silabs,va-supply-voltage \(3 cells\)' "$OUT" "and it counts among the fatal reads"

scen voltage-absent
OUT=$(run)
want 'silabs,vdd-supply-voltage as EXACTLY TWO CELLS: absent, 0 cells' "$OUT" \
  "an absent voltage property is printed as absent and as zero cells"
want 'ABSENT, and that is FATAL for this supply' "$OUT" "and named fatal for that supply"

# THE TWO LENIENT READS: the probe must stay on the top rung for both. A probe that treated either as fatal
# would report a dead block on a working one.
scen status-absent
OUT=$(run)
want 'silabs,status-gpio +absent' "$OUT" "the status gpio is printed as absent"
want 'the tree on the FATAL reads: NONE MISSING' "$OUT" "and is NOT counted among the fatal reads"
want '== verdict: radio-registered' "$OUT" "so a working chain with no status gpio is still the top rung"

scen no-supply
OUT=$(run)
want 'va-supply +absent -- the driver.s regulator_get\(\) fails and, for BOTH' "$OUT" \
  "a missing supply is printed as absent, with the reading that it is not fatal"
want 'the tree on the FATAL reads: NONE MISSING' "$OUT" "and is not counted among the fatal reads either"
want '== verdict: radio-registered' "$OUT" "so a working chain with no supplies is still the top rung"

# A pinmux name mismatch: the driver ends up with no pinctrl, which is NOT fatal either.
scen pinctrl-renamed
OUT=$(run)
want 'pinctrl-names: fm_active fm_suspend ' "$OUT" "renamed pinmux states are printed as read"
want 'that is NOT fatal either' "$OUT" "and the probe says the driver carries on"
want '== verdict: radio-registered' "$OUT" "so it does not stop the chain"

# The bus and the client rungs.
scen bus-disabled
OUT=$(run)
want 'status: +disabled' "$OUT" "the i2c bus's own status is printed"
want '== verdict: no-client' "$OUT" "a bus the tree switches off is its own rung"
want 'NO CONFIG LINE FOR THE FM DRIVER CAN FIX THIS' "$OUT" "and the probe says no config line can fix it"

scen no-client
OUT=$(run)
want '== verdict: no-client' "$OUT" "no client at all reaches the same rung"
want 'i2c/drivers/silabs-fm: present, bound: NONE' "$OUT" \
  "while the driver IS registered -- which is what makes the rung order a check"
want '1\. the i2c client .*7-0011: ABSENT' "$OUT" "and the client named as absent"

scen no-alias
OUT=$(run)
want 'alias: +none points at this controller' "$OUT" "a tree with no alias for this bus says so"
want 'looks for the ADDRESS instead' "$OUT" "and the probe falls back to the address"
want '1\. the i2c client .*7-0011: PRESENT' "$OUT" "so a client under an underivable bus number is FOUND"
want 'BUT NOT UNDER THE NAME DERIVED ABOVE' "$OUT" "and the probe says the name was not derivable"
want '== verdict: radio-registered' "$OUT" "so the rung does not stop on a missing alias"

scen client-other-bus
OUT=$(run)
want '1\. the i2c client .*6-0011: PRESENT' "$OUT" "a client under another bus number is found by its address"
want 'BUT NOT UNDER THE NAME DERIVED ABOVE: i2c7 gives bus 7' "$OUT" "and the derived bus number is named"
want 'The client exists; the ALIAS is what is wrong.' "$OUT" "with the cause attributed to the alias"
want '== verdict: radio-registered' "$OUT" "so a wrong bus number does not stop the ladder"

# The driver rungs.
scen driver-not-registered
OUT=$(run)
want '== verdict: driver-not-registered' "$OUT" "a missing driver directory with the option ON is its own rung"
want 'NOT attributed to a config line here' "$OUT" "and the verdict does not blame the config"
want 'CONFIG_RADIO_SILABS reads .y \(built in\).' "$OUT" "quoting the line that would have contradicted it"

scen driver-unbound
OUT=$(run)
want '== verdict: driver-not-bound' "$OUT" "a registered driver with nothing attached is its own rung"
want 'silabs_fm_probe\(\) fails on a missing silabs,reset-gpio or silabs,int-gpio' "$OUT" \
  "with the list of what makes THIS driver's probe fail"
want 'each is read as EXACTLY TWO CELLS' "$OUT" "including the two-cell voltage rule"
notwant 'AND THE TREE ITSELF IS THE CAUSE' "$OUT" \
  "and, on a tree with no fatal read missing, the verdict does not blame the tree"

scen no-radio-dev
OUT=$(run)
want '== verdict: no-radio-device' "$OUT" "a bound driver with no registered radio device is its own rung"
want 'video_register_device\(\) is the LAST thing the probe does' "$OUT" "with the probe's own end named"
want 'most likely one of the four workqueues' "$OUT" "and the steps before it"

scen no-video4linux
OUT=$(run)
want '3\. .*video4linux: ABSENT -- the v4l2 core registers that class itself at init' "$OUT" \
  "a kernel with no video4linux class says so"
want 'absence is about the KERNEL, not about this chip' "$OUT" "and attributes the absence to the kernel"
want '== verdict: no-radio-device' "$OUT" "reaching the same rung as a bound driver with no device"

# The identity of the radio device when it is NOT radio0.
scen radio-number
OUT=$(run)
want '3\. radio3: +name=radio-silabs +dev=81:3 +index=3' "$OUT" "this block's device is found at radio3 by its name"
want '3\. radio0: +name=tuner-something' "$OUT" "and another device at radio0 is printed without being mistaken for it"
want 'AND radio3 IS THIS BLOCK.S' "$OUT" "with radio3 named as this block's"
want '== verdict: radio-registered' "$OUT" "so the top rung is reached at radio3"

# The tree-level rungs, and the two searches that must not print the same way.
scen bare-tree
OUT=$(run)
want '== verdict: no-device-tree-node' "$OUT" "a tree with no nodes at all, searched with find, is an ABSENCE"
notwant 'tree-unscanned' "$OUT" "and not a search that could not run"

scen bare-tree
OUT=$(run_nofind)
want '== verdict: tree-unscanned' "$OUT" "the same tree with no find(1) is a search that could not run"
want "it is 'this probe" "$OUT" "and the probe says so in its own words (the sentence wraps)"
want 'could not look., and the two must not print the same way' "$OUT" "in the half that carries the point"
notwant 'no-device-tree-node' "$OUT" "and never printing as an absence"

scen alien-node
OUT=$(run)
want '== verdict: no-device-tree-node' "$OUT" "a node of the right shape with another compatible is an absence"
want 'On this board the node IS in all 15 of its trees' "$OUT" "with the reason that rung is surprising here"

scen alien-node
OUT=$(run_nofind)
want '== verdict: no-device-tree-node' "$OUT" "and with no find(1) it is STILL an absence, because the fallback walked"

scen no-fm-node
OUT=$(run)
want '== verdict: no-device-tree-node' "$OUT" "a tree that simply has no such node is the same rung"

# The kernel log: a failure, a silence, and a log that could not be read.
scen log-failing
OUT=$(run)
want 'source: dmesg' "$OUT" "the reader the log came from is named"
want 'silabs-reset-gpio not provided in device tree' "$OUT" "the driver's own failure strings are matched"
want 'Parsing DT failed' "$OUT" "including the parse failure"

scen log-quiet
OUT=$(run)
want '\(none: the kernel log mentions no FM driver this boot\)' "$OUT" \
  "a log with no FM line prints a NAMED silence rather than nothing"
want '\(none: no FM probe failure in this boot.s log\)' "$OUT" "and the failure scan is a named silence too"

scen log-unreadable
OUT=$(run)
want 'the kernel log could not be read' "$OUT" "a log that cannot be read is a state of its own"
want 'this section is NOT READ' "$OUT" "and is named rather than read as a silence"
want '== verdict: radio-registered' "$OUT" "so an unreadable log does not change the rung"

# ==================================================================================================
echo "== 8. the mutations: each one has to redden something =="
# ==================================================================================================
# 1. THIS BLOCK'S OWN DEFECT: the disabled status read as enabled. Every sibling probe guards against
#    treating an ABSENT status as off; here the tree really does switch the node off, so the mistake is the
#    opposite one and it makes the whole ladder blame the bus instead of the tree.
sed 's#^  okay | ok | EMPTY | absent) NODE_EN=yes ;;$#  okay | ok | EMPTY | absent | disabled) NODE_EN=yes ;;#' \
  "$SRC" > "$W/mut-disabled.sh"
if cmp -s "$SRC" "$W/mut-disabled.sh"; then bad "the disabled-status mutation did not apply"; else
  scen node-disabled
  OUT=$(mut_run "$W/mut-disabled.sh")
  notwant '== verdict: no-node-enabled' "$OUT" \
    "reading the tree's own 'disabled' as enabled loses the one rung this board is on (the mutation)"
  want '== verdict: no-client' "$OUT" "and moves the answer down the ladder, where it blames the i2c bus"
  want 'status: +disabled' "$OUT" "on a page that prints 'disabled' while reporting a client that cannot exist"
fi

# 2. The ABSENT status read as off -- the mistake the sibling blocks guard against, and here it is the one
#    that does NOT apply.
sed 's#^  okay | ok | EMPTY | absent) NODE_EN=yes ;;$#  okay | ok) NODE_EN=yes ;;#' "$SRC" > "$W/mut-absentstatus.sh"
if cmp -s "$SRC" "$W/mut-absentstatus.sh"; then bad "the absent-status mutation did not apply"; else
  scen absent-status
  OUT=$(mut_run "$W/mut-absentstatus.sh")
  notwant '== verdict: radio-registered' "$OUT" \
    "reading an absent status as off loses the top rung on a node the tree has enabled (the mutation)"
  want '== verdict: no-node-enabled' "$OUT" "and reports the tree as switching its own node off"
fi

# 3. The CLIENT rung dropped. The client is the i2c core's work, so a node that has no client cannot be
#    fixed by any driver or config line -- which is why the ladder puts it above every driver rung.
sed 's#^elif \[ "\$CLIENT_FOUND" = no \]; then$#elif false; then#' "$SRC" > "$W/mut-clientrung.sh"
if cmp -s "$SRC" "$W/mut-clientrung.sh"; then bad "the client-rung mutation did not apply"; else
  scen no-client
  OUT=$(mut_run "$W/mut-clientrung.sh")
  notwant '== verdict: no-client' "$OUT" "dropping the client rung loses that answer (the mutation)"
  want '== verdict: driver-not-bound' "$OUT" \
    "and reports a driver that was never given a client as a driver whose probe failed"
  want 'the i2c client .*7-0011: ABSENT' "$OUT" \
    "while the same report says the client is absent -- the two readings disagree"
fi

# 4. The PARENT option read instead of the option. `RADIO_ADAPTERS` is the menuconfig that gates
#    `RADIO_SILABS`, so reading it gives the right answer on a healthy kernel and the wrong one wherever the
#    two differ -- which is exactly the mistake the `nfc` block's outside-the-menu option invites.
sed 's#^N_BUILT=$(cfg_opt CONFIG_RADIO_SILABS)$#N_BUILT=$(cfg_opt CONFIG_RADIO_ADAPTERS)#' \
  "$SRC" > "$W/mut-configparent.sh"
if cmp -s "$SRC" "$W/mut-configparent.sh"; then bad "the config-parent mutation did not apply"; else
  scen config-off
  OUT=$(mut_run "$W/mut-configparent.sh")
  notwant '== verdict: driver-not-built' "$OUT" \
    "reading the menuconfig instead of the option loses the config rung (the mutation)"
  want '== verdict: driver-not-registered' "$OUT" "and reports an option that is OFF as one that was on"
  scen config-parent-off
  OUT=$(mut_run "$W/mut-configparent.sh")
  want '== verdict: driver-not-built' "$OUT" \
    "while on a config whose menuconfig is off it blames the option -- the opposite error, in the same run"
fi

# 5. The two-cell voltage read. `of_property_read_u32_array(..., 2)` is EXACTLY two cells, so a three-cell
#    property is fatal even though the supply beside it is not.
sed "s#^      '2 cells') : ;;#      '2 cells' | '3 cells') : ;;#" "$SRC" > "$W/mut-voltage.sh"
if cmp -s "$SRC" "$W/mut-voltage.sh"; then bad "the voltage mutation did not apply"; else
  scen voltage-odd
  OUT=$(mut_run "$W/mut-voltage.sh")
  notwant 'AND THE TREE ITSELF IS THE CAUSE' "$OUT" \
    "accepting a third voltage cell stops the verdict naming the tree as the cause (the mutation)"
  want '3 cells there' "$OUT" \
    "while the page still prints three cells -- an odd property the probe no longer counts as one"
fi

# 6. The endianness. A device-tree u32 is four BIG-ENDIAN bytes and this SoC is little-endian, so `od -tu4`
#    prints 0x11 as 0x11000000: a plausible number, and the client's name comes out wrong.
sed 's#_u_a \* 16777216 + _u_b \* 65536 + _u_c \* 256 + _u_d#_u_d * 16777216 + _u_c * 65536 + _u_b * 256 + _u_a#' \
  "$SRC" > "$W/mut-endian.sh"
if cmp -s "$SRC" "$W/mut-endian.sh"; then bad "the endianness mutation did not apply"; else
  scen node-enabled
  OUT=$(mut_run "$W/mut-endian.sh")
  notwant 'reg: +17 \(0x11\)' "$OUT" "reading a big-endian cell in host order loses the address (the mutation)"
  want '== verdict: no-client' "$OUT" \
    "so a client that exists is looked for under a name that cannot exist, and the whole block reads as absent"
fi

# 7. Phandles counted per FILE instead of per NODE. Every node on this board carries BOTH `phandle` and
#    `linux,phandle`, so a resolver that counts files calls each real hit ambiguous with itself.
sed '/_ph_seen" in/d' "$SRC" > "$W/mut-phandle.sh"
if cmp -s "$SRC" "$W/mut-phandle.sh"; then bad "the phandle mutation did not apply"; else
  scen node-enabled
  OUT=$(mut_run "$W/mut-phandle.sh")
  notwant 'phandle 28 = /soc/pinctrl@01010000, gpio 39' "$OUT" \
    "counting phandle FILES turns one node's two names into an ambiguity (the mutation)"
  want 'phandle 28 = AMBIGUOUS\(2\)' "$OUT" "and a controller that resolves reads as ambiguous"
fi

# 8. The driver's name taken from the WRONG one of the four. `radio-silabs` is the i2c_device_id and the
#    v4l2 device name, and it is NOT the name sysfs keys the driver's directory on.
sed "s#^    printf 'silabs-fm\\\\tCONFIG_RADIO_SILABS#    printf 'radio-silabs\\\\tCONFIG_RADIO_SILABS#" \
  "$SRC" > "$W/mut-drvname.sh"
if cmp -s "$SRC" "$W/mut-drvname.sh"; then bad "the driver-name mutation did not apply"; else
  scen node-enabled
  OUT=$(mut_run "$W/mut-drvname.sh")
  notwant 'driver: +silabs-fm ' "$OUT" \
    "looking the driver up under its id_table name loses the name sysfs is keyed by (the mutation)"
  want 'driver: +radio-silabs ' "$OUT" "and prints the name the v4l2 device carries"
  want '== verdict: driver-not-registered' "$OUT" "so a registered driver reads as one that never registered"
  want 'i2c/devices/7-0011: PRESENT' "$OUT" \
    "while the client is still there, so the two readings DISAGREE -- which is the shape of the defect"
fi

# 9. "Could not search" collapsed into "not found". The one state that must never print like an absence.
sed 's#^  return 2$#  return 1#' "$SRC" > "$W/mut-scan.sh"
if cmp -s "$SRC" "$W/mut-scan.sh"; then bad "the scan mutation did not apply"; else
  scen bare-tree
  OUT=$(mut_run "$W/mut-scan.sh" nofind)
  notwant '== verdict: tree-unscanned' "$OUT" "collapsing could-not-search into not-found loses that state (the mutation)"
  want '== verdict: no-device-tree-node' "$OUT" "and prints an absence the probe cannot support"
fi

# 10. The compatible LIST read as one string. This node's compatible is a list, and the scan matches any
#     entry -- so a report that printed only the first would contradict its own ladder.
sed 's#\$(dtlist "\$NODE/compatible")#$(dtstr "$NODE/compatible")#' "$SRC" > "$W/mut-compat.sh"
if cmp -s "$SRC" "$W/mut-compat.sh"; then bad "the compatible mutation did not apply"; else
  scen compatible-list
  OUT=$(mut_run "$W/mut-compat.sh")
  notwant 'compatible: +silabs,fm-generic silabs,si4705' "$OUT" \
    "reading a compatible LIST as one string loses the entry after the first (the mutation)"
  want 'compatible: +silabs,fm-generic' "$OUT" "and prints a node whose matching entry is invisible"
  want '== verdict: radio-registered' "$OUT" \
    "while the ladder still reaches the top rung through that very entry"
fi

# 11. The radio device looked for by its NUMBER. RADIO_NR is -1, so the number is an allocation -- and on a
#     device where something else registered first, the block's device is not at radio0 at all.
sed 's#^  for _v in /sys/class/video4linux/\*; do$#  for _v in /sys/class/video4linux/radio0; do#' \
  "$SRC" > "$W/mut-byNumber.sh"
if cmp -s "$SRC" "$W/mut-byNumber.sh"; then bad "the by-number mutation did not apply"; else
  scen radio-number
  OUT=$(mut_run "$W/mut-byNumber.sh")
  notwant '== verdict: radio-registered' "$OUT" \
    "looking for the radio device by number loses it when the allocation moved (the mutation)"
  want '== verdict: no-radio-device' "$OUT" "and reports a registered device as unregistered"
fi

# 12. The last RUNG dropped: the radio device assumed rather than looked for.
sed 's#^elif \[ "\$RADIO_FOUND" = no \]; then$#elif false; then#' "$SRC" > "$W/mut-lastrung.sh"
if cmp -s "$SRC" "$W/mut-lastrung.sh"; then bad "the radio-rung mutation did not apply"; else
  scen no-radio-dev
  OUT=$(mut_run "$W/mut-lastrung.sh")
  notwant '== verdict: no-radio-device' "$OUT" "dropping the last rung loses the answer (the mutation)"
  want '== verdict: radio-registered' "$OUT" \
    "and reports a probe that stopped before video_register_device() as one that finished"
  want 'NONE of them reads .radio-silabs.' "$OUT" \
    "while the same report says no such device is registered"
fi

# 13. The LENIENT gpio treated as fatal. `silabs,status-gpio` is optional (a FMDERR and the driver carries
#     on), so counting it among the fatal reads makes a working tree read as an incomplete one.
sed 's#^  for _fv in "silabs,va-supply-voltage" "silabs,vdd-supply-voltage"; do$#  for _fv in "silabs,status-gpio"; do#' \
  "$SRC" > "$W/mut-statusfatal.sh"
if cmp -s "$SRC" "$W/mut-statusfatal.sh"; then bad "the status-fatal mutation did not apply"; else
  scen node-enabled
  OUT=$(mut_run "$W/mut-statusfatal.sh")
  notwant 'the tree on the FATAL reads: NONE MISSING' "$OUT" \
    "counting an optional gpio among the fatal reads loses that summary on a complete tree (the mutation)"
  want 'the tree on the FATAL reads: silabs,status-gpio \(3 cells\)' "$OUT" \
    "and reports a tree that carries the pin as one that is missing it"
fi

# ==================================================================================================
echo "== 9. this harness's own citation =="
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
    grep -oE 'zl1-fm-radio-probe-selftest\.sh[^0-9]*[0-9]+ checks' | sed -n 1p)
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
