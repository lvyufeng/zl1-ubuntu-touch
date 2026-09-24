# 126 — 路径是被那个 stub "漏掉的一支"决定的，而没有人读过它答了什么

**日期**: 2026-09-24
**状态**: 本轮**没有碰设备**（设备仍在 Qualcomm EDL，见 §7）。这一轮做的是**交叉核对**的第三步：把
[`106`](106-the-fingerprint-fix-is-the-directory-nobody-created.md) 那个修复要创建的目录，拿**设备自己的读数**
去对，对出这个项目里第三次出现的同一个形状——**一条推理被写下来，读起来和一个读数一样**，
于是它进了结论表、进了 applier 的注释、还进了安装脚本的一个**常量**，而设备说的正好相反。

**接续**: [`106`](106-the-fingerprint-fix-is-the-directory-nobody-created.md)（那个修复）、
[`101`](101-which-directory-the-fingerprint-hal-is-handed.md)（"读 biometryd 自己 exec 的那个文件"这个修正）、
[`83`](83-the-fingerprint-einval-is-a-missing-directory.md)（根因）、
[`125`](125-the-device-read-those-four-things-already.md)（上一轮，同一个形状的第二次）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 发现了什么？ | `106`/`101` 认定的那条路径 **`/data/system/users/0/fpdata`** 是错的。设备上 biometryd 传的是 **`/data/vendor_de/0/fpdata`** |
| 为什么？ | 因为 `api_level` **不是 `""`**。v63 那个 stub 答 `ro.build.version.sdk`（硬编码 **28**），而**根本不认** `ro.product.first_api_level`；兜底被答了、第一选择没有，`api_level` = `"28"`，`atoi("28") = 28 > 27` |
| 关键的一句话说清楚 | **分支是"漏了一支"翻过去的，不是"答错了"翻过去的。** 那个 stub 的错误是**省略** |
| 读数在哪？ | 就在本仓库里，而且是设备侧探针自己打出来的：`tmp-post-recovery-20260924T013059Z/06-fingerprint.txt:19-22` |
| 两个读数一致吗？ | **不一致**，而且相反：biometryd 的读 = 28，容器（`vendor.img` build.prop，活体容器也一样）= 23。`101` 写的"两个读法一致，所以目标确定"两句都错 |
| 那个推理是从哪儿来的？ | 从"`/usr/bin/getprop` 是个 shell 脚本"——**形状**——推出"所以它什么都不答"。没有人执行过它 |
| 代码上有什么后果？ | 三处：探针的**注释**、安装脚本的 **`REL=/system/users/0/fpdata` 常量**（`--install` 的候选列表和 `--remove` 的 undo 都在用它）、以及两个 harness 的**默认夹具** |
| 离线验证？ | `zl1-fp-store-dir-selftest.sh` **137 / 0 / 2 SKIP**；`zl1-loc-fp-selftest.sh` **200 / 0**。变异测试见 §5，一共 **41 条红**落在两处 |
| 动设备了吗？ | **没有。** 读数是**别的 boot 留下的**，这一轮只是把它们读出来 |

---

## 2. 事实链，逐条给出处

### 2.1 那个 stub 答什么：设备的读数

```
$ sed -n '18,25p' tmp-post-recovery-20260924T013059Z/06-fingerprint.txt
== which of the two paths biometryd passes (its own rule: api_level <= 27 -> /data/system/users/0)
   biometryd execs /usr/bin/getprop -- a shell script (the v63 stub's shape), and it DOES answer (so the level below is a real read)
     ro.product.first_api_level -> <unset>
     ro.build.version.sdk      -> 28
   -> level 28 > 27: biometryd passes /data/vendor_de/0/fpdata/  (check THAT one above)
   the Android side, for cross-check only (biometryd never reads this):
     ro.product.first_api_level -> 23     [2026-06-07 vendor.img build.prop: 23]
     ro.build.version.sdk      -> 28
   -> DISAGREES with the reading above: biometryd will pass /data/vendor_de/0/fpdata, the device reports <=27.
```

这一份是探针**在设备上真跑过**留下的（`107` 那条命令的归档）。注意它是这台设备的**当前**读数，
不是本轮的推断：`first_api_level` 是 `<unset>`，`sdk` 是 `28`，判出来的分支是 `>27`，
而两个读数**明说 DISAGREES**。

### 2.2 那个 stub 的形状：为什么是"省略"

`50` 记过 v63 的 boot hook 把 UT 侧的 `/usr/bin/getprop` 换成一个 `/bin/sh` stub；`93` 又记过它连
`custom.*` 都没有。这次要看清的是它**有哪些支**：

```
ro.build.version.sdk       -> 28          <-- 有支，硬编码
ro.product.first_api_level -> <unset>     <-- 根本没有这一支
```

biometryd 的原式（`halium/biometryd/src/biometry/devices/android.cpp:590-598`）是

```cpp
api_level = store.get("ro.product.first_api_level"); if empty, store.get("ro.build.version.sdk");
if (atoi(api_level) <= 27) ... else ...
```

`?:` 只兜**空**，不兜"文件不存在"。所以第一支**被认了、答了空**，兜底支**被答了**，`api_level` 就是
`"28"`。它**不是**空字符串，`atoi("") = 0` 这条路根本没被走到。

### 2.3 于是"推理 vs 读数"的分界线在哪

`101` 和 `106` 写下的是一串**完全自洽**的推理：

> stub 是个 shell 脚本 → 它不回答属性 → 两次读都返回空 → `api_level` 空 → `atoi("") = 0` → 走 `<=27` →
> 路径是 `/data/system/users/0/fpdata` → 而 `vendor.img` 说 23，也是 `<=27`，**两个读数恰好在同一支**。

每一步都通，结论也具体、可执行、带着**两个**看似独立的支持（一个 stub 的形状 + 一个分区的 build.prop）。
问题是**中间那一步从来没有被执行过**：stub 到底答不答、答哪一支，是**可以读出来的**（执行一次，或者读
`boot.img` 里那份 hook），而它被"是个 shell 脚本"这个形状代替了。**形状能描述，不能下结论**——
`101` §4 自己写过这句话（第一版注释说"THE v63 STUB, so every read below is empty"，然后夹具换上一个会
答话的 shell script，它就一边这么说一边打印出一个值），而它自己的结论表里仍然留着同一个错误。

---

## 3. 为什么这不是"注释错了"这么轻

**因为那个常量被用在两个会写设备的地方。** 安装脚本里原来有：

```sh
REL=/system/users/0/fpdata
```

（`git show e259cc4^:scripts/install-fingerprint-store-dir.sh:98`，逐字。**这一行原本没有注释**——
理由不在代码旁边，而在两篇文档里，这也是它没被复核过的原因之一。）

`--install` 用它打印"将要创建哪一个"（`:440` 那一处）、`--remove` 用它打印"要撤销哪一个"（`:492`）。也就是说：**一次照着它执行的
安装会创建 `/data/vendor_de/0/fpdata` 之外的另一个目录**（`--install` 的 applier 是运行时推导的，所以真正
被创建的是**对**的那个；但 `--remove` 打印的 undo、以及 `--install` 显示给操作者的那条路径，都是**错**的
那一个）。一个 undo 指着一条从未被创建的路径，就是"看起来像一次干净回退，其实什么都没退"。

现在那个常量被**删掉了**，换成 `read_rel()`——**每次问设备**同一条规则，两个调用点都从它取：

```sh
read_rel() {
  "${SSH[@]}" 'G=/usr/bin/getprop
    api=$("$G" ro.product.first_api_level 2>/dev/null)
    [ -n "$api" ] || api=$("$G" ro.build.version.sdk 2>/dev/null)
    case "${api:-}" in ""|*[!0-9]*) api=0 ;; esac
    if [ "$api" -le 27 ]; then printf "/system/users/0/fpdata /vendor_de/0/fpdata"
    else printf "/vendor_de/0/fpdata /system/users/0/fpdata"; fi' 2>/dev/null | tr -d '\r\n'
}
```

设备不回答时它**打印一行说明**，而不是猜一个（猜一个正是这次的错法）。

---

## 4. 顺带被这个读数纠正的两件事

1. **"两张 /data 是同一棵树"是不成立的。** `101` §3.2 从 2026-09-16 的 `userdata.img` 读到
   `/data/vendor_de/0/fpdata` **存在**、`/data/system/users/0/fpdata` **不存在**；而 2026-09-24 设备上经
   HAL 自己的 mount namespace 读到的是**两个都 MISSING**（`06-fingerprint.txt:7-8`）。所以"哪条路径要建"
   **不能**从那张镜像表里推，只能从"biometryd 会传哪一个"里推。镜像表回答的是它自己的问题
   （"在一台启动过很多次的设备的 /data 里，这个目录在不在"），把它当成路径问题的答案是**越界使用一个读数**。
2. **`/data/gf_data` 那条结论没有受影响**：探针、镜像、活体读数三处都说它不在，那是 doc `98` 的第二个 store，
   和这次的路径问题无关。

---

## 5. 离线验证，以及"必须失败"

两个 harness 的**默认夹具**都曾经是**一台不存在的设备**：`ut_getprop_stub` 被写成"什么都不答"，
默认档位是 27。于是每个场景都跑在 `<=27` 那一支上，而断言里写着
`want '/data/system/users/0/fpdata' "$OUT" "and lists the path biometryd actually passes"`——
**这条断言是"通过"的，因为它测的是一台不存在的设备**。这和一个不可能失败的检查是同一族缺陷。

改法是把**设备**变成默认：`ut_getprop_stub` 现在就是那个 stub 的形状（答 `sdk`=28、不认
`first_api_level`），而"什么都不答的 getprop"是另一个夹具 `ut_getprop_silent`，要**按名字请出来**。

```
$ bash scripts/host/zl1-loc-fp-selftest.sh
pass=200 fail=0
$ bash scripts/host/zl1-fp-store-dir-selftest.sh
pass=137 fail=0 skip=2 (device facts, named above)
```

**变异测试**（一个无法失败的 harness 什么也证明不了）：

| 变异 | 结果 | 说明 |
|---|---|---|
| 探针里把分支判据从 `-le 27` 改成 `-gt 27`（路径与理由一起反） | **20 条红** | 断言真的有牙 |
| 把默认夹具换回"什么都不答的 getprop" | **13 条红** | 夹具本身是承重的，不是装饰 |
| 安装脚本里把路径**写死** | **7 条红**（`rc=2`） | 与 `106` §8 那张表里的同一行一致；`rc=2` 是因为 harness **自己那个**"把规则换成常量"的变异 sed 再也匹配不上（同一个代码块被我先改了），它**拒绝装作变异成功了**——`the hardcoded-path fixture did not land` |
| 把 `read_rel()` 换回常量 `/system/users/0/fpdata` | `136 pass / 1 fail`，精确落在 `printing the exact undo, as a DEVICE path` | 这一条就是为它写的 |

前两个变异跑在 `zl1-loc-fp-selftest.sh` 上、后两个在 `zl1-fp-store-dir-selftest.sh` 上；探针那个变异是在
**仓库里那份真文件**上做的，用 `trap` 从 `/tmp` 备份还原（把整棵树拷出去跑会让 harness 找不到它按相对路径
解析的被调用脚本——这一点 `99`/`125` 也踩过）。

`zl1-loc-fp-selftest.sh` 的检查数 195 → **200**，`zl1-health-check.sh` 里那条引用随之更新（它自己会红着
告诉你数字不对，这正是它存在的理由）。

---

## 6. 这一轮**不**证明什么

* **对设备的结论：零。** 设备在 EDL；那个写（`--install`，即创建目录）**一次都没有做过**。
  这一轮说的是"**会**创建哪一个、为什么"，而这个仍然是从**归档的读数**里问出来的，不是这一轮量的。
* **不证明指纹能用了。** 路径对了只是 `83` 三处静默里的第一处有了正确的目标；`/data/gf_data`、`gx_fpd`、
  最里面那层 HAL（`98`）和 `libQSEEComAPI.so`（`64`）一个字都没动。
* **不证明那个 stub 永远答 28。** 它是 v63 boot hook 每次开机装的；`sdk` 那个 28 是硬编码的，所以只要
  这个 hook 还在，答案就是 28。**正因为它是"每次开机重新推导"，这个修复才不需要跟着再改一次。**
* **不证明 2026-09-16 那张 `userdata.img` 读错了。** 它读的是它自己那棵树；错的是**拿它去定路径**。

---

## 7. 设备状态与复现

整轮没有动设备：没有写任何分区或 boot，没有跑 QDL/QFIL，没有重启。设备仍在 **Qualcomm EDL**
（`05c6:9008`，port 3-3，无序列号）。识别目标一律按序列号 **`33e80afe`**；总线上另一台小米
**`4a2fe00b`** 必须忽略。恢复仍然只能靠**物理长按电源 10–20 秒**。

```sh
# 全部在宿主机上，不碰设备。
sed -n '18,25p' tmp-post-recovery-20260924T013059Z/06-fingerprint.txt   # 本节 §2.1 那份读数

bash scripts/host/zl1-loc-fp-selftest.sh              # 200 项
bash scripts/host/zl1-fp-store-dir-selftest.sh        # 137 项 / 2 SKIP

# 证明 harness 测的是这件事：在仓库里那份真探针上做变异，跑完还原。
cp scripts/device/zl1-fingerprint-probe.sh /tmp/fp.bak
sed -i 's/"\$lvl" -le 27/"$lvl" -gt 27/' scripts/device/zl1-fingerprint-probe.sh
bash scripts/host/zl1-loc-fp-selftest.sh              # 20 条红
cp /tmp/fp.bak scripts/device/zl1-fingerprint-probe.sh
```

回到 RNDIS 之后，指纹这一步的顺序**没有变**（`106` §11）：先跑 `device/zl1-fingerprint-probe.sh` 拿到
安装**前**的 "目录 MISSING"，再 `scripts/install-fingerprint-store-dir.sh --status` → `--install`，
然后回探针看 `setActiveGroup failed` 的计数有没有归零。**不同的是现在它会盯着 `/data/vendor_de/0/fpdata`**，
而 `--status` 会在磁盘上是另一个目录时说 DISAGREE——那正是这次改正留下的可检查项。

| 文件 | 作用 |
|---|---|
| `scripts/install-fingerprint-store-dir.sh` | 修：删掉 `REL` 常量、加 `read_rel()`（`--install` 的候选与 `--remove` 的 undo 都走它）；头部注释、`--explain`、落地 applier 的注释改成读数 |
| `scripts/device/zl1-fingerprint-probe.sh` | 修：`msm8996.so` 那段注释（它硬编码的 `/data/system/users/0/fpdata/` 只在那条路径是 `<=27` 时才等于 biometryd 传的）；section 2 的前言改成"漏了一支" |
| `scripts/host/zl1-loc-fp-selftest.sh` | 修：默认夹具改成设备的 stub 形状（195 → **200** 项），`ut_getprop_silent` 成为另一个夹具，§7/§8 的断言改指 `vendor_de`，新增"不一致"与设备形状两个场景 |
| `scripts/host/zl1-fp-store-dir-selftest.sh` | 修：默认夹具同理，`TARGET`/`OTHER` 翻过来（130 → **137** 项） |
| `scripts/host/zl1-health-check.sh` | 改：item 3 的指纹建议改成"**哪一条路径是一个读数**，不是一个常数"；两处引用数更新 |
| `docs/ubuntu-touch/101-*.md`、`106-*.md` | 更正块：旧句子留着，改正贴着它写（见 `125` 立的规矩） |
| `docs/ubuntu-touch/126-*.md` | 本篇 |
