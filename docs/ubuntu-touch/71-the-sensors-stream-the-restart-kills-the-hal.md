# 71 — 传感器不是坏的：缺的是 `start()`；而**每次重启 `sensorfwd`，容器的 sensors HAL 都会自杀一次**（毫秒级同一时刻，6/6）

**日期**: 2026-09-22
**状态**: **三件互相咬合的事量清楚了，前两件推翻了 [`70`](70-the-landscape-was-the-shell-laying-itself-out.md) §6 的判断。**

1. **`accelerometersensor` 没有"没注册"** —— 那是量错了。sensorfw 的调用是三个而不是两个：`loadPlugin(name)` → `requestSensor(name, pid)` → **`<obj>.start(sessionId)`**。少了最后一步，一个完全健康的传感器会一直回放"上一次别人启动它时"的那个值，读起来就是"冻住/没数据"。按三段顺序调，**加速度计、磁力计、陀螺仪都在流**（实测：`xyz` 两个相隔 10 秒的读数是 `(8674999894, -1.56, 21.50, 1016.0)` 和 `(8684997475, -1.52, 23.35, 1017.2)`，手机平放，z 轴 ~1 g）。
2. **"传感器全是旧值"的来源是我们自己的 `systemctl restart sensorfwd`**：这个 boot 里 6 次 sensorfwd 停止，**6/6** 都在毫秒级同一时刻对应容器里一行 `ISensors::poll() re-entry. I do not know what to do except killing myself.`（vendor sensors HAL 自杀），随后 +0.4 秒一个新的 HAL 实例重新注册。**`requestSensor`/`start` 不会杀它**（一次 300 秒的会话里，1 个、2 个 adaptor 都试过，零次自杀）。所以这台设备上"重启 sensorfwd 修传感器"是反的。
3. **真正不流的是 `orientationsensor`**：它的两个输入（加速度计、陀螺仪）都在流，它自己**559 秒没有出过新值**，最后一个是显示电源事件那一刻算出来的 `6`。而**横屏的触发量出来了**：电源键 → 显示电源变化 → qtmir 重读这个缓存值 → `6` 被映射成 `Qt::InvertedLandscapeOrientation` → shell 采纳。**所以 [`70`](70-the-landscape-was-the-shell-laying-itself-out.md) §5 的"重启 greeter 回竖屏"不是持久解，按一下电源键就可能横回去。**

**接续**: [`70`](70-the-landscape-was-the-shell-laying-itself-out.md)（横屏与 §6 的传感器现状，本文更正它）、[`69`](69-repowerd-died-on-a-startup-race-with-sensorfwd.md)（repowerd 的启动竞态）、[`60`](60-sensorfwd-was-the-third-service-behind-the-same-wall.md)（sensorfwd 自己）

---

## 1. sensorfw 的调用是三个，不是两个

```
loadPlugin(name)          -> 加载插件，(true,) / (false,)
requestSensor(name, pid)  -> 建一个会话，返回 session id；插件没加载就回 -1
<iface>.start(sessionId)  -> 会话开始出数据（对应 stop(sessionId)）
```

`/SensorManager/<x>sensor` 那个总线对象是**会话出现之后**才有的，所以 `busctl tree` 看起来像"硬件清单"；`loadPlugin` 单独调用**不会**建对象（实测：`--load-all` 把 9 个插件全部加载成 `(true,)` 之后，树里仍然只有客户端 `requestSensor` 过的 4 个；而在另一次运行里对 `accelerometersensor`/`gyroscopesensor` 显式 `requestSensor`，树里就正好多出这两个）。

`start()` 那一步最容易被漏掉，因为**漏掉它不会报错**：属性照样读得到一个合法的 `(时间戳, 值)`，只是那个时间戳是别人启动它时的。这就是我把"冻住"当成"没有数据"的由来 —— 也是 [`70`](70-the-landscape-was-the-shell-laying-itself-out.md) §6(1) 里那张"只有 magnetometer/orientation 注册了"的表错在哪。

## 2. 按三段顺序调之后：谁在流，谁不在

`scripts/device/zl1-sensorfw-probe.sh`（本次重写：补上 `start()`，并且**不再只比较两次读数，而是把每个读数的时间戳换算成"最后一个样本是多少秒以前"**）在 uptime 8662–8707、sensorfwd 实例启动于 7798 的情况下：

| 传感器 | 值属性 | 读到的值 | 最后一个样本 | 判定 |
|---|---|---|---|---|
| `accelerometersensor` | `(tddd) xyz` | `(8674999894, -1.56, 21.50, 1016.0)` → `(8684997475, -1.52, 23.35, 1017.2)` | 0 秒前 / 0 秒前 | **STREAMING** |
| `magnetometersensor` | `(tiiiiiii) magneticField` | `(8719541900, 3, -7800, -12600, -50579, -7800, -12600, -50579)` → `(8729589225, 3, -7739, -13319, -50399, …)` | 0 秒前 | **STREAMING** |
| `gyroscopesensor` | `(tddd) value` | `(0, 0, 0, 0)` → `(8767230349, 26.23, 6.99, 19.23)` | 0 秒前 | **STREAMING**（`start` 之后第一个样本） |
| `orientationsensor` | `(tu) orientation` | `(8227499150, 6)` | **559 秒前** | **STALE** |
| `alssensor` | `(tu) lux` | `(0, 0)` | **8697 秒前 = 从没出过样本** | **STALE**（时间戳是 0） |

两点解释：

- **"两次读数相同"不是判据，"样本多老"才是。** 一个 40 秒前的样本和一个上一次 boot 的样本，用两次读数看都是"没变"；换成 age 一眼就分开。probe 现在打三种判定：`STREAMING`（窗口内来了新样本）/ `SLOW`（窗口内没有，但最后一个很新 —— 这是 adaptor 正在起转的形态，实测从一个 `start` 到第一个样本要 10~20 秒）/ `STALE`（附具体秒数）。
- **加速度计/陀螺仪的"平放不动"是能对上的**：z ≈ +1015 mG、x/y ≈ 0，正是屏幕朝上平放；陀螺仪在 uptime 8767 读到 `(26.23, 6.99, 19.23)`、8786 读到 `(26.23, 6.99, 59.45)`、8960 读到 `(-37.59, -0.87, -27.10)` —— 两次逐位相同只是量化，第三次整体不同，说明它在正常出噪声范围内的真实值。

**磁力计那个 7 元组**：接口声明的签名就是 `(tiiiiiii)`，值里 `x,y,z` 出现了两遍（`-7800,-12600,-50579` 重复）。这是这个通道自己的形状，不是读错，先照原样记。

## 3. 每次 `restart sensorfwd`，容器的 sensors HAL 就自杀一次

这个 boot 里 sensorfwd 的每一次停止，和容器 logcat 里 HAL 的自杀，是**同一毫秒**：

| sensorfwd `Stopping`（host journal，单调时钟） | HAL `ISensors::poll() re-entry` | 新 HAL 实例 `Registration complete` |
|---|---|---|
| 4891.491 | 4891.472 | 4892.0 |
| 6524.937 | 6525.189 | 6525.605 |
| 6538.511 | 6538.512 | 6538.899 |
| 7242.665 | 7242.661 | 7243.074 |
| 7399.946 | 7399.948 | 7400.368 |
| 7798.273 | 7798.273 | 7798.667 |

**6 次停止 / 6 次自杀**（另外两次自杀在 journal 已经开始之前的位置，见 §8 的说明，无法配对）。自杀那句是 vendor HAL 自己的话：

```
E /vendor/bin/hw/android.hardware.sensors@1.0-service: ISensors::poll() re-entry. I do not know what to do except killing myself.
```

而 **`requestSensor` / `start` / `loadPlugin` 不会杀它**。受控试验（一次 300 秒）：停掉的两个阶段里每次都只有一次自杀、都紧跟在 `systemctl restart sensorfwd` 后面 3 毫秒；之后**只请求磁力计**、放 60 秒，没有自杀；**再加上加速度计**（2 个 adaptor 同时跑）、再放 75 秒，还是没有自杀。所以"多个 adaptor 同时取数"是安全的，**唯一会杀死 HAL 的是 sensorfwd 的停止动作本身**（它退出时的 `stop all sensors` / `setActive(false)` 序列）。

**后果就是"所有传感器都是旧值"**：HAL 自杀后 0.4 秒会有个新实例注册，但那一刻 sensorfwd 已经不在（或正在退出），它手里握着的是**上一具尸体**的连接，于是每个属性都停在最后一次收到的样本上。实测最刺眼的一条：uptime 7251 时加速度计回的样本时间戳是 **6853**（600 秒前、上一具 HAL 尸体生前），而同一个实例里磁力计在 7257 拿到过新样本 —— 说明**连接是不是活的，取决于新 HAL 与 sensorfwd 启动哪个先到**，同一具 sensorfwd 里不同传感器可以一个死一个活。

**操作规则（写下来免得下次又"重启试试"）：这台设备上不要用 `systemctl restart sensorfwd` 来修传感器。** 它的结果是一场赛跑：赢了（新 HAL 先注册）数据会流，输了（§3 那种 600 秒前的样本）就是永久冻住，而且**每次重启都要重新掷一次**。要重新加载插件，用总线上的 `loadPlugin`，不需要重启进程。

## 4. 真正不流的那一个是 `orientationsensor`

它两个输入都在流（§2 的加速度计 + 陀螺仪），`start` 也调过了，它自己**从 uptime 8227.5 之后一直没有出过新值**（8786 时是 559 秒，8960 时已经是 732 秒，值始终是 `(8227499150, 6)`）。8227.5 是这次**面板被点亮**的时刻（我用 repowerd 的 `keepDisplayOn` 唤醒，随后重启 greeter 回竖屏）—— 也就是说**这个样本是"显示电源事件"算出来的**，和 [`70`](70-the-landscape-was-the-shell-laying-itself-out.md) §3 记的"只在显示电源变化时刷新"完全一致，现在多了一句：**在输入传感器持续供数的情况下，它仍然不刷新**。

这一条比 `70` §6(4) 那个"竖着拿 20 秒"的分叉更进一步：**不用有人去拿手机了**，"姿态算错"和"没有数据"里的后者已经排除——数据在流，是方向这个虚拟传感器自己不出值。`orientationChanged` 信号在 [`70`](70-the-landscape-was-the-shell-laying-itself-out.md) §3 里 30 秒抓不到一条，也是同一件事。

## 5. 横屏的完整触发链（这次是从电源键开始，逐行）

用户报的"现在变成横屏了"之前的 2.4 秒，日志是这样的：

```
[ 6673.524983] systemd-logind: Power key pressed short.                              <- 电源键
[ 6673.977621] lomiri: qtmir.sensor: OrientationSensor::onDisplayPowerStateChanged   <- 屏幕电源变化
[ 6673.985527] sensorfw: minLimit: 0 0 / maxLimit: 2147483647 2147483647             <- 一次成功的 load_plugin（repowerd 的光传感器）
[ 6674.000970] lomiri: qtmir.sensor: OrientationSensor::readingChanged
[ 6674.025965] lomiri: qtmir.sensor: PlatformScreen::customEvent() - unknown orientation.      <- 不改现状
[ 6674.534912] lomiri: qtmir.sensor: OrientationSensor::readingChanged
[ 6674.535612] lomiri: qtmir.sensor: PlatformScreen::customEvent() - new orientation=Qt::InvertedLandscapeOrientation   <- 采纳了
[ 6674.627384] systemd-logind: Power key pressed short.                              <- 又按了一次
[ 6675.233458] systemd-logind: Power key pressed short.
[ 6675.849916] lomiri: qtmir.sensor: OrientationSensor::readingChanged
[ 6675.880017] lomiri: qtmir.sensor: PlatformScreen::customEvent() - new orientation=Qt::InvertedLandscapeOrientation
```

三件事因此成立：

1. **触发是显示电源变化，而不是"新数据"** —— 是屏幕亮/灭让 qtmir 去**重读那个缓存值**。
2. **只要缓存值是 `6`，重读的结果就是横屏**（两个不同的电源事件各自采纳了一次 `InvertedLandscape`，两次都在 1 Hz 轮询读到 `6` 的窗口里）。同一秒里那次 `unknown orientation` 说明**值在短暂的起转瞬间是动过的**（1 Hz 的轮询看不到亚秒变化），但落定之后就是 `6`。
3. **所以 `70` §5 的缓解是有条件的，而条件已经明确**：重启 greeter 让 `orientation` 变量回到初值（竖屏），但**任何一次电源键/亮灭屏都会重新采纳 `6`，也就是横回去**。要真正不横，得让 `6` 不再出现（§7）。

顺带一个观察，不是结论：`6` 是在手机平放、屏幕朝上、加速度计 z ≈ +1015 mG 的情况下算出来的；`30-hidl.conf` 给加速度计的坐标矩阵是单位阵。这条链里"哪一处把上下反了"还没有量到 —— 但**现在有两个在流的输入**，这条链第一次是可查的。

## 6. 现在设备的状态（我做过的事）

- **显示**：面板从 `suspend` 唤醒到 `alive`、背光 200，用 repowerd 自己的接口（`keepDisplayOn`，返回 request id `i 7` / `i 8` / `i 9`）；另外把 `setInactivityTimeouts` 调大（1800/3600），免得刚亮又灭。
- **方向**：重启 `lomiri-full-greeter.service`（新 MainPID 393309，`NRestarts=0`），qtmir 报 `Screen - initial currentOrientation is: Qt::PortraitOrientation` → **竖屏**。
- 容器 RUNNING（PID 35057），`systemctl --failed` 空，repowerd / sensorfwd active，SSH 正常。**没有碰任何分区、没有动 boot 镜像、没有改容器内的文件、没有改 `/etc/sensorfw`（它是只读的，见 §7）。**

## 7. 下一步

1. **`orientationsensor` 为什么不出值**（§4）。现在它的输入是可用的，所以可以在不动整条链的前提下查：把 sensorfwd 的日志级别抬到 `debug`（用一条 `ExecStart` 复述型的 drop-in，**不要**用 `setsid` 手工探针 —— [`60`](60-sensorfwd-was-the-third-service-behind-the-same-wall.md) 记着那会抢走总线名把真 unit 卡在 activating），看 `OrientationSensor` 的 chain/`orientationinterpreter` 有没有在跑 `evaluateSensor`。
2. **一个新的、可用的杠杆**：`/usr/sbin/sensorfwd --help` 里有 **`-c=P, --config-file=<path>`**（默认 `/etc/sensorfw/sensord.conf`）。`/etc/sensorfw` 是只读镜像、动不了，但 `/etc/systemd/system` 是可写白名单路径，所以**一条 drop-in 就能让 sensorfwd 吃一份我们放在 `/userdata` 的配置**。这打开了两个实验：（a）换加速度计的坐标矩阵，看 `6` 变不变；（b）`[available] orientationsensor=False`，让方向传感器干脆不注册 —— 代价是**没有自动旋转**，但换来的是**竖屏稳定**。这是取舍，不是纯技术选择，**要不要做等用户一句话**，不擅自改。
3. **HAL 自杀这件事本身**（§3）：它是 vendor HAL 里的 `poll()` 重入保护，触发者是客户端在 poll 飞行途中消失。修它属于容器侧（改 vendor 镜像），不是现在这一步；现在只需要知道**别去踩**。可查的第一条线索是那句话里的线程号（每次自杀都不是主线程在报，例如 `7166 7166` 的主线程 vs `7733 7819` 的 `7819`）。
4. [`70`](70-the-landscape-was-the-shell-laying-itself-out.md) §6 剩下的两条仍在：`vsimd` 报 `libQSEEComAPI.so` not found（文件在）、`android.frameworks.sensorservice@1.0::ISensorManager/default` 永远在等（那个进程就是 sensors HAL 自己 pid 476）。
5. **`alssensor` 从来没有过一个样本**（时间戳 0）—— repowerd 的自动亮度拿不到光强。这是一条独立的小线。

## 8. 文件与复现

| 文件 | 作用 |
|---|---|
| `scripts/device/zl1-sensorfw-probe.sh` | 三段调用（load → request → **start**）+ age 判定。头部写清了它**会扰动被测对象**（`loadPlugin` 会起 adaptor，而起 adaptor 本身就会让这块硬件出一个样本），以及"漏掉 `start` 会让健康传感器看起来是死的"这两个坑 |
| `docs/ubuntu-touch/evidence/sensorfw-hal-suicide-2026-09-22.log` | 本文的证据集：sensorfwd 的每次停/起、HAL 的每次自杀/重注册（单调时钟）、电源键那 2.4 秒、四个传感器的 age、`/etc/sensorfw` 只读的证明、结束时的体检 |

```sh
# 谁在流、谁不在（age 是判据；settle 要够大，adaptor 起转要 10~20 秒）
sh /userdata/zl1-sensorfw-probe.sh --load-all --settle 12 --gap 10 --keep 300

# sensorfwd 的停止 与 HAL 的自杀 是不是同一时刻（两边都是单调时钟）
journalctl -b -o short-monotonic | grep -E "Stopping sensorfwd|Starting sensorfwd"
nsenter -t 35057 -p -m logcat -d -v monotonic | grep -E "poll\(\) re-entry|Registration complete for android.hardware.sensors"

# 正在测的东西的状态：sensorfwd 起于哪个 uptime（age 要跟它比，不是跟 uptime 本身比）
systemctl show sensorfwd -p ExecMainStartTimestampMonotonic --value | awk '{printf "%d\n", $1/1000000}'

# 横屏的直接判据（shell 自己报的），以及电源键那条链
journalctl -b -o short-monotonic _COMM=lomiri | grep -E "currentOrientation|new orientation=|unknown orientation"
```

> **一处 journal 的坑**：这个 boot 的 journal 只从 uptime 4891 起有记录（更早的部分已经不在），所以表里只有 6 次配对；`journalctl -b` 在这台设备上是**不完整**的，别把"没找到"当成"没发生"。设备时钟仍然是错的（[`64`](64-the-last-unit-was-not-failing-it-was-obeying.md)），只有单调时钟能用来排序 —— 这次还看到墙钟在测量期间往回跳了 13 小时，`logcat` 的默认时间戳因此完全不可用于排序，**必须加 `-v monotonic`**。

**设备安全**：只往 `/userdata/` 写（probe 脚本、`probe-after-restart.out`）。只读地看 `/proc`、`/sys`、journal、容器 logcat、`/vendor`。改变设备状态的动作共四类，都可逆：**重启 `lomiri-full-greeter.service`**（用户单元，`Restart=on-failure`，起来后报 `initial currentOrientation is: Qt::PortraitOrientation`）、**用 repowerd 自己的接口按住显示**（`keepDisplayOn` / `setInactivityTimeouts`）、**`systemctl restart sensorfwd`**（这条在 §3 里被证明有害，已停止使用；本次若干次重启都是为定位它而做的，之后不再做）、以及在总线上 `loadPlugin`/`requestSensor`/`start` 传感器（只读数据）。`/dev/fb0/rotate`、面板模式、`/etc/sensorfw`、容器内文件全部没动。
