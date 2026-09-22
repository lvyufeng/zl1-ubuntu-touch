# 70 — 横屏是 shell 自己排的版：一次被采纳的方向读数卡住了；重启 shell 回到竖屏，但**底层是方向传感器不报数据**

**日期**: 2026-09-22
**状态**: **竖屏回来了 —— 重启 `lomiri-full-greeter.service` 之后，新 shell 的 qtmir 报的是 `Screen - initial currentOrientation is: Qt::PortraitOrientation`，而且之后没有采纳过任何方向变化，所以版面是竖的。** 机制不是"读一个新值把屏幕扳回来"，而是 `OrientedShell.qml` 里的 `orientation` 只在 `physicalOrientation` **变化**时才被赋值 —— 传感器现在给不出 qtmir 认得的姿态，于是那个变量一直停在它的初值 0（Primary = 竖屏）。
**但这是缓解，不是治本**：`orientationsensor` 现在恒报 `(uptime_µs, 6)`，6 是 `FaceDown`，而手机是平放朝上的；`accelerometersensor` 在 sensorfw 里**根本没注册**，而 `vsimd` 每 5 秒崩一次。方向这条线的根因在传感器数据通路上，§6 是它的现状和下一步。
**接续**: [`69`](69-repowerd-died-on-a-startup-race-with-sensorfwd.md)（黑屏的因：repowerd 死了；屏一亮就露出这一层的横屏）、[`60`](60-sensorfwd-was-the-third-service-behind-the-same-wall.md)（sensorfwd 本身）、[`58`](58-one-cold-boot-where-the-secure-world-refused-and-three-firmwares-did-not-load.md)（安全世界/固件那条线）

---

## 1. 用户报的是"横屏"，先排除显示器

用户确认的原话：**"现在变成横屏了"**、"横着铺开、字是正的"、"刚刚才有"。先量显示器这一侧，三条都是否：

| 检查 | 结果 |
|---|---|
| 合成器输出的模式 | `mirserver: . \|_ Logical size 1080x1920`（首选模式 `1080x1920`），从头没变 |
| qtmir 的屏幕几何 | `PlatformScreen(...) - id: 1 geometry: QRect(0,0 1080x1920) type: "LVDS-1" scale: 2.25`，整份 boot 都一样 |
| 面板自己的旋转字节 | `/sys/class/graphics/fb0/rotate = 0`，`msm_fb_panel_status = alive`，`mode "1080x1920-57"` |
| 日志里出现过 `1920x1080` 吗 | **0 次**（`grep -c 1920x1080` 整份 boot journal） |

**合成器从来没换过几何。** 所以横屏是 **shell 内部自己排的版** —— 它把一个 1080x1920 的缓冲按横的排，然后交给合成器。

## 2. 为什么 shell 会排成横的：一个只在"变化时"赋值的变量

`/usr/share/lomiri/OrientedShell.qml`：

```qml
property int physicalOrientation: QtQuickWindow.Screen.orientation
property int orientation
onPhysicalOrientationChanged: {
    if (!orientationLocked) {
        orientation = physicalOrientation;
    } else { ... }
}
Component.onCompleted: {
    if (orientationLocked) { orientation = orientationLock.savedOrientation; }
    ...
}
```

`orientation` 是 `property int`，**初值 0**（`Qt::PrimaryOrientation`，也就是竖屏），而它**只在 `physicalOrientation` 变化时**被改。所以"屏幕现在横着"这件事只能是"某一刻 `physicalOrientation` 变成了一个横的值，然后 `orientation` 跟着变了，之后再也不变"。

日志里那一刻是唯一一次：

```
[ 385.646759] qtmir.sensor: OrientationSensor::readingChanged
[ 385.663429] qtmir.sensor: PlatformScreen[0x5e3d6b5eb0]::customEvent() - new orientation=Qt::InvertedLandscapeOrientation
```

这就是**整个 boot 里唯一一次被采纳的方向变化**。之后每一次都是：

```
[ 404.197702] qtmir.sensor: ...::customEvent() - unknown orientation.
[ 115.332982] / [ 115.587090] / [ 2218.837162] / [ 2568.911397] / [ 4542.555712] / [ 4907.548381] / [ 5993.785854] ...
```

而 `unknown` **什么都不做**（它不是 `onPhysicalOrientationChanged` 里那个分支能用的值）。于是 `orientation` 从 385 秒起就一直是 `InvertedLandscape`，屏幕也就一直横着。

> 顺带解释一个容易误读的现象：日志里那些 `OrientationSensor::readingChanged` **不是**"来了新数据"，绝大多数紧跟在 `OrientationSensor::onDisplayPowerStateChanged` 后面 —— 是屏幕电源变化时 shell 去**重读那个缓存值**。

## 3. 传感器那边：值恒为 6（FaceDown），而且只有显示电源变化时才刷新

`/SensorManager/orientationsensor` 的属性：

```
$ gdbus call --system ... Get local.OrientationSensor orientation
(<(uint64 4907939888, uint32 6)>,)
```

`(tu)` = (时间戳, 值)。两件事量出来了：

- **时间戳是"取到这次读数时的 uptime（微秒）"**：`4907939888 µs = 4907.94 s`，而 qtmir 在同一时刻的日志是 `[ 4907.942493] ... customEvent()` —— 对得上。更早一次读到的是 `1912687691 µs = 1912.69 s`。所以**它会刷新**，但只在屏幕电源那类事件上刷新，间隔几十分钟。
- **值一直是 6**。6 是 `FaceDown`。手机平放在桌上、屏幕朝上，正确的应该是 5（`FaceUp`）。

还有一条：**`orientationChanged` 信号一次都不发。** 30 秒的 `dbus-monitor --system "interface='local.OrientationSensor'"` 只抓到我自己的连接建立/断开，一条信号都没有。

## 4. 三个"看起来是杠杆、其实不是"的东西

都试过，都写下来免得下次再试：

1. **`gsettings set com.lomiri.touch.system orientation-lock 'PrimaryOrientation'`** —— 运行时**不触发任何重新评估**。schema 里有这个键（枚举 `none` / `PrimaryOrientation` / `LandscapeOrientation` / `PortraitOrientation` / `InvertedLandscapeOrientation` / `InvertedPortraitOrientation`），shell 是在 `Component.onCompleted` 时读的，设完之后日志一条都没变。
2. **`rotation-lock true`** 也一样。同一个 schema 里的这个键更像 lomiri-system-settings 那个开关自己的设置项；`OrientationLock` 这个 QML 单例不在文件系统上（`OrientationLock.qml` 哪儿都没有），它是 `libLomiriSession-qml.so` 提供的，那个 `.so` 里确实有 `rotation-lock` 字符串 —— 但那不重要，因为：
3. **就算把锁打开也没用。** 看 QML：`onOrientationLockedChanged` 在变成锁定时做的是 `orientationLock.savedOrientation = physicalOrientation` —— 它把**当前**的方向存成锁定的方向，而当前是横的。锁定 = 锁在横屏。

所以 gsettings 这条路在这台设备上不通，唯一的杠杆是 shell 重启。

## 5. 修法：重启 shell（结果：竖屏）

`lomiri-full-greeter.service` 是用户单元，`Type=notify`、`Restart=on-failure`、`TimeoutStartSec=120`：

```sh
su -l phablet -c 'XDG_RUNTIME_DIR=/run/user/32011 \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/32011/bus \
  systemctl --user restart lomiri-full-greeter.service'
```

重启后（新 pid 3769171）：

```
qtmir.sensor: Screen - nativeOrientation is: Qt::PortraitOrientation
qtmir.sensor: Screen - initial currentOrientation is: Qt::PortraitOrientation
qtmir.screens: PlatformScreen(0x5b8a785e80) - id: 1 geometry: QRect(0,0 1080x1920) ... scale: 2.25
qtmir.sensor: PlatformScreen[0x5b8a785e80]::customEvent() - unknown orientation.        <- 只有这一种
qml: Calculating new usage mode. Pointer devices: 1 ... root width: 1080 height: 1920
```

服务状态 `Active: active (running)` / `Status: "Lomiri is running and ready to receive connections..."`。因为之后**没有任何**被采纳的方向变化，`orientation` 停在初值 0 = 竖屏。

**为什么重启能行、而"等它自己变回来"不行**：`orientation` 的初值就是竖屏，而它只会被"变化"改写。传感器现在给不出变化，所以初值就是终值。同一件事反过来也说明这条修法是**有条件的**：只要传感器哪天又报一个 qtmir 认得的横的姿态，它还会横回去（385 秒那次就是这么来的）。

**风险评估**（"别拿 GUI 冒险"这条规矩在这里的形状）：shell 重启会短暂清屏并重建 greeter，但设备**不可能因此变砖** —— SSH 与容器都不依赖它，服务本身 `Restart=on-failure`，最坏情况是一次冷启动就能恢复（GUI 自己起得来这件事已经在 [`69`](69-repowerd-died-on-a-startup-race-with-sensorfwd.md) 的前置里验过）。而且这条路本来就在被走过：[`68`](68-the-camera-stage-was-one-cookie-in-the-stub.md) 记着一次 `mirscreencast` 会话就会让 greeter 重建 GLRenderer，它活下来了。

## 6. 底层还没修：传感器数据通路

这一节是留给下一次的，写清楚是因为它是横屏的根，而且它同时是"所有的硬件都能驱动"的一部分。

**（1）`accelerometersensor` 在 sensorfw 里没有注册。** `availableSensorPlugins` 有 9 个（`accelerometersensor alssensor compasssensor gyroscopesensor magnetometersensor orientationsensor pressuresensor proximitysensor rotationsensor`），但 `requestSensor` 的答复是：

```
requestSensor("accelerometersensor", <pid>) = (-1,)
requestSensor("rotationsensor",      <pid>) = (-1,)
requestSensor("orientationsensor",   <pid>) = (4,)        <- 这个有，返回 session id
sensorfw: SensorManagerError: "requested sensor id 'accelerometersensor' not registered"
sensorfw: SensorManagerError: "requested sensor id 'rotationsensor' not registered"
```

也就是说：**只有 `magnetometersensor` 和 `orientationsensor` 注册了**（`busctl --system tree com.nokia.SensorService` 也只有这两个对象）。`30-hidl.conf` 里写的是 `accelerometeradaptor = hidlaccelerometeradaptor`，所以是 adaptor 起来时没成功注册。

**（2）`vsimd` 在崩循环。** 容器里每 ~5 秒一次：

```
F linker  : CANNOT LINK EXECUTABLE "/vendor/bin/vsimd": library "libQSEEComAPI.so" not found
```

而**那个文件是存在的**：`/vendor/lib64/libQSEEComAPI.so`（31352 字节，主机和容器里都看得到）。所以这不是"镜像少一个库"，是**链接器/命名空间那一类问题** —— 和 [`66`](66-the-input-layer-vendor-symbol-was-libinputservice.md) 的 `DT_NEEDED` 传递、[`55`](55-the-bridge-libraries-built-and-hwbinder-does-not-cross-pid-namespaces-either.md) 的 `pc=0x0` 是同一族。`/dev/qseecom` 在（`crw------- root root 234,0`），`slpi` 子系统 `ONLINE`，所以 TEE 那一侧看起来是好的。

**（3）有东西在永远等 `system_server` 才提供的服务。** 容器 logcat 里稳定刷：

```
W ServiceManagement: Waited one second for android.frameworks.sensorservice@1.0::ISensorManager/default. Waiting another...
```

这是 `android.frameworks.sensorservice` 的 HAL，**由 system_server 注册** —— 这个容器没有 system_server（已经是 [`65`](65-the-camera-was-blocked-on-four-system-server-services.md)/[`67`](67-the-preview-started-it-was-a-sched-fifo-request.md) 那条线的老问题）。发出这条的进程是 pid 476（已退出，抓不到 `cmdline`）。**同一个形状的问题可能也要 `service-stub` 出面**，但先要弄清是谁在等、它等的那个 HAL 是不是传感器数据通路上的一环 —— 不要在没量清楚之前加第六个名字。

**（4）还差一只手的那 20 秒。** 设备上有一个每秒采一次的记录在跑（`/userdata/zl1-orient-poll3.log`，900 秒）。**把手机竖着拿 20 秒**，然后再读：

- 值变成 1（Portrait）→ 传感器是准的，问题只在"平放时算出来的姿态"，那 §5 的修法就是长期解；
- 值**仍然是 6**，或变成别的错的 → 加速度计那条路确实没数据（或者坐标矩阵错），按上面 (1)(2)(3) 往下查。

`30-hidl.conf` 里加速度计的是单位阵 `transformation_matrix = "1,0,0,0,1,0,0,0,1"`（磁力计是 `"-1,0,0,0,1,0,0,0,1"`）—— 如果最后证实是符号反了，那是这一行的活；但**在那 20 秒之前不动它**。

## 7. 文件与复现

| 文件 | 作用 |
|---|---|
| `docs/ubuntu-touch/evidence/repowerd-ordering-2026-09-22.log` | 上一轮的证据集；§2 的横屏日志和 §5 的方向读数引的都是它或者本轮现场（设备上 `/userdata/zl1-orient-poll3.log`） |

```sh
# 看 shell 现在是什么方向（判据是它自己报的 currentOrientation）
journalctl -b -o short-monotonic _COMM=lomiri | grep -E "nativeOrientation|currentOrientation|new orientation=|unknown orientation"

# 读方向传感器的原始值（时间戳 = 取到读数时的 uptime 微秒）
gdbus call --system --dest com.nokia.SensorService --object-path /SensorManager/orientationsensor \
  --method org.freedesktop.DBus.Properties.Get local.OrientationSensor orientation

# 从横屏回到竖屏（§5）
su -l phablet -c 'XDG_RUNTIME_DIR=/run/user/32011 \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/32011/bus \
  systemctl --user restart lomiri-full-greeter.service'
```

**设备安全**：只往 `/userdata/` 写（三个 poll 日志）。只读地看 `/proc`、`/sys`、journal、容器 logcat、`/vendor`。做过两件会改变设备状态的事，都可逆：**重启了 `lomiri-full-greeter.service`**（用户单元，`Restart=on-failure`，起来后 `Status: "Lomiri is running and ready to receive connections..."`），以及**用 repowerd 自己的 DBus 接口把显示按住**（`keepDisplayOn`，返回 request id）。另外对 `orientationsensor` 调过一次 `start`（传感器是只读的）。`/dev/fb0/rotate`、面板模式、`/etc/sensorfw/` 全部没动。**没有碰任何分区、没有动 boot 镜像、没有改容器内的文件。** 设备没有变砖，容器 RUNNING，`systemctl --failed` 为空，SSH 正常。

## 8. 下一步

1. **那 20 秒的手动测量**（§6 (4)）—— 决定 §5 的修法是长期解还是只治症状。
2. **`accelerometersensor` 为什么没注册**（§6 (1)）：sensorfw 在 `--log-level=warning` 下没留下可用的行（unit 的 journal 甚至报 `-- No entries --`，因为 `nsenter` wrapper 的 `comm` 不是它），所以下一步要在**不抢总线名**的前提下拿到 debug 输出 —— [`60`](60-sensorfwd-was-the-third-service-behind-the-same-wall.md) 记着一条手工 `setsid` 探针会活过 `systemctl restart`、抢走 `com.nokia.SensorService`，把真 unit 卡在 `activating`，所以这条路要小心设计。
3. **`vsimd` 的链接失败**（§6 (2)）：文件在、报 `not found`，这是可以查实的一族（`readelf`/`ldd` 在设备上没有，得靠 `/proc/<pid>/maps` 或者拿容器里的 linker 配置 `ld.config.*.txt` 来读命名空间规则）。
4. **`ISensorManager` 那个等待**（§6 (3)）：先查清是谁在等。
5. 上一轮 [`69`](69-repowerd-died-on-a-startup-race-with-sensorfwd.md) §7 里的三件仍然成立：repowerd 的 SEGV 本因（`gdb -ex bt`）、drop-in 的冷启动复核、`qbt1000_key_input` 的垃圾键位图（和"返回键不能用"是同一件事，且**只有屏能亮、输入能点亮它之后这两件才分得开** —— 现在 repowerd 活了，斜屏也回竖了，这两件第一次可以分开量了）。
