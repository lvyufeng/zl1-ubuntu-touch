# 62 — Bluetooth：既不是"墙"也不是"没驱动"，是两处**读错了地方**

**日期**: 2026-09-21
**状态**: **`bluebinder` 从每 60 秒失败一次变成 `active`，`hci0` 起来了，一次真实扫描收到 77 个设备。** 它坏在**两个互相独立的原因**上，而且两个都不是"驱动没起来"：**（一）** 它的就绪检查读的是 Android 属性，而这个 port 上从宿主读属性**永远读不到** —— `/usr/bin/getprop` 是 v63 调试镜像留下的 1352 字节 shell stub，裸调用什么都不打印；连真身 `/usr/bin/getprop.orig-zl1` 从宿主跑也返回 **0 行**。**（二）** `bluebinder` 自己要走 **binder** 才能碰到 `android.hardware.bluetooth@1.0::IBluetoothHci` —— 同一个二进制、同样参数，宿主命名空间里是 `Failed to connect to bluetooth binder service`，容器命名空间里是 `Successfully initialized vhci bluetooth` 并且 `hci0` 出现。这是同一堵墙的**第四次**。
**接续**: [`43`](43-binder-does-not-cross-a-pid-namespace.md)、[`55`](55-the-bridge-libraries-built-and-hwbinder-does-not-cross-pid-namespaces-either.md)、[`60`](60-sensorfwd-was-the-third-service-behind-the-same-wall.md)

---

## 1. 现象：每 60 秒失败一次，而且**一个控制器都没有**

```
bluebinder.service: Failed to start bluebinder.service - Simple proxy for using android binder
                   based bluetooth through vhci.
bluebinder.service: Scheduled restart job, restart counter is at 6.
bluebinder_wait.sh[270925]: Waiting for bluetooth service     <- 每秒一条，一直刷
```

`bluetoothd`（BlueZ 5.85）**是 active 的**，`org.bluez` 在系统总线上，`Bluetooth management interface 1.7 initialized` —— 宿主这一侧的蓝牙栈完全正常。但：

```
$ ls /sys/class/bluetooth/
（空）
$ bluetoothctl list
（空）
```

**没有控制器**。`bluebinder` 就是那个把 Android 的 BT HAL 接到内核 `/dev/vhci` 上、从而造出 `hci0` 的东西；它起不来，BlueZ 就没有任何东西可以管。

## 2. 第一个病因：就绪检查读的是一个 stub，从宿主又读不到属性

`bluebinder.service` 的 `ExecStartPre=/usr/bin/droid/bluebinder_wait.sh`：

```sh
while true; do
    /usr/bin/getprop | grep -q init.svc.*.bluetooth.audio
    if [ $? -eq 0 ] ; then
        bt_status=$(/usr/bin/getprop | grep "init.svc.*bluetooth" | grep -v audio | grep -o "\[running\]")
    else
        bt_status=$(/usr/bin/getprop | grep "init.svc.*bluetooth" | grep -o "\[running\]")
    fi
    if [ "$bt_status" = "[running]" ] ; then echo "Bluetooth service running"; exit 0; fi
    echo "Waiting for bluetooth service"
    sleep 1
done
```

它调的是**不带参数**的 `getprop`（即 dump 全部属性）。而宿主上的 `/usr/bin/getprop` 根本不是 Android 的 getprop：

```
$ file /usr/bin/getprop
（1352 字节 shell 脚本）
$ cat /usr/bin/getprop
#!/bin/sh
PATH=/sbin:/usr/sbin:/bin:/usr/bin
TOOL_NAME="$(basename "$0")"
LOG=/run/zl1-prop-wrapper.log
...
log "no-attach diagnostic no-op setprop: $*"
...
prop="${1:-}"
case "$prop" in
    '')  exit 0 ;;            <- 裸调用：什么都不打印
    ro.build.version.sdk) printf '%s\n' 28 ;;
    ...
    init.svc.*|vendor.*|persist.*) [ -n "$default" ] && printf '%s\n' "$default" ;;
```

这是 v63 调试镜像留下的诊断 wrapper（`/run/zl1-prop-wrapper.log` 是它的日志）。裸调用走 `'')` 那一支，**一行都不输出**，所以 `grep` 永远匹配不到 `[running]`，循环永远不退出 —— 直到 `TimeoutStartSec=60` 把它杀掉，`Restart=always` 再来一轮。

那换真身行不行？**不行**：

```
$ /usr/bin/getprop.orig-zl1 | wc -l
0
```

真身从宿主跑也是 0 行。**Android 的属性区和 binder 一样，只有容器里看得见。** 在容器里问同一个问题，答案很干脆：

```
$ nsenter -t $(lxc-info -n android -pH) -p -m -- /system/bin/getprop | grep bluetooth
[init.svc.vendor.bluetooth-1-0-qti]: [running]
[qcom.bluetooth.soc]: [rome]
[ro.boottime.vendor.bluetooth-1-0-qti]: [45723205437]
```

**所以修法不是"找个更好的宿主 getprop"，是换个地方问。** 新的 `zl1-bt-wait` 保留原脚本的形状（任何非 audio 的 `init.svc.*bluetooth*` 为 `running`）和它的意图，只改了问的地方。

## 3. 第二个病因：`bluebinder` 自己要走 binder

`bluebinder` 的动态依赖里有 **`libgbinder.so.1`**。同一个二进制、同样参数，只换 PID 命名空间：

| | 宿主 PID 命名空间 | 容器 PID 命名空间 |
| --- | --- | --- |
| 输出 | `Failed to connect to bluetooth binder service`<br>（然后三条 `GLib-CRITICAL ... loop != NULL` 断言） | `Own hci index: 2`<br>`Turning bluetooth on`<br>`Got BLUEBINDER_LOCAL_FEATURES_MASK 0x0`<br>`Bluetooth binder initialized successfully`<br>`Successfully initialized vhci bluetooth` |
| `/sys/class/bluetooth/` | 空 | **`hci0`** |
| `hciconfig -a` | 无 | `Type: Primary Bus: Virtual`<br>`BD Address: 08:BD:D0:FA:EF:B4`<br>`UP RUNNING` |

`Own hci index`／`Turning bluetooth on` 说明它拿到了 HAL 的 `IBluetoothHci` 并把 **Rome（WCN3990）那颗芯片真的上电了**。这是同一堵墙的第四次（`43` 是 binder、`55` 是 hwbinder、`60` 是 sensors），也是一次相当干净的对照。

## 4. 修法：复用 `install-container-ns-services.sh`

`bluebinder` 加的正是 `60` 那套机制，但**要的是另外三样**（都不是 capability —— 它 unit 里的沙箱行全是注释掉的，所以不用加宽、也不用 `setpriv` 交还）：

```ini
[Unit]
StartLimitIntervalSec=0

[Service]
NotifyAccess=all
RestartSec=5
TimeoutStartSec=240
ExecStartPre=
ExecStartPre=/userdata/zl1-hybris/bin/zl1-bt-wait
```

- **`ExecStartPre=` 重置 + 换成 `zl1-bt-wait`**：原脚本不可能成功，理由见 §2。
- **`NotifyAccess=all`**：和 `60` 里 `sensorfwd` 同一个理由 —— 这个 unit 也是 `Type=notify`，而 `nsenter -p` 会 fork，READY=1 不是 systemd 认的 MainPID 发的。
- **`TimeoutStartSec=240`**（原值 60）：就绪检查可能要等到 t≈46 秒 —— `ro.boottime.vendor.bluetooth-1-0-qti` 是 `[45723205437]`，也就是 Android 的 BT HAL 在 **45.7 秒**才起来，而这个 unit 又只排在 `lxc-android-config.service` 之后。
- **`StartLimitIntervalSec=0` 放在 `[Unit]`**：`bluebinder.service` 原本把 `StartLimitBurst` / `StartLimitIntervalSec` 写在了 `[Service]` 里，systemd **两条都忽略**而且会说：

  ```
  /usr/lib/systemd/system/bluebinder.service:14: Unknown key name 'StartLimitIntervalSec'
  in section 'Service', ignoring.
  ```

  所以它一直吃的是默认的 5 次/10 秒上限 —— 这就是为什么那个循环最后会**永久**死掉，而不是一直重试。

`zl1-bt-wait` 和 `zl1-ns-exec` 一起放在 `/userdata/zl1-hybris/bin/`，由同一个脚本安装。

## 5. 验证

### 端到端：一次真实扫描收到 77 个设备

```
$ bluetoothctl --timeout 25 scan on
devices seen: 77
[NEW] Device 2C:19:5C:C9:16:C4 Mijia Scale S400 16C4      <- 有名字的
[NEW] Device 3C:20:93:F2:5A:7B midea
...
$ bluetoothctl show
Controller 08:BD:D0:FA:EF:B4 (public)
  Manufacturer: 0x001d (29)   Version: 0x08 (8)
  Powered: yes   PowerState: on
  UUID: Headset AG (00001112-0000-1000-8000-00805f9b34fb)
$ hciconfig -a hci0 | grep bytes
  RX bytes:0 acl:0 sco:0 events:381 errors:0
  TX bytes:4066 acl:0 sco:0 commands:68 errors:0
```

`events:381` 是**空中收到的 HCI 事件** —— 射频在收。整条链是：射频 → Android BT HAL（Rome / SLPI）→ hwbinder → `bluebinder`（容器命名空间）→ `/dev/vhci` → 内核 HCI → BlueZ → D-Bus。同时 `bluetoothd` 注册了 A2DP 的 aptX / SBC 端点。

### 冷启动（boot `42f40d6d-a3c8-4cc7-af04-126bed58d922`）

```
container pid ns: pid:[4026533532]
lomiri-location-service    active     pid 53412     container
biometryd                  active     pid 53383     container
sensorfwd                  active     pid 53561     container
bluebinder                 active     pid 55179     container

hci0        UP RUNNING   BD Address 08:BD:D0:FA:EF:B4
bluetoothctl list -> Controller 08:BD:D0:FA:EF:B4 Generic device [default]
bluebinder NRestarts=2 Result=success
zl1-bt-wait: bluetooth HAL running in the container
sensorfwd   Hybris sensor manager initialized, owns com.nokia.SensorService, NRestarts=2
lightdm=active session=active lomiri=1   fwpath=sta bringup=active
pulseaudio(user)=active, 2 sinks
failed: 1  (update-machine-info-from-deviceinfo.service，老问题)
```

`NRestarts=2` 是重试在正常工作：头一次容器/HAL 还没到，`RestartSec=5` + `StartLimitIntervalSec=0` 让它等到就绪。**四个服务全部自己起来，全部在容器 PID 命名空间里。**

## 6. 还剩的、和一条顺带更正

- **`bluebinder_post.sh` 仍然报 `Failed to get bluetooth address!`**。同一个病：它用宿主 getprop 读 `ro.bt.bdaddr_path` / `persist.vendor.service.bdroid.bdaddr`，读不到。**无害**：控制器的地址是 HAL 报上来的（`08:BD:D0:FA:EF:B4`），BlueZ 用的是它 —— `bluetoothctl list` 和 `/var/lib/bluetooth/` 下配对的设备都按这个地址走。`board-address` 那个文件只有在控制器报全零地址时才有意义，这台不是。
- **没有做过配对/连接测试。** 只做了"控制器在、能扫"。配对要另一台设备配合。
- **顺带更正一条记录**：之前的笔记说 `pulseaudio` inactive、"音频没起来"。那是**查错了名字** —— `pulseaudio` 在这个 rootfs 上是 **user unit**，真实状态是 active，而且它跑在**宿主**命名空间里也完全正常，因为 droid 音频 HAL 是**进程内**加载的、不走 binder。见 [`61`](61-audio-was-already-working-pulseaudio-is-a-user-unit.md)。**"要不要搬进容器命名空间"的判据是那条路走不走 binder，不是"跟不跟 Android 打交道"** —— `grep -a libgbinder <binary>` 就能分辨。

## 7. 这一段改了哪些东西

**设备上**（全是运行时；**没有**写任何分区、**没有**动引导镜像、**没有**动容器里的东西）：

- `/etc/systemd/system/bluebinder.service.d/zz-zl1-ns.conf` 新增（内容见 §4）。
- `/userdata/zl1-hybris/bin/zl1-bt-wait` 新增（新的就绪检查）。
- `/userdata/zl1-hybris/bin/zl1-ns-exec` 重装了一遍（内容未变）。
- `bluetooth`（BlueZ）没有改动；`hci0` 是运行时出现的虚拟控制器，重启即可复现/消失。
- `systemctl --failed` 仍然是 1（老问题），GUI / Wi-Fi / 三个已有服务都正常。
