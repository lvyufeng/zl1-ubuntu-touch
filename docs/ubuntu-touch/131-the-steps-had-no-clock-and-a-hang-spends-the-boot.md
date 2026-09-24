# 131 — 每一步都没有时限，而一次挂起花掉的正是那一次"手指换来的 boot"

**日期**: 2026-09-24
**状态**: 本轮**没有碰设备**（设备仍在 Qualcomm EDL，见 §7）。这一轮修的是**代价最高、也最难看见**的一种缺陷：
`zl1-heat-fix-chain.sh` 和 `zl1-one-boot-runbook.sh` 的每一步都是一次 ssh，而**它们都没有任何时间上限**。
一个挂起的 ssh 不会失败，它会**挂住**——而这两条链要跑的场合，正是一次物理长按电源 10–20 秒换来的、
**不能重来**的 boot。发烫链 harness 159 → **192**，runbook harness 127 → **147**。

**接续**: [`124`](124-the-boot-a-finger-bought-is-one-command.md)（一次 boot 一条命令）、
[`118`](118-the-heat-fix-chain-is-one-command-on-one-boot.md)（发烫链本身）、
[`128`](128-the-chain-changed-the-heat-and-never-measured-it.md)（A/B，也就是被这次上限保住的那件测量）、
[`130`](130-the-boot-s-reading-landed-where-the-boot-s-record-does-not-point.md)（这次 boot 的读数要落在这次 boot 的记录指得到的地方）、
[`104`](104-the-camera-app-instrument-measured-in-the-wrong-unit.md)（"不可能通过的闸门"，也就是本页 §3 要避开的那个形状）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 发现了什么？ | 两条链的**每一步都是 ssh，而一步都没有时间上限**：发烫链的每一步、runbook 的每一步、A/B 那件测量、以及**读取设备状态的那一次 ssh** |
| 为什么这在这里特别严重？ | 因为这两条链**自己会重新枚举它们自己的那条链路**（发烫链第 2 步的 activate 阶段就是干这个的，`115` §4）。一个挂起的 ssh **不会失败**，它会挂住；挂住时花掉的是**一次手指换来的 boot**，而且是**无声地**花掉——没有归档、没有判定、在有人注意到之前什么可读的东西都没有 |
| 第一层修法？ | 每一步跑在 host 侧的 `timeout(1)` 下（`--step-limit`，默认 300 秒）。`124`/`137` 被单独判成**它自己的一种状态**：`DID NOT FINISH: killed at Ns (rc=124, timeout(1)) -- this is NOT a failure of the step`，并且明说这一步**可能已经写了一半**，然后照常读回设备、归档、`exit 1` |
| 那件测量呢？ | `--ab-limit`，而且**是算出来的**：`2 x --ab-window + --ab-hold + 60`。写死的上限会在有人把测量加宽的那一刻截断一次**本来合法**的长测量，而"不可能被满足的上限"正是 `104` 记过的那个形状（一个谁都过不去的闸门） |
| 那还有什么漏的？ | **read-back 也是 ssh，而且是每一条归档路径的最后一件事**（失败分支、`DID NOT FINISH` 分支、keeper 留下那一支、以及链正常跑完的那一支，四条全部）。它挂住的话，**步骤的上限就被它后面的无上限 read-back 打败了——归档永远写不出来**。所以 `--state-limit`（默认 60 秒），并且读不到时印 `UNREADABLE: ...` 而**不是什么都不印**：`INDEX.txt` 里的空值读起来是"设备被问过了、它什么也没说"，而这是 host 侧的一个超时**没法作为证据**的关于手机的断言 |
| runbook 呢？ | 同一个上限（`--step-limit`，默认 900 秒，**故意比发烫链自己的总时长宽**）。但后果**刻意不同**：发烫链的步骤是一条**许可链**（一步失败就停），runbook 的五步是**互相独立的读数**，所以一步超时**不能**让其余四步陪葬——`DID NOT FINISH` 在归档里、在总数里都**单独计数**，既不算失败也不算通过 |
| 离线怎么证明？ | 发烫链 harness：一步真的睡 5 秒配 `--step-limit 2` → 被 `timeout(1)` 杀掉、`05-retire-keeper 124`、归档里有那一行解释、**后面的步骤没有跑**；A/B 真的睡 30 秒配 `--ab-limit 2` → 状态是 `timeout` 而**不是** `failed`；`--ab-window 5 --ab-hold 7` → 印出 `bounded at 77s (2 x 5 + 7 + 60)`（断言的是**算术**不是数字）；read-back 睡 5 秒配 `--state-limit 2` → 归档照写，里面是 `UNREADABLE`。runbook harness：一步睡 5 秒配 `--step-limit 2` → `04-fingerprint 124`、**最后一步还是跑了** |
| 变异？ | 两条各一个：把步骤的上限删掉（超时的那一步被记成**成功**，那正是挂起也会留下的读数），把 read-back 的上限删掉（超时的 read-back 不再被声明成读不到）。 |
| 离线验证？ | 发烫链 harness **159 → 192 检查 / 0 失败**；runbook harness **127 → 147 / 0 失败**；家族 **19 个 harness / 2222 检查 / 全绿**，树未变 |
| 动设备了吗？ | **没有。** |

---

## 2. 缺口：一次挂起，和它花掉的东西

`step()` 原来是**逐字**这样跑起每一步的（`git show HEAD:scripts/host/zl1-heat-fix-chain.sh`）：

```sh
  "$@" > "$out" 2>&1
  local rc=$?
```

而这个文件自己的头注释**逐字**写着这一步的代价（HEAD 第 18–19 行）：

```
#   Steps 4-6 are the ones with consequences: 5 removes a process, and the recovery if 4 was wrong is a
#   finger on the power button (there is no software way back into a phone with no address).
```

——把"代价是一根手指"写下来了，却**没有给任何一步写下时限**。这一类缺陷在这个仓库里已经出现过很多次
（`96`/`99`/`110`），而这一次它在**唯一不能重来的那一次运行**上。

修法的形状是：

```sh
bound() { # SECS, command...
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout -k 5 "$secs" "$@"
  else
    printf 'NOTE: no timeout(1) on this host -- THIS STEP IS NOT TIME-BOUNDED (limit was %ss)\n' "$secs" >&2
    "$@"
  fi
}
```

`timeout(1)` 不在时**照样跑**，但把那句话说出去——因为"这一步失败"和"这一步本来可以永远挂住而没有人会发现"
是两个必须分开的事实。而在**每一步自己的文件**里说，是因为读这一步的人就在那里（runbook 那边同理）。

`124` 被单独判成一个状态，**刻意不并进失败分支**：

```sh
if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
  TIMED_OUT=1
  note "DID NOT FINISH: killed at ${STEP_LIMIT}s (rc=$rc, timeout(1)) -- this is NOT a failure of the step"
  note "and NOT a success: nothing here has read the device since it started."
  say  "  $name 正在做的事可能在设备上只做了一半……"
  read_state; archive; say "  archive: $OUT"; exit 1
fi
```

理由不是措辞：**"这一步失败了"是对手机的一个断言**（它跑了、它说了不），而"host 放弃了它"是关于
**主机**的断言——下一步该怎么走完全不同。归档里也一样：`rc` 列里的一个裸 `124` 会被读成"这一步说了 124"，
所以 `INDEX.txt` 在表格下面多了一段点名哪些步骤是 `124`/`137` 以及这两个码是什么意思。

---

## 3. 那件测量：上限必须是算出来的，不能是写死的

A/B 是这一轮**最不能被打断**的一步：它是 `128` 刚接上去的、这个链存在的理由的一半。它天然时长是
**两个采样窗口加一个 hold**，所以：

```sh
[ -n "$AB_LIMIT" ] || AB_LIMIT=$(( AB_WINDOW * 2 + AB_HOLD + 60 ))
bound "$AB_LIMIT" "${SSH[@]}" "sh /tmp/zl1-thermal.sh --ab --seconds $AB_WINDOW --hold $AB_HOLD" >> "$AB_OUT" 2>&1 &
```

写死一个数字（比如 300）会在有人 `--ab-hold 600` 的那一刻**把一次合法的长测量截断**，而那正是 `104`
记过的形状：一个谁都过不去的闸门。所以 harness 断言的是**算术**：

```sh
run "$S" --yes --ab-window 5 --ab-hold 7
want 'bounded at 77s \(2 x 5 \+ 7 \+ 60\)' "$OUT" "window 5 and hold 7 give a 77 s bound, printed as arithmetic"
notwant 'bounded at 120s' "$OUT" "not a fixed number that a wider measurement would then silently outlast"
```

而且状态是**第七种**：`timeout`。它**不能**被记成 `failed`——`failed` 读起来是"仪器跑了，它说不"，
那是对手机的一个**没有人有证据**的断言。实测：A/B 真的睡 30 秒配 `--ab-limit 2` → `INDEX.txt` 里是
`06b-heat-ab 124`，操作者读到的是

> `NOT MEASURED, and NOT a refusal by the instrument: the host gave up on it after 2s`

——"host 放弃了"和"仪器拒绝了"是两件事，而这一次是前者。

---

## 4. 一层以下：read-back 也是一条 ssh，而且是最后一条

修完步骤的上限之后，这个问题的**同一个缺陷**还在，而且更难看见：`read_state()` 也是一次 ssh，
而它是**每一条归档路径的最后一件事**——失败分支、`DID NOT FINISH` 分支、keeper 留下那一支、
链正常跑完的那一支，四条全是。它挂住的话：

* 步骤的上限**被它后面的无上限 read-back 打败**；
* 而**归档永远写不出来**——也就是这一次 boot 花掉之后**什么都没有留下**，正是这一轮要修的那个形状。

所以它也有限（`--state-limit`，默认 60 秒；它只是四个文件读和一个 `systemctl is-active`），
而且**读不到时要说出来**：

```sh
raw=$(bound "$STATE_LIMIT" "${SSH[@]}" '...')
rc=$?
if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
  FINAL_STATE="UNREADABLE: the read-back did not answer within ${STATE_LIMIT}s (timeout(1) rc=$rc, so
the ssh was killed and the device was NOT read). This is not 'the device said nothing'..."
```

两个细节是刻意的：

* **`tr -d '\r'` 挪到状态判断之后。** 原来它是管道的一部分（`... | tr -d '\r'`），`set -o pipefail`
  之下管道的最后一个命令会决定状态——`timeout(1)` 的 `124` 会被 `tr` 的 `0` 吞掉，于是"被杀掉"和
  "安静地返回空"在读数上一样。
* **`UNREADABLE` 写进 `INDEX.txt`。** 空值在那里读起来是"设备被问过了、它什么也没说"，而这个断言
  没有任何证据（脚本这一轮根本没读到设备）。这正是这一族反复记的那条：**仪器不能报告时，它得说出来**。

---

## 5. runbook：同一个上限，**不同的后果**

runbook 才是"一次 boot 一条命令"的那个东西（`124`），所以它也需要（`--step-limit`，默认 900 秒）。
默认值**故意比发烫链的整段宽**——发烫链现在自己给每一步上了限，runbook 这一层只是**兜底**，
而兜底必须比被兜的那个总时长更宽，否则它会截断一次**正在正常工作**的运行。

但后果**刻意不同**：

| | 发烫链 | runbook |
|---|---|---|
| 五/六步是什么 | 一条**许可链**（第 4 步的结论才许可第 5 步） | **五个互相独立的读数** |
| 一步超时 | **停**（后面的步骤没有它要的许可） | **继续**（后面的步骤跟它没有关系） |
| 为什么 | `118`/`120`：这些不是独立读数 | 和"一步**失败**不让其余四步陪葬"是同一条规矩（harness 第 7 节已经断言过） |

所以 `step_done()` 是**唯一**决定这一步的 rc 在记录里是什么意思的地方（五步不可能对它各说各话），
`124`/`137` 在这里进的是 `N_TIMED_OUT` 而**不是** `FAIL`，总数印成

```
one-boot runbook did not complete: 4 step(s) ran, 0 failed, 1 did not finish
```

——"一步没跑完"和"一步说不行"是两行不同的字。并且 `[ "$FAIL" = 0 ] && [ "$N_TIMED_OUT" = 0 ]` 才是
退出码的来源：这一次运行**没有**跑完，不能报 0。

**而写这个场景的时候，这两个数字还不是两件事**：五个调用点每一个都把非零 rc 记成一次失败
（它们**不可能**知道上限——判定只在 `step_done` 一个地方），于是超时的那一步被**数了两遍**，
总数印成 `1 failed, 1 did not finish`。修法是在总数那里把超时的那些从 `FAIL` 里**减去**（而不是改十个调用分支），
并且 harness 现在**钉住那一行的原文**：

```
one-boot runbook did not complete: 4 step(s) ran, 0 failed, 1 did not finish
```

——"五步里四步跑了、**没有一步失败**、一步没跑完"是一句话，"一步失败、一步没跑完"是另一句话，
而它们描述的只是**一步**。

**函数的位置也是有理由的**：上限加在 `run_bg()` **里面**、直接包住命令，而不是 `bound ... &`——
后台 pid 必须是 `timeout` 自己的 pid，因为信号处理器杀的正是那个 pid；包一层函数的话，
`sleep 1; kill -9` 杀的是那层壳，`timeout` 和它对设备的调用会变成孤儿，
而**中断路径会报告"已经停了"与此同时那一步还在跑**。

---

## 6. 这一轮**不**证明什么

* **不证明 300 秒（或 900 秒）是对的。** 它证明的是"有一个上限，而且撞上它的时候会说出来"。
  这两个数字是**判断**，不是测量；真正的入口是 `--step-limit`。
* **不证明超时的那一步在设备上是安全的。** 恰恰相反：`DID NOT FINISH` 的措辞就是"它可能已经写了一半"。
  这一轮**降低了**"无声地花掉一次 boot"的概率，**没有**让半途的写入变得安全——那是每一步自己的 installer
  的读回该管的事。
* **不证明家族里其它 17 个 harness 有上限。** 这一轮是**手工**把"会跑 ssh 的脚本"扫了一遍
  （家族 runner 的 `--timeout 900` 只保护**跑测试**这件事，不保护被测对象）。那两个真正会在
  **一次不能重来的 boot** 上跑的脚本现在有了；其余的是**人工扫过一遍**，那不是机制——
  `129` §6 记过同一句话，这一页再记一次，因为这一轮的离线证据只覆盖这两个。
* **不证明 `timeout(1)` 到处都在。** 不在的时候代码会**说出来**（runbook harness 里那第二个 sandbox
  就是为了让这条分支成为一个场景，而不是一个意外），但"有 `timeout(1)`"这件事本身没有被保证。
* **不证明上限能管住读取端。** 实测到的一件事值得记下来：`timeout` 在这里**不杀进程组**——
  `out=$(timeout -k 5 1 sh -c 'sleep 20 & echo hi')` 实测**要等满 20 秒**，因为那个孤儿 `sleep`
  还握着 stdout 这根管道，而 `$( )` 要等管道关闭。**对子进程的上限不是对这次读取的上限。**
  真的 ssh 是一个进程、被杀掉之后管道就关了，所以这是夹具的危害而不是被测对象的——夹具里那个
  会睡着的 ssh 替身因此把 `sleep` 的 stdout 重定向掉了。（记在这里，因为下一次有人拿 `timeout`
  包住一个会留下孩子的命令时会再遇到它。）
* **不证明这两条链在设备上跑得通。** 整轮没有一次 ssh。

---

## 7. 设备状态与复现

整轮没有动设备：没有写任何分区或 boot，没有跑 QDL/QFIL，没有重启。设备仍在 **Qualcomm EDL**
（`05c6:9008`，port 3-3，无序列号）。识别目标一律按序列号 **`33e80afe`**；总线上另一台小米
**`4a2fe00b`** 必须忽略。恢复仍然只能靠**物理长按电源 10–20 秒**。

```sh
# 全部在宿主机上，不碰设备。
bash scripts/host/zl1-heat-fix-chain-selftest.sh      # 192 项
bash scripts/host/zl1-one-boot-runbook-selftest.sh    # 147 项
bash scripts/host/zl1-selftest-family.sh              # 19 个 harness / 2222 检查

# 这一轮的核心读数：上限是算出来的，而且印出来。
bash scripts/host/zl1-heat-fix-chain.sh --help | grep -A2 -- '--ab-limit'
bash scripts/host/zl1-heat-fix-chain-selftest.sh | sed -n '/== 7b/,/== 8/p'

# 变异自己会不会红：
bash scripts/host/zl1-heat-fix-chain-selftest.sh | sed -n '/mutation .stepbound/,+4p'
bash scripts/host/zl1-one-boot-runbook-selftest.sh | sed -n '/mutation .notimeout/,+4p'
```

| 文件 | 作用 |
|---|---|
| `scripts/host/zl1-heat-fix-chain.sh` | 改：`bound()`；`--step-limit`（300）/ `--ab-limit`（算出来的）/ `--state-limit`（60）；`step()` 把 124/137 判成 `DID NOT FINISH` 并读回+归档+`exit 1`；A/B 走 `bound` 且 `AB_STATE` 增加 `timeout`；`ab_start` 的 scp 也有上限并把 rc 印进归档；`read_state` 有上限，读不到时写 `UNREADABLE`；`archive()` 增加 `# DID NOT FINISH:` 那段 |
| `scripts/host/zl1-heat-fix-chain-selftest.sh` | 改：第 5b 节新增 A/B 超时、scp 的 rc、**上限的算术**三个场景；第 7 节新增步骤超时与 read-back 超时两个场景；第 9 节新增两个变异；替身的 ssh 增加 `FP_SLEEP_AB`/`FP_SLEEP_STATE`、scp 增加 `FP_RC_SCP` |
| `scripts/host/zl1-one-boot-runbook.sh` | 改：`--step-limit`（900）；`run_bg()` 用 `timeout` 包住命令（pid 必须是 timeout 的）；`step_done()` 单点判定 124/137 → `N_TIMED_OUT` + 归档里点名的 `# DID NOT FINISH:` 段；总数把超时的那些从 `FAIL` 里减去（调用点不可能知道上限），退出码把"没跑完"和"失败"分开 |
| `scripts/host/zl1-one-boot-runbook-selftest.sh` | 改：新第 7b 节（步骤超时仍继续、总数分开计、read-back 那一支在**没有 `timeout(1)` 的 sandbox** 里仍要说出来）；sandbox 增加 `timeout`（否则这个特性在整份 harness 里**隐形**），并新增一个**没有** `timeout` 的 sandbox；第 10b 节新增变异（把上限删掉，超时的那一步就成了"成功"）；总数那一行的原文被钉住（同一步不能被记两次） |
| `scripts/host/zl1-health-check.sh` | 改：发烫链的引用 159 → 192、runbook harness 127 → 147，并补上两段说明（每一步的时限、以及 read-back 为什么也要有） |
| `scripts/README.md` | 改：发烫链行的旗标与"每一步都有时限"一段、七种状态、192；runbook 行的 `--step-limit` 与后果不同的一段；两个 harness 行的检查数与新场景；变异数 10 → 12 |
| `docs/ubuntu-touch/131-*.md` | 本篇 |
