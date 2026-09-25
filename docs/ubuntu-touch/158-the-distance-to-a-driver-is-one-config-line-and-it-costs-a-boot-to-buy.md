# 158 — 指纹离"有一个驱动"还差多远：**一条配置线**，而这条线要用一次刷 boot 去买

**日期**: 2026-09-25
**状态**: 本轮**没有碰设备**。这一页把 [`157`](157-the-answer-is-at-the-kernel-layer-and-it-is-opposite-for-the-two-blocks.md)
给出的那句"修法是让内核包含那个驱动"**变成一份可以量的计划**：从"这个选项是关的"到"这个驱动绑上并建出
`/dev/goodix_fp`"之间**每一个环节**到底还缺什么，全部**离线**量完。

**接续**: [`157`](157-the-answer-is-at-the-kernel-layer-and-it-is-opposite-for-the-two-blocks.md)（它给出的判定是这一轮的起点：
`# CONFIG_INPUT_GP5XX8 is not set`）、[`153`](153-the-premise-was-false-and-the-answer-was-on-this-laptop.md)（**编译出正在跑的镜像的那份源码就在这台笔记本上**——
这一轮整条链读的就是它）、[`152`](152-a-reading-is-only-as-good-as-the-identity-of-its-input.md)（读数要带着它输入的身份，
所以这一轮的判定把每个文件的 sha256 一起印出来）、[`126`](126-*.md)（存目录：驱动**以上**那一层）、
[`124`](124-the-boot-a-finger-bought-is-one-command.md)（一次开机是一条命令）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 这一轮问的是什么？ | docs 157 说"修法是让内核包含那个驱动"，而那是一次**重新编译 + 刷 boot**。**在此之前，这条链上还缺什么？** |
| 为什么值得先量？ | 因为 boot 镜像是这个工程**最贵**的东西：它**一次上电按压**、它是**已经让设备进过 EDL 的那一步**，而这个工程的规矩是"备份和撤销都写清楚了才刷"。**一句"让内核包含那个驱动"不是计划**（docs 157 §1 末行）。 |
| 量出来是什么？ | **`one-config-line-away`**：链上**每一个环节都在**，只差**配置里那一行**。 |
| 环节一：选项？ | `drivers/input/goodixfp/Kconfig:4` 有 `config INPUT_GP5XX8`，`depends on INPUT`，而**编译用的那份 `.config`** 里 `CONFIG_INPUT=y`——**依赖是满足的**。 |
| 环节二：源码？ | 就在树里。模块名 `gf`，`$(MODULE_NAME)-objs := gf_spi.o platform.o`（**两个**目标文件），
总线分支是 `USE_SPI_BUS`（所以是 `spi_driver`，探针要读 `/sys/bus/spi/drivers/<name>`），`of_match_table` 恰好是 `goodix,fingerprint`。 |
| 环节三：设备树节点？ | **5 of 5**：这次构建产出的**五棵** `LE_ZL1` 树，**每一棵**都带着那个节点、**每一个**驱动要的属性都在，而且它们的 SPI 控制器**没有 `status`**（设备树里"没有这个属性"就是**启用**）。 |
| 环节三（续）：镜像里那五棵呢？ | 挂在 boot 镜像上的**五棵**树，**逐字节等于**构建产出的那五棵（按 sha256 认，不是按大小猜）。 |
| 环节四：编得出来吗？ | **编得出来**：两个 `.c` 用**这次构建自己记录的编译命令行**（kbuild 留在旁边的 `.cmd`）编过，`rc=0`；`ld -r` 之后 **51 个未定义符号全部**在内核自己编出的 `vmlinux`（148492 个已定义符号）里找到。 |
| 所以结论是什么？ | **软件路径只差一行。**这也是这个判定器**唯一**声称的东西。 |
| 它对传感器说了什么？ | **什么都没说。**判定自己印出这一段：存目录（docs 126）、信任库、TZ 应用、传感器本身都在这一行的**上面或下面**，指纹在设备侧判定跑过之前仍然是"只在离线量过"。 |
| 这一轮加了几项检查？ | 新 harness **122 项**（`pass=122 fail=0`）；两个记数页同步；家族全量跑见 §9。 |
| 动设备了吗？ | **没有。**设备仍在 **fastboot**（`33e80afe`，`18d1:d00d`），本轮没有一条会改变设备状态的命令。 |

---

## 2. 四个环节，每一环读的都是**这次构建自己的东西**

这一轮的立场是一句话：**关于一个内核的事实，不要从笔记本上的一个文件去问。**defconfig 可能被人改过、
驱动可能编不过、设备树可能不是镜像里那一棵。所以四个环节各自读的输入是：

| 环节 | 读的是什么 | 为什么不是别的 |
|---|---|---|
| 选项 | **编译用的那份 `.config`**（`$OBJ/.config`），依赖逐个在**它**里面求值 | 只读 defconfig 的仪器回答的是**一个文件**，不是**一个内核**；两台不同的解释都印在同一份输出里，谁对一眼可见 |
| 源码 | 树里的四个文件（`gf_spi.c`、`platform.c`、`Kconfig`、`Makefile`）+ 父目录 `Makefile` 的那一行 | 四个名字（选项、文件、驱动 `.name`、compatible）**没有一个相同**（docs 157 §5），所以只能逐个读出来，不能推 |
| 节点 | **构建产出的** `.dtb`（按每棵树自己的 `model` 认这块板） | 两台手机的树在同一个 blob 里、根 `compatible` 逐字节相同（docs 140），**只有 `model` 分得开** |
| 镜像 | boot 镜像里**附着**的那五棵，逐棵与构建产出按 sha256 配 | "构建产出的树有那个节点"和"手机将要启动的那棵树有那个节点"是**两件事**，后者才是会跑的 |

**而驱动要哪些属性，是从驱动自己的源码里读出来的**：每一个 `of_get_named_gpio()` 和一个 `regulator_get()`
（后者解析的是 `<名字>-supply`）。读出来是三个：

```
required by the driver:gfvdda-supply goodix,gpio_irq goodix,gpio_reset
```

**`goodix,gpio_pwr` 不在里面，而这不是省略**：它写在 `platform.c` 的一个 `#if 0` 里（那一段是死代码）。
一个把预处理器状态当成不存在、直接 `grep` 的读数会把它算成"必需"，于是**这块板上没有一棵树满足它**，
判定就会打印 `node-missing-or-incomplete`——**关于一棵完全没问题的树的假红**。所以那段死区是被**复现**出来的
（`#if 0` 开、内部的 `#if`/`#ifdef` 嵌套、`#endif` 关），而且 `gf_spi.c`（897 行 / **887 行活的**）和
`platform.c`（179 行 / **158 行活的**）用**同一个**读取器，两个文件不可能给出不一致的答案。

---

## 3. 为什么这条链的证据在这台笔记本上：kbuild 留下了自己的命令行

"这个驱动编得出来吗"最容易做假，因为**重建一份编译参数**可以在一台永远不会构建真东西的机器上通过。
这里不是重建：kbuild 在每个目标文件旁边留下一份 `.<对象>.o.cmd`，里面是**这次编译真正的命令行**。
`drivers/input/.input.o.cmd` 的第一行拆开就是全部 `-I` / `-D` / 警告开关。

**而这一行不能原样塞进一个 shell 变量**：里面有 `-D"KBUILD_STR(s)=#s"` 这样的条目，在 Makefile 的配方里
那些引号是**shell 引号**、会被 shell 剥掉；把整行放进一个变量再展开，引号字符**进了值里**，gcc 收到
`-D"KBUILD_STR(s)=#s"` 就答 `error: macro names must be identifiers`——**一个和驱动毫无关系的编译失败**。
这是最危险的一种红（它看起来像关于驱动的事实），所以提取器**照 shell 的效果把引号去掉**，
而 harness 有一整个变异专门证明这一条：把 `.replace('"', '')` 去掉，判定必须落到 `driver-does-not-compile`。

编出来之后还有**第二个**读数：`ld -r` 把两个目标文件合成一个，再用 `nm -u` 与 `nm --defined-only vmlinux`
做 `comm`。**"它编得过"和"它属于这个内核"是两件事**，所以它们是两段打印：

```
gf_spi.c: rc=0, 218528 bytes -> .../gf_spi.o
platform.c: rc=0, 145224 bytes -> .../platform.o
ld -r: 360728 bytes of combined object
undefined symbols in the driver: 51
symbols DEFINED in the built vmlinux: 148492
every one of them resolves against this kernel's own vmlinux
```

**而"编不了"和"没编"必须分开。**工具链不在、或者旁边没有 `.cmd` 可取命令行时，判定**不会**站在顶格，
而是落到 `not-verified-whether-it-compiles`，并且在判定词里把**哪一条检查没做成**说出来：

> A check that could not be made is not a pass.

---

## 4. 仪器自己第一轮跑出来的四个缺陷（以及另外两个）

这一轮最值得写下来的部分不是判定，是**判定器自己错的四次**——它们全部是这棵树记过形状的老毛病，
而且是**同一个类型**：**一个读错的东西印出来，和读对了一模一样。**

1. **`depends on INPUT` 没有加 `CONFIG_` 前缀。**配置文件把一个符号写成 `CONFIG_INPUT`，而 Kconfig 的
   `depends on` 行写成 `INPUT`。第一版拿 `^INPUT=` 去查一份写着 `CONFIG_INPUT=y` 的文件，得到"没提到"，
   而"没提到"被算成**依赖不满足**——于是**每一个内核**都会读到 `dependency-off`。
   一个**因为命名约定**而报故障的依赖，和一个**真的**故障，读起来一样。
2. **`$(MODULE_NAME)-objs` 只读了一行。**那份 Makefile 写的是
   `$(MODULE_NAME)-objs := gf_spi.o \` 换行 `platform.o \`。一行 `sed` 读到 `gf_spi.o` 就停，
   于是读数说"这个驱动由一个文件编成"，而它由两个编成——**这个工程记过的"抽取器丢掉一项"**。
   现在用 awk 跨续行读，harness 的变异把它压回一行，断言"两个目标文件"必须变红。
3. **没有剥 `#if 0`。**见 §2：`goodix,gpio_pwr` 会变成对**每一棵树**的要求，于是这块板上**每一棵树**都被
   报成不完整——一次关于健康设备树的假红。
4. **FDT 偏移按文件坐标对齐。**附着在镜像里的设备树，内部偏移是**相对它自己那块 blob 的**；
   而这张镜像里第一个附着的 blob 在 **`0xb4ae66`**，**2 mod 4**。第一版拿文件坐标 `& ~3` 去走，
   结果**五棵真树一棵都没走到**，而 `except: continue` 把解析器的错误变成了**"这张镜像里没有设备树"**——
   **一个不能说"我找到了东西但读不了它"的读取器，才是缺陷本身**。现在先把 blob 切出来再从 0 走，
   并加了一条自洽性检查（`off_struct + size_struct == off_strings` 且 `off_strings + size_strings <= total`），
   它顺手拒掉了这张镜像里**一个巧合的魔数**（偏移 5 处真的有一串 `d0 0d fe ed`）。
5. **`getline` 循环没有判断返回值。**那份 Makefile 的**最后一行**以反斜杠结尾，后面没有行了；
   `getline` 在 EOF 返回 0 而**不改 `$0`**，于是 `while ($0 ~ /\\$/)` **永远转下去**。
   它真的转了——仪器**挂了五分钟、没有任何子进程**（从外面看，挂起就是这样）。这个工程记过：
   **挂起没有退出码，只能靠"回不回来"发现它**，所以 harness 的断言就是这件事：**被变异的那个不许回来，
   原版必须在同一个 fixture 上回来**。
6. **命令行里的引号**：见 §3，它是一个**假红**，而且是关于驱动的那一种。

---

## 5. 阶梯，和它为什么把 `already-in-the-kernel` 也当成一档

```
unreadable-kernel-tree / unreadable-inputs        <- exit 3，什么都不声称
  < driver-source-missing        <- 源码不在（或者文件在但**是空的**）
  < option-not-in-kconfig        <- `config INPUT_GP5XX8` 这一行没了
  < dependency-off               <- 选项存在，但它的 depends on 在**编译用的配置**里不满足
  < match-table-differs          <- 打开它只会编出一个**永远匹配不上**这个节点的驱动
  < node-reading-not-made        <- 设备树**读不了**（"我没看"不是"节点没问题"）
  < no-tree-for-this-phone       <- 这些树没有一棵叫这块板的名字
  < node-missing-or-incomplete   <- 节点在，但**驱动要的属性缺**（或父控制器被 disabled）
  < trees-partly-unreadable      <- 有 .dtb **存在却解析不了**
  < already-in-the-kernel        <- 编译用的配置里这个选项**已经开了**
  < not-verified-whether-it-compiles  <- 静态环节全在，**需要工具链的两环没做成**
  < driver-does-not-compile      <- 用这个内核自己的开关编不过
  < driver-has-unresolved-symbols<- 编得过，但**不属于这个内核**
  < one-config-line-away         <- 每一环都在，只差那一行
```

三处顺序是**故意的**：

* **`already-in-the-kernel` 不是成功，是矛盾。**如果编译用的配置里这个选项已经开着，那 `/dev/goodix_fp`
  缺失就另有原因，而**这台仪器是错的工具**——它会盖住 docs 157 的读数，所以必须先解决它再动手构建。
* **`node-reading-not-made` 和 `no-tree-for-this-phone` 分开**：前者是"我没看"（读数没做成），
  后者是"我看了，没有"（关于**这块板**的断言）。把它们合成一句，就是这棵树反复记过的那个形状。
* **`trees-partly-unreadable` 是这一轮补的一档**，理由和上一条同源：**一个存在却解析不了的 `.dtb`**，
  第一版会掉进 `no-tree-for-this-phone`，也就是把**"我读不了一个在这里的文件"**印成
  **"这里没有这样的文件"**——两句关于**不同东西**的话（一个是仪器，一个是板子），
  而只有其中一句该让操作员去改设备树。它是 harness 逼出来的：**一个打不开的 fixture 必须落在一档能被点名的位置上。**

---

## 6. 五棵树、五棵树，以及"身份而不是大小"

设备树那一节和镜像那一节都是**按 `model` 认板子**的：这块板的树叫 `LE_ZL1-*`，**另一台手机**的树叫 `LE_X2-*`，
而**两台手机的树在同一个 blob 里、根 `compatible` 逐字节相同**（docs 140/156）。所以判定里那句话是有方向的：

```
5 tree(s) naming THIS phone, 0 naming the other board
```

另一台手机的树**被打印出来**（`(not this phone) ...`）而不是被丢掉——**丢掉它，就等于假装那张输出的世界里
只有一台手机**。而镜像里那五棵，每一棵都按 **sha256** 与构建产出相认：

```
#1  @0xb4ae66     407291 bytes  ... LE_ZL1-DVT1 sha=ead2b61547d4bae2
  /soc/spi@7579000/goodixfp@0 present    byte-identical to a built .dtb
```

`0xb4ae66` 这个偏移本身就留在这一页上，因为**它就是第 4 号缺陷的形状**（2 mod 4）。

---

## 7. 这一轮**没有**开药方，只说距离

**"只差一行"不等于"改一行就行"。**判定词的最后一段是仪器自己写的，这一页照抄：

> **WHAT THIS IS NOT**: a statement that the sensor works. The trust store, the store directory
> (docs 126), the TZ application and the sensor itself are all above or below this line, and the
> fingerprint is still "measured offline only" until the device-side judgement runs.

也就是说：这一轮交付的是**判据**。**那一行改在哪里、要不要改、改完要不要刷**，都是设备的决定，
而设备的决定要**一次上电**去买（doc 150 的墙充闸门）。

---

## 8. harness：122 项，一半在 fixture 上，一半在真树上

* **fixture 那一半**：一棵**小到能读**的内核树 + 一个构建输出目录，形状**故意保留**四处：
  Kconfig 与它的依赖、Makefile 的**两级接线（带那个行尾反斜杠）**、驱动自己的四个名字与它对设备树的
  要求（**其中一个在 `#if 0` 里**）、以及一棵**由 harness 自己一个字节一个字节写出**的设备树
  （它的字符串块是**边发属性边拼**的，因为 `nameoff` 是**字节偏移不是下标**——这一条 harness 自己先写错过，
  症状是"每棵树都缺每一个属性"，**一个 fixture 缺陷看起来和一条关于板子的读数一模一样**）。
* **十三个场景**走完阶梯，其中三对是**分开**的：源码缺失 / 源码**空**；DTB 目录里**没有树** / 有树但**解析不了**；
  选项**不在 Kconfig** / 选项在而**依赖不满足**。
* **真树那一半**是 fixture 做不了的：编两个翻译单元要工具链，`ld -r` 要真的 `vmlinux`，树要是**构建真的产出**的那些。
  它同时也是**过期检查**：谁把选项打开了，这一节就会变红，于是他必须先说明为什么。
  两个只有真内核才做得到的档也在这一半里：`driver-has-unresolved-symbols`（把一个 objdir **除了 `vmlinux`
  之外全部软链**到真的那个，再放一个**什么都不定义**的 `vmlinux`——第一版手工搭的 objdir 因为 kbuild 的
  相对 `-I` 在**编译**这一步就失败了，于是它**把驱动报了错**）和 `not-verified-whether-it-compiles`（把工具链拿走）。
* **六个变异**，每一个只弄坏**仪器里的一件东西**，并且必须让**点名的那一条**断言变红。其中四个就是 §4 的四次；
  第五个是那个挂起；第六个是引号。**挂起**那条按这个工程的规矩断言：**被变异的那个不许回来**。
* **fixture 树在跑之前和跑之后各哈希一次**："它不往自己读的东西里写"是**一条读数**，不是一句承诺。
* 静态守卫把所有绝对路径的重定向列出来，**允许的集合恰好是 `/dev/null`**。

---

## 9. 数字

| 项 | 读数 | 怎么读的 |
|---|---|---|
| 判定 | `one-config-line-away` | 一次运行 |
| 选项 | `CONFIG_INPUT_GP5XX8 = NOT SET`（defconfig 与**编译用的 `.config`** 都是），`depends on: INPUT`，`INPUT = y (built in)` | 判定输出的第 2 节 |
| 驱动 | `gf` / `gf_spi.o platform.o` / `USE_SPI_BUS` / `GF_SPIDEV_NAME = 'goodix,fingerprint'` | 第 3 节 |
| 驱动要的属性 | `gfvdda-supply`、`goodix,gpio_irq`、`goodix,gpio_reset`（`goodix,gpio_pwr` 在 `#if 0` 里，**不是**要求） | 第 4 节，从源码里读出来 |
| 这块板的树 | **5 of 5** 带着可用节点；**0** 棵属于另一台手机；SPI 控制器 `status: absent (=enabled)` | 第 5 节 |
| 镜像里的树 | **5 棵**走过去，**0 个**魔数walk不了，每一棵 `byte-identical to a built .dtb` | 第 6 节 |
| 编译 | `gf_spi.c` rc=0（218528 字节）、`platform.c` rc=0（145224 字节） | 第 7 节，用的是**这次构建自己的命令行** |
| 链接 | `ld -r` 360728 字节；未定义 **51** 个；`vmlinux` 已定义 **148492** 个；**未解析 0** | 第 8 节 |
| 输入的 sha256（前 16 位） | `gf_spi.c` `3a18bc64e2fbc406`、`platform.c` `420da3d55faa3f7b`、`Kconfig` `67dc553ad03ce935`、`Makefile` `17077d0b8195de79`、`defconfig` `5d6fd91d8936915f`、`.config` `8b042970f8f9cd63`、`vmlinux` `04b0cc4b98e3fd86`、`halium-boot-zl1-v63-rebuilt.img` `ac0dd8619c05763c` | 判定输出的第 1 节（docs 152） |
| 第一个附着的树 | `0xb4ae66`（**2 mod 4**） | 第 6 节 |
| 新 harness | **122 项**，`pass=122 fail=0` | 一次运行 |
| cli-usage | **208 → 211**（多了两个脚本要过 `--help` 那条规则） | 那个 harness 自己的一跑 |
| 家族全量跑 | **39 个 harness / 39 全绿 / 5170 检查 / 0 失败**，`== the repository is unchanged (472 tracked files hashed before and after, no new file)` | `bash scripts/host/zl1-selftest-family.sh` 的一次运行 |
| 本轮之前 | 5045（docs 157 之后） | 同一命令；差值 **+125** = 新 harness **122** + cli-usage **208 → 211** |
| 一次**没算数**的运行 | 39 / 39 全绿 / 5170 检查，但判定 **`THE TREE CHANGED`**（exit 3）——因为这一页正在被写、README 与 doc 123 正在被改，**而那次运行途中这些 tracked 文件被编辑了**。守卫是对的：它把改动逐个列了出来（README.md、doc 123、`scripts/README.md`、健康检查，以及这一页本身是运行期间新建的）。**读数的可信度和它的输入一样**，所以数字重跑了一遍，上面那一行才是算数的那一次 | 同一命令 |

---

## 10. 这一篇**不**声称什么

* **不声称改那一行就能用。**它只声称**软件路径**只差一行。存目录、信任库、TZ 应用、传感器硬件都在
  这一行的上面或下面，一个都没有被这一轮读到。
* **不声称传感器答话。**这一轮**没有碰硬件**，连打开一个设备节点都没有。
* **不声称那一行该改在哪、该不该刷。**那是一次**重新编译 + 刷 boot**，而刷 boot 是设备的决定
  （doc 150 的墙充闸门在先）。
* **不声称五个环节就是全部。**比如"这个驱动绑上之后会不会申请到 gpio 121"、"regulator 拿不拿得到"，
  都是**运行时**的事；这一轮量的是**静态可解的链**，而仪器把这一点写在它自己的拒绝里。
* **不声称这个判定器是对的。**它自己错了六次，其中四次在这一页上。**能读它的是 harness，不是这一页。**

---

## 11. 设备状态与下一步

整轮**没有写设备**：没有挂载、没有写镜像、没有 flash、没有一条会改变设备状态的命令。
设备在 **fastboot**（`33e80afe`，`18d1:d00d`，端口 3-3）。

不需要设备就能重跑这一页的每一条读数：

```
bash scripts/host/zl1-fp-driver-build-check.sh              # 判定：one-config-line-away
bash scripts/host/zl1-fp-driver-build-check.sh --explain    # 阶梯每一档的意思，和它拒绝做的事
bash scripts/host/zl1-fp-driver-build-check-selftest.sh     # 122 项
```

而**下一步仍然是同一个闸门**：不管要做的是设备侧读数还是构建，先要的是电——
墙充和 `bash scripts/host/zl1-battery-gate.sh --samples 9 --interval 60`（doc 150）。
