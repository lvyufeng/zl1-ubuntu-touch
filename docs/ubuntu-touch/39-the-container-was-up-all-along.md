# 39 — 容器其实起来了；"卡在 coldboot_done 之前"是读数错了

**日期**: 2026-09-21
**状态**: **读数错误已定位并修好**。§4 的结论（容器能整个起来、而且链路同时是活的）
是本轮最重要的正面结果。
**推翻**: [`33-the-container-restart-loop.md`](33-the-container-restart-loop.md) §2 的机制

---

## 1. 先说结论

在 2026-09-21 这次开机上，Android 容器**完整地起来了**：

```
lxc-start=RUNNING ueventd=RUNNING hwservicemanager=RUNNING
servicemanager=RUNNING vndservicemanager=RUNNING zygote=RUNNING netd=RUNNING
fwmarkd socket: present
coldboot_done: present (pid 34801 reached Android boot completion)
host-ping: OK
```

同一时刻 `systemctl show lxc-android-config.service -p NRestarts` = **0**。
容器启动了一次，0.6 秒就写下了 coldboot 标记，之后一直在跑。

而在此之前，**每一次采样、每一次开机**，netwatch 和 `verify-over-ssh.sh` 都在报
`coldboot_done: absent (container is stuck before it)`。

## 2. 错在哪：问的不是容器那个进程

```sh
# 之前
cpid="$(pgrep -f 'lxc-start -n android' | head -1)"
[ -e "/proc/$cpid/root/dev/.coldboot_done" ]
```

`pgrep -f 'lxc-start -n android'` 返回的是 **lxc-start 这个宿主侧辅助进程**（34274），
它的 root 是**宿主的** `/`：

```
$ readlink /proc/34274/root
/
```

所以 `/proc/34274/root/dev/.coldboot_done` **永远不可能存在**——这条检查的答案在它被
写出来的那一刻就固定了。它不是"观察到容器卡住"，它是"问错了人"。

容器自己的 init 是**另一个 pid**：

```
$ lxc-info -n android -p -H
34801
$ readlink /proc/34801/root   # 也是 /，但这是一个在容器命名空间里跑的进程
$ ls /proc/34801/root/dev/.coldboot_done
present
$ cat /proc/34801/comm
init
```

而设备上那层 `lxc-android-ready` 包装脚本**一直是对的**——它用的是 `lxc-info -p`，
每次开机 6 个 tick（0.6 秒）就找到标记：

```
zl1-lxc-ready: container pid=34801
zl1-lxc-ready: android coldboot marker present after 6 ticks
zl1-lxc-ready: host property_service socket present after 0 ticks
zl1-lxc-ready: property area file count=165
```

**两套代码看同一个文件，一套说"在"、一套说"不在"**，而说"不在"的那套被人信了。

修法：新增 `container_pid()`，先用 `lxc-info -n android -p -H`，拿不到就在 `/proc/*/root`
里找带标记的那个。`verify-over-ssh.sh` 里同样的错也一起改了。

> 这类错误值得单独记一笔：它**不会自己暴露**。一个恒为 false 的判据，输出稳定、格式
> 合理、复现性完美——它看起来比真的还可靠。能戳破它的只有"换一个独立来源核对同一个
> 事实"，也就是这里的 `lxc-android-ready` 日志。

## 3. 连带推翻：doc 33 §2 的"无限等待导致重启循环"

[`33`](33-the-container-restart-loop.md) §2 的机制是：

> `lxc-android-ready` 结尾是 `while true; do [ -f .../.coldboot_done ] && break; sleep 0.1; done`
> ——没有超时。容器走不到那一步，`ExecStartPost` 就永不返回，systemd 于是反复重启容器。
> 143 次 / 9362 秒 ≈ 65 秒一次。

两处不成立：

1. **我们的 v63 镜像里那个脚本不是无限循环。** 它是 initramfs 在 switch_root 之前
   替换掉的（`boot/v63/scripts/init-bottom/zl1-postswitch-debug-init`，从
   [`0e95c3a`](../../) 起就在仓库里，也就是那次测量用的同一张镜像）：

   ```sh
   wait_for_path "/proc/$containerpid/root/dev/.coldboot_done" "android coldboot marker" 200 || true
   wait_for_path /dev/socket/property_service "host property_service socket" 200 || true
   log "exiting success so lxc-start stays available for diagnostics"
   exit 0
   ```

   200 tick × 0.1 s = 20 秒上限，然后**无论如何都退 0**。它不可能造成重启循环。

2. **"143 次"很可能是把重复打印当成了事件次数。** 累计的
   `/userdata/zl1-v63-monitor.log` 里 `Failed to allocate new network namespace id`
   出现 **46364 次**——但那一行是 lxc-start 在容器启动时打一次的 WARN，monitor 每个
   tick 都会把 lxc 日志的 tail 再抄一遍（`--- lxc-log-tail ---` 段）。所以这个字符串
   的出现次数是"tick 数"，不是"启动次数"。143 是同一类计数。

   这次的权威计数是 `NRestarts=0`，以及 journal 里**恰好一对** Starting/Started。

§1 里那些数字本身（zygote 0 次、netd 1 次、fwmarkd 0 次）是从 `pgrep` 来的，
`pgrep` 没有这个问题；它们描述的**那一次**开机仍然有效——那一次容器确实没走到 zygote。
被推翻的是**机制**（为什么重启）和**"容器从来起不来"这个一般化**。

## 4. 于是"链路好"和"容器起来"不再互斥

[`33`](33-the-container-restart-loop.md) §3 的推论是：链路稳是因为容器**从来没走到 netd**，
一旦 netd 起来就会断。这次两条同时成立：

| | 以前 | 这次 |
| --- | --- | --- |
| 容器 | 走到 netd 就断链 / 走不到 zygote | `coldboot_done` 在，zygote 在，netd 在，fwmarkd socket 在 |
| 链路 | 只在容器失败时稳 | **同时是通的**（`host-ping: OK`，`rxpkts` 持续上涨） |
| 策略路由 | 三张表被清空 / 规则被挤掉 | `routes=6`，开机第 36 秒加上后没再动过 |

最合理的解释是 [`35`](35-the-policy-routing-rule-that-kills-the-link.md) 那个修法：
把路由放进 netd **自己指向的三张表**里，而不是跟它抢 `ip rule`。netd 起来之后
`15000/16000/17000` 命中的表里已经有路由，`32000 from all unreachable` 就轮不到了。
[`37`](37-the-trial-that-had-no-peer.md) §2 已经证明这三张表 14.7 小时没被清过。

这不是"证明了卡死问题不存在"——它是第一次出现"容器整个起来 + 链路同时活着"的组合，
而历史上从没同时出现过。要多跑几次才能说它是稳的。

## 5. 顺带：netwatch 现在会报采样循环自己的停顿

`/proc/uptime` 的两个数是 uptime 和累计 idle。每两次采样头相减就是上一轮的耗时，
以及其中多少是真空闲。之前这份信息一直在日志里、没人读，于是 2026-09-21 那次
1.6 小时 CPU 打满只表现为日志里一个说不清的洞。现在超时就自己记一行，
并给出判词：idle 少 = 在烧 CPU，idle 多 = 在等什么东西。

## 6. 还没证实什么

- `coldboot_done` 在 ≠ Android 可用。它只说明 init 走完了 boot 标记那一步。
  屏幕、触摸、Wi-Fi 都还没测（Phase 5）。
- 上文 §4 的"容器和链路能共存"目前是 **1 次开机**的观察。按计划要冷启动复现 3 次。
