# 112 — 那扇门其实是一场比赛，而比赛在 keeper 消失的那一刻就结束了

**日期**: 2026-09-23
**状态**: 纯离线的一轮。设备仍在 Qualcomm EDL（`05c6:9008` / port 3-3，无序列号），出来只能靠物理
长按电源。这一轮**没有**碰设备，但它拆掉的是**卡住发烫修复的那扇门本身**。

**接续**: [`88`](88-the-addresses-are-ours-now-not-only-the-keepers.md)（地址现在是 netwatch 的活）、
[`94`](94-retiring-the-v63-debug-keeper-is-a-kill-not-a-unit-edit.md)（退休是一次 kill）、
[`111`](111-netwatch-over-ssh-and-the-twrp-step-that-bought-nothing.md)（装新构建不再需要 TWRP）、
[`107`](107-the-instruments-that-cannot-report-are-not-armed.md)（读不回来的仪器等于没武装）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 门要求什么？ | `zl1-boot-address-check.sh` 读出 `netwatch-configured`，也就是 netwatch 日志里有一行 `ADDRS:`，才发许可去退休 keeper |
| 那一行什么时候才出现？ | **只在 `ensure_addrs()` 发现地址缺失时**。而 keeper 活着的时候它每一秒都把两个地址补回去 —— 所以那一行只在 netwatch 的 2 秒采样恰好落进「地址没了」到「keeper 下一次 tick」之间那道缝里时才出现 |
| 那道缝有多宽？ | 从几十毫秒到 1 秒，**而且从来没有量过**（rndis0 出现与 keeper 的 `configure_iface` 之间隔着一个异步的 gadget bind） |
| 所以「再开一次机再看一遍」是什么？ | **重掷骰子，而且每一次都要开一次机。** 这不是重试，因为失败的那次什么也没测到 —— netwatch 那一轮根本无事可做 |
| 关键的不对称？ | **这道缝在 keeper 消失的那一刻就没了。** 而在那个配置里（也就是这扇门真正要回答的问题里），没有别的东西会去配这个接口，`addrs_ok` 在第一个看到 rndis0 的采样点必然是假，那一行是**确定的** |
| 所以改了什么？ | `inconclusive` 不再指路「再开一次机」，而是指路 `scripts/device/zl1-address-owner-proof.sh --yes` —— 它**故意**把设备放进那个配置里几秒钟：停掉 keeper、拿走一个地址、要求 netwatch 自己发现并补回来 |
| 离线验证？ | `zl1-boot-address-selftest.sh` **24 检查**（多了「两种 inconclusive」一节，并开始自校验健康检查里的引用）；新探针的 `zl1-address-proof-selftest.sh` **49 检查**，**九次变异每一次都让它失败**（§5） |
| 这一轮没证明什么？ | **没有在设备上量过。** 这道门仍然要一次真机运行才能被关上（§6） |

---

## 2. 门的算术：两个写者，两条时钟

门的定义（`zl1-boot-address-check.sh` §5）是：日志里出现 `ADDRS:`，且它早于第一次 heal。
`ADDRS:` 来自 `zl1-netwatch.sh` 的 `ensure_addrs()`：

```sh
ensure_addrs() {
    [ -e "/sys/class/net/$IFACE" ] || return 1
    addrs_ok && return 0          # ← 两个地址都在：安静地返回，什么都不写
    restore_addrs
    ...
    log "ADDRS: uptime=... iface=$IFACE now='...'"      # ← 只有"缺了"才写
    return 0
}
```

而 v63 的 debug keeper（`boot/v63/scripts/init-bottom/zl1-postswitch-debug-init`）在自己的
`while :` 里，**同一个循环体**里做了这件事：

```sh
force_android_usb_rndis steady || true        # 它自己把 gadget 拉起来
configure_iface usb0  && configured=1
configure_iface rndis0 && configured=1        # 然后立刻把两个地址加回去
sleep 1
```

`configure_iface` → `add_addr` 是幂等的（`ip addr show … | grep -q " $addr/" || ip addr add …`）。

于是 keeper 活着时，netwatch 的每一次采样看到的都是「两个地址都在」。它能写出 `ADDRS:` 的唯一机会
是：某个地址**在两次采样之间消失**，而它的下一次采样比 keeper 的下一次 tick 更早到达。

两个独立周期（1 s 的 keeper，2 s 的 netwatch），意味着这是一个**相位竞争**：

```
rndis0 出现的时刻 T
     keeper 下一次 configure_iface：      T + Δk,  Δk ∈ (0, 1]
     netwatch 下一次采样：                T + Δn,  Δn ∈ (0, 2]
     netwatch 能写 ADDRS  ⟺  Δn < Δk
```

在两者相位独立且均匀的假设下这是 1/4 —— 但**这个 1/4 不该被当成结论**，因为 Δk 那一端取决于一个没量
过的异步延迟：`enable=1` 之后 rndis0 由 gadget bind 的 workqueue 创建，从几毫秒到几百毫秒都可能。
真正能站住的陈述只有一句：

> **keeper 活着时，`netwatch-configured` 是一个「赢了一场比赛」的结果，而那场比赛的窗口宽度没有量过。
> 因此 `inconclusive` 是多数开机的**预期**读数，而不是一次失败的尝试。**

这也解释了为什么会走到这一步：`inconclusive` 的旧文案说「确认装的是带 `ensure_addrs()` 的构建，
再开一次机，再看一遍」—— 那句话听起来像是重试，实际上是在掷骰子。

---

## 3. 为什么「再掷一次」不是答案，而差别的方向恰好是好的

值得停一下的是**这道缝为什么存在**：它存在**只因为 keeper 还在**。

- keeper 活着：两个写者，一道缝，证据靠运气。
- keeper 消失：一个写者。rndis0 一出现，第一个看到它的采样点就会走进 `restore_addrs()` 并写下那一行 ——
  **确定性的，每一次开机都是**。

也就是说：**这扇门想要的那条证据，在它唯一不需要证据的配置里最难拿到，而在它真正要回答的配置里是免费的。**
`netwatch-configured` 是一个「用运气去证明一个一旦条件成立就必然发生的事」的门。

所以正确的动作不是再开一次机，而是**在测量的那几十秒里把那道缝拿掉**：把 keeper 停住，于是没有任何别的
写者，再拿走一个地址，看 netwatch 会不会自己发现。这就是 `zl1-address-owner-proof.sh`。

这条推理也顺手说清了它和「真机上的无 keeper 开机」是什么关系：

* `--prove` 证明的是**机制**：这份已安装的构建的地址通路在这台设备上、在没有别人插手的情况下跑得起来，
  而且是每 2 秒一次。
* 真机无 keeper 开机证明的是**排布**：那个 unit 起得够早、在容器起来之前就把地址放上去了。
* 两者都需要，但前者可以在 30 秒内、可逆地、不用开机地拿到；后者才是最终那一次。

---

## 4. 改了什么

### 4.1 `inconclusive` 有两种形状，而且它们不是同一件事

旧文案在两种情况下说同一句话，其中一种是错的：

| 情况 | 谁配的地址 | 旧文案 | 新文案 |
|---|---|---|---|
| keeper 在跑 | keeper（它每秒钟在做这件事） | 「netwatch 路径未被证明」 | 加上那道缝的算术、明确说重跑是重掷骰子、指到 `--prove` |
| **keeper 不在跑** | **不知道** —— 手工 `ip addr add`、容器、或者一份没有可用 `ensure_addrs()` 的构建 | 仍然是「所以是 keeper 配的（它还在跑）」 | 明确说 keeper 也不在跑，所以地址来自别处 |

第二行是一个小的同族缺陷：一句断言了它没有检查过的事情的文案。脚本 §4 已经扫过 keeper 的 pid，所以修它
只需要把那个变量用上。

### 4.2 新探针 `scripts/device/zl1-address-owner-proof.sh`

```
--yes  →  找到 keeper → 武装自动回滚 → SIGSTOP（读回状态必须是 T）
       → 从 rndis0 拿走 192.168.2.15/24（读回必须真的没了）
       → 等最多 --wait 秒：地址回来了吗？日志里有新的一行 ADDRS 吗？
       → 无论结果如何：恢复了地址吗？没有就自己补上；然后把 keeper SIGCONT
```

四档结论：`proof-obtained`(0) / `proof-unclear`(1) / `proof-failed`(1) / 未武装(2)。

**`proof-unclear` 是这一轮新增的一档，而且它不是形式主义**：地址回来了，但没有新日志行。地址确实回来了
（keeper 停着，唯一可能的写者就是 netwatch），可它没有留下证据 —— 那要么是这份构建的 `restore_addrs()`
不写日志，要么脚本看错了地方。**不把它算成证明**，是因为这扇门读的就是日志行。

`proof-failed` 也分两种，因为它们的下一步不同：日志有行而地址没回来（`restore_addrs()` 跑了但没贴上，
是「没粘住」而不是「沉默」），和两者都没有（按可能性排序：内存里跑的是旧构建 → 先重启；或者它根本没在采样）。

**四件刻意不给的东西**：

1. **拿走哪个地址是文件里的字面量。** `10.15.19.82/24` 是主机 SSH 进来的那个地址
   （`ZL1_HOST=root@10.15.19.82`），脚本里没有任何参数能碰到它。就算有人反着来（从
   `192.168.2.15` 登进来），暴露也是有界的：下面那条定时器和 keeper 自己的 1 Hz 循环都会在一秒左右把它补回来。
2. **keeper 不可能一直停着。** 一个 detached 的 `setsid sh -c 'sleep N; kill -CONT pid'` 在 **SIGSTOP
   之前**就武装好，余量比等待窗口多 60 秒 —— 所以 SSH 断线、脚本被 `kill -9`、主机消失，都不会把设备
   留在一个没有地址提供者的状态里。提前 `SIGCONT` 是无害的（对运行中的进程再来一次 SIGCONT 什么也不做）。
3. **`SIGSTOP` 之后要读回状态，`ip addr del` 之后要读回地址。** 两者都是
   [`107`](107-the-instruments-that-cannot-report-are-not-armed.md) 那条规则：一个没生效的停止、一个
   没落地的删除，如果被当成生效，测量出来的就是一句谎话。
4. **一个字节都不装、不改、不写。** 不碰 unit、不读分区、不重启。重启之后 keeper 自己就在跑，这个脚本
   里没有任何持久化的东西。

（顺带一句诚实的话：第 2 条在真机上的依据是 SSH 会话结束时 sshd 会杀掉会话的进程组，所以没有 detach 的
定时器活不过一次掉线；这一点只能靠离线 harness 里的包装器观察到 —— 见 §5.2 的 S12 与 M9。）

---

## 5. 离线验证：24 + 49 检查，九次"必须失败"

### 5.1 `zl1-boot-address-selftest.sh`：24 检查（原来 18）

新增「两种 inconclusive」一节：`C` 场景（假 `/proc` 里没有 keeper）必须出现「keeper 也不在跑」的措辞，
`I` 场景（假 `/proc/813` 里放一个 state `S` 的 `zl1-debug-keeper`）必须出现那道缝的算术、必须说重跑是
re-roll、必须指向 `--prove`，而且**不许用**「keeper 也不在跑」那套措辞。两个分支各有一条断言，所以
文案合并回一句话会被抓到。

同一节还多了**引用自校验**：健康检查里为每个 harness 手写的检查条数曾经腐坏过一次
（[`110`](110-the-lshal-columns-have-a-definition.md)：GPS 那行写着 99，而 harness 已经长到 129），腐坏
了也不会有任何东西失败。现在这个 harness 自己去读健康检查里的那个数字，跟本次运行的条数比。
**如果这台主机上没有非 gawk 的 awk**，BIG 一节会被跳过，总数就依赖主机，这时它**大声数一个 SKIP** 并说明
为什么不比 —— 而不是拿一个反正会对的数字去比。

### 5.2 `zl1-address-proof-selftest.sh`：49 检查

这个探针是**会写的那一类**（[`97`](97-both-hardware-probes-write-the-wrong-thing.md) 记的就是这类探针的
一个写模式写错了东西）：它停一个进程、拿走一个地址，量的又是保命的
那条路。所以它先在假根里跑：真脚本 + 桩 `ip` + **两个真的进程**（cmdline 里带着脚本要找的两个名字，
`$FR/proc/<pid>` 是指向真 `/proc/<pid>` 的符号链接，所以状态字段是真读出来的）+ 一份假日志。

**`kill` 没有桩掉**：SIGSTOP 真的发出去，`/proc/<pid>/stat` 真的变成 `T`，undo 真的把它变回 `S` ——
「keeper 被停住了」和「keeper 又跑起来了」这两件事正是不能靠模拟的。

| 场景 | 断言 |
|---|---|
| S1 | 地址回来了且日志有新行 → `proof-obtained`(0)；**那条自我回滚的定时器确实被武装、目标就是 keeper 的 pid**；结尾 keeper 是 `S`、地址在接口上 |
| S2 | 什么都不回来 → `proof-failed`(1)，**脚本自己把地址补回去并说了**，keeper 回到 `S` |
| S3 | 日志里**只有一行旧的** `ADDRS:`，地址回来了但没有新行 → `proof-unclear`(1) |
| S4 | `ip addr del` 静默不生效（而 `addr show` 照常回答）→ 未武装(2)，keeper 仍然被恢复 |
| S5 | 三条前置拒绝：没有 `--yes`、装着的构建没有 `ensure_addrs()`、netwatch 没在跑 |
| S6 | keeper 本来就不在 → 仍然能测，且**不谎称**恢复了 keeper |
| S7–S9 | 非 zl1 设备、`--wait` 的两种坏值、`--help` 打的是整段头 |
| S10 | 文件比进程新（装完没重启）→ 说出内存里是旧构建、并给出下一步 |
| S11 | 日志有新行但地址没回来 → `proof-failed`，且文案是「没粘住」 |
| S12 | **脚本在等待中被 `kill -9`** —— 出口 trap 没有机会跑，于是：keeper 仍然是 `T`、地址仍然不在、那条 detached 定时器还活着并且指着 keeper 的 pid。这是整份文件里最重要的一条性质，也是普通场景到不了的那一条 |

外加一组**静态**断言（安全性质从源码里读，不是从运行结果里推）：不含 `sysrq-trigger`/`kexec`/`/dev/block`、
没有 `reboot|poweroff|halt` 的**命令**（消息里的那个词是允许的，所以匹配的是命令位置而不是词）、不含
`systemctl`、`ip addr del` 作为命令**只有一处**且操作数是字面量、以及**武装那条定时器的行号必须小于第一条
`kill -STOP` 的行号** —— 最后这条就是「脚本被杀掉时 keeper 不会留在停住状态」的形式化。

九次变异，每一次都让这个 harness 失败：

| 变异 | 结果（基线 49 pass / 0 fail） |
|---|---|
| M1 去掉 `--yes` 闸门 | 21 pass / **32 fail** |
| M2 先 SIGSTOP 再武装定时器 | 48 pass / **1 fail**（武装行号必须小于 SIGSTOP 行号那条静态断言先红） |
| M3 去掉日志偏移锚（任何 `ADDRS:` 都算新） | 46 pass / **4 fail**（S3 变成 `proof-obtained`） |
| M4 不读回 `del` 的结果 | 47 pass / **3 fail**（S4 变成 exit 1） |
| M5 undo 不补地址 | 48 pass / **1 fail**（S2 抓到地址被留在了接口外） |
| M6 改成拿走 SSH 那个地址 | 30 pass / **23 fail** |
| M7 判定只看日志行 | 46 pass / **3 fail**（S11 变成通过） |
| M8 undo 不恢复 keeper | 46 pass / **3 fail**（state 变 `T`） |
| M9 回滚不 detach（走非 setsid 的 `sh -c ... &`） | 46 pass / **3 fail**（S1/S12 都看不到被武装的定时器） |

**还有一条没有牙的，要诚实说明**：我最早试的变异之一是「把 SIGSTOP 的状态读回放宽到接受 `S`」。它**没有让
任何断言变红**，因为这个 harness 无法让一次真的 SIGSTOP 失败 —— 而桩掉 `kill` 就会把上面那条最重要的性质
（真的停住、真的恢复）一起丢掉。所以这一轮记的是**九**次变异，而不是十次，而那次尝试留在这里，因为它是一类
值得记住的空白：*一个断言如果没有任何场景能触发它，它就还不是一条检查。* 脚本本身仍然读回状态、并且在不
是 `T` 时拒绝测量 —— 只是那条路径在离线 harness 里没有覆盖。

M9 的见证者是 harness 里那个记录调用的 `setsid` 包装器。在真机上这条性质的依据不是包装器：SSH 会话结束时
sshd 会杀掉会话的进程组，所以**没有 detach 的定时器活不过一次掉线** —— 而 S12 证明的是包装器看到的那次
`setsid` 真的脱离了这个脚本（脚本被 `kill -9` 之后它还在）。

M3 和 M7 值得单独看一眼，因为它们是先**绿**后红的：M3 一开始没有牙，因为当时没有任何场景能让地址回来却没有
新日志行；M7 一开始也没有牙，因为没有场景是「有日志行但没有地址」。两个覆盖空洞都是**变异测试找出来的**，
不是靠再读一遍代码 —— 这也是为什么这一节要留下这两次记录。

harness 本身也在这一轮里被抓到过两个缺陷，都是「看起来在测、其实测不到」那一类：一是它只清掉自己记录过的
那两个进程号，于是上一个场景留下的、没被记录的进程会被下一个场景的 `/proc` 遍历找到，S5c（netwatch 没在跑）
和 S6（keeper 早就不在）就会悄悄不再测它们名字里的那件事；二是清空假 `/proc` 时用的是 `*`，把身份守卫要读的
`model` 文件一起删了，于是**每一个**场景都以「不是 zl1」退 2 —— 一个看起来完全像脚本缺陷的假象。再加上最初
被发现的第三个：自我回滚的定时器会跨场景堆积，它们迟到的 `kill -CONT` 会落在**被回收的 pid** 上，于是基线
自己开始随机失败。三处都不在脚本里，但只有它们修好之后，上面那张表里的数字才代表脚本。

---

## 6. 这一篇**不**证明什么

* **不证明 netwatch 能在无 keeper 的开机里配好地址。** 这一轮把「怎么量」做成了确定性的，但量本身要设备。
  `--prove` 证明的是机制，不是排布（§3）。
* **不证明新的那套文案在真机上会照原样打出来。** 文案全部在假根里读过，但真机的 `awk`、`stat -c %Y`、
  `setsid` 是否都在，要设备回来第一次跑才知道（脚本对 `setsid` 有回退，对 `stat` 有守卫）。
* **不证明发烫解决了。** 两条主要成因（keeper 烧满一个核、四个核钉在 `performance`）都还没在设备上装。
  这一轮拆掉的是通往第二条的路上的门。
* **不证明 `--prove` 的 `proof-failed` 一定是坏消息。** 装完没重启时它是**预期**的（内存里是旧构建），
  这正是 S10 那行诊断存在的理由。

---

## 7. 设备状态与下一步

设备在 **Qualcomm EDL**（`05c6:9008` / `QUSB__BULK`，port 3-3，无序列号）。整轮只读过主机上的源码和
构建树；**没有写任何分区或 boot，没有跑 QDL/QFIL，没有重启，没有拔插**。识别目标按序列号前缀
**`33e80afe`**；总线上另一台设备 **`4a2fe00b`** 必须忽略。

设备回来之后，发烫那条链是：

```
scripts/host/zl1-post-recovery-capture.sh
install-netwatch-service.sh --yes --ssh        # 不再需要 TWRP（docs 111）
重启                                            # 新构建只有开机才生效（装了不重启 = S10 那一行）
zl1-boot-address-check.sh                      # 读 netwatch-configured；inconclusive 是正常的
zl1-address-owner-proof.sh --yes               # ← 这一轮新增：不用再掷骰子
install-retire-debug-keeper.sh --install --now --after-proof  # 114 之后这一步自己会先跑那个 proof，只有 proof-obtained 才杀
install-cpufreq-governor.sh                    # 发烫的另一半
```
