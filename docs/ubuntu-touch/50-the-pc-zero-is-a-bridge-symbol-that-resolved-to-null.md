# 50 — 那两个 core 的 `pc=0x0` 是 libhybris 的桥接符号解析成了 NULL

**日期**: 2026-09-21
**状态**: `49` 里两个 core 的形状（`pc=0x0`、`si_addr=0`、`lr` 落在自己那个库的某条 `bl …@plt` 之后）查到了底：**不是跳空数据指针，是 `android_dlsym()` 返回 NULL 之后被直接跳了过去**。host 侧的库用 `android_dlopen("libxxx.so") + android_dlsym("u_xxx")` 这种运行时桥接去够 Android 侧，而桥接函数只对**缓存过的**指针做了非空判断，对**刚解析出来的**那个没有 —— 所以"符号不存在"不是一条错误路径，是一条 `br x16`（x16=0）。这也是 `build-hwc2-compat-layer.sh` 早就警告过的那一类：*"it does not NULL-check those, so a missing one is a jump to address 0"*。
**接续**: [`49`](49-two-cores-that-are-not-tls-wifi-stuck-at-wcnss-and-a-trip-into-edl.md)、[`48`](48-the-tls-fault-was-killing-seven-system-services.md)、[`42`](42-the-wait-that-could-never-finish.md)

---

## 1. GPS：反汇编把整条路读出来了

core 给的 `lr = liblomiri-location-service.so.3.0.0 + 0xdaa68`。按动态符号表查，它落在：

```
0x00000000000daa40  <com::lomiri::location::providers::gps::android::HardwareAbstractionLayer::Impl::register_callbacks()>
```

`+40`（`0xdaa68`）正好是这条指令的**返回地址**：

```asm
0xdaa60  mov  x0, x19
0xdaa64  bl   0x33a70 <u_hardware_gps_new@plt>     <-- lr = 0xdaa68 就是它
0xdaa68  str  x0, [x19, #96]
```

`u_hardware_gps_new` 由 `libubuntu_platform_hardware_api.so.4.0.0` 定义（`readelf --dyn-syms` 里两条对得上），是个 348 字节的转发函数。它的形状是这样的：

```asm
; 快路径：取缓存过的指针
0xea8   ldr  x1, [x19, #120]
0xeac   cbz  x1, 0xecc              <-- 缓存是 NULL 的话，会去解析（有判断）
...
0xec4   autiasp
0xec8   br   x16                    <-- 跳到缓存值（此时非 NULL）

; 解析路径：dlopen + dlsym，然后把结果也算一次
0xf70   bl   secure_getenv@plt      ; "UBUNTU_PLATFORM_API_TEST_OVERRIDE"（测试用覆盖）
0xf9c   bl   android_dlopen@plt     ; rodata 0x2998: "libubuntu_application_api.so"
0xf20   bl   android_dlsym@plt      ; rodata 0x29e8: "u_hardware_gps_new"
0xf24   str  x0, [x19, #120]        ; 把结果存起来 —— NULL 也照样存
0xf30   ldr  x1, [x19, #120]
0xf38   mov  x16, x1
0xf44   br   x16                    <-- 没有非空判断。x1=0 → pc=0x0
```

**关键就是这最后四行**：`0xf24` 把 `android_dlsym` 的返回值无条件缓存，`0xf30`–`0xf44` 又无条件跳到它。快路径上的那个 `cbz` 只保护"缓存"，不保护"刚解析出来的值"。

所以那次 SEGV 的含义是唯一的：**`android_dlsym(handle, "u_hardware_gps_new")` 返回了 NULL。** host 侧库自己去 dlopen 的 Android 库是 `libubuntu_application_api.so`。

## 2. biometryd 是同一个形状，只是换了库

core 给的 `lr = libbiometry.so.2.0.0 + 0xd6750`，是 `bl 0xd8f00` 的返回地址。`0xd8f00` 那个函数的开头和上面一模一样：

```asm
0xd8f14  ldr  x0, [x19, #1000]
0xd8f18  cbz  x0, 0xd8f34           ; 缓存判断
...
0xd8f30  br   x16
```

而 `libbiometry.so.2.0.0` 的 rodata 里并排放着：

```
libbiometry_fp_api.so          <-- 它 android_dlopen 的东西
u_hardware_biometry_new
u_hardware_biometry_setNotify
u_hardware_biometry_preEnroll   … 共 14 个
```

注意 `libbiometry.so` 的**动态符号表里一个 `u_` 都没有**（它自己拿字符串去 dlsym），而 `liblomiri-location-service.so` 里 13 个 `u_` 全是 `UND` —— 两种写法，同一个模式。`lomiri-location-serviced` 那 13 个由 `libubuntu_platform_hardware_api` 提供，后者再桥到 `libubuntu_application_api.so`。

**所以两个服务死在同一个机制上：桥接的目标库没给出那个符号。**

## 3. 为什么只有 `gps::Provider` 崩

`49` 里的对照实验现在是自解释的：`--provider dummy::Provider` 完全不碰 Android HAL，所以一次桥接都不做，20 秒安然无事；而 `lsc-wrapper` 的真实配置是 `--provider gps::Provider --provider remote::Provider`，第一条就走进 `HardwareAbstractionLayer::Impl::register_callbacks()`，第一件事就是 `u_hardware_gps_new` → 崩。

调用点也解释了为什么是 `register_callbacks` 而不是更早：**它是这条路上第一个真的去够 Android 侧的动作。**

## 4. 这一类问题在这个 port 里不是新的

`scripts/README.md` 里已经有原文：

> `libui_compat_layer.so`、`libhwc2_compat_layer.so`、`libhidltransport.so` 是宿主图形栈经 libhybris 够过去的 Android 侧对象，原厂 LeEco 镜像要么没有、要么有一个在这里用不了的。

而 `build-hwc2-compat-layer.sh` 的说明里写得更直接：

> *Prints the symbols the rootfs's `libhwc2.so.1` looks up that this build does not export; **it does not NULL-check those, so a missing one is a jump to address 0**.*

**同一句话现在解释了 GPS 和指纹。** 当时只把图形栈那三个库补上了，Halium 服务用的这两个（`libubuntu_application_api.so`、`libbiometry_fp_api.so`）没人看过 —— 因为 `48` 之前这些服务连 TLS 那一关都过不去，压根走不到这里。

## 5. `check-android-bridge-libs.sh`

静态那一半不需要设备：库名和要的符号名都是 host 侧库 rodata 里的普通字符串。所以脚本做两件事：

```
HOST LIBRARY                                             ANDROID BRIDGE
liblomiri-location-service.so.3.0.0                      <none found>  (13 u_ symbols)
libbiometry.so.2.0.0                                     libbiometry_fp_api.so  (14 u_ symbols)
libubuntu_platform_hardware_api.so.4.0.0                 libubuntu_application_api.so  (19 u_ symbols)
```

（`liblomiri-location-service.so` 那一行 `<none found>` 是对的：它自己不含库名，桥接发生在 `libubuntu_platform_hardware_api` 里面。脚本如实说明，不猜。）

加 `--dev` 之后，对每个库名去 `android_dlopen` 会走的那些路径（`/android/system/lib64`、`/android/vendor/lib64`、`/system/lib64` …）找一个"在不在"，找到就把该库需要的每个 `u_` 符号在文件里做一次字节扫描 —— 设备上没有 readelf，而导出的符号名就在 `.dynstr` 里是明文。**"缺"这个结论是可信的，"有"可能是误报**（名字出现在第二个字符串表里），而我们要的正是"缺"。

## 6. 还没验证的（设备当时在 EDL）

- **`libubuntu_application_api.so` 和 `libbiometry_fp_api.so` 在容器里到底在不在、缺哪个符号。** `check-android-bridge-libs.sh --dev` 一条命令就能答，但**设备在 EDL 里**（`49` §5），所以这条是纸上的结论，不是量出来的。
- **旁证**：`49` 里那两份 core 的 `NT_FILE` 列表里 **一个 `/android/...` 路径都没有**（`mapped.txt` 只在 `/dev`、`/proc`、`/sys` 上做了过滤，Android 路径不会被滤掉）。也就是说这两个进程**从来没成功映射过任何 Android 侧库** —— 和 "dlopen/dlsym 没成" 是同一个说法。但这是间接证据，不能替代在设备上查那两个文件。
- **补上之后能不能真的跑起来。** 就算符号齐了，GPS 还需要 `hardware.gps` HAL 在容器里注册（那是 `44`/`47` 那一层的事）。不预测。

## 7. 这一段改了哪些东西

| 文件 | 作用 |
| --- | --- |
| `scripts/hybris-shims/check-android-bridge-libs.sh` | 新增。`[--dev] [ELF…]`。静态读出 host 库要 dlopen 的 Android 库名和它要的 `u_` 符号集；`--dev` 时按 `android_dlopen` 的搜索路径查存在性并逐符号做字节扫描。默认列的那几个是已经咬过这个 port 的桥接用户（GPS、指纹、platform hardware api、libhwc2）。**`--dev` 那一半还没在设备上跑过** —— 写它的时候设备在 EDL |
