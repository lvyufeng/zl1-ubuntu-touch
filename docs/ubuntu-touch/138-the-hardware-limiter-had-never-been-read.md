# 138 — 那台以发烫著称的机器，它的**硬件限温器**从来没有被读过一次

**日期**: 2026-09-24
**状态**: 本轮**没有碰设备**（设备仍在 Qualcomm EDL，见 §9）。这一轮把 [`137`](137-a-boot-should-answer-the-question-nobody-asked.md)
数出来的 12 个"没有任何探针"的硬件块里的**第一个**关掉——而且是**与目标最直接相关的那一个**：
DTB 里有一个 `qcom,lmh`（SoC 的**硬件限温器**），而在这个仓库里没有任何脚本读过它一次。
新工具 `scripts/device/zl1-lmh-probe.sh`（只读、**一个字节都不写**），新 harness **84 项**（六个变异各让它红 1–7 次），
并且它被接进了"一次启动"的链条（新步骤 **04d**，与 04b/04c 同一类：只读、不开块设备、不需要人在场）。
家族 **22 个 harness / 2529 检查 / 全绿**（本页之前是 2438）。

**接续**: [`137`](137-a-boot-should-answer-the-question-nobody-asked.md)（这一页关掉的就是它列出的 12 个缺口里的第一个）、
[`124`](124-the-boot-a-finger-bought-is-one-command.md)（一次启动是一个命令——本轮的步骤 04d 加进的就是它）、
[`72`](72-the-heat-was-the-governor-and-a-debug-keeper.md) 与 [`100`](100-the-other-half-of-the-heat-fix-and-the-only-misc-backup.md)（发烫这条线上的前两半：
policy 那一半和 keeper 那一半）、[`121`](121-the-third-question-about-the-heat.md)（第三半：supply 那一半）、
[`130`](130-the-boot-s-reading-landed-where-the-boot-s-record-does-not-point.md)（`scm_call -12` 那个 secure-world 失败）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 为什么是这一块？ | 因为目标里最老的那条抱怨是发烫，而 `thermal-lmh` 是这条线上**唯一一个从来没有被读过**的硬件块。`zl1-thermal.sh` 读 `thermal_zone`（tsens），`install-cpufreq-governor.sh` 读 `cpufreq`，`zl1-sleep-and-throttle.sh` 读 `lpm_levels`——**没有一个是限温器本身** |
| 为什么以前没看见？ | **结构性的，而且不看源码看不出来**：LMH **不注册 thermal zone，也不是 cooling device**。`drivers/thermal/lmh_lite.c` 里 `thermal_zone`、`of_thermal`、`thermal_cooling`、`cpufreq`、`devfreq`、`qos` 的出现次数**全是 0**。本端口每一个热读器都读 `/sys/class/thermal/thermal_zone*`，所以**按构造**没有一个可能看见它 |
| 那它到底长什么样？ | 驱动名 `lmh-lite-driver`（`/sys/bus/platform/drivers/lmh-lite-driver`）；class `msm_limits` 下**唯一**的设备 `lmh-profile`，暴露 `level`（0600，可写）/ `available_levels` / `total_levels`；`/sys/kernel/debug/lmh_monitor/` 下的 `interrupt_poll_delay_msec`、`hw_trace_enable`、`hw_trace_interval` 和 `debug/{data,config,data_types,config_types}`。**每一条路径都是从源码里抄的，不是猜的** |
| 为什么不是一个开关，而是"阶梯"？ | 因为驱动自己的三条 init 路径**故意不对称**：`lmh_sensor_init()` 是**致命**的（secure world 不给 SCM 命令就 `-ENODEV`，设备根本不 bind）；`lmh_device_init()` 只**警告**（"LMH continues"）；`lmh_debug_init()` **非致命而且安静**（它自己的 SCM 门在 `pr_debug` 下检查）。所以"debugfs 下没有节点"有**三种**不同原因，只报一个就是把人送到错的层 |
| 探针报什么？ | **它到达的阶梯（rung）**：`no-device-tree-node` / `no-driver` / `not-bound` / `bound-log-unreadable` / `bound-no-sensors` / `bound-no-profile` / `bound-profile-no-monitor` / **`monitoring`**。每一级是一个**不同的下一步**，所以每一级都按名字和退出码断言：只有 `monitoring` 是 0 |
| 它拒绝伪造哪两个读数？ | ①**日志读不到 ≠ 0 个传感器**（`bound-log-unreadable` 是独立的一级）；②**debugfs 没挂载 ≠ 驱动没建节点**——所以挂载状态**先**印，而且明说"此时缺节点不构成对驱动的证据" |
| 它写东西吗？ | **一个字节都不写。**连临时文件都不写（日志读两次是存在变量里的）。它的旋钮**是可写的**（`level` 0600）而且这个块紧挨 secure world，所以 harness 花最多检查的就是这条：静态写保护 + 一颗假牙（往 `level` 写的变异） |
| harness 在探针里找到过真缺陷吗？ | **两个。**①`cut -d' ' -f1` 取 mount 行的"设备"字段，而 debugfs 的该字段就是字面量 `nodev`，于是探针印出 `source nodev`——一个**关于自己主语说错话**的读数；②`--quiet` 把**失败判决所指的那几行日志**一起删掉了，于是 `not-bound` 的判决说"上面的日志行说明了原因"而上面什么都没有。两个都修了，两个都在 harness 里有断言 |
| harness 自己的规则被改过吗？ | 改过一次，而且是**收紧**：写保护的"命令位置"规则第一版是"前面有空格就算"，于是它把探针**自己的判决文字**（`Check the debugfs mount line above`，那里 `mount` 是名词）判成了一次写入。规则收紧成"必须是语句的第一个词（行首，或 `;`、`&&`、`\|\|`、`\|`、`(`、`then`、`do`、`else` 之后）"，收紧这件事本身也有断言 |
| 离线验证？ | **84 项**：stub 目录**就是**设备，PATH 沙箱化（`type -P` 建的符号链接），`/proc`、`/sys` 两趟 token 改写（每一趟在自己的输入上计数，并断言没有残留）；**一级一个场景**；两个容易错的读数各有一组断言 |
| 怎么保证它会被跑？ | 接进了 `zl1-post-recovery-capture.sh` 的默认集，作为 **04d**——和 04b（modem）、04c（sleep/throttle）同一类：只读、不开块设备、不需要人在场。capture 的 harness 143 → **146**（它按名字、按顺序、按 scp 的实际路径断言每一步，加一步就必须全部改一遍，这正是它存在的理由） |
| 动设备了吗？ | **没有。** |

---

## 2. 这一块为什么值得单独一轮

目标是合取：「一定要让图形界面能跑起来，**所有的硬件都能驱动**，另外**这台机器很容易发烫**，要解决这个问题」。
发烫这条线已经有**三半**被查过、也各有修法：

| 半 | 是什么 | 谁在读 | 状态 |
|---|---|---|---|
| **policy** | image 把四个核钉在 `performance` 上 | `install-cpufreq-governor.sh` | 修法已安装（docs 72、100） |
| **keeper** | v63 debug keeper 每秒 `systemctl` 一次，占满一个核 | `install-retire-debug-keeper.sh` | 修法是**每次启动杀掉它**（docs 72 那条"改 unit"的路线做不到） |
| **supply** | cmdline 的 `lpm_levels.sleep_disabled=1` 关掉了整机低功耗阶梯 | `zl1-sleep-and-throttle.sh`（docs 121） | 探针有，修法是 runtime 写，尚未在设备上做 |

三半都在 **Linux 这一侧**。而 `thermal-lmh` 是**硬件那一侧**：LMH 的限温是硬件块和 secure world 做的，Linux 驱动只是**监控**它并暴露一个 profile。
所以这一块从来没有被读过这件事，意味着**没有任何读数能说它在不在工作**——不是"它没工作"，是"没人问过"。

这正是 docs 72 那条老账的同一个形状（"没有被测量的东西"），只是这次被测量的东西在 SoC 里。

---

## 3. 它为什么一直没被看见：一条**结构性**的原因

不是"忘了写探针"，是**按构造不可能看见**。`drivers/thermal/lmh_lite.c` 与 `lmh_interface.c`（Halium 树，`/mnt/data/halium-zl1-build/kernel/leeco/msm8996`）：

```
grep -c thermal_zone / of_thermal / thermal_cooling / cpufreq / devfreq / qos   ->  0  0  0  0  0  0
CONFIG_LIMITS_MONITOR=y / CONFIG_LIMITS_LITE_HW=y   (lineage_zl1_defconfig:2378/2379)
```

而本端口所有的热读器——`zl1-thermal.sh`、健康检查里的热那一行、heat chain 的 A/B——都在读 `/sys/class/thermal/thermal_zone*`。
**一个不注册 thermal zone 的块，对它们全体不可见。**这就是缺口的结构，而不是谁疏忽了。

顺带，DTB 里那个节点（rebuilt 集合）是：

```
/soc/qcom,lmh
  compatible = qcom,lmh_v1
  interrupts, vdd-apss-supply, qcom,lmh-odcm-disable-threshold-mA
  qcom,lmh-trim-err-offset   <- 不存在，这是正常的：驱动读作 trim_err_disable=true 并跳过 LMH_TRIM_ERROR
```

`qcom,lmh-trim-err-offset` **缺失是正常的**，探针在 `--explain` 里专门写了这一条，因为一个只数属性的读者会把它当成"缺东西"。

---

## 4. 读数是"阶梯"，因为驱动的失败路径是**故意不对称**的

`lmh_probe()` 里三条 init，按顺序，失败方式完全不同：

| 调用 | 失败时 | 后果 |
|---|---|---|
| `lmh_sensor_init()` | **致命**（`-ENODEV`） | secure world 不提供 SCM 命令（`LMH_CTRL_QPMDA`、`LMH_GET_INTENSITY`、`LMH_GET_SENSORS`，以及**只有** DTB 没有 `qcom,lmh-trim-err-offset` 时才要的 `LMH_TRIM_ERROR`）→ **设备根本不 bind** |
| `lmh_device_init()` | 只**警告**（"LMH continues"） | `msm_limits` 的 profile 节点可以**不存在**，而限温器本身是好的 |
| `lmh_debug_init()` | `pr_err` + `ret=0`，**非致命**，而且它自己的 SCM 门在 `pr_debug` 下检查（**安静**） | monitor 节点也可以不存在，日志里**什么都不说** |

于是：**"debugfs 下没有节点"这句话没有单一含义**。可能是 debugfs 根本没挂载、可能 `lmh_debug_init()` 的门没过、也可能设备压根没 bind。
只报一个读数就是在猜层。所以探针报阶梯，而且把**判据**也印出来（每个阶梯的判决文字里写着下一手该看哪里）。

---

## 5. 两个"不能伪装的读数"

这一页最值钱的两条断言，都是关于**区分"没读到"和"读到了否"**的：

1. **日志读不到 ≠ 0 个传感器。** `dmesg` 和 `journalctl -b -k` 都失败时，探针印
   `the kernel log could not be read ... so the sensor count is NOT READ, which is not the same as zero.`，
   并给出**独立的一级** `bound-log-unreadable`。一个"读到 0 行 `Registering sensor:[`"的读数和"读不到日志"的读数，
   在字符串上**完全一样**（都是空），而它们的含义相反。
   （同一个形状这条线上已经付过代价：docs 120 的 modem 探针把"读不到"报成过"安静"。）
2. **debugfs 没挂载 ≠ 驱动没建节点。** 挂载状态从 `/proc/mounts` **先**读，而且明说
   `(a missing node here is therefore NOT evidence about the driver)`。`ls` 一个不存在的节点和一个没挂载的 debugfs 长得一模一样——
   **位置就是含义**，所以 harness 里有一条断言专门查这两行的**先后顺序**。

---

## 6. harness：84 项，六个变异，和一颗把规则本身收紧了牙

`scripts/host/zl1-lmh-probe-selftest.sh`。纪律沿用 modem 探针那一套：**stub 目录就是设备**，
PATH 沙箱化（`type -P` 建符号链接，因为 `command -v` 在被 profile 定义成函数时会返回**名字**），
`/proc`、`/sys` 两趟 token 改写，并把 landing 数作为不变量断言。

两趟这件事本轮又长了一颗牙：`/proc/sys/kernel/random/boot_id` **里面含 `/sys/`**，
所以"源码里 `/sys/` 的个数 = 最终 token 数"是**错的**，错的量正好就是跨界的那条路径——
harness 第一次运行就是被这条检查拦下的。现在每一趟在自己的输入上计数，并各自断言"本趟之后没有残留"。

一级一个场景：

| 场景 | 阶梯 | 退出码 |
|---|---|---|
| `not-zl1`（`compatible` 里没有 msm8996） | 拒绝，不给判决 | 2 |
| `no-dt-node` | `no-device-tree-node` | 1 |
| `no-driver` | `no-driver` | 2 |
| `unbound`（驱动在、没人绑） | `not-bound` | 1 |
| `bound-log-unreadable` | `bound-log-unreadable` | 1 |
| `bound-no-sensors` | `bound-no-sensors` | 1 |
| `bound-no-profile` | `bound-no-profile` | 1 |
| `bound-profile-no-monitor` / `unmounted-debugfs` | `bound-profile-no-monitor` | 1 |
| `healthy` | `monitoring` | 0 |

六个变异，每一个都必须让它红（`ZL1_LMH_PROBE_SRC=<变异> bash scripts/host/zl1-lmh-probe-selftest.sh`）：

| 变异 | 红 |
|---|---|
| 三个 Linux 侧输出**任意一个**在就算 `monitoring`（`&&` 改 `\|\|`） | **7** |
| 日志读不到时 `SENSORS=-1` 改成 `0` | 2 |
| 把 debugfs 挂载状态挪到 monitor 节点**之后** | **6** |
| mount 行改回 `cut -d' ' -f1`（就是那个 `source nodev`） | 1 |
| `show` 改回"管道 + `\|\| say none"那个形状 | **5** |
| 设备闸门改成 `grep -qa .`（还留着那条路径，但不再判断） | 3 |

写保护是静态的，牙齿有三颗：往 `level` 写的变异、命令位置上的 `mount -t debugfs none /sys/...`、
以及三个**散文夹具**——一个装满了"mount"这句话的 heredoc、本项目散文里那支 `-> /sys/...` 箭头、
以及**`mount` 是名词**的那一句。最后一句是规则收紧的原因：第一版规则是"前面有空格就算"，
而探针自己的判决文字里写着 `Check the debugfs mount line above`——**一个会对句子开火的闸门，第一次烦到人就会被删掉**。

两个豁免也各有断言（去掉任何一个，都有夹具立刻变红）：`2>/dev/null` 不是对设备文件系统的写入，
以及**heredoc 体是文本**（探针 `--explain` 那一页里写着 "the mount state is read first, then mount the debugfs"，
`then mount` 按规则**就是**命令位置，所以 heredoc 体先被抹白，且保留行号）。

---

## 7. harness 在探针里找到的两个真缺陷

harness 不是形式：它在**自己第一次跑通之前**就让探针改了两处，两处都是"读数看起来对、其实错"：

1. **`source nodev`。** `DBG_SRC=$(grep ... /proc/mounts | cut -d' ' -f1)`：mount 行的**第 1 个字段是设备**，
   而伪文件系统的设备名就是字面量 `nodev`。所以探针印的是 `debugfs mounted: yes (source nodev)`——
   一个**关于自己主语说错话**的读数（正是这个项目反复记录的那一类）。现在印**整行**，并且 harness 断言它印的是整行、
   而且**永远不出现** `source nodev`。
2. **`--quiet` 删掉了失败判决所依据的证据。** `not-bound` 的判决文字写着"上面的日志行说明了原因"，
   而 `--quiet` 把日志块一起删了——一句指向**不存在的东西**的话。现在那个块（SCM 门拒绝 / device-init 警告）
   在 `--quiet` 下也印，理由写在探针里而不是只写在这里。

---

## 8. 这一轮**不**证明什么

* **不证明限温器在工作。** 反过来也不证明它没工作。`level` 的数字大小和中断静不静**单独都不说明任何事**：
  LMH 的限温发生在硬件块和 secure world 里，这个驱动只是监控它并暴露一个 profile。
  "它在不在工作"需要一个**负载**，也就是 `zl1-thermal.sh` 那个 A/B 在**机器热的时候**取的读数——
  两个探针是**一起读**的。探针自己的结尾就印着这一条（`WHAT THIS IS NOT`）。
* **不证明 secure world 会给出那些 SCM 命令。** `not-bound` 这个阶梯的**首要嫌疑**是 SCM 门，
  但它同时也可能是 DTB 里没有节点、或者驱动自己的 `late_initcall` 失败。阶梯只负责把人送到**正确的层**，
  不负责给出原因——原因要读上一步的证据。
* **不证明在任何一台真实的 zl1 上跑过。** 这一轮**一次 ssh 都没有**。84 项全部挡在 stub 目录后面。
  阶梯的每一个分支都有场景，但**场景是我造的**；设备上到底落在哪一级，只有设备回来才知道。
* **不证明 `debug/data` 的布局。** 这个仓库里没有任何东西记录那个缓冲区的格式，所以它是**原样打出并标注未解析**的。
  一个猜出来的列就是编造出来的答案。
* **不证明 `thermal-lmh` 这一块"硬件在不在"。** 这一页判的是"**没人读过它**"，不是"它没有工作"——
  和 docs 137 §7 的第一条是同一条。
* **不证明这 12 个缺口里剩下的 11 个更不重要。** 只是这一个与"发烫"这条目标最直接相关，所以先做它。

---

## 9. 设备状态与复现

整轮没有动设备：没有写任何分区或 boot，没有跑 QDL/QFIL，没有重启。设备仍在 **Qualcomm EDL**
（`05c6:9008`）。识别目标一律按序列号 **`33e80afe`**；总线上另一台小米 **`4a2fe00b`** 必须忽略。
恢复仍然只能靠**物理长按电源 10–20 秒**。

```sh
# 全部在宿主机上，不碰设备。
bash scripts/host/zl1-lmh-probe-selftest.sh                  # 84 项
bash scripts/host/zl1-hardware-inventory.sh --gaps           # 现在只剩 11 个缺口

# 那六个变异（每个都必须让它红）：
S=scripts/device/zl1-lmh-probe.sh
sed 's#^  SENSORS=-1#  SENSORS=0#' "$S" > /tmp/mut-lmh.sh
ZL1_LMH_PROBE_SRC=/tmp/mut-lmh.sh bash scripts/host/zl1-lmh-probe-selftest.sh

# 设备回来之后：它已经在"一次启动"的默认集里（04d），所以这一条就够了：
bash scripts/host/zl1-post-recovery-capture.sh --status
# 或者只跑它一个（只读、不写任何东西）：
scp scripts/device/zl1-lmh-probe.sh root@10.15.19.82:/tmp/ && ssh root@10.15.19.82 'sh /tmp/zl1-lmh-probe.sh'
```

| 文件 | 作用 |
|---|---|
| `scripts/device/zl1-lmh-probe.sh` | 新：硬件限温器探针（阶梯、只读、**不写任何东西**，`--quiet` / `--explain` / `--help`） |
| `scripts/host/zl1-lmh-probe-selftest.sh` | 新：84 项，stub 目录就是设备，一级一个场景，六个变异 |
| `scripts/host/zl1-post-recovery-capture.sh` | 改：默认集新增 **04d-lmh**，与 04b/04c 同类（只读、不开块设备、不需要人） |
| `scripts/host/zl1-post-recovery-capture-selftest.sh` | 改：143 → **146** 项（加一步就要按名字/顺序/scp 路径全部改一遍——它按名字断言，所以漏改会红） |
| `scripts/host/zl1-hardware-inventory.sh` | 改：`thermal-lmh` 一行从 `-` 变成点名 `scripts/device/zl1-lmh-probe.sh`；汇总 18 有仪器 / **11** 无 |
| `scripts/host/zl1-hardware-inventory-selftest.sh` | 改：汇总数字与缺口名单跟着改，并**新增一条**断言"被关掉的那个缺口按名字出现在有仪器的一侧" |
| `scripts/host/zl1-health-check.sh` | 改：新增一段（在 heat fix 那一段之后），把 lmh 探针、它的阶梯、和 harness 的 84 项接上；0g 一节改写为 11 of 29；cli-usage 的引用 140 → **144**（它扫的脚本 47 → 49） |
| `scripts/README.md` | 改：`device/zl1-lmh-probe.sh` 与 `host/zl1-lmh-probe-selftest.sh` 各一行；cli-usage 140 → 144；capture harness 143 → 146 |
| `docs/ubuntu-touch/124-*.md` | 改：家族总数那一行续上本轮（2529 / 22 个 harness） |
| `README.md` | 改：本页的索引行 |
| `docs/ubuntu-touch/138-*.md` | 本篇 |
