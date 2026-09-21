# 57 — 重启验证：两个服务在容器 namespace 里活过来了（以及它们第一次露出启动顺序问题）

**日期**: 2026-09-21
**状态**: `56` 的手工结果过了冷启动。`lomiri-location-service` 和 `biometryd` 现在**开机自己就能起来**并且待在容器的 PID namespace 里，图形界面同时在跑。路上暴露了两个"平时看不出来、一重启就现形"的问题 —— 都是**依赖来得比服务晚**，而 systemd 的默认启动限流把"晚"变成了"永远不" —— 各自修掉了。顺带把 `54` 欠的"第二次冷启动"补上了：Wi-Fi 连着三个冷启动都自动起来了，而且**接口名在两次启动之间是反过来的**。
**接续**: [`56`](56-the-two-services-move-into-the-containers-pid-namespace.md)、[`55`](55-the-bridge-libraries-built-and-hwbinder-does-not-cross-pid-namespaces-either.md)、[`54`](54-wifi-the-driver-was-waiting-for-an-fwpath-write-nobody-did.md)
**另见**: [`58`](58-one-cold-boot-where-the-secure-world-refused-and-three-firmwares-did-not-load.md) —— 这次重启里有一次是**坏的**，坏的形状和这里完全无关，但值得单独记：那是 GPU/音频/传感器一起不工作的原因。

---

## 1. 第一次重启：界面正常，但 `lomiri-location-service` 没起来

第一次冷启动之后 `systemctl --failed` 里多了 `lomiri-location-service`。查日志（注意时间戳在时钟同步前后会跳，用 `-o short-monotonic` 才看得出顺序）：

```
[ 42.684] Starting lomiri-location-service.service
[ 56.084] Started lomiri-location-service.service     <- 认领了 bus 名
[ 56.439] Starting lightdm.service
[ 57.636] lomiri-location-service.service: Deactivated successfully   <- 1.5 秒后就没了
[ 68.294] Starting user@32011.service                 <- 用户会话才开始
```

`Deactivated successfully` 而不是 `Failed with result 'signal'` —— 它**干净地退出了**。而 rootfs 里这个 unit 是 `Restart=on-failure`，**干净退出恰恰是它不会重试的那种**。所以它整个开机就一直是死的，而且 `systemctl --failed` 一度也不显示它 —— 因为什么都没有"失败"。

原因在库自己的字符串里（本地 sysroot 里那份 `liblomiri-location-service.so.3.0.0` 上 `strings` 就能看到，不用上设备）：

```
libtrust-store.so.2
DBUS_SESSION_BUS_ADDRESS
core::trust::dbus::create_multi_user_agent_for_bus_connection
TrustStorePermissionManager::create_default_instance_with_bus
```

它在启动时建一个 trust-store agent；而 `trust-stored-skeleton --for-service LomiriLocationService` 是**用户会话**拉起来的（`ps -eo lstart` 显示 13:09:25，在 `user@32011` 开始之后）。设备上还留着一行现场：单位用 `--store-bus session`，也就是它要的那条总线此刻还不存在。

`biometryd` 同一时刻是活的 —— 因为它出厂就是 `Restart=always`。

## 2. 修法：重试，而不是排序

第一版加了 `Restart=always`。第二次重启之后它确实开始重试了，但**三次就永久失败了**：

```
Scheduled restart job, restart counter is at 3.
Start request repeated too quickly.
Failed with result 'start-limit-hit'.
```

systemd 默认限流是 **10 秒内 5 次**；`RestartSec=5` 配这个限制，等于只允许三次尝试就判死。而这个服务要等的会话在 ~68 秒处才来 —— 三次尝试根本不够。

所以现在是三行：

```
[Unit]
StartLimitIntervalSec=0

[Service]
RestartSec=5
Restart=always
```

**为什么是重试而不是 `After=user@32011.service`**：排序意味着把 uid 硬编码进去（rootfs 别处确实这么干，但那还是个 uid）；而且排到用户管理器启动**并不保证**那个管理器内部的 per-user trust-store unit 已经起来；换一个用户还得再来一遍。重试不关心这三件事里哪一件是真的。

`biometryd` 也一起加了 `StartLimitIntervalSec=0` 和 `RestartSec=5`，理由在 §3。

## 3. `biometryd`：能恢复，但差一点就没恢复

同一个坏启动里，`biometryd` 的重复启动计数爬到 **55**、负载平均值 **14.4**。日志说明它在做什么：

```
zl1-ns-exec[...]: setActiveGroup failed: SYS_EINVAL
systemd[1]: biometryd.service: Deactivated successfully.
systemd[1]: biometryd.service: Scheduled restart job, restart counter is at 55.
```

它一进容器 namespace 就会调用 Android 指纹 HAL 的 `setActiveGroup`（选指纹分组），HAL 在准备好之前回 `SYS_EINVAL`；`biometryd` 干净退出；出厂自带的 `Restart=always` 于是不停重启它 —— 每 ~3.7 秒一轮，每轮还带一次 `nsenter`。这是一个**真循环**，不是偶发。

它最终是能好的（好启动上 3–4 次重试之后它就稳住了，因为 HAL 起来了），但 10 秒 5 次的默认限流离判死只差一次尝试 —— 有一次启动它正好用了 4 次。所以给它 `RestartSec=5`（把 100 毫秒的默认值换成有节制的重试，坏启动上也就不会烧 CPU）加 `StartLimitIntervalSec=0`（让它重试到 HAL 起来为止）。

**`setActiveGroup failed: SYS_EINVAL` 本身没有解决**，只是被限速了。值得记一笔：这是指纹链路第一次真正走到"和 Android HAL 对话"的那一层。

## 4. 修完之后：一次干净的重启

```
lightdm=active restarts=3     session=active   lomiri=1
lomiri-location-service    active   restarts=3
biometryd                  active   restarts=3
zl1-wlan-bringup           active   restarts=0
failed: update-machine-info-from-deviceinfo.service
```

`lomiri-location-service` 是**重试到会话起来之后自己稳住的**（3 次），不再需要手工 `systemctl start`。

## 5. 顺带结清 `54` 的待办：Wi-Fi 的第二次冷启动

`54` §6 留了"还没做第二次冷启动"。又冷启动了几次，每次都对：`fwpath: sta`、`zl1-wlan-bringup` 0 次重启、接口出现、`iw dev wlan0 scan` 报 **29 个 BSS**。

**而且这次的接口名和上次是反的。** `54` §3.5 那个"名字不叫 `wlan0`"的教训，这次以更强的形式重演：

```
这次:  wlan0   b4:ef:fa:d1:32:38   (station)      wlp1s0 b6:ef:fa:d1:32:38  (p2p)
上次:  wlp1s0  b4:ef:fa:d1:32:38   (station)      p2p0   b6:ef:fa:d1:32:38
```

**同一个 station 接口，两次启动名字不同。** 也就是说"按名字找"不只是在某一次上是错的，它**每次都可能不一样**。bringup 脚本里的判据（`/sys/class/net/<if>/wireless`）和设备上 `--status` 的写法（发现而不是假设）因此是对的，不是保守。这次的对照也说明 `54` 里 `wlp1s0` 那个名字纯属巧合。

## 6. 这一段改了哪些东西

| 文件 | 作用 |
| --- | --- |
| `scripts/hybris-shims/install-container-ns-services.sh` | 加了 per-unit 的额外 unit 配置（`unit_extra`）：`[Unit] StartLimitIntervalSec=0` + `[Service] RestartSec=5`，`lomiri-location-service` 另加 `Restart=always`。字段用 `\|` 分隔而不是空白 —— 命令里有空格（`/usr/bin/biometryd run`），空白分隔的 `read` 会把它悄悄截断；`\n` 由设备侧 `printf %b` 展开。生成的 drop-in 现在会打印出来，`--status` 里也能看到它 |
