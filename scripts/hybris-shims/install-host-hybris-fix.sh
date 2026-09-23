#!/usr/bin/env bash
# Make the host side of the display stack persistent, without flashing anything.
#
# Why this exists: docs 41/45/46 got the GUI up, but every host-side piece of it was
# runtime state — a bind mount and a `chmod` — and this device drops both on reboot:
#
#   * the TLS-slot shim is bind-mounted over /usr/lib/aarch64-linux-gnu/libtls-padding.so,
#     which is the one file lsc-wrapper preloads (docs 41/45);
#   * /dev/ion and /dev/kgsl-3d0 are created 0600 root:root by devtmpfs, and without
#     /dev/ion open the session user's eglInitialize() fails and Mir reports the
#     misleading "could not select EGL config" (doc 46).
#
# Neither is a rootfs file, so neither can be fixed in place. But /etc/systemd/system is
# one of the rootfs's writable-paths (bind-mounted from /userdata/system-data/etc/systemd,
# the same trick install-container-desabotage.sh uses), so a unit placed there runs at boot
# as root and can do both. /userdata holds the shim itself, and /home holds the session's
# unit drop-in — both persistent.
#
# Companion to install-container-desabotage.sh, which does the container half (undo the
# v63 mount hook's string patches and stop the container's SurfaceFlinger). Both are
# needed for a reboot to come back with a working screen.
#
# Usage: install-host-hybris-fix.sh --install | --remove | --status
#
# Env: ZL1_HOST (default root@10.15.19.82)

set -uo pipefail
DEV="${ZL1_HOST:-root@10.15.19.82}"
here="$(cd "$(dirname "$0")/.." && pwd)"          # scripts/
STAGE=/userdata/zl1-host-fix
APPLY=$STAGE/apply.sh
SHIM=/userdata/zl1-tlsfix/shadow/libtls-padding.so
UNIT=/etc/systemd/system/zl1-host-fix.service
WANTS=/etc/systemd/system/multi-user.target.wants
DROPIN=/home/phablet/.config/systemd/user/lomiri-full-greeter.service.d/zl1-hybris.conf
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$DEV")
SCP=(scp -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

guard() {
  "${SSH[@]}" 'grep -qa msm8996 /proc/device-tree/compatible' 2>/dev/null ||
    { echo "not the zl1 (no msm8996 in /proc/device-tree/compatible) — refusing" >&2; exit 1; }
}

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# ---------------------------------------------------------------- device script
# Written here and pushed, so there is one copy of the logic and it lives in the repo.
cat > "$tmp/apply.sh" <<'EOF_APPLY'
#!/bin/sh
# Host-side display fixes, re-applied at boot. Written by
# scripts/hybris-shims/install-host-hybris-fix.sh — edit it there.
#
# Everything here is runtime state on purpose: no partition is written, no rootfs file
# is modified. The bind mount and the device-node modes simply do not survive a reboot,
# so something has to redo them, and this is that something.
set +e

LOG=/userdata/zl1-host-fix.log
log() { echo "$(cut -d' ' -f1 /proc/uptime) $*" >> "$LOG"; }

logfile_rotate() {
    [ -f "$LOG" ] || return 0
    [ "$(wc -c < "$LOG")" -lt 262144 ] && return 0
    tail -200 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
}

SHIM=/userdata/zl1-tlsfix/shadow/libtls-padding.so
SHIM_DST=/usr/lib/aarch64-linux-gnu/libtls-padding.so
# Every rootfs file this stack overlays with a bind mount. All three sources are on
# /userdata, so they survive a reboot; the mounts do not. install-hybris-shims.sh and
# install-tlsfix.sh stage them, and losing any one of the three takes the screen with it:
#
#   lsc-wrapper          — what lightdm runs the compositor through. Carries the preload
#                          and the nsenter into the container's PID namespace, so without
#                          it the compositor has no Android binder services at all (doc 43).
#   libtls-padding.so    — the bionic-TLS-slot shim (docs 41/45).
#   lomiri-greeter-wrapper — the greeter session runs lomiri too, so it needs the same
#                          preload; without it lightdm's seat cycles every ~100 s (doc 44).
OVERLAYS="
/userdata/zl1-hybris/lsc-wrapper:/usr/share/ubuntu-touch-session/lsc-wrapper
/userdata/zl1-tlsfix/shadow/libtls-padding.so:/usr/lib/aarch64-linux-gnu/libtls-padding.so
/userdata/zl1-hybris/lomiri-greeter-wrapper:/usr/bin/lomiri-greeter-wrapper
"
# Open, not group-owned: the session needs these and there is no graphics group here
# that phablet is in. doc 46 records that /dev/ion is the one that matters — kgsl alone
# still gave EGL_NOT_INITIALIZED, ion alone was enough.
NODES="/dev/kgsl-3d0 /dev/ion"

# A bind mount of a file onto a file: findmnt -T then reports the *file* as the mount
# point, which is exactly the test. Comparing st_dev against the parent directory is not
# — /usr is a read-only loop image here, so that comparison happens to work too, but it
# would silently break on a system where the parent and the source share a device.
overlay_mounted() {
    [ "$(findmnt -n -T "$2" -o TARGET 2>/dev/null)" = "$2" ]
}

mount_overlays() {
    for pair in $OVERLAYS; do
        src=${pair%%:*}; dst=${pair#*:}
        [ -f "$src" ] || { log "no file at $src — skipped"; continue; }
        overlay_mounted "$src" "$dst" && continue
        mount --bind "$src" "$dst" 2>/dev/null && log "bind-mounted $src over $dst" \
                                              || log "FAILED to bind-mount $src over $dst"
    done
}

open_nodes() {
    for n in $NODES; do
        [ -e "$n" ] || continue
        [ "$(stat -c %a "$n")" = 666 ] && continue
        chmod 666 "$n" 2>/dev/null && log "opened $n"
    done
}

# A reboot should end with a screen, not with a black panel that needs a lightdm restart,
# so nudge it once the pieces are in place. Only when it is actually down — restarting a
# healthy lightdm would take the running shell with it.
# A reboot should end with a screen, not with a black panel that needs a manual lightdm
# restart — but the window right after boot is not a failure: the compositor cannot come
# up until the container has been un-sabotaged (install-container-desabotage.sh, which
# does its own single lightdm restart), and the shell cannot come up until the compositor
# has. So this is gated twice: nothing before the system has had time to settle, and at
# most one restart every two minutes after that. Without the gate this would restart
# lightdm every 10 s through the whole boot, which is worse than waiting.
LAST_RESTART=0
MIN_UPTIME=90
RESTART_INTERVAL=120

restart_if_dark() {
    now=$(cut -d. -f1 /proc/uptime)
    [ "$now" -lt "$MIN_UPTIME" ] && return
    [ $((now - LAST_RESTART)) -lt "$RESTART_INTERVAL" ] && return
    st=$(systemctl is-active lightdm 2>/dev/null)
    if [ "$st" != active ]; then
        log "lightdm is $st — starting it"
        systemctl reset-failed lightdm >/dev/null 2>&1
        systemctl restart lightdm >/dev/null 2>&1
        LAST_RESTART=$now
        return
    fi
    if ! pgrep -f '^lomiri --mode=full-greeter' >/dev/null 2>&1; then
        log "lightdm is active but the shell is not running — restarting lightdm"
        systemctl restart lightdm >/dev/null 2>&1
        LAST_RESTART=$now
    fi
}

# Poll, and re-assert rather than act-once: the bind mount can be lost (something
# unmounts it, or /userdata is not ready yet on the boot that starts this), and a shim
# that quietly disappears is the doc-41 SEGV coming back. mount_shim is a findmnt call
# when there is nothing to do.
while :; do
    logfile_rotate
    open_nodes
    mount_overlays
    restart_if_dark
    sleep 10
done
EOF_APPLY

# ---------------------------------------------------------------- install
install_it() {
  guard
  [ -f "$here/tlsfix/out/libtls-padding.so" ] ||
    { echo "build the shim first: scripts/tlsfix/build-tlsfix.sh" >&2; exit 1; }
  # The two wrappers and the shim are the three files the boot fix mounts. The wrappers
  # come from the repo (lsc-wrapper.zl1 is generated by make-lsc-wrapper.sh against the
  # device's own copy; lomiri-greeter-wrapper.zl1 is the device's file with one hunk),
  # so a reboot restores exactly what was reviewed rather than whatever was last left
  # lying in /userdata.
  [ -f "$here/hybris-shims/lsc-wrapper.zl1" ] && [ -f "$here/hybris-shims/lomiri-greeter-wrapper.zl1" ] ||
    { echo "missing tracked wrapper(s) in $here/hybris-shims/" >&2; exit 1; }
  "${SSH[@]}" "mkdir -p $STAGE $(dirname $SHIM) $(dirname $DROPIN) /userdata/zl1-hybris"
  "${SCP[@]}" "$tmp/apply.sh" "$DEV:$APPLY" || exit 1
  "${SCP[@]}" "$here/tlsfix/out/libtls-padding.so" "$DEV:$SHIM" || exit 1
  "${SCP[@]}" "$here/hybris-shims/lsc-wrapper.zl1" "$DEV:/userdata/zl1-hybris/lsc-wrapper" || exit 1
  "${SCP[@]}" "$here/hybris-shims/lomiri-greeter-wrapper.zl1" "$DEV:/userdata/zl1-hybris/lomiri-greeter-wrapper" || exit 1

  # The session's unit-level environment. It has to be the unit's own Environment=:
  # doc 45 records that environment.d does nothing here and that
  # [Manager] DefaultEnvironment= does not override a variable the session already
  # exported (HYBRIS_LD_LIBRARY_PATH comes from lsc-wrapper).
  cat > "$tmp/dropin" <<EOF_DROPIN
[Service]
Environment=HYBRIS_LINKER=o
Environment=LD_PRELOAD=/usr/lib/aarch64-linux-gnu/libtls-padding.so
Environment=HYBRIS_LD_LIBRARY_PATH=/vendor/lib64/egl:/system/lib64/egl:/odm/lib64/egl:/userdata/zl1-hybris/lib:/system/lib64:/odm/lib64:/vendor/lib64
EOF_DROPIN
  "${SCP[@]}" "$tmp/dropin" "$DEV:$DROPIN" || exit 1

  cat > "$tmp/unit" <<EOF_UNIT
[Unit]
Description=zl1: open the GPU and preload the bionic-TLS shim (host side of the display stack)

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
  # Written with ln -sf through the bind mount; the unit file itself is what matters, and
  # systemctl enable is the check that it landed.
  "${SSH[@]}" "
    chmod 0755 $APPLY $SHIM /userdata/zl1-hybris/lsc-wrapper /userdata/zl1-hybris/lomiri-greeter-wrapper
    chown -R phablet:phablet /home/phablet/.config/systemd
    mkdir -p $WANTS
    ln -sf $UNIT $WANTS/zl1-host-fix.service
    systemctl daemon-reload
    systemctl enable zl1-host-fix.service >/dev/null 2>&1
    systemctl restart zl1-host-fix.service
    sleep 6
    echo -n 'unit: '; systemctl is-active zl1-host-fix.service
    echo '-- log'
    tail -6 /userdata/zl1-host-fix.log 2>/dev/null
  "
  echo
  echo "installed. Both halves are now persistent: this one and"
  echo "install-container-desabotage.sh. Verify with: $0 --status"
}

remove_it() {
  guard
  "${SSH[@]}" "
    systemctl disable --now zl1-host-fix.service >/dev/null 2>&1
    rm -f $WANTS/zl1-host-fix.service $UNIT $APPLY $DROPIN
    # -l: running processes have the shim mmap'd, so a plain umount returns EBUSY.
    umount -l /usr/lib/aarch64-linux-gnu/libtls-padding.so 2>/dev/null
    systemctl daemon-reload
    echo 'removed. The shim under /userdata and the log are left in place.'
    echo 'The GPU nodes stay open until the next reboot.'"
}
status_it() {
  guard
  "${SSH[@]}" "
    echo -n 'unit: '; systemctl is-active zl1-host-fix.service
    systemctl is-enabled zl1-host-fix.service 2>/dev/null
    echo 'overlays (source sha256 first 16 / mounted?):'
    for pair in /userdata/zl1-hybris/lsc-wrapper:/usr/share/ubuntu-touch-session/lsc-wrapper \
                /userdata/zl1-tlsfix/shadow/libtls-padding.so:/usr/lib/aarch64-linux-gnu/libtls-padding.so \
                /userdata/zl1-hybris/lomiri-greeter-wrapper:/usr/bin/lomiri-greeter-wrapper; do
      src=\${pair%%:*}; dst=\${pair#*:}
      if [ -f \"\$src\" ]; then
        on=no; [ \"\$(findmnt -n -T \$dst -o TARGET 2>/dev/null)\" = \"\$dst\" ] && on=yes
        printf '  %-9s %s  %s\n' \"\$on\" \"\$(sha256sum \$src | cut -c1-16)\" \"\$dst\"
      else
        printf '  %-9s %s  %s\n' missing - \"\$src\"
      fi
    done
    for n in /dev/kgsl-3d0 /dev/ion; do
      [ -e \$n ] && printf '  %-9s %s\n' \"\$(stat -c %A \$n)\" \"\$n\"
    done
    echo -n 'session drop-in: '; [ -f $DROPIN ] && echo yes || echo no
    printf '  shell: %s  mir: %s/%s  backlight: %s  lightdm: %s\n' \
      \"\$(pgrep -c -f '^lomiri --mode=full-greeter')\" \
      \"\$(ls /run/mir_socket 2>/dev/null | wc -l)\" \
      \"\$(ls /run/user/32011/mir_socket 2>/dev/null | wc -l)\" \
      \"\$(cat /sys/class/leds/lcd-backlight/brightness 2>/dev/null)\" \
      \"\$(systemctl is-active lightdm)\"
    echo '-- log tail'
    tail -8 /userdata/zl1-host-fix.log 2>/dev/null"
}

case "${1:-}" in
--install) install_it ;;
--remove)  remove_it ;;
--status)  status_it ;;
--help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0" ; exit 0 ;;   # printing the manual is not an error
# Everything else, including no argument at all, keeps this script's own exit code.
*) awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; exit 1;;
esac
