# 163 — 那个参数是 bool，而守门的比较同时卸掉了自己的撤销

**日期**: 2026-09-25
**状态**: 这一轮**碰了设备**（一次用户授权的 trial 写），而它拿到的第一个结果是**上一轮的失败原因**：
`05-trial` 的 `rc=4` **不是**关于驱动的发现，是**关于读数自己的形状**——它把「我写进去的字符串」和
「设备读出来的值」当成了同一样东西。

而这一页的第二半更值得记：**那个判据同时也是撤销的开关**。判据说「写没生效」的那条路，正好是
**唯一一条**留下了改动、却因此**不肯撤销**的路。设备上的证据是硬读出来的：
2026-09-25 13:06Z，`sleep_disabled` 读 **`N`**，而这次开机的 cmdline 要的是 `1`——**那次写成功了，
而没有任何东西认领它**。

**第三半是那一步的后果**：那次留下的 `N` 让梯子被允许了 31 分钟，而 cpuidle 的计数器是**自开机累加**的。
所以下一次 trial 的「写之前」快照里已经装着**别人**造出来的进入次数，而它的判据问的正是「写之前**有没有**
进过深睡」——于是修好字母表之后的第一次真机运行印出了 `== verdict: refuted`，**用的却是一段这个参数
根本没在生效的窗口**。判词自己写下了真相（「state2 was ALREADY being entered before this script wrote
anything」），却把它读成了对假设的否定。修法是**第四条前置条件**（baseline D），以及让 runbook 的
`--status` 把它读出来——因为这一条的补救是**重启**，而它是步骤 05，也就是**最后一步**。

于是这一页是**一个错误的四种写法**：

① 一个 `bool` 参数被当成字符串读（三个读者各犯一次）；
② 一个 `WROTE` 标志设在它所守护的那次比较**之后**，于是拒绝路径丢掉了撤销；
③ 三个 harness 的 fixture 都是**没有类型的纯文本文件**，所以**它们一个都测不出前两条**；
④ 一个**自开机累加**的计数器，和一个「原样写回去再读一遍」的证明**一样**，证明不了它之前发生过什么。

**接续**: [`162`](162-the-run-was-three-boots-and-the-scripts-name-was-never-checked.md)（那次运行其实是三次开机；
这一页是它留下的那个 `rc=4` 的原因）、[`160`](160-the-third-heat-cause-had-an-experiment-and-no-installer.md)（散热第三因的安装器，
它的执照就是这一轮第一次真正拿到的那行判词）、[`153`](153-the-premise-was-false-and-the-answer-was-on-this-laptop.md)
（`zl1-lpm-sleep-semantics.sh` 把 `module_param_named` 那一行**逐字引用**为「唯一携带类型的那句声明」）、
[`121`](121-the-third-question-about-the-heat.md)（`sleep_disabled` 是模块参数、0664、可运行时写）、
[`114`](114-the-refusal-gate-was-satisfied-by-the-process-it-removes.md)（执照必须是一整行，不能是一句话）、
[`134`](134-the-false-fail-was-in-the-pipeline-s-writer.md)（`want` 自己报过的假 FAIL）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 上一轮 `05-trial` 为什么 `rc=4`？ | 因为**写成功了，而脚本要求读回来的是它写进去的那个字符串**。`sleep_disabled` 是 **`bool`**，sysfs 把存储值**渲染**成 `Y`/`N`：写 `0` 读回 `N` **就是一次成功的写**。 |
| 那句话是谁打的？ | `the write did not hold: read-back is 'N' (wanted 0). The trap reverts and this run stops -- a file that will not take the value is a finding about this boot's driver.` 它把一次**成功的写**说成了关于驱动的发现。 |
| 那到底写进去了吗？ | **写进去了。** 13:06Z 重读：`sleep_disabled = N`；而 `/proc/cmdline` 里写着 `lpm_levels.sleep_disabled=1`。写之前（步骤 2）读的是 `Y`。 |
| 那撤销了吗？ | **没有。** `WROTE=1` 设在读回检查**之后**，而 `trap` 正是以 `WROTE` 为闸——所以「判据说写没生效」这条路，恰好是**唯一一条**不撤销的路。 |
| 声明在哪？ | `drivers/cpuidle/lpm-levels.c`（构建本机镜像的那棵树，`/mnt/data/halium-zl1-build/kernel/leeco/msm8996`）第 125-127 行：`static bool sleep_disabled;` + `module_param_named(sleep_disabled, sleep_disabled, bool, S_IRUGO \| S_IWUSR \| S_IWGRP);`。 |
| 有几个读者犯了同一个错？ | **三个。** trial（拒绝了自己的好写）、installer（applier 的读回 + 收尾判词）、以及**只读探针** `zl1-sleep-and-throttle.sh`（它会把一条 **ALLOWED** 的梯子说成 **OFF**，正好是它自己判词的**反面**）。 |
| 那棵树知道吗？ | **知道。** `scripts/host/zl1-lpm-sleep-semantics.sh` 从 docs 153 起就 `grep '^static bool sleep_disabled'`，并把 `module_param_named` 逐字引用为「唯一携带类型的那句声明」。声明被一个仪器读着，而三个读者没有一个去问它。 |
| fixture 为什么没抓到？ | 三个 harness 的参数文件都是**纯文本**（写 `0` 读 `0`），所以**修好的脚本和没修的脚本行为完全一样**——一个分不开两种行为的 fixture，哪一种都测不了。上一轮 trial 的 harness 就是在这上面报了 **147 个 PASS**，而脚本在真机上拒绝每一次好写。 |
| 修了吗？ | 修了，而且每一处都配了**突变**和**对照**：把老的比较改回去必须红（三个地方各一次），把类型拿掉则**两个版本必须都过**（证明差别只在类型）；`WROTE` 那一处用一次「删掉 `WROTE=1`」的突变钉住。 |
| 刷了吗？ | **没有。** |
| 那这次授权跑出来的判词呢？ | `== verdict: refuted`——**而它是错的**。见第 8 节：判据问「写之前有没有进过深睡」，而这次开机的计数器里已经装着**上一次没被撤销的写**留下的 162874 次。 |
| 那参数到底管不管深睡？ | **管。** 参数保持 `Y` 的两次快照相隔 127 秒：四个 CPU 的 `state1`/`state2` 增量**全是 0**，只有 `state0` (C0) 在动。而参数是 `0` 的那 120 秒窗口里（这次运行的第 8 节），四核的 `state1`/`state2` 增量是 **5864 到 28624**。 |
| 那"发烫解决了吗"？ | 见第 8 节：这一轮第一次拿到了 trial 的判词，安装与否由它决定。 |
| 现在参数是什么？ | **`Y`**——**这次运行自己的 revert 放回去的**（第 9 节逐字记着）。所以「有人认领」这件事现在成立了；但**这次开机的计数器仍然是脏的**，只有重启能清。 |

---

## 2. 证据：一次成功的写被判成失败

`tmp-one-boot-20260925T125314Z/05-trial.txt` 的最后四行（这一页的全部起点）：

```
== 5. the write path, proved BEFORE anything is changed
   wrote 'Y' back to itself and read 'Y' -- the file is writable AND readable.

== 6. the write, with the undo on the device rather than in this session
   wrote the undo to /tmp/zl1-lpm-trial-revert.sh (run it, or: sh /tmp/zl1-lpm-ladder-trial.sh --revert)
   the write did not hold: read-back is 'N' (wanted 0). The trap reverts and this
   run stops -- a file that will not take the value is a finding about this boot's driver.
```

而 `06-lpm-fix.txt` 于是再次拒绝（`REFUSING: '…/05-trial.txt' holds no '== verdict: …' line at all.`）——
**散热第三因因此没有被安装**，而它其实**已经被写进去了**。

### 2.1 那三行代码，和它的类型

```c
static bool sleep_disabled;                                          /* 125 */
module_param_named(sleep_disabled,                                   /* 126 */
	sleep_disabled, bool, S_IRUGO | S_IWUSR | S_IWGRP);          /* 127 */
```

`bool` 参数的 sysfs `show` 把存储值**按类型渲染**：存 `0` 印 `N`，存 `1` 印 `Y`。
同目录的兄弟参数正好把这一点印在设备上（2026-09-25 09:12 的设备读数）：

```
/sys/module/lpm_levels/parameters/menu_select         = N      <- bool
/sys/module/lpm_levels/parameters/print_parsed_dt     = N      <- bool
/sys/module/lpm_levels/parameters/sleep_disabled      = N      <- 全脚本围绕的那一个
/sys/module/lpm_levels/parameters/sleep_time_override = 0      <- int，所以它是 0
```

`menu_select` 印 `N` 而 `sleep_time_override` 印 `0`——**同一张 `ls` 里两种拼法，就是类型在说话**。
而 trial 的**步骤 5 抓不到这件事**，也不该指望它抓：把刚读到的值原样写回去，**与字母表无关**，
任何文件都会过。字母表只在**值发生改变**的那一次写上有意义——而那正是这个脚本存在的理由。

### 2.2 写之前、写之后

| 时刻 | 读数 | 来源 |
|---|---|---|
| 12:53:14Z | `value: Y` | `05-trial.txt` 步骤 2（`P_BEFORE`） |
| 12:53Z | 写 `0`，读回 `N`，`rc=4` | `05-trial.txt` 步骤 6 |
| 13:06:19Z | `sleep_disabled = N` | 主机直接 ssh 重读（`uptime` 17649s） |
| 13:06:19Z | cmdline：`lpm_levels.sleep_disabled=1` | 同一次重读 |
| 13:20Z | `sleep_disabled = N` | 再次重读（`uptime` 18244s） |

**设备时钟是坏的**（`date` 给出 `Fri Feb 13 06:19:33 AM EST 1970`），所以那台机器上的 mtime 不能用来定序
（参数文件的 mtime 和它的兄弟不同，但那个时间戳本身没有意义）。这一页的时间线全部来自**主机**的时钟
和**设备自己打的 `uptime`**——就是 doc 162 定下的规矩。

---

## 3. 第二个缺陷：判据卸掉了自己的撤销

```sh
printf '0' > "$PARAM" || { bad "   the write failed"; exit 4; }
P_AFTER_WRITE=$(rd "$PARAM")
if [ "$P_AFTER_WRITE" != 0 ]; then
  bad "   the write did not hold: …"
  exit 4
fi
WROTE=1                      # <- 撤销的闸门，只在这里打开
```

`trap 'do_revert' EXIT INT TERM HUP` 的第一行是 `[ "$WROTE" = 1 ] || return 0`。
所以这两行合起来的意思是：**「文件已经变了、而脚本不知道」这条路，正好是「撤销不响」的那条路。**

脚本自己的注释把 `WROTE` 的语义写得很准——「参数的值真的被改过的那一刻」——而它**判定「真的被改过」
所用的证据，正是那条刚刚失效的比较**。这不是两个 bug 拼在一起，是**一个判据同时当了两件事**：
它既报告「没生效」，又负责证明「什么都没变」。

修法是换掉证据本身：**重定向返回了，就说明文件此刻可能装着别的东西**——所以 `WROTE=1` 紧跟在
`printf` 的成功之后，在读回之前。

---

## 4. 同一个比较，四个文件（加上新一轮里它自己的两个读者）

| 文件 | 老写法 | 在真机上会发生什么 |
|---|---|---|
| `device/zl1-lpm-ladder-trial.sh` §6 | `[ "$P_AFTER_WRITE" != 0 ]` | 拒绝自己的好写，`rc=4`，判词行缺失，安装器再次拒绝（**上一轮就是这样**） |
| `device/zl1-lpm-ladder-trial.sh` `do_revert`/`--revert`/§9 | `[ "$(rd "$PARAM")" = 1 ]` | 撤销**成功了**也会报 `THE REVERT DID NOT HOLD`——安全网自己拉假警报 |
| `install-lpm-sleep-fix.sh` applier | `[ "$got" = 0 ]` | 每次开机都 `did NOT take 0 (reads 'N')`、`exit 1`、**unit 进 failed**——而修复是好的 |
| `install-lpm-sleep-fix.sh` 收尾判词 | `awk '$1 != 0 {f=1}'` | 判词会印 `== verdict: not-installed`，就在一台已经装好的机器上 |
| `device/zl1-sleep-and-throttle.sh` §1 | `[ "${SYSFS_SD:-x}" = 0 ] \|\| SYS_ON=yes` | 把**允许睡眠**的梯子读成 **OFF**，并在 §1 里印「两半一致认为梯子是关的」——**它自己判词的反面** |
| `device/zl1-lpm-ladder-trial.sh` §2（baseline D，第 8.3 节新加） | `is_off "$P_BEFORE"` | 这一条**新写的时候就用对了**，因为它是同一天同一个教训的第二次应用——而它比上面几处更要紧：D 要判的**只有**「off 还是 on」，而设备**永远只给读者看 `N`**。所以它的 harness 是一对（`0` 和 `N` 各一次），并且有一颗只认 `0` 的突变做对照 |
| `host/zl1-one-boot-runbook.sh` `read_lpm_param()`（第 8.4 节新加） | 设备侧 `case "$v" in 1\|Y\|y\|on)` | 同上：这是**同一个判据的第二个读者**（`--status` 也要提前知道基准脏不脏），而它的突变就是把 `case` 改成只认 `0` |

修法是同四个字：**读状态，不读字符串**。`is_off` = `0|N|n|off`，`is_on` = `1|Y|y|on`，
其余的值**两个都不是**，并且**明说**它不是（`zl1-sleep-and-throttle.sh` 的 `SYS_ON=other` 分支
就是为此存在：一个认不出来的值不许被折进任何一边）。

`is_off`/`is_on` 在 trial 里的注释逐字引用了 §2.1 的 `module_param_named` 那一行，因为**这一页的教训
不是「要小心」，是「类型是声明里的一个字段，而读它只要一行 `grep`」**——同一个仓库里的
`zl1-lpm-sleep-semantics.sh` 早就那么做了，并且把那条声明**印出来**。

---

## 5. 修法：五处 harness，两处不需要 shim

一个 fixture 要能代表一个**有类型**的 sysfs 文件，渲染该放在哪里——取决于被测脚本拿它做什么：

| harness | 被测者的读法 | 怎么办 |
|---|---|---|
| `host/zl1-lpm-ladder-trial-selftest.sh` | `rd()` = `tr -d '\n' < f` | **`tr` stub**：路径匹配到那个参数时把 `0`→`N`、`1`→`Y`，其余**原样转交**。路径靠 `readlink /proc/self/fd/0` 认（`readlink` 因此进了沙箱 PATH——一个缺工具的沙箱会**静默**关掉需要它的行为）。 |
| `host/zl1-installers-selftest.sh` | applier 的 `got=$(cat "$p")` | **`cat` stub**，同一个规则。开关是**文件**而不是环境变量：这个 stub 是 harness 的**曾孙**（harness → installer → `systemctl` stub → applier → `cat`），一个送不到的控制"看着是绿的、其实什么都没证明"。 |
| `host/zl1-sleep-and-throttle-selftest.sh` | 只读 | **不需要任何 shim。** 只读探针的输入**就是设备交给它的答案**，所以 fixture 里写 `N`/`Y` 本身就是忠实的（`FAKE_LPMPAR=rendered-on\|rendered-off`）。写者要建模一个往返，读者不用。 |
| `host/zl1-one-boot-runbook-selftest.sh` | `read_lpm_param` 的设备侧 `cat` | **同样不需要 shim**，理由同上：这一段跑在 ssh 的**设备那一侧**，`cat` 的输入就是设备的答案，所以 fixture 里直接放 `Y`/`N`。它需要的只是**一条路径映射**（`emit "s#/sys/module/\*/parameters/sleep_disabled#…#g"`）——一条**单独的**规则，而不是把上面那条泛化成 `/sys/module/*/parameters/`：泛化的那条会把将来任何一步提到的模块路径都映射到这台 fixture 上，也就是让 fixture 去回答一个关于**别的旋钮**的问题，而**答错问题的 fixture 是失败不了的**。 |

而 `tr`/`cat` 这两个 stub 是**承重**的，和 `sleep` 那个一样：只有它们在场，「文件里装的是什么」
（harness 自己的读取器 `param()`）和「设备说的是什么」（脚本的每一次读）才**能分开**，
而**这正是让修好的脚本和它的前身行为不同的唯一条件**。

### 5.1 每一处都有一颗牙和一个对照

* **§7a（trial 的字母表）**：类型在场时 `--apply` 必须 `exit 0` 且印 `read 'N' back`；
  把 `is_off` 改回 `!= 0` 的**突变**必须 `exit 4` 并印 `read-back is 'N'`（**与设备上一字不差**）；
  然后把类型拿掉（`FAKE_BOOL=0`，也就是这个 fixture 从前的样子）——**两个版本都必须过**。
  最后一条是这一节的**对照**：没有它，这一节只是在演示自己搭的台子。
* **§9b（谁给撤销上闸）**：`FAKE_STUCK=1` 是「写**落地**了、值**不生效**」——纯文本文件表达不了的
  第二种事，也正是那条**注释说"这里造不出来"**的分支。它现在造得出来：修好的脚本必须 `exit 4`
  **并且把文件放回 `1`**；**删掉 `WROTE=1`** 的突变则必须**留下改动**。
* **installer 的三连读**：同一个 applier、同一个 fixture，读三次——装好的通过并印 `OFF on 1 parameter`；
  把 `case` 改回 `[ "$got" = 0 ]` 的突变印出设备上的原话 `did NOT take 0 (reads 'N')`、`exit 1`、
  让 unit 在一台好机器上失败；**把类型关掉**之后同一个突变通过。
* **§5b（baseline D 的字母表）**：`FAKE_PARAM` 是 `0` 时 `--apply` 必须 `exit 3` 并印
  `REFUSED (baseline D)`、`Nothing was written`，文件**一个字节都不能动**；**同一个状态用 `N`**
  必须**同样拒绝**；把判据改成 `[ "$P_BEFORE" = 0 ]` 的突变则**必须不拒绝**——这一对才是测量，
  因为设备**永远只给读者看 `N`**。同一节还把拒绝里点名的补救 `--revert` **真的跑了一遍**
  （拒绝点一个没人检查的命令，那是一句话，不是一个补救）。
* **runbook 的第七个突变**：把设备侧的 `case "$v" in 1|Y|y|on)` 改成 `case "$v" in 0)`——
  一个只认写者拼法的读者，必须在一台读 `N` 的设备上把 `D. sleep_disabled` 报成 **`ON`**
  （也就是「基准是干净的」，而 05 恰恰会在这台设备上拒绝）。

顺手记下一个**次序陷阱**，第一版就踩了：`lpm_reset` 会把**好的** applier 拷回 `$W/applier`，
所以**在它之前**拷进去的突变会被**静默换回去**——那一趟量的是成品，报告的却是突变。它在第一次运行里
读作 `it exited 0`。

---

## 6. 数字

| harness | 之前 | 现在 |
|---|---|---|
| `host/zl1-lpm-ladder-trial-selftest.sh` | 151 | **187** |
| `host/zl1-installers-selftest.sh` | 442 | **451** |
| `host/zl1-sleep-and-throttle-selftest.sh` | 107 | **114** |
| `host/zl1-lpm-sleep-semantics-selftest.sh` | 102 | **107** |
| `host/zl1-one-boot-runbook-selftest.sh` | 265 | **276** |

（trial 那一格分两轮长起来：字母表那一轮到 169，baseline D 那一轮再到 187。runbook 的三条来自
第 8.4 节：`--status` 的 ON/OFF/NOT-FOUND 三个分支，加上第七个突变的三条。）

`scripts/README.md` 的对应条目和 `host/zl1-health-check.sh` 的引用计数同步改了——引用漂移是这些
harness 自己会报的一种红，五个计数各改一次。

---

## 7. 设备现在的样子（**2026-09-25 本轮结束时重读**，只读，一条写都没有）

| 读数 | 值 | 说明 |
|---|---|---|
| `boot_id` | `693b2eed-4460-46ae-9816-83b2a9220b00` | **仍然是 doc 162 的那一次开机**——从 08:03 到现在一直没重启过。这一页所有读数都在这一次开机上。 |
| `uptime` | 19514s（5h25m） | ssh 通、RNDIS 通 |
| `lpm_levels.sleep_disabled` | **`Y`** | **梯子是关的**，而且这一次**有东西认领它**：13:15Z 那次 `05-trial` 自己的 revert（第 8.1 节） |
| cmdline | `lpm_levels.sleep_disabled=1` | 与文件**一致**——12:53–13:15 之间那个「不一致」的形状已经不在了 |
| `msm_poweroff.download_mode` | `0` | 02 的 panic guard 在生效（A 满足） |
| debug keeper | 不在（argv 匹配，0 个） | 03 退休过（C 满足） |

**但这一次开机的计数器仍然是脏的**，而且这正是 baseline D 存在的理由：`sleep_disabled` 现在是 `Y`、
cmdline 也是 `1`，看上去一切正常，而 `state1`/`state2` 里仍然躺着那 31 分钟攒下的十几万次。
**D 在这台设备、这一次开机会拒绝**，而脚本没有办法把累加值清零——
**唯一的路是重启**：cmdline 会在新的一次开机上再把它设成 `1`，而计数器从零开始。

这一条也顺带说明 D 的判据为什么是**值**而不是「文件时间戳」：参数文件的 mtime 在这台设备上不可信
（设备时钟是坏的，第 2.2 节），而「文件里现在是 `Y`」和「这一次开机的计数器干净」是**两件事**。

---

## 8. 这一轮跑的那一次：它跑完了，判词出来了，而判词是错的

用户授权的那一步是 `scripts/host/zl1-one-boot-runbook.sh --yes --apply-trial`，
它按固定次序跑 01→06，而 06 的执照是 **05 自己刚写下的那一行判词**。归档在
`tmp-one-boot-20260925T131556Z/`。

### 8.1 字母表那一半**成了**

`05-trial.txt` 的第 6、9 节——修好字母表之后第一次在真机上跑：

```
== 6. the write, with the undo on the device rather than in this session
   wrote 0 and read 'N' back: the ladder is ALLOWED from this moment until the revert.
   ('N' is this file's rendering of 0. The parameter is a bool, so sysfs shows Y/N
    whatever spelling was written -- comparing against '0' here is what refused a good write before.)
...
== 9. the revert
   [trap] /sys/module/lpm_levels/parameters/sleep_disabled put back to 1 (it reads 'Y'), verified by read-back.
```

写 `0`、读回 `N`、认成 OFF、跑完、**并且撤销了**——这几行正是第 2、3 节那两个缺陷的反面。
`06-lpm-fix` 于是第一次**真的读到了**判词（上一轮它拒绝的理由是「05 的输出里根本没有
`== verdict:` 这一行」）。

### 8.2 而那一行判词是 `refuted`

```
== 10. the verdict
   before this boot's write, state2 (C2) had been entered 162874 time(s)
   during the window it was entered 15738 more time(s), for 66148914 more of its counted time
   the shallowest state (state0) moved 1171 time(s) in the same window
   -> REFUTED: state2 was ALREADY being entered before this script wrote anything
== verdict: refuted
```

判据的逻辑没错，读数也没错：`state2` **确实**在写之前就有 162874 次。错的是**这个数来自哪一段**。
**上一趟**（`tmp-one-boot-20260925T125314Z/05-trial.txt`，12:53:14Z，同一次开机 `693b2eed`，
距开机约 4h41m）读到的同一个状态是：

```
   value: Y
== 3. the counters BEFORE
   cpu0 state1 C1           usage=0          time=0
   cpu0 state2 C2           usage=0          time=0      (cpu1/cpu2/cpu3 同)
```

也就是说：**参数自开机起一直是 `1` 的 4 小时 41 分钟里，`state1`/`state2` 一次都没进过。**
而那 162874 次，是 **12:53 那一趟自己没有撤销的写**把梯子放开约 31 分钟攒下的（第 2、3 节）。
cpuidle 的计数器**自开机累加**，脚本没有任何办法把它们清零——所以在这台设备、这一次开机上，
「写之前进过深睡吗」这个问题的答案是关于**上一个写者**的。

判词自己把那句话印了出来（`was ALREADY being entered before this script wrote anything`），
然后把它读成了对假设的否定。**这就是第 10 节那句结论的第三次出现**：一个证明不了「之前」的证明。

而这次运行的**后半段**恰好是有效的那一半：参数是 `0` 的那 120 秒里，四个 CPU 的 `state1`/`state2`
增量都很大（cpu0 `17364`/`15738`，cpu2 `27670`/`8249`，cpu3 `28624`/`5864`，cpu1 `9627`/`16982`）。

### 8.3 补上的那一次测量

参数保持 `Y`、两次快照相隔 **127 秒**：**四个 CPU 的 `state1`/`state2` 增量全是 0**，只有
`state0` (C0) 在动。这一次不需要操心基准干不干净，因为**增量**本来就是干净的那一半——而它同时是
「计数器的绝对值不是基准」的现场演示：那两个状态在写之前就已经躺着十几万次的累计值，
参数回到 `Y` 之后它们**停止**了累加。

于是第三个缺陷的修法是**第四条前置条件**，加在 trial 的第 4 节里（连同第 2 节的那段解释）：

```
REFUSED (baseline D): /sys/module/lpm_levels/parameters/sleep_disabled is ALREADY off, so this
boot's cpuidle counters hold entries made while the ladder was allowed. ... Nothing was written.
Measured 2026-09-25: this exact state produced a REFUTED verdict that inverted its own data --
0 entries in 4h42m with the parameter on, and 162874 in the 31 minutes since a previous run
wrote 0 and did not revert. --revert, then reboot, then run this on a boot whose cmdline is the
first thing to touch the driver.
```

三个细节是刻意的：

* 判据是 `is_off`，不是 `= 0`——**同一个字母表问题**，而且这里更要紧，因为设备**永远只给读者看 `N`**
  （第 8.1 节那行 `read 'N' back` 就是它）。harness 的 §5b 因此是一对：同一个状态用 `0` 和用 `N`
  各跑一次，`is_off` 必须**两次都拒绝**，而把判据改成 `= 0` 的**突变必须看不见 `N`**。
* 拒绝**不写任何东西**，并且明说补救是 `--revert` + **重启**——它是这几条拒绝里唯一一条补救不是命令的。
* 它挡的**不只是手写的 `0`**：`install-lpm-sleep-fix.sh` 装好之后，它的 unit **每次开机**都写 `0`。
  所以「参数已经是 `N`」也可能正是**修好的样子**，而那台设备上 05 已经没有什么可量的了——
  这也是判词的一部分，不是故障。

### 8.4 runbook 的 `--status` 也读它

D 是**唯一一条补救是重启**的前置条件，而 05 是**最后一步**：在那里才知道，等于这一趟开机其余五个读数
已经花掉了。所以 `zl1-one-boot-runbook.sh --status` 现在多读一行
（`read_lpm_param`，与 `read_download_mode` / `read_keeper` 同样是设备侧的一次读 + 第四种 token）：

```
  D. sleep_disabled: OFF /sys/module/lpm_levels/parameters/sleep_disabled=N   <- something wrote it. ...
     Step 05 would REFUSE on this boot: ... The remedy is a reboot -- the cmdline sets 1 again
     and the counters restart at zero -- so reboot BEFORE spending this boot if you want 05's verdict.
```

它**不**让整趟序列提前拒绝——01 到 04 在这一趟开机上仍然有用，而被拒绝的 05 只会让 06 拒绝
（06 的执照本来就来自 05）。这一点和第 3 节 `--status` 处理 A、C 的方式一致：报告，而不是替操作者
花掉那趟开机。

它的 harness 因此多了一支**第七个突变**：把设备侧的 `case "$v" in 1|Y|y|on)` 改成 `case "$v" in 0)`
——也就是一个**只认写者拼法**的读者——那么在一台读 `N` 的设备上它会报
`D. sleep_disabled: ON`，即**说基准是干净的，而 05 恰恰会在这台设备上拒绝**。

---

## 9. 这一轮**没有**做的事

* **没有刷任何分区**，没有动 boot 镜像，没有进 EDL，没有碰 modem/EFS/calibration/persist；
* **没有重启设备**；唯一的写是 `05-trial` 那一次参数写，它有 trap、有设备侧的 undo 文件，
  而且**不跨重启**——它也已经自己撤销了（第 7 节：现在是 `Y`）；
* **没有装散热第三因**。`06-lpm-fix` 是**做对了**：它的执照是 `== verdict: supported-not-proven`，
  而这一趟拿到的是 `refuted`，所以它拒绝——而那个 `refuted` 是这一页第 8 节的产物，
  不是关于散热的结论；
* **没有对散热本身下结论**。参数是"意图"的证据，cpuidle 计数器是"行为"的证据，
  而温度是第三个读数（`zl1-thermal.sh --ab`）——这一轮做的是让这三个读数**读得对**。

**下一步的形状是确定的，而且只有一条**：重启（cmdline 把参数设回 `1`，计数器归零），然后
`zl1-one-boot-runbook.sh --yes --apply-trial` 会在**干净基准**上第一次跑到判词——
`supported-not-proven` 就装第三因，`refuted` 就是关于这个参数的真结论。
这一轮买到的正是「那一次运行的结果可以被相信」。

---

## 10. 阶段位置

这一轮修好的不是散热，是**读它的工具**：一个 bool 参数被三个读者当成字符串，其中两个**拒绝了自己
成功的写**，一个**把自己判词读反**；三个 harness 因为 fixture 没有类型，**一个都看不到**；
而一台**自开机累加**的计数器让一个逻辑正确的判据在一个脏基准上印出了**与自己数据相反**的判词。
四个读数、四个不同的缺陷，落在同一句话上：**「读数成立的条件」和「读数本身」，是两样要分别检查的东西。**

**这一页最后要说的是两句，第二句是这一轮新长的：**

* 一个「把值原样写回去再读一遍」的证明，永远证明不了**字母表**。它只能证明文件可写、可读——
  这也是它字面上说的话。而字母表只在**值改变**的那一次写上有意义，所以它必须被单独测，
  且必须有一个**把类型拿掉之后两个版本都能过**的对照，否则那一节测的是它自己搭的台子。
* 一个「写之前有没有」的判据，永远证明不了**之前**——如果那个计数器**自开机**累加。
  它只能证明「在这一次开机上，有人在此之先进过」，而那个人可能是**上一个写者**。
  所以「基准干净吗」必须是**单独的一问**，而这一问的答案不在被测量的那个文件里。
