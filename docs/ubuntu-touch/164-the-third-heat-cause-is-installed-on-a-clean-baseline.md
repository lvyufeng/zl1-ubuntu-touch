# 164 — 散热第三因装上了：一次干净基准上的第一个判词

**日期**: 2026-09-25
**状态**: 这一轮**重启了设备**（用户授权），然后跑了完整的一趟开机序列 01→06。结果**第一次**是可信的：
`05-trial` 在**干净基准**上印出 `== verdict: supported-not-proven`，而 `06-lpm-fix` 拿到这个执照，
把**散热第三因装上了**（`== verdict: installed`）。这一页记的是那次运行、它装上的东西、
以及在这份存档里读出来的**两个关于仪器而不是关于设备的读数**（下一个阶段的对象）。

**接续**: [`163`](163-the-parameter-is-a-bool-and-the-guard-disarmed-its-own-undo.md)（baseline D：没有它，
这一页的判词会是上一页那个 `refuted` 的第三次重复）、
[`160`](160-the-third-heat-cause-had-an-experiment-and-no-installer.md)（这个安装器本体）、
[`121`](121-the-third-question-about-the-heat.md)（第三因是什么）、
[`153`](153-the-premise-was-false-and-the-answer-was-on-this-laptop.md)（机制是从源码读出来的）、
[`99`](99-the-remaining-heat-fix-was-broken-offline.md)（第一、二因的安装器）、
[`131`](131-the-bound-was-on-the-step-not-on-the-hang.md)（每一步的界，这一趟没有一步超时）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 为什么必须重启？ | 上一次开机的 cpuidle 计数器里装着**别人**（12:53 那次没撤销的写）的 162874 次进入，而计数器**自开机累加**、脚本清不掉。docs 163 的 baseline D 因此会在那台设备上拒绝——**它是唯一一条补救是重启的前置条件**。 |
| 重启风险大吗？ | 低，而且**这是这台机器上已知可用的路径**。RNDIS 在 20 秒内回来（`18d1:4ee7`，serial `33e80afe`），ssh 在 5 秒内回来，**没有进 EDL**。 |
| 重启后哪些东西还在？ | `download_mode=0`（02 的 panic guard，**它存在的理由就是跨重启**）、governor 的 unit、退休 keeper 的 unit、netwatch。**keeper 没有回来**——退休 unit 在开机时就把这一环解掉了。 |
| 基准干净吗？ | **干净**。新开机 `2fbf9f8e`，四个 CPU 的 `state1`/`state2` 是 `usage=0 time=0`，参数 `Y`、cmdline `1`。 |
| 判词是什么？ | `== verdict: supported-not-proven`：写之前 `state2` **0 次**，允许梯子的 120 秒里 **+2478 次**；`state0` 同期动了 **7234 次**（所以窗口里**有机会**）。 |
| 装上了吗？ | **装上了。** `06-lpm-fix` → `== verdict: installed`；`ExecMainStatus=0`、`is-active=active`、参数读回 **`N`**。 |
| 那"发烫解决了吗"？ | **三个成因现在都装上了**（第 6 节），而这一趟的 A/B 只覆盖前两个（第三因是在 06 才装的，A/B 在 03 就跑完了）——温度读数见第 5 节，**它是读数，不是判词**。 |
| 没做完的是什么？ | 这一趟的存档里，散热链的**结束状态那一行**有两个读数是关于**读者自己**的（第 5 节），而它之所以一直没被发现，是因为那条读数的 harness **把答案直接交给脚本**了。 |

---

## 2. 那次重启，和那个干净的开机

主机时钟 17:12:24Z 发出 `reboot`（先 `sync`）。之后（`uptime` 74 秒时）读到：

| 读数 | 值 | 说明 |
|---|---|---|
| `boot_id` | `2fbf9f8e-deea-4955-ad0c-6bddf0fb14f5` | **变了**（上一趟是 `693b2eed`，从 08:03 起没重启过） |
| USB | `18d1:4ee7`，serial `33e80afe-…-rndis` | RNDIS 回来；**没有** `05c6:9008` |
| ssh | 10.15.19.82 | 5 秒内回答 |
| `lpm_levels.sleep_disabled` | **`Y`** | 梯子是关的 → baseline **D 满足** |
| cmdline | `lpm_levels.sleep_disabled=1` | 与文件**一致**（这一次开机没有人写过它） |
| `msm_poweroff.download_mode` | **`0`** | **02 的 panic guard 活过了重启**——一个 panic 只会重启，不会进 EDL（A 满足） |
| keeper | **0 个**（argv 匹配） | 退休 unit 在开机时就解掉了它（C 满足） |
| `state1`/`state2` | 四个 CPU 全是 `usage=0 time=0` | **这就是"干净基准"的字面意思** |

`--status`（只读）在跑之前印的三行，也是这一页的起点：

```
  A. download_mode: all=0 (1 parameter(s))   <- ... (prerequisite A is MET)
  C. debug keeper: none -- C is MET
  D. sleep_disabled: ON (1 parameter(s))   <- the ladder is OFF at boot, so step 05's before-window IS a baseline (D is MET)
```

**这一行 D 是新的**（docs 163 第 8.4 节），而它在这台设备上第一次印出来就是 `ON (1 parameter(s))`
——也就是说，上一次的那个陷阱这一次**在跑之前就被读掉了**，而不是在跑完之后从判词里看出来。

---

## 3. 那一刻：`supported-not-proven`

`tmp-one-boot-20260925T171422Z/05-trial.txt`（INDEX：`ran: 2026-09-25T17:24:39Z`，
`boot_check: 6 of 6 steps re-read the identity   changed: 0`）：

```
== 4. the refusals, on their own terms (each leaves the device exactly as it was)
   all three prerequisites are satisfied and the before-window is a baseline, so this is a clean
   measurement; proceeding
...
== 10. the verdict
   before this boot's write, state2 (C2) had been entered 0 time(s)
   during the window it was entered 2478 more time(s), for 5652218 more of its counted time
   the shallowest state (state0) moved 7234 time(s) in the same window
   -> SUPPORTED, NOT PROVEN: with the ladder allowed, state2 was entered 2478 time(s)
      where it had been entered 0 times in the whole boot before. ...
      What this DOES settle is that the ladder is reachable on this device at all, which no image
      here had ever shown.
== verdict: supported-not-proven
```

三个数字的关系就是这一页的全部证据：

* **0 → 2478**：`state2`（全 SoC 的 `system-fpc` 那一级）在**这一次开机**上，参数是 `1` 的时候
  **一次都没进过**，参数写成 `0` 之后 120 秒里进了 2478 次。上一页那个 `refuted` 说的
  「它本来就在进」在干净基准上**不成立**。
* **7234**：同一窗口里 `state0` 动了 7234 次——**机会是有的**，所以 2478 不是"没有机会进"。
  这一条正是判词里那句 `NOT PROVEN` 的边界：它证明的是**可达**，不是**值多少**。
* **`supported-not-proven` 而不是 `supported`**：脚本的判词表里没有 `supported` 这一档，
  因为"打开之后进了 2478 次"和"打开它会省多少电/降多少度"是**两个问题**，而后者需要负载、
  需要 ambient、需要一个 A/B（第 5 节）。

---

## 4. 06 装上了什么

`tmp-one-boot-20260925T171422Z/06-lpm-fix.txt`：

```
licence: '.../05-trial.txt' ends with '== verdict: supported-not-proven' -- the trial says this
         parameter gates the ladder and that the run was clean, so the fix it measured is worth installing.
...
== the read-back, and it is the ONLY thing here that says the fix is in
--- the parameter, and the cmdline it disagrees with:
cmdline: lpm_levels.sleep_disabled=1
file:    /sys/module/lpm_levels/parameters/sleep_disabled = N
...
   the two answers the verdict is made of:
     ExecMainStatus = 0
     is-active      = active
     the parameter  = N
== verdict: installed
```

值得逐字记下的两点：

* **`cmdline=1` 与 `file=N` 不一致，而这正是"修好了"的样子。** docs 121 说这两个答案回答的是
  **不同的问题**（开机被**告知**什么 vs 驱动**现在**是什么），而第 6 节那段「不一致 = 有人写过」的
  旧解读在这里正好反过来用：**安装器就是那个"有人"**，它每个开机再写一次。
* **`N` 不是 `0`。** 这一页不需要再解释第三遍（docs 163），但值得注意：安装器自己的判词里
  已经写死了这句话（`It shows N and not 0 because the parameter is a bool module parameter`），
  这是上一页修完之后第一次在真机上被验证——`== verdict: installed` 是在一个读 `N` 的设备上打出来的。

`06` 的收尾也刻意写了**它不是什么**：`WHAT THIS IS NOT: a statement that the phone runs cooler.`
梯子从下一次开机起**可用**；SoC **用不用**那几级是 cpuidle 计数器的事，而**温度**是第三个读数。

---

## 5. 同一份存档里，两个关于**读者**的读数

这一趟的 `03-heat-chain.txt` 结尾：

```
== the chain finished -- what the device says now
     | netwatch: file=present fn=has-ensure_addrs unit=active
     | keeper: 287596
     | addrs: 192.168.2.15=1 10.15.19.100=0
     | governors: interactive interactive interactive interactive

  Read the governors line: ... And 'keeper: gone' with both addresses
  still 1 is the end state this chain exists to reach.
```

而**这一次开机上 keeper 从头到尾都是 0 个**——`01-capture` 自己的 `03-keeper-status.txt` 用的是
argv 匹配的读者，它印的是 `== the keeper process(es) and who started them / none running`，
`--status` 也印 `C is MET`。所以那行 `keeper: 287596` 是**假的**，而且它一直是假的。

**它是怎么假的，两次独立测出来**：

* 链里那段设备侧脚本要找的名字是 `*zl1-debug-init*` / `*zl1-debug-keeper*`，而**真 keeper 的路径是
  `/usr/local/sbin/zl1-debug-net.sh`**（`install-retire-debug-keeper.sh` 第 100 行 `KEEPER=`）。
  两个名字**都不是它**。
* 而那段脚本的**匹配方式是子串**（`case "$c" in *zl1-debug-init*|…`），它自己又是以
  `sh -c '<整段脚本>'` 送上去的——**所以它匹配的是它自己**。在设备上原样跑一遍那段循环：

```
keeper: 2356709
my pid: 2356709
```

**同一行的第二个读数也一样**：`addrs: … 10.15.19.100=0` 读的是 `ip -br addr show usb0`，
而这台设备上**没有 `usb0`**，并且 `10.15.19.82`（不是 `.100`）与 `192.168.2.15` **两个都在 `rndis0` 上**：

```
rndis0           UP             10.15.19.82/24 192.168.2.15/24
```

所以这条结束状态里有两处是**关于读者自己的假设**，而同一份文件下面那段散文还在说
「`keeper: gone` 与两个地址都是 1 是这条链存在的目的」——**那个状态在这一行里永远到不了**。

**为什么它的 harness 一直看不见。** `zl1-heat-fix-chain-selftest.sh` 里，这两条读数的答案是
**一个 fixture 文件**（`$W/state.txt`，由 ssh stub `cat` 出来）：

```
netwatch: file=present fn=has-ensure_addrs unit=active
keeper: gone
addrs: 192.168.2.15=1 10.15.19.100=1
governors: interactive interactive interactive interactive
```

也就是说 harness **把答案交给了脚本**，那段设备侧脚本**从来没有被执行过**——一段没跑过的代码，
它的名字写错、它的匹配匹配到自己，都不会红。这正是 docs 163 第 5 节那条规则的**反面**：
读者不需要 shim，但它**必须真的跑**。

这一条是**下一个阶段**的对象：把这段读者改成 argv 匹配 + 排除自身 + 从 `install-retire-debug-keeper.sh`
里**读出** keeper 的路径（而不是猜一个名字），把地址读成"这些地址在不在这台设备上"（而不是"在不存在的
`usb0` 上"），并且让 harness 的 ssh stub **真的运行**这段读回、给它一个假 `/proc`、一个只提到路径的
旁观者、以及一个 `sh -c <那段脚本本身>` 形状的进程——最后那个形状，就是这一页测出来的那个。

---

## 6. 三个散热成因的现状（都在设备上读出来的）

| 成因 | 装的东西 | 这一趟之后的状态 |
|---|---|---|
| ① 四个核被钉在 `performance` | `install-cpufreq-governor.sh` 的 unit | `governors: interactive interactive interactive interactive`——四个都读回来了（docs 99 的缺陷就是这一行曾经印 `on 0 cores` 而退出 0） |
| ② v63 debug keeper（~1 核） | `install-retire-debug-keeper.sh` 的 unit | **重启后 keeper 没有回来**（`none running`，`no lock directory`），而它负责的地址由 netwatch 接手（`ensure_addrs(): present`） |
| ③ 阶梯被 cmdline 关掉 | `install-lpm-sleep-fix.sh` 的 unit（**这一轮新装**） | `== verdict: installed`、`ExecMainStatus=0`、`active`、参数读回 `N`；执照是 05 的 `supported-not-proven` |

**温度**：这一趟的 A/B（`03-heat-chain/06b-heat-ab.txt`）在两个成因（①②）之后读到的
tsens 变化是 **−0.7 C 到 −1.9 C**（zone18 51.4→49.5 最大），同时 `systemd` 的 ticks 少了 972、
`dbus-daemon` 少了 143。**它只覆盖前两个**：链在步骤 03 跑，第三因在 06 才装上。
而这段读数本身带着它自己的 caveat（ambient、电池、这次开机的历史），**它不是判词**。

---

## 7. 这一轮**没有**做的事

* **没有刷任何分区**，没有动 boot 镜像，没有进 EDL，没有碰 modem/EFS/calibration/persist；
* **只重启**（用户授权），而重启是这条路径上**唯一**的动作——RNDIS 20 秒内回来、ssh 5 秒内回来、
  没有 EDL；
* **四个写都是安装器自己的**：02 的两个 unit 文件、03 的退休 unit + netwatch 构建 + governor unit、
  04 的 Android `/data` 下一个目录和一个 unit、06 的 applier + unit。加上 05 的那一次**参数写**，
  它按设计 revert 了（06 随后又把它写成 `0`，**那一次是安装器干的、有人认领**）；
* **没有对"手机变凉了"下结论**。第 6 节那段 A/B 是读数，而它的 caveat 就印在它旁边。

---

## 8. 阶段位置

**散热三因现在都装上了。** 这一页买到的不是"凉了"，是**一个可以被相信的判词**：
`state2` 在参数是 `1` 的整次开机里进了 0 次、在参数是 `0` 的 120 秒里进了 2478 次，
而同一窗口的 `state0` 动了 7234 次说明机会是有的。上一页的 `refuted` 于是被解释干净了：
它是**脏基准**的产物，不是这个参数的结论。

下一阶段：这一页第 5 节那两条**关于读者的读数**（散热链结束状态里的 keeper 与地址），
连同让它的 harness **真的运行**那段设备侧脚本——因为一条从来没有被执行过的读数，
它的名字写错、它匹配到自己，都不会红。
