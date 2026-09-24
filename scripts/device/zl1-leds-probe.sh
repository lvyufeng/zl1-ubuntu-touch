#!/bin/sh
# zl1 LEDs probe -- the notification/charging RGB LED, the camera torch/flash, and the button backlight.
#
# Why this exists. doc 137 enumerated this board's hardware from its own device trees and found that
# twelve of twenty-nine blocks are read by nothing in this tree. doc 138 closed the first (thermal-lmh,
# the hardware thermal limiter, on a phone whose user asks for the overheating to be fixed). This probe
# closes two more, and they are two of the three the user actually touches: **the notification LED** and
# **the camera torch**. Neither had ever been read here.
#
# The device tree says exactly what should exist, so the probe can compare a DECLARATION against a
# REGISTRATION -- which is a real reading with a real failure mode, not a guess. From the four PMIC LED
# nodes, taken from the DTBs (not invented):
#
#   /soc/qcom,spmi@400f000/qcom,pm8994@0/qcom,leds@a100      qcom,leds-qpnp
#       qcom,led_mpp_2   linux,name = "button-backlight"      <- the capacitive key backlight
#   /soc/qcom,spmi@400f000/qcom,pmi8994@3/qcom,leds@d000     qcom,leds-qpnp      label = "rgb"
#       qcom,rgb_0/1/2   linux,name = "red" / "green" / "blue"  qcom,use-blink     <- the notification LED
#   /soc/qcom,spmi@400f000/qcom,pmi8994@3/qcom,leds@d300     qcom,qpnp-flash-led label = "flash"
#       qcom,flash_0/1   qcom,led-name = "led:flash_0" / "led:flash_1"
#       qcom,torch_0/1   qcom,led-name = "led:torch_0" / "led:torch_1"
#       qcom,switch      qcom,led-name = "led:switch"
#   /soc/qcom,spmi@400f000/qcom,pmi8994@3/qcom,leds@d800     qcom,qpnp-wled      linux,name = "wled"
#       linux,default-trigger = "bkl-trigger"                 <- the display backlight (docs 137's `backlight` row)
#   /soc/qcom,camera-flash                                   qcom,camera-flash   label = "leds-lm3643"
#       qcom,flash-source / qcom,torch-source                 <- the CONSUMER: it names the phandles of
#                                                                flash_0/1 and torch_0/1 above
#
# Three separate drivers on two separate buses, and that is the reason the verdict reads rungs rather than
# one flag: `qcom,leds-qpnp`, `qcom,qpnp-flash-led` and `qcom,qpnp-wled` are **SPMI** drivers (they appear
# under /sys/bus/spmi/drivers/), while `qcom,camera-flash` is a **platform** driver from the camera stack
# (drivers/media/platform/msm/camera_v2/sensor/flash/msm_flash.c). Any one of them can fail to register
# while the others come up. All three are built in: LEDS_CLASS=y, LEDS_QPNP=y, LEDS_QPNP_FLASH=y,
# LEDS_QPNP_WLED=y in lineage_zl1_defconfig.
#
# The driver-side surface is taken from the sources as well, because it is what tells the entries apart
# without guessing: leds-qpnp.c registers an `led_classdev` per DT child and adds `blink`, `rgb_blink`,
# `on_off_ms`, `rgb_start`, `lut_flags`, `duty_pcts`, `start_idx`, `ramp_step_ms`, `pwm_us`, `led_mode`;
# leds-qpnp-flash.c adds `strobe`, `reg_dump`, `max_allowed_current`, `enable_current_derate`,
# `enable_die_temp_current_derate`. So "which driver owns this entry" is answerable from the attributes
# that are actually present.
#
# **What this probe deliberately does NOT do: it does not light anything.** Writing to `brightness` or to
# `strobe` is a write, and every sibling probe in this tree is read-only, so the torch test is a separate,
# reviewed step and not a side effect of taking a reading. The consequence is stated in the verdict: an LED
# at brightness 0 is NOT evidence of a fault -- an idle phone has its notification LED off -- and the only
# thing here that IS evidence about a driver is whether its entry exists in the class at all.
#
# **Read-only, and it writes nothing at all** -- not even a scratch file, which is why the kernel log is
# captured into a shell variable rather than a temp file.
#
# Usage (on the device):
#   sh zl1-leds-probe.sh              # every rung, then a verdict
#   sh zl1-leds-probe.sh --quiet      # verdict and the readings it rests on
#   sh zl1-leds-probe.sh --explain    # what each reading decides, and why this reading
#
# Exit: 0 every declared LED name is registered (whatever its brightness);
#       1 the reading chain stops early -- the verdict names the rung;
#       2 not the zl1, or this kernel has no LED class at all.

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

# `say` carries the readings, `always` the two things a reader must see whether or not they asked for the
# readings: WHICH boot this is and the verdict itself.
say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
hdr() { printf '\n== %s\n' "$*"; }
always() { printf '%s\n' "$*"; }

# The device guard, the same one its siblings use: msm8996 and not `model`, because a probe that ran on the
# wrong phone would read a different SoC's LEDs and report them as this board's.
grep -qa msm8996 /proc/device-tree/compatible 2>/dev/null ||
  { echo "not the zl1 (no msm8996 in /proc/device-tree/compatible) -- refusing" >&2; exit 2; }

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
# Print the lines of TEXT that match an ERE, or a named "(none: ...)" line -- never nothing.
# NOT `grep ... | sed ... || say none`: in a pipeline the `||` applies to the LAST command and `sed`
# succeeds on empty input, so the none-branch would never fire. This repo has had to fix that shape in
# several instruments (docs 120 section 5, docs 136).
show() { # $1 = text, $2 = ERE, $3 = the "(none: ...)" text, $4 = tail -n, $5 = 1 to print under --quiet
  [ "$QUIET" = 1 ] && [ "${5:-0}" != 1 ] && return 0
  out=$(printf '%s\n' "$1" | grep -aiE -- "$2" 2>/dev/null | tail -n "${4:-15}")
  if [ -n "$out" ]; then printf '%s\n' "$out" | sed 's/^/   | /'; else printf '   | %s\n' "$3"; fi
}

if [ "$MODE" = explain ]; then
  cat <<'EOF'
zl1 LEDs probe -- what each reading decides, and why it is this reading

  1. THE DEVICE TREE'S DECLARATION, found by glob and not assumed.
     Five nodes carry an LED-ish compatible on this board: the PM8994 MPP (button backlight), the PMI8994
     RGB (notification LED), the PMI8994 flash (torch/flash), the PMI8994 WLED (display backlight), and
     /soc/qcom,camera-flash (the camera stack's consumer). Each child's `linux,name` or `qcom,led-name` is
     printed as the LED core will register it, so what follows is a comparison of a DECLARATION with a
     REGISTRATION rather than a story about what should be there. `status` is printed for each node for the
     same reason doc 137 exists: a node can be present and switched off, and the stock and rebuilt device
     trees do not describe the same board.

  2. THE DECLARED-VS-REGISTERED TABLE.
     Every name the device tree declares, and whether /sys/class/leds has an entry by that name. This is the
     one reading here that is evidence about a DRIVER: a missing entry means that driver did not register
     (or the node was disabled, or its probe failed -- the log section says which).

  3. THE LED CLASS, entry by entry: brightness, max_brightness, the current and available triggers, and the
     driver-specific attributes that ARE present. Those attributes identify the driver without guessing,
     because they come from the sources: `rgb_blink`/`on_off_ms`/`lut_flags` belong to leds-qpnp.c,
     `reg_dump`/`max_allowed_current` to leds-qpnp-flash.c, `bkl-trigger` on `wled` to leds-qpnp-wled.c.

  4. THE DRIVERS, on BOTH buses. `qcom,leds-qpnp`, `qcom,qpnp-flash-led` and `qcom,qpnp-wled` are SPMI
     drivers, so they appear under /sys/bus/spmi/drivers/; `qcom,camera-flash` is a platform driver from
     the camera stack. The probe globs every bus rather than naming one, because naming one is how a whole
     driver family becomes invisible -- which is exactly the mistake doc 137 found in the thermal readers.

  5. THE KERNEL LOG, filtered to the LED drivers. They dev_err on failure ("Unable to register led",
     "Unable to read flash name", "Unable to read trigger name"), so the log is where a registration that
     did not happen says why. It is reported as a named absence if it cannot be read, and it is NOT a rung:
     unlike thermal-lmh, where the sensor count came out of the log, no reading here depends on it.

  WHAT THIS CANNOT SAY. Brightness 0 is not a fault: an idle phone's notification LED and torch are off, so
  "all zeros" and "nobody ever drove these" are the same reading. What IS evidence is whether an entry
  exists, what its max_brightness says the hardware allows, and what its trigger currently claims. Whether
  the LED lights needs a write, and this probe does not write -- that is the torch test, a separate step.
EOF
  exit 0
fi

# --- who am I reading ------------------------------------------------------------------------------
hdr "this boot"
always "   boot id:    $(rd /proc/sys/kernel/random/boot_id)"
always "   uptime:     $(cut -d' ' -f1 /proc/uptime 2>/dev/null)s"
say "   kernel:     $(rd /proc/version)"

# --- 1. the device tree's declaration --------------------------------------------------------------
hdr "the device tree's declaration"
# Globbed, both under the SPMI controllers and at the top of /soc. `/proc/device-tree/*leds*` would not find
# the PMIC children (they are under spmi@400f000/qcom,pm*/), and a single deep glob would miss a future
# node that moved -- so all three shapes are searched and the union is what is reported.
DT_NODES=""
for n in /proc/device-tree/soc/qcom,spmi@*/*/qcom,*leds* /proc/device-tree/soc/*leds* \
  /proc/device-tree/soc/*camera-flash* /proc/device-tree/*leds*; do
  [ -e "$n" ] || continue
  case " $DT_NODES " in *" $n "*) continue ;; esac
  DT_NODES="$DT_NODES $n"
done
DECLARED=""
DT_RUNG=node
if [ -z "$DT_NODES" ]; then
  always "   no *leds* / *camera-flash* node under /proc/device-tree -- the running device tree declares no LEDs"
  DT_RUNG=no-node
  DT_COUNT=0
else
  DT_COUNT=0
  for n in $DT_NODES; do
    DT_COUNT=$((DT_COUNT + 1))
    always "   node:  ${n#/proc/device-tree}"
    say "     compatible:  $(dtstr "$n/compatible")   status: $(dtstr "$n/status")"
    say "     label:       $(dtstr "$n/label")"
    say "     default-trigger: $(dtstr "$n/linux,default-trigger")"
    # The name can be declared on the NODE or on a CHILD, and this board does both: the WLED node carries
    # `linux,name = "wled"` itself (its LED is the node), while every PMIC LED and flash channel is a child
    # (`qcom,rgb_0`, `qcom,flash_0`, ...). Reading only one of the two shapes would silently drop a whole
    # node from the comparison and make its absence unmissable-by-construction -- so both are read.
    NNAME=$(dtstr "$n/linux,name"); QNAME=$(dtstr "$n/qcom,led-name")
    case "$NNAME" in absent) ;; *) DECLARED="$DECLARED $NNAME"; say "     node name:   linux,name = $NNAME" ;; esac
    case "$QNAME" in absent) ;; *) DECLARED="$DECLARED $QNAME"; say "     node name:   qcom,led-name = $QNAME" ;; esac
    # Each child may declare its name one of two ways, and these drivers use both: the LED core is
    # registered with `linux,name` by leds-qpnp.c/leds-qpnp-wled.c and with `qcom,led-name` by
    # leds-qpnp-flash.c. Both are collected, because collecting only one would make a whole driver's entries
    # look undeclared.
    for c in "$n"/*; do
      [ -d "$c" ] || continue
      lname=$(dtstr "$c/linux,name")
      qname=$(dtstr "$c/qcom,led-name")
      case "$lname" in absent) ;; *) DECLARED="$DECLARED $lname"; say "     child $(basename "$c"):  linux,name = $lname" ;; esac
      case "$qname" in absent) ;; *) DECLARED="$DECLARED $qname"; say "     child $(basename "$c"):  qcom,led-name = $qname" ;; esac
    done
  done
fi
DECLARED=$(printf '%s\n' $DECLARED 2>/dev/null | grep . | sort -u | tr '\n' ' ')
DECLARED=${DECLARED% }
say "   declared LED name(s): ${DECLARED:-none}"
say "   (the camera flash CONSUMER names the PMIC sources by phandle; the LED entries it will use are the"
say "    led:torch_* / led:flash_* names above, which is why the two blocks are read together)"

# --- 2. the LED class, and the declared-vs-registered comparison ------------------------------------
hdr "the LED class (/sys/class/leds)"
LED_DIR=/sys/class/leds
ENTRIES=""
if [ -d "$LED_DIR" ]; then
  for d in "$LED_DIR"/*; do
    [ -e "$d" ] || continue
    ENTRIES="$ENTRIES $(basename "$d")"
  done
fi
ENTRIES=${ENTRIES# }
if [ -z "$ENTRIES" ]; then
  always "   $LED_DIR: $( [ -d "$LED_DIR" ] && echo 'present but EMPTY' || echo 'MISSING' )"
  always "   -- no LED driver has registered anything. On this kernel that is not a config gap"
  always "   (LEDS_CLASS=y and the three QPNP LED drivers are =y in lineage_zl1_defconfig), so the"
  always "   binding is what to look at: the section below shows which drivers are registered and what"
  always "   is attached to them."
  LED_COUNT=0
else
  LED_COUNT=$(printf '%s\n' $ENTRIES | grep -c .)
  always "   $LED_COUNT entr$([ "$LED_COUNT" = 1 ] && echo y || echo ies):$ENTRIES"
  for d in "$LED_DIR"/*; do
    [ -e "$d" ] || continue
    n=$(basename "$d")
    # `max_brightness`, not `brightness`: it is what the driver says the hardware allows, and it is present
    # whenever the classdev registered, so a 0 there is a reading and an absent file is a driver fact.
    # The trigger is printed as the CURRENT one (the bracketed entry) rather than the whole list, which is
    # a page of available triggers per entry.
    br=$(rd "$d/brightness"); mb=$(rd "$d/max_brightness")
    cur=$(rd "$d/trigger")
    case "$cur" in UNREADABLE | EMPTY) ;; *) cur=$(printf '%s\n' "$cur" | sed -e 's/.*\[//' -e 's/\].*//' | sed -n 1p) ;; esac
    say "     $(printf '%-20s' "$n") brightness=$br max_brightness=$mb trigger=${cur:-UNREADABLE}"
    # The driver-specific attributes that ARE there. This is the identification, and it is a list of what was
    # found rather than a claim about which driver made it: `rgb_blink`/`on_off_ms`/`lut_flags` come from
    # leds-qpnp.c, `reg_dump`/`max_allowed_current` from leds-qpnp-flash.c.
    ATTRS=""
    for a in blink rgb_blink on_off_ms rgb_start lut_flags duty_pcts start_idx ramp_step_ms pwm_us \
      led_mode strobe reg_dump max_allowed_current enable_current_derate enable_die_temp_current_derate \
      dump_regs dim_mode fs_curr_ua start_ramp ramp_ms ramp_step; do
      [ -e "$d/$a" ] && ATTRS="$ATTRS $a"
    done
    say "       attrs:${ATTRS:- none (a plain LED classdev)}"
  done
fi

# --- 3. the drivers, on every bus ----------------------------------------------------------------
hdr "the LED drivers"
DRVS=""
for d in /sys/bus/*/drivers/*led* /sys/bus/*/drivers/*flash*; do
  [ -e "$d" ] || continue
  case " $DRVS " in *" $d "*) continue ;; esac
  DRVS="$DRVS $d"
done
DRV_COUNT=0
if [ -z "$DRVS" ]; then
  always "   no *led* / *flash* driver registered on any bus"
else
  for d in $DRVS; do
    DRV_COUNT=$((DRV_COUNT + 1))
    # Pure-shell derivation, not `dirname`: the probe runs as /bin/sh on the device, and a reading that
    # silently becomes EMPTY because a helper was missing is the failure mode this tree keeps recording.
    bus=${d%%/drivers/*}; bus=${bus##*/}
    B=""
    for b in "$d"/*; do
      [ -e "$b" ] || continue
      case "$(basename "$b")" in bind | unbind | uevent | module) continue ;; esac
      B="$B $(basename "$b")"
    done
    say "     $(printf '%-28s' "$(basename "$d")") bus=$bus bound:${B:- NONE}"
  done
fi
say "   (a driver directory appears as soon as the module registers; a BOUND DEVICE is the symlink inside"
say "    it. The two are different facts, and only the second means a node was probed.)"

# --- 4. the kernel log -----------------------------------------------------------------------------
hdr "the kernel log, for the LED drivers"
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
  always "   -- so this section is NOT READ. No verdict below rests on it: unlike the thermal limiter, whose"
  always "   sensor count only exists in the log, every reading this probe decides on is a file."
  show "" x "(not read: the kernel log could not be read)" 1 1
  LOG_STATE=unread
else
  always "   source:          $LOG_SRC"
  show "$LOG_TEXT" 'led|LED|flash|torch|lm3643|wled|qpnp_led' \
    "(none: the kernel log mentions no LED driver this boot)" 20
  show "$LOG_TEXT" 'Unable to register led|Unable to read (flash|trigger) name|led.*probe.*fail' \
    "(none: no LED registration failure in this boot's log)" 10
  LOG_STATE=read
fi

# --- 5. the comparison, which is the reading that decides ------------------------------------------
hdr "declared, and registered"
MISSING=""
PRESENT=0
for name in $DECLARED; do
  if [ -e "$LED_DIR/$name" ]; then
    PRESENT=$((PRESENT + 1))
    say "     $(printf '%-20s' "$name") registered"
  else
    MISSING="$MISSING $name"
    always "     $(printf '%-20s' "$name") NOT in $LED_DIR"
  fi
done
MISSING=${MISSING# }
if [ -z "$DECLARED" ]; then
  always "   nothing was declared, so there is nothing to compare -- the device tree section above is the"
  always "   reading, and it is a reading about WHICH IMAGE BOOTED."
fi

# The flash/torch half is a different driver on a different bus, so its absence is its own fact rather than
# one more missing name. Anything declared with the `led:` prefix comes from leds-qpnp-flash.c.
FLASH_DECLARED=""
for name in $DECLARED; do
  case "$name" in led:*) FLASH_DECLARED="$FLASH_DECLARED $name" ;; esac
done
FLASH_MISSING=""
for name in $FLASH_DECLARED; do
  [ -e "$LED_DIR/$name" ] || FLASH_MISSING="$FLASH_MISSING $name"
done
FLASH_MISSING=${FLASH_MISSING# }
# A declared name with no `led:` prefix that is also missing: the notification RGB, the button backlight, the
# display backlight. Kept apart from the flash set because the two failures have different causes and
# different next moves, and a rung that named only one of them would send the reader to the wrong driver.
OTHER_MISSING=""
for name in $MISSING; do
  case "$name" in led:*) ;; *) OTHER_MISSING="$OTHER_MISSING $name" ;; esac
done
OTHER_MISSING=${OTHER_MISSING# }
NOTIF_DECLARED=""
for name in red green blue; do
  case " $DECLARED " in *" $name "*) NOTIF_DECLARED="$NOTIF_DECLARED $name" ;; esac
done
NOTIF_DECLARED=${NOTIF_DECLARED# }
say "   notification RGB declared:  ${NOTIF_DECLARED:-none}"
say "   torch/flash declared:       ${FLASH_DECLARED:-none}"

# The other direction, and it is not a fault: the class can hold an entry the device tree never names. On
# this board it really does -- leds-qpnp.c registers an extra classdev called `rgb` whenever the node carries
# `qcom,rgb-sync` (which leds@d000 does), and that dev is where `rgb_blink` lives. Reporting it keeps the
# comparison honest: a reader who saw only the declared names would think the list below was the whole class.
EXTRA=""
for n in $ENTRIES; do
  case " $DECLARED " in *" $n "*) ;; *) EXTRA="$EXTRA $n" ;; esac
done
EXTRA=${EXTRA# }
always "   registered but NOT declared: ${EXTRA:-none}"

# Is anything being driven? A trigger other than "none" means SOMETHING claimed the LED; brightness > 0
# means it is on. Both are read, and neither is turned into a rung, because both are normal at zero.
ACTIVE=""
if [ -n "$ENTRIES" ]; then
  for d in "$LED_DIR"/*; do
    [ -e "$d" ] || continue
    n=$(basename "$d")
    b=$(rd "$d/brightness"); t=$(rd "$d/trigger")
    cur=$(printf '%s\n' "$t" | sed -e 's/.*\[//' -e 's/\].*//' | sed -n 1p)
    case "$b" in 0 | EMPTY | UNREADABLE) ;; *) ACTIVE="$ACTIVE $n(brightness=$b)" ;; esac
    case "$cur" in "" | none | EMPTY | UNREADABLE) ;; *) ACTIVE="$ACTIVE $n(trigger=$cur)" ;; esac
  done
fi
always "   driven now: ${ACTIVE:-nothing (all entries at brightness 0 and trigger none)}"

# --- verdict ---------------------------------------------------------------------------------------
# The rung the evidence reaches, named. Each rung is a different problem with a different next move.
if [ "$DT_RUNG" = no-node ]; then
  V=no-device-tree-nodes
  VMSG="the running device tree declares no LED node at all, so no LED driver has anything to bind to. doc 137 showed the stock and rebuilt trees do not describe the same board, so this is a reading about WHICH IMAGE BOOTED rather than about the LEDs."
elif [ "$LED_COUNT" = 0 ]; then
  V=no-led-class
  VMSG="$LED_DIR has no entry, so no LED driver registered anything. The driver section above says which drivers exist and what is attached: a driver directory with no bound device is a node that was never probed."
elif [ -n "$OTHER_MISSING" ]; then
  V=declared-names-missing
  VMSG="declared LED names with no entry in the class, and they are named above: $OTHER_MISSING. Each one is a driver that did not register its classdev, or a node whose status is disabled. These are not the flash half -- that half is a different driver and gets its own rung below."
elif [ -n "$FLASH_MISSING" ]; then
  V=no-flash-class
  VMSG="the notification and backlight entries are registered, and the torch/flash entries are NOT: $FLASH_MISSING. That half is a separate SPMI driver (qcom,qpnp-flash-led) plus a separate consumer (/soc/qcom,camera-flash, bound by the camera stack), so this is the flash path failing to register rather than the LED core, and the log section above is where its reason would be."
else
  V=registered
  VMSG="every name the device tree declares is registered in the LED class. Whether any of them LIGHTS is not answered here -- see the note under this verdict."
fi

always ""
always "== verdict: $V"
always "   $VMSG"
always ""
always "   WHAT THIS IS NOT: an answer to 'does the notification LED work', or 'does the torch light'."
always "   An idle phone has every LED at brightness 0 with trigger none, so 'nothing is driven now' and"
always "   'nothing can drive them' are the same reading. What is evidence here is which entries exist"
always "   and what max_brightness says they allow. Lighting one is a WRITE (brightness, or the flash"
always "   driver's strobe), and this probe does not write -- that test is its own step."

case "$V" in
registered) exit 0 ;;
*) exit 1 ;;
esac
