# 22 — Stage 2 结果（补）：Android 容器起来了，卡住的是主机侧

**日期**: 2026-09-17
**承接**: [`21-stage2-first-cold-boot.md`](21-stage2-first-cold-boot.md)
（那一篇记录的是**第一次**冷启动，当时容器没起来；原因是设备上缺 `/data/system.img`）

---

## 1. 结论

补上 `/data/system.img` 之后，**Ubuntu Touch 和 Android 容器同时跑起来了，而且是从
flash 进 boot 分区的镜像冷启动、连续跑了 20 分半**。

这一篇纠正 [`21-stage2-first-cold-boot.md`](21-stage2-first-cold-boot.md) 里
"容器没有起来"的结论——那是缺文件造成的，不是镜像或方法的问题。

## 2. 做了什么

```
scripts/stage2b-restore-android-system.sh --yes
```

- 镜像：`/mnt/data/halium-zl1-candidates/android-system-zl1-halium-candidate.img`
  4,294,967,296 字节，SHA256 `ec1d52fa…8142f8`
- 推到 `/data/system.img`（普通文件，不写任何分区）
- 设备端 `sha256sum` 复核：一致
- 推之前先在 TWRP 里确认过 `/data` 下确实只有 `rootfs.img`，没有 `system.img`

## 3. initramfs 这次走对了分支

对照第一次冷启动（[`21`](21-stage2-first-cold-boot.md) §4）：

| | 第一次（无 system.img） | 这次 |
| --- | --- | --- |
| `identify_android_image` | `unknown` | **`system`** |
| `/android` | 落在只读 rootfs 上 | **tmpfs** |
| `/android/system` | 没有 | **`/dev/loop1`** |
| `/android/data` `/android/cache` | 没有 | **`/dev/sda10` 的 bind mount** |
| `/usr/lib/udev/rules.d/70-android.rules` | 没有 | **`/dev/loop1`** |
| kmsg | `mkdir: ... Read-only file system` | **无此错误** |
| kmsg | — | `initrd: Android system image API level is 28` / `initrd: device is le_zl1` |

## 4. 容器确实在跑

设备端 monitor 日志（`/data/zl1-v63-monitor.log`，持久分区，跨启动累积）里最后一次
启动是从 `uptime 3.70 s` 到 `uptime 1230.54 s`：

```
1:systemd:/sbin/init
34342:lxc-start:/usr/bin/lxc-start -n android -F -- /system/bin/env -i
      PATH=/product/bin:/apex/com.android.runtime/bin:... INIT_SECOND_STAGE=true /init
36561:ueventd:/sbin/ueventd
36777:hwservicemanager:/system/bin/hwservicemanager
36778:qseecomd:/vendor/bin/qseecomd
40144:servicemanager:/system/bin/servicemanager
40150:vndservicemanag:/vendor/bin/vndservicemanager /dev/vndbinder
40159:android.hardwar:/vendor/bin/hw/android.hardware.keymaster@3.0-service
40532:allocator@1.0-s:/system/bin/hw/android.hidl.allocator@1.0-service
40536:android.hardwar:...bluetooth@1.0-service-qti
40537:android.hardwar:...camera.provider@2.4-service
40543:cas@1.0-service:/vendor/bin/hw/android.hardware.cas@1.0-service
40557:configstore@1.1:...configstore@1.1-service
40558:android.hardwar:...drm@1.0-service
40559:drm@1.1-service:...drm@1.1-service.clearkey
```

`lxc-ls` 的判据：

```
Name: android  State: RUNNING  PID: 34874  IP: 10.15.19.82  IP: 192.168.2.15  CPU use: 1542.37 seconds
```

最后一次启动里，`uptime > 1000` 的采样点是 **41 个 RUNNING、0 个 STOPPED**。

> 顺带一提：这里 `lxc-ls` 报的是 `RUNNING`，而 2026-06 那批记录里它报 `STOPPED`。
> 见 [`17-adaptation-plan.md`](17-adaptation-plan.md) §1.2——`STOPPED` 是假象，
> 但**不要反过来把 `RUNNING` 也当判据**，认进程表。

## 5. 网络是主机侧的问题，不是设备

设备端每个采样点都是：

```
state=CONFIGURED functions=rndis enable=1 product=zl1 V63 usbd-disabled RNDIS
rndis0(addr=...,carrier=1,op=up,idx=6)
```

从 tick=0（uptime 3.99 s）到 tick=175（uptime 1223.58 s），**carrier 一次没掉**。

但主机在冷启动后 30~120 秒就 ping 不通了，而且 `usb0` 的 MAC 没变、接口没消失、
`carrier=1`——**收包计数几乎为 0**。设备侧证据说设备是健康的，所以问题在主机。

这跟 [`17-adaptation-plan.md`](17-adaptation-plan.md) §1.6 和之前那条根因记录
（"35 秒断网是主机侧的假象"）是同一类问题。

### 5.1 已经确定的一个机制

v63 的 keeper 在启动最初会**反复重绑 USB gadget**：日志里 64 条
`reasserting android_usb RNDIS` 全部落在 `uptime 3.7 s ~ 4.1 s`。
每一次重绑对主机来说都是一次 USB 断开+重连，`usb0` 会被销毁重建、**MAC 变化、
地址丢失**。

所以一次性的 `ip addr add` 只有在"最后一次重绑之后"才有效——这正是冷启动验证
时灵时不灵的原因。为此加了
[`scripts/host-watch-usb0.sh`](../../scripts/host-watch-usb0.sh)：
持续盯着 `usb0`，一旦出现/换 MAC/掉地址就重新配置。

### 5.2 但 5.1 解释不了全部

2026-09-17 00:44 那次冷启动，watcher 全程只看到 **一次** `usb0` 出现
（`fe:d5:1f:6a:06:25`，00:44:55），配置后两个 IP 都 ping 通了；之后 MAC 没变、
接口没消失，**到 00:47 就不通了**。

所以除了 5.1，还有第二个（或同一个的另一种表现）主机侧问题没有定位。
下一步需要设备上的 shell 才能看清。

### 5.3 一条线索，不是结论

内核日志里反复出现

```
WARNING: CPU: 0 PID: <变> at .../net/core/skbuff.c:616 skb_release_head_state+0x74/0xdc()
```

对应源码是 `net/core/skbuff.c` 里的 `WARN_ON(in_irq())`——RNDIS 发送完成
（`tx_complete` → `kfree_skb`）在中断上下文里调用 socket destructor。
**这条警告在"能用的那 8 分钟"里同样出现过**（2026-09-16 20:0x 那次，uptime 83.49 s），
所以它不是断网的直接原因，更像是这版内核的老毛病。

## 6. Stage 2 验收对照（更新）

| 计划步骤 | 验收标准 | 结果 |
| --- | --- | --- |
| 2.1 回滚路径可用 | 备份 `boot.img` 校验通过 | ✅ |
| 2.2 flash + 冷启动 | 冷启动直接进入 V63 状态 | ✅ |
| 2.3 冷启动验收 | systemd PID1 / rndis0 up+carrier=1 / Android 容器存在 | ✅ **三项全过**（容器见 §4） |
| 2.4 连续 3 次冷启动复现 | 3/3 一致 | ⏳ 设备侧每次都成立；主机侧链路不稳，需 §5 修好后再判 |
| 2.5 失败回滚演练 | 刷坏镜像 → 回刷成功 | ⏳ |

## 7. 下一步：要一个设备上的 shell

设备只暴露 RNDIS，没有 adb；HTTP 状态页是只读的。要看清 §5.2，必须在设备上有个 shell。

v63 的 ramdisk 已经支持这个开关——`zl1_debug_shell=1` 会让它在调试 init 阶段
起一个 `busybox telnetd -l /bin/sh`（端口 23）。所以做了一张
**v63 + 这一个 cmdline 参数**的镜像：

```
/mnt/data/halium-zl1-candidates/halium-boot-zl1-v63-debug-shell.img
18,022,400 字节  SHA256 e89be201efc882156169d14d40878915b286de6af649d02511bc11629f6fde5c
```

内核和 ramdisk **一个字节都没动**，只是在 cmdline 的 512 字节字段尾部补了
` zl1_debug_shell=1`（该字段是 NUL 填充的，`ANDROID!` 头也没有校验和）。
生成脚本：[`scripts/make-zl1-debug-shell-boot.sh`](../../scripts/make-zl1-debug-shell-boot.sh)。

刷进去用 [`scripts/flash-boot-image.sh`](../../scripts/flash-boot-image.sh)，
它会拒绝任何不在 `/mnt/data/halium-zl1-candidates/SHA256SUMS` 里的镜像。

**拿到 shell 之后，后续每次重启都不用再按键了**——shell 里可以直接
`reboot` / `reboot recovery` / `reboot bootloader`。
