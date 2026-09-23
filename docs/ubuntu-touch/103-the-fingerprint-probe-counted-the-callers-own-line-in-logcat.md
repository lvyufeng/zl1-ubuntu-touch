# 103 — 指纹探针把调用者自己写的那一行数在了容器的 logcat 里

**日期**: 2026-09-23
**状态**: 纯离线的一轮（设备在 EDL，`05c6:9008` / port 3-3，与 `86`–`102` 同）。把 [`102`](102-gps-log-owners-and-the-two-unreachable-branches.md) 的**归属规则**用到第二个探针上：`zl1-fingerprint-probe.sh` 的第 4 节有**同一族的缺陷**，而且更严重——它数错的那一行正是**整个探针的论据**。`scripts/host/zl1-loc-fp-selftest.sh` 从 124 长到 **179 项**，并且这一轮也在 harness 自己身上抓到三处"检查通过但什么都没测"。设备整轮没有测量。

**接续**: [`83`](83-the-fingerprint-einval-is-a-missing-directory.md)（`SYS_EINVAL` 是一个缺失的目录，静默的 `access(W_OK)` 分支）、[`97`](97-both-hardware-probes-write-the-wrong-thing.md)（两个探针写错过地方）、[`98`](98-the-fingerprint-chain-has-two-more-layers-under-the-wrapper.md)（包装 HAL 底下还有两层）、[`101`](101-which-directory-the-fingerprint-hal-is-handed.md)（section 2 问错了进程的属性）、[`102`](102-gps-log-owners-and-the-two-unreachable-branches.md)（同一规则用在 GPS 探针上）。每个模式的归属证据在 `docs/ubuntu-touch/evidence/fp-log-owners-2026-09-23.log`。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 这一轮修的是什么？ | `zl1-fingerprint-probe.sh` 第 4 节：十三个模式全被数在容器的 logcat 里，而其中**五个在任何镜像里都不存在**，**一个在 UT 侧**——而那个恰好是探针头部引用的那一行 |
| 哪一行最要紧？ | **`setActiveGroup failed`**。探针头部写着：设备日志里只有**调用者**的 `setActiveGroup failed: SYS_EINVAL`，HAL 自己一个字都没有，因为 `access(W_OK)` 那条分支**不打日志**（`BiometricsFingerprint.cpp:221-223`）。调用者是 **biometryd**，而这行字符串在 **`libbiometry.so.2.0.0`** 里——**UT 侧**，所以它进 biometryd 的 journal，**永远不可能出现在 logcat** |
| 后果是什么？ | 探针第 4 节让读者做的那个比较（"'Bad path length' = 0 而 'setActiveGroup failed' > 0 就是 access() 分支"）**按打印出来的样子永远无法成立**：其中一半结构性为 0。而一个读 0 的人会得出**"HAL 根本没收到这个调用"**——正好和头部自己写的相反 |
| 另外五个？ | `Unable to get FP service`、`Connected to IBiometricsFingerprint`、`Unable to get IBiometricsFingerprint` 在三个镜像里**一个字节都没有**；`Can not open fingerprint HW Module`、`Can not create instance of BiometricsFingerprint` 则是**字符串写错了**——二进制里是 **`Can't`**，不是 "Can not"。在一个"以缺失的那一行为主题"的探针里，这两种 0 都不随设备状态变化 |
| harness 里有什么故事？ | `Connected to IBiometricsFingerprint` 之所以看着像真的，是因为**harness 自己的 logcat fixture 里就有它**（`Connected to IBiometricsFingerprint::2.1 service`）。fixture 只能放镜像里真实存在的字符串 |
| 抓到 harness 的什么缺陷？ | 三处，全是"检查跑了、PASS 了、什么也没测"：①**nsenter 桩从来不把 logcat 交给探针**，所以第 4 节的 dump **永远是空的**，每一个计数在所有场景里都是 0——而断言照样 PASS，因为**表里会打印模式名**（旧检查 `it counts the caller's line` 就是这么过的）；②fixture 里放着不存在于任何镜像的字符串；③`journalctl`/`lshal` 这两个也要经过 `nsenter` 的调用同样没人应答 |
| 怎么修的？ | 第 4 节按主人拆成两块；`Can't` 两条改成真实字符串；五个不存在的删掉（并在注释里写明原因）；journal 侧补上四个从来没被数过的模式（`Failed to instantiate device`、`Cannot construct Forwarding device`、`Clearing template store`、`Failed to enroll template`）；把那个推断单独打印出来，说明两半分别在**哪本日志**里；`--help` 的范围原来停在**Usage 那一行之前**，一并修掉 |
| harness 有多少牙？ | 对 `099b301` 的探针：**179 项里 15 条红**，全部是这一个缺陷的侧面 |
| 动设备了吗？ | 没有。三个镜像只读挂载，探针只在假设备里跑（`nsenter`/`logcat`/`journalctl`/`lshal`/`lxc-info` 都是桩），没有写设备，没有 QDL/firehose，没有重启 |

---

## 2. 缺陷的形状：论据那一行被数在了没有它的那本日志里

老代码（`099b301`）第 4 节：

```sh
echo "== container logcat counts (the HAL's silent branch is the point -- a missing line is evidence)"
dump=$(nsenter -t "$A" -p -m -- /system/bin/logcat -d -v brief 2>/dev/null)
for pat in 'setActiveGroup failed' 'Bad path length' 'Unable to get FP service' \
           'Connected to IBiometricsFingerprint' 'Unable to get IBiometricsFingerprint' \
           'Opening fingerprint hal library' 'Can not open fingerprint HW Module' \
           'Start biometrics' 'Can not create instance of BiometricsFingerprint' \
           'fps_hal' 'gx_fpd' 'Fp::connect failed' 'getService failed' ; do
  printf '   %-52s %s\n' "$pat" "$(printf '%s\n' "$dump" | grep -ac "$pat")"
done
echo "   -- 'Bad path length' = 0 while 'setActiveGroup failed' > 0 means the access() branch,"
echo "      which logs NOTHING (BiometricsFingerprint.cpp:221-223)."
```

十三行里：

* **`setActiveGroup failed` 结构性为 0**（它是 biometryd 的，见 §1）。偏偏是它。探针头部花了整整一段解释"设备日志里只有调用者这一行"，然后**用一个永远读不到它的地方去数它**。
* **五个在任何二进制里都不存在**：三个是整个字符串不存在，两个是拼写不同（`Can't` vs `Can not`）。
* 剩下的七个里有两个（`fps_hal`、`gx_fpd`）是 **logcat 的 TAG**——logcat 行的 tag 就是**进程名**，所以进程名可以在 logcat 里出现而不出现在任何二进制里。这是全文唯一的例外，也是它们被保留下来的理由（写进注释里了）。
* 真正在容器二进制里的只有五个：`Bad path length`、`Start biometrics`、`Opening fingerprint hal library`、`Fp::connect failed`，以及 `getService failed`（**这条是通用串**：同一个字符串还出现在这个 Android 镜像里两个无关的 blob 里，所以它的 >0 不一定来自这条链——注释里写明了）。

修完的样子：

```
   --- logcat (the container's vendor service and the modules it loads) ---
     service.leeco_zl1        Bad path length      <-- access() 的前置条件
                              Start biometrics     <-- openHal() 走到了注册服务这一步
                              Opening fingerprint hal library
                              Can't open fingerprint HW Module
                              Can't create instance of BiometricsFingerprint
     fingerprint.msm8996.so   Fp::connect failed
     libsecureui_svcsock.so   getService failed   （通用串，>0 不一定是这条链）
     fps_hal / gx_fpd         TAG = 进程名（不是二进制里的字符串）
   --- journal of biometryd (调用者 biometryd + 它加载的库) ---
     libbiometry.so.2.0.0     setActiveGroup failed: %s   <-- 头部引用的那一行
                              Failed to instantiate device
                              Cannot construct Forwarding device
                              Clearing template store
                              Failed to enroll template
```

并且把那个推断单独打印成两行比较，并**说明每一半来自哪本日志**：

```
      'Bad path length' > 0                  -> the path never reached access() (too long/empty)
      'Bad path length' = 0 AND the caller's
      'setActiveGroup failed' > 0            -> the access(W_OK) branch, which logs NOTHING
```

`journalctl -b -u biometryd --no-pager -o cat`：按**这次启动**取（这台设备没有可用的 RTC），关分页，和 GPS 探针同一规则。

---

## 3. 这一轮在 harness 自己身上抓到的三处

一个 harness 的假检查和缺失的检查代价一样。这一轮的三处**都是"检查跑了、PASS 了、什么都没测"**，而且第一处让第 4 节的存在意义归零：

1. **nsenter 桩从来不把 logcat 交给探针。** 探针读容器日志是
   `nsenter -t "$A" -p -m -- /system/bin/logcat -d -v brief`，而桩只应答 `getprop` / `service list` / `test -e` / `test -f` / `ls` 这几种问题，**别的原样 `exit 0`**。于是 `dump` 永远是空字符串，第 4 节每一个计数**在每一个场景里都是 0**——而断言照样 PASS，因为**表里总是打印模式名**：`want 'setActiveGroup failed' "$OUT" "it counts the caller's line"` 匹配的是**标签**，不是计数。这和第 102 轮 GPS harness 里"检查的是路径本身而不是内容"是同一族。修法是给桩加 `*"logcat"*) cat "$W/logcat.txt"` 和 `*"lshal"*) cat "$W/lshal.txt"` 两个分支——**fixture 必须真的被交付**。
2. **fixture 里放着任何镜像里都不存在的字符串。** `Connected to IBiometricsFingerprint::2.1 service` 是写 fixture 的人**编的**，而探针正好数 `Connected to IBiometricsFingerprint`。一个只在 harness 里存在的字符串把一条只在 harness 里成立的检查撑起来。fixture 现在只用镜像里 grep 得到的字符串，并且第 10 节会逐个核对。
3. **`logcat is read as a dump` 这条断言读的是 `^logcat`。** 探针的 logcat 调用经过 `nsenter`，所以 `$ACT` 里记下的是 `nsenter ...` 那一行；`grep '^logcat '` 什么也找不到，于是这条断言**在它命名的这件事上既不可能通过也不可能失败**。改成 `grep '^nsenter .*logcat'`。

另外两处是**抽取器**的老毛病（第 102 轮同一件事）：模式列表的第一个模式写在 `for pat in '...'` 那一行上，而且两个模式里有撇号（真实字符串是 `Can't ...`），所以在脚本里是**双引号**的——只认识单引号的抽取器把它们**静默丢掉**。现在抽取器接受两种引号，并且加了一条**计数检查**：块里有几行带引号，就必须抽出几个模式。

---

## 4. harness 的形状：两本不重叠的日志，加上唯一一条"字符串是真的"检查

`scripts/host/zl1-loc-fp-selftest.sh`，**179 项**（原 124）。新增两节：

* **第 7b 节**：把探针的输出按 `--- logcat (the container` / `--- journal of biometryd` 切成两块，然后**逐个模式**断言它的计数等于**它主人那本 fixture** 的计数。fixture 两本故意不重叠、计数也互不相同，所以"读错了日志"打印出来的是**对不上的数字**（是 0 而 fixture 是 2），而不是一个看起来很像的 0。另有：日志查询是 `-b`、关分页、`logcat -d`（不是 follow）、两块都在输出里、以及五个被删的字符串不再被数。
* **第 10 节**：每个模式**至今仍是某个镜像里真实存在的字符串**。这是唯一一条"字符串是真的"检查——第 7b 节证明的是**归属**，不是**存在**，而这一轮五个模式就是在同一张表里靠"归属看着对"活下来的。需要镜像，没挂载就**大声 SKIP**、单独计数（exit code 不受它影响，但必须打印出来）。判定标准是**grep 有没有打出命中**，不是退出码：镜像里有文件对我们不可读，grep 报退出码 2。

---

## 5. 这一轮**不**证明什么

* **对设备的结论：零。** 设备在 EDL；`logcat`、`journalctl`、`nsenter`、`lshal`、`/proc` 全是桩。被证明的是**哪个进程能写哪一行**，不是"这台设备的日志里有什么"。
* **`setActiveGroup failed` 在真机上出现过吗？** 没有测。真实设备上的指纹那一条链至今**没有取得过任何一次成功**（`83`/`98`/`101`），所以这一轮修的是**仪器能不能看见它**，不是"它发生了"。
* **`fps_hal`/`gx_fpd` 两条**在第 10 节是**弱一点的说法**：它们是进程名，在镜像里以 `.rc`/selinux 文件的形式存在，不是二进制字符串。检查问的是"在镜像的某个文件里"，不是"在二进制里"——注释里写明了。
* **`getService failed` 是通用串**：同一个字符串在这个 Android 镜像的两个无关 blob 里也有，所以它的 >0 不能归因给这条链。这一条只是没有被删（它确实在 HAL 里）。
* **`--create-store-dir` 那一条写**仍然只有用户同意才做；这一轮没有靠近它。
* **欠着的三条热测量**（`zl1-thermal.sh --ab`）仍然欠着，需要设备。

---

## 6. 复现

```sh
# 全部在宿主机上，只需要 /bin/sh、bash、sed、awk、find、git
sh scripts/host/zl1-loc-fp-selftest.sh          # 179 项
sh scripts/host/zl1-loc-fp-selftest.sh --keep   # 留下假设备、桩、改写后的脚本、两本日志 fixture

# 证明 harness 真的在测这个缺陷：固定写成一个 revision（不能写 HEAD —— 修复一提交，对照就变成
# 拿修复跟它自己比，docs 101 记下了这件事真的发生过）
T=/tmp/zl1-fp-teeth; rm -rf $T; mkdir -p $T/scripts/host $T/scripts/device
cp scripts/host/zl1-loc-fp-selftest.sh $T/scripts/host/
git show 099b301:scripts/device/zl1-fingerprint-probe.sh > $T/scripts/device/zl1-fingerprint-probe.sh
cp scripts/device/zl1-location-request.sh $T/scripts/device/
sh $T/scripts/host/zl1-loc-fp-selftest.sh        # 期望 150 pass / 15 fail

# 归属证据（每个字符串在哪个镜像的哪个文件里）
sed -n '/side B/,$p' docs/ubuntu-touch/evidence/fp-log-owners-2026-09-23.log
grep -rlaF --exclude-dir=doc -- 'setActiveGroup failed' /mnt/utrootfs
grep -rlaF --exclude-dir=doc -- 'Bad path length' /mnt/android-sys-test /mnt/vendor-ro
```

回到设备之后，这一节的位置不变（`zl1-fingerprint-probe.sh` 是恢复顺序里的第 3 步）：

```sh
scripts/device/zl1-fingerprint-probe.sh     # 这一节改的就是它；读数现在按主人分开
```
