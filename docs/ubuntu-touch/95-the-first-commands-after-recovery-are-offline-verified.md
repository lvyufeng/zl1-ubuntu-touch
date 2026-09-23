# 95 — 设备回来后的前几条命令，现在是离线验过的

**日期**: 2026-09-23
**状态**: 纯离线的一轮（设备在 EDL，`05c6:9008` / port 3-3，与 `86`–`94` 同）。这一轮没有产生任何新的设备结论——**它产生的是"回来那一刻不会因为脚本自己的 bug 浪费掉"。**

**为什么这件事值得单独做一轮**：设备在 EDL 里待着的时候，"下一次开机"是**稀缺资源**，而且有几样东西**只在那一次开机里读得到**：

* `/sys/fs/pstore` 里上一次死亡的记录（`86`：pstore 是唯一活过复位的那份证据，而要再拿到它得再死一次）；
* 这一轮 netwatch 日志给的 keeper 退役判语（`94`：只有 `netwatch-configured` 才授权杀 keeper，而抓错会丢 SSH）;
* kmsg 环大约一分钟就绕一圈（`58`），所以 t≈2 秒那些行只存在于一份很早的快照里。

而"前几条命令"恰好是三个**没在真机上完整跑过一次**的脚本：`device/zl1-edl-postmortem.sh`（健康检查第 0 条）、`device/zl1-boot-address-check.sh`（第 0b 条，它决定第 0d 条能不能做）、以及 `device/zl1-orientation-axes.sh`（第 1b 条，只读，但决定性那次跑要一个人拿稳手机）。两个脚本此前都只用**一次性**的合成测试跑过：`86` §5 记着手工跑的 5 个 case、`88` 记着 4 份日志，**都不可重跑**——而那两次各抓到过真 bug（`86`：一个反引号让脚本真的去执行 `reboot edl`；`94`：按 cmdline 子串匹配把测试用的 shell 自己杀了）。

**这一轮把一次性变成可重跑**：三个 harness（10 + 34 + 32 项检查），**重跑之后又抓到三个真 bug**，三个都在"回来那一刻要跑的那条链"上；第三个 harness（orientation 探针，决定性的那次跑需要一只手拿手机）**一个 bug 都没抓到**，那也是一个结果（§3.3）。

**接续**: [`86`](86-edl-has-a-cause-a-panic-and-the-evidence-survives.md)（为什么 panic 会进 EDL、以及 pstore 是唯一活着的那份证据）、[`88`](88-the-addresses-are-ours-now-not-only-the-keepers.md)（地址判语的三个结论）、[`94`](94-retiring-the-v63-debug-keeper-is-a-kill-not-a-unit-edit.md)（那三个结论用来授权什么）、[`58`](58-the-secure-world-refused-and-the-sensors-went-with-it.md)（环一分钟绕一圈）、[`85`](85-is-the-device-back-is-one-command-now.md)（健康检查是回来后的第一条命令）。证据原文在 `docs/ubuntu-touch/evidence/recovery-chain-selftests-2026-09-23.log`。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 两个"回来就跑"的脚本验过吗？ | **现在验了，而且是可重跑的**：`host/zl1-boot-address-selftest.sh`（6 份合成日志、10 项）和 `host/zl1-edl-postmortem-selftest.sh`（7 种设备状态、34 项） |
| 那第三个 harness 呢？ | `host/zl1-orientation-axes-selftest.sh`（桩 `gdbus` + 8 种姿态、32 项）：它**一个 bug 都没抓到**（§3.3），而这本身是个结果 |
| 怎么保证测的是**真脚本**而不是它的复制品？ | 三个 harness 都用 `sed` 把**真脚本**的设备路径改到一棵假根树里，跑那一份；并且各带一道"改写真的生效了吗"的自检（`sh -n` + `D=`/`NETLOG=`/`for f in` 落地检查）。逻辑一个字都没重写 |
| 除了判语还验什么？ | 退出码（它们有含义），以及**什么都没被执行、什么都没被写**：post-mortem 的 harness 在 PATH 最前面放了 23 个"记录自己被调用"的桩（`reboot`/`qdl`/`fastboot`/`mount`/`dd`/`systemctl`/…），并在前后对假根树做 `find -printf '%p %s %T@'` 快照对比 |
| 重跑抓到的第 1 个 bug？ | **每一个"取值型"参数在缺值时都会直接终结脚本**：`--log` 放在最后 → `2: parameter not set`（dash）/ `$2: unbound variable`（bash）。链上一共 5 个脚本有这个问题 |
| 第 2 个？ | `zl1-boot-address-check.sh` 报 netwatch 的 unit 状态时会**打两行**——因为 `systemctl is-active` 会打印 `inactive` **并且**返回非 0，后面的 `\|\| echo` 于是也触发了。停着的 netwatch 正是操作者最需要看清的那种情况 |
| 第 3 个？ | `zl1-edl-postmortem.sh` 的**兜底快照查找从来没工作过**：`ls -tr "$K"/boot-*/` 少了 `-d`，于是它列的是归档目录的**内容**，循环拿到的是裸文件名，下一条 `ls` 在**调用者的当前目录**里跑（演示里它命中了宿主机一个无关的 `.log`） |
| 为什么第 3 个重要？ | 那条路要找的是驱动自己 t≈2 秒的两行，脚本自己把它们称作"这个脚本能找到的最有价值的东西"（`Failed to set secure DLOAD mode` 把整条 hazard 从"武装"降级成"惰性"）。抓错文件是**静默**的，因为"快照里没有这行"是句正常输出 |
| 这是新 bug 吗？ | 不是——和 `86` §5 的第 2 个 bug **同一族**（`ls -t` 给的是裸文件名、`grep` 在错的目录里跑）。当时修掉了 §3 那一处，**漏了它的孪生兄弟**在 §1b 的兜底里 |
| 动设备了吗？ | 没有。三个 harness 都在宿主机上，假根树里的设备状态是编的；没有分区写、没有 boot 镜像写、没有 QDL/firehose、没有重启 |

---

## 2. 三个 bug，和每一个是怎么被"跑一遍"抓到的

### 2.1 取值型参数缺值 = 整条命令什么都不做

修之前，在宿主机上、两种 shell 里都复现过：

```sh
$ sh scripts/device/zl1-boot-address-check.sh --log
scripts/device/zl1-boot-address-check.sh: 42: 2: parameter not set      # rc=2
$ bash scripts/device/zl1-thermal.sh --seconds
scripts/device/zl1-thermal.sh: line 49: $2: unbound variable            # rc=1
```

`set -u` 下 `$2` 未绑定就是退出。报错里那个 `2` 是 shell 自己的参数名，**不是那个 flag**，而且脚本一行都没跑。放在"回来后的第 4 条命令"这种位置上，就是那次开机白跑一次。

修法是同一个惯用法：把 `"$2"` 换成 `${2?message}`，链上每一个取值型 flag 都改，并且在宿主机上逐条验过：

| 脚本 | flag |
|---|---|
| `device/zl1-boot-address-check.sh` | `--log` |
| `device/zl1-gps-probe.sh` | `--seconds` |
| `device/zl1-orientation-axes.sh` | `--seconds`、`--interval` |
| `device/zl1-thermal.sh` | `--seconds`、`--top`、`--hold` |
| `host/zl1-camera-app-test.sh` | `--seconds`、`--run-seconds`、`--extra-args`、`--outdir` |

**故意用 `${2?...}` 而不是 `${2:?...}`**：缺值时要报"缺什么"，而显式给空值（`--extra-args ""`）的行为**和以前一模一样**。逐条验的是三件事：不给值 → 一句点名 flag 的错误 + rc 2/1；给值 → 解析照旧、脚本继续；`--log ""` → **没有任何 shell 级报错**（address check 随后说日志读不到，这是对的）。

### 2.2 `systemctl is-active` 会又打印又失败

```sh
# 改前：非 0 退出让 `|| echo` 也触发了，于是打两行
say "... unit: $(systemctl is-active zl1-netwatch 2>/dev/null || echo '<not a unit here>')"

# 改后：先捕获，再给默认值
u=$(systemctl is-active zl1-netwatch 2>/dev/null)
say "... unit: ${u:-<not a unit here>}"
```

只在 unit **不是 active** 时现形——也就是操作者最该看清的那种状态。

### 2.3 兜底快照查找：`ls -tr` 少了 `-d`

`zl1-edl-postmortem.sh` §1b 的那两行：

```sh
early="$(ls -tr "$D"/boot-*.log 2>/dev/null | head -1)"
[ -n "$early" ] || early="$(ls -tr "$K"/boot-*/ 2>/dev/null | while read -r d; do
                             ls -tr "$d"*.log 2>/dev/null | head -1; done | head -1)"
```

`ls -tr "$K"/boot-*/` **没有 `-d`**，所以 `ls` 列的不是归档**目录**：只有一个目录时列它的内容，有多个时先打 `dir/:` 头再列内容。两种情况下循环体拿到的都是**裸文件名**，接着 `ls -tr "boot-0002.log"*.log` 在**当前工作目录**里执行。演示（一次性小树，每个归档一个文件）：

```
$ ls -tr "$K"/boot-*/            # 脚本写的：
      /tmp/lsdemo/keep/boot-bbbb/:
      boot-2.log
      /tmp/lsdemo/keep/boot-aaaa/:
      boot-1.log
$ ls -dtr "$K"/boot-*/           # 应该是的：
      /tmp/lsdemo/keep/boot-bbbb/
      /tmp/lsdemo/keep/boot-aaaa/
$ 按原样喂循环 -> 当前目录里一个无关的 .log（或者什么都没有）：
      v51-recovery-watch-20260611T095059Z.log
$ 用 -dtr 喂循环 -> 最早的归档快照，正如本意：
      /tmp/lsdemo/keep/boot-bbbb/boot-2.log
```

注意按原样那一行**拿回来的不是错误、也不是归档，而是当前目录里一个无关的 `.log`**。它的具体名字不重要也不可复现（`ls -tr` 按 mtime 排序，谁赢取决于目录内容和时钟）——重要的是它是**静默**的：`early` 要么为空，要么是随便一份日志，而 §1b 的四条 `grep` 就会去错的文件里找。修法就是一个字符 `-d`，写在旁边的注释里说明原因；harness 里 C（本次开机的快照）和 C2（归档里的那份）**分开两个场景**钉住，兜底这条路不会再悄悄烂掉。

### 2.4 这个 glob 错误在别处还有吗

全树扫过一遍（`ls` 带 flag、操作数是 `*/`、flag 里没有 `d`）：**唯一命中就是上面刚加的那句注释**。`device-readonly-inventory.sh` 里剩下的那条 `ls -l /dev/block/platform/*/by-name` 是"就是要列内容"，不是同一回事。

---

## 3. 三个 harness 各自钉住了什么

**3.1 `host/zl1-boot-address-selftest.sh`（6 份日志 / 10 项）** —— 判语授权的是"杀 keeper"（`94`），所以三个结论加开机边界都要钉住。其中两份日志存在的理由：

* 每个 netwatch 日志行都以写入时的 uptime 开头，而 uptime **每次开机归零**，所以一份跨两次开机的日志里是大数字后面跟小数字——**只有 `netwatch start` 边界能把它们分开**；
* C：最新那次开机既没有 `ADDRS:` 也没有 heal，而同一文件里**更早**那次开机有 `ADDRS:`。读错段落就会在一次"其实是 keeper 干的"开机上判出 `netwatch-configured`——**这是唯一一个会丢 SSH 方向的错**；
* D：镜像场景。最新那次干净、更早那次 heal 过；早先的 heal 不许漏进来把它变成 `heal-first`。

另外还把写 harness 时顺带发现的两件事钉住了：netwatch 进程年龄必须从 `/proc/<pid>/stat` 的**第 22 字段**算、且要先剥掉带括号的 comm（`81` 的坑；uptime 412、starttime 10000 ticks 必须读成 312 s）；以及"装上那份构建里 `ensure_addrs()` 没了"这个分支。

**3.2 `host/zl1-edl-postmortem-selftest.sh`（7 种状态 / 34 项）** —— 其中 C 与 C2 是同一个状态的两条到达路径，C2 就是第一次跑就红了的那个。F（pstore 目录和 kmsg 目录都不存在）额外用 `notwant` 断言它**不能说 FOUND**、也**不能把读不到说成没有**——这正是 `86` §7 承诺的性质，也是"post-mortem 是证据还是故事"的分界线。

**3.3 `host/zl1-orientation-axes-selftest.sh`（8 种姿态 / 32 项）：orientation 探针，一个 bug 都没抓到——这也是结果**

`device/zl1-orientation-axes.sh` 回答的是用户报过两次的"它老是横屏"（`70`/`91`/`92`），而它的 `AXES-SWAPPED` / `AXES-INVERTED` 判语是**唯一**授权去试 accelerometer 矩阵的东西。决定性的那一次跑**需要一个人**：手机拿稳、竖屏朝上、屏幕对着自己，坚持整个窗口。所以这里一个解析 bug 浪费的是**人的一步**，不只是命令——而这个脚本几乎全是解析器：它调 `gdbus`，然后用 sed/awk 从一个回复里抠出 uint32、从另一个里抠出三个浮点（`ov_of`、`xyz_of`、以及挑 |g| 轴的 awk），判语只是这些值数出来的计数。

harness 在 PATH 最前面放一个桩 `gdbus`（`loadPlugin`、`requestSensor` 和两次 `Properties.Get` 的回复都由文件提供，所以一个场景就是写一次文件），然后同时检查判语、退出码、以及**人要看的那张表**。32 项：4 配 `--portrait-up` → `AXES-OK`（exit 0）；2/1 配 g 落在 x 上 → `AXES-SWAPPED`（exit 3，也是唯一授权改动的那个判语，所以两个方向都断言过：`AXES-OK` 那次额外断言**不许**说 SWAPPED）；3 → `AXES-INVERTED`（exit 4）；6 配 `--flat-up` → 文档里那个"平的不能决定任何事"的结论（exit 0）；同一个 6 配 `--portrait-up` → exit 5（"Not upright"）；xyz 回复解析不出来 → exit 1（就是当初抓出这个脚本第一版的那个守卫）；标点漂移（`(<uint64 N>, 4)`）→ `ov_of` 的兜底仍然读出 4；不给姿态 flag → 只测量、exit 0、**不猜判语**；conf.d 那一段 → matrix 行和 adaptor 行都打出来；`--explain` → 只打印可逆步骤、不跑测量；`--seconds` 缺值 → 一句点名 flag 的话，而不是 shell 中止。

**全部第一次跑就过。** 这件事值得当成一个结论写下来，而不是当成"什么都没发现"：它意味着那张表、那个判语说的是**手机的姿态**，不是解析器的行为。它**不**意味着判语会是 `AXES-OK`——脚本自己的头部就写着平的读数决定不了任何事（qtmir 按设计忽略 FaceUp/FaceDown），决定性那一次仍然需要一只手拿着手机。

顺带看见的一件小事：脚本里定义了 `ts_of`/`age_of`，而 `age_of` 从来没被调用，所以 orientation 回复里那个 uint64 时间戳哪里都不显示。死代码，没有行为可测，不是 bug。

---

## 4. 这一轮**不**证明什么

* **对设备的结论：零。** 两个 harness 都在宿主机上，假根树里的设备状态是编的，设备整轮都在 EDL。
* **不证明真机上的路径就是假根树里那些**：`/sys/module/msm_poweroff/parameters/download_mode`、`/sys/kernel/dload/`、复位之后 `/sys/fs/pstore` 里到底有没有东西、`/userdata/zl1-kmsg/keep/` 里是不是真的躺着那个死掉的 boot——`86` §5 列的这四件，**仍然一件都没在真机上出现过**。
* **不证明这次就是最后的 bug**。它证明的是这三个具体的缺陷没了；下一个会是另一种形状，那时诚实的做法是再加一个场景，而不是把结论说大。
* **命令护栏不是沙箱**：它只证明这 7 种状态下 post-mortem 没有调用那 23 条命令。不在名单里的命令、这些状态没走到的分支，都不在覆盖范围内。它挡住的是这个脚本**已经犯过一次**的那类事故。

## 5. 复现

```sh
# 两个 harness 都在宿主机上，只需要 /bin/sh、sed、find、gzip
sh scripts/host/zl1-boot-address-selftest.sh          # 10 项
sh scripts/host/zl1-edl-postmortem-selftest.sh        # 34 项
sh scripts/host/zl1-edl-postmortem-selftest.sh --keep # 留下假根树和桩目录供查看
sh scripts/host/zl1-orientation-axes-selftest.sh      # 32 项

# 取值型参数的坑，修前修后各跑一次
sh scripts/device/zl1-boot-address-check.sh --log     # 修前：2: parameter not set
bash scripts/device/zl1-thermal.sh --seconds          # 修前：$2: unbound variable

# glob 的坑，单独看
ls -tr  "$K"/boot-*/     # 列内容（有多个目录时还会先打 dir/: 头）
ls -dtr "$K"/boot-*/     # 列目录，才是循环要的
```

| 文件 | 作用 |
|---|---|
| `scripts/host/zl1-boot-address-selftest.sh` | 新增。6 份合成 netwatch 日志、10 项检查，测的是真的 `device/zl1-boot-address-check.sh` |
| `scripts/host/zl1-edl-postmortem-selftest.sh` | 新增。7 种合成设备状态、34 项检查、23 条命令护栏、前后写快照对比 |
| `scripts/host/zl1-orientation-axes-selftest.sh` | 新增。桩 `gdbus` + 8 种姿态、32 项检查，测的是真的 `device/zl1-orientation-axes.sh`（§3.5，一个 bug 都没抓到） |
| `scripts/device/zl1-edl-postmortem.sh` | 修：兜底快照查找改成 `ls -dtr`（§2.3） |
| `scripts/device/zl1-boot-address-check.sh` | 修：`--log` 用 `${2?}`；unit 状态改为捕获后再给默认值（§2.1、§2.2） |
| `scripts/device/zl1-gps-probe.sh`、`device/zl1-orientation-axes.sh`、`device/zl1-thermal.sh`、`host/zl1-camera-app-test.sh` | 修：每个取值型 flag 改用 `${2?}`（§2.1） |
| `scripts/host/zl1-health-check.sh` | 改：第 0b 和 1b 条的说明里各加上"这个判语可以在没有设备的时候先验" |
| `scripts/README.md` | 改：加两行（两个 harness），并在 `device/zl1-edl-postmortem.sh` 那行里记下第 3 个 bug |
| `docs/ubuntu-touch/evidence/recovery-chain-selftests-2026-09-23.log` | 这一轮的原始输出：两个 harness 的全文、两个缺陷的复现、glob 演示 |
| `docs/ubuntu-touch/95-*.md` | 本篇 |
