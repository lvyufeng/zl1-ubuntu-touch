# 35 — 根因：Android 的一条 `unreachable` 策略路由规则

**日期**: 2026-09-19
**状态**: 机制已定位并修好；§4 有一句话在 2026-09-21 被
[`37`](37-the-trial-that-had-no-peer.md) 更正（见下）

> **2026-09-21 更正**：§4 说"这条修复必须反复施加"，因为 netd 会重装规则。
> 14.7 小时的真机日志显示 **netd 没有动过这三张表里的路由**——`added` 只出现过一次
> （开机第 37 秒），之后 14.7 小时再没补过，而补路由的前提就是"表里没有"。
> 对 `ip rule` 也许成立，对这些路由不成立。详见
> [`37`](37-the-trial-that-had-no-peer.md) §2。本文其余部分（§1 的现场、§2 的机制、
> §3 的时间吻合）没有被推翻。

---

## 1. 证据

`netwatch` 的 netsnap 在设备上抓到了断点之后 4 秒的现场
（uptime 51.31，主机此时已不可达）：

```
--- ip rule ---
0:	from all lookup local
10000:	from all fwmark 0xc0000/0xd0000 lookup 99
10500:	from all iif lo oif dummy0 uidrange 0-0 lookup 1003
13000:	from all fwmark 0x10063/0x1ffff iif lo lookup 97
14000:	from all iif lo oif dummy0 lookup 1003
15000:	from all fwmark 0/0x10000 lookup 99
16000:	from all fwmark 0/0x10000 lookup 98
17000:	from all fwmark 0/0x10000 lookup 97
32000:	from all unreachable

--- route get host ---
RTNETLINK answers: Network is unreachable

--- iptables filter ---
Chain OUTPUT (policy ACCEPT 0 packets, 0 bytes)
    0     0 oem_out ...
    0     0 fw_OUTPUT ...
    0     0 st_OUTPUT ...
    0     0 bw_OUTPUT ...
```

而 main 表里路由是好的（同一份日志的 `--- route ---` 段）：

```
10.15.19.0/24 dev rndis0 scope link src 10.15.19.82
192.168.2.0/24 dev rndis0 scope link src 192.168.2.15
```

## 2. 机制

```
Ubuntu Touch 发包（无 fwmark）
      ↓
规则 15000/16000/17000:  fwmark 0/0x10000  →  【匹配】
      ↓
查表 99 / 98 / 97   ——  这三张表【是空的】
      ↓
查不到路由，继续往下
      ↓
规则 32000:  from all unreachable   →  【判定不可达，包被丢弃】
      ↓
包从未被构造 → 从未到达 eth_start_xmit
      ↓
drv_rcvd == tx_pkts（99 == 99）、所有 netdev 计数器不动
```

`fwmark 0/0x10000` 里的 `0` 是值、`0x10000` 是掩码，
所以这条规则匹配的是**所有 fwmark 掩码位为 0 的包**——也就是**任何没打 fwmark 的包**。
Ubuntu Touch 的包正是如此。

这一条把之前所有"干净计数器"的观察一次性解释完：

- `tx_dropped=0` / `tx_errors=0`：包没被构造，谈不上丢
- `tx_qlen=0` / `tx_throttle=0`：没进队列
- ARP 条目 complete 却发不出去：邻居是好的，是**路由查找**先失败了
- **netfilter 完全干净**：OUTPUT policy ACCEPT，所有计数器 0 —— 不是 iptables

## 3. 时间吻合

```
uptime 44.95   host-ping OK      规则还没装
uptime 47.40   host-ping FAIL    断点（2.4 秒的转折）
uptime 51.31   netsnap 快照      规则已在，32000 unreachable 生效
```

netd 在容器起来的过程中装这套规则，2.4 秒内从通到不通。

## 4. 修法

`main` 表里有 `192.168.2.0/24 dev rndis0`，只是被 netd 的规则挡在后面。
**加两条优先级更高的规则，只针对这两个网段**：

```sh
ip rule add pref 1000 from all to 192.168.2.0/24  lookup main
ip rule add pref 1001 from all to 10.15.19.0/24   lookup main
```

### 为什么加 `to <net>` 而不是 `from all lookup main`

`from all lookup main` 会排在 netd 所有 fwmark 规则前面，**也会影响 Android 容器自己的流量**。
main 表里没有默认路由，所以 Android 的包查不到会继续往下走、最终仍落到它自己的规则上——
但这依赖于一个微妙的性质。加上 `to <net>` 之后，**只有发往这两个网段的包被改道**，
Android 的流量完全不受影响。

### 为什么在 netwatch 里做，而不是一次性设置

> **这段在 2026-09-21 被更正，见文首。** 实测：netd 并没有清掉这三张表里的路由，
> 14.7 小时里一次都没补过。保留原文是因为它记录的**当时**的推理——
> 现在仍然每个采样周期检查一次，但理由是"改动要能被下一次开机复现"，
> 不是"netd 每隔几秒会清一次"。

netd 在容器启动和每次重启时都会重装规则（容器每 ~65 秒被重启一次，见
[`33`](33-the-container-restart-loop.md)）。所以这条修复必须**反复施加**，
而不是开机设一次。netwatch 每个采样周期检查一次，缺了就补——
成本是每 2 秒一条 `ip rule show`（读操作，无副作用）。

### 判据不是"规则存在"，是"route get 真的能解析"

```sh
if ip route get 192.168.2.100 2>&1 | grep -q "dev rndis0"; then
```

因为"规则加上了"和"包能出去了"是两件事——这正是今天上午栽的那个坑
（[`34`](34-correction-the-100-percent-was-the-watchdog.md)：把"治愈成功"读成"没有故障"）。

## 5. 实现与验证状态

实现：[`scripts/device/zl1-netwatch.sh`](../../scripts/device/zl1-netwatch.sh) 里的
`apply_policy_routing_fix()`，每个采样周期调用一次。

已经做了的验证：

- `sh -n` / `dash -n` / `busybox sh -n` 三种 shell 都通过
- **沙箱模拟**：用 mock 的 `ip` 复现"规则缺失 → 添加 → `route get` 从不可达变可达 → 幂等不再重复添加"，
  4 次调用只产生 2 条规则（1000 / 1001 各一条），日志只打一次
- 需要设备做的验证：在真机上确认这条规则真的让链路保持可用

## 6. 如果这条不对

三个可能：

1. **netd 之后又重装规则把它挤掉** —— 那 netwatch 每 2 秒会补回来，日志里会看到反复添加
2. **pref 1000 被 netd 的规则抢先** —— 不会，1000 < 10000，但值得看日志确认
3. **还有别的东西也在丢包** —— 那就看 `route get` 好了之后链路是否恢复；如果 `route get` 好了
   而链路仍然不通，说明还有第二层问题

第 3 点是最有价值的失败模式：它会明确告诉我们"策略路由只是其中一层"。

## 7. 顺带确认的两件事

- **sshd 那次是好的**：快照里 `LISTEN 0.0.0.0:22 users:(("sshd",pid=43282))`。
  后来某次开机不在监听，是 `lxc-android-config-disable-ssh-socket.service` 干的
  （[`32`](32-counterexample-38-minute-boot.md) §5），不是公钥配置的问题。
- **netsnap 一直工作正常**：这份快照是那次开机自己拍的，输出完整。
  我之前说"没装 netsnap"是错的——它装了，是我没去看日志。
