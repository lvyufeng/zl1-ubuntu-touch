# 99 — 剩下的那个发热修复，离线一跑就是坏的：一个 shell 函数的变量是**调用者**的

**日期**: 2026-09-23
**状态**: 纯离线的一轮（设备在 EDL，`05c6:9008` / port 3-3，与 `86`–`98` 同）。这一轮给两个**会写设备状态**的安装器写 harness，第一个跑起来就抓到**真缺陷**：`install-retire-debug-keeper.sh` 的 applier 在"没地址"的那条路径上**直接死掉**，而那条路径正是它整个安全论证的落脚点。设备整轮没有测量。

**接续**: [`72`](72-*.md)（发热的两个来源）、[`94`](94-retiring-the-v63-debug-keeper-is-a-kill-not-a-unit-edit.md)（退休只能靠 kill，不能改 unit）、[`86`](86-*.md)（panic → EDL 是默认武装的）、[`98`](98-the-fingerprint-chain-has-two-more-layers-under-the-wrapper.md)（上一轮，同一套 harness 手法）。证据原文在 `docs/ubuntu-touch/evidence/installer-selftest-2026-09-23.log`。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 这一轮做了什么？ | 给两个"会写设备状态、此前没有任何 harness"的安装器写了 `scripts/host/zl1-installers-selftest.sh`（**128 项**） |
| 为什么是这两个？ | `install-retire-debug-keeper.sh` 是**剩下的那个发热修复**，它的 `--install --now` **会在设备上杀进程**；`install-no-edl-on-panic.sh` 决定一次 panic 会不会把手机送进 EDL |
| 抓到什么？ | `install-retire-debug-keeper.sh` 的 applier **在"没地址"时是死的**：`iface()` 里的 `for i in rndis0 usb0` 用的是**调用者的变量名**，把等待循环的计数器改成了字符串 `"rndis0"` |
| 后果（在设备上）？ | `i=$((i + 1))` 对 `"rndis0"` 做算术 → dash 打印 `Illegal number: rndis0` 并**退出整个脚本**。所以：**拒绝分支从来不执行**，`REFUSING` 从来不打印，unit 报失败而日志里一个字都没有 |
| 更糟的那种？ | 若两个网卡都不存在，`iface` 回显空、`i` 被清空、`$((' + 1))` 恒为 1 → **死循环**。在这个"就是为了把一颗核还回来"的脚本里，占满一颗核（只有 systemd 的 `TimeoutStartSec=180` 能结束它） |
| 有地址时呢？ | **正常**。`has_address` 第一次就成功，`&& break` 在算术之前跳出，所以 kill/verify 都跑得通——harness 的 kill 断言在修复前**是通过的** |
| 所以这是什么性质的缺陷？ | **失败路径上的缺陷，不是happy path 上的**。安全方向是"碰巧"保住的（它在杀任何东西之前就死了），但那是意外，不是设计，而且解释没了 |
| 第二个缺陷？ | 有两个 keeper 进程时，`retiring keeper pids=[900` 换行 `905]` ——`keeper_pids` 每个 pid 一行，`PIDS=$(keeper_pids)` 保留了换行，而 `log()` 造的是**一行**。于是一条日志变成两条，第二条从句子中间开始 |
| 怎么修的？ | 助手函数的变量全部加下划线前缀 + 计数器改名 `_w`（并写下为什么）；`PIDS=$(keeper_pids \| tr '\n' ' ')` 归一化 |
| 怎么证明修的是这个？ | harness **先在 `HEAD` 的脚本上跑**：5 条红，全部是同一个缺陷的五个侧面（§3）。在同一个版本上通过又通过的 harness 什么都没证明 |
| 动设备了吗？ | 没有。假 `/proc`、假网卡地址、假内核参数、假 unit、假 logcat 全是编的；镜像只读挂载 |

---

## 2. 缺陷的形状：一个函数改了调用者的变量

applier 的闸门是这样的（修复前）：

```sh
iface() {
    for i in rndis0 usb0; do                     # <-- i 是调用者的 i
        [ -e "/sys/class/net/$i" ] && { echo "$i"; return; }
    done
}

has_address() {
    i=$(iface)                                   # <-- 于是父 shell 的 i 变成 "rndis0"
    ...
}

i=0
while [ "$i" -lt "$WAIT_S" ]; do
    has_address && break                          # <-- 第一次调用就把 i 毁了
    sleep 1
    i=$((i + 1))                                  # <-- 对 "rndis0" 做算术
done
```

shell 函数**没有局部变量**，`iface()` 在同一个 shell 里跑，`for i` 就是那个 `i`。三种状态各跑一次（都在假设备里，`WAIT_S` 缩到 3 秒，外面套 `timeout`）：

```
A. 两个网卡都不存在      rc=124   还在跑  -> 死循环，占满一颗核
B. rndis0 存在且有地址   rc=0     正常    -> 第一次 has_address 就成功，&& break 在算术之前
C. rndis0 存在但没地址   rc=2     死掉    -> "Illegal number: rndis0"，在拒绝检查之前退出
```

**B 和 C 的差别就是这一轮最要紧的一句话**：坏的是 C——那条为"看不到地址就拒绝"而写的路径。而 B 正常，所以任何"它根本不杀进程"的说法都是错的；harness 的 kill 断言在修复前是通过的，这一点是故意保留在报告里的。

C 的后果具体是：`--install --now` 之后 `systemctl show -p Result -p ExecMainStatus` 报失败，而 `journalctl -t zl1-retire-keeper` **一条都没有**。文档 94 建立的整套叙事是"applier 总是退出 0，一次失败的退休是一行日志，不是一次失败的启动"——那一行从来没有机会被写出来。

A 的后果是它的反面：这一轮之前它被认为"只是不干活"，实际上是**给设备加热**。

---

## 3. 证明 harness 有牙：同一份 harness 对着 `HEAD` 的脚本跑

```
$ git show HEAD:scripts/install-retire-debug-keeper.sh > /tmp/zl1-inst-prefix/scripts/...
$ git show 55a490e:scripts/install-retire-debug-keeper.sh > /tmp/zl1-inst-prefix/scripts/...
$ sh /tmp/zl1-inst-prefix/scripts/host/zl1-installers-selftest.sh
FAIL  the applier refuses
FAIL  and says what it is leaving alone
FAIL  and names the interface it looked at
FAIL  a build whose gate does not recognise the address that IS there refuses too
FAIL  only the two whose ARGV IS the keeper are matched
pass=123 fail=5
```

5 条红，**是同一个缺陷的五个侧面**：第 3 节的三条是拒绝闸门根本没执行，第 5 节的两条是"没有地址时 applier 在第 68 行就死了，所以既配不上任何东西也说不出任何东西"。反过来说，第 4 节那些关于 kill 和 verify 的断言**在 `HEAD` 上全部通过**——这正是诚实读法：这是一个**失败路径**上的 bug。

---

## 4. 这个 harness 的设计：`ssh` 就是那台设备

两个安装器都是 `bash` 脚本，通过 ssh 驱动设备，而它们的**设备侧 applier 是 here-doc**。这就是它们可以在离线被真测的原因——不需要编造设备，harness 提供一台：

* **`ssh` 桩 = 设备本身**：它剥掉连接参数，然后**在本地把远端命令跑起来**，设备绝对路径全部映射进假根树，桩目录放在 PATH 前面。于是 `--install` 的 `cat > /etc/systemd/system/...` 是**真的在写文件**，`--status` 的远端脚本是**真的在遍历一个 `/proc`**。
* **路径映射是一份独立的 sed 脚本**（`$W/paths.sed`），因为它要用在**两处**：命令串，以及命令是 `sh -s` 时（安装器就是这么发 `--status` 脚本的）的**stdin**。只管命令串的话，那段脚本会继续指向**宿主机的** `/proc` 和 `/sys`。而 `cat > FILE` 形式的 stdin **故意不映射**：那些载荷是 applier，它们跑在设备上，必须保留设备路径。
* **`kill` 必须是桩**，而且只能是桩：真发 `kill -TERM 4242` 会杀掉宿主机上碰巧占这个 pid 的进程。它是**按设备进程表的行为**写的——删掉假 `/proc/<pid>`。这也让 applier 的 verify/watch 循环第一次变得可达：`$W/killignore/<pid>` 让信号"杀不动"，`$W/restart` 让东西杀完立刻回来。
* **`systemctl start <unit>` 跑 unit 自己的 `ExecStart`**，所以 `--install --now` 走的是设备会走的那条路；harness 另备一份改好路径的 applier 副本，**落地文件的内容**单独断言（在改写之前）。
* **`ip` 桩输出真实的 `ip -4 addr show dev` 形状**——接口一行、地址缩进一行。这个缩进是有承载力的：applier 取匹配 `inet ` 那行的**第 2 个字段**，单行 fixture 会把网卡名放进那个字段，于是每个场景的闸门都答"没有地址"——**那是 fixture 在撒谎，不是脚本的 bug**。

---

## 5. 写这个 harness 时，harness 自己犯的错（都记下来）

一个 harness 的假检查和一个不存在的检查，代价是一样的。这一轮自己在三处栽了：

1. **未加引号的 here-doc 里的反引号是命令替换。** `ip` 桩的注释里写了 `` `ip -4 addr show dev X` `` 和 `` `awk '/inet /{printf "%s ", $2}'` ``。第一对反引号把 ``ip`` 跑了一遍，第二对把 ``awk`` 跑了一遍——而那个 `awk` **没有文件参数，于是去读 harness 自己的 stdin，永久阻塞**。重定向 `> "$STUB/ip"` 先执行，所以文件被截断成 **0 字节**，而 harness 挂在 0% CPU 上。**未被引号包裹的 here-doc 的注释里不许有反引号**；那次卡死就是它。
2. **`kill` 是 shell 内建命令**，PATH 桩拦不住它。第一版 harness 里 applier 的 `kill -TERM 900` 走的是内建，假 `/proc/900` 纹丝不动，于是"survived SIGTERM → SIGKILL → did not take"三条假象全出来了。现在副本按**路径**调用桩（这也是安全要求，不只是可观测性要求）。
3. **安装器把 applier 的 stdout 走了 `tail -4`。** 所以 `--now` 的输出是那本日志的一个**窗口**，不是日志本身。applier 的 `log()` 同时写 `logger` 和 stdout，所以断言改读 **logger 记录**（设备上 `journalctl` 会读到的那份），只有"操作者看见什么"才断言 `$OUT`——并因此钉住了最后一行确实是操作者看见的那行。

还有两处是**fixture 不真实**：`ip` 的单行输出（上面第 4 节），以及 `status` 里 `$KEEPER` 的路径——传输层必须重写它（`--status` 要 `ls -l $KEEPER`，而在宿主机的真 `/usr/local/sbin` 里造文件不是测试该做的事），所以假设备进程表的 cmdline 就该写假根里的那份，和真设备一样。

---

## 6. 这个 harness 覆盖什么（128 项）

```
== 1.  --status 和 --explain 什么都不改（快照比对：整个假设备的文件集）
== 2.  --install：恰好两个文件、内容逐条断言、enable 但**不** start、当前这次启动什么都没变
== 3.  拒绝闸门：没地址就必须**不杀**（信号一条都没有），并且说清它在放过什么
== 4.  有地址：杀、验证、以及**说清是哪一种失败**（杀不动 vs 被重新拉起）
== 5.  匹配按 argv 而不是子串：只是"提到"那条路径的 shell / grep 不许被杀，pid 1 不许被杀
== 6.  --remove：disable、只删自己那两个文件、并说出"当前这次启动的 keeper 仍然死着"这句实话
== 7.  no-edl：--capture-only **不许碰** policy unit（它自己注释里记着的那次缺陷）
== 8.  no-edl：--install 写四个文件、两个 unit 都 enable --now、并复述那条警告
== 9.  policy applier：写、读回、写不进去就**失败**（返回 1），参数不存在也返回 1
== 10. pstore applier：空 pstore 不算失败、有记录就按 boot_id 归档、只留最新 4 份
== 11. flag 面与守卫，外加两个安装器不许互相指错文件
```

第 7 节是照着 `install-no-edl-on-panic.sh` 自己的注释写的：它记着"早先的草稿在 capture-only 里把 policy unit 禁用并删掉了"——也就是**一次看着像只读的巡检，把已经装好的守卫悄悄卸了**，而且是往不安全的方向。harness 因此**驱动两种状态**（本来没装 / 本来就装着），并断言后者活下来。

---

## 7. 这一轮**不**证明什么

* **对设备的结论：零。** 设备在 EDL；每一个网卡地址、`/proc` 条目、内核参数、unit、日志计数都是合成的。两个安装器**从来没有在设备上跑过**。
* **被证明的是"它们写什么、什么时候拒绝"**——这正是它们存在的理由，也正是离线能定的部分。
* **`systemctl start` 是桩模拟的**：桩跑 unit 自己的 `ExecStart`，这是 systemd 文档下 `Type=oneshot` + `RemainAfterExit=yes` 的行为，不是这台设备 systemd 的实测。
* **keeper 的代价没有被重新测量。** `72` 的"一颗核、5.5/6.1/2.7 C"是那次 A/B 的数字；"退休它值不值得"要靠**设备上**的那次测量，而那是欠着的三条之一。
* **`install-no-edl-on-panic.sh` 这一节通过，完全不代表清掉 `download_mode` 就真能让设备不进 EDL。** 它自己的头部写着：强制 watchdog bite 仍然会发生，而这块 bootloader 是否**独立于该 flag** 把 watchdog 复位当成进 download 模式的条件，从来没有被测过——只能靠 panic 设备来测，而**那不该做**。
* **反向也不成立**：这一轮没有证明 `--install --now` 在真设备上一定会成功退休 keeper。`gx`/`usb-moded`/`netwatch` 在真实启动里的时序是设备上的事（`94` 的 gate：先要 `zl1-boot-address-check.sh` 说 `netwatch-configured`）。

---

## 8. 复现

```sh
# 全部在宿主机上，只需要 /bin/sh、bash、sed、awk、find
sh scripts/host/zl1-installers-selftest.sh          # 128 项
sh scripts/host/zl1-installers-selftest.sh --keep   # 留下假设备、桩、改写后的 applier 与变异体

# 先证明 harness 真的在测这个缺陷：把当前整棵树拷出去，只把这一轮修的那个脚本退回到修复前的 revision。
# 只退它一个，是因为 harness 后来也覆盖了别的安装器，那些脚本的缺陷会在同一个数字里混进来。
#
# **"修复前"要写成一个固定的 revision，不能写 HEAD。** 修复一提交，HEAD 就是修好的版本，
# 同一份 harness 会开始拿修复跟它自己比 —— 而这真的发生了（docs 101 记下了它，以及那个永远只可能
# PASS 的守卫）。这个缺陷的修复是 3a26b66，之前是 55a490e。
rm -rf /tmp/zl1-inst-prefix && mkdir -p /tmp/zl1-inst-prefix
cp -r scripts /tmp/zl1-inst-prefix/
git show 55a490e:scripts/install-retire-debug-keeper.sh > /tmp/zl1-inst-prefix/scripts/install-retire-debug-keeper.sh
sh /tmp/zl1-inst-prefix/scripts/host/zl1-installers-selftest.sh   # 5 条红，同一个缺陷

# 回到设备之后，这两条是恢复顺序里的第 0c / 0d 项
sh scripts/install-no-edl-on-panic.sh --capture-only    # 免费：只装 pstore 捕获，不碰策略
sh scripts/install-retire-debug-keeper.sh --status      # 只读：keeper 是谁拉起的、两个地址在不在
sh scripts/install-retire-debug-keeper.sh --install     # 只装，当前这次启动什么都不变
sh scripts/install-retire-debug-keeper.sh --install --now   # 真的退休（一次 kill）——**用户的决定**
```

| 文件 | 作用 |
|---|---|
| `scripts/host/zl1-installers-selftest.sh` | 新增。128 项，覆盖两个安装器的每个模式、两个设备侧 applier、以及四个 helper 的每个失败分支；`ssh` 桩就是那台设备 |
| `scripts/install-retire-debug-keeper.sh` | 修：助手函数变量加下划线前缀、计数器改名 `_w`（附原因），`PIDS`/`back` 的换行归一化 |
| `docs/ubuntu-touch/evidence/installer-selftest-2026-09-23.log` | 这一轮的原始输出：缺陷三种状态的实测、两处修复原文、128 项全文、对着 `HEAD` 的 5 条红 |
| `docs/ubuntu-touch/99-*.md` | 本篇 |
