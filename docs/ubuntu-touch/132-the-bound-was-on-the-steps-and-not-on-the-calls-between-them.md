# 132 — 上一步给"步骤"上了时限，而两次步骤**之间**的 ssh 没有

**日期**: 2026-09-24
**状态**: 本轮**没有碰设备**（设备仍在 Qualcomm EDL，见 §7）。这一轮是[上一轮](131-the-steps-had-no-clock-and-a-hang-spends-the-boot.md)的**下一层**：
上一轮给 `zl1-one-boot-runbook.sh` 的**每一步**加了时限（`run_bg` 里的 `timeout`），
而 runbook 还做了**四次不进 `run_bg` 的直接 ssh**——**其中两次的输出不是写进文件，而是进了一个 `case`，
变成对手机的判定**。runbook harness 147 → **177**。

**接续**: [`131`](131-the-steps-had-no-clock-and-a-hang-spends-the-boot.md)（步骤的时限、read-back 的时限）、
[`124`](124-the-boot-a-finger-bought-is-one-command.md)（一次 boot 一条命令）、
[`127`](127-the-host-can-also-be-the-thing-that-is-missing.md)（主机自己也可以是缺的那件东西）、
[`125`](125-the-device-read-those-four-things-already.md)（那两个读数的形状）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 发现了什么？ | runbook 有**四次直接 ssh**不在 `run_bg` 里，因此**一次都没有被上一轮的上限覆盖**：可达性探测、`boot_id` 的读取、以及**决定 A 和 C 的那两次读数** |
| 为什么这比步骤更糟？ | 因为步骤的输出写进**文件**，而这四次的输出进的是 `case`——**它把读数变成对手机的判定**。一次 host 侧超时到达那里时是个**空字符串**，于是被印成 `A is treated as NOT met` 和 `C is NOT met (step 03 retires it)` |
| 第二句为什么危险？ | 它**邀请人去重跑第 03 步**（"the cause is 03"）——而第 03 步可能**本来就已经成功了**。也就是说：一个**根本没发生过的读数**，被当成"那一步白做了"的证据，而重跑它花的是一次 boot |
| 修法？ | 第四次读数的**第四个 token**：`TIMEOUT`。前三个 token（`all=0` / `ARMED` / `NOT-FOUND`）**都是对手机的断言**，"host 在 60 秒时杀掉了 ssh"不是——所以它得有自己的名字，和 `131` §4 里 read-back 的 `UNREADABLE` 是同一条规矩 |
| 怎么修**整个类**？ | 所有直接 ssh 走**一个** `devssh()` 包装（`bound "$STATE_LIMIT" "${SSH[@]}"`），并且 harness 把这条**不变量本身**钉住：`${SSH[@]}` 在整个脚本里**只允许出现两处**（一处是 `devssh` 的定义，一处是交给 `run_bg` 的那次），把这两处减掉之后**必须什么都不剩** |
| 为什么"减掉之后必须什么都不剩"而不是数个数？ | 因为**数字对而位置错**的文件能通过数数——计数不是约束，幸存集合为空才是。这一条是在**scratch 副本**上演示过的（`131`/`128` 的规矩：证明检查会红，不能拿真文件做实验） |
| 那个探测呢？ | 它现在区分"连不上"和"**host 自己放弃了**"，并且后者会点名**那个不需要按键的修复**（`zl1-rndis-recover.sh`）：链路停止承载 ≠ 手机死了 |
| `boot_id` 呢？ | 读不到时不再印 `unknown-<timestamp>`——那读起来像一个"没人能匹配上的 boot id"；现在写明白是"host 放弃了"还是"答了个空的" |
| 离线怎么证明？ | 夹具的 ssh 替身多了 `FP_SSH_HANG_ON`：**不是失败，是永不作答**（挂起没有退出码，那正是所有上限存在的形状）。四条场景 + 两个变异 |
| 那个变异怎么断言"挂起"？ | 用一个**从不作答**的设备跑被测对象：有上限时它**回来**（exit 2），把上限从 `devssh` 删掉之后它**挂住**，直到 harness 自己的 `kill` 把它结束（`rc=124`）——"没有回来"就是可观测的差异 |
| 离线验证？ | runbook harness 147 → **177 检查 / 0 失败**；家族 **19 个 harness / 2252 检查 / 全绿**，树未变 |
| 动设备了吗？ | **没有。** |

---

## 2. 缺口：上一轮修的是步骤，而步骤之间还有东西

`131` 给 runbook 的每一步加了 `timeout`（在 `run_bg` 里）。而 runbook 自己还做这些调用：

```sh
"${SSH[@]}" true                              # 可达性探测
BOOT_ID=$("${SSH[@]}" 'cat .../boot_id' ...)   # 这一次 boot 的身份证
DM=$(read_download_mode)                       # A 的读数
KP=$(read_keeper)                              # C 的读数
```

四次，**一次都不进 `run_bg`**。而可达性探测在最前面——它挂住的话，**什么都没有归档，连一行判定都没有**。

但这四次里真正危险的是**后两次**，理由和前面三次不一样：

| | 输出去哪里 |
|---|---|
| 步骤（`run_bg`） | `$OUT/<step>.txt`，一个**文件** |
| 可达性探测 / boot_id | 一行文字 |
| **A 和 C 的读数** | **一个 `case`——它把字符串变成对手机的判定** |

而那个 `case` 在**空字符串**上的行为是：

```
A. download_mode:    <- the reading is not a shape this script knows, so A is treated as NOT met
C. debug keeper:     <- a CPU that is never idle does not enter a deep idle state, so C is NOT met (step 03 retires it)
```

第一句是"没读成"，读起来像"读了但不是这个形状"；**第二句更糟**——它说"所以是第 03 步没做对"，
而第 03 步可能**已经做对了**。一个 host 侧的超时，被转成"去重跑那一步"的指令，
而重跑它要花的正是这一次 boot。`131` §4 在发烫链的 read-back 上写过同一句话：
**空值不能被读成"设备说了什么"**；这里它更进一步——**空值变成了对设备的判决**。

---

## 3. 修法：第四个 token，和一个包装

修法是给读数加一个**它自己的形状**：

```sh
read_download_mode() {
  local raw rc
  raw=$(devssh '...'); rc=$?
  # "不是 0"和"没找到"都是读数；"host 在 60 秒时杀了 ssh"不是。
  # 没有这个 token 时它以**空字符串**到达下面的判定，落进最后一个分支，
  # 被印成 "A is treated as NOT met"——一个 host 侧的超时，当成设备判定印出去。
  gave_up "$rc" && { printf 'TIMEOUT'; return 0; }
  printf '%s' "$raw" | tr -d '\r\n'
}
```

于是那个 `case` 多出一条**在 `*` 之前**的分支——位置重要，因为 `*` 是"其余一切"，
而 `none*` 是**唯一**说 C 成立的分支：

```
A. download_mode: NOT READ -- the host gave up on the ssh at 60s, so this says NOTHING about the phone:
   the parameter may read 0 and it may not. ... the thing to fix is the LINK, not the driver: docs 76.
C. debug keeper: NOT READ -- ... This is not 'no keeper': nothing here says whether one is running,
   and step 03 may well have worked.
```

`A_AFTER` / `C_AFTER` 那一对（步骤之后的那次读）有同样的两个分支，说"**这是关于这台机器的
事实，不是一次读数**，所以它在任何方向上都不是关于 A 的证据；第 05 步会因此拒绝，该修的是链路（`76`），不是 02"。

**整个类**的修法是一个包装：

```sh
devssh() { bound "$STATE_LIMIT" "${SSH[@]}" "$@"; }
```

`--state-limit` 默认 60 秒，和发烫链里同一个名字、同一个职务。`bound()` 与 `run_bg` 里那个
**内联的 `timeout`** 刻意分开，并且理由写在代码里：被后台化的 `bound` 会让**后台 pid 变成子 shell 的**，
而信号处理器杀的正是那个 pid——于是中断会报告"已经停了"与此同时那一步还在跑。

---

## 4. 不变量：钉住"只有两处"，而不是"我记得只有两处"

`131` §6 自己承认过：**"其余是人工扫过一遍，那不是机制"**。这一轮把它兑现，而且用的是**不变量**
而不是清单——因为清单会过期（`110` 的那一族）：

```sh
SSHSITES=$(grep -n '\${SSH\[@\]}' "$SRC")
NSITES=$(printf '%s\n' "$SSHSITES" | grep -c . )
[ "$NSITES" = 2 ] && ok "the subject uses \${SSH[@]} in exactly 2 places, both of them bounded"
LEFT=$(grep -n '\${SSH\[@\]}' "$SRC" | grep -vE 'devssh\(\)|run_bg "\$\{SSH' || true)
[ -z "$LEFT" ] && ok "and with those two removed, no \${SSH[@]} call site is left unbounded"
```

**第二句才是约束**：数字对而位置错的文件能通过数数。两句都在，是因为它们回答的问题不同——
"数量对不对"和"剩下的那些是什么"。

这个"幸存集合为空"的检查是**在 scratch 副本上**演示过的（把被测对象复制到 `/tmp`，
加一行 `"${SSH[@]}" true`，看它被抓住）——**证明检查会红，不能拿真文件做实验**，这是 `128` §9c 的规矩。

---

## 5. 用挂起证明上限：一个没有退出码的形状

上限怎么"离线证明"？一个正常返回的替身**证明不了**——上限只在"不返回"时才起作用。
所以夹具的 ssh 替身多了一个钩子：

```sh
# FP_SSH_HANG_ON: NEVER ANSWER. Not "fail" -- hang, which is the whole point: a stalled link does not
# return a non-zero code, it holds the session open, and every bound this project has added exists for
# that shape and no other.
if [ -n "\${FP_SSH_HANG_ON:-}" ]; then
  case "\$cmd" in *"\$FP_SSH_HANG_ON"*) exec sleep 600 ;; esac
fi
```

（`exec` 不是修饰：它让**替身进程本身**变成那个 `sleep`，于是 `timeout` 杀掉的就是它。
否则一个孤儿 `sleep` 会继续握着 stdout，`$( )` 会等到它结束为止——`131` §6 记过这件事，
那一次是实测出来的：`timeout -k 5 1 sh -c 'sleep 20 & echo hi'` **等满 20 秒**。）

四条场景，全部走这条路：

| 场景 | 断言 |
|---|---|
| 在**第一次**调用就挂住 | 运行**回来**（exit 2）、说明是 host 自己的上限结束了它、明说这是**关于主机**的事实、点名 `zl1-rndis-recover.sh`、并且**什么都没跑** |
| `--status` 里 A 的读数挂住 | `A. download_mode: NOT READ`、印出被撞上的那个上限、**不是** `A is treated as NOT met`、**更不是** `ARMED`（那会是编出来的） |
| `--status` 里 C 的读数挂住 | `C. debug keeper: NOT READ`、并且说"第 03 步可能本来就已经成功了"、**不是** `C is NOT met` |
| `--yes` 之后的那次读 | 归档里写 `A: NOT READ` 和"关于这台机器的事实，不是一次读数"；而**答了**的那次 `boot_id` 以真值进归档 |

两个变异：

| 变异 | 结果 |
|---|---|
| 从 `devssh` 删掉上限 | 运行**挂住**，只有 harness 自己的 `kill` 能结束它（`rc=124`）——也就是"有上限就回来、没有就不回来"这个**唯一**可观测的差异 |
| 删掉 `gave_up` 那个 token | 运行**仍然回来**（上限本身没动），但 A 又被印成 `A is treated as NOT met`，而且**没有任何地方说手机根本没被读到** |

---

## 6. 这一轮**不**证明什么

* **不证明 60 秒是对的。** 它证明的是"有一个上限，撞上它会说出来"，和 `131` 一样。
  三个读数都是四个文件读加一次 `systemctl is-active`，60 秒是**判断**；入口是 `--state-limit`。
* **不证明四次就是全部。** 它证明的是**这一个脚本**里 `${SSH[@]}` 只出现在两处。
  别的脚本（`zl1-post-recovery-capture.sh` 把每一步的时限放在**设备侧**的 `timeout` 上、
  三个 installer、`zl1-health-check.sh` 自己的 `ping`/ssh）**没有**被这一轮的检查覆盖——
  这一轮的机制是**一个文件一条不变量**，不是全树扫描。**发烫链那边同理**：它把每一步、
  A/B、scp、read-back 都包在 `bound` 里，但**没有**同样的"调用点计数"检查
  （它的调用点更多、形状各异，一个全局不变量在那里会是一句空话）。这是**已知的边界**，写在页面上。
* **不证明 `devssh` 的包法在别处也合适。** 它是一次同步调用一个上限；runbook 里唯一
  需要**后台 pid**的地方（步骤、试验）走的是 `run_bg` 的内联 `timeout`，两处形状不同是有理由的
  （§3 末），而这个理由本身没有被断言——它是一段注释。
* **不证明 `TIMEOUT` 覆盖了所有"没读成"的形状。** 它覆盖的是**host 自己放弃**这一种。
  连接被拒、`ConnectTimeout` 到点、设备返回非零——那些走到了 `UNREADABLE` 或别的分支，
  那是 `125` 以来就有的行为，这一轮没有动它们。
* **不证明这两条链在设备上跑得通。** 整轮没有一次 ssh。

---

## 7. 设备状态与复现

整轮没有动设备：没有写任何分区或 boot，没有跑 QDL/QFIL，没有重启。设备仍在 **Qualcomm EDL**
（`05c6:9008`，port 3-3，无序列号）。识别目标一律按序列号 **`33e80afe`**；总线上另一台小米
**`4a2fe00b`** 必须忽略。恢复仍然只能靠**物理长按电源 10–20 秒**。

```sh
# 全部在宿主机上，不碰设备。
bash scripts/host/zl1-one-boot-runbook-selftest.sh    # 177 项
bash scripts/host/zl1-selftest-family.sh              # 19 个 harness / 2252 检查

# 这一轮的核心读数：一个从不作答的设备，被测对象仍然回来。
bash scripts/host/zl1-one-boot-runbook-selftest.sh | sed -n '/== 7c/,/== 8/p'

# 不变量：${SSH[@]} 只允许出现在两处，减掉之后必须为空。
grep -n '\${SSH\[@\]}' scripts/host/zl1-one-boot-runbook.sh

# 变异自己会不会红：
bash scripts/host/zl1-one-boot-runbook-selftest.sh | sed -n '/nodevbound/,/^== 11/p'
```

| 文件 | 作用 |
|---|---|
| `scripts/host/zl1-one-boot-runbook.sh` | 改：`--state-limit`（60）；`bound()` / `devssh()` / `gave_up()`；四次直接 ssh 全部走 `devssh`；探测区分"host 放弃"并点名 rndis 修复；`boot_id` 读不到时说清是哪种；两个读数增加 `TIMEOUT` token，两处 `case` 各增加一个**在 `*` 之前**的分支 |
| `scripts/host/zl1-one-boot-runbook-selftest.sh` | 改：ssh 替身增加 `FP_SSH_HANG_ON`（`exec sleep`，且在探测那一支**之前**）；新第 7c 节（四条场景 + 不变量四项）；第 10b 节增加两个变异（`nodevbound` 用 `muthang` 断言"挂住"） |
| `scripts/host/zl1-health-check.sh` | 改：runbook harness 的引用 147 → 177，并补上"不进 `run_bg` 的那四次调用"和那条不变量 |
| `scripts/README.md` | 改：runbook 行的 `--state-limit`、那四次调用为什么更糟、`devssh` 不变量；harness 行 147 → 177、变异 2 → 4 |
| `docs/ubuntu-touch/132-*.md` | 本篇 |
