#!/bin/sh
# zl1 video-core probe -- the Venus video block: the vidc/v4l2 half AND the PIL firmware half that has to
# come up before any of it can work.
#
# Why this exists. doc 137 enumerated this board's hardware from its own device trees and found 12 blocks
# nothing in this tree reads. One of them is `video-codec` -- twelve device-tree nodes, the second-largest
# gap on that list -- and the block behind them is the thing that decodes and encodes video. On this port
# nothing had ever read it, so nothing here could say whether it was up.
#
# WHAT THE BLOCK ACTUALLY IS: TWO LAYERS, AND THEY FAIL DIFFERENTLY.
#
#   1. THE FIRMWARE. /soc/qcom,venus@ce0000 is `qcom,pil-tz-generic`: the Venus firmware is NOT linked into
#      the kernel, it is loaded from a file at runtime by the peripheral loader, in segments
#      (`venus.mdt` + `venus.b00`..`venus.bNN` -- peripheral-loader.c:794 and :675), and each segment is
#      AUTHENTICATED BY THE SECURE WORLD: pil_init_image_trusted / pil_auth_and_reset in subsys-pil-tz.c
#      go through scm_call(SCM_SVC_PIL, PAS_INIT_IMAGE_CMD / PAS_MEM_SETUP_CMD / PAS_AUTH_AND_RESET_CMD).
#      That is the same secure-world path docs 86/122 caught returning -12 on some cold boots and leaving
#      every PIL firmware unloaded. So this layer can fail in three quite different ways: the file is not
#      where the kernel looks for it, the file is there and the secure world refuses, or nothing asked yet.
#   2. THE DRIVER. /soc/qcom,vidc@c00000 is `qcom,msm-vidc`, driven by `msm_vidc_v4l2` (CONFIG_MSM_VIDC_V4L2=y,
#      msm_v4l2_vidc.c), which registers a V4L2 decoder and encoder (BASE_DEVICE_NUMBER 32, so /dev/video32
#      and /dev/video33) and talks HFI to the firmware once it is up. This layer can be fine while the
#      firmware is not, and vice versa -- hence the ladder below rather than one switch.
#
# AND IT IS A CLIENT-REQUEST DOOR, NOT A BOOT-TIME ONE (the GPS lesson, docs 82/115).
# venus_hfi.c's __load_fw() calls subsystem_get_with_fwname("venus", ...) when the core is initialised --
# i.e. when something OPENS a video instance. Nothing loads this firmware at boot. So on an idle boot the
# subsystem reads OFFLINE and that is NOT a fault: it is "no client has asked yet". A probe that reads
# a missing firmware as a defect would be wrong on the majority of boots. This one therefore separates
# "not loaded" from "load FAILED" -- the second needs evidence of an attempt (crash_count, the subsystem's
# own error buffer, or the kernel log), and it says which of the two it is looking at.
#
# THE FOUR SIBLINGS ARE THE CONTROL GROUP. Four nodes on this board are `qcom,pil-tz-generic` and are all
# served by the same driver with the same firmware search path:
#     /soc/qcom,kgsl-hyp      a530_zap   the GPU's zap shader
#     /soc/qcom,lpass@9300000 adsp       the audio DSP
#     /soc/qcom,ssc@1c00000   slpi       the sensor DSP
#     /soc/qcom,venus@ce0000  venus      the video core
# plus /soc/qcom,mss@2080000, the modem (`qcom,pil-q6v55-mss`, a different driver). They rise at
# different times, so "adsp is ONLINE and venus is OFFLINE" and "all four are OFFLINE" are different
# readings -- the first is normal, the second is a boot-wide firmware problem. The probe prints all of
# them, because a fact about venus alone cannot be told from a fact about the boot without them.
#
# THE FIRMWARE PATH IS A NAMESPACE QUESTION, WHICH IS WHY IT IS READ TWICE.
# The flashed boot image's cmdline carries `firmware_class.path=/vendor/firmware_mnt/image`, and
# firmware_class.c tries that first, then the built-in list (`/lib/firmware/updates`, `/lib/firmware`,
# `/lib64/firmware`, `/lib/firmware/image`), each with filp_open -- in the CALLER's mount namespace. The
# caller is whichever process first opens a video instance, so the answer differs for a UT-side client
# and a container-side one: on this port `/vendor` is a symlink into the container's tree. The probe
# therefore resolves the same candidate paths in its OWN namespace and, when the container is up, in the
# container's -- and prints both, because "unreachable here" and "unreachable there" are different
# findings with different next moves. (This is also why the firmware being in the modem partition is
# stated as an offline finding and not as a device reading: see docs 141.)
#
# **Read-only, and it writes nothing at all** -- not even a scratch file, which is why the kernel log is
# captured into a shell variable. Every knob around this block is writable: the vidc platform device carries
# `pwr_collapse_delay` and `thermal_level` at 0644, the subsystem carries `restart_level`, `firmware_name`,
# `system_debug` and `keep_alive` at 0644 (subsystem_restart.c's subsys_attrs[]), and the two video nodes
# accept ioctls that start a session -- which is what loads the firmware. Driving any of them is a separate,
# reviewed step; it is not a side effect of taking a reading.
#
# Usage (on the device):
#   sh zl1-video-probe.sh             # every rung, then a verdict
#   sh zl1-video-probe.sh --quiet     # the verdict and the readings it rests on
#   sh zl1-video-probe.sh --explain   # what each reading decides, and why this reading
#
# Exit: 0 the firmware is up and the V4L2 devices are registered;
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
# A device-tree string property is BYTES, NUL-terminated. Every value this probe prints goes through
# `san`, and that is not cosmetic: a device tree carries raw binary, and this project has already been
# bitten by a dump that contained a NUL byte -- `grep` reads such a file as BINARY and prints
# "Binary file ... matches" (or, with -c, nothing at all), so a downstream reader silently sees an empty
# answer. Everything printed here is therefore printable-only, and the harness asserts it.
san() { # $1 = text
  printf '%s' "$1" | LC_ALL=C tr -c '[:print:]\n\t' '.' | cut -c1-200
}
# NOTE THE `tr -d '\n'` BEFORE THE SANITIZER. `tr -c '[:print:]' '.'` replaces every byte that is NOT
# printable -- and a newline is not printable, so the line `sed -n 1p` just emitted would come back with a
# trailing dot: `status` reads as `okay.` and every lookup keyed on that string (the subsystem's directory
# name, the board's `case`) silently misses. The dot is one character wide and looks like punctuation.
dtstr() { # $1 = path
  if [ ! -r "$1" ]; then printf 'absent'; return; fi
  v=$(tr '\0' '\n' < "$1" 2>/dev/null | sed -n 1p | tr -d '\n' | LC_ALL=C tr -c '[:print:]' '.')
  printf '%s' "${v:-EMPTY}"
}
# Every string of a property, not just the first: a `compatible` is a LIST, and reading only its first
# entry is how a node looks like it does not carry the compatible you are looking for.
dtlist() { # $1 = path
  if [ ! -r "$1" ]; then printf 'absent'; return; fi
  v=$(tr '\0' '\n' < "$1" 2>/dev/null | grep . | LC_ALL=C tr -c '[:print:]\n' '.' | tr '\n' ' ')
  printf '%s' "${v:-EMPTY}"
}
# A device-tree u32 is BIG-ENDIAN and this SoC is little-endian, so `od -tu4` on the file prints the value
# BYTE-SWAPPED -- 0x00000009 (venus pas-id 9) comes out as a number that looks like a reading and is not
# one. The four bytes are combined explicitly, and anything that is not exactly four bytes says so.
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
nodes_with() { # $1 = compatible; prints paths one per line; 0 found, 1 none, 2 could not search
  # Reset BOTH flags first. They are globals (no locals in this shell), so a call that found something
  # leaves `_nc_found=1` behind and the NEXT call -- in the branch that does not reset it -- would report
  # "found" with no output. That is exactly the shape of the defect docs 72 records.
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
  # The known node shapes, for a kernel where find(1) is missing. All six of this block's nodes are DIRECT
  # children of /soc (read from the device trees: /soc/qcom,vidc@c00000, /soc/qcom,venus@ce0000,
  # /soc/qcom,kgsl-hyp, /soc/qcom,lpass@9300000, /soc/qcom,ssc@1c00000, /soc/qcom,mss@2080000), and the
  # deeper variants are here because a path that moved to another level is exactly what this scan exists to
  # survive.
  for _nc_p in /proc/device-tree/soc/qcom,venus@* /proc/device-tree/soc/*/qcom,venus@* \
    /proc/device-tree/soc/qcom,vidc@* /proc/device-tree/soc/*/qcom,vidc@* \
    /proc/device-tree/soc/qcom,lpass@* /proc/device-tree/soc/*/qcom,lpass@* \
    /proc/device-tree/soc/qcom,ssc@* /proc/device-tree/soc/*/qcom,ssc@* \
    /proc/device-tree/soc/qcom,kgsl-hyp /proc/device-tree/soc/*/qcom,kgsl-hyp \
    /proc/device-tree/soc/qcom,mss@* /proc/device-tree/soc/*/qcom,mss@*; do
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
# The subsystem's own state, from the bus the PIL framework registers it on. OFFLINE / ONLINE / OFFLINING
# come from subsystem_restart.c's subsys_states[]; the attribute set is subsys_attrs[] in that file.
subsys_dir() { printf '%s' "/sys/bus/msm_subsys/devices/$1"; }

if [ "$MODE" = explain ]; then
  cat <<'EOF'
zl1 video-core probe -- what each reading decides, and why it is this reading

  1. WHICH BOARD'S DEVICE TREE IS RUNNING (model, not compatible).
     The flashed boot image's appended blob carries 28 device trees: 5 for the LE_ZL1 and 23 for the LE_X2,
     a different phone, under a byte-identical root `compatible`. `model` is the only property that tells
     them apart, so it is read first: on the X2's tree every reading below is about another phone.

  2. THE DEVICE TREE'S DECLARATION -- two nodes, and they are two layers.
     /soc/qcom,vidc@c00000 (`qcom,msm-vidc`) is the driver half: the V4L2 decoder/encoder and the HFI
     link. /soc/qcom,venus@ce0000 (`qcom,pil-tz-generic`, `qcom,firmware-name = venus`) is the firmware
     half. Both are printed with the properties their drivers actually parse -- status, hfi-version,
     never-unload-fw, sw-power-collapse, imem-size, max-secure-instances, pas-id, proxy-timeout-ms -- which
     are taken from msm_vidc_res_parse.c and subsys-pil-tz.c, not invented. The PIL node has NO `status`
     property, and that is a reading in itself: in the device tree, an absent status means enabled.

  3. THE PIL DRIVER AND WHAT IS BOUND TO IT.
     /sys/bus/platform/drivers/subsys-pil-tz/ appears when the driver registers, and the symlinks inside it
     are the devices that were PROBED. Four nodes on this board are this driver's (kgsl-hyp, lpass, ssc,
     venus), so "the driver is there" says nothing about venus: the bound list has to contain `venus`.

  4. THE SUBSYSTEM ENTRY, which is the firmware's own state.
     The PIL framework registers each subsystem on its own bus, named from the device tree's
     `qcom,firmware-name`, so venus is at /sys/bus/msm_subsys/devices/venus/ with `state`, `crash_count`,
     `error`, `restart_level` and `firmware_name`. ONLINE means the firmware was authenticated AND reset
     into life -- this is the only reading on the device that says the secure-world half succeeded. The
     probe prints the state of EVERY subsystem on the bus, not just venus, because they share the search
     path and the SCM service: "venus alone is OFFLINE" and "everything is OFFLINE" are different problems.
     And it is why the rung a naive reading gets wrong is a rung at all: OFFLINE with no error and no crash
     is what an IDLE, HEALTHY boot looks like, because nothing loads this firmware until a client opens a
     video instance. That state is named, not counted as a fault.

  5. WHERE THE FIRMWARE IS, from both namespaces.
     firmware_class.c tries `firmware_class.path` (the flashed cmdline sets it to
     /vendor/firmware_mnt/image) and then the built-in list, with filp_open in the CALLER's namespace. The
     caller is the process that opens a video instance, so a UT-side client and a container-side one can
     get different answers. Every candidate path is resolved in this probe's namespace and, when the
     container is up, in the container's, for `<name>.mdt` and its `.b00`.. siblings -- because the loader
     needs the segments too (peripheral-loader.c).

  6. THE DRIVER HALF: what a video client would actually open.
     `msm_vidc_v4l2` registers a decoder and an encoder at BASE_DEVICE_NUMBER 32, so /dev/video32 and
     /dev/video33, and its platform device carries four attributes (pwr_collapse_delay, thermal_level,
     platform_version, capability_version -- the last two read from the SoC's efuse registers at probe).
     The probe prints them and does NOT read /sys/kernel/debug/msm_vidc/*/info: that file issues an HFI
     query to the firmware, and this probe does not talk to the block it is measuring.

  WHAT THIS CANNOT SAY. Whether video DECODES. That needs a session: open /dev/video32, negotiate formats,
  feed it a stream. Opening a session is also what LOADS the firmware (venus_hfi.c __load_fw ->
  subsystem_get_with_fwname), so the firmware being OFFLINE with no error is exactly what an idle,
  healthy boot looks like -- and this probe says so instead of calling it a fault. Making it come up is a
  write, and it is a separate, reviewed step.
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

# --- 2. the device tree's declaration --------------------------------------------------------------
hdr "the device tree's declaration -- the driver node and the firmware node"
# The search's OWN exit status is what decides the rung, so it is captured before anything is piped:
# `x=$(nodes_with ... | sed -n 1p)` would report sed's status, and a "could not search" would read as
# "searched and found nothing" -- the exact conflation this probe exists to avoid.
NC_OUT=$(nodes_with qcom,msm-vidc); NC_RC=$?
VIDC=$(printf '%s\n' "$NC_OUT" | sed -n 1p)
VIDC_ST=""
if [ "$NC_RC" = 2 ]; then
  DT_RUNG=unscanned
  always "   the device tree could not be searched for a compatible at all: find(1) is missing AND none of"
  always "   the known node shapes exists. This is NOT 'the tree has no such node' -- it is 'this probe could"
  always "   not look', and the two must not print the same way."
elif [ -z "$VIDC" ]; then
  DT_RUNG=no-node
  always "   no node in this device tree carries compatible qcom,msm-vidc"
  always "   -- the running tree declares no video core at all. The path is not assumed: the whole tree is"
  always "      scanned for the compatible."
else
  DT_RUNG=node
  always "   vidc node:   ${VIDC#/proc/device-tree}"
  say "   compatible:  $(dtlist "$VIDC/compatible")"
  VIDC_ST=$(dtstr "$VIDC/status")
  always "   status:      $VIDC_ST"
  # From msm_vidc_res_parse.c: these are the properties the driver reads, and each one it cannot read has
  # its own dprintk. `qcom,imem-size` sizes the IMEM window; `max-secure-instances` caps the secure
  # sessions; `hfi-version` is what the firmware handshake is checked against.
  say "   hfi:         $(dtstr "$VIDC/qcom,hfi")  version $(dtstr "$VIDC/qcom,hfi-version")"
  say "   firmware:    $(dtstr "$VIDC/qcom,firmware-name")  (the name the PIL will look for)"
  say "   imem-size:   $(dtu32 "$VIDC/qcom,imem-size") bytes"
  say "   max-secure-instances: $(dtu32 "$VIDC/qcom,max-secure-instances")"
  say "   never-unload-fw: $([ -e "$VIDC/qcom,never-unload-fw" ] && echo yes || echo no)   sw-power-collapse: $([ -e "$VIDC/qcom,sw-power-collapse" ] && echo yes || echo no)"
  say "   max-hw-load: $(dtu32 "$VIDC/qcom,max-hw-load")"
  case "$VIDC_ST" in
  okay | ok | EMPTY | absent) ;;
  *) say "   -- status is not okay, so no driver will probe this node: whatever the properties say, there"
     say "      will be no /dev/video device and no client can open one." ;;
  esac
fi

# The firmware node. It is picked by `qcom,firmware-name`, not by its path: this board has FOUR
# qcom,pil-tz-generic nodes and they are different subsystems.
FW_NAME=$( [ -n "$VIDC" ] && dtstr "$VIDC/qcom,firmware-name" )
case "$FW_NAME" in absent | EMPTY | UNREADABLE | '') FW_NAME=venus; FW_SRC="default (the vidc node did not name one)" ;;
*) FW_SRC="read from the vidc node's qcom,firmware-name" ;;
esac
PIL_NODE=""
PIL_LIST=""
while IFS= read -r p; do
  [ -n "$p" ] || continue
  nm=$(dtstr "$p/qcom,firmware-name")
  PIL_LIST="$PIL_LIST $nm=${p#/proc/device-tree}"
  [ "$nm" = "$FW_NAME" ] && PIL_NODE="$p"
done <<EOF
$(nodes_with qcom,pil-tz-generic)
EOF
always "   firmware:    $FW_NAME  ($FW_SRC)"
if [ "$DT_RUNG" = unscanned ]; then
  say "   the PIL nodes could not be scanned either (same reason as above)"
elif [ -n "$PIL_NODE" ]; then
  always "   pil node:    ${PIL_NODE#/proc/device-tree}"
  say "   compatible:  $(dtlist "$PIL_NODE/compatible")"
  # NO status property here, unlike the vidc node -- and absent status means enabled in the device tree.
  PIL_ST=$(dtstr "$PIL_NODE/status")
  say "   status:      $PIL_ST  (an absent status means enabled; this node carries none)"
  say "   pas-id:      $(dtu32 "$PIL_NODE/qcom,pas-id")  (the secure-world PAS id, arg 0 of every scm_call)"
  say "   proxy-timeout-ms: $(dtu32 "$PIL_NODE/qcom,proxy-timeout-ms")"
  say "   proxy clocks/regs: $(dtlist "$PIL_NODE/qcom,proxy-clock-names") / $(dtlist "$PIL_NODE/qcom,proxy-reg-names")"
else
  always "   pil node:    NONE carries qcom,firmware-name = $FW_NAME"
  say "   -- so there is no firmware half for this block in the running tree, whatever the driver half says"
fi
say "   the siblings the loader serves, from the same compatible (the control group -- no count is printed"
say "   because the count is a reading, not a fact about this board):"
say "     $(san "$PIL_LIST")"

# --- 3. the PIL driver, and what is bound to it ----------------------------------------------------
hdr "the peripheral loader (drivers/base + subsys-pil-tz.c)"
DRV=/sys/bus/platform/drivers/subsys-pil-tz
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
  always "   (CONFIG_MSM_PIL=y and CONFIG_MSM_PIL_SSR_GENERIC=y in lineage_zl1_defconfig, so this is not a"
  always "    module that failed to load: if the directory is missing, the kernel did not build it in)"
fi
say "   (a driver directory appears as soon as the driver registers; a BOUND DEVICE is the symlink inside"
say "   it. Every node in the sibling list above shares this compatible, so the directory being present"
say "   says nothing about one node: only the bound list can say whether the video core was probed.)"

# --- 4. the subsystem entry: the firmware's own state ----------------------------------------------
hdr "the subsystems (the firmware's own state, on its own bus)"
ALLSUBS=""
if [ -d /sys/bus/msm_subsys/devices ]; then
  for d in /sys/bus/msm_subsys/devices/*; do
    [ -e "$d" ] || continue
    n=$(basename "$d")
    ALLSUBS="$ALLSUBS $n"
  done
  if [ -z "$ALLSUBS" ]; then
    always "   /sys/bus/msm_subsys/devices exists but is EMPTY -- the bus is registered and no subsystem is on it"
  else
    always "   entries:$ALLSUBS"
    always ""
    always "   $(printf '%-10s %-10s %-11s %-28s %s' SUBSYSTEM STATE CRASHES FIRMWARE RESTART)"
    for n in $ALLSUBS; do
      d=/sys/bus/msm_subsys/devices/$n
      always "   $(printf '%-10s %-10s %-11s %-28s %s' "$n" "$(rd "$d/state")" "$(rd "$d/crash_count")" \
        "$(san "$(rd "$d/firmware_name")")" "$(rd "$d/restart_level")")"
    done
    always ""
    say "   state is subsystem_restart.c's own vocabulary: OFFLINE / OFFLINING / ONLINE."
    say "   ONLINE means the firmware was authenticated by the secure world AND reset into life -- the one"
    say "   reading on this device that says the scm_call half succeeded."
  fi
else
  always "   /sys/bus/msm_subsys/devices: MISSING -- subsystem_restart did not register its bus"
fi
SUB=$(subsys_dir "$FW_NAME")
SUB_ST=unreadable
SUB_CRASH=UNREADABLE
SUB_ERR=UNREADABLE
if [ -d "$SUB" ]; then
  SUB_ST=$(rd "$SUB/state")
  SUB_CRASH=$(rd "$SUB/crash_count")
  SUB_ERR=$(rd "$SUB/error")
  always ""
  always "   $SUB"
  always "     state:          $SUB_ST"
  always "     crash_count:    $SUB_CRASH"
  always "     firmware_name:  $(san "$(rd "$SUB/firmware_name")")"
  always "     restart_level:  $(rd "$SUB/restart_level")"
  # `error` is the subsystem's own last error buffer. An empty one is a READING -- it says the framework
  # was never told this subsystem failed -- so it is printed with its emptiness named rather than as a
  # blank line, and the verdict reads the same distinction out of these two variables.
  case "$SUB_ERR" in
  EMPTY) always "     error:          (empty: nothing ever recorded a failure for this subsystem)" ;;
  UNREADABLE) always "     error:          UNREADABLE" ;;
  *) always "     error:          $SUB_ERR" ;;
  esac
else
  always ""
  always "   $SUB: MISSING -- the loader bound the node and registered no subsystem under the name '$FW_NAME'."
  always "   (The name comes from the device tree's qcom,firmware-name, so a mismatch between the tree and"
  always "    the loader shows up here.)"
fi

# --- 5. where the firmware is, from both namespaces ------------------------------------------------
hdr "the firmware file the loader will look for"
# TWO READINGS, NOT ONE, and the difference between them is real: the CMDLINE token is what the flashed
# boot image asked for, and the SYSSFS PARAMETER is what the kernel accepted. They are usually the same
# string, and a boot where they are not says the parameter was changed at runtime (or the module was
# loaded with a different value) -- which changes where the loader looks.
CMDPATH=$(grep -oE 'firmware_class\.path=[^ ]*' /proc/cmdline 2>/dev/null | sed -n 1p | cut -d= -f2-)
PARAM=$(rd /sys/module/firmware_class/parameters/path)
case "$PARAM" in UNREADABLE | EMPTY) PARAM="" ;; esac
always "   cmdline's firmware_class.path: ${CMDPATH:-（none: this boot's cmdline carries no such token)}"
always "   the live parameter (what the kernel accepted): ${PARAM:-（unset -- the built-in list only)}"
# The built-in list is the kernel's own, cited from firmware_class.c's fw_path[] rather than invented.
# `uname -r` stands in for UTS_RELEASE, the release the kernel was built with.
RELP=$(uname -r 2>/dev/null)
CAND="/lib/firmware/updates/$RELP /lib/firmware/updates /lib/firmware/$RELP /lib/firmware /lib64/firmware /lib/firmware/image"
say "   (the cmdline's own path is checked too, so a missing file is found even if the parameter was"
say "    later overwritten; the entries after it are firmware_class.c's built-in list, in its order)"
always "   looking for: $FW_NAME.mdt (+ its .b00.. segments):"
FOUND_MDT=""
SEG_COUNT=0
# The candidate list is deduplicated ONCE, before it is used: the cmdline token and the live parameter are
# normally the same path, and a list with it twice would print two HIT lines for one file. That is not
# cosmetic -- this section is read as "how many places hold the firmware", so a duplicate reads as a
# finding. (The container loop below uses the same list for the same reason.)
CANDS=""
SEEN=""
for c in $CMDPATH $PARAM $CAND; do
  [ -n "$c" ] || continue
  case " $SEEN " in *" $c "*) continue ;; esac
  SEEN="$SEEN $c"
  CANDS="$CANDS $c"
done
for c in $CANDS; do
  if [ -f "$c/$FW_NAME.mdt" ]; then
    seg=""
    segn=0
    for i in 0 1 2 3 4 5 6 7 8 9; do
      if [ -f "$c/$FW_NAME.b0$i" ]; then seg="$seg b0$i"; segn=$((segn + 1)); fi
    done
    # The loader needs the segments as well as the header (peripheral-loader.c: both are
    # request_firmware calls), so the count is kept: a lone .mdt is a fault with its own name.
    [ "$segn" -gt "$SEG_COUNT" ] && SEG_COUNT=$segn
    always "     HIT   $c/$FW_NAME.mdt   segments:${seg:- NONE}"
    [ -z "$FOUND_MDT" ] && FOUND_MDT="$c"
  elif [ -d "$c" ]; then
    say "     dir   $c  (exists, no $FW_NAME.mdt in it)"
  else
    say "     --    $c  (does not exist)"
  fi
done
[ -z "$FOUND_MDT" ] && always "     NO candidate path holds $FW_NAME.mdt"
# The same candidates in the CONTAINER's namespace, because filp_open resolves in the CALLER's -- and the
# caller that loads this firmware is whichever process first opens a video instance.
A=$(lxc-info -n android -pH 2>/dev/null | head -1)
if [ -n "$A" ]; then
  always "   the same candidates through the container's own root (android pid $A):"
  # WALKED BY THE HOST, NOT ENTERED (docs 162). This loop used to be
  #   v=$(nsenter -t "$A" -m -- ls -d "$c/$FW_NAME.mdt" 2>/dev/null)
  # and its sibling in zl1-modem-probe.sh is where both probes HUNG on 2026-09-25 -- twice, with the
  # device resetting itself 2m08s and 3m05s later (both instants read off the NEXT step's own `uptime`)
  # and with the step's device-side `timeout -k 5 240` never firing, because the reset came first and
  # the socket then went dark until the host's own backstop collected it. What that does NOT establish
  # is that the process was unkillable -- a bound that never got to fire and a signal that could not be
  # delivered print the same absence. The replacement removes the question: there is no call here that
  # can hang. `/proc/<pid>/root/<path>` is THAT path resolved in that process's mount namespace, walked
  # by the reading process: no setns, no fork into the container, and no container binary -- which is
  # exactly what the old note here was reaching for ("the container has no test(1) this project can rely
  # on", docs 117), because the test below is the HOST's own.
  for c in $CANDS; do
    if [ -e "/proc/$A/root$c/$FW_NAME.mdt" ]; then
      always "     HIT   $c/$FW_NAME.mdt"
    elif [ -e "/proc/$A/root$c" ]; then
      say "     dir   $c  (exists, no $FW_NAME.mdt in it)"
    else
      say "     --    $c  (does not exist)"
    fi
  done
  say "   (each line is about ${A}'s OWN root, so it is the container's view and not the host's -- but it"
  say "    is a PATH WALK, not a mount table: a file behind a mount that never happened and a file that is"
  say "    not there at all look the SAME in it. The mount list below is what separates those two.)"
else
  always "   the android container is not running (lxc-info answered nothing), so its own root could"
  always "   not be read -- which is NOT the same as the path being absent there."
fi
# Where the partition that holds it is mounted, if it is mounted at all. This is the reading that turns
# "the path does not exist" into "the path exists and the mount that fills it did not happen".
say "   mounts mentioning firmware/modem/venus:"
show "$(cat /proc/mounts 2>/dev/null)" 'firmware|modem|venus' \
  "(none: no mount on this boot mentions firmware, modem or venus)" 8

# --- 6. the driver half: what a video client would open --------------------------------------------
hdr "the v4l2 half (msm_v4l2_vidc.c)"
VDRV=/sys/bus/platform/drivers/msm_vidc_v4l2
VDEV=""
if [ -d "$VDRV" ]; then
  for b in "$VDRV"/*; do
    [ -e "$b" ] || continue
    case "$(basename "$b")" in bind | unbind | uevent | module) continue ;; esac
    VDEV="$VDEV $(basename "$b")"
  done
  always "   $VDRV: present"
  always "     bound devices:${VDEV:- NONE}"
else
  always "   $VDRV: MISSING -- the v4l2 half of the video driver did not register"
fi
# The platform device's own attributes. The path is found by following the driver's bound symlink, not
# assumed: the device name comes from the device tree node and this probe does not guess it.
for b in $VDEV; do
  d="$VDRV/$b"
  always "   attrs on $b:"
  for a in platform_version capability_version pwr_collapse_delay thermal_level; do
    if [ -e "$d/$a" ]; then say "     $(printf '%-20s' "$a") $(san "$(rd "$d/$a")")"
    else say "     $(printf '%-20s' "$a") (not there)"; fi
  done
  say "     (platform_version/capability_version are read from the SoC's efuse registers at probe and are"
  say "      READ-ONLY; pwr_collapse_delay and thermal_level are 0644 -- WRITABLE -- and this probe writes"
  say "      neither of them.)"
done
# BASE_DEVICE_NUMBER 32 in msm_v4l2_vidc.c, so the decoder is /dev/video32 and the encoder /dev/video33.
VNODES=0
for n in 32 33; do
  if [ -e "/dev/video$n" ]; then VNODES=$((VNODES + 1)); always "   /dev/video$n: present"
  else always "   /dev/video$n: MISSING"; fi
done
say "   (32 is BASE_DEVICE_NUMBER in msm_v4l2_vidc.c: the decoder registers at nr, the encoder at nr+1.)"
say "   every video4linux class entry on this boot, by name:"
V4L=""
for d in /sys/class/video4linux/*; do
  [ -e "$d" ] || continue
  V4L="$V4L $(basename "$d")=$(san "$(rd "$d/name")")"
done
say "    ${V4L:-（none: /sys/class/video4linux has no entries at all)}"
say "   (the camera's ISP video nodes are in this list too -- which is why the two numbers above are"
say "    asserted and the rest are printed rather than guessed at.)"

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
  always "   and the log only separates 'never asked' from 'asked and failed' when both could apply."
  show "" x "(not read: the kernel log could not be read)" 1 1
else
  always "   source: $LOG_SRC"
  show "$LOG_TEXT" 'venus|vidc' \
    "(none: the kernel log mentions neither venus nor vidc this boot)" 20
  # The failure strings, taken from the sources rather than guessed: peripheral-loader.c:797 dev_errs
  # "Failed to locate %s" with the file name, venus_hfi.c dev_errs "Failed to download firmware", and
  # subsys-pil-tz.c prints "Fatal error on %s!" / "subsystem failure reason:". SCM refusals show up as
  # the pas id or the -12 the call returned.
  show "$LOG_TEXT" 'Failed to locate|Failed to download firmware|Fatal error on venus|subsystem failure reason|scm_call|scm-pas|PAS_|pas_id|auth_and_reset|Failed to init resources|Failed to power on venus' \
    "(none: no venus firmware or secure-world failure in this boot's log)" 20
  show "$LOG_TEXT" 'msm_vidc|msm_v4l2|subsys-pil|pil_tz|subsystem_restart' \
    "(none: no loader or vidc driver lines in this boot's log)" 10
fi

# --- verdict ---------------------------------------------------------------------------------------
# "Somebody tried and it failed" needs EVIDENCE, and it is computed here rather than inferred from the
# subsystem being merely not-ONLINE -- because for this block not-ONLINE is the normal, healthy state
# (nothing loads the firmware until a client opens a video instance). A crash count that is a NUMBER and
# not 0, or an error buffer with text in it, is that evidence; an unreadable attribute is not.
LOAD_EVIDENCE=no
case "$SUB_CRASH" in 0 | EMPTY | UNREADABLE | '') ;; *) LOAD_EVIDENCE=yes ;; esac
case "$SUB_ERR" in EMPTY | UNREADABLE | '') ;; *) LOAD_EVIDENCE=yes ;; esac

# The rung the evidence reaches, named. Each rung is a different problem with a different next move, and
# the first one is a different BOARD.
if [ "$DT_RUNG" = unscanned ]; then
  V=tree-unscanned
  VMSG="the device tree could not be searched for a compatible (no find(1), and none of the node shapes this probe knows is present). Nothing about the video core was read, so nothing here is a verdict about it."
elif [ "$BOARD" = x2 ]; then
  V=wrong-board-tree
  VMSG="this boot is running the LE_X2's device tree, not this phone's. The flashed image's appended blob carries both boards' trees under an identical root compatible, so nothing below is about the zl1. The next move is about which DTB the bootloader picked, not about the video core."
elif [ "$BOARD" = other ] || [ "$BOARD" = unknown ]; then
  V=unknown-board
  VMSG="the device tree's model names neither LE_ZL1 nor LE_X2 (read: $MODEL), so this reading cannot be attributed to this phone. The readings below stand on their own; the attribution does not."
elif [ "$DT_RUNG" = no-node ]; then
  V=no-device-tree-node
  VMSG="this device tree declares no qcom,msm-vidc node, so the video driver has nothing to bind to. The node is in all three device-tree sets (stock, rebuilt, filtered) and in every one of the 5 ZL1 trees, so a missing node means the tree that booted is not one of this board's five."
elif [ "$VIDC_ST" != okay ] && [ "$VIDC_ST" != ok ] && [ "$VIDC_ST" != EMPTY ] && [ "$VIDC_ST" != absent ]; then
  V=node-disabled
  VMSG="the video core node is declared and its status is '$VIDC_ST', so the kernel will not probe it: no driver, no /dev/video node, and no client can open a session. Nothing about the firmware can be read from that state."
elif [ -z "$PIL_NODE" ]; then
  V=no-firmware-node
  VMSG="no node in this device tree carries qcom,pil-tz-generic with qcom,firmware-name = '$FW_NAME', so this board's tree has no firmware half for this block and nothing can ever load one. The device tree node is the CAUSE here -- a missing subsystem entry or an unbound loader would be its effects, which is why this rung is asked before them: the four sibling PIL nodes are printed above, so the reader can see which firmware names the tree does declare."
elif [ -z "$DRV_BOUND" ]; then
  V=pil-not-bound
  VMSG="the firmware node is declared and no device is bound to the peripheral loader ($DRV): either the driver did not register (the directory is missing) or it registered and this node was not probed. No client can load this firmware from that state, and the loader's own dprintks name the clock/regulator property it could not read."
elif [ ! -d "$SUB" ]; then
  V=no-subsys-entry
  VMSG="the loader bound the venus node and the subsystem framework has no entry named '$FW_NAME' at $SUB, so nothing will ever bring this firmware up. The name comes from the device tree's qcom,firmware-name -- a mismatch between the tree and the loader shows up here and nowhere else."
elif [ -z "$FOUND_MDT" ]; then
  V=firmware-unreachable
  VMSG="the firmware file $FW_NAME.mdt is not in ANY of the paths the kernel will try (the flashed cmdline's firmware_class.path and firmware_class.c's own list), in this process's mount namespace. A load would fail with -ENOENT. This is a MOUNT/path problem, not a hardware one -- and note which namespace was checked: the loader resolves these paths in the CALLER's, so a container-side client may still succeed where a UT-side one fails."
elif [ "$SEG_COUNT" = 0 ]; then
  V=firmware-incomplete
  VMSG="$FW_NAME.mdt is at $FOUND_MDT and not one of its .b00.. segments is. The loader needs both: peripheral-loader.c's pil_boot() reads <name>.mdt first, builds its segment list from THAT FILE's own program headers (mdt->hdr.e_phnum), and then loads each segment with pil_load_seg(), whose failure path is 'Failed to locate blob %s or blob is too big.'. So a lone .mdt is a firmware that can never load -- a real fault, not an idle core, and a different one from a missing path."
elif [ "$SUB_ST" = ONLINE ]; then
  if [ "$VNODES" = 2 ]; then
    V=online
    VMSG="the venus firmware is up (the subsystem is ONLINE, which means the secure world authenticated it) and both V4L2 devices are registered. Whether video actually decodes needs a session -- see the note under this verdict."
  else
    V=no-video-device
    VMSG="the firmware is up, and the v4l2 half did not register both /dev/video32 and /dev/video33 (found $VNODES of 2). The two halves are separate: the firmware can be up with no client-facing device, and that is where the driver's own probe failure would show."
  fi
elif [ "$LOAD_EVIDENCE" = yes ]; then
  V=load-failed
  VMSG="the subsystem is $SUB_ST and it carries evidence of a failed attempt: crash_count=$SUB_CRASH, error='$(san "$SUB_ERR")'. So this is not 'nobody asked' -- something asked and the load did not complete. The log section above says which half failed (the file, or the secure world)."
else
  V=firmware-not-loaded
  VMSG="everything the load needs is in place -- node, driver, bound device, subsystem entry, and $FW_NAME.mdt reachable at $FOUND_MDT -- and the subsystem is $SUB_ST with no error and no crash: NO CLIENT HAS ASKED YET. venus_hfi.c loads this firmware from __load_fw(), which runs when something opens a video instance, so this is what an idle, healthy boot looks like. It is NOT a fault, and it is not evidence that video works either."
fi

always ""
always "== verdict: $V"
always "   $VMSG"
always ""
always "   WHAT THIS IS NOT: an answer to 'does video decode'. That needs a session -- open /dev/video32,"
always "   negotiate formats, feed it a stream -- and opening a session is ALSO what loads the firmware, so a"
always "   probe that 'fixed' firmware-not-loaded by starting one would be writing to the device and erasing"
always "   the reading at the same time. Making the core come up is a separate, reviewed step."

case "$V" in
online) exit 0 ;;
*) exit 1 ;;
esac
