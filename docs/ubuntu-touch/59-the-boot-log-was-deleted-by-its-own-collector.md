# 59 — 坏启动的早期日志，是被采集器自己删掉的：现在它跨启动留存，而"对照"第一次有了工具

**日期**: 2026-09-21
**状态**: 采集方式改了，**根因仍然没查到**。这一篇只做一件事：把 doc 58 §4 要的那个对照**变成可能**，并把 `--bad` 这个查询装上去。第一次跑它就已经把两个 func id 解码查实了。
**接续**: [`58`](58-one-cold-boot-where-the-secure-world-refused-and-three-firmwares-did-not-load.md)、[`52`](52-the-gui-and-touch-confirmed-by-the-user.md)、[`44`](44-the-v63-image-sabotages-its-own-container.md)

---

## 1. 结论先说：doc 58 §4 要的东西现在拿不出来，因为要对照的那一半已经被删了

doc 58 §4 的下一步写的是：

> 值得做的是对照：把坏启动的 `boot-*.log` 和好启动的并排看，找**在 49 秒之前**两边不同的那几行。

做不了。手上两份"坏启动留存件"**都是环缓冲的尾巴**：

| 文件 | 大小 | 第一行 | 最早的时间戳 |
| --- | --- | --- | --- |
| `keep/boot-badgpu-350s.log` | 253732 | `[  288.510545] [<ffffffc0006f5918>] dwc3_endpoint_transfer_complete+0x2e4/0x50c` | 288 s |
| `keep/kmsg-badgpu.log` | 4904879 | `c` | **102 s** |

`kmsg-badgpu.log` 虽然 4.9 MB，但它是 `follow.sh` 一遍遍转储同一个环拼起来的，所以行序并不单调（`grep` 会在第 21454 行找到 103 秒的 `scm_call`，在第 78 行附近却是 269 秒的 WARN），而**它最早也只到 102 秒**。环本身只有 ~3470 行 / ~250 KiB（这个数是 `install-kmsg-drain.sh` 自己量的，写在它的注释里），开机一分钟内就把 `[0.000000]` 那一段卷掉了。

**删掉它的是采集器自己。** `snapshot.sh` 里第一句实质动作就是

```sh
rm -f "$D"/boot-*.log "$D"/boot.log "$D"/now-*.log 2>/dev/null
```

——"每次开机只留本次开机的快照，这样 `--read` 永远不会对不上是哪一次启动"。这个意图没错，代价是：**坏启动在 t=49.6 秒的那些行，doc 58 §2 是直接从一份快照里引出来的**（它当时还在），而**紧接着的下一次开机把它擦了**。等要对照的时候，能留到手上的只有手工 `cp` 出来的两个尾巴。

## 2. 好的一侧是完整的 —— 而且正好盖住失败窗口

这次（好的）启动留下了完整的开头：

```
boot-35s.log   [    0.000000] Initializing cgroup subsys cpuset   ..  [   35.781595]   2022 行
boot-50s.log   [    2.382477] NET: Registered protocol family 17   ..  [   51.032448]   3002 行
```

把失败窗口那几行按时间摊开（`boot-50s.log`）：

```
[   47.070189] init: Service 'qseecomd' (pid 191) received signal 9
[   47.281861] init: starting service 'qseecomd'...
[   47.783937] subsys-pil-tz soc:qcom,kgsl-hyp: a530_zap: loading from 0x8ea00000 to 0x8ea02000
[   47.814071] subsys-pil-tz soc:qcom,kgsl-hyp: a530_zap: Brought out of reset
[   48.191869] subsys-pil-tz 9300000.qcom,lpass: adsp: loading from 0x8eb00000 to 0x90500000
[   48.210642] subsys-pil-tz 1c00000.qcom,ssc: slpi: loading from 0x90500000 to 0x90f00000
[   48.477819] subsys-pil-tz 1c00000.qcom,ssc: slpi: Brought out of reset
[   48.706529] subsys-pil-tz 9300000.qcom,lpass: adsp: Brought out of reset
```

一条 `Invalid firmware metadata` 都没有，没有 `arm_smmu_assign_table` 的 WARNING。也就是说 doc 58 §4 要的对照，**只差坏启动的那一半**。

## 3. 改了什么：`scripts/install-kmsg-drain.sh`

三件事，都是为了同一件事——**别再让证据死在下一次开机上**。

**(a) 跨启动归档。** 开机先归档、再擦：

```sh
set -- "$D"/boot-*.log
if [ -e "$1" ]; then
    prev=$(cat "$K/current-boot-id" 2>/dev/null); [ -n "$prev" ] || prev=unknown
    a="$K/boot-$prev"; n=2
    while [ -e "$a" ]; do a="$K/boot-$prev.$n"; n=$((n + 1)); done
    mkdir -p "$a"; cp -f "$D"/boot-*.log "$a"/ 2>/dev/null
    ls -dt "$K"/boot-*/ 2>/dev/null | tail -n +5 | while IFS= read -r p; do rm -rf "$p"; done
fi
```

目录名用 `boot_id`（`/proc/sys/kernel/random/boot_id`），而 `boot_id` 存的是**上一次**开机的：这一轮跑的时候 `/proc/.../boot_id` 已经换成新的了，所以上一轮结束时把当时的 id 写在 `keep/current-boot-id` 里。留最新 4 个（每个约 1.5 MiB，`/userdata` 还有 11 GiB）。`boot-*/` 这个 glob 不会碰到手工放的 `keep/boot-badgpu-*.log`。

**(b) 坏启动在发生的时候就自保。** 每次快照后 grep 两个签名：

```sh
if grep -qaE "Invalid firmware metadata|scm_call failed.*ret: -12" "$f" 2>/dev/null; then
    mkdir -p "$b"; cp -f "$D"/boot-*.log "$b"/ 2>/dev/null     # 第一次命中：连之前的一起存
elif [ -d "$b" ]; then
    cp -f "$f" "$b"/ 2>/dev/null                               # 之后：同一启动的快照逐个补
fi
```

`keep/bad-<boot_id>/` **不参与裁剪** —— 坏启动很少见，而这是它唯一的一份。这一条是必须的：环在 t≈75 秒那次快照里还留着 t≈49 秒那一段，再晚一分钟就没有了；而如果下一次开机根本没有跑到 `snapshot.sh`，上面的归档也不会发生。

**(c) 早段快照加密**：`for d in 5 10 20 40 80 160` → `5 5 5 10 20 40 80 160`。unit 在 ~35 秒才起来（`After=local-fs.target`，`/userdata` 挂载偏慢），于是采样点是 35/40/45/50/60/80/120/200/360 —— 失败窗口 49 秒前后各有一条。

**(d) `--bad`**：这就是 §4 需要的那个查询，`--status` 也一并报归档。

### 验过没有

先在沙箱里跑三个模拟启动（改 `D` 到临时目录，把 `dmesg` 换成假输出，boot_id 换成 `AAAA-1`/`BBBB-2`/`CCCC-3`）：

```
启动 A（好）        → 无归档
启动 B（好）        → keep/boot-AAAA-1/{S1,S2,S3,S4}.log，boot-*.log 被擦后重写
启动 C（带 -12 签名）→ keep/boot-BBBB-2/…，并且 keep/bad-CCCC-3/ 拿到全部 4 份快照
archive.log         → 2090960 prev=AAAA-1 files=1 / 2090960 prev=BBBB-2 files=1
```

装到设备上之后的实测：

```
archive.log : 622 prev=f527e636-9afd-4b44-9eea-598ed1a3b6a0 files=7
--status    : boot-f527e636-9afd-4b44-9eea-598ed1a3b6a0   7 file(s)  earliest boot-35s.log: [    0.000000]
```

即：**好的那次启动的 t=0 那一份，现在跨启动留下来了**。装之前先往 `keep/current-boot-id` 写了当前 `boot_id`，所以它按真名存，不是 `boot-unknown`。

顺带修了一个自己踩的坑：`--status` 里"earliest"原本写的是 `ls | sort | head -1`，字典序会把 `boot-111s.log` 排在 `boot-35s.log` 前面 —— **正好挑中最没有用的那一份**（唯一带 `[0.000000]` 的恰恰是数值最小的）。改成按文件名里的 uptime 数值排。

## 4. `--bad` 第一次跑，顺手把两个 func id 查实了

在**好的**这次启动里，它印出来的是：

```
[    0.010721] hyp_assign_table is not functional as qcom_secure_mem is not allocated.
[    0.881942] scm_call failed: func id 0x42000c02, ret: -2, syscall returns: 0xfffffffffffffffc, 0x0, 0x0
-- func id / errno tally:  1 func id 0x42000c02, ret: -2
```

两条都在好启动里、都无害，但都值得写下来，因为它们是**下一次看见时不用再追的噪声**：

- `0.010721` 两条来自 `drivers/soc/qcom/secure_buffer.c:261`：

  ```c
  if (!qcom_secure_mem) {
          pr_err("%s is not functional as qcom_secure_mem is not allocated.\n", __func__);
          return -ENOMEM;
  }
  ```

  上下文是 `MSM Memory Dump base table set up` / `MSM Memory Dump apps data table set up` —— 内存转储表在建，比 `alloc_secure_shared_memory()`（`pure_initcall`，第 402 行先 `kzalloc`、失败才退到 `dma_alloc_coherent`）先叫到 `hyp_assign_table()`。同一份日志里**没有** `Couldn't allocate memory for secure use-cases`，所以那个 buffer 后面是分配成功的。这条 -ENOMEM 是**内核自己的 errno**，和 TZ 没关系。
- `0.881942` 在 UFS / `qcom_ice` 初始化中间，`ret: -2` 是 SCM 驱动自己的错误码（不是 secure world 返回的）。

**func id 解码（现在是查过源码的，之前只是从调用点推的）**：

```
include/soc/qcom/scm.h:46   #define SCM_SIP_FNID(s, c) (((((s) & 0xFF) << 8) | ((c) & 0xFF)) | 0x02000000)
include/soc/qcom/scm.h:24   #define SCM_SVC_MP          0xC
drivers/soc/qcom/scm.c:52   #define SMC64_MASK          0x40000000
drivers/soc/qcom/scm.c:650  x0 = fn_id | scm_version_mask;          /* scm_version_mask == SMC64_MASK */
drivers/soc/qcom/secure_buffer.c:51   #define MEM_PROT_ASSIGN_ID  0x16
drivers/soc/qcom/secure_buffer.c:312  ret = scm_call2(SCM_SIP_FNID(SCM_SVC_MP, MEM_PROT_ASSIGN_ID), &desc);
```

代进去：`SMC64 | SIP | (0x0C<<8) | 0x16` = **`0x42000c16`** —— 正是 `hyp_assign_table()` **唯一**的那次 SCM 调用（`secure_buffer.c` 里 `scm_call2` 只有两处，另一处是 `MEM_PROTECT_LOCK_ID2` = `0x42000c0a`）。所以 doc 58 §2 那条 GPU 栈（`arm_smmu_assign_table` ← `kgsl_iommu_init_pt` ← `adreno_start` ← `kgsl_open`）和 `scm_call failed: func id 0x42000c16` 是同一个东西 —— **现在是查实的，不是推的**。

`0x72000206` 不在这一族里：它落在 `SCM_QSEEOS_FNID` 的空间（`scm.h:47`，基址 `0x32000000`），`0x72000206 = SMC64_MASK | SCM_QSEEOS_FNID(0x02, 0x06)`，是 TZOS 服务侧的调用，和 `SCM_SIP_FNID` 那族**不能混为一谈** —— 这一点 doc 58 §2 的表格里没有区分。

### 还有一条：好启动里那两簇 EPERM 正好夹着 qseecomd 的重启

`0x72000206, ret: -1`（EPERM）在好启动里成两簇：`40.454113`（连续 8 条）和 `47.422372`（doc 58 数出全启动 40 条），而中间夹着 §2 里那两行 `qseecomd` 的 signal 9 / restart。

**这很可能就是我们自己干的。** `zl1-container-fix` 的 `apply()` 里就有

```sh
nsenter -t "$A" -p -m -- /system/bin/setprop ctl.restart hwservicemanager
nsenter -t "$A" -p -m -- /system/bin/setprop ctl.restart qseecomd
```

（doc 44 那套反注入的一部分）。**这是时间上的相关性，不是证明。** 要证得看坏启动里这两簇在不在、在什么位置 —— 而这正是 §3 的归档还没攒够的那一半。

## 5. 顺带一起改的：desabotage 的日志现在带 boot id

查 §4 第三条线索的时候发现 `/userdata/zl1-container-fix.log` **不是每次开机都清的** —— 它是追加 + 轮转，所以**一份文件里横跨了好几次开机**，而每行只有 uptime，没有任何东西能说明哪几行属于哪次启动。它当时长这样（9 次开机，格式完全一样）：

```
41.31 sabotage present (st_dev=39, want 1800) — lifting it     ← 每次开机的第一行，41.3–42.7 s
53.76 after apply: st_dev=1800 hwready=true                    ← 53.8–61.9 s
58.93 surfaceflinger came back — stopping it again
60.87 container zygote is running — stopping it (nothing the host needs is a zygote child)
```

**这个时间线本身就是这一篇最有用的一个新事实**：反注入在 **t≈41–42 秒开始、t≈54–62 秒才结束**，而容器那三个固件的 PIL 加载在 **t≈47.8–48.2 秒** —— 也就是**整个落在 `apply()` 中间**，在它已经发过 `ctl.restart hwservicemanager` / `ctl.restart qseecomd` 之后。好启动里 qseecomd 是 47.07 被 kill、47.28 重启、47.77 就开始加载固件 —— **前后只差半秒**。doc 58 §3 说这是"按启动次发生的竞态"，这里是它的机制：**竞态窗口就是这半秒**。

所以现在 `log()` 每行带上 8 位 boot id，并且每次开机写一条 `=== boot <id>: container-fix starting` 分界：

```
f527e636 768.93 === boot f527e636: container-fix starting
```

**这样下一次坏启动就能直接回答 doc 58 §4 的第三个问题**（"坏的那次 desabotage 是不是还没生效"）：`grep <坏启动的 boot_id> /userdata/zl1-container-fix.log` 就能把它那次的 `apply()` 时间线和 PIL 时间线并排放。

（`--install` 对已经在跑的 unit 是空操作，所以装完当场还是老进程写的旧格式；这一篇里重启了一次 `zl1-container-fix.service` 让新格式立即生效并当场验证 —— 副作用是当前这次开机在日志里多了一个分界块，无害。）

## 6. 还不知道的，和现在仍然不该做的

- **secure world 为什么返回 -12，仍然不知道。** 这一篇没有推进到那一步，它只是把"能推进"这件事修好了：上一次是证据还没看就没了，这一次证据会留下来。
- **不因为竞态窗口就是那半秒就去改时序。** doc 58 §4 写的"不预测"继续有效。9 次开机的 `apply()` 时间线（41.3–42.7 / 53.8–61.9）**没有明显的离群值**，也就是说"坏启动 = desabotage 慢了"这个说法**目前并不被这份日志支持** —— 也可能是坏启动的差异根本不在这一层。先拿到坏启动的 t<49 s，再谈。
- 下一步，等下一次坏启动（它是按启动次发生的，会再来）：

  ```
  scripts/install-kmsg-drain.sh --status      # 看 keep/bad-<id>/ 有没有出现
  scripts/install-kmsg-drain.sh --bad         # 看它的 func id / errno 谱
  ```

  然后把 `keep/bad-<id>/boot-*.log`（最早那份）和 `keep/boot-f527e636-…/boot-35s.log` 的**前 49 秒**并排 diff。这是 doc 58 §4 那句话现在终于能执行的形式。
- 顺带记一句状态：`zl1-kmsg-follow.service` 现在是 **active**。它按设计默认关（写 ~90 KiB/s，注释里写了为什么），但坏启动的尾巴 `keep/kmsg-badgpu.log` 就是它留下的，所以这一篇没有关掉它；它自己有 8 MB 轮转上限。

## 7. 这一段改了哪些东西

**设备上**：
- `/userdata/zl1-kmsg/snapshot.sh` 换成新版，`zl1-kmsg-snapshot.service` 重跑了一次。
- `/userdata/zl1-kmsg/keep/` 多了 `current-boot-id`、`archive.log`、`boot-f527e636-9afd-4b44-9eea-598ed1a3b6a0/`（7 份，含 t=0）。
- `/userdata/zl1-container-fix/apply.sh` 换成带 boot id 的新版，`zl1-container-fix.service` 重启过一次（当场验证过新格式）。
- `systemctl --failed` 仍然是 1（`update-machine-info-from-deviceinfo.service`），GUI 正常，两个搬到容器 namespace 的服务正常。

**没有**写任何分区，**没有**动引导镜像，**没有**动容器里的任何东西。
