#!/usr/bin/env bash
set +e
SER="33e80afe"
IMG="/mnt/data/halium-zl1-candidates/halium-boot-zl1-v64-production-no-android.img"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTDIR="/mnt/data/zl1-bb10/v64-production-boot-${STAMP}"
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
    ip link show usb0 >/dev/null 2>&1 || return 1
    if sudo -n true >/dev/null 2>&1; then
        sudo ip link set usb0 up >>"$LOG" 2>&1 || true
        ip addr show dev usb0 2>/dev/null | grep -q '192\.168\.2\.100/' || sudo ip addr add 192.168.2.100/24 dev usb0 >>"$LOG" 2>&1 || true
        ip addr show dev usb0 2>/dev/null | grep -q '10\.15\.19\.100/' || sudo ip addr add 10.15.19.100/24 dev usb0 >>"$LOG" 2>&1 || true
    fi
    return 0
}
log "V64 production watcher start target=$SER image=$IMG"
log "initial adb=[$(timeout 5 adb devices 2>/dev/null | tr '\n' ';')] fastboot=[$(timeout 5 fastboot devices 2>/dev/null | tr '\n' ';')] usb=[$(usb_summary)]"

# Phase 1: wait for target and boot
booted=0
for i in $(seq 1 8640); do
    if fb_has_target; then
        log "target fastboot detected iteration=$i; fastboot boot V64"
        timeout 90 fastboot -s "$SER" boot "$IMG" >>"$LOG" 2>&1; rc=$?; log "fastboot boot rc=$rc"; booted=1; break
    fi
    if adb_has_target; then
        st="$(adb_state)"; log "target adb detected state=${st:-unknown}; rebooting to bootloader"
        timeout 20 adb -s "$SER" reboot bootloader >>"$LOG" 2>&1 || true
        for j in $(seq 1 45); do
            if fb_has_target; then
                log "target fastboot detected after adb reboot; fastboot boot V64"
                timeout 90 fastboot -s "$SER" boot "$IMG" >>"$LOG" 2>&1; rc=$?; log "fastboot boot rc=$rc"; booted=1; break 2
            fi
            sleep 1
        done
    fi
    if [ $((i%12)) -eq 0 ]; then
        log "waiting target iteration=$i adb=[$(timeout 5 adb devices 2>/dev/null | tr '\n' ';')] fb=[$(timeout 5 fastboot devices 2>/dev/null | tr '\n' ';')] usb=[$(usb_summary)]"
    fi
    sleep 5
done
if [ "$booted" != 1 ]; then log "target not seen; no boot attempted"; exit 3; fi

# Phase 2: validate RNDIS stability + SSH (production: longer observation, less intrusive)
log "V64 booted; monitoring RNDIS stability for production validation"
reachable_count=0; lost_streak=0; ssh_ok=0; max_stable=0
for s in $(seq -w 1 200); do
    configure_host_usb0 || true
    usbline="$(usb_summary)"
    ipline="$(ip -br addr show usb0 2>/dev/null | tr '\n' ' ')"
    ping192=no; ping10=no; ssh22=closed
    ping -c1 -W1 192.168.2.15 >/dev/null 2>&1 && ping192=yes
    ping -c1 -W1 10.15.19.82 >/dev/null 2>&1 && ping10=yes
    timeout 2 bash -c "</dev/tcp/192.168.2.15/22" >/dev/null 2>&1 && ssh22=open
    if [ "$ping192" = yes ] || [ "$ping10" = yes ]; then
        reachable_count=$((reachable_count+1)); lost_streak=0
        [ "$reachable_count" -gt "$max_stable" ] && max_stable=$reachable_count
    elif [ "$reachable_count" -gt 0 ]; then
        lost_streak=$((lost_streak+1))
    fi
    [ "$ssh22" = open ] && ssh_ok=$((ssh_ok+1))
    log "SAMPLE $s usb=[$usbline] usb0=[$ipline] ping192=$ping192 ping10=$ping10 ssh22=$ssh22 reachable_count=$reachable_count lost_streak=$lost_streak ssh_ok=$ssh_ok"
    # Production success: stable for 100 samples (~8 minutes)
    if [ "$reachable_count" -ge 100 ]; then log "V64 PRODUCTION SUCCESS: RNDIS stable for 100+ samples ssh_ok=$ssh_ok"; break; fi
    # Failure: lost after being reachable
    if [ "$lost_streak" -ge 15 ]; then log "V64 RNDIS LOST after reachable max_stable=$max_stable (regression from V54?)"; break; fi
    sleep 5
done
log "FINAL reachable_count=$reachable_count max_stable=$max_stable ssh_ok=$ssh_ok lost_streak=$lost_streak"
log "log=$LOG outdir=$OUTDIR"
