# 64 — 最后一个 unit 不是坏了，是在**照做**：主机名、`libdeviceinfo` 的兜底、以及 `/etc` 的真实布局

**日期**: 2026-09-21
**状态**: **`hostnamectl` 现在报 `Pretty hostname: LeEco Pro3`，`systemctl --failed` 空。** `update-machine-info-from-deviceinfo` 在 [`63`](63-the-last-failed-unit-two-bugs-in-the-installer-that-faked-it.md) 之后已经能成功退出了，但主机名没变 —— 它**不是坏了，是在照做**：这个 unit 只在当前 pretty hostname **为空**时才写。镜像里那个 `PRETTY_HOSTNAME="Generic device"` 把它挡在门外。**同时更正 `63` §7**：这台设备**不需要** zl1 的 deviceinfo yaml —— `libdeviceinfo` 的兜底路径本来就把它认对了（`Name: le_zl1`、`PrettyName: LeEco Pro3`、`DeviceType: phone`、`GridUnit: 21`），而且 `/etc/deviceinfo/devices/` 在这个 port 上还是**只读**的。冷启动 `d8d58a19-8587-4432-b263-42b44b35e392` 复核。
**接续**: [`63`](63-the-last-failed-unit-two-bugs-in-the-installer-that-faked-it.md)、[`48`](48-the-tls-fault-was-killing-seven-system-services.md)

---

## 1. 现象：unit 成功了，主机名还是 `Generic device`

```
$ systemctl show update-machine-info-from-deviceinfo.service -p Result --value
success
$ hostnamectl | head -3
   Static hostname: ubuntu-phablet
   Pretty hostname: Generic device
```

手工跑一遍也一样：`rc=0`，什么都不打印。这个 unit 的用途就是"用 DeviceInfo 的信息更新 pretty hostname 和 chassis"，它成功了，然后什么都没更新。

## 2. 测量：它只做两件事，第二件是有条件的

把 system bus 上的流量录下来再跑一次（`dbus-monitor --system`，进程是 `:1.515`）：

```
method call ... path=/org/freedesktop/DBus; interface=org.freedesktop.DBus; member=Hello
method call ... path=/org/freedesktop/hostname1; ...Properties; member=GetAll
method call ... path=/org/freedesktop/hostname1; ...hostname1; member=SetChassis
（到此为止 —— 没有 SetPrettyHostname）
```

`SetChassis` 每次都调，`SetPrettyHostname` **一次都没调**。二进制里的字符串也印证了它的形状：

```
From org.freedesktop.hostname1, PrettyHostname = '%s', Chassis = '%s'
Can't set chassis: %s
Can't set pretty hostname: %s
Set chassis to '%s'
Set pretty hostname to '%s'
```

它先 `GetAll` 把当前的 PrettyHostname 和 Chassis 读出来，再决定写不写。**判据是"当前值是否为空"**，不是"是否与 DeviceInfo 相同" —— 直接验证：把 `PRETTY_HOSTNAME=` 那一行删掉再跑同一个二进制，

```
--- /etc/machine-info 现在 ---
CHASSIS=handset
PRETTY_HOSTNAME="LeEco Pro3"
```

它**写出了正确的值**。所以逻辑是对的、取值是对的，只有"已经有一个值了就不动它"这条策略把它挡住了。

## 3. 病因：镜像里那个没人拥有的 `Generic device`

```
$ cat /etc/machine-info
PRETTY_HOSTNAME="Generic device"
CHASSIS=handset
$ dpkg -S /etc/machine-info
dpkg-query: no path found matching pattern /etc/machine-info
```

**没有任何包拥有这个文件** —— 它是 rootfs 里带的一个占位值，而且恰好不是空字符串，正好触发上面那条策略。这不是"设备不会报自己是谁"，是"有人先替它填了一个错的名字，而它尊重先来的人"。

修法因此不是去改那个二进制，是把那行删掉、让它自己填。填出来的是 DeviceInfo 报的值，也就是下一节那个值。

## 4. 更正 `63` §7：设备**早就知道自己是谁**，不需要 zl1.yaml

`63` §7 在 `hostnamectl` 是 `Generic device` 的前提下推断"因为 `/etc/deviceinfo/devices/` 里没有 zl1 的 yaml"，并把"写一个 zl1.yaml"列为下一步。**前半句是错的观察对象**（主机名的来源是 §2/§3，不是 deviceinfo 的 yaml），**后半句的结论也就跟着错了**。逐条更正：

`libdeviceinfo` 在没有匹配的 yaml 时会**兜底**，兜底之后报出来的是完整的、正确的：

```
$ LD_PRELOAD=… device-info
[info] No device yaml config found!      <- 信息级，不是错误
 -- About this device --
Name: le_zl1
PrettyName: LeEco Pro3
DeviceType: phone
DriverType: halium
GridUnit: 21
SupportedOrientations: Portrait InvertedPortrait Landscape InvertedLandscape
PrimaryOrientation: Portrait
```

几个值得记住的点：

- `Name` / `PrettyName` 来自 **Android 属性**。二进制里找得到 `ro.product.vendor.device` / `ro.product.vendor.model`（在容器里问同一件事：`[ro.product.vendor.device]: [le_zl1]`、`[ro.product.vendor.model]: [LeEco Pro3]`）。属性区和 binder 一样只有容器里看得见，但**宿主上的 libdeviceinfo 能拿到** —— 它走的是 libhybris 那条进程内路径，不是 binder。
- `DeviceType` / `DriverType` / `GridUnit` / 各方向来自 `default.yaml` 里的 `halium` 与 `phone` 段。也就是说**兜底已经选对了机型档**，21 和 portrait 都不是默认的 desktop 值。
- 匹配方式是 `/proc/device-tree/model` 对 yaml 里的 `Names:` 列表；这台机器的 model 是 `Letv Technologies, Inc. MSM 8996pro + PMI8996 LE_ZL1-DVT1`。

**而且这份 yaml 也写不进去**：

```
$ cat > /etc/deviceinfo/devices/zl1.yaml
bash: line 4: /etc/deviceinfo/devices/zl1.yaml: Read-only file system
```

`halium.yaml` 自己的注释就说明了上游的意图 —— "Intended for use as a bind-mount overlay target, like device-specific Halium ports"，也就是这个文件应该由 port 在启动时**挂**上来，不是运行时往目录里写。这个 port 没有做那一步，但兜底把它兜住了，所以它不是待办事项。

**顺带一提**：`DeviceType: phone` 与当前会话里跑着的 `GRID_UNIT_PX=18` / `QTWEBKIT_DPR=2.0` / `FORM_FACTOR=handset`（来自 `/etc/ubuntu-touch-session.d/*.conf` 那套旧机制）是**一致的**，两套机制不打架。

## 5. 一个刻意的"不做"：不写 `SensorfwConfig`

`deviceinfo` 的 `SensorfwConfig` 是 `sensorfwd --device-info` 去读配置文件的地方，而 `/etc/deviceinfo/sensorfw/` 里只有 Pine 系设备的 conf，一个 zl1 的都没有。看起来"补一个 zl1.conf"是顺理成章的下一步 —— **不做**，理由是它会把现在能用的东西换掉：

- 所有 Pine 的 `SensorfwConfig` 指向的都是 **`iiosensorsadaptor`**（`[plugins] accelerometeradaptor = iiosensorsadaptor` …），那是给 mainline 内核直接暴露 IIO 节点的设备用的。
- 这台机器的传感器走的是 **Android HAL**：这个 port 现在能用，靠的是 `/etc/sensorfw/sensord.conf.d/30-hidl.conf`，它设的是 `hidlaccelerometeradaptor` / `hidlalsadaptor` / `hidlproximityadaptor` …，冷启动后 `sensorfwd` 仍然报 `Hybris sensor manager initialized` 并持有 `com.nokia.SensorService`。
- `30-hidl.conf` 是 `sensord.conf.d/` 里的一份**基线配置**，和 deviceinfo 无关。给它加一个指向 iio 风格文件的 `SensorfwConfig`，等于让 `sensorfwd` 改用一套这台设备上没有的适配器。

**判据**：`SensorfwConfig` 不是"有比没有好"的字段 —— 它是**替换**传感器适配器来源的开关。在没有对应适配器的设备上填它，是主动的回归。

## 6. `/etc` 的真实布局（`sed -i` 会在这里失败）

改这个文件时撞上两件事，都值得记下来：

```
$ findmnt -T /etc/machine-info
TARGET        SOURCE                                FSTYPE OPTIONS
/etc/writable /dev/sda10[/system-data/etc/writable] ext4   rw,…
$ findmnt /
TARGET SOURCE     FSTYPE OPTIONS
/      /dev/loop0 ext4   ro,relatime,data=ordered
$ ls -l /etc/machine-info
lrwxrwxrwx 1 root root 21 Jun  7  2026 /etc/machine-info -> writable/machine-info
```

- **`/` 是一个只读的 ext4 镜像**（loop0）。`/etc` 里的东西默认全是只读的。
- 只有一份**白名单**被从 `/dev/sda10`（可写的 system-data 分区）rw 挂回来：`/etc/writable`、`/etc/systemd/system`、`/etc/ssh`、`/etc/hosts`、`/etc/machine-id`、`/etc/NetworkManager/system-connections`、`/etc/udev/rules.d` …… 这也解释了为什么那两个 drop-in 能持久、`/root` 不能。
- **`/etc/machine-info` 是一个指向 `writable/machine-info` 的符号链接**。`sed -i` 会在**符号链接所在目录**（只读的 `/etc`）建临时文件再改名，所以直接 `sed -i /etc/machine-info` 会失败 —— 必须先 `readlink -f`，改真身。
- 推论：**`/etc` 里新建不了文件**。备份只能放可写的地方（`/userdata/`）。这条适用于以后任何"往 `/etc` 塞一个新文件"的想法。

## 7. 修法与验证

`scripts/install-machine-info.sh`（`--install` / `--remove` / `--status`）：

1. 先用带着 TLS shim 的 `device-info` 问出 `PrettyName`；问不出来就**拒绝**（把那一行删掉会让机器彻底没有 pretty hostname）。
2. 把镜像原值存到 `/userdata/zl1-machine-info/image-default.machine-info`（只存一次）。
3. `readlink -f` 找到真身，`sed -i` 删掉 `PRETTY_HOSTNAME=` 那一行（保留 `CHASSIS` 和以后镜像可能加的任何东西）。
4. `systemctl start` 那个 unit，让它自己填。

`--remove` 把备份写回去（也就是回到 `Generic device`），`--status` 把两边都打出来，包括备份的**内容** —— 第一版脚本在这里犯过一个错：备份是在修复**之后**建的，于是存下来的是已经修好的文件，`--remove` 成了空操作；`--status` 现在打印备份内容就是为了让这种错一眼可见。

往返测试：

```
$ install-machine-info.sh --remove
restored /userdata/zl1-machine-info/image-default.machine-info over /etc/writable/machine-info
Pretty hostname now: Generic device
$ install-machine-info.sh --install
deviceinfo says this device is: LeEco Pro3
  editing /etc/writable/machine-info
  removed the stale PRETTY_HOSTNAME line
  Result=success
  /etc/writable/machine-info: CHASSIS=handset PRETTY_HOSTNAME="LeEco Pro3"
  Pretty hostname now: LeEco Pro3
```

**冷启动 `d8d58a19-8587-4432-b263-42b44b35e392`（t≈147 秒）**：

```
   Static hostname: ubuntu-phablet
   Pretty hostname: LeEco Pro3
         Icon name: computer-handset
           Chassis: handset 🕻
failed units:                （空）
update-machine-info:         Result=success
容器 PID 命名空间 pid:[4026533532]
  lomiri-location-service    active  success NRestarts=2
  biometryd                  active  success NRestarts=3
  sensorfwd                  active  success NRestarts=2   Hybris sensor manager initialized
  bluebinder                 active  success NRestarts=2
lightdm / urfkill / mechanicd / repowerd / hfd-service / pulseaudio(user)   active
hci0 在；wlp1s0、p2p0 在
/etc/machine-info: CHASSIS=handset PRETTY_HOSTNAME="LeEco Pro3"
```

`/etc/writable` 在持久分区上，所以这次改动和那两个 drop-in 一样，是自己活过重启的。

## 8. 这一段改了哪些东西

**设备上**（全是运行时；**没有**写任何分区、**没有**动引导镜像、**没有**动容器里的东西）：

- `/etc/writable/machine-info`（即 `/etc/machine-info`）：删掉 `PRETTY_HOSTNAME="Generic device"`，由那个 unit 写成 `PRETTY_HOSTNAME="LeEco Pro3"`。
- `/userdata/zl1-machine-info/image-default.machine-info`：新增，镜像原值。
- 没有任何 deviceinfo yaml 被创建（见 §4：写不进去，也不需要）。

**仓库里**：新增 `scripts/install-machine-info.sh`，README / `scripts/README.md` 收录。

## 9. 剩下的

`systemctl --failed` 空了，但"所有的硬件都能驱动"还没有。按价值排，还没做的：

- **GPS 没有定位**：`LocSvc_ApiV02: Failed to get features supported from QMI_LOC_GET_SUPPORTED_FEATURE_REQ_V02`，QMI 到 modem 的那条路从没测过。
- **指纹**：`setActiveGroup failed: SYS_EINVAL` 只是被 `RestartSec=5` 节奏化了，没有修好。
- **摄像头、modem/telephony**：完全没测过。
- **蓝牙配对/连接**：只测到"控制器在、能扫到 77 个设备"。
- **Wi-Fi 关联**：需要只有你能提供的 AP 密码。
- **音频**：需要一只耳朵确认扬声器真的响了 —— 到 HAL 那一段已经通了。
- **`MOTION_DETECT`（sensor type 48）**：HAL 对 `setDelay`/`setActive` 回 `-22`。
