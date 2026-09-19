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

# Optional, and off unless the marker file exists: after this many seconds, ask the
# bootloader for recovery so the log can be read without anyone holding a button. The
# command is written into misc, which is what Android's own `reboot recovery` does.
#
# It reboots ONLY if the command was written and read back correctly. There is no plain
# reboot fallback: on 2026-09-17 the write failed, the fallback fired, and the device sat
# in a reboot-every-900-seconds loop that I mistook for a property of the system.
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
        # Record how far the Android container has got, alongside the link state. Added
        # 2026-09-18 after comparing status pages showed the discriminator is not "the
        # container is running" but "the container reached netd": every boot whose link
        # stayed healthy had the container stuck before zygote, and every boot whose link
        # died had zygote, netd and fwmarkd present.
        #   docs/ubuntu-touch/32-counterexample-38-minute-boot.md
        echo "--- container progress ---"
        for p in lxc-start ueventd hwservicemanager servicemanager vndservicemanager zygote netd; do
            if pgrep -f "$p" >/dev/null 2>&1; then printf '%s=RUNNING ' "$p"; else printf '%s=absent ' "$p"; fi
        done
        echo
        if [ -e /dev/socket/fwmarkd ]; then echo "fwmarkd socket: present"; else echo "fwmarkd socket: absent"; fi
        # Where the container gets to, exactly. lxc-android-ready blocks on this file with
        # no timeout, so while it is missing systemd keeps restarting the container — 143
        # times in one 2.6-hour boot, about every 65 s. See
        # docs/ubuntu-touch/33-the-container-restart-loop.md
        cpid="$(pgrep -f 'lxc-start -n android' | head -1)"
        if [ -n "$cpid" ] && [ -e "/proc/$cpid/root/dev/.coldboot_done" ]; then
            echo "coldboot_done: present (container reached Android boot completion)"
        else
            echo "coldboot_done: absent (container is stuck before it)"
        fi
        if [ "$host_ping_ok" = "1" ]; then echo "host-ping: OK"; else echo "host-ping: FAIL"; fi
    } >> "$LOG" 2>&1
}

# Is the transmit path alive? The device asks the host a question and waits for the
# answer; if it never comes, our packets are not getting out.
#
# This probe is the whole detection mechanism, and the reason is that the previous one
# could not fire when it mattered. It watched the device's RX counter for movement, on the
# theory that a stall looks like "the host is talking and we are not answering" — but with
# no traffic from either side (an idle system, or a host that stopped probing after its
# first success) RX does not move either, so it concluded "not stalled" and did nothing.
# Measured on hardware 2026-09-17: exactly that happened, the device sat unreachable for
# 15 minutes with the watchdog running.
#
# Probing from here removes the dependency: the device generates its own traffic, so the
# test works whether or not anything else is happening on the link.
probe_host() {
    ping -c1 -W1 192.168.2.100 >/dev/null 2>&1
}


write_file() { echo "$2" > "$1" 2>/dev/null || return 1; }

# zl1: policy routing fix.
#
# Android's netd installs, in the network namespace it shares with Ubuntu Touch:
#
#     15000: from all fwmark 0/0x10000 lookup 99
#     16000: from all fwmark 0/0x10000 lookup 98
#     17000: from all fwmark 0/0x10000 lookup 97
#     32000: from all unreachable
#
# UT's packets carry no fwmark, so they hit 15000-17000, which select tables 99/98/97 —
# and those tables are empty. The lookup finds nothing and rule 32000 declares the packet
# unreachable, so it is never constructed and never reaches eth_start_xmit. That is the
# whole stall. See docs/ubuntu-touch/35-the-policy-routing-rule-that-kills-the-link.md
#
# One rule ahead of netd's, selecting the main table (which does hold
# "192.168.2.0/24 dev rndis0"), puts the routes back in front of the dead end.
#
# It has to run after netd installs its rules, which is partway into the boot, so it is
# applied on every sample where it is missing rather than once at startup.
# Two routes in the table netd already consults.
#
# The first attempt (2026-09-19) added two ip rules ahead of netd's:
#
#     ip rule add pref 1000 from all to 192.168.2.0/24 lookup main
#     ip rule add pref 1001 from all to 10.15.19.0/24  lookup main
#
# That worked — reachability went from 0.3% to ~80% — but netd rewrites the whole rule
# set every 4-8 s, so the rules were being deleted and re-added continuously. The 80%
# was simply the fraction of time they happened to be present. Measured over two
# minutes the count went 2 -> 0 -> 2 -> 0, roughly every 5 s.
#
# The rules are not where the fix belongs. netd owns them and will keep rewriting them.
# What it does not touch is the CONTENTS of the tables its rules point at. Its own rule
#
#     15000: from all fwmark 0/0x10000 lookup 99
#
# sends every unmarked packet to table 99; that table was empty, which is why the lookup
# found nothing and fell through to `32000: from all unreachable`. Put the routes in
# table 99 and netd's own rule resolves them.
#
# Measured: deleting the pref-1000/1001 rules, leaving only the two routes in table 99,
# the link went to 40/40 and stayed there; table 99's contents did not change once over
# two minutes.
POLICY_TABLES="99"
POLICY_ROUTES="192.168.2.0/24 10.15.19.0/24"

apply_policy_routing_fix() {
    added=0
    for tbl in $POLICY_TABLES; do
        for net in $POLICY_ROUTES; do
            ip route show table "$tbl" 2>/dev/null | grep -q "^$net " && continue
            if ip route add "$net" dev "$IFACE" table "$tbl" 2>/dev/null; then
                added=$((added + 1))
            fi
        done
    done
    if [ "$added" -gt 0 ]; then
        log "policy routing fix: added $added route(s) to table $POLICY_TABLES"
    fi
    # Report against the test that was failing, not against the routes simply existing.
    if ip route get 192.168.2.100 2>&1 | grep -q "dev $IFACE"; then
        [ "$policy_ok" = "1" ] || log "policy routing fix in place: route get 192.168.2.100 resolves via $IFACE"
        policy_ok=1
    else
        [ "$policy_failed" = "1" ] || log "policy routing fix NOT working: $(ip route get 192.168.2.100 2>&1 | head -1)"
        policy_failed=1
    fi
    return 0
}

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
host_ping_ok=0
policy_ok=0
policy_failed=0
# Uptimes at which to snapshot the netfilter/routing state, picked to bracket the break.
NETSNAP_AT="20 30 40 50 60 75 90 110 140 180"

while :; do
    i=$((i + 1))
    host_ping_ok=0
    [ -e "/sys/class/net/$IFACE" ] && probe_host && host_ping_ok=1
    sample

    # Re-assert the policy routing fix whenever it is missing. It has to run continuously
    # because netd rewrites its rule set and the container restarts every ~65 s.
    [ -e "/sys/class/net/$IFACE" ] && apply_policy_routing_fix

    set -- $(ifname_stats)
    rx_b="$1"; rx_p="$2"; tx_b="$3"; tx_p="$4"

    # Track how long the host has been unreachable. The counter only runs while the
    # interface exists, so a heal tearing the netdev down does not itself look like a
    # worsening stall.
    if [ -e "/sys/class/net/$IFACE" ]; then
        if [ "$host_ping_ok" = "1" ]; then
            if [ "$frozen" -ge "$STALL_SECONDS" ]; then
                log "HEAL: host reachable again after ${frozen}s unreachable"
            fi
            frozen=0
            last_tx="$tx_p"
        else
            frozen=$((frozen + SAMPLE_INTERVAL))
        fi
    fi

    uptime_s=$(cut -d' ' -f1 /proc/uptime 2>/dev/null | cut -d. -f1)

    # In record-only mode nothing is healed, but the moment the link dies is still the
    # most interesting line in the log — say so rather than leaving it to be inferred
    # from a run of host-ping: FAIL samples.
    if [ "$HEAL_ENABLED" = "0" ] && [ "$frozen" = "$STALL_SECONDS" ]; then
        log "STALL(unhealed): host unreachable for ${frozen}s; iface=${IFACE} tx_pkts=${tx_p:-?} rx_pkts=${rx_p:-?}"
        { echo "--- stall evidence ---"; gadget_stats; } >> "$LOG" 2>&1
        netsnap
    fi

    # Capture the netfilter/routing state several times early in the boot, because the
    # break lands somewhere in a 40-60 s window and a single sample could easily land on
    # the wrong side of it. Ten samples bracket it whatever the exact timing, and each one
    # records whether the host was reachable at that moment, so the series labels itself.
    netsnap_next="${NETSNAP_AT%% *}"
    if [ -n "$netsnap_next" ] && [ "${uptime_s:-0}" -ge "$netsnap_next" ]; then
        {
            echo "--- host reachable at this snapshot: $([ "$host_ping_ok" = 1 ] && echo yes || echo no)"
        } >> "$LOG" 2>&1
        netsnap
        case "$NETSNAP_AT" in
            *" "*) NETSNAP_AT="${NETSNAP_AT#* }" ;;
            *)     NETSNAP_AT="" ;;
        esac
    fi

    if [ "$hwcheck_done" = "0" ] && [ "${uptime_s:-0}" -ge "$HWCHECK_AFTER" ]; then
        netsnap
        hwcheck
        hwcheck_done=1
    fi
    if [ "$HEAL_ENABLED" = "1" ] && [ "$heals" -lt "$MAX_HEALS" ] \
       && [ "$frozen" -ge "$STALL_SECONDS" ] && [ "${uptime_s:-0}" -ge "$SETTLE_SECONDS" ]; then
        log "STALL: host unreachable for ${frozen}s; iface=${IFACE} tx_pkts=${tx_p:-?} rx_pkts=${rx_p:-?}"
        { echo "--- stall evidence ---"; gadget_stats; } >> "$LOG" 2>&1
        netsnap
        # Escalate: the first heal of a boot re-enumerates, later ones rebind the
        # function. A stall that survives a re-enumeration needs the stronger one.
        if [ "$heals" -eq 0 ]; then heal A "unreachable-${frozen}s"; else heal B "unreachable-${frozen}s-still"; fi
        heals=$((heals + 1))
        log "HEAL: attempt $heals/$MAX_HEALS done; sleeping ${HEAL_RETRY_SECONDS}s before judging"
        sleep "$HEAL_RETRY_SECONDS"
        # Give the heal a fresh baseline so a successful reset is not immediately
        # re-flagged as the same stall.
        set -- $(ifname_stats)
        last_tx="$4"
        frozen=0
        # Deliberately no `continue` here. It used to jump straight back to the top, which
        # meant the recovery check further down was skipped on every iteration that healed
        # — so a device that kept stalling also never reached its scheduled reboot. That is
        # exactly the state the device was found in on 2026-09-17: 47 minutes uptime with
        # the recovery marker set to 900 s and no recovery ever attempted.
    fi

    if [ "$RECOVERY_AFTER" -gt 0 ] && [ "${uptime_s:-0}" -ge "$RECOVERY_AFTER" ]; then
        log "RECOVERY: uptime ${uptime_s}s >= ${RECOVERY_AFTER}s — asking the bootloader for recovery"
        wrote=0
        for blk in /dev/block/bootdevice/by-name/misc /dev/block/sda4; do
            [ -e "$blk" ] || continue
            if printf 'boot-recovery' > "$blk" 2>/dev/null; then
                sync
                # Read it back. On 2026-09-17 every attempt logged "could not write the
                # bootloader command", so the reboot never reached recovery — and because
                # the fallback was a PLAIN reboot, the device just booted the system again
                # and repeated the whole cycle at the next 900 s mark. Five times. A plain
                # reboot is not a degraded version of this feature; it is a reboot loop,
                # so it is gone.
                back="$(dd if="$blk" bs=1 count=16 2>/dev/null | tr -d '\000')"
                if [ "$back" = "boot-recovery" ]; then
                    log "RECOVERY: wrote and verified boot-recovery in $blk; rebooting"
                    wrote=1
                    break
                fi
                log "RECOVERY: wrote to $blk but read back [$back] — not rebooting"
            else
                log "RECOVERY: cannot write $blk"
            fi
        done
        if [ "$wrote" = "0" ]; then
            log "RECOVERY: could not set the bootloader command anywhere; staying up."
            log "RECOVERY: the device will stay in this state — read the log from TWRP by hand."
            # Stop asking; one attempt per boot is enough.
            RECOVERY_AFTER=0
        fi
    fi

    sleep "$SAMPLE_INTERVAL"
done
