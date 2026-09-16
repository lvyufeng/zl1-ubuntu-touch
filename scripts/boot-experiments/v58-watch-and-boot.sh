#!/usr/bin/env bash
set +e
SER="33e80afe"
IMG="/mnt/data/halium-zl1-candidates/halium-boot-zl1-filtered-dtb-postswitch-debug-v58-v54-repack-control.img"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTDIR="/mnt/data/zl1-bb10/v58-v54-repack-control-boot-${STAMP}"
LOG="${OUTDIR}.log"
mkdir -p "$OUTDIR" 2>/dev/null || true
log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }
adb_has_target() { timeout 5 adb devices 2>/dev/null | awk -v s="$SER" '$1==s {found=1} END{exit found?0:1}'; }
fb_has_target() { timeout 5 fastboot devices 2>/dev/null | awk -v s="$SER" '$1==s {found=1} END{exit found?0:1}'; }
adb_state() { timeout 5 adb -s "$SER" get-state 2>/dev/null | tr -d '\r'; }
usb_summary() { python3 - <<'PYUSB'
import os
base='/sys/bus/usb/devices'; rows=[]
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
    timeout 4 curl -fsS --max-time 3 "$url" 2>/dev/null || true
}
port_open() { timeout 2 bash -c "</dev/tcp/$1/$2" >/dev/null 2>&1; }
collect_android_fallback() {
    AOUT="/mnt/data/zl1-bb10/v58-postfallback-adb-$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$AOUT"
    {
      echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo '--- adb devices ---'; adb devices
      echo '--- get-state ---'; adb -s "$SER" get-state
      echo '--- getprop selected ---'; adb -s "$SER" shell 'for p in ro.bootmode ro.boot.bootreason ro.hardware ro.product.device ro.product.model ro.build.version.release ro.build.version.sdk sys.boot_completed; do echo "$p=$(getprop $p)"; done' 2>&1
      echo '--- uname/cmdline ---'; adb -s "$SER" shell 'uname -a; cat /proc/cmdline' 2>&1
      echo '--- pstore list ---'; adb -s "$SER" shell 'ls -l /sys/fs/pstore 2>/dev/null || true' 2>&1
    } > "$AOUT/basic.txt" 2>&1
    adb -s "$SER" exec-out 'cat /sys/fs/pstore/console-ramoops 2>/dev/null' > "$AOUT/console-ramoops.txt" 2>"$AOUT/console-ramoops.err" || true
    sha256sum "$AOUT"/* > "$AOUT/SHA256SUMS" 2>/dev/null || true
    log "collected postfallback adb diagnostics to $AOUT"
}
log "V58 watcher start target=$SER image=$IMG"
log "initial adb=[$(timeout 5 adb devices 2>/dev/null | tr '\n' ';')] fastboot=[$(timeout 5 fastboot devices 2>/dev/null | tr '\n' ';')] usb=[$(usb_summary)]"
booted=0
for i in $(seq 1 120); do
    if fb_has_target; then
        log "target fastboot detected iteration=$i; fastboot boot V58 only"
        timeout 90 fastboot -s "$SER" boot "$IMG" >>"$LOG" 2>&1; rc=$?; log "fastboot boot rc=$rc"; booted=1; break
    fi
    if adb_has_target; then
        st="$(adb_state)"; log "target adb detected state=${st:-unknown}; rebooting target-only to bootloader"
        timeout 20 adb -s "$SER" reboot bootloader >>"$LOG" 2>&1 || true
        for j in $(seq 1 35); do
            if fb_has_target; then
                log "target fastboot detected after adb reboot; fastboot boot V58 only"
                timeout 90 fastboot -s "$SER" boot "$IMG" >>"$LOG" 2>&1; rc=$?; log "fastboot boot rc=$rc"; booted=1; break 2
            fi
            sleep 1
        done
    fi
    [ $((i%12)) -eq 0 ] && log "waiting target iteration=$i adb=[$(timeout 5 adb devices 2>/dev/null | tr '\n' ';')] fb=[$(timeout 5 fastboot devices 2>/dev/null | tr '\n' ';')] usb=[$(usb_summary)]"
    sleep 5
done
if [ "$booted" != 1 ]; then log "target not seen; no boot attempted"; exit 3; fi
reachable_count=0; lost_after_reachable=0; lost_streak=0; android_adb_seen=0
for s in $(seq -w 1 180); do
    configure_host_usb0
    adbline="$(timeout 5 adb devices 2>/dev/null | awk 'NR>1 && NF{printf "%s:%s;",$1,$2}')"
    fbline="$(timeout 5 fastboot devices 2>/dev/null | awk 'NF{printf "%s:%s;",$1,$2}')"
    usbline="$(usb_summary)"
    ipline="$(ip -br addr show usb0 2>/dev/null | tr '\n' ' ')"
    neigh="$(ip neigh show dev usb0 2>/dev/null | tr '\n' ';')"
    ping192=no; ping10=no; http192=no; http10=no; telnet23=closed
    ping -c1 -W1 192.168.2.15 >/dev/null 2>&1 && ping192=yes
    ping -c1 -W1 10.15.19.82 >/dev/null 2>&1 && ping10=yes
    body192="$(http_get http://192.168.2.15:8080/status.txt)"; [ -n "$body192" ] || body192="$(http_get http://192.168.2.15:8081/)"
    body10="$(http_get http://10.15.19.82:8080/status.txt)"; [ -n "$body10" ] || body10="$(http_get http://10.15.19.82:8081/)"
    [ -n "$body192" ] && { http192=yes; printf '%s' "$body192" > "$OUTDIR/status-${s}-192.txt"; }
    [ -n "$body10" ] && { http10=yes; printf '%s' "$body10" > "$OUTDIR/status-${s}-10.txt"; }
    port_open 192.168.2.15 23 && telnet23=open
    if [ "$ping192" = yes ] || [ "$ping10" = yes ] || [ "$http192" = yes ] || [ "$http10" = yes ]; then reachable_count=$((reachable_count+1)); lost_streak=0; elif [ "$reachable_count" -gt 0 ]; then lost_after_reachable=1; lost_streak=$((lost_streak+1)); fi
    snip192="$(printf '%s' "$body192" | tr '\n' ' ' | cut -c1-220)"
    log "SAMPLE $s adb=[$adbline] fb=[$fbline] usb=[$usbline] usb0=[$ipline] ping192=$ping192 ping10=$ping10 telnet23=$telnet23 http192=$http192 http10=$http10 neigh=[$neigh] h192=[$snip192] reachable_count=$reachable_count lost_streak=$lost_streak"
    case "$adbline:$usbline" in *33e80afe:device*Android*|*33e80afe:device*LEX727*) android_adb_seen=$((android_adb_seen+1));; esac
    if [ "$android_adb_seen" -ge 3 ] && [ "$reachable_count" -eq 0 ]; then log "normal Android ADB returned without V58 RNDIS; collecting fallback diagnostics"; collect_android_fallback; break; fi
    if [ "$reachable_count" -ge 100 ] && [ "$lost_after_reachable" = 0 ]; then log "V58 remained reachable long window"; break; fi
    if [ "$lost_streak" -ge 15 ]; then log "V58 lost RNDIS after reachable"; break; fi
    sleep 3
done
log "reachable_count=$reachable_count lost_after_reachable=$lost_after_reachable final adb=[$(timeout 5 adb devices 2>/dev/null | awk 'NR>1 && NF{printf "%s:%s;",$1,$2}')] fb=[$(timeout 5 fastboot devices 2>/dev/null | awk 'NF{printf "%s:%s;",$1,$2}')] usb=[$(usb_summary)]"
log "log=$LOG outdir=$OUTDIR"
