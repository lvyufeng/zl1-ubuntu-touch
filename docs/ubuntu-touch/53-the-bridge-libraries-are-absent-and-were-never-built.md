# 53 — 两个 `pc=0x0` 的答案是"那个库这台设备上根本不存在"

**日期**: 2026-09-21
**状态**: `50` 把 `pc=0x0` 定位成"libhybris 的桥接符号解析成了 NULL"，并留了一条待办：上设备查 `libubuntu_application_api.so` / `libbiometry_fp_api.so` 在不在、缺哪个符号。查完了，答案比"缺一个符号"更简单也更彻底：**这两个库在整台设备上一个都不存在**（`find / -xdev` 加 `/android /vendor /system` 全扫，零命中）。然后顺着查到了原因：**它们的源码就在本地那棵 Halium 树里（`halium/platform-api/android/hybris/Android.mk`、`halium/biometryd/android/hybris/Android.mk`），但这个 port 从来没有把它们编出来过** —— 同一棵树里图形栈那两个 compat layer 是编出来了的（`out/` 里有成品），所以这不是"编不出来"，是"没编"。
**接续**: [`50`](50-the-pc-zero-is-a-bridge-symbol-that-resolved-to-null.md)、[`52`](52-the-gui-and-touch-confirmed-by-the-user.md)

---

## 1. 量到的（读操作）

```
$ ./scripts/hybris-shims/check-android-bridge-libs.sh --dev <三个 sysroot 里的 host 库>
--- libbiometry.so.2.0.0  needs 14 u_ symbols
    libbiometry_fp_api.so        MISSING (not under any android_dlopen path)
--- libubuntu_platform_hardware_api.so.4.0.0  needs 19 u_ symbols
    libubuntu_application_api.so MISSING (not under any android_dlopen path)
```

再全盘找一遍，确认不是"搜索路径没覆盖到"：

```
$ find / -xdev -name "libubuntu_application_api.so*"        ->  (空)
$ find / -xdev -name "libbiometry_fp_api.so*"               ->  (空)
$ find /android /vendor /system -name "libubuntu_application_api.so*" ->  (空)
```

`android_dlopen` 收到的确实是这个名字，不是误读 rodata（`50` 里那句 `add x0, x0, #0x998` 指向 0x2998 = `"libubuntu_application_api.so"`，`w1 = 1` 即 `RTLD_LAZY`）。

顺带确认了宿主侧的确有一条 `/system -> /android/system`（`/vendor`、`/odm` 同理），所以"在宿主进程里按 `/system/lib64` 找"是有意义的，不是路径写错。

## 2. 为什么不在：源码在，但从来没编

`49` 那一串 grep 已经看到 `/mnt/data/halium-zl1-build` 就是这台设备的 Android + Halium 构建树（`PPR1`，Android 9，和设备一致）。里面：

```
halium/platform-api/android/hybris/Android.mk   ->  LOCAL_MODULE := libubuntu_application_api
halium/biometryd/android/hybris/Android.mk      ->  LOCAL_MODULE := libbiometry_fp_api
```

两份 Android.mk 都完整，而且都已经按 Android 版本分了支（这台是 9，所以走 `IS_ANDROID_8=true`）：

| 模块 | 需要的接口/库 |
| --- | --- |
| `libubuntu_application_api` | `libandroidfw libbinder libcutils libinput liblog libutils libgui libEGL libGLESv2 libhardware libhardware_legacy libdl` + `libhidlbase libhidltransport libsensor android.hardware.gnss@1.0/@1.1 android.hardware.power@1.0/@1.1/@1.2/@1.3`。GPS 实现二选一：`BOARD_HAS_LEGACY_GPS_HAL` 为真走 `ubuntu_application_gps_for_hybris.cpp`，否则走 `ubuntu_application_gps_hidl_for_hybris.cpp` |
| `libbiometry_fp_api` | `libbinder libcutils libinput liblog libutils libhardware libhardware_legacy libdl` + `libhidlbase libhidltransport libsensor android.hardware.biometrics.fingerprint@2.1 android.hardware.gatekeeper@1.0`（Android 8 以下直接 `$(error)`） |

需要的 HIDL 接口在树里都在（`hardware/interfaces/` 下 `gnss@1.0`、`gnss@1.1`、`power@1.0`、`power@1.3`、`biometrics.fingerprint@2.1`、`gatekeeper@1.0` 全部命中）。

**而 `out/` 里的成品说明这条流水线是通的**：

```
out/target/product/zl1/system/lib64/libhwc2_compat_layer.so        <-- 编出来了
out/target/product/zl1/system/lib64/libui_compat_layer.so          <-- 编出来了
out/ 里搜 libubuntu_application_api.so / libbiometry_fp_api.so      <-- 空
```

`device/leeco/zl1/` 里也没有任何一行提到 `platform-api` / `biometryd` —— 也就是说这两个 Android 侧模块**从来没有被接进构建**。这和图形栈那边不一样：那边是"缺 → 我们补"，这边是"源码一直在树上，只是没编"。

## 3. 所以 GPS 和指纹的下一步是"编两个库"，不是"补一个符号"

形态和 `build-hwc2-compat-layer.sh` 完全是同一类（`42`/`43` 那个先例）：

1. 把两份 Android.mk 接进树（Halium 的惯例是让 `halium/` 下的目录被构建看见；图形栈那两份是靠 `halium/libhybris/compat/{hwc2,ui}/Android.mk` 进去的）；
2. `m libubuntu_application_api libbiometry_fp_api`；
3. 产物放进 **`/userdata/zl1-hybris/lib/`** —— 就是 `libui_compat_layer.so` / `libhwc2_compat_layer.so` 现在待的地方；
4. 给这两个**系统服务**加 `HYBRIS_LD_LIBRARY_PATH`（合成器是从 `lsc-wrapper` 拿到这个变量的，而 `lomiri-location-service` / `biometryd` 是普通 system unit，拿不到 —— 现在它们的 drop-in 里只有 `LD_PRELOAD`，`§1` 里 `systemctl show -p Environment` 的输出证实了这一点）。这是 `48` 那个 drop-in 机制的第二个用途。

注意 `libhidltransport` 已经在 `/userdata/zl1-hybris/lib/` 里（是 `42` 那个打了补丁的版本），所以依赖里最难的那一个已经就位。

**还没有做**：这两步都还没开始。而且编出来只解决"符号能解析"，**不解决 GPS/指纹本身能不能工作** —— 那还要求 `android.hardware.gnss`、`android.hardware.biometrics.fingerprint` 这两个 HAL 在容器里注册（`44`/`47` 那一层的事）。不预测。

## 4. 这一段改了哪些东西

**没有改任何文件。** 这一篇是 `50` 那条待办的执行结果（设备侧只读检查 + 本地源码树检查）。`52` 里那个快照抓取器还在设备上跑着，等一次重启来验证开机日志。
