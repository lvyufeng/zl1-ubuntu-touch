# 109 — 那九段证据里有答案，只是没人给出判词

**日期**: 2026-09-23
**状态**: 纯离线的一轮。设备仍在 Qualcomm EDL（`05c6:9008` / port 3-3，无序列号），出来只能靠物理长按电源。
这一轮**没有**新的硬件结论，但它把一条**已经录下来的**硬件结论读了出来，并且修掉了"读不出来"的原因：
GPS 探针跑完九个证据段、然后**不给判词**。第一次真跑（[`108`](108-the-scan-that-never-finished-and-the-boot-it-cost.md)）
留下的 `05-gps-probe.txt` 因此被读成"GPS 探针什么判词都没有"——而它里面恰好有这条链**至今最深**的那条证据。

**接续**: [`108`](108-the-scan-that-never-finished-and-the-boot-it-cost.md)（那次真跑与它留下的档案）、
[`93`](93-gps-the-door-is-a-client-request-and-the-two-levers-are-dead.md)（门是一次客户端请求，而两个杠杆都是死的）、
[`102`](102-gps-log-owners-and-the-two-unreachable-branches.md)（日志字符串属于包含它的进程）、
[`82`](82-the-gps-line-read-the-source-and-the-rootfs.md)（`locClientOpen` 那条日志的源码读法）、
[`99`](99-the-remaining-heat-fix-was-broken-offline.md)（仪器不能报告它存在理由的那一族缺陷）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 这一轮发现了什么？ | `tmp-post-recovery-20260923T145530Z/05-gps-probe.txt` 里的计数是：`locClientOpen failed` **0**、`Failed to get features supported` **2**、`gnssSetCapabilitesCb` **2**，日志尾部还有 `u_hardware_gps_set_position_mode: called` |
| 这意味着什么？ | 按 `82` 的源码读法（那条 "Failed to get features" 只在 `locClientOpen()` 的 `else` 分支里写，也就是**只有客户端开成功了才可能出现**），**容器里的 vendor GPS HAL 跑起来了，它的 QMI 客户端开成功了**，而且 UT 适配层被走到了 |
| 所以之前记的"门从没被敲过"呢？ | **不再被录到的日志支持**。`u_hardware_gps_set_position_mode` 就在里面。计数**不能**说的是：那次调用来自客户端的 `StartPositionUpdates`，还是来自 daemon 自己的 provider 初始化 |
| 为什么没人读到？ | 探针印九段证据、**不印判词**。那次运行被总结成"GPS 探针没有判词"，于是一条已经握在手里的结论被当成"没有结论" |
| 修了什么？ | 探针新增 `== verdict`（§6）：从**第 3 段的计数**（而且是**同一个变量**，不是重算一遍）推出链条停在哪一级，并且**明说它判不了什么** |
| 退出码？ | `0` = 链条确实到达容器的 vendor GPS HAL（**只给这一种**）；`1` = 有具名的阻塞点，或完全没有证据；`2` = 用法 |
| 判不了的那一层？ | `lshal` 的**列**。整棵树里没有任何地方记录这些列在这张镜像上的含义，所以探针**不解析**它——用猜出来的列做判词就是编造答案（`99`/`108` 同一族缺陷） |
| 离线验证？ | `scripts/host/zl1-gps-selftest.sh` **99 检查 / 0 失败 / 1 skip**（原来 69 条），**五次变异每一次都让它失败**（§5） |

---

## 2. 那条证据，逐字

设备在 `2026-09-23 14:55` 那次开机上真的记下了这些（`evidence/gps-probe-live-2026-09-23.txt`）：

```
--- logcat (the container's vendor GPS HAL) ---
locClientOpen failed                           0
Failed to checking QMI_LOC message supported   0
Failed to get features supported               2
gnssSetCapabilitesCb                           2
-- the last 8 logcat lines that mention gps/gnss/LocSvc:
| I/ubuntu_application_gps_hidl_for_hybris( 1757): set_gps_service_callbacks: called
| D/PerMgrSrv(  338): GPS voting for modem
| I/ubuntu_application_gps_hidl_for_hybris( 1757): gnssSetCapabilitesCb: called
| I/ubuntu_application_gps_hidl_for_hybris( 1757): gnssSetSystemInfoCb: called
| E/ubuntu_application_gps_hidl_for_hybris( 1757): Unable to initialize GNSS Xtra interface
| I/ubuntu_application_gps_hidl_for_hybris( 1757): u_hardware_gps_set_position_mode: called
| I/ubuntu_application_gps_hidl_for_hybris( 1757): set_position_mode: called
| I/chatty  (  551): uid=1021(gps) NDK identical 1 line
--- journal of lomiri-location-service ---
Instantiating and configuring                  6
(其余 journal 计数与四个 trust-store 门控消息均为 0)
```

读法逐条，以及每条为什么成立：

* **`locClientOpen failed` = 0 且 `Failed to get features supported` = 2。** 这两个字符串都在
  `/mnt/vendor-ro/lib64/libloc_api_v02.so` 里（离线查过），也就是**容器里的 vendor GPS HAL**——所以非零计数
  是"那个进程跑过"的证明，不是猜测。而 `82` 的源码读法说：features 那条只写在 `locClientOpen()` 的
  `else` 分支，**只有开成功了才可能被写出来**，并且它不是致命错误（`open()` 只在 `locClientOpen` 失败分支里
  把 rtv 置成 FAILURE，而那条会打 `locClientOpen failed`）。所以这里的状态是**客户端开成功了**。
* **`gnssSetCapabilitesCb` = 2。** 这个字符串在 `/mnt/android-sys-test/lib/android.hardware.gnss@1.0.so`
  里——vendor HAL 在回应回调，不只是被加载。
* **`u_hardware_gps_set_position_mode: called`。** 这些字符串在
  `/mnt/utrootfs/usr/lib/aarch64-linux-gnu/libubuntu_platform_hardware_api.so.4.0.0` 和
  `liblomiri-location-service.so.3.0.0` 里（离线查过），即 **UT 侧**。它们出现在 **logcat** 而不是 journal，
  是因为容器里那个 hybris HAL shim 加载了同一个库——这正说明了为什么它**不能**被算成四个"计数模式"之一：
  一个 UT 侧库字符串对两份日志都不构成干净陈述。探针单独把它数出来并印出来，判词只用它说"适配层被走到了"。

**之前为什么读反了。** `93` 记的是"门是一次客户端请求"，而当时的结论是那条请求从来没发生过。这条记录现在
**不再被录到的日志支持**：`set_position_mode` 就在日志里。判词因此把它当成"更深一层的问题"，
并且**明确写下它判不了的那件事**——那次调用是客户端发起的还是 daemon 自己的 provider 初始化发出的，
这些计数决定不了。

---

## 3. 探针的缺陷：一个不会给自己判词的仪器

`zl1-gps-probe.sh` 印九段证据，然后**结束**。没有 `== verdict`，退出码恒为 0。后果在那次真跑里立刻显形：

* 我（和任何读者）把它读成"GPS 探针没有任何判词"；
* 而 `05-gps-probe.txt` 里握着的是**这条链至今最深的一条证据**；
* 于是"没有结论"被记了下来，而真相是"有一个结论，但仪器不说"。

这和 `99`/`108` 是同一族：**一个不能报告它存在理由的仪器**。修法不是再印一段证据，而是**让它说出判词**，
并且把判词建在**已经算过的那几个数**上——不是重算一遍：

```sh
count_of() { printf '%s\n' "$2" | grep -ac "$1"; }
for pat in 'locClientOpen failed' ... ; do
  n=$(count_of "$pat" "$dump")
  printf '   %-46s %s\n' "$pat" "$n"
  case "$pat" in
  'locClientOpen failed') n_cc_fail=$n ;;
  ...
  esac
done
```

**表格和判词从同一个变量出来**，因为"两处各自算同一个数"正是判词引用到一个不是表格里那个数的原因。

判词的分级（按链条被走过的顺序，**先检查的东西写在前面**）：

```
no-container        容器不应答（lxc-info 什么都没有）——它下面的一切都不必判
wrong-namespace     daemon 活着但在 HOST PID namespace：看不到容器的 hwbinder 服务，链条根本没开始
trust-store-refused 信任库拒绝了（‘Client lacks permissions…’），并报 gate 1 的状态
qmi-open-failed     链条到达 vendor HAL，而它的 QMI 客户端**开失败了**（‘locClientOpen failed’）
reaches-vendor-hal  链条到达 vendor HAL，**客户端开成功了**；适配层也被走到  → 唯一 exit 0 的一档
daemon-only         daemon 建了 provider，但两份日志都没有请求到达 vendor HAL
no-gnss-listing     什么都没跑，而且 lshal 连一条 gnss 都没有
no-evidence         这一开机无法说明链条在哪断，只能说它没开始
```

`no-container` 和 `wrong-namespace` 在**所有日志分级之前**：容器不在（或 daemon 看不见它）时，
任何日志计数都不能证明链条走过——把它们排在后面就是拿一个不可能成立的证据做判词。

---

## 4. 判不了的就是判不了：`lshal` 的列

第四个证据段是 `lshal` 的 gnss 行，设备上长这样：

```
   Y android.hardware.gnss@1.0::IGnss/default                    N/A        N/A
     android.hardware.gnss@1.0::IGnss/default         N/A        257    257
```

`Y` 是 VINTF manifest 里的声明，这一点确定；**后面那几列的含义，这棵树里没有任何地方记录**。
我查过：仓库里没有 lshal 的格式说明，`system.img` 里的 `/system/bin/lshal` 在这份备份镜像上读不出来
（`debugfs` 报 `File not found by ext2_lookup`，而同一份镜像的 `/` 列得出来），而**用猜出来的列去判断
"服务注册了没有"就是编造答案**——这正是 `99`（`iface()` 复用调用者的循环变量）、
`108`（`awk` 累加器）那一族的形状。

所以探针**明写**它不解析这张表：

```
   -> and that is as far as this probe goes with it. The listing's columns are not parsed on
      purpose: nothing in this tree records what they mean on this image, and a verdict built on a
      guessed column would be a fabricated answer (docs 99/108). n_gnss is a COUNT of lines that
      mention gnss, used only to say "the listing is empty" -- never to say "the service is up".
```

而 `n_gnss`（gnss 行数）只用来判**一个**分支：一行都没有时（`no-gnss-listing`）说"连列都没得列，
先去修这个"。设备上是 7 行，所以那一档对设备不成立——探针对设备的判词是 `reaches-vendor-hal`。

**这一层仍然是这一轮没有解决的**：GNSS HIDL 服务到底注册没有，需要一个**有依据的**读法
（`lshal` 的 flag、或某个进程/`/dev` 检查），而不是解析一张没人记录过格式的表。

---

## 5. 离线验证：99 检查，和五次"必须失败"

`scripts/host/zl1-gps-selftest.sh`（证据：`evidence/gps-verdict-selftest-2026-09-23.log`）。
新增第 10 节，每个场景**只在一个证据来源上不同**，而且第一个 fixture 就是**那次真跑的逐字内容**
（不是编出来的"应该长这样"）：

| 场景 | 判词 | 退出码 |
|---|---|---|
| 录到的那次开机（features=2、fail=0、adapter 被走到） | `reaches-vendor-hal` | **0** |
| 同上 + `custom.location.testing` 被设上 | 同上，并加一行"这个位置可能是测试钩子的，不是 modem 的" | 0 |
| journal 里出现信任库拒绝 | `trust-store-refused`，**且不**声称 HAL 那一级 | 1 |
| daemon 建了 provider、logcat 里什么都没有 | `daemon-only`，并画出"provider ≠ 位置请求"的分界 | 1 |
| daemon 在 HOST namespace | `wrong-namespace`，**不**引用任何日志分级 | 1 |
| 没有容器 | `no-container`，logcat 表被跳过而不是印成一堆 0 | 1 |

外加一条**顺序**断言：`== verdict` 必须排在每一个证据段之后（判词不能出现在它的证据前面）。

变异测试（一个不会失败的 harness 什么也证明不了）：

| 变异 | 结果 |
|---|---|
| 把 `qmi-open-failed` 和 `reaches-vendor-hal` 两支对调 | `98 pass / 1 fail` |
| 退出码恒为 0 | `94 pass / 5 fail` |
| 去掉 namespace 那一支 | `97 pass / 2 fail` |
| 去掉"测试钩子"那一行 NOTE | `98 pass / 1 fail` |
| 把适配层计数改成从 **journal** 读（正是这个 harness 存在的那个缺陷类） | `97 pass / 2 fail` |

写这一节又抓到**四条断言自己的错误**，都记在这里，因为形状是同一个"测试看起来过了但什么也没测"：
把适配层计数写成 2（录到的是 **1**：下一行是 `set_position_mode: called`，不带前缀，fixture 忠实于记录，
是我的断言错了）；断言里跨了一次换行（"columns are not parsed on purpose" 在两行上）；把 gate 1 的断言
放进了不印 gate 1 的那一支；以及用 `/etc/gps.conf` 这个**被 sed 重写过的路径**去找段落顺序。

---

## 6. 这一篇**不**证明什么

* **不证明 GPS 能用。** 判词说的是"链条到达 vendor HAL、客户端开成功"——这是对它**上面**几层的正面结论，
  不是"能拿到定位"。也没有任何一次定位被拿到过。
* **不证明那次调用是客户端发起的。** 判词自己写着：这些计数决定不了它来自客户端的
  `StartPositionUpdates` 还是 daemon 自己的 provider 初始化。判词只说"适配层被走到"。
* **不证明 GNSS HIDL 服务注册了。** 那一层探针只能印、不能判（§4），而它现在会说出来。
* **不证明设备能回来。** 仍在 EDL，出来只能物理长按电源 10–20 秒（`49` §6），没有 QDL/firehose 工具会被跑。

---

## 7. 设备状态

设备在 **Qualcomm EDL**（`05c6:9008` / `QUSB__BULK`，port 3-3，无序列号）。整轮只读过：
`lsusb`、`/sys/bus/usb/devices`、`dmesg`，以及 `ubports-rootfs/rootfs.img` 和
`/mnt/utrootfs`、`/mnt/android-sys-test`、`/mnt/vendor-ro` 三个只读挂载（用来核实每个日志字符串的归属）。
**没有写任何分区或 boot，没有跑 QDL/QFIL，没有重启，没有拔插。** 识别目标按序列号前缀
**`33e80afe`**；总线上另一台设备 **`4a2fe00b`** 必须忽略。

下一步仍然是物理的：长按电源 10–20 秒，等 RNDIS 回来，然后
`scripts/host/zl1-post-recovery-capture.sh` —— 这一次它的 `05` 会**给出判词**，
而不是再留下一份没人能读的九段证据。
