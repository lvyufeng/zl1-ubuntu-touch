# 165 — 结束状态那两行是**读者自己的假设**：一条从来没有被执行过的读数

**日期**: 2026-09-25
**状态**: 纯离线一轮（改了 `host/zl1-heat-fix-chain.sh` 的一段设备侧程序 + 它的 harness），
然后**在设备上只读地**验证了修好之后的那段程序（没有重启、没有写任何东西）。
这一页记的是 docs 164 第 5 节点名的那两个缺陷、它们的机制、修的方法、
以及**为什么 197 条绿检查看不见它们**。

**接续**: [`164`](164-the-third-heat-cause-is-installed-on-a-clean-baseline.md)（这两个读数是那一趟存档里读出来的）、
[`94`](94-retiring-the-v63-debug-keeper-is-a-kill-not-a-unit-edit.md)（keeper 是谁启动的、怎么启动的）、
[`112`](112-the-proof-is-a-race.md)（同一个地址在被谁拥有这件事）、
[`163`](163-the-parameter-is-a-bool-and-the-guard-disarmed-its-own-undo.md) §5（读者的 fixture 不需要 shim，
但**必须真的跑**——这一页是那条规则的另一面）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 坏的那个读数是什么？ | 散热链收尾时那段设备侧程序印的 `keeper: 287596` 和 `addrs: … 10.15.19.100=0`。 |
| 为什么 keeper 那行是假的？ | 两个原因叠在一起：**名字猜错了**（它找 `*zl1-debug-init*`/`*zl1-debug-keeper*`，而 keeper 叫 `/usr/local/sbin/zl1-debug-net.sh`），**匹配方式是整条 cmdline 的子串**——而那段程序自己是 `ssh host '<整段文本>'` 送上去的，**它自己的文本就在它自己的 argv 里**，所以它匹配到了它自己。 |
| 有证据吗？ | 有，两次。存档里 `keeper: 287596` 出现在「这一次开机 argv 匹配的 keeper 数是 0」的那次开机上；手工在设备上原样跑那段循环得到 `keeper: 2356709` 与 `my pid: 2356709`——**同一个 pid**。 |
| 地址那行呢？ | `10.15.19.100` 是**主机**在 `usb0` 上的地址，而这台设备**没有 `usb0`**，它自己的两个地址（`192.168.2.15/24`、`10.15.19.82/24`）都在 `rndis0` 上。所以那半行**任何一次开机都不可能读到 1**，而旁边的散文把它叫作「这条链存在的目的」。 |
| 为什么 harness 一直看不见？ | 那个 harness 把答案**当 fixture 文件交给脚本**（`$W/state.txt`），所以这段设备侧程序**从来没有被执行过**——一段没跑过的代码，名字写错、匹配到自己，都不会红。 |
| 修完了吗？ | 修完了，**并且在设备上读到了**：`keeper: gone` + 两个地址都 `present`——这是第一次真的印出那句散文承诺的结束状态。 |
| 有反证吗（修完的 matcher 真的能找到进程吗）？ | 有，是**正对照**：把 `KEEPER` 设成这台设备上**正在跑**的 `/etc/systemd/system/zl1-netwatch.sh`，同一个程序印出 `keeper: 128538`，而 `128538` 就是 `/bin/sh /etc/systemd/system/zl1-netwatch.sh`（见第 4 节的普查）。 |

---

## 2. 那两个读数是怎么来的

### 2.1 keeper：名字错 + 子串匹配 = 匹配到自己

旧程序在两个地方各有一份（`--status` 一份、收尾读回一份），两份都长这样：

```sh
for p in /proc/[0-9]*; do
  c=$(tr "\0" " " < "$p/cmdline" 2>/dev/null) || continue
  case "$c" in *zl1-debug-init*|*zl1-debug-keeper*) k="${p#/proc/}"; break ;; esac
done
```

* keeper 的真名在 `install-retire-debug-keeper.sh:100`：`KEEPER=/usr/local/sbin/zl1-debug-net.sh`。
  两个模式**都不是它**。
* 匹配的是 `$c`，即**整条 cmdline 拼成一个字符串**；而这段程序是 `ssh host '<文本>'` 送的，
  远端那个 `sh -c '<文本>'` 的 cmdline 是 `/bin/sh\0-c\0<文本>`——**文本里有 `zl1-debug-init` 这个字面量**。
  于是它找到的第一个进程是它自己，`break`，印出自己的 pid。

手工复现（设备上原样跑那段循环，见证据日志第 3 节）：

```
keeper: 2356709
my pid: 2356709
```

证据日志第 3 节还有一个更干净的同型证据：在一台**没有任何 keeper** 的设备上数「cmdline 里含
`zl1-debug` 的进程」，答案是 **1**——而那个 1 就是**执行这条统计命令的进程自己**。

### 2.2 地址：问错了接口，而且是问主机自己的地址

```sh
printf "addrs: 192.168.2.15=%s 10.15.19.100=%s\n" \
  "$(ip -4 -br addr show rndis0 2>/dev/null | grep -c "192.168.2.15")" \
  "$(ip -4 -br addr show usb0   2>/dev/null | grep -c "10.15.19.100")"
```

`10.15.19.100` 是**主机**的地址：`zl1-rndis-recover.sh`、`zl1-rndis-udev-helper.sh`、`host-watch-usb0.sh`、
`verify-device-online.sh` 四个主机脚本设的是它。设备自己的一对是 `192.168.2.15/24` 与 `10.15.19.82/24`，
两个都在 `rndis0` 上——`device/zl1-boot-address-check.sh:86` 读的就是这一对：

```sh
for a in 192.168.2.15/24 10.15.19.82/24; do
```

所以 `10.15.19.100=0` 不是「地址掉了」，是**问了一个这台设备没有的接口上的、属于主机的地址**。

---

## 3. 修的是什么

三件事，都在 `host/zl1-heat-fix-chain.sh` 里，而且**合并成了一个函数** `dev_end_state()`：
两份拷贝就是这些缺陷存在两份的原因。

| 旧 | 新 |
|---|---|
| 猜 `*zl1-debug-init*`/`*zl1-debug-keeper*` | 从 `install-retire-debug-keeper.sh` 里**读出** `KEEPER=`；读不到就印 `keeper: UNKNOWN (…)`，并且 `--status` 上头先打一行 NOTE 说明**它不会拿猜出来的名字去比** |
| 整条 cmdline 子串匹配 | **按 argv 位置**匹配：`argv[1]` 就是路径，或者 `argv[0]` 是 shell 而 `argv[1]` 是路径；同时跳过自己的 pid |
| `ip … show usb0`（主机的地址） | `ip -4 -br addr show` 一次，问的是**设备自己的** `192.168.2.15/24` 与 `10.15.19.82/24`；`ip` 说不出话时印 `addrs: NOT READ (…)`，而不是两个 ABSENT |

**argv 规则的第二个半边才是这台设备需要的**，这一点值得写下来：keeper 是 v63 的引导钩子启动的
（`install-retire-debug-keeper.sh` 第 26–29 行，docs 94）：

```sh
if [ -x /usr/local/sbin/zl1-debug-net.sh ]; then
    /usr/local/sbin/zl1-debug-net.sh >/dev/kmsg 2>&1 &
```

带 shebang 的脚本被 exec 成 `<解释器> <脚本>`，所以 keeper 的 cmdline 是
`/bin/sh\0/usr/local/sbin/zl1-debug-net.sh\0`——**`argv[0]` 不是它**。这不是假想形状，这是**就是它**。

第 4 节的普查把这条落到了实处：这台设备上**所有** shell 脚本进程都是这个形状
（`/bin/sh /etc/systemd/system/zl1-netwatch.sh`、`/bin/sh /userdata/zl1-kmsg/snapshot.sh`、……）。

---

## 4. 在设备上验证（只读）

设备是**同一次开机**：`boot_id 2fbf9f8e`（17:12 那次重启之后的那一次，docs 164），
USB `18d1:d001`（RNDIS），没有重启。三件事，全部只读：

1. **修好之后的 `--status`**（跑的是仓库里现在这份）：

```
  netwatch: file=present fn=has-ensure_addrs unit=active
  keeper: gone
  addrs: 192.168.2.15/24=present 10.15.19.82/24=present
  governors: interactive interactive interactive interactive
```

  这句散文承诺的结束状态（keeper gone + 两个地址 present）**第一次真的印出来了**。

2. **形状普查**（`pid|argv[0]|argv[1]`）：把所有 `argv[0]` 是 shell 的进程列出来，得到 9 行——
   **8 行是 `/bin/sh <脚本>`**（keeper 的形状就是这一种），第 9 行是普查命令自己那个 `bash -c`
   （瞬时的，就是第 2.1 节那份证据的同一个形状）。其中 `128538` 是 netwatch 的 pid。

3. **正对照**：把 shipped 的那段程序**逐字**抽出来（从脚本里 sed 出 heredoc 正文，不是重打一遍），
   把 `KEEPER` 设成正在跑的 `/etc/systemd/system/zl1-netwatch.sh` → 印出 `keeper: 128538`。
   **负对照**：`KEEPER` 设成 keeper 自己的路径 → `keeper: gone`（这一趟 keeper 已经不在了，
   而普查里也没有任何进程提到它）。两次运行里，那段程序**都没有把自己报成 keeper**。

原始输出全部在 [`evidence/chain-end-state-reader-2026-09-25.log`](evidence/chain-end-state-reader-2026-09-25.log)。

---

## 5. harness：把答案交给脚本，不算测

`host/zl1-heat-fix-chain-selftest.sh` 里那两条读数的答案曾经是**一个 fixture 文件** `$W/state.txt`，
由 ssh stub `cat` 出来给链：

```
netwatch: file=present fn=has-ensure_addrs unit=active
keeper: gone
addrs: 192.168.2.15=1 10.15.19.100=1
governors: interactive interactive interactive interactive
```

注意第三行——**这个 fixture 交给链的答案，任何一台设备都印不出来**（`10.15.19.100` 那是主机的地址，
而且这台机器上没有 `usb0`）。fixture 不但没有测那段程序，它还把正确答案**写成了**一个假的，
于是「链读到的东西」和「设备会说什么」之间那道缝，谁也没看见。

现在（215 条检查）：

* ssh stub 把命令交给 `$W/endstate.sh`：把**伪设备的根**映射进那段文本，然后**执行它**——
  `ip` 与 `systemctl` 是 stub，其余全是真的；`/proc` 是 fixture 造的四个形状：

  | 形状 | 内容 | 必须读成 |
  |---|---|---|
  | `proc_keeper` | `argv[0]` 就是路径 | `keeper: 4242` |
  | `proc_shellrun` | `/bin/sh\0<路径>`（**设备真实的形状**，第 3 节） | `keeper: 4245` |
  | `proc_bystander` | `/bin/sh\0-c\0ps -ef \| grep <路径>` | `keeper: gone` |
  | `proc_selfshape` | `/bin/sh\0-c\0KEEPER=<路径> …`（**读者自己的形状**） | `keeper: gone` |

* 地址有 `FP_ADDRS=both/one/none` 三档：只差一个地址时必须读出「那个地址 ABSENT」；
  `ip` 说不出话时必须读出 `NOT READ`，而**不许**印出两个 ABSENT；
* **映射自己也要被检查**：`endstate.sh` 数一数它那五条设备路径里有几条真的出现在程序文本里，
  写进 `endstate.count`，harness 断言 `mapped=5 of 5`。理由是一条具体的缺陷：
  没被映射的路径会去读**这台笔记本自己的** `/proc`、`/sys/devices/system/cpu`、`/etc/systemd/system`——
  这些路径**在这台机器上都存在**，所以映射一旦失效，读数不会崩，它只会**换一个被读的设备**。
  （这正是第一版 `endstate.sh` 的毛病：它用引号 heredoc 写、里面写的是 `$FR`，展开后为空，
  程序读的就是主机的文件系统，而第 2 节每一条都红。）

---

## 6. 三个变异：把缺陷放回去，harness 必须变红

这一节是这一页的**判据**。`keeper: gone` 这个断言有一个天然的空洞：
**一个从不匹配任何东西的读者也会印 `keeper: gone`**。所以三条变异各把一处缺陷放回去：

| 变异 | 放回去的缺陷 | 必须观察到 |
|---|---|---|
| `guessedname` | `KEEPER_BIN="/usr/local/sbin/zl1-debug-init.sh"`（猜名字） | keeper **正在跑**（fixture 里 `proc_keeper`）却报 `gone` |
| `oldsubstr` | 改回整条 cmdline 子串匹配 | `proc_selfshape` 那个进程被报成 `keeper: 4244`——**设备上那个假 pid 的复现** |
| `hostaddr` | `*10.15.19.100/24*` 换回设备自己的地址 | 设备**有**这个地址却读成 `ABSENT`——那半行永远读不到 1 的字面复现 |

每条变异前面都有一条「读回真的发生了」的断言（`netwatch: file=`），
不然一条**在动手之前就拒绝**的变异也能让后面的负向断言通过——这是这个 harness 里已经记过一次的形状。

---

## 7. 这一轮**没有**做的事，和一个仍然没有证据的问题

* **没有重启、没有写任何东西、没有刷任何分区**：设备上做的只有三次只读 ssh（`--status` 一次、
  普查一次、正/负对照各一次），全程无写；改动全在主机侧的两个文件里。
* **没有让 keeper 真的跑起来再读一次**。这一趟的正对照用的是**正在跑的其它脚本**
  （netwatch），因为把 keeper 拉起来正是这条链要干掉的那个热源。
  所以「keeper 在跑时这个读者能不能找到它」在**真机上**仍然是**没有证据**的：
  有证据的是（a）argv 规则能找到这台设备上正在跑的 `sh <脚本>` 形状的进程，
  （b）keeper 的形状就是那个形状（引导钩子那一行 + 普查），（c）keeper 不在时它说 `gone`。
  下一次真有 keeper 的开机上，`--status` 应该印出一个 pid；如果那时它印 `gone`，第一个要查的就是形状。
* **`zl1-v63-monitor.sh`**（普查里的 `750|/bin/sh|/usr/local/sbin/zl1-v63-monitor.sh`）还在跑——
  它是 ~3.4 KB/s 的那个写者，属于散热那一摊，不属于这一页。

---

## 8. 阶段位置

散热三因都装上了（docs 164），而**它们的仪器现在也读得对了**：收尾那三行不再断言主机的地址、
不再拿猜出来的名字比进程表，而且它**在 harness 里真的被执行**。
这一页买到的不是新功能，是**一条读数从「看起来对」变成「跑过、并且有正负对照」**。

下一个阶段：散热的**效果**还没有在新状态下量过（第三因是 06 才装的，那一趟的 A/B 只覆盖前两个），
所以下一次开机该做的是一次**三个成因都在**的 A/B；再往后是硬件清单上还没有驱动起来的那几项。
