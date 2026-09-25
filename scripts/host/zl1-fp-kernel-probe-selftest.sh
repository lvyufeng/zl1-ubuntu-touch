#!/usr/bin/env bash
# zl1 fingerprint-at-the-kernel-layer probe -- offline self-test. Host-side, touches no device, needs no phone.
#
# Why this exists. `scripts/device/zl1-fp-kernel-probe.sh` is the instrument for the fingerprint blocks at the
# layer BELOW every fingerprint document in this project (docs 83/98/101/126 are all above it), and the
# readings that make its design are these:
#
#   1. TWO BLOCKS, OPPOSITE ANSWERS, ONE TREE. So the mutation that matters is not "read the wrong config
#      line" in the abstract -- it is blaming THE OPTION BESIDE THE RIGHT ONE. A third fingerprint driver
#      (`CONFIG_INPUT_FPC1020`) sits in the same Kernel tree and is also off; a probe pointed at it reports a
#      kernel that does not build the Goodix driver wherever FPC1020 happens to be off. Mutation 2 runs on a
#      fixture where FPC1020 is ON and GP5XX8 is off, so the two probes must DISAGREE there.
#   2. THE DRIVER'S NAME IS NOT THE COMPATIBLE. The SPI driver's `.name` is `goodix_fp`, so the directory is
#      /sys/bus/spi/drivers/goodix_fp while the node says `goodix,fingerprint`. Mutation 4 looks the driver up
#      under the compatible and reddens on a fixture where a driver IS registered -- and the two answers in
#      the same report then disagree, which is the shape of the defect.
#   3. THE DEVICE'S NAME IS NOT THE COMPATIBLE EITHER -- and this is the qbt1000 half. The node has no `reg`,
#      so `of_device_make_bus_id()` climbs to the root and the platform device is `soc:qcom,qbt1000`, exactly
#      as this board's `soc:qcom,cnss` and `soc:qcom,kgsl-hyp` are named. Mutation 6 asks for the compatible
#      and gets "no" on a fixture where the device exists.
#   4. "NOT READ" IS NOT "NOT SET". The config comes from `/proc/config.gz`, and a probe that reads no config
#      must say so rather than reporting a driver that is not built. Mutation 5 collapses the two, and the
#      `no-config` scenario is where it reddens.
#   5. THE WORD IS NOT THE BLOCK, so the scan is by COMPATIBLE and the fixture's tree carries a node whose
#      PATH says `fingerprint` and which has no compatible at all (qbt1000's child, exactly as on the phone).
#      Mutation 3 scans by word and the block count changes -- which is also how this harness shows that this
#      project's DTB-derived inventory cannot see that node by construction.
#   6. THIS PROBE OPENS NOTHING, AND ON THIS BLOCK "LOOKING" IS A STATE CHANGE: qbt1000's open() ends in an
#      scm_call2 that hands the SPI BLSP block to the secure world. So this harness carries a second static
#      guard -- for READS of the device nodes -- and a CANARY: the fake `/dev/goodix_fp`, `/dev/qbt1000`,
#      `/dev/qseecom` and a fake spidev all contain `FINGERPRINT-DEVICE-DO-NOT-OPEN`, and no scenario's output
#      may contain it.
#
# How it works: **the stub directory IS the device.** The probe runs as itself against a fake root, with the
# device's tools stubbed and PATH sandboxed to `$STUB:$MINBIN`. The rewrite covers `/proc/`, `/sys/` and the
# four device-node paths this block's prose names -- the last because the probe NAMES `/dev/goodix_fp`,
# `/dev/qbt1000`, `/dev/qseecom` and `/dev/spidevX.Y` in its refusals, and a rewrite that covered only the
# roots it reads today would leave a future `cat /dev/goodix_fp` escaping to this laptop. `/dev/null` does not
# share those prefixes and is asserted to survive.
#
# Usage: zl1-fp-kernel-probe-selftest.sh [--keep]
#   --keep   leave the fake device, the stubs and the rewritten probe for inspection
#
# `ZL1_FP_KERNEL_PROBE_SRC=/path` runs the whole thing against another copy of the subject, which is how a
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
SRC="${ZL1_FP_KERNEL_PROBE_SRC:-$HERE/../device/zl1-fp-kernel-probe.sh}"
[ -r "$SRC" ] || { echo "cannot read the subject: $SRC" >&2; exit 2; }

# THE NAME OF THIS DIRECTORY IS PART OF THE FIXTURE. The probe scans the tree by COMPATIBLE and by WORD, and
# prints how many of each it found -- so a fake root whose path contains one of those words makes every node
# match and the count becomes a constant. The directory is therefore named with neither `fingerprint`, nor
# `goodix`, nor `qbt1000`, nor `fpc`: the block's four words, none of which may appear in a path the probe
# greps. (`qcom` is deliberately still allowed: it is in the paths themselves and is not one of the words.)
W="${TMPDIR:-/tmp}/zl1-selftest-fake-device-fpk"
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
rc_is() { if [ "$1" = "$2" ]; then ok "and the exit status is $1"; else bad "expected exit $2, got $1"; fi; }

# --- the sandbox PATH ------------------------------------------------------------------------------
# `type -P`, not `command -v`: in a shell whose profile has made one of these a function, `command -v` prints
# the NAME rather than a path and the symlink would point at itself.
# `zcat` is a SHELL SCRIPT that execs `gzip -d`, so a sandbox holding zcat but not gzip fails with
# "zcat: gzip: not found" -- and the probe would read no config at all. That is the documented shape of a
# curated PATH hiding the feature it lacks, and it is why gzip is in the list AND required by name below.
for t in awk basename cat cut dirname find grep head od readlink sed sort tail tr uniq wc zcat gunzip gzip; do
  p="$(type -P "$t" 2>/dev/null)" || continue
  [ -n "$p" ] || continue
  ln -sf "$p" "$MINBIN/$t"
  [ "$t" = find ] || ln -sf "$p" "$MINBIN_NOFIND/$t"
done
# The probe reads the tree with find(1), counts properties with od(1), shortens paths with basename(1), and
# reads the kernel's embedded config through zcat(1) or gunzip(1). A sandbox missing one of these would
# silently turn a reading into an absence, so each is required by name before anything runs.
for t in awk basename cat cut dirname grep od sed tail tr wc find zcat gzip; do
  [ -x "$MINBIN/$t" ] || { echo "the sandbox bin is missing $t -- cannot run the probe honestly" >&2; exit 2; }
done
# The second sandbox exists to make ONE state reachable: a device whose kernel has no find(1). Without it,
# "the tree could not be searched" is unreachable and the check that separates it from an absence tests
# nothing.
[ -e "$MINBIN_NOFIND/find" ] && { echo "the no-find sandbox has a find in it" >&2; exit 2; }
[ -x "$MINBIN_NOFIND/tr" ] || { echo "the no-find sandbox is not usable" >&2; exit 2; }
SH_BIN="$(type -P sh 2>/dev/null)"; [ -n "$SH_BIN" ] || SH_BIN=/bin/sh
[ -x "$SH_BIN" ] || { echo "no /bin/sh to run the probe with" >&2; exit 2; }
# gzip is needed to BUILD the fixture's /proc/config.gz; the probe itself only ever reads it.
type -P gzip >/dev/null 2>&1 || { echo "no gzip to build the fixture config with" >&2; exit 2; }

# --- the subject, rewritten into the fake device ---------------------------------------------------
#
# ONE PASS PER RULE and one file per pass, so each rule is counted where it ran. A single pass cascades: the
# `/sys/` inside `/proc/sys/kernel/random/boot_id` would be replaced by the `/proc/` rule and then the `/sys/`
# rule would hit the result. Pass 1 turns each root into a token that cannot itself be a device path; pass 2
# expands the tokens, and nothing in a replacement can be re-matched by a rule that already ran.
cnt() { grep -o -- "$1" "$2" 2>/dev/null | wc -l | tr -d ' '; }
RW="$W/fp-kernel-probe.sh"
sed -e 's#/proc/#__ZP__#g' "$SRC" > "$W/pass1a.sh"
[ "$(cnt '/proc/' "$SRC")" = "$(cnt '__ZP__' "$W/pass1a.sh")" ] \
  || { echo "the /proc/ rewrite did not cover every /proc/ in the source" >&2; exit 2; }
[ "$(cnt '/proc/' "$W/pass1a.sh")" = 0 ] || { echo "a /proc/ survived pass 1 -- the probe would read this host" >&2; exit 2; }
sed -e 's#/sys/#__ZS__#g' "$W/pass1a.sh" > "$W/pass1b.sh"
[ "$(cnt '/sys/' "$W/pass1a.sh")" = "$(cnt '__ZS__' "$W/pass1b.sh")" ] \
  || { echo "the /sys/ rewrite did not cover every /sys/ in the source" >&2; exit 2; }
[ "$(cnt '/sys/' "$W/pass1b.sh")" = 0 ] || { echo "a /sys/ survived pass 1" >&2; exit 2; }
# The four device-node paths this block's prose names, each its own rule so each is counted where it ran.
sed -e 's#/dev/goodix_fp#__ZDG__#g' "$W/pass1b.sh" > "$W/pass1c.sh"
[ "$(cnt '/dev/goodix_fp' "$W/pass1b.sh")" = "$(cnt '__ZDG__' "$W/pass1c.sh")" ] \
  || { echo "the /dev/goodix_fp rewrite did not cover every occurrence" >&2; exit 2; }
sed -e 's#/dev/qbt1000#__ZDQ__#g' "$W/pass1c.sh" > "$W/pass1d.sh"
[ "$(cnt '/dev/qbt1000' "$W/pass1c.sh")" = "$(cnt '__ZDQ__' "$W/pass1d.sh")" ] \
  || { echo "the /dev/qbt1000 rewrite did not cover every occurrence" >&2; exit 2; }
sed -e 's#/dev/qseecom#__ZDX__#g' "$W/pass1d.sh" > "$W/pass1e.sh"
[ "$(cnt '/dev/qseecom' "$W/pass1d.sh")" = "$(cnt '__ZDX__' "$W/pass1e.sh")" ] \
  || { echo "the /dev/qseecom rewrite did not cover every occurrence" >&2; exit 2; }
sed -e 's#/dev/spidev#__ZDP__#g' "$W/pass1e.sh" > "$W/pass1.sh"
[ "$(cnt '/dev/spidev' "$W/pass1e.sh")" = "$(cnt '__ZDP__' "$W/pass1.sh")" ] \
  || { echo "the /dev/spidev rewrite did not cover every occurrence" >&2; exit 2; }
for p in goodix_fp qbt1000 qseecom spidev; do
  [ "$(cnt "/dev/$p" "$W/pass1.sh")" = 0 ] || { echo "a /dev/$p survived pass 1" >&2; exit 2; }
done
MUSTNULL=$(cnt '2>/dev/null' "$SRC")
[ "$MUSTNULL" = "$(cnt '2>/dev/null' "$W/pass1.sh")" ] \
  || { echo "the rewrite touched /dev/null -- the probe's quiet redirects would break" >&2; exit 2; }
sed -e "s#__ZP__#$FR/proc/#g" -e "s#__ZS__#$FR/sys/#g" -e "s#__ZDG__#$FR/dev/goodix_fp#g" \
  -e "s#__ZDQ__#$FR/dev/qbt1000#g" -e "s#__ZDX__#$FR/dev/qseecom#g" -e "s#__ZDP__#$FR/dev/spidev#g" \
  "$W/pass1.sh" > "$RW"
sh -n "$RW" || { echo "the rewritten probe does not parse" >&2; exit 2; }
chmod +x "$RW"
if grep -q -- '__Z' "$RW"; then
  echo "an unexpanded token is left in $RW:" >&2; grep -n -- '__Z' "$RW" | sed -n '1,5p' >&2; exit 2
fi
# An invariant rather than a per-path tally: every token of pass 1 becomes exactly one fake-root path in pass
# 2, and nothing else may. A per-path count cannot see a MISSED path, and one missed path means the probe
# reads THIS machine while every scenario still passes.
TOK=$(cnt '__Z[A-Z]*__' "$W/pass1.sh"); FRS=$(cnt "$FR" "$RW")
[ "$TOK" -gt 0 ] || { echo "pass 1 produced no tokens -- the rewrite matched nothing" >&2; exit 2; }
[ "$TOK" = "$FRS" ] || { echo "$TOK tokens in pass 1 became $FRS fake-root paths in pass 2" >&2; exit 2; }
for tok in __ZP__ __ZS__ __ZDG__ __ZDQ__ __ZDX__ __ZDP__; do
  [ "$(cnt "$tok" "$W/pass1.sh")" -gt 0 ] || { echo "no $tok token was produced -- that rule matched nothing" >&2; exit 2; }
done
grep -qF "$FR$FR" "$RW" && { echo "a rewrite cascaded: $FR appears twice in a row" >&2; exit 2; }
grep -qF "$FR/proc/$FR" "$RW" && { echo "a rewrite cascaded into the fake root's own proc/" >&2; exit 2; }
# The paths the probe's answers hang on, named -- a rule that silently stopped applying would be invisible to
# the counts above if its occurrences moved into a comment.
for need in "$FR/proc/device-tree/model" "$FR/proc/device-tree/compatible" \
  "$FR/proc/sys/kernel/random/boot_id" "$FR/proc/uptime" "$FR/proc/version" "$FR/proc/config.gz" \
  "$FR/sys/bus/platform/drivers" "$FR/sys/bus/platform/devices" "$FR/sys/bus/spi/drivers" \
  "$FR/dev/goodix_fp" "$FR/dev/qbt1000" "$FR/dev/qseecom"; do
  grep -qF "$need" "$RW" || { echo "$need is not in the rewritten probe -- it would read this host, or a reading is gone" >&2; exit 2; }
done
# One rewriting rule for the mutation runs, which are derived from the subject and so inherit its counts.
rewrite_into() { # $1 = source, $2 = output
  sed -e 's#/proc/#__ZP__#g' -e 's#/sys/#__ZS__#g' -e 's#/dev/goodix_fp#__ZDG__#g' \
    -e 's#/dev/qbt1000#__ZDQ__#g' -e 's#/dev/qseecom#__ZDX__#g' -e 's#/dev/spidev#__ZDP__#g' "$1" \
    | sed -e "s#__ZP__#$FR/proc/#g" -e "s#__ZS__#$FR/sys/#g" -e "s#__ZDG__#$FR/dev/goodix_fp#g" \
      -e "s#__ZDQ__#$FR/dev/qbt1000#g" -e "s#__ZDX__#$FR/dev/qseecom#g" -e "s#__ZDP__#$FR/dev/spidev#g" > "$2"
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
#   * a HEREDOC BODY IS TEXT. The probe's `--explain` page says in prose what this block's surfaces are, and
#     blanking the bodies first keeps that prose from being read as code while keeping the line count, so a
#     real hit still reports its own line number.
blank_heredocs() { awk '/<<.?EOF/{s=1} { if (s) print ""; else print $0 } /^EOF$/{s=0}' "$1"; }
strip_nulls() { sed -e 's#[0-9]\{0,\}>[[:space:]]*/dev/null##g' "$1"; }
WRITE_RE='[^-]>[[:space:]]*/(sys|proc|dev)/|(^|[;&|(]|(then|do|else))[[:space:]]*(dd|tee|setprop|modprobe|insmod|rmmod|mkfs(\.ext4)?|mount|umount)([[:space:]]|$)'
write_sites() { strip_nulls "$1" | blank_heredocs /dev/stdin | grep -nE -- "$WRITE_RE"; }
# WHAT COUNTS AS A READ OF THIS BLOCK'S HARDWARE. The write guard above cannot see `cat`, and this probe's
# claim is stronger than "it does not write": it opens NO device node at all, because on this block open() is
# an scm_call2 that hands the SPI BLSP block to the secure world. So the commands that could open one are
# looked for with the four device paths, in one pass, with the same heredoc exemption.
#
# `rd` (this tree's own disciplined reader) is deliberately NOT in the list -- reading a device DIRECTORY's
# `name`/`compatible`/`status` is exactly what the probe is allowed to do -- and neither is `ls`.
OPEN_RE='(^|[;&|(])[[:space:]]*(cat|od|head|tail|dd|wc|grep|tr|strings|hexdump|truncate|tee)([[:space:]]|<|>)[^|]*(dev/goodix_fp|dev/qbt1000|dev/qseecom|dev/spidev|goodix_fp|qbt1000|qseecom)'
open_sites() { blank_heredocs "$1" | grep -nE -- "$OPEN_RE"; }

# --- the fake device --------------------------------------------------------------------------------
CANARY='FINGERPRINT-DEVICE-DO-NOT-OPEN'

# A device-tree STRING property is NUL-terminated; a u32 property is four big-endian bytes. Writing them the
# way the kernel reads them is what makes `dtstr`/`dtu32` in the probe testable at all.
dt_s() { printf '%s\0' "$2" > "$1"; }
dt_u32() { printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $(( ($2 >> 24) & 255 )) $(( ($2 >> 16) & 255 )) $(( ($2 >> 8) & 255 )) $(( $2 & 255 )))" > "$1"; }

# The kernel's own embedded config, gzipped exactly as /proc/config.gz is.
write_config() { # $1 = "OPTION=value" and "# OPTION is not set" lines, one per argument
  local out="$W/cfg.txt" line
  : > "$out"
  for line in "$@"; do printf '%s\n' "$line" >> "$out"; done
  gzip -c "$out" > "$FR/proc/config.gz"
}

mk_base() {
  rm -rf "$FR"
  mkdir -p "$FR/proc/device-tree/soc/spi@7579000/goodixfp@0" \
           "$FR/proc/device-tree/soc/qcom,qbt1000/qcom,fingerprint-sensor-ssc-spi-conn" \
           "$FR/proc/sys/kernel/random" "$FR/sys/bus/platform/drivers" "$FR/sys/bus/platform/devices" \
           "$FR/sys/bus/spi/drivers" "$FR/dev" || exit 2
  dt_s "$FR/proc/device-tree/model" "Letv Technologies, Inc. MSM 8996pro + PMI8996 LE_ZL1-DVT1"
  dt_s "$FR/proc/device-tree/compatible" "qcom,msm8996pro"
  # the SPI controller the goodix node sits on, and the node itself -- exactly as the phone's tree has them
  dt_s "$FR/proc/device-tree/soc/spi@7579000/compatible" "qcom,spi-qup-v2"
  dt_s "$FR/proc/device-tree/soc/spi@7579000/goodixfp@0/compatible" "goodix,fingerprint"
  dt_s "$FR/proc/device-tree/soc/spi@7579000/goodixfp@0/input-device-name" "gf318m"
  dt_u32 "$FR/proc/device-tree/soc/spi@7579000/goodixfp@0/goodix,gpio_reset" 31
  dt_u32 "$FR/proc/device-tree/soc/spi@7579000/goodixfp@0/goodix,gpio_irq" 121
  # the qbt1000 block: a compatible on the PARENT and nothing but properties on the CHILD. The child carries
  # NO compatible -- that is the phone's tree, and it is why a compatible-driven scan cannot see it while the
  # word scan can (it is in the child's PATH).
  dt_s "$FR/proc/device-tree/soc/qcom,qbt1000/compatible" "qcom,qbt1000"
  dt_u32 "$FR/proc/device-tree/soc/qcom,qbt1000/qcom,fingerprint-sensor-ssc-spi-conn/qcom,spi-port-id" 2
  dt_u32 "$FR/proc/device-tree/soc/qcom,qbt1000/qcom,fingerprint-sensor-ssc-spi-conn/qcom,ssc-subsys-id" 5
  # the platform device, named as of_device_make_bus_id() names a node with no `reg`
  mkdir -p "$FR/sys/bus/platform/devices/soc:qcom,qbt1000"
  # the qbt1000 driver: registered, with the device bound (the symlink exists only after probe returned 0)
  mkdir -p "$FR/sys/bus/platform/drivers/qbt1000"
  : > "$FR/sys/bus/platform/drivers/qbt1000/bind"
  : > "$FR/sys/bus/platform/drivers/qbt1000/unbind"
  : > "$FR/sys/bus/platform/drivers/qbt1000/uevent"
  ln -sfn "$FR/sys/bus/platform/devices/soc:qcom,qbt1000" \
    "$FR/sys/bus/platform/drivers/qbt1000/soc:qcom,qbt1000"
  # the four device nodes a reader is most tempted to open, each with a canary in it
  printf '%s\n' "$CANARY" > "$FR/dev/goodix_fp"
  printf '%s\n' "$CANARY" > "$FR/dev/qbt1000"
  printf '%s\n' "$CANARY" > "$FR/dev/qseecom"
  printf '%s\n' "$CANARY" > "$FR/dev/spidev11.0"
  printf 'Linux version 3.18.140 (zl1@fixture) #1 SMP\n' > "$FR/proc/version"
  printf '12345.67 89012.34\n' > "$FR/proc/uptime"
  printf '00000000-1111-2222-3333-444444444444\n' > "$FR/proc/sys/kernel/random/boot_id"
  # THE PHONE'S OWN CONFIG: the Goodix driver off, the FPC one off, qbt1000 on, both SPI and the QMI/QSEECOM
  # halves on. This is the set read out of the kernel image the zl1 boots (see the probe's header).
  write_config '# CONFIG_INPUT_GP5XX8 is not set' '# CONFIG_INPUT_FPC1020 is not set' \
    'CONFIG_MSM_QBT1000=y' 'CONFIG_SPI_QUP=y' 'CONFIG_SPI_SPIDEV=y' 'CONFIG_MSM_QMI_INTERFACE=y' 'CONFIG_QSEECOM=y'
}

run() { # $1 = sandbox ('' = full), rest = probe args
  local sb="$1"; shift
  if [ -n "$sb" ]; then
    OUT=$(cd "$FR" && PATH="$STUB:$sb" "$SH_BIN" "$RW" "$@" 2>&1)
  else
    OUT=$(cd "$FR" && PATH="$STUB:$MINBIN" "$SH_BIN" "$RW" "$@" 2>&1)
  fi
  RC=$?
}
run_src() { # $1 = probe source to rewrite+run, rest = args
  local src="$1"; shift
  rewrite_into "$src" "$W/mut.sh"; chmod +x "$W/mut.sh"
  OUT=$(cd "$FR" && PATH="$STUB:$MINBIN" "$SH_BIN" "$W/mut.sh" "$@" 2>&1); RC=$?
}

# A `dmesg` that answers, so the log section is READ rather than skipped, and that carries the two lines this
# block's log section is about: the driver core's own failed-probe line, and the goodix driver's own init line.
printf '%s\n' '#!/bin/sh' \
  'cat <<'"'"'EOF'"'"'' \
  '[    3.100000] qbt1000: probe of soc:qcom,qbt1000 failed with error -22' \
  '[    3.200000] gf:irq_gpio:121' \
  'EOF' > "$STUB/dmesg"
printf '%s\n' '#!/bin/sh' 'exit 1' > "$STUB/journalctl"
chmod +x "$STUB/dmesg" "$STUB/journalctl"

echo "== 1. the rewrite, both guards' teeth, and the probe's own pages =="
W_SITES=$(write_sites "$SRC")
if [ -z "$W_SITES" ]; then
  ok "the shipped probe contains no write into /sys, /proc or /dev and no state-changing command"
else
  bad "the shipped probe contains what looks like a write:"
  sed 's/^/        | /' <<< "$W_SITES"
fi
O_SITES=$(open_sites "$SRC")
if [ -z "$O_SITES" ]; then
  ok "and no command in it opens a device node -- the claim is 'the kernel layer, nothing opened'"
else
  bad "the shipped probe looks like it opens a device node:"
  sed 's/^/        | /' <<< "$O_SITES"
fi
# The teeth. The write guard's fixtures are this block's real moves: qbt1000's open() is the scm_call2 route,
# and the goodix HAL's `/dev/goodix_fp` is the other; `modprobe` is how someone would "just try" a driver.
printf '%s\n' 'cat /dev/qbt1000' > "$W/teeth-qbt.sh"
printf '%s\n' 'od -An -tx1 /dev/goodix_fp' > "$W/teeth-glyph.sh"
printf '%s\n' 'printf 1 > /sys/bus/platform/drivers/qbt1000/bind' > "$W/teeth-bind.sh"
printf '%s\n' 'modprobe goodix_fp' > "$W/teeth-modprobe.sh"
printf '%s\n' '# prose that must not be read as code' \
  "say \"opening -> /dev/qbt1000 hands the BLSP block to the secure world\"" \
  "cat <<'EOF'" \
  'a reader would cat /dev/goodix_fp, and 2>/dev/null quiets a command' \
  'EOF' > "$W/teeth-prose.sh"
# Each of the four must be CAUGHT -- the teeth are asserted, not assumed, so a guard that stopped working
# cannot pass by finding nothing.
for t in qbt glyph bind modprobe; do
  if [ "$t" = bind ] || [ "$t" = modprobe ]; then
    if [ -n "$(write_sites "$W/teeth-$t.sh")" ]; then ok "the write guard catches teeth-$t"; else bad "the write guard does NOT catch teeth-$t"; fi
  else
    if [ -n "$(open_sites "$W/teeth-$t.sh")" ]; then ok "the open guard catches teeth-$t"; else bad "the open guard does NOT catch teeth-$t"; fi
  fi
done
if [ -z "$(open_sites "$W/teeth-prose.sh")" ] && [ -z "$(write_sites "$W/teeth-prose.sh")" ]; then
  ok "and both guards leave the prose (a heredoc body and a quoted path) alone"
else
  bad "a guard read the probe's prose as code:"
  { open_sites "$W/teeth-prose.sh"; write_sites "$W/teeth-prose.sh"; } | sed 's/^/        | /'
fi
# The rewrite's own invariant, asserted once more from the outside: the fake root must be the only thing the
# rewritten probe names.
grep -qF "$FR/proc/device-tree" "$RW" && ok "the rewritten probe reads the fake device tree" || bad "the rewritten probe does not name the fake tree"
# "the real path is gone" cannot be a lookbehind (the fake root's own `.../root/proc/device-tree` CONTAINS the
# string): it is the two counts being equal.
ALL_DT=$(cnt '/proc/device-tree' "$RW"); FAKE_DT=$(cnt "$FR/proc/device-tree" "$RW")
if [ "$ALL_DT" = "$FAKE_DT" ] && [ "$ALL_DT" -gt 0 ]; then
  ok "and every /proc/device-tree it names is the fake one ($ALL_DT of $ALL_DT)"
else
  bad "$ALL_DT mentions of /proc/device-tree, only $FAKE_DT of them under the fake root -- one would read this laptop"
fi

# --- the explain page and the usage page ------------------------------------------------------------
P_EX=$(PATH="$STUB:$MINBIN" "$SH_BIN" "$SRC" --explain 2>&1); P_RC=$?
rc_is "$P_RC" 0
nonempty "the --explain page prints something" "$P_EX"
want 'TWO BLOCKS, TWO SENSORS, ONE TREE' "$P_EX" "and it says there are two blocks"
want 'RETURNS 0 EVEN IF' "$P_EX" "and it names the goodix init trap before anyone turns the option on"
want 'OPENS NOTHING' "$P_EX" "and it says the probe opens nothing"
P_H=$(PATH="$STUB:$MINBIN" "$SH_BIN" "$SRC" --help 2>&1); P_RC=$?
rc_is "$P_RC" 0
want 'Usage \(on the device\)' "$P_H" "the --help page is the header"
P_B=$(PATH="$STUB:$MINBIN" "$SH_BIN" "$SRC" --nonsense 2>&1); P_RC=$?
want 'unknown argument' "$P_B" "an unknown argument is refused"
rc_is "$P_RC" 2
# --explain must read NOTHING: it is reachable with no device tree at all, which is the whole reason the
# tree guard sits after it.
P_E2=$(cd / && PATH="$STUB:$MINBIN" "$SH_BIN" "$SRC" --explain 2>&1); P_RC=$?
rc_is "$P_RC" 0
nonempty "and --explain works from a directory with no device tree" "$P_E2"

echo
echo "== 2. the phone's own state: the block the HAL opens has no driver in the kernel =="
mk_base
run ''
nonempty "the probe prints a report" "$OUT"
if [ "$RC" = 1 ]; then ok "and the exit status is 1 -- at least one block has no driver"; else bad "expected exit 1, got $RC"; fi
want '^== verdict: driver-not-built' "$OUT" "the verdict is the rung the goodix block reaches"
wantf 'compatible goodix,fingerprint' "$OUT" "and it names WHICH block: the one the HAL opens"
want 'CONFIG_INPUT_GP5XX8 is NOT SET' "$OUT" "and the reason is the option that builds its driver"
want '^     CONFIG_INPUT_GP5XX8 +NOT SET' "$OUT" "the config table says so on the driver's own option"
want '^     CONFIG_MSM_QBT1000 +y \(built in\)' "$OUT" "while the OTHER fingerprint block's driver IS built"
want "its bus:     .*spi@7579000" "$OUT" "and the SPI controller the node sits on is read as its own driver"
want "compatible 'qcom,spi-qup-v2'" "$OUT" "with the controller's compatible printed"
want 'option CONFIG_SPI_QUP: y \(built in\)' "$OUT" "and the controller's own option -- a node on an unbuilt bus is a different problem"
want 'soc:qcom,qbt1000' "$OUT" "and the qbt1000 DEVICE is named as the driver core names it, not by its compatible"
want 'platform device exists: yes' "$OUT" "so the device exists under that name"
want 'NO compatible property at all' "$OUT" "and the report says the child node has no compatible -- the invisible half"
want 'TRUE \(1 of 2 blocks\)' "$OUT" "the two sentences are kept apart: 'there is a driver' is TRUE"
want 'NOT ONE of them is the compatible' "$OUT" "and the four names of the goodix block are named"
want 'SPIDEV_MAJOR = 212' "$OUT" "including the fixed major"
want '212' "$OUT" "the fixed major is printed before anyone turns the option on"
want 'return 0; //status' "$OUT" "and so is the initcall that reports success on failure"
want 'SCM|scm_call2' "$OUT" "and the refusal names the secure-world handover"
want 'NOT ONE DEVICE NODE WAS OPENED' "$OUT" "and that it opened nothing"
want 'no .*/dev/goodix_fp,$' "$OUT" "naming the three device nodes it did not open"
notwantf "$CANARY" "$OUT" "AND THE CANARY: no scenario read a device node"

echo
echo "== 3. the fixture's opposite: both drivers built and bound =="
mk_base
write_config 'CONFIG_INPUT_GP5XX8=y' 'CONFIG_INPUT_FPC1020=y' 'CONFIG_MSM_QBT1000=y' 'CONFIG_SPI_QUP=y' 'CONFIG_SPI_SPIDEV=y' 'CONFIG_MSM_QMI_INTERFACE=y' 'CONFIG_QSEECOM=y'
mkdir -p "$FR/sys/bus/spi/drivers/goodix_fp"
: > "$FR/sys/bus/spi/drivers/goodix_fp/bind"; : > "$FR/sys/bus/spi/drivers/goodix_fp/unbind"; : > "$FR/sys/bus/spi/drivers/goodix_fp/uevent"
ln -sfn "$FR/proc/device-tree/soc/spi@7579000/goodixfp@0" "$FR/sys/bus/spi/drivers/goodix_fp/goodixfp@0"
run ''
want '^== verdict: every-block-has-a-bound-driver' "$OUT" "with a driver built for every block, the verdict is the top rung"
if [ "$RC" = 0 ]; then ok "and the exit status is 0 -- the only rung that exits 0"; else bad "expected exit 0, got $RC"; fi
want '2 of 2' "$OUT" "and the count is the whole table"
want 'registered:  yes' "$OUT" "the goodix driver's directory is looked up under its .name, goodix_fp"
want 'bound: goodixfp@0' "$OUT" "and its bound device is printed"
notwant 'NOT SET' "$OUT" "and nothing in the report claims an option is not set"
notwantf "$CANARY" "$OUT" "the canary is still unread"

echo
echo "== 4. built, registered, and NOT bound -- a different verdict from a different fact =="
mk_base
write_config 'CONFIG_INPUT_GP5XX8=y' 'CONFIG_INPUT_FPC1020=y' 'CONFIG_MSM_QBT1000=y' 'CONFIG_SPI_QUP=y' 'CONFIG_SPI_SPIDEV=y' 'CONFIG_MSM_QMI_INTERFACE=y' 'CONFIG_QSEECOM=y'
mkdir -p "$FR/sys/bus/spi/drivers/goodix_fp"
: > "$FR/sys/bus/spi/drivers/goodix_fp/bind"; : > "$FR/sys/bus/spi/drivers/goodix_fp/unbind"; : > "$FR/sys/bus/spi/drivers/goodix_fp/uevent"
run ''
want '^== verdict: driver-not-bound' "$OUT" "a driver that is built and registered but has no device bound is its own rung"
if [ "$RC" = 1 ]; then ok "and it exits 1"; else bad "expected exit 1, got $RC"; fi
want 'probe of soc:qcom,qbt1000 failed with error -22' "$OUT" "and the log section carries the driver core's own failed-probe line"
want "in the core's words" "$OUT" "and says that line is the core's, not the driver's"
want 'qbt1000_probe has NO dev_info anywhere' "$OUT" "and that a SUCCESSFUL qbt1000 probe prints nothing -- so silence is not evidence"

echo
echo "== 5. the qbt1000 device is bound and the goodix node is not: the count must be a reading =="
mk_base
write_config 'CONFIG_INPUT_GP5XX8=y' 'CONFIG_INPUT_FPC1020=y' 'CONFIG_MSM_QBT1000=y' 'CONFIG_SPI_QUP=y' 'CONFIG_SPI_SPIDEV=y' 'CONFIG_MSM_QMI_INTERFACE=y' 'CONFIG_QSEECOM=y'
mkdir -p "$FR/sys/bus/spi/drivers/goodix_fp"
: > "$FR/sys/bus/spi/drivers/goodix_fp/bind"; : > "$FR/sys/bus/spi/drivers/goodix_fp/unbind"; : > "$FR/sys/bus/spi/drivers/goodix_fp/uevent"
# the goodix node is DISABLED by the tree -- the fm-radio shape, here as a counter-case
dt_s "$FR/proc/device-tree/soc/spi@7579000/goodixfp@0/status" "disabled"
run ''
want '^== verdict: driver-not-bound' "$OUT" "the goodix node is disabled AND its driver is built here, so the rung is about the bind"
want '^     status:      disabled' "$OUT" "and the report prints the status rather than hiding it"
want 'ENABLED' "$OUT" "and says what an absent status would have meant"

echo
echo "== 6. the other board's tree, the unknown board, and a tree with no fingerprint block =="
mk_base
dt_s "$FR/proc/device-tree/model" "Letv Technologies, Inc. MSM 8996pro + PMI8996 LE_X2-DVT1"
run ''
want '^== verdict: wrong-board-tree' "$OUT" "LE_X2's tree is named as another phone's"
want 'BOTH fingerprint blocks sit in both of them' "$OUT" "and the report says the tree cannot separate them"
if [ "$RC" = 1 ]; then ok "and it exits 1"; else bad "expected exit 1, got $RC"; fi
notwantf "$CANARY" "$OUT" "the canary is unread"

mk_base
dt_s "$FR/proc/device-tree/model" "Some Other Board"
run ''
want '^== verdict: unknown-board' "$OUT" "a model naming neither board cannot be attributed"
want 'Some Other Board' "$OUT" "and the reading is printed, not assumed"

mk_base
rm -rf "$FR/proc/device-tree/soc/qcom,qbt1000"
rm -rf "$FR/proc/device-tree/soc/spi@7579000/goodixfp@0"
run ''
want '^== verdict: no-fingerprint-block' "$OUT" "a tree with neither compatible is a reading about the TREE"
want 'all five of its stock device trees' "$OUT" "and the report says what that means on this board"

echo
echo "== 7. no config to read: NOT READ is not NOT SET =="
mk_base
rm -f "$FR/proc/config.gz"
run ''
nonempty "the probe still reports" "$OUT"
want 'NOT READ' "$OUT" "with no config the answer is NOT READ"
want 'source:     NOT READ' "$OUT" "and the config section says so"
notwant 'is not set' "$OUT" "AND THE REPORT MUST NOT CLAIM 'is not set' -- a driver that was not built and a build state that could not be read are different facts"
want 'NOT KNOWN from this boot' "$OUT" "and the per-block line says the build state is not known"
if [ "$RC" = 1 ]; then ok "and it exits 1 -- it does not call an unread config a pass"; else bad "expected exit 1, got $RC"; fi

echo
echo "== 8. a kernel with no find(1): 'could not search' is not 'found nothing' =="
mk_base
# The only node shapes left are files, so the fallback's `-d` test finds no directory at all -- which is the
# state the `-d` was chosen for.
rm -rf "$FR/proc/device-tree"
mkdir -p "$FR/proc/device-tree"
dt_s "$FR/proc/device-tree/model" "Letv Technologies, Inc. MSM 8996pro + PMI8996 LE_ZL1-DVT1"
dt_s "$FR/proc/device-tree/compatible" "qcom,msm8996pro"
run "$MINBIN_NOFIND"
want '^== verdict: tree-unscanned' "$OUT" "a tree that could not be searched is its own verdict"
want 'THE TREE COULD NOT BE SEARCHED' "$OUT" "and the report says so where the block list would be"
if [ "$RC" = 1 ]; then ok "and it exits 1"; else bad "expected exit 1, got $RC"; fi

echo
echo "== 9. the same kernel with no find(1), but with nodes where the glob can reach them =="
mk_base
run "$MINBIN_NOFIND"
want 'goodix,fingerprint' "$OUT" "the fallback glob finds the nodes without find(1)"
want 'qcom,qbt1000' "$OUT" "both of them"
want '^== verdict: driver-not-built' "$OUT" "and the verdict is the same one the find(1) run gave"
if [ "$RC" = 1 ]; then ok "and it exits 1"; else bad "expected exit 1, got $RC"; fi

echo
echo "== 10. --quiet keeps the verdict and the readings it rests on =="
mk_base
run '' --quiet
nonempty "the quiet report is not empty" "$OUT"
want '^== verdict: driver-not-built' "$OUT" "the verdict still prints under --quiet"
want 'CONFIG_INPUT_GP5XX8' "$OUT" "and the reason still prints"
if [ "$RC" = 1 ]; then ok "and the exit status is unchanged"; else bad "expected exit 1, got $RC"; fi
Q_LINES=$(printf '%s\n' "$OUT" | grep -c . | tr -d ' ')
run ''
F_LINES=$(printf '%s\n' "$OUT" | grep -c . | tr -d ' ')
[ "$Q_LINES" -lt "$F_LINES" ] && ok "--quiet really is shorter ($Q_LINES vs $F_LINES lines)" || bad "--quiet printed as much as the full report ($Q_LINES vs $F_LINES)"

echo
echo "== 11. mutations: every one must change the answer on a fixture where it is known =="
# (1) blame the option BESIDE the right one: point the goodix block at the FPC driver's option. On a fixture
# where FPC1020 is ON and GP5XX8 is off, the unmutated probe says 'driver-not-built' and the mutated one says
# the driver is built -- the nfc block's defect, one block over.
mk_base
write_config '# CONFIG_INPUT_GP5XX8 is not set' 'CONFIG_INPUT_FPC1020=y' \
  'CONFIG_MSM_QBT1000=y' 'CONFIG_SPI_QUP=y' 'CONFIG_SPI_SPIDEV=y' 'CONFIG_MSM_QMI_INTERFACE=y' 'CONFIG_QSEECOM=y'
run ''
M0="$OUT"; M0RC="$RC"
want '^== verdict: driver-not-built' "$M0" "unmutated: the goodix block's own option is off, so the verdict is driver-not-built"
sed 's#^\( *printf .goodix_fp\\tCONFIG_INPUT_\)GP5XX8#\1FPC1020#' "$SRC" > "$W/m1.sh"
if grep -q 'goodix_fp\\tCONFIG_INPUT_FPC1020' "$W/m1.sh"; then
  ok "mutation 1 applied (the goodix block pointed at the FPC option)"
else
  bad "mutation 1 did not apply -- the sed matched nothing, so this mutation proves nothing"
fi
run_src "$W/m1.sh"
M1="$OUT"; M1RC="$RC"
want 'CONFIG_INPUT_FPC1020' "$M1" "mutated: the report now names the option beside the right one"
if [ "$(printf '%s' "$M0" | grep -c '^== verdict: driver-not-built')" != "$(printf '%s' "$M1" | grep -c '^== verdict: driver-not-built')" ]; then
  ok "and the verdict changes with it"
else
  bad "the mutation did not change the verdict -- it does not discriminate"
fi
# And the difference must be the OPTION, which is what makes this the nfc block's defect rather than a
# different one: the unmutated report names GP5XX8 as the reason and the mutated one must not.
want 'CONFIG_INPUT_GP5XX8 is NOT SET' "$M0" "unmutated, the reason names the goodix block's own option"
notwant 'CONFIG_INPUT_GP5XX8 is NOT SET' "$M1" "mutated, that sentence is gone -- the FPC option took its place"
# (2) look the driver up under the COMPATIBLE instead of under its `.name`. On a fixture where the driver IS
# registered and bound, the mutated probe reports 'registered: no' and no bound device.
mk_base
write_config 'CONFIG_INPUT_GP5XX8=y' '# CONFIG_INPUT_FPC1020 is not set' 'CONFIG_MSM_QBT1000=y' 'CONFIG_SPI_QUP=y' \
  'CONFIG_SPI_SPIDEV=y' 'CONFIG_MSM_QMI_INTERFACE=y' 'CONFIG_QSEECOM=y'
mkdir -p "$FR/sys/bus/spi/drivers/goodix_fp"
: > "$FR/sys/bus/spi/drivers/goodix_fp/bind"; : > "$FR/sys/bus/spi/drivers/goodix_fp/unbind"; : > "$FR/sys/bus/spi/drivers/goodix_fp/uevent"
ln -sfn "$FR/proc/device-tree/soc/spi@7579000/goodixfp@0" "$FR/sys/bus/spi/drivers/goodix_fp/goodixfp@0"
run ''
M0="$OUT"
want 'registered:  yes' "$M0" "unmutated: the driver is found under goodix_fp"
want '^== verdict: every-block-has-a-bound-driver' "$M0" "and everything is bound"
sed 's#goodix_fp\\tCONFIG_INPUT_GP5XX8#goodix,fingerprint\\tCONFIG_INPUT_GP5XX8#' "$SRC" > "$W/m2.sh"
run_src "$W/m2.sh"
M2="$OUT"; M2RC="$RC"
want 'registered:  no' "$M2" "mutated: looked up under the compatible, the driver is not found"
if [ "$M2RC" != 0 ]; then ok "and the run no longer exits 0"; else bad "the mutation still exits 0 -- it does not discriminate"; fi
# (3) scan by WORD instead of by compatible: the block count changes, because the word finds a node that has
# no compatible at all.
mk_base
run ''
M0="$OUT"
sed "s#for _compat in goodix,fingerprint qcom,qbt1000#for _compat in goodix qbt1000#" "$SRC" > "$W/m3.sh"
if grep -q 'for _compat in goodix qbt1000' "$W/m3.sh"; then
  ok "mutation 3 applied (the scan asks for a WORD instead of the compatible)"
else
  bad "mutation 3 did not apply -- the sed matched nothing"
fi
run_src "$W/m3.sh"
M3="$OUT"
N0=$(printf '%s' "$M0" | grep -c '^ \[[0-9]*\] ')
N3=$(printf '%s' "$M3" | grep -c '^ \[[0-9]*\] ')
if [ "$N3" != "$N0" ]; then
  ok "and the block count changes ($N3 vs $N0): a compatible is a whole string, and 'goodix' is not 'goodix,fingerprint'"
else
  bad "the mutation did not change the block count -- it does not discriminate"
fi
want '^== verdict: no-fingerprint-block' "$M3" "and with both words missing, the mutated report says the tree declares no block at all"
# (4) ask for the platform device by its COMPATIBLE instead of by the name the driver core gives it. On a
# fixture where the device exists as soc:qcom,qbt1000, the mutated probe answers 'no'.
mk_base
run ''
M0="$OUT"
want 'platform device exists: yes' "$M0" "unmutated: the device is found under soc:qcom,qbt1000"
sed 's#plat_dev_exists "soc:\$_bc"#plat_dev_exists "$_bc"#' "$SRC" > "$W/m4.sh"
run_src "$W/m4.sh"
M4="$OUT"
want 'platform device exists: no' "$M4" "mutated: asked for by its compatible, the device is reported missing"
# (5) collapse NOT READ into NOT SET: the no-config fixture is where that reddens.
mk_base
rm -f "$FR/proc/config.gz"
run ''
M0="$OUT"
sed 's#^  if \[ -z "\$CFG_SRC" \]; then printf .NOT READ.; return; fi#  if [ -z "$CFG_SRC" ]; then printf "NOT SET"; return; fi#' "$SRC" > "$W/m5.sh"
if grep -q 'then printf "NOT SET"; return; fi' "$W/m5.sh"; then
  ok "mutation 5 applied (NOT READ collapsed into NOT SET)"
else
  bad "mutation 5 did not apply -- the sed matched nothing"
fi
run_src "$W/m5.sh"
M5="$OUT"
want '^     CONFIG_MSM_QBT1000 +NOT SET' "$M5" "mutated: a config that was never read is now reported as options that are not set"
want 'NOT BUILT' "$M5" "and the per-block line draws the wrong conclusion from it"
# A per-ROW check, not a whole-report one: the no-config report legitimately NAMES the distinction in prose
# ("becomes NOT READ rather than NOT SET"), and an assertion that banned the two words would fail on the
# sentence that explains why they differ -- which is the shape of a check that cannot pass on a correct probe.
notwant '^     CONFIG_[A-Z0-9_]* +NOT SET' "$M0" "while no config ROW in the unmutated report claims an option is not set"
want '^     CONFIG_[A-Z0-9_]* +NOT READ' "$M0" "every row says NOT READ instead"
want 'NOT SET, and those are different facts' "$M0" "and the report says out loud why those two are not the same reading"
# (6) the exit status itself: make the top rung unreachable and the phone's own state must stop exiting 1.
mk_base
sed 's#^\[ "\$V" = every-block-has-a-bound-driver \] && exit 0#exit 0#' "$SRC" > "$W/m6.sh"
run_src "$W/m6.sh"
if [ "$RC" = 0 ]; then
  ok "mutation 6 applied: with the top-rung test replaced by a bare 'exit 0', the phone's fixture reports success"
else
  bad "the exit-status mutation was not visible -- the exit code is not a reading of the verdict"
fi
mk_base
write_config 'CONFIG_INPUT_GP5XX8=y' '# CONFIG_INPUT_FPC1020 is not set' 'CONFIG_MSM_QBT1000=y' 'CONFIG_SPI_QUP=y' \
  'CONFIG_SPI_SPIDEV=y' 'CONFIG_MSM_QMI_INTERFACE=y' 'CONFIG_QSEECOM=y'
mkdir -p "$FR/sys/bus/spi/drivers/goodix_fp"
: > "$FR/sys/bus/spi/drivers/goodix_fp/bind"; : > "$FR/sys/bus/spi/drivers/goodix_fp/unbind"; : > "$FR/sys/bus/spi/drivers/goodix_fp/uevent"
ln -sfn "$FR/proc/device-tree/soc/spi@7579000/goodixfp@0" "$FR/sys/bus/spi/drivers/goodix_fp/goodixfp@0"
run ''
if [ "$RC" = 0 ]; then ok "the clean fixture exits 0 before the mutation"; else bad "the clean fixture should exit 0, got $RC"; fi
sed 's#^\[ "\$V" = every-block-has-a-bound-driver \] && exit 0#[ "$V" = some-v-this-probe-never-sets ] && exit 0#' "$SRC" > "$W/m7.sh"
run_src "$W/m7.sh"
if [ "$RC" = 1 ]; then
  ok "mutation 7 applied: with the top-rung test broken, the CLEAN fixture stops exiting 0 -- the other direction"
else
  bad "the top-rung test is not what makes a clean run exit 0"
fi
# (7) the `-d` in the fallback: drop it, and a tree whose only entries are FILES reports "no blocks" instead
# of "could not search". The no-find fixture is the only place this is observable.
mk_base
rm -rf "$FR/proc/device-tree"; mkdir -p "$FR/proc/device-tree"
dt_s "$FR/proc/device-tree/model" "Letv Technologies, Inc. MSM 8996pro + PMI8996 LE_ZL1-DVT1"
dt_s "$FR/proc/device-tree/compatible" "qcom,msm8996pro"
sed 's#^    \[ -d "\$_nc_p" \] || continue#    :#' "$SRC" > "$W/m8.sh"
if grep -q '^    :$' "$W/m8.sh"; then ok "mutation 8 applied (the -d guard in the fallback)"; else bad "mutation 8 did not apply"; fi
run_src "$W/m8.sh"
if [ "$RC" != 2 ]; then ok "mutated: without the -d guard, 'could not search' is no longer reported as such"; else bad "the -d mutation was invisible"; fi

echo
echo "== 12. the subject this harness is about, and the harness's own count =="
# A harness that ran against a subject it could not read would pass by having nothing to say: `$SRC` is
# required at the top, and this is the same statement made where the numbers are printed.
[ -r "$SRC" ] && ok "the subject is readable: $(basename "$SRC")" || bad "the subject is not readable"
grep -q 'QBT1000' "$SRC" && ok "and it is this block's probe (it names QBT1000)" || bad "the subject does not look like this block's probe"
# --- the health check's number for THIS harness ------------------------------------------------------
# The health check names every harness with a hand-typed check count, and docs 110 records one of those
# going stale with nothing noticing. Each harness now checks its own citation, so a reader who adds a
# check here has to edit the page in the same commit -- and the failure names the page to fix.
HEALTH="$HERE/zl1-health-check.sh"
if [ -r "$HEALTH" ]; then
  match=$(tr '\n' ' ' < "$HEALTH" |
    grep -oE 'zl1-fp-kernel-probe-selftest\.sh[^0-9]*[0-9]+ checks' | sed -n 1p)
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

printf '%s\n' "pass=$PASS fail=$FAIL skip=0"
if [ "$FAIL" = 0 ]; then echo "== verdict: all green"; else echo "== verdict: $FAIL failing"; fi
if [ "$KEEP" = 1 ]; then echo "kept: $W"; else rm -rf "$W"; fi
[ "$FAIL" = 0 ] || exit 1
exit 0
