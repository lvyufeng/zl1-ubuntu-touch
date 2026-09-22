# 68 — 出图这条路上最后一个 bug 在 stub 里（`getToken` 的 cookie）；`67` 那串 `-32` 是客户端的尸体

**日期**: 2026-09-22
**状态**: **相机链路整条通了，而且是稳态的：`/usr/bin/test_camera` 在 60 秒里连续出 2173 帧（约 35 fps），cameraserver 一条 `Camera3-OutputStream` / `E/Surface` / `notifyError` 都不打，dmesg 里一条 binder 消息都没有。** 挡住最后这一段的不是 HAL、不是 buffer 队列、也不是 `67` 说的"预览流的 native window 一上来就是死的" —— 是 **stub 自己**：它回答 `IAppOpsService.getToken` 时，`flat_binder_object` 里带的 cookie 和 `addService` 注册的那个不一样，内核按不变量把**整条回复**判成了 `-EINVAL`（`BR_FAILED_REPLY`），于是 cameraserver 的 `AppOpsManager::getToken()` 从来没拿到过 token。修掉之后 `67` 里那串 `-32` 全部消失。
**同时定案了三件事**：`67` 那串 `-32` 是**客户端已经死了之后**的日志（这次故意 `kill -9` 逐行复现）；`/dev/fb0` 不是扫描缓冲（把显示器用 DBus 强行打开、`ActiveOutputs` 从 0 变 1，fb0 仍然逐字节相同），所以它不能当截图源；app 自己的帧率**与显示器电源无关**（关/开/关/开来回切，帧率一直是 35 fps），所以"帧率"单独不能当"出图"的证据 —— 能当证据的是**合成器的 CPU**。
**接续**: [`67`](67-the-preview-started-it-was-a-sched-fifo-request.md)、[`66`](66-the-input-layer-vendor-symbol-was-libinputservice.md)、[`65`](65-the-camera-was-blocked-on-four-system-server-services.md)
**后续**: 现在挡在"看见预览"上的是**输入**（手机停在锁屏 greeter，解不开就没人能看见任何窗口），见 §7；输入这件事同时是用户报的"返回键不能用"。

---

## 1. `67` 的结论：一半对，一半是现场读错了

`67` 第 7 节说"预览流（stream 0）的 native window 一上来就是死的"，依据是同一次运行里这几行：

```
E/Camera3-OutputStream: getBufferLockedCommon: Stream 0: Can't dequeue next output buffer: Broken pipe (-32)
E/Surface: queueBuffer: error queuing buffer to SurfaceTexture, -32
W/Camera3-OutputStream: disconnectLocked: While disconnecting stream 0 from native window, the native window died from under us
```

这一次把它当成一个**可重复的现象**去量：干净的现场（`camera-stack-reset.sh` 之后）跑预览，然后：

```
== [BEFORE the kill] the doc-67 signature, verbatim:
   --- (end)                                  <- 一条都没有
== SIGKILL the client
02-10 12:41:16.825 E/Surface (38583): queueBuffer: error queuing buffer to SurfaceTexture, -32
02-10 12:41:16.825 E/Camera3-OutputStream(38583): returnBufferCheckedLocked: Stream 0: Error queueing buffer to native window: Broken pipe (-32)
02-10 12:41:16.825 E/Camera2Client(38583): notifyError: Error condition 0 reported by HAL, requestId -1
02-10 12:41:17.007 E/QCamera (38400): <HAL><ERROR> notifyErrorForPendingRequests: 10318: Sending ERROR REQUEST for all pending requests
02-10 12:41:17.008 W/Camera3-OutputStream(38583): returnBufferCheckedLocked: A frame is dropped for stream 3 due to buffer error.
02-10 12:41:17.150 W/Camera3-OutputStream(38583): disconnectLocked: While disconnecting stream 0 from native window, the native window died from under us
02-10 12:41:23.806 I/Camera2ClientBase(38583): Closed Camera 1. Client was: hybris (PID 38605, UID 0)
```

**逐行对上，顺序也一样。** 这意味着那串日志的**因**是"消费者没了"：stream 0 的 native window 是**客户端进程里的 BufferQueue**（hybris 的 `android_camera_set_preview_texture()` 造出来，producer 交给 cameraserver），客户端一死，producer 的 `queueBuffer` 拿到 EPIPE（`-32`）。所以 `67` 第 7 节里"一上来就是死的"是**读了一份上一个客户端留下来的状态**（那次会话的 cameraserver 是上一轮留下的）。`66` 第 6 节那条 `error_code = 0` 也就跟着降到"下游的下游"。

> 一句话：`-32` 是**尸检报告**，不是死因。要判"现在还有没有图"，不能看这串；要看帧计数（§4）和合成器（§5）。

## 2. 真正挡住最后一段的 bug：`getToken` 回答里的 cookie 和注册的不是一个

`service-stub` 注册 `appops` 时用的是表里的 `{ptr 0x5e21, cookie COOKIE_APPOPS = 0x5ea2}`，但 `serve_appops` 的 `code == 7`（`getToken`）分支里**手写了一个长得像 ptr 的常数**当 cookie：

```c
if (code == 7) { /* getToken -> an IBinder of our own */
  p_fbo(p, 0x5e21, 0x5e22);          /* 0x5e22 = 0x5e21 + 1，看着像，但它不是注册时那个 */
}
```

这不是风格问题，是**驱动的不变量**：`binder_translate_binder()`（`drivers/android/binder.c`）按 `flat_binder_object->binder` 这个指针**找节点**，找到节点之后要求 `cookie` 与注册时一致，不一致就返回 `-EINVAL`，整条事务被 `BR_FAILED_REPLY` 否掉。dmesg（要开 `BINDER_DEBUG_USER_ERROR`/`FailedTransaction`）里是这三行：

```
binder: 1363507:1363507 sending u0000000000005e21 node 1069323, cookie mismatch 0000000000005e22 != 0000000000005ea2
binder: 1363507:1363507 transaction failed 29201/-22, size 28-8 line 3211
binder: send failed reply for transaction 1186067 to 1362231:1362261
```

`size 28-8` 就是这个 reply 的 parcel（4 字节 `writeNoException` + 一个 24 字节的 `flat_binder_object`，8 字节 offset），`1186067` 是那条 `getToken`，收件人 `1362231:1362261` 是 cameraserver 里调 `getToken` 的线程。

### 为什么它比看上去严重

`AppOpsManager::getToken()`（`frameworks/native/libs/binder/AppOpsManager.cpp:43`）把结果缓存在 `gToken` 里，之后每一次 `startOperation`/`finishOperation` 都把它当 token 传回来。token 是空的话，`appops` 事务照样到 stub、stub 照样回 `MODE_ALLOWED`，**没有任何一条日志说不对** —— stub 侧"成功写好了回复"，内核在出口上把它扔了。这就是为什么这个 bug 能在四轮会话里活着：**双方都认为自己正常**。

修法是把那个常数换成表里那一个（`p_fbo(p, 0x5e21, COOKIE_APPOPS)`），并把不变量写在表上面（`service-stub.c` 里那段注释就是上面这份证据）。验收是同一次运行的三个信号：

```
--- the appops/getToken transactions the stub saw:
fwsvc[38019] transaction for appops code 5 size 136 from pid 38008 uid 1047   (startWatchingMode)
fwsvc[38019] transaction for appops code 7 size 112 from pid 38008 uid 1047   (getToken)
fwsvc[38019] transaction for appops code 3 size 144 from pid 38008 uid 1047   (startOperation)
--- dmesg (should be empty of binder errors):
   (no binder messages)
--- camera3 errors:
```

## 3. 稳态：60 秒 2173 帧

干净现场，`test_camera` 以 `setsid nohup ... stdbuf -oL` 起（**必须脱离启动它的 ssh**，见 §7 的坑），每 5 秒采一次：

```
   start    pid=1999258  frames/deq=?          backlight=0 fb0=ee941c89
   +5s      pid=1999258  frames/deq=231        backlight=0 fb0=ee941c89
   +15s     pid=1999258  frames/deq=588        backlight=0 fb0=ee941c89
   +30s     pid=1999258  frames/deq=1118       backlight=0 fb0=ee941c89
   +45s     pid=1999258  frames/deq=1647       backlight=0 fb0=ee941c89
   +60s     pid=1999258  frames/deq=2173       backlight=0 fb0=ee941c89
```

单调、线性、约 35 fps（`(2173-231)/55 = 35.3`），和客户端自己请求的 30 fps 一致（略高是因为 stream 的 rate 是按 HAL 的实际节拍算的）。另外三次同形状的运行：`577 / 20 s`（≈28 fps）、`258 / 9 s`、`593 / 20 s`。**没有任何一次出现 `Camera3-OutputStream`、`E/Surface`、`notifyError`，也没有一条 binder dmesg。**

## 4. `backlight=0`、`fb0` 一动不动 —— 这两个都不是"没出图"的证据

上面那张表里 `backlight=0`（`/sys/class/leds/lcd-backlight/brightness`）看起来像"屏是黑的"，`fb0` 的 md5 `ee941c89…` 从几个小时前到现在**没变过**。这两条都要按下面的测量读，否则会把"屏没亮"当成"没画"。

### 4.1 fb0 不是扫描缓冲，别拿它截图

`fbset -i` 说它是真的显示器（`mode "1080x1920-57"`、`geometry 1080 1920 1080 3840 32`、`LineLength 4352`、`rgba 8/0,8/8,8/16,8/24`），而且**合成器确实握着它**：

```
53372 lomiri-system-c -> /dev/fb0            （主机侧合成器）
52177 composer@2.1-se -> /dev/graphics/fb0   （容器里的 HWC，同一个设备）
```

但合成器的扫描输出**不经过 fb0 里的那份内存**。判据是把显示器打开再量：合成器自己的 DBus 接口可以开关显示器

```
busctl --system call com.lomiri.SystemCompositor.Display /com/lomiri/SystemCompositor/Display \
  com.lomiri.SystemCompositor.Display TurnOn s "zl1-diag"
```

`ActiveOutputs` 属性 `(ii)` 从 `0 0` 变成 `1 0`、`TurnOff` 再变回 `0 0` —— 也就是说**输出真的被激活了**，而同一时刻 fb0 的 md5 还是 `ee941c89…`，前后 3 次采样一模一样。结论：**fb0 是这块屏的"遗留 framebuffer"，不是当前扫描输出的那份内存；截图必须另找路子**（合成器的 snapshot、或者人眼看）。

### 4.2 帧率也不证明"到了屏上"

`test_camera` 的 GL 循环是 `... eglSwapBuffers(); wl_display_dispatch();`，所以"帧率"看起来像被合成器节流的结果 —— 但是在**显示器电源来回切换**的同时量它：

```
--- phase 1: display OFF    frames=155 → 344 → 529      (~37 fps)
--- phase 2: TurnOn         frames=730 → 981 → 1151     (~42 fps)
--- phase 3: TurnOff again  frames=1338 → 1519 → 1710   (~37 fps)
--- phase 4: TurnOn again   frames=1992 → 2157 → 2327   (~34 fps)
```

**完全无关。** 客户端在按自己的钟跑（Mir 对场景里的 surface 都会发 frame callback，不管有没有活动输出）。所以"35 fps 稳定"只能证明**相机 + app 侧**是好的，不能证明任何东西到了显示器。

## 5. 能证明"帧到了合成器"的是合成器自己的 CPU

判据换一个：Mir **按 damage 渲染**，所以"有没有东西要画"能直接从合成器的 CPU 时间里看出来（`/proc/<pid>/stat` 的 utime+stime，字段 14+15；pid 用 `ps` 取，**这台设备上 `pgrep -f` 不可靠**，`pgrep -f "lomiri-system-compositor --enable"` 什么都匹配不到）：

| 状态 | 合成器 (ticks/s) | shell `lomiri` (ticks/s) |
|---|---|---|
| 显示器 ON，没有客户端 | **1.2** | 1.2 |
| 显示器 ON，预览在跑 | **27.8**（另一次 33–50） | 43 |
| 显示器 OFF，预览在跑 | 4.8 | 38–48 |

也就是：**显示器开着、没人有 damage 的时候，合成器基本不干活（1.2/s）；同样的显示器、同一个合成器，预览一起来就变成 28–50/s —— 它在合成这个客户端的帧。** 关掉显示器又掉回 ~6/s（Mir 没有活动输出就不画）。

这条路也把 §4.2 的坑绕过去了：**不要用 app 的帧率当证据，要用合成器的 CPU**。它同时解释了一件看起来无关的事：shell（`lomiri`）在预览期间一直烧 40+ ticks/s，无论显示器开关 —— greeter 自己在动画，不是我们的路径。

## 6. 于是"看见预览"现在只差一个前提：把锁屏解开

`lomiri` 是以 `--mode=full-greeter` 起的：**这台手机停在 greeter（锁屏）**，整个屏幕被它盖住，任何非 UT 应用的窗口都不可能露出来。要看见预览，得先在手机上划开锁屏 —— 而这需要**触摸输入**工作。

输入这一侧的测量：

- 内核有 8 个 input 设备：`event0 qpnp_pon`（电源键）、`event1` HDMI CEC、**`event2 qbt1000_key_input`（电容键，返回键在这上面）**、`event3 synaptics_dsx`（触摸屏，`properties=2` = `INPUT_PROP_DIRECT`）、`event4 hbtp_vm`、`event5 gpio-keys`、`event6/7` 耳机。主机侧的 `lomiri` 把 event0–7 全开着，有 7 个 `Mir/Input Reader` 线程（一个在 `ppoll` 里等事件），`lomiri-system-compositor` 开着 event0–5、7，`systemd-logind` 开着 event0–2，`repowerd` 则**一个 input 设备都没开**（它靠 DBus/logind 知道"有人在动"）。
- `qbt1000_key_input` 的键位图是**坏的**：`/sys/class/input/event2/device/capabilities/key` = `400 0 fefefefefefefefe …` —— 交替位的垃圾值，解出来是一堆 `KEY_0…KEY_62`，**里面没有 `KEY_BACK`(158)**。这个设备的身份也是占位的（`bustype 0x19 vendor 0x0001 product 0x0001`，`/sys/devices/virtual/input/input2`）。这条与用户报的"返回键不能用"直接相关，但**还需要人按一下**才能分开是"硬件不报"还是"报上来没人认"（见 §7）。
- **uinput 能用**（`/dev/uinput` 在，脚本起来后 `/sys/class/input` 里真的出现 `event8 = zl1-diag-touch` / `event9 = zl1-diag-keys`），**但注入打不到 GUI 上**：`--keep-seconds 18` 拿着设备的那 18 秒里，`lomiri`、`lomiri-system-compositor`、Mir **没有任何一个进程打开 event8/9**——也就是说**这台设备的合成器不给"启动之后才出现的输入设备"热插拔**（它开机时把所有 event* 打开，之后不再枚举）。同一时间 `dbus-monitor` 在系统总线上一行都没有（tap 之后合成器没有把"有人动过"告诉 repowerd）。
  - 所以 `scripts/device/zl1-inject-input.py` 现在只能测**内核那一半**（事件本身是合法 evdev 事件），测不到合成器那一半。**这是负结果，不是失败**：它说明"注入一个虚拟触摸屏来驱动 GUI"这条路在合成器不热插拔的前提下走不通，除非重启合成器（那是拿 GUI 冒险，不做）。

## 7. 还差一个人：两个只有手能做到的测量

这一节是留给下一次的，写清楚是为了不用重新想：

1. **返回键到底哪一段断的**。设备上放一个 watcher（8 个设备都不 grab，记所有事件到 `/userdata/zl1-input-watch.log`），然后请人在手机上按几次返回键、电源键、摸一下屏：
   - watcher 里**有** `event2` 的事件 → 硬件和驱动在报，断点在"报上来没人认"（很可能就是那张垃圾键位图，或者 Mir/repowerd 没把它当活动）；
   - watcher 里**没有**任何事件 → 断点在更下面（qbt1000 驱动没接中断；`/proc/interrupts` 里连一条 qbt 的行都没有）。
   顺带的判据：`lcd-backlight` 的亮度会不会因为按键/触摸而上去 —— 屏被 repowerd 关了，而**能把它点亮的输入就是"输入通了"**。
2. **预览是不是真的在屏上**。前提是先解锁（第 1 条通了才谈得上）。解不解得开，本身就是"GUI 能不能用"的答案；解开之后跑预览，合成器 CPU 那条链（§5）加上眼睛，就是端到端的证据。

## 8. 文件与复现

| 文件 | 作用 |
|---|---|
| `scripts/android-fw-stubs/service-stub.c` | 这次的修：`getToken` 的 cookie 用表里的 `COOKIE_APPOPS`；表上面写了不变量和 dmesg 证据 |
| `scripts/device/zl1-inject-input.py` | 新：uinput 注入（tap/swipe/key），测"内核那一半"的工具；头部记了它测不到合成器那一半这件事 |

```sh
scripts/android-fw-stubs/build.sh                                  # 重新构建（sha256 会打出来）
scripts/android-fw-stubs/run-on-device.sh                          # 部署 + 起五个名字
scripts/android-fw-stubs/camera-stack-reset.sh                     # provider → cameraserver → 枚举 → 用户切换
# 起客户端：必须 setsid nohup 脱离 ssh，且加 stdbuf -oL（否则 out 是块缓冲，读不到进度）
scripts/android-fw-stubs/run-camera-test.sh --line-buffered --timeout 90
```

显示器开关（这次新找到的、可逆的杠杆）：

```sh
busctl --system call com.lomiri.SystemCompositor.Display /com/lomiri/SystemCompositor/Display \
  com.lomiri.SystemCompositor.Display TurnOn  s "zl1-diag"
busctl --system call com.lomiri.SystemCompositor.Display /com/lomiri/SystemCompositor/Display \
  com.lomiri.SystemCompositor.Display TurnOff s "zl1-diag"
```

**设备安全**：只写 `/userdata/`（stub、`zl1-camera/`、新的 `zl1-inject-input.py`、`zl1-cpu.sh`），只读地看 `/proc`、`/sys`、binder debugfs、`/dev/fb0`；重启过 cameraserver 与 camera provider（init 托管的运行时服务，重启即恢复）。显示器电源用 DBus 开关过几次，每次都回到 `ActiveOutputs = 0 0`（发现时的状态）。backlight 亮度节点被直接写过一次（200），这是它自己的节点、是 LED 语义，没碰任何分区、没动 boot 镜像、没改容器内文件。设备没有变砖。

## 9. 下一步

1. **输入**（现在是关键路径）：按 §7 第 1 条，watcher + 一只手，把"返回键"断在哪一段分开；同时它决定手机能不能解锁。
2. 解开锁屏之后跑一次预览，用 §5 的合成器 CPU + 眼睛收尾"看见预览"。
3. `qbt1000_key_input` 那张垃圾键位图：确认它是驱动填错的（`input_set_capability` 之前没清零 `keybit`），这属于内核侧、要碰 boot 镜像，**排在确认之后**。
4. `67` §7 剩的第 2 条（输入层的 `obtainPointerController` 在没有 SurfaceFlinger 时死循环）仍然成立，而且现在有了新证据：`test_camera` 的 `input` 线程就是停在 `obtainPointerController` 那个 250 ms/100 ms 的重试里，它把 8 个设备全打开了却一个事件都不处理。修它要改 `compat/input`，是我们自己构建的树 —— 但**它只影响走 hybris 输入栈的进程**（相机 app 的"点屏拍照"），主机侧的 GUI 输入不走这条路（主机侧没有 libis 的映射）。
5. daemon 收尾时那个 FORTIFY abort（`66` §6）仍未处理；现在会话能干净跑完 60 秒，它的复现优先级可以降。
