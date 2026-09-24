# 139 — 用户最先摸到的两个块：通知灯和手电筒，从来没有被读过

**日期**: 2026-09-24
**状态**: 本轮**没有碰设备**（设备仍在 Qualcomm EDL，见 §9）。这是 [`137`](137-a-boot-should-answer-the-question-nobody-asked.md)
那份"没有探针"清单的第三次收口，而且一次收两个：**通知/充电 RGB 灯**和**相机手电筒**——也就是**手指最先碰到的两个块**。
新工具 `scripts/device/zl1-leds-probe.sh`（只读、**一个字节都不写**），新 harness **91 项**（九个变异各让它红 1–8 次），
并接进"一次启动"的默认集（新步骤 **04e**）。清单从 **11 个缺口**变成 **9 个**。
家族 **23 个 harness / 2627 检查 / 全绿**（本页之前是 2529）。

**后续**: 本页之后，`vibrator` 这一行也关掉了，而且它引出的不是一条新缺口，而是**这份清单本身的一个错误**：
那一行点名的"仪器"（`ti,drv2604l`）是**另一台手机**（LeEco X2）的芯片，见
[`140`](140-the-block-that-was-another-phones.md) 和 [`141`](141-the-largest-gap-is-two-layers-that-fail-differently.md)。
本页正文的 **9 个缺口**是当天的读数；此后 [`142`](142-the-removable-slot-is-switched-off-in-the-tree.md)、
[`143`](143-the-tree-enables-two-and-the-kernel-builds-neither.md)、
[`144`](144-the-tree-is-explicit-about-the-one-nothing-can-bind.md) 与
[`145`](145-the-count-that-is-a-string.md) 又各收一个，[`146`](146-the-config-line-outside-its-own-menu.md) 再收一个，
[`147`](147-the-tree-switches-off-the-block-both-kernels-build.md) 收的是**唯一一个设备树自己把节点关掉、而两颗内核都把驱动编进去了**的块，
而 [`148`](148-the-block-with-nothing-missing-is-the-one-that-binds-through-a-name-the-tree-never-spells.md) 收的是**唯一一个什么都不缺**的块
（`eeprom`，驱动在两颗内核里都编了、树也没关它）——**12 个缺口到此全部关掉，清单为空**，
而 `zl1-hardware-inventory.sh` 的汇总行是 **29 / 0**，并且清单空了之后它不再只是不印，而是明说一句
"29 of 29 rows, 0 gaps"。
本页之后又收了一个：两个 SD/eMMC 控制器那个 `sdcard` 缺口，见
[`142`](142-the-removable-slot-is-switched-off-in-the-tree.md)，以及设备树打开了两个节点、内核却一个驱动都没编的那个
`usb-pd` 见 [`143`](143-the-tree-enables-two-and-the-kernel-builds-neither.md)（它同时改掉了 [`137`](137-a-boot-should-answer-the-question-nobody-asked.md) §3.2
把另一台手机的 CC 逻辑当成这台手机的一处错误），两个发射器世代抢同一个寄存器窗口的 `hdmi` 见
[`144`](144-the-tree-is-explicit-about-the-one-nothing-can-bind.md)（设备树明确打开的那个反而没人能绑）。清单现在是 **4 个**缺口。

**接续**: [`137`](137-a-boot-should-answer-the-question-nobody-asked.md)（缺口的来源）、
[`138`](138-the-hardware-limiter-had-never-been-read.md)（前一天收的第三个，硬件限温器）、
[`124`](124-the-boot-a-finger-bought-is-one-command.md)（一次启动是一个命令——04e 加进的就是它）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 为什么一次收两个？ | 因为它们**在设备树里是一族**、而且在运行时**是两个独立的驱动**。设备树里五个节点带 LED 类 `compatible`；**通知灯**（PMI8994 `leds@d000`，子节点 `linux,name` = `red`/`green`/`blue`）和**手电筒**（PMI8994 `leds@d300`，`qcom,qpnp-flash-led`，子节点 `qcom,led-name` = `led:torch_0`/`led:flash_0`/…）是同一族里用户最常碰的两个 |
| 这个探针读的是什么？ | **一次比较**：设备树**声明**了什么名字（`linux,name` / `qcom,led-name`），LED core **注册**了哪些条目。这是这块板上唯一一个**不需要猜**就能说"某个驱动没注册成"的读数 |
| 为什么值得单独一个探针？ | 因为"灯不亮"和"灯没注册"是**完全不同的两件事**，而前者根本不是缺陷（空闲的手机灯就是灭的）。能作为证据的只有两样：**条目在不在**，以及**驱动有没有绑上设备**。把这两样分开，正是这个探针存在的理由 |
| 有哪些节点？ | `pm8994@0/leds@a100`（MMP → `button-backlight`）、`pmi8994@3/leds@d000`（`label = "rgb"`，**带 `qcom,rgb-sync`**）、`pmi8994@3/leds@d300`（`qcom,qpnp-flash-led`，`label = "flash"`）、`pmi8994@3/leds@d800`（`qcom,qpnp-wled`，`linux,name = "wled"`，触发 `bkl-trigger`）、以及 `/soc/qcom,camera-flash`（`label = "leds-lm3643"`，相机栈这一端，`qcom,torch-source`/`flash-source` 用 phandle 指向 PMIC 的源） |
| 名字声明在哪儿？ | **两个地方**：`wled` 声明在**节点本身**，其余全部声明在**子节点**。只读子节点的第一版会把 `wled` 悄悄漏出比较之外——这正是 harness 的第一个变异 |
| 有几个驱动、几条总线？ | **三个 SPMI 驱动**（`qcom,leds-qpnp`、`qcom,qpnp-flash-led`、`qcom,qpnp-wled`，所以它们出现在 `/sys/bus/spmi/drivers/`）+ **一个平台驱动**（`qcom,camera-flash`，出自相机栈 `drivers/media/platform/msm/camera_v2/sensor/flash/msm_flash.c`）。**任何一条都能单独没注册**，这就是读数必须是"阶梯"而不是一个开关的原因 |
| 读哪几级？ | `no-device-tree-nodes` / `no-led-class` / `declared-names-missing` / **`no-flash-class`**（手电筒那一半单独一级，因为它是**另一个驱动**）/ `registered`。缺的名字**逐个印出来**，不留给读者去 diff 两张表 |
| 怎么区分"这是哪个驱动注册的条目"？ | **看属性，不看名字**：`rgb_blink`/`on_off_ms` 属于 leds-qpnp.c，`reg_dump`/`max_allowed_current` 属于 leds-qpnp-flash.c，`dim_mode`/`fs_curr_ua` 属于 leds-qpnp-wled.c。属性清单是从源码里抄的，所以这是一个读数，不是一个猜想 |
| 它还发现了一个什么？ | **反向也要比。** `leds-qpnp.c` 在节点带 `qcom,rgb-sync` 时会**额外**注册一个叫 `rgb` 的 classdev（`rgb_blink` 就在它上面），而设备树**从来没声明过这个名字**。只做单向比较会把这个条目藏起来，所以探针两个方向都印 |
| 它写东西吗？ | **一个字节都不写。** 而这一条在这里特别要紧：class 里**每一个条目都是可写的**（`brightness`，flash 驱动还有 `strobe`），所以"顺手点亮一下看看"是这个探针最容易被诱惑去做的事。harness 的第一个变异就是那次写入 |
| 离线验证？ | **91 项**：stub 目录**就是**设备，PATH 沙箱化，两趟 token 改写（每趟在自己的输入上计数并断言无残留）；**一级一个场景**；夹具是**真实形状**（节点级/子节点级的名字两种都有，`qcom,rgb-sync` 的额外条目也有，每个驱动的属性各是它自己那一组） |
| 怎么保证它会被跑？ | 接进 `zl1-post-recovery-capture.sh` 的默认集，作为 **04e**，与 04b/04c/04d 同一类：只读、不开块设备、不需要人在场。capture 的 harness 149 项（加一步就要按名字、顺序、scp 路径、归档文件全部改一遍） |
| 动设备了吗？ | **没有。** |

---

## 2. 为什么"灯"值得一个探针：能作为证据的东西只有两样

发烫、GPS、指纹这些线上，"读数"通常是**数值**。灯不一样：**空闲的手机上灯就是灭的**，所以
`brightness=0` 和 `trigger=none` 与"这些灯根本驱动不了"在读数上**完全一样**。探针的结尾专门写了这一条（`WHAT THIS IS NOT`）。

于是能作为证据的只剩两样，而且都很硬：

1. **条目在不在 class 里。** 设备树声明了名字，LED core 就该有一个同名条目。名字缺了，说明那个驱动没注册成功——
   或者节点 `status` 是 disabled，或者它的 probe 失败了（日志那一节会说为什么）。
2. **驱动有没有绑上设备。** `/sys/bus/*/drivers/<drv>/` 这个目录在模块注册时**就出现**，
   而**有设备挂上去**是里面多一个符号链接。这是两件不同的事，只有后者意味着某个节点真的被 probe 过。

顺带，`max_brightness` 也是可读的：它是驱动说"这块硬件允许什么"的值，所以它能区分"条目在但驱动没接上硬件"和"条目在且硬件参数读得出来"。

---

## 3. 设备树里到底声明了什么

```sh
# 从 38 个 DTB 里读出来的（docs 137 的快照），五个节点：
/soc/qcom,spmi@400f000/qcom,pm8994@0/qcom,leds@a100       qcom,leds-qpnp
    qcom,led_mpp_2      linux,name = "button-backlight"      # 电容键背光
/soc/qcom,spmi@400f000/qcom,pmi8994@3/qcom,leds@d000      qcom,leds-qpnp    label = "rgb"
    qcom,rgb-sync       <- 空属性，它让驱动额外注册一个叫 rgb 的 classdev
    qcom,rgb_0/1/2      linux,name = "red" / "green" / "blue"  qcom,use-blink
/soc/qcom,spmi@400f000/qcom,pmi8994@3/qcom,leds@d300      qcom,qpnp-flash-led  label = "flash"
    qcom,flash_0/1      qcom,led-name = "led:flash_0" / "led:flash_1"
    qcom,torch_0/1      qcom,led-name = "led:torch_0" / "led:torch_1"
    qcom,switch         qcom,led-name = "led:switch"
/soc/qcom,spmi@400f000/qcom,pmi8994@3/qcom,leds@d800      qcom,qpnp-wled    linux,name = "wled"
    linux,default-trigger = "bkl-trigger"                    # 显示屏背光（docs 137 的 backlight 行）
/soc/qcom,camera-flash                                    qcom,camera-flash  label = "leds-lm3643"
    qcom,flash-source / qcom,torch-source                    # phandle 指向上面的 flash_*/torch_*
```

三件事值得单独说：

* **`leds@d800` 的名字声明在节点上，不在子节点上。** `linux,name = "wled"` 和 `linux,default-trigger = "bkl-trigger"`
  是这个节点**自己的**属性（它的 LED 就是它自己）。探针第一版只读子节点，于是 `wled` **从来没有进入比较**——
  也就是说，显示屏背光那个条目**从 class 里消失**这件事，报告会一声不吭。**缺陷在能工作的那个形状里是看不见的**，
  所以 harness 为两种形状各留了一个断言。
* **`qcom,rgb-sync` 会产生一个设备树没声明的条目。** `leds-qpnp.c` 里 `rgb_sync->cdev.name = "rgb"`，
  然后 `sysfs_create_group(..., &rgb_blink_attr_group)`——也就是说 `rgb_blink` 这个属性住在 **`rgb`** 上，
  而不是 `red` 上。所以 class 里会有**九个**条目（`red`/`green`/`blue`/`rgb`/`button-backlight`/`wled` + 三个 `led:*`），
  而设备树只声明八个。**只做单向比较会把多出来的那个藏起来**，所以探针印 `registered but NOT declared`。
* **`qcom,camera-flash` 是另一端。** 它由相机栈的平台驱动绑定（`msm_flash.c`），
  而它 `qcom,torch-source`/`flash-source` 指的就是 PMIC 上那几个源。所以手电筒这条链有**两个驱动**，
  任何一个没起来都会让"打开手电筒"什么也不发生——探针把 `qcom,qpnp-flash-led` 有没有绑上设备单独印出来。

---

## 4. 读数是"阶梯"，因为三个驱动可以各自失败

```
no-device-tree-nodes   设备树里根本没有 LED 节点        -> 这是"启动了哪个 image"的读数（docs 137）
no-led-class           /sys/class/leds 空的或不存在    -> 一个 LED 驱动都没注册；下一手是驱动那一节
declared-names-missing 声明的名字有条目缺失（非 led: 前缀）-> 逐个点名缺哪些
no-flash-class         通知灯和背光都在，手电筒那一半不在 -> 另一个 SPMI 驱动 + 相机栈那一端
registered             声明的每一个名字都注册了           -> 健康；但"亮不亮"不在这里回答
```

`no-flash-class` 单独一级，是因为它的**下一步完全不同**：`declared-names-missing` 要去看 `leds-qpnp.c` 的
SPMI 绑定和节点 `status`，而 `no-flash-class` 要去看 `qcom,qpnp-flash-led` 的 probe 和相机栈。
把两者合成一句"有些名字缺了"，就是把读者送到错的驱动前面。

---

## 5. harness：91 项，九个变异，和真实形状的夹具

`scripts/host/zl1-leds-probe-selftest.sh`。纪律与它的兄弟一致（stub 目录就是设备、PATH 沙箱化、
`/proc` 与 `/sys` 两趟 token 改写且 landing 数作为不变量断言），加上一条这里特有的：

**夹具必须是真实形状。** 因为这一页的产物是一次比较，夹具错了就等于比较错了：

* 名字声明在**节点**（`wled`）和**子节点**（其余全部）两种形状都有；
* `qcom,rgb-sync` 那个**额外的** `rgb` classdev 也在（连同 `rgb_blink`），否则"registered but NOT declared"
  这条读数在**唯一会产生它的情形里**反而没人测；
* 每个驱动的自定义属性**各是它自己那一组**：flash 是 `strobe`/`reg_dump`/`max_allowed_current`；
  wled 是 `dump_regs`/`dim_mode`/`fs_curr_ua`；rgb 是 LPG 组（含 `on_off_ms`/`rgb_start`，这是 vendor 内核）；
  MPP（`button-backlight`）是 LPG 组**但去掉** `rgb_blink`——所以"这是哪个驱动注册的"是被**断言**的，不是被假设的。

九个变异，每一个都必须让它红：

| 变异 | 红 |
|---|---|
| 只读子节点（第一版的缺陷） | 5 |
| 把 flash / 其他 的切分取消（`no-flash-class` 永不可达） | 4 |
| 把"空闲"变成一级判决（`brightness=0` 当成故障） | **8** |
| 去掉反向比较（多出来的条目不再报） | 2 |
| trigger 不取当前值，整页打印 | 3 |
| 只 glob 一条总线（平台那条） | 5 |
| 去掉驱动去重（同一个驱动列两遍） | 2 |
| 设备闸门改成 `grep -qa .`（还在，但不再判断） | 5 |
| **点亮手电筒**（`> .../led:torch_0/brightness`） | 4 |

最后一个是这个探针最容易被诱惑去做的那次写入，也是静态写保护的假牙。同一个闸门还有三块散文夹具
（一个写着"点亮是一次写入"的 heredoc、本项目散文里的 `-> /sys/...` 箭头、以及一句把 `mount` 当名词的句子），
所以它不会对句子开火——这条规则本身是在写 LMH harness 时收紧的（docs 138 §6）。

---

## 6. 这一轮**不**证明什么

* **不证明通知灯或手电筒"能亮"。** 反过来也不证明它们坏了。空闲手机的灯就是灭的，
  所以 `driven now: nothing` 和"根本驱动不了"是同一个读数。要证明能亮需要**写**（`brightness`，或者 flash 驱动的
  `strobe`），而这个探针不写——**那是一个单独的、要单独评审的步骤**，不是取一次读数的副作用。
* **不证明设备上到底落在哪一级。** 这一轮**一次 ssh 都没有**。91 项全部挡在 stub 目录后面，
  场景是我造的；设备上真实的 class 内容（尤其是 `red`/`green`/`blue` 到底在不在）只有设备回来才知道。
* **不证明属性清单完备。** 它是从三个驱动源码里抄的；一个漏抄的属性会让某个条目显示成"plain LED classdev"
  （会被看见），但不会造成错误的覆盖判断。判断本身只依赖**条目在不在**。
* **不证明通知灯的策略归谁。** 在 Ubuntu Touch 上这个 LED 由谁点亮（Android 的 lights HAL 在容器里，
  还是 UT 这一侧的 repowerd）**不是读一次 sysfs 能回答的**。这一页只说"条目在不在、有没有被驱动绑上"。
* **不证明这 9 个缺口里剩下的没有更重要的。** 只是这两个是手指最先碰到的。

---

## 7. 设备状态与复现

整轮没有动设备：没有写任何分区或 boot，没有跑 QDL/QFIL，没有重启。设备仍在 **Qualcomm EDL**（`05c6:9008`）。
识别目标一律按序列号 **`33e80afe`**；总线上另一台小米 **`4a2fe00b`** 必须忽略。
恢复仍然只能靠**物理长按电源 10–20 秒**。

```sh
# 全部在宿主机上，不碰设备。
bash scripts/host/zl1-leds-probe-selftest.sh                 # 91 项
bash scripts/host/zl1-hardware-inventory.sh --gaps           # 现在一个缺口都不剩了（会印出那句 0 gaps）

# 那九个变异里的一个（点亮手电筒，必须被写保护抓住）：
S=scripts/device/zl1-leds-probe.sh
sed 's#^    cur=\$(rd "\$d/trigger")#    printf 1 > /sys/class/leds/led:torch_0/brightness#' "$S" > /tmp/mut-led.sh
ZL1_LEDS_PROBE_SRC=/tmp/mut-led.sh bash scripts/host/zl1-leds-probe-selftest.sh

# 设备回来之后：它已经在"一次启动"的默认集里（04e），所以这一条就够了：
bash scripts/host/zl1-post-recovery-capture.sh --status
# 或者只跑它一个（只读、不写任何东西）：
scp scripts/device/zl1-leds-probe.sh root@10.15.19.82:/tmp/ && ssh root@10.15.19.82 'sh /tmp/zl1-leds-probe.sh'
```

---

## 8. 缺口清单的现状

| 缺口 | 状态 |
|---|---|
| `thermal-lmh`（硬件限温器） | docs **138** 收口 |
| `torch`（相机手电筒） | 本页收口 |
| `notification-led`（通知/充电灯） | 本页收口 |
| `vibrator`（振动马达） | docs **140** 收口——而且收的过程发现这一行原来的"仪器"是**另一台手机**的芯片 |
| `nfc`、`fm-radio`、`video-codec`、`usb-pd`、`sdcard`、`wfd`、`hdmi`、`eeprom` | 当时是 **8 个没有探针**；其中六个此后被收口（`wfd` 见 [`145`](145-the-count-that-is-a-string.md)，最近两个是**决定它那一行的配置项在它自己那个菜单之外**的 `nfc`（见 [`146`](146-the-config-line-outside-its-own-menu.md)）和**设备树自己把节点关掉**的 `fm-radio`（见 [`147`](147-the-tree-switches-off-the-block-both-kernels-build.md)）），只剩 `eeprom` |

其中 `sdcard` 已经有一条**离线就能读出来**的结论值得先记下：DTB 里有两个 `qcom,sdhci-msm` 控制器，
`sdhc1@7464900` 的 `status = "ok"` 且带 `qcom,nonremovable`（HS400/HS200，不可移除 → 内部存储），
而 `sdhc2@74A4900` 带 `cd-gpios`（卡检测）、是 SD 卡的速度模式（SDR12…SDR104），并且
**`status = "disabled"`**——也就是说，可移除卡槽在设备树里**被关掉了**。
那是**一个属性**的距离，而且它改的是 boot image 里的 DTB，所以它属于"要单独决定"的那一类，
不是运行时的读数。这条留在下一次收口时用。

---

## 9. 文件与改动

| 文件 | 作用 |
|---|---|
| `scripts/device/zl1-leds-probe.sh` | 新：LED 探针（声明 vs 注册、五个阶梯、只读**且不写任何东西**） |
| `scripts/host/zl1-leds-probe-selftest.sh` | 新：**91 项**，真实形状夹具，九个变异 |
| `scripts/host/zl1-post-recovery-capture.sh` | 改：默认集新增 **04e-leds** |
| `scripts/host/zl1-post-recovery-capture-selftest.sh` | 改：146 → **149** 项（加一步必须按名字/顺序/scp 路径/归档文件全部改一遍） |
| `scripts/host/zl1-hardware-inventory.sh` | 改：`torch` 与 `notification-led` 两行从 `-` 变成点名 `scripts/device/zl1-leds-probe.sh`；汇总 20 有仪器 / **9** 无 |
| `scripts/host/zl1-hardware-inventory-selftest.sh` | 改：汇总数字与缺口名单跟着改，并**新增**"这两个块按名字出现在有仪器的一侧"的断言 |
| `scripts/host/zl1-health-check.sh` | 改：新增一段（在 heat fix 之后、0g 之前）把 LED 探针的"比较"读法与 91 项接上；0g 改写为 9 of 29；cli-usage 的引用 144 → **148**（它扫的脚本 49 → 51） |
| `scripts/README.md` | 改：两个新脚本各一行；cli-usage 144 → **148**；capture harness 146 → **149** |
| `docs/ubuntu-touch/137-*.md` | 改：后续注记里 11 → 9 |
| `docs/ubuntu-touch/124-*.md` | 改：家族总数那一行续上本轮（2529 → **2627** / 23 个 harness / 全绿） |
| `README.md` | 改：本页的索引行 |
| `docs/ubuntu-touch/139-*.md` | 本篇 |
