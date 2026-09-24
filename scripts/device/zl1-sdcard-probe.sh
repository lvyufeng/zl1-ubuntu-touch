#!/bin/sh
# zl1 sdcard probe -- the two SD/eMMC host controllers on this board: what the device tree declares,
# which one the driver actually bound, and whether any card ever enumerated behind them.
#
# Why this exists. doc 137 enumerated this board's hardware from its own device trees and named the blocks
# nothing in this tree reads. `sdcard` is one of them, and it is TWO controllers -- the whole `sdhci`/
# `mmcblk` family is absent from this repository. Two things made it worth reading before touching it:
#
#   1. THE TWO CONTROLLERS ARE NOT THE SAME KIND OF THING, AND THE TREE SAYS SO. /soc/sdhci@7464900 is
#      `qcom,nonremovable` (the vendor's name for it is `sdhc1`), and /soc/sdhci@74A4900 carries `cd-gpios`
#      (a card-detect GPIO on the TLMM) and is therefore the REMOVABLE slot. On the zl1 the second one is
#      `status = "disabled"` -- in ALL 38 device trees of the three sets -- so the kernel never creates the
#      platform device for it, and there is no card slot to put a card in as far as this kernel is
#      concerned. That is a DEVICE-TREE decision, not a runtime fault, and it is why "does the SD card
#      reader work" is not a question a reading can answer here: switching it on is a boot-image change.
#   2. THE CONTROLLER THAT IS ENABLED IS GATED ON THE CMDLINE, TOO. sdhci_msm_probe() reads the slot index
#      from the `sdhc` ALIAS (not from the node's path), and then has a gate of its own:
#          if ((ret == 1) && !sdhci_msm_is_bootdevice(&pdev->dev)) { ret = -ENODEV; goto pltfm_free; }
#      i.e. slot 1 (this board's `sdhc1`) is only probed when the cmdline's `androidboot.bootdevice=` names
#      it -- and when that token is ABSENT the function returns true, so the gate does NOT fire on this
#      port (neither the stock nor the v63 cmdline carries it). The probe prints that reading anyway,
#      because "the tree says okay and the driver still refused" is a real shape here and the reason is a
#      cmdline token rather than a fault.
#
# AND THE NUMBERS ARE ALLOCATION ORDER, NOT DEVICE-TREE ORDER. mmc core names a host by the lowest free id
# from an idr (drivers/mmc/core/host.c), and mmcblk's index comes from a find_first_zero_bit() over its own
# bitmap (drivers/mmc/core/block.c) -- and sdhci_msm_driver sets PROBE_PREFER_ASYNCHRONOUS, so which
# controller is `mmc0` is not determined by the device tree. So this probe NEVER names a controller by its
# mmcN number: it prints the number the kernel assigned, and the PARENT DEVICE the number belongs to, and
# anything that has to tell the two apart reads the parent.
#
# WHAT THIS BLOCK IS NOT: the storage this port boots from. The rootfs and /data are on the UFS controller
# (/dev/sda*; the rw /etc whitelist is /dev/sda10), so nothing here is on the boot path -- which is exactly
# why this one can be read without the caution the modem partition needs. It is still read-only, because
# every knob in sight is writable:
#   * `/sys/module/sdhci_msm/parameters/{disable_slots,nocmdq}` are `module_param(..., S_IRUGO|S_IWUSR)`,
#     i.e. 0644, and `disable_slots` is the bitmask whose bit N-1 skips slot N AT PROBE TIME;
#   * `/sys/block/mmcblk*/force_ro` is the write-protect lock, and `ro` beside it is drivable;
#   * and the most obvious "test" of all -- reading /dev/mmcblk0 to see whether it answers -- opens a block
#     device. This project does not open block devices on this phone (docs 120, the modem rule), so this
#     probe reads `/sys/block/*/size`, `/proc/partitions` and `/proc/mounts` instead, and says so.
#
# **Read-only, and it writes nothing at all** -- not even a scratch file, which is why the kernel log is
# captured into a shell variable. Making the slot work (a device-tree change in the boot image, or a write
# to `disable_slots`) is a separate, reviewed step; it is not a side effect of taking a reading.
#
# Usage (on the device):
#   sh zl1-sdcard-probe.sh             # every rung, then a verdict
#   sh zl1-sdcard-probe.sh --quiet     # the verdict and the readings it rests on
#   sh zl1-sdcard-probe.sh --explain   # what each reading decides, and why this reading
#
# Exit: 0 a card enumerated behind one of the controllers;
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

say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
hdr() { printf '\n== %s\n' "$*"; }
always() { printf '%s\n' "$*"; }

[ -d /proc/device-tree ] ||
  { echo "no /proc/device-tree here -- refusing (this probe reads the device tree)" >&2; exit 2; }

# --- reading helpers -------------------------------------------------------------------------------
#
# A file that does not exist, a file that is empty, and a file this process may not read are three
# different facts, and an empty string is what all three look like. `rd` never returns one.
rd() { # $1 = path
  if [ -r "$1" ]; then
    v=$(tr -d '\n' < "$1" 2>/dev/null)
    printf '%s' "${v:-EMPTY}"
  else
    printf 'UNREADABLE'
  fi
}
# A device tree carries raw binary, and a dump that contains a NUL byte is read by `grep` as BINARY --
# which means "no match" for a reader that is not expecting it (docs 141 hit this from the other side).
# Everything this probe prints is therefore printable-only.
san() { # $1 = text
  printf '%s' "$1" | LC_ALL=C tr -c '[:print:]\n\t' '.' | cut -c1-200
}
# NOTE THE `tr -d '\n'` BEFORE THE SANITIZER. `tr -c '[:print:]' '.'` replaces every byte that is not
# printable -- and a newline is not, so the line `sed -n 1p` just emitted would come back with a trailing
# dot: `ok` reads as `ok.` and every comparison against it silently misses.
dtstr() { # $1 = path
  if [ ! -r "$1" ]; then printf 'absent'; return; fi
  v=$(tr '\0' '\n' < "$1" 2>/dev/null | sed -n 1p | tr -d '\n' | LC_ALL=C tr -c '[:print:]' '.')
  printf '%s' "${v:-EMPTY}"
}
# Every string of a property, not just the first: `bus-speed-mode` and `clock-names` are LISTS, and reading
# only the first entry is how a property looks like it does not carry the mode you are looking for.
dtlist() { # $1 = path
  if [ ! -r "$1" ]; then printf 'absent'; return; fi
  v=$(tr '\0' '\n' < "$1" 2>/dev/null | grep . | LC_ALL=C tr -c '[:print:]\n' '.' | tr '\n' ' ')
  printf '%s' "${v:-EMPTY}"
}
# A device-tree u32 is BIG-ENDIAN and this SoC is little-endian, so `od -tu4` on the file prints the value
# BYTE-SWAPPED -- 8 (the bus width) comes out as a number of the right shape and the wrong value. The four
# bytes are combined explicitly, and anything that is not exactly four bytes says so.
# Helper variables are underscore-prefixed on purpose: shell functions here have no locals, so a helper's
# variable is the CALLER's.
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
# The n-th u32 of a property, for the ones that are arrays of cells rather than one value: `cd-gpios` is
# `<&tlmm 95 1>` = three cells, and reading it as a single number would be a wrong answer of the right
# shape. Cells are 1-based; a cell that is not there prints `absent`.
dtcell() { # $1 = path, $2 = 1-based cell index
  if [ ! -r "$1" ]; then printf 'absent'; return; fi
  _c_all=$(od -An -tu1 "$1" 2>/dev/null)
  _c_n=0; _c_cell=1; _c_have=0; _c_v=0
  for _c_x in $_c_all; do
    _c_k=$(( (_c_n % 4) + 1 ))
    case "$_c_k" in
    1) _c_v=$((_c_x * 16777216)) ;;
    2) _c_v=$((_c_v + _c_x * 65536)) ;;
    3) _c_v=$((_c_v + _c_x * 256)) ;;
    4) _c_v=$((_c_v + _c_x))
       if [ "$_c_cell" = "$2" ]; then _c_have=1; printf '%s' "$_c_v"; fi
       _c_cell=$((_c_cell + 1))
       ;;
    esac
    _c_n=$((_c_n + 1))
  done
  [ "$_c_have" = 1 ] || printf 'absent'
}
# EVERY u32 of a property, space-separated -- for `qcom,clk-rates`, which is a list and whose first entry
# (400 kHz) is not the reading anybody wants. Cells are read four bytes at a time, so a property whose
# length is not a multiple of four ends with whole cells and the leftover bytes are DROPPED rather than
# turned into a number built from the wrong bytes -- `dtu32` is the one that reports a bad length.
dtu32s() { # $1 = path
  if [ ! -r "$1" ]; then printf 'absent'; return; fi
  _s_out=""
  _s_idx=1
  while :; do
    _s_v=$(dtcell "$1" "$_s_idx")
    [ "$_s_v" = absent ] && break
    _s_out="$_s_out $_s_v"
    _s_idx=$((_s_idx + 1))
  done
  printf '%s' "${_s_out:-EMPTY}"
}
# Print the lines of TEXT that match an ERE, or a named "(none: ...)" line -- never nothing.
# NOT `grep ... | sed ... || say none`: in a pipeline the `||` applies to the LAST command and `sed`
# succeeds on empty input, so the none-branch would never fire.
show() { # $1 = text, $2 = ERE, $3 = the "(none: ...)" text, $4 = tail -n, $5 = 1 to print under --quiet
  [ "$QUIET" = 1 ] && [ "${5:-0}" != 1 ] && return 0
  out=$(printf '%s\n' "$1" | LC_ALL=C grep -aiE -- "$2" 2>/dev/null | tail -n "${4:-15}")
  if [ -n "$out" ]; then printf '%s\n' "$out" | sed 's/^/   | /'; else printf '   | %s\n' "$3"; fi
}
# Every node whose `compatible` list contains an entry, found by SCANNING -- the path is not assumed,
# because a path that moves between device trees is how this project has lost a block before. The glob
# after the scan exists for a kernel where `find` is missing, and it RETURNS 2 rather than "not found"
# when even that cannot look: "there is no such node" and "I could not search" are different facts.
# BOTH flags are reset first: they are globals, so a call that found something leaves `_nc_found=1` behind
# and the next call in the fallback branch would report "found" with no output.
nodes_with() { # $1 = compatible; prints paths one per line; 0 found, 1 none, 2 could not search
  _nc_found=0
  _nc_any=0
  if type find >/dev/null 2>&1; then
    for _nc_c in $(find /proc/device-tree -name compatible 2>/dev/null); do
      if tr '\0' '\n' < "$_nc_c" 2>/dev/null | grep -qx -- "$1"; then
        printf '%s\n' "${_nc_c%/compatible}"
        _nc_found=1
      fi
    done
    [ "$_nc_found" = 1 ] && return 0
    return 1
  fi
  # The known node shapes for a kernel without find(1). Both controllers are DIRECT children of /soc on
  # this board (read from the device trees), and the deeper variant is here because a node that moved to
  # another level is exactly what this scan exists to survive.
  for _nc_p in /proc/device-tree/soc/sdhci@* /proc/device-tree/soc/*/sdhci@*; do
    [ -e "$_nc_p" ] || continue
    _nc_any=1
    if tr '\0' '\n' < "$_nc_p/compatible" 2>/dev/null | grep -qx -- "$1"; then
      printf '%s\n' "$_nc_p"
      _nc_found=1
    fi
  done
  [ "$_nc_found" = 1 ] && return 0
  [ "$_nc_any" = 1 ] && return 1
  return 2
}
# Resolve a phandle to the node that carries it. `cd-gpios` is `<&tlmm 95 1>`, and the phandle is the only
# thing saying WHICH gpio controller that is -- printing the raw number would leave the reader to guess.
# A phandle can be carried by more than one node in a hand-built tree, so an ambiguous answer says so
# rather than picking one: a wrong controller is a wrong gpio number.
phandle_node() { # $1 = phandle number; prints a path, or "AMBIGUOUS(N)", or "unresolved"
  _ph_hits=0; _ph_first=""
  if type find >/dev/null 2>&1; then
    for _ph_f in $(find /proc/device-tree -name phandle -o -name linux,phandle 2>/dev/null); do
      [ -r "$_ph_f" ] || continue
      [ "$(dtu32 "$_ph_f")" = "$1" ] || continue
      _ph_hits=$((_ph_hits + 1))
      [ -z "$_ph_first" ] && _ph_first=$(dirname "$_ph_f")
    done
  else
    return
  fi
  case "$_ph_hits" in
  0) printf 'unresolved' ;;
  1) printf '%s' "${_ph_first#/proc/device-tree}" ;;
  *) printf 'AMBIGUOUS(%s)' "$_ph_hits" ;;
  esac
}

if [ "$MODE" = explain ]; then
  cat <<'EOF'
zl1 sdcard probe -- what each reading decides, and why it is this reading

  1. WHICH BOARD'S DEVICE TREE IS RUNNING (model, not compatible).
     The flashed boot image's appended blob carries 28 device trees: 5 for the LE_ZL1 and 23 for the LE_X2,
     a different phone, under a byte-identical root `compatible`. `model` is the only property that tells
     them apart, so it is read first: on the X2's tree every reading below is about another phone.

  2. THE TWO CONTROLLERS, WHICH ARE NOT THE SAME KIND OF THING.
     /soc/sdhci@7464900 is `qcom,nonremovable` (the vendor calls it `sdhc1`) and /soc/sdhci@74A4900 carries
     `cd-gpios`, i.e. a card-detect line, so it is the REMOVABLE slot (`sdhc2`). The probe prints, for
     each: `status`, which alias points at it, the bus width, the speed modes, the clock rates, whether it
     has inline crypto (`sdhc-msm-crypto` -- a phandle into the `qcom,ice` device, which has to probe FIRST
     or this driver defers forever: "required ICE device not probed yet"), and the card-detect GPIO
     RESOLVED through its phandle, because `<&tlmm 95 1>` is a gpio on a controller and the number alone
     does not say which.

  3. THE ALIAS IS WHAT THE DRIVER READS, AND THE NUMBER IS NOT.
     sdhci_msm_probe() takes its slot index from the `sdhc` ALIAS (`of_alias_get_id`), not from the node's
     path, and refuses outright if there is none ("Failed to get slot index"). It then gates slot 1 on the
     CMDLINE: `if ((ret == 1) && !sdhci_msm_is_bootdevice(&pdev->dev)) ret = -ENODEV;` -- and that helper
     returns TRUE when `androidboot.bootdevice=` is absent, so on this port the gate does not fire. Both
     readings are printed, because "the tree says okay and the driver still refused" is a real shape here
     and the cause would be a cmdline token, not a fault.

  4. THE DRIVER, AND WHAT IS BOUND TO IT.
     /sys/bus/platform/drivers/sdhci_msm/ appears when the driver registers, and the symlinks inside it are
     the devices that were PROBED -- so the bound list, not the directory, is what says whether a
     controller came up. The directory's absence is a different fact from its emptiness, and
     CONFIG_MMC_SDHCI_MSM=y in the defconfig is why "missing" cannot be read as "not built in".

  5. THE NUMBERS ARE ALLOCATION ORDER.
     mmc core names a host "mmc%d" from the lowest free id in an idr, and mmcblk's index comes from a
     find_first_zero_bit() over its own bitmap -- and this driver sets PROBE_PREFER_ASYNCHRONOUS, so which
     controller is mmc0 is not decided by the device tree. The probe therefore prints each mmcN WITH the
     parent device its number belongs to, and tells the controllers apart by the parent.

  6. WHETHER A CARD EVER ENUMERATED, read three ways that can disagree.
     A card is a CHILD of the host's class device, so it appears as /sys/class/mmc_host/mmcN/mmcN:XXXX with
     its own `name`/`date`/`serial`; a card with a filesystem also produces /sys/block/mmcblkN; and the
     partition table shows up in /proc/partitions. Printing all three is what keeps "the host came up" from
     reading as "a card is there".

  WHAT THIS CANNOT SAY. Whether a card in the slot WORKS. On this board the removable controller is
  `status = "disabled"` in the device tree, so the kernel never creates its platform device: an empty slot
  and a slot this kernel cannot drive are the same reading here, and making it work is a boot-image
  device-tree change (or a write to the driver's writable `disable_slots` bitmask) -- a separate, reviewed
  step, not a side effect of taking a reading. And this probe never opens /dev/mmcblk*: this project does
  not open block devices on this phone. It reads /sys/block/*/size, /proc/partitions and /proc/mounts.
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
  always "               therefore about the X2."
  ;;
unknown)
  always "   board:      UNKNOWN -- /proc/device-tree/model could not be read, so which board's tree this is"
  always "               cannot be told from here. The readings below are still taken, and this is named"
  always "               in the verdict rather than being silently assumed to be a zl1."
  ;;
*) always "   board:      neither LE_ZL1 nor LE_X2 -- nothing below can be attributed to this phone" ;;
esac

# --- 2. the controllers the tree declares ----------------------------------------------------------
hdr "the controllers the device tree declares"
NC_OUT=$(nodes_with qcom,sdhci-msm); NC_RC=$?
NODES=$(printf '%s\n' "$NC_OUT" | grep . 2>/dev/null)
N_NODES=0
[ -n "$NODES" ] && N_NODES=$(printf '%s\n' "$NODES" | wc -l | tr -d ' ')
# The aliases: what the driver actually reads for the slot index. Printed as a lookup, not a guess.
ALIASES=""
if [ -d /proc/device-tree/aliases ]; then
  for a in /proc/device-tree/aliases/*; do
    [ -e "$a" ] || continue
    n=$(basename "$a")
    case "$n" in sdhc*) ALIASES="$ALIASES $n=$(dtstr "$a")" ;; esac
  done
fi
always "   sdhc aliases:${ALIASES:- NONE (the driver refuses without one: 'Failed to get slot index')}"

N_ENABLED=0
N_REMOVABLE=0
N_REMOVABLE_ENABLED=0
if [ "$NC_RC" = 2 ]; then
  DT_RUNG=unscanned
  always ""
  always "   the device tree could not be searched for a compatible at all: find(1) is missing AND no"
  always "   sdhci@* node shape exists. This is NOT 'the tree declares no controller' -- it is 'this probe"
  always "   could not look', and the two must not print the same way."
elif [ -z "$NODES" ]; then
  DT_RUNG=no-node
  always ""
  always "   no node in this device tree carries compatible qcom,sdhci-msm"
  always "   -- the running tree declares no SD/eMMC host controller at all. The path is not assumed: the"
  always "      whole tree is scanned for the compatible."
else
  DT_RUNG=node
  for p in $NODES; do
    ST=$(dtstr "$p/status")
    NAME=$(dtstr "$p/qcom,msm-bus,name")
    CD=$(dtstr "$p/cd-gpios")
    NONREM=$(dtstr "$p/qcom,nonremovable")
    WIDTH=$(dtu32 "$p/qcom,bus-width")
    # Which kind of slot this is, from the tree's own properties rather than from the address.
    KIND=unspecified
    [ "$NONREM" != absent ] && KIND="non-removable (qcom,nonremovable)"
    [ "$CD" != absent ] && KIND="REMOVABLE (has cd-gpios)"
    case "$ST" in okay | ok | EMPTY) ENABLED=yes ;; *) ENABLED=no ;; esac
    [ "$ENABLED" = yes ] && N_ENABLED=$((N_ENABLED + 1))
    case "$KIND" in REMOVABLE*) N_REMOVABLE=$((N_REMOVABLE + 1)); [ "$ENABLED" = yes ] && N_REMOVABLE_ENABLED=$((N_REMOVABLE_ENABLED + 1)) ;; esac
    always ""
    always "   ${p#/proc/device-tree}"
    always "     status:      $ST  ($([ "$ENABLED" = yes ] && echo 'the kernel will create this platform device' || echo 'DISABLED: the kernel creates no platform device for it, and no driver can bind at all'))"
    always "     slot:        $KIND"
    always "     bus name:    $NAME   bus width: $WIDTH bit"
    always "     speed modes: $(dtlist "$p/qcom,bus-speed-mode")"
    say "     clock rates: $(dtu32s "$p/qcom,clk-rates")"
    # Inline crypto: the controller points at a `qcom,ice` device through a phandle, and THAT device has to
    # probe first or this driver defers forever.
    ICE_PH=$(dtu32 "$p/sdhc-msm-crypto")
    case "$ICE_PH" in
    absent) say "     inline crypto: none declared ('sdhc-msm-crypto' is not on this node)" ;;
    *) say "     inline crypto: yes -> phandle $ICE_PH = $(phandle_node "$ICE_PH")" ;;
    esac
    # `qcom,ice-clk-rates` is a u32 LIST (`300000000,150000000`), not a string list -- reading it with the
    # string helper prints a row of dots and looks like a property that is not there.
    say "     ice clock rates: $(dtu32s "$p/qcom,ice-clk-rates")   vdd-io-always-on: $([ -e "$p/qcom,vdd-io-always-on" ] && echo yes || echo no)"
    # The card-detect line, with its phandle resolved: `<&tlmm 95 1>` is a gpio NUMBER on a controller, and
    # printing the number alone leaves the reader to guess which one.
    if [ "$CD" != absent ]; then
      CD_CTRL=$(phandle_node "$(dtcell "$p/cd-gpios" 1)")
      CD_GPIO=$(dtcell "$p/cd-gpios" 2)
      CD_FLAG=$(dtcell "$p/cd-gpios" 3)
      case "$CD_FLAG" in
      1) CD_POL="active low (GPIO_ACTIVE_LOW)" ;;
      0) CD_POL="active high" ;;
      *) CD_POL="flag $CD_FLAG" ;;
      esac
      always "     card detect: phandle $(dtcell "$p/cd-gpios" 1) = $CD_CTRL, gpio $CD_GPIO, $CD_POL"
    else
      say "     card detect: none (no cd-gpios on this node)"
    fi
    # The pin states are a reading, not decoration: a controller whose pins are in no pinctrl group cannot
    # talk to anything however okay its status is.
    say "     pinctrl:     names='$(dtlist "$p/pinctrl-names")' groups=$(dtcell "$p/pinctrl-0" 1).."
    say "     (the driver reads its slot index from the sdhc ALIAS above, then gates slot 1 on the cmdline:"
    say "      'androidboot.bootdevice=' naming it, or ABSENT, in which case the gate does not fire)"
  done
fi

# --- 3. the driver, and what is bound to it --------------------------------------------------------
hdr "the driver (drivers/mmc/host/sdhci-msm.c)"
DRV=/sys/bus/platform/drivers/sdhci_msm
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
  always "   $DRV: MISSING -- the driver did not register at all"
  always "   (CONFIG_MMC_SDHCI_MSM=y and CONFIG_MMC_SDHCI_MSM_ICE=y in lineage_zl1_defconfig, so this is not"
  always "    a module that failed to load: if the directory is missing, the kernel did not build it in)"
fi
say "   (a driver directory appears as soon as the driver registers; a BOUND DEVICE is the symlink inside"
say "   it, and only the bound list can say whether a controller came up. The device name is"
say "   '<address>.sdhci' -- 7464900.sdhci for the non-removable controller, 74a4900.sdhci for the"
say "   removable one -- which is how the two are told apart here rather than by an mmcN number.)"
# The driver's own module parameters: `disable_slots` is the bitmask that skips a slot at probe time, and
# it is 0644 -- so it is named here as a knob this probe does not touch.
MP=/sys/module/sdhci_msm/parameters
if [ -d "$MP" ]; then
  always ""
  always "   $MP (both are module_param(..., S_IRUGO|S_IWUSR) = 0644: WRITABLE, and this probe writes neither)"
  for a in disable_slots nocmdq; do
    if [ -e "$MP/$a" ]; then always "     $(printf '%-16s' "$a") $(san "$(rd "$MP/$a")")"
    else say "     $(printf '%-16s' "$a") (not there)"; fi
  done
  say "     (disable_slots bit N-1 skips slot N AT PROBE TIME; it is read once, so writing it now would not"
  say "      change this boot's controllers -- and it is still not this probe's to write.)"
else
  always "   $MP: MISSING (the driver is built in but exposes no module parameters?)"
fi
say "   the cmdline's boot-device token, which is what gates slot 1:"
show "$(rd /proc/cmdline)" 'androidboot\.bootdevice=' \
  "(none: this boot's cmdline carries no androidboot.bootdevice= token -- sdhci_msm_is_bootdevice() returns TRUE for that, so the slot-1 gate does NOT fire)"

# --- 4. the mmc hosts, and whether a card enumerated ----------------------------------------------
hdr "the mmc hosts (what actually came up)"
HOSTS=""
if [ -d /sys/class/mmc_host ]; then
  for h in /sys/class/mmc_host/*; do
    [ -e "$h" ] || continue
    HOSTS="$HOSTS $(basename "$h")"
  done
fi
if [ -z "$HOSTS" ]; then
  always "   /sys/class/mmc_host: NO hosts registered"
  always "   (the class exists as soon as mmc core registers it; an empty one means no controller reached"
  always "    mmc_add_host(), so nothing can enumerate behind it)"
else
  always "   hosts:$HOSTS"
  for h in $HOSTS; do
    D=/sys/class/mmc_host/$h
    # The PARENT DEVICE the number belongs to. This is what tells the two controllers apart, because the
    # number itself is allocation order (see below).
    PARENT=$(readlink "$D/device" 2>/dev/null)
    case "$PARENT" in
    "") PARENT="(no device symlink)" ;;
    *) PARENT=$(printf '%s' "$PARENT" | sed 's#.*/##') ;;
    esac
    always ""
    always "   $h   parent device: $PARENT"
    say "     driver: $(basename "$(readlink "$D/device/driver" 2>/dev/null)")  (the platform driver bound to that parent)"
    # A card is a CHILD of the host's class device: mmcN:XXXX. Printing the children by name is how "the
    # host came up" is kept from reading as "a card is there".
    CARDS=""
    for c in "$D"/mmc*:*; do
      [ -e "$c" ] || continue
      CARDS="$CARDS $(basename "$c")"
    done
    if [ -z "$CARDS" ]; then
      always "     card:        NONE -- the host is up and no card enumerated behind it"
      say "     (for a NON-REMOVABLE host that is the interesting reading: the controller came up and the"
      say "      card initialisation did not complete. The log section below names the failure.)"
    else
      for c in $CARDS; do
        always "     card:        $c"
        for a in name type date fwrev hwrev serial manfid oemid prv life_time pre_eol_info; do
          [ -e "$D/$c/$a" ] && always "       $(printf '%-14s' "$a") $(san "$(rd "$D/$c/$a")")"
        done
        say "       (name/date/serial are the CARD's own registers -- a reading from the card, which is why a"
        say "        card-less phone cannot produce them.)"
      done
    fi
  done
  say ""
  say "   the number is ALLOCATION ORDER, not device-tree order: mmc core takes the lowest free id from an"
  say "   idr, and this driver sets PROBE_PREFER_ASYNCHRONOUS, so which controller is mmc0 is not decided by"
  say "   the tree. That is why each host above is printed with its PARENT DEVICE."
fi

# --- 5. the block devices and the partitions -------------------------------------------------------
hdr "the block devices (read through /sys and /proc, never by opening one)"
BLK=""
for b in /sys/block/mmcblk*; do
  [ -e "$b" ] || continue
  n=$(basename "$b")
  BLK="$BLK $n"
  always "   /sys/block/$n"
  # `size` is in 512-byte sectors, the one unit the kernel documents for it; the byte figure is arithmetic
  # and is labelled as such so it cannot be read as a raw value.
  SZ=$(rd "$b/size")
  case "$SZ" in
  UNREADABLE | EMPTY) always "     size:        $SZ" ;;
  *) always "     size:        $SZ sectors (512-byte units, as /sys/block documents it)" ;;
  esac
  always "     ro:          $(rd "$b/ro")   (1 = the kernel sees it read-only)"
  [ -e "$b/force_ro" ] && always "     force_ro:    $(san "$(rd "$b/force_ro")")   (WRITABLE: the write-protect lock, and this probe does not touch it)"
  PT=""
  for p in "$b"/"$n"*; do
    [ -e "$p" ] || continue
    [ "$(basename "$p")" = "$n" ] && continue
    PT="$PT $(basename "$p")"
  done
  always "     partitions:${PT:- NONE}"
done
if [ -z "$BLK" ]; then
  always "   /sys/block/mmcblk*: NONE -- no mmc block device exists on this boot"
  always "   (this is the reading that says a card with a filesystem never enumerated; it is NOT the same as"
  always "    'the controller did not come up', which section 4 answers.)"
else
  say "   (this probe does NOT open /dev/mmcblk*: this project does not open block devices on this phone,"
  say "    and /sys/block/*/size is the same number without touching the medium.)"
fi
always ""
always "   /proc/partitions, mmc rows:"
show "$(cat /proc/partitions 2>/dev/null)" 'mmcblk' \
  "(none: /proc/partitions has no mmcblk row)" 15
say "   the same file's non-mmc rows, for contrast (the port's own storage is NOT on this controller):"
show "$(cat /proc/partitions 2>/dev/null)" '^( |[0-9])' \
  "(none: /proc/partitions could not be read)" 10 1
always ""
always "   mounts mentioning an mmc device:"
show "$(cat /proc/mounts 2>/dev/null)" 'mmcblk' \
  "(none: nothing on this boot mounted an mmcblock device)" 10 1

# --- 6. the kernel log -----------------------------------------------------------------------------
hdr "the kernel log, for this block"
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
  always "   -- so this section is NOT READ. No verdict below rests on it: the rungs are decided on files,"
  always "   and the log only says WHY a controller that came up has no card."
  show "" x "(not read: the kernel log could not be read)" 1 1
else
  always "   source: $LOG_SRC"
  show "$LOG_TEXT" 'mmc[0-9]|sdhci|mmcblk' \
    "(none: the kernel log mentions no mmc host, sdhci or mmcblk this boot)" 25
  # The failure strings, taken from the sources rather than guessed: mmc.c/sd.c/sdio.c print "error %d
  # whilst initialising ... card"; sdhci.c prints "Timeout waiting for hardware interrupt"; and
  # sdhci-msm.c prints the slot/ICE/regulator/iomem lines quoted in the verdicts below.
  show "$LOG_TEXT" 'whilst initialising|Timeout waiting for hardware|Failed to get slot index|Slot [0-9] disabled|required ICE device not probed yet|ICE device is not enabled|sdhci_msm_ice_get_dev failed|Regulator setup failed|Failed to get iomem resource|Failed to remap registers|DT parsing error|No device tree node' \
    "(none: no card-initialisation or probe failure in this boot's log)" 20
fi

# --- verdict ---------------------------------------------------------------------------------------
# The rung the evidence reaches, named. Each rung is a different problem with a different next move, and
# the first one is a different BOARD.
if [ "$DT_RUNG" = unscanned ]; then
  V=tree-unscanned
  VMSG="the device tree could not be searched for a compatible (no find(1), and no sdhci@* node shape exists). Nothing about the controllers was read, so nothing here is a verdict about them."
elif [ "$BOARD" = x2 ]; then
  V=wrong-board-tree
  VMSG="this boot is running the LE_X2's device tree, not this phone's. The flashed image's appended blob carries both boards' trees under an identical root compatible, so nothing below is about the zl1. The next move is about which DTB the bootloader picked, not about the storage controllers."
elif [ "$BOARD" = other ] || [ "$BOARD" = unknown ]; then
  V=unknown-board
  VMSG="the device tree's model names neither LE_ZL1 nor LE_X2 (read: $MODEL), so this reading cannot be attributed to this phone. The readings below stand on their own; the attribution does not."
elif [ "$DT_RUNG" = no-node ]; then
  V=no-device-tree-node
  VMSG="this device tree declares no qcom,sdhci-msm node, so the SD/eMMC driver has nothing to bind to. Both controllers are in all three device-tree sets and in every one of the 5 ZL1 trees, so a missing node means the tree that booted is not one of this board's five."
elif [ "$N_ENABLED" = 0 ]; then
  V=all-controllers-disabled
  VMSG="every qcom,sdhci-msm node in this tree has a status that is not okay, so the kernel creates no platform device for any of them and no driver can bind. That is a DEVICE-TREE decision inside the boot image, not a runtime fault: nothing here can be fixed without changing the tree that boots."
elif [ -z "$DRV_BOUND" ]; then
  V=driver-not-bound
  VMSG="the driver is declared and enabled in the tree but no device is bound to it ($DRV): either the driver did not register (the directory is missing) or it registered and no controller was probed. The driver's own dprintks name what it could not read (regulators, iomem, the slot alias, the ICE device), and the log section above looks for them."
elif [ -z "$HOSTS" ]; then
  V=no-mmc-host
  VMSG="a platform device IS bound to the driver and mmc core has no host registered, so the controller did not reach mmc_add_host(). That is the driver's later probe stage failing (regulators, clocks, the pwr_irq, the tlmm remap) -- the log section names which."
elif [ -n "$BLK" ]; then
  V=card-enumerated
  VMSG="a card enumerated: /sys/block/$BLK exists with a size, which means a medium answered and the block layer registered it. Whether its FILESYSTEM mounts is a different reading -- and mounting is a write to the device, not a probe."
else
  V=no-card
  VMSG="the controller(s) came up and no card enumerated behind them: no mmcN:XXXX child and no /sys/block/mmcblkN. For the NON-REMOVABLE controller this is the interesting reading (it came up and the card initialisation did not complete -- the log names the failure), and for the removable one it is expected on this board: $N_REMOVABLE of $N_NODES controller(s) are REMOVABLE and $N_REMOVABLE_ENABLED of those are enabled in the tree, so 'a card in the slot' is not a reading this kernel can produce until the device tree that boots says otherwise."
fi

always ""
always "== verdict: $V"
always "   $VMSG"

# The one thing a verdict about this block must not leave implicit, said separately so it cannot be read as
# part of a fault: the slot itself.
if [ "$N_REMOVABLE" != 0 ] && [ "$N_REMOVABLE_ENABLED" = 0 ]; then
  always ""
  always "   THE REMOVABLE SLOT IS SWITCHED OFF IN THE DEVICE TREE ($N_REMOVABLE of $N_NODES controllers carry a"
  always "   cd-gpios and every one of them is disabled). In all 38 device trees of the three sets -- the"
  always "   other phone's included -- so this is not a board quirk of the zl1, it is how the vendor shipped"
  always "   both boards. Switching it on is a device-tree change inside the boot image (or a write to the"
  always "   driver's writable disable_slots bitmask, which is read once at probe time and would do nothing"
  always "   on this boot). Both are separate, reviewed steps and neither is a side effect of a reading."
fi

always ""
always "   WHAT THIS IS NOT: an answer to 'does a card in the slot work'. On this board an empty slot and a"
always "   slot this kernel cannot drive produce the SAME reading, and telling them apart needs either a card"
always "   (a physical act) or a device-tree change (a boot-image write). This probe also never opens"
always "   /dev/mmcblk*: it reads /sys/block/*/size, /proc/partitions and /proc/mounts instead."

case "$V" in
card-enumerated) exit 0 ;;
*) exit 1 ;;
esac
