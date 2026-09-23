#!/usr/bin/env python3
"""Patch the stock Lomiri Shell.qml and write the patched copy to a second path.

Run on the device by `scripts/install-shell-back-key.sh`:

    python3 shell-overlay-patch.py /usr/share/lomiri/Shell.qml /userdata/zl1-shell-overlay/Shell.qml

It lives in a file rather than inside a heredoc in the installer on purpose. Three separate bugs came
out of the embedded version, all the same shape: the installer pipes the program through `ssh "..."`,
a double-quoted string, so the *local* shell processed it too. Every `"` in the Python had to be
escaped as `\"` and anything in backticks was run as a command. The failures were

  * a comment containing `mirscreencast` ran `mirscreencast` locally -- "command not found";
  * a comment in backticks produced "syntax error near unexpected token `('";
  * and finally the escaped quotes around the QML strings were eaten, so the patched file came out
    with `console.log(zl1-shot: capture for  + v)`. That one **took the shell down**: Lomiri logged
    `Shell.qml:957 Expected token ','` and then "Lomiri encountered an unrecoverable error while
    loading: Type Shell unavailable" -- no shell at all. The overlay being runtime-only (a bind mount,
    not a write to the image) is what made that a 20-second fix instead of a broken device.

Two properties make this safe to run against a live phone:

  * every change is an **exact-string replacement**, and the script exits non-zero if the anchor does
    not appear exactly once -- never a fuzzy edit, never a partial one;
  * **nothing is written until every hunk has been applied**, so a failure at hunk 2 cannot leave a
    half-patched file to be mounted over the shell (the installer checks the exit code before it
    mounts, and the boot applier refuses to mount anything without the patch marker).
"""

import io
import sys

# ---------------------------------------------------------------------------------------------
# hunk 1: the physical Back key
# ---------------------------------------------------------------------------------------------
# Nothing in this shell handles Qt.Key_Back (the only Key_Back* strings in the tree are Key_Backtab
# and Key_Backspace) and the apps do not either, so on an app screen the key arrives and dies.
# The handler goes at the one place every hardware key already goes through, because that is how
# power and volume reach PhysicalKeysMapper while an app has focus.
BACK_KEY_ANCHOR = '        Keys.onPressed: physicalKeysMapper.onKeyPressed(event, lastInputTimestamp);\n'

BACK_KEY_REPLACEMENT = '''        Keys.onPressed: {
            // --- zl1: the physical Back key -------------------------------------------------
            // Close the spread if it is open, otherwise leave the app -- with the SAME call the
            // Home key makes, not with a minimize:
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
            //     otherwise brings the launcher forward. greeter.active is the same guard the Home
            //     key uses, to keep pocket presses from doing anything on the lock screen.
            //
            // The console.log lines land in the journal as qml: and are the measurement that the
            // key reaches the shell at all: zl1-back: for Qt.Key_Back, zl1-key: for the keys that
            // were already handled. They are cheap: one line per key press, not per frame.
            if (event.key === Qt.Key_Back || event.nativeVirtualKey === 166) {
                console.log("zl1-back: key=" + event.key + " nvk=" + event.nativeVirtualKey
                            + " spread=" + stage.spreadShown
                            + " drawer=" + launcher.drawerShown
                            + " app=" + (stage.mainApp ? stage.mainApp.appId : "none"));
                if (stage.spreadShown) {
                    stage.closeSpread();
                } else if (!greeter.active && (stage.mainApp || launcher.drawerShown)) {
                    launcher.toggleDrawer(false, false, true);
                }
                event.accepted = true;
            } else {
                console.log("zl1-key: key=" + event.key + " nvk=" + event.nativeVirtualKey);
                physicalKeysMapper.onKeyPressed(event, lastInputTimestamp);
            }
        }
'''

# ---------------------------------------------------------------------------------------------
# hunk 2: an on-demand screenshot
# ---------------------------------------------------------------------------------------------
# Same reasoning as hunk 1 for *how* (a bind-mounted copy, because /usr/share is on the read-only
# image) and a different reason for *why*: there is no other way to see what is on this device's
# screen from the host.
#
#   * /dev/fb0 is a leftover framebuffer that does not contain what is being scanned out -- opening
#     the display over DBus changed `ActiveOutputs` from 0 0 to 1 0 while fb0 stayed byte-identical
#     (doc 68 §4.1), so it cannot be used as a screenshot source;
#   * the compositor's DBus surface offers only Display, Input, PowerButton and UserActivity -- there
#     is no screenshot method;
#   * the two triggers the shell itself has -- Volume Up + Volume Down together, and the PrintScreen
#     key through a GlobalShortcut -- both need fingers on the phone;
#   * `mirscreencast` is installed but cannot initialise gralloc from the host (`failed to find/load
#     gralloc module`: `ro.hardware` is `qcom` and the vendor `hw/` directory ships
#     `gralloc.msm8996.so`, so the lookup that libhybris performs does not match what is there).
#
# So the shell polls a file on the persistent partition and grabs itself when the contents change.
# From the host:
#
#     ssh root@... 'date +%s%N > /userdata/zl1-shell-shot.request'
#
# ItemGrabber logs the PNG path itself ("ItemGrabber: Saving image to ..."), and
# "zl1-shot: capture for <value>" is logged just before it; both land in the journal under the
# shell's pid. The *contents* are compared rather than the file's existence, so repeated captures
# work and a stale file never re-fires. The first poll's outcome is logged once, because the risky
# part is the file:// XMLHttpRequest and a silent failure would be indistinguishable from a timer
# that never ran.
#
# What it captures is the shell item (`itemGrabber.capture(shell)`), which is the whole scene --
# including app surfaces, since qtmir renders them into the shell's scene as texture items. Whether
# that is faithful for a camera preview is exactly what the first capture is for.
SCREENSHOT_ANCHOR = '    Timer {\n        id: cursorHidingTimer\n'

SCREENSHOT_REPLACEMENT = '''    Timer {
        // --- zl1: on-demand screenshot ---------------------------------------------------
        // Polls /userdata/zl1-shell-shot.request every 2 s and, when its contents change, grabs
        // the whole shell and saves a PNG. See the note in shell-overlay-patch.py (hunk 2) for why
        // this exists at all.
        id: zl1ShotTimer
        interval: 2000
        running: true
        repeat: true
        property string lastSeen: ""
        property bool loggedFirstPoll: false
        onTriggered: {
            var status = -1;
            var text = "";
            try {
                var xhr = new XMLHttpRequest();
                xhr.open("GET", "file:///userdata/zl1-shell-shot.request", false);
                xhr.send();
                status = xhr.status;
                text = String(xhr.responseText);
            } catch (e) {
                status = -2;         // no request file yet, or XHR refused the URL
            }
            if (!loggedFirstPoll) {
                loggedFirstPoll = true;
                console.log("zl1-shot: poller alive, status=" + status + " text=" + text);
            }
            if (text.length === 0 || text === lastSeen) {
                return;
            }
            lastSeen = text;
            console.log("zl1-shot: capture for " + text);
            itemGrabber.capture(shell);
        }
    }

'''

# Each hunk is (name, anchor, replacement, keep_anchor). `keep_anchor` decides whether the anchor
# text is re-emitted after the replacement:
#
#   * hunk 1 replaces the one line, so the anchor goes away (keep_anchor=False);
#   * hunk 2 *inserts* a block before an existing object, so the anchor has to come back
#     (keep_anchor=True). Forgetting this is a real bug that happened: the replacement swallowed
#     `Timer {` and `id: cursorHidingTimer`, leaving that timer's body dangling -- and the QML
#     engine **still loaded the file**, because a stray `interval: 3000` at that level is "cannot
#     assign to non-existent property", not a parse failure. The result was a shell that ran, with
#     the cursor-hiding timer silently gone and the new timer never firing. Two lessons: an insertion
#     must re-emit its anchor, and **"the shell loaded" is not the same as "the patch is in"**.
HUNKS = [
    ("the physical Back key", BACK_KEY_ANCHOR, BACK_KEY_REPLACEMENT, False),
    ("an on-demand screenshot", SCREENSHOT_ANCHOR, SCREENSHOT_REPLACEMENT, True),
]


def main(argv):
    if len(argv) != 3:
        sys.stderr.write("usage: shell-overlay-patch.py <stock Shell.qml> <output path>\n")
        return 2
    stock_path, out_path = argv[1], argv[2]
    stock = io.open(stock_path, encoding="utf-8").read()

    patched = stock
    for name, anchor, replacement, keep_anchor in HUNKS:
        n = patched.count(anchor)
        if n != 1:
            sys.stderr.write("hunk '%s': anchor found %d times, need exactly 1 -- refusing to patch\n"
                             % (name, n))
            return 1
        patched = patched.replace(anchor, replacement + (anchor if keep_anchor else ""), 1)

    # Read the result back for the specific corruption this whole exercise is about. `qmllint` is
    # NOT a sufficient gate: when an earlier version of this patcher wrote the file with its double
    # quotes eaten, qmllint produced the *same single diagnostic line* as the stock file, so the
    # installer reported "IDENTICAL diagnostics -> no new error introduced" and mounted a file that
    # the QML engine then refused to load at all (`Expected token ','` -> "Lomiri encountered an
    # unrecoverable error while loading"). qmllint here does not parse deeply enough to catch it, so
    # the check has to name the strings that must survive the round trip.
    required = [
        'console.log("zl1-back: key=" + event.key',
        'console.log("zl1-key: key=" + event.key',
        'console.log("zl1-shot: capture for " + text)',
        'xhr.open("GET", "file:///userdata/zl1-shell-shot.request", false);',
        'launcher.toggleDrawer(false, false, true);',
        'itemGrabber.capture(shell);',
        "Keys.onReleased: physicalKeysMapper.onKeyReleased(event, lastInputTimestamp);",
        # The insertion hunk must have left its anchor object intact -- see keep_anchor above.
        "    Timer {\n        id: cursorHidingTimer\n",
    ]
    missing = [r for r in required if r not in patched]
    if missing:
        for r in missing:
            sys.stderr.write("SELF-CHECK FAILED: %r is not in the patched file\n" % r)
        return 1

    # Only now, with every hunk applied and the result read back, is anything written. A failure
    # above must not leave a half-patched file behind for the installer to mount over the shell.
    io.open(out_path, "w", encoding="utf-8").write(patched)
    sys.stdout.write("patched %s -> %s (%d -> %d lines)\n"
                     % (stock_path, out_path, stock.count("\n"), patched.count("\n")))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
