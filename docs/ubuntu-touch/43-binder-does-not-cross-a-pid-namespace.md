# 43 — 屏幕点不亮（四）：binder 不跨 PID namespace

**日期**: 2026-09-21
**状态**: compositor 的第三个和第四个阻塞点都解掉了（`libhwc2_compat_layer.so` 编出来了），然后发现真正挡住整条 Android 链路的是一个此前完全没看到的事实：**宿主里的进程根本连不上容器里的 binder 服务**。这不是猜测，是一条三组对照命令能重复出来的结论。同一批调查还发现**容器自己也是坏的**：容器里上百个 Android 进程卡在同一个属性上。
**接续**: [`42`](42-the-wait-that-could-never-finish.md)（一个永远等不到的属性）、[`41`](41-bionic-tls-slot-is-never-filled.md)、[`40`](40-the-display-died-below-lomiri.md)

---

## 1. 一句话

`/dev/binder` 和 `/dev/hwbinder` 在宿主机和容器里是**同一个内核设备**（都是 `10:56` / `10:55`，容器配置里就是从宿主机 bind 进去的），但**同一个二进制**在宿主 PID namespace 里跑 `service list` 返回 `Found 0 services:`，用 `nsenter -p` 进容器的 PID namespace 里跑同一个二进制返回 `Found 19 services:`。差别只有 PID namespace 这一个变量。

推论：**compositor（宿主 PID namespace）永远看不到任何 Android binder 服务** —— 包括 `display.qservice`（QCOM HWC 依赖）、`servicemanager`、`hwservicemanager`。这条链断在这里，不在 libhybris，也不在库文件缺失。

## 2. 先解决掉的那个：`libhwc2_compat_layer.so`

`[42]` 末尾的第 4 个阻塞点是 `library "libhwc2_compat_layer.so" not found`。它和 `libui_compat_layer.so` 是同一类东西（Halium 侧、设备的 Android 构建产出、原厂 LeEco 镜像里没有），但**不能**用 `[42]` 那种「预编译 clang 单编一个 .cpp」的办法：它是 **HIDL `android.hardware.graphics.composer@2.1` 服务的客户端**，需要 hidl-gen 生成的头文件（`IComposer.h`、`IComposerClient.h`、command-buffer 那套）。生成它们要跑 hidl-gen，跑 hidl-gen 要跑 Soong —— 也就是说，得真跑一次 Android 构建。

`scripts/hybris-shims/build-hwc2-compat-layer.sh` 把这条路固化下来了。三个宿主侧前置条件都踩过，都写进了脚本的检查里：

| 症状 | 真正的原因 |
| --- | --- |
| `vendor/lineage/bootanimation/Android.mk:50: error: stop` | 缺 ImageMagick（`mogrify`）。这个 `$(error)` 在**产品配置阶段**就触发，比我们的模块被看到早得多，所以看起来像树坏了 |
| `SyntaxError: Missing parentheses in call to 'print'`（沙箱里） | `external/clang/clang-version-inc.py` 和 `bionic/libc/fs_config_generator.py` 还是 Python 2。脚本给这次构建单独准备一个 `python` → `python2.7` 的 shim 目录塞进 PATH |
| `ckati failed`，一堆 `missing libpuffdiff` / `missing ims-common` | lineage 树里无关模块（update_engine 的单测、CodeAurora 的 IMS java 库）依赖不全，kati 在 ninja 开始前就中止。`ALLOW_MISSING_DEPENDENCIES=true` 把它们的错误推迟到一个永远到不了的点 |

产物：`out/libhwc2_compat_layer.so`，135960 字节，SONAME 正确，导出 27 个 `hwc2_compat_*`。

**一个已知的缺口**：根文件系统里那份 `libhwc2.so.1`（比 Halium 9 树新）会 `dlsym` 两个这棵树里没有的符号 —— `hwc2_compat_display_present_or_validate` 和 `hwc2_compat_layer_set_sideband_stream`。它 `dlsym` 后不检查 NULL，所以一旦走到那两条路径就是跳到地址 0。脚本会打印这个差集，不当成错误。

## 3. 下一个错误，和它指向的地方

补上库之后错误变成：

```
failed to get hwcomposer service
```

这是我们自己编进去的那句 `LOG_ALWAYS_FATAL`（`ComposerHal.cpp:171`），`IComposer::getService()` 返回了 nullptr。到此为止看起来还是「HIDL 服务没找到，再调调就行」。为了看清楚它在哪个系统调用上失败，把 `lsc-wrapper` 临时换成 `strace` 包一层跑（`exec strace -f -o /userdata/zl1-utrace.log -s 300 -e trace=... /usr/sbin/lomiri-system-compositor …`；注意 compositor 在 `/usr/sbin/`，不在 `/usr/bin/`）。

strace 给了两条互相对不上的信息：

- `/dev/hwbinder` 打开了（fd 16），`BINDER_VERSION` / `BINDER_SET_MAX_THREADS` 都成功，然后**只有一次 `BINDER_WRITE_READ`**，接着 ConfigStore 就打印 "retrieved: 0 (default)" —— 一次事务，拿到一个空回复，然后放弃。
- 换到 legacy HWC 路径时，`/vendor/lib64/hw/hwcomposer.msm8996.so` **加载成功了**（连同 `libsdmcore.so`、`libqservice.so`、`libqdutils.so`、`vendor.display.config@1.0.so` …），然后在 `ServiceManager` 的 `Waiting for service 'display.qservice'` 上一直转 —— 那是 `frameworks/native/libs/binder/IServiceManager.cpp:164`，`getService()` 的阻塞重试循环。

两条都指向同一件事：**binder 事务发出去了，答复是空的。** 不是库找不到，不是符号缺失。

## 4. 真正的结论：binder 不跨 PID namespace

容器配置（`/var/lib/lxc/android/config`）里 `/dev/binder`、`/dev/hwbinder`、`/dev/vndbinder` 都是从宿主机 `bind` 进去的：

```
lxc.mount.entry = /dev/binder dev/binder bind bind,create=file,optional 0 0
```

也就是说两边打开的确实是同一个内核设备。用 `readlink /proc/<pid>/ns/*` 对比，容器进程和宿主进程的 `net` 和 `user` namespace 相同（配置里 `lxc.namespace.keep = net user`），只有 `pid`、`mnt`、`uts`、`ipc` 不同。

三组对照，同一个 Android 二进制（`/system/bin/service`，走 `/dev/binder` 找 servicemanager）：

```
$ /android/system/bin/service list                     # 宿主 PID namespace
Found 0 services:

$ nsenter -t $$ -p -- /android/system/bin/service list  # 对照组：进自己的 PID namespace
Found 0 services:

$ nsenter -t $(lxc-info -n android -pH) -p -- /android/system/bin/service list
Found 19 services:
0	storaged_pri: [android.os.storaged.IStoragedPrivate]
1	storaged: [android.os.IStoraged]
…
```

第二组是关键对照：它排除了「nsenter 这个工具本身带来了什么」。唯一变化的变量就是 PID namespace。第三组进了容器的。ldd、设备号、mount 都没变。

（内核里具体是哪一步拒的，本次没有下到源码层去钉。结论按观测写：**事务被接受、答复为空**，不是 `-EPERM`，也不是 `-ENOENT`。`[42]` 里 `waitForHwServiceManager` 那次也是同一个味道，只是那次先撞上的是属性等待。）

### 4.1 修法：让 compositor 跑在容器的 PID namespace 里

`lsc-wrapper` 里：

```sh
ANDROID_INIT_PID=$(lxc-info -n android -pH 2>/dev/null | head -1)
if [ -n "$ANDROID_INIT_PID" ] && [ -e "/proc/$ANDROID_INIT_PID/ns/pid" ]; then
    exec nsenter -t "$ANDROID_INIT_PID" -p -- /usr/sbin/lomiri-system-compositor …
fi
```

两个坑，都写进注释了：

- **不要加 `-F` / `--no-fork`。** `setns` 一个 PID namespace 只影响**之后 fork 出来的子进程**，调用者自己还留在原来的 namespace 里。`nsenter -F` 会让被 exec 的进程留在宿主 namespace、而它的孩子进容器 namespace，于是 `task_active_pid_ns(current) != pid_ns_for_children`，`clone(CLONE_THREAD)` 返回 `EINVAL`。亲眼看到的现象是 compositor 启动到一半抛

  ```
  terminating with uncaught exception of type std::__1::system_error: thread constructor failed: Invalid argument
  ```

  也就是「一个进程的线程不能跨两个 PID namespace」。
- **判断目录要用 `[ -e ]` 不是 `[ -d ]`。** `/proc/PID/ns/pid` 是符号链接，目标是 nsfs 的 inode，`-d` 是假的。第一次就是因为它静默走了 fallback 分支，白等了二十分钟。

改完之后 compositor **不再退出**：进程活着、有三个线程，其中一个在 `binder_thread_read` —— 也就是说它注册成了 binder 客户端，这是之前完全做不到的。lightdm 的 60 秒超时才会把它杀掉重启。

## 5. 顺带发现：容器自己也是坏的

在容器里 dump logcat（`nsenter -t <init> -p -- logcat -d -v brief`），满屏是这个：

```
W/ServiceManagement(  451): Waited for hwservicemanager.ready for a second, waiting another...
W/ServiceManagement(  250): Waited for hwservicemanager.ready for a second, waiting another...
… 上百个不同的 pid，从 207 到 525 …
W/ServiceManagement(28638): Waited one second for android.hardware.configstore@1.0::ISurfaceFlingerConfigs/default. Waiting another...
```

**容器里的 Android 进程在等同一个属性，而且等不到。** 这就把 `[42]` 的结论补全了：`hwservicemanager.ready` 读不到不只是「宿主进程读属性区读不到」，而是 `hwservicemanager` **自己没能把它设进去**，于是容器里的 HAL 服务一个都没注册成功 —— `configstore@1.0` 没有、`composer@2.1` 即使进程在跑也不可用、`display.qservice` 也没人注册。

`[42]` §4.2 记的现象（容器的 property service 不接收写入）在这里有了后果：它不是「容器的事，和宿主等待无关」，**它是整条 Android 链路的根**。

也就是说：进了容器的 PID namespace 之后，compositor 卡的位置从「库找不到」变成了「在 `getService(configstore)` 的阻塞重试里等一个永远不会注册的服务」—— 因为宿主那份 `libhidltransport.so` 的 4 字节补丁只去掉了 `waitForHwServiceManager` 的等待，`getRawServiceInternal` 里 **Waiter** 的「每秒钟重试一次、直到服务出现」循环还在，而那个服务永远不出现。

## 6. 现在这条链子

| # | 阻塞 | 状态 |
| --- | --- | --- |
| 1 | compositor 0.44 秒被 SIGSEGV | 已解（TLS 槽垫片，`[41]`） |
| 2 | `libui_compat_layer.so` not found | 已解（`[42]`，自己编） |
| 3 | `eglInitialize` 里 `hwservicemanager.ready` 死等 | 已解（4 字节补丁，`[42]`） |
| 4 | `libhwc2_compat_layer.so` not found | 已解（本篇 §2，真跑 Android 构建） |
| 5 | `failed to get hwcomposer service` / `display.qservice` 等不到 | 已解（本篇 §4，nsenter 进容器 PID namespace） |
| 6 | **宿主进程看不到任何 Android binder 服务** | **已定界（本篇 §4），修法已在 wrapper 里** |
| 7 | **`hwservicemanager.ready` 容器里也没人设得上 → 所有 Android HAL 服务没注册** | **当前** |

## 7. 还没证实什么

- 屏幕仍然不亮，`lcd-backlight/brightness` 还是 0。
- **内核里 binder 为什么跨 PID namespace 不工作**，没有下到源码层确认。观测是硬的（三组对照可重复），机制是推测。
- `display.qservice` 到底有没有被注册过 —— 容器里没有探针能直接列 `/dev/binder` 的服务（`lxc-attach` 在这个负载下反复超时），宿主那份 `service list` 又是空的（§4）。
- 为什么容器的 property service 不接收写入，`[42]` 没查，本篇也没查。**这是现在最值得查的一件事**，因为 §5 表明它挡住了所有 Android HAL。
- nsenter 方案的一个瑕疵：util-linux 的 nsenter 不一定回收得了「活在另一个 PID namespace 里」的子进程，每轮可能留下一个停在 `do_wait`、`children` 为空的 nsenter。它们是惰性的，但会占住 namespace，所以 wrapper 每次启动前会把没有子进程的那些清掉。

## 8. 改了哪些脚本

全部在 `scripts/hybris-shims/`，都只动运行时，没有任何分区写入。

| 文件 | 作用 |
| --- | --- |
| `build-hwc2-compat-layer.sh` | 新增。跑 Android 构建出 `libhwc2_compat_layer.so`，检查宿主前置条件，并把「`libhwc2.so.1` 会 dlsym 但这份没导出」的差集打出来 |
| `make-lsc-wrapper.sh` | 新增。从设备原版 `lsc-wrapper.orig` 生成 `lsc-wrapper.zl1`，两处改动：`HYBRIS_LD_LIBRARY_PATH`、PID namespace。`--check` 用来验证已跟踪的那份还是生成的 |
| `lsc-wrapper.zl1` | 重新生成（sha256 `f3e1b842…`） |
| `install-hybris-shims.sh` | 多部署一个 `libhwc2_compat_layer.so`；`--status` 多打两行：compositor 的 PID namespace 和容器 init 的 PID namespace，这两个不相等就是问题 |
