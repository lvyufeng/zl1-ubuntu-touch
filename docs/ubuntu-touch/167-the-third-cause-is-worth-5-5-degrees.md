# 167 — 第三个成因量出来了：**5.5 °C**，而且控制窗口是**反方向**的

**日期**: 2026-09-25
**状态**: **在设备上跑了**一次（同一次开机 `2fbf9f8e`，没有重启、没有刷任何分区、没有写任何块设备）。
仪器写**一个文件**两次（`1` 挡住阶梯、`0` 放回来），trap 在每条退出路径上把它还回装机状态，
设备自己有 06-lpm-fix 的 unit 每次开机再写一次 0——**所以这个写入不可能活过一次重启**。
判词是 `COST-MEASURED`。

**接续**: [`166`](166-what-the-third-cause-is-worth-in-degrees.md)（这台仪器、三道拒绝 +
**补上的第四道**（panic→EDL）、以及这套三窗口设计为什么要第三个窗口）、
[`164`](164-the-third-heat-cause-is-installed-on-a-clean-baseline.md)（三因装上、稳态读数）、
[`163`](163-the-parameter-is-a-bool-and-the-guard-disarmed-its-own-undo.md)（bool 参数与字母表）、
[`122`](122-the-experiment-that-has-to-be-able-to-refute-it.md)（第一个实验与它的拒绝 A）。

原始输出: [`evidence/ladder-temp-ab-2026-09-25.log`](evidence/ladder-temp-ab-2026-09-25.log)。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 量到了吗？ | 量到了。**挡住睡眠阶梯，最热的 tsens zone 升 5.5 °C**（`tsens_tz_sensor8`：42.2 → 47.7），而**控制窗口回到 0.0 °C**。判词 `COST-MEASURED`。 |
| 控制窗口是"回到原处"吗？ | 不是——**它比 A 还低 0.7–1.3 °C**。这一点比 5.5 那个数字重要：这次运行期间手机在**变凉**（两个只读窗口一小时里从 45.6 漂到 50.9，这一趟是往下走的那一半），而窗口 B 仍然同时高出**两个** A 状态的窗口 2.6–5.5 °C。**效应比可用的漂移大，而且和漂移方向相反。** |
| 是全体一起动吗？ | 不是。**六个 SoC 传感器一起动了 2.6–5.5 °C**，第七个（`tsens_tz_sensor19`）**一动没动**（40.4 三次一模一样），电源轨（`pm8994_tz`、`pa_therm0`）只动 0.5–1.0 °C。所以这不是"整个机身被环境加热了"——那种情况不会只挑六个 SoC 传感器。 |
| 负载变了吗？ | 没变：busy **A 0.80 / B 0.79 / C 0.81** of 4 cores。这正是"阶梯在**空闲功耗**上起作用、而 busy 计的是活跃时间"的预期（脚本自己把这句话印在判词旁边）：**温度变了，而忙的时间没变。** |
| 设备安全吗？ | 同一次开机（`boot_id` 前后都读，没变），参数读回 `N`、`download_mode` 仍是 0、lpm unit `active`。写入是脚本自己还的（**读回验证**，不是承诺），而且下一次开机会再写一次 0。 |
| 这 5.5 °C 能推广吗？ | **不能**，脚本自己把限定印在判词里：一趟、一次开机、一个负载，环境温度和充电状态都没控制。第三个窗口只能抓住**活过窗口 B 的**漂移；一个正好在 B 里冲高、到 C 就消失的漂移，在这里和这个效应**无法区分**。 |

---

## 2. 数字

```
    zone       type                        A      B      C     B-A    C-A
    tsens_tz_sensor8                       42.2   47.7   40.9   +5.5   -1.3
    tsens_tz_sensor4                       41.2   44.8   40.3   +3.6   -0.9
    tsens_tz_sensor6                       41.2   44.5   39.9   +3.3   -1.3
    tsens_tz_sensor3                       41.9   44.8   40.9   +2.9   -1.0
    tsens_tz_sensor5                       41.9   44.5   41.2   +2.6   -0.7
    tsens_tz_sensor7                       41.2   43.8   40.3   +2.6   -0.9
    tsens_tz_sensor19                      40.4   40.4   40.4   +0.0   +0.0
    pm8994_tz（电源轨）                     37.7   38.2   37.3   +0.5   -0.4
```

busy: **A 0.80, B 0.79, C 0.81** of 4 cores。阈值 0.2 °C（仪器自己 0.1 °C 读数的两步）。

判词原文（脚本自己印的）：

```
   -> COST-MEASURED: blocking the ladder warmed the hottest tsens zone by 5.5 C (thermal_zone9 (tsens_tz_sensor8)), and
      putting it back did not leave that warming behind (C is 0.0 C above A). At this load, that is
      what the third heat cause is worth in temperature.
```

---

## 3. 为什么 `+2.6 … +5.5` 与 `-0.7 … -1.3` 合起来才是结论

两个窗口（A、B）会给出 **+5.5 °C**，然后把这次运行的漂移**记在阶梯头上**。
三个窗口给出的是一张**符号表**：

| | A 状态（窗口 A） | 阶梯被挡（窗口 B） | A 状态（窗口 C） |
|---|---|---|---|
| `tsens_tz_sensor8` | 42.2 | **47.7** | 40.9 |
| `tsens_tz_sensor3` | 41.9 | **44.8** | 40.9 |

C **低于** A。如果 B 的那 5.5 °C 只是"手机在这一分钟里变热了"，那么 C——**同样的状态、又过了 ~65 秒**——
应该继续热或者停在热的那一侧，而不是掉到 A 下面。它掉下去了，说明这一趟的**背景是在降温**；
而 B 仍然比**两个**同状态的窗口都高 5.5。**这个效应至少是 5.5，而且方向与漂移相反。**

这正是 [`112`](112-the-proof-is-a-race.md) 那条规则的另一面：**一个 A/B 在会漂的机器上不是"略差"，是"可以量出反号的结果"。**

---

## 4. 三道拒绝 + 补上的那道，在真机上全部走了**通过**的那一侧

`--status`（写任何东西之前）与 `--yes` 两次都印出：

```
   A. panic guard: all 1 download_mode parameter(s) read 0 -- a panic reboots, not EDL
   B. instrument: readable (/tmp/zl1-thermal.sh)
   C. parameter:  /sys/module/lpm_levels/parameters/sleep_disabled is writable
   D. as installed: 'N' -- sleep is NOT disabled, the ladder is ALLOWED (this is window A)
   C. write path: wrote 'N' back to itself and read 'N' -- writable.
```

**拒绝 A 是同一轮里补上的**（docs 166 §7）：仪器第一版写的是 trial 的**同一个参数**、同样的风险，
却把 trial 的panic→EDL 那道门整个漏掉了。它在这一趟上第一次真的跑了一遍，读数是
`/sys/module/msm_poweroff/parameters/download_mode = 0`、02 的 unit `active`。

三个状态都被**读回证明**过，三次都在输出里：

```
   wrote 1 and read 'Y' back: the ladder is BLOCKED from here until the undo.
   wrote 0 and read 'N' back: the ladder is ALLOWED again -- this is the state it started in.
   final state: .../sleep_disabled reads 'N' -- the fix is where this script found it.
```

`Y`/`N` 而不是 `1`/`0`——**字母表**（docs 163）：文件里存的是 `0`/`1`，内核的 sysfs `show` 渲染成 `N`/`Y`。
这一趟就是这条规则在真机上的第一次正面读数：**写入的字符串是 `1`，设备说的是 `Y`，而脚本按状态比。**

---

## 5. 这一趟的**限定**，以及它没有回答的问题

* **不是"阶梯值 5.5 °C"。** 是"**这一趟、这个负载（0.80 核忙）、这个环境温度和这个充电状态下**，
  挡住阶梯让最热的 SoC 传感器高 5.5 °C"。负载越忙，阶梯能省的那部分越可能被别的东西盖过。
* **没有量的**：长期效果（连续几小时、不同 ambient）、充电时的行为（充电器本身在加热电池和电源轨，
  这一趟 `pm8994_tz` 只动 0.5 °C，说明当时没在快充）、以及**这条写入对续航的影响**——
  这次只看了温度。
* **第三个窗口的盲区**：一个正好在 B 里冲高、到 C 就消失的漂移，在这个设计里和这个效应**无法区分**。
  这是脚本自己印出来的句子，不是这一页的免责声明。
* **没有重读的东西**：这一趟没有跑其它探针——相机、GPS、modem 的状态**仍然**是上一轮读的。

---

## 6. 阶段位置

三个散热成因都装上了（docs 164），**第三个的效果现在是量出来的**（这一页），不是推理出来的。
把三件事放在一起：

| 成因 | 修法 | 证据 |
|---|---|---|
| ① debug keeper 每秒 `systemctl` | 退休 unit，每次开机解掉 | keeper 每次开机都是 0 个 |
| ② 四个核钉在 `performance` | `install-cpufreq-governor.sh` | 四个核都读 `interactive` |
| ③ SoC 被禁止用低功耗阶梯 | `install-lpm-sleep-fix.sh` + 06 的 unit | 参数读 `N`，**而且这一页量出了它在-温度上的价钱** |

散热这一条现在可以说的话是：**三个成因都在，第三个值约 5.5 °C。**
还不能说的话是：**"这台机器不发烫了"**——那需要一次长时间、有负载、带充电状态的观察，
而那正是这一趟明确没有做的事。

下一个阶段回到硬件清单上还没有驱动起来的那几项——
**指纹的驱动已经编进 `halium-boot-zl1-v63-fpdriver.img` 但还没刷**、
**GPS 第一个客户端那扇门**（要人点一下）、**modem 一次真机读数都没有过**，
以及**相机 app 上没上屏**（doc 166 更正过：以前那句"预览上过屏"说的是 `test_camera`，不是 UT 的 app）。
