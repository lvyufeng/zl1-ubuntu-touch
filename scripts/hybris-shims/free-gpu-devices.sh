#!/usr/bin/env bash
# Let the Lomiri session's user open the GPU.
#
# Why this exists: with the TLS shim, the linker and the container all sorted out
# (docs 41/44/45), `lomiri --mode=full-greeter` still died with Mir's
#
#     ERROR: ./src/platforms/android/server/gl_context.cpp(127):
#            Throw in function select_egl_config_with_any_format
#     std::exception::what: could not select EGL config
#
# and the message is misleading: eglInitialize() itself was failing. The session
# runs as `phablet` (uid 32011) and the device nodes it needs are created
# root-only by devtmpfs:
#
#     crw------- 1 root root 235,  0 /dev/kgsl-3d0
#     crw------- 1 root root  10, 94 /dev/ion
#
# The system compositor never notices, because lightdm starts it as root. The
# session does, on every EGL call. `test_egl_configs` as root reports 68
# configurations; as phablet it reports `EGL Error 3001` (EGL_NOT_INITIALIZED).
# Chmod'ing these two nodes fixes it, and that is all this script does.
#
# It is a runtime change: both nodes live on devtmpfs, so a reboot puts them back
# to 0600 root:root. --restore does it immediately. The lasting fix belongs in the
# boot image (the post-switch init already mknod's several nodes with -m 666) or in
# a unit on the /etc/systemd/system writable-path, the way
# install-container-desabotage.sh does it for the container.
#
# Usage: free-gpu-devices.sh --apply | --restore | --status | --explain
#
# Env: ZL1_HOST (default root@10.15.19.82)

set -uo pipefail
DEV="${ZL1_HOST:-root@10.15.19.82}"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$DEV")

# /dev/ion is the one that matters: chmod'ing kgsl-3d0 alone still gave EGL Error
# 3001, and ion alone was enough to get 68 configurations. kgsl is in the list
# because the renderer needs it too and there is no reason to leave it root-only.
NODES="/dev/kgsl-3d0 /dev/ion"

# The EGL test needs the same two things the session got in doc 45, or it fails for
# a different reason and the output reads as if the permissions were still wrong.
TESTENV='LD_PRELOAD=/usr/lib/aarch64-linux-gnu/libtls-padding.so HYBRIS_LINKER=o HYBRIS_LD_LIBRARY_PATH=/vendor/lib64/egl:/system/lib64/egl:/odm/lib64/egl:/userdata/zl1-hybris/lib:/system/lib64:/odm/lib64:/vendor/lib64'

guard() {
  "${SSH[@]}" 'grep -qa msm8996 /proc/device-tree/compatible' 2>/dev/null ||
    { echo "not the zl1 (no msm8996 in /proc/device-tree/compatible) — refusing" >&2; exit 1; }
}

node_state() {
  "${SSH[@]}" "for n in $NODES; do
      [ -e \$n ] && printf '  %-18s %s\n' \"\$n\" \"\$(stat -c '%A %U:%G %t:%T' \$n)\" || printf '  %-18s missing\n' \"\$n\"
    done"
}

# What the session user actually gets. This is the measurement, not the mode bits:
# a node can be 0600 root:root and still work if phablet is in the owning group.
egl_probe() {
  "${SSH[@]}" "su -s /bin/sh phablet -c \"env $TESTENV /usr/bin/test_egl_configs\" 2>&1 |
      grep -aE 'Available configurations|EGL Error' | head -2"
}

case "${1:-}" in
--apply)
  guard
  "${SSH[@]}" "for n in $NODES; do
      [ -e \$n ] || continue
      chmod 666 \$n && echo \"  opened \$n\"
    done"
  echo "now the session user sees:"
  egl_probe
  echo
  echo "then: systemctl reset-failed lightdm; systemctl restart lightdm"
  echo "and check that it stays up: pgrep -af 'lomiri --mode=full-greeter'"
  ;;
--restore)
  guard
  "${SSH[@]}" "for n in $NODES; do
      [ -e \$n ] || continue
      chmod 600 \$n && chown root:root \$n && echo \"  restored \$n\"
    done"
  ;;
--status)
  guard
  echo "device nodes:"
  node_state
  echo "what the session user (phablet) can do with EGL:"
  egl_probe
  echo
  "${SSH[@]}" "printf '  shell: %s   mir sockets: %s/%s   backlight: %s   lightdm: %s\n' \
      \"\$(pgrep -c -f '^lomiri --mode=full-greeter')\" \
      \"\$(ls /run/mir_socket 2>/dev/null | wc -l)\" \
      \"\$(ls /run/user/32011/mir_socket 2>/dev/null | wc -l)\" \
      \"\$(cat /sys/class/leds/lcd-backlight/brightness 2>/dev/null)\" \
      \"\$(systemctl is-active lightdm)\""
  ;;
--explain)
  awk 'NR==1{next} /^#/{print; next} {exit}' "$0"
  ;;
--help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0" ; exit 0 ;;   # printing the manual is not an error
# Everything else, including no argument at all, keeps this script's own exit code.
*)
  awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; exit 1;;
esac
