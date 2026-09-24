#!/bin/sh
# zl1 HDMI probe -- the six device-tree nodes that describe this board's HDMI output, which of them the
# tree enables, whether this kernel has a driver for them, and what the ONE driver that does match is
# actually given when it binds.
#
# Why this exists. doc 137 enumerated this board's hardware from its own device trees and named the blocks
# nothing in this tree reads; `hdmi` is one of them, and like `usb-pd` it is not one device. Five readings
# make this probe's design. They are the five below, and each is read by a section further down -- the
# numbering is the order they matter in, not the order the sections run:
#
#   1. TWO TRANSMITTER NODES CLAIM THE SAME MMIO WINDOW, AND ONLY ONE OF THEM HAS A DRIVER.
#      `/soc/qcom,hdmi_tx@9a0000` (`qcom,hdmi-tx`) and `/soc/qcom,sde_hdmi@9a0000` (`qcom,hdmi-tx-8996`,
#      `status = ok`) carry a BYTE-IDENTICAL `reg` (`<0x9A0000 0x50C 0x70000 0x6158 0x9E0000 0xFFF>`) and a
#      byte-identical `reg-names` (`core_physical`, `qfprom_physical`, `hdcp_physical`). They are two
#      GENERATIONS of the same block (the mdss/fb generation and the sde/drm one), the way the display
#      family puts `qcom,mdss_*` and `qcom,sde_*` on the same node -- except that here it is two nodes.
#      This kernel source has NO sde code at all (`qcom,sde-kms`, `qcom,hdmi-tx-8996` match nothing in it),
#      so the enabled node with the `ok` status is the one nothing can bind, and the node with no `status`
#      property at all (which the device tree reads as ENABLED) is the one that has a driver.
#   2. THAT ONE DRIVER ASKS FOR EIGHT NAMED GPIOS AND THE NODE IT BINDS CARRIES ONE.
#      mdss_hdmi_tx.c builds its gpio names as `"qcom,hdmi-tx" "-hpd"` etc., so it looks for
#      `qcom,hdmi-tx-{hpd,mux-en,mux-sel,mux-lpm,ddc-mux-sel,ddc-clk,ddc-data,cec}`. The node it binds
#      carries exactly `qcom,hdmi-tx-hpd`; the OTHER generation's node carries five of them spelled
#      `qcom,hdmi-tx-hpd-gpio`, `-ddc-clk-gpio`, `-ddc-data-gpio`, `-mux-en-gpio`, `-mux-sel-gpio` --
#      the driver's names with a `-gpio` suffix that `of_get_named_gpio` never asks for. The two nodes are
#      complementary halves of one description, and the half with the driver is the incomplete one.
#      A gpio `of_get_named_gpio` cannot find is NOT fatal: the loop `continue`s at DEV_DBG level.
#   3. THE PIN STATE LIST IS SHIFTED BY ONE, AND `hdmi_sleep` IS NOT THE SLEEPING STATE.
#      `pinctrl_dt_to_map` walks `pinctrl-%d` from 0 upward and pairs each with `pinctrl-names[i]` -- and
#      when the names run out, the state is named after its own index. This node has FOUR names
#      (`hdmi_hpd_active hdmi_ddc_active hdmi_active hdmi_sleep`) and FIVE properties, so "hdmi_active"
#      is `pinctrl-2` (hpd active + ddc SUSPEND), "hdmi_sleep" is `pinctrl-3` (hpd active + ddc ACTIVE),
#      and the genuinely suspended pin set (`pinctrl-4`, hpd_suspend + ddc_suspend) is reachable only by
#      the literal name `"4"`. The undrivable SDE node, whose list is the consistent one
#      (`default`/`sleep`, two names, two properties), carries the CEC pin state this node has no name for.
#   4. `connected` IS A VARIABLE, NOT A CABLE. The transmitter's sysfs group (`connected`, `hpd`, `edid`,
#      `video_mode`, ... 13 attributes) lives on the FRAMEBUFFER device -- it is created on
#      `MDSS_EVENT_FB_REGISTERED` -- and `connected`/`hpd` both read `hpd_state`, which is `false` unless
#      something armed HPD or wrote `hot_plug`, and is set back to `false` by `hdmi_tx_hpd_off()`.
#      HPD is armed at FB_REGISTERED only when `pdata->primary || !pdata->pluggable`, and this board's
#      transmitter is `qcom,pluggable` and is not primary -- so on this board `connected: 0` has more than
#      one producer and the probe names them instead of reading it as "no cable".
#      WHICH /dev/fbN IS THE HDMI ONE IS NOT DECIDED BY THE TREE: `mdss_fb` numbers its devices from a
#      registration counter (`fbi_list[fbi_list_index++]`), not from the node's `cell-index`
#      (primary 0, wfd 1, hdmi 2, secondary 3). The probe identifies the HDMI framebuffer by the
#      ATTRIBUTES it carries, never by its number.
#   5. THE BLOCK'S OWN SIX NODES ARE NOT ALL OF IT. The two audio codec-rx children
#      (`qcom,msm-hdmi-audio-codec-rx`) hang off the two transmitters, the DAI (`qcom,msm-dai-q6-hdmi`) is
#      what a PCM stream would route to, and the transmitter's framebuffer is named by a PHANDLE
#      (`qcom,mdss-fb-map` -> `qcom,mdss_fb_hdmi`, `cell-index` 2) rather than by a path. A probe that
#      looked only for `hdmi` in the compatible strings would miss the framebuffer; one that assumed a
#      path would miss a node that moved.
#
# WHAT THIS CANNOT SAY: whether HDMI works. A bound transmitter is not a working port: HPD has to arm,
# the cable has to be seen, EDID has to be read over DDC, and none of that is decided by a device tree.
# And it does not say the port is broken, either -- on this board the missing DDC/mux gpios are non-fatal,
# and whether the same pins are muxed by the `mdss_hdmi_ddc_active` pin state instead is a question for a
# scope, not for sysfs.
#
# **Read-only, and it writes nothing at all** -- not even a scratch file, which is why the kernel log is
# captured into a shell variable. Every knob in sight is named and left alone, and this block has more of
# them than most:
#   * the free framebuffer attributes: `dsi_write`, `trigger_reset`, `msm_fb_panel_status`,
#     `msm_fb_thermal_level`, `msm_fb_dfps_mode`, `disable_bl_scaling`, `idle_time`, `msm_fb_split`, and
#     the standard `blank` -- all `S_IWUSR`, and `dsi_write`/`trigger_reset` on a fb the compositor is
#     scanning out is a visible, state-changing action;
#   * the transmitter's own group: `hot_plug`, `hpd`, `edid`, `sim_mode`, `hdmi_audio_cb`,
#     `vendor_name`, `product_description`, `avi_itc`, `avi_cn0_1`, `s3d_mode`, `5v` -- writing `hpd` or
#     `hot_plug` CHANGES the port's state, and every one of them is a knob the kernel exposes on purpose;
#   * and the whole display pipeline behind them, which is why "run it once and see" is a separate,
#     reviewed step and not a side effect of taking a reading.
#
# Usage (on the device):
#   sh zl1-hdmi-probe.sh             # every rung, then a verdict
#   sh zl1-hdmi-probe.sh --quiet     # the verdict and the readings it rests on
#   sh zl1-hdmi-probe.sh --explain   # what each reading decides, and why this reading
#
# Exit: 0 the transmitter an enabled node needs is registered and bound, so the port readings are readings;
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
# Every string of a property, not just the first: a compatible list, `reg-names` and `pinctrl-names` are
# LISTS, and reading only the first entry is how a property looks like it does not carry the entry you
# want.
dtlist() { # $1 = path
  if [ ! -r "$1" ]; then printf 'absent'; return; fi
  v=$(tr '\0' '\n' < "$1" 2>/dev/null | grep . | LC_ALL=C tr -c '[:print:]\n' '.' | tr '\n' ' ')
  printf '%s' "${v:-EMPTY}"
}
# A device-tree u32 is BIG-ENDIAN and this SoC is little-endian, so `od -tu4` on the file prints the value
# BYTE-SWAPPED -- an address of 0x9A0000 comes out as a number of the right shape and the wrong value.
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
# EVERY cell of a property, as decimal numbers separated by spaces, or a named reason why not. `reg` is
# an array of cells whose length is the point (six cells for a transmitter, two for an i2c address), and
# reading only the first one is how a `<0x9A0000 0x50C> <0x70000 0x6158> <0x9E0000 0xFFF>` window looks
# like a single address.
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
# A NUMBER as hex, for the ones a datasheet or a memory map is written in. `printf '%x'` is not used: a
# 64-bit register base (4200246704) overflows what a one-word shell printf can print, and a hex that is
# wrong for the large numbers is worse than none. `awk` is used instead, and a non-number prints nothing.
hexv() { # $1 = value
  case "$1" in
  '' | *[!0-9]*) printf '' ;;
  *) awk -v n="$1" 'BEGIN { printf "0x%x", n }' ;;
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
  # The known node shapes for a kernel without find(1). This block's nodes sit under the SoC node, under
  # the mdss_mdp node, under i2c controllers and under the display-manager, so the fallback walks the
  # shapes rather than a list -- a node that moved one level is exactly what this scan exists to survive.
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
# Resolve a phandle to the node that carries it. A GPIO is `<&tlmm 60 0>` and `qcom,mdss-fb-map` is a
# phandle to the framebuffer node, and the phandle is the only thing saying WHICH node that is -- printing
# the raw number would leave the reader to guess. A phandle can be carried by more than one node in a
# hand-built tree, so an ambiguous answer says so rather than picking one. But the SAME node can carry the
# same phandle TWICE -- as `phandle` and as the older `linux,phandle`, which this board's pinctrl
# controller and every mdss node does -- and counting matches rather than nodes would call that one node
# ambiguous with itself.
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
# The GPIO cells of a property, RESOLVED: `<&tlmm 61 4 0>` prints as
# "phandle 28 = /soc/pinctrl@01010000, gpio 61, active high". Three cells is the shape on this board; a
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
# How many `pinctrl-N` properties a node has, walked the SAME way the pinctrl core walks them: from 0
# upward until one is missing. It is a count rather than a list because the reading this block needs is
# the MISMATCH between that count and the number of `pinctrl-names` entries -- and a name-less state is
# reachable only by its index, which is a fact about the count.
pinctrl_count() { # $1 = node dir; prints the number of pinctrl-N properties present
  _pc_i=0
  while [ -e "$1/pinctrl-$_pc_i" ]; do _pc_i=$((_pc_i + 1)); done
  printf '%s' "$_pc_i"
}
# The driver that MATCHES a compatible, straight out of the kernel source -- each line is
# "driver-name<TAB>config-option<TAB>source-file<TAB>bus<TAB>how-it-matches". A compatible with no match
# prints `none`, which is a reading (a node nothing can bind) and not an error.
#
# TWO THINGS ABOUT THIS BLOCK'S MATCHING ARE WORTH SPELLING OUT.
#   * `qcom,hdmi-display` and `qcom,hdmi-tx-8996` match NOTHING in this kernel source. The SDE generation
#     (`sde_kms`, `sde_dsi_ctrl*`, `sde_dsi_phy*`, `sde_hdmi`) is in the device tree and has no code in a
#     3.18 kernel at all, so `status = "ok"` on one of those nodes is a tree asking for a driver that does
#     not exist in this generation -- not a driver that failed to load.
#   * `qcom,mdss_hdmi_pll_8996_v3_1p8` is ONE OF FOUR HDMI PLL spellings mdss-pll.c accepts (`_8996`,
#     `_v2`, `_v3`, `_v3_1p8`), and which one a board has is decided by the tree. The driver then picks
#     its PLL interface TYPE from the string, so all four are listed rather than the one this phone has.
#   * a THIRD HDMI driver exists in this kernel source -- drivers/gpu/drm/msm/hdmi, the upstream DRM one --
#     and it matches `qcom,hdmi-tx-8074`, `-8960` and `-8660`: three older SoCs, and nothing this board
#     carries. `CONFIG_DRM` is not set in the flashed kernel either. It is named in the report so that
#     "there is no HDMI driver" cannot be read as true of the source when what is true of the source is
#     "no driver for THESE nodes".
drivers_for() { # $1 = compatible
  case "$1" in
  qcom,hdmi-tx)
    printf 'mdss_hdmi_tx\tCONFIG_FB_MSM_MDSS_HDMI_PANEL\tdrivers/video/msm/mdss/mdss_hdmi_tx.c\tplatform\tby of_match "qcom,hdmi-tx" (the mdss/fb generation)\n'
    ;;
  qcom,hdmi-tx-8996)
    printf 'none\t-\t-\t-\t-\n'
    ;;
  qcom,hdmi-display)
    printf 'none\t-\t-\t-\t-\n'
    ;;
  qcom,mdss_hdmi_pll_8996_v3_1p8 | qcom,mdss_hdmi_pll_8996_v3 | qcom,mdss_hdmi_pll_8996_v2 | qcom,mdss_hdmi_pll_8996)
    printf 'mdss_pll\tCONFIG_MSM_MDSS_PLL\tdrivers/clk/msm/mdss/mdss-pll.c\tplatform\tby of_match "%s"\n' "$1"
    ;;
  qcom,mdss-fb)
    printf 'mdss_fb\tCONFIG_FB_MSM_MDSS\tdrivers/video/msm/mdss/mdss_fb.c\tplatform\tby of_match "qcom,mdss-fb" (shared by primary, secondary, wfd and hdmi)\n'
    ;;
  qcom,msm-hdmi-audio-codec-rx)
    printf 'msm_hdmi_codec_rx\tCONFIG_SND_SOC_MSM_HDMI_CODEC_RX\tsound/soc/codecs/msm_hdmi_codec_rx.c\tplatform\tby of_match "qcom,msm-hdmi-audio-codec-rx"\n'
    ;;
  qcom,msm-dai-q6-hdmi)
    printf 'msm-dai-q6-hdmi\tCONFIG_SND_SOC_QDSP6V2\tsound/soc/msm/qdsp6v2/msm-dai-q6-hdmi-v2.c\tplatform\tby of_match "qcom,msm-dai-q6-hdmi"\n'
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
zl1 HDMI probe -- what each reading decides, and why it is this reading

  1. WHICH BOARD'S DEVICE TREE IS RUNNING (model, not compatible).
     The flashed boot image's appended blob carries 28 device trees: 5 for the LE_ZL1 and 23 for the
     LE_X2, a different phone, under a byte-identical root `compatible`. Both boards' trees carry an HDMI
     transmitter at the same path, so the tree's SHAPE cannot tell you whose reading this is; only
     `model` can. On the X2's tree every reading below is about the other phone's display output.

  2. THE NODES, AND WHICH OF THEM THE TREE ENABLES.
     This board declares six: two transmitters (`qcom,hdmi-tx` and `qcom,hdmi-tx-8996`, one per driver
     generation, claiming the SAME MMIO window), one display (`qcom,hdmi-display`, cell type secondary),
     one PLL, and two audio codec-rx children. For each the probe prints the path -- SCANNED for, never
     assumed -- the compatible list, the `status` (naming an ABSENT status as enabled, because that is
     what an absent status means), the `reg` in every cell AND as hex, the interrupt and its resolved
     parent, the clocks, and the pin state names.

  3. WHETHER THE KERNEL HAS A DRIVER FOR AN ENABLED NODE, AND THE TWO ANSWERS THAT ARE NOT THE SAME.
     "Matches nothing in this kernel source" and "matches, but the option that builds it is off" are two
     different problems: the first is a node no config change can help, the second is a line in a
     defconfig. Both are asked, per node, and both are asked of the DEVICE as well -- whether the driver
     directory exists in /sys/bus/platform/drivers and whether anything is bound to it.

  4. WHAT THE ONE MATCHING DRIVER IS GIVEN WHEN IT BINDS.
     This is the part no other probe of this block would do, and it needs the SOURCE: mdss_hdmi_tx.c
     builds its gpio names as "qcom,hdmi-tx" + a suffix, and it looks up five pin states BY NAME. So the
     probe carries the eight gpio names and the five state names out of the driver and asks the TREE for
     each one, per node. On this board that comparison is the reading: the node the driver binds has one
     of the eight, the node with five of them is spelled with a suffix the driver never asks for, and the
     pin-state list is shifted by one so that "hdmi_sleep" is not the sleeping pin set.

  5. THE PORT READINGS, AND WHY `connected: 0` NEEDS A PRODUCER NAMED.
     The transmitter's sysfs group lives on the FRAMEBUFFER device (it is created on
     MDSS_EVENT_FB_REGISTERED), and `connected`/`hpd` read `hpd_state` -- a variable that something has to
     write. So the probe reads the framebuffer the transmitter points at (through the `qcom,mdss-fb-map`
     PHANDLE, not a path), reports which /sys/class/graphics/fbN carries the transmitter's attributes
     (by ATTRIBUTE, never by number: mdss_fb numbers its devices from a registration counter, not from
     the tree's cell-index), and says out loud that a `0` there is not a statement about the cable until
     something is shown to have armed HPD. And it names what could have armed it: the HPD interrupt, a
     write to the `hot_plug` attribute, or the arm-up at FB_REGISTERED -- which the driver performs only
     when `pdata->primary || !pdata->pluggable`, and this board's transmitter is `qcom,pluggable` and is
     not primary. So on THIS board that arm-up does not happen, and the `0` has fewer producers than it
     would on a board whose HDMI node is primary.

  WHAT THIS CANNOT SAY: that HDMI works, or that it does not. A bound transmitter, a registered
  framebuffer and an armed HPD are all prerequisites, and none of them is a picture on a screen. And the
  missing DDC/mux gpios are non-fatal -- the driver `continue`s past a gpio it cannot find -- so "one of
  eight" is a reading about what the driver was GIVEN, not a proven dead DDC line. This probe writes
  nothing: not the framebuffer attributes (dsi_write, trigger_reset, blank ...), not the transmitter's
  own group (hot_plug, hpd, edid ...), and it opens no device.
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
  always "               the X2's. Unlike the USB-C block, BOTH boards declare an HDMI transmitter at the"
  always "               same path -- so the tree's shape cannot tell you whose reading this is, and every"
  always "               reading below is about the other phone's display output."
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
hdr "the HDMI nodes the device tree declares"
# Every compatible this block is known to use. The scan is per-compatible so that "which compatible is
# present" is a reading rather than a path guess, and the PLL is listed in all four spellings because the
# driver accepts all four and a board carries exactly one.
CANDS="qcom,hdmi-tx qcom,hdmi-tx-8996 qcom,hdmi-display qcom,mdss_hdmi_pll_8996_v3_1p8 qcom,mdss_hdmi_pll_8996_v3 qcom,mdss_hdmi_pll_8996_v2 qcom,mdss_hdmi_pll_8996 qcom,msm-hdmi-audio-codec-rx qcom,msm-dai-q6-hdmi"
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
  always "   the device tree could not be searched for the HDMI compatibles at all: find(1) is missing AND"
  always "   no known node shape exists. This is NOT 'the tree declares no HDMI' -- it is 'this probe could"
  always "   not look', and the two must not print the same way."
else
  if [ -z "$NODES" ]; then
    DT_RUNG=no-node
    always ""
    always "   no node in this device tree carries any of the compatibles this block uses"
    always "   -- the running tree declares no HDMI output at all. The paths are not assumed: the whole"
    always "     tree is scanned for each compatible."
  else
    DT_RUNG=node
    always ""
  fi
fi

# The window audit: two transmitters, one MMIO window. Collected while the nodes are read, printed once,
# because the reading is about the PAIR -- a table of one node's `reg` cannot show that another node claims
# the same addresses.
if [ "$DT_RUNG" = node ]; then
  TX_NODES=""
  N_ENABLED=0
  N_TX=0
  N_TX_ENABLED=0
  N_TX_ENABLED_WITH_DRIVER=0
  N_TX_ENABLED_REGISTERED=0
  N_TX_ENABLED_BOUND=0
  N_MATCHABLE=0
  TX_REG_MDSS=""
  TX_REG_SDE=""
  for p in $NODES; do
    C=$(dtstr "$p/compatible")
    ST=$(dtstr "$p/status")
    # AN ABSENT `status` IS ENABLED, and this block is where that matters: the node the driver binds
    # (`qcom,hdmi-tx`) carries no `status` property at all, while the node that cannot be bound
    # (`qcom,hdmi-tx-8996`) is the one that says `ok`. So the absent case has to be in the ENABLED branch
    # -- a probe that read it as "not okay" would report this board's only drivable transmitter as
    # disabled, and would then report the undrivable one as the enabled node.
    case "$ST" in okay | ok | EMPTY | absent) EN=yes ;; *) EN=no ;; esac
    # A node with no `status` is ENABLED (that is what the device tree means by an absent status), which
    # is why `absent` is in the enabled branch above and why the print below names the absence.
    case "$ST" in
    absent) ST_SHOW="absent (an absent status means enabled; this node carries none)" ;;
    *) ST_SHOW="$ST" ;;
    esac
    [ "$EN" = yes ] && N_ENABLED=$((N_ENABLED + 1))
    case "$C" in
    qcom,hdmi-tx | qcom,hdmi-tx-8996)
      N_TX=$((N_TX + 1))
      TX_NODES="$TX_NODES $p"
      [ "$EN" = yes ] && N_TX_ENABLED=$((N_TX_ENABLED + 1))
      ;;
    esac
    always ""
    always "   ${p#/proc/device-tree}"
    say "     compatible:  $(dtlist "$p/compatible")"
    always "     status:      $ST_SHOW  ($([ "$EN" = yes ] && echo 'the kernel will create this device' || echo 'DISABLED: the kernel creates no device for it, and no driver can bind at all'))"
    REGS=$(dtu32s "$p/reg")
    case "$REGS" in
    absent) say "     reg:         absent (no register window -- this node is a description, not a device)" ;;
    not-u32s*) say "     reg:         $REGS" ;;
    *)
      say "     reg:         $REGS"
      say "                  $(printf '%s' "$REGS" | awk '{printf "hex:"; for (i = 1; i <= NF; i++) printf " 0x%x", $i; print ""}')"
      # The window's identity is the CELLS, not the count: two nodes with the same cells claim the same
      # addresses, and a count would match two nodes that only happen to have the same shape. Kept per
      # transmitter so the comparison can be printed once, as a fact about the PAIR.
      case "$C" in
      qcom,hdmi-tx) TX_REG_MDSS="$REGS" ;;
      qcom,hdmi-tx-8996) TX_REG_SDE="$REGS" ;;
      esac
      ;;
    esac
    RN=$(dtlist "$p/reg-names")
    [ "$RN" != absent ] && say "     reg-names:   $RN"
    _ip=$(dtcell "$p/interrupt-parent" 1)
    INTS=$(dtu32s "$p/interrupts")
    case "$INTS" in
    absent) say "     interrupts:  absent$( [ "$_ip" != absent ] && printf '   interrupt-parent: %s = %s' "$_ip" "$(phandle_node "$_ip")" )" ;;
    not-u32s*) say "     interrupts:  $INTS" ;;
    *)
      case "$_ip" in
      '' | absent) say "     interrupts:  $INTS   interrupt-parent: ${_ip:-absent} (nothing to resolve)" ;;
      *) say "     interrupts:  $INTS   interrupt-parent: $_ip = $(phandle_node "$_ip")" ;;
      esac
      ;;
    esac
    CL=$(dtlist "$p/clock-names")
    [ "$CL" != absent ] && say "     clocks:      $CL"
    say "     pinctrl:     names='$(dtlist "$p/pinctrl-names")'   pinctrl-N properties: $(pinctrl_count "$p")"
    # Every property whose name this block's driver would ask for, printed by NAME and by RESOLVED cells:
    # the gpio audit in section 4 is the comparison, and this is the raw material it compares against. A
    # GLOB is used rather than a directory listing so that no extra tool is needed to read a directory of
    # device-tree properties -- and a glob that matches nothing yields its own pattern, which `-e` rejects.
    _gp_any=0
    for _gp in "$p"/qcom,hdmi-tx-*; do
      [ -e "$_gp" ] || continue
      [ -d "$_gp" ] && continue
      _gp_any=1
      say "     $(printf '%-32s' "$(basename "$_gp")") $(gpio_cells "$_gp")"
    done
    [ "$_gp_any" = 1 ] || say "     (no qcom,hdmi-tx-* property on this node at all)"
    # The drivers that could bind this node, and the two device-side answers about each.
    DLIST=$(drivers_for "$C")
    case "$DLIST" in
    none*) always "     drivers:     NONE in this kernel source matches '$C' -- nothing can ever bind it, under any config" ;;
    *)
      N_MATCHABLE=$((N_MATCHABLE + 1))
      case "$C" in
      qcom,hdmi-tx | qcom,hdmi-tx-8996) [ "$EN" = yes ] && N_TX_ENABLED_WITH_DRIVER=$((N_TX_ENABLED_WITH_DRIVER + 1)) ;;
      esac
      # `drivers_for` prints TAB-separated fields, and a default IFS would split EVERY FIELD into its own
      # word -- so the loop would read `mdss_hdmi_tx`, then `CONFIG_FB_MSM_MDSS_HDMI_PANEL`, then the source
      # path, and treat each as a driver name. IFS is newline-only for the duration of the loop, and each
      # line's fields are cut with `cut -f`, whose separator is a tab. (A `while read` pipeline is the other
      # way to do this and is WRONG here: it runs in a subshell, so the counters below would be incremented
      # and then thrown away with it.)
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
        case "$C" in
        qcom,hdmi-tx | qcom,hdmi-tx-8996)
          [ "$EN" = yes ] && [ "$R" = yes ] && N_TX_ENABLED_REGISTERED=$((N_TX_ENABLED_REGISTERED + 1))
          [ "$EN" = yes ] && [ "$R" = yes ] && [ -n "$B" ] && N_TX_ENABLED_BOUND=$((N_TX_ENABLED_BOUND + 1))
          ;;
        esac
      done
      IFS=$_oldifs
      ;;
    esac
  done
  always ""
  always "   $N_ENABLED of $N_NODES node(s) are ENABLED by this tree, and $N_MATCHABLE of them have a driver"
  always "   somewhere in this kernel source. Of the $N_TX transmitter node(s), $N_TX_ENABLED are ENABLED --"
  always "   and the two questions after that are asked one node at a time, so they are counted:"
  always "     $N_TX_ENABLED_WITH_DRIVER of $N_TX_ENABLED enabled node(s) MATCH a driver in this kernel source"
  always "     $N_TX_ENABLED_REGISTERED of those have that driver REGISTERED in this boot"
  always "     $N_TX_ENABLED_BOUND of those have it BOUND to the device"
fi

# The window, printed as its own finding because it is about the PAIR, and printed as a COMPARISON rather
# than as two `reg` lines a reader has to compare by eye.
if [ "$DT_RUNG" = node ] && [ "$N_TX" -gt 1 ]; then
  always ""
  always "   THE WINDOW: a tree that puts two driver generations on the SAME node puts them on TWO nodes"
  always "   here -- \`qcom,hdmi-tx\` (the mdss/fb generation) and \`qcom,hdmi-tx-8996\` (the sde generation) --"
  always "   and only one of those generations has any code in this kernel."
  if [ -n "$TX_REG_MDSS" ] && [ -n "$TX_REG_SDE" ] && [ "$TX_REG_MDSS" = "$TX_REG_SDE" ]; then
    always "   Both carry the SAME reg cells, so both claim this board's HDMI register window:"
    always "     $TX_REG_MDSS"
    always "   A node that is enabled and claims the same addresses as the node that binds is not a fault and"
    always "   not a duplicate the kernel resolves: it is a description for a driver this kernel generation"
    always "   does not have."
  elif [ -n "$TX_REG_MDSS" ] && [ -n "$TX_REG_SDE" ]; then
    always "   They do NOT carry the same reg cells, so they claim different windows:"
    always "     qcom,hdmi-tx      : $TX_REG_MDSS"
    always "     qcom,hdmi-tx-8996 : $TX_REG_SDE"
  else
    always "   Only one transmitter node is present in this tree, so there is no pair to compare."
  fi
fi

# --- 4. the gpio audit: what the driver asks for, against what each transmitter carries --------------
#
# The names come out of the SOURCE, not out of this probe's opinion: mdss_hdmi_tx.c builds each name as
# `"qcom,hdmi-tx" "<suffix>"`, from three lists -- hpd (hpd, mux-en, mux-sel, mux-lpm), ddc
# (ddc-mux-sel, ddc-clk, ddc-data) and cec (cec). Eight names, and a gpio the driver cannot find is
# skipped with a DEV_DBG, so the audit's consequence is "silently absent lines", not "probe failed".
if [ "$DT_RUNG" = node ] && [ "$N_TX" -gt 0 ]; then
  hdr "the gpios the transmitter driver asks for, against what each transmitter node carries"
  always "   from mdss_hdmi_tx.c: hpd_gpio_config / ddc_gpio_config / cec_gpio_config, each name built as"
  always "   COMPATIBLE_NAME (\"qcom,hdmi-tx\") + a suffix. of_get_named_gpio() looks the WHOLE name up, and a"
  always "   name it cannot find is skipped -- so a property spelled with an extra suffix is, to this driver,"
  always "   a gpio that is not there. Each name is therefore printed with what EACH transmitter node answers."
  # One name per block rather than a padded table: the answers are long (a resolved gpio is a phandle, a
  # controller path and a polarity), and a table whose columns overflow reads as if the two nodes agreed.
  # The four counters are the paragraph below: what each node carries under the driver's OWN spelling, and
  # what it carries only under the other generation's `-gpio` spelling -- counted, not asserted, because a
  # sentence with a number in it that nothing measures is a sentence that goes stale on the next board.
  N_MDSS_HAVE=0; N_SDE_HAVE=0; N_SDE_ALT=0; N_MDSS_ALT=0
  for _sfx in -hpd -mux-en -mux-sel -mux-lpm -ddc-mux-sel -ddc-clk -ddc-data -cec; do
    always ""
    always "   the driver asks for:  qcom,hdmi-tx$_sfx"
    for _p in $TX_NODES; do
      _c=$(dtstr "$_p/compatible")
      case "$_c" in
      qcom,hdmi-tx) _which="mdss node" ;;
      qcom,hdmi-tx-8996) _which="sde node " ;;
      *) continue ;;
      esac
      _val=$(gpio_cells "$_p/qcom,hdmi-tx$_sfx")
      # The other spelling: the same name with `-gpio` appended, which is how the sde generation's node
      # writes it. Printed where the driver's name is missing, because that is the reading.
      case "$_val" in
      absent)
        _alt=$(gpio_cells "$_p/qcom,hdmi-tx$_sfx-gpio")
        case "$_alt" in
        absent) _val="absent -- and absent as 'qcom,hdmi-tx$_sfx-gpio' too" ;;
        *)
          _val="absent, but PRESENT as 'qcom,hdmi-tx$_sfx-gpio': $_alt"
          case "$_which" in
          "mdss node") N_MDSS_ALT=$((N_MDSS_ALT + 1)) ;;
          *) N_SDE_ALT=$((N_SDE_ALT + 1)) ;;
          esac
          ;;
        esac
        ;;
      *)
        case "$_which" in
        "mdss node") N_MDSS_HAVE=$((N_MDSS_HAVE + 1)) ;;
        *) N_SDE_HAVE=$((N_SDE_HAVE + 1)) ;;
        esac
        ;;
      esac
      always "     $_which: $_val"
    done
  done
  always ""
  always "   COUNTED, not asserted: the mdss node carries $N_MDSS_HAVE of these eight names as the driver"
  always "   spells them and $N_MDSS_ALT more only under the other generation's '-gpio' spelling; the sde node"
  always "   carries $N_SDE_HAVE as the driver spells them and $N_SDE_ALT more only as '-gpio'."
  always ""
  always "   THE READING IS THE PAIR. The node the driver BINDS is the one with the driver code in this kernel"
  always "   and the one that is missing most of what the driver asks for; the node that carries the rest is a"
  always "   node no driver in this kernel can bind, and it spells them with a \`-gpio\` suffix the driver never"
  always "   asks for. The two are complementary halves of one description. A missing gpio is NOT fatal (the"
  always "   driver skips it), so this is a reading about what the driver was GIVEN, not a proof that DDC"
  always "   cannot work: the DDC pins may also be muxed by the \`mdss_hdmi_ddc_active\` pin state, which is a"
  always "   question for a scope and not for sysfs."
fi

# --- 5. the pinctrl audit: five states looked up by name, and a list shifted by one -----------------
if [ "$DT_RUNG" = node ] && [ "$N_TX" -gt 0 ]; then
  hdr "the pin states the driver looks up by NAME, and what this tree calls them"
  always "   from mdss_hdmi_tx.c: hdmi_tx_pinctrl_init() looks up 'hdmi_active', 'hdmi_hpd_active',"
  always "   'hdmi_cec_active', 'hdmi_ddc_active' and 'hdmi_sleep'. pinctrl_dt_to_map() pairs pinctrl-names[i]"
  always "   with pinctrl-i, and when the names run out it names the state after its own INDEX -- so a node"
  always "   with more pinctrl-N properties than names has states whose number is not their name."
  for _p in $TX_NODES; do
    _names=$(dtlist "$_p/pinctrl-names")
    _cnt=$(pinctrl_count "$_p")
    always ""
    always "   ${_p#/proc/device-tree}"
    case "$_names" in
    absent) always "     pinctrl-names: (the node has no pinctrl-names property at all)" ;;
    *) always "     pinctrl-names: $(printf '%s' "$_names")" ;;
    esac
    if [ "$_cnt" = 0 ]; then
      always "     pinctrl-N: none of pinctrl-0, pinctrl-1, ... is on this node -- so no state can be"
      always "                selected on it, whatever the names say"
    else
      _nn=0
      case "$_names" in absent) _nn=0 ;; *) _nn=$(printf '%s' "$_names" | wc -w | tr -d ' ') ;; esac
      always "     pinctrl-0..$((_cnt - 1)): $((_cnt)) propert$([ "$_cnt" = 1 ] && echo y || echo ies), $_nn name(s)"
      [ "$_nn" -ge "$_cnt" ] || always "                  THE NAMES RUN OUT $((_cnt - _nn)) STATE(S) EARLY: pinctrl-names[i] names pinctrl-i, and a"
      [ "$_nn" -ge "$_cnt" ] || always "                  state past the last name is reachable only by its own index as a STRING."
    fi
    _i=0
    while [ "$_i" -lt "$_cnt" ]; do
      _nm=$(printf '%s\n' "$_names" | cut -d' ' -f$((_i + 1)))
      [ -z "$_nm" ] && _nm="\"$_i\" (no pinctrl-names entry: this state is named after its index)"
      _cells=$(dtu32s "$_p/pinctrl-$_i")
      _resolved=""
      for _cell in $_cells; do
        case "$_cell" in '' | *[!0-9]*) continue ;; esac
        _resolved="$_resolved $(basename "$(phandle_node "$_cell")")"
      done
      always "     pinctrl-$_i  =$_resolved   <- state name: $_nm"
      _i=$((_i + 1))
    done
    # The comparison that matters: the driver's five names against this node's names.
    _missing=""
    for _want in hdmi_active hdmi_hpd_active hdmi_cec_active hdmi_ddc_active hdmi_sleep; do
      case " $_names " in *" $_want "*) ;; *) _missing="$_missing $_want" ;; esac
    done
    if [ -n "$_missing" ]; then
      always "     the driver looks up these and this node does not name them:$_missing"
    else
      always "     the driver's five state names are all present on this node"
    fi
  done
  always ""
  always "   A STATE WHOSE NAME IS NOT ITS PINS. On this board the mdss node has FOUR names and FIVE"
  always "   properties, so 'hdmi_active' is pinctrl-2 (hpd active + ddc SUSPEND), 'hdmi_sleep' is pinctrl-3"
  always "   (hpd active + ddc ACTIVE), and the pin set that is actually suspended (pinctrl-4) is reachable"
  always "   only by the literal name \"4\". The sde node -- the one with no driver -- has the consistent list."
  always "   What this probe CANNOT say is what that costs on a board: the mapping is a fact about the tree,"
  always "   and whether a sleeping HDMI transmitter with its HPD pin still driven matters is a question for"
  always "   a scope."
fi

# --- 6. the drivers this KERNEL has -----------------------------------------------------------------
hdr "the HDMI drivers this kernel has"
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
for o in CONFIG_FB_MSM_MDSS CONFIG_FB_MSM_MDSS_HDMI_PANEL CONFIG_FB_MSM_MDSS_WRITEBACK CONFIG_MSM_MDSS_PLL CONFIG_SND_SOC_MSM_HDMI_CODEC_RX CONFIG_SND_SOC_QDSP6V2 CONFIG_DRM CONFIG_DRM_MSM; do
  always "     $(printf '%-34s' "$o") $(cfg_opt "$o")"
done
always ""
always "   (a THIRD HDMI driver is in this kernel source and is not a candidate for this board:"
always "    drivers/gpu/drm/msm/hdmi matches 'qcom,hdmi-tx-8074', '-8960' and '-8660' -- three older SoCs."
always "    CONFIG_DRM is not set here either. Naming it is what keeps 'there is no HDMI driver' from being"
always "    read as a fact about the source, when the fact is 'no driver for THESE nodes'.)"
always ""
always "   the driver directories themselves (a directory appears exactly when the driver registered):"
for d in "platform mdss_hdmi_tx" "platform mdss_pll" "platform mdss_fb" "platform msm_hdmi_codec_rx" "platform msm-dai-q6-hdmi"; do
  set -- $d
  BUS=$1; DN=$2
  if [ -d "/sys/bus/$BUS/drivers/$DN" ]; then
    B=$(drv_bound "$BUS" "$DN")
    always "     /sys/bus/$BUS/drivers/$DN: present, bound:${B:- NONE}"
  else
    say "     /sys/bus/$BUS/drivers/$DN: ABSENT (the driver did not register)"
  fi
done

# --- 7. the framebuffer the transmitter points at ---------------------------------------------------
#
# This section reads the transmitter's OWN fb pointer -- `qcom,mdss-fb-map`, a phandle to
# `/soc/qcom,mdss_mdp@900000/qcom,mdss_fb_hdmi` on this board -- and then asks the DEVICE whether that
# framebuffer exists. It is deliberately not a scan for `mdss-fb` nodes: primary, secondary, wfd and hdmi
# all carry `qcom,mdss-fb`, and the one that belongs to this block is the one THIS node points at.
hdr "the framebuffer this block's transmitter points at"
FB_MAP_NODE=""
if [ "$DT_RUNG" = node ] && [ "$N_TX" -gt 0 ]; then
  _tx_win=""
  for _p in $TX_NODES; do
    _c=$(dtstr "$_p/compatible")
    case "$_c" in qcom,hdmi-tx) _tx_win="$_p" ;; esac
  done
  if [ -z "$_tx_win" ]; then
    always "   no 'qcom,hdmi-tx' node in this tree, so there is no node to read 'qcom,mdss-fb-map' from"
  else
    always "   from: ${_tx_win#/proc/device-tree}   property: qcom,mdss-fb-map"
    _ph=$(dtcell "$_tx_win/qcom,mdss-fb-map" 1)
    case "$_ph" in
    absent) always "     the property is not there -- mdss_fb_register() reads it (mdss_fb.c) and returns -ENODEV"
            always "     with 'Unable to find fb node for device' when neither it nor a get_fb_node() hook yields a"
            always "     node, so this is the reading that decides whether the HDMI display gets a framebuffer."
            ;;
    *)
      FB_MAP_NODE=$(phandle_node "$_ph")
      always "     phandle $_ph -> $FB_MAP_NODE"
      case "$FB_MAP_NODE" in
      unresolved | AMBIGUOUS* | *no\ find*)
        always "     the phandle did NOT resolve to exactly one node, so which framebuffer this display gets"
        always "     cannot be read from here."
        FB_MAP_NODE=""
        ;;
      *)
        _fbc=$(dtlist "/proc/device-tree$FB_MAP_NODE/compatible")
        always "     that node's compatible: $_fbc"
        case " $_fbc " in
        *" qcom,mdss-fb "*) always "     it is a 'qcom,mdss-fb' node -- mdss_fb.c is the driver for it, and it is shared by primary,"
                            always "     secondary, wfd and hdmi: cell-index on this board is 0, 3, 1 and 2 respectively." ;;
        *) always "     it is NOT a 'qcom,mdss-fb' node, so the driver the transmitter expects to own its framebuffer"
           always "     is not the driver for what the tree points at." ;;
        esac
        _ci=$(dtu32 "/proc/device-tree$FB_MAP_NODE/cell-index")
        [ "$_ci" != absent ] && always "     cell-index: $_ci -- and this does NOT decide /dev/fbN. mdss_fb numbers its devices from"
        [ "$_ci" != absent ] && always "                  a registration counter (fbi_list[fbi_list_index++]), so the fb number follows"
        [ "$_ci" != absent ] && always "                  the order the framebuffers registered in."
        _devname=$(basename "$FB_MAP_NODE")
        if [ -e "/sys/bus/platform/devices/$_devname" ]; then
          always "     /sys/bus/platform/devices/$_devname: present (the mdss_fb driver created the device)"
        else
          always "     /sys/bus/platform/devices/$_devname: ABSENT (nothing created this framebuffer device)"
        fi
        ;;
      esac
      ;;
    esac
  fi
fi
# The framebuffer CLASS, and which of its devices carries the transmitter's own attributes. The group is
# created on MDSS_EVENT_FB_REGISTERED, so its presence is evidence the display got that far, and it is
# found by ATTRIBUTE -- never by number, because the number is a registration order.
N_FB=0
N_FB_HDMI=0
HDMI_FB=""
for _fb in /sys/class/graphics/fb*; do
  [ -e "$_fb" ] || continue
  N_FB=$((N_FB + 1))
  _attrs=""
  for _a in connected hpd edid video_mode hot_plug sim_mode; do
    [ -e "$_fb/$_a" ] && _attrs="$_attrs $_a"
  done
  case "$_attrs" in
  *" connected "*)
    N_FB_HDMI=$((N_FB_HDMI + 1))
    [ -z "$HDMI_FB" ] && HDMI_FB="$_fb"
    ;;
  esac
  always ""
  always "   $(basename "$_fb")  name: $(rd "$_fb/name")"
  if [ -n "$_attrs" ]; then
    always "     the HDMI transmitter's attributes are here:$_attrs"
    # `connected` and `hpd` read hpd_state, and the probe names what could have written it. `sim_mode` is
    # printed beside them because it is the only readable attribute that reports `hpd_feature_on` -- i.e.
    # whether the HPD feature was EVER armed -- and arming it is what makes the other two meaningful.
    if [ -e "$_fb/connected" ]; then
      always "     connected: $(san "$(rd "$_fb/connected")")   hpd: $(san "$(rd "$_fb/hpd")")   sim_mode: $(san "$(rd "$_fb/sim_mode")")"
      always "                 (sim_mode reads hpd_feature_on, i.e. whether HPD was ever armed; see below)"
    fi
    if [ -e "$_fb/edid" ]; then
      _edid=$(rd "$_fb/edid")
      _elen=$(printf '%s' "$_edid" | wc -c | tr -d ' ')
      always "     edid: $(printf '%s' "$_elen") byte(s) reported by the driver's own attribute (the probe does not"
      always "           write it, and does not read a monitor's EEPROM through anything else)"
    fi
    _wr=""
    for _a in hpd hot_plug edid sim_mode hdmi_audio_cb vendor_name product_description avi_itc avi_cn0_1 s3d_mode 5v; do
      [ -e "$_fb/$_a" ] && _wr="$_wr $_a"
    done
    always "     WRITABLE and left alone:$_wr   (writing hpd or hot_plug CHANGES the port's state)"
  else
    say "     (no HDMI transmitter attribute here -- this is some other framebuffer)"
  fi
done
if [ "$N_FB" = 0 ]; then
  always "   /sys/class/graphics/fb*: no framebuffer device at all. The framebuffer CLASS is what mdss_fb"
  always "   registers into, so no fbN means no mdss_fb device registered -- and the transmitter's sysfs"
  always "   group (connected, edid, ...) is created on that device, so it cannot exist either."
else
  always ""
  always "   $N_FB framebuffer device(s), $N_FB_HDMI of them carrying the HDMI transmitter's attributes."
  if [ "$N_FB_HDMI" != 0 ]; then
    always "   The HDMI one is $HDMI_FB -- identified by its ATTRIBUTES, not by its number:"
    always "   mdss_fb numbers its devices from a registration counter, not from the tree's cell-index."
    always ""
    always "   AND 'connected: 0' IS NOT A STATEMENT ABOUT THE CABLE. connected and hpd both read hpd_state,"
    always "   a variable that is false unless something wrote it: the HPD interrupt (armed only while HPD is"
    always "   on and initialized), or a write to the hot_plug attribute -- a write-class move this probe does"
    always "   not make. hdmi_tx_hpd_off() sets it back to false on power-off, and HPD is armed at"
    always "   MDSS_EVENT_FB_REGISTERED only when (primary || !pluggable) -- and this board's transmitter is"
    always "   qcom,pluggable and is not primary, so that arm-up does not happen for it. So a 0 here has more"
    always "   than one producer, and 'no cable' is only one of them."
  else
    always "   NONE of them carries the transmitter's attributes, which is the reading that the display never"
    always "   got as far as MDSS_EVENT_FB_REGISTERED -- the transmitter's sysfs group is created on that"
    always "   event, so its absence is about the path, not about the monitor."
  fi
fi

# --- 8. the kernel log -----------------------------------------------------------------------------
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
  show "$LOG_TEXT" 'hdmi|mdss_fb|mdss_mdp|sde_kms|msm_hdmi|edid|hpd' \
    "(none: the kernel log mentions no HDMI, mdss_fb or mdss driver this boot)" 25 1
  # The failure strings, taken from the sources rather than guessed. mdss_hdmi_tx.c prints
  # "Unable to read qcom,display-id" (a property NO zl1 tree carries -- an error line on this board that
  # is not a fault), "failed to get pinctrl", "cannot get ... pinstate" (pr_debug), and gpio_request
  # failures; mdss_fb.c prints "Unable to find fb node for device" and "Unable to find mdss for node";
  # and the mdss core prints the display/panel registration failures below.
  show "$LOG_TEXT" 'Unable to read qcom,display-id|Unable to find fb node|Unable to find mdss for node|failed to get pinctrl|cannot get .* pinstate|gpio_request failed|no gpio named|Failed to register|probe .* failed|no driver|failed with error' \
    "(none: no HDMI probe failure in this boot's log)" 20 1
  always ""
  always "   ONE LINE IN THIS LIST IS EXPECTED ON THIS BOARD: mdss_hdmi_tx.c reads 'qcom,display-id' and"
  always "   logs an error when it is missing -- and NO zl1 device tree carries that property anywhere. So"
  always "   that error is a reading about a property the driver asks for and this board never had, not a"
  always "   fault. It is named here so that the next reader of this log does not chase it."
fi

# --- verdict ---------------------------------------------------------------------------------------
# The rung the evidence reaches, named. Each rung is a different problem with a different next move, and
# the first two are a different BOARD and a different SEARCH.
if [ "$DT_RUNG" = unscanned ]; then
  V=tree-unscanned
  VMSG="the device tree could not be searched for the HDMI compatibles (no find(1), and no known node shape exists). Nothing about this board's HDMI output was read, so nothing here is a verdict about it."
elif [ "$BOARD" = x2 ]; then
  V=wrong-board-tree
  VMSG="this boot is running the LE_X2's device tree, not this phone's. Both boards declare an HDMI transmitter at the same path, so the tree's shape cannot tell them apart and only 'model' can -- nothing below is about the zl1. The next move is about which DTB the bootloader picked, not about the display output."
elif [ "$BOARD" = other ] || [ "$BOARD" = unknown ]; then
  V=unknown-board
  VMSG="the device tree's model names neither LE_ZL1 nor LE_X2 (read: $MODEL), so this reading cannot be attributed to this phone. The readings below stand on their own; the attribution does not."
elif [ "$DT_RUNG" = no-node ]; then
  V=no-device-tree-node
  VMSG="this device tree declares no HDMI node at all, so there is nothing for a transmitter driver to bind to. This block's nodes are in all 15 of this board's trees in all three sets, so a missing node means the tree that booted is not one of them."
elif [ "$N_TX_ENABLED" = 0 ]; then
  V=no-transmitter-enabled
  VMSG="both transmitter nodes in this tree have a status that is not okay, so the tree picks no HDMI output and the kernel creates no device for either. Whatever the port does, it does without a transmitter driver by the device tree's own decision."
elif [ "$N_TX_ENABLED_WITH_DRIVER" = 0 ]; then
  V=no-driver-for-enabled-transmitter
  VMSG="the device tree ENABLES $N_TX_ENABLED transmitter node(s) and NO driver in this kernel source matches the compatible they carry: nothing can bind them under any config, so this is a property of the kernel GENERATION and not of a build option."
  if [ "$N_MATCHABLE" != "$N_NODES" ]; then
    VMSG="$VMSG $N_MATCHABLE of $N_NODES node(s) in this block have a driver somewhere in this kernel source; the other $((N_NODES - N_MATCHABLE)) have none."
  fi
elif [ "$N_TX_ENABLED_REGISTERED" = 0 ]; then
  V=driver-not-registered
  VMSG="an enabled transmitter's compatible DOES match a driver in this kernel source, and that driver has not registered -- so this is a BUILD option (the config column above names which one), not a missing driver. The next move is in a defconfig, and it needs a boot-image build."
elif [ "$N_TX_ENABLED_BOUND" = 0 ]; then
  V=driver-not-bound
  VMSG="the driver is registered and nothing is bound to it, so its probe ran and failed -- or never ran. The next move is the probe: the gpio and pin-state audits above are what the driver asks the tree for, and the log section says what it said when it asked."
elif [ -z "$FB_MAP_NODE" ]; then
  V=no-framebuffer
  VMSG="the transmitter's driver is bound, but the framebuffer this display is supposed to register into could not be read: either 'qcom,mdss-fb-map' is not on the transmitter node, or its phandle does not resolve to exactly one node. mdss_fb_register() reads that property and returns -ENODEV without it, so a bound transmitter with no framebuffer is a display with nowhere to draw."
elif [ "$N_FB_HDMI" = 0 ]; then
  V=transmitter-not-attached-to-fb
  VMSG="the transmitter's driver is bound and its framebuffer node resolves, but no /sys/class/graphics/fbN carries the transmitter's own attributes -- and those attributes are created on MDSS_EVENT_FB_REGISTERED. So the path stopped between 'a transmitter driver is running' and 'the display registered its framebuffer'."
else
  V=transmitter-bound
  VMSG="the transmitter's driver is registered and bound, its framebuffer node resolves, and $HDMI_FB carries the transmitter's attributes -- so the display got as far as MDSS_EVENT_FB_REGISTERED and this block's protocol readings (connected, hpd, edid, video_mode) are readings rather than placeholders. What they SAY still depends on what is plugged into the port."
fi

always ""
always "== verdict: $V"
always "   $VMSG"

# The thing a verdict about this block must say out loud, and the reason it is a separate paragraph: on
# this board the tree and the kernel agree about the wrong node, and the gpio audit is one of eight.
if [ "$DT_RUNG" = node ] && [ "$N_TX_ENABLED_BOUND" != 0 ]; then
  always ""
  always "   THE TRANSMITTER IS BOUND AND ITS PORT READINGS ARE STILL NOT THE WHOLE STORY. The node it bound"
  always "   gives it one of the eight gpios it asks for, the other generation's node holds five of the rest"
  always "   with a spelling the driver never asks for, and the pin-state list on the bound node is shifted"
  always "   by one so that 'hdmi_sleep' resolves to the ACTIVE pin set. None of those stops a probe from"
  always "   succeeding -- a gpio the driver cannot find is skipped, not fatal -- which is exactly why they"
  always "   are worth reading out: a boot where HDMI half-works will look, from the log, like a boot where"
  always "   nothing went wrong."
fi

always ""
always "   WHAT THIS IS NOT: an answer to 'does the HDMI port work'. A bound transmitter with an armed HPD is"
always "   a prerequisite and not a picture on a screen, and a 'connected: 0' is a variable until something is"
always "   shown to have armed HPD. This probe writes nothing -- not the framebuffer attributes (dsi_write,"
always "   trigger_reset, blank ...), not the transmitter's own group (hot_plug, hpd, edid ...) -- and opens"
always "   no device: it reads the tree, sysfs and the kernel's own config."

case "$V" in
transmitter-bound) exit 0 ;;
*) exit 1 ;;
esac
