# 156 — 覆盖率是关于那张表的，而没有任何东西量过那张表漏掉什么

**日期**: 2026-09-25
**状态**: 本轮**没有碰设备**。这一页关掉的是"所有的硬件都能驱动"这句话**最容易被误读的那一环**：
`zl1-hardware-inventory.sh` 回答"哪一块硬件没有任何脚本读过"，而它的答案有两个半边——
**行**（表里写的块）和**块**（板上有的硬件）。第二个半边**从来没有被量过**：
一行都没写的块，在那份报告里不是"缺口"，而是**根本不存在**。
这一轮给报告加上了那个读数，而**它第一次跑就找到了一块**（`/soc/qcom,qbt1000`，指纹传感器的 SSC/SPI 块）。

**接续**: [`137`](137-a-boot-should-answer-the-question-nobody-asked.md)（那份清单本身的来历）、
[`148`](148-the-block-with-nothing-missing-is-the-one-that-binds-through-a-name-the-tree-never-spells.md)（最后一个缺口关上、
清单归零的那一轮）、[`140`](140-the-block-that-was-another-phones.md)（同一张表最贵的一次错：一行点名了**另一台手机**的芯片）、
[`123`](123-where-every-peripheral-stands.md)（**每个外设现在在哪儿**：本轮的读数归到那一页）、
[`152`](152-a-reading-is-only-as-good-as-the-identity-of-its-input.md)（读数只和它读的那个文件的**身份**一样可信）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 这一轮问的是什么？ | 那份覆盖率报告说"**29 个硬件块，29 个有仪器，0 个缺口**"。**这句话是关于什么的？** |
| 是关于板子的吗？ | **不是。它是关于那张表的。**report 的每一行、每一个计数、连"0 gaps"那句总结，都在数**表里的行**——而表是**手写的**。 |
| 那"一行都没写的块"会怎样？ | **它不会是缺口，因为它不是一行。**缺口 = 一行失败了；**缺了一行什么都不会失败**。这就是形状：报告只能报告它已经知道的东西。 |
| 这不是这个仓库已经记过的东西吗？ | **是，而且就在同一个文件里面一层**：这份报告曾经**搜到了它自己的源码**，于是每个块都被自己"覆盖"，总结印出 **34 covered / 0 gaps**——一份**不能报缺口**的报告（`[[zl1-instruments-that-cannot-report-not-armed]]`）。那一层修掉了（搜索排除自己、排除 harness、排除散文）；**上面这一层没修**。 |
| 这一轮加了什么读数？ | **这块板上每一个没有被任何一行认领的 `compatible`**，从**同一批设备树**里派生：计数进总结，完整列表走 `--unclaimed`。它不可被"整理"掉，因为它不是清单，是**测量**。 |
| 第一次跑出什么？ | **142 个不同的 `compatible`（242 个 path/compatible 对）没有任何一行认领。** |
| 里面有真硬件吗？ | **有。**最要紧的一个是 **`qcom,qbt1000`**——见 §3。 |
| 读法的**盲区**在哪？ | **没有设备树节点的硬件，这份报告永远看不见**——而这不是理论：**这个内核没有 GNSS 驱动、设备树里也没有 GNSS 节点**（§4）。所以"142"不能被读成"剩下的就这些"。 |
| 表被改了吗？ | **改了三处，都是这次读数逼出来的**：新增一行 `fingerprint-spi`（`qcom,qbt1000`）；`display-mdp` 的 pattern 补上 `sde_kms`（**第二代显示驱动**，11 → 16 个节点）；`audio-codec` 的 pattern 补上 `tasha|slim-ngd`（**它的 token 列表一直点着 `tasha`，而 pattern 认不出那个节点**，66 → 69）。另加 INFRA 的 `iommu` 补上 `cam-smmu`。 |
| 现在的读数？ | **30 个硬件块 / 29 个有仪器 / 1 个缺口**——**缺口列表自 docs 148 清零以来第一次不为零**，而这一次不是"谁忘了写探针"，是**新读数找到的一块**。 |
| 新缺口是什么？ | `fingerprint-spi`：驱动**编进了内核**（`CONFIG_MSM_QBT1000=y`，defconfig:3913），它**自己建出 `/dev/qbt1000` 和一个输入设备 `qbt1000_key_input`**，这个工程**在屏幕上见过那个输入设备**（docs 70/73）——而**这棵树里没有任何脚本读过它**。 |
| 它和指纹什么关系？ | 它的设备树子节点是 **`qcom,fingerprint-sensor-ssc-spi-conn`**：SSC 的 **SPI port 2**、slave 0、TZ 子系统 id 1、SSC 子系统 id 5。也就是说**指纹传感器的 SPI 通路就在这一块里**——而指纹是本工程三个"只量过离线"之一。 |
| 读数会不会被一行空 pattern 骗过去？ | **会，所以现在拒了。**那些 pattern 被拼成**一条 alternation** 来算"没认领"，而 ERE 里一个**空分支匹配一切**——一行空白 pattern 就会让整块板看起来"全被认领"。这跟当年那个空白仪器字段是同一种错（把答案**反过来**），所以按同一条规矩**拒绝**。 |
| 加了几项检查？ | inventory harness **118 → 136**（新读数的计数、空列表要说出来、空白 pattern 的拒绝、以及**两端都**成立的那对断言：`qcom,qbt1000` 进了表、于是**从列表里消失**，`qcom,msm_tspp` 留在列表里）。 |
| 家族全量跑？ | **37 个 harness / 37 全绿 / 4926 检查 / 0 失败**，且**仓库未改**（468 个 tracked 文件跑前跑后各哈希一次） |
| 动设备了吗？ | **没有。**设备仍在 **fastboot**（`33e80afe`，`18d1:d00d`），本轮没有一条会改变设备状态的命令 |

---

## 2. 为什么"0 gaps"必须被一个数字界定

那份报告现在的最强一句是：

```
blocks: 30 hardware -- 29 with a named instrument, **1 with none**, 0 STALE; plus 6 infrastructure rows
```

它读起来像"这块板上没有没人读过的硬件"。而它的每一半都在数**行**：

* `30 hardware` —— 表里有 30 行 `kind=HW`；
* `29 with a named instrument` —— 其中 29 行的仪器文件**真的点到了那个块**；
* `1 with none` —— 剩下那一行没人读。

**一行都没写的块不在这三个数里的任何一个里。**这不是疏忽，是**结构**：报告问的是"表里的行，有没有人读"，
它**从来没有**问过"表漏了什么"。而"表漏了什么"恰恰是"所有的硬件都能驱动"这句话的**上半句**。

**这个形状在这个文件里已经修过一次，而且注释还在**（`instrument_files()` 上面）：

* 第一版**搜到了自己**：每个块都被这个脚本自己"覆盖"，总结印 **34 with an instrument, 0 with none**——
  一份**不可能报缺口**的报告；
* 还有两处**散文**造成假覆盖（`vibrator` 匹配了段落里的 "haptics"，`video-codec` 匹配了另一个段落里的 "venus"）；
* 还有备份脚本的 `ALLOWLIST` 把分区名 `modem`/`bluetooth` 当成了仪器。

那一次修的是"**谁算仪器**"。这一轮修的是"**哪些块进入了这个问题**"——**同一件事再往上一层**。

---

## 3. 第一次读数：142 个未被认领的 compatible，和一个真的块

派生（不是手写）的做法很简单：把表里**每一行**的 DTB pattern 拼成一条 alternation，然后问这块板上
每一个 `path/compatible` 对不对得上。对不上的，就是**这份报告不知道的东西**。

```
  135 distinct compatible(s) on this board are claimed by NO row (230 path/compatible
  pair(s)).
```

（第一次跑是 **142 / 242**；表改过之后是 **135 / 230**。两个数都印在报告里。）

里面**最多的几个**是 GDSC、PWM、cache、SPI/I2C 控制器、DMA 池、regulator —— 这些无论怎么看都是基础设施。
**而这个读数存在的理由，正是"不靠'无论怎么看'来决定"**：它把列表交出来，让人**看**。

而列表里有一个不是基础设施：

| 读数 | 值 | 出处 |
|---|---|---|
| 节点 | `/soc/qcom,qbt1000` | `compatible = "qcom,qbt1000"` |
| 在几套设备树里 | **F R S 三套全在**，15 棵 LE_ZL1 树 | `--unclaimed` 的 `[F R S]` |
| 驱动编进内核了吗 | **是**：`obj-$(CONFIG_MSM_QBT1000) += qbt1000.o`；`lineage_zl1_defconfig:3913` = `CONFIG_MSM_QBT1000=y` | 内核源码 |
| 它建出什么 | 一个字符设备 **`qbt1000`**（`QBT1000_DEV`，`device_create` 于 `qbt1000.c:1050`）**和一个输入设备 `qbt1000_key_input`**（`:1092`，`BTN_TOUCH` + `ABS_X/ABS_Y`） | `drivers/soc/qcom/qbt1000.c` |
| 它的设备树子节点 | **`qcom,fingerprint-sensor-ssc-spi-conn`**：`spi-port-id = <2>`、slave 0、`tz-subsys-id = <1>`、`ssc-subsys-id = <5>`、15 MHz | `msm8996.dtsi:2596-2605` |
| 这个工程见过它吗 | **见过**：`qbt1000_key_input` 出现在 docs 70/73，且 `zl1-input-devices.py:16` **专门有一段注释讲它**（"这块板的电容键不一定在按键控制器上"） | 仓库 |
| 有脚本**读**它吗 | **没有。**（两处提到它的地方**都是注释**，而注释不算读数——那条规则是这个文件自己写下的） | 报告的 token 搜索 |

**所以表里多了一行，而它落进"缺口"那一栏**：

```
fingerprint-spi  1     **NONE**    F R S
```

这是**自 docs 148 把清单清零以来，缺口列表第一次不为零**。而它和之前那十二个缺口**性质不同**：
那十二个是"**清单上已知、没人写探针**"，这一个在昨天还**不在任何清单上**——它是**这一轮的读数找出来的**。

**这一行值得留下的理由不止"它不该隐形"**：它的子节点说得很清楚——**指纹传感器的 SPI 通路在这一块里**。
而指纹是这个工程三个"只量过离线"的外设之一，修法（`/data/vendor_de/0/fpdata`，docs 126）也还**没在设备上跑过**。
一个只读存储目录的判据（`setActiveGroup failed` 归零）**不足以**证明整条指纹链路；`qbt1000` 是那条链路上
**另一个有名字的读数点**，而它现在是**表里一个空白格**。

---

## 4. 这个读数的盲区，以及它第一次就被用上

报告的总结现在**自带**这一句（不是脚注）：

> This reading cannot be complete in the other direction either: a peripheral whose hardware has no
> device-tree node cannot appear in it, or anywhere else in a report derived from device trees.

**这句话不是免责声明，是一个读数。**这一轮顺手把它量了，因为 GPS 一直挂在"只量过离线"那一栏：

| 问 | 答 | 怎么知道的 |
|---|---|---|
| 这个内核有 GPS 驱动吗？ | **没有。**`drivers/` 下没有任何 `gnss` 文件 | `grep -rln gnss $K/drivers/` → 空 |
| 它的设备树里有 GNSS 节点吗？ | **没有。**`msm8996.dtsi` 里没有 `gnss` | `grep -rn gnss $K/arch/arm64/boot/dts/qcom/msm8996.dtsi` → 空 |
| 配置里有吗？ | **没有。**没有 `CONFIG_*GNSS*` | defconfig |
| 两块板的 38 棵树里有吗？ | **没有。**整个 dump（1499 行）里 `gnss`/`gps` **一条都不匹配** | `--dump-compatibles` |

**所以 GPS 在这块板上不是"设备树有节点、内核有驱动、而它不工作"**——它在**内核这一层什么都没有**。
GNSS 引擎在**调制解调器（MSS）**里，而 docs 120/154 已经量到：**固件从来没被挂上、也没有内核侧的调用者**。

这条读法**不**声称"GPS 的答案就是 modem"——那需要设备侧的读数（`locClientOpen` 那条正向前提，
docs 109/119），而本轮没有设备。它声称的是**这一件**：**GPS 不可能出现在一份从设备树派生的覆盖率报告里**，
因为**它的硬件没有节点**。所以"所有的硬件都能驱动"这句话里的 GPS 那一格，**永远要靠另一份记录**——
这也是为什么这一轮的读数要归到 [`123`](123-where-every-peripheral-stands.md)（每个外设现在在哪儿）那一页，
而不是留在这份报告里。

---

## 5. 被读数逼出来的三处表改动，以及**没有被收进去**的东西

读数给出的是**原料**；判断仍然是人的。三处**改**、两处**不改**，都写下来，因为"为什么不改"和"为什么改"一样是结论。

| 决定 | 对象 | 理由 |
|---|---|---|
| **加一行** | `fingerprint-spi`（`qcom,qbt1000`） | §3：驱动在内核里、建出设备、工程见过它、而没人读它 |
| **补 pattern** | `display-mdp` += `sde_kms` | 它的兄弟行 `display-panel` 早就记着"**两代显示驱动挂在同一个窗口上**"，而 mdp 那一行的 pattern 只认第一代。补齐后 **11 → 16**（多了 SDE 根节点和它的 4 个 SMMU context bank） |
| **补 pattern** | `audio-codec` += `tasha\|slim-ngd` | 这一行的**仪器 token 列表里一直写着 `tasha`**，而它的 **DTB pattern 认不出** `/soc/slim@91c0000/tasha_codec`。一行里两半互相矛盾，就是"pattern 漏掉了自己块的节点"。**66 → 69**（还有 `/soc/sound-9335`，声卡节点） |
| **补 pattern（INFRA）** | `iommu` += `cam-smmu` | 相机那 6 个 context bank 是 IOMMU 基础设施，不属于 camera 块 |
| **不加行** | `qcom,msm_tspp` | **内核没编它的驱动**（`# CONFIG_TSPP is not set`），而且这块板没有调谐器。给它一行就是造一个**假的缺口**，而这张表自己的注释写着假缺口"会把真的埋掉"。**它留在 `--unclaimed` 的列表里**——那条规矩写在表自己的注释里（`kind=INFRA` 那一段：把这类东西当缺口列出来"会把真的埋掉"） |
| **不加行** | `qcom,sde-kms` 之外的 SDE 子节点 | 它们随 SDE 根一起被 `display-mdp` 认领了；**path 匹配**让这件事自动成立 |

**顺序也是承重的**：先加读数、**再看它说出什么**、再改表。反过来做（先想"还缺哪几个块"）就是**又用手写的清单去覆盖手写的清单**，
而这一轮的整个题目就是那个做法漏掉了什么。

---

## 6. 空 pattern 现在会被拒绝

那些 pattern 被拼成**一条 alternation** 来算"没认领"：

```
^  ...  | ...  | ...  |
```

ERE 里一个**空分支匹配任何字符串**。所以表里只要有一行 pattern 是空的，结果就是**整块板都被认领**——
"0 compatibles claimed by no row"，**答案被反过来**。同一份文件里，空白**仪器字段**当年干的正是这件事
（`grep -x ""` 匹配每一行 → 那一行被报成 COVERED），当时的修法是"数字段、然后失败"。

这一次同类：**空 pattern 直接拒绝（exit 2），并说明为什么空比错更坏。**

---

## 7. harness：118 → 136 项，而且它抓到了我自己改坏的一处

新增的检查按这个仓库的老规矩来：**两个方向都要成立**。

1. fixture 的设备树里加一个**没有任何行认领**的节点（`j@10`），断言**计数是 1**——
   而且断言的是 **1 个 compatible，不是 fixture 的设备树文件数**（第一版的列表就是按文件数印的，
   每一行都印 15，因为那些 pair 在 15 棵 LE_ZL1 树里都出现——那是关于 blob 的事实，不是关于板子的事实）。
2. `--unclaimed` **列出那个节点**（带路径），并且**不列已认领的行**。
3. **反向**：加一行认领同一个节点，计数必须**变成 0**，而且**空列表要把话说出来**——
   一个永远非零的读数，它的非零值什么都不说明。
4. **空白 pattern 必须被拒绝**，并印出原因。
5. 真实板上：计数的两个数（135/230）、`qcom,msm_tspp` 在列表里、以及 **`qcom,qbt1000` 不在列表里**——
   **后一条是"读数找到了它、表收了它、于是它离开了列表"这件事的完整形状**。

**而这一轮 harness 抓到的一处真缺陷是我自己造的**：我给主报告加新段落时，一次外科手术式的删除
**连带删掉了 "Rows whose DTB pattern matched no node" 那一节的打印**——于是一个**打错的 pattern**
（本来会单独列出来的那一类）**静默消失**。harness 的第 2 节立刻变红。**这正是那份报告存在的理由反过来咬了一口：
一个不能报"我的 pattern 打错了"的报告，和一个 pattern 全对的报告，读起来一模一样。**
（修好之后那一节回来了；这一条留在这里，因为它是这一轮唯一一次"改动弄坏了一个**不能失败**的检查"。）

---

## 8. 数字

| 项 | 读数 | 怎么读的 |
|---|---|---|
| 板的 `compatible`（未认领） | **142 → 135** 个不同值（242 → 230 对） | 报告自己的总结行 |
| 表 | **29 → 30** 行 `HW` | 报告的 `blocks:` 行 |
| 缺口 | **0 → 1**（`fingerprint-spi`） | 报告的 `1 with none` |
| 被补的 pattern | 3 处（display-mdp、audio-codec、iommu） | 见 §5 |
| 节点的移动 | display-mdp **11 → 16**、audio-codec **66 → 69** | 报告的表 |
| inventory harness | **118 → 136 项**，`pass=136 fail=0` | 一次运行 |
| 两个记数页 | health-check 与 `scripts/README.md` 同步到 **136** | docs 110 的引用漂移守卫 |
| 家族全量跑 | **37 个 harness / 37 全绿 / 4926 检查 / 0 失败**，`== the repository is unchanged (468 tracked files hashed before and after, no new file)` | `bash scripts/host/zl1-selftest-family.sh` 的一次运行 |
| 本轮之前 | 4908（docs 155 之后） | 同一命令；差值 **+18** = 这一轮只动了一个 harness 的 118 → 136 |

---

## 9. 这一篇**不**声称什么

* **不声称 135 就是"剩下的硬件"。**它是"**这份报告的表没有认领的 compatible 的个数**"。
  列表里的大多数是总线、时钟、regulator 和 IOMMU context bank；**分类是判断，报告不做这个判断**。
* **不声称表现在完整了。**§4 已经量到它**不可能**完整：没有设备树节点的硬件进不来。
* **不声称 `qbt1000` 与指纹的失败有因果关系。**它声称的是**两个可以被读的事实**：
  它的子节点写着 `fingerprint-sensor-ssc-spi-conn`；而**没有任何脚本读过这个块**。
* **不声称 `qbt1000` 在设备上真的起了。**驱动编进去、节点在三套树里都有，是**离线**读数；
  `/dev/qbt1000` 与 `qbt1000_key_input` 在**这一次 boot** 里存不存在，是设备侧读数。
* **不声称 pattern 补全之后那些块就"读了更多"。**pattern 只决定**哪些节点进入那一行的计数**；
  行的判定仍然由**仪器文件是否点到块**决定（audio-codec 补了 pattern 仍然是同一个仪器、同一句 COVERED）。
* **不声称别的板子适用。**pattern 是按**这块板**的 compatible 写的。

---

## 10. 设备状态与下一步

整轮**没有写设备**：没有挂载、没有写镜像、没有 flash、没有一条会改变设备状态的命令。
设备在 **fastboot**（`33e80afe`，`18d1:d00d`，端口 3-3）。

不需要设备就能重跑这一页的每一条读数：

```
bash scripts/host/zl1-hardware-inventory.sh              # 读那条"表没认领什么"的总结
bash scripts/host/zl1-hardware-inventory.sh --unclaimed   # 完整列表
bash scripts/host/zl1-hardware-inventory-selftest.sh      # 136 检查
```

挡住整个工程的那一步仍然**在手上**：插**墙充**，然后
`bash scripts/host/zl1-battery-gate.sh --samples 9 --interval 60`；读数许可之后
`scripts/host/zl1-one-boot-runbook.sh --yes` 就是那一次 boot。

**这一轮的设备读数（只读，`fastboot getvar`，2026-09-25）**：`battery-soc-ok: no`，四次采样 **2.810 / 2.773 / 2.847 / 2.773 V**，散布 74 mV 把 -37 mV 的首末差完全解释掉，判定 **`FLAT WITHIN NOISE`**——**既不能说电池死了，也不能说它在充**，分开这两者的是**换一个充电器**（docs 150）。这条读数属于那一页，写在这里只是因为它解释了为什么这一轮仍然是一条 `--unclaimed` 就能跑完的、不需要设备的阶段。

### 10.1 这一页给下一次设备侧的读数

`qbt1000` 现在是表里唯一的缺口，而**它的判据很短**：

```
ls -l /dev/qbt1000                      # 驱动 probe 成功才会有的字符设备
cat /proc/bus/input/devices | grep -A2 qbt1000_key_input
```

**两条都在**，说明这块硬件**起了**而**没人读它**；**第一条不在**，说明"驱动编进去了"和"它绑上了"是两件事——
那是**另一条**读数（`dmesg | grep -i qbt`），而不是这一页的结论。
