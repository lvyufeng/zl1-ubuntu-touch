# 65 — 相机打不开，堵在 system_server 的四个服务上；外加一个"在 reply 路径里读 binder"的自伤

**日期**: 2026-09-22
**状态**: **Android 侧整条相机链路已经打通。** `/usr/bin/test_camera` 的 `connect()` 现在能走完 `validateClientPermissionsLocked`，cameraserver 会把 camera 1 真正打开交给它（`QCamera: openCamera`、`mm-camera` daemon 起 `init mods done`），客户端退出后再干净地关掉（`closeCamera ... rc: 0`）。**相机还没有出图**，最后一堵墙在客户端侧而不是 Android 侧：`libcamera_compat_layer.so` 需要 `libis_compat_layer.so`（libhybris 的 input-system 兼容层），设备上没有 —— §7。设备没有变砖，GUI 照常。
**接续**: [`64`](64-the-last-unit-was-not-failing-it-was-obeying.md)、[`48`](48-the-tls-fault-was-killing-seven-system-services.md)

---

## 1. 现象：不是打不开，是**永远**打不开

`/usr/bin/test_camera`（aarch64，跑在容器 PID namespace 里、带两个 preload）输出一行就停住，没有图：

```
out| Problem connecting to camera
```

cameraserver 那边看起来也不像出错，更像**卡住**：

```
I/CameraService( 1021): CameraService::connect call (PID -1 "hybris", camera ID 1) for HAL version default and Camera API version 1
I/ServiceManager( 1021): Waiting to check permission android.permission.CAMERA from uid=0 pid=12667
（然后就没有然后了，直到 1630 秒后）
```

`ServiceManager` 这一行来自 libbinder 的 `android::checkPermission()`（`frameworks/native/libs/binder/IServiceManager.cpp:81`），它是个**没有超时**的重试循环：

```cpp
while (true) {
    if (pc != NULL) { bool res = pc->checkPermission(permission, pid, uid); ... return res; }
    sp<IBinder> binder = defaultServiceManager()->checkService(_permission);
    if (binder == NULL) {
        if (startTime == 0) { startTime = uptimeMillis(); ALOGI("Waiting to check permission %s ..."); }
        sleep(1);                      // 一秒一次，永不放弃
    } else { pc = interface_cast<IPermissionController>(binder); }
}
```

而它是在 `CameraService::connect → connectHelper` 里被调的，**`mServiceLock` 从头到尾被攥着**。所以不只是这一次 connect 卡住：后面每一次 connect 都排在同一个锁上。device 上的实测（`/proc/<cameraserver>/task/*/syscall`，cameraserver 是 **32 位**进程，futex 是 240 号系统调用）：

```
tid=1597268 Binder:1021_1  futex_wait 0xf504d008 val=0x2   <- 持锁者，每秒 sleep(1) 一次
tid=3254879 Binder:1021_2  futex_wait 0xf504d008           <- 排在后面的 connect
tid=3254880 Binder:1021_3  futex_wait 0xf504d008
tid=49944   cameraserver   futex_wait 0xf504d008
```

`_permission` 就是 `android.os.IPermissionController`，手机上由 **system_server** 注册。Halium 容器里没有 system_server —— 所以这个循环不会结束，这个锁不会松。

## 2. 四个洞，不是两个

按 connect() 的执行顺序，一共要补四个名字。前两个是"有它才能往下走"，后两个是"没它就走不远"：

| 名字 | 接口 | 谁在问 | 不问会怎样 |
|---|---|---|---|
| `permission` | `android.os.IPermissionController` | `validateClientPermissionsLocked` → `checkPermission` | 上面那个死循环 + `mServiceLock` 永不释放 |
| `appops` | `android.app.IAppOpsService` | `Client::startCameraOps` → `startOpNoThrow` | `APP_OPS_MANAGER_UNAVAILABLE_MODE = MODE_IGNORED` → 返回 `-EACCES`：`Access ... has been restricted` |
| `activity` | `android.app.IActivityManager` | `notifySystemEvent` → `CameraUidPolicy::registerSelf` | 用户切换事件永远落不了地（§4） |
| `processinfo` | `android.os.IProcessInfoService` | `handleEvictionsLocked` → `ProcessInfoService` | 40 次 1 秒重试后 `TIMED_OUT` → `-110`（§5） |

### 2.1 `mAllowedUsers` 永远是空的（第三个洞）

补上前两个之后，日志确实往前走了一步，然后换了一堵墙：

```
I/CameraService: Check passed after 1630 seconds for android.permission.CAMERA from uid=0 pid=12667
E/CameraService: CameraService::connect X (PID 12667) rejected (cannot connect from device user 0, currently allowed device users: )
```

被拒的那一行是 `CameraService.cpp:938`：

```cpp
if (callingPid != getpid() && (mAllowedUsers.find(clientUserId) == mAllowedUsers.end())) { ... }
```

`mAllowedUsers` **只有一个写入者**：`CameraService::doUserSwitch`（`CameraService.cpp:1862`）。手机上它是被 system_server 的 `CameraServiceProxy` 用 `ICameraService::notifySystemEvent(EVENT_USER_SWITCHED, {userId})` 叫起来的 —— 没有 system_server，就没人告诉 cameraserver 哪个用户被允许连，集合一直是空的，于是**不管权限问题怎么回答，任何客户端都被拒**。

所以 stub 除了注册服务，还要**当一次客户端**，替 system_server 发那一条 oneway 事务：

```
u32 0x00400000                    // strict mode policy
u32 26 "android.hardware.ICameraService"
int32 1                           // EVENT_USER_SWITCHED
int32 1 / int32 0                 // int[] args = {0}
```

`notifySystemEvent` 是 `ICameraService.aidl` 里第 14 个方法（按声明顺序数：1 getNumberOfCameras、2 getCameraInfo、3 connect、… 13 setTorchMode、**14 notifySystemEvent**）。这条事务发出去以后，cameraserver 立刻反问了一个权限：

```
fwsvc transaction for permission code 1 size 180 from pid 1021 uid 1047
fwsvc permission: method 1 permission=android.permission.CAMERA_SEND_SYSTEM_EVENTS
```

—— 也就是说 `notifySystemEvent` 是真的进了处理函数（不然不会去查 `CAMERA_SEND_SYSTEM_EVENTS`），这是发对了的**第二个**独立证据。

### 2.2 `registerSelf()` 在等一个 8 个字符的服务（第三个洞的后半）

用户切换事件进了处理函数，却没生效。原因是 `EVENT_USER_SWITCHED` 的第一句不是 `doUserSwitch`，而是：

```cpp
case ICameraService::EVENT_USER_SWITCHED: {
    mUidPolicy->registerSelf();          // <-- 先问 ActivityManager
    doUserSwitch(args);                  // <-- 才轮到用户切换
```

`ActivityManager::getService()`（`frameworks/native/libs/binder/ActivityManager.cpp:33`）是**另一个**没有健康出口的循环：

```cpp
while (service == NULL || !IInterface::asBinder(service)->isBinderAlive()) {
    sp<IBinder> binder = defaultServiceManager()->checkService(String16("activity"));
    if (binder == NULL) {
        if (startTime == 0) ALOGI("Waiting for activity service");
        else if ((uptimeMillis() - startTime) > 1000000) { ALOGW("... giving up"); break; }
        usleep(25000);                   // 25 毫秒一次
    } else { service = interface_cast<IActivityManager>(binder); mService = service; }
}
```

> 也就是说，即使 stub 什么都不做，**1000 秒后它自己会放弃**、`registerSelf()` 返回、用户切换随后生效。设备上确实是这样：`Check passed after 1630 seconds`、`518 seconds` 就是前两次 connect 各自等到的时刻。补上 `activity` 之后这个等待变成毫秒级。

这条循环在设备上的样子是：`/sys/kernel/debug/binder/transaction_log` 里每 25 毫秒一条 `from 49944:3254880 to 41134 node 43 handle 0 size 88:0`，回的永远是 4 字节（没找到）。**88 字节**是关键：`4(strict) + [4+26*2+2 → 60]` 的接口名之后，名字字段是 24 字节 → 名字长 8 或 9 个字符 —— `"activity"` 是 8 个。两个候选名字（`permission` 是 10 字符 → 92 字节）用字节数就能分开。名字本身是扫描 cameraserver 的堆确认的：`00004000 1a000000 "android.os.IServiceManager" ... 08000000 "activity"`。

### 2.3 `-110`（第四个洞）

用户切换生效之后，connect() 走到了真的建客户端那一步，然后：

```
E/CameraService: handleEvictionsLocked: Priority score query failed: -110
W/CameraBase(14890): An error occurred while connecting to camera 1: Status(-8): '10: connectHelper:1375:
                    Unexpected error Connection timed out (-110) opening camera "1"'
```

`-110` 是 `ETIMEDOUT`，来自 `ProcessInfoService::getProcessStatesScoresImpl()`：它对 `checkService("processinfo")` 做 `BINDER_ATTEMPT_LIMIT` 次重试（每次 `sleep(1)`）后返回 `TIMED_OUT`。这个容器里没有进程模型，也没有别人拿着相机，所以每个被问到的 pid 都按"存在、且在前台"回答（`state 2 = PROCESS_STATE_TOP`、`score 0`）—— 这也是唯一的客户端的真实情况，`wouldEvict` 因此返回空集，不驱逐任何人。

## 3. ★ 真正把整件事又堵回去的 bug：在 reply 路径里读 binder

上面四步每补一个，日志就往前走一段，但**补到第三个的时候又开始永久卡住**——而且卡得更像"信号丢了"：cameraserver 的 `checkPermission` 明明发出去了，stub 的日志里却什么都没有。

measure 出来的状态（`/sys/kernel/debug/binder/proc/<stub>`）：

```
thread 4041263: l 12 need_return 0 tr 0
  incoming transaction 542958: ... from 49944:3254879 to 4041263:4041263 code 1 ... node 542898 size 140:0
node 542898: u0000000000005e11 c0000000000005e12 ...        <- 就是 "permission"
buffer 542958: ... size 140:0:0 active                      <- 事务已投递，没人回
```

同一时刻 stub 的线程状态是 `wchan=binder_thread_read`（阻塞在**读**里），而事务已经躺在它的 todo 表里。原因在 stub 自己身上：**它在 `send_reply()` 里也读了**。

```c
/* 旧版：BC_REPLY 之后又读一次 */
bwr.write_size = 4 + sizeof(tr);
bwr.read_size  = sizeof(rbuf);        // rbuf 是这个函数里的局部数组
bwr.read_buffer = ...;
sys_ioctl(fd, BINDER_WRITE_READ, &bwr);
```

`BINDER_WRITE_READ` 在 `read_size` 非零时**同时读**。于是：回完上一条事务之后，这个 ioctl 顺手把下一条命令读进了函数里的局部 `rbuf`，然后**函数返回、数组丢掉**。对内核来说这条事务已经投递给用户态了（`BR_TRANSACTION` 已经返回），不会再来第二次；对发送方来说回复永远不会来。同一个毛病还有两处：

- `send_reply()` 的第二个 ioctl（`BC_FREE_BUFFER`）也带 `read_size`；
- `binder_transact()` 里 oneway 发送之后也读（`notifySystemEvent` 之后那几十毫秒里正好有事务回来）。

顺带量出来的第二个问题：`buffer ... delivered` 有 5 个从没释放过 —— reply 的 buffer 也是我们的，`BC_FREE_BUFFER` 不能省，否则每 `checkService` 一次泄漏一个（这个进程要活到相机用完为止）。

**修法**：读**只在一个地方发生**（主循环）。`send_reply()` 和 oneway 发送全部 `read_size = 0`；`binder_transact()` 等 reply 的时候如果读到一条 `BR_TRANSACTION`，就地 `answer()` 掉（binder 本来就允许嵌套：同一条线程上先回外层、再回里层）；reply 的 buffer 拿到就还；oneway 事务不回复（内核会以 `BC_REPLY with no pending transaction` 拒绝）但仍要还 buffer。

改完那一条堵了很久的事务立刻被回答，并且解析也对了：

```
fwsvc transaction for permission code 1 size 140 from pid 1021 uid 1047
fwsvc permission: method 1 permission=android.permission.CAMERA pid=13016 uid=0
```

（顺带修了日志本身：事务参数从 `data.writeInterfaceToken()` 写下的 strict-mode 字 + 接口名之后才开始，原来从偏移 0 读，把**接口名**当成了参数打出来 —— 于是日志里出现过 `permission=android.os.IPermissionController` 这种荒唐行。）

## 4. 现在到哪儿了

Android 侧全通。同一次运行里，cameraserver 依次问完四个服务之后，把 camera 1 打开交给了客户端：

```
fwsvc transaction for processinfo code 2 size 88 pids=1 14928
fwsvc transaction for appops code 5 size 136      (startWatchingMode)
fwsvc transaction for appops code 7 size 112      (getToken)
fwsvc transaction for appops code 3 size 144      (startOperation)
I/mm-camera(15005): <MCT><INFO> server_process_module_init: CAMERA_DAEMON: init mods done
I/QCamera ( 2229): <HAL><INFO> closeCamera: [KPI Perf]: X PROFILE_CLOSE_CAMERA camera id 1, rc: 0
I/CameraService: disconnect: Disconnected client for camera 1 for PID 14928
```

客户端侧的最后一堵墙（strace 直接指出来）：

```
openat("/userdata/zl1-hybris/lib/libcamera_compat_layer.so") = 3
openat("/userdata/zl1-hybris/lib/libis_compat_layer.so")     = -1 ENOENT
openat("/android/system/lib64/libis_compat_layer.so")        = -1 ENOENT
... 之后是 Android 的默认搜索路径、egl、vndk-28
out| Problem connecting to camera
err| library "libis_compat_layer.so" not found
```

搜索顺序（先 `HYBRIS_LD_LIBRARY_PATH`，再 Android 的路径）说明这是 **hybris 自己的 `android_dlopen`**，不是 glibc 的 `DT_NEEDED`；`grep -l` 出来点名要它的是 `/usr/lib/aarch64-linux-gnu/libis.so.1`（libhybris 的 input-system 那一半），而 `libis.so.1` 是被 `libcamera.so.1` 拉进来的。`libis_compat_layer` 由 `halium/libhybris/compat/input/Android.mk` 构建（导出 `android_input_*`）——**还没构建、也还没部署**。`scripts/hybris-shims/build-compat-layer.sh` 的模块表已经把它加上了。

## 5. 这次的坑：AIDL 的事务号不能猜

给 `IActivityManager` 写 handler 时先按"记得大概是 173/174"填了两个常数，然后从 `frameworks/base/core/java/android/app/IActivityManager.aidl` 按声明顺序数出来是 **2**（`registerUidObserver`）和 **4**（`isUidActive`）——因为 AIDL 给前四个方法分配的号正好就是 libbinder 那个 native `ActivityManager` 类用到的四个，顺序都一样，这本身就是个旁证。设备上跑起来后日志里收到的就是 `code 2`：

```
fwsvc transaction for activity code 2 size 132 from pid 1021 uid 1047
```

同一件事在 `ICameraService` 上是先算（14 = notifySystemEvent）再用设备上的行为反证（收到 `CAMERA_SEND_SYSTEM_EVENTS` 的权限查询）。**接口号属于"必须量、不能猜"的那一类**，和分区偏移、TLS 槽位一样。

## 6. 文件与复现

| 文件 | 作用 |
|---|---|
| `scripts/android-fw-stubs/service-stub.c` | 全部四个服务的实现，raw binder、freestanding、静态 aarch64，无 libc。头部有每个洞的现场证据 |
| `scripts/android-fw-stubs/build.sh` | 用 Halium 树里的 clang/lld 交叉编出静态 ELF，并断言"无 DT_NEEDED / 无 PT_INTERP / 无未定义符号" |
| `scripts/android-fw-stubs/run-on-device.sh` | 部署到 `/userdata/zl1-fw-stubs/` 并在**容器 PID namespace 里**启动；`--status` / `--stop` / `--foreground` / `--notify-user-switch`（这个模式在后一个提交里被修好：它会先 `--stop`，所以必须自己把 stub 拉回来，见 `66` 第 4 节） |
| `scripts/android-fw-stubs/run-camera-test.sh` | 带两个 preload 跑 `/usr/bin/test_camera`，把输出留在设备上并过滤掉 TLS 垫片的噪声；后来加了 `--no-input-stack` 和 `--line-buffered`（见 `66` 第 5 节） |
| `scripts/hybris-shims/build-compat-layer.sh` | 兼容层构建表，加上 `libis_compat_layer`（`66` 里完成） |

```sh
scripts/android-fw-stubs/run-on-device.sh          # 部署 + 启动，日志里能看到四个名字都 resolve
scripts/android-fw-stubs/run-camera-test.sh        # 跑相机
```

为什么必须跑在容器的 PID namespace 里（`nsenter -p`，永远不要 `-F`）：servicemanager 的 SELinux 钩子用 `getpidcon(pid)` 取调用者上下文，主机侧进程在那里 pid 是 0，注册会被直接拒掉 —— 设备日志写得很直白：`SELinux: getpidcon(pid=0) failed to retrieve pid context.` / `list_service() uid=0 - PERMISSION DENIED`。

**设备安全**：整个过程只往 `/userdata/` 写文件、只读地看 `/proc` 和 binder debugfs，没有碰任何分区、没有动 boot 镜像、没有改容器内文件。设备没有变砖，GUI 照常。

## 7. 下一步

1. ~~构建并部署 `libis_compat_layer.so`~~ —— 做完了，见 [`66`](66-the-input-layer-vendor-symbol-was-libinputservice.md)：它卡的不是 `libskia` 那一步，而是 `libinputservice → libhwui → libheif → libmedia → libavenhancements` 这条传递依赖，链尾是一个这个镜像上没人定义的 vendor 符号。修法是把 `libinputservice` 整个去掉（它的两个源文件编进本模块）。
2. 输入层能加载之后，现在卡在 HAL：它发了一个 `error_code = 0` 的非法 error notify，cameraserver 按设备级错误处理并关掉会话；同一个栈里 `mm-qcamera-daemon` 收尾时 FORTIFY abort。证据和下一步都在 `66` 的第 6、8 节。
3. 然后才是真正的出图：`test_camera` 拿到的帧、以及 UT 侧 `libcamera.so.1` 的取帧路径。
4. stub 现在还是手工起的运行时安装；要长期存在得做成一个 systemd unit（和 `zl1-ns-exec` 那批一样），但那属于"确认有用之后"的事。
