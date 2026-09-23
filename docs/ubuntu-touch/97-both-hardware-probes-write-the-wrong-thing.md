# 97 — 两个硬件探针各有一处"该写的地方写错了"：一个把授权说没了，一个多写了一份

**日期**: 2026-09-23
**状态**: 纯离线的一轮（设备在 EDL，`05c6:9008` / port 3-3，与 `86`–`96` 同）。这一轮验的是 **GPS 与指纹这两件"还没有任何修复"的硬件**在设备回来后会跑的那两个探针，抓到两个真缺陷并修掉。设备整轮没有测量。

**接续**: [`82`](82-the-gps-line-read-the-source-and-the-rootfs.md)（GPS 的两个杠杆）、[`83`](83-the-fingerprint-einval-is-a-missing-directory.md)（指纹 `SYS_EINVAL` 是一个缺失的目录）、[`93`](93-gps-the-door-is-a-client-request-and-the-two-levers-are-dead.md)（门是客户端请求，gate 1 是一条真短路）、[`95`](95-the-first-commands-after-recovery-are-offline-verified.md)（可重跑 harness 的做法）、[`96`](96-three-thermal-units-in-one-snapshot.md)（上一轮，同一手法用在发热仪器上）。证据原文在 `docs/ubuntu-touch/evidence/loc-fp-probes-2026-09-23.log`。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 为什么是这两个脚本？ | 它们是**仅有的两件还没有任何修复的硬件**（GPS、指纹）的仪器，是恢复顺序里的第 `2b` 与 `3` 条 |
| 它们的共同点？ | 每一个都**恰好有一个会写设备的模式**，其余全是只读。所以最要紧的性质，是主机上"不会意外观测到"的那一条：**没被要求就绝不写** |
| 第 1 个缺陷？ | `zl1-location-request.sh --quiet --enable-testing` **静默安装了一个权限旁路**。警告走的是 `say()`，而 `--quiet` 正是把它关掉的那个开关 |
| 为什么这条严重？ | 那个模式装的是 gate 1 旁路：装好之后**设备上任何程序都能取到本机位置**。而"不告诉操作者他正要交出什么"恰恰是 `--quiet` 最不该做的事 |
| 第 2 个缺陷？ | `zl1-fingerprint-probe.sh --create-store-dir` **把两个候选路径都建了**，而它自己第 2 节刚刚判定 biometryd 走的是哪一个 |
| 为什么那条严重？ | 在一个 api_level 说 `<=27` 的设备上建 `/data/vendor_de/0/fpdata`，是**一份没有任何东西会去读的写入**；而脚本印出的 `UNDO` 只提了其中一个——**它唯一被允许做的那次写，可能留下一条任何输出行都没提到的痕迹** |
| 怎么修的？ | 一个 `--quiet` 关不掉的 `warn()`（写 stderr），以及"第 2 节决定路径、第 5 节只写那一条"，外加把**没建的那条**和**为什么没建**一起印出来，`UNDO` 与实际写入的路径严格对应 |
| 怎么证明修的是这个？ | 新 harness（**84 项**）**先在修复前的脚本上跑了一遍**：7 条红，逐条落在这两个缺陷上（§2）。在同一个版本上通过又通过的 harness 什么都没证明 |
| 手法上和前几个 harness 有什么不同？ | 这一个**不桩住写操作**：把两个写入**目的地**改到假根树里，让真的 `mkdir`/`cat >`/`rm` 去执行，然后断言**文件本身**（"存在，而且内容恰好是那一行 `Environment=`"）。只有不该动的（`systemctl`）和要替一台不在场的设备回答的（`lxc-info`/`nsenter`/`logcat`/`getprop`/`qmlscene`/`sleep`）是桩 |
| 动设备了吗？ | 没有。假 `/proc`、假 HAL 进程、假容器、假 logcat 都是编的 |

---

## 2. 两个缺陷，和 harness 是怎么把它们钉住的

跑 harness 的顺序很重要：**先把 harness 对着 `git show HEAD:` 出来的修复前脚本跑一遍**。7 条红，正好分成两组：

```
FAIL  --quiet --enable-testing STILL says it is installing a permission bypass
FAIL  and still says what that means
FAIL  and still names the way back
FAIL  and NOT the other candidate (the defect this round fixed)
FAIL  and it says which path it deliberately did not create
FAIL  and not the <=27 path
FAIL  with the matching undo
pass=77 fail=7
```

### 2.1 `--quiet` 把授权说明说没了（`zl1-location-request.sh`）

这个脚本有三个只读模式和一个会写的模式，而那个会写的模式是这个项目里**唯一会削弱用户安全**的动作：

```sh
# 改前：走 say()，于是 --quiet 下这三行一个字都不打，旁路照样装上
say "This installs a PERMISSION BYPASS: ..."
mkdir -p "$DROPIN_DIR" || { ...; exit 1; }
cat > "$TESTING_DROPIN" <<'EOF'
```

修法是一条规则，而不是一个特例：

```sh
say()  { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
# The consent notice, which --quiet must not silence. ... "Be quieter" means fewer read-only
# findings, never "do not tell me what I am about to give up"; the same rule the post-mortem
# harness exists to enforce on the other side (a mode that acts must be the one thing that
# still speaks).
warn() { printf '%s\n' "$*" >&2; }
```

写 stderr 是有意的：`--request` 那种把 stdout 重定向走的用法，仍然看得到这行。harness 里同时钉了**反面**——`--quiet` 确实把只读分析压掉了（断言输出里没有 `is-enabled`/`ExecStart`/`drop-ins`），所以这条绿不是因为"`--quiet` 坏了"，而是因为**只有那一行没被压掉**。

### 2.2 `--create-store-dir` 多写了一份（`zl1-fingerprint-probe.sh`）

这个脚本整个存在的理由，就是**两个候选路径是两个不同的答案**（`83`：biometryd 按 `api_level <= 27` 硬编码，`<=27` 走 `/data/system/users/0/fpdata/`，否则 `/data/vendor_de/0/fpdata/`）。而它的第 2 节辛苦判定了走哪条，第 5 节却：

```sh
# 改前：两条都建
for p in /data/system/users/0/fpdata /data/vendor_de/0/fpdata; do
  ...
done
echo "   UNDO: nsenter -t $A -m -- rmdir /data/system/users/0/fpdata   (only if it is still empty)"
```

于是：**一条不会被任何东西读取的写入**（在 `<=27` 的机器上建 vendor_de 那条），加上**一句只覆盖其中一条的 UNDO**。这正是 `95` 第 3 个 bug 的同族形状——一段代码没有做它字面上说的事，而且**静默**。

修法是把"哪一条"变成一个变量，让第 5 节不可能和第 2 节不一致：

```sh
# TARGET is the single path this run decided on, and section 5 writes only that one. It used to write
# BOTH candidates while printing an undo for one of them, in a script whose entire point is that the
# two paths are different answers ... Deciding it here means section 5 cannot disagree with section 2.
TARGET=""
...
  case "$TARGET" in
  /data/system/users/0/fpdata) OTHER=/data/vendor_de/0/fpdata ;;
  *)                           OTHER=/data/system/users/0/fpdata ;;
  esac
  ... 只对 $TARGET 做 mkdir/chown/chmod ...
  echo "   NOT created: $OTHER (section 2 says biometryd passes $TARGET, so nothing would ever read the"
  echo "   other one; if the evidence later contradicts section 2, make it by hand:"
  echo "     nsenter -t $A -m -- mkdir -p $OTHER"
  echo "   UNDO: nsenter -t $A -m -- rmdir $TARGET   (only if it is still empty)"
```

harness 把**两个分支都驱动**（`api_level` 27 与 29，通过桩 `nsenter` 回答那两条 property），并断言：

* `api_level=27` → 只有 `mkdir -p /data/system/users/0/fpdata`，**没有** vendor_de 那条；
* `api_level=29` → 反过来；
* property 读不出来 → `atoi("")=0`，落在和一台正确的 Android 8 相同的路径上（这是 `83` 已经建立的结论，现在被钉住）；
* 目录已存在 → 不 `mkdir`、不 `chown`、不 `chmod`，并且**不谎称创建了什么**；
* 没有容器（拿不到 HAL 的 uid）→ 退出 1，**一个写入动作都没有**。

---

## 3. 这个 harness 和前面几个的差别：不桩写操作

前面四个 harness 的"什么都没写"是用**动作日志**证明的（PATH 前面的桩记录自己被调用）。这一个反过来做：

* 把**写入目的地**（drop-in 目录、QML 路径）改到假根树；
* 让真的 `mkdir` / `cat >` / `rm` 执行；
* 然后断言**文件本身**：`zl1-testing.conf` 存在、内容包括 `[Service]` 和**恰好那一行** `Environment=TRUST_STORE_PERMISSION_MANAGER_IS_RUNNING_UNDER_TESTING=1`、且目录里除它之外没有新增；`--disable-testing` 之后这个文件**真的消失**，而 `zl1-dummy.conf` **还在**。

这比"某个桩被调用过"强：它对这次旁路安装的**内容**下了断言，而那正是唯一要紧的东西。桩只留给两类东西——**不该动的**（`systemctl`，它同时要替设备回答 `show -p ExecMainPID`/`ExecStart`/`is-active`/`status`，否则"桥接库在不在 daemon 里"那一段根本走不到）和**要替一台不在场的设备回答的**（`lxc-info` 给容器 pid、`nsenter` 给两条 property 和"这个路径存在吗"、`logcat` 给那几行计数、`getprop`/`qmlscene`/`sleep`）。

一条因此被钉住的细节：`systemctl` 在**每个**模式里都会被调用（`is-active`、`show`、`status` 都是只读查询）。所以断言不是"没调用 systemd"，而是**"没有任何会改变设备的 systemd 调用"**（`daemon-reload`/`restart`/`start`/`stop`/`mask`/…）。把只读查询也算进去的版本会立刻误报——这是写这个 harness 时第一版就犯的错，记在这里因为它是最容易抄错的一条。

---

## 4. 这一轮**不**证明什么

* **对设备的结论：零。** 设备在 EDL；假 `/proc`、假 HAL 进程（`/proc/4242/cmdline` 里那个 `biometrics.fingerprint@2.1-service`）、假容器、假 logcat 全是合成的。尤其：`MISSING /data/system/users/0/fpdata` **是假根树的回答，不是设备的回答**——`83` 那个问题仍然欠着。
* **权限旁路没有被证明真的能开 gate 1。** 被证明的是它**会宣告自己**、而且**只写一个文件、内容只有一行**。`93` §3.4 是从安装好的库里把短路读出来的（离线事实），但一行**放错目录的 drop-in 是静默失效的**——这正是下面那条。
* **drop-in 目录名这个坑只被当作文本钉住**（harness 只断言 `${UNIT}.d` 在改写后仍然存在）。`lomiri-location-service.d/` 少个 `.service` 就是 systemd 永远不会读的目录，和当初 `update-machine-info-from-deviceinfo.d` 那个坑一模一样，而**主机上没有任何办法证明它是对的还是错的**——只有到了设备上 `systemctl cat` 才能说。
* **`--request` 的 Qt 客户端是桩**：断言的是 harness 那几行 `ZL1POS` 原样透传，不是真客户端能拿到 session。那一次测量仍然欠设备，也正是 `2b` 那一行要问的问题。

---

## 5. 复现

```sh
# 全部在宿主机上，只需要 /bin/sh、sed、awk、find
sh scripts/host/zl1-loc-fp-selftest.sh          # 84 项
sh scripts/host/zl1-loc-fp-selftest.sh --keep   # 留下假根树、改写后的脚本、桩目录

# 先证明 harness 真的在测这两个缺陷：把它对着修复前的脚本跑一遍
git show HEAD~1:scripts/device/zl1-location-request.sh > /tmp/old/zl1-location-request.sh

# 回到设备之后，这两条就是第 2b / 3 项
sh scripts/device/zl1-location-request.sh --status      # 只读：三个 gate 各在什么状态
sh scripts/device/zl1-location-request.sh --request     # 真的去要一次位置
sh scripts/device/zl1-fingerprint-probe.sh              # 只读：那条路径在 HAL 眼里存不存在
sh scripts/device/zl1-fingerprint-probe.sh --create-store-dir   # 唯一会写的模式，只建它判定的那一条
```

| 文件 | 作用 |
|---|---|
| `scripts/host/zl1-loc-fp-selftest.sh` | 新增。84 项检查，覆盖两个探针的每个模式：只读、授权说明、写入内容、UNDO 与写入路径的对应、guard、flag 面 |
| `scripts/device/zl1-location-request.sh` | 修：授权警告改走 `warn()`（stderr，`--quiet` 关不掉）；头部记下这条规则 |
| `scripts/device/zl1-fingerprint-probe.sh` | 修：第 2 节定出 `TARGET`，第 5 节只写那一条，印出没建的那条及原因，`UNDO` 与实际路径一一对应；头部同步 |
| `docs/ubuntu-touch/evidence/loc-fp-probes-2026-09-23.log` | 这一轮的原始输出：修复前脚本上的 7 条红、两处修复的原文、84 项全文、以及"不证明什么" |
| `docs/ubuntu-touch/97-*.md` | 本篇 |
