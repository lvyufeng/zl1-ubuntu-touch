# 157 — 指纹的答案在内核这一层，而这一层对两个块给出**相反的**答案

**日期**: 2026-09-25
**状态**: 本轮**没有碰设备**。这一页做的是"所有的硬件都能驱动"这句话里**指纹那一格的最下面一层**：
这个工程所有关于指纹的文档（[`83`](83-*.md)、[`98`](98-*.md)、[`101`](101-*.md)、[`126`](126-*.md)）讲的都是
**存目录、HAL、信任库**——也就是**驱动以上**的层。这一轮问的是它们下面那一层，而答案不是一个句子：

**这块板的设备树声明了两个指纹块，而手上这个内核只为其中一个编了驱动。**

**接续**: [`156`](156-the-coverage-is-about-the-table-and-nothing-measured-the-table.md)（覆盖率是关于那张表的；
**这一轮的块就是那一轮量出来的**）、[`137`](137-a-boot-should-answer-the-question-nobody-asked.md)（那份清单的来历）、
[`123`](123-where-every-peripheral-stands.md)（每个外设现在在哪儿：本轮的读数归到那一页）、
[`124`](124-the-boot-a-finger-bought-is-one-command.md)（一次开机是一条命令：这一轮的探针是它的 04o）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 这一轮问的是什么？ | 容器里的指纹 HAL 打不开 `/dev/goodix_fp`。**在这块板上，这个设备节点有可能存在吗？** |
| 为什么以前没问过？ | 因为以前问的都是**它上面**的层：一个缺失的存目录（docs 83/126）、HAL 的 `setActiveGroup`、信任库的门。**那些修法都成立，但它们修的是驱动以上的东西。** |
| 这块板有几个指纹块？ | **两个**，在同一棵设备树里。`/soc/spi@7579000/goodixfp@0`（`goodix,fingerprint`，`input-device-name = "gf318m"`，reset gpio31，irq gpio121）和 `/soc/qcom,qbt1000`（超声波 QBT1000，子节点 `qcom,fingerprint-sensor-ssc-spi-conn`）。 |
| 哪一个 HAL 在用？ | **第一个。**容器里的 Goodix HAL 开的就是 `/dev/goodix_fp`——这个名字只属于 `goodix,fingerprint` 这个块。 |
| 它的驱动在这个内核里吗？ | **不在。**`# CONFIG_INPUT_GP5XX8 is not set`——`gf_spi.c` 根本没编进去，所以**没有任何东西能绑那个节点，`/dev/goodix_fp` 不可能存在**，HAL 的 `open()` 失败的原因在**这些文档工作过的每一层之下**。 |
| 那"这个内核有指纹驱动"这句话呢？ | **是真的**，但说的是**另一个块**：`CONFIG_MSM_QBT1000=y`，它建出 `/dev/qbt1000` **和一个输入设备 `qbt1000_key_input`**——后者这个工程**在屏幕上见过**（docs 70/73）。 |
| 证据是哪来的？ | **从内核镜像自己身上**：配置是从**镜像里嵌的那份 config** 读的（设备上就是 `/proc/config.gz`，`CONFIG_IKCONFIG_PROC=y`），不是笔记本上某个 defconfig。 |
| 所以"指纹不工作"的结论是什么？ | **要分开说**：HAL 用的那个传感器，**内核层是空的**；而板上另一个指纹块，**内核层是齐的**。任何一句单数形式的"指纹驱动"都会把这两件事平均掉。 |
| 修法是什么？ | **这一轮不开药方。**修法是"让内核包含那个驱动"，而那是一次**重新编译+刷 boot**——属于设备的决定，不是这一轮能替它做的。这一轮交付的是**判据**。 |
| 这一轮动了表吗？ | **动了，而且是它第一次因为这个而收口**：docs 156 量出来的 `fingerprint-spi` 那一行**有了仪器**，于是**缺口列表回到 0**（30 行 / 30 有仪器）。 |
| 加了几项检查？ | 新 harness **112 项**（`pass=112 fail=0`），家族全量跑见 §9。 |
| 动设备了吗？ | **没有。**设备仍在 **fastboot**（`33e80afe`，`18d1:d00d`），本轮没有一条会改变设备状态的命令 |

---

## 2. 一棵树里的两个块，和它们相反的答案

设备树里两个块都在（**这块板的五套 stock 树、每一个变体都有**；`goodix` 在 38 棵 DTB 里的 10 棵，`qbt1000` 在 33 棵）：

| | `/soc/spi@7579000/goodixfp@0` | `/soc/qcom,qbt1000` |
|---|---|---|
| compatible | `goodix,fingerprint` | `qcom,qbt1000` |
| 它是什么 | **电容式 Goodix**，SPI 控制器上，`input-device-name = "gf318m"` | **超声波 QBT1000**，走 SSC 的 SPI 端口 |
| 设备树的子节点 | 无 | `qcom,fingerprint-sensor-ssc-spi-conn`（`spi-port-id = <2>`、slave 0、`tz-subsys-id = <1>`、`ssc-subsys-id = <5>`、15 MHz） |
| 驱动源文件 | `drivers/input/fingerprint/gf_spi.c` | `drivers/soc/qcom/qbt1000.c` |
| **内核为它编了吗** | **没有**：`# CONFIG_INPUT_GP5XX8 is not set` | **编了**：`CONFIG_MSM_QBT1000=y` |
| 它建出什么 | `/dev/goodix_fp`（**建不出来**） | `/dev/qbt1000` **+ 输入设备 `qbt1000_key_input`** |
| 谁在用它 | **容器里的 Goodix HAL**（`biometrics.fingerprint*service`，docs 83/98/126 全是这一条链） | **这个工程没见过谁用它**，只在 docs 70/73 里**在屏幕上见过那个输入设备** |

**这两行是这一页的全部**：一个"指纹不工作"的结论，如果是关于 HAL 那个的，答案是**内核里没有它的驱动**；
如果是关于"这个内核有没有指纹驱动"的，答案是**有，是另一个传感器**。

---

## 3. 证据是从镜像自己身上读出来的，不是从某个 defconfig

这条读数的分量全在**它读的是哪份配置**上。`CONFIG_IKCONFIG_PROC=y`，所以**正在跑的那个内核把自己的配置
放在 `/proc/config.gz` 里**；离线那一半是从**刷进去的 boot 镜像**里把压缩内核解出来、再从里面把内嵌配置段
（`IKCFG_ST`…`IKCFG_ED`）取出来读的——**两条路读的是同一个东西**，所以"内核里有没有这个驱动"这句话
不依赖任何笔记本上的文件是不是最新的。

```
# CONFIG_INPUT_GP5XX8 is not set      <- gf_spi.c，HAL 那个传感器的驱动
CONFIG_MSM_QBT1000=y                  <- 另一个指纹块的驱动，在
# CONFIG_INPUT_FPC1020 is not set      <- 第三种指纹驱动：这个内核有它的开关，而这块板没有它的节点
```

**第三行是给"读数别读成结论"用的**：这块板上还有第三个指纹驱动的配置项，它也是关的，但它**没有节点**，
所以它不在这一轮的任何一个块里。同一个内核里关着的指纹选项有两个，**只有一个和 HAL 的失败有关系**。

---

## 4. 这个块的驱动为什么"看起来像是成功了"：`gf_init()` 的陷阱

源码里那一段值得单独写下来，因为它制造的是一个**读起来正常**的状态：

```c
gf_init() {
  ...
  status = register_chrdev(SPIDEV_MAJOR /* 212 */, "goodix_fp_spi", &gf_fops);
  ...
  status = spi_register_driver(&gf_driver);
  ...
  return 0;   // status   <- 注释掉的
}
```

`return 0; //status`：**即使 `spi_register_driver()` 失败，initcall 也报告成功。**
所以在一个**编了**这个选项的内核上，"initcall 没报错"和"驱动注册上了"是两件事——
这也正是新探针读的是**绑定状态**（`/sys/bus/platform/devices/...` 和 `/sys/bus/spi/drivers/...`）
而不是任何 initcall 的返回值的原因。

---

## 5. 三条"词不是块"，在这一块上都是可量的

这一页的题目是"读数说的是哪一块"，所以三条会在别处把人送错的命名事实，都在这里量了：

1. **四个名字，没有一个 compatible。**配置项是 `CONFIG_INPUT_GP5XX8`，源文件是 `gf_spi.c`，
   驱动 `.name` 是 `goodix_fp`（目录 `/sys/bus/spi/drivers/goodix_fp`），字符设备是 `/dev/goodix_fp`，
   chrdev 注册名是 `goodix_fp_spi`，输入设备是 `gf318m`。按其中任何一个去找，都会在**别的层**找到东西。
2. **`qbt1000` 的子节点没有 `compatible`，而驱动按节点名匹配它。**`qbt1000_probe()` 要求**恰好一个**子节点
   （否则 `-EINVAL`），而它认那个子节点的方式是 `of_node_cmp()` 比对 `child_node->name`——
   **子节点身上没有 `compatible`**。这就是为什么这个块在**这个工程里每一份从 DTB 派生的读数**里都不出现：
   那些读数找的是 `compatible`，而这里没有可找的。
3. **没有 `reg` 的节点会爬回根取名。**`of_device_make_bus_id()` 的行为决定了这个平台设备叫
   **`soc:qcom,qbt1000`**（和这块板上已经记过的 `soc:qcom,cnss`、`soc:qcom,kgsl-hyp` 同一个约定），
   所以一个去找 `/sys/bus/platform/devices/qcom,qbt1000` 的探针，会在**设备确实存在的地方**什么都找不到。

---

## 6. 为什么这个探针**不打开任何东西**，连"看一眼"都不

这是这一轮最容易做错的地方，而做错的方向是**把状态改变当成读数**：

* **`/dev/qbt1000` 的 `open()`** 会做一次 SNS 的 QMI open + keep-alive，然后调
  `qbt1000_set_blsp_ownership()`——也就是 **`scm_call2(TZ_BLSP_MODIFY_OWNERSHIP)`，把 SPI 的 BLSP 块交给安全世界**
  （`release()` 再要回来）；它的 `ioctl` LOAD 还会 `qseecom_start_app("fingerpr")`。**"读一下 `/dev/qbt1000`"
  是一次硬件归属权的移交**，而安全世界的调用**已经让这个工程付过一次开机的代价**（docs 58）。
* **`/dev/goodix_fp`** 是 HAL 自己的门，打开它会唤醒传感器并启动它的中断路径；它**这一次 boot 里不存在**，
  而一个靠打开它才让节点出现的探针，报告的是**它自己的动作**。

所以这个探针的判据全部来自**不需要打开任何东西**的地方：设备树节点、配置、`/sys/bus/...` 的绑定状态、
内核日志。它的 harness 在**四个假设备节点里写了 canary**（`/dev/goodix_fp`、`/dev/qbt1000`、`/dev/qseecom`、
`/dev/spidev`），并把"canary 没出现在任何场景的输出里"做成断言——**将来某一版真的去读了一个，抓到它的是
fixture，不是这台手机。**

**而这有一个代价，探针自己说出来**：它**不能**说两个传感器的**硬件**答不答话，只能说内核**有没有**驱动、
那个驱动**绑没绑上**。

---

## 7. 阶梯，和它为什么点的是**第一个失败的块**

```
tree-unscanned  <  wrong-board-tree  <  unknown-board  <  no-fingerprint-block
                <  no-driver-in-source  <  driver-not-built  <  driver-not-bound
                <  every-block-has-a-bound-driver
```

* `wrong-board-tree` / `unknown-board` 在**最下面**：刷进 boot 的那个 blob 里**两台手机的设备树都在**，
  根 `compatible` 逐字节相同，只有 `model` 能分开（doc 140 那一课）——而**两个指纹块在两台手机的树里都有**，
  所以只看树的形状**分不出**这是哪台手机。
* `no-driver-in-source` 和 `driver-not-built` 是**两件事**：源文件没有匹配的驱动，和驱动在源码里而没编进来。
  这一轮落在**后者**，这是它比前者"近一步"的地方。
* 判词会**点名第一个失败的块**，带着它自己的 compatible 和它自己的选项——因为"**谁的**驱动不在"
  才是这一页的问题。

而**这个内核上它落在 `driver-not-built`，落的正是 HAL 用的那一个块**。判词里那两句被**故意并排**打印：

```
'there is a fingerprint driver in this kernel'            -> TRUE (1 of 2 blocks)
'the fingerprint sensor the HAL opens has a driver here'  -> 见上面每一块自己那一行
```

---

## 8. harness：112 项，以及它防的是哪几种"看起来绿"

* 一个**手机形状的 fixture**（两棵树、两个块、一个 `model`），和一个**假的 `/proc/config.gz`**；
* **两个 sandbox**：一个是全套工具，另一个**没有 `find(1)`**——因为探针的搜索有一条 fallback，
  而**没人跑过的 fallback 不是 fallback**；
* 一个 `dmesg` stub，里面是**驱动核心自己的话**：`probe of soc:qcom,qbt1000 failed with error -22`
  （这句话是 `really_probe()` 打的，**不是驱动打的**——而 `qbt1000_probe()` 成功时**什么都不打**，
  所以日志里的安静**不是**证据，两个方向都不是）；
* **四个假设备节点里的 canary**，以及**写操作**的静态守卫（`> /sys/...`、`dd`、`tee`、`setprop`、
  `modprobe`、`mount`），四个"真会写"的样本**每个都必须被抓到**，而一段散文样本**必须不被误抓**；
* **十一个场景**走完阶梯，其中一对是**这一页的题目**：`NOT READ`（**没找到配置**）和 `NOT SET`（**选项是关的**）
  必须分开——一个把两者混起来的探针，会在"没读到配置"时说"驱动没编"，而那是**同一句话在两种事实上的复用**；
* **八个变异**，每一个都要让**点名的那一条**断言变红，包括：搜索里的**空 ERE 分支**（空分支匹配一切，
  于是"没有指纹块"永远不成立）、板子判断、无 `find` 分支里的 `-d` 守卫、以及顶格判断**两个方向**。

---

## 9. 数字

| 项 | 读数 | 怎么读的 |
|---|---|---|
| 指纹块 | **2 个**（`goodix,fingerprint`、`qcom,qbt1000`） | 探针的 per-block 行 |
| 内核为它们编了吗 | **1 / 2**（`CONFIG_MSM_QBT1000=y`；`# CONFIG_INPUT_GP5XX8 is not set`） | `/proc/config.gz` / 镜像里嵌的配置 |
| 判词 | `driver-not-built` | 一次运行 |
| 覆盖表 | `fingerprint-spi` 这一行**有了仪器** → `30 hardware -- **30 with a named instrument, 0 with none**` | `zl1-hardware-inventory.sh` |
| 缺口列表 | **1 → 0**（docs 156 量出来的那一行，被这一轮的探针读上了） | 同一份报告 |
| 新 harness | **112 项**，`pass=112 fail=0` | 一次运行 |
| 采集链 | **19 步 / 17 个 push / 20 个归档输出**（04o） | capture harness |
| 那次计算的界 | capture **4530 → 4775 s**（19 × (240+5) + 120），仍是 900 s 的 **5.3 倍** | runbook 从 callee 源码里数出来的 |
| 家族全量跑 | **38 个 harness / 38 全绿 / 5045 检查 / 0 失败**，`== the repository is unchanged (469 tracked files hashed before and after, no new file)` | `bash scripts/host/zl1-selftest-family.sh` 的一次运行 |
| 本轮之前 | 4926（docs 156 之后） | 同一命令；差值 **+119** = 新 harness **112** + cli-usage **204 → 208** + capture harness **176 → 179** |

---

## 10. 这一篇**不**声称什么

* **不声称指纹的失败就是那个缺的驱动。**这一篇声称的是**两件可以读的事实**：HAL 用的那个块，
  内核层没有驱动；另一个块有。**因果**要设备侧的读数（`setActiveGroup failed` 归零那条判据，docs 126）。
* **不声称补上 `CONFIG_INPUT_GP5XX8` 就能用。**那是**一次重新编译加一次刷 boot**，而且它会不会让传感器答话，
  这一层看不见：HAL、存目录、信任库、TZ 应用都在它上面或下面。
* **不声称两棵树就是全部。**"这块板有几个指纹块"是**这棵设备树**的读数；一个没有节点的指纹硬件
  连这份读数都进不来（doc 156 §4 那条盲区，同样适用于这里）。
* **不声称 `qbt1000` 起了。**驱动编进去、节点在三套树里都有，是**离线**读数；它这一 boot 有没有绑上，
  是**设备侧**读数——而这个探针**正是那个仪器**，它到现在**一次都还没在设备上跑过**。
* **不声称这个探针读过硬件。**它打开零个设备节点，理由在 §6。
* **不声称 doc 156 那句话失效了。**缺口回到 0 **仍然是关于"行"的**；同一份报告在下面两行仍然印着
  "这块板上有多少个 compatible **没有任何一行认领**"。

---

## 11. 设备状态与下一步

整轮**没有写设备**：没有挂载、没有写镜像、没有 flash、没有一条会改变设备状态的命令。
设备在 **fastboot**（`33e80afe`，`18d1:d00d`，端口 3-3）。

不需要设备就能重跑这一页的每一条读数：

```
bash scripts/device/zl1-fp-kernel-probe.sh --explain          # 判据和它拒绝做的动作
bash scripts/host/zl1-fp-kernel-probe-selftest.sh             # 112 项
bash scripts/host/zl1-hardware-inventory.sh                   # 30 / 30 / 0 gaps
```

**那次开机上它会回答的问题**（`04o`，只读，在默认集里）：

```
tree-unscanned / driver-not-built / driver-not-bound / every-block-has-a-bound-driver
```

而**挡住这一切的仍然是电**：那条命令之前是墙充和
`bash scripts/host/zl1-battery-gate.sh --samples 9 --interval 60`（doc 150）。
