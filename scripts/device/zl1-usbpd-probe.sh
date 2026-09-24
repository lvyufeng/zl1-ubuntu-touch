#!/bin/sh
# zl1 USB Type-C / CC-logic probe -- the six device-tree nodes that declare a port controller, which of
# them the tree enables, and whether the running kernel has a driver for ANY of them.
#
# Why this exists. doc 137 enumerated this board's hardware from its own device trees and named the blocks
# nothing in this tree reads. `usb-pd` is one of them, and it is not one device: it is a MENU of four
# different CC-logic chips on two i2c buses, plus two vendor "driver" nodes. Four readings make this
# probe's design. They are the four below, and each is read by a section further down -- the numbering here
# is the order they matter in, not the order the sections run:
#
#   1. THE TREE ENABLES TWO NODES AND DISABLES FOUR. On i2c@75b5000 (the bus that also carries the
#      charger and the FM radio) `/soc/i2c@75b5000/tusb320@67` (`tusb320`, reg 0x67) and
#      `/soc/i2c@75b5000/cclogic_dev@3d` (`cclogic_dev`, reg 0x3d) are `status = "ok"` -- in ALL 15 of this
#      board's trees, in all three sets. On i2c@757a000 `/soc/i2c@757a000/pi5usb@1d` (`pi5usb`, 0x1d) and
#      `/soc/i2c@757a000/tusb302l@47` (`tusb302l`, 0x47) are `status = "disabled"`, and so are the two
#      platform nodes `/soc/pi5usb_driver` (`letv,pi5usb_driver`) and `/soc/tusb302l_driver`
#      (`letv,tusb302l_driver`).
#   2. THE KERNEL BUILDS DRIVERS FOR THE TWO IT DISABLES, AND FOR NEITHER OF THE TWO IT ENABLES. Read out
#      of the flash boot image's own kernel: `CONFIG_USB_CCLOGIC_PI5USB=y` and `CONFIG_USB_CCLOGIC_TUSB302L=y`
#      (the disabled nodes' drivers), against `# CONFIG_USB_CCLOGIC_TUSB320 is not set`,
#      `# CONFIG_USB_CCLOGIC_PTN5150 is not set` and `# CONFIG_USB_CCLOGIC_PER30216 is not set`. The
#      `cclogic_dev` compatible is matched by exactly two drivers in the whole tree -- ptn5150.c and
#      pericom_i2c_30216c_v1.c -- and BOTH are off. So both enabled nodes get an i2c client from the i2c
#      core and bind nothing, and this is a build-time disagreement between the device tree and the
#      kernel config, not a runtime fault. The probe re-reads the config on the device from
#      /proc/config.gz (CONFIG_IKCONFIG_PROC=y in the same image) rather than trusting a static list.
#   3. `cc_state: none` IS AMBIGUOUS, AND THE AMBIGUITY IS THE WHOLE POINT. The hub driver (cclogic.c,
#      `CONFIG_USB_CCLOGIC=y`, a `subsys_initcall`) creates /sys/class/typec/typec_device/ with
#      `cc_state`, `cc_polarity` and `supported_dev` -- and the ONLY writers of that state are the
#      CC-logic drivers: tusb320.c, ptn5150.c, pericom_i2c_30216c_v1.c, cyccg.c and anx_ohio_driver.c,
#      every one of which calls `cclogic_updata_port_state()`. Its initial value is 0 = "none", which is
#      ALSO the correct value for "nothing is plugged in". So a bare `none` cannot be read as "the port
#      is idle": the probe names the WRITER, and when no driver for an enabled node is registered it
#      says out loud that `none` is the uninitialised value rather than a reading about the port.
#   4. THE OTHER PHONE'S TREES CARRY A DIFFERENT CC-LOGIC FAMILY. All 23 LE_X2 trees in the same blob
#      carry `usb_cclogic@08` (`cypress,cyccg`), `usb_cclogic@28` (`analogix,ohio`) and `dp_analogic@38`
#      (`analogix,anx7816`) -- and NONE of the 15 LE_ZL1 trees does. Their root `compatible` is
#      byte-identical to this board's, so only `model` separates them, and this probe reads `model`
#      before anything else. (doc 137 section 3.2 lists those three as hardware the rebuilt set has and
#      stock does not. That is true of the BLOB and false of this phone: it is the other board's.)
#
# WHAT THIS CANNOT SAY: what the port IS. The USB role, the CC polarity and whether a charger is
# recognised are all decided by a chip this kernel has no driver for, so on this boot they are not merely
# unread -- they are UNDECIDED. Making the block live means a kernel-config change (one line) and that is
# a boot-image build, i.e. a separate, reviewed step.
#
# **Read-only, and it writes nothing at all** -- not even a scratch file, which is why the kernel log is
# captured into a shell variable. Every knob in sight is named and left alone:
#   * /sys/module/cclogic/parameters/cclogic_typec_headset_with_analog is mode 0664, and `module_param_call`
#     passes a NULL setter, so `param_attr_store()` returns -EPERM and a write is REFUSED anyway;
#   * tusb320.c registers a misc device (`/dev/tusb320`) with its own fops, and its sysfs attribute group
#     is behind `#if defined(TUSB320_DEBUG)`, so it is not registered in this build -- opening the misc
#     device is the write-class move here;
#   * and the two `letv,*_driver` platform nodes are the vendor's own driver-sequencing invention.
#
# Usage (on the device):
#   sh zl1-usbpd-probe.sh             # every rung, then a verdict
#   sh zl1-usbpd-probe.sh --quiet     # the verdict and the readings it rests on
#   sh zl1-usbpd-probe.sh --explain   # what each reading decides, and why this reading
#
# Exit: 0 a CC-logic driver for an ENABLED node is registered and bound, so the port state is a reading;
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
# which means "no match" for a reader that is not expecting it. Everything this probe prints is
# therefore printable-only.
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
# Every string of a property, not just the first: a compatible list and `pinctrl-names` are LISTS, and
# reading only the first entry is how a property looks like it does not carry the entry you want.
dtlist() { # $1 = path
  if [ ! -r "$1" ]; then printf 'absent'; return; fi
  v=$(tr '\0' '\n' < "$1" 2>/dev/null | grep . | LC_ALL=C tr -c '[:print:]\n' '.' | tr '\n' ' ')
  printf '%s' "${v:-EMPTY}"
}
# A device-tree u32 is BIG-ENDIAN and this SoC is little-endian, so `od -tu4` on the file prints the value
# BYTE-SWAPPED -- an i2c address of 0x67 comes out as a number of the right shape and the wrong value.
# The four bytes are combined explicitly, and anything that is not exactly four bytes says so.
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
# The n-th u32 of a property, for the ones that are arrays of cells rather than one value: a GPIO is
# `<&tlmm 60 0>` = three cells, and reading it as a single number would be a wrong answer of the right
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
# An i2c address is a NUMBER, and one written in the device tree as `0x67` reading back as `103` is the
# same fact in a unit nobody can compare against a datasheet; the hex is printed beside it.
hex2() { # $1 = 0..255 -- prints 0xNN, or nothing when the input is not one number
  case "$1" in
  '' | *[!0-9]*) printf '' ;;
  *) printf '0x%02x' "$1" ;;
  esac
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
  # The known node shapes for a kernel without find(1). Every one of this block's nodes sits under an
  # `i2c@*` controller, and the direct-child variant is here because a node that moved to another level
  # is exactly what this scan exists to survive.
  for _nc_p in /proc/device-tree/soc/i2c@*/*@* /proc/device-tree/soc/*/i2c@*/*@* /proc/device-tree/soc/*driver; do
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
# Resolve a phandle to the node that carries it. A GPIO is `<&tlmm 60 0>`, and the phandle is the only
# thing saying WHICH gpio controller that is -- printing the raw number would leave the reader to guess.
# A phandle can be carried by more than one node in a hand-built tree, so an ambiguous answer says so
# rather than picking one: a wrong controller is a wrong gpio number. But the SAME node can carry the same
# phandle TWICE -- as `phandle` and as the older `linux,phandle`, which this board's pinctrl controller
# does -- and counting matches rather than nodes would call that one node ambiguous with itself.
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
  0) printf 'unresolved' ;;
  1) printf '%s' "${_ph_first#/proc/device-tree}" ;;
  *) printf 'AMBIGUOUS(%s)' "$_ph_hits" ;;
  esac
}
# The GPIO cells of a property, RESOLVED: `<&tlmm 60 0>` prints as
# "phandle 28 = /soc/pinctrl@01010000, gpio 60, active high". Three cells is the shape on this board; a
# property with a different count says so rather than being read as if it had three.
gpio_cells() { # $1 = path
  if [ ! -r "$1" ]; then printf 'absent'; return; fi
  # A gpio property is WHOLE cells. A length that is not a multiple of four is not a gpio description, and
  # reading the first three bytes of four would print a number of the right shape and the wrong value --
  # the same defect `not-a-u32` exists for, one level down.
  _g_bytes=$(wc -c < "$1" 2>/dev/null | tr -d ' ')
  if [ -z "$_g_bytes" ] || [ $((_g_bytes % 4)) != 0 ]; then
    printf 'not-a-gpio(%s bytes)' "${_g_bytes:-?}"
    return
  fi
  _g_p=$(dtcell "$1" 1)
  _g_n=$(dtcell "$1" 2)
  _g_f=$(dtcell "$1" 3)
  case "$_g_p" in
  absent) printf 'not-a-gpio(no cells)'; return ;;
  esac
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
# HOW A DRIVER MATCHES IS NOT ALWAYS BY COMPATIBLE, and this block is where that bites. i2c_device_match()
# in this kernel tries, in order: the driver's of_device_id table, ACPI, and then -- IF the driver has an
# id_table -- a match on the client's NAME, which for a device-tree client is the MODALIAS: the compatible
# with its vendor prefix stripped (`of_modalias_node` splits at the comma). So:
#   * `pi5usb@1d` carries the BARE compatible `pi5usb`, while pi5usb30216a.c's of_match is
#     `fairchild,pi5usb` -- its of_match does NOT apply to this node, and what would bind it is the
#     id_table entry `{ "pi5usb", 0 }` matching the client's name. Wording this as "the compatible does
#     not match" would be wrong, and wording it as "of_match matches" would be wrong the other way.
#   * the two `letv,*_driver` nodes are PLATFORM nodes (no `reg`), and the platform_driver beside each i2c
#     driver matches them by of_match on exactly that string.
drivers_for() { # $1 = compatible
  case "$1" in
  pi5usb)
    printf 'pi5usb\tCONFIG_USB_CCLOGIC_PI5USB\tdrivers/usb/misc/pi5usb30216a.c\ti2c\tby the id_table NAME "pi5usb" (its of_match is "fairchild,pi5usb", which this node does not carry)\n'
    ;;
  fairchild,pi5usb)
    printf 'pi5usb\tCONFIG_USB_CCLOGIC_PI5USB\tdrivers/usb/misc/pi5usb30216a.c\ti2c\tby of_match "fairchild,pi5usb"\n'
    ;;
  tusb302l)
    printf 'tusb302l\tCONFIG_USB_CCLOGIC_TUSB302L\tdrivers/usb/misc/tusb302l.c\ti2c\tby of_match "tusb302l"\n'
    ;;
  tusb320)
    printf 'tusb320\tCONFIG_USB_CCLOGIC_TUSB320\tdrivers/usb/misc/tusb320.c\ti2c\tby of_match "tusb320"\n'
    ;;
  cclogic_dev)
    printf 'ptn5150\tCONFIG_USB_CCLOGIC_PTN5150\tdrivers/usb/misc/ptn5150.c\ti2c\tby of_match "cclogic_dev"\n'
    printf 'pericom_30216c\tCONFIG_USB_CCLOGIC_PER30216\tdrivers/usb/misc/pericom_i2c_30216c_v1.c\ti2c\tby of_match "cclogic_dev"\n'
    ;;
  cypress,cyccg) printf 'cyccg\tCONFIG_USB_CYCCG\tdrivers/usb/misc/cyccg.c\ti2c\tby of_match "cypress,cyccg"\n' ;;
  analogix,ohio) printf 'ohio\tCONFIG_ANALOGIX_OHIO\tdrivers/usb/misc/anx7418/anx_ohio_driver.c\ti2c\tby of_match "analogix,ohio"\n' ;;
  letv,pi5usb_driver)
    printf 'pi5usb_driver\tCONFIG_USB_CCLOGIC_PI5USB\tdrivers/usb/misc/pi5usb30216a.c\tplatform\tby of_match "letv,pi5usb_driver"\n'
    ;;
  letv,tusb302l_driver)
    printf 'tusb302l_driver\tCONFIG_USB_CCLOGIC_TUSB302L\tdrivers/usb/misc/tusb302l.c\tplatform\tby of_match "letv,tusb302l_driver"\n'
    ;;
  *) printf 'none\t-\t-\t-\t-\n' ;;
  esac
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

if [ "$MODE" = explain ]; then
  cat <<'EOF'
zl1 usb Type-C / CC-logic probe -- what each reading decides, and why it is this reading

  1. WHICH BOARD'S DEVICE TREE IS RUNNING (model, not compatible).
     The flashed boot image's appended blob carries 28 device trees: 5 for the LE_ZL1 and 23 for the
     LE_X2, a different phone, under a byte-identical root `compatible`. Both boards have a USB-C
     port, and the CC-logic chips they declare are DIFFERENT: the X2's trees carry
     `cypress,cyccg` / `analogix,ohio` / `analogix,anx7816` on i2c@757a000 and NONE of this board's
     15 trees does. So `model` is read first: on the X2's tree the whole block below is another
     phone's port.

  2. THE NODES THE TREE DECLARES, AND WHICH OF THEM IT ENABLES.
     This board declares SIX candidates -- four chips and two vendor "driver" nodes -- and enables
     exactly two of them, both on i2c@75b5000: `tusb320@67` and `cclogic_dev@3d`. For each node the
     probe prints the bus, the i2c address in BOTH decimal and hex (a `reg` of 0x67 reading back as
     103 is the same fact in a unit nobody can compare against a datasheet), the interrupt, the GPIO
     cells RESOLVED through their phandle (`<&tlmm 60 0>` is a gpio number on a controller, and the
     number alone does not say which), and the pinctrl states -- because tusb320.c looks up a state
     BY NAME (`m0_ccint_active`) and fails its probe if it is not there.

  3. WHETHER THE KERNEL HAS A DRIVER FOR WHAT THE TREE ENABLED.
     That is the question this probe exists for. The probe carries, from the kernel source, which
     driver matches which compatible -- and HOW it matches, because it is not always by compatible: the
     i2c core also matches a driver's id_table against the client's NAME, which is the compatible with its
     vendor prefix stripped, so `pi5usb@1d` (bare `pi5usb`) would bind through the id_table entry
     `{ "pi5usb", 0 }` even though that driver's of_match is `fairchild,pi5usb`. Then it asks the DEVICE
     two independent questions about each:
     does /sys/bus/i2c/drivers/<name> exist (the driver registered), and does /proc/config.gz say its
     CONFIG option is set (it was built in at all). The two can disagree and the disagreement is the
     answer: a driver the config says is off cannot be registered, and a driver that is registered but
     has nothing bound is a different problem with a different next move.

  4. THE HUB, AND WHY `cc_state: none` IS NOT A READING BY ITSELF.
     cclogic.c (CONFIG_USB_CCLOGIC) is not a device-tree driver at all: it is a `subsys_initcall` that
     creates /sys/class/typec/typec_device/ with `cc_state`, `cc_polarity` and `supported_dev`. The
     ONLY writers of `cc_state` are the CC-logic drivers, each calling cclogic_updata_port_state().
     The initial value is 0, which prints as `none` -- and `none` is ALSO the correct value when
     nothing is plugged in. So the probe prints the value together with the writer that could have
     produced it: with no driver bound, `none` is the uninitialised value and says nothing about the
     port. `supported_dev` is the other half: it is 0 unless a Letv USB audio device (VID 0x262A) is
     attached, so it is a reading about what is on the port RIGHT NOW.

  WHAT THIS CANNOT SAY. What the port IS. The USB role, the CC polarity and whether a charger is
  recognised are decided by a chip this kernel has no driver for, so on such a boot they are not
  merely unread -- they are UNDECIDED. And this probe never opens /dev/tusb320, the misc device
  tusb320.c registers: opening it is a write-class move, and this probe takes readings.
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
  always "               the X2's. That matters more here than for most blocks: the two boards declare"
  always "               DIFFERENT CC-logic chips (the X2's trees carry cypress,cyccg / analogix,ohio /"
  always "               analogix,anx7816 and this phone's 15 trees carry none of them), so every reading"
  always "               below is about the other phone's port."
  ;;
unknown)
  always "   board:      UNKNOWN -- /proc/device-tree/model could not be read, so which board's tree this is"
  always "               cannot be told from here. The readings below are still taken, and this is named"
  always "               in the verdict rather than being silently assumed to be a zl1."
  ;;
*) always "   board:      neither LE_ZL1 nor LE_X2 -- nothing below can be attributed to this phone" ;;
esac

# --- 2. the kernel's own config, read BEFORE the node loop that asks about it ----------------------
#
# This has to come first: the node loop below asks, for every driver that could bind a node, whether the
# option that builds it is set -- and a shell function is only defined once its definition has EXECUTED,
# so defining `cfg_opt` below the loop it is called from would fail at every call.
#
# CONFIG_IKCONFIG_PROC=y in the flashed image, so the RUNNING kernel can be asked rather than a static
# list being trusted. Reading it needs a decompressor, and a device with neither zcat(1) nor gunzip(1) is
# a state this probe NAMES rather than turning into "the option is off": a config that could not be read
# and a config that says `# ... is not set` are different facts, and only one of them is a verdict.
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
  "$1=m") printf 'm (module)' ;;
  "# $1 is not set") printf 'NOT SET' ;;
  *) printf 'absent from the config' ;;
  esac
}

# --- 3. the nodes the device tree declares ---------------------------------------------------------
hdr "the CC-logic nodes the device tree declares"
# Every compatible this block is known to use, on either board. The scan is per-compatible so that "which
# compatible is present" is a reading rather than a path guess.
CANDS="pi5usb tusb302l tusb320 cclogic_dev cypress,cyccg analogix,ohio letv,pi5usb_driver letv,tusb302l_driver"
NODES=""
NC_RC=0
for c in $CANDS; do
  NC_OUT=$(nodes_with "$c"); _rc=$?
  [ "$_rc" = 2 ] && NC_RC=2
  for p in $NC_OUT; do
    case " $NODES " in *" $p "*) continue ;; esac
    NODES="$NODES $p"
  done
done
N_NODES=0
[ -n "$NODES" ] && N_NODES=$(printf '%s\n' $NODES | grep . | wc -l | tr -d ' ')

if [ "$NC_RC" = 2 ]; then
  DT_RUNG=unscanned
  always ""
  always "   the device tree could not be searched for the CC-logic compatibles at all: find(1) is missing"
  always "   AND no known node shape exists. This is NOT 'the tree declares no port controller' -- it is"
  always "   'this probe could not look', and the two must not print the same way."
elif [ -z "$NODES" ]; then
  DT_RUNG=no-node
  always ""
  always "   no node in this device tree carries any of the compatibles this block uses"
  always "   -- the running tree declares no USB Type-C / CC-logic controller at all. The paths are not"
  always "     assumed: the whole tree is scanned for each compatible."
else
  DT_RUNG=node
  N_ENABLED=0
  N_ENABLED_WITH_DRIVER=0
  N_ENABLED_WITH_WRITER=0
  N_MATCHABLE=0
  for p in $NODES; do
    C=$(dtstr "$p/compatible")
    ST=$(dtstr "$p/status")
    REG=$(dtu32 "$p/reg")
    case "$ST" in okay | ok | EMPTY) EN=yes ;; *) EN=no ;; esac
    # A node with no `status` is ENABLED (that is what the device tree means by an absent status), which
    # is why EMPTY is in the enabled branch above and why the print below names the absence.
    case "$ST" in
    absent) ST_SHOW="absent (an absent status means enabled; this node carries none)" ;;
    *) ST_SHOW="$ST" ;;
    esac
    [ "$EN" = yes ] && N_ENABLED=$((N_ENABLED + 1))
    always ""
    always "   ${p#/proc/device-tree}"
    say "     compatible:  $C"
    always "     status:      $ST_SHOW  ($([ "$EN" = yes ] && echo 'the kernel will create this device' || echo 'DISABLED: the kernel creates no device for it, and no driver can bind at all'))"
    case "$REG" in
    absent) say "     reg:         absent (no i2c address -- this is a platform node, not an i2c one)" ;;
    not-a-u32*) say "     reg:         $REG" ;;
    *) say "     reg:         $REG $(hex2 "$REG")  (the i2c address, as the tree writes it)" ;;
    esac
    _ip=$(dtu32 "$p/interrupt-parent")
    case "$_ip" in
    '' | absent | not-a-u32*) say "     interrupts:  $(dtu32 "$p/interrupts")   interrupt-parent: ${_ip:-absent} (nothing to resolve)" ;;
    *) say "     interrupts:  $(dtu32 "$p/interrupts")   interrupt-parent: $_ip = $(phandle_node "$_ip")" ;;
    esac
    for g in irq-gpio qcom,id-gpio cc1_pwr_gpio cc2_pwr_gpio switch_gpio1 switch_gpio2; do
      [ -r "$p/$g" ] && say "     $(printf '%-13s' "$g") $(gpio_cells "$p/$g")"
    done
    say "     pinctrl:     names='$(dtlist "$p/pinctrl-names")'"
    say "     (the driver names its pin state BY NAME and fails its probe when the state is not there --"
    say "      tusb320.c asks for 'm0_ccint_active', so a node whose pinctrl-names omit it cannot bind"
    say "      however okay its status is.)"
    # The drivers that could bind this node, and the two device-side answers about each.
    DLIST=$(drivers_for "$C")
    case "$DLIST" in
    none*) say "     drivers:     NONE in this kernel tree matches '$C' -- nothing can ever bind it" ;;
    *)
      # Any line here is a driver that EXISTS in this kernel source for this compatible, whether or not it
      # registered -- so "matchable" is counted here and not from the registered answer, which is a
      # different fact (the source has the driver / this boot is running it).
      N_MATCHABLE=$((N_MATCHABLE + 1))
      # `drivers_for` prints TAB-separated fields, and a default IFS would split EVERY FIELD into its own
      # word -- so the loop would read `pi5usb`, then `CONFIG_USB_CCLOGIC_PI5USB`, then the source path, and
      # treat each as a driver name. IFS is newline-only for the duration of the loop, and each line's
      # fields are cut with `cut -f`, whose separator is a tab. (A `while read` pipeline is the other way to
      # do this and is WRONG here: it runs in a subshell, so the counters below would be incremented and
      # then thrown away with it.)
      _oldifs=$IFS
      IFS='
'
      for _dl in $DLIST; do
        DN=$(printf '%s' "$_dl" | cut -f1)
        DC=$(printf '%s' "$_dl" | cut -f2)
        DS=$(printf '%s' "$_dl" | cut -f3)
        DB=$(printf '%s' "$_dl" | cut -f4)
        DM=$(printf '%s' "$_dl" | cut -f5)
        R=$(drv_registered "$DB" "$DN")
        B=$(drv_bound "$DB" "$DN")
        CFG=$(cfg_opt "$DC")
        always "     driver:      $DN  ($DS, $DB, $DM)"
        always "       registered: $R   bound:${B:- NONE}   config $DC: $CFG"
        [ "$EN" = yes ] && [ "$R" = yes ] && N_ENABLED_WITH_DRIVER=$((N_ENABLED_WITH_DRIVER + 1))
        [ "$EN" = yes ] && [ "$R" = yes ] && [ -n "$B" ] && N_ENABLED_WITH_WRITER=$((N_ENABLED_WITH_WRITER + 1))
      done
      IFS=$_oldifs
      ;;
    esac
  done
  always ""
  always "   $N_ENABLED of $N_NODES node(s) are ENABLED by this tree, and $N_ENABLED_WITH_DRIVER of those have"
  always "   a driver that is actually REGISTERED in this kernel ($N_ENABLED_WITH_WRITER of them bound)."
fi

# --- 4. the drivers this KERNEL has -----------------------------------------------------------------
hdr "the CC-logic drivers this kernel has (drivers/usb/misc/)"
# The config was read above (before the node loop, which asks it about each driver); this section only
# reports it, and names a config it could not read as NOT READ rather than as "off".
always "   /proc/config.gz: $([ -r /proc/config.gz ] && echo present || echo MISSING)"
if [ -n "$CFG_SRC" ]; then
  always "   source:          $CFG_SRC"
else
  always "   -- the kernel config could NOT be read: either the file is not there, or it is there and this"
  always "      device has neither zcat(1) nor gunzip(1) to expand it, or it could not be read at all. The"
  always "      config column below is therefore NOT READ -- which is a third state, and not 'the option is"
  always "      off'. The \`registered\` column comes from sysfs and needs no decompressor, so no verdict"
  always "      below rests on the config."
fi
always ""
always "   the options that matter, per the kernel's own config:"
for o in CONFIG_USB_CCLOGIC CONFIG_USB_CCLOGIC_PI5USB CONFIG_USB_CCLOGIC_TUSB302L CONFIG_USB_CCLOGIC_TUSB320 CONFIG_USB_CCLOGIC_PTN5150 CONFIG_USB_CCLOGIC_PER30216 CONFIG_USB_CYCCG CONFIG_ANALOGIX_OHIO; do
  always "     $(printf '%-34s' "$o") $(cfg_opt "$o")"
done
always ""
always "   (cclogic.c is the HUB, not a device driver: it is a subsys_initcall that creates"
always "    /sys/class/typec/typec_device/ and nothing else. Every CC-logic driver writes its state through"
always "    cclogic_updata_port_state(), so with the hub built and none of the chip drivers built, that"
always "    directory exists and nothing can ever change what it says.)"
always ""
always "   the driver directories themselves (a directory appears exactly when the driver registered):"
for d in "i2c pi5usb" "i2c tusb302l" "i2c tusb320" "i2c ptn5150" "i2c pericom_30216c" "i2c cyccg" "i2c ohio" "platform pi5usb_driver" "platform tusb302l_driver"; do
  set -- $d
  BUS=$1; DN=$2
  if [ -d "/sys/bus/$BUS/drivers/$DN" ]; then
    B=$(drv_bound "$BUS" "$DN")
    always "     /sys/bus/$BUS/drivers/$DN: present, bound:${B:- NONE}"
  else
    say "     /sys/bus/$BUS/drivers/$DN: ABSENT (the driver did not register)"
  fi
done

# --- 5. the i2c clients, and what is bound to them ---------------------------------------------------
hdr "the i2c clients (what the i2c core instantiated, and what answers)"
# An i2c client exists for every ENABLED device-tree child of a probed i2c adapter -- so the presence of a
# client is itself a reading that agrees (or disagrees) with the tree's `status`, and the `driver`
# symlink beside it is the difference between "a device exists" and "something drives it".
N_CLIENTS=0
for c in /sys/bus/i2c/devices/*; do
  [ -e "$c" ] || continue
  CN=$(rd "$c/name")
  # The client's name is NOT always the compatible: the i2c core names a device-tree client from
  # `of_modalias_node`, which strips the vendor prefix at the comma -- so `cypress,cyccg` becomes `cyccg`
  # and `analogix,ohio` becomes `ohio`. Both spellings are in the list, because a filter that only knew
  # the compatible would report "no client of this block" while one was sitting right there.
  case " pi5usb tusb302l tusb320 cclogic_dev cyccg ohio anx7816 cypress,cyccg analogix,ohio analogix,anx7816 " in
  *" $CN "*) ;;
  *) continue ;;
  esac
  N_CLIENTS=$((N_CLIENTS + 1))
  OF=$(readlink "$c/of_node" 2>/dev/null)
  case "$OF" in
  "") OF="(no of_node symlink here)" ;;
  *) OF=$(printf '%s' "$OF" | sed 's#.*/##') ;;
  esac
  DR=$(readlink "$c/driver" 2>/dev/null)
  case "$DR" in
  "") DR="NONE -- the client exists and no driver is bound to it" ;;
  *) DR=$(printf '%s' "$DR" | sed 's#.*/##') ;;
  esac
  always ""
  always "   $(basename "$c")   name: $CN"
  always "     device tree node: $OF"
  always "     driver:           $DR"
done
if [ "$N_CLIENTS" = 0 ]; then
  always "   /sys/bus/i2c/devices: no client of this block's compatibles exists."
  always "   (An i2c client is created for every ENABLED child of a probed adapter, so no client at all is a"
  always "    reading about the i2c controllers or about the tree's status properties -- not about the chips."
  always "    Section 3 has the tree side of that comparison.)"
else
  always ""
  say "   (this probe does NOT open /dev/tusb320: tusb320.c registers a misc device with its own fops,"
  say "    and opening it is a write-class move. The readings above come from sysfs and the tree.)"
fi

# --- 6. the hub, and the port state it reports ------------------------------------------------------
hdr "the hub: /sys/class/typec/typec_device (cclogic.c)"
TY=/sys/class/typec/typec_device
if [ -d "$TY" ]; then
  always "   $TY: present"
  for a in cc_state cc_polarity supported_dev; do
    if [ -e "$TY/$a" ]; then
      always "     $(printf '%-14s' "$a") $(san "$(rd "$TY/$a")")"
    else
      say "     $(printf '%-14s' "$a") (not there)"
    fi
  done
  always ""
  always "   cc_state is written ONLY by a CC-logic chip driver, and its initial value is 'none' -- which"
  always "   is ALSO the correct value when nothing is plugged in. So 'none' on its own is not a reading"
  always "   about the port: it needs the writer. Section 3 names whether any writer is registered and"
  always "   bound, and the verdict says which of the two 'none' this is."
else
  always "   $TY: MISSING -- the hub did not register. It is a subsys_initcall in cclogic.c behind"
  always "   CONFIG_USB_CCLOGIC, so its absence means that option is off in the kernel that booted, and"
  always "   there is then nowhere at all for a CC-logic driver to report the port state."
fi
# The other surfaces the four chip drivers would create, named so their absence is visible.
always ""
always "   the surfaces a BOUND chip driver would create (their absence is a reading):"
for s in /sys/class/misc/tusb320 /sys/class/tusb302l_class/tusb302l /sys/class/pi5usb_class/pi5usb /dev/tusb320; do
  [ -e "$s" ] && always "     $s: present" || say "     $s: absent"
done
# The one module parameter in this block, and why a write to it is refused rather than dangerous.
CCP=/sys/module/cclogic/parameters/cclogic_typec_headset_with_analog
if [ -e "$CCP" ]; then
  always ""
  always "   $CCP"
  always "     value: $(san "$(rd "$CCP")")   (mode 0664, but cclogic.c passes a NULL setter to"
  always "     module_param_call, and kernel/params.c's param_attr_store() returns -EPERM when ops->set is"
  always "     NULL: the file is writable-LOOKING and a write is REFUSED. This probe writes it either way.)"
else
  say "   $CCP: absent"
fi

# --- 7. the kernel log -----------------------------------------------------------------------------
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
  always "   and the log only says WHY a driver that should have bound did not."
  show "" x "(not read: the kernel log could not be read)" 1 1
else
  always "   source: $LOG_SRC"
  show "$LOG_TEXT" 'tusb|pi5usb|cclogic|typec|ptn5150|pericom|cc_state' \
    "(none: the kernel log mentions no CC-logic driver, typec or cclogic this boot)" 25
  # The failure strings, taken from the sources rather than guessed: tusb320.c prints
  # "Failed to request irq." and the gpio_request failures; tusb302l.c and pi5usb30216a.c print
  # "Failed to register ..."; cclogic.c prints its class/device_create failures; and i2c core prints
  # the "no driver" shapes below.
  show "$LOG_TEXT" 'Failed to request irq|gpio_request failed|Failed to register|device_create fail|failed to create typec class|is absent|probe failed|no driver|failed with error' \
    "(none: no CC-logic probe failure in this boot's log)" 20
fi

# --- verdict ---------------------------------------------------------------------------------------
# The rung the evidence reaches, named. Each rung is a different problem with a different next move, and
# the first one is a different BOARD.
if [ "$DT_RUNG" = unscanned ]; then
  V=tree-unscanned
  VMSG="the device tree could not be searched for the CC-logic compatibles (no find(1), and no known node shape exists). Nothing about the port controllers was read, so nothing here is a verdict about them."
elif [ "$BOARD" = x2 ]; then
  V=wrong-board-tree
  VMSG="this boot is running the LE_X2's device tree, not this phone's. The two boards declare DIFFERENT CC-logic chips -- the X2's trees carry cypress,cyccg / analogix,ohio / analogix,anx7816 and this phone's 15 trees carry none of them -- so nothing below is about the zl1. The next move is about which DTB the bootloader picked, not about the port."
elif [ "$BOARD" = other ] || [ "$BOARD" = unknown ]; then
  V=unknown-board
  VMSG="the device tree's model names neither LE_ZL1 nor LE_X2 (read: $MODEL), so this reading cannot be attributed to this phone. The readings below stand on their own; the attribution does not."
elif [ "$DT_RUNG" = no-node ]; then
  V=no-device-tree-node
  VMSG="this device tree declares no USB Type-C / CC-logic node at all, so there is nothing for a port driver to bind to. This block's nodes are in all 15 of this board's trees in all three sets, so a missing node means the tree that booted is not one of them."
elif [ "$N_ENABLED" = 0 ]; then
  V=no-node-enabled
  VMSG="every CC-logic node in this tree has a status that is not okay, so the tree picks no port controller and the kernel creates no device. Whatever the port does, it does without a CC-logic driver by the device tree's own decision."
elif [ "$N_ENABLED_WITH_DRIVER" = 0 ]; then
  V=driver-not-built
  VMSG="the device tree ENABLES $N_ENABLED node(s) and NO driver that could bind them is registered in this kernel: a BUILD-TIME disagreement between the device tree and the kernel config, not a runtime fault."
  if [ "$N_MATCHABLE" != "$N_NODES" ]; then
    VMSG="$VMSG $N_MATCHABLE of $N_NODES node(s) have a driver somewhere in this kernel source; the other $((N_NODES - N_MATCHABLE)) have none under ANY config, so switching an option on would not help those."
  else
    VMSG="$VMSG All $N_NODES node(s) have a driver in this kernel source, so this is about which options were built, not about a chip nothing supports."
  fi
elif [ "$N_ENABLED_WITH_WRITER" = 0 ]; then
  V=driver-not-bound
  VMSG="a driver for an enabled node IS registered and nothing is bound to it, so the probe never ran. The reasons a bound-capable driver does not bind are the ones section 2's readings are for: the chip not answering on i2c (tusb320.c's tusb320_is_present() reads the device-id register and returns -ENODEV when it does not match), a missing named pinctrl state ('m0_ccint_active'), or a gpio_request failure -- the log section looks for all three."
elif [ ! -d "$TY" ]; then
  V=no-hub
  VMSG="a CC-logic driver for an enabled node is bound, but /sys/class/typec/typec_device is missing, so there is nowhere for it to report the port state. That is CONFIG_USB_CCLOGIC off (the hub is a subsys_initcall in cclogic.c), and it means the driver is driving the port with no state visible to anything."
else
  V=port-reported
  VMSG="a CC-logic driver for an ENABLED node is registered and bound, and the hub is present, so cc_state is a READING about the port and not an uninitialised value. What it says still depends on what is plugged in -- 'none' with a writer bound means nothing is attached, which is now a statement about the port rather than about the kernel."
fi

always ""
always "== verdict: $V"
always "   $VMSG"

# The thing a verdict about this block must say out loud, and the reason it is a separate paragraph: the
# two enabled nodes and the kernel's config disagree, and on THIS board that is a stable, checkable fact.
if [ "$DT_RUNG" = node ] && [ "$N_ENABLED" != 0 ] && [ "$N_ENABLED_WITH_DRIVER" = 0 ]; then
  always ""
  always "   NOTHING CAN WRITE 'cc_state' ON THIS BOOT. The tree enables $N_ENABLED node(s) and this kernel has"
  always "   no registered driver for either, and every writer of cc_state is a CC-logic chip driver -- so"
  always "   the 'none' above is the value the hub was CREATED with, not a report that the port is idle."
  always "   What that costs: the USB role, the CC polarity and whether a charger is recognised are decided"
  always "   by a chip nothing is driving. They are not merely unread on this boot; they are UNDECIDED."
  always "   The fix is a kernel-config line (the tree already enables the node), which means a boot-image"
  always "   build -- a separate, reviewed step, and not a side effect of taking a reading."
fi

always ""
always "   WHAT THIS IS NOT: an answer to 'does the USB-C port work'. That is a question about a chip this"
always "   kernel has no driver for, and the same reading -- cc_state 'none', no client bound -- covers both"
always "   'nothing is plugged in' and 'nothing can ever tell'. This probe also never opens /dev/tusb320 or"
always "   touches any of the driver's knobs: it reads the tree, sysfs and the kernel's own config."

case "$V" in
port-reported) exit 0 ;;
*) exit 1 ;;
esac
