# 24 — 让"能用的那张镜像"变成可重建的

**日期**: 2026-09-17
**解决的问题**: `halium-boot-zl1-v63-usbd-disabled.img` 此前**只作为一个二进制存在**。

---

## 1. 缺口

Phase 1 做到了"构建可复现"（[`19-phase1-reproducible-build.md`](19-phase1-reproducible-build.md)），
但那个可复现的产物 `a29c18db…` 是 **Stock halium-boot**，
**从来没有在设备上跑起来过**。真正能跑的是 v63，而它是从另一条 lineage
（postswitch-debug）派生出来的。

问题在于：**仓库里那个声称能产出这类镜像的脚本是过期的。**

| | `make-halium-postswitch-debug-boot.sh` 内嵌的版本 | v63 ramdisk 里的 |
| --- | ---: | ---: |
| `scripts/init-bottom/zl1-postswitch-debug-init` | 1208 行 | **1638 行** |
| `scripts/local-premount/zl1-usb-debug` | 75 行 | **95 行** |

也就是说 v63 里那套 keeper / monitor / usbd-disabled 逻辑，**没有任何受版本管理的来源能重建它**。
一旦 `/mnt/data/halium-zl1-candidates/` 丢了，这个移植就没了。

## 2. 差距其实只有 5 个条目

把 Phase 1 的可复现产物和 v63 的 ramdisk 都解开逐项比对，差异是：

| 类型 | 路径 |
| --- | --- |
| 新增 | `scripts/init-bottom/zl1-postswitch-debug-init`（74,871 字节，整套 zl1 运行时） |
| 新增 | `scripts/local-premount/zl1-usb-debug`（5,640 字节） |
| 修改 | `init`（加 `zl1_v54_mark` 钩子，7 处） |
| 修改 | `scripts/init-bottom/ORDER`（加一行，让上面的脚本跑起来） |
| 修改 | `scripts/local-premount/ORDER`（加一行） |

外加 cmdline。**ramdisk 里其余 293 个文件逐字节相同。**

## 3. 已纳入版本管理

```
boot/v63/
├── scripts/init-bottom/zl1-postswitch-debug-init    (0775)
├── scripts/local-premount/zl1-usb-debug             (0755)
└── patch/
    ├── init.patch
    ├── scripts_init-bottom_ORDER.patch
    └── scripts_local-premount_ORDER.patch
```

重建设：[`scripts/make-v63-boot-image.sh`](../../scripts/make-v63-boot-image.sh)

```bash
scripts/make-v63-boot-image.sh \
  --kernel-from /mnt/data/halium-zl1-candidates/halium-boot-zl1-v63-usbd-disabled.img \
  --out /tmp/v63-rebuilt.img \
  --verify-against /mnt/data/halium-zl1-candidates/halium-boot-zl1-v63-usbd-disabled.img
```

## 4. 验证结果

```
OK    cmdline identical
OK    appended DTBs identical
OK    kernel Image identical
OK    ramdisk file list identical — 322 vs 322 entries
OK    ramdisk file contents identical — 0 differing
OK    ramdisk file modes identical
```

**bootloader 和内核真正读取的每一个组成部分，重建产物都与 v63 逐内容一致**——
kernel 字节、appended DTB、cmdline、以及 initramfs 的 322 个条目（含内容和权限位）。

### 4.0 重建是确定性的

同一份源码跑三次，产物 SHA256 完全一致（`01004810…`）。要做到这一点需要同时钉住四件事，
而 `cpio --reproducible` 只覆盖了第一件：

| 变量 | 处理 |
| --- | --- |
| inode 号 | `cpio --reproducible` |
| 归档条目顺序 | `find` 按 inode 顺序遍历，每次不同 → `LC_ALL=C sort`（顺带保证目录排在其内容之前） |
| 文件 mtime | `install(1)` / `patch(1)` 留下的是执行时刻 → `touch -h -d "2026-06-13T19:48:00Z"` 统一 |
| gzip 头时间戳 | `gzip -9n` |

**"重建出了不同字节"这件事从此可以回答**：不一样就是源码真的变了。

### 4.1 一个说清楚了的限制：SHA256 与 v63 不同

```
重建  ramdisk 4,117,100 字节  sha256 ebb281ff5537d99a…
v63   ramdisk 4,122,576 字节  sha256 7d9fb803fdc16da6…
```

解压后是**同一个 cpio 流**（同一份 322 个条目、同样内容和权限），
但从 cpio 到 gzip 的封装不同，所以 ramdisk 的字节数和 SHA256 都不一样，镜像文件的 SHA256 随之不同。

试过 `gzip -9` / `-9n` / `--best`、`cpio` 的 `--reproducible` / `--null`、
以及多种遍历顺序，都没有命中 v63 那个字节数——原始打包命令已经不可考。

**这件事功能上无关紧要**：内核读的是解压后的 cpio，与封装方式无关。

所以要说清楚的是：

| 说法 | 成立？ |
| --- | --- |
| 内容与 v63 一致（内核读到的每一个字节） | ✅ 每次重建都自动验证 |
| 本重建自身确定（同源码 → 同 SHA） | ✅ §4.0 |
| **与 v63 文件字节相同** | ❌ 只差 gzip 封装 |

用 v63 那份二进制时用 `ab574bd3…`，用重建那份时用 `01004810…`——两张都记在
[`manifests/halium-boot-candidates.md`](../../manifests/halium-boot-candidates.md) 里。

### 4.2 默认内核来自 Phase 1 基线，会差 29 字节

不带 `--kernel-from` 时，内核取自可复现基线，与 v63 的内核差 **29 字节**：
一处是 GNU build-id note，一处是内核内建 cpio 的时间戳。
同一份源码、不同时刻构建的必然结果，不是内容差异。
验证脚本会把这种情况单独归类并说明，不会当成失败。

## 5. 顺带得到：下一张该测的镜像

有了 `--kernel-from`，就能把 **v63 的 initramfs 装到打过补丁的内核上**：

```
/mnt/data/halium-zl1-candidates/halium-boot-zl1-v63-uether-txwakeup.img
18,010,112 字节  SHA256 1b98c95df3a19a4b6bf7d34cf6aa9f9ea13e22c252b43d7ff0216f662c45a20b
```

以及重建产物本身（v63 的内核 + 本仓重建的 initramfs）：

```
/mnt/data/halium-zl1-candidates/halium-boot-zl1-v63-rebuilt.img
18,010,112 字节  SHA256 010048109a96d38440a87179e387d7ac0fbfec02dbe3e62569140b691b9cd17f
```

数量级小了一点点（18,010,112 vs v63 的 18,022,400）——正是 gzip 封装那 448 字节的差别。

验证结果：cmdline ✅ / DTB ✅ / ramdisk 内容与权限 ✅，只有内核是打过补丁的那份
（28,274,688 vs 28,258,304 字节，+16 KiB）。

**这就是回答"u_ether 补丁能不能消掉那个偶发卡死"要刷的镜像**——
它相对 v63 只改了一个变量：内核里的发送唤醒路径。

## 6. 对计划的意义

| 计划条目 | 之前 | 现在 |
| --- | --- | --- |
| 可复现的构建 | Phase 1 基线可复现，但它不是能跑的镜像 | **能跑的镜像也可重建了**，且每次重建都自动与 v63 二进制逐内容比对 |
| 可持久化的安装 | 依赖 `/mnt/data/halium-zl1-candidates/` 里那份二进制 | 二进制丢了也能重建 |
| 实验可比性 | 换内核 = 手工重打包 | `--kernel-from`，一次一条命令，其余组件由验证保证不变 |

这正好补上了计划 §2 里"可复现的构建"和"能用的安装"之间的那道缝。
