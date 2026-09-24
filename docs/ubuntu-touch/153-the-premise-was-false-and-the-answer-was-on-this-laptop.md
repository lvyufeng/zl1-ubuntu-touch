# 153 — "内核源码不在这台设备上" 是假的，而答案一直在这台笔记本上

**日期**: 2026-09-24
**状态**: 本轮**没有碰设备**。这一页把散热第三因（docs 121）的**机理**从**内核源码里读出来**，
而不是继续假设它；顺手修好了健康页的一个**把 fastboot 当成 RNDIS** 的误判，以及本轮自己的几处真缺陷。
新工具 `scripts/host/zl1-lpm-sleep-semantics.sh` 与它的 harness（**102 项**）。

**接续**: [`121`](121-the-third-question-about-the-heat.md)（第三因：`lpm_levels.sleep_disabled=1`）、
[`152`](152-a-reading-is-only-as-good-as-the-identity-of-its-input.md)（读数只和它读的那个文件的身份一样可信）、
[`151`](151-the-question-that-was-filed-as-unreadable-offline.md)（同一个错误的上一次：把"我看了另一个文件"写成"这里读不出来"）、
[`134`](134-the-false-fail-was-in-the-pipeline-s-writer.md)（`printf | grep -q` 在 pipefail 下报的是写者的死）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 这一轮回答的是什么？ | `lpm_levels.sleep_disabled=1`（散热第三因）**到底做了什么**——docs 121 只到"这个参数让 SoC 不许睡"，没到"它让 CPU 执行哪条指令" |
| 它到底做了什么？ | 参数**只有一个**闸门点：`cpu_power_select()` 里 `if (sleep_disabled \|\| sleep_us < 0) return 0;`——返回的 `0` 是**层级下标，不是布尔**；这个下标被 `lpm_cpuidle_enter()` 原样带进 `psci_enter_sleep()`，而那里的 `if (!idx)` 分支是**一条裸 `wfi()`**：不发 PSCI 调用、不构造 state id、**永远到不了 `cpu_suspend()`** |
| 所以它的效果是什么？ | **不是"选了一个更浅的睡眠态"，而是把整架梯子从顶上摘掉，只留下架构级 WFI。**这是这一轮最要紧的一句，而它以前是**猜的** |
| 那句一直被人重复的前提呢？ | 这棵树里有**两个**仪器、**五处**（外加根 README 里 docs 121 的索引行，是第六处）告诉操作者同一句话：能定这件事的读数"在内核源码里，**而内核源码不在这台设备上**"。**这句话是假的**：编译出这台设备正在跑的镜像的那份源码**就在这台笔记本上**，而且由它编出来的 DTB 与镜像里附着的五份**逐字节相同** |
| 决定"哪一份定义真的被编译"了吗？ | **决定了。**同一个函数在文件里有**三份 `#if` 分支**，读的是**这次构建自己的 `.config`**（arm64 下 `#if !defined(CONFIG_CPU_V7)` 成立 → 第一份就是跑的那份）。配置换成别的分支，判定**直接掉下来**——因为关于死代码的事实不是事实 |
| 梯子是从哪里读的？ | 从**镜像里附着的那五棵设备树**读的，而且**按 `pm-cpu` 簇分组**：这块板有两簇（pwr、perf），倒成一张六行表就会把"下标 0 是 wfi"变成关于**每第三行**的断言 |
| `qcom,use-psci` 算什么？ | **是判定的一部分**：没有它，`psci_enter_sleep()` 这条分支**根本不会被执行**，上面那条链读的就是死代码。五棵树全设了它（`18d1` 上另一个读数：它在 `/soc/qcom,lpm-levels` 节点上） |
| `qcom,min-child-idx` 呢？ | **是算出来的，不是背出来的**——以前这里印的是一句话："被解析但从未被使用"。**这句话与源码矛盾**：它被读了**六次**。准确的说法是：它被消费了，但全在**簇聚合**与**广播定时器**这两条路上，**不在**这个闸门返回进来的那条路上 |
| 顺带查出的真缺陷？ | 健康页把**停在 fastboot 里的手机**报成"ON THE BUS as the RNDIS gadget"，然后让操作者去修**主机**（bind `rndis_host`、配地址）。**发现方式就是照着这一页跑一遍**，而设备当时正好在那状态——它最常在那状态 |
| 修它的第一版又错在哪？ | 去问 `fastboot` 工具——而这个页面的 harness 把 `/sys/bus/usb/devices` 重写成假树，于是这个检查**一步跨出了自己的沙箱**，把一个不相干子系统的宿主 harness 一起搞红。**输入不可替换的仪器，任何 fixture 都驱动不了** |
| 家族全量跑？ | **36 个 harness / 4810 检查 / 全绿**，仓库自指纹未变（**462 个 tracked 文件**前后哈希一致） |
| 动设备了吗？ | **没有。**设备在 **fastboot**（`33e80afe`，即 `18d1:d00d`），本轮唯一一次"读设备"是健康页照常跑它自己的只读检查 |

---

## 2. 为什么这句话是**承重**的

### 2.1 两个仪器把同一句假设写进了自己的判定里（五处）

* `zl1-sleep-and-throttle.sh`（docs 121 的读数仪器）正文里写着：能定这个参数语义的读数"在内核源码里，而内核源码**不在这台设备上**——所以本脚本从不声称知道这个参数做什么，只报告正在发生什么"。
* `zl1-lpm-ladder-trial.sh`（做实验的那个）在 `--help` 里写着"驱动源码也不在这台设备上"，在判定里写着"内核自己的源码会回答；而它不在这台设备上"。

这些句子**本身不是错的姿态**——它们是很负责的"我不知道"。问题在于**前提是假的**：那份源码就在
`/mnt/data/halium-zl1-build/kernel/leeco/msm8996`，而由它编出来的五个 `.dtb` 与镜像里附着的五份
**逐字节相同**。于是"我不知道"变成了"我本可以知道，却把'不知道'写成了永久状态"。

### 2.2 这是 docs 151 记过的**同一个形状**，只是换了文件

docs 120 把"那个 ramdisk 里有没有 fstab"归档成了**设备侧**的 `ls`，理由也是"offline 读不出来"；
docs 151 证明它**读得出来**（那个 ramdisk 就在这台笔记本上的 4 GB 镜像里）。这一轮是同一件事在
**源码**上重演：**"我看了另一个文件"被写成了"这里读不出来"。**

差别在于**代价的走向**：docs 151 那个空洞只让一条读数悬着；这一条的悬空处正是**第三因的修复**——
机理不知道，修复就是猜的，而实验量的是一个**没人读过的旋钮**。

---

## 3. 机理：从返回值到 CPU 真正执行的那条指令

链是**四环**，每一环都从出货文本里**逐行引出来**并带行号，不是转述：

| 环 | 出处 | 它说什么 |
|---|---|---|
| 闸门 | `lpm-levels.c:467`，在 `static int cpu_power_select(`（451）里 | `if (sleep_disabled \|\| sleep_us < 0)` → `return 0;` |
| 选择回调 | `lpm_cpuidle_select()`（1014-1029） | `idx = cpu_power_select(dev, cluster->cpu);` —— 闸门**唯一的**调用者 |
| 进入回调 | `lpm_cpuidle_enter()`（1031…） | `if (idx < 0) return -EINVAL;` 之后，`if (!use_psci) … else success = psci_enter_sleep(cluster, idx, true);`（1061-1072）——**下标原样带进去** |
| 答案 | `psci_enter_sleep()`（939，`#if !defined(CONFIG_CPU_V7)` 那一份） | `if (!idx) { stop_critical_timings(); wfi(); start_critical_timings(); return 1; }` |

于是：**参数把梯子从顶上摘掉，留下的是架构级 WFI**。它**没有任何 `__setup()` 分支**，所以这个名字
只能以模块参数的身份到达驱动——这正是"修法是在运行时写一个值"（docs 121）而不是"重新做一张 boot 镜像"
的原因，也是这个脚本**自己不写**它的原因。

**这一轮还关掉了一个听起来同样合理的说法。**`qcom,min-child-idx` 这个名字很容易被读成"更深的簇状态由它
把关"。这句话可以查，而且很便宜：它在哪被解析、解析出来的字段在哪被读、那些读点**有没有落在闸门返回进的
那个函数里**。结果是：**它被读了六次**（簇聚合与广播定时器的进入/退出各两次），**一次也不在
`cpu_power_select()` 里**。所以它不是**这个**参数的机理；而"被解析但从未被使用"这句以前当散文印出来的话，
是与源码矛盾的——现在这句话是**算**出来的（三个 fixture：只在函数外读、在函数里读、完全不读）。

---

## 4. 三个读数让它不是一次 grep

1. **哪一份定义真的被编译。**同一个函数有三份 `#if` 分支（`!defined(CONFIG_CPU_V7)` / `defined(CONFIG_ARM_PSCI)` / `#else`），
   而**这次构建自己的 `.config`** 回答它：arm64 且 `CONFIG_CPU_V7` 未设 → **第一份**就是跑的那份。
   配置换成 `CONFIG_CPU_V7=y` 时，判定**直接掉下来**：关于编译器永远看不见的文本的"事实"不是事实。
   （这正和"把 `status` 缺失读成 disabled"是同一类错误，只是发生在源码层。）
2. **梯子按簇分组。**这块板每个 DTB 有**两簇** `qcom,pm-cpu`（pwr 与 perf），每簇**各自**有下标 0、
   1、2。五棵树 × 两簇 = **10 对**，全部是 `wfi,fpc-def,fpc`，pwr 的下标 0 延迟 20 µs、perf 的是 25 µs。
   倒成一张表会让"下标 0 是 wfi"变成关于**每第三行**的断言——在这块板上恰好为真，换一簇就不一定，
   而这正是检查不该有的形状。
3. **`qcom,use-psci` 是判定条件，不是装饰。**它在 `/soc/qcom,lpm-levels` 节点上（被 `of_property_read_bool`
   读进 `use_psci`，再由 `if (!use_psci)` 在调用点决定走哪条路）；五棵树**全设了**它。**没有它的树**会让
   上面那条链读的是**永远不会执行的分支**，判定必须掉下来。查找时比的是**路径最后一段**而不是裸节点名——
   fixture 里那个节点嵌在 `/soc/` 下面，裸名比较会报 `0 of 1`。

---

## 5. 工具与 harness

`scripts/host/zl1-lpm-sleep-semantics.sh`——主机侧、**只读**、**没有任何设备代码路径**（harness 静态断言
它连 `fastboot`/`adb`/`ssh` 这些名字都不出现）。判定是一张表：`THE GATE IS A BARE WFI` /
`THE GATE IS SOMETHING ELSE` / `THE TREES DISAGREE` / `UNREADABLE`（exit 3，什么都不主张）。

harness `scripts/host/zl1-lpm-sleep-semantics-selftest.sh`：**102 项**。它的 fixture 是**三种输入本身的形状**：
一棵由生成器**逐行写出、并把写出的行号印出来**的内核源树（所以"闸门在第 17 行"是拿生成器的数字去比的，
不是拿被测脚本自己的 grep 去比的）、一份 `.config`、以及一张**在非 4 对齐偏移上**附着真实 FDT 的 boot 镜像
（FDT 内部的偏移是**相对于 blob** 的，把两者混起来就会让一次遍历悄悄返回**单节点树**）。

**它自己抓到的真缺陷**：一棵**没有任何 CPU 层级**的树，被算成了**一簇有梯子**——因为标记"这里没有梯子"
的哨兵以前印成 `LEVELS -`，而数梯子的检查 grep 的是 `^LEVELS `。于是运行印出 `THE TREES DISAGREE`
（1 对、0 个 wfi）——**一个 exit 0 的错误答案**，而不是"什么都不主张"。一个与它所标记的**缺席共享前缀**的
哨兵，是一个必须被解析的哨兵。

harness 第 8 节把这一轮**真的出过**的三个缺陷用一次替换在副本上重现，并要求上面那些断言**变红**：
`find_fn` 的参数顺序（每一环都报 `NOT FOUND`）、`use-psci` 的裸名比较（设了它的树报 `0 of 1`）、
`LEVELS -` 哨兵——**harness 的非空洞性是被断言的，不是被声明的**。

---

## 6. 这一轮顺带查出的四个真缺陷

### 6.1 健康页把 fastboot 里的手机报成"RNDIS gadget"，然后让人去修主机

`zl1-health-check.sh` 的设备分类**只看序列号**：任何带 `33e80afe*` 的 id 都叫 `rndis`。而
**`18d1:d00d`（bootloader）与 `18d1:d001`（UT 的 RNDIS gadget）是两个不同的 PID**。于是停在
bootloader 里的手机被判成"gadget 已上线"，页面接着报"`rndis_host` 没绑上，这是主机侧问题"，给出
`sudo scripts/host/zl1-rndis-recover.sh`——**在手机等着 fastboot 的时候让人去修主机**。

**发现方式是照着这一页跑一遍**，而设备当时正好在 fastboot——也就是这一页**最常**被运行的状态之一
（刚刷完的手机就停在那）。修法是读 **PID**：`d001` → rndis、`d00d` → fastboot、其它 → `other`
（照常往下走，不猜第三个 id 是什么）。退出码不变（仍是 2，因为"没启动"和"不在总线上"一样都不能继续）。

### 6.2 它的第一版去问 `fastboot` 工具，于是跨出了自己的沙箱

第一版是 `have_fastboot(){ fastboot devices | awk …; }`。它能修好真机上的误判——**代价是把宿主的一个
不相干 harness 弄红了**：`zl1-thermal-selftest.sh` 把 `/sys/bus/usb/devices` 重写成假树来驱动健康页，
而新检查去读**真总线**，在真设备正好在 fastboot 时返回"是"。

**这是这一页最值得记的一条**：一个仪器的**输入必须可被换掉**，否则任何 fixture 都驱动不了它。
所以分类改读**同一张表**（harness 会重写的那张），而不是调用外部工具。它也说明那 5 条红色断言
（"没有 thermal: 行"、"它 exit 2"、"ip 替身没被调用"）**不是噪音**：它们是"检查绕过了 fixture"的签名。

### 6.3 新 harness 没印 `pass=` 那一行，家族把它读成 NOSUMMARY

家族 runner 靠 `pass=N fail=N` 这一行判断一个 harness 是否绿。第一版的 harness 只印了
`ALL GREEN: 102 checks` 这句人话，于是家族报 **NOSUMMARY**——"它没印 pass= 行，所以不能当作绿"。
**能被人读的句子和能被程序读的那一行是两件事。**

### 6.4 判定本身踩了 docs 134 那个形状：`printf … | grep -q` 在 pipefail 下报写者的死

三处"引出的文本里有没有这个分支"的检查写成了 `if printf '%s\n' "$PSS" | grep -q …`。在 `set -o pipefail`
下，`grep -q` 一命中就退出，`printf` 被 SIGPIPE 杀掉，**管道的状态变成 141**——于是**文本里有的分支被报成没有**。
树里已经为这个形状修过十几处（docs 134），修法都是同一个：**让 haystack 直接交到读者手里，没有管道就没有东西可死**。
这里改成 `case "$PSS" in *'if (!idx)'*) …`，家族那份 census（"状态决定某件事的管道"）也就不再点它。

---

## 7. 这一篇**不**证明什么

* **不证明这个参数值多少度。**它证明的是**机理**：参数的效果是让 CPU 停在 WFI。省下多少度是**测量**，
  那是 `zl1-lpm-ladder-trial.sh` 的问题——而且这一页之后，那个实验的问题变得更干净了：它的悬空处不再是
  "这个旋钮是什么意思"，而是"这架梯子在这块板上值多少"。
* **不证明梯子在设备上真的可达。**源码说它存在，设备树说它被描述，但**这架梯子有没有被真的进入过**，
  仍然只有那次 before/after 的计数器能回答，而且那一次**可以给出反对结论**。
* **不证明那个运行时写是安全的。**写 `0` 到 `/sys/module/lpm_levels/parameters/sleep_disabled` 是那台设备上、
  那一次 boot 里的事，仍然要先满足三个前置（panic 不升级、计数器可读、keeper 不在跑）。
* **不证明健康页的分类已经完整。**它现在能认两个 id，第三个 id 会落到 `other` 并**明说自己不猜**——
  不猜是被断言的，认全不是。
* **不证明"内核源码就在手边"这句话对所有旧读数都成立。**它证明的是**这一份**：编译出正在跑的镜像的那份源码
  与那五份 DTB 的身份（sha256）都印在这一页的读数旁边。别的文档里同形状的"读不出来"，要么单独查，要么不该信。

---

## 8. 设备状态与下一步

整轮**没有写设备**：没有挂载、没有写镜像、没有 flash、没有发过一条会改变状态的设备命令。设备在 **fastboot**
（`33e80afe`，`18d1:d00d`，端口 3-3），`battery-soc-ok: no`，与上一轮同一读数。
本轮唯一一次"读设备"是健康页自己的只读检查——而它现在**把这件事说对了**。

不需要设备就能重跑这一页的任何一条读数：

```
bash scripts/host/zl1-lpm-sleep-semantics.sh                  # 判定 + 每一环的行号 + 身份
bash scripts/host/zl1-lpm-sleep-semantics.sh --quiet           # 只印判定
bash scripts/host/zl1-lpm-sleep-semantics-selftest.sh          # 102 检查
bash scripts/host/zl1-health-check.sh                          # 设备/主机状态（现在是 fastboot 分支）
```

挡住整个工程的那一步仍然**在手上**：插**墙充**，然后
`bash scripts/host/zl1-battery-gate.sh --samples 9 --interval 60`；读数许可之后
`scripts/host/zl1-one-boot-runbook.sh --yes` 就是那一次 boot——两个散热修复和指纹存储目录会在硬件上
第一次真的跑起来，而散热第三因的读数也会第一次带着**已经读过的机理**去做。
