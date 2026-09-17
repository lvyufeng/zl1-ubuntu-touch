#!/usr/bin/env bash
# Measure how usable the host↔device link actually is, as numbers.
#
# Why this exists: "the link works now" is not a testable claim, and the previous two days
# were full of claims like it that turned out to be about `carrier=1` rather than about
# packets arriving. What matters is the fraction of time the host can actually reach the
# device, and how often the device's gadget is torn down and rebuilt.
#
# Baseline, measured 2026-09-17 on the known-good v63 image (docs/ubuntu-touch/
# 26-gadget-reassert-every-2-minutes.md):
#
#   gadget re-enumerations   ~1 every 118 s (16 in 36 minutes)
#   reachable               2 pings in 36 minutes
#
# The fix under test is halium-boot-zl1-v63-noreassert.img. A useful result would be
# re-enumerations near zero and a reachable fraction near 1. Anything between is worth
# recording as a partial improvement.
#
# Read-only with respect to the device. It only observes and configures the host's usb0.
#
# Usage: measure-link-stability.sh [MINUTES] [OUTFILE]

set -uo pipefail

MINUTES="${1:-30}"
OUT="${2:-/mnt/data/zl1-bb10/tmp-link-stability-$(date -u +%Y%m%dT%H%M%SZ).csv}"
SER="33e80afe"
HOST_IPS=("192.168.2.100/24" "10.15.19.100/24")
DEV_IPS=("192.168.2.15" "10.15.19.82")
DEADLINE=$(( SECONDS + MINUTES * 60 ))

echo "sampling for ${MINUTES} minutes -> $OUT"
echo "t,usb0,mac,carrier,host_txp,host_rxp,ping15,ping82,http22,status8080" > "$OUT"

samples=0; up_samples=0; ssh_samples=0; http_samples=0
renum=0; last_mac=""
best_run=0; run_seconds=0
reach_seconds=0; total_seconds=0
prev_epoch=""

while (( SECONDS < DEADLINE )); do
  t="$(date -u +%H:%M:%S)"
  epoch="$(date +%s)"
  mac=""; carrier=""; txp=""; rxp=""; p1=N; p2=N; s22=N; h8080=N

  if [[ -e /sys/class/net/usb0 ]]; then
    mac="$(cat /sys/class/net/usb0/address 2>/dev/null)"
    carrier="$(cat /sys/class/net/usb0/carrier 2>/dev/null)"
    read -r txp rxp < <(awk '$1=="usb0:"{print $11, $3}' /proc/net/dev)
    sudo -n ip link set usb0 up 2>/dev/null
    for a in "${HOST_IPS[@]}"; do
      ip addr show dev usb0 2>/dev/null | grep -q "${a%%/*}" || sudo -n ip addr add "$a" dev usb0 2>/dev/null
    done

    ping -c1 -W1 192.168.2.15  >/dev/null 2>&1 && p1=Y
    ping -c1 -W1 10.15.19.82   >/dev/null 2>&1 && p2=Y
    # Only probe the higher-level services when the link is up at all: on a dead link
    # those probes cost seconds each and say nothing new.
    if [[ "$p1" == Y || "$p2" == Y ]]; then
      timeout 2 bash -c 'exec 3<>/dev/tcp/10.15.19.82/22' 2>/dev/null && s22=Y
      timeout 3 curl -fsS --max-time 2 http://10.15.19.82:8080/ >/dev/null 2>&1 && h8080=Y
    fi
  fi

  echo "$t,$([[ -n "$mac" ]] && echo 1 || echo 0),$mac,$carrier,$txp,$rxp,$p1,$p2,$s22,$h8080" >> "$OUT"

  # Account in seconds, not in samples. One iteration costs whatever the probes cost —
  # several seconds when they time out — so a percentage of samples would weight dead
  # periods more heavily than live ones, and a "reachable run" counted in samples would
  # understate its length.
  if [[ -n "$prev_epoch" ]]; then
    dt=$(( epoch - prev_epoch ))
    (( dt > 60 )) && dt=60          # a gap that long means the sampler stalled, not data
    total_seconds=$(( total_seconds + dt ))
    if [[ "$p1" == Y || "$p2" == Y ]]; then
      reach_seconds=$(( reach_seconds + dt ))
      run_seconds=$(( run_seconds + dt ))
      (( run_seconds > best_run )) && best_run=$run_seconds
    else
      run_seconds=0
    fi
  fi
  prev_epoch="$epoch"

  samples=$((samples + 1))
  [[ "$p1" == Y || "$p2" == Y ]] && up_samples=$((up_samples + 1))
  [[ "$s22"   == Y ]] && ssh_samples=$((ssh_samples + 1))
  [[ "$h8080" == Y ]] && http_samples=$((http_samples + 1))

  # A MAC change while usb0 stays present is the gadget being rebuilt; a gap where usb0
  # vanishes entirely also counts.
  if [[ -n "$mac" ]]; then
    if [[ -n "$last_mac" && "$mac" != "$last_mac" ]]; then
      renum=$((renum + 1))
      echo "  $(date -u +%H:%M:%S)  gadget rebuilt (new MAC $mac)  [total $renum]"
    fi
    last_mac="$mac"
  fi

  sleep 2
done

pct() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.1f", (b?100*a/b:0)}'; }
{
  echo
  echo "================ summary ================"
  echo "window                 : ${MINUTES} min requested; ${total_seconds}s covered in ${samples} samples"
  echo "gadget re-enumerations : ${renum}"
  printf 'reachable              : %s%% of the time (%ds of %ds)\n' \
    "$(pct "$reach_seconds" "$total_seconds")" "$reach_seconds" "$total_seconds"
  echo "longest reachable run  : ${best_run}s"
  printf 'ssh port 22 open       : %s%% of samples (%d)\n' "$(pct "$ssh_samples" "$samples")" "$ssh_samples"
  printf 'status page 8080       : %s%% of samples (%d)\n' "$(pct "$http_samples" "$samples")" "$http_samples"
  echo
  echo "baseline to beat (v63, 36 min — docs/ubuntu-touch/26-gadget-reassert-every-2-minutes.md):"
  echo "  16 gadget re-enumerations at a ~118 s cadence; 2 pings reached the device"
  echo "csv                    : $OUT"
} | tee -a "$OUT"
