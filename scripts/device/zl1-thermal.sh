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
# *** THE WINDOW'S TEMPERATURE IS A MEAN, AND IT USED TO BE ONE INSTANT (docs 176/177). ***
#
# The zone table was read ONCE, after the window's sleep, so every number under "== thermal zones:"
# was a snapshot of the window's LAST INSTANT. On 2026-09-26 six device runs of the paired governor
# instrument used that table to price the second heat cause and printed +2.03 / -0.58 / +2.48 / +5.88 /
# +2.27 / +2.30 C on the same phone on the same boot -- and an independent sampler reading the same
# files BY NAME every 2 s during one of those runs showed why: thermal_zone18 walked 41.7 -> 45.6 ->
# 43.7 INSIDE its own 48 s window. A window has no single temperature, so "one sample" was a lottery
# and its prize was the whole reading: the same run and the same pairing gave +2.30 from the snapshot
# and +0.61 from the window means -- 1.7 C, three quarters of the effect being priced.
#
# Nothing about the CPU side changed: /proc/stat and the per-process table are still two snapshots and
# their difference, because a tick count IS a delta over a window. This is the temperature side
# catching up with that idea. `take_window` now walks the zones once a second for the length of the
# window, and `thermal_summary` reports the MEAN of those samples per zone -- printed with how many
# samples it took, how many seconds it actually walked, and how far the widest zone moved across them,
# so a zone whose own scatter is bigger than the difference being measured says so in the output
# instead of in a reviewer's head.
#
# The unit table, the flags and the `hottest:` line are untouched: the mean is computed on the RAW
# values per (name, type) and then scaled by the same table, so the printed layout is byte-identical
# in shape and every existing reader -- including device/zl1-governor-temp-ab.sh, which parses `$4 ==
# "C"` -- keeps working.
#
# *** AND EVERY "/s" IN HERE WAS DIVIDED BY THE WRONG BAR (docs 177, second half). ***
#
# The CPU side is two snapshots and their difference, and the difference was divided by the number of
# seconds the caller ASKED for -- `--seconds 10` -- while the two snapshots are separated by the zone
# walk AND two walks of /proc, all three of which happen INSIDE the window. Measured on the device on
# 2026-09-26 with 621 processes: the 38-zone walk costs 0.30 s, one walk of /proc costs 4.58 s, so
# `--seconds 10` reads /proc/stat 20.7 s apart and runs 23.8 s end to end -- and every rate this script
# printed (`context switches N/s`, `N ticks  X/s`, `busy N of 4 cores`) was therefore about 2.07x too
# big. A core-count is a ratio and the ratio was between two different units, which is docs 174's
# mistake one file over.
#
# Three changes, each of them measured rather than argued:
#   * the sample loop SUBTRACTS a sample's own cost from its sleep, so a window is `--seconds` long
#     instead of 1.3-1.4x it (the zone walk is per-second work, and `sleep 1` sat on top of it);
#   * the window's own clock interval (fractional /proc/uptime -- the RTC on this board reads 1970) is
#     measured between the two /proc/stat reads and used as the divisor for every rate, per window, so
#     the A/B mode's two windows each use their own;
#   * when that interval cannot be read the script says REQUESTED instead of "measured" and prints to
#     stderr what it fell back to, because a rate divided by the wrong bar is exactly the defect this
#     fixes -- and a device whose clock is stuck must not turn into a division by zero.
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
  --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0" ; exit 0 ;;
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
  # The window is bracketed by two CLOCK readings, and the seconds between them are what every rate
  # below is divided by -- not the seconds the caller asked for (docs 177, see the long note at the end
  # of this function). zl1_wa is fractional and comes from /proc/uptime, which is the only clock on this
  # phone that does not read 1970.
  zl1_wa=$(cut -d' ' -f1 /proc/uptime)
  read_stat "$TMP/stat.$1a"; snap_procs "$TMP/proc.$1a"
  # The zones are walked ONCE A SECOND ACROSS THE WINDOW, and the window's temperature is their mean
  # (docs 177): a window has no single temperature, and taking one sample of it was a lottery whose
  # prize was the whole reading. The count is the bound -- one sample per second for SECONDS_WIN
  # seconds -- so the loop cannot hang on a stuck clock, and both the count and the seconds actually
  # walked are printed, because inside a clock bound a count is a range and not a constant
  # (docs 175's lesson about the pre-hold's samples, learned the same way).
  ZS="$TMP/zones.samples.$1"
  : > "$ZS"
  zl1_zs=0
  zl1_t0=$(uptime_s)
  while [ "$zl1_zs" -lt "$SECONDS_WIN" ]; do
    # One sample per second, and the sample's own cost is SUBTRACTED from the sleep (docs 177). Reading
    # 38 zones is 76 forks on this phone -- measured at 0.4 s -- so a plain `sleep 1` makes a 30 s
    # window a 42 s one, and every rate below is divided by the seconds this script says it watched.
    zl1_s0=$(cut -d' ' -f1 /proc/uptime)
    zone_raw >> "$ZS"
    zl1_zs=$((zl1_zs + 1))
    zl1_rest=$(awk -v s="$zl1_s0" '{ r = 1 - ($1 - s); if (r < 0.05) r = 0.05; printf "%.2f", r }' /proc/uptime)
    sleep "$zl1_rest"
  done
  ZSAMPLES=$zl1_zs
  ZSAMPLE_SECS=$(( $(uptime_s) - zl1_t0 ))
  read_stat "$TMP/stat.$1b"; snap_procs "$TMP/proc.$1b"
  # *** THE WINDOW'S RATES ARE DIVIDED BY THE SECONDS IT MEASURED (docs 177). ***
  #
  # Everything downstream divides tick counts by SECONDS_WIN -- the seconds the script was ASKED for --
  # while the ticks themselves are the difference between two /proc/stat snapshots that bracket the
  # zone walk AND the /proc process walk. Measured on the device on 2026-09-26 (621 processes, 38 zones):
  # `--seconds 10` read /proc/stat 20.7 s apart while dividing by 10, so every "/s" this script printed
  # was 2.07x the truth; the same run took 23.8 s end to end. That is docs 174's mistake in a new place:
  # a number in one unit divided by a bar in another. The interval is now measured (fractional
  # /proc/uptime, which is the only clock here that does not read 1970) and used for every rate.
  zl1_wb=$(cut -d' ' -f1 /proc/uptime)
  WIN_SECS=$(awk -v a="$zl1_wa" -v b="$zl1_wb" 'BEGIN { printf "%.2f", b - a }')
  case "$WIN_SECS" in
  ''|0|0.*) WIN_SECS="$SECONDS_WIN"; WIN_CLOCK_STUCK=1 ;;
  *)        WIN_CLOCK_STUCK=0 ;;
  esac
  # Kept per window rather than in one global: the A/B mode prints window A's table AFTER window B has
  # been taken, so a single global would divide A's ticks by B's seconds.
  printf '%s\n' "$WIN_SECS" > "$TMP/wsecs.$1"
  printf '%s\n' "$WIN_CLOCK_STUCK" > "$TMP/wstuck.$1"
}

# The seconds a window actually measured. Anything dividing a tick count uses THIS, and a window whose
# clock could not be read (or read as zero) falls back to the requested length rather than dividing by
# zero -- and says so, because a rate divided by the wrong bar is exactly the defect this fixes.
wsecs() { cat "$TMP/wsecs.$1" 2>/dev/null || printf '%s' "$SECONDS_WIN"; }

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
      -v secs="$(wsecs "$label")" -v stuck="$(cat "$TMP/wstuck.$label" 2>/dev/null || echo 0)" \
      -v la="$(loadavg)" -v d="$dstate" '
    BEGIN {
      if (dt <= 0) { print "  (no CPU ticks in the window -- too short?)"; exit }
      printf "  busy %.2f of %d cores (%.0f%%), of which iowait %.2f cores\n", busy/dt*n, n, 100*busy/dt, iow/dt*n
      printf "  user %.0f%%  sys %.0f%%  irq %.0f%%  softirq %.0f%%  iowait %.0f%%   (%d ticks, %.1f s%s)\n",
             100*u/dt, 100*sy/dt, 100*irq/dt, 100*soft/dt, 100*iow/dt, dt, secs,
             (stuck == 1 ? " REQUESTED -- the clock did not advance" : " measured")
      printf "  context switches %.0f/s   loadavg %s   D-state threads %s\n", c/secs, la, d
    }' > "$TMP/summary.$label"
  if [ "$(cat "$TMP/wstuck.$label" 2>/dev/null)" = 1 ]; then
    echo "  (NOTE: /proc/uptime did not advance across this window, so its rates are divided by the" >&2
    echo "   REQUESTED length, ${SECONDS_WIN}s, and not by a measured one)" >&2
  fi
  proc_delta "$TMP/proc.${label}a" "$TMP/proc.${label}b" > "$TMP/top.$label"
}

# The label is derived from the file the caller hands in ($TMP/top.A -> A) so that each window's ticks
# are divided by that window's own measured seconds.
top_list() {
  label=${1##*/top.}
  awk -v s="$(wsecs "$label")" '{ printf "   %7d ticks  %6.2f/s  %-6s %s\n", $1, $1/s, $2, $3 }' "$1"
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
zone_raw() {
  for z in /sys/class/thermal/thermal_zone*; do
    [ -r "$z/temp" ] || continue
    printf '%s %s %s\n' "${z##*/}" "$(cat "$z/type" 2>/dev/null)" "$(cat "$z/temp" 2>/dev/null)"
  done
}

zone_read() {
  zone_raw | awk "$zl1_scale_awk"
}
# zone_read is the SINGLE-INSTANT reading and NOTHING in a window calls it any more (docs 177): the
# window reports zone_mean's average of what take_window walked. It stays because it is the shape every
# reader of this output binds to -- `name=type:milli:raw:flag:unit`, with `raw` and the unit printed so
# the scaling can be checked by hand -- and zone_mean is defined as that shape with an average in it.
# A one-line samples file gives exactly this function's answer, which is how the mean degrades to the
# old behaviour if a window is ever one sample long.

# The mean of many samples, in zone_read's format. $1 = a file of repeated "name type raw" triples.
# The average is taken on the RAW values and scaled once at the end, which is the same arithmetic in
# either order because the factor is a constant per zone -- but it keeps the printed `raw` field
# consistent with the printed milli value, which is the property that lets a reader check the scaling
# by hand. Zones that appear in some samples and not others (a driver that registers late, a file that
# goes unreadable) are averaged over the samples that HAVE them, and their count is their own.
zone_mean() {
  awk '
    { k = $1 " " $2
      if (n[k]++ == 0) ord[++z] = k
      s[k] += $3 + 0 }
    END { for (i = 1; i <= z; i++) { split(ord[i], p, " "); printf "%s %s %.1f\n", p[1], p[2], s[ord[i]] / n[ord[i]] } }
  ' "$1" | awk "$zl1_scale_awk"
}

# How far each zone moved across the samples, in milli-degC -- the same unit as the table, computed by
# scaling first and subtracting after, because the raw units differ per driver (a spread in raw numbers
# would compare deci-degC with milli-degC). "name milli_span samples". Printed so that a zone whose own
# scatter is the size of the thing being measured cannot be read as a quiet number (docs 176:
# thermal_zone12 moved 412 -> 480 -> 406 in 4 s at IDLE).
zone_spread() {
  awk "$zl1_scale_awk" "$1" | awk -F'[:=]' '
    { k = $1
      if (n[k]++ == 0) { mn[k] = $3 + 0; mx[k] = $3 + 0; ord[++z] = k }
      if ($3 + 0 < mn[k]) mn[k] = $3 + 0
      if ($3 + 0 > mx[k]) mx[k] = $3 + 0 }
    END { for (i = 1; i <= z; i++) printf "%s %d %d\n", ord[i], mx[ord[i]] - mn[ord[i]], n[ord[i]] }'
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
  # The window's temperature is the MEAN of the samples `take_window` walked across it (docs 177), not
  # the last instant -- see the header. `zone_mean` keeps zone_read's exact output shape, so `hottest:`,
  # the flags and every reader of this table are unchanged.
  zmean="${ZS:-$TMP/zones.samples}"
  if [ ! -s "$zmean" ]; then
    echo "== thermal zones: none readable"
    return
  fi
  zone_mean "$zmean" > "$TMP/zones.now"
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
  # ... and how much each zone moved while it was being averaged. A zone whose own swing approaches the
  # difference this run is trying to measure is not a quiet number, and the reader can only know that if
  # it is printed here (docs 176: thermal_zone12 moved 5 C in 4 s on an idle phone).
  zone_spread "$zmean" > "$TMP/zones.spread"
  if [ -s "$TMP/zones.spread" ]; then
    # The span is timed by /proc/uptime, and on a machine whose clock does not move there is no span to
    # print -- but the SAMPLE COUNT is still a count (the loop is bounded by it), so it is printed either
    # way and the missing second is named rather than printed as 0 (a zero here reads as "the walk was
    # instantaneous", which is the opposite of what a stuck clock means).
    if [ "${ZSAMPLE_SECS:-0}" -gt 0 ] 2>/dev/null; then
      zl1_wstr="${ZSAMPLE_SECS}s"
    else
      zl1_wstr="an untimed span (the clock did not advance)"
    fi
    awk -v s="$ZSAMPLES" -v w="$zl1_wstr" '
      { if ($2 + 0 > m) { m = $2 + 0; n = $1 }
        if ($2 + 0 >= 200) big++ }
      END { printf "   (mean of %s sample(s) walked over %s of this window; the widest zone moved %.1f C -- %s", s, w, m/1000, n
            if (big) printf "; %d zone(s) moved 0.2 C or more across it", big
            print ")" }' "$TMP/zones.spread"
  fi
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

  echo "== B minus A per process (ticks in windows of $(wsecs A)s and $(wsecs B)s respectively; + = hotter, sorted by size):"
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
  # Window B's side is the MEAN of the samples window B walked, exactly like window A's (docs 177).
  # Before that this line re-read the zones once, AFTER window B was over -- so the A/B compared a mean
  # with an instant, which is the same defect the single-window table had.
  zone_mean "$TMP/zones.samples.B" > "$TMP/zones.B"
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
