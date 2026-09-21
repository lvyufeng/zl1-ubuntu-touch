# 61 — 音频其实一直是好的：`pulseaudio` 是 **user** unit，而且它跑在宿主命名空间里也能用

**日期**: 2026-09-21
**状态**: **更正记录**。之前的笔记写着"`pulseaudio` inactive、音频没起来"，那是**查错了名字** —— `pulseaudio` 在这个 rootfs 上是 **user unit**（`/usr/lib/systemd/user/pulseaudio.service`），`systemctl is-active pulseaudio` 问的是系统 unit，当然不存在。真实的它是 **active**，卡 `droid_card.primary`，端口齐全。这一篇把测到的东西记下来，并说明**哪一步我没法远程证明**（我听不见扬声器）。
**接续**: [`48`](48-the-tls-fault-was-killing-seven-system-services.md)、[`58`](58-one-cold-boot-where-the-secure-world-refused-and-three-firmwares-did-not-load.md)（`58` 把"音频没起来"归给 `adsp` 没加载 —— 那是一条**真的**故障路径，但不是**这条**）

---

## 1. 先更正：`pulseaudio` 不是系统服务

```
$ systemctl is-active pulseaudio            -> inactive   (单位不存在)
$ systemctl --user -M '32011@' is-active pulseaudio  -> active
$ pgrep -a pulseaudio
  52730 /usr/bin/pulseaudio --daemonize=no --log-target=journal
```

`/usr/lib/systemd/user/pulseaudio.service`、`pulseaudio.socket`、`pulseaudio-x11.service` 都在 user 目录下。`pactl info` 也确认它在跑：

```
Server String: /run/user/32011/pulse/native
Server Name: pulseaudio        Server Version: 16.1
Default Sink: sink.primary_output
Default Source: source.droid
```

所以"音频 inactive"是**测量错误**，不是设备状态。凡是这个 rootfs 上的音频判断，都得用 `systemctl --user -M '32011@'` 或者 `pgrep`/`pactl`，不能用 `systemctl is-active <name>`。

## 2. 声卡和端口都在

```
$ cat /proc/asound/cards
 0 [msm8996tashamtp]: msm8996-tasha-m - msm8996-tasha-mtp-snd-card
```

`pactl list cards` 里 `droid_card.primary`（`module-droid-card.c`，`droid.hw_module = "primary"`）的端口清单是完整的，而且 **available 状态是真的**：

| 端口 | available |
| --- | --- |
| `output-speaker` | **available**（当前 Active Port） |
| `output-earpiece` | available |
| `output-wired_headset` / `output-wired_headphone` | **not available**（没插东西，正确） |
| `input-builtin_mic` | available |
| `input-wired_headset` | not available（同上） |
| `output-bluetooth_sco`、`output-sco_headset`、`output-aux_digital`、`output-line`、`output-fm`、`output-proxy` | available |

加载的模块里，`module-droid-hidl`、`module-droid-card-28`、`module-droid-discover` 就是 halium 的 droid 音频桥；`module-bluez5-discover`（`profile=a2dp_sink`）也在。

## 3. 播一段测试音：**sink 从 SUSPENDED 变成 RUNNING**

在设备上生成 1 秒 440 Hz 的 wav，用会话用户的 `paplay` 播，播放期间采样 sink 状态：

```
生成        /tmp/zl1-tone.wav  (176444 字节，44100 Hz 立体声)
Active Port output-speaker
播放前      sink.primary_output   SUSPENDED
播放中 t=1  sink.primary_output   RUNNING
        t=2  sink.primary_output   RUNNING
        t=3  sink.primary_output   IDLE      <- 播完了
paplay exit=0，没有任何输出（也就是没有报错）
pulseaudio journal 里没有任何新行
```

**这条链是通到 HAL 的**：`sink.primary_output` 挂在 `module-droid-card.c` 上，`RUNNING` 意味着 pulseaudio 把 44100 Hz 立体声样本交给了**进程内的 Android 音频 HAL**（`/vendor/lib64/hw/audio.primary.msm8996.so`），而它把 `paplay` 那 1 秒全部收下了、没有报错。往下就是 ASM/ADSP 到扬声器。

**我没法远程证明扬声器真的响了。** 这一步和 `52` 的图形界面一样，要**耳朵确认**：如果你在设备上（或者稍后在设备上）听到一声 440 Hz 的短音，那音频就整条通了；如果没听到，那问题在 HAL 之后的 ADSP/ASM 路由，不在 pulseaudio 这一层 —— 这一篇的结论只到"pulseaudio 和它的 sink 是好的、样本交给 HAL 成功了"。

## 4. 一个和 `56`/`60` 相反的结论：**音频不需要搬进容器的 PID 命名空间**

`pulseaudio` 跑在**宿主** PID 命名空间（`pid:[4026531836]`，初始命名空间），而它工作正常。原因是它走的路不一样：

- `module-droid-card-28` 是**进程内**通过 libhybris 的 `hw_get_module("audio")` 把 `/vendor/lib64/hw/audio.primary.msm8996.so` **dlopen 进自己进程**直接调用 —— 不经过 binder，所以 PID 命名空间无关。
- 对照：`android.hardware.audio@4.0::IDevicesFactory/default` **确实**在容器里注册着（`lshal` 有），`module-droid-hidl` 也存在；但真正干活的是前者那条路。

**所以规则不是"所有跟 Android 打交道的服务都搬过去"**，而是：**只要那条路经过 binder/hwbinder 才要搬**。判据很简单 —— `grep -a libgbinder <binary>`，或者看 `/proc/<pid>/maps`。已经搬过去的四个（`lomiri-location-service`、`biometryd`、`sensorfwd`、`bluebinder`）都链接 `libgbinder`；`pulseaudio` 不链接。

## 5. `58` 那条线的位置

`58` 说 `adsp: Invalid firmware metadata` → `pulseaudio` 起不来，把它和"显示、sensorfwd"并列成一次坏启动的三个后果。那一篇的**因果本身没错**，但需要补一句限定：**在 firmware 正常的启动里**（比如这次），`adsp` 是加载成功的（`adsp: loading from ...` / `Brought out of reset` / `Power/Clock ready interrupt received`），而音频仍然是好的 —— 也就是说音频从来没有第二种故障。本次开机复核：`pulseaudio` active、2 个 sink、测试音能播。

坏启动里音频会跟着一起没了，这一点不变；`install-kmsg-drain.sh --bad` 现在会直接报那种启动的签名。

## 6. 这一段改了哪些东西

**设备上什么都没改。** 这一篇从头到尾是读和测：`systemctl --user -M`、`pactl info/list`、`paplay` 一段本地生成的 wav、以及归档里的开机日志。测试文件 `/tmp/zl1-tone.wav` 留在设备上（`/tmp` 不是持久的，下次开机就没了）。
