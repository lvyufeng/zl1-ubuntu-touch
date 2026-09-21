# 44 — 屏幕点不亮（五）：v63 镜像一直在拆自己容器的台

**日期**: 2026-09-21
**状态**: 屏幕亮了。`mir_socket` 建起来了、Lomiri 起来了、背光 128、Mir 报 `Active output [1] at (0, 0) is 1080x1920`。挡住它的不是 libhybris，也不是哪个 HAL 没编出来，而是**v63 这个"已知可用"镜像自己在容器启动时改掉了三个 Android 二进制的字符串**。
**接续**: [`43`](43-binder-does-not-cross-a-pid-namespace.md)（binder 不跨 PID namespace）、[`42`](42-the-wait-that-could-never-finish.md)（一个永远等不到的属性）、[`41`](41-bionic-tls-slot-is-never-filled.md)、[`40`](40-the-display-died-below-lomiri.md)

---

## 1. 一句话

`[42]` 和 `[43]` 把容器的病记成两个"还没查"的谜：**为什么 property service 不收写入**、**为什么 `hwservicemanager.ready` 没人设得上**。答案是：**镜像自己不让它们成功。** v63 的 LXC mount hook 会把 `hwservicemanager`、`qseecomd`、`libc.so` 各复制一份到 tmpfs 里，把里面**等长**的关键字符串换掉，再 bind 覆盖回真身：

| 被改的文件 | 原字符串 | 换成 | 后果 |
| --- | --- | --- | --- |
| `system/bin/hwservicemanager` | `hwservicemanager.ready` | `zlservicemanager/ready` | 容器里每个 HAL 都等一个**永远不会被设上**的属性 |
| `vendor/bin/qseecomd` | `sys.listeners.registered` | `zl1.listeners.registered` | 同上一类 |
| `system/lib64/libc.so`、`system/lib/libc.so` | `/dev/socket/property_service` | `/dev/socket/property_servicf` | 容器里**所有**属性的写入都 `ENOENT`，因为连的是一个不存在的 socket |

三处都是 V25/V28/V29/V30 时代的**诊断实验**（`scripts/make-halium-postswitch-debug-boot.sh` 里有大段注释解释当时的假设），后来被原封不动收进 `0e95c3a`「Make the known-good v63 image rebuildable from tracked source」。v63 的"已知可用"是**网络**意义上的（`netd` 被禁掉，RNDIS 稳），Android 这边整个是坏的 —— 而坏的原因就写在 boot 镜像里。

顺带解掉的第二个东西：**容器的 SurfaceFlinger 必须停掉**，否则它一个人占着 QCOM composer 的单客户端名额，宿主 compositor 拿不到 HWC2 client。

## 2. 怎么发现的：两条"物理上不可能"的观察

把三个库补上之后（`[43]` §2），compositor 的报错停在：

```
android/server: Error opening HWC HAL. Assuming HWComposer 2 device with libhwc2_compat_layer.
failed to create composer client
```

先怀疑 `createClient()` 而已。为了分清"是容器坏还是宿主坏"，做了一组对照：**同一个二进制、同一个 PID namespace，只换 mount namespace** 去写属性。

```
$ nsenter -t $A -p    -- /system/bin/setprop debug.p1 1     # 宿主 mount ns
   rc=0                                       6/6 成功
$ nsenter -t $A -p -m -- /system/bin/setprop debug.q1 1     # 容器 mount ns
   setprop: failed to set property 'debug.q1' to '1'   0/6 成功
```

6/6 对 0/6，不是抖动。但接下来每一步都指向"不可能"：

- `/dev/socket` 两个 namespace 里是**同一个目录**（inode 44066，两边列出来的成员 inode 逐个相同）。写个标记文件进去，另一边立刻看得见。
- `/dev/socket/property_service` 在容器 mount ns 里 `ls -la` **成功**，是同一个 inode 46622，`srw-rw-rw-`。
- `/dev/__properties__` 两边是同一个 tmpfs（设备号 `0:17`）。
- 而 strace 说：

  ```
  connect(3, {sa_family=AF_UNIX, sun_path="/dev/socket/property_service"}, 31) = 0          # 宿主 mount ns
  connect(3, {sa_family=AF_UNIX, sun_path="/dev/socket/property_servicf"}, 31) = -1 ENOENT # 容器 mount ns
  ```

**同一个文件、同一个长度 31，最后一个字节一个是 `e` 一个是 `f`。** 同一个 ELF 里的同一个字符串常量不可能这样。于是问题变成"这两边到底是不是同一个文件"：

```
$ md5sum /android/system/lib64/libc.so
  67786011d5860035922b5d807822452f
$ md5sum /proc/$A/root/system/lib64/libc.so        # 走容器 init 的 root
  2d5a50333c1b2991207b9501a644240b
$ stat -c '%d %i' ...   host: dev=1800 ino=3484     cont: dev=39 ino=43930
```

`dev=1800` 是 `7:8`，也就是 `/dev/loop1`（`/userdata/system.img`）—— 真身。`dev=39` 是某个 **tmpfs**。同一路径、同一挂载点、不同的设备 —— 只可能是**有人在这条路径上又 mount 了一层**。`/proc/self/mountinfo`（容器 namespace 里）一眼看到：

```
348 326 0:39 /system/lib64/libc.so   tmpfs
349 326 0:39 /system/lib/libc.so     tmpfs
346 326 0:39 /system/bin/hwservicemanager tmpfs
347 327 0:39 /vendor/bin/qseecomd    tmpfs
```

四个 tmpfs 文件 bind 在真身之上。**这就是 `[42]`「容器的 property service 不接收写入」和 `[43]`「`hwservicemanager.ready` 没人设得上」的全部答案。**

## 3. 谁 mount 的：v63 的 LXC mount hook

`/var/lib/lxc/android/zl1-mount-hook.sh`（19 KB，由 initramfs 的 `zl1-postswitch-debug-init` 每次开容器前写出来，`lxc.hook.mount` 每次 `lxc-start` 跑一遍）。它干了很多正常的 V63 活（mask `usbd.rc`、伪造 Android 那边的 USB gadget 视图、给 `.rc` 补 `seclabel`），然后是三段等长字符串替换 + `mount --bind`。它们写在 `/run/*.log` 里，每次容器启动都有记录：

```
/run/zl1-hwservicemanager-patch.log   patched old_count=2 new_count_before=0 new_count_after=2
/run/zl1-qseecomd-patch.log           patched old_count=1 new_count_before=0 new_count_after=1
/run/zl1-libc-prop-socket-patch.log   system/lib64/libc.so: patched old_count=1 ...
                                      system/lib/libc.so:   patched old_count=1 ...
```

源码里的理由（`scripts/make-halium-postswitch-debug-boot.sh`）大意是：V25/V29 看到 Android init 收到 `/system/bin/hwservicemanager` 的属性更新后 SIGSEGV，于是把属性名改成**含斜杠的非法名**，想让 property service 在 `QueuePropertyChange()` 之前就拒掉；V28 看到 init 在 qseecomd 发 `sys.listeners.registered=true` 之后不久就死，于是同样改名；V30 发现非法名也还是崩，就进一步**把 libc 的 property socket 路径改成不存在的路径**，让 init 之外的所有 `property_set` 客户端根本连不上。

这些是**排除法实验**，不是修复。它们全体留在镜像里，后果是容器的 Android HAL 一层都起不来 —— 每一个 HAL 都在等 `hwservicemanager.ready`，而 `hwservicemanager` 把它设成了 `zlservicemanager/ready`。

## 4. 修法一：把三处替换拿掉

运行时可以逐条撤销（`umount -l`，因为文件被 mmap 着，普通 `umount` 返回 `EBUSY`）：

```sh
A=$(lxc-info -n android -pH | head -1)
for t in /system/lib64/libc.so /system/lib/libc.so \
         /system/bin/hwservicemanager /vendor/bin/qseecomd; do
    nsenter -t $A -p -m -- /system/bin/umount -l "$t"
done
nsenter -t $A -p -m -- /system/bin/setprop ctl.restart hwservicemanager
nsenter -t $A -p -m -- /system/bin/setprop ctl.restart qseecomd
```

（顺序要紧：`ctl.restart` 本身是一次属性写入，只有 libc 那两层撤掉之后才写得进去。）

撤掉之后容器当场变好：

| | 撤掉之前 | 撤掉之后 |
| --- | --- | --- |
| 容器内 `setprop debug.x 1` | `failed to set property` rc=1 | rc=0，读回来是 1 |
| `getprop hwservicemanager.ready` | 空 | `true` |
| `getprop sys.listeners.registered` | 空 | `true` |
| `logcat` 里 `waiting another` | 7798 行（最后 200 行里 200 行） | 最后 200 行里 **0** 行 |
| `lshal` 认到的 HIDL 服务 | 0 | **145** |

145 个里含 compositor 要的全部：`android.hardware.graphics.composer@2.1::IComposer/default`、`configstore@1.0::ISurfaceFlingerConfigs/default`、`graphics.allocator@2.0::IAllocator/default`、`graphics.mapper@2.0::IMapper/default`。`[43]` §5 那张"一个都没注册"的图到这里闭合。

## 5. 修法二：容器的 SurfaceFlinger 必须停

HAL 起来之后 compositor 往前走了一步，走到我们自己的那句 `LOG_ALWAYS_FATAL`：

```
halium/libhybris/compat/hwc2/ComposerHal.cpp:182   LOG_ALWAYS_FATAL("failed to create composer client");
```

`getService()` 这次成功了（`[43]` 那句 `failed to get hwcomposer service` 没再出现），失败的是 `mComposer->createClient()`。容器那边的 composer 服务同时在 logcat 里说：

```
D/ComposerHal( 3559): waiting for previous client to be destroyed
D/ComposerHal( 3559): previous client was not destroyed
D/vndksupport( 8466): Loading /vendor/lib64/hw/hwcomposer.msm8996.so from current namespace instead of sphal namespace.
F/HwcComposer( 8466): failed to create composer client
D/SDM     ( 3559): DisplayBase::BuildLayerStackStats: LayerStack layer_count: 2, app_layer_count: 1, ...
```

**QCOM 的 composer@2.1 只允许一个 client，而容器的 SurfaceFlinger 正拿着它**（那些 `SDM ... layer_count: 2` 就是 SF 在送帧）。Halium 的设计里显示器归宿主 compositor，所以容器的 SF 不该跑：

```sh
nsenter -t $A -p -m -- /system/bin/setprop ctl.stop surfaceflinger
nsenter -t $A -p -m -- /system/bin/setprop ctl.stop bootanim
```

停掉之后 `init.svc.surfaceflinger=stopped`（60 秒内稳定 —— 之前看到它"自己回来"，其实是**容器整个重启了**，不是 init 把它拉起来），然后重启 lightdm，compositor 就一路走到底：

```
mirserver: GL vendor: Qualcomm / GL renderer: Adreno (TM) 530
mirserver: GL version: OpenGL ES 3.2 V@331.0 (GIT@2df12b3, I07da2d9908) (Date:10/04/18)
mirserver: Mir version 1.8.2
mirserver: Initial display configuration:
mirserver: * Output 1: LVDS connected, used
mirserver: . |_ Power is on
mirserver: . |_ Current mode 1080x1920
Server supports 4 of 11 surface pixel formats. Using format: 1
Active output [1] at (0, 0) is 1080x1920
Spinner using pixels per grid unit: 21
Spinner using native orientation: 'Portrait'
```

观测到的状态（连续 80 秒不抖）：`lightdm=active`、compositor 4 个进程、`/run/mir_socket` 和 `/run/wayland-syscomp` 存在、`lomiri-system-compositor-spinner` 在跑、Lomiri session 4 个进程、`/sys/class/leds/lcd-backlight/brightness = 128`（在这之前一直是 0）。

**这就是 Phase 5 的显示器目标：屏幕亮了。** 第一次。

### 5.1 为什么 SF 一停就"连锁重启"

`/system/etc/init/surfaceflinger.rc`：

```
service surfaceflinger /system/bin/surfaceflinger
    class core animation
    ...
    onrestart restart zygote
```

`onrestart restart zygote` —— SF 每重启一次，init 就把 zygote 连同 `audioserver`、`cameraserver`、`media`、`netd`、`wificond` 一起拉一遍。宿主 compositor 一旦抢到 HWC，SF 下次启动必然拿不到 client → 崩 → init 拉 zygote → 一整片服务重启 → 容器很快重启。`dmesg` 里那一串

```
init: Service 'zygote' (pid 1053) received signal 9
init: Command 'restart audioserver' ... succeeded
init: Command 'restart cameraserver' ... succeeded
...
```

就是这条链。所以 **SF 必须是被 `.rc` 里 `disabled` 掉的**，不能只是 `ctl.stop` —— `ctl.stop` 活不过下一次容器重启。

## 6. 现在的限制（重要）

三处替换和 SF 都是**容器每次启动时重新装上的**，所以上面两个修法都是**运行时的**，而且**活不过一次容器重启**。验证过程中容器重启过一次（`lxc-start` 进程还在，容器 init 换了 pid，`/run/zl1-*-patch.log` 全部被重写），三处替换立刻回来、`hwservicemanager.ready` 又变空。

也就是说：**要真正解决，必须改 boot 镜像**，让 `zl1-postswitch-debug-init` 写出来的 mount hook

1. 不含那三段字符串替换；
2. 给 `system/etc/init/surfaceflinger.rc` 加一个 `disabled` 的 bind-mask（照 `usbd.rc` 那个现成的写法）。

这是下一步，不是本篇的范围。本篇只把"屏幕亮起来需要什么"钉死，并用运行时手段证明这个配置是对的。

## 7. 还没证实什么

- **屏幕亮了，但内容对不对没验证。** 背光 128、Mir 报了 active output、spinner 在跑 —— 但这些都不等于"人眼看到正确的画面"。需要一张照片或一次触摸事件才能确认。
- **就位的不是稳定画面，是一个约 100 秒一轮的循环。** 这次跑下去之后 lightdm 已经走到起 greeter：

  ```
  Seat seat0: Running command /usr/lib/lightdm/lightdm-greeter-session /usr/bin/lomiri-greeter-wrapper /usr/bin/lomiri --mode=greeter
  ```

  而 greeter 会话（`/var/log/lightdm/seat0-greeter.log`）里是

  ```
  [qtmir.screens: ScreensModel[ScreensModel(0x...)]::ScreensModel()]
  Segmentation fault
  ```

  也就是 **QtMir 构造完 `ScreensModel` 之后段错误**，lightdm 记 `Seat seat0: Stopping; failed to start a greeter`，把整个 display manager 拆掉重来（起始时刻 14:55:58 / 14:57:38 / 14:59:31 / 15:01:22，间隔 100–113 秒）。compositor 本身在这个过程中一直健在（`up` 数到 97 秒才被换掉），`mir_socket`、背光、active output 都在 —— **每一轮都能重新把显示配好，只是会话起不来**。
  下一步的怀疑对象是 greeter 会话的**环境**：`lsc-wrapper` 只包了 system compositor，`lomiri --mode=greeter` 是 lightdm 自己拉起来的，TLS 槽垫片和 `HYBRIS_LD_LIBRARY_PATH` 都不一定在它的环境里 —— 而 QtMir 一样走 libhybris。
- **V25/V29/V30 当年观测到的 init SIGSEGV 是不是真的。** 现在容器里 `setprop` 正常工作、`hwservicemanager.ready` 正常设置，init 没有崩。但那三个补丁被拿掉的时间还不长，也没有专门去压它。如果那个崩是真的，正确的修法是修 init 那个崩，不是把整个容器的属性写入废掉。
- **容器的 zygote 现在还会不会自己崩。** `dmesg` 里那串 zygote 连锁重启有一次是 SF 引起的；但这台设备上跑的是 MIUI/乐视的 framework，`android.frameworks.sensorservice@1.0::ISensorManager` 一直缺席（logcat 里在等），framework 稳不稳定没有单独测过。
- **内核里 binder 为什么跨 PID namespace 不工作**（`[43]` §4）仍未下到源码层；观察是硬的，机制是推测。nsenter 方案继续保留。

## 8. 改了哪些脚本

| 文件 | 作用 |
| --- | --- |
| `scripts/hybris-shims/free-container-display.sh` | 新增。`--apply` 撤掉三处替换（`umount -l` 四个 tmpfs 文件 + 重启 `hwservicemanager`/`qseecomd`）、停掉容器的 `surfaceflinger`/`bootanim`；`--status` 打印两边的对照（容器里 `property_service` 路径是 `e` 还是 `f`、`hwservicemanager.ready`、`lshal` 计数、`init.svc.surfaceflinger`、compositor 的 PID namespace）；`--explain` 把三处替换和它们的出处列出来。运行时-only，容器一重启就要重跑 |
