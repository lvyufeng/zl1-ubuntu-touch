# 180 — 这台仪器第一次在设备上跑，量到的是**上一次留下的那个进程**

**日期**: 2026-09-26
**状态**: 改完并且**离线**证明（相机 harness 108 → **126** 条，family 43 个 harness 全绿、**6222** 条检查、
513 个 tracked 文件前后逐字节相同）；设备上**只做了只读**复核，判据那一条 `--keep-display` 的跑
**还没跑**。顺带在放行门上抓到并修掉了**第二个**红（§5b）：它不是设备的缺陷，是三条把**宿主自己的秒数**
写死的断言——同一个 harness 单独跑是全绿的，有负载才红。

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
| 为什么它一定会发生？ | 三件事叠在一起：**起 app 的那一步走 `/proc` 取第一个匹配**（[`179`](179-the-keeper-is-matched-by-argv-not-by-its-name.md) 的同一个形状）；**UT 相机 app 忽略 SIGTERM**（我在手动探测里量到过：`kill` 之后 11 个线程、状态 S 一动不动）；而第 6 步的停止**只有一个裸 `kill`**——`timeout` 也只送这一个信号。于是"停掉"从来没有真的停掉过任何东西。 |
| 它跟 [`104`](104-a-unit-error-can-make-a-gate-unfalsifiable.md) 是同一类吗？ | **是同一类，但换了一边**。104 那一轮的错误在**读数的单位**（东西量错了），这一轮的错误在**读数的对象**（量的是别的东西）。两次都是：仪器印了一个**看起来很正常的数**，而那个数**不是关于它声称的那个主体**的。 |
| 修法是什么？ | 把"没有相机 app 在跑"从**假设**变成**读数**——第 0.6 步，在开屏、启动之前问一次；有残留就**退出 1 并且什么都不碰**（不 `busctl`、不 `kill`）。`--clean-first` 是接受残留的那条路：先 SIGTERM、等 2 秒、还在就 **`kill -9`**，再复核，并且**把结果印成"哪一种信号起了作用"**。**跑不掉 SIGKILL 的进程终止整趟运行**，而不是被拿去量。第 6 步用同一个停止函数——运行结束时自己的 app 也走这条路。 |
| 离线怎么被证明的？ | `scripts/host/zl1-camera-app-test-selftest.sh` 从 108 涨到 **126** 条，新增**第 11 节**：残留让运行**退出 1 且什么都没碰**（断言输出里**没有** `busctl … call`、**没有** `kill`）、`--clean-first` 先 SIGTERM 后 SIGKILL（两条断言分别匹配 `^kill /…proc/<pid>$` 和 `^kill -9 /…proc/<pid>$`）、健康的一趟结束时用同样的方式结束自己的 app、以及 `--help` 里有这个开关。 |
| 写它的过程中抓到我自己什么错？ | 三条**过宽**的断言：`notwant "the app's own rate"` 会匹配到"它**不**证明什么"那一条（收紧成 `the app's own rate: `）；`notwant 'the app is being composited'` 会匹配到判词**自己的解释**（收紧成 `the app's window is being composited`）；还有一条引用漂移——健康检查里 108 应该写 126（family 的 `zl1-cli-usage-selftest.sh` 上一轮就是为了同一类漂移变红的）。 |
| 设备现在怎么样？ | **在跑**：`33e80afe` → `18d1:d001`（RNDIS），`boot_id 2fbf9f8e-deea-4955-ad0c-6bddf0fb14f5`，display `(ii) 0 0`，没有相机 app 在跑，会话的 Mir socket 回到 **4** 条 established 连接。**没有写任何分区，没有重启，没有 panic。** |

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
| app 自己 | **忽略 SIGTERM** | 手动量到过：`kill` 之后它还是 11 个线程、状态 S，纹丝不动 |

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
  | `stopped by SIGKILL (it ignored SIGTERM)` | **这一次是真的**——它忽略 SIGTERM，这是这台设备上最常见的那个结果 |
  | `STILL RUNNING after SIGKILL: <pids>` | 它也跑得掉 SIGKILL：**终止整趟运行**，不量它 |

第 6 步（运行结束时结束自己的 app）用的是**同一个函数**，所以"运行前"和"运行后"用的是同一条
规则——这一课这棵树已经学过：**两个调用点各带一份自己的拷贝，等于每一个缺陷都存在两次**
（docs 165 / 179）。

停完之后还有一次复核，而且判词里出现的是**复核过的那个答案**，不是"我发过信号"这个动作。

---

## 5. 离线证明：harness 108 → 126

新增的第 11 节（`the premise … and the stop that keeps one from being measured twice`）用**同一个
传输 stub**（stub 目录**就是**设备）跑出四种情形：

* **残留 → 拒绝**：退出 1，输出里有那句 `ALREADY RUNNING`，**没有** `busctl`，**没有** `kill`。
* **`--clean-first`**：SIGTERM 先出现，2 秒后 `kill -9` 出现，判词是
  `stopped by SIGKILL (it ignored SIGTERM)`——**并且两条断言分别匹配两种信号**，因为
  "它升了级"这句话只有在该升的时候才该成立。
* **跑到最后**：健康的一趟结束时，自己的 app 也用同样的方式被结束。
* **`--help`**：这个开关在帮助里。

stub 里的 `kill` 按设备上的**不对称**来写：`-9` 才会删掉 `/proc/<pid>/cmdline`（也就是
SIGTERM 被忽略、SIGKILL 不被忽略），否则"升级"这件事在 fixture 里根本量不出来。

**写这一节时被我自己的 harness 抓到三条过宽的断言**（§1 最后两行），这正是 harness 存在的理由：
一条`notwant` 太宽，就会**匹配到文件里那段解释这个缺陷的散文**，于是它在**这个缺陷被写回来**的时候
也照样绿。

---

## 5b. 顺手抓到的第二件事：family 的红，两次不在同一个地方

同一个**冻结的**树上跑了两遍 family，两遍各有一个红，**而且不是同一个**：

| 第几遍 | 红的那个 | 是不是真的 |
|---|---|---|
| 第一遍 | `zl1-cli-usage-selftest.sh` | **是真的**——README 里写着 108，而 harness 已经是 126（引用漂移，同一个形状这一轮已经修过一次） |
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


* **判据那条命令还没在设备上跑过。** 这一轮改的是仪器；仪器改完之后的**第一次设备运行是下一件事**。
* **相机的真问题没动**：app 卡在 `binder_thread_read`——一个发出去没返回的 EGL/hwcomposer 调用；
  这一轮只是保证了**下一趟量到的是它**，而不是上一个它。
* **app 在屏上被人看见过**这件事，仍然一次都没有。
* 这一轮**没有**写任何分区、没有重启、没有 `modprobe`、没有碰 cnss/qbt1000、没有开任何设备节点。

---

## 7. 下一步（按顺序）

1. `bash scripts/host/zl1-camera-app-test.sh --clean-first --keep-display --run-seconds 90`
   ——**让人看一眼手机**。这正是当初关掉显示阶段的那个协议（"用户亲眼亲手确认"）。
2. 判词若是"没画"，下一个读数是那个**不返回的 binder 事务**：它发给谁、是哪一个调用；
   以及 `/system/lib64/libui_compat_layer.so` 在不在 dlopen 路径上（`/system` 是 `/dev/loop1` 上的
   ro ext4，这台设备上**任何地方都没有这个文件**）。
3. 把"5/s 就是画了"从**设计选择**变成**量出来的带**：在同一个窗口里跑一个**已知会画**的客户端
   （`/usr/bin/test_camera`，doc 77），看它的 app 速率是多少。
