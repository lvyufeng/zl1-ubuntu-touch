#!/usr/bin/env bash
# zl1 USB Type-C / CC-logic probe -- offline self-test. Host-side, touches no device, needs no phone.
#
# Why this exists. `scripts/device/zl1-usbpd-probe.sh` is the instrument for the `usb-pd` row of doc 137's
# gap list, and that row is not one device: it is a MENU of four CC-logic chips on two i2c buses plus two
# vendor "driver" nodes, and the tree enables exactly two of the six. Four readings make the probe's design,
# and each is a scenario below:
#
#   1. THE TREE ENABLES TWO NODES AND DISABLES FOUR, AND THE KERNEL BUILDS THE DRIVERS FOR THE FOUR.
#      `/soc/i2c@75b5000/tusb320@67` and `/soc/i2c@75b5000/cclogic_dev@3d` are `status = ok` in all 15 of
#      this board's trees; the two chips on i2c@757a000 and the two `letv,*_driver` platform nodes are
#      `disabled`. The boot kernel's own config has `CONFIG_USB_CCLOGIC_PI5USB=y` and `_TUSB302L=y` -- the
#      DISABLED nodes' drivers -- against `# CONFIG_USB_CCLOGIC_TUSB320 is not set`, `_PTN5150` and
#      `_PER30216` not set. So the two enabled nodes get an i2c client and bind nothing. That is a
#      build-time disagreement and it is the rung `driver-not-built`.
#   2. `cc_state: none` IS AMBIGUOUS. The hub (cclogic.c) creates /sys/class/typec/typec_device/ and the
#      ONLY writers of it are the chip drivers. `none` is both the uninitialised value and the value for
#      "nothing is plugged in" -- so the probe names the WRITER, and the scenario that must print the
#      warning is the one where no driver is registered.
#   3. HOW A DRIVER MATCHES IS NOT ALWAYS THE COMPATIBLE. `pi5usb@1d` carries the bare compatible
#      `pi5usb`, while pi5usb30216a.c's of_match is `fairchild,pi5usb`; what would bind it is the
#      id_table entry `{ "pi5usb", 0 }` matching the client's NAME, which the i2c core derives from the
#      compatible with the vendor prefix stripped. So both a `pi5usb` node and the client it creates are
#      this block's, and a probe that only knew compatibles would miss them.
#   4. IT WRITES NOTHING, AND THE KNOB IN SIGHT LOOKS WRITABLE. cclogic.c's
#      `cclogic_typec_headset_with_analog` is mode 0664, but `module_param_call` passes a NULL setter and
#      `param_attr_store()` returns -EPERM -- and tusb320.c's misc device (/dev/tusb320) has its own fops.
#      The static guard covers redirects and state-changing commands, and the mutation that must redden it
#      is the write to that parameter.
#
# How it works: **the stub directory IS the device.** The probe runs as itself against a fake root, with the
# device's tools stubbed and PATH sandboxed to `$STUB:$MINBIN`, where MINBIN holds symlinks to the real
# coreutils. The rewrite covers `/proc/`, `/sys/` and `/dev/tusb` -- the last because the probe NAMES
# /dev/tusb320 in its prose and its checklist, and a rename that re-rooted only the two roots it reads
# today would leave a future `> /dev/tusb320` escaping to this laptop.
#
# Usage: zl1-usbpd-probe-selftest.sh [--keep]
#   --keep   leave the fake device, the stubs and the rewritten probe for inspection
#
# `ZL1_USBPD_PROBE_SRC=/path` runs the whole thing against another copy of the subject, which is how a
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
SRC="${ZL1_USBPD_PROBE_SRC:-$HERE/../device/zl1-usbpd-probe.sh}"
[ -r "$SRC" ] || { echo "cannot read the subject: $SRC" >&2; exit 2; }

W="${TMPDIR:-/tmp}/zl1-usbpd-probe-selftest"
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
# The probe reads the device tree with `find`, resolves a phandle with it, and counts nodes with `wc`; a
# sandbox missing one of these would silently turn a reading into an absence. So each tool the probe calls
# is required by name before anything runs.
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
# THREE RULES. `/proc/` carries the device tree, the boot id, the uptime and the kernel config; `/sys/`
# carries the i2c and platform buses, the classes and the module parameters; and `/dev/tusb` is here even
# though the probe only NAMES that misc device today -- a rename that re-rooted only what the probe reads
# right now would leave a future `> /dev/tusb320` escaping to this laptop, and that is the defect this
# whole rewrite exists to prevent. `/dev/null` does not share the prefix.
cnt() { grep -o -- "$1" "$2" 2>/dev/null | wc -l | tr -d ' '; }
rewrite() { # $1 = source, $2 = output
  sed -e 's#/proc/#__ZP__#g' "$1" > "$W/pass1a.sh"
  sed -e 's#/sys/#__ZS__#g' "$W/pass1a.sh" > "$W/pass1b.sh"
  sed -e 's#/dev/tusb#__ZBT__#g' "$W/pass1b.sh" > "$W/pass1.sh"
  sed -e "s#__ZP__#$FR/proc/#g" -e "s#__ZS__#$FR/sys/#g" -e "s#__ZBT__#$FR/dev/tusb#g" \
    "$W/pass1.sh" > "$2"
}
RW="$W/usbpd-probe.sh"
sed -e 's#/proc/#__ZP__#g' "$SRC" > "$W/pass1a.sh"
[ "$(cnt '/proc/' "$SRC")" = "$(cnt '__ZP__' "$W/pass1a.sh")" ] \
  || { echo "the /proc/ rewrite did not cover every /proc/ in the source" >&2; exit 2; }
[ "$(cnt '/proc/' "$W/pass1a.sh")" = 0 ] || { echo "a /proc/ survived pass 1 -- the probe would read this host" >&2; exit 2; }
sed -e 's#/sys/#__ZS__#g' "$W/pass1a.sh" > "$W/pass1b.sh"
[ "$(cnt '/sys/' "$W/pass1a.sh")" = "$(cnt '__ZS__' "$W/pass1b.sh")" ] \
  || { echo "the /sys/ rewrite did not cover every /sys/ in the source" >&2; exit 2; }
[ "$(cnt '/sys/' "$W/pass1b.sh")" = 0 ] || { echo "a /sys/ survived pass 1" >&2; exit 2; }
sed -e 's#/dev/tusb#__ZBT__#g' "$W/pass1b.sh" > "$W/pass1.sh"
[ "$(cnt '/dev/tusb' "$W/pass1b.sh")" = "$(cnt '__ZBT__' "$W/pass1.sh")" ] \
  || { echo "the /dev/tusb rewrite did not cover every occurrence" >&2; exit 2; }
[ "$(cnt '/dev/tusb' "$W/pass1.sh")" = 0 ] || { echo "a /dev/tusb survived pass 1" >&2; exit 2; }
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
for tok in __ZP__ __ZS__ __ZBT__; do
  [ "$(cnt "$tok" "$W/pass1.sh")" -gt 0 ] || { echo "no $tok token was produced -- that rule matched nothing" >&2; exit 2; }
done
grep -qF "$FR$FR" "$RW" && { echo "a rewrite cascaded: $FR appears twice in a row" >&2; exit 2; }
grep -qF "$FR/proc/$FR" "$RW" && { echo "a rewrite cascaded into the fake root's own proc/" >&2; exit 2; }
# The paths the probe's answers hang on, named -- a rule that silently stopped applying would be invisible
# to the counts above if its occurrences moved into a comment.
# NOTE the `/sys/bus/` entry and not `/sys/bus/i2c/drivers`: the probe builds a bus path from variables
# (`"/sys/bus/$BUS/drivers/$DN"`), because it asks about both the i2c and the platform bus -- so the literal
# full path is nowhere in the file and requiring it would fail a probe that is doing the right thing.
for need in "$FR/proc/device-tree/model" "$FR/proc/device-tree/compatible" \
  "$FR/proc/sys/kernel/random/boot_id" "$FR/proc/uptime" "$FR/proc/config.gz" \
  "$FR/sys/bus/" "$FR/sys/class/typec/typec_device" "$FR/sys/class/misc/tusb320" \
  "$FR/sys/module/cclogic/parameters" "$FR/dev/tusb320"; do
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
#   * a HEREDOC BODY IS TEXT. The probe's `--explain` page says in prose what is NOT done, and blanking
#     the bodies first keeps that prose from being read as code while keeping the line count, so a real hit
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
# The teeth, and the first one is the write this probe is most plausibly tempted into: the one knob in the
# block that LOOKS writable, and the misc device whose fops are a write-class interface.
printf '%s\n' '# a fixture for the redirect rule: the parameter that looks writable and is refused' \
  'printf 1 > /sys/module/cclogic/parameters/cclogic_typec_headset_with_analog' > "$W/teeth-param.sh"
printf '%s\n' '# a fixture for the same rule, writing the port state through the hub' \
  'printf dfp > /sys/class/typec/typec_device/cc_state' > "$W/teeth-state.sh"
printf '%s\n' '# a fixture for the command-position rule' \
  'modprobe tusb320' > "$W/teeth-cmd.sh"
printf '%s\n' '# prose that must not be read as code' \
  "cat <<'EOF'" \
  'writing /sys/class/typec/typec_device/cc_state would be a WRITE, and opening /dev/tusb320 is a write-class move this probe does not make' \
  'EOF' \
  'say "the arrow -> /sys/class/typec/typec_device/cc_state is how this page writes a path"' > "$W/teeth-prose.sh"
want 'cclogic_typec_headset_with_analog' "$(write_sites "$W/teeth-param.sh")" \
  "the guard catches a redirect into the parameter that looks writable (as a fixture)"
want 'cc_state' "$(write_sites "$W/teeth-state.sh")" "and one into the hub's own port state"
want 'modprobe tusb320' "$(write_sites "$W/teeth-cmd.sh")" "and catches a state-changing command in command position"
notwant '.' "$(write_sites "$W/teeth-prose.sh")" \
  "and does not punish prose that names an arrow before a /sys path, or a heredoc about opening the misc device"
wantf 'opening /dev/tusb320 is a write-class move' "$(cat "$W/teeth-prose.sh")" \
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
# not `printf '%s' "$2"` -- `%s` prints the characters `\000` literally, which reads back as
# not-a-u32(N bytes) and makes every phandle look unresolved.
dtu32p() { mkdir -p "$(dirname "$1")"; printf "$2" > "$1"; }
# A NUL-separated string LIST (a `compatible` list, `pinctrl-names`), written as the bytes it is.
dtlistp() { mkdir -p "$(dirname "$1")"; printf "$2" > "$1"; }

# The two boards' root properties, exactly as the flashed blob carries them: IDENTICAL `compatible`, and a
# `model` that is the only thing telling them apart.
MODEL_ZL1='Letv Technologies, Inc. MSM 8996pro + PMI8996 LE_ZL1-DVT1'
MODEL_X2='Letv Technologies, Inc. MSM 8996 v3 + PMI8996 LE_X2-PVT'
# The pinctrl controller every gpio cell in this block points at, as phandle 28. It carries BOTH
# `phandle` and `linux,phandle` in the real tree, which is why the probe looks for either name.
tlmm_node() {
  DT="$FR/proc/device-tree/soc/pinctrl@01010000"
  dtp "$DT/compatible" 'qcom,msm8996-pinctrl'
  dtu32p "$DT/phandle" '\000\000\000\034'
  dtu32p "$DT/linux,phandle" '\000\000\000\034'
  dtu32p "$DT/#gpio-cells" '\000\000\000\002'
  dtu32p "$DT/#interrupt-cells" '\000\000\000\002'
  : > "$DT/gpio-controller"
  : > "$DT/interrupt-controller"
}
# THE TWO ENABLED NODES, with the real bytes read out of a ZL1 DTB. Note what they share: the properties of
# tusb320@67 and cclogic_dev@3d are IDENTICAL except `reg` (0x67 vs 0x3d) -- the same interrupt 73 on
# parent 28, the same four gpio cells, the same three pinctrl states. One of the two is the other's
# template, and a fixture that invented different numbers would hide that.
cc_enabled_node() { # $1 = node dir, $2 = compatible, $3 = reg as the 4 big-endian bytes
  dtp "$1/compatible" "$2"
  dtp "$1/status" 'ok'
  dtu32p "$1/reg" "$3"
  dtu32p "$1/interrupt-parent" '\000\000\000\034'
  dtu32p "$1/interrupts" '\000\000\000\111\000\000\000\002'
  dtu32p "$1/irq-gpio" '\000\000\000\034\000\000\000\111'
  dtu32p "$1/cc1_pwr_gpio" '\000\000\000\034\000\000\000\074'
  dtu32p "$1/cc2_pwr_gpio" '\000\000\000\034\000\000\000\075'
  dtu32p "$1/switch_gpio1" '\000\000\000\034\000\000\000\072'
  dtu32p "$1/switch_gpio2" '\000\000\000\034\000\000\000\073'
  dtlistp "$1/pinctrl-names" 'm0_ccswitch_active\000m0_ccint_active\000m0_ccpwr_active\000'
  dtu32p "$1/pinctrl-0" '\000\000\001\002'
  dtu32p "$1/pinctrl-1" '\000\000\001\003'
  dtu32p "$1/pinctrl-2" '\000\000\001\004'
}
# The i2c nodes the tree DISABLES. Their `qcom,id-gpio` is THREE cells (`<&tlmm 132 0>`), which is why the
# probe prints the flag cell as well as the number -- and their pinctrl state is named after their own
# driver (`pi5usb_active` / `tusb302l_active`), not after tusb320's.
cc_disabled_i2c_node() { # $1 = node dir, $2 = compatible, $3 = reg bytes, $4 = the pinctrl state name
  dtp "$1/compatible" "$2"
  dtp "$1/status" 'disabled'
  dtu32p "$1/reg" "$3"
  dtu32p "$1/interrupt-parent" '\000\000\000\034'
  dtu32p "$1/interrupts" '\000\000\000\111\000\000\000\002'
  dtu32p "$1/irq-gpio" '\000\000\000\034\000\000\000\111'
  dtu32p "$1/qcom,id-gpio" '\000\000\000\034\000\000\000\204\000\000\000\000'
  dtlistp "$1/pinctrl-names" "$4\000"
}
# The vendor's two platform nodes: a `compatible` and a `status`, no `reg` at all -- so a probe that read
# `reg` as a u32 and printed it would print a wrong-shaped answer for these two.
cc_platform_node() { # $1 = node dir, $2 = compatible
  dtp "$1/compatible" "$2"
  dtp "$1/status" 'disabled'
}
# The X2's CC-logic family: the nodes that are in the OTHER phone's 23 trees and in none of this board's
# 15. They are what makes the board reading matter here.
x2_cc_nodes() {
  dtp "$FR/proc/device-tree/soc/i2c@757a000/usb_cclogic@08/compatible" 'cypress,cyccg'
  dtp "$FR/proc/device-tree/soc/i2c@757a000/usb_cclogic@08/status" 'ok'
  dtp "$FR/proc/device-tree/soc/i2c@757a000/usb_cclogic@28/compatible" 'analogix,ohio'
  dtp "$FR/proc/device-tree/soc/i2c@757a000/usb_cclogic@28/status" 'ok'
  dtp "$FR/proc/device-tree/soc/i2c@757a000/dp_analogic@38/compatible" 'analogix,anx7816'
  dtp "$FR/proc/device-tree/soc/i2c@757a000/dp_analogic@38/status" 'ok'
}

# The kernel config, as the flashed boot image's own kernel carries it: the two DISABLED nodes' drivers are
# built in and neither of the two ENABLED nodes' drivers is.
config_realistic() {
  { printf '# Automatically generated file; DO NOT EDIT.\n'
    printf 'CONFIG_I2C=y\n'
    printf 'CONFIG_USB_CCLOGIC=y\n'
    printf 'CONFIG_USB_CCLOGIC_PI5USB=y\n'
    printf 'CONFIG_USB_CCLOGIC_TUSB302L=y\n'
    printf '# CONFIG_USB_CCLOGIC_TUSB320 is not set\n'
    printf '# CONFIG_USB_CCLOGIC_PTN5150 is not set\n'
    printf '# CONFIG_USB_CCLOGIC_PER30216 is not set\n'
    printf '# CONFIG_USB_CYCCG is not set\n'
    printf '# CONFIG_ANALOGIX_OHIO is not set\n'
    printf 'CONFIG_IKCONFIG=y\n'; } > "$W/kernel.config"
}
# The same config with the ENABLED node's driver built in -- so the config and sysfs DISAGREE. The
# `registered` column comes from sysfs and is the one that decides the rung; this fixture is what proves
# the probe does not decide it from the config.
config_tusb320_on() {
  config_realistic
  sed -i 's/^# CONFIG_USB_CCLOGIC_TUSB320 is not set$/CONFIG_USB_CCLOGIC_TUSB320=y/' "$W/kernel.config"
}
cat > "$STUB/zcat" <<'STUBEOF'
#!/bin/sh
cat "$CONFIGFILE"
STUBEOF
chmod +x "$STUB/zcat"

scen() {
  SCEN="$1"
  rm -rf "$FR"
  mkdir -p "$FR/proc/sys/kernel/random" "$FR/proc/device-tree/soc" \
    "$FR/sys/bus/i2c/devices" "$FR/sys/bus/i2c/drivers" "$FR/sys/bus/platform/drivers" \
    "$FR/sys/class" "$FR/sys/module" "$FR/dev"

  printf '%s\0' "$MODEL_ZL1" > "$FR/proc/device-tree/model"
  printf 'qcom,msm8996-mtp\0qcom,msm8996\0qcom,mtp\0' > "$FR/proc/device-tree/compatible"
  printf '11111111-2222-3333-4444-555555555555\n' > "$FR/proc/sys/kernel/random/boot_id"
  printf '1234.56 5678.90\n' > "$FR/proc/uptime"
  printf 'Linux version 3.18.140 (build) #1 SMP\n' > "$FR/proc/version"
  # The config. `no-config` is the ONLY scenario without the file: a device that cannot be asked is a
  # third state, and the probe must name it rather than read it as "the option is off".
  CONFIGFILE="$W/kernel.config"
  case "$SCEN" in
  no-config) rm -f "$FR/proc/config.gz" ;;
  config-tusb320-on) config_tusb320_on; cp "$W/kernel.config" "$FR/proc/config.gz" ;;
  *) config_realistic; cp "$W/kernel.config" "$FR/proc/config.gz" ;;
  esac
  # A gzip magic is not needed: the stub `zcat` cats the file, and the probe only requires that `zcat` be
  # there and produce something. The name of the file on the device is the one sysfs exposes.
  printf '\037\213\010\000' > /dev/null

  case "$SCEN" in
  unknown-model) printf 'Letv Technologies, Inc. LE_UNKNOWN-XYZ\0' > "$FR/proc/device-tree/model" ;;
  no-model) rm -f "$FR/proc/device-tree/model" ;;
  x2-tree) printf '%s\0' "$MODEL_X2" > "$FR/proc/device-tree/model" ;;
  esac

  # The device tree's CC-logic nodes. The default is the real zl1 shape.
  case "$SCEN" in
  no-dt-node | bare-tree | alien-node) : ;;
  x2-tree) x2_cc_nodes ;;
  all-disabled)
    # The status is written as the BYTES it is (`dtp` appends the NUL), so switching it means writing the
    # property again -- `sed 's/^ok$/disabled/'` matches nothing on a file whose last byte is a NUL, and the
    # node would stay enabled while the scenario believed it was off.
    cc_enabled_node "$FR/proc/device-tree/soc/i2c@75b5000/tusb320@67" 'tusb320' '\000\000\000\147'
    dtp "$FR/proc/device-tree/soc/i2c@75b5000/tusb320@67/status" 'disabled'
    cc_enabled_node "$FR/proc/device-tree/soc/i2c@75b5000/cclogic_dev@3d" 'cclogic_dev' '\000\000\000\075'
    dtp "$FR/proc/device-tree/soc/i2c@75b5000/cclogic_dev@3d/status" 'disabled' 
    cc_disabled_i2c_node "$FR/proc/device-tree/soc/i2c@757a000/pi5usb@1d" 'pi5usb' '\000\000\000\035' 'pi5usb_active'
    cc_disabled_i2c_node "$FR/proc/device-tree/soc/i2c@757a000/tusb302l@47" 'tusb302l' '\000\000\000\107' 'tusb302l_active'
    cc_platform_node "$FR/proc/device-tree/soc/pi5usb_driver" 'letv,pi5usb_driver'
    cc_platform_node "$FR/proc/device-tree/soc/tusb302l_driver" 'letv,tusb302l_driver'
    ;;
  one-enabled)
    cc_enabled_node "$FR/proc/device-tree/soc/i2c@75b5000/tusb320@67" 'tusb320' '\000\000\000\147'
    cc_disabled_i2c_node "$FR/proc/device-tree/soc/i2c@757a000/pi5usb@1d" 'pi5usb' '\000\000\000\035' 'pi5usb_active'
    cc_platform_node "$FR/proc/device-tree/soc/pi5usb_driver" 'letv,pi5usb_driver'
    ;;
  pi5usb-enabled)
    # The disabled-elsewhere node switched on, so the id_table-NAME match is reachable and has to be named.
    cc_disabled_i2c_node "$FR/proc/device-tree/soc/i2c@757a000/pi5usb@1d" 'pi5usb' '\000\000\000\035' 'pi5usb_active'
    dtp "$FR/proc/device-tree/soc/i2c@757a000/pi5usb@1d/status" 'ok' 
    ;;
  bad-reg)
    cc_enabled_node "$FR/proc/device-tree/soc/i2c@75b5000/tusb320@67" 'tusb320' '\000\000\000\147'
    printf '\000\000\147' > "$FR/proc/device-tree/soc/i2c@75b5000/tusb320@67/reg"
    ;;
  bad-gpio)
    # A gpio property whose length is not a whole number of cells: three bytes is not a gpio description,
    # and reading the first three bytes of four would print a plausible wrong number.
    cc_enabled_node "$FR/proc/device-tree/soc/i2c@75b5000/tusb320@67" 'tusb320' '\000\000\000\147'
    printf '\000\000\111' > "$FR/proc/device-tree/soc/i2c@75b5000/tusb320@67/irq-gpio"
    ;;
  *) # the real zl1 shape: two enabled, four disabled
    cc_enabled_node "$FR/proc/device-tree/soc/i2c@75b5000/tusb320@67" 'tusb320' '\000\000\000\147'
    cc_enabled_node "$FR/proc/device-tree/soc/i2c@75b5000/cclogic_dev@3d" 'cclogic_dev' '\000\000\000\075'
    cc_disabled_i2c_node "$FR/proc/device-tree/soc/i2c@757a000/pi5usb@1d" 'pi5usb' '\000\000\000\035' 'pi5usb_active'
    cc_disabled_i2c_node "$FR/proc/device-tree/soc/i2c@757a000/tusb302l@47" 'tusb302l' '\000\000\000\107' 'tusb302l_active'
    cc_platform_node "$FR/proc/device-tree/soc/pi5usb_driver" 'letv,pi5usb_driver'
    cc_platform_node "$FR/proc/device-tree/soc/tusb302l_driver" 'letv,tusb302l_driver'
    ;;
  esac
  # `alien-node`: a node of the RIGHT SHAPE carrying a compatible nothing in this block uses, so a scan
  # without find(1) is a scan that HAPPENED and found nothing -- which is a different state from "could not
  # look", and the only scenario that can tell the two apart.
  if [ "$SCEN" = alien-node ]; then
    dtp "$FR/proc/device-tree/soc/i2c@757a000/cc@99/compatible" 'qcom,alien-cclogic'
  fi
  if [ "$SCEN" != no-dt-node ] && [ "$SCEN" != bare-tree ] && [ "$SCEN" != alien-node ] && [ "$SCEN" != x2-tree ]; then
    tlmm_node
  fi
  if [ "$SCEN" = x2-tree ]; then tlmm_node; fi
  # `ambiguous-phandle`: a second node carries phandle 28, which a hand-built tree can do. The probe must
  # say AMBIGUOUS rather than pick one -- a wrong controller is a wrong gpio number.
  if [ "$SCEN" = ambiguous-phandle ]; then
    dtu32p "$FR/proc/device-tree/soc/other-gpio/phandle" '\000\000\000\034'
  fi

  # The i2c clients. A client exists for every ENABLED child of a probed adapter, and NOT for a disabled
  # one -- that is what `for_each_available_child_of_node` means -- so the fixtures are faithful and create
  # clients only for the enabled nodes.
  case "$SCEN" in
  no-i2c-clients | no-dt-node | bare-tree | alien-node | all-disabled) : ;;
  x2-tree)
    mkdir -p "$FR/sys/bus/i2c/devices/11-0008" "$FR/sys/bus/i2c/devices/11-0028"
    printf 'cyccg\n' > "$FR/sys/bus/i2c/devices/11-0008/name"
    printf 'ohio\n' > "$FR/sys/bus/i2c/devices/11-0028/name"
    ;;
  pi5usb-enabled)
    mkdir -p "$FR/sys/bus/i2c/devices/7-001d"
    printf 'pi5usb\n' > "$FR/sys/bus/i2c/devices/7-001d/name"
    ;;
  one-enabled)
    mkdir -p "$FR/sys/bus/i2c/devices/11-0067"
    printf 'tusb320\n' > "$FR/sys/bus/i2c/devices/11-0067/name"
    ;;
  *)
    mkdir -p "$FR/sys/bus/i2c/devices/11-0067" "$FR/sys/bus/i2c/devices/11-003d"
    printf 'tusb320\n' > "$FR/sys/bus/i2c/devices/11-0067/name"
    printf 'cclogic_dev\n' > "$FR/sys/bus/i2c/devices/11-003d/name"
    ;;
  esac

  # The driver directories. `driver-registered-unbound` is the directory with nothing attached, which is a
  # DIFFERENT reading from the directory being absent -- and `port-reported` is the same directory with a
  # client bound, i.e. a writer.
  case "$SCEN" in
  driver-registered-unbound | no-hub | port-reported)
    mkdir -p "$FR/sys/bus/i2c/drivers/tusb320"
    touch "$FR/sys/bus/i2c/drivers/tusb320/bind" "$FR/sys/bus/i2c/drivers/tusb320/unbind" \
      "$FR/sys/bus/i2c/drivers/tusb320/uevent"
    ;;
  esac
  case "$SCEN" in
  no-hub | port-reported)
    ln -sfn "$FR/sys/bus/i2c/devices/11-0067" "$FR/sys/bus/i2c/drivers/tusb320/11-0067"
    ln -sfn "$FR/sys/bus/i2c/drivers/tusb320" "$FR/sys/bus/i2c/devices/11-0067/driver"
    ;;
  esac

  # The hub. `no-hub` is the class directory's absence -- a driver is driving the port with nowhere to
  # report it. `port-reported` gives it a state, and `writer-none` is the state the ambiguity is about.
  case "$SCEN" in
  no-hub | no-dt-node | bare-tree | alien-node | all-disabled | one-enabled | pi5usb-enabled | bad-reg | bad-gpio) : ;;
  x2-tree) : ;;
  port-reported)
    mkdir -p "$FR/sys/class/typec/typec_device"
    printf 'dfp\n' > "$FR/sys/class/typec/typec_device/cc_state"
    printf 'cc1\n' > "$FR/sys/class/typec/typec_device/cc_polarity"
    printf '0\n' > "$FR/sys/class/typec/typec_device/supported_dev"
    ;;
  *)
    mkdir -p "$FR/sys/class/typec/typec_device"
    printf 'none\n' > "$FR/sys/class/typec/typec_device/cc_state"
    printf 'none\n' > "$FR/sys/class/typec/typec_device/cc_polarity"
    printf '0\n' > "$FR/sys/class/typec/typec_device/supported_dev"
    ;;
  esac

  # The one module parameter in the block: mode 0664 in the real device, and a write to it is refused.
  if [ "$SCEN" != no-module-params ]; then
    mkdir -p "$FR/sys/module/cclogic/parameters"
    printf '0\n' > "$FR/sys/module/cclogic/parameters/cclogic_typec_headset_with_analog"
  fi

  # The kernel log. `log-unreadable` makes BOTH readers fail -- the only honest way to reach "not read".
  LOGMODE=normal
  [ "$SCEN" = log-unreadable ] && LOGMODE=unreadable
  case "$SCEN" in
  log-failing)
    { printf '[    0.000000] Booting Linux on physical CPU 0x0\n'
      printf '[    1.100000] tusb320 11-0067: tusb320_is_present: device id mismatch\n'
      printf '[    1.110000] tusb320: probe of 11-0067 failed with error -19\n'
      printf '[   30.000000] random: crng init done\n'; } > "$W/kernel.log"
    ;;
  log-quiet)
    { printf '[    0.000000] Booting Linux on physical CPU 0x0\n'
      printf '[   30.000000] random: crng init done\n'; } > "$W/kernel.log"
    ;;
  log-unreadable) : > "$W/kernel.log" ;;
  *)
    { printf '[    0.000000] Booting Linux on physical CPU 0x0\n'
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
  export LOGMODE LOGFILE="$W/kernel.log" CONFIGFILE
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
want '^# zl1 USB Type-C / CC-logic probe' "$OUT" "--help prints the probe's own header"
want 'a write-class move' "$(run --explain)" "--explain says opening the misc device is a write-class move"
want 'UNDECIDED' "$(run --explain)" "and names the state a chip with no driver leaves the port in"
want 'id_table' "$(run --explain)" "and spells out that a driver does not always match by compatible"
want 'fairchild,pi5usb' "$(run --explain)" "naming the of_match that the tree's own compatible does not carry"
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
want 'carry none of them' "$OUT" "naming the CC-logic difference rather than just the board name"
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
echo "== 3. the tree: what it declares, and what it switches on =="
# ==================================================================================================
scen idle
OUT=$(run)
want 'tusb320@67' "$OUT" "the enabled node on i2c@75b5000 is read by its path"
want 'cclogic_dev@3d' "$OUT" "and so is the second enabled one"
want 'pi5usb@1d' "$OUT" "the disabled i2c node is read too (a disabled node is still a reading)"
want 'letv,pi5usb_driver' "$OUT" "and so is the vendor's platform node"
want '2 of 6 node\(s\) are ENABLED' "$OUT" "the count of enabled nodes is printed, not left to the reader"
want 'reg: +103 0x67' "$OUT" "the i2c address is printed in decimal AND hex"
want 'reg: +103 0x67 +\(the i2c address' "$OUT" "and labelled as the i2c address"
want 'reg: +absent \(no i2c address' "$OUT" "while a platform node says why it has no address"
want 'gpio 73, no flag cell' "$OUT" "a two-cell gpio is read as two cells: the number, and no polarity flag"
want 'phandle 28 = /soc/pinctrl@01010000' "$OUT" "and the phandle is resolved to the controller that carries it"
want "names='m0_ccswitch_active m0_ccint_active m0_ccpwr_active '" "$OUT" "the pinctrl states are printed BY NAME"
want "'m0_ccint_active', so a node whose pinctrl-names omit it cannot bind" "$OUT" \
  "and the probe says why a name matters (the driver looks its state up by name)"
want 'DISABLED: the kernel creates no device for it, and no driver can bind at all' "$OUT" \
  "a disabled node is named as a tree decision, not as a hardware fault"

scen bad-reg
OUT=$(run)
want 'not-a-u32\(3 bytes\)' "$OUT" "a reg that is not four bytes says so rather than printing a number"
notwant 'reg: +0 ' "$OUT" "and does not print a plausible wrong value for it"

scen bad-gpio
OUT=$(run)
want 'not-a-gpio\(3 bytes\)' "$OUT" "a gpio property that is not a whole number of cells says so"
notwant 'gpio 292' "$OUT" "and does not print a number of the right shape read from three of four bytes"

scen ambiguous-phandle
OUT=$(run)
want 'AMBIGUOUS\(2\)' "$OUT" "a phandle carried by two nodes is reported as ambiguous"
notwant 'phandle 28 = /soc/pinctrl@01010000, gpio' "$OUT" "and the probe does not pick one of them"

# ==================================================================================================
echo "== 4. the fault this block actually has: a driver the tree enables and the kernel does not build =="
# ==================================================================================================
scen idle
OUT=$(run); RC=$?
want '== verdict: driver-not-built' "$OUT" "an enabled node with no registered driver is its own rung"
[ "$RC" = 1 ] && ok "and exits 1" || bad "the driver-not-built verdict exited $RC, not 1"
want 'registered: no +bound: NONE +config CONFIG_USB_CCLOGIC_TUSB320: NOT SET' "$OUT" \
  "the two answers about the driver are printed side by side, per driver"
want 'config CONFIG_USB_CCLOGIC_PI5USB: y \(built in\)' "$OUT" \
  "and the config says the DISABLED nodes' driver IS built -- the disagreement, in one line"
want 'CONFIG_USB_CCLOGIC_PTN5150 +NOT SET' "$OUT" "the second candidate for cclogic_dev is named as off too"
want 'by of_match "cclogic_dev"' "$OUT" "and which of the two claims cclogic_dev is spelled out"
want 'BUILD-TIME disagreement between the device tree and the kernel config' "$OUT" \
  "the verdict says this is a build decision, not a runtime fault"
want 'not a side effect of taking a reading' "$OUT" "and that the fix is a boot-image step of its own"

scen no-config
OUT=$(run); RC=$?
want 'config CONFIG_USB_CCLOGIC_TUSB320: NOT READ' "$OUT" "a kernel that cannot be asked is a state of its own"
want 'NOT READ -- which is a third state' "$OUT" "and the report says so rather than calling the option off"
want '== verdict: driver-not-built' "$OUT" "and the rung is unchanged, because sysfs answers it without the config"
[ "$RC" = 1 ] && ok "and still exits 1" || bad "the no-config verdict exited $RC, not 1"

scen config-tusb320-on
OUT=$(run)
want 'config CONFIG_USB_CCLOGIC_TUSB320: y \(built in\)' "$OUT" "a config that SAYS the driver is built is printed"
want 'registered: no' "$OUT" "and the registered column still says no -- sysfs is what decides it"
want '== verdict: driver-not-built' "$OUT" "so the config cannot talk the probe into a healthier rung"

scen pi5usb-enabled
OUT=$(run)
want 'compatible: +pi5usb' "$OUT" "a bare-compatible node is read by what it says"
want 'by the id_table NAME "pi5usb"' "$OUT" \
  "and the idle-table name match is named, because its of_match is fairchild,pi5usb"
want 'which this node does not carry' "$OUT" "with the reason it is not the of_match"

# ==================================================================================================
echo "== 5. every remaining rung, one scenario each =="
# ==================================================================================================
scen no-dt-node
OUT=$(run); RC=$?
want '== verdict: no-device-tree-node' "$OUT" "a tree with none of this block's nodes says so"
[ "$RC" = 1 ] && ok "and exits 1" || bad "the no-node verdict exited $RC, not 1"

scen alien-node
OUT=$(run)
want '== verdict: no-device-tree-node' "$OUT" "a node of the right SHAPE with a compatible nothing matches is an absence"
notwant 'tree-unscanned' "$OUT" "and is not confused with a scan that could not run (find(1) is here)"

scen bare-tree
OUT=$(run_nofind); RC=$?
want '== verdict: tree-unscanned' "$OUT" "a tree that cannot be searched is its own rung"
want 'device tree could not be searched for the CC-logic compatibles at all' "$OUT" "and is named as could-not-look"
want 'must not print the same way' "$OUT" "with the reason that state must not look like an absence"
[ "$RC" = 1 ] && ok "and exits 1" || bad "the unscanned verdict exited $RC, not 1"

scen all-disabled
OUT=$(run)
want '== verdict: no-node-enabled' "$OUT" "a tree that enables no port controller is its own rung"
want 'DISABLED: the kernel creates no device' "$OUT" "each node is named as disabled rather than as unbound"

scen one-enabled
OUT=$(run)
want '1 of 3 node\(s\) are ENABLED' "$OUT" "one enabled node out of a different total is counted right"
want '== verdict: driver-not-built' "$OUT" "and with no driver registered it is the same rung"

scen driver-registered-unbound
OUT=$(run)
want 'registered: yes +bound: NONE' "$OUT" "a registered driver with nothing attached prints both facts"
want '== verdict: driver-not-bound' "$OUT" "and that is a DIFFERENT rung from driver-not-built"
want 'the chip not answering on i2c' "$OUT" "the verdict names the candidate causes, taken from the sources"

scen no-hub
OUT=$(run)
want '== verdict: no-hub' "$OUT" "a bound driver with no hub to report through is its own rung"
want 'CONFIG_USB_CCLOGIC off' "$OUT" "and the reason is named, because that is a kernel config line"

scen port-reported
OUT=$(run); RC=$?
want '== verdict: port-reported' "$OUT" "a bound driver WITH the hub is the healthy rung"
want 'cc_state +dfp' "$OUT" "and the port state is then a reading"
want 'cc_polarity +cc1' "$OUT" "with the polarity beside it"
[ "$RC" = 0 ] && ok "and exits 0" || bad "the healthy verdict exited $RC, not 0"
notwant 'NOTHING CAN WRITE' "$OUT" "and the warning paragraph is NOT printed when a writer is bound"

# ================================================================================================
echo "== 6. 'cc_state: none' is ambiguous, and the report has to say so =="
# ================================================================================================
scen idle
OUT=$(run)
want 'cc_state +none' "$OUT" "the hub's state is read"
want 'NOTHING CAN WRITE .cc_state. ON THIS BOOT' "$OUT" "and with no writer bound the warning paragraph IS printed"
want 'not a report that the port is idle' "$OUT" "the paragraph names the ambiguity in those terms"
want 'they are UNDECIDED' "$OUT" "and says the port is undecided rather than merely unread"
want "covers both" "$OUT" "the closing note says the same reading covers two different worlds"
want 'never opens ' "$OUT" "and says out loud that the misc device was not opened"
want 'a write is REFUSED' "$OUT" "the one module parameter is named as writable-LOOKING and refused"

scen no-hub
OUT=$(run)
want 'MISSING -- the hub did not register' "$OUT" "a missing hub is named, with the option behind it"
want 'nowhere at all for a CC-logic driver to report the port state' "$OUT" "and what its absence costs"

# ==================================================================================================
echo "== 7. the i2c clients, and the surfaces a bound driver would create =="
# ==================================================================================================
scen idle
OUT=$(run)
want '11-0067 +name: tusb320' "$OUT" "the client the i2c core created is read by its bus-address name"
want '11-003d +name: cclogic_dev' "$OUT" "and so is the second one"
want 'driver: +NONE -- the client exists and no driver is bound to it' "$OUT" \
  "a client with nothing bound says so in words, not by an empty line"

scen no-i2c-clients
OUT=$(run)
want 'no client of this block.s compatibles exists' "$OUT" "an empty device list is a reading of its own"
want 'not about the chips' "$OUT" "and the report says what it IS a reading about"

scen x2-tree
OUT=$(run)
want 'cyccg' "$OUT" "the X2's clients are matched by their MODALIAS (the vendor prefix is stripped)"

scen idle
OUT=$(run)
for s in '/sys/class/misc/tusb320' '/sys/class/tusb302l_class/tusb302l' '/sys/class/pi5usb_class/pi5usb' '/dev/tusb320'; do
  want "$(printf '%s' "$s" | sed 's#/#\\/#g'): absent" "$OUT" "the surface a bound driver would create is named when absent: $s"
done
want 'ABSENT \(the driver did not register\)' "$OUT" "a driver directory that is not there is named as not registered"

scen no-module-params
OUT=$(run)
want 'cclogic_typec_headset_with_analog: absent' "$OUT" "a module parameter that is not there is not invented"

# ==================================================================================================
echo "== 8. the kernel log section =="
# ==================================================================================================
scen log-failing
OUT=$(run)
want 'tusb320_is_present: device id mismatch' "$OUT" "a probe failure in the log is shown"
want 'probe of 11-0067 failed with error -19' "$OUT" "with the error line beside it"

scen log-quiet
OUT=$(run)
want 'none: the kernel log mentions no CC-logic driver' "$OUT" "a log with nothing in it says so in a named way"
want 'none: no CC-logic probe failure' "$OUT" "and the failure filter says so too"

scen log-unreadable
OUT=$(run)
want 'the kernel log could not be read' "$OUT" "an unreadable log is named, not printed as empty"
want 'No verdict below rests on it' "$OUT" "and the report says the rungs do not depend on it"

# ==================================================================================================
echo "== 9. --quiet, which must keep the verdict and drop the scroll =="
# ==================================================================================================
scen idle
OUT=$(run --quiet)
want '== verdict: driver-not-built' "$OUT" "--quiet still prints the verdict"
want 'cc_state +none' "$OUT" "and the hub reading the verdict rests on"
notwant 'the driver names its pin state BY NAME' "$OUT" "while dropping the per-node commentary"
notwant 'compatible:  cclogic_dev' "$OUT" "and the node-by-node dump"

# ==================================================================================================
echo "== 10. the mutations that are readings, not writes =="
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
fi
# 2. The status check dropped: a node the kernel will create no device for would report as a driver
#    problem, sending the reader to the wrong subsystem (and making the enabled count meaningless).
sed "s#case \"\$ST\" in okay | ok | EMPTY) EN=yes ;; \*) EN=no ;; esac#case \"\$ST\" in *) EN=yes ;; esac#" \
  "$SRC" > "$W/mut-status.sh"
if cmp -s "$SRC" "$W/mut-status.sh"; then bad "the status mutation did not apply"; else
  scen all-disabled
  OUT=$(mut_run "$W/mut-status.sh")
  notwant '== verdict: no-node-enabled' "$OUT" \
    "dropping the status check stops a tree that enables nothing being a rung (the mutation)"
  want 'ENABLED by this tree' "$OUT" "and every node counts as enabled instead"
fi
# 3. The rung decided by the SOURCE having a driver instead of by the driver REGISTERING. That is the
#    mutation that matters most here: it turns the block's actual fault into a different one.
sed 's#^        R=\$(drv_registered "\$DB" "\$DN")#        R=yes#' "$SRC" > "$W/mut-registered.sh"
if cmp -s "$SRC" "$W/mut-registered.sh"; then bad "the registered mutation did not apply"; else
  scen idle
  OUT=$(mut_run "$W/mut-registered.sh")
  notwant '== verdict: driver-not-built' "$OUT" \
    "treating a source-matching driver as registered loses the rung this block is about (the mutation)"
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
  notwant 'reg: +103 0x67' "$OUT" "combining the four bytes in the host's order loses the real address (the mutation)"
  want 'reg: +1728053248 0x67000000' "$OUT" "and prints a number of the right SHAPE and the wrong value"
fi
# 6. The ambiguity paragraph silenced. This is the reading a phone with nothing plugged in depends on:
#    without it, `cc_state: none` with no writer looks like a working, idle port.
sed 's#^  always "   NOTHING CAN WRITE .cc_state. ON THIS BOOT. The tree enables \$N_ENABLED node(s) and this kernel has"#  : "   NOTHING CAN WRITE '"'"'cc_state'"'"' ON THIS BOOT."#' \
  "$SRC" > "$W/mut-note.sh"
if cmp -s "$SRC" "$W/mut-note.sh"; then bad "the ambiguity-note mutation did not apply"; else
  scen idle
  OUT=$(mut_run "$W/mut-note.sh")
  notwant 'NOTHING CAN WRITE' "$OUT" \
    "silencing the paragraph removes the reading that keeps an uninitialised 'none' from looking like a reading (the mutation)"
  want '== verdict: driver-not-built' "$OUT" "while the verdict itself still stands"
fi
# 7. The phandle resolution dropped: the gpio cells would print numbers and leave the controller to guess.
sed 's#^  printf .phandle %s = %s, gpio %s, %s. "\$_g_p" "\$(phandle_node "\$_g_p")" "\$_g_n" "\$_g_pol"#  printf "phandle %s = (not resolved), gpio %s, %s" "$_g_p" "$_g_n" "$_g_pol"#' \
  "$SRC" > "$W/mut-ph.sh"
if cmp -s "$SRC" "$W/mut-ph.sh"; then bad "the phandle mutation did not apply"; else
  scen idle
  OUT=$(mut_run "$W/mut-ph.sh")
  notwant 'phandle 28 = /soc/pinctrl@01010000' "$OUT" \
    "not resolving the phandle leaves the gpio controller unnamed (the mutation)"
  want 'gpio 73' "$OUT" "while the gpio number itself is still printed -- the wrong-answer-of-the-right-shape case"
fi
# 8. The tab-separated driver lines read with a default IFS: every FIELD becomes its own iteration, and the
#    report prints the config option as if it were a driver name.
sed -e "/^      IFS='$/,/^'\$/d" "$SRC" > "$W/mut-ifs.sh"
if cmp -s "$SRC" "$W/mut-ifs.sh"; then bad "the IFS mutation did not apply"; else
  scen idle
  OUT=$(mut_run "$W/mut-ifs.sh")
  notwant 'driver: +tusb320 +\(drivers/usb/misc/tusb320.c' "$OUT" \
    "splitting the driver line on tabs loses the driver's own line (the mutation)"
  want 'driver: +CONFIG_USB_CCLOGIC_TUSB320' "$OUT" "and prints the config option as if it were a driver"
fi

# ==================================================================================================
echo "== 11. this harness's own citation =="
# ==================================================================================================
# A count typed by hand in the first thing a human reads goes stale the moment this file grows, so this
# harness reads its own citation out of the health check and compares it with what it just ran.
HEALTH="$HERE/zl1-health-check.sh"
if [ -r "$HEALTH" ]; then
  # The number is the one immediately before ` checks`, taken from the matched text rather than from the
  # whole sentence: `grep -oE '[0-9]+'` over the match also finds the 1 in `zl1-`, which is how the first
  # version of this check on a sibling harness compared 1 against 158. The first match is taken with
  # `sed -n 1p` and NOT with `head -n1`: this file sets pipefail, and a reader that exits early turns the
  # WRITER's SIGPIPE death into the pipeline's status -- a check that would report a failure of its own
  # extractor.
  match=$(tr '\n' ' ' < "$HEALTH" |
    grep -oE 'zl1-usbpd-probe-selftest\.sh[^0-9]*[0-9]+ checks' | sed -n 1p)
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
