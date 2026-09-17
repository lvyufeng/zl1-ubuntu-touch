#!/bin/sh
# zl1 network watchdog — runs on the device, records evidence and self-heals.
#
# Two jobs, one service, because they need the same samples:
#
#  1. Record. Every SAMPLE_INTERVAL seconds, append the state that matters for the
#     intermittent transmit stall: the gadget's own stats (/sys/kernel/debug/rndis/
#     status -> tx_pkts_rcvd, tx_qlen, tx_throttle), the interface counters, the qdisc
#     state and the routing/ARP tables. Written to /userdata/zl1-netwatch.log, which is
#     on the persistent partition, so it survives the boot that went wrong.
#
#  2. Heal. About 1 boot in 4, the device ends up able to receive but not transmit:
#     rndis0 keeps taking host ARP requests while its tx counter freezes, and it never
#     recovers on its own (the transmit queue stays stopped). Measured 2026-09-17: 6 of
#     8 boots carried 0.3-1.9 MB, 2 carried ~4 KB and never moved again. See
#     docs/ubuntu-touch/22-stage2-coldboot-results.md section 5.
#
#     When that is detected, re-assert the RNDIS gadget — the same sysfs sequence the
#     v63 keeper already runs (enable=0, clear functions, set descriptors, functions=
#     rndis, enable=1). Re-enumerating resets the endpoints and clears the stopped
#     transmit queue, so the host gets a fresh USB session.
#
# Nothing here writes to a partition. The only side effect outside this script's own log
# is the gadget re-assert, which is what the boot image already does by itself.
#
# Installed by scripts/install-netwatch-service.sh. Do not edit on the device.

LOG=/userdata/zl1-netwatch.log
ANDROID_USB=/sys/class/android_usb/android0
IFACE=rndis0

SAMPLE_INTERVAL=2
STALL_SECONDS=45          # TX must be frozen this long while RX moves, to declare a stall
SETTLE_SECONDS=90         # never act before the boot has settled this long
HEAL_RETRY_SECONDS=25     # wait this long after a heal before judging it
MAX_HEALS=8               # per boot

# 0 = record only, do not touch the gadget. Set to 1 by a marker file, or by default
# below, so the recorder alone can be used when a heal would spoil an experiment.
HEAL_ENABLED=1
[ -r /userdata/zl1-netwatch-noheal ] && HEAL_ENABLED=0

# Optional: after this many seconds, ask the bootloader to reboot into recovery, so the
# log can be read without anyone holding a button. Off unless the marker file exists.
# Writing "boot-recovery" into misc is exactly what Android's own `reboot recovery`
# does; the bootloader ignores anything it does not recognise.
RECOVERY_AFTER_FILE=/userdata/zl1-netwatch-reboot-recovery
RECOVERY_AFTER=0
[ -r "$RECOVERY_AFTER_FILE" ] && RECOVERY_AFTER=$(cat "$RECOVERY_AFTER_FILE" 2>/dev/null || echo 0)
case "$RECOVERY_AFTER" in *[!0-9]*|"") RECOVERY_AFTER=0 ;; esac

log() { echo "$(cat /proc/uptime 2>/dev/null | cut -d' ' -f1)s $*" >> "$LOG"; }

ifname_stats() {
    # -> "rx_bytes rx_pkts tx_bytes tx_pkts"
    awk -v i="$IFACE:" '$1==i{print $2, $3, $10, $11}' /proc/net/dev 2>/dev/null
}

gadget_stats() {
    # The gadget's own counters live in debugfs (u_ether.c uether_stat_show). The
    # directory is named after the netdev the function registered, which is "rndis"
    # for f_rndis — but do not rely on that, search for the file.
    for d in /sys/kernel/debug/rndis /sys/kernel/debug/usb0 /sys/kernel/debug/eth; do
        [ -r "$d/status" ] || continue
        echo "[$d]"; cat "$d/status" 2>/dev/null
        echo "tx_bytes_rcvd=$(cat "$d/tx_bytes_rcvd" 2>/dev/null)"
        return 0
    done
    for s in /sys/kernel/debug/*/status; do
        [ -r "$s" ] || continue
        grep -q 'tx_qlen' "$s" 2>/dev/null || continue
        echo "[$s]"; cat "$s" 2>/dev/null
        echo "tx_bytes_rcvd=$(cat "${s%status}tx_bytes_rcvd" 2>/dev/null)"
        return 0
    done
    echo "(no uether debugfs status file; /sys/kernel/debug mounted=$([ -d /sys/kernel/debug ] && echo yes || echo no), entries: $(ls /sys/kernel/debug 2>/dev/null | tr '\n' ' '))"
}

sample() {
    {
        echo "===== uptime $(cat /proc/uptime) ====="
        echo "--- iface ---"; ifname_stats
        echo "--- gadget ---"; gadget_stats
        echo "--- ip -s -s ---"; ip -s -s link show "$IFACE" 2>&1 | head -20
        echo "--- addr ---";     ip -br addr show "$IFACE" 2>&1
        echo "--- route ---";    ip route show 2>&1
        echo "--- arp ---";      cat /proc/net/arp 2>&1
        echo "--- counters ---"
        for f in tx_dropped tx_errors tx_aborted_errors rx_dropped rx_errors; do
            printf '%s=%s ' "$f" "$(cat /sys/class/net/$IFACE/statistics/$f 2>/dev/null)"
        done
        echo
        if pgrep -f lxc-start >/dev/null 2>&1; then echo "lxc-start: RUNNING"; else echo "lxc-start: absent"; fi
        if ping -c1 -W1 192.168.2.100 >/dev/null 2>&1; then echo "host-ping: OK"; else echo "host-ping: FAIL"; fi
    } >> "$LOG" 2>&1
}

write_file() { echo "$2" > "$1" 2>/dev/null || return 1; }

reassert_gadget() {
    reason="$1"
    [ -d "$ANDROID_USB" ] || { log "HEAL: $ANDROID_USB missing, cannot re-assert"; return 1; }
    log "HEAL: re-asserting RNDIS reason=$reason (state=$(cat $ANDROID_USB/state 2>/dev/null))"
    { echo "--- gadget status before heal ---"; gadget_stats; } >> "$LOG" 2>&1

    write_file "$ANDROID_USB/enable" 0
    sleep 1
    write_file "$ANDROID_USB/functions" ""
    write_file "$ANDROID_USB/idVendor" 18D1
    write_file "$ANDROID_USB/idProduct" D001
    write_file "$ANDROID_USB/iManufacturer" "Halium"
    write_file "$ANDROID_USB/iProduct" "zl1 V63 usbd-disabled RNDIS"
    write_file "$ANDROID_USB/iSerial" "33e80afe-v63-usbd-disabled-rndis"
    write_file "$ANDROID_USB/f_rndis/ethaddr" "02:15:19:82:00:01"
    write_file "$ANDROID_USB/f_rndis/vendorID" 18D1
    write_file "$ANDROID_USB/f_rndis/manufacturer" "Halium"
    write_file "$ANDROID_USB/f_rndis/wceis" 1
    write_file "$ANDROID_USB/functions" rndis
    sleep 1
    write_file "$ANDROID_USB/enable" 1

    sleep 2
    # Never leave the gadget disabled: if the sequence above failed part-way the device
    # would be unreachable, and only a physical power-cycle could bring it back.
    if [ "$(cat $ANDROID_USB/enable 2>/dev/null)" != "1" ]; then
        log "HEAL: enable is not 1 after re-assert — forcing it back on"
        write_file "$ANDROID_USB/enable" 1
    fi
    log "HEAL: done; state=$(cat $ANDROID_USB/state 2>/dev/null) functions=$(cat $ANDROID_USB/functions 2>/dev/null) enable=$(cat $ANDROID_USB/enable 2>/dev/null) iface=$(ifname_stats)"
    return 0
}

log "netwatch start pid=$$ heal=$HEAL_ENABLED stall=${STALL_SECONDS}s max_heals=$MAX_HEALS recovery_after=${RECOVERY_AFTER}s cmdline=$(cat /proc/cmdline)"
{ echo "--- boot ---"; cat /proc/cmdline; } >> "$LOG" 2>&1

i=0
heals=0
last_tx=""
frozen=0
rx_at_last_tx=""

while :; do
    i=$((i + 1))
    sample

    # Only judge health from a sample taken while the interface exists.
    set -- $(ifname_stats)
    rx_b="$1"; rx_p="$2"; tx_b="$3"; tx_p="$4"

    if [ -n "$tx_p" ]; then
        if [ "$tx_p" = "$last_tx" ]; then
            frozen=$((frozen + SAMPLE_INTERVAL))
        else
            if [ "$frozen" -ge "$STALL_SECONDS" ]; then
                log "HEAL: recovered on its own after ${frozen}s frozen"
            fi
            frozen=0
            last_tx="$tx_p"
            rx_at_last_tx="$rx_p"
        fi
    fi

    uptime_s=$(cut -d' ' -f1 /proc/uptime 2>/dev/null | cut -d. -f1)
    if [ "$HEAL_ENABLED" = "1" ] && [ "$heals" -lt "$MAX_HEALS" ] \
       && [ "$frozen" -ge "$STALL_SECONDS" ] && [ "${uptime_s:-0}" -ge "$SETTLE_SECONDS" ]; then
        log "STALL: tx_packets frozen at $tx_p for ${frozen}s while rx went $rx_at_last_tx -> $rx_p"
        { echo "--- stall evidence ---"; gadget_stats; } >> "$LOG" 2>&1
        reassert_gadget "tx-frozen-${frozen}s"
        heals=$((heals + 1))
        log "HEAL: attempt $heals/$MAX_HEALS done; sleeping ${HEAL_RETRY_SECONDS}s before judging"
        sleep "$HEAL_RETRY_SECONDS"
        # Give the heal a fresh baseline so a successful reset is not immediately
        # re-flagged as the same stall.
        set -- $(ifname_stats)
        last_tx="$4"
        rx_at_last_tx="$2"
        frozen=0
        continue
    fi

    if [ "$RECOVERY_AFTER" -gt 0 ] && [ "${uptime_s:-0}" -ge "$RECOVERY_AFTER" ]; then
        log "RECOVERY: uptime ${uptime_s}s >= ${RECOVERY_AFTER}s — asking the bootloader for recovery"
        for blk in /dev/block/bootdevice/by-name/misc /dev/block/sda4; do
            [ -e "$blk" ] || continue
            if printf 'boot-recovery' > "$blk" 2>/dev/null; then
                sync
                log "RECOVERY: wrote boot-recovery to $blk"
                reboot
                sleep 300
            fi
        done
        log "RECOVERY: could not write the bootloader command; doing a plain reboot"
        sync
        reboot
        sleep 300
    fi

    sleep "$SAMPLE_INTERVAL"
done
