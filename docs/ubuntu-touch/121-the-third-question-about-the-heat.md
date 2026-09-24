# 121 — 发烫的第三个问题：**SoC 到底允不允许睡觉**

**日期**: 2026-09-24（含当晚的一次更正，见 §5.5）
**状态**: 本轮**没有碰设备**（设备仍在 EDL，见 §7）。全部在 host 侧：给发烫问题找出了**第三个、与前两个
互不相干的原因**，并为它写了一件新的只读仪器（`scripts/device/zl1-sleep-and-throttle.sh`）+ **107 检查**的
离线 harness。**没有安装任何东西，没有 flash，没有写分区；这件仪器读的文件里有四个是可写的，
它一个都没写——而且 harness 用逐字节的清单证明了这一点。**

> **本轮的更正（§5.5）**：这篇的第一版把 `lpm_levels.sleep_disabled` 判成内核的 **`__setup` 启动参数**，
> 因此说"设备上只能读 `/proc/cmdline`"。**那是错的**：把 boot 内核的 `__param` 段按 `struct kernel_param`
> 解出来，它是一条**内置驱动的模块参数**，权限位 **0664 = 可写**。所以第三个原因的修法不是重刷 boot，
> 而是**一次运行时写入**——不用 flash、不用重启、同一个 boot 里就能量、能退回。更正的过程与标定
> 记在 §5.5 和 [`evidence/lpm-sleep-disabled-param-2026-09-24.txt`](evidence/lpm-sleep-disabled-param-2026-09-24.txt)。

**接续**: [`118`](118-the-heat-fix-chain-is-one-command-on-one-boot.md)（发烫修复是一条命令，一个 boot）、
[`99`](99-*.md)（governor：镜像把四个核钉在 `performance`）、
[`96`](96-*.md)（三个温度单位，和那件温度仪器）、
[`72`](72-*.md)（发烫诊断与 v63 debug keeper）、
[`120`](120-the-subsystem-nobody-has-looked-at.md)（上一轮：modem 的仪器与那条被 cmdline 推翻的假说）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 这一轮做了什么？ | 找到了发烫的**第三个原因**，并把"**是它在起作用吗**"变成一件**只读、离线可验证**的仪器 |
| 前两个原因是什么？ | ① v63 debug keeper 每秒 `systemctl` 一次，占住一个核（docs 72/94/99）；② 镜像把四个核**全钉在 `performance`**（min == max == 最高档，docs 99）。**两个都还没装上** |
| 第三个原因是什么？ | **SoC 自己的省电阶梯被关掉了。**每一条 zl1 cmdline 都带 `lpm_levels.sleep_disabled=1`，而每个 zl1 DTB 都**完整地**描述着那个被它关掉的阶梯 |
| 为什么这条和那两条**不一样**？ | 那两条是**需求侧**（有人在烧 CPU、频率被钉死）。这一条是**供给侧**：**什么都不做的时候，硬件也被禁止进入低功耗状态** —— 所以手机**空转也热**，而那两个修复**一个都碰不到它** |
| 离线证据是什么？ | ① **DTB**：`soc/qcom,lpm-levels` 下有 system-wfi / system-ret / system-fpc（整颗 SoC）、两个 cluster 的 L2 档、以及每核的 wfi/retention/pc；② **cmdline**：**原厂**镜像那条（docs 20 第 33 行）就带 `lpm_levels.sleep_disabled=1`，v63 逐字继承；③ **内核**：把它解压出来，`lpm_levels.sleep_disabled` 出现在内核的 `__param` 段里，按 `struct kernel_param` 解出来是 `{name, ops, mode, arg}`，**mode = 0664 = 可写** —— 它是内置驱动 `lpm_levels` 的**模块参数**，不是启动参数（§5.5 是更正的过程） |
| 这改变了什么？ | **修法的风险等级。** 如果它是启动参数，唯一的修法是换 cmdline → **新 boot 镜像 → flash**；它既然是可写的模块参数，修法就是 `/sys/module/lpm_levels/parameters/sleep_disabled` 上的一次**写入**：**不用 flash、不用重启，一个 boot 里可以量了再退回。**（它旁边那条 `cpuidle.off` 是 **0444**，只能在命令行上给——这个不对称正是分界线。） |
| 那这算结论吗？ | **不算。**这是一条有名字的机制的**假说**：**参数的名字是"意图"的证据，cpuidle 的计数器才是"行为"的证据。**仪器打印的是**行为**，"写 0 之后阶梯是否真的回来"要设备上的前后对比 |
| 这一轮真的修了什么？ | **两个仪器缺陷**，而且第二个是这条仪器存在的意义的反面（§5.1）：DT 阶梯被按**固定三层深度**匹配，**静默漏掉了最深的三个 system 档**（正是整件事的关键）；以及 `--quiet` 会让**判定**跟着变（quiet 运行会把刚读成功的 cpuidle 报成 UNKNOWN）。**③ 加上 §5.5 的那次更正**：第一版把参数判错成了启动参数，于是**唯一能读它的地方**也判错了 |
| 离线验证？ | `zl1-sleep-and-throttle-selftest.sh` **107 检查 / 0 失败**；harness 自身 3 个缺陷（§5.3）+ 新增一条针对"写 `sleep_disabled`"的牙齿（§5.2） |
| 家族全量跑呢？ | **1714 检查**（16 个 harness），红了一条 —— 在**别的** harness 里，而且**设备没有错**：一条断言在整份输出里找三位数字，而那份输出里含**这台笔记本的 uptime**（§5.4）。两半都修了，installers harness 从 375 涨到 **377 检查**，全家族现在是 **16 个 harness / 1736 检查 / 全绿**（§5.5 的更正又给这件仪器加了 19 条检查） |
| 动设备了吗？ | **没有。**仪器**从来没有在设备上跑过**；设备仍在 EDL |

---

## 2. 为什么前两个修复可能不够

已有的两个修复各自对应一个**真实的**原因，而且都还没有装上（docs 118）。但它们是同一个方向上的两件事：

* **谁在烧**：v63 debug keeper，每秒 `systemctl` 一次，约一个核（docs 72/94/99）；
* **烧多快**：四个核全在 `performance`，也就是 min == max == 最高档，永不降频（docs 99）。

两个都是**需求侧**：有人要 CPU，或者 CPU 的调度策略不降频。而"这台机器很容易发烫"这个描述里还有另一半，
是这两个修复**结构上碰不到**的：**它闲着的时候热不热。**

设备树的答案很明确 —— 这颗 SoC **有**一整套低功耗阶梯：

| 层级 | 节点 | 档 |
|---|---|---|
| 整颗 SoC | `soc/qcom,lpm-levels/qcom,pm-cluster@0/qcom,pm-cluster-level@N` | `system-wfi`（100 us）→ `system-ret`（350 us）→ `system-fpc`（11000 us） |
| 大核 cluster 的 L2 | `.../qcom,pm-cluster@0/qcom,pm-cluster-level@N` | `pwr-l2-wfi` → `pwr-l2-gdhs` → `pwr-l2-fpc` |
| 小核 cluster 的 L2 | `.../qcom,pm-cluster@1/qcom,pm-cluster-level@N` | `perf-l2-wfi` → `perf-l2-gdhs` → `perf-l2-fpc` |
| 每个核 | `.../qcom,pm-cpu/qcom,pm-cpu-level@N` | 每核 wfi / retention / power collapse（20/40/80 us） |

（从 `/boot` 里的 DTB 逐节点读出来的，**那五个 DTB 里每一个都这样**。）其中 `system-fpc` 是**整颗 SoC 的
full power collapse** —— 就是"待机时把芯片真的关掉"的那一档。

而**它被关了**：

```
lpm_levels.sleep_disabled=1
```

这一行在**原厂**镜像的 cmdline 上就有（[`20`](20-stage2-runbook.md:33) 第 33 行，当年为了别的目的记下来的），
`scripts/make-v63-boot-image.sh` 的 `V63_CMDLINE` **逐字继承**。它不是这个 port 加的，是第三方 ROM 带来的
（`/boot` 那份是 MIUI，见 docs 120 §3.5），而 port 拿它当"标准 Android 启动参数"继承了。

### 2.1 为什么必须用"行为"而不是"参数名"来下判断（本节已更正，见 §5.5）

这一节的第一版说：`lpm_levels.sleep_disabled` 是内核 `__setup` 表里的**启动参数**，所以设备上唯一能读它的
地方是 `/proc/cmdline`，`/sys/module/lpm_levels/parameters/` 里没有它。**那半句是错的**（§5.5 是把
`__param` 段解出结构的经过）：它是**内置驱动 `lpm_levels` 的模块参数**，权限位 **0664**，
所以设备上**两个地方都能读**，而且第二个是**可写**的：

```
/proc/cmdline                                    这次 boot 被交代了什么
/sys/module/lpm_levels/parameters/sleep_disabled 驱动现在是什么值   <- 0664，可写，修法就在这里
```

两个都要读，因为它们回答的是**两个问题**，而且**可以不一致**：不一致就说明有人在 boot 之后写过它
（**那正是修复的样子**），或者驱动没有消费那条 cmdline。仪器打印两个，并且明说哪个是哪个。

真正没变的那条原则：

* **它到底做了什么，写在源码里，而源码不在设备上。**所以仪器**不声称**知道参数做什么，只量**发生了什么**：
  cpuidle 的每个状态被进入过多少次、待了多久。参数名是**意图**的证据，计数器是**行为**的证据，两者读在一起。
  尤其：**`0664` 只证明这个文件能写，不证明写下去有用**——"写 0 之后阶梯有没有回来"是设备上的前后对比。

---

## 3. 那些离线读数（全部只读，命令都在 evidence 里）

evidence： [`evidence/sleep-and-throttle-offline-readings-2026-09-24.txt`](evidence/sleep-and-throttle-offline-readings-2026-09-24.txt)

| 读数 | 怎么读的 | 说了什么 |
|---|---|---|
| 5 个 DTB，每个都有 `qcom,lpm-levels` | 从 `boot.img` 里找 FDT magic（`d00dfeed`）切出来，再按 FDT 结构逐节点走 | 阶梯**存在**，而且是**完整的**（含整颗 SoC 的 fpc） |
| 每档的 `label` 和 `qcom,latency-us` | 同上 | 从 wfi（100 us）到 fpc（11000 us），**退出延迟**越大越省电——这正是"闲着的时候"该用的东西 |
| cmdline 带 `lpm_levels.sleep_disabled=1` | `docs/ubuntu-touch/20-stage2-runbook.md:33`（原厂）+ `scripts/make-v63-boot-image.sh:67`（v63） | **原厂就带着，port 逐字继承** |
| 内核里这个参数**是什么** | boot kernel 解压后，找到引用这五个字符串的指针表，按 `struct kernel_param`（32 字节：`{name, ops, perm:u16, level:s8, flags:u8, arg}`）解码 | 它们在 `__param` 段里，**不是** `__setup`（后者是 16 字节的 `{str, fn}`，没有 ops、没有权限位） |
| 它是**可写**的吗 | 同一张表里解码出的 `perm`：`lpm_levels.sleep_disabled` = **0664**；旁边 `cpuidle.off` = **0444** | **可写。**所以修法是运行时写入，不是新 boot 镜像 |
| 这个解码器可信吗 | 同一段、同一个解码器跑在**已知**的参数上：`usbcore.autosuspend`、`usbcore.usbfs_memory_mb` → 0644；`nousb`、`usbcore.blinkenlights` → 0444 | **解码器在已知答案上复现了已知答案**，所以它对未知那一条给出的答案才值得拿来做决定 |
| 内核里有 `msm_thermal` 和 `qcom,lpm-levels` | 同一份解压内核 | 两条路都在编译进去的驱动里 |
| 一条名字带前缀，说明什么 | `lpm_levels.sleep_disabled` 是**带点前缀**注册的 | 内置驱动（`MODULE_PARAM_PREFIX` = `KBUILD_MODNAME "."`）——而 sysfs 正是把这个前缀剥掉去建路径的：`<模块名>/parameters/<剩下的>` |

顺带（与本篇无关但值得记）：把内核解压出来这件事本身有个坑 —— `boot.img` 的 kernel 段**后面还接着 DTB**，
所以 `gzip.decompress()` 会以 `BadGzipFile` 收场。要用 `zlib.decompressobj(31)` 读到流的结尾，
`unused_data` 就是那 2 MB 的 DTB。这条坑记在 evidence 里。

---

## 4. 仪器：它问什么，以及它**绝对不**做什么

`scripts/device/zl1-sleep-and-throttle.sh [--status] [--quiet] [--explain]`，7 节：

1. **这次 boot 被交代了什么，以及驱动现在是什么值** —— 两个读数，因为这是两个问题：
   `/proc/cmdline` 里 power 相关的参数**整行打印**（值是重点：`lpm_levels.sleep_disabled=1` 是一句话，
   "参数存在"不是），`sleep_disabled` **单独再点一次名**（它"没被设置"是一条明确的读数，而不是
   "那一行不在那里所以没注意到"）；以及 `/sys/module/lpm_levels/parameters/` 的**泛读**（不假设参数名）
   加 `sleep_disabled` 的值与**权限位**。两个读在一起，**不一致**就那么印出来：不一致意味着有人在 boot
   之后写过它，或者驱动没消费那条 cmdline。`--quiet` 只影响打印，两条读数**都**照样取。
2. **硬件到底有什么阶梯** —— 从**活的** `/proc/device-tree/soc/qcom,lpm-levels` **递归**走一遍，
   打印每档的 `label` 和 `latency-us`。**阶梯存在但没被用**，和**阶梯不存在**，是两个不同的发现。
3. **后果，也就是真正的证据** —— cpuidle：driver，然后每个核每个状态的 `name`/`usage`/`time`/`disable`。
   最深那一档的占比打印成**比例**：`time` 的单位 sysfs ABI **没有写**，而比例把单位约掉了 —— 这台设备的
   三个温度区用了三种单位（docs 96），所以一个没有单位的计数器不该被拿去做算术。
4. **内核自己在做什么** —— `/sys/module/msm_thermal/parameters/*` **按目录泛读**（不假设参数名），
   以及 `/sys/class/thermal/cooling_device*`：**一个都没有注册**，所以 cooling-device 那一半的
   限流框架**没有东西可以限**（这正是 `install-cpufreq-governor.sh` 在注释里记过的状态）。
5. **温度区在内核眼里的样子 —— 而且故意不打印它们的温度** —— 只打印数量、`type`、`mode`、`policy`。
   `mode` 是没人读的那个：`disabled` 的 zone 的 trip **不会触发**。温度**不在这里打印**是刻意的：
   这台设备的 zone 不共享单位，而 `zl1-thermal.sh` 拥有那张表 —— **第二份表就是第二次搞错的机会**。
6. **cpufreq 现在的样子** —— 每个核的 governor、cur/min/max、以及是否 online。这就是"两个已知的发烫修复
   装上了哪一半"的读数。
7. **verdict：三个原因各自一行**，各自**PRESENT / ABSENT / UNKNOWN** —— 因为它们是**独立的**，
   而"手机很热"这句话**说不出是哪一条在跑**。UNKNOWN 是"某条读数没取到"，它让脚本 `exit 1`：
   那是关于**仪器**的答案，不是关于手机的。

### 4.1 安全线：这件仪器读的四个文件**是可写的**

前面几件仪器的安全线是"什么都不写"。这一件要更小心一点，因为它读的里面**有四个文件在设备上是可写的**：

```
/sys/devices/system/cpu/cpu*/cpuidle/state*/disable     # 写 1 就是不让用这一档
/sys/class/thermal/thermal_zone*/mode                   # enabled / disabled
/sys/class/thermal/thermal_zone*/policy                 # step_wise / power_allocator
/sys/module/lpm_levels/parameters/sleep_disabled        # 0664 —— 这一个就是本问题的"修法"本身
```

**这四个正是"顺手修一下"的典型目标**：一个来查"为什么这么热"的脚本，看到 `disable=1` 或者
`mode=disabled`，很自然会想把它打开再量一次；而第四个更直接——**它就是这件探针在问的那个问题的答案**，
写一行 `0` 就是"修好它"。**这里一行都不写。**改它是一次**决定**，不是一次**读数**，而这次决定不该由一件
探针来做。仪器只读，harness 用**逐字节的清单**证明它只读（§5.2），静态 guard 针对**四个**文件各有一条牙齿，
`--explain` 里也明写这四个文件的名字。

---

## 5. 离线验证：107 检查，和它抓到的缺陷

`scripts/host/zl1-sleep-and-throttle-selftest.sh`：**107 检查 / 0 失败**。

传输层与前几件一样：**stub 目录就是设备**，`PATH` 指向 `$STUB:$MINBIN`（沙箱里是真 coreutils 的软链，
没有 `gdbus`），`/proc`、`/sys` 被**两趟 token 改写**进一个假根，并且断言"第一趟的 token 数 == 第二趟的
假根路径数"。

### 5.1 三个**仪器**缺陷

| 缺陷 | 它本来会造成什么 |
|---|---|
| DT 阶梯按**固定三层深度** glob（`$L/*/*/qcom,pm-cluster-level@*` 等） | **静默漏掉最深的三个 `system-*` 档** —— 也就是这一整件事的关键那三档。假设备上 8 档只报出 5 档，而**没有任何一行说它漏了**。这正是"一件仪器**自己制造出来的**错误答案"。现在改成**递归**遍历，harness 把 `system-ret` 那一档**按名字**钉成断言 |
| 把参数判成 `__setup`（**§5.5**），并因此用一行**断言**把 `/sys/module/lpm_levels/parameters/` 排除掉 | 排除了**唯一可写、因而唯一能被修**的那个读数，还把修法从"一次写入"抬成"一次 flash"。**这条缺陷的形状值得单独记：它不是读错了设备，是把一个推断写成了读数。** |
| `--quiet` 让**判定**跟着变 | 每个核的循环体在 `--quiet` 下直接 `continue`，于是统计量停在初值，**一次 quiet 运行会把刚刚成功读到的 cpuidle 报成 UNKNOWN**。合同是"`--quiet` 改变**显示什么**，不改变**判定什么**"，现在循环体永远统计、只有打印被 guard，并且 harness 断言"quiet 与 loud 的**退出码相同**" |

### 5.2 "它什么都不写"有**两条**牙齿，而第二条才是保证

* **静态检查**：对**发出去的源码**做正则（不许写 `/sys`、`/proc`、块设备，不许 `dd`/`mount`/`modprobe`
  出现在命令位置，不许改状态的 `systemctl`），外加两条**反向**牙齿：箭头后面的路径是散文不是重定向
  （`-> /proc/cmdline could not be read`），而真正的重定向**仍然要被抓到**。四个可写文件**各有一条正方向
  牙齿**：thermal zone 的 `mode`、cpuidle 的 `disable`、以及**最诱人的那一条** ——
  `printf "0" > /sys/module/lpm_levels/parameters/sleep_disabled`（它离读它的那行只有一个字符远，
  而且"阶梯回来了没有"正是读这份文件的人脑子里装着的那件事）——三条都必须被抓到，抓不到就是**红**。
* **行为检查，而且是更强的那条**：静态正则有一个**已知盲点** —— 它只看得到写向**绝对设备路径**的操作，
  而一个脚本可以用变量写：`printf 1 > "$s/disable"`。**任何正则都分不出这个和一次读**，因为信息在
  `$s` 被赋值的地方。所以真正的保证是**逐字节清单**：跑一次仪器，要求假设备**一个字节都没变**
  （结构 + 大小 + 每个文件的 md5）。**并且清单本身要有牙**：在两个快照之间**手动改一个字节**，清单必须
  看见 —— 这条也断言了。

第二条牙齿**当场就抓到了东西**，而且抓得有价值：改一个字节那一步用的正是 fixture 的
`scaling_governor`，而它暴露出 fixture 自己在两个本该相同的运行之间**变了**（大小 12 → 1）——
原因是 `case "${FAKE_GOV:-performance}"` 的**分支体**里写的是裸 `$FAKE_GOV`，而 harness 把它 export 成
**空串**，于是写出了"governor = 空"。**是清单抓到 fixture 的错**，不是任何断言。

### 5.3 三个 **harness 自身**缺陷

1. **fixture 忘了建它自己要写的目录**：`lv()` 写的是 `mkdir -p "$(dirname "$1")"` —— 建了**父目录**，
   然后把文件写进一个**从没建过**的目录。结果是假设备**根本没有任何阶梯**，而 section 2 会报"走了一遍
   什么都没找到"。**一个静默地测试'被设置好的东西不存在'的 fixture**，正是 docs 119 §5.2 记过的形状。
2. **断言用了一个不可能通过的正则**：`\|` 在 ERE 里是**字面竖线**，不是选择符，所以那一条断言
   **永远不可能通过**（也永远抓不到东西）。拆成两条独立的断言。
3. **`(no online file: cpu0)` 与实现不符**：探针的文案改过一次，断言没跟着改 —— 同族的老问题
   （断言在测它**以为**在读的那句话）。现在断言与实现对得上，并且 cpu3 有一条 `online=0` 的真读数。

### 5.4 顺带：家族全量跑出来的那一条红，红的不是设备

把整个 harness 家族跑一遍（16 个，**1714 检查**），红了一条，在**别的** harness 里：

```
NOT GREEN: zl1-installers-selftest.sh[pass=374 fail=1]
FAIL  and neither is the grep
        | zl1-retire-keeper: retiring keeper pids=[900 905] ... uptime=2290419s matched= [900: ...] [905: ...]
```

**决定是对的**（`pids=[900 905]`，正是该杀的那两个），红的是断言。那条断言原本是
`notwant '904' "$OUT"` —— 在**整份输出**里找这三个数字。而这一行里有一个**没有任何场景能控制**的数字：
`uptime=$(cut -d. -f1 /proc/uptime)s`，读的是**这台笔记本自己的** uptime。原因是 harness 给 applier
做路径改写时**漏了 `/proc/uptime`**（applier 的这份副本因此有一半在读 host 的 `/proc`）。于是：

* 那台机器的 uptime 是 `22904xx` 时，`22904xy` 里含着 `904`，这条断言**就红** —— **每 1000 秒里有 100 秒**；
* **设备上什么都没有错。**这是一条**定时炸弹式的断言**：它之前每一次家族全量跑都是绿的，只是**那几次的秒数不对**。

两半都修了，而且修的是各自那一半：

| 修哪里 | 怎么修 | 牙齿 |
|---|---|---|
| **fixture**：applier 副本漏改 `/proc/uptime` | 加进改写表，并**断言改写落地**（`grep -qF "$FR/proc/uptime"`） | 新增一条读数断言：退休那行的 uptime 必须是假设备的 `100s`，**不是这台笔记本的** |
| **断言**：在整份输出里做子串搜索 | 新增 `matched_pids()`：只取 `matched=` 字段里的 pid；`903`/`904` 两条改成对它断言 | 先断言这个提取器**恰好**给出 `900 905` —— 因为**对一个空串做"不包含"永远通过**，那正是"断言在测'被设置好的东西不存在'" |

这条值得记在**这一篇**里，因为它和 §5.1 是一条原理：**一件仪器/一条断言，如果它的答案里混进了一个
和问题无关、又不受控的量，那它测的就不是它声称在测的东西。**上一节是探针漏报了三档 DT 阶梯，这一节是
断言把 host 的秒数当成了 pid。

修完之后，全家族 **16 个 harness / 1717 检查 / 0 失败**；§5.5 的更正把这一件从 88 加到 **107 检查**，
收尾时全家族是 **1736 检查 / 0 失败**。

### 5.5 那次更正：它不是启动参数，是一个**可写**的模块参数

第一版把一个**载重**判断搞错了：它说 `lpm_levels.sleep_disabled` 是内核的 `__setup` 启动参数，
因此设备上只有 `/proc/cmdline` 能读它。**这个判断之所以重要，是因为它决定修法的风险等级**：

| 如果它是 | 修法就是 | 代价 |
|---|---|---|
| `__setup` 启动参数 | 改 cmdline → **新 boot 镜像** | **一次 flash**（本项目最怕的那件事） |
| **模块参数**（实际是） | 写 `/sys/module/lpm_levels/parameters/sleep_disabled` | **一次写入**：不 flash、不重启、一个 boot 内可量可退 |

更正的办法是**去解结构**，不是再猜一次字符串。第一版只做了 `strings` 级别的观察——看到
`lpm_levels.sleep_disabled`、`sleep_time_override`、`menu_select`、`cpuidle.off` 挨在一起，就当成
"同一张 `__setup` 表"。**"字符串挨在一起"不是表。**这一轮改成：

1. 解压 boot kernel（`zlib.decompressobj(31)`，坑见 §3）。
2. 定出加载基址——**靠一致性推出来，不是挑一个**：扫描所有高位地址的 8 字节字，找一个常数 `A`，使
   `A + （五个字符串各自的文件偏移）` 都**是**这个镜像里的字。答案 `0xffffffc000080000`，**5/5 命中**。
3. 找到引用这些字符串的指针表，按 `struct kernel_param` 解码。

结果是**两张**表，而且只有一张是参数表：

| 表 | 步长 | 解码成 | 判定 |
|---|---|---|---|
| `0x126xxxx` | 8 字节，邻居就是那些字符串本身 | 按 32 字节结构读出来是乱码（"权限位" `0o126550`） | **不是**参数表 |
| `0x179xxxx` | 32 字节，`cdc_ncm`/`usbcore`/`lpm_levels`/`mmc_core` 连成一片 | `{name, ops, mode, arg}` 全部落在该落的地方 | 内核的 `__param` 段 ✔ |

关键的一行：

```
@0x179d980 name=cpuidle.off                ops=...a638 perm=0444 arg=0xffffffc001c45944
@0x179d9a0 name=lpm_levels.sleep_disabled  ops=...a578 perm=0664 arg=0xffffffc001c45a31
```

**旁边那条 `cpuidle.off` 是 0444（只读，只能在命令行上给），而 `sleep_disabled` 是 0664。**
这个不对称不是巧合，它就是"要不要 flash"这条分界线。

而**让这个解码算读数、而不是巧合**的是标定：同一个解码器、同一套偏移，跑在**已知答案**的参数上——

```
usbcore.autosuspend      0644   <- /sys/module/usbcore/parameters/autosuspend，人人都知道可写
usbcore.usbfs_memory_mb  0644   <- 同上
nousb                    0444   <- 只读
usbcore.blinkenlights    0444   <- 只读
```

还有一条印证：`sleep_disabled`、`print_parsed_dt`、`menu_select` 三个的 `arg` 是 **`.data` 里三个相邻的
字节**（`…a30` / `…a31` / `…a32`），共用同一个 `ops` —— 这就是三个相邻的 `static bool` 的样子。

**这次更正的另一半代价，是仪器自己。**第一版的 section 1 只读 cmdline，而且用一句**断言**把
`/sys/module/lpm_levels/parameters/` 排除掉了——**那不是设备上的读数，是推断**，而它推断反了。
现在 section 1 读**两个**，并且**明说哪个是哪个**：cmdline 是"boot 被交代了什么"，sysfs 是"驱动现在是什么"，
两者**不一致**时（有人写过／驱动没消费）就当一条读数印出来。verdict 的第 3 条原因现在**以 sysfs 为准**
（那才是活的值、才是修法会改的地方），cmdline 读不到时不再把整条原因判成 UNKNOWN——**半边可读就够了**，
但必须**说**出另外半边没读到。

新增的检查里，专门有一组是这些**不一致的形状**——(a) cmdline 没有这个 key 而驱动仍是 1、(b) 两边都说
阶梯允许（**只有这一种形状配得上 ABSENT**）、(c) cmdline 仍要求关而驱动已经是 0（**这正是修复的样子**）、
(d) 参数文件不在而目录在、(e) 整个 `lpm_levels` 目录不在、(f) cmdline 读不到但活值能读、(g) 两半都读不到。
**每一种都必须落到它自己的读数上，而不是落到离它最近的那个。**

---

## 6. 这一篇**不**证明什么

* **不证明"省电阶梯被关掉"就是发烫的原因。**它证明的是：**阶梯在 DT 里、参数在 cmdline 里、文件在设备上
  可写**，而**设备上还没量过**。这是一条有名字的机制的假说，不是发现。
* **不证明参数 `sleep_disabled` 的语义。**那是源码的事，源码不在设备上。仪器量的是**行为**（计数器），
  并且**故意**把两者分开打印 —— 参数是意图，计数是事实。**权限位 0664 只证明这个文件能写，
  不证明写下去有用**：那个要"写 0 → 再看计数器"的前后对比。
* **不证明 `msm_thermal` 没在限流。**DT 里那个节点的 trip（poll 100 ms、90 °C 降频到 768 MHz、
  100 °C 热插拔、105 °C 热复位）都在，而 `install-cpufreq-governor.sh` 记过"**没有任何 cooling device
  注册**"。这两件事怎么共存，要设备上的读数（第 4 节打印参数，第 5 节打印 zone 的 mode）。
* **不证明探针在真机上不会出错。**它只在假设备上跑过。

---

## 7. 设备状态与下一步

整轮没有动设备：没有写任何分区或 boot，没有跑 QDL/QFIL，没有重启，没有绕过权限。设备仍在 **Qualcomm EDL**
（`05c6:9008`，无序列号）；唯一的出口是**物理长按电源 10–20 秒**（只有用户能做）。

新探针接进了 **`zl1-post-recovery-capture.sh` 的默认集（第 04c 步）**，理由和 04b 一样：**只读、从不打开
块设备、不需要人**，所以那次"用一根手指换来的 boot"应该顺带把它带上。capture 的 harness 从 136 涨到
**139 检查**，并且默认集的步数断言（七步、八个归档输出、五次 push）一起改了 —— **顺序断言是逐位断的**
（`sed -n '5p'` / `'6p'` / `'7p'`），所以新步骤插在中间不会被"总数没变"这种断言放过。

```
# 0. 先出 EDL：物理长按 POWER 10–20 秒，等 RNDIS 和 ssh
scripts/host/zl1-post-recovery-capture.sh            # 0 系列；MODEM 是 04b，SLEEP 是 04c，都在默认集里
scripts/host/zl1-heat-fix-chain.sh --status          # 只读：发烫链条的四个问题
scripts/host/zl1-heat-fix-chain.sh --yes             # 部署 → 激活 → 90 s → 地址证明 → 退役 keeper → governor
```

**发烫那三个原因，回来的那一次能一次全读出来**：keeper 的 pid 和 ticks 由 capture 的 0 系列抓
（docs 94，杀掉之后就没了），governor 由 04b 之后的 04c 第 6 节读，**"能不能睡"由 04c 第 1/3 节读**
（cmdline 与 sysfs 两个值一起读，不一致会明说）。

而**第三个原因的修法现在比这一篇动笔时便宜得多**：§5.5 的更正把"要换 boot 镜像、要 flash"换成了
**一次写入**。设备回来的顺序因此可以是：`zl1-post-recovery-capture.sh`（顺带把 04c 的前值取下来）
→ `zl1-heat-fix-chain.sh --yes`（前两个修复）→ **写 `0` 到
`/sys/module/lpm_levels/parameters/sleep_disabled`，再跑一次 04c 看计数器** —— 前后对比就是这条假说的
判决，全程不 flash、不重启，读不回来就写回 `1`。

**这一步还没有装成一条命令，也还没有在设备上跑过。**在那之前，这一篇里的一切仍然只是
**离线可以核对**的东西。
