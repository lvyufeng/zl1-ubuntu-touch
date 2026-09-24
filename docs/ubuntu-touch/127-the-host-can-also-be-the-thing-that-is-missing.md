# 127 — 宿主自己也会是那个"不在场的东西"，而 runbook 只问了设备在不在

**日期**: 2026-09-24
**状态**: 本轮**没有碰设备**（设备仍在 Qualcomm EDL，见 §6）。这一轮是从 [`126`](126-the-path-was-decided-by-what-the-stub-omits.md)
的同一个题上往前一步：把"那一次手指换来的 boot"的**前提**从"设备在不在"扩到"这台机器还在不在"。
改的是 `scripts/host/zl1-one-boot-runbook.sh`（第 0 节之后新增一个**宿主侧前置检查**），
harness 从 95 涨到 **118 检查**。

**接续**: [`124`](124-the-boot-a-finger-bought-is-one-command.md)（那条命令和它的顺序）、
[`118`](118-the-heat-fix-chain-is-one-command-on-one-boot.md)（第 03 步是发烫链）、
[`107`](107-one-physical-press-buys-one-command.md)（一次手指换一次 boot）、
[`126`](126-the-path-was-decided-by-what-the-stub-omits.md)（上一轮：一条推理被当成读数）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 发现了什么？ | `zl1-one-boot-runbook.sh` 的第 0 节问的是"**有没有设备**"（按序列号、EDL 状态、ssh 通不通），**没有问"这台机器还齐不齐备"**——而第 03 步要的三样东西**全在宿主机上** |
| 那三样是什么？ | `install-netwatch-service.sh --yes --ssh` 的**第一步**就会拒绝，除非：① misc 备份**非空**；② 它旁边有 `SHA256SUMS`；③ 那个 SHA256 **还对得上**；④ 要部署的 netwatch build 里**有 `ensure_addrs()`** |
| 为什么这是个真问题？ | 少了任何一样，拒绝发生在**第 03 步**，而那时 **01 和 02 已经跑过了**：这次手指换来的 boot 已经花掉一半，**发烫那一半整段丢掉** |
| 现在怎么样了？ | 检查挪到**第 01 步之前**，并且 `--status` 也报它；**不通过就 `exit 2`，一步都不跑** |
| 路径是从哪儿来的？ | **从那个 installer 里读出来的**，不是在本文件里再抄一份——"第二份路径就是第二个会过期的东西"，这正是 `126` 的教训换一个文件 |
| 第一版错在哪？ | 它按 `MISC_IMG="\(.*\)"` 把值抄回来，而 installer 里写的是 `MISC_IMG="$MISC_OUT/misc.img"`——**那是一个路径表达式，不是一个路径**。抄回来的是字面量 `$MISC_OUT/misc.img`。**实测出来的，不是想出来的**（见 §3） |
| 那读不出来怎么办？ | **报成"这个检查不可用"，绝不报成通过。** 一个什么都匹配不到却不吭声的提取器，就是这棵树一直在记的"不可能失败的检查" |
| 离线验证？ | harness **95 → 118 检查 / 0 失败**；两个变异分别让它红 **18 条**和 **4 条**（§4）。顺带加的表格闭合检查在 meta-harness 里（124 → **125**），变异红 1 条（§5） |
| 动设备了吗？ | **没有。** |

---

## 2. 缺口在哪：一个只问了一半的前置条件

第 0 节做的事是对的，而且它做得很仔细（按序列号而不是 USB ID、serial 是**前缀**、
`05c6:9008` 那种"没有序列号的 EDL"单独一支、另一台小米必须读成 absent）。它问的是：

> **有没有一台能 ssh 的 zl1？**

但这一次运行的**五个步骤里有三个会真的写设备**，而它们的**前置条件不止在设备上**。第 03 步是发烫链，
它自己的第 1 步是这样开头的（`install-netwatch-service.sh`，逐字）：

```
--ssh REQUIRES a verified misc backup rather than taking one. ... so it refuses, by name, with the
command that takes one.
```

而那个"verified"有四个条件（同一个文件里的 `misc_backup_ok()` 和它的 `SRC` 检查）：

```sh
[[ -s "$MISC_IMG" ]]                          || return 1   # 非空
[[ -f "$MISC_OUT/SHA256SUMS" ]]               || return 1   # 有校验文件
( cd "$MISC_OUT" && sha256sum -c SHA256SUMS ) || return 1   # 哈希还对得上
grep -q '^ensure_addrs()' "$SRC"              || return 1   # build 会配地址
```

**这四样没有一样在设备上。** 它们在 `/mnt/data/zl1-backups/` 和 `scripts/device/` 里，
也就是在**跑这条 runbook 的这台笔记本**上。所以"设备在不在"这个问题的答案完全可以是"在"，
而这次运行仍然在第 03 步撞墙——**在那之后**。

这就是这一轮要修的东西的形状：**一个前置条件被问了一半，而没被问的那一半更贵**，
因为它在**花了东西之后**才被问到。用一次手指换来的那次 boot 是这里唯一不能重来的东西
（`107`），所以"晚一步才发现"和"根本不能发现"在这里几乎是一回事。

---

## 3. 第一版是错的，而错法是这个项目刚记过的那种

第一版这样读那两个变量：

```sh
HOST_MISC_IMG=$(sed -n 's/^MISC_IMG="\(.*\)"$/\1/p' "$NW" | head -1)
```

跑真 installer 的结果是：

```
$ sed -n 's/^MISC_IMG="\(.*\)"$/\1/p' scripts/install-netwatch-service.sh | head -1
$MISC_OUT/misc.img
```

因为 installer 里那一行是：

```sh
MISC_OUT="/mnt/data/zl1-backups/2026-09-17-misc"
MISC_IMG="$MISC_OUT/misc.img"
```

bash 在赋值那一刻把 `$MISC_OUT` 展开了，所以**变量**里是完整路径；但**文件里的文本**是一个
**路径表达式**。用正则去"抄值"抄到的是表达式。于是那个检查会指着一个不存在的文件，
永远报"备份缺失"——**一个永远在喊狼来了的检查**，和永远通过的检查是同一个家族的反面。

修法是把两半分开读、而且**要求那个形式**：

```sh
HOST_MISC_OUT=$(sed -n 's/^MISC_OUT="\(.*\)"$/\1/p' "$NW" | head -1)
_img=$(sed -n 's|^MISC_IMG="\$MISC_OUT/\(.*\)"$|\1|p' "$NW" | head -1)
HOST_MISC_IMG=$([ -n "$_img" ] && [ -n "$HOST_MISC_OUT" ] && echo "$HOST_MISC_OUT/$_img")
```

而形式对不上时（比如 installer 改成 `MISC_IMG="${MISC_OUT}/misc.img"`），打的是：

```
the misc-backup paths could not be read out of ... (the MISC_OUT/MISC_IMG form it uses is not the one this reads)
```

——**说的是"读不出来"，不是"备份坏了"。** 这两个是不同的诊断，混在一起就会把操作者
打发去修一个没坏的东西。harness 里有专门一条断言这一句（§4 的第 6 个场景）。

---

## 4. 离线验证：95 → 118，以及"必须红"

新增的是 harness 的第 9b 节，它把**两个方向**都驱动一遍。夹具是**一个假的 installer**
（放在假仓库里，形式和真的一样），因为指向真 installer 会让每个场景的结论变成
"这台笔记本怎么样"，而 ready / broken 两支就不可能同时被测到——这一条在夹具旁边写着。

| 场景 | 期望 |
|---|---|
| 宿主齐备 | `--status` 和 `--yes` 都打出 `step 03's preconditions hold`，而且**照常往下跑**（`CALLEE CAPTURE` 在记录里） |
| `misc.img` 不见了 | `--status` 报 `step 03 CANNOT start on this host`；`--yes` **`exit 2`**，打出 `REFUSING, before anything ran`、文件全路径、以及**一条 callee 记录都没有**；archive 目录建了但**没有 `INDEX.txt`** |
| 备份在、但不是它自称的那个镜像 | 同上，理由必须是 `FAILS its recorded SHA256`——**不是**"文件不存在" |
| build 里没有 `ensure_addrs()` | 同上，理由必须点出缺的是哪个性质 |
| `--skip 03-heat-chain` + 坏宿主 | **不拒绝**，其余步骤照跑（这是宿主的问题，不是设备的问题，也不该挡住别的步骤） |
| installer 用了别的形式 | `exit 2`，且理由是**提取失败**而不是备份坏 |

**变异测试**（一个无法失败的 harness 什么也证明不了）：

| 变异 | 结果 |
|---|---|
| 把 runbook 里那段拒绝改成 `if false` | **18 条红** |
| 把 `sha256sum -c` 那一段删掉（只看文件在不在） | **4 条红**（`it exited 0` / `and the reason is the hash...` / `a step ran: CALLEE CAPTURE...` / 引用计数那条） |

第二个变异值得单独说一句：只删掉**校验和**、保留"文件存在"检查，红的正是那三条**关于哈希的断言**——
也就是说这一节测的不是"有没有做检查"，而是**做的是哪一个检查**。

---

## 5. 顺带修掉的两处（都是"页面说的和文件里的不一样"）

1. **`scripts/README.md` 里有四行的表格没闭合。** 这一轮加文字时发现的：runbook 那一行、
   `zl1-post-recovery-capture-selftest.sh` 那一行、`zl1-fp-store-dir-selftest.sh` 那一行、
   `install-fingerprint-store-dir.sh` 那一行都以内容结尾、**没有收尾的 `|`**（同一张表里其他行都有三个竖线）。
   GFM 允许省略首尾竖线，所以它**渲染得出来**——这正是那种"看起来没事"的缺陷，而其中两行是这一轮和上一轮
   我自己改过的。四行都补上了，并且在 meta-harness（`zl1-cli-usage-selftest.sh`，第 4 节 (d)）里加了一条机制检查：
   **两张 README 里每一行以 `| ` 开头的行都必须以 `|` 结尾**（不数竖线个数，因为 `tr | grep | sed` 这种
   行内代码里的竖线是内容，不是结构）。变异测试：把其中一行重新改成不闭合 → **红 1 条**。
   > 这条检查自己第一版是错的，而错法值得记：它用 `/^\| /` 和 `/\|[[:space:]]*$/` 两个 awk 正则，
   > 而**在 awk 的 ERE 里 `\|` 不是竖线**——它匹配到了不相关的行，报的是 `README.md:79`，
   > 而那一行是个没有竖线的项目符号。改成 `substr()` 之后才报对。**一个模式写错的检查会指名错误的文件**，
   > 比什么都不报更坏：它把读者送到一行没问题的代码上。
   > 顺着这一条还修了报告本身：两张 README **同名**，第一版打印的是 `basename`，所以 `scripts/README.md`
   > 里的缺陷被报成 `README.md:79`——**指错了文件**。现在打的是相对仓库的路径。
   > （这和 docs 103 是同一族："一条日志只属于包含它的进程"，一个报告必须指名它真正观察的那个东西。）
2. **`docs/ubuntu-touch/118` 的离线验证数字过期了**：它写着 `zl1-heat-fix-chain-selftest.sh`
   **95 检查 / 5 个变异**，而 `zl1-health-check.sh` 里那条引用写的是 **107 / 7 个变异**。
   两个数字都已改，并按 `125` 立的规矩**把旧数字留着**、把更正贴在旁边。
3. **`scripts/README.md` 里 `install-fingerprint-store-dir.sh` 那一行还写着 130 检查**，
   而 `126` 已经把那个 harness 改到 **137**。同一行改掉了（这一行正是同一轮里被漏掉收尾竖线的那一行，
   两处是同一处编辑的后果）。

---

## 6. 这一轮**不**证明什么

* **不证明 runbook 跑得通。** 完整链路**一次都没有在设备上跑过**；这一轮加的是一个
  **在设备不在时也能成立**的检查，所以它自己在设备上一次都没有执行过。
* **不证明宿主现在是齐备的——它只证明"怎么问"。** 顺带做的读数说这一台目前是齐备的
  （`/mnt/data/zl1-backups/2026-09-17-misc/misc.img` 存在、`sha256sum -c` 通过、源 build 有 `ensure_addrs()`），
  **但那是一次读数，不是一个保证**：`/mnt/data` 是可以变的，而这正是这个检查存在的理由。
* **不证明第 03 步只需要这四个条件。** 它读的是 installer 自己那两条拒绝，
  而 installer 还有别的拒绝（transport、misc 设备的字节数比对等）——这一轮**没有**把它们穷举完，
  只是把"未知的"从"最贵的那个位置"挪到了"最便宜的那个位置"。
* **不证明顺序变了。** 五个步骤的顺序和它们的理由一个字都没动（`124`）。

---

## 7. 设备状态与复现

整轮没有动设备：没有写任何分区或 boot，没有跑 QDL/QFIL，没有重启。设备仍在 **Qualcomm EDL**
（`05c6:9008`，port 3-3，无序列号）。识别目标一律按序列号 **`33e80afe`**；总线上另一台小米
**`4a2fe00b`** 必须忽略。恢复仍然只能靠**物理长按电源 10–20 秒**。

```sh
# 全部在宿主机上，不碰设备。
bash scripts/host/zl1-one-boot-runbook-selftest.sh          # 118 项

# 直接看那个检查现在怎么答（设备不在，所以它先在设备那关拒绝；--
# 宿主的结论在 --status 里是同一段代码）
grep -n 'host_for_step03' scripts/host/zl1-one-boot-runbook.sh

# 手动读一遍那三样（这只是一次读数，不是保证）：
sed -n 's/^MISC_OUT="\(.*\)"$/\1/p' scripts/install-netwatch-service.sh
( cd /mnt/data/zl1-backups/2026-09-17-misc && sha256sum -c SHA256SUMS )
grep -c '^ensure_addrs()' scripts/device/zl1-netwatch.sh      # 必须是 1

# 证明 harness 测的是这件事：在仓库里那份真 runbook 上做变异，跑完还原。
cp scripts/host/zl1-one-boot-runbook.sh /tmp/rb.bak
sed -i 's/^if wanted 03-heat-chain; then$/if false; then/' scripts/host/zl1-one-boot-runbook.sh
bash scripts/host/zl1-one-boot-runbook-selftest.sh            # 18 条红
cp /tmp/rb.bak scripts/host/zl1-one-boot-runbook.sh
```

| 文件 | 作用 |
|---|---|
| `scripts/host/zl1-one-boot-runbook.sh` | 改：新增 `host_for_step03()` 与它前面的提取；在**第 01 步之前**拒绝；`--status` 也报这一段 |
| `scripts/host/zl1-one-boot-runbook-selftest.sh` | 扩：95 → **118** 项；假 installer + 假的 misc 备份/build；第 9b 节六个场景两个方向 |
| `scripts/host/zl1-health-check.sh` | 改：runbook harness 的引用 95 → 118，并把"宿主侧前置"写进那段说明 |
| `scripts/README.md` | 改：runbook harness 的行 95 → 118；installer 行的宿主侧说明；**三行没闭合的表格** |
| `docs/ubuntu-touch/124-*.md`、`118-*.md` | 追记/更正：过期的检查数（数字留着，更正贴着写） |
| `docs/ubuntu-touch/127-*.md` | 本篇 |
