# 118 — 发烫修复是一条命令，一个 boot

**日期**: 2026-09-24
**状态**: 本轮**没有碰设备**（设备仍在 EDL，见 §6）。全部是 host 侧：把 `116`/`117` 之后那张"下一步"清单
——`0b2 → 0b2a → 0b1 → 0d → governor` 五步——收成**一条命令**，并为它写了离线 harness。**没有在设备上
安装任何东西，没有 flash，没有写分区。**

**接续**: [`114`](114-the-refusal-gate-was-satisfied-by-the-process-it-removes.md)（licence 与子串门）、
[`115`](115-replacing-a-file-does-not-change-a-process.md)（`--activate` 与那个 90 秒）、
[`112`](112-the-gate-is-a-race-and-it-ends-when-the-keeper-does.md)（verdict 是竞态，licence 是 proof）、
[`107`](107-one-command-runs-the-zero-series.md)（`post-recovery-capture` 的同一个形状，一层之上）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 做了什么？ | `scripts/host/zl1-heat-fix-chain.sh`：把发烫修复的后半段（部署 → 激活 → 等 90 s → 地址归属证明 → 退役 keeper → governor）写成**一个 boot 上的一条命令** |
| 为什么必须是一条命令？ | 因为这是一个 **licence chain**，不是一组独立的读数：第 5 步只能由第 4 步的 `proof-obtained` 授权，而**半途而废的链条意味着地址不归任何人所有** —— 那时候唯一的退路是手指按住电源键 |
| 它自己新增了什么安全性论证吗？ | **没有**。每一步保留自己的门；它加的是**顺序**和**一个 boot 的算术** |
| 为什么 boot 的算术重要？ | 这台设备上 boot 不便宜：每一个 boot 都可能落进 EDL，而出 EDL 要物理长按 10–20 s（doc 49 §6）。一条五步、中间夹 90 秒等待的手工清单，正是"做了一半然后放弃"的形状 |
| 这一轮**真的修了**一个消息？ | **是**。EDL 那段拒绝文本的第二行是 `tool may be run here.` —— 上一行的 `no QDL/firehose` 才是那个否定，所以这一行**单独读起来像是允许**。是 harness 把它抓出来的（§3） |
| 离线验证？ | `zl1-heat-fix-chain-selftest.sh` **95 检查 / 0 失败**，其中 5 个变异各自改变它观察到的东西 |
| 写 harness 时抓到了什么？ | **两类"不可能失败的检查"**：变异体因为路径解析而在自己的 preflight 退出 2（于是两条 `notwant` 断言靠"什么都没跑"通过），以及一个只改了**注释里的散文**、行为与 subject 完全一样的变异（§5.2/§5.3） |
| 动设备了吗？ | **没有。** 设备仍在 EDL；发烫**仍未解决**（两个热修复都还没装上） |

---

## 2. 为什么是"一条命令"

`107` 已经确立过这个形状一次（`post-recovery-capture`：一次 boot 上按顺序跑完 0 系列）。这一次的对象是
**发烫修复的后半段**，而它的每一步都已经有自己的 harness：

| # | 步骤 | 它自己的门 |
|---|---|---|
| 1 | `install-netwatch-service.sh --yes --ssh` | 需要**已验证的 misc 备份**（见 §4.1） |
| 2 | `install-netwatch-service.sh --yes --ssh --activate` | `ExecMainStartTimestampMonotonic` 必须严格晚于重启前的 `/proc/uptime`（docs 115） |
| 3 | 等 90 s（`--settle`） | 激活后的 build 的 heal 会**重新枚举 USB gadget**，而链条自己的 ssh 就跑在它上面 |
| 4 | `zl1-address-owner-proof.sh --yes` | 它自己会 SIGSTOP keeper、拿走地址、要求 netwatch 放回来（docs 112） |
| 5 | `install-retire-debug-keeper.sh --install --now --after-proof` | 替换件必须已部署、带 `ensure_addrs()`、且 active；`--now` 没有 `--after-proof` 直接拒绝（docs 114） |
| 6 | `install-cpufreq-governor.sh --install` | 写回读，拒绝时**非零退出**（docs 99） |

也就是说，链条**没有引入任何新的安全论证**——它带来的是两样别的东西：

1. **顺序**：第 5 步要在第 4 步之后，且只在那**一整行** verdict 出现之后；
2. **一个 boot 的算术**：五步里那 90 秒的等待如果被跳过，失败会**出现在证明里**，看起来像证明的错
   （发现这一点的是 docs 115）。

于是一个手工清单最可能的两种坏结局——**在中途放弃**、或者**在证明失败之后还去跑第 5 步**——都被
结构性排除了：`step()` 在第一个失败处**停下**（不像 capture 脚本，那里的步骤是彼此独立的读数），
读回设备状态，归档，`exit 1`。

---

## 3. 这一轮真的修了的一个消息：拒绝文本的第二行

EDL 分支原本是这么写的（`116`/`117` 之前的形状）：

```sh
say "  It is in Qualcomm EDL (05c6:9008 / QDL mode). There is no software exit and no QDL/firehose"
say "  tool may be run here. THE NEXT MOVE IS PHYSICAL: long-press POWER for 10-20 s, wait for RNDIS"
```

**这两行拼起来是对的**——"没有软件出口，也没有 QDL/firehose 工具可以在这里运行"。但一个读者看到的
是**两行**，而第二行独立地读起来是：

```
  tool may be run here.
```

也就是**允许**。给它做断言的 harness 写下了它以为在读的那句话（`tool may not be run here`），第一次运行
就失败了——**而失败是正确的**：那句话不在输出里。这不是 harness 的错字，这是**文本的错**：否定被留在
上一行的行尾，而这一行的开头读起来是许可。现在它自己说清楚：

```sh
say "  It is in Qualcomm EDL (05c6:9008 / QDL mode). There is no software exit, and no downloader"
say "  tool may be run here: not QFIL, not QSaharaServer, not fh_loader and not any fastboot write."
say "  THE NEXT MOVE IS PHYSICAL: long-press POWER for 10-20 s, wait for RNDIS and ssh, then run"
say "  this script again."
```

断言也随之分成三条：说了**没有 downloader 可以跑**、**点名**它不是在提供哪几个工具、以及**没有**把其中
任何一个当作出路来提。这一整件事是 `113` 那条规矩的又一次命中：**一段输出也是一件仪器**，而它读起来像
什么和它意味着什么，可以不一致。

---

## 4. 这条命令做了什么

### 4.1 预检：在写任何东西之前，把 misc 备份的**三条规则**查一遍

第 1 步的安装器**拒绝**在没有已验证 misc 备份的情况下继续，这是对的。链条在**自己开始之前**做同一件事，
这样不至于花掉一个 boot 才发现：

```sh
misc_backup_ok() {
  [ -s "$MISC_BACKUP" ] || { echo "empty or missing"; return 1; }
  [ -f "$MISC_OUT/SHA256SUMS" ] || { echo "no SHA256SUMS beside it"; return 1; }
  ( cd "$MISC_OUT" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ) || { echo "it FAILS its recorded SHA256"; return 1; }
  return 0
}
```

三条规则是**安装器的**（`install-netwatch-service.sh` 里的那三条），这里只是重说一遍；两者若不一致，
**安装器赢**，因为它的拒绝保护的才是那个它能写的分区。只查 `[ -f ]` 的形状在这个仓库里已经出过事
（docs 116/117 是同一族的最近两次），所以这一次三条一起查，且 harness 里有一条变异**专门把它退回到
存在性检查**，要求那一刻链条**不再拒绝**——检查是活的。

### 4.2 三种"够不着"：拒绝、说出下一个动作、什么都不跑

| 状态 | 判据 | 输出 |
|---|---|---|
| `edl` | `lsusb -d 05c6:9008` | EDL 那段：物理长按，且**点名不许跑的工具** |
| `absent` | `/sys/bus/usb/devices/*/serial` 没有 `33e80afe` 前缀 | 检查线缆和端口，并**点名必须忽略的另一台手机**（`4a2fe00b`） |
| ssh 无应答 | `ssh true` 失败 | 指向 **host 侧**的恢复（`zl1-rndis-recover.sh`，那一个**不需要按键**） |

三种都是 `exit 2`、**不写任何东西**，并且 harness 对每一种都断言"**没有发生任何 ssh/scp**"和"**没有
任何安装器被调用**"——用 107 的方式：看 verdict，也看**实际没打电话**。

顺序也是刻意的：**先看 host 的 USB 树**，因为 EDL 里**没有 serial number**，按序列号找什么也找不到，
而按 vendor-id 找会找到一台**不能对话**的手机。

### 4.3 那 90 秒为什么是"一步"，以及为什么在后台

它是归档里的一步（`03-settle.txt`），因为"这里等了 90 s"是下一个读者需要的事实——跳过它的链条会**在
证明中间掉线**，而那个失败看起来会像证明的错。

```sh
sleep "$SETTLE" &
wait $!
```

后台 + `wait` 不是风格问题：bash 会**推迟 trap 直到前台命令返回**，所以前台 `sleep N` 会让一次中断
拖 N 秒才被响应（capture 脚本实测过：前台 +20.0 s 对 `wait` 下 +2.0 s）。90 秒的 settle 上，这就是
"被打断"和"九十秒后被打断"的区别。

### 4.4 licence 是一整行，不是一个词

```sh
VERDICT=$(grep -ax '== verdict: [a-z-]*' "$OUT/04-proof.txt" | tail -1 | sed 's/^== verdict: //')
if [ "$PROOF_RC" != 0 ] || [ "$VERDICT" != "proof-obtained" ]; then
```

`-x` 是**整行**匹配，这正是 docs 114 的教训（当时一个**子串**门接受了仅仅含有那个词的一句话）。步骤 4
的 rc 也必须为 0：**一个印了那个词但没有成功的证明**同样不授权。其他一切——`proof-unclear`、拒绝、空
输出、超时——都让 keeper 留在原地，那是安全的那一边，而链条会**说清楚这不是链条失败、是链条在工作**，
并读回设备状态告诉读者"手机还够得着"。

### 4.5 归档、退出码、中断

每一步自己的输出进 `tmp-heat-fix-<timestamp>/`，配一个 `INDEX.txt`（step / rc / file）和一个
`SHA256SUMS`；`tmp-*` 是 gitignored，所以归档不进仓库。

| 退出码 | 含义 |
|---|---|
| 0 | 链条跑到头 |
| 1 | 某一步失败（归档说得出是哪一步，以及那留下了什么状态） |
| 2 | 拒绝：没有 `--yes`，或者设备够不着，或者 misc 备份不可用 |
| 3 | 被中断——**它自己的码**，而且中断也留下归档 |

`trap on_signal INT TERM HUP` 走 `archive; exit 3`，所以一次被 Ctrl-C 的链条仍然留下一份带
`INTERRUPTED` 的 `INDEX.txt` 和**它已经完成了哪几步**。

---

## 5. 离线验证：95 检查，5 个变异，以及写它时抓到的两类假绿

`scripts/host/zl1-heat-fix-chain-selftest.sh`：**95 检查 / 0 失败**，一次干净的运行归档在
[`evidence/heat-fix-chain-selftest-2026-09-24.log`](evidence/heat-fix-chain-selftest-2026-09-24.log)。
传输层是 stub（`ssh`/`scp` stub **就是**设备），四个被调用脚本是记录用的 stand-in；subject 是**重写过的
副本**——只改四个 callee 路径和启动总线的那一处，其余（参数处理、拒绝顺序、verdict 比较、归档、trap）
都是真代码。

### 5.1 五个变异

| 变异 | 必须改变的东西 |
|---|---|
| 去掉 settle | 那次等待消失（所以"它**就是** 90"这条断言是活的） |
| verdict 门放宽成子串 | 一个近似的 verdict 现在**授权**了 kill（rc 变 0，retire 真的跑了） |
| 去掉 `--after-proof` | 被调用方被要求**不重新测量**就杀 |
| 预检退回存在性检查 | 一个**空**的备份不再让链条停下 |
| 删掉 EDL 拒绝 | 有东西对着 EDL 里的手机跑了起来 |

每一个变异都先断言**它落地了**：同一个 sed 必须也能改动**发布出去的那个文件**、变异体必须能解析、
并且必须与 subject 不同。这三条各自都是被真实事故逼出来的（§5.2/§5.3）。

### 5.2 假绿之一：变异体在自己的预检里退出 2

变异体最初是 `sed "$SRC"` 生成的，而 `$SRC` 里的四个 callee 是 `"$HERE/../install-*.sh"`——`$HERE` 是
**假仓库**，那里没有安装器。于是每个变异体都在**自己的预检循环**里：

```
cannot read /tmp/zl1-heat-fix-chain-selftest/fake-repo/scripts/host/../install-netwatch-service.sh
rc=2
```

五个变异里有四个因此根本没有执行，而其中最坏的两个是**通过**的：

```sh
notwant 'after-proof' "$(callees)"   # 什么都没跑，所以"没带 --after-proof"当然成立
```

—— 一条**不可能失败**的检查，而且它通过的理由和它在测的东西毫无关系。修法有两半：变异体从**重写过的
副本**生成（被变异的行仍然是发布的那些行，`mutate()` 会断言这一点），以及**每个变异块的第一条断言是
"它到达了各个步骤"**。没有后半条，这个 section 里的否定断言会被一个"在做事之前就拒绝了"的变异体满足。

### 5.3 假绿之二：变异改的是注释里的散文

`--install --now --after-proof` 这个字符串在链条里出现**三次**：头部注释、计划文本、以及真正的调用行。
最初的 sed 打的是那个裸字符串，于是它改了**散文**，留下调用行原封不动——变异体**报告"已落地"而行为与
subject 一模一样**（harness 打印出 `CALLEE install-retire-debug-keeper args=--install --now --after-proof`，
这就是它当场暴露的方式）。现在 sed 指名 `"$RETIRE" ` 前缀，只可能命中调用行。

### 5.4 守卫抓到的一条**陈旧**变异

"这个 sed 一行都没匹配上发布出去的文件"这条守卫，第一次跑就把 `nosettle` 抓了出来：它打的是
`^sleep "$SETTLE"$`，而**中断修复**（§4.3）已经把那一行换成了 `sleep "$SETTLE" &` 加 `wait $!`。
一条静静匹配不到东西的变异，就是一条**什么也不测**的变异。顺带记一个 GNU sed 的坑：在模式的**末尾**
把字面 `$` 写成 `\$` **不匹配**（本文实测），所以末尾锚点要写成裸 `$`。

---

## 6. 这一轮没有确定的事

### 6.1 这条链条**没有在设备上跑过**

95 条检查全部离线。它是**第一个可检验的断言**：设备回来的那一次，链条的第一条真实验证就会发生。在那
之前，"它是对的"只意味着**在 stub 面前**它是对的。

### 6.2 发烫**仍然没有解决**

两个热修复（退役 v63 debug keeper，约 1 个核；cpufreq governor，镜像把四个核都钉在 `performance`）
**都还没装上**，都要等设备。链条只是让"装上"这件事花掉**一个 boot**而不是五个手打命令加一次半途而废。

### 6.3 EDL 的原因仍然**没有确定**

`116` §6.1 的框架没变：**两次 EDL 前面都是指纹探针，这是两个点的相关性，不是归因**。本轮的链条**不碰**
那个问题，它只是把"设备回来之后要做什么"变成一条命令。

---

## 7. 下一步

顺序与 `117` §7 相同，只是后半段现在是**一条命令**（每一步都还没有得到用户的批准；设备在 EDL，唯一的
出口是物理长按电源 10–20 秒）：

```
scripts/host/zl1-post-recovery-capture.sh                    # 探针默认跳过；0. / 0b / 0b1 / 0b2 的读数
scripts/host/zl1-heat-fix-chain.sh --status                  # 只读：链条在这台设备上的四个问题
scripts/host/zl1-heat-fix-chain.sh --yes                     # 0b2 -> 0b2a -> 90s -> 0b1 -> 0d -> governor
```
