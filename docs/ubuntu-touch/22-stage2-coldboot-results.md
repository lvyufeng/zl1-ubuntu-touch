# 22 — Stage 2 结果（补）：Android 容器起来了，剩下的是设备发包通路卡死

**日期**: 2026-09-17
**承接**: [`21-stage2-first-cold-boot.md`](21-stage2-first-cold-boot.md)
（那一篇记录的是**第一次**冷启动，当时容器没起来；原因是设备上缺 `/data/system.img`）

---

## 1. 结论

补上 `/data/system.img` 之后，**Ubuntu Touch 和 Android 容器同时跑起来了，而且是从
flash 进 boot 分区的镜像冷启动、连续跑了 20 分半**。

这一篇纠正 [`21-stage2-first-cold-boot.md`](21-stage2-first-cold-boot.md) 里
"容器没有起来"的结论——那是缺文件造成的，不是镜像或方法的问题。

但"跑起来"≠"可用"：**设备的 RNDIS 发送通路在容器起来后约 30 秒卡死**
（见 §5）。这是 Stage 2 剩下的真问题。

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

## 5. 断链的真相：设备的 RNDIS **发送**通路卡死

> 这一节在 2026-09-17 做了**更正**。第一版写成"设备是健康的、问题在主机侧"，
> 那是照抄了 2026-06 的旧结论。设备端 `/proc/net/dev` 的计数器不这么说。

### 5.1 计数器说了什么

设备端 monitor 在每次采样时都记录 `/proc/net/dev`。以最后一次启动（uptime 3.70 → 1230.54 s）为例：

```
rndis0:  RX bytes / RX pkts        TX bytes / TX pkts
uptime ~  50 秒      6516 / 122            210500 / 155
uptime ~1200 秒     11088 / 228            210962 / 162
```

- **RX 一路涨到 228 包**，也就是主机发的包**一直都能到达设备的 rndis0**；
- **TX 卡在 162 包 / 210962 字节不动了**；
- 主机侧同时期 `usb0` 的 RX 几乎为 0。

再看包的尺寸：RX 增量 4572 字节 / 106 包 ≈ **43 字节/包**——正是 ARP 请求的大小。
所以主机一直在发 ARP 请求、设备一直收得到，**设备就是不回**。

那 210962 字节的 TX 是什么？一次 HTTP 状态页响应 = 200,022 字节。
**设备只成功发出过一次东西**（冷启动后约 30 秒我抓的那张状态页），之后再也发不出去。

### 5.2 结论

**设备的 RNDIS 发送通路在冷启动约 30 秒后卡死。** 不是主机的问题，
也不是"设备完全健康"。`carrier=1` / `operstate=up` 这两个 sysfs 读数
**不能反映数据通路是否还活着**——这正是 2026-06 那批记录得出错误结论的原因：
计划 §1.1 说的"v63 稳定 9 分钟"其实也只是这两个读数，
而同一份笔记里"Network reachable for 7 samples (~30s)"才是真实可用时间。

### 5.3 一个已确认的次要机制（主机侧，值得修但不是根因）

v63 的 keeper 在启动最初会**反复重绑 USB gadget**：日志里 64 条
`reasserting android_usb RNDIS` 全部落在 `uptime 3.7 s ~ 4.1 s`。
每次重绑对主机都是一次 USB 断开+重连，`usb0` 被销毁重建、**MAC 变化、地址丢失**。

所以一次性的 `ip addr add` 只有在"最后一次重绑之后"才有效——冷启动验证时灵时不灵
有这个成分。为此加了 [`scripts/host-watch-usb0.sh`](../../scripts/host-watch-usb0.sh)。
**但它解释不了 §5.2**：2026-09-17 00:44 那次，watcher 全程只看到一次 `usb0` 出现，
配置后两个 IP 都 ping 通，之后 MAC 没变、接口没消失，两分钟后照样不通。

### 5.4 和容器有没有关系

时间上高度相关：

| 冷启动 | 设备上有 `/data/system.img` | 设备侧 TX 可用多久 |
| --- | --- | --- |
| 2026-09-16 20:05（[`21`](21-stage2-first-cold-boot.md)） | ❌ 没有 → 容器起不来 | **8 分钟以上**（96 s / 363 s / 472 s 都取到了状态页） |
| 2026-09-16 20:23 起（本文） | ✅ 有 → 容器 RUNNING | **约 30 秒**（只成功过一次 HTTP） |

也就是说：**容器一起来，设备的发包通路就在半分钟内卡死。** 这是目前最强的线索，
但"容器如何导致它"还没有证据——需要设备上的 shell 或一个 pre-start 钩子来抓现场。

### 5.5 一条指向内核的线索（还不算结论）

内核日志里反复出现：

```
WARNING: CPU: 0 PID: <变> at .../net/core/skbuff.c:616 skb_release_head_state+0x74/0xdc()
```

对应 `net/core/skbuff.c` 里的 `WARN_ON(in_irq())`，调用栈是：

```
skb_release_head_state      net/core/skbuff.c:616
__kfree_skb / kfree_skb
tx_complete                 <-- RNDIS 的发送完成回调
usb_gadget_giveback_request
dwc3_gadget_giveback -> dwc3_endpoint_transfer_complete -> dwc3_interrupt
```

也就是**在中断上下文里释放带 socket destructor 的 skb**。
`tx_packets` 不涨、包却排在队列里出不去，和"发送完成路径出问题导致队列停摆"
是一致的——但目前只有相关性，没有直接证明。

下一步应该抓的现场：`ip -s -s link show rndis0`（看 `tx_queue` / dropped）、
`/sys/class/net/rndis0/statistics/*`、以及 Android 起来前后 rndis0 的
`ip addr` / `ip route` / `ip neigh` 快照。

## 6. Stage 2 验收对照（更新）

| 计划步骤 | 验收标准 | 结果 |
| --- | --- | --- |
| 2.1 回滚路径可用 | 备份 `boot.img` 校验通过 | ✅ |
| 2.2 flash + 冷启动 | 冷启动直接进入 V63 状态 | ✅ |
| 2.3 冷启动验收 | systemd PID1 / rndis0 up+carrier=1 / Android 容器存在 | ✅ **三项全过**（容器见 §4） |
| 2.4 连续 3 次冷启动复现 | 3/3 一致 | ⏳ 每次都起得来、容器每次都 RUNNING，但网络只活约 30 秒，见 §5 |
| 2.5 失败回滚演练 | 刷坏镜像 → 回刷成功 | ⏳ |

## 7. 下一步：要一个设备上的 shell

设备只暴露 RNDIS，没有 adb；HTTP 状态页是只读的，而且**只有约 30 秒的可用窗口**。
要在现场抓 §5 的证据，必须在设备上有个 shell。

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
