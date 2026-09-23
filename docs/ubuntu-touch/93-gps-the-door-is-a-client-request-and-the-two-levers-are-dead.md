# 93 — GPS 的门是一次**客户端请求**，而这台设备上那两把"试验钥匙"都插不进去

**日期**: 2026-09-23
**状态**: 纯离线的一轮（设备在 EDL，与 `86`–`92` 同）。`82` 把 GPS 的问题拆成了两半（UT 侧 / Android HAL 侧），并留下一条要在设备上读的线（`does_satellite_based_positioning`）。这一轮回答的是**在那条线之前**的问题，而且不需要设备就能回答完：

> **`u_hardware_gps_start()` 是谁调的？在这台设备上，要让这次调用第一次发生，必须发生什么？**

答案是一道门和一把锁，都可以从镜像里读出来。门是**一次客户端请求**（D-Bus 上的 `StartPositionUpdates`），锁是 `TrustStorePermissionManager`——而 `82` 推荐的两把"试验钥匙"（`custom.location.testing` 的豁免、`custom.location.fake` 的假位置 A/B）**在这台设备上根本插不进去**，因为 v63 引导镜像每次开机都会把 `/usr/bin/getprop` 换成一个只会回答 `ro.*` 的壳脚本。这两把钥匙是镜像自己提供的，坏掉的不是属性值，是**问属性的那个工具**。

**接续**: [`82`](82-the-gps-line-read-the-source-and-the-rootfs.md)（要读 `locClientOpen failed`、那两把钥匙、两个仪器）、[`55`](55-the-bridge-libraries-built-and-hwbinder-does-not-cross-pid-namespaces-either.md)（桥接库）、[`56`](56-the-two-services-move-into-the-containers-pid-namespace.md)（两个服务搬进容器的 PID 命名空间）。证据原文在 `docs/ubuntu-touch/evidence/location-chain-2026-09-23.log`。

---

## 1. 一句话结论

**从客户端到硬件，这条链上的每一环都有名字，而且只有一条路：**

| # | 环节 | 在已安装二进制里的地址 / 名字 |
|---|---|---|
| 1 | 客户端在**会话对象**上调 `StartPositionUpdates` | D-Bus 接口 `com.lomiri.location.Service.Session` |
| 2 | `service::session::Skeleton::on_start_position_updates` | 符号在 `liblomiri-location-service.so.3.0.0` |
| 3 | `service::session::Implementation::start_position_updates()` | `0x8f0e4`（384 B） |
| 4 | engine 选 provider → `providers::gps::Provider::start_position_updates()` | `0xe7f10`（40 B） |
| 5 | **虚调用**进 HAL 的 vtable 槽 | `.data.rel.ro` 文件偏移 `0x15e580`，槽里是 `0xdaa80` |
| 6 | `HardwareAbstractionLayer::start_positioning()` | `0xdaa80`（368 B） |
| 7 | 里面：`Impl::register_callbacks()` → `bl 0x33a70` = **`u_hardware_gps_new`** | `0xdaa40`（64 B），`bl` 在 `0xdaa64` |
| 8 | 里面：尾部 `b 0x33610` = **`u_hardware_gps_start`** | `0xdaa84`（`0x33610` 是它的 PLT 桩） |
| 9 | `libubuntu_platform_hardware_api.so.4` → `android_dlopen/dlsym` | 容器里的 HIDL `android.hardware.gnss@1.0` |

三句话：

1. **`u_hardware_gps_new` 和 `u_hardware_gps_start` 都只在 `start_positioning()` 里，而 `start_positioning()` 只在一次客户端请求里被虚调用。** 守护进程**启动**的时候一件事都不碰硬件——建 provider、占 D-Bus 名字、开 bus，都不会调用这两个函数（§2）。所以"这台设备上硬件那一半从来没被要求做过任何事"是一个**结构性的结论**，不是关于 HAL 的猜测。
2. **门前面有一把默认关着的锁，而且在任何会话对象存在之前就检查。** `CreateSessionForCriteria` 第一件事就是 `check_permission_for_credentials`；拒绝时抛的那句话在二进制里：`Client lacks permissions to access the service with the given criteria`。用的是 `TrustStorePermissionManager`（不是"没有 trust-store"那个构建），它有**三道闸，任何一道不过都返回 `rejected`**（§3）。其中第一道就是镜像自己留的豁免开关。
3. **镜像留的两把钥匙都依赖 `getprop`，而 `getprop` 在这台设备上不是镜像里那个二进制。** v63 的 `zl1-postswitch-debug-init` 每次开机把 `/usr/bin/getprop` 覆盖成一个壳脚本，它的 `case` 表里**没有** `custom.*` 这一支，落到 `*)` 之后因为 wrapper 没给第二个参数而**什么都不打印**；`setprop` 干脆是 `exit 0`。于是 `custom.location.testing` 永远不等于 `true`、`custom.location.fake` 永远不等于 `true`（§4）。**两把钥匙同时失效，而且失效在同一个地方。**

## 2. 门：`u_hardware_gps_start()` 是怎么被走到的

### 2.1 服务确实带着硬件 provider

单元 `/usr/lib/systemd/system/lomiri-location-service.service` 自己写着

```
ExecStart=/usr/bin/lomiri-location-serviced --bus system --provider gps::Provider --provider remote::Provider
```

而它的 drop-in `lomiri-location-service.service.d/lxc-android-config.conf` 把 `ExecStart` 换成了 wrapper `lomiri-location-serviced-wrapper`；wrapper 的 `else` 支（也就是这台设备上**唯一**会走到的支，见 §4）逐字就是同一行。这个单元是**已启用**的：`/etc/systemd/system/multi-user.target.wants/lomiri-location-service.service` 存在。

### 2.2 硬件代码在**服务库**里，不在 `providerd` 里

`lomiri-location-service-providerd` 是 **remote** provider 那一半：它既没有 `libubuntu_platform_hardware_api` 的 `NEEDED`，`strings` 里也一个 `u_hardware` 都没有。全镜像里只有两个目标引用平台 API——**那个库本身**和 API 库自己：

```
$ grep -rl libubuntu_platform_hardware_api $R/usr/lib $R/usr/bin
usr/lib/aarch64-linux-gnu/liblomiri-location-service.so.3.0.0
usr/lib/aarch64-linux-gnu/libubuntu_platform_hardware_api.so.4.0.0
```

而 13 个 `u_hardware_gps_*` 是这个库的普通 `UND` 动态符号（所以是正常 PLT 调用，不是 `dlsym`）。

### 2.3 两个调用点，都在同一个函数里

重建 PLT 映射（`.plt` 在 `0x33510`，前 32 字节是解析器，第 i 个桩在 `0x33530 + 16i`，读 GOT `0x16f048 + 8i`）：

```
u_hardware_gps_start   重定位序号 14 → 桩 0x33610，GOT 0x16f0b8
u_hardware_gps_new     重定位序号 84 → 桩 0x33a70，GOT 0x16f2e8
```

两个调用点：

```
$ llvm-objdump-14 -d liblomiri-location-service.so.3.0.0 | grep -n 0x33610
  dab84:  b   0x33610      <-- 尾调用，在 start_positioning() 内
$ llvm-objdump-14 -d liblomiri-location-service.so.3.0.0 | grep -n 0x33a70
  daa64:  bl  0x33a70      <-- 在 Impl::register_callbacks() 内
```

`readelf -sW` 给这两个符号的边界是 `0xdaa40 + 0x40`（`register_callbacks`）和 `0xdaa80 + 0x170`（`start_positioning`）——两个 `bl`/`b` 都落在 `start_positioning` 的范围内。**建（`new`）和启（`start`）都在 `start_positioning()` 里**。

**它是虚函数**：地址 `0xdaa80` 在 `.text` 里只作为调用目标出现一次，在 `.data.rel.ro` 里出现一次——文件偏移 `0x15e580`，落在 `HardwareAbstractionLayer` 的 vtable 里（相邻槽是 `0xda910 set_assistance_mode`、`0xda9c0 set_position_mode`）。所以第 5 步是一次**虚调用**，这也是为什么"谁调它"这个问题不能在 `.text` 里 grep 出来，只能顺着 vtable 和符号表往上找。

### 2.4 这条链上每一环都有符号，所以中间步不是猜的

`liblomiri-location-service.so.3.0.0` 的符号表里，从会话到 provider 的每一步都在：

```
com::lomiri::location::service::session::Implementation::start_position_updates()
com::lomiri::location::providers::gps::Provider::start_position_updates()
com::lomiri::location::providers::gpsd::Provider::start_position_updates()
com::lomiri::location::providers::dummy::Provider::start_position_updates()
com::lomiri::location::providers::remote::Provider::Stub::start_position_updates()
com::lomiri::location::providers::remote::Provider::Skeleton::start_position_updates()
com::lomiri::location::FusionProvider::start_position_updates()
com::lomiri::location::ProxyProvider::start_position_updates()
com::lomiri::location::Provider::Controller::start_position_updates()
```

（这也顺带解释了 `--provider dummy::Provider` 为什么是一次**完整 UT 栈**的 A/B：`dummy::Provider` 有它自己的 `start_position_updates()`，只是不去碰 Android。）

## 3. 锁：`TrustStorePermissionManager`，三道闸

### 3.1 检查发生在会话存在之前

`service/skeleton.cpp` 的 `handle_create_session_for_criteria()`：

```cpp
Criteria criteria;
in->reader() >> criteria;

auto credentials =
    configuration.credentials_resolver->resolve_credentials_for_incoming_message(in);

auto result =
    configuration.permission_manager->check_permission_for_credentials(criteria, credentials);

if (PermissionManager::Result::rejected == result) throw std::runtime_error
{
    "Client lacks permissions to access the service with the given criteria"
};
```

`throw` 落进同一个函数的 catch-all，回给客户端的是**不泄漏内情的**一句

```
com.lomiri.location.Service.Error.CreatingSession / "Error creating session"
```

真正的原因只写进服务端日志。两句字符串都能在已安装的二进制里找到（`fcbb0` / `fca08`）。

### 3.2 用的确实是 trust-store 那个 manager

这是**编译期**决定的，不是运行期：

```cpp
clls::SystemConfiguration& clls::SystemConfiguration::instance()
{
#ifdef ENABLE_TRUST_STORE
    static UbuntuSystemConfiguration config;   // → TrustStorePermissionManager
#else
    static DefaultSystemConfiguration config;  // → DefaultPermissionManager
#endif
    return config;
}
```

而同一个包的 `debian/rules` 明写

```
-DENABLE_TRUST_STORE=ON \
```

### 3.3 三道闸，任何一道不过都是 `rejected`

`trust_store_permission_manager.cpp`：

```cpp
if (is_running_under_testing())
    return Result::granted;

if (credentials.profile.empty()) {
    SYSLOG(ERROR) << "Could not resolve PID " << credentials.pid << " to apparmor profile";
    return service::PermissionManager::Result::rejected;
}
...
try { auto answer = agent->authenticate_request_with_parameters(params); ... }
catch(...) { /* We silently drop all issues here and return rejected. */ }
```

按顺序：

1. **环境变量豁免**：`is_running_under_testing()` 读的是 `TRUST_STORE_PERMISSION_MANAGER_IS_RUNNING_UNDER_TESTING == "1"`（这个字符串就在二进制 `101e48`）。这是**镜像自己留的**开关。
2. **调用者必须有非空 AppArmor profile**：`skeleton.cpp` 里用 `aa_gettaskcon(pid, ...)` 取；失败就 log `Could not resolve PID <pid> to apparmor profile: <e>` 并把字符串留空——空字符串正好撞上这道闸。
3. **trust store 的答复**：`core::trust::dbus::create_multi_user_agent_for_bus_connection(bus, trust_store_service_name)` 去问 trust-store agent；**任何异常都被吞掉变成 `rejected`**，客户端看不到区别。

trust-store 这一侧在这台设备上是**接好线**的——不是空挂：`data/com.lomiri.location.Service.conf` 允许 `core.trust.dbus.Agent.LomiriLocationService`，用户单元 `lomiri-location-service-trust-stored.service`（`trust-stored-skeleton --for-service LomiriLocationService --remote-agent DBusRemoteAgent --local-agent MirAgent`）在 `graphical-session.target.wants` 里是**已启用**的（还有一个 `-wayland` 变体，靠 `ConditionPathExists=/run/user/%U/mir_socket_trusted` 二选一），而 `lomiri-indicator-location.service` 也在 `lomiri-indicators.target.wants` 里已启用，还带 `/etc/xdg/autostart/lomiri-indicator-location.desktop`。也就是说：**谁来回答"允许吗"这件事，系统是有安排的**；而没有安排的是——**第一次请求从哪里来**。

## 4. 为什么这道锁在这台设备上是关着的：两把钥匙同时失效

wrapper 逐字是这样的：

```sh
if [ -x /usr/bin/getprop ] && [ "$(getprop custom.location.testing)" = "true" ]; then
    export TRUST_STORE_PERMISSION_MANAGER_IS_RUNNING_UNDER_TESTING="1"
fi

if [ -x /usr/bin/getprop ] && [ "$(getprop custom.location.fake)" = "true" ]; then
    lat="$(getprop custom.location.lat 51.505660)"
    lon="$(getprop custom.location.lon -0.099850)"
    exec lomiri-location-serviced --bus system --provider dummy::Provider ...
else
    exec lomiri-location-serviced --bus system --provider gps::Provider --provider remote::Provider
fi
```

镜像发货时这两把钥匙都在：`testing` 豁免第一道闸，`fake` 给出一整个不碰 Android 的假位置栈。**但两个 `getprop` 都不是镜像里那个二进制。**

`boot/v63/scripts/init-bottom/zl1-postswitch-debug-init` 每次开机（这一段在 `if [ -d /var/lib/lxc/android/pre-start.d ]` 里，而那个目录在本端口存在；它前面还先 `mount -o remount,rw /`，这也解释了为什么一个"只读镜像"能被写）会把 `/usr/bin/getprop`、`/usr/bin/setprop` 覆盖成壳脚本。它的全部判断表是：

```sh
prop="${1:-}"
default="${2:-}"
case "$prop" in
    '') exit 0 ;;
    ro.build.version.sdk) printf '%s\n' 28 ;;
    ro.product.device|ro.product.vendor.device|ro.product.odm.device) printf '%s\n' le_zl1 ;;
    ro.product.name|ro.product.vendor.name|ro.product.odm.name) printf '%s\n' ZL1_CN ;;
    ro.product.model|ro.product.vendor.model) printf '%s\n' 'LeEco Pro3' ;;
    ro.hardware|ro.boot.hardware) printf '%s\n' qcom ;;
    ro.treble.enabled) printf '%s\n' true ;;
    ro.vndk.version) printf '%s\n' 28 ;;
    sys.boot_completed|dev.bootcomplete|service.bootanim.exit)
        [ -n "$default" ] && printf '%s\n' "$default" ;;
    init.svc.*|vendor.*|persist.*|ctl.*|debug.*|test.*)
        [ -n "$default" ] && printf '%s\n' "$default" ;;
    *) [ -n "$default" ] && printf '%s\n' "$default" ;;
esac
exit 0
```

`custom.location.testing` 和 `custom.location.fake` 都落到 `*)`。wrapper 两次调用**都没有给第二个参数**，所以 `$default` 为空 → **什么都不打印**，`exit 0`。两个比较永远不成立。`setprop` 在同一个脚本里被显式写成 no-op（`log "no-attach diagnostic no-op setprop: $*"; exit 0`），所以也**设不进去**。

**结论：在这台设备上，wrapper 永远走 `else` 支，`TRUST_STORE_PERMISSION_MANAGER_IS_RUNNING_UNDER_TESTING` 永远是关的。** 于是：

* 第一道闸永远不豁免；
* 任何调用者要么过不了第二道闸（`aa_gettaskcon` 答不出来 → 空 profile），要么落到第三道闸去问一个从来没有被回答过的 trust store；
* 两条路的终点都是 `rejected`，客户端只看到 `Error creating session`。

这就是 `82` §2 那句"没有客户端要过位置"的**结构性版本**：不只是"没有客户端来敲"，而是**门上的锁默认是关的，而镜像自己那两把钥匙被开机脚本挡住了**。

## 5. 由此得到的两把真钥匙（两个 drop-in，都还没装）

`/etc/systemd/system` 是本端口少数几个可写白名单路径之一（`zl1-etc-is-read-only-with-rw-bind-mounts`），而且 drop-in 目录必须是**完整单元名**（`lomiri-location-service.service.d`，写成 `lomiri-location-service.d` 是静默失效的）。

**钥匙 A：绕过 `getprop`，直接把豁免放进服务自己的环境。**

```ini
# /etc/systemd/system/lomiri-location-service.service.d/zl1-testing.conf
[Service]
Environment=TRUST_STORE_PERMISSION_MANAGER_IS_RUNNING_UNDER_TESTING=1
```

`is_running_under_testing()` 读的就是**服务进程自己的环境**，所以 systemd 能设。效果：第一道闸对**任何**调用者返回 `granted`，于是连一个 unconfined 的 root shell 也能建会话、开位置更新——而那就是第一次调用 `u_hardware_gps_new`/`u_hardware_gps_start` 的那一刻。

**这是一个权限旁路**：drop-in 在位期间，设备上任何进程都能拿到位置。这跟 `orientationsensor=False` 和"退役 debug keeper"是同一类决定——**要用户点头，不能自己装**。

**钥匙 B：不走属性，直接换 `ExecStart`（假位置 A/B）。**

```ini
# /etc/systemd/system/lomiri-location-service.service.d/zl1-dummy.conf
[Service]
ExecStart=
ExecStart=/usr/bin/lomiri-location-serviced --bus system \
          --provider dummy::Provider \
          --dummy::Provider::ReferenceLocationLat=51.505660 \
          --dummy::Provider::ReferenceLocationLon=-0.099850
```

（空的那行 `ExecStart=` 是**重置**列表用的；少了它 systemd 会追加第二条命令。）这就是 wrapper 在属性可读时本来会跑的那条命令，所以它走的是一整条 UT 栈而完全不碰 Android——`82` 想要的那个 A/B，用不着改引导镜像就能恢复。

注意 **B 前面还是站着那把锁**：`dummy::Provider` 一样要先过 `CreateSessionForCriteria` 的权限检查，所以要有 A 才能被客户端看见。这顺带说明：**"假位置"那个实验在本端口即使把命令换对了，也照样不会出结果**——这是它没结果的两个独立原因之一。

## 6. 还差什么才能把这个实验做完

一条链，两个动作，一个判据：

1. **钥匙 A 装上**（用户决定），`systemctl daemon-reload` + 重启 `lomiri-location-service`；
2. **一个真的会要位置的客户端**。镜像里 `lomiri-location-serviced-cli` 要不了（它的命令面只有 `session`、`does_satellite_based_positioning [get/set]`、`does_report_wifi_and_cell_ids [get/set]`）。但 **Qt 那一侧是齐的**：`libqtposition_lomiri.so`（插件 key 就是 `"lomiri"`，见它的内嵌元数据 `"Keys": ["lomiri"]`、`"Provider": "lomiri"`、`"Position": true`）是 `QGeoPositionInfoSourceFactory`，`qml-module-qtpositioning` 在，`/usr/lib/qt5/bin/qmlscene` 是**真的 aarch64 二进制**，offscreen 平台插件也在。所以一个 `PositionSource { name: "lomiri"; active: true }` 的 QML 文件就是那个客户端——它用的是**已经构建好的客户端库**，因此不需要猜 `Criteria` 在 D-Bus 上怎么编组。
3. **判据**：请求之后，`lomiri-location-service` 自己的日志里有没有新会话；以及 Android 侧 GNSS HAL 有没有被叫起来。`scripts/device/zl1-location-request.sh` 就是做这三件事的（默认只读：`--status` 把上面每一环的状态打出来，`--request` 才发请求）。

| 文件 | 作用 |
|---|---|
| `scripts/device/zl1-location-request.sh` | 新增。`--status`（默认，只读）把 §2/§3/§4 的每一环逐条打出来——单元是否启用、真实 `ExecStart`、drop-in 在不在、`getprop` 是不是 v63 那个壳脚本、两个属性读出来是什么、服务与 trust-store agent 在不在总线上、`libubuntu_platform_hardware_api` 有没有映射进进程；`--request` 用 `PositionSource{name:"lomiri"}` 的 QML 客户端（`qmlscene` + offscreen）真的要一次位置，并对比服务 pid/重启计数、打服务日志；`--enable-testing`/`--disable-testing` 装/卸豁免 drop-in；`--explain` 只打印两个 drop-in 和代价，什么都不做 |
| `docs/ubuntu-touch/evidence/location-chain-2026-09-23.log` | 新增。这一轮的全部原始证据：七个二进制的 sha256 与版本、PLT 映射的重建过程与两个调用点、vtable 槽、`readelf` 的符号边界、三个上游源码文件的 sha256 与逐段引用、v63 壳脚本的完整 `case` 表 |

## 7. 这一轮**不**证明什么

* **不证明硬件一旦被问就能工作。** 它证明的是"要问哪个调用、以及这台设备从没问过"，不是"问了就有 fix"。
* **不证明设备当前缺的**就是一次会话请求——只证明那是门，且锁默认关着。能分开两者的实验是 §6 的三步。
* **对 Android 侧什么也没加**：`u_hardware_gps_start` 返回什么、QMI 客户端开不开、有没有 fix，都是 `82` 那条 `locClientOpen failed` 的事。
* **没有在设备上量过任何东西**（设备整轮都在 EDL）：`aa_gettaskcon` 对一个 root shell 是成功还是失败没测。两种结果都与上面的代码相容——它决定的是**哪一道闸**在拒，不是**有没有**在拒。
* **那个 QML 客户端没有被任何 Qt 运行时跑过。** 它用到的类型/属性/信号（`PositionSource`、`position`、`active`、`valid`、`updateTimeout`、`sourceError`、`supportedPositioningMethods`、`positionChanged`/`sourceErrorChanged`/`validityChanged`）是逐个对着镜像里的 `plugins.qmltypes`（导出为 `QtPositioning/PositionSource 5.0`）和 `libQt5PositioningQuick.so.5.15.13` 里真实存在的信号名核过的，插件 key `"lomiri"` 来自 `libqtposition_lomiri.so` 自己的内嵌元数据——但"名字都对"不等于"跑起来就对"。`zl1-location-request.sh` 的三种模式是用 stub 过的 `systemctl`/`gdbus`/`getprop`/`qmlscene` 在离线环境里跑过的（包括 `--seconds` 后面没参数这个 `set -u` 陷阱，它当场暴露了一个会直接终止脚本的 `shift` 错误），那只证明脚本自己的逻辑，不证明设备上的结果。
* **没有改任何东西**：两个 drop-in 都只写在这里，没有装；没有重启任何服务；没有碰引导镜像；没有分区写。
