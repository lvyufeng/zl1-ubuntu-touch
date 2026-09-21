# 48 — 硬件盘点，以及同一个 TLS 缺陷还在杀另外七个系统服务

**日期**: 2026-09-21
**状态**: 图形界面在跑之后做了一次硬件盘点。发现 `systemctl --failed` 里那七个服务**全是同一个 SIGSEGV** —— 也就是 `41`/`45` 那个 bionic TLS 槽，只不过这次踩到的是**系统服务**而不是合成器。给它们加上垫片之后 `mechanicd`、`repowerd`、`urfkill`、`hfd-service` 直接变成 active，`sensorfwd` 起来了但没到 ready，`lomiri-location-service` 和 `biometryd` 仍然段错误（下一步要抓 core）。
**接续**: [`47`](47-the-screen-comes-back-by-itself.md)、[`45`](45-the-shell-crashed-on-a-thread-then-picked-the-wrong-linker.md)、[`41`](41-bionic-tls-slot-is-never-filled.md)

---

## 1. 硬件盘点（都在，驱动情况不一样）

| 子系统 | 内核/设备侧 | 用户侧 | 状态 |
| --- | --- | --- | --- |
| 显示 | `mdss`、`/sys/class/leds/lcd-backlight`（128） | lomiri-system-compositor + Lomiri 外壳 | **跑起来了**（`44`–`47`） |
| 触摸 | `synaptics_dsx` = `/dev/input/event3`，`android_input` 组 | Lomiri 已 `Input device added`（8 个 event 节点全部） | 枚举到了，**事件没测过** |
| 网络 | 只有 `rndis0`（RNDIS，宿主侧 DHCP 到 10.15.19.82）；`rmnet_data0..7` 全 DOWN | NetworkManager active | **没有 `wlan0`** |
| 音频 | ALSA card 0 = `msm8996-tasha-mtp-snd-card`，`/dev/snd` 有 38 个节点 | pulseaudio **inactive** | 卡片在，没起 |
| 传感器 | `/sys/bus/iio/devices` 空，`/dev/sensors` 存在 | `sensorfwd` activating | 差一步 |
| 摄像头 | `/dev/video0..3`、`video32/33`、`venus_dec/enc` | — | 设备在，没测 |
| 调制解调器 | `/dev/smd7/8/11/21/22/36`、`smdcntl0/8`、`rmnet_ctrl0..3` | ofono active，rild 在跑 | 设备在，没测 |
| GPS | `/dev/ttyHS0`、`ttyHSL0/1` | `lomiri-location-service` **failed** | 缺 |
| 蓝牙 | rfkill 里能看到 `bt_power` | `bluetooth-touch` 单元 | 没测 |
| 电源/电池 | `/sys/class/power_supply/{battery,bms,fg_adc,usb,...}` | `repowerd`（现在是 active） | 见 §3 |
| 震动/手电 | `/sys/class/timed_output/vibrator`、`leds/torch_light0/1` | `hfd-service`（现在是 active） | 服务起来了，没测 |
| Wi-Fi 固件 | — | — | `/vendor/firmware_mnt/image/bdwlan30.b0*` 在，但 `/lib/firmware` 里没有对应物，**也没有 `wlan` 模块** |

缺 Wi-Fi 的形态很具体：**没有 `wlan0`、没有无线模块可加载、固件只在 Android 的 `/vendor/firmware_mnt` 里**。这是下一步要单独打的一场。

## 2. 七个服务，同一个 SIGSEGV

`systemctl --failed` 出来七个，全都是 `code=killed, signal=SEGV`：

```
mechanicd  repowerd  sensorfwd  urfkill  hfd-service  lomiri-location-service  biometryd
```

它们全是 Halium 服务（电源、传感器、rfkill 开关、震动、GPS、指纹），都要经 libhybris 调进 Android —— 也就都会去读那个**没人填的 bionic TLS slot 1**，然后死在同一个地方。`41` 修的是合成器，`45` 修的是会话（写进 `lsc-wrapper` 和 Lomiri 的 unit drop-in），**系统服务一个都没管**。

给它们每个加一份 drop-in：

```ini
# /etc/systemd/system/<unit>.d/zl1-tls.conf   （写在可写路径上，能活过重启）
[Service]
Environment=LD_PRELOAD=/usr/lib/aarch64-linux-gnu/libtls-padding.so
```

结果：

| unit | 加垫片前 | 加垫片后 |
| --- | --- | --- |
| `mechanicd` | SEGV | **active** |
| `repowerd` | SEGV | **active** |
| `urfkill` | SEGV | **active**（日志里已经在 `Setting device 0 (BLUETOOTH) to unblocked`） |
| `hfd-service` | SEGV | **active** |
| `sensorfwd` | SEGV | activating（不再崩，但没到 ready） |
| `lomiri-location-service` | SEGV | **仍然 SEGV** |
| `biometryd` | SEGV | **仍然 SEGV** |

前四个是干净的胜利：**垫片只做一件事（填 TP+8），它一加上去服务就活了，这就是"死因是 TLS 槽"的证明。** 后两个还崩，说明它们死在更后面的地方 —— 挂着，需要 core，不能猜（`40` 的教训）。

## 3. 顺带看出来的：显示电源链路是通的

`repowerd` 一起来，背光**从 128 掉到了 0**。原因不是坏了，是这条链路终于活了：Lomiri → repowerd → Android 电源 HAL → 背光。没有触摸输入，它按空闲超时把屏幕关了 —— 这正是手机该有的行为，而在这之前 `repowerd` 根本没跑，所以背光一直是死钉在 128。

`echo 128 > /sys/class/leds/lcd-backlight/brightness` 之后它**稳住了 40 秒以上**（repowerd 没有把它再关掉），所以那是一次空闲超时，不是抖动。

**但这也意味着一个前提被暴露了：** 现在要靠"有人摸屏幕"才能唤醒，而触摸还没验证过。所以"屏幕亮着"这件事在无人值守的测试里是不稳定的 —— 这不是故障，是缺一次真实触摸。

## 4. `install-system-tls-preload.sh`

手工列七个 service 会过期，所以做成脚本，规则有两条：

1. **扫**：`systemctl show -p ExecStart` 拿到可执行文件，`grep -qa libhybris` 命中就加。这一条会**多抓**（snapd 的二进制里有 libhybris 的 soname 字符串，它其实不需要垫片 —— 多装一份无害），也会**漏抓**。
2. **补**：`sensorfwd`、`urfkill`、`hfd-service`、`lomiri-location-service`、`biometryd` 的可执行文件里**根本没有 `libhybris` 这个字符串**（它们的 Android 侧是运行时插件），扫描看不见。它们是靠"崩了"被找到的，所以写死在 `EXTRA_UNITS` 里。

两条合起来现在写 12 份 drop-in。`--remove` 全拆，`--status` 列出来并且顺带报 `systemctl --failed`。

## 5. 还没证实 / 下一步

- **`lomiri-location-service` 和 `biometryd` 为什么加了垫片还崩。** 要用 `hybris-crash-hunt.sh` 抓 core 看 PC 是不是还落在 `__ctype_get_mb_cur_max+8`，还是挪到别处了。不猜。
- **`sensorfwd` 卡在哪。** 不崩了但 `activating`，看起来是没进 ready 状态（Type=dbus/notify 的握手），要单独看。
- **Wi-Fi。** 没有 `wlan0`、没有无线模块、固件只在 `/vendor/firmware_mnt/image/bdwlan30.b0*`。要搞清楚这个内核有没有 `wcnss` 驱动、需不需要把固件摆到 `/lib/firmware`。
- **音频。** ALSA 卡片在，`pulseaudio` 没起（它是 user unit）；`audiosystem-passthrough-qti.service` 还在失败列表里。
- **触摸。** 8 个 event 节点都枚举到了，缺一次真实触摸。而且现在背光熄灭要靠触摸唤醒，所以这一条同时也是"屏幕能稳定亮着"的前提。
- **`update-machine-info-from-deviceinfo.service`** 也在失败列表里（一个改 hostname 的小服务），没看。
- 这一篇的所有改动都是**宿主侧、写在可写路径上的**：drop-in 在 `/etc/systemd/system`，垫片本体是 bind mount（`install-tlsfix.sh --mount`，`47` 的 `zl1-host-fix.service` 每次开机重装）。没有碰任何分区。
