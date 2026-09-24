# 144 — 设备树明确打开的那个发射器，正是这颗内核绑不上的那个

**日期**: 2026-09-24
**状态**: 本轮**没有碰设备**（设备仍在 Qualcomm EDL，见 §7）。这是 [`137`](137-a-boot-should-answer-the-question-nobody-asked.md)
那份"没有探针"清单的第八次收口，收的是 `hdmi`——它**不是一台设备**，而是**六份描述、七个节点**：两个发射器世代
（`qcom,hdmi-tx` 与 `qcom,hdmi-tx-8996`）**抢同一个 MMIO 窗口**，各自的音频 codec-rx 子节点、一个 display 子节点、一个 PLL，
外加音频 DAI `qcom,msm-dai-q6-hdmi`（清单那一行的 pattern 自己就漏了它）。
新工具 `scripts/device/zl1-hdmi-probe.sh`（只读、**一个字节都不写**、**什么都不打开**）与它的 harness **164 项**；
它接进了"一次启动"的默认集（新步骤 **04j**，与 04b–04i 同一类：只读、不写、不需要人在场）。
清单从 **5 个缺口**变成 **4 个**。

**接续**: [`137`](137-a-boot-should-answer-the-question-nobody-asked.md)（缺口的来源）、
[`142`](142-the-removable-slot-is-switched-off-in-the-tree.md) 与 [`143`](143-the-tree-enables-two-and-the-kernel-builds-neither.md)
（前两次收口——"设备树关掉的一半"和"设备树打开、内核没编"）、
[`124`](124-the-boot-a-finger-bought-is-one-command.md)（一次启动是一个命令）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 为什么收这个？ | 它是剩下四个缺口里**唯一一个"两代驱动挂在同一个地址上"**的块——这个形状之前没被量过，而它决定了"哪一代在跑"这个问题的答案 |
| 这个块为什么不是一个设备？ | 设备树里有**七个**节点：`/soc/qcom,hdmi_tx@9a0000`（`qcom,hdmi-tx`）、`/soc/qcom,sde_hdmi@9a0000`（`qcom,hdmi-tx-8996`）、两个发射器各自的 `qcom,msm-hdmi-audio-codec-rx` 子节点、`/soc/qcom,display-manager/qcom,hdmi-display`、`/soc/qcom,mdss_hdmi_pll@0x9a0600`，以及 `/soc/qcom,msm-dai-q6-hdmi` |
| **最要紧的那条读数** | **两个发射器的 `reg` 逐字节相同**（`<0x9A0000 0x50C 0x70000 0x6158 0x9E0000 0xFFF>`，`reg-names` 也相同），也就是说**两个世代都声称这块板的 HDMI 寄存器窗口**；而**设备树明确打开的那一个，这颗内核绑不上** |
| 为什么？ | `qcom,hdmi-tx-8996` 那一个（`status = ok`）属于 **sde 世代**：`sde_kms` / `sde_dsi_ctrl` / `sde_dsi_phy` / `sde_hdmi` **全在设备树里、在这颗 3.18 内核的任何一处代码里都没有**。而 `mdss_hdmi_tx.c`（`of_match` 是 `qcom,hdmi-tx`）匹配的是**另一个**节点——那个节点**连 `status` 属性都没有**，而设备树里"没有 `status`"就是**打开** |
| 那这是故障吗？ | **不是。** 这仍然是**设备树与内核世代之间的分歧**：一个节点是给下一代内核写的描述。让 sde 那一代活起来**不是一行 config**，是换一颗内核 |
| 第二个容易读反的地方？ | **gpio 的名字**。驱动把八个名字拼成 `"qcom,hdmi-tx"` + 后缀，于是它找的是 `qcom,hdmi-tx-{hpd,mux-en,mux-sel,mux-lpm,ddc-mux-sel,ddc-clk,ddc-data,cec}`。**它绑的那个节点只带一个**（`-hpd`），而另一个世代的节点带五个——拼成 `qcom,hdmi-tx-hpd-gpio` 这样带 `-gpio` 后缀的名字，`of_get_named_gpio()` **从来不会去找**。两个节点是**同一份描述互补的两半**，而有驱动的那一半是**残缺的那一半** |
| 那这个 gpio 缺失致命吗？ | **不致命。** 找不到的 gpio 在驱动里是 `continue`（DEV_DBG 级），所以"八个里有一个"是关于**驱动拿到了什么**的读数，**不是**"DDC 那条线是坏的"的证明 |
| 第三个容易读反的地方？ | **pin 状态表整体错位一格**。`pinctrl_dt_to_map()` 把 `pinctrl-names[i]` 与 `pinctrl-i` 配对，**名字用完之后的那个状态就按它自己的下标命名**。这个节点有 **4 个名字、5 个属性**，于是 `hdmi_active` = `pinctrl-2`（hpd 活动 + ddc **挂起**）、`hdmi_sleep` = `pinctrl-3`（hpd 活动 + ddc **活动**），而**真正睡下去的那一组**（`pinctrl-4`）只能靠字面名字 `"4"` 取到 |
| 第四条读数为什么值得单独讲？ | 因为 **`connected` 是变量，不是线**。发射器的 sysfs 组（`connected`、`hpd`、`edid`、`video_mode` …）是在 **`MDSS_EVENT_FB_REGISTERED` 时建在 framebuffer 设备上的**，而 `connected`/`hpd` 都读 `hpd_state`——只有**有人把 HPD armed 起来**才会被写。而驱动在那个事件上 arm HPD 的条件是 `pdata->primary \|\| !pdata->pluggable`，这块板的节点是 `qcom,pluggable` 且不是 primary，**所以这块板上那个 arm 不会发生**。于是 `connected: 0` 有不止一个来源，"没插线"只是其中一个 |
| 那怎么知道哪个 `/dev/fbN` 是 HDMI 的？ | **不能按编号**。`mdss_fb` 用的是 `fbi_list[fbi_list_index++]`（注册顺序），**不是**设备树里的 `cell-index`（primary 0、wfd 1、hdmi 2、secondary 3）。探针按**属性**认它 |
| 那探针怎么报？ | 先报板子，再爬阶梯：`tree-unscanned` / `wrong-board-tree` / `unknown-board` / `no-device-tree-node` / `no-transmitter-enabled` / `no-driver-for-enabled-transmitter` / `driver-not-registered` / `driver-not-bound` / `no-framebuffer` / `transmitter-not-attached-to-fb` / `transmitter-bound` |
| 它写东西吗？ | **一个字节都不写，而且什么都不打开。** 这是本文件里最容易被诱惑的一块：发射器自己的 sysfs 组（`hpd`、`hot_plug`、`edid`、`sim_mode`…）全可写，**写 `hpd` 或 `hot_plug` 会改变端口状态**；它背后的 framebuffer 属性（`dsi_write`、`trigger_reset`、`blank`）也是 |
| 离线验证？ | `scripts/host/zl1-hdmi-probe-selftest.sh`，**164 项**：stub 目录**就是**设备，一级一个场景，**三条根路径**（`/proc/`、`/sys/`、`/dev/fb`）的改写，设备树属性按**字节**写，一个"除了 `find(1)` 什么都有"的沙箱，九个变异各让它红 |
| 动设备了吗？ | **没有。** |

---

## 2. 设备树里到底有什么（逐字节读出来的，不是猜的）

15 棵 LE_ZL1 树里，这七个节点**全部存在**，而且**形状与另一台手机（LE_X2 的 23 棵）完全一样**——
所以"树里有没有 HDMI"这个问题**分不出两台手机**，只能靠 `model`（这一页的探针先读 `model`，理由与 [`140`](140-the-block-that-was-another-phones.md) 相同）。

```
/soc/qcom,hdmi_tx@9a0000            compatible = qcom,hdmi-tx         status: 没有这个属性  ← 设备树读作"打开"
    reg        = <0x9A0000 0x50C 0x70000 0x6158 0x9E0000 0xFFF>
    reg-names  = core_physical qfprom_physical hdcp_physical
    phandle    = 551
    interrupt-parent -> phandle 28 (= /soc/pinctrl@01010000)   interrupts: 没有这个属性
    qcom,hdmi-tx-hpd          = <61 4 0>        ← 唯一的 gpio，而且是 PMIC MPP，不是 TLMM
    qcom,mdss-fb-map          = <62>            → /soc/qcom,mdss_mdp@900000/qcom,mdss_fb_hdmi
    qcom,pluggable、qcom,disable-load、qcom,enable-load、cell-index
    pinctrl-names = hdmi_hpd_active hdmi_ddc_active hdmi_active hdmi_sleep     ← 4 个名字
    pinctrl-0..4  = 63 64 / 63 65 / 63 64 / 63 65 / 66 64                     ← 5 个属性（2 格一组）

/soc/qcom,sde_hdmi@9a0000           compatible = qcom,hdmi-tx-8996    status = ok     ← 明确打开
    reg / reg-names: 与上面**逐字节相同**
    phandle = 67          interrupt-parent -> phandle 69 (= /soc/qcom,sde_kms@900000)   interrupts = <8 0>
    qcom,hdmi-tx-hpd-gpio       = <61 4 0>      ← 与上一节点**同一个 HPD 单元**，只是换了拼法
    qcom,hdmi-tx-ddc-clk-gpio   = <28 32 0>     ddc-data = <28 33 0>
    qcom,hdmi-tx-mux-en-gpio    = <28 27 0>     mux-sel  = <28 83 0>
    pinctrl-names = default sleep                                              ← 2 个名字
    pinctrl-0..1  = 63 65 70 / 66 64 71                                        ← 2 个属性（3 格一组）

/soc/qcom,display-manager/qcom,hdmi-display        compatible = qcom,hdmi-display（没有 status）
/soc/qcom,mdss_hdmi_pll@0x9a0600                   compatible = qcom,mdss_hdmi_pll_8996_v3_1p8
/soc/qcom,hdmi_tx@9a0000/qcom,msm-hdmi-audio-rx    compatible = qcom,msm-hdmi-audio-codec-rx
/soc/qcom,sde_hdmi@9a0000/qcom,sde-hdmi-audio-rx   compatible = qcom,msm-hdmi-audio-codec-rx
/soc/qcom,msm-dai-q6-hdmi                          compatible = qcom,msm-dai-q6-hdmi
```

pin 状态的六个 phandle 是**真实的**，而且它们正好解释了那份错位：

| phandle | 节点 | 谁引用 |
|---|---|---|
| 63 | `mdss_hdmi_hpd_active` | 两个发射器的 hpd 活动状态 |
| 64 | `mdss_hdmi_ddc_suspend` | 两个发射器的 ddc **挂起**状态 |
| 65 | `mdss_hdmi_ddc_active` | 两个发射器的 ddc 活动状态 |
| 66 | `mdss_hdmi_hpd_suspend` | 两个发射器的 hpd **挂起**状态 |
| 70 | `mdss_hdmi_cec_active` | **只有 sde 节点**引用 |
| 71 | `mdss_hdmi_cec_suspend` | **只有 sde 节点**引用 |

也就是说：**探针按名字去问的那五个 pin 状态里，`hdmi_cec_active` 这个节点根本没有名字**——
它只出现在那个"绑不上"的节点的 `default` 状态里。这是"有驱动的那一半是残缺的那一半"的又一处。

---

## 3. 真正的问题：`status` 的缺席与它的存在

`mdss_hdmi_tx.c` 的 `of_match` 表只有一项：

```c
static const struct of_device_id mdss_hdmi_tx_dt_match[] = {
	{ .compatible = "qcom,hdmi-tx" },
	{}
};
```

而 sde 世代（`sde_hdmi.c` 等）**这颗 3.18 内核里根本没有**——不是没编，是**没有这份代码**。
于是同一个地址上的两个节点里：

* 有驱动的那一个（`qcom,hdmi-tx`）**没有 `status` 属性**——设备树里这是"打开"的**默认**写法；
* 没驱动的那一个（`qcom,hdmi-tx-8996`）写着 `status = ok`，**它在这颗内核里永远不会成为 device**。

探针的 `status` 判定因此把 `absent` 放在**打开**那一支，并且这一处**有一个专门的红**：
把它挪出去，这块板唯一能驱动的发射器会读成"关闭"、绑不上的那个会读成"打开"——**一次删掉一个词，两条读数同时反向**。

### 3.1 那个指向 PMIC 的 gpio（本页第二条容易读错的读数）

`qcom,hdmi-tx-hpd` 的单元是 `<61 4 0>`：**61 是 phandle**，它指向
`/soc/qcom,spmi@400f000/qcom,pm8994@0/mpps`（`label = pm8994-mpp`，`#gpio-cells = 2`）——
**HPD 这条线接在 PMIC 的 MPP 引脚上，不是 TLMM 的引脚**。而 sde 节点在 `-gpio` 拼法下带的是
**同一个单元** `<61 4 0>`，另外四个（ddc-clk / ddc-data / mux-en / mux-sel）才是 TLMM 的 `<28 …>`。

这条读数是这一轮**从夹具里抓出来的**：harness 的第一版把 mdss 节点的 HPD 写成 `<28 61 0>`
（TLMM 的 phandle + gpio 61）——一个**看起来完全合理的数字，指向错误的控制器**。写夹具时按真字节读一遍才发现。

---

## 4. 探针：先认板子，再爬阶梯

```
tree-unscanned                 /proc/device-tree 在、但没有 find(1) 之类的"看不了"
wrong-board-tree               model 是 LE_X2（另一台手机）——**在任何硬件读数之前**
unknown-board                  model 既不是 LE_ZL1 也不是 LE_X2（或读不到）
no-device-tree-node            扫过了，没有任何节点带这七个 compatible 中的任何一个
no-transmitter-enabled         两个发射器在树里都被关掉
no-driver-for-enabled-transmitter  打开的发射器，**这颗内核的源码里**没有任何驱动匹配它（与 config 无关）
driver-not-registered          匹配上了，但驱动没注册（**这是一行 defconfig**）
driver-not-bound               注册了，但没绑上（probe 跑了并且失败，或者从没跑）
no-framebuffer                 发射器没有 `qcom,mdss-fb-map`，或 phandle 没解析到唯一节点（`mdss_fb_register()` 返回 -ENODEV）
transmitter-not-attached-to-fb 驱动绑上了、fb 节点也解析了，但没有任何 `/sys/class/graphics/fbN` 带发射器的属性
transmitter-bound              发射器绑上、fb 带属性 —— 这一块的协议读数（connected/hpd/edid/video_mode）才是读数
```

前六级是**结构性**的（树和内核世代决定），后五级是**这次启动的运行时**状态。分开是因为**下一步动作完全不同**：
`no-driver-for-enabled-transmitter` 要换内核，`driver-not-registered` 要改 defconfig 再构建 boot image，
`driver-not-bound` 要读 probe 的日志。

探针同时把三个**容易读错**的东西印在旁边而不是留给人推：

* **窗口比较**：两个发射器的 `reg` 单元逐格列出来，并明确写"两者相同，因此两者都声称这个窗口"；
* **每个 gpio 名字下两个节点各自的回答**，包括"缺，但以 `-gpio` 拼法存在"这一种；
* **每个 pin 状态解析出的 pin 节点，旁边写出它的名字**——于是 `hdmi_sleep` 指着活动引脚这件事是**看得见的**。

---

## 5. 最要紧的一条：`connected: 0` 不是关于线的陈述

`hdmi_tx_sysfs_create()` 在 `MDSS_EVENT_FB_REGISTERED` 时把这些属性建在 **framebuffer 设备**（`fbi->dev`）上，
而不是发射器设备上。也就是说：

* **有这些属性，本身就是"显示走到了注册 framebuffer 这一步"的证据**（探针用它当最后一级阶梯的判据）；
* `connected` 与 `hpd` **都读 `hpd_state`**：一个**只有人写它才会变**的变量。写它的有三条路——
  HPD 中断（在 HPD 打开并初始化之后才会 arm）、对 `hot_plug` 属性的一次写（**写级别的动作，本探针不做**）、
  以及 `MDSS_EVENT_FB_REGISTERED` 时的那次 arm；
* 而那次 arm 的条件是 `pdata->primary || !pdata->pluggable`，**这块板的节点是 `qcom,pluggable` 且不是 primary**：
  **在这块板上它不会发生**。`hdmi_tx_hpd_off()` 还会在断电时把它写回 `false`。

所以 `connected: 0` 有不止一个来源，而"没插线"只是其中一个——探针把这些**印出来**，而不是把它当成关于线的读数。
这是这一页里唯一一条**即使硬件完全正常也会看到 0** 的读数。

---

## 6. 为什么这个探针的写守卫值得单独评审

这一块的可写面是本文件里最大的一处，而且**每一项都真的会改变状态**：

| 面 | 为什么它是写级别的 |
|---|---|
| `/sys/class/graphics/fbN/blank` | 标准接口：写它会让屏幕**黑掉/亮起来** |
| `dsi_write`、`trigger_reset` | 往面板发命令、触发复位——在合成器正在扫描的 fb 上这是**可见的**动作 |
| `hpd`、`hot_plug` | 写它**改变端口状态**（`hpd_state`），也就是让上面那条读数**变成真的** |
| `edid` | 驱动自己的属性：写它等于**伪造一个显示器** |
| `sim_mode` | 读 `hpd_feature_on`：写它等于假装 HPD 曾被 arm |

探针**一个都不写、一个都不打开**，`--quiet` / `--explain` / `--help` 之外没有别的模式；
它的 harness 里九个变异，第二个就是本块最核心的那个（`status` 的缺席读成关闭），
而**写守卫的第一个变异是往发射器自己的状态里写**。

---

## 7. 设备状态与复现

整轮没有动设备：没有写任何分区或 boot，没有跑 QDL/QFIL，没有重启。设备仍在 **Qualcomm EDL**（`05c6:9008`）。
识别目标一律按序列号 **`33e80afe`**；总线上另一台小米 **`4a2fe00b`** 必须忽略。恢复仍然只能靠**物理长按电源 10–20 秒**。

```sh
# 全部在宿主机上，不碰设备。
bash scripts/host/zl1-hardware-inventory.sh --block hdmi    # 7 个节点，现在有仪器了
bash scripts/host/zl1-hardware-inventory.sh --gaps          # 现在只剩 4 个缺口
bash scripts/host/zl1-hdmi-probe-selftest.sh                # 164 项

# 本块最核心的那个变异（把"没有 status"读成关闭，必须红）：
P=scripts/device/zl1-hdmi-probe.sh
sed 's#case "\$ST" in okay | ok | EMPTY | absent) EN=yes ;; \*) EN=no ;; esac#case "$ST" in okay | ok) EN=yes ;; *) EN=no ;; esac#' "$P" > /tmp/mut-status.sh
ZL1_HDMI_PROBE_SRC=/tmp/mut-status.sh bash scripts/host/zl1-hdmi-probe-selftest.sh

# 设备回来之后（只读、不写任何东西、不打开任何设备；或直接跑 capture，它已经把 04j 放进默认集）：
scp scripts/device/zl1-hdmi-probe.sh root@10.15.19.82:/tmp/ && ssh root@10.15.19.82 'sh /tmp/zl1-hdmi-probe.sh'
# 它会先回答"这棵树是不是这块板"，再回答哪一代发射器绑上了、它的 framebuffer 是谁、以及
# connected/hpd 现在是谁写的。
```

---

## 8. 这一轮**不**证明什么

* **不证明 HDMI 能用，也不证明不能用。** 恰恰相反：它证明的是**这一块在这颗内核里停在"发射器驱动"这一层**——
  绑上、fb 注册、HPD armed 都是**前提**，没有一个是屏幕上的图像。
* **不证明 sde 那一代"坏了"。** 它是**下一代内核的描述**：这颗 3.18 内核里连那份代码都没有，
  所以"绑不上"是关于**世代**的话，不是关于硬件的话。
* **不证明那七个 gpio 里缺的六个是问题。** 找不到的 gpio 在驱动里是 `continue`：
  探针报的是**驱动拿到了什么**。DDC 这条线**可能**由 `mdss_hdmi_ddc_active` 那个 pin 状态复用出来——
  那是示波器的问题，不是 sysfs 的问题。
* **不证明 `edge` 的 pin 状态表错位有任何后果。** 它是一个关于设备树的**事实**（4 个名字、5 个属性），
  而"一个睡下去的 HDMI 发射器还drive 着 HPD 引脚会怎样"要问板子。
* **不证明设备上落在哪一级。** 这一轮**一次 ssh 都没有**：164 项全部挡在 stub 目录后面，场景是我造的。
  设备上真实的那一级（尤其是驱动目录在不在、有没有 framebuffer 带那些属性）只有设备回来才知道。
* **不证明剩下 4 个缺口里没有更重要的。** 只是这一块问的问题最容易被一次读数答错，而"答错"是可以量的。

---

## 9. 文件与改动

| 文件 | 作用 |
|---|---|
| `scripts/device/zl1-hdmi-probe.sh` | 新：HDMI 探针（七个节点、两代发射器同一个窗口、`status` 的缺席=打开、八个 gpio 名字的两个拼法、pin 状态表错位一格、`connected` 是变量不是线、fb 按属性不按编号），**board-first**，十一级阶梯，只读**且不写任何东西、不打开任何设备** |
| `scripts/host/zl1-hdmi-probe-selftest.sh` | 新：**164 项**，stub 目录就是设备，**三条根路径**改写（含 `/dev/fb`），设备树属性按字节写，一个"除了 `find(1)` 什么都有"的沙箱，**九个变异**；并抓出过我自己夹具里的一处错（HPD 单元写成了 TLMM 的 phandle + gpio 61，真值是 PMIC MPP 的 `<61 4 0>`），于是新增 `no-mpp-node` 场景专门覆盖"phandle 解析不到"那一支 |
| `scripts/host/zl1-hardware-inventory.sh` | 改：`hdmi` 行点名仪器，并补上 `qcom,msm-dai-q6-hdmi`（音频 DAI，这一行原来的 pattern **漏了它**，所以计数从 6 变成 **7**）；汇总 24/5 → **25/4** |
| `scripts/host/zl1-hardware-inventory-selftest.sh` | 改：汇总数字改成 25/4；`hdmi` 从缺口循环移到"已覆盖、按名字与节点数断言"那一组 |
| `scripts/host/zl1-post-recovery-capture.sh` | 改：默认集新增 **04j-hdmi**（只读、不写、不需要人在场、不打开设备） |
| `scripts/host/zl1-post-recovery-capture-selftest.sh` | 改：161 → **164** 项（加一步要按名字/顺序/scp 路径/归档文件/步骤数与 push 数全部改一遍：13 步/11 push/14 归档 → **14 步/12 push/15 归档**） |
| `scripts/host/zl1-health-check.sh` | 改：新增 **5e. HDMI**（两代发射器同一个窗口、`status` 的缺席、PMIC MPP 那个 gpio、pin 状态错位、`connected` 的 writer）；0g 改写为 **4 of 29**；capture harness 引用 161 → **164**；cli-usage 引用 164 → **168**（它扫的脚本 59 → 61）；新增 hdmi harness 引用 **164** |
| `scripts/README.md` | 改：两个新脚本各一行；cli-usage 引用 164 → **168**；capture 两行 161 → **164**、步骤 13/11/14 → 14/12/15；capture 那一行补上 04j |
| `docs/ubuntu-touch/137-*.md` | 改：后续注记 5 → **4 个缺口**，汇总 24/5 → **25/4** |
| `docs/ubuntu-touch/139-*.md` | 改：后续注记 5 → **4 个缺口**，缺口表补上这一轮的收口 |
| `docs/ubuntu-touch/124-*.md` | 改：家族总数那一行续上本轮 |
| `README.md` | 改：本页的索引行 |
| `docs/ubuntu-touch/144-*.md` | 本篇 |
