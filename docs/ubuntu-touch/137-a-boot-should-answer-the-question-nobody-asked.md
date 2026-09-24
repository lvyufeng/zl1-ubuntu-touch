# 137 — 一次启动应该回答的问题，从来没有人问过：哪些硬件**根本没有**探针

**日期**: 2026-09-24
**状态**: 本轮**没有碰设备**（设备仍在 Qualcomm EDL，见 §8）。这一轮做的是一件不需要设备、但决定了"下一次启动值不值"的事：
把 zl1 的硬件**从它自己的设备树里数一遍**，再问一句这个仓库里**有谁读过它**。
答案印在同一张表上：**29 个硬件块，17 个有探针，12 个一个都没有**。
新工具 `scripts/host/zl1-hardware-inventory.sh`（离线、只读、不需要手机），新 harness **74 项**（七个变异各让它红 9–19 次），
新增提交的派生数据 `docs/ubuntu-touch/hardware-compatibles.txt`（725 条 path/compatible，附每个源 DTB 的 sha256）。
家族 **21 个 harness / 2438 检查 / 全绿**（本页之前是 2360；差额 78 = 新增 harness 74 + cli-usage 136 → 140）。

> **后续**：本页列出的 12 个缺口，已有六个被关掉：`thermal-lmh`（与"发烫"最直接相关的那个）见
> [`138`](138-the-hardware-limiter-had-never-been-read.md)，通知灯与手电筒（手指最先碰到的两个）见
> [`139`](139-the-two-blocks-a-finger-touches-first.md)，`vibrator` 见 [`140`](140-the-block-that-was-another-phones.md)
（那一行原本点名的仪器属于另一台手机），剩下最大的那个 `video-codec`（十二个节点）见
> [`141`](141-the-largest-gap-is-two-layers-that-fail-differently.md)，两个存储控制器那个 `sdcard`（其中可插拔
> 的一半在设备树里是关掉的）见 [`142`](142-the-removable-slot-is-switched-off-in-the-tree.md)，而**另一台手机的 CC 逻辑
> 冒充这块板的**那个 `usb-pd` 见 [`143`](143-the-tree-enables-two-and-the-kernel-builds-neither.md)，而**两个发射器世代抢同一个寄存器窗口**的
> `hdmi` 见 [`144`](144-the-tree-is-explicit-about-the-one-nothing-can-bind.md)，而**决定这一块大小的东西是一个字符串**的
> `wfd` 见 [`145`](145-the-count-that-is-a-string.md)，而**决定它那行的配置项在它自己那个菜单之外**的
> `nfc` 见 [`146`](146-the-config-line-outside-its-own-menu.md)，而**设备树自己把节点关掉、而项目手上两颗内核都把它的驱动编进去了**的
> `fm-radio` 见 [`147`](147-the-tree-switches-off-the-block-both-kernels-build.md)，而**最后一个、也是唯一一个"什么都不缺"的**那个
> `eeprom` 见 [`148`](148-the-block-with-nothing-missing-is-the-one-that-binds-through-a-name-the-tree-never-spells.md)。所以那份清单现在是
> **0 个**：12 个缺口全部关掉，而 `zl1-hardware-inventory.sh` 的汇总行也已经改成 **29 / 0**（这两个数字是**手改**的：关掉一个缺口必须有人看见，
> 这正是那份清单存在的理由）。清单**空了之后**它也不再只是"不印"，而是明说一句"29 of 29 rows, 0 gaps"——因为一份**印不出缺口**的报告
> 和一份**没有缺口**的报告，读起来是完全一样的。本页正文不变，它是当天的读数——唯一一处更正在 §3.2 里，见上方那个引用块。

**接续**: [`124`](124-the-boot-a-finger-bought-is-one-command.md)（一次启动是一个命令——本页回答的是"这一次该测什么"）、
[`136`](136-the-two-early-exiting-readers-are-not-the-same-defect.md)（同一天：harness 之外的形状普查）、
[`129`](129-the-family-total-was-typed-and-no-harness-can-see-the-tree.md)（一个没人能看见的数字就是缺陷本身）、
[`72`](72-the-phone-ran-hot-because-of-two-things-nobody-was-measuring.md)（"没被测量的东西"的另一半）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 为什么现在做这个？ | 目标剩下的每一条（图形、全部硬件、发烫、GPS、指纹、modem、相机合成、方向）**都要设备**，而设备在 EDL，出来一次要一次物理长按。所以最值钱的工作是**把下一次启动要测什么先定下来**——而"所有的硬件都能驱动"这条，到这个项目为止**从来没有被当成一个集合量过** |
| 为什么以前没量过？ | 因为树里约 25 个探针**每一个都是为了当时那个症状写的**（屏幕黑、GPS 不说话、指纹 EINVAL）。没有一次是"把硬件列出来，问谁没有探针"，所以"缺什么"的答案一直等于"最近在查什么" |
| 硬件清单从哪来？ | **设备树**。内核能绑定的每一个块都是一个带 `compatible` 的节点，板上没有的块不可能有节点——而且这是**唯一**在设备不在手边时也能用的来源 |
| 树上到底有多少硬件块？ | 38 个 DTB、3 个集合（stock 5 个、rebuilt 28 个、filtered 5 个），去重后 **699 个路径 / 725 条 path/compatible**；归到**29 个硬件块 + 6 个基础设施行** |
| 有几个没有探针？ | **12 个**：`nfc`、`fm-radio`、`vibrator`、`torch`、`notification-led`、`video-codec`、`thermal-lmh`、`usb-pd`、`sdcard`、`wfd`、`hdmi`、`eeprom` |
| 最值得注意的两个？ | `thermal-lmh`——DTB 里有 `qcom,lmh`（**硬件限温器**）而没有任何脚本读过它，**在这台以发烫著称的机器上**；`sdcard`——两个 `qcom,sdhci-msm` 控制器，从没被碰过一次 |
| 硬件清单这件事本身有个陷阱吗？ | 有，而且是本轮最重要的发现：**stock 和 rebuilt 两个 DTB 集合描述的不是同一块板**。rebuilt 比 stock 多 **21 个节点**（v2/v3 的 SoC 系列、`tfa9890` 第二个功放、`drv2604l` 触觉驱动、`atmel_mxt_ts`/`hideep` 三个多出来的触摸控制器、USB-C 的 CC 逻辑），stock 比 rebuilt 多 **1 个**（`qcom,msm-thermal-simple`） |
| 那"板上到底有什么"由谁决定？ | **由启动的那个 image 决定**。所以这一页有一条只有设备能回答的问题：`/proc/device-tree`。`--live` 就是读它（只读，唯一碰设备的模式） |
| 还有一个更细的陷阱？ | 两个集合都把**两代显示驱动挂在同一个节点**上（`qcom,mdss_*` 和 `qcom,sde_*`），所以绑哪个是**内核**的决定，不是 DTB 的——DTB 自己回答不了自己的问题 |
| 这个工具自己出了几次错？ | 三次，全是同一类（**读数看起来对，其实是错的**）：表用 `\|` 同时当字段分隔符和 token 的"或"，于是每行的 DTB 模式只剩第一个分支、`kind` 从来不是分支依据；脚本**在自己的表里找到了自己的 token**，于是 34 个块全部"有探针"、0 个缺口；以及"散文和分区名算不算探针"（注释里的 haptics、另一个文件的 venus、`ALLOWLIST` 里的 `modem` 和 `bluetooth`） |
| "有探针"和"表烂了"是一回事吗？ | **不是，本轮把它们分开了**：`STALE` = 表里点名的**文件不在**（表错了）；`**NONE**` = 没人读这个块（**这是缺口**）。合并两者会把缺口藏起来。写进陈诉的第三种情况——文件在、只在散文里提到——判 **NONE**，因为那正是这一页要问的问题 |
| 离线验证？ | 新 harness **74 项**：FDT 解析器对**合成的**设备树（格式不是对这块板的断言，所以自己造一个是诚实的），分类器对**假仓库**（九个夹具脚本只因 token 出现在**哪里**而不同）；七个变异各红 9–19 次 |
| 动设备了吗？ | **没有。** |

---

## 2. 为什么是"集合"这个问题

目标是一句合取：「一定要让图形界面能跑起来，**所有的硬件都能驱动**，另外这台机器很容易发烫，要解决这个问题」。
图形这一条已经由用户的手和眼确认过了（docs 52、以及那条已被取代的"重启就黑屏"记录）；剩下的是硬件、发烫、以及各条仍在追的线（GPS、指纹、modem、相机合成、方向）。

这些线有一个共同点：**它们都要设备**。而这台设备的每一次启动都要一次物理长按电源 10–20 秒（docs 124 就是为了让那一次不浪费而存在的）。
所以"下一步做什么"的正确提法不是"再查哪条线"，而是：**这次启动应该回答哪些问题，才能让它值得一次按压。**

要回答这个，先要有一个**集合**。这个仓库从来没有过：

```sh
# 每个探针都是为当时的症状写的，所以"缺什么"的答案一直是"最近在查什么"
scripts/device/zl1-thermal.sh        # 因为发烫
scripts/device/zl1-gps-probe.sh      # 因为 GPS 不说话
scripts/device/zl1-fingerprint-probe.sh
scripts/host/zl1-camera-app-test.sh  # 因为要看合成
...
```

数出来是 25 个探针，覆盖得**看起来**很全。量过之后不是：**29 个硬件块里有 12 个没有任何脚本读过一次**，而其中两个与目标直接相关（`thermal-lmh` 在发烫这条上，`sdcard` 在"所有硬件"这条上）。

---

## 3. 数据从哪来：设备树，以及它自己的三个陷阱

### 3.1 为什么是 DTB

内核能绑定的每一个块都是一个带 `compatible` 的节点，**板上没有的块不可能有节点**。所以厂商自己的 DTB 是唯一一份完整的清单，而且它是**离线**的——设备在 EDL 的时候唯一还能读的硬件描述。

用的三个集合（都是 `tmp-*/`，见 §3.3）：

| 集合 | 来源 | DTB 数 | 去重后 path/compatible |
|---|---|---|---|
| **S** stock | 厂商 boot image | 5 | 693 |
| **R** rebuilt | Halium 构建产物 | 28 | 713 |
| **F** filtered | 打过补丁的 stock | 5 | 693 |
| 并集 | | 38 | **699 路径 / 725 对** |

### 3.2 三个集合不是同一块板——这是本轮最重要的读数

```
rebuilt 有、stock 没有的：21 个节点
   /soc/i2c@75b6000/tfa9890@34          nxp,tfa9890          <- 第二个功放
   /soc/i2c@75b7000/drv2604l@5a         ti,drv2604l          <- 触觉（振动）
   /soc/i2c@75ba000/atmel_mxt_ts@4a     atmel,atmel_mxt_ts   ┐
   /soc/i2c@75ba000/synaptics_dsx@4b    synaptics,dsx-i2c    ├ 三个多出来的触摸控制器
   /soc/i2c@75b9000/hideep_z@6c         hideep3d,hideep_3d   ┘
   /soc/i2c@757a000/usb_cclogic@08      cypress,cyccg        ┐ USB-C CC 逻辑
   /soc/i2c@757a000/usb_cclogic@28      analogix,ohio        ┘
   /soc/i2c@757a000/dp_analogic@38      analogix,anx7816     <- DisplayPort
   /soc/qcom,gcc@300000   qcom,gcc-8996-v2      /soc/qcom,gpucc@8c0000  qcom,gpucc-8996-v2
   /soc/qcom,mmsscc@8c0000 qcom,mmsscc-8996-v2  /soc/qcom,cpu-clock-8996@  ...
   ...（+ v2/v3 的 cpr3、mdss_hdmi_pll v2/v3、coresight tpda/tpdm、arm,armv8-pmuv3）

stock 有、rebuilt 没有的：1 个节点
   /soc/qcom,msm-thermal-simple         qcom,msm-thermal-simple

filtered 与 stock 的差别：2 个节点（+qcom,mincpubw / −qcom,msm-thermal-simple）
```

> **一处更正（2026-09-24，见 [`143`](143-the-tree-enables-two-and-the-kernel-builds-neither.md)）**：上面那三个
> `usb_cclogic` / `dp_analogic` 节点**不是这台手机的 CC 逻辑**。它们是 **LE_X2 的**——出现在那份 blob 里 23 棵 X2 树上，
> 而这台手机自己的 15 棵 ZL1 树里**一个都没有**。上面这个对照本身没错（它说的是**那份 blob** 里 rebuilt 比 stock 多了什么），
> 错的是把它们当成了这块板的硬件——这正是 [`140`](140-the-block-that-was-another-phones.md) 在 `vibrator` 那一行修过的同一类缺陷，
> 隔壁一行。这台手机的 CC 逻辑是 i2c@75b5000 上的 `tusb320@67` 和 `cclogic_dev@3d`，两个都是 `status = ok`，
> 而内核里**一个驱动都没有编**。

**所以"这块板上有振动马达吗"这个问题，DTB 自己回答不了**——它取决于启动的是哪个 image。rebuilt 多出来的那 21 个节点里有一个 `drv2604l`（触觉驱动），也有三个额外的触摸控制器；两个集合都带的两个显示驱动代际则挂在**同一个节点**上：

```
同一个地址上挂着两代驱动的节点：
  /soc/qcom,mdss_dsi@0/qcom,mdss_dsi_ctrl0@994000   qcom,mdss-dsi-ctrl      ┐ legacy（msm-3.18 时代）
  /soc/qcom,sde_dsi_ctrl0@994000                    qcom,dsi-ctrl-hw-v1.4   ┘ sde（msm-4.x 时代）
  /soc/qcom,mdss_dsi_pll@994400                     qcom,mdss_dsi_pll_8996_v2   ┐
  /soc/qcom,sde_dsi_phy0@994400                     qcom,dsi-phy-v4.0           ┘
各代独有：
  /soc/qcom,mdss_mdp@900000                         qcom,mdss_mdp           （legacy）
  /soc/qcom,sde_hdmi@9a0000                         qcom,hdmi-tx-8996       （sde）
一个节点三个 compatible：
  /soc/qcom,mdss_hdmi_pll@0x9a0600   qcom,mdss_hdmi_pll_8996_v2 / _v3 / _v3_1p8
```

**绑哪个是内核的选择。** 这就是 `--live` 存在的理由：它读设备上的 `/proc/device-tree`（只读），把"offline 的三个集合"和"真正在跑的那棵树"对上。

### 3.3 数据是 gitignore 的，所以有快照

DTB 在 `tmp-*/` 下（`.gitignore` 的 `tmp-*/`），**15 MB，而且新克隆里一个都没有**。所以这个工具还有第二种输入：`--snapshot`，读一份**提交进仓库的派生快照** `docs/ubuntu-touch/hardware-compatibles.txt`（725 行数据 + 每个源 DTB 的大小与 sha256 + 总数）。两条路给**逐字节相同**的报告，harness 在两边都断言（§6）。

（顺带：`docs/ubuntu-touch/hardware-inventory.txt` 是这个位置上前一个尝试的残留，内容是两行 ssh 超时，不是清单。它作为历史留在原处，这一页的数据在 `hardware-compatibles.txt`。）

---

## 4. 怎么算"有探针"：这一步出了三次错，全是同一类

规则本来是简单的：每个块有一个**token 集合**，在 `scripts/**` 里搜，搜到就算有探针。写成代码之后错了三次，三次都是"**读数看起来对，其实是错的**"，而且三次都往**同一个方向**错——**把没有探针的块说成有**：

| # | 错法 | 症状 |
|---|---|---|
| 1 | 表用 `\|` **同时**当字段分隔符和 token 的"或" | `read -r a b c d` 在错的 `\|` 上断开，行尾全塞进最后一个变量：**每行的 DTB 模式只剩第一个分支**，`kind` 从来不是 `INFRA`（所以 5 个基础设施行被当成硬件行），而表印出来依然整整齐齐 |
| 2 | 脚本**在自己的表里**找到了自己的 token | 每一个块都匹配到**这个脚本本身**：汇总行印的是「34 with an instrument, **0 with none**」——**一份报不出缺口的报告** |
| 3 | 散文和分区名 | `vibrator` 匹配到某文件开头段落里的 "haptics"；`video-codec` 匹配到另一个文件里的 "venus"；`modem` 和 `bluetooth` 匹配到备份脚本的 `ALLOWLIST`（那里 `modem`/`dsp`/`bluetooth` 是**分区名**） |

第 2 条就是这一页存在的理由的一半：**一个只能报"全部都有"的仪器，和没读过的写入是同一种东西**（docs 72 的那条）。护栏有三层，每一层都有夹具：

1. **排除自己**和**排除 harness**（harness 之所以提到 token，正是因为它被测的对象就是那个块）；
2. **排除备份白名单**（`backup-partitions-*`：分区名不是探针）；
3. **排除注释行和印出来的字符串**——**散文不是读数**。这一条和 docs 136 §5 给家族普查加的那条过滤是同一件事、同一个原因。

### 4.1 STALE 与"没有探针"是两件事

改到这里还剩一个判断：如果一个块**点名**了仪器文件，而文件里搜不到 token，算什么？第一版判 `STALE`（表烂了）。**这是错的**，而且错得有代价：那个文件很可能**就是**应该读这个块的探针，只是它现在不读——那正是这一页要问的问题，不是表的问题。所以：

| 判决 | 含义 | 谁的问题 |
|---|---|---|
| COVERED | 点名的文件在，**而且**读到了这个块 | —— |
| **STALE** | 点名的文件**不在** | **表**的路径写错了 |
| **NONE** | 没人读这个块（行里写 `-`，或点名的文件只在散文里提到它） | **缺口本身** |
| （单独一栏） | DTB 模式**一个节点都没匹配上** | **模式**写错了，既不算有、也不算缺口 |

把这些合并起来会把缺口藏起来——所以它们分开印，而且 STALE 那一栏还把文件路径印出来（让"表错了"可以被核对）。

---

## 5. 结果：29 个硬件块，12 个没有探针

```
BLOCK            DTB   INSTRUMENT                             SETS
display-panel    22    zl1-egl-probe.py (+5)                  F R S
display-mdp      11    zl1-camera-app-test.sh (+10)           F R S
gpu              13    zl1-egl-probe.py (+6)                  F R S
touch            6     zl1-watch-input.py (+2)                F R S
keys             3     zl1-input-devices.py (+5)              F R S
fingerprint      1     zl1-fingerprint-probe.sh (+8)          F R S
nfc              1     **NONE**                               F R S
fm-radio         1     **NONE**                               F R S
vibrator         1     **NONE**                               R      <- 只在 rebuilt 集合里
torch            2     **NONE**                               F R S
backlight        1     free-container-display.sh (+4)         F R S
notification-led 2     **NONE**                               F R S
audio-codec      67    zl1-audio-test.sh                      F R S
camera           34    zl1-camera-app-test.sh (+8)            F R S
video-codec      12    **NONE**                               F R S
wifi             6     install-wlan-bringup.sh (+2)           F R S
bluetooth        1     install-container-ns-services.sh       F R S
modem            7     zl1-modem-probe.sh (+3)                F R S
sensors          4     zl1-sensorfw-probe.sh (+8)             F R S
thermal-tsens    2     zl1-thermal.sh (+4)                    F R S
thermal-lmh      1     **NONE**                               F R S   <- 硬件限温器，没人读过
thermal-policy   4     install-cpufreq-governor.sh (+7)       F R S
battery          6     device-readonly-inventory.sh (+3)      F R S
usb              10    zl1-rndis-recover.sh (+16)             F R S
usb-pd           8     **NONE**                               F R S
sdcard           2     **NONE**                               F R S   <- 两个 sdhci 控制器
wfd              2     **NONE**                               F R S
hdmi             8     **NONE**                               F R S
eeprom           2     **NONE**                               F R S
blocks: 29 hardware -- 17 with a named instrument, **12 with none**, 0 STALE
        plus 6 infrastructure rows (coresight / interconnect / ipc / pinctrl / iommu / ufs)
```

三件事值得单独说：

* **`thermal-lmh` 是这台机器发烫这一条上的缺口**。DTB 里有 `qcom,lmh`（`qcom,lmh_v1`，硬件限温），而树里没有任何脚本读过它一次——`zl1-thermal.sh` 读的是 `thermal_zone`（tsens），`install-cpufreq-governor.sh` 读的是 `cpufreq`。**这台机器以发烫著称，而它的硬件限温器从来没有被读过。** 注意这不是说它没工作：是说**没有任何读数能说它在不在工作**。
* **`sdcard` 从没被碰过**：两个 `qcom,sdhci-msm` 控制器，`sdhci`/`mmcblk` 在整个树里一次都没出现。
* **"列了但不算缺口"的 6 行是明写的**：`coresight`、`interconnect`（时钟/调压器）、`ipc`（glink/smem/smp2p）、`pinctrl`、`iommu` 以及 `ufs`（这个端口就是从它启动的）。把它们当缺口印出来会把真正的 12 个淹掉——所以报告里它们**根本不占行**，只在汇总里计一个数。

另外，`--gaps` 那一栏顺带说明了为什么"点名仪器"比"让搜索去挑"好：第一版让搜索挑并印出**字母序最前**的那个文件，于是 `modem` 被判给 `zl1-gps-probe.sh`——那个文件只是在句子里说了 "the modem's"，而**真正探 modem 的文件在同一个列表里，字母序晚一位**。名字是一个**可以被核对**的断言（对不上就 STALE），字母序不是。

---

## 6. harness：74 项，七个变异

`scripts/host/zl1-hardware-inventory-selftest.sh`。两端各自攻一次，因为这一页的产物**整个就是一句断言**：

* **解析器对合成的设备树**。FDT 是一个格式，不是对这块板的断言，所以自己造一个是诚实的——而且两个真实出现过的 bug 各自有一个夹具**专为暴露它**而设计：
  * `FDT_END` 是 token **9**，不是 4（4 是 `FDT_NOP`）。第一版把 4 当 END，于是 `bad token 9`——而它是在**解析完两千多个节点之后**才报的，看起来像"跑通了一半"；
  * 属性填充是 `(len+3) & ~3`，不是 `(len+4) & ~3`——后者的 `+` 比 `&` 结合得更紧，所以**任何长度是 4 的倍数的属性都会让 token 流错位一个字节**，而结果是**一棵看起来合理的、更短的树**。夹具因此带：一个 NOP、一个 4 字节节点名、一个 5 字节（填充到 8）的节点名、一个 8 字节的 `reg`、一个双元素 `compatible`、以及**最后一个兄弟节点**（错位的 walk 最先丢的就是尾巴）。
  * 不是 FDT 的文件必须**退出 3 并说出是哪个文件**，绝不能走成"一棵没有硬件的树"。
* **分类器对假仓库**。把被测脚本拷到一个假根下（这样它的 `ROOT` 就是假根、搜索只扫夹具），九个夹具脚本**只因 token 出现在哪里而不同**：会在代码行里跑（COVERED）、只在注释里、只在 `echo` 里、只在备份白名单的 `ALLOWLIST` 里（那里 `modem` 是分区名）、只在被测脚本自己身上（这五种除第一种外**必须全是 NONE**）。以及一个**点名的文件不存在**的行（必须 STALE）、一个写 `-` 的行（必须是无提示的缺口）、一个模式匹配不上任何节点的行（必须进自己那一栏、不计入有也不计入缺口），和一行**不是 5 个 tab 字段**的表（必须**拒绝**——四字段的行会把仪器名填进 `kind`、把仪器留空，而**空模式让 `grep -x` 匹配每一行**，于是那一行真的印成了 COVERED 加一列空白）。

七个变异，每一个都必须让它红，而且红在**为它写的那条检查**上：

| 变异 | 红 |
|---|---|
| 去掉"排除自己" | 9 |
| 去掉注释/印出字符串的过滤（散文又算探针） | 12 |
| 去掉备份白名单的排除 | 12 |
| 让"对不上"一律判 STALE | 12 |
| 填充改回 `(len+4) & ~3` | **19** |
| token 4 当 `FDT_END` | **17** |
| `--dtb-dir` 把目录本身交给解析器 | **18** |

最后一行为什么值得单独留一个变异：第一版就是这样——目录被当成文件读，运行打出一棵**空树**、stderr 上一个 `IsADirectoryError`，而**通过管道时退出码是 0**，看起来完全像"一棵没有硬件的树"。抓住它的是 harness 里那句"报告有没有内容"（`nonempty`）：它红了之后，它下面的三十多项检查全都空了。

---

## 7. 这一轮**不**证明什么

* **不证明那 12 个块的硬件在不在。** 反过来也不证明：这里判的是"**没有脚本读过它**"，不是"它没有工作"。`thermal-lmh` 可能一直在工作——**它只是从来没有被读过一次**，所以没有任何读数能说它在不在（这正是 docs 72 那条老账的同一个形状）。
* **不证明"有探针"的那些读数是好的。** 这一页量的是覆盖的**形状**，不是它的质量；每个探针的质量归它自己的 harness 管。
* **不证明 token 集合完备。** 它是**人造的断言**，而且**错的方向很危险**：一个写错的 token 会让有探针的块显示成缺口（会被看见），但一个**太宽**的 token 会让缺口显示成有探针——第 4 节那三次错全是这个方向。防线只有两样：散文/分区名/自身的排除，以及夹具里"只在注释里"的那一行。**一个 token 集合宽到能匹配任何东西，这一页就又变成"0 个缺口"了。**
* **不证明 stock/rebuilt 那 21 个节点的差别是"谁对"。** 只证明**它们不同**，以及这件事只有设备能回答——`--live` 这一轮**没有跑**（一次 ssh 都没有）。
* **不证明 `--live` 的输出能直接用。** 它印的是设备上 `find /proc/device-tree -name compatible` 的结果，**没有和离线集合做过逐项差分**——那个差分要等设备回来。
* **不证明快照永远是这 725 行。** 它带 sha256、harness 每次核对；但如果 DTB 本身被重新解出来，会先红，然后需要人重新生成一次。

---

## 8. 设备状态与复现

整轮没有动设备：没有写任何分区或 boot，没有跑 QDL/QFIL，没有重启。设备仍在 **Qualcomm EDL**
（`05c6:9008`，Bus 003 Device 020）。识别目标一律按序列号 **`33e80afe`**；总线上另一台小米
**`4a2fe00b`** 必须忽略。恢复仍然只能靠**物理长按电源 10–20 秒**。

```sh
# 全部在宿主机上，不碰设备。
bash scripts/host/zl1-hardware-inventory.sh --gaps            # 12 个没有探针的块
bash scripts/host/zl1-hardware-inventory.sh                   # 全表 + 汇总
bash scripts/host/zl1-hardware-inventory.sh --block audio-codec
bash scripts/host/zl1-hardware-inventory.sh --snapshot docs/ubuntu-touch/hardware-compatibles.txt
bash scripts/host/zl1-hardware-inventory-selftest.sh          # 74 项

# 设备回来之后，唯一一条只有它能回答的问题（只读）：
bash scripts/host/zl1-hardware-inventory.sh --live

# 那七个变异（每个都必须让它红）：
S=scripts/host/zl1-hardware-inventory.sh
sed 's#(i + ln + 3) & ~3#(i + ln + 4) & ~3#' "$S" > /tmp/mut-pad.sh
ZL1_HW_INVENTORY_SRC=/tmp/mut-pad.sh bash scripts/host/zl1-hardware-inventory-selftest.sh
```

| 文件 | 作用 |
|---|---|
| `scripts/host/zl1-hardware-inventory.sh` | 新：离线枚举硬件 + 搜索探针（`--gaps` / `--block` / `--dump-compatibles` / `--snapshot` / `--table` / `--live`） |
| `scripts/host/zl1-hardware-inventory-selftest.sh` | 新：74 项，合成设备树 + 假仓库 + 七个变异 |
| `docs/ubuntu-touch/hardware-compatibles.txt` | 新：提交的派生快照（725 条 path/compatible + 每个源 DTB 的 sha256） |
| `scripts/host/zl1-health-check.sh` | 改：新增 0g 一节，把这份清单与"这次启动该回答什么"接上，并引用 harness 的 74 项 |
| `scripts/README.md` | 改：`host/zl1-hardware-inventory.sh` 与它的 harness 各一行 |
| `scripts/host/zl1-cli-usage-selftest.sh` | 改：它扫的是「健康检查点名过的每个脚本」，所以新建的两个脚本让它 136 → **140** 项；而且 `--help` 分支必须写成 `--help|-h)` 才被它的静态闸门认出（这个闸门存在是因为它执行脚本，而这本书里有会刷机的脚本） |
| `docs/ubuntu-touch/124-*.md` | 改：家族总数那一行续上本轮 |
| `docs/ubuntu-touch/137-*.md` | 本篇 |
