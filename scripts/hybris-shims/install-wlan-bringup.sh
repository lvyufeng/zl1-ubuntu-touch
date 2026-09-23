#!/usr/bin/env bash
# Make the WLAN driver actually load on this device — the step that was missing all along.
#
# Why this exists: on 2026-09-21 the QCA6174 was found to be fully supported by the running
# kernel — `CONFIG_QCA_CLD_WLAN=y`, 1356 `hdd_*` symbols in `/proc/kallsyms`, the PCIe device
# `0000:01:00.0` bound to `cnss_wlan_pci`, the firmware present under the kernel's own
# configured path — and yet there was no `wlan0` and `cnss-prealloc/status` read 1888 Kb all
# free, i.e. the WLAN host driver had never run once.
#
# The reason is in the driver's own source. When qcacld is built *into* the kernel rather
# than as a module, its init does nothing at all:
#
#     static int __init hdd_module_init(void)
#     {
#        /* Driver initialization is delayed to fwpath_changed_handler */
#        return 0;
#     }
#
# The real entry point is the `fwpath` module parameter's set handler. Writing it runs
# `kickstart_driver(true, mode_change)` -> `hdd_driver_init()` -> the PCIe HIF -> the chip
# power-up and firmware boot. On a stock Android image something in userspace writes it
# (`init.qcom.rc` only has `chown wifi wifi /sys/module/wlan/parameters/fwpath`, i.e. it
# expects a userspace writer, and the wifi HAL is normally that writer with the Android
# framework up). Here nothing ever did, so the driver simply never started.
#
# The value is a trigger, not a path. `hdd_get_fwpath()` has exactly one caller and it only
# compares the first two characters against "ap" (AP mode); the actual firmware directory
# comes from the kernel's `firmware_class/parameters/path`, already
# `/vendor/firmware_mnt/image`. "sta" is the station-mode value. The parameter's buffer is
# only 20 bytes (`BUF_LEN`), so a real path longer than 19 characters is rejected with
# ENOSPC — which is what a first attempt with `/userdata/zl1-firmware` got.
#
# Verified by hand on 2026-09-21: writing "sta" produced `wlan0`, `FW:4.1.2.57`,
# `HW:QCA6174_REV3_2`, `wlan: driver loaded in 1151543`, and took cnss-prealloc from 0 to
# 600 Kb used. The write is a power-up, not a teardown — unlike the `cnss` unbind that put
# the device into EDL (docs 49), this is the driver's own documented entry point.
#
# Usage: install-wlan-bringup.sh --install | --remove | --status | --trigger
#
# Env: ZL1_HOST (default root@10.15.19.82)

set -uo pipefail
DEV="${ZL1_HOST:-root@10.15.19.82}"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$DEV")

guard() {
  "${SSH[@]}" 'grep -qa msm8996 /proc/device-tree/compatible' 2>/dev/null ||
    { echo "not the zl1 (no msm8996 in /proc/device-tree/compatible) — refusing" >&2; exit 1; }
}

# The device-side watchdog. Re-asserts rather than acting once, for the same reason as the
# other units here: a driver that failed to load is silent, and "it worked when I ran it by
# hand" is not a property of the next boot.
WATCH_SH='
#!/bin/sh
D=/userdata/zl1-wlan
LOG=$D/bringup.log
FW=/sys/module/wlan/parameters/fwpath
mkdir -p "$D"
# Keep the log across boots but bounded.
logfile_rotate() {
    [ -f "$LOG" ] || return 0
    [ "$(wc -c < "$LOG")" -lt 262144 ] && return 0
    tail -200 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
}
log() { printf "%s %s\n" "$(cut -d. -f1 /proc/uptime)" "$*" >> "$LOG"; }

# The interface is NOT called wlan0. systemd-udevd predictable naming renames it, and on
# 2026-09-21 the name that came up was `wlp1s0` — with `p2p0` alongside it — while `wlan0`
# never existed at all. So a check for the literal name reports "the driver did not load" on
# a device where it loaded fine and `iw dev … scan` returns real access points. Ask the kernel
# which interfaces are wireless instead: /sys/class/net/<if>/wireless exists only for those.
wifi_if() {
    for d in /sys/class/net/*/; do
        [ -e "$d/wireless" ] || continue
        n=$(basename "$d")
        [ "$n" = p2p0 ] && continue          # the P2P sibling is not the station interface
        printf '%s' "$n"
        return 0
    done
    return 1
}

# One attempt per boot is the common case; the retry budget exists for the boot where the
# firmware is not readable yet when the container is still coming up.
tries=0
while :; do
    logfile_rotate
    if ifc=$(wifi_if); then
        # Already up. Say so once, then stay quiet — this loop runs for the life of the boot.
        if [ "$tries" != up ]; then
            log "wireless interface $ifc present: $(cat /sys/class/net/$ifc/address 2>/dev/null)"
            tries=up
        fi
        sleep 60
        continue
    fi
    if [ "$tries" = up ]; then
        # It existed and went away; that is worth a line, and worth retrying.
        log "the wireless interface went away — re-triggering"
        tries=0
    fi
    if [ "$tries" -ge 12 ]; then
        sleep 300
        continue
    fi
    # The chip firmware is read through the kernel firmware loader at the path in
    # firmware_class/parameters/path (/vendor/firmware_mnt/image), which only resolves once
    # the container filesystem is mounted. Without this check the trigger fires too early on
    # a cold boot and the driver fails with an error that looks like a firmware problem.
    if [ ! -r /vendor/firmware_mnt/image/qwlan30.bin ]; then
        [ "$tries" = 0 ] && log "waiting for /vendor/firmware_mnt/image to be readable"
        tries=$((tries + 1))
        sleep 10
        continue
    fi
    echo sta > "$FW" 2>>"$LOG"
    log "wrote fwpath=$(cat $FW 2>/dev/null) (attempt $((tries + 1)))"
    tries=$((tries + 1))
    sleep 15
done
'

case "${1:-}" in
--install)
  guard
  tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
  printf '%s\n' "$WATCH_SH" > "$tmp"
  # The same trap as install-kmsg-drain.sh: the assignment starts with a newline, so the
  # file's first line would not be the shebang and systemd would report `Exec format error`
  # / status=203/EXEC without saying why.
  sed -i '/./,$!d' "$tmp"
  case "$(head -1 "$tmp")" in
    '#!'*) ;;
    *) echo "refusing to push: first line is not a shebang ($(head -1 "$tmp"))" >&2; exit 1;;
  esac
  "${SSH[@]}" "mkdir -p /userdata/zl1-wlan"
  scp -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "$tmp" "$DEV:/userdata/zl1-wlan/bringup.sh"
  "${SSH[@]}" "chmod 755 /userdata/zl1-wlan/bringup.sh"
  "${SSH[@]}" "bash -s" <<'REMOTE'
set -u
cat > /etc/systemd/system/zl1-wlan-bringup.service <<'UNIT'
[Unit]
Description=zl1: load the QCA6174 WLAN driver (writes fwpath; nothing else does)
# After the container's filesystems exist, because the firmware is read through
# /vendor/firmware_mnt/image, and after the host fix so the display work is not delayed.
After=multi-user.target
Wants=multi-user.target

[Service]
Type=simple
ExecStart=/userdata/zl1-wlan/bringup.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable zl1-wlan-bringup.service >/dev/null 2>&1
systemctl reset-failed zl1-wlan-bringup.service >/dev/null 2>&1
systemctl restart zl1-wlan-bringup.service
sleep 5
echo "unit: $(systemctl is-active zl1-wlan-bringup.service)"
REMOTE
  echo "installed. Verify with: $0 --status"
  ;;
--remove)
  guard
  "${SSH[@]}" '
    systemctl disable --now zl1-wlan-bringup.service >/dev/null 2>&1
    rm -f /etc/systemd/system/zl1-wlan-bringup.service
    systemctl daemon-reload
    echo "removed the unit. wlan0 (if up) stays until the next reboot."'
  ;;
--trigger)
  guard
  "${SSH[@]}" '
    echo sta > /sys/module/wlan/parameters/fwpath && echo "wrote fwpath=sta"
    sleep 12
    ip -brief link | awk "/wlp|wlan/ {print \"  \" \$0}"'
  ;;
--status)
  guard
  # The interface name is udev'"'"'s (wlp1s0 on 2026-09-21), so it is discovered rather than
  # assumed — and the scan test is the one that actually answers "does the radio work".
  "${SSH[@]}" 'bash -s' <<'REMOTE'
printf 'unit       : '; systemctl is-active zl1-wlan-bringup.service 2>&1
printf 'fwpath     : '; cat /sys/module/wlan/parameters/fwpath 2>/dev/null; echo
echo 'wireless interfaces (the name is udev'\''s, not wlan0):'
station=""
for d in /sys/class/net/*/; do
    [ -e "$d/wireless" ] || continue
    n=$(basename "$d")
    printf '  %-10s %s  %s\n' "$n" "$(cat $d/address 2>/dev/null)" "$(cat $d/operstate 2>/dev/null)"
    [ "$n" = p2p0 ] || [ -n "$station" ] || station=$n
done
printf 'cnss pool  : '; grep -A2 'Memory Status' /sys/kernel/debug/cnss-prealloc/status 2>/dev/null | tail -2 | tr '\n' ' '; echo
if [ -n "$station" ]; then
    ip link set "$station" up 2>/dev/null
    printf 'scan test  : '
    n=$(timeout 25 iw dev "$station" scan 2>/dev/null | grep -c '^BSS')
    echo "$n BSS(es) visible on $station"
fi
echo 'bringup log:'
tail -8 /userdata/zl1-wlan/bringup.log 2>/dev/null
REMOTE
  ;;
--help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0" ; exit 0 ;;   # printing the manual is not an error
# Everything else, including no argument at all, keeps this script's own exit code.
*)
  awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; exit 1;;
esac
