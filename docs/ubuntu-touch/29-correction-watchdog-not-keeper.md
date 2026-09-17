# 29 — 更正：每 ~118 秒重枚举的是我自己的看门狗，不是 keeper

**日期**: 2026-09-17
**推翻**: [`26-gadget-reassert-every-2-minutes.md`](26-gadget-reassert-every-2-minutes.md)

---

## 1. 设备端日志直接给出了答案

`/data/zl1-netwatch.log` 里的 session 边界：

```
   34.93s netwatch start ... heal=1 ... recovery_after=900s
  901.71s RECOVERY: uptime 901s >= 900s — asking the bootloader for recovery
  901.71s RECOVERY: could not write the bootloader command; doing a plain reboot
   35.55s netwatch start ... heal=1 ... recovery_after=900s
  902.17s RECOVERY: ... doing a plain reboot
   35.23s netwatch start ...
  902.35s RECOVERY: ... doing a plain reboot
   35.87s netwatch start ...
  922.77s RECOVERY: ... doing a plain reboot
   35.42s netwatch start ...
  902.48s RECOVERY: ... doing a plain reboot
   35.53s netwatch start ...
   34.87s netwatch start ... heal=0 ... recovery_after=1800s     <- 纯记录模式
```

**netwatch 自己重启了设备 5 次。**

## 2. §26 错在哪

§26 的头条是"v63 的 keeper 每 ~118 秒把 USB gadget 拆掉重建一次"。
那是从主机侧看到的 `usb0` 反复消失/重新出现推断的，**我没有去看设备端谁在动手**。

现在设备端日志把同一段时间的因果写得很清楚：

```
  117.18s STALL: tx_packets frozen at ... for 46s while rx went 107 -> 198
  117.19s HEAL A: reason=tx-frozen-46s
  117.21s HEAL A: enable=0/1 on the gadget          <- 这就是一次重新枚举
  122.31s HEAL A: done
  233.65s STALL: ...
  233.68s HEAL B: unbind/rebind the rndis function  <- 又一次
  ...
  901.71s RECOVERY: ... doing a plain reboot
```

治愈的时间点：117 / 233 / 358 / 476 / 594 / 711 / 825 秒，平均间隔 **122 秒**。
而 §26 从主机侧量到的"重新枚举"间隔是 **117–125 秒**。

**同一个东西。** 那 16 次"重新枚举"是我的看门狗的 A/B 级治愈，不是 keeper 的 `force_android_usb_rndis`。

## 3. 因此

| §26 的说法 | 实际 |
| --- | --- |
| keeper 每 ~118 秒重建 gadget | **是我的 netwatch 在治愈**，keeper 开机只重建了一次（`reason=full`） |
| 那 ~118 秒是病因 | 那是**症状处理动作**，而且它在制造新的干扰 |
| 建议刷 `noreassert` 去掉 keeper 的重建 | **打错了目标**。keeper 本来就没在反复重建 |

`halium-boot-zl1-v63-noreassert.img` 因此是在修一个不存在的问题。
它不有害（keeper 少做一次无谓的重建），但它不是解药——**别指望刷了它链路就好了**。

## 4. 更糟的：看门狗在伤害设备

两件事：

**其一，`RECOVERY` 每 900 秒重启一次设备。** marker 文件写的是 900，
于是每次开机到 uptime 900 秒，netwatch 就重启它。设备陷入"跑 15 分钟 → 自杀 → 重来"的循环。

**其二，它想写 `boot-recovery` 进 misc 但写不进去**：

```
RECOVERY: could not write the bootloader command; doing a plain reboot
```

所以它退化成普通重启，设备回到 UT 而不是回到 TWRP。
**这就是为什么我之前以为"recovery 兜底从未生效"**——它确实没生效，但原因不是我以为的
那个 `continue`（那个我也修了，是真的），而是**写 misc 这一步本身就失败了**。

### 已经做的止血

设备在 TWRP 时我删掉了 `/data/zl1-netwatch-reboot-recovery`。
下一轮 `RECOVERY_AFTER=0`，不再重启。

## 5. 那真正的问题是什么

排除掉之后，剩下的观察是**干净的**：

- 每次开机，链路可用约 50 秒
- 之后设备**收得到、发不出**（`tx_packets` 冻结，`rx_packets` 继续涨）
- 这个状态自己不会恢复

**这个还没解释。** 而 netwatch 的治愈每次都会重新枚举 gadget、清掉主机的地址，
所以它在"治疗"的同时也打断了链路——**用它来观察这个问题是不合适的**。

所以现在设备上装的是 **`heal=0` + 无 recovery marker** 的纯记录模式：
它只写日志，不碰任何东西。下一轮的日志会是第一个没有被自己的治愈污染的样本。

## 6. 教训

这次和 [`27`](27-what-a-reachable-window-shows.md) §7 记的是同一种错误，而且更严重：

**我从主机侧看到一个规律（~118 秒的重新枚举），就给它编了一个设备侧的原因（keeper），
而没有去读设备端那份当时就能读到的日志。**

设备端的 `zl1-netwatch.log` 在我写下 §26 的时候就已经存在了——
只要我进一次 TWRP 就能看到"是我自己在动"。我没有去看，因为主机侧的规律看起来已经自洽了。

规则：**当推断涉及"设备上的某个进程在做什么"，就去读设备上的进程日志，
不要从主机侧的观察反推。**

## 7. 关掉干扰之后的干净基线

删掉 marker、`heal=0`，开机观察 20 分钟：

```
window                 : 20 min;  1199s 覆盖，302 个采样
gadget re-enumerations : 0
reachable              : 2.0% of the time (24s of 1199s)
longest reachable run  : 24s
ssh port 22 open       : 0%
status page 8080       : 3.3% of samples
```

**0 次重新枚举。** 对比有治愈时的 6–16 次/10–36 分钟——**那些枚举全部是治愈动作**，
一个都不是 keeper 干的。这一条现在是实测确认的，不再是从日志时间点推断。

而且 **18 分钟没有重启**（过了 900 秒关口）——重启循环也确认是 netwatch 的
`RECOVERY` 功能造成的，marker 一删就没了。

### 但底层问题还在

**链路可用 24 秒 / 20 分钟（2.0%）**，窗口就在开机后头一小段，之后一直"收得到、发不出"。
这次没有看门狗在旁边反复重新枚举、也没有重启，所以这是**第一个没有被自己污染的样本**。

问题没解决，只是终于被干净地量出来了：

| | |
| --- | --- |
| 症状 | 每次开机 ~25–50 秒后，设备收得到、发不出，且不自愈 |
| 已排除 | keeper 重建 gadget（喂，没有这回事） |
| 已排除 | 设备重启（喂，那是我自己造成的） |
| 已排除 | 主机侧状态（五种手段无效，含真总线复位） |
| 仍然未知 | 为什么 TX 会停 |

设备端的 `zl1-netwatch.log` 现在正在以纯记录模式累积这个过程的
`STALL(unhealed)` 记录——那是下一份要读的东西，而读它需要一次 TWRP。
