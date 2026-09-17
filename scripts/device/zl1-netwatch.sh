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
#     The heal escalates. First a plain enable=0/1, which re-enumerates the USB link and
#     resets the endpoints. If TX is still frozen after that, the function is unbound and
#     rebound, which frees and recreates the netdev — that is the only thing that clears
#     state held on the net_device itself, such as a transmit queue stopped by
#     netif_stop_queue. (Measured 2026-09-17: a host-side USBDEVFS_RESET re-enumerated the
#     device — its random host MAC changed — and the link was still dead, so a mere USB
#     reset is not enough.)
#
#     After either stage the device-side addresses are re-applied, because a rebound
#     netdev comes back with none and the host could not reach a device that had no IP.
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

# Put the device-side addresses back. The v63 keeper configures these at boot; if a heal
# destroys and recreates the netdev (stage B below), it comes back with no addresses, and
# the host would still not be able to reach the device even though the link was fixed.
restore_addrs() {
    for ifn in rndis0 usb0; do
        [ -e "/sys/class/net/$ifn" ] || continue
        ip link set "$ifn" up 2>/dev/null
        ip addr show dev "$ifn" 2>/dev/null | grep -q '192.168.2.15/' || ip addr add 192.168.2.15/24 dev "$ifn" 2>/dev/null
        ip addr show dev "$ifn" 2>/dev/null | grep -q '10.15.19.82/'  || ip addr add 10.15.19.82/24 dev "$ifn" 2>/dev/null
    done
}

# Stage A: a full USB re-enumeration. enable=0 disconnects the gadget from the bus and
# enable=1 brings it back, so the host sees a fresh USB session and the endpoints are
# reset. The netdev survives, so the static addresses stay.
heal_reenumerate() {
    log "HEAL A: enable=0/1 on the gadget"
    write_file "$ANDROID_USB/enable" 0
    sleep 2
    write_file "$ANDROID_USB/enable" 1
    sleep 3
    restore_addrs
}

# Stage B: unbind and rebind the function. This frees and recreates the netdev, which is
# the only thing that clears state living on the net_device itself — a transmit queue
# stopped by netif_stop_queue survives a mere USB reset, and the host confirmed that on
# 2026-09-17: a USBDEVFS_RESET re-enumerated the device (its random host MAC changed) and
# the link was still dead. Stage B is strictly stronger than anything reachable from the
# host.
heal_rebind_function() {
    log "HEAL B: unbind/rebind the rndis function"
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
    sleep 3
    restore_addrs
}

heal() {
    stage="$1"; reason="$2"
    [ -d "$ANDROID_USB" ] || { log "HEAL: $ANDROID_USB missing, cannot heal"; return 1; }
    log "HEAL $stage: reason=$reason state=$(cat $ANDROID_USB/state 2>/dev/null)"
    { echo "--- gadget status before heal $stage ---"; gadget_stats; } >> "$LOG" 2>&1

    if [ "$stage" = "A" ]; then heal_reenumerate; else heal_rebind_function; fi

    # Never leave the gadget disabled: if the sequence above failed part-way the device
    # would be unreachable, and only a physical power-cycle could bring it back.
    if [ "$(cat $ANDROID_USB/enable 2>/dev/null)" != "1" ]; then
        log "HEAL $stage: enable is not 1 — forcing it back on"
        write_file "$ANDROID_USB/enable" 1
    fi
    log "HEAL $stage: done; state=$(cat $ANDROID_USB/state 2>/dev/null) functions=$(cat $ANDROID_USB/functions 2>/dev/null) enable=$(cat $ANDROID_USB/enable 2>/dev/null) iface=$(ifname_stats)"
    return 0
}

# One-shot hardware snapshot, taken once the boot has settled. This is the evidence base
# for the Phase 5 usability items (display, touch, audio, sensors), collected on the same
# trip as the network samples so they do not each need their own boot.
HWCHECK_AFTER=120
hwcheck_done=0

hwcheck() {
    {
        echo "===== hwcheck uptime $(cat /proc/uptime) ====="
        echo "--- uname ---"; uname -a
        echo "--- cmdline ---"; cat /proc/cmdline
        echo "--- framebuffer ---"; cat /proc/fb 2>&1
        for d in /sys/class/graphics/*; do
            [ -e "$d/name" ] || continue
            echo "[$(basename "$d")] name=$(cat "$d/name" 2>/dev/null) state=$(cat "$d/state" 2>/dev/null)"
            echo "  virtual_size=$(cat "$d/virtual_size" 2>/dev/null) bpp=$(cat "$d/bits_per_pixel" 2>/dev/null) blank=$(cat "$d/blank" 2>/dev/null)"
        done
        echo "--- drm ---"
        for d in /sys/class/drm/*/status; do
            [ -r "$d" ] && echo "$(dirname "$d" | xargs basename) $(cat "$d" 2>/dev/null)"
        done
        echo "--- backlight ---"
        for d in /sys/class/backlight/*; do
            [ -d "$d" ] || continue
            echo "$(basename "$d") brightness=$(cat "$d/brightness" 2>/dev/null)/$(cat "$d/max_brightness" 2>/dev/null)"
        done
        echo "--- input devices ---"
        grep -E '^N: |^H: |^B: ' /proc/bus/input/devices 2>/dev/null | head -60
        echo "--- evtest present ---"; command -v evtest >/dev/null 2>&1 && echo yes || echo no
        echo "--- asound cards ---"; cat /proc/asound/cards 2>&1
        echo "--- iio devices ---"; ls /sys/bus/iio/devices 2>/dev/null | tr '\n' ' '; echo
        echo "--- thermal ---"
        for z in /sys/class/thermal/thermal_zone*/temp; do
            [ -r "$z" ] && printf '%s=%s ' "$(basename "$(dirname "$z")")" "$(cat "$z" 2>/dev/null)"
        done; echo
        echo "--- battery ---"
        for b in /sys/class/power_supply/*; do
            [ -d "$b" ] || continue
            echo "$(basename "$b") type=$(cat "$b/type" 2>/dev/null) capacity=$(cat "$b/capacity" 2>/dev/null) status=$(cat "$b/status" 2>/dev/null)"
        done
        echo "--- modules ---"; cat /proc/modules 2>/dev/null | head -40
    } >> "$LOG" 2>&1
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

    # A stall is specifically "the host is talking to us and we are not answering", so
    # the frozen counter only accrues while RX is also moving. Counting any period of
    # quiet TX as a stall would fire on an idle system — and a heal is disruptive
    # (stage B recreates the netdev), besides polluting the evidence we are collecting.
    if [ -n "$tx_p" ]; then
        if [ "$tx_p" = "$last_tx" ]; then
            if [ -n "$rx_p" ] && [ "$rx_p" != "$rx_at_last_tx" ]; then
                frozen=$((frozen + SAMPLE_INTERVAL))
            else
                frozen=0
            fi
        else
            if [ "$frozen" -ge "$STALL_SECONDS" ]; then
                log "HEAL: transmit recovered on its own after ${frozen}s frozen"
            fi
            frozen=0
            last_tx="$tx_p"
            rx_at_last_tx="$rx_p"
        fi
    fi

    uptime_s=$(cut -d' ' -f1 /proc/uptime 2>/dev/null | cut -d. -f1)
    if [ "$hwcheck_done" = "0" ] && [ "${uptime_s:-0}" -ge "$HWCHECK_AFTER" ]; then
        hwcheck
        hwcheck_done=1
    fi
    if [ "$HEAL_ENABLED" = "1" ] && [ "$heals" -lt "$MAX_HEALS" ] \
       && [ "$frozen" -ge "$STALL_SECONDS" ] && [ "${uptime_s:-0}" -ge "$SETTLE_SECONDS" ]; then
        log "STALL: tx_packets frozen at $tx_p for ${frozen}s while rx went $rx_at_last_tx -> $rx_p"
        { echo "--- stall evidence ---"; gadget_stats; } >> "$LOG" 2>&1
        # Escalate: the first heal of a boot re-enumerates, later ones rebind the
        # function. A stall that survives a re-enumeration needs the stronger one.
        if [ "$heals" -eq 0 ]; then heal A "tx-frozen-${frozen}s"; else heal B "tx-frozen-${frozen}s-still"; fi
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
