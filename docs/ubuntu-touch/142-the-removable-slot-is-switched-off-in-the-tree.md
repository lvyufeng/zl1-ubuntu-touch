# 142 — 可插拔那个卡槽在设备树里是关掉的：存储控制器的两个半边

**日期**: 2026-09-24
**状态**: 本轮**没有碰设备**（设备仍在 Qualcomm EDL，见 §7）。这是 [`137`](137-a-boot-should-answer-the-question-nobody-asked.md)
那份"没有探针"清单的第六次收口，收的是 `sdcard`——它不是**一个**设备，是**两个控制器**，而且设备树明说它们**不是同一类东西**。
新工具 `scripts/device/zl1-sdcard-probe.sh`（只读、**一个字节都不写**、**从不打开块设备**）与它的 harness **158 项**；
它接进了"一次启动"的默认集（新步骤 **04h**，与 04b–04g 同一类：只读、不写、不需要人在场）。
清单从 **7 个缺口**变成 **6 个**；家族 **26 个 harness / 3116 检查 / 全绿**（本页之前是 2951 / 25）。

**接续**: [`137`](137-a-boot-should-answer-the-question-nobody-asked.md)（缺口的来源）、
[`141`](141-the-largest-gap-is-two-layers-that-fail-differently.md)（前一次收口——最大的那个：视频编解码的两层）、
[`140`](140-the-block-that-was-another-phones.md)（board 这一列是怎么来的：那一行点名的仪器属于另一台手机）、
[`124`](124-the-boot-a-finger-bought-is-one-command.md)（一次启动是一个命令）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 为什么收这个？ | 它排在清单剩下的六个里的中间位置（两个节点），但**它问的问题最容易被一次读数答错**：这块板上"SD 卡能不能用"这个问题，**内核层面根本还没被问到** |
| 这个块为什么不是一个设备？ | 设备树里有两个 `qcom,sdhci-msm` 节点：`/soc/sdhci@7464900` 带 `qcom,nonremovable`（厂商叫它 `sdhc1`），`/soc/sdhci@74A4900` 带 **`cd-gpios`**（一个卡检测引脚）——所以后者是**可插拔**那个（`sdhc2`） |
| **最要紧的那条读数** | **可插拔那个在设备树里是 `status = "disabled"`，而且是全部 38 棵设备树都如此**（三个集合、两台手机）。内核因此**根本不会为它建 platform device**：**空卡槽**和**"这个内核驱动不了的卡槽"读到的东西一模一样** |
| 那这是故障吗？ | **不是。** 这是 boot image 里的一处**设备树决定**，不是运行时故障。要让它工作要么改设备树（改 boot image），要么写驱动的 `disable_slots` 位掩码——**两者都是单独的、要单独评审的步骤**，不是取一次读数的副作用 |
| 那探针怎么报？ | 它把这件事**单独印成一段**，而不是把它混进 verdict："THE REMOVABLE SLOT IS SWITCHED OFF IN THE DEVICE TREE（2 个控制器里 1 个带 cd-gpios，而且它是关掉的）" |
| 为什么不能简单看 `/dev/mmcblk0`？ | 因为**读它就是一个写级别的动作**：打开一个块设备。这个项目**不在手机上打开块设备**（docs 120 的 modem 规则）。所以探针读 `/sys/block/*/size`、`/proc/partitions`、`/proc/mounts`，并在报告里明说 |
| 那 `mmc0` 是谁？ | **不知道，而且光看数字永远不会知道。** mmc core 从 idr 里取**最小可用编号**给主机（`mmc%d`），`mmcblk` 的下标来自它自己的 `find_first_zero_bit()`——而这个驱动设了 `PROBE_PREFER_ASYNCHRONOUS`。所以**编号是分配顺序，不是设备树顺序**；探针把每个 `mmcN` 连**它的 parent device** 一起印，两个控制器靠 parent 区分，从不靠编号 |
| 还有一条容易错的？ | 槽位下标来自 **`sdhc` 别名**（`of_alias_get_id`，没有就 `Failed to get slot index` 直接放弃），而且槽 1 还要过**内核命令行**那一关：`if ((ret == 1) && !sdhci_msm_is_bootdevice(...)) ret = -ENODEV;`——这个 helper 在**没有** `androidboot.bootdevice=` 时返回 true，所以在这个端口上**那一关不会拦**。两条都印出来，因为"树说 okay 而驱动还是拒绝了"在这里是一个真实的形状 |
| 探针怎么报？ | 先报板子，再爬阶梯：`tree-unscanned` / `wrong-board-tree` / `unknown-board` / `no-device-tree-node` / `all-controllers-disabled` / `driver-not-bound` / `no-mmc-host` / `no-card` / `card-enumerated` |
| 它写东西吗？ | **一个字节都不写。** 而这里尤其要紧：`disable_slots` 和 `nocmdq` 都是 `module_param(..., S_IRUGO\|S_IWUSR)` = **0644**，每个块设备旁边都有可写的 `force_ro`，而"跑一次看看"的最自然形式——打开 `/dev/mmcblk0`——本身就是这个项目不做的那类动作 |
| 离线验证？ | `scripts/host/zl1-sdcard-probe-selftest.sh`，**158 项**：stub 目录**就是**设备，一级一个场景，**三条根路径**（`/proc/`、`/sys/`、`/dev/mmcblk`）的改写，设备树属性按**字节**写（u32 是四个大端字节，`cd-gpios` 是三格而第一格是 phandle），一个"除了 `find(1)` 什么都有"的沙箱，八个变异各让它红 |
| 动设备了吗？ | **没有。** |

---

## 2. 设备树里到底有什么（读数，不是猜测）

`--block sdcard` 只告诉你有两个节点。下面是这两个节点的属性，从 DTB 里逐字读出来的：

```
/soc/sdhci@7464900                    别名 sdhc1        status = ok
    compatible = qcom,sdhci-msm        qcom,msm-bus,name = sdhc1
    qcom,bus-width = 8                 qcom,nonremovable   （空属性：布尔）
    qcom,bus-speed-mode = HS400_1p8v HS200_1p8v DDR_1p8v
    qcom,clk-rates = 400000 20000000 25000000 50000000 96000000 192000000 384000000
    sdhc-msm-crypto -> phandle 297 = /soc/sdcc1ice@7443000  （qcom,ice, status = ok）
    qcom,ice-clk-rates = 300000000 150000000
    qcom,vdd-io-always-on              reg-names = hc_mem core_mem cmdq_mem
    vdd-supply -> 298   vdd-io-supply -> 250   pinctrl-names = active sleep

/soc/sdhci@74A4900                    别名 sdhc2        status = disabled   ← 全部 38 棵
    compatible = qcom,sdhci-msm        qcom,msm-bus,name = sdhc2
    qcom,bus-width = 4                 （没有 qcom,nonremovable）
    qcom,bus-speed-mode = SDR12 SDR25 SDR50 DDR50 SDR104
    cd-gpios = <&tlmm 95 1>            reg-names = hc_mem core_mem
    （没有 sdhc-msm-crypto）
```

`cd-gpios = <&tlmm 95 1>` 是**三格**：第一格是 **phandle**（28 = `/soc/pinctrl@01010000`，`qcom,msm8996-pinctrl`），
第二格是 **gpio 95**，第三格是**极性标志**（1 = `GPIO_ACTIVE_LOW`）。**只印 "95" 是把"哪个控制器上的 95 号脚"留给读者去猜**，
而把这个属性当成**一个** u32 读会得到一个**形状对、值错**的数字——所以探针把 phandle 解析出来、把极性译出来印，
遇到两个节点带同一个 phandle 时印 `AMBIGUOUS(n)` 而**不挑一个**。

三条从**源码**里读出来、而不是从日志里猜出来的：

* **`sdhci_msm_probe()` 的顺序是有意义的**：先 `sdhci_msm_ice_get_dev()`（`-EPROBE_DEFER` 打 `"required ICE device not probed yet"`，
  `-ENODEV` 打 `"ICE device is not enabled"` 并且**只是一条 warning**——即 ICE 是可选的），再 `of_alias_get_id(np, "sdhc")`
  （`<= 0` 就打 `"Failed to get slot index"`），**然后**才是槽 1 的那一关，再然后才看 `disable_slots` 的位。
  顺序重要是因为**"ICE 设备没先 probe"会让这个驱动永远 defer**，而那是路径问题不是硬件问题。
* **`disable_slots` 是"读一次"的**：`module_param(..., S_IRUGO|S_IWUSR)`，它的第 N-1 位在 **probe 时**决定跳过槽 N。
  所以"写它一下"**对这一次启动不会有任何影响**——写它仍然是单独的、要评审的一步。
* **`sdhci_msm_is_bootdevice()` 在命令行没有 `androidboot.bootdevice=` 时返回 true。** 这个端口刷进去的 cmdline
  （docs 20 记的那条）**没有**这个 token，也没有 `datapart=`——所以槽 1 那一关**在这个端口上不会拦**。探针还是把这条读出来印，
  因为反过来的形状（树说 okay、驱动却拒绝了）在这里是可能的，而原因会是**一个 cmdline token**，不是故障。

---

## 3. 为什么"编号"不能用来认控制器

这是本页最值得单独记下来的一条，因为它是**一份看起来像读数的猜测**：

```
mmc core (drivers/mmc/core/host.c)   主机名 = "mmc%d"，d 来自 idr 里的最小可用编号
mmc block (drivers/mmc/core/block.c) mmcblk%d 的下标来自自己的 find_first_zero_bit()
sdhci_msm_driver                     .probe_type = PROBE_PREFER_ASYNCHRONOUS
```

三行合起来的意思是：**哪个控制器先 probe 完，谁就是 `mmc0`**——设备树里的先后**决定不了**。
所以"`mmc0` 是那个不可插拔的"是一句**没有依据**的话，而它长得像一句读数。
探针的处理是把每个 `mmcN` 连**它的 parent device** 一起印：

```
   mmc0   parent device: 7464900.sdhci
     card:        NONE -- the host is up and no card enumerated behind it
```

两个控制器靠 parent（`<地址>.sdhci`）区分，**从不靠编号**。fixture 里也特意把编号造成"和别名对不上"的样子
（别名说槽 1，idr 发的是 0），这样"信编号"的写法和"读 parent"的写法会**给出不同的答案**——
这也正是 harness 里那条专项断言要保的东西。

---

## 4. 探针：先认板子，再爬阶梯

`scripts/device/zl1-sdcard-probe.sh`，`/bin/sh`，**只读、不写任何东西**（连临时文件都不写，内核日志收进 shell 变量）。

```
tree-unscanned          没有 find(1) 且没有已知节点形状   -> "没法看"不是"不在"
wrong-board-tree        /proc/device-tree/model 是 X2 的  -> 这一轮的所有读数都不是这块板的
unknown-board           model 两个都不认 / 读不出来
no-device-tree-node     树里没有 qcom,sdhci-msm 节点      -> 驱动没有可绑的东西
all-controllers-disabled 每个节点的 status 都不是 okay    -> 内核不建 platform device：设备树决定，不是运行时故障
driver-not-bound        驱动声明了、也 enabled，但没有设备绑上去（目录不在 / 目录空，两种都印）
no-mmc-host             绑上了但没有 mmc 主机注册        -> 驱动后半段失败，日志那节说哪一段
no-card                 主机起来了、后面没有卡          -> 不可插拔那个这是"有意思"的读数
card-enumerated         /sys/block/mmcblkN 有 size       -> 介质应答了，块层注册了
```

读数按源码取：节点印 `status`、别名、`qcom,msm-bus,name`、`qcom,bus-width`、speed modes、`qcom,clk-rates`（**每一格**，
因为第一格 400 kHz 不是任何人想要的数）、inline crypto 的 phandle 解析、`cd-gpios` 的 phandle/gpio/极性、
pinctrl 组；驱动那节印绑定列表和 `disable_slots`/`nocmdq`（并标明 0644、本探针不写）；主机那节印 `mmcN` 连同 parent、
driver、以及卡子节点（`mmcN:XXXX` 的 `name`/`date`/`serial`——**那是卡自己的寄存器**，所以没有卡的手机印不出来）；
块设备那节印 `size`（512 字节扇区，单位明写）、`ro`、`force_ro`、分区，以及 `/proc/partitions` 和 `/proc/mounts` 的对照读数。
长度不是 4 的设备树属性报 `not-a-u32(N bytes)`，不崩、也不猜。

---

## 5. 最要紧的一条：**空卡槽**不是**读卡器坏了**

这一页真正值得记下来的，是探针里那段单独印出来的话：

```
   THE REMOVABLE SLOT IS SWITCHED OFF IN THE DEVICE TREE (1 of 2 controllers carry a
   cd-gpios and every one of them is disabled). In all 38 device trees of the three
   sets -- the other phone's included -- so this is not a board quirk of the zl1, it is
   how the vendor shipped both boards. Switching it on is a device-tree change inside
   the boot image (or a write to the driver's writable disable_slots bitmask, which is
   read once at probe time and would do nothing on this boot).
```

它**必须**单独印，因为在一台没有插卡的手机上，下面三件事**产生同一份读数**：

| 情况 | 读数 |
|---|---|
| 卡槽是空的 | 没有 host 上的卡子节点，没有 `/sys/block/mmcblk*` |
| 卡槽在设备树里是关掉的 | 同上，**而且连 platform device 都没有** |
| 内核根本没编这个驱动 | 同上 |

前两种**在这一代内核里不可区分**（都是"没有媒体"），第二种和第三种靠**驱动目录在不在**分开。
所以"SD 卡能不能用"这个问题**只有两种办法回答**：插一张卡（物理动作），或者改设备树（boot image 写操作）——
而**两者都不该是一次读数的副作用**。这也是 harness 里第六个变异要保的东西：把这段话静音，
"卡槽是关掉的"就退化成"读卡器坏了"。

---

## 6. 为什么这个探针的写守卫值得单独评审

这个块在**每一处**都可写，而且最容易想到的"测一下"正好是**这个项目禁止的那个动作**：

```
/sys/module/sdhci_msm/parameters/disable_slots   0644   probe 时读一次的位掩码
/sys/module/sdhci_msm/parameters/nocmdq          0644
/sys/block/mmcblk*/force_ro                      可写   写保护锁
/sys/block/mmcblk*/ro                            可写
读 /dev/mmcblk0 看看它答不答应                    打开一个块设备 —— 这是写级别的动作
```

所以 probe 里印的是 `/sys/block/*/size`（**同一个数字，不碰介质**），并且报告里明说它**没有**打开任何块设备。
harness 的第一条变异就是往里塞一句 `printf 0 > /sys/block/mmcblk0/force_ro`——**解除写保护**，
这是"存储探针"最容易被诱惑写下去的那一句；写守卫必须抓住它。
第二条静态检查（`--help` 输出里那句 "never opens /dev/mmcblk*"）是**断言**而不是注释：
这句话在报告里，是因为不印它的话，"读了一次 size"和"打开了一次设备"看起来是一样的。

---

## 7. 设备状态与复现

整轮没有动设备：没有写任何分区或 boot，没有跑 QDL/QFIL，没有重启。设备仍在 **Qualcomm EDL**（`05c6:9008`）。
识别目标一律按序列号 **`33e80afe`**；总线上另一台小米 **`4a2fe00b`** 必须忽略。恢复仍然只能靠**物理长按电源 10–20 秒**。

```sh
# 全部在宿主机上，不碰设备。
bash scripts/host/zl1-hardware-inventory.sh --block sdcard      # 2 个节点，现在有仪器了
bash scripts/host/zl1-hardware-inventory.sh --gaps              # 现在只剩 6 个缺口
bash scripts/host/zl1-sdcard-probe-selftest.sh                  # 158 项

# 那条最要紧的变异（解除写保护，必须红）：
P=scripts/device/zl1-sdcard-probe.sh
sed 's#^  SZ=\$(rd "\$b/size")#  printf 0 > /sys/block/mmcblk0/force_ro; SZ=$(rd "$b/size")#' "$P" > /tmp/mut-ro.sh
ZL1_SDCARD_PROBE_SRC=/tmp/mut-ro.sh bash scripts/host/zl1-sdcard-probe-selftest.sh

# 设备回来之后（只读、不写任何东西、不打开块设备；或直接跑 capture，它已经把 04h 放进默认集）：
scp scripts/device/zl1-sdcard-probe.sh root@10.15.19.82:/tmp/ && ssh root@10.15.19.82 'sh /tmp/zl1-sdcard-probe.sh'
# 它会先回答"这棵树是不是这块板"，再回答两个控制器各自在哪一级，以及那个可插拔的槽是不是关着的。
```

---

## 8. 这一轮**不**证明什么

* **不证明 SD 卡能用，也不证明不能用。** 恰恰相反：它证明的是**这个问题在这一次启动里不成立**——
  可插拔那个控制器在内核里根本不存在（设备树 disabled），所以插卡、拔卡都不会改变任何读数。
* **不证明设备上落在哪一级。** 这一轮**一次 ssh 都没有**：158 项全部挡在 stub 目录后面，场景是我造的。
  设备上真实的那一级（尤其是不可插拔那个控制器有没有绑上、有没有卡）只有设备回来才知道。
* **不证明"打开一个块设备"是危险的。** 它证明的是**这个项目不做这件事**（docs 120 的规则），
  而这条规则在这里的代价只是多写两行（`/sys/block/*/size` 与 `/proc/partitions`）；
  **收益是这一页的每一个读数都不依赖介质本身还在不在**。
* **不证明 `disable_slots` 写下去会发生什么。** 源码说它 probe 时读一次，所以对当前这次启动**不会有影响**——
  但"不会有影响"是一句关于**这一次启动**的话，不是关于"写它是安全的"。
* **不证明改设备树就能让卡槽工作。** 那需要改 boot image 里的 DTB 并重新验证整棵树的其余部分——
  属于"需要单独决定"的那一类，本页只把它**量出来**（38 棵全 disabled，两台手机都这样）。
* **不证明剩下 6 个缺口里没有更重要的。** 只是这个块问的问题最容易被一次读数答错，而"答错"是可以量的。

---

## 9. 文件与改动

| 文件 | 作用 |
|---|---|
| `scripts/device/zl1-sdcard-probe.sh` | 新：SD/eMMC 控制器探针（两个 `qcom,sdhci-msm` 节点、可插拔槽的设备树状态、`cd-gpios` 的 phandle 解析、`mmcN` 的 parent device），**board-first**，九级阶梯，只读**且不写任何东西、不打开任何块设备** |
| `scripts/host/zl1-sdcard-probe-selftest.sh` | 新：**158 项**，stub 目录就是设备，**三条根路径**改写（含 `/dev/mmcblk`），设备树属性按字节写，`alien-node` 夹具让"搜过但没找到"在无 `find(1)` 时也可达，八个变异 |
| `scripts/host/zl1-hardware-inventory.sh` | 改：`sdcard` 行点名仪器（汇总 22/7 → **23/6**） |
| `scripts/host/zl1-hardware-inventory-selftest.sh` | 改：汇总数字改成 23/6；`sdcard` 从缺口循环移到"已覆盖、按名字与节点数断言"那一组 |
| `scripts/host/zl1-post-recovery-capture.sh` | 改：默认集新增 **04h-sdcard**（只读、不写、不需要人在场、不打开块设备） |
| `scripts/host/zl1-post-recovery-capture-selftest.sh` | 改：155 → **158** 项（加一步必须按名字/顺序/scp 路径/归档文件/步骤数与 push 数全部改一遍：11 步/9 push/12 归档 → **12 步/10 push/13 归档**） |
| `scripts/host/zl1-health-check.sh` | 改：新增一段（在 video 之后）把"两个控制器 + 可插拔那个是关掉的 + 编号不是身份"与 158 项接上；设备清单新增 **5c. SD card / eMMC hosts**；0g 改写为 **6 of 29**；cli-usage 引用 156 → **160**（它扫的脚本 55 → 57）；capture harness 引用 155 → **158** |
| `scripts/README.md` | 改：两个新脚本各一行；cli-usage 引用 156 → **160**（覆盖 70 → 72 个脚本）；capture 两行 155 → **158**、步骤 11/9/12 → 12/10/13；capture 那一行补上 04h |
| `docs/ubuntu-touch/137-*.md` | 改：后续注记 7 → **6**，并指向本页 |
| `docs/ubuntu-touch/139-*.md` | 改：后续注记 7 → **6** |
| `docs/ubuntu-touch/124-*.md` | 改：家族总数那一行续上本轮（3116） |
| `README.md` | 改：本页的索引行 |
| `docs/ubuntu-touch/142-*.md` | 本篇 |
