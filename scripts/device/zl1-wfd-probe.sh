#!/bin/sh
# zl1 WFD / writeback probe -- the three device-tree nodes that describe this board's screen mirroring,
# the one property that decides HOW MANY writeback blocks exist, the phandle the chain fails on, and the
# two runtime traces the whole chain leaves behind.
#
# Why this exists. doc 137 enumerated this board's hardware from its own device trees and named the
# blocks nothing in this tree reads; `wfd` is one of them, and the row's own pattern names two nodes
# while a THIRD belongs to the block. Five readings make this probe's design:
#
#   1. THE BLOCK IS TWO NODES, THE HARDWARE COUNTS ARE ON TWO OTHERS, AND A THIRD NODE IS THE OTHER
#      GENERATION. (So the block is three nodes, and the row's pattern named two of them.) `/soc/qcom,mdss_wb_panel` (`qcom,mdss_wb`) is the panel; its `qcom,mdss-fb-map`
#      phandle resolves to `/soc/qcom,mdss_mdp@900000/qcom,mdss_fb_wfd` (`qcom,mdss-fb`,
#      `cell-index = 1`), which is the framebuffer. `/soc/qcom,display-manager/qcom,wb-display@0`
#      (`qcom,wb-display`, `label = wb_display`) is a third node matching NOTHING in this kernel source.
#      And the numbers that size the hardware are not here: `qcom,mdss-wb-count = 2` sits on
#      `/soc/qcom,mdss_rotator` (mdss_rotator.c reads it and refuses to probe without it), while
#      `qcom,mdss-wb-off` and `qcom,mdss-mixer-wb-off` are on the mdss_mdp node. A probe that looked only
#      at nodes with `wb` in the compatible would report half the block.
#   2. `qcom,mdss-wfd-mode` IS READ TWICE, FROM THE SAME NODE, WITH TWO DIFFERENT CONSEQUENCES.
#      mdss_mdp.c sets `mdata->wfd_mode` from it -- INTERFACE / SHARED / DEDICATED, and it `pr_warn`s
#      "wfd mode not configured. Set to default: Shared" when the property is ABSENT. Then
#      `mdss_mdp_parse_dt_wb()` reads the SAME property a second time and sets `num_intf_wb = 1` exactly
#      when the value is NOT "shared" -- so this one string decides whether an interface-writeback block
#      is allocated, and therefore how many writeback blocks the driver has. This board says `intf`.
#   3. THE CHAIN IS A PHANDLE, AND IT FAILS BEFORE THE FIRST RUNTIME TRACE.
#      `mdss_wb_probe` -> `mdss_wb_dev_init` (registers a SWITCH named "wfd") -> `mdss_register_panel()`
#      -> reads `qcom,mdss-fb-map` FROM THE PANEL'S OWN NODE -> `of_platform_device_create()` on the
#      `qcom,mdss-fb` child -> that device's probe registers the framebuffer. Without the phandle,
#      `mdss_register_panel()` prints "Unable to find fb node for device" and returns -ENODEV, and
#      `mdss_wb_probe`'s error path UNREGISTERS the switch again. So `/sys/class/switch/wfd` existing is
#      an end-to-end witness: it means the driver bound, the panel's DT parsed, the phandle resolved AND
#      the framebuffer device was created.
#   4. THAT WITNESS IS READ-ONLY, AND THE WRITE-CLASS MOVE OF THIS BLOCK IS AN IOCTL, NOT A WRITE.
#      `/sys/class/switch/wfd/{name,state}` is created by `switch_dev_register()`, and `state` is
#      `DEVICE_ATTR(state, S_IRUGO, state_show, NULL)` -- a NULL store, so a shell write is refused by
#      the kernel. The value is set only by `switch_set_state()`, called from
#      `mdss_mdp_wb_set_mirr_hint()` for MDP_WRITEBACK_MIRROR_{ON,PAUSE,RESUME,OFF} -- and that is
#      reached from an ioctl on the FRAMEBUFFER device. So the temptation here is not a sysfs write but
#      opening /dev/graphics/fbN and issuing a mirror ioctl, which would change the block's state AND
#      emit a uevent. This probe opens no framebuffer and issues no ioctl.
#   5. WHICH /dev/fbN IS THE WRITEBACK ONE IS THE PANEL'S TYPE, NOT THE NUMBER -- and not the name
#      either. `msm_fb_type` (read-only) prints "writeback panel" for it, and the KERNEL finds it the
#      same way: `msm_fb_get_writeback_fb()` walks `fbi_list` looking for `panel.type == WRITEBACK_PANEL`.
#      The number is a registration order (`fbi_list[fbi_list_index++]`), and
#      `/sys/class/graphics/fbN/name` is worse than a number: `fix->id` is built as `"mdssfb_%x"` from
#      `(int *)&mfd->panel`, i.e. from the FIRST field of `struct mdss_panel_info`, which is `xres`. So
#      the "name" is the panel's horizontal resolution in hex -- 640 here, so `mdssfb_280` -- and two
#      framebuffers of the same resolution carry the same name.
#
# WHAT THIS CANNOT SAY: whether screen mirroring works. A bound panel driver, a registered switch and a
# framebuffer of type `writeback panel` are all prerequisites, and none of them is a mirrored picture:
# the mirror is turned on by an ioctl this probe does not make, and the switch state reads 0 until
# something does.
#
# **Read-only, and it writes nothing at all** -- not even a scratch file, which is why the kernel log is
# captured into a shell variable. Every knob in sight is named and left alone:
#   * the writeback framebuffer's own mdss attributes: `blank`, `msm_fb_panel_status`,
#     `msm_fb_dfps_mode`, `idle_time`, `msm_fb_thermal_level`, `disable_bl_scaling`, and
#     `trigger_reset` / `dsi_write` -- writing any of them is a state-changing command to a panel;
#   * `/dev/graphics/fbN` itself: the mirror hints (`MDP_WRITEBACK_MIRROR_ON` and friends) arrive as an
#     ioctl on that device, and the switch this probe reads is written by exactly that path;
#   * the rotator's `qcom,mdss-wb-count` and the mdss node's wb offsets, which are device-tree
#     properties -- they are boot-image decisions, not runtime knobs, and this probe reads them as such.
#
# Usage (on the device):
#   sh zl1-wfd-probe.sh             # every rung, then a verdict
#   sh zl1-wfd-probe.sh --quiet     # the verdict and the readings it rests on
#   sh zl1-wfd-probe.sh --explain   # what each reading decides, and why this reading
#
# Exit: 0 the writeback panel driver is bound, its switch is registered and its framebuffer is there;
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
# which means "no match" for a reader that is not expecting it, so every reader below sanitizes what it
# prints: `dtstr` per string, `dtlist` per list entry.
# NOTE THE `tr -d '\n'` BEFORE THE SANITIZER. `tr -c '[:print:]' '.'` replaces every byte that is not
# printable -- and a newline is not, so the line `sed -n 1p` just emitted would come back with a trailing
# dot: `ok` reads as `ok.` and every comparison against it silently misses.
dtstr() { # $1 = path
  if [ ! -r "$1" ]; then printf 'absent'; return; fi
  v=$(tr '\0' '\n' < "$1" 2>/dev/null | sed -n 1p | tr -d '\n' | LC_ALL=C tr -c '[:print:]' '.')
  printf '%s' "${v:-EMPTY}"
}
# Every string of a property, not just the first: a compatible list and `reg-names` are LISTS, and reading
# only the first entry is how a property looks like it does not carry the entry you want.
dtlist() { # $1 = path
  if [ ! -r "$1" ]; then printf 'absent'; return; fi
  v=$(tr '\0' '\n' < "$1" 2>/dev/null | grep . | LC_ALL=C tr -c '[:print:]\n' '.' | tr '\n' ' ')
  printf '%s' "${v:-EMPTY}"
}
# A device-tree u32 is BIG-ENDIAN and this SoC is little-endian, so `od -tu4` on the file prints the value
# BYTE-SWAPPED -- an offset of 0x65000 comes out as a number of the right shape and the wrong value. The
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
# EVERY cell of a property, as decimal numbers separated by spaces, or a named reason why not. Both the wb
# offsets and `qcom,mdss_pan_res` are arrays whose LENGTH is the reading -- reading only the first cell is
# how a 640x480 panel looks like a 640-wide one.
dtu32s() { # $1 = path
  if [ ! -r "$1" ]; then printf 'absent'; return; fi
  _us_vals=$(od -An -tu1 "$1" 2>/dev/null)
  _us_n=0; _us_out=""; _us_v=0; _us_k=0
  for _us_x in $_us_vals; do
    _us_k=$(( _us_n % 4 ))
    case "$_us_k" in
    0) _us_v=$((_us_x * 16777216)) ;;
    1) _us_v=$((_us_v + _us_x * 65536)) ;;
    2) _us_v=$((_us_v + _us_x * 256)) ;;
    3) _us_v=$((_us_v + _us_x)); _us_out="$_us_out $_us_v" ;;
    esac
    _us_n=$((_us_n + 1))
  done
  if [ "$_us_n" = 0 ]; then printf 'EMPTY'; return; fi
  if [ $((_us_n % 4)) != 0 ]; then printf 'not-u32s(%s bytes)' "$_us_n"; return; fi
  printf '%s' "$(printf '%s' "$_us_out" | sed 's/^ //')"
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
  # The known node shapes for a kernel without find(1). This block's nodes sit under the SoC node, under
  # the mdss_mdp node and under the display-manager, so the fallback walks the shapes rather than a list --
  # a node that moved one level is exactly what this scan exists to survive.
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
# Resolve a phandle to the node that carries it. `qcom,mdss-fb-map` is a phandle to the framebuffer node,
# and the phandle is the only thing saying WHICH node that is -- printing the raw number would leave the
# reader to guess, and the number is not the identity (four `qcom,mdss-fb` children share the compatible).
# A phandle can be carried by more than one node in a hand-built tree, so an ambiguous answer says so
# rather than picking one. But the SAME node can carry the same phandle TWICE -- as `phandle` and as the
# older `linux,phandle`, which every mdss node on this board does -- and counting matches rather than
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
  0) printf 'unresolved' ;;
  1) printf '%s' "${_ph_first#/proc/device-tree}" ;;
  *) printf 'AMBIGUOUS(%s)' "$_ph_hits" ;;
  esac
}
# The driver row for ONE node: the same three lines the scan loop prints, for the nodes the block owns but
# the scan does not look for (the rotator, the mdp and the framebuffer child). It exists because the
# matching in `drivers_for` is what carries the two name mismatches this block has -- `mdp` for the MDP, and
# the rotator having no option of its own -- and a match nothing calls prints nothing.
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
# The driver that MATCHES a compatible, straight out of the kernel source -- each line is
# "driver-name<TAB>config-option<TAB>source-file<TAB>bus<TAB>how-it-matches". A compatible with no match
# prints `none`, which is a reading (a node nothing can bind) and not an error.
#
# TWO THINGS ABOUT THIS BLOCK'S MATCHING ARE WORTH SPELLING OUT.
#   * `qcom,mdss_wb` and `qcom,mdss-fb` are BOTH built into the flashed kernel
#     (CONFIG_FB_MSM_MDSS_WRITEBACK=y and CONFIG_FB_MSM_MDSS=y), so this block's rung is about BINDING and
#     not about a missing driver or a config line -- unlike the usb-pd block (nothing built) and the sde
#     generation of HDMI (no code at all).
#   * `qcom,wb-display` matches NOTHING. It is a display-manager child of the same generation as
#     `qcom,hdmi-display`, and neither has code in a 3.18 kernel: `qcom,wb-display` appears in eight
#     device-tree files of this project's reference tree and in not one .c or .h file. It is named in the
#     report so that the block's own node count is a reading rather than a pattern's accident.
#   * `qcom,mdss_rotator` is listed because it is where the block's HARDWARE COUNT lives: mdss_rotator.c
#     READS `qcom,mdss-wb-count` and refuses to probe ("Error in device tree") when it is absent, so the
#     rotator and the writeback panel are one description split over two nodes.
drivers_for() { # $1 = compatible
  case "$1" in
  qcom,mdss_wb)
    printf 'mdss_wb\tCONFIG_FB_MSM_MDSS_WRITEBACK\tdrivers/video/msm/mdss/mdss_wb.c\tplatform\tby of_match "qcom,mdss_wb" (the writeback panel)\n'
    ;;
  qcom,mdss-fb)
    printf 'mdss_fb\tCONFIG_FB_MSM_MDSS\tdrivers/video/msm/mdss/mdss_fb.c\tplatform\tby of_match "qcom,mdss-fb" (shared by primary, secondary, wfd and hdmi)\n'
    ;;
  qcom,wb-display)
    printf 'none\t-\t-\t-\t-\n'
    ;;
  qcom,mdss_rotator)
    # THE ROTATOR HAS NO CONFIG OPTION OF ITS OWN. mdss_rotator.c is in `mdss-mdp-objs` in
    # drivers/video/msm/mdss/Makefile, so it is built by CONFIG_FB_MSM_MDSS and by nothing else -- there is
    # no CONFIG_MSM_ROTATOR in this tree at all (the flashed config has no ROTATOR option except the
    # unrelated SDE one). A reader who looked for a rotator option would find it "not set" and conclude the
    # rotator is missing from a kernel that builds it.
    printf 'mdss_rotator\tCONFIG_FB_MSM_MDSS\tdrivers/video/msm/mdss/mdss_rotator.c\tplatform\tby of_match "qcom,mdss_rotator" (it owns qcom,mdss-wb-count; built via mdss-mdp-objs, so its option is the MDP.s)\n'
    ;;
  qcom,mdss_mdp)
    # THE DRIVER NAME IS NOT THE COMPATIBLE'S. mdss_mdp.c registers its platform driver as "mdp" -- the
    # comment in the source says so out loud ("Driver name must match the device name added in
    # platform.c") -- while the of_match is "qcom,mdss_mdp". So the driver DIRECTORY is
    # /sys/bus/platform/drivers/mdp, and a reader who looked for `mdss_mdp` there would find nothing and
    # could conclude the MDP never registered on a device whose display is working. The WFD probe prints
    # both names for that reason.
    printf 'mdp\tCONFIG_FB_MSM_MDSS\tdrivers/video/msm/mdss/mdss_mdp.c\tplatform\tby of_match "qcom,mdss_mdp" -- but registered as "mdp" (it owns qcom,mdss-wb-off and reads qcom,mdss-wfd-mode twice)\n'
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
# The panel's DT numbers are read through DEFAULTS that live in the driver, so a board with the property
# missing does not read as "unset" -- it reads as the driver's default, and the probe has to say which it
# is looking at. The default for `qcom,mdss_pan_res` is 1280x720 and for `qcom,mdss_pan_bpp` 24.
pan_res() { # $1 = node dir
  _pr_v=$(dtu32s "$1/qcom,mdss_pan_res")
  case "$_pr_v" in
  absent) printf 'ABSENT -- the driver would use its own default, 1280x720, and the panel would be built with a resolution this board did not choose' ;;
  not-u32s*) printf '%s' "$_pr_v" ;;
  *) printf '%s   (xres %s, yres %s)' "$_pr_v" "$(printf '%s' "$_pr_v" | cut -d' ' -f1)" "$(printf '%s' "$_pr_v" | cut -d' ' -f2)" ;;
  esac
}

if [ "$MODE" = explain ]; then
  cat <<'EOF'
zl1 WFD / writeback probe -- what each reading decides, and why it is this reading

  1. WHAT THE BLOCK ACTUALLY IS, AND WHY ITS COUNT IS SOMEWHERE ELSE.
     Two nodes describe it: `/soc/qcom,mdss_wb_panel` (`qcom,mdss_wb`, the writeback panel) and the
     `qcom,mdss-fb` child its `qcom,mdss-fb-map` points at (`qcom,mdss_fb_wfd`, `cell-index = 1`). A
     third node carries the compatible of another generation (`qcom,wb-display`) and has no driver here.
     And the numbers that SIZE the hardware are on two different nodes: `qcom,mdss-wb-count` is on the
     rotator, `qcom,mdss-wb-off` and `qcom,mdss-mixer-wb-off` are on mdss_mdp. The probe prints all of
     them, because a reading of this block that stopped at the `wb` nodes would miss where the writeback
     blocks are counted.

  2. THE ONE STRING THAT DECIDES WHETHER A WRITEBACK BLOCK EXISTS.
     `qcom,mdss-wfd-mode` is read TWICE from the mdss_mdp node. mdss_mdp.c turns it into
     `mdata->wfd_mode` (INTERFACE / SHARED / DEDICATED) and `pr_warn`s when it is absent;
     `mdss_mdp_parse_dt_wb()` reads the same property again and sets `num_intf_wb = 1` exactly when the
     value is NOT "shared". So this board's value -- `intf` -- is the difference between one interface
     writeback block and none, and the probe prints both consequences next to the string.

  3. THE CHAIN, AND THE ONE LINK THAT FAILS BEFORE ANYTHING RUNTIME EXISTS.
     mdss_wb_probe() -> mdss_wb_dev_init() (a switch named "wfd") -> mdss_register_panel() -> the
     `qcom,mdss-fb-map` PHANDLE read from the PANEL's node -> a platform device for the `qcom,mdss-fb`
     child -> that device's own probe -> register_framebuffer(). The failure the probe reaches for is the
     third: without the phandle, `mdss_register_panel()` logs "Unable to find fb node for device" and
     returns -ENODEV, and the probe's error path then UNREGISTERS the switch. So the switch device is not
     one runtime trace among several -- it is the last thing standing only if every earlier step worked.

  4. THE WRITE-CLASS MOVE ON THIS BLOCK IS AN IOCTL.
     `/sys/class/switch/wfd/state` is `DEVICE_ATTR(state, S_IRUGO, state_show, NULL)`: there is no store,
     so a write is refused by the kernel, and the value is only ever set by `switch_set_state()` from
     `mdss_mdp_wb_set_mirr_hint()` -- reached through an MDP ioctl on the framebuffer device. So the probe
     names the ioctl path as the move it does not make, instead of pretending a sysfs write is the risk.
     The framebuffer's own mdss attributes (`blank`, `msm_fb_panel_status`, `trigger_reset`, ...) are
     writable and are left alone too.

  5. WHY THE FRAMEBUFFER IS IDENTIFIED BY ITS TYPE AND NOT BY ITS NUMBER OR NAME.
     `msm_fb_type` reads "writeback panel" for it, and the KERNEL does the same thing:
     `msm_fb_get_writeback_fb()` walks `fbi_list` for `panel.type == WRITEBACK_PANEL`. The `/dev/fbN`
     number is a registration order, and the fb's `name` is `fix->id` = `"mdssfb_%x"` of
     `(int *)&mfd->panel` -- the FIRST field of the panel info struct, which is `xres`. So the name is a
     resolution in hex (640 -> `mdssfb_280`), which is a property of the panel and not of the device.

  WHAT THIS CANNOT SAY: that mirroring works. The switch exists only if the chain got to the end, but its
  state stays 0 until something asks for a mirror, and asking is an ioctl. This probe writes nothing and
  opens no framebuffer.
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
  always "               carries both boards' trees (5 LE_ZL1 + 23 LE_X2), and BOTH declare the same"
  always "               writeback panel at the same path -- so the tree's shape cannot tell you whose"
  always "               reading this is, and only 'model' can. Everything below is the other phone's."
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
hdr "the writeback nodes the device tree declares"
# The compatibles this block is known to use. `qcom,mdss-fb` is deliberately NOT scanned here: four
# children of mdss_mdp carry it and only one of them is this block's, and the framebuffer is reached the
# way the KERNEL reaches it -- through the panel's `qcom,mdss-fb-map` phandle, in section 6.
CANDS="qcom,mdss_wb qcom,wb-display"
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
  always "   the device tree could not be searched for this block's compatibles at all: find(1) is missing"
  always "   AND no known node shape exists. This is NOT 'the tree declares no writeback panel' -- it is"
  always "   'this probe could not look', and the two must not print the same way."
else
  if [ -z "$NODES" ]; then
    DT_RUNG=no-node
    always ""
    always "   no node in this device tree carries 'qcom,mdss_wb' or 'qcom,wb-display' -- the running tree"
    always "   declares no writeback panel at all. The paths are not assumed: the whole tree is scanned."
  else
    DT_RUNG=node
    always ""
  fi
fi

# The panel's own node, and the counters that come off it, are collected here and printed once.
PANEL_NODES=""
N_PANEL=0
N_PANEL_ENABLED=0
N_PANEL_WITH_DRIVER=0
N_PANEL_REGISTERED=0
N_PANEL_BOUND=0
if [ "$DT_RUNG" = node ]; then
  for p in $NODES; do
    # MEMBERSHIP, NOT THE FIRST ENTRY. `compatible` is a NUL-separated LIST, and `nodes_with` finds this
    # node because the list CONTAINS the block's string -- so classifying on the first entry alone would
    # find the node and then decline to count it, which prints as "the panel is not enabled" on a tree
    # where it is. The block's own string wins when the list carries it; otherwise the first entry stands.
    CL=$(dtlist "$p/compatible")
    C=$(dtstr "$p/compatible")
    for _cm in qcom,mdss_wb qcom,wb-display; do
      case " $CL " in *" $_cm "*) C="$_cm" ;; esac
    done
    ST=$(dtstr "$p/status")
    # AN ABSENT `status` IS ENABLED -- the same reading the HDMI block turns on, and it is the reading that
    # matters here too: this board's wb panel node carries NO `status` property, which the device tree
    # means as enabled. A probe that read `absent` as "not okay" would report this block as switched off
    # by its own tree while the kernel is perfectly willing to bind it.
    # ONE PLACE DECIDES, and every count below reads this one variable -- so a reading of `absent` that is
    # wrong moves the enabled count, the with-driver count AND the verdict together, instead of leaving the
    # numbers saying one thing and the rung another.
    case "$ST" in okay | ok | EMPTY | absent) EN=yes ;; *) EN=no ;; esac
    case "$ST" in
    absent) ST_SHOW="absent (an absent status means enabled; this node carries none)" ;;
    *) ST_SHOW="$ST" ;;
    esac
    case "$C" in
    qcom,mdss_wb)
      N_PANEL=$((N_PANEL + 1))
      PANEL_NODES="$PANEL_NODES $p"
      [ "$EN" = yes ] && N_PANEL_ENABLED=$((N_PANEL_ENABLED + 1))
      ;;
    esac
    always ""
    always "   ${p#/proc/device-tree}"
    always "     compatible:  $(dtlist "$p/compatible")"
    always "     status:      $ST_SHOW"
    DRV=$(drivers_for "$C")
    DN=$(printf '%s' "$DRV" | cut -f1)
    DC=$(printf '%s' "$DRV" | cut -f2)
    DF=$(printf '%s' "$DRV" | cut -f3)
    DB=$(printf '%s' "$DRV" | cut -f4)
    DH=$(printf '%s' "$DRV" | cut -f5)
    case "$DN" in
    none)
      always "     drivers:     NONE in this kernel source matches '$C' -- nothing can ever bind it, under"
      always "                  any config"
      ;;
    *)
      always "     driver:      $DN  ($DF, $DB, $DH)"
      case "$C" in
      qcom,mdss_wb)
        [ "$EN" = yes ] && N_PANEL_WITH_DRIVER=$((N_PANEL_WITH_DRIVER + 1))
        REG=$(drv_registered "$DB" "$DN")
        BND=$(drv_bound "$DB" "$DN")
        always "       registered: $REG   bound: $( [ -n "$BND" ] && printf '%s' "${BND# }" || printf 'NONE' )   config $DC: $(cfg_opt "$DC")"
        [ "$REG" = yes ] && N_PANEL_REGISTERED=$((N_PANEL_REGISTERED + 1))
        [ -n "$BND" ] && N_PANEL_BOUND=$((N_PANEL_BOUND + 1))
        ;;
      *)
        always "       registered: $(drv_registered "$DB" "$DN")   bound: $(drv_bound "$DB" "$DN")   config $DC: $(cfg_opt "$DC")"
        ;;
      esac
      ;;
    esac
    # The properties the two OTHER nodes of this description carry, printed where the block is read rather
    # than left to a grep: the count is on the rotator and the offsets are on mdss_mdp.
    case "$C" in
    qcom,wb-display)
      always "     cell-index:  $(dtu32 "$p/cell-index")   label: $(dtstr "$p/label")"
      always "                  -- and NOTHING in this kernel source matches 'qcom,wb-display': it belongs to"
      always "                     the display-manager generation, the same one as 'qcom,hdmi-display'. Its"
      always "                     presence is a reading about which tree this is, not about a driver."
      ;;
    esac
  done
  always ""
  always "   COUNTED, because every rung below is one of these four questions:"
  always "     $N_NODES node(s) in this tree belong to the block ($N_PANEL of them the writeback panel)"
  always "     $N_PANEL_ENABLED of $N_PANEL panel node(s) are ENABLED (a node with NO status property is"
  always "                enabled -- this board's panel node carries none)"
  always "     $N_PANEL_WITH_DRIVER of those MATCH a driver in this kernel source (independent of config)"
  always "     $N_PANEL_REGISTERED of those have that driver REGISTERED in this boot (this is the defconfig"
  always "                question -- on the flashed kernel it is already yes)"
  always "     $N_PANEL_BOUND of those have it BOUND to the device (this is the probe's own question)"
  # The two properties that size the block, on the nodes the row's pattern does not name.
  WBN=""
  ROT=$(nodes_with qcom,mdss_rotator | sed -n 1p)
  if [ -n "$ROT" ] && [ -d "$ROT" ]; then
    WBN=$(dtu32 "$ROT/qcom,mdss-wb-count")
    always ""
    always "   ${ROT#/proc/device-tree}"
    always "     qcom,mdss-wb-count: $WBN   <- the block's hardware count, and it is HERE and not on a wb node."
    always "                  mdss_rotator.c READS this property and refuses to probe without it"
    always "                  (\"Error in device tree\"), and it must be <= ROT_MAX_HW_BLOCKS. So the rotator"
    always "                  and the writeback panel are one description split over two nodes."
    node_driver_row qcom,mdss_rotator
  fi
fi

# --- 4. the one string that decides whether an interface-writeback block exists ----------------------
if [ "$DT_RUNG" = node ]; then
  MDP=$(nodes_with qcom,mdss_mdp | sed -n 1p)
  WFD_MODE="absent"
  [ -n "$MDP" ] && [ -d "$MDP" ] && WFD_MODE=$(dtstr "$MDP/qcom,mdss-wfd-mode")
  hdr "the property that sizes the writeback hardware"
  # num_intf_wb is the ONE number in this block that no property carries: mdss_mdp_parse_dt_wb() derives it
  # from the STRING above, and only when the property is there and is not "shared".
  N_INTF=1
  case "$WFD_MODE" in absent | EMPTY | shared) N_INTF=0 ;; esac
  case "$WFD_MODE" in
  absent | EMPTY)
    always "   qcom,mdss-wfd-mode: $WFD_MODE"
    always "     ABSENT IS NOT NEUTRAL HERE. mdss_mdp.c would fall back to SHARED and log"
    always "     \"wfd mode not configured. Set to default: Shared\", and mdss_mdp_parse_dt_wb() decides"
    always "     num_intf_wb from this same property -- so an absent property means NO interface-writeback"
    always "     block is allocated and the writeback path is the shared one. The probe cannot tell that"
    always "     apart from a tree that meant it, which is exactly why the absence is printed as a state."
    ;;
  *)
    always "   qcom,mdss-wfd-mode: $WFD_MODE"
    always "     READ TWICE, FROM THIS ONE NODE, WITH TWO CONSEQUENCES:"
    case "$WFD_MODE" in
    intf) always "       1. mdata->wfd_mode = MDSS_MDP_WFD_INTERFACE  (the 'intf' branch of mdss_mdp.c)" ;;
    shared) always "       1. mdata->wfd_mode = MDSS_MDP_WFD_SHARED     (the default, and this tree says it)" ;;
    dedicated) always "       1. mdata->wfd_mode = MDSS_MDP_WFD_DEDICATED  (the 'dedicated' branch of mdss_mdp.c)" ;;
    *) always "       1. NOT one of intf / shared / dedicated, so mdss_mdp.c takes its default: SHARED" ;;
    esac
    case "$WFD_MODE" in
    shared) always "       2. mdss_mdp_parse_dt_wb(): NOT 'shared' is false, so num_intf_wb = 0 -- no interface"
            always "          writeback block is allocated, and every wb entry is a block wb" ;;
    *) always "       2. mdss_mdp_parse_dt_wb(): the value is not 'shared', so num_intf_wb = 1 -- ONE extra"
       always "          writeback entry is allocated and gets caps MDSS_MDP_WB_WFD | MDSS_MDP_WB_INTF" ;;
    esac
    ;;
  esac
  if [ -n "$MDP" ] && [ -d "$MDP" ]; then
    WOFF=$(dtu32s "$MDP/qcom,mdss-wb-off")
    MOFF=$(dtu32s "$MDP/qcom,mdss-mixer-wb-off")
    _nwoff=0; _nmoff=0
    case "$WOFF" in '' | absent | EMPTY | not-u32s*) : ;; *) set -- $WOFF; _nwoff=$# ;; esac
    case "$MOFF" in '' | absent | EMPTY | not-u32s*) : ;; *) set -- $MOFF; _nmoff=$# ;; esac
    N_NWB=$((_nmoff + N_INTF))
    always ""
    say "   ${MDP#/proc/device-tree}"
    say "     qcom,mdss-wb-off:        $WOFF"
    say "     qcom,mdss-mixer-wb-off:  $MOFF"
    say "                  the register offsets of the writeback blocks, on the mdp node. Their COUNT is"
    say "                  the property length (mdss_mdp_parse_dt_prop_len), which is why the probe prints"
    say "                  every cell rather than the first -- here the count IS the reading."
    node_driver_row qcom,mdss_mdp
    always ""
    always "   THREE COUNTS FROM THREE PLACES, AND THEY ARE NOT THE SAME NUMBER:"
    always "     qcom,mdss-wb-count      on the ROTATOR   = ${WBN:-NOT READ}   (the rotator's own blocks;"
    always "                                              mdss_rotator.c reads it and refuses to probe without"
    always "                                              it, and it must be <= ROT_MAX_HW_BLOCKS)"
    always "     qcom,mdss-mixer-wb-off  on THIS node    = $_nmoff cell(s) -> mdata->nmixers_wb, passed to"
    always "                                              mdss_mdp_wb_addr_setup() as num_block_wb"
    always "     qcom,mdss-wb-off        on THIS node    = $_nwoff cell(s) -> mdata->nwb_offsets"
    always "   AND A FOURTH THAT NO PROPERTY CARRIES -- IT IS DERIVED FROM THE STRING ABOVE:"
    always "     qcom,mdss-wfd-mode = $WFD_MODE -> num_intf_wb = $N_INTF"
    always ""
    always "   THE ARITHMETIC, because it is how the tree checks itself without knowing it:"
    always "     mdss_mdp_wb_addr_setup() allocates mdata->nwb = num_block_wb + num_intf_wb"
    always "                                            = $_nmoff + $N_INTF = $N_NWB entries"
    always "     and the tree's own qcom,mdss-wb-off has $_nwoff cell(s)."
    case "$_nwoff" in
    "$N_NWB")
      always "     THEY AGREE. That is the whole reading: qcom,mdss-wb-off names the offsets of the blocks"
      always "     that mdss_mdp_wb_addr_setup() allocates, and it agrees here ONLY BECAUSE the wfd-mode string"
      always "     is '$WFD_MODE' and not 'shared'. Flip that one string to 'shared' and num_intf_wb becomes 0,"
      always "     mdata->nwb becomes $_nmoff -- while the tree still lists $_nwoff offsets. Nothing in the driver"
      always "     compares the two, so that mismatch would be silent."
      ;;
    *)
      always "     THEY DO NOT AGREE ($_nwoff offsets against $N_NWB allocated blocks), and nothing in the"
      always "     driver compares them: mdss_mdp_parse_dt_wb() stores the length it read and never checks it"
      always "     against mdata->nwb. So this is a tree that describes a different number of writeback blocks"
      always "     than the driver would allocate for it -- a reading, not a crash."
      ;;
    esac
  fi
fi

# --- 5. the panel's own DT parameters, and the defaults behind them ---------------------------------
N_WB_FB=0
N_FB=0
WB_FB=""
SWITCH_DIR=/sys/class/switch/wfd
SWITCH_STATE=absent
if [ "$N_PANEL" != 0 ]; then
  hdr "the writeback panel's own parameters, and the defaults behind them"
  # Cleared before the loop: this is the verdict's evidence for the framebuffer rung, and a value left
  # over from an earlier node would make a later rung unreachable.
  FB_NODE=""
  for p in $PANEL_NODES; do
    always "   ${p#/proc/device-tree}"
    always "     qcom,mdss_pan_res:  $(pan_res "$p")"
    BPP=$(dtu32 "$p/qcom,mdss_pan_bpp")
    case "$BPP" in
    absent) always "     qcom,mdss_pan_bpp:  ABSENT -- the driver would use its own default, 24" ;;
    *) always "     qcom,mdss_pan_bpp:  $BPP   (the driver's own default is 24, so this matches it)" ;;
    esac
    always "                  These two are the ONLY properties mdss_wb_parse_dt() reads, and both have a"
    always "                  default in the driver instead of an error: a tree that forgot them gets a"
    always "                  1280x720 panel at 24bpp rather than a probe failure. mdss_wb_check_params()"
    always "                  refuses a resolution >= 4096 ('Invalid resolutions') at reconfiguration time."
    always "                  AND THE RESOLUTION IS READ AS EXACTLY TWO CELLS: of_property_read_u32_array()"
    always "                  asks for 2, so a LONGER property is read as a pair and the extra cells are"
    always "                  ignored, while a SHORTER one fails the read and the driver silently uses its"
    always "                  own 1280x720. Both directions are why every cell is printed here."
    # The framebuffer POINTER, and the failure that happens before anything runtime exists.
    FB_RAW=$(dtu32 "$p/qcom,mdss-fb-map")
    case "$FB_RAW" in
    absent) always "     qcom,mdss-fb-map:   ABSENT -- mdss_register_panel() reads this property from THIS node"
            always "                  and, without it, logs \"Unable to find fb node for device\" and returns"
            always "                  -ENODEV: no framebuffer device is created, and mdss_wb_probe()'s error"
            always "                  path unregisters the switch it just registered." ;;
    not-a-u32*) always "     qcom,mdss-fb-map:   $FB_RAW" ;;
    *)
      TGT=$(phandle_node "$FB_RAW")
      always "     qcom,mdss-fb-map:   phandle $FB_RAW -> ${TGT}"
      case "$TGT" in
      unresolved* | AMBIGUOUS* | '')
        always "                  the phandle did NOT resolve to exactly one node, which is the same failure"
        always "                  as an absent property: mdss_register_panel() gets no node, logs \"Unable to"
        always "                  find fb node for device\" and returns -ENODEV."
        ;;
      *)
        FB_NODE="$TGT"
        FB_C=$(dtlist "/proc/device-tree${TGT}/compatible")
        always "                  that node's compatible: $FB_C"
        case "$FB_C" in
        *qcom,mdss-fb*)
          always "                  it is a 'qcom,mdss-fb' node -- mdss_fb.c is the driver for it, and it is"
          always "                  shared by PRIMARY, SECONDARY, wfd and hdmi: the four children differ in"
          always "                  little but cell-index (0, 3, 1 and 2 respectively)."
          ;;
        *)
          always "                  NOT a 'qcom,mdss-fb' node: mdss_register_panel() would create a platform"
          always "                  device for it and no driver would take it, so no framebuffer would register."
          ;;
        esac
        always "                  cell-index: $(dtu32 "/proc/device-tree${TGT}/cell-index") -- and this does NOT"
        always "                              decide the /dev/fbN number; see the framebuffer section"
        node_driver_row "$(printf '%s' "$FB_C" | cut -d' ' -f1)"
        ;;
      esac
      ;;
    esac
  done
fi

# --- 6. the drivers --------------------------------------------------------------------------------
hdr "the drivers this block needs"
always "   $( [ -r /proc/config.gz ] && printf '%s: present' /proc/config.gz || printf '%s: MISSING' /proc/config.gz )"
if [ -n "$CFG_SRC" ]; then
  say "   source:          $CFG_SRC"
  always ""
  always "   the options that matter, per the kernel's own config:"
  always "     CONFIG_FB_MSM_MDSS                 $(cfg_opt CONFIG_FB_MSM_MDSS)"
  always "     CONFIG_FB_MSM_MDSS_WRITEBACK       $(cfg_opt CONFIG_FB_MSM_MDSS_WRITEBACK)"
  always "     CONFIG_FB_MSM_MDSS_COMMON          $(cfg_opt CONFIG_FB_MSM_MDSS_COMMON)"
  always "     CONFIG_DRM                         $(cfg_opt CONFIG_DRM)"
  always "   AND THE OPTION THAT IS NOT HERE: there is no CONFIG_MSM_ROTATOR and no CONFIG_FB_MSM_MDSS_WB in"
  always "   this kernel's Kconfig at all. mdss_rotator.c and mdss_fb.c are listed in drivers/video/msm/mdss/"
  always "   Makefile under mdss-mdp-objs / CONFIG_FB_MSM_MDSS, so the MDP's own option is what builds them --"
  always "   a reader who looked for a rotator option would find it missing from a kernel that builds it."
  always ""
  always "   THIS BLOCK'S DRIVER IS BUILT, and that is the reading that separates it from the two before it:"
  always "   the writeback panel's own option is set, so the rung below cannot be \"the kernel has no"
  always "   driver for this\" -- it can only be about binding, or about the phandle in section 5."
else
  always "   -- the kernel config could NOT be read: either the file is not there, or it is there and this"
  always "      device has neither zcat(1) nor gunzip(1) to expand it, or it could not be read at all. The"
  always "      config columns below are therefore NOT READ -- which is a third state, and not 'the option"
  always "      is off'. The driver directories in sysfs need no decompressor, so no verdict below rests on"
  always "      the config."
fi
always ""
always "   the driver directories themselves (a directory appears exactly when the driver registered):"
for _d in "platform mdss_wb" "platform mdss_fb" "platform mdss_rotator" "platform mdp"; do
  set -- $_d
  _dir="/sys/bus/$1/drivers/$2"
  if [ -d "$_dir" ]; then
    _b=$(drv_bound "$1" "$2")
    always "     $_dir: present, bound: $( [ -n "$_b" ] && printf '%s' "${_b# }" || printf 'NONE' )"
  else
    always "     $_dir: ABSENT (the driver did not register)"
  fi
done
always "   AND NOTE THE NAME OF THE LAST ONE: the MDP's platform driver is registered as \`mdp\`, not"
always "   \`mdss_mdp\` -- mdss_mdp.c says so in a comment above the driver struct (\"Driver name must match"
always "   the device name added in platform.c\"). The compatible is \`qcom,mdss_mdp\` and the DIRECTORY is"
always "   \`mdp\`, so \`mdss_mdp\` is a name that exists in the device tree, in the source file's name and"
always "   nowhere in sysfs."

# --- 7. the runtime traces the chain leaves behind --------------------------------------------------
hdr "the runtime traces this chain leaves behind"
# The switch. mdss_wb_dev_init() registers it BEFORE the framebuffer is looked up, and mdss_wb_probe()'s
# error path unregisters it again -- so its existence is an end-to-end witness, not a partial one.
if [ -d "$SWITCH_DIR" ]; then
  SWITCH_STATE=$(rd "$SWITCH_DIR/state")
  always "   $SWITCH_DIR: present"
  always "     name:      $(rd "$SWITCH_DIR/name")"
  always "     state:     $SWITCH_STATE"
  always "                  The switch device EXISTS, and on this chain that is an end-to-end reading:"
  always "                  mdss_wb_dev_init() registers it before the framebuffer is looked up, and the"
  always "                  probe's error path unregisters it if mdss_register_panel() fails -- so a present"
  always "                  switch means the panel's DT parsed, the fb phandle resolved, and the framebuffer"
  always "                  device was created."
  always "                  AND WRITING IT IS NOT A MOVE THIS PROBE CAN MAKE: the attribute is"
  always "                  DEVICE_ATTR(state, S_IRUGO, state_show, NULL) -- there is no store at all, so the"
  always "                  kernel refuses a shell write. The value is set only by switch_set_state(), from"
  always "                  mdss_mdp_wb_set_mirr_hint() -- i.e. by an MDP ioctl on the framebuffer device."
  always "                  A 0 here therefore means 'no mirror was ever asked for', and that is a statement"
  always "                  about the software path, not about the display hardware."
else
  always "   $SWITCH_DIR: ABSENT -- the writeback panel driver never registered its switch device."
  always "                  Because the switch is registered BEFORE the framebuffer lookup and removed again"
  always "                  on failure, an absent switch means the chain stopped at or before that point:"
  always "                  the driver did not bind, its DT did not parse, or the phandle in section 5 did"
  always "                  not resolve. The kernel log section below says which of those it was."
fi
always ""
# The framebuffer class, and which of its devices is the writeback one. It is found by the ATTRIBUTE the
# kernel itself would use -- `panel.type == WRITEBACK_PANEL`, which `msm_fb_type` prints -- and never by
# number or by name: the number is a registration order and the name is the panel's xres in hex.
for _fb in /sys/class/graphics/fb*; do
  [ -e "$_fb" ] || continue
  N_FB=$((N_FB + 1))
  _ty=$(rd "$_fb/msm_fb_type")
  _nm=$(rd "$_fb/name")
  always "   $(basename "$_fb")  name: $_nm   msm_fb_type: $_ty"
  # ONE PLACE DECIDES which framebuffer this is, and it is the TYPE -- the same thing the kernel reads.
  _iswb=no
  case "$_ty" in "writeback panel") _iswb=yes ;; esac
  case "$_iswb" in
  yes)
    N_WB_FB=$((N_WB_FB + 1))
    [ -z "$WB_FB" ] && WB_FB="$_fb"
    always "     THIS is the writeback framebuffer, and it is identified the way the KERNEL identifies it:"
    always "     msm_fb_get_writeback_fb() walks fbi_list looking for panel.type == WRITEBACK_PANEL, which"
    always "     is exactly what 'msm_fb_type: writeback panel' reports."
    always "     the mdss attributes it carries (all WRITABLE and left alone):"
    _w=""
    for _a in blank msm_fb_panel_status msm_fb_dfps_mode idle_time msm_fb_thermal_level disable_bl_scaling trigger_reset dsi_write; do
      [ -e "$_fb/$_a" ] && _w="$_w $_a"
    done
    always "      $_w"
    ;;
  *) : ;;
  esac
done
case "$N_FB" in
0) always "   /sys/class/graphics/fb*: no framebuffer device at all. The framebuffer CLASS is what mdss_fb"
   always "                  registers into, so no fbN means mdss_fb registered no device -- and the"
   always "                  writeback panel's framebuffer is one of them." ;;
*)
  always ""
  always "   $N_FB framebuffer device(s), $N_WB_FB of them reporting 'writeback panel'."
  if [ -n "$WB_FB" ]; then
    always "   The writeback one is $WB_FB -- identified by its TYPE, not by its number:"
    always "   mdss_fb numbers its devices from a registration counter (fbi_list[fbi_list_index++]), so"
    always "   /dev/fbN follows the order the panels registered in."
  fi
  always "   AND THE fb NAME IS NOT AN IDENTITY EITHER: mdss_fb.c builds it as fix->id = \"mdssfb_%x\" from"
  always "   (int *)&mfd->panel -- the FIRST field of struct mdss_panel_info, which is xres. So the name is"
  always "   the panel's horizontal resolution in hex, and two framebuffers of the same resolution carry the"
  always "   same name. On this board the writeback panel is 640 wide in the tree, which would name it"
  always "   mdssfb_280."
  ;;
esac

# --- 8. the kernel log, for this block --------------------------------------------------------------
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
  show "$LOG_TEXT" 'wfd|writeback|wb_panel|mdss_wb|mdss_fb|mdss_mdp|rotator|switch' \
    "(none: the kernel log mentions no writeback, mdss_fb or mdss driver this boot)" 25 1
  # The failure strings, taken from the sources rather than guessed. mdss_fb.c prints "Unable to find fb
  # node for device" and "Unable to find mdss for node"; mdss_wb.c prints "unable to register writeback
  # panel" and "unable to set up device nodes for writeback panel"; mdss_mdp.c warns "wfd mode not
  # configured."; mdss_rotator.c prints "Error in device tree" for a missing wb count.
  show "$LOG_TEXT" 'Unable to find fb node|Unable to find mdss for node|unable to register writeback panel|writeback panel|wfd mode not configured|wfd mode|Invalid resolutions|Error in device tree|probe .* failed|failed with error|no driver' \
    "(none: no writeback probe failure in this boot's log)" 20 1
  always ""
  always "   ONE LINE IN THIS LIST WOULD BE EXPECTED ON A TREE THAT LOST THE PROPERTY: mdss_mdp.c warns"
  always "   'wfd mode not configured. Set to default: Shared' when 'qcom,mdss-wfd-mode' is absent -- and"
  always "   this board's tree carries it, so that warning is evidence the tree the kernel read is not the"
  always "   tree this probe just read. It is named here so the two can be told apart."
fi

# --- verdict ---------------------------------------------------------------------------------------
# The rung the evidence reaches, named. Each rung is a different problem with a different next move, and
# the first two are a different BOARD and a different SEARCH.
if [ "$DT_RUNG" = unscanned ]; then
  V=tree-unscanned
  VMSG="the device tree could not be searched for this block's compatibles (no find(1), and no known node shape exists). Nothing about this board's writeback panel was read, so nothing here is a verdict about it."
elif [ "$BOARD" = x2 ]; then
  V=wrong-board-tree
  VMSG="this boot is running the LE_X2's device tree, not this phone's. Both boards declare the same writeback panel at the same path, so the tree's shape cannot tell them apart and only 'model' can -- nothing below is about the zl1. The next move is about which DTB the bootloader picked."
elif [ "$BOARD" = other ] || [ "$BOARD" = unknown ]; then
  V=unknown-board
  VMSG="the device tree's model names neither LE_ZL1 nor LE_X2 (read: $MODEL), so this reading cannot be attributed to this phone. The readings below stand on their own; the attribution does not."
elif [ "$DT_RUNG" = no-node ]; then
  V=no-device-tree-node
  VMSG="this device tree declares no node with 'qcom,mdss_wb': the writeback panel is not described at all, so the kernel creates no device for it and no driver can bind. That is a boot-image (device tree) fact, not a runtime fault -- and on this board the property is in all 15 of its trees, so this rung means the tree being read is not the tree this phone boots with."
elif [ "$N_PANEL_ENABLED" = 0 ]; then
  V=no-panel-enabled
  VMSG="the writeback panel node carries a status that is not okay, so the tree switches the block off by its own decision and the kernel creates no device for it. Note what this board's node actually carries: NO status property at all, which the device tree reads as ENABLED."
elif [ "$N_PANEL_WITH_DRIVER" = 0 ]; then
  V=no-driver-for-enabled-panel
  VMSG="the tree enables the writeback panel and NO driver in this kernel source matches 'qcom,mdss_wb': nothing can bind it under any config, so this is a property of the kernel SOURCE and not of a build option. (On the flashed zl1 kernel this cannot be the rung: CONFIG_FB_MSM_MDSS_WRITEBACK=y and mdss_wb.c is in the source.)"
elif [ "$N_PANEL_REGISTERED" = 0 ]; then
  V=driver-not-registered
  VMSG="the compatible matches a driver in this kernel source and that driver is not registered -- so the option that builds it is off in THIS kernel, which is a defconfig line and a boot-image build. Check the config column above before believing it: a config that could not be read prints NOT READ and is a different state."
elif [ "$N_PANEL_BOUND" = 0 ]; then
  V=driver-not-bound
  VMSG="the driver is registered and nothing is bound to the writeback panel, so its probe ran and failed -- or never ran. mdss_wb_probe() returns -ENODEV when the platform device has no device tree node, and its DT parse cannot fail, so the next move is the kernel log section below."
elif [ -z "${FB_NODE:-}" ]; then
  V=no-framebuffer
  VMSG="the panel node's 'qcom,mdss-fb-map' does not resolve to exactly one node, and mdss_register_panel() READS THAT PROPERTY FROM THE PANEL'S OWN NODE: without it, it logs 'Unable to find fb node for device' and returns -ENODEV. So no framebuffer device is created for this display and the probe's error path unregisters the switch again -- which is why this rung usually comes with an ABSENT /sys/class/switch/wfd."
elif [ ! -d "$SWITCH_DIR" ]; then
  V=no-writeback-switch
  VMSG="the driver is bound and the framebuffer pointer resolves, but the switch device that mdss_wb_dev_init() registers does not exist. Since dev_init runs BEFORE the framebuffer lookup and the failure path unregisters it, an absent switch means the chain stopped between binding and the end -- the kernel log section above says where."
elif [ "$N_WB_FB" = 0 ]; then
  V=no-writeback-fb
  VMSG="the switch exists (so mdss_register_panel() succeeded and a platform device was created for the framebuffer node) but no /sys/class/graphics/fbN reports 'writeback panel'. So that device's own probe did not complete -- which is a different move from the phandle, because the device was created."
else
  V=writeback-panel-registered
  VMSG="the writeback panel driver is bound, its switch device is registered, and $WB_FB reports 'writeback panel' -- so the whole chain from the device tree to a registered framebuffer is in place, and the readings below are readings rather than placeholders."
fi

always ""
always "== verdict: $V"
always "   $VMSG"

# The thing a verdict about this block must say out loud. On this board the chain is complete and the
# switch still reads 0, and those two facts are not in tension -- the second is what the first implies
# until something asks for a mirror.
if [ "$V" = writeback-panel-registered ]; then
  always ""
  always "   AND THE STATE READING IS STILL 0, WHICH IS NOT A FAULT. The switch is written only by"
  always "   switch_set_state(), reached from mdss_mdp_wb_set_mirr_hint() -- i.e. from an MDP ioctl on the"
  always "   framebuffer device, for MDP_WRITEBACK_MIRROR_{ON,PAUSE,RESUME,OFF}. Nothing has asked for a"
  always "   mirror on this boot unless something opened that device, so a 0 here says 'no mirror was"
  always "   requested', not 'the writeback engine is dead'. The probe does not ask for one: that call is"
  always "   the write-class move of this block, and it also emits a uevent."
fi

always ""
always "   WHAT THIS IS NOT: an answer to 'does screen mirroring work'. A bound panel driver, a registered"
always "   switch and a framebuffer of type 'writeback panel' are the software path being in place -- and"
always "   none of them is a mirrored picture, and none of them says the writeback engine's own registers"
always "   are healthy. This probe writes NOTHING at all (no framebuffer attribute, no switch write, not a"
always "   scratch file) and opens no device: it reads the tree, sysfs and the kernel's own config."

[ "$V" = writeback-panel-registered ] && exit 0
exit 1
