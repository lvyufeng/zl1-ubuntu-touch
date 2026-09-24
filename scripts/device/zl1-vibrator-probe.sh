#!/bin/sh
# zl1 vibrator probe -- the PMI8994 haptics block (qcom,qpnp-haptic), AND the device tree that decides
# whether this board even has one.
#
# Why this exists, and why it is the probe that had to come with a correction.
# doc 137 enumerated this board's hardware from its device trees and listed nine blocks nothing here reads.
# One of those rows was `vibrator`, matched by the node /soc/i2c@75b7000/drv2604l@5a (compatible
# `ti,drv2604l`) with the note "only in the rebuilt set". That row was wrong twice over, and finding out why
# is the point of this probe:
#
#   1. `ti,drv2604l` is not this phone's vibrator. It is a second, I2C haptics chip on a DIFFERENT BOARD
#      whose device trees are appended to the same flashed boot image. The flashed image is
#      halium-boot-zl1-v63-rebuilt.img, and its appended blob carries 28 device trees: 5 for this phone
#      (LE_ZL1-*, model suffixes DVT1/EVT/NA/PVT) and 23 for the LeEco X2 (LE_X2-*, LE_X2_NA-*). All 23 of
#      the X2 trees carry drv2604l; none of the 5 ZL1 trees does. The inventory attributed a node to "the
#      board" when it had only attributed it to a directory, and the giveaway was recorded as a curiosity
#      ("only in the rebuilt set") instead of being chased.
#   2. This board's vibrator is the PMI8994's own haptics peripheral:
#        /soc/qcom,spmi@400f000/qcom,pmi8994@3/qcom,haptic@c000   compatible qcom,qpnp-haptic
#      and it is in ALL THREE device-tree sets -- stock, rebuilt and filtered -- so it was never a
#      "which image booted" question at all. Its driver is drivers/platform/msm/qpnp-haptic.c,
#      CONFIG_QPNP_HAPTIC=y in lineage_zl1_defconfig, and it registers a timed_output device named
#      "vibrator" -- i.e. /sys/class/timed_output/vibrator/enable, the file Android's vibrator HAL writes a
#      millisecond count to. Nothing in this tree had ever read it.
#
# The same board mix-up makes this the first probe here whose device guard reads `model` and not
# `compatible`. Both trees carry the IDENTICAL root compatible, byte for byte:
#     qcom,msm8996-mtp\0qcom,msm8996\0qcom,mtp
# so the guard its ~25 siblings use -- `grep -qa msm8996 /proc/device-tree/compatible` -- is satisfied by
# the OTHER PHONE'S device tree, which is in this blob. Only `model` distinguishes them
# (`... MSM 8996pro + PMI8996 LE_ZL1-DVT1` against `... MSM 8996 v3 + PMI8996 LE_X2-PVT`). The two trees
# also disagree about this very block: the ZL1's haptic node is `status = okay` with `qcom,wave-shape =
# sine`, the X2's is `status = disabled` with `square`. So on a boot that picked the wrong tree, the vibrator
# is the reading that says so -- which is why this probe reports the board as its first rung instead of
# refusing to run.
#
# **Read-only, and it writes nothing at all** -- not even a scratch file, which is why the kernel log is
# captured into a shell variable rather than a temp file. That matters more here than anywhere: `enable` is
# WRITABLE, and writing a millisecond count to it makes the phone buzz. The buzzing test is a separate,
# reviewed step; it is not a side effect of taking a reading, and the verdict says so.
#
# Usage (on the device):
#   sh zl1-vibrator-probe.sh              # every rung, then a verdict
#   sh zl1-vibrator-probe.sh --quiet      # verdict and the readings it rests on
#   sh zl1-vibrator-probe.sh --explain    # what each reading decides, and why this reading
#
# Exit: 0 the haptics driver is registered and its timed_output entry exists;
#       1 the reading chain stops early -- the verdict names the rung;
#       2 there is no device tree to read at all.

set -u

QUIET=0
MODE=report
while [ $# -gt 0 ]; do
  case "$1" in
  --quiet) QUIET=1 ;;
  --explain) MODE=explain ;;
  --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

# `say` carries the readings, `always` the things a reader must see whether or not they asked for the
# readings: which board's tree this is, and the verdict itself.
say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
hdr() { printf '\n== %s\n' "$*"; }
always() { printf '%s\n' "$*"; }

# The device tree is the base requirement -- without it there is nothing to read and no board to name.
[ -d /proc/device-tree ] ||
  { echo "no /proc/device-tree here -- refusing (this probe reads the device tree)" >&2; exit 2; }

# A file that does not exist, a file that is empty, and a file this process may not read are three different
# facts, and an empty string is what all three look like. `rd` never returns one.
rd() { # $1 = path
  if [ -r "$1" ]; then
    v=$(tr -d '\n' < "$1" 2>/dev/null)
    printf '%s' "${v:-EMPTY}"
  else
    printf 'UNREADABLE'
  fi
}
# A device-tree property is BYTES: a NUL-terminated string list. Take the first string, or say which of the
# three absences it is.
dtstr() { # $1 = path
  if [ ! -r "$1" ]; then printf 'absent'; return; fi
  v=$(tr '\0' '\n' < "$1" 2>/dev/null | sed -n 1p)
  printf '%s' "${v:-EMPTY}"
}
# Every string of a property, not just the first: a `compatible` is a LIST, and reading only its first entry
# is how a node looks like it does not carry the compatible you are looking for.
dtlist() { # $1 = path
  if [ ! -r "$1" ]; then printf 'absent'; return; fi
  v=$(tr '\0' '\n' < "$1" 2>/dev/null | grep . | tr '\n' ' ')
  printf '%s' "${v:-EMPTY}"
}
# A device-tree u32 property is BIG-ENDIAN and this SoC is little-endian, so `od -tu4` on the file prints the
# value BYTE-SWAPPED -- 0x00000e74 (3700 mV) comes out as 0x740e0000, a number that looks like a reading and
# is not one. The four bytes are therefore combined explicitly, and anything that is not exactly four bytes
# says so instead of printing a plausible number. Helper variables are underscore-prefixed on purpose: shell
# functions here have no locals, so a helper's variable is the CALLER's (docs: the shared-name defect).
dtu32() { # $1 = path
  if [ ! -r "$1" ]; then printf 'absent'; return; fi
  _u_vals=$(od -An -tu1 "$1" 2>/dev/null)
  _u_n=0; _u_a=; _u_b=; _u_c=; _u_d=
  for _u_x in $_u_vals; do
    _u_n=$((_u_n + 1))
    case "$_u_n" in 1) _u_a=$_u_x ;; 2) _u_b=$_u_x ;; 3) _u_c=$_u_x ;; 4) _u_d=$_u_x ;; esac
  done
  if [ "$_u_n" != 4 ]; then printf 'not-a-u32(%s bytes)' "${_u_n:-?}"; return; fi
  printf '%s' $((_u_a * 16777216 + _u_b * 65536 + _u_c * 256 + _u_d))
}
# Print the lines of TEXT that match an ERE, or a named "(none: ...)" line -- never nothing.
# NOT `grep ... | sed ... || say none`: in a pipeline the `||` applies to the LAST command and `sed`
# succeeds on empty input, so the none-branch would never fire. This repo has had to fix that shape in
# several instruments (docs 120 section 5, docs 136).
show() { # $1 = text, $2 = ERE, $3 = the "(none: ...)" text, $4 = tail -n, $5 = 1 to print under --quiet
  [ "$QUIET" = 1 ] && [ "${5:-0}" != 1 ] && return 0
  out=$(printf '%s\n' "$1" | grep -aiE -- "$2" 2>/dev/null | tail -n "${4:-15}")
  if [ -n "$out" ]; then printf '%s\n' "$out" | sed 's/^/   | /'; else printf '   | %s\n' "$3"; fi
}
# The node carrying a compatible, found by SCANNING for the compatible rather than by guessing its path.
# doc 137's whole lesson is that a node's path is a thing that moves between device trees, and this board's
# blob holds two boards' worth of them. The scan is the authority; the glob after it exists for a kernel
# where `find` is missing, and it RETURNS 2 rather than "not found" when even that fallback cannot look:
# "there is no such node" and "I could not search" are different facts and must not print alike.
node_with() { # $1 = compatible; prints the path; 0 found, 1 not found, 2 could not search
  if type find >/dev/null 2>&1; then
    for _nw_c in $(find /proc/device-tree -name compatible 2>/dev/null); do
      if tr '\0' '\n' < "$_nw_c" 2>/dev/null | grep -qx -- "$1"; then
        printf '%s' "${_nw_c%/compatible}"
        return 0
      fi
    done
    return 1
  fi
  _nw_any=0
  for _nw_p in /proc/device-tree/soc/*/qcom,haptic@* /proc/device-tree/soc/*/*/qcom,haptic@* \
    /proc/device-tree/soc/*/*/drv2604l@* /proc/device-tree/soc/*/drv2604l@*; do
    [ -e "$_nw_p" ] || continue
    _nw_any=1
    if tr '\0' '\n' < "$_nw_p/compatible" 2>/dev/null | grep -qx -- "$1"; then
      printf '%s' "$_nw_p"
      return 0
    fi
  done
  [ "$_nw_any" = 1 ] && return 1
  return 2
}

if [ "$MODE" = explain ]; then
  cat <<'EOF'
zl1 vibrator probe -- what each reading decides, and why it is this reading

  1. WHICH BOARD'S DEVICE TREE IS RUNNING (model, not compatible).
     The flashed boot image's appended blob carries 28 device trees: 5 for the LE_ZL1 and 23 for the LE_X2,
     a different phone. Their root `compatible` is byte-identical, so the `msm8996` guard every sibling
     probe uses cannot tell them apart; `model` can. This is the first rung because on the wrong tree every
     reading below is about another phone -- and the two trees disagree about THIS block: the ZL1's haptic
     node is status=okay with wave-shape sine, the X2's is status=disabled with square.

  2. THE DEVICE TREE'S DECLARATION, found by scanning for `qcom,qpnp-haptic`.
     The node, its `status`, and the properties its driver actually parses (`qcom,actuator-type`,
     `qcom,play-mode`, `qcom,wave-shape`, `qcom,vmax-mv`, `qcom,ilim-ma`, `qcom,wave-play-rate-us`, and the
     two interrupt opt-ins) -- taken from drivers/platform/msm/qpnp-haptic.c, not invented. A node can be
     present and switched off, and a missing property is a probe failure with its own message in the log
     ("Unable to read vmax", "Invalid actuator type").

  3. THE ti,drv2604l NODE, IF PRESENT, AS THE OTHER BOARD'S.
     A reader who greps this tree for "vibrator" finds /soc/i2c@75b7000/drv2604l@5a (compatible
     ti,drv2604l) and could reasonably conclude it is this phone's. It is not: it is declared by the X2's
     trees only (23 of the 28 DTBs in the flashed blob), its driver CONFIG_DRV2604L_HAPTICS=y is built, and
     both drivers register a timed_output named "vibrator". So its presence is evidence about WHICH TREE you
     are looking at, not about this board. It is printed as such, by name.

  4. THE DRIVER ON ITS BUS.
     `qcom,qpnp-haptic` is an SPMI driver, so it appears at /sys/bus/spmi/drivers/qcom,qpnp-haptic/. The
     directory appears when the driver registers and a BOUND DEVICE is the symlink inside it; only the
     second means the node was probed. Both are printed, because "registered" and "bound" are different
     facts and only one of them is about this phone's hardware.

  5. THE timed_output ENTRY, which is the interface that matters.
     qpnp-haptic.c registers a timed_output device named "vibrator" (CONFIG_ANDROID_TIMED_OUTPUT=y), so the
     entry is /sys/class/timed_output/vibrator/ with `enable` in it -- the file Android's vibrator HAL writes
     a millisecond count to. The entry's own sysfs attributes (wf_s0..wf_s7, wf_update, wf_rep, wf_s_rep,
     play_mode, dump_regs, ramp_test, min_max_test) come from the same source, so which driver owns the
     entry is read rather than assumed. `enable` reads 0 when idle, and 0 is NOT a fault.

  6. THE KERNEL LOG, filtered to the haptics driver.
     It dev_errs on a failed probe ("DT parsing failed", "hap config failed", "timed_output registration
     failed", "sysfs creation failed", and one "Unable to read <property>" per missing property), so the log
     is where a probe that did not happen says why. It is reported as a named absence if it cannot be read,
     and it is NOT a rung: no verdict below depends on it.

  WHAT THIS CANNOT SAY. Whether the phone BUZZES. Reading `enable` cannot answer that, because an idle
  vibrator reads 0 and a dead one does too -- the same shape as the LEDs probe's brightness, and the same
  answer: the evidence is whether the entry exists and whether a driver bound to the node. Writing a
  millisecond count to `enable` would answer it, which is exactly why this probe does not: that is a write,
  it is a separate step, and it needs its own review.
EOF
  exit 0
fi

# --- who am I reading ------------------------------------------------------------------------------
hdr "this boot"
always "   boot id:    $(rd /proc/sys/kernel/random/boot_id)"
always "   uptime:     $(cut -d' ' -f1 /proc/uptime 2>/dev/null)s"
say "   kernel:     $(rd /proc/version)"

# --- 1. which board's device tree is this ----------------------------------------------------------
hdr "the board this device tree describes"
MODEL=$(dtstr /proc/device-tree/model)
COMPAT=$(dtlist /proc/device-tree/compatible)
always "   model:      $MODEL"
say "   compatible: $COMPAT"
BOARD=other
case "$MODEL" in
*LE_ZL1*) BOARD=zl1 ;;
*LE_X2*) BOARD=x2 ;;
UNREADABLE | absent | EMPTY) BOARD=unknown ;;
esac
case "$BOARD" in
zl1) always "   board:      LE_ZL1 -- this phone" ;;
x2)
  always "   board:      LE_X2 -- NOT this phone. The appended device-tree blob in the flashed boot image"
  always "               carries both boards' trees (5 LE_ZL1 + 23 LE_X2), and this boot is running one of"
  always "               the X2's: the bootloader picked the other phone's tree. Every reading below is"
  always "               therefore about the X2, and so is every sibling probe's -- their device guard tests"
  always "               for \`msm8996\`, which both trees carry byte for byte."
  ;;
unknown)
  always "   board:      UNKNOWN -- /proc/device-tree/model could not be read, so which board's tree this is"
  always "               cannot be told from here. The readings below are still taken, and this is named"
  always "               in the verdict rather than being silently assumed to be a zl1."
  ;;
*) always "   board:      neither LE_ZL1 nor LE_X2 -- nothing below can be attributed to this phone" ;;
esac

# --- 2. the device tree's declaration --------------------------------------------------------------
hdr "the device tree's declaration"
HAP=$(node_with qcom,qpnp-haptic); NW_RC=$?
ST=""
if [ "$NW_RC" = 2 ]; then
  DT_RUNG=unscanned
  always "   the device tree could not be searched for a compatible at all: find(1) is missing AND none of"
  always "   the known node shapes exists. This is NOT 'there is no haptics node' -- it is 'this probe"
  always "   could not look', and the two must not print the same way."
elif [ -z "$HAP" ]; then
  DT_RUNG=no-node
  always "   no node in this device tree carries compatible qcom,qpnp-haptic"
  always "   -- the running tree declares no PMI8994 haptics peripheral at all. The path is not assumed:"
  always "      the whole tree is scanned for the compatible, because a path that moved between device"
  always "      trees is how this project has lost a block before (docs 137)."
else
  DT_RUNG=node
  always "   node:        ${HAP#/proc/device-tree}"
  say "   compatible:  $(dtlist "$HAP/compatible")"
  ST=$(dtstr "$HAP/status")
  always "   status:      $ST"
  # The properties the driver actually reads, from qpnp-haptic.c. `qcom,actuator-type` and `qcom,play-mode`
  # are strings; the rest are u32 and are read as big-endian (see dtu32). A missing one is not cosmetic:
  # each has its own dev_err in the log.
  say "   actuator:    $(dtstr "$HAP/qcom,actuator-type")  (lra or erm -- decides the whole drive path)"
  say "   play-mode:   $(dtstr "$HAP/qcom,play-mode")  (direct or pwm; pwm needs an LPG channel)"
  say "   wave-shape:  $(dtstr "$HAP/qcom,wave-shape")"
  say "   vmax-mv:     $(dtu32 "$HAP/qcom,vmax-mv")"
  say "   ilim-ma:     $(dtu32 "$HAP/qcom,ilim-ma")"
  say "   play-rate-us: $(dtu32 "$HAP/qcom,wave-play-rate-us")"
  say "   use-play-irq: $([ -e "$HAP/qcom,use-play-irq" ] && echo yes || echo no)   use-sc-irq: $([ -e "$HAP/qcom,use-sc-irq" ] && echo yes || echo no)"
  say "   (wave-samples/rep counts: $(dtu32 "$HAP/qcom,wave-rep-cnt") / $(dtu32 "$HAP/qcom,wave-samp-rep-cnt"))"
  case "$ST" in
  okay | ok | EMPTY | absent) ;;
  *)
    say "   -- status is not okay, so the kernel will not probe this node: whatever the properties say, no"
    say "      driver will bind to it. On the X2's trees this node is \`disabled\`; on the ZL1's it is \`okay\`,"
    say "      so a disabled node here is first of all a question about WHICH TREE booted."
    ;;
  esac
fi

# The other board's vibrator, named so that a reader who greps for "vibrator" does not stop here.
DRV2604L=$(node_with ti,drv2604l)
if [ -n "$DRV2604L" ]; then
  say "   also present: ${DRV2604L#/proc/device-tree}  ($(dtlist "$DRV2604L/compatible"))"
  say "     -- this is the LE_X2's vibrator, not this phone's. The X2 trees declare it and the ZL1 trees do"
  say "        not, and its driver (CONFIG_DRV2604L_HAPTICS=y) is built into this kernel, so it registers a"
  say "        SECOND timed_output under the same name. Its PRESENCE says which board's tree is running."
else
  say "   also present: no ti,drv2604l node in this tree (all 5 ZL1 trees lack it, all 23 X2 trees have it)"
fi

# --- 3. the driver, on its bus ---------------------------------------------------------------------
hdr "the haptics driver"
DRV=/sys/bus/spmi/drivers/qcom,qpnp-haptic
DRV_BOUND=""
if [ -d "$DRV" ]; then
  for b in "$DRV"/*; do
    [ -e "$b" ] || continue
    case "$(basename "$b")" in bind | unbind | uevent | module) continue ;; esac
    DRV_BOUND="$DRV_BOUND $(basename "$b")"
  done
  always "   $DRV: present"
  always "     bound devices:${DRV_BOUND:- NONE (the driver registered, nothing was probed)}"
else
  always "   $DRV: MISSING -- the driver did not register on the SPMI bus"
  always "   (CONFIG_QPNP_HAPTIC=y in lineage_zl1_defconfig and the driver is built in, so a missing"
  always "    directory is not a module that failed to load -- see the log section)"
fi
say "   (a driver directory appears as soon as the driver registers; a BOUND DEVICE is the symlink inside"
say "    it. The two are different facts, and only the second means the node was probed.)"

# --- 4. the timed_output entry ---------------------------------------------------------------------
hdr "the timed_output entry (/sys/class/timed_output)"
TO=/sys/class/timed_output
TO_ENTRIES=""
if [ -d "$TO" ]; then
  for d in "$TO"/*; do
    [ -e "$d" ] || continue
    TO_ENTRIES="$TO_ENTRIES $(basename "$d")"
  done
fi
TO_ENTRIES=${TO_ENTRIES# }
TO_HAS=0
if [ -z "$TO_ENTRIES" ]; then
  always "   $TO: $( [ -d "$TO" ] && echo 'present but EMPTY' || echo 'MISSING' )"
  always "   -- nothing registered a timed_output device, so there is no entry for a vibrator HAL to write"
  always "      to. CONFIG_ANDROID_TIMED_OUTPUT=y, so the class appears as soon as anything uses it."
else
  always "   entries: $TO_ENTRIES"
  for d in "$TO"/*; do
    [ -e "$d" ] || continue
    n=$(basename "$d")
    # `enable` is what a HAL writes to and what reports the time left; 0 means idle, and idle is not a
    # fault. It is READ here and never written -- see the note at the top of this file.
    EN=$(rd "$d/enable")
    case "$n" in vibrator) TO_HAS=1 ;; esac
    say "     $(printf '%-12s' "$n") enable=$EN"
    # The attributes are qpnp-haptic.c's own sysfs group, so they say WHICH driver owns the entry: the X2's
    # drv2604l driver registers the same name "vibrator" with its own, different set.
    ATTRS=""
    for a in wf_s0 wf_s1 wf_s2 wf_s3 wf_s4 wf_s5 wf_s6 wf_s7 wf_update wf_rep wf_s_rep play_mode \
      dump_regs ramp_test min_max_test; do
      [ -e "$d/$a" ] && ATTRS="$ATTRS $a"
    done
    say "       attrs:${ATTRS:- none (not qpnp-haptic's group)}"
  done
fi

# --- 5. the kernel log -----------------------------------------------------------------------------
hdr "the kernel log, for the haptics driver"
# Captured into a variable, because the probe writes nothing at all -- not even a scratch file.
LOG_TEXT=""; LOG_SRC=""
if LOG_TEXT=$(dmesg 2>/dev/null) && [ -n "$LOG_TEXT" ]; then
  LOG_SRC=dmesg
elif LOG_TEXT=$(journalctl -b -k --no-pager 2>/dev/null) && [ -n "$LOG_TEXT" ]; then
  LOG_SRC="journalctl -b -k"
else
  LOG_TEXT=""; LOG_SRC=""
fi
if [ -z "$LOG_SRC" ]; then
  always "   the kernel log could not be read (neither dmesg nor journalctl -b -k returned anything)"
  always "   -- so this section is NOT READ. No verdict below rests on it: every reading this probe decides"
  always "   on is a file, not a log line."
  show "" x "(not read: the kernel log could not be read)" 1 1
else
  always "   source:          $LOG_SRC"
  show "$LOG_TEXT" 'qpnp.hap|qpnp_hap|haptic|vibrat' \
    "(none: the kernel log mentions no haptics driver this boot)" 20
  show "$LOG_TEXT" 'DT parsing failed|hap config failed|hap pwm config failed|timed_output registration failed|sysfs creation failed|Unable to read (vmax|actuator type|play mode|wav shape|ILim|play rate|timeout)|Invalid (actuator type|play mode)|only PWM mode|Unable to get haptic base address' \
    "(none: no haptics probe failure in this boot's log)" 10
fi

# --- verdict ---------------------------------------------------------------------------------------
# The rung the evidence reaches, named. Each rung is a different problem with a different next move -- and
# the first one is a different BOARD, which is why it is checked before the hardware.
if [ "$DT_RUNG" = unscanned ]; then
  V=tree-unscanned
  VMSG="the device tree could not be searched for a compatible (no find(1), and none of the node shapes this probe knows is present). Nothing about the vibrator was read, so nothing here is a verdict about it."
elif [ "$BOARD" = x2 ]; then
  V=wrong-board-tree
  VMSG="this boot is running the LE_X2's device tree, not this phone's. The flashed image's appended blob carries both boards' trees under an identical root compatible, so nothing below -- and nothing in any sibling probe whose guard tests for msm8996 -- is about the zl1. The next move is about which DTB the bootloader picked, not about the vibrator."
elif [ "$BOARD" = other ] || [ "$BOARD" = unknown ]; then
  V=unknown-board
  VMSG="the device tree's model names neither LE_ZL1 nor LE_X2 (read: $MODEL), so this reading cannot be attributed to this phone. The hardware readings below stand on their own; the attribution does not."
elif [ "$DT_RUNG" = no-node ]; then
  V=no-device-tree-node
  VMSG="this device tree declares no qcom,qpnp-haptic node, so no haptics driver has anything to bind to. Unlike the LEDs, this is NOT a which-image-booted question: the node is in all three device-tree sets (stock, rebuilt, filtered) and in every one of the 5 ZL1 trees. A missing node here means the tree that booted is not one of this board's five."
elif [ -n "$HAP" ] && [ "$ST" != okay ] && [ "$ST" != ok ]; then
  V=node-disabled
  VMSG="the haptic node is declared and its status is '$ST', so the kernel will not probe it and no driver can bind. On this board's own trees the status is 'okay'; 'disabled' is the LE_X2's copy of this block -- so the first question is which tree this is, not what is wrong with the driver."
elif [ -z "$DRV_BOUND" ]; then
  V=driver-not-bound
  VMSG="the node is declared, and no device is bound to the haptics driver ($DRV). Either the driver did not register on the bus (the directory is missing) or it registered and this node was not probed -- the log section above says which, and its dev_errs name the property it could not read."
elif [ "$TO_HAS" = 0 ]; then
  V=no-timed-output
  VMSG="a driver is bound to the haptics node and there is no 'vibrator' entry under $TO -- so the registration the vibrator HAL needs did not happen, or the entry was created under another name (found:$TO_ENTRIES). That is the driver's own step: qpnp-haptic.c dev_errs 'timed_output registration failed' when it cannot create it."
else
  V=registered
  VMSG="the haptics node is declared and okay, a driver is bound to it, and /sys/class/timed_output/vibrator exists with its own sysfs group. Whether the phone BUZZES is not answered here -- see the note under this verdict."
fi

always ""
always "== verdict: $V"
always "   $VMSG"
always ""
always "   WHAT THIS IS NOT: an answer to 'does the vibrator work'. An idle vibrator reads enable=0 and so"
always "   does one that can never be driven, so those two are the same reading here. What is evidence is"
always "   whether the node exists and is enabled, whether a driver bound to it, and whether the timed_output"
always "   entry exists -- and, first of all, WHICH BOARD'S TREE this is. Making the phone buzz is a WRITE"
always "   (a millisecond count into enable), and this probe does not write: that test is its own step."

case "$V" in
registered) exit 0 ;;
*) exit 1 ;;
esac
