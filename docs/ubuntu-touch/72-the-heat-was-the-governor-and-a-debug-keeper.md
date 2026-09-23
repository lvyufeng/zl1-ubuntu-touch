# 72 — 发热：镜像把 4 个核钉在 `performance`，而 v63 的调试守护脚本每秒跑两条 `systemctl`、每 ~6 秒触发一次 2 秒的 daemon-reload

**日期**: 2026-09-22
**状态**: **两个热源量出来了，第一个已经修好并装成开机生效，第二个只停了运行时（可逆）。第三个（§4 的"内核态占掉一半 CPU"）在 §4b 的第二次测量里被推翻 —— 那是 `iowait` 记账假象，真实忙碌 0.87 个核；同时 §3 里 keeper 的代价从 6.6% 修正为整整一个核。**

1. **CPU 频率策略**：4 个核全部是 `performance`，`scaling_cur_freq == scaling_max_freq` —— 永远跑在最高频，空闲也不降。改成 `interactive`（这台内核没有 `schedutil`）后，空闲核从 1132800/1363200 MHz 掉到 **307200/460800 MHz**，负载下照样能升上去。已由 `scripts/install-cpufreq-governor.sh --install` 装成 `zl1-cpufreq-governor.service`（oneshot，`WantedBy=multi-user.target`，`Result=success`）。**这是这次的正式成果。**
2. **v63 的调试网络守护脚本**（`/usr/local/sbin/zl1-debug-net.sh`，孤立进程 pid 817，它的 unit 因为脚本自己 daemonize 而在 67 ms 后就"退出"了）是第二个热源，而且它是**自己造的**：它的 1 Hz 主循环里第 112-113 行每秒执行 `systemctl mask --runtime usb-moded.service` 和 `systemctl stop usb-moded.service` —— 这会让 **systemd 每 ~6 秒做一次 daemon-reload，每次要 ~2 秒**（日志原文 `Reloading finished in 2044 ms`）。它自己还烧掉 **6.6% 的一个核**（实测 20 秒 132 ticks），循环里还每次遍历一遍 `/proc/[0-9]*`。
3. ~~**剩下的一半 CPU 是内核态**：20 秒 `/proc/stat` 差分是 user 16.9% / idle 24.1% / 其它 59%，也就是 4 个核里约 **3.0 个在忙、其中 2.4 个在内核**~~ → **【§4b 已推翻：那 2.4 个核是 `iowait` 记账假象，真实忙碌约 0.87 个核】**，而且 §3 那个 keeper 的实际代价是 **整整一个核**（不是这里写的 6.6%）。~~另外容器内存 **3.70 GB / 3.87 GB**（只剩 162 MB）仍然成立。~~ → **【[`87`](87-the-container-memory-reading-was-the-whole-phone.md) 已更正：这个内核没开 `CONFIG_MEMCG`、rootfs 上也没有 lxcfs，所以那个从容器里跑出来的 `free` 读的是宿主机的 `/proc/meminfo` —— 3.70/3.87 GB 是**整台手机**的，不是容器的配额，也没有配额可调。96% 满仍然成立，但要按「UT 与 Android 之间没有内存隔离」来读。】**

**接续**: [`71`](71-the-sensors-stream-the-restart-kills-the-hal.md)（同一批测量里发现的：`sensorfwd` + HAL 的持续 CPU 与 HAL 自杀循环是同一件事）、[`69`](69-repowerd-died-on-a-startup-race-with-sensorfwd.md)

---

## 1. 量发热用什么

没有温度计，也没有 perf，所以用的是三样东西，都在 `/proc` 和 `/sys` 里：

| 仪器 | 读法 | 注意 |
|---|---|---|
| 系统负载 | `cat /proc/loadavg` | 只说明"有多少在排队"，不说明谁在烧 |
| 全机 CPU 拆分 | `/proc/stat` 的 `cpu` 行做两次差分 | 单核机器上它会骗人；这里有 4 个核，`busy = (user+sys+irq+softirq+iowait)/total × 4` |
| 单个进程 | `/proc/<pid>/stat` 的 `utime+stime` 差分 | **比 `top` 可信**：`top` 的瞬时百分比会跳，20 秒的 ticks 差分是稳定的 |
| 温度 | `/sys/class/thermal/thermal_zone*/temp` | **同一台设备上三种单位**，见下 |

温度的坑要单独说，因为混着看会得出错的结论：

| 区域名 | 单位 | 本次读到的值 | 读作 |
|---|---|---|---|
| `tsens_tz_sensor1…20` | **十倍摄氏度** | 490 / 558 / 580 | 49.0 / 55.8 / 58.0 °C |
| `pm8994_tz`、`battery` | **毫摄氏度** | 46923 / 42500 | 46.9 / 42.5 °C |
| `msm_therm`、`quiet_therm`、`pa_therm0`、`emmc_therm` | **摄氏度** | 47 / 49 / 43 / 45 | 直接读 |

所以 `sort -n | tail -1` 取"最高温"是**错的**（它会把 48000 当成最高），必须按名字分别看。另外 `battery` 是 42.5 °C 而且当时**正在充电**（shell 日志里 `INDICATOR_BATTERY_CHARGING` / `battery-caution-charging-symbolic`），所以环境温度这一项里有一部分不是 CPU。

## 2. 热源一：4 个核被钉在最高频（已修，开机生效）

```
$ for p in 0 1 2 3; do cat /sys/devices/system/cpu/cpu$p/cpufreq/scaling_governor; done
performance performance performance performance
$ cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq   # 而且 cur == max
1132800        # cpu0/cpu1 的 max 是 1132800，cpu2/cpu3 是 1363200
```

`performance` 的意思是"永远最高频"，对一块靠电池的手机 SoC 来说这是最没必要的发热：没有活干的时候它也在全速烧电。`scaling_available_governors` 是：

```
interactive conservative ondemand userspace powersave performance
```

**没有 `schedutil`**，而 `interactive` 是这类 Qualcomm 内核（msm8996）本来就会默认给的调频器，所以选它。运行时改完立刻生效：

```
before:  cpu0 1132800  cpu1 1132800  cpu2 1363200  cpu3 1363200
after:   cpu0  307200  cpu1  307200  cpu2  460800  cpu3  460800      # 负载没变（~6），说明不是"核闲下来了"
```

**持久化**用的是 `scripts/install-cpufreq-governor.sh --install`：它写两个文件到 `/etc/systemd/system`（这是可写路径；`/` 是只读镜像，见 [`64`](64-the-last-unit-was-not-failing-it-was-obeying.md) 与记忆里的 `/etc` 只读那条）：

- `/etc/systemd/system/zl1-cpufreq-governor.sh` —— 应用脚本，遍历 `/sys/devices/system/cpu/cpu*/cpufreq` 写 `scaling_governor`，幂等，可以手工跑；
- `/etc/systemd/system/zl1-cpufreq-governor.service` —— `Type=oneshot`、`RemainAfterExit=yes`、`Before=multi-user.target`，开机跑一次。

验证用的是 `systemctl cat`（**只有它才是"这个 unit 真的生效"的诚实检查**，`is-enabled` 会骗人 —— 见记忆里 drop-in 目录名那条），加上 `Result=success`，加上直接读 `scaling_governor`。**没有做**的事情写清楚：没动 `scaling_max_freq`（只改"什么时候升频"，不改"能升到多高"）、没碰 `min_freq`、没碰 thermal trip point（**这台设备一个 cooling device 都没注册**，`/sys/class/thermal/cooling_device*` 是空的，所以内核侧根本没有节流可调）、没进容器。

## 3. 热源二：v63 调试守护脚本 —— 它每秒跑两条 `systemctl`

进程是孤立的 `/bin/sh`：

```
$ tr '\0' ' ' < /proc/817/cmdline
/bin/sh /usr/local/sbin/zl1-debug-net.sh
$ ps -o pid=,ppid=,time= -p 817
   817     1  00:10:35          # ppid=1：unit 早就不认它了
$ systemctl status zl1-debug-net.service
   Active: inactive (dead) ... Duration: 67ms      # 脚本自己 daemonize，unit 以为它干完了
```

它的主循环（`while :; do … sleep 1; done`）每秒做这些事：重写 `/run/systemd/system/zl1-debug-net.service`、`maybe_systemctl_mask_usb`、`kill_usb_managers`（遍历 `/proc/[0-9]*`）、`force_android_usb_rndis`、给 `usb0`/`rndis0` 配地址、启动调试服务。**贵的是第二条**：

```
110:maybe_systemctl_mask_usb() {
111:    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
112:        systemctl mask --runtime usb-moded.service >/dev/null 2>&1 || true
113:        systemctl stop usb-moded.service >/dev/null 2>&1 || true
```

`systemctl mask --runtime` 会改 unit 文件目录，于是 systemd 重载；`systemctl stop` 是一次 job。结果是 **每 ~6 秒一次 daemon-reload，每次的系统时间约 2 秒**：

```
[ 6865.401165] systemd[1]: Reloading...
[ 6867.481908] systemd[1]: Reloading finished in 2080 ms.
```

**A/B 是干净的**（`kill -STOP 817` 停、`kill -CONT 817` 恢复，中间用了一个 600 秒自恢复的定时器做安全网）：

| | 证据 |
|---|---|
| 停之前 | 817 在 20 秒里烧 132 ticks = **6.6% 的一个核**；日志里 reload 每 ~6 秒一条 |
| 停之后 | **5 分钟一条 reload 都没有**（最后一条 [9259.4]）；负载均值 6.66–7.36 → 5.38–6.02；`tsens_tz_sensor1` 538 → **490**（53.8 → 49.0 °C）、`pm8994_tz` 48000 → 46923 |
| 自恢复定时器一到（[9850] 左右恢复） | **[9866.9] 立刻又来一条 `Reloading requested`，client 的 cgroup 是 `init.scope`** —— 正是孤立进程所在的 scope。5 秒内复现，因为这就是它循环的第一秒 |

**它现在被停在运行时（`kill -STOP 817`），但这不是持久修复，是有意的临时状态。** 理由是：它同时是**开机时给 RNDIS 配地址的那一方**（`configure_iface` 写 `192.168.2.15/24` 和 `10.15.19.82/24` 并按 ARP 宣告），而我们的 `zl1-netwatch.sh` 虽然有一份等价的 `restore_addrs()`，**但"没有 keeper 的开机能不能拿到地址"这件事还没有被验证过**。拿掉它而开机没地址，就等于 SSH 没了、要用手去按手机 —— 为了省几个百分点的 CPU 去赌用户的访问权，这个赌不做。恢复只需要 `kill -CONT 817`（不受影响的另一条路是重启设备，keeper 会照旧起来）；要真正换掉它需要一次**重启验证**，见 §6。

§5 那 5 分钟（keeper 停着、什么也不跑）的读数：systemd 自己在 300 秒里只用了 **1 秒** CPU，SoC 降了 **5.5 / 6.1 / 2.7 °C**，reload **0 条**。

## 4. 剩下的一半：内核态，只有数字

```
20s /proc/stat 差分: user 16.9%  idle 24.1%  其余 59%（sys+irq+softirq+iowait）
=> 4 核里约 3.0 核在忙，其中 2.4 核在内核态
容器自己的 top 一致：400%cpu  19-27%user  108-215%sys  96-269%idle
```

按进程能算到的只有 ~0.5 核：`sensorfwd` + `android.hardware.sensors@1.0-service` 合计约一个核的 18%（[`71`](71-the-sensors-stream-the-restart-kills-the-hal.md) 里那个 HAL 自杀/重连循环是同一件事），`android.hardware.graphics.composer@2.1-service` 约 4%。`ksoftirqd/*` 四个核累计约 6.5 分钟、`rcu_preempt`+`rcu_sched` 约 6.7 分钟（2.6 小时里），这是大量系统调用/IPC 的形状，而不是某一个热循环。~~容器内存 3.70/3.87 GB **几乎满了**~~ → **【更正见 [`87`](87-the-container-memory-reading-was-the-whole-phone.md)：那是整机的数，容器没有内存配额（本内核 `CONFIG_MEMCG` 未开）】**，回收压力会是其中一部分，但 `kswapd0` 只有 14 秒 CPU，所以不是主因。

**一个必须写下来的自省**：这一节里的读数会被**我自己**污染 —— 全量 `journalctl | grep` 在这台设备上就是一次典型的 CPU 尖峰，而这次测量期间我跑过几次（其中两次还把 SSH 命令跑到超时）。所以"停掉 keeper 之后温度反而从 49.0 升到 55.8 °C"这种读数不能当作 keeper 有害的证据：那 5 分钟里烧得多的是我的 grep、`systemctl daemon-reload`（装 unit 时）、以及充电。要分离它，只能用 §5 那个"安静 5 分钟"的测法。

## 4b. 第二次测量（换了两个变量之后）：**"2.4 个核"是记账假象，真实的忙是 0.87 个核**

§4 那组数字是在 **governor 还是 `performance`、keeper 还在跑** 的时候取的。把这两件事都改掉之后再量一次（`docs/ubuntu-touch/evidence/thermal-second-pass-2026-09-22.log`），结论变了两条，而且两条都是**收窄**（问题比原来写的小）：

**(a) "4 核里 3 个在忙、2.4 个在内核" 是 `iowait` 被算进了 busy。** 同一台设备、同一个负载均值区间，`iowait` 实测 **0%**，拆分是：

```
user=5.6%  sys=15.0%  idle=78.3%   -> busy = 0.87 核（4 核的 22%）
```

也就是说真实忙碌只有 **0.87 个核**，其中内核态（`sys`）0.60 个。**没有一个"消失的核"需要去找。** §4 之所以读到 59% 的"其它"，是因为当时把 `iowait` 和 `irq/softirq` 一起并进了 busy —— 这台设备 `iowait` 很高（容器在 96% 满的内存上做回收、加上 §4b(c) 那些 D 态驱动线程），而 `iowait` 是**等待**，不是**计算**，它对发热的贡献远小于同等的 `user`/`sys`。**教训（写给以后）：`busy = (total-idle)/total` 这个式子在这台设备上是错的，要单独看 `user` 和 `sys`。**

**(b) §3 的 keeper 代价是 ~1.0 个核，不是 6.6%。** 15 秒窗口的干净 A/B（除了 `SIGSTOP`/`SIGCONT`，别的一切不变）：

| | user | sys | idle | busy | reload |
|---|---|---|---|---|---|
| keeper **停着** | 5.6% | 15.0% | 78.3% | **0.87 核** | 0 |
| keeper **跑着** | 11.6% | 32.7% | 54.0% | **1.84 核** | 1（15 秒窗口内） |

差值 **0.97 个核 ≈ 这台 4 核 SoC 的 24%**。§3 那个 6.6% 是**只算 keeper 自己那个 `/bin/sh` 进程的 ticks** 得到的 —— 它漏掉了这笔账真正的大头：`systemctl` 是**子进程**，daemon-reload 是 **systemd 自己（pid 1）** 干的活，两者都不记在 817 头上。**所以"某个进程烧多少"这个测法在"它让别人替它烧"的场景里会低一个数量级。**（reload 计数是这两列里较弱的一个：`journalctl -n 3000` 会截断，而 §3 测到的节奏是每 ~6 秒一次、每次 2044 ms，15 秒里应当有 ~2 条。CPU 那一列是稳的。）

**(c) 负载均值 5-6 **不是** CPU —— 是 5 个睡在驱动里的内核线程。** 负载 5.02/5.35/5.54 的同时只有 0.87 个核在忙：

```
进程状态: {S: 586, R: 3, D: 5, T: 1, Z: 3}     （T 就是停着的 keeper）
5 个 D 态任务（都是正常的周期性内核工作，wchan 是驱动自己的等待点）：
  pid 154      mdss_dsi_event     wchan dsi_event_thread
  pid 415      msm-core:sampling  wchan do_sampling
  pid 932451   mdss_fb0           wchan __mdss_fb_display_thread
  pid 3509113  kworker/3:0        wchan usleep_range（栈里有 tsens_poll）
  pid 45       普通 workqueue worker
容器内部: {D: 0, R: 0, S: 118}   —— 容器一个 D 都没有，不是它
```

这台内核把"睡在驱动调用里"记成 `D`，所以**负载 5-6 的意思是"有五个驱动线程在睡觉"，不是"有 5 个核在干活"**。（顺带：这个内核把 D 态在 `ps` 里标成 `(disk sleep)`，在一条没有换页压力的路径上这是错的标签。）**不要用负载均值判断发热** —— §1 表格里那句"只说明有多少在排队"要加一句："在这台设备上排队的多半是睡着的驱动线程"。

**(d) 那 0.87 个核里，谁在烧（10 秒上下文切换数，全机 602 个任务 1587 个线程共 29244 次）：**

```
rcu_preempt 7415 | ksoftirqd/2 3282 | rcu_sched 2795 | ksoftirqd/3 2560 | ksoftirqd/0 1869
sensorfwd 1590（其中 372 次非自愿）| ksoftirqd/1 1414 | kworker/u8:8 1281
systemd-journald 695 | android.hardware.sensors@1.0-service 440（78 个线程）
```

**~83% 的上下文切换是内核自己的**（RCU、softirq、kworker），用户态里唯一的大户就是 `sensorfwd` + sensors HAL 这一对（[`71`](71-the-sensors-stream-the-restart-kills-the-hal.md)）。**没有剩下一个跑飞了的用户态进程可以怪。** 中断侧：`IPI0` 19573/10 秒、`CPU3` 5853/10 秒，也是这么多核间唤醒该有的形状。

**(e) 容器 sensors HAL 的 A/B 在这个粒度下没有结论（写下来，别当成有结论）。** 停掉再起来：`busy` 0.72（停）vs 0.82（跑），差 0.1 个核，落在 15 秒窗口的噪声里；而"跑着"的那次读数是在我一串 `journalctl` 之后立刻取的，被我自己污染了。**它要花点东西，但这个方法说不出多少 —— 而且杀掉它也不是修法**（加速度计/磁力计/陀螺仪就是通过它流的，§71）。

**(f) 温度（同一轮结束时）**：`tsens_tz_sensor1` 519（51.9 °C，起点 558）、`tsens_tz_sensor8` 535（53.5 °C，起点 580）、`pm8994_tz` 45945（45.9 °C，起点 49125）、`battery` 41200（41.2 °C，起点 42500，**还在充电**）。

## 5. 安静的 5 分钟（keeper 停着，什么都不跑）—— 这是最干净的一条证据

| 时刻 | uptime | 负载 | `tsens_tz_sensor1` | `tsens_tz_sensor8` | `pm8994_tz` | `battery` | systemd 自己的 CPU | reload |
|---|---|---|---|---|---|---|---|---|
| t0 | 9892 | 6.76 | 558 (55.8 °C) | 580 (58.0 °C) | 49125 (49.1 °C) | 42500（充电中） | **37:38** | — |
| t1（+300 秒） | 10192 | 6.04 | 503 (**50.3 °C**) | 519 (**51.9 °C**) | 46434 (**46.4 °C**) | 42200 | **37:39** | **0** |

三件事同时成立，所以这条不是噪声：

1. **systemd 在 300 秒里只花了 1 秒 CPU**（`37:38` → `37:39`）。作为对照：keeper 跑着的时候，它每秒调一次 `systemctl mask --runtime`（改 unit 目录）+ 一次 `systemctl stop`，日志里表现为每 ~6 秒一次 `Reloading finished in ~~2000 ms`。**推理（不是测量，写清楚）**：300 秒里 50 次 reload、每次约 2 秒的 busy 时间，就是约 100 秒的系统忙时 ≈ 三分之一个核。直接测到的是上面那 1 秒。
2. **SoC 降了 5.5 °C / 6.1 °C / 2.7 °C**（tsens1 / tsens8 / pm8994），而且电池**还在充电**（42.5 → 42.2 °C），也就是说降温不是"没在充电了"。
3. **负载均值 6.76 → 6.04**，reload 计数 **0**。

反过来也验过一次：自恢复定时器把 keeper 一放（约 [9850]），**5 秒内在 [9866.9] 就又来了一条 `Reloading requested`，client 的 cgroup 是 `init.scope`** —— 正是孤立进程所在的 scope。停→没有、放→立刻有，这是 §3 那个 A/B 的闭环。

**这条测量唯一没分离掉的是"我自己的命令"**：t0 之后那 300 秒里我一条设备命令都没发（就是一个 `sleep 300`），所以这 5 分钟的读数里没有被我的 `journalctl | grep` 污染。

## 6. 下一步

1. **把 keeper 换掉，然后重启验证**（§3）。做法上有一条比"遮蔽 unit"更好的路：它的 unit 文件在 `/etc/systemd/system/zl1-debug-net.service` —— **是可写的**，所以不用去碰只读镜像里的脚本，改 unit 的 `ExecStart` 指向一个我们自己写的、开机只跑一次的 bring-up（持久地 `systemctl mask usb-moded.service` + 强制 gadget + 配地址 + ARP 宣告），再让 netwatch 的 45 秒 stall 自愈兜底。验证必须包含**一次真正的重启**，而且要用户在（万一 RNDIS 没起来，需要人手；主机侧有 udev 规则会自动 bind `rndis_host`，但设备侧的地址只有设备自己能配）。**这一步要用户点头再做。**（2026-09-22 用户的选择：**先不重启**，就维持"运行时停着"这个状态，所以本次到这里为止；`scripts/device/zl1-quiet-debug-keeper.sh` 是它的开关。）
2. ~~**那 2.4 个核的内核态**（§4）~~ → **§4b 已结案：没有那 2.4 个核。** 真实忙碌 0.87 个核、内核态 0.60 个、`iowait` 0%，负载均值是睡着的驱动线程。**剩下要处理的只有 §4b(d) 里那两个真实的用户态大户**（`sensorfwd` + sensors HAL，§71 那条线）和内存 3.70/3.87 GB —— 后者已经不是"发热嫌疑"而是**稳定性问题**：那不是容器的配额，而是**整机**的占用（[`87`](87-the-container-memory-reading-was-the-whole-phone.md)：本内核没开 `CONFIG_MEMCG`，rootfs 上也没有 lxcfs），所以 OOM killer 在 UT 与 Android 之间**没有隔离**；`kswapd0` 只有 14 秒 CPU，所以它也不是热源。
3. `orientationsensor` 那条（[`71`](71-the-sensors-stream-the-restart-kills-the-hal.md) §7）：`sensorfwd -c=<path>` 这个杠杆还没用；`orientationsensor=False` = 稳定竖屏、没有自动旋转，是取舍，等用户决定。

## 7. 文件与复现

| 文件 | 作用 |
|---|---|
| `scripts/device/zl1-quiet-debug-keeper.sh` | `--stop` / `--resume` / `--status`。把 §3 的 keeper 停住/恢复（SIGSTOP/SIGCONT），**不碰开机路径**：它是只读镜像里的脚本、`systemctl` 管不到那个进程、而"没有 keeper 的开机能不能拿到地址"还没验过，所以只能动运行时。重启之后它会回来，重跑 `--stop` 即可 |
| `scripts/install-cpufreq-governor.sh` | `--install` / `--remove` / `--status` / `--governor NAME`。头部写着为什么（`performance` 钉高频）、装了什么、**没有**动什么（max_freq、trip point、容器），以及第二个热源的完整数字 |
| `docs/ubuntu-touch/evidence/thermal-2026-09-22.log` | 本次证据：governor 前后、keeper 的 CPU 差分、reload 的 A/B、热区原始读数、安静 5 分钟 |
| `docs/ubuntu-touch/evidence/thermal-second-pass-2026-09-22.log` | §4b 的证据：keeper 的 15 秒 A/B（0.87 ↔ 1.84 核）、5 个 D 态线程的 wchan/栈、10 秒上下文切换计数、容器 HAL A/B、结束时的温度 |

```sh
# 谁在烧（不要信 top 的瞬时值，用 ticks 差分）
a=$(awk '{print $14+$15}' /proc/<pid>/stat); sleep 20; b=$(awk '{print $14+$15}' /proc/<pid>/stat); echo $((b-a))  # 100 ticks = 1s
# 全机拆分
awk '/^cpu /{print $2,$3,$4,$5,$6,$7,$8}' /proc/stat      # user nice sys idle iowait irq softirq
# 温度（注意三种单位）
for z in /sys/class/thermal/thermal_zone*; do printf '%-22s %s\n' "$(cat $z/type)" "$(cat $z/temp)"; done
# keeper 的开关（运行时、可逆；它的 unit 不认这个进程，systemctl 管不到它）
kill -STOP 817     # 停
kill -CONT 817     # 恢复
```

**设备安全**：只往 `/userdata/` 写（证据/日志）。只读地看 `/proc`、`/sys`、journal、容器。改变设备状态的动作都可逆：装了 `zl1-cpufreq-governor.service`（`--remove` 可撤，且它只写 `scaling_governor`）、`kill -STOP 817`（`kill -CONT 817` 可撤，中途还有一个 600 秒自恢复的定时器）。**没有**遮蔽任何 unit、没有改 `/etc/sensorfw`、没有碰分区或 boot 镜像、没有动容器内的文件。容器 RUNNING，`systemctl --failed` 空，SSH 正常，面板 `alive`。
