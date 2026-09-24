# 148 — 唯一一个"什么都不缺"的块，靠一个设备树从来不写的名字绑上

**日期**: 2026-09-24
**状态**: 本轮**没有碰设备**（设备仍在 Qualcomm EDL，见 §7）。这是
[`137`](137-a-boot-should-answer-the-question-nobody-asked.md) 那份"没有探针"清单的**第十二次、也是最后一次**收口，收的是
`eeprom`——**清单到此为空**。它是一个**节点**：`/soc/i2c@75b6000/at24@51`（`compatible = "atmel,24c32"`，
`reg = <0x51>`），而它**整块只有两个属性**，设备树**没有** `status`（=打开），项目手上**两颗内核都把这个驱动编进去了**。
所以它是前面十一个的**反例**：别的块各有一个明确的拦路石（一行配置、一行 `status`、一个编不出来的驱动），
**这一块一个都没有**——因此这个探针问的不是"缺了什么"，而是"这条链走到了第几层"。
新工具 `scripts/device/zl1-eeprom-probe.sh`（只读、**一个字节都不写**、**连属性的内容都不读**、**不开任何设备节点**）
与它的 harness **285 项**；它接进了"一次启动"的默认集（新步骤 **04n**）。清单从 **1 个缺口**变成 **0 个**。

**接续**: [`137`](137-a-boot-should-answer-the-question-nobody-asked.md)（缺口的来源）、
[`146`](146-the-config-line-outside-its-own-menu.md) / [`147`](147-the-tree-switches-off-the-block-both-kernels-build.md)（前两次收口），
[`124`](124-the-boot-a-finger-bought-is-one-command.md)（一次启动是一个命令）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 为什么收这个？ | 它是清单上**最后一个**，也是**唯一一个"什么都不缺"**的块——前面十一个各有一个拦路石，这一块没有。**正因如此它才值得单独读**：一块"看起来应该早就能用"的硬件，恰好是"没有一个明确原因"这种诊断最容易出错的地方 |
| 这一块由谁描述？ | **一个节点**：`/soc/i2c@75b6000/at24@51`，在 F R S 三个集合里都在，15 棵 LE_ZL1 树**形状完全相同** |
| 这个节点的全部内容是什么？ | **只有两个属性**：`compatible = "atmel,24c32"` 和 `reg = <0x51>`。**没有 `status`**（设备树把"没有 status"读作**打开**），没有 `read-only`，没有 `pagesize`，没有 gpio、没有中断、没有 supply、没有 pinctrl——**它就是一根两线存储器，驱动别的什么都不需要** |
| 那"驱动没编"呢？ | **不是。`CONFIG_EEPROM_AT24=y` 在项目手上的两颗内核里**——vendor boot image 的 3.18.120 内核**和**这块板正在跑的 v63 Halium 3.18.140 内核，`CONFIG_SYSFS=y` 也都在（Kconfig 里 `config EEPROM_AT24` 是 `depends on I2C && SYSFS`）。**所以这一块没有任何一个"缺件"可找** |
| 那这一块的读数是关于什么的？ | **关于这条链走到了第几层**。三个证人：i2c **客户端**（只需设备树 + 总线，**没有驱动也存在**）< **绑定**（驱动编了、注册了，且 id_table 的名字对得上）< **`eeprom` 这个 sysfs 属性**（probe 跑到最后一句话）。**每一层都比前一层需要更多**，而在这块板上——因为什么都不缺——链条一旦停住，是**停住了**，不是**被拒绝** |
| 那它是怎么绑上的？ | **靠两张表一致，而这次匹配走的是一个设备树从来不写的名字。**`at24_of_match[]` **只有一条**：`{ .compatible = "atmel,24c32" }`；i2c 驱动的 `.name` 是 **`at24`**（所以目录是 `/sys/bus/i2c/drivers/at24`）。但真正跑的是 `at24_probe(client, id)`，`id` 来自 `i2c_match_id(driver->id_table, client)`——而**设备树客户端的名字是兼容串剥掉厂商前缀**（`of_modalias_node`）：`atmel,24c32` → **`24c32`**，它**正是** `at24_ids[]` 里的一条（`{ "24c32", AT24_DEVICE_MAGIC(32768 / 8, AT24_FLAG_ADDR16) }`） |
| 为什么这两张表**不是**二选一？ | 因为 **of_match 决定这个节点能不能匹配上，id_table 决定匹配之后手里拿到的是什么**。`atmel,24c64` 这种兼容串**根本没有 of_match**，连匹配都匹配不上；而一个剥完前缀后**不在** id_table 里的兼容串会**匹配上然后被拒绝**——`if (!id->driver_data) return -ENODEV;` 就在芯片被碰之前。**这块板没有这个问题，但这条路的形状决定了"能不能绑"和"绑上之后是什么芯片"是两个问题** |
| 那"这就是一颗 24c32"是谁说的？ | **是 id_table 说的，不是设备树。**`magic` 解出来是：`byte_len = BIT(magic & 31) = 4096` 字节、`flags = AT24_FLAG_ADDR16`（地址指针 16 位，所以每次访问带两字节偏移）、`num_addresses = DIV_ROUND_UP(4096, 65536) = 1`（**多地址那套机器在这里是空转的**，不会去建 addr+1 的假客户端）、`write_max = min(page_size, io_limit) = min(1, 128) = 1` 字节。**设备树只提供了一个名字，上面每一个数字都是从那张表来的** |
| 第二件要紧的事？ | **设备树的两个属性和驱动的两个属性不相交。**`at24_get_ofdata()` 向树要两样东西：`read-only`（**只测存在与否**，也就是布尔）和 `pagesize`（一格）。**两样都不在这儿** |
| 那这两处缺席有后果吗？ | **都有，而且都能看出来。**没有 `read-only` ⇒ 那个 sysfs 属性被建成**可写**的（mode 从 `S_IRUSR` 起步，因为 `AT24_FLAG_IRUGO` 也没置位）；没有 `pagesize` ⇒ `chip.page_size` 保持 1，**一次写最多 1 字节**（`io_limit` 是 128，取小的那个）。**所以这颗芯片的大小和可写性，设备树里一个字都没有，只出现在内核日志那一行 `dev_info` 里**——这就是日志那一节不是装饰的原因 |
| 那长度规则和上一块（FM）一样吗？ | **正好相反，而这是一个值得单独说的细节。**FM 的电压属性用 `of_property_read_u32_array(..., 2)` 读，也就是**恰好两格**，长了被截断、短了报 -EINVAL；而 `pagesize` 走的是 `of_get_property()`，**只要属性存在就返回一个指针，不管它多长**，然后 `at24_get_ofdata()` **只取第一格**——所以**更长的 `pagesize` 是被截断而不是被拒绝**。唯一真正未定义的是**存在但为空**的那种：`of_get_property()` 对长度为 0 的属性**仍然返回非 NULL**，于是驱动去读四个字节，而那四个字节不在那里。探针把"缺席 / 存在但为空 / 存在且更长"**分成三种读法印出来**，就是因为这三者对驱动是三件不同的事 |
| 这一块"写级别"的动作是什么？ | **读和写是同一个文件**。`at24_probe()` 最后建 **一个** 二进制 sysfs 属性：`sysfs_create_bin_file(&client->dev.kobj, &at24->bin)`，`attr.name = "eeprom"`、`size = chip.byte_len` ⇒ `/sys/bus/i2c/devices/8-0051/eeprom`。**读它**跑 `at24_bin_read()` → `at24_read()` → `i2c_transfer()`；**写它**跑 `at24_bin_write()` → `at24_write()` → `i2c_transfer()`。所以这一块**没有一个可以"安全看一眼"的读面**：**"看一眼 EEPROM"和"覆盖 EEPROM"是同一条路径，只是重定向符不同**，而"想读却写错了"的一个 `>` 就是对芯片的写 |
| 那探针怎么处理？ | **它的声明比"不写"更强：它只读那个属性的存在，一个字都不读它的内容。**它读的是设备目录里的**别的**文件（`name`、`modalias`、driver 那个符号链接），以及驱动目录本身。harness 为此带了**第二道静态闸门**（专门管"读"），有自己的一套牙齿 |
| 还有第二条路到同一颗芯片吗？ | **有，而且在驱动下面一层。**`CONFIG_I2C_CHARDEV=y` 在两颗内核里都有，所以 `i2c-dev` 编了；如果这个总线上存在 `/dev/i2c-N`，用户态程序**可以直接寻址从地址 0x51**，整条 at24 驱动根本不在路径上。探针**印出这个节点在不在**，然后**一个都不打开**——`dd if=… of=/dev/i2c-8` 和 `dd if=… of=/sys/.../eeprom` 是**同一颗从设备的两条路**，两条都被点名拒绝 |
| 那个属性是"身份"还是"拷贝"？ | **是门，不是拷贝。**顶层的 rung 叫 `eeprom-exposed` 而**故意不叫** `*-ready`：它说的是**软件路径到位**（节点打开、客户端在、驱动绑上、属性在），**不是**"里面的数据对"。这份数据是**这块板的校准值或序列号**，唯一的看法就是探针拒绝的那条路——"里面是什么"必须是**有人故意做的决定**，不能是探针的副作用 |
| 那"eeprom"这个词本身有什么陷阱？ | **这个词在这棵树里指三样东西，只有一样是这一块**：清单里这一行的名字叫 `eeprom`；驱动建出来的 sysfs 属性也叫 `eeprom`；而 `drivers/misc/eeprom/eeprom.c` 是**第二个驱动**，`.name` 也是 `eeprom`、属性也叫 `eeprom`——但它**根本没有 `of_match_table`**，所以从设备树**永远匹配不上**，而且它的配置项 `CONFIG_EEPROM_LEGACY` 在**两颗内核里都不是 SET**，所以它**连内核里都不在**。"绑不上"和"不在"是两件事，探针把后者说得更重 |
| 那"grep eeprom"到底会找到什么？ | **可测量的答案：在这块板的树上，它找到 0 个节点。**这个节点的路径是 `at24@51`、兼容串是 `atmel,24c32`，**两个都不含这个词**。而它**真正会落到的**是两个**别的行**里的节点：`/soc/qcom,cci@a0c000/qcom,eeprom@0` 和 `@1`——那是**摄像头的**片上校准存储器，由摄像头栈读、算在**摄像头那一行**里，不归这个驱动。探针把扫描**跑出来印**（连同条数），而不是替读者下结论 |
| 那这一块和 `fm-radio` 在同一个总线上吗？ | **不是，但两条总线挨着，而且这一条上还有另一个块。**`i2c@75b6000` 上只有两个设备：`at24@51`（本块）和 **`nq@28`（`qcom,nq-nci`）**——后者正是 [`146`](146-the-config-line-outside-its-own-menu.md) 那一步收的 NFC 控制器。**所以这条总线出问题，是和一个本工程已经仔细读过的块共享的问题**；只查这一块，分不开两者。总线自己的读数也在报告里：`qcom,clk-freq-out = 400000`（400 kHz）、`qcom,disable-dma` **存在**（所以这个控制器的传输**不走 DMA**）、`pinctrl-names = i2c_active i2c_sleep` |
| 地址 0x51 说明什么？ | **说明它和别的芯片共用这个地址，所以地址不能当身份。**at24.c 自己的注释就举了反例：**`PCF8563` 这颗 RTC 也用 0x51**。不过 `24c32` 在所有描述它的树里都是 `reg = <0x51>`，所以探针把"地址与型号一致"印出来，同时**不把地址当身份** |
| 那探针怎么报？ | 先认板子，再爬阶梯：`tree-unscanned` / `wrong-board-tree` / `unknown-board` / `no-device-tree-node` / `no-driver-for-node` / `no-node-enabled` / `no-client` / `driver-not-built` / `driver-not-registered` / `driver-not-bound` / `no-eeprom-attribute` / **`eeprom-exposed`** |
| 为什么 `no-client` 排在 `driver-not-*` **前面**？ | 和 `nfc`、`fm-radio` 同一条理由：客户端是 i2c 核心按设备树建的，**客户端不存在时任何一行配置都修不了它**，下一步是那个 i2c 控制器（或它的 alias），不是 at24 驱动 |
| 离线验证？ | `scripts/host/zl1-eeprom-probe-selftest.sh`，**285 项**：stub 目录**就是**设备，一级一个场景，**三条根路径**（`/proc/`、`/sys/`、**`/dev/i2c`**——最后一条是因为探针**点名**了它不打开的那条用户态路径），设备树属性按**字节**写，一个"除了 `find(1)` 什么都有"的沙箱，**十三个变异**各让它红 |
| 动设备了吗？ | **没有。** |

---

## 2. 设备树里到底有什么（逐字节读出来的）

15 棵 LE_ZL1 树里这个节点**形状完全相同**，所以"树里有没有 EEPROM"分不出两台手机，只能靠 `model`
（和 inventory 那一整套板卡过滤同一条道理）。它的全部内容：

```
/soc/i2c@75b6000/at24@51
  compatible = "atmel,24c32"       # 字符串，NUL 结尾
  reg        = <0x51>              # 一格 u32，四个大端字节 00 00 00 51
```

**就这两个。**没有 `status`（设备树读作**打开**——这是**普通**情况，和同一个总线上那个 `nq@28` 一样，
也和**上一块 `fm-radio` 恰好相反**）、没有 `read-only`、没有 `pagesize`、没有 gpio、没有 `interrupts`、
没有 supply、没有 `pinctrl-*`。

它的客户端名（如果链走通）**是可以推出来的**：总线的 alias 是 `i2c8`
（`/proc/device-tree/aliases/i2c8 = "/soc/i2c@75b6000"`），地址是 0x51，而 i2c 核心给客户端起的名字是
`%d-%04x`，所以是 **`8-0051`**。**这个推出来的名字是后面"三个证人"那一节要找的东西**，所以它**不是**脚注。

X2 那台手机在 rebuilt 集合里**也有**一个 `at24@51`，挂在 `i2c@757a000` 上——所以**两台手机的树里都有一个
at24 节点**，"树里有没有它"同样分不出板子。

同一棵树里另外三件值得记下来的事：

* **总线本身**：`compatible = "qcom,i2c-msm-v2"`，**没有 `status`**（=打开），`qcom,clk-freq-out = <400000>`，
  `qcom,disable-dma`（布尔，存在），`pinctrl-names = "i2c_active" "i2c_sleep"`。
* **这条总线上的另一个设备**：`nq@28`（`qcom,nq-nci`）——[`146`](146-the-config-line-outside-its-own-menu.md) 收的那一块。
  **它和本块共享这条总线**。
* **两个"同名不同物"的节点**：`/soc/qcom,cci@a0c000/qcom,eeprom@0`（`qcom,eeprom-name = sony_imx298`、
  `qcom,slave-addr = 160`、`qcom,proj-name = zl1`、`status = ok`）和 `@1`（`ov8865_plus`、`reg = <1>`、
  `slave-addr = 0x6c`）。**它们带 `qcom,eeprom`，是这个探针那节"这个词不是这一块"的读数来源。**

---

## 3. 这一块的配置链，以及"什么都不缺"是什么意思

```kconfig
# drivers/misc/eeprom/Kconfig
menu "EEPROM support"
config EEPROM_AT24
	tristate "I2C EEPROMs from most vendors"
	depends on I2C && SYSFS
	...
```

和 `nfc`、`fm-radio` 都不一样——**没有"藏在菜单外"的行，也没有"链断在某一环"**：

| 选项 | 报告里读到的 | 备注 |
|---|---|---|
| `CONFIG_I2C` | `y (built in)` | 第一个父项 |
| `CONFIG_SYSFS` | `y (built in)` | 第二个父项（`depends on I2C && SYSFS`） |
| `CONFIG_EEPROM_AT24` | `y (built in)` | **这一块真正需要的那个** |
| `CONFIG_EEPROM_LEGACY` | `NOT SET` | **旁边那个驱动（`eeprom.c`）的选项**，在车里 | 

`# CONFIG_EEPROM_LEGACY is not set` 在**两颗内核里都是**。所以这块板上"这一项没打开"这个解释
**在车里就找不到**——这也是这个探针的**第一个变异**（把 `CONFIG_EEPROM_AT24` 读成
`CONFIG_EEPROM_LEGACY`）要盯的东西：一个问错选项的探针会在一颗**确实编了这个驱动**的内核上
报"这个内核没编它"，而**同一页的两行读数会互相矛盾**。

**所以这一块和前面十一个的区别是结构性的：**别的块的报告在回答"缺的是哪一个"，
这一块的报告在回答"**这条链走到了第几层**"。

---

## 4. 两个属性对两个属性，而它们不相交

`at24_get_ofdata()` 是全部：

```c
static void at24_get_ofdata(struct i2c_client *client, struct at24_platform_data *chip)
{
	const __be32 *val;
	struct device_node *node = client->dev.of_node;

	if (node) {
		if (of_get_property(node, "read-only", NULL))
			chip->flags |= AT24_FLAG_READONLY;
		val = of_get_property(node, "pagesize", NULL);
		if (val)
			chip->page_size = be32_to_cpup(val);
	}
}
```

两句话，各有一个后果：

| 驱动问的 | 这块板的树 | 后果 |
|---|---|---|
| `read-only`（**只测存在**） | **不在** | 属性建成**可写**（`S_IRUSR \| S_IWUSR`；`AT24_FLAG_IRUGO` 也没置位，所以 mode 从 `S_IRUSR` 起步）——**设备树本来能就这颗芯片的数据说这一件事，而它没说** |
| `pagesize`（第一格） | **不在** | `chip.page_size` 保持 1（`chip.page_size = 1;` 在 `at24_get_ofdata()` **之前**），所以 `write_max = min(1, 128) = 1` 字节 |

**长度这件事，本块和 FM 是反的，值得单独写下来：**

* FM：`of_property_read_u32_array(np, name, vol, 2)` ⇒ **恰好两格**，长了**静默截断**、短了 **-EINVAL**。
* 本块：`of_get_property()` ⇒ **只要属性存在就返回指针，不论多长**，然后**只取第一格**。
  所以更长的 `pagesize` 是**被截断**的，不是被拒绝的。
* 唯一**未定义**的是**存在但为空**：长度为 0 的属性 `of_get_property()` **仍然返回非 NULL**，
  于是驱动去读**四个不在那里的字节**，`chip.page_size` 变成那四个字节——**不是 1**。

探针因此把 `pagesize` 印成**三种**读法（**缺席** / **存在但为空** / **存在且更长，取第一格**），
harness 对三种都有场景和断言。

---

## 5. 三个证人，三层嵌套，以及为什么"属性在"是最强的那个

```
客户端（只需要设备树 + 总线 —— 它存在，即使 at24 驱动一个都没编）
  < 绑定（驱动编了、注册了，而且 id_table 的名字解得出来，probe() 不会 -ENODEV）
    < 属性（probe 跑到了最后一句话）
```

| 证人 | 在这块板上 | 怎么读 |
|---|---|---|
| 1. i2c 客户端 | `/sys/bus/i2c/devices/8-0051` **在** | 它**恰好**在用 alias + `reg` 推出来的那个名字下（不是的话，探针按**地址**再找一遍并说明 alias 有问题） |
| 1b. 客户端的 `name` 文件 | 读出来是 **`24c32`** | **这是"剥掉厂商前缀"那条规则的读数**：不是树里的 `atmel,24c32`，也不是驱动的 `at24`。**三个名字，三个不同的地方** |
| 2. 绑定 | `/sys/bus/i2c/drivers/at24` 在，绑的是 `8-0051` | 驱动目录名是驱动的 `.name`（`at24`），和客户端名不是一回事 |
| 3. `eeprom` 属性 | `/sys/bus/i2c/devices/8-0051/eeprom` **在** | `sysfs_create_bin_file()` 是 `at24_probe()` 里**最后一个会失败**的语句（它后面只剩 `i2c_set_clientdata()`、一句 `dev_info()` 和可选的 `chip.setup()`，都不会失败）——**所以这个文件在，意味着 probe 走到了终点，而不只是"客户端在"** |

**嵌套本身就是读数**：每一层都严格需要前一层。在一块**什么都不缺**的板上，链条停在某一层是
"**停住了**"，而不是"**被拒绝了**"——这个区别决定了下一步该查什么。

顶层 rung 叫 `eeprom-exposed`，**故意不叫** `*-ready`。

---

## 6. 写面：读和写是同一个文件，而第二条路在驱动下面

```sh
# 探针拒绝的两个动作（harness 的静态闸门对这两个都有牙齿）：
dd if=/dev/zero of=/sys/bus/i2c/devices/8-0051/eeprom bs=1 count=1   # 覆盖校准数据
dd if=/dev/zero of=/dev/i2c-8                                       # 同一条从设备的无驱动路径
```

**这一块的特殊之处**：`at24_bin_read` 和 `at24_bin_write` 都走 `i2c_transfer()`，
**读也是一次总线事务**。所以"只是看一眼"在这颗芯片上**不是无害的**，而这个探针的声明因此
**比"不写"更强**：它读那个属性的**存在**，**不读它的内容**。

harness 为这句话带了两道闸门：

1. **写闸门**（所有兄弟 harness 都有）：`>` 重定向进 `/sys`、`/proc`、`/dev`，以及命令位置上的
   `dd` / `tee` / `setprop` / `modprobe` / …；`>/dev/null` 是豁免（这条移植的 shell 是 `/bin/sh`，
   `2>/dev/null` 是唯一的安静写法），heredoc 正文也是豁免（`--explain` 那页是在**说**这些面，不是在**用**它们）。
2. **读闸门（本块独有）**：`cat` / `od` / `head` / `tail` / `dd` / `wc` / `grep` / tr / strings / hexdump
   **接一个指向 `…/eeprom` 的路径**，同样豁免 heredoc。**它故意不拦 `rd`**——那是这棵树自己的读法，
   读设备目录里的 `name` / `modalias` **正是探针该做的事**。

两道闸门各有一条牙齿用例和一个"必须不被误伤"的用例，另外那个 fixture 里写着一行哨兵值
（`CALIBRATION-DATA-DO-NOT-READ`），所以**任何一个场景的报告里出现它，都会被抓到**——不是靠承诺。

---

## 7. 设备状态与复现

整轮没有动设备：没有写任何分区或 boot，没有跑 QDL/QFIL，没有重启。设备仍在 **Qualcomm EDL**（`05c6:9008`）。
识别目标一律按序列号 **`33e80afe`**；总线上另一台小米 **`4a2fe00b`** 必须忽略。
恢复仍然只能靠**物理长按电源 10–20 秒**。

```sh
# 全部在宿主机上，不碰设备。
bash scripts/host/zl1-eeprom-probe-selftest.sh                # 285 项
bash scripts/host/zl1-hardware-inventory.sh --gaps            # 现在一个缺口都不剩（印出 "29 of 29 rows, 0 gaps"）

# 本块最核心的那个变异（把旁边那个驱动的选项当成这一块的选项，必须红）：
S=scripts/device/zl1-eeprom-probe.sh
sed 's/^N_BUILT=$(cfg_opt CONFIG_EEPROM_AT24)$/N_BUILT=$(cfg_opt CONFIG_EEPROM_LEGACY)/' "$S" > /tmp/mut.sh

# 设备回来之后（只读、不写任何东西、不读属性的内容、不打开任何设备节点；或直接跑 capture，它已经把 04n 放进默认集）：
scp scripts/device/zl1-eeprom-probe.sh root@$IP:/tmp/ && ssh root@$IP 'sh /tmp/zl1-eeprom-probe.sh'

# 它会先回答"这棵树是不是这块板"，再回答节点在不在、有没有 status、树的两个属性与驱动的两个属性各是什么样、
# 两张表怎么一致、配置链的四行各是什么、客户端/绑定/属性三层证人到了哪一层、总线上的另一个设备是谁、
# 以及内核日志里那一行 dev_info 到底说了什么。
```

---

## 8. 这一轮**不**证明什么

* **不证明这颗芯片里的数据是对的、或者是什么。** 探针读的是那个属性的**存在**，
  **一个字都没读它的内容**——而且这是**故意的**，因为读它在这颗芯片上是一次真实的总线事务，
  而写它是同一条路径。**"里面是什么"需要一个有人故意做的决定。**
* **不证明这一块"能用"。** 顶层 rung `eeprom-exposed` 说的是**软件路径到位**，
  不是任何形式的校验、也不是"数据完整"。**它在设备上有没有真的跑过，这一轮同样没证明**——
  一次 ssh 都没有。
* **不证明 `/dev/i2c-8` 存在。** 探针**印出**它看到的 `/dev/i2c-*`，然后**一个都不打开**；
  在没有设备树的假根里，这个问题的答案是"没读"。**"配置里 `CONFIG_I2C_CHARDEV=y`"
  和"设备上真有这个节点"是两件事**，探针把两者印成相邻的两行。
* **不证明这一块和摄像头的 `qcom,eeprom` 节点无关。** 只证明**它们不是同一个驱动读的**、
  在这个仓库里算**两行**。摄像头那一行自己的探针是另一个。
* **不证明 15 棵树以外还有没有别的树。** 读的还是那三套（stock / rebuilt / filtered）。
* **不证明清单不会再有缺口。** 它证明的是**今天这份 token 集合下**没有。一个**写错的** token
  会让有探针的块显示成缺口（会被看见），而一个**太宽**的 token 会让缺口显示成有探针——
  [`137`](137-a-boot-should-answer-the-question-nobody-asked.md) §4 记的那三次错全是这个方向。
  **这一轮在汇总行上补了一道防线**：清单为空时它**不再只是"不印缺口那一节"**，
  而是明说一句 `29 of 29 rows, 0 gaps`——因为**一份印不出缺口的报告和一份没有缺口的报告，
  读起来是完全一样的**。

---

## 9. 文件与改动

| 文件 | 改动 |
|---|---|
| `scripts/device/zl1-eeprom-probe.sh` | **新增**：只读探针，12 级阶梯，顶层 rung `eeprom-exposed` |
| `scripts/host/zl1-eeprom-probe-selftest.sh` | **新增**：285 项，三根路径改写，13 个变异，两道闸门 |
| `scripts/host/zl1-hardware-inventory.sh` | `eeprom` 行获得仪器；**汇总 28/1 → 29/0**；清单为空时**明说一句** 0 gaps |
| `scripts/host/zl1-hardware-inventory-selftest.sh` | 断言改成"29 of 29、0 gaps"和那句空清单的话；114 → **118** 项 |
| `scripts/host/zl1-post-recovery-capture.sh` | 新步骤 **`04n-eeprom`**（默认集，只读），并把提示句里的"十二个"改成"十三个" |
| `scripts/host/zl1-post-recovery-capture-selftest.sh` | 18 步 / 16 次推送 / 19 个归档；173 → **176** 项 |
| `scripts/host/zl1-health-check.sh` | 新条目 **5i. EEPROM**；0g 那句话改成"29 of 29、0 with none"；多处引用数字跟着改 |
| `scripts/README.md` | 新两行（探针与 harness），capture / inventory / cli-usage 的计数与脚本数一并改 |
| `README.md` | 索引新增本页 |
| `docs/ubuntu-touch/137` / `139` / `124` | 缺口清单 → **0 个**；汇总 29 / 0；家族总数链条接上本轮 |
| `docs/ubuntu-touch/148-…` | 本页 |

家族：**32 个 harness / 4430 检查 / 全绿**，仓库自指纹未变。
