#!/bin/sh
# zl1 thermal budget -- who is burning, and how hot the SoC actually is. Read-only.
#
# Why a script at all: docs/ubuntu-touch/72 answered "what is making this phone hot" by hand -- tick
# deltas from /proc/<pid>/stat sampled twice, /proc/stat before and after, thermal zones, and then the
# same measurement again after changing one thing (SIGSTOP the debug keeper), with the conclusion
# coming from the *difference* between the two windows (5.5/6.1/2.7 C on tsens1/tsens8/pm8994). Doing
# that by hand is where numbers get mixed up, and the A/B is the part that matters: an absolute
# temperature means nothing on a device whose battery is charging and whose ambient changes.
#
# So this is an instrument, not a report, and it has one opinion in it: **a CPU number here is a delta
# over a window and nothing else.** `top`'s instantaneous percentage on this kernel prints values that
# cannot be added up (doc 72 section 1); /proc/<pid>/stat fields 14+15 accumulated over N seconds can
# be, because HZ is 100 and the deltas are integers. It also separates `iowait` from user/sys, because
# doc 72 section 4's "2.4 cores in the kernel" turned out to be iowait accounting and a number that
# cannot tell those apart is the one that misled that doc.
#
# What it reads, all read-only: /proc/stat, /proc/<pid>/stat, /proc/<pid>/comm, /proc/loadavg,
# /proc/cpuinfo, /proc/meminfo, /sys/class/thermal/thermal_zone*, /sys/devices/system/cpu/*/cpufreq/*,
# and the LXC cgroup memory counters if this kernel exposes them. It writes nothing to the device: no
# file outside /tmp, no property, no /sys write, no service touched, no signal sent.
#
# One more thing it has an opinion about, and this one is a bug it used to have: **the thermal zones do
# not share a unit.** On this device tsens_tz_sensor* report deci-degC, pm8994_tz/battery report
# milli-degC, and msm_therm/quiet_therm/pa_therm*/emmc_therm report plain degC -- three conventions at the
# same instant, and neither the sysfs ABI nor the file contents say which one a given zone uses. Until
# the table below existed, this script divided every zone by 1000, which made it report the hottest SoC
# zone as 0.6 C, make `hottest:` pick whichever family happened to have the largest *raw* number (so a
# tsens zone could never win), and -- the expensive one -- render doc 72's 5.5 C cooling result, the
# measurement the whole A/B exists for, as "+0.0 C". See the comment on zone_read().
#
# Usage (on the device):
#   zl1-thermal.sh                        # one 30 s window: CPU attribution + temperature
#   zl1-thermal.sh --seconds 60 --top 15
#   zl1-thermal.sh --ab --hold 30         # window A, a gap to change one thing, window B, then the
#                                         # per-process and per-zone *differences* -- the doc 72 shape
#   zl1-thermal.sh --quiet                # summary only, no per-process table
#
# --ab is meant to be driven from the host like this:
#
#   ssh root@10.15.19.82 'sh /tmp/zl1-thermal.sh --ab --hold 30' &
#   sleep 35; ssh root@10.15.19.82 'sh /tmp/zl1-quiet-debug-keeper.sh --stop'   # change ONE thing
#
# ... and the verdict is in the second half. The gap is a plain sleep and not a prompt on purpose: this
# runs over ssh, and a script that waits for a keypress is a script that hangs a session (the same trap
# zl1-sensors-recover.sh's stuck() had to avoid).

set -u

SECONDS_WIN=30
TOP=10
HOLD=0
AB=0
QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
  --seconds) SECONDS_WIN="${2?--seconds needs a number}"; shift 2 ;;
  --top)     TOP="${2?--top needs a number}"; shift 2 ;;
  --ab)      AB=1; shift ;;
  --hold)    HOLD="${2?--hold needs a number}"; shift 2 ;;
  --quiet)   QUIET=1; shift ;;
  --help|-h) sed -n '2,49p' "$0"; exit 0 ;;
  *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

TMP=$(mktemp -d /tmp/zl1-thermal.XXXXXX) || exit 1
trap 'rm -rf "$TMP"' EXIT INT TERM

uptime_s() { awk '{printf "%d", $1}' /proc/uptime; }
loadavg() { cut -d' ' -f1-3 /proc/loadavg; }
ncpu() { grep -ac '^processor' /proc/cpuinfo; }

# --- snapshots ---------------------------------------------------------------------------------

# One "u n s idle iowait irq softirq steal" line, plus ctxt on line 2. The fields are /proc/stat's
# aggregate "cpu" line, $2..$9 (user nice system idle iowait irq softirq steal) -- exactly eight, which
# is the count the format string has to have or awk aborts and this function silently writes only the
# ctxt line, which then makes every percentage below nonsense (measured: "88.00 of 88 cores busy").
read_stat() {
  awk '/^cpu / { printf "%s %s %s %s %s %s %s %s\n", $2, $3, $4, $5, $6, $7, $8, $9 }' /proc/stat > "$1"
  awk '/^ctxt/ { print $2 }' /proc/stat >> "$1"
  [ "$(wc -l < "$1")" -eq 2 ] || { echo "error: read_stat got $(wc -l < "$1") lines, not 2" >&2; exit 1; }
}

# "pid comm ticks" for every process. comm comes from /proc/<pid>/comm (one word, never contains a
# space) rather than from /proc/<pid>/stat, whose comm field is parenthesised *and may contain spaces*
# -- which silently shifts fields 14/15 onto the wrong numbers for exactly the processes one is
# looking at. The sub() below strips "pid (comm) " so that $12/$13 are utime/stime for every process,
# including the ones whose name has a space in it.
snap_procs() {
  : > "$1"
  for p in /proc/[0-9]*; do
    pid=${p#/proc/}
    [ -r "$p/stat" ] || continue
    t=$(awk '{ sub(/^[^)]*\) /, ""); print $12 + $13 }' "$p/stat" 2>/dev/null)
    [ -n "$t" ] || continue
    c=$(cat "$p/comm" 2>/dev/null)
    [ -n "$c" ] || c="?"
    printf '%s %s %s\n' "$pid" "$c" "$t" >> "$1"
  done
}

take_window() {
  read_stat "$TMP/stat.$1a"; snap_procs "$TMP/proc.$1a"
  sleep "$SECONDS_WIN"
  read_stat "$TMP/stat.$1b"; snap_procs "$TMP/proc.$1b"
}

# Per-process deltas between two snapshots, biggest first, this script's own pid excluded.
proc_delta() {
  awk '
    FILENAME == ARGV[1] { t[$1] = $3; name[$1] = $2; next }
    { if ($1 in t && $3 - t[$1] > 0) printf "%d %s %s\n", $3 - t[$1], $1, name[$1] }
  ' "$1" "$2" | grep -av "^[0-9]* $$ " | sort -rn | head -"$TOP"
}

# --- one window's verdict ----------------------------------------------------------------------

# $1 = label. Prints the core-load summary for that window into $TMP/summary.$1 and the top list into
# $TMP/top.$1. All arithmetic on integers, then one awk for the formatting -- a shell that has to
# explain its own awk expression is a shell nobody will trust later.
verdict() {
  label="$1"
  # /proc/stat aggregate: 1=user 2=nice 3=sys 4=idle 5=iowait 6=irq 7=softirq 8=steal
  a_u=$(awk 'NR==1 {print $1}' "$TMP/stat.${label}a"); b_u=$(awk 'NR==1 {print $1}' "$TMP/stat.${label}b")
  a_n=$(awk 'NR==1 {print $2}' "$TMP/stat.${label}a"); b_n=$(awk 'NR==1 {print $2}' "$TMP/stat.${label}b")
  a_s=$(awk 'NR==1 {print $3}' "$TMP/stat.${label}a"); b_s=$(awk 'NR==1 {print $3}' "$TMP/stat.${label}b")
  a_i=$(awk 'NR==1 {print $4}' "$TMP/stat.${label}a"); b_i=$(awk 'NR==1 {print $4}' "$TMP/stat.${label}b")
  a_w=$(awk 'NR==1 {print $5}' "$TMP/stat.${label}a"); b_w=$(awk 'NR==1 {print $5}' "$TMP/stat.${label}b")
  a_r=$(awk 'NR==1 {print $6}' "$TMP/stat.${label}a"); b_r=$(awk 'NR==1 {print $6}' "$TMP/stat.${label}b")
  a_q=$(awk 'NR==1 {print $7}' "$TMP/stat.${label}a"); b_q=$(awk 'NR==1 {print $7}' "$TMP/stat.${label}b")
  a_c=$(awk 'NR==2 {print $1}' "$TMP/stat.${label}a"); b_c=$(awk 'NR==2 {print $1}' "$TMP/stat.${label}b")

  n=$(ncpu)
  dt=$(( (b_u-a_u) + (b_n-a_n) + (b_s-a_s) + (b_i-a_i) + (b_w-a_w) + (b_r-a_r) + (b_q-a_q) ))
  busy=$(( dt - (b_i-a_i) - (b_w-a_w) ))
  awk -v dt="$dt" -v busy="$busy" -v n="$n" -v u="$((b_u-a_u))" -v sy="$((b_s-a_s))" \
      -v iow="$((b_w-a_w))" -v irq="$((b_r-a_r))" -v soft="$((b_q-a_q))" -v c="$((b_c-a_c))" \
      -v secs="$SECONDS_WIN" -v la="$(loadavg)" -v d="$dstate" '
    BEGIN {
      if (dt <= 0) { print "  (no CPU ticks in the window -- too short?)"; exit }
      printf "  busy %.2f of %d cores (%.0f%%), of which iowait %.2f cores\n", busy/dt*n, n, 100*busy/dt, iow/dt*n
      printf "  user %.0f%%  sys %.0f%%  irq %.0f%%  softirq %.0f%%  iowait %.0f%%   (%d ticks, %d s)\n",
             100*u/dt, 100*sy/dt, 100*irq/dt, 100*soft/dt, 100*iow/dt, dt, secs
      printf "  context switches %.0f/s   loadavg %s   D-state threads %s\n", c/secs, la, d
    }' > "$TMP/summary.$label"
  proc_delta "$TMP/proc.${label}a" "$TMP/proc.${label}b" > "$TMP/top.$label"
}

top_list() {
  awk -v s="$SECONDS_WIN" '{ printf "   %7d ticks  %6.2f/s  %-6s %s\n", $1, $1/s, $2, $3 }' "$1"
}

# --- temperature, frequency, memory ------------------------------------------------------------

# *** The thermal zones do not share a unit. ***
#
# The sysfs thermal ABI says `thermal_zone*/temp` is milli-degC, and on most machines that is all there
# is to know. On THIS device three different in-tree drivers register zones and two of them disagree
# with the ABI. Measured at one instant, from the same snapshot (docs/ubuntu-touch/evidence/
# thermal-2026-09-22.log, section 9; the raw lines are in section 7):
#
#   tsens_tz_sensor1=558   tsens_tz_sensor8=580     deci-degC   -> 55.8 C / 58.0 C
#   pm8994_tz=49125        battery=42500            milli-degC  -> 49.1 C / 42.5 C
#   msm_therm=49           quiet_therm=50           plain degC  -> 49 C   / 50 C
#
# So the numerically smallest value in that snapshot is the hottest thing on the phone, and the largest
# is the battery. Dividing everything by 1000 -- which is what this script did -- reported the SoC at
# 0.6 C, and made the max-by-raw-value "hottest" line unable to ever name a tsens zone. It also made
# every --ab delta wrong by the same factor in the direction that matters least visibly: a real 5.5 C
# drop across the tsens family printed as "+0.0 C", i.e. as "the change cost nothing".
#
# There is no way to derive the unit from the data. A 10x error is inside every plausible temperature
# band (raw 580 is 0.58 C as milli and 58.0 C as deci, and both are believable numbers), so the only
# honest mechanism is the table, keyed on the zone's `type` -- which is what the zone's driver sets, and
# therefore what decides the unit. Two properties are kept so that a table that goes stale is loud
# rather than silent:
#
#   * a type that is NOT in the table is flagged `assumed` in the output and counted in the summary
#     (the default is the ABI's milli-degC, and saying so beats hiding it);
#   * a scaled value outside the band below is flagged `implausible` and is then EXCLUDED from the
#     hottest pick -- a number this script has just declared unbelievable should not decide the answer.
#     The band catches a family mis-assumed by 1000x (msm_therm's 47 read as degC -> 47000 C), not one
#     mis-assumed by 10x (which is why the hottest line prints the raw value and the unit as well).
#
# That last line is the real safety property: `hottest: tsens_tz_sensor8 58.0 C (raw 580 = deci-degC)`
# lets a reader check the arithmetic in their head, which is exactly what the old output prevented.
zl1_scale_awk='
  function zl1_scale(type,   f, u) {
    zl1_known = 1
    if      (type ~ /^tsens_tz_sensor[0-9]+$/)                             { f = 100;  u = "deci-degC" }
    else if (type == "pm8994_tz" || type == "battery")                     { f = 1;    u = "milli-degC" }
    else if (type ~ /^(msm_therm|quiet_therm|pa_therm[0-9]*|emmc_therm)$/) { f = 1000; u = "degC" }
    else                                                                   { f = 1;    u = "assumed-milli-degC"; zl1_known = 0 }
    zl1_unit = u
    return f
  }
  $3 == "" { next }
  {
    m = $3 * zl1_scale($2)
    flag = zl1_known ? "ok" : "assumed"
    if (m < -40000 || m > 160000) flag = "implausible"
    printf "%s=%s:%d:%d:%s:%s\n", $1, $2, m, $3, flag, zl1_unit
  }
'

# One "name=type:milli:raw:flag:unit" line per zone, so two readings can be diffed by name and every
# value downstream is in ONE unit no matter which driver registered it.
zone_read() {
  for z in /sys/class/thermal/thermal_zone*; do
    [ -r "$z/temp" ] || continue
    printf '%s %s %s\n' "${z##*/}" "$(cat "$z/type" 2>/dev/null)" "$(cat "$z/temp" 2>/dev/null)"
  done | awk "$zl1_scale_awk"
}

# $1 = a zones file. Fields, split on [:=] : 1 name 2 type 3 milli 4 raw 5 flag 6 unit.
zone_print() {
  awk -F'[:=]' '{
    printf "   %-10s %-24s %8.1f C", $1, $2, $3/1000
    if ($5 == "assumed")          printf "   <- type not in the unit table; assumed milli-degC (raw %s)", $4
    else if ($5 == "implausible") printf "   <- IMPLAUSIBLE as %s: raw %s", $6, $4
    print ""
  }' "$1"
}

thermal_summary() {
  zone_read > "$TMP/zones.now"
  if [ ! -s "$TMP/zones.now" ]; then
    echo "== thermal zones: none readable"
    return
  fi
  echo "== thermal zones:"
  zone_print "$TMP/zones.now"
  awk -F'[:=]' '
    { n++
      if ($5 != "ok") bad++
      if ($5 == "implausible") { skip++; next }
      if (++picked == 1 || $3 + 0 > m) { m = $3 + 0; t = $2; r = $4; u = $6; f = $5 }
    }
    END {
      if (picked == 0) { print "   hottest: none -- every readable zone was flagged implausible"; exit }
      printf "   hottest: %s %.1f C  (raw %s = %s", t, m/1000, r, u
      if (f != "ok") printf ", FLAGGED %s", f
      printf ", of %d zones", n
      if (bad)  printf "; %d flagged above", bad
      if (skip) printf "; %d implausible, left out of the pick", skip
      print ")"
    }' "$TMP/zones.now"
}

cpufreq_state() {
  found=0
  for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
    [ -r "$c/scaling_cur_freq" ] || continue
    found=1
    printf '   %-22s governor=%-12s cur=%-8s kHz  max=%s kHz\n' "${c#/sys/devices/system/cpu/}" \
      "$(cat "$c/scaling_governor" 2>/dev/null)" "$(cat "$c/scaling_cur_freq" 2>/dev/null)" \
      "$(cat "$c/scaling_max_freq" 2>/dev/null)"
  done
  [ "$found" = 1 ] || echo "   (no cpufreq nodes)"
}

mem_state() {
  awk '/^MemTotal|^MemAvailable|^SwapTotal|^SwapFree/ { printf "   %-14s %s kB\n", $1, $2 }' /proc/meminfo

  # The container's memory, and the trap that has already been fallen into once here.
  #
  # Doc 72 section 8 recorded "container memory: 3867268k total, 3705148k used, 162120k free --
  # 96% full" from `free`/`top` INSIDE the container, and doc 72 section 4b(d) called that "the
  # container is about to be OOM'd". Both the number and the label are wrong: this kernel has no
  # `memory` cgroup hierarchy mounted at all, so a container-side `free` is reading the host's own
  # /proc/meminfo, and 3867268k is the device's MemTotal (4 GB minus the usual carveouts), not a
  # quota. In other words that reading is "the whole phone is 96% full", which is a different and
  # more serious statement: nothing isolates the two sides from the OOM killer.
  #
  # Two independent confirmations, both from records rather than from a live device:
  #   * /proc/mounts in the 2026-09-18 and 2026-09-19 snapshots (docs/ubuntu-touch/evidence,
  #     do-not-use-this-file-as-evidence aside: they are in /mnt/data/zl1-backups) lists the systemd,
  #     freezer, devices, cpuset, perf_event, bfqio, cpu,cpuacct, debug and blkio hierarchies --
  #     no `memory`.
  #   * `lxc-info -n android -pH` prints "CPU use:" and, on a kernel that has it, "Memory use:" --
  #     doc 22's capture has the former and not the latter, and the port's container config
  #     (doc 16) has no lxc.cgroup.memory.* directive either.
  #
  # So: look for the real per-container path, and if there is no memory hierarchy, say that instead
  # of printing the host's number under a container label.
  cmem=""
  for f in /sys/fs/cgroup/memory/lxc/*/memory.usage_in_bytes \
           /sys/fs/cgroup/memory/lxc.payload.*/memory.usage_in_bytes; do
    [ -r "$f" ] || continue
    cmem="$f"
    printf '   %-14s %s bytes  (%s)\n' "android cgroup" "$(cat "$f")" "$f"
    lim="${f%usage_in_bytes}limit_in_bytes"
    [ -r "$lim" ] && printf '   %-14s %s bytes\n' "android limit" "$(cat "$lim")"
    break
  done
  if [ -z "$cmem" ]; then
    if [ -r /sys/fs/cgroup/memory/memory.usage_in_bytes ]; then
      # The hierarchy exists but has no lxc/<name> child: this is the ROOT of the hierarchy, i.e. the
      # whole system. Printing it is fine as long as it is not called the container's number.
      printf '   %-14s %s bytes  (ROOT of the hierarchy -- the whole system, NOT the container)\n' \
        "cgroup usage" "$(cat /sys/fs/cgroup/memory/memory.usage_in_bytes)"
      echo "                    -> no lxc/<name> child under it: no per-container accounting here"
    else
      echo "   cgroup memory  : NO memory cgroup mounted on this kernel"
    fi
    echo "                    -> a container-side \`free\` reports THIS device's MemTotal, not a"
    echo "                       container quota (doc 87). Read MemAvailable above as the phone's"
    echo "                       headroom, and remember nothing isolates UT's processes from"
    echo "                       Android's when the OOM killer chooses."
  fi
}

dstate_count() {
  n=0
  for p in /proc/[0-9]*/stat; do
    s=$(awk '{ sub(/^[^)]*\) /, ""); print $1 }' "$p" 2>/dev/null)
    [ "$s" = "D" ] && n=$((n + 1))
  done
  echo "$n"
}

# --- run ---------------------------------------------------------------------------------------

echo "zl1 thermal budget :: $(date) :: uptime $(uptime_s) s :: window ${SECONDS_WIN}s :: read-only"
dstate=$(dstate_count)

take_window A
verdict A
cat "$TMP/summary.A"
if [ "$QUIET" = 0 ]; then
  echo "== window A, top $TOP by CPU:"
  top_list "$TMP/top.A"
fi
thermal_summary
echo "== cpufreq:"
cpufreq_state
echo "== memory:"
mem_state

if [ "$AB" = 1 ]; then
  [ "$HOLD" -gt 0 ] || HOLD=$SECONDS_WIN
  cp "$TMP/zones.now" "$TMP/zones.A" 2>/dev/null || true
  echo
  echo "== window A done. Change ONE thing now; window B starts in ${HOLD}s :: $(date)"
  sleep "$HOLD"
  dstate=$(dstate_count)
  take_window B
  verdict B
  echo "== window B (after the change):"
  cat "$TMP/summary.B"
  echo "== window B, top $TOP by CPU:"
  top_list "$TMP/top.B"

  echo "== B minus A per process (ticks in the same ${SECONDS_WIN}s window; + = hotter, sorted by size):"
  # Two things this section has to get right. The union of the two top lists, not just B's: a process
  # that went quiet is by definition no longer in B's top list, so differencing only B's list hides the
  # answer to the question the mode exists for -- "did the thing I just stopped actually stop?". (Doc 81
  # section 3 already said an A-only process counts from 0; now it does.) And the sort is by the SIZE of
  # the change either way, because the biggest mover is the finding, and it is as likely to be a drop
  # (the keeper was SIGSTOPped) as a rise.
  if [ -s "$TMP/top.A" ] || [ -s "$TMP/top.B" ]; then
    awk '
      FILENAME == ARGV[1] { a[$2 " " $3] = $1; seen[$2 " " $3] = 1; next }
      { b[$2 " " $3] = $1; seen[$2 " " $3] = 1 }
      END {
        for (k in seen) {
          d = (k in b ? b[k] : 0) - (k in a ? a[k] : 0)
          if (d == 0) continue
          split(k, p, " ")
          m = d < 0 ? -d : d
          printf "%d %d %s %s %s\n", m, d, p[1], p[2], (k in a ? "-" : "A")
        }
      }
    ' "$TMP/top.A" "$TMP/top.B" | sort -rn | head -"$TOP" | awk '
      { printf "   %+8d  %-6s %s", $2, $4, $3
        if ($5 != "-") printf "   (absent from window %s, counted from 0)", $5
        print "" }'
    echo "   (processes in either top-$TOP list)"
  else
    echo "   (both windows were empty: nothing to compare)"
  fi

  echo "== B minus A per thermal zone (sorted by the size of the change, either direction):"
  zone_read > "$TMP/zones.B"
  # Both sides are already in milli-degC (zone_read), so this diff is in one unit whatever the driver --
  # which is what makes the doc 72 numbers reproduce here. Zones flagged implausible in B are left out
  # rather than differenced against a number this script has just called unbelievable, and a zone that
  # only exists in B is not differenced against 0 C (which would print as a +40 C "cooling").
  #
  # The sort is by magnitude, not by signed value: the finding is the biggest mover, and on this device
  # the biggest mover in the one A/B anyone has run was a *drop* (5.5 C), which a signed descending sort
  # would have put last, behind the battery's 0.3 C drift.
  awk -F'[:=]' '
    FILENAME == ARGV[1] { t[$1] = $3; next }
    $5 == "implausible" { skip++; next }
    !($1 in t) { fresh++; next }
    { d = $3 - t[$1]; m = d < 0 ? -d : d; printf "%d %d %s %s %s %s %s\n", m, d, $1, $2, t[$1], $3, $5 }
    END { if (skip)  printf "note    (%d zone(s) left out: flagged implausible in B)\n", skip
          if (fresh) printf "note    (%d zone(s) readable only in B: nothing to difference against)\n", fresh }
  ' "$TMP/zones.A" "$TMP/zones.B" > "$TMP/zdiff"
  grep -v '^note' "$TMP/zdiff" | sort -rn | awk '
    { printf "   %-10s %-24s %+6.1f C   (%.1f -> %.1f)", $3, $4, $2/1000, $5/1000, $6/1000
      if ($7 != "ok") printf "   <- FLAGGED %s", $7
      print "" }'
  sed -n 's/^note *//p' "$TMP/zdiff"
fi
