# 45 — 屏幕点不亮（六）：外壳不再段错误，卡在 EGL config

**日期**: 2026-09-21
**状态**: `lomiri --mode=full-greeter` **不再 SIGSEGV**，改成干净地抛异常退出。原因分两段：段错误是 bionic TLS 槽只填了主线程；异常是 libhybris 选错了 linker（`q.so`，它的默认搜索路径里没有 `/vendor/lib64/egl`）。把 linker 钉成 `o.so` 之后 `dlopen failed` 全部消失，现在停在 Mir 的 `could not select EGL config`。
**接续**: [`44`](44-the-v63-image-sabotages-its-own-container.md)（镜像拆自己的台）、[`41`](41-bionic-tls-slot-is-never-filled.md)（TLS 槽没人填）、[`40`](40-the-display-died-below-lomiri.md)

---

## 1. 两段，不是一段

`44` §7 把"约 100 秒一轮的 lightdm 循环"记成待查，并怀疑 greeter 会话的环境。环境确实是个方向，但真正挡住会话的是两个独立的东西，被同一条日志串在一起：

```
lomiri[1709514]: qtmir.screens: ScreensModel[...]::ScreensModel()
lomiri[1709514]: <information> mirserver: Starting
lomiri[1709514]: < - debug - > mirserver: Not using logind ... Only owner of session may take control
lomiri[1709514]: < - debug - > mirserver: Not using Linux VT subsystem ... Failed to open current VT
lomiri[1709514]: < - debug - > mirserver: No session management supported
systemd[1681033]:  lomiri-full-greeter.service: Main process exited, code=killed, status=11/SEGV
```

会话是 `lomiri-full-greeter.service`（systemd **user** unit，`ExecStart=/usr/libexec/lomiri-systemd-wrapper --mode=full-greeter`），它由 `ubuntu-touch-session` 在 lightdm 自动登录 `phablet` 之后拉起。它起 Mir 成功（`mirserver: Starting`），然后死。**不是 lightdm 的 greeter 会话** —— 那个（`lomiri --mode=greeter`）在 `44` 那一轮里已经能跑住了。

## 2. 第一段：TLS 槽垫片只覆盖主线程

`41` 的结论是：glibc 进程里 bionic 的 TLS slot 1（TP+8）永远是 0，`__get_thread()` 返回 NULL，`__get_bionic_tls()` 的读取就炸在 `0xb00`。`scripts/tlsfix` 的垫片在 constructor 里把这个槽填上一个假的 `pthread_internal_t`。

**constructor 只在它自己那个线程上跑** —— 也就是主线程。之后 `pthread_create` 出来的每个线程都拿到一个全新的、清零的 TCB，TP+8 又是 0。而这次崩的就是这样一个线程：内核早先写下的那个 core 文件名是 `core.MirServerThread.1061654`，**线程名写在文件名里**。壳子的 Mir 起来后创建 server 线程，段错误落在 server 线程上。

修法：垫片里加 `pthread_create` 拦截，包一层 trampoline，在新线程的入口点之前先填槽（`scripts/tlsfix/tlsfix.c`）。malloc/dlsym 是它唯二用到的 libc 入口，两者失败都退回到真正的 `pthread_create`，不把调用弄挂。构建脚本跟着加了两条形状检查：必须有导出的 `pthread_create`，而且**不能带 version definition** —— 带版本的话 glibc 里 `pthread_create@GLIBC_2.34` 的引用绑不上它，拦截就永远不生效。

效果（同一份日志）：

| | 之前 | 之后 |
| --- | --- | --- |
| `lomiri-full-greeter` 退出方式 | `code=killed, status=11/SEGV` | `code=exited, status=1/FAILURE` |
| 主进程日志 | 停在 `mirserver: Starting` 后段 | 继续走到建图形平台 |
| 重启计数 | 一直涨到 63+ | 仍是失败，但换了原因 |

也就是说：**段错误是 TLS 槽，跟显示没有关系**，这一点到这一篇才被真正证实。

## 3. 第二段：libhybris 给壳子选了一个没有 egl 路径的 linker

异常版本的日志是：

```
lomiri[1884478]: dlopen failed: library "libGLESv2_adreno.so" not found      (× 24)
lomiri[1884478]: dlopen failed: library "eglSubDriverAndroid.so" not found
lomiri[1884478]: Exception while creating graphics platform
lomiri[1884478]: ERROR: ./src/platforms/android/server/gl_context.cpp(127): Throw in function select_egl_config_with_any_format
lomiri[1884478]: std::exception::what: could not select EGL config
```

`dlopen failed: library "…" not found` 是 **bionic linker** 的措辞。宿主这一侧，Android 库由 libhybris 的 linker 加载，而那台设备上 linker 有四个：`/usr/lib/aarch64-linux-gnu/libhybris/linker/{mm,n,o,q}.so`。它们**默认搜索路径不一样**：

```
$ grep -aoE "/vendor/lib64/egl|/vendor/lib64|/system/lib64|/odm/lib64" o.so | sort | uniq -c
      2 /vendor/lib64/egl        <-- 有
      3 /vendor/lib64
      5 /system/lib64
      5 /odm/lib64
$ grep -aoE "/vendor/lib64/egl|/vendor/lib64|/system/lib64|/odm/lib64" q.so | sort | uniq -c
      3 /vendor/lib64             <-- 没有 egl
      3 /system/lib64
      3 /odm/lib64
```

`libGLESv2_adreno.so` 在 `/vendor/lib64/egl/` 下面，而 `HYBRIS_LD_LIBRARY_PATH` 里只有 `/vendor/lib64`。所以**用哪个 linker 决定了 EGL 驱动找不找得到**。两个活着的进程摆在一起看，一目了然：

```
compositor pid=1959794  maps: libhybris/linker/o.so
                        /android/vendor/lib64/egl/libGLESv2_adreno.so     <-- 从 egl 目录加载
greeter    pid=2078665  maps: libhybris/linker/q.so
                        （没有 adreno 的 map —— 找不到就是没有）
```

两个进程的 `HYBRIS_LD_LIBRARY_PATH` 和 `LD_PRELOAD` **完全相同**，所以差别不在环境变量，而在 linker 的选择。libhybris 里这个选择支持环境变量覆盖：

```
$ grep -aoE "HYBRIS_LINKER|ro.build.version" libhybris-common.so.1.0.0 | sort -u
HYBRIS_LINKER
ro.build.version
```

不设 `HYBRIS_LINKER` 时它按 `ro.build.version` 自己挑；壳子挑到了 `q.so`（Android 10 的那只），而 compositor 挑到 `o.so`（Android 8）。设备上跑的是 Android 8 的库，`o` 才是对的。

修法是把 linker 钉住，写在 **unit 级**的 drop-in 里（unit 的 `Environment=` 压过 manager 的环境，这条是必需的 —— 见 §5）：

```ini
# /home/phablet/.config/systemd/user/lomiri-full-greeter.service.d/zl1-hybris.conf
[Service]
Environment=HYBRIS_LINKER=o
Environment=LD_PRELOAD=/usr/lib/aarch64-linux-gnu/libtls-padding.so
Environment=HYBRIS_LD_LIBRARY_PATH=/vendor/lib64/egl:/system/lib64/egl:/odm/lib64/egl:/userdata/zl1-hybris/lib:/system/lib64:/odm/lib64:/vendor/lib64
```

钉住之后 `dlopen failed` **一条都不剩**，失败点从"驱动加载不了"变成"选不出 EGL config"。这是净进展：EGL 那条路已经通了。

## 4. 现在停在哪：`could not select EGL config`

```
lomiri[2152649]: <information> mirserver: Starting
lomiri[2152649]: Exception while creating graphics platform
lomiri[2152649]: ERROR: ./src/platforms/android/server/gl_context.cpp(127): Throw in function select_egl_config_with_any_format
lomiri[2152649]: std::exception::what: could not select EGL config
```

值得注意的三点：

1. **壳子的 Mir 在直接建 android 图形平台**（`src/platforms/android/...`），也就是想自己去驱动显示器。而显示器已经归 system compositor 了，壳子本来应该是**嵌套**在它里面（`MIR_SERVER_HOST_SOCKET=/run/mir_socket` 这个变量就在环境里，Mir 的 "mir"/nested 平台就是靠它连宿主）。
2. **同一台设备上选得出 EGL config** —— system compositor 自己就是 Mir android 平台，`GL renderer: Adreno (TM) 530`，`Active output [1] at (0, 0) is 1080x1920`。所以不是"Adreno 选不出 config"，是**这个进程的这次选择**不一样。
3. 所以下一步是平台选择，不是 EGL：要么让壳子走 nested/mir 平台（用宿主 socket），要么找出 compositor 那份 Mir 的图形平台参数（它带着 `--enable-num-framebuffers-quirk=true --disable-overlays=false --console-provider=...`）里哪一条让 `select_egl_config_with_any_format` 有解。

这一条没查完，这一篇只把前两段钉死。

## 5. 环境从哪里来（这一节是踩坑记录）

`44` §7 猜"greeter 会话的环境里没有垫片"。猜对了一半，但路径是对的、做法错了一次：

- `lomiri --mode=greeter`（lightdm 的 greeter 会话）由 lightdm 直接跑，环境里没有垫片 → 所以在 `/usr/bin/lomiri-greeter-wrapper` 里 `export`（bind mount 覆盖，运行时的）。
- `lomiri --mode=full-greeter`（phablet 会话的 user unit）的进程环境**不是**从 greeter wrapper 继承的，它来自 systemd **user manager**。
- `/home/phablet/.config/environment.d/*.conf` **不生效**（`systemctl --user show-environment` 里看不到）。
- `/home/phablet/.config/systemd/user.conf` 的 `[Manager] DefaultEnvironment=` **生效**（`show-environment` 里看得到），但**对已经有值的变量不一定压得住** —— `HYBRIS_LD_LIBRARY_PATH` 是从会话脚本（`/usr/share/ubuntu-touch-session/lsc-wrapper`，全机唯一 export 它的地方）继承下来的，改 `DefaultEnvironment` 之后进程里读出来还是老值。
- **unit 级的 `Environment=` 才压得住。** 放在 `~/.config/systemd/user/<unit>.d/*.conf`，改完用 phablet 身份 `systemctl --user daemon-reload`（以 root 跑会 `Failed to connect to bus: Operation not permitted`，要带 `XDG_RUNTIME_DIR` 和 `DBUS_SESSION_BUS_ADDRESS`）。

## 6. 改了哪些文件

| 文件 | 作用 |
| --- | --- |
| `scripts/tlsfix/tlsfix.c` | 加了 `pthread_create` 拦截：新线程在自己的入口点之前填 TP+8。原来的 constructor 只够主线程 |
| `scripts/tlsfix/build-tlsfix.sh` | 加两条形状检查：`pthread_create` 必须导出、而且必须不带 version definition（否则 glibc 的版本化引用绑不上，拦截静默失效） |
| 设备上 `/home/phablet/.config/systemd/user/lomiri-full-greeter.service.d/zl1-hybris.conf` | unit 级环境：`HYBRIS_LINKER=o` + 垫片 + 带 egl 目录的 `HYBRIS_LD_LIBRARY_PATH`。`/home` 是持久的，所以这个能活过重启 —— 但它**不是**镜像里该有的东西，最终仍然要落到 boot 镜像/会话配置里 |
