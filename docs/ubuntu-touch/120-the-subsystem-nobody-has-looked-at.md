# 120 — 那个从来没有人看过的子系统

**日期**: 2026-09-24
**状态**: 本轮**没有碰设备**（设备仍在 EDL，见 §7）。全部在 host 侧：给**telephony/modem** —— 这个 port 上
**唯一一个连一件仪器都没有**的子系统 —— 写了第一件仪器（只读），配一个 **111 检查**的离线 harness；并且把
"固件到底在哪儿"这个问题从"印象"变成了**可以在镜像上逐字核对**的东西。**没有安装任何东西，没有 flash，
没有写分区，没有开权限绕过。**

**修订（同一天，探针在设备上跑之前的最后一趟离线核对）**: 这一篇原来的假说是"**boot 根本没给内核设
`firmware_class.path`，而且这个 rootfs 连 `/lib/firmware` 都没有**"。把**每一条 boot cmdline** 和 **UT rootfs
自己的符号链接**读出来之后，这句话**有一半是错的**：cmdline **一直**带着
`firmware_class.path=/vendor/firmware_mnt/image`（**原厂**的 boot 就带着，docs 20 有记录），而 UT rootfs 的
`/vendor` **是指向 `/android/vendor` 的软链** —— 所以内核被指到的那个路径**是对的**。于是问题从"**路径**"
变成了"**那个挂载**"：§3.4/§3.5 是修正后的版本，探针也跟着改了两处（§5.1）。改动的动力不是"文档要好看"，
而是**原来的探针会把一个就在那儿的固件报成 MISSING**。

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
| 镜像上先说得出什么？ | 设备树点名要 `modem`（`qcom,pil-self-auth` 也开着 → TZ 要验签）；**Android 的 vendor 镜像里根本没有这个固件**；它在**独立的 FAT16 `modem` 分区**上，而且那个分区的**根目录**放着 `IMAGE/` 和 `VERINFO/`；这个 UT rootfs **连 `/lib/firmware` 都没有** |
| boot 有没有告诉内核去哪儿找？ | **告诉了，而且指对了。**每条 zl1 cmdline 都带 `firmware_class.path=/vendor/firmware_mnt/image`（**原厂** boot 就带，docs 20 有记录），而 `IMAGE/` 正是文件所在的那一层 |
| 那为什么还可能找不到？ | 因为**内核被指到的那条路径是一个软链**：UT rootfs 里 `/vendor -> /android/vendor`。路径**解析得通**当且仅当**有人把 modem 分区挂在了 `/android/vendor/firmware_mnt`** —— 而在 UT 这一侧，做这件事的是 halium 的 mount 循环，它读的 fstab **不存在时不会报错，只是一件都没挂** |
| 那这算结论吗？ | **不算。**这是一条**有名字的机制**，不是一个发现 —— 挂载可能由 halium 做、由容器的 init 做（那是**另一个 mount namespace**，对内核没用）、或者由镜像里看不见的第三种方式做。**探针就是用来量这一件事的** |
| 离线验证？ | `zl1-modem-probe-selftest.sh` **111 检查 / 0 失败**；写它的过程中抓到 **5 个脚本缺陷 + 8 个 harness 自身缺陷**（§5） |
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

`shortname=lower` 就是为什么内核要的 `modem.mdt`（小写）在这个卷上是 `MODEM.MDT`（大写 8.3）。**而且它在
`IMAGE/` 里**：把分区镜像按 BPB 直接走一遍（不挂载、不碰设备，`scripts/host/zl1-edl-postmortem.sh` 之外
一条一次性的 python 走 FAT），根目录只有两个目录 —— `IMAGE/`（cluster 4）和 `VERINFO/`（cluster 2），301 个
文件 78.2 MiB，`IMAGE/MODEM.MDT` 8156 字节、`IMAGE/MBA.MBN` 213824 字节。**所以挂上以后，内核要的那个文件
在挂载点的下一层**，这一点下面 §5.1 会变成一个探针缺陷。

而 **UT 这一侧的 rootfs 里没有 `/etc/fstab` 的对应项**（`rootfs-...-zl1-host.img:/etc/fstab` 只有一行
`# UNCONFIGURED FSTAB FOR BASE SYSTEM`），`/lib` 是指向 `usr/lib` 的软链（usrmerge），而
**`/usr/lib/firmware` 根本不存在**。

### 3.4.1 但是 `/vendor` 是一条**软链**，而且 cmdline **一直**指对了地方

这一小节是修订（见开头）：原来这里写的是"boot 根本没设 `firmware_class.path`"。把 rootfs 镜像和每一条
cmdline 读出来之后，两件事都反了过来：

| 离线读数 | 从哪儿读的 | 说明什么 |
|---|---|---|
| `/vendor -> /android/vendor`、`/firmware -> /android/firmware` | `debugfs stat` **rootfs 镜像本身** | 内核被指到的路径**不是**一个目录，而是一条**软链**：它解析得通，当且仅当**有人把 modem 分区挂在 `/android/vendor/firmware_mnt`** |
| `firmware_class.path=/vendor/firmware_mnt/image` | **每一条** zl1 boot cmdline；**原厂**那条记在 [`20`](20-stage2-runbook.md:33) | 这不是 port 加的，是**原厂 Android 的写法**被继承了；而 `image/` **正是** §3.4 里那个 `IMAGE/` —— **指对了** |
| `/firmware -> /vendor/firmware_mnt` | Android boot ramdisk 的**根** | 同一个约定：Android 那边 `/firmware` 也是软链，指到同一个挂载点 |

也就是说：**"内核不知道去哪儿找"是错的**。真正的问题只剩一个 —— **那个挂载点这一次 boot 有没有被挂上**。

### 3.5 那谁会挂它？——halium 的 mount 循环，而它**不报错**

把 UT 的 boot ramdisk 打开（`/tmp/utrd`，347 项），`scripts/halium` 里两段读数是决定性的：

```sh
mount_android_partitions() {          # 逐行读 fstab，跳过 /system、/data、/，其余按 label 挂
  cat ${fstab} | while read line; do
    ...
    mount $path ${mount_root}/$2 -t $3 -o $4
  done
}
...
mount_android_partitions "${rootmnt}/var/lib/lxc/android/rootfs/fstab*" ${rootmnt}/android ${rootmnt}/userdata
```

三个要点，每一个都是这一篇的结论的一半：

1. **它是从 `${rootmnt}/var/lib/lxc/android/rootfs/` 里读 fstab 的**，而那个目录在上面的流程里是
   `mount --move /android-rootfs ${rootmnt}/var/lib/lxc/android/rootfs` 搬过来的 —— 也就是**它从 Android
   ramdisk 里解出来的那一棵树的根**（`extract_android_ramdisk`）。
2. **`cat` 遇到没有展开的 glob 会失败**，于是 `while read` 的循环体**一次都不执行**：**一件都不挂，而且
   一声不响**。这是一个**静默的、彻底的空缺**，正是"看起来一切正常"最贵的那种形状。
3. **设备上那份 Android ramdisk（`/boot` 里那份）根本没有 fstab 这个文件** —— 把它的 cpio 清单过一遍，
   没有任何 `fstab*` 条目（顺带一个与本篇无关但值得记一笔的读数：**这份 `/boot` 是第三方 MIUI 的 ROM**，
   不是原厂 LeEco 的 —— `init.miui.*`、`ro.product.manufacturer=Xiaomi`，而 `ro.product.device=le_zl1`）。
   halium **真正**解的那份 ramdisk 在它自己的 system 镜像里（`/android-system/boot/android-ramdisk.img`），
   那一份**离线看不到** —— 所以"它有没有 fstab"是**设备上一条 `ls` 的事**，而探针第 3 节现在就是那条 `ls`。

   > **2026-09-24 追记（[`151`](151-the-question-that-was-filed-as-unreadable-offline.md)）：上面这句"离线看不到"是错的。**
   > 那份 system 镜像**就在这台笔记本上**，而且它就是**被 push 到手机 `/data/system.img` 的同一个 4 GB 文件**。
   > 用 `debugfs -R dump`（只读）把它里面的 `/boot/android-ramdisk.img` 取出来走一遍 cpio，
   > 读数是 **65 个条目、一个都不是 fstab** —— 也就是下面那条假说 **(a) 成立**，而且它是**离线可复现的**，
   > 不再是设备上的事。**下面那两条 `ls` 现在降级成"确认"，不是"发现"**（期望 0；读到非 0 说明手机上的镜像
   > 不是这里读的镜像，那是发现不是矛盾）。本条错误值得记形状：第 1 步证明了 **A 不在设备的 `/boot` 里**，
   > 却被写成了"**这个问题看不到**"——两句都像是"我查过了"，而只有前一句是真的。

于是假说从"路径没设"变成**两条可以分开量的机制**：(a) **什么都没挂**（fstab 缺失 → 循环空转）；
(b) **挂了，但挂在容器的 namespace 里**（Android 的 init 自己按 fstab 挂 `/vendor`，而那是**另一个 mount
namespace**，内核解析 `firmware_class.path` 时看不到它）。探针第 3 节把两件事分开打印。

---

## 4. 仪器本身：它做什么，以及它**绝对不**做什么

`scripts/device/zl1-modem-probe.sh [--status] [--quiet] [--explain]`，7 节 + verdict：

1. **设备树点名要什么** —— 从**活的** `/proc/device-tree/soc/qcom,mss@2080000` 读 `qcom,firmware-name`。
   节点读不出来的时候，名字就是**未知**，而不是"大概叫 modem"；后面的每一节都会照此说明。
2. **搜索路径上有没有它** —— **两个** `firmware_class.path` 都读，因为它们是两个问题的答案：**boot cmdline
   上那个**是 probe 时刻真正生效的，**sysfs 里那个**是内核**现在**的值；两者不一致就明写。然后是内核内置
   表，**逐个目录**问一句"这里有没有 `${name}.mdt` / `${name}.b00`"。**"目录不存在"和"目录存在但文件不在
   里面"是两个不同的答案**，所以分开打印。
3. **固件实际在哪儿** —— 先打印**符号链接链**（`/vendor`、`/android`、`/firmware` 各自解析到哪里），因为这
   整个问题就架在它上面；然后是 `mount` 的表、四个候选挂载点（**每个都问两层**：挂载点本身，和它的
   `image/`）、容器自己 namespace 里的视图，最后是 **halium 那个 fstab 在不在、里面有没有 modem 那一行**。
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

## 5. 离线验证：111 检查，和它抓到的十三个缺陷

`scripts/host/zl1-modem-probe-selftest.sh`：**111 检查 / 0 失败**，一次干净的运行归档在
[`evidence/modem-probe-selftest-2026-09-24.log`](evidence/modem-probe-selftest-2026-09-24.log)。

传输层是**假的设备**：脚本原样跑，`PATH` 指向 stub 目录，`journalctl`/`lxc-info`/`nsenter`/`systemctl`/
`gdbus`/`mount` 全是 stub，`/proc`、`/sys`、`/dev` 被改写进一个假根。内核日志是一个**文件**，它能不能读
由 fixture 决定 —— 这正是"日志读不出来"和"日志里什么都没有"这两个场景可以分开存在的原因。

### 5.1 五个**脚本**缺陷（前三个是 harness 逼出来的，后两个是这一趟离线核对逼出来的）

| 缺陷 | 它本来会造成什么 |
|---|---|
| 搜索路径那节**在没问过任何文件之后**就下结论"固件不在内核的搜索路径上" | 名字未知时，它把**一个没被提出来的问题**报成了否定答案。现在这一节有三种答案，第三种是 `NOT CONCLUDED` |
| 容器那节写成 `nsenter … \| sed … \|\| say "(…)"` | 管道里的 `\|\|` 属于**最后一条命令**，而 `sed` 在空输入上**成功** —— 于是一个跑不起来的 `nsenter` 会**什么都不打印**，而"什么都没打印"读起来正好像"这个挂载点不存在" |
| `--quiet` 打印了它自己文档里说要丢掉的读数 | 计数表用的是裸 `printf`，`show` 也不看 `QUIET`；而文档写的是"--quiet：verdict 和章节标题"。现在合同是**标题 + boot 身份 + verdict**，别的一律不打印（harness 按这个合同断言） |
| 对着**挂着**的 modem 分区按**挂载点**问文件（`$mp/modem.mdt`） | FAT 的根是 `IMAGE/`，所以答案是 `$mp/image/modem.mdt`。原来那一句会把**就在那儿的固件**报成 `MISSING` —— 一件仪器**自己制造出来的否定答案**，而它读起来和"固件真的不在"一模一样。现在每个候选挂载点都问**两层**，并且 harness 把一个两层答案**不一样**的场景（`image/modem.mdt=present` 而 `modem.mdt=MISSING`）钉成断言 |
| 同一个探针**"内核被指到哪儿"**只读了 sysfs，没读 cmdline | sysfs 是**现在**的值，cmdline 是 **probe 时刻**的值 —— 而固件正是 probe 时刻要的。少了这一条，"路径一直是对的"这件事**在设备上无法被确认**，而它正是这条假说唯一的核心。现在两个都读，不一致时明写 |
| 它的写操作检查把探针**自己的散文**读成了重定向（`-> /proc/cmdline could not be read`） | 箭头后面接一个路径被当成 `> /proc/...`。一个**会在正确的探针上报错**的守卫，通常的下一步是被**放宽到不再守卫任何东西**；这里改成精确地排除箭头，并且 harness **两个方向都证明**（真重定向仍然抓到，箭头仍然不算）—— 见 §5.3 |

### 5.2 八个 **harness 自身**缺陷（每一个都会让"通过"没有意义）

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
8. **内置搜索表的第一个元素从来没被改写。** 它写成 `PATHS="/lib/firmware/updates/$KREL …"` —— 第一项前面是
   **引号**而不是空格，于是那条要求前导空格的改写规则**没碰到它**，探针问的是**这台笔记本自己的**
   `/lib/firmware/updates`。它回答 `MISSING`，所以**看起来什么也没错**；而一台**真有**那个目录的 host 会被
   当作手机来读。修法是探针那张表**以空格开头**（`for d in $PATHS` 会忽略它），再加一条恒等式
   ——`token 数 == ' /lib/firmware' 在源码里出现的次数`—— 写这条恒等式的当口它就把自己抓出来了。

### 5.3 "它什么都不写"是**静态检查**出来的，而且这个检查有牙

§4.1 的安全线如果只写在注释里，它就是一句愿望。所以 harness 对**发出去的源码**做一次正则检查：
不许有写进 `/sys`、`/proc`、块设备的重定向，不许有 `dd`/`mkfs`/`mount`/`modprobe` 这类命令出现在
**命令位置**，不许有改状态的 `systemctl` 动词。两条牙：

* 把一个 `: > /sys/module/firmware_class/parameters/path` 放回去 —— 检查必须抓到它；
* 把 `mount` 换成 `mount -o bind /vendor/firmware_mnt /lib/firmware` —— 检查也必须抓到它。

第二条是刻意的：`mount` 是**两个命令共用一个名字**（光 `mount` 是**列出**挂载，探针确实要用它），所以
检查必须能区分**列表**和**挂载**。一个把 `mount` 一律放行的检查等于没有检查，而一个把注释里"mount point"
都算成写操作的检查没人会留着。

第三条牙是**为了守卫自己**加上的：它第一次跑起来，报的是**探针自己**的一句读数（`-> /proc/cmdline could
not be read` —— 箭头后面一个路径，被读成了 `> /proc/`）。所以规则改成"`>` 前面不能紧跟 `-`"，而且**两个方向
都要证明**：

* `x > /proc/sys/kernel/foo` 和 `echo 1 >/sys/module/bar/baz`（有空格和没空格两种写法）—— **仍然抓到**；
* `say "     -> /proc/cmdline could not be read"` —— **不算写操作**。

这两条一起才说明"排除箭头"没有把规则削弱成一条什么都抓不到的规则。一个会在**正确的探针**上报错的守卫，
它的下一步通常是被人**放宽到不再守卫任何东西** —— 这一条把那个下一步堵住了。

---

## 6. 这一篇**不**证明什么

* **不证明 modem 是坏的**，也不证明它是好的。它只给出**该问的问题**和**一次能回答它的运行**。
* **不证明固件"不在搜索路径上"** —— 那要设备上的读数（§4 第 2 节），而探针还没在设备上跑过。
* **不证明 §3.5 那两条机制里哪一条成立**（也可能两条都不成立）。§3 全部是**镜像上的**读数：固件在分区上、
  分区在 fstab 里、rootfs 里没有 `/lib/firmware`、`/vendor` 是一条软链、halium 的 mount 循环读的那个 fstab
  一旦 glob 没展开就会**静默空转**。**哪一条在真机上发生，只有设备上的读数说了算。**
* **不证明设备上那份 halium 的 Android ramdisk 有没有 fstab。**"解出来那棵树的根"离线看不到（它在
  halium 的 system 镜像里），所以这一条**只能**在设备上 `ls` —— 这正是探针第 3 节现在做的事。

  > **2026-09-24 追记（[`151`](151-the-question-that-was-filed-as-unreadable-offline.md)）：这一条也被 [`151`](151-the-question-that-was-filed-as-unreadable-offline.md) 推翻。**
  > 那份 ramdisk **离线看得到**，读数是 **65 个条目、没有 fstab**，所以这条不再是"不证明"里的东西——
  > 它现在是**一条离线读数**（`bash scripts/host/zl1-modem-mount.sh`），设备上那句 `ls` 成了对它的确认。
  > 这一条留在这里，是因为它示范了**一条"我证明不了"可以伪装成一条发现**：前提里那个"看不到"是真的，
  > 而它说的是**另一个文件**。
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
scripts/host/zl1-post-recovery-capture.sh             # 0 系列读数；MODEM 探针现在是默认集里的 04b
scripts/host/zl1-heat-fix-chain.sh --yes              # 发烫：部署 → 激活 → 90 s → 证明 → 退役 keeper → governor
scripts/host/zl1-gps-first-client.sh --seconds 180    # 需要手边有人：把 "detect current location" 打开
```

**这一轮把探针接进了 `zl1-post-recovery-capture.sh` 的默认集（第 04b 步）**，而不是让它留成一条要手打的
`scp`。理由是它和 01/02 是同一类：**只读、从不打开块设备、不需要人**，而 05/06 被默认跳过有它们自己的理由
（其中一件有写模式，而且两次 EDL 前最后跑着的都是指纹那件）。boot 是**用一根手指换来的**，所以
telephony —— 唯一一个**真机读数一次都没取过**的子系统 —— 应该由那次 boot 顺带带上。

接线时抓到第二个同族缺陷，而且它在**上一层**：capture 自己的 harness 把"它认识的 callee 标记"写死在一张
表里，于是**真的跑了六步**的一次运行被读成"exactly five steps"——新那一步对下面每一条断言都是不可见的。
现在那个提取器**从一个具名的表里导出**，并且**看到自己不认识的标记就拒绝运行**：往被测脚本里加一步而忘了
加进这张表，会变成一次 setup failure，而不是一次安静的少数。这正是这个仓库记过的
"an extractor that drops an item" 形状。

### 7.1 那次真机运行要看什么（探针是第一次跑，所以先把"要看哪几行"写下来）

探针的输出是七节，但真正决定下一轮方向的只有四条读数，而且它们**都只在设备上存在**：

| 读数（第几节） | 两种可能，以及它们各自意味着什么 |
|---|---|
| **cmdline 上的 `firmware_class.path`**（2） | 应当是 `/vendor/firmware_mnt/image`。**如果不是**，那说明这个 port 的 boot 和镜像里的那份不一样 —— 那是比 modem 更大的发现 |
| **那条路径 `readlink -f` 之后是什么**（2/3） | 解析到 `/android/vendor/firmware_mnt/image`（软链被跟随）还是"解析不了"（软链悬空）—— 后者说明**没有任何东西挂在那里** |
| **`/var/lib/lxc/android/rootfs/fstab*` 在不在**（3） | 在：halium 的循环有机会挂；**不在：那个循环一件都没挂，而且它不会报错** —— modem 的整个故事到这一行就结束了，而且它是**一个挂载问题**，不是硬件问题 |
| **内核日志里的 `request_firmware`**（4） | 与上面三条**互相印证**：路径对 + 挂了 + 仍然失败 → 下一步才是 TZ/验签（`qcom,pil-self-auth` 是开着的），而不是继续怀疑挂载 |

**这四条都不是"结论"，是"这一轮要读的四行"。**在任何一条被读出来之前，这一篇里的一切仍然只是**离线可以
核对**的东西；而设备现在在 EDL，唯一的出口是物理长按电源 10–20 秒（只有用户能做）。

> **2026-09-24 追记（[`151`](151-the-question-that-was-filed-as-unreadable-offline.md)）：这张表里的第三行已经不是设备读数了。**
> **`/var/lib/lxc/android/rootfs/fstab*` 在不在**这一条，离线已经读到：**不在**（那个 ramdisk 65 个条目，
> 没有 fstab）。所以它落在右边那一格——**那个循环一件都没挂，而且它不会报错**——而这一格现在带着一条
> **离线可复现**的读数，而不是一条等待。剩下三条仍然只在设备上存在，而且顺序变了：**第四条（内核日志）
> 现在是第一条**，因为假设它印证的那个前提已经被离线证实了。
