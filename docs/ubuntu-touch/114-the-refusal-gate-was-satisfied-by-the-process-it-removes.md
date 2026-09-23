# 114 — 那道闸门由它要拿掉的那个进程来满足

**日期**: 2026-09-23
**状态**: 纯离线的一轮。设备仍在 Qualcomm EDL（`05c6:9008` / port 3-3，无序列号），出来只能靠物理
长按电源。这一轮**没有**碰设备。

**接续**: [`94`](94-retiring-the-v63-debug-keeper-is-a-kill-not-a-unit-edit.md)（退役 keeper 只能靠 kill）、
[`99`](99-the-remaining-heat-fix-was-broken-offline.md)（"一个静默没武装的守卫比一个出现在
`systemctl --failed` 里的单元更糟"）、
[`112`](112-the-gate-is-a-race-and-it-ends-when-the-keeper-does.md)（`netwatch-configured` 是一场赛跑）、
[`113`](113-the-usage-text-is-an-instrument-too.md)（守卫要问**能回答它的那个东西**）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 发现了什么？ | `install-retire-debug-keeper.sh` 的 applier 里那道"看不到地址就不杀"的闸门，**不可能失败**：地址正是 keeper 自己每秒放上去的。所以闸门是被**它即将拿掉的那个进程**满足的 |
| 有多要紧？ | 这是"一核换 SSH"的那个决定。keeper 一死，地址就只剩 netwatch 在维持；若 netwatch 其实做不到，**下一次链路抖动就再也回不来**，恢复要用手按住手机。而这道闸门在**每一次真会杀 keeper 的开机**上都放行 |
| 为什么以前没发现？ | 因为 harness 里"没地址 → 拒绝"那一幕，测的是**没有 keeper 可退役**的配置——也就是这个问题根本不成立的唯一状态。**一个只在无关状态里被测过的守卫** |
| 一句话说这是什么缺陷？ | `112` 同一条规则再下一层：**地址在不在，不能证明有人能把它再造出来** |
| 改了什么？ | 闸门从"地址在不在"换成"**替代品在不在、在跑不在跑**"：`/etc/systemd/system/zl1-netwatch.sh` 可执行、带 `ensure_addrs()`、且 `zl1-netwatch.service` 是 active。这是只有我们自己的代码才能满足、keeper 替不了的条件（§3） |
| 不满足时怎么报？ | **退出 1**，让单元落进 `systemctl --failed`——不是一行静默的日志。因为"没部署"不是瞬态：设备上没有任何东西会自己把 netwatch 装上去（`99` 的规则） |
| 那 `--now` 呢？ | 现在还要求 `--after-proof`：先把 `zl1-address-owner-proof.sh` 推上去跑一遍，**只有 `proof-obtained` 才杀**。许可来自半分钟前做的一次**测量**，不是"我记得我跑过 `boot-address-check`"（§4） |
| 离线验证？ | `zl1-installers-selftest.sh` **336 检查 / 0 失败**（原 278）；新内容的牙齿：对**修复前**的安装器跑同一套，**66 条红**（§5，原始输出在 `evidence/installers-mutations-2026-09-23.log`） |
| 顺带发现的第二个缺陷？ | harness 的 `is-active` 桩**打印 `inactive` 却退出 0**，而闸门信的是退出码——**一个和被测脚本无缘无故意见一致的 fixture**。两边都改对了：桩按真实 systemd 退 3，闸门读的是那个状态字符串（§6） |
| 动设备了吗？ | 没有。全部在假设备上跑；没有写分区、没有 QDL/firehose、没有重启、没有拔插 |

---

## 2. 缺陷：闸门测的变量，是它要移除的东西设置的

applier 里原来只有一道前置检查：

```sh
has_address() {           # rndis0/usb0 上有没有 192.168.2.15/24 或 10.15.19.82/24
    _live=$(ip -4 addr show dev "$_if" | awk '/inet /{printf "%s ", $2}')
    case " $_live " in *" 192.168.2.15/24 "*) return 0 ;; *" 10.15.19.82/24 "*) return 0 ;; esac
    return 1
}
```

而 keeper 的 1 Hz 主循环里做的正是这件事（`configure_iface rndis0 usb0`）。于是：

* keeper 活着 → 地址在 → 闸门放行 → 杀掉 keeper（**闸门被它要拿掉的那个进程满足**）；
* keeper 不在 → 地址可能不在 → 闸门拒绝。**而这时候本来也没有 keeper 可退役。**

也就是说：这个守卫只在一个**与它要防的事情无关**的配置里会拒绝。它从来没有在真正危险的时刻说过"不"。
`112` 已经在下层记过同一句话——*地址在，不等于有人能再造一个*——而这一次它是**代码里的一道闸门**，
不是一次判读。

**它为什么看起来是安全的**：头里写着"refuses to kill when it cannot see an address"，读起来像保守方向；
harness 里也确实有一幕"没有地址 → 拒绝，一个信号都不发"，而且它是**绿的**。那一幕不假，只是它测的是
"没有 keeper 的机器"。

---

## 3. 修复的一半：闸门问替代品，不问症状

```sh
replacement_ready() {
    [ -x "$NETWATCH" ] || return 1
    grep -q '^ensure_addrs()' "$NETWATCH" 2>/dev/null || return 1
    [ "$(systemctl is-active "$NETWATCH_UNIT" 2>/dev/null)" = active ] || return 1
    return 0
}
```

三件事，各自都不是 keeper 能替它满足的：

1. **文件在**：`/etc/systemd/system/zl1-netwatch.sh` 存在且可执行；
2. **能力在**：那个**已部署的**版本里有 `ensure_addrs()`——就是"每个采样周期重新断言地址"的那个函数。
   注意这是 `install-netwatch-service.sh` 在落地时**问过的同一个问题**（它 refuse 不带 `ensure_addrs()`
   的构建，`88`），只是问在设备寿命的另一端；
3. **它在跑**：`zl1-netwatch.service` 是 active。

不满足时 **exit 1**。这是刻意的，而且和头里原来那句"永远退 0 —— 退役失败是一行日志，不是一次失败的
开机"是相反的，理由有两层：

* "没部署"和"链路一时不对"是**两类不同的事实**。地址不在是瞬态的，keeper 还在，保守方向就是别动它；
* "没部署"**不会自己变好**——设备上没有任何东西会去部署 netwatch。这时一行日志等于**一个静默没武装的
  发烫修复**，正是 `99` 记的那件事。落进 `systemctl --failed` 是唯一会被人看见的形态。

所以 applier 现在有**两条**闸门，退出码不同、含义不同，顺序也重要：1a 在 mask 之前，所以拒绝时连单元
都没有被 mask——harness 对这一条有断言。

---

## 4. 修复的另一半：`--now` 需要一份**测量**，不是一份记忆

前半段修好了"替代品在不在"，但 `--now` 仍然可以在**没人量过**的开机上把 keeper 杀掉：netwatch 装好了、
active、带 `ensure_addrs()`，可它**在这台设备的这次开机上到底管不管用**，只有量了才知道。

`112` 已经给出那个测量：`zl1-address-owner-proof.sh` —— 停住 keeper、把一个地址拿掉、要求 **netwatch**
把它放回去并且**说出来**。它是唯一能区分"netwatch 拥有地址"和"keeper 拥有地址"的检查。所以：

```
scripts/install-retire-debug-keeper.sh --install --now --after-proof
```

没有任何 `--after-proof` 的 `--now` **退 2，什么都不碰**（`env_reset` 级的前后快照相等，harness 有断言）。
这是刻意的：proof 会停一个进程、摘一个地址，那是**用户要的决定**，不是"我顺手做了"。拒绝不要钱，也不改
设备。许可的要求写在拒绝信息里，连能用的那行命令一起打出来。

判定用的是**那一行**：

```sh
if [ "$PROOF_RC" != 0 ] || ! printf '%s\n' "$PROOF_OUT" | grep -qx '== verdict: proof-obtained'; then
```

不是 `grep -q 'proof-obtained'`。harness 里有一个专门为此存在的 fixture：它**退出 0**、**打印了
`proof-obtained` 这几个字**，但那句话不是判词行。写成子串匹配的闸门会放它过去——这是这个仓库记过的
同一种空白（`110`：一道守卫要了一个在两个版本里都不存在的字符串）。

---

## 5. 离线验证：336 检查，和对修复前的 66 条红

`scripts/host/zl1-installers-selftest.sh`：**336 检查 / 0 失败**（这一轮之前是 278）。新增的四节：

| 节 | 测什么 |
|---|---|
| **2b 许可** | 没有 `--after-proof` 的 `--now` 退 2 且**整台假设备前后快照相同**；`--after-proof` 没有 `--now` 也退 2；proof 的**真实字节**被推上设备（`cmp` 与仓库文件相等）；`proof-obtained` 才启动单元；`proof-unclear`/`not armed`/"字符串在错位置"三种都不许许可，且 keeper 必须还活着、一个信号都没发 |
| **2c 替代品闸门** | 没部署 / 老构建（无 `ensure_addrs()`）/ 部署了但 inactive：三种都 **exit 1**、日志里是 `NOT ARMED`、keeper 还活着、**且没有出现 `REFUSING`**（证明拒绝不是来自地址那道闸门——这一节的 fixture **一直是有地址的**）；再有一幕对照：替代品就位时同一个调用**确实会杀**，所以这道闸门不是一堵墙 |
| **1（补充）** | `--status` 能说出替代品在不在（`ABSENT` / `ensure_addrs(): present` / `active`），因为那正是决定要不要杀的那个答案 |
| **引用守卫** | 这一页现在点名了这个 harness，于是它也带上了 `110` 的那条防漂移守卫（它本来没有，因为**这一页从来没点过它的名**——见 §8） |

**牙齿**：把 harness 对着**修复前**的 `install-retire-debug-keeper.sh` 跑，**66 条红**（每次运行都先 `assert` 自己的改动落地；逐条 FAIL 在 `evidence/installers-mutations-2026-09-23.log`，基线 336/0/0 与提交树一致）。这不是"顺手也
跑了一下"，这是这个 harness 存在的证明——一个对着坏构建也不红的 harness 什么都没测。

**四次变异**，每一次都先 `assert` 自己的改动落地了：

| 变异 | 结果 |
|---|---|
| M1 把 applier 里的替代品闸门整块删掉 | rc=1，322 pass / **14 fail** |
| M2 闸门改回信退出码，**并且**把桩改回退 0（还原那个缺陷） | rc=1，333 pass / **3 fail** |
| M3 把许可闸门改成 `if false` | rc=1，328 pass / **8 fail** |
| M4 判词检查改成子串 `grep -q proof-obtained` | rc=1，333 pass / **3 fail** |

上面每一个数字都不是第一次跑出来的。第一版变异脚本只把 `host/` 和四个安装器抄进临时目录，**而且从 `/tmp` 运行**——
于是"shipped applier"那一节走 `git log -- scripts/install-cpufreq-governor.sh`，在仓库外**没有历史可走**，它
`SKIP`（总数变成 335、带 1 个 skip），而依赖它产物的 4 条检查跟着红。**一个 BASE 里带 4 条失败的"基线"**，
没有一条是关于被测代码的。这和 `113` §6 是同一类错误：**测量的标尺错了，读起来和关于被测对象的事实一模一样**。
所以证据日志里那行"必须在仓库里跑"是量出来的，不是抄来的；也正是它让 BASE 与提交树上的 336/0/0 对得上。

M2 要同时改两个文件，这本身就是它记录的东西——见 §6。

---

## 6. 第二个缺陷：一个和被测脚本无缘无故意见一致的 fixture

写 2c 的"部署了但没在跑"那一幕时它**先是绿的**——也就是说 applier 在没有 netwatch 在跑的情况下照杀。
手工复现之后原因很清楚：

* 桩里 `is-active` 打印 `inactive`，然后 **`exit 0`**；
* 而闸门写的是 `systemctl is-active X >/dev/null 2>&1 || return 1`——**只信退出码**。

真实的 `systemctl is-active` 对 inactive 是**退 3**。桩少了这一半，于是**桩的答案和脚本的期望无缘无故
地一致**：脚本从没"看见" inactive，它看见的是"命令成功了"。两边都改：

* 桩按真实语义 `echo inactive; exit 3`；
* 闸门读**状态字符串**，因为"它是不是 active"才是想问的问题，而"命令是否成功"只是它的代理。

> **一个只会点头的 fixture，和一道永远不会拒的闸门，是同一个东西。**

M2 之所以要同时改两个文件才能复现缺陷，也正是这个原因：那不是一处的错误，是**一处错误和它的镜子**。

---

## 7. 这一篇**不**证明什么

* **不证明 keeper 可以安全退役了。** 它证明的是**那道闸门现在能失败**。真机上还从没跑过
  `--after-proof`：proof 在设备上跑过一次（`112` 的离线段全部覆盖，49 检查），但**退役这一次调用**
  依赖的两个前提——netwatch 已部署、且它的 `ensure_addrs()` 在这台设备上真的能放回地址——都还没在设备上
  同时为真过。这也意味着**发烫没有解决**：两条主要成因（keeper 烧满一个核、四个核钉在 `performance`）
  依然一个都没装上。
* **不证明 `replacement_ready()` 的三个条件是充分的。** 它们是**必要**的：一个 active、带
  `ensure_addrs()` 的 netwatch 仍然可能因为别的原因放不回地址。`--after-proof` 才是充分性那一半，这也是
  为什么它是必需的而不是可选的。
* **不证明别的安装器有同样的问题。** 只有 keeper 那个装了一道"由被移除者满足"的闸门。
  `install-cpufreq-governor.sh` 的对应问题是"写进去读不回来"（`99` 已修），
  `install-no-edl-on-panic.sh` 的是"只读模式静默解除了守卫"（`99` 已修）。

---

## 8. 顺带补上的：一个这一页从来没让人跑过的 harness

写这一轮时才发现：**健康检查从来没有点名 `zl1-installers-selftest.sh`**。也就是说，一个 336 检查、
覆盖**发烫修复两半**的离线验证，在这一页上是不可见的——没有人会被告诉去跑它。这正是 `113` 里那条规则
缺了一半的样子：*"这一页点名的每一个 harness"* 只在**点名之后**才有效。

它现在被点名了，于是三件事自动发生：`113` 的用法扫描把它带进覆盖集（45 个脚本，其中 30 个是这一页点名的）、
`4d` 要求它带上防漂移守卫（它现在带着，`11` 个 harness 全部通过）、以及它自己的条数（336）有了活引用。

顺带也要更正 §5 里的一处数字：**不是"278 检查"**。`scripts/README.md` 里那个数字会随这一轮变，而它是**手
写的**——所以这一页记的 336 由 harness 自己核，README 里的那个由人核，后者仍是这个仓库里会腐坏的那一类。

---

## 9. 设备状态与下一步

设备在 **Qualcomm EDL**（`05c6:9008` / `QUSB__BULK`，port 3-3，无序列号）。整轮只读过主机上的脚本树；
**没有写任何分区或 boot，没有跑 QDL/QFIL，没有重启，没有拔插**。识别目标按序列号前缀 **`33e80afe`**；
总线上另一台设备 **`4a2fe00b`** 必须忽略。

下一步仍然是物理的：长按电源 10–20 秒，等 RNDIS 回来，然后
`scripts/host/zl1-post-recovery-capture.sh`。那之后那条链（`111` / `112` / 本轮）：

```
install-netwatch-service.sh --yes --ssh         # 0b2，不再需要 TWRP
重启                                             # 新构建只有开机才生效
zl1-boot-address-check.sh                       # 0b，inconclusive 是正常读数
zl1-address-owner-proof.sh --yes                # 0b1，确定性地量它
install-retire-debug-keeper.sh --install --now --after-proof   # 0d，许可来自上一步
install-cpufreq-governor.sh                     # 发烫的另一半
```

最后一步之前，`install-retire-debug-keeper.sh --status` 会直接说出替代品在不在——那是这一轮新加的，
也是现在唯一能提前看出"这次退役会不会被闸门拦住"的读数。
