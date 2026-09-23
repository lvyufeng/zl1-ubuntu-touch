#!/usr/bin/env bash
# Put the CPU cores on a scaling governor instead of the `performance` the image ships.
#
# Why this exists: on 2026-09-22 the user said **"这台机器很容易发烫"** (this thing gets hot easily),
# and the first thing measured was the governor:
#
#     $ for p in 0 1 2 3; do cat /sys/devices/system/cpu/cpu$p/cpufreq/scaling_governor; done
#     performance performance performance performance
#     $ cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq   # == scaling_max_freq
#     1132800                            # cpu0/cpu1 max 1132800, cpu2/cpu3 max 1363200
#
# All four cores sit at their maximum clock **all the time** and never scale down. On a battery-powered
# msm8996 that is the single biggest avoidable heat source there is: when nothing is runnable the cores
# still burn full power. `scaling_available_governors` on this kernel is
# `interactive conservative ondemand userspace powersave performance` -- there is no `schedutil`, and
# `interactive` is the Qualcomm-tuned governor these kernels normally ship as the default, so that is
# what this installs. Measured effect of switching it at runtime: idle cores drop from 1132800/1363200
# MHz to **307200/460800 MHz**, and they still ramp under load (the load average stayed at ~6 during
# the change, so the cores were genuinely still working).
#
# The rest of the thermal picture, measured at the same time, so the next person knows what was and was
# not this:
#
#   * `zl1-debug-net.sh` -- the v63 debug network keeper, running as an orphaned `/bin/sh` (unsigned by
#     any unit: its unit exits after 67 ms because the script daemonizes itself) -- burns **6.6% of a
#     core, permanently**, in a 1 Hz loop that walks `/proc/[0-9]*`, rewrites systemd unit files and
#     configures the RNDIS gadget. The rewrite is expensive: it triggers a `systemd daemon-reload`
#     **every ~6 s**, and each one takes ~2 s of systemd CPU (`Reloading finished in 2044 ms`). Stopping
#     it for measurement (SIGSTOP, reversible with SIGCONT, with a self-reverting 600 s timer as a
#     safety net) dropped the load average from 6.66-7.36 to 5.38-6.02 and **stopped the reloads
#     entirely** (last reload [9259.4], none in the following minutes), and the SoC cooled:
#     `tsens_tz_sensor1` 538 -> 490 (deci-degrees: 53.8 -> 49.0 C), `pm8994_tz` 48000 -> 46923 (46.9 C).
#     It is **not stopped here** on purpose: the keeper is what configures `rndis0`/`usb0` at boot
#     (`192.168.2.15/24` and `10.15.19.82/24`, announced with `arping -A`), and our own
#     `zl1-netwatch.sh` has an equivalent `restore_addrs()` -- but that function was reachable **only
#     from the heal stages**, and a heal needs 45 s of failed pings *and* uptime >= 90, so a keeper-less
#     boot would have had no address for ~135 s and then been fixed by a full RNDIS re-enumeration
#     (docs 88). The netwatch now re-asserts the addresses every sample (`ensure_addrs()`), which is
#     what makes the next stage a small step; retiring it still needs a reboot test;
#     losing the address means losing SSH, i.e. needing hands on the phone, which is exactly the sort of
#     step that does not get taken to save a few percent of CPU on someone else's behalf.
#   * About half of the remaining CPU is **kernel** time: a 20 s `/proc/stat` delta gave
#     user 16.9% / idle 24.1% / everything else 59%, i.e. ~3.0 of 4 cores busy with 2.4 of them in
#     the kernel. The container's own top agrees (`215%sys`). The named consumers only account for
#     ~0.5 cores (`sensorfwd` + `android.hardware.sensors@1.0-service` ~18% of one core, the graphics
#     composer ~4%), so most of it is IPC/reclaim/interrupt work with no owner. `ksoftirqd` has
#     accumulated ~6.5 minutes in 2.6 h and RCU ~6.7 minutes, which is the shape of heavy syscall
#     churn rather than one hot loop.
#   * The container is nearly full: **3.70 GB used of 3.87 GB** (162 MB free). Reclaim pressure is a
#     real contributor to that kernel time, but `kswapd0` has only 14 s of CPU on it, so it is not the
#     main cost. Worth knowing before blaming the governor for everything.
#
# What this installs (both files are new, on the `/etc/systemd/system` writable path -- `/` is a
# read-only image, and `/etc/systemd/system` here resolves into the rw `/etc/writable` mount, which is
# why the units this port already added live there):
#
#   /etc/systemd/system/zl1-cpufreq-governor.sh    the applier (also usable by hand)
#   /etc/systemd/system/zl1-cpufreq-governor.service   oneshot, RemainAfterExit, WantedBy=multi-user
#
# Deliberately **not** done: no frequency caps of our own (the shipped `scaling_max_freq` of
# 1132800/1363200 is left alone -- this only changes *when* the cores go up, not how far), no
# `min_freq` fiddling, no thermal-zone trip points (the device has **no cooling devices registered at
# all**, so there is no kernel throttling to tune -- `ls /sys/class/thermal/cooling_device*` is empty),
# and nothing inside the container.
#
# Usage: install-cpufreq-governor.sh [--install] [--remove] [--status] [--governor NAME]
#   --governor NAME  governor to set (default interactive); the applier reads
#                    ZL1_CPUFREQ_GOVERNOR from the unit's Environment= instead

set -u

HOST=${ZL1_HOST:-root@10.15.19.82}
SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 $HOST"
UNIT=/etc/systemd/system/zl1-cpufreq-governor.service
APPLIER=/etc/systemd/system/zl1-cpufreq-governor.sh
GOVERNOR=interactive
ACTION=--install

while [ $# -gt 0 ]; do
  case "$1" in
    --install|--remove|--status) ACTION="$1"; shift ;;
    --governor) GOVERNOR="$2"; shift 2 ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done

case "$ACTION" in
  --install)
    $SSH "cat > $APPLIER" <<'APPLIER_EOF'
#!/bin/sh
# Set the CPU frequency governor on every core that has one. Installed by
# scripts/install-cpufreq-governor.sh -- see that file for why this exists (the image ships
# `performance`, which pins all four cores at their maximum clock forever).
#
# Safe to run by hand at any time; it is idempotent and prints what it did.
GOV=${ZL1_CPUFREQ_GOVERNOR:-interactive}
n=0
for p in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
    [ -w "$p/scaling_governor" ] || continue
    echo "$GOV" > "$p/scaling_governor" 2>/dev/null || continue
    n=$((n + 1))
done
logger -t zl1-cpufreq "set governor '$GOV' on $n cores"
echo "zl1-cpufreq: governor '$GOV' on $n cores"
exit 0
APPLIER_EOF
    $SSH "chmod +x $APPLIER; cat > $UNIT" <<UNIT_EOF
[Unit]
Description=zl1: put the CPU cores on a scaling governor (the image ships 'performance')
# Before anything heavy starts, so the first minutes after boot are not spent at full clock.
After=local-fs.target
Before=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=ZL1_CPUFREQ_GOVERNOR=$GOVERNOR
ExecStart=$APPLIER

[Install]
WantedBy=multi-user.target
UNIT_EOF
    $SSH "systemctl daemon-reload && systemctl enable --now zl1-cpufreq-governor.service" 2>&1 | tail -2
    echo
    echo "--- the only honest check that the unit is in effect (systemctl cat, not is-enabled):"
    $SSH "systemctl cat zl1-cpufreq-governor.service | head -20; echo; systemctl is-active zl1-cpufreq-governor.service; systemctl show zl1-cpufreq-governor.service -p ExecMainStatus -p Result" 2>&1
    echo
    echo "--- governors now:"
    $SSH 'for p in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do printf "%s gov=%s cur=%s max=%s\n" "${p%/cpufreq}" "$(cat $p/scaling_governor)" "$(cat $p/scaling_cur_freq)" "$(cat $p/scaling_max_freq)"; done'
    ;;

  --remove)
    $SSH "systemctl disable --now zl1-cpufreq-governor.service 2>&1 | tail -1; rm -f $UNIT $APPLIER; systemctl daemon-reload; echo removed"
    echo "--- governors after removal (back to whatever the image set):"
    $SSH 'for p in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do printf "%s gov=%s\n" "${p%/cpufreq}" "$(cat $p/scaling_governor)"; done'
    ;;

  --status)
    echo "=== unit (systemctl cat is the only honest check a unit is in effect) ==="
    $SSH "systemctl cat zl1-cpufreq-governor.service 2>&1 | head -20; echo; systemctl is-active zl1-cpufreq-governor.service; systemctl is-enabled zl1-cpufreq-governor.service; systemctl show zl1-cpufreq-governor.service -p ExecMainStatus -p Result -p NRestarts" 2>&1
    echo
    echo "=== governors and clocks ==="
    $SSH 'cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors; for p in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do printf "%s gov=%-12s cur=%s max=%s\n" "${p%/cpufreq}" "$(cat $p/scaling_governor)" "$(cat $p/scaling_cur_freq)" "$(cat $p/scaling_max_freq)"; done'
    echo
    echo "=== the numbers that made this a stage (load, CPU split, thermal zones) ==="
    $SSH 'echo "load: $(cat /proc/loadavg)"; echo "uptime: $(cut -d. -f1 /proc/uptime)s"
a=$(awk "/^cpu /{print \$2,\$3,\$4,\$5,\$6,\$7,\$8}" /proc/stat); sleep 5; b=$(awk "/^cpu /{print \$2,\$3,\$4,\$5,\$6,\$7,\$8}" /proc/stat)
echo "5s cpu split (ticks): first=$a  second=$b"
echo "--- thermal zones (units differ per driver: tsens_* are deci-degC, pm8994_tz/battery are milli-degC, msm_therm/quiet_therm/pa_therm0/emmc_therm are plain degC)"
for z in /sys/class/thermal/thermal_zone*; do printf "%-22s %s\n" "$(cat $z/type)" "$(cat $z/temp)"; done | grep -vE "LLM_|DLMt_"'
    echo
    echo "=== and the thing that is still burning CPU on purpose (see the header) ==="
    $SSH 'ps -o pid=,stat=,time=,cmd= -C zl1-debug-net.sh 2>/dev/null; pgrep -f zl1-debug-net.sh >/dev/null && echo "(v63 debug keeper is running; so are its daemon-reloads)"'
    ;;
esac
