#!/usr/bin/env bash
set -euo pipefail

# Build a zl1 Halium diagnostic boot image that brings up initramfs USB
# RNDIS/telnet early, but does NOT stop at break=premount. The normal Halium
# boot path continues, leaving a host-visible debug endpoint if later boot
# stages hang.
#
# Host-side only: this script does not run adb/fastboot and does not touch the
# phone or block devices.

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 /path/to/filtered-halium-boot.img /path/to/output.img" >&2
  exit 2
fi

HALIUM_BOOT=$(realpath -m "$1")
OUT_IMG=$(realpath -m "$2")
OUT_DIR=$(dirname "$OUT_IMG")

[[ -f "$HALIUM_BOOT" ]] || { echo "Missing boot image: $HALIUM_BOOT" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null || { echo "Missing required command: $1" >&2; exit 1; }
}
for cmd in abootimg mkbootimg gzip cpio find python3 sha256sum stat; do
  require_cmd "$cmd"
done

mkdir -p "$OUT_DIR"
WORK_DIR=$(mktemp -d "$OUT_DIR/.make-usbdebug-boot.XXXXXX")
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

extract_cmdline() {
  python3 - "$1" <<'PY'
import sys
from pathlib import Path
cfg = Path(sys.argv[1])
for line in cfg.read_text().splitlines():
    if line.startswith('cmdline = '):
        print(line[len('cmdline = '):])
        break
else:
    raise SystemExit(f'cmdline not found in {cfg}')
PY
}

printf 'Mode: make nonblocking Halium USB debug boot image\n'
printf 'Input Halium boot: %s\n' "$HALIUM_BOOT"
printf 'Output image:      %s\n' "$OUT_IMG"
printf 'This is host-side only; it does not run adb/fastboot and does not touch the phone.\n\n'

abootimg -x "$HALIUM_BOOT" \
  "$WORK_DIR/bootimg.cfg" \
  "$WORK_DIR/zImage" \
  "$WORK_DIR/initrd.img" >/dev/null

RAMDISK_DIR="$WORK_DIR/ramdisk"
mkdir -p "$RAMDISK_DIR"
(
  cd "$RAMDISK_DIR"
  gzip -dc "$WORK_DIR/initrd.img" | cpio -idm --quiet
)

mkdir -p "$RAMDISK_DIR/scripts/local-premount"
cat > "$RAMDISK_DIR/scripts/local-premount/zl1-usb-debug" <<'EOF'
#!/bin/sh
# Nonblocking initramfs USB debug endpoint for zl1 Halium diagnostics.
# Starts RNDIS + telnet early, then returns so normal boot continues.

case "$1" in
prereqs)
    exit 0
    ;;
esac

PATH=/sbin:/usr/sbin:/bin:/usr/bin
USB_FUNCTIONS=rndis
ANDROID_USB=/sys/class/android_usb/android0
GADGET_DIR=/config/usb_gadget
LOCAL_IP=192.168.2.15
TELNET_DEBUG_PORT=23
BUSYBOX=/bin/busybox

log() {
    echo "zl1-usb-debug: $*" >/dev/kmsg 2>/dev/null || true
}

write_file() {
    echo -n "$2" >"$1" 2>/dev/null || true
}

setup_android_usb() {
    [ -d "$ANDROID_USB" ] || return 1
    log "using android_usb gadget path"
    write_file "$ANDROID_USB/enable" 0
    write_file "$ANDROID_USB/functions" ""
    usleep 300000 2>/dev/null || sleep 1
    write_file "$ANDROID_USB/enable" 0
    write_file "$ANDROID_USB/idVendor" 18D1
    write_file "$ANDROID_USB/idProduct" D001
    write_file "$ANDROID_USB/iManufacturer" "Halium initrd"
    write_file "$ANDROID_USB/iProduct" "zl1 debug boot"
    write_file "$ANDROID_USB/iSerial" "zl1-debug 192.168.2.15"
    write_file "$ANDROID_USB/functions" "$USB_FUNCTIONS"
    write_file "$ANDROID_USB/enable" 1
    return 0
}

setup_configfs() {
    mkdir /config 2>/dev/null || true
    grep -q ' /config ' /proc/mounts 2>/dev/null || mount -t configfs none /config 2>/dev/null || true
    [ -d "$GADGET_DIR" ] || return 1
    log "using configfs gadget path"

    mkdir -p "$GADGET_DIR/g1/strings/0x409" "$GADGET_DIR/g1/configs/c.1/strings/0x409" 2>/dev/null || true
    write_file "$GADGET_DIR/g1/idVendor" "0x18D1"
    write_file "$GADGET_DIR/g1/idProduct" "0xD001"
    write_file "$GADGET_DIR/g1/strings/0x409/serialnumber" "zl1-debug 192.168.2.15"
    write_file "$GADGET_DIR/g1/strings/0x409/manufacturer" "Halium initrd"
    write_file "$GADGET_DIR/g1/strings/0x409/product" "zl1 debug boot"
    write_file "$GADGET_DIR/g1/configs/c.1/strings/0x409/configuration" "$USB_FUNCTIONS"

    mkdir -p "$GADGET_DIR/g1/functions/rndis.usb0" 2>/dev/null || true
    ln -s "$GADGET_DIR/g1/functions/rndis.usb0" "$GADGET_DIR/g1/configs/c.1/rndis.usb0" 2>/dev/null || true
    if [ -n "$(ls /sys/class/udc 2>/dev/null)" ]; then
        echo "$(ls /sys/class/udc | head -1)" > "$GADGET_DIR/g1/UDC" 2>/dev/null || true
    fi
    return 0
}

setup_interface() {
    USB_IFACE=notfound
    if /sbin/ifconfig rndis0 "$LOCAL_IP" up 2>/dev/null; then
        USB_IFACE=rndis0
    elif /sbin/ifconfig usb0 "$LOCAL_IP" up 2>/dev/null; then
        USB_IFACE=usb0
    fi
    [ "$USB_IFACE" != notfound ] || return 1

    cat > /etc/udhcpd.conf <<EOF_DHCP
start 192.168.2.20
end 192.168.2.90
lease_file /var/udhcpd.leases
interface $USB_IFACE
option subnet 255.255.255.0
EOF_DHCP

    pidof udhcpd >/dev/null 2>&1 || "$BUSYBOX" udhcpd >/dev/kmsg 2>&1 || true
    pidof telnetd >/dev/null 2>&1 || "$BUSYBOX" telnetd -b ${LOCAL_IP}:${TELNET_DEBUG_PORT} -l /bin/sh >/dev/kmsg 2>&1 || true

    log "ready on $USB_IFACE $LOCAL_IP:${TELNET_DEBUG_PORT}; continuing normal boot"
    return 0
}

log "starting nonblocking USB debug setup"
setup_android_usb || setup_configfs || log "could not set USB gadget"
setup_interface || log "could not configure rndis0/usb0 yet"
/sbin/ifconfig -a >/dev/kmsg 2>&1 || true
exit 0
EOF
chmod +x "$RAMDISK_DIR/scripts/local-premount/zl1-usb-debug"

ORDER="$RAMDISK_DIR/scripts/local-premount/ORDER"
touch "$ORDER"
if ! grep -q '/scripts/local-premount/zl1-usb-debug' "$ORDER"; then
  {
    printf '/scripts/local-premount/zl1-usb-debug "$@"\n'
    cat "$ORDER"
  } > "$ORDER.new"
  mv "$ORDER.new" "$ORDER"
fi

NEW_INITRD="$WORK_DIR/initrd-usbdebug.img"
(
  cd "$RAMDISK_DIR"
  find . -print0 | cpio --null -o -H newc --owner=0:0 --quiet | gzip -9 > "$NEW_INITRD"
)

CMDLINE=$(extract_cmdline "$WORK_DIR/bootimg.cfg")
# Make sure an accidentally supplied break image does not stop in initramfs.
CMDLINE=$(python3 - "$CMDLINE" <<'PY'
import sys
cmd = sys.argv[1].split()
filtered = [x for x in cmd if not (x == 'break' or x.startswith('break='))]
print(' '.join(filtered))
PY
)

mkbootimg \
  --kernel "$WORK_DIR/zImage" \
  --ramdisk "$NEW_INITRD" \
  --cmdline "$CMDLINE" \
  --base 0x80000000 \
  --kernel_offset 0x00008000 \
  --ramdisk_offset 0x01000000 \
  --second_offset 0x00f00000 \
  --tags_offset 0x00000100 \
  --pagesize 4096 \
  --header_version 0 \
  -o "$OUT_IMG"

printf 'Created:\n'
printf '  path:   %s\n' "$OUT_IMG"
printf '  size:   %s bytes\n' "$(stat -c '%s' "$OUT_IMG")"
printf '  sha256: %s\n' "$(sha256sum "$OUT_IMG" | awk '{print $1}')"
printf '\nTemporary test command after the phone is back in fastboot:\n'
printf '  fastboot boot %s\n' "$OUT_IMG"
printf '\nDo not flash this image unless separately reviewed and explicitly approved.\n'
