#!/bin/sh
# zl1 EEPROM probe -- the last block in this project with no instrument, and the only one where NOTHING is
# missing: the driver is built in both kernels, the tree leaves the node enabled, and the one thing that makes
# it bind travels through a name the tree never spells.
#
# Why this exists. doc 137 enumerated this board's hardware from its own device trees and named the blocks
# nothing in this tree reads. Eleven of the twelve have been closed, and every one of them had exactly one
# obstacle: `nfc` a config line outside the menu that gates it, `fm-radio` a `status = "disabled"` the tree
# wrote itself, `hdmi` a transmitter the tree switches on and the kernel cannot bind. THIS ONE HAS NONE.
# Five readings make this probe's design, and the first is that difference:
#
#   1. THERE IS NOTHING MISSING HERE, WHICH IS WHY THIS PROBE ASKS A DIFFERENT QUESTION. `CONFIG_EEPROM_AT24=y`
#      in BOTH kernels this project has in hand -- the vendor boot image's 3.18.120 kernel AND the v63 Halium
#      3.18.140 kernel this port boots -- and `CONFIG_SYSFS=y` in both, which is the Kconfig's other
#      dependency (`config EEPROM_AT24` is `depends on I2C && SYSFS`). The node carries NO `status`, which the
#      device tree reads as ENABLED, and it is the ordinary case -- the FM receiver one bus over is the one
#      whose tree switches it off. So the ladder's job is not to find the single missing thing but to say
#      WHICH OF THE THREE WITNESSES IS PRESENT, and a verdict here is a statement about the software path.
#   2. IT BINDS ONLY BECAUSE TWO TABLES AGREE, AND THE MATCH TRAVELS THROUGH A NAME THE TREE NEVER SPELLS.
#      `at24_of_match[]` has exactly ONE entry, `{ .compatible = "atmel,24c32" }`, and the i2c driver's
#      `.name` is `at24` (so the directory is /sys/bus/i2c/drivers/at24). But the function that runs is
#      `at24_probe(client, id)` where `id` comes from `i2c_match_id(driver->id_table, client)`, and a
#      DEVICE-TREE client's `client->name` is the compatible with the VENDOR PREFIX STRIPPED by
#      `of_modalias_node()`: `atmel,24c32` -> `24c32`. That is exactly an `at24_ids[]` entry
#      (`{ "24c32", AT24_DEVICE_MAGIC(32768 / 8, AT24_FLAG_ADDR16) }`), so `id->driver_data` is non-zero --
#      and if it were zero, probe() would `return -ENODEV` before touching the chip. **The two tables are not
#      alternatives: the of_match is what lets the node match at all, and the id_table is what the match
#      actually carries.** A tree spelling `atmel,24c64` would find no match; a compatible whose stripped form
#      is not in the id_table would match and then be refused.
#      AND THE STRIPPED NAME IS THE ONE THE KERNEL PRINTS: `client->name` is what appears in `/sys/bus/i2c/
#      devices/8-0051/name` and in every `dev_info` line, so the chip on the bus is called `24c32` and the
#      driver's directory is called `at24` -- neither of them is the word this block's row is named after.
#   3. THE TREE'S TWO PROPERTIES AND THE DRIVER'S TWO PROPERTIES DO NOT INTERSECT. The node carries
#      `compatible` and `reg`, and that is its whole description. `at24_get_ofdata()` asks the tree for
#      exactly two more: `read-only` (tested for PRESENCE, i.e. a boolean) and `pagesize` (one cell). NEITHER
#      IS HERE, and both absences have consequences the probe prints: no `read-only` means the sysfs attribute
#      is WRITABLE, and no `pagesize` means `chip.page_size` stays 1, which caps a single write at 1 byte
#      (`io_limit` is 128, so the smaller of the two wins). So the tree is silent about the only two things
#      the driver can be told -- and the size and the writability are visible only in the kernel log, which is
#      why the log section of this probe is not decoration.
#   4. THE READ PATH AND THE WRITE PATH ARE THE SAME FILE. `at24_probe()` ends by creating ONE binary sysfs
#      attribute, `sysfs_create_bin_file(&client->dev.kobj, &at24->bin)` with `attr.name = "eeprom"` and
#      `size = chip.byte_len`: `/sys/bus/i2c/devices/8-0051/eeprom`. Reading it runs `at24_bin_read()` ->
#      `at24_read()` -> `i2c_transfer()`; writing it runs `at24_bin_write()` -> `at24_write()` -> `i2c_transfer()`.
#      So on this block there is no separate read surface to look at safely: **"look at the EEPROM" and
#      "overwrite the EEPROM" are the same path with a different redirect**, and a stray `>` on a line that was
#      meant to read is a write to the chip. This probe reads neither: it reads the attribute's EXISTENCE and
#      the device directory's other files (`name`, `modalias`, the driver symlink) and nothing else.
#      AND THERE IS A SECOND PATH TO THE SAME CHIP, one level below the driver: `CONFIG_I2C_CHARDEV=y` in both
#      kernels, so `i2c-dev` is built and a `/dev/i2c-N` node for this bus, if it exists, can address slave
#      0x51 directly. The probe names whether that node exists and opens neither it nor the attribute.
#   5. THE WORD IS NOT THE BLOCK. Three different things in this tree are called `eeprom`, and only one of
#      them is this block: this block's ROW in the inventory is `eeprom`; the sysfs ATTRIBUTE the driver
#      creates is also called `eeprom`; and `drivers/misc/eeprom/eeprom.c` is a SECOND driver whose `.name` is
#      `eeprom` and whose attribute is `eeprom` too -- with NO `of_match_table`, so it can never be matched
#      from a device tree, and `CONFIG_EEPROM_LEGACY` is NOT SET in either kernel, so it is not even in the
#      kernel that is running. A reader grepping `eeprom` finds it and finds the wrong thing. And two more
#      nodes on this board carry `qcom,eeprom` in their path -- `qcom,eeprom@0` / `qcom,eeprom@1` under
#      `/soc/qcom,cci@a0c000`, the CAMERA's on-chip calibration memories, which are a different row of the
#      same gap list and are read by the camera stack, not by this driver.
#
# WHAT THIS CANNOT SAY, AND IT MATTERS MORE HERE THAN IN ANY SIBLING: whether the chip's CONTENTS are intact,
# or what they are. The tree says nothing about the contents, no property describes them, and the only way to
# see them is the path this probe refuses. A bound driver and a present attribute are the software path being
# in place -- not a checksum, and not a copy.
#
# **Read-only, and it writes nothing at all** -- not even a scratch file, which is why the kernel log is
# captured into a shell variable. The two surfaces a reader is most tempted to touch are both called out
# above: `/sys/bus/i2c/devices/*/eeprom` is never read or written, and no `/dev/i2c-N` is opened.
#
# Usage (on the device):
#   sh zl1-eeprom-probe.sh             # every rung, then a verdict
#   sh zl1-eeprom-probe.sh --quiet     # the verdict and the readings it rests on
#   sh zl1-eeprom-probe.sh --explain   # what each reading decides, and why this reading
#
# Exit: 0 the node is enabled, the driver is bound and its `eeprom` attribute is present;
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
ATTR_FOUND=no
DRV_REG=no
DRV_BOUND=""
SRC_MATCH=yes
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
# THE TEST IS ON THE BYTES, and "all printable" is not enough on its own: a one-cell property like the i2c
# address is three NUL bytes and a `Q`, which IS all-printable once the NULs are dropped. A device-tree
# STRING is NUL-TERMINATED and never carries two NULs in a row (an empty string does not occur), so the shape
# of a string property is: printable-or-NUL bytes, a NUL as the LAST byte, no two NULs adjacent, and at least
# one non-NUL byte.
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
# BYTE-SWAPPED -- an i2c address of 0x51 comes out as a number of the right shape and the wrong value. The
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
# A property the driver reads with `of_property_read_u32()` is ONE cell: longer is truncated, absent fails.
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
# Every node whose PATH or `compatible` carries a word -- how a reader's grep would look, and how this probe
# shows that the word is not the block. It counts NODES, not matches, and it is deliberately not the same
# scan as `nodes_with`: the point is the set the word finds, which is larger than the set this block owns.
nodes_named() { # $1 = a word; prints paths one per line
  if type find >/dev/null 2>&1; then
    find /proc/device-tree -name compatible 2>/dev/null | while read -r _nn_c; do
      _nn_p=${_nn_c%/compatible}
      _nn_hit=0
      case "$_nn_p" in *"$1"*) _nn_hit=1 ;; esac
      if [ "$_nn_hit" = 0 ] && tr '\0' '\n' < "$_nn_c" 2>/dev/null | grep -qi -- "$1"; then _nn_hit=1; fi
      [ "$_nn_hit" = 1 ] && printf '%s\n' "$_nn_p"
    done
    return 0
  fi
  for _nn_p in /proc/device-tree/soc/* /proc/device-tree/soc/*/* /proc/device-tree/soc/*/*/* \
    /proc/device-tree/soc/*/*/*/* /proc/device-tree/*; do
    [ -d "$_nn_p" ] || continue
    _nn_hit=0
    case "$_nn_p" in *"$1"*) _nn_hit=1 ;; esac
    if [ "$_nn_hit" = 0 ] && tr '\0' '\n' < "$_nn_p/compatible" 2>/dev/null | grep -qi -- "$1"; then _nn_hit=1; fi
    [ "$_nn_hit" = 1 ] && printf '%s\n' "$_nn_p"
  done
  return 0
}
# The driver that MATCHES a compatible, straight out of the kernel source -- each line is
# "driver-name<TAB>config-option<TAB>source-file<TAB>bus<TAB>how-it-matches". A compatible with no match
# prints `none`, which is a reading (a node nothing can bind) and not an error.
#
# THE NAME THIS PRINTS IS THE ONE SYSFS KEYS ON, and for this block that is worth spelling out: the i2c
# driver's `.name` is `at24`, so the directory is /sys/bus/i2c/drivers/at24 -- while the CLIENT's sysfs
# name, and the name in every log line, is the compatible with the vendor prefix stripped, `24c32`.
drivers_for() { # $1 = compatible
  case "$1" in
  atmel,24c32)
    printf 'at24\tCONFIG_EEPROM_AT24\tdrivers/misc/eeprom/at24.c\ti2c\tby of_match "atmel,24c32" (its id_table carries the STRIPPED name "24c32", and that is the entry `i2c_match_id()` finds -- see below)\n'
    ;;
  qcom,i2c-msm-v2)
    printf 'i2c-msm-v2\tCONFIG_I2C_MSM_V2\tdrivers/i2c/busses/i2c-msm-v2.c\tplatform\tby of_match "qcom,i2c-msm-v2" (the bus this node sits on)\n'
    ;;
  *) printf 'none\t-\t-\t-\t-\n' ;;
  esac
}
# The drivers that CLAIM this block's word and cannot bind it, printed where the block is read. For this
# block it is not a naming coincidence: the OTHER `eeprom` driver creates an attribute with the same name,
# and it is not even built into the kernel that is running.
near_miss_driver() {
  printf 'eeprom\tdrivers/misc/eeprom/eeprom.c\tCONFIG_EEPROM_LEGACY\tNO of_match_table at all -- cannot be matched from a device tree, and its own sysfs attribute is ALSO named "eeprom"\n'
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

if [ "$MODE" = explain ]; then
  cat <<'EOF'
zl1 EEPROM probe -- what each reading decides, and why it is this reading

  1. THERE IS NOTHING MISSING HERE, WHICH IS WHY THIS PROBE ASKS A DIFFERENT QUESTION. `CONFIG_EEPROM_AT24=y`
     in BOTH kernels in hand (the vendor 3.18.120 one and the v63 Halium 3.18.140 one this port boots) and
     `CONFIG_SYSFS=y` in both, which is the other half of `depends on I2C && SYSFS`. The node carries no
     `status`, which the device tree reads as ENABLED -- the ordinary case: the FM receiver one bus over is
     the block whose tree switches it OFF. So every sibling probe's first job (find the one missing thing) is
     absent here, and this one's job is to say WHICH OF THE THREE WITNESSES IS PRESENT.

  2. IT BINDS ONLY BECAUSE TWO TABLES AGREE, AND THE MATCH TRAVELS THROUGH A NAME THE TREE NEVER SPELLS.
     `at24_of_match[]` has exactly one entry, `atmel,24c32`; the driver's `.name` is `at24`; and
     `at24_probe()`'s `id` comes from `i2c_match_id(driver->id_table, client)`, where a device-tree client's
     name is the compatible with the VENDOR PREFIX STRIPPED (`of_modalias_node`): `atmel,24c32` -> `24c32`.
     That IS an `at24_ids[]` entry, so `id->driver_data` is non-zero -- and a zero there returns -ENODEV
     before the chip is touched. The of_match is what lets the node match; the id_table is what the match
     carries. And the stripped name is the one the kernel prints: `24c32`, never `atmel,24c32`.

  3. THE TREE'S TWO PROPERTIES AND THE DRIVER'S TWO PROPERTIES DO NOT INTERSECT. The node is `compatible`
     plus `reg`, and that is all. `at24_get_ofdata()` asks for `read-only` (presence only) and `pagesize`
     (one cell); neither is here, so the attribute is WRITABLE and `page_size` stays 1 -- which caps one
     write at 1 byte. The size and the writability are visible only in the kernel log, which is why its
     section here is not decoration.

  4. THE READ PATH AND THE WRITE PATH ARE THE SAME FILE. `at24_probe()` ends by creating
     `/sys/bus/i2c/devices/8-0051/eeprom` (`sysfs_create_bin_file`, `size = chip.byte_len`), whose read and
     write both end in `i2c_transfer()`. So "look at the EEPROM" and "overwrite the EEPROM" are the same
     path with a different redirect. This probe reads the attribute's EXISTENCE and nothing of its contents.
     AND `CONFIG_I2C_CHARDEV=y` in both kernels, so a `/dev/i2c-N` for this bus, if it exists, is a SECOND
     path to slave 0x51 one level below the driver: named here, opened nowhere.

  5. THE WORD IS NOT THE BLOCK. This block's ROW is `eeprom`, its sysfs ATTRIBUTE is `eeprom`, and
     `drivers/misc/eeprom/eeprom.c` is another driver whose name and attribute are both `eeprom` -- with no
     of_match_table at all and `CONFIG_EEPROM_LEGACY` not set in either kernel, so a grep finds it and finds
     something that is not in the kernel. Two more nodes on this board carry `qcom,eeprom` in their path:
     the CAMERA's on-chip memories, which are a different row of the same list.

  WHAT THIS CANNOT SAY -- and it matters more here than in any sibling -- is whether the chip's CONTENTS are
  intact, or what they are. No property describes them and the only way to see them is the path this probe
  refuses. A bound driver and a present attribute are the software path in place: not a checksum.
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
  always "               carries both boards' trees, and an at24 node sits on an i2c bus in BOTH -- so the"
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
hdr "the EEPROM node the device tree declares"
NODES=""
NC_RC=0
NC_OUT=$(nodes_with atmel,24c32); _rc=$?
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
BUSNUM=""
if [ "$NC_RC" = 2 ]; then
  DT_RUNG=unscanned
  always ""
  always "   the device tree could not be searched for 'atmel,24c32' at all: find(1) is missing AND no"
  always "   known node shape exists. This is NOT 'the tree declares no EEPROM' -- it is 'this probe could"
  always "   not look', and the two must not print the same way."
elif [ -z "$NODES" ]; then
  DT_RUNG=no-node
  always ""
  always "   no node in this device tree carries 'atmel,24c32' -- the running tree declares no EEPROM at all."
  always "   The path is not assumed: the whole tree is scanned."
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
  # AND HERE THE ABSENT CASE IS THE ORDINARY ONE. Unlike the FM receiver one bus over -- which carries
  # `status = "disabled"` in all 15 trees -- this node carries NO status, and the device tree reads that as
  # ENABLED. So the probe prints the value it read AND which way round it read it.
  case "$ST" in
  okay | ok | EMPTY | absent) NODE_EN=yes ;;
  *) NODE_EN=no ;;
  esac
  case "$ST" in
  absent) always "     status:      absent (an absent status means ENABLED -- and THIS node carries none, which"
    always "                  is the ordinary case: the FM node one bus over is the one whose tree"
    always "                  switches it OFF)" ;;
  disabled | fail | reserved)
    always "     status:      $ST"
    always "                  AND THIS IS THE WHOLE ANSWER FOR THIS BLOCK. The device tree switches its own"
    always "                  EEPROM OFF, so the i2c core never instantiates the client: no driver binds, no"
    always "                  attribute is created, and no build option can change that. On this board the"
    always "                  node is in all 15 of its trees WITH NO STATUS AT ALL, so seeing 'disabled' here"
    always "                  means the tree being read is not the tree this phone boots with."
    ;;
  *) always "     status:      $ST" ;;
  esac
  # The node's WHOLE description. There are two properties, and the section below is about the two the
  # driver asks for and does not find.
  _nprops=0
  say "     every property on this node:"
  for _p in "$NODE"/*; do
    [ -r "$_p" ] || continue
    _bn=$(basename "$_p")
    _nprops=$((_nprops + 1))
    case "$_bn" in compatible | status) continue ;; esac
    _sz=$(wc -c < "$_p" 2>/dev/null | tr -d ' ')
    case "$_sz" in
    0) say "       $(printf '%-26s' "$_bn") (a boolean, no value)" ;;
    *) say "       $(printf '%-26s' "$_bn") $(dtprop "$_p")" ;;
    esac
  done
  always "                   and THAT IS THE WHOLE DESCRIPTION: $((_nprops)) properties, and every one of this"
  always "                   phone's 15 trees carries the same two. No gpios, no interrupts, no supplies and"
  always "                   no pinctrl -- the chip is a two-wire memory and the driver needs nothing else."
  # THE TWO PROPERTIES THE DRIVER ASKS THE TREE FOR AND DOES NOT FIND. Both absences have consequences, and
  # both consequences are the reason this block's sysfs surface is what it is.
  always ""
  always "   the TWO properties at24_get_ofdata() asks this node for -- and NEITHER IS HERE:"
  _ro=$(dtstr "$NODE/read-only")
  case "$_ro" in
  absent) always "     read-only   absent, so the sysfs attribute is created WRITABLE (S_IRUSR | S_IWUSR)."
    always "                 A tree that carries this property as a boolean would make it read-only -- and"
    always "                 that is the ONE thing the tree could say about this chip's data." ;;
  EMPTY) always "     read-only   PRESENT as a boolean, so the attribute is created READ-ONLY."
    always "                 (at24_get_ofdata() tests PRESENCE, not a value.)" ;;
  *) always "     read-only   = $_ro -- NOT the shape the driver tests for: it asks whether the PROPERTY"
    always "                 EXISTS, so any spelling here makes the attribute read-only." ;;
  esac
  # THE LENGTH IS NOT A GATE HERE, AND THAT IS THE POINT OF THE THIRD BRANCH. `at24_get_ofdata()` does
  # `val = of_get_property(node, name, NULL); if (val) chip->page_size = be32_to_cpup(val)` -- and
  # of_get_property() returns a pointer for a property that EXISTS whatever its length. So "the property is
  # there" and "the property is four bytes" are different questions, and a probe that folded them together
  # would print `absent` for a tree that carries a longer `pagesize` -- which is the shape this driver
  # accepts and TRUNCATES rather than refuses.
  _ps=$(dtu32 "$NODE/pagesize")
  _psn=$(dtcells "$NODE/pagesize")
  # An EMPTY property and a LONGER one are different failures of the same read, so they are told apart here
  # rather than folded into one "not a u32": the empty case is the only one whose result is undefined.
  _ps0=no
  [ -r "$NODE/pagesize" ] && [ ! -s "$NODE/pagesize" ] && _ps0=yes
  case "$_ps" in
  absent) always "     pagesize    absent, so chip.page_size stays 1 and a single write is capped at 1"
    always "                 byte (io_limit is 128, so the smaller of the two wins)." ;;
  not-a-u32*)
    if [ "$_ps0" = yes ]; then
      always "     pagesize    PRESENT but EMPTY ($_psn): of_get_property() returns a pointer for a property"
      always "                 that EXISTS, whatever its length, so at24_get_ofdata() then reads four bytes out"
      always "                 of a buffer with none in them -- chip.page_size is whatever those bytes are, NOT"
      always "                 1. A bare 'pagesize' is a different tree from one that omits the property."
    else
      always "     pagesize    PRESENT but $_psn -- NOT a single u32, and the driver's read is worth spelling"
      always "                 out for exactly that reason: of_get_property() returns a pointer for ANY length,"
      always "                 and at24_get_ofdata() then takes the FIRST CELL of it, so chip.page_size is"
      always "                 $(dtcell "$NODE/pagesize" 1) here and the cells after it are never looked at."
      always "                 AND THAT IS THE OPPOSITE OF THE FM BLOCK TWO ROWS UP, whose voltage properties"
      always "                 are read as EXACTLY two cells and fail otherwise: here longer is truncated, and"
      always "                 only the zero-length case is undefined."
    fi ;;
  *) always "     pagesize    = $_ps, so chip.page_size is $_ps. AND IT IS READ AS THE FIRST CELL ONLY:"
    always "                 at24_get_ofdata() takes of_get_property()'s buffer and reads one cell out of"
    always "                 it, so a LONGER property is truncated rather than refused -- the opposite of the"
    always "                 FM block two rows up, whose voltage properties are read as EXACTLY two cells and"
    always "                 fail on any other length. (This one is exactly $(dtcells "$NODE/pagesize").)" ;;
  esac
  always "                   AND THE TREE'S TWO PROPERTIES AND THE DRIVER'S TWO PROPERTIES DO NOT INTERSECT:"
  always "                   the node carries compatible + reg, the driver asks for read-only + pagesize, and"
  always "                   this tree answers neither. The size and the writability the driver ends up with"
  always "                   are therefore visible only in its own dev_info line -- see the log section."
  # AND THE WORD IS NOT THE BLOCK, read off THIS tree rather than asserted: a scan for `eeprom` does not
  # even FIND this node -- its path is `at24@51` and its compatible is `atmel,24c32`. What the word does
  # find is worth naming, because it is where a reader's grep lands.
  _nn_paths=$(nodes_named eeprom)
  _nn=$(printf '%s\n' "$_nn_paths" | grep . | wc -l | tr -d ' ')
  _nn_misc=""
  for _n in $_nn_paths; do
    [ "$_n" = "$NODE" ] && continue
    _nn_misc="$_nn_misc ${_n#/proc/device-tree}"
  done
  always ""
  always "   AND THE WORD 'eeprom' DOES NOT NAME THIS BLOCK IN THE TREE AT ALL: a scan for it finds"
  always "   $_nn node(s):"
  if [ -n "$_nn_misc" ]; then
    always "     $_nn_misc"
    always "                   and NONE of them is this node -- this one is 'at24@51' and carries"
    always "                   'atmel,24c32'. The nodes above carry 'qcom,eeprom': they are the CAMERA's"
    always "                   on-chip calibration memories, read by the camera stack and counted under the"
    always "                   camera row of the same list, not by this driver."
  else
    always "     (none at all -- so on this tree a grep for the word finds nothing, while this node is"
    always "      right there under a name that does not contain it.)"
  fi
  # The bus, its alias, and the other device on it.
  always ""
  always "   the i2c bus this node sits on:"
  always "     ${I2C_PARENT#/proc/device-tree}"
  always "       compatible: $(dtlist "$I2C_PARENT/compatible")"
  _bst=$(dtstr "$I2C_PARENT/status")
  case "$_bst" in
  absent) always "       status:     absent (an absent status means enabled; this controller carries none)" ;;
  *) always "       status:     $_bst" ;;
  esac
  _bfreq=$(dtu32 "$I2C_PARENT/qcom,clk-freq-out")
  case "$_bfreq" in
  absent | not-a-u32*) : ;;
  *) always "       qcom,clk-freq-out: $_bfreq -- so this bus runs at $_bfreq Hz, and every transfer the"
    always "                   attribute would issue goes at that rate" ;;
  esac
  say "       pinctrl-names: $(dtprop "$I2C_PARENT/pinctrl-names")"
  _bdma=$(dtstr "$I2C_PARENT/qcom,disable-dma")
  case "$_bdma" in
  EMPTY) say "       qcom,disable-dma is PRESENT, so this controller's transfers are done WITHOUT DMA." ;;
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
    _hex=$(printf '%x' "$I2C_ADDR")
    say "       reg:        $I2C_ADDR (0x$_hex) -- the i2c slave address, written '$CLIENT_ADDR' in a"
    say "                   client's sysfs name, and 0x$_hex on the wire"
    case "$I2C_ADDR" in
    81) always "                   AND A 24c32 ANSWERS AT 0x51 IN EVERY TREE THAT DESCRIBES ONE -- so the"
      always "                   address is a reading the tree and the chip's own name agree about, not a"
      always "                   coincidence of this node." ;;
    esac
    case "$I2C_ALIAS" in
    i2c[0-9]*)
      BUSNUM=${I2C_ALIAS#i2c}
      CLIENT_NAME="${BUSNUM}-$CLIENT_ADDR"
      always "       alias:      $I2C_ALIAS -> bus $BUSNUM, so the i2c core will name the client"
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
  # THIS BUS CARRIES EXACTLY ONE OTHER DEVICE, and it is the block the previous stage instrumented: the NFC
  # controller at 0x28. That is worth naming rather than counting, because it means a fault on this bus is a
  # fault shared with a block this project has already read carefully.
  _others=""
  for _o in "$I2C_PARENT"/*; do
    [ -d "$_o" ] || continue
    [ "$_o" = "$NODE" ] && continue
    _oc=$(dtstr "$_o/compatible")
    [ "$_oc" = absent ] && continue
    _others="$_others ${_o##*/}($_oc)"
  done
  if [ -n "$_others" ]; then
    always "       AND THIS BUS CARRIES ANOTHER DEVICE:$_others"
    always "                   so a bus-level fault would be shared with it -- and checking THIS block alone"
    always "                   could not tell the two apart. The other one is the NFC controller, which is"
    always "                   its own row of the same list and has its own probe."
  else
    always "       and this bus carries no other device in the tree."
  fi
  node_driver_row "$(dtstr "$I2C_PARENT/compatible")"
fi

# --- 4. the driver, and the config chain that decides this block ------------------------------------
hdr "the driver this block needs"
DRV=$(drivers_for atmel,24c32)
DN=$(printf '%s' "$DRV" | cut -f1)
DC=$(printf '%s' "$DRV" | cut -f2)
DF=$(printf '%s' "$DRV" | cut -f3)
DB=$(printf '%s' "$DRV" | cut -f4)
DH=$(printf '%s' "$DRV" | cut -f5)
if [ "$DN" = none ]; then
  SRC_MATCH=none
  always "   NO DRIVER IN THIS KERNEL SOURCE MATCHES 'atmel,24c32' -- nothing can bind this node under any"
  always "   config, so no config line can fix it."
else
  SRC_MATCH=yes
  always "   driver:      $DN   ($DF, $DB)"
  always "                $DH"
  always "                built by $DC -- and the chain that gates THAT is printed below."
fi
# THE MATCH PATH, which for this block is the whole reason it binds.
always ""
always "   HOW THE TWO TABLES AGREE, WHICH IS THE READING THIS BLOCK IS REALLY ABOUT:"
always "     at24_of_match[]  has exactly ONE entry: { .compatible = \"atmel,24c32\" }"
always "     the driver's      .name is \"$DN\" -- so the directory is /sys/bus/i2c/drivers/$DN"
always "     and the function that runs is at24_probe(client, id), where id comes from"
always "     i2c_match_id(driver->id_table, client) -- and a DEVICE-TREE client's name is the compatible"
always "     with the VENDOR PREFIX STRIPPED (of_modalias_node): \"atmel,24c32\" -> \"24c32\"."
always "     \"24c32\" IS an at24_ids[] entry ({ \"24c32\", AT24_DEVICE_MAGIC(32768 / 8, AT24_FLAG_ADDR16) }),"
always "     so id->driver_data is non-zero -- and a ZERO there returns -ENODEV before the chip is touched."
always "     SO THE TWO TABLES ARE NOT ALTERNATIVES: the of_match is what lets the node match at all, and"
always "     the id_table is what the match actually carries. A compatible whose stripped form is not in"
always "     the id_table would match and then be refused; this tree's does not have that problem."
always "     AND THE STRIPPED NAME IS THE ONE THE KERNEL PRINTS: the client's sysfs 'name' and every log"
always "     line say '24c32' -- never 'atmel,24c32', and never 'at24'. Three names, three different places."
# What the size and the flags work out to, said out loud rather than left as arithmetic.
always ""
always "   AND THE MAGIC DECODES TO THE CHIP THE DRIVER THINKS THIS IS:"
always "     byte_len    = BIT(magic & 31)      = 4096 bytes (a 32 kbit part)"
always "     flags       = AT24_FLAG_ADDR16     -- the address pointer is 16 bit, so every access carries"
always "                                          a two-byte offset"
always "     num_addresses = DIV_ROUND_UP(4096, 65536) = 1, so the multi-address machinery is INERT here:"
always "                                          no dummy clients are created at addr+1. A 24c64 or larger"
always "                                          WOULD create them, and an unavailable address there is an"
always "                                          -EADDRINUSE at probe time."
always "     write_max   = min(page_size, io_limit) = min(1, 128) = 1 byte"
always "     the attribute's mode = S_IRUSR | S_IWUSR, because AT24_FLAG_IRUGO is not set either"
always "     AND ALL OF THAT IS THE DRIVER'S CHOICE FROM A NAME THE TREE MERELY MATCHED: the tree says"
always "     'atmel,24c32' and every number above follows from the id_table entry that name resolves to."
always "   AND THE DRIVER BESIDE IT CAN NEVER BIND THIS NODE, which is the mistake this block invites more"
always "   than any sibling because the WORD is the same in both:"
NM=$(near_miss_driver)
always "     $(printf '%s' "$NM" | cut -f1)  $(printf '%s' "$NM" | cut -f2)"
always "       $(printf '%s' "$NM" | cut -f3)  -- and it is the shape of the near miss that matters:"
always "       $(printf '%s' "$NM" | cut -f4)"
_legacy=$(cfg_opt CONFIG_EEPROM_LEGACY)
always "       option:     $_legacy"
case "$_legacy" in
"NOT SET" | "absent from the config")
  always "                   so this is not a driver that CANNOT bind -- it is one that IS NOT IN THE"
  always "                   RUNNING KERNEL at all. Its sysfs attribute would ALSO be named 'eeprom', and"
  always "                   its source file is named after the word, which is why the word is not enough." ;;
*) always "                   and that is the reading, not an assumption: the kernels in hand do not set it,"
  always "                   so on THIS board the near miss is absent rather than merely unable to bind." ;;
esac
always "     A reader who grepped for 'eeprom' would find this file, and it is not in the running kernel."
_cg_e=no; [ -e /proc/config.gz ] && _cg_e=yes
_cg_r=no; [ -r /proc/config.gz ] && _cg_r=yes
_cg_d=no; [ -n "$CFG_SRC" ] && _cg_d=yes
always "   /proc/config.gz: $_cg_e present / $_cg_r permission-readable / $_cg_d expanded"
[ -n "$CFG_SRC" ] && say "   source:      $CFG_SRC"
always ""
always "   the CHAIN that gates the option, per the kernel's own config -- TWO parents, and both on:"
always "     CONFIG_I2C                   $(cfg_opt CONFIG_I2C)"
always "     CONFIG_SYSFS                 $(cfg_opt CONFIG_SYSFS)"
always "     CONFIG_EEPROM_AT24           $(cfg_opt CONFIG_EEPROM_AT24)"
always "     CONFIG_EEPROM_LEGACY         $(cfg_opt CONFIG_EEPROM_LEGACY)   <- the OTHER 'eeprom' driver's"
always "                                                                    option, and the one beside it"
always ""
if [ -n "$CFG_SRC" ]; then
  always "   AND THIS OPTION IS GATED BY ITS MENU, in the ordinary way: 'config EEPROM_AT24' sits inside"
  always "   'menu \"EEPROM support\"' in drivers/misc/eeprom/Kconfig and declares 'depends on I2C && SYSFS' --"
  always "   TWO parents, both of which are on. (Two blocks elsewhere in this list are the exceptions worth"
  always "   remembering: the NFC option sits AFTER the endmenu of the menu that gates it, and the FM node is"
  always "   refused by the device tree while its option is on. A probe that assumed any one of the three"
  always "   shapes would read the wrong thing in the other two.)"
  always ""
  always "   AND ON THIS BOARD THERE IS NOTHING MISSING AT ALL -- in BOTH kernels this project has in hand:"
  always "   the vendor boot image's 3.18.120 kernel AND the v63 Halium 3.18.140 kernel this port boots both"
  always "   carry 'CONFIG_EEPROM_AT24=y' with 'CONFIG_SYSFS=y'. So unlike every block closed before it, this"
  always "   one has no missing piece for a ladder to find: the driver is built, the tree leaves the node"
  always "   enabled, and the ladder below is about HOW FAR THE CHAIN RAN, not about which link is gone."
else
  always "   -- the kernel config could NOT be read: either the file is not there, or it is there and this"
  always "      device has neither zcat(1) nor gunzip(1) to expand it, or it could not be read at all. The"
  always "      columns above are therefore NOT READ -- which is a third state, and not 'the option is off'."
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
say "     (the driver's .name is '$DN' -- that is the directory name above; the CLIENT's name is the"
say "      stripped compatible, '24c32', which is what a reader would find in the device directory)"

# --- 5. the runtime traces the chain leaves behind --------------------------------------------------
hdr "the runtime traces this chain leaves behind"
# The FIRST witness: the i2c client. The core creates it from the device tree as soon as the adapter
# registers -- and this is the witness that is weakest, because it needs no driver at all.
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
  always "      AND ITS 'name' FILE IS A READING OF ITS OWN: it is the compatible with the vendor prefix"
  always "      stripped, so it reads '24c32' -- not the tree's 'atmel,24c32' and not the driver's 'at24'."
  say "      name=$(rd "/sys/bus/i2c/devices/$CLIENT_ACTUAL/name")  modalias=$(rd "/sys/bus/i2c/devices/$CLIENT_ACTUAL/modalias")"
elif [ -n "$CLIENT_ADDR" ]; then
  always "   1. the i2c client /sys/bus/i2c/devices/$CLIENT_NAME: ABSENT"
  always "      and nothing under /sys/bus/i2c/devices carries address $CLIENT_ADDR either. FOR THIS BLOCK"
  always "      THAT IS NOT EXPECTED: this node carries no status, so the i2c core SHOULD have instantiated"
  always "      it, and its absence points at the bus (or the alias) rather than at the chip."
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
say "   2. a device bound to '$DN' -- needs the node ENABLED, the driver built and registered, and the"
say "      of_match / id_table pair to have delivered a client name the id_table knows:"
say "        $( [ -n "${DRV_BOUND:-}" ] && printf '%s' "$DRV_BOUND" || printf 'NONE' )"
# The THIRD witness: the `eeprom` bin attribute, created by the LAST statement of the probe.
ATTR_FOUND=no
ATTR_SIZE=""
say ""
if [ -n "$CLIENT_ACTUAL" ] && [ -d "/sys/bus/i2c/devices/$CLIENT_ACTUAL" ]; then
  always "   3. the files in /sys/bus/i2c/devices/$CLIENT_ACTUAL:"
  for _f in "/sys/bus/i2c/devices/$CLIENT_ACTUAL"/*; do
    [ -e "$_f" ] || continue
    _fb=$(basename "$_f")
    case "$_fb" in
    eeprom)
      ATTR_FOUND=yes
      # THE SIZE IS NOT READ FROM HERE: `wc -c` on a sysfs bin attribute returns 0 because the kernel
      # generates it on demand, and READING it would drive the bus. What is printed is that it EXISTS.
      always "      $_fb   <- THE ATTRIBUTE THIS DRIVER CREATES, and the ONLY data surface this block has."
      always "              IT IS READ-WRITE AND IT IS NOT TOUCHED HERE: reading it runs at24_bin_read() ->"
      always "              i2c_transfer() over as many chunks as the size needs, and writing it runs"
      always "              at24_bin_write() -> at24_write() -> i2c_transfer() with the same path. So"
      always "              'look at the EEPROM' and 'overwrite the EEPROM' are one path with two redirects."
      always "              The SIZE is chip.byte_len (4096 for this part) and it is set on the attribute at"
      always "              creation -- but it is not readable as a file's size here, which is why the log"
      always "              section below is where the size and the writability are actually read."
      ;;
    name | modalias | uevent | power | subsystem | driver | of_node)
      say "      $_fb"
      ;;
    *) say "      $_fb" ;;
    esac
  done
  if [ "$ATTR_FOUND" = yes ]; then
    always "      AND THE ATTRIBUTE IS THE STRONGEST WITNESS HERE: sysfs_create_bin_file() is the LAST"
    always "      FALLIBLE thing at24_probe() does -- after the chip's magic was decoded from the id_table,"
    always "      after the adapter was checked for I2C_FUNC_I2C, after the possible dummy clients, the zero"
    always "      checks and the write-buffer allocation. (Only i2c_set_clientdata(), a dev_info() and an"
    always "      optional chip.setup() follow it, and none of those can fail.) So an 'eeprom' file"
    always "      existing means the probe reached its END, not merely that a client exists."
  else
    always "      and there is NO 'eeprom' file in it: the attribute is the last thing the probe creates, so"
    always "      its absence means the probe did not reach sysfs_create_bin_file()."
  fi
else
  always "   3. the device directory cannot be listed -- no client was found, and the attribute can only"
  always "      exist inside it. That is the expected shape when the client is missing."
fi
# THE SECOND PATH TO THE SAME CHIP, named and not taken. i2c-dev is built into both kernels; whether a node
# exists for THIS bus is the device's own answer -- and "the config could not be read" is a third state that
# must not print as "there is no userspace path".
say ""
_CDEV=$(cfg_opt CONFIG_I2C_CHARDEV)
case "$_CDEV" in
"NOT SET" | "absent from the config")
  always "   AND THE SAME CHIP HAS NO USERSPACE PATH BELOW THIS DRIVER: CONFIG_I2C_CHARDEV is $_CDEV, so"
  always "   i2c-dev is not available and the sysfs attribute above is the ONLY way to reach this chip."
  ;;
"NOT READ")
  always "   AND WHETHER THE SAME CHIP HAS A SECOND, DRIVERLESS PATH IS NOT READ: the config could not be"
  always "   read, so whether i2c-dev is built cannot be said from here. What IS there is the device's own"
  always "   answer, and it is listed rather than interpreted:"
  _any=0
  for _dev in /dev/i2c-*; do
    [ -e "$_dev" ] || continue
    _any=1
    always "     $_dev"
  done
  [ "$_any" = 0 ] && always "     (none: no /dev/i2c-* node exists here)"
  always "   NOT OPENED, whichever it is: an i2c-dev write is a write to the chip, and an ioctl-then-write is a"
  always "   driverless way to reach slave 0x$CLIENT_ADDR with no at24 driver in the path at all."
  ;;
*)
  always "   AND THE SAME CHIP HAS A SECOND PATH, ONE LEVEL BELOW THIS DRIVER, WHICH THIS PROBE DOES NOT TAKE:"
  always "   CONFIG_I2C_CHARDEV is $_CDEV, so i2c-dev is built -- and a userspace program could address slave"
  always "   0x$CLIENT_ADDR on this bus directly, with no at24 driver in the path at all. What is there:"
  _any=0
  for _dev in /dev/i2c-*; do
    [ -e "$_dev" ] || continue
    _any=1
    _devn=${_dev#/dev/i2c-}
    if [ -z "$BUSNUM" ]; then
      always "     $_dev   (the bus number is not derivable from the tree, so whether this is this block's"
      always "                  bus cannot be said here)"
    else
      case "$_devn" in
      "$BUSNUM")
        always "     $_dev   <- THIS BUS, so the chip is reachable from userspace without this driver."
        always "                  NOT OPENED, and neither is any other: an i2c-dev write is a write to the chip."
        ;;
      *) always "     $_dev   (not this block's bus)" ;;
      esac
    fi
  done
  [ "$_any" = 0 ] && always "     (none: /dev/i2c-* does not exist here, so the module is built but no adapter node was"
  [ "$_any" = 0 ] && always "      created -- which the at24 attribute above is unaffected by.)"
  ;;
esac
say ""
say "   THE NESTING IS THE READING: client (tree plus bus only -- it exists with NO at24 driver built) <"
say "   bound (the driver built, registered, and the id_table name resolving so probe() does not return"
say "   -ENODEV) < attribute (the probe ran to its LAST statement). Each needs strictly more than the one"
say "   before, and on THIS board the difference matters because nothing is missing: a chain that stops has"
say "   stopped, not been refused."

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
  always "   this section is NOT READ. No verdict below rests on it, but NOTE WHAT IS LOST: the SIZE and the"
  always "   WRITABILITY of the chip appear nowhere else -- the tree does not carry them and the attribute's"
  always "   size is not readable as a file. On a device where this section cannot be read, this block's"
  always "   numbers are unavailable rather than absent."
else
  always "   source: $LOG_SRC"
  always "   THE DRIVER'S OWN dev_info LINE IS THE ONLY PLACE THE SIZE AND THE WRITABILITY APPEAR, because"
  always "   the tree carries neither and the attribute's size is not a file size here:"
  show "$LOG_TEXT" 'byte .* EEPROM|EEPROM, .*writable|at24' \
    "(none: the kernel log names no at24 device this boot)" 15 1
  always ""
  show "$LOG_TEXT" 'io_limit must not be 0|page_size must not be 0|looks suspicious|address 0x[0-9a-f]* unavailable|cannot write due to controller restrictions|Falling back to' \
    "(none: no at24 probe complaint in this boot's log)" 15 1
  always ""
  always "   HOW TO READ THAT LINE: it is printed as \"%zu byte %s EEPROM, %s, %u bytes/write\" -- so"
  always "   '4096 byte 24c32 EEPROM, writable, 1 bytes/write' says the size the id_table entry gave, the"
  always "   stripped name the client got, and that no read-only property was found (writable) with a"
  always "   one-byte write cap (no pagesize). THREE of those four facts are properties this tree does NOT"
  always "   carry -- which is why the log is a reading here and not a confirmation of one."
  always ""
  always "   AND A LINE ABOUT THIS DRIVER IN THE LOG WOULD CONTRADICT A DISABLED NODE: a driver's strings"
  always "   can only appear if its probe ran, and a node the tree switches off is never instantiated -- so"
  always "   'at24' in the log plus 'disabled' in the tree is a contradiction worth chasing."
fi

# --- verdict ---------------------------------------------------------------------------------------
# The rung the evidence reaches, named. Each rung is a different problem with a different next move, and
# the first ones are a different BOARD and a different SEARCH.
N_BUILT=$(cfg_opt CONFIG_EEPROM_AT24)
if [ "$DT_RUNG" = unscanned ]; then
  V=tree-unscanned
  VMSG="the device tree could not be searched for 'atmel,24c32' (no find(1), and no known node shape exists). Nothing about this board's EEPROM was read, so nothing here is a verdict about it."
elif [ "$BOARD" = x2 ]; then
  V=wrong-board-tree
  VMSG="this boot is running the LE_X2's device tree, not this phone's. An at24 node sits on an i2c bus in both, so the tree's shape cannot tell them apart and only 'model' can -- nothing below is about the zl1. The next move is about which DTB the bootloader picked."
elif [ "$BOARD" = other ] || [ "$BOARD" = unknown ]; then
  V=unknown-board
  VMSG="the device tree's model names neither LE_ZL1 nor LE_X2 (read: $MODEL), so this reading cannot be attributed to this phone. The readings below stand on their own; the attribution does not."
elif [ "$DT_RUNG" = no-node ]; then
  V=no-device-tree-node
  VMSG="this device tree declares no node with 'atmel,24c32': the EEPROM is not described at all, so no client is created for it and no driver can bind. On this board the node IS in all 15 of its trees, so this rung means the tree being read is not the tree this phone boots with."
elif [ "$SRC_MATCH" = none ]; then
  V=no-driver-for-node
  VMSG="the tree declares the node and NO driver in this kernel source matches 'atmel,24c32' -- so nothing can bind it under any config. This is a property of the kernel SOURCE, not of a build option."
elif [ "$NODE_EN" = no ]; then
  V=no-node-enabled
  VMSG="the device tree SWITCHES THIS BLOCK OFF: the EEPROM node carries 'status = $(dtstr "$NODE/status")', so the i2c core never instantiates a client for it and nothing below can exist -- whatever the kernel was built with. ON THIS BOARD THAT WOULD BE SURPRISING: the node is in all 15 of this phone's trees with NO status at all, which the device tree reads as enabled. So this rung is more likely to be another tree than a decision about this chip."
elif [ "$CLIENT_FOUND" = no ]; then
  V=no-client
  VMSG="the node is enabled and a driver exists in this kernel's source, but the i2c CORE never created the client -- so the bus node is disabled or its own driver is not built, or 'reg' is not a usable address. NO CONFIG LINE FOR THE AT24 DRIVER CAN FIX THIS, which is why it outranks the driver rungs below it: the next move is the i2c controller the node sits on."
elif [ "$DRV_REG" = no ]; then
  case "$N_BUILT" in
  "NOT SET" | "absent from the config")
    V=driver-not-built
    VMSG="the driver is in this kernel's source, nothing is registered, and THE KERNEL'S OWN CONFIG DOES NOT BUILD IT (CONFIG_EEPROM_AT24: $N_BUILT). Check the CHAIN above before believing it: this option has TWO parents (I2C and SYSFS), and either being off would read as this. AND NOTE WHAT THIS RUNG IS NOT ON THIS BOARD: both kernels in hand carry 'CONFIG_EEPROM_AT24=y' with SYSFS on, so if the device reports this rung the config being read is not the one the kernel booted with."
    ;;
  *) V=driver-not-registered
     VMSG="the driver is in this kernel's source and nothing is registered, but this is NOT attributed to a config line here: CONFIG_EEPROM_AT24 reads '$N_BUILT'. Either the option is 'm' and the module is not in the rootfs, or the config could not be read at all -- which is a third state, and neither of those is 'the kernel does not build it'."
     ;;
  esac
elif [ -z "${DRV_BOUND:-}" ]; then
  V=driver-not-bound
  VMSG="the driver is registered and NOTHING is bound to the EEPROM node, so either the match never happened or at24_probe() ran and failed. The match is where this block can fail QUIETLY: at24_probe() returns -ENODEV before touching the chip if the id_table entry's driver_data is zero, which for a device-tree client depends on the compatible STRIPPING TO a name the id_table carries -- 'atmel,24c32' -> '24c32'. After that it can fail on a missing I2C_FUNC_I2C (with AT24_FLAG_ADDR16 that is -EPFNOSUPPORT), on a zero page_size (-EINVAL), on a dummy client it cannot create (-EADDRINUSE), or on the sysfs attribute itself."
elif [ "$ATTR_FOUND" = no ]; then
  V=no-eeprom-attribute
  VMSG="the driver is bound but its 'eeprom' attribute is not in the device directory. sysfs_create_bin_file() is the LAST FALLIBLE statement at24_probe(), so this means something before it failed -- and the two candidates that come after the bind are the dummy clients (none here, num_addresses is 1 for a 4096-byte part) and the attribute creation itself. The kernel log section above says which."
else
  V=eeprom-exposed
  VMSG="the node is enabled, the i2c client exists, the driver is bound to it, and the attribute the driver creates as its LAST statement is present -- so the whole chain from the device tree to a readable sysfs file is in place. AND NOTE WHAT THIS RUNG IS: the software path, not the chip's data. The attribute is present; its CONTENTS were not read, and reading them is the one thing this probe refuses."
fi

always ""
always "== verdict: $V"
always "   $VMSG"

# What a verdict about this block must say out loud: the attribute is a door, not a copy of what is behind it.
if [ "$V" = eeprom-exposed ]; then
  always ""
  always "   AND THE ATTRIBUTE IS A DOOR, WHICH IS NOT A FAULT. This probe read its EXISTENCE and none of its"
  always "   contents: /sys/bus/i2c/devices/$CLIENT_ACTUAL/eeprom runs i2c transfers on READ as well as on"
  always "   write, so 'looking' is a bus action on a chip that holds a board's calibration or serial data --"
  always "   and the same path with a '>' in front of it overwrites that data. Nothing here says the contents"
  always "   are intact, or what they are: that would take a read, and this project's answer to 'what is in"
  always "   it' has to be a decision someone makes on purpose, not a probe's side effect."
fi

always ""
always "   WHAT THIS IS NOT: an answer to 'is the EEPROM good'. An enabled node, a bound driver and a present"
always "   attribute are the software path in place -- none of them is a checksum, and the chip's contents are"
always "   exactly what was not read. This probe writes NOTHING at all (no scratch file), opens NO device"
always "   node, and never opens /sys/bus/i2c/devices/*/eeprom or /dev/i2c-*, which are the same chip by two"
always "   different routes."

[ "$V" = eeprom-exposed ] && exit 0
exit 1
