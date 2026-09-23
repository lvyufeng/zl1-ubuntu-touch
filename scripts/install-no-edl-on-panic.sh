#!/usr/bin/env bash
# Remove one automatic path from "a panic" to "the device sits in EDL waiting for a finger".
#
# Why this exists (docs/ubuntu-touch/86): the 2026-09-23 trip into Qualcomm EDL was unattributed for a
# whole session. Reading the kernel tree that built the flashed image found the mechanism, and it is
# **armed by default**:
#
#     panic -> panic notifier sets in_panic -> msm_restart_prepare():
#         set_dload_mode(download_mode && (in_panic || restart_mode == RESTART_DLOAD))
#     -> (IMEM magics are absent on msm8996, so) scm_set_dload_mode(SCM_DLOAD_MODE)
#        -> scm_io_write(tcsr-boot-misc-detect = 0x7b3000, 0x10)
#     -> msm_trigger_wdog_bite()            [CONFIG_MSM_FORCE_WDOG_BITE_ON_PANIC=y]
#     -> the SoC resets with the dload flag set -> the bootloader enters EDL instead of booting.
#
# `download_mode` is a compiled-in **1** (`drivers/power/reset/msm-poweroff.c:63`) and is exposed as a
# 0644 module parameter (`module_param_call(download_mode, dload_set, ...)`, `:95`). So the escalation
# can be turned off from userspace, with the driver's own interface, without flashing anything:
#
#     echo 0 > /sys/module/<name>/parameters/download_mode
#
# Two things make that safe to do, and both come from the source rather than from hope:
#
#   1. **It is not a state the device does not otherwise enter.** Every *normal* restart already calls
#      `set_dload_mode(0)`: `msm_restart_prepare()` computes `download_mode && (in_panic || ...)`, which
#      is false for `systemctl reboot`, for `poweroff` (`do_msm_poweroff()` calls `set_dload_mode(0)`
#      directly) and for a `reboot recovery`. The flag is set to 1 at probe time and cleared again on
#      every ordinary shutdown path -- so writing 0 only changes what a **panic** does.
#   2. **It works even if the secure-world write fails.** `set_dload_mode()` first writes the (absent)
#      IMEM magics, then calls `scm_set_dload_mode()`, and finally records `dload_mode_enabled = on` in
#      the kernel. `msm_restart_prepare()` consults `get_dload_mode()`, i.e. that kernel-side variable --
#      so the policy takes effect regardless of whether TZ accepts the register write. (Docs 58 records
#      that `scm_call` does return -12 on this device on some boots, which is exactly why this matters.)
#
# **What this does NOT do, and the unit says so out loud:** it removes one gate, not necessarily the
# only gate. The forced watchdog bite still happens on a panic, and whether this device's bootloader
# treats a watchdog reset as a download-mode trigger *independently* of the flag has never been
# tested -- it cannot be tested except by panicking the device. So this lowers a probability; it does
# not make a trip impossible, and `scripts/device/zl1-edl-postmortem.sh` stays the only way to
# attribute one. Nothing here should ever be cited as "EDL can no longer happen".
#
# And because a claim needs a witness, the same installer also adds a **read-only** unit that copies
# `/sys/fs/pstore/*` (ramoops: the oops and console records) into the persistent partition at every
# boot. Nothing captures pstore today -- `install-kmsg-drain.sh` handles the kmsg ring, which dies with
# the reset -- so a panic record currently survives only until the ramoops console zone fills or a
# later boot reuses it. Capturing it early makes the record durable and dated, which is what the
# post-mortem needs. That unit writes nothing outside `/userdata` and changes no policy.
#
# Installed on the `/etc/systemd/system` writable path (the same one every other unit of this port
# lives on: `/` is a read-only image and `/etc/systemd/system` resolves into the rw `/etc/writable`
# mount). Two appliers, both plain shell, both idempotent, both runnable by hand:
#
#   /etc/systemd/system/zl1-panic-guard.sh            pstore -> /userdata/zl1-kmsg/keep/pstore-<boot_id>/
#   /etc/systemd/system/zl1-no-edl-on-panic.sh        download_mode -> 0, verified by read-back
#
# Usage: install-no-edl-on-panic.sh [--status] [--install] [--capture-only] [--remove]
#   --status        (default) what is installed, what the flag reads now, what pstore holds
#   --install       both units: the pstore capture and the download_mode policy
#   --capture-only  only the pstore capture -- evidence without any policy change
#   --remove        disable and delete both, and put the flag back to the image's default (1)
#
# Nothing here flashes, writes a partition, or touches the boot image. The only persistent writes are
# two small files and two unit files on the rw /etc path.

set -u

HOST=${ZL1_HOST:-root@10.15.19.82}
SSH="ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 $HOST"
D=/etc/systemd/system
CAP_SH=$D/zl1-panic-guard.sh
CAP_UNIT=$D/zl1-panic-guard.service
POL_SH=$D/zl1-no-edl-on-panic.sh
POL_UNIT=$D/zl1-no-edl-on-panic.service
ACTION=--status

while [ $# -gt 0 ]; do
  case "$1" in
    --status|--install|--capture-only|--remove) ACTION="$1"; shift ;;
    --help|-h) awk 'NR==1{next} /^#/{print; next} {exit}' "$0" ; exit 0 ;;
    *) echo "unknown argument $1 (try --help)" >&2; exit 2 ;;
  esac
done

# The device-side appliers. Kept as here-docs, like the other installers in this directory.
read -r -d '' CAP_EOF <<'CAP'
#!/bin/sh
# Copy the kernel's pstore records (ramoops: console + oops) onto the persistent partition, at boot,
# before anything else can fill the ramoops zone. Read-only with respect to the kernel: it reads
# /sys/fs/pstore and writes only under /userdata. Installed by scripts/install-no-edl-on-panic.sh.
P=/sys/fs/pstore
D=/userdata/zl1-kmsg
K=$D/keep

[ -d "$P" ] || { logger -t zl1-panic-guard "no /sys/fs/pstore on this kernel"; exit 0; }
set -- "$P"/*
[ -e "$1" ] || { logger -t zl1-panic-guard "pstore empty at boot $(cut -d. -f1 /proc/uptime)s"; exit 0; }

BOOT=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
[ -n "$BOOT" ] || BOOT=unknown
# "<boot_id>.pstore" so a boot that captured nothing leaves a visible absence rather than a gap
A="$K/pstore-$BOOT.pstore"
mkdir -p "$D" "$K" "$A" 2>/dev/null || exit 0
cp -f "$P"/* "$A"/ 2>/dev/null
printf '%s captured=%s files=%s\n' "$(cut -d. -f1 /proc/uptime)" "$BOOT" "$(ls "$A" | wc -l)" \
    >> "$K/pstore-archive.log" 2>/dev/null
# newest 4, same policy as the kmsg archive; each is a few KiB
ls -dt "$K"/pstore-*.pstore 2>/dev/null | tail -n +5 | while IFS= read -r p; do rm -rf "$p"; done
logger -t zl1-panic-guard "pstore captured to $A ($(ls "$A" | wc -l) files)"
exit 0
CAP

read -r -d '' POL_EOF <<'POL'
#!/bin/sh
# Clear the kernel's panic -> Qualcomm EDL escalation, using the driver's own runtime parameter.
# Installed by scripts/install-no-edl-on-panic.sh -- read that file for why, and for the caveat that
# this removes ONE gate and does not prove EDL cannot happen. Idempotent; safe to run by hand.
#
# `download_mode` is a 0644 module_param_call in drivers/power/reset/msm-poweroff.c, compiled in as 1.
# With it 0, msm_restart_prepare() evaluates set_dload_mode(0) on a panic, so the dload flag is not set
# and the SoC resets normally instead of entering the download loader.
found=0
ok=1
for p in /sys/module/*/parameters/download_mode; do
    [ -e "$p" ] || continue
    found=1
    before=$(cat "$p" 2>/dev/null)
    echo 0 > "$p" 2>/dev/null
    after=$(cat "$p" 2>/dev/null)
    logger -t zl1-no-edl "download_mode $before -> $after ($p)"
    echo "zl1-no-edl: $p $before -> $after"
    # Verified by read-back, and a failed write FAILS THE UNIT on purpose. A guard that silently is
    # not armed is worse than a unit that shows up in `systemctl --failed`: the whole point of this
    # file is to be able to say whether the escalation is off, and "Result=success" over an unchanged
    # flag would be a lie of exactly the kind this project keeps finding in its own instruments.
    [ "$after" = 0 ] || { echo "zl1-no-edl: the flag did NOT clear (reads '$after') -- a panic would still arm EDL"; ok=0; }
done
[ "$found" = 1 ] || { logger -t zl1-no-edl "no /sys/module/*/parameters/download_mode -- driver not built in?"; echo "zl1-no-edl: the parameter does not exist"; exit 1; }
[ "$ok" = 1 ] || exit 1
# The caveat is repeated on every boot on purpose: the day someone reads this log to decide whether a
# trip was impossible, the answer must be in the log itself, not in a document they did not open.
logger -t zl1-no-edl "NOTE: the forced watchdog bite on panic still happens; whether this device's bootloader enters EDL independently of the flag is untested (docs 86)"
exit 0
POL

case "$ACTION" in
--install|--capture-only)
  $SSH "cat > $CAP_SH" <<CAP_APPLIER
$CAP_EOF
CAP_APPLIER
  $SSH "chmod 0755 $CAP_SH; cat > $CAP_UNIT" <<'CAP_UNIT_EOF'
[Unit]
Description=zl1: capture /sys/fs/pstore (ramoops oops/console) onto the persistent partition
# /userdata is what we write to, so local-fs must be up. DefaultDependencies=no so this is not held
# back behind the usual sysinit ordering: pstore should be read as early as possible.
DefaultDependencies=no
After=local-fs.target
Before=multi-user.target
StartLimitIntervalSec=0

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/etc/systemd/system/zl1-panic-guard.sh

[Install]
WantedBy=multi-user.target
CAP_UNIT_EOF

  if [ "$ACTION" = "--install" ]; then
    $SSH "cat > $POL_SH" <<POL_APPLIER
$POL_EOF
POL_APPLIER
    $SSH "chmod 0755 $POL_SH; cat > $POL_UNIT" <<'POL_UNIT_EOF'
[Unit]
Description=zl1: clear the panic -> Qualcomm EDL escalation (download_mode=0)
DefaultDependencies=no
After=local-fs.target
Before=multi-user.target
StartLimitIntervalSec=0

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/etc/systemd/system/zl1-no-edl-on-panic.sh

[Install]
WantedBy=multi-user.target
POL_UNIT_EOF
  fi

  # --capture-only must be NON-DESTRUCTIVE about the policy unit. An earlier draft disabled and
  # deleted it here, which meant that re-running in capture-only mode to inspect things would
  # silently disarm a guard that was already installed -- and it would do so in the unsafe
  # direction. It now leaves the policy unit exactly as it found it and says which state that was.
  $SSH "systemctl daemon-reload
    systemctl enable --now zl1-panic-guard.service >/dev/null 2>&1
    if [ '$ACTION' = '--install' ]; then
      systemctl enable --now zl1-no-edl-on-panic.service >/dev/null 2>&1
    fi
    systemctl daemon-reload" 2>&1 | tail -2

  echo
  echo "--- the only honest check that a unit is in effect (systemctl cat, not is-enabled):"
  $SSH "systemctl cat zl1-panic-guard.service | head -14; echo; systemctl is-active zl1-panic-guard.service; systemctl show zl1-panic-guard.service -p ExecMainStatus -p Result" 2>&1
  if [ "$ACTION" = "--install" ]; then
    $SSH "echo; systemctl cat zl1-no-edl-on-panic.service | head -14; echo; systemctl is-active zl1-no-edl-on-panic.service; systemctl show zl1-no-edl-on-panic.service -p ExecMainStatus -p Result" 2>&1
  fi
  echo
  echo "--- what the flag reads now (0 = a panic will not arm EDL):"
  $SSH 'for p in /sys/module/*/parameters/download_mode; do [ -e "$p" ] && echo "$p = $(cat $p)"; done' 2>&1
  echo
  echo "--- pstore right now:"
  $SSH 'ls -l /sys/fs/pstore/ 2>/dev/null || echo "(no /sys/fs/pstore)"' 2>&1
  echo
  if [ "$ACTION" = "--capture-only" ]; then
    echo "capture-only: the pstore capture is installed and the download_mode policy was NOT touched."
    echo "--- the policy unit's current state, so it is clear what was left alone:"
    $SSH "if [ -f $POL_UNIT ]; then echo '$POL_UNIT is present: $(systemctl is-active zl1-no-edl-on-panic.service 2>&1)'; else echo '$POL_UNIT is not installed (no policy change on this device)'; fi" 2>&1
  else
    echo "Both installed. Read the caveat in the header of scripts/install-no-edl-on-panic.sh: this"
    echo "removes one gate to EDL, it does not prove EDL cannot happen. Attribute a trip with"
    echo "scripts/device/zl1-edl-postmortem.sh, never by assuming this unit prevented it."
  fi
  ;;

--remove)
  $SSH "systemctl disable --now zl1-panic-guard.service zl1-no-edl-on-panic.service 2>&1 | tail -2
    rm -f $CAP_SH $CAP_UNIT $POL_SH $POL_UNIT
    systemctl daemon-reload
    echo removed" 2>&1
  echo
  echo "--- putting the flag back to the image's compiled-in default, so the device is left as found:"
  $SSH 'for p in /sys/module/*/parameters/download_mode; do [ -e "$p" ] && { echo 1 > "$p"; echo "$p = $(cat $p)  (1 = the image default: a panic arms EDL again)"; }; done' 2>&1
  echo
  echo "--- the capture archive is left in place (it is evidence, not configuration):"
  $SSH 'ls -dt /userdata/zl1-kmsg/keep/pstore-*.pstore 2>/dev/null | head -4 || echo "(none)"' 2>&1
  ;;

--status)
  echo "=== unit files present? ==="
  $SSH "ls -l $CAP_SH $CAP_UNIT $POL_SH $POL_UNIT 2>&1" 2>&1
  echo
  echo "=== units (systemctl cat is the only honest check) ==="
  $SSH "systemctl cat zl1-panic-guard.service zl1-no-edl-on-panic.service 2>&1 | head -30" 2>&1
  echo
  echo "=== is-active / result ==="
  $SSH "for u in zl1-panic-guard zl1-no-edl-on-panic; do printf '%s: active=%s enabled=%s result=%s status=%s\n' \"\$u\" \"\$(systemctl is-active \$u.service 2>&1)\" \"\$(systemctl is-enabled \$u.service 2>&1)\" \"\$(systemctl show \$u.service -p Result --value 2>&1)\" \"\$(systemctl show \$u.service -p ExecMainStatus --value 2>&1)\"; done" 2>&1
  echo
  echo "=== the flag, live (0 = a panic will not arm EDL; 1 = it will) ==="
  $SSH 'for p in /sys/module/*/parameters/download_mode; do [ -e "$p" ] && echo "$p = $(cat $p)"; done' 2>&1
  echo
  echo "=== pstore now, and what has been captured ==="
  $SSH 'echo "--- live:"; ls -l /sys/fs/pstore/ 2>/dev/null || echo "(no /sys/fs/pstore)"
echo "--- archive index (newest last):"; tail -n 6 /userdata/zl1-kmsg/keep/pstore-archive.log 2>/dev/null || echo "(no captures yet -- the unit runs at boot)"
echo "--- captures kept:"; ls -dt /userdata/zl1-kmsg/keep/pstore-*.pstore 2>/dev/null | head -4' 2>&1
  ;;
esac
