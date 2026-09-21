#!/usr/bin/env bash
# Keep the kernel log. On this device it is currently unreadable, and that is what made
# the Wi-Fi investigation a blind one.
#
# Why this exists: on 2026-09-21 the kernel ring buffer held only the last ~18 seconds,
# because the uether TX path (patched by scripts/patch-uether-tx-wakeup.sh) emits a
# `tx_complete` WARN stack trace on every transmit, ~3500 lines at a time. Every boot-time
# message — including everything the cnss/wlan/qcacld drivers say while bringing up the
# QCA6174 — is overwritten within seconds of the USB link coming up. `journalctl -k`
# returns 1 line, so journald is not capturing /dev/kmsg either. The only way to read a
# driver error was to make the driver probe again, and doing that with `unbind` put the
# device into EDL (see docs/ubuntu-touch/49-*). So: capture the log *first*.
#
# The unit goes on the /etc/systemd/system writable-path (a bind mount of
# /userdata/system-data/etc/systemd), so it survives a reboot with no rootfs change, and
# the script and its output live on /userdata.
#
# Usage: install-kmsg-drain.sh --install | --remove | --status | --read [LINES]
#
# Env: ZL1_HOST (default root@10.15.19.82)

set -uo pipefail
DEV="${ZL1_HOST:-root@10.15.19.82}"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$DEV")
DIR=/userdata/zl1-kmsg

guard() {
  "${SSH[@]}" 'grep -qa msm8996 /proc/device-tree/compatible' 2>/dev/null ||
    { echo "not the zl1 (no msm8996 in /proc/device-tree/compatible) — refusing" >&2; exit 1; }
}

case "${1:-}" in
--install)
  guard
  # The device-side script is written with a quoted heredoc and scp'd, rather than pasted
  # into an ssh one-liner: it is a loop with redirections, and the escaping is not worth it.
  tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
  cat > "$tmp" <<'DRAIN'
#!/bin/sh
# Snapshot the ring buffer first, then follow it.
#
# The snapshot is the whole point: /dev/kmsg opened *after* a WARN storm has wrapped the
# ring gives you the tail of the storm and nothing else. `dmesg` reads the entire buffer
# (SYSLOG_ACTION_READ_ALL), so a drainer that starts at ~t=10 s keeps the boot log.
#
# Neither half uses the clock. The device's clock is wrong (1970-02-09 in systemd's view),
# so the raw /dev/kmsg records — which carry a monotonic microsecond counter — are kept
# verbatim. That is also why the log is readable across a reboot at all.
D=/userdata/zl1-kmsg
mkdir -p "$D"
dmesg > "$D/boot.log" 2>/dev/null

# Rotate at 8 MB, keeping the newer 4 MB. Without this the WARN storm fills /userdata.
rotate() {
    [ -f "$D/kmsg.log" ] || return 0
    [ "$(wc -c < "$D/kmsg.log")" -gt 8388608 ] || return 0
    tail -c 4194304 "$D/kmsg.log" > "$D/kmsg.log.tmp" 2>/dev/null &&
        mv "$D/kmsg.log.tmp" "$D/kmsg.log"
    echo "=== rotated at uptime $(cut -d. -f1 /proc/uptime)s ===" >> "$D/kmsg.log"
}

# One open file description, read forever. Re-opening /dev/kmsg per iteration would
# restart at the head of the buffer every time and loop over the same records.
n=0
exec 3< /dev/kmsg
while IFS= read -r line <&3; do
    printf '%s\n' "$line" >> "$D/kmsg.log"
    n=$((n + 1))
    [ $((n % 500)) -eq 0 ] && rotate
done
DRAIN
  "${SSH[@]}" "mkdir -p $DIR"
  scp -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$tmp" "$DEV:$DIR/drain.sh"
  "${SSH[@]}" "chmod 755 $DIR/drain.sh"
  "${SSH[@]}" "bash -s" <<'REMOTE'
set -u
mkdir -p /etc/systemd/system/zl1-kmsg-drain.service.d
# DefaultDependencies=no and ordering before the container is what makes this early
# enough: the point is to have a reader attached before the USB link starts its WARN
# storm, and the container starts well after that.
cat > /etc/systemd/system/zl1-kmsg-drain.service <<'UNIT'
[Unit]
Description=zl1: keep the kernel log on /userdata
DefaultDependencies=no
After=local-fs.target
Before=lxc.service android.service sysinit.target shutdown.target
Conflicts=shutdown.target

[Service]
Type=simple
ExecStart=/userdata/zl1-kmsg/drain.sh
Restart=always
RestartSec=5
# The drainer must not be killed by the OOM killer while it is the only reader.
OOMScoreAdjust=-500

[Install]
WantedBy=sysinit.target
UNIT
systemctl daemon-reload
systemctl enable zl1-kmsg-drain.service >/dev/null 2>&1
systemctl reset-failed zl1-kmsg-drain.service >/dev/null 2>&1
systemctl restart zl1-kmsg-drain.service
sleep 4
systemctl is-active zl1-kmsg-drain.service
REMOTE
  echo "installed. Wrote $( "${SSH[@]}" "wc -l < $DIR/boot.log 2>/dev/null" | tr -d '\r' ) lines of boot log already."
  echo "Read it with: $0 --read 200"
  ;;
--remove)
  guard
  "${SSH[@]}" '
    systemctl disable --now zl1-kmsg-drain.service >/dev/null 2>&1
    rm -f /etc/systemd/system/zl1-kmsg-drain.service
    rmdir /etc/systemd/system/zl1-kmsg-drain.service.d 2>/dev/null
    systemctl daemon-reload
    echo "removed the unit. The script and its log stay on /userdata/zl1-kmsg."'
  ;;
--status)
  guard
  "${SSH[@]}" "
    printf 'unit      : '; systemctl is-active zl1-kmsg-drain.service 2>&1
    printf 'script    : '; ls -l $DIR/drain.sh 2>/dev/null || echo missing
    printf 'boot.log  : '; wc -l < $DIR/boot.log 2>/dev/null || echo missing
    printf 'kmsg.log  : '; wc -l < $DIR/kmsg.log 2>/dev/null || echo missing
    printf 'ring now  : '; dmesg 2>/dev/null | wc -l"
  ;;
--read)
  guard
  n="${2:-200}"
  # boot.log is the whole buffer as it stood when the drainer started; kmsg.log is
  # everything since. Grepping both is how a driver's boot-time error finally becomes
  # visible — that is the entire purpose of this script.
  "${SSH[@]}" "
    echo '=== boot.log | cnss/wlan/wcnss/qcacld ==='
    grep -aiE 'cnss|wlan|wcnss|qca6174|ar6320|qcacld' $DIR/boot.log 2>/dev/null | tail -n $n
    echo
    echo '=== boot.log | tail ==='
    tail -n $n $DIR/boot.log 2>/dev/null"
  ;;
*)
  sed -n '2,25p' "$0"; exit 1;;
esac
