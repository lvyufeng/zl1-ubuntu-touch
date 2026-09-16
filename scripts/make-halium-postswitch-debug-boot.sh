#!/usr/bin/env bash
set -euo pipefail

# Build a zl1 Halium diagnostic boot image that:
#   1. starts initramfs RNDIS/telnet early and continues normal boot;
#   2. installs a temporary /tmp/zl1-debug-init inside the Ubuntu rootfs just
#      before switch_root;
#   3. boots with init=/tmp/zl1-debug-init, which starts a post-switch_root
#      busybox telnetd on 192.168.2.15:2323 and then execs /sbin/init.
#
# Host-side only: this script does not run adb/fastboot and does not touch the
# phone or block devices. The resulting boot image will modify the staged
# /data/rootfs.img regular file during boot by writing /tmp/zl1-* debug files.

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
WORK_DIR=$(mktemp -d "$OUT_DIR/.make-postswitch-debug-boot.XXXXXX")
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

printf 'Mode: make post-switch-root Halium debug boot image\n'
printf 'Input Halium boot: %s\n' "$HALIUM_BOOT"
printf 'Output image:      %s\n' "$OUT_IMG"
printf 'Host-side only. The resulting image writes temporary debug files into rootfs.img during boot.\n\n'

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

mkdir -p "$RAMDISK_DIR/scripts/local-premount" "$RAMDISK_DIR/scripts/init-bottom"

cat > "$RAMDISK_DIR/scripts/local-premount/zl1-usb-debug" <<'EOF'
#!/bin/sh
# Nonblocking initramfs USB debug endpoint for zl1 Halium diagnostics.
# Starts RNDIS + telnet early, then returns so normal boot continues.
case "$1" in prereqs) exit 0 ;; esac

PATH=/sbin:/usr/sbin:/bin:/usr/bin
USB_FUNCTIONS=rndis
ANDROID_USB=/sys/class/android_usb/android0
GADGET_DIR=/config/usb_gadget
LOCAL_IP=192.168.2.15
TELNET_DEBUG_PORT=23
BUSYBOX=/bin/busybox

log() { echo "zl1-usb-debug: $*" >/dev/kmsg 2>/dev/null || true; }
write_file() { echo -n "$2" >"$1" 2>/dev/null || true; }

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
    [ -n "$(ls /sys/class/udc 2>/dev/null)" ] && echo "$(ls /sys/class/udc | head -1)" > "$GADGET_DIR/g1/UDC" 2>/dev/null || true
    return 0
}

setup_interface() {
    USB_IFACE=notfound
    if /sbin/ifconfig rndis0 "$LOCAL_IP" up 2>/dev/null; then USB_IFACE=rndis0
    elif /sbin/ifconfig usb0 "$LOCAL_IP" up 2>/dev/null; then USB_IFACE=usb0
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
    log "initramfs debug ready on $USB_IFACE $LOCAL_IP:${TELNET_DEBUG_PORT}; continuing normal boot"
    return 0
}

log "starting nonblocking USB debug setup"
setup_android_usb || setup_configfs || log "could not set USB gadget"
setup_interface || log "could not configure rndis0/usb0 yet"
/sbin/ifconfig -a >/dev/kmsg 2>&1 || true
exit 0
EOF
chmod +x "$RAMDISK_DIR/scripts/local-premount/zl1-usb-debug"

cat > "$RAMDISK_DIR/scripts/init-bottom/zl1-postswitch-debug-init" <<'EOF'
#!/bin/sh
# Install a temporary init wrapper into the mounted Ubuntu rootfs. The boot
# cmdline uses init=/tmp/zl1-debug-init, so run-init will execute this wrapper
# after switch_root. The wrapper starts a rootfs telnet shell on 192.168.2.15:2323
# and then execs the real /sbin/init.
case "$1" in prereqs) exit 0 ;; esac

PATH=/sbin:/usr/sbin:/bin:/usr/bin
ROOT="${rootmnt:-/root}"
log() { echo "zl1-postswitch-debug: $*" >/dev/kmsg 2>/dev/null || true; }

[ -d "$ROOT" ] || { log "missing rootmnt $ROOT"; exit 0; }
log "installing /tmp/zl1-debug-init into $ROOT"

mount -o remount,rw "$ROOT" 2>/dev/null || log "remount rw failed; trying to continue"
mkdir -p "$ROOT/tmp" "$ROOT/usr/local/sbin" "$ROOT/etc/systemd/system/sysinit.target.wants" "$ROOT/etc/systemd/system/multi-user.target.wants" 2>/dev/null || true
chmod 1777 "$ROOT/tmp" 2>/dev/null || true
cp /bin/busybox "$ROOT/tmp/busybox" 2>/dev/null || log "copy busybox to /tmp failed"
chmod 0755 "$ROOT/tmp/busybox" 2>/dev/null || true
cp /bin/busybox "$ROOT/usr/local/sbin/zl1-busybox" 2>/dev/null || log "copy busybox to /usr/local/sbin failed"
chmod 0755 "$ROOT/usr/local/sbin/zl1-busybox" 2>/dev/null || true

cat > "$ROOT/usr/local/sbin/zl1-status-login.sh" <<'EOF_ZL1_STATUS_LOGIN'
#!/bin/sh
PATH=/usr/local/sbin:/sbin:/usr/sbin:/bin:/usr/bin:/tmp
echo "zl1 status endpoint"
date 2>/dev/null || true
echo "--- cmdline ---"
cat /proc/cmdline 2>/dev/null || true
echo "--- uptime ---"
cat /proc/uptime 2>/dev/null || true
echo "--- mounts ---"
mount 2>/dev/null || true
echo "--- ip ---"
ip -br addr show 2>/dev/null || ifconfig -a 2>/dev/null || true
echo "--- routes ---"
ip route show 2>/dev/null || route -n 2>/dev/null || true
echo "--- listeners ---"
ss -ltnp 2>/dev/null || netstat -ltnp 2>/dev/null || true
echo "--- debug net log ---"
cat /run/zl1-debug-net.log 2>/dev/null || true
echo "--- debug init log ---"
cat /run/zl1-debug-init.log 2>/dev/null || true
echo "--- lxc logs ---"
cat /run/zl1-lxc-ready.log 2>/dev/null || true
cat /var/log/lxc/android.log 2>/dev/null || true
echo "--- processes ---"
ps wwax 2>/dev/null || ps 2>/dev/null || true
echo "zl1 status endpoint done"
sleep 1
EOF_ZL1_STATUS_LOGIN
chmod 0755 "$ROOT/usr/local/sbin/zl1-status-login.sh" 2>/dev/null || true

cat > "$ROOT/usr/local/sbin/zl1-status-server.py" <<'EOF_ZL1_STATUS_SERVER'
#!/usr/bin/python3
# V44: minimal no-subprocess HTTP status server. V43 accepted connections but
# reset them before the host received data; avoid fork/subprocess work and always
# send a small response first. This is status-only, no shell and no writes outside
# /run logs.
import os, socket, threading, time

LOG = "/run/zl1-debug-net.log"
PORTS = (8081, 8080)


def read_file(path, limit=65536):
    try:
        with open(path, "rb") as f:
            data = f.read(limit)
        return data.decode("utf-8", "replace")
    except Exception as e:
        return f"<cannot read {path}: {e}>\n"


def append_log(msg):
    line = f"zl1-python-status: {msg}\n"
    try:
        os.makedirs("/run", exist_ok=True)
        with open(LOG, "a") as f:
            f.write(line)
    except Exception:
        pass
    try:
        with open("/dev/kmsg", "w") as k:
            k.write(line)
    except Exception:
        pass


def status_text():
    parts = [
        "zl1 python status endpoint v44\n",
        time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()) + "\n",
        "--- cmdline ---\n", read_file("/proc/cmdline"),
        "--- uptime ---\n", read_file("/proc/uptime"),
        "--- proc net dev ---\n", read_file("/proc/net/dev"),
        "--- proc net route ---\n", read_file("/proc/net/route"),
        "--- proc net tcp ---\n", read_file("/proc/net/tcp"),
        "--- proc mounts ---\n", read_file("/proc/mounts", 65536),
        "--- debug net log ---\n", read_file(LOG, 65536),
        "--- debug init log ---\n", read_file("/run/zl1-debug-init.log", 65536),
        "--- lxc ready log ---\n", read_file("/run/zl1-lxc-ready.log", 65536),
        "--- lxc android log ---\n", read_file("/var/log/lxc/android.log", 65536),
        "--- status done ---\n",
    ]
    return "".join(parts)


def drain_request(conn):
    conn.settimeout(0.4)
    data = b""
    end = time.time() + 1.0
    while time.time() < end and len(data) < 4096:
        try:
            chunk = conn.recv(1024)
        except socket.timeout:
            break
        except Exception:
            break
        if not chunk:
            break
        data += chunk
        if b"\r\n\r\n" in data or b"\n\n" in data:
            break
    return data


def handle(conn, addr):
    try:
        append_log(f"client {addr} accepted")
        drain_request(conn)
        body = status_text().encode("utf-8", "replace")
        header = ("HTTP/1.0 200 OK\r\n"
                  "Content-Type: text/plain; charset=utf-8\r\n"
                  f"Content-Length: {len(body)}\r\n"
                  "Connection: close\r\n\r\n").encode("ascii")
        conn.settimeout(5.0)
        conn.sendall(header)
        conn.sendall(body)
        try:
            conn.shutdown(socket.SHUT_WR)
        except Exception:
            pass
        time.sleep(0.1)
        append_log(f"client {addr} sent {len(body)} bytes")
    except Exception as e:
        append_log(f"client {addr} error {type(e).__name__}: {e}")
    finally:
        try:
            conn.close()
        except Exception:
            pass


def serve(port):
    while True:
        s = None
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind(("0.0.0.0", port))
            s.listen(8)
            append_log(f"listening on 0.0.0.0:{port}")
            while True:
                conn, addr = s.accept()
                threading.Thread(target=handle, args=(conn, addr), daemon=True).start()
        except Exception as e:
            append_log(f"server port {port} restart after {type(e).__name__}: {e}")
            try:
                if s:
                    s.close()
            except Exception:
                pass
            time.sleep(1)


for port in PORTS:
    threading.Thread(target=serve, args=(port,), daemon=True).start()
while True:
    time.sleep(60)
EOF_ZL1_STATUS_SERVER
chmod 0755 "$ROOT/usr/local/sbin/zl1-status-server.py" 2>/dev/null || true

# V33 reached the post-switch 1209:0004 RNDIS gadget but the host saw no ARP
# replies from either 192.168.2.15 or 10.15.19.82. The one-shot pre-/post-switch
# ifconfig can lose its address when Ubuntu Touch re-creates the USB gadget, so
# install a tiny systemd/debug keeper that repeatedly re-adds both diagnostic IPs
# and restarts telnetd after gadget resets. Runtime/rootfs diagnostic only.
cat > "$ROOT/usr/local/sbin/zl1-debug-net.sh" <<'EOF_ZL1_DEBUG_NET'
#!/bin/sh
PATH=/usr/local/sbin:/sbin:/usr/sbin:/bin:/usr/bin:/tmp
BB=/usr/local/sbin/zl1-busybox
[ -x "$BB" ] || BB=/tmp/busybox
LOG=/run/zl1-debug-net.log
mkdir -p /run 2>/dev/null || true
log() {
    msg="zl1-debug-net: $*"
    echo "$msg" >> "$LOG" 2>/dev/null || true
    echo "$msg" > /dev/kmsg 2>/dev/null || true
}
ensure_ttys() {
    mkdir -p /dev/pts 2>/dev/null || true
    grep -q ' /dev/pts ' /proc/mounts 2>/dev/null || mount -t devpts devpts /dev/pts 2>/dev/null || true
    [ -e /dev/ptmx ] || mknod -m 666 /dev/ptmx c 5 2 2>/dev/null || true
    chmod 666 /dev/ptmx 2>/dev/null || true
}
have_listener() {
    port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | grep -Eq "[.:]$port[[:space:]]" && return 0
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | grep -Eq "[.:]$port[[:space:]]" && return 0
    fi
    hexport="$(printf '%04X' "$port" 2>/dev/null || true)"
    # /proc/net/tcp state 0A is LISTEN. Do not treat TIME_WAIT/CLOSE_WAIT from a
    # just-consumed status connection as a live listener, or the keeper will not
    # restart status telnetd after one-shot probes.
    if [ -n "$hexport" ] && awk -v p=":$hexport" 'NR>1 && index($2,p) && $4=="0A" {found=1} END{exit found?0:1}' /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
        return 0
    fi
    return 1
}
have_applet() {
    [ -x "$BB" ] || return 1
    "$BB" --list 2>/dev/null | grep -qx "$1"
}
write_http_status() {
    mkdir -p /run/zl1-http 2>/dev/null || true
    {
        echo "zl1 debug status"
        date 2>/dev/null || true
        echo "--- cmdline ---"
        cat /proc/cmdline 2>/dev/null || true
        echo "--- ip ---"
        ip -br addr show 2>/dev/null || ifconfig -a 2>/dev/null || true
        echo "--- listeners ---"
        ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null || true
        echo "--- debug net log ---"
        cat "$LOG" 2>/dev/null || true
        echo "--- debug init log ---"
        cat /run/zl1-debug-init.log 2>/dev/null || true
        echo "--- ps ---"
        ps wwax 2>/dev/null || ps 2>/dev/null || true
    } > /run/zl1-http/index.txt 2>/dev/null || true
}
debug_shell_enabled() {
    case " $(cat /proc/cmdline 2>/dev/null) " in
        *" zl1_debug_shell=1 "*) return 0 ;;
    esac
    return 1
}
process_alive() {
    pidfile="$1"
    [ -s "$pidfile" ] || return 1
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}
start_python_status() {
    # The initramfs busybox lacks nc/sh applets and its telnetd/httpd exit rc=1 in
    # this post-switch context, so V40-V42 never kept a listener open even though
    # RNDIS/ping were stable. The Ubuntu rootfs has /usr/bin/python3, which can bind
    # a plain TCP status server with no shell, no PTY and no busybox dependency.
    PY=""
    for cand in /usr/bin/python3 /bin/python3 /usr/local/bin/python3; do
        [ -x "$cand" ] && { PY="$cand"; break; }
    done
    [ -n "$PY" ] || { log "no rootfs python3 for status server"; return 1; }
    if process_alive /run/zl1-pystatus.pid; then
        return 0
    fi
    "$PY" /usr/local/sbin/zl1-status-server.py >>"$LOG" 2>&1 &
    echo "$!" > /run/zl1-pystatus.pid 2>/dev/null || true
    log "started python3 status server pid=$! ($PY) on 0.0.0.0:8081/8080"
    return 0
}
start_debug_servers() {
    ensure_ttys
    write_http_status
    # Primary, reliable status channel: rootfs python3 on 8081 and 8080.
    start_python_status || true
    if ! debug_shell_enabled; then
        return 0
    fi
    # Optional interactive shell only when explicitly requested. busybox telnetd -l
    # needs a shell; point it at the rootfs /bin/sh by absolute path.
    [ -x "$BB" ] || return 0
    if ! have_listener 23; then
        ( "$BB" telnetd -F -b 0.0.0.0:23 -l /bin/sh >>"$LOG" 2>&1; log "shell telnetd 23 exited rc=$?" ) &
        log "spawned shell telnetd 23 pid=$!"
    fi
}
add_addr() {
    ifname="$1"
    cidr="$2"
    addr="${cidr%/*}"
    if command -v ip >/dev/null 2>&1; then
        ip addr show dev "$ifname" 2>/dev/null | grep -q " $addr/" || ip addr add "$cidr" dev "$ifname" 2>/dev/null || true
    fi
}
configure_iface() {
    ifname="$1"
    [ -e "/sys/class/net/$ifname" ] || return 1
    if command -v ip >/dev/null 2>&1; then
        ip link set "$ifname" up 2>/dev/null || true
        add_addr "$ifname" 192.168.2.15/24
        add_addr "$ifname" 10.15.19.82/24
    elif [ -x "$BB" ]; then
        "$BB" ifconfig "$ifname" 192.168.2.15 netmask 255.255.255.0 up 2>/dev/null || true
        "$BB" ifconfig "${ifname}:1" 10.15.19.82 netmask 255.255.255.0 up 2>/dev/null || true
    else
        ifconfig "$ifname" 192.168.2.15 netmask 255.255.255.0 up 2>/dev/null || true
    fi
    if command -v arping >/dev/null 2>&1; then
        arping -q -c 1 -A -I "$ifname" 192.168.2.15 2>/dev/null || true
        arping -q -c 1 -A -I "$ifname" 10.15.19.82 2>/dev/null || true
    fi
    return 0
}
snapshot() {
    {
        echo "--- snapshot ---"
        date 2>/dev/null || true
        cat /proc/cmdline 2>/dev/null || true
        for ifname in usb0 rndis0; do
            [ -e "/sys/class/net/$ifname" ] || continue
            echo "iface=$ifname mac=$(cat /sys/class/net/$ifname/address 2>/dev/null) carrier=$(cat /sys/class/net/$ifname/carrier 2>/dev/null)"
        done
        ip -br addr show 2>/dev/null || ifconfig -a 2>/dev/null || true
        ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null || true
    } >> "$LOG" 2>&1 || true
}
log "keeper start"
i=0
while :; do
    configured=0
    configure_iface usb0 && configured=1
    configure_iface rndis0 && configured=1
    start_debug_servers
    if [ $((i % 10)) -eq 0 ]; then
        log "tick=$i configured=$configured"
        snapshot
    fi
    i=$((i + 1))
    sleep 1
done
EOF_ZL1_DEBUG_NET
chmod 0755 "$ROOT/usr/local/sbin/zl1-debug-net.sh" 2>/dev/null || true

cat > "$ROOT/etc/systemd/system/zl1-debug-net.service" <<'EOF_ZL1_DEBUG_NET_UNIT'
[Unit]
Description=zl1 temporary USB debug network keeper
DefaultDependencies=no
After=local-fs.target systemd-udevd.service
Before=basic.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/zl1-debug-net.sh
Restart=always
RestartSec=2

[Install]
WantedBy=sysinit.target multi-user.target
EOF_ZL1_DEBUG_NET_UNIT
chmod 0644 "$ROOT/etc/systemd/system/zl1-debug-net.service" 2>/dev/null || true
ln -sf ../zl1-debug-net.service "$ROOT/etc/systemd/system/sysinit.target.wants/zl1-debug-net.service" 2>/dev/null || true
ln -sf ../zl1-debug-net.service "$ROOT/etc/systemd/system/multi-user.target.wants/zl1-debug-net.service" 2>/dev/null || true
log "installed persistent debug network keeper"

cat > "$ROOT/tmp/zl1-lxc-pre-start.sh" <<'EOF_LXC_PRESTART'
#!/bin/sh
# Minimal Halium-9 LXC pre-start hook for zl1 diagnostics.
# Keep Android container dev paths that lxc.mount.entry expects, then let LXC
# mount the extracted Android ramdisk rootfs and Android /system image.
# Start each container attempt with fresh Android IPC/property directories. Stale
# files in /dev/__properties__ from a previous failed init make Android 9 abort
# with "Failed to initialize property area".
if mountpoint -q /dev/__properties__ 2>/dev/null; then
    umount /dev/__properties__ 2>/dev/null || true
fi
rm -rf /dev/__properties__ /dev/socket 2>/dev/null || true
mkdir -p /dev/__properties__ /dev/socket
mount -t tmpfs -o mode=0711 tmpfs /dev/__properties__ 2>/dev/null || true
chmod 0711 /dev/__properties__ 2>/dev/null || true
chmod 0755 /dev/socket 2>/dev/null || true

# Avoid LXC refusing safe_mount when the extracted Android ramdisk contains
# symlink placeholders for optional bind targets. These changes are made only in
# the tmpfs Android rootfs created for this boot.
if [ -n "$LXC_ROOTFS_PATH" ] && [ -d "$LXC_ROOTFS_PATH" ]; then
    for mount_name in vendor firmware odm; do
        target="$LXC_ROOTFS_PATH/$mount_name"
        [ -L "$target" ] && rm "$target" 2>/dev/null || true
        [ -d "$target" ] || mkdir -p "$target" 2>/dev/null || true
    done
fi

# The zl1 vendor init qsee listener wait is patched later in the LXC mount hook,
# after the vendor bind mount is visible. Pre-start only prepares the temporary
# Android ramdisk rootfs.

# Android 9 init aborts very early if /sys/fs/selinux/null is missing. In this
# AppArmor-booted Halium container there is no SELinuxFS. Patch every copy of
# that string in the extracted tmpfs Android init binary to a same-length regular
# file at the Android rootfs top level. This avoids depending on LXC /dev mount
# ordering. This is diagnostic only and does not modify phone partitions or the
# staged Android system image.
if [ -n "$LXC_ROOTFS_PATH" ] && [ -d "$LXC_ROOTFS_PATH" ]; then
    mkdir -p "$LXC_ROOTFS_PATH/dev" "$LXC_ROOTFS_PATH/dev/__properties__" "$LXC_ROOTFS_PATH/dev/socket" 2>/dev/null || true
    [ -e "$LXC_ROOTFS_PATH/dev/null" ] || mknod -m 666 "$LXC_ROOTFS_PATH/dev/null" c 1 3 2>/dev/null || true
    : > "$LXC_ROOTFS_PATH/selinux-null0000000" 2>/dev/null || true
    chmod 666 "$LXC_ROOTFS_PATH/selinux-null0000000" 2>/dev/null || true
    cat > "$LXC_ROOTFS_PATH/secilc-wrapper000" <<'EOF_SECILC_WRAPPER'
#!/system/bin/sh
# Diagnostic wrapper: Android init sees kernel policyvers=15 in this Halium LXC
# environment, but the Android 9 MLS policy cannot be written as policy version
# 15. Raise only the secilc -c argument and leave all other args unchanged.
args=""
replace_next=0
for arg in "$@"; do
    if [ "$replace_next" = 1 ]; then
        args="$args 30"
        replace_next=0
        continue
    fi
    args="$args $arg"
    if [ "$arg" = "-c" ]; then
        replace_next=1
    fi
done
echo "zl1-secilc-wrapper:$args" > /dev/kmsg 2>/dev/null || true
exec /system/bin/secilc $args
EOF_SECILC_WRAPPER
    chmod 755 "$LXC_ROOTFS_PATH/secilc-wrapper000" 2>/dev/null || true
fi
if [ -f "$LXC_ROOTFS_PATH/init" ]; then
    python3 - <<'PY_PATCH' "$LXC_ROOTFS_PATH/init" 2>/dev/null || true
import sys
from pathlib import Path
p = Path(sys.argv[1])
old = b'/sys/fs/selinux/null'
legacy = b'/dev/zl1-selinuxnul0'
devnull = b'/dev/null' + b'\0' * (len(old) - len(b'/dev/null'))
new = b'/selinux-null0000000'
secilc_old = b'/system/bin/secilc'
secilc_new = b'/secilc-wrapper000'
selinux_initialize_off = 0x1ada0
selinux_initialize_prologue = bytes.fromhex('fc6fbaa9')
selinux_initialize_ret = bytes.fromhex('c0035fd6')
boottime_getenv_add_off = 0x4ab4
boottime_getenv_selinux_took_add = bytes.fromhex('00100391')
boottime_getenv_started_at_add = bytes.fromhex('003c0191')
crash_signal_branch_off = 0xc6ec
crash_signal_branch_to_reboot = bytes.fromhex('60010054')
aarch64_nop = bytes.fromhex('1f2003d5')
init_aborter_branch_off = 0x6df0
init_aborter_branch_if_not_pid1 = bytes.fromhex('01020054')
init_aborter_branch_to_default_aborter = bytes.fromhex('10000014')
# Android 9 init on this kernel can parse properties but stalls because there is
# no real SELinux domain transition support in the AppArmor Halium container.
# These offsets are static-libselinux code copied into the zl1 Android /init
# binary. Replace the matched functions with "mov w0,#0; ret" so setexeccon,
# setcon-like helpers, restorecon, and setcontext calls become no-op success.
# This patch is applied only to the temporary extracted Android ramdisk rootfs.
static_selinux_ret0 = bytes.fromhex('00008052c0035fd6')
static_selinux_patch_sites = {
    'is_selinux_enabled_static': (0xb0930, bytes.fromhex('680a00f0087d44f9')),
    'setcon_like_1_static': (0xb22c0, bytes.fromhex('ffc300d1f44f01a9')),
    'setcon_like_2_static': (0xb2338, bytes.fromhex('ffc300d1f44f01a9')),
    'setcon_like_3_static': (0xb23b0, bytes.fromhex('ffc300d1f44f01a9')),
    'setfilecon_like_static': (0xb14a4, bytes.fromhex('ffc300d1f44f01a9')),
    'selinux_android_setcontext_static': (0xa9714, bytes.fromhex('ff8301d1f90b00f9')),
    'selinux_android_restorecon_wrapper_static': (0xb46f8, bytes.fromhex('e803012a02008012')),
}
# Android init's SocketConnection::source_context() constructs std::string from
# getpeercon() output without checking the return code. In this AppArmor-backed
# LXC there is no SELinux peer label on accepted AF_UNIX sockets, so getpeercon()
# can leave the output pointer NULL and property updates from any external client
# crash init. Patch static getpeercon() in the temporary /init to return
# u:r:init:s0 for all peers: adrp x2, <u:r:init:s0>; add x2, x2, #off;
# str x2, [x1]; mov w0,#0; ret. This is diagnostic only.
getpeercon_static_off = 0xb0dbc
getpeercon_static_expected = bytes.fromhex('ff0301d1f65701a9f44f02a9fd7b03a9fdc30091')
getpeercon_static_patch = bytes.fromhex('a20600f042cc1591220000f900008052c0035fd6')
# V32 proved getpeercon no longer returns NULL, but source_context() still calls
# freecon(source_context). Since getpeercon now points at the static literal
# u:r:init:s0, freecon() must also be no-op for this diagnostic boot; otherwise
# bionic's allocator crashes trying to free a non-heap address after property reads.
freecon_static_off = 0xacbdc
freecon_static_expected = bytes.fromhex('f1680214')
freecon_static_patch = bytes.fromhex('c0035fd6')
if len(old) != len(legacy) or len(old) != len(devnull) or len(old) != len(new):
    raise SystemExit('null replacement length mismatch')
if len(secilc_old) != len(secilc_new):
    raise SystemExit('secilc replacement length mismatch')
data = p.read_bytes()
old_before = data.count(old)
legacy_before = data.count(legacy)
devnull_before = data.count(devnull)
new_before = data.count(new)
secilc_old_before = data.count(secilc_old)
secilc_new_before = data.count(secilc_new)
selinux_skip_before = data[selinux_initialize_off:selinux_initialize_off + 4]
boottime_getenv_before = data[boottime_getenv_add_off:boottime_getenv_add_off + 4]
crash_signal_branch_before = data[crash_signal_branch_off:crash_signal_branch_off + 4]
init_aborter_branch_before = data[init_aborter_branch_off:init_aborter_branch_off + 4]
static_selinux_before = {name: data[off:off + len(static_selinux_ret0)] for name, (off, _expected) in static_selinux_patch_sites.items()}
getpeercon_static_before = data[getpeercon_static_off:getpeercon_static_off + len(getpeercon_static_patch)]
freecon_static_before = data[freecon_static_off:freecon_static_off + len(freecon_static_patch)]
changed = False
if old_before or legacy_before or devnull_before or secilc_old_before:
    data = data.replace(old, new).replace(legacy, new).replace(devnull, new).replace(secilc_old, secilc_new)
    changed = True
if selinux_skip_before == selinux_initialize_prologue:
    data = data[:selinux_initialize_off] + selinux_initialize_ret + data[selinux_initialize_off + 4:]
    changed = True
elif selinux_skip_before == selinux_initialize_ret:
    pass
else:
    raise SystemExit('SelinuxInitialize prologue mismatch at 0x1ada0: %s' % selinux_skip_before.hex())
if boottime_getenv_before == boottime_getenv_selinux_took_add:
    data = data[:boottime_getenv_add_off] + boottime_getenv_started_at_add + data[boottime_getenv_add_off + 4:]
    changed = True
elif boottime_getenv_before == boottime_getenv_started_at_add:
    pass
else:
    raise SystemExit('boottime getenv add mismatch at 0x4ab4: %s' % boottime_getenv_before.hex())
if crash_signal_branch_before == crash_signal_branch_to_reboot:
    data = data[:crash_signal_branch_off] + aarch64_nop + data[crash_signal_branch_off + 4:]
    changed = True
elif crash_signal_branch_before == aarch64_nop:
    pass
else:
    raise SystemExit('crash signal branch mismatch at 0xc6ec: %s' % crash_signal_branch_before.hex())
if init_aborter_branch_before == init_aborter_branch_if_not_pid1:
    data = data[:init_aborter_branch_off] + init_aborter_branch_to_default_aborter + data[init_aborter_branch_off + 4:]
    changed = True
elif init_aborter_branch_before == init_aborter_branch_to_default_aborter:
    pass
else:
    raise SystemExit('InitAborter branch mismatch at 0x6df0: %s' % init_aborter_branch_before.hex())
for name, (off, expected) in static_selinux_patch_sites.items():
    before = static_selinux_before[name]
    if before == expected:
        data = data[:off] + static_selinux_ret0 + data[off + len(static_selinux_ret0):]
        changed = True
    elif before == static_selinux_ret0:
        pass
    else:
        raise SystemExit('static SELinux patch mismatch for %s at 0x%x: %s' % (name, off, before.hex()))
if getpeercon_static_before.startswith(getpeercon_static_expected):
    data = data[:getpeercon_static_off] + getpeercon_static_patch + data[getpeercon_static_off + len(getpeercon_static_patch):]
    changed = True
elif getpeercon_static_before == getpeercon_static_patch:
    pass
else:
    raise SystemExit('static getpeercon patch mismatch at 0x%x: %s' % (getpeercon_static_off, getpeercon_static_before.hex()))
if freecon_static_before == freecon_static_expected:
    data = data[:freecon_static_off] + freecon_static_patch + data[freecon_static_off + len(freecon_static_patch):]
    changed = True
elif freecon_static_before == freecon_static_patch:
    pass
else:
    raise SystemExit('static freecon patch mismatch at 0x%x: %s' % (freecon_static_off, freecon_static_before.hex()))
if changed:
    p.write_bytes(data)
old_after = data.count(old)
legacy_after = data.count(legacy)
devnull_after = data.count(devnull)
new_after = data.count(new)
secilc_old_after = data.count(secilc_old)
secilc_new_after = data.count(secilc_new)
selinux_skip_after = data[selinux_initialize_off:selinux_initialize_off + 4]
boottime_getenv_after = data[boottime_getenv_add_off:boottime_getenv_add_off + 4]
crash_signal_branch_after = data[crash_signal_branch_off:crash_signal_branch_off + 4]
init_aborter_branch_after = data[init_aborter_branch_off:init_aborter_branch_off + 4]
static_selinux_after = {name: data[off:off + len(static_selinux_ret0)] for name, (off, _expected) in static_selinux_patch_sites.items()}
getpeercon_static_after = data[getpeercon_static_off:getpeercon_static_off + len(getpeercon_static_patch)]
freecon_static_after = data[freecon_static_off:freecon_static_off + len(freecon_static_patch)]
static_selinux_summary = ','.join('%s:%s->%s' % (name, static_selinux_before[name].hex(), static_selinux_after[name].hex()) for name in sorted(static_selinux_patch_sites))
try:
    with open('/dev/kmsg', 'wb', buffering=0) as kmsg:
        kmsg.write(('zl1-lxc-pre-start: init patch old_before=%d legacy_before=%d devnull_before=%d new_before=%d secilc_old_before=%d secilc_new_before=%d selinux_skip_before=%s boottime_before=%s crash_branch_before=%s aborter_branch_before=%s getpeercon_before=%s freecon_before=%s old_after=%d legacy_after=%d devnull_after=%d new_after=%d secilc_old_after=%d secilc_new_after=%d selinux_skip_after=%s boottime_after=%s crash_branch_after=%s aborter_branch_after=%s getpeercon_after=%s freecon_after=%s static_selinux=%s\n' % (old_before, legacy_before, devnull_before, new_before, secilc_old_before, secilc_new_before, selinux_skip_before.hex(), boottime_getenv_before.hex(), crash_signal_branch_before.hex(), init_aborter_branch_before.hex(), getpeercon_static_before.hex(), freecon_static_before.hex(), old_after, legacy_after, devnull_after, new_after, secilc_old_after, secilc_new_after, selinux_skip_after.hex(), boottime_getenv_after.hex(), crash_signal_branch_after.hex(), init_aborter_branch_after.hex(), getpeercon_static_after.hex(), freecon_static_after.hex(), static_selinux_summary)).encode())
except Exception:
    pass
PY_PATCH
fi
exit 0
EOF_LXC_PRESTART
chmod 0755 "$ROOT/tmp/zl1-lxc-pre-start.sh" 2>/dev/null || true

# Ubuntu Touch 24.04/Noble starts Android through systemd's
# lxc-android-config.service and its official pre-start.sh already runs
# /var/lib/lxc/android/pre-start.d snippets. Install the zl1 patch there when
# the directory exists, so Noble keeps the upstream pre-start.sh/config/mount
# hooks instead of the older debug bind-mount replacement path below.
if [ -d "$ROOT/var/lib/lxc/android/pre-start.d" ]; then
    cp "$ROOT/tmp/zl1-lxc-pre-start.sh" "$ROOT/var/lib/lxc/android/pre-start.d/90-zl1-debug-init-patch" 2>/dev/null \
        && chmod 0755 "$ROOT/var/lib/lxc/android/pre-start.d/90-zl1-debug-init-patch" 2>/dev/null \
        && log "installed Noble LXC pre-start.d zl1 init patch hook" \
        || log "failed to install Noble LXC pre-start.d hook"
else
    log "Noble LXC pre-start.d directory not present; keeping legacy /tmp fallback hook"
fi

cat > "$ROOT/tmp/zl1-debug-init" <<'EOF_DEBUG_INIT'
#!/bin/sh
# Temporary zl1 debug init wrapper installed by Halium initramfs.
export PATH=/tmp:/sbin:/usr/sbin:/bin:/usr/bin
BB=/tmp/busybox
log() { echo "zl1-debug-init: $*" >/dev/kmsg 2>/dev/null || true; }

log "entered post-switch-root debug init wrapper"

# The initramfs normally moves /proc, /sys, and /run before run-init. Be
# defensive in case a previous step changed that behavior.
grep -q ' /proc ' /proc/mounts 2>/dev/null || mount -t proc proc /proc 2>/dev/null || true
grep -q ' /sys ' /proc/mounts 2>/dev/null || mount -t sysfs sysfs /sys 2>/dev/null || true

mkdir -p /dev/__properties__ /dev/socket /run 2>/dev/null || true

# Ubuntu Touch 24.04/Noble starts Android from lxc-android-config.service and
# the official /var/lib/lxc/android/pre-start.sh runs pre-start.d snippets. If
# that hook directory exists, preserve the official config/pre-start/mount hooks
# and let /var/lib/lxc/android/pre-start.d/90-zl1-debug-init-patch run normally.
# The legacy bind-mount fallback below is kept only for old 16.04/upstart rootfs
# layouts that do not have pre-start.d.
if [ -d /var/lib/lxc/android/pre-start.d ]; then
    if [ -x /var/lib/lxc/android/pre-start.d/90-zl1-debug-init-patch ]; then
        log "using Noble LXC pre-start.d zl1 init patch hook"
    else
        log "Noble LXC pre-start.d exists but zl1 hook is missing or not executable"
    fi

    # Noble's stock config expects binderfs and its stock mount hook is not
    # idempotent if the Android tmpfs rootfs already has /socket from a previous
    # failed start. This 3.18 zl1 kernel exposes legacy binder nodes instead of
    # /dev/binderfs, so runtime-bind a generated config that preserves the Noble
    # pre-start/post-stop hooks but disables binderfs, adds the legacy binder
    # char devices, and points lxc.hook.mount at an idempotent generated hook.
    # Do not place this hook under /tmp or /run: Noble's tmp cleanup can remove
    # /tmp, and /run is mounted noexec, causing LXC mount hooks to fail with
    # "Permission denied". Store the hook under /var/lib/lxc/android instead.
    mount -o remount,rw / 2>/dev/null || true
    mkdir -p /run /var/log/lxc 2>/dev/null || true
    : > /var/log/lxc/android.log 2>/dev/null || true

    # Noble's /usr/lib/lxc-android-config/lxc-android-ready uses the Ubuntu-side
    # getprop helper in a tight loop after /dev/socket/property_service appears.
    # On the zl1 diagnostic boots that helper segfaults repeatedly, causing the
    # systemd ExecStartPost step to time out and kill an otherwise running Android
    # container. Install a bounded diagnostic ready wrapper that waits for the LXC
    # container and property socket, but deliberately avoids host getprop so the
    # foreground lxc-start process remains alive for inspection.
    if [ -x /usr/lib/lxc-android-config/lxc-android-ready ]; then
        [ -e /usr/lib/lxc-android-config/lxc-android-ready.orig-zl1 ] \
            || cp /usr/lib/lxc-android-config/lxc-android-ready /usr/lib/lxc-android-config/lxc-android-ready.orig-zl1 2>/dev/null \
            || true
        cat > /usr/lib/lxc-android-config/lxc-android-ready <<'EOF_ZL1_LXC_READY'
#!/bin/sh
PATH=/sbin:/usr/sbin:/bin:/usr/bin
LOG=/run/zl1-lxc-ready.log
mkdir -p /run 2>/dev/null || true
log() {
    msg="zl1-lxc-ready: $*"
    echo "$msg" >> "$LOG" 2>/dev/null || true
    echo "$msg" > /dev/kmsg 2>/dev/null || true
    echo "$msg" >&2
}
wait_for_path() {
    path="$1"
    label="$2"
    tries="$3"
    i=0
    while [ "$i" -lt "$tries" ]; do
        if [ -e "$path" ]; then
            log "$label present after $i ticks"
            return 0
        fi
        sleep 0.1
        i=$((i + 1))
    done
    log "$label not present after $tries ticks"
    return 1
}

log "wrapper start; avoiding Ubuntu-side getprop after observed segfault loop"
err="$(lxc-wait -n android -s RUNNING -t 30 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
    log "lxc-wait rc=$rc err=$err"
    # Return success for diagnostics; if lxc-start really exited, systemd will see
    # the main process exit separately. This avoids ExecStartPost killing LXC.
    exit 0
fi
log "lxc-wait observed RUNNING"

containerpid="$(lxc-info -n android -p -H 2>/dev/null || true)"
log "container pid=${containerpid:-missing}"
if [ -n "$containerpid" ] && [ -d "/proc/$containerpid/root" ]; then
    wait_for_path "/proc/$containerpid/root/dev/.coldboot_done" "android coldboot marker" 200 || true
else
    log "container root not visible; skipping coldboot wait"
fi
wait_for_path /dev/socket/property_service "host property_service socket" 200 || true
if [ -d /dev/__properties__ ]; then
    prop_count="$(find /dev/__properties__ -maxdepth 1 -type f 2>/dev/null | wc -l 2>/dev/null || echo unknown)"
    log "property area file count=$prop_count"
fi
log "exiting success so lxc-start stays available for diagnostics"
exit 0
EOF_ZL1_LXC_READY
        chmod 0755 /usr/lib/lxc-android-config/lxc-android-ready 2>/dev/null || true
        log "installed bounded Noble lxc-android-ready diagnostic wrapper"
    else
        log "Noble lxc-android-ready not found; cannot install ready wrapper"
    fi

    # Ubuntu Touch 24.04 ships host-side getprop/setprop helpers that talk to
    # Android's property service directly. On zl1 / Android 9 they send a
    # request pattern that Android init logs as "sys_prop: invalid command 2",
    # and the host helpers segfault. V20 proxied through lxc-attach, which made
    # reads work as root but caused user-namespace permission failures from some
    # systemd service contexts and made setprop hang. For this diagnostic image,
    # install no-attach stubs instead: return stable defaults for common reads,
    # honor getprop's default-value argument, and make writes a logged no-op
    # success. This isolates Android init/LXC progress from host helper crashes,
    # property-service protocol mismatches, and lxc-attach side effects.
    for tool_name in getprop setprop; do
        tool_path="/usr/bin/$tool_name"
        if [ -x "$tool_path" ]; then
            [ -e "${tool_path}.orig-zl1" ] \
                || cp "$tool_path" "${tool_path}.orig-zl1" 2>/dev/null \
                || true
            cat > "$tool_path" <<'EOF_ZL1_PROP_WRAPPER'
#!/bin/sh
PATH=/sbin:/usr/sbin:/bin:/usr/bin
TOOL_NAME="$(basename "$0")"
LOG=/run/zl1-prop-wrapper.log
mkdir -p /run 2>/dev/null || true
log() {
    msg="zl1-${TOOL_NAME}-wrapper: $*"
    echo "$msg" >> "$LOG" 2>/dev/null || true
    echo "$msg" > /dev/kmsg 2>/dev/null || true
}

if [ "$TOOL_NAME" = setprop ]; then
    log "no-attach diagnostic no-op setprop: $*"
    exit 0
fi

prop="${1:-}"
default="${2:-}"
case "$prop" in
    '')
        exit 0
        ;;
    ro.build.version.sdk)
        printf '%s\n' 28
        ;;
    ro.product.device|ro.product.vendor.device|ro.product.odm.device)
        printf '%s\n' le_zl1
        ;;
    ro.product.name|ro.product.vendor.name|ro.product.odm.name)
        printf '%s\n' ZL1_CN
        ;;
    ro.product.model|ro.product.vendor.model)
        printf '%s\n' 'LeEco Pro3'
        ;;
    ro.hardware|ro.boot.hardware)
        printf '%s\n' qcom
        ;;
    ro.treble.enabled)
        printf '%s\n' true
        ;;
    ro.vndk.version)
        printf '%s\n' 28
        ;;
    sys.boot_completed|dev.bootcomplete|service.bootanim.exit)
        # Android has not reached userspace boot completion in this diagnostic path.
        [ -n "$default" ] && printf '%s\n' "$default"
        ;;
    init.svc.*|vendor.*|persist.*|ctl.*|debug.*|test.*)
        [ -n "$default" ] && printf '%s\n' "$default"
        ;;
    *)
        [ -n "$default" ] && printf '%s\n' "$default"
        ;;
esac
exit 0
EOF_ZL1_PROP_WRAPPER
            chmod 0755 "$tool_path" 2>/dev/null || true
            log "installed ${tool_name} no-attach diagnostic stub"
        else
            log "$tool_path not found; cannot install ${tool_name} wrapper"
        fi
    done

    cat > /var/lib/lxc/android/zl1-mount-hook.sh <<'EOF_ZL1_LXC_MOUNT'
echo "zl1-lxc-mount-hook: start" > /dev/kmsg 2>/dev/null || true
mknod -m 666 "${LXC_ROOTFS_MOUNT}/dev/null" c 1 3 2>/dev/null || true
mknod -m 600 "${LXC_ROOTFS_MOUNT}/dev/kmsg" c 1 11 2>/dev/null || true
mknod -m 666 "${LXC_ROOTFS_MOUNT}/dev/random" c 1 8 2>/dev/null || true
mknod -m 666 "${LXC_ROOTFS_MOUNT}/dev/urandom" c 1 9 2>/dev/null || true
# The legacy 3.18 binder devices are bind-mounted from host devtmpfs. They can
# arrive as root:root 0600, which prevents Android system services and Ubuntu
# binder clients from opening hwbinder/vndbinder. Relax them for this diagnostic
# boot only; this changes runtime devtmpfs permissions, not phone partitions.
chmod 666 "${LXC_ROOTFS_MOUNT}/dev/binder" "${LXC_ROOTFS_MOUNT}/dev/hwbinder" "${LXC_ROOTFS_MOUNT}/dev/vndbinder" "${LXC_ROOTFS_MOUNT}/dev/ashmem" 2>/dev/null || true
chmod 440 "${LXC_ROOTFS_MOUNT}/proc/cmdline" 2>/dev/null || true
if [ -w "${LXC_ROOTFS_MOUNT}" ]; then
    [ -e "${LXC_ROOTFS_MOUNT}/socket" ] || [ -L "${LXC_ROOTFS_MOUNT}/socket" ] || ln -s /dev/socket "${LXC_ROOTFS_MOUNT}/socket" 2>/dev/null || true
fi
# V25/V29's exact remaining crash is Android init receiving a property update
# from /system/bin/hwservicemanager and immediately taking SIGSEGV in property
# handling. Renaming hwservicemanager.ready to another legal property name still
# crashes, so patch only the temporary mounted userspace view by bind-mounting a
# copied hwservicemanager binary whose property name string is changed to the
# same-length *invalid* diagnostic key "zlservicemanager/ready". Android property
# service should reject the slash-containing name before QueuePropertyChange(),
# testing whether suppressing this client property update lets init continue into
# later classes without touching phone system/vendor partitions.
hwsm_bin="${LXC_ROOTFS_MOUNT}/system/bin/hwservicemanager"
hwsm_exec_dir="/run/zl1-hwsm-exec"
hwsm_patch="${hwsm_exec_dir}/zl1-hwservicemanager"
: > /run/zl1-hwservicemanager-patch.log 2>/dev/null || true
mkdir -p "$hwsm_exec_dir" 2>/dev/null || true
if ! grep -qs " $hwsm_exec_dir " /proc/mounts 2>/dev/null; then
    mount -t tmpfs -o mode=755,exec,nosuid,nodev tmpfs "$hwsm_exec_dir" >>/run/zl1-hwservicemanager-patch.log 2>&1 \
        || mount -t tmpfs -o mode=755 tmpfs "$hwsm_exec_dir" >>/run/zl1-hwservicemanager-patch.log 2>&1 \
        || true
fi
rm -f "$hwsm_patch" 2>/dev/null || true
if [ -f "$hwsm_bin" ] && grep -qs " $hwsm_exec_dir " /proc/mounts 2>/dev/null; then
    grep " $hwsm_exec_dir " /proc/mounts >>/run/zl1-hwservicemanager-patch.log 2>/dev/null || true
    if cp "$hwsm_bin" "$hwsm_patch" 2>/dev/null \
        && python3 - <<'PY_ZL1_HWSM_PATCH' "$hwsm_patch" >>/run/zl1-hwservicemanager-patch.log 2>&1
import sys
from pathlib import Path
p = Path(sys.argv[1])
old = b'hwservicemanager.ready'
new = b'zlservicemanager/ready'
if len(old) != len(new):
    raise SystemExit('replacement length mismatch')
data = p.read_bytes()
old_count = data.count(old)
new_count = data.count(new)
if old_count < 1:
    if new_count >= 1:
        print(f'already-patched old_count={old_count} new_count={new_count}')
        raise SystemExit(0)
    raise SystemExit(f'property string not found old_count={old_count} new_count={new_count}')
data = data.replace(old, new)
p.write_bytes(data)
print(f'patched old_count={old_count} new_count_before={new_count} new_count_after={data.count(new)}')
PY_ZL1_HWSM_PATCH
    then
        chmod --reference="$hwsm_bin" "$hwsm_patch" 2>/dev/null || chmod 0755 "$hwsm_patch" 2>/dev/null || true
        if mount --bind "$hwsm_patch" "$hwsm_bin" 2>/dev/null; then
            echo "zl1-lxc-mount-hook: bind-patched hwservicemanager.ready -> invalid zlservicemanager/ready from exec tmpfs" > /dev/kmsg 2>/dev/null || true
        else
            echo "zl1-lxc-mount-hook: failed to bind-patch hwservicemanager binary from exec tmpfs" > /dev/kmsg 2>/dev/null || true
        fi
    else
        echo "zl1-lxc-mount-hook: hwservicemanager property-string patch failed from exec tmpfs" > /dev/kmsg 2>/dev/null || true
    fi
else
    echo "zl1-lxc-mount-hook: hwservicemanager binary not visible or exec tmpfs unavailable for property-string patch" > /dev/kmsg 2>/dev/null || true
fi
# V28 proves the original hwservicemanager.ready crash is bypassed, but init then
# dies shortly after qseecomd sends sys.listeners.registered=true. The qcom rc
# wait_for_prop for this key is already removed below, so rename qseecomd's emitted
# property to a same-length diagnostic key. This avoids the Android init property
# trigger path for sys.listeners.registered without touching vendor on disk.
qsee_bin="${LXC_ROOTFS_MOUNT}/vendor/bin/qseecomd"
qsee_patch="${hwsm_exec_dir}/zl1-qseecomd"
: > /run/zl1-qseecomd-patch.log 2>/dev/null || true
rm -f "$qsee_patch" 2>/dev/null || true
if [ -f "$qsee_bin" ] && grep -qs " $hwsm_exec_dir " /proc/mounts 2>/dev/null; then
    grep " $hwsm_exec_dir " /proc/mounts >>/run/zl1-qseecomd-patch.log 2>/dev/null || true
    if cp "$qsee_bin" "$qsee_patch" 2>/dev/null \
        && python3 - <<'PY_ZL1_QSEE_PATCH' "$qsee_patch" >>/run/zl1-qseecomd-patch.log 2>&1
import sys
from pathlib import Path
p = Path(sys.argv[1])
old = b'sys.listeners.registered'
new = b'zl1.listeners.registered'
if len(old) != len(new):
    raise SystemExit('replacement length mismatch')
data = p.read_bytes()
old_count = data.count(old)
new_count = data.count(new)
if old_count < 1:
    if new_count >= 1:
        print(f'already-patched old_count={old_count} new_count={new_count}')
        raise SystemExit(0)
    raise SystemExit(f'property string not found old_count={old_count} new_count={new_count}')
data = data.replace(old, new)
p.write_bytes(data)
print(f'patched old_count={old_count} new_count_before={new_count} new_count_after={data.count(new)}')
PY_ZL1_QSEE_PATCH
    then
        chmod --reference="$qsee_bin" "$qsee_patch" 2>/dev/null || chmod 0755 "$qsee_patch" 2>/dev/null || true
        if mount --bind "$qsee_patch" "$qsee_bin" 2>/dev/null; then
            echo "zl1-lxc-mount-hook: bind-patched qseecomd sys.listeners.registered -> zl1.listeners.registered" > /dev/kmsg 2>/dev/null || true
        else
            echo "zl1-lxc-mount-hook: failed to bind-patch qseecomd binary" > /dev/kmsg 2>/dev/null || true
        fi
    else
        echo "zl1-lxc-mount-hook: qseecomd property-string patch failed" > /dev/kmsg 2>/dev/null || true
    fi
else
    echo "zl1-lxc-mount-hook: qseecomd binary not visible or exec tmpfs unavailable for property-string patch" > /dev/kmsg 2>/dev/null || true
fi
# V30 proved that even an invalid slash-containing property name still crashes
# Android init after the property socket payload is received. That means init is
# dying before HandlePropertySet() can reject the name, most likely while building
# SocketConnection::source_context(): getpeercon() has no SELinux peer context in
# this Halium/AppArmor container and Android 9 init constructs std::string(NULL).
# For this diagnostic boot, block external libc property_set clients from reaching
# /dev/socket/property_service by bind-patching the temporary mounted bionic libc
# copies to connect to a same-length nonexistent socket path. Android init's own
# InitPropertySet path is static/internal and is unaffected. This is a runtime-only
# bind mount from exec tmpfs; it does not modify system/vendor on disk.
libc_prop_old="/dev/socket/property_service"
libc_prop_new="/dev/socket/property_servicf"
: > /run/zl1-libc-prop-socket-patch.log 2>/dev/null || true
for libc_rel in system/lib64/libc.so system/lib/libc.so; do
    libc_bin="${LXC_ROOTFS_MOUNT}/${libc_rel}"
    libc_tag=$(printf '%s' "$libc_rel" | tr '/.' '___')
    libc_patch="${hwsm_exec_dir}/zl1-${libc_tag}"
    rm -f "$libc_patch" 2>/dev/null || true
    if [ -f "$libc_bin" ] && grep -qs " $hwsm_exec_dir " /proc/mounts 2>/dev/null; then
        grep " $hwsm_exec_dir " /proc/mounts >>/run/zl1-libc-prop-socket-patch.log 2>/dev/null || true
        if cp "$libc_bin" "$libc_patch" 2>/dev/null \
            && python3 - <<'PY_ZL1_LIBC_PROP_PATCH' "$libc_patch" "$libc_rel" >>/run/zl1-libc-prop-socket-patch.log 2>&1
import sys
from pathlib import Path
p = Path(sys.argv[1])
rel = sys.argv[2]
old = b'/dev/socket/property_service'
new = b'/dev/socket/property_servicf'
if len(old) != len(new):
    raise SystemExit('replacement length mismatch')
data = p.read_bytes()
old_count = data.count(old)
new_count = data.count(new)
if old_count < 1:
    if new_count >= 1:
        print(f'{rel}: already-patched old_count={old_count} new_count={new_count}')
        raise SystemExit(0)
    raise SystemExit(f'{rel}: property socket string not found old_count={old_count} new_count={new_count}')
data = data.replace(old, new)
p.write_bytes(data)
print(f'{rel}: patched old_count={old_count} new_count_before={new_count} new_count_after={data.count(new)}')
PY_ZL1_LIBC_PROP_PATCH
        then
            chmod --reference="$libc_bin" "$libc_patch" 2>/dev/null || chmod 0644 "$libc_patch" 2>/dev/null || true
            if mount --bind "$libc_patch" "$libc_bin" 2>/dev/null; then
                echo "zl1-lxc-mount-hook: bind-patched $libc_rel property socket -> /dev/socket/property_servicf" > /dev/kmsg 2>/dev/null || true
            else
                echo "zl1-lxc-mount-hook: failed to bind-patch $libc_rel property socket" > /dev/kmsg 2>/dev/null || true
            fi
        else
            echo "zl1-lxc-mount-hook: $libc_rel property socket patch failed" > /dev/kmsg 2>/dev/null || true
        fi
    else
        echo "zl1-lxc-mount-hook: $libc_rel not visible or exec tmpfs unavailable for property socket patch" > /dev/kmsg 2>/dev/null || true
    fi
done
# Android init's automatic SELinux transition lookup fails in this AppArmor-backed
# Halium LXC environment because getcon() returns "unconfined" instead of an
# Android SELinux domain. Without an explicit service seclabel, every service start
# calls security_compute_create(unconfined, file_label, process), fails with
# "Could not get process context", and V24 eventually segfaults in init. For this
# diagnostic boot only, bind-patch the temporary mounted rc view so every service
# block has an explicit seclabel and therefore skips ComputeContextFromExecutable().
# The init binary's setexeccon-like libselinux helpers are already patched to no-op
# success in pre-start, so this does not require real SELinux domain transitions.
mkdir -p /run/zl1-rc-patches 2>/dev/null || true
python3 - <<'PY_ZL1_RC_SECLABEL' "${LXC_ROOTFS_MOUNT}" /run/zl1-rc-patches >/run/zl1-rc-seclabel.log 2>&1 || echo "zl1-lxc-mount-hook: rc seclabel patch script failed" > /dev/kmsg 2>/dev/null || true
import os, re, shutil, subprocess, sys
from pathlib import Path
root = Path(sys.argv[1])
patch_dir = Path(sys.argv[2])
service_re = re.compile(r'^(\s*)service\s+\S+\s+')
top_re = re.compile(r'^\S')
search_dirs = [root]
for rel in ('system/etc/init', 'system_ext/etc/init', 'vendor/etc/init', 'odm/etc/init', 'product/etc/init'):
    d = root / rel
    if d.is_dir():
        search_dirs.append(d)
candidates = []
seen = set()
for d in search_dirs:
    if d == root:
        try:
            entries = [p for p in d.iterdir() if p.is_file() and p.suffix == '.rc']
        except Exception:
            entries = []
    else:
        try:
            entries = [p for p in d.rglob('*.rc') if p.is_file()]
        except Exception:
            entries = []
    for p in entries:
        sp = str(p)
        if sp not in seen:
            seen.add(sp)
            candidates.append(p)
patched_files = 0
patched_services = 0
bind_ok = 0
for path in candidates:
    try:
        text = path.read_text(errors='surrogateescape')
    except Exception as e:
        print(f'skip-read {path}: {e}')
        continue
    lines = text.splitlines(True)
    out = []
    i = 0
    changed = False
    while i < len(lines):
        line = lines[i]
        m = service_re.match(line)
        if not m:
            out.append(line)
            i += 1
            continue
        block = [line]
        i += 1
        while i < len(lines):
            stripped = lines[i].strip()
            if top_re.match(lines[i]) and stripped and not stripped.startswith('#'):
                break
            block.append(lines[i])
            i += 1
        has_seclabel = any(re.match(r'^\s*seclabel\s+', b) for b in block[1:])
        out.append(block[0])
        if not has_seclabel:
            out.append(f'{m.group(1)}    seclabel u:r:init:s0\n')
            changed = True
            patched_services += 1
        out.extend(block[1:])
    if not changed:
        continue
    rel = str(path.relative_to(root)).replace('/', '__')
    patched = patch_dir / rel
    try:
        patched.write_text(''.join(out), errors='surrogateescape')
        shutil.copymode(path, patched)
    except Exception as e:
        print(f'skip-write {path}: {e}')
        continue
    patched_files += 1
    rc = subprocess.call(['mount', '--bind', str(patched), str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if rc == 0:
        bind_ok += 1
    else:
        print(f'bind-failed rc={rc} {patched} -> {path}')
print(f'zl1-rc-seclabel patched_files={patched_files} patched_services={patched_services} bind_ok={bind_ok} candidates={len(candidates)}')
try:
    with open('/dev/kmsg', 'w') as kmsg:
        kmsg.write(f'zl1-lxc-mount-hook: rc seclabel patched_files={patched_files} patched_services={patched_services} bind_ok={bind_ok} candidates={len(candidates)}\n')
except Exception:
    pass
PY_ZL1_RC_SECLABEL
# By the mount hook stage the vendor bind mount is visible. Patch the temporary
# mounted view of init.qcom.rc to skip the qsee listener wait that blocks Android
# init before post-fs-data/boot in this LXC environment. /var/lib/lxc/android is
# on the read-only Ubuntu rootfs here, so keep the copied file in /run tmpfs.
qcom_rc="${LXC_ROOTFS_MOUNT}/vendor/etc/init/hw/init.qcom.rc"
qcom_patch="/run/zl1-init.qcom.rc"
rm -f "$qcom_patch" 2>/dev/null || true
if [ -f "$qcom_rc" ]; then
    if cp "$qcom_rc" "$qcom_patch" 2>/dev/null \
        && sed -i '/^[[:space:]]*wait_for_prop[[:space:]]\+sys\.listeners\.registered[[:space:]]\+true[[:space:]]*$/d' "$qcom_patch" 2>/dev/null \
        && ! grep -q 'wait_for_prop sys.listeners.registered true' "$qcom_patch" 2>/dev/null \
        && mount --bind "$qcom_patch" "$qcom_rc" 2>/dev/null; then
        echo "zl1-lxc-mount-hook: bind-patched init.qcom.rc via /run to skip sys.listeners.registered wait" > /dev/kmsg 2>/dev/null || true
    else
        echo "zl1-lxc-mount-hook: failed to bind-patch init.qcom.rc wait_for_prop via /run" > /dev/kmsg 2>/dev/null || true
    fi
else
    echo "zl1-lxc-mount-hook: init.qcom.rc not visible for wait_for_prop patch" > /dev/kmsg 2>/dev/null || true
fi
echo "zl1-lxc-mount-hook: end" > /dev/kmsg 2>/dev/null || true
exit 0
EOF_ZL1_LXC_MOUNT
    chmod 0755 /var/lib/lxc/android/zl1-mount-hook.sh 2>/dev/null || true

    if [ -f /var/lib/lxc/android/config ]; then
        cp /var/lib/lxc/android/config /run/zl1-lxc-config-noble 2>/dev/null || true
        if [ -f /run/zl1-lxc-config-noble ]; then
            sed -i \
                -e 's@^lxc.hook.mount = .*@lxc.hook.mount = /var/lib/lxc/android/zl1-mount-hook.sh@' \
                -e 's@^lxc.log.level = .*@lxc.log.level = 3@' \
                -e 's@^# lxc.log.level = .*@lxc.log.level = 3@' \
                -e 's@^lxc.mount.entry = /dev/binderfs @# zl1-debug disabled missing binderfs: lxc.mount.entry = /dev/binderfs @' \
                -e '/# zl1-debug: legacy binder nodes for 3.18 kernel/d' \
                -e '/# zl1-debug: extra diagnostics/d' \
                -e '/^lxc.log.file = /d' \
                -e '/^lxc.mount.entry = \/dev\/binder dev\/binder /d' \
                -e '/^lxc.mount.entry = \/dev\/hwbinder dev\/hwbinder /d' \
                -e '/^lxc.mount.entry = \/dev\/vndbinder dev\/vndbinder /d' \
                -e '/^lxc.mount.entry = \/dev\/ashmem dev\/ashmem /d' \
                /run/zl1-lxc-config-noble 2>/dev/null || true
            if ! grep -q '^lxc.log.level = ' /run/zl1-lxc-config-noble 2>/dev/null; then
                printf '\nlxc.log.level = 3\n' >> /run/zl1-lxc-config-noble
            fi
            cat >> /run/zl1-lxc-config-noble <<'EOF_ZL1_LXC_CFG'
# zl1-debug: extra diagnostics
lxc.log.file = /var/log/lxc/android.log
# zl1-debug: legacy binder nodes for 3.18 kernel, no binderfs mountpoint
lxc.mount.entry = /dev/binder dev/binder bind bind,create=file,optional 0 0
lxc.mount.entry = /dev/hwbinder dev/hwbinder bind bind,create=file,optional 0 0
lxc.mount.entry = /dev/vndbinder dev/vndbinder bind bind,create=file,optional 0 0
lxc.mount.entry = /dev/ashmem dev/ashmem bind bind,create=file,optional 0 0
EOF_ZL1_LXC_CFG
            mount --bind /run/zl1-lxc-config-noble /var/lib/lxc/android/config 2>/dev/null \
                && log "runtime-bound Noble LXC config for legacy binder nodes and idempotent mount hook" \
                || log "failed to bind Noble LXC config patch"
        fi
    fi
else
    # Legacy Ubuntu Touch 16.04 path: the staged zl1 Android system image carries
    # /boot/android-ramdisk.img because the Halium initramfs needs it for
    # system-image mode. After switch-root that same file is visible as
    # /android/system/boot/android-ramdisk.img, which can make the stock hook
    # mis-detect this as a Halium <=7 layout. Runtime-bind a generated config and
    # minimal pre-start hook only for that old layout.
    if [ -f /var/lib/lxc/android/config ]; then
        cp /var/lib/lxc/android/config /run/zl1-lxc-config 2>/dev/null || true
        if [ -f /run/zl1-lxc-config ]; then
            sed -i \
                -e 's@^lxc.mount.entry = /dev/binderfs @# zl1-debug disabled: lxc.mount.entry = /dev/binderfs @' \
                -e 's@^lxc.mount.entry = /vendor @# zl1-debug disabled: lxc.mount.entry = /vendor @' \
                -e 's@^lxc.mount.entry = /firmware @# zl1-debug disabled: lxc.mount.entry = /firmware @' \
                -e 's@^lxc.mount.entry = /odm @# zl1-debug disabled: lxc.mount.entry = /odm @' \
                /run/zl1-lxc-config 2>/dev/null || true
            if ! grep -q '^lxc.mount.entry = /dev/null dev/null ' /run/zl1-lxc-config 2>/dev/null; then
                printf '\nlxc.mount.entry = /dev/null dev/null bind bind,create=file 0 0\n' >> /run/zl1-lxc-config
            fi
        fi
        mount --bind /run/zl1-lxc-config /var/lib/lxc/android/config 2>/dev/null \
            && log "runtime-bound legacy generated LXC config with dev-null bind and optional mounts disabled" \
            || log "failed to bind legacy generated LXC config"
    fi

    if [ -f /var/lib/lxc/android/pre-start.sh ] && [ -x /tmp/zl1-lxc-pre-start.sh ]; then
        mount --bind /tmp/zl1-lxc-pre-start.sh /var/lib/lxc/android/pre-start.sh 2>/dev/null \
            && log "runtime-bound legacy minimal Halium-9 LXC pre-start hook" \
            || log "failed to bind legacy minimal LXC pre-start hook"
    fi
fi

if [ -x /usr/local/sbin/zl1-debug-net.sh ]; then
    /usr/local/sbin/zl1-debug-net.sh >/dev/kmsg 2>&1 &
    log "started zl1 debug network keeper from init wrapper"
elif [ -x "$BB" ]; then
    "$BB" ifconfig rndis0 192.168.2.15 up 2>/dev/null || "$BB" ifconfig usb0 192.168.2.15 up 2>/dev/null || true
    "$BB" ifconfig usb0:1 10.15.19.82 up 2>/dev/null || "$BB" ifconfig rndis0:1 10.15.19.82 up 2>/dev/null || true
    case " $(cat /proc/cmdline 2>/dev/null) " in
        *" zl1_debug_shell=1 "*)
            "$BB" telnetd -p 23 -l /bin/sh >/dev/kmsg 2>&1 &
            "$BB" telnetd -p 2323 -l /bin/sh >/dev/kmsg 2>&1 &
            log "started fallback post-switch telnetd on 192.168.2.15:23/2323"
            ;;
        *)
            log "fallback telnetd disabled by default; set zl1_debug_shell=1 to enable"
            ;;
    esac
else
    log "missing $BB; cannot start post-switch debug server"
fi

# Leave breadcrumbs for offline inspection if rootfs.img is mounted later.
{
    date 2>/dev/null || true
    cat /proc/cmdline 2>/dev/null || true
    mount 2>/dev/null || true
} >/run/zl1-debug-init.log 2>&1 || true

init_delay=2
for arg in $(cat /proc/cmdline 2>/dev/null); do
    case "$arg" in
        zl1_init_delay=*) init_delay="${arg#zl1_init_delay=}" ;;
    esac
done
log "pre-systemd delay=${init_delay}; debug network should be reachable before /sbin/init"
if [ "$init_delay" = hold ]; then
    while :; do
        sleep 30
        log "holding before /sbin/init for diagnostics"
    done
else
    sleep "$init_delay" 2>/dev/null || sleep 2
fi
log "execing real /sbin/init"
exec /sbin/init "$@"
EOF_DEBUG_INIT
chmod 0755 "$ROOT/tmp/zl1-debug-init" 2>/dev/null || true
sync
mount -o remount,ro "$ROOT" 2>/dev/null || true
log "installed debug init wrapper"
exit 0
EOF
chmod +x "$RAMDISK_DIR/scripts/init-bottom/zl1-postswitch-debug-init"

LOCAL_PREMOUNT_ORDER="$RAMDISK_DIR/scripts/local-premount/ORDER"
touch "$LOCAL_PREMOUNT_ORDER"
if ! grep -q '/scripts/local-premount/zl1-usb-debug' "$LOCAL_PREMOUNT_ORDER"; then
  { printf '/scripts/local-premount/zl1-usb-debug "$@"\n'; cat "$LOCAL_PREMOUNT_ORDER"; } > "$LOCAL_PREMOUNT_ORDER.new"
  mv "$LOCAL_PREMOUNT_ORDER.new" "$LOCAL_PREMOUNT_ORDER"
fi

INIT_BOTTOM_ORDER="$RAMDISK_DIR/scripts/init-bottom/ORDER"
touch "$INIT_BOTTOM_ORDER"
if ! grep -q '/scripts/init-bottom/zl1-postswitch-debug-init' "$INIT_BOTTOM_ORDER"; then
  { cat "$INIT_BOTTOM_ORDER"; printf '/scripts/init-bottom/zl1-postswitch-debug-init "$@"\n'; } > "$INIT_BOTTOM_ORDER.new"
  mv "$INIT_BOTTOM_ORDER.new" "$INIT_BOTTOM_ORDER"
fi

NEW_INITRD="$WORK_DIR/initrd-postswitch-debug.img"
(
  cd "$RAMDISK_DIR"
  find . -print0 | cpio --null -o -H newc --owner=0:0 --quiet | gzip -9 > "$NEW_INITRD"
)

CMDLINE=$(extract_cmdline "$WORK_DIR/bootimg.cfg")
CMDLINE=$(python3 - "$CMDLINE" <<'PY'
import sys
cmd = sys.argv[1].split()
filtered = [x for x in cmd if not (x == 'break' or x.startswith('break=') or x.startswith('init='))]
filtered.append('init=/tmp/zl1-debug-init')
filtered.append('zl1_init_delay=hold')
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
printf '\nExpected endpoints:\n'
printf '  initramfs telnet:     192.168.2.15:23, early and temporary\n'
printf '  post-switch status:   http://192.168.2.15:8081/ or :8080 via rootfs python3\n'
printf '  post-switch status:   http://10.15.19.82:8081/ or :8080 via rootfs python3\n'
printf '  post-switch shell:    disabled unless cmdline has zl1_debug_shell=1\n'
printf '\nDo not flash this image unless separately reviewed and explicitly approved.\n'
