# 141 — 最大的那个缺口：视频编解码，以及"没人问过它"和"它坏了"的区别

**日期**: 2026-09-24
**状态**: 本轮**没有碰设备**（设备仍在 Qualcomm EDL，见 §7）。这是 [`137`](137-a-boot-should-answer-the-question-nobody-asked.md)
那份"没有探针"清单的第五次收口，收的是**剩下最大的一个**：`video-codec`，**十二个设备树节点**（清单上仅次于显示那一族）。
新工具 `scripts/device/zl1-video-probe.sh`（只读、**一个字节都不写**）与它的 harness **155 项**；
它接进了"一次启动"的默认集（新步骤 **04g**，与 04b–04f 同一类：只读、不写、不需要人在场）。
清单从 **8 个缺口**变成 **7 个**；家族 **25 个 harness / 2951 检查 / 全绿**（本页之前是 2789 / 24）。

**接续**: [`137`](137-a-boot-should-answer-the-question-nobody-asked.md)（缺口的来源）、
[`140`](140-the-block-that-was-another-phones.md)（前一次收口——那一行点名的仪器属于另一台手机）、
[`58`](58-one-cold-boot-where-the-secure-world-refused-and-three-firmwares-did-not-load.md)（安全世界拒绝 `scm_call` 的那次冷启动：本页的固件那一半正好走同一条路）、
[`124`](124-the-boot-a-finger-bought-is-one-command.md)（一次启动是一个命令）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 为什么先收这个？ | 它是剩下最大的一个：**十二个设备树节点**（`--block video-codec` 就是这句话），而这十二个节点背后是一个**块**——视频编解码核心。清单上比它大的只有显示那一族，而显示已经有仪器了（而且已经由用户的手和眼确认过） |
| 这个块为什么难读？ | 因为它**不是一个东西，是两层**：`/soc/qcom,vidc@c00000`（`qcom,msm-vidc`，驱动那一半，`msm_v4l2_vidc.c`）和 `/soc/qcom,venus@ce0000`（`qcom,pil-tz-generic`，固件那一半）。两层会**各自失败**，也会各自成功 |
| 固件那一半特别在哪？ | Venus 的固件**没有编进内核**：它是运行时由**外设加载器**从文件里分段读进来的（`venus.mdt` + `venus.b00`…），而且**每一段都要安全世界先认证**——`subsys-pil-tz.c` 里就是 `scm_call(PAS_INIT_IMAGE_CMD)` 和 `PAS_AUTH_AND_RESET_CMD`。这正是 docs 58 抓到返回 **-12** 的那条路（那一次 `a530_zap`/`adsp`/`slpi` 全都没加载，于是 GPU 没有、音频没有、传感器没有） |
| 驱动那一半在哪？ | `/soc/qcom,vidc@c00000`，`msm_v4l2_vidc.c` 注册一个解码器和一个编码器，设备号从 `BASE_DEVICE_NUMBER` **32** 起——所以是 **/dev/video32**（解码）和 **/dev/video33**（编码，`nr + 1`） |
| **最要紧的那条读数** | **开机时没有人加载这个固件。** `venus_hfi.c` 的 `__load_fw()` 是在**有客户端打开一个视频实例**时才跑的（`subsystem_get_with_fwname("venus", ...)`），所以**空闲启动时子系统读到 `OFFLINE` 是健康状态**。把"没加载"当成故障的探针，在大多数启动上都会报错 |
| 那怎么区分"没人问"和"问过、失败了"？ | 要**证据**：`crash_count` 是个**数字且非 0**，或者 `error` 缓冲区**有文字**。两者都没有、而加载需要的东西全在——那才叫 `firmware-not-loaded`（没人问）。这是本页最重要的一条，也是 harness 里第一个"读数变异"要保的东西 |
| 为什么要把**所有**子系统都印出来？ | 因为**同一个驱动服务四个节点**：`kgsl-hyp`（GPU 的 zap shader）、`lpass`（音频 DSP）、`ssc`（传感器 DSP）和 `venus`，共享同一条搜索路径和同一个 SCM 服务。所以"只有 venus 是 OFFLINE"和"整次启动的固件全没起来"是**两个不同的问题**，一行读数分不出来——四个兄弟互为对照组，这就是那个对照组 |
| 固件文件在哪？ | `/vendor/firmware_mnt/image`——刷进去的 cmdline 带着 `firmware_class.path=/vendor/firmware_mnt/image`，而 `firmware_class.c` 的搜索表是 `fw_path[]`：那个参数、`/lib/firmware/updates/<版本>`、`/lib/firmware/updates`、`/lib/firmware/<版本>`、`/lib/firmware`、`/lib64/firmware`、`/lib/firmware/image`。**每条路径都在调用者的 mount namespace 里解析**，所以探针在**两个 namespace**里各查一遍 |
| 探针怎么报？ | 先报板子，再爬阶梯：`tree-unscanned` / `wrong-board-tree` / `unknown-board` / `no-device-tree-node` / `node-disabled` / `no-firmware-node`（**因**，排在加载器自己那几级之前，那几级是**果**）/ `pil-not-bound` / `no-subsys-entry` / `firmware-unreachable` / `firmware-incomplete`（`.mdt` 在、分段不在）/ `no-video-device` / `load-failed` / `firmware-not-loaded` / `online` |
| 它写东西吗？ | **一个字节都不写。** 而这条在这里同样要紧：vidc 平台设备的 `pwr_collapse_delay` 和 `thermal_level` 是 **0644**，子系统的 `restart_level`/`firmware_name`/`system_debug` 也是 0644，而**打开任何一个视频节点就是加载固件的那件事**。所以"跑一次看看能不能解码"是一个**单独的、要单独评审**的步骤，不是取一次读数的副作用 |
| 离线验证？ | `scripts/host/zl1-video-probe-selftest.sh`，**155 项**：stub 目录**就是**设备，一级一个场景，**四条根路径**（`/proc/`、`/sys/`、`/dev/video`、`/lib/firmware`）的改写（最后一条不覆盖的话，"固件不可达"那一级会找到**本机**的 `/lib/firmware`），"树形"夹具保持三种形状彼此不同，八个变异各让它红 |
| 动设备了吗？ | **没有。** |

---

## 2. 为什么是这个块，以及为什么它不能用一个开关读

`137` 的清单把"缺什么"变成了一句话，而剩下的七个里，`video-codec` 是**节点最多**的一个：

```sh
$ bash scripts/host/zl1-hardware-inventory.sh --block video-codec     # 收口之后
video-codec      12    zl1-video-probe.sh                     F R S
$ bash scripts/host/zl1-hardware-inventory.sh --gaps
blocks: 29 hardware -- 22 with a named instrument, **7 with none**, 0 STALE; plus 6 infrastructure rows, ...
```

十二个节点，在三个集合里都在（`F R S`）。但"十二个节点"不是"一个设备"——它是**一个节点加十一个子节点**
（`arm9_bus_ddr`、`bus_cnoc`、`venus_bus_ddr`、`venus_bus_vmem`、`firmware_cb`、`non_secure_cb`、
`secure_bitstream_cb`、`secure_non_pixel_cb`、`secure_pixel_cb` 这些是 SMMU/总线的上下文，`venus@ce0000`
和 `arm,smmu-venus@d40000` 是另外两个），所以**读它的正确方式不是数节点，而是问"它要动起来需要什么"**。

而它需要的东西是**两层**，而且两层**会各自失败**：

```
第一层：固件         /soc/qcom,venus@ce0000    qcom,pil-tz-generic   pas-id 9   firmware-name venus
                    固件不在内核里：加载器分段读 venus.mdt + venus.b00..，
                    每一段要安全世界认证（scm_call PAS_INIT_IMAGE_CMD / PAS_AUTH_AND_RESET_CMD）
第二层：驱动         /soc/qcom,vidc@c00000     qcom,msm-vidc         hfi venus 3xx
                    msm_v4l2_vidc.c 注册 /dev/video32（解码）和 /dev/video33（编码）
```

这正是**为什么一个"开关式"的探针在这里一定是错的**：固件起来了而 V4L2 那半没注册，和驱动注册了而固件没加载，
是两种不同的故障，下一手也完全不同。

---

## 3. 设备树里到底有什么（读数，不是猜测）

`--block video-codec` 只能告诉你有十二个节点。属性是从 DTB 里一个一个读出来的（`/tmp/dtp/dump4.py`，
那个 scratch 工具**逐字复现**了提交的 walker，并在 38 棵树上给出与快照完全一致的 725 对 / 699 路径——所以这份读数不是建立在第二个"写法不同、bug 也不同"的解析器上）：

```
/soc/qcom,vidc@c00000
    compatible = qcom,msm-vidc          status = ok
    qcom,hfi = venus                    qcom,hfi-version = 3xx
    qcom,firmware-name = venus          qcom,imem-size = 524288（0x00080000）
    qcom,max-secure-instances = 5       qcom,max-hw-load = 2563200（0x00271fc0）
    qcom,never-unload-fw（空）           qcom,sw-power-collapse（空）
    mmagic-venus-supply / venus-supply / venus-core0-supply / venus-core1-supply
    clock-names = smmu_ahb_clk smmu_axi_clk mmagic_video_axi core_clk iface_clk bus_clk maxi_clk core0_clk core1_clk

/soc/qcom,venus@ce0000
    compatible = qcom,pil-tz-generic    （没有 status 属性 —— 缺席在设备树里就是 enabled）
    qcom,pas-id = 9                     qcom,proxy-timeout-ms = 100
    qcom,firmware-name = venus          qcom,proxy-reg-names = vdd
    qcom,proxy-clock-names = core_clk iface_clk bus_clk maxi_clk
    qcom,msm-bus,name = pil-venus       memory-region（指向 IMEM 的保留区）
```

三件事值得单独说：

* **`status` 只在驱动那一半有，固件那一半没有。** 这不是遗漏：设备树里**没有 `status` 就是 enabled**。
  所以探针把"缺席"单独印出来（`status: absent (an absent status means enabled; this node carries none)`），
  而不是把它当成空字符串——这一条和 `wrong-board-tree` 是同一类：**"没写"和"写坏了"必须印成两句不同的话**。
* **四个兄弟是真兄弟，modem 不是。** `kgsl-hyp`/`lpass`/`ssc`/`venus` 都是 `qcom,pil-tz-generic`，
  而 `mss@2080000` 是 `qcom,pil-q6v55-mss`——**另一个驱动**。所以探针按 compatible 找兄弟，
  modem 不会混进来（harness 专门有一条断言：夹具如果把 modem 写成 `pil-tz-generic`，那就是**夹具在撒谎**）。
* **分段的数量不是设备树说的，是 `.mdt` 自己说的。** `peripheral-loader.c` 的 `pil_boot()` 先读 `venus.mdt`
  （`snprintf(fw_name, ..., "%s.mdt")`），**从那个文件自己的 program header 表**（`mdt->hdr.e_phnum`）建出段列表，
  再逐段 `pil_load_seg()`；那段失败时打的是 `"Failed to locate blob %s or blob is too big."`。
  所以"`.mdt` 在、分段不在"是一个**单独的、真实的故障**（不是"空闲"，也不是"路径不对"），探针给它单独一级。

> 顺手记下这一轮读到的一处自己的错：探针最初的 verdict 文本写的是 `peripheral-loader.c's pil_get_files loops
> the segments`——**这个函数不存在**。在源码里逐行找过之后是 `pil_boot()`、`pil_load_seg()` 和
> `mdt->hdr.e_phnum`。这类"引用了一个听起来对的函数名"的错，是**只有去读源码才会掉进去的坑**，
> 而它和数值错误一样：形状对、内容错。

---

## 4. 探针：先认板子，再爬阶梯

`scripts/device/zl1-video-probe.sh`，`/bin/sh`，**只读、不写任何东西**（连临时文件都不写，所以内核日志是收进 shell 变量里的）。

```
tree-unscanned        没有 find(1) 且没有已知节点形状   -> "没法看"不是"不在"
wrong-board-tree      /proc/device-tree/model 是 X2 的  -> 这一轮的所有读数都不是这块板的
unknown-board         model 两个都不认 / 读不出来
no-device-tree-node   树里没有 qcom,msm-vidc 节点        -> 驱动没有可绑的东西
node-disabled         status != ok                      -> 内核不会 probe 它：没有驱动、没有 /dev/video
no-firmware-node      没有一个 pil-tz 节点叫这个名字     -> 这是"因"：加载器那几级是"果"，所以排在它们前面
pil-not-bound         subsys-pil-tz 目录不在/空          -> 谁都不加载，下一手是内核日志
no-subsys-entry       绑定成功但没有子系统条目           -> 名字来自 qcom,firmware-name，树/加载器不一致就在这里显形
firmware-unreachable  每一条候选路径都没有 .mdt          -> 这是 mount/路径问题，不是硬件问题
firmware-incomplete   .mdt 在、分段不在                  -> 永远加载不了的固件
no-video-device       固件起来了、两个节点没都注册       -> 报"found N of 2"，1 个也不算过
load-failed           有证据（crash_count 非 0 / error 有字）-> 有人试过，没成
firmware-not-loaded   该有的都在、OFFLINE、无错无崩        -> 没人问过（！）
online                子系统 ONLINE 且两个节点都注册
```

读数按源码取：节点印 `status`/`hfi`/`hfi-version`/`firmware-name`/`imem-size`/`max-secure-instances`/
`never-unload-fw`/`sw-power-collapse`/`max-hw-load`，固件节点印 `pas-id`/`proxy-timeout-ms`/proxy 时钟与稳压器；
驱动那一半印 `msm_vidc_v4l2` 里**挂上去的设备**和那四个属性（`platform_version`/`capability_version` 只读，
`pwr_collapse_delay`/`thermal_level` 0644——属性名是从 `msm_v4l2_vidc.c` 的 `msm_vidc_core_attrs[]` 里抄的）；
子系统那一级印**整张表**（每个子系统一行：state / crash_count / firmware_name / restart_level）；
固件那一级印**参数和 cmdline 两个读数**（它们可以不一致），以及两个 namespace 里的每一条候选路径。
长度不是 4 的设备树属性报 `not-a-u32(N bytes)`，不崩、也不猜。

---

## 5. 最要紧的一条：**没人问过**不是故障

这一页真正值得记下来的，是探针里那句 **NO CLIENT HAS ASKED YET**。

```
venus_hfi.c:  __load_fw()  ->  subsystem_get_with_fwname("venus", ...)
                              ^ 由"打开一个视频实例"触发，不是开机
```

所以一次**空闲而健康**的启动长这样：子系统 `OFFLINE`、`crash_count` 0、`error` 空、`.mdt` 和分段都在。
把它报成"固件没起来"就是在**每一次没有人在看视频的启动上误报**。

而"有人试过、没成"长这样：`crash_count` 是个非 0 的数字，或者 `error` 缓冲区里有字
（`pil_load_seg()` 失败时会 `subsys_set_error(desc->subsys_dev, firmware_error_msg)`）。
于是判据是**证据**，不是状态本身：

```sh
LOAD_EVIDENCE=no
case "$SUB_CRASH" in 0 | EMPTY | UNREADABLE | '') ;; *) LOAD_EVIDENCE=yes ;; esac
case "$SUB_ERR"   in EMPTY | UNREADABLE | '') ;; *) LOAD_EVIDENCE=yes ;; esac
```

harness 里第八个变异就是**把这一条拆掉**（`LOAD_EVIDENCE=no` → `yes`）：它让一次"没人问过"的启动
变成 `load-failed`——**在一个什么都没失败的启动上报故障**。这是本页的探针最容易被写错的地方，
所以它是被单独断言的那一个。

---

## 6. 为什么要把四个兄弟一起印出来

`subsys-pil-tz` 在这块板上有**四个**设备，而探测器的**目录存在**只说明"驱动注册了"：

```
/sys/bus/platform/drivers/subsys-pil-tz/
  bind  unbind  uevent
  c00000.qcom,vidc      <- 绑定列表（这些才是被 probe 过的）
  ce0000.qcom,venus
  9300000.qcom,lpass
  1c00000.qcom,ssc
```

它们共享**一条搜索路径**（`firmware_class.path`）和**一个 SCM 服务**，所以：

| 读数 | 含义 |
|---|---|
| `adsp ONLINE`、`venus OFFLINE` | 正常：音频开机就要用，视频没人看 |
| **四个全 OFFLINE 且都有错** | 不是 venus 的问题——是**整次启动的固件**都没起来（docs 58 那种形状） |
| `venus OFFLINE` 且 `crash_count>0` | 有人试过、失败了，而且是 venus 自己的 |

探针把整张表印出来，就是因为**一行读数回答不了上面这三行里的前两行**。
harness 里第七个变异把兄弟列表静音——venus 自己那行还在，但"它是个别问题还是全局问题"这个读数就没了。

---

## 7. 设备状态与复现

整轮没有动设备：没有写任何分区或 boot，没有跑 QDL/QFIL，没有重启。设备仍在 **Qualcomm EDL**（`05c6:9008`）。
识别目标一律按序列号 **`33e80afe`**；总线上另一台小米 **`4a2fe00b`** 必须忽略。恢复仍然只能靠**物理长按电源 10–20 秒**。

```sh
# 全部在宿主机上，不碰设备。
bash scripts/host/zl1-hardware-inventory.sh --block video-codec   # 12 个节点，现在有仪器了
bash scripts/host/zl1-hardware-inventory.sh --gaps                # 现在只剩 7 个缺口
bash scripts/host/zl1-video-probe-selftest.sh                     # 155 项

# 那个最重要的变异（把"没人问过"折成"失败"，必须红）：
P=scripts/device/zl1-video-probe.sh
python3 - "$P" <<'PY'
import sys
s = open(sys.argv[1]).read()
open('/tmp/mut-idle.sh','w').write(s.replace("LOAD_EVIDENCE=no", "LOAD_EVIDENCE=yes", 1))
PY
ZL1_VIDEO_PROBE_SRC=/tmp/mut-idle.sh bash scripts/host/zl1-video-probe-selftest.sh

# 设备回来之后（只读、不写任何东西；或直接跑 capture，它已经把 04g 放进默认集）：
scp scripts/device/zl1-video-probe.sh root@10.15.19.82:/tmp/ && ssh root@10.15.19.82 'sh /tmp/zl1-video-probe.sh'
# 它会先回答"这棵树是不是这块板"，再回答固件这一半在哪一级、以及整次启动的固件是不是都起来了。
```

---

## 8. 这一轮**不**证明什么

* **不证明视频能解码。** 反过来也不证明不能。那需要一次**会话**：打开 `/dev/video32`、协商格式、喂一段码流——
  而**打开会话本身就是加载固件的那件事**，所以"用一次会话把 `firmware-not-loaded` 修掉"的探针，
  等于**在取读数的同时把读数擦掉**。让它起来是一个单独的、要单独评审的步骤。
* **不证明设备上落在哪一级。** 这一轮**一次 ssh 都没有**：155 项全部挡在 stub 目录后面，场景是我造的。
  设备上真实的那一级（尤其是 `status`、驱动有没有绑上、`/vendor/firmware_mnt` 有没有被挂上）只有设备回来才知道。
* **不证明 `firmware-not-loaded` 是设备上的实际状态。** 它是"该有的都在"时的读法；如果设备上读到的是它，
  那也只是"没人问过"，而不是"这条路能通"。
* **不证明 `sdhc2`（可插拔 SD 卡槽）那件事。** `137` 清单上还在的 `sdcard` 缺口（两个 `qcom,sdhci-msm` 控制器）
  这一轮**没有收**。它的**离线读数已经做完**（`sdhci@7464900` 是 `status=ok` + `qcom,nonremovable` + HS400 + inline crypto，
`sdhci@74A4900` 是可插拔那个、带 `cd-gpios`、但 `status = "disabled"`——**这一条是 boot image 里的设备树改动**，
属于"需要单独决定"的那一类），但探针还是下一个阶段的事。
* **不证明那四个兄弟在设备上真的会一起起来。** 对照组的意义在于**当它们不一致时能看出来**，
  而不是预测它们的值。
* **不证明剩下的 7 个缺口里没有更重要的。** 只是这个块最大，而"最大"是可以量的。

---

## 9. 文件与改动

| 文件 | 作用 |
|---|---|
| `scripts/device/zl1-video-probe.sh` | 新：视频核心探针（V4L2 一半 + PIL 固件一半），**board-first**，十四级阶梯，只读**且不写任何东西** |
| `scripts/host/zl1-video-probe-selftest.sh` | 新：**155 项**，stub 目录就是设备，四条根路径改写（含 `/lib/firmware`），`bare-tree` 夹具，八个变异 |
| `scripts/host/zl1-hardware-inventory.sh` | 改：`video-codec` 行点名仪器（清单汇总 21/8 → **22/7**） |
| `scripts/host/zl1-hardware-inventory-selftest.sh` | 改：汇总数字改成 22/7；`video-codec` 从缺口循环移到"已覆盖、按名字断言"那一组 |
| `scripts/host/zl1-post-recovery-capture.sh` | 改：默认集新增 **04g-video**（只读、不写、不需要人在场） |
| `scripts/host/zl1-post-recovery-capture-selftest.sh` | 改：152 → **155** 项（加一步必须按名字/顺序/scp 路径/归档文件/步骤数全部改一遍） |
| `scripts/host/zl1-health-check.sh` | 改：新增一段（在 vibrator 之后）把"两层 + 没人问过"和 155 项接上；设备清单新增 **5b. video codec**；0g 改写为 **7 of 29**；cli-usage 引用 152 → **156**（它扫的脚本 53 → 55）；capture harness 引用 152 → **155** |
| `scripts/README.md` | 改：两个新脚本各一行；cli-usage 引用 152 → **156**（覆盖 70 个脚本）；capture 两行 152 → **155**、步骤 10/8/11 → 11/9/12；capture 那一行补上 04g |
| `docs/ubuntu-touch/137-*.md` | 改：后续注记 8 → 7，并指向本页 |
| `docs/ubuntu-touch/124-*.md` | 改：家族总数那一行续上本轮 |
| `README.md` | 改：本页的索引行 |
| `docs/ubuntu-touch/141-*.md` | 本篇 |
