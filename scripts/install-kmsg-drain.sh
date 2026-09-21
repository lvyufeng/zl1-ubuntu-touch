#!/usr/bin/env bash
# Keep the kernel log — as a bounded set of **early** snapshots, not a continuous follow.
#
# Why this exists: on 2026-09-21 the kernel ring buffer was unreadable on this device. Two
# things were wrong, and the second one changed the design:
#
#   1. `journalctl -k` returns 1 line — journald is not capturing /dev/kmsg — so the only
#      source is the ring itself.
#   2. The ring is small and the noise is fast. Measured on the device:
#          ring capacity   ~3470 lines / ~249 KiB
#          while idle      3473 -> 3470 lines in 6 s   (nothing: no traffic, no noise)
#          while talking   ~3480 lines in 3 s          (~90 KiB/s, a burst per transmit)
#      The noise is `tx_complete` WARN stack traces from the uether TX patch
#      (scripts/patch-uether-tx-wakeup.sh), and it is triggered by *host traffic*: the
#      device WARNs on transmit, so the ring is only wrapped while something is talking to
#      it. That is why the boot messages can still be caught — but only in the first
#      seconds, before the host starts pinging.
#
# So a continuous `dmesg -W >> file` is the wrong tool twice over: it would write ~90 KiB/s
# (≈8 GiB/day) onto the eMMC for no benefit, because by the time it runs the messages worth
# keeping are already hours old. What is actually wanted is the *boot* log, and the way to
# get it is to snapshot the ring as early as systemd will run us, and again a few times
# while the boot settles. The whole set costs a couple of MiB per boot and then the unit
# exits.
#
# This is the prerequisite for the Wi-Fi work: `docs/ubuntu-touch/49-*` records what
# happens when you go at a driver you cannot see, and it is an EDL. `51-*` is the grep list
# to run against the snapshots once they exist.
#
# Usage: install-kmsg-drain.sh --install | --remove | --status | --read [LINES] | --follow-on | --follow-off
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

# The snapshot collector. Deliberately a short, bounded sequence of sleep-then-dump rather
# than a loop: the point is coverage of the first ~2 minutes, and each dump is the *whole*
# ring as it stands, so a later snapshot is never a superset of an earlier one — the early
# one is the only one that still has the boot messages.
SNAPSHOT_SH='
#!/bin/sh
D=/userdata/zl1-kmsg
mkdir -p "$D"
# Keep only the snapshots from the current boot, so `--read` is never ambiguous about
# which boot it is looking at. The uptime in the filename is the marker.
rm -f "$D"/boot-*.log "$D"/boot.log "$D"/now-*.log 2>/dev/null
snap() {
    dmesg > "$D/boot-$(cut -d. -f1 /proc/uptime)s.log" 2>/dev/null
}
snap
for d in 5 10 20 40 80 160; do
    sleep "$d"
    snap
done
'
# Only for the rare case where a *live* trace is needed (e.g. watching a driver while
# something is deliberately poked). Off by default, and the unit comment says why.
FOLLOW_SH='
#!/bin/sh
D=/userdata/zl1-kmsg
mkdir -p "$D"
rotate() {
    [ -f "$D/kmsg.log" ] || return 0
    [ "$(wc -c < "$D/kmsg.log")" -gt 8388608 ] || return 0
    tail -c 4194304 "$D/kmsg.log" > "$D/kmsg.log.tmp" 2>/dev/null &&
        mv "$D/kmsg.log.tmp" "$D/kmsg.log"
    echo "=== rotated at uptime $(cut -d. -f1 /proc/uptime)s ===" >> "$D/kmsg.log"
}
# `dmesg -W` (follow-new), not `read` on /dev/kmsg: bash'\''s read() takes one byte at a
# time, and a partial read of a /dev/kmsg record fails with EINVAL, so a `while read` loop
# over it exits immediately having read nothing. That is how the first version of this
# script "succeeded" and wrote no log at all.
n=0
dmesg -W 2>/dev/null | while IFS= read -r line; do
    printf "%s\n" "$line" >> "$D/kmsg.log"
    n=$((n + 1))
    [ $((n % 500)) -eq 0 ] && rotate
done
'

push_scripts() {
  tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
  printf '%s\n' "$SNAPSHOT_SH" > "$tmp.snap"
  printf '%s\n' "$FOLLOW_SH"   > "$tmp.follow"
  # The two assignments above start with `='` and a newline, so the strings begin with a
  # blank line and the file's first line is *not* the shebang. systemd then refuses it with
  # `Failed to execute ... Exec format error` / status=203/EXEC, which says nothing at all
  # about why. Strip the leading blank lines and prove the result starts with `#!` before it
  # goes anywhere near the device.
  for f in "$tmp.snap" "$tmp.follow"; do
    sed -i '/./,$!d' "$f"
    case "$(head -1 "$f")" in
      '#!'*) ;;
      *) echo "refusing to push $f: first line is not a shebang ($(head -1 "$f"))" >&2; exit 1;;
    esac
  done
  "${SSH[@]}" "mkdir -p $DIR"
  scp -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "$tmp.snap" "$DEV:$DIR/snapshot.sh"
  scp -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "$tmp.follow" "$DEV:$DIR/follow.sh"
  "${SSH[@]}" "chmod 755 $DIR/snapshot.sh $DIR/follow.sh"
  rm -f "$tmp.snap" "$tmp.follow"
}

write_units() {
  "${SSH[@]}" "bash -s" <<'REMOTE'
set -u
# Early and non-blocking: DefaultDependencies=no plus Before=sysinit.target puts the unit
# near the front of boot, and Type=simple means systemd only waits for the fork, not for
# the snapshots — a oneshot that sleeps for 160 s must never sit in front of sysinit.
cat > /etc/systemd/system/zl1-kmsg-snapshot.service <<'UNIT'
[Unit]
Description=zl1: snapshot the kernel ring early, while the boot log is still in it
DefaultDependencies=no
After=local-fs.target
Before=sysinit.target shutdown.target
Conflicts=shutdown.target

[Service]
Type=simple
ExecStart=/userdata/zl1-kmsg/snapshot.sh
Restart=no
TimeoutStartSec=0
OOMScoreAdjust=-500

[Install]
WantedBy=sysinit.target
UNIT

cat > /etc/systemd/system/zl1-kmsg-follow.service <<'UNIT'
[Unit]
Description=zl1: follow /dev/kmsg (live trace only — writes ~90 KiB/s while the host talks)
After=multi-user.target

[Service]
Type=simple
ExecStart=/userdata/zl1-kmsg/follow.sh
Restart=always
RestartSec=5
OOMScoreAdjust=-500

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable zl1-kmsg-snapshot.service >/dev/null 2>&1
systemctl disable zl1-kmsg-follow.service >/dev/null 2>&1
systemctl reset-failed zl1-kmsg-snapshot.service zl1-kmsg-follow.service >/dev/null 2>&1
systemctl restart zl1-kmsg-snapshot.service
sleep 3
echo "snapshot unit: $(systemctl is-active zl1-kmsg-snapshot.service)"
REMOTE
}

case "${1:-}" in
--install)
  guard
  push_scripts
  write_units
  echo "installed. The snapshot unit collects the ring at ~0, 5, 15, 35, 75, 155, 315 s of uptime."
  echo "After a reboot, read them with: $0 --read 300"
  ;;
--remove)
  guard
  "${SSH[@]}" '
    systemctl disable --now zl1-kmsg-snapshot.service zl1-kmsg-follow.service >/dev/null 2>&1
    rm -f /etc/systemd/system/zl1-kmsg-snapshot.service /etc/systemd/system/zl1-kmsg-follow.service
    systemctl daemon-reload
    echo "removed the units. The snapshots and scripts stay on /userdata/zl1-kmsg."'
  ;;
--follow-on)
  guard
  "${SSH[@]}" 'systemctl enable --now zl1-kmsg-follow.service >/dev/null 2>&1; sleep 2; echo "follow: $(systemctl is-active zl1-kmsg-follow.service)"'
  ;;
--follow-off)
  guard
  "${SSH[@]}" 'systemctl disable --now zl1-kmsg-follow.service >/dev/null 2>&1; echo "follow: $(systemctl is-active zl1-kmsg-follow.service)"'
  ;;
--status)
  guard
  "${SSH[@]}" "
    printf 'snapshot unit : '; systemctl is-active zl1-kmsg-snapshot.service 2>&1
    printf 'follow unit   : '; systemctl is-active zl1-kmsg-follow.service 2>&1
    echo 'snapshots:'
    for f in $DIR/boot-*.log; do
      [ -f \"\$f\" ] || continue
      printf '  %-28s %6s lines\n' \"\$(basename \$f)\" \"\$(wc -l < \$f)\"
    done
    printf 'ring right now : %s lines, earliest: ' \"\$(dmesg | wc -l)\"; dmesg | head -1"
  ;;
--read)
  guard
  n="${2:-300}"
  # Every snapshot and the live follow, grepped for the driver names the Wi-Fi work needs.
  # This is the command docs/ubuntu-touch/51-* refers to.
  "${SSH[@]}" "
    for f in $DIR/boot-*.log $DIR/kmsg.log; do
      [ -f \"\$f\" ] || continue
      n=\$(grep -aicE 'cnss|wlan|wcnss|qca6174|ar6320|qcacld' \"\$f\")
      printf '=== %s  (%s matching lines) ===\n' \"\$f\" \"\$n\"
      grep -aiE 'cnss|wlan|wcnss|qca6174|ar6320|qcacld' \"\$f\" | head -n $n
      echo
    done
    echo '=== earliest snapshot, first 40 lines ==='
    ls -t $DIR/boot-*.log 2>/dev/null | tail -1 | xargs -r head -40"
  ;;
*)
  sed -n '2,35p' "$0"; exit 1;;
esac
