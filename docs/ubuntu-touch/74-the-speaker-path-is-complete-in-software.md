# 74 — 扬声器这条链在软件层已经是**完整且可验证**的：pulseaudio → droid sink（端口就是 `output-speaker`）→ 容器里 HAL 选 `speaker-stereo` → `TERT_MI2S_RX`（三级 MI2S，即**外部 smart PA**，不是内部 WCD9335）→ codec 的功放控制全部被置成出声的值；**能不能听见只剩用户的耳朵**

**日期**: 2026-09-22
**状态**: **软件链每一环都量到了，没有一环是坏的或缺的。** 用户要的"让扬声器真的出声"，从软件能做的部分已经做完了；剩下的是一个**耳朵问题**（外置智能功放的供电/I2C/固件在软件这一侧看不见，而本机的内核日志不落盘）。同时把一件容易误判的事写下来：**用 440 Hz 的弱音试听在手机小喇叭上本来就几乎听不见**，那不是故障证据。

**接续**: [`72`](72-the-heat-was-the-governor-and-a-debug-keeper.md)（同一批 `/proc`、`/sys` 的测量习惯）、[`71`](71-the-sensors-stream-the-restart-kills-the-hal.md)（**"要进容器命名空间"只对 sensors 成立，音频不是** —— 见 §5）

---

## 1. 起点：pulseaudio 已经指向扬声器，而且没静音

```
$ pactl list short sinks            # 以 phablet 身份，XDG_RUNTIME_DIR=/run/user/32011
0  sink.fake.sco        module-null-sink.c   s16le 1ch 8000Hz   SUSPENDED
1  sink.primary_output  module-droid-card.c  s16le 2ch 44100Hz  SUSPENDED     <- 默认 sink
   Active Port: output-speaker    Mute: no    Volume: 65536 / 100% / 0.00 dB
```

`pactl list short modules` 里和音频有关的是 `module-droid-discover`、`module-droid-card-28`、`module-droid-hidl`（都是 `helper=false`，这个 port 的输出路径不走 `audiosystem-passthrough` 那个 helper 进程）。**一张 droid 卡、一个输出、活动端口已经是 `output-speaker`、未静音、音量 100%** —— 没有需要改的配置。

## 2. 放音时，容器里的 HAL 把路走对了

`paplay --device=sink.primary_output` 放一段 12 秒的测试音，sink 立刻 `RUNNING`。同一时刻容器 logcat 里 `audio_hw_primary` 每次播放稳定输出这五行：

```
start_output_stream: enter: stream(0x5f2b556090) usecase(1: low-latency-playback) devices(0x2)
select_devices: out_snd_device(2: speaker-stereo) in_snd_device(0: )
enable_snd_device: snd_device(2: speaker-stereo)
enable_audio_route: apply mixer and update path: low-latency-playback smartpa
start_output_stream: exit
```

`devices(0x2)` 就是 `AUDIO_DEVICE_OUT_SPEAKER`，`speaker-stereo` 就是扬声器 **snd_device**，而 mixer path 的名字直接叫 **`low-latency-playback smartpa`** —— 说明 HAL 自己知道这块板的扬声器走的是**智能功放**。停止时对应地 `disable_audio_route: reset … smartpa` / `disable_snd_device`。**没有错误，没有回退，没有选到别的设备。**

## 3. 功放确实被"拧开"过：播放中 vs 空闲两组 codec 读数

读取工具是 `/system/bin/tinymix`（§5 说明为什么不是 `amixer`）：

| 控制项 | 播放中 | 空闲 |
|---|---|---|
| `TERT_MI2S_RX Audio Mixer MultiMedia5` | **On** | Off |
| `Speaker Volume` | **5** | 1 |
| `Digital Gain` | **56** | 40 |
| `Boost Output Voltage` | **9V** | 6.5V |
| `Left / Right Channel Enable` | **On / On** | Off / Off |
| `Left / Right Feedback Enable` | ON / ON | ON / ON |
| `AIF4_VI Mixer SPKR_VI_1 / _2` | Off | Off |

**这两列的差本身就是证据**：`/vendor/etc/mixer_paths_tasha.xml` 里 `speaker` 这条 path 写的就是这组播放值（`Boost Output Voltage=9V`、`Speaker Volume=5`、`Digital Gain=56`、两个 `Channel Enable=1`），而 HAL 在 `enable_audio_route` 时应用它、在 standby 时撤掉它 —— 读数正好一升一降。

后端是 **`TERT_MI2S_RX`**（三级 MI2S），不是内部 codec 的 `SLIMBUS_0_RX`：这颗 SoC 把音频从 MI2S 送出去给**外置智能功放**，所以"没有声音"如果要归因，也**不可能**是 pulseaudio/HAL 这一侧的选择问题。

唯一没被解释的是 `SPKR_VI_1/2`（功放的电压/电流回sense 进 codec，用于喇叭保护）两列都是 `Off`。**它是不是出声的必要条件，这次没有验证**，写下来。

## 4. 数字通路一直走到 SoC 的 DMA

播放中全机只有一个 host PCM 在跑：

```
/proc/asound/card0/pcm15p/sub0/status: state: RUNNING
```

`aplay -l` 里 **device 15 = MultiMedia5**，正是 §3 那行 `TERT_MI2S_RX Audio Mixer MultiMedia5 = On` 对应的 PCM。**所以数据真的进了 MI2S 的 DMA，不只是"HAL 以为它放了"。**

## 5. 一个工具坑（和一条和 sensors 相反的结论）：读 codec **不需要**进容器的 PID 命名空间

```
$ amixer -c 0 scontrols        -> amixer: Mixer sysdefault:0 load error: No such device
$ amixer -D hw:0 scontrols     -> amixer: Mixer hw:0 load error: No such device
$ amixer -c 0 info             -> Card sysdefault:0 'msm8996tashamtp'   Mixer name : ''
$ /system/bin/tinymix          -> Mixer name: 'msm8996-tasha-mtp-snd-card'  Number of controls: 2392
```

差别在**工具**，不在命名空间：Halium 把 `/system` 软链到 `/android/system`，Android 的 `tinymix` **直接在 host 上就能跑**（本节的读数全部是这么取的，没有用 `nsenter`）。而这台设备的 host `amixer` 打不开这张卡的 mixer —— **谁在这里伸手去拿 `amixer`，都会错误地得出"codec 不存在"的结论。**

> 对照 [记忆里 binder/命名空间那条](../../README.md)：sensors HAL 必须进容器的 PID 命名空间才看得见，音频**不需要**。两条都是实测，别互相套用。

## 6. 顺便撞上的：一颗随网络流量冒出来的内核 WARN（在 USB RNDIS 的发送完成路径上）

测音频的过程中 `dmesg` 里出现了大量 backtrace，解出来是：

```
WARNING: CPU: 1 PID: 8 at net/core/skbuff.c:616 skb_release_head_state+0x74/0xdc()
Call trace: skb_release_head_state <- __kfree_skb <- kfree_skb <- tx_complete
            <- usb_gadget_giveback_request <- dwc3_gadget_giveback
            <- dwc3_endpoint_transfer_complete <- dwc3_interrupt
```

也就是**USB gadget 的 RNDIS 发送完成**里释放了一个带 destructor（来自 socket）的 skb，而 `skbuff.c:616` 那句正是 `WARN_ON(in_irq())`：它在中断上下文里释放了本不该在这里释放的 skb。**这是这台 port 网络路径上一个真实的 bug，但不是致命的**（WARN 不会停机，网络照常工作 —— 我们全程的 SSH 就是走这条路）。

频率量了一下，**和流量形状有关，和字节数关系不大**：

| 场景 | 新增 WARN |
|---|---|
| 空闲 20 秒 / 60 秒 | ~1 / ~1 |
| 一次 20 MB 批量传输（设备→主机） | 0–6 |
| 300 次小命令往返 | +1 |
| 我连续 dump 大段日志（`dmesg \| grep`，几百 KB 的**突发小块**输出） | 一次 30 秒的 ring 里灌进 **134 行** |

**注意 ring 只留得住约 30 秒**（这次实测 12751 → 12784 就翻篇了），所以"134 行"是**一次突发**的下限，不是长期速率。active console 是 `tty0`（fbcon），`printk` 的 console loglevel 是 4 —— 也就是这些 trace 会被**画到帧缓冲控制台上**，在突发时是有代价的。想做实验的话 `/proc/sys/kernel/printk` 的 console loglevel 是可以调的（ring 里照样留全，只影响往 console 画），但这**没有改**，因为它是可逆性不明的一个额外变量，而当前收益也不明确。

## 7. 还差什么

**只差一件事：耳朵。** 上面每一步都证明"软件让它响了"，没有任何一步能证明"它真的响了"。

试听用的音是**两次**：先是 440 Hz、幅度 12000/32767（**这是我自己设的坑：手机小喇叭在 440 Hz 上效率极低，"听不见"不能当故障证据**），然后是 1.8 kHz / 2.4 kHz 的短促 beep、幅度 30000（这才是有效的试听信号）。

- **听得见** → 音频这一环结束，软件链完整，不需要改任何东西；
- **听不见** → 嫌疑人全部在 codec **下游**，且都在这个软件路径之外：外置 smart PA 的供电使能、它的 I2C 探测/配置、或它的固件。要查这个得看**开机时的内核日志**，而这台设备的内核日志**不落盘**（`journalctl -k -b` → `-- No entries --`，ring 只留 ~1 分钟），所以必须在一次开机里抓。

## 8. 文件与复现

| 文件 | 作用 |
|---|---|
| `scripts/device/zl1-audio-test.sh` | 在设备上跑。`--seconds/--hz/--amp/--sink` 放一段可控的音，放音**中**读一次 codec、放音**后**再读一次，并报告 sink 状态与正在跑的 host PCM。`--status` 只读。判读方式写在脚本头部：sink `RUNNING` 而 codec 没被配置 = 问题在 HAL 以上；codec 被配置成 §3 那组值 = 软件侧已经做完，静音只可能在下游 |
| `docs/ubuntu-touch/evidence/audio-path-2026-09-22.log` | 本次全部原始读数：sink/module 表、HAL 五行、两组 tinymix 对照、RUNNING 的 PCM、启动时 `backend_tag_table[speaker] → smartpa` 与 `MTP_Speaker_cal.acdb` 加载、`amixer` vs `tinymix` 的对照 |

```sh
# 在设备上（脚本在 /userdata/，从主机 scp 过去）
sh /userdata/zl1-audio-test.sh --seconds 12 --hz 1800 --amp 30000
# 只读地看现在是什么状态
sh /userdata/zl1-audio-test.sh --status
# 关键的一次对照：播放中再读一遍 codec（另一个终端）
/system/bin/tinymix | grep -iE 'MultiMedia5|Speaker Volume|Boost Output Voltage|Channel Enable'
```

**设备安全**：只往 `/userdata/`（测试音、脚本）和 `/tmp` 写。只读地看 `/proc/asound`、`/sys`、`/dev/snd`、容器 logcat、`/vendor/etc`。改变设备状态的动作只有"通过正常的 pulseaudio 路径放音"这一件，没有改任何 mixer 值（§3 两组读数都是**读**出来的，不是写进去的）、没有改 `/etc/pulse`、没有碰容器。容器 RUNNING，`systemctl --failed` 空，SSH 正常。
