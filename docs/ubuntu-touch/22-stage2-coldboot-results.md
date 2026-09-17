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

## 5. 断链的真相：设备发包通路偶发卡死（不是每次都卡）

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

### 5.2 但它是**偶发**的——这一点很关键

设备端 monitor 日志（`/data/zl1-v63-monitor.log`，跨启动累积）一共记录了 64 次
monitor 启动，其中约 8 次有真实数据。把每次开机首尾的 `rndis0` 计数器列出来：

| 开机（日志行区间） | RX 首 → 尾 | TX 首 → 尾 | 结果 |
| --- | --- | --- | --- |
| 15 (12989–24153) | 0 → 24,570 B / 441 p | 0 → **792,449 B / 635 p** | 正常 |
| 23 (25018–36182) | 420 → 52,864 B / 821 p | 956 → **1,674,463 B / 1205 p** | 正常 |
| 31 (37045–44423) | 0 → 15,209 B / 222 p | 0 → 370,210 B / 294 p | 正常 |
| 39 (45286–56454) | 0 → 31,230 B / 483 p | 0 → **1,109,764 B / 797 p** | 正常 |
| 47 (57316–68481) | 508 → 10,600 B / 126 p | 1,054 → 327,877 B / 261 p | 正常 |
| 55 (69343–80512) | 348 → 3,030 B / 20 p | 886 → **4,029 B / 31 p** | **卡死** |
| 57 (80592–92275) | 496 → 53,786 B / 910 p | 398 → **1,935,263 B / 1360 p** | 正常 |
| 63 (92866–133353) | 6,516 → 11,088 B / 228 p | 210,500 → **210,962 B / 162 p** | **卡死** |

**8 次里有 6 次正常**，TX 能跑到 0.3–1.9 MB；只有 55 和 63 两次卡住。
而且 **55 卡死之后的 57 立刻就是好的**。

所以这不是"每次开机 30 秒后必卡"的系统性故障，而是**每次开机独立决定的偶发竞态**。
我这次运气不好，两次都撞上了（第一次是 63，第二次刷完 debug-shell 镜像后又是同类）。

这也意味着 **Stage 2.4 的"连续 3 次冷启动"是做得到的**——需要的是重试，不是修内核。

### 5.2b 那为什么计数器看起来"卡死"

`rndis0` 的 `tx_bytes` / `tx_packets` 只在 **`tx_complete`**（USB 发送完成回调）里累加
（`u_ether.c` 的 `tx_complete`）。所以 TX 计数不动，严格说只能证明
**"没有完成事件"**，不能证明"没有发包"。

但主机侧同时期 `usb0` 的 RX 只有 2 个包，所以包确实没出去——不是计数口径问题。

### 5.2c 代码里有一处注释正好描述了这个现象

`u_ether.c` 的聚合发送路径里（`eth_start_xmit` → `multi_pkt_xfer` 分支）有一段：

```c
if (dev->tx_skb_hold_count < dev->dl_max_pkts_per_xfer) {
    /*
     * should allow aggregation only, if the number of
     * requests queued more than the tx requests that can
     *  be queued with no interrupt flag set sequentially.
     * Otherwise, packets may be blocked forever.
     */
    if (dev->no_tx_req_used > MAX_TX_REQ_WITH_NO_INT) {
        list_add(&req->list, &dev->tx_reqs);
        spin_unlock_irqrestore(&dev->req_lock, flags);
        goto success;
    }
}
```

（`MAX_TX_REQ_WITH_NO_INT = 5`）

而 `netif_wake_queue()` 在整条发送路径里**只有 `tx_complete` 一处会调用**。
也就是说：只要有一次完成事件丢了，发送队列就永久停在 stop 状态。
`goto success` 这条提前返回的分支不排队、不唤醒——注释里的
"packets may be blocked forever" 就是我们的症状。

这条路径需要 `multi_pkt_xfer` 且走 `tx_reqs` 池；**是不是它，要靠 §5.4 的现场证据判定**，
现在只有代码层面的吻合，不算证明。

### 5.2d 主机侧能做的都试过了：USB 总线复位也不行

在主机上对这个 gadget 发了一次**真正的 USB 总线复位**（`USBDEVFS_RESET` ioctl 直接打到
`/dev/bus/usb/003/012`；`usbreset(1)` 工具不行，它没法在总线上两个 `18d1` 设备里选对）。

dmesg 证明复位确实发生了，而且**设备侧真的重新绑定了 gadget**：

```
[1676676.813446] usb 3-3: reset high-speed USB device number 12 using xhci_hcd
[1676676.964589] rndis_host 3-3:1.0 usb0: register 'rndis_host' ... c2:18:4b:33:2f:1b
```

主机侧看到的 host MAC 变了（前一次是 `6a:53:29:85:64:07`），说明设备重新生成了它那份随机
host MAC——也就是设备的 gadget 栈确实走了一遍 disconnect/connect。

**链路仍然是死的。** 这个否定结果很有信息量：

1. 排除了"主机侧状态错乱"这个解释。主机侧能试的五种手段**全部无效**：

   | 手段 | 结果 |
   | --- | --- |
   | `modprobe -r rndis_host` + 重新 `modprobe` | usb0 重新注册，链路依旧不通 |
   | `/sys/bus/usb/devices/3-3/{unbind,bind}`（绑到 usb 驱动再绑回） | 同上 |
   | `authorized` 0 → 1 | 同上（设备侧 host MAC 变了，说明确实重新绑定了 gadget） |
   | `USBDEVFS_RESET`（真正的总线复位） | 同上，见上面 dmesg |
   | runtime PM suspend/resume | **做不到**：`runtime_status=active` 恒定，usbnet 一直持有引用，自动挂起不会触发 |
2. 把故障范围缩小了：一次全新的 `gether_connect` 都救不回来，说明**能被重新枚举清掉的
   东西不是病因**。
3. 能在重新枚举后存活下来的，是挂在 **net_device** 上的状态——而 `u_ether` 在
   `gether_disconnect` / `gether_connect` 之间**不会重建 net_device**，
   所以 `netif_stop_queue` 停掉的发送队列会一直留着。

也就是说 §5.2c 的假设没被推翻，反而更贴了。而且这也说明**设备侧看门狗的第二级治愈
（unbind/rebind 函数 → 释放并重建 netdev）比主机上任何手段都强**，是唯一还没试过的一招。

### 5.3 结论（更正）

**设备偶尔会卡在"收得到、发不出"的状态。** 发生率约 1/4 次开机；
一旦发生，本次开机内不会自愈（发送队列停在 stop 状态，没有东西再去唤醒它）。
`carrier=1` / `operstate=up` 这两个 sysfs 读数**不能反映数据通路是否还活着**——
2026-06 那批记录正是只看这两个读数，才把"偶发卡死"记成了"稳定 9 分钟"。

### 5.3b 一个已确认的次要机制（主机侧，值得修但不是根因）

v63 的 keeper 在启动最初会**反复重绑 USB gadget**：日志里 64 条
`reasserting android_usb RNDIS` 全部落在 `uptime 3.7 s ~ 4.1 s`。
每次重绑对主机都是一次 USB 断开+重连，`usb0` 被销毁重建、**MAC 变化、地址丢失**。

所以一次性的 `ip addr add` 只有在"最后一次重绑之后"才有效——冷启动验证时灵时不灵
有这个成分。为此加了 [`scripts/host-watch-usb0.sh`](../../scripts/host-watch-usb0.sh)。
**但它解释不了 §5.2**：2026-09-17 00:44 那次，watcher 全程只看到一次 `usb0` 出现，
配置后两个 IP 都 ping 通，之后 MAC 没变、接口没消失，两分钟后照样不通。

### 5.4 和容器有没有关系（相关，但样本太小）

时间上高度相关：

| 冷启动 | 设备上有 `/data/system.img` | 设备侧 TX 可用多久 |
| --- | --- | --- |
| 2026-09-16 20:05（[`21`](21-stage2-first-cold-boot.md)） | ❌ 没有 → 容器起不来 | **8 分钟以上**（96 s / 363 s / 472 s 都取到了状态页） |
| 2026-09-16 20:23 起（本文） | ✅ 有 → 容器 RUNNING | **约 30 秒**（只成功过一次 HTTP） |

单看这两次是这样；但把 §5.2 的历史数据摆进来，**"容器一起来就卡死"这个相关性就站不住了**——
§5.2 里那些正常的开机（15/23/31/39/47/57）容器未必都没起来，而 55 那次卡死也未必有容器。
样本太小，这里不下结论。真正要判"容器是不是诱因"，得靠 §5.5 的现场证据。

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
| 2.4 连续 3 次冷启动复现 | 3/3 一致 | ⏳ 每次都起得来、容器每次都在；网络 **6/8 次正常**（§5.2），偶发卡死约 1/4。需要重试 + 抓现场 |
| 2.5 失败回滚演练 | 刷坏镜像 → 回刷成功 | ⏳ |

## 7. 下一步：设备侧看门狗（记录 + 自愈）

设备只暴露 RNDIS、没有 adb，状态页是只读的，而且卡死时连状态页都取不到。
所以现场只能靠设备自己记下来——并且既然卡死不会自愈，就得让设备自己治。

`scripts/device/zl1-netwatch.sh` 一个服务干两件事：

**记录**：每 2 秒把下面这些追加进 `/userdata/zl1-netwatch.log`（持久分区，跨启动保留）：

- **`/sys/kernel/debug/rndis/status`** —— `u_ether.c` 自己的计数器：
  `tx_pkts_rcvd`（交给 `eth_start_xmit` 的包数）、`tx_qlen`（还堆在 `tx_skb_q` 里的）、
  `tx_throttle`（`netif_stop_queue` 被调用的次数）、聚合直方图
- `/proc/net/dev` 的 `rndis0` 收发计数
- `ip -s -s link show rndis0`（qdisc / 队列 / drop）
- 地址、路由、ARP 表
- `lxc-start` 在不在、能不能 ping 通主机

`tx_pkts_rcvd` 是关键：如果它一直涨而 `tx_qlen` 也一直涨、主机却收不到任何东西，
那就是"唤醒丢了"（§5.2c）。这一条能直接判定，不需要再靠猜。

**自愈**：当 `tx_packets` 连续 45 秒不动（且 `uptime > 90` 秒，避免把启动过程误判成卡死），
**按两级升级**：

- **A 级**：`enable=0` → `enable=1`，整条 USB 链路重新枚举，端点复位，netdev 保留
- **B 级**：解绑再重绑 rndis 函数，**释放并重建 netdev**——按 §5.2d 的结论，
  这是唯一能清掉"挂在 net_device 上的停摆状态"的手段，比主机上任何操作都强

每次开机第一次治愈走 A，之后走 B。两级之后都**重新配上设备侧地址**
（`192.168.2.15/24` + `10.15.19.82/24`）——B 级会毁掉 netdev，它重新出现时是没有地址的，
不补上就算链路修好了主机也照样够不着。

安全性：

- 每次开机最多自愈 8 次，每次自愈后等 25 秒再判断
- 自愈后**检查 `enable` 是否回到 1**，没回到就强行写回——这是唯一可能让设备失联的
  环节，所以单独兜底
- 只写 `/sys/class/android_usb/android0/*` 和它自己的日志，**不碰任何分区**
- 需要只记录不自愈时：`install-netwatch-service.sh --yes --noheal`
  （自愈会破坏"复现卡死"的实验，所以这个开关是必要的）

安装方式**不动 rootfs、不动 ramdisk、不写分区**：rootfs 的 `/etc/systemd/system`
本身是一个 `writable-path`，运行时 bind mount 自 `/userdata/system-data/etc/systemd`，
在 TWRP 里就是 `/data/system-data/etc/systemd`。把 unit 放进去就是持久的。
安装脚本顺便备份 `misc`（2026-06-07 那批备份里没有它）。

**一次按键之后就不用再按了**：同一脚本可以在 `uptime` 超过设定值后往 `misc` 写
`boot-recovery`（就是 Android `reboot recovery` 的做法）并要求 bootloader 进 recovery，
于是"开机 → 记录 → 自愈 → 自动回 TWRP → 读日志"变成闭环。
开关是 `/data/zl1-netwatch-reboot-recovery` 文件，不存在就完全不做这件事。

### 7.1 顺带采集 Phase 5 需要的硬件证据

同一次开机里，`uptime > 120s` 时还会做一次**一次性硬件快照**写进同一个日志：

- framebuffer：`/proc/fb`、`/sys/class/graphics/*/{name,state,virtual_size,bits_per_pixel,blank}`
- DRM 连接器状态 `/sys/class/drm/*/status`
- 背光 `/sys/class/backlight/*`
- 输入设备 `/proc/bus/input/devices`（名字、handler、能力位），以及 `evtest` 在不在
- 声卡 `/proc/asound/cards`、IIO 设备、thermal zone、电池、已加载模块

这样"显示"和"触摸"这两项 Phase 5 验收就不需要各自单独占一次开机——
设备回来后一次读数就能判断 framebuffer 有没有内容、触摸设备有没有被注册。
`read-netwatch-log.sh` 会把这段单独打出来。

一键设置：`scripts/twrp-one-shot-setup.sh`（后台等待 TWRP，然后自动装服务、写 marker、重启）。
