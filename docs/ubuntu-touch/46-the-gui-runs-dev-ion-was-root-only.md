# 46 — 图形界面跑起来了：`/dev/ion` 是 root-only

**日期**: 2026-09-21
**状态**: **Lomiri 外壳在跑，而且在出帧。** `lomiri --mode=full-greeter` 连续存活 98 秒以上不掉，日志里是 `[PERFORMANCE]: Last frame took 60/87/135 ms to render`、QML 在加载（`EdgeBarrierSettings`、`Icon.qml`、指示灯状态），49 个 user unit 在跑，`/run/mir_socket` 和 `/run/user/32011/mir_socket` 都在，背光 128，lightdm active，`44`/`45` 那个约 100 秒一轮的座位循环停了。
**接续**: [`45`](45-the-shell-crashed-on-a-thread-then-picked-the-wrong-linker.md)、[`44`](44-the-v63-image-sabotages-its-own-container.md)、[`41`](41-bionic-tls-slot-is-never-filled.md)

---

## 1. 一句话

`45` 结束时壳子停在 Mir 的 `could not select EGL config`。真正的原因是**设备节点权限**：`/dev/ion` 是 `crw------- root root`，而 Lomiri 会话跑在 `phablet`（uid 32011）下面，打不开 ION 分配器 —— `eglInitialize` 直接失败（`EGL Error 3001` = `EGL_NOT_INITIALIZED`），于是**一个 EGL config 都选不出来**。`chmod 666 /dev/ion` 之后同一个二进制、同一个用户，68 个 config 全出来了。

这一条独立于前面所有工作，而且是纯粹的环境问题：**根下的 compositor 一直是好的，因为它跑在 root 下**，从来没碰到过这个权限墙。

## 2. 怎么定位的：把"root 行不行"当成变量

`45` §4 记了三条观察，其中第二条是关键：**同一台设备上 system compositor 自己就是 Mir 的 android2 平台，它能选到 EGL config**。所以问题不在 Adreno、不在 EGL 本身，而在"这两个进程哪里不一样"。最省事的切法就是**同一个测试程序，换用户跑**：

```
$ env ... /usr/bin/test_egl_configs                       # root
  Available configurations: 68
  ===== Configuration #0 =====
    EGL_RED_SIZE: 5
    ...
$ su -s /bin/sh phablet -c "env ... /usr/bin/test_egl_configs"
  EGL Version 1.4
  ...
  EGL Error 3001 at test_egl_configs.c:106        <-- EGL_NOT_INITIALIZED
```

`EGL_NOT_INITIALIZED` 说的是 `eglInitialize()` 就没成功，不是"属性组合没有匹配"。设备上的 GPU 相关节点全是 root-only：

```
crw------- 1 root root 235,  0 /dev/kgsl-3d0
crw------- 1 root root  10, 94 /dev/ion
```

**顺序上的一点诚实**：先 `chmod 666 /dev/kgsl-3d0`，`test_egl_configs` **仍然** `EGL Error 3001`；再 `chmod 666 /dev/ion`，立刻出 68 个 config。所以 **`/dev/ion` 是必需的那一个**；`/dev/kgsl-3d0` 是否也必需没有单独测（两个都放开之后才验证了整条路）。msm8996 上图形的 buffer 走 ION，这个结果是自洽的。

## 3. 后果：一路到底

放开 `/dev/ion` 之后重启 lightdm，`lomiri --mode=full-greeter` 不再退出：

```
t= 36s  1 lomiri --mode=full-greeter
...
t= 90s  1 lomiri --mode=full-greeter        连续 60 秒不掉
```

再拉一次长窗口（98 秒，每 7 秒一采样）：

```
t=  7s shell=1 mir=1 user_mir=1 bl=128 ldm=active
...
t= 98s shell=1 mir=1 user_mir=1 bl=128 ldm=active
```

外壳自己的日志：

```
qml: EdgeBarrierSettings: min=2gu(36px), max=120gu(2160px), sensitivity=0.5, threshold=61gu(1098px?)
[PERFORMANCE]: Last frame took 60 ms to render.
[PERFORMANCE]: Last frame took 87 ms to render.
qml: updateLightState: onDeviceStateChanged, indicatorState: INDICATOR_OFF, ...
[PERFORMANCE]: Last frame took 507 ms to render.
file:///usr/lib/aarch64-linux-gnu/qt5/qml/Lomiri/Components/1.3/Icon.qml:115:5: QML Image: Canno... (缺图标)
```

**出帧了**，QML 场景图在跑，指示灯状态在更新。user 会话里 49 个 unit 在跑，唯一失败的是 `audiosystem-passthrough-qti.service`。

## 4. 这一路一共有五道墙

到这里为止挡住"图形界面"的五件事，每一件都是独立的，而且**四件都在宿主这一侧、跟 libhybris 或者 Android 没关系**：

| # | 挡住的 | 是什么 | 在哪一篇 |
| --- | --- | --- | --- |
| 1 | HAL 一个都不注册 | v63 镜像的 LXC mount hook 把四个 Android 二进制的字符串改掉 | `44` |
| 2 | compositor 拿不到 HWC client | 容器的 SurfaceFlinger 占着 QCOM composer 的唯一名额 | `44` |
| 3 | 进程在 `__ctype_get_mb_cur_max+8` 段错误 | bionic TLS slot 1 没人填；**而且垫片只填主线程** | `41` / `45` |
| 4 | `dlopen failed: libGLESv2_adreno.so` | libhybris 挑了 `q.so`，它的默认路径里没有 `/vendor/lib64/egl` | `45` |
| 5 | `could not select EGL config` | **`/dev/ion` 是 root-only，会话用户打不开** | 本篇 |

## 5. 现在的限制

- **这次改动是运行时的。** `/dev/kgsl-3d0` 和 `/dev/ion` 在 devtmpfs 上，**一次重启就回到 0600 root:root**。要持久，得写进 boot 镜像（`boot/v63/scripts/init-bottom/zl1-postswitch-debug-init` 里已经有现成的 `mknod -m 666` 段落，给 `/dev/null`、`/dev/kmsg` 那几个）或者一条开机就执行的 unit（照 `zl1-container-fix.service` 那个模式放在 `/etc/systemd/system`）。
- **`HYBRIS_LINKER=o` 和垫片也在宿主这一侧，同样不持久**（垫片是 bind mount，linker 是 unit drop-in；后者在 `/home/phablet` 下，能活过重启）。
- **`/dev/ion` 那 666 是不是给太宽了。** 现在的做法是把整个节点对所有人开放。正经的做法是给 ION 一个组（Android 那边是 `graphics`），把会话用户加进去。这次只做到"能用"。
- **屏幕内容仍然没有被眼睛验证过。** 出帧、背光 128、QML 在加载都是间接证据；一次触摸或者一张照片才能确认画面是对的。
- **没测过长稳。** 98 秒不掉不等于可以过夜；`44` 记录的容器自毁机制（每次 `lxc-start` 重放补丁）还在，`zl1-container-fix.service` 在看守它。
- **剩下那个失败的 unit**：`audiosystem-passthrough-qti.service`（"instance implementing IQcRilAudio interface"）—— 音频那条线的第一个待办。
- 触摸、Wi-Fi、其余硬件一个都没开始测（用户的目标里"所有的硬件都能驱动"那一半）。

## 6. 复现（当前设备上生效的全部运行时改动）

```sh
# 1. 容器：撤掉 v63 镜像的三处字符串替换 + 停掉容器的 SurfaceFlinger
scripts/hybris-shims/free-container-display.sh --apply
#    （持久版：scripts/hybris-shims/install-container-desabotage.sh --install）

# 2. 宿主：垫片（含 pthread_create 拦截）
scripts/tlsfix/install-tlsfix.sh --mount

# 3. 宿主：GPU 设备节点
chmod 666 /dev/kgsl-3d0 /dev/ion

# 4. 宿主：会话的 unit 级环境（/home/phablet/.../lomiri-full-greeter.service.d/zl1-hybris.conf）
#      HYBRIS_LINKER=o + LD_PRELOAD=垫片 + 带 egl 目录的 HYBRIS_LD_LIBRARY_PATH

systemctl reset-failed lightdm; systemctl restart lightdm
```

四步里 **1、3 是这一篇和 `44` 新增的**，2 是 `45` 改的，4 是 `45` 加的。
