#!/usr/bin/env bash
# Run `lomiri-location-service`, `biometryd` and `sensorfwd` inside the Android container's PID
# namespace, which is the last thing standing between them and the HALs they were built to talk to.
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
# why it appears in the container's `ps -A` and never in the host's. These services are plain
# system units, so nothing did that for them.
#
# `sensorfwd` is the same wall a third time (doc 60), and it was measured the same way — the same
# binary, the same 25 seconds, only the namespace changed:
#
#     host namespace       sensorfw: Requesting adaptor: "magnetometeradaptor"
#                          sensorfw: Could not find remote object for sensor service. Trying...
#     container namespace  sensorfw: Connected to sensor 1.0 service
#                          sensorfw: void HybrisManager::initManager() SELECT type: 1
#                                    ACCELEROMETER name: LSM6DS3 Accelerometer
#                          sensorfw: HYBRIS CTL setActive(1=ACCELEROMETER, false) -> success
#
# What this installs:
#
#   /userdata/zl1-hybris/bin/zl1-ns-exec                     the wrapper (one copy, shared)
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
#     thread group across the two. All three of these services are threaded; that would kill
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
#     running the service outside the namespace. The units are ordered after
#     `lxc-android-config.service` where they can be, so this should not happen; when it does, a
#     unit that says it failed is honest and `Restart=` will pick it up, whereas a service
#     running in the wrong namespace would report `active` and quietly do nothing.
#
#   * The wrapper itself needs two capabilities the services do not. `CAP_SYS_ADMIN` is required
#     by `setns()` for any namespace (kernel/nsproxy.c: `if (!(flags & CLONE_NEWUSER) &&
#     !ns_capable(current_user_ns(), CAP_SYS_ADMIN)) return -EPERM;`), and `CAP_SYS_PTRACE` is
#     required to `stat()` `/proc/<container-init>/ns/pid` — the wrapper's own "is the container
#     up" test, and the reason it reported `no android container after 60s` when only
#     `CAP_SYS_ADMIN` was added. Bisected on the device: neither cap alone is enough, both
#     together are. But `sensorfwd.service` ships `CapabilityBoundingSet=CAP_BLOCK_SUSPEND
#     CAP_DAC_OVERRIDE CAP_FOWNER`, so widening it would leave the *service* holding caps it was
#     never given. Instead the wrapper re-narrows after `setns` with
#     `setpriv --bounding-set=-sys_admin,-sys_ptrace,-setpcap`, so `sensorfwd` ends up with
#     exactly the three caps its unit file lists (verified: `CapBnd: 000000100000000a`, which is
#     2^36 + 2^3 + 2^1 — BLOCK_SUSPEND, FOWNER, DAC_OVERRIDE and nothing else). Dropping from the
#     bounding set needs `CAP_SETPCAP`, which is why that is in the widened set too and is
#     dropped first. This is opt-in per unit via `ZL1_NS_DROP_CAPS=1`, so it cannot change the
#     behaviour of the two services that already work.
#
# One service at a time is still the rule — see `--install` for how to do just one.
#
# Usage: install-container-ns-services.sh --install [unit...] | --remove | --status
#        (no unit named with --install = all three)
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
    sensorfwd)               printf '%s' '/usr/sbin/sensorfwd --systemd --device-info --log-level=warning';;
    bluebinder)              printf '%s' '/usr/sbin/bluebinder';;
    *) return 1;;
  esac
}
ALL_UNITS="lomiri-location-service biometryd sensorfwd bluebinder"

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
#
# sensorfwd is a different shape of the same thing, and it is worse than either: `Type=notify`
# with the default 90 s start timeout. Without a PID namespace it never sends READY=1 at all, so
# systemd kills it every 90 s and restarts it — `Failed with result 'timeout'`, `NRestarts=9` —
# and because the unit is `WantedBy=graphical.target` that stall sits directly in front of the
# GUI. It also carries two properties the others do not (see the header for the first):
#
#   * `NotifyAccess=all`. `Type=notify` defaults to accepting READY=1 only from the unit's main
#     PID, and `nsenter -p` **forks**: the process systemd calls MainPID is nsenter's own, while
#     the one that moved into the container, execs sensorfwd and sends the notification is its
#     child (and with the setpriv step in between, further still). systemd said so exactly —
#     `Got notification message from PID 1049011, but reception only permitted for main PID
#     1048906` — and then timed out at 90 s anyway, so the unit stayed in `activating` and the
#     `ExecStart` swap alone was not enough. `all` accepts a notification from any process in
#     the unit's cgroup, which is what a wrapper needs.
#   * the widened capability bounding set `zl1-ns-exec` needs, paired with `ZL1_NS_DROP_CAPS=1`
#     so the wrapper hands the service back exactly the three caps its own unit file lists.
#
# `RestartSec=5` is only insurance for a boot where the container is late; with the namespace and
# `NotifyAccess` in place it reaches READY on the first try.
unit_extra() {
  case "$1" in
    lomiri-location-service)
      printf '%s' '[Unit]\nStartLimitIntervalSec=0\n\n[Service]\nRestartSec=5\nRestart=always';;
    biometryd)
      printf '%s' '[Unit]\nStartLimitIntervalSec=0\n\n[Service]\nRestartSec=5';;
    sensorfwd)
      printf '%s' '[Unit]\nStartLimitIntervalSec=0\n\n[Service]\nNotifyAccess=all\nRestartSec=5\nEnvironment=ZL1_NS_DROP_CAPS=1\nCapabilityBoundingSet=CAP_BLOCK_SUSPEND CAP_DAC_OVERRIDE CAP_FOWNER CAP_SYS_ADMIN CAP_SYS_PTRACE CAP_SETPCAP';;
    # bluebinder needs three things beyond the ExecStart swap, and none of them is a capability
    # (its own unit file has all its sandboxing lines commented out, so no widening and no
    # setpriv hand-back is involved):
    #
    #   * `ExecStartPre=` reset plus a replacement, because the shipped readiness script reads
    #     Android properties through a host-side stub and can never succeed. See BTWAIT_SH above.
    #   * `NotifyAccess=all`, for the reason sensorfwd needs it: `nsenter -p` forks, so READY=1
    #     does not come from MainPID. This unit is `Type=notify` too.
    #   * `TimeoutStartSec` raised from the shipped 60 to 240, because the pre-check may legitimately
    #     wait for a HAL that this port does not bring up until t≈46 s (see BTWAIT_SH).
    #
    # The shipped unit also puts `StartLimitBurst` / `StartLimitIntervalSec` in `[Service]`, where
    # systemd ignores both (`Unknown key name 'StartLimitIntervalSec' in section 'Service'`), so
    # the default 5-starts-per-10-s applies and the loop it drives dies permanently. Setting the
    # interval to 0 in the right section is what makes the retry work at all.
    bluebinder)
      printf '%s' '[Unit]\nStartLimitIntervalSec=0\n\n[Service]\nNotifyAccess=all\nRestartSec=5\nTimeoutStartSec=240\nExecStartPre=\nExecStartPre=/userdata/zl1-hybris/bin/zl1-bt-wait';;
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
# between two processes in the same PID namespace. A host process calling IGnss::getService(),
# IBiometricsFingerprint::getService() or ISensors::getService() gets nullptr, and the failure is
# silent: the HIDL side just returns null, the binder side returns an empty reply. `lshal` run
# from the host lists 0 registered services; the same binary inside the container lists 134.
#
# -p only. Never -F: setns on a PID namespace only affects future children, so -F would leave
# this process behind while its children move, and every pthread_create would fail with EINVAL.
# That is fatal for threaded services.

# Wait for the container, but not forever. The callers are ordered after
# lxc-android-config.service where they can be, so this normally succeeds on the first try.
#
# The `-e` test needs CAP_SYS_PTRACE in the *caller*: /proc/<pid>/ns/pid is only readable for a
# process this one may ptrace, and the container init is not in our PID namespace. Without that
# capability the test is false no matter how healthy the container is, and this loop runs the
# full 60 s and then reports "no android container" — which is what it said when sensorfwd was
# given CAP_SYS_ADMIN but not CAP_SYS_PTRACE. Both caps are listed in that unit drop-in.
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
    # ZL1_NS_DROP_CAPS: the wrapper needs CAP_SYS_ADMIN (setns requires it for every namespace
    # type) and CAP_SYS_PTRACE (the test above), but a service whose own unit file lists a
    # narrower CapabilityBoundingSet must not inherit them just because we put a wrapper in
    # front of it. setpriv re-narrows after the namespace switch, so what is execd ends up with
    # exactly the caps its unit file names. Dropping from the bounding set needs CAP_SETPCAP,
    # which is why that is in the widened set as well and is dropped here along with the rest.
    # Opt-in, and set only by units whose bounding set we had to widen -- never on by default,
    # so it cannot change the behaviour of services that already work.
    if [ -n "${ZL1_NS_DROP_CAPS:-}" ] && [ -x /usr/bin/setpriv ]; then
        exec nsenter -t "$A" -p -- /usr/bin/setpriv \
            --bounding-set=-sys_admin,-sys_ptrace,-setpcap \
            --inh-caps=-all --ambient-caps=-all -- "$@"
    fi
    exec nsenter -t "$A" -p -- "$@"
fi

# Fail loudly instead of running without the namespace: a service that starts in the host
# namespace claims its D-Bus name and reports active while being unable to reach any HAL.
echo "zl1-ns-exec: no android container after 60s; refusing to run $1 outside its PID namespace" >&2
exit 1
'

# bluebinder's readiness test, and why the shipped one cannot work here.
#
# `bluebinder.service` ships `ExecStartPre=/usr/bin/droid/bluebinder_wait.sh`, which loops until
# `getprop | grep 'init.svc.*bluetooth' | grep -v audio | grep -o '[running]'` matches. On this
# port that can never match, for one reason wearing two hats: **Android properties are only
# visible inside the container**, exactly like binder.
#
#   * `/usr/bin/getprop` on the host is not the Android binary at all. It is a 1352-byte shell
#     script (from the v63 debug image — see `zl1-getprop-is-a-stub`) that answers a handful of
#     `ro.*` properties from a case statement and prints the caller's default for `init.svc.*`.
#     Its bare-`getprop` case — the one the wait script uses, with no argument — prints **nothing
#     at all**. So the grep sees an empty string, forever.
#   * Even the real binary, `/usr/bin/getprop.orig-zl1`, returns **0 lines** when run from the
#     host. Measured. The property area is the container's.
#
# Inside the container the same question has a real answer:
#     [init.svc.vendor.bluetooth-1-0-qti]: [running]
#
# So the fix is not a better host-side getprop; it is to ask inside. The loop below keeps the
# shipped script's shape (any `init.svc.*bluetooth*` that is not audio, running) and its intent,
# and only changes where it looks.
#
# The 120 s budget is deliberate: the log carries `ro.boottime.vendor.bluetooth-1-0-qti:
# [45723205437]`, i.e. the Android bluetooth HAL is up at t≈45.7 s, and this unit is only ordered
# after `lxc-android-config.service`. That is why the drop-in also raises `TimeoutStartSec`.
BTWAIT_SH='
#!/bin/sh
# Wait until the Android bluetooth HAL is running. Written by
# scripts/hybris-shims/install-container-ns-services.sh — edit it there.

container_init() {
    A=$(lxc-info -n android -pH 2>/dev/null | head -1)
    if [ -n "$A" ] && [ -e "/proc/$A/ns/pid" ]; then echo "$A"; fi
}

A=""
i=0
while [ "$i" -lt 60 ]; do
    A=$(container_init)
    [ -n "$A" ] && break
    A=""
    i=$((i + 1))
    sleep 2
done
if [ -z "$A" ]; then
    echo "zl1-bt-wait: no android container after 120s" >&2
    exit 1
fi

i=0
while [ "$i" -lt 60 ]; do
    st=$(nsenter -t "$A" -p -m -- /system/bin/getprop 2>/dev/null |
         grep "init\.svc.*bluetooth" | grep -v audio | grep -o "\[running\]" | head -1)
    if [ "$st" = "[running]" ]; then
        echo "zl1-bt-wait: bluetooth HAL running in the container"
        exit 0
    fi
    i=$((i + 1))
    sleep 2
done
echo "zl1-bt-wait: bluetooth HAL still not running after 120s" >&2
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
  # Both device-side scripts are pushed on every install, whichever units were named: they are
  # tiny, and a unit's drop-in can then reference either without the installer needing to know
  # which. `zl1-bt-wait` is only referenced by bluebinder's drop-in.
  for pair in "ns-exec:$WRAPPER_SH" "bt-wait:$BTWAIT_SH"; do
    name="${pair%%:*}"; body="${pair#*:}"
    printf '%s\n' "$body" > "$tmp"
    # Same trap as the other installers here: the assignment starts with a newline, so without
    # this the file's first line is not the shebang and systemd reports `Exec format error` /
    # status=203/EXEC without saying why.
    sed -i '/./,$!d' "$tmp"
    case "$(head -1 "$tmp")" in
      '#!'*) ;;
      *) echo "refusing to push $name: first line is not a shebang ($(head -1 "$tmp"))" >&2; exit 1;;
    esac
    "${SSH[@]}" "mkdir -p $BINDIR"
    "${SCP[@]}" "$tmp" "$DEV:$BINDIR/zl1-$name" || exit 1
    "${SSH[@]}" "chmod 755 $BINDIR/zl1-$name"
  done

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
UNITS="lomiri-location-service:lomiri-location biometryd:biometryd sensorfwd:sensorfwd bluebinder:bluebinder"
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
echo
# sensorfwd's evidence is in its own journal, not logcat: it does not go through a bridge library
# of ours, it opens the Android sensors HAL directly with libgbinder, so what it has to say is
# only in what it prints. Per boot (`-b`) on purpose — unlike the logcat counts above, this one
# must not include attempts from before the change.
#
# The patterns are chosen for the level the *unit* runs at (`--log-level=warning`), not the level
# a hand-run probe uses: `Connected to sensor 1.0 service` and the `SELECT type: ... name: ...`
# enumeration are only printed at `debug`, so counting them here answers 0 on a perfectly healthy
# service. `Hybris sensor manager initialized` is what is left at warning level, and it is logged
# only after the HAL has answered and every sensor has been probed.
echo 'sensorfwd evidence (its journal this boot):'
printf '  %-46s %s\n' 'Hybris sensor manager initialized' \
    "$(journalctl -u sensorfwd -b --no-pager 2>/dev/null | grep -c 'Hybris sensor manager initialized')"
printf '  %-46s %s\n' 'Could not find remote object (host ns symptom)' \
    "$(journalctl -u sensorfwd -b --no-pager 2>/dev/null | grep -c 'Could not find remote object')"
printf '  %-46s %s\n' 'HYBRIS CTL calls that returned an error' \
    "$(journalctl -u sensorfwd -b --no-pager 2>/dev/null | grep -c 'HYBRIS CTL.*-> -')"
printf '  %-46s %s\n' 'sensors named in those errors' \
    "$(journalctl -u sensorfwd -b --no-pager 2>/dev/null | grep -o 'HYBRIS CTL [a-zA-Z]*([0-9]*=[A-Z_]*' | sed 's/.*(//; s/[0-9]*=//' | sort -u | tr '\n' ' ')"
printf '  %-46s %s\n' 'owns com.nokia.SensorService' \
    "$(busctl --system list 2>/dev/null | grep -c 'com.nokia.SensorService')"
printf '  %-46s %s\n' 'NRestarts / Result' \
    "$(systemctl show -p NRestarts --value sensorfwd 2>/dev/null) / $(systemctl show -p Result --value sensorfwd 2>/dev/null)"
printf '  %-46s %s\n' "Failed with result 'timeout' (this boot)" \
    "$(journalctl -u sensorfwd -b --no-pager 2>/dev/null | grep -c "Failed with result 'timeout'")"
echo '  (that last count is whole-boot, so a boot in which this was installed while running still'
echo '   contains the failures from before it — the unambiguous facts are NRestarts and Result)'
echo '  (the per-sensor enumeration — "SELECT type: 1 ACCELEROMETER name: LSM6DS3 Accelerometer"'
echo '   and friends — is only printed at --log-level=debug; run it by hand, or temporarily'
echo '   change the drop-in, if you need to see the HAL inventory itself)'
REMOTE
  ;;
*)
  # The header, whatever its current length: lines 2..the end of the leading comment block.
  # A fixed `sed -n '2,57p'` silently truncates the usage text every time the header grows,
  # which is how it was found.
  awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; exit 1;;
esac
