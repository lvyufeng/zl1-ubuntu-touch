# 38 — Stage 2.5：回滚演练

**日期**: 2026-09-21
**状态**: **通过**（回滚路径已验证），附一条重要保留意见（见 §5）
**承接**: [`20-stage2-runbook.md`](20-stage2-runbook.md)、
[`stage2-coldboot-trials.md`](stage2-coldboot-trials.md)（Stage 2.4）

---

## 1. 为什么做这个

Phase 2 的判据里写着：**2.5 通过，才可以说"这条路线是安全的"。**

在那之前，"有回滚路径"只是对**一个文件**的声明——文件在不在、哈希对不对。
它没有说明**设备**能不能回到原样。这两件事不一样，演练就是把前者变成后者。

## 2. 演练的四步

用的坏镜像是**有记录的失败**，不是临时造的：
`halium-boot-zl1-v67-from-v63-lxc-masked.img`，18,022,400 字节，
`cfce435a403f9f0435bcfc327b64b81fb30d3ae4c1b82cf4a23b1c166612fa8f`，
`docs/session-notes/FAILURE-PATTERN-V64-V67.txt` 记的是
"no ADB, no RNDIS, unknown state"，而且当时是从它恢复过来的。

| 步 | 时间 (UTC) | 动作 | 结果 |
| --- | --- | --- | --- |
| 1 | 02:08:13 | `fastboot flash boot` 坏镜像 | `Sending 'boot' OKAY` / `Writing 'boot' OKAY` |
| 2 | 02:08:15 → 02:12:17 | 确认它**起不来** | 240 秒内无 RNDIS gadget，**也没掉 EDL** ——正是记录的症状 |
| 3 | 04:33:50 | `fastboot flash boot` 回刷原厂 `boot.img` | `Sending` (65536 KB) `OKAY` / `Writing OKAY`；镜像 65536 KB，整分区写入 |
| 4 | 04:34:03 → | 确认设备回来 | 见 §4 |

第 3 步用的镜像是 `/mnt/data/zl1-backups/2026-06-07-adb-root-staged/boot.img`，
`a06d6508499ee37a03effea1e6bec1d04f23843fd44d198a49fb3e07cb5778ef`——
**刷之前脚本自己先校验了一遍**（`stage2-rollback-boot.sh` 里的 `ROLLBACK_SHA`）。

### 2b. 刷坏镜像之前先把"现在是什么"记下来

从 TWRP 读 boot 分区的前 18,022,400 字节：

```
ab574bd337fa8dfe25b21b90bb8bc9ea39a1ea12907d286bed788e8f92e57576
```

这跟 [`manifests/halium-boot-candidates.md`](../../manifests/halium-boot-candidates.md) 里
`halium-boot-zl1-v63-usbd-disabled.img`（**KNOWN GOOD**）**逐字节相同**。
所以"演练弄坏了就刷回 v63"也是一条有哈希的路径，不只是"刷回原厂"。
记录在 `/mnt/data/zl1-backups/2026-09-21-misc-commands/PRE-DRILL-BOOT-PARTITION.txt`。

### 2c. 走到 fastboot 这一步原来是纯人工，而且演练脚本自己会放弃

02:12:17 坏镜像确认失败之后，脚本开始等人工把设备带到 fastboot。它的窗口是**硬编码
1800 秒**，到 02:42:24 就超时退出了——设备留在原处（这是对的），但**已经没有东西在
等那次按键了**。

修法：

- 窗口改成 `HUMAN_WAIT_SECONDS`，默认 6 小时
- 新增 [`scripts/stage2-rollback-resume.sh`](../../scripts/stage2-rollback-resume.sh)：
  从"坏镜像已在、已确认起不来"这个状态接着走，等多久都行，然后跑同一个带哈希校验的回滚

顺带还有一个**不需要按键就能进 TWRP 的通路**：见 §6。

## 3. 顺带修好的：`run-stage24-and-25.sh` 在构造上跑不完

跑 2.4 的时候发现它用的是 `adb shell reboot`。**Ubuntu Touch 不跑 adbd**，
所以它只能走一次——第一次开机之后每次重启都失败。Stage 2.4 因此**不可能**完成。
现在重启走 SSH。

## 4. 结论：回滚路径成立

设备在 04:34:03 重启后，**04:59:13 起 adb 可用**（约 25 分钟）。
读到的是：

```
LeEco/ZL1_CN/le_zl1:9/PKQ1.181007.001/9.11.13:user/release-keys   （原厂 ROM）
ro.boot.verifiedbootstate = orange
```

而且 **`/data` 没被动过**：

```
-rw-r--r-- 1 root root 8589934592 2026-03-24 21:45 /data/rootfs.img
-rw-rw-rw- 1 root root 4294967296 2026-06-07 22:34 /data/system.img
```

也就是 Ubuntu Touch 那套映像文件还在，`/data` 用了 13G / 24G。
**演练没有毁掉适配的现场。**

回滚路径成立：坏镜像 → 确认失败 → 带哈希校验地刷回 → 设备重新可达。

## 5. 保留意见：adbd 起来了 ≠ Android 起来了

这是本次最需要写清楚的一点。

设备**起不来 Android**。它停在开机动画里：

```
[init.svc.bootanim]        = running      （从 uptime 14193 s 一直 running）
[init.svc.surfaceflinger]  = running
system_server              = 不在进程表里
ro.boottime.zygote         = 不存在        ← zygote 从来没启动过
sys.boot_completed         = 空
```

logcat 里 `system_server` 的前身（pid 663）在**无限等待**一个永远不会注册的服务：

```
W ServiceManagement: Waited one second for
    android.frameworks.sensorservice@1.0::ISensorManager/default. Waiting another...
```

（传感器那几个 HAL 自己是在跑的：`vendor.sensors-hal-1-0`、`vendor.sensors.qti`、
`citsensor-hal-1-1` 都在。`/vendor` 也挂着、`libQSEEComAPI.so` 也在。
所以不是"vendor 没挂上"这么简单。）

**这跟演练无关。** 演练只写了 boot 分区，而 boot 分区的内容跟原厂备份逐字节相同
（刷之前主机侧校验过，`fastboot` 送回 `OKAY`）。一次只写 boot 分区的操作，
不可能造成 zygote 不启动。

所以正确的说法是：

| 说法 | 成不成立 |
| --- | --- |
| 坏镜像刷进去之后能刷回来 | ✅ 成立 |
| 设备没有变砖，adb / fastboot / TWRP 都到得了 | ✅ 成立 |
| `/data` 里的适配现场没被破坏 | ✅ 成立 |
| "设备回到了原生 Android" | ⚠️ **只说对了一半**：回到了原厂内核和 adbd，Android 框架没有起来 |

原厂 Android 为什么挂住**是另一件事**，这里不动它——
最直接的"修法"是清 `/data`，而那会**删掉 `rootfs.img` 和 `system.img`**，
也就是删掉整个适配的现场。**不做。**

脚本的判据也跟着改了：`wait_for_android()` 现在分开报"adbd 起来了"和
`sys.boot_completed=1`。之前那句 "device is back on stock Android" 是个比证据强的结论。

## 6. 进 TWRP 不再需要按键

Ubuntu Touch 不跑 adbd，所以从 UT 出来原来只有一条路：按键。
其实还有一条：**`misc` 分区**。往里面写 `boot-recovery` 就是 Android 自己的
`reboot recovery` 干的事，也正是设备侧看门狗 `RECOVERY_AFTER` 用的机制。

新增 [`scripts/enter-recovery-from-ut.sh`](../../scripts/enter-recovery-from-ut.sh)，
2026-09-21 实测：

```
02:07:28  wrote and verified boot-recovery in /dev/sda4
02:07:48  TWRP is up on 33e80afe        ← 20 秒
```

两个细节：

- **写回读校验**，读回来不是 `boot-recovery` 就**不重启**。没有 bootloader 命令的
  重启不是"降级版"，是重启循环。
- **路径按视角选**：Ubuntu Touch 下分区在 `/dev/disk/by-partlabel/`、
  节点是 `/dev/sdaNN`；TWRP/Android 下才是 `/dev/block/bootdevice/by-name/`。
  硬编码任何一边都会在另一边失败。

所以现在的可达性：

| 目标 | 从 UT | 从坏镜像 | 需要按键吗 |
| --- | --- | --- | --- |
| TWRP | `enter-recovery-from-ut.sh` | 音量上 + 电源 | UT 侧不用 |
| fastboot | `adb reboot bootloader` | 音量下 + 电源 | 坏镜像下要 |

**只有"设备完全起不来还要进 fastboot"这一种情况仍然需要按键。**

## 7. 另一个发现：两个手机会报同一个 USB ID

演练期间核对 USB 标识时看到：

```
3-3 :  idVendor=18d1 idProduct=4ee7 serial=33e80afe product=Android     ← zl1
3-10:  idVendor=18d1 idProduct=4ee7 serial=4a2fe00b product="MI 4LTE"   ← 小米
```

**同一个 `18d1:4ee7`。** 原厂 Android 下的 zl1 和小米在 USB 标识上完全一样，
只有 serial 和 product 字符串不同。

这比原来记的更严重：不只是"别用裸 USB ID"，而是**用裸 USB ID 会稳定地选错**。
所有脚本仍然按 serial `33e80afe` 过滤。
