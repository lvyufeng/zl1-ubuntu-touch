# 117 — 跑不起来的命令不是一个 0

**日期**: 2026-09-24
**状态**: 本轮**没有碰设备**（设备仍在 EDL，见 §6）。全部是 host 侧：一次对 `116` 结论的**核对与推翻**、
一处同一形状的**第二实例**、以及一个让"跑不起来"和"什么都没找到"不再长得一样的机制。**没有在设备上
安装任何东西，没有 flash，没有写分区。**

**接续**: [`116`](116-the-existence-test-that-could-not-be-answered.md)（存在性测试问不出答案 —— 本文
修正它的两处结论）、[`103`](103-the-fingerprint-probe-counted-the-callers-own-line-in-logcat.md)
（logcat 的 fixture 曾经是空的，而断言照样绿）、[`109`](109-an-instrument-that-cannot-report.md)
（一个不能报数的仪器比没有更糟）、[`99`](99-the-remaining-heat-fix-was-broken-offline.md)
（一个静默失败的 applier 不是"暂时"）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 发现/改了什么？ | `116` 说"这个探针从来没有在设备上创建过任何东西"。**那是错的**，本文 §2 用设备自己的 `system.img` 核对后推翻：127 是**逐命令**的，`mkdir`/`chown`/`chmod` 在容器里都有 |
| 那么 `116` 的正确结论是什么？ | `test` 确实是唯一缺失的那一类（mksh 把它做成内建，toybox 的 applet 没装），所以那个 `[ -e ]` 守卫**从来没有生效过**、创建分支**每次都被走到**，而写本身**会成功** —— 也就是说，唯一那个会写的模式不是没写，是**它的守卫是死代码** |
| 还发现了什么？ | **同一形状的第二个实例就在同一个文件里**：两行 `nsenter -p -m -- lshal`（`lshal` 是裸命令，靠 PATH 在容器里解析）。`116` 修完了 `test`，把这两行留下了 —— 而新加的**静态守卫**第一次跑就把它们抓出来了 |
| 新机制是什么？ | `ns_run`：跑不起来时，它把 `NSENTER-EXEC-FAIL: ...` 这一行**印进输出里**，而不是让输出保持空。三个调用点（binder 服务表、logcat、lshal）现在分成"没找到"和"没跑成"两件事 |
| 为什么标记要印进输出？ | 因为每个调用点都是 `x=$(ns_run ...)`，而**命令替换是子 shell**：第一版把失败放进一个变量，探针三个 section 之后死在 `NS_FAIL: parameter not set` |
| 离线验证？ | `zl1-loc-fp-selftest.sh` **195 检查 / 0 失败**（原 181）；跑在 `1ea5185`（`116` 那份探针）上是 **187 通过 / 8 失败**，其中 7 条是新的执行失败场景，第 8 条就是那个静态守卫在抓 `116` 留下的裸 `lshal` |
| 动设备了吗？ | **没有。** 全部只读主机。设备仍在 EDL |

---

## 2. 修正 `116`：127 是**逐命令**的，而那个守卫从来没生效过

`116` 的解释是"容器的挂载表里没有 `/usr/bin`"，于是 `test` 找不到。这句话**关于结果是对的，关于范围
是错的** —— 它暗示"容器里什么都跑不了"，而真相是**逐命令**的，而且可以拿设备自己的镜像核对。

核对的方法是读那个镜像，而不是读日志（这个项目的规矩：读源码，不读日志）：

```sh
IMG=/mnt/data/zl1-backups/2026-06-07-adb-root-staged/system.img   # 设备上的那个系统分区
debugfs -R "stat /bin/test" "$IMG"      # -> 没有
debugfs -R "stat /bin/ls"   "$IMG"      # -> Inode 945, symlink -> toybox
```

**`system.img` 的 applet 目录里**：

| 有 | 没有 |
|---|---|
| `ls`, `mkdir`, `chown`, `chmod`, `ps`, `rmdir`, `rm`, `grep`, `awk`, `sed`, `tr`, `getprop`, `lshal`, `logcat`, `service`, `timeout`, `env`, `date`, `sh` | **`test`**, **`[`** |

原因写在镜像的构成里：Android 的 `mksh` 把 `test` 做成**内建**，所以 toybox 的 `test` applet 没有装；
`/sbin` 在 system-as-root 的镜像里根本不存在，`/usr/bin` 也不是 Android 的路径（这些在 `116` 里是对的，
只是它们不是**区分**那一行代码成败的东西）。

也就是说：**`test -e` 跑不起来，`ls -l` 跑得起来**。而 `PATH` 是调用者的
（UT rootfs 的 `/etc/environment`：`/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:...`），
所以 `nsenter -m` 之后那些名字是在容器的树里找的 —— 找得到 `ls`，找不到 `test`。

### 2.1 被推翻的那个结论

`116` §2 的结尾写的是：

> 唯一那个会写设备的模式也在同一个坑里：它会认为目标目录不存在，然后 `mkdir` 同样以 127 失败。
> 也就是说，这个探针**从来没有在设备上创建过任何东西**。

**`mkdir` 没有以 127 失败** —— 它在那个 applet 集合里。所以真实的行为是：

```
[ -e "$TARGET" ]   (nsenter -m -- test -e)   -> 永远为假
mkdir -p ...       (nsenter -m -- mkdir -p)  -> 成功
chown/chmod                                  -> 成功
ls -ldn           (nsenter -m -- ls -ldn)    -> 成功，所以"now: <正确的 mode>"会印出来
```

这个模式**看起来会完全正确**，而它里面"已经存在"的那条分支是**死代码**：它从来没有说过"已经存在"，
它每次都在重新创建。这不是"它没写"，这是"**它的守卫从来没生效过**"。

### 2.2 那么"有没有留下东西"是一个可以读的问题

`116` 从这里推出来的一句是"探针实际上一直是只读的"，本文把它撤回。剩下的是一个**读数**问题，而答案
已经在手里：2026-09-24 那次抓取里，三条候选路径全部是

```
MISSING  /data/system/users/0/fpdata
MISSING  /data/vendor_de/0/fpdata
MISSING  /data/vendor/biometrics
```

而那次读是走 `/proc/<hal-pid>/root/...` 拿到的 —— 也就是**会答话**的那个机制。`/data` 跨开机存在
（同一块 ext4），所以这是证据：**没有找到任何一次早先的 `--create-store-dir` 留下的目录**，而这三条
路径正是它可能碰的全部。它不能证明"从来没跑过"，只能证明"跑过也没留下东西" —— 后者才是需要担心的
那一半。

---

## 3. 同一形状的第二个实例：`lshal`

`116` 修完了所有 `test`/`ls` 的出现点，但**留下了两行**：

```sh
nsenter -t "$A" -p -m -- lshal 2>/dev/null | grep -ai 'fingerprint' | sed 's/^/   /'
n=$(nsenter -t "$A" -p -m -- lshal 2>/dev/null | grep -aci 'fingerprint')
```

`lshal` 是**裸命令**：它在容器里靠 PATH 解析。它今天能找到（`lshal` 在那个 applet 集合里），所以它
没有坏 —— 但它是**同一类**：一个靠"容器恰好有这个名字"的命令，而它的空输出会被读成一个判断：

```
   (no fingerprint service registered)
```

这句话来自 `grep -c` 得到 0，而 0 有两个来源：**lshal 说没有**，和 **lshal 没跑起来**。这正是 `116`
整篇的主题，只是换了命令名。

本文新加的**静态守卫**在第一次运行时就把它们抓出来了（§5 的 8 条失败里的第 8 条）。守卫的规则是一条
机械的、可以一眼看懂的：**给 `nsenter` 带上 `-m` 的命令必须是绝对路径**，否则它就是在容器的 PATH 里
找东西。`ns_run`（§4）是唯一的例外通道 —— 它的调用点把 flags 作为**带引号的参数**传进去，所以不匹配
这条规则，这是对的：它存在的意义正是"这个调用必须走容器的 PATH，而它的失败会被印出来"。

顺带：这两行原本各跑一次 `lshal`，也就是**两次机会给出不同的答案**。现在是一次调用、读两遍。

---

## 4. `ns_run`：把"跑不起来"印进输出

```sh
dump=$(ns_run '-p -m' /system/bin/logcat -d -v brief)
case "$dump" in
*NSENTER-EXEC-FAIL:*) echo "   COULD NOT RUN: ${dump#*NSENTER-EXEC-FAIL: }" ;;
esac
```

三个调用点，每一种都有一个**本来会被印成结论**的东西：

| 调用 | 空输出本来会被读成 | 现在 |
|---|---|---|
| `service list` | `-> not registered`（Fp::connect 没有对象可谈） | `COULD NOT RUN: ...`，并且**不印**那句判断 |
| `logcat` | 每一条 pattern 都是 0 —— 而 0 在这个探针里**是一个发现**（HAL 的 `access()` 分支不写日志） | `COULD NOT RUN` + "下面的 0 是这个原因，不是 HAL 沉默" |
| `lshal` | `(no fingerprint service registered)` | `COULD NOT RUN` + "这个问题是**没有答案**，不是答'没有'" |

### 4.1 为什么标记在**输出里**，而不是一个变量

第一版写的是"`ns_run` 设置 `NS_FAIL`，调用者读它"。它**在设备上不会工作，在 harness 里也不工作**，因为：

```sh
sl=$(ns_run '-p' /system/bin/service list)     # <- 命令替换 = 一个子 shell
```

子 shell 里设的变量，出到外面就没了。于是探针在**三个 section 之后**死在

```
/tmp/zl1-loc-fp-selftest/fp.sh: 409: NS_FAIL: parameter not set
```

—— 这是 `set -u` 做的一件好事（它把一个静默的空值变成了一个响亮的失败），但它同时说明了为什么"靠
一个变量传递状态"在这种调用形态下是错的。改成把标记**印进被捕获的那段文本**之后，状态活在调用者真正
拿到的东西里，而且它对读输出的人也是可见的。

### 4.2 上一节的教训在这里复现了一次

`116` §6 记过：那个 harness 自己有过"一个因为与脚本无关的原因而绿掉的断言"。这次的静态守卫差点重演：
它原本的 mutant 检查只要求"变异后的副本里**有东西**匹配"，而 `116` 那份探针里**本来就**有两行裸
`lshal` 会匹配 —— 于是这条检查会在一个**与变异无关**的原因下通过。现在它只数**被放回去的那一行**
（`grep -c 'test -f'`），这才是它声称在测的东西。

---

## 5. 离线验证：195 检查，和对 `1ea5185` 的 8 个失败

`scripts/host/zl1-loc-fp-selftest.sh`：**195 检查 / 0 失败**（原 181）。新增的是 7c 一节：

| 场景 | 断言 |
|---|---|
| **一切正常** | 探针**不提**"跑不起来"，并且照样报告 binder 那个问题 —— 这是负方向，防的是"总是印 COULD NOT RUN"也能过 |
| **`service list` 跑不起来** | 印 `COULD NOT RUN: nsenter: failed to execute service list`（**点名那个工具**），且**不印** `Fp::connect has nothing to talk to` |
| **`logcat` 跑不起来** | 印出失败，并说清"下面的 0 是这个原因"；表格**照样印** —— 读者要看到"没读到"，而不是看到一个消失的 section |
| **`lshal` 跑不起来** | 印出失败，且**不印** `no fingerprint service registered`，并说明这是"没有答案" |
| **`lshal` 正常** | 注册那一行**真的**印出来，且不声称"没有答案" |
| **静态守卫** | 发布出去的文件里，**没有任何命令**是在容器的 PATH 里解析的（全是绝对路径） |
| **守卫的牙** | 把那一行改写回 `nsenter -m -- test -f`，守卫**必须**抓到，而且必须抓到**那一行** |

跑在 `1ea5185` 那份探针上（把修复真的撤掉，不是描述一遍）：**187 通过 / 8 失败**，原始输出归档在
[`evidence/loc-fp-prefix117-2026-09-24.log`](evidence/loc-fp-prefix117-2026-09-24.log)；本轮那次绿的
在 [`evidence/loc-fp-selftest-2026-09-24b.log`](evidence/loc-fp-selftest-2026-09-24b.log)。

8 条里 **7 条**是新的执行失败场景（三个调用点各自的失败打印与"不许印的判断"），第 **8** 条是静态守卫
—— 它抓的就是 §3 里那两行 `116` 留下的裸 `lshal`。**一条检查写出来第一次跑就发现了上一轮的漏网，这是
它值得存在的最好证明。**

---

## 6. 这一轮**没有**确定的事

### 6.1 容器的树里，PATH 到底落在哪个目录

镜像里 `/bin` 是真的目录、`/system` 不存在；而设备上 `nsenter -p -m -- /system/bin/logcat` 是**work**的
（2026-09-23 的 GPS 实测有 logcat 内容），所以容器的挂载命名空间里 `/system/bin` 也在。**这两者并不
矛盾，但本文没有确定**容器启动时是怎么摆的（哪一种 bind mount、`/bin` 是不是 `/system/bin` 的同一个
inode）。**结论不需要它**：两个名字指向的是**同一个系统镜像**，而那个镜像里没有 `test`。这一点已经
写进探针的注释，作为"已知的未确定项"，而不是含混过去。

### 6.2 修复**没有在设备上跑过**

`ns_run` 与静态守卫的验证全部是离线的。等设备回来，`116` 那条第一个可检验断言（第 2 节能不能真的
读到 `/vendor/lib64/hw/fingerprint.msm8996.so`）**同时**是这个修复的第一个见证。

### 6.3 两次 EDL 的原因仍然**没有确定**

`116` §6.1 的框架没变：**两次 EDL 前面都是指纹探针，这是两个点的相关性，不是归因**。本文改动的
是其中一条**推理**（"它写不进去，所以不可能是它写的"被推翻了），不是那个结论。现在确定的是：

* 那个写模式**会**写；
* 2026-09-24 的读数（走 `/proc/<pid>/root`）显示它**没有留下东西**；
* 但**没有任何一次读数**能回答"它在崩溃那一刻之前做了什么" —— 那需要设备上的一次运行，而不是一次读。

**所以探针默认跳过（`116` §6.3）这个决定，在这一轮之后依然是凭相关性做的**，只不过程度更清楚了：
现在知道它是一个**会写**的探针，而不是一个只会读的探针。

### 6.4 发烫仍然没有解决

两个发烫修复（退役 v63 debug keeper、cpufreq governor）**都还没装上**，都要等设备。

---

## 7. 下一步

和 `116` §7 一样，顺序不变（本文不改那个顺序，只改了两个探针的**正确性**）：

```
scripts/host/zl1-post-recovery-capture.sh                    # 探针默认跳过
install-netwatch-service.sh --yes --ssh
install-netwatch-service.sh --yes --ssh --activate
zl1-address-owner-proof.sh --yes
install-retire-debug-keeper.sh --install --now --after-proof # 只有 proof-obtained 才杀
install-cpufreq-governor.sh
```

每一步都还没有得到用户的批准；设备在 EDL，唯一的出口是物理长按电源 10–20 秒。
