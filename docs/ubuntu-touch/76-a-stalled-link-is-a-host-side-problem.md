# 76 — 链路卡死时**不需要碰设备**：从主机侧重新枚举 USB gadget 就回来了（设备全程是好的）

**日期**: 2026-09-23
**状态**: **一次真实的卡死被主机侧修好了，设备连 uptime 都没变。** 这台设备现在只有 RNDIS 一条路可走，所以"主机能不能自己把路修回来"直接决定项目会不会被迫去按手机。这次的答案是：**能**，用 `authorized` 0→1 让主机重新枚举 gadget。同时量到一个缺口：**设备侧的看门狗 `zl1-netwatch` 全程没管这件事**，而它的判据本来就不覆盖这种形状。

**接续**: [`35`](35-the-policy-routing-rule-that-kills-the-link.md)（同一类"链路死掉"的另一半：策略路由）、[`37`](37-the-trial-that-had-no-peer.md)（"没有 usb0"被当成"设备没开机"的那次）

---

## 1. 现场：设备活着，路死了

在一次长时间运行的相机栈重置（`camera-stack-reset.sh`）过程中，SSH 突然变成 `No route to host`。主机侧看：

```
usb0   UNKNOWN  192.168.2.100/24 10.15.19.100/24      <- 地址都在，接口在
3-3:1.0 / 3-3:1.1 都绑在 rndis_host 上                  <- 驱动也在
usb0 rx_packets = 63537 → 冻结                           <- 收不到任何东西
usb0 tx_packets 还在慢慢涨（只有 ARP 请求）
```

设备侧**完全正常**：USB 控制通道活着 —— `lsusb -v` 能读出全部描述符，`iSerial` 读得到 `33e80afe-v63-usbd-disabled-rndis`（也就是目标设备本人，不是那台小米）。ARP 表里 `10.15.19.82` 是 FAILED，`192.168.2.15` 还是 STALE。

**所以这不是握手问题、不是地址问题、不是驱动绑定问题，而是 RNDIS 数据通道单向卡住：设备不再往主机发。** 这一点后来被最重要的一条证据钉死：**恢复全过程设备的 uptime 从 38532 秒一直连着**，没有重启。

## 2. 修好它的那一步：重新枚举

按代价从低到高试，每一步之后都用真链路测（ping + 一次真的能读出值的 SSH）：

| 步骤 | 动作 | 结果 |
|---|---|---|
| 1 | `ip link set usb0 up` + 重新加两个地址 | 没用（地址本来就在） |
| 2 | 在 gadget 的两个接口上 unbind/rebind `rndis_host` | 没用（接口重建了、MAC 变了，还是收不到） |
| 3 | **`authorized` 0 → 1（主机重新枚举 gadget）** | **通了** |

第 3 步是这次的关键，而且它符合"绝不碰设备"这条底线：写的是**主机侧** `/sys/bus/usb/devices/3-3/authorized`，设备只是看到一次 USB reset（和每次启动看到的是同一件事），**不断电**（电池在供电，uptime 是证据）。第 4 步（把整个 USB 设备从主机的 `usb` 驱动上 unbind/rebind）留在脚本里但**需要 `--force`** —— 它最接近"拔插一次"，如果它也没回来，下一步就是人来按电源键。

这一条现在是 `scripts/host/zl1-rndis-recover.sh`（`--status` 只查不动；按序列号 `33e80afe` 前缀匹配，绝不按 USB ID；带 `--force` 才做第 4 步；日志在 `/var/log/zl1-rndis-recover.log`）。**这是"设备不会变得够不着"这条约束目前最硬的一块保障。**

## 3. 缺口：设备侧的看门狗没管这件事

`zl1-netwatch.service` **在跑**（pid 32463，`active`），判据是它自己文件里写的：

```
STALL_SECONDS=45     # TX must be frozen this long while RX moves, to declare a stall
```

而整个事件窗口里**一条 heal 都没有**（日志里只有每次启动的 `netwatch start … heal=0 stall=45s` 那一行）。原因它自己的注释里已经写过一次：

```
157-# theory that a stall looks like "the host is talking and we are not answering" — but with
159-# first success) RX does not move either, so it concluded "not stalled" and did nothing.
```

也就是**它的判据要求"TX 冻住**同时**RX 在动"**，而这次主机侧只零星发了几个 ARP（2.5 分钟里 tx 从 15 涨到 29），根本没有足够的 RX 动作去配对这个条件。

> **诚实标注**：这一点**没有**被直接证明 —— 设备侧在卡死窗口里的计数器我拿不到（因为没有链路），所以我只能确定"判据要求 RX 动作"和"这次 RX 可能几乎没动"这两件事，不能确定它当时具体读到什么。要真正定案得在一次可复现的卡死里同时抓两侧的计数器。

**结论上的取舍**：与其去改这个判据（改错了会让它对着健康链路乱治），不如把"主机侧恢复"当成标准手段 —— 它成本更低、有实测、而且不需要设备配合。netwatch 保持原样，它的职责是设备侧自愈，这次没触发是已知边界。

## 4. 我自己这支恢复脚本的两个 bug（都是"它会骗人"的那种）

1. **单包 ping 会把好的链路判成死的。** 第一版用 `ping -c 1 -W 2`，卡死之后 ARP 表项是 FAILED/空的，**第一个包全花在 ARP 解析上**，于是"链路正常"也被报成 dead。对一个恢复工具来说这是最坏的 bug：**它会接着去重新枚举一条健康的链路**。改成 `ping -c 3 -i 0.3 -W 3`，并且后面还有一次真的读 `/proc/uptime` 的 SSH 作为第二判据。
2. **在 `sudo` 里用 root 的 SSH 密钥。** 脚本要写 sysfs 所以整体跑在 root 下，但 root 的 `~/.ssh` 不是设备授权的那把 key，于是 BatchMode 下拿到 `Permission denied (publickey)`，**又**把好链路报成死的。修法是进 root 之前记住调用者（`SUDO_USER`）、找出他的 key 并用 `-i` 传进去。

两个 bug 的形状一样：**恢复工具的"检测"必须比它要修的问题更可靠**，否则它会把好设备当坏设备修。

## 5. 复现

```sh
# 只查不动（退出码 0 = 链路真在传数据）
scripts/host/zl1-rndis-recover.sh --status
# 按 1→2→3 升级修复，通了就停
scripts/host/zl1-rndis-recover.sh
# 只在前三步都失败、并且你接受"最接近拔插一次"时才加
scripts/host/zl1-rndis-recover.sh --force
```

**设备安全**：全程只写主机侧的 sysfs（`authorized`、`rndis_host/bind`、`usb/bind`）和主机的 `usb0` 地址。**设备上没有任何一个字节被读或写，没有任何分区被碰，设备一次都没有被要求做任何事**（做不到 —— 这支脚本正是"够不着它"时用的）。目标匹配按序列号前缀，不按 USB ID。恢复过程中设备 uptime 连续（38532 → 38590+），没有重启。
