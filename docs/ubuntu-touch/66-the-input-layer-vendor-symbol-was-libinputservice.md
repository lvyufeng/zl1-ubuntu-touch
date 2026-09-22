# 66 — 输入兼容层的那个 vendor 符号不是符号问题：`libinputservice` 把整个音频栈拖进了相机进程

**日期**: 2026-09-22
**状态**: **`libis_compat_layer.so` 现在能在设备上加载了。** 在此之前它在 `android_input_stack_initialize()` 里必死：`err` 只有一行 `cannot locate symbol "_ZN7android9AVFactory17createMediaFilterEv" referenced by "/android/system/lib64/libavenhancements.so"`，`out` 是空的，退出码 139。原因不是缺一个符号，是 **DT_NEEDED 是传递的**：本模块链 `libinputservice.so`，而它链 `libhwui.so`，`libhwui` 链 `libheif.so`，`libheif` 链 `libmedia.so`，`libmedia` 链 `libavenhancements.so` —— 一个 vendor 预编译库，导入一个**这个镜像上没有任何库提供**的符号。修法是把这个依赖去掉（不是补那个符号）：`libinputservice` 在本树里只有两个源文件，把它们编进本模块即可。验收：新 `.so` 的 DT_NEEDED 里没有 `libinputservice`/`libhwui`/`libheif`/`libmedia`，三个 `Pointer/SpriteController` 符号改为本模块自己定义，导出的 `android_input_*` 仍然是 6 个；设备上同一条命令不再 139。

**接续**: [`65`](65-the-camera-was-blocked-on-four-system-server-services.md)（四个 system_server 服务 + reply 路径读 binder 的自伤）

---

## 1. 现象：连上了，然后在输入层里死掉，`out` 是空的

`65` 收口之后，`test_camera` 的连接一路通到 cameraserver 打开 camera 1，接着：

```
== exit=139
err| cfi-shadow-init[18627] loaded
err| cannot locate symbol "_ZN7android9AVFactory17createMediaFilterEv" referenced by "/android/system/lib64/libavenhancements.so"...
err| cannot locate symbol "_ZN7android9AVFactory17createMediaFilterEv" referenced by "/android/system/lib64/libavenhancements.so"...
== reached the preview?
  no
```

`hybris` 的 `android_dlopen` 不对失败的 dlopen 做 NULL 检查，所以"找不到符号"不是一条消息，是几条指令之后跳到 NULL：`out` 空、退出码 139，看起来像"什么都没发生"。

## 2. 第一次判断（"去掉 libheif"）对，但**不够**

`libskia` 的 `SkHeifCodec.o` 在本模块里只有一个外部依赖 `createHeifDecoder()`（libheif 提供），所以第一版是把它从 `LOCAL_SHARED_LIBRARIES` 里拿掉、换成 `compat-layer-src/zl1-no-libheif.cpp` 提供的空实现（`SkHeifCodec.cpp:123-127` 明确检查 null，这是 skia 支持的一条路径）。构建通过，`readelf -dW` 里确实没有 libheif 了 —— **然后设备上还是同样的 139，同样的消息。**

原因：libheif 不是从这个模块自己的 NEEDED 进来的，是**从别处进来的**。用 `strace -f -qq -e trace=openat` 抓加载顺序（`/userdata/zl1-camera/strace-open.txt`）：

```
"/userdata/zl1-hybris/lib/libis_compat_layer.so" = 4
"/android/system/lib64/libinput.so"              = 5
"/android/system/lib64/libandroidfw.so"          = 6
"/android/system/lib64/libinputflinger.so"       = 7
"/android/system/lib64/libinputservice.so"       = 8
...
"/android/system/lib64/libhwui.so"               = 20
"/android/system/lib64/libheif.so"               = 22
...
"/android/system/lib64/libmedia.so"              = 27
...
"/android/system/lib64/libavenhancements.so"     = 4
```

顺序只是线索，结论要靠**逐个 .so 的 DT_NEEDED**（把设备上的库 scp 回来，在主机上 `readelf -dW`）：

| 库 | NEEDED 里有没有 libhwui |
|---|---|
| `libandroidfw.so` | 没有（它链的是 libgui） |
| `libgui.so` | 没有 |
| `libinputflinger.so` | 没有 |
| **`libinputservice.so`** | **有** |

所以链是

```
libis_compat_layer.so -> libinputservice.so -> libhwui.so -> libheif.so -> libmedia.so -> libavenhancements.so
```

而 `libavenhancements.so` 是 LeEco 的 vendor 预编译库，导入

```
_ZN7android9AVFactory17createMediaFilterEv      android::AVFactory::createMediaFilter()
```

`grep -l` 整个 `/system/lib64`、`/vendor/lib64`、`/odm/lib64`：只有 4 个库**引用**它（`libavenhancements`、`libmedia2_jni`、`libmediaplayerservice`、`libstagefright_httplive`），**没有任何库定义它**。也就是说这个镜像上的 vendor 图形/音频栈本来就是断的，只是平时没人把它加载进相机进程而已。

**这是本次最值得记下来的一条**：`DT_NEEDED` 是传递的，"我把 libheif 从我的列表里删掉了"不等于"libheif 不在我的进程里"。判断这类问题必须在设备上量加载顺序，或者把每个依赖的 `.so` 拉回来量它的 NEEDED，两者缺一不可。

## 3. 修法：不要 libinputservice，把它的两个源文件编进来

上游 `frameworks/base/libs/input/Android.bp` 写得很清楚，`libinputservice` 就是两个源文件：

```python
cc_library_shared {
    name: "libinputservice",
    srcs: [ "PointerController.cpp", "SpriteController.cpp" ],
    shared_libs: [ ..., "libhwui", "libgui", ... ],   # libhwui 只是为了 Skia
}
```

而这个模块**已经有 Skia**（静态链接的 `libskia` + 那四个它自己的静态依赖，见 `build-compat-layer.sh` 里 libheif 那一段的解释），它从 `libinputservice` 要的符号一共只有 3 个：

```
_ZN7android16SpriteControllerC1ERKNS_2spINS_6LooperEEEi
_ZN7android17PointerController18setDisplayViewportEiii
_ZN7android17PointerControllerC1ERKNS_2spINS_32PointerControllerPolicyInterfaceEEERKNS1_INS_6LooperEEERKNS1_INS_16SpriteControllerEEE
```

（用本模块的 UND 符号集和 `libinputservice.so` 的导出符号集求交集量出来的，不是猜的。）

于是改动是：`LOCAL_SHARED_LIBRARIES` 里去掉 `libinputservice`，把 `frameworks/base/libs/input/{Pointer,Sprite}Controller.cpp` 拷进模块目录并加进 `LOCAL_SRC_FILES`；再加上 `libui`（`SpriteController` 画图用 `android::bytesPerPixel()` 和 `android::Region`，两个都在 `libui.so`，而 `libui` 自己的依赖只有 HIDL 的 mapper/allocator 和 base，**链到这里就断了**）。

功能上没有取舍：鼠标指针的 sprite 和触点可视化用的就是这两个类，代码一模一样，只是从"从系统库调用"变成"本进程内调用"。而 `test_camera` 传的 `InputStackConfiguration` 是 `{ false, 25000, 1024, 1024 }`，第一项 `enable_touch_point_visualization = false`，所以这条路在相机里本来也不走。

验收（主机上对新构建的 `.so`）：

```
NEEDED: libinput libcutils libutils libgui libandroidfw libinputflinger libui libft2 libexpat
        liblog libpng libjpeg libz libnativewindow libicui18n libicuuc libpiex libdng_sdk
        libEGL libGLESv2 libvulkan libc++ libc libm libdl          <- 没有 inputservice/hwui/heif/media
导出符号: android_input_* 6 个（接口没变）
        _ZN7android16SpriteControllerC1ERKNS_2spINS_6LooperEEEi        本模块定义
        _ZN7android17PointerController18setDisplayViewportEiii          本模块定义
        _ZN7android17PointerControllerC1E...                            本模块定义
```

设备上部署后（两侧 md5 一致），`test_camera` 不再 139：进程活得下来，被 `timeout` 杀掉（exit 124），`err` 里没有那条符号消息。

## 4. 顺带修掉的一个自伤：`--notify-user-switch` 把 stub 停掉就不管了

`run-on-device.sh` 的每个模式开头都会 `--stop`（正在服务的实例必须先停，否则 `addService` 会 `ALREADY_EXISTS`，而且运行中的可执行文件不能覆盖）。但 `--notify-user-switch` 分支在发完 `notifySystemEvent` 之后直接 `exit 0` —— **serving 的那份 stub 被停掉、没有起来**。后果不是"小一号的功能"：

cameraserver 的 `checkPermission()` 要问 `permission` 这个名字，而它的重试循环是 **untimed** 且占着 `CameraService::mServiceLock`。客户端于是永远卡在

```
threads: 1   wchan: binder_thread_read   syscall: 29 (ioctl)
```

stub 日志零增长、cameraserver 什么都没问、`dumpsys` 也拿不到东西。现场就是这样一张"谁都没报错、谁都没动"的图。现在这个模式发完事件会继续把 stub 拉起来 —— 一次 `--notify-user-switch` 之后是**完整的**可用状态（四个名字在服务 + `mAllowedUsers = {0}`）。

## 5. 两个测量工具（这次加的）

- `run-camera-test.sh --no-input-stack`：把 `no-input-stack.so` 加到 `LD_PRELOAD`，六个 `android_input_stack_*` 入口被它自己接掉，`libis.so.1` 就不会去 dlopen 真正的输入层。**这是测量手段，不是修法**，用来把"输入层的问题"和"相机的问题"分开。
- `run-camera-test.sh --line-buffered`：崩溃会丢掉 stdio 缓冲。`test_camera` 的进度是用 `printf` 写到重定向文件里的（块缓冲），早死就是**空文件**，看起来像"它什么都没打印"。加 `stdbuf -oL` 之后，"最后打印到哪一行"才是可读的证据。

## 6. 现在卡在哪：HAL 发了一个非法 error notify，cameraserver 于是把相机关掉

输入层这一堵墙拆掉之后，相机侧的现场变成（同一次运行）：

```
I/CameraService: CameraService::connect call (PID -1 "hybris", camera ID 1) ...
I/Camera2ClientBase: Camera 1: Opened. Client: hybris (PID 21402, UID 0)
E/Camera2Client: notifyError: Error condition 0 reported by HAL, requestId -1
I/Camera2Client: Camera 1: Closed
I/Camera2ClientBase: Closed Camera 1. Client was: hybris (PID 21402, UID 0)
```

`errorCode = 0` 在 `Camera3Device::notifyError()` 的映射表里是"未使用"，落到 `default:` 分支按**设备级错误**处理（`CameraDeviceBase` → `SET_ERR`），于是会话被拆掉，`test_camera` 拿到 `Problem connecting to camera`（exit 1）或干脆在 hybris 的 NULL 上再崩一次（exit 139）。症状每次不同，因为时间点不同：

- HAL 在 `configureStreams` 之后报错时：`strace` 里能看到 4 条输出流（`format 34` 预览 1920x1080 / `format 33` BLOB 3264x2448 / `format 34` 3264x2448 / 一条 `type=1` 的输入流），`mm-camera` 还打印了 `Linking successful for stream 0x30001`，然后 `Camera3-Device: Stream 1: DataSpace override not allowed for format 0x21`（BLOB 流的 dataspace 与 HAL 的 override 不一致，这条只是 ALOGE，不是失败），紧接着就是上面那条 `notifyError`。
- HAL 在会话初始化时就报错时：`QCamera: <MCI><ERROR> mm_channel_fsm_fn_stopped: 891: invalid state (1) for evt (6)`、`lock_acq: 363: failed to acquire lock` —— 通道状态机在"已停"状态下又收到一次 stop。

同一个栈里的第二个问题：**`mm-qcamera-daemon` 在收尾时会 abort**。`/data/tombstones/tombstone_0*` 今天新增了 6 个，全是同一个：

```
pid: 20163, tid: 20282, name: CAM_stopisp  >>> /vendor/bin/mm-qcamera-daemon <<<
signal 6 (SIGABRT), code -6 (SI_TKILL)
Abort message: 'FORTIFY: pthread_mutex_destroy called on a destroyed mutex (0xe503045c)'
backtrace:
  #03 pthread_mutex_destroy+128
  #04 /vendor/lib/libmmcamera2_isp_modules.so
  #05 /vendor/lib/libmmcamera2_mct.so
另一条线程栈：
  #03 /vendor/lib/libmmcamera2_mct.so (mct_pipeline_sync_pend+22)
  #04 /vendor/lib/libmmcamera2_mct.so (mct_pipeline_stop_session+524)
  #05 /vendor/lib/libmmcamera2_mct.so (mct_controller_destroy+318)
  #06 /vendor/bin/mm-qcamera-daemon
  #07 /vendor/bin/mm-qcamera-daemon (main+1264)
```

即 `mct_controller_destroy`（主线程）与 `CAM_stopisp` 线程同时拆同一个 ISP 模块，互斥量被 destroy 两次。daemon 退出后由 provider 重新拉起；但**下一次连接会撞上**

```
E/CameraService: CameraService::connect (PID -1) rejected (too many other clients connecting).
W/CameraBase: ... 'connectHelper:1338: Cannot open camera 1 for "hybris" (PID -1): Too many other clients connecting'
```

也就是 `65` 里那个 3 s 的 `AutoConditionLock` 超时。清掉这一状态的顺序（这次用了很多次）：`ctl.restart cameraserver` → 杀掉 provider（init 会把它和 daemon 一起重新拉起）→ 等 `dumpsys media.camera` 报 `Number of camera devices: 2` → `run-on-device.sh --notify-user-switch`。

顺带一个与相机无关但会刷屏的背景：`/vendor/bin/vsimd` 因为 `/vendor/lib*/libQSEEComAPI.so` 不存在而反复 `CANNOT LINK EXECUTABLE`，被 init 一直重启（`vsimd` 是视频侧的，不在相机路径上）。

## 7. 文件与复现

| 文件 | 作用 |
|---|---|
| `scripts/hybris-shims/build-compat-layer.sh` | 树补丁。这次新增：去掉 `libinputservice`、把它的两个源文件编进来、补 `libui`；原来的 libskia/libheif/`setDisplayInfo` 三段保持不变，每段各自独立可重入 |
| `scripts/hybris-shims/compat-layer-src/zl1-no-libheif.cpp` | `createHeifDecoder()` 的空实现（skia 的 HEIF 编解码器对象在静态 libskia 里，绕不开） |
| `scripts/android-fw-stubs/run-on-device.sh` | `--notify-user-switch` 现在会连 stub 一起拉起来（第 4 节） |
| `scripts/android-fw-stubs/run-camera-test.sh` | 新增 `--no-input-stack`（测量）与 `--line-buffered`（崩溃时能看到进度） |
| `scripts/android-fw-stubs/no-input-stack.c` | 那六个入口的空实现，freestanding、无 libc |

```sh
scripts/hybris-shims/build-compat-layer.sh libis_compat_layer      # 产出 scripts/hybris-shims/out/libis_compat_layer.so
# 部署：scp 到设备的 /userdata/zl1-hybris/lib/（运行时安装，两侧 md5 必须一致）
scripts/android-fw-stubs/run-on-device.sh                          # 四个服务 + mAllowedUsers
scripts/android-fw-stubs/run-camera-test.sh --line-buffered        # 跑相机
```

**设备安全**：全程只写 `/userdata/`（`zl1-hybris/lib`、`zl1-camera`、`zl1-fw-stubs`），只读地看 `/proc`、binder debugfs 和 `/data/tombstones`；没有碰任何分区、没有动 boot 镜像、没有改容器内文件。为了拿干净状态重启过 cameraserver 和 camera provider（都是 init 托管的运行时服务，重启即恢复），设备没有变砖，GUI 照常。

## 8. 下一步

1. **HAL 那条 `error_code = 0`**：要确定它是"客户端要的流/参数它不支持"还是"它自己的状态坏了"。可用的杠杆：hybris 侧 `halium/libhybris/compat/camera/camera_compatibility_layer.cpp` 是我们自己构建的，可以改它请求的流配置（现在客户端要 4 条流，其中一条是 `type=1` 的输入流、还有一条 BLOB 的 dataspace 对不上）逐项排除。
2. **daemon 的 abort**：先确认它是不是"daemon 正常退出时的 vendor 竞态"（也就是无害噪音），办法是看它是否**只在**会话收尾时发生；如果不是，再看 `mct_controller_destroy` 是被谁触发的。
3. 上面两条清了之后才是 `65` 第 7 节剩的那件事：`Started camera preview.` 真正打出来、以及 UT 侧 `libcamera.so.1` 的取帧路径。
