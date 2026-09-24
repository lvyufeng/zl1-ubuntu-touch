# 115 — 替换一个文件不会改变一个进程

**日期**: 2026-09-24
**状态**: 这一轮**碰了设备**。设备被从 EDL 里救回来一次（用户物理长按电源），启动正常、RNDIS 回来了、
ssh 通了；随后**在抓取证据的第 06 步（指纹探针）又一次掉进 EDL**（§7）。故障原因未定，本轮**没有**在
设备上安装任何东西，也没有 flash 任何分区。

**接续**: [`111`](111-netwatch-over-ssh-and-the-twrp-step-that-bought-nothing.md)（netwatch 可以走 ssh 装，
TWRP 那一步什么也没换来）、[`112`](112-the-gate-is-a-race-and-it-ends-when-the-keeper-does.md)（许可是
`zl1-address-owner-proof.sh` 的 `proof-obtained`）、[`114`](114-the-refusal-gate-was-satisfied-by-the-process-it-removes.md)
（退役 keeper 的闸门现在问替代品）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 发现/改了什么？ | `install-netwatch-service.sh` 新增 `--activate`：**让已部署的那份构建在这一次开机上就变成正在跑的那份，并且证明它确实是** |
| 为什么需要它？ | 覆盖一个文件不会改变一个进程。`--ssh` 之后，**部署的**文件有 `ensure_addrs()`，而**写日志的那个进程**还是旧构建 —— 于是地址归属证明测的是**旧构建**，退役闸门会照旧拒绝，而 `--status` 会显示"替代品已部署、带函数、active"：**两个事实，两个不同的对象** |
| 它省掉了什么？ | **一次重启。** `111` 那条链里"装完必须重启，新构建只有开机才生效"这一步，现在可以换成一次 ssh 往返 |
| 为什么这值得做？ | 在这台设备上**一次开机不是免费的**：每一次开机都可能以 EDL 结束，而离开 EDL 要用手按住电源键 10–20 秒。这台机器在 2026-09-23 和 09-24 各掉进去过一次（§7） |
| 怎么证明"换掉了"？ | `systemctl restart` **不是证据**。所以：重启前后各读一次 `ExecMainStartTimestampMonotonic`（微秒，自本次开机）与 `/proc/uptime`，要求**前者严格晚于后者**。两个都是单调时钟，所以设备那个坏掉的墙上时钟（已经把 journalctl 的排序搞坏了）在这里插不上手 |
| 读不出来怎么办？ | **失败，不假设。**（`99`：一个不能报数的仪器比没有更糟） |
| 离线验证？ | `zl1-installers-selftest.sh` **375 检查 / 0 失败**（原 336），新增第 14b 节，七幕覆盖每一条能出错的分支（§5） |
| 这一轮自己捅的两个洞？ | 都在**那个不引号的 heredoc** 里：一个反引号让 harness 挂满整个 timeout；一个没转义的 `$1` 让 `set -u` 直接中止 `cat`，于是 stub 根本没被写出来，**第 1–13 节的 57 条检查一起红**（§6） |
| 动设备了吗？ | 是。一次物理长按（用户做的）把它从 EDL 救回来；**没有 flash、没有 QDL/firehose、没有写任何分区**；随后它在指纹探针那一步又掉回 EDL（§7） |

---

## 2. 缺陷：`--ssh` 之后，部署的和在跑的不是同一个东西

`111` 的链路是：

```
install-netwatch-service.sh --yes --ssh   →  重启  →  zl1-boot-address-check.sh
```

"重启"那一步在 `111` 里是有理由的，而且理由是对的：`--ssh` **故意不重启**任何东西。原因是 `sh` 是
**边跑边从文件里读脚本**的，所以在活着的 watchdog 底下 `cat > $DEST` 会把文件截断、让它接着执行刚
送到的字节。于是 `--ssh` 的做法是写 `$DEST.new`、在设备上读回来核对、再 `mv`（rename(2)）就位 ——
**跑着的 shell 抓着旧 inode 把旧构建跑完**。

这个设计是对的，但它有一个副作用：**在下次开机之前，"已部署"和"正在跑"是两回事。**

而 `114` 之后，退役 keeper 的闸门问的正是这两个问题的**合取**：

```sh
replacement_ready() {
    [ -x "$NETWATCH" ] || return 1                     # 文件在（已部署）
    grep -q '^ensure_addrs()' "$NETWATCH" || return 1  # 能力在（看的是文件）
    [ "$(systemctl is-active "$NETWATCH_UNIT")" = active ] || return 1   # 在跑（问的是进程）
    return 0
}
```

第三个条件在 `--ssh` 之后立刻为真 —— **那个 unit 从来没停过**。于是：

* 闸门放行；
* 地址归属证明（`112`）会**失败**，因为它停掉 keeper 之后，真正在跑的旧构建根本不会去 `ensure_addrs()`；
* 而如果跳过证明直接杀 keeper，**地址就没了**。

也就是说：这不是"证明会误判"，而是**证明这一步会正确地拒绝一个闸门会正确地放行的配置**。两者用的
是同一份文件，读到的却是两个不同时代的真相。

---

## 3. `--activate`：把它变成同一个东西，并证明

```sh
systemctl restart zl1-netwatch.service
```

就这一条。但**"我重启了"不是证据** —— 一个 `restart` 可以什么都没做（unit 没加载、进程是别的东西、
systemd 状态和现实不一致）。所以这个模式**读回来**：

```sh
u=$(cut -d" " -f1 /proc/uptime)                    # 重启前
systemctl restart zl1-netwatch.service
# 等 active
mono=$(systemctl show -p ExecMainStartTimestampMonotonic --value zl1-netwatch.service)
```

然后要求 `mono > u * 1000000`。

### 3.1 为什么这一步是**决定性的**，而不是"很可能"

它把两个各自都不够的事实合起来：

1. **部署的文件带 `ensure_addrs()`** —— 这是在设备上对**那个文件**问的（`grep -q '^ensure_addrs()' "$DEST"`），
   不是对仓库里的源文件问的；
2. **正在跑的主进程在这次重启之后才启动** —— 所以它读的就是那个文件。

`sh` 在执行**前**从文件里读脚本（这就是 `111` 那条 rename(2) 的道理所在），所以"进程在文件就位之后
才启动"蕴含"它读的是那份文件"。**缺任何一条都不成立**，这也是为什么第一条单独会误判（旧构建没有函数，
但文件有），而第二条单独毫无意义（它只说明进程是新的）。

### 3.2 单调时钟

时间戳是**微秒、自本次开机**。设备的墙上时钟是坏的（`zl1-device-clock-breaks-journal-queries`：它已经
把 journalctl 的排序搞坏了），如果拿 `date` 去比，这次检查会变成一个关于墙钟的检查。两个单调值相减
就绕开了整个问题。

### 3.3 三种失败，三个不同的退出方式

| 情况 | 行为 |
|---|---|
| 读不到 `ExecMainStartTimestampMonotonic` | **exit 1**，明说"读不出来，所以不声称"。`99` 那条规则：一个不能报数的仪器比没有更糟 |
| 时间戳**早于**重启前的 uptime | **exit 1**，说这是**旧构建的幸存者**，部署的那份不是正在跑的那份 |
| 服务没能回到 active | **exit 1**，并且明说**重启不是重试**（"重启会用同一个构建起来"），因为那意味着这是构建的问题，不是这一次重启的问题 |

第三条是一句**省下一次开机**的话：如果没有这句，操作者会以为"再开一次就好了"。

### 3.4 它是一个**独立的模式**，不是 `--ssh` 的新默认

`--ssh` 单独用**仍然什么都不重启**（第 14 节有一条断言守着这件事，本轮新加）。理由写进了头里：
替换一个文件和重启一个服务是**两件不同的事**，有不同的失败模式；而重启恰恰是安装路径刻意不做的那
件事。顺带：参数里现在**只允许一个模式**，`--remove --noheal` 这种以前"最后一个赢"的写法现在是拒绝。

---

## 4. 它**不**证明什么

* **不证明这次开机的排布是对的。** unit 起得够不够早、在容器之前拿到地址 —— 只有一次**没有 keeper 的
  开机**能回答（`112` §3）。`--activate` 只回答"跑的是哪份代码"。这句话现在**也打在脚本输出里**，
  不只是写在头里。
* **不证明重启之后它不会立刻捣乱。** 新构建带自愈，自愈会重枚举 USB gadget —— 那会**打断下一步要用的
  那条 ssh 连接**。脚本里写了：它要 90 秒（`SETTLE_SECONDS`）才动手，而且要 TX 冻住 45 秒；所以实操
  规则是"等 90 秒，再跑证明"。
* **不证明 keeper 可以退役。** 那是 `114` 的闸门 + `112` 的证明。
* **没有在真机上跑过 `--activate`。** 这一轮设备活了大约 7 分钟，但那 7 分钟里跑的是抓取脚本；§7。

---

## 5. 离线验证：375 检查，第 14b 节

`scripts/host/zl1-installers-selftest.sh`：**375 检查 / 0 失败**（原 336）。14b 的七幕：

| 幕 | 断言 |
|---|---|
| **不给 `--ssh`** | exit 2，理由说的是"没有 systemd 可以重启"，而**不是**先去探测 adb 然后说"33e80afe 不在 adb 里"——那句是真的，而且与被拒的原因无关（会把操作者送去 TWRP 做一件在 adb 上本来也不会成立的事）。有一句 `notwant` 守着这个 |
| **部署的是旧构建** | exit 1，点名缺的函数，并且说清"退役闸门问的是同一个问题"，**且没有重启它** |
| **什么都没部署** | exit 1，点名，并给出能部署的那条命令 |
| **没有已验证的 misc 备份** | exit 1 —— 理由是关于**被启动的那个服务**（它能往 misc 写 `boot-recovery`），不是关于传输方式 |
| **happy path** | 真的调了 `systemctl restart zl1-netwatch.service`；报告了单调比较；给了 90 秒的警告；交棒给证明；**并且说出自己没证明什么** |
| **重启没有生效**（进程是幸存者） | exit 1，点名那个比较，说明"部署的不是正在跑的"，**且不声称成功** |
| **仪器读不出来** | exit 1，点名读不出来的那个值，**且不声称成功** |
| **服务没回到 active** | exit 1，并说"重启会用同一个构建起来"，所以这不是重试 |

外加一条守 `--ssh` 单独用**仍然不重启任何东西**的断言：**替换文件和重启服务保持分开**，操作者必须
开口要。

### 5.1 三个 fixture，各自都能出错

* `$W/netwatch-mono`：`show -p ExecMainStartTimestampMonotonic` 的答案，是一个**可写文件**而不是常量
  —— 在真机上这个数每次重启都变，一个不会变的 fixture 测不了读它的那个检查；
* 它的**默认值是"幸存者"**（5 s，早于这台假设备的 100.0 s uptime），也就是**默认落在失败的那一侧**：
  要通过的场景必须真的重启一次才能拿到；
* `$W/netwatch-nomono` 让它回答 `n/a`，`$W/netwatch-stale` 让它回答一个早于重启的值。

`env_reset` 每次都清掉这三个 —— 否则上一幕留下的"晚于重启"的值会让下一幕的检查**因为一个与脚本无关
的原因**通过。

### 5.2 为什么要给 netwatch 单独一条 stub 分支

`zl1-netwatch.sh` 是 `while :; do ensure_addrs; sleep 2; done`。`sleep` 被 stub 成瞬时，所以**执行它
等于跑满一个核**、把 harness 挂死。所以这一个 unit 的 `restart` 由 stub 直接模拟两台事实（active +
一个启动时间戳），而不是去跑它。这件事本身值得记下来：**fixture 有时候必须模拟，而不是执行。**

---

## 6. 这一轮自己捅的两个洞，都在同一个 heredoc 里

那个生成 `systemctl` stub 的 heredoc 是**不引号**的（`<<EOF`，因为它要展开 `$FR`、`$W`、`$STUB`），
所以里面的反引号和裸 `$` 都是**在写文件的时候求值**的。文件里早就有一条注释专门警告这件事 —— 而我
在同一段里连踩两次：

### 6.1 反引号 → harness 挂死

我写了一句注释：`` zl1-netwatch.sh is `while :; do ensure_addrs; sleep 2; done` ``。反引号 =
命令替换，于是 harness **真的去执行了那个循环**：`sleep` 是 stub、瞬时，`ensure_addrs` 不存在，
所以它一边刷 `ensure_addrs: not found` 一边**跑满一个核直到 `timeout` 把它杀掉**。现象是"harness 没有
输出"。

修法：注释里不许有反引号，改用单引号引用，并把踩坑这件事写进那条注释本身。

### 6.2 裸 `$1` → 整个 stub 没被写出来

我用 `awk '{printf "%d\n", ($1 + 2) * 1000000}'` 去算"比重启前的 uptime 晚 2 秒"。那个 `$1` 是不
引号 heredoc 里的**位置参数**，而 harness 是 `set -u`、运行时没有参数 —— 于是：

```
scripts/host/zl1-installers-selftest.sh: 241: 1: parameter not set
```

`set -u` 下这个展开**中止整个 `cat`**，所以 `$STUB/systemctl` **根本没被写出来**，`systemctl` 变成
"command not found"，**第 1–13 节的 57 条检查一起红**。

这两件事是同一个教训的两半：**在一个不引号的 heredoc 里，一句"注释"可以是代码，一句"代码"可以是
另一个程序的参数。** 而这个 harness 自己的头里已经写着这条规则 —— 说明**写着规则和遵守规则是两件事**，
而唯一能分辨它们的是"跑起来、并且看红在哪里"：57 条红里没有一条在说"stub 没写出来"，是那一行
`1: parameter not set` 说的。

---

## 7. 设备：一次救回，又一次掉进 EDL

这一轮设备的状态发生了两次变化，两次都不是我做的决定：

1. **进 fastboot**（用户物理操作）。`fastboot devices` 显示序列号 **`33e80afe`** —— 是目标机；
   总线上另一台 **`4a2fe00b`** 必须忽略。`product: MSM8996`，`secure: yes`。
   用户批准后执行 `fastboot reboot`（**不写任何分区**），设备正常启动：RNDIS 回来、两个地址
   在、ssh 通。
2. **又一次掉进 EDL**（`05c6:9008`，无序列号）。发生在抓取证据的**第 06 步（指纹探针）**进行中，
   开机之后大约 6–7 分钟。`scripts/host/zl1-post-recovery-capture.sh` 正常地按 `exit 3`
   （"被打断"）归档了它已经收集到的部分。

### 7.1 这一次得到的读数（`tmp-post-recovery-20260924T013059Z/`）

| 文件 | 是什么 |
|---|---|
| `00-identity.txt` | boot_id、uptime、kernel、keeper pid、`failed units: 0` |
| `01-edl-postmortem.txt` | **上一次** EDL 的证词：pstore 是空的；kmsg 归档里那次开机的最后一份快照停在 84 s，末尾是 `rndis0(...,carrier=0,op=down,idx=6)`。脚本给出 "FOUND: a kernel oops/panic is on record"，但它抓到的是**开机时**的 `Call trace:`（0.41/0.79/1.61 s）——**那多半是假阳性**，需要重读而不是采信 |
| `02-boot-address.txt` | `inconclusive`：地址在，但装的是**没有 `ensure_addrs()`** 的那份构建，所以配地址的是 keeper。**这正是 `111` 预言的状态**，也正是本轮 `--activate` 要解决的那一半 |
| `03-keeper-status.txt` | keeper pid 817，ppid 1，`ppid_comm=zl1-debug-init`；地址两个都在；**替代品：文件在、`ensure_addrs()` MISSING、unit active** —— 与 §2 描述的一模一样 |
| `04-health-check.txt` | 306 行 |
| `05-gps-probe.txt` | 168 行 |
| `06-fingerprint.txt` | 2681 字节，**在被中断前**；末尾是 `nsenter: failed to execute test: No such file or directory` ×9 |

### 7.2 没有做的事

**没有**在设备上安装任何东西（`install-netwatch-service.sh` 一次都没有运行），**没有** flash、**没有**
QDL/firehose、**没有**写分区、**没有**重启服务。得到的 ssh 读数全部是只读的。

### 7.3 下一步仍然是物理的

设备在 EDL，**唯一**的出口是物理长按电源 10–20 秒。之后：

```
scripts/host/zl1-post-recovery-capture.sh --skip-probes      # 先不碰指纹，见下
install-netwatch-service.sh --yes --ssh
install-netwatch-service.sh --yes --ssh --activate           # ← 本轮新增，省掉一次重启
zl1-address-owner-proof.sh --yes                             # 决定性的测量
install-retire-debug-keeper.sh --install --now --after-proof # 只有 proof-obtained 才杀
install-cpufreq-governor.sh                                  # 发烫的另一半
```

**`--skip-probes` 是有理由的**：两次 EDL 里至少这一次与第 06 步（指纹探针）在时间上重合，而这两个
探针**从来没有产生过任何修复**（`peripheral-status`：GPS 与指纹至今没有拿到过定位/指纹）。在发烫修复
还没装上、每一次开机都要用手指换来的阶段，先拿确定的东西，再回头查探针。
