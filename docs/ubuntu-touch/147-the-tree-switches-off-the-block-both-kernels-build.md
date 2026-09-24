# 147 — 设备树自己把节点关掉，而两颗内核都把它的驱动编进去了

**日期**: 2026-09-24
**状态**: 本轮**没有碰设备**（设备仍在 Qualcomm EDL，见 §7）。这是
[`137`](137-a-boot-should-answer-the-question-nobody-asked.md) 那份"没有探针"清单的第十一次收口，收的是
`fm-radio`。它是一个**节点**：一条 i2c 总线上的一个调频接收芯片，而它带着**这个项目里唯一一个
`status = "disabled"`**——15 棵 LE_ZL1 树、三个集合里全部如此。**别的块都是"树里没有 status（=打开）、
内核里没编"，这一块是反过来的：树把节点关掉了，而项目手上两颗内核都把这个驱动编进去了。**
新工具 `scripts/device/zl1-fm-radio-probe.sh`（只读、**一个字节都不写**、**不开任何设备节点**）与它的
harness **266 项**；它接进了"一次启动"的默认集（新步骤 **04m**）。清单从 **2 个缺口**变成 **1 个**。

**接续**: [`137`](137-a-boot-should-answer-the-question-nobody-asked.md)（缺口的来源）、
[`143`](143-the-tree-enables-two-and-the-kernel-builds-neither.md) / [`144`](144-the-tree-is-explicit-about-the-one-nothing-can-bind.md) /
[`145`](145-the-count-that-is-a-string.md) / [`146`](146-the-config-line-outside-its-own-menu.md)（前四次收口），
[`124`](124-the-boot-a-finger-bought-is-one-command.md)（一次启动是一个命令）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 为什么收这个？ | 它是剩下缺口里**唯一一个"决定它在不在的东西不是配置行、不是源码，而是设备树自己写的一行 `status`"**的块——而且它是**逆向**的：别的块是"树打开了、内核没编"，它是"**内核编了、树关掉了**" |
| 这一块由谁描述？ | **一个节点**：`/soc/i2c@75b5000/silabs4705@11`（`silabs,si4705`），在 F R S 三个集合里都在，15 棵 LE_ZL1 树里形状完全相同 |
| 第一件要紧的事？ | **设备树把它关掉了。**`status = "disabled"`——**15 棵树、三个集合，全部如此**。而这个项目**此前读过的每一个块都没有 `status` 属性**（设备树把"没有 status"读作**打开**）。所以这一块是整个项目里唯一的例外，而例外是**反方向**的 |
| 为什么这要紧？ | 因为 i2c 核心**不会**给一个不是 okay 的节点建客户端：**没有客户端、没有绑定、没有 radio 设备**，而**这跟内核怎么编的一点关系都没有**。所以"这个块为什么没工作"这个问题，答案在**设备树**里，不在配置里、也不在接线里 |
| 那"驱动没编"这个显而易见的解释呢？ | **是错的**。`CONFIG_RADIO_SILABS=y` 在项目手上的**两颗内核**里——vendor boot image 的 3.18.120 内核**和**这块板正在跑的 v63 Halium 3.18.140 内核。**驱动的确编进去了，是树拒绝了那个节点** |
| 那它和上一块（`nfc`）是什么关系？ | **互为镜像**。`nfc` 的决定项是一行配置，而且那一行**写在它看起来应该受其管辖的菜单之外**、在出货内核里是关的；`fm-radio` 的配置链**完全打开**，而树把这个节点关掉了。**两个块、两个方向**，所以两个探针都得有——一个按另一个的形状去读，两个都会读错 |
| 那这一块的配置链是什么样？ | **是正规的形状**：`config RADIO_SILABS` 写在 `if RADIO_ADAPTERS && VIDEO_V4L2` **里面**，而 `RADIO_ADAPTERS` 自己是一个 `menuconfig`，依赖 `VIDEO_V4L2` 和 `MEDIA_RADIO_SUPPORT`。所以"这一项没打开"在这块板上有**四个可能的父项**，探针因此印**四行**而不是一行 |
| 第二件要紧的事？ | **这个节点把它的两个中断描述了两遍，而两遍走的是不同的机制。**`interrupts = <0 1>` 加上 `interrupt-map = <0 28 38 2  1 28 78 1>`：子中断 0 → TLMM gpio 38（flag 2 = 下降沿），子中断 1 → TLMM gpio 78（flag 1 = 上升沿）——**正是驱动自己读的那两个脚**（`silabs,int-gpio` = `<28 38 0>`、`silabs,status-gpio` = `<28 78 0>`） |
| 为什么这要紧？ | 因为**驱动一个都不用它**：`interrupt-map` 完全不读，而是在 **open 的时候**对**自己的 gpio** 调 `gpio_to_irq()`。**把 `interrupts` 当成"FM 的中断"引出来，引的是一句没有任何东西执行的描述** |
| 第三件要紧的事？ | **三个 gpio，两个致命；两个调压器，一个都不致命**——而**三个 pgpio 之外，那两个电压属性是致命的**。`silabs,reset-gpio` 致命得最彻底（`silabs_parse_dt()` **把 gpio 自己的负 errno 返回出去**），`silabs,int-gpio` 同样致命，而 `silabs,status-gpio` **是可选的**（一个 `FMDERR`，之后代码用 `> 0` 判断）；两个 supply 恰好相反：`regulator_get("va")` 失败只会 defer 或跳过，`regulator_get("vdd")` 失败打印一句"vdd supply is not provided"就继续 |
| 那"电源这一半"就完全宽松吗？ | **不是**：`silabs,va-supply-voltage` / `silabs,vdd-supply-voltage` 由 `of_property_read_u32_array(np, name, vol, 2)` 读取，也就是**恰好两格**——长了**被静默截断**，短了（或缺席）返回 `-EINVAL`，probe 走到错误路径。所以"节点完整"和"驱动能绑"在这一块**也是两个不同的问题**，而且切法和 `nfc` 那块不一样 |
| 这块板的两个 supply 是什么？ | **一种一个，这正是读数**：`va-supply` 指向 `/soc/rome_vreg`，`compatible = regulator-fixed`——**是 PMIC 的一个 GPIO 驱动一个固定电压**（`gpio = <29 9 0>`、`enable-active-high` 是布尔、`startup-delay-us = 4000`），**给这个芯片上电就是驱动那个引脚**；`vdd-supply` 指向 `.../rpm-regulator-smpa4/regulator-s4`（`qcom,rpm-smd-regulator`，`regulator-name = pm8994_s4`，1800000 uV），**电压归 RPM 管、不从 CPU 问** |
| 这一块"写级别"的动作是什么？ | **打开设备节点**：`silabs_fm_fops_open()` 跑 `silabs_fm_power_cfg(TURNING_ON)`——两个调压器、pinctrl 的 active 状态、三个 gpio 全部配好——而第一个 ioctl 就通过 i2c 真的对芯片下命令（`send_cmd` → `i2c_transfer`）。**`open("/dev/radioN")` 是一个硬件动作，不是对硬件的读数** |
| 有 sysfs 可写面吗？ | **有，一个**：v4l2 核心给每个 radio 设备挂的属性里有 **`debug`（`DEVICE_ATTR_RW`）**——`/sys/class/video4linux/radioN/debug`，是这个块**唯一**的可写文件，而它是 v4l2 的啰嗦程度旋钮，不是硬件。探针两个都不做 |
| 那"radio 设备叫什么编号"？ | **编号是分配的，名字才是身份**。这个驱动 `RADIO_NR` 是 **-1**，也就是"第一个空号"，所以 `/sys/class/video4linux/radioN` 的 **N** 是注册顺序；而这个 v4l2 设备的 `name` 属性读出来是 **`radio-silabs`**。所以探针**遍历整个 class、按 `name` 属性认设备**，而不是去读 `radio0` |
| 一个块有几个名字？ | **四个**，只有第二个是 sysfs 里的 i2c 路径：compatible `silabs,si4705`、i2c 驱动的 `.name` **`silabs-fm`**（目录 `/sys/bus/i2c/drivers/silabs-fm`）、它的 `i2c_device_id` **`radio-silabs`**（不按设备树匹配时会用这个名字，而它**不是**路径）、以及 **`radio-silabs` 又是那个 v4l2 设备的名字** |
| 还有一个更阴的？ | **有一个永远绑不上这个节点的驱动**：`drivers/media/radio/si470x/radio-si470x-i2c.c` 声明 `.name = "si470x"`，而它**根本没有 `of_match_table`**。**grep `si470` 会找到两个文件，而只有一个能绑这个节点**——探针把这个"近邻"印在驱动行下面，就是为了让人不必猜 |
| 那探针怎么报？ | 先认板子，再爬阶梯：`tree-unscanned` / `wrong-board-tree` / `unknown-board` / `no-device-tree-node` / `no-driver-for-node` / **`no-node-enabled`** / `no-client` / `driver-not-built` / `driver-not-registered` / `driver-not-bound` / `no-radio-device` / `radio-registered` |
| 为什么 `no-client` 排在 `driver-not-*` **前面**？ | 和 `nfc` 同一条理由：客户端是 i2c 核心按设备树建的，**客户端不存在时任何一行配置都修不了它**，下一步是那个 i2c 控制器（或它的 alias），不是 FM 驱动 |
| 离线验证？ | `scripts/host/zl1-fm-radio-probe-selftest.sh`，**266 项**：stub 目录**就是**设备，一级一个场景，**三条根路径**（`/proc/`、`/sys/`、**`/dev/radio`**）的改写，设备树属性按**字节**写，一个"除了 `find(1)` 什么都有"的沙箱，**十三个变异**各让它红 |
| 动设备了吗？ | **没有。** |

---

## 2. 设备树里到底有什么（逐字节读出来的）

15 棵 LE_ZL1 树里这个节点**形状完全相同**，所以"树里有没有 FM"分不出两台手机，只能靠 `model`：

```
/soc/i2c@75b5000/silabs4705@11        compatible = silabs,si4705
    status          = "disabled"        ← **15 棵树、三个集合里全部如此** ← 这一块的全部答案
    reg             = <0x11>            ← i2c 从机地址 17；sysfs 里的名字是 "7-0011"
    silabs,reset-gpio  = <28 39 0>      TLMM(28) gpio 39   ← 驱动读：复位（**致命**）
    silabs,int-gpio    = <28 38 0>      TLMM(28) gpio 38   ← 驱动读：中断（**致命**）
    silabs,status-gpio = <28 78 0>      TLMM(28) gpio 78   ← 驱动读：状态（**可选**）
    interrupt-parent   = <28>   interrupts = <0 1>
    interrupt-names    = "silabs_fm_int" "silabs_status_int"
    interrupt-map      = <0 28 38 2  1 28 78 1>   ← 把这些子中断接到**上面那两个脚**
    va-supply          = <251>   silabs,va-supply-voltage  = <3300000 3300000>
    vdd-supply         = <250>   silabs,vdd-supply-voltage = <1800000 1800000>
    pinctrl-names      = "pmx_fm_active" "pmx_fm_suspend"
    pinctrl-0          = <252 253 254>    pinctrl-1 = <255 256 257>

/aliases/i2c7 = /soc/i2c@75b5000       ← 总线号来自这里，而客户端名字由它 + reg 组成
```

四个 phandle：

| phandle | 节点 | 这一块用到它的哪里 |
|---|---|---|
| **28** | `/soc/pinctrl@01010000`（`qcom,msm8996-pinctrl`） | 三个 gpio 和 `interrupt-map` 里的两个脚 |
| **29** | `.../pm8994@0/gpios`（label `pm8994-gpio`） | `rome_vreg` 自己那个 `gpio = <29 9 0>` |
| **250** | `.../rpm-regulator-smpa4/regulator-s4`（`regulator-name pm8994_s4`） | `vdd-supply`——**RPM 管的轨** |
| **251** | `/soc/rome_vreg`（`regulator-fixed`） | `va-supply`——**GPIO 开关** |

三个 pinmux 组的名字本身就是读数：`pinctrl-0`（ACTIVE）解析成
`/soc/pinctrl@01010000/pmx_fm_int/fm_int/active`、`.../pmx_fm_status/fm_status_int/active`、
`.../pmx_fm_rst/fm_rst/active`——**三组正好对应这一块的三个脚**。而且驱动是**按字符串**去找这两个状态的
（`pinctrl_lookup_state(..., "pmx_fm_active")`），所以名字拼错**不会失败**，只会让驱动拿到一个空 pinctrl
（那里 `-EINVAL` 被转成了成功）。

同一条总线上还有**另一个块**：`cclogic_dev@3d`（`cypress,cyccg`，就是 `usb-pd` 那一行里的一个节点）。
探针把这一点印出来，因为"这条总线上有什么"不是只有一个答案，而一个把它当成 FM 收音的读数会把两行混成一行。

---

## 3. 这一块的配置链是**正规**的（这正是它值得单独读的理由）

```kconfig
# drivers/media/radio/Kconfig
menuconfig RADIO_ADAPTERS
        bool "Radio Adapters"
        depends on VIDEO_V4L2
        depends on MEDIA_RADIO_SUPPORT        # ← 两个父项
...
if RADIO_ADAPTERS && VIDEO_V4L2               # ← 这一块在里面
config RADIO_SILABS
        tristate "Silicon Labs Si470x FM Radio Receiver support"
```

| 内核 | MEDIA_RADIO_SUPPORT | VIDEO_V4L2 | RADIO_ADAPTERS | **RADIO_SILABS** |
|---|---|---|---|---|
| stock boot image（3.18.120） | y | y | y | **y** |
| v63 Halium（3.18.140，这块板正在跑） | y | y | y | **y** |

**两颗内核都是 `CONFIG_RADIO_SILABS=y`。**所以"这个块的驱动没编"这句话，在项目手上这两颗内核里都是错的——
而这正是这一块与 [`146`](146-the-config-line-outside-its-own-menu.md) 的 `nfc` **互为镜像**的地方：

| | `nfc`（146） | `fm-radio`（本篇） |
|---|---|---|
| 决定它的东西 | 一行**配置**（`CONFIG_NFC_NQ`） | 设备树里的**一行 `status`** |
| 那一行/那一项在哪 | 写在它**看起来该管的菜单之外** | 写在 `if RADIO_ADAPTERS && VIDEO_V4L2` **里面**（正规） |
| 出货内核里它是什么 | **关的** | **开的** |
| 所以下一个动作是 | 改 defconfig、重编 boot image | 改设备树、重编 boot image |

探针把链路**四行**都印出来，因为"这一项没打开"在这块板上有四个可能的父项；而它只用**最后一行**做结论。
还有一个第三状态：**配置读不到**（文件不在、或者没有 zcat/gunzip 能展开它）。这时四列印 `NOT READ`，
而结论**不会**说"这颗内核没编这个驱动"——那是第四种状态，也是唯一一种能怪配置行的状态。

---

## 4. 三个 gpio、两个致命；两个调压器、一个都不致命；而**电压属性是致命的**

```c
/* drivers/media/radio/silabs/radio-silabs.c -- silabs_parse_dt() */
ret = of_get_named_gpio(node, "silabs,reset-gpio", 0);
if (ret < 0) { ...; return ret; }              /* 致命，而且返回的是 GPIO 自己的 errno */
ret = of_get_named_gpio(node, "silabs,int-gpio", 0);
if (ret < 0) { ...; return ret; }              /* 致命 */
ret = of_get_named_gpio(node, "silabs,status-gpio", 0);
if (ret < 0) FMDERR(...);                      /* **不致命**：之后用 status_gpio > 0 判断 */

/* silabs_dt_parse_vreg_info() -- 每个 supply 旁边的电压 */
ret = of_property_read_u32_array(np, vreg_name, vol_suply, 2);   /* **恰好两格** */
if (ret) return -EINVAL;                                          /* 致命 */
```

这一段的四个分支，harness 是一条一条量过的：

| 场景 | 树 | 驱动能绑吗 | 结论必须是 |
|---|---|---|---|
| `reset-absent` / `int-absent` / `gpio-short`（不是整格） | 致命读缺失或无效 | 不能 | `driver-not-bound`，而且结论里**点名**缺的是哪一个 |
| `voltage-odd`（三格）/ `voltage-absent` | 电压属性不是两格 | 不能 | 同上，点名的是那个**电压属性** |
| `status-absent` | 可选的第三个 gpio 缺 | **能** | `radio-registered`（最高一级） |
| `no-supply` | 两个 supply 都缺 | **能** | `radio-registered` |
| `pinctrl-renamed` | pinctrl 名字换了 | **能**（那个 `-EINVAL` 被转成成功） | `radio-registered` |

后三行是这一节的要害：**把它们任何一行当致命，就会在一块正常工作的板上报出"这块是死的"**。
而 `voltage-odd` 那一行是相反的陷阱：**supply 缺席不致命，但 supply 旁边那个电压属性缺席/多一格是致命的**。

---

## 5. 三层证据，四个名字，一个永远绑不上的邻居

```
设备树 ──► i2c 客户端  /sys/bus/i2c/devices/7-0011      ← 只要总线驱动在、且节点 status 是 okay，它就在
                 │
                 └─► 绑定    /sys/bus/i2c/drivers/silabs-fm/7-0011  ← 需要：驱动被编 + 被注册 + 两个致命 gpio 与两个电压属性都过
                              │
                              └─► radio 设备 /sys/class/video4linux/radioN/name = "radio-silabs"
                                            ← video_register_device() 是 probe 的**最后**一步
```

在这一块上，**第一层就是缺的那一层**——因为节点自己写着 `disabled`。所以探针的顺序把"节点被关掉"
排在了客户端之前，而且客户端那一节会把这一条**明说**：客户端不在**不是总线的故障**，是设备树的决定
（总线好不好，由上面总线那一节回答）。

而**第三层的身份是 `name` 文件，编号是分配出来的**：`RADIO_NR` 是 -1，所以 `radio0` 是"第一个空号"。
harness 里有一个场景把这一块的设备放在 **`radio3`**，同时在 **`radio0`** 放一个**不相干的设备**：
**按编号找就等于在赌注册顺序**，而那正是第十一号变异。

四个名字里唯一是 sysfs 路径的是 `silabs-fm`；harness 的第八个变异就是把驱动按 `radio-silabs` 去查，
于是**驱动目录读成"没注册"**，而同一份报告里客户端还在——两列自相矛盾，正是这个缺陷的形状。

---

## 6. 写级别的那一步是**打开设备**（外加一个可写属性）

| 面 | 为什么它是写级别的 |
|---|---|
| `open("/dev/radioN")` | `silabs_fm_fops_open()` → `silabs_fm_power_cfg(TURNING_ON)`：**两个调压器上电、pinctrl 选 active、三个 gpio 配好**——真实引脚 |
| 设备节点上的第一个 ioctl | `send_cmd()` → `i2c_transfer()`：**真的对芯片下命令** |
| `/sys/class/video4linux/radioN/debug` | v4l2 核心的 `DEVICE_ATTR_RW(debug)`——这个块**唯一**的可写文件（一个啰嗦程度旋钮，与硬件无关） |
| `silabs,reset-gpio` / `va-supply` / 两个电压属性 | 设备树属性：**boot image 的决定**，不是运行时旋钮，探针按属性读它们 |

探针**一个都不做**：它遍历 `/sys/class/video4linux/*` 读 `name`/`dev`/`index`（普通文本），
`/dev/radioN` **一次都不打开**、也不 stat 成设备，`debug` 只读不写。harness 的静态写守卫有**七个"牙齿"**夹具，
其中两个就是这一块的真实诱惑：`printf 1 > /dev/radio0`（打开就等于上电）和
`printf 2 > /sys/class/video4linux/radio0/debug`（唯一可写属性）。

---

## 7. 设备状态与复现

整轮没有动设备：没有写任何分区或 boot，没有跑 QDL/QFIL，没有重启。设备仍在 **Qualcomm EDL**（`05c6:9008`）。
识别目标一律按序列号 **`33e80afe`**；总线上另一台小米 **`4a2fe00b`** 必须忽略。恢复仍然只能靠**物理长按电源 10–20 秒**。

```sh
# 全部在宿主机上，不碰设备。
bash scripts/host/zl1-hardware-inventory.sh --block fm-radio     # 1 个节点，现在有仪器了
bash scripts/host/zl1-hardware-inventory.sh --gaps               # 现在只剩 1 个缺口：eeprom
bash scripts/host/zl1-fm-radio-probe-selftest.sh                 # 266 项

# 本块最核心的那个变异（把树自己写的 disabled 读成打开，必须红）：
P=scripts/device/zl1-fm-radio-probe.sh
sed 's#^  okay | ok | EMPTY | absent) NODE_EN=yes ;;$#  okay | ok | EMPTY | absent | disabled) NODE_EN=yes ;;#' \
  "$P" > /tmp/mut-disabled.sh
ZL1_FM_RADIO_PROBE_SRC=/tmp/mut-disabled.sh bash scripts/host/zl1-fm-radio-probe-selftest.sh

# 设备回来之后（只读、不写任何东西、不打开任何设备；或直接跑 capture，它已经把 04m 放进默认集）：
scp scripts/device/zl1-fm-radio-probe.sh root@10.15.19.82:/tmp/ && ssh root@10.15.19.82 'sh /tmp/zl1-fm-radio-probe.sh'
# 它会先回答"这棵树是不是这块板"，再回答节点在不在、`status` 到底是什么、三个 gpio 与两个 supply 各是什么样、
# 配置链的四行各是什么，以及客户端/绑定/radio 设备三层证据到了哪一层。
```

---

## 8. 这一轮**不**证明什么

* **不证明 FM 收音机能用，也不证明不能用。**恰恰相反：它证明的是**软件路径**到了哪一层——
  客户端、绑定、radio 设备**一个都不是电台**，而且芯片此刻是**关着的**：`silabs_fm_probe()` 什么都不上电，
  上电发生在**有人 open 设备节点**的时候。
* **不证明"改一行 `status` 就好了"。**它只说明**这一颗内核的驱动是编好的**；把 `disabled` 改成 `ok`
  是**重编一个 boot image** 的决定（要重新签名、要重新刷 boot 分区），那是一件需要单独审查的动作，
  并且与本项目"先备份、再校验"的规矩一起看。这一轮**没有**做，也没打算在这一轮做。
* **不证明 `si470x` 那个驱动是"多余的"。**它服务的是**别的**板子/别的匹配方式；探针把它印出来只是为了说明
  **grep `si470` 会找到两个文件、而只有一个能绑这个节点**。
* **不证明设备上落在哪一级。**这一轮**一次 ssh 都没有**：266 项全部挡在 stub 目录后面，场景是我造的。
  设备上真实的样子——尤其"客户端是不是真的不在"——只有设备回来才知道。
* **不证明"总线上另一个节点"是 `usb-pd` 的全部。**那一行有 6 个节点（[`143`](143-the-tree-enables-two-and-the-kernel-builds-neither.md)），
  这里只是说**这条总线上不只有 FM**。
* **不证明剩下 1 个缺口（`eeprom`）不重要。**只是这一块的问题**最容易被"读配置行"一次答错**，
  而"答错"是可以量的。

---

## 9. 文件与改动

| 文件 | 作用 |
|---|---|
| `scripts/device/zl1-fm-radio-probe.sh` | 新：FM 探针（一个节点、树自己写的 `disabled`、两套中断描述走不同机制、三个 gpio 两致命、两个 supply 不致命而两个电压属性致命、两个 supply 一种一个、一个可写属性、一个永远绑不上的邻居），**board-first**，十二级阶梯，只读**且不写任何东西、不打开任何设备节点** |
| `scripts/host/zl1-fm-radio-probe-selftest.sh` | 新：**266 项**，stub 目录就是设备，**三条根路径**改写（含 `/dev/radio`），设备树属性按字节写（含节点 18 个属性与六个 pinmux 组），一个"除了 `find(1)` 什么都有"的沙箱，**十三个变异** |
| `scripts/host/zl1-hardware-inventory.sh` | 改：`fm-radio` 行点名仪器；汇总 27/2 → **28/1** |
| `scripts/host/zl1-hardware-inventory-selftest.sh` | 改：汇总数字改成 28/1；`fm-radio` 从缺口循环移到"已覆盖、按名字与节点数断言"那一组 |
| `scripts/host/zl1-post-recovery-capture.sh` | 改：默认集新增 **04m-fm**（只读、不写、不需要人在场、不打开设备） |
| `scripts/host/zl1-post-recovery-capture-selftest.sh` | 改：170 → **173** 项（步骤数与 push 数、归档文件数一起改：16 步/14 push/17 归档 → **17 步/15 push/18 归档**） |
| `scripts/host/zl1-health-check.sh` | 改：新增 **5h. FM RADIO**（树自己关节点、两颗内核都编了驱动、四行配置链、两套中断、三个 gpio 两致命、两个 supply 一种一个、两个电压属性恰好两格、`name` 是身份编号是分配、四个名字、一个 `of_match_table` 都没有的邻居、打开设备就是上电）；0g 改写为 **1 of 29**；capture harness 引用 170 → **173**；cli-usage 引用 176 → **180**（它扫的脚本 65 → 67）；新增 fm harness 引用 **266** |
| `scripts/README.md` | 改：两个新脚本各一行；cli-usage 176 → **180**、覆盖集 80 脚本 → **82**、括号里两个数改成 62 + 5；capture 170 → **173**、步骤 16/14/17 → 17/15/18，并补上 04m |
| `docs/ubuntu-touch/137-*.md` | 改：后续注记 2 → **1 个缺口**，汇总 27/2 → **28/1** |
| `docs/ubuntu-touch/139-*.md` | 改：后续注记 2 → **1 个缺口**，汇总 27/2 → **28/1**，缺口表补上这一轮的收口 |
| `docs/ubuntu-touch/124-*.md` | 改：家族总数那一行续上本轮 |
| `README.md` | 改：本页的索引行 |
| `docs/ubuntu-touch/147-*.md` | 本篇 |
