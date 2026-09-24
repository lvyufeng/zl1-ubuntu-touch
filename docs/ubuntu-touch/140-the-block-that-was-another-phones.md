# 140 — 那一行的"仪器"是另一台手机的芯片：振动马达，以及清单自己的一个错误

**日期**: 2026-09-24
**状态**: 本轮**没有碰设备**（设备仍在 Qualcomm EDL，见 §7）。这是 [`137`](137-a-boot-should-answer-the-question-nobody-asked.md)
那份"没有探针"清单的第四次收口，收的是 `vibrator`。但收的过程发现的东西比一个探针重要得多：
**那一行点名的"仪器"是另一台手机（LeEco X2）的芯片**——因为刷进去的 boot image 里**,贴着的设备树包含两台手机的**，
而两台手机的根 `compatible` **逐字节相同**。
新工具 `scripts/device/zl1-vibrator-probe.sh`（只读、**一个字节都不写**）与它的 harness **115 项**；
`zl1-hardware-inventory.sh` 因此多了一个 **board 列**（读每棵树自己的 `model`）、`--board zl1|x2|all`、一个按**文件**的普查、
一个"只被另一台手机声明"的独立结论，以及 `--boards`；它的 harness 从 74 项涨到 **114 项**。
清单从 **9 个缺口**变成 **8 个**；探针同时接进"一次启动"的默认集（新步骤 **04f**，与 04b/04c/04d/04e 同一类：只读、不写、不需要人在场）。
家族 **24 个 harness / 2789 检查 / 全绿**（本页之前是 2627 / 23）。

**接续**: [`137`](137-a-boot-should-answer-the-question-nobody-asked.md)（缺口的来源与清单本身）、
[`139`](139-the-two-blocks-a-finger-touches-first.md)（前一天收的两个——手指最先碰到的两个）、
[`138`](138-the-hardware-limiter-had-never-been-read.md)（硬件限温器）、
[`124`](124-the-boot-a-finger-bought-is-one-command.md)（一次启动是一个命令）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 为什么这一轮不是"加一个探针"？ | 因为 `vibrator` 那一行**本来就是错的**。它点名的节点是 `/soc/i2c@75b7000/drv2604l@5a`（`ti,drv2604l`），而那是**另一台手机**（LeEco X2）的第二个触觉芯片 |
| 怎么会有另一台手机的设备树？ | 刷进去的是 `halium-boot-zl1-v63-rebuilt.img`，它**贴着的设备树 blob 里有 28 棵树**：**5 棵是这块板**（`LE_ZL1-*`），**23 棵是 X2**（`LE_X2-*`）。那次构建把这两个板都支持的设备树一起贴进去了 |
| 为什么以前没发现？ | 因为旧清单是按**目录**归类的：23 棵 X2 的树只出现在 rebuilt 集合里，于是那条笔记写成了"only in the rebuilt set"——**一个好奇点，而不是一条线索**。真话是"只在 rebuilt 集合里"= "**在另一台手机的集合里**" |
| 为什么 `compatible` 认不出来？ | 两台手机的根 `compatible` **逐字节相同**：`qcom,msm8996-mtp\0qcom,msm8996\0qcom,mtp`。所以树里那约 25 个探针用的 `grep -qa msm8996 /proc/device-tree/compatible` 这道闸门，**被另一台手机的树满足了** |
| 那什么能认出来？ | 只有 `model`：ZL1 是 `Letv Technologies, Inc. MSM 8996pro + PMI8996 LE_ZL1-DVT1`，X2 是 `... MSM 8996 v3 + PMI8996 LE_X2-PVT`。于是这个探针是这棵树里**第一个按 `model` 而不是按 `compatible` 判断板子的探针** |
| 这块板真正的振动马达是什么？ | PMI8994 自己的触觉外设：`/soc/qcom,spmi@400f000/qcom,pmi8994@3/qcom,haptic@c000`，`compatible = qcom,qpnp-haptic`，驱动 `drivers/platform/msm/qpnp-haptic.c`，注册一个叫 `vibrator` 的 timed_output 设备——也就是 `/sys/class/timed_output/vibrator/enable`，**Android 的 vibrator HAL 往这里写毫秒数**。它在**三个集合里都有**，所以从来不是"哪个 image 启动了"的问题 |
| 两台手机的同一个节点一样吗？ | **不一样，而且正好相反**：ZL1 的 `qcom,haptic@c000` 是 `status = okay` + `qcom,wave-shape = sine`；X2 的是 `status = disabled` + `square`。所以"启动落在了另一台手机的树上"这件事，**这个块本身就是那个读数** |
| 探针怎么报？ | 先报板子，再报阶梯：`tree-unscanned`（没有 `find(1)` **且**没有已知节点形状——**"没法看"不是"不在"**）/ `wrong-board-tree` / `unknown-board` / `no-device-tree-node` / `node-disabled` / `driver-not-bound` / `no-timed-output` / `registered` |
| 它写东西吗？ | **一个字节都不写。** 而这一条在这里最要紧：`enable` **是可写的，写一个毫秒数手机就会震**。所以"震不震"是一个**单独的、要单独评审**的步骤，不是取一次读数的副作用——verdict 里明写 |
| 设备树里的数字怎么读？ | 一个 u32 是**四个大端字节**，所以 `qcom,vmax-mv` 的 3700 是 `00 00 0e 74`。顺手用 `od -tu4` 会印出 `0x740e0000`——**一个形状正确、数值错误的读数**。探针按字节组合，长度不是 4 就报 `not-a-u32(N bytes)` |
| 清单改了什么？ | 每行多一个 **board 列**（读那棵树自己的 `model`）、默认只报这一台（`--board all|x2` 看别的）、一个**按文件**的普查（`# boards: Fz 5 Rx 23 Rz 5 Sz 5`）、`--boards`（一行一棵树：集合/板子/sha256/大小/`model`），以及一条独立结论：**只被另一台手机声明**的块 |
| 这一改抓出了什么真缺陷？ | **两条**：①另一台的过滤器（`--board x2`）把 `model` 两个板子都不认的树**丢掉了**——正是那份报告存在的理由被自己违反；②快照**写的时候用了过滤后的数据**，于是"从快照读"和"从 DTB 读"给出**不同的报告**（688 vs 699 个路径）——harness 的"两条路必须一致"那条抓住了它 |
| 离线验证？ | `zl1-hardware-inventory-selftest.sh` **114 项**（+40），`zl1-vibrator-probe-selftest.sh` **115 项**。板子那部分用**三棵只差 `model` 的树**，而且**故意不对称**（这台两个节点、另两台各一个），三档过滤器给出**三组不同的数字**；七个 board 变异各让它红 **16–34 次**，六个读数变异各让它红几次 |
| 动设备了吗？ | **没有。** |

---

## 2. 这一轮真正收到的东西：清单自己的一个错误

`137` 那份清单的价值在于它把"缺什么"变成了一句话。但它也有一行是错的，而且是**同一个方向**的错误——把**没有**探针的说成**有**？

不是。这次是相反方向，而且更隐蔽：**它把一个块判给了这台手机，而那个块是另一台手机的**。

```
旧行（docs 137 的第 172 行）：
vibrator         1     **NONE**                               R      <- 只在 rebuilt 集合里
```

"只在 rebuilt 集合里"是一句**笔记**。它的意思是：rebuilt 那批 DTB 里有、stock 那批里没有。写这句话的人（也就是上一轮）
把它当成一个好奇点记下来，然后继续往下数。**但它是线索**：为什么一个集合会多出一个硬件？

答案是那次构建**贴进去的不止一台手机的树**：

```
38 棵树 = 5 stock(LE_ZL1) + 5 filtered(LE_ZL1) + 28 rebuilt
                                                  └── 5 是 LE_ZL1，23 是 LE_X2
                                            普查：Fz 5  Rx 23  Rz 5  Sz 5
```

```
$ bash scripts/host/zl1-hardware-inventory.sh --boards
SET   BRD  SHA256      SIZE      MODEL / FILE
S     z    009a01f567  408918    Letv Technologies, Inc. MSM 8996pro + PMI8996 LE_ZL1-DVT1
                                   tmp-dtb-analysis/stock/dtbs/stock-00-off11550824-size408918.dtb
...
R     x    cfe46ed53f  413017    Letv Technologies, Inc. MSM 8996 v3 + PMI8996 LE_X2-PVT
                                   tmp-dtb-analysis/rebuilt/dtbs/rebuilt-00-off11836453-size413017.dtb
38 device tree(s); BRD z=LE_ZL1 (this phone) x=LE_X2 (a different phone) ?=names neither
```

而且这两台手机的根 `compatible` **逐字节相同**：

```sh
# 两台手机的 /proc/device-tree/compatible 完全相同
qcom,msm8996-mtp\0qcom,msm8996\0qcom,mtp
```

所以树里约 25 个探针的**设备闸门**——

```sh
grep -qa msm8996 /proc/device-tree/compatible || { echo "not a zl1"; exit 2; }
```

——**被另一台手机的树满足了**。这不是这棵树里任何探针的错（它们从没打算分辨两台同 SoC 的板子），
但它意味着：**"板子对不对"这件事，只有 `model` 能回答**，而清单必须先回答它，才谈得上"这块板上有没有这个硬件"。

> 顺带记下这一轮踩到的一个 shell 陷阱（写在代码里了）：一行以 `|| true` 结尾、紧接着一个 `case`，
> 放在 `x=$( ... )` 里在 bash 5.1 是**语法错误**（`syntax error near unexpected token ';;'`）。
> 用最小复现定位到之后，改成"`case` 在前、不要 `|| true`"。

---

## 3. 设备树里到底有什么

```sh
# 三个集合里唯一的触觉节点（ZL1 与 X2 同一个地址，属性相反）：
/soc/qcom,spmi@400f000/qcom,pmi8994@3/qcom,haptic@c000
    compatible = qcom,qpnp-haptic          # 三个集合里都有
    LE_ZL1:  status = okay      qcom,wave-shape = sine
    LE_X2:   status = disabled  qcom,wave-shape = square

/soc/i2c@75b7000/drv2604l@5a
    compatible = ti,drv2604l                # 23 棵 X2 的树全都有；5 棵 ZL1 一棵都没有
```

三件事值得单独说：

* **这一块上有一个"板子对不对"的读数。** X2 的同一节点是 `status = disabled`，所以如果启动落在错的树上，
  `driver-not-bound` 之前的那一级就会说 `node-disabled`——而**探针会把板子印在它前面**，因为"这个块的读数不对"
  和"这整棵树都不是这块板"是两句不同的话，第二句会决定整次启动的其它所有读数。
* **`ti,drv2604l` 不是"另一个候选驱动"，是别块板的芯片。** 旧行把它写成 `NONE`（没人读它）其实在**数字上**是对的，
  在**归属上**是错的：它属于另一台手机，所以它既不是这台手机的缺口，也不该出现在这台手机的表里。
* **timed_output 不是一个内核子系统里的小角落。** `timed_output_dev.name = "vibrator"` 就是 Android
  vibrator HAL 的入口；Ubuntu Touch 侧（`repowerd`/`feedbackd` 一类）用的是同一类接口。
  所以这条链**在哪一侧被点亮**是另一个问题，这一页只回答"驱动注册了没有、条目在不在"。

---

## 4. 探针：先认板子，再爬阶梯

`scripts/device/zl1-vibrator-probe.sh`，`/bin/sh`，**只读、不写任何东西**（连临时文件都不写，
所以内核日志是收进 shell 变量里的——这正是 harness 里那条"写自由"检查要断言的东西）。

```
tree-unscanned        没有 find(1) 且没有已知节点形状   -> 退出 2：这是"没法看"，不是"不在"
wrong-board-tree      /proc/device-tree/model 是 X2 的  -> 这一轮的所有读数都不是这块板的
unknown-board         model 两个都不认                  -> 先说清楚，再往下读
no-device-tree-node   /soc/**/qcom,haptic@* 不存在       -> 树里没有这个块
node-disabled         status = disabled                 -> 驱动绑不上（X2 的树就是这一级）
driver-not-bound      qpnp_haptic 目录在、没有设备挂上   -> probe 失败；下一手是内核日志
no-timed-output       /sys/class/timed_output 没有 vibrator
registered            条目在、驱动绑上、属性组读得出来    -> 健康；"震不震"不在这里回答
```

读数按源码取，不靠猜：节点印 `status` / `qcom,wave-shape` / `qcom,actuator-type` / `qcom,vmax-mv` /
`qcom,play-mode`；驱动那一级印 `/sys/bus/platform/drivers/qpnp_haptic/` 里**挂上去的设备**；
条目那一级印**属性组**（`wf_s0..wf_s7`、`wf_update`、`wf_rep`、`wf_s_rep`、`play_mode`、`dump_regs`、
`ramp_test`、`min_max_test`），属性名是从 `qpnp-haptic.c` 里抄的——所以"这个条目是另一个驱动注册的"
是一个**读数**，不是一个假设。长度不是 4 的属性报 `not-a-u32(N bytes)`，不崩、也不猜。

---

## 5. 清单的修正：board 列，以及它抓出的两个真缺陷

改动都在 `zl1-hardware-inventory.sh` 里：

| 改动 | 为什么 |
|---|---|
| 每行多第 4 个字段 **board**（`z`/`x`/`?`），从每棵树自己的 `model` 读出来 | 只有 `model` 能分辨两台板；`?` 是"这棵树谁都不认"，**不是**失败 |
| `--board zl1`（默认）/ `x2` / `all` | 一份关于这台手机的报告不该把另一台手机的硬件算进来 |
| 每文件一行 `#file  <path>  <set>  <board>  <model>` + 普查 `# boards: Fz 5 Rx 23 Rz 5 Sz 5` | 普查按**文件**数，所以"38 棵里 23 棵是另一台"是可读的；按节点会淹掉 |
| 一节 **"只被另一台手机声明"** | 这种行**既不是缺口**（那会说"这台手机有这个硬件而没人读"）**也不是坏模式**。它是自己的结论，而且它就是旧 `vibrator` 行的形状 |
| `--boards`：一行一棵树，配对 sha256/大小/`model` | 报告里"贴着的 blob 有两台手机"是一句关于 38 个文件的话，得有一个能核对的读数；两个列表的顺序是**断言**的（`MISPAIRED`），不是假设的 |
| 快照带 board 列（699 路径 / 725 对 → **1413 行**带 board） | 不带，读回来时过滤器比较的是空字段，于是每一行都留下 |

两个真缺陷是**被自己的 harness 抓出来的**，都不是手写时看出来的：

1. **`--board x2` 把"谁都不认"的树丢了。** 过滤器写成 `$4 == "x"`，看起来对，实际把 `?` 全都排除——
   而 `?` 恰恰是"这台报告认不出来的树"，在一份以"看看另一台手机"为目的的报告里把它丢掉，正好是它不该做的事。
   harness 的三棵不对称的树让两个方向给出**不同的数字**，所以它红了（少了 1 个路径、1 对 compatible）。
2. **快照写成了过滤后的数据。** 于是 `--snapshot` 和读 DTB **给出不同的报告**（688 vs 699 个路径）：
   快照没有 board 列 → 过滤器拿空字段比较 → 什么也没过滤掉。修法是快照**永远写未过滤的全量**（两种手机都在），
   过滤在读回来的时候做——这样 `--board x2`/`all` 在一个新克隆里也是可复现的（那正是快照存在的理由）。

---

## 6. harness：114 + 115，十三个变异

`scripts/host/zl1-hardware-inventory-selftest.sh`：74 → **114 项**。新增的一节是**三棵只差 `model` 的树**：

* **故意不对称**（这台两个节点、另两台各一个），所以三档过滤器给出**三组不同的数字**——
  一个"什么都不做"的过滤器不可能通过；
* `?` 必须在**两个**方向上都留下（一个认不出来的树不该消失）；
* 同一个节点在三棵树里必须产生**三行**（board 是行身份的一部分，不是装饰）；
* 三行表 + 三档过滤器证明**方向**：默认档下这台手机的块在表里、另一台的块在另一节；`--board x2` 时两者**互换**，
  而 `?` 那行两档都是缺口；
* `--boards` 一行一棵树（集合/板子/sha256/大小/`model`），并且**数出它印了几棵**。

`scripts/host/zl1-vibrator-probe-selftest.sh`：**115 项**。纪律与兄弟一致（stub 目录**就是**设备、PATH 沙箱化、
两趟 token 改写且 landing 数作为不变量断言、一级一个场景、名字与退出码都断言），加上这里特有的两条夹具：

* **大端 u32**：`qcom,vmax-mv` 的 3700 是 `00 00 0e 74`。变异**反转组合顺序**而不是"换字节序"——
  后者实测**什么都没改变**（`od -tu4` 在两种写法下都碰巧印出 3700），一个不改变可观测量的变异什么都没测；
* **"没法看"与"不在"**：一个**什么工具都有、就是没有 `find(1)`** 的沙箱，让 `tree-unscanned`（退出 2）
  与"没有这个节点"分开。把两者合并是这一族最老的缺陷（docs 72）。

| 变异（对清单脚本） | 红 |
|---|---|
| `root_model` 去读 `compatible`（于是板子恒为 `?`） | 32 |
| 默认过滤器改成 `== "z"`（把 `?` 丢掉） | 34 |
| 另一台过滤器丢掉 `?`（**本轮修掉的那个**） | 16 |
| "只被另一台声明"的行当成缺口 | 19 |
| `#file` 印板子字母而不是 `model` | 18 |
| 快照列顺序反过来（board 跑到过滤器读的字段上） | 18 |
| `board_of` 恒返回 `z`（闸门退化成"全都是这台"） | 31 |

三个"读数变异"（vibrator）：板子闸门改成测 `compatible`、去掉 `status` 检查、把空的 *bound devices* 读成"没问题"，
外加"把 `could not search` 折成 `not found`"、"反转字节组合"、"把这一台的注记静音"——各自让 115 项里的若干项变红。

---

## 7. 设备状态与复现

整轮没有动设备：没有写任何分区或 boot，没有跑 QDL/QFIL，没有重启。设备仍在 **Qualcomm EDL**（`05c6:9008`）。
识别目标一律按序列号 **`33e80afe`**；总线上另一台小米 **`4a2fe00b`** 必须忽略。恢复仍然只能靠**物理长按电源 10–20 秒**。

```sh
# 全部在宿主机上，不碰设备。
bash scripts/host/zl1-hardware-inventory.sh --boards            # 38 棵树：集合/板子/sha256/大小/model
bash scripts/host/zl1-hardware-inventory.sh --gaps              # 现在只剩 8 个缺口
bash scripts/host/zl1-hardware-inventory.sh --board x2          # 另一台手机的表（这台手机的块会出现在"另一台"一节）
bash scripts/host/zl1-hardware-inventory-selftest.sh            # 114 项
bash scripts/host/zl1-vibrator-probe-selftest.sh                # 115 项

# 那两个变异里最重要的一个（另一台过滤器丢掉"谁都不认"的树，必须红 16 项）：
P=scripts/host/zl1-hardware-inventory.sh
python3 - "$P" <<'PY'
import sys
s = open(sys.argv[1]).read()
open('/tmp/mut-keepq.sh','w').write(s.replace("""'$4 == "x" || $4 == "?"'""", """'$4 == "x"'""", 1))
PY
ZL1_HW_INVENTORY_SRC=/tmp/mut-keepq.sh bash scripts/host/zl1-hardware-inventory-selftest.sh

# 设备回来之后（只读、不写任何东西）：
scp scripts/device/zl1-vibrator-probe.sh root@10.15.19.82:/tmp/ && ssh root@10.15.19.82 'sh /tmp/zl1-vibrator-probe.sh'
# 它会先回答"这棵树是不是这块板"，再回答振动马达在哪一级。
```

---

## 8. 这一轮**不**证明什么

* **不证明振动马达会震。** 反过来也不证明它不会。要证明需要**写** `enable`（一个毫秒数），
  那是一个**单独的、要单独评审**的步骤——这一轮没有做，也不该由一次读数顺带做掉。
* **不证明设备上落在哪一级。** 这一轮**一次 ssh 都没有**：115 + 114 项全部挡在 stub 目录后面，
  场景是我造的。设备上真实的那一级（尤其是 `status`、以及驱动有没有绑上）只有设备回来才知道。
* **不证明那 23 棵 X2 的树是"多余的"。** 它们是同一个内核支持的板子，贴在一个 boot image 里是 Halium 构建的
  正常产物。这一页说的是：**读它们的人必须知道自己在读谁**。
* **不证明树里其它探针的闸门都要改成 `model`。** 约 25 个探针的 `msm8996` 闸门在"只要不是别的 SoC"这个意义上
  仍然有效；这一页只说明**它不能分辨这两台板**——所以清单需要 board 列，而每个探针要不要跟着改是**各自的判断**，
  不在这轮的范围里。
* **不证明剩下 8 个缺口里没有更重要的。** 只是这一行本来就是错的，错的东西优先。

---

## 9. 文件与改动

| 文件 | 作用 |
|---|---|
| `scripts/device/zl1-vibrator-probe.sh` | 新：振动马达探针（PMI8994 `qcom,qpnp-haptic`），**board-first**，八级阶梯，只读**且不写任何东西** |
| `scripts/host/zl1-vibrator-probe-selftest.sh` | 新：**115 项**，stub 目录就是设备，两棵真实 `model` + 一棵谁都不认，沙箱缺 `find(1)` |
| `scripts/host/zl1-hardware-inventory.sh` | 改：board 列（读 `model`）、`--board zl1\|x2\|all`、每文件普查、`--boards`、"只被另一台声明"一节、快照带 board 列且**写未过滤全量**；`vibrator` 行改成 `qcom,qpnp-haptic\|qcom,haptic` |
| `scripts/host/zl1-hardware-inventory-selftest.sh` | 改：74 → **114 项**（三棵只差 `model` 的树、七条 board 断言组） |
| `docs/ubuntu-touch/hardware-compatibles.txt` | 改：**重新生成**——699 路径 / 725 对 / **1413 行**（带 board），38 个源文件的 sha256 不变 |
| `scripts/host/zl1-post-recovery-capture.sh` | 改：默认集新增 **04f-vibrator**（只读、不开块设备、不需要人在场），并说明为什么它的"板子"那一行值得一次稀有启动 |
| `scripts/host/zl1-post-recovery-capture-selftest.sh` | 改：149 → **152** 项（加一步必须按名字/顺序/scp 路径/归档文件全部改一遍） |
| `scripts/host/zl1-health-check.sh` | 改：新增一段（在 LED 之后、LMH 之前）把"板子这件事"和 115 项接上；0g 改写为 **8 of 29**、引用 114 项；cli-usage 引用 148 → **152**（它扫的脚本 51 → 53）；capture harness 引用 149 → **152** |
| `scripts/README.md` | 改：两个新脚本各一行；inventory 那一行改成"两台手机"的读数；inventory harness 74 → **114**；cli-usage 148 → **152** |
| `docs/ubuntu-touch/139-*.md` | 改：后续注记 + §8 缺口表（9 → 8） |
| `docs/ubuntu-touch/137-*.md` | 改：后续注记里 9 → 8，并指向本页 |
| `docs/ubuntu-touch/124-*.md` | 改：家族总数那一行续上本轮 |
| `README.md` | 改：本页的索引行 |
| `docs/ubuntu-touch/140-*.md` | 本篇 |
