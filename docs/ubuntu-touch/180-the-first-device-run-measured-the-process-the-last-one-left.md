# 180 — 这台仪器第一次在设备上跑，量到的是**上一次留下的那个进程**

**日期**: 2026-09-26
**状态**: 改完并且**离线**证明（相机 harness 108 → **137** 条，family 在**冻结的**树上跑到
**43 个 harness 全绿、6230 条检查、0 红**，514 个 tracked 文件前后逐字节相同、没有新文件）；**判据命令已经上过设备两次**（§5a），第二次就在修完操作数之后——
它印出 `app stopped: stopped by SIGTERM`，于是**这一篇同时撤掉了它自己上一版里的一句话**：
"这个 app 忽略 SIGTERM"（见 §5a 那一节末尾）。另外在放行门上抓到并修掉了**第二个**红（§5b）：它不是设备的缺陷，
是三条把**宿主自己的秒数**写死的断言——同一个 harness 单独跑是全绿的，有负载才红。

这一篇不是从计划里来的。它来自**这一轮仪器自己在设备上印出来的第一行**：它说它量的是
那个刚起的 app，而它实际量的，是**二十二分钟前另一次手动探测留下的同一个进程**。

**接续**: [`104`](104-a-unit-error-can-make-a-gate-unfalsifiable.md)（同一台仪器的第一轮：
单位错了 100 倍，于是那条门**不可能失败**）、
[`178`](178-the-premise-of-a-measurement-is-a-reading.md)（A/B 的前提是一次**读数**，不是从调用点推的）、
[`179`](179-the-keeper-is-matched-by-argv-not-by-its-name.md)（上一轮：匹配一个进程要找 **argv**，不找名字）、
[`84`](84-the-camera-app-on-screen-is-one-command-now.md)（这台仪器本来就是为了回答这一个问题而写的）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 那个缺陷是什么？ | 仪器把**上一次运行留下的进程**量成了这一次的 app，而它印出来的证据表**属于另一个进程**。 |
| 它是怎么被看见的？ | 2026-09-26 的第一次设备运行印出 `alive pid=3710153`——和我二十二分钟前手动起、并且**以为已经停掉**的那个进程**同一个 pid**（它的 ppid 是一个**早就触发过**的 `timeout`）。而证据表里那两行 `Added camera 0/1`，是新进程的。**一个运行，两个进程的读数，混在同一个判决里。** |
| 为什么它一定会发生？ | 三件事叠在一起：**起 app 的那一步走 `/proc` 取第一个匹配**（[`179`](179-the-keeper-is-matched-by-argv-not-by-its-name.md) 的同一个形状）；第 6 步的停止**只有一个裸 `kill`**；而 `timeout` 也只送这一个信号。**这一版当时的第三个原因写的是"app 忽略 SIGTERM"——那条在 §5a 被撤掉了**（真正的第三件事是那个 `kill` 的**操作数是个路径**，dash 根本不认，所以一次信号都没送出去）。 |
| 它跟 [`104`](104-a-unit-error-can-make-a-gate-unfalsifiable.md) 是同一类吗？ | **是同一类，但换了一边**。104 那一轮的错误在**读数的单位**（东西量错了），这一轮的错误在**读数的对象**（量的是别的东西）。两次都是：仪器印了一个**看起来很正常的数**，而那个数**不是关于它声称的那个主体**的。 |
| 修法是什么？ | 把"没有相机 app 在跑"从**假设**变成**读数**——第 0.6 步，在开屏、启动之前问一次；有残留就**退出 1 并且什么都不碰**（不 `busctl`、不 `kill`）。`--clean-first` 是接受残留的那条路：先 SIGTERM、等 2 秒、还在就 **`kill -9`**，再复核，并且**把结果印成"哪一种信号起了作用"**。**跑不掉 SIGKILL 的进程终止整趟运行**，而不是被拿去量。第 6 步用同一个停止函数——运行结束时自己的 app 也走这条路。 |
| 离线怎么被证明的？ | `scripts/host/zl1-camera-app-test-selftest.sh` 从 108 涨到 **137** 条，新增**第 11 节**：残留让运行**退出 1 且什么都没碰**（断言输出里**没有** `busctl … call`、**没有** `kill`）、`--clean-first` 先 SIGTERM 后 SIGKILL（两条断言分别匹配 `^kill [0-9]+$` 和 `^kill -9 [0-9]+$`——**操作数必须是数字**，§5a）、健康的一趟结束时用同样的方式结束自己的 app、`--help` 里有这个开关，以及**两种信号结果各有 fixture**（默认"第一个信号不够"，`FAKE_SIGTERM_WORKS=1` 是设备那一次的 `stopped by SIGTERM`）。 |
| 写它的过程中抓到我自己什么错？ | 三条**过宽**的断言：`notwant "the app's own rate"` 会匹配到"它**不**证明什么"那一条（收紧成 `the app's own rate: `）；`notwant 'the app is being composited'` 会匹配到判词**自己的解释**（收紧成 `the app's window is being composited`）；还有一条引用漂移——健康检查里 108 应该写 126（family 的 `zl1-cli-usage-selftest.sh` 上一轮就是为了同一类漂移变红的；这一节后来又长到 **137**，引用同步）。 |
| 设备现在怎么样？ | **在跑**：`33e80afe` → `18d1:d001`（RNDIS），`boot_id 2fbf9f8e-deea-4955-ad0c-6bddf0fb14f5`。那次 `--keep-display` 的跑把**显示器留在了亮着**（那正是这个开关的用途：给人看），跑完之后 app 的残留进程用**数字** SIGKILL 清掉，显示器随后关回 `(ii) 0 0`。**没有写任何分区，没有重启，没有 panic。** |

---

## 2. 那个缺陷的形状：一个运行，两个进程

第一次设备运行的判决是这一句（上一轮已经记进 [`104`](104-a-unit-error-can-make-a-gate-unfalsifiable.md)
的续篇和 README）：

```
-> THE APP NEVER PAINTED: the app itself burned 0.1 ticks/s over window B
   -- under 1% of one core across 15 s of a live process (alive pid=3710153 state=S threads=11)
app threads waiting in: poll_schedule_timeout 6, futex_wait_queue_me 4, binder_thread_read 1
session Mir socket: 4 before the launch, 5 while it ran, 5 after it was stopped
```

那个判决**本身是对的**——"这个 app 没画"在那一刻是真的。让这一轮值得写下来的，是它
**关于哪个进程**成立：`alive pid=3710153` 是**上一次**手动探测留下的进程，而证据表里
`Added camera "0"` / `"1"` 那两行，是**这一次**启动的那个新进程打的。也就是说：

* 仪器的**判决**是拿残留进程的 CPU 算的；
* 仪器的**证据**是拿新进程的 stdout 抄的；
* 两件事写在同一个页面上，中间没有任何东西说明它们是两个主体。

而"`4 → 5 → 4`"那三个 Mir 连接数**是这次运行自己的**（它在启动前后各读了一次），所以它们
说的是新进程**确实连上了**会话的 Mir socket——这也正是为什么这条读数值得留下：它
**不可能**由一个二十二分钟前的残留造成（残留那次启停早就结束了）。

**为什么会取到残留**：第 3 步走 `/proc/*/cmdline` 取**第一个**匹配
`$APP_BIN` 的进程。这不是一个"偶尔"——上一趟的 app 没死，于是**下一趟量的就是它**，
而且因为两趟用的是同一个二进制、同一个启动器，一切读数都**看上去正常**。

---

## 3. 为什么"停掉"从来没有停掉过

三件事各自都没问题，叠起来就是一个从不生效的停止：

| 环节 | 它做什么 | 为什么不够 |
|---|---|---|
| `timeout` 包着启动 | 时间到就发信号 | `timeout` 默认发的就是 **SIGTERM**，仅此一个 |
| 第 6 步的停止 | 一个裸 `kill` | 也是 **SIGTERM**。`kill` 是 shell **builtin**，所以 PATH 里的 stub 拦不住它（harness 为此专门按**路径**调用 stub） |
| 第 6 步那个 `kill` 的**操作数** | `kill ${p%/cmdline}` | 那是一个 **`/proc` 路径**。设备的 `/bin/sh` 是 **dash**，它的 kill builtin 只收**进程号**：`arguments must be process or job IDs`，rc=1，**什么信号都没发**（§5a） |
| （这一版当时写的第三行） | "app 自己：**忽略 SIGTERM**" | **已撤回**——它来自一次手工的数字 `kill`，而这台仪器自己的"停止"从来没到过 app，"没生效"和"杀不死"在过去是**两件重叠的事**。修完操作数之后唯一一次量到的结果是 `stopped by SIGTERM` |

于是"停掉 app"这个动作，在**没有任何一处报错**的情况下，一次都没成功过。而它留下的东西，
下一趟会**当成自己的测量对象**捡起来。

这不是"脚本写得粗心"，这是**一个读数的前提没有被读**：仪器需要"没有相机 app 在跑"这件事
成立才能回答它自己的问题，而它**假设**了这件事。这一轮把这句话写下来也不过是重复
[`178`](178-the-premise-of-a-measurement-is-a-reading.md) 那一轮的结论——那一轮是在**另一台**仪器
（热量链的 A/B）上同一个形状：**前提是要读的，不是从调用点推的**。

---

## 4. 修法：前提是一次读数，停止要升级

第 0.6 步在**开屏和启动之前**跑（所以拒绝的路径上什么都不碰）：

```
== 0.6  premise: no camera app may already be running
   ! a camera app is ALREADY RUNNING: pid 3710153 (started 22 minutes ago, from an earlier run)
     its readings would be measured as this run's, so this run refuses and touches nothing.
     re-run with --clean-first to stop it (SIGTERM, then SIGKILL), verify, and then measure.
```

* 有残留、没给 `--clean-first` → **退出 1**，并且在拒绝之前**没有**发过 `busctl`、**没有**发过 `kill`
  （harness 对这两件事都有断言，因为它们正是"拒绝"和"半途"的分界）。
* 给了 `--clean-first` → 走同一个升级停止，结果**印出是哪一种信号起了作用**：

  | 停止函数的输出 | 意思 |
  |---|---|
  | `nothing to stop` | 本来就没有残留 |
  | `stopped by SIGTERM` | 正常情况 |
  | `stopped by SIGKILL (SIGTERM did not end it)` | 第一个信号不够（**注意**：这句说的是"没结束"，不是"被忽略"——[`104`](104-a-unit-error-can-make-a-gate-unfalsifiable.md) 那一类错误就是把一个读数说成一句更强的话） |
  | `STILL RUNNING after SIGKILL: <pids>` | 它也跑得掉 SIGKILL：**终止整趟运行**，不量它 |

第 6 步（运行结束时结束自己的 app）用的是**同一个函数**，所以"运行前"和"运行后"用的是同一条
规则——这一课这棵树已经学过：**两个调用点各带一份自己的拷贝，等于每一个缺陷都存在两次**
（docs 165 / 179）。

停完之后还有一次复核，而且判词里出现的是**复核过的那个答案**，不是"我发过信号"这个动作。

---

## 5. 离线证明：harness 108 → 137

新增的第 11 节（`the premise … and the stop that keeps one from being measured twice`）用**同一个
传输 stub**（stub 目录**就是**设备）跑出四种情形：

* **残留 → 拒绝**：退出 1，输出里有那句 `ALREADY RUNNING`，**没有** `busctl`，**没有** `kill`。
* **`--clean-first`**：SIGTERM 先出现，2 秒后 `kill -9` 出现，判词是
  `stopped by SIGKILL (SIGTERM did not end it)`——**并且两条断言分别匹配两种信号**，因为
  "它升了级"这句话只有在该升的时候才该成立。**两条路都有 fixture**：`FAKE_SIGTERM_WORKS=1`
  让第一个信号就结束（也就是**设备上那一次真的走的那条**），断言则要求
  `app stopped: stopped by SIGTERM` **并且没有一条 `^kill -9` 调用**——否则"升级"就只有一条被测的
  分支加一条编出来的分支。
* **跑到最后**：健康的一趟结束时，自己的 app 也用同样的方式被结束。
* **`--help`**：这个开关在帮助里。

stub 里的 `kill` 默认按"第一个信号不够"来写（`-9` 才会删掉 `/proc/<pid>/cmdline`），否则"升级"
这件事在 fixture 里根本量不出来——**但这是一个 fixture 选择，不是一句关于设备的话**：
`FAKE_SIGTERM_WORKS=1` 就是设备的形状（见上一条）。

**写这一节时被我自己的 harness 抓到三条过宽的断言**（§1 最后两行），这正是 harness 存在的理由：
一条`notwant` 太宽，就会**匹配到文件里那段解释这个缺陷的散文**，于是它在**这个缺陷被写回来**的时候
也照样绿。

---

## 5a. 上设备之后量到的是**另一个东西**：这个停止从来没有送出过信号

改完前提和升级停止之后，判据命令第一次上设备：

```
bash scripts/host/zl1-camera-app-test.sh --clean-first --keep-display --run-seconds 90
```

（`--keep-display`：显示器**留在亮着**，这是给**人**看一眼手机用的那一条路。）

判决本身是：

```
compositor with no client:   3.8/s
compositor with the app:     3.9/s  (47 3.9 1 0.1)
the app's own burn:          0.1/s  (pid 3957277, over the SAME window as B)
the stop at the end:         STILL RUNNING after SIGKILL: /proc/3957277
-> THE APP NEVER PAINTED: ...
```

而这一行里最要紧的是**倒数第三行**：`STILL RUNNING after SIGKILL`。读起来是
**"这个 app 连 SIGKILL 都杀不掉"**——那是**关于这个 app 的一句很强的话**，而它是**假的**。

同一个 pid，用**数字**发一次 SIGKILL，**当秒就没了**：

```
$ kill -9 3957277        # 数字
gone
```

### 真正的原因：dash 的 kill 只收进程号

| 读到的 | 值 |
|---|---|
| 设备的 `/bin/sh` 是 | `/usr/bin/dash` |
| 停止送出去的是 | `kill /proc/3957277` —— 一个**路径** |
| dash 的回答 | `kill: /proc/3957277: arguments must be process or job IDs`，**rc=1，什么信号都没发** |
| 为什么没人看见这句话 | 那一行写着 `2>/dev/null` |

追下去，`stop_app` 里**两个** `kill`（SIGTERM 和 SIGKILL）**都是这个写法**：

```sh
for p in /proc/[0-9]*/cmdline; do
  case "..." in "$APP_BIN "*) kill ${p%/cmdline} 2>/dev/null ;; esac
done
```

`${p%/cmdline}` 把 `/proc/3957277/cmdline` 变成 `/proc/3957277`——**路径**。
所以这个仓库里"停止相机 app"这件事，**从来没有发出过一个信号**，
在**任何一趟**运行里，包括这一轮之前的所有版本。

### 修完之后的第二次设备运行，把这一篇自己的一句话撤掉了

操作数改完（信号只发数字）之后，同一趟命令再上设备一次。这一次停止那一行印的是：

```
   app stopped: stopped by SIGTERM
```

**这是这台设备上第一次有一趟运行真的能回答"它怕不怕 SIGTERM"** —— 之前的每一趟都没送出过信号
（§上面那个操作数缺陷），所以那一行在过去只是把**没发生的事**印成了一个结果。

于是这一篇上一版里那句"**UT 相机 app 忽略 SIGTERM**"（以及 §1 / §3 两张表里跟着它的格子）
**撤回**，理由不是"换了个说法"，而是它**从来没被这台仪器量到过**：

| 那句话的来源 | 它现在是什么 |
|---|---|
| 一次**手工**的 `kill <数字>` 之后，进程仍有 11 个线程、状态 S | 我无法再复核它；它和"停止从没送出过信号"在过去是**两件重叠的事**，而仪器把它们印成了同一句 |
| 仪器**自己**那句"停止" | 从来没到过 app——操作数是 `/proc` 路径，dash 拒收，**一个信号都没发** |
| 修完之后唯一一次真的发出信号的运行 | `stopped by SIGTERM`：**第一个信号就够了**，而且远在 2 秒之内 |

所以现在的写法是：**停止升级并且报出是哪一个信号起了作用**，这是**读数**；"这个 app 忽略
SIGTERM"不是。fixture 现在**两边都钉住**（默认那句是"第一个信号不够"，`FAKE_SIGTERM_WORKS=1`
是设备那一句），所以设备将来若真的变得不理会 SIGTERM，这棵树有一侧会替它说出来。

（顺带一处**本来就对**的：前提那条拒绝消息里给的是 `kill -9 ${PRE_APP#/proc/}`——**数字**。
所以"照着它说的手敲"从来能work，而**脚本自己那条路**从来不work。）

### 修法：信号只发给**数字**

```sh
pids() { for p in /proc/[0-9]*/cmdline; do
      case "$(tr '\0' ' ' < "$p" 2>/dev/null)" in "$APP_BIN "*) q=${p%/cmdline}; echo "${q#/proc/}" ;; esac
    done; }
...
for q in $(pids); do kill $q 2>/dev/null; done          # 裸 kill，操作数是数字
for q in $(pids); do kill -9 $q 2>/dev/null; done       # 升级，操作数还是数字
```

### 离线那一半为什么没抓到它：**fixture 站在了错的一边**

这是这一轮最该记住的一句。那条断言**要求**的正是坏形状：

```
want '^kill /[^ ]*proc/[0-9]+$' ...     # ← 断言要求操作数是 /proc 路径
```

而 stub 是这么写的：

```sh
case "$1" in
-9) rm -f "$FR/proc/$FAKE_APP_PID/cmdline" ... ;;
esac
```

它**收什么都行**。于是：**脚本送一个路径 → 断言要求一个路径 → fixture 收下一个路径**，
三件事一起排在设备的**反面**。在笔记本上它永远是绿的，在手机上它永远是坏的。
（这也解释了为什么改之前"把 app 停掉"这件事**从来没有被验证过**：它的失败在 fixture 里
不可能发生。）

### 现在的 fixture：**dash 的形状**

stub 现在**先查操作数**，非数字就 `exit 1`、**一个信号都不发**——

```sh
for a in "$@"; do
  case "$a" in
  -9|-15|-TERM|-KILL|-[A-Za-z]*) continue ;;
  ''|*[!0-9]*) exit 1 ;;          # ← dash 的规则
  esac
done
```

而断言改成 `^kill [0-9]+$`。**这个判据本身也从两边证过**（不是"看起来对"）：把一个
`kill /proc/6100` 的信号日志和 `kill 6100` 的一份**都**喂给同一条正则，**路径那份必须不匹配、
数字那份必须匹配**——一个谓词只有在**两边各有 fixture 走过**之后才算数。

（这一段没有写成 sed 变异，原因是**我试了**：这个文件里操作数是双引号 ssh 命令里的 `\$q`，
连同 `{`/`}`，sed 与 gawk 在这台笔记本上对它的处理各不相同，写出来的变异**两次都没落地**。
一个"悄悄没落地"的变异，正是上面这些段落一直在讲的那个缺陷，所以改成**字符串 fixture 的两边证明**。）

### 顺带量到的第二件事：app 卡在**建屏**这一步，不是相机

这一趟的 app 自己的 stderr：

```
Creating a QMirClientScreen now
Creating a QMirClientScreen now
tlsfix2 thread ...
Import path added "…/lib/aarch64-linux-gnu"
Camera app directory "…"
```

然后就没有了。证据表里 `Added camera` 的计数是 **0 err / 0 out**——也就是这一趟
**根本没走到"认到两个相机"**，而 docs 80 那几趟是走到了的。主线程停在 `binder_thread_read`，
所以**卡点在 `QMirClientScreen` 的构造里**（Qt 的 ubuntumirclient 平台插件建屏，
底下走 hybris 的 EGL → hwcomposer/gralloc → binder），**比相机管线早**。
这把"卡在哪"往前挪了一整段：之前只知道"卡在一个不返回的 EGL/hwcomposer 调用"，
现在知道**是建屏那一个**，而且**相机的枚举根本没开始**。

（`cfi-shadow-init` 那两行仍在：`resolved android_dlopen via dlopen("libhybris-common.so.1")`，
即 docs 80 那个 EGL 修复是活的。）

---

## 5b. 顺手抓到的第二件事：family 的红，两次不在同一个地方

同一个**冻结的**树上跑了两遍 family，两遍各有一个红，**而且不是同一个**：

| 第几遍 | 红的那个 | 是不是真的 |
|---|---|---|
| 第一遍 | `zl1-cli-usage-selftest.sh` | **是真的**——README 里写着 108，而 harness 已经涨到 126（引用漂移，同一个形状这一轮已经修过一次；这一节结束时是 137） |
| 第二遍 | `zl1-governor-temp-ab-selftest.sh` | **不是真的**——**同一个 harness 单独跑 321/321 全绿** |

第二遍那个红，在**有负载的笔记本上**复现了：开六个 `yes > /dev/null`，跑三次，第三次红。
红的那一条断言是：

```
FAIL  and prints HOW LONG it took, and that the test was EVERY ZONE rather than the hottest one
```

它要求仪器印出 `…reading after 1s`——**把宿主自己花掉的秒数写死在断言里**。

追下去，同一个文件里有**三处**同一个形状：

| 位置 | 钉住的字面量 | 那个数字是谁选的 |
|---|---|---|
| `wait-returns` 场景 | `after 1s` | 宿主——wait 由**时钟**定界（这正是 docs 174 修好的那件事） |
| `plateau` 场景 | `after 3s` | 宿主——`PRE_WAITED = PRE_NOW_T - PRE_T0` |
| `plateau` 场景 | `in the last 1s` | 宿主——`PRE_GAP=$((PRE_NOW_T - PRE_LAST_T))`，是**量出来的间隔**，从来不是 `--poll` |

**为什么它值得停下来修，而不是"重跑一遍绿了就算了"**：这棵树只有**一道**放行门（family），
而"一个红取决于笔记本当时的负载"意味着这道门**会随机变红**，于是它变红的时候没人能行动——
而这正是这棵树反复记下的那个形状（`zl1-a-count-inside-a-clock-bound-is-a-host-number`）。
而且这台设备上一次真的量到过它：docs 174 修的就是**同一个错误的另一半**——`--settle-back 240`
花了 798 秒墙钟，因为"上界"数的是**睡眠秒**。所以这一次不是新缺陷，是**同一个缺陷在断言这一侧**。

改法就是那条记忆里写的那句话的**两半都要**：断言改成**要一个数字**（`[0-9]+`），
并且**把它印出来**——只放宽不印，等于把可核对性也一起放宽了：

```
PASS  and the wait cost 1s of wall clock under a --settle-back 4 (a host number: this run's own seconds,
      not a value the harness may pin)
PASS  and it waited 3s of wall clock against a --settle-back 5 --poll 1, i.e. the wait ran for at least
      the 3 s this run's two moves cost (a host number, printed rather than pinned)
```

只有一处保留了数值比较，因为那不是宿主选的：**wait 必须至少走到它被给的那个界**
（`>= 3`）。上面第二行那段 `3s` 就是量出来的那个位置。

改完：harness 321 → **324**，开六个负载进程连跑三次 **324/324 全绿**；
健康检查里那两条引用（321）同步改到 324，并且把这三条断言为什么变成数字写在了引用旁边。

**这一节要留下的规则**：一个断言里出现**秒数**（或任何由本机时钟/负载决定的数量）时，
它写下来的就不该是一个**值**，而是一个**形态**——并且**它看到的是哪个数必须被印出来**，
否则放宽和放水在外观上是同一件事。

---

## 6. 这一轮**没有**证明什么

* **相机的真问题没动**：app 卡在 `binder_thread_read`——一个发出去没返回的调用，现在知道它在
  **建屏**（`QMirClientScreen` 的构造）那一段，**比相机枚举早**（§5a）；
  这一轮只是保证了**下一趟量到的是它**，而不是上一个它。
* **app 在屏上被人看见过**这件事，仍然一次都没有。
* **"app 怕不怕 SIGTERM"现在只有一次读数**（`stopped by SIGTERM`，一台设备、一个 boot、一个进程状态）。
  它足以**撤回**旧那句话，不足以当成一条规律——所以升级停止留着，并且两侧都有 fixture。
* **"5/s 就是画了"仍然是设计选择，不是量出来的带**（§7 第 3 条）。
* 这一轮**没有**写任何分区、没有重启、没有 `modprobe`、没有碰 cnss/qbt1000、没有开任何设备节点。

---

## 7. 下一步（按顺序）

1. **把"没画"这条判词推到它该去的地方**：判词现在是拿**建屏那一步**的不返回调用算的
   （§5a：`Creating a QMirClientScreen` ×2、`Added camera` 0/0、主线程在 `binder_thread_read`）。
   下一个读数是**那个事务本身**：它发给谁、是哪一个调用（`/proc/<pid>/task/*/stack` 加
   `binder_thread_read` 的那一侧），以及 `/system/lib64/libui_compat_layer.so` 在不在 dlopen 路径上
   （`/system` 是 `/dev/loop1` 上的 ro ext4，这台设备上**任何地方都没有这个文件**）。
2. **把"5/s 就是画了"从设计选择变成量出来的带**：在**同一个窗口**里跑一个**已知会画**的客户端
   （`/usr/bin/test_camera`，doc 77 —— 它被量到过 20–26 ticks/s），看它的 app 速率是多少。
   这是这一篇列在"不证明什么"里的那一条（§6）。
3. **`--keep-display --run-seconds 90` 那条命令，给人看的那一眼还没发生**：两次设备运行里，
   第一次用了 `--keep-display`，但它那一刻量到的还是操作数缺陷（§5a）；第二次没用这个开关，
   所以**结束之后显示器是关的**（已验证：`lcd-backlight/brightness` = `0`，没有残留进程）。
   要用户亲眼确认"相机 app 在屏上是什么样"，就再跑一次带 `--keep-display` 的那条。
