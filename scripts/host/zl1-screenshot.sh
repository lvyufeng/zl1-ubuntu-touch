#!/usr/bin/env bash
# Take a screenshot of the zl1's screen from the host, over SSH, with no fingers on the phone.
#
# Why this exists: there was no way to see what is on this device's screen. Every other path was
# tried and closed (docs/ubuntu-touch/76 and 74 §4.1):
#
#   * /dev/fb0 is a leftover framebuffer -- turning the display on over DBus moved ActiveOutputs
#     from 0 0 to 1 0 while fb0 stayed byte-identical, so it does not hold what is being scanned out;
#   * the compositor's DBus surface has only Display, Input, PowerButton and UserActivity: no
#     screenshot method;
#   * `mirscreencast` cannot initialise gralloc from the host (`failed to find/load gralloc module`);
#   * the shell's own two triggers -- Volume Up + Volume Down together, and the PrintScreen key
#     through a GlobalShortcut -- both need fingers on the phone.
#
# So the shell itself takes the picture. The overlay (scripts/shell-overlay-patch.py, hunk 2) adds a
# Timer that polls /userdata/zl1-shell-shot.request every 2 s and, when the file's *contents* change,
# calls itemGrabber.capture(shell) -- the same call the volume-key trigger makes. ItemGrabber writes
# the PNG itself and logs the path, so the capture is verifiable from the journal rather than assumed.
#
# The overlay has to be installed for this to work: `scripts/install-shell-back-key.sh --install`.
# This script says so instead of failing quietly if the marker is missing.
#
# Usage: zl1-screenshot.sh [--out FILE] [--timeout SECONDS] [--quiet]
#
#   --out FILE   where to put the PNG locally (default: /tmp/zl1-shot-<timestamp>.png)
#   --timeout N  seconds to wait for the PNG to appear on the device (default 20)

set -u

HOST=${ZL1_HOST:-root@10.15.19.82}
SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 $HOST"
SHOT_DIR=/home/phablet/Pictures/Screenshots
REQUEST=/userdata/zl1-shell-shot.request
OUT=""
TIMEOUT=20
QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --out)     OUT="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --quiet)   QUIET=1; shift ;;
    # --help prints this file's own header: the header IS the manual (it carries the Usage line),
    # and the length of it is not something a fixed line range can know.
    --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0" ; exit 0 ;;
    *) echo "unknown argument $1 (try --help)" >&2; exit 2 ;;
  esac
done
[ -n "$OUT" ] || OUT="/tmp/zl1-shot-$(date +%Y%m%d-%H%M%S).png"
say() { [ "$QUIET" = 1 ] || echo "$*"; }

# The poller lives in the shell's copy of Shell.qml, not in the file on disk, so asking the running
# shell is the only honest check -- the overlay file can exist and not be mounted (see the boot
# applier's own note about findmnt and sub-paths).
if ! $SSH "grep -q zl1ShotTimer /proc/\$(su -l phablet -c 'XDG_RUNTIME_DIR=/run/user/32011 systemctl --user show lomiri-full-greeter.service -p MainPID --value' 2>/dev/null | tail -1)/root/usr/share/lomiri/Shell.qml 2>/dev/null"; then
  say "the running shell has no screenshot poller."
  say "install the overlay first:  bash scripts/install-shell-back-key.sh --install"
  exit 1
fi

before=$($SSH "ls -1t $SHOT_DIR/*.png 2>/dev/null | head -1")
# The poller compares the file's *contents*, so a fresh value is what fires it -- rewriting the same
# number twice does nothing, and a stale file left over from a previous run cannot re-trigger.
$SSH "date +%s%N > $REQUEST"

i=0
new=""
while [ "$i" -lt "$TIMEOUT" ]; do
  sleep 2
  i=$((i + 2))
  new=$($SSH "ls -1t $SHOT_DIR/*.png 2>/dev/null | head -1")
  [ -n "$new" ] && [ "$new" != "$before" ] && break
done

if [ -z "$new" ] || [ "$new" = "$before" ]; then
  say "no new PNG after ${TIMEOUT}s -- the shell did not capture."
  say "what the shell logged (zl1-shot: poller alive is the one that says the timer runs):"
  $SSH "journalctl -b -o short-monotonic _COMM=lomiri --no-pager -n 3000 2>/dev/null | grep -aE 'zl1-shot|ItemGrabber' | tail -6"
  exit 1
fi

# A new PNG is not yet a *finished* PNG: the poller above finds it the moment it is created, so
# copying straight away races the shell's own write. Measured 2026-09-23: 4 of 17 grabs came back
# truncated this way (525118, 623566, 254386 and 516914 bytes; the complete ones of the same scene
# were ~565 KB and ~750 KB), and the truncation is invisible downstream -- the file still has a
# valid PNG header, so `file` reports it happily and only a decoder complains. So wait for the size
# to stop changing before copying.
s1=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  s2=$($SSH "stat -c %s '$new' 2>/dev/null || echo 0")
  [ "$s2" -gt 0 ] && [ "$s2" = "$s1" ] && break
  s1=$s2
  sleep 1
done
[ "$s1" -gt 0 ] || { say "the shell created $new but it never grew past 0 bytes"; exit 1; }

copy() {
  scp -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "$HOST:$new" "$OUT"
}
# ...and then check the copy really is a whole PNG. The last 12 bytes of every PNG are the IEND
# chunk -- length 0, "IEND", and its CRC -- so a file that does not end in those 8 bytes is a
# truncated file whatever its header says. This is the only reliable test here that needs nothing
# installed on either end.
complete() { [ "$(tail -c 8 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "49454e44ae426082" ]; }

ok=0
for _ in 1 2 3; do
  copy || { say "captured $new on the device ($s1 bytes) but could not copy it"; exit 1; }
  complete "$OUT" && { ok=1; break; }
  say "the copy of $new is not a complete PNG yet -- copying it again"
  sleep 2
done

if [ "$ok" != 1 ]; then
  say "WARNING: $OUT is truncated ($(stat -c %s "$OUT" 2>/dev/null) of $s1 bytes) after 3 tries."
  say "         The shell may still have been writing. Do not treat this file as a picture."
  exit 1
fi

say "$OUT"
# A zero-byte or tiny PNG is a capture that failed after logging success, so it is worth saying which.
sz=$(stat -c %s "$OUT" 2>/dev/null || echo 0)
[ "$sz" -lt 1000 ] && say "WARNING: only $sz bytes -- that PNG is probably not a picture"
exit 0
