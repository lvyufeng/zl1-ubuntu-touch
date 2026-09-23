# 106 — 指纹的修复就是那个没人创建的目录

**日期**: 2026-09-23
**状态**: 纯离线的一轮（设备仍在 Qualcomm EDL，`05c6:9008` / port 3-3，与 `86`–`105` 同）。这一轮把
[`83`](83-the-fingerprint-einval-is-a-missing-directory.md) 的根因**从诊断变成修复**：
新增 `scripts/install-fingerprint-store-dir.sh`，它创建那一个目录——真机上由 `system_server` 创建的、
这台移植上**没有任何人**创建的那个目录——并把它做成每次开机重新推导的持久步骤。它**不是**又一个探针；
这一轮之前在指纹上做过的一切（`83`/`97`/`98`/`101`/`103`）都只是把这个结论变得可信。

**接续**: [`83`](83-the-fingerprint-einval-is-a-missing-directory.md)（根因：缺目录）、
[`97`](97-both-hardware-probes-write-the-wrong-thing.md)（两个候选路径只能有一个）、
[`98`](98-the-fingerprint-chain-has-two-more-layers-under-the-wrapper.md)（wrapper 之下还有两层）、
[`101`](101-which-directory-the-fingerprint-hal-is-handed.md)（biometryd 读的是**UT 侧**的 getprop）、
[`103`](103-the-fingerprint-probe-counted-the-callers-own-line-in-logcat.md)（那条日志属于谁）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 缺的是哪个目录？ | `/data/system/users/0/fpdata`，`0770`，owner = 指纹 HAL 跑的那个 uid |
| 谁本该创建它？ | **`system_server`**。`FingerprintService.updateActiveGroup()`：`fpDir.mkdir()` + `restorecon`，**mkdir 失败就直接 return，连 `setActiveGroup` 都不调**（`frameworks/base/.../FingerprintService.java:1585-1622`） |
| 这台移植上有谁？ | **没有人**。Halium 没有 `system_server`；biometryd 里除了那两个路径常量没有任何 mkdir；`device/leeco/zl1/biometrics/*.rc` 里也没有（只有 sysfs/`/dev` 的 chown/chmod） |
| 所以修复是什么？ | 补上那一步——而且只补那一步 |
| 从哪里写？ | **host 侧**：Android 的 `/data` 就是 `/dev/sda10[/android-data]` 这个普通 rw ext4，host 上是 `/var/lib/android-data`，容器里由 `mount-android-partitions` bind 成 `/data`。同一个文件系统，所以不需要 `nsenter`，容器没起来也能写，也不会被容器的 mount namespace 搞混 |
| 两个候选路径选哪个？ | `/data/system/users/0/fpdata`（`<= 27` 分支）。**但不由脚本硬编码**：applier 每次开机重新跑一遍 biometryd 自己的规则（§5） |
| 会碰别的分区 / 会刷机吗？ | 不会。两个文件写在 `/etc/systemd/system`（可写 bind mount），一个目录写在 Android 的数据分区上 |
| 会重启什么吗？ | 不会。目录本身就是修复，biometryd 是 `Restart=always`，它自己会再试一次 |
| 离线验证？ | `scripts/host/zl1-fp-store-dir-selftest.sh`，**130 检查，0 失败**（§8），并且**四次变异每次都让它失败** |
| 在设备上跑过吗？ | **没有。** 设备在 EDL，恢复只能物理长按电源 10–20 秒 |

---

## 2. 四个来源，按顺序

**(a) HAL —— 两个 `SYS_EINVAL`，只有一个会说话**
`device/leeco/zl1/biometrics/BiometricsFingerprint.cpp:215-228`：

```cpp
if (storePath.size() >= PATH_MAX || storePath.size() <= 0) {
    ALOGE("Bad path length: %zd", storePath.size()); return SYS_EINVAL;   // 会打日志
}
if (access(storePath.c_str(), W_OK)) { return SYS_EINVAL; }               // 完全静默
```

设备日志里 `Bad path length` 一次都没出现，只有调用方那句 `setActiveGroup failed: SYS_EINVAL`——
这本身就是"失败发生在 `access()` 那一支"的证据。

**(b) 调用方 —— 路径是 biometryd 自己挑的**
`halium/biometryd/src/biometry/devices/android.cpp:590-598`：读 `ro.product.first_api_level`，
空则读 `ro.build.version.sdk`，`atoi() <= 27` → `/data/system/users/0/fpdata/`，否则
`/data/vendor_de/0/fpdata/`。框架不给路径，用户也不给——**biometryd 决定**。

**(c) 真 Android —— 由 `system_server` 创建，且失败即放弃**
见上表。目录存在且属于调用方之后，`access(W_OK)` 才通过。

**(d) 这台移植 —— 空的**
上面已经说过：没有 system_server、没有 biometryd 的 mkdir、没有 rc 的 mkdir。

**结论**：挡在 biometryd 和一次成功的 `setActiveGroup` 之间的，**是一个 Android 框架自己会用、
自己会创建的目录**，而这里没有人创建它。修复就是创建它。

---

## 3. 为什么从 host 侧写是对的层级

- `/dev/sda10[/android-data]` 是一个普通 ext4，`stage2-coldboot1-mounts.txt` 里 host 上挂在
  `/var/lib/android-data`；`usr/libexec/lxc-android-config/mount-android-partitions` 把它 bind 到
  `/android/data`，也就是容器的 `/data`。
- **同一份文件系统**，所以 host 路径写进去 = 容器看到的 `/data/...`。不需要 `nsenter`，容器没跑也能写，
  容器的 mount namespace 也干扰不了。
- 它不只是"不是镜像"：它不是 flash，不是 QDL/firehose，也不是禁写的那些分区（`modemst1`/`modemst2`/
  `fsg`/`fsc`/`persist`/`modem`/`dsp`/`bluetooth`）。它只是 Android 一整天都在写的那个分区上的一个目录。
- 反过来说：探针（`device/zl1-fingerprint-probe.sh`）问的是**同一个问题的另一半**——它用
  `/proc/<hal-pid>/root/...` 从 **HAL 自己的 namespace** 去看（因为 `access()` 就是这么算的），
  并且拿 `/proc/<hal-pid>/status` 的 uid 做比较。两边必须一致，`--status` 会检查这一点。

---

## 4. 写什么，不写什么

**立即写一次**（这一次开机也生效）：

```
/var/lib/android-data/system/users/0/fpdata        即 Android 的 /data/system/users/0/fpdata
                                                    mode 0770
                                                    owner = HAL 真在跑的 uid，否则 1000（user system）
```

**持久化**（两个文件，都在 `/etc/systemd/system`，那是可写 bind mount；`/etc` 本身是只读镜像）：

```
/etc/systemd/system/zl1-fp-store-dir.sh             applier
/etc/systemd/system/zl1-fp-store-dir.service        oneshot 单元（enable 过）
```

**刻意不做**：

| 不做 | 为什么 |
|---|---|
| 不创建另一个候选 `/data/vendor_de/0/fpdata` | 两个都建，就会留下一个**永远不会被读**的目录，以及一条只提到其中一个的 undo（`97`） |
| 不 `restorecon` | 它得在容器里跑；`--status` 会打出容器的 `getenforce`，所以这个"不需要"是被检查过的假设，而不是默认 |
| 不 chown 到写死的 uid | applier 从 `HAL` 的 `/proc` 里读真实 uid，读不到才退回 1000 |
| **不把"写成功"当成"修好了"** | `chown` 到一个不存在的 uid 在数值上照样成功；被内核拒绝的 chown 在 `2>/dev/null` 后面静默失败；`access(W_OK)` 看的是**目录自己说什么**，不是你要了什么。所以 applier 会 stat 回来，不一致就 `exit 1`（这就是 cpufreq applier 那一课的复刻，`95`） |
| 不重启任何服务 | 目录本身就是修复；biometryd 是 `Restart=always`，一直在重试（`63` 记过 `NRestarts=2`）。`--install` 只打印"要立刻触发一次重试就打这条命令"，不背着操作者去动 |

---

## 5. applier 的逻辑，以及它为什么每次开机重新推导路径

1. **路径 = biometryd 自己的规则**，每次开机重跑：读 UT 侧 `/usr/bin/getprop` 的同两个 key，同样
   `atoi()`。`atoi("") = 0` 落进 `<= 27`——在本机上这个分支**恰恰是因为那次读是坏的**才被选中
   （`101`：biometryd exec 的是 UT 侧的 `getprop`，而 v63 的 boot hook 把那个文件换成了一个没有
   `custom.*` 分支、对 `ro.*` 也不回答的 shell stub）。
   两个答案在本机**恰好重合**，这正是"写死也不会错"的错觉来源，也正是**不该写死**的理由：getprop 哪天
   开始回答 > 27，applier 跟着 biometryd 走，而 `--status` 会在装上的是另一个目录时说 DISAGREE。
2. **分区检查**：`/proc/mounts` 里没有 `/var/lib/android-data` 就**拒绝创建**并 `exit 1`。否则目录会落到
   只读 rootfs 上，之后每一个检查都会变成关于一个挂载点的谎话。
3. **owner**：扫 `/proc/[0-9]*/cmdline` 找 `biometrics.fingerprint*service`，从它的 `status` 取 `Uid:`；
   找不到就用 1000（`user system`——真 Android 的 `FingerprintService` 跑的 uid，也是设备 rc 要的）。
4. **创建或修复**：`mkdir -p` + `chown` + `chmod 0770`，并且**先记 before 再记 after**——因为
   `ls -ld` 前后不同就是 `REPAIRED` 的证据。
5. **读回**：`stat -c %u` / `%a`，不等于目标的 uid/770 就
   `MISMATCH: ... the directory EXISTS but this is NOT the fix`，`exit 1`。

---

## 6. 单元的顺序（三条，每条都有理由）

```ini
RequiresMountsFor=/var/lib/android-data   # 既排在那次挂载之后，也把本单元的生命周期绑在它上面
After=lxc-android-config.service          # 移植自己的"容器配置就绪"点；它已经间接排在 mount-android-partitions 之后
Before=biometryd.service                  # setActiveGroup 是 biometryd 启动时调的
```

`Type=oneshot` + `RemainAfterExit=yes`（结果事后可读），`ExecStart=/bin/sh /etc/systemd/system/zl1-fp-store-dir.sh`。
applier 是幂等的，所以"起晚了"是一次修复，不是错过窗口。

---

## 7. `--status`（只读）回答的四个问题

1. 单元在不在——用 `systemctl cat`，不是 `is-enabled`（`63`：十七个 drop-in 存在过但从未被加载）。
2. 规则现在选哪条路——把两个 getprop 的**原始回答**连引号一起打出来，所以"为什么是 0"是可见的。
3. **磁盘上的目录是不是这条规则选的那一个**（AGREE / DISAGREE / NEITHER）。
   注：只会 grep applier 文本是**没用的**——applier 是运行时推导路径的，两个字面量永远都在文件里。
4. HAL 那一侧：`/proc/<pid>/root/data/...` 存不存在、owner 和 HAL 的 uid 一不一致、
   `/var/lib/android-data` 挂没挂、biometryd 的 `NRestarts` 与 `setActiveGroup failed` 计数、
   容器 `getenforce`。

---

## 8. 离线验证：130 检查，和四次"必须失败"

`scripts/host/zl1-fp-store-dir-selftest.sh`（证据：`evidence/fp-store-dir-selftest-2026-09-23.log`）。
它没有并进 `zl1-installers-selftest.sh`，因为**它的假设备是另一台机器**：那四个安装脚本都活在 UT rootfs
上，而这一个还需要一台**挂着 Android 数据分区**、有一个**自己的 namespace 的 HAL 进程**、以及一个
**会回答（或在本机上不回答）的 `getprop`** 的设备。除此之外手法相同：假的 `ssh` 就是设备——它剥掉连接
选项，把命令在假根里真跑一遍。

两条本脚本特有的细节，也是它不能共用 harness 的原因：

* 安装脚本用 `cat > FILE` 把载荷放在 **stdin** 上，所以路径映射**只作用于命令、从不作用于载荷**。
  于是落地文件的**内容**可以被断言，而它仍然带着**设备路径**——那么 harness 就必须**拒绝**运行它
  （`99` 第 5 节：跑一个落地 applier 就是拿 host 自己的 `/proc`、`/etc` 当设备）。这个拒绝是**被断言**的：
  把重写副本挪走，`--install` 必须**响亮地失败**（`exit 97`），而不是悄悄量错机器——并且运行后
  host 上 `/var/lib/android-data` 仍然不存在。
* applier 是安装脚本自己调的（`/bin/sh '$APPLIER'`，"running it now"那一步），不是 `systemctl start`，
  所以拦截点在命令上，不在单元的 `ExecStart` 上。

**变异测试**（一个无法失败的 harness 什么也证明不了）：

| 变异 | 结果 |
|---|---|
| 删掉读回（"目录存在"就当成修好了） | `128 pass / 2 fail` |
| 删掉拒绝门（分区没挂也照建） | `127 pass / 3 fail` |
| host 路径少剥一层 `/data`（§9） | `128 pass / 2 fail` |
| applier 里把路径**写死** | `123 pass / 7 fail` |

四个都失败，原版 `130 pass / 0 fail / 2 skip`（两个 skip 是明确的"这是设备事实，本机测不了"：
biometryd 真的传了这条路径、以及 `access(W_OK)` 真会通过）。

---

## 9. 第一版里的真 bug（harness 找出来的）

`--status` 第一版把 host 路径算成 `"/var/lib/android-data$P"`，而 `$P` **本身**就是
`/data/system/users/0/fpdata`——于是拼出来的是 `/var/lib/android-data/data/system/users/0/fpdata`，
**多了一层 `data`**。这个错误是隐形的：目录**永远找不到**，`--status` 会在一个刚刚 `--install` 成功、
目录就摆在那儿的设备上说 "NEITHER exists"。harness 是在"安装之后 AGREE"这条断言上把它抓出来的。
现在 host 路径 = 挂载点 + `${P#/data}`，并且这个算式旁边就写着为什么。

---

## 10. 这一篇**不**证明什么

* **不证明指纹能用了。** 它只证明"该存在的目录会被创建、且创建结果会被读回检查"。后面整条链——
  biometryd 真的传这条路径、`access(W_OK)` 真的通过、`setActiveGroup` 真的返回 0、`gx_fpd` 和更里面那层
  HAL（`98`）愿意买账——**一次都没有在设备上被观察过**。装机后的判据只有一个：
  `journalctl -b -u biometryd | grep -c "setActiveGroup failed"` 变成 0。
* **不证明 SELinux 没问题。** `--status` 打的 `getenforce` 在本机是假设值（stub 给 `Permissive`）。
  真设备上如果是 `Enforcing`，那么 `restorecon` 这一步就不能省，那才是下一步的起点。
* **不是一个"正经"修复。** 它是给一个缺失的 `system_server` 打的补丁，所以它是又多了一块移植状态——
  哪天这套移植长出真正的指纹栈，这个单元应该被**删掉**，而不是因为"它能用"留着。`--remove` 就是干这个的；
  目录**故意不删**，因为真 Android 也会创建它，删掉只会在看起来像一次干净回退的同时把指纹再弄坏一次。

---

## 11. 设备状态

整轮没有动设备：没有写任何分区或 boot，没有跑 QDL/QFIL，没有重启。设备仍在 **Qualcomm EDL**
（`05c6:9008`，port 3-3，无序列号）。识别目标一律按序列号 **`33e80afe`**；总线上另一台小米
**`4a2fe00b`** 必须忽略。恢复仍然只能靠**物理长按电源 10–20 秒**。

回到 RNDIS 之后，指纹这一步的顺序是：先跑 `device/zl1-fingerprint-probe.sh`（拿到安装**前**的
"目录 MISSING"），再 `scripts/install-fingerprint-store-dir.sh --status` → `--install`，然后回到探针看
`setActiveGroup failed` 的计数有没有归零。
