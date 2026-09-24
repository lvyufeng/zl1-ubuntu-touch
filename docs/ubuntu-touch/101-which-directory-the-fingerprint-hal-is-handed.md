# 101 — 指纹 HAL 拿到的是哪个目录：在镜像和源码里问完，不用问设备

**日期**: 2026-09-23
**状态**: 纯离线的一轮（设备在 EDL，`05c6:9008` / port 3-3，与 `86`–`100` 同）。这一轮第一次把指纹那条链的**两个前提**从**真镜像**里问出来，并且发现**决定这件事的那段代码读错了进程的属性**——修掉了，并让 harness 从 110 项长到 **124 项**。设备整轮没有测量。

**接续**: [`83`](83-the-fingerprint-einval-is-a-missing-directory.md)（`SYS_EINVAL` 是一个缺失的目录）、[`98`](98-the-fingerprint-chain-has-two-more-layers-under-the-wrapper.md)（包装 HAL 底下还有两层、两个 store、三处静默）、[`97`](97-both-hardware-probes-write-the-wrong-thing.md)（两个探针写错过地方）、[`100`](100-the-other-half-of-the-heat-fix-and-the-only-misc-backup.md)（上一轮）。证据原文在 `docs/ubuntu-touch/evidence/fp-store-path-2026-09-23.log`。

> **2026-09-24 更正（[`126`](126-the-path-was-decided-by-what-the-stub-omits.md)）：本篇的中心结论有一半是错的，而且错法是这个仓库最贵的那一种——一个推理被写下来，读起来就像一个读数。**
> 本篇说 `api_level` 是 `""`（因为"两次读都返回空"），说 biometryd 走 `<=27`，说它传
> **`/data/system/users/0/fpdata/`**，还说两个读法**一致**所以目标确定。**设备自己的回答不是这样**：
> v63 那个 stub **不是哑的**——它有 `ro.build.version.sdk` 这一支（硬编码 28，就是 doc 50 那次改动），
> 而 `ro.product.first_api_level` **一支都没有**。于是第一选择没答、兜底答了，`api_level` 是 **`"28"`**，
> `atoi("28")=28 > 27`，biometryd 传的是 **`/data/vendor_de/0/fpdata/`**；而容器说 23，**两个读数是不一致的**。
> 读数是 2026-09-24 设备侧探针的归档输出（`tmp-post-recovery-20260924T013059Z/06-fingerprint.txt:19-22`：
> `first_api_level -> <unset>`、`sdk -> 28`、`level 28 > 27`），而本仓库里早就有它——**"两次读都返回空"这句话，
> 从来没有人读过，是从 stub 是 shell 脚本这个形状推出来的**。
> 连带被推翻的还有三处：§3.2 那张表（它拿 2026-09-16 的 `userdata.img` 读到 `/data/vendor_de/0/fpdata`
> **存在**，而 2026-09-24 设备上经 HAL 自己的 mount namespace 读到的两个路径**都不是 EXISTS**——
> 两张 /data 不是同一时刻的同一棵树，能定路径的只有 biometryd 自己会传哪一个）；§4 那条
> `-> AGREES with the reading above (both <=27)` 的示例输出（真机打的是 `DISAGREES`）；
> 以及"老代码碰巧对"这个判断——**老代码在这台设备上是错的**，不是碰巧对：它读容器的 23 会去建
> `/data/system/users/0/fpdata`，而 biometryd 会传 `/data/vendor_de/0/fpdata`。
> 修法见 126：探针的判定没变（仍然是"读 biometryd 自己 exec 的那个文件"），变的是**关于那个文件答了什么的
> 事实**，以及由它推出的路径、以及 harness 的默认夹具（它和本篇一样，把 `<=27` 和 `/data/system/users/0/fpdata`
> 当成了真机的形状）。本篇下面**没有改掉的旧句子都留着**，因为"推理读起来像读数"这件事本身要看得见。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 这一轮回答了什么？ | 指纹链的**第一个前提**：biometryd 交给 HAL 的 store 路径是**哪一个**、**为什么是它**、以及**它到底存不存在** —— 三件事全部在宿主机上用真镜像和源码问完 |
| 怎么问的？ | `userdata.img`（26 GiB，`/data` 整分区）和 `vendor.img`（2026-06-07 备份）只读挂载，加上 `halium/biometryd` 的源码 |
| biometryd 传哪个路径？ | ~~**`/data/system/users/0/fpdata/`**~~ → **`/data/vendor_de/0/fpdata/`**（2026-09-24 更正，见上；stub 答了兜底、没答第一选择） |
| 为什么是它？ | 因为 `api_level = 28 > 27`。~~而 `api_level` 是 `""`~~ —— 见上，**原句是从 stub 的形状推出来的，不是读出来的**；设备上它是 `28` |
| 那句 `>27` 是怎么来的？ | `biometryd` **不读 Android 属性区**：它 `exec("/usr/bin/getprop", {key})`（`property_store.cpp:26`）—— 一个**绝对路径**，指向 UT 侧那个二进制，而它在每个启动都被 v63 boot hook 换成一个 `/bin/sh` stub（docs 50、93）。那个 stub 答 `ro.build.version.sdk`（硬编码 28）而**根本不认** `ro.product.first_api_level`，于是兜底被答了、第一选择没有，`api_level` 是 `"28"`，走 `>27` 分支——**分支是"漏了一支"翻过去的，不是"答错了"翻过去的** |
| 真值是什么？ | `vendor.img` 的 `build.prop` 里 **`ro.product.first_api_level=23`** → `23 <= 27` → **同一个路径** |
| 所以两个读法矛盾吗？ | ~~不矛盾~~ → **矛盾**：biometryd 的读是 28，容器的是 23，落在**不同的**两支。所以目标确定**不是因为两个读数一致**，而是因为只有 biometryd 自己那个读算数（它从不读容器的 getprop） |
| 那个目录存在吗？ | **不存在**。真镜像里 `/data/system/users/0` 存在且**空的**（没有 `fpdata`），`/data/gf_data` 也不存在，而 `/data/vendor_de/0/fpdata` **存在**（`drwx------ system:system`，也空的） |
| 这证实了什么？ | `83` 的"EINVAL 是一个缺失的目录"**成立**：那个目录确实不在，而且是在一台已经启动过很多次的设备的镜像里不在；`98` 的第二个 store 也是**真的不在**——两处静默是**两次真实的缺失**，不是同一次的两个说法 |
| 抓到什么缺陷？ | 探针的 section 2 问的是**容器的** `/system/bin/getprop`，而 biometryd 读的是**UT 侧的** `/usr/bin/getprop`。在真机上两边都 `<=27`，所以老代码**碰巧**对；一旦 UT 侧的 getprop 能答出 `>27`，它就会**很有把握地报出错的路径**——而 section 6 只写那一个目录，undo 也只撤销那一个 |
| 怎么修的？ | 读 **biometryd 自己执行的那个二进制**，把 `<=27` 的理由说成 biometryd 的（"它自己的读是空的"），再把容器的值作为**交叉核对**打印出来，并**明确说出两边一致还是不一致** |
| 怎么证明 harness 有牙？ | 同一份 harness 对着 `HEAD` 的探针：**13 条红，全是同一个缺陷的侧面**，其中两条是"容器说 29 但 UT getprop 是桩 → 应该建 `<=27` 那个路径"和"不是容器那个值暗示的路径（老探针的答案）" |
| 动设备了吗？ | 没有。两个镜像只读挂载（`noload`）、没有写任何东西、没有 QDL/firehose、没有重启 |

---

## 2. 缺陷的形状：问错进程的属性

老代码（`HEAD`）：

```sh
fal=$(nsenter -t "$A" -p -- /system/bin/getprop ro.product.first_api_level 2>/dev/null | tr -d '\r')
sdk=$(nsenter -t "$A" -p -- /system/bin/getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')
lvl=${fal:-$sdk}
case "$lvl" in
  ''|*[!0-9]*) TARGET=/data/system/users/0/fpdata ;;   # atoi("")=0
  *) [ "$lvl" -le 27 ] && TARGET=/data/system/users/0/fpdata || TARGET=/data/vendor_de/0/fpdata ;;
esac
```

问的是**容器**的属性区，而 biometryd 的 `store.get` 是：

```cpp
core::posix::ChildProcess getprop = core::posix::exec("/usr/bin/getprop", {key}, {}, core::posix::StandardStream::stdout);
```

一个**绝对路径**，指向 UT 侧那个二进制。

> **2026-09-24 更正（[`126`](126-the-path-was-decided-by-what-the-stub-omits.md)）：下面这一段的出发点是错的。**
> 它说"真值 23 和空值都 `<=27`，所以老代码对了"——**老代码在这台设备上是错的**。UT 侧的 stub 答 28，
> biometryd 走 `>27`，而老代码读容器的 23 会去建 `<=27` 那个路径：一个不会被任何东西读到的目录，
> 外加一条只针对它的 undo。所以这不是"一个只在特定巧合下正确的判断"，而是一次**会真的写错的判断**，
> 只是从没有人把那个 stub 答了什么读出来过。这一段留着，因为它的推理形状仍然是对的——
> 只是它的第二个前提从未被验证。

它在两种情况下会变成错的，而且都是很正常的设备：

* UT 侧 getprop **不是**桩（比如 v63 hook 没装上，或换了 image），且设备 `first_api_level > 27` → biometryd 走 `>27` 分支，探针去建 `<=27` 那个目录；
* 反过来，UT 侧 getprop 是桩而设备 `>27` → biometryd 走 `<=27`（因为读不到），老探针读容器的 `>27` 去建 `vendor_de` 那个目录。

第二种就是 harness 现在的场景，而它证明的不只是"路径不一样"——**section 6 会真的去 `mkdir` 那个不会被任何东西读到的目录，然后打印一条只针对它的 undo**，也就是说：一次"成功"的写入，什么都没修，还留下一行看起来像修好了的输出。

---

## 3. 两个前提，从镜像里读出来

### 3.1 真值：`ro.product.first_api_level = 23`

```sh
$ sudo mount -o ro,noload,loop /mnt/data/zl1-backups/2026-06-07-adb-root-staged/vendor.img /mnt/vendor-ro
$ sudo grep -E 'first_api_level|board.platform|product.board' /mnt/vendor-ro/build.prop
ro.board.platform=msm8996
ro.product.board=msm8996
ro.product.first_api_level=23
```

顺带一提，`ro.hardware` **不在**这个 `build.prop` 里——这正是 doc 98 从库里读出的 `hw_get_module` 变体顺序会落到 `ro.product.board=msm8996` 的原因。两篇文档在这里对上了。

### 3.2 目录到底在不在：`userdata.img`

```sh
$ sudo mount -o ro,noload,loop /mnt/data/zl1-backups/2026-09-16-recovery-supplement/userdata.img /mnt/udata-ro
$ sudo ls -ld /mnt/udata-ro/system/users/0{,/fpdata} /mnt/udata-ro/vendor_de/0/fpdata /mnt/udata-ro/gf_data
ls: cannot access 'system/users/0/fpdata': No such file or directory
ls: cannot access 'gf_data': No such file or directory
drwx------. 2 1000 1000 4096 Apr 25  1970 system/users/0
drwx------. 2 1000 1000 4096 Apr 25  1970 vendor_de/0/fpdata
```

| 路径 | 状态 |
|---|---|
| `/data/system/users/0` | 存在，`drwx------` `system:system`，**空的** |
| `/data/system/users/0/fpdata` | **不存在** ← ~~biometryd 传的~~、HAL `access()` 的**不是**它（2026-09-24 更正，见 §0 的更正块） |
| `/data/vendor_de/0/fpdata` | 存在，`drwx------` `system:system`，**空的** ← **这张像里它存在，而 biometryd 传的是它；2026-09-24 的活体读数里它和上面那条一起 MISSING**（两张 /data 不是同一棵树的不同时刻，见下） |
| `/data/gf_data` | **不存在** ← 最里面那个 Goodix HAL 自己的 store |

这是这几条路径**第一次被对着真镜像核过**。结论有两条，都很收敛：

1. **doc 83 成立**：那个目录确实不在。而且这张像是从一台已经启动过很多次的设备上拍的（`logcat.txt` 800 KB、`lost+found` 有 16 KB 的内容、`adb/` 有 6 个子目录），所以"从来没被创建过"不是"这次启动刚好没有"。
2. **doc 98 的第二个 store 也不在**：`/data/gf_data` 不存在。也就是说那两处静默是**两次真实的缺失**，而不是同一次缺失的两个说法——这一点以前只能从库里读出结构，现在有镜像作证。

> **2026-09-24 更正（[`126`](126-the-path-was-decided-by-what-the-stub-omits.md)）：上面这张表读的是 2026-09-16 的 `userdata.img`，而它能回答的问题比本篇以为的窄。**
> 活体设备给出的答案是**两个都 MISSING**——2026-09-24 的探针归档
> （`tmp-post-recovery-20260924T013059Z/06-fingerprint.txt:7-8`）经 HAL 自己的 mount namespace 读的是
> `MISSING  /data/system/users/0/fpdata` 与 `MISSING  /data/vendor_de/0/fpdata`。所以"哪条路径要建"不能从
> 这张表推：**image 里在不在**和**设备上现在在不在**是两个不同的读数（而且这张像是 2026-09-16 的，在
> netwatch/cpufreq/keeper 那些工作之前）。能定这件事的只有一条：**biometryd 自己会传哪一个**，
> 而那是 `/data/vendor_de/0/fpdata`。

**镜像挂载是只读的**（`ro,noload,loop`），26 GiB 那张没有做过任何写操作；`-exact` 那套挂不上（docs 84）的记录不受影响，这轮用的是 `-staged` 之外的 `recovery-supplement` 那一份，`file` 说是合法 ext4。

---

## 4. 修完之后：说清"为什么"，并且承认两个读法可以不一致

section 2 现在做三件事，而不是一件：

1. 读 **`/usr/bin/getprop`**（biometryd 自己执行的那个文件），并且判定它答了没有——判定依据是**它答了什么**，不是猜文件类型：

   ```
   biometryd execs /usr/bin/getprop -- a shell script (the v63 stub's shape), and it DOES answer (so the level below is a real read)
     ro.product.first_api_level -> <unset>
     ro.build.version.sdk      -> 28
   -> level 28 > 27: biometryd passes /data/vendor_de/0/fpdata/  (check THAT one above)
   ```

   > **2026-09-24 更正（[`126`](126-the-path-was-decided-by-what-the-stub-omits.md)）：这一段原来是那条 `answers NOTHING` 的输出。**
   > 真机上打的是上面这五行：判定机制没变（跟着"答了什么"走），而**答案是"答了"**——答的是兜底那一支。
   > 这正好说明为什么第 1 步的判定必须跟着结果走：同一条代码路径，在同一次运行里既能被读成"哑的"也能被读成
   > "答了"，而只有后者是真的。

   （第一版这段写的是"THE v63 STUB, so every read below is empty by construction"，然后测试换了个**会答话的** shell script 上去，它就一边这么说一边打印出一个值——一句话和它下面几行自相矛盾。所以判定必须跟着**结果**走；`#!` 只能用来描述"形状"，不能用来下结论。）

2. 按 biometryd 的**原式**决定路径，并把理由写成 biometryd 的理由。

3. **交叉核对**容器的值，把离线已知的 `23` 一起打印出来，并且明说一致还是不一致：

   ```
   the Android side, for cross-check only (biometryd never reads this):
     ro.product.first_api_level -> 23     [2026-06-07 vendor.img build.prop: 23]
     ro.build.version.sdk      -> 28
   -> DISAGREES with the reading above: biometryd will pass /data/vendor_de/0/fpdata, the device reports <=27.
   ```

   而这台设备上打的**就是**这一种（按上面的更正：biometryd 的读是 28，容器的是 23）。原文在这里写的是
   "这台设备上两个读法一致，所以目标确定"——**两句都错**。正确的是：这台设备上两个读法不一致，而目标仍然确定，
   **因为只有 biometryd 自己那个读算数**（它从不读容器的 getprop）。"因为两个独立读法一致所以确定"和"确定"
   是两句不同的话，而这次连第一个前提都不成立。

---

## 5. 证明 harness 有牙

```
$ sh /tmp/zl1-hw/scripts/host/zl1-loc-fp-selftest.sh      # 对着 HEAD 的探针
pass=111 fail=13
```

13 条红，**同一个缺陷的侧面**。最要紧的两条是：

```
FAIL  container says 29 but the UT getprop is the stub -> biometryd passes <=27, and that is the path created
FAIL  NOT the path the container's value would suggest (the old probe's answer)
```

harness 现在可以**给 UT 侧的 getprop 一个答案**（`ut_getprop 29 29`），所以这三种情形都能被驱动：真机形状、两个都 `>27`、以及**两个不一致**——最后这一种是以前根本表达不出来的。

> **2026-09-24 更正（[`126`](126-the-path-was-decided-by-what-the-stub-omits.md)）：这一段的"真机形状（桩 + 容器 23）"当初指的是 `<=27` 那一支，而真机落在 `>27`。**
> 夹具也一起改了：`ut_getprop_stub` 现在**就是设备那个 stub 的形状**（答 `ro.build.version.sdk`=28、
> 不认 `ro.product.first_api_level`），而"什么都不答的 getprop"变成另一个夹具 `ut_getprop_silent`，
> 要按名字请出来。断言里那句"biometryd 实际传的路径"也从 `/data/system/users/0/fpdata` 改成了
> `/data/vendor_de/0/fpdata`。**一个默认夹具是"不存在的设备"的 harness，通过的方式是测量了错的东西**——
> 这和一个"不可能失败的检查"是同一族缺陷。当前 **200 项**，全绿。

### 5.1 顺带发现：那个"跟修复前比"的场景，在修复提交之后就变成自比了

同一轮里，`zl1-installers-selftest.sh` 的第 12 节红了 3 条，而它二十分钟前还是全绿。原因不是产品改动，是
**它读的是 `git show HEAD:scripts/install-cpufreq-governor.sh`**——而那一条断言的全部意义是"**出厂那版**
applier 在一颗核没动的情况下也 exit 0"。修复一提交，`HEAD` 就是修好的版本，于是它开始拿修复跟它自己比；
本来该拦住这件事的守卫查的是字符串 `did NOT take it`，而 applier 打印的是 `did NOT take '<governor>'`——
**两个版本里都不存在这个字符串**，所以那道守卫永远只可能 PASS。

这正是这个文件存在的理由（"一个只会通过的断言和一个不存在的断言等价"），而它自己犯了。修法不是改那个字符串，
是**把"修复前"的来源改对**：沿着这个文件的历史往回走，取最近一个 applier **没有**回读的 revision，并把这个
revision 的短 SHA 打出来。同时 `git log -- "$CP"` 改成 **repo 相对路径**——因为文档里教人的用法是把整棵树
拷到仓库外面跑，而 `git log -- /tmp/copy/...` 找不到任何历史（第一版这么写时，它把一次能用的比较变成了一次
硬错误）。找不到历史时它打一行 `SKIP` 并**单独计数、在最后点名**，因为悄悄变成空操作才是这里真正的缺陷。

写这一篇时也顺手核对了 docs 99 和 100 的复现命令：它们同样写的是 `HEAD`，而那两个修复都已经提交了，所以
按原文跑已经**复现不出**当时那些红。现在三处都改成"拷当前整棵树、只把那一轮修的那几个脚本退回指定的
revision"，并且**每一处都重新跑过**：docs 99 → `pass=224 fail=5`，docs 100 → `pass=211 fail=15`，
本篇 → `pass=111 fail=13`。

---

## 6. 这一轮**不**证明什么

* **对设备的结论：零。** 设备在 EDL；探针**仍然没有在设备上跑过**，那个写（`--create-store-dir`）**一次都没有做过**。这一轮说的是"它会建哪个目录、为什么"，而这个是从镜像和源码里问出来的。
* **`/data` 那张像是 2026-09-16 的**，在 netwatch / cpufreq / keeper 那些工作之前。它回答的是"在一台启动过很多次的设备上，那个目录在不在"，不是"现在在不在"。
* **`first_api_level=23` 是 `vendor` 分区的 `build.prop` 值**，也就是容器属性区**会**提供的值；它不是设备上跑出来的 `getprop`。
* **即使目录被建出来，也不能证明指纹随后就能用。** `access(W_OK)` 底下还坐着最里面那个 HAL 自己的 store（`/data/gf_data`，也不存在）、守护进程 `gx_fpd`、以及 `libQSEEComAPI.so`。doc 83 的 EINVAL 是**三处静默里的第一处**；这一轮确认前两处是真实的缺失，对第三处一个字都没说。
* **建目录是对 Android `/data` 的一次写**，仍然是用户的决定。探针只为**它建的那一个**路径打印 undo。

---

## 7. 复现

```sh
# 全部在宿主机上。镜像是只读挂载，不碰设备。
sudo mount -o ro,noload,loop /mnt/data/zl1-backups/2026-06-07-adb-root-staged/vendor.img /mnt/vendor-ro
sudo grep -E 'first_api_level|board.platform|product.board' /mnt/vendor-ro/build.prop
sudo mount -o ro,noload,loop /mnt/data/zl1-backups/2026-09-16-recovery-supplement/userdata.img /mnt/udata-ro
sudo ls -ld /mnt/udata-ro/system/users/0{,/fpdata} /mnt/udata-ro/vendor_de/0/fpdata /mnt/udata-ro/gf_data

sh scripts/host/zl1-loc-fp-selftest.sh            # 124 项（写这篇时；现在是 200 项，见 126）
sh scripts/host/zl1-loc-fp-selftest.sh --keep     # 留下假根、改写后的脚本和桩

# 证明 harness 测的是这个缺陷：把当前整棵树拷出去，只把两个探针退回到修复前的 revision。
# **写固定的 revision，不要写 HEAD**——修复一提交，HEAD 就是修好的版本，同一份 harness 会开始拿修复
# 跟它自己比（这次真的发生了，见 §5 末尾）。这个缺陷的修复是这一篇所在的提交，之前是 25f7ba1。
rm -rf /tmp/zl1-hw && mkdir -p /tmp/zl1-hw
cp -r scripts /tmp/zl1-hw/
git show 25f7ba1:scripts/device/zl1-fingerprint-probe.sh > /tmp/zl1-hw/scripts/device/zl1-fingerprint-probe.sh
git show 25f7ba1:scripts/device/zl1-location-request.sh  > /tmp/zl1-hw/scripts/device/zl1-location-request.sh
sh /tmp/zl1-hw/scripts/host/zl1-loc-fp-selftest.sh    # 13 条红

# 回到设备之后（只读的那一条）
scp scripts/device/zl1-fingerprint-probe.sh root@10.15.19.82:/tmp/ && \
  ssh root@10.15.19.82 'sh /tmp/zl1-fingerprint-probe.sh'
# 唯一的写，是用户的决定：
#   sh /tmp/zl1-fingerprint-probe.sh --create-store-dir
```

| 文件 | 作用 |
|---|---|
| `scripts/device/zl1-fingerprint-probe.sh` | 修：section 2 读 **biometryd 自己执行的** `/usr/bin/getprop`，判定跟着**答没答**走，并把容器值作为明说一致/不一致的交叉核对 |
| `scripts/host/zl1-loc-fp-selftest.sh` | 扩：110 → **124** 项；`ut_getprop` 夹具可以给 UT 侧 getprop 一个答案，从而驱动 `>27` 和不一致两种情形 |
| `docs/ubuntu-touch/evidence/fp-store-path-2026-09-23.log` | 这一轮的原始输出：源码原文、两个镜像的实测、三种读法的探针输出、124 项全文、对着 `HEAD` 的 13 条红 |
| `docs/ubuntu-touch/101-*.md` | 本篇 |
