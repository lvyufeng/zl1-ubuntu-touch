#!/usr/bin/env bash
# Make the container un-sabotage and the display handover **persistent**, without
# flashing anything and without touching the boot image.
#
# free-container-display.sh does the work but is runtime-only, because the v63
# image's LXC mount hook re-applies its three string substitutions on every
# container start (see docs/ubuntu-touch/44-*.md). The rootfs is read-only at
# runtime, so the hook itself cannot be edited in place — but /etc/systemd/system
# is one of the rootfs's writable-paths, bind-mounted from
# /userdata/system-data/etc/systemd. A unit placed there is persistent and runs at
# boot, which is code execution at boot without touching the rootfs, the ramdisk or
# any partition.
#
# So this installs a small supervisor that
#
#   1. waits for the Android container,
#   2. lifts the four bind-mounted copies the moment they appear,
#   3. stops the container's SurfaceFlinger so the host compositor can hold the
#      QCOM composer's single client slot,
#   4. keeps watching, because the hook comes back every time the container does.
#
# The device-side script is written by this one, so there is one copy of the logic
# and it lives in the repo.
#
# Usage: install-container-desabotage.sh --install | --remove | --status
#
# Env: ZL1_HOST (default root@10.15.19.82)

set -uo pipefail
DEV="${ZL1_HOST:-root@10.15.19.82}"
STAGE=/userdata/zl1-container-fix
APPLY=$STAGE/apply.sh
UNIT=/etc/systemd/system/zl1-container-fix.service
WANTS=/etc/systemd/system/multi-user.target.wants
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$DEV")
SCP=(scp -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

guard() {
  "${SSH[@]}" 'grep -qa msm8996 /proc/device-tree/compatible' 2>/dev/null ||
    { echo "not the zl1 (no msm8996 in /proc/device-tree/compatible) — refusing" >&2; exit 1; }
}

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# ---------------------------------------------------------------- device script
cat > "$tmp/apply.sh" <<'EOF_APPLY'
#!/bin/sh
# Undo what the v63 boot image's LXC mount hook does to the Android container, and
# hand the display to the host compositor. Written by
# scripts/hybris-shims/install-container-desabotage.sh — edit it there.
#
# The hook runs on every lxc-start, so this watches rather than acting once.
# Everything here is runtime state: no partition, no rootfs file, no image.
set +e

LOG=/userdata/zl1-container-fix.log
log() { echo "$(cut -d' ' -f1 /proc/uptime) $*" >> "$LOG"; }

logfile_rotate() {
    [ -f "$LOG" ] || return 0
    [ "$(wc -c < "$LOG")" -lt 262144 ] && return 0
    tail -200 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
}

# The real libc.so lives on /dev/loop1, which is st_dev 1800 (7:8) as seen through
# the container init's root. Anything else at that path is one of the tmpfs copies.
REAL_DEV=1800

container_init() {
    A=$(lxc-info -n android -pH 2>/dev/null | head -1)
    [ -n "$A" ] || return 1
    # /proc/PID/ns/pid is a symlink to nsfs: -e, never -d.
    [ -e "/proc/$A/ns/pid" ] || return 1
    echo "$A"
}

apply() {
    A=$1
    for t in /system/lib64/libc.so /system/lib/libc.so \
             /system/bin/hwservicemanager /vendor/bin/qseecomd; do
        nsenter -t "$A" -p -m -- /system/bin/umount -l "$t" >/dev/null 2>&1
    done
    # ctl.restart is itself a property write, so it can only work now that the
    # patched libc is out of the way.
    nsenter -t "$A" -p -m -- /system/bin/setprop ctl.restart hwservicemanager >/dev/null 2>&1
    nsenter -t "$A" -p -m -- /system/bin/setprop ctl.restart qseecomd        >/dev/null 2>&1
    # RescueParty is the Android framework's "this device is in a crash loop" escalator, and
    # it ends in a reboot to recovery. Stopping SurfaceFlinger below puts the framework in
    # exactly that state on purpose: system_server waits forever for a service that will
    # never come back, RescueParty counts every wait as an event, and the device reboots into
    # TWRP — with no help from us and nothing in the host's own logs to explain it.
    # Verified on 2026-09-21: W/RescueParty: "Noticed 2 events for UID 0 in last 126 sec"
    # alongside I/ServiceManager: "Waiting for service SurfaceFlinger..." repeating, which
    # is what pstore's ramoops buffer still held after the device came up in recovery.
    nsenter -t "$A" -p -m -- /system/bin/setprop persist.sys.disable_rescue true >/dev/null 2>&1
    sf=$(nsenter -t "$A" -p -m -- /system/bin/getprop init.svc.surfaceflinger 2>/dev/null)
    if [ "$sf" = running ]; then
        nsenter -t "$A" -p -m -- /system/bin/setprop ctl.stop surfaceflinger >/dev/null 2>&1
        nsenter -t "$A" -p -m -- /system/bin/setprop ctl.stop bootanim        >/dev/null 2>&1
    fi
    # ...and stop the framework too, rather than leaving it waiting. Nothing the host needs
    # is a zygote child: every HAL the compositor talks to is an init service, and lshal
    # still reports 146 of them with zygote stopped. What stopping it buys is the end of the
    # crash loop itself, and the load average drops from ~14 to ~9 with it.
    if [ "$(nsenter -t "$A" -p -m -- /system/bin/getprop init.svc.zygote 2>/dev/null)" = running ]; then
        nsenter -t "$A" -p -m -- /system/bin/setprop ctl.stop zygote >/dev/null 2>&1
    fi
}

first=1
while :; do
    logfile_rotate
    A=$(container_init)
    if [ -n "$A" ]; then
        dev=$(stat -c %d "/proc/$A/root/system/lib64/libc.so" 2>/dev/null)
        if [ -n "$dev" ] && [ "$dev" != "$REAL_DEV" ]; then
            log "sabotage present (st_dev=$dev, want $REAL_DEV) — lifting it"
            apply "$A"
            if [ "$first" = 1 ]; then
                # Let lightdm's seat pick the freed display up straight away instead
                # of waiting out its own cycle.
                systemctl reset-failed lightdm >/dev/null 2>&1
                systemctl restart lightdm >/dev/null 2>&1
                first=0
            fi
            sleep 5
            dev=$(stat -c %d "/proc/$A/root/system/lib64/libc.so" 2>/dev/null)
            log "after apply: st_dev=$dev hwready=$(nsenter -t "$A" -p -m -- /system/bin/getprop hwservicemanager.ready 2>/dev/null)"
        else
            # Clean. Only make sure the container's display stack stays out of the
            # host compositor's way — and that the framework is not left waiting for it,
            # which is what feeds RescueParty (see apply()).
            sf=$(nsenter -t "$A" -p -m -- /system/bin/getprop init.svc.surfaceflinger 2>/dev/null)
            if [ "$sf" = running ]; then
                log "surfaceflinger came back — stopping it again"
                nsenter -t "$A" -p -m -- /system/bin/setprop ctl.stop surfaceflinger >/dev/null 2>&1
                nsenter -t "$A" -p -m -- /system/bin/setprop ctl.stop bootanim        >/dev/null 2>&1
            fi
            z=$(nsenter -t "$A" -p -m -- /system/bin/getprop init.svc.zygote 2>/dev/null)
            if [ "$z" = running ]; then
                log "container zygote is running — stopping it (nothing the host needs is a zygote child)"
                nsenter -t "$A" -p -m -- /system/bin/setprop ctl.stop zygote >/dev/null 2>&1
            fi
        fi
    fi
    sleep 5
done
EOF_APPLY

# ---------------------------------------------------------------- install
install_it() {
  guard
  "${SSH[@]}" "mkdir -p $STAGE"
  "${SCP[@]}" "$tmp/apply.sh" "$DEV:$APPLY" || exit 1
  cat > "$tmp/unit" <<EOF_UNIT
[Unit]
Description=zl1: lift the container's boot-time string patches and free the display

[Service]
Type=simple
ExecStart=$APPLY
Restart=always
RestartSec=5
Nice=-5

[Install]
WantedBy=multi-user.target
EOF_UNIT
  "${SCP[@]}" "$tmp/unit" "$DEV:$UNIT" || exit 1
  # Written via a file, not `ln -s`: the target is on the read-only rootfs side of
  # the bind mount, and a failed symlink would silently leave the unit disabled.
  "${SSH[@]}" "
    chmod 0755 $APPLY
    mkdir -p $WANTS
    ln -sf $UNIT $WANTS/zl1-container-fix.service
    systemctl daemon-reload
    systemctl enable --now zl1-container-fix.service 2>&1 | tail -2
    sleep 8
    echo -n 'unit: '; systemctl is-active zl1-container-fix.service
    echo '-- log'
    tail -6 /userdata/zl1-container-fix.log 2>/dev/null
  "
  echo
  echo "installed. It is persistent: /etc/systemd/system is a writable-path on /userdata."
  echo "Verify with: $0 --status"
}

remove_it() {
  guard
  "${SSH[@]}" "
    systemctl disable --now zl1-container-fix.service >/dev/null 2>&1
    rm -f $WANTS/zl1-container-fix.service $UNIT $APPLY
    systemctl daemon-reload
    echo 'removed. The container goes back to its boot-time patches at its next start'
    echo '(the sabotage is part of the boot image, so a reboot restores it anyway).'
    echo 'The log at /userdata/zl1-container-fix.log is left in place.'"
}

status_it() {
  guard
  "${SSH[@]}" "
    echo -n 'unit: '; systemctl is-active zl1-container-fix.service
    systemctl is-enabled zl1-container-fix.service 2>/dev/null
    echo -n 'applied and clean? '
    A=\$(lxc-info -n android -pH 2>/dev/null | head -1)
    if [ -n \"\$A\" ]; then
      dev=\$(stat -c %d /proc/\$A/root/system/lib64/libc.so 2>/dev/null)
      if [ \"\$dev\" = 1800 ]; then echo 'yes'; else echo \"no (st_dev=\$dev, the tmpfs copy is mounted)\"; fi
      n() { nsenter -t \"\$A\" -p -m -- \"\$@\" 2>/dev/null; }
      printf '  hwservicemanager.ready=[%s] surfaceflinger=[%s]\n' \
        \"\$(n /system/bin/getprop hwservicemanager.ready)\" \"\$(n /system/bin/getprop init.svc.surfaceflinger)\"
      printf '  HIDL services: %s\n' \"\$(n /system/bin/lshal | grep -acE '^[A-Za-z]')\"
    else
      echo 'no container'
    fi
    printf '  mir_socket: %s  backlight: %s  lightdm: %s\n' \
      \"\$(ls /run/mir_socket 2>/dev/null | wc -l)\" \"\$(cat /sys/class/leds/lcd-backlight/brightness 2>/dev/null)\" \"\$(systemctl is-active lightdm)\"
    echo '-- log tail'
    tail -8 /userdata/zl1-container-fix.log 2>/dev/null"
}

case "${1:-}" in
--install) install_it ;;
--remove)  remove_it ;;
--status)  status_it ;;
*) sed -n '2,26p' "$0"; exit 1;;
esac
