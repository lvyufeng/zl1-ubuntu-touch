# 33 — 90 分钟可达的一次开机，和它暴露的真正结构

**日期**: 2026-09-18
**设备**: `33e80afe`，同一张已知可用的 v63 镜像

---

## 1. 这次开机的结果

```
45 分钟定时测量 : 可达 100%（2698s / 2698s），0 次重新枚举
持续到发文     : 设备 uptime 9362 秒（2.6 小时），链路依然可达
                 947 个采样里可达 947 个
```

**这是整个移植工作里链路最稳的一次。** 而它同时在告诉我们**为什么**：

```
容器启动次数   : 143
容器命名空间   : 143 次 "Failed to allocate new network namespace"
zygote         : 0 次
netd           : 1 次
fwmarkd        : 0 次
```

## 2. 结构：容器在无限重启，而它是被设计成这样的

`lxc-android-config.service`：

```ini
Type=exec
ExecStart=/usr/libexec/lxc-android-config/start-android-container
ExecStartPost=/usr/lib/lxc-android-config/lxc-android-ready
```

而 `lxc-android-ready` 的结尾是：

```sh
while true; do
    [ -f /proc/$containerpid/root/dev/.coldboot_done ] && break
    sleep 0.1
done
```

**它会一直等 `/dev/.coldboot_done` 出现——没有超时。** 如果容器里的 Android init
走不到那一步，`ExecStartPost` 永远不会返回，systemd 就认为这个 unit 没启动成功，
于是**反复重启容器**。

143 次 / 9362 秒 ≈ **65 秒一次**。

### 和之前所有观察对上了

| 之前看到的 | 现在知道是什么 |
| --- | --- |
| 主机侧每 ~65–120 秒的重新枚举 | 是**容器重启**带动的，不是我猜的 keeper（[`26`](26-gadget-reassert-every-2-minutes.md)），也不全是我的看门狗（[`29`](29-correction-watchdog-not-keeper.md)）——**底层是容器在重启** |
| "容器时有时无" | 它一直处于"起来 → 没到 coldboot_done → 被杀 → 再起来"的循环 |
| 15:57 那次有 `lxc-stop -n android -k` | 就是 `ExecStop`，每次重启前停掉旧的 |

**所以真正的因果链是：Android init 走不到 coldboot_done → 容器被无限重启。**

## 3. 而"链路好"正是这个循环的副产品

这次能 2.6 小时不断，是因为**容器从来没走到 netd**（`zygote` 0 次、`fwmarkd` 0 次）。
而 [`32`](32-counterexample-38-minute-boot.md) 的对照说的是同一件事的另一面：
容器走到 netd 的那几次，链路都在 ~50 秒断掉。

`Failed to allocate new network namespace` 这条 WARN 出现 143 次也说明了原因：
容器**没有自己的网络命名空间**，和宿主共用一套。所以 netd 一旦跑起来，
它装的策略路由/iptables 就直接作用在 `rndis0` 所在的栈上。

## 4. 于是问题变成两个，而不是一个

| 问题 | 现状 |
| --- | --- |
| **A. 容器为什么走不到 coldboot_done** | 不知道。这是"Android 起不来"的直接原因 |
| **B. 容器走到 netd 之后，为什么 UT 的包发不出去** | 已有签名（[`30`](30-outbound-drops-before-the-queue.md)：包在设备队列前被丢），指向 netd 的策略路由 |

**A 和 B 有因果关系，但方向和我之前想的相反。**

我之前把"容器起来"当成病因（[`30`](30-outbound-drops-before-the-queue.md)），
现在的图景是：**容器的启动过程本身就在失败，而它在失败之前把链路打死了。**

也就是说，**修好 A 会让 B 更容易发生**——容器真的跑起来，netd 就会一直存在。
所以两个都得处理，而且**必须先搞清楚 B**，否则 A 修好了链路反而彻底不可用。

## 5. 下一步的优先级因此调整

原来的计划是"先让容器起来"。现在应该反过来：

1. **先解决 B**：容器走到 netd 时，为什么 UT 的包发不出去。
   需要一次"容器能走到 netd"的开机，然后读 `ip rule show` / `ip route get` / iptables 计数器。
   ——这正是 `netsnap` 要抓的东西，它已经装好在那儿等着。
2. **再解决 A**：容器为什么停在 coldboot_done 之前。
   这个可以在有链路的前提下慢慢查（因为 A 没解决时链路是好的）。
3. **A 修好之后回到 B 验证**——那时 netd 会长期存在，B 的修复才有意义。

## 6. 一个可以现在做的观察

`/dev/.coldboot_done` 是 Android init 在启动完成的标志。容器每次起来后，
可以看它卡在哪一步。设备当前可达，但状态页里没有

```sh
ls /proc/<containerpid>/root/dev/.coldboot_done
```

这一条。加到 `netwatch` 里很简单，下次开机就能看到"容器到底走到哪一步就停了"，
比数 `zygote` 出现次数精确。

（这次来不及加了——设备上装的是旧版看门狗，而且它现在跑得很好，不想打断。）
