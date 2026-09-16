#!/usr/bin/env bash
set +e
SER="33e80afe"
IMG="/mnt/data/halium-zl1-candidates/halium-boot-zl1-filtered-dtb-postswitch-debug-v55-android-usb-attribution.img"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTDIR="/mnt/data/zl1-bb10/v55-android-usb-attribution-boot-${STAMP}"
LOG="${OUTDIR}.log"
mkdir -p "$OUTDIR" 2>/dev/null || true
log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }
runlog() { log "RUN $*"; timeout 60 "$@" >>"$LOG" 2>&1; rc=$?; log "RC $rc for $*"; return $rc; }
adb_has_target() { timeout 5 adb devices 2>/dev/null | awk -v s="$SER" '$1==s {found=1} END{exit found?0:1}'; }
fb_has_target() { timeout 5 fastboot devices 2>/dev/null | awk -v s="$SER" '$1==s {found=1} END{exit found?0:1}'; }
adb_state() { timeout 5 adb -s "$SER" get-state 2>/dev/null | tr -d '\r'; }
usb_summary() {
python3 - <<'PYUSB'
import os
base='/sys/bus/usb/devices'
rows=[]
try: devs=sorted(os.listdir(base))
except Exception: devs=[]
for d in devs:
    p=os.path.join(base,d); vals={}
    for f in ('idVendor','idProduct','manufacturer','product','serial'):
        try: vals[f]=open(os.path.join(p,f)).read().strip()
        except Exception: vals[f]=''
    if vals.get('idVendor') in ('18d1','05c6') or vals.get('serial') in ('33e80afe','4a2fe00b') or vals.get('manufacturer')=='Halium':
        rows.append('%s %s:%s manufacturer=%s product=%s serial=%s' % (d, vals.get('idVendor'), vals.get('idProduct'), vals.get('manufacturer'), vals.get('product'), vals.get('serial')))
print(';'.join(rows))
PYUSB
}
configure_host_usb0() {
    if ip link show usb0 >/dev/null 2>&1; then
        ip link set usb0 up >>"$LOG" 2>&1 || true
        ip addr show dev usb0 2>/dev/null | grep -q '192\.168\.2\.100/' || ip addr add 192.168.2.100/24 dev usb0 >>"$LOG" 2>&1 || true
        ip addr show dev usb0 2>/dev/null | grep -q '10\.15\.19\.100/' || ip addr add 10.15.19.100/24 dev usb0 >>"$LOG" 2>&1 || true
    fi
}
http_get() {
    url="$1"
    if command -v curl >/dev/null 2>&1; then
        timeout 4 curl -fsS --max-time 3 "$url" 2>/dev/null
    else
        python3 - "$url" <<'PYHTTP'
import sys, urllib.request
try:
    print(urllib.request.urlopen(sys.argv[1], timeout=3).read().decode('utf-8','replace'))
except Exception:
    sys.exit(1)
PYHTTP
    fi
}
port_open() { timeout 2 bash -c "</dev/tcp/$1/$2" >/dev/null 2>&1; }
log "V55 watcher start target=$SER image=$IMG"
if [ ! -f "$IMG" ]; then log "missing image $IMG"; exit 2; fi
log "initial adb=[$(timeout 5 adb devices 2>/dev/null | tr '\n' ';')] fastboot=[$(timeout 5 fastboot devices 2>/dev/null | tr '\n' ';')] usb=[$(usb_summary)]"
booted=0
for i in $(seq 1 120); do
    if fb_has_target; then
        log "target fastboot detected on iteration=$i; booting V55 with fastboot boot only"
        timeout 90 fastboot -s "$SER" boot "$IMG" >>"$LOG" 2>&1
        rc=$?
        log "fastboot boot rc=$rc"
        booted=1
        break
    fi
    if adb_has_target; then
        st="$(adb_state)"
        log "target adb detected state=${st:-unknown}; rebooting target-only to bootloader"
        timeout 20 adb -s "$SER" reboot bootloader >>"$LOG" 2>&1 || true
        for j in $(seq 1 30); do
            if fb_has_target; then
                log "target fastboot detected after adb reboot; booting V55 with fastboot boot only"
                timeout 90 fastboot -s "$SER" boot "$IMG" >>"$LOG" 2>&1
                rc=$?
                log "fastboot boot rc=$rc"
                booted=1
                break 2
            fi
            sleep 1
        done
        log "target did not enter fastboot yet after adb reboot; continuing wait"
    fi
    if [ $((i % 12)) -eq 0 ]; then
        log "waiting for target $SER (iteration=$i) adb=[$(timeout 5 adb devices 2>/dev/null | tr '\n' ';')] fb=[$(timeout 5 fastboot devices 2>/dev/null | tr '\n' ';')] usb=[$(usb_summary)]"
    fi
    sleep 5
done
if [ "$booted" != 1 ]; then
    log "target $SER not seen in adb/fastboot before watcher timeout; no boot attempted"
    log "log=$LOG outdir=$OUTDIR"
    exit 3
fi
# Wait for RNDIS descriptor/interface and monitor.
reachable_count=0
lost_after_reachable=0
lost_streak=0
for s in $(seq -w 1 160); do
    configure_host_usb0
    adbline="$(timeout 5 adb devices 2>/dev/null | awk 'NR>1 && NF{printf "%s:%s;",$1,$2}')"
    fbline="$(timeout 5 fastboot devices 2>/dev/null | awk 'NF{printf "%s:%s;",$1,$2}')"
    usbline="$(usb_summary)"
    ipline="$(ip -br addr show usb0 2>/dev/null | tr '\n' ' ')"
    neigh="$(ip neigh show dev usb0 2>/dev/null | tr '\n' ';')"
    ping192=no; ping10=no; http192=no; http10=no; telnet23=closed
    ping -c1 -W1 192.168.2.15 >/dev/null 2>&1 && ping192=yes
    ping -c1 -W1 10.15.19.82 >/dev/null 2>&1 && ping10=yes
    body192=""; body10=""
    body192="$(http_get http://192.168.2.15:8080/status.txt 2>/dev/null || http_get http://192.168.2.15:8081/ 2>/dev/null || true)"
    if [ -n "$body192" ]; then http192=yes; printf '%s' "$body192" > "$OUTDIR/status-${s}-192.txt"; fi
    body10="$(http_get http://10.15.19.82:8080/status.txt 2>/dev/null || http_get http://10.15.19.82:8081/ 2>/dev/null || true)"
    if [ -n "$body10" ]; then http10=yes; printf '%s' "$body10" > "$OUTDIR/status-${s}-10.txt"; fi
    port_open 192.168.2.15 23 && telnet23=open
    if [ "$ping192" = yes ] || [ "$ping10" = yes ] || [ "$http192" = yes ] || [ "$http10" = yes ]; then
        reachable_count=$((reachable_count+1)); lost_streak=0
    elif [ "$reachable_count" -gt 0 ]; then
        lost_after_reachable=1; lost_streak=$((lost_streak+1))
    fi
    snip192="$(printf '%s' "$body192" | tr '\n' ' ' | cut -c1-260)"
    snip10="$(printf '%s' "$body10" | tr '\n' ' ' | cut -c1-160)"
    log "SAMPLE $s adb=[$adbline] fb=[$fbline] usb=[$usbline] usb0=[$ipline] ping192=$ping192 ping10=$ping10 telnet23=$telnet23 http192=$http192 http10=$http10 neigh=[$neigh] h192=[$snip192] h10=[$snip10] reachable_count=$reachable_count lost_streak=$lost_streak"
    if [ "$reachable_count" -ge 100 ] && [ "$lost_after_reachable" = 0 ]; then
        log "V55 remained reachable for long stability window; stopping sampling"
        break
    fi
    if [ "$lost_streak" -ge 15 ]; then
        log "V55 lost RNDIS/data plane after being reachable; stopping sampling"
        break
    fi
    sleep 3
done
log "reachable_count=$reachable_count lost_after_reachable=$lost_after_reachable final adb=[$(timeout 5 adb devices 2>/dev/null | awk 'NR>1 && NF{printf "%s:%s;",$1,$2}')] fb=[$(timeout 5 fastboot devices 2>/dev/null | awk 'NF{printf "%s:%s;",$1,$2}')] usb=[$(usb_summary)]"
log "log=$LOG outdir=$OUTDIR"
