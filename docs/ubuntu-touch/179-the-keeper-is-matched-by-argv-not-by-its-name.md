# 179 — 匹配 keeper 的是它的 **argv**，不是它的名字

**日期**: 2026-09-26
**状态**: 九个程序改完（同一个写法在**两个名字**下），**离线**证明；设备上只做了**只读**的复核。
这一篇不是从计划里来的，它是从**读手机时读到的一句假话**里来的：健康检查在
**一台没有 keeper 的 boot 上**印了 `debug keeper: RUNNING`。追下去发现同一个写法在这棵树里
有**六处**（keeper 的名字），其中**两处拿着它去发信号**；把这条**不认名字**的扫描做出来之后，
**又找出三处**——它们问的是**另一个名字**（netwatch），而且就在**同样三个文件**里。

**接续**: [`178`](178-the-premise-of-a-measurement-is-a-reading.md)（A/B 的前提是一次读数）、
[`165`](165-the-end-state-reader-had-never-been-run.md)（读回那个程序是**跑**的，不是被喂的）、
[`128`](128-the-chain-changed-the-heat-and-never-measured-it.md)（每一条 harness 的数字都得有人读）、
[`94`](94-retiring-the-v63-debug-keeper-is-a-kill-not-a-unit-edit.md)（keeper 是一个 shebang 脚本，
它被 exec 成 `<interpreter> <script>`）、
[`72`](72-the-heat-was-the-governor-and-a-debug-keeper.md)（keeper 是第二个热源，一个整核）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 这一轮发现的缺陷是什么？ | "keeper 在不在"（以及"netwatch 在不在"）这个问题的答案，是**在一张进程表里找它的名字**得出的。 |
| 为什么这个做法**在这几个程序里**一定是错的？ | 因为这些程序**每一个都把自己的文本里的那条路径带着**，其中**两个是被整块交给 `sh -c` 的**——也就是说**它们本身就是一个 argv 元素，里面写着要搜的那个字符串**。于是**搜索者会匹配到自己**，而"第一个匹配到的 pid 就返回"意味着**先撞上谁就报谁**。 |
| 它造成的**最坏**后果是什么？ | 不是印错一个数字：`device/zl1-quiet-debug-keeper.sh --stop` **SIGSTOP 的正是 `--status` 报出来的那个 pid**，`device/zl1-address-owner-proof.sh` 第 2 节的循环**决定谁被 SIGSTOP**。一个幻觉在这里是**一个对着提问者自己发的信号**。 |
| 它已经造成过什么？ | 手机 2026-09-26：健康检查印出 `keeper pid 3545508`，而同一次读数里的 `my pid: 3545508`——**读者自己**，状态 S，在一个 **argv 规则下匹配数为零**的 boot 上（同分钟的链的读回是 `keeper: gone`）。于是**每一个没有 keeper 的 boot** 都印着 `debug keeper: RUNNING ... it costs ~a core`，而那句话是**关于没有的东西**的。 |
| 另外两处错在哪个方向？ | `install-cpufreq-governor.sh` 那一半里，`pgrep -f zl1-debug-net.sh` 匹配到的是**读它的那个 shell**（comm=`bash`）；另一半 `ps -C zl1-debug-net.sh` 匹配的是**命令名**，而 keeper 是 shebang 脚本、comm 是 `sh`——**那一半根本找不到一个真正在跑的 keeper**。两半合起来是一个**稳定地报错**的读数。 |
| 规则是什么？ | **一个完整的 argv 元素等于那条路径**，或者 **argv[0] 是一个 shell 而 argv[1] 是那条路径**（docs 94：shebang 脚本被 exec 成 `<interpreter> <script>`），并且**跳过读者自己的 pid**。**提一句名字不等于它是 keeper。** |
| 这条规则是新的吗？ | **不是**。`install-retire-debug-keeper.sh` 的 `is_keeper_cmdline()`（那是**杀**它用的规则）和 `zl1-one-boot-runbook.sh` 的 `read_keeper()` 一直在用它（docs 165 之后链的读回也用它）。这一轮是让**读**和**做**用同一条规则。 |
| 为什么是**九**处而不是六处？ | 因为**第二条**扫描把**名字**去掉了：它不找 `zl1-debug-net.sh`，它找**任何一个 `*.sh` 名字**被 star-star 或 `pgrep -f` 匹配的写法。于是它立刻指出**三处**——`device/zl1-boot-address-check.sh` 第 2 节、`device/zl1-address-owner-proof.sh` 的**预备门**、以及 `device/zl1-quiet-debug-keeper.sh` 的 `--status` 里那句 `pgrep -f zl1-netwatch.sh`——问的都是 **netwatch**，用的都是同一个写法，**而且在同样那几个文件里**。一个只知道 keeper 名字的 harness 会把这些叫"干净"。 |
| 离线怎么被证明的？ | 新 harness `scripts/host/zl1-keeper-detect-selftest.sh`，**105 条全绿**：它**提取**每个出厂程序、把它那句 `/proc` 重写成假根、**真的跑它**，六种 fixture 形状，一棵**不认名字**的 sweep，**五次变异**（每一次都把 substring 放回去，都必须让上面的断言变红）。**写它的过程中被我自己的 fixture 抓出三个缺陷**（§7）。 |
| 设备现在怎么样？ | **在跑**（`33e80afe`，`18d1:d001`，RNDIS），`boot_id 2fbf9f8e-deea-4955-ad0c-6bddf0fb14f5`。改完之后**只做了只读复核**：健康检查印 `debug keeper: not running`，`install-cpufreq-governor.sh --status` 印 `NOT running`，安静 keeper `--status` 印 `keeper: not running`——三者一致，且都和一个**真的没有 keeper** 的 boot 相符。**没有写任何分区。** |

---

## 2. 这个缺陷是怎么被看见的：我读到了一句假话

这一轮的起点不是一个计划，是一次**复核**。我在手机上跑健康检查（只读）时，同一个页面上有两件事
**不可能同时成立**：

```text
   debug keeper: RUNNING (state S) -- it costs ~a core and makes systemd reload every ~6s
```

而**同一次会话**里，链的状态读数（`--status`）说的是 `already-fixed (keeper gone, ...)`，
链的 device-side 读回说的是 `keeper: gone`。三者里**只有一个能是真的**，而且我知道哪两个是真的：
docs 172 之后这两个修复都是**开机 unit**，这台手机**每一次开机都不装 keeper**。

于是问题变成"那个 `RUNNING` 是从哪儿来的"，而不是"谁对"。为了回答它，我在手机上把那个循环**拆开**
跑了一次，并且**故意把分隔符切开**，让探针**不可能匹配到自己的那段文本**：

```text
$ ps -p 3545508
  PID ...  STAT ...
3545508 ...  S ...
$ echo "my pid: $$"
my pid: 3545508
```

**读者自己**。它不是别人写的循环跑偏了——它就是那个循环，**匹配到了正在跑它的那个进程**。

原因值得写下来，因为它不是这几个程序的坏运气，而是它们的**形状**：

1. 这些程序都是**整块**交给 `sh -c` 的（或者被 ssh 传过去当一整条命令），
   也就是说**整段程序文本是 argv 里的一个字符串**；
2. 那段文本里写着那条路径（它要匹配的东西、它要打印的提示、它调用的脚本名）；
3. 于是**它自己的 cmdline 里就有它正在搜的那个字符串**；
4. 而这些循环的形状是"**第一个匹配到的就返回**"——所以**往往就是它自己**。

同一轮里另外两处也各自错在不同的方向，这说明了"名字匹配"这个做法**连在同一个方向上错都做不到**：

* `install-cpufreq-governor.sh` 的 `--status`：`pgrep -f zl1-debug-net.sh` 匹配到**一个** pid，
  `comm` 是 `bash`——**读它的那个 shell**。它的另一半 `ps -C zl1-debug-net.sh` 匹配的是**命令名**，
  而 keeper 是 shebang 脚本、exec 成 `<interpreter> <script>`（docs 94），comm 是 `sh`：
  **那一半无论有没有 keeper 都找不到它**。
* `zl1-quiet-debug-keeper.sh` 的 `--status`，从一个 argv 里提到过这个名字的 wrapper 里调用，
  印出 `keeper pid 3550125: state=S cpu over 20s=0 ticks RUNNING`——**wrapper shell**。
  `--status` 报一个幻觉是**一个坏数字**；`--stop` 照办是**一个对着调用者发的 SIGSTOP**。

---

## 3. 规则：规则已经在树里了，只是读的那一半没用它

`install-retire-debug-keeper.sh` 的 `is_keeper_cmdline()` 是**杀** keeper 时用的判定，
它一直是按 **argv** 比的：**一个完整的 argv 元素等于那条路径**，或者
**argv[0] 是一个 shell（`sh`/`dash`/`bash`/`busybox`，带或不带路径）而 argv[1] 是那条路径**，
**并且跳过自己**。`zl1-one-boot-runbook.sh` 的 `read_keeper()` 用的是同一条规则，
docs 165 之后链的 device-side 读回也是。**这一轮没有发明任何新规则**。

它要修的是同一件事的**读**那一半。后果最难看的地方在于，**做**和**读**用的是两套判定，
所以它们**可以互相矛盾**：`--status` 列出一个进程，而紧接着的 applier **拒绝动它**——
操作者看到的是自相矛盾的两句话，而且**两句话都是这条链印出来的**。

九处，以及每一处错在哪个方向：

| 文件 | 那一处是什么 | 错法 |
|---|---|---|
| `host/zl1-health-check.sh` | 一次性设备读数的 `keeper=` 字段 | 整条 cmdline 上找名字 → **匹配到读者自己** |
| `install-cpufreq-governor.sh` | `--status` 的"还在烧 CPU 的东西"一节 | `pgrep -f` **匹配读者**；`ps -C` **永远找不到**（comm 是 `sh`） |
| `device/zl1-quiet-debug-keeper.sh` | `keeper_pids()` | 找名字；而 `--stop` **SIGSTOP 的正是它** |
| `install-retire-debug-keeper.sh` | `--status` 的 heredoc | 找名字 → **列出一个 applier 拒绝动的进程** |
| `device/zl1-address-owner-proof.sh` | 第 2 节（**决定谁被 SIGSTOP**） | 找名字 |
| `device/zl1-boot-address-check.sh` | 第 4 节（它的结果**进判决**） | 找名字 |
| **`device/zl1-boot-address-check.sh`** | **第 2 节**：这一页说 netwatch 是 "running, pid N" 还是 "NOT RUNNING，先装它" | **同一个写法，另一个名字** |
| **`device/zl1-address-owner-proof.sh`** | **预备门**：没有它就不许开测 | **同一个写法，另一个名字**（一个幻觉会让探针开始一次它注定失败的测量） |
| **`device/zl1-quiet-debug-keeper.sh`** | `--status` 里那句 netwatch 列表 | **`pgrep -f zl1-netwatch.sh`** |

**最后三行不是我想起来的，是扫描找出来的**——而且那三行是**在我把前六处修完之后**才出现的。
这就是为什么新的 harness 里那条扫描**不认名字**：一个只覆盖"我记得的那几处"的 harness，
会正好漏掉**两处会发信号 19 的地方**（keeper 那两处），也会漏掉**三处另一个名字下的同一件事**。
`zl1-quiet-debug-keeper.sh` 里那条规则现在是一个函数 `pids_matching()`，**两个问题走同一条规则**：
这正是"同一个文件的读者必须和它的提问方式一致"的最小形态。

---

## 4. 离线怎么证明它：把出厂的程序**跑起来**，对着假的 `/proc`

`scripts/host/zl1-keeper-detect-selftest.sh`（**105 条**）。它的骨架是 docs 165 的那条纪律：
**不喂答案，跑程序**。

**怎么跑**：每一个受测程序的文本被一条规则**提取**出来（`sed`/`awk` 按结构取，不是按行号），
把其中的 `/proc/` 重写成这个 harness 的假根，然后用真的 `sh` 执行。
每一次提取都**断言非空**、并且**断言里面真的有 argv 规则**——否则一次提取失败会让下面每一条断言
**在空字符串上通过**（这正是 docs 163/165 记下来的那个缺陷）。两段**设备侧的循环**（keeper 的与
netwatch 的）是从四个块里各取一块的，取的依据是块体里出现的**常量名**，所以一个问错问题的读者
会**取不到东西**，而不是**取到别的块**。

**六种 `/proc` 形状**，每一种里都另有 pid 1 和一个**读不出 cmdline 的条目**（内核线程的形状：
每个 reader 都必须**跳过它**，而不是把它当成一个匹配）：

| 形状 | 里面是什么 | 正确答案 |
|---|---|---|
| `none` | 只有 pid 1 和那个读不出来的条目 | 什么都没有 |
| `keeper` | `/bin/sh <keeper 路径>`（v63 钩子的形状，pid 101） | 是 keeper |
| `argv0` | `<keeper 路径>` 就是 argv[0]（unit 的形状，pid 102） | 是 keeper |
| `netwatch` | `/bin/sh <netwatch 路径>`（pid 106，unit 的 ExecStart 是那条路径） | 是 netwatch，**不是** keeper |
| `bystander` | **只是提到**路径的 shell：`ps -ef \| grep zl1-debug-net.sh`（pid 103，**basename**）、`echo /usr/local/sbin/zl1-debug-net.sh`（pid 105，**完整路径**）、以及 **netwatch 的完整路径**（pid 108） | 都不是 |
| `selfshape` | **读者自己的形状**：把带路径的 `sh -c` 文本放进 argv（pid 104） | 不是 keeper |

`mixed` 形状（**一个真的 keeper + 一个真的 netwatch + 四个只是提到它们的 shell**）是 substring 规则
**永远过不了**的那条断言：它在这种形状里找到一个东西，而**找到的是谁要靠运气**。

**sweep，而且它不认名字**：那九个位置是**当下存在**的，**规则**才是要长期守住的东西。所以其余程序
都会被扫描一遍，找 substring 的写法——**`*<任意 .sh 名字>*`**、`pgrep -f <任意 .sh>`，
以及 `*"$大写变量"*` 这类变量形式——**只扫代码行**（注释里的例子不算），
并且**断言扫描真的读到了那六个受测文件**（否则"零个命中"和"什么都没扫"是同一个读数，docs 128 的规矩）。
这条不认名字的规则，就是**第九处被发现的原因**。

**五次变异**，每一次把 substring 规则放回**一个**地方，都必须让上面的断言变红：

| 变异 | 放回到哪儿 | 必须看到什么 |
|---|---|---|
| `health` | 健康检查的 `keeper=` | bystander 与**读者自己的形状**都被报成 keeper（手机上那个假读数被复现） |
| `gov` | `install-cpufreq-governor.sh` | bystander 让它印 `the v63 debug keeper is running`，而且**计数是 2，全部关于不是 keeper 的东西** |
| `retire` | 退休安装器的 `--status` | **指明完整路径**的那个 shell 被列成 keeper |
| `quiet` | 安静 keeper 的规则函数 | `--stop` 会 SIGSTOP 一个**只是提到**路径的 shell，而 `--status` 在**没有 keeper** 的 boot 上不再说 `not running` |
| `sweep` | 六个受测文件之一 | 扫描必须命中它，**并且命中要说出行号**——因为一条只说"有 1 处"的仪器，读的人**不知道该修哪儿** |

**另外两个名字下的扫描也被证明是活的**：扫的判据自己拿着五份 scratch 文件跑一遍——
两个 keeper 的旧写法（star-star、`pgrep -f`）、**两个 netwatch 的旧写法**都必须被命中，
而**两个新写法**（keeper 的、netwatch 的）都**不许**被命中。否则"没有命中"可能只是**判据根本不认识那个名字**。

---

## 5. 引用：那个数字得有人读，而且这一次的检查必须**放在最后**

**105 条**这个数字是**手打**在 `host/zl1-health-check.sh` 里的（docs 128 的规矩：每一个被那一页点名的
harness 都要**自己核对**这个数字，否则它会像 docs 110 记的那样**悄悄过期**）。
`scripts/host/zl1-cli-usage-selftest.sh` 第 4d 节还从反面查这件事：那一页点名的每一个 harness
**都必须带着**这条自我核对的检查，而它的判据是**一行字面量**（`HEALTH="$HERE/zl1-health-check.sh"`）。
这个 harness 第一版把那行写成了 `"$REPO/scripts/host/…"`——**同一条路径、不同的写法**——
于是它在 4d 眼里就是"一个不能核对引用的 harness"。**判据是一行文本时，等价的写法不是等价的。**

这个检查还有一个形状上的坑，这一轮踩到了：树里其他 harness 用的形式是
`total=$((PASS + FAIL + 1))`，**那个 `+1` 就是检查自己**——它不能在跑之前被数进去。
所以**这条检查必须是文件里的最后一条**。这个 harness 里的"树没被动过"那条检查（六个受测文件的哈希）
本来在它后面，于是这个文件曾经声称**一个比它自己最终通过数还大 1** 的数字。
现在两条互换了位置，文件末尾就是引用检查，`+1` 于是**就是**最终那个数（105）。

---

## 6. 这一轮**没有**做的事

* **没有跑任何东西去改设备。** 设备上做的都是只读复核：健康检查、`install-cpufreq-governor.sh --status`、
  安静 keeper `--status`，三者都说"没有 keeper"，且与那个 boot 的链读数一致。**没有写任何分区。**
* **没有把 `is_keeper_cmdline()` 抽成一个共用函数。** 九个位置里有几对是**同一份文本的两个拷贝**
  （device-side 的 heredoc 与 shell 脚本），把这套规则抽出去要动 ssh 的传输方式和两个文件的部署，
  这一轮的风险预算用在了别处。代价是**这条规则的副本现在有九份**，所以 §4 里那条**不认名字的扫描**
  就是它的保险：**第十处**再写一遍这个写法，sweep 会说话——**这一轮它已经说了三次**。
* **没有声称"把幻觉根除了"。** 这条规则依赖 argv 的形状（`<interpreter> <script>`），
  而 argv 是**可以被伪造**的：一个故意把自己伪装成 keeper 的进程仍然会被认出来。
  这不是这一篇要防的东西——这一篇防的是**读者匹配自己**，那是**默认行为**，不是攻击。
* **没有声称那三次只读读数就是设备上的"证明"。** harness 的**正方向**是离线的，因为
  "设备上真的有一个 keeper"这件事只能由**真的启动真的 keeper** 来产生，
  而**负方向**才是手机被问过的那半边：改完之后它在**没有 keeper 的 boot 上**说"没有 keeper"。
  真正在设备上跑一次 `--stop`/`--status` 仍然要在**一次买来的 boot** 上做，那是下一轮的事。

---

## 7. 这一篇的缺陷是从哪儿被抓出来的：我自己写错了三次 fixture

写第六处和第十处以外的部分时，harness 和**别的 harness** 抓住了我自己。三次都属于同一类错误，
而且这一篇记住它们的理由比记住缺陷本身更值：
**一个 fixture 缺陷会让变异测试变成装饰，一个形状错误的 fixture 会让断言在错误的对象上通过。**

* **变异 `retire` "落下来了，但没有红"。** 变异确实改了那一行（`cmp` 说副本和出厂文件不同），
  可是**变异后的程序仍然印 `none running`**。原因是我把 bystander 写成了
  `ps -ef | grep zl1-debug-net.sh`——**它只写了 basename**，而这一处要放回去的那条老判定
  搜的是**完整路径**。于是**变异体拿到的东西它根本不可能匹配**，这条变异就变成了
  **一个从来不失败的检查**。修法是给 fixture 补上**两个写法**（pid 103 写 basename、pid 105 写完整路径），
  因为**这些 reader 搜的本来就不是同一个字符串**。
* **两个设备 harness 的 fixture 用的是**被规则**发明出来的进程形状**。**
  `zl1-boot-address-selftest.sh` 把进程的 cmdline 写成
  `#!/bin/sh\0/usr/bin/sh\0<路径>\0`——**`#!/bin/sh` 不是任何内核会产生的 argv[0]**（那一行是脚本的
  第一行，不是 exec 的参数），它以前能匹配**只因为读者是 substring 匹配**。
  `zl1-address-proof-selftest.sh` 更直接：它把 `/bin/sleep` **复制成一个叫 `zl1-netwatch.sh.3` 的文件**
  再执行——一个叫"相似名字"的进程，而读者的判据是"argv 元素**等于**那条路径"。
  两个 harness 都改成**真的形状**：cmdline 写成 `/bin/sh\0<那条路径>\0`；进程 fixture 直接**按它自己的
  路径**启动一个 shell 脚本（`/bin/sh <路径>`，就是设备上的形状），并且把副本里那条常量**重写成 fixture
  自己的路径**——**重写本身被断言**，因为一个改名会让 sed 变成空操作，而 fixture 与读者就会**因为
  错误的理由**达成一致。这里还测出一个坑：**`exec sleep 300` 会让形状消失**（dash 优化掉最后一次
  exec，并把 argv[0] 换成真正的可执行文件），所以 fixture 用的是循环而不是 exec。
* **那条"不能核对引用"的失败**（§5）：同一条路径、另一种写法，判据是一行字面量。

第一条正是那种"**看起来是绿的**"的缺陷：变异落下来了、副本变了、其余 80 条全绿——
只有把变异体**真的跑一次**并**看它印了什么**，才能发现它**从来没被给过能匹配的东西**。
第二条是同一个道理的另一半：fixture **能匹配**，但匹配的是一个**只存在于这条规则里的世界**。
