#!/usr/bin/env bash
# zl1 video probe -- offline self-test. Host-side, touches no device, needs no phone.
#
# Why this exists. `scripts/device/zl1-video-probe.sh` is the instrument for the `video-codec` row of doc
# 137's gap list -- twelve device-tree nodes, the second-largest block nothing in this tree had ever read.
# That block is TWO layers that fail differently (a firmware the peripheral loader has to authenticate
# through the secure world, and a V4L2 driver that only registers if the first one's node is enabled), and
# the probe's whole design follows from two facts that make a naive reading WRONG:
#
#   1. THE FIRMWARE IS NOT LOADED AT BOOT. venus_hfi.c's __load_fw() runs when something OPENS a video
#      instance, so on an idle boot the subsystem reads OFFLINE and that is the healthy state. A probe that
#      called a missing firmware a fault would be wrong on most boots, so the scenario that has to exist is
#      the one where everything is in place and NOBODY HAS ASKED -- and it must produce its own rung.
#   2. THE SAME DRIVER SERVES FOUR NODES. subsys-pil-tz has four devices on this board (kgsl-hyp, lpass,
#      ssc, venus) with one search path and one SCM service, so "the driver is there" says nothing about
#      venus. The four are each other's control group and the probe prints all their states -- which is why
#      the subsystem table is asserted, not just venus's own line.
#
# How it works: **the stub directory IS the device.** The probe runs as itself against a fake root, with
# the device's tools stubbed and PATH sandboxed to `$STUB:$MINBIN`, where MINBIN holds symlinks to the real
# coreutils. The rewrite covers FOUR path roots (`/proc/`, `/sys/`, `/dev/video`, `/lib/firmware`) because
# this probe resolves the firmware search list itself -- and the sandbox is what keeps a miss from silently
# reading THIS laptop: the last run against a sandbox that lacked a `journalctl` stub printed the HOST's
# kernel log, which is exactly the failure the sandbox exists to catch.
#
# Usage: zl1-video-probe-selftest.sh [--keep]
#   --keep   leave the fake device, the stubs and the rewritten probe for inspection
#
# `ZL1_VIDEO_PROBE_SRC=/path` runs the whole thing against another copy of the subject, which is how a
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
SRC="${ZL1_VIDEO_PROBE_SRC:-$HERE/../device/zl1-video-probe.sh}"
[ -r "$SRC" ] || { echo "cannot read the subject: $SRC" >&2; exit 2; }

W="${TMPDIR:-/tmp}/zl1-video-probe-selftest"
# `root`, not `dev`: the fake root's path must not itself contain a path the rewriter hunts for, or the
# replacement text gets rewritten in turn (the trap docs 120 records for its sibling harnesses).
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
# A check that passes for free on an empty string is not a check.
nonempty() { if [ -n "$2" ]; then ok "$1"; else bad "$1 -- the output was empty, so nothing below it can be trusted"; fi; }
# A count, asserted as a number rather than as a substring: "8 entries" and "18 entries" both contain "8".
count_is() { # $1 = text, $2 = ERE, $3 = expected count, $4 = label
  local n; n=$(grep -cE -- "$2" <<< "$1")
  if [ "$n" = "$3" ]; then ok "$4"; else bad "$4 (expected $3, counted $n)"; fi
}

# --- the sandbox PATH ------------------------------------------------------------------------------
# `type -P`, not `command -v`: in a shell whose profile has made one of these a function, `command -v`
# prints the NAME rather than a path and the symlink would point at itself.
for t in awk basename cat cut dirname find grep head od sed sort tail tr uniq wc uname; do
  p="$(type -P "$t" 2>/dev/null)" || continue
  [ -n "$p" ] || continue
  ln -sf "$p" "$MINBIN/$t"
  [ "$t" = find ] || ln -sf "$p" "$MINBIN_NOFIND/$t"
done
for t in awk grep head od sed tail tr cut find; do
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
# TWO PASSES in two FILES per rule, so each rule is counted where it ran. A one-pass rewrite cascades: the
# `/sys/` inside `/proc/sys/kernel/random/boot_id` would be replaced by the `/proc/` rule and then the
# `/sys/` rule would hit the result. Pass 1 turns each root into a token that cannot itself be a device
# path; pass 2 expands the tokens, and nothing in a replacement can be re-matched by a rule that already
# ran.
#
# FOUR RULES, and each is here because a reading depends on it. `/proc/` and `/sys/` carry the node, the
# board, the cmdline, the loader's directories and the subsystem bus. `/dev/video` (and not `/dev/`) is the
# V4L2 half -- `/dev/` alone would rewrite the probe's own `2>/dev/null` into a path in the fake root and
# every quiet redirect would fail to create it. `/lib/firmware` and `/lib64/firmware` are the loader's
# BUILT-IN search list: unrewritten, a "the firmware is unreachable" scenario would find the HOST's
# /lib/firmware and the rung could never be reached.
A1="$W/pass1a.sh"; P1="$W/pass1.sh"; RW="$W/video-probe.sh"
rewrite() { # $1 = source, $2 = output
  sed -e 's#/proc/#__ZP__#g' "$1" > "$W/pass1a.sh"
  sed -e 's#/sys/#__ZS__#g' "$W/pass1a.sh" > "$W/pass1b.sh"
  sed -e 's#/lib64/firmware#__ZL64__#g' "$W/pass1b.sh" > "$W/pass1c.sh"
  sed -e 's#/lib/firmware#__ZL__#g' "$W/pass1c.sh" > "$W/pass1.sh"
  sed -e 's#/dev/video#__ZDV__#g' "$W/pass1.sh" > "$W/pass1d.sh"
  sed -e "s#__ZP__#$FR/proc/#g" -e "s#__ZS__#$FR/sys/#g" -e "s#__ZL__#$FR/lib/firmware#g" \
    -e "s#__ZL64__#$FR/lib64/firmware#g" -e "s#__ZDV__#$FR/dev/video#g" "$W/pass1d.sh" > "$2"
}
sed -e 's#/proc/#__ZP__#g' "$SRC" > "$A1"
cnt() { grep -o -- "$1" "$2" 2>/dev/null | wc -l | tr -d ' '; }
[ "$(cnt '/proc/' "$SRC")" = "$(cnt '__ZP__' "$A1")" ] \
  || { echo "the /proc/ rewrite did not cover every /proc/ in the source" >&2; exit 2; }
[ "$(cnt '/proc/' "$A1")" = 0 ] || { echo "a /proc/ survived pass 1 -- the probe would read this host" >&2; exit 2; }
sed -e 's#/sys/#__ZS__#g' "$A1" > "$W/pass1b.sh"
[ "$(cnt '/sys/' "$A1")" = "$(cnt '__ZS__' "$W/pass1b.sh")" ] \
  || { echo "the /sys/ rewrite did not cover every /sys/ in the source" >&2; exit 2; }
[ "$(cnt '/sys/' "$W/pass1b.sh")" = 0 ] || { echo "a /sys/ survived pass 1" >&2; exit 2; }
sed -e 's#/lib64/firmware#__ZL64__#g' "$W/pass1b.sh" > "$W/pass1c.sh"
[ "$(cnt '/lib64/firmware' "$W/pass1b.sh")" = "$(cnt '__ZL64__' "$W/pass1c.sh")" ] \
  || { echo "the /lib64/firmware rewrite did not cover every occurrence" >&2; exit 2; }
sed -e 's#/lib/firmware#__ZL__#g' "$W/pass1c.sh" > "$W/pass1.sh"
[ "$(cnt '/lib/firmware' "$W/pass1c.sh")" = "$(cnt '__ZL__' "$W/pass1.sh")" ] \
  || { echo "the /lib/firmware rewrite did not cover every occurrence" >&2; exit 2; }
sed -e 's#/dev/video#__ZDV__#g' "$W/pass1.sh" > "$W/pass1d.sh"
[ "$(cnt '/dev/video' "$W/pass1.sh")" = "$(cnt '__ZDV__' "$W/pass1d.sh")" ] \
  || { echo "the /dev/video rewrite did not cover every occurrence" >&2; exit 2; }
[ "$(cnt '/lib/firmware' "$W/pass1.sh")" = 0 ] || { echo "a /lib/firmware survived pass 1" >&2; exit 2; }
[ "$(cnt '/dev/video' "$W/pass1d.sh")" = 0 ] || { echo "a /dev/video survived pass 1" >&2; exit 2; }
# `2>/dev/null` must stay behind untouched: rewriting it would make every quiet redirect try to create a
# file in the fake root, and the probe would fail in a way that looks like a scenario problem.
MUSTNULL=$(cnt '2>/dev/null' "$SRC")
[ "$MUSTNULL" = "$(cnt '2>/dev/null' "$W/pass1d.sh")" ] \
  || { echo "the rewrite touched /dev/null -- the probe's quiet redirects would break" >&2; exit 2; }
sed -e "s#__ZP__#$FR/proc/#g" -e "s#__ZS__#$FR/sys/#g" -e "s#__ZL__#$FR/lib/firmware#g" \
  -e "s#__ZL64__#$FR/lib64/firmware#g" -e "s#__ZDV__#$FR/dev/video#g" "$W/pass1d.sh" > "$RW"
sh -n "$RW" || { echo "the rewritten probe does not parse" >&2; exit 2; }
chmod +x "$RW"
if grep -q -- '__Z' "$RW"; then
  echo "an unexpanded token is left in $RW:" >&2; grep -n -- '__Z' "$RW" | sed -n '1,5p' >&2; exit 2
fi
# An invariant rather than a per-path tally: every token of pass 1 becomes exactly one fake-root path in
# pass 2, and nothing else may. A per-path count cannot see a MISSED path, and one missed path means the
# probe reads THIS machine while every scenario still passes (docs 98 found exactly that).
TOK=$(cnt '__Z[A-Z0-9]*__' "$W/pass1d.sh"); FRS=$(cnt "$FR" "$RW")
[ "$TOK" -gt 0 ] || { echo "pass 1 produced no tokens -- the rewrite matched nothing" >&2; exit 2; }
[ "$TOK" = "$FRS" ] || { echo "$TOK tokens in pass 1 became $FRS fake-root paths in pass 2" >&2; exit 2; }
for tok in __ZP__ __ZS__ __ZL__ __ZL64__ __ZDV__; do
  [ "$(cnt "$tok" "$W/pass1d.sh")" -gt 0 ] || { echo "no $tok token was produced -- that rule matched nothing" >&2; exit 2; }
done
grep -qF "$FR$FR" "$RW" && { echo "a rewrite cascaded: $FR appears twice in a row" >&2; exit 2; }
grep -qF "$FR/proc/$FR" "$RW" && { echo "a rewrite cascaded into the fake root's own proc/" >&2; exit 2; }
# The paths the probe's answers hang on, named -- a rule that silently stopped applying would be invisible
# to the counts above if its occurrences moved into a comment.
for need in "$FR/proc/device-tree/model" "$FR/proc/device-tree/compatible" "$FR/proc/cmdline" \
  "$FR/proc/uptime" "$FR/sys/module/firmware_class/parameters/path" \
  "$FR/sys/bus/platform/drivers/subsys-pil-tz" "$FR/sys/bus/msm_subsys/devices" \
  "$FR/sys/bus/platform/drivers/msm_vidc_v4l2" "$FR/lib/firmware/image" "$FR/dev/video"; do
  grep -qF "$need" "$RW" || { echo "$need is not in the rewritten probe -- it would read this host, or a reading is gone" >&2; exit 2; }
done

# --- the static safety guard, and its teeth --------------------------------------------------------
#
# What counts as a write: a redirect into /sys, /proc or /dev; and dd/tee/setprop/modprobe/insmod/rmmod/
# mount/umount/mkfs **in command position**, where command position means the first word of a statement --
# the start of a line, or just after `;`, `&&`, `||`, `|`, `(`, `then`, `do` or `else`. Requiring a
# statement boundary and not just "after a space" is what keeps the probe's own prose ("making the core
# come up is a separate step") from being read as code.
#
# Two exemptions, each of which is itself asserted: `>/dev/null` is not a write to the device's filesystem
# (this port's shell is /bin/sh, where `2>/dev/null` is the only way to be quiet), and a HEREDOC BODY IS
# TEXT -- the probe's `--explain` page describes opening a session in a sentence, and blanking the bodies
# first keeps that prose from being read as code while keeping the line count, so a real hit still reports
# its own line number.
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
# The teeth, and the first one is the write this probe is most plausibly tempted into: "just open a session
# and the firmware will load" -- i.e. poking the writable thermal_level knob, or the SSR restart level.
printf '%s\n' '# a fixture for the redirect rule: the session this probe deliberately does not start' \
  'printf 1 > /sys/bus/platform/drivers/msm_vidc_v4l2/c00000.qcom,vidc/thermal_level' > "$W/teeth-knob.sh"
printf '%s\n' '# a fixture for the command-position rule' \
  'insmod /tmp/msm_vidc.ko' > "$W/teeth-cmd.sh"
printf '%s\n' '# prose that must not be read as code' \
  "cat <<'EOF'" \
  'making the core come up is a WRITE -- opening a session, or writing thermal_level -- and this probe does neither' \
  'EOF' \
  'say "the arrow -> /sys/class/video4linux is how this page writes a path"' > "$W/teeth-prose.sh"
want 'thermal_level' "$(write_sites "$W/teeth-knob.sh")" \
  "the guard catches a redirect into the vidc thermal_level knob (the session test, as a fixture)"
want 'msm_vidc\.ko' "$(write_sites "$W/teeth-cmd.sh")" "and catches a state-changing command in command position"
notwant '.' "$(write_sites "$W/teeth-prose.sh")" \
  "and does not punish prose that names an arrow before a /sys path, or a heredoc about opening a session"
want 'opening a session, or writing thermal_level' "$(grep -aE -- 'opening a session, or writing thermal_level' "$W/teeth-prose.sh")" \
  "while the heredoc that says so is present in the fixture (so the exemption is doing work, not hiding a miss)"
printf 'x=$(dmesg 2>/dev/null)\n' > "$W/teeth-null.sh"
want '/dev/null' "$(grep -aE -- "$WRITE_RE" "$W/teeth-null.sh")" \
  "and without the /dev/null strip, the probe's own quiet-redirects WOULD be flagged"
notwant '.' "$(write_sites "$W/teeth-null.sh")" "while with the strip they are not"

# --- the fake device -------------------------------------------------------------------------------
#
# `scen` builds the whole fake root from nothing, so a scenario can never inherit the previous one's
# leftovers -- the trap docs 128 section 9c records. Every file it does not create is ABSENT, which is the
# point: the probe must reach its verdict from what is there, not from what a copy left behind.
#
# Device-tree properties are BYTES: a string list is NUL-terminated, and a u32 is four big-endian bytes.
dtp() { mkdir -p "$(dirname "$1")"; printf '%s\0' "$2" > "$1"; }
dtu32p() { mkdir -p "$(dirname "$1")"; printf "$2" > "$1"; }

# The two boards' root properties, exactly as the flashed blob carries them: IDENTICAL `compatible`, and a
# `model` that is the only thing telling them apart.
MODEL_ZL1='Letv Technologies, Inc. MSM 8996pro + PMI8996 LE_ZL1-DVT1'
MODEL_X2='Letv Technologies, Inc. MSM 8996 v3 + PMI8996 LE_X2-PVT'

# The vidc node's real properties, from a ZL1 DTB: status `ok`, hfi venus 3xx, imem 0x00080000 = 524288,
# max-secure-instances 5, max-hw-load 2563200 = 0x00271fc0, and the two empty boolean properties.
vidc_node() { # $1 = node dir, $2 = status
  dtp "$1/compatible" 'qcom,msm-vidc'
  dtp "$1/status" "$2"
  dtp "$1/qcom,hfi" 'venus'
  dtp "$1/qcom,hfi-version" '3xx'
  dtp "$1/qcom,firmware-name" 'venus'
  dtu32p "$1/qcom,imem-size" '\000\010\000\000'
  dtu32p "$1/qcom,max-secure-instances" '\000\000\000\005'
  dtu32p "$1/qcom,max-hw-load" '\000\047\037\300'
  : > "$1/qcom,never-unload-fw"
  : > "$1/qcom,sw-power-collapse"
}
# The venus PIL node: no `status` property at all (an absent status means ENABLED), pas-id 9, proxy timeout
# 100 ms, and the clocks/regulators the loader's proxy votes on.
pil_node() { # $1 = node dir, $2 = firmware name
  dtp "$1/compatible" 'qcom,pil-tz-generic'
  dtp "$1/qcom,firmware-name" "$2"
  dtu32p "$1/qcom,pas-id" '\000\000\000\011'
  dtu32p "$1/qcom,proxy-timeout-ms" '\000\000\000\144'
  dtp "$1/qcom,proxy-reg-names" 'vdd'
  dtp "$1/qcom,proxy-clock-names" 'core_clk'
  printf 'core_clk\0' > "$1/clock-names"
}

scen() {
  SCEN="$1"
  rm -rf "$FR"
  mkdir -p "$FR/proc/sys/kernel/random" "$FR/proc/device-tree/soc" "$FR/sys/bus/platform/drivers" \
    "$FR/sys/bus/msm_subsys/devices" "$FR/sys/class/video4linux" "$FR/dev" \
    "$FR/sys/module/firmware_class/parameters" "$FR/vendor/firmware_mnt/image" "$FR/lib/firmware"

  printf '%s\0' "$MODEL_ZL1" > "$FR/proc/device-tree/model"
  printf 'qcom,msm8996-mtp\0qcom,msm8996\0qcom,mtp\0' > "$FR/proc/device-tree/compatible"
  printf '11111111-2222-3333-4444-555555555555\n' > "$FR/proc/sys/kernel/random/boot_id"
  printf '1234.56 5678.90\n' > "$FR/proc/uptime"
  printf 'Linux version 3.18.140 (build) #1 SMP\n' > "$FR/proc/version"
  # The flashed cmdline's own token, and the live parameter: normally the same path, and the fixture makes
  # them the fake root's, so neither can reach this laptop.
  printf 'console=tty0 firmware_class.path=%s/vendor/firmware_mnt/image androidboot.serialno=33e80afe\n' "$FR" \
    > "$FR/proc/cmdline"
  printf '%s\n' "$FR/vendor/firmware_mnt/image" > "$FR/sys/module/firmware_class/parameters/path"
  printf '/dev/sda10 /etc ext4 rw 0 0\n' > "$FR/proc/mounts"

  V="$FR/proc/device-tree/soc/qcom,vidc@c00000"
  P="$FR/proc/device-tree/soc/qcom,venus@ce0000"
  case "$SCEN" in
  unknown-model) printf 'Letv Technologies, Inc. LE_UNKNOWN-XYZ\0' > "$FR/proc/device-tree/model" ;;
  no-model) rm -f "$FR/proc/device-tree/model" ;;
  x2-tree) printf '%s\0' "$MODEL_X2" > "$FR/proc/device-tree/model" ;;
  esac
  # The three siblings the SAME driver serves: the control group. `qcom,mss@2080000` is the modem and
  # carries a DIFFERENT compatible (`qcom,pil-q6v55-mss`), so it must not appear in the pil-tz list -- the
  # fixture would be lying about the tree if it did. `no-pil-node` is the scenario where the tree declares
  # the video core and NO pil-tz node at all, which is a rung of its own.
  if [ "$SCEN" != no-pil-node ] && [ "$SCEN" != bare-tree ]; then
    pil_node "$FR/proc/device-tree/soc/qcom,kgsl-hyp" 'a530_zap'
    pil_node "$FR/proc/device-tree/soc/qcom,lpass@9300000" 'adsp'
    pil_node "$FR/proc/device-tree/soc/qcom,ssc@1c00000" 'slpi'
  fi
  if [ "$SCEN" != bare-tree ]; then
    dtp "$FR/proc/device-tree/soc/qcom,mss@2080000/compatible" 'qcom,pil-q6v55-mss'
    dtp "$FR/proc/device-tree/soc/qcom,mss@2080000/qcom,firmware-name" 'modem'
  fi
  case "$SCEN" in
  no-dt-node | bare-tree) : ;;
  no-pil-node) vidc_node "$V" ok ;;
  node-disabled) vidc_node "$V" disabled; pil_node "$P" 'venus' ;;
  *) vidc_node "$V" ok; pil_node "$P" 'venus' ;;
  esac

  # The loader. Four bound devices, the video core among them -- the bound list is the reading, not the
  # directory.
  D="$FR/sys/bus/platform/drivers/subsys-pil-tz"
  case "$SCEN" in
  no-driver-dir) : ;;
  pil-not-bound) mkdir -p "$D"; touch "$D/bind" "$D/unbind" "$D/uevent" ;;
  # `no-pil-node`: the tree has no pil-tz node, so (faithfully) there is no platform device either -- and
  # no subsystem entry, since the entry is created by the device's probe. The rung is asked before those
  # two, which is what makes it a diagnosis rather than an effect.
  no-pil-node) mkdir -p "$D"; touch "$D/bind" "$D/unbind" "$D/uevent" ;;
  *)
    mkdir -p "$D/c00000.qcom,vidc" "$D/ce0000.qcom,venus" "$D/9300000.qcom,lpass" "$D/1c00000.qcom,ssc"
    touch "$D/bind" "$D/unbind" "$D/uevent"
    ;;
  esac

  # The subsystem bus: the firmware's own state, and the control group. venus is OFFLINE in every scenario
  # that has not asked it to load, which is the healthy idle state this probe must not call a fault.
  SUBS="$FR/sys/bus/msm_subsys/devices"
  mkdir -p "$SUBS"
  subs_entry() { # $1 = name, $2 = state, $3 = crash_count, $4 = error text
    mkdir -p "$SUBS/$1"
    printf '%s\n' "$2" > "$SUBS/$1/state"
    printf '%s\n' "$3" > "$SUBS/$1/crash_count"
    printf '%s\n' "$4" > "$SUBS/$1/error"
    printf '%s\n' "$1" > "$SUBS/$1/firmware_name"
    printf 'SYSTEM\n' > "$SUBS/$1/restart_level"
  }
  case "$SCEN" in
  # The tree declares no pil-tz node at all: no loader device, no subsystem entry -- only the modem's
  # (whose node is a different driver's and is still in the tree).
  no-pil-node) subs_entry modem OFFLINE 0 '' ;;
  # `bare-tree`: no known node shape anywhere, which is the only fixture state in which a probe with no
  # find(1) must say "I could not look" instead of "there is no node". Every other scenario has at least
  # one known shape (the modem), so a real search DID happen there and "not found" is the honest reading.
  bare-tree) : ;;
  no-subsys-entry) subs_entry adsp ONLINE 0 ''; subs_entry modem OFFLINE 0 '' ;;
  *)
    case "$SCEN" in
    load-failed) subs_entry venus OFFLINE 3 ''; subs_entry adsp ONLINE 0 '' ;;
    load-failed-error) subs_entry venus OFFLINE 0 'Failed to download firmware'; subs_entry adsp ONLINE 0 '' ;;
    online | online-no-dev | one-video-node) subs_entry venus ONLINE 0 ''; subs_entry adsp ONLINE 0 '' ;;
    *) subs_entry venus OFFLINE 0 ''; subs_entry adsp ONLINE 0 '' ;;
    esac
    subs_entry slpi OFFLINE 0 ''
    subs_entry a530_zap OFFLINE 0 ''
    subs_entry modem OFFLINE 0 ''
    # `extra-subsys`: a subsystem this probe has no name for. The table must print what the bus holds, not
    # what the probe expects -- a hard-coded list of five names would hide a sixth.
    if [ "$SCEN" = extra-subsys ]; then subs_entry wcnss OFFLINE 0 ''; fi
    ;;
  esac

  # The v4l2 half: the platform driver, its bound device, its four attributes, and the two video nodes.
  #
  # The video nodes exist on a HEALTHY boot with the firmware still idle, because msm_vidc_probe_vidc_device
  # registers them from the platform probe -- it does not wait for the firmware. That is the fixture being
  # faithful, and it is also why the `idle` scenario is not a picture of a broken boot.
  VD="$FR/sys/bus/platform/drivers/msm_vidc_v4l2"
  case "$SCEN" in no-dt-node | node-disabled) : ;; *)
    mkdir -p "$VD/c00000.qcom,vidc"
    printf '2.0\n' > "$VD/c00000.qcom,vidc/platform_version"
    printf '1.0\n' > "$VD/c00000.qcom,vidc/capability_version"
    printf '1500\n' > "$VD/c00000.qcom,vidc/pwr_collapse_delay"
    printf '0\n' > "$VD/c00000.qcom,vidc/thermal_level"
    touch "$VD/bind" "$VD/unbind"
    # Which of the two nodes registered: both on a healthy probe, one in `one-video-node`, none in
    # `online-no-dev` (the firmware is up and the client-facing half is not).
    case "$SCEN" in
    online-no-dev) : ;;
    one-video-node)
      touch "$FR/dev/video32"
      mkdir -p "$FR/sys/class/video4linux/video32"
      printf 'msm_vidc_dec\n' > "$FR/sys/class/video4linux/video32/name"
      ;;
    *)
      touch "$FR/dev/video32" "$FR/dev/video33"
      mkdir -p "$FR/sys/class/video4linux/video32" "$FR/sys/class/video4linux/video33"
      printf 'msm_vidc_dec\n' > "$FR/sys/class/video4linux/video32/name"
      printf 'msm_vidc_enc\n' > "$FR/sys/class/video4linux/video33/name"
      ;;
    esac
    ;;
  esac
  # The firmware file: `<name>.mdt` plus its segments. The `firmware-unreachable` scenario is the one that
  # has none -- in the parameter's path and in every built-in one, which is why the rewrite had to cover
  # /lib/firmware too.
  if [ "$SCEN" != firmware-unreachable ]; then
    : > "$FR/vendor/firmware_mnt/image/venus.mdt"
    for i in 0 1 2 3 4; do printf 'seg%s' "$i" > "$FR/vendor/firmware_mnt/image/venus.b0$i"; done
  fi
  # `segments-missing`: the .mdt is there and the segments are not, which the loader needs too.
  if [ "$SCEN" = segments-missing ]; then rm -f "$FR/vendor/firmware_mnt/image/venus.b0"*; fi

  # The kernel log. `unreadable` makes BOTH readers fail -- the only honest way to reach "not read".
  LOGMODE=normal
  case "$SCEN" in log-unreadable) LOGMODE=unreadable ;; esac
  : > "$W/kernel.log"
  case "$SCEN" in
  online | online-no-dev | load-failed | load-failed-error)
    { printf '[    0.000000] Booting Linux on physical CPU 0x0\n'
      printf '[    1.100000] subsys-pil-tz ce0000.qcom,venus: Fatal error on venus!\n'
      printf '[    1.100100] msm_vidc: Failed to download firmware\n'
      printf '[   30.000000] random: crng init done\n'; } > "$W/kernel.log"
    ;;
  log-loading)
    { printf '[    0.000000] Booting Linux on physical CPU 0x0\n'
      printf '[    1.100000] subsys-pil-tz 9300000.qcom,lpass: adsp is now ONLINE\n'
      printf '[   30.000000] random: crng init done\n'; } > "$W/kernel.log"
    ;;
  log-quiet)
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
  export LOGMODE LOGFILE="$W/kernel.log"

  # The container, whose mount namespace the probe reads for the firmware's path -- because the loader
  # resolves it in the CALLER's. `container-up` is the only scenario where it answers.
  cat > "$STUB/lxc-info" <<'STUBEOF'
#!/bin/sh
[ -n "${CONTAINER_PID:-}" ] || exit 1
printf '%s\n' "$CONTAINER_PID"
STUBEOF
  cat > "$STUB/nsenter" <<'STUBEOF'
#!/bin/sh
# nsenter -t PID -m -- ls -d PATH  ->  print PATH when the fake device has it
p=""
for a in "$@"; do case "$a" in /*) p="$a" ;; esac; done
[ -n "$p" ] && [ -e "$p" ] && { printf '%s\n' "$p"; exit 0; }
exit 1
STUBEOF
  chmod +x "$STUB/lxc-info" "$STUB/nsenter"
  if [ "$SCEN" = container-up ]; then export CONTAINER_PID=4242; else unset CONTAINER_PID; fi
}

# `run` executes the rewritten probe as the fake device sees it. PATH is the sandbox FIRST, so a tool the
# probe needs and the sandbox lacks fails loudly instead of silently reaching this laptop's copy -- the
# last run against a sandbox without a `journalctl` stub printed the HOST's kernel log through this hole.
run() { ( cd "$W" && PATH="$STUB:$MINBIN" "$SH_BIN" "$RW" "$@" ) 2>&1; }
# The same, on a device that has no find(1): the only way to reach "the tree could not be searched".
run_nofind() { ( cd "$W" && PATH="$STUB:$MINBIN_NOFIND" "$SH_BIN" "$RW" "$@" ) 2>&1; }
# The same again, for a MUTATED copy of the subject: rewritten the same way, run against the scenario that
# was built last. $3 = nofind to run it on the sandbox without find(1).
mut_run() { # $1 = mutated source, $3 = nofind
  rewrite "$1" "$W/mutated.sh"
  sh -n "$W/mutated.sh" || { printf 'MUTATED SUBJECT DOES NOT PARSE\n'; return; }
  if [ "${3:-}" = nofind ]; then
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
want '^# zl1 video-core probe' "$OUT" "--help prints the probe's own header"
want 'a separate, reviewed step' "$(run --explain)" "--explain says bringing the core up is a write and a separate step"
want 'nothing loads this firmware until a client opens' "$(run --explain)" \
  "and names the state a naive reading would call a fault"
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
want '== verdict: no-device-tree-node' "$OUT" "a tree with no qcom,msm-vidc node says so"
want 'no node in this device tree carries compatible qcom,msm-vidc' "$OUT" "naming what is missing"
want 'the whole tree is' "$OUT" "with the scan named, so the reading does not rest on a guessed path"
[ "$RC" = 1 ] && ok "and exits 1" || bad "the no-node verdict exited $RC, not 1"

scen node-disabled
OUT=$(run); RC=$?
want '== verdict: node-disabled' "$OUT" "a declared node with status != ok is its own rung"
want 'its status is .disabled.' "$OUT" "quoting the status it read"
want 'no driver will probe this node' "$OUT" "and saying what that costs: no driver and no client node"
[ "$RC" = 1 ] && ok "and exits 1" || bad "node-disabled exited $RC, not 1"

scen no-pil-node
OUT=$(run); RC=$?
want '== verdict: no-firmware-node' "$OUT" "a vidc node whose firmware node is missing is its own rung"
want "pil node: +NONE carries qcom,firmware-name = venus" "$OUT" "naming the compatible and the name it searched for"
want 'device tree node is the CAUSE here' "$OUT" "and saying why this rung is asked before the loader's own"
[ "$RC" = 1 ] && ok "and exits 1" || bad "no-pil-node exited $RC, not 1"

scen no-driver-dir
OUT=$(run); RC=$?
want '== verdict: pil-not-bound' "$OUT" "a loader that never registered is its own rung"
want 'MISSING -- the driver did not register at all' "$OUT" "with the directory's absence stated, which is not the same as empty"
want 'CONFIG_MSM_PIL=y' "$OUT" "and the defconfig cited, so 'missing' is not read as 'not built in'"
[ "$RC" = 1 ] && ok "and exits 1" || bad "no-driver-dir exited $RC, not 1"

scen pil-not-bound
OUT=$(run); RC=$?
want '== verdict: pil-not-bound' "$OUT" "a loader directory with nothing attached reaches the same rung"
want 'bound devices: NONE .the driver registered, nothing was probed.' "$OUT" \
  "printed as NONE rather than as a blank"
[ "$RC" = 1 ] && ok "and exits 1" || bad "pil-not-bound exited $RC, not 1"

scen no-subsys-entry
OUT=$(run); RC=$?
want '== verdict: no-subsys-entry' "$OUT" "a bound device with no subsystem entry is its own rung"
want 'registered no subsystem under the name .venus.' "$OUT" "and the verdict names the missing entry"
want "from the device tree's qcom,firmware-name" "$OUT" "with the source of that name, since a tree/loader mismatch shows up here"
[ "$RC" = 1 ] && ok "and exits 1" || bad "no-subsys-entry exited $RC, not 1"

scen firmware-unreachable
OUT=$(run); RC=$?
want '== verdict: firmware-unreachable' "$OUT" "no candidate path holding the .mdt is its own rung"
want 'NO candidate path holds venus.mdt' "$OUT" "and the absence is printed against every candidate"
want 'a MOUNT/path problem, not a hardware one' "$OUT" "with the verdict saying which kind of problem it is"
[ "$RC" = 1 ] && ok "and exits 1" || bad "firmware-unreachable exited $RC, not 1"

scen load-failed
OUT=$(run); RC=$?
want '== verdict: load-failed' "$OUT" "a crash count that is a non-zero number is evidence somebody tried"
want 'crash_count=3' "$OUT" "with the count quoted"
want "not 'nobody asked'" "$OUT" "and the verdict separating it from the idle state"
[ "$RC" = 1 ] && ok "and exits 1" || bad "load-failed exited $RC, not 1"

scen load-failed-error
OUT=$(run)
want '== verdict: load-failed' "$OUT" "an error buffer with text in it is the other half of that evidence"
want 'Failed to download firmware' "$OUT" "with the buffer quoted"

scen idle
OUT=$(run); RC=$?
want '== verdict: firmware-not-loaded' "$OUT" "everything in place and nobody asking is its own rung, not a fault"
want 'NO CLIENT HAS ASKED YET' "$OUT" "in those words"
want '__load_fw.., which runs when something opens a video instance' "$OUT" "with the call site named, so the reader can check it"
want 'It is NOT a fault, and it is not evidence that video works either' "$OUT" "and both halves of that sentence"
[ "$RC" = 1 ] && ok "and exits 1 (a rung is not a healthy verdict)" || bad "the idle verdict exited $RC, not 1"

scen online
OUT=$(run); RC=$?
want '== verdict: online' "$OUT" "an ONLINE subsystem with both video nodes is the healthy rung"
want 'both V4L2 devices are registered' "$OUT" "and says why: both devices, not just the firmware"
[ "$RC" = 0 ] && ok "and exits 0" || bad "the healthy verdict exited $RC, not 0"

scen online-no-dev
OUT=$(run); RC=$?
want '== verdict: no-video-device' "$OUT" "a firmware that is up with no client-facing node is its own rung"
want 'found 0 of 2' "$OUT" "with the count of the nodes it found"
[ "$RC" = 1 ] && ok "and exits 1" || bad "online-no-dev exited $RC, not 1"

scen one-video-node
OUT=$(run)
want '== verdict: no-video-device' "$OUT" "ONE of the two nodes is the same rung, not a pass"
want 'found 1 of 2' "$OUT" "and the count is a number, so 'one is enough' cannot read as a pass"

# ==================================================================================================
echo "== 4. a node that could not be SEARCHED is not a node that is absent =="
# ==================================================================================================
scen bare-tree
OUT=$(run_nofind); RC=$?
want '== verdict: tree-unscanned' "$OUT" "with no find(1) and no known node shape, the probe says it could not look"
want 'could not be searched for a compatible at all' "$OUT" "in those words"
want "NOT .the tree has no such node." "$OUT" "and says explicitly that this is not an absence"
notwant 'no-device-tree-node' "$OUT" "so it never reports the absence rung it cannot support"
[ "$RC" = 1 ] && ok "and exits 1" || bad "tree-unscanned exited $RC, not 1"
# The other side of that distinction: the same sandbox WITH one known node shape (the modem) and no video
# node is a real search that found nothing -- so it must report the absence, not the inability.
scen no-dt-node
OUT=$(run_nofind)
want '== verdict: no-device-tree-node' "$OUT" \
  "a sandbox with no find(1) but one known node shape is a search that HAPPENED and found nothing"
notwant 'tree-unscanned' "$OUT" "so it must not claim it could not look"
scen idle
OUT=$(run_nofind); RC=$?
want '== verdict: firmware-not-loaded' "$OUT" \
  "while the same probe WITH the nodes present but no find(1) still finds them through the fallback globs"
want 'vidc node: +/soc/qcom,vidc@c00000' "$OUT" "and prints the node it found"
want 'pil node: +/soc/qcom,venus@ce0000' "$OUT" "and the firmware node, which is a different node"
notwant 'NONE carries qcom,firmware-name' "$OUT" \
  "and the SECOND scan found its node too -- a scan whose found-flag leaked from the first would return 0 with no output"
[ "$RC" = 1 ] && ok "and exits 1 (this rung is about the firmware, not the search)" || bad "the no-find-but-nodes-present scenario exited $RC, not 1"

# ==================================================================================================
echo "== 5. a device-tree u32 is BIG-ENDIAN, and a wrong length is not a number =="
# ==================================================================================================
scen idle
OUT=$(run)
want 'pas-id: +9' "$OUT" "a 4-byte big-endian property is read as its value, not byte-swapped"
want 'proxy-timeout-ms: +100' "$OUT" "and so is a second one"
want 'imem-size: +524288 bytes' "$OUT" "and a third, with its unit named"
notwant '150994944' "$OUT" "with the byte-swapped form of pas-id 9 nowhere in the report"
# The failure mode of a length change is a plausible number, so the fixture makes the property 3 bytes and
# the probe must say so instead of reading three bytes as if they were four.
scen idle
printf '\000\000\011' > "$FR/proc/device-tree/soc/qcom,venus@ce0000/qcom,pas-id"
OUT=$(run)
want 'pas-id: +not-a-u32.3 bytes.' "$OUT" "a property that is not four bytes says so rather than printing a number"
notwant 'pas-id: +[0-9]' "$OUT" "and prints no number at all for it"

# ==================================================================================================
echo "== 6. the firmware search: two readings, one path, and both namespaces =="
# ==================================================================================================
scen idle
OUT=$(run)
want "cmdline's firmware_class.path: +$FR/vendor/firmware_mnt/image" "$OUT" \
  "the cmdline's own token is read, which is what the flashed image asked for"
want 'the live parameter .what the kernel accepted.: +' "$OUT" "and the live parameter separately, because it can be changed at runtime"
count_is "$OUT" 'HIT .*venus\.mdt' 1 "the same path in both readings prints ONE hit line, not two"
want 'segments: b00 b01 b02 b03 b04' "$OUT" "and the segments the loader needs beside it are listed"
scen segments-missing
OUT=$(run); RC=$?
want '== verdict: firmware-incomplete' "$OUT" "an .mdt with no segments is a fault of its own, not an idle core"
want 'segments: NONE' "$OUT" "the .mdt is reported with an empty segment list, named rather than blank"
want 'Failed to locate blob' "$OUT" "and the verdict quotes the loader's own string for that failure"
[ "$RC" = 1 ] && ok "and exits 1" || bad "segments-missing exited $RC, not 1"

scen idle
OUT=$(run)
want 'the android container is not running' "$OUT" "a container that is not running is named, not left blank"
want 'NOT the same as the path being absent there' "$OUT" "and the distinction is stated rather than implied"
scen container-up
OUT=$(run)
want "the container's mount namespace .android pid 4242." "$OUT" "when the container IS up, its namespace is read too"
count_is "$OUT" 'HIT   .*venus\.mdt' 2 "and the same path is then a hit in BOTH namespaces"

# ==================================================================================================
echo "== 7. the control group, and the state that is not a fault =="
# ==================================================================================================
scen idle
OUT=$(run)
want 'SUBSYSTEM +STATE +CRASHES' "$OUT" "the subsystem table is printed with its own vocabulary"
want 'adsp +ONLINE' "$OUT" "including a subsystem that IS online, which is the control group's whole point"
want 'venus +OFFLINE' "$OUT" "and venus, offline and idle"
want 'error: +\(empty: nothing ever recorded a failure' "$OUT" \
  "an empty error buffer is printed WITH its emptiness named, not as a blank"
want 'the siblings the loader serves' "$OUT" "and the nodes sharing this driver are listed"
want 'a530_zap=/soc/qcom,kgsl-hyp' "$OUT" "by the FIRMWARE NAME the tree gives them and by path"
notwant 'modem=/soc/qcom,mss@2080000' "$OUT" \
  "while the modem -- a DIFFERENT compatible -- is not in that list (the fixture would be lying about the tree if it were)"
scen extra-subsys
OUT=$(run)
want 'entries:.*wcnss' "$OUT" "a bus carrying a subsystem this probe has no name for still lists it"
count_is "$OUT" '^   (venus|adsp|slpi|a530_zap|modem|wcnss) ' 6 \
  "and the table has one row per subsystem on the bus, not one per hard-coded name"

# ==================================================================================================
echo "== 8. the v4l2 half, and an unreadable log =="
# ==================================================================================================
scen idle
OUT=$(run)
want 'msm_vidc_v4l2: present' "$OUT" "the V4L2 half of the driver is read through its platform driver"
want 'bound devices: c00000.qcom,vidc' "$OUT" "and its bound device is printed"
want 'platform_version +2.0' "$OUT" "with the efuse-derived attributes (a READING, in the right shape if it were wrong)"
want 'thermal_level +0' "$OUT" "and the writable thermal knob's value, which this probe does not touch"
want 'video4linux class entry' "$OUT" "and every video4linux node on the boot, by name"
want 'video32=msm_vidc_dec' "$OUT" "including the decoder's own name"
want '32 is BASE_DEVICE_NUMBER' "$OUT" "with the constant that makes /dev/video32 the decoder, cited"
scen online
OUT=$(run)
want 'video33: present' "$OUT" "a present encoder node is reported as present"

scen log-quiet
OUT=$(run)
want 'the kernel log mentions neither venus nor vidc this boot' "$OUT" "a readable log with no venus lines prints its named (none: ...) line"
want 'no venus firmware or secure-world failure' "$OUT" "and the failure block prints its own named (none: ...) line"
scen log-loading
OUT=$(run)
want 'adsp is now ONLINE' "$OUT" "a loader line about a SIBLING is surfaced, because the siblings are the control group"
scen load-failed
OUT=$(run)
want 'Fatal error on venus' "$OUT" "and a failure line this probe's own filters name is surfaced"
want 'Failed to download firmware' "$OUT" "including the driver's own string for a firmware that did not arrive"
scen log-unreadable
OUT=$(run); RC=$?
want 'the kernel log could not be read' "$OUT" "an unreadable kernel log says so"
want 'so this section is NOT READ' "$OUT" "and is named as not read rather than printed empty"
want '== verdict: firmware-not-loaded' "$OUT" "with the verdict unchanged -- no rung here comes from the log"
[ "$RC" = 1 ] && ok "and its exit code is the rung's, not the log's" || bad "the unreadable-log scenario exited $RC, not 1"

# ==================================================================================================
echo "== 9. --quiet, and the exit-code contract =="
# ==================================================================================================
scen online
Q=$(run --quiet); F=$(run)
want '== verdict: online' "$Q" "--quiet still prints the verdict (a verdict is not a reading)"
want 'boot id:' "$Q" "--quiet still prints which boot this is (a verdict with no boot identity is not attributable)"
want 'model:' "$Q" "--quiet still prints which board's tree this is (the first rung survives --quiet)"
want 'state: +ONLINE' "$Q" "--quiet keeps the subsystem state the verdict rests on"
want 'venus.mdt' "$Q" "and the firmware path the verdict rests on"
notwant 'compatible:' "$Q" "--quiet drops the device-tree detail"
want 'compatible:' "$F" "and the full run has it"
notwant 'video4linux class entry' "$Q" "--quiet drops the per-node listing"
want 'video4linux class entry' "$F" "which the full run keeps"
OUT=$(run --bogus); RC=$?
want 'unknown argument' "$OUT" "an unknown argument is refused by name"
[ "$RC" = 2 ] && ok "and exits 2, so a typo cannot be read as a reading" || bad "an unknown argument exited $RC, not 2"

# ==================================================================================================
echo "== 10. the shipped probe is still write-free, and the mutation proves the guard has teeth =="
# ==================================================================================================
notwant '>[[:space:]]*/tmp/' "$(cat "$SRC")" "the shipped probe writes no scratch file in /tmp either"
notwant '\bmktemp\b' "$(cat "$SRC")" "and creates no temporary file at all"
want 'LOG_TEXT=\$\(dmesg' "$(cat "$SRC")" "the kernel log is captured into a variable (the write-free way to read it twice)"
want 'lxc-info -n android -pH' "$(cat "$SRC")" "and the container's namespace is read with ls, not with a mount"
# The mutation: the session test, which is precisely the write a probe about a codec would be tempted into
# -- poke the writable thermal knob and see whether the core comes up. It edits the attribute-printing line
# and keeps the `if`/`else` shape, so the mutated probe still parses.
sed 's#^    if \[ -e "\$d/\$a" \]; then say#    if [ -e "$d/$a" ]; then printf 1 > /sys/bus/platform/drivers/msm_vidc_v4l2/c00000.qcom,vidc/thermal_level; say#' \
  "$SRC" > "$W/mut-write.sh"
if cmp -s "$SRC" "$W/mut-write.sh"; then
  bad "the mutation did not apply -- the seed line it edits is gone, so this check would test nothing"
else
  ok "the mutation applied to the shipped source"
  want 'thermal_level' "$(write_sites "$W/mut-write.sh")" \
    "and a mutation that pokes the writable thermal knob is caught by the guard"
fi

# ==================================================================================================
echo "== 11. the mutations that are readings, not writes =="
# ==================================================================================================
# Each of these is a way the probe could still LOOK right, and each must redden a check: a mutation that
# reddens nothing means the scenario it edits is not being tested. The scenario is rebuilt before the
# mutated subject runs, so the two subjects see the same device.
# 1. The board guard: test the root `compatible` -- which BOTH trees carry -- instead of `model`. This is
#    not hypothetical: it is the guard this project's ~25 sibling probes use today.
sed -e 's#^case "\$MODEL" in#case "$MODEL$COMPAT" in#' \
  -e 's#^\*LE_ZL1\*) BOARD=zl1 ;;#*LE_ZL1*|*qcom,msm8996*) BOARD=zl1 ;;#' "$SRC" > "$W/mut-board.sh"
if cmp -s "$SRC" "$W/mut-board.sh"; then bad "the board mutation did not apply"; else
  scen x2-tree
  OUT=$(mut_run "$W/mut-board.sh")
  notwant '== verdict: wrong-board-tree' "$OUT" \
    "a guard that tests msm8996 instead of model stops seeing the other board's tree (the mutation)"
  want '== verdict: firmware-not-loaded' "$OUT" "and lands on a hardware rung instead, which is the whole failure mode"
fi
# 2. The status check dropped: a node the kernel will not probe would report as a driver or firmware problem.
sed 's#^elif \[ "\$VIDC_ST" != okay \] && \[ "\$VIDC_ST" != ok \] && \[ "\$VIDC_ST" != EMPTY \] && \[ "\$VIDC_ST" != absent \]; then#elif false; then#' \
  "$SRC" > "$W/mut-status.sh"
if cmp -s "$SRC" "$W/mut-status.sh"; then bad "the status mutation did not apply"; else
  scen node-disabled
  OUT=$(mut_run "$W/mut-status.sh")
  notwant '== verdict: node-disabled' "$OUT" "dropping the status check stops the disabled node being a rung (the mutation)"
fi
# 3. An empty `bound devices` read as fine: a loader directory with nothing attached would pass.
sed 's#^elif \[ -z "\$DRV_BOUND" \]; then#elif false; then#' "$SRC" > "$W/mut-bound.sh"
if cmp -s "$SRC" "$W/mut-bound.sh"; then bad "the bound-device mutation did not apply"; else
  scen pil-not-bound
  OUT=$(mut_run "$W/mut-bound.sh")
  notwant '== verdict: pil-not-bound' "$OUT" \
    "treating an unattached loader as fine stops the rung that says nothing was probed (the mutation)"
fi
# 4. "Could not search" collapsed into "not found": the state that must never print like an absence.
sed 's#^  \[ "\$_nc_any" = 1 \] && return 1#  return 1#' "$SRC" > "$W/mut-scan.sh"
if cmp -s "$SRC" "$W/mut-scan.sh"; then bad "the scan mutation did not apply"; else
  scen no-dt-node
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
  notwant 'pas-id: +9' "$OUT" "combining the four bytes in the host's order loses the real value (the mutation)"
  want 'pas-id: +150994944' "$OUT" "and prints a number of the right SHAPE and the wrong value"
fi
# 6. The "nobody asked" state folded into a failure. This is THIS probe's central reading: for every other
#    PIL subsystem, offline is a fault; for venus it is the boot's normal shape.
sed 's#^LOAD_EVIDENCE=no#LOAD_EVIDENCE=yes#' "$SRC" > "$W/mut-idle.sh"
if cmp -s "$SRC" "$W/mut-idle.sh"; then bad "the idle mutation did not apply"; else
  scen idle
  OUT=$(mut_run "$W/mut-idle.sh")
  notwant '== verdict: firmware-not-loaded' "$OUT" \
    "calling an idle-but-ready firmware a failure stops the rung that says nobody asked (the mutation)"
  want '== verdict: load-failed' "$OUT" "and reports a fault on a boot where nothing failed"
fi
# 7. The control group silenced: venus's own line would look the same, and the reading that separates "venus
#    is offline" from "the whole boot's firmware is offline" would be gone.
sed 's#^say "     \$(san "\$PIL_LIST")"#: "     silenced"#' "$SRC" > "$W/mut-group.sh"
if cmp -s "$SRC" "$W/mut-group.sh"; then bad "the control-group mutation did not apply"; else
  scen idle
  OUT=$(mut_run "$W/mut-group.sh")
  notwant 'a530_zap=/soc/qcom,kgsl-hyp' "$OUT" \
    "silencing the sibling list removes the control group that makes venus's own state readable (the mutation)"
  want '== verdict: firmware-not-loaded' "$OUT" "while venus's own reading still stands"
fi
# 8. The firmware search list emptied: the "unreachable" rung would be decided by a path the probe never
#    checked. The seed is the built-in list itself.
sed 's#^CAND="/lib/firmware/updates/\$RELP .*#CAND=""#' "$SRC" > "$W/mut-cand.sh"
if cmp -s "$SRC" "$W/mut-cand.sh"; then bad "the candidate-list mutation did not apply"; else
  scen idle
  OUT=$(mut_run "$W/mut-cand.sh")
  notwant 'lib/firmware/image' "$OUT" "emptying the built-in search list removes the paths it would have checked (the mutation)"
fi

# ==================================================================================================
echo "== 12. this harness's own citation =="
# ==================================================================================================
# A count typed by hand in the first thing a human reads goes stale the moment this file grows, so this
# harness reads its own citation out of the health check and compares it with what it just ran.
HEALTH="$HERE/zl1-health-check.sh"
if [ -r "$HEALTH" ]; then
  cited=$(sed -e 's/always "/ /g' -e 's/"$//' "$HEALTH" | tr '\n' ' ' |
            sed -n 's/.*zl1-video-probe-selftest.sh[ ,(]*\([0-9][0-9]*\) checks.*/\1/p')
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
