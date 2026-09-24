# 154 — 这块板上没有内核侧在加载调制解调器，所以那一次挂载必须自己发生

**日期**: 2026-09-24
**状态**: 本轮**没有碰设备**。这一页把 docs 120/151 留下的另一半补完：**内核侧没有任何客户端在加载调制解调器**——
不是"加载失败"，是**没有调用者**；因此"把固件分区在开机时挂上"不是一种修法，而是**唯一**的那条路。
修法是一次 initramfs 改动（**一条挂载行 + 三个静默变响**），配一个 **40 项**的离线 harness；
镜像已经构建并逐项验过：**只有 initramfs 是故意改的**，撤销就是刷回上一张 boot 镜像。

**接续**: [`120`](120-the-subsystem-nobody-has-looked-at.md)（那个没人看过的子系统：cmdline 把内核指对了，
而那条路径是一个软链）、
[`151`](151-the-question-that-was-filed-as-unreadable-offline.md)（halium 的挂载循环**静默**失败，
"那个 ramdisk 里有没有 fstab"曾是**设备侧**读数，其实是这台笔记本上的文件；容器里那个 `vendor`
是**真目录并且是空的**——就是这次缺掉的挂载留下的**占位**）、
[`152`](152-a-reading-is-only-as-good-as-the-identity-of-its-input.md)（读数只和它读的那个文件的**身份**一样可信）、
[`153`](153-the-premise-was-false-and-the-answer-was-on-this-laptop.md)（**输入不可替换的仪器，任何 fixture 都驱动不了**）、
[`24`](24-reproducible-working-image.md)（可复现的已知good镜像）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 这一轮问的是什么？ | docs 120/151 只到"halium 什么都没挂、也没出声"。**但"没挂载"为什么等于"调制解调器起不来"？**挡住启动的那个**消费者**是谁？ |
| 谁在加载它？ | **没有人在加载。** 这个内核里 `subsystem_get()` 一共三处调用点：**两个客户端**（glink xprt 与 SMD ipc-router）加一处 `__subsystem_get` 内部的依赖查询；而**设备树把两个客户端都关了** |
| glink 那一处怎么被关的？ | `disable_pil_loading` 由 `qcom,pil-label` 决定（`ipc_router_glink_xprt.c:779-787`：有这个属性才置 `false`）。**五棵设备树上 `/soc/qcom,ipc_router_modem_xprt` 都没有它**，于是 `:417-418` 那个 `if (!glink_xprtp->disable_pil_loading)` **根本不成立** |
| SMD 那一处怎么被关的？ | `ipc_router_smd_xprt.c:467-484` → `smd_edge_to_pil_str()`（`smd.c:781-795`）在 `skip_pil` 为真时**返回 NULL**，调用点 `:476` 因此不执行。而 `skip_pil` 来自 `qcom,not-loadable`（`smd_init_dt.c:244-245`）——**这个属性就写在 `/soc/qcom,smem@86000000/qcom,smd-modem` 上** |
| 这两个键是同一个键吗？ | **不是。** `qcom,is-not-loadable`（`pil-q6v5-mss.c:370`）和 `qcom,not-loadable`（`smd_init_dt.c:244`）是两个不同的键。前者在 `/soc/qcom,mss@2080000` 上**没有**，所以 MSS 的 PIL 驱动**照常 probe、照常注册** |
| 那还剩什么路径？ | **用户态的一次 `open()`。** `pil-q6v5-mss.c:207` 把 `subsys_desc.name` 写死为 `"modem"`；`subsystem_restart.c:1317-1318` 用 `device_create(..., "subsys_%s", …)` 造出 **`/dev/subsys_modem`**；它的 `.open`（`:1245`）调 `subsystem_get_with_fwname("modem", subsys_dev->desc->fw_name)`。**固件是在有人打开这个字符设备的那一刻才被请求的** |
| 所以修法是什么？ | **让固件分区在开机时就在那里。** 而它从来不在：halium 读的那份 Android ramdisk **一行 fstab 都没有**，`cat` 对未展开的 glob 失败，`while read` 的主体一次也没跑过——**没挂载、也没出声**（docs 120/151） |
| 改了几个地方？ | **一条挂载行 + 三个静默变响**：未匹配的 glob、设备不存在的行、挂载失败。三者都**只报告**，**不中断**启动（这个 initramfs 不在 `set -e` 下——从 `/init` 与 `/scripts/functions` 里读出来的，不是假设） |
| 只挂一行，为什么？ | **一次 boot 一个变量。** 这张镜像要回答的是"**内核能不能找到**调制解调器的固件"。把 vendor 分区一起挂上（值得做）会让一次失败有两个成因，所以它是**下一步**那次测量的题目 |
| 离线怎么验？ | 新 harness **40 项**：它**真的打上这个补丁、再运行打好补丁的 `mount_android_partitions`**（`mount` 与 `tell_kmsg` 换成替身），断言的是它**做了什么**——建了哪个目录、用了哪个设备、做不到时**说了什么** |
| 镜像动了多少？ | 归档成员 **349 → 350**（普通文件 **322 → 323**）：**新增** `zl1-android-fstab`，**只改了** `scripts/halium`。内核 blob 差 **29 字节**（build-id note：同一份源码、不同时刻构建，**照实印出来**）、附着的五棵设备树与 cmdline **逐字节相同** |
| 家族全量跑？ | **37 个 harness / 4852 检查 / 全绿**（仓库自指纹未变） |
| 动设备了吗？ | **没有。**设备仍在 **fastboot**（`33e80afe`，`18d1:d00d`），本轮没有一条会改变设备状态的命令 |

---

## 2. 为什么"谁在加载它"必须在内核侧问

docs 120/151 把"halium 什么都没挂"读成了事实：那是一个**必要条件**被证伪。但一个必要条件被证伪**不**
说明它就是**那一件**缺的东西——除非有人**消费**它。

这一页先去找那个消费者。做法是把出货源码里**每一个**能为 modem 触发加载的位置读出来（不是列出"可能的"，
而是 `subsystem_get` 的**全部**调用点——一共三处，其中 `subsystem_restart.c:840` 那一处是
`__subsystem_get` 内部的**依赖查询**，它只为**已经被请求**的子系统服务，不是第三个消费者，
所以真正的客户端只有两处），再看**这一块板**上哪一个真的会执行。答案是：在本内核构建里，
为 modem 调用的客户端只有两处，而设备树把两处都关了。

**这一节的方法比结论重要**：docs 120 的"挂载循环静默失败"是**在 halium 里**读出来的，所以它只能回答
"没挂载"；**为什么没挂载要紧**只能在**内核侧**回答。两边各自成立，合起来才是"固件永远不在那里"。

---

## 3. 全部四个位置：两个被设备树关掉，剩下的一处由用户态触发

| 位置 | 出处 | 这一块板上会发生什么 |
|---|---|---|
| glink xprt | `ipc_router_glink_xprt.c:417-418`，闸门值来自 `:779-787` 的 `qcom,pil-label` | **不执行**：五棵树上 `/soc/qcom,ipc_router_modem_xprt` 没有 `qcom,pil-label`，`disable_pil_loading` 保持 `true` |
| SMD ipc-router | `ipc_router_smd_xprt.c:467-484` → `is_pil_loading_disabled()`（`:518-531`）→ `smd_edge_to_pil_str()`（`smd.c:781-795`） | **拿到 NULL**：`qcom,not-loadable` 写在 `/soc/qcom,smem@86000000/qcom,smd-modem` 上（`smd_init_dt.c:244-245` 把它变成 `skip_pil`），`smd.c:788` 于是返回 NULL |
| MSS PIL 驱动本身 | `pil-q6v5-mss.c:207` 写死名字 `"modem"`，`:370` 读 **`qcom,is-not-loadable`** | **注册并建立 `/dev/subsys_modem`**：那个键在 `/soc/qcom,mss@2080000` 上**没有**，所以 `pil_mss_driver_probe` 走的是**可加载**的那条分支 |
| `/dev/subsys_modem` 的 `.open` | `subsystem_restart.c:1317-1318` 造设备、`:1245` 请求固件 | **这是唯一会执行的一处**，而它由**用户态**触发 |

**这是本轮最要紧的一句**：这台设备上，调制解调器的固件**不是被内核的某个子系统加载的**，而是被
**用户态打开一个字符设备**时请求的。所以"固件在不在文件系统上"不是一条优化，而是**那条路径存在的全部前提**。

**而两个键长得像、含义不同**，这一点值得单列：`qcom,is-not-loadable` 让驱动**不注册**，
`qcom,not-loadable` 让 **SMD 边不代为加载**。把前者的读数套到后者（或反过来）会把整个判断**倒过来**：
`/soc/qcom,mss@2080000` 上没有 `qcom,is-not-loadable`，所以驱动是在的；而 `qcom,smd-modem` 上有
`qcom,not-loadable`，所以 SMD 那条路是断的。**两个"没有"和"有"，意思完全相反。**

### 3.1 这些读数的身份

- 来源：`/mnt/data/halium-zl1-candidates/halium-boot-zl1-v63-modemfw.img` **里附着的那五棵设备树**
  （blob 2044818 字节，五棵首尾相接：407291 / 411874 / 407287 / 411075 / 407291，偏移 0、407291、
  819165、1226452、1637527）。**五棵上的读数一致**，所以上面每一条都不是"某一棵树"的读数。
- 内核侧引用的源码：`/mnt/data/halium-zl1-build/kernel/leeco/msm8996`——**编译出正在跑的那张镜像的
  那份源码**（docs 153 已经用五份 DTB 的 sha256 把这件事钉住）。本页每条引用都带**行号**，是读出来的，
  不是转述的。

---

## 4. 三个静默：从出货文本里逐行读出来的

修补的对象 `scripts/halium` **就是设备运行时的那一份**（身份见 §6.2）。它有三处不说话的地方：

| # | 静默 | 出处 | 后果 |
|---|---|---|---|
| 1 | **glob 没有匹配任何文件** | `cat ${fstab}` 失败，`while read` 的**主体一次也不跑** | 这台设备**每一次**启动都走这里：它读的 fstab 在它解出来的 Android ramdisk 里，而那份 ramdisk **一行 fstab 都没有** |
| 2 | **一行 fstab 的设备不存在** | `[ ! -e "$path" ] && continue` | 一个合法的 fstab 本来就会列不存在的分区，所以这条**不该**报错；但在这台设备上，整个修复都压在"这张分区被找到"上，**成与不成都要说** |
| 3 | **挂载失败** | `mount … ` 的返回值没人看 | 目录空着、日志安静——和"从来没试过"是**同一个症状**，而这两者要分开 |

**这三条从来没有中断过启动**：这个 initramfs **不在 `set -e` 下**（从 `/init` 与 `/scripts/functions`
读出来的）。所以修补的方向是**把话说出来**，而不是"把错误重新变成致命"——后者会把一个安静的坏启动
换成一个吵闹的坏启动，而**启动本身不是这一页要修的东西**。

---

## 5. 修法：一条挂载行，加三句真话

新增文件 `zl1-android-fstab`（**一条数据行**）：

```
/dev/disk/by-partlabel/modem    /vendor/firmware_mnt    vfat    ro,shortname=lower,uid=0,gid=1000,dmask=227,fmask=337
```

**为什么挂载点是 `/vendor/firmware_mnt`**：内核按 `firmware_class.path` 找固件，而**每一条 zl1 cmdline
（包括原厂镜像的）都写着 `firmware_class.path=/vendor/firmware_mnt/image`**。UT 根里 `/vendor` 是
`/android/vendor` 的**符号链接**，而 `request_firmware()` 是在**内核**的根里解析它的——所以那个目录
必须是 Android 侧一个**真实挂载的文件系统**。FAT16 的 modem 分区自己的根下是 `IMAGE/` 与 `VERINFO/`，
于是内核要的那个文件正是 `<挂载点>/image/modem.mdt`——**`firmware_class.path` 指的就是这个目录。**

**`.mdt` 这个后缀也是读出来的，不是推断的**：`subsystem_restart.c:1647-1648` 让 `fw_name` **默认等于
子系统名**（`"modem"`），`peripheral-loader.c:794` 再 `snprintf(fw_name, sizeof(fw_name), "%s.mdt",
desc->fw_name)`，`:795` 把那一个名字交给 `request_firmware()`。所以这条链的最后一环是
**`request_firmware("modem.mdt")`**，而它失败时内核会打一行 `Failed to locate modem.mdt`
（`pil_err` = `dev_err(dev, "%s: " fmt, desc->name, …)`，`peripheral-loader.c:45-46` 与 `:798`）。

**为什么挂载点建得出来**：halium 自己的尾巴会做 `ln -sf system/vendor ${mount_root}/vendor`。
**走上那一支，挂载点就永远建不出来**——链接会解析进只读的 Android system 镜像里。
这条 fstab 行让 `/android/vendor` 保持**真实目录**（`/android` 是补过的 halium 挂的 tmpfs），
挂载点就落在这个挂载根上，harness 对**两个条件**都断言（目录存在，且 `/android/vendor` 不是链接）。

**选项**：`ro`（这个分区从不从这里写）与 `shortname=lower`（内核问的名字是 `modem.mdt`）是**承重**的；
`uid=0,gid=1000,dmask=227,fmask=337` 是 Android 自己的；**减掉了它 fstab 里的
`context=u:object_r:firmware_file:s0`**——这条 cmdline 说 `security=apparmor`，SELinux 的 context
在这里是一个谁都不认的选项。**这四项里只有一项本轮是"读出来的"、另一项是"抄来的"**：`ro` 是这个
工程自己的决定（那个分区从不从这里写），其余三个是**原样抄 Android 自己的 `/etc/fstab.qcom`**。
`shortname=lower` 之所以必须留，是因为**同一行里有它**——即那份 fstab 的作者面对的是一个名字为大写的
卷；**卷上的名字本轮没有直接读过**，这是推断，不是读数。

**为什么只有一行**：见 §1 表格最后一条。`persist` 也在 Android 的 fstab 里，而它**绝不能**从这里挂：
Android 是**可写**挂它的，这个工程不写那个分区。

---

## 6. 被否掉的四个设计

| 设计 | 为什么不要 |
|---|---|
| **在 `pre_mountroot` 里挂**（第一版的思路） | halium 的 `/init` 在 `pre_mountroot` **之后**才 `cp -a /tmpmnt /` 并 `pivot_root`（**读 `/init` 读出来的**，不是推测）：挂在 `/tmpmnt/...` 上的东西会**留在地板下面**。而 docs 151 已经量到这个形状的另一半：容器里那个 `vendor` 是**真目录并且是空的**——挂载缺失留下的占位，"空目录"与"被盖住的目录"是两件要分开的事 |
| **insmod** | 根文件系统是**只读**的（`/` 是只读镜像，只有 `/etc` 那一带是 rw bind mount——两条都已在设备上量过：docs 93 记 `/etc/systemd/system` 是少数几个可写白名单路径之一，docs 106 记 `/etc` 本身不是），模块放不进去；而且**不需要**：PIL 是编进内核的（这个树 `arch/arm64/configs/lineage_zl1_defconfig:3900` 就是 `CONFIG_MSM_PIL=y`，`:3901` 是 `CONFIG_MSM_PIL_SSR_GENERIC=y`），设备上别的子系统（adsp、venus）本来就走这条路被加载 |
| **顺手把 vendor 分区也挂上**（以及 `persist`） | vendor 值得做，但那是**下一步**；`persist` 是**永不** |
| **加一个 `grep /proc/mounts` 的"是否已挂载"守卫** | **输入不可替换的仪器，任何 fixture 都驱动不了**（docs 153）。而且这个位置在容器起来之前、只跑一次，没有第二个能挂它的人。能测的分支才叫分支 |

---

## 7. 镜像与它的验证（都是本轮实测的数字）

| 项 | 读数 | 怎么读的 |
|---|---|---|
| 新镜像 | `/mnt/data/halium-zl1-candidates/halium-boot-zl1-v63-modemfw.img`，18010112 字节，sha256 `6d5ca2b175616f6a022b261c7a3e0ace462f33bbfc07562bb990d87129223c80` | `sha256sum` |
| 归档成员 | **349 → 350**（普通文件 **322 → 323**） | 在两张镜像上数 cpio 成员 / 走文件树 |
| 新增 | `zl1-android-fstab`（2608 字节，模式 **0644**——读的，不是执行的） | 从新镜像里取出来 |
| 改动 | **只有** `scripts/halium`（24508 字节） | 与参考镜像逐项比对：只有这一个变 |
| 内核 blob | **29 字节不同**，位置连续（偏移 0x1849e40 起） | build-id note：**同一份源码、不同时刻构建**。这里**照实印出来**，不吞掉 |
| 附着的五棵设备树 | **逐字节相同**（2044818 字节） | 与参考镜像逐字节比 |
| cmdline | **逐字节相同** | 同上 |

**"只有 initramfs 是故意改的"是这一页给设备的承诺**：内核、设备树、cmdline 一个字节都没动，
所以如果这张镜像在真机上出了问题，**撤销就是刷回上一张 boot 镜像**——不需要别的动作，
也不需要碰任何别的分区。

### 7.1 构建器里补的一处

`make-v63-boot-image.sh --patch FILE` 允许补丁**新增**文件，而 `patch` 建出来的文件带**构建机的 umask**。
不改这一处，归档里记录的模式——**以及镜像的哈希**——就会取决于谁在哪台机器上构建。
构建器现在显式 `chmod 0644`。**这是本轮 harness 逼出来的一处真缺陷**（见 §8 第 4 条）。

---

## 8. harness：40 项，而它做的事一句话说就是"真的跑一遍"

`scripts/host/zl1-halium-modem-mount-selftest.sh`。**它与文本 diff 的区别**：它**打上补丁**，
然后把打好补丁的 `mount_android_partitions` **取出来运行**（`mount` 与 `tell_kmsg` 换成替身），
断言的是**行为**。

1. **fixture 是那个真文件，不是它的摘要**：`scripts/host/fixtures/halium-02dd7445` 是**设备正在跑的
   那张 boot 镜像里**的 `scripts/halium`（21943 字节，sha256 `02dd7445…`）。身份**断言两次**——登记的
   哈希，以及在候选镜像在这台笔记本上时**与镜像逐字节比对**（不在时**明印一条 SKIP**，不是默默通过）。
   这正是 docs 152 那条：**读数只和它读的那个文件的身份一样可信。**
2. **打补丁用的是构建器自己的命令**（`patch -p1 --forward --silent`），并断言这个补丁**只碰两个路径**、
   **第二次应用被拒绝**——一个会重复打补丁的构建路径会**悄悄**把工作做两遍。
3. 新镜像在时，把 `scripts/halium` 与 `zl1-android-fstab` **取回来**，要求与 harness 自己造出来的
   **逐字节相同**：产物和 harness 不可能各说各话。
4. **八个场景**：没有 fallback（那最初的一句静默，现在被报出来，且什么都没挂）；有 fallback（读的
   确实是它的那一行）；glob **匹配上了**（fallback **不被读**——对一份真有 fstab 的 ramdisk 这是 no-op）；
   设备存在（用的是 fstab **点名**的那个设备，配上这份 initramfs 自己的选项）；**挂载点落在
   `/android/vendor/firmware_mnt`，且 `/android/vendor` 是真实目录而不是链接**；设备不存在（报出来，
   不是静默 `continue`）；挂载失败（报出来，**并且不中断**）。
5. **每一条"报出来了"都在未打补丁的 fixture 上再跑一次，必须不出现**。一个对**它要修的那个脚本**
   红不起来的 harness 不是证据。
6. **安全断言**（§5 那条线的静态部分）：只有一行、**只读**、来源是 **`modem`** 分区、且不含
   `persist`/`fsg`/`fsc`/`modemst*`/`boot`/`recovery`/`misc`/`dsp`/`bluetooth`/`userdata`/`system`/`cache`。
7. 两个出货文件都**不含**任何碰设备的命令名；第 7 节是这个 harness 在健康页里的**引用漂移守卫**（docs 110）。

---

## 9. 这一篇**不**证明什么

* **不证明调制解调器会起来。**它证明的是**固件会被找到**。挂上之后 PIL 会不会成功、调制解调器会不会
  注册到 QMI，都是**设备侧**的读数。
* **不证明在设备上那次挂载会成功。**`/dev/disk/by-partlabel/modem` 在 initramfs 里**存不存在**，
  是 initramfs 跑过 udev 之后的事——那是设备侧的读数，本页只能证明**函数会去用它**，以及**用不到时
  会说出来**。
* **不证明 `/vendor` 挂上之后容器会更好。**那是下一步那次测量的题目，不是这一页的结论。
* **不证明三条报告在真机上会出现。**harness 证明的是**这个函数会这么说**；它出现在 `kmsg` 里的
  前提是那条路径真的走到。
* **不证明 `/dev/subsys_modem` 在真机上存在。**这一页证明的是**源码会造出它**（`CONFIG_MSM_PIL=y`
  下 MSS 驱动 probe 成功才有），而一条真机上的 `ls /dev/subsys*` **本轮没做**。它存在与否不改变修法
  （固件分区要么该在，要么不该在），但它决定"挂上之后**谁**会去请求固件"这句话该不该当成已确认。
* **不证明这一行对别的手机正确。**它抄的是**这块板**的 Android fstab，写在**这块板**的 initramfs 里。
* **不证明"内核侧没有加载者"这句话对所有别的子系统成立。**它证明的是**这一个**：全部调用点读过了，
  两个闸门都读出值了，五棵设备树读数一致。

---

## 10. 设备状态与下一步

整轮**没有写设备**：没有挂载、没有写镜像、没有 flash、没有一条会改变设备状态的命令。设备在
**fastboot**（`33e80afe`，`18d1:d00d`，端口 3-3）。

不需要设备就能重跑这一页的任何一条读数：

```
bash scripts/host/zl1-modem-mount.sh                         # docs 151 的读数（ramdisk 里没有 fstab）
bash scripts/host/zl1-halium-modem-mount-selftest.sh         # 40 检查（打补丁 + 运行）
bash scripts/make-v63-boot-image.sh --patch boot/patches/0200-halium-modem-firmware-mount.patch \
    --out /tmp/modemfw.img --verify-against /mnt/data/halium-zl1-candidates/halium-boot-zl1-v63-rebuilt.img
```

挡住整个工程的那一步仍然**在手上**：插**墙充**，然后
`bash scripts/host/zl1-battery-gate.sh --samples 9 --interval 60`；读数许可之后
`scripts/host/zl1-one-boot-runbook.sh --yes` 就是那一次 boot。**把
`halium-boot-zl1-v63-modemfw.img` 刷进去，会是调制解调器这条线的第一次真机检验**——同时也是两个
散热修复和指纹存储目录在硬件上的第一次真跑。

### 10.1 那一次 boot 上要看的那一行

```
Failed to locate modem.mdt
```

**这一行出现**，说明**有人走到了请求固件的那一步、而文件不在**——也就是这次挂载没成功，
或者挂上了但 `IMAGE/` 不在预期位置。
**这一行不出现**，则有两种可能，而它们要靠挂载点的读数分开：要么挂载成了、固件也在（接下来该看的是
PIL 自己那几行），要么**根本没有人打开过 `/dev/subsys_modem`**（那说明消费者不在这一层，
而不是文件不在）。`dmesg | grep -i 'modem.mdt\|subsys_modem\|pil'` 就是这一页留给下一次 boot 的问题。
