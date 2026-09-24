#!/usr/bin/env bash
# zl1 NFC probe -- offline self-test. Host-side, touches no device, needs no phone.
#
# Why this exists. `scripts/device/zl1-nfc-probe.sh` is the instrument for the `nfc` row of doc 137's gap
# list, and the readings that make that probe's design are these:
#
#   1. ONE NODE CARRIES TWO GENERATIONS OF PROPERTY NAMES AND ONLY ONE IS READ. `/soc/i2c@75b6000/nq@28`
#      (`qcom,nq-nci`) carries `qcom,nq-ven`, `qcom,nq-irq`, `qcom,nq-firm`, `qcom,nq-clkreq` and
#      `qcom,clk-src` -- what `nfc_parse_dt()` asks for -- AND `nxp,p61-pwr` / `nxp,p61-rst`, which no `.c`,
#      `.h` or Kconfig in this tree reads. The pins do not even agree: the driver's power enable is a TLMM
#      pin (phandle 28), the unread one is a PMIC pin (phandle 29). The `namespace` mutation is what makes
#      "which namespace did that line come from" a check: it reads the ven cells out of `nxp,p61-pwr`.
#   2. THREE OF THE FIVE READS ARE FATAL AND TWO ARE NOT. `ven-absent`, `clk-src-absent` and
#      `clk-src-wrong` are scenarios where the tree refuses the node to the driver; `firm-absent` and
#      `clkreq-absent` are the two where the driver binds anyway and the verdict must still be the top rung.
#      A probe that treated the two lenient properties as fatal would report a dead block on a working one.
#   3. ONE STRING VALUE GATES THE PROBE. `qcom,clk-src` is compared against `BBCLK2` and any other value
#      takes `goto err_free_dev`, so it is a switch and not information. The fixture carries the board's own
#      `BBCLK2`.
#   4. THE CONFIG LINE IS OUTSIDE THE MENU IT LOOKS LIKE IT BELONGS TO. `config NFC_NQ` sits after the
#      `endmenu` of the menu that `depends on NFC`, so `CONFIG_NFC` is NOT a precondition for it -- and the
#      two kernels this project has in hand prove it in opposite directions: the stock 3.18.120 kernel has
#      `# CONFIG_NFC is not set` AND `CONFIG_NFC_NQ=y` (built, menu off), while the v63 Halium 3.18.140
#      kernel has both off. The `config-stock` scenario is that first kernel's shape, and the `config`
#      mutation -- reading `CONFIG_NFC` instead -- is what turns "the option is off" from a reading into a
#      mistake on a kernel that has the driver.
#   5. THE TWO `#ifdef`s DEFINED NOWHERE. `CONFIG_NFC_HW_CHECK` and `NFC_KERNEL_BU` exist only as `#ifdef`
#      uses, so the probe neither checks for the hardware nor powers it: VEN stays low and the chip is
#      powered only by userspace, through the `NFC_SET_PWR` ioctl. The write-class fixtures below are that
#      call and the two `i2c_master_send`/`recv` shapes behind the device node's read/write.
#   6. THE THREE NESTED WITNESSES AND FOUR NAMES. The i2c CLIENT exists from the device tree alone with no
#      NFC driver built; the BIND needs the driver built, registered and its probe past the fatal reads and
#      the clock string; the MISC DEVICE needs the probe to have run to the END, because `misc_register()`
#      comes after the clock and the gpios and every later failure path deregisters. The names are
#      `qcom,nq-nci` (compatible), `nq-nci` (the driver directory), `nqx-i2c` (its i2c_device_id) and
#      `pn544` (the MISC DEVICE it registers). `misc-name` and `driver-name` are the mutations for the last
#      two: the name you can see in /dev is another driver's, and the id_table name is not a sysfs path.
#
# How it works: **the stub directory IS the device.** The probe runs as itself against a fake root, with the
# device's tools stubbed and PATH sandboxed to `$STUB:$MINBIN`, where MINBIN holds symlinks to the real
# coreutils. The rewrite covers `/proc/`, `/sys/` and `/dev/pn544` -- the last because the probe NAMES that
# device node in its prose and in its write-guard paragraph, and a rename that re-rooted only the roots it
# reads today would leave a future `> /dev/pn544` escaping to this laptop. `/dev/null` does not share that
# prefix and is asserted to survive.
#
# Usage: zl1-nfc-probe-selftest.sh [--keep]
#   --keep   leave the fake device, the stubs and the rewritten probe for inspection
#
# `ZL1_NFC_PROBE_SRC=/path` runs the whole thing against another copy of the subject, which is how a
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
SRC="${ZL1_NFC_PROBE_SRC:-$HERE/../device/zl1-nfc-probe.sh}"
[ -r "$SRC" ] || { echo "cannot read the subject: $SRC" >&2; exit 2; }

W="${TMPDIR:-/tmp}/zl1-nfc-probe-selftest"
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
# The exit code is a reading too, and the probe's top rung is the only one that may exit 0.
rc_is() { # $1 = expected, $2 = the run's status
  if [ "$1" = "$2" ]; then ok "and the exit status is $1"; else bad "expected exit $1, got $2"; fi
}

# --- the sandbox PATH ------------------------------------------------------------------------------
# `type -P`, not `command -v`: in a shell whose profile has made one of these a function, `command -v`
# prints the NAME rather than a path and the symlink would point at itself.
for t in awk basename cat cut dirname find grep head od readlink sed sort tail tr uniq wc; do
  p="$(type -P "$t" 2>/dev/null)" || continue
  [ -n "$p" ] || continue
  ln -sf "$p" "$MINBIN/$t"
  [ "$t" = find ] || ln -sf "$p" "$MINBIN_NOFIND/$t"
done
# The probe reads the device tree with `find`, resolves phandles with it, counts property cells with `od`,
# and shortens paths with `basename`/`dirname`; a sandbox missing one of these would silently turn a reading
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
#
# THREE RULES. `/proc/` carries the device tree, the boot id, the uptime, the version and the kernel config;
# `/sys/` carries the i2c bus, the driver directory, the client, the misc class and the config's own path;
# and `/dev/pn544` is here even though the probe only NAMES that device node today -- a rename that
# re-rooted only what the probe reads right now would leave a future `> /dev/pn544` escaping to this laptop,
# which is the defect this whole rewrite exists to prevent. `/dev/null` does not share that prefix.
cnt() { grep -o -- "$1" "$2" 2>/dev/null | wc -l | tr -d ' '; }
rewrite() { # $1 = source, $2 = output
  sed -e 's#/proc/#__ZP__#g' "$1" > "$W/pass1a.sh"
  sed -e 's#/sys/#__ZS__#g' "$W/pass1a.sh" > "$W/pass1b.sh"
  sed -e 's#/dev/pn544#__ZPN__#g' "$W/pass1b.sh" > "$W/pass1.sh"
  sed -e "s#__ZP__#$FR/proc/#g" -e "s#__ZS__#$FR/sys/#g" -e "s#__ZPN__#$FR/dev/pn544#g" \
    "$W/pass1.sh" > "$2"
}
# The whole chain is applied to the SUBJECT once here to prove every rule matched something and that the
# source has no `/proc/` or `/sys/` left; `rewrite` is then reused for the mutated copies.
RW="$W/nfc-probe.sh"
sed -e 's#/proc/#__ZP__#g' "$SRC" > "$W/pass1a.sh"
[ "$(cnt '/proc/' "$SRC")" = "$(cnt '__ZP__' "$W/pass1a.sh")" ] \
  || { echo "the /proc/ rewrite did not cover every /proc/ in the source" >&2; exit 2; }
[ "$(cnt '/proc/' "$W/pass1a.sh")" = 0 ] || { echo "a /proc/ survived pass 1 -- the probe would read this host" >&2; exit 2; }
sed -e 's#/sys/#__ZS__#g' "$W/pass1a.sh" > "$W/pass1b.sh"
[ "$(cnt '/sys/' "$W/pass1a.sh")" = "$(cnt '__ZS__' "$W/pass1b.sh")" ] \
  || { echo "the /sys/ rewrite did not cover every /sys/ in the source" >&2; exit 2; }
[ "$(cnt '/sys/' "$W/pass1b.sh")" = 0 ] || { echo "a /sys/ survived pass 1" >&2; exit 2; }
sed -e 's#/dev/pn544#__ZPN__#g' "$W/pass1b.sh" > "$W/pass1.sh"
[ "$(cnt '/dev/pn544' "$W/pass1b.sh")" = "$(cnt '__ZPN__' "$W/pass1.sh")" ] \
  || { echo "the /dev/pn544 rewrite did not cover every occurrence" >&2; exit 2; }
[ "$(cnt '/dev/pn544' "$W/pass1.sh")" = 0 ] || { echo "a /dev/pn544 survived pass 1" >&2; exit 2; }
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
for tok in __ZP__ __ZS__ __ZPN__; do
  [ "$(cnt "$tok" "$W/pass1.sh")" -gt 0 ] || { echo "no $tok token was produced -- that rule matched nothing" >&2; exit 2; }
done
grep -qF "$FR$FR" "$RW" && { echo "a rewrite cascaded: $FR appears twice in a row" >&2; exit 2; }
grep -qF "$FR/proc/$FR" "$RW" && { echo "a rewrite cascaded into the fake root's own proc/" >&2; exit 2; }
# The paths the probe's answers hang on, named -- a rule that silently stopped applying would be invisible
# to the counts above if its occurrences moved into a comment.
for need in "$FR/proc/device-tree/model" "$FR/proc/device-tree/compatible" \
  "$FR/proc/sys/kernel/random/boot_id" "$FR/proc/uptime" "$FR/proc/version" "$FR/proc/config.gz" \
  "$FR/sys/bus/i2c/drivers" "$FR/sys/bus/i2c/devices" "$FR/sys/class/misc/pn544" "$FR/dev/pn544"; do
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

echo "== 1. the rewrite, the guard's teeth, and the probe's own pages =="
W_SITES=$(write_sites "$SRC")
if [ -z "$W_SITES" ]; then
  ok "the shipped probe contains no write into /sys, /proc or /dev and no state-changing command"
else
  bad "the shipped probe contains what looks like a write:"
  sed 's/^/        | /' <<< "$W_SITES"
fi
# The teeth, and the first is this block's real write-class move: powering the controller on (or into
# download mode) is an ioctl on the device node, and the shell spellings of "speak to the chip" are a write
# into that node and an i2c tool. The second is the sysfs surface a reader might reach for instead -- there
# is none, and writing into the class directory is the shape of trying anyway.
printf '%s\n' '# a fixture for the redirect rule: the device node the ioctl drives' \
  'printf 1 > /dev/pn544' > "$W/teeth-dev.sh"
printf '%s\n' '# a fixture for the same rule: the misc class entry, which is not writable at all' \
  'printf 1 > /sys/class/misc/pn544/dev' > "$W/teeth-class.sh"
printf '%s\n' '# a fixture for the redirect rule: the i2c address attribute' \
  'printf 1 > /sys/bus/i2c/devices/8-0028/name' > "$W/teeth-i2c.sh"
printf '%s\n' '# a fixture for the command-position rule, in the shape this block invites: the ioctl is not' \
  '#' 'shell, so the nearest shell equivalents are a raw dd onto the node and an i2c tool' \
  'dd if=nci.bin of=/dev/pn544 bs=1 count=4' > "$W/teeth-dd.sh"
printf '%s\n' '# a fixture for the command-position rule' \
  'modprobe nq-nci' > "$W/teeth-cmd.sh"
printf '%s\n' '# prose that must not be read as code' \
  "cat <<'EOF'" \
  'powering the chip would be ioctl(/dev/pn544, NFC_SET_PWR, 1), and writing /sys/class/misc/pn544/dev is refused by the kernel anyway' \
  'EOF' \
  'say "the arrow -> /sys/class/misc/pn544/dev is how this page writes a path"' > "$W/teeth-prose.sh"
want 'pn544' "$(write_sites "$W/teeth-dev.sh")" \
  "the guard catches a redirect into the NFC device node (as a fixture)"
want 'misc/pn544/dev' "$(write_sites "$W/teeth-class.sh")" "and one into the misc class entry"
want 'i2c/devices/8-0028/name' "$(write_sites "$W/teeth-i2c.sh")" "and one into a client's own i2c attribute"
want 'dd if=nci.bin of=/dev/pn544' "$(write_sites "$W/teeth-dd.sh")" \
  "and a dd straight onto the device node, which is the shell's nearest thing to the NFC_SET_PWR ioctl this block's write-class move really is"
want 'modprobe nq-nci' "$(write_sites "$W/teeth-cmd.sh")" "and a state-changing command in command position"
notwant '.' "$(write_sites "$W/teeth-prose.sh")" \
  "and does not punish prose that names an arrow before a /sys path, or a heredoc about an ioctl"
wantf 'ioctl(/dev/pn544, NFC_SET_PWR, 1)' "$(cat "$W/teeth-prose.sh")" \
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

# The two boards' root properties, exactly as the flashed blob carries them. Both declare an NFC controller
# at the same path with the same bytes, so only `model` can tell them apart.
MODEL_ZL1='Letv Technologies, Inc. MSM 8996pro + PMI8996 LE_ZL1-DVT1'
MODEL_X2='Letv Technologies, Inc. MSM 8996 v3 + PMI8996 LE_X2-PVT'

# THE I2C BUS the controller sits on. It is a separate node because the CLIENT's existence depends on it,
# and a bus that is switched off in the tree is a state no config line for the NFC driver can repair.
i2c_bus_node() {
  B="$FR/proc/device-tree/soc/i2c@75b6000"
  # No `status` property -- which the device tree reads as ENABLED -- and a compatible nothing in this
  # block reads. `bus-disabled` is the scenario that adds one.
  dtp "$B/compatible" 'qcom,i2c-msm-v2'
  # And the alias that gives the adapter its BUS NUMBER: the client's sysfs name is built from it.
  dtp "$FR/proc/device-tree/aliases/i2c8" '/soc/i2c@75b6000'
}
# THE CONTROLLERS the node's cells point at, each carrying BOTH `phandle` and `linux,phandle` -- as every
# node in this tree does. That pair is not decoration: it is the trap that makes a phandle resolver which
# counts FILES instead of NODES report each real hit as AMBIGUOUS(2), which is one of the mutations.
ctl_node() { # $1 = path, $2 = phandle bits, $3 = label or ''
  dtu32p "$1/phandle" "$2"
  dtu32p "$1/linux,phandle" "$2"
  [ -n "$3" ] && dtp "$1/label" "$3"
  return 0
}
controllers_nodes() {
  # The TLMM: phandle 28. The driver's ven/irq/firm pins are on THIS controller, and it has no label.
  C="$FR/proc/device-tree/soc/pinctrl@01010000"
  dtp "$C/compatible" 'qcom,msm8996-pinctrl'
  dtu32p "$C/#gpio-cells" '\000\000\000\002'
  dtu32p "$C/phandle" '\000\000\000\034'
  dtu32p "$C/linux,phandle" '\000\000\000\034'
  # The pinmux state groups the node's pinctrl-0/pinctrl-1 point at. Their NAMES are the block's own two
  # pins (`pmx_rd_nfc_int`, `pmx_nfc_reset`) and they are what the probe resolves cell by cell.
  ctl_node "$C/pmx_rd_nfc_int/active" '\000\000\001\007' ''
  ctl_node "$C/pmx_nfc_reset/active" '\000\000\001\010' ''
  ctl_node "$C/pmx_rd_nfc_int/suspend" '\000\000\001\011' ''
  ctl_node "$C/pmx_nfc_reset/suspend" '\000\000\001\012' ''
  # The PMIC gpios: phandle 29, label pm8994-gpio. The driver's clkreq pin and the UNREAD nxp,p61-pwr are
  # on THIS controller -- which is how the two generations of property names are told apart.
  P="$FR/proc/device-tree/soc/qcom,spmi@400f000/qcom/pm8994@0/gpios"
  dtp "$P/compatible" 'qcom,qpnp-pin'
  dtu32p "$P/#gpio-cells" '\000\000\000\002'
  dtu32p "$P/phandle" '\000\000\000\035'
  dtu32p "$P/linux,phandle" '\000\000\000\035'
  dtp "$P/label" 'pm8994-gpio'
  M="$FR/proc/device-tree/soc/qcom,spmi@400f000/qcom/pm8994@0/mpps"
  dtp "$M/compatible" 'qcom,qpnp-pin'
  dtu32p "$M/#gpio-cells" '\000\000\000\002'
  dtu32p "$M/phandle" '\000\000\000\075'
  dtu32p "$M/linux,phandle" '\000\000\000\075'
  dtp "$M/label" 'pm8994-mpp'
  # The clock controller: phandle 74, which the node's `clocks` cell points at. It is not a gpio and has no
  # gpio cells -- a probe that resolved every phandle as a gpio controller would print a plausible cell
  # count for it.
  G="$FR/proc/device-tree/soc/qcom,gcc@300000"
  dtp "$G/compatible" 'qcom,gcc-8996-v3'
  dtu32p "$G/phandle" '\000\000\000\112'
  dtu32p "$G/linux,phandle" '\000\000\000\112'
}
# THE NFC NODE ITSELF, with the real cells read out of the 15 LE_ZL1 trees: ven/irq/firm on the TLMM
# (phandle 28), clkreq on the PMIC gpios (29), the unread `nxp,p61-pwr` on the PMIC and `nxp,p61-rst` back
# on the TLMM, `qcom,clk-src = "BBCLK2"`, and `clocks = <74 1233729765>`.
nfc_node() {
  N="$FR/proc/device-tree/soc/i2c@75b6000/nq@28"
  dtp "$N/compatible" 'qcom,nq-nci'
  # reg = 0x28, one cell -- and 0x28 is what makes the client's sysfs name `8-0028`, because the kernel
  # formats it `%d-%04x`.
  dtu32p "$N/reg" '\000\000\000\050'
  dtu32p "$N/qcom,nq-ven" '\000\000\000\034\000\000\000\014\000\000\000\000'
  dtu32p "$N/qcom,nq-irq" '\000\000\000\034\000\000\000\137\000\000\000\000'
  dtu32p "$N/qcom,nq-firm" '\000\000\000\034\000\000\000\061\000\000\000\000'
  dtu32p "$N/qcom,nq-clkreq" '\000\000\000\035\000\000\000\012\000\000\000\000'
  dtu32p "$N/nxp,p61-pwr" '\000\000\000\035\000\000\000\007\000\000\000\000'
  dtu32p "$N/nxp,p61-rst" '\000\000\000\034\000\000\000\202\000\000\000\000'
  dtp "$N/qcom,clk-src" 'BBCLK2'
  # 1233729765 = 0x498938E5, four big-endian bytes. A probe that read this with `od -tu4` would print a
  # number of the right shape and the wrong value, which is what the `endianness` mutation does.
  dtu32p "$N/clocks" '\000\000\000\112\111\0211\070\0345'
  dtp "$N/clock-names" 'ref_clk'
  # The interrupt described TWICE: the OF cells the i2c core reads first, and the gpio the driver
  # overwrites `client->irq` from. Here they name the same controller and the same line.
  dtu32p "$N/interrupt-parent" '\000\000\000\034'
  dtu32p "$N/interrupts" '\000\000\000\137'
  dtp "$N/interrupt-names" 'nfc_irq'
  dtlistp "$N/pinctrl-names" 'nfc_active\000nfc_suspend'
  dtu32p "$N/pinctrl-0" '\000\000\001\007\000\000\001\010'
  dtu32p "$N/pinctrl-1" '\000\000\001\011\000\000\001\012'
}

# The kernel configs, as the two real kernels carry them. THE TWO LINES THAT MATTER ARE THE LAST TWO, and
# the point is that they are NOT the same in the two files: the menu that `depends on NFC` is off in BOTH,
# while the driver is built in only one -- because `config NFC_NQ` sits after that menu's `endmenu`.
config_halium() { # the v63 Halium kernel this port boots: the driver is NOT built
  { printf '# Automatically generated file; DO NOT EDIT.\n'
    printf 'Linux/arm64 3.18.140 Kernel Configuration\n'
    printf 'CONFIG_IKCONFIG=y\n'
    printf 'CONFIG_IKCONFIG_PROC=y\n'
    printf 'CONFIG_I2C=y\n'
    printf 'CONFIG_I2C_MSM_V2=y\n'
    printf '# CONFIG_I2C_MSM_QUP is not set\n'
    printf 'CONFIG_I2C_CHARDEV=y\n'
    printf '# CONFIG_NFC is not set\n'
    printf '# CONFIG_NFC_NQ is not set\n'
    printf '# CONFIG_NFC_PN544 is not set\n'; } > "$W/kernel.config"
}
config_stock() { # the vendor boot image's kernel: the driver IS built with the menu off
  { printf '# Automatically generated file; DO NOT EDIT.\n'
    printf 'Linux/arm64 3.18.120 Kernel Configuration\n'
    printf 'CONFIG_IKCONFIG=y\n'
    printf 'CONFIG_IKCONFIG_PROC=y\n'
    printf 'CONFIG_I2C=y\n'
    printf 'CONFIG_I2C_MSM_V2=y\n'
    printf '# CONFIG_I2C_MSM_QUP is not set\n'
    printf 'CONFIG_I2C_CHARDEV=y\n'
    printf '# CONFIG_NFC is not set\n'
    printf 'CONFIG_NFC_NQ=y\n'
    printf '# CONFIG_NFC_PN544 is not set\n'; } > "$W/kernel.config"
}
config_nokey() { # an older config where the symbol is not in the file at all
  { printf 'CONFIG_IKCONFIG=y\n'
    printf 'CONFIG_IKCONFIG_PROC=y\n'
    printf 'CONFIG_I2C=y\n'
    printf 'CONFIG_I2C_MSM_V2=y\n'
    printf '# CONFIG_NFC is not set\n'; } > "$W/kernel.config"
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

# The run-time side: the i2c CLIENT (created by the core from the tree), the driver DIRECTORY (created when
# the driver registers), the bind (a symlink beside it) and the MISC device.
client_present() { # $1 = the client's sysfs name
  mkdir -p "$FR/sys/bus/i2c/devices/$1"
  printf '%s\n' "$1" > "$FR/sys/bus/i2c/devices/$1/name"
}
driver_registered() {
  mkdir -p "$FR/sys/bus/i2c/drivers/nq-nci"
  : > "$FR/sys/bus/i2c/drivers/nq-nci/bind"
  : > "$FR/sys/bus/i2c/drivers/nq-nci/unbind"
  : > "$FR/sys/bus/i2c/drivers/nq-nci/uevent"
}
bind_client() { # $1 = the client's sysfs name
  ln -sfn "$FR/sys/bus/i2c/devices/$1" "$FR/sys/bus/i2c/drivers/nq-nci/$1"
}
misc_present() {
  mkdir -p "$FR/sys/class/misc/pn544"
  printf 'pn544\n' > "$FR/sys/class/misc/pn544/name"
  printf '10:56\n' > "$FR/sys/class/misc/pn544/dev"
  printf '0\n' > "$FR/sys/class/misc/pn544/devt"
}

scen() {
  SCEN="$1"
  rm -rf "$FR"
  mkdir -p "$FR/proc/sys/kernel/random" "$FR/proc/device-tree/soc" "$FR/proc/device-tree/aliases" \
    "$FR/sys/bus/i2c/drivers" "$FR/sys/bus/i2c/devices" "$FR/sys/class/misc" "$FR/dev"

  printf '%s\0' "$MODEL_ZL1" > "$FR/proc/device-tree/model"
  printf 'qcom,msm8996-mtp\0qcom,msm8996\0qcom,mtp\0' > "$FR/proc/device-tree/compatible"
  printf '11111111-2222-3333-4444-555555555555\n' > "$FR/proc/sys/kernel/random/boot_id"
  printf '1234.56 5678.90\n' > "$FR/proc/uptime"
  printf 'Linux version 3.18.140 (build) #1 SMP\n' > "$FR/proc/version"
  # The config. `no-config` is the scenario WITHOUT the file and `config-unreadable` the one where the file
  # is there and cannot be expanded: a device that cannot be asked is a third state, and the probe must name
  # it rather than read it as "the option is off".
  CONFIGFILE="$W/kernel.config"
  CFGMODE=readable
  # THE DEFAULT IS THE STOCK SHAPE, because the scenarios that reach the driver actually running are on a
  # kernel that builds it -- and `driver-unregistered`, which is on the Halium kernel, is the state THIS
  # PORT is really in: the option off, no driver, no client bound. A scenario's config and its driver
  # directory therefore have to be chosen together, or the fixture would describe a kernel that cannot
  # exist.
  case "$SCEN" in
  driver-unregistered | no-config | config-unreadable) config_halium ;;
  config-nokey) config_nokey ;;
  *) config_stock ;;
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
  # A tree that is not a tree: no nodes anywhere, so a scan without find(1) has nothing to look AT --
  # which is a different state from a scan that ran and found no node it was looking for.
  # BOTH directories go: with `aliases` left behind the no-find scan still has something to LOOK AT, and
  # "could not search" would be unreachable -- the one state that must never print like an absence.
  bare-tree) rmdir "$FR/proc/device-tree/soc" "$FR/proc/device-tree/aliases" 2>/dev/null ;;
  esac

  # The device tree's NFC node, in the real zl1 shape. `alien-node` gets a node of the right SHAPE carrying
  # a compatible nothing in this block uses, so a scan without find(1) is a scan that HAPPENED and found
  # nothing -- the only scenario that can tell that apart from "could not look".
  case "$SCEN" in
  bare-tree | alien-node) : ;;
  no-nfc-node) i2c_bus_node; controllers_nodes ;;
  *) i2c_bus_node; nfc_node; controllers_nodes ;;
  esac
  N="$FR/proc/device-tree/soc/i2c@75b6000/nq@28"
  case "$SCEN" in
  node-disabled) dtp "$N/status" 'disabled' ;;
  # `compatible` is a LIST, and the scan must find this node because the list CONTAINS the block's string --
  # a probe that classified on the FIRST entry alone would decline the node it had just found.
  compatible-list) dtlistp "$N/compatible" 'qcom,nfc-generic\000qcom,nq-nci\000' ;;
  bus-disabled) dtp "$FR/proc/device-tree/soc/i2c@75b6000/status" 'disabled' ;;
  no-alias) rm -f "$FR/proc/device-tree/aliases/i2c8" ;;
  ven-absent) rm -f "$N/qcom,nq-ven" ;;
  irq-absent) rm -f "$N/qcom,nq-irq" ;;
  firm-absent) rm -f "$N/qcom,nq-firm" ;;
  clkreq-absent) rm -f "$N/qcom,nq-clkreq" ;;
  clk-src-absent) rm -f "$N/qcom,clk-src" ;;
  clk-src-wrong) dtp "$N/qcom,clk-src" 'BBCLK1' ;;
  # A gpio with no flag cell at all: the driver's of_get_named_gpio() accepts it, so it is NOT fatal.
  ven-odd) dtu32p "$N/qcom,nq-ven" '\000\000\000\034\000\000\000\014' ;;
  # A gpio property whose length is not a whole number of cells: not a gpio description at all.
  ven-short) dtu32p "$N/qcom,nq-ven" '\000\000\000\034\000\000\000\014\000' ;;
  esac
  if [ "$SCEN" = alien-node ]; then
    A="$FR/proc/device-tree/soc/i2c@75b6000/nq@28"
    dtp "$A/compatible" 'nxp,pn544-i2c'
    dtp "$FR/proc/device-tree/soc/qcom,alien-nfc@1/compatible" 'qcom,alien-nfc'
  fi

  # ---- the run-time side, from three questions: what the CORE makes (the client), what the DRIVER makes
  # (a directory when it registers, a symlink when its probe returns 0), and what the PROBE's own end makes
  # (the misc device). Deciding them per scenario rather than per branch is what keeps the nesting honest:
  # a bound device with no client is not a state the kernel can reach.
  CLIENT_SYSFS=""; REG=yes; BIND=yes; MISC=yes
  case "$SCEN" in
  # no node, or a node the tree switches off: the core never instantiates a client and nothing else matters
  bare-tree | alien-node | no-nfc-node | node-disabled) REG=no; BIND=no; MISC=no ;;
  # the bus is off, or the client was never created: the driver registered with nothing to attach to
  bus-disabled | no-client) BIND=no; MISC=no ;;
  # the tree refuses the node to the driver: the fatal reads, and the clock string
  # `ven-odd` is NOT in this list: a two-cell gpio is valid, so on that tree the driver binds normally.
  ven-absent | irq-absent | ven-short | clk-src-wrong | clk-src-absent) BIND=no; MISC=no ;;
  # nothing registered -- the three ways that happens (the option, the module, the config unreadable)
  no-config | config-unreadable | config-nokey | driver-unregistered | driver-unregistered-stock)
    REG=no; BIND=no; MISC=no ;;
  # registered, and attached to nothing: the probe ran and failed
  driver-unbound) BIND=no; MISC=no ;;
  # bound, and the probe stopped before misc_register()
  no-misc) BIND=yes; MISC=no ;;
  esac
  case "$SCEN" in
  bare-tree | alien-node | no-nfc-node | node-disabled | bus-disabled | no-client) CLIENT_SYSFS="" ;;
  client-other-bus) CLIENT_SYSFS=7-0028 ;;
  no-alias) CLIENT_SYSFS=5-0028 ;;
  *) CLIENT_SYSFS=8-0028 ;;
  esac
  # The bus driver's own directory, whenever there is a tree for it to bind: a scenario that has a CLIENT
  # also has a registered i2c adapter, and a report saying otherwise would be describing a kernel that
  # cannot exist.
  case "$SCEN" in
  bare-tree) : ;;
  *)
    mkdir -p "$FR/sys/bus/platform/drivers/i2c-msm-v2" "$FR/sys/bus/platform/devices"
    : > "$FR/sys/bus/platform/drivers/i2c-msm-v2/bind"
    : > "$FR/sys/bus/platform/drivers/i2c-msm-v2/unbind"
    : > "$FR/sys/bus/platform/drivers/i2c-msm-v2/uevent"
    mkdir -p "$FR/sys/bus/platform/devices/75b6000.i2c"
    ln -sfn "$FR/sys/bus/platform/devices/75b6000.i2c" \
      "$FR/sys/bus/platform/drivers/i2c-msm-v2/75b6000.i2c"
    ;;
  esac
  [ -n "$CLIENT_SYSFS" ] && client_present "$CLIENT_SYSFS"
  [ "$REG" = yes ] && driver_registered
  [ "$BIND" = yes ] && bind_client "$CLIENT_SYSFS"
  [ "$MISC" = yes ] && misc_present

  # The kernel log. `log-unreadable` makes BOTH readers fail -- the only honest way to reach "not read".
  LOGMODE=normal
  [ "$SCEN" = log-unreadable ] && LOGMODE=unreadable
  case "$SCEN" in
  log-failing)
    { printf '[    0.000000] Booting Linux on physical CPU 0x0\n'
      printf '[    1.200000] nq-nci 8-0028: irq gpio not provided\n'
      printf '[    1.200000] nq-nci 8-0028: probe of 8-0028 failed with error -22\n'
      printf '[   30.000000] random: crng init done\n'; } > "$W/kernel.log"
    ;;
  log-quiet)
    { printf '[    0.000000] Booting Linux on physical CPU 0x0\n'
      printf '[   30.000000] random: crng init done\n'; } > "$W/kernel.log"
    ;;
  log-unreadable) : > "$W/kernel.log" ;;
  *)
    # A boot with NO nq-nci line -- which is what a kernel whose config has the option off looks like, and
    # the log section says so rather than leaving a reader to read silence as health.
    { printf '[    0.000000] Booting Linux on physical CPU 0x0\n'
      printf '[    0.500000] i2c-msm-v2 75b6000.i2c: bus 8 registered\n'
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
  export LOGMODE LOGFILE="$W/kernel.log" CONFIGFILE CFGMODE
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
# The subject's exit status, which is a reading too: the top rung is the only one that may exit 0.
run_rc() { ( cd "$W" && PATH="$STUB:$MINBIN" "$SH_BIN" "$RW" "$@" ) >/dev/null 2>&1; printf '%s' "$?"; }

# ==================================================================================================
echo "== 2. the probe's own pages =="
# ==================================================================================================
want '^# zl1 NFC probe' "$(run --help)" "--help prints the probe's own header"
want 'Six readings make this probe.s design' "$(run --help)" "and the six readings it is built around"
want 'FOUR NAMES FOR ONE BLOCK' "$(run --help)" "and the four names, named in the header"
EX=$(run --explain)
nonempty "the explain page is not empty" "$EX"
want 'THE TWO NAMESPACES ON ONE NODE' "$EX" "--explain names the two generations of property names on one node"
want 'THE CONFIG LINE OUTSIDE THE MENU' "$EX" "and the Kconfig placement that decides this block"
want 'AFTER the .endmenu.' "$EX" "with the endmenu named -- the page wraps, so the sentence is matched in pieces"
want 'NFC_SET_PWR' "$EX" "and the ioctl that is the only thing that powers the chip"
want 'pn544' "$EX" "and the misc device's own name"
want 'nqx-i2c' "$EX" "and the id_table name, which is not a path in sysfs"
want 'THREE NESTED WITNESSES' "$EX" "and the nesting that decides the ladder's order"
notwant '== verdict:' "$EX" "and it prints the page and NO verdict (nothing was read)"
# --quiet is a documented mode, and an untested flag is a claim nobody checked. What it must keep is the
# verdict and the readings the verdict rests on; what it may drop is the per-node dump.
scen idle
OUT=$(run --quiet)
want '== verdict: nfc-ready' "$OUT" "--quiet still prints the verdict"
want '1\. the i2c client .*8-0028: PRESENT' "$OUT" "and the witness the rung rests on"
notwant 'other properties on this node' "$OUT" "while dropping the per-node property dump"
notwant '^       clocks:' "$OUT" "and the clock and pinmux lines with it"

# ==================================================================================================
echo "== 3. board-first: which tree is this, before any hardware =="
# ==================================================================================================
scen idle
OUT=$(run)
nonempty "the report is not empty" "$OUT"
want 'model: +Letv Technologies, Inc. MSM 8996pro \+ PMI8996 LE_ZL1-DVT1' "$OUT" "a zl1 tree is named by its model"
want 'compatible: qcom,msm8996-mtp qcom,msm8996 qcom,mtp' "$OUT" "its compatible list is printed whole"
want 'board: +LE_ZL1 -- this phone' "$OUT" "and read as this phone"
want 'kernel: +Linux version 3.18.140' "$OUT" "the running kernel is named"

scen x2-tree
OUT=$(run)
want '== verdict: wrong-board-tree' "$OUT" "the X2's device tree is its own rung, checked before any hardware"
want 'BOTH declare an NFC' "$OUT" \
  "naming that both boards declare one at the same path (the sentence is wrapped, so it is matched in pieces)"
want 'controller at the same path with the same bytes' "$OUT" "in the half that carries the conclusion"
want 'at the same path with the same bytes' "$OUT" "naming the reason the tree's shape cannot tell them apart"
want 'nothing below is about the zl1' "$OUT" "and saying what that makes the readings below"

scen unknown-model
OUT=$(run)
want '== verdict: unknown-board' "$OUT" "a model that names neither board is not attributed to this phone"
want 'neither LE_ZL1 nor LE_X2' "$OUT" "and is reported as neither rather than assumed to be a zl1"

scen no-model
OUT=$(run)
want '== verdict: unknown-board' "$OUT" "an unreadable model reaches the same rung, not a crash"
want 'board: +UNKNOWN' "$OUT" "and is named as unreadable rather than as neither"

# ==================================================================================================
echo "== 4. the node, and the two namespaces it carries =="
# ==================================================================================================
scen idle
OUT=$(run)
want '/soc/i2c@75b6000/nq@28' "$OUT" "the NFC node is read by its path, not assumed"
want 'compatible:  qcom,nq-nci' "$OUT" "with the compatible the driver matches on"
want 'status:      absent \(an absent status means enabled; this node carries none\)' "$OUT" \
  "and no status at all, which the device tree reads as ENABLED"
want 'qcom,nq-ven +phandle 28 = /soc/pinctrl@01010000, gpio 12, active high' "$OUT" \
  "the power enable resolves to the TLMM controller"
want 'qcom,nq-irq +phandle 28 = /soc/pinctrl@01010000, gpio 95' "$OUT" "and the irq pin to the same one"
want 'qcom,nq-clkreq +phandle 29 = .*pm8994@0/gpios \(label pm8994-gpio\), gpio 10' "$OUT" \
  "while the clock request is on the PMIC's gpio controller -- two controllers on one node"
want 'qcom,clk-src     BBCLK2' "$OUT" "the clock source string is read as a value"
want 'This board carries the one name the driver supports' "$OUT" "and reads as the one the driver accepts"
want 'FATAL if invalid: nfc_parse_dt\(\) returns -EINVAL and probe\(\) never runs' "$OUT" \
  "the ven read is named FATAL"
want 'OPTIONAL: a missing one is a dev_warn' "$OUT" "and the firmware pin is named as NOT fatal"
want 'NOT checked in parse_dt; at probe an invalid value is only a dev_err' "$OUT" \
  "and the clock request is named as the lenient one"
want 'AND THE PROPERTIES NOTHING IN THIS KERNEL READS' "$OUT" \
  "the second generation of names is printed where the node is read"
want 'nxp,p61-pwr +phandle 29 = .*gpio 7' "$OUT" "with its power line on the PMIC"
want 'nxp,p61-rst +phandle 28 = .*gpio 130' "$OUT" "and its reset line back on the TLMM"
want 'NOTHING ASKS FOR THESE' "$OUT" "and named as read by nothing"
want 'the pins do not even match the ones the' "$OUT" \
  "in a sentence that says the two descriptions disagree about the WIRING, not just the name"
want 'the tree on the three FATAL reads: NONE MISSING -- all three are present and valid' "$OUT" \
  "the three fatal reads are summarised as present"
want 'alias: +i2c8 -> bus 8, so the i2c core will name the client' "$OUT" "the alias gives the bus number"
want "'8-0028' -- and THAT name is what the witness section looks for" "$OUT" "and the client's name is derived and declared"
want 'reg: +40 \(0x28\) -- the i2c slave address' "$OUT" "the address is read as a number, not as text"
want 'pinctrl-0 \(the ACTIVE state\):  /soc/pinctrl@01010000/pmx_rd_nfc_int/active, /soc/pinctrl@01010000/pmx_nfc_reset/active' "$OUT" \
  "both cells of the active pinmux state are resolved"
want 'the state groups are NAMED for this block' "$OUT" "and the group names are read as this block's own pins"
want 'AND THE DRIVER OVERWRITES WHATEVER THIS SAYS' "$OUT" \
  "the interrupt described twice is named as an overwrite rather than as one value"
want 'here both name the same controller and the same line' "$OUT" "with the reason it is invisible on this board"
want 'driver: +i2c-msm-v2 ' "$OUT" "the bus this node sits on is named with its own driver"
want 'registered: yes   bound: 75b6000\.i2c' "$OUT" "which is registered and bound in this boot"

# A node found because its compatible LIST contains the block's string: classified on the first entry alone
# the probe would decline a node it had just found.
scen compatible-list
OUT=$(run)
want 'compatible:  qcom,nfc-generic qcom,nq-nci ' "$OUT" "a compatible list is printed whole"
want '== verdict: nfc-ready' "$OUT" "and a node found through a LATER entry is treated as the block"

# A node the tree switches off: the core never instantiates a client for it, so the driver has nothing to
# bind -- and the probe must say the TREE did that, not the kernel.
scen node-disabled
OUT=$(run)
want 'status:      disabled' "$OUT" "a status that is not okay is printed as read"
want '== verdict: no-node-enabled' "$OUT" "and the node being switched off is its own rung"
want 'NO status property at all, which the device tree reads as ENABLED' "$OUT" \
  "with the reading the probe has to be careful to get the right way round on this board"

# ==================================================================================================
echo "== 5. the two config lines that decide this block =="
# ==================================================================================================
# THIS IS THE BLOCK'S OWN READING. `CONFIG_NFC` is off in BOTH kernels -- the one this port boots and the
# stock one that builds the driver -- so a probe that read it would give the same answer for a kernel with
# the driver and one without.
scen idle
OUT=$(run)
want 'CONFIG_NFC_NQ +y \(built in\)' "$OUT" "the line that DECIDES is read, and it says the driver is built"
want 'CONFIG_NFC +NOT SET' "$OUT" "while the line beside it says the menu is off"
want 'AND THE SECOND ONE IS NOT A PRECONDITION FOR THE FIRST' "$OUT" \
  "and the probe says why both have to be read together"
want 'sits AFTER the .endmenu. of .menu' "$OUT" "naming the place in Kconfig that makes that true"
want 'the driver is BUILT with the menu off' "$OUT" "and reporting the stock kernel's own shape"
want 'APPEARS IN' "$OUT" "and that the same line appears in both kernels"
want 'The rung below is decided on CONFIG_NFC_NQ' "$OUT" "so which line the verdict rests on is stated"
want 'AND THE TWO SWITCHES THAT ARE DEFINED NOWHERE' "$OUT" "the two dead #ifdefs are named"
want 'NO POWER-ON AT PROBE' "$OUT" "including the one that would have powered the chip"
want 'ioctl NFC_SET_PWR \(1 = on, 2 = download mode, 0 = off\)' "$OUT" "and what powers it instead"
want 'config.gz: yes present / yes permission-readable / yes expanded' "$OUT" \
  "the config file's three facts are printed separately"

# A config where the symbol is not in the file at all: a fourth state, and not the same as "not set".
scen config-nokey
OUT=$(run)
want 'CONFIG_NFC_NQ +absent from the config' "$OUT" "a config that does not carry the symbol says so"
want '== verdict: driver-not-built' "$OUT" "and is still a kernel that does not build the driver"

# THE STATE THIS PORT IS REALLY IN: the Halium kernel's config, no driver directory, and the client present.
scen driver-unregistered
OUT=$(run)
want 'CONFIG_NFC_NQ +NOT SET' "$OUT" "the Halium kernel's own line"
want 'CONFIG_NFC +NOT SET' "$OUT" "with both lines off, as that kernel really has them"
want '== verdict: driver-not-built' "$OUT" "the rung this port is on"
want "THE KERNEL'S OWN CONFIG DOES NOT BUILD IT" "$OUT" "with the cause named as the config"
want 'it is one defconfig line and a boot-image build' "$OUT" "and the size of the next move"
want 'CONFIG_NFC is off in the kernel this port boots AND in the stock kernel that HAS the driver' "$OUT" \
  "including the warning not to check the obvious line instead"
want '1\. the i2c client .*8-0028: PRESENT' "$OUT" "and the WEAKEST witness IS present on this kernel"
want 'is here with NO NFC driver built at' "$OUT" "which the probe says out loud rather than reading as health"
want '/sys/bus/i2c/drivers/nq-nci: ABSENT \(the driver did not register\)' "$OUT" \
  "while the driver directory is absent"
want '3\. .*pn544: ABSENT' "$OUT" "and the strongest witness is absent with it"
rc_is 1 "$(run_rc)"

# THE SAME MISSING DIRECTORY ON A KERNEL THAT BUILDS THE DRIVER: the config is a separate axis, and the
# verdict must not blame a config line that says the option is on.
scen driver-unregistered-stock
OUT=$(run)
want 'CONFIG_NFC_NQ +y \(built in\)' "$OUT" "this kernel builds the driver"
want '== verdict: driver-not-registered' "$OUT" "so a missing directory is NOT read as 'not built'"
want 'NOT attributed to a config line here' "$OUT" "and the probe says which rung it is on instead"
want "CONFIG_NFC_NQ reads 'y \(built in\)'" "$OUT" "quoting the line that would have contradicted it"

# A config that could not be read at all: the third state, which must not print as "the option is off".
scen no-config
OUT=$(run)
want 'config.gz: no present / no permission-readable / no expanded' "$OUT" "a missing config file is named as missing"
want 'the kernel config could NOT be read' "$OUT" "and the reason is printed as a state of its own"
want 'CONFIG_NFC_NQ +NOT READ' "$OUT" "so the column says NOT READ rather than NOT SET"
want '== verdict: driver-not-registered' "$OUT" "and the verdict does not claim the kernel cannot build it"
want "CONFIG_NFC_NQ reads 'NOT READ'" "$OUT" "with the third state quoted in the message"
notwant 'driver-not-built' "$OUT" "and never the rung that blames a config line nobody read"

# The file is there and permission-readable, but it cannot be EXPANDED -- the case that makes "readable" an
# incomplete reading on its own.
scen config-unreadable
OUT=$(run)
want 'config.gz: yes present / yes permission-readable / no expanded' "$OUT" \
  "a config that is present and unexpandable says exactly that"
want 'CONFIG_NFC_NQ +NOT READ' "$OUT" "and its columns are NOT READ all the same"
want 'either the file is not there, or it is there and this' "$OUT" "with both causes named"

# ==================================================================================================
echo "== 6. the three witnesses, and the rungs =="
# ==================================================================================================
# The whole chain in place: the top rung, and the only one that may exit 0.
scen idle
OUT=$(run)
want 'driver: +nq-nci ' "$OUT" "the driver's directory name is the one sysfs is keyed by"
want 'by of_match "qcom,nq-nci" \(its i2c_device_id is "nqx-i2c" and its misc device is named "pn544"\)' "$OUT" \
  "with all four names of the block on one line"
want '/sys/bus/i2c/drivers/nq-nci: present, bound: 8-0028' "$OUT" "the driver is registered and bound"
want '1\. the i2c client .*8-0028: PRESENT' "$OUT" "the FIRST witness is present"
want 'it is under EXACTLY the name derived above \(bus i2c8, address 0028\)' "$OUT" \
  "under exactly the name the tree's alias and reg predict"
want 'this is the WEAKEST witness in the block' "$OUT" "and is named as the weakest"
want '2\. a device bound to .nq-nci.' "$OUT" "the SECOND witness is the bind"
want '3\. .*pn544: PRESENT' "$OUT" "the THIRD witness is the misc device"
want 'dev:       10:56 -- major:minor, i.e. a DEVICE NODE exists for this entry' "$OUT" \
  "with its major:minor read from the class entry"
want 'misc_register\(\) is called AFTER the clock and the' "$OUT" ...
want 'THE NAME IS .pn544. AND THE CHIP IS AN NQ' "$OUT" "and the misc name is named as another driver's"
want 'AND IT IS NOT OPENED HERE' "$OUT" "and the device node is named as NOT opened"
want 'THE NESTING IS THE READING' "$OUT" "the nesting is stated where the witnesses are"
want '== verdict: nfc-ready' "$OUT" "the whole chain is the top rung"
want 'AND THE CHIP IS STILL POWERED DOWN, WHICH IS NOT A FAULT' "$OUT" \
  "with the chip's power state named even on the top rung"
want 'WHAT THIS IS NOT: an answer to .does NFC work.' "$OUT" "and what the top rung does not claim"
rc_is 0 "$(run_rc)"
want '(none: the kernel log mentions no NFC driver this boot)' "$OUT" \
  "and a boot with no NFC line prints a named silence rather than nothing"
rc_is 0 "$(run_rc)"

# No alias in the tree: the BUS NUMBER cannot be derived, so the probe looks for the ADDRESS instead of a
# name -- and a client it finds that way is real.
scen no-alias
OUT=$(run)
want 'alias: +none points at this controller' "$OUT" "a tree with no alias for this bus says so"
want 'looks for the ADDRESS instead' "$OUT" "and the probe falls back to the address rather than to a name"
want 'the i2c client .*5-0028: PRESENT' "$OUT" "so a client under an underivable bus number is FOUND"
want 'BUT NOT UNDER THE NAME DERIVED ABOVE' "$OUT" "and is named as found by address, not by name"
want '== verdict: nfc-ready' "$OUT" "so the rung does not stop on a missing alias"

# A client under a DIFFERENT bus number: the alias is what is wrong, and the verdict must not read it as
# "there is no client".
scen client-other-bus
OUT=$(run)
want 'the i2c client .*7-0028: PRESENT' "$OUT" "a client under another bus number is found by its address"
want 'BUT NOT UNDER THE NAME DERIVED ABOVE: i2c8 gives bus 8' "$OUT" "and the derived bus number is named"
want 'the next move is the controller.s alias rather than the NFC driver' "$OUT" "with the right next move"
want '== verdict: nfc-ready' "$OUT" "so a wrong bus number does not stop the ladder"

# THE CLIENT IS THE WEAKEST WITNESS, AND IT STILL OUTRANKS THE DRIVER. With the bus switched off in the tree
# there is nothing to bind, so a probe that asked about the driver first would blame the driver.
scen bus-disabled
OUT=$(run)
want 'status:     disabled' "$OUT" "the i2c bus's own status is printed"
want '== verdict: no-client' "$OUT" "a bus the tree switches off is its own rung"
want 'NO CONFIG LINE FOR THE NFC DRIVER CAN FIX THIS' "$OUT" "and the probe says no config line can fix it"
want 'the next move is the i2c controller the node sits on' "$OUT" "with the next move named"
notwant 'driver-not-bound' "$OUT" "and it does not report a driver rung it never got to"

scen no-client
OUT=$(run)
want '== verdict: no-client' "$OUT" "no client at all reaches the same rung"
want '/sys/bus/i2c/drivers/nq-nci: present, bound: NONE' "$OUT" \
  "while the driver IS registered -- which is what makes the rung order a check"
want 'carries address 0028 either' "$OUT" "and the probe says it looked for the address too"
want 'did not become a client: the bus node is disabled or its own driver is not built' "$OUT" \
  "in a sentence that names both causes (it is wrapped, so it is matched in pieces)"

# Registered and attached to nothing: the probe ran and failed.
scen driver-unbound
OUT=$(run)
want '== verdict: driver-not-bound' "$OUT" "a registered driver with nothing attached is its own rung"
want 'bound: NONE' "$OUT" "which the driver directory line says"
want 'nq-nci_probe\(\) fails on a missing/invalid qcom,nq-ven or qcom,nq-irq' "$OUT" \
  "with the list of what makes that probe fail"
notwant 'AND THE TREE ITSELF IS THE CAUSE' "$OUT" "and it does not blame a tree that is complete"

# The fatal reads, one at a time. The verdict must carry WHICH read the tree is missing, because that fact
# alone means the node never binds under any config.
scen ven-absent
OUT=$(run)
want 'qcom,nq-ven      absent' "$OUT" "a missing power enable is printed as absent"
want 'the tree on the three FATAL reads: qcom,nq-ven' "$OUT" "and summarised as a missing fatal read"
want '== verdict: driver-not-bound' "$OUT" "which is why the driver is not bound"
want 'AND THE TREE ITSELF IS THE CAUSE: it is missing or invalid on qcom,nq-ven' "$OUT" \
  "named in the verdict itself rather than only in the section above"
want 'That is a device-tree \(boot image\) fact, and no runtime action fixes it' "$OUT" \
  "with the kind of fix that would be needed"

scen irq-absent
OUT=$(run)
want 'qcom,nq-irq      absent' "$OUT" "the irq pin missing is the second fatal read"
want 'the tree on the three FATAL reads: qcom,nq-irq' "$OUT" "and is summarised the same way"

# A gpio property with only two cells: the driver's of_get_named_gpio() takes the flags cell as optional, so
# this is a VALID description and must not be counted among the fatal reads.
scen ven-odd
OUT=$(run)
want 'qcom,nq-ven      phandle 28 = /soc/pinctrl@01010000, gpio 12, no flag cell' "$OUT" \
  "a gpio with no flag cell is printed as exactly that"
want 'the tree on the three FATAL reads: NONE MISSING' "$OUT" \
  "and is NOT counted among the fatal reads, because the driver accepts it"
want '== verdict: nfc-ready' "$OUT" "so the chain is not broken by a missing flag cell"

# A gpio property whose length is not a whole number of cells is not a gpio description at all: a probe that
# read the first three bytes of four would print a pin number of the right shape and the wrong value.
scen ven-short
OUT=$(run)
want 'qcom,nq-ven      not-a-gpio\(9 bytes\)' "$OUT" "a gpio property that is not whole cells says so"
want 'the tree on the three FATAL reads: qcom,nq-ven' "$OUT" "and counts as a missing fatal read"

# THE TWO LENIENT READS. The driver warns and carries on, so the verdict must stay on the top rung -- a
# probe that treated these as fatal would report a dead block on a working one.
scen firm-absent
OUT=$(run)
want 'qcom,nq-firm     absent' "$OUT" "the optional firmware pin is printed as absent"
want 'the tree on the three FATAL reads: NONE MISSING' "$OUT" "and is NOT counted among the fatal reads"
want '== verdict: nfc-ready' "$OUT" "so a working chain with no firmware pin is still the top rung"

scen clkreq-absent
OUT=$(run)
want 'qcom,nq-clkreq   absent' "$OUT" "the clock request is printed as absent"
want 'the tree on the three FATAL reads: NONE MISSING' "$OUT" "and is not among the fatal reads either"
want '== verdict: nfc-ready' "$OUT" "so it does not stop the chain"

# The clock source: missing and wrong are two different failures with the same consequence, and the value the
# driver supports is the one this board carries.
scen clk-src-absent
OUT=$(run)
want 'qcom,clk-src     absent' "$OUT" "a missing clock source is printed as absent"
want 'ABSENT, AND THAT IS FATAL' "$OUT" "and named fatal"
want 'the tree on the three FATAL reads: qcom,clk-src' "$OUT" "and summarised with the fatal reads"

scen clk-src-wrong
OUT=$(run)
want 'qcom,clk-src     BBCLK1' "$OUT" "a clock source that is not the one the driver supports is printed"
want 'AND THIS IS THE FAILING CASE' "$OUT" "and named as the case that fails the probe"
want 'the driver accepts only .BBCLK2.' "$OUT" "with the one accepted value named"
want '== verdict: driver-not-bound' "$OUT" "so the tree value, not the config, is why it is not bound"

# Bound, and the probe stopped before misc_register(): the third witness is what separates "believed to be
# built" from "the chain is whole".
scen no-misc
OUT=$(run)
want '== verdict: no-misc-device' "$OUT" "a bound driver with no misc device is its own rung"
want 'nq-nci_probe\(\) did not run to the end' "$OUT" "with the probe's own end named as where it stopped"
want 'misc_register\(\) comes after clk_get\(\)/clk_prepare_enable' "$OUT" \
  "and the steps before it, which is what the absence of that device rules out"
want 'a driver that failed after misc_register\(\)' "$OUT" "plus the failure that deregisters again"

# The tree-level rungs, and the two searches that must not print the same way.
scen bare-tree
OUT=$(run)
want '== verdict: no-device-tree-node' "$OUT" "a tree with no nodes at all, searched with find, is an ABSENCE"
notwant 'tree-unscanned' "$OUT" "and not a search that could not run"

scen bare-tree
OUT=$(run_nofind)
want '== verdict: tree-unscanned' "$OUT" "the same tree with no find(1) is a search that could not run"
want "probe could not look', and the two must not print the same way" "$OUT" \
  "and the probe says so in its own words (wrapped, so matched in pieces)"
want 'NOT .the tree declares no NFC controller.' "$OUT" "naming what it is not"
notwant 'no-device-tree-node' "$OUT" "and never printing as an absence"

scen alien-node
OUT=$(run)
want '== verdict: no-device-tree-node' "$OUT" "a node of the right shape with another compatible is an absence"
want 'the NFC controller is not described at all' "$OUT" "and the absence is spelled out"
want 'on this board the node is in all 15 of its trees' "$OUT" \
  "with the reason that rung is a surprising answer on this phone"

scen alien-node
OUT=$(run_nofind)
want '== verdict: no-device-tree-node' "$OUT" "and with no find(1) it is STILL an absence, because the scan ran"
want 'the whole tree is scanned' "$OUT" "which is what a fallback that walks the known shapes can still say"

scen no-nfc-node
OUT=$(run)
want '== verdict: no-device-tree-node' "$OUT" "a tree that simply has no such node is the same rung"
want 'no node in this device tree carries .qcom,nq-nci.' "$OUT" "with the compatible quoted"

# The kernel log: a failure, a silence, and a log that could not be read.
scen log-failing
OUT=$(run)
want 'irq gpio not provided' "$OUT" "the driver's own failure strings are matched out of the log"
want 'probe of 8-0028 failed with error -22' "$OUT" "including the probe failure line"
want 'source: dmesg' "$OUT" "and the reader it came from is named"

scen log-quiet
OUT=$(run)
want '(none: the kernel log mentions no NFC driver this boot)' "$OUT" \
  "a log with no NFC line prints a NAMED silence rather than nothing"
want 'A LINE ABOUT NFC IN THIS LOG WOULD BE EVIDENCE' "$OUT" \
  "and the probe says what such a line would have meant"
want 'the config file is not the running kernel.s' "$OUT" \
  "including that a contradiction would mean the config is not this kernel's"

scen log-unreadable
OUT=$(run)
want 'the kernel log could not be read' "$OUT" "a log that cannot be read is a state of its own"
want 'so this section is NOT READ' "$OUT" "and is named NOT READ rather than as a silence"
want 'No verdict below rests on it' "$OUT" "which is why the verdict is still decided on files"
want '== verdict: nfc-ready' "$OUT" "so an unreadable log does not change the rung"

# ==================================================================================================
echo "== 7. the mutations: each one has to redden something =="
# ==================================================================================================
# A harness that cannot make its subject fail has tested nothing. Each mutation below is a defect that would
# LOOK right in the report, and each is run against the scenario where it shows.

# 1. THE BLOCK'S OWN DEFECT: reading the config line beside the right one. `CONFIG_NFC` is off in the kernel
#    this port boots AND in the stock kernel that builds the driver, so a probe that read it would report "not
#    built" on a kernel that has the driver -- and the report would look exactly like a correct one.
sed 's#cfg_opt CONFIG_NFC_NQ#cfg_opt CONFIG_NFC#g' "$SRC" > "$W/mut-config.sh"
if cmp -s "$SRC" "$W/mut-config.sh"; then bad "the config mutation did not apply"; else
  scen driver-unregistered-stock
  OUT=$(mut_run "$W/mut-config.sh")
  notwant '== verdict: driver-not-registered' "$OUT" \
    "reading CONFIG_NFC instead of CONFIG_NFC_NQ loses the rung a missing driver directory belongs on when the kernel DOES build it (the mutation)"
  want '== verdict: driver-not-built' "$OUT" "and blames a config line that says the opposite"
  want 'CONFIG_NFC_NQ +NOT SET' "$OUT" \
    "while the column is still LABELLED CONFIG_NFC_NQ -- the label and the value disagree, which is the shape of the defect"
  scen idle
  OUT=$(mut_run "$W/mut-config.sh")
  want 'CONFIG_NFC +NOT SET' "$OUT" "and on a kernel that builds the driver the decided line reads NOT SET"
  notwant 'CONFIG_NFC_NQ +y \(built in\)' "$OUT" \
    "so the driver is never reported as built (the bus's own option is, and that is a different line)"
fi

# 2. The clock source treated as information instead of as a switch: the driver fails the probe on any value
#    other than BBCLK2, so a probe that stopped checking it would report a chain that cannot be.
sed 's#^  case "\$_clk" in$#  case "BBCLK2" in#' "$SRC" > "$W/mut-clk.sh"
if cmp -s "$SRC" "$W/mut-clk.sh"; then bad "the clock-source mutation did not apply"; else
  scen clk-src-wrong
  OUT=$(mut_run "$W/mut-clk.sh")
  notwant 'AND THIS IS THE FAILING CASE' "$OUT" \
    "not treating the clock source as a switch loses the reading that this tree value fails the probe (the mutation)"
  want 'qcom,clk-src     BBCLK1' "$OUT" "while the value is still printed, with nothing said about it"
  scen clk-src-absent
  OUT=$(mut_run "$W/mut-clk.sh")
  notwant 'ABSENT, AND THAT IS FATAL' "$OUT" "and a MISSING clock source stops being named as fatal too"
  want 'the tree on the three FATAL reads: NONE MISSING' "$OUT" \
    "so the report claims a complete tree on one that cannot ever bind"
fi

# 3. The rung ORDER. The client is the weakest witness and the driver question is the one a reader expects, so
#    a probe that asked about the driver first would blame the driver on a board whose bus is switched off.
sed 's#^elif \[ "\$CLIENT_FOUND" = no \]; then$#elif false; then#' "$SRC" > "$W/mut-order.sh"
if cmp -s "$SRC" "$W/mut-order.sh"; then bad "the rung-order mutation did not apply"; else
  scen no-client
  OUT=$(mut_run "$W/mut-order.sh")
  notwant '== verdict: no-client' "$OUT" \
    "the client rung never firing loses the rung a board with no client belongs on (the mutation)"
  want '== verdict: driver-not-bound' "$OUT" "and reports a driver a rung that nothing bound"
  notwant 'NO CONFIG LINE FOR THE NFC DRIVER CAN FIX THIS' "$OUT" \
    "so the sentence that says no config line can fix it is gone with it"
fi

# 4. The THIRD witness, made irrelevant. The misc device is what separates "the driver is bound" from "the
#    probe ran to the end", and a probe that dropped it would call a half-run probe a whole one.
sed 's#^elif \[ "\$MISC_PRESENT" = no \]; then$#elif false; then#' "$SRC" > "$W/mut-misc.sh"
if cmp -s "$SRC" "$W/mut-misc.sh"; then bad "the misc-nesting mutation did not apply"; else
  scen no-misc
  OUT=$(mut_run "$W/mut-misc.sh")
  notwant '== verdict: no-misc-device' "$OUT" \
    "dropping the third witness loses the rung a half-run probe belongs on (the mutation)"
  want '== verdict: nfc-ready' "$OUT" "and reports the top rung on a chain whose end never ran"
fi

# 5. The two property NAMESPACES collapsed. The driver's power enable is a TLMM pin; the unread
#    `nxp,p61-pwr` is a PMIC pin, and a probe that read the second as if it were the first would describe
#    wiring no driver uses -- with a plausible phandle, pin and polarity.
sed 's#gpio_cells "\$NODE/qcom,nq-ven"#gpio_cells "$NODE/nxp,p61-pwr"#g' "$SRC" > "$W/mut-ns.sh"
if cmp -s "$SRC" "$W/mut-ns.sh"; then bad "the namespace mutation did not apply"; else
  scen idle
  OUT=$(mut_run "$W/mut-ns.sh")
  notwant 'qcom,nq-ven +phandle 28 = /soc/pinctrl@01010000, gpio 12' "$OUT" \
    "reading the driver's power enable out of the namespace nothing asks for loses the controller it is really on (the mutation)"
  want 'qcom,nq-ven +phandle 29 = .*pm8994-gpio., gpio 7' "$OUT" \
    "and prints the PMIC pin instead -- the UNREAD generation's line, as if it were the driver's"
fi

# 6. The endianness. A device-tree u32 is four BIG-ENDIAN bytes and this SoC is little-endian, so `od -tu4`
#    prints 0x28 as 0x28000000: a plausible number, and the client's name comes out wrong.
sed 's#^  printf .%s. \$((_u_a \* 16777216 + _u_b \* 65536 + _u_c \* 256 + _u_d))$#  printf "%s" "$(od -An -tu4 "$1" | tr -d " ")"#' \
  "$SRC" > "$W/mut-endian.sh"
if cmp -s "$SRC" "$W/mut-endian.sh"; then bad "the endianness mutation did not apply"; else
  scen idle
  OUT=$(mut_run "$W/mut-endian.sh")
  notwant 'reg: +40 \(0x28\)' "$OUT" "reading a big-endian cell in host order loses the address (the mutation)"
  want 'reg: +671088640' "$OUT" "and prints a number of the right shape and the wrong value"
  want '== verdict: no-client' "$OUT" \
    "so a client that exists is looked for under a name that cannot exist, and the whole block reads as absent"
fi

# 7. An absent `status` read as NOT enabled. This board's node carries no status property, and the device tree
#    reads that as ENABLED -- so getting it backwards reports the tree as switching off its own NFC node.
sed 's#^  okay | ok | EMPTY | absent) NODE_EN=yes ;;$#  okay | ok) NODE_EN=yes ;;#' "$SRC" > "$W/mut-status.sh"
if cmp -s "$SRC" "$W/mut-status.sh"; then bad "the absent-status mutation did not apply"; else
  scen idle
  OUT=$(mut_run "$W/mut-status.sh")
  notwant '== verdict: nfc-ready' "$OUT" \
    "reading an absent status as disabled loses the top rung on a node the tree has enabled (the mutation)"
  want '== verdict: no-node-enabled' "$OUT" "and reports the tree as switching its own node off"
fi

# 8. "Could not search" collapsed into "not found". The one state that must never print like an absence.
sed 's#^  \[ "\$_nc_any" = 1 \] && return 1$#  return 1#' "$SRC" > "$W/mut-scan.sh"
if cmp -s "$SRC" "$W/mut-scan.sh"; then bad "the scan mutation did not apply"; else
  scen bare-tree
  OUT=$(mut_run "$W/mut-scan.sh" nofind)
  notwant '== verdict: tree-unscanned' "$OUT" "collapsing could-not-search into not-found loses that state (the mutation)"
  want '== verdict: no-device-tree-node' "$OUT" "and prints an absence the probe cannot support"
fi

# 9. Phandles counted per FILE instead of per NODE. Every node on this board carries BOTH `phandle` and
#    `linux,phandle`, so a resolver that counts files calls each real hit ambiguous with itself.
sed 's#^      case "\$_ph_seen" in \*" \$_ph_dir "\*) continue ;; esac$#      :#' "$SRC" > "$W/mut-phandle.sh"
if cmp -s "$SRC" "$W/mut-phandle.sh"; then bad "the phandle mutation did not apply"; else
  scen idle
  OUT=$(mut_run "$W/mut-phandle.sh")
  notwant 'phandle 28 = /soc/pinctrl@01010000, gpio 12' "$OUT" \
    "counting phandle FILES turns one node's two names into an ambiguity (the mutation)"
  want 'phandle 28 = AMBIGUOUS\(2\)' "$OUT" "and a controller that resolves reads as ambiguous"
fi

# 10. The driver's name taken from the WRONG one of the four. `nqx-i2c` is the i2c_device_id and it is NOT a
#     path in sysfs, so looking the driver up by it finds nothing on a device where it is registered.
sed "s#^    printf 'nq-nci\\\\tCONFIG_NFC_NQ#    printf 'nqx-i2c\\\\tCONFIG_NFC_NQ#" "$SRC" > "$W/mut-drvname.sh"
if cmp -s "$SRC" "$W/mut-drvname.sh"; then bad "the driver-name mutation did not apply"; else
  scen idle
  OUT=$(mut_run "$W/mut-drvname.sh")
  notwant 'driver: +nq-nci ' "$OUT" \
    "looking the driver up under its id_table name loses the name sysfs is keyed by (the mutation)"
  want 'driver: +nqx-i2c ' "$OUT" "and prints a name no directory carries"
  want '== verdict: driver-not-registered' "$OUT" \
    "so a registered driver reads as one that never registered"
  want 'i2c/devices/8-0028: PRESENT' "$OUT" \
    "while the client is still there, so the two readings DISAGREE -- which is the shape of the defect"
fi

# 11. "Could not read" collapsed into "not set". The config that cannot be read is a third state; a probe that
#     reported it as the option being off would blame a config line it never read.
sed 's#printf .NOT READ.; return; fi#printf "NOT SET"; return; fi#' "$SRC" > "$W/mut-notread.sh"
if cmp -s "$SRC" "$W/mut-notread.sh"; then bad "the not-read mutation did not apply"; else
  scen no-config
  OUT=$(mut_run "$W/mut-notread.sh")
  notwant '== verdict: driver-not-registered' "$OUT" \
    "reporting an unreadable config as NOT SET loses the third state (the mutation)"
  want '== verdict: driver-not-built' "$OUT" "and blames a config line that was never read"
  want 'CONFIG_NFC_NQ +NOT SET' "$OUT" "on a page whose own line above says the file was not expanded"
  want 'no expanded' "$OUT" "so the two readings contradict each other in the same report"
fi

# 12. The misc device looked for under the DRIVER's name. `pn544` is the name the driver registers and it is
#     also another driver's -- and `nq-nci`, the name a reader would expect, is a device node that never
#     exists.
sed 's#^MISC_DIR=/sys/class/misc/pn544$#MISC_DIR=/sys/class/misc/nq-nci#' "$SRC" > "$W/mut-miscname.sh"
if cmp -s "$SRC" "$W/mut-miscname.sh"; then bad "the misc-name mutation did not apply"; else
  scen idle
  OUT=$(mut_run "$W/mut-miscname.sh")
  notwant '== verdict: nfc-ready' "$OUT" \
    "looking for the misc device under the name a reader would expect loses the strongest witness (the mutation)"
  want '== verdict: no-misc-device' "$OUT" \
    "and reports a probe that ran to the end as one that stopped early"
  notwant 'misc/pn544' "$OUT" "while the name the driver really registers is gone from the report"
fi

# ==================================================================================================
echo "== 8. this harness's own citation =="
# ==================================================================================================
# A count typed by hand in the first thing a human reads goes stale the moment this file grows, so this
# harness reads its own citation out of the health check and compares it with what it just ran.
HEALTH="$HERE/zl1-health-check.sh"
if [ -r "$HEALTH" ]; then
  # The number is the one immediately before ` checks`, taken from the matched text rather than from the whole
  # sentence: `grep -oE '[0-9]+'` over the match also finds the 1 in `zl1-`, which is how the first version of
  # this check on a sibling harness compared 1 against its own total. The first match is taken with `sed -n
  # 1p` and NOT with `head -n1`: this file sets pipefail, and a reader that exits early turns the WRITER's
  # SIGPIPE death into the pipeline's status -- a check that would report a failure of its own extractor.
  match=$(tr '\n' ' ' < "$HEALTH" |
    grep -oE 'zl1-nfc-probe-selftest\.sh[^0-9]*[0-9]+ checks' | sed -n 1p)
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
