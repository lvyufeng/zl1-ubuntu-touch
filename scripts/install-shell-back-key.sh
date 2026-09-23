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
# close the spread if it is open, otherwise minimize the focused app.
#
# **What Back does, in three attempts** (all three measured, 2026-09-23).
#
# 1. `stage.onMinimizeClicked()` -> one journal line per press and then a real error:
#
#        qml: zl1-back: key=16777313 nvk=undefined spread=false app=morph-browser
#        file:///usr/share/lomiri//Shell.qml:306: TypeError: Type error
#
#    So the key *did* reach the handler (16777313 is `Qt.Key_Back`, 0x01000061) and the action was
#    what failed. `onMinimizeClicked` is not a public function of `Stage`; it is a signal handler
#    inside `Stage/Stage.qml`:
#
#        Connections {
#            target: panelState                       // PanelState { id: panelState } -- Shell.qml
#            function onMinimizeClicked() { if (priv.focusedAppDelegate) { priv.focusedAppDelegate.requestMinimize(); } }
#        }
#
# 2. `panelState.minimizeClicked()` -- emitting that signal is the shell's own minimize path, so this
#    was the obvious repair. It runs **clean: no error at all, and nothing happens on screen.** The
#    reason is in the same file: `PanelState.decorationsVisible` is bound to `mode == "windowed"`, so
#    in phone mode (`staged`) there are no window decorations and therefore no minimize button -- a
#    minimized window is simply not a state this shell has on a phone. `priv` (where
#    `minimizeAllWindows()` lives) is not reachable from Shell.qml either.
#
# 3. What the HOMEPAGE key does, which the user has watched work, is
#    `launcher.toggleDrawer(false, false, true)` (`WindowInputMonitor.onHomeKeyActivated`). So Back
#    now makes that same call: it toggles, so it closes the launcher drawer/panel when one is open
#    and otherwise brings the launcher forward -- i.e. it leaves the app. `greeter.active` is the
#    Home key's own guard, kept so a pocket press does nothing on the lock screen. The spread, which
#    is a distinct shell state, is still closed directly with `stage.closeSpread()`.
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
# Usage: install-shell-back-key.sh [--install] [--remove] [--status] [--persist] [--unpersist]
#
#   --install    build the overlay, lint it, mount it, restart the greeter (runtime only)
#   --remove     unmount it and go back to the stock shell (runtime only)
#   --status     is it mounted, and has the shell logged any key presses
#   --persist    make it survive a reboot: install the applier + a systemd unit. **The overlay has
#                to work first, and the boot behaviour is not verified until a real reboot.**
#   --unpersist  remove that unit and applier again (does not unmount the current overlay)

set -u

HOST=${ZL1_HOST:-root@10.15.19.82}
SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 $HOST"
STOCK=/usr/share/lomiri/Shell.qml
OVERLAY_DIR=/userdata/zl1-shell-overlay
OVERLAY=$OVERLAY_DIR/Shell.qml
UNIT=/etc/systemd/system/zl1-shell-back-key.service
APPLIER=/etc/systemd/system/zl1-shell-back-key.sh
APPLIER_SRC="$(cd "$(dirname "$0")" && pwd)/device/zl1-shell-back-key-apply.sh"
SENTINEL=/userdata/zl1-shell-back-key.disabled
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
            // if it is open, otherwise minimize the focused app.
            //
            // Leaving the app is done with the SAME call the Home key makes, not with a minimize:
            //   * calling Stage.onMinimizeClicked() throws "TypeError: Type error" -- it is only a
            //     signal handler inside Stage.qml, not a public function (measured 2026-09-23);
            //   * emitting panelState.minimizeClicked() runs clean (no error at all) and changes
            //     nothing on screen: in phone mode the stage is "staged" and window decorations --
            //     hence a minimize button -- only exist when mode == "windowed"
            //     (PanelState.decorationsVisible is bound to exactly that), so a minimized window
            //     is not a state this shell has on a phone;
            //   * WindowInputMonitor.onHomeKeyActivated, i.e. what the HOMEPAGE key does and what
            //     the user has seen work, is launcher.toggleDrawer(false, false, true);
            //     Launcher.toggleDrawer toggles, so the same call closes an open drawer/panel and
            //     otherwise brings the launcher forward. greeter.active is the same guard the
            //     Home key uses, to keep pocket presses from doing anything on the lock screen.
            //
            // The console.log lines land in the journal as qml: and are the measurement that the
            // key reaches the shell at all: zl1-back: for Qt.Key_Back, zl1-key: for the keys
            // that were already handled. They are cheap (a line per key press, not per frame).
            if (event.key === Qt.Key_Back || event.nativeVirtualKey === 166) {
                console.log(\"zl1-back: key=\" + event.key + \" nvk=\" + event.nativeVirtualKey
                            + \" spread=\" + stage.spreadShown
                            + \" drawer=\" + launcher.drawerShown
                            + \" app=\" + (stage.mainApp ? stage.mainApp.appId : \"none\"));
                if (stage.spreadShown) {
                    stage.closeSpread();
                } else if (!greeter.active && (stage.mainApp || launcher.drawerShown)) {
                    launcher.toggleDrawer(false, false, true);
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
    echo "=== 0. drop any overlay that is already mounted ==="
    # This has to come first, and it is not just tidiness: while an overlay is mounted, $STOCK reads
    # the *patched* file, so step 1's exact-match anchor would not be found and a re-install would
    # abort with "ANCHOR NOT FOUND EXACTLY ONCE (0)". The patch must always be built from the file
    # the read-only image ships, and the only way to see that file is with nothing over it.
    $SSH "mountpoint -q $STOCK && { umount $STOCK && echo 'unmounted the previous overlay'; } || echo 'nothing was mounted'"
    echo
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

  --persist)
    echo "=== 1. the overlay must exist and be the patched file (run --install first) ==="
    $SSH "ls -l $OVERLAY && grep -c 'zl1: the physical Back key' $OVERLAY" || {
      echo "ABORTED: no built overlay on the device -- run --install first"; exit 1; }
    echo
    echo "=== 2. install the boot-time applier to a writable path ==="
    scp -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "$APPLIER_SRC" "$HOST:$APPLIER" || { echo "ABORTED: scp failed"; exit 1; }
    $SSH "chmod 755 $APPLIER && ls -l $APPLIER"
    echo
    echo "=== 3. install the unit ==="
    $SSH "cat > $UNIT <<'EOF'
[Unit]
Description=Mount the patched Lomiri Shell.qml (physical Back key handler) over the read-only image
Documentation=file:///userdata/zl1-shell-back-key.log
After=local-fs.target
RequiresMountsFor=/userdata
Before=multi-user.target graphical.target
ConditionPathExists=$OVERLAY

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$APPLIER
TimeoutStartSec=30

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable zl1-shell-back-key.service 2>&1 | tail -2"
    echo
    echo "=== 4. what systemd actually has (systemctl cat is the only honest check) ==="
    $SSH "systemctl cat zl1-shell-back-key.service | head -30; echo; systemctl is-enabled zl1-shell-back-key.service"
    echo
    echo "NOTE: this changes what happens at boot and that has **not** been verified yet --"
    echo "      verifying it needs a real reboot, which is a separate step to agree on."
    echo "Escape hatch, usable over SSH even if the shell is black:"
    echo "      touch $SENTINEL     # then a reboot brings the stock shell back"
    echo "      systemctl disable zl1-shell-back-key.service"
    ;;
  --unpersist)
    $SSH "systemctl disable zl1-shell-back-key.service 2>&1 | tail -1
rm -f $UNIT $APPLIER && systemctl daemon-reload
echo 'removed:'; ls -l $UNIT $APPLIER 2>&1 | tail -2"
    echo "(the overlay that is mounted right now is untouched; use --remove for that)"
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
