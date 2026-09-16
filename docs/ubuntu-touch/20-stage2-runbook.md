# 20 — Stage 2 操作手册：持久化安装 v63 与冷启动验收

**对应计划**: [`17-adaptation-plan.md`](17-adaptation-plan.md) Phase 2
**前置**: Stage 0 完成（[`18-stage0-backup-record-2026-09-16.md`](18-stage0-backup-record-2026-09-16.md)）
**核心改变**: 用 `fastboot flash boot`，不再用 `fastboot boot`

---

## 1. 为什么要改

`fastboot boot` 是 v2–v73 的主力测试手段，也是那些 session 收效甚微的原因
（计划 §1.5）：不落盘、每次都从头来、反复执行会累积脏状态、两次把设备掉进 EDL。

Stage 2 要回答的是旧计划从未验证的问题：
**一次 `flash` 之后，冷启动能不能直接进入目标状态？**

## 2. 本次要刷什么

| | 镜像 | 字节 | SHA256 |
| --- | --- | ---: | --- |
| 目标 | `/mnt/data/halium-zl1-candidates/halium-boot-zl1-v63-usbd-disabled.img` | 18,022,400 | `ab574bd337fa8dfe25b21b90bb8bc9ea39a1ea12907d286bed788e8f92e57576` |
| 回滚 | `/mnt/data/zl1-backups/2026-06-07-adb-root-staged/boot.img` | 67,108,864 | `a06d6508499ee37a03effea1e6bec1d04f23843fd44d198a49fb3e07cb5778ef` |

回滚镜像是**当前设备 boot 分区的逐字节副本**（2026-09-16 现场核对，
见 [`18-stage0-backup-record-2026-09-16.md`](18-stage0-backup-record-2026-09-16.md) §3），
所以回刷它 = 回到实验前的状态。

v63 的 cmdline：

```
androidboot.hardware=qcom ehci-hcd.park=3 lpm_levels.sleep_disabled=1
cma=32M@0-0xffffffff androidboot.configfs=true apparmor=1 security=apparmor
firmware_class.path=/vendor/firmware_mnt/image loop.max_part=7
init=/tmp/zl1-debug-init zl1_init_delay=30 zl1_usb_fakebind=v63
zl1_v63_monitor=1 zl1_v63_usbd_disabled=1 zl1_packaging=v63
```

注意**没有 `datapart=`**，这是刻意的：v63 的 initramfs 钩子
（`scripts/local-premount/zl1-usb-debug` + `scripts/init-bottom/zl1-postswitch-debug-init`）
自己做 USB 和 keeper，并把 `zl1-v63-monitor` 与一个 HTTP 状态服务装进 rootfs。

## 3. 设备侧前置状态（已核对）

| 项 | 值 | 核对时间 |
| --- | --- | --- |
| `/data/rootfs.img` | 8,589,934,592 字节，ext4，label `UBPORTS_ROOTFS` | 2026-09-16 |
| rootfs 内的 NM 静态连接 | `rndis-static.nmconnection` / `usb0-static.nmconnection`（IP `192.168.2.15/24`、`10.15.19.82/24`） | 主机镜像内已确认 |
| `userdata` | ext4，label `data`，uuid `5a796cbd-934f-429c-af2a-26e6998a119b` | 2026-09-16 |
| boot 分区 | 未改动，SHA256 `a06d6508…` | 2026-09-16 |

## 4. 执行

设备当前在 TWRP，所以走 `adb reboot bootloader`。

```bash
/mnt/data/zl1-bb10/scripts/stage2-flash-boot-and-verify.sh --yes
```

脚本自己会做这些检查，任何一条不过就直接退出、不碰设备：

1. 回滚镜像存在且 SHA256 == `a06d6508…`
2. v63 镜像存在且 SHA256 == `ab574bd3…`
3. 目标 serial `33e80afe` 在 adb 或 fastboot 里可见（无关的 `4a2fe00b` 被显式忽略）
4. 从 adb `reboot bootloader`，等 fastboot 出现
5. `fastboot flash boot`，`fastboot reboot`
6. 等设备宣告 USB gadget `18d1:d001` → `sudo modprobe rndis_host` → 等 `usb0`
7. 给 `usb0` 配 `192.168.2.100/24` 与 `10.15.19.100/24`
8. ping `192.168.2.15` 和 `10.15.19.82`
9. `curl http://10.15.19.82:8080/`

退出码 0 的条件是 **两个 IP 都 ping 通且 HTTP 有响应**。

日志写在 `/mnt/data/zl1-bb10/stage2-flash-<UTC时间戳>.log`。

## 5. 验收标准（计划 2.3 / 2.4）

冷启动后，**不接主机也要能起来**；接上主机后：

| 检查 | 期望 |
| --- | --- |
| systemd | PID 1 在 `/usr/lib/systemd/systemd` |
| Android 容器 | `pgrep -f lxc-start` 有结果，**不要用 `lxc-ls`**（见计划 §1.2） |
| Android 用户空间 | 进程表里有 `logd` / `servicemanager` / `vndservicemanager` |
| RNDIS | 主机 `usb0` 拿到 IP，`ping 10.15.19.82` 通 |
| 状态服务 | `curl http://10.15.19.82:8080/` 返回状态页 |

**2.4 要求连续 3 次冷启动结果一致**——这是旧计划从未验证过的指标。
每次冷启动之间：`adb reboot`（或断电重开），等设备重新宣告 gadget，再跑一次验证。

## 6. 失败时怎么办

### 6.1 刷完起不来（没有 `18d1:d001`）

不要慌。boot 分区只影响启动，不影响任何其他分区。两条路：

**A. 从 fastboot 回刷**（设备还在 fastboot 时最快）

```bash
/mnt/data/zl1-bb10/scripts/stage2-rollback-boot.sh --yes
```

**B. 从 TWRP 回刷**（fastboot 进不去时）

```bash
adb -s 33e80afe push /mnt/data/zl1-backups/2026-06-07-adb-root-staged/boot.img /tmp/boot.img
adb -s 33e80afe shell 'dd if=/tmp/boot.img of=/dev/block/bootdevice/by-name/boot'
```

### 6.2 进了 fastboot 但 `fastboot flash` 失败

先看 `fastboot getvar partition-size:boot` 是否是 67108864。
不要改刷别的分区。直接走 §6.1 的 B。

### 6.3 掉进 EDL（`05c6:9008`）

需要长按电源 15–20 秒断电再开机。**不要**用 QFIL 之类的工具刷机。

### 6.4 绝对不要做的事

- 不要 `fastboot flash system` / `flash vendor` / `flash userdata`
- 不要碰 `modemst1` `modemst2` `fsg` `fsc` `persist` `modem` `dsp` `bluetooth`
- 不要 `fastboot erase` 任何分区
- 不要在 serial 不是 `33e80afe` 的设备上执行任何写操作

## 7. 记录模板

```text
Stage 2 run — <date>
flash:  halium-boot-zl1-v63-usbd-disabled.img  ab574bd3…
result: flash OK / reboot OK / gadget 18d1:d001 seen at <t+Ns>
        usb0 up, ping 192.168.2.15 OK / ping 10.15.19.82 OK / HTTP 8080 OK
cold boot #1: <result>
cold boot #2: <result>
cold boot #3: <result>
```
