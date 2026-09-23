# 79 — `orientationsensor` 不是坏的：它是一个**6 个离散位置的分类器**，"静止时不出样本"是它的定义

**日期**: 2026-09-23
**状态**: [`70`](70-the-landscape-was-the-shell-laying-itself-out.md)/[`71`](71-the-sensors-stream-the-restart-kills-the-hal.md)/[`78`](78-the-sensors-came-back-without-a-reboot.md) 一直把 `orientationsensor` 放在"不产出"那一栏——**这一条是判据用错了**：它不是"不产出"，它是一个*位置分类器*，静止时本来就没有东西可报。同时第一次把 9 个传感器一次量全：**6 个在流、1 个是分类器、1 个没有时间戳、1 个根本没有对象**。剩下一个真问题被单独拎出来：分类器说 `6`，而加速度计说屏幕朝上，**两者矛盾**——而 `qtmir` 读的正是分类器那个值，所以这才是这台设备"老是横屏"的源头（`70`/`71`）。

**接续**: [`71`](71-the-sensors-stream-the-restart-kills-the-hal.md)（§7 把"关掉 orientationsensor 换固定竖屏"作为一个**取舍**挂着，等用户决定）、[`70`](70-the-landscape-was-the-shell-laying-itself-out.md)（横屏是 shell 自己摆的）、[`78`](78-the-sensors-came-back-without-a-reboot.md)（传感器栈是怎么回来的）

---

## 1. 先问 sensorfw 这个传感器**是什么**

之前所有关于 orientation 的讨论都只用了它的**值**（`(timestamp, 6)`）。把 `sensorfw` 的 introspection 问完，它自己写着：

```
id                    ('orientationsensor',)
type                  ('OrientationSensorChannel',)
description           ('orientation of the device screen as 6 pre-defined positions',)
isValid               (true,)
interval              (uint32 100,)
getAvailableIntervals ([(5.0, 1000.0, 0.0)],)
```

**"orientation of the device screen as 6 pre-defined positions"** —— 这就是 Android 的 **device orientation**（HIDL `SENSOR_TYPE_DEVICE_ORIENTATION = 25`）：*六个离散位置*的分类器（1 portrait、2 landscape、3 reverse portrait、4 reverse landscape、5 face up、6 face down），不是一个角度流。

这一类传感器**在定义上就是 on-change**：它报的是"现在是哪一个位置"，不是"每秒多少度"。所以：

* 手机不动 → 位置没变 → **没有新样本**，这是**正确行为**；
* probe 的判据（读两次，看时间戳）在这种传感器上**永远读出 STALE**——那是判据的适用边界，不是故障。

`70`/`71` 记录的两条"它不流"的证据（"输入在流、它 559 秒不出新值"、"只在显示电源变化时刷新一次"）与"位置没变"完全一致；`78` §5 里那次"adaptor 一启动就出样本"也一样——启动时的**第一次分类**就是一次"变化"。

**要角度（连续量）用的是另外两个传感器**，它们都在流：

```
compasssensor   'compass north in degrees'          (timestamp, 225, 225, 225, 3)
rotationsensor  'x, y, and z axes rotation in degrees'  (timestamp, -1.0, 180.0, -45.0)
```

## 2. 剩下那个真问题：分类器说 `6`，加速度计说屏幕朝上

`scripts/device/zl1-orientation-watch.sh --seconds 8`（静止，屏幕关着，uptime 42,595 s）：

```
   uptime    orientation  sample age        accelerometer (mG)
     42595   6            1018              -4.07, 22.43, 1010.05
     42597   6            1020              -3.71, 21.36, 1010.05
     42599   6            1023              -3.96, 21.96, 1010.85
     42602   6            1025              -3.06, 21.31, 1010.49
positions seen: 6   changes: 0
```

加速度计 z 稳定在 **+1010 mG**。按 Android 的坐标系（+Z 从屏幕指向用户），**平放的手机屏幕朝上时 z ≈ +1000 mG**——也就是 `5`（face up）。分类器报的是 `6`（face down）。**两者矛盾。**

两种解释，都要人来分：

1. **分类器判错了**（输入是加速度计+磁力计，磁力计这边也不干净：compass 报 `225°`、rotation 报 `(-1.0, 180.0, -45.0)`，都是"算法输出了但没标定"的形状）；
2. **分类器没错，是它自己的编号跟 Android 文档不同**（Qualcomm 的 SSC 里 `dev_ori` 的取值不保证与 AOSP 的 `DEVICE_ORIENTATION_*` 一一对应）。

用这个脚本就能分开：**把手机拿起来、翻个面**，同一张表里两列一起看。如果翻成屏幕朝下时分类器变成 `5`，那就是编号约定不同；如果它一直卡在 `6` 不动，那就是判位坏了（或者这个算法根本没在跑——注意 `ro.vendor.sensors.dev_ori: false` 这个属性）。

**为什么这件事不只是学术问题**：`qtmir` 读的就是这个值来决定 shell 的横竖，`71` 量到 `6` 被它映射成 `Qt::InvertedLandscapeOrientation`，于是 shell 摆成横屏。**这台设备"老是横屏"的上游就是这一个数。** 在分类器可信之前，横屏会继续出现；把 `orientationsensor` 关掉（`sensorfwd -c=<path>`，`72` §6.3 那个还没用过的杠杆）换一个**稳定竖屏、没有自动旋转**是一个**取舍**——`71` §7 已经把它挂在那儿等用户决定，这一节只是把它的依据补全。

## 3. 九个传感器一次量全（第一次）

同一轮里对每一个都做了三件事：`loadPlugin`、`requestSensor`（持一个会话）、读 `id`/`type`/`description`/`interval`/`isValid`，再用 probe 读两次值。

| 传感器 | 值（一次读数） | 状态 | `interval` (ms) | sensorfw 自己写的描述 |
|---|---|---|---|---|
| `accelerometersensor` | `(-3.19, 20.24, 1009.14)` mG | **STREAMING** | 100 | x, y, and z axes accelerations in mG |
| `gyroscopesensor` | `(-92.7, -53.3, 8.7)` mdps | **STREAMING** | 50 | x, y, and z axes angular velocity in mdps |
| `magnetometersensor` | `(3, 14939, -15420, -43800, …)` nT | **STREAMING** | 10 | magnetic flux density in nT |
| `compasssensor` | `(225, 225, 225, 3)` 度 | **STREAMING** | 100 | compass north in degrees |
| `rotationsensor` | `(-1.0, 180.0, -45.0)` 度 | **STREAMING** | 100 | x, y, and z axes rotation in degrees |
| `proximitysensor` | `(uint32 5)` | SLOW（on-change 类，6–14 s 一次） | 0 | whether an object is close to device screen |
| `orientationsensor` | `(uint32 6)` | STALE **（应当如此，见 §1）** | 100 | orientation of the device screen as 6 pre-defined positions |
| `alssensor` | `(0, 99)` | 值在动但**时间戳恒为 0**（见 `78` §6） | 0 | ambient light intensity in lux |
| `pressuresensor` | — | **没有对象**（plugin `loadPlugin` 返回 true，但 `requestSensor` 之后 `/SensorManager/pressuresensor` 不存在） | — | （无） |

所以"9 个传感器"里：**5 个连续量在流**（加速度计、陀螺仪、磁力计、指南针、旋转），1 个是 on-change 的接近传感器（读到的值 6 秒前刚更新过，14 秒时没再变——它报的是"有没有东西靠近"，本来就不该每秒都出），1 个是位置分类器（`orientationsensor`，不该期待它流），1 个在流但从不盖时间戳（`alssensor`），1 个根本没有这个传感器（`pressuresensor`）。顺带一句给以后：`availableSensorPlugins` 列的是**插件**，不是硬件——`pressuresensor` 就是列了但没有对象的那种。

## 4. 复现

```bash
cp scripts/device/zl1-orientation-watch.sh root@10.15.19.82:/tmp/
# 拿起来、翻个面、放回去，看着两列
ssh root@10.15.19.82 'sh /tmp/zl1-orientation-watch.sh --seconds 60'

# 只看一个传感器是什么（不问值）
ssh root@10.15.19.82 'gdbus introspect --system --dest com.nokia.SensorService \
  --object-path /SensorManager/orientationsensor | sed -n "/interface local/,/^  };/p"'
```

| 文件 | 作用 |
|---|---|
| `scripts/device/zl1-orientation-watch.sh` | 新增。每秒打一行"uptime / 分类器的位置 / 这个样本多旧 / 加速度计三轴"，跑完给"见过哪些位置、变了几次"，并在结尾说明 5=face up、6=face down 这些编号。只读：握两个会话、读属性，不重启任何东西、不写设备 |
| `docs/ubuntu-touch/evidence/sensors-recovered-without-reboot-2026-09-23.log` | 同一份证据里加了 §"THE NINE SENSORS, ONE PAGE" 和 §"THE ORIENTATION WATCH" |

## 5. 这一轮**不**证明什么

* **不证明分类器的值是对的，也不证明它是错的**（§2）：只能证明它和加速度计矛盾，分开两者需要把手机拿起来——那是人的动作。
* 不证明 `rotationsensor` / `compasssensor` 的值**可用**：它们**在流**，但读数形状（`(-1.0, 180.0, -45.0)`、方位 225°）像是没标定的输出。能不能直接拿去做罗盘/姿态，没测。
* 不证明 `proximitysensor` 的 `5` 是什么意思（描述只说"是否有东西靠近屏幕"）。
* **没有**动 `orientationsensor` 的配置，**没有**为了"修横屏"去关任何传感器——那是个取舍（§2 末段），等用户定。
* 没有重启、没有分区写、没有改容器里的文件；`ActiveOutputs` 仍是 `(ii) 0 0`。
