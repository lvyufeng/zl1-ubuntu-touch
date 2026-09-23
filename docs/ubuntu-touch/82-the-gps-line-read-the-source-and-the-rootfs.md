# 82 — GPS 这条线上有两件事被读反了：那行 QMI 错误不是拦路者，"没人要过位置"才是

**日期**: 2026-09-23
**状态**: 纯离线的一轮（设备在 EDL，见 [`80`](80-the-ut-camera-app-starts-and-our-preload-was-breaking-egl.md) §7）。做的是把 `56`/`64` 里"GPS 没有定位"这条**读一遍源码和这个 port 自己的 rootfs 镜像**，结论有两处要改：**（一）**`LocSvc_ApiV02: Failed to get features supported from QMI_LOC_GET_SUPPORTED_FEATURE_REQ_V02` 这行**不是**失败原因 —— 它在源码里只打一条日志然后继续，而且它能被打出来本身就说明 QMI client **开成功了**；**（二）**`u_hardware_gps_start` 从没被调用过，最可能的原因是**从来没有任何客户端请求过位置**，而不是某个东西坏了。顺带把这条线的三个现成仪器找出来了：`lomiri-location-serviced-cli`（读/写两个开关）、`test_gps`（直插 Android GPS HAL）、以及 `custom.location.fake` 那个**用假坐标跑通整条 UT 定位栈**的杠杆。

**接续**: [`56`](56-the-two-services-move-into-the-containers-pid-namespace.md) §5（那行 QMI 错误的原始记录）、[`64`](64-the-last-unit-was-not-failing-it-was-obeying.md) §9（"GPS 没有定位"这条待办）、[`55`](55-the-bridge-libraries-built-and-hwbinder-does-not-cross-pid-namespaces-either.md)（桥接库）

---

## 0. 这一轮读的是什么（先把材料说清楚）

| 材料 | 位置 | 它是什么 |
|---|---|---|
| GPS HAL 的源码 | `/mnt/data/halium-zl1-build/device/leeco/msm8996-common/location/` | 这台设备（leeco msm8996）的 location 树，`loc_api/loc_api_v02/LocApiV02.cpp` 就是打出那行日志的文件 |
| 这个 port 的 rootfs 镜像 | `/mnt/data/ubports-rootfs/24.04-2.x/rootfs-24.04-2.x-arm64-android9plus-zl1-host.img`（只读 loop 挂载） | 设备上跑的那个 rootfs 的副本：单元文件、wrapper、`liblomiri-location-service.so`、`libubuntu_platform_hardware_api.so`、`/usr/bin/test_gps`、`/etc/gps.conf` |

两点声明：容器里跑的是**厂商原版 Android 镜像**，`device/leeco/...` 是它源码树里的对应版本（日志里的 `open:413:11` 与树里的 `LocApiV02.cpp:411-413` 只差两行，指向同一段代码）；**这一轮没有碰设备**。

## 1. 那行 QMI 错误是**非致命**的，而且它证明 QMI client 开成功了

`LocApiV02::open(LOC_API_ADAPTER_EVENT_MASK_T mask)` 的顺序（`LocApiV02.cpp:261-430`）：

```c
status = locClientOpen(mQmiMask, &globalCallbacks, &clientHandle, (void *)this);
if (eLOC_CLIENT_SUCCESS != status || clientHandle == LOC_CLIENT_INVALID_HANDLE_VALUE) {
    mMask = 0; mQmiMask = 0;
    LOC_LOGE ("%s:%d]: locClientOpen failed, status = %s\n", ...);
    rtv = LOC_API_ADAPTER_ERR_FAILURE;          // <-- 只有这一处会让 open() 失败
} else {
    status = locClientSupportMsgCheck(...);     // 失败只打日志
    if (eLOC_CLIENT_SUCCESS != status)
        LOC_LOGE("%s:%d]: Failed to checking QMI_LOC message supported. \n", ...);

    if (batching 支持) { locSyncSendReq(QMI_LOC_QUERY_AON_CONFIG_REQ_V02, ...); }   // 失败只打日志

    status = locSyncSendReq(QMI_LOC_GET_SUPPORTED_FEATURE_REQ_V02, ...);
    if (eLOC_CLIENT_SUCCESS != status) {
        LOC_LOGE("%s:%d:%d]: Failed to get features supported from "
                 "QMI_LOC_GET_SUPPORTED_FEATURE_REQ_V02. \n", ...);   // <-- 设备上那一行
    } else { ...保存 feature 表... }
}
...
return rtv;     // rtv 只在 locClientOpen 失败时被置成 FAILURE
```

读数：

* 那行错误在 **`else` 分支里** —— 能打出来，就意味着 `locClientOpen()` **返回了成功**、`clientHandle` 有效。所以 `56` §5 写的"向 modem/位置子系统开 QMI 通道时失败"**读反了**：QMI client 是开着的。
* 这条消息只影响**一条特性查询**（`GET_SUPPORTED_FEATURE`）。后面的事（设位置模式、注册事件掩码、启动）都不依赖它：`open()` 照样返回成功，`rtv` 只有 `locClientOpen` 那条路会变。
* 因此**它不是"GPS 没有定位"的原因**。真正没发生过的动作是 `gnssStart` / `u_hardware_gps_start` —— 那是"有人要位置"之后才会走的。

要判别的只有一条：设备日志里**有没有** `locClientOpen failed`。有 → QMI 通道真没开（那才是 modem 侧问题）；没有 → 这一环通的。

## 2. UT 这一侧：开关在哪，仪器是什么

从 rootfs 镜像里读出来的现状（全部是设备上真实安装的东西）：

**a. 单元与 wrapper。** `lomiri-location-service.service` 的 `ExecStart` 被一个 drop-in 换掉了（`usr/lib/systemd/system/lomiri-location-service.service.d/lxc-android-config.conf`，注意目录名是**完整的单元名 + `.service.d`**）：

```sh
# /usr/libexec/lxc-android-config/lomiri-location-serviced-wrapper
if getprop custom.location.fake = true; then
    exec lomiri-location-serviced --bus system --provider dummy::Provider \
         --dummy::Provider::ReferenceLocationLat="$lat" --dummy::Provider::ReferenceLocationLon="$lon"
else
    exec lomiri-location-serviced --bus system --provider gps::Provider --provider remote::Provider
fi
```

* 默认（非 fake）走的就是 **`gps::Provider`** —— 所以"provider 没配"这个嫌疑不存在。
* **`custom.location.fake=true` 是这条线上最干净的一个杠杆**：它把整个 UT 定位栈（daemon → engine → 客户端那条 D-Bus 路）用**一个假坐标**跑起来，完全不碰 Android GPS。它给出一个二分的上半截：**假坐标能出来 → UT 这一侧是好的，故障在 HAL 那一侧；连假坐标都出不来 → 故障在 HAL 以上。** 代价是它要重启一次 location 服务（dbus 激活的服务，运行时操作、可逆）。

**b. `gps::Provider` 里面是什么**（`liblomiri-location-service.so.3.0.0` 的符号与字符串）：

* 未定义符号里有全套 `u_hardware_gps_*`（`new`/`start`/`stop`/`set_position_mode`/`inject_*`/`agps_*`）→ UT 这侧通过 **platform-api** 说话；
* `libubuntu_platform_hardware_api.so.4.0.0` 定义了这 14 个 `u_hardware_gps_*`，而它的未定义符号只有 `android_dlopen` / `android_dlsym` —— 这些函数体都是小跳板（每个 ~0x160 字节），**最后一步是 hybris 载入 Android 侧的库**。也就是说 `u_hardware_gps_start` 是"UT→Android 的那个门"，从没被调用过 = **这扇门从没被敲过**。
* 字符串里还有 `gps::android::HardwareAbstractionLayer`、`SntpReferenceTimeSource`、`GpsXtraDownloader`、`/etc/gps.conf` —— 与下面 §4 对得上。

**c. `lomiri-location-serviced-cli` 的真实能力**（`strings` 出来只有这三条）：

```
Usage: lomiri-location-serviced-cli [options] <command>
   session ...
   does_satellite_based_positioning [get/set]
   does_report_wifi_and_cell_ids [get/set]
```

**它不能请求位置**，它是一个**开关工具**。这件事很重要，因为它给了"`u_hardware_gps_start` 从没被调用"一个具体的、可读的嫌疑：**`does_satellite_based_positioning` 如果是 `false`，卫星定位那一路本来就不会被启动**。先 `get` 一下这个值，比任何猜测都便宜。（`does_report_wifi_and_cell_ids` 同理管 Wi-Fi/基站定位。）

**d. `test_gps`**（`/usr/bin/test_gps`，rootfs 自带）是**硬件那一半**的仪器，它绕过 UT 全栈、直接走 Android 的 `gps.h`：

```
*** get gps interface        / *** GPS interface not found :(
*** init gps interface
*** set up agps interface / server / agps ril interface
*** start gps track
*** gps tracking started
用法: -a agps, -c 冷启动, -s <agps_server:port>, -r agpsril, -x Xtra, 无参数=standalone
```

它和 UT 那条路**不一定打到同一个 HAL 实现**（UT 那边是 HIDL `android.hardware.gnss@1.0`（`56`：`vendor.qti.gnss@1.0-service` → `LocSvc_ApiV02`），`test_gps` 走的是 legacy `hw_get_module("gps")`），所以 `test_gps` 成功**不自动**等于 UT 能用、失败也**不自动**等于硬件坏。它是一个便宜的"这颗芯片这条链子下面有没有反应"的探针。

## 3. `/etc/gps.conf`：只有 XTRA，没有 SUPL

rootfs 里的那份（413 字节）内容就是三个 XTRA 服务器（`xtra1/2/3.gpsonextra.net`）加 `XTRA_SERVER_QUERY=0`。**没有 `SUPL_HOST`** 之类的行。这影响的是 AGPS 加速（首次定位时间），不是"能不能定位"：standalone 定位不需要它。记住这一点是为了以后不要把它当成"GPS 不工作"的原因。

## 4. 下一步该量的四件事（按便宜程度排序，都不需要改任何东西）

| # | 量什么 | 怎么量 | 它排除什么 |
|---|---|---|---|
| 1 | `does_satellite_based_positioning` 是 `true` 还是 `false` | `lomiri-location-serviced-cli does_satellite_based_positioning get`（用会话用户的 D-Bus） | 如果是 `false`，这就是"从没 start"的全部原因，而且改它是 `set true` |
| 2 | 日志里有没有 `locClientOpen failed` | logcat 计数（§1 唯一的判别行） | QMI 通道到底开没开 |
| 3 | 有没有客户端要过位置 | 让一个客户端请求一次定位，同时看 logcat 有没有 `gnssStart`/HAL 的 start 行 | "没人要过" vs "要了但没起来" |
| 4 | `test_gps -c` 有没有反应 | 设备上跑它（hybris 环境），看 `*** start gps track` 之后有没有 SV/位置 | 芯片/固件/HAL 这一层有没有活着 |

**§2a 的假坐标杠杆**单独列在这里，因为它的价值是把第 3 条的上半截钉死：假坐标能出来 → UT 栈是好的。

## 5. 复现

```sh
# 只读的一轮（不动任何东西）
scp scripts/device/zl1-gps-probe.sh root@10.15.19.82:/tmp/
ssh root@10.15.19.82 'sh /tmp/zl1-gps-probe.sh'

# 硬件那一半（会真的启动一次 GPS 跟踪，可逆、无副作用）
ssh root@10.15.19.82 'sh /tmp/zl1-gps-probe.sh --test-gps'
```

| 文件 | 作用 |
|---|---|
| `scripts/device/zl1-gps-probe.sh` | 新增。**只读**地收集 §4 的 1–3 项：单元的真实 `ExecStart`（`systemctl cat`，这是判断 drop-in 生效没有的唯一诚实办法）、daemon 的 pid 与它所在的 PID namespace、两个开关（`lomiri-location-serviced-cli ... get`）、logcat 里六个关键字符串的计数（含 §1 那个判别行）、`custom.location.*` 属性（**在容器里读**，见 [[zl1-android-properties-are-only-visible-in-the-container]]）、以及 GNSS HIDL 服务在不在（`nsenter -p -m` 下的 `lshal`）。`--test-gps` 才跑 `/usr/bin/test_gps -c` |
| `docs/ubuntu-touch/82-*.md` | 本篇 |

## 6. 这一轮**不**证明什么

* **没有在设备上量任何东西**（设备在 EDL，需要手动复位）。§1 是**读源码**的结论，§2 是**读 rootfs 镜像**的结论。
* **不证明 `locClientOpen()` 在设备上成功了**：证明的是"**那行错误能被打印出来** ⇒ 走进了 `else` 分支 ⇒ `locClientOpen` 返回成功"。设备上真的调用了 `open()` 且真的走进了那个分支，这一点由 `56` 记录的那行日志保证；但"日志里没有 `locClientOpen failed`"这句话本身我**还没查过**（查它是 §4 第 2 项）。
* **不证明 `test_gps` 能拿到位置**，也不证明它和 UT 那条 HIDL 路打的是同一个 HAL（§2d）。
* **不证明那两个开关的当前值**是 `true`（§4 第 1 项就是去读它）。
* 不证明 modem 那一侧是好的：`GET_SUPPORTED_FEATURE` 这一条 QMI 消息失败是**事实**（虽然非致命），它的原因（modem 不支持？PDK 差异？）没有查。
