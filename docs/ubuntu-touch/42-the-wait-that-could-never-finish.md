# 42 — 屏幕点不亮（三）：一个永远等不到的属性

**日期**: 2026-09-21
**状态**: compositor 不再「一启动就死」，而是「启动后永远卡住」；卡住的**那一行**已经用 core + gdb 逐帧读出来了，并用一个 4 字节补丁绕过。`libui_compat_layer.so` 已经能自己编出来。阻塞推进到第三个：`libhwc2_compat_layer.so`。
**接续**: [`40`](40-the-display-died-below-lomiri.md)（崩在哪条指令）、[`41`](41-bionic-tls-slot-is-never-filled.md)（为什么会崩）

---

## 1. 一句话

把 `libui_compat_layer.so` 补上之后，`lomiri-system-compositor` 不再被 SIGSEGV 杀掉，而是**停在第 6 秒**
不动了。core dump 的栈是：

```
mir::Server::run()
  → mir::DefaultServerConfiguration::the_graphics_platform()
  → create_host_platform()                      [graphics-android2 平台插件]
  → libEGL_libhybris 的 eglInitialize
  → android::egl_display_t::initialize()        [Android libEGL]
  → configstore::get<…ISurfaceFlingerConfigs::hasWideColorDisplay>()
  → hardware::details::getRawServiceInternal()
  → hardware::defaultServiceManager1_1()
  → hardware::waitForHwServiceManager()         ← 这里
  → android::base::WaitForProperty(…)           [libbase]
  → SystemProperties::Wait(…)                   [bionic libc]
  → syscall(__NR_futex, FUTEX_WAIT, …)          ← 永远
```

`WaitForProperty` 等的是属性 **`hwservicemanager.ready`**，而这个属性在这台设备上**从来没被设过**，
`waitForHwServiceManager()` 又是一个没有上界的重试循环。宿主进程里没有任何办法让它成功，
所以它只会一直等下去。

## 2. 症状变了，但看起来还是很像

现象是 lightdm 每 60 秒重启一次 compositor：

```
[+0.04s] DEBUG: Unity System Compositor: Waiting for system compositor for 60s
[+0.04s] DEBUG: Launching process …: /usr/share/ubuntu-touch-session/lsc-wrapper …
（60 秒后）
```

compositor 自己一直在 `futex_wait_queue_me` 上，日志停在
`mirserver: Selected driver: ubports:android2`，**没有任何错误**。`[41]` 里那种 0.44 秒被 SIGSEGV
的痕迹没有了 —— 这正是「换了一个阻塞点」的样子。

## 3. 给一个「不崩溃」的进程留一份 core

崩溃会自己留下 core，卡死不会。所以 `hybris-crash-hunt.sh` 增加了 `--from-pid`：
`SIGABRT` 一个正在跑的进程，强制内核写 core，之后的分析完全一样。

两个坑（都已写进脚本）：

- **`RLIMIT_CORE` 属于被杀的进程，不属于你手上的 shell。** systemd → lightdm →
  compositor 这条链的 core 上限是 0，`kill -ABRT` 之后什么都不会产生，而
  `ls -t core.*` 会慷慨地递给你**上一轮**的 core。那份 core 分析得漂漂亮亮，
  但和这次毫无关系——第一次跑就踩了这个。所以脚本现在先 `prlimit --pid … --core=unlimited`，
  并且核对产出的 core 名字必须是 `core.<comm>.<pid>`，否则直接失败退出。
- **NT_FILE 里的偏移不是 vaddr 减去映射起点。** 只有当覆盖文件开头的那个映射的
  `p_vaddr == 0` 时才成立。`libc.so` 是这样，`libhidltransport.so` **不是**
  （第一个 LOAD：文件偏移 0、vaddr `0xa000`）。算错时模块名还是对的、偏移小了一个
  `p_vaddr`，于是符号化到一个毫不相干的函数或者干脆是一片乱码——两次解析结果天差地别，
  差别只在这个加法。脚本现在从 NT_FILE 求出文件偏移，再走该文件自己的 program headers。
  （`[40]`/`[41]` 的结论没受影响：那些地址都落在 `libc.so` 里，而它的首个 LOAD 的
  `p_vaddr` 就是 0。）

```sh
scripts/hybris-crash-hunt.sh --from-pid $(pgrep -f '^lomiri-system-compositor' | head -1)
```

## 4. 为什么这个等待永远完不了

### 4.1 属性确实不存在

`/dev/__properties__/` 是 Android 属性和宿主进程共享的（见 `[40]` §6）。用**真正的**
getprop 读：

```
$ /usr/bin/getprop.orig-zl1 init.svc.hwservicemanager
running                       ← 容器在跑，hwservicemanager 活着
$ /usr/bin/getprop.orig-zl1 hwservicemanager.ready
                              ← 空
$ /usr/bin/getprop.orig-zl1 | wc -l
659                           ← 属性区是好的，宿主进程读得到
```

在属性文件里直接找也找不到这个名字：

```
$ grep -rl "hwservicemanager.ready" /dev/__properties__/
（无输出）
```

### 4.2 容器的属性服务不接收写入

`hwservicemanager` 启动时会 `property_set("hwservicemanager.ready", "true")`
（`system/hwservicemanager/service.cpp:68`）。它没成功。在容器里用 **Android 自己的**
`/system/bin/setprop`（不是宿主那个，见 §5）试：

```
lxc-attach -n android -- /system/bin/setprop hwservicemanager.ready true
setprop: failed to set property 'hwservicemanager.ready' to 'true'
```

`debug.zl1test`、`persist.sys.zl1test` 一样失败 —— 不是这一个属性的问题，
是容器的 property service 整体不接收写入。这一层为什么坏，本次没有继续往下挖：
它是 Android 容器自己的事，而**宿主进程等不到这个属性这件事本身，不依赖它坏在哪**。

### 4.3 libhybris 在这里不会来救场

libhybris 本来有一整套属性 hook（`hybris/common/hooks.c` 的 `hooks_properties`），
其中 `__system_property_find` 的版本是**永远返回 NULL**。但它被有意跳过：

```c
// make sure to skip the property hooks only when o.so is actually loaded
// The o linker is loaded when sdk_version >= 27 and exists.
if (!found && sdk_version < 27)
    found = bsearch(&key, hooks_properties, …);
```

本机 SDK 28，所以真正跑的是 Android libc 里那份 `__system_property_find`。core 也印证了这一点：
futex 的地址是 `/dev/__properties__/properties_serial` 偏移 4，也就是**属性区的全局 serial** ——
bionic 只在 `pi == nullptr`（没找到属性）时才会等到那个字上。

## 5. 修法：把那一句 `waitForHwServiceManager()` 变成 `ret`

`scripts/hybris-shims/` 会复制一份设备的 `/android/system/lib64/libhidltransport.so`，
**只改 4 个字节**：

```
_ZN7android8hardware23waitForHwServiceManagerEv  vaddr 0x2aadc
  文件偏移 0x2adc 处  ff 03 03 d1  (sub sp, sp, #0xc0)   →   c0 03 5f d6  (ret)
```

然后把这份副本放进 `/userdata/zl1-hybris/lib/`，并让 compositor 的
`HYBRIS_LD_LIBRARY_PATH` 把那个目录排在 `/system/lib64` **前面** ——
Android linker 按 soname 找到的就是这一份。没有写任何分区，`system.img` 原封不动。

**为什么是补丁而不是别的**：

- **注册 `hybris_set_hook_callback` 自己实现属性函数**：能行，但回调是**按符号**注册的，
  不是按调用。一旦接管 `__system_property_find`，就必须对所有属性名都给出行为，
  包括转发给真正的 bionic 实现——那要在一层层 hook 里绕回来，比 4 个字节复杂得多，
  也更容易错。
- **把属性写进属性区**：最"正确"，但属性区是 read-only 映射，写进去等于重新实现
  Android 的属性分配逻辑（`prop_info` 布局、count、全局 serial 与 futex 唤醒）。
- 补丁的语义也恰好是对的：`waitForHwServiceManager()` **只负责等**，它不等了，
  后面的 `getService()` 就会快速失败，而调用方本来就处理"服务不存在"这条路径
  （Android 各 HAL 的 client 都按 optional 处理）。宿主进程里那个等待**没有成功分支**，
  所以跳过它不改变任何一条能走通的路。

效果（`mirserver` 日志）：

```
[info] No device yaml config found!
<information> android/server: Error opening HWC HAL. Assuming HWComposer 2 device with libhwc2_compat_layer.
library "libhwc2_compat_layer.so" not found
```

`eglInitialize` 过去了（耗时约 6 秒，是那次 HIDL 查找失败的代价），接着进到了
hwcomposer 的初始化。

## 6. 顺带发现：本机的 `getprop`/`setprop` 是假的

`/usr/bin/getprop` 和 `/usr/bin/setprop` 在本机是**两个 1352 字节的 shell 脚本**，
由 v63 的 `zl1-postswitch-debug-init` 在每次启动时装上去的（原始二进制被留在
`/usr/bin/*.orig-zl1`）。它们把几个 `ro.*` 硬编码，其余全部打印默认值，
`setprop` 是空操作。

也就是说：**从装了 v63 调试镜像起，在这台设备上敲 `getprop xxx` 得到的都不是真实属性。**
本次最开始就被它骗过一次（`getprop hwservicemanager.ready` 返回空、`getprop | wc -l` 返回 0，
两个都毫无意义）。

真实的读法是原始二进制 + TLS 垫片（`[41]` 的那个，它自己不预加载就会 SIGSEGV）：

```sh
LD_PRELOAD=/usr/lib/aarch64-linux-gnu/libtls-padding.so /usr/bin/getprop.orig-zl1 <name>
```

写属性则没有宿主侧的路，只能在容器里用 `/system/bin/setprop`（而它现在是坏的，见 §4.2）。

## 7. 现在这条链子

| # | 阻塞 | 状态 |
| --- | --- | --- |
| 1 | `lomiri-system-compositor` 在 0.44 秒被 SIGSEGV | 已解（`[41]` 的 TLS 槽垫片） |
| 2 | Mir 的 android2 平台 `library "libui_compat_layer.so" not found` | 已解（`scripts/hybris-shims/` 自己编一份） |
| 3 | `eglInitialize` 里 `hwservicemanager.ready` 死等 | 已解（4 字节补丁） |
| 4 | **`library "libhwc2_compat_layer.so" not found`** | **当前** |

第 4 个和 `libui_compat_layer.so` 是同一类东西：Halium 侧、由设备的 Android 构建产出的库，
原厂 LeEco 镜像里没有。源码在 `halium/libhybris/compat/hwc2/`。难度明显更高：
它要 `hardware/interfaces/graphics/composer/2.1/utils/command-buffer/` 下那批
**由 hidl-gen 生成**的头文件，而 `[41]` 那种「用预编译 clang 单编一个 .cpp」的做法
覆盖不到生成步骤。

另外那句 `Error opening HWC HAL` 本身是**预期**的：这台设备的 HWC 是
`/vendor/lib64/hw/hwcomposer.msm8996.so` 这种 legacy HWC2 **模块**，不是 HIDL
`android.hardware.graphics.composer@2.1` 服务，所以 Mir 走 fallback 路径是对的 ——
fallback 缺的正是第 4 项。

## 8. 还没证实什么

- `libhwc2_compat_layer.so` 是不是**唯一**剩下的阻塞。现在是最大嫌疑，不是结论。
- 屏幕仍然不亮：`/sys/class/leds/lcd-backlight/brightness` 还是 0。
  现在的状态是「compositor 能走到 hwcomposer 初始化然后失败退出」，不是「compositor 在工作」。
- 补丁的副作用没有测全。它影响**所有**走 libhybris 的宿主进程里的 HIDL 查找；
  现在能观察到的是 compositor 这条路变好了，别的没测。
- 容器的属性服务为什么不接收写入，没查。
- 为什么别的 Halium 9 端口不卡在这里。`[41]` 留下的那个问题在这一篇里也没答案。
