# 27 — 一次可达窗口里读到的现场

**日期**: 2026-09-17
**怎么拿到的**: 每 ~2 分钟周期性地给 `usb0` 配好地址再探测（不做这一步就永远够不着——
每次 gadget 重建都会把主机的地址清掉）。15:57 抓到了连续 3 份状态页。

---

## 1. 先纠正一件事：设备现在跑的是哪张镜像

不是 v63，是 **`halium-boot-zl1-v63-debug-shell.img`**
（v63 + cmdline 加 `zl1_debug_shell=1`），00:55 刷进去的。之后所有"重启进 UT"都用的它，
因为 14:40 那次 one-shot 没带 `BOOT_IMAGE` 参数，只重启不刷机。

这个区别有意义：它带着 `zl1_debug_shell=1`，而日志里出现了

```
[881.629664] zl1-debug-net-v63: shell telnetd 23 exited rc=1
```

也就是**那张镜像确实尝试起了 telnet shell，但 telnetd 启动失败（rc=1）**。
所以"刷 debug-shell 镜像就能拿到 shell"这条路，光靠 cmdline 参数是走不通的。

## 2. 状态页里读到的事实

### 2.1 netwatch 装上了，而且在跑

进程表里：

```
1:systemd:/sbin/init
1019:zl1-netwatch.sh:/bin/sh /etc/systemd/system/zl1-netwatch.sh
```

### 2.2 Android 容器起来了，而且是完整的一套

同一份进程表里，除了 `lxc-start ... INIT_SECOND_STAGE=true /init`，
还有一整套 HAL：

```
ueventd, hwservicemanager, qseecomd, servicemanager, vndservicemanager,
android.hardware.{keymaster,bluetooth,camera.provider,cas,configstore,drm,gatekeeper,
graphics.allocator,graphics.composer,health,light,memctrl,memtrack,power,sensors,
thermal,vibrator,vr,wifi}@*, android.hidl.allocator, dumpstate, media.omx,
lxc-monitord, systemd-journald, systemd-udevd, systemd-timesyncd, systemd-logind,
dbus-daemon, zl1-v63-monitor, zl1-debug-net.sh
```

**这比 v63 在 2026-06-13 那次记录到的还要全。** 容器不是"勉强起来"，是完整起来了。

### 2.3 sshd 确实在监听 22

```
LISTEN 0      8    0.0.0.0:8080
LISTEN 0      8    0.0.0.0:8081
LISTEN 0      128  0.0.0.0:22
```

`8080/8081` 是 keeper 的状态服务，`22` 是 **sshd**。6 份快照里有 4 份能看到它。

### 2.4 新出现的东西：有人在停容器

```
559331:lxc-stop:/usr/bin/lxc-stop -n android -k
```

**`lxc-stop -k` 正在跑。** 有东西在强杀 Android 容器。这和时间线上容器忽有忽无、
以及 §26 里那套"每 ~2 分钟拆一次 USB gadget"是同一个层面的现象——**设备上有多方在互相拆台**。

## 3. 可达窗口的规律：只在开机最初约 50 秒

这次实测（每 2 秒探一次，10 分钟）：

```
可达时间          47 秒 / 599 秒  (7.8%)
最长连续可达      47 秒
ssh 端口 22       0%
状态页 8080       11.2% 的采样
```

而那次 47 秒窗口对应的设备 uptime 是 **9.73 秒**——**刚开机**。

这解释了两件事：

1. **为什么 6 月每个 session 都撞到"约 30 秒可用"**：那不是"跑一会儿就坏"，
   而是**只有开机最初那一小段是通的**，之后 churn 开始，就再无窗口。
2. **为什么 ssh 一次都没成功**：窗口在 uptime 0–50 秒，而 `sshd` 要等 systemd 起来
   （约 30 秒后）才开始监听。两者重叠的部分极小，实测就是 0%。

## 4. recovery 兜底为什么没生效（已修）

14:40 那次安装把 marker 写成了 `900`。设备此后 uptime 跑到了 2870 秒（48 分钟），
**一次 recovery 都没触发**。

原因在 netwatch 自己的循环里：治愈分支末尾有一个 `continue`，

```sh
        heals=$((heals + 1))
        log "HEAL: attempt $heals/$MAX_HEALS done; ..."
        sleep "$HEAL_RETRY_SECONDS"
        ...
        continue            # <-- 直接跳回循环顶部
    fi

    if [ "$RECOVERY_AFTER" -gt 0 ] && [ "${uptime_s:-0}" -ge "$RECOVERY_AFTER" ]; then
        ...  <- 只要治愈过一次，这段就再也到不了
```

**只要治愈被触发过一次，后面的 recovery 检查就被永久跳过。**
设备恰好就处在"一直在触发治愈"的状态里，所以 marker 形同虚设。

已经把这个 `continue` 删掉，并在代码里写明为什么。

## 5. 这些对计划意味着什么

| 之前的说法 | 现在 |
| --- | --- |
| "设备约 1/4 次开机会卡死" | **不是概率**：每次开机的头 ~50 秒都通，之后都断 |
| "刷 debug-shell 镜像能拿到 telnet shell" | 那张镜像里 telnetd 以 rc=1 退出，**这条路走不通** |
| "Android 容器起不来" | 容器**完整起来了**，连指纹/相机/drm 那些 HAL 都在 |
| "recovery 兜底能自动把设备送回 TWRP" | **从未生效过**，原因是循环里的 `continue`；已修 |
| "SSH 修好了但没验证" | 已确认 **sshd 在监听 22**；没验证的只剩公钥认证本身 |

真正剩下的那个问题变得更清楚了：**不是"设备会不会偶尔坏"，而是"开机 ~50 秒后有什么东西
开始反复拆 USB gadget、并且还会 `lxc-stop -k` 掉容器"。**
[`26`](26-gadget-reassert-every-2-minutes.md) 找到的 keeper 重建设备是其中一环；
`lxc-stop` 是另一环，之前没看见过。

## 6. 所以下一轮要刷什么，也要跟着改

原计划是刷 `halium-boot-zl1-v63-noreassert.img`（去掉 keeper 的 gadget 重建）。
仍然该刷，但既然已经知道：

- 窗口只有开机头 50 秒
- sshd 大约 30 秒后才监听
- 容器一起来 churn 就开始

那么测试的判据要换：**不是"SSH 能不能连上"，而是"开机后 50 秒关口还在不在"**——
即 uptime 超过 120 秒后，`host-watch-usb0` 还能不能持续看到可达。
`measure-link-stability.sh` 已经按这个口径输出（可达时间占比 + 最长连续可达 + 重建次数）。

`halium-boot-zl1-v63-debug-shell.img` 里 telnetd 失败的原因也值得顺手查——
源码里是 `busybox telnetd -F -b 0.0.0.0:23 -l /bin/sh`，
`-F`（前台）配上 `-l` 在 initramfs 的 busybox 里可能不成立。
但那是次要的：**只要窗口不关，SSH 就够了。**
