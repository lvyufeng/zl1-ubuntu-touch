# 102 — GPS 的日志按"谁写的"分开：两个模式数在错的日志里，外加两个"永远不可能打印出来"的分支

**日期**: 2026-09-23
**状态**: 纯离线的一轮（设备在 EDL，`05c6:9008` / port 3-3，与 `86`–`101` 同）。这一轮把 `zl1-gps-probe.sh` 的第 3 节按**每个字符串的主人是哪个进程**重写，按这个规则**删掉两个模式**、补上五个从来没被数过的 journal 侧模式；顺手在同一个脚本里抓到两个各自独立的小缺陷。新的 host harness 从 0 长到 **69 项**。设备整轮没有测量。

**接续**: [`82`](82-the-gps-line-read-the-source-and-the-rootfs.md)（那行 QMI 错误不是拦路者，"没人要过位置"才是；读源码和 rootfs 而不是读日志）、[`93`](93-gps-the-door-is-a-client-request-and-the-two-levers-are-dead.md)（那道门是一次客户端请求，而 `82` 的两把试验钥匙在这台设备上都插不进去），[`101`](101-which-directory-the-fingerprint-hal-is-handed.md)（上一轮：仪器问错进程的属性）、[`99`](99-the-remaining-heat-fix-was-broken-offline.md)/[`100`](100-the-other-half-of-the-heat-fix-and-the-only-misc-backup.md)（"仪器必须能说出'没生效'"）、[`69`](69-repowerd-died-on-a-startup-race-with-sensorfwd.md)（这台设备没有可用的 RTC，按时间读 journal 是骗人的）。每个模式的归属证据在 `docs/ubuntu-touch/evidence/gps-log-owners-2026-09-23.log`。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 这一轮修的是什么？ | `zl1-gps-probe.sh` 第 3 节：八个模式里**两个不可能出现在 logcat 里**（它们在 UT 侧），另有**两个在任何镜像里都不存在**——四个都被数在 logcat 里，另外五个从不出现的 journal 侧模式补上了 |
| 规则是什么？ | **一个字符串只可能出现在"地址空间里含有它"的那个进程的日志里。** 容器里进程加载的 vendor 库 → logcat；UT 侧的可执行文件或它 dlopen 的库 → stderr → 该 unit 的 journal；**任何二进制里都没有的字符串 → 它的 0 从来不是证据** |
| 数错的那两个是？ | `Issue instantiating provider` 与 `Instantiating and configuring`，两个都在 `/usr/bin/lomiri-location-serviced` 里，往 stderr 写，所以进 journal 不进 logcat |
| 新补的五个是？ | `Remote service failed to start`、`Failed to inject reference time`、源码路径 `android_hardware_abstraction_layer.cpp`（都在 `liblomiri-location-service.so.3.0.0` 里，第三个是 `__FILE__` 打进去的），加上 `libtrust-store.so.2` 的两条 gate 消息——它们**在旧版里没有被数过**，即这条链 UT 侧的那一半从来没有出现在表里 |
| 为什么会指错层？ | 它们的计数**结构性为 0**，而"0"在这份探针里读作**"provider 从来没被实例化"**——于是整条诊断被指向容器里的 HAL，而真正没发生的事在 UT 侧的 daemon 里 |
| 哪两个被删了？ | `set_gps_service_callbacks`（三个镜像里**一个字节都没有**，连符号表里都没有）；`Unable to get GPS service`（在 `libandroid_servers.so` 里，即框架自己的 `GnssLocationProvider`，**这条链不走它**——UT 的 daemon 直接走 HIDL `IGnss::getService()`） |
| 抓到什么别的缺陷？ | ①`does_report_wifi_and_cell_ids` 那一行**从来没有打印过值**：`sed 's/^/   wifi/cell: /'` 里替换串中的 `/` 结束了 `s` 命令，sed 报 `unknown option to 's'`，于是这一节唯一一个从不显示的数字就是它。②"gate 1 短路了吗"的兜底分支**不可达**：`tr \| grep \| sed \|\| echo "(absent)"` 报的是 **sed** 的状态，而 sed 永远成功 |
| harness 怎么保证不数错？ | **两本日志的 fixture 故意不重叠**：同一个字符串在两本里给不同的计数，所以从错的那本读出来的**数字不可能对上**——是一条红的检查，而不是一个看起来很像的 0 |
| harness 有多少牙？ | 对 `HEAD`（`e4cecba`）的探针：**69 项里 25 条红**，全部落在上面那几个缺陷的侧面上 |
| 动设备了吗？ | 没有。全部在宿主机上跑一个假设备（`/proc`、`logcat`、`journalctl`、`nsenter`、`lshal`、`lomiri-location-serviced-cli` 都是桩），没有写任何设备，没有 QDL/firehose，没有重启 |

---

## 2. 缺陷的形状：把 UT 侧的字符串数在容器的日志里

老代码（`HEAD`）第 3 节只有一个 logcat 块，八个模式都在里面：

```sh
dump=$(nsenter -t "$A" -p -m -- /system/bin/logcat -d -v brief 2>/dev/null)
for pat in 'locClientOpen failed' ... 'gnssSetCapabilitesCb' \
           'Instantiating and configuring' 'Issue instantiating provider'; do
  printf '   %-48s %s\n' "$pat" "$(printf '%s\n' "$dump" | grep -ac "$pat")"
done
```

`Instantiating and configuring` 与 `Issue instantiating provider` 是 `lomiri-location-serviced` 自己往 stderr 写的，而 stderr 进 **journal**，不进容器的 logcat。所以那两行**永远是 0**，而"0"在这份探针的语境里是**"provider 从来没被实例化"**——一个只可能指向容器的结论，而它其实是"我数错了地方"。

这一轮的修法：第 3 节拆成三块，每块只数它主人写的那本日志。

```
   --- logcat (容器里的 vendor GPS HAL) ---
     libloc_api_v02.so                       locClientOpen failed
                                             Failed to checking QMI_LOC message supported
                                             Failed to get features supported
     android.hardware.gnss@1.0-impl-qti.so   gnssSetCapabilitesCb
   --- journal of lomiri-location-service.service (daemon 自己 + 它加载的库) ---
     /usr/bin/lomiri-location-serviced       Issue instantiating provider
                                             Instantiating and configuring
     liblomiri-location-service.so.3.0.0     Remote service failed to start
                                             Failed to inject reference time
                                             .../android_hardware_abstraction_layer.cpp
```

两处细节值得单独记：

* **journal 的查询是 `-b`（按这次启动）而不是按时间**，并且关掉分页。原因和 `69` 一样：**这台设备没有可用的 RTC**（时间戳会落在 1970 年、并在同一次启动里跳），`journalctl --since` 会给出没有意义的窗口，而按启动范围取的对数计数**与顺序无关**。
* `gnssSetCapabilitesCb` 同时存在于 `libandroid_servers.so`，但**这条链上的写者是容器里的 `android.hardware.gnss@1.0-impl-qti.so`**，所以它仍然归 logcat——这条在证据文件里写清楚了，免得下一个人以为它该被删。

### 2.1 被删掉的两个模式，以及"0 从来不是证据"

| 模式 | 三个镜像里的命中 | 为什么删 |
|---|---|---|
| `set_gps_service_callbacks` | UT 0 / Android system 0 / vendor 0 | 它**不是一条日志**。`grep -rlaF` 读的是整个文件，所以一个只作为导出符号活下来的名字也会被命中——三个镜像里都没有，说明它连符号表都不在里面。它的 0 从来没测过任何东西 |
| `Unable to get GPS service` | UT 0 / Android system 2 / vendor 0 | 它**存在**，但在 `libandroid_servers.so`（外加 `services.vdex`）里：那是框架的 `GnssLocationProvider`。UT 的 daemon **不走它**——`providers/gps/android_hardware_abstraction_layer.cpp` 自己调 HIDL `IGnss::getService()`。UT 那侧命中 0 次，所以它的 0 说的是"我数的不是我这条路" |

也就是说，老代码八个模式里有四个是**没有信息量的 0**（两个数错日志、两个根本不在任何日志里），而它们和真正有信息量的那四个混在同一张表里、格式完全一样；这条链**UT 侧的那一半**（daemon 与它加载的库自己写的话）则完全不在表里。这就是这一节存在的理由：**计数这件事本身不区分"没发生"和"数错了地方"**。

---

## 3. 顺手的两个缺陷：两个"永远不可能打印出来"的分支

两个都在同一个脚本里，都是**输出分支实际不可达**，都和 harness 是同一件事的两面。

### 3.1 `wifi/cell` 那个数字从来没有显示过

```sh
/usr/bin/lomiri-location-serviced-cli does_report_wifi_and_cell_ids get 2>&1 | sed 's/^/   wifi/cell: /'
```

替换串里有一个 `/`，它**结束了 `s` 命令**，sed 于是报 `sed: -e expression #1, char 5: unknown option to 's'` 并返回 1；管道把 sed 的错误输出当成了"值"，于是这一节唯一一个从不显示自己读数的开关就是 `does_report_wifi_and_cell_ids`。修法是换分隔符：

```sh
... | sed 's|^|   wifi/cell: |'
```

这条是 harness 抓到的：断言 `does_report_wifi_and_cell_ids` 的值出现在输出里——而老脚本打印的是 sed 的报错，所以那条断言在 `HEAD` 上是红的（22 条红里的一条）。**同一个形状**在这一轮之前的别处也出现过：一个只可能 PASS 的守卫、一个被 `head -1` 吃掉的失败、一个把多行输出当文件名的 `grep -q`。

### 3.2 gate 1 的兜底分支不可达

```sh
tr '\0' '\n' < "/proc/$dpid/environ" | grep -a 'TRUST_STORE_...' | sed 's/^/     /' \
  || echo "     (absent: gate 1 is NOT short-circuited)"
```

`||` 报的是**管道最后一个命令**（sed）的状态，而 sed 在读不到行时也返回 0——所以环境变量**不在**的时候，这个分支照样不会打印 "(absent)"，而是打出一行空白。也就是：**"短路了"和"没短路"看起来一样**，正好是这个探针存在的那个问题的形状（`99`–`101` 同一族）。修法是把值先取出来再判断：

```sh
tsv=$(tr '\0' '\n' < "/proc/$dpid/environ" 2>/dev/null \
      | grep -a 'TRUST_STORE_PERMISSION_MANAGER_IS_RUNNING_UNDER_TESTING')
if [ -n "$tsv" ]; then
  printf '     %s\n' "$tsv"
  echo "     -> gate 1 IS short-circuited: ..."
else
  echo "     (absent: gate 1 is NOT short-circuited, so the trust store decides)"
fi
```

`--help` 的范围也顺手收紧了：原来 `sed -n '2,46p'` 越过了头部三行，把 `set -u` 和 `TEST_GPS=0` 当成 usage 打出来（头部现在到第 43 行，`--help` 取 `2,43p`）。harness 加了一条**否定断言**（`--help` 的输出里不许有 `set -u`），因为一个行号范围会随头部一起漂移，而正向断言看不见这件事。

---

## 4. harness 的形状：两本不重叠的日志

`scripts/host/zl1-gps-selftest.sh`，**69 项**，全部离线。核心设计只有一条：

> **两本 fixture 的日志（`$W/logcat.txt`、`$W/journal.txt`）故意不重叠**：同一个字符串在两本里给不同的计数，而探针只可能从其中一本读它。

于是"数错了日志"这件事的表现不是 0，而是**一个对不上的数字**——一条红检查。第 4 节还专门断言这两本 fixture **确实互不包含**（一个在 logcat 有、在 journal 没有的串，和一个反向的串），因为如果 fixture 重叠了，上面这条性质就悄无声息地消失了——**一个只能 PASS 的断言**。

```
== 1. 归属规则，直接从被测脚本的文字里静态检查                                    7
== 2. 默认这一跑什么都不写（快照比对）                                            7
== 3. 每个计数都来自它主人的那本日志                                               18
== 4. 两本 fixture 必须保持可区分（harness 自己的牙）                              2
== 5. namespace 判定，两个方向都驱动                                               10
== 6. 两个开关、四个属性、HIDL 服务                                                 6
== 7. flag 面                                                                      5
== 8. --test-gps 是 opt-in，并且和相机那条路一样到达 HAL                            5
== 9. 每个模式至今仍是"某个镜像里真实存在的字符串"（镜像没挂就 SKIP）              9
```

第 1 节是静态的，因为它要证明的是**文字层面的归属**：每个模式只出现在它所属的那一块里，两个被删的模式不再出现（既不在脚本里，也不在它自己的注释里——第一版检查的是 `$SRC` 全文，而**被删掉的那两个字符串正写在脚本自己解释"为什么删掉它们"的注释里**，所以那条断言只能红；改成对着抽出来的两个模式列表 `$LPATS$JPATS` 断言）。第 3 节里另有一条：**被删的串不许再被数**，以及"gate 1 短路"与"没短路"两个分支都必须在输出里出现。

第 9 节是第 1 节的另一半，也是唯一的"这条模式是真的"检查：第 1 节只证明每个字符串在**对的列表**里，
那是**归属**，不等于它在任何地方存在——上面刚说过，两个在任何镜像里都不存在的模式就是在同一张表里活下来的。
它需要镜像，所以镜像没挂载时**大声 SKIP**、单独计数、退出码不受它影响（`SKIP` 是对**这台宿主机**的陈述，
不是缺陷；但"只可能 PASS 的检查"正是这份文件要抓的东西，所以它必须被打印出来）。

第 9 节的测试是"**grep 有没有打出命中**"，不是 grep 的退出码：镜像里有几个文件对我们不可读
（`/mnt/android-sys-test/bin/bootstat` 等），grep 把它报成退出码 **2**，于是"按退出码判断"的第一版让
**每一个**模式都以一条权限错误失败——一个 harness 自己的 bug，长得和"这些字符串哪里都没有"一模一样。

第 5 节（namespace 判定）是这一轮 harness 自己犯的错，值得单独说，见 §5。

---

## 5. 这一轮 harness 自己犯的错（都记下来）

1. **`/proc/<pid>/ns/pid` 是符号链接，而 `readlink` 对普通文件打印空。** 第一版 fixture 是
   `printf '%s\n' "$DHOST_NS" > "$FR/proc/700/ns/pid"` 写出来的**普通文件**，于是探针里那两次 `readlink` 都拿到空串，两个空串**相等**，于是**每一条 namespace 判定都输出"在容器里"——原因完全错误，而所有相关检查全绿**。这是同一族缺陷里最干净的一个例子：**harness 自己的 fixture 形状不对时，被测的判定逻辑根本没被执行**。修法是 `ln -sf`，并加上一条**值断言**（探针必须打印 `ns/pid pid:[2222]` 这两个数字），因为"值非空"才是那个判定真正在比较的东西。
2. **默认 fixture 一开始是"坏设备"。** `env_reset` 原来把 daemon 的 ns 设成 HOST，于是第 5 节第一条检查的名字（"daemon 在容器的 namespace 里"）和它自己的 fixture 相反；而且**后面每一节的 fixture 都是一台 namespace 错的设备**。改成默认即健康值（daemon 与容器同 ns），mismatch 由专门的一条场景显式构造。
3. **`want`/`notwant` 拿到文件路径时检查的是路径本身。** `want 'pat' "$OUT"` 里的 `$OUT` 是文本，但有几条断言传的是**文件名**，`grep` 就把路径当字符串匹配了（`countf`/`wantf`/`notwantf` 因此分开：一个给文本，一个给文件）。
4. **`${p#/proc/}` 这个前缀剥离也要做"落点检查"。** 它不是一条路径，所以不在路径重写的计数检查里；没被重写的话 `dpid` 会变成完整路径，两次 `readlink` 都失败，**每一条 namespace 判定都以错误的原因输出"相同"**——第 1 条缺陷的另一面。现在按形状计数：`${p#/proc/}` 在改写后的脚本里必须出现同样多次。
5. **两个模式列表的抽取把每个列表的第一个模式悄悄丢掉了。** `pats()` 只匹配"缩进 + 单引号"那种行，
   而**每个列表的第一个模式写在 `for pat in '...'` 那一行上**，于是 `locClientOpen failed`（探针头部
   自己点名的那个判别模式）和 `Issue instantiating provider` **一个检查都没进**：不参与"两个列表不相交"，
   不参与第 9 节，连打印出来的列表里都没有——而第 1 节的"找到了列表"依旧 PASS。这是这份文件存在的
   那个缺陷类的又一个例子：**一个静默少跑一条的检查**。修法是让 `pats()` 同时接受两种形状。
6. **`grep -r` 在镜像里的退出码是 2。** 见上（第 9 节）：判断"字符串存在"不能用退出码，要用"有没有命中"。
7. **`systemctl cat` 的输出必须落到 `/tmp`，而快照要把那个文件排除。** "什么都不写"的快照比对否则会因为脚本自己写的一个文件而红（这个文件是脚本约定的输出位置，不是它的副作用）。

---

## 6. 这一轮**不**证明什么

* **对设备的结论：零。** 设备在 EDL；logcat、journal、`lshal`、`lomiri-location-serviced-cli`、`/proc` 全是桩。被证明的是**计数来自哪本日志**，不是"这条链上发生了什么"。
* **`locClientOpen failed` 在真机上的计数没有被测。** 这一轮没有设备日志。`93` 的源码结论（它是 `locClientOpen()` 的 `else` 分支，只在 QMI 客户端**成功打开**之后才可能打印）继续成立，但仍然是源码结论。
* **归属表的每一行都是"该字符串出现在该镜像的这个文件里"**，不是"该文件在设备上被加载了"。后者由 `82`（daemon 走 HIDL）和 `98`（容器里的 vendor 树）分别论证过。
* **UT 侧那五个模式至今没有在设备上出现过一次**——`82`/`93` 的结论就是"那条门从来没被客户端的 `StartPositionUpdates` 撞开"。所以这一轮修的是**仪器能不能看见它**，不是"它发生了"。
* **`--test-gps` 没有在设备上跑过**（那是硬件半场，且要设备）。
* **欠着的三条热测量**（`zl1-thermal.sh --ab`）仍然欠着，需要设备。

---

## 7. 复现

```sh
# 全部在宿主机上，只需要 /bin/sh、bash、sed、awk、find、git
sh scripts/host/zl1-gps-selftest.sh          # 60 项
sh scripts/host/zl1-gps-selftest.sh --keep   # 留下假设备、桩、改写后的探针、两本日志 fixture

# 证明 harness 真的在测这些缺陷：把整棵树拷出去，只把探针退回到修复前的 revision。
# **固定写成一个 revision，不能写 HEAD**——HEAD 会随修复一起前移，那样这个对照就变成拿修复跟
# 它自己比（docs 101 记下了这件事真的发生过，以及那个因此永远只可能 PASS 的守卫）。
# 这个缺陷的修复紧跟在 e4cecba 之后：
T=/tmp/zl1-gps-teeth; rm -rf $T; mkdir -p $T/scripts/host $T/scripts/device
cp scripts/host/zl1-gps-selftest.sh $T/scripts/host/
git show e4cecba:scripts/device/zl1-gps-probe.sh > $T/scripts/device/zl1-gps-probe.sh
sh $T/scripts/host/zl1-gps-selftest.sh        # 期望 38 pass / 22 fail

# 归属证据（每个字符串在哪个镜像的哪个文件里；需要只读挂载那三个镜像）
sed -n '1,40p' docs/ubuntu-touch/evidence/gps-log-owners-2026-09-23.log
grep -rlaF --exclude-dir=doc -- 'locClientOpen failed' /mnt/android-sys-test /mnt/vendor-ro
grep -rlaF --exclude-dir=doc -- 'Issue instantiating provider' /mnt/utrootfs
```

回到设备之后，这一节在恢复顺序里的位置不变（`zl1-gps-probe.sh` 是第 2 步的一部分）：

```sh
scripts/host/zl1-health-check.sh                  # 0
scripts/device/zl1-edl-postmortem.sh              # 0
scripts/device/zl1-boot-address-check.sh          # 0b
scripts/install-no-edl-on-panic.sh --capture-only # 0c（只读、免费）
scripts/install-retire-debug-keeper.sh --status   # 0d（只读）
scripts/device/zl1-gps-probe.sh                   # 这一节改的就是它；读数现在按主人分开
```
