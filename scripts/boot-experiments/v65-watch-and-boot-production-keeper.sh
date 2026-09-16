#!/bin/bash
# V65 Production Keeper Watcher
# Based on V64 watcher — monitors RNDIS + SSH stability

set -euo pipefail

TARGET_SERIAL="33e80afe"
BOOT_IMAGE="/mnt/data/halium-zl1-candidates/halium-boot-zl1-v65-production-keeper.img"
TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
LOGFILE="/mnt/data/zl1-bb10/v65-production-keeper-boot-${TIMESTAMP}.log"
OUTDIR="/mnt/data/zl1-bb10/v65-production-keeper-boot-${TIMESTAMP}"

HOST_IP_192="192.168.2.100"
HOST_IP_10="10.15.19.100"
DEVICE_IP_192="192.168.2.15"
DEVICE_IP_10="10.15.19.82"

exec > >(tee -a "$LOGFILE") 2>&1

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }
adb_devs() { adb devices 2>/dev/null | awk 'NR>1 && NF>=2 {printf "%s:%s;", $1, $2}'; }
fb_devs() { fastboot devices 2>/dev/null | awk 'NF>=2 {printf "%s;", $1}'; }
usb_devs() {
    lsusb -v 2>/dev/null | awk '
    /^Bus.*Device.*ID/ {bus=$2; dev=$4; sub(/:$/,"",dev); id=$6; mfg=""; prod=""; ser=""}
    /iManufacturer/ {for(i=3;i<=NF;i++) mfg=mfg" "$i; sub(/^ /,"",mfg)}
    /iProduct/ {for(i=3;i<=NF;i++) prod=prod" "$i; sub(/^ /,"",prod)}
    /iSerial/ {for(i=3;i<=NF;i++) ser=ser" "$i; sub(/^ /,"",ser);
        printf "%s-%s %s manufacturer=%s product=%s serial=%s;", bus, dev, id, mfg, prod, ser
    }' | tr '\n' ' ' | sed 's/; /;/g; s/;$//'
}
usb0_state() { ip -o addr show usb0 2>/dev/null | awk '{printf "%s ", $2; for(i=3;i<=NF;i++) printf "%s ", $i}'; }
ping_check() { ping -c1 -W1 "$1" >/dev/null 2>&1 && echo yes || echo no; }
ssh_check() {
    timeout 2 bash -c "echo >/dev/tcp/$1/22" 2>/dev/null && echo open || echo closed
}
neigh_state() {
    ip neigh show dev usb0 2>/dev/null | awk '{printf "%s lladdr %s %s;", $1, $5, $NF}'
}

wait_for_target() {
    log "waiting for target $TARGET_SERIAL in adb or fastboot"
    local iter=0
    while [ $iter -lt 60 ]; do
        adb_list=$(adb_devs)
        fb_list=$(fb_devs)
        if echo "$adb_list" | grep -qF "$TARGET_SERIAL"; then
            log "target detected in adb state=$(echo "$adb_list" | grep -oP "${TARGET_SERIAL}:\K[^;]+")"
            return 0
        fi
        if echo "$fb_list" | grep -qF "$TARGET_SERIAL"; then
            log "target detected in fastboot"
            return 0
        fi
        if [ $((iter % 12)) -eq 0 ] && [ $iter -gt 0 ]; then
            log "waiting target iteration=$iter adb=[$adb_list] fb=[$fb_list] usb=[$(usb_devs)] usb0=[$(usb0_state)]"
        fi
        sleep 5
        iter=$((iter + 1))
    done
    log "ERROR: target not detected after 300s"
    return 1
}

reboot_to_fastboot() {
    log "attempting adb reboot bootloader"
    adb -s "$TARGET_SERIAL" reboot bootloader 2>/dev/null || true
    sleep 3
    local wait=0
    while [ $wait -lt 20 ]; do
        if fastboot devices 2>/dev/null | grep -qF "$TARGET_SERIAL"; then
            log "target in fastboot after ${wait}s"
            return 0
        fi
        sleep 1
        wait=$((wait + 1))
    done
    log "WARNING: fastboot not detected after reboot attempt"
    return 1
}

fastboot_boot_image() {
    log "fastboot booting $BOOT_IMAGE"
    fastboot -s "$TARGET_SERIAL" boot "$BOOT_IMAGE"
    local rc=$?
    log "fastboot boot rc=$rc"
    return $rc
}

log "V65 watcher start target=$TARGET_SERIAL image=$BOOT_IMAGE"
log "initial adb=[$(adb_devs)] fastboot=[$(fb_devs)] usb=[$(usb_devs)] usb0=[$(usb0_state)]"

if ! wait_for_target; then
    log "ABORT: target not found"
    exit 1
fi

adb_state=$(adb_devs | grep -oP "${TARGET_SERIAL}:\K[^;]+")
if [ "$adb_state" = "device" ] || [ "$adb_state" = "recovery" ]; then
    log "target adb detected state=$adb_state; rebooting target-only to bootloader"
    reboot_to_fastboot || true
    sleep 5
fi

if ! fastboot devices 2>/dev/null | grep -qF "$TARGET_SERIAL"; then
    log "ERROR: target not in fastboot mode"
    exit 1
fi

log "target fastboot detected; fastboot boot V65"
if ! fastboot_boot_image; then
    log "ERROR: fastboot boot failed"
    exit 1
fi

log "===== PHASE 2: Monitor RNDIS stability ====="
sleep 15

sample_num=0
reachable_count=0
lost_streak=0
max_stable=0
ssh_ok=0

while true; do
    sample_num=$((sample_num + 1))

    adb_now=$(adb_devs)
    fb_now=$(fb_devs)
    usb_now=$(usb_devs)
    usb0_now=$(usb0_state)
    ping192=$(ping_check "$DEVICE_IP_192")
    ping10=$(ping_check "$DEVICE_IP_10")
    ssh22=$(ssh_check "$DEVICE_IP_192")
    neigh=$(neigh_state)

    if [ "$ping192" = "yes" ] || [ "$ping10" = "yes" ]; then
        reachable_count=$((reachable_count + 1))
        lost_streak=0
        if [ $reachable_count -gt $max_stable ]; then
            max_stable=$reachable_count
        fi
    else
        lost_streak=$((lost_streak + 1))
    fi

    if [ "$ssh22" = "open" ]; then
        ssh_ok=$((ssh_ok + 1))
    fi

    log "SAMPLE $(printf '%03d' $sample_num) adb=[$adb_now] fb=[$fb_now] usb=[${usb_now:0:200}] usb0=[${usb0_now:0:100}] ping192=$ping192 ping10=$ping10 ssh22=$ssh22 neigh=[$neigh] reachable_count=$reachable_count lost_streak=$lost_streak ssh_ok=$ssh_ok"

    if [ $reachable_count -ge 100 ]; then
        log "SUCCESS: V65 RNDIS stable for 100+ samples"
        log "FINAL reachable_count=$reachable_count max_stable=$max_stable ssh_ok=$ssh_ok lost_streak=$lost_streak"
        log "log=$LOGFILE outdir=$OUTDIR"
        mkdir -p "$OUTDIR"
        echo "V65 SUCCESS: stable RNDIS" > "$OUTDIR/result.txt"
        exit 0
    fi

    if [ $lost_streak -ge 15 ]; then
        log "FAILURE: V65 RNDIS lost after $reachable_count reachable samples"
        log "FINAL reachable_count=$reachable_count max_stable=$max_stable ssh_ok=$ssh_ok lost_streak=$lost_streak"
        log "log=$LOGFILE outdir=$OUTDIR"
        mkdir -p "$OUTDIR"
        echo "V65 FAILED: lost after $reachable_count" > "$OUTDIR/result.txt"
        exit 1
    fi

    sleep 4
done
