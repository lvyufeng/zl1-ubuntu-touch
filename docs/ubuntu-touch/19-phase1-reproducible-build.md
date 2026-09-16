# 19 — Phase 1 记录：构建可复现化（2026-09-16）

**目标**: 同一份源码 + 同一组脚本 → 逐字节相同的 `halium-boot.img`
**对应计划**: [`17-adaptation-plan.md`](17-adaptation-plan.md) Phase 1
**构建树**: `/mnt/data/halium-zl1-build`

---

## 1. 结论

**做到了。** 两次独立的完全干净重建（`rm -rf out/`）产出同一个 SHA256：

```
a29c18db3525e9fdeb4bfcf43053ab305f5e7263dbf743b0380cd1e231c0b1a3
17,997,824 字节
```

产物已存档：`/mnt/data/halium-zl1-candidates/halium-boot-zl1-reproducible-20260916.img`

## 2. 计划里写的那个目标 SHA 是错的

[`17-adaptation-plan.md`](17-adaptation-plan.md) Phase 1.4 原本要求重建产物等于

```
cd5cf3c1a715821eb6d63e390abcde4d64bb9f844c52c77ef055c2017fbab109
```

**这个值不可达，而且不是因为构建有问题。** 逐字节比对证明它是那个镜像**自己的**问题：

对 `halium-boot-zl1-filtered-dtb.img`（2026-06-07 15:16 构建）与本次重建产物做三段比对：

| 段 | 结果 |
| --- | --- |
| ramdisk（boot.img 内） | **逐字节相同** |
| appended DTB 区（kernel 尾部 2,044,818 字节） | **逐字节相同** |
| 解压后的 kernel `Image` | 差 29 字节 |

那 29 字节全部来自内核自带的 512 字节 cpio（内置 initramfs，内容只有 `dev` / `dev/console` / `root`），
差异是 cpio 头里的 **mtime 字段**：

| 镜像 | cpio mtime | UTC |
| --- | --- | --- |
| 2026-06-07 那张（A） | 1780836726 | 2026-06-07 **12:52:06** |
| 本次重建（B） | 1780845256 | 2026-06-07 **15:14:16** |

A 的 UTS 版本串写的是 `#3 SMP PREEMPT Sun Jun 7 15:14:16 UTC 2026`，
但它的 initramfs cpio 却是 12:52:06 打的——**早于它自己的构建时刻 2 小时 22 分**。
也就是说 A 里那份 `usr/initramfs_data.cpio.gz` 是 12:52 那次增量构建留下的陈旧产物，
`usr/Makefile` 的 `if_changed` 认为命令行没变就没有重新生成它。

**A 自己就不可复现**，所以拿它的 SHA 当"重建应该命中"的判据是错的。
正确做法是建立一个新的、诚实的基线——就是上面的 `a29c18db…`。

## 3. 根因与修复：两处未固定的时间戳

### 3.1 UTS 版本串（`#3 SMP PREEMPT <date>`）

`scripts/mkcompile_h` 在 `KBUILD_BUILD_VERSION` / `KBUILD_BUILD_TIMESTAMP` 为空时，
分别从对象目录的 `.version` 文件取计数器和用 `date` 取当前时间：

```sh
if [ -z "$KBUILD_BUILD_VERSION" ]; then
    if [ -r .version ]; then VERSION=`cat .version`; else VERSION=0; echo 0 > .version; fi
else
    VERSION=$KBUILD_BUILD_VERSION
fi
if [ -z "$KBUILD_BUILD_TIMESTAMP" ]; then TIMESTAMP=`date`; else TIMESTAMP=$KBUILD_BUILD_TIMESTAMP; fi
```

未固定时，重建与 2026-06-07 镜像差 **99 字节**，分布在 5 处：
版本串本身、内核 `utsname` 的副本、一个 GNU build-id note（20 字节 SHA1），
以及两段位于某个压缩块内部的字节（下游雪崩效应）。

### 3.2 内置 initramfs cpio 的 mtime

`usr/gen_init_cpio.c:529` 默认 `default_mtime = time(NULL)`，
但 `scripts/gen_initramfs_list.sh:303` 会在 `KBUILD_BUILD_TIMESTAMP` 非空时改传 `-t <epoch>`：

```sh
if test -n "$KBUILD_BUILD_TIMESTAMP"; then
    timestamp="$(date -d"$KBUILD_BUILD_TIMESTAMP" +%s || :)"
    ...
    timestamp="-t $timestamp"
```

所以**只要 `KBUILD_BUILD_TIMESTAMP` 出现在构建环境里，这两处就都被固定住**。

### 3.3 修复位置

[`scripts/build-halium-boot.sh`](../../scripts/build-halium-boot.sh) 里 export 四个变量，
默认值取 2026-06-07 那次构建的值，可用环境变量覆盖：

```sh
export KBUILD_BUILD_VERSION="${KBUILD_BUILD_VERSION:-3}"
export KBUILD_BUILD_TIMESTAMP="${KBUILD_BUILD_TIMESTAMP:-Sun Jun 7 15:14:16 UTC 2026}"
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-lvyufeng}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-root}"
```

`KBUILD_BUILD_USER` / `KBUILD_BUILD_HOST` 也固定了：它们的默认值是 `whoami` / `hostname`，
不固定的话换台机器构建版本串就会变。

## 4. 还有一个隐含依赖：`-dirty` 后缀

内核版本串是 `3.18.140-lineage-gc2f6e859-dirty`。这个 `-dirty` 来自
`scripts/setlocalversion` 看到工作区有未提交改动——
即 [`patch-halium9-build-tree.sh`](../../scripts/patch-halium9-build-tree.sh) 留下的三个文件。

**推论：内核树必须保持"恰好被脚本改过、且没有别的改动"这个状态，重建才能命中 `a29c18db…`。**
如果谁 `git checkout` 把三个补丁撤了，版本串会变成不带 `-dirty` 的另一版，SHA 随之改变。

## 5. Phase 1 验收对照

| 步骤 | 验收标准 | 结果 |
| --- | --- | --- |
| 1.1 manifest 冻结到具体 commit | 6 个仓全部 pin 到 revision | ✅ [`manifests/halium-9-zl1.xml`](../../manifests/halium-9-zl1.xml) |
| 1.2 补丁脚本可重复执行（幂等） | 干净树上重复执行结果一致 | ✅ 沙箱跑 3 次，`diff -r run1 run3` 无差异 |
| 1.3 DTB 过滤配方固化 | `PRODUCT_LE_ZL1=y` / `PRODUCT_LE_X2` 关 / 5 个 zl1 DTB 显式列出，不再手工改 | ✅ 已在脚本文本中，且重建的 DTB 区与参照镜像逐字节相同 |
| 1.4 一次干净重建并比对 | 产物 SHA 稳定 | ✅ 两次 `rm -rf out/` 重建同为 `a29c18db…`；原定的 `cd5cf3c1…` 经查不可达，见 §2 |
| 1.5 候选目录清单清理 | 删除 0 字节镜像并生成清单 | ✅ [`manifests/halium-boot-candidates.md`](../../manifests/halium-boot-candidates.md)，85 张 |

## 6. 复现方法

```bash
# 1. 内核树回到"只有脚本补丁"的状态
git -C /mnt/data/halium-zl1-build/kernel/leeco/msm8996 checkout -- \
    arch/arm64/configs/lineage_zl1_defconfig scripts/dtc/Makefile scripts/gcc-wrapper.py

# 2. 重新施加补丁（幂等）
/mnt/data/zl1-bb10/scripts/patch-halium9-build-tree.sh /mnt/data/halium-zl1-build

# 3. 完全干净重建
rm -rf /mnt/data/halium-zl1-build/out
/mnt/data/zl1-bb10/scripts/build-halium-boot.sh /mnt/data/halium-zl1-build

# 4. 应当得到
sha256sum /mnt/data/halium-zl1-build/out/target/product/zl1/halium-boot.img
# a29c18db3525e9fdeb4bfcf43053ab305f5e7263dbf743b0380cd1e231c0b1a3
```

单次干净重建在这台机器（88 核）上约 **2 分 25 秒**。

## 7. 这个产物与"已知可用"的关系

`a29c18db…` 是 **halium-boot 基线**，从来没有在设备上启动过。
已知能在 zl1 上跑起来的仍然是
`halium-boot-zl1-v63-usbd-disabled.img`（SHA256 `ab574bd3…e57576`），
它来自另一条 lineage（postswitch-debug）。

Phase 1 的产物证明了**构建管线是确定的**，这是接下来比较镜像差异的前提；
它本身不是 Stage 2 要刷的镜像。Stage 2 刷的仍是那张已知可用的 v63。
