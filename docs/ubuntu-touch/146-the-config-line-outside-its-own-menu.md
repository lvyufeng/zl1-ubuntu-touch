# 146 — 决定这一块的配置项，在它自己那个菜单之外

**日期**: 2026-09-24
**状态**: 本轮**没有碰设备**（设备仍在 Qualcomm EDL，见 §7）。这是 [`137`](137-a-boot-should-answer-the-question-nobody-asked.md)
那份"没有探针"清单的第十次收口，收的是 `nfc`。它是一个**节点**：一条 i2c 总线上的一个芯片，而它同时带着
**两代属性命名**——驱动读的那五个，和**这颗内核里没有任何 .c / .h / Kconfig 会读**的两个——而且两代
**对引脚的说法都不一致**。真正决定这一块在不在的，是**一行配置**：`CONFIG_NFC_NQ`，它写在它看起来应该
受其管辖的那个菜单**之外**。
新工具 `scripts/device/zl1-nfc-probe.sh`（只读、**一个字节都不写**、**不开任何设备节点**）与它的 harness **238 项**；
它接进了"一次启动"的默认集（新步骤 **04l**）。清单从 **3 个缺口**变成 **2 个**。

**接续**: [`137`](137-a-boot-should-answer-the-question-nobody-asked.md)（缺口的来源）、
[`143`](143-the-tree-enables-two-and-the-kernel-builds-neither.md) / [`144`](144-the-tree-is-explicit-about-the-one-nothing-can-bind.md) /
[`145`](145-the-count-that-is-a-string.md)（前三次收口）、
[`124`](124-the-boot-a-finger-bought-is-one-command.md)（一次启动是一个命令）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 为什么收这个？ | 它是剩下缺口里**唯一一个"决定它的东西不是设备树、不是源码，而是一行内核配置"**的块，而且那一行**不在它看起来应该属于的菜单里** |
| 这一块由谁描述？ | **一个节点**：`/soc/i2c@75b6000/nq@28`（`qcom,nq-nci`），在 F R S 三个集合里都在，15 棵 LE_ZL1 树里形状完全相同 |
| 第一件要紧的事？ | **这个节点带着两代属性命名，而只有一代被读。**驱动读 `qcom,nq-ven`、`qcom,nq-irq`、`qcom,nq-firm`、`qcom,nq-clkreq`、`qcom,clk-src`；节点上还有 `nxp,p61-pwr` 与 `nxp,p61-rst`——**这颗内核的任何一个 .c、.h、Kconfig 都不读它们** |
| 为什么这要紧？ | 因为**两代对引脚的说法不一致**。驱动认的电源使能是 `qcom,nq-ven` = `<28 12 0>`，**TLMM**（phandle 28，`pinctrl@01010000`）上的 12 号脚；没人读的那个 `nxp,p61-pwr` = `<29 7 0>`，是 **PMIC**（phandle 29，`label pm8994-gpio`）上的 7 号脚。一个"这个节点有一个电源使能"的读数，如果不说是**哪一代命名**，就是在把一行没有驱动会问的线，当成真实接线印出来 |
| 那这一块到底跨几个控制器？ | **两个**：`qcom,nq-ven` / `nq-irq` / `nq-firm` 和 `nxp,p61-rst` 在 TLMM（28），`qcom,nq-clkreq` 和 `nxp,p61-pwr` 在 PMIC gpio（29），而 `clocks` 指向的是第三个 phandle（74，`qcom,gcc@300000`，**不是 gpio 控制器、没有 `#gpio-cells`**） |
| 第二件要紧的事？ | **五个被读的属性里，三个是致命的，两个不是。**`qcom,nq-ven` 或 `qcom,nq-irq` 无效、或者 `qcom,clk-src` 缺席，`nfc_parse_dt()` 就返回 `-EINVAL`（probe 根本不会跑）；而 `qcom,nq-firm` 缺席只是一个 `dev_warn`，`qcom,nq-clkreq` 缺失在 probe 里只是一个 `dev_err` |
| 所以"节点完整"和"驱动能绑"是同一个问题吗？ | **不是**，探针分开回答：`firm-absent` / `clkreq-absent` 两个场景里**驱动照常绑上**，结论必须还在最高一级；而 `ven-absent` / `ven-short` 里树自己就让驱动绑不上 |
| 第三件要紧的事？ | **一个字符串是开关。**`if (!strcmp(platform_data->clk_src_name, "BBCLK2"))`——别的值走 `goto err_free_dev`，也就是**probe 失败**。这块板写的正是 `BBCLK2`，而驱动只支持这一个名字 |
| 那"决定这一块的那个东西"是什么？ | **一行内核配置**：`CONFIG_NFC_NQ`。它在 `drivers/nfc/Kconfig` 里写在 `menu "Near Field Communication (NFC) devices"`（那个 `depends on NFC` 的菜单）的 **`endmenu` 之后**，所以它的**唯一依赖是 I2C**，`CONFIG_NFC` 管不到它 |
| 为什么这要紧？ | 因为项目手上这两颗内核**各证明了一半**：**stock** boot image 的 3.18.120 内核里写着 `# CONFIG_NFC is not set` **和** `CONFIG_NFC_NQ=y`——菜单关着而驱动**被编进去了**；而这块板正在跑的 **v63 Halium 3.18.140** 内核里两行都是关的。**`CONFIG_NFC` 这一行在两者里完全一样**，所以去读那一行的人，从一颗有驱动的内核和一颗没有驱动的内核会得到同一个答案 |
| 第二件"定义了却哪儿都没有"的东西？ | **两个 `#ifdef`**：`CONFIG_NFC_HW_CHECK` 与 `NFC_KERNEL_BU` 在 `nq-nci.c` 里**只以 `#ifdef` 出现**——整棵树里既没有 Kconfig 符号也没有 `-D`。于是 probe **既不检查硬件在场，也不上电**：VEN 保持低、参考时钟保持关，芯片只能由用户空间通过 misc 设备上的 `NFC_SET_PWR` ioctl（1 = 开，2 = 下载模式，0 = 关）上电 |
| 那"有输出"要怎么读？ | 探针把这一条印在最高一级的旁边：**三个证据是软件路径就位，不是"这块芯片在工作"**——它此刻是**关着**的 |
| 那三层证据是什么？ | **嵌套的三层**：i2c **客户端**（`/sys/bus/i2c/devices/8-0028`）只由设备树就生成，**一颗 NFC 驱动都没编进去时它也在**；**绑定**（驱动目录下的一个符号链接）需要驱动被编、被注册、probe 过了那三个致命读和那个字符串；**misc 设备**（`/sys/class/misc/pn544`）需要 probe **一路跑到最后**——`misc_register()` 在时钟和四个 gpio **之后**，而它之后每一条失败路径都会 `misc_deregister()` |
| 所以读哪一层最容易读错？ | 第一层。**"客户端在"是最弱的证据**，而它恰好是"这块硬件在不在"这个问题最容易问成的样子——在这块板正在跑的那颗内核上它会回答"在"，而那颗内核的配置里驱动是关的 |
| 一个块有几个名字？ | **四个**，其中三个是坑：`qcom,nq-nci` 是 compatible，`nq-nci` 是驱动目录（**唯一一个是 sysfs 路径的**），`nqx-i2c` 是它的 `i2c_device_id`（不按设备树匹配时会用这个名字，而它**不是**路径），`pn544` 是它注册的 **misc 设备**——而 `pn544` **同时是这棵树里另一个驱动**（`drivers/nfc/pn544`，`nxp,pn544-i2c`，另一代芯片）。**按 `/dev` 里能看见的名字去 grep，会找到错的驱动** |
| 那探针怎么报？ | 先认板子，再爬阶梯：`tree-unscanned` / `wrong-board-tree` / `unknown-board` / `no-device-tree-node` / `no-driver-for-node` / `no-node-enabled` / `no-client` / `driver-not-built` / `driver-not-registered` / `driver-not-bound` / `no-misc-device` / `nfc-ready` |
| 为什么 `no-client` 排在 `driver-not-*` **前面**？ | 因为客户端是 i2c 核心按设备树生成的：**客户端根本不存在时，任何一行配置都修不了它**，下一步是那个 i2c 控制器（或者它的 alias），不是 NFC 驱动 |
| 这一块"写级别"的动作是什么？ | **设备节点上的一个 ioctl，加上节点自己的读/写**：`read()` 会等 IRQ 然后 `i2c_master_recv`（**从芯片读**），`write()` 是 `i2c_master_send`（**对芯片说 NCI**），`ioctl(NFC_SET_PWR, 0\|1\|2)` 直接驱动 VEN、固件下载脚和参考时钟。探针**什么设备节点都不打开**，`/dev/pn544` 一次都不碰 |
| 有 sysfs 可写面吗？ | **没有**。`nq-nci.c` 不建任何 attribute、任何 class、任何 module parameter——所以 misc 目录是这个块**唯一**的文件面，而它是个普通文件（读 `dev` 只是读 `major:minor`） |
| 离线验证？ | `scripts/host/zl1-nfc-probe-selftest.sh`，**238 项**：stub 目录**就是**设备，一级一个场景，**三条根路径**（`/proc/`、`/sys/`、**`/dev/pn544`**）的改写，设备树属性按**字节**写（29 个 cell，含四个 pinctrl 组），一个"除了 `find(1)` 什么都有"的沙箱，**十二个变异**各让它红 |
| 动设备了吗？ | **没有。** |

---

## 2. 设备树里到底有什么（逐字节读出来的）

15 棵 LE_ZL1 树里这个节点**形状完全相同**，所以"树里有没有 NFC"分不出两台手机，只能靠 `model`：

```
/soc/i2c@75b6000/nq@28              compatible = qcom,nq-nci      status: 没有这个属性  ← 设备树读作"打开"
    reg             = <0x28>              ← i2c 从机地址；sysfs 里的名字是 "8-0028"
    qcom,nq-ven     = <28 12 0>           TLMM(28)   gpio 12     ← 驱动读：电源使能（致命）
    qcom,nq-irq     = <28 95 0>           TLMM(28)   gpio 95     ← 驱动读：中断（致命）
    qcom,nq-firm    = <28 49 0>           TLMM(28)   gpio 49     ← 驱动读：固件脚（不致命，dev_warn）
    qcom,nq-clkreq  = <29 10 0>           PMIC(29)   gpio 10     ← 驱动读：时钟请求（不致命，dev_err）
    qcom,clk-src    = "BBCLK2"                                 ← 驱动读：**是开关**（致命）
    nxp,p61-pwr     = <29 7 0>            PMIC(29)   gpio 7      ← **没有任何东西读**
    nxp,p61-rst     = <28 130 0>          TLMM(28)   gpio 130    ← **没有任何东西读**
    interrupt-parent = <28>   interrupts = <95>   interrupt-names = "nfc_irq"
    clocks = <74 1233729765>  clock-names = "ref_clk"          ← 74 = /soc/qcom,gcc@300000（时钟控制器）
    pinctrl-0 = <263 264>     pinctrl-1 = <265 266>
    pinctrl-names = "nfc_active" "nfc_suspend"

/aliases/i2c8 = /soc/i2c@75b6000       ← 总线号来自这里，而客户端名字由它 + reg 组成
```

两个 gpio 控制器：

| phandle | 节点 | label | 这一块用到它的哪里 |
|---|---|---|---|
| **28** | `/soc/pinctrl@01010000`（`qcom,msm8996-pinctrl`） | 没有 label | `qcom,nq-ven` 12、`qcom,nq-irq` 95、`qcom,nq-firm` 49、`nxp,p61-rst` 130 |
| **29** | `.../pm8994@0/gpios`（`qcom,qpnp-pin`） | **`pm8994-gpio`** | `qcom,nq-clkreq` 10、`nxp,p61-pwr` 7 |
| 61 | `.../pm8994@0/mpps` | `pm8994-mpp` | 这一块**不用**（节点上指向它的 phandle 一个都没有） |
| 74 | `/soc/qcom,gcc@300000`（`qcom,gcc-8996-v3`） | — | `clocks` 的时钟控制器（**不是** gpio 控制器） |

而四个 pinmux 组的名字本身就是读数：`pinctrl-0`（ACTIVE）解析成
`/soc/pinctrl@01010000/pmx_rd_nfc_int/active` 和 `/soc/pinctrl@01010000/pmx_nfc_reset/active`——
**`pmx_rd_nfc_int` 和 `pmx_nfc_reset` 就是驱动读的那两个脚**，所以探针把这两行印出来，而不是只印 `pinctrl-names`。

**节点自己没有 `status` 属性**——和 [`144`](144-the-tree-is-explicit-about-the-one-nothing-can-bind.md) 的 HDMI 发射器、
[`145`](145-the-count-that-is-a-string.md) 的写回面板同一条读数：设备树里"没有 `status`"就是**打开**。
探针因此只有一个 `EN=yes/no` 判断，结论和计数一起读它；harness 里第七个变异就是把 `absent` 翻到"关"那一支。

---

## 3. 三条致命、两条不致命，以及一个"是开关"的字符串

```c
/* drivers/nfc/nq-nci.c -- nfc_parse_dt() */
r = of_get_named_gpio(node, "qcom,nq-ven", 0);   if (r < 0) { ...; return -EINVAL; }   /* 致命 */
r = of_get_named_gpio(node, "qcom,nq-irq", 0);   if (r < 0) { ...; return -EINVAL; }   /* 致命 */
r = of_get_named_gpio(node, "qcom,nq-firm", 0);  if (r < 0) dev_warn(...);             /* 不致命 */
r = of_get_named_gpio(node, "qcom,nq-clkreq", 0); if (r < 0) dev_err(...);             /* 不致命 */
r = of_property_read_string(node, "qcom,clk-src", &clk_src_name);
                                                 if (r) { ...; return -EINVAL; }      /* 缺席 → 致命 */

/* drivers/nfc/nq-nci.c -- nqx_probe() */
if (!strcmp(platform_data->clk_src_name, "BBCLK2")) { ... }
else { dev_err(...); goto err_free_dev; }        /* **值不对 → probe 失败** */
...
misc_register(&nqx_dev->misc);                   /* ← 在这一步之后任何失败都会 deregister */
request_irq(client->irq, ...);                   /* ← client->irq 已被 gpio_to_irq() 覆盖 */
```

注意最后一行：**驱动请求的那个 IRQ 不是设备树 `interrupts` 里那个**——`client->irq` 会被
`gpio_to_irq(qcom,nq-irq)` 覆盖。这块板上两者指向同一个控制器、同一个线号（TLMM 95），所以覆盖是**看不见的**；
探针把这一点印出来，因为它不是普遍成立的。

这一段的四个分支，harness 是一条一条量过的：

| 场景 | 树 | 驱动能绑吗 | 结论必须是 |
|---|---|---|---|
| `ven-absent` / `irq-absent` / `ven-short` | 致命读缺失或不是整格 | 不能（`-EINVAL`） | `driver-not-bound`，而且结论里**点名**缺的是哪一个 |
| `clk-src-absent` | 字符串缺席 | 不能（`-EINVAL`） | 同上 |
| `clk-src-wrong` | 字符串 = `BBCLK1` | 不能（走 `err_free_dev`） | 同上，且印出"这就是失败的那一种值" |
| `firm-absent` / `clkreq-absent` | 不致命的那两个缺 | **能** | `nfc-ready`（最高一级） |
| `ven-odd` | gpio 只有两格（没有 flag 格） | **能**（`of_get_named_gpio` 接受） | `nfc-ready` |

后两行是这一节的要害：**把它们当致命，就会在一块正常工作的板上报出"这块是死的"**。

---

## 4. 决定这一块的那一行配置，在它自己那个菜单之外

```kconfig
# drivers/nfc/Kconfig
menu "Near Field Communication (NFC) devices"
        depends on NFC
config NFC_PN544
        tristate "PN544 NFC driver"
        depends on I2C && NFC
...
endmenu                                   # ← 菜单在这里结束

config NFC_NQ                             # ← 它在 endmenu **之后**
        tristate "NXP NQ NFC driver"
        depends on I2C                    # ← 唯一的依赖是 I2C，**没有 NFC**
```

`drivers/nfc/Makefile` 也一致：`obj-$(CONFIG_NFC) += ...` 在菜单内那一堆，而 `obj-$(CONFIG_NFC_NQ) += nq-nci.o`
单独一行。**于是 `CONFIG_NFC` 不是 `CONFIG_NFC_NQ` 的前置条件**，而项目手上的两颗内核把这件事正反各证明了一半：

| 内核 | `CONFIG_NFC` | `CONFIG_NFC_NQ` | 结论 |
|---|---|---|---|
| **stock** boot image（3.18.120） | `# ... is not set` | **`=y`** | 菜单关着，驱动**被编进去了** |
| **v63 Halium**（3.18.140，这块板正在跑） | `# ... is not set` | `# ... is not set` | 两行都关 |

**`CONFIG_NFC` 这一行在两者里一模一样。**所以"这块有没有 NFC 驱动"这个问题，
**读那一行是答不出来的**——而它旁边那一行（`CONFIG_NFC_NQ`）才是答案。
探针把两行都印出来、说明为什么必须一起读，并且**只用第二行做结论**；harness 的第一个变异就是把探针改成读
`CONFIG_NFC`——在 stock 形状的配置上它会报"没编"，而那颗内核**有**这个驱动。

还有一个第三状态：**配置读不到**（文件不在、或者文件在但没有 zcat/gunzip 能展开它）。
探针把 `/proc/config.gz` 的三件事分开印（**在不在 / 权限可读 / 是否展开了**），配置两列这时印 `NOT READ`，
而结论**不会**说"这颗内核没编这个驱动"——那是第四种状态，也是唯一一种能怪配置行的状态。

---

## 5. 三层嵌套证据，四个名字

```
设备树 ──► i2c 客户端  /sys/bus/i2c/devices/8-0028        ← 只要总线驱动在，它就在；**驱动编没编都无关**
                 │
                 └─► 绑定    /sys/bus/i2c/drivers/nq-nci/8-0028  ← 需要：驱动被编 + 被注册 + probe 过了那三读与那个字符串
                              │
                              └─► misc   /sys/class/misc/pn544   ← 需要 probe **跑到最后**
```

`misc_register()` 在 `clk_get()`/`clk_prepare_enable()`、四个 gpio 请求和 `dma_pool` 分配**之后**，
而它之后的每一条失败路径（例如 `request_irq` 失败）都会 `misc_deregister()`。所以：

* misc 设备在 ⇒ probe 一路跑完（**最强**）；
* 绑定在而 misc 不在 ⇒ probe 在 `misc_register` 附近或之后失败了（`no-misc-device`）；
* 客户端在而没有任何绑定 ⇒ 驱动没注册、或者 probe 在 fatal 读/时钟那一步就被拒了；
* 客户端不在 ⇒ 核心压根没建这个客户端，**任何配置行都修不了**。

客户端名字是**推出来的**：`%d-%04x`，总线号来自 `aliases/i2c8`，地址来自 `reg = 0x28` → `8-0028`。
探针把推导过程印出来，并且**不把推导当事实**：名字不在时它会**按地址再找一遍**（`*-0028`），
找到了就说"客户端在，错的是 alias"（`client-other-bus`），找不到才说"真的没有客户端"。
没有 alias 时它连名字都不推，直接按地址找（`no-alias`）——这两种状态下一步动作完全不同，不能长一个样。

四个名字里唯一是 sysfs 路径的是 `nq-nci`；harness 的第十个变异就是把驱动按 `nqx-i2c` 去查，
于是**驱动目录读成"没注册"**，而同一份报告里客户端还在——两列自相矛盾，正是这个缺陷的形状。

---

## 6. 写级别的那一步是一个 ioctl（而 sysfs 上没有可写面）

| 面 | 为什么它是写级别的 |
|---|---|
| `/dev/pn544` 的 `read()` | 等 IRQ，然后 `i2c_master_recv`——**从芯片读**，会真的动 i2c 总线 |
| `/dev/pn544` 的 `write()` | `i2c_master_send`——**对芯片说 NCI**，会改控制器状态 |
| `ioctl(NFC_SET_PWR, 0\|1\|2)` | 驱动 VEN、固件下载脚与参考时钟：关、开、或进下载模式（**真实引脚**） |
| `misc_register` 出来的 sysfs 面 | **没有**：`nq-nci.c` 不建 attribute、不建 class、不建 module parameter |
| `qcom,nq-*` / `qcom,clk-src` / 两个 `nxp,p61-*` | 设备树属性：**boot image 的决定**，不是运行时旋钮，探针按属性读它们 |

探针**一个都不做**：它读的是 `/sys/class/misc/pn544` 这个**普通文件**（`dev` 属性只是 `major:minor` 文本），
`/dev/pn544` 一次都不打开、也不 stat 成设备。harness 的静态写守卫有四个"牙齿"夹具，
第四个（`dd if=nci.bin of=/dev/pn544`）就是这一块的真实诱惑——**shell 里最接近那个 ioctl 的东西**。

---

## 7. 设备状态与复现

整轮没有动设备：没有写任何分区或 boot，没有跑 QDL/QFIL，没有重启。设备仍在 **Qualcomm EDL**（`05c6:9008`）。
识别目标一律按序列号 **`33e80afe`**；总线上另一台小米 **`4a2fe00b`** 必须忽略。恢复仍然只能靠**物理长按电源 10–20 秒**。

```sh
# 全部在宿主机上，不碰设备。
bash scripts/host/zl1-hardware-inventory.sh --block nfc    # 1 个节点，现在有仪器了
bash scripts/host/zl1-hardware-inventory.sh --gaps         # 现在只剩 2 个缺口
bash scripts/host/zl1-nfc-probe-selftest.sh                # 234 项

# 本块最核心的那个变异（去读"旁边那一行"，必须红）：
P=scripts/device/zl1-nfc-probe.sh
sed 's#cfg_opt CONFIG_NFC_NQ#cfg_opt CONFIG_NFC#g' "$P" > /tmp/mut-config.sh
ZL1_NFC_PROBE_SRC=/tmp/mut-config.sh bash scripts/host/zl1-nfc-probe-selftest.sh

# 设备回来之后（只读、不写任何东西、不打开任何设备；或直接跑 capture，它已经把 04l 放进默认集）：
scp scripts/device/zl1-nfc-probe.sh root@10.15.19.82:/tmp/ && ssh root@10.15.19.82 'sh /tmp/zl1-nfc-probe.sh'
# 它会先回答"这棵树是不是这块板"，再回答节点在不在、两代命名各说的是哪个控制器、
# 客户端/绑定/misc 三层证据到了哪一层，以及这一块在这颗内核里到底有没有被编进去。
```

---

## 8. 这一轮**不**证明什么

* **不证明 NFC 能用，也不证明不能用。**恰恰相反：它证明的是**软件路径**到了哪一层——
  客户端、绑定、misc 设备，**没有一个是读卡**，而且芯片此刻是**关着**的（那两个 `#ifdef` 都不成立）。
* **不证明 `CONFIG_NFC_NQ=y` 就够。**它只说明 stock 内核把它编进去了；这块板跑的是 Halium 内核，
  而**改一行 defconfig 要重新编一个 boot image**——那是一件需要单独审查的动作（并且与本项目"先备份、再校验"的规矩一起看）。
  这一轮**没有**做，也没打算在这一轮做。
* **不证明 `nxp,p61-*` 是"坏的"或"多余的"。**它们是**下一代命名的描述**，而这一块两代都在树上；
  探针的作用是让人**不必猜哪一代是驱动用的**。
* **不证明那个 i2c 客户端一定叫 `8-0028`。**名字是从 alias 推的，所以探针在名字不在时**按地址再找一遍**，
  两种结果分开印——设备上到底落在哪一种，只有设备回来才知道。
* **不证明设备上落在哪一级。**这一轮**一次 ssh 都没有**：234 项全部挡在 stub 目录后面，场景是我造的。
* **不证明剩下 2 个缺口里没有更重要的。**只是这一块的问题**最容易被"读错了配置行"一次答错**，而"答错"是可以量的。

---

## 9. 文件与改动

| 文件 | 作用 |
|---|---|
| `scripts/device/zl1-nfc-probe.sh` | 新：NFC 探针（一个节点、两代属性命名、三个致命读对两个不致命、一个"是开关"的字符串、配置行在菜单之外、两个空 `#ifdef`、三层嵌套证据、四个名字），**board-first**，十二级阶梯，只读**且不写任何东西、不打开任何设备节点** |
| `scripts/host/zl1-nfc-probe-selftest.sh` | 新：**234 项**，stub 目录就是设备，**三条根路径**改写（含 `/dev/pn544`），设备树属性按字节写（29 个 cell，含 263/264/265/266 四个 pinmux 组与每个控制器的 `phandle` + `linux,phandle`），一个"除了 `find(1)` 什么都有"的沙箱，**十二个变异** |
| `scripts/host/zl1-hardware-inventory.sh` | 改：`nfc` 行点名仪器；汇总 26/3 → **27/2** |
| `scripts/host/zl1-hardware-inventory-selftest.sh` | 改：汇总数字改成 27/2；`nfc` 从缺口循环移到"已覆盖、按名字与节点数断言"那一组 |
| `scripts/host/zl1-post-recovery-capture.sh` | 改：默认集新增 **04l-nfc**（只读、不写、不需要人在场、不打开设备） |
| `scripts/host/zl1-post-recovery-capture-selftest.sh` | 改：167 → **170** 项（加一步要按名字/顺序/scp 路径/归档文件/步骤数与 push 数全部改一遍：15 步/13 push/16 归档 → **16 步/14 push/17 归档**） |
| `scripts/host/zl1-health-check.sh` | 改：新增 **5g. NFC**（两代命名、三条致命对两条不致命、`BBCLK2` 是开关、`CONFIG_NFC_NQ` 在菜单之外、两个空 `#ifdef`、三层证据、四个名字）；0g 改写为 **2 of 29**；capture harness 引用 167 → **170**；cli-usage 引用 172 → **176**（它扫的脚本 63 → 65）；新增 nfc harness 引用 **234** |
| `scripts/README.md` | 改：两个新脚本各一行；cli-usage 172 → **176**、覆盖集 78 脚本 → **80**、括号里两个数改成 60 + 5；capture 167 → **170**、步骤 15/13/16 → 16/14/17，并补上 04l |
| `docs/ubuntu-touch/137-*.md` | 改：后续注记 3 → **2 个缺口**，汇总 26/3 → **27/2** |
| `docs/ubuntu-touch/139-*.md` | 改：后续注记 3 → **2 个缺口**，缺口表补上这一轮的收口 |
| `docs/ubuntu-touch/124-*.md` | 改：家族总数那一行续上本轮 |
| `README.md` | 改：本页的索引行 |
| `docs/ubuntu-touch/146-*.md` | 本篇 |
