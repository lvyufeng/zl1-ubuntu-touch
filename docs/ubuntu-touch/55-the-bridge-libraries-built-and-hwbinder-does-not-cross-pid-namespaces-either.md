# 55 — 那两个库编出来了、装上了、两个服务都起来了，然后撞上 hwbinder 也不跨 PID namespace

**日期**: 2026-09-21
**状态**: `53` 定的下一步做完了：`libubuntu_application_api.so` 和 `libbiometry_fp_api.so` 从本地 Halium 树里编出来、装进 `/userdata/zl1-hybris/lib/`、给两个 system unit 加上 `HYBRIS_LD_LIBRARY_PATH`。**`lomiri-location-service` 和 `biometryd` 从 `failed` 变成 `active`，失败单元从 3 个降到 1 个。** 但 GPS/指纹本身**还不能用**，而且原因不是符号了 —— 是 `IGnss::getService()` 返回 NULL：**hwbinder 和 binder 一样不跨 PID namespace**（`43` 只证明了 binder 那一半）。所以下一步是"让这两个服务跑进容器的 PID namespace"，和 `lsc-wrapper` 对合成器做的是同一件事。
**接续**: [`53`](53-the-bridge-libraries-are-absent-and-were-never-built.md)、[`50`](50-the-pc-zero-is-a-bridge-symbol-that-resolved-to-null.md)、[`43`](43-binder-does-not-cross-a-pid-namespace.md)

---

## 1. 失败原因一直是明文写着的

装之前先看了一眼这两个单元到底在报什么（`journalctl -u`，注意设备时钟不对，见 `47` 那条附注）：

```
lomiri-location-serviced-wrapper[46760]: library "libubuntu_application_api.so" not found
lomiri-location-service.service: Main process exited, code=killed, status=11/SEGV

biometryd[45045]: library "libbiometry_fp_api.so" not found
biometryd.service: Main process exited, code=killed, status=11/SEGV
```

`50` 是从 core 反汇编推出来的（`br x16`、x16=0、`pc=0x0`），`53` 是扫全盘发现库不存在 —— 而**库自己每次都把原因印在日志里**，只是一直没人读那一行。两次 SIGSEGV 都是"dlopen 失败 → 桥接符号是 NULL → 跳上去"。

## 2. 编：两个陷阱，一个"什么都没发生"

`build-platform-api-libs.sh`（新增）。`53` 里"从来没接进构建"这句话这次查实了，而且比预想的更精确：两份 `Android.mk` **本来就在构建图里** ——

```
$ grep -n 'platform-api\|biometryd' out/.module_paths/Android.mk.list
233:halium/biometryd/android/hybris/Android.mk
242:halium/platform-api/android/hybris/Android.mk
```

（`build/make/core/main.mk:463` 就是从这个清单 include 全部子 makefile 的。）所以 `m libubuntu_application_api` 一直是一个合法请求，只是 `device/leeco/zl1/` 里没有一行 `PRODUCT_PACKAGES` 提到它，也没有别的模块依赖它 —— ninja 从来没有理由去编它。**修法是"提一次请求"，不是"打一个补丁"。**

路上踩了两个坑，都是"看起来是别的问题"的那一类：

**一、脚本静静地什么都没干。** 第一版脚本在 `set -euo pipefail` 下 `( cd "$TREE"; source build/envsetup.sh >/dev/null 2>&1; lunch ...; m ... )`，结果是：打印完 `== building: ...` 就直接 `exit 1`，**一行 make 输出都没有**。原因在 envsetup.sh 自己：

```sh
# build/envsetup.sh:1701
_xarray=(a b c)
if [ -z "${_xarray[${#_xarray[@]}]}" ]     # 故意越界一格，用来判断数组是 0 起还是 1 起
```

bash < 4.4 把它展开成空串；bash ≥ 4.4 在 `set -u` 下判它 "unbound variable" 并**中止 source**。这台机器是 bash 5.1.16 —— 于是 `source` 失败、`set -e` 让子 shell 当场退出，整个脚本在碰 make 之前就结束了。要 `set +u` 再 source。`build-hwc2-compat-layer.sh` 有同一个潜在问题（它也是这个形状），一起修了 —— 那份脚本此前很可能**从来没有成功跑过**，`out/` 里的 `libhwc2_compat_layer.so` 是手工编的。

**二、`find` 给了 32 位的那个。** product out 里同名文件有两份（`system/lib` 是 arm，`system/lib64` 是 arm64），`find … -print -quit` 先撞上哪个纯看遍历顺序，第一次给的就是 arm 的。两个都能编过、名字还一样，**只有在 64 位设备上加载时才失败**。现在直接写死 `system/lib64`，并且把 `readelf -h` 的 Machine 打出来。

顺带把 GPS 后端的二选一也说清楚（`BOARD_HAS_LEGACY_GPS_HAL` 为真走 `ubuntu_application_gps_for_hybris.cpp`，否则走 `..._hidl_...`），因为编出来的是 **HIDL** 那一个 —— 也就是说它要对话的是 `android.hardware.gnss` HIDL 服务，而不是老的 `hardware/gnss.h`。这一点决定了 §5 那个问题。

## 3. 装：符号是精确对上的

产物（都是 AArch64，SONAME 正确）：

```
libubuntu_application_api.so   135184 bytes   exports 19 个 u_ 符号
libbiometry_fp_api.so           68904 bytes   exports 14 个 u_ 符号
```

把宿主侧的"需要"和这边的"导出"逐个对上（从 crash-hunt 的 sysroot 里取宿主库，用同一个字节扫描）：

```
libubuntu_platform_hardware_api.so.4.0.0: needs 19, ours exports 19   missing: NONE
libbiometry.so.2.0.0:                     needs 14, ours exports 14   missing: NONE
```

不是"数量凑巧"：是两边各自 **1:1 完全一致**，一条不缺、一条不多。依赖也点过名：两个库的 `DT_NEEDED` 在设备上全部可解析，包括 `/userdata/zl1-hybris/lib/libhidltransport.so`（`42` 那个打过补丁的版本，是这一串里最难的一个）。

`install-platform-api-libs.sh`（新增）：推两个 `.so` 进 `/userdata/zl1-hybris/lib/`，然后给两个单元写**第二个** drop-in：

```
[Service]
Environment=HYBRIS_LD_LIBRARY_PATH=/userdata/zl1-hybris/lib:/system/lib64:/odm/lib64:/vendor/lib64
```

写成 `zl1-hybris-path.conf` 而不是去改 `install-system-tls-preload.sh` 写的 `zl1-tls.conf`：systemd 会合并 drop-in，两个变量都在，而且**两边重跑都不会覆盖对方**。值就是 `lsc-wrapper` 给合成器设的那个 —— 合成器从 wrapper 拿到它，普通 system unit 没有 wrapper，这正是它们看不见 `/userdata/zl1-hybris/lib` 的原因。

## 4. 结果：两个服务都起来了

```
  lomiri-location-service          active
  biometryd                        active

  lomiri-location-service  pid 917493  3 mapping(s)     <- 库确实被这个进程映射进来了
  biometryd                pid 925733  3 mapping(s)
```

`lomiri-location-service` 的日志里那句关键的话回来了 —— `50` 说它"只在真的 `gps::Provider` 上崩"，现在：

```
Instantiating and configuring: gps::Provider        <- 以前就是死在这一行
Instantiating and configuring: remote::Provider
systemd[1]: Started lomiri-location-service.service - Location Services.
```

`systemctl --failed` 从三个降到**一个**（只剩 `update-machine-info-from-deviceinfo`）。`biometryd` 也从 `failed (Result: signal)` 变成 `active`。

**`pc=0x0` 这一类到这儿就结清了**：两条 segfault 的根因（宿主库 dlopen 一个设备上不存在的 Android 库）已经修掉。

## 5. 但是：`getService()` 返回 NULL —— hwbinder 也不跨 PID namespace

服务活着、库也映射进来了，可是 GPS 拿不到数据。容器里的 logcat 里，**我们自己的库**在说话（tag 就是文件名）：

```
D/ubuntu_application_gps_hidl_for_hybris: gnssHal 1.1 was null, trying 1.0     (x50)
E/ubuntu_application_gps_hidl_for_hybris: Unable to get GPS service            (x50)
```

`set_gps_service_handle()` 先要 1.1、退回 1.0，**两个都是 NULL**。指纹那边一模一样：

```
E/: Unable to get IBiometricsFingerprint::2.1 service
```

而这两个 HAL **在容器里是注册着的**（`lshal`）：

```
Y android.hardware.gnss@1.0::IGnss/default
Y android.hardware.biometrics.fingerprint@2.1::IBiometricsFingerprint/default
Y android.hardware.gatekeeper@1.0::IGatekeeper/default
```

（顺带一个意外的好消息：指纹 HAL 的二进制叫 `...fingerprint@2.0-service.leeco_zl1`，但**它注册的确实是 2.1**，正好对上我们编出来的客户端需要的那个版本。`gnss@1.1` 没有，但源码本来就会退回 1.0。）

那为什么拿不到？**同一个 `lshal` 二进制，从宿主 PID namespace 跑和从容器 PID namespace 跑，看到的注册服务数差了一个数量级：**

```
$ /android/system/bin/lshal                              | grep -c '^Y'   ->   0
$ nsenter -t $(lxc-info -n android -pH) -p -m -- \
      /system/bin/lshal                                  | grep -c '^Y'   -> 134
```

`43` 用 `service list` 的 `Found 0 services` / `Found 19 services` 证明了 **binder** 不跨 PID namespace；这次是同一件事在 **hwbinder** 上的对照实验（`lshal` 走 `hwservicemanager`）。宿主 namespace 里 `getService()` 只能返回 NULL —— 所以 `lomiri-location-serviced` 跑在宿主里，注定看不见容器里那些 HAL，不管符号修得多干净。

对照组也在：`lomiri-system-compositor` **不**在宿主 `ps` 里、只在容器的 `ps -A` 里（容器内 pid 1212）—— 因为 `lsc-wrapper` 用 `nsenter -t $ANDROID_INIT_PID -p` 把它送进去了，所以它能拿到 hwcomposer。**合成器能工作，靠的就是这一步；这两个服务现在缺的也正是这一步。**

## 6. 所以下一步是"把两个服务搬进容器的 PID namespace"

形状已经现成（`43` §5、`lsc-wrapper`）：`exec nsenter -t "$ANDROID_INIT_PID" -p -- <原来的命令>`。

要点和风险，先说清楚：

- **只能加 `-p`**（必要时 `-m`），**不能加 `-F`**。`setns` 一个 PID namespace 只影响之后 fork 出来的子进程，`-F` 会让被 exec 的进程留在宿主 namespace 而它的孩子进容器，于是 `task_active_pid_ns(current) != pid_ns_for_children`，`clone(CLONE_THREAD)` 返回 `EINVAL` —— 这两个服务都是 GLib 线程化的，会以 `46`/`47` 那种"起一半"的方式死掉。
- 这两个是**系统**服务：`lomiri-location-service` 还要在 system bus 上注册名字、`biometryd` 要被别的进程调用。`nsenter -p` 只换 PID namespace，mount/net namespace 不动，D-Bus 应该没事 —— 但这是**预测**，不是测量。合成器是会话服务，`43` 的经验不能直接外推。
- 因此这一步要**一次只做一个服务**，先用只读方式验证（起来之后 `lshal` 里能不能看见、`getService` 还回不回 NULL），不行就退回（删掉 drop-in 的 `ExecStart=` 覆盖即可，库和 `HYBRIS_LD_LIBRARY_PATH` 都留着，那部分已经证明是好的）。

**没做的**：这一步一点没开始。也仍然**不预测** GPS/指纹最终能不能用 —— 符号能解析、服务能拿到、HAL 能对话，是三件事，现在是第二件做完了。

## 7. 这一段改了哪些东西

| 文件 | 作用 |
| --- | --- |
| `scripts/hybris-shims/build-platform-api-libs.sh` | 新增。`m libubuntu_application_api libbiometry_fp_api`，把产物放进 `out/`。带那三个宿主前置检查（ImageMagick / python2 shim / `ALLOW_MISSING_DEPENDENCIES`），外加这次新踩的两个坑：`set +u` 才能 source envsetup.sh，以及必须取 `system/lib64` 那一份 |
| `scripts/hybris-shims/build-hwc2-compat-layer.sh` | 同一个 `set +u` 修复（它此前大概从没成功跑过），以及失败时明确报错而不是静默退出 |
| `scripts/hybris-shims/install-platform-api-libs.sh` | 新增。`--install` / `--remove` / `--status`。装两个库 + 给两个单元写 `HYBRIS_LD_LIBRARY_PATH` drop-in；`--status` 把"库在不在"、"环境变量有没有"、"单元活不活"、"进程有没有真的映射这个库"分成四件事分别报，最后附 `journalctl -u` 的尾部 |
