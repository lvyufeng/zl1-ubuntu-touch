# 143 — 端口那六个节点：设备树打开的两个，内核一个驱动都没有

**日期**: 2026-09-24
**状态**: 本轮**没有碰设备**（设备仍在 Qualcomm EDL，见 §7）。这是 [`137`](137-a-boot-should-answer-the-question-nobody-asked.md)
那份"没有探针"清单的第七次收口，收的是 `usb-pd`——它同样**不是一个设备**，而是**一台菜单**：两条 i2c 总线上的四颗 CC-logic 芯片，
加上两个厂商的 `letv,*_driver` 平台节点，这块板上一共**六个**。
新工具 `scripts/device/zl1-usbpd-probe.sh`（只读、**一个字节都不写**、**什么都不打开**）与它的 harness **130 项**；
它接进了"一次启动"的默认集（新步骤 **04i**，与 04b–04h 同一类：只读、不写、不需要人在场）。
清单从 **6 个缺口**变成 **5 个**；本页同时改掉 [`137`](137-a-boot-should-answer-the-question-nobody-asked.md) §3.2 里把**另一台手机**的 CC-logic
当成这台手机的一处错误。

**接续**: [`137`](137-a-boot-should-answer-the-question-nobody-asked.md)（缺口的来源）、
[`142`](142-the-removable-slot-is-switched-off-in-the-tree.md)（前一次收口——存储控制器的两个半边）、
[`140`](140-the-block-that-was-another-phones.md)（同一类错误的第一次：那一行点名的仪器属于另一台手机）、
[`124`](124-the-boot-a-finger-bought-is-one-command.md)（一次启动是一个命令）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 为什么收这个？ | 它排在剩下五个缺口里，但**它是清单上唯一一个"设备树打开了、内核却没编"的块**——这个形状之前没被量过 |
| 这个块为什么不是一个设备？ | 设备树里有**六个**候选节点：i2c@75b5000 上的 `tusb320@67`、`cclogic_dev@3d`，i2c@757a000 上的 `pi5usb@1d`、`tusb302l@47`，加上 `/soc/pi5usb_driver` 和 `/soc/tusb302l_driver` 两个平台节点（没有 `reg`，不是 i2c 设备） |
| **最要紧的那条读数** | **设备树打开的两个，内核一个驱动都没编。** 15 棵 ZL1 树里 `tusb320@67` 和 `cclogic_dev@3d` 都是 `status = ok`；而刷进去那颗内核的 config 里 `# CONFIG_USB_CCLOGIC_TUSB320 is not set`，`cclogic_dev` 只被 `ptn5150.c` 和 `pericom_i2c_30216c_v1.c` 认领、**两个都关着**——**它编出来的那两个驱动（`_PI5USB`、`_TUSB302L`）恰恰属于设备树关掉的那四个节点** |
| 那这是故障吗？ | **不是。** 这是**设备树与内核 config 之间的构建期分歧**，不是运行时故障。两个 enabled 节点照样拿到 i2c client，只是没有任何东西能绑上去。修它只需要**一行 config**，而那一行意味着**重新构建 boot image**——单独的、要单独评审的一步 |
| 为什么这条读数会让整个块值得一个探针？ | 因为 **`cc_state` 的 `none` 是有歧义的**。hub（`cclogic.c`，一个 `subsys_initcall`）建出 `/sys/class/typec/typec_device/`，而**只有芯片驱动会写它**；它初值是 0，打印出来是 `none`——**而 `none` 也正好是"什么都没插"的正确值**。所以探针在让人相信这个值之前，先**点出写它的人是谁**：没有驱动绑上时，`none` 是 hub **被创建时**的值，USB 角色、CC 极性、充电器识不认出来**不是"没读到"，是"未被决定"** |
| 怎么才能让它活？ | 一行 `CONFIG_USB_CCLOGIC_TUSB320=y`（树那边早就打开了）→ boot image 构建。**不是取一次读数的副作用** |
| 那探针怎么报？ | 先报板子，再爬阶梯：`tree-unscanned` / `wrong-board-tree` / `unknown-board` / `no-device-tree-node` / `no-node-enabled` / `driver-not-built` / `driver-not-bound` / `no-hub` / `port-reported` |
| 它写东西吗？ | **一个字节都不写，而且什么都不打开。** 这块唯一个看着可写的旋钮是 `cclogic_typec_headset_with_analog`（mode **0664**）——但 `module_param_call` 的 **setter 是 NULL**，`kernel/params.c` 的 `param_attr_store()` 直接返回 **-EPERM**；而 `tusb320.c` 注册的 misc 设备 `/dev/tusb320` 有自己的 fops，**打开它本身就是写级别的动作** |
| 顺带改了什么？ | [`137`](137-a-boot-should-answer-the-question-nobody-asked.md) §3.2 把 `cypress,cyccg` 和 `analogix,ohio` 列成这台手机的 USB-C CC logic——那两个节点在 **LE_X2 的 23 棵树**里，**这台手机的 15 棵里一个都没有**。同一个缺陷 [`140`](140-the-block-that-was-another-phones.md) 在 `vibrator` 那一行已经修过一次，这是隔壁一行 |
| 离线验证？ | `scripts/host/zl1-usbpd-probe-selftest.sh`，**130 项**：stub 目录**就是**设备，一级一个场景，**三条根路径**（`/proc/`、`/sys/`、`/dev/tusb`）的改写，设备树属性按**字节**写（u32 是四个大端字节），一个"除了 `find(1)` 什么都有"的沙箱，八个变异各让它红 |
| 动设备了吗？ | **没有。** |

---

## 2. 设备树里到底有什么（逐字节读出来的，不是猜的）

```
/soc/i2c@75b5000/tusb320@67            status = ok          ← 15 棵 ZL1 树全都如此
    compatible = tusb320               reg = 0x67
    interrupt-parent -> phandle 28     interrupts = <73 2>
    irq-gpio = <&tlmm 73>              （两格：只有号码，没有极性标志格）
    cc1_pwr_gpio = <&tlmm 60>          cc2_pwr_gpio = <&tlmm 61>
    switch_gpio1 = <&tlmm 58>          switch_gpio2 = <&tlmm 59>
    pinctrl-names = m0_ccswitch_active m0_ccint_active m0_ccpwr_active
    pinctrl-0/1/2 = 258 259 260

/soc/i2c@75b5000/cclogic_dev@3d        status = ok
    …… 上面**每一个字节都相同**，只有 reg 不一样：reg = 0x3d

/soc/i2c@757a000/pi5usb@1d             status = disabled
    compatible = pi5usb                reg = 0x1d
    interrupt-parent -> phandle 28     interrupts = <73 2>      irq-gpio = <&tlmm 73>
    qcom,id-gpio = <&tlmm 132 0>       （三格：phandle、gpio、极性标志 0）
    pinctrl-names = pi5usb_active

/soc/i2c@757a000/tusb302l@47           status = disabled
    compatible = tusb302l              reg = 0x47
    …… 同上，pinctrl-names = tusb302l_active

/soc/pi5usb_driver                     compatible = letv,pi5usb_driver      status = disabled   （没有 reg）
/soc/tusb302l_driver                   compatible = letv,tusb302l_driver    status = disabled   （没有 reg）
```

四条值得单独写下来的读数：

* **两个 enabled 节点的属性集几乎逐字节相同**（只有 `reg` 不同）。也就是说这块板上的两行是**同一个模板抄了两遍**——
  同一个中断、同一组 gpio、同一串 pinctrl 状态名。夹具也照着这个抄，因为**如果夹具自己编了不同的数字，"两个节点其实是同一个模板"这条读数就被藏掉了**。
* **四个 i2c 节点共用同一条中断**（`interrupts = <73 2>`，parent 是 phandle 28），`irq-gpio` 也都是同一个 73 号脚。
  所以探针把每个节点的中断分别印出来，而不是只印一次。
* **gpio 属性的格数不一样，而且格数不是可有可无的**：`irq-gpio` 是**两格**（`<&tlmm 73>`，没有极性格），
  `qcom,id-gpio` 是**三格**（`<&tlmm 132 0>`，有极性格）。把两格的当成三格读、或者反过来，都会得到一个**形状对、意思错**的结果，
  所以探针把"没有极性格"也印出来，而不是当作缺了数据；长度不是四的整数倍的属性报 `not-a-gpio(N bytes)`，
  而不是把四个字节里的前三个读成一个数——那是"形状对、意思错"的另一种写法。
* **`pinctrl-names` 是驱动按名字查的东西**：`tusb320.c` 会去找 `m0_ccint_active`，找不到就 probe 失败。
  所以一个 `status = ok` 的节点也可能**因为少了一个名字而绑不上**——这也是探针把名字整串印出来的原因。

---

## 3. 真正的问题：设备树打开的，内核没编；设备树关掉的，内核编了

从**刷进去那颗内核自己的 config**（用 IKCONFIG 从 `kernel-v63` 里抽出来的）读：

```
CONFIG_USB_CCLOGIC=y                  ← hub，也就是 cclogic.c（建 /sys/class/typec/）
CONFIG_USB_CCLOGIC_PI5USB=y           ← 设备树**关掉**的节点（pi5usb@1d）的驱动
CONFIG_USB_CCLOGIC_TUSB302L=y         ← 设备树**关掉**的节点（tusb302l@47）的驱动
# CONFIG_USB_CCLOGIC_TUSB320 is not set   ← 设备树**打开**的节点（tusb320@67）的驱动
# CONFIG_USB_CCLOGIC_PTN5150 is not set   ← cclogic_dev 的两个候选之一
# CONFIG_USB_CCLOGIC_PER30216 is not set  ← cclogic_dev 的另一个候选
```

而 `cclogic_dev` 这个 compatible 在整个内核里**只有两个驱动认领它**（`ptn5150.c` 的 of_match 和 `pericom_i2c_30216c_v1.c` 的 of_match），
**两个都没编**。所以：

```
设备树打开了 2 个节点  →  i2c 核心给它们各建一个 client  →  没有任何驱动能绑上去
设备树关掉了 4 个节点  →  for_each_available_child_of_node() 根本不为它们建 client  →  它们的驱动倒是编好了
```

这不是板子上的故障，是**构建期的分歧**。探针把这条分歧印成一句话（"BUILD-TIME disagreement between the device tree and the
kernel config"），并把它的代价说明白：修它要一行 config，也就是一次 boot image 构建。

### 3.1 "驱动匹配"不总是靠 compatible（这是本页第二条容易错的读数）

内核这颗 `i2c_device_match()` 的顺序是：驱动的 `of_device_id` 表 → ACPI → **如果驱动有 `id_table`，就拿 client 的 `NAME` 去比**。
而设备树 client 的 `NAME` 是 `of_modalias_node()` 算出来的 **modalias**：compatible 里**逗号后面那一段**（去厂商前缀）。于是：

| 节点 | 它的 compatible | 驱动的 of_match | 谁会绑它 |
|---|---|---|---|
| `pi5usb@1d` | `pi5usb`（**光秃秃的**） | `fairchild,pi5usb` | **`id_table` 里的名字 `pi5usb`**——of_match 对不上这个节点 |
| `tusb302l@47` | `tusb302l` | `tusb302l` | of_match |
| `tusb320@67` | `tusb320` | `tusb320` | of_match |
| `cclogic_dev@3d` | `cclogic_dev` | `cclogic_dev`（ptn5150 / pericom 各一份） | of_match |
| `letv,pi5usb_driver` | `letv,pi5usb_driver` | 平台驱动的 of_match 同名 | 平台总线 |

所以"这个 compatible 没有驱动"是一句**可能错**的话，而"它的 of_match 对不上"和"没有任何东西能绑它"是两件不同的事。
探针把**匹配方式**和驱动名一起印，`pi5usb` 那一行会明说"by the id_table NAME"，并且把 of_match 是 `fairchild,pi5usb、
这个节点并没有带**这一点写出来。i2c client 的过滤也按**两种拼法**都认——因为 client 的名字是 modalias，
`cypress,cyccg` 建出来的 client 叫 `cyccg`，只认 compatible 的过滤器会在 client 就在眼前时报"这个块没有 client"。

---

## 4. 探针：先认板子，再爬阶梯

`scripts/device/zl1-usbpd-probe.sh`，`/bin/sh`，**只读、不写任何东西**（连临时文件都不写，内核日志收进 shell 变量），**什么设备都不打开**。

```
tree-unscanned          没有 find(1) 且没有已知节点形状   -> "没法看"不是"不在"
wrong-board-tree        /proc/device-tree/model 是 X2 的  -> 而且这台手机的 15 棵树根本没有 X2 那三个 CC-logic 节点
unknown-board           model 两个都不认 / 读不出来
no-device-tree-node     树里没有本块的任何 compatible     -> 驱动没有可绑的东西
no-node-enabled         每个节点的 status 都不是 okay     -> 设备树自己决定不要端口控制器
driver-not-built        enabled 了，但**没有任何能绑它的驱动注册过**  -> 本节这条：构建期分歧
driver-not-bound        驱动注册了、却没设备绑上去        -> probe 没跑成，日志那节说为什么
no-hub                  绑定成功了，但 /sys/class/typec/ 不在  -> CONFIG_USB_CCLOGIC 没编：驱动在驱动一个没有地方汇报的端口
port-reported           绑定成功 + hub 在                 -> cc_state 这时候才是**读数**
```

读数按源码取：节点印 `compatible`、`status`、`reg`（**十进制和十六进制都印**——0x67 读成 103 是同一个事实的两种单位）、
中断和解析过的 `interrupt-parent`、每个 gpio 的 phandle/gpio/极性、`pinctrl-names`；驱动那节印每个候选驱动的
`registered` / `bound` / **config 那一行**，以及**匹配方式**；hub 那节印 `cc_state` / `cc_polarity` / `supported_dev`
和"绑定成功才会出现的那些 surface"（`/sys/class/misc/tusb320` 等）的**缺席**；日志那节只找本块的失败串。
长度不是 4 的属性报 `not-a-u32(N bytes)`；两个节点带同一个 phandle 报 `AMBIGUOUS(n)` 而**不挑一个**；
一个节点同时带 `phandle` 和 `linux,phandle`（本板 pinctrl 两个都有）**只算一个节点**——
第一版按匹配次数算，于是把同一个控制器报成了"自己和自己有歧义"。

`--quiet` 保留 verdict 和它赖以成立的那几条读数（每个节点的 `status`、驱动行、hub、总结），丢掉逐节点的细节。

---

## 5. 最要紧的一条：`cc_state: none` 不是读数，是**一个还没有人写过的初值**

hub 是 `cclogic.c` 里的一个 `subsys_initcall`：它建出 `/sys/class/typec/typec_device/`，挂上
`cc_state`、`cc_polarity`、`supported_dev` 三个只读属性，**然后就不管了**。写它的只有芯片驱动
（`tusb320.c` / `ptn5150.c` / `pericom_i2c_30216c_v1.c` / `cyccg.c` / `anx_ohio_driver.c`），
每一个都通过 `cclogic_updata_port_state()` 写。它的初值是 0，而

```c
char *typec_port_state_string[] = {"none", "ufp", "dfp", "audio", "debug"};
char *typec_port_polarity_string[] = {"none", "cc1", "cc2"};
```

所以 0 印出来是 **`none`**——**而 `none` 同时是"什么都没插"的正确值**。这就是本页最值得记下来的一件事：

| 情况 | 读数 |
|---|---|
| 端口空着，驱动在 | `cc_state: none`（**这是读数**） |
| 驱动根本没绑上 | `cc_state: none`（**这是 hub 被创建时的初值**） |

**两者在这一代内核里不可区分**，除非你说出**写它的人是谁**。所以探针在打印这个值的同时点出 writer，
并且在没有任何 writer 绑上时**单独印一段**：

```
   NOTHING CAN WRITE 'cc_state' ON THIS BOOT. The tree enables 2 node(s) and this kernel has
   no registered driver for either, and every writer of cc_state is a CC-logic chip driver -- so
   the 'none' above is the value the hub was CREATED with, not a report that the port is idle.
   What that costs: the USB role, the CC polarity and whether a charger is recognised are decided
   by a chip nothing is driving. They are not merely unread on this boot; they are UNDECIDED.
```

这段**必须单独印**，因为不印它的话，"端口空着"和"没人能告诉你"看起来一模一样。这也是 harness 里
第六个变异要保的东西：把这段话静音，`none` 就退化成了一条"看起来像读数的初值"。
（`supported_dev` 是另一半：它只有在插着一个乐视 USB 音频设备时才是非 0，所以它**是**关于"现在插着什么"的读数。）

---

## 6. 为什么这个探针的写守卫值得单独评审

这块的可写面很小，但**最容易想到的那一句**正好是这个项目不做的那类动作：

```
/sys/module/cclogic/parameters/cclogic_typec_headset_with_analog   0664   ← 看着可写
    module_param_call(cclogic_typec_headset_with_analog, NULL, getter, ..., 0664)
    kernel/params.c 的 param_attr_store(): if (!attribute->param->ops->set) return -EPERM;
    → setter 是 NULL，所以**写它会被拒绝**。看着可写，而且是白写。
/dev/tusb320    tusb320.c 注册的 misc 设备，有自己的 fops  →  **打开它就是写级别的动作**
```

所以探针**既不写那个参数、也不打开那个设备**，并且在报告里明说。harness 的第一条变异就是往里塞一句
`printf 1 > /sys/module/cclogic/parameters/cclogic_typec_headset_with_analog`——"端口探针"最容易被诱惑写下去的那一句。

---

## 7. 设备状态与复现

整轮没有动设备：没有写任何分区或 boot，没有跑 QDL/QFIL，没有重启。设备仍在 **Qualcomm EDL**（`05c6:9008`）。
识别目标一律按序列号 **`33e80afe`**；总线上另一台小米 **`4a2fe00b`** 必须忽略。恢复仍然只能靠**物理长按电源 10–20 秒**。

```sh
# 全部在宿主机上，不碰设备。
bash scripts/host/zl1-hardware-inventory.sh --block usb-pd    # 6 个节点，现在有仪器了
bash scripts/host/zl1-hardware-inventory.sh --gaps            # 现在只剩 5 个缺口
bash scripts/host/zl1-usbpd-probe-selftest.sh                 # 128 项

# 那条最要紧的变异（写那个看着可写的参数，必须红）：
P=scripts/device/zl1-usbpd-probe.sh
sed 's#^  CFG=\$(cfg_opt "\$DC")#  printf 1 > /sys/module/cclogic/parameters/cclogic_typec_headset_with_analog; CFG=$(cfg_opt "$DC")#' "$P" > /tmp/mut-param.sh
ZL1_USBPD_PROBE_SRC=/tmp/mut-param.sh bash scripts/host/zl1-usbpd-probe-selftest.sh

# 设备回来之后（只读、不写任何东西、不打开任何设备；或直接跑 capture，它已经把 04i 放进默认集）：
scp scripts/device/zl1-usbpd-probe.sh root@10.15.19.82:/tmp/ && ssh root@10.15.19.82 'sh /tmp/zl1-usbpd-probe.sh'
# 它会先回答"这棵树是不是这块板"，再回答两个 enabled 节点各自有没有驱动、cc_state 有没有 writer。
```

---

## 8. 这一轮**不**证明什么

* **不证明 USB-C 端口能用，也不证明不能用。** 恰恰相反：它证明的是**这个问题在这一次启动里不成立**——
  决定 USB 角色和 CC 极性的那颗芯片没有人驱动，所以这一层是**未被决定**，而不是"读到了但是坏的"。
* **不证明写那个 module parameter 会发生什么。** 源码说 setter 是 NULL、写会返回 `-EPERM`——
  但"会被拒绝"是一句关于**这颗内核这一段代码**的话，不是关于"写它是安全的"。
* **不证明 `cclogic_dev` 到底是哪颗芯片。** 树上有两个驱动候选（ptn5150 和 pericom 30216c），
  两者**都没编**，所以哪一颗真的焊在上面**这一次启动里无法回答**——它需要一次 config 改动，或者一块表。
* **不证明设备上落在哪一级。** 这一轮**一次 ssh 都没有**：130 项全部挡在 stub 目录后面，场景是我造的。
  设备上真实的那一级（尤其是两个 enabled 节点有没有 client、`cc_state` 是什么）只有设备回来才知道。
* **不证明 `driver-not-built` 是这块板唯一的问题。** 它只说明：**设备树打开的两个节点，在这颗内核里没有驱动**——
  这是从设备树和内核 config 里读出来的，与板子上的焊接无关。
* **不证明剩下 5 个缺口里没有更重要的。** 只是这个块问的问题最容易被一次读数答错，而"答错"是可以量的。

---

## 9. 文件与改动

| 文件 | 作用 |
|---|---|
| `scripts/device/zl1-usbpd-probe.sh` | 新：USB Type-C / CC-logic 探针（六个节点、设备树打开的两个、内核一个都没编、`cc_state` 的 writer、config 与 sysfs 两个独立的答案、gpio 的 phandle 解析、驱动**匹配方式**），**board-first**，九级阶梯，只读**且不写任何东西、不打开任何设备** |
| `scripts/host/zl1-usbpd-probe-selftest.sh` | 新：**130 项**，stub 目录就是设备，**三条根路径**改写（含 `/dev/tusb`），设备树属性按字节写，一个"除了 `find(1)` 什么都有"的沙箱，八个变异 |
| `scripts/host/zl1-hardware-inventory.sh` | 改：`usb-pd` 行点名仪器，并补上 `cclogic_dev`（这一行原来的 pattern **漏了树打开的两个节点里的第二个**，所以计数从 5 变成 **6**）；汇总 23/6 → **24/5** |
| `scripts/host/zl1-hardware-inventory-selftest.sh` | 改：汇总数字改成 24/5；`usb-pd` 从缺口循环移到"已覆盖、按名字与节点数断言"那一组；**并修掉一处本文件自带的缺陷**——上一轮那行断言结尾写成了 `\\`（两个反斜杠互相转义、**不是**续行），于是断言带着 `\` 这个 label 通过、下一行被当命令执行（`command not found`），两者都不红 |
| `scripts/host/zl1-post-recovery-capture.sh` | 改：默认集新增 **04i-usbpd**（只读、不写、不需要人在场、不打开设备） |
| `scripts/host/zl1-post-recovery-capture-selftest.sh` | 改：158 → **161** 项（加一步要按名字/顺序/scp 路径/归档文件/步骤数与 push 数全部改一遍：12 步/10 push/13 归档 → **13 步/11 push/14 归档**） |
| `scripts/host/zl1-health-check.sh` | 改：新增一段（在 sdcard 之后）把"设备树打开的两个 / 内核一个都没编 / `cc_state` 的 writer / §3.2 那处更正"与 128 项接上；设备清单新增 **5d. USB-C / CC-logic**；0g 改写为 **5 of 29**；cli-usage 引用 160 → **164**（它扫的脚本 57 → 59）；capture harness 引用 158 → **161** |
| `scripts/README.md` | 改：两个新脚本各一行；cli-usage 引用 160 → **164**（覆盖 72 → 74 个脚本）；capture 两行 158 → **161**、步骤 12/10/13 → 13/11/14；capture 那一行补上 04i |
| `docs/ubuntu-touch/137-*.md` | 改：后续注记 6 → **5**，§3.2 更正（`cypress,cyccg` / `analogix,ohio` 是 LE_X2 的，不是这台手机的） |
| `docs/ubuntu-touch/139-*.md` | 改：后续注记 6 → **5** |
| `docs/ubuntu-touch/124-*.md` | 改：家族总数那一行续上本轮 |
| `README.md` | 改：本页的索引行 |
| `docs/ubuntu-touch/143-*.md` | 本篇 |
