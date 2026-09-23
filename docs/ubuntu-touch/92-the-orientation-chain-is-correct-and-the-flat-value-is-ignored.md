# 92 — 方向这条链是对的：中间的翻译表逐名字对齐，而"平放"那个值 qtmir 根本不采纳

**日期**: 2026-09-23
**状态**: 纯离线的一轮（设备在 EDL，与 `86`–`91` 同）。这一轮把 `70` §5 / `71` §5 / `91` §1 留下的那个问题——"这条链里哪一处把上下反了"——**判死**：**没有任何一处反**。链上的三个二进制（`libqtsensors_sensorfw.so`、`liborientationinterpreter-qt5.so`、`libqt5mir1server.so.1`）和两份上游源码互相印证，端到端可以列成一张六行的表。直接后果有两个，都是否证性的：`91` §1 的候选修法（把 z 取负）**什么都不会改**；而 `91` 交付的那个探针（平放测 `z` 与 `5`/`6`）**不可能判定任何事**，因为平放落在 qtmir 一个明确忽略的分支上。

**接续**: [`91`](91-where-the-orientation-value-comes-from.md)（链的结构，本篇更正它的 §1 与 §6/§7）、[`70`](70-the-landscape-was-the-shell-laying-itself-out.md) §2/§5（设备侧唯一的日志）、[`71`](71-the-sensors-stream-the-restart-kills-the-hal.md) §5/§6（`z ≈ +1015 mG` 那条测量、电源键重放）、[`78`](78-the-sensors-came-back-without-a-reboot.md)（传感器栈的修法与顺序，仍是 undo）

---

## 1. 一句话结论

**端到端这张表，逐行都是对的：**

| sensorfw 的值 | 它自己的名字 | QtSensors 的值 | Qt 的名字 | qtmir 给屏幕的 |
|---|---|---|---|---|
| 1 | LeftUp（左边朝上） | 3 | LeftUp | `Qt::LandscapeOrientation` |
| 2 | RightUp（右边朝上） | 4 | RightUp | `Qt::InvertedLandscapeOrientation` |
| 3 | BottomUp（底边朝上＝倒了） | 2 | TopDown | `Qt::InvertedPortraitOrientation` |
| 4 | BottomDown（底边朝下＝正竖） | 1 | TopUp | `Qt::PortraitOrientation` |
| 5 | FaceDown | 6 | FaceDown | **不动**（日志 `unknown orientation.`） |
| 6 | FaceUp | 5 | FaceUp | **不动**（日志 `unknown orientation.`） |

（native orientation 是 `Portrait`——由 `1080x1920` 的几何直接算出来的，不是传感器读的，见 §5。）

三句话：

1. **中间那张翻译表是逐名字对齐的**：LeftUp→LeftUp、RightUp→RightUp、BottomUp→TopDown、BottomDown→TopUp、FaceUp→FaceUp、FaceDown→FaceDown。它不反任何东西（§3）。
2. **"手机平放、屏幕朝上、报 6"从来不是故障。** sensorfw 自己的枚举里 FaceUp 就是 6（Qt 的枚举里 FaceUp 是 5），`processFace()` 就是"z > 0 → 6"（§4）。同一个数在两家叫不同的名字，而 `70`/`71`/`91` 把它读成了"6 = FaceDown，所以哪一处反了"——那是把 Qt 的枚举名字套到了 sensorfw 的编号上。
3. **而"平放"这个位置 qtmir 根本不采纳**：`FaceUp`/`FaceDown` 两个值走 `default:` 分支，只打一行 `unknown orientation.`，`m_currentOrientation` 一个字节都不动（§5）。所以**平放永远不可能让屏幕转，也不可能让屏幕转回来**——这是上游设计，不是这个端口的毛病。

于是 `91` §1 那一行候选修法（`transformation_matrix = "1,0,0,0,1,0,0,0,-1"`）**改了也不会看见任何变化**：6 变成 5（或反过来），两个值都在被忽略的那一行。`91` 交付的探针同理——它测量的那一对（分类器的 5/6 × z 的符号）**恰好是两个不会影响屏幕的数的关系**，所以它无论输出什么都不能解释横屏。

## 2. 全部误会的来源：这条链上有**三个**不同的枚举

这是这一轮唯一一个"概念性"的发现，也是前面三篇文档出错的根：链上有三个枚举，名字几乎一样，编号各不同。

| 层 | 枚举 | 编号 |
|---|---|---|
| sensorfw（`PoseData::Orientation`） | LeftUp, RightUp, BottomUp, BottomDown, **FaceDown, FaceUp** | 1,2,3,4,**5,6** |
| QtSensors（`QOrientationReading::Orientation`） | TopUp, TopDown, LeftUp, RightUp, **FaceUp, FaceDown** | 1,2,3,4,**5,6** |
| Qt（`Qt::ScreenOrientation`） | Portrait, Landscape, InvertedPortrait, InvertedLandscape | 1, 2, 4, 8 |

两个要点：

* **面的两个值，两家的编号正好相反**：sensorfw 的 5 = FaceDown / 6 = FaceUp，Qt 的 5 = FaceUp / 6 = FaceDown。设备上报 6（`71` §6 的 `(<(uint64 …, uint32 6)>,)`），在 Qt 那边就是 `FaceUp`——**完全正确**。
* 连"sensorfw 的 4 个边位"的顺序也和 Qt 不一样：sensorfw 是 `LeftUp, RightUp, BottomUp, BottomDown`，Qt 是 `TopUp, TopDown, LeftUp, RightUp`。所以即使没有面那一对，编号也不能直接对着看。

源码（`evidence/orientation-mapping-2026-09-23.log` §2 有原文与 sha256）：

* sensorfw：`ubports/sensorfw` 分支 `xenial_-_android9`，`datatypes/posedata.h`；
* QtSensors：`qt/qtsensors` 分支 `5.15`，`src/sensors/qorientationsensor.h`；
* 两份都在**安装的二进制里**重新对过一遍编号，不靠"我记得 Qt 是这么排的"——见 §3/§4。

## 3. 中间那张表：六个字，逐名字对齐

sensorfw 的值进 QtSensors 时经过**唯一一次**换算，在 `libqtsensors_sensorfw.so`（`libqt5sensors5-sensorfw`，也就是这个端口上 `QOrientationSensor` 的后端）里，是一个**六项查表**，比 switch 更难误读：

```
SensorfwOrientationSensor::getOrientation(int x)     # 0x1a060
    w0 = x - 1
    if (w0 > 5) return 0            # 0..6 以外 -> Undefined
    return table[w0]                # 表在 .rodata 0x1f550
```

```sh
$ llvm-objdump-14 -s -j .rodata libqtsensors_sensorfw.so | grep '^ 1f55'
 1f550 03000000 04000000 02000000 01000000   ................
 1f560 06000000 05000000                      ........
```

六个字是 `{3, 4, 2, 1, 6, 5}`，也就是：

```
sensorfw 1 LeftUp     -> Qt 3 LeftUp        sensorfw 4 BottomDown -> Qt 1 TopUp
sensorfw 2 RightUp    -> Qt 4 RightUp       sensorfw 5 FaceDown   -> Qt 6 FaceDown
sensorfw 3 BottomUp   -> Qt 2 TopDown       sensorfw 6 FaceUp     -> Qt 5 FaceUp
```

**左列和右列的名字一一对应，一个都没错。** 这一层是 QtSensors 的 sensorfw 后端里写死的一行表，它不可能"反了"——它是**翻译**，不是修正。

（顺带：`slotDataAvailable(const Unsigned&)` 直接把 D-Bus 数据里的那个 `uint32` 交给 `getOrientation`，再 `QOrientationReading::setOrientation`。所以 `71` §6 用 `gdbus` 读到的那个 `uint32 6`，就是这张表的输入，没有第二处换算。）

## 4. 那个"6"是算出来的：`processFace()` 说 z > 0 就是它

sensorfw 的 `liborientationinterpreter-qt5.so` 里，六位置是这样定的（源码 `filters/orientationinterpreter/orientationinterpreter.cpp`，与安装的二进制逐条对上，日志 §4 有反汇编）：

```cpp
int OrientationInterpreter::orientationCheck(const AccelerationData &data, OrientationMode mode) const
{
    if (mode == OrientationInterpreter::Landscape)
        return round(atan((double)data.x_ / sqrt(data.y_ * data.y_ + data.z_ * data.z_)) * RADIANS_TO_DEGREES);
    else
        return round(atan((double)data.y_ / sqrt(data.x_ * data.x_ + data.z_ * data.z_)) * RADIANS_TO_DEGREES);
}

PoseData OrientationInterpreter::rotateToPortrait(int rotation)
{   newTopEdge.orientation_ = (rotation <= 0) ? PoseData::BottomUp : PoseData::BottomDown;  ... }

PoseData OrientationInterpreter::rotateToLandscape(int rotation)
{   newTopEdge.orientation_ = (rotation <= 0) ? PoseData::LeftUp : PoseData::RightUp;  ... }

void OrientationInterpreter::processFace()
{
    if (abs(data.z_) >= 300) {
        newFace.orientation_ = ((data.z_ <= 0) ? PoseData::FaceDown : PoseData::FaceUp);
        ...
    }
}
```

三件事一次说清：

* **竖着拿**（横屏/竖屏那一对）看的是 x 和 y 的**符号**：竖屏模式用 `atan(y/…)`，所以 `y > 0` → `BottomDown`（正竖）、`y < 0` → `BottomUp`（倒了）；横屏模式用 `atan(x/…)`，`x > 0` → `RightUp`、`x < 0` → `LeftUp`。**"上下"其实是 y 的符号，"左右"是 x 的符号。**
* **平放**（`|z| ≥ 300 mG` 且 x、y 都够小）落在 `processFace()` 里：**`z > 0` → 6**。这条路径与 `71` §6 的实测（平放朝上时 `z ≈ +1016 mG`，分类器报 6）**互相印证**——一个来自源码、一个来自设备。两个独立来源都指向"6 是朝上"，所以 `91` 那句"6 = 屏幕朝下，所以反了"是错的。
* 还有一条容易被忽略的：平放时 `processTopEdge()` 的两个角都低于阈值（20°/25°），于是它把 `topEdge` 置成 `Undefined`；`processOrientation()` 看到 `topEdge == Undefined` 就**改用 `face` 的值**。也就是说，平放时上报的那个 6 **就是** `FaceUp`，不是"边位"——分类器自己都不认为手机是竖着或横着的。

编号的旁证（不需要头文件）：`rotateToPortrait` 编出来是 `(rotation > 0) + 3`，即 3/4；`rotateToLandscape` 是 `(rotation > 0) + 1`，即 1/2；`processFace` 的 z>0 分支直接写 6、z≤0 分支写 `5 + (topEdge != Undefined)`。所以 `BottomUp=3, BottomDown=4, LeftUp=1, RightUp=2, FaceDown=5, FaceUp=6` 是从这台设备**自己的二进制**里读出来的，与 `posedata.h` 完全一致。

## 5. qtmir 只认四个值，`FaceUp`/`FaceDown` 是"unknown orientation."

`PlatformScreen::onOrientationReadingChanged` 把读数放进事件对象偏移 20，`PlatformScreen::customEvent` 在那个偏移上分发。分发结构（`llvm-objdump-14` 反汇编，日志 §5）：

```
cmp w0,#3 ; b.eq -> LeftUp 的 case      cmp w0,#1 ; b.eq -> TopUp 的 case
b.hi -> 再比 4                          cmp w0,#2 ; b.ne -> UNKNOWN（0 也在这里）
                                        （w0 > 3 且 != 4 的也进 UNKNOWN）
```

四个 case 的结果（`m_nativeOrientation` 是 `Portrait` 时取每条的"否则"一支）：

| 读数（Qt 编号） | 名字 | 写入 `m_currentOrientation` |
|---|---|---|
| 1 | TopUp | `PortraitOrientation`(1) |
| 2 | TopDown | `InvertedPortraitOrientation`(4) |
| 3 | LeftUp | `LandscapeOrientation`(2) |
| 4 | RightUp | `InvertedLandscapeOrientation`(8) |
| 5 / 6 | FaceUp / FaceDown | **不写**，只 `qWarning("Unknown orientation.")` 并 `accept()` |

`m_nativeOrientation` 不是传感器读的：构造函数里 `(几何.height() <= 几何.width()) ? 2 : 1`，这台设备是 `QRect(0,0 1080x1920)`，所以是 `Portrait`(1)；`m_currentOrientation` 初值也是 `Portrait`，之后只被上表改写。公开可见的同名实现（`ubports/qtmir` 的 `src/platforms/mirserver/screen.cpp`，类名在那边叫 `Screen`、在这个构建里叫 `PlatformScreen`）**逐 case 与此一致**——八个（值 × native）组合全对上，日志 §5 有原文。

**这就把设备日志解释干净了**（`70` §2 引的那几行）：

```
[ 385.663429] qtmir.sensor: PlatformScreen[...]::customEvent() - new orientation=Qt::InvertedLandscapeOrientation
[ 404.197702] qtmir.sensor: ...::customEvent() - unknown orientation.
（之后每一次都是 unknown）
```

* `unknown orientation.` 稳定刷，正是平放时的 6 走 `default:`；**"6 被采纳成横屏"这件事在代码里不存在**（`70` §5 / `71` §5 的那句机制描述因此是错的）。
* 整个 boot 里唯一一次被采纳的 `InvertedLandscape`(8)，按 §1 的表只可能来自 sensorfw 的 **RightUp(2)**＝"右边朝上"（1 或 2 之外没有别的组合能给出 8）。那一刻手机是怎么放的**没有记录**，但可以确定的是：之后的每一次读数都没有再改写它。

还有一条 `71` §5 的日志，按新表读出来的信息比当时多。那一段是连按电源键时抓的，两次电源事件各自采纳了一次 `InvertedLandscape`：

```
[ 6674.025965] ... customEvent() - unknown orientation.                                  <- 这一秒里有一个 6
[ 6674.535612] ... customEvent() - new orientation=Qt::InvertedLandscapeOrientation      <- 这一秒里有一个边位值
[ 6675.880017] ... customEvent() - new orientation=Qt::InvertedLandscapeOrientation
```

两件事因此是**日志本身证明**的，不靠推断：

* **那两次采纳的读数不是 6**（6 只会打 `unknown orientation.`）。同一秒里出现 `unknown orientation.`，说明这一秒里分类器在 6 与某个边位值之间动过——**按电源键意味着手正在手机上**，手机在动，这完全可以解释。
* 所以**"电源键把 6 采纳成横屏"这个说法在日志里也不成立**；成立的是"手碰手机 → 出现一次边位读数 → 屏幕跟过去"，而手机放回平放后那些 6 不再改写它——**要回到竖屏，需要的是重新出现一次"竖握"的边位读数**（`BottomDown`），这正是 §6 那一支要量的事。

## 6. 所以"横屏"剩下什么

把不可能的划掉之后，只剩两条，而且**一次测量就能分开**：

* **(a) x/y 轴序不对。** 如果加速度计的 x 和 y 在进分类器之前被交换了，那么"正竖着拿"的手机对 `atan(y/…)` 来说看起来像"躺在侧面"——报 1 或 2，屏幕就是横的，而且**只要竖着拿就一直横**，与用户报的现象最贴。判据：竖握时读数是 4 还是 1/2。（若整对取负，读数会是 3，表现为**倒竖**而不是横屏——用户没报过倒竖。）
* **(b) 轴没问题，是"卡住"。** 如果竖握读数是 4，那么轴这条线整族排除，剩下的就是"最后一个被采纳的边位值一直留着"：平放按设计不改屏幕（§5），于是 385 秒那次 `InvertedLandscape` 就一直留到下次有人把手机竖起来为止。这一支还要再分两种：**b1** 竖起来时 sensorfw 确实报了 4、只是没人再看屏幕（那只是"平放不改"的设计后果）；**b2** 手机动了、值也变了，但没送到 qtmir（`71` §7.5 那个"30 秒 `orientationChanged` 一次都没发"**不能**当证据——那 30 秒手机平放着没动，本来就不该有变化）。

没有任何一条现成的文档量过竖握的那一个样本。**这就是这一轮要补的测量**，判据只有一个数。

## 7. 探针按新判据重写了

`scripts/device/zl1-orientation-axes.sh` 保留名字（"axes"仍然贴切：问的就是轴），判据换了：

```sh
# 设备回来之后，手机**竖握、屏幕朝自己**，那只手就是全部前提
scp scripts/device/zl1-orientation-axes.sh root@10.15.19.82:/tmp/
ssh root@10.15.19.82 'sh /tmp/zl1-orientation-axes.sh --seconds 30 --portrait-up'
```

| 结论 | 条件 | 退出码 | 意思 |
|---|---|---|---|
| `AXES-OK` | 竖握时主要是 4 | 0 | 轴序没问题；横屏属于 §6(b)，整族"改矩阵"的解释可以划掉 |
| `AXES-SWAPPED` | 竖握时主要是 1 或 2 | 3 | x/y 交换了（§6(a)）——唯一还值得动矩阵的一支 |
| `AXES-INVERTED` | 竖握时主要是 3 | 4 | 同一根轴 180° 反（表现为倒竖，不是横屏） |
| `Not upright` | 全是 5/6 | 5 | 手机其实是平放的，重来 |
| `No accelerometer sample` | 加速度列一个都解析不出来 | 1 | 栈的毛病（`78`），不是这一条 |
| `Mixed or empty` | 没有单一主导值 | 2 | 保留输出 |

变化的地方，逐条都有理由：

* **`--flat-up` 还在，但结论改成"这个测量说明不了任何事"。** 平放读数应该是 5/6；脚本会明说这两个值 qtmir 按设计不采纳，别拿它当判据——把 `91` 走错的那一步在脚本里堵住。
* **`--portrait-up` 是新的那一支**，也是唯一有结论的支。
* 每个样本多加一列：**哪个轴在扛那 1 g（符号也在）**。这样表可以对着手里的手机读，不必信任脚本。
* `--explain` 里的表和外加步骤按 §1 重写；`transformation_matrix` 的具体值只在 `AXES-SWAPPED`/`AXES-INVERTED` 时才提，而且照旧**不改**。

## 8. 顺手修掉的两个测量错误

1. **`91` 那个版本的 xyz 解析是坏的，而打桩测试没抓到。** 它取"最后三个整数"，但 `xyz` 的三个分量是**浮点**（`-1.56, 21.50, 1016.0`）：`1016.0` 会被切成 `1016` 和 `0` 两个 token，于是"最后三个整数"变成了 `(1016, 0, 50)` 这种垃圾。打桩用的假数据全是整数，所以 7 个场景全过了。现在改成：**砍掉第一个逗号之前的部分（时间戳），再按逗号切三段，每段取整数部分**；`(uint64 11, 5, -3, 1015)`（整数）和 `((uint64 11, -1.56, 1016.0, 21.5),)`（浮点）两种形状都测过。
2. **"读到了值但没有加速度"这种情况原本会给出一个像样的结论。** 现在加速度列一个都解析不出来时，先判"没有可对照的姿态"，退出 1，不给任何 verdict——`91` 那版会拿一个只有单向输入的样本下结论。

打桩测试这一轮跑了 10 个场景（`gdbus` 打桩 + 设备树检查打桩）：4→`AXES-OK`/0、2→`AXES-SWAPPED`/3、3→`AXES-INVERTED`/4、6+`--portrait-up`→`Not upright`/5、6+`--flat-up`→"说明不了任何事"/0、4+`--flat-up`→"不是面值"/2、不给 flag→只测量/0、4 与 2 交替→`Mixed`/2、加速度不可解析→1、全空→1；另外整数与浮点两种 xyz 形状、以及 `(uint32 4)` 这种裸回复各跑了一遍。

## 9. 复现

```sh
# 主机上（不需要设备）
sh -n scripts/device/zl1-orientation-axes.sh
sh scripts/device/zl1-orientation-axes.sh --explain

# 那张翻译表：六个字，从 .rodata 读
sudo mount -o loop,ro,noload /mnt/data/ubports-rootfs/24.04-2.x/rootfs-24.04-2.x-arm64-android9plus-zl1-host-4g.img /mnt/zl1-rootfs
llvm-objdump-14 -d --start-address=0x1a060 --stop-address=0x1a0a0 \
  /mnt/zl1-rootfs/usr/lib/aarch64-linux-gnu/qt5/plugins/sensors/libqtsensors_sensorfw.so
llvm-objdump-14 -d --start-address=0x5b960 --stop-address=0x5b9d0 \
  /mnt/zl1-rootfs/usr/lib/aarch64-linux-gnu/libqt5mir1server.so.1
```

| 文件 | 作用 |
|---|---|
| `scripts/device/zl1-orientation-axes.sh` | 重写。判据从"z 的符号 vs 5/6"换成"竖握时的边位值 vs 4"；`--portrait-up` 是唯一有结论的一支；`--flat-up` 保留但明说它判定不了任何事。仍只读 |
| `docs/ubuntu-touch/evidence/orientation-mapping-2026-09-23.log` | 本轮全部离线证据：三个二进制的 sha256 与包版本、三个枚举的原文、翻译表的 `.rodata` 六字、`processFace`/`rotateTo*` 的源码与反汇编、qtmir 分发结构与公开源码、设备日志的交叉对照 |
| `docs/ubuntu-touch/92-*.md` | 本篇 |

## 10. 这一轮**不**证明什么

* **不证明轴是好的。** 本篇证明的是"链的中间没有反"，以及"平放那个值判定不了任何事"。x/y 轴序（§6(a)）是**剩下唯一**还没排除的候选，判据是竖握那一次读数——设备在 EDL，没量。
* **不解释 385 秒那次 `InvertedLandscape` 是怎么来的。** 那一刻手机的姿态没有记录；能确定的只有"之后没有任何读数改写它"。
* **不证明 sensorfw 的投递是好的。** `71` §7.5 的观察在本篇之后既不支持也不反对（那 30 秒手机没动，本就不该有变化），所以 §6(b2) 仍然是开的。
* **不改任何东西**：设备在 EDL，本轮对它的操作是零；`transformation_matrix` **没有**改，连"该改成什么"都要等竖握那一次测量。
* **不改动映射那一半**：qtmir 对 5/6 不做任何事是上游行为（公开源码逐 case 一致），不是缺陷，所以没有"改 qtmir"的动议。
