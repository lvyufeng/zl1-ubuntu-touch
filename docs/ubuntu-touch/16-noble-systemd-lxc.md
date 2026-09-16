# Ubuntu Touch 24.04 Noble Android LXC startup on zl1

This note records the Android container startup path found in the 24.04 / Noble `android9plus` rootfs image used for zl1 diagnostics.

Inspected rootfs artifact:

```text
/mnt/data/ubports-rootfs/24.04-2.x/rootfs-24.04-2.x-arm64-android9plus-zl1-host.img
```

## Key difference from 16.04

Ubuntu Touch 16.04 used upstart jobs for Android container startup. The 24.04 rootfs uses systemd, so the old debug strategy of replacing or patching an upstart job does not apply.

On 24.04, keep the official `lxc-android-config` service and hook scripts intact whenever possible. Use the existing `pre-start.d` extension point for zl1-specific diagnostics.

## systemd unit that starts Android

Primary unit inside the 24.04 rootfs:

```text
/lib/systemd/system/lxc-android-config.service
```

It is enabled from:

```text
/lib/systemd/system/sysinit.target.wants/lxc-android-config.service
```

Relevant directives:

```ini
[Unit]
Description=LXC Android Config and Container Initialization
DefaultDependencies=no
Wants=systemd-udevd.service systemd-udev-trigger.service
After=systemd-udevd-kernel.socket systemd-udevd-control.socket
Before=systemd-udev-trigger.service sysinit.target

Requires=mount-android-system.service mount-halium-overlay.service mount-android-partitions.service
After=mount-android-system.service mount-halium-overlay.service mount-android-partitions.service

[Service]
Type=exec
UMask=0000
ExecStart=/usr/libexec/lxc-android-config/start-android-container
ExecStartPost=/usr/lib/lxc-android-config/lxc-android-ready
ExecStop=/usr/bin/lxc-stop -n android -k
```

Generic `lxc.service` / `lxc@.service` units exist, but they are not the enabled Android startup path for this rootfs.

## Mount/setup units that run first

`lxc-android-config.service` depends on these services:

```text
/lib/systemd/system/mount-android-system.service
/lib/systemd/system/mount-halium-overlay.service
/lib/systemd/system/mount-android-partitions.service
```

Important behavior:

- `mount-android-system` searches for Android system/rootfs images, including userdata paths such as `/userdata/system.img` and `/userdata/android-rootfs.img`.
- `mount-halium-overlay` overlays Halium files from `/android/system/halium`, `/android/system/ubuntu`, `/opt/halium-overlay/`, or `/usr/share/halium-overlay/`.
- `mount-android-partitions` extracts `/android/system/boot/android-ramdisk.img` if present, then bind-mounts the assembled Android tree to `/var/lib/lxc/android/rootfs`.

## Actual launcher

The service runs:

```text
/usr/libexec/lxc-android-config/start-android-container
```

For Android 8/9 (`ro.build.version.sdk <= 28`), it starts the container with second-stage Android init enabled:

```sh
exec /usr/bin/lxc-start -n android -F -- \
    /system/bin/env -i \
        PATH=/product/bin:/apex/com.android.runtime/bin:/apex/com.android.art/bin:/sbin:/system/sbin:/system_ext/bin:/system/bin:/system/xbin:/odm/bin:/vendor/bin:/vendor/xbin \
        INIT_STARTED_AT=0 \
        INIT_SECOND_STAGE=true \
        /init
```

For zl1 / Android 9 this means Android init runs as:

```text
INIT_SECOND_STAGE=true /init
```

inside the LXC container.

## LXC config

Main config:

```text
/var/lib/lxc/android/config
```

Relevant directives:

```ini
lxc.rootfs.path = /var/lib/lxc/android/rootfs
lxc.net.0.type = none
lxc.namespace.keep = net user

lxc.hook.pre-start = /var/lib/lxc/android/pre-start.sh
lxc.hook.mount = /var/lib/lxc/android/mount.sh
lxc.hook.post-stop = /var/lib/lxc/android/post-stop.sh

lxc.apparmor.profile = unconfined
lxc.autodev = 0

lxc.mount.entry = tmpfs dev tmpfs nosuid,mode=0755 0 0
lxc.mount.entry = /dev/__properties__ dev/__properties__ bind bind,create=dir 0 0
lxc.mount.entry = /dev/binderfs dev/binderfs bind bind,create=dir,optional 0 0
lxc.mount.entry = /dev/socket dev/socket bind bind,create=dir 0 0
lxc.mount.entry = proc proc proc nodev,noexec,nosuid 0 0
lxc.mount.entry = sys sys sysfs nodev,noexec,nosuid 0 0
lxc.mount.entry = selinuxfs sys/fs/selinux selinuxfs optional 0 0
```

Unlike the older 16.04 diagnostic path, this config already has the needed `/dev/__properties__`, `/dev/socket`, `/dev/binderfs`, proc/sys, and optional selinuxfs entries. Do not replace it unless a new failure proves a config change is required.

## Official pre-start extension point

Top-level pre-start hook:

```text
/var/lib/lxc/android/pre-start.sh
```

Relevant behavior:

```sh
if [ -w $LXC_ROOTFS_PATH ]; then
    rm $LXC_ROOTFS_PATH/sbin/adbd

    sed -i "/mount_all /d" $LXC_ROOTFS_PATH/init.*.rc
    sed -i "/swapon_all /d" $LXC_ROOTFS_PATH/init.*.rc
    sed -i "/on nonencrypted/d" $LXC_ROOTFS_PATH/init.rc

    # Config snippet scripts
    run-parts /var/lib/lxc/android/pre-start.d || true
fi

mkdir -p /dev/__properties__ /dev/socket
```

This means the safest zl1 hook is a run-parts snippet:

```text
/var/lib/lxc/android/pre-start.d/90-zl1-debug-init-patch
```

That snippet runs after Android rootfs assembly but before `lxc-start` execs Android init. It can patch only the temporary/rbind Android rootfs view via `$LXC_ROOTFS_PATH`.

## Current zl1 debug implementation

The post-switch debug boot builder now installs the zl1 Android init patch as the Noble pre-start snippet when the directory exists:

```text
scripts/make-halium-postswitch-debug-boot.sh
```

Generated image:

```text
/mnt/data/halium-zl1-candidates/halium-boot-zl1-filtered-dtb-postswitch-debug-v15-noble-prestartd.img
Size:   17,993,728 bytes
SHA256: daef301af398f6751a9f4a930ce26854db161342b7f004150ce3874497cb80af
```

The generated boot image keeps these debug endpoints:

```text
initramfs telnet:   192.168.2.15:23
post-switch telnet: 192.168.2.15:2323
```

The Noble path intentionally preserves:

- `/var/lib/lxc/android/config`
- `/var/lib/lxc/android/pre-start.sh`
- `/var/lib/lxc/android/mount.sh`
- `/var/lib/lxc/android/post-stop.sh`
- `/usr/libexec/lxc-android-config/start-android-container`
- `lxc-android-config.service`

The older runtime bind-mount replacement of `pre-start.sh` and `config` remains only as a fallback for old 16.04/upstart rootfs layouts where `pre-start.d` does not exist.

## Next diagnostic command

Use only temporary boot for this diagnostic artifact:

```bash
fastboot boot /mnt/data/halium-zl1-candidates/halium-boot-zl1-filtered-dtb-postswitch-debug-v15-noble-prestartd.img
```

Do not flash this image unless separately reviewed and explicitly approved.

## Useful on-device checks after boot

From the post-switch telnet shell, check systemd and LXC state:

```sh
systemctl status lxc-android-config.service --no-pager
systemctl status mount-android-system.service mount-halium-overlay.service mount-android-partitions.service --no-pager
journalctl -b -u lxc-android-config.service --no-pager
journalctl -b -u mount-android-system.service -u mount-halium-overlay.service -u mount-android-partitions.service --no-pager
lxc-info -n android
lxc-ls -f
```

Check that the zl1 snippet was installed and whether it patched Android init:

```sh
ls -l /var/lib/lxc/android/pre-start.d/90-zl1-debug-init-patch
ls -l /var/lib/lxc/android/rootfs/init /var/lib/lxc/android/rootfs/selinux-null0000000 /var/lib/lxc/android/rootfs/secilc-wrapper000
dmesg | grep -Ei 'zl1|lxc|init:|selinux|secilc|property|binder|android' | tail -200
```
