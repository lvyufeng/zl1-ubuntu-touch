# 134 — 家族的判定辅助函数报告过一次假 FAIL，而失败的是管道里的**写端**

**日期**: 2026-09-24
**状态**: 本轮**没有碰设备**（设备仍在 Qualcomm EDL，见 §8）。这一轮的起点不是设计，而是一次
**闪烁的失败**：在验证 [`133`](133-the-host-check-answered-for-one-step-and-the-rest-had-none.md) 的家族跑里，
`zl1-lpm-ladder-trial-selftest.sh` 报了一次 `FAIL`，而它断言的那段文字**当时就在被测的文件里**。
钉住它之后读数只有一个，而且它是**家族自己的判定辅助函数**的缺陷：13 个 harness 共用同一个
`want`/`notwant`，其中 **7 个设了 `set -o pipefail`**，于是"读端提前退出"会变成"**写端**死了，所以这次检查不通过"。
trial harness 131 → **134**、meta-harness 85 → **90**、家族 2283 → **2291**。

**接续**: [`133`](133-the-host-check-answered-for-one-step-and-the-rest-had-none.md)（这一轮是在验证它的家族跑里冒出来的）、
[`132`](132-the-bound-was-on-the-steps-and-not-on-the-calls-between-them.md)（永不作答的替身与"上限"的证明方式）、
[`131`](131-the-steps-had-no-clock-and-a-hang-spends-the-boot.md)（`timeout` 不杀进程组那次实测）、
[`129`](129-the-family-total-was-typed-and-no-harness-can-see-the-tree.md)（家族机器本身也要有断言）、
[`128`](128-the-chain-changed-the-heat-and-never-measured-it.md)（证明"这个检查会红"，且**不拿真文件做实验**）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 症状？ | trial harness 会**间歇**报一次 `FAIL`，而它的输入**完整且匹配**：把失败那一刻的干草堆回读出来是 36615 字节、647 行，拿**同一段内容**当场重跑 `grep -Eq` 返回 **0** |
| 那个 `FAIL` 是谁说的？ | **不是读端**。`PIPESTATUS` 当场是 `printf=141 grep=0`：**读端说"匹配"，管道说"写端死了"**，而 `set -o pipefail` 把**管道里任何一处非零**当成这次检查的结果 |
| 机制？ | `want` 原来是 `printf '%s\n' "$2" \| grep -Eq -- "$1"`。`grep -q` 命中第一处就退出（这就是 `-q` 的用途），此时写端还没写完，于是写端吃到 `SIGPIPE` 被杀 |
| 为什么它是**闪烁**的？ | 因为干草堆（36 KB）**比管道容量小**：通常写端在读端退出之前就写完了，于是这是一场竞速——这里 **100 次里红 4 次** |
| 什么时候它**不是**竞速？ | 干草堆比管道大的时候。实测：2 MB 的干草堆、匹配落在第一行，旧形状 **200/200 全部假失败**；把同一段字符串**不经任何进程**交给 grep（here-string），**0/200** |
| 修法？ | 干草堆**不经进程**到达读端：`grep -Eq -- "$1" <<< "$2"`。判定不再包含"写端还活着吗"这个问题 |
| 影响面有多大？ | 同一个 `want`/`notwant` 写在 **13 个 harness** 里；其中 **7 个设了 pipefail**（camera-app-test、gps-first-client、lpm-ladder-trial、one-boot-runbook、modem-probe、selftest-family、sleep-and-throttle），**这 7 个里的 24 行**带着这个形状——而它们**全部**被改掉了（今天扫描为 0） |
| 只是那 13 个辅助函数吗？ | 不是：判定位置上还有 `printf … \| grep -q …` 的直接用法（`lpm-ladder-trial` 四处、`camera-app-test` 两处）、截断输出用的 `\| head`（五处：三处 `head -5`、一处 `head -1`、一处 `head -10`）、以及 runbook harness 里 `latest_archive()` 的 `ls -dt … \| head -1`（**函数返回值**会被 pipefail 污染） |
| 怎么保证不加回去？ | meta-harness 里的**不变量**：**任何设了 pipefail 的 harness 都不许把 `grep -q`/`grep -m`/`head` 放在管道右边**。它扫的是**真 harness**而不是清单，点名那 7 个，扫不到任何一个时报"洞"而不是通过 |
| 为什么禁**形状**而不是禁**用法**？ | 因为用法在文本里看不见（它取决于 pipefail 和两个调用方），而"提前退出的读端"**只能省工作量，永不会改变答案**——所以不要它什么也没失去（截断的地方改用 `sed -n '1,5p'`，读到底，打印的还是一样五/十行） |
| 那"这个检查会红"呢？ | 三个夹具：带形状的**必须被抓到**、here-string 的**不许被抓到**、把形状**写在注释里**的**也不许**（否则每一个解释这个缺陷的 harness 都会被自己的守卫打红）。第一个夹具用 `@` 占位再 `tr` 成 `\|`——因为 meta-harness 自己也设了 pipefail，而"守卫必须给自己的测试数据开口子"正是这棵树一直在躲的形状 |
| 陷阱呢？ | trial harness 的 11b：一个**超过 1 MB**、匹配落在**第一行**的干草堆（并且断言它确实那么大）。把写端放回管道里，它**每次都红**（实测 3/3，不需要机器负载），把写端拿掉就是绿的（134/0） |
| 旧修订版上这个检查会红吗？ | 会。对**具名的**修订 `ea45200` 跑同一个扫描：7 个文件一共 **24 行**；今天 0 行（`git show HEAD:` 不行——那是自比较，见 §5） |
| 离线验证？ | trial 131 → **134**、meta 85 → **90**、runbook harness 208（其中一行的形状也改掉）、家族 **19 个 harness / 2291 检查 / 全绿**，树未变 |
| 动设备了吗？ | **没有。** |

---

## 2. 症状：一个"内容对、判定错"的失败

它长得不像一个缺陷，像一个抖动：家族跑有时红一次，重跑就绿。第一次抓到它是这样：

```
FAIL  the branch for a write that succeeds and vanishes is pinned in the source (it cannot be built here)
pass=130 fail=1
```

而那一次的 `FAIL` 是**间歇**的（另一次红的是同一节里的另一条）。判断一个"间歇的失败"是不是真缺陷，
唯一诚实的办法是**把失败那一刻的输入抓下来**：给 `want` 加一行，在失败分支里把
`$2` 的字节数、行数，以及**拿同一段内容重跑同一个 grep** 的返回码写进 `/tmp/wantlog`：

```
WANTFAIL label=[and names: 3 REFUSED] printf=141 grep=0 bytes=36615 lines=647
WANTFAIL label=[the header declares the exit codes] printf=141 grep=0 bytes=36615 lines=647
```

三件事同时成立，而这在"内容错了"的假设下不可能同时成立：

* **内容完整**（36615 字节、647 行——就是那个文件，命令替换只少一个结尾换行）；
* **重跑匹配**（同一段字符串、同一个模式，`grep -Eq` 返回 0）；
* 而当时那个管道的两个退出码是 **`printf=141 grep=0`**。

`141` 是 `128+13`——**SIGPIPE**。也就是说：**读端说"我找到了"，死在管道里的是写端**，而这次检查
报的是**写端的死**。于是同一件事的两面同时被证明了：这不是内容问题，是**判定的来源**错了。

---

## 3. 机制：`-q` 提前退出，加 `pipefail`，等于"写端的死是答案"

```sh
set -o pipefail                      # 家族全部 7 个 harness 都设了
printf '%s\n' "$2" | grep -Eq -- "$1"   # 判定 == 管道里任何一处非零
```

`grep -q` 的语义是"命中即退出"，这本身是对的、也是它快的理由。但它的**退出**会关掉管道的读端，
而此时写端可能还在写——写端于是吃到 `SIGPIPE`。`pipefail` 关心的不是"谁"而是"有没有"非零，
所以这个**正常**的退出路径被读成了失败。

它是竞速还是必然，只取决于**干草堆有多大**（默认管道容量 64 KB）：

| 干草堆 | 旧形状（`printf \| grep -q`） | 新形状（`<<< "$2"`） |
|---|---|---|
| 36 KB（本 harness 的真实大小） | 100 次运行里红 **4** 次 | 0 |
| 2 MB（匹配在第一行） | **200/200 假失败** | **0/200** |

第二行是这一轮真正有用的那个读数：**它把"闪烁"变成了"必然"**。这既是修法的证明，也是
"这个检查会红"的证明——不需要机器负载、不需要多跑几次，任何主机上都会红。

---

## 4. 修法：干草堆不经进程到达读端

```sh
want()    { if grep -Eq -- "$1" <<< "$2"; then ok "$3"; else bad "$3"; sed 's/^/        | /' <<< "$2"; fi; }
notwant() { if grep -Eq -- "$1" <<< "$2"; then bad "$3"; grep -E -- "$1" <<< "$2" | sed 's/^/        | /'; else ok "$3"; fi; }
```

（`notwant` 失败分支里的那条管道是**没有问题的**：写端是 `grep -E`，它读到底，不会提前退出。）

设了 pipefail 的 7 个 harness 里，有 6 个用的是这个辅助函数；第 7 个（`one-boot-runbook`）的
`want`/`notwant` 是 `case` 写法（没有管道），所以它在这一轮里只需要改 `latest_archive()` 那一行——
**"辅助函数改好了"不等于"这个文件改好了"**，这也是下面那张表存在的原因。

改的范围是**形状所在的每一行**，而不是"那几个辅助函数"——因为同一个缺陷在别的判定位置上也存在：

| 位置 | 原来的形状 | 现在 |
|---|---|---|
| 13 个 harness 的 `want`/`notwant`/`wantl` | `printf … \| grep -Eq …` | `grep … <<< "$2"` |
| `lpm-ladder-trial` 的四处判定（声明的写目标、白名单的第五个目标、额外目标的捕获、撤销文件是否落盘） | `printf … \| grep -qxF/-q …` | `grep … <<< "$VAR"` |
| `camera-app-test` 的 stray-zero 判定 | `printf … \| grep -qE '^0$'` | `grep -qE '^0$' <<< "$TABLE"` |
| 三处"只印前五行"的诊断（lpm、modem、sleep） | `grep -n … \| head -5 >&2` | `grep -n … \| sed -n '1,5p' >&2` |
| `camera-app-test` 取第一行启动命令 | `… \| head -1` | `… \| sed -n '1p'` |
| `sleep-and-throttle` 印前十条 diff | `diff … \| head -10 \| sed …` | `diff … \| sed -n '1,10p' \| sed …` |
| **`one-boot-runbook`** 的 `latest_archive()` | `ls -dt … \| head -1` | `ls -dt … \| sed -n '1p'` |

最后一行值得单独说：它不在判定里，在**函数的返回值**里。`latest_archive() { ls … | head -1; }`
的返回值在 pipefail 下会变成 `ls` 的 `SIGPIPE`（141），而不是 0——今天的所有调用方都把它接进
变量、不用状态，所以它**今天**是无害的，但"一个函数偶尔返回非零"是下一次有人在
`latest_archive || ...` 里用它的那种缺陷。

---

## 5. 不变量：禁形状，扫真 harness，扫不到就说洞

`want` 会被复制（它已经被复制了 13 次），所以修一次不算修好。meta-harness 里加了一段，
扫的是**真 harness**，不是清单：

```sh
scan_risky() { # 文件 -> 命中行（带原文件行号，注释行丢掉）
  grep -nE '\|[[:space:]]*(grep[[:space:]]+-[A-Za-z]*q|grep[[:space:]]+-[A-Za-z]*-m|head([[:space:]]|$))' "$1" \
    | grep -vE '^[0-9]+:[[:space:]]*#'
}
for f in "$HERE"/zl1-*selftest.sh; do
  grep -qE '^set -[a-zA-Z]* *pipefail' "$f" || continue
  ...
done
```

三个决定是刻意的：

* **只扫设了 pipefail 的 harness**，而"设了"由**行首的 `set`** 认定（这棵树里每个 harness 都这么写）。
  没有 pipefail 时，写端的死活不是管道的状态，这个形状是**惰性**的：这一轮没有改动的 12 个 harness
  里，7 个带着同一个 `want`/`notwant`（另外几个带着 `\| head` 之类的截断），它们今天不可能因此误报。
  **而其中某一个哪天加上 `set -o pipefail`，这个检查立刻变红并列出要改的行**——
  这正是重点：这个形状是一踩就响的陷阱，而那句 `set` 看起来和它毫无关系。
* **禁形状，不禁用法**；并且**跳过注释行**。用法在文本里看不见（取决于 pipefail 和两个调用方），
  而提前退出的读端只能省工作量，永不改变答案；至于注释——**这个缺陷本身就要靠注释来解释**，
  一个会被自己的说明打红的守卫，下场是被删掉。
* **扫不到任何一个 pipefail harness 时报"洞"**，不是通过：`no harness was found to set pipefail`
  正是"检查不可能失败"那类东西的入口，所以它是被印出来的。

夹具三个，顺序有意义（一个全红的扫描会通过第一条、死在第二条）：

| 夹具 | 断言 |
|---|---|
| 带形状的（`set -uo pipefail` + 旧写法） | **必须被抓到**——否则上面那条断言不是检查，是一句话 |
| 用 here-string 的 | **不许被抓到**——否则修法本身也被惩罚 |
| 把形状**写在注释里**的 | **不许被抓到**——否则每个解释这个缺陷的 harness 都会红 |

第一个夹具是**组装**出来的：`@` 占位、`tr '@' '|'` 成真。原因写在那行注释里，而且它本身是一条规矩：
**守卫不能给自己的测试数据开口子**——meta-harness 自己也设了 pipefail，把带形状的夹具直接写在源文件里，
就等于要求扫描器认识自己的测试数据。

---

## 6. 陷阱：一个每次都会红的检查

不变量保护"形状不再出现"，而**行为**要由被测对象自己证明。trial harness 的第 11b 节：

```sh
BIG="$( { printf 'the first line is the one that matches\n'; seq 1 200000; } )"
NBIG=${#BIG}
[ "$NBIG" -gt 1000000 ] && ok "…$NBIG bytes, larger than any default pipe…" || bad "…"
want '^the first line is the one that matches$' "$BIG" "a haystack larger than a pipe ($(… wc -c) bytes) …"
notwant 'a pattern that is nowhere in the haystack' "$BIG" "and the same haystack does not match …"
```

三条断言，各自的用途不同：**第一行**是"这个陷阱不可能是空的"（干草堆必须真的比管道大），
第二条是**陷阱**本身，第三条是**反方向**（同一个干草堆对不在里面的模式必须不匹配，
否则"这个辅助函数对大的输入一律返回 0"也会通过）。

**它每次都会红**，这一点是实测的：把 `want` 改回 `printf … | grep -Eq …`（写完就还原，见下），
harness 三次运行、三次都是：

```
FAIL  a haystack larger than a pipe (1288933 bytes) with the match on its FIRST line
pass=133 fail=1
```

——**不带任何机器负载**，也不需要多跑几次才撞上。这一条很重要：只能偶尔失败的检查，
没有人能据它行动；而这一轮修的那个缺陷恰恰是"偶尔失败"，所以它的替身必须不是。

（还原之后 `pass=134 fail=0`；文件用 `git diff` 核对过，与提交内容一致。）

**机制本身没有在 harness 里再测一遍，这是刻意的**：测它需要写出被禁的那个形状，
而"守卫给自己的演示开一个口子"比"演示只留在文档里"更糟。上面那两个数字
（`PIPESTATUS` 141/0、4/100、2 MB 的 200/200 与 0/200）就是那次测量的结果。

---

## 7. 这一轮**不**证明什么

* **不证明另外 12 个 harness 没问题。** 它们带着同一个形状，只是没设 pipefail，所以今天不可能误报；
  这一轮**没有**改它们的辅助函数（改了是 12 个文件的纯风格变更，而那 12 个文件的测试正在
  绿着——不是这一轮该动的东西）。**不变量会在它们中间任何一个加上 pipefail 的那天变红**，
  这是这一轮对它们的全部承诺。
* **不证明不变量是完备的。** 它是**文本**扫描：靠行首的 `set … pipefail` 判定"设了"，
  所以一个用别的方式打开 pipefail 的 harness（`set -o pipefail` 分行写、或 `bash -o pipefail` 调用）
  会漏掉；一个把形状**藏在 heredoc 里**的文件也会被抓到（那反而是对的）。
  这两侧都没有被断言，只有"扫到 7 个"这句话被印出来。
* **不证明 `<<<` 在所有主机上都一样。** 它由 bash 实现（本树里所有 harness 都是 bash）；
  这一轮证明了"在这台机器上、这个 bash 上，它 0/200"。没有测别的 bash 版本。
* **不证明那 24 行以外没有同一个缺陷。** 这一轮修的是**7 个设了 pipefail 的 harness**里、
  扫描器认识的那 24 行。**树里还有约 40 个脚本**带着同样的形状（`readelf … | grep -q` 的构建闸门、
  `ss -ltn | grep -q`、`ip addr show | grep -q`，以及设备侧用 `head -1` 取 pid 的地方），
  其中至少两处的写端**可能真的很大**（`camera-stack-reset.sh` 把一整个 `logcat -d` 灌进 `grep -q`；
  `android-fw-stubs/build.sh` 与 `tlsfix/build-tlsfix.sh` 用 `readelf` 的输出当构建闸门），
  它们**没有被这一轮覆盖**——不在 pipefail 之下时它们是无害的，在 pipefail 之下的那些
  这一轮也没扫。这是**已知的边界**，写在页面上。
* **不证明另外 5 个修好的 harness 有行为陷阱。** 只有 trial 那一个（缺陷被实测到的地方）有；
  其余 5 个由**不变量**覆盖，而"不变量是文本的"这件事上面刚说过。
* **不证明这两条链在设备上跑得通。** 整轮没有一次 ssh。

---

## 8. 设备状态与复现

整轮没有动设备：没有写任何分区或 boot，没有跑 QDL/QFIL，没有重启。设备仍在 **Qualcomm EDL**
（`05c6:9008`，port 3-3，无序列号）。识别目标一律按序列号 **`33e80afe`**；总线上另一台小米
**`4a2fe00b`** 必须忽略。恢复仍然只能靠**物理长按电源 10–20 秒**。

```sh
# 全部在宿主机上，不碰设备。
bash scripts/host/zl1-lpm-ladder-trial-selftest.sh   # 134 项
bash scripts/host/zl1-selftest-family-selftest.sh    # 90 项
bash scripts/host/zl1-selftest-family.sh             # 19 个 harness / 2291 检查

# 这一轮的核心机制（写端，不是读端）：一个大于管道的干草堆，旧形状必然失败、新形状不会。
set -uo pipefail
big=$( { printf 'MATCH\n'; seq 1 300000; } )
printf '%s\n' "$big" | grep -Eq MATCH; echo "old shape status: $?   (141 = the writer was killed)"
grep -Eq MATCH <<< "$big";            echo "new shape status: $?"

# 不变量自己会不会红（对具名修订，不对 HEAD——那会变成自比较）：
git show ea45200:scripts/host/zl1-lpm-ladder-trial-selftest.sh \
  | grep -cE '\|[[:space:]]*(grep[[:space:]]+-[A-Za-z]*q|head([[:space:]]|$))'   # 7

# 陷阱会不会红：把 want 的写端放回管道，它会红，而且每次都红（写完还原）。
bash scripts/host/zl1-selftest-family-selftest.sh | sed -n '/== 7b\./,/== 8\./p'
```

| 文件 | 作用 |
|---|---|
| `scripts/host/zl1-camera-app-test-selftest.sh` | 改：`want`/`notwant`/`wantl` 走 here-string；stray-zero 判定与取第一行启动命令改掉 |
| `scripts/host/zl1-gps-first-client-selftest.sh` | 改：`want`/`notwant` |
| `scripts/host/zl1-lpm-ladder-trial-selftest.sh` | 改：`want`/`notwant`；四处判定改掉；三处诊断改 `sed -n`；新增第 11b 节（三检查：干草堆必须真的比管道大、陷阱、反方向） |
| `scripts/host/zl1-modem-probe-selftest.sh` | 改：`want`/`notwant`；诊断改 `sed -n` |
| `scripts/host/zl1-selftest-family-selftest.sh` | 改：`want`/`notwant`；新增第 7b 节（不变量 + 三个夹具 + "扫不到就报洞"） |
| `scripts/host/zl1-sleep-and-throttle-selftest.sh` | 改：`want`/`notwant`；诊断与 diff 输出改 `sed -n` |
| `scripts/host/zl1-one-boot-runbook-selftest.sh` | 改：`latest_archive()` 的 `head -1` → `sed -n '1p'`（返回值不再被 pipefail 污染） |
| `scripts/host/zl1-health-check.sh` | 改：trial 131 → 134、meta 85 → 90，并补上这一段（PIPESTATUS 的读数、2 MB 的 200/200、陷阱为什么必须每次都会红、以及不变量为什么禁形状禁注释） |
| `scripts/README.md` | 改：两个 harness 行的检查数与新章节 |
| `docs/ubuntu-touch/134-*.md` | 本篇 |
