# 133 — 主机的自检只回答了第 03 步，而这一步之外的四步一个都没有

**日期**: 2026-09-24
**状态**: 本轮**没有碰设备**（设备仍在 Qualcomm EDL，见 §7）。上一轮（[`132`](132-the-bound-was-on-the-steps-and-not-on-the-calls-between-them.md)）
给 runbook 的每一个**调用**都上了时限；这一轮改的是**同一条命令的另一半**：它开始之前对**这台机器**
提的那个问题。那个问题原来是关于**一个步骤**的，而它的论证适用于**这一次运行要走的每一步**——
包括第 03 步自己**身体里**驱动的那些、runbook 从来没有看过一眼的脚本。runbook harness 177 → **208**。

**接续**: [`132`](132-the-bound-was-on-the-steps-and-not-on-the-calls-between-them.md)（不是步骤的那些调用）、
[`127`](127-the-host-can-also-be-the-thing-that-is-missing.md)（主机自己也可以是缺的那件东西）、
[`118`](118-the-heat-fix-chain-is-one-command-on-one-boot.md)（发烫链，以及第 4 步的那份许可）、
[`126`](126-the-path-was-decided-by-what-the-stub-omits.md)（第二份会被复制、然后会过期的策略）、
[`130`](130-the-boot-s-reading-landed-where-the-boot-s-record-does-not-point.md)（这一次 boot 的读数要落在这一次 boot 的记录指得到的地方）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 发现了什么？ | runbook 跑之前的主机自检（`host_for_step03()`）**只回答第 03 步**：misc 备份在不在、校验对不对、netwatch 构建里有没有 `ensure_addrs()`。它甚至**只在 `if wanted 03-heat-chain` 成立时才跑** |
| 为什么这不够？ | 因为**它的论证**——"这台机器上少一个文件，代价是那一次 boot，而 boot 是唯一不能重跑的东西"——对五步**同样成立**。01/02/04/05 各自要的那个脚本也都在这台机器上，而它们在原来那份检查里**一个都没有** |
| 而第 03 步还有一层？ | 有：**它自己的身体还会驱动四个 runbook 从未看过的脚本**（`install-retire-debug-keeper.sh`、`install-cpufreq-governor.sh`、`device/zl1-address-owner-proof.sh`、`device/zl1-thermal.sh`）。一个缺失的 01 会在 01 被发现，一个缺失的 05 会在 05 被发现，**而一个缺失的测量仪器在任何一步都不会被发现**——链会降级成 `unusable`、把这句话写进归档，然后这一次 boot 以"没有测量、也没有第二次机会"结束 |
| 修法的**形状**是什么？ | 不是把那张清单从一步抄成五步，而是**两种缺失分开**：**缺脚本 = 拒绝**（拒绝不花任何东西，半花的 boot 花掉一根手指）；**缺仪器 = 警告**（在这里拒绝，是为了保护一个**比拒绝本身造成的损失更小**的损失，把整套发烫修复——两个本来能装上的 installer 加 keeper 的击杀——全部扔掉。这就是 `118` 第 4 步的许可换了一个文件） |
| 哪一种是哪一种由谁决定？ | **从发烫链里读出来**，不在 runbook 里再决定一次：链自己那五行 `NW/RETIRE/CPUFREQ/PROOF/THERMAL="$HERE/…"` 和它自己的 `for f in "$NW" "$RETIRE" "$CPUFREQ" "$PROOF"; do [ -r "$f" ] \|\| exit 2` 循环，**在循环里的就是它要拒绝的，不在的就是它要降级的**。抄一份到这里就是第二份会过期的策略（`126`） |
| 读不出来怎么办？ | **UNUSABLE**——不是通过，也不是拒绝。提取器什么都没匹配到时两边都是空的，而"没有要检查的东西"读起来和"东西都在"**一模一样**（一个不可能失败的检查）。所以此时把话说出来：`NOTE: part of the host check could not be made -- this run is NOT verified against it:` |
| 被跳过的步骤呢？ | **不检查**。这一次运行不会走的步骤不可能失败，而在它身上拒绝会让 `--skip`/`--only` 在**恰恰是唯一出路的那台主机**上失效 |
| 路径按谁的目录解析？ | 按**链自己的**目录（`CHAIN_DIR` + `_abs`），不是 runbook 的。真树里两者**是同一个目录**，所以用错的那个在那里**碰巧永远是对的**——这正是"夹具必须把两者分开放"存在的理由（第一版就是这么错的，为一个本来就在的文件、在隔壁目录里拒绝了） |
| 离线怎么证明？ | 第 9c 节：五条场景（脚本没了、被跳过的步骤不能失败、链自己的脚本没了、仪器没了、检查做不成）+ 两个变异（把仪器变成拒绝、让"做不成"闭嘴） |
| 那两个变异第一次是怎么失败地通过的？ | 两个都**什么都没证明**：一个去改了 `bad=`（调用方从不看它，HARD/SOFT 是**印出来的前缀**，所以那个变异体 exit 0 并把发烫修复装上了），一个去改了提取器（空的提取**照样**会走到 UNUSABLE 分支并照样印出来）。改的是**被观察的那句话**之后，两个才真的变红 |
| 离线验证？ | runbook harness 177 → **208 检查 / 0 失败**；家族 **19 个 harness / 2283 检查 / 全绿**，树未变 |
| 动设备了吗？ | **没有。** |

---

## 2. 缺口：那个论证是关于"一台主机"的，检查却是关于"一个步骤"的

`127` 的修法是：runbook 在**第 01 步之前**检查主机，因为"在这台机器上少一个文件"的代价是那一次 boot。
但那一次修的是**第 03 步的**三个条件（misc 备份非空、SHA256 还对、netwatch 构建里带 `ensure_addrs()`），
代码逐字是这样收尾的（`git show HEAD:scripts/host/zl1-one-boot-runbook.sh`；`…` 那一行是本页的省略，
不是脚本里的内容）：

```sh
if wanted 03-heat-chain; then
  HOST_BAD=$(host_for_step03) || { … exit 2; }
  say "-- host check: step 03's preconditions hold (misc backup verifies, the build carries ensure_addrs())"
fi
```

一个**步骤名写在函数名里**的检查，和一个**只在那个步骤会被走时才跑**的检查。而它要防的那件事
对其它四步没有任何不同：

| 步骤 | 它要的主机文件 | 原来在哪里才会被发现 |
|---|---|---|
| 01 capture | `scripts/device/zl1-post-recovery-capture.sh` | 在 01 |
| 02 panic guard | `scripts/install-no-edl-on-panic.sh` | 在 02 |
| 03 heat chain | `scripts/host/zl1-heat-fix-chain.sh` **及其四个被驱动的脚本** | 在 03（只检查了三个**条件**，没检查那四个文件） |
| 04 fingerprint | `scripts/install-fingerprint-store-dir.sh` | 在 04 |
| 05 trial | `scripts/device/zl1-lpm-ladder-trial.sh` | 在 05 |

"在 01 被发现"的意思是：01 之前的每一件事都已经花掉了——**包括那次长按电源换来的 boot 里，
用它做的每一件事**。而这五步里最糟的一个不在表里：

```
THERMAL="$HERE/../device/zl1-thermal.sh"      # 第 03 步身体里驱动的第五个脚本，不在链的拒绝循环里
```

它不在 `for f in "$NW" "$RETIRE" "$CPUFREQ" "$PROOF"` 里，因为链**不需要它也能跑完**：它只是
A/B 那件测量的仪器（`128`），缺了它，链会把它自己报告成 `unusable`、照常装两个修复、照常击杀 keeper，
然后这一次 boot 的**测量**就没了。这是**在任何一步都不会被发现的缺失**，而它与"少一个脚本"的后果
完全不同：前者让一个步骤不能开始，后者让一次已经开始的运行失去它存在的理由的一半。

---

## 3. 修法：两种缺失，两种后果，而"哪一种"是读出来的

新的 `host_ready()` 对**这一次运行会走的每一步**回答同一个问题，并且把答案分成**带前缀的两类**——
前缀不是装饰，**调用方 switch 的正是它**：

```sh
# (a) 每一步自己的脚本。跳过的步骤不查：这次运行不会走的步骤不可能失败。
[ -r "$path" ] || { echo "HARD $step cannot start: its own script is not readable: $path"; bad=1; }
...
# (b) 第 03 步身体里要驱动的东西，从链里读出来。
if ! printf '%s\n' "$CHAIN_HARD" | grep -qw "$name"; then
  # 链没有它也能跑——它在归档里说明，而不是在这里拒绝。
  [ -r "$path" ] || echo "SOFT 03-heat-chain will run but its MEASUREMENT WILL NOT: $name ($path) is not readable,
    so the chain will report the A/B as unusable -- the two heat fixes still install"
  continue
fi
[ -r "$path" ] || { echo "HARD 03-heat-chain cannot start: $name is not readable: $path"; bad=1; }
```

（第二段里的换行是本页的排版；脚本里是一行。）

两类都被断言**从两边**：`SOFT` 那一边由变异证明"把它当成拒绝，这次 boot 的整套发烫修复就没了"，
`HARD` 那一边由场景证明"缺一个脚本 → exit 2，而且**一步都没有跑**，连脚本都好的那四步也没有"。

而**哪一种是哪一种**是读出来的，两行 `sed`：

```sh
CHAIN_CALLEES=$(sed -n 's|^\([A-Z_][A-Z_0-9]*\)="\$HERE/\(.*\)"$|\1 \2|p' "$HEAT")
CHAIN_HARD=$(sed -n '/^for f in /{s/^for f in //; s/; do.*//; s/"//g; s/\$//g; p; q;}' "$HEAT")
```

这两行是**发烫链自己的策略**，不是这一页对它的复述。理由和 `126` 里那句一样：
把策略抄一份过来，就有第二份会在链改掉它的那一天**过期**的东西，而过期的形式是"runbook 拒绝，
链本来会跑"或者更糟的"runbook 放行，链在设备上拒绝"。

**读不出来时不通过。** 提取器什么都没匹配到时两边都是空的，而这时"没有要检查的东西"读起来和
"东西都在"一模一样。所以它与两类是**分开的第三种**：

```
NOTE: part of the host check could not be made -- this run is NOT verified against it:
  * the heat chain's callees could not be read out of .../zl1-heat-fix-chain.sh, so whether step 03 can
    start is UNKNOWN (not a pass)
```

它既**不拒绝**（链的形状变化不是 operator 的错，而且这一步可能完全没问题）也**不通过**
（"我没看懂"不是"我检查过了"），而是说清楚这次运行**没有**被验证过，然后照常走。

---

## 4. 一个"只在真树里碰巧正确"的路径

链把自己的脚本写成 `$HERE/../install-*.sh`，而这里的 `$HERE` 是**链所在目录**——
在真树里，链和 runbook 在同一个目录（`scripts/host/`），所以拿 **runbook 的** `$HERE` 去解析
`$HERE/../install-retire-debug-keeper.sh` **结果是对的**。这正是"碰巧正确"：它在一棵树里对，
在一棵把两者**分开放**的树里错，而没有任何一个真树的运行能把这两者区分开。

夹具把这层窗纸捅破了：第一版按 runbook 的目录解析，于是在自己造出来的树里为一个**本来就在**
的文件、在**隔壁目录**里拒绝了。修法两行：

```sh
CHAIN_DIR=$(dirname "$HEAT")
path=$(_abs "$CHAIN_DIR/$(printf '%s' "$rel")")
```

`_abs()` 只是把 `..` 消掉——一条凌晨两点被人读的消息不该让人在脑子里做路径规范化，
而断言路径的检查应该断言那个**文件**，不是走到它的那段路。

---

## 5. 离线证据：五条场景，和两个"第一次什么都没证明"的变异

第 9c 节按"两种缺失"的顺序过一遍：

| 场景 | 断言 |
|---|---|
| 某一步**自己的脚本**没了 | exit 2、点名那一步、说 `REFUSING, before anything ran`、**一步都没跑**（连脚本都好的四步也没有）、`--status` 说同一句话 |
| 那一步**被 `--skip` 掉了** | 不为它拒绝、不声称主机坏了，而**该跑的步骤照跑**（`--skip 05-trial` 和 `--only 01-capture` 各一次） |
| 第 03 步**身体里**的脚本没了 | exit 2、点名链自己的变量名（`RETIRE`）和链解析出的路径，而且**不是** runbook 目录那一条 |
| **仪器**没了 | **不拒绝**（`the run PROCEEDS … a missing instrument is not a reason to lose the heat fix`）、印 `WARNING: the run will proceed`、说清丢的是什么（`its MEASUREMENT WILL NOT`）和链会写成什么（`the A/B as unusable`），**链照常被调用**；仪器放回去之后再问一次，警告消失——所以那是一句读数，不是一段固定的字 |
| 链的形状**读不出来** | 不拒绝、也不通过，印 `could not be made -- this run is NOT verified against it` 和"读不出来的是什么"；`--status` 在同样的话里说 `which is NOT a pass` |

两个变异各证明一类**做错的方向**：

| 变异 | 第一次为什么什么都没证明 | 改对之后的读数 |
|---|---|---|
| 把缺仪器变成**拒绝** | 它改的是 `bad=`，而调用方从不看 `bad`——HARD/SOFT 是**印出来的前缀**。实测：那个变异体 exit 0，**照样把发烫修复装上了** | 变异体现在 exit 2，而且链**从未被调用**（`CALLEE HEAT` 在动作记录里不出现）——整套发烫修复为了一个测量工具被扔掉 |
| 让"做不成"这句话**闭嘴** | 它改的是提取器，而空提取**照样**会走到 UNUSABLE 分支、照样把话说出来。实测：那个变异体报告那个洞的方式和被测对象一模一样 | 现在改的是那句话本身：此时一台**从未被验证过**的主机报告自己 ready |

这两个"第一次"是同一类错误的两个样本，值得单独记一句：**改动一个内部变量，证明不了任何事情**，
除非你说得出**谁在观察它**。`132` 里那条"一个永不返回的替身证明不了上限"是同一件事的另一种写法。

---

## 6. 这一轮**不**证明什么

* **不证明那张清单是完整的。** 它证明的是"这一次运行会走的每一步，它自己的脚本，以及第 03 步
  按**链的策略**要拒绝或降级的那些文件"。链的**内部**还有别的东西（它 ssh 过去的设备、
  它在设备上跑的 `/tmp/zl1-thermal.sh` 的**存在性**是设备侧的事实）——那不在主机自检的射程里。
* **不证明 `--status` 和 `--yes` 用的是同一份判断的两次运行。** 两者调用的是同一个
  `host_ready()`，但没有任何东西**断言**这一点以外的等价（比如两次之间主机状态变了，读数当然会变）。
* **不证明其它 18 个 harness 的主机检查。** 这一轮是**一个脚本的一个函数**；别的脚本
  有没有"只检查第一步"的形状，没有被扫过。
* **不证明这几类缺失在设备上会以同样的方式发生。** 缺文件是**主机侧**的故障模式，
  而设备侧的对应物（链在设备上发现 `/tmp/zl1-thermal.sh` 不在）走的是链自己的分支，这一轮没动。
* **不证明家族一直全绿——这一轮的家族跑里遇到过一次闪烁失败，而且它是真的。**
  在一次家族运行里 `zl1-lpm-ladder-trial-selftest.sh` 报了一次 `FAIL`，而被它断言的那段文字
  **当时就在文件里**（`$(cat "$SRC")` 的内容完整：36615 字节、647 行，同一段内容当场重跑
  `grep -Eq` 返回 0）。把它钉住之后读数只有一个：**管道里的写端死于 SIGPIPE，而 `set -o pipefail`
  把这个死亡当成了这次检查的结果**——实测 `PIPESTATUS` 是 `printf=141 grep=0`，100 次运行里红了 4 次。
  这个形状（`printf … | grep -q …` 当作判定）在 13 个 harness 的 `want`/`notwant` 里都有，
  其中 **6 个设了 `pipefail`**；构造一个**大于管道容量**的载荷（2 MB）并让匹配落在第一行时，
  旧形状 **200/200 全部假失败**，而把干草堆直接交给 grep（不经过进程）是 **0/200**。
  它和这一轮改的文件没有任何关系（那个 harness 和它断言的那个脚本这一轮都没有被碰过），
  但它是**真的**，修在下一轮。
* **不证明这两条链在设备上跑得通。** 整轮没有一次 ssh。

---

## 7. 设备状态与复现

整轮没有动设备：没有写任何分区或 boot，没有跑 QDL/QFIL，没有重启。设备仍在 **Qualcomm EDL**
（`05c6:9008`，port 3-3，无序列号）。识别目标一律按序列号 **`33e80afe`**；总线上另一台小米
**`4a2fe00b`** 必须忽略。恢复仍然只能靠**物理长按电源 10–20 秒**。

```sh
# 全部在宿主机上，不碰设备。
bash scripts/host/zl1-one-boot-runbook-selftest.sh    # 208 项
bash scripts/host/zl1-selftest-family.sh              # 19 个 harness / 2283 检查

# 这一轮的核心：两种缺失，两种后果。
bash scripts/host/zl1-one-boot-runbook-selftest.sh | sed -n '/== 9c/,/== 10\./p'

# 两个变异自己会不会红：
bash scripts/host/zl1-one-boot-runbook-selftest.sh | sed -n '/mutation .the instrument made a refusal/,+3p'

# 那个闪烁失败的唯一读数（写端，不是读端）：
bash scripts/host/zl1-one-boot-runbook-selftest.sh >/dev/null; echo $?   # 与本页 §6 无关，见下一轮
```

| 文件 | 作用 |
|---|---|
| `scripts/host/zl1-one-boot-runbook.sh` | 改：`host_for_step03()` 之外增加 `host_ready()`（整条序列 + 链的 callees，HARD/SOFT/UNUSABLE 三类，前缀即分类）；`CHAIN_CALLEES`/`CHAIN_HARD` 两行 `sed` 把链的策略**读出来**；`_abs()` 与 `CHAIN_DIR`（按**链的**目录解析）；`--status` 与运行前的块按三类分别处理（拒绝 / 说清洞 / 警告后继续），并都印 `-- host check: every step this run takes can start from this machine` |
| `scripts/host/zl1-one-boot-runbook-selftest.sh` | 改：新第 9c 节（五条场景，含"跳过的步骤不能失败"和"按链的目录解析"）；第 10b 节增加两个变异（`hardinstrument`、`nocallees`），并记下它们第一版为什么什么都没证明 |
| `scripts/host/zl1-health-check.sh` | 改：runbook harness 的引用 177 → 208，并补上整条序列的主机自检、两种缺失的分野、"读出来而不是抄一份"和那个被分开的夹具目录 |
| `scripts/README.md` | 改：runbook 行的"HOST 检查覆盖整条序列"一段与 HARD/SOFT 的理由；harness 行 177 → 208、变异 4 → 6 |
| `docs/ubuntu-touch/133-*.md` | 本篇 |
