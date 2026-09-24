# 135 — 相机栈重置的等待说"没有注册"，而死的是往管道里写日志的那个进程

**日期**: 2026-09-24
**状态**: 本轮**没有碰设备**（设备仍在 Qualcomm EDL，见 §8）。上一轮（[`134`](134-the-false-fail-was-in-the-pipeline-s-writer.md)）在 §7 里
点名了 harness 之外"写端可能真的很大"的两处位置，其中之一就是这轮的脚本；这一轮去读了它。读出来的不是"以后可能会出问题"，
而是**这个等待今天就会给出错误读数**：设备立刻注册了 provider，脚本却说"没有注册"，而那句话把人送去查一个坏掉的 HAL。
新 harness 61 项；家族 19 → **20 个 harness / 2291 → 2354 检查**，树未变。

**接续**: [`134`](134-the-false-fail-was-in-the-pipeline-s-writer.md)（同一个形状，在家族自己的判定辅助函数里；本页是它 §7 点名的下一处）、
[`133`](133-the-host-check-answered-for-one-step-and-the-rest-had-none.md)（一个检查的论证适用范围）、
[`67`](67-the-preview-started-it-was-a-sched-fifo-request.md)（同一个脚本上一次给出假警告：用户切换的判定读了一条那条路径从不打印的日志）、
[`68`](68-the-camera-stage-was-one-cookie-in-the-stub.md)（这个重置存在的理由，以及它之后才能开始的那次测量）、
[`128`](128-the-chain-changed-the-heat-and-never-measured-it.md)（"证明这个检查会红"，且不拿真文件做实验）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 发现了什么？ | `scripts/android-fw-stubs/camera-stack-reset.sh` 的两个等待（provider 注册、cameraserver 枚举）把**整份 `logcat -b main -d`** 通过管道交给 `grep -q`，每个等待 30 次，而脚本自己设了 `set -uo pipefail` |
| 后果？ | 设备**立刻**注册了 provider（那行就在 dump 的**第一行**），脚本却说 `provider has not registered after 90s`——而这句话把人送去查一个坏掉的 HAL |
| 是竞速还是必然？ | **必然**。干草堆（整份主日志缓冲）比管道（64 KB）大的时候**每一次运行都错**：离线夹具 5089028 字节、匹配落在第一、二行，修前的脚本每次都给出"没有注册"（同一份夹具在修好的脚本上是"第一遍就命中"） |
| 为什么一直没人看见？ | 因为小 dump 时写端通常先写完（同一个"36 KB 里 100 次红 4 次"的形状，[`134`](134-the-false-fail-was-in-the-pipeline-s-writer.md) §3），只有日志攒大了才必现——**恰恰是你已经在查别的问题的时候**。而这个脚本是手动跑在每次相机测量之前的 |
| 修法？ | **先取回 dump，再对取回的文本做匹配**（`dump="$(on_device "$LOGCAT_DUMP")"` 之后 `grep -q "$PAT" <<< "$dump"`）。判定里不再有"写端还活着吗"这个问题 |
| 同一形状还有哪里？ | 两个用户切换的判定（`printf '%s\n' "$last_notify" \| grep -q …`）——同样改成 here-string |
| 放弃时的诊断呢？ | 原来**再问一遍 logcat**（61 次 dump 而不是 60，而且第二遍是同一个问题晚三秒、外加又一次被杀死的机会）；现在读**刚才失败的那一份** `$dump` |
| 顺带？ | `--quiet` 从来没有安静过：四行远端回显（`killed … pid` / `up:` / `ctl.restart cameraserver` / `cleared`）直接写 stdout，不经过 `say`。现在每一行都过 `say`，而且**两个方向**都有断言 |
| 离线怎么证明？ | 新 harness `host/zl1-camera-stack-reset-selftest.sh`，**61 项**。传输替身就是设备；夹具 dump **按构造大于管道**（5089028 字节）；一个 `sed` 变异把管道放回去 → 30 次 sleep + "没有注册"，而修好的脚本读**同一份** dump 第一遍就命中。对**修前的修订版**（`git show HEAD:`）跑同一套，**红 12 处** |
| 不变量呢？ | 这个 harness 设了 pipefail，所以家族 meta-harness 立刻扫了它——而**第一次写它就是红的**：它必须在文件里拼出那个形状（一个变异体的 `sed` 表达式、一个指名"惰性形状"的过滤器）。两处都改成 `@` + `tr` 组装。这正是 [`134`](134-the-false-fail-was-in-the-pipeline-s-writer.md) §7 对那 12 个 harness 许下的承诺：**谁哪天加上 pipefail，谁被抓到** |
| 家族？ | **20 个 harness / 2354 检查 / 全绿**，409 个跟踪文件前后哈希一致 |
| 动设备了吗？ | **没有。** |

---

## 2. 现象：一个"设备明明答了"的失败

修前的脚本，对着一个 5089028 字节、**第一行就是那行注册日志**的 dump：

```
== waiting for the provider to register its HIDL interface
   provider has not registered after 90s
== restarting cameraserver
   ctl.restart cameraserver
== waiting for cameraserver to enumerate both cameras
   cameraserver has not enumerated both cameras after 90s -- a run now would fail to connect
```

两种等待各自耗掉 90 秒、各自失败，而它要的那两行分别在 dump 的第一行和第二行。这**不是**"设备坏了"的读数，
它是"这个检查没能读到它自己的输入"的读数，而后者的危害更大：`67` 与 `68` 的全部内容都建立在
"a run now would fail to connect"这句话上，一个人会据此去重启容器、去查 HAL、去怀疑 `mAllowedUsers`。

同一份夹具、同一个夹具文件，换成本轮的脚本（§4）：

```
== waiting for the provider to register its HIDL interface
   provider registered
```

---

## 3. 机制：六十次提问，每一次都是一条 64 KB 的管道

```sh
set -uo pipefail                                  # 脚本第 50 行
for i in $(seq 1 30); do                          # 两个这样的循环
  if on_device 'nsenter -t $(lxc-info …) -p -- /system/bin/logcat -b main -d -v brief' |
    grep -q 'Registration complete for …ICameraProvider'; then
```

`grep -q` 的语义是"命中即退出"，命中之后它关掉读端；此时写端（`timeout → ssh → sh -c → nsenter → logcat → cat`，
最里面那个 `cat` 正在把整份缓冲往外倒）还没写完，于是吃到 `SIGPIPE`。`pipefail` 不看是谁，只看**有没有**非零，
于是"写端死了"变成了这次检查的答案。`134` §3 已经把这条链量过一次（36 KB 里 100 次红 4 次、2 MB 里 200/200 假失败、
here-string 0/200）；本页新增的只是**它的量级**：这里的干草堆是整份主日志缓冲，不是几百行文本。

两个循环各 30 次，加上放弃时那一次额外的 dump，修前的一份"没注册"的运行会做 **61 次** logcat dump，
而修好的是 **60 次**——这个差值本身就是一个可断言的观察（§5）。

---

## 4. 修法：干草堆先落下来，匹配只对着文本

| 位置 | 原来 | 现在 |
|---|---|---|
| provider 等待 | `if on_device '<整份 logcat>' \| grep -q …` | `dump="$(on_device "$LOGCAT_DUMP")"`，再 `grep -q "$PROVIDER_REGISTERED" <<< "$dump"` |
| 枚举等待 | 同上（字符串是**另一份拷贝**） | 同上，而且两个等待共用 `LOGCAT_DUMP` 与两个模式变量——两份拷贝不会各自漂移 |
| 放弃时的诊断 | `on_device '<整份 logcat>' \| grep -aiE … \| tail -6` | `grep -aiE … <<< "$dump" \| tail -6`（读刚才失败的那一份） |
| 两个用户切换判定 | `printf '%s\n' "$last_notify" \| grep -q …` | `grep -q … <<< "$last_notify"` |
| 四行远端回显与 notify 那一行 | 直接写 stdout | `say "$(on_device '…')"`——`say` 之外不再有 stdout |
| 远端字符串里的 4 处 `head -1` | `pgrep … \| head -1` 等 | **保留**。它们在**设备侧**的 sh 里跑，那里没有 pipefail，状态也被丢弃；改它们是在一个"每次相机测量前都要跑"的脚本上做没有可观察差异的 diff（`134` §7 把这一整类点名为惰性形状） |

`say` 自己也加了一条规矩：**空的输出不再印出一个空行**。原来的写法里远端命令什么都不印时什么都不印，
把这些回显改道之后，"`say "$(远端命令)"`" 会在失败路径上多印一行空白——这一条是为了保持那个原行为，
而且它只需要改一处，不需要在五个调用点各加一个 `[ -n … ]`。

---

## 5. 离线证据：夹具自己先错了三次

`host/zl1-camera-stack-reset-selftest.sh` 的形状与它的兄弟姐妹一致：**传输替身就是设备**
（`ssh` 剥掉选项和主机名，把远端命令在本地一个假根里跑；`lxc-info`、`pgrep`、`nsenter`、
`/system/bin/logcat`、`/system/bin/setprop` 都是替身；`sleep` 是即时时钟）。四件事是这一轮踩出来的，
而且四件都是"夹具不能失败"这一类的变体：

| 踩到的 | 读数 | 结果 |
|---|---|---|
| logcat 替身末尾写了 `exit 0` | 被 SIGPIPE 杀死的 `cat` 被报成 **0**，于是变异体看起来和修好的脚本**一模一样**——陷阱没响，而它会"通过" | 替身的最后一条命令就是那个 `cat`，它的状态就是替身的状态。夹具不能失败，陷阱就是一句话 |
| 场景之间复用 dump 夹具 | 脚本最后一步是 `logcat -c`（**清空缓冲**），所以下一个场景读到空文件：第一次运行的失败信息里写着 `0-byte dump`，而陷阱"没有复现" | 大夹具写一次到 `$W/big-dump.txt`，每个场景 `cp` 过去 |
| 远端命令里的 `kill -9 $p` | `kill` 是 shell **内建**，PATH 替身拦不住，夹具里的 pid 会是**宿主机上真实的 pid** | 传输替身用远端前导文件注入一个 `kill()` **函数**（函数优先于普通内建），杀变成记录 |
| 两种 `sleep 3` | 等待自己的 `sleep 3` 与 provider 重启命令里的 `sleep 3` 在动作记录里长得一样，"等待睡了几次"没法断言 | `sleep` 替身连**父进程的 cmdline** 一起记：等待的是 `bash …camera-stack-reset.sh` 的子进程，远端那条是 `sh -c …` 的子进程 |

断言分七节：守卫（不是 zl1 就一步都不做）、健康路径（四步与它们的顺序、完整服务名、`nsenter` 用的是容器 pid）、
**大于管道的 dump**（陷阱 + 真的没注册的那条分支：30 次 ×2 的 sleep、60 次 dump、诊断只印 QCamera 行）、
用户切换的四种日志（`sent` / `no such service` / 本地对象 / 什么都没有 / **旧块说 sent 而最后一块不是**）、
三个变异、对被测文件的形状扫描、以及这个 harness 自己的引用自检。

三个变异各改变一个**具名**的可观察量：`oldpoll`（把管道放回去，见 §1）、`anyblock`（用户切换的判定从
"最后一段 notify"变成"尾部任何一处 `sent (oneway)`"——正是 `67` 去掉的那个假警告）、
`noprefix`（`ctl.restart camera-provider-2-4`，setprop 接受它然后什么都不做）。

---

## 6. 不变量：这个 harness 第一次被写出来就是红的

meta-harness 的 7b 节（[`134`](134-the-false-fail-was-in-the-pipeline-s-writer.md) §5）扫的是**真 harness**，
判据是行首的 `set … pipefail`。这个新文件设了 pipefail，所以它一进树就在扫描范围里，而**第一次家族跑就红**：

```
FAIL  a pipefail harness still has the shape that reports the WRITER's death as a check's answer:
```

抓到两行，而且两行都是**它必须拼出这个形状**的地方：一个是变异体的 `sed` 表达式（那是**制造**缺陷的测试数据），
一个是指名"惰性形状"的过滤器（那是**描述**缺陷的测试数据）。做法与 meta-harness 自己的夹具一致：
用 `@` 占位、组装时 `tr '@' '|'`——守卫不该给自己的测试数据开口子，因为一个需要豁免的守卫迟早被人关掉。

修好之后 meta-harness 报 `8 harness(es) set pipefail and were scanned`（上一轮是 7），其余那一节的三条夹具不变。

另一条不变量在本文件里：`risky()` 扫**被写文件的每一个**"写端可能被杀死"的形状，今天必须恰好是**五个**——
四个远端字符串里的 `head -1`，加上 `LOGCAT_DUMP` 里那一个——而且它配三条夹具（有形状的必须被抓到、
here-string 的不许被抓到、**写在注释里**的也不许）。对着**修前的修订版**跑，这一节印的正是那两行判定：

```
FAIL  a pipeline whose writer can be killed now feeds something in the shipped file:
        | 145:if printf '%s\n' "$last_notify" | grep -q 'sent (oneway)'; then
        | 147:elif printf '%s\n' "$last_notify" | grep -q 'no such service'; then
```

---

## 7. 这一轮**不**证明什么

* **不证明设备上的主日志缓冲真的会超过 64 KB。** 夹具证明的是"这个形状在大输入下必死"，不是"这台手机
  一定撞得上"。不过这个等待的**全部理由**就是那段日志很大（它在等两条要几秒钟才出现的行），
  而 64 KB 只是一屏左右——真要断言设备上的尺寸，得在设备上量，这一轮没有。
* **不证明另外那约 40 处同类形状。** [`134`](134-the-false-fail-was-in-the-pipeline-s-writer.md) §7 的清单
  （`readelf … | grep -q` 的构建闸门、`ss -ltn | grep -q`、设备侧用 `head -1` 取 pid 的地方）**一条都没有动**；
  这一轮只读了一个文件，另外那一处在同一个 §7 里被点名的 `android-fw-stubs/build.sh` 没有读。
  **不变量仍然只覆盖 harness**，也就是说这棵树里"设了 pipefail 的普通脚本"仍然没有守卫。
* **不证明这个序列本身是对的。** 重置有没有把相机栈带进"一次测量可以从这里开始"的状态，是 `67`/`68` 的问题，
  需要设备。这一轮改的是**判定**，不是**动作**：重启顺序、完整服务名、`nsenter` 的用法都只是被断言下来
  （它们以前就是对的），没有被重新论证。
* **不证明 `tail -14` 这个窗口够。** 用户切换的判定依赖 `tail -14 $LOG` 里能找到**最后一段** notify：
  如果那一段落在文件末尾 14 行之外，`awk` 取不到起点，判定会走到 else 分支并警告。今天没有改它
  （改它需要知道这份日志真实的增长形状），这是**已知边界**，写在这里。
* **不证明 `--quiet` 之外的东西。** `say` 现在是唯一的 stdout 出口，但"这不是 zl1"的报错仍然直接写 stderr
 （故意的：错误不该被 `--quiet` 吞掉）。
* **不证明 README 的计数配对是完整的。** 这一轮发现 `scripts/README.md` 里
  `host/zl1-cli-usage-selftest.sh` 那一行的计数写成 `**N checks.**`（句号在粗体里），而 4f 的配对正则要求
  `**N checks**`——**这一行的数字从来没有被比过**，只有健康检查那一侧被 harness 自己自检。现在它成对了
  （并且数字随本轮改成 **136**），配对数 14 → 15，并用一次故意的 `**999 checks**` 证明它现在会红
  （`zl1-cli-usage-selftest.sh: README says 999, the verified citation says 136`）。另外两行（`48 checks.` 的
  纯文本形式，以及一行根本没写计数）**仍然是配不上的形状**——记下来，没有扫。
* **不证明这条链在设备上跑得通。** 整轮一次 ssh 都没有。

---

## 8. 设备状态与复现

整轮没有动设备：没有写任何分区或 boot，没有跑 QDL/QFIL，没有重启。设备仍在 **Qualcomm EDL**
（`05c6:9008`，port 3-3，无序列号）。识别目标一律按序列号 **`33e80afe`**；总线上另一台小米
**`4a2fe00b`** 必须忽略。恢复仍然只能靠**物理长按电源 10–20 秒**。

```sh
# 全部在宿主机上，不碰设备。
bash scripts/host/zl1-camera-stack-reset-selftest.sh    # 61 项
bash scripts/host/zl1-cli-usage-selftest.sh             # 136 项
bash scripts/host/zl1-selftest-family-selftest.sh       # 90 项（它扫到 8 个 pipefail harness）
bash scripts/host/zl1-selftest-family.sh                # 20 个 harness / 2354 检查

# 这一轮的核心：同一份大于管道的 dump，修前说"没有注册"，修后第一遍就命中。
bash scripts/host/zl1-camera-stack-reset-selftest.sh | sed -n '/== 3\./,/== 4\./p'
bash scripts/host/zl1-camera-stack-reset-selftest.sh | sed -n '/== 5\./,/== 6\./p'

# 那个"陷阱真的会响"的证明：变异体是被测对象自己的旧形状。
bash scripts/host/zl1-camera-stack-reset-selftest.sh | grep -A2 "mutation 'oldpoll'"

# 这个 harness 在修前的修订版上必须红（12 处），否则它什么都没测：
git show HEAD:scripts/android-fw-stubs/camera-stack-reset.sh > /tmp/pre-fix.sh
ZL1_CAMERA_RESET_SRC=/tmp/pre-fix.sh bash scripts/host/zl1-camera-stack-reset-selftest.sh | grep '^FAIL'

# 机制本身（不经 harness）：
set -uo pipefail
{ printf 'MATCH\n'; seq 1 300000; } | grep -q MATCH; echo "old shape at the end of a pipe: $?   (141 = the writer was killed)"
d=$( { printf 'MATCH\n'; seq 1 300000; } ); grep -q MATCH <<< "$d"; echo "the captured form: $?"
```

| 文件 | 作用 |
|---|---|
| `scripts/android-fw-stubs/camera-stack-reset.sh` | 改：两个等待先取回 dump、再对文本匹配（`LOGCAT_DUMP` 与两个模式变量，两个等待共用）；放弃时的诊断读那一份失败的 dump（不再第二次问 logcat）；两个用户切换判定改 here-string；四行远端回显与 notify 行改为经 `say`（`say` 同时不再印空行，`--quiet` 因此名副其实） |
| `scripts/host/zl1-camera-stack-reset-selftest.sh` | **新增**：61 项。传输替身就是设备（含一个注入的远端 `kill()` 函数、记录父进程的 `sleep`）；夹具 dump 5089028 字节；三个变异各改变一个具名观察量；对被写文件的形状扫描（五个惰性形状 + 三个夹具）；自己的引用自检 |
| `scripts/host/zl1-health-check.sh` | 改：点名新 harness（61 项）并写下它修的是什么；`zl1-cli-usage-selftest.sh` 的引用 134 → **136**、它点名的脚本 44 → 45（路径 39 → 40） |
| `scripts/README.md` | 改：新增新 harness 的一行（61 项）；`zl1-cli-usage-selftest.sh` 一行 134 → **136**，并把计数改成配对检查认识的形式（配对数因此 14 → 15） |
| `docs/ubuntu-touch/124-*.md` | 改：家族总数那一行续上本轮的 2354 |
| `docs/ubuntu-touch/135-*.md` | 本篇 |
