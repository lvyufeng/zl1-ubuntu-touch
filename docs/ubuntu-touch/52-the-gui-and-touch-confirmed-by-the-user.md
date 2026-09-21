# 52 — 图形界面和触摸，用户本人确认了

**日期**: 2026-09-21
**状态**: `44` 以来所有关于显示的结论都是间接证据（出帧、背光、QML、socket），`47`/`49`/`51` 都把它列为"还没证实"。现在这一条**由用户本人当场确认**：**图形界面没问题，可以触摸。** 也就是说 `44`–`47` 那一串推断是对的，而且触摸这条从 `48` 起一直挂着的待办也一起结了。触摸能用还顺带解掉了一个副作用：`48` 里 repowerd 起来之后会按空闲超时把背光关掉，当时的结论是"缺一次真实触摸才能唤醒"—— 现在确认那次唤醒是能做到的。
**接续**: [`47`](47-the-screen-comes-back-by-itself.md)、[`48`](48-the-tls-fault-was-killing-seven-system-services.md)、[`51`](51-what-the-wlan-driver-wants-read-from-its-own-source.md)

---

## 1. 用户确认的是什么

原话：**"图形界面没问题，可以触摸"**。

这两句分别关掉两件事：

| 之前的状态 | 现在 |
| --- | --- |
| 屏幕内容从来没被眼睛验证过（`44`–`51` 每一篇都写着"间接证据"） | **看过，没问题** |
| 8 个 event 节点都枚举到了，但"缺一次真实触摸" | **可以触摸** |

## 2. 设备侧的旁证（读，未改任何东西）

同一时刻在设备上读到的：

```
synaptics_dsx   Sysfs=/devices/soc/75ba000.i2c/i2c-12/12-0020/input/input3
                Handlers=kbd mdss_fb kgsl mouse1 event3 cpufreq
                PROP=2                       <-- INPUT_PROP_DIRECT
/dev/input/event3  crw-rw---- root android_input
lomiri --mode=full-greeter   运行中
repowerd                      active
backlight                     0            <-- repowerd 的空闲超时把它关了
```

`PROP=2` 是 `INPUT_PROP_DIRECT`（"坐标就是屏幕坐标，没有光标"），这正是触摸屏该有的标志；`mdss_fb`/`kgsl` 两个 handler 说明显示和 GPU 都在这一条 input 通路上。这些只说明**通路是对的**，真正拍板的是用户那一下触摸 —— 这与 `40` 的教训一致：能读到的东西只证明"配置在了"，不证明"能用"。

## 3. 于是"所有硬件"现在的账是这样

| 子系统 | 状态 |
| --- | --- |
| 显示 | **用户确认可用** |
| 触摸 | **用户确认可用** |
| GPU（kgsl/ion/Adreno 530） | 合成器在用 |
| 电源 / 背光 / 震动 / 手电（`repowerd`、`hfd-service`） | 服务 active（`48`），震动本体没测 |
| rfkill（`urfkill`） | active，日志里已在切 BLUETOOTH 开关 |
| 网络（RNDIS） | 可用（宿主侧要手动 bind，见 memory） |
| **Wi-Fi** | 没有 `wlan0`；WCNSS 没被拉起来（`49`），要的固件名和日志 grep 表已从源码读出（`51`） |
| **GPS / 指纹** | `lomiri-location-service`、`biometryd` 仍失败；`pc=0x0` 已定位为 libhybris 桥接符号解析成 NULL（`50`），**还差上设备查那个符号** |
| 音频 | ALSA 卡片在，`pulseaudio` 没起 |
| 摄像头 / 调制解调器 / 蓝牙 | 设备节点在，没测 |

也就是说：**图形栈这一整个阶段可以收了**，剩下的是逐个外设，而外设里最大的一块（Wi-Fi）已经有了一张可执行的清单。

## 4. 顺带：内核日志的抓取器修好了，而且踩了两个坑

`49` 的结论是"要看开机日志"，但那一刻发现了一件比预想严重的事：**环型缓冲只有约 3470 行 / 249 KiB，而噪声是按需爆发的**。在设备上量的：

| 情况 | 6 秒内的变化 |
| --- | --- |
| 空闲（没有任何流量） | 3473 → **3470** 行（噪声停止） |
| 有 ssh 在收发 | 3 秒 ~3480 行（约 90 KiB/s） |
| 只算我连着的那段时间 | 环里最早那条的 timestamp 只有 **10 秒**之前 |

噪声是 `tx_complete` 的 WARN 栈（我们自己 `patch-uether-tx-wakeup.sh` 带出来的），**由宿主侧流量触发**。三个结论：

1. 开机日志**抓得到** —— 只要在宿主开始说话之前抓；
2. 一个常驻的 `dmesg -W >> 文件` 是**错的工具**：它会在 eMMC 上按 90 KiB/s 写（≈8 GiB/天），而那时值得留的开机日志早就没了；
3. 所以改成了**一组有界快照**：`DefaultDependencies=no` + `Before=sysinit.target` 的 unit，在 uptime 约 0/5/15/35/75/155/315 秒各 dump 一次整个环，然后退出。一次开机几 MiB，`--read` 直接从里面 grep `cnss|wlan|wcnss|qca6174|ar6320|qcacld`（`51` §4 那张表的用法）。

两个坑记下来，因为它们都不是"看起来会错"的那种：

- **`while read` 读 `/dev/kmsg` 会立刻退出。** bash 的 `read` 一次一个字节地 `read()`，而 `/dev/kmsg` 的记录被部分读取就返回 `EINVAL`。所以 `exec 3< /dev/kmsg; while IFS= read -r line <&3` 这个循环**一行都读不到就结束了**，脚本"成功地"什么都没写。要跟读得用 `dmesg -W`（或 `cat`，它一次读一大块）。第一版就是栽在这里，表现为"unit 每隔 5 秒重启一次，日志文件不存在"。
- **`printf '%s' "$VAR"` 把前导空行也写进了脚本**，于是文件第一行不是 shebang，systemd 报 `Failed to execute ... Exec format error` / `status=203/EXEC` —— 这句话完全不提真正的原因。现在推送前会 `sed '/./,$!d'` 去掉前导空行并且**断言第一行是 `#!`**，不满足就不推。

快照器已经在设备上跑起来了（`boot-382s.log`、`boot-387s.log`、`boot-397s.log` 各约 3470 行），但**真正的验证要等一次重启**：只有开机头几秒的快照里才有 cnss 的话。这一条写在 §5。

## 5. 下一步

1. **重启一次，然后 `install-kmsg-drain.sh --read 300`。** 看 `boot-*s.log` 里有没有 cnss/wlan 的行 —— 这是 `51` 那张 grep 表第一次能真正用上。**在它没有结果之前不碰 wifi 驱动。**
2. 按 `51` §3 的命令核对那七个固件文件名（`qwftm/otf30/utf30/utfbd30/epping30/evicted30` 里还没看过的那五个）。
3. **`check-android-bridge-libs.sh --dev`** —— 查 `libubuntu_application_api.so` / `libbiometry_fp_api.so` 在容器里在不在、缺哪个符号，把 `50` 的纸上结论变成量出来的。
4. 音频（`pulseaudio` 是 user unit）、`update-machine-info-from-deviceinfo.service`、以及相机/调制解调器/蓝牙的摸底。

## 6. 这一段改了哪些东西

| 文件 | 作用 |
| --- | --- |
| `scripts/install-kmsg-drain.sh` | **重写**。从"常驻跟读 `/dev/kmsg`"改成"开机早期的一组有界快照 + 可选的 `--follow-on` 实时跟读"。加了 `--follow-on` / `--follow-off`。修掉两个坑（§4）：`dmesg -W` 代替 `while read /dev/kmsg`；推送前去掉前导空行并断言 shebang。已经在设备上装好并跑起来了 |
| `docs/ubuntu-touch/52-*` | 这一篇 |
