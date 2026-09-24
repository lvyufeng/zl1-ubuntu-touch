#!/bin/sh
# zl1 LMH probe -- is the SoC's own HARDWARE thermal limiter alive, and on which rung?
#
# Why this exists. doc 137 enumerated the device's hardware from its own device trees and asked which
# blocks no script in this tree reads. Twelve of twenty-nine are read by nothing, and the one that
# matters most for this port's oldest complaint is `thermal-lmh`: the node is `/soc/qcom,lmh` with
# `compatible = qcom,lmh_v1`, and **no script here had ever read it** -- on a phone whose user asks for
# the overheating to be fixed.
#
# Why it was missed is structural, and it is not obvious from any reading on the device:
# **LMH registers no thermal zone and is not a cooling device.** `drivers/thermal/lmh_lite.c` has zero
# occurrences of `thermal_zone`, `of_thermal` or `thermal_cooling`, and zero of `cpufreq`/`devfreq`/`qos`.
# Every thermal reader in this port -- zl1-thermal.sh, the health check, the heat chain's A/B -- reads
# /sys/class/thermal/thermal_zone*, so by construction none of them could ever have seen it. The limiting
# is done by the LMH hardware block and the secure world; Linux's driver *monitors* it and exposes a
# profile level. That is the thing to read, and there is no thermal zone to read it from.
#
# Every path below is taken from the driver source in the Halium build tree
# (`kernel/leeco/msm8996/drivers/thermal/lmh_lite.c` and `lmh_interface.c`), not guessed:
#
#   /sys/bus/platform/drivers/lmh-lite-driver     LMH_DRIVER_NAME, "lmh-lite-driver"
#   /sys/class/msm_limits/<dev>/{level,total_levels,available_levels}
#                                                 class "msm_limits"; the one device the driver registers
#                                                 is LMH_DEVICE = "lmh-profile" (lmh_lite.c's single
#                                                 lmh_device_register call, at the end of lmh_device_init)
#   /sys/kernel/debug/lmh_monitor/                LMH_MON_NAME = "lmh_monitor"
#     interrupt_poll_delay_msec                   LMH_ISR_POLL_DELAY
#     hw_trace_enable, hw_trace_interval          LMH_TRACE_ENABLE / LMH_TRACE_INTERVAL
#     debug/{data,config,data_types,config_types} LMH_DBGFS_*
#
# **The driver's failure paths are deliberately asymmetric, and that is why this probe reads rungs and
# not one flag.** From lmh_probe(), in order:
#   * lmh_sensor_init()  is FATAL. It needs SCM commands (LMH_CTRL_QPMDA, LMH_GET_INTENSITY,
#     LMH_GET_SENSORS, plus LMH_TRIM_ERROR only when the device tree has no `qcom,lmh-trim-err-offset`).
#     If the secure world does not advertise them, probe returns -ENODEV and **the device never binds**.
#   * lmh_device_init()  is a WARNING -- the driver prints "LMH continues" -- so the msm_limits profile
#     nodes can be absent on a limiter that is otherwise fully up.
#   * lmh_debug_init()   is pr_err + ret=0, NOT fatal, and its own SCM gate (LMH_DEBUG_*) is checked
#     under pr_debug, i.e. **quietly**. So the monitor nodes can be absent too, with nothing in the log.
# Four different states, and "no debugfs node" on its own cannot tell them apart.
#
# Two things this probe deliberately does NOT do. It does not parse `debug/data`: nothing in this tree
# records that buffer's layout, and a guessed column would be a fabricated answer (docs 109's rule), so
# the bytes are printed raw and labelled as unparsed. And it does not claim the limiter is *working* from
# an absolute level -- see the note under the verdict.
#
# **Read-only, and it writes nothing at all -- not even a scratch file.** Every probe here that needs a
# second pass over a log keeps it in a shell variable, and this one has no other use for /tmp.
#
# Usage (on the device):
#   sh zl1-lmh-probe.sh              # every rung, then a verdict
#   sh zl1-lmh-probe.sh --quiet      # verdict and the readings it rests on
#   sh zl1-lmh-probe.sh --explain    # what each reading decides, and why this reading
#
# Exit: 0 the limiter is bound, registered its sensors, and everything Linux-side reads;
#       1 bound (or not) with the reading chain stopping early -- the verdict names the rung;
#       2 not the zl1, or this kernel has no LMH driver at all.

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

# `say` carries the readings, `hdr` the headings, `always` the two things a reader must see whether or
# not they asked for the readings: WHICH boot this is (a verdict with no boot identity cannot be
# attributed to anything) and the verdict itself. `hdr` prints under --quiet too, because a one-paragraph
# --quiet with no labels is worse than no --quiet at all.
say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
hdr() { printf '\n== %s\n' "$*"; }
always() { printf '%s\n' "$*"; }

# The device guard. `compatible` and not `model`: msm8996 is what this port's other probes refuse on, and
# a probe that runs on the wrong phone reads a different SoC's limiter and reports it as this one's.
grep -qa msm8996 /proc/device-tree/compatible 2>/dev/null ||
  { echo "not the zl1 (no msm8996 in /proc/device-tree/compatible) -- refusing" >&2; exit 2; }

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
# Existence as a word, so it cannot be confused with an empty answer.
ex() { [ -e "$1" ] && printf 'present' || printf 'MISSING'; }
# Raw bytes as hex, because a device-tree property and a debugfs buffer are bytes and not text. With
# neither od nor hexdump present the answer is a named absence, not a blank line.
hexread() { # $1 = path, $2 = max bytes
  if [ ! -r "$1" ]; then printf 'UNREADABLE'; return; fi
  if command -v od >/dev/null 2>&1; then
    head -c "${2:-64}" "$1" 2>/dev/null | od -An -tx1 | tr -s ' \n' ' ' | sed 's/^ //; s/ $//'
  elif command -v hexdump >/dev/null 2>&1; then
    head -c "${2:-64}" "$1" 2>/dev/null | hexdump -v -e '1/1 "%02x "' | sed 's/ $//'
  else
    printf 'no od or hexdump'
  fi
}
# Print the lines of TEXT that match an ERE, or a named "(none: ...)" line -- never nothing.
# NOT `grep ... | sed ... || say none`: in a pipeline the `||` applies to the LAST command and `sed`
# succeeds on empty input, so the none-branch would never fire and a pattern matching nothing would print
# nothing at all. That is a shape this repo has had to fix in four other instruments.
show() { # $1 = text, $2 = ERE, $3 = the "(none: ...)" text, $4 = tail -n, $5 = 1 to print under --quiet
  [ "$QUIET" = 1 ] && [ "${5:-0}" != 1 ] && return 0
  out=$(printf '%s\n' "$1" | grep -aiE -- "$2" 2>/dev/null | tail -n "${4:-15}")
  if [ -n "$out" ]; then printf '%s\n' "$out" | sed 's/^/   | /'; else printf '   | %s\n' "$3"; fi
}

if [ "$MODE" = explain ]; then
  cat <<'EOF'
zl1 LMH probe -- what each reading decides, and why it is this reading

  1. THE DEVICE TREE'S OWN DESCRIPTION, searched and not assumed.
     The node is /soc/qcom,lmh with compatible qcom,lmh_v1 in the device trees analysed offline -- but
     doc 137 showed the STOCK and REBUILT trees do not describe the same board (rebuilt carries 21 nodes
     stock does not), and this port may boot either. So the node is FOUND by glob, the `compatible` is
     printed as the booting kernel sees it, and the properties the driver reads are listed individually:
     `interrupts` (the limiter's IRQ), `vdd-apss-supply` (present => lmh_dpm_init() runs), and
     `qcom,lmh-odcm-disable-threshold-mA`. Note that `qcom,lmh-trim-err-offset` being ABSENT is normal:
     the driver reads that as trim_err_disable=true and skips the LMH_TRIM_ERROR SCM command.

  2. THE DRIVER, and whether a device is bound to it.
     /sys/bus/platform/drivers/lmh-lite-driver exists as soon as the module registers, which is a
     different fact from a **bound device** (a symlink inside that directory). The difference is the
     whole first question, because lmh_sensor_init() is FATAL: no sensors from the secure world, no bind.

  3. THE SENSOR LIST, from the kernel log.
     `Registering sensor:[<name>_<node_id>]` is printed once per sensor the secure world returned. Zero of
     them on a bound device cannot happen (that path is fatal before it), so the count reads how much of
     the limiter the secure world handed over -- and `SCM cmd:N not available` / `Sensor Init failed.
     err:-19` are the lines that say WHY there are none. If neither dmesg nor the journal can be read,
     the count is UNREAD, which is not zero and is reported as its own verdict.

  4. THE PROFILE, /sys/class/msm_limits/lmh-profile/{level,total_levels,available_levels}.
     This is lmh_device_init()'s output, and its failure is only a WARNING in the driver ("LMH
     continues"), so these files can be absent on a limiter that is otherwise fully up. `level` is the
     software profile knob (0600, root-writable); `available_levels` and `total_levels` are what it can
     be set to. A level number on its own says nothing about throttling -- see the note at the end.

  5. THE MONITOR PATH, /sys/kernel/debug/lmh_monitor/.
     debugfs must be MOUNTED for anything under it to exist, and to `ls` a missing node and an unmounted
     debugfs look identical. So the mount state is read first from /proc/mounts, and a missing node is
     only reported as a driver fact when debugfs IS mounted. debug/data is the live buffer; it is printed
     and deliberately not parsed.

  6. THE INTERRUPT, from /proc/interrupts.
     The driver requests an IRQ and re-enables it from a workqueue once throttling stops ("Zero
     throttling. Re-enabling interrupt"). A row here means the interrupt is REGISTERED. The count column
     is what says whether it has fired, and zero on an idle phone is normal.

  WHAT THIS CANNOT SAY. A low `level` or a quiet interrupt does not mean the limiter is working, and a
  high one does not mean the phone is throttling. LMH's limiting happens in the hardware block and the
  secure world; this driver monitors it and exposes a profile. "Is it working" needs a load on the SoC --
  a reading taken while the phone is hot, which is what zl1-thermal.sh's A/B is for and why this probe
  and that one are meant to be read together.
EOF
  exit 0
fi

# --- who am I reading ------------------------------------------------------------------------------
hdr "this boot"
always "   boot id:    $(rd /proc/sys/kernel/random/boot_id)"
always "   uptime:     $(cut -d' ' -f1 /proc/uptime 2>/dev/null)s"
say "   kernel:     $(rd /proc/version)"

# --- 1. the device tree's own description -----------------------------------------------------------
hdr "the device tree's description of the limiter"
DT_NODES=""
for n in /proc/device-tree/soc/*lmh* /proc/device-tree/*lmh*; do
  [ -e "$n" ] || continue
  DT_NODES="$DT_NODES $n"
done
if [ -z "$DT_NODES" ]; then
  always "   no *lmh* node under /proc/device-tree -- the running device tree has no limiter"
  DT_RUNG=no-node
else
  DT_RUNG=node
  for n in $DT_NODES; do
    always "   node:  ${n#/proc/device-tree}"
    say "     compatible:  $(tr '\0' ' ' < "$n/compatible" 2>/dev/null)"
    for p in interrupts vdd-apss-supply qcom,lmh-odcm-disable-threshold-mA qcom,lmh-trim-err-offset; do
      if [ -e "$n/$p" ]; then
        say "     $(printf '%-38s' "$p") present  [$(hexread "$n/$p" 64)]"
      else
        say "     $(printf '%-38s' "$p") absent"
      fi
    done
  done
fi

# --- 2. the driver, and whether anything is bound to it --------------------------------------------
hdr "the driver"
DRV_DIR=""
for d in /sys/bus/platform/drivers/*lmh*; do
  [ -e "$d" ] || continue
  DRV_DIR="$d"
done
if [ -z "$DRV_DIR" ]; then
  always "   /sys/bus/platform/drivers/*lmh*:  MISSING -- this kernel has no LMH driver registered"
  always "   (the Halium defconfig carries CONFIG_LIMITS_LITE_HW=y and CONFIG_LIMITS_MONITOR=y, so a"
  always "    kernel without it is either not that kernel or the driver failed its own late_initcall)"
  always ""
  always "== verdict: no-driver"
  always "   The SoC's hardware thermal limiter is not reachable from Linux on this boot, so nothing on"
  always "   this port can be limiting or reading it. The software governor (install-cpufreq-governor.sh)"
  always "   is then the only thermal policy that exists -- which is worth knowing before tuning it."
  exit 2
fi
always "   driver:          ${DRV_DIR#/sys/bus/platform/drivers/}"
BOUND=""
for b in "$DRV_DIR"/*; do
  [ -e "$b" ] || continue
  case "$(basename "$b")" in bind | unbind | uevent | module) continue ;; esac
  BOUND="$BOUND $(basename "$b")"
done
if [ -n "$BOUND" ]; then
  always "   bound device(s):$BOUND"
else
  always "   bound device(s): NONE -- the driver is registered and no limiter is attached to it"
fi
if [ -d /sys/module/lmh_lite ]; then
  say "   module lmh_lite: present, refcnt=$(rd /sys/module/lmh_lite/refcnt)"
else
  say "   module lmh_lite: not a module on this kernel (built in, as the defconfig says)"
fi

# --- 3. the sensor list, from the kernel log -------------------------------------------------------
hdr "the sensors the secure world handed over"
# dmesg where available, the journal otherwise. `LOGSRC` empty means neither could be read, and that is
# reported as UNREAD rather than as a count of zero -- an unreadable log and a log with nothing in it are
# different facts, and reading the first as the second is how a dead modem was reported as a quiet boot.
LOG_TEXT=""
LOG_SRC=""
if LOG_TEXT=$(dmesg 2>/dev/null) && [ -n "$LOG_TEXT" ]; then
  LOG_SRC=dmesg
elif LOG_TEXT=$(journalctl -b -k --no-pager 2>/dev/null) && [ -n "$LOG_TEXT" ]; then
  LOG_SRC="journalctl -b -k"
else
  LOG_TEXT=""
fi
if [ -z "$LOG_SRC" ]; then
  always "   the kernel log could not be read (neither dmesg nor journalctl -b -k returned anything)"
  always "   -- so the sensor count is NOT READ, which is not the same as zero."
  SENSORS=-1
else
  always "   source:          $LOG_SRC"
  SENSORS=$(printf '%s\n' "$LOG_TEXT" | grep -ac 'Registering sensor:\[' 2>/dev/null)
  [ -n "$SENSORS" ] || SENSORS=0
  always "   Registering sensor: lines: $SENSORS"
  show "$LOG_TEXT" 'Registering sensor:\[' \
    "(none: the driver printed no sensor registration this boot)" 20
fi
say "   this boot's lmh lines, and any SCM-gate refusal:"
if [ -n "$LOG_SRC" ]; then
  # `5 1` = print even under --quiet: this block IS the evidence the two failing rungs point at ("the log
  # lines above are what say so"), and a verdict that points at lines --quiet removed points at nothing.
  show "$LOG_TEXT" 'SCM cmd:[0-9]+ not available|Sensor Init failed|Error reading:(qcom|vdd)|WARNING: Device Init failed' \
    "(none: no SCM-gate refusal and no device-init warning in this boot's log)" 12 1
  show "$LOG_TEXT" 'lmh' "(none: the kernel log mentions lmh nowhere)" 20
else
  show "" x "(not read: the kernel log could not be read)" 1 1
fi

# --- 4. the profile --------------------------------------------------------------------------------
hdr "the profile (msm_limits)"
ML=/sys/class/msm_limits
PROF=absent
if [ -e "$ML" ]; then
  PROF=ok
  always "   class:           present"
  DEV_LIST=""
  for d in "$ML"/*; do
    [ -e "$d" ] || continue
    DEV_LIST="$DEV_LIST $(basename "$d")"
  done
  always "   device(s):      ${DEV_LIST:-NONE}"
  for d in "$ML"/*; do
    [ -e "$d" ] || continue
    for f in level total_levels available_levels; do
      if [ -e "$d/$f" ]; then
        say "     $(printf '%-32s' "$(basename "$d")/$f") $(rd "$d/$f")"
      else
        say "     $(printf '%-32s' "$(basename "$d")/$f") MISSING"
      fi
    done
  done
else
  always "   class:           MISSING -- lmh_device_init() did not create it"
  always "   (in the driver that path only WARNS: 'WARNING: Device Init failed. err:... LMH continues'."
  always "    A bound limiter with no profile is a driver state, not a missing limiter.)"
fi

# --- 5. the monitor path, with debugfs's own state first -------------------------------------------
# The whole mount LINE, not a field of it: field 1 of a /proc/mounts line is the device, and for a
# pseudo-filesystem that is the literal string `nodev` -- so `cut -d' ' -f1` here prints "source nodev",
# which is a reading that is wrong about its own subject. (The harness caught that: its fixture carries a
# real mount line, and the probe reported the field labelled "source" as `nodev`.)
hdr "the monitor path (debugfs)"
DBG_LINE=$(grep -a ' /sys/kernel/debug ' /proc/mounts 2>/dev/null | head -1)
if [ -n "$DBG_LINE" ]; then
  always "   debugfs mounted: yes ($DBG_LINE)"
else
  always "   debugfs mounted: NO -- so nothing under /sys/kernel/debug can exist, whatever the driver did"
  always "   (a missing node here is therefore NOT evidence about the driver)"
fi
MON=/sys/kernel/debug/lmh_monitor
MONR=$(ex "$MON")
always "   $MON: $MONR"
if [ -e "$MON" ]; then
  for f in interrupt_poll_delay_msec hw_trace_enable hw_trace_interval; do
    if [ -e "$MON/$f" ]; then
      say "     $(printf '%-32s' "$f") $(rd "$MON/$f")"
    else
      say "     $(printf '%-32s' "$f") MISSING"
    fi
  done
  for f in data config data_types config_types; do
    if [ -e "$MON/debug/$f" ]; then
      say "     $(printf '%-32s' "debug/$f") $(hexread "$MON/debug/$f" 48)"
    else
      say "     $(printf '%-32s' "debug/$f") MISSING"
    fi
  done
  say "   debug/data, raw and NOT parsed (nothing in this tree records its layout):"
  say "   | $(hexread "$MON/debug/data" 512)"
fi

# --- 6. the interrupt ------------------------------------------------------------------------------
hdr "the interrupt"
IRQ_ROWS=$(grep -ai 'lmh' /proc/interrupts 2>/dev/null)
if [ -n "$IRQ_ROWS" ]; then
  printf '%s\n' "$IRQ_ROWS" | sed 's/^/   | /'
  IRQR=present
else
  always "   /proc/interrupts has no 'lmh' row -- the limiter's interrupt is not registered"
  IRQR=absent
fi

# --- verdict ---------------------------------------------------------------------------------------
# The rung the evidence reaches, named. Each rung is a different problem with a different next move, and
# printing only the highest reading reached would lose the one a reader needs.
if [ "$DT_RUNG" = no-node ]; then
  V=no-device-tree-node
  VMSG="the running device tree has no LMH node, so the driver has nothing to bind to. That is a property of the DTB this boot used, and doc 137 showed the stock and rebuilt trees do not describe the same board -- so this is a reading about WHICH IMAGE BOOTED, not about the limiter."
elif [ -z "$BOUND" ]; then
  V=not-bound
  VMSG="the driver is registered and NOTHING is bound to it. lmh_sensor_init() is fatal in the driver, so the prime suspect is the secure-world gate: without the SCM commands LMH_CTRL_QPMDA / LMH_GET_INTENSITY / LMH_GET_SENSORS, probe returns -ENODEV and the limiter never comes up. The log lines above are what say so -- and this is the same secure-world dependency docs 130 records failing with scm_call -12 on some cold boots."
elif [ "$SENSORS" = -1 ]; then
  V=bound-log-unreadable
  VMSG="the limiter IS bound, but this boot's kernel log could not be read, so the sensor count is UNREAD rather than zero. Everything else below still reads; this one rung cannot."
elif [ "$SENSORS" = 0 ]; then
  V=bound-no-sensors
  VMSG="the limiter is bound with no sensor registered, which the driver's own control flow says should be impossible (the sensor path is fatal). Read the two log blocks above before believing either half."
elif [ "$PROF" = ok ] && [ "$MONR" = present ] && [ "$IRQR" = present ]; then
  V=monitoring
  VMSG="bound, sensors registered, profile readable, monitor path created, interrupt registered -- every link on the Linux side is up. The interrupt's COUNT column is a reading of how often the limiter had to work, not of whether it can."
elif [ "$PROF" = ok ]; then
  V=bound-profile-no-monitor
  VMSG="the profile is readable, so the limiter came up; the monitor path is missing. lmh_debug_init() checks its own SCM commands (LMH_DEBUG_*) and is NOT fatal in the driver, so this is a limiter that runs without its debug buffer. Check the debugfs mount line above before blaming the driver."
else
  V=bound-no-profile
  VMSG="the limiter is bound and its sensors registered, but lmh_device_init() produced no profile -- a non-fatal path in the driver ('LMH continues'), so the limiter itself is likely up and only its level knob is missing."
fi
always ""
always "== verdict: $V"
always "   $VMSG"
always ""
always "   WHAT THIS IS NOT: an answer to 'is the limiter working'. LMH limits in hardware and in the"
always "   secure world; this driver monitors it and exposes a profile. A quiet interrupt and a level"
always "   number say nothing on their own -- that reading needs a load, i.e. the A/B zl1-thermal.sh"
always "   takes, read while this device is hot."

case "$V" in
monitoring) exit 0 ;;
*) exit 1 ;;
esac
