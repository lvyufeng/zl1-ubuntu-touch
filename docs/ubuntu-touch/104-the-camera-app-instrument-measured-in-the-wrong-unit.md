# 104 — 相机应用那件仪器：一个 100× 的单位、一个两行的计数，和一句谁都没读过的判词

**日期**: 2026-09-23
**状态**: 纯离线的一轮（设备在 EDL，`05c6:9008` / port 3-3，与 `86`–`103` 同）。`zl1-camera-app-test.sh` 是 health-check 的第 1 项，也是**唯一**一件为"相机窗口有没有上屏"这个问题而存在的仪器——它是最后一件没有离线验证的外设仪器（post-mortem、boot-address、orientation、thermal、installers、loc-fp、gps 都已经有了）。给它写离线验证，找出了**四个缺陷**，四个都是这个项目反复遇到的那种形状：**一个数字或者一句判词，报不出它自己声称的东西**。`scripts/host/zl1-camera-app-test-selftest.sh` 78 项；对 `b909256` 的仪器是 **55 通过 / 23 红**。

**接续**: [`68`](68-*.md)（§5 量出来的那条带：无客户端 1.2 ticks/s，有客户端 20–50）、[`77`](77-*.md)（一张截图永远不能证明什么在*活着*）、[`80`](80-*.md)（应用第一次跑起来，`ZL1_AS_UID=32011` + 修好的 `libcfi-shadow-init.so`）、[`98`](98-*.md)（同一族的"harness 自己也有缺陷"）、[`102`](102-gps-log-owners-and-the-two-unreachable-branches.md) / [`103`](103-the-fingerprint-probe-counted-the-callers-own-line-in-logcat.md)（归属规则）。代码里前后对照与两次运行的原文：`docs/ubuntu-touch/evidence/camapp-test-defects-2026-09-23.log`。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 这一轮修的是什么？ | `zl1-camera-app-test.sh` 的四个缺陷：**单位错了 100 倍**、**计数会打印两行**、**判词不读应用有没有起来**、**参数守卫根本不存在** |
| 100× 有多要紧？ | 头部把那一列叫作 `ticks/s`，引用的带子是 **1.2 / 20–50**（`68` §5，HZ=100）；而代码算的是 `(b-a) * 100 / secs`。于是那条**绝对门槛 `B >= 8`**——写下来时意思是"8 ticks/s，远高于 1.2 的基线"——实际是 **0.08/s**，除了"合成器完全不动"以外**不可能失败**。整个判词里真正在干活的只剩比值那一半 |
| 为什么不能只是"把 100 去掉"？ | 因为门槛紧跟着就变成**小数比较**：`[ "$B_TPS" -ge $((A_TPS * 4)) ]` 在 `A_TPS=1.0` 时是 `bash: 1.0: syntax error: invalid arithmetic operator`。老写法之所以自洽，恰恰是因为它产出的是整数。所以比值判断整块搬到了 awk |
| 计数是什么形状的缺陷？ | `n=$(grep -ac "$pat" F 2>/dev/null \|\| echo 0)`：**`grep -c` 无匹配时既打印 `0` 又退出 1**，于是回退分支又贴了一个 `0`——值里带了一个换行，表格在**最要紧的那几行**（`ASSERT`、`caught signal`，本来就该是 0）多打出一条孤立的行 |
| 判词读了什么、没读什么？ | 第 3 步知道"应用有没有起来"并打印了出来，**判词一个字都没用**；窗口 B 结束后"还在不在"也同样只打印不使用。后果是：**启动器失败会被报成"应用没有被合成"**——仪器为一件事去怪应用，而应用根本没得到做那件事的机会 |
| 还有一处静默呢？ | 两个窗口只要有一个读不出来，老代码的 `if` 不成立、`else` 是空的——**一行判词都不打**，看起来像"判词恰好是空的" |
| 参数守卫呢？ | 头部写着 `--run-seconds` "必须大于 2 × `--seconds`"，**没人检查**；而且 2× 也不是那个算术（窗口 A 在启动**之前**跑，根本不需要应用）。真正的要求是 `--seconds + 6 + 2`：窗口 B 在启动后 6 秒才开始，长度 `--seconds`。低于它，应用会在窗口中间被杀，判词转而怪它 |
| 证据表读了几本日志？ | 一本：`app.err`，还管它叫"应用自己的证据（来自 `$OUTDIR/app.err`）"。**哪个流由谁写不是这件脚本能确定的事**——而 `zl1-camapp-launch.py` 自己就是用 `file=sys.stderr` 打印的（`102`/`103` 的归属规则，往上一层） |
| harness 有多少牙？ | 对 `b909256` 的仪器：**78 项里 23 条红**，四个缺陷每一个都至少有一条红指着它 |
| 动设备了吗？ | 没有。ssh/scp 都是桩，桩**就是**设备（在假根里跑远端命令），没有写设备、没有 QDL/firehose、没有重启 |

---

## 2. 缺陷一：一个 100× 的单位，和它后面那条不可能失败的门槛

老代码（`b909256`）的窗口函数与判词：

```sh
ticks_window() {
  local label="$1" secs="$2" pid="$3"
  ssh_d "a=\$(awk '{ sub(/^[^)]*\) /, \"\"); print \$12+\$13 }' /proc/$pid/stat)
    sleep $secs
    b=\$(awk '{ sub(/^[^)]*\) /, \"\"); print \$12+\$13 }' /proc/$pid/stat)
    echo \"$label \$((b-a)) \$(( (b-a) * 100 / $secs ))\"" | tail -1
}
...
if [ -n "${A_TPS:-}" ] && [ -n "${B_TPS:-}" ]; then
  if [ "$B_TPS" -ge $((A_TPS * 4)) ] && [ "$B_TPS" -ge 8 ]; then
```

`(b-a)` 是 jiffies，`secs` 是秒，所以 jiffies/秒**本来就是** ticks/s——只要除以秒，不用乘 100。乘了 100 之后，屏幕上的 `100`/`2000` 与头部自己引用的 `1.2`/`20–50` 相差两个数量级，而 `B >= 8` 这条为"8% 的一个核"写的门槛变成了 0.08%：

| 夹具（12 秒窗口） | 老代码打印 | 老代码判词 | 文档单位下的真值 | 真值判词 |
|---|---|---|---|---|
| A=12 / B=240 jiffies | `100` / `2000` | composited | 1.0 / 20.0 | composited |
| A=1 / B=30 jiffies | `8` / `250` | **composited** | 0.1 / 2.5 | **inconclusive** |
| A=12 / B=18 jiffies | `100` / `150` | none（靠比值那一半才对） | 1.0 / 1.5 | none |
| A=12 / B=720 jiffies | `100` / `6000` | composited | 1.0 / 60.0 | composited |

第二行是这条缺陷的分水岭：一个**几乎不动**的合成器在老算术下两道门槛全过（`250 ≥ 4×8` 且 `250 ≥ 8`），在文档单位里只有 2.5/s——是基线的 25 倍，却离 8/s 的门槛还远，正确答案是"不确定"。也就是说老代码会把"合成器为了这件事勉强动了几下"报成"应用正在被合成**。

修完：远端只带回 **jiffies 和秒**，速率在本地算（`printf "%.1f", d/s`），比值判断搬进 awk（`[ -ge ]` 吃不了小数）。而且**读不出来的窗口保持读不出来**：`[ -n "$d" ] || return 0`——在哪儿打印 `0.0`，都会让一次 ssh 失败看起来和"合成器什么都没干"一模一样，然后判词去怪应用。

---

## 3. 缺陷二：一个会打印两行的计数

```sh
n=$(grep -ac "$pat" "$OUTDIR/app.err" 2>/dev/null || echo 0)
printf '   %-32s %s\n' "$pat" "$n"
```

`grep -c` 数不到东西时**打印 `0` 并且退出 1**，所以 `|| echo 0` 让 `n` 变成 `0\n0`（`$( )` 只削掉尾部的换行，不削中间的）。`printf` 于是打出两行：一行是那一行剩下的部分，一行是个孤零零的 `0`。**受害的正好是该为 0 的行**——`ASSERT`、`caught signal` 在设备上就该是 0，而读者看到一个单独成行的 `0` 时，没法把它和"另一行表格"区分开。同一个坑这个项目已经踩过一次（`grep -c ... || echo 0` 在笔记里出现过），这是它在**打印**这一侧的表现。

修完：

```sh
count_in() { # $1 file, $2 pattern -> one number, always
  local n=
  [ -r "$1" ] && n="$(grep -ac -- "$2" "$1" 2>/dev/null)"
  printf '%s\n' "${n:-0}"
}
```

---

## 4. 缺陷三：判词不读应用自己的状态

第 3 步在设备上走 `/proc`（`pgrep -f` 在这台机器上不可靠，`68` §5）找到应用并把答案打印出来：

```
   launched pid 6100
```

然后判词从 `if [ -n "$A_TPS" ] ...` 开始，**这句话一个字也没用**。窗口 B 结束后的 `alive=` 也一样（`alive pid=... state=S threads=...` 或者 `NOT RUNNING (it exited before the window ended)`）。于是：

* **启动器失败**（uid、会话总线、EGL、二进制缺失）→ 屏幕上出现"应用没有被合成"；
* **应用中途死了** → 窗口 B 量的是那块屏幕，不是应用，而判词照旧比较两个数字；
* **窗口读不出来** → 一行判词都没有。

修完的判词按互斥的三种状态排序，而且**"从没起来"优先**（一个从没起来的应用当然也不在运行，再打一遍"它死了"只是噪音）：

```sh
if   [ "$APP_STARTED" = 0 ]; then ... 启动器失败，不是合成器的问题 ...
elif [ "$APP_ALIVE"   = 0 ]; then ... 窗口 B 量的是屏幕，不是应用 ...
elif [ -n "${A_TPS:-}" ] && [ -n "${B_TPS:-}" ]; then ... 比值 ...
else ... NO VERDICT：两个窗口有一个读不出来，没有可比的东西 ...
fi
```

---

## 5. 缺陷四：一个文档里存在、代码里不存在的守卫

头部写着"`--run-seconds` 必须大于 2 × `--seconds`"，代码里没有这句话对应的任何一行。而且 2× 也不是那个算术：窗口 A 在**启动之前**跑，压根不需要应用，所以 `--run-seconds` 需要覆盖的只有"启动后 6 秒 + 窗口 B 的 `--seconds`"。低于它，`timeout $RUN_SECS` 会在窗口 B 中间把应用杀掉，`alive` 读到空——而（修完之后）判词会忠实地报"应用在窗口 B 结束前就不在了"。**判词对了，测的却是参数错误**，这正是这件仪器最不该犯的错：怪应用。所以是拒绝，不是警告：

```sh
_min=$((SECS + 6 + 2))
if [ "$RUN_SECS" -lt "$_min" ]; then ... exit 2; fi
```

---

## 6. 缺陷五（附带）：证据表只读了一个流

老表的表头是 `== the app's own evidence (from $OUTDIR/app.err):`——**把"数哪一个文件"当成了"证据是什么"**。`zl1-camapp-launch.py` 自己的两行（`launching ...`、`dropped to uid ...`）都是用 `file=sys.stderr` 写的，Qt 的消息处理器（`console.log` 的去处）也是 stderr——所以真实运行里 `app.out` 很可能是**空的**。修完的表两列都数、列名写明来自哪个文件：

```
   Creating a QMirClientScreen         2 err     1 out
   Added camera                        2 err     0 out
   Application is now active           1 err     0 out
   ASSERT                              0 err     0 out
   caught signal                       0 err     0 out
   not found                           0 err     0 out
   -- 'Added camera' in app.err:
   | Added camera "0"
   | Added camera "1"
```

`--help` 的范围（老 `2,52p`）落在**赋值区中间**——打出来的东西里有 `HOST=...`、`SECS=12`、`RUN_SECS=45` 这些行；新头部变长之后，同一个 `2,52p` 又从**另一头**出错：它停在 `#   --outdir DIR` **之前**，也就是说最后一条被文档化的选项没被打出来。范围的两端都会错，而且只有一端是响的——所以 harness 现在两头都断言（既要 `--outdir DIR` 在，也不要 `^HOST=` 在）。

---

## 7. harness：**桩就是设备**

`scripts/host/zl1-camera-app-test-selftest.sh` 用的是 installers 自测那套传输桩模式，这里是它最完整的一次应用：

* `ssh` 把连接选项和主机名剥掉，**在本地跑远端命令**；`scp` 两个方向都实现（推到假设备 / 从假设备拉回应用自己的输出）；
* **`sleep` 就是时钟**：每一次 `sleep` 往假的 `/proc/<pid>/stat` 里加一段 jiffies（按调用序号从 `rates` 文件取），所以两个窗口真的经过脚本自己的 awk 字段运算——包括 `sub(/^[^)]*\) /)` 去 comm 的那一步，而 comm 故意**带一个空格**（内核允许，最多 15 字符）；
* `lxc-info`/`busctl`/`pgrep`/`nsenter`/`kill` 都是桩：`busctl` 的 `TurnOn`/`TurnOff` **真的改变** `ActiveOutputs` 的回答，所以"屏幕是否被恢复成原样"是关于夹具的事实，不是关于日志的断言；
* `kill` 必须**按路径**调用：它是 shell 内建命令，PATH 桩拦不住它，而一次真的 `kill` 会去杀宿主机的进程。改写脚本的那条 sed 因此是**单引号**的——它要匹配的那一行在文件里真的带着反斜杠（`\${p%/cmdline}`，因为它在双引号的 ssh 命令里），双引号会把反斜杠吃掉，sed 照样退出 0，唯一的症状是一次真的 `kill`；
* `--help`、参数守卫、以及"落地检查"（`/proc/` 改写的条数必须相等，`kill` 改写必须命中）都在最前面，因为一处漏改就是"命令在量**这台**机器，而所有场景照样 PASS"（`98` 的缺陷）。

**这一轮 harness 自己犯的错，也都是同一个形状**（这里记下来，因为每一个都会让一个检查"跑了、PASS 了、什么也没测"）：

1. `env_reset` 里写死的 `S_LAUNCH=1` 把场景**在调用之前**设的标志覆盖掉——`S_LAUNCH=0` 的场景于是安静地测了健康的设备（和 `102` 那轮"默认夹具是个坏设备"是同一族，方向相反）。现在：会出错的设备要么由 `run()` 的环境在**运行时**传（`S_ALIVE`、`S_CONTAINER`、`S_SHELL`），要么在 `env_reset` **之后**写进假根（型号、缺失的 cmdline、屏幕状态）；
2. `win3()` 用 `NF==3` 取那一行——而脚本**把注释打在同一行**（`A 12 1.0   (label jiffies ...)`），于是所有速率都读成空；
3. 桩里一个没转义的 `$W_COM_PID` 在**写桩的时候**就被替换成了空，stat 文件落到了 `$FR/proc//stat`：`awk: cannot open ... for reading`，合成器永远不动；
4. fixture 把 `dropped to uid 32011` 写进了 `app.out`——而那一行按源码是 **stderr**（`file=sys.stderr`）。夹具的形状就是被测对象的形状，这一条 `103` 已经付过一次学费。

---

## 8. 牙

| 运行 | 结果 |
|---|---|
| 修完的仪器 | **78 通过 / 0 红** |
| 同一个 harness 对 `b909256` 的仪器 | **55 通过 / 23 红** |

23 条红逐个落在四个缺陷上：守卫 4 条（`it exited 0 instead of refusing` 等）、单位 9 条（`the A window printed '100', want 1.0`、`A printed '8', want 0.1`、`so it is inconclusive` 等）、判词 4 条、计数与两个流 5 条，外加 `--help` 越界 1 条。原文在 `docs/ubuntu-touch/evidence/camapp-test-defects-2026-09-23.log`。

---

## 9. 这一轮没有动设备，设备的状态也没有变

设备整轮都在 **Qualcomm EDL**（`05c6:9008`，port 3-3，无序列号），和 `86`–`103` 一样。没有写任何分区或 boot，没有跑 QDL/QFIL，没有重启。恢复仍然只能靠**物理长按电源 10–20 秒**，之后设备以 RNDIS 回来（用 `grep -qa msm8996 /proc/device-tree/compatible` 和 `adb devices` 里**没有** `33e80afe` 来确认）。识别目标一律按序列号 **`33e80afe`**；总线上另一台小米 **`4a2fe00b`** 必须忽略。

仪器这边修好之后，"相机应用的窗口到底上没上屏"这个问题**仍然没有被回答**——这一轮回答的是"那件仪器能不能测量它"。等设备回到 RNDIS，第一件事就是 health-check 第 1 项，也就是这件脚本本身（`--keep-display` 留给人在旁边看屏幕）。

---

## 10. 下一步（按顺序，设备回来之后）

```sh
scripts/host/zl1-health-check.sh                       # 总览，第 1 项就是相机
scripts/device/zl1-edl-postmortem.sh                   # 0: 这一轮 EDL 之前发生了什么（ramoops 还在）
scripts/device/zl1-boot-address-check.sh               # 0b: boot 的地址是否已由 netwatch 接管
scripts/install-no-edl-on-panic.sh --capture-only      # 0c: 只读
scripts/install-retire-debug-keeper.sh --status        # 0d: 只读
scripts/host/zl1-camera-app-test.sh --keep-display     # 1: 这一轮修好的仪器
scripts/host/zl1-orientation-axes.sh --seconds 30 --portrait-up   # 1b: 唯一还没测的候选（x/y 对调）
scripts/device/zl1-gps-probe.sh                        # 2
scripts/device/zl1-location-request.sh --status        # 2b
scripts/device/zl1-fingerprint-probe.sh                # 3
scripts/device/zl1-thermal.sh --ab                     # 4: 三次测量（`zl1-thermal-zones-have-three-units`）
```

需要用户点头才能做的仍然是那几件：退役 debug keeper（`--install --now` 会真的杀进程）、`install-no-edl-on-panic.sh --install`、任何安装器的 `--install`、指纹探针的 `--create-store-dir`（往 Android 的 `/data` 里写目录）、GPS 的 `--enable-testing` drop-in（一次真实的权限绕过）。
