# 31 — 排查清单：已经排除的、和下一个要看的一个东西

**日期**: 2026-09-17
**为什么写**: 今天在同一个问题上换了七八个假设，其中好几个是可以在主机上花几分钟排除的。
这一篇把**已经排除的**和**依据**记下来，下次不用重做；最后是**唯一还需要设备的一次读数**。

---

## 1. 已排除（附依据）

| 假设 | 排除依据 |
| --- | --- |
| **ufw 防火墙** | rootfs 里 `ufw.service` 确实在 `multi-user.target.wants` 下，但 `/etc/ufw/ufw.conf` 是 **`ENABLED=no`**。`ufw-init start quiet` 尊重这个开关，不装规则。而且其默认策略是 `INPUT=DROP / OUTPUT=ACCEPT`——即使装了也放行出方向 |
| **waydroid 的网络脚本** | `/usr/lib/waydroid/data/scripts/waydroid-net.sh` 是 rootfs 里唯一同时动 iptables 和路由的 UT 侧脚本，但 waydroid 在 `/etc/systemd/system` 下**没有任何 unit**，不会运行 |
| **NetworkManager 的策略路由** | `rndis-static.nmconnection` / `usb0-static.nmconnection` 里**没有 `route-table=`**，所以 NM 不会建策略路由表；`method=manual` 且无网关，也不产生默认路由。这与设备上 `/proc/net/route` 只有两条 /24 路由一致 |
| **设备侧 ARP 条目陈旧** | 干净的那次 20 分钟观察里，主机 `usb0` 的 MAC 是 **`42:9b:9f:62:d4:8a`，302 个采样全程不变**。主机没有重新枚举，设备眼里的主机 MAC 不会失效 |
| **发送队列被停掉** | `tx_throttle=0`（`netif_stop_queue` 从未被调用）、`tx_qlen=0`（队列是空的）——[`23`](23-uether-tx-wakeup-patch.md) 的假设不成立 |
| **USB / gadget 层** | 接口 `state UP`、MAC 稳定、地址在、`tx_dropped=0`、`tx_errors=0`、ARP complete |
| **keeper 反复重建 gadget** | [`29`](29-correction-watchdog-not-keeper.md)：那是我自己的看门狗 |
| **设备重启** | [`29`](29-correction-watchdog-not-keeper.md)：那是我自己的 recovery marker；删掉后 18 分钟无重启 |
| **主机侧状态错乱** | [`22`](22-stage2-coldboot-results.md) §5.2d：五种手段无效，含真正的 USB 总线复位（`USBDEVFS_RESET`），且 dmesg 证明设备确实重新枚举了 |

## 2. 剩下的唯一嫌疑：Android 的 netd

三条证据：

1. **共用网络命名空间**：`/var/lib/lxc/android/config` 里 `lxc.namespace.keep = net user`
   ——`keep` 表示**不**新建 namespace，容器与宿主共用同一套网络栈
2. **netd 确实在跑**：`/etc/init/netd.rc` 起 `netd`，并创建 `fwmarkd` socket；
   内核日志里有 `Created socket '/dev/socket/fwmarkd'` 和 `x_tables: ip_tables: owner match ...`
3. **时间吻合**：断点在 uptime 40–60 秒，容器就是那时起来的；
   而唯一一次**容器起不来**的开机（缺 `/data/system.img`），链路连续可用 **8 分钟以上**

### Android 的网络栈为什么正好能干这事

Android 的网络不是"一条默认路由"那么简单，它是一整套**策略路由 + fwmark**：

- 多个路由表（`main`、`local_network`、`legacy_system`、按 netId 编号的表……）
- 大量 `ip rule` 条目按 socket 的 fwmark 选表
- socket 由 `netd` / `fwmarkd` 打标记，Linux 默认的 `main` 表查找被绕过

**Ubuntu Touch 侧发的包没有 fwmark。** 如果 netd 装了一组"只按 fwmark 选表"的规则，
且默认规则被挤到后面或指到了不含 rndis0 路由的表，那么 UT 的包就会**在路由查找阶段被丢掉**——
`ip_route_output` 返回不可达，包在到达设备队列之前就没了，
**这正好符合"所有 netdev 计数器都不动"的观察**。

而 `netd` 和它装的规则，是**容器起来的时候才出现的**。这解释了为什么每次开机的头 ~50 秒通、之后不通。

## 3. 唯一还需要设备的一次读数

不用新仪表、不用改镜像，四条命令：

```sh
ip rule show                    # 规则顺序 —— 有没有 non-main 规则排在默认查找之前
ip route get 192.168.2.100      # 直接问：这条包会走哪条规则、哪张表
ip route show table all         # 所有表，不只 main
iptables -t filter -L -n -v     # 计数器 —— 规则"存在"还是"正在吃包"
```

**`ip route get` 一条就能定案**：

- 输出 `... dev rndis0 src 192.168.2.15` → 路由是好的，问题在别处
- 输出 `Network is unreachable` 或指向别的表和设备 → **确认是策略路由**

`netwatch` 已经改成在 **uptime 20/30/40/50/60/75/90/110/140/180 秒**各抓一次这四组输出，
每次还记录"当时主机可达吗"。**十次采样跨过断点，无论断点具体落在哪一秒都能对上**，
而且每一份都自带标签——不需要猜哪一份在断点前。

（`netwatch` 跑在 `#!/bin/sh` 下，所以这份调度用的是 POSIX 写法，不是 bash 数组；
dash 和 busybox 都过。）

## 4. 不需要设备也能做的对照实验

`container-ab-test.sh`：在 TWRP 里把 `/data/system.img` 改名 → 容器起不来 → 开机测 10 分钟。
如果链路持续可用，就是容器干的。**可逆**（改回文件名即可），两侧都有现成基线：

| | 可达率 | 观测时长 |
| --- | --- | --- |
| 有容器 | 2–8% | 10–20 分钟 |
| 无容器（2026-09-16 那次） | 连续可用 8 分钟以上 | — |

## 5. 如果确认是 netd，可能的修法（先记着，不预先动手）

| 方案 | 代价 |
| --- | --- |
| 把 `lxc.namespace.keep` 里的 `net` 去掉，让容器用独立 netns | 容器的网络会变成孤岛，Android 侧联网功能全废；但 USB/RNDIS 归 UT 管，可能反而更干净 |
| 给 rndis0 的流量加一条高优先级的 `ip rule` / 打 fwmark | 治标，且要知道 netd 的规则形态才能写对 |
| 在容器起来后再施加一遍 UT 侧的网络配置 | 竞态，时序上不可靠 |

**先不设计。** 读一次 `ip rule show` 才知道该修哪一条。
