#!/bin/sh
# zl1 NFC probe -- the one device-tree node that describes this board's NFC controller, the two
# property NAMESPACES it carries, the string that gates its probe, and the three nested run-time
# witnesses a working chain leaves behind.
#
# Why this exists. doc 137 enumerated this board's hardware from its own device trees and named the
# blocks nothing in this tree reads; `nfc` is one of them. Six readings make this probe's design:
#
#   1. THE NODE CARRIES TWO GENERATIONS OF PROPERTY NAMES, AND ONLY ONE IS READ.
#      `/soc/i2c@75b6000/nq@28` (`qcom,nq-nci`) carries `qcom,nq-ven`, `qcom,nq-irq`, `qcom,nq-firm`,
#      `qcom,nq-clkreq` and `qcom,clk-src` -- the five names `nfc_parse_dt()` asks for -- AND
#      `nxp,p61-pwr` and `nxp,p61-rst`, which NOTHING in this kernel reads: not a .c, not a .h, not a
#      Kconfig. And the two descriptions do not even agree about the pins: the driver's power enable is
#      `qcom,nq-ven` = `<28 12 0>`, a TLMM pin, while the unread one is `nxp,p61-pwr` = `<29 7 0>`, a
#      PMIC pin. A probe that reported "the node describes a power enable" without saying WHICH
#      namespace it came from would be reporting a line nothing asks for as if it were the wiring.
#   2. THREE OF THE FIVE READS ARE FATAL AND TWO ARE NOT. `qcom,nq-ven` and `qcom,nq-irq` invalid make
#      `nfc_parse_dt()` return -EINVAL (the probe never runs), and so does a missing `qcom,clk-src` --
#      but a missing `qcom,nq-firm` is only a `dev_warn` and a missing `qcom,nq-clkreq` only a
#      `dev_err`. So "the node is complete" and "the driver can bind" are different questions, and
#      this probe answers them separately.
#   3. ONE STRING VALUE GATES THE PROBE. `if (!strcmp(platform_data->clk_src_name, "BBCLK2"))` -- and
#      the else branch is `goto err_free_dev`, i.e. the probe FAILS. This board says "BBCLK2". The
#      driver has no other clock source, so the property is not informational: it is a switch.
#   4. THE CONFIG LINE THAT DECIDES THIS BLOCK IS OUTSIDE THE MENU IT LOOKS LIKE IT BELONGS TO.
#      `config NFC_NQ` sits in drivers/nfc/Kconfig AFTER the `endmenu` of `menu "Near Field
#      Communication (NFC) devices"`, which is the menu that `depends on NFC`. So `CONFIG_NFC` is NOT
#      a precondition for `CONFIG_NFC_NQ`, and the two kernels this project has in hand prove it in
#      opposite directions: the STOCK boot image's 3.18.120 kernel has `# CONFIG_NFC is not set` AND
#      `CONFIG_NFC_NQ=y` (the driver is built with the menu off), while the v63 Halium kernel this
#      port boots (3.18.140) has both off. **A reader who checks CONFIG_NFC gets the same line from
#      both kernels.** This probe reads CONFIG_NFC_NQ, prints both, and says which one it decided on.
#   5. TWO `#ifdef`s THAT ARE DEFINED NOWHERE. `CONFIG_NFC_HW_CHECK` and `NFC_KERNEL_BU` appear in
#      nq-nci.c only as `#ifdef` uses: there is no Kconfig symbol and no -D for either anywhere in the
#      tree, so both blocks are OFF. The first removes the probe's hardware presence check; the second
#      removes the `gpio_set_value(en_gpio, 1)` that would power the chip on. So even a bound driver
#      leaves VEN LOW and the ref clock off, and the chip is powered up only by userspace: the
#      `NFC_SET_PWR` ioctl on the misc device (1 = on, 2 = download mode, 0 = off). A reading that
#      stopped at "the driver bound" would look like a live controller and not be one.
#   6. FOUR NAMES FOR ONE BLOCK, AND ONE OF THEM IS ANOTHER DRIVER'S. The compatible is
#      `qcom,nq-nci`; the i2c driver's `.name` is `nq-nci` (so the directory is
#      /sys/bus/i2c/drivers/nq-nci); its `i2c_device_id` is `nqx-i2c`; and the MISC DEVICE it registers
#      is named **`pn544`** -- so the device node is /dev/pn544 and the class entry is
#      /sys/class/misc/pn544. And `pn544` is ALSO a different driver in the same tree
#      (drivers/nfc/pn544, `nxp,pn544-i2c`), a different chip family that has nothing to do with this
#      node. Grepping for the name you can see in /dev finds the wrong driver; that is why this probe
#      prints all four and says which node it is actually reading.
#
# THE THREE NESTED WITNESSES, because the ladder below rests on the nesting. The i2c CLIENT
# (/sys/bus/i2c/devices/<bus>-<addr>) is created by the i2c core from the device tree as soon as the
# adapter registers -- it exists with NO NFC driver built at all. The BIND (a symlink under the driver
# directory) needs the driver built, registered, and its probe to have got past the three fatal reads
# and the clock string. The MISC DEVICE (/sys/class/misc/pn544) needs the probe to have run to the end,
# because `misc_register()` is called after the clock and the gpios and every failure path after it
# deregisters. So each witness needs strictly more than the one before, and on this port the first one
# is present while the second and third are not.
#
# WHAT THIS CANNOT SAY: whether NFC works. A client, a bound driver and a misc device are the software
# path being in place -- none of them is a card read, and after them the chip is still powered DOWN
# until userspace asks for power.
#
# **Read-only, and it writes nothing at all** -- not even a scratch file, which is why the kernel log is
# captured into a shell variable. The one surface a reader is most tempted to touch is NOT a sysfs
# attribute: it is the device node itself.
#   * `/dev/pn544` is never opened. A `read()` there waits on the IRQ and then does an `i2c_master_recv`
#     FROM THE CHIP; a `write()` does an `i2c_master_send` TO IT, i.e. it speaks NCI to the controller;
#     and `ioctl(NFC_SET_PWR, 0|1|2)` drives VEN and the firmware-download pin and switches the ref
#     clock -- power off, power on, or download mode. This probe opens no device node at all, and it
#     does not stat it as a device: it reads the CLASS entry, which is a plain file.
#   * the driver's own gpios: nowhere in sysfs. nq-nci.c creates no attributes, no class and no module
#     parameters, so the misc entry is the only file surface the block has -- which is itself a reading
#     (there is no `state` file here to misread, unlike the writeback switch).
#   * the device-tree properties `qcom,nq-*`, `qcom,clk-src` and the two `nxp,p61-*` names are boot-image
#     decisions, not runtime knobs, and this probe reads them as such.
#
# Usage (on the device):
#   sh zl1-nfc-probe.sh             # every rung, then a verdict
#   sh zl1-nfc-probe.sh --quiet     # the verdict and the readings it rests on
#   sh zl1-nfc-probe.sh --explain   # what each reading decides, and why this reading
#
# Exit: 0 the client exists, the driver is bound and its misc device is registered;
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
MISC_PRESENT=no
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
# numbers. Handing a u32 property to the string reader prints control characters -- `clocks  JI.18.5` -- which
# is a line nobody can use and which hides that the value is a number.
#
# THE TEST IS ON THE BYTES, and "all printable" is not enough on its own: a one-cell property like
# `qcom,nq-ven`'s neighbour `reg = <0x28>` is three NUL bytes and a `(`, which IS all-printable once the NULs
# are dropped. A device-tree STRING is NUL-TERMINATED and never carries two NULs in a row (an empty string
# does not occur), so the shape of a string property is: printable-or-NUL bytes, a NUL as the LAST byte, no
# two NULs adjacent, and at least one non-NUL byte.
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
# BYTE-SWAPPED -- an i2c address of 0x28 comes out as a number of the right shape and the wrong value. The
# four bytes are combined explicitly, and anything that is not exactly four bytes says so.
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
# node's gpio cells is a phandle to a gpio controller, and printing the raw number would leave the reader
# to guess -- and the number is not the identity: a miss here is `unresolved`, and two nodes carrying the
# same phandle is `AMBIGUOUS(N)`. But the SAME node can carry the same phandle TWICE -- as `phandle` and
# as the older `linux,phandle`, which every node on this board does -- and counting matches rather than
# nodes would call that one node ambiguous with itself.
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
  # The LABEL when the node has one: on this board the two gpio controllers are told apart by
  # 'pm8994-gpio' and 'pm8994-mpp', and a bare path would leave a reader to work out which is which.
  _ph_lbl=$(dtstr "$_ph_first/label")
  case "$_ph_lbl" in
  absent | EMPTY) printf '%s' "${_ph_first#/proc/device-tree}" ;;
  *) printf '%s (label %s)' "${_ph_first#/proc/device-tree}" "$_ph_lbl" ;;
  esac
}
# A property whose every cell is a phandle (a pinctrl state), resolved cell by cell. The pinmux state
# groups on this board are NAMED for this block -- `pmx_rd_nfc_int` and `pmx_nfc_reset` -- so they are a
# reading about the block rather than decoration, and a single-cell read of a two-cell property would have
# printed one of them as if it were the whole state.
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
# A gpio property as the driver would read it: a phandle, a pin number and a flag cell. The controller is
# named, because on THIS node the two generations do not agree about which controller their power enable
# lives on, and a bare pin number cannot show that.
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
# compatible is `qcom,nq-nci`, the i2c driver's `.name` is `nq-nci` (so the directory is
# /sys/bus/i2c/drivers/nq-nci), its `i2c_device_id` is `nqx-i2c`, and the misc device it registers is
# named `pn544`. Four names, four different answers to "what is this block called", and only the second
# one is a path in sysfs.
drivers_for() { # $1 = compatible
  case "$1" in
  qcom,nq-nci)
    printf 'nq-nci\tCONFIG_NFC_NQ\tdrivers/nfc/nq-nci.c\ti2c\tby of_match "qcom,nq-nci" (its i2c_device_id is "nqx-i2c" and its misc device is named "pn544")\n'
    ;;
  qcom,i2c-msm-v2)
    printf 'i2c-msm-v2\tCONFIG_I2C_MSM_V2\tdrivers/i2c/busses/i2c-msm-v2.c\tplatform\tby of_match "qcom,i2c-msm-v2" (the bus this node sits on)\n'
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
# The driver row for ONE node: the same three lines the scan loop prints, for the nodes this block owns
# but the scan does not look for (the i2c controller the node sits on). It exists because the matching in
# `drivers_for` is what carries the config option that decides this block, and a match nothing calls
# prints nothing.
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

if [ "$MODE" = explain ]; then
  cat <<'EOF'
zl1 NFC probe -- what each reading decides, and why it is this reading

  1. THE TWO NAMESPACES ON ONE NODE. `/soc/i2c@75b6000/nq@28` (`qcom,nq-nci`) carries `qcom,nq-ven`,
     `qcom,nq-irq`, `qcom,nq-firm`, `qcom,nq-clkreq` and `qcom,clk-src` -- what nfc_parse_dt() asks for --
     and `nxp,p61-pwr` / `nxp,p61-rst`, which nothing in this kernel reads. The two do not agree about the
     pins either: the driver's power enable is a TLMM pin, the unread one is a PMIC pin. The probe prints
     both, and says which namespace each line came from.

  2. WHAT THE DRIVER DOES WITH EACH MISSING PROPERTY. Three are fatal: `qcom,nq-ven` and `qcom,nq-irq`
     make nfc_parse_dt() return -EINVAL, and so does a missing `qcom,clk-src`. Two are not: a missing
     `qcom,nq-firm` is a dev_warn and a missing `qcom,nq-clkreq` a dev_err. So "the node is complete" and
     "the driver can bind" are different questions and this probe answers them separately.

  3. THE STRING THAT IS A SWITCH. `if (!strcmp(clk_src_name, "BBCLK2"))` -- anything else takes the else
     branch, which is `goto err_free_dev`, so the probe fails. The driver supports exactly one clock source
     name and this board carries it.

  4. THE CONFIG LINE OUTSIDE THE MENU, WHICH IS THE READING THIS BLOCK TURNS ON. `config NFC_NQ` is in
     drivers/nfc/Kconfig AFTER the `endmenu` of the menu that `depends on NFC`. So `CONFIG_NFC` is not a
     precondition for it -- and the two kernels this project has in hand show why that matters: the stock
     boot image's kernel has `# CONFIG_NFC is not set` AND `CONFIG_NFC_NQ=y` (built, with the menu off),
     while the Halium kernel this port boots has both off. The same `CONFIG_NFC` line appears in both. The
     probe prints both lines and decides on CONFIG_NFC_NQ.

  5. THE TWO `#ifdef`s THAT ARE DEFINED NOWHERE. `CONFIG_NFC_HW_CHECK` and `NFC_KERNEL_BU` exist only as
     `#ifdef` uses in nq-nci.c: no Kconfig symbol, no -D. Both off means no hardware presence check at
     probe, and no power-on either -- the driver drives VEN LOW and leaves the ref clock off. Power comes
     from userspace, through the NFC_SET_PWR ioctl.

  6. THE THREE NESTED WITNESSES. The i2c CLIENT exists from the device tree alone, with no NFC driver
     built. The BIND needs the driver built, registered and its probe past the three fatal reads and the
     clock string. The MISC DEVICE (/sys/class/misc/pn544) needs the probe to have run to the END, because
     misc_register() comes after the clock and the gpios and every later failure path deregisters it. Each
     needs strictly more than the one before -- so "the client is there" is the weakest reading in this
     block and the one a probe is most likely to mistake for "NFC is there".

  7. FOUR NAMES FOR ONE BLOCK. `qcom,nq-nci` is the compatible; `nq-nci` is the i2c driver's `.name`, and it
     is the ONLY one of the four that is a path in sysfs (/sys/bus/i2c/drivers/nq-nci); `nqx-i2c` is its
     `i2c_device_id`, which a non-device-tree match would key on and which is NOT a path; and `pn544` is the
     MISC device it registers, so that is the name in /dev -- and also the name of a DIFFERENT driver in this
     same tree (drivers/nfc/pn544, `nxp,pn544-i2c`). Grepping for the name you can see in /dev finds the
     wrong driver.

  WHAT THIS CANNOT SAY: that NFC works. And even with all three witnesses in place the chip is powered
  DOWN until something issues NFC_SET_PWR -- a call this probe does not make, because it opens no device.
EOF
  exit 0
fi

# The device-tree guard comes AFTER the explain page on purpose: `--explain` reads nothing, and refusing it
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
  always "               carries both boards' trees (5 LE_ZL1 + 23 LE_X2), and BOTH declare an NFC"
  always "               controller at the same path with the same bytes -- so the tree's shape cannot"
  always "               tell you whose reading this is, and only 'model' can. Everything below is the"
  always "               other phone's."
  ;;
unknown)
  always "   board:      UNKNOWN -- /proc/device-tree/model could not be read, so which board's tree this is"
  always "               cannot be told from here. The readings below are still taken, and this is named"
  always "               in the verdict rather than being silently assumed to be a zl1."
  ;;
*) always "   board:      neither LE_ZL1 nor LE_X2 -- nothing below can be attributed to this phone" ;;
esac

# --- 2. the kernel's own config, read BEFORE the sections that ask about it -------------------------
#
# This has to come first: the driver section asks whether the option that builds the driver is set -- and a
# shell function is only defined once its definition has EXECUTED, so defining `cfg_opt` below the caller
# would fail at every call.
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
  "$1=m") printf 'm (module -- it needs a .ko in the rootfs)' ;;
  "# $1 is not set") printf 'NOT SET' ;;
  *) printf 'absent from the config' ;;
  esac
}

# --- 3. the node the device tree declares ----------------------------------------------------------
hdr "the NFC node the device tree declares"
NODES=""
NC_RC=0
NC_OUT=$(nodes_with qcom,nq-nci); _rc=$?
[ "$_rc" = 2 ] && NC_RC=2
NODES="$NC_OUT"
N_NODES=0
[ -n "$NODES" ] && N_NODES=$(printf '%s\n' $NODES | grep . | wc -l | tr -d ' ')

NFC_NODE=""
if [ "$NC_RC" = 2 ]; then
  DT_RUNG=unscanned
  always ""
  always "   the device tree could not be searched for 'qcom,nq-nci' at all: find(1) is missing AND no"
  always "   known node shape exists. This is NOT 'the tree declares no NFC controller' -- it is 'this"
  always "   probe could not look', and the two must not print the same way."
elif [ -z "$NODES" ]; then
  DT_RUNG=no-node
  always ""
  always "   no node in this device tree carries 'qcom,nq-nci' -- the running tree declares no NFC"
  always "   controller at all. The path is not assumed: the whole tree is scanned."
else
  DT_RUNG=node
  always ""
fi

# The bus the node sits on, the address the i2c core will use, and the name sysfs will give the client.
NODE=""
I2C_PARENT=""
I2C_ADDR=""
CLIENT_NAME=""
CLIENT_ADDR=""
I2C_ALIAS=""
if [ "$DT_RUNG" = node ]; then
  NODE=$(printf '%s\n' $NODES | grep . | sed -n 1p)
  [ "$N_NODES" != 1 ] && always "   ($N_NODES nodes carry this compatible; the first is read below)"
  I2C_PARENT=$(dirname "$NODE")
  always "   ${NODE#/proc/device-tree}"
  always "     compatible:  $(dtlist "$NODE/compatible")"
  ST=$(dtstr "$NODE/status")
  # AN ABSENT `status` IS ENABLED. This node carries none on every one of the 15 zl1 trees, and the same
  # reading decided the writeback panel and the HDMI transmitter -- a probe that read `absent` as "not
  # okay" would report this block as switched off by its own tree.
  case "$ST" in
  okay | ok | EMPTY | absent) NODE_EN=yes ;;
  *) NODE_EN=no ;;
  esac
  case "$ST" in
  absent) always "     status:      absent (an absent status means enabled; this node carries none)" ;;
  *) always "     status:      $ST" ;;
  esac
  # Every OTHER property the node carries, printed where the node is read rather than left to a grep --
  # a probe that printed only the five the driver asks for would hide the second namespace entirely.
  say "     other properties on this node:"
  for _p in "$NODE"/*; do
    [ -r "$_p" ] || continue
    _bn=$(basename "$_p")
    case "$_bn" in compatible | status) continue ;; esac
    _sz=$(wc -c < "$_p" 2>/dev/null | tr -d ' ')
    case "$_sz" in
    0) say "       $(printf '%-24s' "$_bn") (a boolean, no value)" ;;
    *)
      say "       $(printf '%-24s' "$_bn") $(dtprop "$_p")"
      ;;
    esac
  done
  # THE PROPERTIES THE DRIVER READS, EACH WITH WHAT HAPPENS IF IT IS MISSING. This is the list from
  # nfc_parse_dt(), and the ordering is the driver's own: two fatal gpios, one optional gpio, the clock
  # source STRING (fatal), and the clock-request gpio (read but checked leniently at probe).
  always ""
  always "   the five properties nfc_parse_dt() reads, and what a MISSING one does:"
  always "     qcom,nq-ven      $(gpio_cells "$NODE/qcom,nq-ven")"
  always "                      FATAL if invalid: nfc_parse_dt() returns -EINVAL and probe() never runs."
  always "                      This is the pin the driver calls the hardware reset / power enable."
  always "     qcom,nq-irq      $(gpio_cells "$NODE/qcom,nq-irq")"
  always "                      FATAL if invalid, the same way. The driver takes the IRQ FROM THIS GPIO:"
  always "                      it computes gpio_to_irq() and OVERWRITES client->irq with it."
  always "     qcom,nq-firm     $(gpio_cells "$NODE/qcom,nq-firm")"
  always "                      OPTIONAL: a missing one is a dev_warn and the pin is simply not driven."
  always "     qcom,nq-clkreq   $(gpio_cells "$NODE/qcom,nq-clkreq")"
  always "                      NOT checked in parse_dt; at probe an invalid value is only a dev_err."
  _clk=$(dtstr "$NODE/qcom,clk-src")
  always "     qcom,clk-src     $_clk"
  case "$_clk" in
  BBCLK2)
    always "                      FATAL if the read fails, and A SWITCH IF THE VALUE IS NOT 'BBCLK2':"
    always "                      the driver compares it and takes 'goto err_free_dev' on any other value."
    always "                      This board carries the one name the driver supports."
    ;;
  absent | EMPTY) always "                      ABSENT, AND THAT IS FATAL: of_property_read_string() fails, r is"
    always "                      non-zero, and nfc_parse_dt() returns -EINVAL -- the probe never runs." ;;
  *) always "                      AND THIS IS THE FAILING CASE: the driver accepts only 'BBCLK2', so this"
    always "                      value takes 'goto err_free_dev' -- the probe runs and then fails." ;;
  esac
  # THE SECOND NAMESPACE. Named as unread because it IS unread: no .c, no .h and no Kconfig in this
  # kernel source asks for either name.
  always ""
  always "   AND THE PROPERTIES NOTHING IN THIS KERNEL READS:"
  for _p in "nxp,p61-pwr" "nxp,p61-rst"; do
    if [ -r "$NODE/$_p" ]; then
      always "     $(printf '%-16s' "$_p") $(gpio_cells "$NODE/$_p")"
    else
      always "     $(printf '%-16s' "$_p") absent on this node"
    fi
  done
  always "                      NOTHING ASKS FOR THESE. They are a later generation's spelling of the same"
  always "                      lines, on the same node, and the pins do not even match the ones the"
  always "                      driver uses -- so a reading that said 'the node has a power enable' without"
  always "                      saying WHICH namespace it came from would be reporting a line no driver asks"
  always "                      for as if it were the wiring."
  # The bus. If this node's parent is disabled, no client is ever created and no config line can help.
  always ""
  always "   the i2c bus this node sits on:"
  always "     ${I2C_PARENT#/proc/device-tree}"
  always "       compatible: $(dtlist "$I2C_PARENT/compatible")"
  _bst=$(dtstr "$I2C_PARENT/status")
  case "$_bst" in
  absent) always "       status:     absent (an absent status means enabled; this controller carries none)" ;;
  *) always "       status:     $_bst" ;;
  esac
  # The alias is the BUS NUMBER, and the client's sysfs name is built from it plus the address. Both are
  # printed even when one is missing, because the name below is DERIVED and a derived name that quietly
  # became a guess would be the defect this whole probe is about.
  for _a in /proc/device-tree/aliases/*; do
    [ -r "$_a" ] || continue
    [ "$(dtstr "$_a")" = "${I2C_PARENT#/proc/device-tree}" ] || continue
    I2C_ALIAS=$(basename "$_a")
  done
  I2C_ADDR=$(dtu32 "$NODE/reg")
  case "$I2C_ADDR" in
  absent | not-a-u32* | '') always "       reg:        $I2C_ADDR -- the i2c address is what makes this node a client at all" ;;
  *)
    # The sysfs client name is `%d-%04x` of the adapter's number and this address, so the address is
    # formatted the way the kernel formats it -- 0x28 becomes 0028, not 28.
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
      always "                   actually there: a client it finds that way is real, and the alias is what is"
      always "                   missing."
      ;;
    esac
    ;;
  esac
  # The node's own interrupt description, against the one the driver ends up using.
  _ints=$(dtprop "$NODE/interrupts")
  always "       interrupts:  $_ints   interrupt-names: $(dtprop "$NODE/interrupt-names")"
  always "                   AND THE DRIVER OVERWRITES WHATEVER THIS SAYS: client->irq is replaced with"
  always "                   gpio_to_irq() of 'qcom,nq-irq'. Two descriptions of one interrupt, and they do"
  always "                   not have to agree -- here both name the same controller and the same line"
  always "                   number, so on this board the overwrite is invisible; in general it is not."
  say "       clocks:      $(dtprop "$NODE/clocks")   clock-names: $(dtprop "$NODE/clock-names")"
  say "       pinctrl-names: $(dtlist "$NODE/pinctrl-names")"
  always "       pinctrl-0 (the ACTIVE state):  $(phandle_list "$NODE/pinctrl-0")"
  always "       pinctrl-1 (the suspend state): $(phandle_list "$NODE/pinctrl-1")"
  always "                   and the state groups are NAMED for this block: 'pmx_rd_nfc_int' and"
  always "                   'pmx_nfc_reset' are the two pins the driver reads, so the pinmux the tree"
  always "                   configures for this node is this node's."
  # WHICH OF THE THREE FATAL READS THE TREE IS MISSING. This is a fact about the TREE, and the verdict for a
  # driver that did not bind is more useful when it carries it: a missing qcom,nq-ven is enough on its own
  # to make nfc_parse_dt() fail, before any clock or gpio is looked at.
  FATAL_MISSING=""
  case "$(gpio_cells "$NODE/qcom,nq-ven")" in
  absent | not-a-gpio*) FATAL_MISSING="$FATAL_MISSING qcom,nq-ven" ;;
  esac
  case "$(gpio_cells "$NODE/qcom,nq-irq")" in
  absent | not-a-gpio*) FATAL_MISSING="$FATAL_MISSING qcom,nq-irq" ;;
  esac
  case "$_clk" in
  absent | EMPTY) FATAL_MISSING="$FATAL_MISSING qcom,clk-src" ;;
  BBCLK2) : ;;
  *) FATAL_MISSING="$FATAL_MISSING qcom,clk-src (not the one value the driver supports)" ;;
  esac
  always ""
  always "   the tree on the three FATAL reads:${FATAL_MISSING:- NONE MISSING -- all three are present and valid}"
  case "$FATAL_MISSING" in
  '') : ;;
  *) always "     (a missing or invalid one of these makes nfc_parse_dt() return -EINVAL, so the driver is"
     always "      refused the node before the clock or any gpio is touched -- the node never binds, whatever"
     always "      the config says.)" ;;
  esac
  # The driver for the controller itself, since a disabled or unbuilt bus means no client.
  node_driver_row "$(printf '%s' "$(dtstr "$I2C_PARENT/compatible")")"
fi

# --- 4. the driver, and the config line that decides this block -------------------------------------
hdr "the driver this block needs"
DRV=$(drivers_for qcom,nq-nci)
DN=$(printf '%s' "$DRV" | cut -f1)
DC=$(printf '%s' "$DRV" | cut -f2)
DF=$(printf '%s' "$DRV" | cut -f3)
DB=$(printf '%s' "$DRV" | cut -f4)
DH=$(printf '%s' "$DRV" | cut -f5)
if [ "$DN" = none ]; then
  SRC_MATCH=none
  always "   NO DRIVER IN THIS KERNEL SOURCE MATCHES 'qcom,nq-nci' -- nothing can bind this node under any"
  always "   config, so no config line can fix it."
else
  SRC_MATCH=yes
  always "   driver:      $DN   ($DF, $DB)"
  always "                $DH"
  always "                built by $DC -- and see the two lines below before reading that as 'the option'."
fi
_cg_e=no; [ -e /proc/config.gz ] && _cg_e=yes
_cg_r=no; [ -r /proc/config.gz ] && _cg_r=yes
_cg_d=no; [ -n "$CFG_SRC" ] && _cg_d=yes
always "   /proc/config.gz: $_cg_e present / $_cg_r permission-readable / $_cg_d expanded"
[ -n "$CFG_SRC" ] && say "   source:      $CFG_SRC"
# THE TWO COLUMNS ARE PRINTED WHATEVER HAPPENED TO THE FILE. Printing them only when the config was read
# would make "the config could not be read" look like a page with no config line on it at all -- and the
# third state has to be visible exactly where the other two are, or a reader compares nothing with nothing.
always ""
always "   the two lines that have to be read TOGETHER, per the kernel's own config:"
always "     CONFIG_NFC_NQ             $(cfg_opt CONFIG_NFC_NQ)"
always "     CONFIG_NFC                $(cfg_opt CONFIG_NFC)"
always ""
if [ -n "$CFG_SRC" ]; then
  always "   AND THE SECOND ONE IS NOT A PRECONDITION FOR THE FIRST, which is the reading this block turns"
  always "   on. In drivers/nfc/Kconfig, 'config NFC_NQ' sits AFTER the 'endmenu' of 'menu \"Near Field"
  always "   Communication (NFC) devices\"' -- the menu that 'depends on NFC'. So CONFIG_NFC gates every"
  always "   driver INSIDE that menu and does NOT gate this one, whose only dependency is I2C."
  always "   The two kernels this project has in hand prove it: the stock boot image's kernel carries"
  always "   '# CONFIG_NFC is not set' AND 'CONFIG_NFC_NQ=y' -- the driver is BUILT with the menu off --"
  always "   while the Halium kernel this port boots has both off. THE SAME CONFIG_NFC LINE APPEARS IN"
  always "   BOTH, so a reader who checked the obvious one would get the same answer from a kernel that"
  always "   has the driver and one that does not. The rung below is decided on CONFIG_NFC_NQ."
  always ""
  always "   AND THE TWO SWITCHES THAT ARE DEFINED NOWHERE: CONFIG_NFC_HW_CHECK and NFC_KERNEL_BU appear"
  always "   in nq-nci.c ONLY as '#ifdef' uses. There is no Kconfig symbol and no -D for either in this"
  always "   kernel source, so both blocks are OFF, which means:"
  always "     * no hardware presence check at probe (the code under CONFIG_NFC_HW_CHECK is not compiled);"
  always "     * NO POWER-ON AT PROBE (the gpio_set_value(en_gpio, 1) under NFC_KERNEL_BU is not compiled),"
  always "       so a bound driver drives VEN LOW and leaves the ref clock off. Power comes from userspace:"
  always "       ioctl NFC_SET_PWR (1 = on, 2 = download mode, 0 = off) on the misc device."
  always "   A reading that stopped at 'the driver is built and bound' would therefore describe a live"
  always "   controller that is not live."
else
  always "   -- the kernel config could NOT be read: either the file is not there, or it is there and this"
  always "      device has neither zcat(1) nor gunzip(1) to expand it, or it could not be read at all. The"
  always "      config columns are therefore NOT READ -- which is a third state, and not 'the option is off'."
  always "      The driver directory in sysfs needs no decompressor, so the verdict below rests on it and NOT"
  always "      on the config."
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
say "     (the driver's .name is '$DN'; its i2c_device_id is 'nqx-i2c', which is what a non-DT match"
say "      would key on, and it is NOT a path in sysfs)"

# --- 5. the runtime traces the chain leaves behind --------------------------------------------------
hdr "the runtime traces this chain leaves behind -- three witnesses, each needing more than the last"
# The FIRST witness: the i2c client. The core creates it from the device tree as soon as the adapter
# registers, so it exists with NO NFC driver built at all -- which is exactly why it must not be the read
# the verdict rests on.
CLIENT_FOUND=no
CLIENT_WHY=""
CLIENT_ACTUAL=""
if [ -n "$CLIENT_ADDR" ]; then
  if [ -n "$CLIENT_NAME" ] && [ -e "/sys/bus/i2c/devices/$CLIENT_NAME" ]; then
    CLIENT_FOUND=yes; CLIENT_WHY=derived; CLIENT_ACTUAL="$CLIENT_NAME"
  else
    # Before calling that an absence: the name above is DERIVED, and the bus number inside it comes from the
    # ALIAS rather than from the adapter's own sysfs. An entry with this ADDRESS under a DIFFERENT bus
    # number is the derived name being wrong, not the client being missing -- two different next moves, and
    # they must not print the same way.
    for _d in /sys/bus/i2c/devices/*-"$CLIENT_ADDR"; do
      [ -e "$_d" ] || continue
      CLIENT_FOUND=yes; CLIENT_WHY=address; CLIENT_ACTUAL="$(basename "$_d")"
    done
  fi
fi
if [ "$CLIENT_FOUND" = yes ]; then
  always "   1. the i2c client /sys/bus/i2c/devices/$CLIENT_ACTUAL: PRESENT"
  case "$CLIENT_WHY" in
  derived)
    always "      and it is under EXACTLY the name derived above (bus $I2C_ALIAS, address $CLIENT_ADDR)."
    ;;
  address)
    always "      BUT NOT UNDER THE NAME DERIVED ABOVE: $I2C_ALIAS gives bus ${CLIENT_NAME%%-*}, while the"
    always "      adapter registered under a different number. The client exists; the ALIAS is what is wrong,"
    always "      and the next move is the controller's alias rather than the NFC driver."
    ;;
  esac
  always "      and this is the WEAKEST witness in the block: the i2c core creates the client from the"
  always "      device tree as soon as the adapter registers, so it is here with NO NFC driver built at"
  always "      all. A probe that asked 'is NFC present?' this way would answer yes on the kernel this"
  always "      port boots, whose config has the driver off."
elif [ -n "$CLIENT_ADDR" ]; then
  always "   1. the i2c client /sys/bus/i2c/devices/$CLIENT_NAME: ABSENT"
  always "      and nothing under /sys/bus/i2c/devices carries address $CLIENT_ADDR either, so the node really"
  always "      did not become a client: the bus node is disabled or its own driver is not built, or 'reg' is"
  always "      not a usable address. No driver can bind without a client, so this outranks every driver"
  always "      question below it."
else
  always "   1. the i2c client: CANNOT BE LOOKED FOR -- this node's address did not read as a u32, so neither"
  always "      the client's name nor the address to look for can be derived from the tree (see the 'reg' line"
  always "      above). What IS actually there:"
  for _d in /sys/bus/i2c/devices/*; do
    [ -e "$_d" ] || continue
    always "        $(basename "$_d")"
  done
fi
# The SECOND witness: a symlink under the driver directory -- the probe got past the fatal reads.
say ""
say "   2. a device bound to '$DN' -- needs the driver built, registered, and nfc_parse_dt() to have"
say "      passed all three fatal reads and the 'BBCLK2' string:"
say "        $( [ -n "${DRV_BOUND:-}" ] && printf '%s' "$DRV_BOUND" || printf 'NONE' )"
# The THIRD witness: the misc device. misc_register() runs AFTER the clock and the gpios, and every later
# failure path calls misc_deregister() -- so a present misc device means the probe ran to the end.
MISC_DIR=/sys/class/misc/pn544
say ""
if [ -d "$MISC_DIR" ]; then
  MISC_PRESENT=yes
  always "   3. $MISC_DIR: PRESENT"
  always "      dev:       $(rd "$MISC_DIR/dev") -- major:minor, i.e. a DEVICE NODE exists for this entry."
  always "                 This probe reads the CLASS entry and never the node; see the note below."
  always "      and this is the strongest witness here: misc_register() is called AFTER the clock and the"
  always "      gpios, and every failure path after it calls misc_deregister() -- so a present misc device"
  always "      means the probe ran all the way to the end."
  always "      THE NAME IS 'pn544' AND THE CHIP IS AN NQ. The misc device is named 'pn544' for the"
  always "      userspace stack's benefit, and 'pn544' is ALSO a different driver in this same tree"
  always "      (drivers/nfc/pn544, compatible 'nxp,pn544-i2c', a different chip family) -- so grepping for"
  always "      the name you can see in /dev finds the wrong driver."
  always "      AND IT IS NOT OPENED HERE. A read() on /dev/pn544 waits on the IRQ and then does an"
  always "      i2c_master_recv FROM THE CHIP; a write() does an i2c_master_send TO it, i.e. it speaks NCI"
  always "      to the controller; and ioctl(NFC_SET_PWR, 0|1|2) drives VEN and the firmware-download pin"
  always "      and switches the ref clock. Every one of those changes the hardware's state, so this probe"
  always "      reads the class entry and opens no device node at all."
else
  MISC_PRESENT=no
  always "   3. $MISC_DIR: ABSENT -- no misc device, so nq-nci_probe() did not run to the end. Because"
  always "      misc_register() comes after clk_get()/clk_prepare_enable(), after the four gpio requests and"
  always "      after the dma_pool allocation, and every failure path after it deregisters, an absent misc"
  always "      device means one of THOSE steps failed -- and a driver that failed after misc_register()"
  always "      would have deregistered it again. The kernel log section below says which."
fi
say ""
say "   THE NESTING IS THE READING: client (tree + bus only) < bound (driver built, registered, probe's"
say "   fatal reads passed) < misc device (the probe ran to the END). Each needs strictly more than the"
say "   one before, and this block's whole ladder is those three plus the tree above them."

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
  always "   the kernel log could not be read (neither dmesg nor journalctl -b -k returned anything)"
  always "   -- so this section is NOT READ. No verdict below rests on it: the rungs are decided on files,"
  always "   and the log only says WHY a driver that should have bound did not."
else
  always "   source: $LOG_SRC"
  show "$LOG_TEXT" 'nq-nci|nqx|nfcc|pn544|nfc|NFC' \
    "(none: the kernel log mentions no NFC driver this boot)" 25 1
  # The failure strings, taken from the sources rather than guessed. nq-nci.c prints "unable to request
  # gpio [%d]", "dis gpio not provided", "irq gpio not provided", "clkreq gpio not provided", "BBCLK2
  # clock not provided", "misc_register failed", "request_irq failed", "unable to disable clock" and
  # "unable to enable clock".
  show "$LOG_TEXT" 'dis gpio not provided|irq gpio not provided|clkreq gpio not provided|firm gpio not provided|BBCLK2 clock not provided|unable to request gpio|misc_register failed|request_irq failed|unable to enable clock|unable to disable clock|probe .* failed|failed with error' \
    "(none: no NFC probe failure in this boot's log)" 20 1
  always ""
  always "   A LINE ABOUT NFC IN THIS LOG WOULD BE EVIDENCE THAT THE KERNEL READ A CONFIG OTHER THAN THE ONE"
  always "   ABOVE: this driver's strings can only appear if the driver ran, and a kernel whose CONFIG_NFC_NQ"
  always "   is not set never runs it. So the two readings have to agree -- and if the log mentions nq-nci"
  always "   while the config column above says NOT SET, the config file is not the running kernel's."
fi

# --- verdict ---------------------------------------------------------------------------------------
# The rung the evidence reaches, named. Each rung is a different problem with a different next move, and
# the first ones are a different BOARD and a different SEARCH.
N_BUILT=$(cfg_opt CONFIG_NFC_NQ)
if [ "$DT_RUNG" = unscanned ]; then
  V=tree-unscanned
  VMSG="the device tree could not be searched for 'qcom,nq-nci' (no find(1), and no known node shape exists). Nothing about this board's NFC controller was read, so nothing here is a verdict about it."
elif [ "$BOARD" = x2 ]; then
  V=wrong-board-tree
  VMSG="this boot is running the LE_X2's device tree, not this phone's. Both boards declare an NFC node at the same path with the same bytes, so the tree's shape cannot tell them apart and only 'model' can -- nothing below is about the zl1. The next move is about which DTB the bootloader picked."
elif [ "$BOARD" = other ] || [ "$BOARD" = unknown ]; then
  V=unknown-board
  VMSG="the device tree's model names neither LE_ZL1 nor LE_X2 (read: $MODEL), so this reading cannot be attributed to this phone. The readings below stand on their own; the attribution does not."
elif [ "$DT_RUNG" = no-node ]; then
  V=no-device-tree-node
  VMSG="this device tree declares no node with 'qcom,nq-nci': the NFC controller is not described at all, so the i2c core creates no client for it and no driver can bind. That is a boot-image (device tree) fact, not a runtime fault -- and on this board the node is in all 15 of its trees, so this rung means the tree being read is not the tree this phone boots with."
elif [ "$SRC_MATCH" = none ]; then
  V=no-driver-for-node
  VMSG="the tree declares the node and NO driver in this kernel source matches 'qcom,nq-nci' -- so nothing can bind it under any config. This is a property of the kernel SOURCE, not of a build option. (On the kernel this project has, it cannot be the rung: nq-nci.c is in the source and its compatible matches.)"
elif [ "$NODE_EN" = no ]; then
  V=no-node-enabled
  VMSG="the NFC node carries a status that is not okay, so the tree switches the block off by its own decision and the i2c core creates no client for it. Note what this board's node actually carries: NO status property at all, which the device tree reads as ENABLED."
elif [ "$CLIENT_FOUND" = no ]; then
  V=no-client
  VMSG="the driver exists in this kernel's source and the node is enabled, but the i2c CORE never created the client -- so the bus node is disabled or its own driver is not built, or 'reg' is not a usable address. NO CONFIG LINE FOR THE NFC DRIVER CAN FIX THIS, which is why it outranks the driver rungs below: the next move is the i2c controller the node sits on."
elif [ "$DRV_REG" = no ]; then
  # The config is a SEPARATE AXIS from sysfs, and it is allowed to disagree. Where sysfs says the driver
  # did not register, the config is asked WHY -- and `NOT READ` is a third answer, not "the option is off".
  case "$N_BUILT" in
  "NOT SET" | "absent from the config")
    V=driver-not-built
    VMSG="the driver is in this kernel's source, nothing is registered, and THE KERNEL'S OWN CONFIG DOES NOT BUILD IT (CONFIG_NFC_NQ: $N_BUILT). So this is not a fault on the board and not a wiring problem: it is one defconfig line and a boot-image build. Check the SECOND line in the config section before believing it -- CONFIG_NFC is off in the kernel this port boots AND in the stock kernel that HAS the driver, so the obvious line does not decide this."
    ;;
  *) V=driver-not-registered
     VMSG="the driver is in this kernel's source and nothing is registered, but this is NOT attributed to a config line here: CONFIG_NFC_NQ reads '$N_BUILT'. Either the option is 'm' and the module is not in the rootfs, or the config could not be read at all -- which is a third state, and neither of those is 'the kernel does not build it'."
     ;;
  esac
elif [ -z "${DRV_BOUND:-}" ]; then
  V=driver-not-bound
  VMSG="the driver is registered and NOTHING is bound to the NFC node, so its probe ran and failed -- or never ran against this client. nq-nci_probe() fails on a missing/invalid qcom,nq-ven or qcom,nq-irq, on a missing qcom,clk-src, on any clk-src value other than 'BBCLK2', on a failed clk_get() of the 'ref_clk' clock, on any of the four gpio requests, and on the dma_pool allocation."
  case "$FATAL_MISSING" in
  '') : ;;
  *) VMSG="$VMSG AND THE TREE ITSELF IS THE CAUSE: it is missing or invalid on$FATAL_MISSING, which alone makes nfc_parse_dt() return -EINVAL and refuses the node to the driver. That is a device-tree (boot image) fact, and no runtime action fixes it -- but read the next rung first: a driver that is not built never reads the tree at all." ;;
  esac
  VMSG="$VMSG The properties section above names every read, and the kernel log section says which one failed."
elif [ "$MISC_PRESENT" = no ]; then
  V=no-misc-device
  VMSG="the driver is bound but its misc device is not registered, so nq-nci_probe() failed AFTER the bind point -- which on this driver means after misc_register() and then deregistered it (a failed request_irq does exactly that). The next move is the kernel log section above."
else
  V=nfc-ready
  VMSG="the i2c client exists, the driver is bound to it, and the misc device is registered -- so the whole chain from the device tree to a registered character device is in place, and the readings above are readings rather than placeholders."
fi

always ""
always "== verdict: $V"
always "   $VMSG"

# The thing a verdict about this block must say out loud: the three witnesses are the software path, and
# the chip is still off.
if [ "$V" = nfc-ready ]; then
  always ""
  always "   AND THE CHIP IS STILL POWERED DOWN, WHICH IS NOT A FAULT. CONFIG_NFC_HW_CHECK and NFC_KERNEL_BU"
  always "   are defined nowhere in this kernel source, so the probe neither checks for the hardware nor"
  always "   powers it: VEN is driven LOW and the ref clock is off. Power comes from userspace through"
  always "   ioctl(NFC_SET_PWR) on the misc device -- 1 = on, 2 = download mode, 0 = off. Nothing has asked"
  always "   for it on this boot unless something opened that node, so the absence of NFC traffic says"
  always "   'nobody asked', not 'the controller is dead'. The probe does not ask: that call is the"
  always "   write-class move of this block, and it drives real pins."
fi

always ""
always "   WHAT THIS IS NOT: an answer to 'does NFC work'. An i2c client, a bound driver and a registered"
always "   misc device are the software path being in place -- none of them is a card read, and the"
always "   controller is powered down until something issues NFC_SET_PWR. This probe writes NOTHING at all"
always "   (no scratch file) and opens no device node: it reads the tree, sysfs and the kernel's own config."

[ "$V" = nfc-ready ] && exit 0
exit 1
