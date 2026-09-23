# 100 — 发热修复的另一半（cpufreq）和唯一那份 misc 备份：两个"报告成功但其实没生效"的仪器

**日期**: 2026-09-23
**状态**: 纯离线的一轮（设备在 EDL，`05c6:9008` / port 3-3，与 `86`–`99` 同）。这一轮把上一轮的 harness 从 **128 项**扩到 **228 项**，覆盖剩下两个会**写设备状态**的安装器，两个都抓到真缺陷。设备整轮没有测量。

**接续**: [`72`](72-*.md)（发热的两个来源）、[`94`](94-retiring-the-v63-debug-keeper-is-a-kill-not-a-unit-edit.md)（退休只能靠 kill）、[`95`](95-the-first-commands-after-recovery-are-offline-verified.md) / [`96`](96-three-thermal-units-in-one-snapshot.md)（`performance` 与三个热单位）、[`99`](99-the-remaining-heat-fix-was-broken-offline.md)（上一轮，同一套 harness 的第一次）。证据原文在 `docs/ubuntu-touch/evidence/installer-selftest-2026-09-23-cpufreq-netwatch.log`。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 这一轮做了什么？ | `scripts/host/zl1-installers-selftest.sh` 从 128 项扩到 **228 项**（docs 101 又加了 1 项，现为 229），新增第 12 节（cpufreq，44 项）和第 13 节（netwatch，56 项）——正好是剩下两个会写设备状态的安装器 |
| 为什么是这两个？ | `install-cpufreq-governor.sh` 是**发热修复的另一半**（把四颗核从镜像自带的 `performance` 上调走）；`install-netwatch-service.sh` 是**唯一会读一个分区**的安装器（misc，看门狗能往里写 `boot-recovery`） |
| cpufreq 抓到什么？ | applier **写完之后从不回读**。`echo > scaling_governor` 一返回就记一次成功，所以"内核对这个名字回 EINVAL、值根本没变"时它报的是 `governor 'schedutil' on 0 cores`，**退出 0**、`Result=success`、unit `active`——一个说"发热修复已武装"而四颗核仍在 `performance` 的仪器 |
| cpufreq 还抓到什么？ | `--governor` **末尾不带值**时 `$2` 触发 `set -u` 直接**中止整个 shell**（rc=1，且不说哪个 flag 缺值）；以及**根本没有 `--help` 分支**（`unknown argument --help`，rc=2），而同目录每一个兄弟脚本都打印用法 |
| netwatch 抓到什么？ | misc 备份那一整块只由 `[[ -f misc.img ]]` 把关，**之后再也不看那个文件**。于是一次 `exec-out` 只拿到 0 字节或截断的镜像（adb 掉线、设备被拔、cat 失败），留下的文件会满足**以后每一次**运行的 `-f` 测试，而 `sha256sum` 会老老实实把"空文件的哈希"记下来并被相信 |
| 为什么这个缺陷特别刺眼？ | 它是这个项目**已经被咬过一次**的形状：`2026-06-07-adb-root-exact` 那套备份 31/31 SHA256 全过，**仍然挂不上**（docs 84） |
| 修法（cpufreq）？ | 每个核写后**回读**，读回来的不等于目标就计数为 `bad`；`bad != 0` 或 `n == 0` 一律 **`exit 1`** 并打印"the heat fix is NOT armed"；`--governor` 用 `${2?...}` 让消息里带 flag 名；补 `--help` |
| 修法（netwatch）？ | 已存在的镜像**必须**非空**且**记录的哈希仍然对得上才接受（否则重取，这是安全方向）；新取的镜像先写 `.tmp`，再和**第二次独立读取**的分区字节数交叉核对，不一致就 `rm -f` + `exit 1` |
| 怎么证明 harness 有牙？ | 同一份 harness 对着 `HEAD` 的脚本跑：**15 条红**，只有两个缺陷（cpufreq 8 条、netwatch 7 条）。而第 1–11 节（退休 debug keeper、no-EDL）在 `HEAD` 上**全过**——诚实读法：坏的是**失败路径**，不是 happy path |
| 动设备了吗？ | 没有。假 `/sys`、假 `/proc`、假分区、假 unit、假 adb 全是编的；设备仍是 EDL |

---

## 2. cpufreq：一个不能判断自己有没有生效的仪器

脚本存在的理由是用户自己那句话——**"这台机器很容易发烫"**——而第一件被量到的事就是 governor：

```
$ for p in 0 1 2 3; do cat /sys/devices/system/cpu/cpu$p/cpufreq/scaling_governor; done
performance performance performance performance
$ cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq    # == scaling_max_freq
1132800                       # cpu0/cpu1 上限 1132800，cpu2/cpu3 上限 1363200
```

四颗核**一直**在最高频，从不降。内核提供的表是 `interactive conservative ondemand userspace powersave performance`（**没有 `schedutil`**），运行时改成 `interactive` 后空载从 1132800/1363200 掉到 **307200/460800**（docs 95）。

缺陷的形状是这样的（修复前）：

```sh
for p in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
    [ -w "$p/scaling_governor" ] || continue
    echo "$GOV" > "$p/scaling_governor" 2>/dev/null   # 写失败？这里看不出来
    n=$((n + 1))                                     # 于是无条件算一次成功
done
echo "... on $n cores"                                # 0 也好，4 也好，都 exit 0
```

真内核面对一个它不提供的名字会**回 EINVAL 并保留旧值**；写成普通文件则会"成功"。所以在真设备上，这个脚本的失败长这样：`on 0 cores`、`exit 0`、`Result=success`、unit `active`。**而那正是它唯一要报告的那件事。**

修完的 applier 逐核回读，并且把"没生效"变成一个**失败的 unit**：

```
zl1-cpufreq: /sys/devices/system/cpu/cpu2 did NOT take 'interactive' (reads 'performance')
zl1-cpufreq: governor 'interactive' on 3 cores (1 did not take it)
zl1-cpufreq: the heat fix is NOT armed on 1 core(s)
```

这不是洁癖：`install-no-edl-on-panic.sh` 的注释里已经写下同一条规则——**一个静静没武装上的守卫，比一个出现在 `systemctl --failed` 里的 unit 糟得多**。

---

## 3. netwatch：唯一一份 misc 备份，被"存在"当成了"可用"

`install-netwatch-service.sh` 在 TWRP 里跑，把 unit 和脚本推到 `/data/system-data/etc/systemd/system`（那是 `/etc/systemd/system` 的可写绑定，重启后仍在），**同时**给 misc 分区拍一张像——因为看门狗可以往里写 `boot-recovery` 来进 recovery，而 2026-06-07 那套备份里**没有 misc**。修复前：

```sh
if [[ ! -f "$MISC_OUT/misc.img" ]]; then
  ...
  adb -s "$SER" exec-out "cat $MISC_BLK" > "$MISC_OUT/misc.img"
  ls -l "$MISC_OUT/misc.img"
  ( cd "$MISC_OUT" && sha256sum misc.img > SHA256SUMS )
fi
```

`-f` 之后没有任何一次**再看那个文件**。一次截断的传输留下一个短文件，从此每一次运行都会说"备份已存在"并跳过——而 `ls -l` 事后看不出短读，`sha256sum` 也会为错误的内容背书。这个项目已经吃过一次同样的亏：那套 `-exact` 备份 **31/31 SHA256 全过、仍然挂不上**。

修复把"存在"和"可用"分开，并把新取的备份钉在第二次独立读取上：

```sh
misc_backup_ok() {
  [[ -s "$MISC_IMG" ]] || { echo "existing misc.img is EMPTY ..." >&2; return 1; }
  [[ -f "$MISC_OUT/SHA256SUMS" ]] || { echo "existing misc.img has no SHA256SUMS ..." >&2; return 1; }
  ( cd "$MISC_OUT" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ) \
    || { echo "existing misc.img FAILS its recorded SHA256 ..." >&2; return 1; }
  return 0
}
# ... 新取的那份：
adb -s "$SER" exec-out "cat $MISC_BLK" > "$MISC_IMG.tmp"
MISC_DEV_BYTES="$(adb -s "$SER" shell "wc -c < $MISC_BLK" | tr -d '\r ')"
[ ! -s "$MISC_IMG.tmp" ] || [ "$MISC_LOCAL_BYTES" != "$MISC_DEV_BYTES" ] && {
  rm -f "$MISC_IMG.tmp"; echo "refusing to record a misc backup: ..." >&2; exit 1; }
```

harness 把这条路径整个走了一遍：伪分区 4096 字节以上、`$W/adb-short` 让 `exec-out cat` 只回 1024 字节而 `wc -c` 说真话——于是它必须**拒绝记录**这份备份，并且**留下 no `.tmp`**。

顺带一个必须写下来的事实：**现存那份备份的内容全是 0。** `2026-09-17-misc/misc.img` 是 1048576 字节，
SHA256 `30e14955…`，`tr -d '\0' | wc -c` 是 0——也就是说拍照那一刻这个设备的 misc 分区是**整块空白**
（没有任何 `boot-recovery` / `bootonce` 残留）。这不是坏备份，**是一张合法的像**。而这正是为什么检查
不能是"它看起来像不像内容"，只能是"**它是不是设备报告的那个字节数、以及它是不是当初记下的那一份**"：
一块空白的 misc 恰恰是最该被正确备份的那种状态，因为它安静得让人以为没什么可存。

---

## 4. harness 的形状变了：两个传输，两台假设备

上一轮的 `ssh` 桩就是那台设备。这一轮多了一台：netwatch 走 **adb**，而且是对着 TWRP（userdata 就是普通的 `/data`）。所以现在有**两个假根**，而且是故意分开的：

| 传输 | 假设备 | 谁在用 |
|---|---|---|
| `ssh` | `$W/fake` | 退休 debug keeper、no-EDL、cpufreq（三个 rootfs 侧安装器） |
| `adb` | `$W/nw` | netwatch（TWRP 侧） |

两个根**不能共用**：两族的落点在不同树里（`/data/system-data/...` 对 `/etc/systemd/system/...`），共用一个根会让某一节的残留满足另一节的断言——这正是 harness 最擅长生产的那种假通过。

---

## 5. 这一轮 harness 自己犯的错（都记下来）

一个 harness 的假检查和一个不存在的检查，代价是一样的。这一轮在四处栽了，其中第一处**看起来像 30 个产品缺陷**：

1. **`else` 分支里多了一个 `;;`。** adb 桩的生成器里我写了
   ```sh
   if [ -e "$W/adb-short" ]; then ... else env ... sh -c "$c" ;; fi ;;
   ```
   那个内层 `;;` 让 dash 报 `Syntax error: ";;" unexpected (expecting "fi")`，**桩无法执行**，于是第 13 节一次性红了 **30 条**，每一条都长得像 netwatch 的行为问题。最小复现：带内层 `;;` 的 `/tmp/inner.sh` 报同一个语法错误，去掉就正常。**桩自己坏掉时，症状是被测脚本"什么都做错"。**
2. **不要去改设备路径。** 第一版把安装器的 `BASE`（一个**设备**路径 `/data/system-data/...`）重写成了假根里的宿主路径；安装器随后把这个路径交给传输层，传输层再映射一次——于是落点变成
   `/tmp/zl1-installers-selftest/nw/tmp/zl1-installers-selftest/fake/data/system-data/...`，**假根被套进自己里面**。规则是：**只重写宿主路径**（这里只有 `MISC_OUT`，它确实是这台笔记本上的目录），设备路径归传输层管。
3. **`readlink -f` 从设备返回的是设备路径。** 安装器问设备要 misc 的块设备，然后拿答案去比对 `/dev/block/*`。映射过的路径不可能匹配，于是它每次都走"解析不出 misc，跳过备份"那条分支。传输层因此需要一个**把命名空间换回去**的 `readlink` 桩：在这个假设备里 `$W/nw` 就是 `/`，剥掉前缀**就是**去伪装。
4. **`grep -q 模式 "$OUT"` 把多行文本当成了文件名。** `$OUT` 是整段输出，不是文件；grep 于是报 `grep: file: ...` 并把每一行都当成一个待读文件名——一条失败的断言就这么消失了。要 `printf '%s\n' "$OUT" | grep -q`。另外还有个小的：`check-netwatch-integrity.sh` 是**相对 `$SRC` 的上一级**去找的，所以假树里必须也放一份，否则 `[[ -x ]]` 不成立、整项检查**被静默跳过**——那正是 2026-09-19 装了一个丢了五个函数的构建的原因，也是这项检查存在的理由。

---

## 6. 这个 harness 现在覆盖什么（228 项；docs 101 之后 229）

```
== 1.  --status 和 --explain 什么都不改（快照比对：整个假设备的文件集）                     14
== 2.  --install：恰好两个文件、内容逐条断言、enable 但**不** start                       22
== 3.  拒绝闸门：没地址就必须**不杀**，并且说清它在放过什么                                 9
== 4.  有地址：杀、验证、以及**说清是哪一种失败**（杀不动 vs 被重新拉起）                   20
== 5.  匹配按 argv 而不是子串：只是"提到"那条路径的 shell / grep 不许被杀，pid 1 不许被杀    9
== 6.  --remove：disable、只删自己那两个文件、并说出"当前这次启动的 keeper 仍然死着"          8
== 7.  no-edl：--capture-only **不许碰** policy unit（它自己注释里记着的那次缺陷）          12
== 8.  no-edl：--install 写四个文件、两个 unit 都 enable --now、并复述那条警告               9
== 9.  policy applier：写、读回、写不进去就**失败**，参数不存在也失败                       10
== 10. pstore applier：空 pstore 不算失败、有记录就按 boot_id 归档、只留最新 4 份             7
== 11. flag 面与守卫，外加两个安装器不许互相指错文件                                          8
== 12. cpufreq：发热修复的另一半（镜像自带 'performance'）                                  44
== 13. netwatch：TWRP 侧安装器，以及唯一一份 misc 备份                                      56
```

第 12 节的形状值得单独说一句：**它不测"写发生了"，它测"仪器能不能把'已武装'和'什么都没变'分开"**。所以有两条断言是拿 `HEAD` 的 applier（用 `git show` 取、同样改写路径）在**同一个 fixture** 上跑，证明它在那台"有一颗核从来没动"的设备上**退出 0**——那一条就是被修掉的行为本身。

---

## 7. 这一轮**不**证明什么

* **对设备的结论：零。** 设备在 EDL；每一个 `/sys`、`/proc`、unit、分区、地址都是 fixture。两个安装器**从来没有在设备上跑过**。
* **misc 分区在这轮里是一个 8 KiB 的随机十六进制文件**，adb 传输是桩。被证明的是**检查的形状**（非空 + 哈希 + 字节数交叉核对），不是真分区真的是 1 MiB，也不是真备份是好的。（顺带：现存那份 `2026-09-17-misc/misc.img` 是 1048576 字节、SHA256 校验通过——这是 `ls`/`sha256sum` 说的，不是这轮测的。）
* **"四颗核会在启动时离开 `performance`"没有被测。** 被测的是"它们没离开时 applier 会失败"。
* **`interactive` 这个名字和 307200/460800 那两个数字**是 2026-09-22 手工量到的（docs 95），这轮没有重测，也重测不了——假核是文件。
* **doc 99 的两条不证明项继续成立**：keeper 的代价没有重测；`install-no-edl-on-panic.sh` 通过不代表清掉 `download_mode` 就真能不进 EDL。
* **欠着的三条热测量**（`zl1-thermal.sh --ab`）仍然欠着，需要设备。

---

## 8. 复现

```sh
# 全部在宿主机上，只需要 /bin/sh、bash、sed、awk、find、git
sh scripts/host/zl1-installers-selftest.sh          # 228 项
sh scripts/host/zl1-installers-selftest.sh --keep   # 留下两台假设备、桩、改写后的 applier 与变异体

# 证明 harness 真的在测这两个缺陷：把当前整棵树拷出去，只把这一轮修的那两个脚本退回到修复前的 revision
# （整棵树都要拷：netwatch 的检查要 scripts/check-netwatch-integrity.sh，缺了它会另外多出 6 条红，
#  那是复制不完整，不是缺陷）。
#
# **"修复前"要写成一个固定的 revision，不能写 HEAD**——这一篇当时写的就是 HEAD，而这两个修复一提交，
# 它就开始拿修复跟它自己比了（docs 101 记下了这次真的发生，以及那个永远只可能 PASS 的守卫）。
# 这两个缺陷的修复是 25f7ba1，之前是 3a26b66。
rm -rf /tmp/zl1-inst-prefix && mkdir -p /tmp/zl1-inst-prefix
cp -r scripts /tmp/zl1-inst-prefix/
git show 3a26b66:scripts/install-cpufreq-governor.sh > /tmp/zl1-inst-prefix/scripts/install-cpufreq-governor.sh
git show 3a26b66:scripts/install-netwatch-service.sh > /tmp/zl1-inst-prefix/scripts/install-netwatch-service.sh
sh /tmp/zl1-inst-prefix/scripts/host/zl1-installers-selftest.sh   # 15 条红，两个缺陷

# 回到设备之后，这两条在恢复顺序里的位置：cpufreq 是现在就能做的一条
bash scripts/install-cpufreq-governor.sh --status     # 只读：unit、四颗核的 governor、热区
bash scripts/install-cpufreq-governor.sh --install    # 装 unit + applier，enable --now
bash scripts/install-cpufreq-governor.sh --remove     # 退回镜像原本的设置
```

| 文件 | 作用 |
|---|---|
| `scripts/host/zl1-installers-selftest.sh` | 扩：128 → **228** 项（后为 229），两个传输（ssh/adb）、两台假设备；第 12/13 节 |
| `scripts/install-cpufreq-governor.sh` | 修：每核回读 + 读不回来就 `exit 1`；`${2?}` 与 `--help` |
| `scripts/install-netwatch-service.sh` | 修：既存备份必须**非空且哈希对得上**；新备份与第二次读取交叉核对，不一致就拒收 |
| `docs/ubuntu-touch/evidence/installer-selftest-2026-09-23-cpufreq-netwatch.log` | 这一轮的原始输出：两个缺陷的原文、228 项全文、对着 `HEAD` 的 15 条红 |
| `docs/ubuntu-touch/100-*.md` | 本篇 |
