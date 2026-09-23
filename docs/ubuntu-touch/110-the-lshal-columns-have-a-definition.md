# 110 — lshal 的列是有定义的：容器里的 GNSS 服务是**注册的**

**日期**: 2026-09-23
**状态**: 纯离线的一轮。设备仍在 Qualcomm EDL（`05c6:9008` / port 3-3，无序列号），出来只能靠物理长按电源。
这一轮**没有**碰设备，但它解决的是 [`109`](109-the-evidence-had-an-answer-it-just-had-no-verdict.md) §4 明确留下的那一层：
GNSS HIDL 服务到底注册没有。上一轮的说法是"这棵树里没有任何地方记录 `lshal` 的列是什么意思，
所以探针只能印、不能判"。**那句话对输出是真的，对源码是假的** —— 镜像自己的构建树里就有 `lshal`，
而且它编译出来的 `liblshal.so` 里逐字带着那些字符串。列的定义找到了，于是那一层从"猜不出来"变成"读得出来"，
而 2026-09-23 那次录下来的清单**早就写着答案**。

**接续**: [`109`](109-the-evidence-had-an-answer-it-just-had-no-verdict.md)（那段证据有答案，只是没有判词）、
[`93`](93-gps-the-door-is-a-client-request-and-the-two-levers-are-dead.md)（门是一次客户端请求）、
[`82`](82-the-gps-line-read-the-source-and-the-rootfs.md)（`locClientOpen` 那条日志的源码读法）、
[`102`](102-gps-log-owners-and-the-two-unreachable-branches.md)（日志字符串属于包含它的进程）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 这一轮解决了哪一层？ | `109` §4 留下的那一层：`lshal` 的列没人记录过格式，所以"服务注册了没有"判不了 |
| 依据从哪来？ | 镜像的构建树自带 `lshal`：`/mnt/data/halium-zl1-build/frameworks/native/cmds/lshal`。编译产物 `/mnt/android-sys-test/lib64/liblshal.so` 里逐字带着 `Thread Use`、`are you root?`、`All binderized services (registered services through hwservicemanager)` —— 所以源码读法适用于这张镜像，不是推测 |
| 决定性的一条规则是什么？ | `R` 列是 `TableEntry::isReleased()`，它读 `hash`；而 `hash` 在**整份源码里只被赋值一次**，在 `fetchBinderizedEntry()` 里，也就是 **`lshal` 的第一张表**。所以"行在第一张表"= hwservicemanager 列了它 = **已注册**；`R = Y` = 那个对象被取到、并且回答了 `interfaceChain()`/`getHashChain()` = **活着，不只是被列出** |
| 那张录下来的清单说了什么？ | `android.hardware.gnss@1.0::IGnss/default` **在第一张表里**（`R = Y`）。也就是说：**容器里的 GNSS HIDL 服务是注册的，而且它回答了 IPC** |
| 探针改了什么？ | §4 从"打印并拒绝读"改成给出**有依据的读法**（并且把依据写在脚本里）；§6 的判词多一支 `gnss-not-registered`；`no-gnss-listing` **上移**到 `daemon-only` 之前（它原来是几乎打不出来的死分支）；判词的名字单独打一行 `VERDICT: <name>`，因为散文没法被 grep；并且把"`lshal` 一个字都没输出"和"清单里没有 gnss"分开说 —— 前者是**仪器**的阻塞，不是"容器没有 GNSS HAL" |
| 离线验证？ | `scripts/host/zl1-gps-selftest.sh` **129 检查 / 0 失败 / 1 skip**（原来 99 条），**九次变异每一次都让它失败**（§5），其中两次一开始**没有牙**，是这一轮补上的 |
| 这一轮没解决的？ | "是谁发起的"（`109` 已经静态追到"需要数据流读"），以及"有没有拿到过定位" |
| 顺手关掉了什么漂移？ | 健康检查给每个 harness 写的检查数是**手打的**，加一条断言就会过期（GPS 那行还写着 99，已经涨过 120 了，没有任何机制会注意到）。现在被引用的六个 harness 都自己核对这条引用（§6） |

---

## 2. 源码在这里，规则只有三条

`109` §4 的原话是"这棵树里没有任何地方记录这些列在这张镜像上的含义"。这句话需要分开看：

* **这份仓库里**确实没有 —— 所以当时的结论在当时的证据下是对的；
* **镜像的构建树里有**：`/mnt/data/halium-zl1-build/frameworks/native/cmds/lshal/`，
  就是这台设备镜像的来源树。而 `/mnt/android-sys-test/bin/lshal` 只有 68 KB、`.text` 只有 0x1b4 字节，
  因为它是个壳：真正的代码在 `liblshal.so`（334 KB）。所以字符串要在**那个**文件里找：

```
$ for s in 'are you root?' 'Thread Use' 'All binderized services' 'passthrough implementations'; do
    printf '%-30s ' "$s"; strings -a /mnt/android-sys-test/lib64/liblshal.so | grep -c -F "$s"; done
are you root?                  1
Thread Use                     1
All binderized services        1
passthrough implementations    1
```

四条都在。**这一步本身就是 `102` 的归属规则**：一个字符串只属于包含它的那个二进制，
所以"源码说的"和"镜像里跑的"要用二进制里的字面量对上，不能用仓库里读到的源码直接下结论。

对上之后，读法只有三条：

1. **`lshal` 按顺序打三张表**，用空行分隔，每张表前面有一行描述，而那行描述是 `liblshal.so` 里的字面量：
   ```
   1 "All binderized services (registered services through hwservicemanager)"
   2 "All interfaces that getService() has ever return as a passthrough interface;"
   3 "All available passthrough implementations (all -impl.so files)."
   ```
2. **默认列**是 `ListCommand.cpp` 里写的
   `{RELEASED, INTERFACE_NAME, THREADS, SERVER_PID, CLIENT_PIDS}`，
   也就是 `R  Interface  Thread Use  Server  Clients`。
3. **`hash` 只在一处被赋值**（`fetchBinderizedEntry()`），而 `R` 就是 `hash` 的读数
   （`isReleased()`：`hash` 空或等于空哈希 → `" "`，否则 → `"Y"`）。表 2 和表 3 的条目从不设 `hash`。
   于是 **`R = Y` 是只有第一张表才可能出现的标记**。

第三条是全部的关键。它把"这张表是哪张表"变成了一个**可以独立验证**的事实：
既可以用描述行认，也可以用 `R` 列认，两条路互不依赖。

还有一条**必须**一起读的：`lshal` 自己给第二张表的描述里写着
`The Server / Server CMD column can be ignored.` ——
所以 `Server` 列**只在第一张表的行上**读。这正是"不解析"那条旧规矩想避免的坑，
而现在它变成了一个可以照着做的规矩。

---

## 3. 把那次录下来的清单读出来

`evidence/gps-probe-live-2026-09-23.txt` 里那八行，逐字复现如下（左端是 `R` 列）：

```
   Y android.hardware.gnss@1.0::IGnss/default                                                  N/A        N/A
   Y android.hardware.gnss@1.0::IGnss/gnss_vendor                                              N/A        N/A
   Y android.hidl.base@1.0::IBase/gnss_vendor                                                  N/A        N/A
   Y vendor.qti.gnss@1.0::ILocHidlGnss/gnss_vendor                                             N/A        N/A
     android.hardware.gnss@1.0::IGnss/default                               N/A        257    257
     vendor.qti.gnss@1.0::ILocHidlGnss/gnss_vendor                          N/A        257    257
     android.hardware.gnss@1.0::I*/* (/vendor/lib/hw/) (-qti)              N/A        N/A
     android.hardware.gnss@1.0::I*/* (/vendor/lib64/hw/) (-qti)            N/A        N/A    257
```

按 §2 的规则读：

* **前四行 `R = Y`** → 它们**只能**来自第一张表（只有那里会设 `hash`），
  而且 `Y` 意味着 `interfaceChain()` 和 `getHashChain()` 都成功了。
  按名字排序（`android.hardware.gnss@1.0::IGnss/…` → `android.hidl.base@1.0::…` → `vendor.qti.gnss@1.0::…`）
  和 `fetchBinderized()` 里的 `std::map` 顺序一致。
* **第一行就是这次链条需要的那个服务**：`android.hardware.gnss@1.0::IGnss/default`。
  所以 **它是注册的，而且是活的**。
* 它的 `Server` 是 `N/A`：`SERVER_PID` 在 `serverPid == NO_PID` 时打 `N/A`，而 `serverPid` 来自
  `getDebugInfo().pid` —— 说明这个实现没有报 pid（`Thread Use` 也是 `N/A`：
  `getThreadUsage()` 在 `threadCount == 0` 时打 `N/A`，而 `pid` 是 `NO_PID` 时那段 `getPidInfoCached`
  根本不会被走）。这两件事一起解释得通，不需要额外假设。
* **第五、六行 `R` 是空的**，`Server` 和 `Clients` 都是 `257`：这是**第二张表**
  （`serverPid = clientPids[0]`，恰好一个客户端时），也就是 `lshal` 自己说
  "Server 列可以忽略"的那种行。**这一行不能用来判注册** —— 而旧版本连它在哪张表都不知道。
* **最后两行**是 `-impl.so` 的清单（第三张表），`I*/*` 是聚合条目。

**所以那次的答案是"注册了"，而且这个答案在那次开机上就已经躺在归档里了。**

`109` 已经用日志说清了下半段（vendor HAL 跑了、QMI 客户端开成功、适配层被走到）。
现在上半段也清楚了：**UT 要调的那个服务确实在 hwservicemanager 里**。
两段合起来，链条从 UT 的适配层一直到 QMI 都有正面证据 —— 这**不是**"能定位"，
但"门从没被敲过"这个旧说法现在两头都不成立。

---

## 4. 探针改了哪三处

### 4.1 §4 从"拒绝读"改成"有依据地读"

原来的 §4 抓完 `grep gnss` 之后打印一段"这张表的列不解析"。问题不只是它不判，
而是**抓取本身就是有损的**：`grep` 把空行和描述行都吃掉了，而空行正是三张表的分界。
现在抓的是**整份清单**，然后用一个 awk 按 §2 的规则切表。判词只用三条输出：

```
registered=yes | no | unknown
where      = in-table-1 | outside-table-1 | absent
rel        = R 列的原值（Y 或 -）
ran        = lshal 有没有输出（有 / 一个字都没有）
```

最后一项是补上去的，因为"它列出了零条"和"它根本没法被问"是两个不同的阻塞：
`nsenter ... lshal` 什么都不输出时，`n_gnss = 0` 会让判词落到 `no-gnss-listing`，
而那句话读起来像"容器里没有 GNSS HAL" —— **真正的病在仪器上**。
所以现在 §4 会明说"`lshal` 一个字都没输出"，判词那一支也会补一句
"这可能是'问不到'，先把这件事修好再对 HAL 下结论"。变异 `I` 打的就是这一行。

**`unknown` 不等于 `no`，这是这一轮最容易写错的一处。** 如果清单里没有那行描述
（换了一个 `lshal` 构建），三张表就分不开，那时"行不在第一张表"完全可能是"我以为它不是第一张表"。
所以锚点行**先判**，锚点不在就直接 `unknown`，任何行都不再被相信。第一版的代码把
`outside-table-1` 直接映射成 `no`，锚点缺失时会把一张真在第一张表里的行读成"没注册" ——
这正是变异 `A` 要打的地方（§5）。

### 4.2 §6 多一支，并把一支死分支挪上来

判词的分级现在是这样（按链条被走过的顺序，先命中者胜）：

```
no-container        容器不应答
wrong-namespace     daemon 在 HOST PID namespace
trust-store-refused 信任库拒绝了
qmi-open-failed     到达 vendor HAL，而 QMI 客户端开失败
reaches-vendor-hal  到达 vendor HAL、客户端开成功、适配层被走到        → 唯一 exit 0
gnss-not-registered 什么都没跑，而清单说没有服务可调                   ← 新
no-gnss-listing     什么都没跑，而且连一行 gnss 都没有                 ← 上移
daemon-only         daemon 建了 provider，没有请求到达 HAL
no-evidence         这一次开机说不清断在哪
```

`gnss-not-registered` 的位置有理由：日志说的是**什么跑过**，清单说的是**UT 能碰到什么**。
一条证明 vendor HAL 跑过的日志比一张清单更深，所以 `qmi-open-failed` 和 `reaches-vendor-hal`
排在它前面、**不被它推翻**；反过来，当两份日志都是沉默的，清单是**唯一**还能指出断点在哪的东西。

`no-gnss-listing` 上移的理由更直接：它原来排在 `daemon-only` 后面，
而只要 daemon 打过**任何**一行 provider 日志（大多数它跑起来过的开机都会），
判词就永远是 `daemon-only` —— 哪怕容器里根本没有 GNSS HAL。**那一支在原位置几乎是死代码。**
"daemon 跑了但没东西到达 HAL"在那时是它的**后果**，不是更好的名字。
现在 `daemon-only` 那一支还会明说"容器的 IGnss/default 是注册的"，因为能走到那一支
就说明 `gnss-not-registered` 没有命中。

另外，判词的名字现在单独打一行：

```
   VERDICT: reaches-vendor-hal
```

散文没法被 grep，但归档下来的那次 capture、和任何回头看的人，需要一个稳定的词。

---

## 5. 离线验证：129 检查，九次"必须失败"

`scripts/host/zl1-gps-selftest.sh`（证据：`evidence/gps-registration-selftest-2026-09-23.log`）。
新增第 11 节，全部建在一个**真形状**的 fixture 上：

* 那份 fixture 不是编的：三行描述**逐字取自** `liblshal.so`，默认行就是那次录下来的清单。
  旧版本喂给 stub 的是**一行裸的服务名** —— `lshal` 从来不会打成那样 ——
  所以它当时断言的东西不可能是关于一份真清单的。
* 每个场景只动**一件事**：行在哪张表里，或者锚点行在不在。

| 场景 | `registered` | 判词 |
|---|---|---|
| 行在第一张表（= 录到的那次） | `yes` | `reaches-vendor-hal`（exit 0） |
| 只在第二张表 | `no` | 日志沉默时 → `gnss-not-registered` |
| 按名字哪儿都没有，但第一张表确实被读到 | `no` | 同上 |
| 没有锚点行（另一个 lshal） | `unknown` | 不许是 `no` |
| 第一张表里的行，`R` 是空的 | `yes` | 并说"被列出了，但没确认活着" |
| 全清单没有 gnss，`lshal` 有输出 | — | `no-gnss-listing`（exit 1），直接指 HAL |
| `lshal` 一个字都没输出 | `unknown` | `no-gnss-listing`，但**补一句**"这可能是问不到" |

变异测试（一个不会失败的 harness 什么也证明不了）：

| 变异 | 结果 |
|---|---|---|
| A 去掉"锚点先判" | `123 pass / 5 fail` |
| B `outside-table-1` 读成 `yes` | `124 pass / 4 fail` |
| C 去掉 `absent` 那一支 | `127 pass / 1 fail` |
| D 判词名字那行 | `126 pass / 2 fail` |
| E `Server` 从另一支读（对调 `hsrv`/`osrv`） | `127 pass / 1 fail` |
| F `no-gnss-listing` 挪回 `daemon-only` 之后 | `126 pass / 2 fail` |
| G `R` 列恒读成 `Y` | `126 pass / 2 fail` |
| H `R` 列从另一支读（对调 `hrel`/`orel`） | `127 pass / 1 fail` |
| I 去掉"`lshal` 问不到"那一句 | `127 pass / 1 fail` |

（基线：`129 pass / 0 fail / 1 skip`。）

**E 和 G 一开始是没有牙的**，两次都值得记下来，因为失败的形状不一样：

* **G 是真的漏洞**：`R` 列恒读成 `Y`，而当时**没有任何场景**在第一张表里放一个 `R` 为空的合法行，
  所以这个错值没有地方显形。补法不是加断言，是加场景（`unreleased`）。
* **E 一开始是我写坏的变异**：它想测"`Server` 列从哪张表读"，却换成了一段 `sed`，
  而那段 `sed` 在当时的 `live` fixture 上**恰好**也算出 `257`，于是"变异没失败"看起来像漏洞。
  真正的毛病在 fixture：那个场景原来用的是录制里的 `257/257`，**第二张表也带 257**，
  所以一个读错表的实现照样能打出 257。把数字换成**全清单唯一**的 `909 / 7/9` 之后，
  错实现再也打不出来；同时把变异换成直接对调两支（`hsrv`/`osrv`），两次都失败了。
  **一个期望值能被错误实现算出来的 fixture，不是测试。**

---

## 6. 顺手关掉一个漂移：健康检查引用的检查数

`scripts/host/zl1-health-check.sh` 是设备回来时**第一个被读**的东西，而它给每个 harness 都写着
一个**检查数**。那些数字是手打的，所以每加一条断言就会过期 —— 而**读者最先看到的那份东西里
写着一个不实的数字**，正是这个项目反复在找的同一族缺陷：一个仪器的报告和它的对象对不上。

它已经发生过：GPS 那一行还写着 99，而那个 harness 早就涨过 120 了（`109` 那一轮加断言时漏改的），
**而且没有任何机制会注意到**。所以现在**健康检查引用到的每一个 harness 都自己核对这条引用** ——
不需要设备，因为在跑到那一步时 `PASS`/`FAIL` 已经定了，harness 知道自己的总数：

```sh
cited=$(sed -e 's/always "/ /g' -e 's/"$//' "$HEALTH" | tr '\n' ' ' |
          sed -n 's/.*<harness>.sh[ ,(]*\([0-9][0-9]*\) checks.*/\1/p')
[ "$cited" = "$((PASS + FAIL + 1))" ] || bad "..."
```

（`+1` 是这条断言自己 —— 读者引用的是 harness 最后打出的那个 `pass=`，所以它必须把自己算进去。）

六个被引用的 harness 都加上了这一条。**它有牙**：把健康检查里 thermal 的引用从 45 改成 99，
那个 harness 立刻 `pass=44 fail=1` 并指名说改哪个文件。

## 7. 这一篇**不**证明什么

* **不证明 GPS 能用。** 这一轮证明的是"服务注册了、而且活着"—— 是它上面几层的正面结论，
  不是"能拿到定位"。至今没有任何一次定位被拿到过。
* **不证明那次调用是客户端发起的。** `109` 已经静态追到"`set_position_mode` 没有直接调用点，
  要靠数据流读"，这一轮没有推进它。
* **不证明注册是"现在"注册的。** 读的是 **2026-09-23 14:55 那次开机**录下来的清单。
  设备在 EDL 里已经很久，下一次开机要重新读一遍。
* **不证明这台设备能回来。** 仍在 EDL，出来只能物理长按电源 10–20 秒（`49` §6），
  不会跑任何 QDL/firehose 工具。

---

## 8. 设备状态

设备在 **Qualcomm EDL**（`05c6:9008` / `QUSB__BULK`，port 3-3，无序列号）。整轮只读过主机上的
`/mnt/data/halium-zl1-build/`、`/mnt/android-sys-test`（只读挂载）和那份归档；
**没有写任何分区或 boot，没有跑 QDL/QFIL，没有重启，没有拔插**。
识别目标按序列号前缀 **`33e80afe`**；总线上另一台设备 **`4a2fe00b`** 必须忽略。

下一步仍然是物理的：长按电源 10–20 秒，等 RNDIS 回来，然后
`scripts/host/zl1-post-recovery-capture.sh` —— 它的 `05` 现在会把注册状态和判词一起留下。
