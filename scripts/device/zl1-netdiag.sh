#!/bin/sh
# zl1 network diagnostic sampler — runs on the device, writes to persistent storage.
#
# Why this exists: the device exposes RNDIS only (no adb), the HTTP status page is
# read-only, and the useful window is about 30 seconds. Whatever answers "why does the
# RNDIS transmit path stop" has to be recorded on the device and read afterwards.
#
# It samples the interface, the queue state and the routing/ARP tables every 2 seconds
# into /userdata/zl1-netdiag.log, which survives reboots. Read it from TWRP.
#
# Installed by scripts/install-netdiag-service.sh. Do not edit on the device.

LOG=/userdata/zl1-netdiag.log
INTERVAL=2
ITERATIONS=1800          # ~1 hour at 2 s

# Optional: after this many seconds, ask the bootloader to reboot into recovery so the
# log can be read without anyone holding a button. Off unless the marker file exists.
# Writing "boot-recovery" to the misc partition is exactly what Android's own
# `reboot recovery` does; the bootloader ignores anything it does not understand.
RECOVERY_AFTER_FILE=/userdata/zl1-netdiag-reboot-recovery
RECOVERY_AFTER=0
[ -r "$RECOVERY_AFTER_FILE" ] && RECOVERY_AFTER=$(cat "$RECOVERY_AFTER_FILE" 2>/dev/null || echo 0)

reboot_to_recovery() {
    echo "zl1-netdiag: asking the bootloader for recovery at uptime $(cat /proc/uptime)" >> "$LOG"
    for p in /dev/block/bootdevice/by-name/misc /dev/block/sda4; do
        [ -e "$p" ] || continue
        printf 'boot-recovery' > "$p" 2>/dev/null && sync && reboot && return 0
    done
    echo "zl1-netdiag: could not set the bootloader command; doing a plain reboot" >> "$LOG"
    reboot
}

echo "zl1-netdiag start uptime=$(cat /proc/uptime) cmdline=$(cat /proc/cmdline)" >> "$LOG"

i=0
while [ "$i" -lt "$ITERATIONS" ]; do
    i=$((i + 1))
    {
        echo "===== uptime $(cat /proc/uptime) ====="

        # -s -s is the point of the exercise: it prints qdisc state, tx_queue and drops.
        ip -s -s link show rndis0 2>&1

        grep -E 'rndis0|usb0' /proc/net/dev 2>&1
        ip -br addr show rndis0 2>&1
        echo "--- arp ---";  cat /proc/net/arp 2>&1
        echo "--- route ---"; ip route show 2>&1
        echo "--- rule ---";  ip rule show 2>&1
        echo "--- neigh ---"; ip neigh show 2>&1
        echo "--- ip stats ---"; grep -E '^Ip:|^Icmp:' /proc/net/snmp 2>&1
        echo "--- counters ---"
        for f in tx_dropped tx_errors tx_aborted_errors rx_dropped rx_errors; do
            printf '%s=%s ' "$f" "$(cat /sys/class/net/rndis0/statistics/$f 2>/dev/null)"
        done
        echo
        # Decisive for the intermittent transmit stall: tx_pkts_rcvd counts every
        # packet handed to eth_start_xmit, while tx_qlen is what is still sitting in
        # the gadget's tx_skb_q and tx_throttle is how often netif_stop_queue was
        # called. If tx_pkts_rcvd climbs while tx_qlen climbs and the device sends
        # nothing, the wake-up is being lost (netif_wake_queue is only called from
        # tx_complete). See docs/ubuntu-touch/22-stage2-coldboot-results.md 5.2c.
        echo "--- uether stats ---"
        for d in /sys/kernel/debug/rndis /sys/kernel/debug/usb0 /sys/kernel/debug/eth; do
            [ -d "$d" ] || continue
            echo "[$d]"; cat "$d/status" 2>&1; cat "$d/tx_bytes_rcvd" 2>&1
        done
        ls /sys/kernel/debug 2>/dev/null | tr '\n' ' '; echo
        echo "--- listeners ---"; (ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | head -8
        if pgrep -f lxc-start >/dev/null 2>&1; then echo "lxc-start: RUNNING"; else echo "lxc-start: absent"; fi
        echo "--- android_usb ---"
        cat /sys/class/android_usb/android0/state /sys/class/android_usb/android0/functions 2>&1

        # Can the device reach the host at all?
        if ping -c1 -W1 192.168.2.100 >/dev/null 2>&1; then
            echo "host-ping: OK"
        else
            echo "host-ping: FAIL"
        fi
    } >> "$LOG" 2>&1
    if [ "$RECOVERY_AFTER" -gt 0 ] && [ "$i" -ge $((RECOVERY_AFTER / INTERVAL)) ]; then
        reboot_to_recovery
        exit 0
    fi
    sleep "$INTERVAL"
done

echo "zl1-netdiag done uptime=$(cat /proc/uptime)" >> "$LOG"
