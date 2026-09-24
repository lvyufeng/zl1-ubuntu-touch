#!/bin/sh
# zl1 FM radio probe -- the one device-tree node that describes this board's FM receiver, the
# `status = disabled` it carries in every set, and the two-namespace interrupt the driver reads twice.
#
# Why this exists. doc 137 enumerated this board's hardware from its own device trees and named the blocks
# nothing in this tree reads; `fm-radio` is one of them, and it is the one gap whose answer is a DEVICE TREE
# DECISION rather than a build option. Six readings make this probe's design:
#
#   1. THE TREE SWITCHES THIS NODE OFF, EXPLICITLY, IN EVERY SET. `/soc/i2c@75b5000/silabs4705@11`
#      (`silabs,si4705`) carries `status = "disabled"` -- in all 15 LE_ZL1 trees, in all three sets (stock,
#      rebuilt, filtered). Every other block this project has instrumented carries NO `status` at all, which
#      the device tree reads as ENABLED; this one is the exception, and the exception runs the other way.
#      A device tree node that is not okay is never instantiated by the i2c core, so there is NO client, no
#      bind, and no radio device -- whatever the kernel was built with. **That is the reading this probe
#      exists to make hard to miss**, and it is the first thing it prints.
#   2. AND THE OBVIOUS EXPLANATION IS WRONG. The tempting next sentence is "the driver is not built". It is:
#      `CONFIG_RADIO_SILABS=y` in BOTH kernels this project has in hand -- the vendor boot image's 3.18.120
#      kernel AND the v63 Halium 3.18.140 kernel this port boots. So this is not the `nfc` block's shape (a
#      config line outside the menu that gates it, off in the shipping kernel); it is the mirror image: the
#      driver is present and the TREE refuses the node. A probe that stopped at the config would report this
#      block as one build option away from working, and no build option would change anything.
#   3. THIS OPTION IS GATED BY ITS MENU, UNLIKE THE ONE NEXT DOOR. `config RADIO_SILABS` sits INSIDE
#      `if RADIO_ADAPTERS && VIDEO_V4L2`, and `RADIO_ADAPTERS` is itself a `menuconfig` that depends on
#      `VIDEO_V4L2` and `MEDIA_RADIO_SUPPORT`. That is the ordinary shape -- which is exactly why the `nfc`
#      block's placement outside its menu is worth a separate probe. The probe prints the whole chain,
#      because "the option is not set" can mean four different missing parents here.
#   4. THE NODE DESCRIBES ITS TWO INTERRUPTS TWICE, AND THE TWO DESCRIPTIONS GO THROUGH
#      DIFFERENT MECHANISMS. `interrupts = <0 1>` with `interrupt-map = <0 28 38 2  1 28 78 1>`: the child's
#      interrupt 0 maps to TLMM gpio 38 (flag 2) and interrupt 1 maps to TLMM gpio 78 (flag 1). And the
#      gpios the DRIVER reads -- `silabs,int-gpio = <28 38 0>` and `silabs,status-gpio = <28 78 0>` -- are
#      the same two pins. So the tree routes the interrupts through the gpio controller, and the driver
#      ignores the interrupt-map entirely and calls `gpio_to_irq()` on its own gpios. A reading that quoted
#      `interrupts` as "the FM interrupts" would be quoting a description nothing acts on.
#   5. THREE GPIOS, TWO OF THEM FATAL, AND TWO REGULATORS, NEITHER OF THEM FATAL. `silabs,reset-gpio` is
#      fatal in the strongest way -- `silabs_parse_dt()` returns the gpio's own negative errno, so the
#      probe's failure code is whatever `of_get_named_gpio()` said -- `silabs,int-gpio` is fatal, and
#      `silabs,status-gpio` is optional (a `FMDERR` and the driver carries on with `status_gpio` at 0,
#      which later code tests with `> 0`). The two supplies are the reverse: `regulator_get("va")` failing
#      is NOT fatal (a -EPROBE_DEFER defers the probe, anything else just skips the regulator) and
#      `regulator_get("vdd")` failing prints "vdd supply is not provided" and continues. So "the node is
#      complete" and "the driver can bind" are different questions here too, with a different split.
#   6. THE WRITE-CLASS MOVE IS OPENING A CHARACTER DEVICE, AND THIS BLOCK HAS A WRITABLE SYSFS FILE.
#      `silabs_fm_fops_open()` runs `silabs_fm_power_cfg(TURNING_ON)`: both regulators on, the pinctrl
#      active state selected, the reset/int/status gpios configured -- and the first ioctl writes real
#      commands to the chip over i2c (`send_cmd` -> `i2c_transfer`). So `open("/dev/radioN")` is a hardware
#      action, not a read of one. AND the v4l2 core puts a WRITABLE attribute on every radio device:
#      `/sys/class/video4linux/radioN/debug` is `DEVICE_ATTR_RW(debug)` -- the only writable file this block
#      has, and it is a verbosity knob in the v4l2 core, not the hardware. The probe writes neither.
#
# AND THE FOURTH NAME, WHICH IS THE ONE IN /dev. The compatible is `silabs,si4705`; the i2c driver's `.name`
# is **`silabs-fm`** (so the directory is /sys/bus/i2c/drivers/silabs-fm) while its `i2c_device_id` is
# `radio-silabs`; and `RADIO_NAME`/`DRIVER_NAME` = `radio-silabs` is ALSO the v4l2 device's name -- so
# `/sys/class/video4linux/radioN/name` reads `radio-silabs` while the directory is `radio0`. The node
# NUMBER is allocated (`RADIO_NR` is -1, i.e. the first free), so the number is a registration order and
# the `name` file is the identity -- the same trap as the writeback framebuffer's `mdssfb_280`.
# AND ONE DRIVER THAT CAN NEVER BIND THIS NODE: `drivers/media/radio/si470x/radio-si470x-i2c.c` declares
# `.name = "si470x"` and has NO `of_match_table` at all, so it cannot be matched from the device tree. A
# reader grepping for "si470" finds two drivers and only one of them can ever bind this node.
#
# WHAT THIS CANNOT SAY: whether FM radio works. An enabled node, a bound driver and a registered radio
# device are the software path being in place -- none of them is a station, and the chip is powered DOWN
# until something opens the device node.
#
# **Read-only, and it writes nothing at all** -- not even a scratch file, which is why the kernel log is
# captured into a shell variable. The two surfaces a reader is most tempted to touch are both called out
# above: `/dev/radioN` is never opened, and `/sys/class/video4linux/*/debug` is never written.
#
# Usage (on the device):
#   sh zl1-fm-radio-probe.sh             # every rung, then a verdict
#   sh zl1-fm-radio-probe.sh --quiet     # the verdict and the readings it rests on
#   sh zl1-fm-radio-probe.sh --explain   # what each reading decides, and why this reading
#
# Exit: 0 the node is enabled, the driver is bound and its radio device is registered;
#       1 the chain stops early -- the verdict names the rung;
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

# The verdict's inputs are declared before anything reads them: a shell function has no locals and an
# unset variable under `set -u` is a crash, which in a report looks like a finding.
NODE_EN=yes
CLIENT_FOUND=no
RADIO_FOUND=no
DRV_REG=no
DRV_BOUND=""
SRC_MATCH=yes
FATAL_MISSING=""
CLIENT_ADDR=""
V=""
VMSG=""

say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
hdr() { printf '\n== %s\n' "$*"; }
always() { printf '%s\n' "$*"; }

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
# NOTE THE `tr -d '\n'` BEFORE THE SANITIZER. `tr -c '[:print:]' '.'` replaces every byte that is not
# printable -- and a newline is not, so the line `sed -n 1p` just emitted would come back with a trailing
# dot: `ok` reads as `ok.` and every comparison against it silently misses.
dtstr() { # $1 = path
  if [ ! -r "$1" ]; then printf 'absent'; return; fi
  v=$(tr '\0' '\n' < "$1" 2>/dev/null | sed -n 1p | tr -d '\n' | LC_ALL=C tr -c '[:print:]' '.')
  printf '%s' "${v:-EMPTY}"
}
# Every string of a property, not just the first: a compatible list is a LIST, and reading only the first
# entry is how a property looks like it does not carry the entry you want.
dtlist() { # $1 = path
  if [ ! -r "$1" ]; then printf 'absent'; return; fi
  v=$(tr '\0' '\n' < "$1" 2>/dev/null | grep . | LC_ALL=C tr -c '[:print:]\n' '.' | tr '\n' ' ')
  printf '%s' "${v:-EMPTY}"
}
# A property rendered the way it can be read: the strings when its bytes are text, the CELLS when they are
# numbers. Handing a u32 property to the string reader prints control characters, which is a line nobody can
# use and which hides that the value is a number.
#
# THE TEST IS ON THE BYTES, and "all printable" is not enough on its own: a one-cell property like the
# i2c address is three NUL bytes and a `(`, which IS all-printable once the NULs are dropped. A
# device-tree STRING is NUL-TERMINATED and never carries two NULs in a row (an empty string does not
# occur), so the shape of a string property is: printable-or-NUL bytes, a NUL as the LAST byte, no two
# NULs adjacent, and at least one non-NUL byte.
dtprop() { # $1 = path
  if [ ! -r "$1" ]; then printf 'absent'; return; fi
  _pr_ok=1; _pr_nz=0; _pr_prev=999; _pr_last=999; _pr_n=0
  for _pr_x in $(od -An -tu1 "$1" 2>/dev/null); do
    _pr_n=$((_pr_n + 1))
    _pr_last=$_pr_x
    if [ "$_pr_x" = 0 ]; then
      [ "$_pr_prev" = 0 ] && _pr_ok=0
    else
      _pr_nz=$((_pr_nz + 1))
      { [ "$_pr_x" -lt 32 ] || [ "$_pr_x" -gt 126 ]; } && _pr_ok=0
    fi
    _pr_prev=$_pr_x
  done
  if [ "$_pr_ok" = 1 ] && [ "$_pr_last" = 0 ] && [ "$_pr_nz" -gt 0 ]; then
    printf '%s' "$(dtlist "$1")"
    return
  fi
  case "$_pr_n" in
  0) printf 'EMPTY (a boolean, no value)'; return ;;
  esac
  if [ $((_pr_n % 4)) != 0 ]; then printf '[%s bytes, not cells]' "$_pr_n"; return; fi
  _pr_i=1; _pr_out=""
  while [ "$_pr_i" -le $((_pr_n / 4)) ]; do
    _pr_out="$_pr_out $(dtcell "$1" "$_pr_i")"
    _pr_i=$((_pr_i + 1))
  done
  printf '[u32 cells:%s ]' "$_pr_out"
}
# A device-tree u32 is BIG-ENDIAN and this SoC is little-endian, so `od -tu4` on the file prints the value
# BYTE-SWAPPED -- an i2c address of 0x11 comes out as a number of the right shape and the wrong value. The
# four bytes are combined explicitly, and anything that is not exactly four bytes says so.
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
# CELL N of a property, 1-based, or `absent` if the property is shorter than that. A gpio cell and an
# interrupt cell are both read this way, and a property whose length is not a whole number of cells must
# not report a plausible value for its last one.
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
# How many cells a property is, or a named complaint when its length is not a whole number of them.
# A property the driver reads with `of_property_read_u32_array(..., 2)` is read as EXACTLY TWO CELLS:
# longer is truncated, shorter (or absent) fails and the caller gets -EINVAL.
dtcells() { # $1 = path
  if [ ! -r "$1" ]; then printf 'absent, 0 cells'; return; fi
  _dc_b=$(wc -c < "$1" 2>/dev/null | tr -d ' ')
  case "$_dc_b" in '' | *[!0-9]*) printf 'unreadable'; return ;; esac
  if [ $((_dc_b % 4)) != 0 ]; then printf '[%s bytes, not cells]' "$_dc_b"; return; fi
  printf '%s cells' $((_dc_b / 4))
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
  # The known node shapes for a kernel without find(1). This block's node sits UNDER an i2c controller, so
  # the fallback walks the shapes rather than a list -- a node one level deeper is exactly what this scan
  # exists to survive.
  # `-d` and not `-e`: `/proc/device-tree/*` also matches the root's own PROPERTIES (`model`,
  # `compatible`), which are files -- and counting those as "nodes exist here" is how this fallback would
  # report "I searched and found nothing" on a tree it never actually searched.
  for _nc_p in /proc/device-tree/soc/* /proc/device-tree/soc/*/* /proc/device-tree/soc/*/*/* \
    /proc/device-tree/soc/*/*/*/* /proc/device-tree/*; do
    [ -d "$_nc_p" ] || continue
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
# Resolve a phandle to the node that carries it, and the node's LABEL when it has one. Every one of this
# node's cells is a phandle to a gpio controller, an interrupt controller or a regulator, and printing the
# raw number would leave the reader to guess -- and the number is not the identity: a miss here is
# `unresolved`, and two nodes carrying the same phandle is `AMBIGUOUS(N)`. But the SAME node can carry the
# same phandle TWICE -- as `phandle` and as the older `linux,phandle`, which every node on this board does
# -- and counting matches rather than NODES would call that one node ambiguous with itself.
phandle_node() { # $1 = phandle number; prints a path, or "AMBIGUOUS(N)", or "unresolved"
  _ph_hits=0; _ph_first=""; _ph_seen=" "
  if type find >/dev/null 2>&1; then
    for _ph_f in $(find /proc/device-tree -name phandle -o -name linux,phandle 2>/dev/null); do
      [ -r "$_ph_f" ] || continue
      [ "$(dtu32 "$_ph_f")" = "$1" ] || continue
      _ph_dir=$(dirname "$_ph_f")
      case "$_ph_seen" in *" $_ph_dir "*) continue ;; esac
      _ph_seen="$_ph_seen$_ph_dir "
      _ph_hits=$((_ph_hits + 1))
      [ -z "$_ph_first" ] && _ph_first="$_ph_dir"
    done
  else
    # A phandle that CANNOT be resolved and one that is NOT THERE are different facts, and an empty
    # string would print as the second without saying so.
    printf 'unresolved (no find(1) here to look it up with)'
    return
  fi
  case "$_ph_hits" in
  0) printf 'unresolved'; return ;;
  1) : ;;
  *) printf 'AMBIGUOUS(%s)' "$_ph_hits"; return ;;
  esac
  # The LABEL when the node has one, and the REGULATOR's own name when it has one of those: on this board
  # the two supplies are told apart by `rome_vreg` and `pm8994_s4`, and a bare path would leave a reader to
  # work out which is which.
  _ph_lbl=$(dtstr "$_ph_first/label")
  case "$_ph_lbl" in absent | EMPTY) _ph_lbl=$(dtstr "$_ph_first/regulator-name") ;; esac
  case "$_ph_lbl" in
  absent | EMPTY) printf '%s' "${_ph_first#/proc/device-tree}" ;;
  *) printf '%s (label %s)' "${_ph_first#/proc/device-tree}" "$_ph_lbl" ;;
  esac
}
# THE PATH WITHOUT THE LABEL. `phandle_node` prints a path AND the node's label, because a reader wants
# `rome_vreg` rather than a bare path -- but a caller that then OPENS the path needs the path alone, and
# `${...%% (label *}` is what separates the two. Reading `.../rome_vreg (label rome_vreg)/compatible` would
# report every property of a labelled regulator as absent, which is a reading of the wrong node rather than
# of no node.
phandle_path() { # $1 = phandle number; prints a path, or the same words phandle_node can
  _pp_n=$(phandle_node "$1")
  case "$_pp_n" in
  *" (label "*) printf '%s' "${_pp_n%% (label *}" ;;
  *) printf '%s' "$_pp_n" ;;
  esac
}
# A property whose every cell is a phandle (a pinctrl state), resolved cell by cell. The pinmux state
# groups on this board are NAMED for this block -- `pmx_fm_int`, `pmx_fm_status` and `pmx_fm_rst` -- so
# they are a reading about the block rather than decoration, and a single-cell read of a three-cell
# property would have printed one of them as if it were the whole state.
phandle_list() { # $1 = path
  if [ ! -r "$1" ]; then printf 'absent'; return; fi
  _pl_b=$(wc -c < "$1" 2>/dev/null | tr -d ' ')
  case "$_pl_b" in '' | *[!0-9]*) printf 'not-a-list(%s)' "${_pl_b:-?}"; return ;; esac
  if [ $((_pl_b % 4)) != 0 ]; then printf 'not-a-list(%s bytes)' "$_pl_b"; return; fi
  _pl_n=$((_pl_b / 4)); _pl_i=1; _pl_out=""
  while [ "$_pl_i" -le "$_pl_n" ]; do
    _pl_out="$_pl_out, $(phandle_node "$(dtcell "$1" "$_pl_i")")"
    _pl_i=$((_pl_i + 1))
  done
  printf '%s' "${_pl_out#, }"
}
# A gpio property as the driver would read it: a phandle, a pin number and a flag cell.
gpio_cells() { # $1 = path
  if [ ! -r "$1" ]; then printf 'absent'; return; fi
  # A gpio property is WHOLE cells. A length that is not a multiple of four is not a gpio description, and
  # reading the first three bytes of four would print a number of the right shape and the wrong value.
  _g_bytes=$(wc -c < "$1" 2>/dev/null | tr -d ' ')
  if [ -z "$_g_bytes" ] || [ $((_g_bytes % 4)) != 0 ]; then
    printf 'not-a-gpio(%s bytes)' "${_g_bytes:-?}"
    return
  fi
  _g_p=$(dtcell "$1" 1); _g_n=$(dtcell "$1" 2); _g_f=$(dtcell "$1" 3)
  case "$_g_p" in absent) printf 'not-a-gpio(no cells)'; return ;; esac
  case "$_g_f" in
  1) _g_pol="active low (GPIO_ACTIVE_LOW)" ;;
  0) _g_pol="active high" ;;
  absent) _g_pol="no flag cell" ;;
  *) _g_pol="flag $_g_f" ;;
  esac
  printf 'phandle %s = %s, gpio %s, %s' "$_g_p" "$(phandle_node "$_g_p")" "$_g_n" "$_g_pol"
}
# The driver that MATCHES a compatible, straight out of the kernel source -- each line is
# "driver-name<TAB>config-option<TAB>source-file<TAB>bus<TAB>how-it-matches". A compatible with no match
# prints `none`, which is a reading (a node nothing can bind) and not an error.
#
# THE NAME THIS PRINTS IS THE ONE SYSFS KEYS ON, and for this block that is worth spelling out: the
# compatible is `silabs,si4705`, the i2c driver's `.name` is `silabs-fm` (so the directory is
# /sys/bus/i2c/drivers/silabs-fm), its `i2c_device_id` is `radio-silabs`, and `radio-silabs` is ALSO the
# name of the v4l2 device it registers -- so four names, and only the second is an i2c path in sysfs.
# AND THE DRIVER BESIDE IT CAN NEVER BIND: `si470x` declares no `of_match_table` at all, so it is listed
# here as the thing a reader would find if they grepped for `si470` and stopped at the first hit.
drivers_for() { # $1 = compatible
  case "$1" in
  silabs,si4705)
    printf 'silabs-fm\tCONFIG_RADIO_SILABS\tdrivers/media/radio/silabs/radio-silabs.c\ti2c\tby of_match "silabs,si4705" (its i2c_device_id is "radio-silabs" and its VIDEO DEVICE is also named "radio-silabs")\n'
    ;;
  qcom,i2c-msm-v2)
    printf 'i2c-msm-v2\tCONFIG_I2C_MSM_V2\tdrivers/i2c/busses/i2c-msm-v2.c\tplatform\tby of_match "qcom,i2c-msm-v2" (the bus this node sits on)\n'
    ;;
  *) printf 'none\t-\t-\t-\t-\n' ;;
  esac
}
# The drivers that CLAIM this chip's name and cannot bind it, printed where the block is read. This is not
# a list of alternatives: it is the shape of the mistake (a grep for `si470` finds two files).
near_miss_driver() {
  printf 'si470x\tdrivers/media/radio/si470x/radio-si470x-i2c.c\tNO of_match_table at all -- cannot be matched from a device tree\n'
}
# Is a driver REGISTERED? /sys/bus/<bus>/drivers/<name> exists exactly when it registered, so this is the
# device's own answer and not an inference from a list.
drv_registered() { # $1 = bus, $2 = driver name; prints yes/no
  [ -d "/sys/bus/$1/drivers/$2" ] && printf 'yes' || printf 'no'
}
# Is anything BOUND to it? The symlinks beside bind/unbind/uevent are the devices that were PROBED.
drv_bound() { # $1 = bus, $2 = driver name; prints a space-separated list, or empty
  _db_out=""
  for _db_b in "/sys/bus/$1/drivers/$2"/*; do
    [ -e "$_db_b" ] || continue
    case "$(basename "$_db_b")" in bind | unbind | uevent | module) continue ;; esac
    _db_out="$_db_out $(basename "$_db_b")"
  done
  printf '%s' "$_db_out"
}
# The driver row for ONE node: the same three lines the scan loop prints, for the nodes this block owns but
# the scan does not look for (the i2c controller the node sits on). It exists because the matching in
# `drivers_for` is what carries the config option that decides this block, and a match nothing calls prints
# nothing.
node_driver_row() { # $1 = compatible
  _ndr=$(drivers_for "$1")
  _ndn=$(printf '%s' "$_ndr" | cut -f1); _ndc=$(printf '%s' "$_ndr" | cut -f2)
  _ndf=$(printf '%s' "$_ndr" | cut -f3); _ndb=$(printf '%s' "$_ndr" | cut -f4)
  _ndh=$(printf '%s' "$_ndr" | cut -f5)
  if [ "$_ndn" = none ]; then
    always "     driver:      NONE in this kernel source matches '$1' -- nothing can ever bind it, under"
    always "                  any config"
    return 0
  fi
  _ndbd=$(drv_bound "$_ndb" "$_ndn")
  always "     driver:      $_ndn  ($_ndf, $_ndb, $_ndh)"
  always "       registered: $(drv_registered "$_ndb" "$_ndn")   bound: $( [ -n "$_ndbd" ] && printf '%s' "${_ndbd# }" || printf 'NONE' )   config $_ndc: $(cfg_opt "$_ndc")"
}
# The regulator a supply property points at, read the way this block's driver reads it. This is worth its
# own helper because BOTH halves are readings: the phandle names the regulator, and the regulator's own
# node says whether it is a fixed gpio switch or an RPM-controlled rail -- and on this board the two
# supplies are one of each.
supply_row() { # $1 = the supply property path, $2 = the property name the driver reads the voltage from
  _sr_p=$(dtcell "$1" 1)
  case "$_sr_p" in
  absent | '') always "     $(printf '%-26s' "$(basename "$1")") absent -- the driver's regulator_get() fails and, for BOTH"
    always "       supplies, that is not fatal (see the note below)."
    return 0 ;;
  esac
  _sr_node=$(phandle_node "$_sr_p")
  always "     $(printf '%-26s' "$(basename "$1")") phandle $_sr_p = $_sr_node"
  case "$_sr_node" in
  unresolved | AMBIGUOUS* | 'unresolved (no find'*) return 0 ;;
  esac
  _sr_path="/proc/device-tree$(phandle_path "$_sr_p")"
  _sr_comp=$(dtstr "$_sr_path/compatible")
  _sr_name=$(dtstr "$_sr_path/regulator-name")
  _sr_status=$(dtstr "$_sr_path/status")
  _sr_volt=$(dtprop "$_sr_path/regulator-min-microvolt")
  always "       compatible: $(printf '%-24s' "$_sr_comp") regulator-name: $_sr_name"
  case "$_sr_status" in
  absent | EMPTY) always "       status:     absent (an absent status means enabled; a regulator carries none)" ;;
  *) always "       status:     $_sr_status" ;;
  esac
  case "$_sr_comp" in
  regulator-fixed)
    # A FIXED regulator is a gpio switch: the chip's analog rail on this board is not a PMIC rail at all,
    # it is a PMIC GPIO driving a fixed supply -- so powering the chip means driving that pin.
    always "       A FIXED REGULATOR, i.e. a GPIO SWITCH RATHER THAN A RAIL: gpio = $(gpio_cells "$_sr_path/gpio")"
    _sr_ah=$(dtstr "$_sr_path/enable-active-high")
    case "$_sr_ah" in
    EMPTY) always "       enable-active-high is PRESENT (a boolean), so the pin drives the supply ON when high" ;;
    absent) always "       enable-active-high is ABSENT, so the pin is active LOW" ;;
    *) always "       enable-active-high = $_sr_ah" ;;
    esac
    _sr_delay=$(dtu32 "$_sr_path/startup-delay-us")
    case "$_sr_delay" in
    absent) always "       (no startup-delay-us)" ;;
    *) always "       startup-delay-us: $_sr_delay -- the driver must wait that long after enabling it" ;;
    esac
    ;;
  qcom,rpm-smd-regulator)
    always "       AN RPM-CONTROLLED RAIL: min $(printf '%s' "$_sr_volt") uV, and the RPM, not the CPU, owns the"
    always "       voltage -- so this supply cannot be checked by asking the SoC."
    ;;
  *) always "       (a regulator kind this probe does not know: $_sr_comp)" ;;
  esac
  always "       the driver reads $(basename "$2") as EXACTLY TWO CELLS: $(dtcells "$2") there."
  case "$(dtcells "$2")" in
  '2 cells') always "                      and this tree has exactly that, so within_voltage_votes is filled." ;;
  absent*) always "                      ABSENT, and that is FATAL for this supply: of_property_read_u32_array()"
    always "                      fails, silabs_dt_parse_vreg_info() returns -EINVAL, and probe() goes to its"
    always "                      error path." ;;
  *) always "                      AND THIS IS NOT TWO CELLS: the read is EXACTLY two, so a longer property is"
    always "                      TRUNCATED and a shorter one FAILS the -EINVAL check -- a value that looks"
    always "                      right and a supply the driver refuses are the same line here." ;;
  esac
}

if [ "$MODE" = explain ]; then
  cat <<'EOF'
zl1 FM radio probe -- what each reading decides, and why it is this reading

  1. THE TREE SWITCHES THIS NODE OFF. `/soc/i2c@75b5000/silabs4705@11` (`silabs,si4705`) carries
     `status = "disabled"` in all 15 LE_ZL1 trees and in all three sets. Every other block this project has
     instrumented carries NO status at all, which the device tree reads as ENABLED -- this one is the
     exception, and it runs the other way. The i2c core never instantiates a node that is not okay, so
     there is no client, no bind and no radio device, whatever the kernel was built with.

  2. AND THE OBVIOUS EXPLANATION IS WRONG. `CONFIG_RADIO_SILABS=y` in BOTH kernels in hand -- the vendor
     3.18.120 kernel AND the v63 Halium 3.18.140 kernel this port boots. So the driver IS built on the
     device and the tree is what refuses the node. This is the mirror image of the `nfc` block, whose
     option sits outside the menu that gates it and is off in the shipping kernel.

  3. THIS OPTION IS GATED BY ITS MENU. `config RADIO_SILABS` sits INSIDE `if RADIO_ADAPTERS && VIDEO_V4L2`,
     and `RADIO_ADAPTERS` is a menuconfig depending on `VIDEO_V4L2` and `MEDIA_RADIO_SUPPORT`. The probe
     prints the whole chain, because "the option is not set" has four possible parents here.

  4. THE NODE DESCRIBES ITS INTERRUPTS TWICE, THROUGH DIFFERENT MECHANISMS. `interrupts = <0 1>` with an
     `interrupt-map` that routes child interrupt 0 to TLMM gpio 38 and child interrupt 1 to TLMM gpio 78 --
     the SAME two pins the driver reads as `silabs,int-gpio` and `silabs,status-gpio`. The driver ignores
     the interrupt-map and calls gpio_to_irq() on its own gpios.

  5. THREE GPIOS, TWO FATAL, AND TWO REGULATORS, NEITHER FATAL. `silabs,reset-gpio` is fatal in the
     strongest way (the probe returns the gpio's own negative errno), `silabs,int-gpio` is fatal, and
     `silabs,status-gpio` is optional. The supplies are the reverse: a failed `regulator_get("va")` only
     defers or skips, and a failed `regulator_get("vdd")` prints and continues.

  6. THE WRITE-CLASS MOVE IS OPENING THE DEVICE. `silabs_fm_fops_open()` powers the chip up: both
     regulators, the pinctrl active state, the gpios -- and the first ioctl writes real commands over i2c.
     AND the v4l2 core puts ONE WRITABLE attribute on every radio device:
     `/sys/class/video4linux/radioN/debug` is `DEVICE_ATTR_RW(debug)`, a verbosity knob. The probe writes
     neither and opens no device node.

  AND FOUR NAMES, ONE OF WHICH IS IN /dev: the compatible `silabs,si4705`; the i2c driver `.name`
  `silabs-fm` (the only sysfs path); the i2c_device_id `radio-silabs`; and the v4l2 device name
  `radio-silabs`, which is what `/sys/class/video4linux/radioN/name` reads while the directory is `radio0`.
  The NUMBER is allocated (`RADIO_NR` is -1), so it is a registration order and the `name` file is the
  identity. And `si470x`, the driver beside it, has no of_match_table at all: it can never bind this node.

  WHAT THIS CANNOT SAY: whether FM radio works. An enabled node, a bound driver and a registered radio
  device are the software path in place -- and the chip is powered DOWN until something opens the node.
EOF
  exit 0
fi

# The device-tree guard comes after the explain page on purpose: `--explain` reads nothing, and refusing it
# on a machine with no device tree would make the page that says what the probe reads unreachable exactly
# where a reader would want it.
[ -d /proc/device-tree ] ||
  { echo "no /proc/device-tree here -- refusing (this probe reads the device tree)" >&2; exit 2; }

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
  always "               carries both boards' trees, and the FM node is at the same path in both -- so the"
  always "               tree's shape cannot tell you whose reading this is, and only 'model' can."
  ;;
unknown)
  always "   board:      UNKNOWN -- /proc/device-tree/model could not be read, so which board's tree this is"
  always "               cannot be told from here. The readings below are still taken, and this is named in"
  always "               the verdict rather than being silently assumed to be a zl1."
  ;;
*) always "   board:      neither LE_ZL1 nor LE_X2 -- nothing below can be attributed to this phone" ;;
esac

# --- 2. the kernel's own config, read BEFORE the sections that ask about it -------------------------
#
# This has to come first: the driver section asks whether the option that builds the driver is set -- and a
# shell function is only defined once its definition has EXECUTED, so defining `cfg_opt` below the caller
# would fail at every call.
#
# CONFIG_IKCONFIG_PROC=y in the flashed image, so the RUNNING kernel can be asked rather than a static list
# being trusted. Reading it needs a decompressor, and a device with neither zcat(1) nor gunzip(1) is a state
# this probe NAMES rather than turning into "the option is off": a config that could not be read and a
# config that says `# ... is not set` are different facts, and only one of them is a verdict.
CFG_SRC=""
CFG_TEXT=""
if [ -r /proc/config.gz ]; then
  if type zcat >/dev/null 2>&1 && CFG_TEXT=$(zcat /proc/config.gz 2>/dev/null) && [ -n "$CFG_TEXT" ]; then
    CFG_SRC="zcat /proc/config.gz"
  elif type gunzip >/dev/null 2>&1 && CFG_TEXT=$(gunzip -c /proc/config.gz 2>/dev/null) && [ -n "$CFG_TEXT" ]; then
    CFG_SRC="gunzip -c /proc/config.gz"
  fi
fi
cfg_opt() { # $1 = option name; prints y / m / NOT SET / absent / NOT READ
  if [ -z "$CFG_SRC" ]; then printf 'NOT READ'; return; fi
  case "$(printf '%s\n' "$CFG_TEXT" | grep -E "^$1=|^# $1 is not set$")" in
  "$1=y") printf 'y (built in)' ;;
  "$1=m") printf 'm (module -- it needs a .ko in the rootfs)' ;;
  "# $1 is not set") printf 'NOT SET' ;;
  *) printf 'absent from the config' ;;
  esac
}

# --- 3. the node the device tree declares ----------------------------------------------------------
hdr "the FM node the device tree declares"
NODES=""
NC_RC=0
NC_OUT=$(nodes_with silabs,si4705); _rc=$?
[ "$_rc" = 2 ] && NC_RC=2
NODES="$NC_OUT"
N_NODES=0
[ -n "$NODES" ] && N_NODES=$(printf '%s\n' $NODES | grep . | wc -l | tr -d ' ')

NODE=""
I2C_PARENT=""
I2C_ADDR=""
CLIENT_NAME=""
CLIENT_ADDR=""
I2C_ALIAS=""
if [ "$NC_RC" = 2 ]; then
  DT_RUNG=unscanned
  always ""
  always "   the device tree could not be searched for 'silabs,si4705' at all: find(1) is missing AND no"
  always "   known node shape exists. This is NOT 'the tree declares no FM receiver' -- it is 'this probe"
  always "   could not look', and the two must not print the same way."
elif [ -z "$NODES" ]; then
  DT_RUNG=no-node
  always ""
  always "   no node in this device tree carries 'silabs,si4705' -- the running tree declares no FM receiver"
  always "   at all. The path is not assumed: the whole tree is scanned."
else
  DT_RUNG=node
  always ""
fi

if [ "$DT_RUNG" = node ]; then
  NODE=$(printf '%s\n' $NODES | grep . | sed -n 1p)
  [ "$N_NODES" != 1 ] && always "   ($N_NODES nodes carry this compatible; the first is read below)"
  I2C_PARENT=$(dirname "$NODE")
  always "   ${NODE#/proc/device-tree}"
  always "     compatible:  $(dtlist "$NODE/compatible")"
  ST=$(dtstr "$NODE/status")
  # AND HERE THE ABSENT CASE IS THE ONE THAT DOES NOT APPLY. Every other block this project has read
  # carries no `status` at all, which the device tree reads as ENABLED; this node carries `disabled`, in
  # every one of its 15 trees, in every set. So the answer is the opposite of the usual one, and the probe
  # prints the value it read rather than a yes/no.
  case "$ST" in
  okay | ok | EMPTY | absent) NODE_EN=yes ;;
  *) NODE_EN=no ;;
  esac
  case "$ST" in
  absent) always "     status:      absent (an absent status means enabled; this node carries none)" ;;
  disabled | fail | reserved)
    always "     status:      $ST"
    always "                  AND THIS IS THE WHOLE ANSWER FOR THIS BLOCK. The device tree switches its own FM"
    always "                  receiver OFF, so the i2c core never instantiates the client: no driver can bind,"
    always "                  no radio device is registered, and NO BUILD OPTION CAN CHANGE THAT. Every other"
    always "                  node this project has instrumented declares no status at all -- which the device"
    always "                  tree reads as enabled -- and this one is the exception, running the other way."
    ;;
  *) always "     status:      $ST" ;;
  esac
  say "     other properties on this node:"
  for _p in "$NODE"/*; do
    [ -r "$_p" ] || continue
    _bn=$(basename "$_p")
    case "$_bn" in compatible | status) continue ;; esac
    _sz=$(wc -c < "$_p" 2>/dev/null | tr -d ' ')
    case "$_sz" in
    0) say "       $(printf '%-26s' "$_bn") (a boolean, no value)" ;;
    *) say "       $(printf '%-26s' "$_bn") $(dtprop "$_p")" ;;
    esac
  done
  # THE GPIOS THE DRIVER READS, EACH WITH WHAT HAPPENS IF IT IS MISSING. The ordering is the driver's own
  # in silabs_parse_dt(), and the split is not the same as the NFC block's: there the FIRST two were fatal
  # and the last two lenient; here the first two are fatal and only the third is lenient.
  always ""
  always "   the three gpios silabs_parse_dt() reads, and what a MISSING one does:"
  always "     silabs,reset-gpio  $(gpio_cells "$NODE/silabs,reset-gpio")"
  always "                        FATAL IN THE STRONGEST WAY: the driver returns the GPIO'S OWN NEGATIVE"
  always "                        ERRNO, so probe() fails with -ENODEV or -EINVAL from of_get_named_gpio()"
  always "                        rather than from a decision of its own."
  always "     silabs,int-gpio    $(gpio_cells "$NODE/silabs,int-gpio")"
  always "                        FATAL, the same way. This is the pin the driver turns into an IRQ at OPEN"
  always "                        time with gpio_to_irq() -- not the interrupt the tree routes below."
  always "     silabs,status-gpio $(gpio_cells "$NODE/silabs,status-gpio")"
  always "                        OPTIONAL: a missing one is a FMDERR and the driver carries on with"
  always "                        status_gpio at 0, which later code tests with '> 0'."
  # WHICH OF THE READS THE TREE IS MISSING OR INVALID ON. This is a fact about the TREE, and the verdict
  # for a driver that did not bind is more useful when it carries it: a missing reset gpio is enough on its
  # own, and so is a voltage property that is not exactly two cells.
  FATAL_MISSING=""
  case "$(gpio_cells "$NODE/silabs,reset-gpio")" in
  absent | not-a-gpio*) FATAL_MISSING="$FATAL_MISSING silabs,reset-gpio" ;;
  esac
  case "$(gpio_cells "$NODE/silabs,int-gpio")" in
  absent | not-a-gpio*) FATAL_MISSING="$FATAL_MISSING silabs,int-gpio" ;;
  esac
  for _fv in "silabs,va-supply-voltage" "silabs,vdd-supply-voltage"; do
    if [ -r "$NODE/$_fv" ]; then
      case "$(dtcells "$NODE/$_fv")" in
      '2 cells') : ;;
      *) FATAL_MISSING="$FATAL_MISSING $_fv ($(dtcells "$NODE/$_fv"))" ;;
      esac
    fi
  done
  always ""
  always "   the tree on the FATAL reads:${FATAL_MISSING:- NONE MISSING -- the two fatal gpios are present and valid}"
  case "$FATAL_MISSING" in
  '') : ;;
  *) always "     (each of these fails silabs_parse_dt() or silabs_dt_parse_vreg_info(), so the driver is"
     always "      refused the node or the supply whatever the config says.)" ;;
  esac
  # The interrupt described twice, through two mechanisms.
  always ""
  always "   the interrupts, DESCRIBED TWICE AND THROUGH DIFFERENT MECHANISMS:"
  always "     interrupts       $(dtprop "$NODE/interrupts")   interrupt-names: $(dtprop "$NODE/interrupt-names")"
  always "     interrupt-parent $(dtprop "$NODE/interrupt-parent")"
  always "     interrupt-map    $(dtprop "$NODE/interrupt-map")"
  always "                      flag 2 = IRQ_TYPE_EDGE_FALLING, flag 1 = IRQ_TYPE_EDGE_RISING, and the phandle"
  always "                      in each entry is the TLMM gpio controller -- so the map routes this node's two"
  always "                      interrupts to the SAME TWO PINS the driver reads as its own gpios. THE DRIVER"
  always "                      ACTS ON NEITHER: it ignores interrupt-map and calls gpio_to_irq() on"
  always "                      silabs,int-gpio (and, if present, silabs,status-gpio). A reading that quoted"
  always "                      'interrupts' as the FM interrupts would be quoting a description nothing uses."
  # The supplies. Two, one of each kind, and neither fatal -- but the voltage property beside them is read
  # as EXACTLY TWO CELLS, so that half IS fatal.
  always ""
  always "   the two supplies the driver asks for (regulator_get(\"va\") / regulator_get(\"vdd\")):"
  supply_row "$NODE/va-supply" "$NODE/silabs,va-supply-voltage"
  supply_row "$NODE/vdd-supply" "$NODE/silabs,vdd-supply-voltage"
  always "     AND NEITHER regulator IS FATAL, WHICH IS THE OPPOSITE OF THE GPIOS ABOVE: a failed"
  always "     regulator_get(\"va\") only DEFERS the probe (-EPROBE_DEFER) or is skipped, and a failed"
  always "     regulator_get(\"vdd\") prints 'vdd supply is not provided' and carries on. But the VOLTAGE"
  always "     PROPERTY beside each one IS read as exactly two cells, so a tree that names a supply and then"
  always "     writes an odd voltage property fails the probe -- at a different point, for a different reason."
  # The pinmux state groups, named for this block.
  say ""
  say "       pinctrl-names: $(dtprop "$NODE/pinctrl-names")"
  always "       pinctrl-0 (the ACTIVE state):  $(phandle_list "$NODE/pinctrl-0")"
  always "       pinctrl-1 (the suspend state): $(phandle_list "$NODE/pinctrl-1")"
  always "                   and the driver LOOKS UP THESE TWO NAMES BY STRING: silabs_fm_pinctrl_init() does"
  always "                   pinctrl_lookup_state(..., \"pmx_fm_active\") and (..., \"pmx_fm_suspend\"), which are"
  always "                   exactly the two names above. A tree that spelled them differently would leave the"
  always "                   driver with no pinctrl at all -- and that is NOT fatal either: a -EINVAL there is"
  always "                   turned into success."
  # The bus.
  always ""
  always "   the i2c bus this node sits on:"
  always "     ${I2C_PARENT#/proc/device-tree}"
  always "       compatible: $(dtlist "$I2C_PARENT/compatible")"
  _bst=$(dtstr "$I2C_PARENT/status")
  case "$_bst" in
  absent) always "       status:     absent (an absent status means enabled; this controller carries none)" ;;
  *) always "       status:     $_bst" ;;
  esac
  for _a in /proc/device-tree/aliases/*; do
    [ -r "$_a" ] || continue
    [ "$(dtstr "$_a")" = "${I2C_PARENT#/proc/device-tree}" ] || continue
    I2C_ALIAS=$(basename "$_a")
  done
  I2C_ADDR=$(dtu32 "$NODE/reg")
  case "$I2C_ADDR" in
  absent | not-a-u32* | '') always "       reg:        $I2C_ADDR -- the i2c address is what makes this node a client at all" ;;
  *)
    CLIENT_ADDR=$(printf '%04x' "$I2C_ADDR")
    say "       reg:        $I2C_ADDR (0x$(printf '%x' "$I2C_ADDR")) -- the i2c slave address, written"
    say "                   '$CLIENT_ADDR' in a client's sysfs name"
    case "$I2C_ALIAS" in
    i2c[0-9]*)
      _busnum=${I2C_ALIAS#i2c}
      CLIENT_NAME="${_busnum}-$CLIENT_ADDR"
      always "       alias:      $I2C_ALIAS -> bus $_busnum, so the i2c core will name the client"
      always "                   '$CLIENT_NAME' -- and THAT name is what the witness section looks for."
      ;;
    *)
      always "       alias:      none points at this controller, so the BUS NUMBER cannot be read from the"
      always "                   tree -- and a client's sysfs name is built from the bus number, so no name can"
      always "                   be derived here. This probe looks for the ADDRESS instead, and lists what is"
      always "                   actually there."
      ;;
    esac
    ;;
  esac
  # The same bus carries another block. A probe that reported "what is on this bus" as one device would
  # conflate two of doc 137's rows.
  _others=""
  for _o in "$I2C_PARENT"/*; do
    [ -d "$_o" ] || continue
    [ "$_o" = "$NODE" ] && continue
    _oc=$(dtstr "$_o/compatible")
    [ "$_oc" = absent ] && continue
    _others="$_others ${_o##*/}($_oc)"
  done
  if [ -n "$_others" ]; then
    always "       AND THIS BUS CARRIES ANOTHER BLOCK TOO:$_others"
    always "                   so 'what is on this bus' is not one device, and a probe that listed the bus and"
    always "                   called it the FM radio would be conflating two rows of the gap list."
  fi
  node_driver_row "$(dtstr "$I2C_PARENT/compatible")"
fi

# --- 4. the driver, and the config chain that decides this block ------------------------------------
hdr "the driver this block needs"
DRV=$(drivers_for silabs,si4705)
DN=$(printf '%s' "$DRV" | cut -f1)
DC=$(printf '%s' "$DRV" | cut -f2)
DF=$(printf '%s' "$DRV" | cut -f3)
DB=$(printf '%s' "$DRV" | cut -f4)
DH=$(printf '%s' "$DRV" | cut -f5)
if [ "$DN" = none ]; then
  SRC_MATCH=none
  always "   NO DRIVER IN THIS KERNEL SOURCE MATCHES 'silabs,si4705' -- nothing can bind this node under any"
  always "   config, so no config line can fix it."
else
  SRC_MATCH=yes
  always "   driver:      $DN   ($DF, $DB)"
  always "                $DH"
  always "                built by $DC -- and the chain that gates THAT is printed below."
fi
always "   AND THE DRIVER BESIDE IT CAN NEVER BIND THIS NODE, which is the mistake this line exists to stop:"
NM=$(near_miss_driver)
always "     $(printf '%s' "$NM" | cut -f1)  $(printf '%s' "$NM" | cut -f2)"
always "       $(printf '%s' "$NM" | cut -f3)"
always "     A reader who grepped for 'si470' would find two files and could reasonably pick the wrong one."
_cg_e=no; [ -e /proc/config.gz ] && _cg_e=yes
_cg_r=no; [ -r /proc/config.gz ] && _cg_r=yes
_cg_d=no; [ -n "$CFG_SRC" ] && _cg_d=yes
always "   /proc/config.gz: $_cg_e present / $_cg_r permission-readable / $_cg_d expanded"
[ -n "$CFG_SRC" ] && say "   source:      $CFG_SRC"
always ""
always "   the CHAIN that gates the option, per the kernel's own config -- and it is a real chain here:"
always "     CONFIG_MEDIA_RADIO_SUPPORT   $(cfg_opt CONFIG_MEDIA_RADIO_SUPPORT)"
always "     CONFIG_VIDEO_V4L2            $(cfg_opt CONFIG_VIDEO_V4L2)"
always "     CONFIG_RADIO_ADAPTERS        $(cfg_opt CONFIG_RADIO_ADAPTERS)"
always "     CONFIG_RADIO_SILABS          $(cfg_opt CONFIG_RADIO_SILABS)"
always ""
if [ -n "$CFG_SRC" ]; then
  always "   AND THIS OPTION IS GATED BY ITS MENU, UNLIKE THE ONE IN THE BLOCK NEXT DOOR. In"
  always "   drivers/media/radio/Kconfig, 'config RADIO_SILABS' sits INSIDE 'if RADIO_ADAPTERS && VIDEO_V4L2',"
  always "   and RADIO_ADAPTERS is itself a menuconfig that depends on VIDEO_V4L2 and MEDIA_RADIO_SUPPORT."
  always "   That is the ordinary shape -- every parent in the chain has to be on, which is why four lines are"
  always "   printed rather than one. (The \`nfc\` block is the exception: 'config NFC_NQ' sits AFTER the"
  always "   endmenu of the menu that depends on NFC, so its only parent is I2C. A probe for one block that"
  always "   assumed the other's shape would read the wrong line in both.)"
  always ""
  always "   AND ON THIS BOARD THE WHOLE CHAIN IS ON -- in BOTH kernels this project has in hand: the vendor"
  always "   boot image's 3.18.120 kernel AND the v63 Halium 3.18.140 kernel this port boots both carry"
  always "   'CONFIG_RADIO_SILABS=y'. So the tempting explanation for this block -- 'the driver is not built'"
  always "   -- is WRONG, and no build option would change anything: the device tree refuses the node."
else
  always "   -- the kernel config could NOT be read: either the file is not there, or it is there and this"
  always "      device has neither zcat(1) nor gunzip(1) to expand it, or it could not be read at all. The"
  always "      four columns above are therefore NOT READ -- which is a third state, and not 'the option is"
  always "      off'. The driver directory in sysfs needs no decompressor, so the verdict below rests on it and"
  always "      NOT on the config."
fi
always ""
always "   the driver directory itself (a directory appears exactly when the driver registered):"
_dir="/sys/bus/$DB/drivers/$DN"
if [ "$DN" != none ] && [ -d "$_dir" ]; then
  _b=$(drv_bound "$DB" "$DN")
  DRV_REG=yes
  DRV_BOUND=$(printf '%s' "${_b# }")
  always "     $_dir: present, bound: $( [ -n "$_b" ] && printf '%s' "${_b# }" || printf 'NONE' )"
else
  DRV_REG=no
  DRV_BOUND=""
  always "     $_dir: ABSENT (the driver did not register)"
fi
say "     (the driver's .name is '$DN'; its i2c_device_id is 'radio-silabs', which is what a non-DT match"
say "      would key on, and it is NOT a path in sysfs)"

# --- 5. the runtime traces the chain leaves behind --------------------------------------------------
hdr "the runtime traces this chain leaves behind"
# The FIRST witness: the i2c client. The core creates it from the device tree as soon as the adapter
# registers -- but ONLY for a node whose status is okay, which is precisely why this block's first witness
# is the one that fails here.
CLIENT_FOUND=no
CLIENT_WHY=""
CLIENT_ACTUAL=""
if [ -n "$CLIENT_ADDR" ]; then
  if [ -n "$CLIENT_NAME" ] && [ -e "/sys/bus/i2c/devices/$CLIENT_NAME" ]; then
    CLIENT_FOUND=yes; CLIENT_WHY=derived; CLIENT_ACTUAL="$CLIENT_NAME"
  else
    for _d in /sys/bus/i2c/devices/*-"$CLIENT_ADDR"; do
      [ -e "$_d" ] || continue
      CLIENT_FOUND=yes; CLIENT_WHY=address; CLIENT_ACTUAL="$(basename "$_d")"
    done
  fi
fi
if [ "$CLIENT_FOUND" = yes ]; then
  always "   1. the i2c client /sys/bus/i2c/devices/$CLIENT_ACTUAL: PRESENT"
  case "$CLIENT_WHY" in
  derived) always "      and it is under EXACTLY the name derived above (bus $I2C_ALIAS, address $CLIENT_ADDR)." ;;
  address) always "      BUT NOT UNDER THE NAME DERIVED ABOVE: $I2C_ALIAS gives bus ${CLIENT_NAME%%-*}, while the"
    always "      adapter registered under a different number. The client exists; the ALIAS is what is wrong." ;;
  esac
elif [ -n "$CLIENT_ADDR" ]; then
  always "   1. the i2c client /sys/bus/i2c/devices/$CLIENT_NAME: ABSENT"
  always "      and nothing under /sys/bus/i2c/devices carries address $CLIENT_ADDR either. FOR THIS BLOCK"
  always "      THAT IS THE EXPECTED READING AND NOT A FAULT OF THE BUS: the i2c core only instantiates a"
  always "      client for a node whose status is okay, and this node says 'disabled'. So the bus can be"
  always "      perfectly healthy -- and the bus section above is what says whether it is -- while this"
  always "      client does not exist."
else
  always "   1. the i2c client: CANNOT BE LOOKED FOR -- this node's address did not read as a u32, so neither"
  always "      the client's name nor the address to look for can be derived from the tree. What IS there:"
  for _d in /sys/bus/i2c/devices/*; do
    [ -e "$_d" ] || continue
    always "        $(basename "$_d")"
  done
fi
# The SECOND witness: a symlink under the driver directory.
say ""
say "   2. a device bound to '$DN' -- needs the node ENABLED, the driver built and registered, and"
say "      silabs_parse_dt() to have passed the two fatal gpios and both voltage properties:"
say "        $( [ -n "${DRV_BOUND:-}" ] && printf '%s' "$DRV_BOUND" || printf 'NONE' )"
# The THIRD witness: the v4l2 radio device. video_register_device() is the LAST thing probe() does, so a
# registered radio device means the whole probe ran -- and its identity is the `name` attribute, not the
# number.
RADIO_FOUND=no
RADIO_WHAT=""
say ""
if [ -d /sys/class/video4linux ]; then
  # THE NAME FILE IS THE IDENTITY AND THE NUMBER IS A REGISTRATION ORDER. RADIO_NR is -1 in this driver, so
  # v4l2 allocates the first free number: `radio0` today says nothing about which device it is, and the
  # v4l2 device's own name -- 'radio-silabs' -- is what identifies it. This walks the class rather than
  # reading one numbered directory, so a device at radio3 is found and a device at radio0 that belongs to
  # something else is not mistaken for this one.
  for _v in /sys/class/video4linux/*; do
    [ -e "$_v" ] || continue
    _vn=$(rd "$_v/name")
    _vd=$(rd "$_v/dev")
    _vi=$(rd "$_v/index")
    always "   3. $(basename "$_v"):  name=$_vn  dev=$_vd  index=$_vi"
    say "      debug (WRITABLE, and NOT written): $(rd "$_v/debug")"
    case "$_vn" in
    radio-silabs) RADIO_FOUND=yes; RADIO_WHAT="$(basename "$_v")" ;;
    esac
  done
  if [ "$RADIO_FOUND" = yes ]; then
    always "      AND $RADIO_WHAT IS THIS BLOCK'S: its 'name' attribute reads 'radio-silabs', which is the v4l2"
    always "      device name this driver registers -- while the DIRECTORY is a number v4l2 allocated"
    always "      (RADIO_NR is -1 in this driver). So the name is the identity and the number is a"
    always "      registration order, and a probe that looked for 'radio0' would be reading an allocation."
    always "      video_register_device() is the LAST thing silabs_fm_probe() does, after the regulators, the"
    always "      pinctrl, the video_device_alloc() and the four workqueues -- so this entry existing means the"
    always "      whole probe ran."
  else
    always "      and NONE of them reads 'radio-silabs', so this block's radio device is NOT registered."
    always "      Because video_register_device() is the last step of the probe, its absence means one of the"
    always "      steps before it failed -- or, for this block on this board, that the probe never ran at all"
    always "      because the node is disabled. The verdict below names which."
  fi
else
  always "   3. /sys/class/video4linux: ABSENT -- the v4l2 core registers that class itself at init, so its"
  always "      absence is about the KERNEL, not about this chip: VIDEO_V4L2 is off, or this kernel has no"
  always "      media framework at all."
fi
say ""
say "   THE NESTING IS THE READING: client (tree plus bus only) < bound (node enabled, driver built and"
say "   registered, probe's fatal reads passed) < radio device (the probe ran to the END). Each needs"
say "   strictly more than the one before -- and on THIS board the first one is already missing, which is"
say "   what makes the tree's own status the answer rather than a step on the way to one."

# --- 6. the kernel log, for this block --------------------------------------------------------------
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
  always "   the kernel log could not be read (neither dmesg nor journalctl -b -k returned anything) -- so"
  always "   this section is NOT READ. No verdict below rests on it: the rungs are decided on files, and the"
  always "   log only says WHY a driver that should have bound did not."
else
  always "   source: $LOG_SRC"
  show "$LOG_TEXT" 'silabs|sifm|si4705|fm_radio|radio-silabs|VIDIOC' \
    "(none: the kernel log mentions no FM driver this boot)" 25 1
  # The failure strings, taken from the sources rather than guessed: "silabs-reset-gpio not provided in
  # device tree", "silabs-int-gpio not provided in device tree", "unable to request gpio", "silabs-status-gpio
  # not provided", "Parsing DT failed", "Invalid property name", "vdd supply is not provided", "areg probe
  # defer", "Could not register video device", "failed allocating buffers".
  show "$LOG_TEXT" 'reset-gpio not provided|int-gpio not provided|status-gpio not provided|unable to request gpio|Parsing DT failed|Invalid property name|vdd supply is not provided|areg probe defer|Could not register video device|failed allocating buffers|v4l2|video4linux' \
    "(none: no FM probe failure in this boot's log)" 20 1
  always ""
  always "   A LINE ABOUT THIS DRIVER IN THE LOG WOULD BE EVIDENCE THAT THE KERNEL READ A DIFFERENT TREE THAN"
  always "   THE ONE ABOVE: this driver's strings can only appear if its probe ran, and a node the tree"
  always "   switches off is never instantiated -- so 'silabs' in the log plus 'disabled' in the tree is a"
  always "   contradiction worth chasing, and the two readings have to agree."
fi

# --- verdict ---------------------------------------------------------------------------------------
# The rung the evidence reaches, named. Each rung is a different problem with a different next move, and
# the first ones are a different BOARD and a different SEARCH.
N_BUILT=$(cfg_opt CONFIG_RADIO_SILABS)
if [ "$DT_RUNG" = unscanned ]; then
  V=tree-unscanned
  VMSG="the device tree could not be searched for 'silabs,si4705' (no find(1), and no known node shape exists). Nothing about this board's FM receiver was read, so nothing here is a verdict about it."
elif [ "$BOARD" = x2 ]; then
  V=wrong-board-tree
  VMSG="this boot is running the LE_X2's device tree, not this phone's. The FM node is at the same path in both, so the tree's shape cannot tell them apart and only 'model' can -- nothing below is about the zl1. The next move is about which DTB the bootloader picked."
elif [ "$BOARD" = other ] || [ "$BOARD" = unknown ]; then
  V=unknown-board
  VMSG="the device tree's model names neither LE_ZL1 nor LE_X2 (read: $MODEL), so this reading cannot be attributed to this phone. The readings below stand on their own; the attribution does not."
elif [ "$DT_RUNG" = no-node ]; then
  V=no-device-tree-node
  VMSG="this device tree declares no node with 'silabs,si4705': the FM receiver is not described at all, so no client is created for it and no driver can bind. On this board the node IS in all 15 of its trees, so this rung means the tree being read is not the tree this phone boots with."
elif [ "$SRC_MATCH" = none ]; then
  V=no-driver-for-node
  VMSG="the tree declares the node and NO driver in this kernel source matches 'silabs,si4705' -- so nothing can bind it under any config. This is a property of the kernel SOURCE, not of a build option."
elif [ "$NODE_EN" = no ]; then
  # THE RUNG THIS BOARD IS ON, and the one that has to be unmistakable: it is the only rung in this whole
  # project whose cause is the DEVICE TREE switching a block off rather than anything missing.
  V=no-node-enabled
  VMSG="THE DEVICE TREE SWITCHES THIS BLOCK OFF: the FM node carries 'status = $(dtstr "$NODE/status")', so the i2c core never instantiates a client for it, no driver binds, and no radio device is registered -- whatever the kernel was built with. THIS IS NOT A BUILD OPTION AND NOT A WIRING FAULT: the driver IS built (CONFIG_RADIO_SILABS is $N_BUILT), and the same node exists in all 15 of this phone's trees, in all three sets, with the same status. The next move is a device-tree (boot image) decision, and it is the opposite kind of move from the config line another block on this board needs."
elif [ "$CLIENT_FOUND" = no ]; then
  V=no-client
  VMSG="the node is enabled and a driver exists in this kernel's source, but the i2c CORE never created the client -- so the bus node is disabled or its own driver is not built, or 'reg' is not a usable address. NO CONFIG LINE FOR THE FM DRIVER CAN FIX THIS, which is why it outranks the driver rungs below it: the next move is the i2c controller the node sits on."
elif [ "$DRV_REG" = no ]; then
  case "$N_BUILT" in
  "NOT SET" | "absent from the config")
    V=driver-not-built
    VMSG="the driver is in this kernel's source, nothing is registered, and THE KERNEL'S OWN CONFIG DOES NOT BUILD IT (CONFIG_RADIO_SILABS: $N_BUILT). Check the CHAIN above before believing it: this option has four possible parents (MEDIA_RADIO_SUPPORT, VIDEO_V4L2 and RADIO_ADAPTERS among them), and any one of them being off would read as this. AND NOTE WHAT THIS RUNG IS NOT ON THIS BOARD: both kernels in hand carry 'CONFIG_RADIO_SILABS=y', so if the device reports this rung the config being read is not the one the kernel booted with."
    ;;
  *) V=driver-not-registered
     VMSG="the driver is in this kernel's source and nothing is registered, but this is NOT attributed to a config line here: CONFIG_RADIO_SILABS reads '$N_BUILT'. Either the option is 'm' and the module is not in the rootfs, or the config could not be read at all -- which is a third state, and neither of those is 'the kernel does not build it'."
     ;;
  esac
elif [ -z "${DRV_BOUND:-}" ]; then
  V=driver-not-bound
  VMSG="the driver is registered and NOTHING is bound to the FM node, so its probe ran and failed -- or never ran against this client. silabs_fm_probe() fails on a missing silabs,reset-gpio or silabs,int-gpio, on a failed gpio_request for any of the three, on an odd silabs,va-supply-voltage or silabs,vdd-supply-voltage (each is read as EXACTLY TWO CELLS), and on the v4l2 device allocation and the four workqueues."
  case "$FATAL_MISSING" in
  '') : ;;
  *) VMSG="$VMSG AND THE TREE ITSELF IS THE CAUSE: it is missing or invalid on$FATAL_MISSING, which alone fails silabs_parse_dt()." ;;
  esac
  VMSG="$VMSG The properties section above names every read, and the kernel log section says which one failed."
elif [ "$RADIO_FOUND" = no ]; then
  V=no-radio-device
  VMSG="the driver is bound but its radio device is not registered. video_register_device() is the LAST thing the probe does, so this means a step before it failed -- most likely one of the four workqueues or the video_device_alloc() -- and the kernel log section above says which."
else
  V=radio-registered
  VMSG="the node is enabled, the i2c client exists, the driver is bound to it, and its v4l2 radio device is registered -- so the whole chain from the device tree to a registered character device is in place, and the readings above are readings rather than placeholders."
fi

always ""
always "== verdict: $V"
always "   $VMSG"

# What a verdict about this block must say out loud: the three witnesses are the software path, and the chip
# is still off.
if [ "$V" = radio-registered ]; then
  always ""
  always "   AND THE CHIP IS STILL POWERED DOWN, WHICH IS NOT A FAULT. silabs_fm_probe() powers nothing: the"
  always "   regulators, the pinctrl active state and the three gpios are configured by silabs_fm_fops_open(),"
  always "   i.e. when something OPENS the device node -- and the first ioctl then writes real commands to the"
  always "   chip over i2c. So the absence of FM traffic says 'nobody opened it', not 'the receiver is dead'."
  always "   The probe does not open it: that is this block's write-class move, and it drives real pins."
fi

always ""
always "   WHAT THIS IS NOT: an answer to 'does FM radio work'. An enabled node, a bound driver and a"
always "   registered radio device are the software path being in place -- none of them is a station, and the"
always "   chip is powered down until something opens the device node. This probe writes NOTHING at all (no"
always "   scratch file), opens NO device node, and does not touch the one writable attribute this block has"
always "   (/sys/class/video4linux/radioN/debug)."

[ "$V" = radio-registered ] && exit 0
exit 1
