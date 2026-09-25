# 161 — 界在步骤上，挂起在调用里

**日期**: 2026-09-25
**状态**: 这一轮**碰了设备**（一次只读的开机链），而且这一轮的第一个成果是**承认上一轮那次开机
是哪一步花掉的**。五个读数在这一轮被证明是假的，而它们的形状是同一个：**你量的那一层，不是出问题的
那一层。**
① 界下在**步骤**上，而挂起发生在步骤**发出的那个调用**里；
② 界的公式**手写**在步骤的一侧，而真正的项数在 callee 里；
③ EDL 事故的"归因"来自一个把**每次健康开机都会打的字**当成死亡签名的仪器；
④ "archive 里没有死亡签名"来自一个**只看了前六分钟**的见证。
⑤ 而"哪个 archive 是那台死掉的 boot"来自 `ls -dt`——**这台设备的时钟是错的**，
所以那个顺序是任意的，而读错一个 archive，印出来的字**一模一样**。

**接续**: [`131`](131-the-steps-had-no-clock-and-a-hang-spends-the-boot.md)（每一步都要有墙钟界的由来）、
[`132`](132-the-bound-was-on-the-steps-and-not-on-the-calls-between-them.md)（同一个形状，在 runbook 里修过一次，
**从没走到这一轮要修的 callee**）、
[`149`](149-the-bound-of-one-boot-has-to-be-read-out-of-its-callee.md)（界要从 callee 的源码里数出来）、
[`134`](134-the-false-fail-was-in-the-pipeline-s-writer.md)（pipefail 把写者的死读成判词）、
[`95`](95-the-first-commands-after-recovery-are-offline-verified.md)（EDL 之后第一批命令的离线验证）、
[`86`](86-edl-has-a-cause-a-panic-and-the-evidence-survives.md)（panic → EDL 这条路）、
[`89`](89-one-gate-to-edl-is-closed-and-it-is-reversible.md)（那道门可以被关上，而且是可逆的）、
[`159`](159-the-driver-was-built-into-the-image-and-the-image-is-the-reading.md)（镜像的读数）、
[`160`](160-the-third-heat-cause-had-an-experiment-and-no-installer.md)（散热第三因的安装器）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 上一轮那次开机花在哪一步？ | 花在 **ssh 客户端自己**：`04b-modem` 的最后一行（`container pid 34906; its own view of the firmware mount:`）写在 05:19，归档写在 05:24 —— 中间约 **4 分 09 秒**，那个 ssh 没有回来，而设备上**没有任何子进程**。 |
| 那这算谁的错？ | 算**界的位置**：设备侧的 `timeout -k 5 $STEP_LIMIT` 在 **ssh 的另一侧**。远端命令已经跑完、客户端挂死时，设备侧一行字都不会打。 |
| 为什么以前没修？ | 同一个形状在 [`132`](132-the-bound-was-on-the-steps-and-not-on-the-calls-between-them.md) 修过一次——**修在 runbook 里**，从没走到它调用的那个 callee。 |
| 这一轮的修法是？ | **结构性的**：无界的 `run_bg` **从文件里删掉**，只剩一个 `run_bg_bound LIMIT SECONDS cmd`，五个调用点全都改掉；harness 断言"源码里不存在无界的 runner"。 |
| 两个界是多少？ | push 用 `IO_LIMIT=60`；ssh 与 host 步用 `HOST_BACKSTOP=$((STEP_LIMIT + 30))`。backstop **故意比设备侧松**——设备侧那个 `timeout` 发的是**进程组**信号，它才是应该先响的。 |
| 两个 124 怎么分？ | 靠**标记**：设备侧包一层，`124|137` 时打 `ZL1STEP-TIMEOUT device`。没有这个标记的 124 是**链路**，不是手机——措辞也分成两段。 |
| identity 块错在哪？ | 它**无条件**印 `ok`。实测那份 `00-identity.txt` 是 **173 字节 5 行**，缺 `keeper pids` / `keeper cpu ticks` / `failed units`，而脚本印的是 `ok`。 |
| runbook 的界改了吗？ | 改了：`19 x 245 + 120 = 4775 s` → **`19x65 + 19x275 + 4x275 + 120 = 7680 s`**。旧式子的理由是"identity 块、归档和三个 HOST 步骑在 slack 里"——它们**没有骑在任何东西上**。 |
| EDL 事故归因了吗？ | **没有。**而且这一页**要撤掉上一轮几乎写下的那个归因**：`zl1-edl-postmortem.sh` 印的 `FOUND: a kernel oops/panic is on record` 是**假阳性**。 |
| 为什么是假阳性？ | 它的签名表里有裸的 `watchdog` 和 `Call trace`，而**每一次健康开机**都会印 `MSM Watchdog Initialized` 和 6 段 `WARNING:` 的 `Call trace:`。 |
| 还有第五件事吗？ | 有：`keep/boot-92165447-…/` 里 9 个快照停在 **363 s**，而那台 boot 活了 **2299 s**——**不是 ring 绕了，是采集器早就结束了**。"没有死亡签名"只覆盖了前六分钟。 |
| 这一轮把假读数改成了什么？ | 命中的 pattern 必须**点名**（`matched 'Kernel panic'`），含歧义的词变成**数出来的读数**（`not-as-a-sig…`），缺的读数**写下来**（`MISSING, and missing is not zero`），`--diff` 先印**层表**再印选项，而层表的比较用**整个值**。 |
| 层表当场抓到了什么？ | 抓到它**自己**的比较宽度：第一版比较的是截断后的字符串。改成比整个值之后，又照出 harness 的 fixture **两轮以来读的一直是空 cmdline**（boot 头里 `name` 与 `cmdline` 的位置写反了），而没人发现是因为**没有任何断言读过 cmdline 的值**。 |
| 刷了吗？ | **没有。**刷镜像这一轮仍然**没有**做。 |
| 那"发烫解决了吗"？ | **没有。**三个散热修复里，这一轮只让**第二个**（panic guard）在真机上落地，另外两个仍未运行过。 |

---

## 2. 那次开机：ssh 没回来，而印的是 ok

归档在 `tmp-one-boot-20260925T051409Z/`（`INDEX.txt` 说 `INTERRUPTED: yes`）。它记下来的事：

```
-- 01-edl-postmortem    ok      (97 lines)
-- 02-boot-address      FAILED rc=1          # 判词说"这次开机对 netwatch 那条路什么都没说"
-- 03-keeper-status     ok      (44 lines)
-- 04-health-check      ok      (1685 lines)
-- 04b-modem
INTERRUPTED: archived what had run
```

`04b-modem.txt` 的**最后一行**是这一句，之后什么都没有：

```
   container pid 34906; its own view of the firmware mount:
```

那一步的下一件事是 `nsenter -p -t 34906 -m -- …`，进容器读它自己看到的挂载。文件 mtime 05:19，归档
05:24。中间那 **4 分 09 秒**里，设备侧**没有子进程**——远端命令已经结束，挂住的是客户端。

**这就是"界不在这一层"的最干净的形态。**`step()` 对设备步的守卫是真的：

```sh
timeout -k 5 $STEP_LIMIT sh /tmp/$base $args     # 在设备上，发的是进程组信号
```

但它**在 ssh 的另一侧**。客户端挂死时，设备侧没有任何东西可杀、也没有任何东西会打日志。
而这一侧当时是**没有界**的：`run_bg` 只是 `"$@" &` 加 `wait`。

### identity 块：这一轮唯一一处"读被打断而记录说它好了"

同一个脚本更早的地方，`00-identity.txt` 是**173 字节、5 行**：

```
boot_id: 92165447-1906-4c94-a926-3b4abcf91d50
captured: 2026-09-25T05:14:10Z
host: Linux 5.15.0-190-generic
uptime: 2021.96 589.93
kernel: 3.18.140-lineage-gc2f6e859-dirty
```

缺三行：`keeper pids`、`keeper cpu ticks (utime+stime)`、`failed units`。而脚本对这一步印的是：

```
   ok   (-> 00-identity.txt)
```

`note "ok"` 当时是**无条件**的——它精确地印在了那个挂过的调用上。于是这一轮把两件事一起改了：

* **缺的读数要写下来。**文件短了不会自己宣告自己短，而这个文件是后面每个读数用来对时间的那个。
  现在失败会写 `identity: NOT READ -- …（the link, not the phone）`、
  `identity: THE LINES ABOVE THIS ONE ARE THE WHOLE OF WHAT CAME BACK.`、
  `identity: cpu ticks are MISSING, and missing is not zero`，并且 `note` 印
  `PARTIAL rc=$_irc -- 00-identity.txt is SHORT and says which readings are missing` 且计入 `FAIL`。
* **两个半边要分得开。**`uptime`/`kernel` 回来了而 `keeper pids` 没回来，是关于一个遍历 `/proc`
  的循环的读数（keeper 那一段是约 650 次 `cmdline` 读，在这颗 SoC 上要花掉几秒的系统调用时间）；
  **一整个都没回来**才是链路。

---

## 3. 修法是结构性的：无界的 runner 从文件里删掉

`run_bg` 有五个调用点，每一个都是"挂死的 ssh 可以吃掉一次开机"的位置。而把它**留在文件里**当
"以后别再这么调"的约定，正是 [`132`](132-the-bound-was-on-the-steps-and-not-on-the-calls-between-them.md)
那一轮的结果：修在 runbook 里，callee 从没被改到。所以这一轮不是"避免"它：

```sh
run_bg_bound() { # bounded-call LIMIT SECONDS, then the command
  local lim="$1"; shift
  timeout -k 5 "$lim" "$@" &
  RB_PID=$!
  wait "$RB_PID"
  RB_RC=$?
  RB_PID=""
}
```

**文件里现在只有一个 runner，它永远要一个界**，而 harness 有一节**结构性**地断言源码里不存在
`run_bg()` 的定义。危险是从树里**移走**的，不是"记得别这么写"。

两个界，各自有各自的理由：

| 界 | 值 | 为什么是这个值 |
|---|---|---|
| `IO_LIMIT` | `60` | 一次 push：链路是通的，脚本很小。和散热链给自身读回用的界同尺寸。 |
| `HOST_BACKSTOP` | `STEP_LIMIT + 30` | **故意比设备侧松**：应该先响的是设备侧那个 `timeout`，它的进程组信号才能到"步骤自己生出来的孩子"。这个界只为"那个 timeout 根本来不及跑"的情况存在——死掉的 socket、掉了的链路、卡住的 ssh。 |

**两个 `timeout` 都退 124**，所以判词不能靠退出码。设备侧包一层，自己印标记：

```sh
timeout -k 5 $STEP_LIMIT sh /tmp/$base $args
zr=$?
case $zr in
  124|137) printf '%s\n' 'ZL1STEP-TIMEOUT device' >&2 ;;
esac
exit $zr
```

于是 `124` 的注释分成两段，一段说**手机**，一段说**链路**：

* 有标记 → `the DEVICE's own timeout(1) ended this step at ${STEP_LIMIT}s … check the load in 04.`
* 没标记 → `the HOST BACKSTOP ended this step at ${HOST_BACKSTOP}s, with no marker from the device's
  own timeout(${STEP_LIMIT}s) in its output: the ssh never came back. This is a reading about the LINK,
  not about the phone -- the step's own output stops where the socket died.`

harness 里加了一节用**桩**复现这个形状（`FP_SSH_HANG` 让桩 `sleep 3600`），而不是让某个 callee 睡
很久——睡很久的 callee 仍然是一个**最终会回来**的 ssh，而"回来晚了"和"从没回来"是两种不同的失败。

---

## 4. 界要从 callee 里数出来

runbook 给 `01-capture` 算的那个界，公式是**手写**在**另一边**的：

```
旧: 19 x 245 + 120 = 4775 s
    理由是 "the identity block, the archive and the three HOST steps ride in the slack"
```

**它们没有骑在任何东西上。**4775 s 这个数字写在 INDEX.txt 里，而那次开机的 identity ssh 就是在这
个数下面挂掉的——上限**看起来**很宽，实际上一个调用可以把它整段吃掉。新的式子：

```
19x65 + 19x275 + 4x275 + 120 = 7680 s
```

每一项都是 callee 真的会发的一个调用，而且**每一侧都有界**：

| 项 | 来自 |
|---|---|
| `19 x (60+5)` | 19 个设备步各一次 push，界是本侧的 `IO_LIMIT` |
| `19 x (240+35)` | 同一个步的 ssh：设备侧 `STEP_LIMIT`、本侧 `STEP_LIMIT+30`（`-k 5` 之后） |
| `(4+1) x (240+35)` | 3 个 host 步 + 归档，**再加 1**——identity 块不是一行 `step`，数不进那个计数，所以单列 |
| `+ 120` | slack |

`_cap_shape()` 现在返回**四个**数（设备步数、host 步数、`STEP_LIMIT`、`IO_LIMIT`），两个新的都是
**从 callee 读出来的**；读不到就返回非零 → 该步退回平界，**并把这件事说出来**——那不是通过，是
"本该让它安全的那个检查没有发生"。

harness 的 fixture 跟着改（`STEP_LIMIT=240` / `IO_LIMIT=60` / 3 个 device 步 / 1 个 host 步 →
**1690 s**，超过平界 900 s，所以走的是"computed from the callee"那一支而不是地板那一支——**走哪一支
本身就是一个读数**，所以断言点名的是**形式**而不只是数字）。`noboundshape` 变异也跟着改了它的 `sed`。

---

## 5. EDL 事故的"归因"是假的

上一轮那次开机的结尾是：总线变成 `05c6:9008`（EDL）。设备**自己回来了**（新 boot_id
`61c4abf0-1ec6-467d-bfd3-bf09169d99d7`，`18d1:d001`），当轮在它上面装了 panic guard
（`bash scripts/install-no-edl-on-panic.sh --install`），`download_mode` 读 **0**，这一轮复核仍是 0。

`download_mode` 当时是 **1**，因为 **`01-capture` 排在 `02-panic-guard` 之前**。这是那个顺序的张力，
不是谁忘了：**读证据的步骤必须在最前面**（pstore 只活到下一次 reset、ring 一分钟就绕），而**关上那道门
的步骤排在它后面**。这一轮把这句话写下来，不假装它不存在。

### 而唯一一个"归因"是这个仪器自己造的

`zl1-edl-postmortem.sh` 在那次运行里印了：

```
   *** contains a death signature ***
…
== verdict
   FOUND: a kernel oops/panic is on record, in the witness marked above.
```

那一刻它读的是 `keep/boot-0488bd3c-…/boot-84s.log`。而那份日志的"死亡签名"是这几行：

```
| [    0.410836] Call trace:
| [    0.791549] Call trace:
| [    1.612153] Call trace:
```

**`t < 2 s` 的 `Call trace:` 是开机警告的栈回溯。**实测在一个**活着的**开机上（`0488bd3c` 的 84s
快照——它之后还产出了更多快照，所以它**证明性地**没有死）：

| pattern | 次数 |
|---|---|
| `WARNING:` | **6** |
| `Call trace:` | **6** |
| `watchdog` | **2** |
| `Kernel panic` / `Unable to handle kernel` / `Internal error` / `BUG:` / `Going down for restart` / `PC is at` / `WDOG: watchdog bite` | **全是 0** |

签名表里有裸的 `watchdog`（`msm_watchdog 9830000.qcom,wdt: MSM Watchdog Initialized` 就匹配）和裸的
`Call trace`（每段 `WARNING:` 的栈回溯都匹配）。**所以这个仪器对任何一次开机都会说"有 oops 在案"。**

### 修法：判词要点名，歧义要数出来

* 两个含歧义的词**移出判词**，变成**数出来的读数**：
  `not-as-a-signature: 'Call trace' x6, 'watchdog' x2  (a healthy boot prints both …)`。
  "某文件里有 6 个 `Call trace`"是关于日志的**事实**；"有 oops 在案"是这个脚本只有**能点名**它读的
  是哪一行时才配说的话。
* 命中必须**点名自己的 pattern**：`*** contains a death signature *** matched 'Kernel panic'`。
  判词的模式匿名就**无法复核**——而这正是一个假阳性同时躲过一次手写 harness 和一次真机运行的原因。
* `PC is at` 保留在判词集里，虽然它在健康开机上测得 0：它是真的 oops 标记（出错的那条指令），
  只是上面那 6 个 `WARNING:` 不打它。

### harness 缺的那个 fixture：一次**真的**开机

harness 有七个设备状态，而代表"干净开机"的那一个是**一行编出来的字**。真开机不是那样的——
于是**不能触发探测器的反例什么都不证明**。新加的 H 状态是**真开机该有的形状**：6 组
`WARNING:` + `Call trace:`，加 watchdog 自己的两行 init。对**改之前**的仪器跑它，红 4 条，其中一条
正是这个：

```
FAIL  H: the verdict DOES say [contains a death signature] -- the two strings EVERY healthy boot prints are out of the verdict pattern
```

同一轮里，H 也断言了那些词现在是**数**（`not-as-a-signature: 'Call trace' x6, 'watchdog' x2`）。

### 第九个状态：**"哪一个 archive 才是死掉的那台 boot"本身也要能报否**

改完之后在真机上跑，第二个见证仍然印 `no death signature`——而它读的是 **`boot-92165447`**，
也就是**真的死掉的那一台**。这一句是对的，但它当时**几乎是错的**：选 archive 的那一行是

```sh
newest="$(ls -dt "$K"/boot-*/ 2>/dev/null | head -1)"
```

而**这台设备的时钟是错的**（见 [`64`](64-the-last-unit-was-not-failing-it-was-obeying.md)，doc 69 也
引过它：墙钟排序会骗人）。`keep/` 下四个 archive
的 mtime 全都一样，`ls -dt` 于是给出一个**任意**顺序——实测它把 `boot-0488bd3c` 排在最前、
把**真正死掉的那台 `boot-92165447` 排在最末**。所以"没有死亡签名"这句话读到的是**别的 boot 的日志**，
而它会以完全相同的样子印出来。

规则改成**读采集器自己的日志**：drain 每次开机都往 `keep/archive.log` 追加一行
`<uptime> prev=<boot_id> files=N`，那个 id 是**上一台** boot，所以取**最新的一行、且它的 archive
还在**。两个坑都在 fixture 里按住：

* **"最后一行"不是规则。**archive 会被"最新 4 台"裁掉，而**行还在**——实测最后一行指的是
  `boot-61c4abf0`（那台**活的** boot，被采集器一次**开机中途重启**按自己的 id 归档的），
  而那个目录已经被裁掉了。所以是"最新的、且目录还在的那一行"。
* **"最新 4 台"这个裁剪本身以前是按 `ls -dt` 排的**，也就是按那个坏时钟排的——它会把**该留的**
  裁掉。这一轮它至少不再删**本台 boot 自己的**快照（见下）。

判词现在**说出是哪条规则答的**（`chosen by: archive.log, the newest entry whose archive still exists`），
`ls -dt` 退回成 fallback 并且**被标注**（`ls -dt -- and this device's clock is wrong, so that order is
arbitrary`），因为"最新的 archive"在被证明之前是一个**关于时钟的说法**。

第九个 fixture（`I`）就是让这两条规则**互相对立**：两个 archive、`ls -dt` 先排到**错的**那个、
日志指向**对的**那个，中间还夹一行指向**已被裁掉**的目录。而它自己先断言**fixture 确实对立**
（`'ls -dt' ranked 'boot-dead00', not boot-old01, so this state cannot tell the two rules apart`——
第一版写的 fixture 两个目录在同一毫秒里创建、`ls -dt` 随便断了平局，这个状态**什么都没测**却全绿）。
对**改之前**的仪器跑，I 状态红 **4** 条，其中包括
`the verdict DOES say [boot-old01 is a *previous*]`——它**指名道姓地把错的 boot 报成了候选**。

harness 44 → **57** 项（第八、第九两个状态，加上新状态自己的 fixture 自检）。

---

## 6. 见证只到 363 秒

那台死在 EDL 的 boot 活了 **2299 s**（`01-edl-postmortem.txt` 自己印的），而
`keep/boot-92165447-…/` 里是 **9 个快照**：

```
boot-36s.log boot-41s.log boot-46s.log boot-52s.log boot-62s.log
boot-82s.log boot-122s.log boot-203s.log boot-363s.log
```

差值 `5 5 5 10 20 40 80 160` **就是采集器的那一行**，只是 unit 在 ~35 s 才起来。也就是说：

> **不是 ring 绕了，是采集器早就结束了。**

所以"archive 里没有死亡签名"这句话，对那台 boot 来说只覆盖了**前六分钟**；而它死于第 38 分钟。
采集器的 doc-comment 里写着 "coverage of the first ~2 minutes"，像是这是设计——它是设计，但**它
和"这台机器会不会在后半夜死"没有关系**。

改法是把序列排到一次开机装得下：`for d in 5 5 5 10 20 40 80 160 320 320 640 640 1280 1280` ——
**15 个快照**，最后一个是 **4841 s**（约 80 分钟）。每个 ~250 KiB，一台开机 ~3.75 MiB，`keep/` 留
四台，整个归档不到 15 MiB（`/userdata` 有 11 GiB 空）。

**而安装器结尾那句话以前是手打的 schedule**（"~0, 5, 10, 15, 25, 45, 85, 165, 325 s"），这一轮它
改成从**刚推上去的那个脚本里读出来**：

```sh
_sched=$(printf '%s\n' "$SNAPSHOT_SH" | sed -n 's/^for d in \(.*\); do$/\1/p')
```

读不到就拒绝报告（`refusing to report a schedule`）。已经装到设备上——它只写 `/userdata/zl1-kmsg`
与 `/etc/systemd/system` 的两个 unit，**下一次开机生效**。

### 同一轮查出来的第二个缺陷：采集器会把**正在跑的这台 boot** 当成"上一台"

`--install` 会 enable 并 **start** 那个 unit，所以这个单元**在一台活的 boot 上也会被启动**
（这一轮为了换 schedule 就装了两次）。而搬运那一段的假设是"`current-boot-id` 里的 id 一定属于**别的**
boot"——它由**上一次**运行写，正常情况成立。但在一台活的 boot 上重启时，`prev` **就是本台**：

```
prev=61c4abf0-1ec6-467d-bfd3-bf09169d99d7  files=9      <- 本台 boot 被按自己的 id 归档
prev=61c4abf0-1ec6-467d-bfd3-bf09169d99d7  files=4      <- 紧接着 rm -f 删掉了它自己的 5 个快照
```

一个**以正在运行的 boot 命名的目录**不是任何东西的见证；而那次 `rm -f` 删掉的，是**一台还在跑的
boot 的唯一副本**。修法是在搬运与删除**之前**先比一次 id：`RESTART=1` 时两步都跳过，日志里留一行
`skip prev=… (this boot -- mid-boot restart: nothing carried forward, nothing deleted)`——
**"什么都没做"这件事也要留下读数**，否则下一次读日志的人分不清"没重启"和"重启了但没记"。

---

## 7. 第 (b) 半：`--diff` 的两层

同一个形状，换一层。`zl1-boot-image-kernel.sh --diff A B` 以前只印**选项**差异，而**选项是一层**：
`-fpdriver` 与 `-fpdriver-modemfw` 会打出

```
0 option(s) differ
```

——因为一个改的是**内核**、另一个改的是 **initramfs**。而读这句话的人会得出结论"这两张镜像一样"，
然后在**决定开机的那一半**上错。现在的 `--diff` 先印**层表**：

```
boot image (whole file)                  a1b2c3d4e5f60718  a1b2c3d4e5f60718  same
kernel blob (what the bootloader loads)  …                 …                 same
decompressed Image                       …                 …                 same
appended device trees (5 FDT)            …                 …                 same
ramdisk                                  …                 …                 DIFFERS
cmdline                                  …                 …                 same
   -> 2 of 6 layers differ: boot image (whole file); ramdisk
      (a ramdisk difference is INVISIBLE to the option list below: the config is one layer)
```

设备树那一行带 **FDT 数**：`(none)` 在**两侧都**是"没有附着的设备树"的样子，而"都没有"不能看起来
像"有相同的树"。每个读数都不是单独成立的判词——**层表说哪个文件动了，选项表说内核里面动了什么**。

### 而这张表当场就抓到了一个东西：它自己的 fixture 读的是空 cmdline

层表的第一版把**显示宽度**当成了比较宽度（比较的是 `[:16]` 截断后的字符串），于是两张
cmdline 有 493 个字符、只在第 16 个字符之后不同的镜像，会被印成：

```
   cmdline                                  androidboot.hard androidboot.hard same
```

——**这正是这张表被写出来要消除的那个缺陷，低了一层。**改成"比较**整个值**、只把**显示**截短"，
并把显示宽度写在表下面。

而这一改，立刻发现了一个**两轮之前就存在**的 fixture 缺陷：harness 造的那个 boot 头，把 16 字节的
`name` 字段放在了 **cmdline 该在的位置**（真实顺序是 `name[16]` → `cmdline[512]` → `id[8]`，
fixture 写的是 `id` → `name` → `cmdline`）。读出器 `d[64:64+512].split(b'\0')[0]` 于是从一个 NUL
开始——**这个文件里每一个 fixture 的 cmdline 都读成了空**。两轮没人发现，因为**没有任何断言读过
cmdline 的*值***，只断言过那个标签出现过。新加的 `--cmdline` fixture 选项和层表的 cmdline 行是把它
照出来的那面镜子，而同一轮里补上的那对 fixture 现在断言：**只在显示宽度之后不同的 cmdline 仍然读
`DIFFERS`**。

harness 92 → **109** 项，变异从五个到**六个**（新的那个印出层表的**汇总**而扔掉它的**行**——
"对一批从未印出来的行下判词"比没有表更坏）。

---

## 8. 这一页不要你相信什么

* **事故的归因仍然是零。**pstore 当时和现在都是空的；`keep/` 里那台 boot 的最后见证停在 363 s
  （§6）。三个候选——`04b-modem` 里 `nsenter` 进容器的那一步、我在这台 boot 上刚做的
  `rfkill unblock bluetooth`、热与负载——**一个都没有被证伪或证实**。修好的仪器会让**下一次**事故
  有话说，它不是对**这一次**的答案。
* **panic guard 不是"EDL 不可能了"。**它关的是"panic 在 `download_mode=1` 下带 dload 标记复位"这条
  路；强制 watchdog bite 没有被碰，而且"这台 bootloader 是否在标记之外也进 EDL"从来没有测过。
* **`02-boot-address` 那次 `FAILED rc=1` 不是设备坏了**：它的判词是"这次开机对 netwatch 那条路什么
  都没说"（装的是没有 `ensure_addrs()` 的旧版，地址是 keeper 配的）。它是**一次读不出结论的读**，
  记为 FAILED 而不是通过。
* **三个散热修复里，这一轮没有一个新跑过。**这一轮在真机上落地的只有 panic guard。

---

## 9. 怎么重跑这一页的每一条读数

不需要设备：

```
bash scripts/host/zl1-post-recovery-capture-selftest.sh      # 179 -> 197 项
bash scripts/host/zl1-one-boot-runbook-selftest.sh           # 235 项
bash scripts/host/zl1-edl-postmortem-selftest.sh             # 44 -> 57 项（八、九两个状态）
bash scripts/host/zl1-boot-image-kernel-selftest.sh          # 92 -> 109 项（层表的读数是真镜像跑的）
bash scripts/host/zl1-selftest-family.sh                     # 40 个 harness / 5419 项 / 全绿
```

而**假阳性那一条**是这么离线复现的：把 harness 指向改之前的仪器
（`git show <rev>:scripts/device/zl1-edl-postmortem.sh`），H 状态立刻红 4 条，其中一条就是
`the verdict DOES say [contains a death signature]`；**同一份改之前的仪器**，I 状态也红 4 条，
其中一条是 `the verdict DOES say [boot-old01 is a *previous*]`——它把**错的**那台 boot 报成了候选。
两次都用同一句：`git show <rev>:... > /tmp/pretest/scripts/device/zl1-edl-postmortem.sh`，
再把这个 harness 和 `host/zl1-health-check.sh` 拷进 `/tmp/pretest/scripts/host/` 跑（**不要**在仓库里跑，
家族 harness 会给整棵树打指纹）。

需要设备（只读）：

```
scp scripts/device/zl1-edl-postmortem.sh root@10.15.19.82:/tmp/ && \
  ssh root@10.15.19.82 'sh /tmp/zl1-edl-postmortem.sh'
```

这一页里**在设备上跑过**的两条读数就是上面这条（改好的仪器，输出见 §5/§6）和
`bash scripts/install-kmsg-drain.sh --install`（§6，只写 `/userdata` 与两个 unit）。

---

## 10. 阶段位置

这一轮**没有刷任何分区、没有动 boot 镜像**。设备上发生的事只有两件：panic guard 装上并读回
（`download_mode` 仍读 0），以及 kmsg 采集器换了新 schedule（下一次开机生效）。

下一步仍然要电，顺序不变：

1. **闸门**：墙充 + `bash scripts/host/zl1-battery-gate.sh --samples 9 --interval 60`（doc 150）。
2. **闸门之后**：`scripts/host/zl1-one-boot-runbook.sh --yes`——六步，`01-capture` 现在带 7680 s 的界，
   而它里面的每一个调用两侧都有界。若 05 说 `supported-not-proven`，**06 会把散热第三因装上**。
3. **下一次从 EDL 回来时**：`scp` 那个**改好的** post-mortem 上去跑——它是唯一能读上一台 boot 的东西。
4. **只有用户明确同意才做**：刷 `halium-boot-zl1-v63-fpdriver.img` 或 `-modemfw`
   （撤销是刷回 `halium-boot-zl1-v63-rebuilt.img`，`ac0dd8619c05763c…`）。

**而这一页最后要说的一句是：这一轮把四个"看起来在回答、其实答的是另一层"的读数改成了会自己说出来的
读数——包括把自己上一轮几乎写下的那个 EDL 归因撤掉。**事故仍然没有原因，发烫仍然没有被解决，
而这两件事现在各自有一个**能报否**的仪器。
