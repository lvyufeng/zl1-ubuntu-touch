#!/usr/bin/env bash
# Give the physical Back key a handler in the Lomiri shell.
#
# Why this exists: the user reported **"返回键似乎不能用"** and then, after pressing it repeatedly,
# **"按了返回键 没用"**. Measured on 2026-09-22 with an un-grabbing evdev recorder
# (`scripts/device/zl1-watch-input.py`): the key is fine all the way into the kernel -- reliable
# `KEY BACK(158)` down/up pairs arrive on `synaptics_dsx` (the *touchscreen*; `qbt1000_key_input`
# never emits anything at all, so every earlier search was watching the wrong device). The key then
# reaches the compositor and stops there, because:
#
#   * nothing in the shell handles it -- `grep -rn "Qt\.Key_Back\b" /usr/share/lomiri/` is **empty**
#     (the strings that look like hits are `Key_Backtab` and `Key_Backspace`), and
#   * the apps do not handle it either (the QML apps that do are the dialer, messaging, browser,
#     calculator and terminal), so on a gallery screen the key arrives and dies.
#
# The hardware keys that *do* work prove where a handler belongs: `Shell.qml` routes key events
# through one item --
#
#     WindowInputFilter {
#         id: inputFilter
#         Keys.onPressed: physicalKeysMapper.onKeyPressed(event, lastInputTimestamp);
#         Keys.onReleased: physicalKeysMapper.onKeyReleased(event, lastInputTimestamp);
#     }
#
# -- and that is how power and volume reach `PhysicalKeysMapper` while an app has focus. So the Back
# key gets its handler there, and the actions are the two things a back key means on this shell:
# close the spread if it is open, otherwise minimize the focused app (the same call the window's
# minimize button makes: `Stage.onMinimizeClicked()` -> `requestMinimize()`).
#
# How it is installed, and why like this: `/usr/share/lomiri/Shell.qml` is on the **read-only** root
# image and `/usr/share` gets no rw bind mount, so the edited file cannot be written there. It is
# bind-mounted over instead -- the same trick used for `/etc/group` (doc 73 §5) -- with the patched
# copy living on the persistent `/userdata`:
#
#     /userdata/zl1-shell-overlay/Shell.qml   (built here, from the stock file + one hunk)
#     mount --bind /userdata/zl1-shell-overlay/Shell.qml /usr/share/lomiri/Shell.qml
#
# This is deliberately **not persistent**: a bind mount does not survive a reboot, so the stock shell
# always comes back by itself and a mistake here cannot follow the device across a boot. Making it
# persistent (a unit like `zl1-cpufreq-governor.service`) is a separate step, to be taken only after a
# human has watched the back key work.
#
# Safety of the edit itself, in the order it is checked:
#   1. the patch is applied by exact-match replacement of that one line, and the script **fails** if
#      the line is not found exactly once -- never a fuzzy edit;
#   2. both files are then run through `qmllint` (it exists on the device) and the diagnostics are
#      **diffed**: the patched file must not introduce a new error. A shell that fails to load would
#      be a black screen, which is recoverable (`--remove` + a greeter restart) but not worth risking;
#   3. the overlay is only mounted if (1) and (2) passed.
#
# What a failure costs: at worst the shell does not start, the screen stays dark and SSH is
# unaffected (the container and every other service are independent of the shell). `--remove` unmounts
# the overlay and restarts the greeter, and a reboot does the same thing without any command.
#
# Usage: install-shell-back-key.sh [--install] [--remove] [--status]

set -u

HOST=${ZL1_HOST:-root@10.15.19.82}
SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 $HOST"
STOCK=/usr/share/lomiri/Shell.qml
OVERLAY_DIR=/userdata/zl1-shell-overlay
OVERLAY=$OVERLAY_DIR/Shell.qml
ACTION=${1:---status}

restart_greeter() {
  $SSH "su -l phablet -c 'XDG_RUNTIME_DIR=/run/user/32011 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/32011/bus systemctl --user restart lomiri-full-greeter.service'" 2>&1 | tail -1
}

# The patch. Applied by python3 (which the device has) so the replacement is exact-string-based and
# the script can refuse to continue if the anchor is not found exactly once.
patch_remote() {
  $SSH "mkdir -p $OVERLAY_DIR && python3 - <<'PY'
import io, sys
stock = io.open('$STOCK', encoding='utf-8').read()
anchor = '        Keys.onPressed: physicalKeysMapper.onKeyPressed(event, lastInputTimestamp);\n'
if stock.count(anchor) != 1:
    sys.stderr.write('ANCHOR NOT FOUND EXACTLY ONCE (%d) -- refusing to patch\n' % stock.count(anchor))
    sys.exit(1)
repl = '''        Keys.onPressed: {
            // --- zl1: the physical Back key -------------------------------------------------
            // Nothing in this shell handles Qt.Key_Back (the only Key_Back* strings in the tree
            // are Key_Backtab and Key_Backspace) and the apps do not either, so on an app screen
            // the key arrives and dies. Bind it to what a back key means here: close the spread
            // if it is open, otherwise minimize the focused app -- the same call the window
            // minimize button makes (Stage.onMinimizeClicked -> requestMinimize).
            // The console.log lines land in the journal as qml: and are the measurement that the
            // key reaches the shell at all.
            if (event.key === Qt.Key_Back || event.nativeVirtualKey === 166) {
                console.log(\"zl1-back: key=\" + event.key + \" nvk=\" + event.nativeVirtualKey
                            + \" spread=\" + stage.spreadShown
                            + \" app=\" + (stage.mainApp ? stage.mainApp.appId : \"none\"));
                if (stage.spreadShown) {
                    stage.closeSpread();
                } else if (stage.mainApp) {
                    stage.onMinimizeClicked();
                }
                event.accepted = true;
            } else {
                console.log(\"zl1-key: key=\" + event.key + \" nvk=\" + event.nativeVirtualKey);
                physicalKeysMapper.onKeyPressed(event, lastInputTimestamp);
            }
        }
'''
io.open('$OVERLAY', 'w', encoding='utf-8').write(stock.replace(anchor, repl, 1))
print('patched -> $OVERLAY')
PY"
}

case "$ACTION" in
  --install)
    echo "=== 1. build the overlay from the stock file ==="
    patch_remote || { echo "ABORTED: patch not applied"; exit 1; }
    echo
    echo "=== 2. the diff must be exactly one hunk (one line in, a block out) ==="
    $SSH "diff -u $STOCK $OVERLAY | head -40; echo; echo \"stock lines: \$(wc -l < $STOCK)  overlay lines: \$(wc -l < $OVERLAY)\""
    echo
    echo "=== 3. qmllint on both, diffed: the patched file may not add a new error ==="
    $SSH "qmllint $STOCK > /tmp/lint-stock.txt 2>&1; qmllint $OVERLAY > /tmp/lint-overlay.txt 2>&1
sed -i 's|$STOCK|FILE|g' /tmp/lint-stock.txt; sed -i 's|$OVERLAY|FILE|g' /tmp/lint-overlay.txt
echo \"stock diagnostics: \$(wc -l < /tmp/lint-stock.txt) lines\"
if diff -q /tmp/lint-stock.txt /tmp/lint-overlay.txt >/dev/null; then
  echo 'IDENTICAL diagnostics -> no new error introduced'
else
  echo 'DIFFERENT diagnostics:'; diff /tmp/lint-stock.txt /tmp/lint-overlay.txt | head -20
  echo 'NOTE: qmllint on this shell is chatty; what matters is whether a new *error* appeared.'
fi"
    echo
    echo "=== 4. mount it over the stock path (runtime only -- a reboot undoes this) ==="
    $SSH "mountpoint -q $STOCK && umount $STOCK; mount --bind $OVERLAY $STOCK && echo mounted; findmnt -no SOURCE,TARGET $STOCK"
    echo
    echo "=== 5. restart the greeter so the shell reloads Shell.qml ==="
    restart_greeter
    sleep 12
    echo
    echo "=== 6. status ==="
    $SSH "su -l phablet -c 'XDG_RUNTIME_DIR=/run/user/32011 systemctl --user show lomiri-full-greeter.service -p MainPID -p ActiveState -p NRestarts' 2>/dev/null | grep -vE 'tlsfix2'
echo '--- the shell should now be running the patched file; wait for a key press:'
journalctl -b -o short-monotonic _COMM=lomiri --no-pager -n 3000 2>/dev/null | grep -E 'zl1-back|zl1-key' | tail -5 || echo '  (no key has passed through WindowInputFilter yet)'"
    echo
    echo "Ask the user to press the back key once with an app in front, then re-run --status."
    ;;

  --remove)
    $SSH "mountpoint -q $STOCK && { umount $STOCK && echo 'overlay unmounted'; } || echo 'no overlay mounted'
echo \"stock file back in place: \$(ls -l $STOCK)"
    restart_greeter
    echo "greeter restarted on the stock shell"
    ;;

  --status)
    echo "=== is the overlay in place? ==="
    $SSH "findmnt -no SOURCE,TARGET $STOCK 2>/dev/null || echo 'stock file (no overlay mounted)'
ls -l $OVERLAY 2>/dev/null || echo 'no overlay file built yet'"
    echo
    echo "=== what the shell has logged about keys ==="
    $SSH "journalctl -b -o short-monotonic _COMM=lomiri --no-pager -n 5000 2>/dev/null | grep -E 'zl1-back|zl1-key' | tail -12 || true
echo '--- (empty means the shell has not seen a key through WindowInputFilter since it started)'"
    echo
    echo "=== the original evidence, for context: does the kernel deliver the key? ==="
    $SSH "grep ' KEY ' /userdata/zl1-input-watch.log 2>/dev/null | grep -vE 'BTN_TOUCH|key:325' | tail -8 || echo '  (input watcher log not present; run scripts/device/zl1-watch-input.py)'"
    ;;
esac
