#!/usr/bin/env bash
# Keep the kernel log — as a bounded set of snapshots across the boot, not a continuous follow.
# (It was a set of **early** snapshots only, ending at 363 s of uptime, until docs 161 measured what
# that cost: the boot that went to EDL on 2026-09-25 lived 2299 s, so its archive held nothing from
# the time it died. See the schedule comment below the guard.)
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
# Updated 2026-09-21: the set is no longer discarded on the next boot. It is archived to
# `keep/boot-<boot_id>/` (newest 4), and a boot whose ring shows the secure-world failure
# signatures copies itself to `keep/bad-<boot_id>/` the moment the signature appears. Why
# both: `docs/ubuntu-touch/58-*` §4 asks for a diff of a bad boot against a good one
# **before** the failure at t≈49 s, and by then there was nothing left to diff — see §2 of
# `docs/ubuntu-touch/59-*`. `--bad` is the query that diff needs.
#
# Usage: install-kmsg-drain.sh --install | --remove | --status | --read [LINES] | --bad | --follow-on | --follow-off
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

# The snapshot collector. Deliberately a bounded sequence of sleep-then-dump rather than a
# loop: each dump is the *whole* ring as it stands, so a later snapshot is never a superset of
# an earlier one — the early one is the only one that still has the boot messages.
#
# **AND THE SEQUENCE HAS TO OUTLAST THE BOOT IT IS WATCHING (docs 161).** It used to be
# `5 5 5 10 20 40 80 160`, which ends at about 363 s of uptime, and the doc-comment above says
# "coverage of the first ~2 minutes" as if that were the design. Measured on the boot that went
# to EDL on 2026-09-25: `keep/boot-92165447-.../` holds nine snapshots at 36, 41, 46, 52, 62,
# 82, 122, 203 and 363 s — the gaps ARE that list, offset by the ~35 s it takes the unit to
# start — and that boot lived to **2299 s**. So the archive of a boot that dies late holds
# nothing from the time it died, and this is NOT the ring wrapping: the collector had already
# finished. The post-mortem's second witness printed `no death signature` over it, which was
# true of the first six minutes of a thirty-eight minute boot.
#
# The schedule now reaches ~80 min of uptime: 15 snapshots at 36, 41, 46, 51, 61, 81, 121, 201,
# 361, 681, 1001, 1641, 2281, 3561 and 4841 s. At ~250 KiB each that is ~3.75 MiB per boot, and
# keep/ holds four boots, so the whole archive stays under ~15 MiB against the 11 GiB free on
# /userdata. The tail is not doubling for its own sake: what a late death needs is a snapshot
# *near* it, and a boot that dies at minute 30 is not served by a snapshot at minute 6 whose
# contents the ring has long overwritten.
#
# Two additions after 2026-09-21, both of them consequences of the same mistake:
#
#   * **The previous boot's snapshots are archived, not deleted.** This script wiped
#     boot-*.log on every boot, and that is what destroyed the only evidence for doc 58.
#     The one cold boot whose secure world refused was captured — doc 58 quotes its
#     t=49.6 s lines straight out of a snapshot — but the *next* boot wiped that snapshot,
#     and the two files copied aside by hand (keep/boot-badgpu-350s.log, keep/kmsg-badgpu.log)
#     are both ring-buffer tails that start at t=288 s and t=102 s. The ring is ~3470 lines
#     and wraps within about a minute, so nothing earlier was ever retrievable. keep/boot-<id>/
#     is that boot, named by /proc/sys/kernel/random/boot_id, which the *previous* run
#     remembered in keep/current-boot-id (this boot's id is already a fresh one by the time we
#     run). Newest 4 archives are kept — each is ~1.5 MiB and /userdata has 11 GiB free.
#
#   * **A bad boot preserves itself as it happens.** The ring still holds the t=49 s region at
#     the snapshot taken ~75 s in; a minute later it does not, and if the snapshot unit does not
#     run on the following boot the archive above never happens either. So every snapshot is
#     grepped for the two signatures that mean "the secure world refused"
#     (`Invalid firmware metadata`, `scm_call failed ... ret: -12`) and, on the first hit, the
#     whole set collected so far is copied to keep/bad-<boot_id>/ immediately.
SNAPSHOT_SH='
#!/bin/sh
D=/userdata/zl1-kmsg
K=$D/keep
mkdir -p "$D" "$K"

# ---- carry the previous boot forward, before anything is wiped -------------
#
# AND "THE PREVIOUS BOOT" HAS TO BE A DIFFERENT BOOT (docs 161). `current-boot-id` is written by the
# PREVIOUS run of this script, so it normally names another boot -- but this unit can also be started on a
# LIVE boot (the installer enables and starts it, and on 2026-09-25 `--install` was run twice for the
# schedule change), and then `prev` IS this boot. Measured, from the two installs: `keep/boot-61c4abf0-…/`
# was created with the LIVE boot id, `files=9` and then `files=4`, and the `rm -f` below deleted the
# rest of that boot'\''s snapshots. A directory named after the running boot is a witness of nothing, and the
# deletion destroys the only copy of a boot still in progress. So a restart is detected and BOTH steps are
# skipped: nothing is carried forward, nothing is deleted, and the log says which happened.
BOOT=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
[ -n "$BOOT" ] || BOOT=unknown
prev=$(cat "$K/current-boot-id" 2>/dev/null)
[ -n "$prev" ] || prev=unknown
RESTART=0
[ "$prev" = "$BOOT" ] && RESTART=1

set -- "$D"/boot-*.log
if [ -e "$1" ] && [ "$RESTART" = 0 ]; then
    a="$K/boot-$prev"
    n=2
    while [ -e "$a" ]; do a="$K/boot-$prev.$n"; n=$((n + 1)); done
    mkdir -p "$a"
    cp -f "$D"/boot-*.log "$a"/ 2>/dev/null
    printf "%s prev=%s files=%s\n" "$(cut -d. -f1 /proc/uptime)" "$prev" "$(ls "$a" | wc -l)" >> "$K/archive.log"
    # newest 4 only; boot-*/ excludes the hand-made keep/boot-badgpu-*.log files
    ls -dt "$K"/boot-*/ 2>/dev/null | tail -n +5 | while IFS= read -r p; do rm -rf "$p"; done
fi
if [ "$RESTART" = 1 ]; then
    printf "%s skip prev=%s (this boot -- mid-boot restart: nothing carried forward, nothing deleted)\n" \
        "$(cut -d. -f1 /proc/uptime)" "$prev" >> "$K/archive.log"
else
    printf "%s\n" "$BOOT" > "$K/current-boot-id" 2>/dev/null
    # Keep only the snapshots from the current boot, so `--read` is never ambiguous about
    # which boot it is looking at. The uptime in the filename is the marker. The copy above
    # is what makes this safe.
    rm -f "$D"/boot-*.log "$D"/boot.log "$D"/now-*.log 2>/dev/null
fi

snap() {
    f="$D/boot-$(cut -d. -f1 /proc/uptime)s.log"
    dmesg > "$f" 2>/dev/null
    b="$K/bad-$BOOT"
    if grep -qaE "Invalid firmware metadata|scm_call failed.*ret: -12" "$f" 2>/dev/null; then
        # First hit: the whole set so far (the ring still holds the window before the
        # failure). Later snapshots of the same boot are appended one at a time by the
        # branch below, so a bad boot keeps its aftermath as well as its beginning.
        # Deliberately never pruned — bad boots are rare and this is the only copy.
        mkdir -p "$b"
        cp -f "$D"/boot-*.log "$b"/ 2>/dev/null
    elif [ -d "$b" ]; then
        cp -f "$f" "$b"/ 2>/dev/null
    fi
}
snap
for d in 5 5 5 10 20 40 80 160 320 320 640 640 1280 1280; do
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
--help|-h)
  # The header is printed VERBATIM, `#` prefixes and all -- that is the convention every other script
  # here follows and what the health check's property test requires (a line that is not a comment means
  # something other than the header is being printed). It prints the WHOLE header rather than a shorter
  # summary, because the design and its history already live there and a second version would be one
  # more thing to keep in step.
  awk 'NR==1{next} /^#/{print; next} {exit}' "$0"
  exit 0
  ;;
--install)
  guard
  push_scripts
  write_units
  # THE MESSAGE IS DERIVED FROM THE SCRIPT THAT WAS JUST PUSHED, not typed again. It used to restate
  # the schedule by hand and it went stale the moment the schedule changed (docs 161) -- the same shape
  # as every other number in this repo that lived in two places. `snap` is called once before the loop,
  # so the first snapshot is at the unit's start (~35 s of uptime, measured) and the rest follow the list.
  _sched=$(printf '%s\n' "$SNAPSHOT_SH" | sed -n 's/^for d in \(.*\); do$/\1/p')
  [ -n "$_sched" ] || { echo "refusing to report a schedule: the collector's 'for d in' line is unreadable" >&2; exit 1; }
  _upto=$(printf '%s\n' "$_sched" | awk '{for (i = 1; i <= NF; i++) t += $i} END {printf "%d", t + 35}')
  echo "installed. The snapshot unit collects the ring at ~0 s of uptime (one dump before the loop) and"
  echo "then after each of: $_sched s  -- the last snapshot is therefore at about ${_upto} s of uptime."
  echo "Before wiping them it archives the previous boot's set to /userdata/zl1-kmsg/keep/boot-<boot_id>/"
  echo "(newest 4 kept), and any boot whose ring contains the secure-world failure signatures copies"
  echo "itself to keep/bad-<boot_id>/ as soon as the signature appears."
  echo "After a reboot:  $0 --status    then   $0 --bad    then   $0 --read 300"
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
  # `first` / `earliest` must sort by the uptime in the filename, not lexicographically:
  # `ls | sort | head -1` answers boot-111s.log when boot-35s.log is the one with t=0 in it,
  # which is exactly backwards — the earliest snapshot is the only one holding the boot.
  "${SSH[@]}" "
    printf 'snapshot unit : '; systemctl is-active zl1-kmsg-snapshot.service 2>&1
    printf 'follow unit   : '; systemctl is-active zl1-kmsg-follow.service 2>&1
    echo 'snapshots (this boot):'
    for f in $DIR/boot-*.log; do
      [ -f \"\$f\" ] || continue
      printf '  %-28s %6s lines  from %s\n' \"\$(basename \$f)\" \"\$(wc -l < \$f)\" \"\$(head -1 \$f | cut -c1-14)\"
    done
    echo 'archived boots:'
    for d in $DIR/keep/boot-*/; do
      [ -d \"\$d\" ] || continue
      e=\$(ls \$d/boot-*.log 2>/dev/null | sed 's#.*/boot-##; s#s\.log\$##' | sort -n | head -1)
      printf '  %-44s %2s file(s)  earliest boot-%ss.log: %s\n' \"\$(basename \$d)\" \"\$(ls \$d | wc -l)\" \"\$e\" \"\$(head -1 \$d/boot-\${e}s.log 2>/dev/null | cut -c1-14)\"
    done
    for d in $DIR/keep/bad-*/; do
      [ -d \"\$d\" ] || continue
      e=\$(ls \$d/boot-*.log 2>/dev/null | sed 's#.*/boot-##; s#s\.log\$##' | sort -n | head -1)
      printf '  BAD %-40s %2s file(s)  earliest boot-%ss.log: %s\n' \"\$(basename \$d)\" \"\$(ls \$d | wc -l)\" \"\$e\" \"\$(head -1 \$d/boot-\${e}s.log 2>/dev/null | cut -c1-14)\"
    done
    printf 'ring right now : %s lines, earliest: ' \"\$(dmesg | wc -l)\"; dmesg | head -1"
  ;;
--bad)
  guard
  # The doc 58 §4 query: what does a boot in which the secure world refused look like, and
  # does a good boot differ from it *before* the failure? Prints the secure-world lines in
  # time order for every archived boot, plus which func ids each one got and with what errno.
  # Each archive is summarised over its *earliest* snapshot — the one with the boot in it.
  "${SSH[@]}" "
    for d in $DIR/keep/bad-*/ $DIR/keep/boot-*/ $DIR/boot-*.log; do
      [ -e \"\$d\" ] || continue
      case \"\$d\" in */) e=\$(ls \$d/boot-*.log 2>/dev/null | sed 's#.*/boot-##; s#s\.log\$##' | sort -n | head -1)
                         f=\"\$d/boot-\${e}s.log\"; tag=\"\$(basename \$d) / boot-\${e}s.log\";;
                  *)  f=\"\$d\"; tag=\"this boot: \$(basename \$d)\";; esac
      [ -f \"\$f\" ] || continue
      hits=\$(grep -acE 'scm_call failed|hyp_assign_table|Invalid firmware metadata|arm_smmu_assign_table|secure world has been busy' \"\$f\")
      printf '=== %-52s %s line(s), covering %s .. %s\n' \"\$tag\" \"\$hits\" \
        \"\$(head -1 \$f | cut -c1-12)\" \"\$(tail -1 \$f | cut -c1-12)\"
      if [ \"\$hits\" -gt 0 ]; then
        grep -aE 'scm_call failed|hyp_assign_table|Invalid firmware metadata|arm_smmu_assign_table|secure world has been busy' \"\$f\" | head -24
        echo '  -- func id / errno tally:'
        grep -aoE 'func id 0x[0-9a-f]+, ret: -?[0-9]+' \"\$f\" | sort | uniq -c | sort -rn
      fi
      echo
    done"
  ;;
--read)
  guard
  n="${2:-300}"
  # Every snapshot — this boot's, and each archived boot's — plus the live follow, grepped for
  # the driver names the Wi-Fi work needs. This is the command docs/ubuntu-touch/51-* refers to.
  "${SSH[@]}" "
    for f in $DIR/boot-*.log $DIR/keep/boot-*/*.log $DIR/keep/bad-*/*.log $DIR/kmsg.log; do
      [ -f \"\$f\" ] || continue
      n=\$(grep -aicE 'cnss|wlan|wcnss|qca6174|ar6320|qcacld' \"\$f\")
      printf '=== %s  (%s matching lines) ===\n' \"\$f\" \"\$n\"
      grep -aiE 'cnss|wlan|wcnss|qca6174|ar6320|qcacld' \"\$f\" | head -n $n
      echo
    done
    echo '=== earliest snapshot of this boot, first 40 lines ==='
    ls -t $DIR/boot-*.log 2>/dev/null | tail -1 | xargs -r head -40"
  ;;
*)
  # The header, whatever its current length: lines 2..the end of the leading comment block.
  # A fixed line range silently truncates the usage text every time the header grows.
  awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; exit 1;;
esac
