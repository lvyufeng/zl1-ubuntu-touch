# 18 — Stage 0 记录：备份补齐与基线冻结（2026-09-16）

**设备**: LeEco Pro3 `zl1` / `le_zl1` / `ZL1_NA` / `LEX727`，ADB serial `33e80afe`
**当次环境**: TWRP recovery（不是 Android，也不是 Ubuntu Touch）
**对应计划**: [`17-adaptation-plan.md`](17-adaptation-plan.md) Phase 0

---

## 1. 这次补齐的缺口

[`14-backup-record-2026-06-07.md`](14-backup-record-2026-06-07.md) 记录的分区备份
覆盖 31 个分区，**故意没有备份 `userdata` 和 `cache`**。
而 `userdata` 恰恰是 v2–v73 每次实验唯一的写入目标——没有它的镜像，
"把设备恢复成实验前的样子"这件事在物理上做不到。

本次补上了这两块，加上一份 v63 时期的设备端监控日志。
**所有操作都是只读的：没有向任何分区写入过一个字节。**

---

## 2. 设备环境基线（2026-09-16）

| 项 | 值 |
| --- | --- |
| TWRP | `3.3.1-0`，`leeco/omni_zl1/zl1:9/PQ3A.190705.003/3:eng/test-keys` |
| recovery 内核 | `Linux 3.18.120-lineage-g7df6a19f4b38` (2019-04-16) |
| `ro.product.device` | `le_zl1` |
| `ro.boot.bootdevice` | `624000.ufshc` |
| `androidboot.verifiedbootstate` | `orange`（bootloader 已解锁） |
| `androidboot.selinux` | `permissive` |
| `android.letv.hardware_version` | `dvt1` |
| `androidboot.serialno` | `33e80afe` |

## 3. 回滚锚点：boot 分区当前内容

```
/dev/block/bootdevice/by-name/boot  ->  /dev/block/sde18   (67108864 字节)
sha256  a06d6508499ee37a03effea1e6bec1d04f23843fd44d198a49fb3e07cb5778ef
```

这与 2026-06-07 备份的 `boot.img` **逐字节相同**。两个含义：

1. 之前所有 session 从未真正把镜像写进 boot 分区（`fastboot boot` 不落盘），
   所以设备的 boot 分区至今仍是出厂/Lineage 状态；
2. Stage 2 的 `fastboot flash boot` 有一个**哈希已核验的回滚镜像**
   （`/mnt/data/zl1-backups/2026-06-07-adb-root-staged/boot.img`，
   回刷命令见 [`scripts/stage2-rollback-boot.sh`](../../scripts/stage2-rollback-boot.sh)）。

`boot.img` 结构已用 `unpack_bootimg` 校验（Phase 0.5）：

| 项 | 值 |
| --- | --- |
| magic | `ANDROID!` |
| page_size | 4096 |
| header_version | 0 |
| kernel_addr / ramdisk_addr | `0x80008000` / `0x81000000` |
| kernel_size / ramdisk_size | 13603625 / 2358078 |

## 4. 分区表一致性复核（Phase 0.3）

把 `2026-06-07-adb-root-staged/partition-sizes.txt` 里 31 个备份分区的
设备节点与大小，和本次从 `/sys/class/block/*/size` 重新读到的值逐项比对：

```
checked=31  mismatches=0  missing=0
```

31 个备份分区全部存在、大小完全一致，设备节点路径（`sda2`/`sde18`/`sdf1`…）也没有变化。
分区表自 2026-06-07 起未被改动。

---

## 5. 本次新增的备份

目录：`/mnt/data/zl1-backups/2026-09-16-recovery-supplement/`
校验：`cd` 到该目录后 `sha256sum -c SHA256SUMS`

| 文件 | 字节 | 内容 | 设备端 SHA256 交叉校验 |
| --- | ---: | --- | --- |
| `cache.img` | 268435456 | `cache` 分区原始镜像（`/dev/block/sda3`） | ✅ `374e4cce…f6514` |
| `userdata.img` | 26144878592 | `userdata` 分区原始镜像（`/dev/block/sda10`），见 §7 | ✅ `8a5d2ee8…5ca07` |
| `userdata-excluding-rootfs.tar` | 275565056 | `userdata` 的**全部文件内容**，1048 项，排除 `rootfs.img` | `tar -tf` 通过，1048 项 |
| `zl1-v63-monitor.log` | 7238012 | 设备端 v63 监控日志（40447 行），比仓库里那份 4025 行的副本完整 | — |
| `rootfs-head-device.bin` | 4096 | 设备 `/data/rootfs.img` 前 4 KiB | — |
| `rootfs-head-host.bin` | 4096 | 主机 rootfs 镜像前 4 KiB（对照用） | — |

两个原始镜像的 SHA256 都是**在设备上对分区本体算一遍、再和主机副本比一遍**，
两边完全一致——静默短读无法蒙混过关。

`cache` 是单块 256 MiB 分区，`cache.img` 就是它的完整原始镜像。
`recovery`/`boot`/`system`/`vendor` 等其余 30 个分区在 2026-06-07 已备份。

### 5.1 `userdata` 为什么用 tar 而不是只做镜像

`userdata` 有 26.1 GB，其中 8 GB 是 `rootfs.img`——一个**由主机镜像部署出来**的产物，
不是设备独有数据。真正设备独有、丢了就没了的是 UT 持久层
（`system-data/`、`/root/.ssh`、`sshd_config`、蓝牙配对等），
总共约 275 MB，已完整打进 `userdata-excluding-rootfs.tar`。

## 6. 修正：`rootfs.img` 设备副本与主机镜像的差异已解释清楚

之前发现：设备 `/data/rootfs.img` 的 SHA256（`c1fe27e1…`）与主机
`/mnt/data/ubports-rootfs/24.04-2.x/rootfs-24.04-2.x-arm64-android9plus-zl1-host.img`
的 SHA256（`10af178c…`）不同，但两者 ext4 superblock 的 uuid/label/块数完全一致。
当时判断"可能还有内容差异"，**这个担心是多余的**。

把两边的前 4 KiB 逐字节比对，总共只有 22 个字节不同，全部落在 ext4 superblock 里：

| 文件偏移 | superblock 偏移 | 字段 | 设备 | 主机 |
| --- | --- | --- | --- | --- |
| 1037–1041 | 12–16 | `s_free_blocks_count` / `s_free_inodes_count` | 较少 | 较多 |
| 1069–1077 | 44–52 | `s_mtime` / `s_wtime` | 挂载写入过 | mkfs 时刻 |
| 1162–1172 | 137–147 | `s_last_mounted` | `root` | `mnt/` |
| 2045–2048 | 1020–1023 | superblock 校验和 | 随之不同 | — |
| 52 | 52 | `s_mnt_count` | **25** | **1** |

**结论：两个镜像是同一个文件系统，设备那份只是被挂载并写入过 25 次。**
不存在内容分歧，因此不需要对 8 GB 的 `rootfs.img` 做归档副本——
主机镜像 + 正常使用即可复现。

## 7. `userdata` 原始镜像：分块拷贝

`adb exec-out cat /dev/block/bootdevice/by-name/userdata` 这条路走不通：
试过两次，分别在一份 8 GB 文件拷到 343 MB 和 359 MB 时中断，
而 `adb` 仍然返回 **exit 0**——TWRP 的 adbd 会悄悄掐掉长连接。

改用 [`scripts/stage0-backup-userdata-cache.sh`](../../scripts/stage0-backup-userdata-cache.sh)：
按 512 MiB 分块读（`dd bs=1048576 skip=N count=512`），每块校验落盘长度，
不足则从该块起点重传，最多 5 次。一个连接断掉只损失一个块，不再损失整份拷贝。

收尾时在**设备端**对分区本身算一次 SHA256 作为基准，
与主机副本的 SHA256 比对——这样"静默短读"无法蒙混过关。

结果：设备端与主机端 `8a5d2ee841d17514be74328ac77edac271a8f9900c1a7b44a766121905a5ca07`，一致。
设备端算 26 GB 用了 3 分 21 秒，主机端 3 分 8 秒。

**第一个版本的分块脚本有个 bug，值得记下来**：最后一块按 MiB 向下取整了。
`userdata` 是 26,144,878,592 字节，第 49 块需要 357.7 MiB，
脚本却只请求了 357 MiB，于是整整少读 733,184 字节（716 KiB），
而且五次重试全部"失败"——因为目标值本身算错了。
修正是把每块的 MiB 数**向上取整**：越界读块设备只会得到短读，多要 1 MiB 是免费的。

### 7.1 一条走不通的路

`adb exec-out cat` 这条路也不可用：8 GB 的 `rootfs.img` 试过两次，
分别拷到 343 MB 和 359 MB 时中断，而 `adb` 仍然返回 **exit 0**。

> `dd` 用 `bs=1048576` 而不是 `bs=1M`：这台 TWRP 的 toybox `dd` 不接受 `1M` 后缀，
> 会报 `block size '1M': illegal number`。

## 8. 与计划验收标准的对应

| 计划步骤 | 状态 | 证据 |
| --- | --- | --- |
| 0.1 设备以 `33e80afe` 出现 | ✅ | 全程按 serial 过滤；`4a2fe00b`（小米）被显式忽略 |
| 0.2 补备份 `userdata` 与 `cache` | ✅ | §5 表格，两个原始镜像均与设备端 SHA256 一致，`sha256sum -c` 全 OK |
| 0.3 复核 31 个备份与分区表一致 | ✅ | §4，`checked=31 mismatches=0` |
| 0.4 记录原生 Android 冷启动基线 | ⏳ 未做 | 需要离开 recovery 启动 Android，会中断本次备份；放到 Stage 2 之前做 |
| 0.5 校验备份的 `boot.img` 可回刷 | ✅ | §3，`unpack_bootimg` 校验通过 |
| 0.6 候选镜像清单 | ✅ | [`manifests/halium-boot-candidates.md`](../../manifests/halium-boot-candidates.md)，84 张镜像，0 字节坏件已删除 |

0.4 是唯一未完成项，但它不阻塞 Stage 2：`boot.img` 已核验，
`fastboot flash boot` 的回滚路径完整。
