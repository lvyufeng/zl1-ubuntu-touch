# 72 — 发热：镜像把 4 个核钉在 `performance`，而 v63 的调试守护脚本每秒跑两条 `systemctl`、每 ~6 秒触发一次 2 秒的 daemon-reload

**日期**: 2026-09-22
**状态**: **两个热源量出来了，第一个已经修好并装成开机生效，第二个只停了运行时（可逆），第三个（内核态占掉一半 CPU）只有数字、没有结论。**

1. **CPU 频率策略**：4 个核全部是 `performance`，`scaling_cur_freq == scaling_max_freq` —— 永远跑在最高频，空闲也不降。改成 `interactive`（这台内核没有 `schedutil`）后，空闲核从 1132800/1363200 MHz 掉到 **307200/460800 MHz**，负载下照样能升上去。已由 `scripts/install-cpufreq-governor.sh --install` 装成 `zl1-cpufreq-governor.service`（oneshot，`WantedBy=multi-user.target`，`Result=success`）。**这是这次的正式成果。**
2. **v63 的调试网络守护脚本**（`/usr/local/sbin/zl1-debug-net.sh`，孤立进程 pid 817，它的 unit 因为脚本自己 daemonize 而在 67 ms 后就"退出"了）是第二个热源，而且它是**自己造的**：它的 1 Hz 主循环里第 112-113 行每秒执行 `systemctl mask --runtime usb-moded.service` 和 `systemctl stop usb-moded.service` —— 这会让 **systemd 每 ~6 秒做一次 daemon-reload，每次要 ~2 秒**（日志原文 `Reloading finished in 2044 ms`）。它自己还烧掉 **6.6% 的一个核**（实测 20 秒 132 ticks），循环里还每次遍历一遍 `/proc/[0-9]*`。
3. **剩下的一半 CPU 是内核态**：20 秒 `/proc/stat` 差分是 user 16.9% / idle 24.1% / 其它 59%，也就是 4 个核里约 **3.0 个在忙、其中 2.4 个在内核**，而按进程记账只能算到 ~0.5 个核（`sensorfwd` + sensors HAL 占一个核的 18%、图形合成器 4%）。另外容器内存 **3.70 GB / 3.87 GB**（只剩 162 MB）。这两条只记数字，**没有结论**，见 §4。

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

按进程能算到的只有 ~0.5 核：`sensorfwd` + `android.hardware.sensors@1.0-service` 合计约一个核的 18%（[`71`](71-the-sensors-stream-the-restart-kills-the-hal.md) 里那个 HAL 自杀/重连循环是同一件事），`android.hardware.graphics.composer@2.1-service` 约 4%。`ksoftirqd/*` 四个核累计约 6.5 分钟、`rcu_preempt`+`rcu_sched` 约 6.7 分钟（2.6 小时里），这是大量系统调用/IPC 的形状，而不是某一个热循环。容器内存 3.70/3.87 GB **几乎满了**，回收压力会是其中一部分，但 `kswapd0` 只有 14 秒 CPU，所以不是主因。

**一个必须写下来的自省**：这一节里的读数会被**我自己**污染 —— 全量 `journalctl | grep` 在这台设备上就是一次典型的 CPU 尖峰，而这次测量期间我跑过几次（其中两次还把 SSH 命令跑到超时）。所以"停掉 keeper 之后温度反而从 49.0 升到 55.8 °C"这种读数不能当作 keeper 有害的证据：那 5 分钟里烧得多的是我的 grep、`systemctl daemon-reload`（装 unit 时）、以及充电。要分离它，只能用 §5 那个"安静 5 分钟"的测法。

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
2. **那 2.4 个核的内核态**（§4）：先查清是谁 —— 容器内存压力（可以试 `--memory` 之外的手段，或者把容器的 swap 用起来）、binder/QMI 的 churn、还是 HAL 的 poll 自旋（[`71`](71-the-sensors-stream-the-restart-kills-the-hal.md) §3 那条线的另一半：**HAL 每 13~700 秒自杀一次**，重连期间在烧 CPU）。`perf` 在这台设备上没有，但 `/proc/<pid>/stack`、`/proc/interrupts` 的差分、`/proc/vmstat` 的 `pgscan`/`pgsteal` 都还在。
3. `orientationsensor` 那条（[`71`](71-the-sensors-stream-the-restart-kills-the-hal.md) §7）：`sensorfwd -c=<path>` 这个杠杆还没用；`orientationsensor=False` = 稳定竖屏、没有自动旋转，是取舍，等用户决定。

## 7. 文件与复现

| 文件 | 作用 |
|---|---|
| `scripts/device/zl1-quiet-debug-keeper.sh` | `--stop` / `--resume` / `--status`。把 §3 的 keeper 停住/恢复（SIGSTOP/SIGCONT），**不碰开机路径**：它是只读镜像里的脚本、`systemctl` 管不到那个进程、而"没有 keeper 的开机能不能拿到地址"还没验过，所以只能动运行时。重启之后它会回来，重跑 `--stop` 即可 |
| `scripts/install-cpufreq-governor.sh` | `--install` / `--remove` / `--status` / `--governor NAME`。头部写着为什么（`performance` 钉高频）、装了什么、**没有**动什么（max_freq、trip point、容器），以及第二个热源的完整数字 |
| `docs/ubuntu-touch/evidence/thermal-2026-09-22.log` | 本次证据：governor 前后、keeper 的 CPU 差分、reload 的 A/B、热区原始读数、安静 5 分钟 |

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
