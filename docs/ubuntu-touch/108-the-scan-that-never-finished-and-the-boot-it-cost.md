# 108 — 那次扫描永远没跑完：它花掉了一次开机，也花掉了那次开机的记录

**日期**: 2026-09-23
**状态**: 第一次真正在设备上跑了 [`107`](107-one-physical-press-buys-one-command.md) 的那条恢复链。它跑完了 `00`–`06`，
但其中 `02` 里的一个 `awk` 在一片 63 MB 的日志上转了 **12 分钟、占满一个核**，随后设备自己进了 Qualcomm EDL。
这一轮修掉那个 `awk`，并把"中断也要留下记录"从一句承诺变成**被测过的行为**。
**全程没有写任何分区、没有跑 QDL/QFIL、没有重启设备**；设备现在仍在 EDL，出来只能靠物理长按电源。

**接续**: [`107`](107-one-physical-press-buys-one-command.md)（那条链本身与它的离线验证）、
[`86`](86-edl-has-a-cause-a-panic-and-the-evidence-survives.md)（pstore）、
[`87`](87-the-container-memory-reading-was-the-whole-phone.md)（kmsg 环形缓冲）、
[`88`](88-the-addresses-are-ours-now-not-only-the-keepers.md)（netwatch 记账 = 退休 keeper 的许可）、
[`94`](94-retiring-the-v63-debug-keeper-is-a-kill-not-a-unit-edit.md)（keeper 的 pid 与 CPU ticks 只在杀之前存在）、
[`76`](76-a-stalled-link-is-a-host-side-problem.md)（链路卡死是主机侧的事）、
[`49`](49-two-cores-that-are-not-tls-wifi-stuck-at-wcnss-and-a-trip-into-edl.md)（EDL 没有软件出口）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 修的是什么？ | `scripts/device/zl1-boot-address-check.sh` 里那段**把整段日志累加进一个字符串**的 `awk`：它是 O(n²)，在设备上跑不完 |
| 为什么从没被发现？ | 因为工作站的 `awk` 是 gawk，它的 `s = s x` 是原地追加。**同一份 36 MB 输入：gawk 0.41 s，mawk 超过 120 s 被杀，busybox awk 超过 100 s** |
| 设备用的是哪个？ | mawk。UT rootfs 里 `/usr/bin/awk` 是符号链接，`/usr/bin/mawk` 存在，`/bin/busybox` **不存在**（`debugfs` 只读查过 rootfs.img） |
| 在设备上的代价？ | `02` 的输出停在 `== netwatch log:` 那一行——**也就是扫描开始的地方**，`== verdict` 从未出现。`awk` 转了约 12 分钟、94 % 一个核、load ~9 |
| 修法？ | **一次流式扫描**（边读边判断，只为最新那段保留它关心的行），加一个 `CAP` 上限；顺带把原来对大文件的三次全量读取变成一次 |
| 修完的第一版对了吗？ | **不对**。第一版边匹配边打印，于是**上一个开机的 ADDRS/HEAL 行泄进了这一次开机的判词**——harness 的场景 C 当场抓住 |
| 那条链现在安全了吗？ | 会写设备的步骤现在跑在**设备侧**的 `timeout -k 5 N` 下（GNU timeout 会给命令单独开一个进程组，超时杀的是**整个组**——这正是那次转 12 分钟的那个子进程需要被处理的方式） |
| 中断了呢？ | `SIGINT/SIGTERM/SIGHUP` 现在**先写 `INDEX.txt` 和 `SHA256SUMS`，再 `exit 3`**。上一次真跑就是被时限杀掉的，`00`–`06` 躺在磁盘上而没有索引、没有校验和 |
| 离线验证？ | `zl1-boot-address-selftest.sh` **18 检查 / 0 失败 / 0 skip**（原来 10 条）；`zl1-post-recovery-capture-selftest.sh` **121 检查 / 0 失败 / 2 skip**（原来 94 条） |
| 变异测试？ | 两个 harness 各 5 次和 3 次变异，**每一次都让它失败**（§6） |

---

## 2. 这次真的跑了，而且那次开机没有被榨干

设备在 `14:55:30Z` 起来（`boot_id 97e4e320-…`，uptime 479 s），`107` 的那条链按顺序跑：

```
14:55  00 identity    keeper pid 812, cpu ticks 2870        <- 杀掉之前才存在的两个数
14:55  01 post-mortem pstore EMPTY                          <- 上一次 reset 没留下 oops
14:55  02 boot-address  ...停在 "== netwatch log:" 这一行   <- 扫描从这里开始，再没回来
15:07  03 keeper --status  
15:07  04 health-check
15:08  05 gps-probe / 06 fingerprint
~15:09 设备自己进了 EDL（USB 上 18d1:d001 -> 05c6:9008）
```

三件事值得单独写下来：

1. **设备自己给出的证据。** `02-boot-address.txt` 的**最后一行是 `== netwatch log: /userdata/zl1-netwatch.log`**，
   也就是那段扫描的入口，而 `== verdict` 一次都没有出现。这一段不是我在主机上推断出来的，是设备在
   那 12 分钟里写下来的东西。
2. **`02` 前面那一半仍然读到了真东西**：netwatch 进程活着（pid 33094，启动 456 s，unit active），
   但**装上去的那份没有 `ensure_addrs()`**。按 `88` 的规矩，这一次开机的地址不是它配的，判词应当是
   `inconclusive` —— **所以 keeper 现在不能退休**（`install-retire-debug-keeper.sh --install` 的许可还没有）。
   同一份输出里指纹那两个候选目录也**都不存在**（`106` 的修复还没 `--install`）。
3. **这一次开机的记录没有留下。** 进程被 600 s 的时限杀掉（exit 143），`00`–`06` 在磁盘上，
   但**没有 `INDEX.txt`、没有 `SHA256SUMS`**——谁也说不清哪个文件是哪一步的。这正是 §5 第一件事的由来。

关于那次 EDL：`dmesg` 里从 `18d1:d001` 断开到 `05c6:9008` 出现只隔 **1.4 s**，是一次 reset。
**我不能说那个 `awk` 就是原因**——只能说明时间上的相邻：扫描 14:55→15:07，链跑完 15:08，设备 ~15:09 进 EDL，
而当时 load 已经到 9、有一个核被占满。真正的判词只能在**下一次开机**的 `01 post-mortem` 里读
（`86`：pstore 只活到下一次 reset）。而 `86` 也说过，pstore 能不能跨 reset 保留**从来没有被验证过**——
`01` 这一次读到的就是 EMPTY。

---

## 3. 缺陷：一个 O(n²) 的 `awk`，和一个看不见它的工作站

原来的写法（`02-boot-address-check.sh` §3）：

```awk
/ netwatch start / { n++; buf=""; next }
{ if (n > 0) buf = buf $0 "\n" }          # 每一行都复制一次已经攒下的全部内容
END { printf "%s", buf }
```

`buf = buf $0 "\n"` 每行都要把已积累的整个字符串复制一遍。**除非 `awk` 对"给自己追加"做了原地优化，
它就是 O(段长²)**。测出来的差别（主机上，36 MB、只有**一个** `netwatch start` 边界，也就是最新段就是整个文件尾部）：

| `awk` | 原写法 | 新写法 |
|---|---|---|
| gawk 5.1 | **0.41 s** | 0.28 s |
| mawk | **> 120 s（被杀，一个字节都没写出来）** | 0.18 s |
| busybox awk | **> 100 s（被杀）** | 0.72 s |

**gawk 是唯一一个不慢的**，而它就是这台工作站上的 `awk`——`scripts/host/*-selftest.sh` 全都在 gawk 下跑过。
这不是"测试不够多"，是**测试跑在了一个和被测环境不同的实现上**，而且差别恰好是决定性的那一个。

为什么最新段会那么大，看日志的形状（`scripts/device/zl1-netwatch.sh` 的 `sample()`）：**每约 5 秒一个
约 1.6 KB 的块**（`===== uptime … =====` 加 iface/gadget/addr/route/arp/counters/container 七小节），
而 `netwatch start` 这个边界**只在服务启动时**才写一行。服务不重启，最新段就是文件的整个尾巴——
63 MB 里可能有十几 MB 是一个开机的。按上面的常数，这正是"十几分钟"那一档。
（设备上那一段的**确切**大小没有被量到：量它的那台设备就是进了 EDL 的那台。）

---

## 4. 修法，以及修法的第一版是错的

现在是一趟流式扫描，只为**最新**那一段保留脚本真正要看的行（`ADDRS`/`STALL`/`HEAL`），并且有上限：

```awk
/ netwatch start / { n++; kept=0; next }
n > 0 && /^[0-9.]+s (ADDRS|STALL|HEAL)/ { if (++kept <= cap) keep[kept] = $0 }
END {
  for (i = 1; i <= kept; i++) print keep[i]      # 只打印最后一段的那几行
  printf "#section boots=%d kept=%d cap=%d\n", n, kept + 0, cap
}
```

保留到 `END` 再打印**不是**旧的那个累加器：`kept` 每个边界清零，所以数组被覆盖、末尾循环忽略陈旧的尾巴，
而且有 `CAP` 封顶——**内存是 O(CAP)，不是 O(段长)**。开机计数也从同一趟里出来，
原来对同一个 63 MB 文件的三次全量读取变成一次。

**第一版就是在这里错的**：它边匹配边 `print`，于是**第一个开机的 `ADDRS:` 行也进了输出**——
而判词只看"最新那一段"，`9.40s ADDRS: …` 来自上一段开机，结果把一个 `inconclusive` 判成了
`netwatch-configured`。而这个错误判词的后果是**授权退休 keeper**，也就是把 SSH 交给一次没被证明过的路径。
harness 的场景 C（"最新一次开机什么也没说，老的那次说了"）就是为这件事存在的，它当场失败。
**修一个缺陷时新引入的缺陷，被一条早就为它写好的断言挡住**——这是这一族 harness 存在的全部理由。

顺带改掉的两处：

* `--help` 原来用 `sed -n '2,33p'` 截头部：一个固定行号范围，头部一长就**静默截断**用法说明
  （`104` 记的就是这个缺陷）。改成"从 `$0` 里读所有注释行"。
* 段文件空了不再等于"服务从没跑过"——现在那两种情况由**头部里的计数**区分，
  而头部读不出来时脚本报的是"日志读不了"，不是"从没跑过"。这也有断言（场景 F/G）。

---

## 5. `capture` 的硬化：两件都是那次真跑教出来的

### 5.1 上界在**设备侧**

```sh
if command -v timeout >/dev/null 2>&1; then
  timeout -k 5 $STEP_LIMIT sh /tmp/$base $args
else
  printf '%s\n' 'NOTE: this device has no timeout(1): THIS STEP IS NOT TIME-BOUNDED.' >&2
  sh /tmp/$base $args
fi
```

用 `timeout`（根文件系统里确实有：`/usr/bin/timeout`）而不是主机的 `timeout ssh`，有两个理由，
第二个是那次事故的直接教训：

* 主机侧的时限只能"不再等它"，设备上的进程照跑——那是反过来的修法；
* **GNU `timeout` 会给命令单独开一个进程组，超时向整个组发信号。** 那次转 12 分钟的是一个**子进程**
  （`sh /tmp/zl1-boot-address-check.sh` 里的 `awk`）；只杀父 shell 会把它留在那儿继续占核。
  `-k 5` 是"再不听就 SIGKILL"。

没有 `timeout(1)` 时**照跑但在自己的输出里说不设上界**，而不是默认静默地不设（`99` 的教训：
一个不存在的护栏必须出声，不能被推断出来）。这条分支是**被执行过**的，不是被读过的：
harness 用一个自己搭的 `PATH` 把 `timeout` 拿掉再跑一遍。

### 5.2 中断也要留下记录

```sh
on_signal() {
  INTERRUPTED=1
  if [ -n "$RB_PID" ]; then kill -TERM "$RB_PID"; sleep 1; kill -9 "$RB_PID"; wait "$RB_PID"; fi
  archive
  printf '\nINTERRUPTED: archived what had run into %s\n' "$OUT" >&9
  exit 3
}
exec 9>&1
trap on_signal INT TERM HUP
```

四个都是被 harness 逼出来的设计点：

1. **`archive` 必须是函数，而且必须在第一个步骤** **之前**定义。上一次的运行死在 `archive` 那一步之前，
   所以那一次的证据没有索引。
2. **长调用必须"后台 + `wait`"**，不能前台。bash 只会在**前台命令结束之后**才处理已捕获的信号；
   信号落在 `wait` 上则立刻处理。主机上量过：`sleep 20` 前台时 TERM 在 **+20.0 s** 才被处理，
   同样的 TERM 在 `sleep 20 & wait` 下是 **+2.0 s**。不这么做，Ctrl-C 就得把那一步等完，
   而那一步的上界是设备侧的 240 s。
3. **处理函数写的字进 fd 9，不进 stdout。** 信号是在某一步正在跑的时候到的，而那一步的
   ssh 带着 `> $step.txt 2>&1`——所以处理函数里的 `say` 会落进**被中断那一步的输出文件**，
   而且是在 `archive` 已经算过校验和**之后**才落进去，于是那份部分档案**自己验不过自己**。
   这一条是 harness 的 `sha256sum -c` 抓出来的。
4. **`${STEP_RC[$i]}` 必须写 `:-`。** `archive` 同时是信号处理函数，信号可以在
   `STEP_NAMES+=(...)` 和 `STEP_RC+=(...)` **之间**到达（也就是一步正在跑的时候）。在 `set -u` 下，
   朴素的 `${STEP_RC[$i]}` 会让整个函数**中断退出**——第一版就是这样写了一个 `INDEX.txt`、
   然后死在写 `SHA256SUMS` 的上一行。现在被中断的那一步会被列出来，rc 一栏是 `?`、
   文件名后面标 `partial: the interrupt landed here`：**"哪一步被切断"本身就是要写进记录的事实**。

`exit 3` 也是一个新码：`1` 是"某一步判词不好"，`2` 是"什么都没跑"，`3` 是"跑了一半，但记录在磁盘上"。

---

## 6. 数字与变异

| harness | 之前 | 现在 |
|---|---|---|
| `zl1-boot-address-selftest.sh` | 10 检查 | **18 检查 / 0 失败 / 0 skip**（`evidence/boot-address-scale-selftest-2026-09-23.log`） |
| `zl1-post-recovery-capture-selftest.sh` | 94 检查 | **121 检查 / 0 失败 / 2 skip**（`evidence/post-recovery-capture-selftest-2026-09-23b.log`） |

一个不会失败的 harness 什么也证明不了，所以两边都做了变异：

| 变异 | 结果 |
|---|---|
| 序列号从"前缀匹配"改回相等 | `119 pass / 2 fail` |
| 去掉设备侧的 `timeout` | `120 pass / 1 fail` |
| 完全不要信号处理函数 | `112 pass / 9 fail` |
| 处理函数里把队列读取的 `:-` 去掉 | `115 pass / 6 fail` |
| 把 `archive` 挪回脚本末尾只调一次 | `114 pass / 7 fail` |
| 把累加器放回 `boot-address` | `11 pass / 7 fail` |
| 去掉 `CAP` 上限 | `17 pass / 1 fail` |
| 改成边匹配边打印 | `17 pass / 1 fail`（另外，真跑中的那一版在场景 C 上是 `16 pass / 2 fail`） |

`boot-address` 那一段的规模测试是有意做成"两半"的：**一半跑真的脚本**（2.3 MB 一段、在 mawk 下必须跑完），
**一半把旧写法单独拿去跑同一份日志**（必须超过 15 s 被杀）。少了任何一半，这条断言都可能在一个
什么都测不出的情况下通过。`capture` 里那两个 skip 是明确写出来的"本机测不了"：两个被调用脚本自己的判词、
以及每一步背后的设备事实。

---

## 7. 这一篇**不**证明什么

* **不证明那次 EDL 是这个 `awk` 造成的。** 只能说时间相邻、当时 load 到 9、有一个核被占满。
  判词在下一次开机的 `01 post-mortem` 里，而它能不能读到，又取决于 pstore 是否跨 reset 保留——
  这一条 `86` 就已经列为未验证。
* **不证明 pstore 保留。** 这一次读到的就是 EMPTY。
* **不证明那条链现在跑得完。** 设备侧的 `timeout` 是新加的，`07` 从来没有跑过，
  `--with-capture` 的写步骤也从来没有跑过。
* **不证明 keeper 可以退休。** 恰恰相反：`02` 读到的那半段说装上去的 netwatch **没有 `ensure_addrs()`**，
  所以许可还不存在。
* **不证明设备能回来。** 出来仍然只能物理长按电源 10–20 秒（`49` §6），没有任何 QDL/firehose 工具会被跑。

---

## 8. 设备状态

设备在 **Qualcomm EDL**（`05c6:9008` / `QUSB__BULK`，port 3-3，无序列号）。
整轮只读过：`lsusb`、`/sys/bus/usb/devices`、`dmesg`、以及 `ubports-rootfs/rootfs.img`（`debugfs` 只读）。
**没有写任何分区或 boot，没有跑 QDL/QFIL，没有重启，没有拔插。** 识别目标一律按序列号
**`33e80afe`**（前缀匹配——gadget 报的是 `33e80afe-v63-usbd-disabled-rndis`）；总线上另一台设备
**`4a2fe00b`** 必须忽略。

下一步只能是物理的：**长按电源 10–20 秒**，等 RNDIS 回来，然后

```sh
scripts/host/zl1-post-recovery-capture.sh
```

这一次运行本身就有两处不同：`02` 不会再转 12 分钟，而 `01` 读的 pstore 正是**这一次**进 EDL 留下的那一份。
