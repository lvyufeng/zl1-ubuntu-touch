# 78 — 传感器全灭 8.2 小时后不用重启就回来了：HAL 卡死在一次 `batch()` 里，客户端握着它的尸体

**日期**: 2026-09-23
**状态**: **加速度计、陀螺仪、磁力计当场恢复**（由新起的客户端实测 STREAMING），恢复方式是不重启、不刷任何东西，只按一个**固定顺序**动两个进程。同一个动作还把 `orientationsensor` 逼出了 8.2 小时里第一个真样本（但它仍然只出一次）。另外收窄了 [`71`](71-the-sensors-stream-the-restart-kills-the-hal.md) §3/§4 那条"**别**重启 `sensorfwd`"的操作规则：错的不是"重启"，是"**单独**重启"——顺序能把那次掷硬币变成确定的事，`scripts/device/zl1-sensors-recover.sh` 就是把它固定下来的那个脚本。

**接续**: [`71`](71-the-sensors-stream-the-restart-kills-the-hal.md)（sensorfwd 停止会杀 HAL、`orientationsensor` 不流）、[`72`](72-the-heat-was-the-governor-and-a-debug-keeper.md) §4b(d)（sensorfwd + sensors HAL 是唯一两个大的用户态 CPU 大户）、[`68`](68-the-camera-stage-was-one-cookie-in-the-stub.md) §5（判据要用合成器自己的 CPU，不要信 app 自报）

---

## 1. 症状：9 个传感器全 STALE，而"年龄比 HAL 还老"这一条就说明不是硬件

`scripts/device/zl1-sensorfw-probe.sh --load-all` 在 uptime 41,183 s：

```
local.AccelerometerSensor.xyz          last sample 28975 s ago   (timestamp 12323934179)
local.GyroscopeSensor.value            last sample 29037 s ago
local.MagnetometerSensor.magneticField last sample 29068 s ago
local.OrientationSensor.orientation    last sample 29520 s ago   (11902936926, 6)
local.ALSSensor.lux                    last sample 41330 s ago   (0, …)
```

9 个插件都 `loadPlugin -> (true,)`、`requestSensor` 都返回会话号、`start()` 都不报错——**接口全是好的，值一个都不动**。

关键是这几个 age 和进程的年龄放在一起看（`ps -eo pid,etimes`，uptime 40,806 s）：

| 进程 | pid | etimes | 起于 uptime |
|---|---|---|---|
| `sensors@1.0-service`（容器的 HAL） | 938936 | 28437 | **12,369 s** |
| `sensorfwd` | 216350 | 33007 | 7,799 s |
| `sensors.qti`（SSC/SLPI 代理） | 41607 | 40758 | 开机就在 |

**最新的样本（uptime 12,323.9 s）比正在跑的那具 HAL 的启动时刻（12,369 s）还早 45 秒。** 也就是说：活着的那具 HAL **一辈子没送出过一个样本**，那些"最后一个值"是它**前一具**留下的。加上 SLPI（`subsys4`）报 `state=ONLINE`，责任就不在硬件也不在固件。

这条判据不是新发明，probe 自己的脚注就是这么写的（"把 age 和 uptime 比一比"），这里只是把它从"守护进程"层次推到"进程"层次。

## 2. 内核能看到的：一个永远不会返回的 HIDL `batch()`

这台内核的 `/sys/kernel/debug/binder` 是**一个文件装两个上下文**——每个进程下分别有 `context binder` 和 `context hwbinder`——所以 HIDL 调用从主机侧就能读。uptime 40,982 s：

```
proc 938936                                   ← 容器的 sensors HAL
context hwbinder
  thread 938936: l 02 need_return 0 tr 0
    incoming transaction 1838445: from 216350:939021 to 938936:938936
      code 4 flags 10 pri 0:120 r1 node 1838258 size 44:0
  node 1838258: ... hs 1 hw 1 ls 1 lw 0 is 2 iw 2 tr 1 proc 216350 40677
proc 216350                                   ← sensorfwd
context hwbinder
  thread 939021: l 10 need_return 0 tr 0
    outgoing transaction 1838445: ... from 216350:939021 to 938936:938936 code 4 ... r1
  ref 1838283: desc 1 node 1838258 s 1 w 0
```

逐条读出来：

* `node 1838258` 就是 ISensors 节点，持有者只有 **sensorfwd(216350) 和 hwservicemanager(40677)**。
* `code 4` 是 HIDL 方法序号 4 = `ISensors::batch()`，`r1` = 需要回复，所以这是一次**双向调用**；`size 44` = 24 字节 HIDL 打包头 + handle(4) + sampling period(8) + max report latency(8)，和 `batch()` 的入参对得上。
* 客户端线程 939021 停在 `binder_thread_read`——**在等回复**；服务端主线程 938936 把这个事务挂在自己栈上（也就是**正在 `batch()` 里面**），而它的 wchan 是 `futex_wait_queue_me`：**睡在调用内部的用户态锁上**，不是在核里。
* 6 秒后再读，**一字不变**。不是慢，是永远不返回。
* 它和沉默对得上：最新样本在 12,323.9 s，栈已经哑了 28,900 s。

顺带量了一下这具 HAL 的其余 75 个线程：`37 futex_wait_queue_me | 36 poll_schedule_timeout | 1 diagchar_read | 1 binder_thread_read`——36 个按传感器分的取数线程都停在"等数据"的 ppoll 上，形状正常。容器的 binder 整体是**全静**的：最高事务号隔 61 秒采样两次都是 `1993203`，`0 tx/s`。（这也是为什么卡死那次没法用"事务速率"定年，只能用样本年龄定。）

**`orientationsensor` 的嫌疑顺带被点亮**：它恰好是唯一一个不流的传感器，而卡住的那次调用恰好是 `batch()`；`batch()` 是**启动一个流**的调用。这条链**没有被证明**——事务体里那几个字节在主机侧读不到，历史 logcat 也早被刷掉了。写在这里当一个有支撑的假设，不是结论。

## 3. 两步：先杀 HAL（没用），再重启客户端（起效）

### 第一步：`kill -9 <HAL>`（uptime 41,260 s）

init 的服务名是 `vendor.sensors-hal-1-0`（`class hal`、没有 `oneshot`，所以 init 一定会把它拉起来）：

* 13 秒后新实例 `1785710`（`comm=sensors@1.0-ser`、`ppid=35057`=容器 init、**74 线程**），主线程停在 `binder_thread_read`——**卡死的那次调用随着旧进程一起没了**；
* 它重新注册成功（`node 2174420`），但**持有者只有 `40677`**，也就是只有 hwservicemanager——**一个客户端都没有**；
* 再跑 probe：**还是全 STALE，时间戳和杀之前一模一样**（`orientation` 仍是 `11902936926`）。

**结论：修 HAL 单独不够。** 一具健康但没人连的 HAL，看起来和死的一样。

### 第二步：`systemctl restart sensorfwd`（uptime 41,575 s）

`216350 -> 1796648`，`ActiveState=active`，`repowerd`（1320231）全程没动。而且这次**HAL 没被带下去**（60 秒后还是 1785710）——见下一节。

重启后默认只有三个总线对象存在（`alssensor`、`magnetometersensor`、`orientationsensor`，即 repowerd 订阅的那三个），`requestSensor` 的会话号从 11 起（不是 58），都说明这是一具全新的守护进程。

然后，**用重启后新起的客户端**量（不是旧会话）：

```
磁力计 (settle 20/gap 12)
  read #1: (41807325000, 3, 14700, -15420, -44219, ...)   age 0 s
  read #2: (41819417006, 3, 14460, -16200, -43980, ...)   age 0 s   => STREAMING

加速度计 / 陀螺仪（它们没有总线对象，必须用 --sensor 点名才量得到）
  accel  (41887172570, -3.3655, 20.9915, 1010.416)  age 10 s
  accel  (41897270091, -3.2784, 21.4754, 1009.705)  age  0 s        => STREAMING
  gyro   (41887234338, 26.2279,  6.9941,   13.1140) age 10 s
  gyro   (41897381847, 26.2279, 31.4735,   13.1140) age  0 s        => STREAMING
```

**三个传感器回来了**，每个都由一个重启前不存在的客户端 pid 测得。压力/接近/指南针/旋转**没测**。

## 4. 收窄 [`71`](71-the-sensors-stream-the-restart-kills-the-hal.md) §3/§4：错的不是"重启"，是"单独重启"

doc 71 量到的是：**这个 boot 里 sensorfwd 每停一次（6/6），容器的 HAL 就在同一毫秒自杀一次**（`ISensors::poll() re-entry. I do not know what to do except killing myself.`），机制是"客户端在 poll 飞行途中消失"；§4 因此写下操作规则：**别用 `systemctl restart sensorfwd` 修传感器**——它是场赛跑（新 HAL 先注册就流、否则永久冻住），每次重启重掷一次。

今天量到的是：

1. **这次重启 HAL 没自杀：0/1。** 机制没变，变的是前提：老 sensorfwd 手里那个连接**本来就是死的**（它连的是已经被杀掉的 938936 那具节点），退出时它要调的 `setActive(false)` 只可能拿到 `BR_DEAD`，**没有"飞行中的 poll"可以触发自杀**。所以"重启必然杀 HAL"不是必然，它取决于客户端此刻是不是真的连着。**这是推断，不是测量**——测到的是"没自杀"这一个事实。
2. **顺序能把 §4 的硬币拿掉。** §4 说结果取决于"新 HAL 和 sensorfwd 谁先注册"。那么先把 HAL 杀掉、**等它在 binder dump 里重新注册（hwservicemanager 持有节点）**、再重启客户端，客户端一上来就有活的服务端——硬币不用掷了。今天的 1/1 与这个机制一致。
3. 因此规则要改成：**别单独重启 `sensorfwd`；要修就按 `HAL → 等注册 → 客户端` 的顺序走**（`scripts/device/zl1-sensors-recover.sh`）。

## 5. `orientationsensor`：一个样本，出现在 adaptor 启动后 1.8 秒

重启前它的值停在 `(11902936926, 6)`——uptime **11,902.9 s** 的遗物（29,520 秒前）。重启之后：

```
(41576823352, 6)      uptime 41,576.8 s
```

新 sensorfwd 的启动时刻是 uptime 41,575 s，**样本晚了 1.8 秒**。这是 8.2 小时里第一个真样本、是新守护进程算的，不是旧值。然后**它又冻住了**：10 秒后、262 秒后、320 秒后、482 秒后读到的都是 `41576823352`，值始终是 `6`。

这和 probe 自己的注意事项对得上（"**adaptor 的启动本身就会让这块硬件出一个样本**"），所以它把 orientation 的病灶**收窄成一句话**：整条链（SSC 的 orientation 算法 → sensors HAL → hidlorientationadaptor → 总线对象）**能算、能出**，缺的是**后续更新**。它仍然不是"硬件没有这个传感器"。

## 6. 顺手纠正一条我自己的读数：`alssensor` 不是"从来没出过样本"

probe 的 age 判据把 `local.ALSSensor.lux` 判成"timestamp 0 = 从未有过样本"（[`71`](71-the-sensors-stream-the-restart-kills-the-hal.md) 和记忆里都这么记的）。实际上它的**时间戳**一直是 0，但**第二个字段在动**：

```
(0, 94) -> (0, 96) -> (0, 98) -> (0, 97)
```

也就是说这个 adaptor **不给自己盖时间戳**，而值在变。老的判据（只看时间戳的 age）会把它判成"死"，只看"两次读是否相同"会把它判成"活"——**两个都对一半**。probe 现在把这种情况单独说清楚：时间戳为 0 且值在动 → `STREAMING (the value moves, but the timestamp is 0 -- this adaptor never stamps its samples)`；时间戳为 0 且值不动 → 明说"这个 adaptor 不盖时间戳，值也没动"。（这**不**等于说自动亮度就好了——repowerd 拿这个值做什么、值跟不跟真实光强，都没测。）

## 7. 复现

```bash
# 看一眼（什么都不改）：HAL 的 pid/年龄、节点被谁持有、有没有在飞的事务、每个传感器的样本年龄
cp scripts/device/zl1-sensorfw-probe.sh scripts/device/zl1-sensors-recover.sh root@10.15.19.82:/tmp/
ssh root@10.15.19.82 'sh /tmp/zl1-sensors-recover.sh --status'

# 修（HAL -> 等注册 -> 客户端，然后自己 probe 一遍）
ssh root@10.15.19.82 'sh /tmp/zl1-sensors-recover.sh --recover'

# 单独量某个"没有总线对象"的传感器（加速度计、陀螺仪必须点名）
sh scripts/device/zl1-sensorfw-probe.sh --sensor accelerometersensor --sensor gyroscopesensor
```

| 文件 | 作用 |
|---|---|
| `scripts/device/zl1-sensors-recover.sh` | 新增。`--status`（只读）/ `--recover`（两步 + 复核）。先杀容器 HAL、**等它注册**，再重启 `sensorfwd`；不碰显示、不碰分区、不写容器文件系统 |
| `scripts/device/zl1-sensorfw-probe.sh` | 新增 `--sensor NAME`（点名一个还没有总线对象的传感器，加速度计/陀螺仪就属于这种）；`report()` 现在能区分"时间戳 0 但值在动"和"时间戳 0 且不动"；脚注里那条"别重启 sensorfwd"改成"别**单独**重启" |
| `docs/ubuntu-touch/evidence/sensors-recovered-without-reboot-2026-09-23.log` | 本次全部读数：冷态清单、binder 片段、tx 速率 0/s、两步前后、orientation 那一个样本、结束时的体检 |

## 8. 这一轮**不**证明什么

* **不证明"只重启客户端就够了"**：两步是连着做的，HAL 那一步是否**必要**没有分离（旧 HAL 是卡死的，新客户端去调它大概率还是卡——但这是推理）。
* **不证明这个卡死不会复发**，也**没查出根因**：谁让那具 HAL 在 uptime 12.37 ks 重启、为什么新实例一出生就卡在 `batch()` 里，两个都不知道。取向相同的事（§2 末段）只是假设。
* 不证明压力/接近/指南针/旋转传感器能用——它们**没测**。
* **不证明 `orientationsensor` 好了**（§5）：它只出一次。`alssensor` 的"值在动"也不等于自动亮度能用。
* 不证明**重启之后**还需要跑这个脚本——开机路径是不是自己就能收敛，没验（[`69`](69-repowerd-died-on-a-startup-race-with-sensorfwd.md) 的 drop-in 注释说开机时 `sensorfwd` 会重启几次直到 HAL 稳下来，今天量到的却是"开机后 12.3 ks 才坏"，两者不矛盾但也没对上）。
* 传感器恢复意味着 [`72`](72-the-heat-was-the-governor-and-a-debug-keeper.md) §4b(d) 里那对"最大的用户态 CPU 大户"回来了：它们全灭的这 8.2 小时里，全机只有 **0.87 个核**在忙（user 162 + sys 459 ticks / 10 s，idle 82%），恢复之后要不要重测发热，是下一轮的账。

**设备安全**：全程只往 `/userdata/` 写、只在 `/tmp` 放脚本；`ActiveOutputs` 收尾仍是发现时的 `(ii) 0 0`；`systemctl --failed` 空；`lxc` 容器 RUNNING；keeper（pid 817）仍停在 `T`（[`72`](72-the-heat-was-the-governor-and-a-debug-keeper.md) §3 的运行时状态）；**没有重启**（uptime 41,914 s 连续）、没有分区写、没有碰 boot 镜像、没有动容器里的文件。改变设备状态的动作只有三类，都可逆：杀容器 HAL（init 必然重启它）、`systemctl restart sensorfwd`（`Restart=always`）、总线上 `loadPlugin`/`requestSensor`/`start`（只读数据）。
