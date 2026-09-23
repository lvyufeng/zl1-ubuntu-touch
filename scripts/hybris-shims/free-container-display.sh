#!/usr/bin/env bash
# Un-sabotage the Android container, and free the display for the host compositor.
#
# The v63 boot image writes an LXC mount hook that bind-mounts tmpfs copies of
# four real Android binaries over the originals with one string changed in each
# (all same length, so nothing about the file's shape gives it away):
#
#   system/bin/hwservicemanager    hwservicemanager.ready  -> zlservicemanager/ready
#   vendor/bin/qseecomd            sys.listeners.registered -> zl1.listeners.registered
#   system/lib64/libc.so           /dev/socket/property_service -> /dev/socket/property_servicf
#   system/lib/libc.so             (same as above)
#
# They are V25/V28/V29/V30 diagnostic experiments, frozen into the image by
# 0e95c3a. Their effect is that no Android HAL in the container can ever come up:
# every one of them waits for hwservicemanager.ready, and every property write
# from inside the container fails with ENOENT because libc dials a socket path
# that does not exist. See docs/ubuntu-touch/44-*.md.
#
# Second half: the container's SurfaceFlinger holds the QCOM composer's single
# client slot, so the host compositor's createClient() gets NO_RESOURCES and
# libhybris' ComposerHal.cpp:182 LOG_ALWAYS_FATALs. Stopping surfaceflinger (and
# bootanim with it) hands the HWC to Mir, which is where Halium wants it.
#
# Both halves are runtime-only and only last until the container next starts,
# because the hook runs on every lxc-start. Making them permanent means changing
# the boot image. This script is how the configuration is reached and checked
# today.
#
# Usage: free-container-display.sh --apply | --status | --explain
#
# Env: ZL1_HOST (default root@10.15.19.82)

set -uo pipefail
DEV="${ZL1_HOST:-root@10.15.19.82}"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$DEV")

guard() {
  "${SSH[@]}" 'grep -qa msm8996 /proc/device-tree/compatible' 2>/dev/null ||
    { echo "not the zl1 (no msm8996 in /proc/device-tree/compatible) — refusing" >&2; exit 1; }
}

read -r -d '' REMOTE <<'EOF_REMOTE'
set +e
A=$(lxc-info -n android -pH 2>/dev/null | head -1)
[ -n "$A" ] || { echo "no android container"; exit 1; }
N() { nsenter -t "$A" -p -m -- "$@" 2>/dev/null; }
Q() { N /system/bin/getprop "$1"; }
PATCHED=/system/lib64/libc.so
case "$1" in
apply)
  # 1. Lift the four bind-mounted copies. umount -l, not umount: the files are
  #    mmap'd by running processes, so a plain umount returns EBUSY.
  for t in $PATCHED /system/lib/libc.so /system/bin/hwservicemanager /vendor/bin/qseecomd; do
    N /system/bin/umount -l "$t" >/dev/null 2>&1
    printf '  lifted %-32s rc=%s\n' "$t" "$?"
  done
  echo "  property write from inside the container:"
  if N /system/bin/setprop debug.zl1free 1; then echo "    OK"; else echo "    STILL FAILING — the libc over-mount is still in the way"; fi
  # 2. Restart the two services whose binaries were patched. Only possible after
  #    the libc over-mounts are gone: ctl.restart is itself a property write.
  N /system/bin/setprop ctl.restart hwservicemanager
  N /system/bin/setprop ctl.restart qseecomd
  # 3. Hand the display to the host compositor.
  N /system/bin/setprop ctl.stop surfaceflinger
  N /system/bin/setprop ctl.stop bootanim
  sleep 5
  echo "  hwservicemanager.ready=[$(Q hwservicemanager.ready)] sys.listeners.registered=[$(Q sys.listeners.registered)]"
  printf '  HIDL services registered: %s\n' "$(N /system/bin/lshal | grep -acE '^[A-Za-z]')"
  printf '  init.svc.surfaceflinger=[%s] init.svc.bootanim=[%s]\n' "$(Q init.svc.surfaceflinger)" "$(Q init.svc.bootanim)"
  echo "  -- restarting lightdm"
  systemctl reset-failed lightdm 2>/dev/null
  systemctl restart lightdm
  sleep 25
  printf '  lightdm: %s\n' "$(systemctl is-active lightdm)"
  printf '  compositor processes: %s\n' "$(pgrep -f '/usr/sbin/lomiri-system-compositor --enable' | wc -l)"
  printf '  /run/mir_socket: %s  backlight: %s\n' \
    "$(ls /run/mir_socket 2>/dev/null | wc -l)" "$(cat /sys/class/leds/lcd-backlight/brightness 2>/dev/null)"
  ;;
status)
  echo "== the container's libc, either way =="
  printf '  path string the container sees:  %s\n' "$(N grep -a -o '/dev/socket/property_servic.' $PATCHED | sort -u | tr '\n' ' ')"
  printf '  path string in the real file:    %s\n' "$(grep -a -o '/dev/socket/property_servic.' /android/system/lib64/libc.so | sort -u | tr '\n' ' ')"
  printf '  device/inode, container view:    %s\n' "$(N stat -c '%d %i' $PATCHED 2>/dev/null)"
  printf '  device/inode, real file:         %s\n' "$(stat -c '%d %i' /android/system/lib64/libc.so)"
  echo "  (dev 1800 = 7:8 = /dev/loop1 is the real one; anything else is a tmpfs copy)"
  echo
  echo "== container health =="
  printf '  hwservicemanager.ready=[%s]  zlservicemanager/ready=[%s]\n' \
    "$(Q hwservicemanager.ready)" "$(Q zlservicemanager/ready)"
  printf '  sys.listeners.registered=[%s]  zl1.listeners.registered=[%s]\n' \
    "$(Q sys.listeners.registered)" "$(Q zl1.listeners.registered)"
  printf '  HIDL services registered: %s\n' "$(N /system/bin/lshal | grep -acE '^[A-Za-z]')"
  printf '  HAL waits in the last 200 log lines: %s\n' \
    "$(N /system/bin/logcat -d -v brief | tail -200 | grep -ac 'waiting another')"
  printf '  init.svc.surfaceflinger=[%s] init.svc.bootanim=[%s]\n' \
    "$(Q init.svc.surfaceflinger)" "$(Q init.svc.bootanim)"
  echo
  echo "== display stack =="
  printf '  lightdm: %s\n' "$(systemctl is-active lightdm)"
  printf '  /run/mir_socket: %s  /run/wayland-syscomp: %s  backlight: %s\n' \
    "$(ls /run/mir_socket 2>/dev/null | wc -l)" "$(ls /run/wayland-syscomp 2>/dev/null | wc -l)" \
    "$(cat /sys/class/leds/lcd-backlight/brightness 2>/dev/null)"
  P=$(pgrep -f '/usr/sbin/lomiri-system-compositor --enable' | tail -1)
  if [ -n "$P" ]; then
    printf '  compositor: pid %s, up %ss, pid namespace %s\n' "$P" "$(ps -o etimes= -p "$P" | tr -d ' ')" "$(readlink /proc/$P/ns/pid)"
    printf '  container init pid namespace:   %s\n' "$(readlink /proc/$A/ns/pid)"
    printf '  its own compositor process:     %s\n' "$(pgrep -f '^/usr/sbin/lomiri-system-compositor' | tail -1)"
  else
    echo "  compositor: not running"
  fi
  ;;
esac
exit 0
EOF_REMOTE

case "${1:-}" in
--apply)
  guard
  "${SSH[@]}" "bash -s apply" <<<"$REMOTE"
  ;;
--status)
  guard
  "${SSH[@]}" "bash -s status" <<<"$REMOTE"
  ;;
--explain)
  cat <<'EOF'
The v63 boot image's LXC mount hook (written by zl1-postswitch-debug-init, run by
lxc.hook.mount on every container start) bind-mounts tmpfs copies of four Android
binaries with one same-length string changed in each:

  system/bin/hwservicemanager   hwservicemanager.ready    -> zlservicemanager/ready
  vendor/bin/qseecomd           sys.listeners.registered  -> zl1.listeners.registered
  system/lib64/libc.so          /dev/socket/property_service -> /dev/socket/property_servicf
  system/lib/libc.so            (same)

Provenance: V25/V28/V29/V30 diagnostic experiments in
scripts/make-halium-postswitch-debug-boot.sh, frozen into the image by 0e95c3a.
They are why no Android HAL in the container ever registered a service.

Check for yourself, on the device:

  A=$(lxc-info -n android -pH | head -1)
  nsenter -t $A -p -m -- grep " 0:39 " /proc/self/mountinfo | awk '{print $5}'
  nsenter -t $A -p -m -- grep -a -o '/dev/socket/property_servic.' /system/lib64/libc.so
  nsenter -t $A -p -m -- /system/bin/getprop hwservicemanager.ready
  nsenter -t $A -p -m -- /system/bin/lshal | wc -l
  nsenter -t $A -p -m -- /system/bin/logcat -d -v brief | grep -c 'waiting another'

The display half is a separate resource conflict, not a bug in the shims: the
QCOM composer@2.1 service allows one client, and the container's SurfaceFlinger
takes it. Its .rc has "onrestart restart zygote", so every time it loses the
fight it takes zygote and half the container's services down with it.
EOF
  ;;
--help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0" ; exit 0 ;;   # printing the manual is not an error
# Everything else, including no argument at all, keeps this script's own exit code.
*)
  awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; exit 1;;
esac
