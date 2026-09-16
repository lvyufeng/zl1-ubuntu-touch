# 21 — Stage 2 结果：持久化启动成功，Android 容器被设备状态卡住

**日期**: 2026-09-16
**镜像**: `halium-boot-zl1-v63-usbd-disabled.img`（SHA256 `ab574bd3…e57576`）
**方法**: `fastboot flash boot`（不是 `fastboot boot`）
**对应计划**: [`17-adaptation-plan.md`](17-adaptation-plan.md) Phase 2

---

## 1. 结论

**项目历史上第一次，zl1 从 flash 进 boot 分区的镜像冷启动进入了 Ubuntu Touch，
并且稳定运行。**

| 计划验收项 | 结果 |
| --- | --- |
| 2.2 `fastboot flash boot` + 冷启动 | ✅ 写入 17,600 KB，`OKAY [0.677s]`；复电后冷启动 |
| 2.3a systemd 作为 PID 1 | ✅ `1 ppid=0 systemd /sbin/init` |
| 2.3b `rndis0` up、`carrier=1` | ✅ uptime 87 s → 363 s 连续 71 个采样点，**0 次掉线** |
| 2.3c Android 容器进程存在 | ❌ **容器没有起来**，原因见 §4 |
| 2.4 连续 3 次冷启动复现 | ⏳ 见 §6 |

## 2. 冷启动现场

```
flash:  Sending 'boot' (17600 KB)  OKAY [ 0.501s]
        Writing 'boot'             OKAY [ 0.133s]
reboot -> 9 秒后主机看到 18d1:d001
host:   usb0 up, 192.168.2.100/24 + 10.15.19.100/24
        ping 192.168.2.15  OK
        ping 10.15.19.82   OK  (0.26 ms)
        curl http://10.15.19.82:8080/  -> 状态页
```

设备侧（冷启动后 6 分钟，uptime 363.55 s）：

```
PID 1        systemd | /sbin/init
ppid=1       systemd-journald, systemd-udevd, systemd-timesyncd,
             systemd-logind, dbus-daemon, lxc-monitord,
             sensorfwd, display-powersave-blocker
ppid=820     python3 /usr/local/sbin/zl1-status-server.py
rndis0       operstate=up  carrier=1
android_usb  state=CONFIGURED  functions=rndis  idVendor=18d1  idProduct=d001
             iProduct="zl1 V63 usbd-disabled RNDIS"
```

监控日志 `zl1-v63-monitor` 从 tick=0（uptime 3.78 s）跑到 tick=281（uptime 362.83 s），
每一个采样点都是 `pid1=[systemd|/sbin/init]` 且 `carrier=1,op=up`。

**这是 `fastboot boot` 从来给不了的东西**：一次写盘，之后每次上电都是这个状态。

原始证据见 [`evidence/`](evidence/)：

| 文件 | 内容 |
| --- | --- |
| `stage2-coldboot1-summary.txt` | 状态页关键段落 + 全部 71 个去重采样点 |
| `stage2-coldboot1-processes.txt` | 进程表 |
| `stage2-coldboot1-mounts.txt` | `/proc/mounts` |
| `stage2-coldboot1-initramfs.log` | 本次启动的 initramfs 日志（含错误） |
| `june-v63-working-initramfs.log` | 2026-06-13 那次可用启动的同一段日志，用于对照 |

## 3. 一个被推翻的猜测

刷之前怀疑过"`fastboot flash` 和 `fastboot boot` 会让设备走不同的代码路径"。
**没有这回事。** 两者用的是同一张镜像、同一条 cmdline，initramfs 也走了完全相同的分支。
唯一的差别是设备上的数据不一样，见下。

## 4. 容器没起来的真正原因：`/data/system.img` 不在了

initramfs 日志（[`evidence/stage2-coldboot1-initramfs.log`](evidence/stage2-coldboot1-initramfs.log)）：

```
[3.592628] cat: can't open '/root/var/lib/lxc/android/rootfs/fstab*': No such file or directory
[3.593587] mkdir: can't create directory '/root/android/cache': Read-only file system
[3.594326] mount: mounting /root/userdata/cache on /root/android/cache failed
[3.594820] ln: /root/android/vendor: Read-only file system
[3.595001] initrd: moving Android system to /android/system
[3.595571] mount: mounting /android-system on /root/android/system failed
```

对照 2026-06-13 那次可用的启动
（[`evidence/june-v63-working-initramfs.log`](evidence/june-v63-working-initramfs.log)）：

```
initrd: Halium rootfs is /tmpmnt/rootfs.img
initrd: mounting android system image (/tmpmnt/system.img) ro, in /android-system (system mode)
initrd: mounting android system image from userdata partition
initrd: extracting android ramdisk
initrd: Android system image API level is 28
initrd: device is le_zl1
```

推理链：

1. `scripts/halium` 的 `identify_android_image()` 只认三个位置：
   `/tmpmnt/system.img`（= `/data/system.img`）、`/tmpmnt/android-rootfs.img`、
   `/halium-system/var/lib/lxc/android/system.img`（rootfs 内部）。
2. 设备当前 `/data` 是空的——**没有 `system.img`**（在 TWRP 里 `ls -la /data/` 确认过），
   主机 rootfs 镜像的 `/var/lib/lxc/android/` 里也没有 `system.img`（已挂载核对）。
3. 于是 `ANDROID_IMAGE_MODE="unknown"`，两个分支都不走：
   - `ANDROID_IMAGE_MODE=system` 才会执行的 `mount -t tmpfs none ${rootmnt}/android` 没执行
     → `/android` 落在**只读**的 rootfs 上 → `mkdir /root/android/{data,system,cache}` 全部失败
   - `/android-system` 没挂上 → `mount --move` 失败
4. `/android` 不存在，UT rootfs 里的 `lxc-android-config` 就没有 Android 系统可挂，
   容器自然起不来。这也解释了为什么 `/var/lib/lxc/android/rootfs` 在
   `/proc/mounts` 里完全缺席。

**这不是镜像的问题，是设备数据的问题。** rootfs 是只读挂载的（`(user mode)`，
因为既没有 `/userdata/.writable_image` 也没有 `/halium-system/.writable_image`），
所以 initramfs 只能靠那个 tmpfs 来写 `/android`，而 tmpfs 又依赖 system.img 存在。

### 4.1 修复

把 `/data/system.img` 放回去即可，用的还是原来那份：

```
/mnt/data/halium-zl1-candidates/android-system-zl1-halium-candidate.img
4,294,967,296 字节  SHA256 ec1d52fa36b37893b840e30a60dbbda4a54b0058bf258ab1b1d20ba8508142f8
```

已核对它正是 initramfs 需要的东西：ext4、`ro.product.device=le_zl1`、
`ro.build.version.sdk=28`、并带 `/halium` overlay
（`halium/lib/udev/rules.d/70-android.rules` + `boot/android-ramdisk.img`），
与 June 日志里的 `API level is 28` / `device is le_zl1` 对得上。

推送方式就是 [`scripts/stage-halium-userdata-images-adb.sh`](../../scripts/stage-halium-userdata-images-adb.sh)：
把镜像作为普通文件放到 `/data/system.img`，不写任何分区。

## 5. 顺带查清的两件事

### 5.1 `/root` 不是持久化的，所以 SSH 公钥放在那里永远不会生效

[`SSH-FINAL-STATUS.md`](SSH-FINAL-STATUS.md) 记录了"把公钥放进 userdata 的
`/root/.ssh` 仍然 Permission denied"。现在原因明确了：
主机 rootfs 镜像的 `/etc/system-image/writable-paths` 里**没有 `/root`**，
所以 `/root` 就是只读 rootfs 自己那个目录，任何写进去的公钥都在重启后消失（或被忽略）。

而**`/etc/ssh` 是持久化的**（`/etc/ssh  auto  persistent`），运行时也确实是
`/dev/sda10` 的 bind mount。

sshd 的配置里 `AuthorizedKeysFile` 没设，走默认的 `.ssh/authorized_keys`。
**正确做法是下一版镜像里把 `AuthorizedKeysFile` 指到 `/etc/ssh/authorized_keys.d/%u`**，
那是个可写、可持久的位置。这样既不用改 rootfs 的 `writable-paths`，也不用碰 Android 侧。

### 5.2 设备上确实有 sshd 在跑

端口 22 在监听（OpenSSH 9.6p1 Ubuntu），但
`/etc/ssh/sshd_config.d/50-lxc-android-config.conf` 里 `PasswordAuthentication=no`，
只能公钥。公钥位置的问题见 5.1。

## 6. 下一步需要一次物理操作

设备现在**跑着 Ubuntu Touch**，刷新后的 boot 分区就是 v63。
USB gadget 只有 RNDIS，**没有 adb**（`functions=rndis`），
所以从主机上没有任何办法让它重启到 fastboot 或 recovery。

用户端的几个串口（`/dev/ttyUSB0/1`，Digilent FT2232）也试过了：
115200 收发都没有任何输出，不是这台手机的 console。

因此需要一次人工按键：

| 目标 | 操作 |
| --- | --- |
| **recovery (TWRP)** | 关机，然后**音量上 + 电源** |
| **fastboot** | 关机，然后**音量下 + 电源** |

推荐进 **TWRP**，因为接下来的动作是：

1. `adb push` 那份 4 GB 的 `android-system-zl1-halium-candidate.img` 到 `/data/system.img`
2. `adb reboot`，验证 v63 冷启动后 Android 容器是否起来（`pgrep -f lxc-start`）
3. 顺手把 SSH 修好（见 5.1），此后所有设备侧诊断都可以直接用 shell

**回滚路径始终可用**：进 fastboot 后
`scripts/stage2-rollback-boot.sh --yes` 能把原厂 `boot.img`（`a06d6508…`）刷回去。
设备现在能正常启动、能联网，不属于卡死状态。
