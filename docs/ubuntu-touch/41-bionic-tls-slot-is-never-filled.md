# 41 — 屏幕点不亮（二）：bionic 的线程槽从来没人填

**日期**: 2026-09-21
**状态**: 根因**已定位并已用实验修好**；`lightdm` 从 `failed` 变成 `active`，`lomiri-system-compositor` 不再在 0.44 秒被杀。修法是一个**运行时**的 `LD_PRELOAD` 垫片（本文给全部命令）。下一个阻塞已经暴露：Android 镜像里缺 `libui_compat_layer.so`。
**接续**: [`40-the-display-died-below-lomiri.md`](40-the-display-died-below-lomiri.md)（那一篇把崩溃定位到指令；这一篇给出解释和修法）

---

## 1. 一句话

`__get_bionic_tls()` 读的是 **`TP + 8`**（bionic 的 `TLS_SLOT_THREAD_ID`，slot 1）。
在 **aarch64 glibc** 上，`TP + 8` 是 `tcbhead_t::private` —— **一个 glibc 自己从不写、也从不读的成员**。

```
aarch64 glibc:  struct { dtv_t *dtv; void *private; } tcbhead_t;   /* sysdeps/aarch64/nptl/tls.h */
                TP+0  = dtv        ← glibc 用
                TP+8  = private    ← glibc 不用   = bionic slot 1
                TP+16 = 静态 TLS 块的第一块        = bionic slot 2（撞车，UBports 0022 就是为它写的）
```

所以在 glibc 宿主进程里，**bionic 的"当前线程"槽永远是 0**，`__get_thread()` 返回 NULL，
`*__get_thread()->bionic_tls` 就是 `0 + 2816 = 0xb00` —— 正好是 core dump 里的 `si_addr`。

而唯一会填写这个槽的代码是 bionic 的 `__libc_init_main_thread()`，它住在 **Android 的 linker** 里；
libhybris 的 linker 插件把 `__linker_init()`（唯一调用它的地方）整个 `#ifdef DISABLED_FOR_HYBRIS_SUPPORT` 掉了。
[`40`](40-the-display-died-below-lomiri.md) 里说"o.so 不建 TLS"，这一篇把**为什么这台设备上必然崩**补齐了。

## 2. 三条证据

### 2.1 设备上直接量：`TP+8 == 0`

设备上有 python3，于是可以在**宿主进程里**执行几条机器码来读寄存器（不需要编译器）：

```python
# mmap 一段 RWX，写入： mrs x0, tpidr_el0 ; ldr x0, [x0, #8] ; ret
p = libc.mmap(None, 4096, 7, 0x22, -1, 0)
ctypes.memmove(p, bytes.fromhex("40d03bd5" "000440f9" "c0035fd6"), 12)
tp8 = ctypes.CFUNCTYPE(ctypes.c_uint64)(p)()
```

结果（普通 python3 进程，与 libhybris 无关）：

```
TP       = 0x7491600e60
*(TP+8)  = 0x0            ← 空的
*(TP+0)  = TP + 0x770     ← glibc 的 dtv 在这里
*(TP+16) = 0
*(TP+32) = 0x0000007bfa831350
```

也就是说 `TP+8` 在该进程里就是 0，而 glibc 没有任何事 —— 因为它不用这个成员。

### 2.2 glibc 的布局文档与 UBports 自己的补丁都这么说

- glibc 2.39 `sysdeps/aarch64/nptl/tls.h`：`TLS_DTV_AT_TP=1`，`tcbhead_t` **只有两个成员** `{dtv; private;}`。
- UBports 打包补丁 `0022-linker-q-move-DTV-pointer-out-of-raw-TLS-slot-into-l.patch` 的提交信息里写着：

  > Storing the bionic DTV pointer in TLS_SLOT_DTV writes to a fixed offset from the glibc thread
  > pointer (**tp+16 for slot 2 on arm64**), which is where glibc places the first static TLS block.

  他们为 **slot 2 撞车** 打了补丁，而 **slot 1 一直空着没人管**。

### 2.3 反汇编：填槽的那条指令根本不在这台设备上

- `pc = /android/system/lib64/libc.so!__ctype_get_mb_cur_max+8`，指令 `ldr x8, [x8, #2816]`，`si_addr = 0xb00` ⇒ 上一句 `ldr x8, [x8, #8]` 读到的是 0。
- 扫描**所有被映射的库**里的 `tpidr_el0` 访问：

  | 文件 | `mrs tpidr_el0`（读） | `msr tpidr_el0`（写） |
  | --- | --- | --- |
  | `/android/system/lib64/libc.so` | 610 | **0** |
  | `/android/system/lib64/libc++.so` | 370 | **0** |
  | `/usr/lib/aarch64-linux-gnu/libhybris/linker/o.so` | 9 | **0** |
  | `/usr/lib/aarch64-linux-gnu/libhybris-common.so.1.0.0` | 1 | **0** |
  | `/android/system/bin/linker64`（真正的 Android linker） | 630 | **1** |

  **"设 TP" 的代码只存在于真正的 linker64 里**。libhybris 的 `o.so` 是同源代码编出来的宿主版，
  但 `__linker_init()`（其中才有 `__libc_init_main_thread(args)`，见 `hybris/common/o/linker_main.cpp:621`）
  被 `#ifdef DISABLED_FOR_HYBRIS_SUPPORT` 关掉了，所以 `msr` 也被编掉了。

> 顺带：`libtls-padding.so` 的说明文字（写在 `lsc-wrapper` 里）说
> "the TLS area clobbered by the Bionic libc … reserves some space for Bionic libc to clobber"
> —— 它管的是 **slot 2**（TP+16，glibc 静态 TLS 的第一块）。**slot 1 没有任何人在管**。

## 3. 修法（已验证）

造一个 `libtls-padding.so` 的**超集**：保留原来那 128 字节的 TLS 垫片，另外在构造函数里
把 `TP+8` 填成一个零填充的假 `pthread_internal_t`：

```c
__thread char tls_padding[128] __attribute__((tls_model("initial-exec"), used, visibility("default")));
static char fake_thread[2816 + 8];   /* pthread_internal_t::bionic_tls 在 +2816 */
static char fake_bionic_tls[4096];   /* bionic_tls::locale 在 +0，全零 ⇒ NULL */

__attribute__((constructor)) static void tlsfix_init(void) {
    void **tp; __asm__ volatile("mrs %0, tpidr_el0" : "=r"(tp));
    if (!tp || tp[1]) return;
    *(void **)(fake_thread + 2816) = fake_bionic_tls;
    tp[1] = fake_thread;                      /* TLS_SLOT_THREAD_ID */
}
```

`bionic_tls::locale == NULL` 是关键：`__ctype_get_mb_cur_max` 自己会判空
（`add x9, x8, #1; cmp x9, #1; b.hi` → locale 为 0 或 -1 时走"还没有 locale"的分支返回 4/1，**不解引用**）。

源码与构建脚本在 [`../../scripts/tlsfix/`](../../scripts/tlsfix/)：

```sh
scripts/tlsfix/build-tlsfix.sh                 # clang 交叉编出 libtls-padding.so
scripts/tlsfix/install-tlsfix.sh --mount       # 绑到设备上（运行时，重启即失效）
scripts/tlsfix/install-tlsfix.sh --unmount     # 撤销
```

### 3.1 效果

```
$ systemctl is-active lightdm
active                                    ← 之前是 failed（NRestarts=5）

$ ps -o pid,stat,comm -p $(pgrep -f lomiri-system-compositor)
1759891 Ssl+ lomiri-system-compositor     ← 之前 [+0.44s] 就被 SIGSEGV 杀掉

$ /usr/bin/test_hwcomposer
Segmentation fault (core dumped)          ← 之前
test_hwcomposer: test_common.cpp:373: ... Assertion `err == 0' failed.   ← 之后（不再是 SIGSEGV）
```

`unity-system-compositor.log` 也从"加载完平台插件就死"变成了：

```
mirserver: Found graphics driver: ubports:android2 (version 1.8.0) Support priority: 272
mirserver: Selected driver: ubports:android2 (version 1.8.0)
library "libui_compat_layer.so" not found
```

## 4. 这次改动的性质与边界

- **纯运行时**：`scripts/tlsfix/install-tlsfix.sh --mount` 只是在 `/usr/lib/aarch64-linux-gnu/libtls-padding.so`
  上做一次 `mount --bind`。没有写任何分区，没有改 rootfs 镜像，`--unmount` 即恢复原状。
- 这个垫片**不是最终的修法**，它是一个**探针 + 临时替代**：
  - 假的 `pthread_internal_t` 是全零的，bionic 眼里的"当前线程"是个桩（tid=0、key_data 全零、dlerror_buffer 可写）。
    已经能看到有些路径会因此**返回错误而不是崩溃**（`hw_get_module` 就返回了非 0）。
  - 它的位置（`TP+8` = glibc 的 `private`）是**安全的**——glibc 从不碰这个成员；
    但把它做成永久的，应该走"换掉 rootfs 里那份 `libtls-padding.so`"或 `/etc/ld.so.preload`，
    而不是每次靠 `mount --bind`。

## 5. 它暴露出的下一个阻塞

`library "libui_compat_layer.so" not found` —— Mir 的图形平台选了出来、然后停在这里。

- 这个库**不是** Ubuntu 的，是 **Halium/Android 侧**的：源码在 libhybris 的
  `compat/ui/ui_compatibility_layer.cpp`（`android::GraphicBuffer` 的一层薄 C 包装），
  由**设备的 Android 构建**编出来放进 `/system/lib64/libui_compat_layer.so`。
- 本机用的是**原厂 LeEco Android 9 镜像**，里面没有它。这正是
  [`40`](40-the-display-died-below-lomiri.md) §7 里"我们用的是一个原厂 stock Android 9 `system.img`"那条猜测的**第一次实证**。

所以 Phase 5 现在是两个独立的阻塞，第一个已经解决，第二个是"Android 镜像缺 Halium 侧的东西"。

## 6. 还没证实什么

- `lightdm active` ≠ 屏幕亮。`/sys/class/leds/lcd-backlight/brightness` 仍是 0，`/run/wayland-syscomp` 还没出现。
  现在的状态是"compositor 活着、在 futex 上等"，不是"compositor 正常工作"。
- `libui_compat_layer.so` 是不是**唯一**剩下的阻塞，还没证实（它现在是最大嫌疑，不是结论）。
- 垫片对**其它进程**（会话、pulseaudio、ofono…）的影响没测——目前只作用于被 `LD_PRELOAD` 的那条链。
- 为什么别的 Halium 9 端口不崩，仍然没有解释。现在多了一个候选解释：
  那些端口的 Android 镜像是 Halium 自己构建的，`libui_compat_layer.so` 之类齐备，
  而 **bionic TLS 槽这一条**——如果它们也是这份 libhybris，理应同样崩；这一点还没验证。
