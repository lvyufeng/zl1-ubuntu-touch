#!/usr/bin/env bash
# zl1 WFD / writeback probe -- offline self-test. Host-side, touches no device, needs no phone.
#
# Why this exists. `scripts/device/zl1-wfd-probe.sh` is the instrument for the `wfd` row of doc 137's gap
# list. That row is not one device either, and the readings that make the probe's design are these:
#
#   1. THE BLOCK IS TWO NODES AND THE NUMBERS ARE ON TWO OTHERS. `/soc/qcom,mdss_wb_panel` (`qcom,mdss_wb`)
#      is the panel; its `qcom,mdss-fb-map` phandle resolves to `.../qcom,mdss_fb_wfd` (`qcom,mdss-fb`,
#      `cell-index = 1`); `/soc/qcom/display-manager/qcom,wb-display@0` (`qcom,wb-display`) matches NOTHING
#      in this kernel source; `qcom,mdss-wb-count` is on the ROTATOR; and `qcom,mdss-wfd-mode`,
#      `qcom,mdss-wb-off` and `qcom,mdss-mixer-wb-off` are on the mdss_mdp node. The `node-count` and
#      `alien-node` scenarios are what make "the scan found the block" a reading rather than a pattern's
#      accident -- and `compatible-list` is the one that keeps `compatible` read as the LIST it is.
#   2. ONE STRING DECIDES HOW MANY WRITEBACK BLOCKS EXIST. `qcom,mdss-wfd-mode` is read TWICE from the
#      mdss_mdp node: once into `mdata->wfd_mode`, and again by `mdss_mdp_parse_dt_wb()` for `num_intf_wb`.
#      The probe prints the arithmetic (`num_block_wb + num_intf_wb` against the tree's own offset count),
#      because on this board the two agree ONLY BECAUSE the string is `intf` -- and the `mode-shared`
#      scenario is that sentence made checkable. The `mode-shared` mutation-free check and the
#      `mut-intf` mutation are the two halves of it.
#   3. THE CHAIN IS A PHANDLE READ FROM THE PANEL'S OWN NODE. `mdss_register_panel()` reads
#      `qcom,mdss-fb-map` and, without it, logs "Unable to find fb node for device" and returns -ENODEV --
#      while `mdss_wb_probe()`'s error path UNREGISTERS the switch it registered first. So the switch's
#      existence is an end-to-end witness, and `no-switch` is the scenario where the driver bound and the
#      chain still stopped. `no-fb-map`, `fb-map-unresolved` and `fb-map-ambiguous` are the three ways the
#      phandle fails.
#   4. THE WRITE-CLASS MOVE OF THIS BLOCK IS AN IOCTL. `/sys/class/switch/wfd/state` is
#      `DEVICE_ATTR(state, S_IRUGO, state_show, NULL)` -- a NULL store -- so the write the probe must not
#      make is `ioctl(/dev/graphics/fbN, MDP_WRITEBACK_MIRROR_ON)`, and the attributes beside it (`blank`,
#      `dsi_write`, `trigger_reset`) are writable too. The static guard below has teeth for both, plus a
#      `dd of=/dev/graphics/fbN` and a heredoc of prose that must NOT be read as code.
#   5. WHICH /dev/fbN IS THE WRITEBACK ONE IS THE PANEL TYPE, NOT THE NUMBER. `msm_fb_type` prints
#      "writeback panel", the kernel looks for `panel.type == WRITEBACK_PANEL`, and the number is a
#      registration order. The `fb-number` scenario puts the writeback framebuffer at fb3 with fb1 present
#      as another panel, so identifying it by a number is a check that can fail.
#
# How it works: **the stub directory IS the device.** The probe runs as itself against a fake root, with the
# device's tools stubbed and PATH sandboxed to `$STUB:$MINBIN`, where MINBIN holds symlinks to the real
# coreutils. The rewrite covers `/proc/`, `/sys/`, `/dev/fb` and `/dev/graphics/` -- the last two because
# the probe NAMES a framebuffer device in its prose and in its write-guard paragraph, and a rename that
# re-rooted only the roots it reads today would leave a future `> /dev/graphics/fb0` escaping to this
# laptop. `/dev/null` does not share either prefix and is asserted to survive.
#
# Usage: zl1-wfd-probe-selftest.sh [--keep]
#   --keep   leave the fake device, the stubs and the rewritten probe for inspection
#
# `ZL1_WFD_PROBE_SRC=/path` runs the whole thing against another copy of the subject, which is how a
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
SRC="${ZL1_WFD_PROBE_SRC:-$HERE/../device/zl1-wfd-probe.sh}"
[ -r "$SRC" ] || { echo "cannot read the subject: $SRC" >&2; exit 2; }

W="${TMPDIR:-/tmp}/zl1-wfd-probe-selftest"
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
# The probe reads the device tree with `find`, resolves phandles with it, counts the property cells with
# `od`, and shortens a path with `basename`; a sandbox missing one of these would silently turn a reading
# into an absence. So each tool the probe calls is required by name before anything runs.
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
# FOUR RULES. `/proc/` carries the device tree, the boot id, the uptime and the kernel config; `/sys/`
# carries the buses, the classes, the switch, the framebuffer attributes and the config's own path; and
# `/dev/fb` and `/dev/graphics/` are here even though the probe only NAMES a framebuffer device today -- a
# rename that re-rooted only what the probe reads right now would leave a future `> /dev/graphics/fb0`
# escaping to this laptop, which is the defect this whole rewrite exists to prevent. `/dev/null` does not
# share either prefix.
cnt() { grep -o -- "$1" "$2" 2>/dev/null | wc -l | tr -d ' '; }
rewrite() { # $1 = source, $2 = output
  sed -e 's#/proc/#__ZP__#g' "$1" > "$W/pass1a.sh"
  sed -e 's#/sys/#__ZS__#g' "$W/pass1a.sh" > "$W/pass1b.sh"
  sed -e 's#/dev/graphics/#__ZGF__#g' "$W/pass1b.sh" > "$W/pass1c.sh"
  sed -e 's#/dev/fb#__ZBF__#g' "$W/pass1c.sh" > "$W/pass1.sh"
  sed -e "s#__ZP__#$FR/proc/#g" -e "s#__ZS__#$FR/sys/#g" -e "s#__ZGF__#$FR/dev/graphics/#g" \
    -e "s#__ZBF__#$FR/dev/fb#g" "$W/pass1.sh" > "$2"
}
# The whole chain is applied to the SUBJECT once here to prove every rule matched something and that the
# source has no `/proc/` or `/sys/` left; `rewrite` is then reused for the mutated copies.
RW="$W/wfd-probe.sh"
sed -e 's#/proc/#__ZP__#g' "$SRC" > "$W/pass1a.sh"
[ "$(cnt '/proc/' "$SRC")" = "$(cnt '__ZP__' "$W/pass1a.sh")" ] \
  || { echo "the /proc/ rewrite did not cover every /proc/ in the source" >&2; exit 2; }
[ "$(cnt '/proc/' "$W/pass1a.sh")" = 0 ] || { echo "a /proc/ survived pass 1 -- the probe would read this host" >&2; exit 2; }
sed -e 's#/sys/#__ZS__#g' "$W/pass1a.sh" > "$W/pass1b.sh"
[ "$(cnt '/sys/' "$W/pass1a.sh")" = "$(cnt '__ZS__' "$W/pass1b.sh")" ] \
  || { echo "the /sys/ rewrite did not cover every /sys/ in the source" >&2; exit 2; }
[ "$(cnt '/sys/' "$W/pass1b.sh")" = 0 ] || { echo "a /sys/ survived pass 1" >&2; exit 2; }
sed -e 's#/dev/graphics/#__ZGF__#g' "$W/pass1b.sh" > "$W/pass1c.sh"
[ "$(cnt '/dev/graphics/' "$W/pass1b.sh")" = "$(cnt '__ZGF__' "$W/pass1c.sh")" ] \
  || { echo "the /dev/graphics/ rewrite did not cover every occurrence" >&2; exit 2; }
[ "$(cnt '/dev/graphics/' "$W/pass1c.sh")" = 0 ] || { echo "a /dev/graphics/ survived pass 1" >&2; exit 2; }
sed -e 's#/dev/fb#__ZBF__#g' "$W/pass1c.sh" > "$W/pass1.sh"
[ "$(cnt '/dev/fb' "$W/pass1c.sh")" = "$(cnt '__ZBF__' "$W/pass1.sh")" ] \
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
for tok in __ZP__ __ZS__ __ZBF__ __ZGF__; do
  [ "$(cnt "$tok" "$W/pass1.sh")" -gt 0 ] || { echo "no $tok token was produced -- that rule matched nothing" >&2; exit 2; }
done
grep -qF "$FR$FR" "$RW" && { echo "a rewrite cascaded: $FR appears twice in a row" >&2; exit 2; }
grep -qF "$FR/proc/$FR" "$RW" && { echo "a rewrite cascaded into the fake root's own proc/" >&2; exit 2; }
# The paths the probe's answers hang on, named -- a rule that silently stopped applying would be invisible
# to the counts above if its occurrences moved into a comment.
for need in "$FR/proc/device-tree/model" "$FR/proc/device-tree/compatible" \
  "$FR/proc/sys/kernel/random/boot_id" "$FR/proc/uptime" "$FR/proc/config.gz" \
  "$FR/sys/bus/" "$FR/sys/class/switch/wfd" "$FR/sys/class/graphics/fb" \
  "$FR/dev/fb" "$FR/dev/graphics/fb"; do
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
# The teeth, and the first two are the writes this block's own paragraph names as the ones NOT made: the
# switch state that an MDP ioctl writes, and a blank/DSI write into a panel that a compositor is scanning.
printf '%s\n' '# a fixture for the redirect rule: the writeback switch state' \
  'printf 1 > /sys/class/switch/wfd/state' > "$W/teeth-switch.sh"
printf '%s\n' '# a fixture for the same rule: blanking a framebuffer' \
  'printf 1 > /sys/class/graphics/fb1/blank' > "$W/teeth-blank.sh"
printf '%s\n' '# a fixture for the same rule: a DSI command written into a panel' \
  'printf 0x05 > /sys/class/graphics/fb1/dsi_write' > "$W/teeth-dsi.sh"
printf '%s\n' '# a fixture for the command-position rule, in the shape this block invites: an ioctl is not' \
  '#' 'shell, so the nearest shell equivalent is a dd straight onto the framebuffer device' \
  'dd if=/dev/zero of=/dev/graphics/fb1 bs=4096 count=1' > "$W/teeth-dd.sh"
printf '%s\n' '# a fixture for the command-position rule' \
  'modprobe mdss_wb' > "$W/teeth-cmd.sh"
printf '%s\n' '# prose that must not be read as code' \
  "cat <<'EOF'" \
  'the mirror hint would be ioctl(/dev/graphics/fb1, MDP_WRITEBACK_MIRROR_ON), and writing /sys/class/switch/wfd/state is refused by the kernel anyway' \
  'EOF' \
  'say "the arrow -> /sys/class/graphics/fb1/blank is how this page writes a path"' > "$W/teeth-prose.sh"
want 'wfd/state' "$(write_sites "$W/teeth-switch.sh")" \
  "the guard catches a redirect into the writeback switch's state (as a fixture)"
want 'blank' "$(write_sites "$W/teeth-blank.sh")" "and one into a framebuffer attribute"
want 'dsi_write' "$(write_sites "$W/teeth-dsi.sh")" "and one that writes a DSI command into the panel"
want 'dd if=/dev/zero of=/dev/graphics/fb1' "$(write_sites "$W/teeth-dd.sh")" \
  "and a dd straight onto the framebuffer device, which is the shell's nearest thing to the ioctl this block's write-class move really is"
want 'modprobe mdss_wb' "$(write_sites "$W/teeth-cmd.sh")" "and a state-changing command in command position"
notwant '.' "$(write_sites "$W/teeth-prose.sh")" \
  "and does not punish prose that names an arrow before a /sys path, or a heredoc about an ioctl"
wantf 'ioctl(/dev/graphics/fb1, MDP_WRITEBACK_MIRROR_ON)' "$(cat "$W/teeth-prose.sh")" \
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
# A NUL-separated string LIST (a `compatible` list), written as the bytes it is.
dtlistp() { mkdir -p "$(dirname "$1")"; printf "$2" > "$1"; }

# The two boards' root properties, exactly as the flashed blob carries them. Both declare the same
# writeback panel at the same path with the same bytes, so only `model` can tell them apart.
MODEL_ZL1='Letv Technologies, Inc. MSM 8996pro + PMI8996 LE_ZL1-DVT1'
MODEL_X2='Letv Technologies, Inc. MSM 8996 v3 + PMI8996 LE_X2-PVT'

# THE PANEL. No `status` property at all -- which the device tree reads as ENABLED -- 640x480 at 24bpp, and
# a `qcom,mdss-fb-map` of phandle 60 pointing at the wfd framebuffer child.
wb_panel_node() {
  D="$FR/proc/device-tree/soc/qcom,mdss_wb_panel"
  dtp "$D/compatible" 'qcom,mdss_wb'
  dtu32p "$D/qcom,mdss-fb-map" '\000\000\000\074'
  dtu32p "$D/qcom,mdss_pan_res" '\000\000\002\200\000\000\001\340'
  dtu32p "$D/qcom,mdss_pan_bpp" '\000\000\000\030'
}
# THE FRAMEBUFFER the panel's phandle points at, carrying BOTH `phandle` and `linux,phandle` -- as every
# mdss node in this tree does. That pair is not decoration: it is the trap that makes a phandle resolver
# which counts FILES instead of NODES report the one real hit as AMBIGUOUS(2), which is one of the
# mutations below.
wfd_fb_node() {
  F="$FR/proc/device-tree/soc/qcom,mdss_mdp@900000/qcom,mdss_fb_wfd"
  dtp "$F/compatible" 'qcom,mdss-fb'
  dtu32p "$F/cell-index" '\000\000\000\001'
  dtu32p "$F/phandle" '\000\000\000\074'
  dtu32p "$F/linux,phandle" '\000\000\000\074'
}
# The OTHER framebuffer children, so a probe that scanned `qcom,mdss-fb` would find four nodes and have to
# guess which one is this block's. The block is reached through the panel's phandle instead.
other_fb_children() {
  P="$FR/proc/device-tree/soc/qcom,mdss_mdp@900000/qcom,mdss_fb_primary"
  dtp "$P/compatible" 'qcom,mdss-fb'
  dtu32p "$P/cell-index" '\000\000\000\000'
  H="$FR/proc/device-tree/soc/qcom,mdss_mdp@900000/qcom,mdss_fb_hdmi"
  dtp "$H/compatible" 'qcom,mdss-fb'
  dtu32p "$H/cell-index" '\000\000\000\002'
  S="$FR/proc/device-tree/soc/qcom,mdss_mdp@900000/qcom,mdss_fb_secondary"
  dtp "$S/compatible" 'qcom,mdss-fb'
  dtu32p "$S/cell-index" '\000\000\000\003'
}
# The generation's display-manager child: `qcom,wb-display`, which appears in eight device-tree files of
# this project's reference tree and in not one .c or .h file -- so it is a node nothing can bind, and it is
# part of the block's node count.
wb_display_node() {
  G="$FR/proc/device-tree/soc/qcom/display-manager/qcom,wb-display@0"
  dtp "$G/compatible" 'qcom,wb-display'
  dtu32p "$G/cell-index" '\000\000\000\002'
  dtp "$G/label" 'wb_display'
}
# The rotator, which is where the block's HARDWARE COUNT lives: mdss_rotator.c reads `qcom,mdss-wb-count`
# and prints "Error in device tree" and refuses to probe without it.
rotator_node() {
  R="$FR/proc/device-tree/soc/qcom,mdss_rotator"
  dtp "$R/compatible" 'qcom,mdss_rotator'
  dtu32p "$R/qcom,mdss-wb-count" '\000\000\000\002'
}
# The mdss_mdp node: the wfd-mode string and the two offset arrays, whose LENGTHS are the counts the driver
# allocates from. The real cells: qcom,mdss-wb-off = 413696 415744 417792 (three), qcom,mdss-mixer-wb-off =
# 294912 299008 (two), and qcom,mdss-wfd-mode = "intf" -- so num_block_wb(2) + num_intf_wb(1) = 3, which is
# exactly the number of offsets the tree lists.
mdp_node() {
  M="$FR/proc/device-tree/soc/qcom,mdss_mdp@900000"
  dtp "$M/compatible" 'qcom,mdss_mdp'
  dtu32p "$M/phandle" '\000\000\000\063'
  dtu32p "$M/linux,phandle" '\000\000\000\063'
  dtp "$M/qcom,mdss-wfd-mode" 'intf'
  dtu32p "$M/qcom,mdss-wb-off" '\000\006\120\000\000\006\130\000\000\006\140\000'
  dtu32p "$M/qcom,mdss-mixer-wb-off" '\000\004\200\000\000\004\220\000'
}

# The kernel config, as the flashed boot image's own kernel carries it: the whole display stack and the
# writeback panel are BUILT, and there is no rotator option in the file at all -- because mdss_rotator.c is
# built by CONFIG_FB_MSM_MDSS via mdss-mdp-objs and has no option of its own.
config_realistic() {
  { printf '# Automatically generated file; DO NOT EDIT.\n'
    printf 'CONFIG_IKCONFIG=y\n'
    printf 'CONFIG_IKCONFIG_PROC=y\n'
    printf 'CONFIG_FB_MSM_MDSS=y\n'
    printf 'CONFIG_FB_MSM_MDSS_COMMON=y\n'
    printf 'CONFIG_FB_MSM_MDSS_WRITEBACK=y\n'
    printf 'CONFIG_FB_MSM_MDSS_HDMI_PANEL=y\n'
    printf '# CONFIG_MSM_SDE_ROTATOR is not set\n'
    printf '# CONFIG_DRM is not set\n'; } > "$W/kernel.config"
}
cat > "$STUB/zcat" <<'STUBEOF'
#!/bin/sh
cat "$CONFIGFILE"
STUBEOF
cat > "$STUB/gunzip" <<'STUBEOF'
#!/bin/sh
cat "$CONFIGFILE"
STUBEOF
chmod +x "$STUB/zcat" "$STUB/gunzip"

# The fb attributes the probe looks for on the writeback framebuffer: the mdss group, all of them writable
# and all of them left alone.
wb_fb_attrs() { # $1 = the fb directory
  mkdir -p "$1"
  printf 'mdssfb_280\n' > "$1/name"
  printf 'writeback panel\n' > "$1/msm_fb_type"
  for a in blank msm_fb_panel_status msm_fb_dfps_mode idle_time msm_fb_thermal_level disable_bl_scaling \
    trigger_reset dsi_write; do printf '0\n' > "$1/$a"; done
}
other_fb() { # $1 = dir, $2 = name
  mkdir -p "$1"
  printf '%s\n' "$2" > "$1/name"
  printf 'primary panel\n' > "$1/msm_fb_type"
  printf '0\n' > "$1/blank"
}
# The driver directories, and `bound` attaches a device to one of them: a directory with nothing in it is a
# DIFFERENT reading from a directory that is absent.
driver_dirs() {
  for d in mdss_wb mdss_fb mdss_rotator mdp; do
    mkdir -p "$FR/sys/bus/platform/drivers/$d"
    : > "$FR/sys/bus/platform/drivers/$d/bind"
    : > "$FR/sys/bus/platform/drivers/$d/unbind"
    : > "$FR/sys/bus/platform/drivers/$d/uevent"
  done
}
bind_device() { # $1 = driver dir name, $2 = device name
  mkdir -p "$FR/sys/bus/platform/devices/$2"
  ln -sfn "$FR/sys/bus/platform/devices/$2" "$FR/sys/bus/platform/drivers/$1/$2"
}

scen() {
  SCEN="$1"
  rm -rf "$FR"
  mkdir -p "$FR/proc/sys/kernel/random" "$FR/proc/device-tree/soc" \
    "$FR/sys/bus/platform/drivers" "$FR/sys/bus/platform/devices" \
    "$FR/sys/class/graphics" "$FR/sys/class/switch" "$FR/dev"

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
  *) config_realistic; cp "$W/kernel.config" "$FR/proc/config.gz" ;;
  esac

  case "$SCEN" in
  unknown-model) printf 'Letv Technologies, Inc. LE_UNKNOWN-XYZ\0' > "$FR/proc/device-tree/model" ;;
  no-model) rm -f "$FR/proc/device-tree/model" ;;
  x2-tree) printf '%s\0' "$MODEL_X2" > "$FR/proc/device-tree/model" ;;
  # A tree that is not a tree: no nodes anywhere, so a scan without find(1) has nothing to look AT --
  # which is a different state from a scan that ran and found no node it was looking for.
  bare-tree) rmdir "$FR/proc/device-tree/soc" ;;
  esac

  # The device tree's writeback nodes. The default is the real zl1 shape.
  case "$SCEN" in
  no-wb-node | bare-tree | alien-node) : ;;
  panel-disabled)
    wb_panel_node; dtp "$FR/proc/device-tree/soc/qcom,mdss_wb_panel/status" 'disabled'
    wfd_fb_node; other_fb_children; wb_display_node; rotator_node; mdp_node
    ;;
  compatible-list)
    # `compatible` is a LIST, and the scan finds this node because the list CONTAINS the block's string. A
    # probe that classified on the FIRST entry alone would find the node and then decline to count it --
    # printing 'the panel is not enabled' on a tree where it is.
    wb_panel_node
    dtlistp "$FR/proc/device-tree/soc/qcom,mdss_wb_panel/compatible" 'qcom,mdss-fb\000qcom,mdss_wb\000'
    wfd_fb_node; other_fb_children; wb_display_node; rotator_node; mdp_node
    ;;
  no-fb-map)
    wb_panel_node; rm -f "$FR/proc/device-tree/soc/qcom,mdss_wb_panel/qcom,mdss-fb-map"
    wfd_fb_node; other_fb_children; wb_display_node; rotator_node; mdp_node
    ;;
  fb-map-unresolved)
    wb_panel_node
    dtu32p "$FR/proc/device-tree/soc/qcom,mdss_wb_panel/qcom,mdss-fb-map" '\000\000\000\055'
    wfd_fb_node; other_fb_children; wb_display_node; rotator_node; mdp_node
    ;;
  fb-map-ambiguous)
    wb_panel_node; wfd_fb_node; other_fb_children; wb_display_node; rotator_node; mdp_node
    # A second node carrying the framebuffer's phandle: a hand-built tree can do that, and the probe must
    # say AMBIGUOUS rather than pick one -- the wrong node is the wrong framebuffer.
    dtu32p "$FR/proc/device-tree/soc/qcom,mdss_mdp@900000/qcom,mdss_fb_other/phandle" '\000\000\000\074'
    ;;
  panres-absent)
    wb_panel_node; rm -f "$FR/proc/device-tree/soc/qcom,mdss_wb_panel/qcom,mdss_pan_res"
    wfd_fb_node; other_fb_children; wb_display_node; rotator_node; mdp_node
    ;;
  panres-odd)
    # Three cells is not a resolution. The probe must say what it read rather than take the first two.
    wb_panel_node
    dtu32p "$FR/proc/device-tree/soc/qcom,mdss_wb_panel/qcom,mdss_pan_res" '\000\000\002\200\000\000\001\340\000\000\000\000'
    wfd_fb_node; other_fb_children; wb_display_node; rotator_node; mdp_node
    ;;
  no-rotator)
    wb_panel_node; wfd_fb_node; other_fb_children; wb_display_node; mdp_node
    ;;
  mode-shared)
    wb_panel_node; wfd_fb_node; other_fb_children; wb_display_node; rotator_node; mdp_node
    dtp "$FR/proc/device-tree/soc/qcom,mdss_mdp@900000/qcom,mdss-wfd-mode" 'shared'
    ;;
  mode-absent)
    wb_panel_node; wfd_fb_node; other_fb_children; wb_display_node; rotator_node; mdp_node
    rm -f "$FR/proc/device-tree/soc/qcom,mdss_mdp@900000/qcom,mdss-wfd-mode"
    ;;
  mode-bogus)
    wb_panel_node; wfd_fb_node; other_fb_children; wb_display_node; rotator_node; mdp_node
    dtp "$FR/proc/device-tree/soc/qcom,mdss_mdp@900000/qcom,mdss-wfd-mode" 'mirrored'
    ;;
  wb-off-two)
    wb_panel_node; wfd_fb_node; other_fb_children; wb_display_node; rotator_node; mdp_node
    dtu32p "$FR/proc/device-tree/soc/qcom,mdss_mdp@900000/qcom,mdss-wb-off" '\000\006\120\000\000\006\130\000'
    ;;
  wb-off-absent)
    wb_panel_node; wfd_fb_node; other_fb_children; wb_display_node; rotator_node; mdp_node
    rm -f "$FR/proc/device-tree/soc/qcom,mdss_mdp@900000/qcom,mdss-wb-off"
    ;;
  *)
    wb_panel_node; wfd_fb_node; other_fb_children; wb_display_node; rotator_node; mdp_node
    ;;
  esac
  # `alien-node`: a node of the RIGHT SHAPE carrying a compatible nothing in this block uses, so a scan
  # without find(1) is a scan that HAPPENED and found nothing -- which is a different state from "could not
  # look", and the only scenario that can tell the two apart.
  if [ "$SCEN" = alien-node ]; then
    dtp "$FR/proc/device-tree/soc/qcom,alien-display@1/compatible" 'qcom,alien-wfd'
  fi

  # The driver directories. `driver-unregistered` has no mdss_wb directory at all; `driver-unbound` has the
  # directory with nothing attached.
  case "$SCEN" in
  no-wb-node | bare-tree | alien-node | panel-disabled) : ;;
  driver-unregistered) driver_dirs; rm -rf "$FR/sys/bus/platform/drivers/mdss_wb" ;;
  driver-unbound) driver_dirs ;;
  *) driver_dirs ;;
  esac
  case "$SCEN" in
  driver-unregistered | driver-unbound | no-wb-node | bare-tree | alien-node | panel-disabled) : ;;
  *) bind_device mdss_wb qcom,mdss_wb_panel ;;
  esac
  case "$SCEN" in
  no-wb-node | bare-tree | alien-node | panel-disabled) : ;;
  *)
    bind_device mdp mdss_mdp
    bind_device mdss_fb qcom,mdss_fb_wfd
    ;;
  esac
  case "$SCEN" in
  no-rotator | no-wb-node | bare-tree | alien-node | panel-disabled) : ;;
  *) bind_device mdss_rotator qcom,mdss_rotator ;;
  esac

  # The switch, and the framebuffer class. An ABSENT switch is the end-to-end witness failing: the driver
  # registers it before it looks the framebuffer up, and the error path unregisters it again.
  case "$SCEN" in
  no-switch | no-wb-node | bare-tree | alien-node | driver-unbound | driver-unregistered) : ;;
  *)
    mkdir -p "$FR/sys/class/switch/wfd"
    printf 'wfd\n' > "$FR/sys/class/switch/wfd/name"
    printf '0\n' > "$FR/sys/class/switch/wfd/state"
    ;;
  esac
  case "$SCEN" in
  no-fb-class | no-wb-node | bare-tree | alien-node | driver-unbound | driver-unregistered | no-switch) : ;;
  fb-number)
    # THE FB NUMBER IS A REGISTRATION ORDER, NOT THE TREE'S cell-index. Here the framebuffer that reports
    # 'writeback panel' is fb3, while fb1 exists as another panel -- so identifying it by a number is a
    # check that can fail, and it is not the number the tree would suggest.
    other_fb "$FR/sys/class/graphics/fb0" mdssfb_438
    other_fb "$FR/sys/class/graphics/fb1" mdssfb_wfd
    other_fb "$FR/sys/class/graphics/fb2" mdssfb_hist
    wb_fb_attrs "$FR/sys/class/graphics/fb3"
    ;;
  no-wb-fb)
    # The switch exists, so mdss_register_panel() succeeded and a device was created for the framebuffer
    # node -- but no fbN reports the writeback panel type, so that device's own probe did not complete.
    other_fb "$FR/sys/class/graphics/fb0" mdssfb_438
    other_fb "$FR/sys/class/graphics/fb1" mdssfb_280
    ;;
  *)
    other_fb "$FR/sys/class/graphics/fb0" mdssfb_438
    wb_fb_attrs "$FR/sys/class/graphics/fb1"
    ;;
  esac

  # The kernel log. `log-unreadable` makes BOTH readers fail -- the only honest way to reach "not read".
  LOGMODE=normal
  [ "$SCEN" = log-unreadable ] && LOGMODE=unreadable
  case "$SCEN" in
  log-failing)
    { printf '[    0.000000] Booting Linux on physical CPU 0x0\n'
      printf '[    1.200000] mdss_wb: mdss_wb_probe: unable to register writeback panel\n'
      printf '[    1.200000] mdss_fb: Unable to find fb node for device: qcom,mdss_wb_panel\n'
      printf '[    1.210000] mdss_wb: probe of qcom,mdss_wb_panel failed with error -19\n'
      printf '[   30.000000] random: crng init done\n'; } > "$W/kernel.log"
    ;;
  log-quiet)
    { printf '[    0.000000] Booting Linux on physical CPU 0x0\n'
      printf '[   30.000000] random: crng init done\n'; } > "$W/kernel.log"
    ;;
  log-unreadable) : > "$W/kernel.log" ;;
  *)
    # A boot where the block came up, and one line that must NOT be read as a failure: mdss_mdp.c warns
    # "wfd mode not configured. Set to default: Shared" only when the property is absent, and this tree
    # carries it -- so the probe names that line as evidence the kernel read a DIFFERENT tree.
    { printf '[    0.000000] Booting Linux on physical CPU 0x0\n'
      printf '[    1.150000] mdss_mdp: wfd mode: intf\n'
      printf '[    1.160000] mdss_wb: adding framebuffer device qcom,mdss_wb_panel\n'
      printf '[    1.170000] Console: switching to colour frame buffer device 80x60\n'
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
want '^# zl1 WFD / writeback probe' "$OUT" "--help prints the probe's own header"
want 'the writeback panel.' "$(run --explain)" "--explain opens by naming the panel node"
want 'num_intf_wb' "$(run --explain)" "and names the number that is derived from a string"
want 'qcom,mdss-fb-map' "$(run --explain)" "and the phandle the chain fails on"
want 'DEVICE_ATTR\(state, S_IRUGO, state_show, NULL\)' "$(run --explain)" \
  "and says out loud that the switch attribute has no store, so the write move is an ioctl"
want 'registration order' "$(run --explain)" "and says the fb number is a registration order"
want 'mdssfb_280' "$(run --explain)" "and names what the fb's own name really encodes"
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
want 'BOTH declare the same' "$OUT" \
  "naming why the tree's shape cannot tell the two boards apart"
want 'writeback panel at the same path' "$OUT" "in a sentence that is wrapped, so it is matched where it is written"
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
echo "== 3. the block's nodes, and the three counts that are not the same number =="
# ==================================================================================================
scen idle
OUT=$(run); RC=$?
want '/soc/qcom,mdss_wb_panel' "$OUT" "the writeback panel is read by its path"
want '/soc/qcom/display-manager/qcom,wb-display@0' "$OUT" "and the display-manager child, which no driver binds"
want 'compatible:  qcom,mdss_wb' "$OUT" "the panel's compatible is printed"
want 'status: +absent \(an absent status means enabled; this node carries none\)' "$OUT" \
  "and the node with NO status is read as ENABLED, which is what this board's panel carries"
want "NONE in this kernel source matches 'qcom,wb-display'" "$OUT" \
  "the display-manager child is named as matching nothing -- under any config"
want '2 node\(s\) in this tree belong to the block \(1 of them the writeback panel\)' "$OUT" \
  "the node count is measured, not left to the pattern"
want '1 of 1 panel node\(s\) are ENABLED' "$OUT" "and so is the enabled count"
want '1 of those MATCH a driver in this kernel source' "$OUT" "and the driver-match count"
want '1 of those have that driver REGISTERED in this boot' "$OUT" "and the registered count"
want '1 of those have it BOUND to the device' "$OUT" "and the bound count"
want '== verdict: writeback-panel-registered' "$OUT" "the whole chain being in place is its own rung"
[ "$RC" = 0 ] && ok "and exits 0, which is the only rung that does" || bad "the top rung exited $RC, not 0"

scen compatible-list
OUT=$(run); RC=$?
want 'compatible:  qcom,mdss-fb qcom,mdss_wb' "$OUT" "a compatible LIST is printed whole"
want '1 of 1 panel node\(s\) are ENABLED' "$OUT" \
  "and the block's own string is found in the LIST even when it is not the first entry"
want '== verdict: writeback-panel-registered' "$OUT" "so the verdict is the same as the plain tree's"
[ "$RC" = 0 ] && ok "and it exits 0 too" || bad "the compatible-list case exited $RC, not 0"

scen panel-disabled
OUT=$(run); RC=$?
want '== verdict: no-panel-enabled' "$OUT" "a panel the tree switches off is its own rung"
notwant '1 of 1 panel node\(s\) are ENABLED' "$OUT" \
  "with the enabled count dropping -- and the same check in the idle scenario proves it reads 1 when it should"
want '0 of 1 panel node\(s\) are ENABLED' "$OUT" "to zero, which is the number the rung is decided on"
[ "$RC" = 1 ] && ok "and exits 1" || bad "the panel-disabled verdict exited $RC, not 1"

scen no-wb-node
OUT=$(run); RC=$?
want '== verdict: no-device-tree-node' "$OUT" "a tree with no writeback node at all is the rung above that"
want 'no node in this device tree carries' "$OUT" "and it says the SCAN found nothing, not that a lookup failed"
[ "$RC" = 1 ] && ok "and exits 1" || bad "the no-node verdict exited $RC, not 1"

# ==================================================================================================
echo "== 4. the string that decides how many writeback blocks exist =="
# ==================================================================================================
scen idle
OUT=$(run)
want 'qcom,mdss-wfd-mode: intf' "$OUT" "the mode string is printed"
want 'mdata->wfd_mode = MDSS_MDP_WFD_INTERFACE' "$OUT" "with its first consequence, from mdss_mdp.c"
want 'num_intf_wb = 1 -- ONE extra' "$OUT" "and its second, from mdss_mdp_parse_dt_wb()"
want 'THREE COUNTS FROM THREE PLACES, AND THEY ARE NOT THE SAME NUMBER' "$OUT" \
  "the three counts are laid out together rather than left to arithmetic"
want 'qcom,mdss-wb-count      on the ROTATOR   = 2' "$OUT" "the rotator's own count is one of them"
want 'qcom,mdss-mixer-wb-off  on THIS node    = 2 cell\(s\)' "$OUT" "the wb mixer offsets are the second"
want 'qcom,mdss-wb-off        on THIS node    = 3 cell\(s\)' "$OUT" "and the wb offsets are the third"
want 'qcom,mdss-wfd-mode = intf -> num_intf_wb = 1' "$OUT" \
  "and the fourth is named as derived from a string rather than from a property"
want '= 2 \+ 1 = 3 entries' "$OUT" "the arithmetic the driver does is printed"
want 'THEY AGREE' "$OUT" "and the tree's own offset count is compared with it"
want "it agrees here ONLY BECAUSE the wfd-mode string" "$OUT" \
  "with the reason it agrees -- which is the reading, not the agreement"
want 'qcom,mdss-wb-off: +413696 415744 417792' "$OUT" "every cell of the offset array is printed"

scen mode-shared
OUT=$(run)
want 'qcom,mdss-wfd-mode: shared' "$OUT" "a tree that says 'shared' is printed as such"
want 'num_intf_wb = 0 -- no interface' "$OUT" \
  "and num_intf_wb is 0 there, which is the whole reason the string matters"
want '= 2 \+ 0 = 2 entries' "$OUT" "so the driver would allocate two blocks"
want 'THEY DO NOT AGREE \(3 offsets against 2 allocated blocks\)' "$OUT" \
  "while the tree still lists three offsets -- a mismatch nothing in the driver compares"

scen mode-absent
OUT=$(run)
want 'qcom,mdss-wfd-mode: absent' "$OUT" "an absent property is a state, not a blank"
want 'ABSENT IS NOT NEUTRAL HERE' "$OUT" "and it is named as the thing that changes the count"
want 'NO interface-writeback' "$OUT" "with the consequence spelled out"

scen mode-bogus
OUT=$(run)
want "NOT one of intf / shared / dedicated" "$OUT" \
  "a value the driver does not know is named as such rather than silently defaulted"

scen wb-off-two
OUT=$(run)
want 'qcom,mdss-wb-off        on THIS node    = 2 cell\(s\)' "$OUT" "a shorter offset array is counted as what it is"
want 'THEY DO NOT AGREE \(2 offsets against 3 allocated blocks\)' "$OUT" \
  "and the disagreement is reported -- a reading, not a crash"

scen wb-off-absent
OUT=$(run)
want 'qcom,mdss-wb-off: +absent' "$OUT" "a missing offset array prints as absent"
want 'THEY DO NOT AGREE \(0 offsets against 3 allocated blocks\)' "$OUT" "with the count it implies"

scen no-rotator
OUT=$(run)
want 'qcom,mdss-wb-count +on the ROTATOR += NOT READ' "$OUT" \
  "with no rotator node the count is NOT READ rather than 0 -- mdss_rotator.c refuses to probe without it"

# ==================================================================================================
echo "== 5. the panel's own parameters, and the driver defaults behind them =="
# ==================================================================================================
scen idle
OUT=$(run)
want 'qcom,mdss_pan_res: +640 480   \(xres 640, yres 480\)' "$OUT" "the resolution is read as a pair and named"
want 'qcom,mdss_pan_bpp: +24' "$OUT" "and the bpp is read"
want 'These two are the ONLY properties mdss_wb_parse_dt\(\) reads' "$OUT" \
  "and the probe says they are the only two the driver reads"
want '1280x720 panel at 24bpp rather than a probe failure' "$OUT" \
  "including what a tree that forgot them would get -- the driver's own defaults"

scen panres-absent
OUT=$(run)
want 'qcom,mdss_pan_res: +ABSENT' "$OUT" "an absent resolution prints as ABSENT"
want "the driver would use its own default, 1280x720" "$OUT" "beside the default the driver would use"

scen panres-odd
OUT=$(run)
want 'qcom,mdss_pan_res: +640 480 0   \(xres 640, yres 480\)' "$OUT" \
  "a three-cell resolution prints every cell, so the extra one is visible rather than silently dropped"
want 'READ AS EXACTLY TWO CELLS' "$OUT" \
  "and the probe says the driver asks for two, which is why a longer property is not an error"

# ==================================================================================================
echo "== 6. the phandle, which is where the chain fails before anything runtime exists =="
# ==================================================================================================
scen idle
OUT=$(run)
want 'qcom,mdss-fb-map: +phandle 60 -> /soc/qcom,mdss_mdp@900000/qcom,mdss_fb_wfd' "$OUT" \
  "the phandle is resolved to the node that carries it, not printed as a number"
want "that node's compatible: qcom,mdss-fb" "$OUT" "and that node's compatible is read"
want 'shared by PRIMARY, SECONDARY, wfd and hdmi' "$OUT" \
  "with the four children of the same driver named, since cell-index is all that separates them"
want 'cell-index: 1' "$OUT" "and the tree's own cell-index is printed"
want 'does NOT' "$OUT" "while the probe says cell-index does not decide the fb number"

scen no-fb-map
OUT=$(run); RC=$?
want 'qcom,mdss-fb-map: +ABSENT' "$OUT" "the property being absent is read as absent"
want 'Unable to find fb node for device' "$OUT" "with the driver's own error string quoted"
want 'unregisters the switch it just registered' "$OUT" "and the consequence for the switch spelled out"
want '== verdict: no-framebuffer' "$OUT" "so this is the no-framebuffer rung"
[ "$RC" = 1 ] && ok "and exits 1" || bad "the no-fb-map verdict exited $RC, not 1"

scen fb-map-unresolved
OUT=$(run)
want 'phandle 45 -> unresolved' "$OUT" "a phandle nothing carries is named as unresolved"
want '== verdict: no-framebuffer' "$OUT" "and reaches the same rung as an absent property"
notwant 'no find' "$OUT" "and is NOT confused with the other way a phandle fails to resolve"

scen fb-map-ambiguous
OUT=$(run)
want 'phandle 60 -> AMBIGUOUS\(2\)' "$OUT" \
  "a phandle two nodes carry is named AMBIGUOUS rather than picked -- a wrong node is a wrong framebuffer"
want '== verdict: no-framebuffer' "$OUT" "and reaches the no-framebuffer rung too"

# ==================================================================================================
echo "== 7. the run-time traces, and the two rungs that separate them =="
# ==================================================================================================
scen idle
OUT=$(run)
want '/sys/class/switch/wfd: present' "$OUT" "the switch device is read where it is"
want 'state: +0' "$OUT" "with its state"
want 'an end-to-end reading' "$OUT" "and the reason its existence is an end-to-end witness"
want 'the fb phandle resolved' "$OUT" "naming what a present switch proves"
want 'there is no store at all' "$OUT" \
  "and that a shell write is refused by the kernel, so the state is 0 until an ioctl asks"
want '2 framebuffer device\(s\), 1 of them reporting' "$OUT" "the fb class is counted"
want 'THIS is the writeback framebuffer' "$OUT" "and the writeback one is named"
want 'identified the way the KERNEL identifies it' "$OUT" "with the kernel's own criterion quoted"
want 'blank msm_fb_panel_status msm_fb_dfps_mode idle_time msm_fb_thermal_level disable_bl_scaling trigger_reset dsi_write' "$OUT" \
  "and its writable mdss attributes are LISTED, so 'left alone' is a statement about named knobs"
want 'mdssfb_280' "$OUT" "and the fb's own name is read"
want 'the panel.s horizontal resolution in hex' "$OUT" "with what that name really encodes"

scen no-switch
OUT=$(run); RC=$?
want '== verdict: no-writeback-switch' "$OUT" \
  "a switch that never registered is its own rung, below the bound one"
want 'the chain stopped at or before that point' "$OUT" "with the reason named"
[ "$RC" = 1 ] && ok "and exits 1" || bad "the no-switch verdict exited $RC, not 1"

scen no-wb-fb
OUT=$(run)
want '== verdict: no-writeback-fb' "$OUT" \
  "a switch that exists but no fb of the writeback type is the rung below it"
want 'that device.s own probe did not complete' "$OUT" "and it says which step is left"

scen fb-number
OUT=$(run)
want '4 framebuffer device\(s\), 1 of them reporting' "$OUT" "a device whose writeback fb is fb3 is counted the same way"
want 'The writeback one is .*sys/class/graphics/fb3' "$OUT" \
  "and the writeback framebuffer is named by its TYPE even when it is not the number the tree suggests"
want 'mdss_fb numbers its devices from a registration counter' "$OUT" "with the reason the number cannot be used"

scen no-fb-class
OUT=$(run)
want 'no framebuffer device at all' "$OUT" "a device with no framebuffer class at all says so"
want '== verdict: no-writeback-fb' "$OUT" "and lands on the same rung as a class without the writeback one"

# ==================================================================================================
echo "== 8. the drivers, their directories, and the two names that are not the same =="
# ==================================================================================================
scen idle
OUT=$(run)
want 'CONFIG_FB_MSM_MDSS +y \(built in\)' "$OUT" "the MDP option is read out of the running kernel's own config"
want 'CONFIG_FB_MSM_MDSS_WRITEBACK +y \(built in\)' "$OUT" "and so is the writeback panel's"
want 'there is no CONFIG_MSM_ROTATOR' "$OUT" \
  "and the option that does NOT exist is named -- the rotator is built by the MDP's option, not its own"
want '/sys/bus/platform/drivers/mdss_wb: present, bound: qcom,mdss_wb_panel' "$OUT" \
  "each driver directory is read, with what is bound to it"
want '/sys/bus/platform/drivers/mdp: present, bound: mdss_mdp' "$OUT" \
  "and the MDP's directory is looked up by the name it REGISTERS under, not by its compatible"
want 'the MDP.s platform driver is registered as `mdp`, not' "$OUT" \
  "with the mismatch named out loud, because mdss_mdp is a name that is in the tree and not in sysfs"

scen driver-unregistered
OUT=$(run); RC=$?
want '== verdict: driver-not-registered' "$OUT" \
  "a driver the source has but the kernel did not register is its own rung"
want 'which is a defconfig line and a boot-image build' "$OUT" "and it names the next move -- a config line"
want '/sys/bus/platform/drivers/mdss_wb: ABSENT \(the driver did not register\)' "$OUT" \
  "with the directory reported as absent rather than as unbound"
[ "$RC" = 1 ] && ok "and exits 1" || bad "the not-registered verdict exited $RC, not 1"

scen driver-unbound
OUT=$(run); RC=$?
want '== verdict: driver-not-bound' "$OUT" \
  "a registered driver with nothing bound is the next rung, and a different next move"
want '/sys/bus/platform/drivers/mdss_wb: present, bound: NONE' "$OUT" \
  "with the directory present and NOTHING bound -- a different reading from absent"
[ "$RC" = 1 ] && ok "and exits 1" || bad "the not-bound verdict exited $RC, not 1"

scen no-config
OUT=$(run)
want '/proc/config.gz: MISSING' "$OUT" "a device with no kernel config says so"
want 'the kernel config could NOT be read' "$OUT" "and the column is named as NOT READ"
want 'NOT READ$|NOT READ' "$OUT" "which is a third state, not 'the option is off'"
want 'no verdict below rests on' "$OUT" "and the probe says no verdict depends on it"
want '== verdict: writeback-panel-registered' "$OUT" "so the verdict still stands on sysfs alone"

# ==================================================================================================
echo "== 9. the kernel log, and the one line that means the tree is not this tree =="
# ==================================================================================================
scen idle
OUT=$(run)
want 'mdss_wb: adding framebuffer device' "$OUT" "the block's own log lines are shown"
want "ONE LINE IN THIS LIST WOULD BE EXPECTED ON A TREE THAT LOST THE PROPERTY" "$OUT" \
  "and the probe names the line that would mean the kernel read another tree"
want 'evidence the tree the kernel read is not the' "$OUT" "with the reason"

scen log-failing
OUT=$(run)
want 'unable to register writeback panel' "$OUT" "a probe failure is shown"
want 'Unable to find fb node for device' "$OUT" "including the phandle failure's own string"
want 'probe of qcom,mdss_wb_panel failed with error -19' "$OUT" "and the -ENODEV that follows it"

scen log-quiet
OUT=$(run)
want 'the kernel log mentions no writeback' "$OUT" \
  "a log with nothing about this block says so rather than printing nothing"

scen log-unreadable
OUT=$(run)
want 'the kernel log could not be read' "$OUT" "a log that cannot be read is named, not read as empty"
want 'NOT READ' "$OUT" "and the section is marked as not read"
want '== verdict: writeback-panel-registered' "$OUT" "while the verdict, decided on files, still stands"

# ==================================================================================================
echo "== 10. could-not-search is not the same fact as not-found =="
# ==================================================================================================
scen bare-tree
OUT=$(run_nofind); RC=$?
want '== verdict: tree-unscanned' "$OUT" \
  "a device with no find(1) and no known node shape is its own rung, above every hardware reading"
want 'this probe could not look' "$OUT" "and it says which of the two facts this is"
want 'the two must not print the same way' "$OUT" "with the distinction named"
[ "$RC" = 1 ] && ok "and exits 1" || bad "the unscanned verdict exited $RC, not 1"

scen bare-tree
OUT=$(run)
want '== verdict: no-device-tree-node' "$OUT" \
  "while the SAME tree WITH find(1) is a scan that ran and found nothing"
notwant 'tree-unscanned' "$OUT" "so the two states do not print the same way"

scen alien-node
OUT=$(run_nofind)
want '== verdict: no-device-tree-node' "$OUT" \
  "and a tree that HAS nodes, none of them this block's, is a scan that happened -- not a scan that could not run"
notwant 'tree-unscanned' "$OUT" "which is the third state, covered by the alien tree"

# ==================================================================================================
echo "== 11. the mutations: one per reading, each of which must redden =="
# ==================================================================================================
# 1. An absent `status` read as disabled. This board's panel node carries no status property at all, so
#    this one edit turns the block's only panel into a switched-off one.
sed 's#^    case "\$ST" in okay | ok | EMPTY | absent) EN=yes ;; \*) EN=no ;; esac#    case "$ST" in okay | ok | EMPTY) EN=yes ;; *) EN=no ;; esac#' \
  "$SRC" > "$W/mut-status.sh"
if cmp -s "$SRC" "$W/mut-status.sh"; then bad "the status mutation did not apply"; else
  scen idle
  OUT=$(mut_run "$W/mut-status.sh")
  notwant '1 of 1 panel node\(s\) are ENABLED' "$OUT" \
    "reading an absent status as disabled switches this board's panel off (the mutation)"
  want '== verdict: no-panel-enabled' "$OUT" "and the verdict moves with the count"
fi
# 2. The block's own compatible looked for in the FIRST entry of a list instead of anywhere in it. The
#    `compatible-list` scenario is the only tree that can tell the two apart.
sed 's#^      case " \$CL " in \*" \$_cm "\*) C="\$_cm" ;; esac#      :#' "$SRC" > "$W/mut-list.sh"
if cmp -s "$SRC" "$W/mut-list.sh"; then bad "the compatible-list mutation did not apply"; else
  scen compatible-list
  OUT=$(mut_run "$W/mut-list.sh")
  notwant '1 of 1 panel node\(s\) are ENABLED' "$OUT" \
    "classifying on the first compatible entry loses a node the scan found by its list (the mutation)"
  want '== verdict: no-panel-enabled' "$OUT" "and prints the panel as switched off"
fi
# 3. The number that is derived from a STRING treated as always 1. This is the mutation that makes the
#    arithmetic agree on a tree where it does not -- the exact defect the paragraph exists to prevent.
sed 's#^  case "\$WFD_MODE" in absent | EMPTY | shared) N_INTF=0 ;; esac#  :#' "$SRC" > "$W/mut-intf.sh"
if cmp -s "$SRC" "$W/mut-intf.sh"; then bad "the num_intf_wb mutation did not apply"; else
  scen mode-shared
  OUT=$(mut_run "$W/mut-intf.sh")
  notwant 'THEY DO NOT AGREE' "$OUT" \
    "assuming num_intf_wb is always 1 hides the mismatch on a tree that says 'shared' (the mutation)"
  want 'THEY AGREE' "$OUT" "and the probe then claims an agreement the tree does not have"
fi
# 4. The byte order: `od -tu4` on a little-endian host, which is the mistake that looks like a reading. A
#    device tree's u32s are four BIG-endian bytes, so the FIRST byte is the most significant -- and the
#    mutation makes it the least significant, which is what a host-order reader does.
sed -e 's#^    0) _us_v=\$((_us_x \* 16777216)) ;;#    0) _us_v=$((_us_x)) ;;#' \
  -e 's#^    1) _us_v=\$((_us_v + _us_x \* 65536)) ;;#    1) _us_v=$((_us_v + _us_x * 256)) ;;#' \
  -e 's#^    2) _us_v=\$((_us_v + _us_x \* 256)) ;;#    2) _us_v=$((_us_v + _us_x * 65536)) ;;#' \
  -e 's#^    3) _us_v=\$((_us_v + _us_x)); _us_out="\$_us_out \$_us_v" ;;#    3) _us_v=$((_us_v + _us_x * 16777216)); _us_out="$_us_out $_us_v" ;;#' \
  "$SRC" > "$W/mut-endian.sh"
if cmp -s "$SRC" "$W/mut-endian.sh"; then bad "the endianness mutation did not apply"; else
  scen idle
  OUT=$(mut_run "$W/mut-endian.sh")
  notwant 'qcom,mdss_pan_res: +640 480' "$OUT" \
    "combining the four bytes in the host's order loses the real resolution (the mutation)"
  notwant 'qcom,mdss-wb-off: +413696 415744 417792' "$OUT" \
    "and the offset array, because both are read through the same helper"
  want 'qcom,mdss_pan_res: +2147614720 3758161920' "$OUT" \
    "and what it prints instead has the right SHAPE and the wrong values -- which is why the check is the whole pair"
fi
# 5. The panel resolution read as ONE cell instead of a pair: the two-cell property then reads as
#    not-a-u32, which is how "the resolution is a pair" earns its check.
sed 's#^  _pr_v=\$(dtu32s "\$1/qcom,mdss_pan_res")#  _pr_v=$(dtu32 "$1/qcom,mdss_pan_res")#' "$SRC" > "$W/mut-panres.sh"
if cmp -s "$SRC" "$W/mut-panres.sh"; then bad "the pan_res mutation did not apply"; else
  scen idle
  OUT=$(mut_run "$W/mut-panres.sh")
  notwant 'xres 640, yres 480' "$OUT" \
    "reading only the first cell of a two-cell property loses the pair (the mutation)"
  want 'not-a-u32' "$OUT" "and the property reads as the wrong size, which is the honest report"
fi
# 6. The switch's existence no longer required. The switch is the end-to-end witness -- registered before
#    the framebuffer lookup and unregistered again on failure -- so dropping its check makes a device whose
#    chain stopped report the top rung.
sed 's#^elif \[ ! -d "\$SWITCH_DIR" \]; then#elif false; then#' "$SRC" > "$W/mut-switch.sh"
if cmp -s "$SRC" "$W/mut-switch.sh"; then bad "the switch mutation did not apply"; else
  scen no-switch
  OUT=$(mut_run "$W/mut-switch.sh")
  notwant '== verdict: writeback-panel-registered' "$OUT" \
    "not requiring the switch loses the rung a device with no switch belongs on (the mutation)"
  want '== verdict: no-writeback-fb' "$OUT" "and reports a step that is not the one that failed"
fi
# 7. The framebuffer identified by a NUMBER instead of by its type. On a board whose fb number is a
#    registration order that names the wrong framebuffer -- and it passes on any fixture where the number
#    and the type happen to agree, which is why the `fb-number` scenario exists.
sed 's#^  case "\$_ty" in "writeback panel") _iswb=yes ;; esac#  case "$_fb" in */fb1) _iswb=yes ;; esac#' \
  "$SRC" > "$W/mut-fbnum.sh"
if cmp -s "$SRC" "$W/mut-fbnum.sh"; then bad "the fb-number mutation did not apply"; else
  scen fb-number
  OUT=$(mut_run "$W/mut-fbnum.sh")
  notwant 'The writeback one is .*sys/class/graphics/fb3' "$OUT" \
    "identifying the writeback framebuffer by a number loses the one that actually reports that type (the mutation)"
  want 'The writeback one is .*sys/class/graphics/fb1' "$OUT" \
    "and the probe names fb1 instead -- a framebuffer that is not of the writeback type at all"
fi
# 8. The phandle counted per FILE instead of per NODE. Every mdss node in this tree carries BOTH `phandle`
#    and `linux,phandle`, so a resolver that counts files calls the one real hit ambiguous with itself --
#    and the block then reads as having no framebuffer at all.
sed 's#^      case "\$_ph_seen" in \*" \$_ph_dir "\*) continue ;; esac#      :#' "$SRC" > "$W/mut-phandle.sh"
if cmp -s "$SRC" "$W/mut-phandle.sh"; then bad "the phandle mutation did not apply"; else
  scen idle
  OUT=$(mut_run "$W/mut-phandle.sh")
  notwant 'phandle 60 -> /soc/qcom,mdss_mdp@900000/qcom,mdss_fb_wfd' "$OUT" \
    "counting phandle FILES turns one node's two names into an ambiguity (the mutation)"
  want 'AMBIGUOUS' "$OUT" "and the property reads as ambiguous on a tree where it resolves"
  want '== verdict: no-framebuffer' "$OUT" "so the whole block reads as having no framebuffer"
fi
# 9. The MDP's driver name. sysfs is keyed by the name the driver REGISTERS under -- `mdp` -- while the
#    compatible is `qcom,mdss_mdp`; a reader who used the compatible would find the directory missing on a
#    device whose display is working.
sed "s#^    printf 'mdp\\\\tCONFIG_FB_MSM_MDSS#    printf 'mdss_mdp\\\\tCONFIG_FB_MSM_MDSS#" "$SRC" > "$W/mut-mdpname.sh"
if cmp -s "$SRC" "$W/mut-mdpname.sh"; then bad "the mdp-name mutation did not apply"; else
  scen idle
  OUT=$(mut_run "$W/mut-mdpname.sh")
  notwant 'driver: +mdp ' "$OUT" \
    "looking the MDP up under its compatible instead of its driver name loses the name sysfs is keyed by (the mutation)"
  want 'driver: +mdss_mdp ' "$OUT" "and prints a name no directory carries"
  want 'drivers/mdp: present' "$OUT" \
    "while the directory list still reads the name sysfs really has, so the two columns DISAGREE -- which is the shape of the defect"
fi
# 10. "Could not search" collapsed into "not found": the state that must never print like an absence.
sed 's#^  \[ "\$_nc_any" = 1 \] && return 1#  return 1#' "$SRC" > "$W/mut-scan.sh"
if cmp -s "$SRC" "$W/mut-scan.sh"; then bad "the scan mutation did not apply"; else
  scen bare-tree
  OUT=$(mut_run "$W/mut-scan.sh" nofind)
  notwant '== verdict: tree-unscanned' "$OUT" "collapsing could-not-search into not-found loses that state (the mutation)"
  want '== verdict: no-device-tree-node' "$OUT" "and prints an absence the probe cannot support"
fi
# 11. The rung that says the kernel SOURCE has no driver for this panel. On the shipped source it cannot
#    fire -- `drivers_for` always matches `qcom,mdss_wb` -- so this mutation is what proves the rung is
#    reachable at all rather than a paragraph no tree can get to.
sed "s#^    printf 'mdss_wb\\\\tCONFIG_FB_MSM_MDSS_WRITEBACK#    printf 'none\\\\t-#" "$SRC" > "$W/mut-nodriver.sh"
if cmp -s "$SRC" "$W/mut-nodriver.sh"; then bad "the no-driver mutation did not apply"; else
  scen idle
  OUT=$(mut_run "$W/mut-nodriver.sh")
  want '== verdict: no-driver-for-enabled-panel' "$OUT" \
    "a source with no driver for this panel is its own rung, and this replay is what keeps it reachable"
  want 'a property of the kernel SOURCE and not of a build option' "$OUT" "with the kind of problem named"
fi
# 12. The four-count arithmetic printed but never compared. Without the comparison the paragraph claims an
#     agreement on every tree, including the one that disagrees.
sed 's#^    "\$N_NWB")#    "__never__")#' "$SRC" > "$W/mut-agree.sh"
if cmp -s "$SRC" "$W/mut-agree.sh"; then bad "the agreement mutation did not apply"; else
  scen idle
  OUT=$(mut_run "$W/mut-agree.sh")
  notwant 'THEY AGREE' "$OUT" \
    "never taking the agreement branch loses the reading that the tree and the driver count the same blocks (the mutation)"
  want 'THEY DO NOT AGREE' "$OUT" "and the probe contradicts a tree that agrees"
fi

# ==================================================================================================
echo "== 12. this harness's own citation =="
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
    grep -oE 'zl1-wfd-probe-selftest\.sh[^0-9]*[0-9]+ checks' | sed -n 1p)
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
