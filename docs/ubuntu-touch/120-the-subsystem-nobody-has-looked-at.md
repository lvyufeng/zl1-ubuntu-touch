# 120 — 那个从来没有人看过的子系统

**日期**: 2026-09-24
**状态**: 本轮**没有碰设备**（设备仍在 EDL，见 §7）。全部在 host 侧：给**telephony/modem** —— 这个 port 上
**唯一一个连一件仪器都没有**的子系统 —— 写了第一件仪器（只读），配一个 **79 检查**的离线 harness；并且把
"固件到底在哪儿"这个问题从"印象"变成了**可以在镜像上逐字核对**的东西。**没有安装任何东西，没有 flash，
没有写分区，没有开权限绕过。**

**接续**: [`117`](117-the-command-that-could-not-run-is-not-a-zero.md)（跑不起来的命令不是一个 0）、
[`102`](102-gps-log-owners-and-the-two-unreachable-branches.md)（一条日志字符串只属于包含它的那个进程）、
[`49`](49-*.md)（unbind cnss 会把设备直接送进 EDL）、
[`119`](119-the-first-client-that-finally-knocked.md)（上一轮：给 GPS 的门找了个客户端）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 这一轮做了什么？ | `scripts/device/zl1-modem-probe.sh`：**只读**的 modem/PIL 探针，7 节读数 + 一个说出"证据停在哪一级"的 verdict |
| 为什么是它？ | 因为它是**唯一没有仪器**的子系统。别的外设都被量过至少一次，modem 的全部记录只有一句"ofono 是 active" |
| 为什么不能靠"看起来没问题"？ | 因为 modem **不是一个可以戳的驱动**：它是**第二个 CPU 在跑固件**，而固件必须在 probe 时刻由**内核**亲手交过去。"ofono 起来了"只说明有个守护进程起来了 |
| 镜像上先说得出什么？ | 设备树点名要 `modem`（`qcom,pil-self-auth` 也开着 → TZ 要验签）；**Android 的 vendor 镜像里根本没有这个固件**；它在**独立的 FAT16 `modem` 分区**上；而这个 UT rootfs **连 `/lib/firmware` 都没有** |
| 那这算结论吗？ | **不算。**这是一条**有名字的假说**，不是一个发现 —— port 完全可能 bind-mount、可能设了 `firmware_class.path`、可能用镜像里看不见的方式拿到固件。**探针就是用来量这一件事的** |
| 离线验证？ | `zl1-modem-probe-selftest.sh` **79 检查 / 0 失败**；写它的过程中抓到 **3 个脚本缺陷 + 7 个 harness 自身缺陷**（§5） |
| 动设备了吗？ | **没有。**探针**从来没有在设备上跑过**；设备仍在 EDL |

---

## 2. 为什么偏偏是它没人看

这个 port 每一个外设都至少被量过一次，而且大多数是被**反复**量过的：屏幕、触摸、传感器、方向、Wi-Fi、
摄像头、GPS、指纹、音频、温度。只有 telephony 没有，而它的全部记录是一句话——
**"ofono 是 active"**。

这句话是真的，也是**唯一能说的**：`ofono` 是一个用户态守护进程，它起来说明不了它有没有 modem 可以谈。
而 modem 恰好是那种"**看起来一切正常**"最贵的子系统：

* 它不通过一个你可以 `cat` 的 sysfs 节点暴露自己；
* 它**不是内核里的一段 driver**，而是**另一个 CPU**（hexagon DSP6，见 §3）在跑固件；
* 固件必须在 **probe 时刻由内核交过去**，交不过去就是一句 `request_firmware` 失败，而那句失败**只在这一
  次 boot 的内核日志里**。

所以这里最可能的故障形状是：**固件从来没到过内核能拿到它的地方**，而设备上**没有任何东西会因此报警** ——
ofono 照常 active，界面照常能用，只是永远没有信号。这正是"没人看过的子系统"会呈现的样子。

---

## 3. 镜像上到底说得出什么（全部可逐字核对）

以下每一条都是在这一轮的 host 上**重新量过**的，用 `debugfs`（**只读**打开 ext4 镜像，不 mount）和一个
FAT16/ELF 解析器直接读镜像，**没有碰设备**。这些读数连同产生它们的命令归档在
[`evidence/modem-offline-readings-2026-09-24.txt`](evidence/modem-offline-readings-2026-09-24.txt)。

### 3.1 设备树自己点了名

`boot.img` 里带着 **5 个** DTB（按机型变体）。第一个能完整走通的那个里，`/soc/qcom,mss@2080000` 是：

| 属性 | 值 |
|---|---|
| `compatible` | `qcom,pil-q6v55-mss` |
| `qcom,firmware-name` | **`modem`** |
| `qcom,pil-self-auth` | **存在，无值**（DT 的布尔属性 = TZ 要验签） |
| `status` | `ok` |

另外四条变体里，**字符串表同样都有** `qcom,firmware-name` 和 `qcom,pil-self-auth`，而且
`qcom,pil-q6v55-mss` 在整个 `boot.img` 里正好出现 **5 次**（每个 DTB 一次）——但**哪一片 DTB 被真的启动了，
这台 host 说不出来**（我的走通解析器只吃下了第一个）。

**这正是探针为什么要读活的设备树**（§4 第 1 节），而不是读这个仓库里的一份 DTB：一份离线 DTB 是**关于某个
变体的猜想**，`/proc/device-tree` 才是这一次 boot 的事实。

### 3.2 固件**不在** Android 的 vendor 镜像里

`debugfs` 读 `vendor.img` 的 `/firmware`（126 个条目）：有 GPU 的 `a530_*`、`cpp_firmware_*`、`venus.*`、
`Signedrompatch_*`，以及 **RF 配置树 `modem_pr/`** —— 但**没有 `modem.mdt`，没有 `modem.b*`，没有 `mba.mbn`**。

顺带一个容易看错的地方：`/vendor/firmware/modem_pr/` 里的 `mcfg_sw_*.mbn` **不是 modem 固件**，是**运营商
配置**。它长得像 modem 的东西、名字里有 modem，很容易被当成"固件在 vendor 里"的证据。

### 3.3 固件在**独立的 FAT16 分区**上，而且是一个**完整的 ELF 镜像**

`modem.img`（115343360 字节）是一个 **FAT16** 卷（BPB：`bytes/sector 4096`、`sectors/cluster 4`、
`root entries 512`、`FAT16`），根目录下两个目录：`IMAGE/` 和 `VERINFO/`。整个树 **301 个文件、78.2 MiB**。

`IMAGE/` 里关键的是 **20 个 `MODEM.B*` + `MODEM.MDT`**：

```
MODEM.B00   884      MODEM.B08  14223856   MODEM.B15     79632
MODEM.B01   7272     MODEM.B09    327264    MODEM.B16    498151
MODEM.B02   5460     MODEM.B10    180672    MODEM.B17  10645504
MODEM.B03   1612836  MODEM.B11    458208    MODEM.B18     81920
MODEM.B04   3229019  MODEM.B12  10351032    MODEM.B19   1830912
MODEM.B05   163056   MODEM.B13   7242464    MODEM.B20    238112
MODEM.B06   734144   MODEM.B14   —— 不存在   MODEM.MDT      8156
MODEM.B07   2028468
```

**`MODEM.B14` 不存在**，第一反应是"少了一个分片、固件是坏的"。**不是**：`MODEM.MDT` 自己就是镜像的 ELF
头（`readelf`：ELF32、`Machine: QUALCOMM DSP6 Processor`、`Entry point 0x88800000`，里面还带着一张
Qualcomm 的 attestation 证书链，写着 `LeEco le_ares`），而它的 **program header 表**逐条解释了这 20 个文件：

| program header | `p_filesz` | 分区上的文件 |
|---|---|---|
| 0 | 884 | `MODEM.B00` (884) |
| 1 | 7272 | `MODEM.B01` (7272) |
| 2 … 13 | 5460 … 7242464 | `MODEM.B02 … MODEM.B13`，**大小逐条相等** |
| **14** | **0**（`p_memsz` = 24548416） | **没有文件 —— 这一条本来就没有东西要载入** |
| 15 … 20 | 79632 … 238112 | `MODEM.B15 … MODEM.B20`，**大小逐条相等** |
| 21, 22, 23, 24, 25 | 0 | 没有文件 |

26 个 program header，其中 **`p_filesz != 0` 的正好 20 个**，而分区上正好有 **20 个 `MODEM.B*`**，**每一个的
大小都和它对应的 header 相同**。所以"缺了 B14"不是缺陷，而是**那个 header 没有数据**。

这句话可以写得比"我认为内核按索引取名"更稳：**分区上的文件集合，和"有数据要载入的那几条 program header"
一一对应、大小相等**。无论加载器的命名规则是什么，它要的东西**在这里是全的** —— 这一点在离线就定死了，
而"它到底有没有去要"只能由设备上的内核日志回答。

同一棵树上还有别的固件（`ADSP.*`、`VENUS.*`、`ALIMAP64.*`、`BDWLAN30.*`、`OTP30.BIN`、`UTF30.BIN`、
`MBA.MBN` 213824 字节）和每个运营商的 `MCFG_SW.MBN`、每个 SoC 的 `MCFG_HW.MBN`（含 `MSM8996/LA`）。也就是说
这个分区是**出厂固件仓**，不只是 modem 一份。

### 3.4 它被挂到哪里，以及 UT 这边**从来没挂过它**

Android 自己的 `vendor.img:/etc/fstab.qcom` 里写得一字不差：

```
/dev/block/bootdevice/by-name/modem   /vendor/firmware_mnt   vfat
    ro,shortname=lower,uid=0,gid=1000,dmask=227,fmask=337,
    context=u:object_r:firmware_file:s0                       wait
```

`shortname=lower` 就是为什么内核要的 `modem.mdt`（小写）在这个卷上是 `MODEM.MDT`（大写 8.3）。

而 **UT 这一侧的 rootfs 里没有 `/etc/fstab` 的对应项**（`rootfs-...-zl1-host.img:/etc/fstab` 只有一行
`# UNCONFIGURED FSTAB FOR BASE SYSTEM`），`/lib` 是指向 `usr/lib` 的软链（usrmerge），而
**`/usr/lib/firmware` 根本不存在**。也就是说：

* 内核的 `request_firmware()` 按内置搜索表找（`/lib/firmware`、`/lib/firmware/updates`、各自的
  `/<uname -r>` 变体，加上 `firmware_class.path`），而这个 rootfs **一个都不存在**；
* 唯一挂过 `modem` 分区的是 **Android 自己的 init**（按上面那条 fstab），而那个挂载点
  `/vendor/firmware_mnt` 只在**容器的 mount namespace 里**才可能有意义。

**这就是那条有名字的假说**：内核在 UT 的搜索路径上找不到固件，而固件在另一个没有被挂载的分区里。
探针第 2、3 节量的就是这件事的两半——**搜索路径上有没有**，和**那个分区到底挂没挂**。

---

## 4. 仪器本身：它做什么，以及它**绝对不**做什么

`scripts/device/zl1-modem-probe.sh [--status] [--quiet] [--explain]`，7 节 + verdict：

1. **设备树点名要什么** —— 从**活的** `/proc/device-tree/soc/qcom,mss@2080000` 读 `qcom,firmware-name`。
   节点读不出来的时候，名字就是**未知**，而不是"大概叫 modem"；后面的每一节都会照此说明。
2. **搜索路径上有没有它** —— `firmware_class.path` 和内核内置表，**逐个目录**问一句"这里有没有
   `${name}.mdt` / `${name}.b00`"。**"目录不存在"和"目录存在但文件不在里面"是两个不同的答案**，所以分开打印。
3. **固件实际在哪儿** —— `mount` 的表、四个候选挂载点、以及容器自己 namespace 里的视图。
4. **有没有载入** —— 这一次 boot 的内核日志，按 pattern 计数，**并且日志能不能读先证明一次**。
5. **只有载入成功才存在的管道** —— `/sys/bus/msm_subsys`、`/sys/class/remoteproc`、`/dev/qmi*`、rmnet。
   这些是**下游**：它们缺失是结果不是原因，先读它们正是"诊断停在低一层"的原因。
6. **UT 这一侧** —— `ofono` 的单元状态，以及 `org.ofono` 这个名字在系统总线上有没有 owner。
7. **verdict：证据停在哪一级。**四个台阶：可达 / 挂了但不在搜索路径上 / 没挂也没到 / **无法回答**。

### 4.1 安全线是绝对的，而且它是一条设计约束，不是一句声明

这个脚本**什么都不写**：不写分区、不写 sysfs、不 modprobe、不重启服务。它对"不写"做了两件更硬的事：

* **它从不打开块设备，连读都不读。**`modemst1`/`modemst2`/`fsg`/`fsc`/`persist` 上放着**校准数据和 IMEI**，
  而"打开 modem 分区看一下"和"写它"之间只隔一个笔误。所以第 3 节读的是**挂载点**（`mount` 的表和目录
  里的文件），不是块设备节点 —— 同样的问题，不需要那个风险。
* **它不 unbind、不 reset、不 restart 任何东西。**这个设备上 unbind `cnss` 会**直接掉进 EDL**
  （docs 49），所以这一类动作**永远不会**进脚本。

### 4.2 三个"读不出来"的分支，都在任何否定分支**之前**

这是 docs 117 那条规矩的第 N 次应用，而这里是它最贵的一次。**`journalctl` 失败时什么都不打印，而一次
安静的开机也什么都不打印。**如果脚本分不清这两件事，它就会把"一个死掉的 modem"报成"这次开机内核什么
都没说" —— 一个整个子系统就是这样被搁置几个月的形状。所以：

* 内核日志**先被证明能读**（`journalctl -b -k ... && [ -s ]`），读不出来时**明确写出"下面的 0 是这个原因"**，
  并且 verdict 是 **UNANSWERED**，不是"driver 什么都没记"；
* 设备树**没有给出固件名**时，**没有任何目录被问过任何一个文件**，所以搜索路径那一节写的是
  **NOT CONCLUDED**，不是"固件不在搜索路径上"（这一条是 harness 逼出来的，§5.1）；
* 容器**回答不了**的时候，打出的是它自己的名字行（"这个 namespace 什么都没回答，这和'路径不存在'不是
  一回事"），而不是一片空白。

---

## 5. 离线验证：79 检查，和它抓到的十个缺陷

`scripts/host/zl1-modem-probe-selftest.sh`：**79 检查 / 0 失败**，一次干净的运行归档在
[`evidence/modem-probe-selftest-2026-09-24.log`](evidence/modem-probe-selftest-2026-09-24.log)。

传输层是**假的设备**：脚本原样跑，`PATH` 指向 stub 目录，`journalctl`/`lxc-info`/`nsenter`/`systemctl`/
`gdbus`/`mount` 全是 stub，`/proc`、`/sys`、`/dev` 被改写进一个假根。内核日志是一个**文件**，它能不能读
由 fixture 决定 —— 这正是"日志读不出来"和"日志里什么都没有"这两个场景可以分开存在的原因。

### 5.1 三个**脚本**缺陷（都是 harness 逼出来的）

| 缺陷 | 它本来会造成什么 |
|---|---|
| 搜索路径那节**在没问过任何文件之后**就下结论"固件不在内核的搜索路径上" | 名字未知时，它把**一个没被提出来的问题**报成了否定答案。现在这一节有三种答案，第三种是 `NOT CONCLUDED` |
| 容器那节写成 `nsenter … \| sed … \|\| say "(…)"` | 管道里的 `\|\|` 属于**最后一条命令**，而 `sed` 在空输入上**成功** —— 于是一个跑不起来的 `nsenter` 会**什么都不打印**，而"什么都没打印"读起来正好像"这个挂载点不存在" |
| `--quiet` 打印了它自己文档里说要丢掉的读数 | 计数表用的是裸 `printf`，`show` 也不看 `QUIET`；而文档写的是"--quiet：verdict 和章节标题"。现在合同是**标题 + boot 身份 + verdict**，别的一律不打印（harness 按这个合同断言） |

### 5.2 七个 **harness 自身**缺陷（每一个都会让"通过"没有意义）

1. **改写级联（两次）。** 假根最初放在 `$W/dev`，于是 `/proc/` 那条规则产出的 `$W/dev/proc/...` 被随后
   的 `/dev/` 规则**又改了一遍**，变成 `$W/tmp/.../dev/dev/proc/...`；把假根改到 `$W/root` 之后，同一类
   问题以另一副面孔回来：`/proc/sys/kernel/osrelease` 里的 `sys/` 撞上了 `/sys/` 那条规则。**读的是一个
   不存在的路径，而下面每一个场景照样"通过"。**所以现在改写是**两趟**：第一趟把每个设备路径换成**不可能
   再被规则匹配到的 token**，第二趟展开 token，并且断言"第一趟的 token 数 == 第二趟的假根路径数"。
2. **`verdict()` 取不到东西。** 探针的标题是 `== 7. verdict`（带编号），而我从 GPS 那件仪器抄来的是
   `^== verdict$` —— 于是**每一条关于 verdict 的断言都在对一个空字符串做**。锚点改成带编号的形式。
3. **`command -v grep` 返回的是"grep"这个词。** 这台机器的 profile 把 `grep` 变成了一个 shell 函数，
   `command -v` 于是打印它的名字而不是路径，软链就指向了自己。改用 `type -P`。
4. **`env PATH=… bash` 找不到 bash。** `env` 用**新的** PATH 去找要跑的程序，而沙箱和 stub 目录里都没有
   解释器。改成用**绝对路径**的 `sh`（也更接近设备上的 `#!/bin/sh`）。
5. **`printf "('%%s',)"` 打出了字面量 `%s`。** 生成 stub 的 heredoc 不该转义 `%`。
6. **`nsenter[^|]*-p` 匹配到了 `-probe`。** 假根的路径里含 "-probe"，一个宽松的 `-p` 模式把它读成了 PID
   namespace 标志 —— 一个**正确的脚本会被断言判错**。改成匹配**作为标志的 `-p`**。
7. **这台 host 的 `/usr/bin/gdbus` 会被假设备继承。** PATH 只加 stub 前缀的话，"把 stub 藏起来"这个
   场景里真正可达的是**这台笔记本自己的 gdbus**，而探针会去查**这台机器的系统总线**。这正是 docs 119 §5.2
   在 GPS 那件仪器的 harness 里抓到的那个泄漏；这里用**沙箱 PATH**（一组指向真 coreutils 的软链，里面
   没有 gdbus）从构造上关掉它。

### 5.3 "它什么都不写"是**静态检查**出来的，而且这个检查有牙

§4.1 的安全线如果只写在注释里，它就是一句愿望。所以 harness 对**发出去的源码**做一次正则检查：
不许有写进 `/sys`、`/proc`、块设备的重定向，不许有 `dd`/`mkfs`/`mount`/`modprobe` 这类命令出现在
**命令位置**，不许有改状态的 `systemctl` 动词。两条牙：

* 把一个 `: > /sys/module/firmware_class/parameters/path` 放回去 —— 检查必须抓到它；
* 把 `mount` 换成 `mount -o bind /vendor/firmware_mnt /lib/firmware` —— 检查也必须抓到它。

第二条是刻意的：`mount` 是**两个命令共用一个名字**（光 `mount` 是**列出**挂载，探针确实要用它），所以
检查必须能区分**列表**和**挂载**。一个把 `mount` 一律放行的检查等于没有检查，而一个把注释里"mount point"
都算成写操作的检查没人会留着。

---

## 6. 这一篇**不**证明什么

* **不证明 modem 是坏的**，也不证明它是好的。它只给出**该问的问题**和**一次能回答它的运行**。
* **不证明固件"不在搜索路径上"** —— 那要设备上的读数（§4 第 2 节），而探针还没在设备上跑过。
* **不证明 §3 的假说成立。**§3 全部是**镜像上的**读数：固件在分区上、分区在 fstab 里、rootfs 里没有
  `/lib/firmware`。**port 完全可能已经 bind-mount 了 vendor 树，或者设了 `firmware_class.path`** —— 那正是
  探针要量的。
* **不证明 `ofono` 的读数对新东西有用**。它是"一个守护进程起来了"，这一篇的作用恰恰是**把这句话从结论降级
  成背景**。
* **不证明探针在真机上不会出错**。它只在 stub 上跑过；真机上第一次运行的输出，才第一次算数。

---

## 7. 设备状态与下一步

整轮没有动设备：没有写任何分区或 boot，没有跑 QDL/QFIL，没有重启，没有绕过权限。设备仍在 **Qualcomm EDL**
（`05c6:9008`，无序列号）；唯一的出口是**物理长按电源 10–20 秒**（只有用户能做）。

顺序（每一步都还没有得到用户的批准）：

```
# 0. 先出 EDL：物理长按 POWER 10–20 秒，等 RNDIS 和 ssh
scripts/host/zl1-post-recovery-capture.sh             # 0 系列读数；探针默认跳过
scripts/host/zl1-heat-fix-chain.sh --yes              # 发烫：部署 → 激活 → 90 s → 证明 → 退役 keeper → governor
scripts/host/zl1-gps-first-client.sh --seconds 180    # 需要手边有人：把 "detect current location" 打开
scp scripts/device/zl1-modem-probe.sh root@<ip>:/tmp/ && \
  ssh root@<ip> 'sh /tmp/zl1-modem-probe.sh'          # 这一轮的新仪器，第一次真机运行
```

最后一条是这一轮的全部意义：**它读什么都可以，但它什么都不写**，所以它可以和别的读数放在同一次 boot 里、
在同一个 `zl1-health-check.sh` 的运行中一起做（见那里的第 5 项）。
