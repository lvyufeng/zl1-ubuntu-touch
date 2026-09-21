# 60 — sensorfwd 是第三个撞同一堵墙的服务，而且它比前两个多要了两样东西

**日期**: 2026-09-21
**状态**: **sensorfwd 从 `activating` 卡死变成 `active`，并且在容器 PID 命名空间里真的驱动了传感器 HAL。** 墙还是 `55`/`56` 那堵（hwbinder 不跨 PID 命名空间）—— 这次是用**同一个二进制、同一条命令行、同样 25 秒，只有命名空间不同**量出来的。但把它搬过去之后还差两样，前两个服务都不需要：**wrapper 要 `CAP_SYS_ADMIN` 和 `CAP_SYS_PTRACE`**（缺一个都不行，是在设备上二分出来的），而 sensorfwd 的 unit 自带 `CapabilityBoundingSet=`，所以用完还得还回去；以及 **`NotifyAccess=all`** —— `nsenter -p` 会 fork，READY=1 不是 systemd 认的那个 PID 发的。端到端验到的是：一个 D-Bus 客户端 `requestSensor` 之后，HAL 把它自己的参数答了回来（`getResolution -> 0.244286`、`getMinDelay -> 5000`、`getMaxDelay -> 1000000`，`setActive -> success`）。
**接续**: [`55`](55-the-bridge-libraries-built-and-hwbinder-does-not-cross-pid-namespaces-either.md)、[`56`](56-the-two-services-move-into-the-containers-pid-namespace.md)、[`57`](57-boot-verification-the-two-services-come-up-by-themselves.md)、[`48`](48-the-tls-fault-was-killing-seven-system-services.md)

---

## 1. 现象：不是崩，是被 systemd 每 90 秒杀一次

`sensorfwd` 一直是 `activating`。它不崩、不报错，只是**永远不发 READY=1**：

```
sensorfwd.service: start operation timed out. Terminating.
sensorfwd.service: Failed with result 'timeout'.
sensorfwd.service: Scheduled restart job, restart counter is at 9.
```

`Restart=always` + `RestartSec=1` + unit 自带 `Type=notify`（默认 90 秒启动超时），于是每 90 秒一轮，`NRestarts` 数到 9。而 `sensorfwd.service` 是 **`WantedBy=graphical.target`** —— 这个停顿正好压在图形界面 **前面**。

`systemctl show` 说得很清楚：`Result=success`、`ExecMainStatus=0` —— **它自己没失败过**，是 systemd 判它启动超时。

## 2. 第一层：同一堵墙，第三次

`48` 记过 `sensorfwd` 卡在 `activating`，当时归因到 SLPI 没加载。这次 SLPI 是**加载成功**的（`slpi_load_fw: SLPI image is loaded`、`Power/Clock ready interrupt received`），所以不是那条线。

第一次量的方式是 `strings`/`maps`：`/proc/<pid>/maps` 里有 `libgbinder.so.1.1.47`、`libhidlsensorfw-qt5.so.1.0.0`、`libhybris-common`，`/etc/sensorfw/sensord.conf.d/30-hidl.conf` 把插件指到 `hidlaccelerometeradaptor` 这一族 —— 也就是**它走 gbinder 直接开 Android 的 sensors HAL**，而它跑在**宿主 PID 命名空间**（`pid:[4026531836]`，初始命名空间）。

然后照 `55` 的办法做了对照 —— 同一个二进制，同一条命令行，同样 25 秒，只换命名空间：

| | 宿主 PID 命名空间 | 容器 PID 命名空间 |
| --- | --- | --- |
| 输出 | `Requesting adaptor: "magnetometeradaptor"`<br>`Could not find remote object for sensor service. Trying to reconnect`<br>（这个循环填满 8 KB） | `Connected to sensor 1.0 service`<br>`Get sensor list`<br>`initialize event pipe` |
| 之后 | 什么都不发生 | `void HybrisManager::initManager() SELECT type: 1 ACCELEROMETER name: LSM6DS3 Accelerometer`<br>`HYBRIS CTL setDelay(1=ACCELEROMETER, 200000) -> success`<br>`HYBRIS CTL setActive(1=ACCELEROMETER, false) -> success` |
| 大小 | 8 055 字节 | 377 763 字节 |

容器里那一跑还把**这台设备的传感器清点**报了出来，这是头一次看到真实清单：

```
type  1 ACCELEROMETER             LSM6DS3 Accelerometer
type 35 ACCELEROMETER_UNCALIBRATED LSM6DS3 Accelerometer Uncalibrated
type  2 MAGNETIC_FIELD            AK09911 Magnetometer
type 14 MAGNETIC_FIELD_UNCALIBRATED AK09911 Magnetometer Uncalibrated
type  4 GYROSCOPE                 LSM6DS3 Gyroscope
type 16 GYROSCOPE_UNCALIBRATED    LSM6DS3 Gyroscope Uncalibrated
type  7 PROXIMITY                 LTR579 ALSPS
type  5 LIGHT                     LTR579 ALSPS
```

`Could not find remote object for sensor service` 就是 HIDL 那边的 `getService()` 返回了空 —— 和 `55` 的 `Unable to get GPS service`、`Unable to get IBiometricsFingerprint::2.1 service` 是同一句话的不同说法。**宿主命名空间里 `lshal` 看到 0 个服务，容器里 134 个**，那条测量直接适用。

## 3. 第二层：搬过去之后，systemd 不认那条通知

照 `56` 的办法接进 `install-container-ns-services.sh`（加 `sensorfwd` 的 `unit_cmd` / `unit_extra`，`zz-` drop-in 覆盖 `ExecStart`）。结果**还是 `activating`**，但理由换了一个，而且 systemd 逐字说了出来：

```
sensorfwd.service: Got notification message from PID 1049011,
                   but reception only permitted for main PID 1048906
```

`Type=notify` 默认只接受**主 PID** 发来的 READY=1。而 `nsenter -p` **必须 fork** —— `setns` 对 PID 命名空间只影响未来的子进程，所以往容器里落、然后 exec sensorfwd、然后发通知的，是 nsenter 的**子进程**；加上中间那层 `setpriv`，更不可能是主 PID。于是通知被丢掉，90 秒照样超时。

`NotifyAccess=all`（接受本 unit cgroup 内任何进程的通知）就解决了。**只搬命名空间不够** —— 这一点值得记，因为 `56` 的两个服务都是 `Type=dbus`，那条路上没有这个坑。

## 4. 第三层：wrapper 要两个 capability，而 unit 把它们关着

`zl1-ns-exec` 在 systemd 下报 `no android container after 60s`（以及那句拒绝跑的话），**而直接手跑同一个 wrapper 是好的**。差别只有一个：sensorfwd 的 unit 自带

```
CapabilityBoundingSet=CAP_BLOCK_SUSPEND CAP_DAC_OVERRIDE CAP_FOWNER
```

设备上二分出来的结论：

| bounding set | 结果 |
| --- | --- |
| 原始三个 | `no android container after 60s` |
| 原始三个 + `CAP_SYS_ADMIN` | 还是 `no android container after 60s` |
| 原始三个 + `CAP_SYS_PTRACE` | 还是 `no android container after 60s` |
| 原始三个 + `CAP_SYS_ADMIN` + `CAP_SYS_PTRACE` | 落到容器命名空间 |

两个都要，各自的理由不同：

- **`CAP_SYS_ADMIN`** 是 `setns()` 本身要的。`kernel/nsproxy.c`：`if (!(flags & CLONE_NEWUSER) && !ns_capable(current_user_ns(), CAP_SYS_ADMIN)) return -EPERM;` —— 除 `CLONE_NEWUSER` 外任何命名空间都要。
- **`CAP_SYS_PTRACE`** 是 wrapper **自己那句判断**要的：`[ -e "/proc/$A/ns/pid" ]`。`/proc/<pid>/ns/*` 只对"本进程可以 ptrace 的目标"可读，而容器 init 不在我们的 PID 命名空间里。缺它的时候这句永远为假，于是循环跑满 60 秒，然后报"没有容器" —— 一个**看起来像容器没起来、其实是权限不够**的错。这条最值得记，因为它会把人引到错误的方向。

但把这两个 cap 加进 unit 的 bounding set，就等于**让 sensorfwd 拿着它的 unit 文件从没给过的权限**。所以 wrapper 在 `setns` 之后用 `setpriv` 再收窄回去：

```sh
if [ -n "${ZL1_NS_DROP_CAPS:-}" ] && [ -x /usr/bin/setpriv ]; then
    exec nsenter -t "$A" -p -- /usr/bin/setpriv \
        --bounding-set=-sys_admin,-sys_ptrace,-setpcap \
        --inh-caps=-all --ambient-caps=-all -- "$@"
fi
```

从 bounding set 里删 cap 需要 `CAP_SETPCAP`（实测：不给就是 `setpriv: apply bounding set: Operation not permitted`），所以它也进了那个加宽的集合、并且一起被删掉。结果实测：

```
pid 224262  /usr/sbin/sensorfwd --systemd --device-info --log-level=warning
  ns     pid:[4026533532]      <- 容器
  CapBnd 000000100000000a      <- 2^36 + 2^3 + 2^1 = BLOCK_SUSPEND + FOWNER + DAC_OVERRIDE，正好是原来那三个
```

进程树也正是想要的那条链，一边一个、不堆积：

```
224072  1      nsenter -t 35067 -p -- /usr/bin/setpriv --bounding-set=-sys_admin,-sys_ptrace,-setpcap \
                 --inh-caps=-all --ambient-caps=-all -- /usr/sbin/sensorfwd --systemd ...
224262  224072 /usr/sbin/sensorfwd --systemd --device-info --log-level=warning
```

**这一整套是 `ZL1_NS_DROP_CAPS=1` 开关控制的**，只有 sensorfwd 的 drop-in 设它，所以 `56` 那两个已经跑起来的服务行为一点没变。

## 5. `--status` 差点报了个假阴性

第一版把 `Connected to sensor 1.0 service` 当成"成功"证据去数，结果是 **0** —— 而服务是好的。原因是那条日志、以及 `SELECT type: ... name: ...` 那份清点，都只在 **`--log-level=debug`** 打；unit 自己跑在 `--log-level=warning`，成功路径不打日志，**只打错误**。warning 级别下真正能当阳性证据的是 `Hybris sensor manager initialized`（它是 HAL 答完、每个传感器探完之后才打的）。这条和 `57` 里 `lomiri-location-service` 那个"干净退出所以看起来没问题"是同一类错误：**证据串选错级别，就会把好的报成坏的。** 现在 `--status` 的 sensorfwd 段用的是 warning 级别确实存在的串，并且明确写了清点要 debug 才看得到。

顺带修了一个同类的：`--status` 里选"最早那份快照"用的是 `ls | sort | head -1`，字典序会把 `boot-111s.log` 排在 `boot-35s.log` 前面 —— 正好挑中最没用的那份。`59` 已经改成按文件名里的 uptime 数值排。

## 6. 验证

### 冷启动（boot `b085c446-3e88-4630-8010-f3c1ba08ef7a`）

```
container pid ns: pid:[4026533532]
lomiri-location-service    active     pid 55959    container
biometryd                  active     pid 55965    container
sensorfwd                  active     pid 56174    container

sensorfwd: Result=success  NRestarts=3  SubState=running
  Hybris sensor manager initialized : 3
  Failed with result 'timeout'      : 0        <- 改之前是 11
  owns com.nokia.SensorService      : 1
  CapBnd                            : 000000100000000a

lightdm=active session=active lomiri=1
fwpath=sta  zl1-wlan-bringup=active  zl1-container-fix=active  zl1-kmsg-snapshot=active
failed: 1  (update-machine-info-from-deviceinfo.service，老问题，与本次无关)
```

`NRestarts=3` 是重试在起作用：头两次容器/HAL 还没就绪，`RestartSec=5` + `StartLimitIntervalSec=0` 让它等到就绪为止，而不是像默认那样撞上 `start-limit-hit` 永久死掉。**这一次冷启动没有 `Failed with result 'timeout'` 了。**

### 端到端：一个真的客户端请求，走通了整条链

D-Bus 上能问的都问了：

```
availablePlugins        -> 52 个，含所有 hidl* 适配器
availableSensorPlugins  -> 9 个：accelerometersensor alssensor compasssensor gyroscopesensor
                                 magnetometersensor orientationsensor pressuresensor
                                 proximitysensor rotationsensor
pluginAvailable accelerometersensor/alssensor/proximitysensor/gyroscopesensor -> b true
loadPlugin accelerometersensor -> b true
requestSensor accelerometersensor -> /SensorManager/accelerometersensor 出现了
```

然后把 unit 停掉、手起一个 `--log-level=debug` 的实例，再发一次 `requestSensor`，看 HAL 那一侧（**这就是"数据真的从 SLPI 一路走到我们进程"的证据**）：

```
sensorfw: HYBRIS CTL getResolution(1=ACCELEROMETER) -> 0.244286
sensorfw: HYBRIS CTL getMinDelay(1=ACCELEROMETER) -> 5000
sensorfw: HYBRIS CTL getMaxDelay(1=ACCELEROMETER) -> 1000000
sensorfw: HYBRIS CTL setDelay(1=ACCELEROMETER, 200000) -> success
sensorfw: HYBRIS CTL setActive(1=ACCELEROMETER, true) -> success
sensorfw: HYBRIS CTL getDelay(1=ACCELEROMETER) -> 100000
sensorfw: HYBRIS CTL setActive(1=ACCELEROMETER, false) -> success
```

`0.244286` 这个分辨率、`5000`/`1000000` 这对延迟范围是 **Android sensors HAL 自己报出来的数**，不是我们这边的常量。`setActive(..., true)` 成功就是**传感器在 HAL 里真的被打开**；最后那条 `false` 是客户端（`dbus-send`）退出、连接断掉之后 sensorfwd 正确地关掉它。容器侧也对得上：`sensors.qti` 持着 `/dev/sensors` 和 `/persist/sensors/sns.reg`（SLPI 的传感器注册表）。

## 7. 还没做到的，和两个坑

- **还没有客户端在消费数据流。** `setActive(true)` 之后没有任何东西在读 —— `mce` 在这个 port 上是 `inactive`（`repowerd` 接管了电源管理），lomiri 也还没请求过。所以"能驱动"到这里指的是 **sensorfwd 起来了、连着 HAL、9 个传感器可用、一次请求能让 HAL 把传感器打开**；"某个应用真的看到数"还差一个客户端。
- **`MOTION_DETECT`（type 48）不工作**：`setDelay(48=MOTION_DETECT, 30000) -> -22`、`setActive(48=MOTION_DETECT, false) -> -22`，每次开机各 4 条。这是 HAL 对这个传感器不实现那两个调用，sensorfwd 打条错误继续走（后面照样 `Hybris sensor manager initialized`）。不是故障，但 `--status` 会把它数出来。
- **坑：手跑的探针会漏。** 为了看 debug 日志，我用 `setsid nsenter ... sensorfwd &` 起了一个实例 —— 它**不在任何 unit 的 cgroup 里**，所以 `systemctl restart sensorfwd` 杀不掉它；它先抢到了 `com.nokia.SensorService`，真正的 unit 就卡在 `activating`（`Result=exit-code`）。清掉那个 stray PID 之后一切恢复。**这正是 wrapper 里"不做 nsenter 清扫"那条取舍的另一面**：wrapper 自己的子进程在 unit cgroup 里所以会被 `KillMode=control-group` 收走，而手工起的、`setsid` 出去的不会。以后要起调试实例，记得按 PID 收尾（这次是 `pgrep -f 'log-level=debug'` 找到的）。
- **不因为 `NRestarts=3` 就去改时序。** 那是重试正常工作。`StartLimitIntervalSec=0` 是它还能继续重试的前提。

## 8. 这一段改了哪些东西

**设备上**（都是运行时，**没有**写任何分区、**没有**动引导镜像、**没有**动容器里的东西）：

- `/etc/systemd/system/sensorfwd.service.d/zz-zl1-ns.conf` 新增：`ExecStart=` 覆盖到 `zl1-ns-exec`，`NotifyAccess=all`，`RestartSec=5`，`StartLimitIntervalSec=0`，`Environment=ZL1_NS_DROP_CAPS=1`，加宽的 `CapabilityBoundingSet`。
- `/userdata/zl1-hybris/bin/zl1-ns-exec` 更新：加 `setpriv` 收窄那一段（受 `ZL1_NS_DROP_CAPS` 控制），并把 `CAP_SYS_PTRACE` 那个坑写进了注释。
- 调试用的 stray 进程已清掉，`/tmp/sf*.log` 已删。
- `systemctl --failed` 仍然是 1（老问题），GUI 正常，前两个服务正常。
