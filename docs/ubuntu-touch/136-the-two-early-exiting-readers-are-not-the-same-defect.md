# 136 — harness 之外的那类形状：量过之后只有三个有牙，其余是零成本的统一

**日期**: 2026-09-24
**状态**: 本轮**没有碰设备**（设备仍在 Qualcomm EDL，见 §8）。上一轮（[`135`](135-the-wait-said-not-registered-and-the-writer-was-the-one-that-died.md)）修的是一个**确定会误报**的等待；
这一轮去查的是 [`134`](134-the-false-fail-was-in-the-pipeline-s-writer.md) §7 亲手画下的那条边界——"不变量只覆盖 harness，树里还有约 40 个脚本带着同样的形状"。
查的办法是先**量**再改，而量出来的结果把那条边界改了形状：**两个"提前退出的读端"并不一样危险**，`cmd | head` 在任何大于一个管道容量的输入上都会杀死写端（实测 19/20、20/20、50/50、30/30），
而 `cmd | grep -q PAT` 要**大约五个管道容量**才杀得死（318899 字节 30 次全活、348899 字节 30 次全死）。所以树里剩下的那批绝大多数**这次不可能是活的**。
按这个读数，本轮只改了**写端大小不被脚本约束**的三处、以及被真实执行证明无害的四处构建闸门；另外六处**回滚**了。家族 20 个 harness / 2354 → **2360** 检查。

**接续**: [`134`](134-the-false-fail-was-in-the-pipeline-s-writer.md)（这个形状本身；本页是它 §7 画的那条边界）、
[`135`](135-the-wait-said-not-registered-and-the-writer-was-the-one-that-died.md)（同一形状在设备侧的一个**确定**误报）、
[`129`](129-the-family-total-was-typed-and-no-harness-can-see-the-tree.md)（一个没人能看见的数字就是缺陷本身）、
[`110`](110-the-count-in-the-page-was-checked-by-nothing.md)（手打的计数）、
[`126`](126-the-path-was-decided-by-what-the-stub-omits.md)（第二份会过期的策略）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 上一轮留下的边界是什么？ | [`134`](134-the-false-fail-was-in-the-pipeline-s-writer.md) §7：不变量**只**扫 harness（7 个设了 pipefail），树里还有约 40 个脚本带同形状，"今天无害，因为没设 pipefail"——这句后半是错的 |
| 树里到底有多少？ | **96 个脚本设了 `pipefail`**，其中 88 个不是 harness；带"状态被使用"的那种形状（`if cmd \| grep -q P`、`cmd \| grep -q P && …`、`… \|\| …`）的有 **17 个文件、29 处** |
| 两个读端一样危险吗？ | **不。** 实测（本机、bash、管道容量 65536）：`cmd \| head` 在**任何**大于一个管道的输入上都杀死写端（19/20、20/20、50/50、30/30——`head` 读完**一行**就退出）；`cmd \| grep -q PAT` 要在**大约五个管道容量**才稳定杀死（318899 字节 **30/30 全活**，348899 字节 **30/30 全死**） |
| 那 134 的 36 KB 里 4/100 呢？ | 是这件事的尾巴，不是另一件事。134 的 2 MB（200/200）在这条曲线的另一侧 |
| 为什么这决定了这一轮的做法？ | 因为一个点是否危险取决于**模式在不在数据里**——"读端要读到 EOF 才能说没有"的那种检查（`DT_NEEDED` 必须为空）**由构造就是安全的**，而"模式预期存在"的那种才有牙。这是**数据**的性质，不是文本的性质，所以守卫判不了 |
| 那守卫做什么？ | **普查，不是判决**：扫全部非 harness 的 pipefail 脚本、只扫"状态被使用"的那种形状、要求**每个文件的处数**与记录一致。它说得出"这里没有任何一处是在没人看的情况下变过的"，说不出"这一处是危险的"——它不假装 |
| 这一轮改了什么？ | 三处**写端大小不被脚本约束**的状态页标记（`verify-device-online.sh`、`stage2-coldboot-trial.sh`、`stage2-flash-boot-and-verify.sh`），加四处**被真实构建跑过**的闸门（`android-fw-stubs/`、`cfi-shadow/`、`crash-dump/`、`tlsfix/`），加 family runner 自己的选择（`zl1-selftest-family.sh`） |
| 回滚了什么？ | 六处：`host-watch-usb0.sh`、`measure-link-stability.sh`、`fix-ssh-authorized-keys.sh`、`install-netwatch-service.sh`、`hybris-shims/build-compat-layer.sh`、`hybris-shims/build-platform-api-libs.sh`——**按量测是惰性的，而且本轮无法执行验证**。134 §7 拒绝的正是这种改动 |
| 回滚是形式主义吗？ | 不是，它有代价的先例：本轮第一次修 `install-repowerd-ordering.sh` 时，那三行注释落在了 **`REMOTE_STATUS='…'` 这个发给设备的字符串里面**，"writer's" 里的撇号**提前闭合了那个字符串**，整个文件语法坏掉——是 `bash -n` 抓住的 |
| 离线验证？ | meta-harness 90 → **96**（新增 7c 普查：88 个脚本、17 个文件、29 处、三个夹具）、家族 **20 个 harness / 2360 检查 / 全绿**，树未变；四个构建脚本**真的跑过**，全部 `machine: AArch64` 且 rc=0 |
| 动设备了吗？ | **没有。** |

---

## 2. 这一轮的量测：两个读端不是同一件事

[`134`](134-the-false-fail-was-in-the-pipeline-s-writer.md) 把 `grep -q`、`grep -m`、`head` 当成**一类**禁掉了（这个做法本身是对的：禁形状，因为读端提前退出"只能省工作量、永不会改变答案"）。但它没有分开量过它们，而分开量之后差别很大：

```sh
set -uo pipefail
big=$( { printf 'MATCH\n'; seq 1 N; } )
printf '%s\n' "$big" | grep -q '^MATCH$'     # 写端死不死？
```

| 干草堆 | `printf \| grep -q`（写端被杀死） | `printf \| head -1` |
|---|---|---|
| ~28 KB | 0/40 | — |
| ~229 KB | 0/40 | — |
| ~319 KB | **1/30** | — |
| ~349 KB | **30/30** | — |
| ~409 KB … 2.3 MB | 30/30 … 40/40 | 20/20 |
| 任意大小（`n=6000`、`n=200000`） | — | **19/20、20/20** |

两种读端的机制不同，这一点从行数上看就明白：`head -1` 读完**一行**就退出，此时写端几乎一定还在写；`grep -q` 要先把读到的缓冲区扫一遍才决定退出，而缓冲区比一行大得多。
**这一轮没有把机制证到底**（阈值为什么落在五个管道容量而不是一个，我没有解释，也没有断言）；这一页用的是读数，不是模型。

**它改变了"哪些点有牙"这个判断。** `readelf -sW` 在这棵树的产物上只有 1662–2722 字节（`libcfi-shadow-init.so`、`service_stub`、`no-input-stack.so`），
`readelf -dW` 连 libc 都只有 1394 字节（动态段本来就小）；`lsmod`、`lsusb`、`ip addr show`、`adb devices` 都是几 KB；`systemctl cat` 也是。
**全部远在阈值之下。** 唯一**大小不被脚本约束**的是设备发回来的**状态页**（`$http` / `$body`）——它有多大是设备的事。

---

## 3. 边界上的第三个轴：那行是发给设备的字符串

这一轮最实际的一课来自一次**回滚**。`install-repowerd-ordering.sh:93` 看起来是最典型的"host 侧判决"——operator 在主机上跑 `--status`，它决定"这个修复装没装"。
于是按同样的办法改掉，然后：

```
scripts/install-repowerd-ordering.sh: line 156: syntax error near unexpected token `;;'
```

原因不在那一行。**那一行在 `REMOTE_STATUS='…'` 里面**——一个单引号开头、发给设备的字符串：

```sh
REMOTE_STATUS='
DROPIN=/etc/systemd/system/repowerd.service.d/zz-zl1-after-sensorfwd.conf
if [ -f "$DROPIN" ]; then
  ...
fi
# The reading that matters is `systemctl cat`, not the file existing: …
if systemctl cat repowerd.service 2>/dev/null | grep -q "zz-zl1-after-sensorfwd.conf"; then
```

我给这段"host 侧代码"加的三行注释里有 **`writer's`**，那个撇号**闭合了整个设备字符串**。两件事同时成立：

* **那处形状本来是惰性的**——它在**设备的 sh** 里跑，那里没有 pipefail，状态也没人用；
* **而"顺手改一下"不是无害的**：它把文件改坏了。`bash -n` 抓住了（这一轮每次编辑之后都跑它，这是它值钱的一次）。

这正是 [`134`](134-the-false-fail-was-in-the-pipeline-s-writer.md) §5 那句话的具体形态：**用法在文本里看不见**。
所以普查**不判**，只数；而"哪个文件是被留下的、为什么"写在普查表旁边的注释里，三类理由：**在设备字符串里**（惰性，而且改它有过先例）、
读端是 `head -1` 而且写端是几百字节的列表、以及**已经没有 runbook 驱动它的历史阶段机器**。

---

## 4. 改了哪七处（以及为什么是这七处）

判据只有两条，都能说出来：**(a) 写端大小不被脚本约束**，或者 **(b) 这次改动被一次真实执行证明无害**。

| 文件 | 为什么 | 怎么验证的 |
|---|---|---|
| `verify-device-online.sh` | `printf '%s' "$http" \| grep -q "$pat"`——**状态页的大小是设备的事**，脚本不约束它 | 读 + `bash -n` |
| `stage2-coldboot-trial.sh` | 同上（`$body`），而且它决定的是 `container=running/absent`——**这次冷启动试验存在的那个判决** | 读 + `bash -n` |
| `stage2-flash-boot-and-verify.sh` | 同上，加上 `lsmod \| grep -q '^rndis_host'`（**模式预期存在**） | 读 + `bash -n` |
| `android-fw-stubs/build.sh` | `readelf -sW \| grep -q ' _start$'` 等——**模式预期存在** | **真的构建过**，rc=0 |
| `cfi-shadow/build.sh` | 同上（SONAME / INIT_ARRAY / `android_dlopen`） | **真的构建过**，rc=0 |
| `crash-dump/build.sh` | 同上（SONAME / INIT_ARRAY） | **真的构建过**，rc=0 |
| `tlsfix/build-tlsfix.sh` | 五处，全部"模式预期存在"（TLS / INIT_ARRAY / `tls_padding` / `pthread_create` / 无版本定义） | **真的构建过**，rc=0 |
| `host/zl1-selftest-family.sh` | `printf '%s\n' "$b" \| grep -Eq "$ONLY" \|\| continue`——写端只有一个文件名（惰性），但**后果是全树最重的：一个被静默跳过的 harness 就是一个不可能失败的检查**，而那正是 [`129`](129-the-family-total-was-typed-and-no-harness-can-see-the-tree.md) 的病 | 真的跑过 `--only` |

构建闸门那一列值得单独说一句：**它们今天不可能误报**（1662 字节 vs 阈值约 349000），但把它们改掉的成本是零，而它们**能被真实执行证明**——
四个构建脚本本轮各跑了一遍，全部 `machine: AArch64`、rc=0。**能被执行的改动就是能被证明的改动**，这是它们留下、而那六个被回滚的原因。

回滚的六个是**另一种**：`host-watch-usb0.sh`、`measure-link-stability.sh`、`fix-ssh-authorized-keys.sh`、`install-netwatch-service.sh`、
`hybris-shims/build-compat-layer.sh`、`hybris-shims/build-platform-api-libs.sh`。它们的形状按量测是惰性的（写端几 KB），
**而这一轮没有能力执行它们**（hybris 那两个要整棵 Android 树，其余三个要设备或 root）。
[`134`](134-the-false-fail-was-in-the-pipeline-s-writer.md) §7 拒绝的正是这种改动，理由是"改了是纯风格变更"；本页给它补上了另一半理由：**改一个跑不起来的脚本，是把一个惰性的形状换成一个未经验证的 diff。**

---

## 5. 不变量：普查，而不是判决

meta-harness 新增第 7c 节。它做三件事，每件都有一个理由：

```sh
VERDICT_RE='(\|[[:space:]]*(grep[[:space:]]+-[A-Za-z]*q|grep[[:space:]]+-[A-Za-z]*-[A-Za-z]*m|head([[:space:]]|$)))[^|]*(&&|\|\|)|(^|[^A-Za-z])(if|while|elif|!)[[:space:]].*\|[[:space:]]*(grep[[:space:]]+-[A-Za-z]*q|head([[:space:]]|$))'
verdict_sites() { grep -nE "$VERDICT_RE" "$1" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -vE '^[0-9]+:[[:space:]]*(always|say|echo|printf)[[:space:]]+["'\'']' ; }
```

1. **只扫"状态被使用"的形状。** `p=$(cmd | head -1)` 不是判决：调用方读的是**替换的值**，而一个没人看的非零状态什么都不是。
   所以"用法"在这一处**是**文本可见的——条件是三种上下文之一（`if` / `&&` / `||`），这一点与 [`134`](134-the-false-fail-was-in-the-pipeline-s-writer.md) §5 说的"用法看不见"不矛盾：
   134 说的是"这个形状在这个脚本里是否致命"看不见（取决于 pipefail 和调用方），而**这一段正是把判据收窄到"调用方就是条件本身"之后的结果**。
2. **两类行被跳过，理由与 7b 的同一条。** 注释行（每个解释这个缺陷的文件都在注释里引用它）；以及**印出来的字符串**（`always "…"` / `say "…"` / `echo "…"`）。
   第二条不是预设的——**它抓到了这一轮自己写进去的那段话**：我给 health check 加的解释文字被报成"两个新点"。一个会被自己说明书打红的守卫，下场是被删掉。
3. **要求每个文件的处数与记录一致，而不是要求零。** 因为判不了（§2、§3）。它数出来的是 **88 个非 harness 的 pipefail 脚本、其中 17 个文件共 29 处**，并且两个方向都查：
   出现不在表里的文件、表里某文件的处数变了、表里的文件不再是 pipefail 脚本——**三种都报**。

三个夹具，顺序与 7b 相同（一个全红的扫描会过第一条、死在第二条）：带形状的必须被抓到、here-string 的不许被抓到、**写在印出来的字符串里的**也不许。
第三个夹具是为了这一轮那次自打脸：它是用 `@` 占位再 `tr` 组装的（这个 harness 自己也设 pipefail）。

**它不是"判决"这件事本身是要写清楚的**：一个只能报"变过了"的守卫，价值在于**没有任何一处能悄悄出现**，而不是在于它知道哪一处危险。
这一页对"哪一处危险"的答案是 §2 那条曲线，而它是**数据**的性质——写在这里，不写进守卫。

---

## 6. 这一轮**不**证明什么

* **不证明那 29 处都是惰性的。** 曲线说 `grep -q` 要大约五个管道容量才杀死写端，**而那 29 处里有几处的写端大小本轮量不到**（状态页是设备发回来的）。
  它们是**唯一**被留下"有嫌疑"的一类，而这一轮把它们改掉了——所以留下的 15 处（17 个文件里的另外那些，见 §3 的三类理由）都是写端可量、且远在阈值之下的。
* **不证明阈值是 349000 这个数。** 它是这台机器、这个 bash、这一次负载下的读数；**机制没有解释**（为什么是五个管道容量而不是一个），也没有在别的 bash 上测过。曲线本身在 §2，可以被重跑。
* **不证明 `| head` 的那些点被处理了。** 树里非 harness 的 pipefail 脚本中有 **75 处** `| head`，其中状态被使用的按 7c 的判据是**个位数**，全部在设备字符串里或写端是几百字节的列表。
  这一轮**没有改任何一处 `| head`**——而 §2 说它是**可靠**的杀手。这是本页最该被追问的地方：它可靠，但树里没有一处它的状态是有用的。**如果哪天有人写了一个 `if cmd | head -1`，7c 会报出来**，这是这一轮对它的全部承诺。
* **不证明 7c 的判据完备。** 它是**文本**的：一个把管道的状态**间接**用掉的写法（存进变量、隔几行再 `[ "$?" = 0 ]`）不在它的射程里。这一侧没有断言，只有"29 处"这句话被印出来。
* **不证明回滚的那六个文件没有问题。** 它们带着形状，按量测是惰性的——**而这一轮没有能力验证对它们的改动**，所以留原样。这是把"不改"当成一个决定写下来，不是把它当默认。
* **不证明 135 的那个改动在设备上跑得通。** 整轮一次 ssh 都没有。

---

## 7. 设备状态与复现

整轮没有动设备：没有写任何分区或 boot，没有跑 QDL/QFIL，没有重启。设备仍在 **Qualcomm EDL**
（`05c6:9008`，Bus 003 Device 020）。识别目标一律按序列号 **`33e80afe`**；总线上另一台小米
**`4a2fe00b`** 必须忽略。恢复仍然只能靠**物理长按电源 10–20 秒**。

```sh
# 全部在宿主机上，不碰设备。
bash scripts/host/zl1-selftest-family-selftest.sh   # 96 项，含 7c 的普查
bash scripts/host/zl1-selftest-family.sh            # 20 个 harness / 2360 检查

# 这一轮的核心读数：两个读端不是一件事。
set -uo pipefail
for n in 50000 55000 60000; do
  big=$( { printf 'MATCH\n'; seq 1 "$n"; } )
  k=0; for i in $(seq 1 30); do printf '%s\n' "$big" | grep -q '^MATCH$'; [ "${PIPESTATUS[0]}" = 141 ] && k=$((k+1)); done
  printf '  bytes=%-9s grep -q killed=%d/30\n' "${#big}" "$k"
done
big=$( { printf 'x\n'; seq 1 6000; } ); k=0
for i in $(seq 1 20); do printf '%s\n' "$big" | head -1 >/dev/null; [ "${PIPESTATUS[0]}" = 141 ] && k=$((k+1)); done
echo "  head -1 killed=$k/20   (any size above one pipe)"

# 那四个被改过的构建闸门，真的跑得通：
for b in scripts/android-fw-stubs/build.sh scripts/cfi-shadow/build.sh scripts/tlsfix/build-tlsfix.sh; do bash "$b"; done
bash scripts/crash-dump/build.sh --clang "$(command -v clang)"

# 普查自己会不会红（对具名修订，不对 HEAD）：
bash scripts/host/zl1-selftest-family-selftest.sh | sed -n '/== 7c\./,/== 8\./p'
```

| 文件 | 作用 |
|---|---|
| `scripts/host/zl1-selftest-family-selftest.sh` | 改：新增第 7c 节（树级普查：只数"状态被使用"的形状、按文件比对处数、三个夹具、跳过注释与**印出来的字符串**） |
| `scripts/verify-device-online.sh` | 改：状态页标记（写端大小不被约束） |
| `scripts/stage2-coldboot-trial.sh` | 改：`lsmod` / `ip addr` / 状态页的 `container=running` 判决 |
| `scripts/stage2-flash-boot-and-verify.sh` | 改：`lsmod` / `ip addr` / 状态页标记 |
| `scripts/android-fw-stubs/build.sh`、`scripts/cfi-shadow/build.sh`、`scripts/crash-dump/build.sh`、`scripts/tlsfix/build-tlsfix.sh` | 改：把 `readelf … \| grep -q` 换成"读一次、匹配文本"（四个脚本本轮都真实构建过） |
| `scripts/host/zl1-selftest-family.sh` | 改：harness 选择改 here-string（被静默跳过的 harness 是永远不会失败的检查） |
| `scripts/host/zl1-health-check.sh` | 改：meta-harness 的引用 90 → **96**，并补上 7c 的普查、那条曲线、以及设备字符串那一课 |
| `scripts/README.md` | 改：meta-harness 一行 90 → **96** |
| `docs/ubuntu-touch/124-*.md` | 改：家族总数那一行续上本轮的 2365 |
| `docs/ubuntu-touch/136-*.md` | 本篇 |
