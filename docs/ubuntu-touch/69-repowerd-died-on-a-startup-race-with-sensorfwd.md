# 69 — repowerd 是**死在启动竞态上**的（sensorfwd 还没 READY 就超时 10 秒，然后 SEGV）；顺带第一次看见黑屏下面藏着的横屏

**日期**: 2026-09-22
**状态**: **`repowerd` 从 `failed (Result: signal)` 变回 `active`，而且不是靠手工拉起来的 —— 一条 drop-in 让它排在 `sensorfwd` 的 `READY=1` 之后。** 直接证据是一次受控重赛：两个 unit 都停掉、只 `start repowerd`，systemd 的 job 列表当场显示 `sensorfwd.service start running` / `repowerd.service start waiting`，sensorfwd 的 `Started` 在 [1739.422]，repowerd 的 `Starting` 在 [1739.445] —— 中间隔 23 毫秒。这一轮里 `load_plugin` **成功**（sensorfwd 打出了整份 boot 里只有两次的 `minLimit/maxLimit`），没有 10 秒停顿、没有 timeout、没有 SEGV。** 屏也跟着第一次能被点亮并按住：`ActiveOutputs` 从 `0 0` 到 `1 0`、`backlight` 0→118、`msm_fb_panel_status` `suspend`→`alive`，30 秒不掉。
**同时第一次看清黑屏下面藏着什么**：shell 停在 **横屏** —— 而这不是显示器方向错了（合成器和 shell 的窗口几何全程都是 `1080x1920`，整份日志里 `1920x1080` 出现 **0** 次），是 shell 自己把版面按横的排版了，起因是 boot 里**唯一一次被采纳**的方向读数（[385.6]）把屏幕转成了 `Qt::InvertedLandscapeOrientation`，之后全部读数都是 `unknown orientation`（unknown 不改变现状，所以就卡在那儿）。**而这一条在 repowerd 修好之前根本看不见：屏一直是黑的。**
**接续**: [`68`](68-the-camera-stage-was-one-cookie-in-the-stub.md)、[`64`](64-the-last-unit-was-not-failing-it-was-obeying.md)、[`48`](48-the-tls-fault-was-killing-seven-system-services.md)

---

## 1. repowerd 这一整个 boot 都是死的

这次不是从日志推断出来的，是它的终态：

```
$ systemctl status repowerd
   Active: failed (Result: signal) since ...
  Process: 38558 ExecStart=/usr/sbin/repowerd (code=killed, signal=SEGV)
$ busctl --system list | grep -i repowerd        # 空
```

shell 那边是**症状**，不是原因 —— 它的日志一直在说同一件事：

```
com.lomiri.Repowerd DBus interface not available, waiting for it
presuming no wakelocks held
```

这台 port 上**没有别的东西**管待机/息屏策略。所以 repowerd 一死，"屏会黑"和"黑了没人能点亮"同时成立，和用户报的"黑屏了""都没反应"是同一件事。这也解释了一个和 [`48`](48-the-tls-fault-was-killing-seven-system-services.md) 打架的现象：doc 48 说 repowerd 活着的时候背光会自己从 128 掉到 0，而这次背光一直是 128、**同时没有任何 repowerd 进程** —— 不是 doc 48 错了，是这次它根本没活。

## 2. 病因：一个 10 秒的超时，和一个 13.25 秒的 READY

`journalctl -b -o short-monotonic`（单调时间戳；设备时钟是错的，墙钟排序会骗人，见 [`64`](64-the-last-unit-was-not-failing-it-was-obeying.md)）里 repowerd 的一生只有这么长：

```
[   42.365731] systemd: Starting repowerd.service
[   42.420230] systemd: Starting sensorfwd.service
[   42.450425] repowerd: main: Starting repowerd 2025.09
[   42.716069] dbus-daemon: Activating systemd to hand-off: service name='com.nokia.SensorService'
                                 requested by ':1.1' (pid=38558 comm="/usr/sbin/repowerd")
[   52.724265] repowerd: Sensorfw: failed to call load_plugin: Timeout was reached
[   52.725601] repowerd: g_variant_unref: assertion 'value != NULL' failed
[   52.727406] repowerd: DefaultDaemonConfig: Failed to create SensorfwLightSensor: Could not create sensorfw backend
[   52.727751] repowerd: DefaultDaemonConfig: Falling back to NullLightSensor
[   55.701017] systemd: Started sensorfwd.service            <- sensorfwd 的 READY=1，13.25 秒才到
[   55.717542] systemd: repowerd.service: Main process exited, code=killed, status=11/SEGV
[   55.721516] systemd: Failed to start repowerd.service
```

三件事可以逐条读出来：

1. **它自己去要 sensorfw 的。** [42.716] 那条 dbus-daemon 的 hand-off 请求是 **repowerd（pid 38558）** 发出的：它启动时通过 DBus 激活 `com.nokia.SensorService`，也就是 sensorfwd，然后调 `load_plugin()`。
2. **那个调用有 10 秒超时，而 sensorfwd 要 13.25 秒。** repowerd 的计时从自己启动算（42.450 → 52.724，正好 10.00 秒），sensorfwd 的 `Type=notify` READY 在 55.701。**差 3 秒，但这 3 秒是致命的** —— 超时先到。
3. **然后它 SEGV。** 超时之后它退到 `NullLightSensor`，再过 3 秒死掉。

**退到 Null 本身不是死因**：这次幸存的那一轮里 `NullHBM` 和 `NullPerformanceBooster` 一样出现了，两轮都在。所以杀死它的是**超时之后那个坏掉的 sensorfw 客户端对象**，不是"N 个功能没有"。（精确到哪一行解引用还没证；没有 core，`core_pattern = core`、`/var/lib/systemd/coredump/` 是空的。）

**为什么以前是好的**：`repowerd` 在 doc 48/52/63/64 里都记着 `active`，同一张镜像、同一批 unit。变的是**谁赢了这个竞态**，不是谁缺了件东西。这台设备上传感器 DSP 的启动时间本来就在抖（见 [`58`](58-one-cold-boot-where-the-secure-world-refused-and-three-firmwares-did-not-load.md)），10 秒 vs 13 秒这种差距随手就跨过去了。

**两个设计上的原因让"输一次"变成"整个 boot 都没了"**：

- `repowerd.service` 对 `sensorfwd.service` **完全没有排序** —— 它的 `After=` 只有 `lxc-android-config.service dbus.socket`（`Wants=` 里也没有 sensorfwd）。赢不赢只看 job 调度。
- 它是 **`Restart=no`**。输一次就永久。

顺带排除掉的：`/usr/share/repowerd/device-configs/config-default.xml` 存在且两轮一样；`libcutils.so` 的 `dlopen` 失败两轮一样（无害）；zl1 的 device config 两轮都没有；显示状态也相同。

## 3. 修法：一条 drop-in，只加排序和重试

`/etc/systemd/system/repowerd.service.d/zz-zl1-after-sensorfwd.conf`（`/etc` 本身是只读镜像，`/etc/systemd/system` 是可写的白名单路径，见 [`64`](64-the-last-unit-was-not-failing-it-was-obeying.md) §6）：

```ini
[Unit]
After=sensorfwd.service
Wants=sensorfwd.service

[Service]
Restart=on-failure
RestartSec=5
```

- **`After=` 是修法**。sensorfwd 是 `Type=notify`，所以"排在它后面"就是"排在它的 `READY=1` 后面"，而那正是 `load_plugin()` 需要的那一刻。它也是有界的：sensorfwd 没设 `TimeoutStartSec`，systemd 的 `DefaultTimeoutStartSec`（90 秒）会兜住这次等待。
- **`Restart=on-failure` 是网，不是修法**，而且它让"排序"从"正确"变成"够用"：sensorfwd 在第一次 READY 之后还会再重启三次（[63.6] [71.4] [83.4]，`NRestarts=3`，到 [84.0] 才安静下来），所以即使 repowerd 在第一次 READY 就起来，也可能被后面的重启甩掉。有了重试，那只是一次 5 秒后的重来，而不是"死到下一次开机"。

**刻意没做的**：没加 `SensorfwConfig`、没加 zl1 的 device yaml（[`64`](64-the-last-unit-was-not-failing-it-was-obeying.md) §5 —— 那会把 sensorfwd 从能用的 HIDL adaptor 上换走）。也没去关 repowerd 的 sensorfw 光源传感器，因为**没有这个开关**：`/etc/default/repowerd` 全是注释（只有 `REPOWERD_DEVICE_CONFIG_DIR` 和 `SENSORFW_SOCKET_PATH` 两个变量），`/usr/sbin/repowerd` 里连一个长选项都没有（`grep -aoE -- '--[a-z][a-z0-9-]{2,}'` 返回空），而 `config-default.xml` 里的 `config_automatic_brightness_available=false` 并不阻止它构造 sensorfw backend。

## 4. 验证：不是"看起来 active"，是**当场重跑一次那个竞态**

`Type=dbus` 的坑在[上一次会话里已经踩过一次](../../README.md)（打印了 `Started` 然后 3 秒后死掉），所以"现在 active"不算证据。这次的判据是把两个 unit 都停掉、只请求 repowerd，然后看 systemd 的 job 队列：

```
先: repowerd=active sensorfwd=active
systemctl stop repowerd; systemctl stop sensorfwd
( systemctl start repowerd ) &
t=1  jobs: 23234 sensorfwd.service start running | 23105 repowerd.service start waiting
t=2..15  jobs: (空)
systemctl start repowerd 返回 rc=0
后: repowerd=active  pid 1320231   sensorfwd=active  NRestarts=0
```

`repowerd.service start waiting` 后面挂着 `sensorfwd.service start running` —— **排序确实被执行了**，而不是碰巧谁先跑。对应的 journal：

```
[ 1739.394428] sensorfw: Hybris sensor manager initialized
[ 1739.422482] systemd: Started sensorfwd.service
[ 1739.445080] systemd: Starting repowerd.service        <- 23 ms 之后
[ 1739.460103] sensorfw: minLimit: 0 0                   <- load_plugin 成功的标志
[ 1739.460667] sensorfw: maxLimit: 2147483647 2147483647
[ 1739.487316] repowerd: main: Starting repowerd 2025.09
[ 1739.857200] systemd: Started repowerd.service         <- 0.19 秒，没有 10 秒停顿，没有 SEGV
```

`minLimit/maxLimit` 这一对是很好的判据：**整份 boot 里它只出现两次**（t=112，和这次 t=1739），也就是**每次 `load_plugin` 成功才有一对**，不是每次尝试都打。24 分钟后复查：`repowerd: active pid 1320231`，`com.lomiri.Repowerd` / `com.lomiri.Repowerd.Settings` / `com.canonical.Unity.Screen` 三个名字都在 system bus 上。

**屏是真的回来了**（这是"GUI 能不能用"的直接前提）：

```
前: ActiveOutputs=(ii) 0 0   backlight=0    panel_status=suspend
busctl --system call com.lomiri.Repowerd /com/canonical/Unity/Screen \
  com.canonical.Unity.Screen keepDisplayOn
后: ActiveOutputs=(ii) 1 0   backlight=118  panel_status=alive   (30 秒以上不掉)
```

`keepDisplayOn` 是 repowerd 自己的接口，**可逆**，而且不需要 root 写任何 sysfs 节点。

## 5. 于是第一次看清：黑屏下面藏着横屏

用户这一轮报的是**"现在变成横屏了"**，还确认了是"横着铺开、字是正的"、而且是"刚刚才有"。这条和 repowerd 是同一件事的两面：**屏黑着的时候没人看得见版面是什么样。**

先说**不是**什么：

- **不是显示器/合成器方向错了。** 整份 boot 里 `1920x1080` 出现 **0** 次；合成器报的永远是 `Logical size 1080x1920`，qtmir 的 `PlatformScreen` 永远是 `geometry: QRect(0,0 1080x1920)`，shell 自己的 `root width: 1080 height: 1920`。**窗口几何从头到尾没变过。**
- **不是 panel 的旋转字节。** `/sys/class/graphics/fb0/rotate = 0`，从头没动过。

**是什么**：shell 内部把版面按横的排版了，而触发它的是 boot 里**唯一一次被采纳**的方向读数：

```
[ 385.646759] qtmir.sensor: OrientationSensor::readingChanged
[ 385.663429] qtmir.sensor: PlatformScreen::customEvent() - new orientation=Qt::InvertedLandscapeOrientation
[ 404.197075] qtmir.sensor: OrientationSensor::readingChanged
[ 404.197702] qtmir.sensor: PlatformScreen::customEvent() - unknown orientation.
（之后每一次都是 unknown orientation.）
```

读设备上 `/usr/share/lomiri/OrientedShell.qml` 的代码可以确认这条链是对的：`PlatformScreen::onOrientationReadingChanged()` 收到一个**它能认的**枚举值才会改方向，`unknown` 那条路径**不改现状**：

```qml
property int orientation
onPhysicalOrientationChanged: {
    if (!orientationLocked) { orientation = physicalOrientation; }
    ...
```

（`orientation` 是 `QtQuickWindow.Screen.orientation`，一个 `unknown` 的值在那里就是"别动"。）所以 385 秒那一次被采纳，之后全部 ignored，屏幕就**一直横着**，直到 shell 重启或方向真的再变一次。

**那个值本身**是 sensorfw 给的，而它现在冻住了：

```
$ gdbus call --system ... /SensorManager/orientationsensor ... Get local.OrientationSensor orientation
(<(uint64 4907939888, uint32 6)>,)
（每秒一次，值恒为 6，时间戳不变）
```

6 在 Qt 里是 `FaceDown`（屏幕朝下）。手机平放在桌上，正确的应该是 5（`FaceUp`）。而 `/etc/sensorfw/sensord.conf.d/30-hidl.conf` 给加速度计的坐标变换矩阵是**单位阵**：

```ini
[accelerometer]
transformation_matrix = "1,0,0,0,1,0,0,0,1"
```

（同一份文件里磁力计是 `"-1,0,0,0,1,0,0,0,1"`。）一个错的坐标矩阵恰好可以同时解释"平放时报 FaceDown"和"385 秒那次报 InvertedLandscape"。

**这一条我没有定案，因为定案需要一只手。** §7 把它写成下一次的测量：竖着拿 20 秒，看那个值变不变、变成几 —— 读数对得上就是"只是平放时的姿态判据不对"（竖屏锁 + 重启 shell 即可），对不上就是坐标矩阵真的填错了（那要改 `/etc/sensorfw/`，只读镜像，得先想清楚怎么落）。设备上已经有一个每秒采一次的记录在跑（`/userdata/zl1-orient-poll2.log`，900 秒），竖屏锁 `com.lomiri.touch.system orientation-lock` 也已经设成 `'PrimaryOrientation'` 摆在那儿等着。

**这次没白试的三条**（都是负结果，但省掉下一次）：

- `orientation-lock` 设成 `'PrimaryOrientation'` **不触发任何重新评估**：shell 的日志在那之后一条都没变 —— 它是在 boot 时读的（`Component.onCompleted`），运行时 set 不做事。同一个 schema 里的 `rotation-lock` 也更像 lomiri-system-settings 那个开关自己的设置项，shell 不读它。
- 指望"重启 sensorfwd 让读数变一变"**没有发生**：重启后时间戳换了（4907939888），**值还是 6、还是冻的**。那个值不是"每次读时算一遍"，是一个缓存下来的姿态。
- shell 是 `Type=notify`、`Restart=on-failure`（`lomiri-full-greeter.service`，`ExecStart=/usr/libexec/lomiri-systemd-wrapper --mode=full-greeter`），所以**任何重启 shell 的手法都绕不过 greeter 自己** —— 这是"别拿 GUI 冒险"那条规矩在这里的具体形状，和 [`68`](68-the-camera-stage-was-one-cookie-in-the-stub.md) §6 记的 `mirscreencast` 会让 greeter 重建 GLRenderer 是同一类风险。所以横屏这条要走"把方向弄对"，不走"重启看看"。

## 6. 文件与复现

| 文件 | 作用 |
|---|---|
| `scripts/install-repowerd-ordering.sh` | 新：`--install` / `--remove` / `--status`。那条 drop-in 的唯一来源；头部就是 §1–§4 的全部证据。`--status` 打印 drop-in 内容 + `systemctl cat` 是否真的加载了它 + 两个 unit 的实况 + 本轮 journal 里的两个签名（`systemctl cat` 才是判据，文件存在什么都不是 —— [`63`](63-the-last-failed-unit-two-bugs-in-the-installer-that-faked-it.md) 的教训） |
| `scripts/device/zl1-watch-input.py` | 新（上一轮写好、这次入库）：8 个 input 设备都不 grab 地记录所有 evdev 事件，给 [`68`](68-the-camera-stage-was-one-cookie-in-the-stub.md) §7 第 1 条那个"返回键断在哪一段"的测量用 |
| `scripts/device/zl1-inject-input.py` | 加了 `--repeat/--every`：一个虚拟设备连续点 N 次（一个"创建设备、用一次、销毁"的进程是没法被观察的） |
| `docs/ubuntu-touch/evidence/repowerd-ordering-2026-09-22.log` | 本次全部原始证据：失败的 boot、sensorfwd 的抖动、手工重跑成功的两次、drop-in 文本、job 队列、bus 名字、显示开关、方向读数 |

```sh
scripts/install-repowerd-ordering.sh --install   # 装 drop-in 并当场应用（幂等）
scripts/install-repowerd-ordering.sh --status    # 看它在不在、有没有真被加载
scripts/install-repowerd-ordering.sh --remove    # 回到镜像原始形状（不碰正在跑的进程）
```

**设备安全**：只往 `/userdata/` 和 `/etc/systemd/system/repowerd.service.d/`（可写白名单）写；只读地看 `/proc`、`/sys`、`/dev/fb0`、binder debugfs。重启过 `sensorfwd` 与 `repowerd` 这两个 init 托管的运行时服务（都是 `Restart=always`/已改成 `on-failure`，重启即恢复）。显示用 repowerd 自己的 DBus 接口开关，每次都能回到发现时的状态。`/sys/class/leds/lcd-backlight/brightness` 没有被写过。**没有碰任何分区、没有动 boot 镜像、没有改容器内文件。** 设备没有变砖，GUI 照常，容器 RUNNING。

## 7. 下一步

1. **横屏**（用户这一轮报的，也是"GUI 能不能用"的关键路径）：等一只手 —— 手机竖着拿 20 秒，读 `/userdata/zl1-orient-poll2.log`，按 §5 那个二分定案。竖屏锁已经在 `'PrimaryOrientation'` 上了，方向一旦弄对就能锁住。
2. **`repowerd` 的 SEGV 本因**还没证到行：要证的是一条 `gdb /usr/sbin/repowerd -ex bt -p <pid>`，条件是 repowerd 跑着而 sensorfwd 是停的。排序修法已经让这条不必再等，但它是"为什么退到 Null 之后会死"的答案。
3. **冷启动复核**（这条 drop-in 的唯一真考验）：`/etc/systemd/system` 在持久分区上，所以它应该活过重启；`systemctl is-active repowerd` + `busctl --system list | grep com.lomiri.Repowerd` 是判据。
4. **`qbt1000_key_input` 那张垃圾键位图**（`fefefefefefefe…`，里面没有 `KEY_BACK`）—— 内核侧，要碰 boot 镜像，仍然**排在确认之后**。注意它和"返回键不能用"的关系现在多了一层：屏黑着的时候，"返回键点不亮屏幕"和"返回键没接上"是分不开的；repowerd 活过来之后这两件事才分得开。
5. `67` §7 剩的第 2 条（输入层的 `obtainPointerController` 在没有 SurfaceFlinger 时死循环）仍然成立。
6. 顺带记一笔、优先级待定：这次量到两个"看起来坏了、其实只是没人接"的常驻噪声，都不是 0 号问题但会一直刷日志 —— `mtp-server-usb-moded-watcher.service` 每 1.4 秒重启一次（`com.meego.usb_moded` 没人提供，重启计数已经到 3365+），以及 `camera-service-trust-stored` 反复起（每两次间隔几秒）。
