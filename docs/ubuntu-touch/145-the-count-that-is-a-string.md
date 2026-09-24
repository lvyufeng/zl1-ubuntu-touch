# 145 — 决定这一块大小的那个数字，是一个字符串

**日期**: 2026-09-24
**状态**: 本轮**没有碰设备**（设备仍在 Qualcomm EDL，见 §6）。这是 [`137`](137-a-boot-should-answer-the-question-nobody-asked.md)
那份"没有探针"清单的第九次收口，收的是 `wfd`——屏幕**回写/镜像**那一块。它同样**不是一台设备**：一个面板、一个 framebuffer、
一个**没有任何驱动会绑**的 display-manager 子节点，而真正决定这一块**有几个回写块**的四份数字**分散在三个节点上**，
其中一份**不是数字，是字符串**（`qcom,mdss-wfd-mode`，被**读两次**、两个后果）。
新工具 `scripts/device/zl1-wfd-probe.sh`（只读、**一个字节都不写**、**不开任何设备**、**不发 ioctl**）与它的 harness **185 项**；
它接进了"一次启动"的默认集（新步骤 **04k**，与 04b–04j 同一类：只读、不写、不需要人在场）。
清单从 **4 个缺口**变成 **3 个**。

**接续**: [`137`](137-a-boot-should-answer-the-question-nobody-asked.md)（缺口的来源）、
[`142`](142-the-removable-slot-is-switched-off-in-the-tree.md) / [`143`](143-the-tree-enables-two-and-the-kernel-builds-neither.md) /
[`144`](144-the-tree-is-explicit-about-the-one-nothing-can-bind.md)（前三次收口）、
[`124`](124-the-boot-a-finger-bought-is-one-command.md)（一次启动是一个命令）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 为什么收这个？ | 它是剩下缺口里**唯一一个"决定硬件数量的东西不是数字"**的块——这个形状之前没被量过，而它决定了"这一块有几个回写块"这个问题的答案 |
| 这一块由谁描述？ | **三个节点**：`/soc/qcom,mdss_wb_panel`（`qcom,mdss_wb`，面板）、它的 `qcom,mdss-fb-map` phandle 指向的 `/soc/qcom,mdss_mdp@900000/qcom,mdss_fb_wfd`（`qcom,mdss-fb`，`cell-index = 1`，framebuffer），以及 `/soc/qcom/display-manager/qcom,wb-display@0`（`qcom,wb-display`，**这颗内核里没有任何驱动匹配它**） |
| **最要紧的那条读数** | **这一块的硬件数量是一个字符串决定的。**`qcom,mdss-wfd-mode` 被 mdss_mdp 节点**读了两次**：一次进 `mdata->wfd_mode`（`intf` / `shared` / `dedicated`，缺席时 `pr_warn` 并取 `shared`），一次被 `mdss_mdp_parse_dt_wb()` 再读一遍，**只在值不是 `"shared"` 时**令 `num_intf_wb = 1` |
| 为什么这要紧？ | 因为 `mdss_mdp_wb_addr_setup()` 分配的是 `num_block_wb + num_intf_wb` 个回写块，而 `num_block_wb` 是 `qcom,mdss-mixer-wb-off` 的**格数**、`mdata->nwb_offsets` 是 `qcom,mdss-wb-off` 的**格数**。这块板是 2 + 1 = 3，而树里正好写了 **3 个** offset——**两者一致，而且只因为那个字符串是 `intf`**。把它翻成 `"shared"`，驱动只分配 2 个，树里还是 3 个 offset，**驱动里没有任何一处比较这两个数** |
| 那"三个 count"到底是几个数？ | 四个，来自三个地方：`qcom,mdss-wb-count = 2`（在**旋转器**节点上，`mdss_rotator.c` 读它、缺了就拒绝 probe）、`qcom,mdss-mixer-wb-off` = 2 格（= `num_block_wb`）、`qcom,mdss-wb-off` = 3 格（= `mdata->nwb_offsets`），以及**没有属性携带的** `num_intf_wb = 1` |
| 那"读两次"是怎么读的？ | `of_get_property()` 两次，从**同一个节点**：一次在 `mdss_mdp_parse_dt()`（写成 `mdata->wfd_mode`），一次在 `mdss_mdp_parse_dt_wb()`（决定 `num_intf_wb`）。**同一个字符串，两个后果，一个在显示模式上、一个在内存分配上** |
| 第二个容易读反的地方？ | **链条是一个 phandle，而且它是在"任何运行时痕迹出现之前"失败的那一环。**`mdss_wb_probe()` → `mdss_wb_dev_init()`（注册一个叫 `wfd` 的 switch）→ `mdss_register_panel()` → **从面板自己的节点**读 `qcom,mdss-fb-map` → 给 `qcom,mdss-fb` 子节点建 platform device → 那个设备自己的 probe 注册 framebuffer。**没有 phandle 时**会打印 `Unable to find fb node for device` 并返回 `-ENODEV`，而 `mdss_wb_probe()` 的出错路径会**把刚注册的 switch 注销掉** |
| 所以 `/sys/class/switch/wfd` 存在意味着什么？ | **它是一条端到端的读数**，不是若干痕迹之一：驱动绑上了、DT 解析过了、phandle 解析到了、framebuffer 设备建出来了——四步里任何一步失败，这个属性文件都不存在 |
| 那这一块"写级别"的动作是什么？ | **是 ioctl，不是 sysfs 写。**`/sys/class/switch/wfd/state` 是 `DEVICE_ATTR(state, S_IRUGO, state_show, NULL)`——**没有 store**，shell 写会被内核拒绝；值只由 `switch_set_state()` 写，而它从 `mdss_mdp_wb_set_mirr_hint()` 来，也就是**framebuffer 设备上的一个 MDP ioctl** |
| 那 `state: 0` 是什么？ | **"没有人请求过镜像"，不是"引擎死了"。**探针把这句话印在 0 的旁边，而不是把它当成故障 |
| 怎么知道哪个 `/dev/fbN` 是回写的那一个？ | **不能按编号，也不能按名字。**编号是注册顺序（`fbi_list[fbi_list_index++]`）；名字是 `fix->id = "mdssfb_%x"`，取自 `(int *)&mfd->panel`，即 `struct mdss_panel_info` 的**第一个字段 `xres`**——所以名字是**分辨率的十六进制**（640 → `mdssfb_280`），**两个同宽的面板会重名**。探针按 `msm_fb_type` 认它，因为内核也是这么认的（`msm_fb_get_writeback_fb()` 在 `fbi_list` 里找 `panel.type == WRITEBACK_PANEL`） |
| 那探针怎么报？ | 先认板子，再爬阶梯：`tree-unscanned` / `wrong-board-tree` / `unknown-board` / `no-device-tree-node` / `no-panel-enabled` / `no-driver-for-enabled-panel` / `driver-not-registered` / `driver-not-bound` / `no-framebuffer` / `no-writeback-switch` / `no-writeback-fb` / `writeback-panel-registered` |
| 它写东西吗？ | **一个字节都不写、什么都不打开。**这一块的可写面是 framebuffer 自己的 mdss 属性（`blank`、`msm_fb_panel_status`、`trigger_reset`、`dsi_write`…）和一个**ioctl**；探针两样都不做，`/dev/graphics/fbN` 一次都不打开 |
| 离线验证？ | `scripts/host/zl1-wfd-probe-selftest.sh`，**185 项**：stub 目录**就是**设备，一级一个场景，**四条根路径**（`/proc/`、`/sys/`、`/dev/fb`、`/dev/graphics/`）的改写，设备树属性按**字节**写，一个"除了 `find(1)` 什么都有"的沙箱，**十二个变异**各让它红 |
| 动设备了吗？ | **没有。** |

---

## 2. 设备树里到底有什么（逐字节读出来的，不是猜的）

15 棵 LE_ZL1 树里，这三个节点**全部存在**，而且**形状完全相同**（同一个 `phandle 60`、同一个 `cell-index 1`）。
所以"树里有没有 WFD"这个问题**分不出两台手机**，只能靠 `model`：

```
/soc/qcom,mdss_wb_panel                 compatible = qcom,mdss_wb     status: 没有这个属性  ← 设备树读作"打开"
    qcom,mdss-fb-map   = <60>           → /soc/qcom,mdss_mdp@900000/qcom,mdss_fb_wfd
    qcom,mdss_pan_res  = <640 480>
    qcom,mdss_pan_bpp  = <24>

/soc/qcom,mdss_mdp@900000/qcom,mdss_fb_wfd
                                        compatible = qcom,mdss-fb
    cell-index = 1     phandle = 60     linux,phandle = 60   ← 同一个节点带两个名字

/soc/qcom/display-manager/qcom,wb-display@0
                                        compatible = qcom,wb-display
    cell-index = 2     label = wb_display                    ← 没有驱动，见 §4.2

/soc/qcom,mdss_rotator                  compatible = qcom,mdss_rotator
    qcom,mdss-wb-count = <2>            ← 数量在这里，不在 wb 节点上

/soc/qcom,mdss_mdp@900000               compatible = qcom,mdss_mdp
    qcom,mdss-wfd-mode      = "intf"    ← 字符串
    qcom,mdss-wb-off        = <413696 415744 417792>      ← 3 格
    qcom,mdss-mixer-wb-off  = <294912 299008>             ← 2 格
```

**面板自己没有 `status` 属性**——和 [`144`](144-the-tree-is-explicit-about-the-one-nothing-can-bind.md) 的 HDMI 发射器同一条读数：
设备树里"没有 `status`"就是**打开**。探针因此把 `absent` 放在**打开**那一支，
而这个判断**只有一处**（`EN=yes/no`），后面四个计数全读它——所以"读反一次"会让计数和结论**一起**动，
而不是数字说一套、结论说另一套。

---

## 3. 真正的问题：四个 count，三个地方，其中一个不是数字

```c
/* mdss_mdp.c -- mdss_mdp_parse_dt() */
wfd_data = of_get_property(pdev->dev.of_node, "qcom,mdss-wfd-mode", NULL);
if (wfd_data) { ... "intf" -> MDSS_MDP_WFD_INTERFACE; "shared" -> SHARED; "dedicated" -> DEDICATED;
                else -> pr_debug("wfd default mode: Shared") ... }

/* mdss_mdp.c -- mdss_mdp_parse_dt_wb() */
wfd_data = of_get_property(pdev->dev.of_node, "qcom,mdss-wfd-mode", NULL);
if (wfd_data && strcmp(wfd_data, "shared") != 0)
        num_intf_wb = 1;
nwb_offsets = mdss_mdp_parse_dt_prop_len(pdev, "qcom,mdss-wb-off");
...
mdss_mdp_wb_addr_setup(mdata, num_wb_mixer, num_intf_wb);

/* mdss_mdp_ctl.c -- mdss_mdp_wb_addr_setup() */
total = num_block_wb + num_intf_wb;
mdata->nwb = total;
```

于是这一块有**四个数**，来自**三个节点**，而其中一个是**从字符串推出来的**：

| 数 | 来自 | 值（本板） | 谁读它 |
|---|---|---|---|
| 旋转器的回写块数 | `qcom,mdss-wb-count`，在 **rotator** 节点 | **2** | `mdss_rotator.c`：缺了就 `pr_err("Error in device tree")` 并**拒绝 probe** |
| `num_block_wb` | `qcom,mdss-mixer-wb-off` 的**格数**，在 mdp 节点 | **2** | `mdss_mdp_parse_dt_mixer()` |
| `mdata->nwb_offsets` | `qcom,mdss-wb-off` 的**格数**，在 mdp 节点 | **3** | `mdss_mdp_parse_dt_wb()` |
| `num_intf_wb` | **`qcom,mdss-wfd-mode` 这个字符串** | **1** | 同一个函数，第二次读同一个属性 |

`mdss_mdp_wb_addr_setup()` 分配 `mdata->nwb = 2 + 1 = 3` 个块，而树里正好写了 **3 个** offset。
**两者一致——而且只因为那个字符串是 `intf`。**把它翻成 `"shared"`：`mdata->nwb` 变成 2，
树里还是 3 个 offset，**驱动里没有任何一处把这两个数放在一起比**，所以那个不一致是**静默的**。

探针把这一整段印出来（三行 count、一行推出来的数、一行算术、以及"一致/不一致"的结论），
harness 用四个场景把它变成可检查的：`mode-shared`（字符串一改，分配 2 个而树里 3 个 offset → 不一致）、
`mode-absent`（属性缺席 → `num_intf_wb = 0`）、`mode-bogus`（值不是三个之一 → 驱动取默认 `shared`）、
以及 `wb-off-two` / `wb-off-absent`（树自己写少了 offset → 不一致），
再加一个变异（把 `num_intf_wb` 当成永远是 1）——那个变异会让探针在**不一致的树上宣称一致**。

### 3.1 没有 `CONFIG_MSM_ROTATOR` 这个选项

`drivers/video/msm/mdss/Makefile` 里 `mdss_rotator.o` 属于 `mdss-mdp-objs`，也就是**由 `CONFIG_FB_MSM_MDSS` 编译**：
这颗内核**没有**"旋转器的选项"这种东西（flashed config 里唯一带 ROTATOR 的名字是无关的 `CONFIG_MSM_SDE_ROTATOR`）。
一个按名字去找该选项的读者会看到"没设置"，从而在**一颗把它编进去了的内核**上得出"旋转器不在"。

同一类名字分歧还有两处，都在这一块里：

| 名字 | 它是什么 | 它**不是**什么 |
|---|---|---|
| `mdp` | mdss_mdp 的 platform driver `.name`（源码注释：*"Driver name must match the device name added in platform.c"*） | 不是 `mdss_mdp`——`mdss_mdp` 这个名字在设备树里、在源文件名里，**在 sysfs 里不存在** |
| `mdss_wb` | 写回面板的 driver `.name`（`of_match = qcom,mdss_wb`） | 不是 `qcom,mdss_wb`——sysfs 的目录是 `mdss_wb` |

探针把这两个目录都印出来，并**当场写出**这个分歧；harness 的第九个变异就是把 `mdp` 换成 `mdss_mdp`，
于是"驱动行"说 `mdss_mdp` 而"目录列"说 `mdp`——**两列互相矛盾**，正是这个缺陷的形状。

---

## 4. 为什么 `/sys/class/switch/wfd` 是一条端到端读数

### 4.1 链条

```
qcom,mdss_wb_panel  (platform device)
   └─ mdss_wb_probe()
        ├─ mdss_wb_parse_dt()            只读 qcom,mdss_pan_res / qcom,mdss_pan_bpp
        ├─ mdss_wb_dev_init()            switch_dev_register()  ← 注册 /sys/class/switch/wfd
        ├─ mdss_register_panel(pdev, pdata)
        │     └─ of_parse_phandle(pdev->dev.of_node, "qcom,mdss-fb-map", 0)
        │           ├─ 没有 → pr_err("Unable to find fb node for device: %s") → -ENODEV
        │           └─ 有   → of_platform_device_create(qcom,mdss_fb_wfd) → mdss_fb 的 probe
        └─ 出错路径 error_init: → mdss_wb_dev_uninit()  ← 把刚注册的 switch 注销
```

**注册在"找 framebuffer"之前，注销在失败路径上**——所以那个属性文件存在，就意味着这四步都过了。
探针的 `no-switch` 场景正是"驱动绑上了、链条还是断的"，而第十二个变异（不再要求 switch 存在）
会让这样一台设备报出**最高一级**。

### 4.2 那个没有任何驱动的节点

`qcom,wb-display` 在本项目的参考树里出现在**八份设备树文件**里，而在**任何 `.c` / `.h` 文件里一次都没有**。
它和 `qcom,hdmi-display` 是同一代（display-manager 那一代）的描述。它在报告里被**点名**，
因为它属于这一块的**节点计数**——一个只按 `wb` 找 compatible 的探针会漏掉它，
而"漏掉"和"不存在"在一份报告里长得一样。

---

## 5. 写级别的那一步是一个 ioctl

| 面 | 为什么它是写级别的 |
|---|---|
| `/dev/graphics/fbN` | 镜像提示（`MDP_WRITEBACK_MIRROR_ON` / `_PAUSE` / `_RESUME` / `_OFF`）是**这个设备上的 ioctl**；本探针读的那个 switch，值就是被这条路径写的 |
| `/sys/class/switch/wfd/state` | `DEVICE_ATTR(state, S_IRUGO, state_show, NULL)`——**没有 store**，shell 写会被内核拒绝（所以它不是"别写"的问题，而是**写不进去**） |
| `/sys/class/graphics/fbN/{blank,dsi_write,trigger_reset}` | 让屏幕黑掉/亮起来、往面板发命令、触发复位——在合成器正在扫描的 fb 上这是**可见的**动作 |
| `qcom,mdss-wb-count`、`qcom,mdss-wb-off`、`qcom,mdss-mixer-wb-off` | 设备树属性：它们是**boot image 的决定**，不是运行时旋钮，探针按属性读它们 |

探针**一个都不写、一个都不打开**；harness 的静态写守卫有四个"牙齿"夹具，
第三个（`dd of=/dev/graphics/fbN`）就是这一块的真实诱惑——**shell 里最接近那个 ioctl 的东西**。

---

## 6. 设备状态与复现

整轮没有动设备：没有写任何分区或 boot，没有跑 QDL/QFIL，没有重启。设备仍在 **Qualcomm EDL**（`05c6:9008`）。
识别目标一律按序列号 **`33e80afe`**；总线上另一台小米 **`4a2fe00b`** 必须忽略。恢复仍然只能靠**物理长按电源 10–20 秒**。

```sh
# 全部在宿主机上，不碰设备。
bash scripts/host/zl1-hardware-inventory.sh --block wfd    # 3 个节点，现在有仪器了
bash scripts/host/zl1-hardware-inventory.sh --gaps         # 现在只剩 3 个缺口
bash scripts/host/zl1-wfd-probe-selftest.sh                # 185 项

# 本块最核心的那个变异（把"从字符串推出来的数"当成永远是 1，必须红）：
P=scripts/device/zl1-wfd-probe.sh
sed 's#^  case "\$WFD_MODE" in absent | EMPTY | shared) N_INTF=0 ;; esac#  :#' "$P" > /tmp/mut-intf.sh
ZL1_WFD_PROBE_SRC=/tmp/mut-intf.sh bash scripts/host/zl1-wfd-probe-selftest.sh

# 设备回来之后（只读、不写任何东西、不打开任何设备；或直接跑 capture，它已经把 04k 放进默认集）：
scp scripts/device/zl1-wfd-probe.sh root@10.15.19.82:/tmp/ && ssh root@10.15.19.82 'sh /tmp/zl1-wfd-probe.sh'
# 它会先回答"这棵树是不是这块板"，再回答面板绑没绑上、它的 framebuffer 是哪个、
# 那一块 switch 在不在，以及这一块的四个 count 是不是同一个数。
```

---

## 7. 这一轮**不**证明什么

* **不证明屏幕镜像能用，也不证明不能用。**恰恰相反：它证明的是这一块的**软件路径**到了哪一步——
  面板驱动绑上、switch 注册、`writeback panel` 类型的 framebuffer 在，**没有一个是屏幕上的画**。
* **不证明 `state: 0` 是故障。**它是"没人请求过镜像"；请求是一次 ioctl，而这个探针**不发**。
* **不证明那四个 count 在设备上真的互相一致。**这一轮读的是**参考树**：设备上真实读到的那棵树
  （以及它到底是不是这块板的那棵）只有设备回来才知道。
* **不证明"三处名字分歧"有任何后果。**`mdp` / `mdss_mdp`、没有 rotator 选项、`mdss_wb` / `qcom,mdss_wb`
  都是**关于名字的事实**；它们会不会让谁读错，是**读的人**的问题，而探针的作用是让人不必猜。
* **不证明 `qcom,wb-display` 那一代"坏了"。**它是**下一代内核的描述**：这颗 3.18 内核里连那份代码都没有。
* **不证明设备上落在哪一级。**这一轮**一次 ssh 都没有**：185 项全部挡在 stub 目录后面，场景是我造的。
* **不证明剩下 3 个缺口里没有更重要的。**只是这一块的问题最容易被"一个数"答错，而"答错"是可以量的。

---

## 8. 文件与改动

| 文件 | 作用 |
|---|---|
| `scripts/device/zl1-wfd-probe.sh` | 新：WFD / 回写探针（三个节点、phandle 从面板自己的节点读、`qcom,mdss-wfd-mode` 读两次、**四个 count 三个地方**、switch 是端到端读数、ioctl 才是写级别的那一步、fb 按 type 不按编号/名字），**board-first**，十二级阶梯，只读**且不写任何东西、不打开任何设备** |
| `scripts/host/zl1-wfd-probe-selftest.sh` | 新：**185 项**，stub 目录就是设备，**四条根路径**改写（含 `/dev/fb` 与 `/dev/graphics/`），设备树属性按字节写，一个"除了 `find(1)` 什么都有"的沙箱，**十二个变异**；写夹具时按真字节读出 `qcom,mdss-wb-off` 是 **3 格**、`qcom,mdss-mixer-wb-off` 是 **2 格**、`qcom,mdss-wb-count` 是 **2**，于是"2 + 1 = 3 = 树里的 offset 数"这条读数才有夹具可对 |
| `scripts/host/zl1-hardware-inventory.sh` | 改：`wfd` 行点名仪器，并补上 `qcom,wb-display`（display-manager 那一代的子节点，原来的 pattern **漏了它**，所以计数从 2 变成 **3**）；汇总 25/4 → **26/3** |
| `scripts/host/zl1-hardware-inventory-selftest.sh` | 改：汇总数字改成 26/3；`wfd` 从缺口循环移到"已覆盖、按名字与节点数断言"那一组 |
| `scripts/host/zl1-post-recovery-capture.sh` | 改：默认集新增 **04k-wfd**（只读、不写、不需要人在场、不打开设备、不发 ioctl） |
| `scripts/host/zl1-post-recovery-capture-selftest.sh` | 改：164 → **167** 项（加一步要按名字/顺序/scp 路径/归档文件/步骤数与 push 数全部改一遍：14 步/12 push/15 归档 → **15 步/13 push/16 归档**） |
| `scripts/host/zl1-health-check.sh` | 改：新增 **5f. WFD / writeback**（`qcom,mdss-wfd-mode` 读两次、四个 count、switch 是端到端读数、写级别的那一步是 ioctl、fb 按 type 认）；0g 改写为 **3 of 29**；capture harness 引用 164 → **167**；cli-usage 引用 168 → **172**（它扫的脚本 61 → 63）；新增 wfd harness 引用 **185** |
| `scripts/README.md` | 改：两个新脚本各一行；cli-usage 引用 168 → **172**、覆盖集 74 脚本 → **78**、括号里两个数改成 63 + 15；capture 两行 164 → **168**、步骤 14/12/15 → 15/13/16；capture 那一行补上 04k |
| `docs/ubuntu-touch/137-*.md` | 改：后续注记 4 → **3 个缺口**，汇总 25/4 → **26/3** |
| `docs/ubuntu-touch/139-*.md` | 改：后续注记 4 → **3 个缺口**，缺口表补上这一轮的收口 |
| `docs/ubuntu-touch/124-*.md` | 改：家族总数那一行续上本轮 |
| `README.md` | 改：本页的索引行 |
| `docs/ubuntu-touch/145-*.md` | 本篇 |
