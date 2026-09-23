# 80 — UT 相机 app 起来了；而挡住它的是**我们自己那个 preload**（`cfi-shadow` 把进程里每一次 hybris dlopen 都弄坏了）

**日期**: 2026-09-23
**状态**: 相机线上最后一个没测过的东西（UT 相机 app `camera.ubports_camera_4.1.1`）**第一次站住了**：连上 Mir、拿到 hybris 的 EGL（`vendor = Android`、`1.4 Android META-EGL`）、QML 起来了、**把两个摄像头都枚举到了**（`Added camera "0"` / `"1"`）、`** Application is now active`，30 秒定时器到点时还活着。路上发现真正的拦路者是**本仓库自己的 `libcfi-shadow-init.so`**：它的 `dlsym(RTLD_NEXT, "android_dlopen")` 在某些进程里解析不到（`libhybris-common` 只在一个 dlopen 进来的库的 **local scope** 里），于是它把每一个 hybris `dlopen` 都回答了 NULL —— 结果是 glvnd 拿不到 hybris 的 EGL、退到 Mesa、而 Mesa 在这台设备上**根本不可能工作**（它要 `/dev/dri`，这台机器是 kgsl）。修好它，EGL 就回来了。

**接续**: [`77`](77-the-screen-can-be-photographed-and-the-camera-is-on-it.md)（相机硬件本身已经证明，屏上能拍到；`test_camera` 是那个证据）、[`65`](65-the-camera-was-blocked-on-four-system-server-services.md)/[`68`](68-the-camera-stage-was-one-cookie-in-the-stub.md)（`test_camera` 这条路是怎么通的，以及 `cfi-shadow` 为什么存在）

---

## 1. 起点：这个 app 是什么，为什么以前起不来

它不是 `/usr/share/applications` 里的东西，那样会得出"这台设备没有相机 app"的错误结论；它是**预装的 click 包**：

```
/usr/share/click/preinstalled/camera.ubports/4.1.1/lomiri-camera-app
  app id: camera.ubports_camera_4.1.1
  .desktop Exec: lomiri-camera-app-migrate.py lomiri-camera-app --mode=barcode-reader %u
  lomiri-app-launch-appids 列得到它
```

从主机上把它拉起来的难点是三件不相干的事，之前逐一踩过（`scripts/device/zl1-camapp-launch.py` 头部记着）：

1. **它必须在容器 PID namespace 里**（相机这条路是 Android binder）；
2. **它要用会话自己的环境**（`HYBRIS_LD_LIBRARY_PATH`、`HYBRIS_LINKER=o`、`MIR_SOCKET`、`QT_QPA_PLATFORM=ubuntumirclient`），手搭一份就得到 `eglInitialize` 的断言 —— 所以 launcher 是读 `/proc/<shell pid>/environ`；
3. **它从当前目录找自己的包目录**（在 `/root` 起 → `Camera app directory "/root"` → `file:///root/qml/camera-app.qml: No such file or directory`），所以要先 `chdir` 进包。

补上这三条之后，卡点只剩一个，而且看着像平台问题：

```
ASSERT: "eglInitialize(mEglDisplay, nullptr, nullptr) == EGL_TRUE" in
        file ../../../src/ubuntumirclient/qmirclientintegration.cpp, line 150
```

崩溃现场（`crash-dump` 留的 maps）里是 **`libEGL_mesa.so.0` 而不是 `libEGL_libhybris.so.0`**，stderr 里还有四行 X11 的话 —— 一行也不该出现在一个 Mir 客户端里：

```
Authorization required, but no authorization protocol specified
```

顺手否掉一条"换条路走"的念头：**这台设备没有 wayland 的 QPA 插件**（`Available platform plugins are: eglfs, linuxfb, minimal, minimalegl, offscreen, mir1server, ubuntumirclient, vnc, xcb`）——`test_camera` 走 wayland 是因为它是**裸 EGL/Wayland 客户端**（`eglSwapBuffers(); wl_display_dispatch();`，`68` §4.2），不是 Qt app。Qt app 只有 `ubuntumirclient` 这一条路。

## 2. 先把 EGL 这一层量清楚

**这一层不是猜的**：`libEGL.so.1.1.0` 是个 **glvnd 分发器**（`nm -D` 里没有任何 EGL 实现，只有 `libGLdispatch.so.0`），它按 `/usr/share/glvnd/egl_vendor.d/` 里的 json 顺序找 provider，这里是 `10_libhybris.json` 和 `50_mesa.json`。把两个库拉到主机上读：

| 库 | 它是什么 | 关键事实 |
|---|---|---|
| `libEGL_libhybris.so.0` | libhybris 的 **glvnd ICD** | `nm -D` 只导出一个 `__egl_Main`：**它没有 `eglGetDisplay`**；它读 `EGL_PLATFORM`，然后 dlopen `/usr/lib/aarch64-linux-gnu/libhybris/eglplatform_<PLATFORM>.so` |
| `libEGL.so.1.1.0` | glvnd 分发器 | 谁提供 display 取决于它把调用交给哪个 vendor |
| `/usr/lib/aarch64-linux-gnu/libhybris/` | hybris 的平台模块 | `eglplatform_{fbdev,hwcomposer,null,wayland}.so` —— **没有 mir 模块**，而 `ubuntumirclient` 是个 Mir 客户端 |

**壳子不走 glvnd**。`lomiri` 的 maps 里有 `libEGL_libhybris.so.0.0.0`、`libEGL_adreno.so`、`eglplatform_null.so`，还有 `mir1/client-platform/android2.so.5` 和 `mir1/server-platform/graphics-android2.so.16`：**Mir 自己的平台插件直接 dlopen hybris 的 EGL**，绕过了 glvnd。所以"壳子能画"从来不证明"Qt 客户端能拿到 EGL"。

然后 `strace -f -e trace=openat` 把 app 那一侧的顺序摊开（不加任何额外 preload）：

```
openat("/usr/share/glvnd/egl_vendor.d/10_libhybris.json")  = 8
openat("/lib/aarch64-linux-gnu/libEGL_libhybris.so.0")     = 8      <- hybris 的 ICD 读到了
openat("/usr/share/glvnd/egl_vendor.d/50_mesa.json")       = 8
openat("/lib/aarch64-linux-gnu/libEGL_mesa.so.0")          = 8      <- 但 display 给了 Mesa
openat("/dev/dri", O_DIRECTORY)                            = -1 ENOENT
--- SIGABRT ---
```

`/dev/dri` 那一行是判决：**Mesa 在这台设备上不可能成功**（它要 DRM/GBM，而这台机器的 GPU 是 kgsl `/dev/kgsl-3d0`）。所以问题不是"Mesa 错了"，而是"为什么没轮到 hybris"。

## 3. 一个探针把问题缩到一行

`scripts/device/zl1-egl-probe.py`（新）把 qtmir 那段代码用 ctypes 复刻出来，不带 Qt、不带 app 跑：`mir_connect_sync()` → `mir_connection_get_egl_native_display()` → 这个值交给 glvnd 的 `eglGetDisplay()` → `eglInitialize()`。

先看到的是**没坏的那一半**：

```
Mir connection valid (MIR_SOCKET='/run/user/32011/mir_socket')
mir_connection_get_egl_native_display() = EGL_DEFAULT_DISPLAY (0)
libEGL.so.1  eglGetDisplay(EGL_DEFAULT_DISPLAY) = 0x1
             eglInitialize = 1 (1.4)
             vendor = Android            <- hybris 的 android EGL（Adreno）
             version = 1.4 Android META-EGL
```

也就是说：`EGL_PLATFORM` 不设、Mesa 也在列表里，glvnd **照样能选中 hybris 并初始化成功**。那 app 为什么不行？于是把 app 用的那组 preload 加到这个探针上 —— 差别只有这一个：

```
cfi-shadow-init[33976] loaded
cfi-shadow-init[33976] no android_dlopen/android_dlsym after this object -- not priming
libEGL.so.1  eglGetDisplay(EGL_DEFAULT_DISPLAY) = 0x33446c90
             eglInitialize = 0 (0.0)
```

**是 `libcfi-shadow-init.so`。** 同一个二进制、同一份环境，加它就失败、不加就成功；同一份 strace 也对着这个：加了它以后 `libEGL_libhybris.so.0` 后面**再也没有** `/android/system/lib64/libEGL.so`、`libEGL_adreno.so`、`eglplatform_null.so` —— hybris 的 EGL 停在半路，glvnd 只好退给 Mesa。

## 4. 根因：一条 `RTLD_NEXT` 解析 + 一个被缓存成"永远"的失败

`scripts/cfi-shadow/cfi-shadow-init.c` 的工作原理是**抢占 `android_dlopen`**（`libcamera.so.1` 从全局作用域拿到这个符号，于是拿到我们这份），第一次调用时把 bionic 的 CFI shadow 补上，然后把调用**转发给真身**（`real_dlopen`）。真身是这么找的：

```c
real_dlopen = (dlopen_fn)dlsym(RTLD_NEXT, "android_dlopen");
```

`RTLD_NEXT` 只在**本对象之后的全局作用域**里找。而 `libhybris-common.so.1` 可以只存在于**某个被 dlopen 进来的库的 local scope** 里 —— `libEGL_libhybris.so.0` 正是被 glvnd 的 `libEGL.so.1` dlopen 的，local scope 对 `RTLD_NEXT` 不可见。于是 `real_dlopen` 是 NULL，而 `android_dlopen()` 的转发是 `if (!real_dlopen) return NULL;` —— **这个进程里每一次 hybris dlopen 都返回 NULL**。更糟的是 `state` 无论成败都被置成"已处理"，所以这一次失败被缓存成永久。

为什么以前没炸：`test_camera` 把 `libcamera.so.1` 放在可执行文件的 `DT_NEEDED` 里，`libhybris-common` 因此在第一次调用之前就进了**全局**作用域，`RTLD_NEXT` 找得到。相机 app 是**后来**才通过 `libcamera_compat_layer` 载入 libcamera 的，那时这个 preload 已经把进程毒了。设备上的日志把两个人群分得干干净净：90 条 `shadow at 0x...`（`test_camera` 那批）对 13 条 `not priming`（相机 app 和本次所有探针）。

**修法**（`resolve_real()`）：先试 `RTLD_NEXT`（原来能work的地方行为不变），不成就回退到 `dlopen("libhybris-common.so.1", RTLD_NOW|RTLD_GLOBAL)` 从这个 handle 取两个符号，并把走了哪条路打进日志；`prime()` 改成返回成功与否，失败时把 `state` 置回 0 —— **"还没到时候"不能被缓存成"永远不行"**。

```
$ scripts/cfi-shadow/build.sh
    sha256 1b66341170fe7188b2e87f52cbde568432db99584c0b468fed52907097219056
    （旧: bec52da782a00bbbbcbdf51cb1069ce61aacaf978b46eb33005afb34dc3587be，
      设备上留成 libcfi-shadow-init.so.orig-20260923）
    DT_NEEDED 仍为空；dlopen 进了 undefined 列表（从 libc.so.6 解析）
```

修完的探针：`resolved android_dlopen via dlopen("libhybris-common.so.1") -- RTLD_NEXT could not see it` + `shadow at 0x...` + `vendor = Android / eglInitialize = 1`。

## 5. app 起来了 —— 而且必须以会话用户跑

修完之后的完整一次运行（`scripts/device/zl1-camapp-launch.py`，头部有用法）：

```
dropped to uid 32011 gid 32011
cfi-shadow-init[34254] resolved android_dlopen via dlopen(...)
Creating a QMirClientScreen now
Creating a QMirClientScreen now
Import path added ".../camera.ubports/4.1.1//./lib/aarch64-linux-gnu"
Camera app directory "/usr/share/click/preinstalled/camera.ubports/4.1.1"
Added camera "0"
Added camera "1"
** Application is now active
exit=124   （30 秒定时器到点时还活着）
```

**`ZL1_AS_UID=32011` 是必须的**，不是洁癖：以 root 跑会走到 `** (process:34068): ERROR **: Error connecting to unix:path=/run/user/32011/bus: The connection is closed` 然后 SIGTRAP —— 会话总线不接受 uid 不是 32011 的对端。所以 launcher 先以 root 读会话的环境和 runtime dir，**最后一步**再 `setgid/setuid` 到 32011。

`Added camera "0"` / `"1"` 说明这条路真的走到了摄像头枚举（`libcamera.so.1` → `libcamera_compat_layer.so` → cameraserver），不是停在 UI 上。

## 6. 还差什么（都在这一轮之外）

| 缺口 | 现状 |
|---|---|
| **屏上有没有** | 这一轮显示器一直关着（`ActiveOutputs (ii) 0 0`），也没在 app 活着的时候量合成器 CPU，所以 `68` §5 / `77` 那条判据（显示器 ON：没客户端 1.2 ticks/s，有预览 20–50）**没有用上**。要按那套来，得先开显示器（`68` §8 那两条 `busctl TurnOn/TurnOff`，可逆） |
| **预览出不出图** | 摄像头枚举到了，但**没有去找过一帧** |
| `/system/lib64/libui_compat_layer.so` | app 按**绝对路径**要它；`/android/system` 是 **ro 的 ext4（`/dev/loop1`）**，写不进去，shim 在 `/userdata/zl1-hybris/lib/` 只有基名能被 `HYBRIS_LD_LIBRARY_PATH` 找到。这一次它是 non-fatal（`m_surface is NULL, can't update video texture`） |
| media-hub 会话 | `No such object path '/com/lomiri/MediaHub/Service/sessions/0'`（快门声那条路），非致命 |
| 会话总线 | app 现在靠 launcher 直接给环境；正经的路是 `lomiri-app-launch`，它没成功过（这一轮也没再试） |

## 7. 设备状态：这一轮以 EDL 收尾

SSH 在主机内核时刻 2200800.5 停止应答，**主机自己的 kern.log** 把这次转变记在 zl1 一直在的那个口（3-3，RNDIS 那个 gadget）：

```
[2195387.8] rndis_host 3-3:1.0 usb0: unregister ... RNDIS device
[2195388.9] rndis_host 3-3:1.0 usb0: register ... , 52:d0:92:1c:83:b6
[2195607.8] rndis_host 3-3:1.0 usb0: unregister ... RNDIS device
[2195609.9] rndis_host 3-3:1.0 usb0: register ... , 86:e0:d0:fb:61:33
[2200800.5] usb 3-3: USB disconnect, device number 114
[2200802.2] usb 3-3: New USB device found, idVendor=05c6, idProduct=9008, bcdDevice= 0.00
            Product: QUSB__BULK, SerialNumber=0
[2200802.2] qcserial 3-3:1.0: Qualcomm USB modem converter now attached to ttyUSB2
```

`05c6:9008` / `QUSB__BULK` 是 **Qualcomm EDL**；它在这个口上稳定挂了 80 秒以上、没有序列号。这一轮**没有写任何分区、没有碰 boot 镜像、没有动 modem/radio 分区，也没有跑任何 EDL/QDL/QFIL 工具**（这是本项目的底线）。**归因没有做**：相机 app 在两分钟前还在跑（会话用户、容器里开着相机那条路），在那之前设备自己把 RNDIS gadget 重新枚举过两次，而 SoC 也可以因为固件侧不恢复的故障直接落到 EDL（`zl1` 上"secure world 的 `scm_call` 失败、PIL 固件全下不来"那种记录就在这条线上）。**记成一次未解释的转变，不写成诊断。**

设备要离开 EDL 需要**手动复位**（长按电源键）——不经过 QDL loader 的软件路子没有，而 QDL 是本项目明令不用的。这一侧没有跑任何 EDL 工具。

**这不是第一次，而且上次是靠手复位回来的**：[`49`](49-two-cores-that-are-not-tls-wifi-stuck-at-wcnss-and-a-trip-into-edl.md) §5 记着同一副面孔（`05c6:9008`、同一口 3-3、`18d1:` 从总线上消失、SSH 断），那次的触发是 `cnss` 平台驱动的 unbind（PCIe link down → SoC 级 crash-dump 路径 → EDL），恢复方式是**长按电源键 10–20 秒硬复位**，回来以后设备重新以 `18d1:d001`（RNDIS）出现。那次的教训是"在这台 zl1 上不要 unbind `cnss`/`cnss_pci`"；这一次没有碰过驱动、Wi-Fi 或任何平台设备，所以**触发条件不同，只共用"msm8996 上某些 SoC 级故障的终点就是 EDL"这一条**。恢复后的自检照 `49` §6：RNDIS 回来、`grep -qa msm8996 /proc/device-tree/compatible`、`adb devices` 里不该有 `33e80afe`。

## 8. 复现

```bash
A=$(ssh root@10.15.19.82 'lxc-info -n android -pH'); P=$(ssh root@10.15.19.82 'pgrep -x lomiri | head -1')
scp scripts/device/zl1-camapp-launch.py scripts/device/zl1-egl-probe.py root@10.15.19.82:/tmp/

# 相机 app（会话用户、容器 PID namespace、两个 preload）
ssh root@10.15.19.82 "nsenter -t $A -p -- env ZL1_AS_UID=32011 \
  ZL1_PRELOAD_EXTRA='/userdata/zl1-hybris/lib/libcfi-shadow-init.so /userdata/zl1-hybris/lib/crash-dump.so' \
  python3 /tmp/zl1-camapp-launch.py \
    /usr/share/click/preinstalled/camera.ubports/4.1.1/lomiri-camera-app \
    camera.ubports_camera_4.1.1 /usr/share/click/preinstalled/camera.ubports/4.1.1 $P"

# EGL 那一层单独量（不带 Qt、不带 app）
ssh root@10.15.19.82 "nsenter -t $A -p -- python3 /tmp/zl1-camapp-launch.py \
  /usr/bin/python3 zl1-egl-probe /tmp $P /tmp/zl1-egl-probe.py"

# cfi-shadow 重新构建（改过 cfi-shadow-init.c 之后）
scripts/cfi-shadow/build.sh
```

| 文件 | 作用 |
|---|---|
| `scripts/device/zl1-camapp-launch.py` | 新增。用**运行中会话自己的环境**起一个 app（读 `/proc/<pid>/environ`），可选 `ZL1_SET_<NAME>=<value>` 逐项覆盖、`ZL1_PRELOAD_EXTRA` 追加 preload、`ZL1_AS_UID` 最后一步降到会话用户、`chdir` 进包目录；`argv[5:]` 透传给目标（探针就是这么跑的） |
| `scripts/device/zl1-egl-probe.py` | 新增。把 qtmir 的 EGL 初始化用 ctypes 复刻：直接看 hybris 的 ICD 是什么、glvnd 的默认 display 归谁、`mir_connection_get_egl_native_display()` 到底返回什么、以及带/不带 preload 的差别。**不含 Qt、不含 app** —— 这是把"平台坏了"和"这个 app 坏了"分开的东西 |
| `scripts/cfi-shadow/cfi-shadow-init.c` | 修：`resolve_real()`（`RTLD_NEXT` + `dlopen("libhybris-common.so.1")` 回退）与失败不缓存 |
| `docs/ubuntu-touch/evidence/camera-app-starts-2026-09-23.log` | 同一份证据：崩溃现场、两个 maps、strace 对照、探针输出、app 运行日志、主机 kern.log 的 EDL 转变 |

## 9. 这一轮**不**证明什么

* **不证明 app 的窗口到了屏上**（§6）：显示器全程关着，合成器 CPU 没量，没有截图。
* **不证明预览出图**：只证到"两个摄像头被枚举到"。
* **不证明 `cfi-shadow` 的修复对 `test_camera` 没有回归**：那条路这一轮没有再跑（它的判据是 `Started camera preview.` + 合成器 CPU，`65`/`68`）。
* **不证明 EDL 的成因**（§7）：只证明它发生了、发生在这个口上、以及这一侧没碰过任何分区或 EDL 工具。
* 没有重启、没有分区写、没有改 `boot`；写过的只有 `/userdata/`（launcher、探针、日志、修好的 `libcfi-shadow-init.so` 及其 `.orig-20260923` 备份）和 `/tmp`。
