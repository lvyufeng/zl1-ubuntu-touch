# 155 — 那份报告只落在一个地方，而仪器把它读成了"什么都没说"

**日期**: 2026-09-24
**状态**: 本轮**没有碰设备**。docs 154 把"开机时挂上调制解调器固件分区"这一手做完了，但**有没有做成**，
离线证不了：initramfs 的文件在 `switch_root` 之后就没了。这一页把**唯一**那个证人交给设备侧的仪器——
initramfs 自己的 `initrd:` 报告——并且在这一轮就**修掉了两个把"报告在、而仪器说没有"变成假阴性的缺陷**。

**接续**: [`154`](154-no-in-kernel-client-loads-the-modem-so-the-mount-has-to-happen-itself.md)（那一次挂载本身）、
[`120`](120-the-subsystem-nobody-has-looked-at.md) /
[`151`](151-the-question-that-was-filed-as-unreadable-offline.md)（halium 的挂载循环**静默**失败）、
[`117`](117-the-command-that-could-not-run-is-not-a-zero.md)（**跑不起来的命令不是一个 0**——"取不到"与"没找到"不能长得一样）、
[`110`](110-the-lshal-columns-have-a-definition.md)（§6 顺手关掉的引用漂移：**手打的检查数**）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 这一轮问的是什么？ | docs 154 修好了挂载。**但"它到底跑了没有"，怎么知道？** |
| 离线知道不了，为什么？ | **initramfs 的文件在 `switch_root` 之后就不存在了。**在 rootfs 镜像上实测（`debugfs`）：`/scripts` **不存在**、`/zl1-android-fstab` **不存在**。所以"那一次挂载发生了没有"在离线上只有**函数会不会用它**这一个答案，不是**它用成了没有** |
| 那唯一证人在哪？ | **内核环里。**halium 的 `tell_kmsg` 就是 `echo "initrd: $1" > /dev/kmsg`，于是 `initrd:` 那几个字只有环里有 |
| 环够吗？ | **不够，而且这台设备的 journal 指望不上**：drain 的头（2026-09-21）记着 `journalctl -k` **只回一行**——journald 根本没在抓 `/dev/kmsg`（`scripts/install-kmsg-drain.sh:7`） |
| 所以仪器怎么读？ | **三个来源，固定顺序**：① kmsg drain 的**最早**快照 → ② 活的 `dmesg` → ③ `journalctl -b -k`。顺序是承重的：环会在**大约一分钟**内绕回来（同一处记着 ~3470 行 / 249 KiB，说话时 3 秒 ~3480 行），所以"开机时取的那一份"比"现在读到的环"更接近真相 |
| 三个来源里凭什么信一个？ | **它必须带启动相位**（`Linux version` 或 `initrd:`）。"文件非空"曾经是旧守卫的**全部**条件，而它被一行任意内容满足——那正是 docs 117 的形状：仪器拿一行噪声当"这一次开机的日志"，然后报"驱动什么都没说" |
| 快照选"最早"是怎么选的？ | **按文件名里的数字**，不是目录顺序、不是字典序：名字是 `boot-<uptime>s.log`（drain 用 `cut -d. -f1 /proc/uptime` 取的），所以 `boot-2s` 必须胜过 `boot-160s` |
| 环能不能清？ | **不能。**`dmesg -c` / `-C` / `--clear` / `--read-clear` 会毁掉这份报告**唯一**的副本——一次**不可撤销**的写。现在静态守卫查一次、**记录下来的动作**里再查一次，并且有一条"裸 `dmesg` 仍然允许" |
| 这一轮仪器自己**找出的缺陷**是什么？ | 状态机拿**一行**（`checking fstab`）回答"有没有报告"，而那一行是报告里**最旧**的一行（环丢最旧的行），于是**一份从 mount label 那行开始的日志**——循环没跑完就拷下来的快照，正是 drain 的 uptime 存在的理由——被报成"initramfs 什么都没说"。**正是 docs 117 那个假阴性，从后门进来** |
| 修法？ | 计数改成**整份报告**的和（六项相加），新增状态 `REPORT PRESENT, AND IT STOPS BEFORE THE MOUNT`，**并且给它配一个场景**（`label_only`）——加了状态而没有断言，在这个工程里不算修 |
| 报告的字串会不会和镜像漂移？ | **会，而且原本无人察觉**：仪器按文本匹配，那些文本是**另一个文件**（补丁）打印的。harness 因此新增第 10 节，把补丁里**全部 8 条 `tell_kmsg` 字串**取出来、**分类**、按**补丁自己的措辞**逐条喂给仪器 |
| 怎么保证那一节不是自说自话？ | 两条：**词改一个字母**（`MOUNT FAILED` → `MOUNT-FAILED`）必须让它**不再被读作报告**；以及**普查**——补丁里出现一条 harness 没分类的报告字串就是**红的**（新增报告不能悄悄无人断言） |
| 仪器改了多少？ | `device/zl1-modem-probe.sh`：**800 行**（本轮 +339/-51 量级） |
| harness 改了多少？ | `host/zl1-modem-probe-selftest.sh`：**111 → 167 项**（1061 行） |
| 家族全量跑？ | **37 个 harness / 4908 检查 / 全绿**（仓库自指纹未变） |
| 动设备了吗？ | **没有。**设备仍在 **fastboot**（`33e80afe`，`18d1:d00d`），本轮没有一条会改变设备状态的命令 |

---

## 2. 为什么"挂载发生了没有"只能由设备侧回答

docs 154 证明的是**函数会去用那个分区**：它打了补丁、把打好补丁的 `mount_android_partitions`
**取出来运行**，断言的是建了哪个目录、用了哪个设备、做不到时说了什么。那是**离线的全部**。

它**不能**证明在真机上那一次挂载成功了：`/dev/disk/by-partlabel/modem` 在 initramfs 里存不存在，
是 initramfs 跑过 udev 之后的事。而那一次开机**留给自己的唯一记录**，就是 initramfs 写进环里的那几行——
因为：

| 东西 | 开机之后还在吗 | 怎么知道的 |
|---|---|---|
| initramfs 的 `/scripts`（补丁改的那个函数） | **不在** | `debugfs -R 'stat /scripts' /mnt/data/ubports-rootfs/rootfs.img` → `File not found` |
| 补丁新增的 `/zl1-android-fstab` | **不在** | 同上（`stat /zl1-android-fstab` → `File not found`） |
| `initrd:` 那几行 | **在环里**，直到环绕回来 | 环容量与绕回速度见 §1 表（drain 的头，2026-09-21 实测） |
| journal 里有没有 | **几乎不在** | `journalctl -k` 回 1 行（同一处） |

所以这一轮做的事不是"再写一个仪器"，而是**让已有的仪器能读到那份报告，并且在读不到的时候说"读不到"**。

---

## 3. 三个来源，固定顺序，而且"带启动相位"才算数

顺序不是风格问题：

1. **drain 的最早快照**先试。它是**开机时**对环的拷贝，而环会在大约一分钟内绕回来——"最早的那一份"
   是唯一可能还保有开机那几行的东西。
2. 再试 **`dmesg`**（活的环）。它可能还留着，也可能已经绕过去了；这是**读数**，不是保证。
3. 最后试 **`journalctl -b -k`**。在这台设备上它几乎必然很薄，但"很薄"要被**说出来**，不能被**当成答案**。

**接受一个来源的条件是它含启动相位**（`initrd:`、`Linux version`、`Booting Linux`、`Initializing cgroup`
之一）。不含的来源会被**报出来但不用**，并且明说：*它没有捕获这一次开机，从它读出的每个答案都会是假阴性*。

这一条是这一轮**第二个**真缺陷的位置（第一个见 §5）：旧的守卫问的是"这个来源**是不是空的**"，而
`journalctl` 的那一行把它满足了——于是仪器拿一行噪声当"日志"，数出全 0，再印出它的那句安慰话，
而那句话是**关于一次它从没读过的开机**的。harness 里 `thin` 场景（两个来源都薄）驱动的就是这个形状，
断言的是它必须 **UNANSWERED** 并且把"薄"**说出来**。

---

## 4. 守卫：环不能清

`dmesg -c`（以及 `-C` / `--clear` / `--read-clear`）在这个工程里不是"清理"，是**销毁证据**：
那份报告**只写过一次**，而环是它唯一落地的地方。所以：

* **静态**：harness 第 0 节在**出货源码**上查（这是它第一条守卫，带牙齿）；
* **动态**：第 9 节再从仪器**记录下来的动作**里查一次——一条把清环藏在变量里的调用，静态规则看不见；
* **反向**：`want 'dmesg $'`——**裸 `dmesg` 仍然必须允许**，否则守卫会逼着人删掉那次读。

这三条一起才是守卫：只有"禁止"没有"仍然允许"，正确的写法会被判红；只有"记录动作"没有"静态查"，
一条 `dmesg -C` 只要换个拼法就能溜过去。

---

## 5. 这一轮最要紧的发现：报告在，而仪器说"什么都没说"

状态机原本是这样问"有没有报告"的：`GLOB MATCHED, OR THIS IMAGE HAS NO REPORT` 那一支**只**问
`checking fstab` 这一行的计数。而这一行在报告里**不是第一行也不是最后一行**：

```
initrd: checking fstab /var/lib/lxc/android/rootfs/fstab* for additional mount points   <- 只有这一行被问
initrd: fstab ... matched NO file; using the one this initramfs carries: /zl1-android-fstab
initrd: checking mount label modem
initrd: mounting /dev/disk/by-partlabel/modem as /android/vendor/firmware_mnt ...
```

**那一条日志在环里是会丢开头的**：环丢的是**最旧**的行，而"checking fstab"正是报告里**最旧**的那一行。
所以一个已经绕回来的环，留下的恰恰是报告的**后半段**（`checking mount label`、`mounting`…），把开头丢掉——
而在旧判据下，**"开头不在"就等于"整份报告不在"**。drain 的快照则给出同一形状的更干净版本：**循环还没跑完
就拷下来的那一份**，内容就停在它当时说到的那一行（`boot-2s.log` 名字里的 uptime 就是给这件事用的）。

于是：日志里明明**躺着报告的行**，状态机却落到 `NO INITRAMFS REPORT IN THIS LOG`，并印出"这个日志里没有
initramfs 的报告"——把**"我说了话"读成"它没说话"**。这正是 docs 117 的形状，只不过这次不是"来源没读到"，
而是**报告读到了却被自己的判据筛掉**。

**是 harness 的新一节把它找出来的**，而不是靠想一想：第 10 节把补丁里每一条报告字串**单独**喂给仪器，
`checking mount label modem` 这一条就红了——**一条只含这一行的日志被报成"没有报告"**。

修法两处，缺一不可：

1. `IN_ANY` = 六项计数之**和**，用它回答"到底有没有报告"，于是 `NO INITRAMFS REPORT IN THIS LOG`
   现在真的意味着**一行都没有**；
2. 新增状态 `REPORT PRESENT, AND IT STOPS BEFORE THE MOUNT`，它在 §4 和 verdict 里**各自**有一段话，
   说的是"来源到这里就结束了"（循环还没跑完就拷下来的快照），**不是**"它什么都没说"；它同时把反面的形状写清楚——**丢开头**那是环干的事，不是这一支。

**并且配了一个场景**：`FAKE_RING=label_only`——环里只有启动相位和那一条 mount label 行——断言状态是
新的那一个、并且**不是**"没有报告"。**新增状态而没有场景，在这个工程里等于没修**（docs 117 的教训）。

---

## 6. 第 10 节：字串从补丁里取出来，不是在这里打一遍

仪器按**文本**读那份报告，而那些文本是**另一个文件**打印的：
`boot/patches/0200-halium-modem-firmware-mount.patch`。两半住在不同文件里，所以补丁里**改一个词**，
仪器的挂载读数就会静默变成"initramfs 什么都没说"——**而全树不会有任何东西注意到**。

harness 的第 10 节因此不"再打一遍字串"，而是**从补丁里取**：

| 步骤 | 做法 | 为什么 |
|---|---|---|
| 取 | `sed` 出补丁里**所有** `tell_kmsg "…"` 的参数（**added 行与 context 行都取**——`checking fstab` 是一条 context 行，而四条挂载结果是 added 行）；先剥掉 diff 标记，所以带 tab 的 context 行也能找到 | 仪器匹配的是**"halium 原本会说的" ∪ "补丁加上的"** |
| 底线 | 取出的条数 **< 8 就是红的**（今天是 8 条） | 一个匹配不到东西的提取器不能通过 |
| 分类 | **两个桶**：`mount`（7 条：`checking fstab` / `matched NO file` / `checking mount label` / `no device for label` / `mounting ` / `MOUNT FAILED`）与 `other`（1 条：`moving Android system to`） | 补丁里新出现一条**没被分类**的报告字串 → **红的**。新增报告必须人为分类，不能悄悄无人断言 |
| 代入 | 把 shell 变量换成设备上的真值（`$fstab` → `/var/lib/lxc/android/rootfs/fstab*`、`$label` → `modem`、`$path` 与 `$1` → `/dev/disk/by-partlabel/modem`、`${mount_root}/$2` → `/android/vendor/firmware_mnt`、`$3` → `vfat`、`$4` → `ro,shortname=lower`） | 要喂的是**设备会打印的那一行**。**有变量没被替换掉就是 FAIL 而不是 SKIP**——那意味着这份 fixture 是猜的 |
| 断言（mount 桶） | 仪器**逐字**印出这一行（`grep -F`），且状态**不是**"没有报告" | 两条都是它必须做到的 |
| 断言（other 桶） | 仪器**不**把它读作挂载报告 | 反向也要成立，否则一个"什么 `initrd:` 行都当报告"的模式也能通过 |
| 普查 | 两个桶的条数都 > 0，且**加起来等于取出的总数**，并把条数**印出来** | 一个什么都没读到的 `while` 会让上面每条断言都不执行 |
| 牙齿 | 把一行**改一个字母**（`MOUNT FAILED` → `MOUNT-FAILED`）再喂一次，必须**不被读作报告**，并且那一份环的状态必须**如实**报成"没有报告" | 没有这一条，"它印出了这一行"对**任何文本**都成立，也就不说明任何事 |

**实现上的一处小心**：循环用 `while … done < 文件` 的**输入重定向**，不是管道——管道会把循环放进子 shell，
于是计数器和 `PASS/FAIL` **全丢**，一节就能全绿地什么都不证明。

**而这一节的初稿被这棵树自己的守卫判了红**：断言写成了 `printf … | grep -q`，而
`host/zl1-selftest-family-selftest.sh` 有一条不变式扫**每一个设了 `pipefail` 的 harness**，禁止在管道右边
放会提前退出的读者（`grep -q`/`grep -m`/`head`）——因为那时**管道的状态是写者的死**，不是检查的答案
（[`134`](134-the-false-fail-was-in-the-pipeline-s-writer.md) / [`135`](135-the-wait-said-not-registered-and-the-writer-was-the-one-that-died.md)；守卫本身见 [`136`](136-the-two-early-exiting-readers-are-not-the-same-defect.md)）。这里输入都很小、`grep -q` 不会真的把写者提前关掉，但**形状**就是守卫要禁的那个，
所以修的是断言本身：`grep -Fq -- pat <<< "$out"`（here-string 没有会死的写者进程）。这条守卫的价值正在于
它**在形状出现的那一刻就红**，而不是等到某个输入长到 349 KB。

---

## 7. 顺手改掉的一句措辞：候选 fstab 不在，不等于"这一次没挂"

仪器 §3 原本把"容器里的候选 fstab 不在"写成 `MOUNTED NOTHING THIS BOOT`。**那是一个过度结论**：

* 它**排除掉的是一种机制**（Android ramdisk 里的 fstab，也就是 halium 的循环本来要读的那份）；
* 它**没有**回答 initramfs **这一次**挂没挂——挂载发生在 initramfs 里，那次 boot 的 fs 在 `switch_root`
  之后就不在了，**候选文件不在**与**循环跑没跑过**是两件事。

现在这一节写的是 `with an UNPATCHED initramfs THAT LOOP MOUNTED NOTHING THIS BOOT`，并明说它**只**排除了
一种机制。分类那个问题的，是 §4 的那份报告（§5/§6 就是它的两道守卫）。

---

## 8. 数字

| 项 | 读数 | 怎么读的 |
|---|---|---|
| 仪器 | `scripts/device/zl1-modem-probe.sh`，**800 行** | `wc -l` |
| harness | `scripts/host/zl1-modem-probe-selftest.sh`，**1061 行 / 167 项** | 一次运行：`pass=167 fail=0` |
| 两个记数页 | `host/zl1-health-check.sh` 与 `scripts/README.md` 都从 **111** 改到 **167**，并各加了一段说明 | docs 110 的引用漂移守卫逐条核对 |
| 报告状态 | **9 个**（8 个读数状态 + `UNREADABLE`；新增的是 `REPORT PRESENT, AND IT STOPS BEFORE THE MOUNT`） | `grep -n 'INITRD_STATE="' scripts/device/zl1-modem-probe.sh` |
| 补丁的报告字串 | **8 条**（7 条关于挂载 / 1 条不是） | harness 第 10 节自己印出来 |
| 家族总数 | **4852 → 4908**（只动这一个 harness：111 → 167） | 家族 runner 把每个 harness 的 `pass=` 加起来 |

---

## 9. 这一篇**不**证明什么

* **不证明那一次挂载在真机上成功了。**它证明的是**仪器会如实报告**它成功、失败、设备不存在、
  还是"日志到此为止"。
* **不证明真机上会出现这些 `initrd:` 行。**harness 证明的是**这个仪器会读**；那些行出现的前提是
  补丁真的走到那一步（docs 154 的 §9 已经列过这条边界）。
* **不证明 drain 装在设备上。**没装的话，来源①就缺席，仪器会**说出来**并退回到活环——那是**读数**，
  不是保证。
* **不证明 journal 在别的 boot 上仍然只有一行。**那是 2026-09-21 的读数，写在 drain 的头里；仪器因此
  **不依赖**它——一个薄的来源会被拒绝，而不是被信任。
* **不证明状态名与设备的真实行为一一对应。**状态是从**日志文本**读出来的；"它说它挂了"与"挂上了"
  在 verdict 里是**分开写**的两件事（`MOUNTED` 那一支说的就是"两者不一致时不要判谁错"）。
* **不证明补丁与仪器的字串不会漂移。**它证明的是**一旦漂移，harness 会红**（§6 的最后两行）。

---

## 10. 设备状态与下一步

整轮**没有写设备**：没有挂载、没有写镜像、没有 flash、没有一条会改变设备状态的命令。设备在
**fastboot**（`33e80afe`，`18d1:d00d`，端口 3-3）。

不需要设备就能重跑这一页的每一条读数：

```
bash scripts/host/zl1-modem-probe-selftest.sh        # 167 检查（含第 10 节的补丁字串普查）
bash scripts/host/zl1-cli-usage-selftest.sh          # 引用漂移守卫（README ↔ 健康页必须一致）
```

挡住整个工程的那一步仍然**在手上**：插**墙充**，然后
`bash scripts/host/zl1-battery-gate.sh --samples 9 --interval 60`；读数许可之后
`scripts/host/zl1-one-boot-runbook.sh --yes` 就是那一次 boot。

### 10.1 那一次 boot 上要看的两处

```
   source …: N lines, and it CONTAINS THE BOOT PHASE -- this is the log read below
   -> STATE: <mounted / mount failed / device absent / …>
```

**第一处**说明**哪一个来源**被采纳了（drain 的最早快照最好；只有活环也行，但要看清是哪一类）。
**第二处**是 initramfs 自己说的话——`MOUNTED` 是修好了，`MOUNT FAILED` 与 `DEVICE ABSENT` 是有名字的
原因（挂载点、设备），`NO FALLBACK` 是**旧行为变得可听见**，而 `REPORT PRESENT, AND IT STOPS BEFORE THE MOUNT`
意思是**日志太短**、要重取而不是下结论。
