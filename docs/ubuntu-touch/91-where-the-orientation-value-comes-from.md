# 91 — 方向值是从哪来的：一条链、一行配置、一个 6

**日期**: 2026-09-23
**状态**: 纯离线的一轮（设备在 EDL，与 `86`–`90` 同）。这一轮把 `70` §5 / `71` §5 留下的那句"这条链里'哪一处把上下反了'还没有量到"**缩到一个具体的位置**，而且缩法是可离线判定的（不需要设备），结论是一行配置 + 一个可被否证的预测 + 一个只读探针。

**接续**: [`70`](70-the-landscape-was-the-shell-laying-itself-out.md) §5（`6` → qtmir 采纳 `InvertedLandscape`）、[`71`](71-the-sensors-stream-the-restart-kills-the-hal.md) §5/§7（电源键重放、坐标矩阵那条实验）、[`78`](78-the-sensors-came-back-without-a-reboot.md)（传感器全灭的修法与顺序，也是这一轮的 undo）、[`64`](64-the-last-unit-was-not-failing-it-was-obeying.md) §5（`30-hidl.conf` 是基线配置）

> **【更正，见 [`92`](92-the-orientation-chain-is-correct-and-the-flat-value-is-ignored.md)（同一天，紧随本篇）。】本篇的 §2/§3/§4/§5（链的结构、`=Feature_*` 那条死路、UT 侧不缺库、三个没绑定的 adaptor）仍然成立，§1 的**结论**和 §6/§7 的**修法**不成立：**
>
> * 本篇 §1 假设"5 = 朝上、6 = 朝下"，于是推出"平放报 6 → 那条链里有一处把 z 反了 → 候选修法是 `transformation_matrix` 取负 z"。**这个前提是错的**：sensorfw 自己的枚举（`PoseData::Orientation`）里 `FaceUp` = **6**、`FaceDown` = 5，`processFace()` 就是"z > 0 → 6"。设备上报 6 是**正确的**，和 `71` §6 的 `z ≈ +1015 mG` 是同一件事的两次确认。`92` §2 把这条链上三个枚举（sensorfw / QtSensors / Qt）的编号并排列了出来——它们名字几乎一样、编号各不同，这才是误会的来源。
> * 而且**平放这个位置 qtmir 根本不采纳**：它只为四个"边位"值（LeftUp/RightUp/BottomUp/BottomDown）改写屏幕，`FaceUp`/`FaceDown` 走 `default:` 分支、只打一行 `unknown orientation.`（`92` §5 有反汇编，逐 case 与公开源码一致）。所以把 6 改成 5 什么都看不见，`92` §1 端到端那张表才是判据。
> * 因此**那个探针的判据（分类器的 5/6 × z 的符号）判定不了任何事**，已按"竖握时是 4 还是 1/2"重写（`92` §7）。顺带：本篇脚本里的 xyz 解析对**浮点**分量是坏的（打桩用整数所以没抓到），`92` §8 有说明。
> * 本篇 §5 里"`6` 是 qtmir 唯一采纳过的值"（引自 `70` §5）也要按 `92` §1 重读：`6` 不可能被采纳，被采纳的 `InvertedLandscape` 来自"右边朝上"那类边位读数。

---

## 1. 一句话结论

> **【§1 的两条结论都要按 [`92`](92-the-orientation-chain-is-correct-and-the-flat-value-is-ignored.md) 重读，本节保留原文。】**链的结构（这一节上半段）是对的；"于是这对矛盾落在那唯一的换算上、候选修法是取负 z"这一段不成立——`6` 本来就是朝上，而且平放值 qtmir 不采纳。

**`local.OrientationSensor` 那个 1–6 的值不是从 Android 的方向传感器拿来的，是 sensorfw 自己用加速度计算出来的。**

链是这样（全部来自二进制里的字符串与符号，见 §2）：

```
加速度计 adaptor → accelerometerchain → [加速度计坐标矩阵] → orientationinterpreter(六位置分类器)
                                                                        ↓
                                                              local.OrientationSensor (1..6)
```

于是"手机平放、屏幕朝上、加速度计 `z ≈ +1015 mG`，分类器却说 `6`（屏幕朝下）"这对矛盾，落在**这段链唯一的换算**上：

```
[accelerometer]
transformation_matrix = "1,0,0,0,1,0,0,0,1"     <- 单位阵，等于什么都没修正
```

同一个文件里磁力计那一节**不是**单位阵（它把 x 取了负），也就是同一类、同一原因的修正，只是加速度计这一行没人写过。候选修法因此是一行：

```
transformation_matrix = "1,0,0,0,1,0,0,0,-1"   <- 取负 z
```

**并且这个预测是可被否证的**：同一个平放朝上的样本应该从 `6` 变成 `5`。这一轮交付的 `scripts/device/zl1-orientation-axes.sh` 就是**只读地**测这件事——它不改任何东西，只把"加速度计的 z 符号"和"分类器的值"并列打出来，然后按分支给结论。

> **不是"猜坐标矩阵"，是把猜测变成一次测量。** `71` §7.2(a) 当时写的是"换加速度计的坐标矩阵，看 `6` 变不变"——那是在三个轴、两个符号的六种可能里试。现在只剩下 z 的符号这一种，理由是链的结构（§2），而且探针能在改动之前先判。

## 2. 数据通路：证据，不是推断

| 命题 | 证据（`evidence/orientation-path-2026-09-23.log` 有全部原始输出） |
|---|---|
| 那个对象是 sensorfw 自己的 | `liborientationsensor-qt5.so` 里有 `local.OrientationSensor`、`OrientationPlugin`、`OrientationSensorChannelAdaptor`，以及链名 `orientationchain` |
| 这条链吃的是**加速度计** | `liborientationchain-qt5.so` 里有 `accelerometer`、`accelerometerchain`、`PoseData`，以及错误串 `accelerometer/orientationinterpreter join failed` |
| 那个分类器就是六位置分类 | `liborientationinterpreter-qt5.so` 里有 `OrientationInterpreter::processFace()`、`rotateToPortrait()`、`rotateToLandscape()`、`THRESHOLD_PORTRAIT`/`THRESHOLD_LANDSCAPE`，配置键 `orientation/threshold_portrait`、`orientation/threshold_landscape` |
| 唯一换算就是那一行 | `libaccelerometerchain-qt5.so` 里有 `accelerometer/transformation_matrix`（还有 `accelerometer/acccoordinatealigner join failed`），而它的值是单位阵 |
| **名字里带 orientation 的那三个 adaptor 不可能是这个值的来源** | `libhidl{orientation,rotation,georotation}adaptor-qt5.so` 三个都产出 `CompassData`——**角度**（0–359），不是 1–6 的位置。所以 `30-hidl.conf` 里 `orientationadaptor = hidlorientationadaptor` 与这个值无关（这也顺手说明它不是"Android 的 DEVICE_ORIENTATION 传感器直通"） |

**顺手更正一处**：`scripts/device/zl1-orientation-watch.sh` 的头部注释写着这个值是"Android 的 DEVICE ORIENTATION 传感器（HIDL SENSOR_TYPE_DEVICE_ORIENTATION = 25）"。按上面第 5 行，**这个说法在二进制里没有依据**（那三个 adaptor 出的是角度），已经改成"由 sensorfw 自己的 interpreter 从加速度计算出"，并指向本篇。那个脚本的**结论**（"5 是朝上、6 是朝下，如果它和加速度计对不上，就是两个坐标系有一个错了"）是对的，改的只是来源那一句。

## 3. `=Feature_*` 那套**不是**原因——而配置文件在**邀请**这个错误结论

`20-sensors-default.conf` 里一半的传感器写成 `accelerometersensor=Feature_AccelerationSensor` 这种形式。很容易由此得出"这台设备没有 `Feature_AccelerationSensor`，所以加速度计不注册"。**这条路是死的**，而且离线就能证明：

* `sensorfwd` 从 `libdeviceinfo.so.0` 取 `DeviceInfo::get` 和 `DeviceInfo::contains`（`readelf -d` 里有这个依赖，动态符号里有这两个函数）；
* `libsensorfw-qt5.so.0.9.0` 里有字面量 `Feature_` 和 `bool evaluateAvailabilityValue(const QString&, const QString&)`——这套语法就是通过 deviceinfo 解析的；
* 而这台设备的 `/etc/deviceinfo` 里**没有一个** `Feature_*` 键（`grep -rl Feature_ /etc/deviceinfo` 无输出）；
* **可是 ALS 和 proximity 的配置行也是 `=Feature_*` 形式，而它们是工作的**（`78`；ALS 的 lux 值会动）。

四个事实放在一起：缺 feature 键这条路上，两个方向都对不上。所以"某个传感器没注册"不能靠改 `[available]` 来解释或解决——这一节写下来就是为了以后不再走这条死路。

同时记下**真正该看的那一行日志**：`libsensorfw` 里有字符串 `Plugin not available: `。哪天真有插件被拒（`70` §6(1)/`78` §1 都遇到过），一条命令就能点名：

```sh
journalctl -u sensorfwd --no-pager | grep -n "Plugin not available\|not registered"
```

（读日志的坑照旧：这台设备时钟不对、`journalctl -n` 的顺序会骗人，按 unit 读，见 `69`。）

## 4. UT 侧的插件**不是**少库——与 `90` 恰好相反

`90` 在 Android 侧证明了 `vsimd` 起不来是"少一个同 class 的库"。为了避免这个形状被串味到 UT 侧，这一轮把同一套判据用在了 rootfs 上：`sensord-qt5/` 下**所有**插件，每一个 `DT_NEEDED` 都在镜像自己的 6233 个 soname 里能找到（未解析：0 个）。所以这个端口上"某个 sensorfw 插件起不来"不会是缺库，只能是运行期的事（或者 HAL 那一侧）。

## 5. 装了三份、没绑定的 adaptor（这一条**不**解释 `6`）

`libsensorfw-qt5-hidl` 装了 11 个 adaptor，`30-hidl.conf` 绑了 8 个。没绑的是 `georotationadaptor`、`rotationadaptor`、`wakeupadaptor`。

* `wakeupadaptor` 是**故意**的：`20-sensors-default.conf` 里 `wakeupsensor=False`，注释写了原因；
* `georotationadaptor` / `rotationadaptor` 没有配置行——但这**不是** `rotationsensor` 的问题：`librotationsensor-qt5.so` 的链是 `accelerometerchain:rotationfilter:compasschain`，它自己从加速度计+磁力计算，不需要 `rotationadaptor`。写下来是为了别把"装了就一定要绑"当规律。

## 6. 为什么不自己改那一行

> **【更正，见 [`92`](92-the-orientation-chain-is-correct-and-the-flat-value-is-ignored.md)：第 1 条的前提（"6 是 qtmir 唯一采纳过的值"）是错的——6 恰恰是它**不**采纳的两个值之一；第 2、3 条仍然成立，而且换了判据之后更需要它们（`92` §7 的 `--portrait-up` 也要一只手）。】**

三件事让我把它留成"等你一句话"，而不是顺手改掉：

1. **它会改屏幕行为**。~~`6` 是 qtmir 唯一采纳过的值（`70` §5、`71` §5）~~，改分类器的输入就是改 shell 的方向行为——这是可见的行为变化，不是纯粹的内部测量。
2. **重启 `sensorfwd` 本身有代价。** `71` §3 记着单独重启能让容器的传感器 HAL 死掉（8.2 小时不出一个样本）；`78` 找到了固定的顺序把它变成确定的事，那个顺序就是 `scripts/device/zl1-sensors-recover.sh`，同时也是这次的 undo。所以 A/B 必须走那条顺序，不能 `systemctl restart` 了事。
3. **而且现在还量不了。** 设备在 EDL，"手机平放朝上"这个前提需要一只手（需要你）。

所以这一轮的交付是：**一个只读探针 + 一条打印出来的可逆步骤**（`--explain`），改动本身不做。

## 7. 验证到什么程度

> **【更正，见 [`92`](92-the-orientation-chain-is-correct-and-the-flat-value-is-ignored.md) §8：这一节记录的是**旧判据**（`INVERTED`/`AGREES`/`AMBIGUOUS`）下的打桩测试，判据本身已被换掉，所以这些场景连同结论一起作废。两点要留下来：打桩用**整数**假数据，所以浮点解析的 bug 没被抓到（`92` §8 第 1 条）；"读到值但加速度不可解析"这种情况旧脚本仍会下结论（`92` §8 第 2 条）。新脚本 10 个场景见 `92` §8。】

* `scripts/device/zl1-orientation-axes.sh` 用打桩的 `gdbus`（按调用返回固定的、可控的 orientation/xyz）跑了 **7 个场景**：平放朝上+分类器 6（判 `INVERTED`，退出 3）、平放朝上+分类器 5（判 `AGREES`，退出 0）、`z` 为负（判 `AMBIGUOUS`，退出 2，并且**明说不要凭这个输出就改矩阵**）、不够平（判"没有平放样本"，退出 1）、有平放样本但没给 `--flat-up`（退出 0，要求再跑一次）、`z` 符号在跑动中变过而分类器不变（判"两者不是简单相反"，退出 2）、xyz 回复解析不出来（判"没有平放样本"，退出 1）。
* 解析用的不是固定形状：`gdbus` 对 struct-in-variant 的标点随版本变（`(uint64 1, 5, -3, 1015)`、`(<...>,)`、`((...),)`、`(<(...)>,)`），所以脚本取"最后三个整数"，四种形状都测过。
* 打桩测试**抓到一个真 bug**：第一版的 `INVERTED` 分支只要求"见过 `6` 且 `z>0`"，没要求"从没见过 `6` 且 `z<0`"，于是**符号来回变的那个场景也被报成干净的 INVERTED**——正是最该说"两者不是简单相反"的情形。已修成每个计数器只在它自己的组合上触发。
* 配置读取那一节对着**真实镜像里的 `30-hidl.conf`** 跑过，打出来的就是上面那两行（`hidlaccelerometeradaptor` + 单位阵）。
* **没在设备上跑过任何东西**（设备在 EDL）。未验证的是设备侧的事实：`--flat-up` 时加速度计到底是不是 `+z`、`|z|` 到不到 800 mG、以及**`6` 到底是不是 `z` 取负就能变成 `5`**。

## 8. 复现

```sh
# 主机上（不需要设备）
sh -n scripts/device/zl1-orientation-axes.sh
sh scripts/device/zl1-orientation-axes.sh --explain

# 设备回来之后，只读的那一次测量：**手机竖握、屏幕朝自己**（旧版这里是 `--flat-up`）
scp scripts/device/zl1-orientation-axes.sh root@10.15.19.82:/tmp/
ssh root@10.15.19.82 'sh /tmp/zl1-orientation-axes.sh --seconds 30 --portrait-up'

# 如果样本是陈旧的（age 一直在涨 / 0），先修栈再量 —— 顺序在 78
scp scripts/device/zl1-sensors-recover.sh root@10.15.19.82:/tmp/ && ssh root@10.15.19.82 'sh /tmp/zl1-sensors-recover.sh'
```

| 文件 | 作用 |
|---|---|
| `scripts/device/zl1-orientation-axes.sh` | 新增（**判据当天就被 [`92`](92-the-orientation-chain-is-correct-and-the-flat-value-is-ignored.md) §7 换掉**：现在量的是"竖握时读数是不是 4"，`--portrait-up` 才有结论，`--flat-up` 保留但明说判定不了任何事）。设备侧、**只读**；`--explain` 打印那一行改动的**可逆**步骤。不改任何配置、不重启任何服务 |
| `scripts/device/zl1-orientation-watch.sh` | 头部关于这个值来源的说法已更正（§2 末），并指向本篇 |
| `docs/ubuntu-touch/evidence/orientation-path-2026-09-23.log` | 本轮全部离线证据：配置、插件清单、链里的字符串与符号、deviceinfo 的四个事实、插件依赖全解析 |
| `docs/ubuntu-touch/91-*.md` | 本篇 |

## 9. 这一轮**不**证明什么

* **不证明** ~~`-z` 是对的。它证明的是"候选只有一个"，以及"那个候选可以被一次测量否证"。真正的证明是探针判 `INVERTED` **并且**改完之后同一个样本变成 `5`。~~ **【更正，见 [`92`](92-the-orientation-chain-is-correct-and-the-flat-value-is-ignored.md)：`-z` 已被判否证——6 和 5 两个值都在 qtmir 被忽略的那一行，改了看不见。真正的判据换成了竖握时读数是 4 还是 1/2。】**
* **不证明** `6` 就是横屏的唯一原因。`70` §5 记着 qtmir 只是"重读那个缓存值"，`71` §5 记着触发是显示电源变化——~~**mapping 那一侧（`6` → `InvertedLandscape`）没有被这一轮碰过**，它可能也要动。顺序上应该先让分类器给出正确的值，再看 qtmir 拿 `5` 做什么。~~ **【更正，见 [`92`](92-the-orientation-chain-is-correct-and-the-flat-value-is-ignored.md) §5：mapping 那一侧已经查清了——`6` 不会变成 `InvertedLandscape`（那是 `FaceUp`，被 `default:` 忽略）；能给出 `InvertedLandscape` 的只有四个边位值里的一个。所以不是"先改分类器再看映射"，而是"量竖握那一次读数"。】**
* **不解释** `alssensor` 时间戳恒为 0（`71` §7.5）、`ISensorManager` 永远在等（`70` §6(3)）——两条独立的小线。
* **不改动设备**：设备在 EDL，本轮对它的操作是零；§1 那一行配置**没有**改，§6 写了为什么它需要你点头。
