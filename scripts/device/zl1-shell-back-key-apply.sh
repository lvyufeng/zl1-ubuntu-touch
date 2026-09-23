#!/bin/sh
# Mount the patched Lomiri Shell.qml over the read-only image, at boot.
#
# This is the boot-time half of `scripts/install-shell-back-key.sh`: that script builds
# /userdata/zl1-shell-overlay/Shell.qml, checks it with qmllint, and bind-mounts it by hand. This
# one re-does the mount on every boot, because a bind mount does not survive a reboot -- so without
# it the physical Back key stops working again after every restart.
#
# Why the shell file has to be replaced at all, and what the patch does: see the header of
# `scripts/install-shell-back-key.sh` and docs/ubuntu-touch/75-the-back-key-works.md. In one line:
# nothing in the stock shell handles Qt.Key_Back, so the key arrives and dies; the patched file
# makes it do what the Home key does (`launcher.toggleDrawer(false, false, true)`) or close the
# spread.
#
# It is deliberately paranoid, in this order, because the failure mode is a shell that will not
# start, i.e. a black screen on every boot:
#
#   1. `/userdata/zl1-shell-back-key.disabled` exists  -> do nothing. **This is the escape hatch**:
#      create that file over SSH and reboot (or `systemctl disable zl1-shell-back-key.service`), and
#      the stock shell comes back. SSH and the Android container do not depend on the shell, so a
#      black screen is always recoverable this way.
#   2. the overlay is missing or empty                 -> do nothing, and say so in the log.
#   3. the overlay does not contain the patch marker   -> do nothing. A truncated or half-written
#      file must never be mounted over the shell.
#   4. the mount itself fails, or the result does not    -> unmount and fail. It is better to boot
#      read back as the overlay                          the stock shell than a possibly half-applied one.
#
# Everything it does is logged (with the device's uptime, because the wall clock on this port is
# wrong) to a file on the persistent partition, since the shell is normally already up by the time
# anyone can log in and look.
#
# Do not run this by hand to install the overlay: use `install-shell-back-key.sh --install`, which
# also builds it and lints it first.

set -u

OVERLAY=/userdata/zl1-shell-overlay/Shell.qml
TARGET=/usr/share/lomiri/Shell.qml
SENTINEL=/userdata/zl1-shell-back-key.disabled
LOG=/userdata/zl1-shell-back-key.log
MARKER='--- zl1: the physical Back key'

log() {
  printf '%s %s\n' "$(cut -d' ' -f1 /proc/uptime)" "$*" >> "$LOG"
}

if [ -e "$SENTINEL" ]; then
  log "sentinel $SENTINEL present -> leaving the stock shell alone"
  exit 0
fi

if [ ! -s "$OVERLAY" ]; then
  log "ERROR $OVERLAY missing or empty -> leaving the stock shell alone"
  exit 1
fi

# The `--` is not decoration: MARKER begins with `---`, which grep would otherwise read as an
# option and fail on ("grep: unrecognized option"), taking the "do nothing" path for the wrong
# reason. Caught by running this script by hand before trusting it.
if ! grep -q -- "$MARKER" "$OVERLAY"; then
  log "ERROR $OVERLAY does not contain the patch marker -> leaving the stock shell alone"
  exit 1
fi

if mountpoint -q "$TARGET"; then
  log "already mounted over $TARGET; nothing to do"
  exit 0
fi

if ! mount --bind "$OVERLAY" "$TARGET" 2>>"$LOG"; then
  log "ERROR mount --bind $OVERLAY $TARGET failed"
  exit 1
fi

# Read the file back rather than trusting either the exit code or the mount table: an overlay that
# is mounted but wrong is worse than no overlay at all. Checking for the marker at $TARGET is the
# honest check -- it asks the question that matters ("does the shell see the patched file?").
#
# Do NOT verify by grepping `findmnt -no SOURCE` for the overlay's full path: findmnt reports the
# sub-path *relative to the filesystem that holds it*, so a file at /userdata/x shows up as
# `/dev/sda10[/x]`, and a grep for `/userdata/x` fails even though the mount is perfect. That bug
# made this script mount and then immediately unmount, which is exactly why the guard is a read-back.
if grep -q -- "$MARKER" "$TARGET" 2>/dev/null; then
  log "mounted $OVERLAY over $TARGET (marker read back from $TARGET)"
  exit 0
fi

log "ERROR $TARGET does not show the patched file after mounting -> unmounting"
umount "$TARGET" 2>>"$LOG" || log "ERROR could not unmount $TARGET -- a reboot will clear it"
exit 1
