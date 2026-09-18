# 30 — 卡死的机制找到了：出方向的数据包在设备队列之前被丢掉

**日期**: 2026-09-17
**数据来源**: `/data/zl1-netwatch.log`（纯记录模式下没有，这一份是带治愈的 session，
但每一采样点的 `gadget_stats` / `ip -s -s` / ARP / 路由都是干净的）

---

## 1. 一次断点的前后对比

同一个 session，相隔 18.7 秒的两个采样：

```
uptime 42.50   RX 1160 B/19 p   TX 1418 B/19 p   drv_rcvd=19  qlen=0  throttle=0   host-ping: OK
uptime 61.22   RX 1412 B/22 p   TX 1712 B/22 p   drv_rcvd=22  qlen=0  throttle=0   host-ping: FAIL
```

同一份采样里还有：

```
6: rndis0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP qlen 1000
    link/ether 66:6a:1c:60:4c:2b
    TX: bytes 1712  packets 22  errors 0 dropped 0 carrier 0 collsns 0
    TX errors: aborted 0 fifo 0 window 0 heartbt 0 transns 2
rndis0  UP  192.168.2.15/24 10.15.19.100/24          <- 地址在
10.15.19.0/24 dev rndis0 scope link                  <- 路由在
192.168.2.100  0x1  0x2  66:6a:1c:60:4c:2b  *  rndis0 <- ARP 条目是 complete
```

**这 18.7 秒里 netwatch 打了约 7 次 ping（每 2–3 秒一次），而设备只发出去 3 个包。**

而所有计数器都是干净的：`tx_dropped=0`、`tx_errors=0`、`tx_qlen=0`、`tx_throttle=0`、
接口 `state UP`、MAC 没变、地址没丢、路由在、ARP 条目是**完整的**（`0x2`，有真实 MAC）。

## 2. 这个组合只能说明一件事

包从 socket 出发，通过了路由，邻居是解析好的，然后**消失了**：

- 没有进 u_ether 的队列（`tx_qlen=0`、`tx_pkts_rcvd` 不动）
- 没有被设备层丢弃（`tx_dropped=0`、`tx_errors=0`）
- 接口没有停（`state UP`，且 `tx_throttle=0` 说明 `netif_stop_queue` 从未被调用）

**在设备队列之前被丢掉的包，不会在任何 netdev 计数上留痕。**
那只有两个地方能干这事：**netfilter（iptables）**，或者**策略路由（`ip rule`）把包扔进了没有路由的表**。

## 3. 为什么指向 Android

三条独立线索都指向 Android 的 netd：

**其一：netd 和 Ubuntu 共用同一个网络命名空间。** LXC 配置里写着：

```
lxc.namespace.keep = net user
```

`keep` 意味着**不**新建 net namespace，即容器与宿主共享网络栈。
所以 Android 的网络配置会直接作用在 `rndis0` 所在的这套栈上。

**其二：内核日志里能看到 netd 起来了。**

```
[  735.109134] init: Created socket '/dev/socket/fwmarkd', mode 660, user 0, group 3003
[  735.855062] x_tables: ip_tables: owner match: used from hooks INPUT, but only valid from OUTPUT/POSTROUTING
```

`fwmarkd` 是 netd 的组件；`x_tables` 那两行是内核在抱怨 netd 装的 iptables 规则。
（那个 owner-match 警告本身是这类内核上的老问题，无害，但它是 netd 在装规则的**证据**。）

**其三：时间对得上。** 断点在 uptime 40–60 秒之间；容器就是那段时间起来的。
而早先那次**没有 `/data/system.img`、容器起不来**的开机，链路连续可用 **8 分钟以上**——
这条相关性我之前亲手否掉了（[`22`](22-stage2-coldboot-results.md) §5.4 说"样本太小，不下结论"），
**它是这三条里最有力的一条，我当时就该追下去。**

## 4. 这一步推翻掉的东西

| 说法 | 现状 |
| --- | --- |
| [`23`](23-uether-tx-wakeup-patch.md)："发送队列被停掉且无人唤醒" | **不成立**：`tx_throttle=0` 说明 `netif_stop_queue` 从未被调用，`tx_qlen=0` 说明队列是空的 |
| [`26`](26-gadget-reassert-every-2-minutes.md)："keeper 反复重建 gadget" | 已在 [`29`](29-correction-watchdog-not-keeper.md) 更正：是我自己的看门狗 |
| [`22`](22-stage2-coldboot-results.md) §5："TX 通路卡死" | 方向对，但**不是 USB 侧的问题**——包根本没到 USB 层 |
| "ARP 解析失败" | 不成立：ARP 条目是 complete 的 |

也就是说，`u_ether` 那个内核补丁（doc 23）**修的是一个真实存在但与本案无关的缺陷**，
而 USB/gadget 层面从头到尾都是好的。

## 5. 下一步要抓什么

需要设备上的这几个命令的输出（`netwatch` 已加进去，见下）：

```sh
ip rule show                  # 策略路由：有没有人把包引到空表
ip route show table all       # 所有表，不只是 main
ip route get 192.168.2.100    # 实际会走哪条规则/哪张表
iptables -t filter -L -n -v   # 有没有 DROP 在涨
```

`ip route get` 是关键——它会直接报出"这条包会走哪条规则、哪张表"，
一条命令就能区分"路由没问题"和"被策略路由带跑了"。
而 `iptables -L -v` 的**计数器**能区分"规则存在但没匹配"和"规则正在吃包"。

已经加进 `scripts/device/zl1-netwatch.sh`：在 **uptime 45 秒**（断点之前）、
**第一次判定卡死时**、以及 **uptime 120 秒**（断点之后）各抓一次快照。
45 秒和 120 秒那一对就是断点两侧的对照。

## 6. 还有一个不需要新仪表就能做的实验

既然"容器起来 → 链路就断"这条相关性现在有三条线索支撑，
那就直接做 A/B：

1. 在 TWRP 里把 `/data/system.img` 改名（容器起不来，和我 9 月 16 日那次状态一样）
2. 开机，`measure-link-stability.sh` 跑 10 分钟
3. 如果链路持续可用 → **确认是容器/Android 网络配置干的**
4. 改回来，再开机确认断点回来 → 闭环

这个实验可逆、不需要新代码、而且两侧都有基线可比
（有容器：可达 2–8%；无容器：8 分钟以上）。

脚本：`scripts/container-ab-test.sh`。

---

## 7. 后补：断点精确到 2.4 秒，而且是一条干净的转折

从 `2026-09-18` 那次 `heal=1` 的 29 MB 日志里（该样本的链路状态被治愈污染了，
但**每一采样点的计数器本身是干净的**），取出断点前后的逐点序列：

```
uptime   rx_pkts  tx_pkts  drv_rcvd  host-ping
   42      6816     8026       87      OK
   45      7404     8712       94      OK
   47      7740     9104       98      FAIL   <-- 断
   50      7908     9104       98      FAIL
   54      8160     9104       98      FAIL
   68      8916     9104       98      FAIL
   71      8972     9174       99      FAIL   <-- 漏出去 1 个包
   73      9140     9174       99      FAIL
   97      9896     9174       99      FAIL
```

三点：

1. **断点在 uptime 44.95 和 47.40 之间——只有 2.4 秒的窗口。** 不是渐变，是转折。
2. **断后 rx 一直在涨**（7740 → 9896），也就是主机的包**持续到达设备的 rndis0**；
   而 `tx_pkts` 和驱动侧 `tx_pkts_rcvd` 一起冻住。
3. **`drv_rcvd` 与 `tx_pkts` 完全相等**（99 = 99）——也就是说，凡是进到
   `eth_start_xmit` 的包都发出去了。**卡住的不是发送，是包压根没到发送函数。**

第 3 点是把范围锁死的关键：`eth_start_xmit` 是 netdev 的发送入口，
包要到达它必须经过 socket → 路由查找 → netfilter OUTPUT/POSTROUTING → qdisc。
而这一整段**掉了包不会动任何 netdev 计数器**——这正是我们看到的。

出问题的位置因此只剩两个：

| 可能 | 特征 | 怎么区分 |
| --- | --- | --- |
| **策略路由**：`ip rule` 把无 fwmark 的包导到没有 rndis0 路由的表 | 路由查找失败，包根本没被构造 | `ip route get 192.168.2.100` 会报 `Network is unreachable` 或指向别的表 |
| **netfilter**：iptables 规则 DROP | 包被构造了但被丢掉 | `iptables -L -v` 的**计数器**会涨 |

`netsnap` 的采样点（uptime 20/30/40/50/60/75/90/110/140/180）里，
**40 和 50 这一对正好夹住这个 2.4 秒的断点**，而且每次采样都记录了当时主机可达与否，
所以断点前后两份快照自带标签。

## 8. 顺带一个观察：断点和容器的关系

断点在 uptime ~46 秒。而容器第一次被 systemd 重启是在 ~65 秒
（[`33`](33-the-container-restart-loop.md)：`lxc-android-ready` 无超时等待
`/dev/.coldboot_done`，143 次重启 / 9362 秒 ≈ 65 秒一次）。

**46 秒早于第一次重启**，所以断点对应的是**容器第一次启动、Android init 往下走**的过程，
不是某次重启。这和"Android init 走到 netd 就装规则"的时序吻合——
但这是时序吻合，不是证据。证据要靠 §7 那两份快照。
