# 56 — 把两个服务搬进容器的 PID namespace：桥接真的通了

**日期**: 2026-09-21
**状态**: `55` 的最后一道墙拆了。`lomiri-location-service` 和 `biometryd` 现在跑在**容器的 PID namespace** 里（`nsenter -p`，和 `lsc-wrapper` 对合成器做的一样），于是：指纹那边库自己报出 **`Connected to IBiometricsFingerprint::2.1 service`**；GPS 那边 `set_gps_service_callbacks` 走到了，而且**容器的 gnss HAL 回调进了我们的进程**（`gnssSetCapabilitesCb`、`gnssSetSystemInfoCb`）。失败单元仍然只有 `update-machine-info-from-deviceinfo` 一个，两个服务重启计数都是 0。**但"桥接通了"不等于"定位能用"**：还没拿到过位置，容器里 GNSS 引擎的 QMI 层在报错（§5）。
**接续**: [`55`](55-the-bridge-libraries-built-and-hwbinder-does-not-cross-pid-namespaces-either.md)、[`43`](43-binder-does-not-cross-a-pid-namespace.md)、[`50`](50-the-pc-zero-is-a-bridge-symbol-that-resolved-to-null.md)

---

## 1. 只差这一步

`55` 量到的对照：**同一个 `lshal` 二进制，宿主 PID namespace 里报 0 个注册服务，容器里报 134 个**。宿主里 `getService()` 只能返回 NULL，所以 `lomiri-location-serviced` 跑在宿主里，符号修得多干净都没用。

设备上还有个现成的对照组：`lomiri-system-compositor` **只出现在容器的 `ps -A` 里**（容器内 pid 1212），宿主 `ps` 里找不到 —— 因为 `lsc-wrapper` 用 `nsenter -t $ANDROID_INIT_PID -p` 把它送进去了。合成器能从 `43` 活到现在，靠的就是这一步。

## 2. 装了什么

`install-container-ns-services.sh`（新增），两件东西：

```
/userdata/zl1-hybris/bin/zl1-ns-exec                  包装脚本，两个服务共用一份
/etc/systemd/system/<unit>.service.d/zz-zl1-ns.conf   ExecStart 覆盖
```

`zz-` 前缀是有用的，不是装饰：`lomiri-location-service` 已经有 `lxc-android-config.conf` 在做 `ExecStart=` 重置，而 systemd 是**跨所有 drop-in 目录按文件名统一字典序**应用的，所以要有一个排在 `lxc-android-config.conf` 后面的名字，"最后一个 `ExecStart=` 生效"才成立。（`zl1-ns.conf` 恰好也排在它后面，但那是巧合。）

包装脚本的关键几行：

```sh
A=$(lxc-info -n android -pH | head -1)
[ -n "$A" ] && [ -e "/proc/$A/ns/pid" ] || { echo "...refusing..."; exit 1; }
exec nsenter -t "$A" -p -- "$@"
```

三个刻意的选择：

- **只加 `-p`，不加 `-F`。** `setns` 一个 PID namespace 只影响之后 fork 的子进程，`-F` 会让被 exec 的进程留在宿主 namespace 而它的孩子进容器，`pthread_create` 就 `EINVAL` —— 这两个都是 GLib 线程化的，`43` 见过合成器这样死。
- **不做 `nsenter` 清理**（`lsc-wrapper` 里那段）。那边清理是因为残留的无子 `nsenter` 会一直占着 namespace；这边 systemd 默认 `KillMode=control-group`，而 **cgroup 和 PID namespace 是正交的** —— 真正搬进容器的那个子进程也在本 unit 的 cgroup 里，会被一起杀。实测确认了（§6）。而且清理意味着按模式匹配 `nsenter` 进程，那会碰到合成器那个活着的，不值得为一个装饰性问题冒这个险。
- **容器没起来就退出非零**，不在宿主 namespace 里凑合跑。跑在错误 namespace 里的服务会照常注册 D-Bus 名字、报 `active`，然后什么都不做 —— 那是最糟的一种"成功"。两个 unit 都是 `Type=dbus` 且 `After=lxc-android-config.service`，正常不会走到这条路；走到时 `Restart=` 会接手。

**一次只搬一个。** 先搬 `biometryd`（没有用户可见的东西依赖它），确认之后再搬 `lomiri-location-service`。

## 3. 结果

```
lomiri-location-service          active
  pid 1562784  pid:[4026533532]  in the container PID namespace
biometryd                        active
  pid 1486941  pid:[4026533532]  in the container PID namespace
```

（容器自己的 ns 是 `pid:[4026533532]`，宿主的进程是 `4026531836`。）

**指纹 —— 库自己说通了：**

```
I/(4605): Connected to IBiometricsFingerprint::2.1 service
```

这一行对应 `biometry_fp_hidl_for_hybris.cpp` 里的成功分支（`ALOGI("Connected to IBiometricsFingerprint::2.1 service\n")`，紧跟在 `getService()` 非空之后）。有意思的是：**容器里那个 HAL 的二进制叫 `...fingerprint@2.0-service.leeco_zl1`，但它注册的是 2.1** —— 正好是我们编出来的客户端要的那个版本（`55` §2 里 GPS 后端二选一选中的是 HIDL 那份，指纹这份的 `getService` 先试 2.3 再退 2.1）。

**GPS —— 不只是连上，HAL 回调进来了：**

```
I/ubuntu_application_gps_hidl_for_hybris(4649): u_hardware_gps_new: called
I/(4649): set_gps_service_handle: called
D/(4649): gnssHal 1.1 was null, trying 1.0
I/(4649): set_gps_service_callbacks: called        <- 以前到不了这里
E/(4649): Unable to initialize GNSS Xtra interface  <- Xtra（预测星历）没有，非致命
I/(4649): u_hardware_gps_set_position_mode: called
I/(4649): gnssSetCapabilitesCb: called              <- HAL 调进我们的进程
I/(4649): gnssSetSystemInfoCb: called               <- 同上
```

对比同一份 logcat 里搬家**之前**那些 pid 102 的记录：每一轮都停在 `set_gps_service_handle` → `gnssHal 1.1 was null, trying 1.0` → `Unable to get GPS service`，然后重来。现在 `set_gps_service_callbacks` 走得下去，说明 `getService()` 非空、`setCallback` 被接受、**而且 HAL 主动回调了** —— `IGnssCallback` 是从容器里的 `android.hardware.gnss@1.0-service` 打过来的。整条 hwbinder 链路是活的。

`gnssHal 1.1 was null` 是正常的，不是问题：`lshal` 里只有 `@1.0::IGnss/default`，源码本来就写了退回 1.0，hwservicemanager 也明确说了 `Cannot find entry android.hardware.gnss@1.1::IGnss/default in either framework or device manifest`。

## 4. 重启是干净的

`nsenter` 那个"父进程留在宿主 namespace、子进程进容器"的形状天然让人担心残留。实测：`systemctl restart lomiri-location-service` 之后，旧的 nsenter（1520141）消失、新的（1562764）出现，**没有累积**；容器里 `ps -A` 只有一个 `lomiri-location-serviced`、一个 `biometryd`；`NRestarts` 都是 0。§2 里那个 cgroup 推断是对的。

合成器那个 nsenter（51411）全程没被碰。

## 5. 这**不**等于定位能用

桥接通了是第三件事做完了（`55` §6：符号能解析 → 服务能拿到 → HAL 能对话）。**还没有拿到过位置**，而且下面这层在报错：

```
E/LocSvc_ApiV02(239): open:413:11]: Failed to get features supported from QMI_LOC_GET_SUPPORTED_FEATURE_REQ_V02.
```

这是容器里 GNSS 引擎（`vendor.qti.gnss@1.0-service` → `vendor.qti.gnss@1.0-impl.so` → `LocSvc_ApiV02`）在向 modem/位置子系统开 QMI 通道时失败。也就是说还有**第四件事**：GNSS 引擎要和 modem 侧说话，而 modem 的状态在本 port 的清单里一直是"设备节点在，没测"（`48`）。`gnssStart` 也还没被调用过 —— 我们的库里没出现 `u_hardware_gps_start`，那要等有客户端请求定位才会走。

不预测。这一篇的结论只到"HAL 能对话、回调能回来"。

## 6. 这一段改了哪些东西

| 文件 | 作用 |
| --- | --- |
| `scripts/hybris-shims/install-container-ns-services.sh` | 新增。`--install [unit…]` / `--remove` / `--status`。装包装脚本和 `zz-zl1-ns.conf` drop-in；不带参数时两个都搬，带参数可以一次只搬一个。`--status` 报的是**四件事分开**：wrapper 在不在、单元活不活、**进程在哪个 PID namespace**（按 `comm` 找真正的服务进程并对比 `ns/pid`，因为 ExecStart 是 nsenter、真正搬走的是它的子进程，而且 `Type=dbus` 单元的 MainPID 还未必是它）、以及 logcat 里那几行关键字符串的计数。日志计数是全 buffer 的，所以搬家前的失败也还在里面 —— 看的是成功那几行有没有出现过 |
