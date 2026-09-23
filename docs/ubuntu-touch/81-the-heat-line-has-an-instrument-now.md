# 81 — 发热这条线现在有仪器了：一个可重复的 A/B，而不是一串手敲的命令

**日期**: 2026-09-23
**状态**: `72` 把两个热源量出来了，但那次的每一条数字都是手敲命令凑的（两次 `/proc/<pid>/stat` 差分、`/proc/stat` 前后、热区读数，然后换一个变量再量一遍），而**结论恰恰来自两个窗口的差**（keeper 停掉后 tsens1/tsens8/pm8994 掉了 5.5/6.1/2.7 C）。手敲的过程里最容易丢的就是这个 A/B。所以这一步只做一件事：把 `72` 的测量法做成 `scripts/device/zl1-thermal.sh` —— 一次运行给出一个窗口的 CPU 归属 + 温度，`--ab` 给出"改一个东西前后"的**逐进程和逐热区差值**。**这个脚本在真实内核上跑通了（本机 x86 主机，见 §4），但没有在 zl1 上跑过 —— 设备现在在 EDL，需要手动复位。**

**接续**: [`72`](72-the-heat-was-the-governor-and-a-debug-keeper.md)（两个热源的原始测量与 §6 的后续）、[`78`](78-the-sensors-came-back-without-a-reboot.md)（§6 那条欠账：`sensorfwd` + sensors HAL 是 `72` §4b(d) 里两个最大的用户态消费者，它们回来了，热要重新量）、[`80`](80-the-ut-camera-app-starts-and-our-preload-was-breaking-egl.md)（设备进 EDL 的这一次）

---

## 1. 为什么必须是"窗口差分"

* **`top` 的瞬时百分比在这台内核上不可加**（`72` §1 已经踩过）；`/proc/<pid>/stat` 的 utime+stime 是整数、HZ=100，两次采样相减是可以相加的量。
* **绝对温度说明不了任何事**：设备在充电、环境温度在变，`72` 的结论之所以站得住，是因为它比的是"同一个设备、同一个电池状态、改一个东西前后"。
* **`iowait` 必须和 user/sys 分开**：`72` §4 那句"2.4 个核在内核态"就是 `iowait` 记账假象（§4b 推翻），一个分不出这两者的数字正是误导过那一次的。

## 2. 它量什么（全部只读）

| 输出 | 来源 | 注意 |
|---|---|---|
| 有多少核在忙 / user / sys / irq / softirq / **iowait** | `/proc/stat` 聚合行两次差分 | 按核数归一，`busy = total − idle − iowait` |
| 上下文切换/秒、loadavg、**D 态线程数** | `/proc/stat` 的 ctxt、`/proc/loadavg`、`/proc/<pid>/stat` 第一字段 | D 态既不算 user 也不算 sys，是"在等 io"的形状 |
| 窗口内 CPU 最高的 N 个进程 | `/proc/<pid>/stat` 的 utime+stime 两次差分 | **进程名从 `/proc/<pid>/comm` 读**，不从 `stat` —— `stat` 里的 comm 带括号且**可以含空格**，会把 14/15 字段错位到错误进程上 |
| 每个热区的温度 + 最热的那个 | `/sys/class/thermal/thermal_zone*/{type,temp}` | 毫摄氏度 |
| 每个核的 governor / cur / max | `/sys/devices/system/cpu/cpu*/cpufreq/*` | `72` §2 那个"钉在最高频"的判据 |
| 内存（含容器的 cgroup 计数，若有） | `/proc/meminfo`、`/sys/fs/cgroup/memory/memory.*` | `72` §4b 的容器 3.70/3.87 GB |

**写的只有 `/tmp` 里的临时目录**（退出时删掉）：不写设备文件、不写 property、不写 `/sys`、不碰任何服务、不发信号。

## 3. `--ab` 怎么用（这是它的全部意义）

```sh
# 从主机驱动：先起 A/B，再在中途改一个变量
ssh root@10.15.19.82 'sh /tmp/zl1-thermal.sh --ab --hold 30' &
sleep 35
ssh root@10.15.19.82 'sh /tmp/zl1-quiet-debug-keeper.sh --stop'     # 只改这一个
# ... 第二半输出就是结论：逐进程的 ticks 差 + 逐热区的 C 差
```

中间的间隔是**普通 `sleep` 而不是等待按键**：它跑在 ssh 上，等按键的脚本就是会挂住会话的脚本（`zl1-sensors-recover.sh` 的 `stuck()` 专门避开的同一个坑）。A/B 里进程差按 `"pid comm"` 配对，只在 A 的 top-N 里出现的进程按 0 起算，并且**把这件事印出来**——不然"某个进程在 B 里变了多少"会被读成"它在 B 里才出现"。

## 4. 它被验证到什么程度（说清楚，别夸大）

**在真实内核上端到端跑通了** —— 但在**本机主机**（x86，88 核，`schedutil`）上，不是 zl1 上：

```
zl1 thermal budget :: ... :: window 3s :: read-only
  busy 6.28 of 88 cores (7%), of which iowait 0.00 cores
  user 6%  sys 1%  irq 0%  softirq 0%  iowait 0%   (48722 ticks, 3 s)
  context switches 33646/s   loadavg 5.76 5.73 6.28   D-state threads 0
== thermal zones:   thermal_zone0 x86_pkg_temp 42.0 C ... hottest: x86_pkg_temp at 52.0 C
== cpufreq:         cpu0/cpufreq governor=schedutil cur=1200136 kHz max=3700000 kHz
--ab:  == B minus A per process: +11 1446878 python ...   == per thermal zone: -1.0 C (42.0 -> 41.0)
```

跑这一次是有价值的，而且**抓到了两个真 bug**：`read_stat()` 的格式串少了一个 `%s`，awk 直接报错退出、文件里只剩 ctxt 行，于是所有百分比都拿 ctxt 当 ticks 算 —— 输出是"88.00 of 88 cores busy (100%)"，看着像结论，其实是垃圾。现在 `read_stat()` 会**自己核对拿到两行**，不等（`72` 那种"数字看着合理就往下走"的错，这里用断言挡掉）。

**没在 zl1 上验证的部分**（等设备回来第一条就是这些）：热区路径与名称（`tsens1`/`tsens8`/`pm8994` 这套在 `72` 里是对的，脚本按 `/sys/class/thermal/*` 枚举，不假设名字）、cpufreq 节点（这台内核没有 `schedutil`，`interactive` 是 `install-cpufreq-governor.sh` 装的）、LXC 的 cgroup 路径（两个候选路径都试，读不到就跳过）、以及 D 态线程在 4 核设备上的耗时（主机 88 核上要一两秒）。

## 5. 这条线上现在欠的三次测量（设备回来就能做）

1. **`sensorfwd` + sensors HAL 的热代价**（`72` §4b(d) 里两个最大的用户态消费者，`78` 让它们重新跑起来了）：`zl1-thermal.sh --ab`，中途只停其一（sensors 那侧的可逆开关是 `zl1-sensors-recover.sh` 的对手方向，别单独 `systemctl restart sensorfwd` —— `78` §4 的规则）。
2. **governor 那个修复的"开机生效"**：`72` §2 装成了 `zl1-cpufreq-governor.service`，但还没在**一次真正的重启之后**核对过（`systemctl --failed` + 每个核的 governor）。
3. **容器内存 3.70/3.87 GB**：这不是发热嫌疑（`kswapd0` 只有 14 秒 CPU），是"容器随时会被 OOM"，`72` §6 第 2 条挂着，脚本会把它一起打出来。

这三条都需要设备在线；第 2 条还需要用户点头重启。

## 6. 复现

```sh
scp scripts/device/zl1-thermal.sh root@10.15.19.82:/tmp/
ssh root@10.15.19.82 'sh /tmp/zl1-thermal.sh --seconds 60 --top 15'          # 一个窗口
ssh root@10.15.19.82 'sh /tmp/zl1-thermal.sh --ab --hold 30'                 # 改一个东西前后
```

| 文件 | 作用 |
|---|---|
| `scripts/device/zl1-thermal.sh` | 新增。`--seconds N` / `--top N` / `--ab` / `--hold N` / `--quiet` / `--help`。一个窗口的 CPU 归属 + 温度；`--ab` 给逐进程与逐热区的差值。只读，只写 `/tmp`。已验证：真实内核上端到端（主机，x86）；未验证：zl1 上的热区/cpufreq/cgroup 路径 |

## 7. 这一轮**不**证明什么

* **没有任何新的温度数字**：这一轮没有在 zl1 上测过任何东西（设备在 EDL），§4 里那张输出是**主机**的。
* **不证明 `72` 的两个热源还有效或已失效**：脚本只是把测量法固定下来，没有重复那次实验。
* **不证明脚本在任何非 Linux 的 `/proc` 上能用**：它依赖 `/proc/stat` 的字段顺序（`ctxt`、8 个 cpu 字段），那是 Linux 的 ABI，不是这个移植的性质。
