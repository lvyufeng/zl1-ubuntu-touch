# 107 — 一次物理按键要换回什么：把恢复后的那一串命令变成一条

**日期**: 2026-09-23
**状态**: 纯离线的一轮（设备仍在 Qualcomm EDL，`05c6:9008` / port 3-3，与 `86`–`106` 同）。这一轮**不是**
新的硬件结论，而是把 [`86`](86-edl-has-a-cause-a-panic-and-the-evidence-survives.md) 之后那串"回来第一件要做的事"
——`00`–`04` 五步、每一步都有自己的 scp/ssh——变成**一条命令**，并且在设备还在 EDL 的时候就把它的行为
离线钉死。

**接续**: [`86`](86-edl-has-a-cause-a-panic-and-the-evidence-survives.md)（pstore）、
[`87`](87-the-container-memory-reading-was-the-whole-phone.md)（kmsg 环形缓冲约一分钟）、[`88`](88-the-addresses-are-ours-now-not-only-the-keepers.md)（netwatch 记账，退休 keeper 的许可）、
[`94`](94-retiring-the-v63-debug-keeper-is-a-kill-not-a-unit-edit.md)（keeper 的 pid 与 CPU ticks 只在杀之前存在）、
[`95`](95-the-first-commands-after-recovery-are-offline-verified.md)（这一串的离线验证）、
[`100`](100-the-other-half-of-the-heat-fix-and-the-only-misc-backup.md)/[`49`](49-two-cores-that-are-not-tls-wifi-stuck-at-wcnss-and-a-trip-into-edl.md)（EDL 的软件出口不存在）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 新增了什么？ | `scripts/host/zl1-post-recovery-capture.sh`：一条命令，按唯一正确的顺序跑完恢复后的只读链，并把每一步的输出**存成文件** |
| 解决的是哪件事？ | **物理按一次电源是很稀缺的**。从 EDL 出来只能物理长按电源 10–20 秒（`49` §6），而出来之后有三样东西**只在那一次开机里读得到** |
| 哪三样？ | ① `/sys/fs/pstore` 里的上一次 oops——**下一次 reset 就没了**（`86`）；② `/userdata/zl1-kmsg/` 的环形缓冲**约一分钟**就绕回来，而 boot-address 的判词必须来自**这一次**开机的 netwatch 日志（`87`/`88`）；③ keeper 的 pid 和累计 CPU ticks——杀掉之后就再也测不到了（`94`） |
| 默认跑什么？ | `01` post-mortem → `02` boot-address → `03` keeper `--status` → `04` health-check → `05` gps 探针 → `06` 指纹探针 → `07` 姿态普查，**七步，全部只读** |
| 会写设备的步骤呢？ | 只有一步会写（`install-no-edl-on-panic.sh --capture-only`，它把 pstore 拷到 `/userdata`），**默认不跑**，要 `--with-capture` 才跑 |
| 设备还在 EDL 呢？ | **拒绝，`exit 2`，一个 ssh 都不发**，并直接打印"下一步只能是物理长按电源"。没有 archive 目录被创建 |
| 离线验证？ | `scripts/host/zl1-post-recovery-capture-selftest.sh`，**94 检查 / 0 失败 / 2 skip**，**五次变异每次都让它失败**（§5） |
| 在设备上跑过吗？ | 只跑过**拒绝分支**（对着真实 EDL 状态，只读总线，`exit 2`）。完整链路**没跑过**，因为设备没回来 |

---

## 2. 为什么值得为此写一个脚本

不是因为"免得手打命令"这种好看的理由，而是因为**这次开机的证据是易失的，而拿到这次开机的代价是一次物理按键**：

* post-mortem 必须在**任何别的东西之前**跑。它读的 `/sys/fs/pstore` 只在**下一次 reset 之前**有效——
  在那之前跑的任何东西都是在透支一份不能重读的证据。所以 `01` 是这个脚本的第一步，而在这行之前的
  一切（身份信息块）都只读。
* boot-address 的判词（`netwatch-configured`）决定 keeper 能不能退休（`88`/`94`），而它只能从**这一次**开机的
  netwatch 日志里读。判错要付的代价是 SSH，而 SSH 要付的代价是**再按一次电源**。
* keeper 的 CPU ticks 是"它到底占了多少核"的唯一直接证据，杀掉之后就不存在了（`94`）。所以身份信息块
  **在链开始之前**就把 pid 和 ticks 抄下来。

把这三件事交给"一边看 health-check 一边手打六对 scp/ssh，同时环形缓冲在绕"是不合理的。脚本做的是
**顺序**和**留档**——两件脚本比人可靠的事。

---

## 3. 顺序，以及为什么是"失败的步骤不中断"

```
00 身份信息        boot_id / uptime / keeper pid + ticks / failed units   （只读，先抄下来）
01 edl-postmortem      <-- 必须第一，pstore 只活到下一次 reset
02 boot-address        <-- 退休 keeper 的许可就在这一步的判词里
03 keeper --status     只读
04 health-check        所有依赖屏幕/传感器的单元
05 gps 探针            只读
06 指纹探针            只读（默认模式不写）
07 姿态普查            只读；**不是** --portrait-up 那次决定性运行（那需要有人扶稳手机）
```

`--with-capture` 才会加上 `08 install-no-edl-on-panic.sh --capture-only`，也就是**唯一会写设备**的那一步。

**一个步骤失败不中断整条链**，这是刻意的：这一串证据只能读一次，为了第一个坏判词就停下来，等于把
剩下的证据扔掉、再按一次电源。所以失败会被记下（日志里那一行、`INDEX.txt` 里的 rc、末尾的总结与
`exit 1`），而**其余步骤继续跑**。这一点在 §5 里是被变异测过的。

---

## 4. 留档：为什么是文件而不是回滚屏

每次运行落在 `tmp-post-recovery-<UTC 时间戳>/`（默认在仓库根，被 `.gitignore` 的 `tmp-*` 覆盖——
**大块数据不进 git**），里面有：

```
00-identity.txt ... 07-orientation.txt   每一步自己的输出
INDEX.txt                                boot_id、时间、三个开关、以及 步骤名 / rc / 文件名 三列
SHA256SUMS                               校验和
```

`INDEX.txt` 里带 **rc**：一个失败步骤和一个"跑了但什么也没说"的步骤，在只有文件名的列表里长得一模一样，
所以 rc 必须在那里。`SHA256SUMS` 在，是因为这份目录是**一次无法回访的开机**的记录——一份没人能验完整性的
记录，在下一次有人问"它真的是这么说的吗"时是个负担。

两次针对**同一次开机**的运行会落进同一个目录（按 `boot_id` 命名只是决定怎么用，目录是 `--outdir` 给的），
所以"再抓一次"不会产生第二份互相矛盾的记录。

---

## 5. 离线验证：94 检查，和五次"必须失败"

`scripts/host/zl1-post-recovery-capture-selftest.sh`（证据：`evidence/post-recovery-capture-selftest-2026-09-23.log`）。

手法沿用这一族：**`ssh`/`scp` 桩就是设备**。这一轮多了一层，因为被测脚本**会调用别的脚本**：那些被调用的
脚本在这里是**记录用替身**（它们各自有自己的 harness），于是"调用了哪些、以什么顺序、带什么参数、输出有没有
留档"变成可断言的。被改写过的路径随后**和真实仓库对照**：改写过的脚本要调用的每个路径，都必须在真实树里
存在——否则一个拼错的脚本名，看起来和一个"跑了但没说话"的步骤完全一样。

变异测试（一个不会失败的 harness 什么也证明不了）：

| 变异 | 结果 |
|---|---|
| 顺序调换（`01`/`02` 互换） | `92 pass / 2 fail` |
| 去掉 EDL 拒绝（照跑不误） | `79 pass / 15 fail` |
| 会写的那一步放进默认集合 | `84 pass / 10 fail` |
| 不留档（不写 `INDEX.txt`/`SHA256SUMS`） | `84 pass / 10 fail` |
| 一个步骤失败就中断整条链 | `89 pass / 5 fail` |

原版 `94 pass / 0 fail / 2 skip`。两个 skip 是明确写出的"本机测不了"：那七个被调用脚本**自己**的判词，
以及每一步背后的设备事实（pstore 里到底有没有 oops、netwatch 到底有没有配地址）。

---

## 6. harness 自己抓出来的三个 fixture 缺陷

写这个 harness 的过程又复现了同一族错误，全部记在这里，因为它们都是"测试看起来过了但什么也没测"的形状：

1. **`lsusb -d ID` 是个过滤器。** 我的桩不看参数、无条件打印并 `exit 0`，于是**健康设备也报 EDL**——
   整个默认运行"拒绝"了，六十多条断言一起失败。脚本问的第一个问题**就是**这个过滤行为，把它假掉就是把
   答案假掉。桩现在按 `-d` 的 id 决定 `exit 0` 还是 `exit 1`。
2. **`sed` 映射的顺序会造成二次替换。** `/tmp/` 那条规则最后应用，而**前面每条规则的替换文本本身就在
   `/tmp` 下面**，于是替换文本被后一条规则再改一遍，设备路径变成 `.../fake/tmp/.../fake/proc/uptime`。
   现在那条规则锚定在脚本真正发送的形状上（`sh /tmp/<script>`），并且**探针里有一条专门断言"不许出现
   双重前缀"**——因为这个失败的表现是"设备脚本读了一个不存在的路径"，不是一条报错。
3. **`-o NAME=VALUE` 是两个 argv。** 只跳过"以 `-` 开头"的参数，会留下 `BatchMode=yes`，于是 `scp` 桩把两个
   选项值当成 src/dst，复制失败——**每一个设备步骤都报"could not copy"**。

还有一条不是 fixture 而是断言位置的错误：`keeper pids` / `keeper cpu ticks` 两行被断言在**标准输出**上，
而身份信息块是重定向进 `00-identity.txt` 的。`boot_id` 那条**碰巧**还是过了，因为脚本头部重复打印了它——
这正是"一条错误的断言因为巧合看起来是对的"的形状。

---

## 7. 用法，以及它和 health-check 的关系

```sh
scripts/host/zl1-post-recovery-capture.sh                    # 设备回来后，第一条命令
scripts/host/zl1-post-recovery-capture.sh --skip-probes      # 只想要那三样易失证据时
scripts/host/zl1-post-recovery-capture.sh --with-capture     # 也跑那唯一会写的一步
```

它不是 health-check 的替代品：health-check 是**路由**，它告诉你在哪个状态、下一条命令是什么；这个脚本
是**执行那条顺序并留档**。`04` 就包含 health-check，所以原样保留。

跑完之后会写设备的步骤（每一个都是**用户自己的决定**，脚本不会替谁做）：`install-fingerprint-store-dir.sh
--status` 然后 `--install`（`106`）、`install-no-edl-on-panic.sh --capture-only`、以及**只有在 `02` 说了
`netwatch-configured` 之后**才轮到 `install-retire-debug-keeper.sh --install`。

---

## 8. 这一篇**不**证明什么

* **不证明设备能回来。** 它证明的是"回来之后那一次开机能被榨干"，而回来本身仍然只能靠物理长按电源
  10–20 秒（`49` §6）；没有任何 QDL/firehose 工具会被跑。
* **不证明那些被判词的东西。** pstore 里到底有没有 oops、netwatch 到底有没有配地址、屏幕和传感器现在
  到底怎么样——每一步**自己**的 harness 覆盖它们各自的逻辑，而**设备事实**要等设备。
* **不证明它跑得通。** 完整链路一次都没在设备上跑过；在设备上跑过的只有拒绝分支（见 §1 和证据日志第 3 节）。
  第一次真正运行本身就是一次验证，而它要花掉的那次按键不会因为这篇文档而变便宜。

---

## 9. 设备状态

整轮没有动设备：没有写任何分区或 boot，没有跑 QDL/QFIL，没有重启。设备仍在 **Qualcomm EDL**
（`05c6:9008`，port 3-3，无序列号）。识别目标一律按序列号 **`33e80afe`**；总线上另一台小米
**`4a2fe00b`** 必须忽略。
