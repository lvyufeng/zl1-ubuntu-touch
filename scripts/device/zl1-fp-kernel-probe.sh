#!/bin/sh
# zl1 fingerprint-at-the-kernel-layer probe -- this board's device tree declares TWO fingerprint blocks, and
# the kernel this phone boots builds a driver for exactly ONE of them.
#
# Why this exists. The fingerprint is one of this project's three "measured offline only" peripherals, and
# the whole of its history here is the ANDROID side: a missing store directory (docs 83), a HAL that takes
# more than a wrapper to reach (docs 98), the store directory that is really `/data/vendor_de/0/fpdata`
# (docs 126). Every one of those is a layer ABOVE the kernel. Nothing in this tree had read the layer BELOW
# it -- which of this board's fingerprint blocks the running kernel has a driver for at all. That reading is
# here, and it is not a summary of the above: it is a different fact, and it points the other way.
#
# The readings that make this probe's design:
#
#   1. THERE ARE TWO BLOCKS, AND THEY ARE NOT THE SAME SENSOR. The device tree declares
#      `/soc/spi@7579000/goodixfp@0` with `compatible = "goodix,fingerprint"` and
#      `input-device-name = "gf318m"` -- a Goodix capacitive sensor on the SPI controller at 0x7579000 --
#      and `/soc/qcom,qbt1000` with a child node `qcom,fingerprint-sensor-ssc-spi-conn` (Quality's
#      ultrasonic QBT1000, whose child describes an SSC SPI port). BOTH are in all five of this phone's
#      stock device trees, in every variant (DVT1 / EVT / NA / PVT): this is not two phones' trees, it is
#      one phone's tree declaring two sensors. And the word `fingerprint` names NEITHER of them in sysfs.
#   2. THE ONE THE ANDROID HAL OPENS IS THE ONE WITH NO DRIVER IN THE RUNNING KERNEL. The container's
#      fingerprint HAL is the Goodix one -- docs 98 read `goodix_sensor_init/enroll/match` out of
#      `fingerprint.msm8996.so` and `/dev/goodix_fp` out of the same binary. `/dev/goodix_fp` is created by
#      `drivers/input/goodixfp/gf_spi.c`, whose Kconfig option is `CONFIG_INPUT_GP5XX8` -- and the config
#      THIS PHONE'S KERNEL WAS BUILT WITH (read out of the kernel image's own embedded config, not out of a
#      defconfig file) says `# CONFIG_INPUT_GP5XX8 is not set`. The driver is not in the kernel, so nothing
#      binds the SPI node, so no `/dev/goodix_fp` can exist, so that HAL's open() can never succeed -- which
#      is a fact no amount of `fpdata`-directory work above it can change.
#      **THE CORRECTION THIS MAKES TO THIS PROJECT'S OWN RECORD**: docs 98 named `/dev/goodix_fp` as one of
#      the layers below the wrapper, and `zl1-fingerprint-probe.sh` CHECKS for it -- but nothing had asked
#      whether it could exist. A probe that reads "the node is absent" every boot is not a reading of the
#      driver, it is a reading of the absence. This probe reads the node that decides it.
#   3. AND THE ONE THAT IS BUILT IS NOT THE ONE THE HAL OPENS. `CONFIG_MSM_QBT1000=y` in the same embedded
#      config, and the driver's own strings are in the kernel image (`qbt1000_probe`, `qbt1000_key_input`).
#      So on this phone the kernel has a fingerprint driver -- for the OTHER fingerprint sensor. "There is a
#      fingerprint driver in the kernel" and "the fingerprint sensor's driver is in the kernel" are two
#      different sentences, and they have different answers here.
#   4. THE OBSTACLE IS ONE CONFIG LINE, AND THAT IS A DIFFERENT KIND OF FINDING FROM THE SIBLINGS'. The
#      twelve blocks docs 138-148 closed each had an obstacle that had to be FOUND (a `status` the tree
#      wrote, a config line outside its own menu, a name the tree never spells). This one is not hidden at
#      all: `CONFIG_INPUT_GP5XX8` is a plain line in `drivers/input/goodixfp/Kconfig`, the node is enabled,
#      the SPI controller it sits on IS built (`CONFIG_SPI_QUP=y`) and its own driver registered. What the
#      probe therefore has to establish is not WHERE the obstacle is but WHICH BLOCK each statement is
#      about -- because the two blocks' answers are opposite, and a single sentence would average them.
#   5. THE WORD IS NOT THE BLOCK, THREE WAYS. (a) The block's sysfs name is neither `goodix,fingerprint`
#      nor `fingerprint`: the SPI driver's `.name` is `goodix_fp` (so the directory is
#      /sys/bus/spi/drivers/goodix_fp), the char device it creates is `goodix_fp`, the kernel thread of that
#      name is `goodix_fp_spi`, and the input device it registers is `gf318m`. Four names, none of them the
#      compatible. (b) A third fingerprint driver exists in this tree and is a THIRD option:
#      `drivers/input/fpc1020` (`CONFIG_INPUT_FPC1020`, also not set), with no node on this board at all --
#      and `zl1-fingerprint-probe.sh` looks for its sysfs path, so that name is already in this project's
#      vocabulary. (c) `qcom,fingerprint-sensor-ssc-spi-conn` LOOKS like a compatible and is not one: it is
#      the qbt1000 CHILD's node NAME, and the qbt1000 driver keys on it with `of_node_cmp()` against
#      `child_node->name`, with no `compatible` property involved anywhere. The child carries none -- which
#      is why this block does not appear in this project's DTB-derived inventory at all.
#   6. THE GOODIX DRIVER HAS A TRAP THAT A CONFIG LINE WOULD NOT FIX, AND IT IS WORTH READING BEFORE ANYONE
#      TURNS THE OPTION ON. `gf_init()` claims a FIXED major number (`register_chrdev(SPIDEV_MAJOR=212, ...)`,
#      the classic 1990s pattern instead of `alloc_chrdev_region`), creating a class `goodix_fp` and then
#      registering the SPI driver -- and it `return 0` **even when `spi_register_driver()` failed**, with the
#      real status only printed: `pr_info(" status = 0x%x\n", status); ... return 0; //status`. So a kernel
#      built with this driver can boot with the option ON, the initcall reported SUCCESS, and no driver
#      registered. An instrument that reads the config line alone would call that fixed.
#
# WHAT THIS PROBE DOES NOT DO, and why it is a refusal rather than a limitation: it opens NOTHING. It reads
# the device tree, the kernel's own embedded config, and sysfs DIRECTORY ENTRIES; it never reads
# `/dev/goodix_fp`, never opens `/dev/qbt1000`, and never touches `/dev/qseecom`. That last one matters for
# this block specifically: qbt1000's `open()` performs an SNS QMI open + keep-alive and then an
# `scm_call2(TZ_BLSP_MODIFY_OWNERSHIP)` that HANDS THE SPI BLSP BLOCK TO THE SECURE WORLD, giving it back on
# close -- and secure-world calls are the shape that has already cost this project a boot (docs 58). "Look
# at the fingerprint device" is a state change on this board, so it is not done here at all.
#
# Usage (on the device):
#   sh zl1-fp-kernel-probe.sh            # every block, then a verdict
#   sh zl1-fp-kernel-probe.sh --quiet    # the table and the verdict only
#   sh zl1-fp-kernel-probe.sh --explain  # what each reading decides, and why this reading
#
# Exit: 0 every fingerprint block this tree declares has its driver built into the RUNNING kernel AND bound;
#       1 at least one block does not -- the verdict names which and why;
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
V=""
VMSG=""
BLOCKS_TOTAL=0
BLOCKS_BUILT=0
BLOCKS_BOUND=0
FIRST_UNBUILT=""
FIRST_UNTABLE=""
BOARD=other
MODEL=""
DT_WORDS=""

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
# A device-tree u32 is BIG-ENDIAN and this SoC is little-endian, so `od -tu4` on the file prints the value
# BYTE-SWAPPED -- an SPI port id of 2 comes out as a number of the right shape and the wrong value. The four
# bytes are combined explicitly, and anything that is not exactly four bytes says so.
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
# succeeds on empty input, so the none-branch would never fire.
show() { # $1 = text, $2 = ERE, $3 = the "(none: ...)" text, $4 = tail -n, $5 = 1 to print under --quiet
  [ "$QUIET" = 1 ] && [ "${5:-0}" != 1 ] && return 0
  out=$(printf '%s\n' "$1" | LC_ALL=C grep -aiE -- "$2" 2>/dev/null | tail -n "${4:-15}")
  if [ -n "$out" ]; then printf '%s\n' "$out" | sed 's/^/   | /'; else printf '   | %s\n' "$3"; fi
}
# Every node whose `compatible` list contains an entry, found by SCANNING -- the path is not assumed, because
# a path that moves between device trees is how this project has lost a block before. The glob after the scan
# exists for a kernel where `find` is missing, and it RETURNS 2 rather than "not found" when even that cannot
# look: "there is no such node" and "I could not search" are different facts.
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
  # The known node shapes for a kernel without find(1). These nodes sit at four different depths -- one under
  # an SPI controller, one directly under /soc -- so the fallback walks the shapes rather than a list.
  # `-d` and not `-e`: `/proc/device-tree/*` also matches the root's own PROPERTIES (`model`, `compatible`),
  # which are files -- and counting those as "nodes exist here" is how this fallback would report "I searched
  # and found nothing" on a tree it never actually searched.
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
# shows that the word is not the block. It counts NODES, not matches. For this block the difference is not
# decorative: the word `fingerprint` finds the qbt1000 CHILD node in its path, and that child carries no
# `compatible` at all -- which is exactly why it is invisible to every DTB-derived reading in this project.
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
# Every node that has NO `compatible` but whose PATH carries a word. It exists because this block's own child
# node is one of these, and a reader who only looks at `compatible` properties never sees it: the qbt1000
# child is matched by NODE NAME (`of_node_cmp(child_node->name, ...)`), and the DTB-derived inventory of this
# project omits every node without a compatible -- so this block's other half is invisible there by
# construction, which is a fact about the reading, not about the hardware.
nodes_named_nocompat() { # $1 = a word; prints the DIRECTORIES whose path carries it and which have no
                           #      `compatible` property of their own
  # `-type d` and a test on the property FILE, not on a list of `compatible` paths: the whole point of this
  # helper is the nodes that have no `compatible`, and a scan that starts from a list of compatible
  # properties can never return one -- which is the mistake this helper exists to make visible.
  if type find >/dev/null 2>&1; then
    find /proc/device-tree -type d 2>/dev/null | while read -r _nq_p; do
      case "$_nq_p" in *"$1"*) ;; *) continue ;; esac
      [ -e "$_nq_p/compatible" ] && continue
      printf '%s\n' "$_nq_p"
    done
    return 0
  fi
  for _nq_p in /proc/device-tree/soc/* /proc/device-tree/soc/*/* /proc/device-tree/soc/*/*/*; do
    [ -d "$_nq_p" ] || continue
    case "$_nq_p" in *"$1"*) ;; *) continue ;; esac
    [ -e "$_nq_p/compatible" ] && continue
    printf '%s\n' "$_nq_p"
  done
  return 0
}
# The driver that MATCHES a compatible, straight out of the kernel source -- each row is
# "driver-name<TAB>config-option<TAB>source-file<TAB>bus<TAB>how-it-matches". A compatible with no match
# prints `none`, which is a reading (a node nothing can bind) and not an error.
#
# THE NAME THIS PRINTS IS THE ONE SYSFS KEYS ON, and for these two blocks that is the whole point:
#   * goodix: the SPI driver's `.driver.name` is `goodix_fp` -> /sys/bus/spi/drivers/goodix_fp -- while the
#     char device it creates is `goodix_fp`, the kernel thread that registered with a FIXED major is
#     `goodix_fp_spi`, the class is `goodix_fp`, and the INPUT device it registers is `gf318m`. FOUR names,
#     and not one of them is the compatible `goodix,fingerprint`.
#   * qbt1000: the platform driver's `.name` is `qbt1000` -> /sys/bus/platform/drivers/qbt1000, and its DEVICE
#     is `soc:qcom,qbt1000` (the node has no `reg`, and `of_device_make_bus_id()` climbs to the root, so the
#     name carries the parent path prefix -- the same convention that gives this board `soc:qcom,cnss` and
#     `soc:qcom,kgsl-hyp`). A probe looking for `/sys/bus/platform/devices/qcom,qbt1000` finds nothing on a
#     device where the device exists.
drivers_for() { # $1 = compatible
  case "$1" in
  goodix,fingerprint)
    printf 'goodix_fp\tCONFIG_INPUT_GP5XX8\tdrivers/input/goodixfp/gf_spi.c\tspi\tby of_match "goodix,fingerprint" (the ONLY entry: gx_match_table)\n'
    ;;
  qcom,qbt1000)
    printf 'qbt1000\tCONFIG_MSM_QBT1000\tdrivers/soc/qcom/qbt1000.c\tplatform\tby of_match "qcom,qbt1000" (the ONLY entry: qbt1000_match)\n'
    ;;
  qcom,spi-qup-v2)
    printf 'spi_qup\tCONFIG_SPI_QUP\tdrivers/spi/spi-qup.c\tplatform\tby of_match "qcom,spi-qup-v2" (the bus the goodix node sits ON)\n'
    ;;
  *) printf 'none\t-\t-\t-\t-\n' ;;
  esac
}
# The drivers that CLAIM this block's word and cannot bind it. For this block that is not a naming
# coincidence: a THIRD fingerprint driver is in this tree, with its own config option and no node on this
# board -- and `zl1-fingerprint-probe.sh` already looks for its sysfs path, so the name is in this project's
# vocabulary without anything having asked whether a driver is behind it.
near_miss_driver() {
  printf 'fpc1020\tdrivers/input/fpc1020/fpc1020_tee.c\tCONFIG_INPUT_FPC1020\tNO node on this board carries its compatible -- the driver is in the tree and the hardware it drives is not. It is named here because /sys/devices/soc/soc:fpc_fpc1020 is one of the paths zl1-fingerprint-probe.sh reads, and a path that is always absent is a reading of the absence.\n'
}
# The device node a driver would create, and the name it would have. Printed for every block, because "the
# node is absent" is what the reader is going to see and this is the reason it is absent.
dev_node_for() { # $1 = the config option of the driver; $2 = the node it would create
  case "$(cfg_opt "$1")" in
  "y (built in)") printf 'the driver is built, so the node exists iff its probe reached the statement that creates it' ;;
  "m (module -- it needs a .ko in the rootfs)") printf 'the driver is a MODULE: the node exists only if that .ko is present in this rootfs AND modprobe ran' ;;
  "NOT SET") printf 'the driver is NOT BUILT, so nothing in this kernel can create %s -- whatever the device tree says' "$2" ;;
  "absent from the config") printf 'the config does not mention %s at all, so nothing was built from it' "$1" ;;
  *) printf 'the config could not be read here, so whether the driver is built is NOT KNOWN from this boot' ;;
  esac
}
# Is a driver REGISTERED? /sys/bus/<bus>/drivers/<name> exists exactly when it registered, so this is the
# device's own answer and not an inference from a list.
drv_registered() { # $1 = bus, $2 = driver name; prints yes/no
  [ -d "/sys/bus/$1/drivers/$2" ] && printf 'yes' || printf 'no'
}
# Is anything BOUND to it? The symlinks beside bind/unbind/uevent are the devices that were PROBED. For a
# platform driver that is the device's PROBE HAVING RETURNED 0, not merely matched: the driver core adds the
# symlink before calling probe() and REMOVES it again in its failure path (`really_probe()`,
# drivers/base/dd.c), so a driver whose probe failed has no symlink here -- and the core prints
# "probe of soc:qcom,qbt1000 failed with error -22" itself, in the core's own words rather than the driver's.
drv_bound() { # $1 = bus, $2 = driver name; prints a space-separated list, or empty
  _db_out=""
  for _db_b in "/sys/bus/$1/drivers/$2"/*; do
    [ -e "$_db_b" ] || continue
    case "$(basename "$_db_b")" in bind | unbind | uevent | module) continue ;; esac
    _db_out="$_db_out $(basename "$_db_b")"
  done
  printf '%s' "$_db_out"
}
# Is a platform device REGISTERED? This is a different question from "is the driver bound", and on a device
# whose probe failed the two answers differ: the device stays in /sys/bus/platform/devices/ with no driver
# symlink in it.
plat_dev_exists() { # $1 = the device name as the driver core spells it
  [ -d "/sys/bus/platform/devices/$1" ] && printf 'yes' || printf 'no'
}

if [ "$MODE" = explain ]; then
  cat <<'EOF'
zl1 fingerprint-at-the-kernel-layer probe -- what each reading decides, and why it is this reading

  1. TWO BLOCKS, TWO SENSORS, ONE TREE. `/soc/spi@7579000/goodixfp@0` (`compatible = "goodix,fingerprint"`,
     `input-device-name = "gf318m"`) is a Goodix capacitive sensor on the SPI controller; `/soc/qcom,qbt1000`
     with child `qcom,fingerprint-sensor-ssc-spi-conn` is Qualcomm's ultrasonic QBT1000 on an SSC SPI port.
     Both are in all five stock device trees of this phone and in every LE_ZL1 variant. So "the fingerprint"
     is two nodes here, and a single answer about "the fingerprint driver" is an average of two opposite
     facts.

  2. THE HAL'S SENSOR HAS NO DRIVER IN THE RUNNING KERNEL. docs 98 read `goodix_sensor_init`, `gx_fpd` and
     `/dev/goodix_fp` out of the container's HAL. `/dev/goodix_fp` comes from `drivers/input/goodixfp/gf_spi.c`
     under `CONFIG_INPUT_GP5XX8`. The kernel this phone boots was built with
     `# CONFIG_INPUT_GP5XX8 is not set` -- read out of the kernel image's own embedded config
     (`/proc/config.gz`), which is the build that is RUNNING and not a defconfig file on a laptop. So nothing
     binds the node, no `/dev/goodix_fp` can be created, and that HAL's open() cannot succeed for a reason
     that is BELOW every layer docs 83/98/126 worked on.

  3. AND THE SENSOR WHOSE DRIVER IS BUILT IS THE OTHER ONE. `CONFIG_MSM_QBT1000=y` in the same embedded
     config. So "this kernel has a fingerprint driver" is TRUE and "this kernel has THE FINGERPRINT'S driver"
     is FALSE, and only the second sentence is about the phone.

  4. THE OBSTACLE IS ONE CONFIG LINE -- WHICH MAKES THE PROBE'S JOB THE ATTRIBUTION, NOT THE SEARCH. The
     node is enabled, the SPI controller it sits on is built (`CONFIG_SPI_QUP=y`) and registered, and every
     property the driver asks for is present (`goodix,gpio_reset` -> gpio31, `goodix,gpio_irq` -> gpio121,
     `spi-max-frequency`, and the pinctrl groups). Nothing is hidden. What a reader can get wrong is which
     block a statement is about.

  5. THE WORD IS NOT THE BLOCK. Four names for the Goodix block (`goodix_fp` driver, `goodix_fp` char device,
     `goodix_fp_spi` chrdev registration, `gf318m` input device), none of them the compatible; a third
     fingerprint driver in the same tree (`CONFIG_INPUT_FPC1020`, also not set) with no node on this board;
     and `qcom,fingerprint-sensor-ssc-spi-conn`, which LOOKS like a compatible and is a node NAME -- the
     qbt1000 driver compares `child_node->name` with `of_node_cmp()` and the child carries no `compatible`
     property at all, which is why this block is invisible to every DTB-derived reading in this project.

  6. TURNING THE OPTION ON IS NOT THE WHOLE FIX, AND THIS IS WORTH READING FIRST. `gf_init()` claims a FIXED
     major (`register_chrdev(SPIDEV_MAJOR = 212, "goodix_fp_spi", ...)`), creates a class, then registers the
     SPI driver -- and it RETURNS 0 EVEN IF `spi_register_driver()` FAILED, printing the real status only
     (`pr_info(" status = 0x%x\n", status); ... return 0; //status`). A boot with the option ON can therefore
     report the initcall as successful and have no driver registered. Reading the config line is necessary and
     not sufficient; the tree's own record of what the driver DOES is the other half.

  7. THIS PROBE OPENS NOTHING. Not `/dev/goodix_fp`, not `/dev/qbt1000`, not `/dev/qseecom`. qbt1000's
     `open()` runs an SNS QMI open + keep-alive and then `scm_call2(TZ_BLSP_MODIFY_OWNERSHIP)`, handing the
     SPI BLSP block to the secure world (and `release()` hands it back) -- a state change, not an observation,
     and secure-world calls are the shape that has already cost this project a boot (docs 58).
EOF
  exit 0
fi

# The device-tree guard comes after the explain page on purpose: `--explain` reads nothing, and refusing it on
# a machine with no device tree would make the page that says what the probe reads unreachable exactly where a
# reader would want it.
[ -d /proc/device-tree ] ||
  { echo "no /proc/device-tree here -- refusing (this probe reads the device tree)" >&2; exit 2; }

# --- 0. this boot -----------------------------------------------------------------------------------
hdr "this boot"
always "   boot id:    $(rd /proc/sys/kernel/random/boot_id)"
always "   uptime:     $(cut -d' ' -f1 /proc/uptime 2>/dev/null)s"
say "   kernel:     $(rd /proc/version)"

# --- 1. which board's device tree is this -----------------------------------------------------------
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
  always "               carries both boards' trees, and BOTH fingerprint blocks sit in both of them -- so the"
  always "               tree's shape cannot tell you whose reading this is, and only 'model' can."
  ;;
unknown)
  always "   board:      UNKNOWN -- /proc/device-tree/model could not be read, so which board's tree this is"
  always "               cannot be told from here. The readings below are still taken, and this is named in"
  always "               the verdict rather than being silently assumed to be a zl1."
  ;;
*) always "   board:      neither LE_ZL1 nor LE_X2 -- nothing below can be attributed to this phone" ;;
esac

# --- 2. the kernel's own config, read BEFORE the sections that ask about it --------------------------
#
# This has to come first: every block's row asks whether the option that builds its driver is set -- and a
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
hdr "the config the RUNNING kernel was built with"
if [ -n "$CFG_SRC" ]; then
  always "   source:     $CFG_SRC   (the kernel's own embedded config: this is the build that is running,"
  always "               not a defconfig file somewhere else)"
else
  always "   source:     NOT READ -- /proc/config.gz is not readable here, and neither zcat nor gunzip could"
  always "               open it. NOTE WHAT THAT COSTS: every 'is the driver built' answer below becomes NOT"
  always "               READ rather than NOT SET, and those are different facts -- a driver that is not built"
  always "               and a driver whose build state could not be read look the same from sysfs alone."
fi
for _c in CONFIG_INPUT_GP5XX8 CONFIG_MSM_QBT1000 CONFIG_INPUT_FPC1020 CONFIG_SPI_QUP CONFIG_SPI_SPIDEV CONFIG_MSM_QMI_INTERFACE CONFIG_QSEECOM; do
  always "     $(printf '%-24s' "$_c") $(cfg_opt "$_c")"
done
say ""
say "   HOW TO READ THOSE: the three INPUT_* lines are the three fingerprint drivers that exist in this"
say "   kernel's source, and two of them are off. CONFIG_SPI_QUP is the controller the goodix node sits on,"
say "   CONFIG_SPI_SPIDEV is the GENERIC userspace SPI driver -- it is built, and it does NOT help, because"
say "   it only binds nodes whose compatible is 'spidev'; this board's node says 'goodix,fingerprint', so no"
say "   /dev/spidevX.Y appears for that chip either. CONFIG_MSM_QMI_INTERFACE and CONFIG_QSEECOM are the two"
say "   things qbt1000's probe needs (the notifier it registers, and the TZ app it loads on ioctl)."

# --- 3. every fingerprint block this tree declares --------------------------------------------------
hdr "every fingerprint block this device tree declares"
# The scan is by COMPATIBLE, and that is a choice worth naming: the word 'fingerprint' also appears in the
# PATH of qbt1000's child, which carries no compatible at all -- so a scan by word would count a node that
# this project's DTB-derived inventory cannot even see, and a scan by compatible cannot. Both are printed.
BLOCKS=""
SCAN_RC=0
for _compat in goodix,fingerprint qcom,qbt1000; do
  _out=$(nodes_with "$_compat"); _rc=$?
  [ "$_rc" = 2 ] && SCAN_RC=2
  [ -n "$_out" ] && BLOCKS="$BLOCKS$_out
"
done
BLOCKS=$(printf '%s' "$BLOCKS" | grep . | sort -u)
N_BLOCKS=0
[ -n "$BLOCKS" ] && N_BLOCKS=$(printf '%s\n' "$BLOCKS" | grep . | wc -l | tr -d ' ')
BLOCKS_TOTAL=$N_BLOCKS
if [ "$SCAN_RC" = 2 ]; then
  always "   THE TREE COULD NOT BE SEARCHED (no find(1) and no known node shape answered), so the number of"
  always "   blocks below is not a reading. Everything that follows is about the paths named, not about the"
  always "   board."
fi
if [ "$N_BLOCKS" = 0 ]; then
  always "   (none: no node in this tree carries 'goodix,fingerprint' or 'qcom,qbt1000')"
  always "   ON THIS BOARD THAT WOULD BE A READING ABOUT THE TREE, NOT THE PHONE: both compatibles are in all"
  always "   five of this phone's stock device trees, so a tree with neither is some other tree."
else
  _i=0
  printf '%s\n' "$BLOCKS" | while IFS= read -r _b; do
    [ -n "$_b" ] || continue
    _i=$((_i + 1))
    _bc=$(dtlist "$_b/compatible")
    always "   $_b"
    always "     compatible:  $_bc"
    always "     status:      $(dtstr "$_b/status")   (a node with no 'status' property is ENABLED -- the"
    always "                  device tree reads an absent status as okay, which is the ordinary case; it is the"
    always "                  fm-radio block on this board that the tree switches OFF itself)"
  done
fi

# The word scan, which is a different set from the block scan and is why it is printed here.
W_FP=$(nodes_named fingerprint | grep . | sort -u)
W_FPC=$(nodes_named fpc | grep . | sort -u)
W_NC=$(nodes_named_nocompat fingerprint | grep . | sort -u)
say ""
say "   the same tree, read by the WORD instead of by the compatible -- this is what a grep finds:"
say "     nodes whose path or compatible carries 'fingerprint': $(printf '%s\n' "$W_FP" | grep -c . | tr -d ' ')"
say "     nodes whose path or compatible carries 'fpc':         $(printf '%s\n' "$W_FPC" | grep -c . | tr -d ' ')"
say "     nodes whose PATH carries 'fingerprint' and which have NO compatible property at all:"
say "       $( [ -n "$W_NC" ] && printf '%s' "$(printf '%s' "$W_NC" | tr '\n' ' ')" || printf '(none)' )"
say "     ^ THAT LAST LINE IS THE ONE THIS PROJECT'S INVENTORY CANNOT SEE. A DTB-derived reading omits every"
say "       node without a 'compatible', and qbt1000's child is one of those -- its name LOOKS like a"
say "       compatible and is not: the driver matches it with of_node_cmp() against node->name."

# --- 4. each block, at the kernel layer -------------------------------------------------------------
hdr "each block, at the kernel layer"
if [ "$N_BLOCKS" != 0 ]; then
  _i=0
  for _b in $(printf '%s\n' "$BLOCKS"); do
    _i=$((_i + 1))
    _bc=$(dtstr "$_b/compatible")
    _row=$(drivers_for "$_bc")
    _dn=$(printf '%s' "$_row" | cut -f1)
    _dc=$(printf '%s' "$_row" | cut -f2)
    _df=$(printf '%s' "$_row" | cut -f3)
    _db=$(printf '%s' "$_row" | cut -f4)
    _dh=$(printf '%s' "$_row" | cut -f5)
    always ""
    always " [$_i] $_b"
    say "     $_bc"
    if [ "$_dn" = none ]; then
      always "     driver:      NONE in this kernel source matches '$_bc' -- nothing can ever bind it, under any"
      always "                  config, and no config line can fix it"
      [ -z "$FIRST_UNTABLE" ] && FIRST_UNTABLE="$_b ($_bc)"
      continue
    fi
    _opt=$(cfg_opt "$_dc")
    _reg=$(drv_registered "$_db" "$_dn")
    _bnd=$(drv_bound "$_db" "$_dn")
    _bnd=$(printf '%s' "${_bnd# }")
    always "     driver:      $_dn   ($_df, $_db)"
    always "     matches:     $_dh"
    always "     config $_dc: $_opt"
    always "     registered:  $_reg      bound: $( [ -n "$_bnd" ] && printf '%s' "$_bnd" || printf 'NONE' )"
    case "$_opt" in
    "y (built in)") BLOCKS_BUILT=$((BLOCKS_BUILT + 1)) ;;
    *) [ -z "$FIRST_UNBUILT" ] && FIRST_UNBUILT="$_b (compatible $_bc -- $_dc is $_opt)" ;;
    esac
    [ -n "$_bnd" ] && BLOCKS_BOUND=$((BLOCKS_BOUND + 1))
    # The device NAME, which is not the compatible for either block.
    case "$_bc" in
    qcom,qbt1000)
      always "     device name: soc:$_bc   -- NOT '$_bc'. The node carries no 'reg', so the driver core's"
      always "                  of_device_make_bus_id() climbs to the root and prefixes the parent path; this is"
      always "                  the same convention that gives this board 'soc:qcom,cnss' and"
      always "                  'soc:qcom,kgsl-hyp'. A probe looking for /sys/bus/platform/devices/$_bc finds"
      always "                  nothing on a device where the platform device exists: $(plat_dev_exists "soc:$_bc")"
      always "     it creates:  /dev/qbt1000  and the input device 'qbt1000_key_input' -- but ONLY if probe()"
      always "                  returns 0, and its LAST fallible step is input_register_device()"
      ;;
    goodix,fingerprint)
      always "     four names:  the driver directory is /sys/bus/spi/drivers/goodix_fp (the spi_driver's"
      always "                  .name), the char device it creates is /dev/goodix_fp, it claims a FIXED major"
      always "                  (SPIDEV_MAJOR = 212) as 'goodix_fp_spi', and the input device it registers is"
      always "                  '$(dtstr "$_b/input-device-name")'. NOT ONE of them is the compatible."
      always "     it creates:  /dev/goodix_fp, and that input device -- but only if the driver is in the"
      always "                  kernel at all, and it is not: see the config line above"
      # The BUS this node sits on is a separate driver with its own option, and a node on an unbuilt
      # controller is a different problem from a node whose own driver is unbuilt. Read it, don't assume it.
      _pnode=$(printf '%s' "$_b" | sed 's#/[^/]*$##')
      _pc=$(dtstr "$_pnode/compatible")
      _prow=$(drivers_for "$_pc")
      always "     its bus:     $_pnode  (compatible '$_pc')"
      always "                  driver $(printf '%s' "$_prow" | cut -f1), option $(printf '%s' "$_prow" | cut -f2): $(cfg_opt "$(printf '%s' "$_prow" | cut -f2)")  registered: $(drv_registered "$(printf '%s' "$_prow" | cut -f4)" "$(printf '%s' "$_prow" | cut -f1)")"
      ;;
    esac
    case "$_bc" in
    qcom,qbt1000) always "     the node it would create: $(dev_node_for "$_dc" "/dev/qbt1000")" ;;
    *) always "     the node it would create: $(dev_node_for "$_dc" "/dev/goodix_fp")" ;;
    esac
  done
fi

# --- 5. what stands between the tree and a driver, per block ----------------------------------------
hdr "what stands between the tree and a driver"
say "   TWO BLOCKS, TWO ANSWERS, AND A SINGLE SENTENCE ABOUT 'THE FINGERPRINT DRIVER' WOULD AVERAGE THEM."
say ""
say "   goodix,fingerprint -- THE BLOCK THE CONTAINER'S HAL OPENS. docs 98 read 'goodix_sensor_init',"
say "   'gx_fpd' and /dev/goodix_fp out of fingerprint.msm8996.so, and /dev/goodix_fp is created by"
say "   drivers/input/goodixfp/gf_spi.c under CONFIG_INPUT_GP5XX8. Read above: that option is"
say "   '$(cfg_opt CONFIG_INPUT_GP5XX8)' in the config the RUNNING kernel was built with. Nothing in the"
say "   kernel can bind this node, so /dev/goodix_fp cannot exist this boot -- and no work on the store"
say "   directory (docs 83/126), on the HAL's layers (docs 98) or on the trust store above it can change"
say "   that, because all of those are ABOVE this line."
say ""
say "   qcom,qbt1000 -- THE OTHER SENSOR, WHOSE DRIVER IS BUILT. Its Kconfig calls it 'QBT1000 Ultrasonic"
say "   Fingerprint Sensor' and the same embedded config says CONFIG_MSM_QBT1000 is"
say "   '$(cfg_opt CONFIG_MSM_QBT1000)'. So this kernel DOES have a fingerprint driver -- for the sensor the"
say "   container's HAL does not open. 'There is a fingerprint driver in the kernel' and 'the fingerprint"
say "   sensor has a driver in the kernel' are two sentences with two different answers on this phone."
say ""
say "   AND THE THIRD DRIVER IN THE TREE, with no node on this board:"
say "     $(near_miss_driver | cut -f1)  $(near_miss_driver | cut -f3)  ($(near_miss_driver | cut -f2))"
say "     $(near_miss_driver | cut -f4)"
say ""
say "   THE OBSTACLE FOR THE GOODIX BLOCK IS ONE CONFIG LINE, AND TURNING IT ON IS NOT THE WHOLE FIX:"
say "     * the node asks for nothing this tree lacks -- goodix,gpio_reset/goodix,gpio_irq are both here,"
say "       the SPI controller it sits on is built (CONFIG_SPI_QUP is '$(cfg_opt CONFIG_SPI_QUP)') and"
say "       registered, and the node carries no 'status';"
say "     * BUT 'gf_init()' claims a FIXED major (register_chrdev(SPIDEV_MAJOR = 212, \"goodix_fp_spi\", ...))"
say "       -- not the alloc_chrdev_region() pattern -- and then RETURNS 0 EVEN IF spi_register_driver()"
say "       FAILED: the real status is only PRINTED ('pr_info(\" status = 0x%x\\n\", status)') before"
say "       'return 0; //status'. A kernel built with the option on can boot, report that initcall as"
say "       successful, and have no driver registered. Reading the option is necessary and not sufficient."

# --- 6. the kernel log, for these blocks ------------------------------------------------------------
hdr "the kernel log, for these blocks"
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
  always "   this section is NOT READ. No verdict below rests on it, but NOTE WHAT IS LOST: the driver core's"
  always "   own 'probe of <device> failed with error N' line is the only place a FAILED probe is named, and"
  always "   the goodix driver's ' status = 0x...' line is the only place its own init says what it did."
else
  always "   source: $LOG_SRC"
  always "   THE DRIVER CORE NAMES A FAILED PROBE -- in the core's words, with the DEVICE name and the errno,"
  always "   and NOT in the driver's. That line is why a failed bind is findable at all here:"
  show "$LOG_TEXT" 'probe of soc:qcom,qbt1000|probe of [^ ]*qbt1000|qbt1000' \
    "(none: the kernel log names qbt1000 nowhere in this boot -- and that is NOT a fault: this driver prints nothing at all when its probe SUCCEEDS, so silence here is not evidence either way)" \
    15 1
  say "    ^ NOTE WHAT THAT SILENCE IS: qbt1000_probe has NO dev_info anywhere, so a probe that SUCCEEDS"
  say "      prints nothing at all. Silence is not evidence either way here -- and the goodix driver is the"
  say "      exception, because its own init() prints unconditionally."
  always ""
  show "$LOG_TEXT" 'goodix|gf:irq_gpio|SPIDEV|fpc1020|blsp ownership|Could not connect to SNS' \
    "(none: no goodix, fpc1020 or qbt1000 runtime line in this boot's log)" 15 1
  always ""
  always "   HOW TO READ THOSE: 'probe of soc:qcom,qbt1000 failed with error -22' means the driver MATCHED and"
  always "   its probe ran and failed (-22 is the child-parse -EINVAL, the only -EINVAL in that function);"
  always "   'probing driver ... with device ...' at debug level is not printed on this kernel; and any"
  always "   'goodix' line at all would CONTRADICT the config read above -- a driver that is not built cannot"
  always "   print, so a goodix line in this log means the running kernel is not the one whose config was read."
fi

# --- 7. what this probe refuses to touch ------------------------------------------------------------
hdr "what this probe refuses to touch, and why it is a refusal"
always "   NOT ONE DEVICE NODE WAS OPENED. This probe read the device tree, /proc/config.gz, and sysfs"
always "   DIRECTORY ENTRIES. On this block that matters more than in the siblings, because both of these"
always "   sensors' device nodes are state changes rather than observations:"
always "     * qbt1000: open() runs qbt1000_sns_open_req() -> qbt1000_sns_keep_alive_req(1) ->"
always "       qbt1000_set_blsp_ownership(tz_subsys_id), and THAT LAST ONE IS AN scm_call2 INTO THE SECURE"
always "       WORLD that transfers the SPI BLSP block's ownership to TZ; release() transfers it back. A"
always "       'read' of /dev/qbt1000 is therefore a handover of a hardware block, and secure-world calls are"
always "       the shape that has already cost this project a boot (docs 58). ioctl LOAD additionally runs"
always "       qseecom_start_app(\"fingerpr\") -- a TZ application load."
always "     * goodix: /dev/goodix_fp is the HAL's own door; opening it wakes the sensor and starts its"
always "       interrupt path. It does not exist this boot (see above), and a probe that created it by"
always "       opening it would be reporting its own action."
always ""
always "   WHAT THAT COSTS: this probe cannot say whether either sensor's HARDWARE answers -- only whether"
always "   the kernel has a driver for it and whether that driver bound. That separation is the point: the"
always "   answer above is about the layer BELOW the HAL, and it is falsifiable without touching the phone."

# --- verdict ---------------------------------------------------------------------------------------
if [ "$SCAN_RC" = 2 ]; then
  V=tree-unscanned
  VMSG="the device tree could not be searched (no find(1), and neither known node shape answered), so the number of fingerprint blocks below is not a reading. Nothing here is a verdict about this board's fingerprint."
elif [ "$BOARD" = x2 ]; then
  V=wrong-board-tree
  VMSG="this boot is running the LE_X2's device tree, not this phone's. Both fingerprint blocks are declared in BOTH boards' trees, so the tree's shape cannot tell them apart and only 'model' can -- nothing below is about the zl1, and the next move is about which DTB the bootloader picked."
elif [ "$BOARD" = other ] || [ "$BOARD" = unknown ]; then
  V=unknown-board
  VMSG="the device tree's model names neither LE_ZL1 nor LE_X2 (read: $MODEL), so this reading cannot be attributed to this phone. The readings below stand on their own; the attribution does not."
elif [ "$N_BLOCKS" = 0 ]; then
  V=no-fingerprint-block
  VMSG="this device tree declares no node with 'goodix,fingerprint' or 'qcom,qbt1000'. On this board that means the tree being read is not the tree this phone boots with: both compatibles are in all five of its stock device trees, in every variant."
elif [ -n "$FIRST_UNTABLE" ]; then
  V=no-driver-in-source
  VMSG="at least one block has NO driver in this kernel source that matches its compatible ($FIRST_UNTABLE), so nothing can bind it under any config. That is a fact about the SOURCE, not about a build option."
elif [ -n "$FIRST_UNBUILT" ]; then
  V=driver-not-built
  VMSG="every block has a driver in this kernel's source, and at least one of those drivers IS NOT IN THE RUNNING KERNEL: $FIRST_UNBUILT. Read the config section for the exact lines. THIS IS THE RUNG THE GOODIX SENSOR -- the one the container's HAL opens -- REACHES. Note what it is NOT: not 'the hardware is bad', not 'the tree is wrong', not 'the HAL is broken'. The driver is not in the kernel, so nothing binds the node, so the device node does not exist, and every layer above it (docs 83/98/126) has been working against a door with no room behind it."
elif [ "$BLOCKS_BOUND" != "$BLOCKS_TOTAL" ]; then
  V=driver-not-bound
  VMSG="every block's driver IS built into this kernel, and not every block is bound ($BLOCKS_BOUND of $BLOCKS_TOTAL). The drivers are registered; something is stopping the match or the probe. The kernel log section above names it: the driver core prints 'probe of <device> failed with error N' in its own words when a probe runs and fails, and a node that never matched prints nothing at all."
else
  V=every-block-has-a-bound-driver
  VMSG="every fingerprint block this device tree declares has a driver that is built into the RUNNING kernel and bound to its node ($BLOCKS_BOUND of $BLOCKS_TOTAL). AND NOTE WHAT THIS IS AND IS NOT: it is the KERNEL LAYER being in place -- the software path from the device tree to a bound driver. It is NOT 'the fingerprint works': the HAL, the trust store, the TZ application and the sensor's own answers are all above or below this line, and this probe opened no device node to ask any of them."
fi

always ""
always "== verdict: $V"
always "   $VMSG"
always ""
always "   THE TWO SENTENCES THIS VERDICT KEEPS APART, because a single one would be wrong in both directions:"
always "     'there is a fingerprint driver in this kernel'                  -> $( [ "$BLOCKS_BUILT" != 0 ] && printf 'TRUE (%s of %s blocks)' "$BLOCKS_BUILT" "$BLOCKS_TOTAL" || printf 'no block' )"
always "     'the fingerprint sensor the HAL opens has a driver here'        -> see the per-block rows above"
always ""
always "   WHAT THIS IS NOT: a statement about the sensor, the HAL, the trust store or the TZ application. It"
always "   is a statement about the kernel layer, taken without opening a single device node: no /dev/goodix_fp,"
always "   no /dev/qbt1000, no /dev/qseecom."

[ "$V" = every-block-has-a-bound-driver ] && exit 0
exit 1
