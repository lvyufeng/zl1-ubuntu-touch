# 36 — 一个上游原因，两个症状？

**日期**: 2026-09-20
**状态**: 假设，等待设备日志验证

---

## 观察到的两个症状

| 症状 | 证据 |
| --- | --- |
| **链路每 ~50 秒断一次** | `32000: from all unreachable` 把无 fwmark 的包判为不可达（[`35`](35-the-policy-routing-rule-that-kills-the-link.md)） |
| **容器到不了 coldboot_done** | `lxc-android-ready` 无超时等待，容器被反复重启（[`33`](33-the-container-restart-loop.md)） |

之前我把它们当成两个问题（A 和 B），并认为修好一个会恶化另一个。

## 一个可能让它们变成同一个原因的东西

`netd.rc`（Android 侧）：

```
service netd /system/bin/netd
    class main
    socket netd stream 0660 root system
    socket dnsproxyd stream 660 root inet
    socket mdns stream 0660 root system
    socket fwmarkd stream 0660 root inet
    onrestart restart zygote
    onrestart restart zygote_secondary
```

两条要点：

1. **netd 就是装那些策略路由规则的东西**——`32000 unreachable`、`15000/16000/17000 fwmark 0/0x10000`
2. **`onrestart restart zygote`** —— netd 重启会连带重启 **zygote**，而 zygote 是 Android
   框架的起点

所以如果 netd 在反复重启：

```
netd 启动 → 装规则 → （某事让它失败）→ netd 被重启
                                            ↓ onrestart
                                       zygote 被重启 → Android 框架永远起不来
                                            ↓
                                       coldboot_done 永远不出现
                                            ↓
                                       lxc-android-ready 无超时 → systemd 重启容器
```

**一次 netd 重启 = 一次链路中断 + 一次容器启动失败。**

## 这改变了两件事

### 一、A 和 B 不是两个问题

[`33`](33-the-container-restart-loop.md) §4 说"修好 A 会让 B 更容易发生"。如果这个假设成立，
真实情况是：**A 和 B 都由 netd 的反复重启造成**，修 netd 会同时解决两个。

### 二、修法可能比"补表"更根本

现在 [`35`](35-the-policy-routing-rule-that-kills-the-link.md) 的做法是**在每个采样周期往
netd 的表里补路由**——治的是 netd 装完规则之后的状态。如果 netd 本身在反复重启，
那还有另一个方向：**让 netd 不要反复重启**，规则只装一次，链路就稳定了。

## 需要什么证据

| 问题 | 怎么看 |
| --- | --- |
| netd 在重启吗 | 容器里 `pgrep -f netd` 的 PID 有没有变；`dmesg` 里有没有反复的 `Created socket '/dev/socket/fwmarkd'` |
| netd 重启和链路断同时吗 | netwatch 日志的 `policy routing fix: added` 时间点 vs 内核日志 |
| netd 为什么失败 | Android 的 `logcat`（容器里）或者 `/data/tombstones` |

**这三条都需要设备可达**，而现在设备卡在 cold boot #3，链路不通。

## 一个已经可以做的推论

如果 netd 的重启周期也是 ~50-65 秒，那和观测到的链路断点（46 秒）、容器重启（65 秒）
就在同一个量级上——**三个数字吻合**，这是支持假设的第一条线索。

（但"三个数字接近"不是证明。可能是同一个周期，也可能只是都受同一个外部因素约束。）
