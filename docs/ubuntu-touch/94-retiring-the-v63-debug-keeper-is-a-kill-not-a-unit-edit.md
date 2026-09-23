# 94 — 退役 v63 调试 keeper：为什么这条路是"杀进程"，而不是 doc 72 说的"改 unit"

**日期**: 2026-09-23
**状态**: 纯离线的一轮（设备在 EDL，与 `86`–`93` 同）。`72` §4b 找出了这台机器的**第二个热源**——`/usr/local/sbin/zl1-debug-net.sh`，v63 的调试网络 keeper，一个 1 Hz 的 `/bin/sh` 循环：代价是**一整个核**（SIGSTOP 前后 1.84 → 0.87 busy cores），并且让 systemd **每 ~6 秒 daemon-reload 一次、每次 ~2 秒**；把它停掉后 SoC 降了 5.5/6.1/2.7 °C（tsens1/tsens8/pm8994，电池还在充电）。`72` 也给了"持久退役"的做法：**改 `/etc/systemd/system/zl1-debug-net.service` 的 `ExecStart`**，因为那个路径可写。

**这一轮证明那个做法不可能生效**，而且理由在引导镜像里，不在设备上：v63 的 `zl1-postswitch-debug-init` **每次开机都重写 keeper 的脚本和它的 unit**（还有两个 `*.target.wants` 符号链接），所以任何改动下一个开机就没了；而看起来能活下来的 drop-in **也救不了**，因为**活下来的那个进程根本不是 systemd 启的那个**——同一条钩子在 systemd 存在之前就把 keeper 直接后台启动了，keeper 的互斥是一把 `mkdir` 锁，ramdisk 那个实例先拿到，systemd 那个实例看见有活的 primary 就 `exit 0`。**剩下唯一不需要动引导镜像的杠杆，是 keeper 自己的形状**：它是一个纯 shell 脚本，由 ramdisk 启动、没有任何东西会重启它、退出时自己的 trap 会清掉锁——**开机后杀掉它，直到下次重启之前都不会回来**。`scripts/install-retire-debug-keeper.sh` 就是这件事，而且**它看不见地址就拒绝动手**。

**接续**: [`72`](72-the-heat-was-the-governor-and-a-debug-keeper.md)（两个热源、以及那个现在被否掉的退役方案）、[`88`](88-the-addresses-are-ours-now-not-only-the-keepers.md)（地址现在是 netwatch 的活，这才是退役的前提）、[`78`](78-the-sensors-came-back-without-a-reboot.md)（热测量的方法学）。证据原文在 `docs/ubuntu-touch/evidence/debug-keeper-retirement-2026-09-23.log`。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| doc 72 说的"改 unit 的 ExecStart"能持久吗？ | **不能**：钩子第 632 行 `cat > "$ROOT/etc/systemd/system/zl1-debug-net.service"`，每次开机重写；keeper 脚本本身也一样（第 313 行） |
| 那 `/etc/systemd/system/zl1-debug-net.service.d/` 的 drop-in 呢？ | **活得下来**（钩子不碰 drop-in 目录，`/etc` 也优先于 `/run`），**但没用**：systemd 那个实例不是活下来的那个 |
| 活下来的是哪个？ | **钩子第 1587-1588 行直接后台启的那个**——它在 systemd 之前就跑起来了，并在第 347 行用 `mkdir` 拿了锁；systemd 的实例在第 354 行打 `keeper duplicate exit v63` 后 `exit 0`，于是 `Restart=on-failure` 永远不触发，unit 整轮都是 `inactive (dead)` |
| 那还剩什么？ | **在开机后杀掉它**：没有东西会重启它（unit 是 dead 的，脚本自己没有 supervisor，锁由它自己的 EXIT trap 清掉），到下次重启为止不会回来 |
| 安全吗？ | 是。usb-moded 的遮蔽是 `/run` 里的文件（比 keeper 活得久）；地址由我们自己的 `zl1-netwatch.service` 每个采样重新声明（`ensure_addrs()`，装在这次之前是故意的）；重启把 keeper 原样还回来 |
| 有什么代价？ | **这是每次开机做一次的事，不是持久的**。真正持久的退役只有一条路：改引导镜像（§6），不做 |

## 2. doc 72 的方案为什么不可能生效

钩子 `boot/v63/scripts/init-bottom/zl1-postswitch-debug-init`，带行号：

```
    4  ROOT="${rootmnt:-/root}"                       # initramfs 里，这就是真的 rootfs
  313  cat > "$ROOT/usr/local/sbin/zl1-debug-net.sh" <<'EOF_ZL1_DEBUG_NET'
  ...
  630  EOF_ZL1_DEBUG_NET
  632  cat > "$ROOT/etc/systemd/system/zl1-debug-net.service" <<'EOF_ZL1_DEBUG_NET_UNIT'
  641  ExecStart=/usr/local/sbin/zl1-debug-net.sh
  642  Restart=on-failure
  647  chmod 0644 "$ROOT/etc/systemd/system/zl1-debug-net.service"
  648  ln -sf ../zl1-debug-net.service "$ROOT/etc/systemd/system/sysinit.target.wants/zl1-debug-net.service"
  649  ln -sf ../zl1-debug-net.service "$ROOT/etc/systemd/system/multi-user.target.wants/zl1-debug-net.service"
```

`$ROOT` 是真的根文件系统（initramfs 还在跑时 root 挂在 `rootmnt`），所以这几行写的就是**在用的那份**。脚本、unit、两个启用符号链接**每次开机无条件重建**。改哪个都没用。

## 3. drop-in 活得下来，但救不了：活下来的不是 systemd 那个实例

同一条钩子在 systemd 启动**之前**就把 keeper 直接后台拉起来：

```
 1587  if [ -x /usr/local/sbin/zl1-debug-net.sh ]; then
 1588      /usr/local/sbin/zl1-debug-net.sh >/dev/kmsg 2>&1 &
 1589      log "started zl1 debug network keeper from init wrapper pid=$!"
```

而 keeper 的互斥是**原子的 mkdir**，不是 systemd 认识的任何东西：

```
  329  LOCKDIR=/run/zl1-debug-net.lock
  347  if mkdir "$LOCKDIR" 2>/dev/null; then
  348      record_primary_lock
  350      trap cleanup_primary EXIT HUP INT TERM
  351  else
  353      if [ -n "$primary" ] && kill -0 "$primary" 2>/dev/null; then
  354          log "keeper duplicate exit v63 pid=$$ ppid=$PPID primary=$primary ..."
  355          exit 0
```

于是普通的一次开机是：

1. ramdisk 启动 keeper，它拿到锁（doc 72 里是 pid 817）；
2. systemd 之后启动它自己的实例，那个实例看见有活的 primary，打一行 `keeper duplicate exit v63`，**以 0 退出**；
3. 因此 `Restart=on-failure` 永不触发，unit 整轮都是 `inactive (dead)`。

这正是 doc 72 记下的"它的 unit 因为脚本自己 daemonize 而在 67 ms 后就'退出'了"的机制——而且它说明 **systemd 的 unit 是条死路**：覆盖它的 `ExecStart` 改的是那个本来就会放弃的实例。

（**这一步是推论，不是测量**：上面 2/3 是从锁的代码 + doc 72 记录的 `systemctl status` 推出来的，没有在设备上重测（设备整轮在 EDL）。`install-retire-debug-keeper.sh --status` 就是为下一次开机把这件事摆出来写的——它逐个打印 keeper 进程的 pid/ppid/comm/cgroup 和锁目录内容，一条命令可查。）

## 4. 剩下的杠杆，和让它安全的四件事

keeper 的主循环（第 611-629 行）每秒做：重写自己的 runtime unit、`systemctl mask --runtime usb-moded.service` + `stop`、遍历 `/proc/[0-9]*` 杀 usb 管理器、强制 RNDIS gadget、给 `usb0`/`rndis0` 配地址、启动调试服务。**它没有任何自我重启的机制**：unit 是 dead 的，没有别的 unit 引用它。所以杀掉它之后，直到下次重启都不会回来——下次开机会被钩子原样重建。

让它安全的四件事：

1. **usb-moded 的遮蔽比 keeper 活得久。** `maybe_systemctl_mask_usb`（第 423 行）是 `systemctl mask --runtime` + `stop`，钩子还额外做了更直接的 `ln -sfn /dev/null /run/systemd/system/usb-moded.service`（第 404 行）。两者都是 `/run` 里的文件，整轮有效。杀掉 keeper **不会**把 usb-moded 放回来跟 RNDIS 打架。
2. **地址现在是我们自己的服务负责的。** `zl1-netwatch.service` 每个采样重新声明 rndis0 的地址（`ensure_addrs()`，日志里是 `ADDRS:`），而且**它是在这次之前装的**——所以第一个用来证明新路径的开机，恰好是一个 keeper 本来也会干这件事的开机（`88`）。
3. **拒绝条件**：applier 等 `rndis0`/`usb0` 上出现两个地址之一，**等不到就什么都不做，明确写进日志**。没有地址，正是 keeper 可能还是唯一能给地址的那个东西的状态——所以这个方向必须是保守的那个。
4. **不可逆的方向什么都没有**：重启把 keeper 原样还回来（钩子重建两个文件）。

## 5. 交付的东西，以及离线测试改掉了什么

`scripts/install-retire-debug-keeper.sh` 在可写的 `/etc/systemd/system` 上装两个文件（就是本端口所有 unit 住的那个路径）：

```
/etc/systemd/system/zl1-retire-debug-keeper.sh         applier（纯 shell，幂等）
/etc/systemd/system/zl1-retire-debug-keeper.service    oneshot，DefaultDependencies=no，
                                                       After=local-fs.target zl1-netwatch.service，
                                                       Before=multi-user.target
```

模式：`--status`（默认，只读）／`--install`（装 + 启用，**对当前这次开机什么都不改**）／`--install --now`（顺手在当前这次开机上也退役）／`--remove`／`--explain`。

applier 的**杀、拒绝、复活**三条路径都在主机上用 stub（`systemctl`/`logger`）加一个假 keeper（cmdline 是 `/bin/sh /tmp/fk/keeper.sh`）跑过：

| 场景 | 结果 |
|---|---|
| 关门（主机上没有 rndis0/usb0） | **拒绝**，假 keeper 一根毛都没动 ✓ |
| 有东西每 4 秒把它拉起来 | 识别为 **RESTART**（不是"没杀掉"）并如实报告 ✓ |
| 干净地杀 | 消失，并在观察窗口内确认 ✓ |

**第一版在这里栽了一次，值得记下来，因为它是"仪器"和"隐患"的分界。** 它用**整个 cmdline 的子串匹配**找 keeper：

```sh
c=$(tr '\000' ' ' < "$d/cmdline" 2>/dev/null)
case "$c" in *"$KEEPER"*) echo "$p" ;; esac
```

子串匹配会命中**任何命令行里恰好提到这个路径**的进程——一个 `ps | grep zl1-debug-net.sh`、一个正在跑本项目脚本的 shell、一个打开着这个文件的编辑器。离线测试里它命中的是测试脚本自己，applier 把测试 shell 杀了：测试当场死在半路，工具报 exit 144、输出截断。**在设备上，同样的匹配会杀掉一个无关进程，可能是人正在用来调试的那个 shell。**

现在要求这个路径**必须是参数本身**：

```sh
is_keeper_cmdline() {
    set -- $(tr '\000' '\n' < "$1" 2>/dev/null)
    case "${1:-}" in
    "$KEEPER") return 0 ;;
    esac
    case "${1:-}" in
    */sh|*/dash|*/bash|*/busybox|sh|dash|bash|busybox)
        case "${2:-}" in
        "$KEEPER") return 0 ;;
        esac
        ;;
    esac
    return 1
}
```

——匹配 keeper 真实的形状（`#!/bin/sh` shebang，所以它的 cmdline 是 `/bin/sh /usr/local/sbin/zl1-debug-net.sh`，跟 doc 72 里 `ps` 打出来的一样），别的一概不匹配；并且跳过自己的 pid。

验证那一步也改成了**区分两种失败**，第一版把它们混成了一句：

* 原 pid 集合里的进程还在 → `SIGKILL did not take`（杀不掉的问题）；
* 出现了一个**原本不在集合里**的 pid → `something RESTARTED the keeper as pid N -- SIGKILL was not the problem; the retirement needs a different lever`。

第二种意味着**只有改引导镜像才能退役它**，所以它被当成一条独立的事实记下来，而不是混进"还在跑"里。

## 6. 唯一能"持久"退役的办法（不做）

只有一条：**改引导镜像**。`boot/v63/scripts/init-bottom/zl1-postswitch-debug-init` 就是创建脚本和 unit 的那个文件；改它、用 `scripts/make-halium-postswitch-debug-boot.sh` 重建 ramdisk、再刷 boot，才能从源头去掉 keeper。那是引导镜像写入，是本项目明确要用户点头的那一类改动；而且**为了让温度降下来，并不需要它**——上面那个"每次开机杀一次"在每一次开机上的热效果是一样的，代价只是每次重启后要再来一次。

## 7. 这一轮**不**证明什么

* **没有在设备上验证** systemd 那个实例就是会退出的那个。锁的代码和 doc 72 记录的 status 与它一致，但没有重测；`--status` 会在下次开机把它摆出来。
* **不证明没有 keeper 的开机能保住地址。** 那正是 `zl1-boot-address-check.sh` 测的东西，也是它被当作门槛的原因。
* **没有量热差。** applier 在退役的那一刻会记下 keeper 自己的 CPU ticks（`/proc/<pid>/stat` 第 14+15 字段，HZ 来自 `getconf`），就是为了让 `zl1-thermal.sh --ab` 有前后可比——但这个对比还没做。
* **这个退役不是持久的。** 这里没有任何东西改引导镜像；除了那个"下次开机再杀一次"的 unit，这里没有任何东西能活过一次重启。
* **什么都没装。** 设备在 EDL，这是一个准备好的改动，等一个决定。

## 8. 复现

```bash
cd /mnt/data/zl1-bb10

# 钩子每次开机重写两个文件（313/632/648-649），并且自己直接启动 keeper（1587-1589）
grep -n 'cat > "\$ROOT/usr/local/sbin/zl1-debug-net.sh"\|cat > "\$ROOT/etc/systemd/system/zl1-debug-net.service"\|zl1-debug-net.sh >/dev/kmsg' \
     boot/v63/scripts/init-bottom/zl1-postswitch-debug-init

# 锁、duplicate-exit 分支、EXIT trap
sed -n '329,356p' boot/v63/scripts/init-bottom/zl1-postswitch-debug-init

# 主循环
sed -n '611,629p' boot/v63/scripts/init-bottom/zl1-postswitch-debug-init

# 设计和两种 drop-in 的对照（什么都不改）
bash scripts/install-retire-debug-keeper.sh --explain
```

| 文件 | 作用 |
|---|---|
| `scripts/install-retire-debug-keeper.sh` | 新增。`--status`（默认，只读）／`--install`／`--install --now`／`--remove`／`--explain`。装一个 oneshot unit，它在每次开机后（等地址出现、最多 45 秒）杀掉 v63 调试 keeper 并观察 30 秒确认；先 `systemctl mask --runtime` 它的 unit，再 TERM、再 KILL，区分"杀不掉"和"被重启"两种失败；记下被杀进程的 CPU ticks 供热对比。**看不见地址就拒绝动手。** |
| `docs/ubuntu-touch/evidence/debug-keeper-retirement-2026-09-23.log` | 新增。钩子的逐行证据（脚本/unit/直接启动/锁/主循环）、为什么 drop-in 没用、三件让它安全的事、离线测试的三种场景与那个子串匹配 bug 的前后代码 |
