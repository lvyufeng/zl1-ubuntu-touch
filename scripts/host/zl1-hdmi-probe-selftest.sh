#!/usr/bin/env bash
# zl1 HDMI probe -- offline self-test. Host-side, touches no device, needs no phone.
#
# Why this exists. `scripts/device/zl1-hdmi-probe.sh` is the instrument for the `hdmi` row of doc 137's gap
# list, and that row is not one device: it is six device-tree nodes, two of which are two GENERATIONS of
# the same transmitter claiming the same MMIO window. Five readings make the probe's design, and each is a
# scenario below:
#
#   1. TWO TRANSMITTERS, ONE WINDOW, AND ONLY ONE OF THEM DRIVABLE. `/soc/qcom,hdmi_tx@9a0000`
#      (`qcom,hdmi-tx`) carries NO `status` property -- which the device tree reads as ENABLED -- and is
#      the one `mdss_hdmi_tx.c` matches. `/soc/qcom,sde_hdmi@9a0000` (`qcom,hdmi-tx-8996`) says
#      `status = "ok"` and matches NOTHING in this kernel source, because the whole sde generation is in
#      the device tree and in no code of a 3.18 kernel. The two carry BYTE-IDENTICAL `reg` and `reg-names`.
#      `absent` therefore has to be in the ENABLED branch of the status test, or this board's only
#      drivable transmitter reads as disabled -- and that mutation is one of the ones below.
#   2. EIGHT NAMED GPIOS, AND THE NODE WITH THE DRIVER HAS ONE. The names come out of the source
#      (`"qcom,hdmi-tx"` + a suffix, three lists); the sde node carries five of them under a `-gpio`
#      suffix the driver never asks for. The probe CARRIES the five state names out of the driver and
#      asks the TREE for each, so the mutation that removes the `-gpio` alternative has to redden.
#   3. THE PIN STATE LIST IS SHIFTED BY ONE. `pinctrl_dt_to_map` pairs `pinctrl-names[i]` with `pinctrl-i`
#      and names a state past the last name after its own INDEX, so a node with four names and five
#      properties has `hdmi_sleep` pointing at the ACTIVE pins. The scenario is the real one: four names,
#      five properties, and the state that actually sleeps reachable only as `"4"`.
#   4. `connected` IS A VARIABLE. The transmitter's attributes are created on MDSS_EVENT_FB_REGISTERED and
#      live on the FRAMEBUFFER device; `connected`/`hpd` read `hpd_state`, which is only written once HPD
#      is armed -- and HPD is armed at that event only when `primary || !pluggable`, which this board's
#      node is not. And which `/sys/class/graphics/fbN` is the HDMI one follows a REGISTRATION COUNTER,
#      not the tree's `cell-index`, so the probe identifies it by ATTRIBUTE. The `fb-number` scenario is
#      what makes that checkable.
#   5. THE BLOCK'S FRAMEBUFFER IS NAMED BY A PHANDLE. `qcom,mdss-fb-map` -> the `qcom,mdss-fb` child, and
#      `mdss_fb_register()` returns -ENODEV without it. Two scenarios make that rung reachable (no
#      property, and a phandle that resolves to nothing).
#
# How it works: **the stub directory IS the device.** The probe runs as itself against a fake root, with
# the device's tools stubbed and PATH sandboxed to `$STUB:$MINBIN`, where MINBIN holds symlinks to the real
# coreutils. The rewrite covers `/proc/`, `/sys/` and `/dev/fb` -- the last because the probe NAMES a
# framebuffer device in its prose and a rename that re-rooted only the two roots it reads today would
# leave a future `> /dev/fb0` escaping to this laptop.
#
# Usage: zl1-hdmi-probe-selftest.sh [--keep]
#   --keep   leave the fake device, the stubs and the rewritten probe for inspection
#
# `ZL1_HDMI_PROBE_SRC=/path` runs the whole thing against another copy of the subject, which is how a
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
SRC="${ZL1_HDMI_PROBE_SRC:-$HERE/../device/zl1-hdmi-probe.sh}"
[ -r "$SRC" ] || { echo "cannot read the subject: $SRC" >&2; exit 2; }

W="${TMPDIR:-/tmp}/zl1-hdmi-probe-selftest"
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
# The probe reads the device tree with `find`, resolves phandles with it, counts the pinctrl-N properties
# with `-e` and names a controller with `basename`; a sandbox missing one of these would silently turn a
# reading into an absence. So each tool the probe calls is required by name before anything runs.
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
# carries the buses, the classes, the pinctrl controller's states and the framebuffer attributes; and
# `/dev/fb` is here even though the probe only NAMES a framebuffer device today -- a rename that re-rooted
# only what the probe reads right now would leave a future `> /dev/fb0` escaping to this laptop, which is
# the defect this whole rewrite exists to prevent. `/dev/null` does not share the prefix.
cnt() { grep -o -- "$1" "$2" 2>/dev/null | wc -l | tr -d ' '; }
rewrite() { # $1 = source, $2 = output
  sed -e 's#/proc/#__ZP__#g' "$1" > "$W/pass1a.sh"
  sed -e 's#/sys/#__ZS__#g' "$W/pass1a.sh" > "$W/pass1b.sh"
  sed -e 's#/dev/fb#__ZBF__#g' "$W/pass1b.sh" > "$W/pass1.sh"
  sed -e "s#__ZP__#$FR/proc/#g" -e "s#__ZS__#$FR/sys/#g" -e "s#__ZBF__#$FR/dev/fb#g" \
    "$W/pass1.sh" > "$2"
}
RW="$W/hdmi-probe.sh"
sed -e 's#/proc/#__ZP__#g' "$SRC" > "$W/pass1a.sh"
[ "$(cnt '/proc/' "$SRC")" = "$(cnt '__ZP__' "$W/pass1a.sh")" ] \
  || { echo "the /proc/ rewrite did not cover every /proc/ in the source" >&2; exit 2; }
[ "$(cnt '/proc/' "$W/pass1a.sh")" = 0 ] || { echo "a /proc/ survived pass 1 -- the probe would read this host" >&2; exit 2; }
sed -e 's#/sys/#__ZS__#g' "$W/pass1a.sh" > "$W/pass1b.sh"
[ "$(cnt '/sys/' "$W/pass1a.sh")" = "$(cnt '__ZS__' "$W/pass1b.sh")" ] \
  || { echo "the /sys/ rewrite did not cover every /sys/ in the source" >&2; exit 2; }
[ "$(cnt '/sys/' "$W/pass1b.sh")" = 0 ] || { echo "a /sys/ survived pass 1" >&2; exit 2; }
sed -e 's#/dev/fb#__ZBF__#g' "$W/pass1b.sh" > "$W/pass1.sh"
[ "$(cnt '/dev/fb' "$W/pass1b.sh")" = "$(cnt '__ZBF__' "$W/pass1.sh")" ] \
  || { echo "the /dev/fb rewrite did not cover every occurrence" >&2; exit 2; }
[ "$(cnt '/dev/fb' "$W/pass1.sh")" = 0 ] || { echo "a /dev/fb survived pass 1" >&2; exit 2; }
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
for tok in __ZP__ __ZS__ __ZBF__; do
  [ "$(cnt "$tok" "$W/pass1.sh")" -gt 0 ] || { echo "no $tok token was produced -- that rule matched nothing" >&2; exit 2; }
done
grep -qF "$FR$FR" "$RW" && { echo "a rewrite cascaded: $FR appears twice in a row" >&2; exit 2; }
grep -qF "$FR/proc/$FR" "$RW" && { echo "a rewrite cascaded into the fake root's own proc/" >&2; exit 2; }
# The paths the probe's answers hang on, named -- a rule that silently stopped applying would be invisible
# to the counts above if its occurrences moved into a comment.
for need in "$FR/proc/device-tree/model" "$FR/proc/device-tree/compatible" \
  "$FR/proc/sys/kernel/random/boot_id" "$FR/proc/uptime" "$FR/proc/config.gz" \
  "$FR/sys/bus/" "$FR/sys/class/graphics/fb" "$FR/dev/fb"; do
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
# The teeth, and the first ones are the writes this probe is most plausibly tempted into: a framebuffer
# blank (which would blank the screen the user is looking at), a DSI command write into the panel, and the
# transmitter's own hpd/hot_plug attributes, which CHANGE the port's state.
printf '%s\n' '# a fixture for the redirect rule: blanking the framebuffer' \
  'printf 1 > /sys/class/graphics/fb0/blank' > "$W/teeth-blank.sh"
printf '%s\n' '# a fixture for the same rule: a DSI command written into the panel' \
  'printf 0x05 > /sys/class/graphics/fb0/dsi_write' > "$W/teeth-dsi.sh"
printf '%s\n' '# a fixture for the same rule: the port state, through the transmitter attribute' \
  'printf 1 > /sys/class/graphics/fb2/hot_plug' > "$W/teeth-plugin.sh"
printf '%s\n' '# a fixture for the command-position rule' \
  'modprobe mdss_hdmi_tx' > "$W/teeth-cmd.sh"
printf '%s\n' '# prose that must not be read as code' \
  "cat <<'EOF'" \
  'writing /sys/class/graphics/fb0/dsi_write would push a command into the panel, and /dev/fb0 is a device this probe never opens' \
  'EOF' \
  'say "the arrow -> /sys/class/graphics/fb0/blank is how this page writes a path"' > "$W/teeth-prose.sh"
want 'blank' "$(write_sites "$W/teeth-blank.sh")" \
  "the guard catches a redirect into a framebuffer attribute (as a fixture)"
want 'dsi_write' "$(write_sites "$W/teeth-dsi.sh")" "and one that writes a DSI command into the panel"
want 'hot_plug' "$(write_sites "$W/teeth-plugin.sh")" "and one into the transmitter's own port state"
want 'modprobe mdss_hdmi_tx' "$(write_sites "$W/teeth-cmd.sh")" "and catches a state-changing command in command position"
notwant '.' "$(write_sites "$W/teeth-prose.sh")" \
  "and does not punish prose that names an arrow before a /sys path, or a heredoc about a framebuffer device"
wantf 'writing /sys/class/graphics/fb0/dsi_write would push a command' "$(cat "$W/teeth-prose.sh")" \
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
# A NUL-separated string LIST (a `compatible` list, `pinctrl-names`, `reg-names`), written as the bytes it is.
dtlistp() { mkdir -p "$(dirname "$1")"; printf "$2" > "$1"; }

# The two boards' root properties, exactly as the flashed blob carries them: IDENTICAL `compatible`, and a
# `model` that is the only thing telling them apart.
MODEL_ZL1='Letv Technologies, Inc. MSM 8996pro + PMI8996 LE_ZL1-DVT1'
MODEL_X2='Letv Technologies, Inc. MSM 8996 v3 + PMI8996 LE_X2-PVT'
# The register window BOTH transmitters declare, as the six big-endian cells of the real tree:
# 0x9A0000 0x50C 0x70000 0x6158 0x9E0000 0xFFF.
REG_HDMI='\000\232\000\000\000\000\005\014\000\007\000\000\000\000\141\130\000\236\000\000\000\000\017\377'
REGNAMES_HDMI='core_physical\000qfprom_physical\000hdcp_physical\000'
# The pinctrl controller every gpio cell points at, as phandle 28. It carries BOTH `phandle` and
# `linux,phandle` in the real tree, which is why the probe looks for either name -- and the six named pin
# states under it, which is how the probe resolves a pinctrl-N cell to the state it selects.
tlmm_node() {
  DT="$FR/proc/device-tree/soc/pinctrl@01010000"
  dtp "$DT/compatible" 'qcom,msm8996-pinctrl'
  dtu32p "$DT/phandle" '\000\000\000\034'
  dtu32p "$DT/linux,phandle" '\000\000\000\034'
  dtu32p "$DT/#gpio-cells" '\000\000\000\002'
  dtu32p "$DT/#interrupt-cells" '\000\000\000\002'
  : > "$DT/gpio-controller"
  : > "$DT/interrupt-controller"
  # mdss_hdmi_hpd_active 63, mdss_hdmi_ddc_suspend 64, mdss_hdmi_ddc_active 65, mdss_hdmi_hpd_suspend 66,
  # mdss_hdmi_cec_active 70, mdss_hdmi_cec_suspend 71 -- the six states the two transmitters reference.
  dtu32p "$DT/mdss_hdmi_hpd_active/phandle" '\000\000\000\077'
  dtu32p "$DT/mdss_hdmi_ddc_suspend/phandle" '\000\000\000\100'
  dtu32p "$DT/mdss_hdmi_ddc_active/phandle" '\000\000\000\101'
  dtu32p "$DT/mdss_hdmi_hpd_suspend/phandle" '\000\000\000\102'
  dtu32p "$DT/mdss_hdmi_cec_active/phandle" '\000\000\000\106'
  dtu32p "$DT/mdss_hdmi_cec_suspend/phandle" '\000\000\000\107'
  dtu32p "$DT/mdss_hdmi_hpd_active/pins" '\000\000\000\075'
  dtu32p "$DT/mdss_hdmi_ddc_active/pins" '\000\000\000\040'
}
# THE NODE THE DRIVER BINDS, with the real bytes. It has NO `status` property -- which is the device tree's
# way of saying enabled -- and FOUR pinctrl-names against FIVE pinctrl-N properties, which is the shift.
tx_mdss_node() {
  D="$FR/proc/device-tree/soc/qcom,hdmi_tx@9a0000"
  dtp "$D/compatible" 'qcom,hdmi-tx'
  dtu32p "$D/reg" "$REG_HDMI"
  dtlistp "$D/reg-names" "$REGNAMES_HDMI"
  dtu32p "$D/interrupt-parent" '\000\000\000\034'
  # HPD is a PMIC MPP pin, not a TLMM pin: the real cell is <61 4 0> and 61 is the phandle of
  # /soc/qcom,spmi@400f000/qcom,pm8994@0/mpps (label pm8994-mpp). The first version of this fixture wrote
  # <28 61 0> -- the TLMM phandle with gpio 61 -- which is a plausible NUMBER and the wrong controller,
  # which is exactly the shape this project keeps recording: a fixture that is right-looking and wrong.
  dtu32p "$D/qcom,hdmi-tx-hpd" '\000\000\000\075\000\000\000\004\000\000\000\000'
  dtu32p "$D/qcom,mdss-fb-map" '\000\000\000\076'
  : > "$D/qcom,pluggable"
  dtlistp "$D/pinctrl-names" 'hdmi_hpd_active\000hdmi_ddc_active\000hdmi_active\000hdmi_sleep\000'
  dtu32p "$D/pinctrl-0" '\000\000\000\077\000\000\000\100'
  dtu32p "$D/pinctrl-1" '\000\000\000\077\000\000\000\101'
  dtu32p "$D/pinctrl-2" '\000\000\000\077\000\000\000\100'
  dtu32p "$D/pinctrl-3" '\000\000\000\077\000\000\000\101'
  dtu32p "$D/pinctrl-4" '\000\000\000\102\000\000\000\100'
  dtu32p "$D/phandle" '\000\000\002\046'
  dtu32p "$D/linux,phandle" '\000\000\002\046'
}
# THE NODE NOTHING CAN BIND: the same window, `status = ok`, the sde generation's gpio SPELLING (the
# driver's names with `-gpio` appended), and the consistent two-name/two-property pin list that carries the
# CEC state the mdss node has no name for.
tx_sde_node() {
  D="$FR/proc/device-tree/soc/qcom,sde_hdmi@9a0000"
  dtp "$D/compatible" 'qcom,hdmi-tx-8996'
  dtp "$D/status" 'ok'
  dtu32p "$D/reg" "$REG_HDMI"
  dtlistp "$D/reg-names" "$REGNAMES_HDMI"
  dtu32p "$D/interrupt-parent" '\000\000\000\105'
  dtu32p "$D/interrupts" '\000\000\000\010\000\000\000\000'
  # ... and the other generation's node describes the SAME line, under the other spelling, with the
  # SAME cells: that is the finding, so the fixture has to write them identically.
  dtu32p "$D/qcom,hdmi-tx-hpd-gpio" '\000\000\000\075\000\000\000\004\000\000\000\000'
  dtu32p "$D/qcom,hdmi-tx-mux-en-gpio" '\000\000\000\034\000\000\000\033\000\000\000\000'
  dtu32p "$D/qcom,hdmi-tx-mux-sel-gpio" '\000\000\000\034\000\000\000\123\000\000\000\000'
  dtu32p "$D/qcom,hdmi-tx-ddc-clk-gpio" '\000\000\000\034\000\000\000\040\000\000\000\000'
  dtu32p "$D/qcom,hdmi-tx-ddc-data-gpio" '\000\000\000\034\000\000\000\041\000\000\000\000'
  dtlistp "$D/pinctrl-names" 'default\000sleep\000'
  dtu32p "$D/pinctrl-0" '\000\000\000\077\000\000\000\101\000\000\000\106'
  dtu32p "$D/pinctrl-1" '\000\000\000\102\000\000\000\100\000\000\000\107'
  dtu32p "$D/phandle" '\000\000\000\103'
}
# The sde KMS node the sde transmitter's interrupt-parent points at -- in the tree, and in no code of this
# kernel. It exercises the phandle resolver on a node whose name is not a path anyone can guess.
sde_kms_node() {
  D="$FR/proc/device-tree/soc/qcom,sde_kms@900000"
  dtp "$D/compatible" 'qcom,sde-kms'
  dtu32p "$D/phandle" '\000\000\000\105'
  : > "$D/interrupt-controller"
}
# The HDMI framebuffer child (cell-index 2, phandle 62), the PLL, the display-manager child, the two audio
# codec-rx children and the DAI: the rest of the block, which is what a probe that only looked for "hdmi"
# in the compatible strings would miss.
rest_of_block() {
  F="$FR/proc/device-tree/soc/qcom,mdss_mdp@900000/qcom,mdss_fb_hdmi"
  dtp "$F/compatible" 'qcom,mdss-fb'
  dtu32p "$F/cell-index" '\000\000\000\002'
  dtu32p "$F/phandle" '\000\000\000\076'
  dtu32p "$F/linux,phandle" '\000\000\000\076'
  G="$FR/proc/device-tree/soc/qcom,mdss_mdp@900000/qcom,mdss_fb_primary"
  dtp "$G/compatible" 'qcom,mdss-fb'
  dtu32p "$G/cell-index" '\000\000\000\000'
  P="$FR/proc/device-tree/soc/qcom,mdss_hdmi_pll@0x9a0600"
  dtp "$P/compatible" 'qcom,mdss_hdmi_pll_8996_v3_1p8'
  dtp "$P/label" 'MDSS HDMI PLL'
  dtu32p "$P/reg" '\000\232\001\200\000\000\013\020\000\232\003\100\000\000\000\310\000\214\043\100\000\000\000\010'
  dtlistp "$P/reg-names" 'pll_base\000phy_base\000gdsc_base\000'
  H="$FR/proc/device-tree/soc/qcom,display-manager/qcom,hdmi-display"
  dtp "$H/compatible" 'qcom,hdmi-display'
  dtp "$H/label" 'hdmi_display'
  dtp "$H/qcom,display-type" 'secondary'
  A="$FR/proc/device-tree/soc/qcom,hdmi_tx@9a0000/qcom,msm-hdmi-audio-rx"
  dtp "$A/compatible" 'qcom,msm-hdmi-audio-codec-rx'
  B="$FR/proc/device-tree/soc/qcom,sde_hdmi@9a0000/qcom,sde-hdmi-audio-rx"
  dtp "$B/compatible" 'qcom,msm-hdmi-audio-codec-rx'
  # The controller the HPD cell points at: the PMIC's MPP block, phandle 61, `#gpio-cells = 2`, label
  # pm8994-mpp. Without it the probe would print "unresolved" for a phandle that RESOLVES on this board --
  # which is why the `no-mpp-node` scenario removes exactly this node rather than the fixture inventing a
  # phandle nothing carries.
  M="$FR/proc/device-tree/soc/qcom,spmi@400f000/qcom,pm8994@0/mpps"
  dtp "$M/compatible" 'qcom,qpnp-pin'
  dtp "$M/label" 'pm8994-mpp'
  : > "$M/gpio-controller"
  : > "$M/spmi-dev-container"
  dtu32p "$M/#gpio-cells" '\000\000\000\002'
  dtu32p "$M/phandle" '\000\000\000\075'
  dtu32p "$M/linux,phandle" '\000\000\000\075'
  I="$FR/proc/device-tree/soc/qcom,msm-dai-q6-hdmi"
  dtp "$I/compatible" 'qcom,msm-dai-q6-hdmi'
  dtu32p "$I/qcom,msm-dai-q6-dev-id" '\000\000\000\010'
}

# The kernel config, as the flashed boot image's own kernel carries it: the display stack, the PLL, the
# HDMI codec rx and the qdsp6v2 DAI are all BUILT, and the upstream DRM one is not built at all.
config_realistic() {
  { printf '# Automatically generated file; DO NOT EDIT.\n'
    printf 'CONFIG_FB_MSM_MDSS=y\n'
    printf 'CONFIG_FB_MSM_MDSS_HDMI_PANEL=y\n'
    printf 'CONFIG_FB_MSM_MDSS_WRITEBACK=y\n'
    printf 'CONFIG_MSM_MDSS_PLL=y\n'
    printf 'CONFIG_SND_SOC_MSM_HDMI_CODEC_RX=y\n'
    printf 'CONFIG_SND_SOC_QDSP6V2=y\n'
    printf '# CONFIG_DRM is not set\n'
    printf 'CONFIG_IKCONFIG=y\n'; } > "$W/kernel.config"
}
# The same config with the DRM HDMI driver switched on -- so the config and sysfs DISAGREE about a driver
# this board's nodes still cannot use. The `registered` column comes from sysfs and is the one that decides
# the rung; this fixture is what proves the probe does not decide it from the config.
config_drm_on() {
  config_realistic
  sed -i 's/^# CONFIG_DRM is not set$/CONFIG_DRM=y/' "$W/kernel.config"
}
cat > "$STUB/zcat" <<'STUBEOF'
#!/bin/sh
cat "$CONFIGFILE"
STUBEOF
chmod +x "$STUB/zcat"
cat > "$STUB/gunzip" <<'STUBEOF'
#!/bin/sh
cat "$CONFIGFILE"
STUBEOF
chmod +x "$STUB/gunzip"

scen() {
  SCEN="$1"
  rm -rf "$FR"
  mkdir -p "$FR/proc/sys/kernel/random" "$FR/proc/device-tree/soc" \
    "$FR/sys/bus/platform/drivers" "$FR/sys/bus/platform/devices" \
    "$FR/sys/class/graphics" "$FR/sys/module" "$FR/dev"

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
  config-drm-on) config_drm_on; cp "$W/kernel.config" "$FR/proc/config.gz" ;;
  *) config_realistic; cp "$W/kernel.config" "$FR/proc/config.gz" ;;
  esac

  case "$SCEN" in
  unknown-model) printf 'Letv Technologies, Inc. LE_UNKNOWN-XYZ\0' > "$FR/proc/device-tree/model" ;;
  # A tree that is not a tree: no nodes anywhere, so a scan without find(1) has nothing to look AT --
  # which is a different state from a scan that ran and found no node it was looking for.
  bare-tree) rmdir "$FR/proc/device-tree/soc" ;;
  no-model) rm -f "$FR/proc/device-tree/model" ;;
  x2-tree) printf '%s\0' "$MODEL_X2" > "$FR/proc/device-tree/model" ;;
  esac

  # The device tree's HDMI nodes. The default is the real zl1 shape.
  case "$SCEN" in
  no-dt-node | bare-tree | alien-node) : ;;
  all-disabled)
    # The status is written as the BYTES it is (`dtp` appends the NUL), so switching it means writing the
    # property again -- `sed 's/^ok$/disabled/'` matches nothing on a file whose last byte is a NUL, and the
    # node would stay enabled while the scenario believed it was off.
    tx_mdss_node; dtp "$FR/proc/device-tree/soc/qcom,hdmi_tx@9a0000/status" 'disabled'
    tx_sde_node;  dtp "$FR/proc/device-tree/soc/qcom,sde_hdmi@9a0000/status" 'disabled'
    rest_of_block
    ;;
  sde-only-enabled)
    # The generation rung: the only ENABLED transmitter is the one no kernel of this generation can bind.
    tx_mdss_node; dtp "$FR/proc/device-tree/soc/qcom,hdmi_tx@9a0000/status" 'disabled'
    tx_sde_node
    rest_of_block
    ;;
  mdss-disabled-only)
    # The mirror of the above: the sde node switched off, so only the drivable one remains enabled.
    tx_mdss_node
    tx_sde_node; dtp "$FR/proc/device-tree/soc/qcom,sde_hdmi@9a0000/status" 'disabled'
    rest_of_block
    ;;
  no-fb-map)
    tx_mdss_node; rm -f "$FR/proc/device-tree/soc/qcom,hdmi_tx@9a0000/qcom,mdss-fb-map"
    tx_sde_node
    rest_of_block
    ;;
  fb-map-unresolved)
    tx_mdss_node; dtu32p "$FR/proc/device-tree/soc/qcom,hdmi_tx@9a0000/qcom,mdss-fb-map" '\000\000\001\055'
    tx_sde_node
    rest_of_block
    ;;
  fb-map-ambiguous)
    tx_mdss_node
    tx_sde_node
    rest_of_block
    # A second node carrying the framebuffer's phandle: a hand-built tree can do it, and the probe must say
    # AMBIGUOUS rather than pick one -- the wrong node is the wrong framebuffer.
    dtu32p "$FR/proc/device-tree/soc/qcom,mdss_mdp@900000/qcom,mdss_fb_other/phandle" '\000\000\000\076'
    ;;
  bad-reg)
    tx_mdss_node
    printf '\000\232\000\000\000\000\005' > "$FR/proc/device-tree/soc/qcom,hdmi_tx@9a0000/reg"
    tx_sde_node
    rest_of_block
    ;;
  bad-gpio)
    tx_mdss_node
    # A gpio property whose length is not a whole number of cells: three bytes is not a gpio description,
    # and reading the first three bytes of four would print a plausible wrong number.
    printf '\000\000\075' > "$FR/proc/device-tree/soc/qcom,hdmi_tx@9a0000/qcom,hdmi-tx-hpd"
    tx_sde_node
    rest_of_block
    ;;
  no-mpp-node)
    # The tree that does not carry the controller its own gpio cell points at. This is the scenario that
    # keeps the probe's "unresolved" branch covered now that the fixture writes the REAL cells: the point
    # is that a phandle can fail to resolve in the tree, not that the number can be made up.
    tx_mdss_node
    tx_sde_node
    rest_of_block
    rm -rf "$FR/proc/device-tree/soc/qcom,spmi@400f000"
    ;;
  names-short)
    # Two names over three properties: the third state is named after its index, and the comparison the
    # probe prints has to say the names ran out. The properties past pinctrl-2 are REMOVED, because a
    # scenario that only rewrites the names is still the five-property shape.
    tx_mdss_node
    rm -f "$FR/proc/device-tree/soc/qcom,hdmi_tx@9a0000/pinctrl-3" \
          "$FR/proc/device-tree/soc/qcom,hdmi_tx@9a0000/pinctrl-4"
    dtlistp "$FR/proc/device-tree/soc/qcom,hdmi_tx@9a0000/pinctrl-names" 'hdmi_hpd_active\000hdmi_ddc_active\000'
    tx_sde_node
    rest_of_block
    ;;
  *)
    tx_mdss_node
    tx_sde_node
    rest_of_block
    ;;
  esac
  # `alien-node`: a node of the RIGHT SHAPE carrying a compatible nothing in this block uses, so a scan
  # without find(1) is a scan that HAPPENED and found nothing -- which is a different state from "could not
  # look", and the only scenario that can tell the two apart.
  if [ "$SCEN" = alien-node ]; then
    dtp "$FR/proc/device-tree/soc/qcom,alien-display@1/compatible" 'qcom,alien-hdmi'
  fi
  if [ "$SCEN" != no-dt-node ] && [ "$SCEN" != bare-tree ] && [ "$SCEN" != alien-node ]; then
    tlmm_node
    sde_kms_node
  fi
  # `ambiguous-phandle`: a second node carries the pinctrl controller's phandle, which a hand-built tree
  # can do. The probe must say AMBIGUOUS rather than pick one -- a wrong controller is a wrong gpio.
  if [ "$SCEN" = ambiguous-phandle ]; then
    tx_mdss_node
    tx_sde_node
    rest_of_block
    tlmm_node
    sde_kms_node
    dtu32p "$FR/proc/device-tree/soc/other-pinctrl/phandle" '\000\000\000\034'
  fi

  # The driver directories. `driver-registered-unbound` is the directory with nothing attached, which is a
  # DIFFERENT reading from the directory being absent -- and the `bound` scenarios are the same directory
  # with a device attached.
  case "$SCEN" in
  driver-registered-unbound | bound-no-hdmi-attrs | fb-number | transmitter-bound | no-fb-class | log-failing | log-quiet | log-unreadable | config-drm-on | no-fb-map | fb-map-unresolved | fb-map-ambiguous)
    mkdir -p "$FR/sys/bus/platform/drivers/mdss_hdmi_tx" "$FR/sys/bus/platform/drivers/mdss_fb" \
      "$FR/sys/bus/platform/drivers/mdss_pll"
    touch "$FR/sys/bus/platform/drivers/mdss_hdmi_tx/bind" "$FR/sys/bus/platform/drivers/mdss_hdmi_tx/unbind" \
      "$FR/sys/bus/platform/drivers/mdss_hdmi_tx/uevent"
    touch "$FR/sys/bus/platform/drivers/mdss_fb/bind" "$FR/sys/bus/platform/drivers/mdss_fb/unbind" \
      "$FR/sys/bus/platform/drivers/mdss_fb/uevent"
    ;;
  esac
  case "$SCEN" in
  bound-no-hdmi-attrs | fb-number | transmitter-bound | no-fb-class | log-failing | log-quiet | log-unreadable | config-drm-on | no-fb-map | fb-map-unresolved | fb-map-ambiguous)
    mkdir -p "$FR/sys/bus/platform/devices/9a0000.hdmi" "$FR/sys/bus/platform/devices/qcom,mdss_fb_hdmi"
    ln -sfn "$FR/sys/bus/platform/devices/9a0000.hdmi" "$FR/sys/bus/platform/drivers/mdss_hdmi_tx/9a0000.hdmi"
    ln -sfn "$FR/sys/bus/platform/devices/qcom,mdss_fb_hdmi" "$FR/sys/bus/platform/drivers/mdss_fb/qcom,mdss_fb_hdmi"
    ;;
  esac

  # The framebuffer class. The transmitter's own attributes (connected, hpd, edid, video_mode, ...) are
  # created on the FRAMEBUFFER device, so a scenario that has them is a scenario where the display got as
  # far as MDSS_EVENT_FB_REGISTERED.
  case "$SCEN" in
  no-fb-class | no-dt-node | bare-tree | alien-node | all-disabled | sde-only-enabled | bad-reg | bad-gpio | names-short | ambiguous-phandle | mdss-disabled-only | no-config | no-fb-map | fb-map-unresolved | fb-map-ambiguous) : ;;
  bound-no-hdmi-attrs)
    # The framebuffer registered, but this device carries only the generic fb attributes -- so nothing
    # carries the transmitter's group, and the probe has to reach that rung instead of the top one.
    mkdir -p "$FR/sys/class/graphics/fb0"
    printf 'mdssfb_90000\n' > "$FR/sys/class/graphics/fb0/name"
    printf '0\n' > "$FR/sys/class/graphics/fb0/blank"
    ;;
  fb-number)
    # THE FB NUMBER IS A REGISTRATION ORDER, NOT THE TREE'S cell-index. Here the framebuffer that carries
    # the transmitter's attributes is fb3, while the tree says cell-index 2 and fb2 exists as the WFD one.
    mkdir -p "$FR/sys/class/graphics/fb0" "$FR/sys/class/graphics/fb2" "$FR/sys/class/graphics/fb3"
    printf 'mdssfb_90000\n' > "$FR/sys/class/graphics/fb0/name"
    printf 'mdssfb_wfd\n' > "$FR/sys/class/graphics/fb2/name"
    printf 'mdssfb_hdmi\n' > "$FR/sys/class/graphics/fb3/name"
    for a in connected hpd edid video_mode hot_plug sim_mode; do printf '0\n' > "$FR/sys/class/graphics/fb3/$a"; done
    ;;
  *)
    mkdir -p "$FR/sys/class/graphics/fb0" "$FR/sys/class/graphics/fb2"
    printf 'mdssfb_90000\n' > "$FR/sys/class/graphics/fb0/name"
    printf 'mdssfb_hdmi\n' > "$FR/sys/class/graphics/fb2/name"
    for a in connected hpd edid video_mode hot_plug sim_mode hdmi_audio_cb vendor_name product_description avi_itc avi_cn0_1 s3d_mode 5v; do
      printf '0\n' > "$FR/sys/class/graphics/fb2/$a"
    done
    ;;
  esac

  # The kernel log. `log-unreadable` makes BOTH readers fail -- the only honest way to reach "not read".
  LOGMODE=normal
  [ "$SCEN" = log-unreadable ] && LOGMODE=unreadable
  case "$SCEN" in
  log-failing)
    { printf '[    0.000000] Booting Linux on physical CPU 0x0\n'
      printf '[    1.100000] mdss_hdmi_tx: mdss_hdmi_tx_probe:2720 Unable to read qcom,display-id, data=0x0,len=0\n'
      printf '[    1.110000] gpio_request failed for gpio: hpd\n'
      printf '[    1.120000] mdss_hdmi_tx: probe of 9a0000.hdmi failed with error -19\n'
      printf '[   30.000000] random: crng init done\n'; } > "$W/kernel.log"
    ;;
  log-quiet)
    { printf '[    0.000000] Booting Linux on physical CPU 0x0\n'
      printf '[   30.000000] random: crng init done\n'; } > "$W/kernel.log"
    ;;
  log-unreadable) : > "$W/kernel.log" ;;
  *)
    { printf '[    0.000000] Booting Linux on physical CPU 0x0\n'
      printf '[    1.100000] Console: switching to colour frame buffer device 120x90\n'
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
want '^# zl1 HDMI probe' "$OUT" "--help prints the probe's own header"
want 'the FRAMEBUFFER device' "$(run --explain)" "--explain says where the transmitter's attributes live"
want 'MDSS_EVENT_FB_REGISTERED' "$(run --explain)" "and names the event that creates them"
want 'registration counter' "$(run --explain)" "and says the fb number is a registration counter, not cell-index"
want 'hpd_state' "$(run --explain)" "and names what a 'connected: 0' actually reads"
want 'pdata->primary \|\| !pdata->pluggable' "$(run --explain)" "and the condition that decides whether HPD is armed at all"
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
want 'BOTH boards declare an HDMI transmitter at the' "$OUT" "naming why the tree's shape cannot tell them apart"
[ "$RC" = 1 ] && ok "and exits 1" || bad "the wrong-board verdict exited $RC, not 1"

scen unknown-model
OUT=$(run)
want '== verdict: unknown-board' "$OUT" "a model that names neither board is not attributed to this phone"
want 'neither LE_ZL1 nor LE_X2' "$OUT" "and is reported as neither rather than assumed to be a zl1"

scen no-model
OUT=$(run)
want '== verdict: unknown-board' "$OUT" "an unreadable model reaches the same rung, not a crash"
want 'board: +UNKNOWN' "$OUT" "and is named as unreadable rather than as neither"

# ==================================================================================================
echo "== 3. the two generations, and the window they both claim =="
# ==================================================================================================
scen idle
OUT=$(run)
want '/soc/qcom,hdmi_tx@9a0000' "$OUT" "the mdss transmitter is read by its path"
want '/soc/qcom,sde_hdmi@9a0000' "$OUT" "and so is the sde one"
want '/soc/qcom,display-manager/qcom,hdmi-display' "$OUT" "and the display-manager child"
want '/soc/qcom,mdss_hdmi_pll@0x9a0600' "$OUT" "and the PLL"
want '/soc/qcom,msm-dai-q6-hdmi' "$OUT" "and the audio DAI, which the block's own inventory pattern does not match"
want 'absent \(an absent status means enabled; this node carries none\)  \(the kernel will create this device\)' "$OUT" \
  "the node with NO status is read as ENABLED -- which is what this board's drivable transmitter has"
want 'ok  \(the kernel will create this device\)' "$OUT" "and the sde node's explicit ok is read as the same thing"
want 'Of the 2 transmitter node\(s\), 2 are ENABLED' "$OUT" "the enabled count is printed, not left to the reader"
want '7 of 7 node\(s\) are ENABLED' "$OUT" "every node of this block is counted, including the audio ones"
want 'reg: +10092544 1292 458752 24920 10354688 4095' "$OUT" "the register window is printed as every cell"
want 'hex: 0x9a0000 0x50c 0x70000 0x6158 0x9e0000 0xfff' "$OUT" "and again in hex, because that is how a memory map is written"
want 'reg-names: +core_physical qfprom_physical hdcp_physical' "$OUT" "the reg-names list is read as a LIST"
want 'Both carry the SAME reg cells, so both claim this board.s HDMI register window' "$OUT" \
  "and the two transmitters' windows are COMPARED rather than left for the reader to compare"
want "NONE in this kernel source matches 'qcom,hdmi-tx-8996'" "$OUT" \
  "the sde transmitter is named as matching nothing -- under ANY config"
want 'by of_match "qcom,hdmi-tx" \(the mdss/fb generation\)' "$OUT" "while the mdss one names its driver and how it matches"
want 'interrupt-parent: 69 = /soc/qcom,sde_kms@900000' "$OUT" "and a phandle in the tree resolves to the node that carries it"

scen sde-only-enabled
OUT=$(run); RC=$?
want '== verdict: no-driver-for-enabled-transmitter' "$OUT" \
  "a tree that enables only the undrivable generation is its own rung, not 'no driver registered'"
want 'property of the kernel GENERATION and not of a build option' "$OUT" "and it says WHICH kind of problem that is"
[ "$RC" = 1 ] && ok "and exits 1" || bad "that verdict exited $RC, not 1"

scen all-disabled
OUT=$(run); RC=$?
want '== verdict: no-transmitter-enabled' "$OUT" "a tree that enables neither transmitter is the rung above it"
want 'Of the 2 transmitter node\(s\), 0 are ENABLED' "$OUT" "with the count saying so"
[ "$RC" = 1 ] && ok "and exits 1" || bad "the no-transmitter verdict exited $RC, not 1"

# ==================================================================================================
echo "== 4. the gpio audit: what the driver asks for, against what each node carries =="
# ==================================================================================================
scen idle
OUT=$(run)
want 'the driver asks for: +qcom,hdmi-tx-hpd' "$OUT" "the driver's own gpio names are carried out of the source"
want 'the driver asks for: +qcom,hdmi-tx-cec' "$OUT" "all eight of them, including the CEC line no node has"
want "mdss node: phandle 61 = /soc/qcom,spmi@400f000/qcom,pm8994@0/mpps, gpio 4, active high" "$OUT" \
  "the node the driver binds answers with a RESOLVED gpio -- and it is a PMIC MPP pin, not a TLMM pin"
want "sde node : absent, but PRESENT as 'qcom,hdmi-tx-hpd-gpio': phandle 61 = /soc/qcom,spmi@400f000/qcom,pm8994@0/mpps, gpio 4, active high" "$OUT" \
  "and the OTHER generation's node describes the same line, under the other spelling, in the same cells"
want "sde node : absent, but PRESENT as 'qcom,hdmi-tx-ddc-clk-gpio'" "$OUT" \
  "and the other generation's spelling is named where the driver's name is missing"
want "absent -- and absent as 'qcom,hdmi-tx-mux-lpm-gpio' too" "$OUT" \
  "while a line neither node has says so for BOTH spellings"
want 'COUNTED, not asserted: the mdss node carries 1 of these eight names' "$OUT" \
  "the count of what each node carries is measured, not written into the sentence"
want 'the sde node' "$OUT" "and the sde node's count is measured too"
want "carries 0 as the driver spells them and 5 more only as '-gpio'" "$OUT" \
  "which for this board's sde node is zero under the driver's spelling and five under the other"
want 'THE READING IS THE PAIR' "$OUT" "and the paragraph draws the conclusion from the pair"

# THE SCENARIO THAT KEEPS "unresolved" COVERED NOW THAT THE FIXTURE CARRIES THE REAL CELLS. The fixture
# writes <61 4 0> because that is what the board's own tree says, so the phandle RESOLVES; a tree that does
# not carry the controller at all is a different tree, and it is this scenario rather than an invented
# number -- the first version of the fixture wrote phandle 29 (which nothing carried) to reach this branch,
# and a wrong number that happens to print the same word is not the same reading.
scen no-mpp-node
OUT=$(run)
want 'mdss node: phandle 61 = unresolved, gpio 4, active high' "$OUT" \
  "a phandle the tree does not carry is named as UNRESOLVED rather than dropped"
want "sde node : absent, but PRESENT as 'qcom,hdmi-tx-hpd-gpio': phandle 61 = unresolved" "$OUT" \
  "for both spellings of the same line, since the cell is the same cell"
notwant 'no find' "$OUT" \
  "and not as 'no find(1)', which is the other way a phandle fails to resolve (a device without find)" 

# ==================================================================================================
echo "== 5. the pin states: five looked up by name, four declared =="
# ==================================================================================================
scen idle
OUT=$(run)
want 'pinctrl-names: hdmi_hpd_active hdmi_ddc_active hdmi_active hdmi_sleep' "$OUT" "the names are printed in order"
want 'pinctrl-0\.\.4: 5 properties, 4 name\(s\)' "$OUT" "and the count of properties beside the count of names"
want 'THE NAMES RUN OUT 1 STATE\(S\) EARLY' "$OUT" "the shift is named as a shift, not left to arithmetic"
want 'pinctrl-2  = mdss_hdmi_hpd_active mdss_hdmi_ddc_suspend   <- state name: hdmi_active' "$OUT" \
  "and each state is resolved to the pin nodes it selects, beside its NAME"
want 'pinctrl-3  = mdss_hdmi_hpd_active mdss_hdmi_ddc_active   <- state name: hdmi_sleep' "$OUT" \
  "so that 'hdmi_sleep' pointing at the ACTIVE pins is visible"
want 'pinctrl-4  = mdss_hdmi_hpd_suspend mdss_hdmi_ddc_suspend   <- state name: "4"' "$OUT" \
  "and the state that really sleeps is shown to be named after its own index"
want 'the driver looks up these and this node does not name them: hdmi_cec_active' "$OUT" \
  "the one state name the driver looks up and this node lacks is named"
want 'mdss_hdmi_cec_active' "$OUT" "and the sde node's pin list is shown to carry it"
want 'has the consistent list|sde node' "$OUT" "while the undrivable node's list is the consistent one"

scen names-short
OUT=$(run)
want 'pinctrl-0\.\.2: 3 properties, 2 name\(s\)' "$OUT" "a shorter list is counted the same way"
want 'THE NAMES RUN OUT 1 STATE\(S\) EARLY' "$OUT" "and a three-property/two-name node is one state short too"

# ==================================================================================================
echo "== 6. the drivers: source, config, registration, binding =="
# ==================================================================================================
scen idle
OUT=$(run)
want 'registered: no   bound: NONE' "$OUT" "a driver that has not registered is a reading of its own"
want '== verdict: driver-not-registered' "$OUT" \
  "and the rung names a BUILD option rather than a missing driver, which is the next move it implies"
want 'CONFIG_FB_MSM_MDSS_HDMI_PANEL: y \(built in\)' "$OUT" "and the config is asked from the device, not assumed"
want 'CONFIG_DRM  +NOT SET' "$OUT" "the DRM option is printed beside it"
want 'drivers/gpu/drm/msm/hdmi matches' "$OUT" "and the third HDMI driver in the source is named, with the SoCs it does match"
want 'no driver for THESE nodes' "$OUT" "so that 'there is no HDMI driver' cannot be read as true of the source"
want 'driver: +mdss_pll  \(drivers/clk/msm/mdss/mdss-pll.c' "$OUT" "the PLL driver is asked for like the others"
want 'config CONFIG_MSM_MDSS_PLL: y \(built in\)' "$OUT" "with its own config option asked of the device"

scen driver-registered-unbound
OUT=$(run); RC=$?
want 'registered: yes   bound: NONE' "$OUT" "a driver directory with nothing bound is a THIRD reading"
want '== verdict: driver-not-bound' "$OUT" "and it is a rung of its own: the probe ran, or never did"
want 'mdss_hdmi_tx: present, bound: NONE' "$OUT" "with the driver directory named as present rather than absent"
[ "$RC" = 1 ] && ok "and exits 1" || bad "the driver-not-bound verdict exited $RC, not 1"

scen no-config
OUT=$(run)
want 'NOT READ' "$OUT" "a device that cannot be asked has its own state, not 'the option is off'"
want 'so no verdict' "$OUT" "and the probe says the verdicts do not rest on it"
want 'below rests on the config' "$OUT" "in the sentence that draws the line for the reader"

scen config-drm-on
OUT=$(run)
want 'CONFIG_DRM  +y \(built in\)' "$OUT" "a config that says a driver is built is read as such"
want '== verdict: transmitter-bound' "$OUT" \
  "while the rung still follows SYSFS, not the config -- a config that says a whole second HDMI stack is built cannot move it"

# ==================================================================================================
echo "== 7. the framebuffer, which is named by a phandle =="
# ==================================================================================================
scen idle
OUT=$(run)
want 'from: /soc/qcom,hdmi_tx@9a0000   property: qcom,mdss-fb-map' "$OUT" "the fb is read from the transmitter's own property"
want 'phandle 62 -> /soc/qcom,mdss_mdp@900000/qcom,mdss_fb_hdmi' "$OUT" "the phandle is RESOLVED to a path"
want "it is a 'qcom,mdss-fb' node" "$OUT" "and the node's compatible is checked against the driver that would own it"
want 'cell-index: 2 -- and this does NOT decide .*dev/fbN' "$OUT" "cell-index is printed and explicitly disclaimed"
want 'fbi_list\[fbi_list_index\+\+\]' "$OUT" "naming the counter that does decide the fb number"

scen no-fb-map
OUT=$(run); RC=$?
want '== verdict: no-framebuffer' "$OUT" "a transmitter with no fb pointer is its own rung"
want 'returns -ENODEV with' "$OUT" "and the probe names the driver code that returns without it"
[ "$RC" = 1 ] && ok "and exits 1" || bad "the no-framebuffer verdict exited $RC, not 1"

scen fb-map-unresolved
OUT=$(run); RC=$?
want '== verdict: no-framebuffer' "$OUT" "a phandle that resolves to nothing reaches the same rung"
want 'did NOT resolve to exactly one node' "$OUT" "and says which of the two ways it failed"

scen fb-map-ambiguous
OUT=$(run)
want 'AMBIGUOUS\(2\)' "$OUT" "two nodes carrying one phandle is AMBIGUOUS, not a coin flip"
want 'did NOT resolve to exactly one node' "$OUT" "and it is named as a failure to resolve, not as an absence"

# ==================================================================================================
echo "== 8. the framebuffer class, the attributes, and 'connected' =="
# ==================================================================================================
scen transmitter-bound
OUT=$(run); RC=$?
want '== verdict: transmitter-bound' "$OUT" "a bound transmitter whose fb carries its attributes is the top rung"
want "MDSS_EVENT_FB_REGISTERED and this block's protocol readings" "$OUT" "and the rung says what that implies"
want 'the HDMI transmitter.s attributes are here: connected hpd edid video_mode hot_plug' "$OUT" \
  "the attributes are listed for the framebuffer that has them"
want 'connected: 0   hpd: 0' "$OUT" "and the port readings are printed"
want 'edid: .* byte\(s\) reported by the driver.s own attribute' "$OUT" "with the EDID read through the driver's own attribute only"
want 'WRITABLE and left alone: hpd hot_plug edid' "$OUT" "and the writable ones are named as left alone"
[ "$RC" = 0 ] && ok "and exits 0" || bad "the top rung exited $RC, not 0"

scen transmitter-bound
OUT=$(run --quiet)
want '== verdict: transmitter-bound' "$OUT" "--quiet still prints the verdict"
want "AND 'connected: 0' IS NOT A STATEMENT ABOUT THE CABLE" "$OUT" "and the ambiguity paragraph the rung rests on"
notwant '^     compatible: +qcom,hdmi-tx' "$OUT" "while dropping the per-node property dump"
notwant '^     reg: +10092544' "$OUT" "and the register window with it"
notwant '^     pinctrl:' "$OUT" "and the pin-list count"
want '^     status: +absent' "$OUT" "but NOT the status line, which is what the enabled rung is read from"
want 'the driver asks for:  qcom,hdmi-tx-mux-en' "$OUT" "but NOT the per-gpio audit, which the rung rests on"
want 'pinctrl-0\.\.4: 5 properties, 4 name\(s\)' "$OUT" "nor the pin-state dump"

scen bound-no-hdmi-attrs
OUT=$(run); RC=$?
want '== verdict: transmitter-not-attached-to-fb' "$OUT" \
  "a framebuffer without the transmitter's attributes is the rung below the top one"
want 'NONE of them carries the transmitter.s attributes' "$OUT" "and the probe says so in the plural"
[ "$RC" = 1 ] && ok "and exits 1" || bad "that verdict exited $RC, not 1"

scen fb-number
OUT=$(run)
want 'verdict: transmitter-bound' "$OUT" "the fb carrying the transmitter's attributes is found when it is not the second one"
want 'The HDMI one is .*fb3' "$OUT" "IDENTIFIED BY ATTRIBUTE: fb3, which the tree's cell-index would not have pointed at"
want 'fb2' "$OUT" "while the other framebuffer is still listed"

scen no-fb-class
OUT=$(run)
want 'no framebuffer device at all' "$OUT" "a device with no framebuffer class is named as such"
want 'it cannot exist either' "$OUT" "and the consequence for the transmitter's attributes is spelled out"

# ==================================================================================================
echo "== 9. the leaf readings: a bad reg, a bad gpio, an ambiguous phandle =="
# ==================================================================================================
scen bad-reg
OUT=$(run)
want 'reg: +not-u32s\(7 bytes\)' "$OUT" "a reg that is not a whole number of cells says so"
notwant 'reg: +0x9a0000' "$OUT" "rather than reading the first three bytes of four"

scen bad-gpio
OUT=$(run)
want 'not-a-gpio\(3 bytes\)' "$OUT" "a gpio property that is not a whole number of cells says so"
want 'mdss node: not-a-gpio\(3 bytes\)' "$OUT" "and it does so on the node whose property it is"
want 'one of eight|COUNTED, not asserted' "$OUT" "while the audit still counts the names it can read"

scen ambiguous-phandle
OUT=$(run)
want 'AMBIGUOUS\(2\)' "$OUT" "a phandle two nodes carry is reported as ambiguous"

# ==================================================================================================
echo "== 10. the tree that could not be searched, and the scan that found nothing =="
# ==================================================================================================
scen bare-tree
OUT=$(run_nofind); RC=$?
want '== verdict: tree-unscanned' "$OUT" "'could not look' is its own rung and not an absence"
want 'this probe could' "$OUT" "and the probe says which of the two it is looking at"
[ "$RC" = 1 ] && ok "and exits 1" || bad "the unscanned verdict exited $RC, not 1"

scen alien-node
OUT=$(run_nofind)
want '== verdict: no-device-tree-node' "$OUT" "a fallback scan that HAPPENED and found nothing is an absence"
want 'no node in this device tree carries any of the compatibles' "$OUT" "and it is worded as a scan result"

scen no-dt-node
OUT=$(run)
want '== verdict: no-device-tree-node' "$OUT" "a tree with no HDMI node is the absence rung"
want 'in all 15 of this board.s trees' "$OUT" "and the prose says why a missing node is itself a reading"

# ==================================================================================================
echo "== 11. the log =="
# ==================================================================================================
scen log-failing
OUT=$(run)
want 'Unable to read qcom,display-id' "$OUT" "the driver's own probe error is found in the log"
want 'probe of 9a0000.hdmi failed with error -19' "$OUT" "and the failure line beside it"
want 'ONE LINE IN THIS LIST IS EXPECTED ON THIS BOARD' "$OUT" \
  "and the expected-on-this-board line is called out rather than left to be chased"

scen log-quiet
OUT=$(run)
want 'none: the kernel log mentions no HDMI' "$OUT" "a quiet log says so rather than printing nothing"
want 'none: no HDMI probe failure' "$OUT" "for both searches"

scen log-unreadable
OUT=$(run)
want 'the kernel log could not be read' "$OUT" "an unreadable log is NOT READ, a third state"
want 'No verdict below rests on it' "$OUT" "and the probe says the verdicts do not rest on it"

# ==================================================================================================
echo "== 12. the mutations that are readings, not writes =="
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
# 2. THE `absent` STATUS READ AS DISABLED. This is the mutation this block exists for: on this board the
#    ONLY drivable transmitter is the one with no `status` property, so dropping `absent` from the enabled
#    branch turns the kernel's drivable node into a disabled one and the undrivable node into the enabled
#    one -- two readings, both inverted, from one deleted word.
sed 's#case "\$ST" in okay | ok | EMPTY | absent) EN=yes ;; \*) EN=no ;; esac#case "$ST" in okay | ok) EN=yes ;; *) EN=no ;; esac#' \
  "$SRC" > "$W/mut-status.sh"
if cmp -s "$SRC" "$W/mut-status.sh"; then bad "the absent-status mutation did not apply"; else
  scen idle
  OUT=$(mut_run "$W/mut-status.sh")
  notwant 'absent (an absent status means enabled; this node carries none)  (the kernel will create this device)' "$OUT" \
    "reading an absent status as disabled inverts this board's only drivable transmitter (the mutation)"
  want 'Of the 2 transmitter node\(s\), 1 are ENABLED' "$OUT" "and the enabled count changes with it"
fi
# 3. The rung decided by the SOURCE having a driver instead of by the driver REGISTERING. That is the
#    mutation that matters here: it turns "a probe failed" into "the kernel has no HDMI at all".
sed 's#^        R=\$(drv_registered "\$DB" "\$DN")#        R=yes#' "$SRC" > "$W/mut-registered.sh"
if cmp -s "$SRC" "$W/mut-registered.sh"; then bad "the registered mutation did not apply"; else
  scen idle
  OUT=$(mut_run "$W/mut-registered.sh")
  notwant '== verdict: driver-not-registered' "$OUT" \
    "treating a source-matching driver as registered loses the rung this scenario is about -- the one that\n    names a defconfig as the next move (the mutation)"
  want '== verdict: driver-not-bound' "$OUT" "and lands on the rung that sends the reader to the probe, not the config"
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
#    A device tree's u32s are four BIG-endian bytes, so the FIRST byte is the most significant -- and the
#    mutation makes it the least significant, which is what a host-order reader does. It targets the
#    MULTI-cell reader (`dtu32s`, which prints the register window as every cell), not `dtu32`.
sed -e 's#^    0) _us_v=\$((_us_x \* 16777216)) ;;#    0) _us_v=$((_us_x)) ;;#' \
  -e 's#^    1) _us_v=\$((_us_v + _us_x \* 65536)) ;;#    1) _us_v=$((_us_v + _us_x * 256)) ;;#' \
  -e 's#^    2) _us_v=\$((_us_v + _us_x \* 256)) ;;#    2) _us_v=$((_us_v + _us_x * 65536)) ;;#' \
  -e 's#^    3) _us_v=\$((_us_v + _us_x)); _us_out="\$_us_out \$_us_v" ;;#    3) _us_v=$((_us_v + _us_x * 16777216)); _us_out="$_us_out $_us_v" ;;#' \
  "$SRC" > "$W/mut-endian.sh"
if cmp -s "$SRC" "$W/mut-endian.sh"; then bad "the endianness mutation did not apply"; else
  scen idle
  OUT=$(mut_run "$W/mut-endian.sh")
  notwant 'hex: 0x9a0000 0x50c 0x70000 0x6158 0x9e0000 0xfff' "$OUT" \
    "combining the four bytes in the host's order loses the real window (the mutation)"
  notwant 'reg: +10092544 1292 458752 24920 10354688 4095' "$OUT" \
    "in both the decimal and the hex column, because both are read through the same helper"
  want 'hex: 0x9a00 0xc050000 0x700 0x58610000 0x9e00 0xff0f0000' "$OUT" \
    "and what it prints instead has the right SHAPE and the wrong values -- which is why the check is the whole window and not a prefix"
fi
# 6. The pin-state NAME dropped, so a state is printed by its number: the shift disappears exactly, because
#    a list read by index cannot show that its names ran out.
sed 's#^      _nm=\$(printf .%s\\n. "\$_names" | cut -d. . -f\$((_i + 1)))#      _nm="index $_i"#' \
  "$SRC" > "$W/mut-pin.sh"
if cmp -s "$SRC" "$W/mut-pin.sh"; then bad "the pin-state mutation did not apply"; else
  scen idle
  OUT=$(mut_run "$W/mut-pin.sh")
  notwant '<- state name: hdmi_sleep' "$OUT" \
    "printing a pin state by its index instead of its name hides the shift (the mutation)"
  want 'pinctrl-3' "$OUT" "while the state itself is still printed"
fi
# 7. The other generation's spelling dropped from the audit, so the pair reading disappears and the report
#    says a line both nodes lack is a line both nodes lack.
sed "s#^        _alt=\$(gpio_cells \"\$_p/qcom,hdmi-tx\$_sfx-gpio\")#        _alt=absent#" \
  "$SRC" > "$W/mut-alt.sh"
if cmp -s "$SRC" "$W/mut-alt.sh"; then bad "the -gpio mutation did not apply"; else
  scen idle
  OUT=$(mut_run "$W/mut-alt.sh")
  notwant "PRESENT as 'qcom,hdmi-tx-ddc-clk-gpio'" "$OUT" \
    "dropping the -gpio spelling loses the reading that the two nodes are complementary (the mutation)"
  want 'COUNTED, not asserted' "$OUT" "while the audit is still printed"
fi
# 8. The framebuffer identified by the tree's cell-index instead of by the attributes it carries. On a board
#    whose fb number is a registration order, that names the WRONG framebuffer -- and it passes on any
#    fixture where the two happen to agree, which is why the `fb-number` scenario exists.
sed 's#^  case "\$_attrs" in#  case "$(dtu32 "/proc/device-tree${FB_MAP_NODE}/cell-index")" in#' \
  "$SRC" > "$W/mut-fbnum.sh"
if cmp -s "$SRC" "$W/mut-fbnum.sh"; then bad "the fb-number mutation did not apply"; else
  scen fb-number
  OUT=$(mut_run "$W/mut-fbnum.sh")
  notwant 'The HDMI one is .*fb3' "$OUT" \
    "identifying the HDMI framebuffer by cell-index loses the one that actually carries its attributes (the mutation)"
  want 'NONE of them carries the transmitter.s attributes' "$OUT" \
    "and it drops a rung instead, because cell-index 2 is not a device that carries them"
fi
# 9. The `connected`-ambiguity paragraph silenced. This is the reading the whole top rung rests on: without
#    it, a `0` from a port nothing has ever armed looks like a report about the cable.
sed "s#^    always \"   AND 'connected: 0' IS NOT A STATEMENT ABOUT THE CABLE. connected and hpd both read hpd_state,\"#    : \"   AND 'connected: 0' IS NOT A STATEMENT ABOUT THE CABLE.\"#" \
  "$SRC" > "$W/mut-note.sh"
if cmp -s "$SRC" "$W/mut-note.sh"; then bad "the ambiguity-note mutation did not apply"; else
  scen transmitter-bound
  OUT=$(mut_run "$W/mut-note.sh")
  notwant 'more than one producer' "$OUT" \
    "silencing the paragraph removes the reading that keeps an unarmed hpd_state from looking like a cable report (the mutation)"
  want '== verdict: transmitter-bound' "$OUT" "while the verdict itself still stands"
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
  # version of this check on a sibling harness compared 1 against 158. The first match is taken with
  # `sed -n 1p` and NOT with `head -n1`: this file sets pipefail, and a reader that exits early turns the
  # WRITER's SIGPIPE death into the pipeline's status -- a check that would report a failure of its own
  # extractor.
  match=$(tr '\n' ' ' < "$HEALTH" |
    grep -oE 'zl1-hdmi-probe-selftest\.sh[^0-9]*[0-9]+ checks' | sed -n 1p)
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
