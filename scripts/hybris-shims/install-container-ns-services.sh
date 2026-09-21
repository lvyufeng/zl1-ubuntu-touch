#!/usr/bin/env bash
# Run `lomiri-location-service` and `biometryd` inside the Android container's PID namespace,
# which is the last thing standing between them and the HALs they were built to talk to.
#
# Where this comes from: doc 55 built and installed the two missing bridge libraries, and both
# services went from `failed (Result: signal)` to `active` — the `pc=0x0` class is closed. They
# still cannot do anything, though, because `IGnss::getService()` returns NULL and `biometryd`
# reports `Unable to get IBiometricsFingerprint::2.1 service`, while `lshal` inside the container
# shows both registered. The reason is the one doc 43 found for binder, measured for hwbinder:
#
#     $ /android/system/bin/lshal                              | grep -c '^Y'   ->   0
#     $ nsenter -t $(lxc-info -n android -pH) -p -m -- \
#           /system/bin/lshal                                    | grep -c '^Y'   -> 134
#
# Same binary, only the PID namespace differs. The compositor has been living with this since
# doc 43 — `lsc-wrapper` execs it through `nsenter -p`, which is why it can reach hwcomposer and
# why it appears in the container's `ps -A` and never in the host's. These two services are
# plain system units, so nothing did that for them.
#
# What this installs:
#
#   /userdata/zl1-hybris/bin/zl1-ns-exec                     the wrapper (one copy, used by both)
#   /etc/systemd/system/<unit>.service.d/zz-zl1-ns.conf      ExecStart override
#
# The `zz-` prefix is load-bearing. `lomiri-location-service` already has an `ExecStart=` reset
# in `/usr/lib/systemd/system/lomiri-location-service.service.d/lxc-android-config.conf`, and
# systemd applies drop-ins in one lexicographic order across *all* drop-in directories, so a
# name that sorts after `lxc-android-config.conf` is what makes the last `ExecStart=` win. A
# name like `zl1-ns.conf` happens to sort after it too, but by accident.
#
# Deliberate choices, and the reasons:
#
#   * `-p` only, never `-F`. `setns` on a PID namespace affects only future children, so with
#     `-F` the exec'd process stays in the host namespace while its children go to the
#     container's, and `pthread_create` then fails with EINVAL because a thread cannot share a
#     thread group across the two. Both of these services are GLib-threaded; that would kill
#     them the same way doc 43 saw the compositor die.
#
#   * No `nsenter` sweep before starting, unlike `lsc-wrapper`. There, a leftover childless
#     `nsenter` keeps the namespace open across compositor restarts. Here systemd's default
#     `KillMode=control-group` kills the whole cgroup — and cgroups are orthogonal to PID
#     namespaces, so the child that actually landed in the container is in this unit's cgroup
#     and does get killed. Sweeping would also mean pattern-matching `nsenter` processes, which
#     would put the compositor's live one in reach; not worth it for a cosmetic leak.
#
#   * If the container is not up, the wrapper waits up to a minute and then *fails*, rather than
#     running the service outside the namespace. Both units are `Type=dbus` and are ordered
#     after `lxc-android-config.service`, so this should not happen; when it does, a unit that
#     says it failed is honest and `Restart=` will pick it up, whereas a service running in the
#     wrong namespace would report `active` and quietly do nothing.
#
# One service at a time is still the rule — see `--install` for how to do just one.
#
# Usage: install-container-ns-services.sh --install [unit...] | --remove | --status
#        (no unit named with --install = both)
#
# Env: ZL1_HOST (default root@10.15.19.82)

set -uo pipefail
DEV="${ZL1_HOST:-root@10.15.19.82}"
STAGE=/userdata/zl1-hybris
BINDIR=$STAGE/bin
here="$(cd "$(dirname "$0")" && pwd)"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$DEV")
SCP=(scp -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

# unit -> the command it runs today. Read off the device rather than guessed: for
# lomiri-location-service the real ExecStart is the lxc-android-config wrapper, not
# /usr/bin/lomiri-location-serviced, and wrapping the wrong one would silently drop the
# provider arguments that wrapper adds.
unit_cmd() {
  case "$1" in
    lomiri-location-service) printf '%s' '/usr/libexec/lxc-android-config/lomiri-location-serviced-wrapper';;
    biometryd)               printf '%s' '/usr/bin/biometryd run';;
    *) return 1;;
  esac
}
ALL_UNITS="lomiri-location-service biometryd"

# Extra unit-file text a unit needs on top of the ExecStart swap. Section headers included;
# `\n` is expanded on the device with `printf %b`, because the field has to survive a
# line-oriented `read`. Empty (`-` in the wire format) means "nothing extra".
#
# Both of these services have the same problem in different clothes: something they need is
# not there yet when they first start, they exit, and systemd's *default start rate limit*
# (5 starts per 10 s) turns "late" into "never" — the unit lands in `failed` with
# `start-limit-hit` and stays there for the rest of the boot.
#
# lomiri-location-service exits ~1.5-8 s after claiming its bus name, before the user session
# exists. It builds a trust-store agent at startup (`liblomiri-location-service.so` links
# `libtrust-store.so.2`; `TrustStorePermissionManager::create_default_instance_with_bus`,
# `core::trust::dbus::create_multi_user_agent_for_bus_connection` and a literal
# `DBUS_SESSION_BUS_ADDRESS` are all in its strings), and the `trust-stored-skeleton` for
# `--for-service LomiriLocationService` is started by the *user* session, which on this port
# begins ~25 s after this unit does. It exits *cleanly*, which is exactly what the rootfs's
# `Restart=on-failure` does not retry, so it was dead for the whole boot and `--failed` did not
# even show it. `Restart=always` plus no rate limit makes it retry until the session is up.
#
# biometryd already ships `Restart=always`, and it does recover — but only just: one boot it
# restarted itself 4 times against a limit of 5. Its first attempt calls the Android fingerprint
# HAL's `setActiveGroup`, which answers `SYS_EINVAL` until the HAL is ready, and it exits
# cleanly on that. `RestartSec=5` bounds the retry instead of leaving the 100 ms default in
# place, which on the boot where the HAL never became ready turned into a ~4 s hot loop and
# pushed the load average to 14 (measured).
unit_extra() {
  case "$1" in
    lomiri-location-service)
      printf '%s' '[Unit]\nStartLimitIntervalSec=0\n\n[Service]\nRestartSec=5\nRestart=always';;
    biometryd)
      printf '%s' '[Unit]\nStartLimitIntervalSec=0\n\n[Service]\nRestartSec=5';;
    *) return 1;;
  esac
}

guard() {
  "${SSH[@]}" 'grep -qa msm8996 /proc/device-tree/compatible' 2>/dev/null ||
    { echo "not the zl1 (no msm8996 in /proc/device-tree/compatible) — refusing" >&2; exit 1; }
}

WRAPPER_SH='
#!/bin/sh
# Run the command given as arguments inside the Android container PID namespace.
#
# Why: Android binder -- both /dev/binder and /dev/hwbinder -- only completes a transaction
# between two processes in the same PID namespace. A host process calling IGnss::getService()
# or IBiometricsFingerprint::getService() gets nullptr, and the failure is silent: the HIDL
# side just returns null, the binder side returns an empty reply. `lshal` run from the host
# lists 0 registered services; the same binary inside the container lists 134.
#
# -p only. Never -F: setns on a PID namespace only affects future children, so -F would leave
# this process behind while its children move, and every pthread_create would fail with EINVAL.
# That is fatal for GLib-threaded services.

# Wait for the container, but not forever. Both callers are ordered after
# lxc-android-config.service, so this normally succeeds on the first try.
A=""
i=0
while [ "$i" -lt 30 ]; do
    A=$(lxc-info -n android -pH 2>/dev/null | head -1)
    if [ -n "$A" ] && [ -e "/proc/$A/ns/pid" ]; then
        break
    fi
    A=""
    i=$((i + 1))
    sleep 2
done

if [ -n "$A" ]; then
    exec nsenter -t "$A" -p -- "$@"
fi

# Fail loudly instead of running without the namespace: a service that starts in the host
# namespace claims its D-Bus name and reports active while being unable to reach any HAL.
echo "zl1-ns-exec: no android container after 60s; refusing to run $1 outside its PID namespace" >&2
exit 1
'

case "${1:-}" in
--install)
  guard
  shift || true
  units="${*:-$ALL_UNITS}"
  for u in $units; do
    unit_cmd "$u" >/dev/null || { echo "unknown unit: $u" >&2; exit 1; }
  done

  tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
  printf '%s\n' "$WRAPPER_SH" > "$tmp"
  # Same trap as the other installers here: the assignment starts with a newline, so without
  # this the file's first line is not the shebang and systemd reports `Exec format error` /
  # status=203/EXEC without saying why.
  sed -i '/./,$!d' "$tmp"
  case "$(head -1 "$tmp")" in
    '#!'*) ;;
    *) echo "refusing to push: first line is not a shebang ($(head -1 "$tmp"))" >&2; exit 1;;
  esac

  "${SSH[@]}" "mkdir -p $BINDIR"
  "${SCP[@]}" "$tmp" "$DEV:$BINDIR/zl1-ns-exec" || exit 1
  "${SSH[@]}" "chmod 755 $BINDIR/zl1-ns-exec"

  # The units, their commands, and the extra service properties each one needs go in through
  # the environment so the heredoc stays quoted. `|` separates the fields rather than
  # whitespace, because a command contains spaces (`/usr/bin/biometryd run`) and a
  # whitespace-split `read` would silently truncate it. `-` means "no extra properties" —
  # a placeholder rather than an empty field, so the field count never depends on the value.
  cmds=""
  for u in $units; do
    extra="$(unit_extra "$u")"; [ -n "$extra" ] || extra="-"
    cmds="$cmds$u|$(unit_cmd "$u")|$extra
"
  done
  "${SSH[@]}" "BINDIR='$BINDIR' CMDS='$cmds' bash -s" <<'REMOTE'
set -u
printf '%s\n' "$CMDS" | while IFS='|' read -r u c extra; do
  [ -n "$u" ] || continue
  mkdir -p "/etc/systemd/system/$u.service.d"
  {
    echo '[Service]'
    echo '# zz- so this sorts after lxc-android-config.conf: systemd applies drop-ins in one'
    echo '# lexicographic order across all drop-in directories, and the last ExecStart= wins.'
    echo 'ExecStart='
    echo "ExecStart=$BINDIR/zl1-ns-exec $c"
  } > "/etc/systemd/system/$u.service.d/zz-zl1-ns.conf"
  if [ "$extra" != "-" ]; then
    printf '\n# why the retry settings below are not the rootfs defaults:\n' \
      >> "/etc/systemd/system/$u.service.d/zz-zl1-ns.conf"
    printf '%b\n' "$extra" >> "/etc/systemd/system/$u.service.d/zz-zl1-ns.conf"
  fi
  echo "wrote /etc/systemd/system/$u.service.d/zz-zl1-ns.conf:"
  sed 's/^/  | /' "/etc/systemd/system/$u.service.d/zz-zl1-ns.conf"
done
systemctl daemon-reload
for u in $(printf '%s\n' "$CMDS" | awk -F'|' '{print $1}'); do
  systemctl reset-failed "$u" >/dev/null 2>&1
  systemctl restart "$u"
done
sleep 20
for u in $(printf '%s\n' "$CMDS" | awk -F'|' '{print $1}'); do
  printf '  %-32s %s\n' "$u" "$(systemctl is-active "$u" 2>&1)"
done
REMOTE
  echo
  echo "Verify with: $0 --status"
  ;;
--remove)
  guard
  "${SSH[@]}" "
    for u in $ALL_UNITS; do
      rm -f /etc/systemd/system/\$u.service.d/zz-zl1-ns.conf
      rmdir /etc/systemd/system/\$u.service.d 2>/dev/null
    done
    systemctl daemon-reload
    for u in $ALL_UNITS; do
      systemctl reset-failed \$u >/dev/null 2>&1
      systemctl restart \$u
    done
    echo 'removed the ExecStart overrides; the two services are back in the host PID namespace.'"
  ;;
--status)
  guard
  "${SSH[@]}" "BINDIR='$BINDIR' bash -s" <<'REMOTE'
set -u
UNITS="lomiri-location-service:lomiri-location biometryd:biometryd"
printf 'wrapper: '; ls -l "$BINDIR/zl1-ns-exec" 2>/dev/null || echo 'ABSENT'
A=$(lxc-info -n android -pH 2>/dev/null | head -1)
echo "android init pid: ${A:-<none>}"
if [ -n "$A" ]; then
    echo "container pid ns: $(readlink /proc/$A/ns/pid 2>/dev/null)"
fi
echo
for entry in $UNITS; do
    u=${entry%%:*}; procname=${entry##*:}
    printf '%-32s %s\n' "$u" "$(systemctl is-active "$u" 2>&1)"
    # Which namespace the *real* process is in. ExecStart is nsenter, which stays in the host
    # namespace, and the process that moved is its child -- so following MainPID is not enough,
    # and for a Type=dbus unit it is often not even the right process. Look the service up by
    # the name the kernel gives it instead.
    real=$(pgrep -x "$procname" 2>/dev/null | head -1)
    if [ -n "$real" ]; then
        ns=$(readlink "/proc/$real/ns/pid" 2>/dev/null)
        where="host"
        [ -n "$A" ] && [ "$ns" = "$(readlink /proc/$A/ns/pid 2>/dev/null)" ] && where="container"
        printf '  pid %-8s %s  in the %s PID namespace\n' "$real" "$ns" "$where"
    else
        printf '  (no process to look at)\n'
    fi
done
echo
echo 'what the library says now (the real answer, from the container logcat):'
echo '  (counts are over the whole ring buffer, so failures from before the change are still'
echo '   in there — the question is whether the success lines have appeared at all)'
journalctl -u lomiri-location-service -b --no-pager -n 3 2>/dev/null | sed 's/^/  /'
if [ -n "$A" ]; then
    # One logcat dump, not one per pattern: each `logcat -d` is a full pass over a large buffer
    # over a slow link, and four of them turned a status check into a two-minute wait.
    dump=$(nsenter -t "$A" -p -m -- /system/bin/logcat -d -v brief 2>/dev/null)
    # These four strings are the actual branches in the C++, not guesses: "Unable to get GPS
    # service" is logged right after both getService() calls return null, and
    # "set_gps_service_callbacks" is only reached once one of them did not. For fingerprint the
    # pair is explicit. `gnssSetCapabilitesCb` is the stronger one still — that callback is the
    # Android HAL calling *into* our process, which is the whole link working.
    for pat in 'Unable to get GPS service' 'set_gps_service_callbacks' 'gnssSetCapabilitesCb' \
               'Unable to get IBiometricsFingerprint' 'Connected to IBiometricsFingerprint'; do
        printf '  %-42s %s\n' "$pat" "$(printf '%s\n' "$dump" | grep -c "$pat")"
    done
else
    echo '  (no container, so no logcat to read)'
fi
REMOTE
  ;;
*)
  sed -n '2,57p' "$0"; exit 1;;
esac
