#!/usr/bin/env bash
# Make the device stop calling itself "Generic device".
#
# Why this exists: `update-machine-info-from-deviceinfo.service` was the last unit in
# `systemctl --failed`, and after the TLS drop-in it got it (docs 63) it started exiting 0 — but
# `hostnamectl` still said `Pretty hostname: Generic device`. It was not broken. Measured on the
# device with `dbus-monitor --system`, it does exactly two things:
#
#     GetAll  /org/freedesktop/hostname1  org.freedesktop.hostname1
#     SetChassis                           <- always
#     (no SetPrettyHostname)
#
# so it writes the chassis unconditionally and the pretty hostname **only when the current one is
# empty**. This image ships `/etc/machine-info` with
#
#     PRETTY_HOSTNAME="Generic device"
#     CHASSIS=handset
#
# from nowhere in particular — `dpkg -S /etc/machine-info` finds no owner — so the unit reads a
# non-empty value, decides the hostname is already set, and leaves it. Blank the line and the same
# binary writes `PRETTY_HOSTNAME="LeEco Pro3"` on the next run, which is its intended behaviour.
#
# The value comes from `libdeviceinfo`, and this is the second thing worth knowing: **there is no
# zl1 yaml and there does not need to be one.** With nothing matching in `/etc/deviceinfo/devices/`
# the library falls back to the Android properties and the `halium`/`phone` blocks of
# `/etc/deviceinfo/default.yaml`, and reports the device correctly:
#
#     Name: le_zl1        (ro.product.vendor.device)
#     PrettyName: LeEco Pro3   (ro.product.vendor.model)
#     DeviceType: phone   DriverType: halium   GridUnit: 21   PrimaryOrientation: Portrait
#
# `/etc/deviceinfo/devices/` is also on a read-only mount here, so a runtime yaml was never an
# option anyway — upstream expects a port to bind-mount `halium.yaml`, not to write into that
# directory. Nothing here adds one, and in particular nothing adds a `SensorfwConfig`: this port's
# working sensor configuration is `/etc/sensorfw/sensord.conf.d/30-hidl.conf` (the HIDL adaptors),
# while every `SensorfwConfig` in the tree names an `iiosensorsadaptor` file for a mainline-kernel
# Pine device. Pointing `sensorfwd --device-info` at one of those would move it off the adaptors
# that currently work.
#
# Usage: install-machine-info.sh --install | --remove | --status
#
# Two things about where the file lives, both found the hard way:
#
#   - `/etc/machine-info` is a **symlink** to `writable/machine-info`, i.e. into `/etc/writable`,
#     which is the one part of `/etc` that is a writable bind mount. Everything outside that list
#     is a read-only ext4 image (`/` is `/dev/loop0 ... ro`), so `sed -i /etc/machine-info` fails:
#     GNU sed writes its temp file next to the target and the symlink's directory is read-only.
#     Resolve it with `readlink -f` and edit the real path.
#   - `/etc/systemd/system` is writable (the drop-ins here prove it) but `/etc` itself is not, so
#     **no new file can be created in `/etc`** — the backup goes to `/userdata/`.
#
# Env: ZL1_HOST (default root@10.15.19.82)

set -uo pipefail
DEV="${ZL1_HOST:-root@10.15.19.82}"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$DEV")
UNIT=update-machine-info-from-deviceinfo.service
BAK=/userdata/zl1-machine-info/image-default.machine-info

guard() {
  "${SSH[@]}" 'grep -qa msm8996 /proc/device-tree/compatible' 2>/dev/null ||
    { echo "not the zl1 (no msm8996 in /proc/device-tree/compatible) — refusing" >&2; exit 1; }
}

# `device-info` links libdeviceinfo, which reaches bionic through libandroid-properties and needs
# the same TLS shim the services get (docs 48/63) — without it the tool segfaults like they did.
REMOTE_DEVICEINFO='export LD_PRELOAD=/usr/lib/aarch64-linux-gnu/libtls-padding.so
  /usr/bin/device-info 2>/dev/null'

case "${1:-}" in
--install)
  guard
  # Ask what the device says it is before touching anything. If the library has no pretty name to
  # offer, blanking the line would leave the machine with no hostname at all, so refuse instead.
  pretty="$("${SSH[@]}" "$REMOTE_DEVICEINFO" | sed -n 's/^PrettyName: //p' | head -1)"
  if [ -z "$pretty" ]; then
    echo "libdeviceinfo reports no PrettyName on this device — refusing to blank the hostname" >&2
    exit 1
  fi
  echo "deviceinfo says this device is: $pretty"

  "${SSH[@]}" "BAK='$BAK' UNIT='$UNIT' bash -s" <<'REMOTE'
set -u
# /etc/machine-info is a symlink into /etc/writable; everything else under /etc is a read-only
# image. Edit the resolved path, and only create new files under /userdata.
MI=$(readlink -f /etc/machine-info)
case "$MI" in
/*) ;;
*) echo "  /etc/machine-info does not resolve to an absolute path — refusing" >&2; exit 1 ;;
esac
[ -f "$MI" ] || { echo "  $MI is not a file — refusing" >&2; exit 1; }
mkdir -p "$(dirname "$BAK")"
# Keep the image's file once, so --remove has something truthful to restore. `cp -a` over an
# existing backup would overwrite the original with the already-fixed file, so it is skipped if
# the backup is there.
if [ ! -f "$BAK" ]; then
  cp -a "$MI" "$BAK"
  echo "  saved the image default to $BAK"
else
  echo "  $BAK already exists, not overwriting it"
fi
echo "  editing $MI"
if grep -q '^PRETTY_HOSTNAME=' "$MI"; then
  # sed -i, not a rewrite: CHASSIS and anything else a future image adds must survive.
  sed -i '/^PRETTY_HOSTNAME=/d' "$MI"
  echo "  removed the stale PRETTY_HOSTNAME line"
else
  echo "  no PRETTY_HOSTNAME line to remove"
fi
# The value the unit will write is exactly what deviceinfo reports, so this is idempotent: run it
# twice and the second run finds a non-empty hostname and changes nothing.
systemctl reset-failed "$UNIT" >/dev/null 2>&1
systemctl start "$UNIT" >/dev/null 2>&1
sleep 3
printf '  Result=%s\n' "$(systemctl show "$UNIT" -p Result --value)"
printf '  %s: %s\n' "$MI" "$(tr '\n' ' ' < "$MI")"
printf '  Pretty hostname now: %s\n' "$(hostnamectl --pretty 2>/dev/null)"
REMOTE
  echo
  echo "Verify with: $0 --status"
  ;;
--remove)
  guard
  "${SSH[@]}" "BAK='$BAK' UNIT='$UNIT' bash -s" <<'REMOTE'
set -u
MI=$(readlink -f /etc/machine-info)
if [ -f "$BAK" ]; then
  cp -a "$BAK" "$MI"
  echo "restored $BAK over $MI"
else
  echo "no $BAK to restore — leaving $MI alone" >&2
fi
systemctl reset-failed "$UNIT" >/dev/null 2>&1
systemctl start "$UNIT" >/dev/null 2>&1
sleep 3
printf 'Pretty hostname now: %s\n' "$(hostnamectl --pretty 2>/dev/null)"
REMOTE
  ;;
--status)
  guard
  echo "--- what the device says it is (libdeviceinfo) ---"
  "${SSH[@]}" "$REMOTE_DEVICEINFO" | sed 's/^/  /'
  echo
  echo "--- what systemd thinks ---"
  "${SSH[@]}" "
    printf '  Static hostname: %s\n' \"\$(hostnamectl --static 2>/dev/null)\"
    printf '  Pretty hostname: %s\n' \"\$(hostnamectl --pretty 2>/dev/null)\"
    printf '  Chassis:         %s\n' \"\$(hostnamectl 2>/dev/null | sed -n 's/^ *Chassis: *//p')\"
    echo '  /etc/machine-info:'
    sed 's/^/    /' /etc/machine-info 2>/dev/null || echo '    (absent)'
    if [ -f '$BAK' ]; then
      echo '  image default saved at $BAK:'
      sed 's/^/    /' '$BAK'
    else
      echo '  no $BAK — --remove would have nothing to restore'
    fi
    echo '  unit:'
    systemctl show '$UNIT' -p ActiveState -p SubState -p Result -p NRestarts --value 2>/dev/null | tr '\n' ' ' | sed 's/^/    /'; echo"
  echo
  echo "--- the deviceinfo directory (expected read-only; a yaml here is not how this port is set up) ---"
  "${SSH[@]}" "
    ls /etc/deviceinfo/devices/ 2>&1 | sed 's/^/  /'
    printf '  zl1/le_zl1 entry present: '
    ls /etc/deviceinfo/devices/ 2>/dev/null | grep -qiE 'zl1|le_' && echo yes || echo 'no — libdeviceinfo falls back to the Android properties, which are correct'"
  ;;
*)
  awk 'NR==1{next} /^#/{print; next} {exit}' "$0"; exit 1;;
esac
