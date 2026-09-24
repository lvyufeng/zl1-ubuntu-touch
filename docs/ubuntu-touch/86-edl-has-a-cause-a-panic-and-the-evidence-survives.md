# 86 — EDL 不是凭空来的：一次内核 panic 就能把它直接送进去，而证据还在

**日期**: 2026-09-23
**状态**: 纯离线的一轮（设备仍在 EDL，`05c6:9008` / port 3-3，跑 `zl1-health-check.sh --quiet` 确认过）。`80` §7 记下了那次掉进 EDL 的**状态**，但没有**归因**：那一轮没有写任何分区、没有写 boot 镜像、没有碰 modem/radio 分区、也**没有跑过任何 QDL/firehose 工具**。于是"为什么"一直空着。这一轮把那份内核树（就是编出**当前刷着的那个镜像**的树）读了一遍，答案是：**这台设备上存在一条从"内核 panic"到"EDL"的路径，而且它是默认开着的**。同时找到两处**还会说话的证据**——所以这不是一个"解释"，而是一条可以验证、并且已经做成了命令的东西：`scripts/device/zl1-edl-postmortem.sh`。

**接续**: [`80`](80-the-ut-camera-app-starts-and-our-preload-was-breaking-egl.md) §7（第一次 EDL，未归因）、[`49`](49-two-cores-that-are-not-tls-wifi-stuck-at-wcnss-and-a-trip-into-edl.md) §5–6（上一次 EDL 和唯一的归来方式）、[`85`](85-is-the-device-back-is-one-command-now.md)（回来后第一条命令）、[`58`](58-the-secure-world-refused-and-the-sensors-went-with-it.md)（`scm_call` 会失败、以及为什么日志得先存下来）

---

## 1. 进入 EDL 的三条路，两条是软件，一条默认开着

读 `drivers/power/reset/msm-poweroff.c`（`CONFIG_POWER_RESET_MSM=y`，`lineage_zl1_defconfig:2226`）：

| 路径 | 代码 | 需要什么 |
|---|---|---|
| **内核 panic** | `msm_restart_prepare()` 里 `set_dload_mode(download_mode && (in_panic \|\| restart_mode == RESTART_DLOAD))`（`:278`），紧接着 `msm_trigger_wdog_bite()`（`:386`） | `download_mode`=**1**（`:63` 的编译期默认值）+ `CONFIG_MSM_FORCE_WDOG_BITE_ON_PANIC=y`（`watchdog.h:17–18` 把它定成 1）——两个都满足 |
| **`reboot edl`** | `strncmp(cmd, "edl", 3)` → `enable_emergency_dload_mode()`（`:333`） | 有意地敲一条命令 |
| PMIC 欠压（UVLO） | `dload_on_uvlo` 模块参数 | **关的**：`static bool dload_on_uvlo;` 默认 false，只能手写开 |

第一条是重点，因为它是**被动**的：它不需要任何人做任何事，只需要内核 panic 一次。而"内核 panic 一次"对一个正在移植的端口来说是**日常**——不是我方写了什么危险命令，是 HAL/HWC/驱动里任何一处 null deref 都可能。链条是：

```
panic  ->  panic_notifier_list 上注册的 panic_prep_restart() 把 in_panic 置 1（:98）
       ->  do_msm_restart()  ->  msm_restart_prepare()  ->  set_dload_mode(1)
       ->  scm_set_dload_mode(SCM_DLOAD_MODE=0x10)（:119 那条 TCSR 退路）
       ->  msm_trigger_wdog_bite()（强制，因为 FORCE_WDOG_BITE_ON_PANIC=1）
       ->  复位，而 dload 标志已经被置上  ->  引导程序进 EDL，而不是进系统
```

这不是 EDL 第一次有原因，之前有两条：`scripts/README.md` 末尾记着那批 `fastboot boot` 实验"两次把设备送进 EDL"；`49` §5 那次则归因于 `cnss`/`cnss_pci` 的 `unbind`（拆掉 PCIe 链路撞上 SoC 的 crash-dump 路径）。两条都是**外部动作**触发的（一条命令、一次 unbind），而且都解释不了 `80` §7：那一次设备**正跑着 UT**（RNDIS 在、SSH 在），整个会话里既没有 fastboot 命令也没有动过驱动。所以上面这条是**第三条**路，也是唯一一条不需要外部命令、不需要任何人做任何事的路。

两个细节值得写下来，因为它们决定这条路径**在这台设备上到底走哪一段**：

* **IMEM 里没有那个节点。** `msm8996.dtsi` 的 `qcom,msm-imem@66bf000` 只有 `mem_dump_table` / `dload-type` / `restart_reason` / `boot_stats` / `pil`——**没有** `qcom,msm-imem-download_mode`，也没有 `emergency_download_mode`（`le-common.dtsi` 也没加）。所以 `set_dload_mode()` 里那两段 `__raw_writel(0xE47B337D / 0xCE14091A)` 因为地址是 NULL 被跳过；
* **于是走的是 TCSR 那条。** `restart@4ab000` 提供了 `tcsr-boot-misc-detect` = `0x7b3000`，`scm_set_dload_mode()` 在 SCM 的 DLOAD 调用不可用时就是 `scm_io_write(0x7b3000, arg1)`。**离线只能读到"代码和 DT 都给了它这个寄存器"**，读不到它某一次是否真的写成功（`58` 记着这台设备的 `scm_call` 是会返回 -12 的）。这一点在 §4 里由设备自己回答。

## 2. 没有出口——这句话终于有出处了

`85` 把这个状态路由到"长按电源 10–20 秒"，理由是 `49` §6 里那次就是这么回来的。现在可以把"没有软件出口"从经验写成机制：**EDL 里跑的是 SoC 的 boot ROM 加载器，那个会运行代码的内核恰恰就是没有在运行的东西。** 内核里任何"离开 EDL"的代码都不可能被执行；能做的只有让 boot ROM 透过 USB 收一个 firehose 程序（本项目明确不用，见约束），或者把它复位回正常引导路径——而后者只有人按电源键才能保证（dload 标志还挂着的时候，一次软复位只会**再进一次** EDL）。

所以 `85` 里 EDL 那一行的处置、和 `80` §7 的处置，不是保守，是唯一解。

## 3. 证据：pstore 里那一份会活过复位

那个 panic 会留下东西，这是这一轮第二个发现：

* `CONFIG_PSTORE_RAM=y` + `CONFIG_PSTORE_CONSOLE=y`（`defconfig` 4129–4132，在编出来的 `out/target/product/zl1/obj/KERNEL_OBJ/.config` 里复核过）；
* `msm8996-le-common.dtsi:29–35, 65–76`：ramoops 区域是 1 MiB @ `0x91500000`，`no-map` 保留，且 **`android,ramoops-dump-oops = <0x1>`**（`fs/pstore/ram.c:283` 就是读这个决定 oops 记不记）；
* 所以一份 **console 记录**（`/sys/fs/pstore/console-ramoops-0`）和一份 **oops 记录**（`dmesg-ramoops-*`）会落到 `/sys/fs/pstore/`。

这是**唯一能活过复位**的见证：`58` 那个 kmsg 环形缓冲是内存里的，复位就没了（这也是为什么它要靠定时快照 `dmesg` 到 `/userdata`）。而 kmsg 那套装好的归档逻辑（`install-kmsg-drain.sh`）提供了**第二个、独立的**见证：开机时把上一个 boot 的 `boot-*.log` 搬进 `keep/boot-<上一个 boot_id>/`，所以 UT → EDL → UT 这一圈之后，**`keep/` 里最新的那个归档就是死掉的那个 boot**。

`scripts/device/zl1-edl-postmortem.sh` 就是把这两份见证读出来的一条命令：先问设备自己（`/proc/config.gz`，`CONFIG_IKCONFIG_PROC=y`，不是问那棵树）那条路径武装了没有、`download_mode` 现在是几、`/sys/kernel/dload/` 在不在；再按顺序读 pstore 和 kmsg 归档，用同一串死亡特征（`Kernel panic`、`Unable to handle kernel`、`WDOG`、`Going down for restart` …）判读；最后给三条分支的判语。

## 4. 那个"能关掉"的开关，以及为什么它不持久

`download_mode` 是个模块参数（`:95`，0644），运行时能写：

```sh
echo 0 > /sys/module/msm_poweroff/parameters/download_mode      # 仅本 boot 有效！
```

写 0 之后，同一个 boot 里再 panic，`set_dload_mode(0)` 会把标志清掉，于是复位后**正常引导**而不是进 EDL。

**但它不持久，这点必须写清楚**：`download_mode` 是编译期写死的 `1`（`:63`），而且是**每次开机由驱动自己重新写一遍**的——`msm_restart_probe()` 结尾就是 `set_dload_mode(download_mode)`（`:582`）。所以运行时那次 0 只活在当前这个 boot 里。

想永久改掉，只有改内核一行（`static int download_mode = 1;`）+ 重新编译 + 刷 boot 镜像。**这一轮没有做，也不打算在没有明确许可时做**：那是一次刷写，而 `pstore` 是否活过复位、`download_mode` 写 0 在这台设备上是否真的生效，都还没有在真机上验证过。把它当成一个**候选阶段**记录下来，不是当成已经做出的决定。

## 5. 验证到什么程度（说清楚，包括脚本里被抓出来的两个真 bug）

* **来源是可信的**：所有配置都来自 `out/target/product/zl1/obj/KERNEL_OBJ/.config`——也就是编出当前刷着那个镜像的同一份构建产物，不是 defconfig 的"应该如此"。
* **`zl1-edl-postmortem.sh` 的判语分支用合成树在本机跑过 5 个 case**：panic 只在 kmsg 归档里（判 FOUND）、panic 只在 pstore 里（判 FOUND）、两处都空且 `download_mode=1`（判"未归因 + 危险已武装"）、两处都空且 `download_mode=0`、model 不是 `LE_ZL1`（退出码 2，并且拒绝把结论说成关于这台设备的）。
* **在合成测试里抓出两个真 bug，这正是"跑一遍而不是相信它"的价值**：
  1. 判语里那句 `(`reboot edl` -> ...)` 的反引号被 shell 当成**命令替换**了——脚本在宿主机上真的去执行了一次 `reboot edl`（宿主机上失败："Failed to write reboot parameter file: Permission denied"）。**如果在设备上跑，它会真的把手机送进 EDL。** 已改成引号。
  2. 归档那一段用 `ls -t` 只取了文件名，`grep` 却是在当前目录下找它——于是"文件里明明有 panic"被判成"没有特征"。已改成拼完整路径。
* **这两个 case 现在是可重跑的**（`95`）：`scripts/host/zl1-edl-postmortem-selftest.sh` 把这段合成测试做成了 7 种设备状态、34 项检查的 harness，测的是**真脚本**（把设备路径 `sed` 改到假根树里跑），并且额外断言"什么都没被执行、什么都没被写"（PATH 最前面放 23 个记录自己被调用的桩 + 前后对假根树做 `find -printf` 快照对比）。**重跑立刻抓出第三个 bug**：§1b 的兜底快照查找是 `ls -tr "$K"/boot-*/`，**少了 `-d`**——它列的是归档目录的**内容**，循环拿到裸文件名，下一条 `ls` 就在调用者的当前目录里跑（演示里命中了宿主机一个无关的 `.log`）。那正是"这个脚本能找到的最有价值的东西"所在的那条路，而且失败是静默的（"快照里没有这行"看起来很正常）。和上面第 2 个 bug 同一族：当时修掉了 §3 那一处，漏了 §1b 的孪生兄弟——**一次性测试找不到这种，可重跑的 harness 第二次跑就找到了**。
* **没验过的**：整条路径在**真机**上的样子——`/sys/module/msm_poweroff/parameters/download_mode` 是不是这个路径（`msm-poweroff.o` → 模块名 `msm_poweroff`，脚本是 `for p in /sys/module/*/parameters/download_mode`，不写死）、`/sys/kernel/dload/` 存不存在、`/sys/fs/pstore` 复位后是不是真有东西、`/userdata/zl1-kmsg/keep/` 里是不是真的躺着那个死掉的 boot。**四件都还没在真机上出现过一次**，所以脚本凡取不到的地方都明确写"unavailable"并让退出码变 1，而不是把"读不到"说成"没有"。

  > **2026-09-24 更正（[`125`](125-the-device-read-those-four-things-already.md)）：上面这一条的四件里，有三件和第四件的一半，早就在真机上读到了，而且读了两次。**
  > 读数在 doc 107 那条命令留下的归档里：`tmp-post-recovery-20260923T145530Z/01-edl-postmortem.txt:14` 与
  > `tmp-post-recovery-20260924T013059Z/01-edl-postmortem.txt:13` 都写着
  > `/sys/module/msm_poweroff/parameters/download_mode = 1`（**猜测是对的，设备确认了它**）；
  > `/sys/kernel/dload` → `emmc_dload`，且 `emmc_dload = 0`；
  > `/userdata/zl1-kmsg/keep/` → 4 个 `boot-<boot_id>/`，其中一个带死亡特征和 Call trace。
  > `/sys/fs/pstore` 只被回答了一半：**目录存在而且可读**（归档打的是 EMPTY，不是"不存在"，
  > 这两个分支在本文件的脚本里是分开的），**但"它能不能活过一次复位"仍然没验过**——空的 pstore
  > 既符合"上次没 panic"，也符合"ramoops 没活过复位"，这正是下面那段自己写的话。
  > 这一段留着，是因为它是这个仓库最贵的一条纪律的说明：**一个推理写下来以后，读起来和一个读数一样**，
  > 而这次相反方向的版本是——**一条读数写下来以后，一句"没验过"可以比读数活得更久**。
* **不证明 2026-09-23 那次就是 panic**：它证明的是"这条路径存在且默认开着，并且证据会被留下"。真正的归因要等设备回来、`zl1-edl-postmortem.sh` 跑过一遍、看到那份 oops（并且时间对得上）才算。

## 6. 复现

```sh
# 设备一回来，第一条就是这个（只读）
scp scripts/device/zl1-edl-postmortem.sh root@10.15.19.82:/tmp/
ssh root@10.15.19.82 'sh /tmp/zl1-edl-postmortem.sh'
ssh root@10.15.19.82 'sh /tmp/zl1-edl-postmortem.sh --quiet'   # 只要判语
ssh root@10.15.19.82 'sh /tmp/zl1-edl-postmortem.sh --full'    # 打印整份记录
```

`85` 的那个健康检查现在把这一条排在第 **0** 位（在四条测量之前），因为它是唯一"只有这一次开机还读得到"的东西。

| 文件 | 作用 |
|---|---|
| `scripts/device/zl1-edl-postmortem.sh` | 新增。只读：`/proc/config.gz` 问机制、`/sys/fs/pstore` 和 `/userdata/zl1-kmsg/keep/` 两份见证、三条分支的判语。`--quiet` / `--full`；退出码 0=跑完、1=有见证读不到（报告不完整）、2=这不像 zl1 |
| `scripts/host/zl1-health-check.sh` | 改：`next` 列表加上第 0 条（`85` 描述的输出多了一行） |
| `docs/ubuntu-touch/86-*.md` | 本篇 |

## 7. 这一轮**不**证明什么

* **不证明 2026-09-23 那次 EDL 的原因是 panic**（§5）：只证明了这条路存在、默认武装、且会留证据。
* **不证明 pstore 在这台设备上活过一次复位**——ramoops 要引导程序配合保留那块 `no-map` 内存，**我们从未验证过**。所以脚本把"空的 pstore"明确写成"证明不了什么"，而不是"没 panic"。
* **不证明 `download_mode` 写 0 有效或安全**，也不证明它可逆（`:58–62` 那段注释警告某些 TZ 寄存器只能改一次，而 `scm_disable_sdi()` 其实在每次重启和每次关机时都已经无条件调用了）。
* 不证明 EDL 里的任何行为：那部分代码这一轮一个字也没执行过。
* **不改动设备**：这一轮对设备做的唯一一件事是 `zl1-health-check.sh --quiet` 的只读巡检（连 ping 都没发出去，因为它在 EDL 分支就退出了）。
