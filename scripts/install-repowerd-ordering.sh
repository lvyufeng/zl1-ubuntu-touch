#!/usr/bin/env bash
# Stop repowerd from dying at boot, by making it wait for sensorfwd.
#
# Why this exists: on the boot of 2026-09-22 `repowerd` was **dead**, and it had been dead for the
# whole boot. `systemctl status repowerd` said `failed (Result: signal)`, `Main PID ... signal=SEGV`,
# and the shell's own journal was full of `com.lomiri.Repowerd DBus interface not available, waiting
# for it` / `presuming no wakelocks held`. Nothing else on this port owns idle/screen policy, so a
# dead repowerd means the screen can go dark and nothing can bring it back — which is what the
# device looked like.
#
# It is a **race, not a missing feature**, and docs 48/52/63/64 all record repowerd as `active`:
# the same units on the same image used to come up fine. What changed is only who won.
#
# The race, from `journalctl -b -o short-monotonic` (monotonic timestamps: the device clock is
# wrong, so wall-clock ordering lies — see doc 64):
#
#     [   42.365731] systemd: Starting repowerd.service
#     [   42.420230] systemd: Starting sensorfwd.service
#     [   42.450425] repowerd: main: Starting repowerd 2025.09
#     [   52.724265] repowerd: Sensorfw: failed to call load_plugin: Timeout was reached
#     [   52.725601] repowerd: g_variant_unref: assertion 'value != NULL' failed
#     [   52.727406] repowerd: DefaultDaemonConfig: Failed to create SensorfwLightSensor: Could not create sensorfw backend
#     [   52.727751] repowerd: DefaultDaemonConfig: Falling back to NullLightSensor
#     [   55.701017] systemd: Started sensorfwd.service            <- sensorfwd's READY, 13.25 s in
#     [   55.717542] systemd: repowerd.service: Main process exited, code=killed, status=11/SEGV
#
# repowerd's sensorfw backend calls `load_plugin()` while it is starting, with a **10 second**
# timeout measured from its own start (42.450 -> 52.724). sensorfwd is `Type=notify` and does not
# reach `READY=1` until 55.701 — 13.25 s in, so the two are separated by more than the timeout. The
# call times out, repowerd falls back to `NullLightSensor`, and 3 s later it SEGVs. The fallback is
# not itself the crash: the same Null* fallbacks happen on the runs that survive
# (`NullHBM`, `NullPerformanceBooster`, `NullLightSensor` are all benign), so what kills it is the
# sensorfw client left in a broken state by the timeout.
#
# Two things about the shipped unit turn a lost race into a dead daemon:
#
#   - `repowerd.service` has **no ordering against `sensorfwd.service`** at all — its `After=` is
#     only `lxc-android-config.service dbus.socket` — so whether it wins depends on job scheduling.
#   - it is `Restart=no`, so the loss is permanent for the rest of the boot.
#
# The fix is one drop-in on the `/etc/systemd/system` writable path (`/etc` itself is a read-only
# ext4 image; doc 64 §6):
#
#   [Unit]     After=sensorfwd.service  Wants=sensorfwd.service
#   [Service]  Restart=on-failure  RestartSec=5
#
# `After=` is the fix: sensorfwd is `Type=notify`, so ordering after it means ordering after its
# `READY=1`, which is exactly the state `load_plugin()` needs. It is also bounded — sensorfwd sets
# no `TimeoutStartSec`, so systemd's `DefaultTimeoutStartSec` (90 s) caps the wait — and it adds no
# new file beyond the drop-in, no polling loop, and no change to sensorfwd itself.
#
# `Restart=on-failure` is the net, and it is what makes the ordering sufficient rather than merely
# correct: sensorfwd reaches its *first* READY at ~13 s but then restarts three more times, ~8 s
# apart, until the container's sensor HAL settles (`Scheduled restart job, restart counter is at
# 1/2/3` at [63.6] [71.4] [83.4], then `NRestarts=3` and stable from [84.0] on). A repowerd that
# starts on the first READY can therefore still lose its sensorfw connection to a later restart;
# with `Restart=on-failure` each loss is a retry 5 s later instead of a daemon that stays dead until
# the next boot.
#
# Note what is deliberately **not** done: no `SensorfwConfig` or device yaml is added (doc 64 §5 —
# that would move sensorfwd off the HIDL adaptors that work), and repowerd's config surface is not
# touched. `/etc/default/repowerd` is entirely comments and `/usr/sbin/repowerd` has no long options
# at all (a grep for `--[a-z-]` finds none), so there is no switch to turn the sensorfw light sensor
# off: `REPOWERD_DEVICE_CONFIG_DIR` and `SENSORFW_SOCKET_PATH` are the only knobs there are, and
# `config_automatic_brightness_available=false` in `config-default.xml` does not stop repowerd from
# constructing the sensorfw backend. Ordering is the available fix.
#
# Usage: install-repowerd-ordering.sh --install | --remove | --status
#
# Env: ZL1_HOST (default root@10.15.19.82)

set -uo pipefail
DEV="${ZL1_HOST:-root@10.15.19.82}"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$DEV")
UNIT=repowerd.service
DROPIN=/etc/systemd/system/repowerd.service.d/zz-zl1-after-sensorfwd.conf

guard() {
  "${SSH[@]}" 'grep -qa msm8996 /proc/device-tree/compatible' 2>/dev/null ||
    { echo "not the zl1 (no msm8996 in /proc/device-tree/compatible) — refusing" >&2; exit 1; }
}

REMOTE_STATUS='
DROPIN=/etc/systemd/system/repowerd.service.d/zz-zl1-after-sensorfwd.conf
if [ -f "$DROPIN" ]; then
  echo "  present: $DROPIN"
  sed "s/^/    /" "$DROPIN"
else
  echo "  absent: $DROPIN"
fi
# The reading that matters is `systemctl cat`, not the file existing: systemd only reads
# <full-unit-name>.d, and doc 63 is the story of 17 drop-ins that existed and were never loaded.
if systemctl cat repowerd.service 2>/dev/null | grep -q "zz-zl1-after-sensorfwd.conf"; then
  echo "  systemctl cat repowerd.service lists it: in effect"
else
  echo "  systemctl cat repowerd.service does NOT list it — the drop-in is inert"
fi
printf "  Effective After=:   %s\n" "$(systemctl show repowerd.service -p After --value)"
printf "  Effective Restart=: %s (RestartSec=%s)\n" \
  "$(systemctl show repowerd.service -p Restart --value)" \
  "$(systemctl show repowerd.service -p RestartSec --value)"
'

case "${1:-}" in
--install)
  guard
  "${SSH[@]}" "DROPIN='$DROPIN' bash -s" <<'REMOTE'
set -u
# /etc is a read-only image; /etc/systemd/system is on the writable path. The directory already
# exists (zl1-tls.conf lives in it) but do not assume it.
mkdir -p "$(dirname "$DROPIN")" || { echo "  cannot create $(dirname "$DROPIN")" >&2; exit 1; }
cat > "$DROPIN" <<'CONF'
# Written by scripts/install-repowerd-ordering.sh in the zl1 port repo. The measurements
# behind it are in that script's header and in docs/ubuntu-touch/69-*.md.
#
# Why: repowerd's sensorfw backend calls load_plugin() during startup with a 10 s timeout,
# and the shipped unit carries no ordering against sensorfwd -- which is Type=notify and
# does not reach READY=1 until ~13 s in. repowerd timed out, fell back to NullLightSensor,
# and died with SIGSEGV; because the unit is Restart=no it then stayed dead for the whole
# boot, and nothing else on this port owns screen policy.
#
# After= is the fix: ordering after a Type=notify unit means ordering after its READY=1,
# which is the state load_plugin() needs. systemd bounds the wait (DefaultTimeoutStartSec).
[Unit]
After=sensorfwd.service
Wants=sensorfwd.service

# The net, not the fix: sensorfwd restarts ~3 more times after its first READY, until the
# container's sensor HAL settles, so a repowerd that starts on the first READY can still
# lose its connection. This makes that a retry instead of a daemon dead until the next boot.
[Service]
Restart=on-failure
RestartSec=5
CONF
echo "  wrote $DROPIN"
systemctl daemon-reload
# Apply it now as well as at the next boot. reset-failed first: a unit that has exhausted
# Restart= is not started by `start` alone (doc 48 learned this the hard way).
systemctl reset-failed repowerd.service >/dev/null 2>&1
if systemctl is-active --quiet repowerd.service; then
  echo "  repowerd is already active; leaving the running instance alone"
else
  systemctl start repowerd.service >/dev/null 2>&1
  sleep 2
  printf '  after start: %s\n' "$(systemctl is-active repowerd.service)"
fi
REMOTE
  echo
  echo "--- what systemd now says ---"
  "${SSH[@]}" "$REMOTE_STATUS"
  echo
  echo "Note: the ordering only helps if it is honoured at boot. Verify with a cold boot, not here."
  ;;
--remove)
  guard
  "${SSH[@]}" "DROPIN='$DROPIN' bash -s" <<'REMOTE'
set -u
# Restore the shipped shape: no ordering, Restart=no. Leave the running daemon alone — stopping it
# to "fully revert" would take screen policy away for no reason, and the next boot is the test.
if [ -f "$DROPIN" ]; then
  rm -f "$DROPIN"
  echo "  removed $DROPIN"
else
  echo "  $DROPIN was not there"
fi
systemctl daemon-reload
printf '  Effective After=:   %s\n' "$(systemctl show repowerd.service -p After --value)"
printf '  Effective Restart=: %s\n' "$(systemctl show repowerd.service -p Restart --value)"
REMOTE
  ;;
--status)
  guard
  echo "--- the drop-in ---"
  "${SSH[@]}" "$REMOTE_STATUS"
  echo
  echo "--- the two units, right now ---"
  "${SSH[@]}" '
    systemctl show repowerd.service -p ActiveState -p SubState -p Result -p ExecMainStatus -p NRestarts --value 2>/dev/null | tr "\n" " " | sed "s/^/  repowerd:  /"; echo
    systemctl show sensorfwd.service -p ActiveState -p SubState -p Result -p NRestarts --value 2>/dev/null | tr "\n" " " | sed "s/^/  sensorfwd: /"; echo
    printf "  repowerd pid/uptime: %s\n" "$(ps -o pid=,etime= -C repowerd 2>/dev/null | tr -s " ")"
    printf "  com.lomiri.Repowerd names on the system bus: %s\n" "$(busctl --system list 2>/dev/null | grep -c com.lomiri.Repowerd)"'
  echo
  echo "--- this boot's journal, monotonic (the device clock is wrong, so wall-clock order lies) ---"
  "${SSH[@]}" '
    echo "  repowerd:"
    journalctl -b -o short-monotonic -u repowerd.service --no-pager 2>/dev/null |
      grep -E "Starting repowerd|Started repowerd|failed to call load_plugin|Falling back to NullLightSensor|status=11/SEGV" |
      sed "s/^/    /" | tail -12
    echo "  sensorfwd:"
    journalctl -b -o short-monotonic -u sensorfwd.service --no-pager 2>/dev/null |
      grep -E "Started sensorfwd|Scheduled restart" | sed "s/^/    /" | tail -8'
  ;;
*)
  awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; exit 1;;
esac
