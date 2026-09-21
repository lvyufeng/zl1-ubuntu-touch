# 40 — 屏幕点不亮：崩在 libhybris 的 Android 运行时，不在 Lomiri

**日期**: 2026-09-21
**状态**: 根因定位到**指令级**。修法还没有。
**用途**: Phase 5「显示」的第一份诊断。它推翻了"这是 lightdm / Lomiri 的配置问题"这个直觉。

---

## 1. 先说结论

屏幕不亮，不是 Lomiri 没配好，也不是 lightdm 的 session 写错了。**是 libhybris 的 Android 运行时在宿进程里崩了。**

三条独立证据：

1. **lightdm 为什么失败**: `lightdm` 起 `lsc-wrapper`，后者 exec
   `lomiri-system-compositor`。compositor 在 **0.44 秒**时被 SIGSEGV 杀死，
   lightdm 于是重试 5 次、`Start request repeated too quickly`、`failed`。
   `unity-system-compositor.log` 的最后一行就是这个：

   ```
   [+0.10s] DEBUG: Launching process 46269: /usr/share/ubuntu-touch-session/lsc-wrapper ...
   [+0.44s] DEBUG: Process 46269 terminated with signal 11
   ```

   Mir 的日志停在"加载完 `graphics-android2.so.16` 和 `input-evdev.so.7`"——
   平台插件刚被 dlopen，实例化还没开始就死了。

2. **上游 libhybris 的最小测试同样崩**。这不是 Mir 的问题，因为不经过 Mir 也崩：

   | 测试 | 结果 |
   | --- | --- |
   | `test_dlopen` | rc=0，正常输出 |
   | `getprop ro.hardware` | rc=0，`qcom` |
   | `test_hwcomposer` | **rc=139（SIGSEGV），无任何输出** |
   | `test_egl` | **rc=139** |
   | `test_glesv2` | **rc=139** |
   | `test_lights` | **rc=139** |

   `test_hwcomposer` 是 upstream 的一个几十行的自检程序。它崩了，说明**宿进程里任何
   走 Android 图形栈的调用都活不下来**，与 Lomiri、与 lightdm、与 session 文件都无关。

3. **崩在哪条指令上**（core dump + `gdb-multiarch`，方法见 §6）：

   ```
   pc  = 0x7cf04ad358   = Android libc.so  __ctype_get_mb_cur_max + 8
   x8  = 0
   si_addr = 0xb00
   ```

   `0xb00 = 2816`，正是那条指令的立即数，也就是说 **x8 是 0，做了一次 NULL+2816 的读**。

## 2. 完整的调用链

frame pointer 手工往上走（core 里没有 CFI，`bt` 走不动），
`scripts/hybris-crash-hunt.sh` 会把每个返回地址落到「模块 + 偏移」上：

```
pc       0x…d358  /android/system/lib64/libc.so                   +0x2b358   ← 崩在这
lr       0x…85b0  /android/system/lib64/libc++.so                  +0x955b0
frame0   0x…da50  /android/system/lib64/libc++.so                  +0x6aa50
frame1   0x…d5c0  /android/system/lib64/libc++.so                  +0x6a5c0
frame2   0x…d1ac  /android/system/lib64/libc++.so                  +0x3a1ac
frame3   0x…1278  /usr/lib/aarch64-linux-gnu/libhybris/linker/o.so +0x21278
frame4   0x…139c  /usr/lib/aarch64-linux-gnu/libhybris/linker/o.so +0x2139c
frame5   0x…7e58  /usr/lib/aarch64-linux-gnu/libhybris/linker/o.so +0x27e58
frame6-8 0x…7d08  /usr/lib/aarch64-linux-gnu/libhybris/linker/o.so +0x27d08   ← 同一个地址出现三次
frame9   0x…7b6c  /usr/lib/aarch64-linux-gnu/libhybris/linker/o.so +0x17b6c
frame10  0x…84b4  /usr/lib/aarch64-linux-gnu/libhybris/linker/o.so +0x184b4
frame11  0x…06b4  /usr/lib/aarch64-linux-gnu/libhardware.so.2.0.0  +0x6b4
frame12  0x…20a4  /usr/bin/test_hwcomposer                        +0x30a4
frame13  0x…84c4  /usr/lib/aarch64-linux-gnu/libc.so.6             +0x284c4
frame15  0x…2b70  /usr/bin/test_hwcomposer                        +0x3b70   ← __libc_start_main
```

读法（由内向外）：glibc 侧的 libhybris 包装 `libhardware.so.2.0.0` →
libhybris 的 Android linker 插件 `o.so` → Android `libc++.so`
（`std::__1::locale::__imp::__imp(unsigned long)`，`lr` 处的符号已核对）
→ Android `libc.so` 的 `__ctype_get_mb_cur_max` → 崩。

`o.so` 里同一个返回地址连着出现三次（frame6/7/8），说明那里是一段递归。

顺带：`libc.so` 里紧邻的 `uselocale` 用的是**一模一样**的开头三条指令
（`mrs` / `ldr x8,[x8,#8]` / `ldr x9,[x8,#2816]`），交叉印证了 2816 这个偏移的含义。

反汇编（`__ctype_get_mb_cur_max` 共 60 字节）：

```asm
__ctype_get_mb_cur_max:
    mrs  x8, tpidr_el0          ; x8 = 线程指针
    ldr  x8, [x8, #8]           ; x8 = TLS[1]  = TLS_SLOT_THREAD_ID
    ldr  x8, [x8, #2816]        ; <-- 崩在这里，x8 == 0
    ldr  x8, [x8]
    ...
```

`2816` 不是随便一个数：libhybris 自己 vendor 了一份 bionic 头文件，
`pthread_internal.h` 里 `pthread_internal_t` 的**最后一个成员**就是
`struct bionic_tls* bionic_tls;`，而 bionic 的取值方式是

```cpp
static inline pthread_internal_t* __get_thread() {
  void** tls = __get_tls();                       // 就是 TP
  if (tls) return (pthread_internal_t*) tls[TLS_SLOT_THREAD_ID];
  return nullptr;
}
static inline bionic_tls& __get_bionic_tls() {
  return *__get_thread()->bionic_tls;             // __get_thread() 是 NULL 时就是 0+2816
}
```

`TLS_SLOT_THREAD_ID == 1`，在 aarch64 上就是 `TP + 8`。

**所以：崩溃的直接含义是 `*(TP+8) == 0`，也就是 bionic 的"当前线程"槽位在宿进程里
没有被建立。** 在 glibc 宿进程里 TP 是 glibc 的 TCB，bionic 的那套槽位本来就没人填。

libhybris 并不打算 hook 掉这类函数——已核对 installed 的
`libhybris-common.so.1.0.0`：它 hook 了 `newlocale` / `freelocale` / `duplocale` /
`uselocale` / `localeconv` / `setlocale`，**但没有** `__ctype_get_mb_cur_max`
（整个 .so 里没有 `ctype`、`mb_cur_max` 这些字符串）。

而 linker 插件 `o.so` 里唯一会建立主线程 TLS 的地方是 `__linker_init()`，它调
`__libc_init_main_thread(args)`——**这段代码被 `#ifdef DISABLED_FOR_HYBRIS_SUPPORT`
整个关掉了**（`hybris/common/o/linker_main.cpp`）。导出的
`android_linker_init()` 只做 LD_LIBRARY_PATH、`set_application_target_sdk_version`
和命名空间初始化，**不建 TLS**。

## 3. 试过、并且都无效的

排错的价值一半在"排掉了什么"：

| 假设 | 结果 |
| --- | --- |
| `LD_PRELOAD=libtls-padding.so` 就能修 | **无效**，仍然 139（相对路径和全路径都试了） |
| SDK 版本号认错了，导致选错 linker | **无效**。`HYBRIS_ANDROID_SDK_VERSION` 试 26/27/28/29/30/33 全崩 |
| 宿主看到的是"另一份陈旧的属性区" | **排除**。宿主与容器看到的是**同一个 tmpfs**：`property_info` 两边 `dev=17 ino=44605`，目录 `ino=40730`。`/dev/__properties__` 里 165 个文件，齐全 |
| 属性区损坏导致 bionic 属性代码崩 | **不是崩点**。崩在 TLS，不在属性 |
| linker 变体选错 | 顺带测出了规则：**sdk ≤ 28 → `o.so`，sdk ≥ 29 → `q.so`**。两种都崩 |

顺带说明：`libtls-padding.so` 确实是个 TLS 垫片（它的 `PT_TLS` 段
`memsz=0x80`，导出 `tls_padding` 128 字节），但把它预加载进来并不能救这个崩溃。

## 4. 一条独立的、也还没解释的观察

libhybris 自带的 `getprop`（走的是 libhybris 自己的属性实现，**根本不加载任何
Android .so**，所以它从不崩）读同一批属性时表现不一致：

```
ro.build.version.sdk             [28]        ← 读得到
ro.hardware                      [qcom]      ← 读得到
ro.product.name                  [ZL1_CN]    ← 读得到
ro.build.version.release         []          ← 空
ro.vndk.lite                     []          ← 空（容器里 getprop 是 true）
ro.build.version.security_patch  []          ← 空
```

后果之一是 Android linker 去开 `/system/etc/ld.config.txt`；而本机是 **VNDK-lite**
镜像（`/system/etc/` 里只有 `ld.config.vndk_lite.txt`），所以那次 open 是 ENOENT：

```
openat(AT_FDCWD, "/system/etc/ld.config.txt", O_RDONLY|O_NOFOLLOW|O_CLOEXEC) = -1 ENOENT
```

这条目前只是记下来，**没有证据说它就是崩因**（崩的是 TLS，不是配置解析）。

## 5. 顺带排除的两个"看起来像"的方向

- **`/dev/dri` 不存在**不是问题。UT 在 Halium 上本来就是走 `graphics-android2`
  （hybris → 容器里的 hwcomposer），不是走 DRM/KMS。容器里的
  `surfaceflinger`、`android.hardware.graphics.composer`、`gralloc` 进程**都在跑**，
  `/dev/fb0` 也在。缺的是宿进程侧那条 hybris 通路。
- **Lomiri 装没装**不是问题。`lomiri`、`ciborium`、`liblomiri-api0`、
  `deviceinfo-tools` 都装好了；问题在它之前。

## 6. 复现方法（可复用）

`scripts/hybris-crash-hunt.sh` 把整套流程做成了一个脚本：设 `core_pattern` →
跑指定的 hybris 测试拿到 core → 从 core 的 `NT_FILE` 里读出所有被映射的文件路径 →
按原路径拉一份 sysroot → `gdb-multiarch` 报出崩溃点、反汇编和调用链。

依赖：宿主装 `gdb-multiarch`（`apt install gdb-multiarch`）。设备侧不需要编译任何东西——
`strace` 是设备上现成的，core 由内核写。

为什么这值得固化成脚本：这次的结论**全**来自"core + 符号 + 反汇编"，而在此之前
三轮猜测（属性区、linker 变体、padding）全部落空。

## 7. 还没证实什么

- **为什么别的 Halium 9 端口不这样崩。** 这是最大的空白。候选解释，按可信度排：
  1. **本机那份 libhybris 不是 ubports/libhybris 的产物**。installed 的
     `libhybris-common.so.1.0.0` 里有 `MEOW_get_tls_meow_offset` 和
     `_hybris_hook___tls_get_addr`，而 `ubports/libhybris` 的**全部 22 个分支、
     全部历史**里搜不到 "MEOW" 这个词（也没有 `0cedf90` 这个 commit）。
     也就是说安装的那份来自**另一棵带补丁的源码树**，而那个补丁几乎可以肯定就是
     和 bionic TLS 有关的那段。**下一步应该是拿到 Ubuntu/UBports 的 libhybris
     源码包，读那段补丁，看它为什么在这里没生效。**
  2. `/etc/ld.so.preload` **不存在**。`lsc-wrapper` 里写着这个垫片"必须预加载"。
     但显式 `LD_PRELOAD` 也救不了，所以这条要么不是原因，要么"预加载"的生效条件
     比 `LD_PRELOAD` 更苛刻。
  3. 我们用的是一个**原厂 stock Android 9 `system.img`**（`ro.build.id=PKQ1.181007.001`，
     `ZL1_CN`），不是 Halium 自己构建的 Android 系统镜像。如果 Halium 的镜像对
     bionic 打过补丁，这就能解释全部现象。
- §4 那条属性读不全的现象本身也还没解释。
- **这不等于"永远点不亮"**，只等于"当前这条路径必然崩"。下一步要么找到那段 TLS
  建立代码不生效的原因，要么绕过它。
