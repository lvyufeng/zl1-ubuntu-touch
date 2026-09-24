# 151 — 那个被写成「离线看不到」的问题，答案一直在这台笔记本上

**日期**: 2026-09-24
**状态**: 本轮**没有碰设备**。全部在 host 侧：把 [`120`](120-the-subsystem-nobody-has-looked-at.md) 的 §3 第 3 条
——"设备上那份 halium 的 Android ramdisk 有没有 fstab"——**离线读了出来**。
新工具 `scripts/host/zl1-modem-mount.sh` 与它的 harness（**64 项**）。**没有挂载、没有写镜像、没有 flash、
没有在设备上跑过任何东西**；设备仍在 fastboot（序列号 `33e80afe`）。

**为什么值得单独一页**: [`120`](120-the-subsystem-nobody-has-looked-at.md) 把整个 modem 的故事收成**一条机制**
（halium 的 mount 循环读一个 glob，`cat` 失败，循环体一次都不执行，**一声不响**），然后把它唯一缺的那个读数
**归给设备**。这一页证明那个归属是错的——而错的代价不是"多跑一次设备"，是**这条链路上最贵的一个问题被推迟到了
一次用一根手指买来的 boot 上**，而那次 boot 还要同时付散热、指纹、摄像头的账。

**接续**: [`120`](120-the-subsystem-nobody-has-looked-at.md)（modem 的全部离线读数与那个假说）、
[`150`](150-the-gate-the-rest-of-the-project-waits-behind.md)（那次 boot 的闸门）、
[`124`](124-the-boot-a-finger-bought-is-one-command.md)（那次 boot 是怎么被花掉的）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| doc 120 把什么归给了设备？ | "解出来那棵树的根"离线看不到（它在 halium 的 system 镜像里），所以"那份 ramdisk 有没有 fstab"**只能**在设备上 `ls` |
| 为什么这是错的？ | 因为**那个 ramdisk 就在这台笔记本上**：它是 Android system 镜像里的 `/boot/android-ramdisk.img`，而那份镜像正是**被 push 到手机 `/data/system.img` 的同一个 4 GB 文件** |
| 读数是什么？ | **65 个条目，一个都不是 fstab。** 于是 glob `/var/lib/lxc/android/rootfs/fstab*` 展开成空、`cat` 失败、`while read` 的循环体**一次都不执行**——**一件都不挂，而且一声不响** |
| 这是假说 (a) 吗？ | 是。**假说 (a) 成立，而且它现在是一条离线可复现的读数，不是一条推论** |
| 这算"关于手机"的结论吗？ | **不算**，而且脚本自己明说。它是关于**两个镜像文件**的结论；设备上那句确认仍是 doc 120 已经写好的那条 `ls`（期望 0） |
| 修了吗？ | **没有。**两条修法都在脚本里点了名，**一条都没做**——两条都是设备侧的写，是人的决定 |
| 离线验证？ | `zl1-modem-mount-selftest.sh` **64 检查 / 0 失败**；fixture 是**真的镜像**（gzip 过的 cpio + `mke2fs -d` 造的 ext4） |
| 动设备了吗？ | **没有。**设备仍在 fastboot |

---

## 2. 机制不是转述的，是从 boot image 自己嘴里引出来的

这一页最容易犯的错是**复述** §120 那张流程图。所以脚本做的事是：**打开这个项目要 flash 的那张 boot image**
（默认 `halium-boot-zl1-v63-rebuilt.img`），解出它的 initrd（gzip 的 cpio），把里面的 `scripts/halium`
**原文取出来，带行号打印**。读数（`141` / `151` / `577` / `626` 四行）：

```
141:	fstab=$1
145:	tell_kmsg "checking fstab $fstab for additional mount points"
151:	cat ${fstab} | while read line; do
626:		mount_android_partitions "${rootmnt}/var/lib/lxc/android/rootfs/fstab*" ${rootmnt}/android ${rootmnt}/userdata
```

三件事都在这一小段里，而且**没有一件是解释出来的**：

1. `fstab=$1`，而调用点传进来的**是一个 glob**（`.../rootfs/fstab*`）——**glob 在赋值时不展开，在
   `cat` 的时候才展开，而且是不加引号的**。
2. 唯一的消费者是 `cat ${fstab} | while read line`。**一个匹配不到任何文件的 glob 会让 `cat` 打出错误、返回
   非零、并且什么也不打印**，于是循环体——那次 `mkdir` 和那次 `mount`——**一次都不执行**。
3. **没有 else 分支，也没有任何消息**。所以"fstab 是空的"和"fstab 不存在"在日志里是**同一片安静**。
   这一条正是这个工程反复在写的形状：**一个静默的、彻底的空缺，看起来和正常一模一样**。

它打印两个调用点，是因为那里有**两个** glob：`${rootmnt}/fstab*`（第 577 行，Android 自己的分区）和
`626` 那一行（容器的那份）。**modem 那一条走的是第二个**。

---

## 3. 读数：65 个条目，一个 fstab 都没有

第二段做的是这一页的全部意义：`debugfs -R dump`（**只读**，从不 `-w`）把 system 镜像里的
`/boot/android-ramdisk.img` 解到临时目录，然后**走它的 cpio**。

```
  the ramdisk: 2060050 bytes, extracted read-only with debugfs
  entries in it: 65

  every entry whose NAME contains fstab:
    (none -- and that is the reading, not an empty list to scroll past)
```

**而那棵树的根**（§3）让这件事变得具体——ramdisk 根目录里那四个名字，一个是真目录、三个是指向它下面的软链：

```
    bt_firmware    symlink -> /vendor/bt_firmware
    dsp            symlink -> /vendor/dsp
    firmware       symlink -> /vendor/firmware_mnt
    vendor         directory
```

**那个 `vendor` 是一个真目录，而且是空的。** 它就是**这次缺失的挂载本来要挂上去的地方**——
`/vendor/firmware_mnt` 是容器里 kernel 那条 `firmware_class.path=/vendor/firmware_mnt/image`
最终解析到的位置（doc 120 §2）。所以这张表不是两张无关的读数摆在一起：**一边是缺失的那个挂载的目的地，
一边是它的收件人**。

至于 `/var/lib/lxc/android/rootfs`：**在 UT 的 rootfs 镜像里它是空的**，而这不是缺陷——boot 的时候
halium 会把解出来的 ramdisk `mount --move` **盖在它上面**，所以镜像里放什么都看不见。脚本把这一条也印出来，
因为"空目录"和"被盖住的目录"是两件事，而它们的读法看起来一样。

---

## 4. 为什么 doc 120 会把它归给设备

`grep` 一下 120 就能看见那个推理链——**每一步都对，只有最后一步是坏的**：

1. 设备 `/boot` 里那份 ramdisk 的 cpio 清单被过了一遍，**没有 `fstab*` 条目**（顺带一个与本篇无关的读数：
   那份 `/boot` 是第三方 MIUI 的 ROM）。**这一步是对的。**
2. 但 halium **真正**解的那份 ramdisk 不在 `/boot`，在 halium 自己的 system 镜像里
   （`/android-system/boot/android-ramdisk.img`）。**这一步也是对的。**
3. 于是结论写成："那一份**离线看不到** —— 所以'它有没有 fstab'是**设备上一条 `ls` 的事**"。
   **这一步是错的**：那份 system 镜像**就在这台笔记本上**，而且它不是一份无关紧要的副本——
   它就是**被 push 到手机 `/data/system.img` 的那个文件**（doc 21；restore 脚本点的是同一条路径）。

所以真正发生的是一次**可见性的错位**：第 1 步证明了**A 不在设备 `/boot` 里**，第 3 步把 A 的可见性
推给了**设备**，而 A 其实一直躺在这台机器上，一个 `debugfs` 之外什么也不需要。

这类错误的形状值得记下来：**"我看的是另一个文件"被写成了"这个问题看不到"**。
两句都像`我查过了`，而只有前一句是真的。

---

## 5. 判定表：四个状态，三个是答案

和这一轮其他仪器一样，结论**不是 yes/no**。因为"没有 fstab"、"有 fstab 但没写这一行"、"有 fstab 而且写了"
和"读不了"是**四件不同的事**，只有最后一件不是答案：

| 状态 | 判据 | 含义 |
|---|---|---|
| `THE LOOP IS EMPTY` | ramdisk 里没有名字含 `fstab` 的条目 | **本次的读数**：循环空转 → 一件都不挂 → 静默 |
| `NO LINE FOR THE MODEM` | 有 fstab，但没有任何一行匹配 `firmware_mnt\|modem\|/vendor` | 循环**跑了**，但没挂这件事——**同一个安静，另一条路线** |
| `A LINE FOR THE MODEM IS THERE` | 有 fstab 而且写了那一行 | 问题**移动了一格**：变成那一次挂载本身（设备节点、文件系统类型、选项），而那是设备上的读数 |
| `UNREADABLE` | 某个输入读不了 | **什么都不主张**（exit 3） |

第二种状态里脚本做了一件小但重要的事：它**把文件里真正有的行全印出来**。
因为"什么都没匹配上"和"什么都没读到"在输出上长得一模一样，而它们的结论相反。

`UNREADABLE` 有**两条**触发路径，而且两条都在**任何结论之前**：boot image 里没有 cpio 成员携带
`scripts/halium`、或者 system 镜像里没有可读的 `/boot/android-ramdisk.img`。
第二种尤其重要——**那说明这个镜像不是 halium 从中解 ramdisk 的那个**，所以这里的一切**不是关于这台设备跑的那次 boot
的读数**。这本身是一条发现，但它是**关于镜像的**，脚本明说这一层区分。

---

## 6. 写这个脚本时踩到的四个坑（都是"不报错的错"）

这一页的工具和这个工程其他工具一样，**第一次写就是错的**，而且**四个错误里有三个的共同点是"不会失败，
只会给出一个看起来正常的读数"**：

1. **cpio `newc` 的对齐规则。**NUL 是跟着**路径名**补的，好让 **(110 字节的定长头 + 路径名)** 是 4 的倍数；
   数据部分独立补到 4。第一版把这条规则用在了**路径名**上，结果是：**不报错，返回一个只有一条目的清单**。
   这也正是这个页面的主题在同一份代码里的复现——**一个错的结果看起来像一个正常的结果**，
   而这次它只是让 `grep fstab` 什么都没匹配到，也就是**恰好和真正的答案一样**。修法是把
   `data_off(namesize) = 110 + namesize + pad` 写成一个函数，让三处（找 `scripts/halium`、列条目、
   取 fstab 内容）**共用同一个算式**。
2. **`TRAILER!!!` 是结束标记，不是条目。**把它数进去会让条目数**多 1**，而读者看不出来。
3. **`lstrip('./')` 会把根条目 `.` 变成空串**（`lstrip` 吃的是字符集，不是前缀）。要用 `startswith('./')`
   然后切片——同一个坑这棵树在别处也踩过。
4. **`debugfs -R cat` 不跟随软链。**rootfs 里 `/vendor` 是软链，`cat` 打印不出东西；要读它必须用
   `stat`，而 `stat` 把**快速软链的目标**单独印在 `Fast link dest:` 这一行上。第一版在这里印的是 `?`,
   也就是**一个报不出话的检查**。现在读出来的是 `"/android/vendor"`。

---

## 7. 这一篇**不**证明什么

* **不证明这台设备上的 modem 是坏的或好的。**它是关于**两个镜像文件**的结论。那份镜像**是**这个项目
  staged 的、也是**被 push 上去的那一份**，但"镜像里的东西"和"设备上跑的东西"之间永远隔着一个 boot。
* **不证明设备上那份 `/data/system.img` 和这里读的是同一个文件。**这正是脚本把设备侧确认写成**一句可数的
  命令**的原因（doc 120 已经写好、探针第 3 节已经在做的那条）：
  `ls -l /var/lib/lxc/android/rootfs/ | grep -c fstab`，**期望 0**。
  哪天它读到非 0，那不是矛盾，**那就是发现**：手机上的镜像不是这里读的镜像。
* **不证明 (b) 不成立。**doc 120 的假说 (b) 是"挂了，但挂在容器的 mount namespace 里"。这一页只回答了 (a)，
  而且 (a) 成立**并不排除** (b)——它们可以同时为真，而 (b) 只能设备上量。
* **不证明两条修法里哪条对。**脚本点了名（给 ramdisk 一个 fstab，是一次 **userdata 侧的写**——
  不是关键分区，但意味着重写一个容器要从它启动的 4 GB 镜像；或者让 boot 脚本不再依赖那个文件，
  是一次 initrd 改动，即一次 `fastboot flash boot`，这个项目已经在例行做而且能回滚），
  **一条都没做**，因为两条都是设备侧的，是拿着设备的人的决定。
* **不证明它没写过东西。**这一条由 harness 的**静态**那一节保证：`debugfs -R` 而**从不** `-w`、
  没有 `mount`、没有 `fastboot`、没有 `dd of=`、没有下载器的名字；而且 `mount` / `fastboot` **确实**出现在
  脚本里（在**禁止它们的那些散文**里），所以那一节不是 grep 一次就算——**每一处出现都被检查是不是在注释或
  打印字符串里**。

---

## 8. 离线验证：64 检查，fixture 是真的镜像

`scripts/host/zl1-modem-mount-selftest.sh`，**64 检查 / 0 失败**。

fixture **不是文本文件**：一份真的 gzip 过的 cpio（由一个 `cpio.py` 助手写出来），和一份真的 **ext4**
（`mke2fs -F -q -t ext4 -d` 造）。用一个全是文本文件的 fixture 去测这两个 parser，**两个都不算被测到**。

| 节 | 什么 |
|---|---|
| 1 | 每个判定状态一个 fixture：**空循环**（本次读数）、**有 fstab 但没这一行**、**有 fstab 且写了这一行** |
| 2 | **两条 `UNREADABLE`**：boot image 里没有 `scripts/halium`、system 镜像里没有 ramdisk——两条都要求**什么都不主张**（不是"读成 disabled"那种把缺件读成否定） |
| 3 | **独立的 cpio 走查**：harness 自己再实现一遍，**要求它和被测对象的条目数一致**；而且**要求 fixture 的条目数明显大于一把**，否则"两边一致"可能只是**两个 1** |
| 4 | rootfs 里一个有真软链的 `/vendor`，保证第 4 节**是被读的**而不是被跳过的 |
| 5 | **三个变异**（每个都真的跑过）：**对齐规则**、存在性判定、内容判定。第一个就是这份工具**真的犯过**的那个错 |

对齐那条变异有一个细节值得写下来：**同一个助手也用来走 boot image**，所以这个变异体通常的签名是
`UNREADABLE: the boot image has no cpio member`——在它走到条目数之前就已经出局。检查**接受两个签名**，
而不是把"变异体被更早的一步挡住了"**算成一次通过**。**一个因为它没跑到而被判过的变异，什么都没证明。**

那个"两边一致"的要求也不是形式：**一个错的对齐规则返回的是 1 个条目**，而一个独立的走查在没有这一条时
**也可以返回 1**。所以检查里额外钉了一条：**fixture 的条目数必须大于一把**，让"两个 1"不能冒充一致。

**家族全量跑**：**34 个 harness / 4623 检查 / 全绿**，仓库自指纹未变（**457 个 tracked 文件**前后哈希一致——
这一页的四个新文件已经 `git add`，所以它们**也在这道指纹里**，而不是站在它外面）。
这一页新增的是**第 34 个** harness（64 项）。`scripts/README.md` 与健康检查的**每 harness 计数必须一致**
那一条也仍然成立（现在比 **29** 行）。

---

## 9. 设备状态与下一步

整轮**没有动设备**：没有挂任何镜像（连只读挂载都没有）、没有写任何镜像、没有 flash、
没有在设备上跑过任何命令。设备仍在 **fastboot**（序列号 `33e80afe`，`battery-soc-ok: no`）。

这一页把 doc 120 留给设备的那**一个**读数拿回来了，所以下一次 boot 上 modem 的账目变成了：

```
# 这条现在是"确认"，不再是"发现"——期望 0
ls -l /var/lib/lxc/android/rootfs/ | grep -c fstab
```

**而它现在要确认的是一条离线已经量到的机制**，所以它可以和那一次 boot 的其他账（散热、指纹、摄像头）
一起读，而不必再占一次。两条修法都还在桌上，**都还没做**——它们是设备侧的写，是拿着设备的人的决定。

出来之后仍然是**一条命令**（doc 124）：

```
scripts/host/zl1-one-boot-runbook.sh --status     # 只读：这个 boot 上还剩什么没做
scripts/host/zl1-one-boot-runbook.sh --yes        # 五步，按唯一能成立的顺序
```

而在这之前，想重跑这一页的任何一条读数，**一个设备都不需要**：

```
bash scripts/host/zl1-modem-mount.sh              # 全部读数
bash scripts/host/zl1-modem-mount.sh --quiet      # 只要判定那一行
bash scripts/host/zl1-modem-mount-selftest.sh     # 64 检查
```
