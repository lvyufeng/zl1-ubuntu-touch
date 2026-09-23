# 87 — "容器内存 96% 满了" 那个读数，读的其实是整台手机

**日期**: 2026-09-23
**状态**: 纯离线的一轮（设备仍在 EDL）。`72` §8 记着一行读数——`container memory: 3867268k total, 3705148k used, 162120k free`，§4b(d) 把它写成 **"容器 3.70/3.87 GB，也就是 96% 满，已经不是发热嫌疑而是容器随时会被 OOM"**。这一轮把它的来源查清了：**这是从容器里跑 `top`/`free` 取到的，而这个内核根本没有 memory cgroup，容器里也没有 lxcfs，所以容器里的 `free` 读到的就是宿主机的 `/proc/meminfo`——那个数字是这台设备的 MemTotal，不是容器的配额。** 结论要换一个形状：不是"容器快被 OOM 了"，而是"**整台手机 96% 满，而且 UT 和 Android 之间没有任何隔离**"。

**接续**: [`72`](72-the-heat-was-the-governor-and-a-debug-keeper.md) §4b(d)/§8（被更正的那两处）、[`16`](16-noble-systemd-lxc.md)（容器配置）、[`22`](22-stage2-coldboot-results.md)（`lxc-info` 的那次捕获）、[`81`](81-the-heat-line-has-an-instrument-now.md)（这个仪器现在多印两个数）

---

## 1. 那行读数是哪来的

`docs/ubuntu-touch/evidence/thermal-2026-09-22.log` §8：

```
container top:  400%cpu  19-27%user  108-215%sys  96-269%idle
container memory: 3867268k total, 3705148k used, 162120k free    <- 96% full
```

上下文写的是 "container top"，也就是**在容器里**跑的 `top`（`400%cpu` 是容器那一侧的视角）。所以问题变成：容器里的 `free`/`top` 读 `/proc/meminfo`，看到的是谁？

正常情况下可以是两件事之一：
1. 容器有 **memory cgroup 配额**（`lxc.cgroup.memory.limit_in_bytes`），内核把这个配额报成 `MemTotal`；或者
2. **lxcfs** 在容器里替换 `/proc/meminfo`，按 cgroup 的用量伪造一份。

这两条**都不成立**。下面是四条独立的证据，全部离线可查。

## 2. 四条证据

**(a) 编出当前镜像的那个内核没有开 memory cgroup。** `out/target/product/zl1/obj/KERNEL_OBJ/.config`：

```
CONFIG_CGROUPS=y
CONFIG_CGROUP_FREEZER=y
CONFIG_CGROUP_DEVICE=y
CONFIG_CGROUP_CPUACCT=y
# CONFIG_MEMCG is not set        <- 这一条
```

没有内存控制器，就没有配额可报。

> **顺带一个会骗人的地方**：`lineage_zl1_defconfig` 里还留着 **`CONFIG_CGROUP_MEM_RES_CTLR=y` / `_SWAP=y` / `_KMEM=y`**（`:4640–4642`）。那是 **2.6/3.0 时代的符号名**，在 3.18 的 Kconfig 里**已经不存在**了，所以那三行是惰性的——**defconfig 读起来像是开了内存 cgroup，实际编出来的 `.config` 说 `not set`。** 只看 defconfig 的人会被骗，这和 `getprop` 是 stub、`lxc-ls` 谎报 STOPPED 是同一族：**读配置要读产物，不要读意图。**

**(b) 宿主机上就没有 `memory` 层级。** `/mnt/data/zl1-backups/` 里两份设备快照（`status-healthy-boot-20260918.txt`、`status-20260919T1605-healed-boot.txt`）的 `/proc/mounts` 段落列了全部 cgroup 挂载：`systemd`、`freezer`、`devices`、`cpuset`、`perf_event`、`bfqio`、`cpu,cpuacct`、`debug`、`blkio`——**没有 `memory`**。

**(c) LXC 自己也说没有。** `22` 记的 `lxc-info -n android -pH` 那一行：

```
Name: android  State: RUNNING  PID: 34874  IP: 10.15.19.82  IP: 192.168.2.15  CPU use: 1542.37 seconds
```

`lxc-info` 在有 memory cgroup 时会多打一行 `Memory use:`。**这里只有 `CPU use`。**

**(d) 容器配置里没有任何内存指令，而且 UT 的 rootfs 上没有 lxcfs。** `16` 抄下来的 `/var/lib/lxc/android/config` 里没有一条 `lxc.cgroup.memory.*`；rootfs 镜像（只读挂在 `/mnt/utrootfs`）里的 LXC 配置也 grep 不到。而且——**关键的那一条**——rootfs 上装的 lxc 相关包只有：

```
liblxc-common / liblxc1t64 / lxc / lxc-android-config
```

**没有 lxcfs。** 深度 `find` 也搜不到任何 `lxcfs*`。没有 lxcfs，就没有任何东西会替容器改写 `/proc/meminfo`。

四条合起来只有一个可能：**容器里的 `free` 读的就是内核全局的 `/proc/meminfo`。** 于是 `3867268k` 是这台设备的 MemTotal（4 GB 减去内核与 PIL carveout 之后的样子，3.69 GiB / 3.87 GB 十进制——而 cgroup 配额从来不会是这么一个零碎的数），`3705148k` 是整机已用。**"容器 96% 满" 这句话里的"容器"两个字是错的。**

## 3. 换成正确的说法之后，要处理的东西变了

| 原来（`72` §4b(d)） | 更正后 |
|---|---|
| "容器内存 3.70/3.87 GB，容器随时会被 OOM" | "**整台手机** 3.70/3.87 GB，96% 满" |
| 隐含的下一步：调容器配置 | **没有旋钮可调**。内核没开 `CONFIG_MEMCG`，容器配置里写 `lxc.cgroup.memory.*` 也是空操作。真正的旋钮只有两个：改内核配置 + 刷 boot 镜像，或者确实把内存用量降下来 |
| 发热嫌疑 | **同时是设备稳定性问题**：没有隔离意味着 OOM killer 在 UT 的 ~600 个任务和 Android 的 ~118 个任务之间**全局挑一个**。而按 [`47`](47-the-screen-comes-back-by-itself.md) §3 查清的机制，SurfaceFlinger 一停，容器的 framework 就永远在等它，每一次等待都是 RescueParty 记下的一次事件，攒够了**就把整机重启进 recovery** —— 这条链直接落在"不要让设备死机或变砖"那条约束上 |
| `iowait` 归因于"在 96% 满的**容器**上回收" | 回收压力是真的（**手机**是满的），但"容器"那两个字同样要拿掉 |

**还有一件更要紧的事：`top` 只有一个"used"，而 `MemAvailable` 从没被读过。** `top` 的 `used` 是 `total - free - buffers - cached`，它不等于"用不了的内存"——Linux 上 96% used 和 96% 压力是两件事。判断"会不会被 OOM"要看的是 `MemAvailable`（含可回收的页缓存）。所以 `72` 那个"96% 满 ⇒ 随时 OOM"的推理链中间缺一环，而这一环从来没量过。`81` 那个仪器 `zl1-thermal.sh` 的 `mem_state()` 现在**本来就印 `MemTotal` / `MemAvailable` / `SwapTotal` / `SwapFree`**——下一条命令就能补上。

## 4. 仪器里那个跟着错的标签，已经改掉

`zl1-thermal.sh` 的 `mem_state()` 原来有这样一段（注释还引了 `72` §4b）：

```sh
  for f in /sys/fs/cgroup/memory/memory.usage_in_bytes /sys/fs/cgroup/memory/memory.limit_in_bytes; do
    [ -r "$f" ] && printf '   %-14s %s\n' "${f##*/}" "$(cat "$f")"
  done
```

两个毛病：**（1）**`/sys/fs/cgroup/memory/` 的根是**整机**，即使有也不是容器的数；**（2）**这台设备上这个路径根本不存在，所以那个循环**什么都不打印**——脚本静默地假装自己量过容器内存，而读的人不会知道。现在改成：

* 先找**容器自己的**路径（`/sys/fs/cgroup/memory/lxc/*/` 与 `lxc.payload.*/`），找到就印用量和上限；
* 找不到但根还在 → 明确标注 **`ROOT of the hierarchy -- the whole system, NOT the container`**；
* 两个都没有（**这台设备的实际情况**）→ 直接说 **`NO memory cgroup mounted on this kernel`**，并写明"容器里的 `free` 报的是本机 MemTotal，不是容器配额，而且 OOM 时 UT 和 Android 之间没有隔离"。

三条分支都用合成 cgroup 树在本机跑过（有 `lxc/<name>` 子目录 / 只有根 / 完全没有），输出逐条核对过。**没有在设备上跑过**——设备在 EDL。

## 5. 这是这条线上第四个"读数的形状骗人"

按时间：`lxc-ls` 把运行中的容器报成 STOPPED；`top` 的瞬时 CPU% 在这台设备的内核上不能相加；`busy = (total-idle)/total` 把 `iowait` 算成了忙（`72` §4b 自己抓到的）；现在这个是——**在一个没有 cgroup 内存控制器的内核上，问容器"你用了多少内存"**。四个是同一个形状：**命令跑得通、有输出、输出还是个数，但它回答的不是你问的那个问题。** 所以这一族值得一条通用做法：*读数之前先问"这个数是从哪一层来的，那一层在这台设备上真的存在吗"*——`72` §4b 的教训（先拆 `user`/`sys`/`iowait`，别用合并的 `busy`）是同一个。

## 6. 复现

```sh
# （a）内核到底开没开内存 cgroup —— 读产物，不读 defconfig
grep -E "MEMCG|CGROUP_MEM" /mnt/data/halium-zl1-build/out/target/product/zl1/obj/KERNEL_OBJ/.config
grep -n "CGROUP_MEM" /mnt/data/halium-zl1-build/kernel/leeco/msm8996/arch/arm64/configs/lineage_zl1_defconfig

# （b）宿主机上有没有 memory 层级（用归档快照，设备不需要在）
grep "^cgroup " /mnt/data/zl1-backups/status-20260919T1605-healed-boot.txt

# （d）rootfs 上有没有 lxcfs
ls /mnt/utrootfs/usr/bin/lxcfs 2>&1
awk '/^Package: /{p=$2} /^Status: install ok installed/{print p}' /mnt/utrootfs/var/lib/dpkg/status | grep -i lxc

# 设备回来之后，一条命令补上那从来没量过的一环：
scp scripts/device/zl1-thermal.sh root@10.15.19.82:/tmp/ && ssh root@10.15.19.82 'sh /tmp/zl1-thermal.sh --seconds 60'
```

| 文件 | 作用 |
|---|---|
| `scripts/device/zl1-thermal.sh` | 改：`mem_state()` 不再把 cgroup 根当容器，找不到容器 cgroup 时明确说明"本内核没有内存控制器、容器里的 `free` 报的是本机 MemTotal、OOM 时没有隔离"。三条分支用合成 cgroup 树验过 |
| `docs/ubuntu-touch/72-*.md` | 改：§4b(d) 与 §8 加更正，指向本篇 |
| `docs/ubuntu-touch/87-*.md` | 本篇 |

## 7. 这一轮**不**证明什么

* **不证明内存压力是假的。** 96% 是整机的 96%，那仍然是满的（`kswapd0` 只有 14 秒 CPU 这条也还成立，所以它不对应一个正在拼命回收的系统）。被推翻的只是**"容器"这个范围和"有配额可调"这个隐含前提**。
* **不证明 OOM 一定会发生**，也不证明它发生过：没有 `dmesg` 里的 OOM 记录（`58` 那个环形缓冲会把它冲掉）、没有 pstore 证据（设备在 EDL）、也没有 `MemAvailable` 的历史读数。这条链的最后一环仍然要设备。
* **不证明把 `CONFIG_MEMCG` 打开是安全的或必要的**——那是一次内核配置改动加一次刷 boot 镜像，属于要明确许可的那一类，本轮没做也没建议做。
* **不证明 `3867268k` 一定等于 MemTotal**：它等于"容器里 `free` 看到的那个数"，而在没有 memcg、没有 lxcfs 的前提下那个数只能是内核全局的 MemTotal。要端到端确认，设备回来后在**容器里和宿主上各跑一次 `free`**，两个数一样就闭环了（`zl1-thermal.sh` 现在会把宿主的 `MemTotal`/`MemAvailable` 打出来，正好做这一比）。
* 不改动设备：这一轮对所有素材都是只读的（归档快照、构建产物、只读挂载的 rootfs 镜像）。
