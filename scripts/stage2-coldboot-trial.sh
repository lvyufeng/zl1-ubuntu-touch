#!/usr/bin/env bash
# Record one Stage 2 cold-boot trial, and append it to the tracked trial log.
#
# Stage 2.4 asks for three consecutive cold boots with the same result. The device is
# only reachable over RNDIS while Ubuntu Touch is up, so "the result" means: does the
# device come back, does it serve its status page, is the Android container in the
# process table, and — from the netwatch log if the device later returns to TWRP — did
# the link stall and did the watchdog heal it.
#
# Run it after powering the device on. It waits, verifies, and appends a row.
#
# Usage: stage2-coldboot-trial.sh [--note "..."] [--timeout SECONDS]

set -uo pipefail

SER="33e80afe"
OTHER_SER="4a2fe00b"
HOST_IPS=("192.168.2.100/24" "10.15.19.100/24")
DEV_IPS=("192.168.2.15" "10.15.19.82")
RNDIS_VIDPID="18d1:d001"
TIMEOUT=300
NOTE=""
OUT_DIR="/mnt/data/zl1-bb10/tmp-coldboot-trials"
LEDGER="/mnt/data/zl1-bb10/docs/ubuntu-touch/stage2-coldboot-trials.md"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --note) NOTE="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT_DIR"

if adb devices 2>/dev/null | awk -v s="$OTHER_SER" '$1==s{found=1} END{exit found?0:1}'; then
  echo "note: unrelated device $OTHER_SER (Xiaomi) is on the bus — ignoring it"
fi

echo "== waiting up to ${TIMEOUT}s for the device RNDIS gadget =="
start=$(date +%s)
gadget="no"
for (( i = 0; i < TIMEOUT / 2; i++ )); do
  if lsusb -d "$RNDIS_VIDPID" >/dev/null 2>&1; then gadget="yes"; break; fi
  sleep 2
done
t_gadget=$(( $(date +%s) - start ))
echo "gadget: $gadget (after ${t_gadget}s)"

net_ok="no"; http_ok="no"; container="unknown"; uptime=""
if [[ "$gadget" == yes ]]; then
  # Here-strings from here on: this script sets pipefail, and `lsmod | grep -q` reports the writer's
  # death when the pattern IS there (docs/ubuntu-touch/136).
  grep -q '^rndis_host' <<< "$(lsmod)" || sudo -n modprobe rndis_host 2>/dev/null
  for _ in $(seq 1 40); do ip link show usb0 >/dev/null 2>&1 && break; sleep 1; done
  if ip link show usb0 >/dev/null 2>&1; then
    sudo -n ip link set usb0 up 2>/dev/null
    for a in "${HOST_IPS[@]}"; do
      grep -q "${a%%/*}" <<< "$(ip addr show dev usb0)" || sudo -n ip addr add "$a" dev usb0 2>/dev/null
    done
    ok=0
    for ip in "${DEV_IPS[@]}"; do
      for _ in $(seq 1 30); do
        ping -c1 -W1 "$ip" >/dev/null 2>&1 && { ok=$((ok+1)); break; }
        sleep 2
      done
    done
    [[ "$ok" -eq 2 ]] && net_ok="yes"
  fi

  body=""
  for _ in $(seq 1 20); do
    body="$(timeout 6 curl -fsS --max-time 5 http://10.15.19.82:8080/ 2>/dev/null || true)"
    [[ -n "$body" ]] && break
    sleep 3
  done
  if [[ -n "$body" ]]; then
    http_ok="yes"
    printf '%s\n' "$body" > "$OUT_DIR/status-${STAMP}.txt"
    uptime="$(sed -n '/--- uptime ---/{n;p;}' "$OUT_DIR/status-${STAMP}.txt" | tr -d '\r' | awk '{print $1}')"
    # The body is the device's whole status page and this script sets pipefail: a pipeline here would
    # read a writer's death as "the container is absent", which is the one verdict this trial exists to
    # report (docs/ubuntu-touch/136).
    if grep -q 'lxc-start' <<< "$body" && grep -q 'servicemanager' <<< "$body"; then
      container="running"
    else
      container="absent"
    fi
  fi
fi

# Did the netwatch watchdog see a stall in this boot? Only readable once the device is
# back in TWRP again, so it is best-effort here.
stall="not-read"
st="$(adb devices 2>/dev/null | awk -v s="$SER" '$1==s{print $2}')"
if [[ "$st" == "recovery" ]]; then
  verdict="$(adb -s "$SER" shell 'grep -E "STALL:|HEAL:|recovered on its own|netwatch start" /data/zl1-netwatch.log 2>/dev/null | tail -20' | tr -d '\r')"
  if [[ -n "$verdict" ]]; then
    stall="$(printf '%s\n' "$verdict" | grep -c 'STALL:') stall(s), $(printf '%s\n' "$verdict" | grep -c 'HEAL: re-asserting') heal(s)"
    printf '%s\n' "$verdict" > "$OUT_DIR/netwatch-${STAMP}.txt"
  else
    stall="no netwatch log"
  fi
fi

# One row per trial. Create the ledger with a header the first time.
if [[ ! -f "$LEDGER" ]]; then
  mkdir -p "$(dirname "$LEDGER")"
  {
    echo "# Stage 2.4 — cold-boot trials"
    echo
    echo "One row per power-on, appended by \`scripts/stage2-coldboot-trial.sh\`."
    echo "Stage 2.4 asks for three consecutive boots with the same result."
    echo
    echo "| # | UTC | gadget | ping | status page | container | uptime at status | netwatch | note |"
    echo "| ---: | --- | --- | --- | --- | --- | ---: | --- | --- |"
  } > "$LEDGER"
fi
n=$(( $(grep -c '^| [0-9]' "$LEDGER" || true) + 1 ))
printf '| %d | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
  "$n" "$STAMP" "$gadget" "$net_ok" "$http_ok" "$container" "${uptime:-—}" "$stall" "$NOTE" >> "$LEDGER"

echo
echo "gadget=$gadget ping=$net_ok http=$http_ok container=$container uptime=${uptime:-—} netwatch=$stall"
echo "appended row $n to $LEDGER"
[[ "$gadget" == yes && "$net_ok" == yes && "$http_ok" == yes ]]
