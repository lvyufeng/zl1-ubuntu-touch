# 67 — 预览起来了：`startPreview` 堵在 `scheduling_policy` 这个 SCHED_FIFO 请求上；顺带量出输入层在等 SurfaceFlinger

**日期**: 2026-09-22
**状态**: **`Started camera preview.` 真的打出来了**，而且是可以重复的：`connect()` 走完 → cameraserver 打开 camera 1 → 客户端的 `startPreview`（`ICamera::START_PREVIEW`，binder code 5）**返回** → `test_camera` 进入它的 GL 循环。挡住它的那件事与相机无关：`Camera3Device::configureStreamsLocked` 在把流交给 HAL 之后，会为请求线程要一次 SCHED_FIFO 提升，走 `android::requestPriority → checkService("scheduling_policy")`，而这个名字在 Halium 容器里没有 system_server 去注册，那条循环是 `sleep(1)` 且**没有超时、没有日志、没有出口**。`service-stub` 现在也回答这个名字（第五个），设备上 `Set real time priority for request queue thread` 和 `Started camera preview.` 都出现了。
**还没到出图**：预览流（cameraserver 的 stream 0）的 native window 一上来就是死的 —— `getBufferLockedCommon: Stream 0: Can't dequeue next output buffer: Broken pipe (-32)`、`disconnectLocked: ... the native window died from under us`，HAL 随后 `notifyErrorForPendingRequests`。这是下一堵墙，§7。

> **本节这两条结论都在 [`68`](68-the-camera-stage-was-one-cookie-in-the-stub.md) 被量翻了，读的时候要连着那份一起看。** (1) 那串 `-32` **不是**"native window 一上来就是死的"，是**客户端已经死了之后**的尸检报告 —— 这次故意 `kill -9` 客户端，逐行复现了同一串日志（顺序都一样），而在客户端活着的时候一条都没有。(2) 真正挡住出图的是 stub 自己：`IAppOpsService.getToken` 的回复里 `flat_binder_object` 的 cookie 和注册时不一致，内核按不变量把**整条回复**判成 `-EINVAL`。修掉之后：60 秒 2173 帧、零 camera3 错误、dmesg 无 binder 消息。
**接续**: [`66`](66-the-input-layer-vendor-symbol-was-libinputservice.md)、[`65`](65-the-camera-was-blocked-on-four-system-server-services.md)

---

## 1. 现象：连接通了，`startPreview` 不回

`65`/`66` 那四堵墙拆完之后现场是"什么都没发生"：`test_camera` 停在

```
err| Created egl window
out| ... Current preview fps range: 30
== reached the preview?
  no
```

同一时刻两个进程各有一个循环，都不是相机自己在转：

```
（app）main 线程      wchan=binder_thread_read     <- 在等 code 5 的回复
（app）input 线程     hrtimer_nanosleep            <- 每 100 ms 醒一次
（cameraserver）Binder:_N  nanosleep({tv_sec=1})   <- 每秒醒一次，永远
```

`/sys/kernel/debug/binder/proc/<app>` 里那条 outgoing 事务写得很清楚：`to <cameraserver> code 5 flags 10 pri 0:120 r1` —— code 5 是 `ICamera::START_PREVIEW`（`frameworks/av/camera/ICamera.cpp` 的枚举：1 DISCONNECT、2 SET_PREVIEW_TARGET、3 SET_PREVIEW_CALLBACK_FLAG、4 SET_PREVIEW_CALLBACK_TARGET、**5 START_PREVIEW**）。也就是说 cameraserver 收到了、但没回。

## 2. 两个循环分开量：app 那个是**输入层**在等 SurfaceFlinger

先说 app 那个（它和相机无关，但是这次量出来的新结论）。20 秒的 `strace -f` 里那个线程只睡两种时长：

```
187 × nanosleep({tv_sec=0, tv_nsec=100000000})     <- 100 ms
  4 × nanosleep({tv_sec=0, tv_nsec=250000000})     <- 250 ms
```

这两个数字正好对上 `IServiceManager::getService()` 的一条实现细节：重试间隔是 `gSystemBootCompleted ? 1000 : 100` 毫秒（`frameworks/native/libs/binder/IServiceManager.cpp:154`），而**调用者**（`ComposerService::connectLocked()`）在两次 `getService` 之间 `usleep(250000)`。于是每个周期 = 47 次 × 100 ms + 一次 250 ms ≈ 5.0 s，日志里正好是每 5.3 s 一条

```
W/ServiceManager(29978): Service SurfaceFlinger didn't start. Returning NULL
```

（`I/ServiceManager: Waiting for service SurfaceFlinger...` 其实每秒都在打，只是被 logd 的 chatty 抑制掉了 —— 我们数到 189 条 `Waiting` 对 37 条 `didn't start`，正好是每周期 5 条，就是 chatty 放过的那些。）

线程名把最后一步补上：那个 tid 的 `comm` 是 **`input`**，而这个名字在 `halium/libhybris/compat/input/input_compatibility_layer.cpp:430,441` 只出现一次 —— `global_state->input_reader_thread->run("input")`。链路是

```
android_input_stack_initialize()
  -> DefaultInputReaderPolicyInterface::obtainPointerController()   对每个鼠标设备无条件构造
     -> android::SpriteController / android::PointerController
        -> DisplayEventReceiver::DisplayEventReceiver -> ComposerService::getComposerService()
        -> SpriteController::ensureSurfaceComposerClient -> new SurfaceComposerClient()
           -> ComposerService::connectLocked()   while (getService("SurfaceFlinger") != OK) usleep(250000)
```

这台设备上**没有 SurfaceFlinger**（GUI 是主机侧的 `lomiri-system-compositor`），所以这个循环按构造就是死的。它不挡相机（相机在别的线程/进程），但它意味着**任何走 hybris 输入栈的进程，输入线程永远停在构造函数里**：收不到任何输入事件，还每秒被唤醒一次。`test_camera` 的"点屏拍照"就是这条路，所以这条路在相机里本来也不通。修它得让 `obtainPointerController()` 容忍"没有 SurfaceFlinger"（`InputReader` 有几处 `mPointerController->` 是不判空的：`InputReader.cpp:2854`、`5265-5300`），那是输入层自己的活，记在 §7。

## 3. cameraserver 那个循环：用 binder tracepoint 量出来它每 1.0002 秒问一次 servicemanager

cameraserver 那个线程**一行日志都没有**，所以不能靠日志找它。可用的量法有两个，都用上了：

```
/sys/kernel/debug/tracing/events/binder/binder_transaction        （事务本身：谁发给谁、reply、flags、code）
/sys/kernel/debug/tracing/events/binder/binder_transaction_alloc_buf （载荷大小：data_size/offsets_size）
```

只过滤 `common_pid == <cameraserver> || to_proc == <cameraserver>`，20 秒里它只发一种事务，1.0002 秒一次、连着发：

```
binder_transaction: dest_node=43 dest_proc=41134 reply=0 flags=0x10 code=0x2
   41134 = servicemanager；flags 0x10 = TF_ACCEPT_FDS（同步、等回复）；code 2 = CHECK_SERVICE_TRANSACTION
binder_transaction_alloc_buf: data_size=104 offsets_size=0
   回复是 4 字节 → "没有这个服务"（找到了会是一个 flat_binder_object）
```

## 4. 名字不用猜：104 这个字节数已经把范围缩到 16/17 个字符，再用 `/proc/<pid>/mem` 读出来

`checkService` 的载荷 = `writeInterfaceToken()` + `writeString16(name)`，字节数是可以算的：

```
4    strict-mode policy 字（writeInterfaceToken 先写它）
60   接口名 "android.os.IServiceManager"：4 + 27*2 + 2 = 60（27 字符 + NUL，正好 4 字节对齐）
4    名字的长度字段
pad4(2L+2)   名字本身（L 字符 + NUL，补到 4）
```

`data_size = 104` ⇒ `pad4(2L+2) = 36` ⇒ **L ∈ {16, 17}**。同一条算式在 app 那边是自证的：它的 SurfaceFlinger 轮询 `data_size = 100` ⇒ L ∈ {14, 15}，而日志里明写着 `SurfaceFlinger`（14）✓。

名字本身从运行中的进程内存里读：接口名是以 **UTF-16** 写进 parcel 的，所以按 UTF-16 字节找 `android.os.IServiceManager` 只会命中 parcel 缓冲区（`.rodata` 里那份是 ASCII，不会误伤）。cameraserver 是 32 位进程，parcel 就躺在它线程栈上（`nanosleep` 的参数地址 `0xeb1030d0` 就是栈），三个命中点读出来同一个名字：

```
0xf2f420c8  [anon:libc_malloc]  +0  ... "media.camera"        （它自己注册的名字，12 字符）
0xf3523208  [anon:libc_malloc]  +2  L=17 "scheduling_policy"  <- 这个
0xf3557a08  [anon:libc_malloc]  +2  L=17 "scheduling_policy"
```

（`android.os.IServiceManager` 的 UTF-16 串在 cameraserver 的 363 个可读区间里只出现在 libc_malloc 堆里，不会洒得到处都是；读到 `tail` 的时候要按 `4 + L*2` 解 UTF-16LE —— `L` 是紧跟接口名 NUL 之后的那个 int32。）

`scheduling_policy` 是 17 个字符，落在 {16,17} 里 ✓。

## 5. 代码定位：一次"给请求线程提优先级"的请求，卡在 `checkService` 的 `sleep(1)`

名字有了，调用点是一处，而且就在客户端那条路径上：

```cpp
// frameworks/av/services/camera/libcameraservice/device3/Camera3Device.cpp:2568-2582
// configureStreamsLocked() 的最后一段（流已经交给 HAL 之后）
char value[PROPERTY_VALUE_MAX];
property_get("camera.fifo.disable", value, "0");
int32_t disableFifo = atoi(value);
if (disableFifo != 1) {
    pid_t requestThreadTid = mRequestThread->getTid();
    res = requestPriority(getpid(), requestThreadTid, kRequestThreadPriority,
                          /*isForApp*/ false, /*asynchronous*/ false);
```

```cpp
// frameworks/av/media/utils/SchedulingPolicyService.cpp:31
int requestPriority(pid_t pid, pid_t tid, int32_t prio, bool isForApp, bool asynchronous)
{
    for (;;) {
        ...
        if (sps == 0) {
            sp<IBinder> binder = defaultServiceManager()->checkService(_scheduling_policy);
            if (binder == 0) { sleep(1); continue; }     // <-- 没有超时，也没有日志
```

`scheduling_policy` 是 `android.os.ISchedulingPolicyService`，手机上是 **system_server** 注册的（`SystemServer.java:828`）—— 这个容器没有 system_server，名字永远不存在，于是**正在处理客户端 `startPreview` 的那个线程**就睡在这一行上。这解释了这次现象的全部：

- app 主线程在等回复（§1）✓
- cameraserver 那个线程 1 秒一次 `checkService`、没有日志 ✓（`requestPriority` 这条路径确实一句都不打）
- 之前那条 `E/Camera2Client: notifyError: Error condition 0`（`66` 第 6 节把它当成了死因）是**下游**：60 秒之后 HAL 超时报错，而客户端的调用那时还没回。

顺带：同一个 `if` 里还有一条逃生口 —— `camera.fifo.disable=1` 会整段跳过。可以拿它做反证（设上属性、重跑，预览照样起），但**修法不是它**：属性得写进容器的 build 里，而手机上是"有这么一个服务"。

## 6. 修法：`service-stub` 的第五个名字，以及它真的去做那件事

`service-stub.c` 加第五个服务，形状和另外四个一样（raw binder、freestanding、静态）：

| 名字 | 接口 | 事务号 | 回复 |
|---|---|---|---|
| `scheduling_policy` | `android.os.ISchedulingPolicyService` | 1 requestPriority(pid, tid, prio, isForApp) / 2 requestCpusetBoost(enable, client) | `writeNoException()` + int32 |

`ISchedulingPolicyService.cpp` 的 Bp 侧最后是 `reply.readInt32()`，所以两个方法都要多回一个 int32（`answer()` 已经先写了 no-exception 字）。`requestPriority` 回答"OK"的同时**真的去做那件事**：对它点名的 tid 调 `sched_setscheduler(tid, SCHED_FIFO, prio)`（aarch64 号 119），结果写进日志，成败都回 OK —— 提升本身是尽力而为，拒绝只会让 cameraserver 打一条 warning，而不回就把客户端放回原处。tid 是调用者自己命名空间里的，而 stub 就跑在容器的 PID namespace 里，所以这个调用是直的。

验收（`/userdata/zl1-fw-stubs/service-stub.log`，第五个名字登记后同一个进程立刻被问）：

```
fwsvc[34315] registering "scheduling_policy" as node 0x5e51 cookie 0x5e52
fwsvc[34315] addService("scheduling_policy"): 136 bytes, object at +104
fwsvc[34315]   -> the name resolves
fwsvc[34315] transaction for scheduling_policy code 1 size 96 from pid 34305 uid 1047
fwsvc[34315] scheduling_policy: method 1 requestPriority pid=34305 tid=34373 prio=1 isForApp=0: SCHED_FIFO set
```

cameraserver 自己那条日志是第二份独立证据（它在 `res == OK` 分支才会打）：

```
D/Camera3-Device(34305): Set real time priority for request queue thread (tid 34373)
```

然后是客户端：

```
out| Started camera preview.
== reached the preview?
  yes: Started camera preview.
```

`dumpsys media.camera` 也把它自己说清楚了：`Active Camera Clients: [(Camera ID: 1, ... Client Package Name: hybris ...)]`、`Allowed user IDs: 0`、事件表里 `USER_SWITCH previous allowed user IDs: <None>, current allowed user IDs: 0` → `CONNECT device 1 client for package hybris`。

一次带时间顺序的完整日志留在 [`evidence/camera-preview-2026-09-22.log`](evidence/camera-preview-2026-09-22.log)。

## 7. 现在到哪儿，以及剩下的三件

预览"起得来"是这次拿到的；**出图还差最后一段**。同一份日志里的顺序是：`Camera 1: Opened` → `Set real time priority` → 立刻

```
E/Camera3-OutputStream: getBufferLockedCommon: Stream 0: Can't dequeue next output buffer: Broken pipe (-32)
W/Camera3-OutputStream: returnBufferCheckedLocked: A frame is dropped for stream 3 due to buffer error.
E/Camera2Client: notifyError: Error condition 0 reported by HAL, requestId -1
E/Surface: queueBuffer: error queuing buffer to SurfaceTexture, -32
...
W/Camera3-OutputStream: disconnectLocked: While disconnecting stream 0 from native window, the native window died from under us
```

也就是**预览流（stream 0）的 native window 一上来就是死的**：`-32` 是 EPIPE，消费者那头（SurfaceTexture）没人接；cameraserver 于是丢帧、HAL 报 `notifyErrorForPendingRequests`。app 自己的循环是活的（8 秒里 841 次 `ioctl(26</dev/kgsl-3d0>)` = 105 次/秒的 GPU 提交、约 25 次/秒的 `sync_fence` 等待），所以是"在画，但没有帧可画"。

`66` 第 6 节的结论要按这条改：`error_code = 0` 不是死因，是**下游**（以前它在挂起 60 秒后才出现，现在它出现在流建立之后、由 stream 0 的 buffer 错误触发），而且 `66` 里那张"客户端拿不到图所以报 connect 失败"的图景其实是"客户端永远卡在 startPreview + cameraserver 会话被拆掉"的两种表现。

1. **stream 0 的 native window 死在谁手上** —— 量出来了，见 [`68`](68-the-camera-stage-was-one-cookie-in-the-stub.md)：客户端活着的时候它不死；那串 `-32` 是客户端死后的日志（故意 `kill -9` 复现）。挡住出图的是 stub 里 `getToken` 的 cookie。
2. **输入层的 SurfaceFlinger 死循环**（§2）：让 `obtainPointerController()` 在没有 SurfaceFlinger 时也能返回一个可用的控制器 —— 注意 `InputReader.cpp:2854`、`5265-5300` 是不判空解引用的。
3. **`camera-stack-reset.sh` 的假警告**已经修掉：它原来用 `grep -A2 'checkService("media.camera")' | grep 'the name resolves'` 判定用户切换，而 `notifySystemEvent` 那条路径本来就不打 `the name resolves`，于是每次都误报 `WARNING: media.camera did not resolve`。现在按**最后一段** notify 的 `sent (oneway)` / `no such service` 判定。

## 8. 文件与复现

| 文件 | 作用 |
|---|---|
| `scripts/android-fw-stubs/service-stub.c` | 第五个服务 `scheduling_policy`（`serve_scheduling_policy`），头部有这次的全部现场证据与算式 |
| `scripts/android-fw-stubs/run-on-device.sh` | `SERVICES` 加上 `scheduling_policy`；结尾那段"现在到哪儿"改成了五个名字 + 预览 |
| `scripts/android-fw-stubs/camera-stack-reset.sh` | 用户切换的判定改成不会误报；头部记上"stub 必须是带第五个名字的那份"（就是这个脚本在部署它） |
| `docs/ubuntu-touch/evidence/camera-preview-2026-09-22.log` | 这次运行的 camerasever / stub / dumpsys 摘录 |

```sh
scripts/android-fw-stubs/run-on-device.sh            # 五个名字
scripts/android-fw-stubs/camera-stack-reset.sh       # provider → cameraserver → 枚举 → 用户切换
scripts/android-fw-stubs/run-camera-test.sh --line-buffered --timeout 90
# 期望：out 里出现 Started camera preview.；stub 日志里出现 requestPriority ... SCHED_FIFO set
```

**设备安全**：只往 `/userdata/` 写（`zl1-fw-stubs`、`zl1-camera`）、只读地看 `/proc`、`/sys/kernel/debug/{binder,tracing}`；为拿到干净状态重启过 cameraserver 与 camera provider（init 托管的运行时服务，重启即恢复），devicetree 每次核对过是 `MSM 8996pro + PMI8996 LE_ZL1`。没有碰任何分区、没有动 boot 镜像、没有改容器内文件。设备没有变砖，GUI 照常。
