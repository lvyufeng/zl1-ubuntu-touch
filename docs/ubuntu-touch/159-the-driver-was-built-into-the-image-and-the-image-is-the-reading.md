# 159 — 驱动被编进了镜像，而"镜像"就是这次读数

**日期**: 2026-09-25
**状态**: 本轮**没有碰设备**。这是这个工程第一次**真的产出那个驱动**——docs 158 量出的
`one-config-line-away` 里的那一行**被改了**，内核重新编译，驱动**进了镜像**。
而这一轮交付的**不是一个判定词，是两个**：一个**工具**（镜像自己说的话）和一个**镜像**（只有一处
差别的候选 boot）。**设备仍在 fastboot，一样东西都没刷。**

**接续**: [`158`](158-the-distance-to-a-driver-is-one-config-line-and-it-costs-a-boot-to-buy.md)（它量出只差一行，
并留下判定 `one-config-line-away`）、[`157`](157-the-answer-is-at-the-kernel-layer-and-it-is-opposite-for-the-two-blocks.md)
（`# CONFIG_INPUT_GP5XX8 is not set`，从**镜像自己嵌的配置**里读出来）、
[`153`](153-the-premise-was-false-and-the-answer-was-on-this-laptop.md)（编译出正在跑的镜像的源码就在这台笔记本上，
所以这一轮能真的编）、[`152`](152-a-reading-is-only-as-good-as-the-identity-of-its-input.md)（读数的输入要带身份——
这一轮因此把"两张镜像只差一处"做成**从镜像里算出来的**）、[`150`](150-the-gate-the-rest-of-the-project-waits-behind.md)
（墙充闸门：刷与不刷是设备的决定）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 这一轮做了什么？ | 把 docs 158 量出的**那一行**改了：`lineage_zl1_defconfig:1871`，`# CONFIG_INPUT_GP5XX8 is not set` → `CONFIG_INPUT_GP5XX8=y`。然后重新编译内核。 |
| 编出来了吗？ | **编出来了**：构建日志里 `CC drivers/input/goodixfp/gf_spi.o`、`CC .../platform.o`、`LD .../gf.o`、`LD .../built-in.o`，`rc=0`。 |
| 新的内核镜像是什么？ | `halium-boot.img` sha256 `e4b120001397cd3e…`，**可复现**（两次构建逐字节相同）。 |
| 新的 boot 镜像呢？ | `halium-boot-zl1-v63-fpdriver.img`，sha256 `09fd1fe96e41f23d…`，18010112 字节。它 = **新的内核** + **v63 那份 initramfs**。 |
| 怎么知道只有一处变了？ | **从两张镜像里算出来的**：新工具 `--diff` 读两张镜像**各自嵌的那份配置**，答案是 **`1 option(s) differ`**——`CONFIG_INPUT_GP5XX8  y  ->  not set`。而 **ramdisk（`ebb281ff5537d99a`）和五棵附着的设备树（`5b280099e84e773c`）逐字节相同**，cmdline 也相同。 |
| 驱动在镜像里吗？ | **在**。工具在**解压后的 Image** 里找到 `goodix_fp`、`gf318m`、`goodix,fingerprint`、`goodix_fp_spi` 四个字符串，判定 `carries-the-driver`。 |
| 这台机器上有什么是新写的？ | 一个**工具**（`scripts/host/zl1-boot-image-kernel.sh`，只读镜像）和它的 harness（**92 项**）。 |
| 它对传感器说了什么？ | **什么都没说。**这一轮把"内核里有没有这个驱动"从"关的"变成"开的"，而存目录（docs 126）、信任库、TZ 应用、传感器本身**一个都没有被这一轮读到**。 |
| 刷了吗？ | **没有。**设备仍在 fastboot（`33e80afe`，`18d1:d00d`）。刷 boot 是设备的决定，墙充闸门在先（doc 150），撤销是刷回 `halium-boot-zl1-v63-rebuilt.img`。 |

---

## 2. 那一行改在哪，以及为什么它**不在这个仓库里**

改的是内核树里的一个 defconfig：

```
1871c1871
< # CONFIG_INPUT_GP5XX8 is not set
---
> CONFIG_INPUT_GP5XX8=y
```

`diff` 的**全部输出就是这一行**——这一个事实本身就是一次读数，所以它被写进了这个工程的证据里
（`/mnt/data/zl1-fp-build-159/before.sha256` 把改动前每一个输入的 sha256 都记下来了，
`lineage_zl1_defconfig.before` 是改动前的整份文件）。

**而这个改动这一个提交带不走**：内核源码在 `/mnt/data/halium-zl1-build`，**不在这个仓库里**。
所以"这一行被改了"这件事在这个树里**只能靠镜像本身证明**——这正是 §3 那个工具存在的理由。
一个只在提交信息里说"我改了一行"的工程，和一句"让内核包含那个驱动"没有区别。

---

## 3. 读数为什么必须是**工具**：这两条读数以前都是一次性的

docs 157 和 docs 158 都是**靠读一个镜像里的配置**得出结论的，而两次都是**有人打了一条命令、把输出抄进
文档**。也就是说：这个树里**没有任何东西**能在不重新抄一遍的前提下回答"我正要刷的这张镜像里的内核说了什么"。

而这是一个**镜像会被重新构建成同名文件**的工程（docs 152：`halium-boot-zl1-v63-rebuilt.img` 这个名字底下
可以换一张镜像），"最贵的一步是一次开机"的工程，和"我改了一行"必须能变成**关于文件的事实**的工程。
所以这一轮的第二个产物是把那条读数做成工具：

```
bash scripts/host/zl1-boot-image-kernel.sh IMG [IMG ...]
bash scripts/host/zl1-boot-image-kernel.sh --diff A B
```

它**只读**：不跑 kbuild、不配置、不打开任何设备，除临时目录外不写。它逐层说出来：

| 层 | 它读什么 | 为什么这一层值得单独读 |
|---|---|---|
| boot header | 页大小（**校验是 2 的幂**）、kernel/ramdisk/second 的大小（**对文件长度校验**）、cmdline、第 40 个字段 | 页大小错了会把内核的**后半段**读成 ramdisk，而那样读出来的东西**看起来完全正常** |
| 内核 blob | blob 的 sha256、**解压后 Image** 的 sha256 与大小 | blob 是 `Image.gz-dtb`：**一个** gzip member + 后面附着的设备树，边界只能靠 `unused_data`（把整个文件当内核读会把 2MB 设备树当成代码去哈希，**而且仍然能在中间找到一个配置**） |
| **内核自己的配置** | flat Image 里 `IKCFG_ST` 与 `IKCFG_ED` 之间的字节，两种布局都试 | 这就是设备在 `/proc/config.gz` 会答的**同一批字节** |
| **驱动在不在 Image 里** | 四个字符串 | **配置行说的是"要了什么"，Image 里的字符串说的是"有什么"**——两件事，都印出来，而它们不一致的时候才是要看的 |

**而它存在是为了守住一个区别**：**"这个内核的配置里没提这个选项"**和**"这个内核根本不带配置"**是
关于**不同东西**的两件事。没有 `CONFIG_IKCONFIG` 的内核答 **`NO CONFIG EMBEDDED`**，于是它下面每一行的
状态印成 **UNKNOWN**，**永不**印成 `not set`。同一个区别在文件层：读不了的文件 exit 3，**什么都不声称**——
"这不是一个内核"和"这是一个没有驱动的内核"也不是一句话。

---

## 4. 工具自己第一轮跑出来的两个缺陷

这一轮**第一次**运行就印出了一个必须修的东西，而且是这个工程记得最牢的那一类：**一个印出来的东西，
和读对了长得一模一样。**

1. **控制针没有被标成控制针。**工具印的是四个"要找的名字"加一个 `gf_spi.c`：
   ```
   goodix_fp=FOUND  gf318m=FOUND  goodix,fingerprint=FOUND  goodix_fp_spi=FOUND  gf_spi.c=not found
   ```
   在一张**完全健康**的镜像上，这一行读起来是"四项找到了，一项缺"。而 `gf_spi.c` 是**源码文件名**，
   一个优化过的 Image **本来就不该带它**——它是**故意的对照组**，存在的理由是让"not found"这一列
   **看得见地可以出现**，从而证明前四个 FOUND 不是子串搜索的假阳性。
   第一版把它和另外四个并列印出来，**没有任何标记**：一个正确的读数被印成了部分失败。
   现在它单独一行、带标签印出来，而 harness **断言那个标签存在**——因为**写在源码注释里的话不是关于输出的读数**。
2. **`say` 不是 `printf`。**`say` 把它的参数当成**一个** `%s` 印出来，所以
   `say "   boot header: page=%s kernel=%s …"` 印出的是**格式串本身**，后面跟着五个值。
   这一行的形状**恰好和一条正确的读数一样**，只有知道自己在看什么的人才发现它没有百分比号。
   现在那一行是真的 `printf`，而且用 `[ "$QUIET" = 1 ] ||` 保护——两个缺陷都是**同一类**。

---

## 5. "只差一处"是**从镜像算出来的**，不是一句承诺

这一轮最承重的读数不是"编译成功"，是这一条：

```
== the options that DIFFER between the two kernels' own configs
   (this is computed from the two IMAGES, so it needs no defconfig to agree with)
   1 option(s) differ:
     CONFIG_INPUT_GP5XX8                y            -> not set
```

它由 `--diff` 从**两张镜像各自嵌的配置**里算出来，**不需要任何 defconfig 与它一致**。
这是这个工程的规矩（docs 152）：**一句"我只改了一行"是一个意图，而从两个文件里算出"只差一处"是一个事实。**

而"不变量"那一半也是印出来的，因为**只有变量是内核**这件事必须被证明，而不是被假设：

| 不变量 | 两张镜像的读数 | 含义 |
|---|---|---|
| initramfs | `ramdisk: sha256=ebb281ff5537d99a`（两边相同） | v63 那份 initramfs **一个字节都没动** |
| 附着的设备树 | `2044818 bytes, 5 FDT magic(s)  sha256=5b280099e84e773c`（两边相同） | 五棵树的 blob **逐字节相同**；设备树不是变量 |
| cmdline | 两边相同 | 启动参数不是变量 |
| **唯一的变量** | **内核 blob**：`kernel=13884449` 字节（v63-rebuilt 比它少 2601 字节） | 所以**唯一的变量是内核**，而这正是"一行配置改了驱动"该有的形状 |

---

## 6. 上一轮的仪器红了，而**这是它该做的事**

这一轮改完那一行之后，`zl1-fp-driver-build-check-selftest.sh`（docs 158 的 harness）**变红了**，
而且是**五条断言一起红**。这不是回归，这是那一节**写在源码里的用途**：

> 真树那一半是 fixture 做不了的：… 它同时也是**过期检查**：谁把选项打开了，这一节就会变红，
> 于是他必须先说明为什么。（docs 158 §8）

**它真的这么做了。**而现在必须回答它，因为一个"红了然后被注释掉"的守卫比没有守卫更坏。

它红的方式本身说明了一个这一轮才知道的事实：那个仪器的**顶格断的是"离一行有多远"**，
而这一轮把那一行**改掉了**，于是同一份输入现在答 `already-in-the-kernel`——
**"距离为零"**。所以正确的修法不是把断言放宽，是**把两件不同的事分成两次运行**：

| 运行 | 读的是什么 | 该答什么 | 为什么它必须存在 |
|---|---|---|---|
| (a) **真正的构建目录，原样** | 那个 `.config`（现在带着那一行） | `already-in-the-kernel`：**距离为零** | 这就是这一轮的**结果**；而且它是**双向**的过期检查——谁把这一行改回去而没说，这条断言一样会红 |
| (b) **同一棵真树，配置点名** | 真源码、真 Makefile/Kconfig、真驱动、**五棵真 .dtb**、真镜像里附着的五棵、真 objdir 的编译参数、真 `vmlinux`——**只有 config 与 defconfig 是写出来的**，两个都印在仪器自己的第 1 节里（**按 sha256**） | `one-config-line-away`：顶格仍然在**真树**上被走到 | 否则"阶梯"就只剩下 fixture 上走过的那一半，而 fixture 做不了编译和链接 |

**而那个仪器的判词本身也过期了。**它原来写的是"这个仪表是错的，应该先解决这个矛盾"——
那是**在这台仪器被写出来的前提**下写的（docs 157 读的是**正在跑的镜像**，答 `not set`）。
现在这一行是**故意**开的，于是同一句话变成了**假警报**：它在叫操作员去解决一个项目刚刚刻意造出来的状态。
现在它说的是**两件事里哪一件为真，以及这个读数到底是关于什么的**：

> 这里的**距离为零**……而**构建目录不是镜像**，所以去读你正要启动的那张镜像
> （`host/zl1-boot-image-kernel.sh` 从 Image 自己里面读配置）。

这一条值得记下来，因为它是这个工程的**老形状的又一面**：**一句话在写下它的前提变了之后，会继续以原来的
自信说出来。**

## 7. 这一轮**不**声称什么

* **不声称指纹能用。**它声称的是：**内核里有这个驱动**。存目录（docs 126）、信任库、TZ 应用、
  传感器硬件都在这条线的上面或下面，一个都没有被这一轮读到。上一轮已经把这句写进了判定词里，
  这一轮**一个字都没有多加**。
* **不声称驱动绑上了。**Image 里有 `goodix_fp` 这个字符串，说的是**代码在里面**；
  它绑不绑得上、gpio 121 拿不拿得到、regulator 给不给电，全是**运行时**的事。
* **不声称镜像能启动。**它**一次都没有在设备上跑过**。它和 v63 的差别只有内核，而
  "只有内核不同"**不等于**"启动结果相同"——这个工程在这一条上吃过的教训不止一次。
* **不声称那一行该不该刷。**刷 boot 是设备的决定，墙充闸门在先（doc 150），
  而撤销路径是明确的：刷回 `halium-boot-zl1-v63-rebuilt.img`（`ac0dd8619c05763c…`）。
* **不声称这一行改在仓库里。**见 §2：源码树不在这个仓库，所以这个变化**只由镜像证明**，
  而镜像在 `/mnt/data/halium-zl1-candidates/`（gitignored），身份记在
  `manifests/halium-boot-candidates.md` 与 `SHA256SUMS` 里（doc 152 的清单工具：`zl1-artifact-manifest.sh` 判 `IN SYNC`）。

---

## 8. harness：92 项，而 fixture 是 harness **自己一个字节一个字节搭出来的镜像**

这个工具有一个别的东西没有的难处：**它的输入格式是二进制**，而二进制 fixture 最容易被写成
"输入恰好是主体读得懂的样子"——那样 harness 就在证明主体和它自己一致。

所以 fixture 是 harness 自己的 `mkimage.py` **搭**出来的：boot header、一个**真的** gzip member、
一个**真的**附着 FDT、一段**真的** `IKCFG_ST`/`IKCFG_ED`。每一个 flag 只种**一个**结构事实：

| flag | 种的是哪一个事实 |
|---|---|
| `--opt NAME=STATE` | 配置里某一项的状态 |
| `--nostrings` | Image 里没有驱动字符串（配置说有、Image 说没有——**两句话打架**） |
| `--noconfig` | 内核**根本不带**配置 → 每一项必须印 `NO CONFIG EMBEDDED` |
| `--lenprefixed` | 另一种 `IKCFG` 布局（8 字节长度前缀） |
| `--badconfig` | 标记在、中间那些字节**充不出**一个配置 |
| `--badmagic` | 不是 boot 镜像 |
| `--noappend` | `Image.gz-dtb` **没有**附着的设备树 |
| `--earlyed` | `IKCFG_ED` 出现在 `IKCFG_ST` **之前**（它埋在压缩流里，改不出来，所以是构建时就种） |
| `--badpage` | header 声称 6144，而布局是 4096 |
| `--cutmember N` / `--oversize N` | gzip member 被切断 / header 声称的比文件里多 |
| `--page` / `--truncate` | 布局本身 |

**五个变异，每一个只弄坏主体里的一件事**，而且必须让**点名的那一条**断言变红：
① 把整个 blob 当 Image 读；② 从 0 开始找 `IKCFG_ED`（而不是从 `IKCFG_ST` 之后）；
③ 把页大小写死；④ 把"没有配置"折成"not set"——**这个工具存在的理由**；⑤ 对一对不能比较的镜像
印出一个空 diff（**空 diff 恰好是"两个内核用同一份配置编的"的样子**）。

**最后两节跑的是真的镜像**：候选镜像与这个工程正在启动的那张，并把这一轮的中心断言**断言成行**——
它们自己嵌的配置**只差一项**，而它们的 initramfs（`ebb281ff5537d99a`）与五棵附着的设备树
（`5b280099e84e773c`）**逐字节相同**。

静态守卫列出所有绝对路径的重定向（允许集合恰好是 `/dev/null`），fixture 树跑前跑后各哈希一次。

---

## 9. 数字

| 项 | 读数 | 怎么读的 |
|---|---|---|
| defconfig 的改动 | **1 行**（`1871c1871`） | `diff`，全部输出 |
| 编译 | `CC gf_spi.o`、`CC platform.o`、`LD gf.o`、`LD built-in.o`，`rc=0` | 构建日志 |
| 新内核 blob | `e4b120001397cd3e…`（`halium-boot.img`），**两次构建相同** | sha256 |
| 新 `.config` | `a677c709b095cb54…`（改前 `8b042970f8f9cd63…`） | sha256 |
| 新 `vmlinux` | `b980c327719d72a0…`（改前 `04b0cc4b98e3fd86…`） | sha256 |
| 候选镜像 | `halium-boot-zl1-v63-fpdriver.img` 18010112 字节，sha256 `09fd1fe96e41f23d…` | `gen-candidate-manifest.sh` 重跑，93 张 |
| 候选镜像的内核 blob | `c6d46e3488ddc0f6…`，13884449 字节 | `zl1-boot-image-kernel.sh` |
| 解压后的 Image | 28259328 字节，sha256 `f23f386ff9ec58fa…` | 同上 |
| 附着的设备树 | 2044818 字节，5 个 FDT magic，sha256 `5b280099e84e773c`（**与 v63-rebuilt 相同**） | 同上 |
| initramfs | sha256 `ebb281ff5537d99a`（**与 v63-rebuilt 相同**） | 同上 |
| 内核自己的配置 | 125101 字节 | 同上 |
| 六个被查的选项 | `CONFIG_INPUT_GP5XX8 y`、`CONFIG_MSM_QBT1000 y`、`CONFIG_INPUT_FPC1020 not set`、`CONFIG_INPUT y`、`CONFIG_IKCONFIG y`、`CONFIG_IKCONFIG_PROC y` | 同上 |
| Image 里的驱动字符串 | `goodix_fp` / `gf318m` / `goodix,fingerprint` / `goodix_fp_spi` **全 FOUND**；对照组 `gf_spi.c` not found（**预期**） | 同上 |
| 判定 | **`carries-the-driver`** | 同上 |
| `--diff` 两张镜像 | **`1 option(s) differ`**：`CONFIG_INPUT_GP5XX8 y -> not set` | 同上 |
| 新工具 | `scripts/host/zl1-boot-image-kernel.sh`（只读、不跑 kbuild） | — |
| 新 harness | **92 项**，`pass=92 fail=0` | 一次运行 |
| cli-usage | **211 → 214**（页面新点名两个脚本；而它不是猜的——第一版按 213 写，跑出来是 214） | 那个 harness 自己的一跑 |
| 上一轮的 harness（过期检查**真的响了**） | `zl1-fp-driver-build-check-selftest.sh` **122 → 129 项**；它在家族里 **5 条断言红**，全部由这一行引起 | `bash scripts/host/zl1-selftest-family.sh`，第一次运行 |
| 家族全量跑 | **40 个 harness / 40 全绿 / 5272 检查 / 0 失败**，`== the repository is unchanged (475 tracked files hashed before and after, no new file)` | `bash scripts/host/zl1-selftest-family.sh` 在内容冻结之后的一次运行 |
| 本轮之前 | 5170（docs 158 之后，39 个 harness） | 同一命令；差值 **+102** = 新 harness **92** + cli-usage **211 → 214**（+3）+ fp harness **122 → 129**（+7） |

---

## 10. 设备状态与下一步

整轮**没有写设备**：没有挂载、没有写镜像、没有 flash、没有一条会改变设备状态的命令。
设备在 **fastboot**（`33e80afe`，`18d1:d00d`，端口 3-3）。

不需要设备就能重跑这一页的每一条读数：

```
bash scripts/host/zl1-boot-image-kernel.sh /mnt/data/halium-zl1-candidates/halium-boot-zl1-v63-fpdriver.img
bash scripts/host/zl1-boot-image-kernel.sh --diff \
     /mnt/data/halium-zl1-candidates/halium-boot-zl1-v63-fpdriver.img \
     /mnt/data/halium-zl1-candidates/halium-boot-zl1-v63-rebuilt.img
bash scripts/host/zl1-boot-image-kernel-selftest.sh          # 92 项
```

**而下一步仍然要电，而且现在多了一件要做决定的事。**两件事都在同一个闸门后面：

1. **闸门**：墙充 + `bash scripts/host/zl1-battery-gate.sh --samples 9 --interval 60`（doc 150）。
2. **闸门之后**：`scripts/host/zl1-one-boot-runbook.sh --yes`（doc 124 那一条顺序固定的命令）。
3. **只有用户明确同意才做**：刷 `halium-boot-zl1-v63-fpdriver.img`——
   撤销是刷回 `halium-boot-zl1-v63-rebuilt.img`（`ac0dd8619c05763c…`），
   两张镜像的差别**只有内核**，而这一点是**算出来的**（§5）。

而"刷了之后指纹就能用"**不是这一轮说的**，也说不了：这一轮把内核里**有没有**这个驱动从"关的"
变成了"开的"，而**驱动绑不绑得上**、**绑上之后 HAL 开不开得了节点**、**节点开得了之后存目录在不在**
（docs 126）——三件都是运行时的事，一件都还没有量过。
