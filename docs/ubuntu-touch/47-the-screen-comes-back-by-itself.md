# 47 — 重启之后屏幕自己回来了，但容器的 RescueParty 差点把它拆掉

**日期**: 2026-09-21
**状态**: 冷重启后**没有任何人工干预**，两个 unit 在 42 秒内把三处 overlay、两个 GPU 节点、容器补丁全部重新装上，127 秒时 Lomiri 外壳已经在跑（`shell=1 mir=1/1 bl=128 ldm=active`）。同时查清了一件差点被忽略的事：**停掉容器的 SurfaceFlinger 会让 Android framework 一直等一个永远不会回来的服务，RescueParty 把每一次等待都记成一次崩溃事件，攒够了就把整机重启进 recovery。** 这台设备上已经发生过一次：我发出 `systemctl reboot` 之后，设备先起了 UT，然后自己又重启进了 TWRP。
**接续**: [`46`](46-the-gui-runs-dev-ion-was-root-only.md)、[`45`](45-the-shell-crashed-on-a-thread-then-picked-the-wrong-linker.md)、[`44`](44-the-v63-image-sabotages-its-own-container.md)

---

## 1. 持久化生效了

`46` 结束时的状态全部是运行时的：三处 bind mount、两个 GPU 节点的权限、容器里的三处字符串替换。现在把它们都交给了两个开机 unit（`install-host-hybris-fix.sh` 和 `install-container-desabotage.sh`，都写在 `/etc/systemd/system` 这个可写路径上），然后**真的重启了一次**核对。

`/userdata/zl1-host-fix.log` 里两次启动的对照（行首是当时的 uptime）：

```
5501.41 opened /dev/kgsl-3d0                                    <-- 上一次启动，我手动跑的
5501.44 opened /dev/ion
5654.44 bind-mounted the TLS shim
5777.26 bind-mounted /userdata/zl1-hybris/lsc-wrapper over /usr/share/ubuntu-touch-session/lsc-wrapper
42.00 opened /dev/kgsl-3d0                                      <-- 重启之后，unit 自己跑的
42.02 opened /dev/ion
42.05 bind-mounted /userdata/zl1-hybris/lsc-wrapper over /usr/share/ubuntu-touch-session/lsc-wrapper
42.10 bind-mounted /userdata/zl1-tlsfix/shadow/libtls-padding.so over /usr/lib/aarch64-linux-gnu/libtls-padding.so
42.21 bind-mounted /userdata/zl1-hybris/lomiri-greeter-wrapper over /usr/bin/lomiri-greeter-wrapper
```

`/userdata/zl1-container-fix.log` 同样：

```
42.03 sabotage present (st_dev=39, want 1800) — lifting it
57.59 after apply: st_dev=1800 hwready=true
62.80 surfaceflinger came back — stopping it again
```

开机 127 秒时的状态：`shell=1  mir=1/1  backlight=128  lightdm=active`。**屏幕是被开机流程自己点亮的，没有我动手。** 这是 `44` 以来第一次。

## 2. 但是设备自己又重启了一次，进了 TWRP

时间线（这段是事后拼出来的）：

1. 我在 uptime 5831s 发 `systemctl reboot`。
2. `pstore` 里的 `console-ramoops` 显示那次启动**正常关闭**（`systemd-shutdown[1]: Could not deactivate swap /dev/zram0`、`keeper exit v63 pid=815 rc=143 uptime=5847.38`），没有 panic。
3. 主机这边的 udev 日志显示 zl1 的 RNDIS（`18d1:d001`）在 `16:21:45` 被配上 `usb0` —— **也就是说 UT 确实起来了**。
4. 但一分钟后再看，`adb devices` 是：

   ```
   List of devices attached
   33e80afe	recovery
   ```

   设备在 **TWRP 3.3.1-0** 里。`misc` 分区读出来是全零（BCB 被 bootloader 消费后清掉了）。

**不是我自己脚本干的。** 把 `/data/system-data/` 整个 grep 一遍，只有 `zl1-netwatch.sh` 里有 `boot-recovery`；而它的 `RECOVERY_AFTER` 来自 `/userdata/zl1-netwatch-reboot-recovery`（**不存在**），日志里也没有任何 `RECOVERY:` 行。boot 镜像的 `zl1-postswitch-debug-init` 里连 `recovery` 这个词都没有。

## 3. 谁干的：RescueParty，证据在容器的 logcat 里

回到 UT（从 TWRP 里 `reboot system`）之后，容器一起来就能看见：

```
W/RescueParty( 1506): Noticed 2 events for UID 0 in last 126 sec
I/ServiceManager( 1506): Waiting for service SurfaceFlinger...
I/ServiceManager( 1506): Waiting for service SurfaceFlinger...
W/ServiceManager( 1506): Service SurfaceFlinger didn't start. Returning NULL
I/ServiceManager( 1506): Waiting for service SurfaceFlinger...
```

`1506` 是容器的 `system_server`。`RescueParty` 是 Android framework 里那个"这机器在崩溃循环"的升级器，它的最后一级就是重启进 recovery（让用户恢复出厂）。而**把 system_server 推进这个状态的正是我们自己的修法**：`44` 要求停掉容器的 SurfaceFlinger（QCOM composer 只收一个 client），SF 一停，framework 就永远在 `Waiting for service SurfaceFlinger...`，每一次等待都是一次"事件"。

`pstore` 里那份上一次启动的日志也留着一模一样的痕迹：`Waiting for service SurfaceFlinger...`、`Service SurfaceFlinger didn't start. Returning NULL`、`Waited one second for android.frameworks.sensorservice@1.0::ISensorManager/default. waiting another.`

所以：**停 SF 是必须的，但只停 SF 不行** —— 它把容器留在一个 framework 崩溃循环里，而那个循环有个延迟生效的核弹。`44` §5.1 记的"停 SF 会导致一连串服务重启"，现在看只是这颗核弹的早期症状。

## 4. 修法：让容器停在 HAL 这一层

两件事，都不需要 framework：

```sh
nsenter -t $A -p -m -- /system/bin/setprop persist.sys.disable_rescue true   # 关掉 RescueParty
nsenter -t $A -p -m -- /system/bin/setprop ctl.stop zygote                   # 让 framework 别等
```

第二条的依据是：**宿主需要的东西没有一个是 zygote 的子进程**。compositor 要的 HIDL 服务全是 init service，`lshal` 停在 zygote 之前之后都是满的：

| | 停之前 | 停之后 |
| --- | --- | --- |
| `lshal` 认到的 HIDL 服务 | 145 | **146** |
| `init.svc.zygote` | running | stopped |
| `init.svc.surfaceflinger` | stopped | stopped |
| `persist.sys.disable_rescue` | 空 | `true` |
| `hwservicemanager.ready` | `true` | `true` |
| logcat 里 `RescueParty`/`Waiting for service SurfaceFlinger` | 一直在刷 | 最近 500 行里 **0** 条 |
| `/proc/loadavg` 第一个数 | 14.00 | **8.93** |

关掉的东西：Android 应用跑不了（不需要），TF 卡/USB 大容量存储那类 framework 服务（不需要）。留下来的：146 个 HIDL 服务、QMI、显示、音频 HAL —— 也就是宿主真正要用的那一层。

两条都已经写进 `install-container-desabotage.sh` 的看门狗，每次容器启动后自动执行。

## 5. 还没证实的

- **重启了第二次吗。** 这一篇只重启了一次（§1）。RescueParty 的核弹已经拆了，但"再重启一次屏幕还会自己回来"要再测一遍才算数。
- **`persist.sys.disable_rescue=true` 之外，init 自己有没有别的重启路径。** `44` §5.1 那条 `onrestart restart zygote` 还在；现在 zygote 是被主动停的（不是崩的），init 不会因此重启。但 `ctl.stop zygote` 之后如果 init 重启容器，zygote 会自己回来，看门狗要能跟上。
- **容器的 `/data` 里 `persist.sys.disable_rescue` 落到哪了。** 写进去了（读回来是 `true`），但它存的位置是容器的持久属性区，容器重启后是否还在没有被单独验证 —— 看门狗每次启动都会再写一遍，所以功能上不依赖。
- **屏幕内容还是没被眼睛验证。** 这一篇的所有结论都还是间接证据（出帧、背光、QML、socket）。
- **rescue 事件是不是真的会累积到那一级。** 我看到的证据是"RescueParty 在数事件"加"设备进了 recovery"，中间那一步（RescueParty 的第几级、它到底调用的是 `reboot recovery` 还是别的）没有直接抓到。写在这里当待证。

## 6. 这一段改了哪些东西

| 文件 | 作用 |
| --- | --- |
| `scripts/hybris-shims/install-host-hybris-fix.sh` | 新增。宿主侧的持久化：三处 overlay（`lsc-wrapper`、`libtls-padding.so`、`lomiri-greeter-wrapper`）、两个 GPU 节点、以及会话的 unit drop-in。10 秒一轮重新断言，不是只做一次 |
| `scripts/hybris-shims/lomiri-greeter-wrapper.zl1` | 新增（跟踪进仓库）。原来只躺在 `/userdata` 里，重启后恢复的是"上次留下的那份"而不是"review 过的那份" |
| `scripts/hybris-shims/install-container-desabotage.sh` | 改。`apply()` 里加 `persist.sys.disable_rescue=true`，并把容器的 zygote 也停掉；干净分支同样会补停 zygote |
