# 17 — Ubuntu Touch / Halium 9 适配计划（重制版）

**日期**: 2026-09-16
**目标设备**: LeEco Pro3 `zl1` / `le_zl1` / MSM8996 (Snapdragon 821)，ADB serial `33e80afe`
**上一版本状态**: 参考 [`V63-OPTIONC-CONFIRMED-WORKING.md`](V63-OPTIONC-CONFIRMED-WORKING.md)、
[`docs/session-notes/STRATEGIC-ANALYSIS-NEXT-STEPS.md`](../session-notes/STRATEGIC-ANALYSIS-NEXT-STEPS.md)

本计划取代之前"逐个镜像试错（v2 → v73）"的做法。它基于对已有证据的重新核对，
其中包含若干对早期结论的**修正**——这些修正直接改变了下一步该做什么。

---

## 1. 证据基线（本次重新核对的结果）

### 1.1 已确认可用：v63 配置是"Ubuntu Touch + Android 容器同时运行"的工作状态

之前多个 session 记录把 V63 描述成"只是能进 systemd、Android 没起来"的状态。
本次直接读取设备端状态转储，结论相反：

`v63-usbd-disabled-boot-20260613T195322Z/status-008-192.txt`（最后一次采样）中，
进程表里有完整的 Android 用户空间：

```
34212  ppid=1      lxc-start  /usr/bin/lxc-start -n android -F -- /system/bin/env -i PATH=... INIT_SECOND_STAGE=true /init
34782  ppid=34212  init       /init
36591  ppid=34782  ueventd    /sbin/ueventd
36868  ppid=34782  hwservicemanager
36869  ppid=34782  qseecomd
39867  ppid=34782  logd
39868  ppid=34782  servicemanager
39869  ppid=34782  vndservicemanager /dev/vndbinder
39878+ ppid=34782  android.hardware.{keymaster,audio,bluetooth,camera,cas,
                   configstore,drm,gatekeeper,graphics,health,light,memtrack,
                   power,sensors,thermal,vibrator,vr,wifi}@* 全套 HAL
```

同一时刻 USB/RNDIS 侧：

```
/sys/class/android_usb/android0/state=CONFIGURED
/sys/class/android_usb/android0/functions=rndis
/sys/class/android_usb/android0/iProduct=zl1 V63 usbd-disabled RNDIS
rndis0(addr=...,carrier=1,op=up,idx=6)
```

对应的设备端 monitor 日志 `zl1-v63-monitor-from-device.log` 有 419 个 tick、
跨度 `uptime 3.99s → 537.94s`（约 9 分钟），全程 `rndis0 up`、`carrier=1`。

**结论：V63 配置下，Ubuntu Touch（systemd PID 1）、Android LXC 容器（Android init + HAL 全套）、
USB RNDIS 网络三者可以同时稳定运行近 9 分钟。** 这不是"半成品"状态，
而是一个真正可用的调试平台。

### 1.2 修正：`lxc-ls` 报 `STOPPED` 是假象，不能作为判据

`zl1-v63-monitor-from-device.log` 里 829/831 个采样都是
`lxc=[Name: android State: STOPPED ]`，早期 session 据此判断"Android 容器从未启动"。

这个判断是错的。同一个 monitor 脚本在 **v61** 上也报 `STOPPED`，而 v61 的状态转储
（`v61-postinit-monitor-boot-20260613T073058Z/status-008-192.txt`）里同样有
`lxc-start` → `/init` → `zygote64` / `zygote` / `surfaceflinger` 在跑。

原因是 `lxc-start -F`（前台模式）不写 `/run/lxc/*/state` 那类状态文件，`lxc-ls` 于是报 `STOPPED`。

**行动项**：所有"容器在不在跑"的判断改用 `lxc-info -n android`、
`pgrep -f lxc-start`、或直接看 `logd`/`servicemanager` 进程是否存在。
`lxc-ls` 的输出在本项目的文档中一律作废。

### 1.3 已定根的故障：35 秒断网

根因不是镜像、不是内核、不是 usbd。是 Ubuntu Touch rootfs 里
`usb-moded` 的 tethering 逻辑生成了一条 `method=shared`（内置 DHCP server）的
NetworkManager 连接，把设备侧静态 IP 覆盖掉。修复方式是在 rootfs 内预置：

- `/etc/NetworkManager/system-connections/rndis-static.nmconnection`
- `/etc/NetworkManager/system-connections/usb0-static.nmconnection`

（mode 0600，`autoconnect-priority=100`）

已注入该修复的 `rootfs.img`：`/mnt/data/ubports-rootfs/24.04-2.x/rootfs-24.04-2.x-arm64-android9plus-zl1-host.img`
（8,589,934,592 字节，2026-06-14 13:35）。V63 的 9 分钟稳定窗口就是在这个 rootfs 上取得的。

### 1.4 修正：分区备份已经完成并校验通过

之前 README 与 `DEVICE-IN-EDL-2026-06-17.md` 写的是"关键分区尚未备份"，**这条已过期**。

`/mnt/data/zl1-backups/2026-06-07-adb-root-staged/` 有 31 个镜像 + `partition-sizes.txt` + `SHA256SUMS`。
本次重新执行 `sha256sum -c SHA256SUMS`：**31/31 OK**。覆盖：

| 类别 | 分区 |
| --- | --- |
| 启动链 | `xbl` `xblbak` `aboot` `abootbak` `tz` `tzbak` `rpm` `rpmbak` `hyp` `hypbak` `devcfg` `devcfgbak` |
| 密钥/校准 | `keymaster(±bak)` `cmnlib(±bak)` `cmnlib64(±bak)` `modemst1` `modemst2` `fsg` `fsc` `persist` |
| 系统 | `boot` `recovery` `system` `vendor` `modem` `dsp` `bluetooth` `splash` |

~~**仍然缺失**：`userdata`（`/dev/block/sda10`）与 `cache`。~~
**已于 2026-09-16 补齐**（见 [`18-stage0-backup-record-2026-09-16.md`](18-stage0-backup-record-2026-09-16.md)）：
`cache.img`（256 MiB 原始镜像）、`userdata-excluding-rootfs.tar`（275 MB，1048 项，全部文件内容）、
`userdata.img`（26.1 GB 原始镜像，分块读 + 设备端 SHA256 交叉校验），
存放于 `/mnt/data/zl1-backups/2026-09-16-recovery-supplement/`。
同时复核了 31 个备份分区与设备当前分区表：`checked=31 mismatches=0`。

因此 [`00-safety.md`](00-safety.md) 中"备份完成后才允许 flash"的前置条件
**已完全满足**。这意味着计划可以从"只敢 `fastboot boot`"
升级为"可以正规 `fastboot flash boot` + 有回滚路径"。

回滚锚点：设备当前 boot 分区 SHA256 `a06d6508…5778ef`，
与 2026-06-07 备份的 `boot.img` 逐字节相同——即之前所有 session 都从未真正写入过 boot 分区。

### 1.5 `fastboot boot` 是本次适配最大的方法论障碍

`fastboot boot`（RAM boot，不写分区）看起来安全，但实测：

- 非持久：每次都要重来，无法验证"重启后还能不能用"这一最基本的可用性要求
- 会污染状态：反复执行后 userdata/cache/system 累积脏状态
  （见 [`DEVICE-STATE-CORRUPTION-DISCOVERED.txt`](../session-notes/DEVICE-STATE-CORRUPTION-DISCOVERED.txt)，
  同一张 V64 镜像重测时 USB 描述符变成了 "Nexus 4 (fastboot)"）
- 失败时可能掉进 EDL，需要人工断电才能恢复

v64–v67 的"持久化失败"很可能主要是这个方法论问题的产物，而不是镜像本身的问题。
**新版计划的核心改变：停止把 `fastboot boot` 当主力测试手段。**

### 1.6 主机侧 USB 绑定需要人工介入（可自动化）

设备端 gadget 宣告 `bInterfaceClass = 255 (Vendor Specific)`，主机的 `rndis_host`
不会自动 probe，必须手动写 sysfs `new_id` / `bind`，并在有限窗口内配上
`192.168.2.100/24` 与 `10.15.19.100/24`。这一步目前是人工的，是每次实验的
"人为不确定源"。

### 1.7 当前物理状态（2026-09-16 更新）

- 目标设备 `33e80afe` **正在运行 Ubuntu Touch**：boot 分区已刷入 v63
  （`ab574bd3…e57576`），冷启动后 systemd PID1 + RNDIS 稳定 6 分钟以上
- **USB gadget 只有 RNDIS，没有 adb**，所以从主机无法让它重启到 fastboot/recovery；
  要换镜像必须先做一次人工按键（音量下+电源 = fastboot，音量上+电源 = TWRP）
- 总线上同时有无关的 Xiaomi `4a2fe00b`（**必须忽略**，所有脚本按 serial 过滤）
- 回滚镜像（原厂 `boot.img`，SHA256 `a06d6508…5778ef`）校验通过，回刷命令见
  [`scripts/stage2-rollback-boot.sh`](../../scripts/stage2-rollback-boot.sh)
- 构建树产物在位：`/mnt/data/halium-zl1-build/out/target/product/zl1/halium-boot.img`
  = 17,997,824 字节，SHA256 `a29c18db3525e9fdeb4bfcf43053ab305f5e7263dbf743b0380cd1e231c0b1a3`
  （Phase 1 的可复现基线，见 [`19-phase1-reproducible-build.md`](19-phase1-reproducible-build.md)。
  旧的 filtered-DTB 参照件 `cd5cf3c1…` 已被证明不可复现——是那张镜像自己的陈旧 initramfs 时间戳）
- `/mnt/data/halium-zl1-candidates/` 保有 v2–v73 全部镜像共 84 张，清单见
  [`manifests/halium-boot-candidates.md`](../../manifests/halium-boot-candidates.md)
  - 已知可用的 `halium-boot-zl1-v63-usbd-disabled.img`（18,022,400 字节）
    SHA256 `ab574bd3…e57576`
  - 已知坏件 `halium-boot-zl1-v65-production-with-keeper.img`（0 字节）**已删除**
- `/mnt/data` 剩余空间 368 GB，备份目录已含 26.1 GB 的 `userdata.img`

---

## 2. 策略：从"试错"改为"可复现的三件事"

旧计划在问："哪一版镜像能开机？"
新计划要回答的是另外三件事，按依赖顺序：

1. **可复现的构建** — 同一份源码 + 同一组补丁 → 逐字节相同的 `halium-boot.img`
2. **可复现的环境** — 每次实验开始前，设备与主机都回到同一个已知状态
3. **可持久化的安装** — 一次 `flash` 之后，冷启动能直接进入目标状态，不需要 `fastboot boot`

在这三件事落地之前，任何外设（显示、触摸、modem、Wi-Fi、音频、传感器、摄像头）
的调试结果都不可信——因为无法区分"外设没配好"和"这次开机本身就不正常"。

---

## 3. 分阶段计划

### Phase 0 — 设备恢复与基线固化（无风险，先做）

前置：需要人工物理操作让设备退出 EDL（长按电源 15–20 秒断电，再开机）。

> **状态（2026-09-16）：0.1–0.3、0.5、0.6 已完成，0.4 待做。**
> 完整证据见 [`18-stage0-backup-record-2026-09-16.md`](18-stage0-backup-record-2026-09-16.md)。

| 步骤 | 动作 | 验收标准 | 状态 |
| --- | --- | --- | --- |
| 0.1 | 物理退出 EDL，确认设备以 `33e80afe` 出现 | `adb devices` / `fastboot devices` 中 `33e80afe` 在位；**忽略 `4a2fe00b`** | ✅ |
| 0.2 | 补备份 `userdata` 与 `cache` | `sha256sum -c` 全 OK；`userdata` 副本与设备端 SHA256 一致 | ✅ |
| 0.3 | 复核现有 31 个备份与设备当前分区表一致 | `partition-sizes.txt` 与新读取的 `by-name` 逐项大小一致（`mismatches=0`） | ✅ |
| 0.4 | 记录一次原生 Android 冷启动基线 | 完整 `getprop`、`/proc/cmdline`、`dmesg`、`mount` 存档，作为"正常"参照 | ⏳ |
| 0.5 | 确认备份的 `boot.img` 可回刷（dry-run，不实际刷） | 用 `unpack_bootimg` 校验 `boot.img` 结构有效、page size 4096 | ✅ |
| 0.6 | 候选镜像清单 | 0 字节坏件删除；`manifests/halium-boot-candidates.md` 生成 | ✅ |

> 0.2 的目的不是"再多一份备份"，而是让唯一的写入分区也有回滚点。
> 在此之前，任何对 userdata 的写入都是不可回退的。

### Phase 1 — 构建可复现化

现有构建已经成功（见 [`07-build-log-index.md`](07-build-log-index.md)），
但五个 host 侧补丁是手工打的、源码 revision 写在文档里而不是锁在文件里。

| 步骤 | 动作 | 验收标准 |
| --- | --- | --- |
| 1.1 | manifest 冻结到具体 commit | `manifests/halium-9-zl1.xml` 中 6 个仓全部 pin 到 revision（`device/leeco/zl1 c430cb9`、`device/leeco/msm8996-common 9ff1910`、`kernel/leeco/msm8996 c2f6e859`、`vendor/leeco 084763d`、`halium/halium-boot 8656205`、`build/make 1bfc37a`） | ✅ 2026-09-16 |
| 1.2 | 把补丁脚本化并可重复执行 | `scripts/patch-halium9-build-tree.sh` 在干净树上重复执行两次结果一致（幂等） | ✅ 沙箱三次执行 `diff -r` 无差异 |
| 1.3 | DTB 过滤配方固化进构建流程 | `CONFIG_PRODUCT_LE_ZL1=y`、`CONFIG_PRODUCT_LE_X2` 关闭、`CONFIG_BUILD_ARM64_APPENDED_DTB_IMAGE_NAMES` 五个 zl1 DTB 显式列出，不再手工改 | ✅ |
| 1.4 | 一次干净重建并比对 | 产物 SHA256 稳定可复现 | ✅ **`a29c18db…c0b1a3`**（两次 `rm -rf out/` 重建一致）。原定的 `cd5cf3c1…` 经查不可达——参照镜像自带的 initramfs cpio mtime 是陈旧值，见 [`19-phase1-reproducible-build.md`](19-phase1-reproducible-build.md) §2 |
| 1.5 | 清理候选目录清单 | 删除 0 字节镜像；`manifests/halium-boot-candidates.md` 生成（文件名 → SHA256 → 用途 → 已知结果） | ✅ 85 张镜像，v68–v73 已从 `tmp-*/` 归集 |

**1.4 是 Phase 1 的硬门禁。** 构建不可复现，后面所有结论都不可比。
**门禁已于 2026-09-16 通过**，记录见 [`19-phase1-reproducible-build.md`](19-phase1-reproducible-build.md)。
关键修复：`scripts/build-halium-boot.sh` 固定 `KBUILD_BUILD_TIMESTAMP` 等四个变量，
未固定时重建与参照镜像差 99 字节。

> **补充（2026-09-17）**：Phase 1 的可复现产物是 **Stock halium-boot**，从未在设备上跑过；
> 真正能跑的是 v63。两者之间只差 initramfs 里的 5 个条目，现已把这段差距纳入版本管理，
> v63 可以**从仓库源码确定性重建**，且每次重建都自动与 v63 二进制逐内容比对。
> 见 [`24-reproducible-working-image.md`](24-reproducible-working-image.md)。
> 这补上了"可复现的构建"与"能用的安装"之间的缝。

### Phase 2 — 持久化安装与回滚路径

这是本计划与旧计划最大的分歧点：**从这里开始用 `fastboot flash boot`，不再用 `fastboot boot`。**

> **状态（2026-09-21）**：**Phase 2 全部完成。** 2.1–2.3 见下；2.4 做了连续 3 次冷启动
> 且 3/3 一致（[`stage2-coldboot-trials.md`](stage2-coldboot-trials.md)）；
> 2.5 的回滚演练通过（[`38`](38-stage25-rollback-drill.md)）。
>
> 两件在这次推进中才暴露出来的事：
>
> - **判据要落在被评价的对象上。** 2026-09-20 记成"2.4 第 3 次失败"的那次开机，
>   其实是**主机侧没有对端**（14.7 小时里 `rx_packets` 全是 0），设备并没有出问题。
>   见 [`37`](37-the-trial-that-had-no-peer.md)。
> - **设备发包通路偶发卡死（约 1/4 次开机）这件事，仍然没有被证实或推翻。**
>   历史那 6/8 次正常的数据是**有主机在场**时测的，所以那个数字还作数；
>   但那份 14.7 小时的日志不能用来判定它。这一点写在 `37` §7。
>
> Phase 3 的 3.1–3.4 大部分在 `run-stage24-and-25.sh` + `host-watch-usb0.sh` 里已经落地，
> 下一步是 Phase 4（容器运行时）与 Phase 5（显示 / 触摸 / Wi-Fi / 稳定性）。
> 两次冷启动的记录：[`21-stage2-first-cold-boot.md`](21-stage2-first-cold-boot.md)（第一次，容器未起）、
> [`22-stage2-coldboot-results.md`](22-stage2-coldboot-results.md)（补上 `/data/system.img` 之后，容器起来）。

| 步骤 | 动作 | 验收标准 | 状态 |
| --- | --- | --- | --- |
| 2.1 | 确认回滚路径可用 | 备份 `boot.img`（2026-06-07）SHA256 校验通过；记录 `fastboot flash boot` 回刷命令；确认进入 fastboot 的方式（电源+音量减） | ✅ |
| 2.2 | `fastboot flash boot halium-boot-zl1-v63-usbd-disabled.img` | flash 成功，`fastboot reboot` 后**冷启动**直接进入 V63 状态 | ✅ |
| 2.3 | 冷启动验收：不接主机也能起来 | 冷启动后 5 分钟内 `systemd` PID1 在位；接上 USB 后 `rndis0` up、`carrier=1`；Android 容器进程存在（`lxc-info -n android` 或 `pgrep -f lxc-start`） | ✅ 三项全过：systemd PID1、`rndis0` carrier=1 全程不掉、`lxc-start` + 整套 Android HAL 在跑 |
| 2.4 | 连续 3 次冷启动复现 | 3/3 次结果一致（这是旧计划从未验证过的指标） | ✅ 2026-09-21：3/3，每项都过（systemd PID1 / route get ok / 6 条表路由 / 23–24 个 HAL 进程）。记录：[`stage2-coldboot-trials.md`](stage2-coldboot-trials.md) |
| 2.5 | 失败回滚演练 | 人为刷一次坏镜像 → 成功回刷备份 `boot.img` → 设备回到原生 Android | ✅ 2026-09-21：回滚路径成立，设备未变砖，`/data` 现场完好。**但原厂 Android 框架起不来**（zygote 未启动），与演练无关。见 [`38`](38-stage25-rollback-drill.md) |

2.3/2.4 通过，才可以说"zl1 能跑 Ubuntu Touch"。**2.4 已于 2026-09-21 通过。**
2.5 通过，才可以说"这条路线是安全的"。**2.5 已于 2026-09-21 通过**，
保留意见（原厂 Android 自身起不来）见 [`38`](38-stage25-rollback-drill.md) §5。

#### 当前卡点与恢复步骤（2026-09-17）

设备卡在一次**发包通路卡死**的开机里：RNDIS 只暴露 gadget、没有 adb，
状态页取不到，主机侧试过 `modprobe -r/-r`、`unbind/bind`、`authorized` 强制重新枚举，
都无法让它恢复。**需要一次人工按键。**

后台已经在等（`scripts/twrp-one-shot-setup.sh 900 5400`）：

```bash
# 设备：关机，然后按住 音量上 + 电源 进 TWRP
# 之后全自动：misc 备份 → 装 netwatch（记录+自愈）→ 修 SSH → 写 marker → 重启
```

再之后每次开机都会：UT 起来并记录 → 卡死则自愈 → 到点自动回 TWRP。
日志：`scripts/read-netwatch-log.sh`，取证：`scripts/stage2-coldboot-trial.sh`。

想换 boot 镜像时才需要再按一次键（用 `flash-boot-image.sh`）。

> **2.3 的容器缺口不是镜像问题，是设备数据问题。**
> v63 的 initramfs 需要 `/data/system.img`（或 `/data/android-rootfs.img`）来建立
> `/android` 这个 tmpfs；两个都没有时它退化成"在只读 rootfs 上 mkdir"，全部失败。
> 这份 system image 在设备上已经不存在了（2026-06-13 那次启动时还在）。
> 补回去即可，镜像本身不用改：见 [`21-stage2-first-cold-boot.md`](21-stage2-first-cold-boot.md) §4.1。

### Phase 3 — 主机侧 USB/RNDIS 自动化

| 步骤 | 动作 | 验收标准 |
| --- | --- | --- |
| 3.1 | 写 udev 规则自动 bind `rndis_host` | 插线后 `usb0` 自动出现，无需手工 sysfs 写入 |
| 3.2 | 自动配置主机侧 IP | `usb0` 自动获得 `192.168.2.100/24` 与 `10.15.19.100/24` |
| 3.3 | 写一个"等待并验证连通"脚本，替代各版 `watch-and-boot` | 一条命令完成：等待设备 → 等 `usb0` → 配 IP → 探测 `10.15.19.82` HTTP/SSH → 输出 PASS/FAIL |
| 3.4 | 明确"必须忽略 `4a2fe00b`"写进脚本 | 所有设备操作前按 serial 过滤，脚本拒绝在 serial 不匹配时继续 |

3.3 之后，每次实验的"环境"就固定了，才有资格比较镜像差异。

### Phase 4 — Halium 运行时与 Android 容器

| 步骤 | 动作 | 验收标准 |
| --- | --- | --- |
| 4.1 | 统一容器状态判据 | 文档与脚本中不再使用 `lxc-ls`，改用 `lxc-info -n android` |
| 4.2 | 确认 Android 容器在冷启动下的启动时序 | 记录 `lxc-android-config.service` → `start-android-container` → `lxc-start` 的时间线，明确从冷启动到容器 READY 的耗时 |
| 4.3 | 复核 usb-moded 与 NM 静态连接的交互 | 冷启动后 `rndis0` 的 IP 在 10 分钟内不丢；NM 中不存在 `method=shared` 的活动连接 |
| 4.4 | 用 `pre-start.d` 钩子承载实验性改动 | 所有容器侧实验通过 `/var/lib/lxc/android/pre-start.d/` 注入，不改 rootfs 主体（对应 [`16-noble-systemd-lxc.md`](16-noble-systemd-lxc.md)） |
| 4.5 | 复核 netd / IPA / rmnet 的真实影响 | 用「一次只改一个变量 + 冷启动复现 3 次」的方式重测，取代 v64–v67 的快速试错 |

4.5 优先级重新排定：既然 V63 已经能带 Android 容器跑 9 分钟，
"netd 是不是元凶"这个问题已经从"阻塞项"降级为"稳定性优化项"。

### Phase 5 — 基础可用性（能用的最小集合）

按依赖顺序，每一项都要"冷启动后仍成立"：

| 项 | 验收标准 |
| --- | --- |
| SSH | 主机 `ssh root@10.15.19.82` 免密登录成功；冷启动后仍成功（注意 `/root`、`/etc/ssh` 是从 userdata bind-mount 进来的） |
| 显示 | 屏幕点亮，有可见输出（framebuffer 有内容） |
| 触摸 | `evtest` 能看到触摸事件，坐标可用 |
| Wi-Fi | `wlan0` 扫描出 AP 列表 |
| 稳定性 | 连续运行 1 小时不掉网、不重启 |

### Phase 6 — 外设

顺序与优先级沿用 [`NEXT-STEPS-PERIPHERALS-V72.md`](../session-notes/NEXT-STEPS-PERIPHERALS-V72.md)，
但在 Phase 5 完成前不启动：

cellular modem（`rmnet_ipa0` / `qmi`）→ 音频 → 传感器 → 摄像头 → 蓝牙 → GPS

---

## 4. 与旧计划的关键差异

|  | 旧计划（v2–v73） | 新计划 |
| --- | --- | --- |
| 测试手段 | 主力 `fastboot boot`（RAM boot） | 主力 `fastboot flash boot` + 备份回滚 |
| 成功判据 | 某次开机没失败 | 连续 3 次冷启动结果一致 |
| 变量控制 | 一次改多项（usbd + netd + keeper + packaging） | 一次一个变量，冷启动复现 3 次 |
| 容器判据 | `lxc-ls` 显示 `STOPPED` | `lxc-info` / 进程存在性 |
| 环境 | 手工 bind USB、手工配 IP | udev + 脚本自动化 |
| 上游 | 文档里写 revision | manifest 里 pin revision + 幂等补丁脚本 |
| 结论可靠性 | 每轮结论被下一轮推翻 | 构建可复现 + 环境可复现 → 结论可累积 |

v64–v67 尝试的"持久化"方向是对的，失败原因是**在没有可复现环境和可复现构建的前提下**
同时改了太多变量。新计划把这两件事前置到 Phase 1–3，再回到 Android 容器调优。

---

## 5. 安全约束（沿用 [`00-safety.md`](00-safety.md)，仍然有效）

- 不写 `modemst1` `modemst2` `fsg` `fsc` `persist` `modem` `dsp` `bluetooth`
- 任何设备操作前确认目标是 serial `33e80afe`；**`4a2fe00b` 是无关的 Xiaomi 设备，必须忽略**
- Phase 2 允许 `flash boot`（有已校验的备份可回滚），但**不允许** `flash system` / `flash vendor`
- 设备在 EDL 时不要用 QFIL/qfil 类工具刷机
- 大体积源码树与备份留在 notes 仓库之外（见 [`.gitignore`](../../.gitignore)）

---

## 6. 立即要做的下一步

按顺序，前三项都不依赖设备在线：

1. **补 `userdata` 备份**（需要设备在线；Phase 0.2）
2. **冻结 manifest 到具体 revision，把 5 个补丁脚本幂等化**（纯主机侧；Phase 1.1–1.2）
3. **跑一次干净重建，比对 SHA256**（纯主机侧；Phase 1.4）
4. **写 udev 规则 + 统一等待脚本**（Phase 3.1–3.3）
5. 设备恢复到 fastboot 后，执行 Phase 2.2 首次 `flash boot` + 连续 3 次冷启动验收

第 2、3、4 项现在就可以开始，不需要设备。
