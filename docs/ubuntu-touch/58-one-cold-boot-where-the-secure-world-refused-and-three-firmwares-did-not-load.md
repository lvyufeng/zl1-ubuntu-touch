# 58 — 一次冷启动里 secure world 拒绝了，于是三个固件都没加载：没有 GPU、没有音频、没有传感器

**日期**: 2026-09-21
**状态**: **一次坏的冷启动被完整地记下来了**（`/userdata/zl1-kmsg/keep/boot-badgpu-350s.log`），它一次解释了三个一直分开记着的"未解决"项。那次启动里 `scm_call`（到 TrustZone 的安全通道调用）返回 **`-12`（ENOMEM）**，于是 PIL 加载固件的那条路全断：**`a530_zap`（GPU）、`adsp`（音频 DSP）、`slpi`（传感器低功耗岛）三个都报 `Invalid firmware metadata`**。后果是 `kgsl_open` 失败 → EGL 拿不到 config → 合成器起不来 → 界面不在；ADSP 没有 → `pulseaudio` 起不来；SLPI 没有 → `sensorfwd` 卡住。**下一次冷启动就全好了** —— 所以这是**按启动次发生的竞态**，不是持久故障。**为什么 secure world 会拒绝，还没有答案**，只知道它拒绝的是哪几个调用、以及拒绝之后设备会变成什么样。
**接续**: [`44`](44-the-v63-image-sabotages-its-own-container.md)、[`46`](46-the-gui-runs-dev-ion-was-root-only.md)、[`57`](57-boot-verification-the-two-services-come-up-by-themselves.md)

---

## 1. 现象：界面不在，而且怎么重启 lightdm 都没用

有一次冷启动之后合成器一直起不来。`/var/log/lightdm/unity-system-compositor.log`：

```
<information> mirserver: Selected driver: ubports:android2 (version 1.8.0)
ERROR: ./src/server/graphics/default_configuration.cpp(182): Throw in function operator()
std::exception::what: Exception while creating graphics platform
ERROR: ./src/platforms/android/server/gl_context.cpp(127): Throw in function select_egl_config_with_any_format
std::exception::what: could not select EGL config
```

`46` 见过的那个报错。但 `46` 的原因是 `/dev/kgsl-3d0` / `/dev/ion` 权限是 `crw------- root:root`，而**这次它们是 `crw-rw-rw-`**，`free-gpu-devices.sh --status` 确认会话用户拿到的还是：

```
EGL Error 3001 at test_egl_configs.c:106        <- EGL_NOT_INITIALIZED
```

也就是说权限没问题，**`eglInitialize` 本身就是失败的**。`lightdm` 重启计数爬到 22 以上，`user@32011` 整个开机没起来。

先排除了一个嫌疑：把 `56` 搬进容器 namespace 的那两个服务**停掉**再重启 lightdm，界面照样起不来。所以和这次改动无关，是独立的一条线。

## 2. 答案在开机日志里 —— 而日志是 `52` 那个快照抓取器留下的

`dmesg` 环里那一段（`boot-110s.log`，从 `[49.6]` 开始）：

```
[   49.650140] scm_call failed: func id 0x42000c16, ret: -12, syscall returns: 0x0, 0x0, 0x0
[   49.650174] hyp_assign_table: Failed to assign memory protection, ret = -12
[   49.650203] WARNING: CPU: 1 PID: 41005 at drivers/iommu/arm-smmu.c:2320 arm_smmu_assign_table+0xb0/0x130()
[   49.650220] CPU: 1 PID: 41005 Comm: android.hardwar
              Call trace:
                arm_smmu_assign_table+0xb0/0x130
                arm_smmu_attach_dev+0x614/0xbcc
                iommu_attach_device+0x24/0xd4
                _attach_pt.isra.31+0x54/0x90
                kgsl_iommu_init_pt+0x1d0/0x3c4
                kgsl_mmu_createpagetableobject+0x88/0x164
                kgsl_iommu_getpagetable+0x48/0x54
                kgsl_iommu_start+0x134/0x1f0
                kgsl_mmu_start+0x28/0x38
                adreno_start+0x128/0x47c
                kgsl_open+0x130/0x3b0        <- 一路到 open("/dev/kgsl-3d0")
                chrdev_open / vfs_open / do_last / path_openat / do_sys_open / SyS_openat
```

**有人 `open("/dev/kgsl-3d0")`，内核在 `adreno_start` 里给 GPU 建 IOMMU 页表，走到 `arm_smmu_assign_table` 需要 secure world 把那段内存标记为受保护 —— 而 `scm_call` 返回了 `-12`。** 于是 `kgsl_open` 失败，EGL 无从而来。（触发者是容器里的 `android.hardwar`，PID 41005 —— 容器自己的图形栈在开机时开 GPU。）

紧接着，同一类失败把另外两个固件也带走了：

```
[   49.677265] ueventd: firmware: loading 'a530_zap.mdt' for '.../kgsl-hyp/firmware/a530_zap.mdt'
[   51.946823] subsys-pil-tz soc:qcom,kgsl-hyp: a530_zap: Invalid firmware metadata
[   50.050069] scm_call failed: func id 0x42000201, ret: -12, syscall returns: 0x0, 0x0, 0x0
[   50.050916] subsys-pil-tz 9300000.qcom,lpass: adsp: Invalid firmware metadata
[   50.056749] subsys-pil-tz 1c00000.qcom,ssc: slpi: Invalid firmware metadata
[   50.056792] scm: secure world has been busy for 1 second!
[   50.136170] sensors-ssc soc:qcom,msm-ssc-sensors: slpi_load_fw: pil get failed,
[   50.136196] sensors-ssc: slpi_load_fw: SLPI image loading failed
```

`Invalid firmware metadata` 是 PIL 在 secure world 里认证镜像失败时的说法 —— **它的意思不是"固件文件坏了"，而是"这一步走不过去"**。`scm: secure world has been busy for 1 second!` 是内核自己在说它等 secure world 等了一秒。

那一整次启动里失败计数（`boot-*.log` 里的快照）：

| func id | 次数 | 用途（从调用点看） |
| --- | --- | --- |
| `0x42000201` | 21 | PIL 那一路（adsp / slpi / kgsl-hyp 认证） |
| `0x42000904` | 27 | 未定 |
| `0x42000c16` | 4 | `hyp_assign_table` —— 就是上面那条 GPU 栈 |
| `0x42001306` | 25 | 未定 |

## 3. 它一次解释了三个分开记着的"未解决"

| 一直单独记着的现象 | 这次看到的直接原因 |
| --- | --- |
| `26`/`46` 的显示：`could not select EGL config` / `EGL_NOT_INITIALIZED` | `kgsl_open` 失败：`a530_zap` 没加载 + `hyp_assign_table` 被拒 |
| `48` 的音频：`pulseaudio` inactive、"ALSA 卡在" | `adsp: Invalid firmware metadata` |
| `48` 的 `sensorfwd` 卡在 `activating` | `slpi: Invalid firmware metadata` → `slpi_load_fw: SLPI image loading failed` |

而 `57` 那次好的启动里同样四行 PIL 日志长这样，**一条 `Invalid firmware metadata` 都没有**：

```
subsys-pil-tz 9300000.qcom,lpass: adsp: loading from ...
subsys-pil-tz 1c00000.qcom,ssc: slpi: loading from ...
subsys-pil-tz ce0000.qcom,venus: venus: loading from ...
subsys-pil-tz soc:qcom,kgsl-hyp: a530_zap: loading from ...
```

也没有 `arm_smmu_assign_table` 那条 WARNING。（好启动里也有 `scm_call failed`，但是**另外两个 func id** —— `0x42000c02` 2 次、`0x72000206` 40 次 —— 和这几个不是一回事。）**所以这是按启动次发生的竞态**：同一份镜像、同一台设备，一次启动全都起不来，下一次全好。

## 4. 归因边界

**没有查清的是**：secure world 为什么拒绝。这篇能说的是 **内核在哪些调用点上拿到了 `-12`、以及拿不到之后哪三个子系统会一起消失** —— 这些是从日志直接读出来的，不是推测。往下走要查的是 secure world 那一侧：

- `-12` 是 `ENOMEM`，而 `hyp_assign_table` 失败在 msm8996 上通常指向 **TZ 侧的内存/连接数被占满**。`scm: secure world has been busy for 1 second!` 指向同一个方向。
- 谁在开机的同时也在用它：容器里 `qseecomd` / `android.hardware.keymaster` / DRM（widevine 那两个）/ `fdpp` 都在这个时间窗口里起来。`44` 记过 v63 镜像会往容器里 bind 打补丁 `qseecomd`，desabotage 会把它摘掉 —— 值得核对**坏的那次启动里 desabotage 是不是还没生效**（`zl1-container-fix` 的日志在坏启动里没留）。
- 值得做的是对照：把坏启动的 `boot-*.log` 和好启动的并排看，找**在 49 秒之前**两边不同的那几行，而不是继续看失败之后。

**不预测。** 也不建议为此改任何东西 —— 目前的证据只够说明"这是一次竞态，重启可解"，而设备每次都能回来。

## 5. 这一段改了哪些东西

**没有改任何设备状态。** 坏启动的日志被保存到 `/userdata/zl1-kmsg/keep/boot-badgpu-350s.log` 和 `keep/kmsg-badgpu.log`（`install-kmsg-drain.sh` 每次开机都会清掉 `boot-*.log`，所以不另存就没了）。这一篇是读日志的结果。
