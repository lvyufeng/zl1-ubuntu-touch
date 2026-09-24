# 116 — 存在性测试问不出答案，而它在花掉一次开机

**日期**: 2026-09-24
**状态**: 本轮**没有碰设备**（设备仍在 EDL，见 §6）。全部是 host 侧：一个设备侧探针的**真实缺陷**、
一个 harness 里**为什么没抓到它**的 fixture 缺陷、以及一次默认值的翻转。**没有在设备上安装任何东西，
没有 flash，没有写分区，没有重启任何服务。**

**接续**: [`115`](115-replacing-a-file-does-not-change-a-process.md)（替换一个文件不会改变一个进程；同一轮
设备的一次救回和又一次掉进 EDL）、[`103`](103-the-fingerprint-probe-counted-the-callers-own-line-in-logcat.md)
（一个 log 里的字符串属于写出它的那个进程）、[`109`](109-an-instrument-that-cannot-report.md)
（一个不能报数的仪器比没有更糟）、[`107`](107-one-physical-press-buys-one-command.md)
（一次物理按键换来一条命令，而它的每一步都只读一次）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 发现/改了什么？ | 指纹探针的**每一条存在性测试都从来没有得到过答案**：`nsenter -t PID -m -- test -e PATH` 里的 `test` 是在**容器的挂载表里**被 exec 的，而那个表里没有 `/usr/bin`，于是 `nsenter` 以 127 退出 —— shell 把 exec 失败读成**假**，所以"测不出来"被报成了"不存在" |
| 它到底错在哪？ | 探针第 2 节的结论 `-> no variant match; AOSP would fall back to fingerprint.default.so` **是一个它没有挣来的结论**。设备自己在 2026-09-24 的归档输出里说了九遍：`nsenter: failed to execute test: No such file or directory` —— 三个 variant × 三个目录，正是那个循环的每一次 |
| 修法 | 换成一个**不需要 exec 的读法**：`/proc/<hal-pid>/root/<path>`。路径由**内核**按目标进程的挂载命名空间和 root 解析，而做这件事的工具（`[ -e ]`、`ls`）是 UT 侧自己的 |
| 为什么这个错值得单开一篇？ | 这是 `103`/`109` 那条规则**同一形状的第二层**：一个仪器**不能报数**，却印出了一个确定的答案。而且它不只影响阅读 —— 唯一那个会写的模式（`--create-store-dir`）也用同一套测试，所以"测出来不存在"会让它**每次都去创建**，而 `mkdir` 同样会以 127 失败 |
| 为什么 harness 没抓到？ | 因为 **fixture 无缘无故地同意了脚本**：nsenter stub 里有一组 `test -e`/`test -f`/`ls` 分支，而 stub 根本没有容器那张挂载表 —— 它当然答得出。那组分支已经删掉了，取而代之的是一个**有牙的 mutant** |
| 离线验证？ | `zl1-loc-fp-selftest.sh` **181 检查 / 0 失败**；把它跑在 `10ba692` 那份探针上（把修复**真的撤掉**，不是描述一遍）是 **164 通过 / 14 失败**（§5） |
| 还改了什么？ | `zl1-post-recovery-capture.sh` 的**两个探针默认不跑了**（`--with-probes` 才跑）。理由写在 §6.3：相关性，不是因果，也不冒充因果 |
| 动设备了吗？ | **没有。** 本轮全程只读主机。设备仍在 EDL（§6） |

---

## 2. 缺陷：`nsenter -m -- test` 在容器里没有 `test`

有问题的写法是这一段（第 2 节，"哪个模块被 `hw_get_module('fingerprint')` 选中"）：

```sh
for v in $variants; do
  for d in /vendor/lib64/hw /system/lib64/hw /odm/lib64/hw; do
    if [ -z "$pick" ] && nsenter -t "$A" -m -- test -f "$d/fingerprint.$v.so"; then
      pick="$d/fingerprint.$v.so"
    fi
  done
done
```

这段代码的**意图**是对的，而且它的注释解释了为什么不能直接用 `test -f`：`/vendor` 是**容器**的树，
在 UT 侧直接测它会报"每个模块都不存在"，读起来就是"HAL 没装"。所以它换成了 `nsenter -m`。

问题是 `nsenter` 的执行顺序：**先进命名空间，然后 exec**。于是 `test` 这个名字是在**容器的挂载表**
里被解析的，而那个表里没有 UT rootfs 的 `/usr/bin` —— `test` 不是内建（它是 `nsenter` 要 exec 的一个
真程序），所以：

```
nsenter: failed to execute test: No such file or directory
```

`exec` 失败是退出码 **127**。而 shell 里 `cmd` 失败就是**假**。所以这一句不是"报错然后停"，它是
**"报错然后回答'不存在'"** —— 于是 `pick` 一直是空的，循环跑完九次（`qcom`、`msm8996`、`msm8996`
三个 variant，乘三个目录），探针印出：

```
   -> no variant match; AOSP would fall back to fingerprint.default.so
```

**这句话是假的**，而它不是"猜错"，是**没看**。这也是为什么它骗过了一切：格式对、位置对、逻辑对，
唯一不对的是它从来没读过任何一个文件。

同样的写法还有三处（第二个 store 的 `test -e`/`ls -ldn`、`--create-store-dir` 的
`test -e`/`mkdir`/`chown`/`chmod`/`ls -ldn`），所以**唯一那个会写设备的模式也在同一个坑里**：它会认为
目标目录不存在，然后 `mkdir` 同样以 127 失败。也就是说，这个探针**从来没有在设备上创建过任何东西**，
而它的 UNDO 行一直印在那里，像是它创建过。

（反方向的两个是好的，而且理由是同一个：`lshal` 和 `logcat` 走 `-p -m` 仍然能用，因为容器那张表里的
`/bin` **就是** Android 的 `/bin`，里面有它们。它们需要 `-p`/`-m` 是为了 binder，所以保持原样。）

---

## 3. 修法：`/proc/<pid>/root/<path>`，一个不需要 exec 的读法

```sh
halpath() { # $1 = a path as the CONTAINER sees it; prints the path to read it from HERE
  if [ -n "$H" ]; then printf '/proc/%s/root%s' "$H" "$1"; else printf '%s' "$1"; fi
}
```

`/proc/<pid>/root` 是一个**内核提供的视图**：路径由内核按目标进程的 mount namespace 和 root 解析，
而**做读取的工具是 UT 侧自己的**（`[ -e ]` 是 shell 内建，`ls` 是 UT 的 `ls`）。没有 exec，就没有
"命令不存在"这个失败模式。

十一处调用点全部换过去了：模块 variant 的 `[ -f ]`、模块列表的 `ls -l`、AOSP fallback 的 `[ -e ]`、
第二个 store 的 `[ -e ]` 与 `ls -ldn`，以及 `--create-store-dir` 的 `mkdir -p`/`chown`/`chmod`/`ls -ldn`。
这意味着**写和撤销现在在同一个命名空间里**：`mkdir -p /proc/<pid>/root/data/vendor_de/0/fpdata`
创建的正是 HAL 的 `access(W_OK)` 会去看的那个目录，而 UNDO 行
`rmdir /proc/<that-pid>/root$TARGET` 指向的是同一处。在此之前，这两行指的是**两个不同的东西**。

顺带修掉的是那句 undo 的可用性：它现在带一条找出**本次开机**的 HAL pid 的命令
（`ps -eo pid,args | grep -i [b]iometrics.fingerprint`），因为 pid 每次开机都会变，而旧文里印的是
一个写死在文本里的 pid。

### 3.1 `$H` 为空时的行为

`halpath` 的 else 分支会原样返回路径 —— 那是**主机**的路径，读它没有意义。所以这一条必须说清：
**第 2 节、第 4 节、第 5 节的所有 `halpath` 调用都在 `[ -n "$H" ]` 的 else 分支里**，`--create-store-dir`
另外还有一条 `if [ -z "$A" ] || [ -z "$H" ]; then ... exit 1`。也就是说，那个 fallback 是防御性的、
不可达的读路径；HAL 没在跑的时候，探针在文件开头就说了 `== HAL: not running`，它不会拿主机的树冒充容器。

---

## 4. fixture 为什么没抓到它：一个**无缘无故同意**的 stub

缺陷在设备上存在了几个月，而 `zl1-loc-fp-selftest.sh` 一直是绿的。原因值得单独写下来，因为它和
`114` 里那个 `is-active` stub（打印 `inactive` 却 `exit 0`）是同一个形状：

harness 的 `nsenter` stub 里有一组分支，专门回答 `test -e` / `test -f` / `ls`。**但 stub 没有容器的
挂载表** —— 它就是主机上的一个 shell 脚本，`test` 当然找得到、当然答得出。于是：

* 在设备上：`nsenter -m -- test` → 127 → 假 → "不存在"；
* 在 fixture 里：`nsenter -m -- test` → **真/假取决于假根里有没有那个文件** → 看起来完全正常。

**这就是"一个因为与脚本无关的原因而与脚本一致"的 fixture。** 它比"没有 fixture"更糟：没有 fixture 至少
不会给出一份绿。修法是把它删掉 —— stub 里不再回答存在性问题（`test -e`/`test -f`/`ls` 三个分支，
以及配套的 `$W/exists`/`$W/files`/`$W/ls` 三个文件全部移除），取而代之的是一个**必须能失败**的 mutant：

```sh
sed 's#printf .*/proc/%s/root%s. "$H" "$1"#printf "%s" "$1"#' "$W/fp.sh" > "$W/fp.hostpath.sh"
```

也就是把 `halpath()` 短路成返回它自己的参数 —— **每一处读都指向这台主机**而不是容器的 root。它必
须找不到模块、必须报告第二个 store 不存在、必须说出 `no variant match`。**如果它还能找到模块，那么
上面所有的断言测的都是主机，不是设备。**

这个 mutant 是**同一个缺陷的两次去壳**，这一点也写进了文件：第一稿把 `test -f` 直接指向主机的
`/vendor`；第二稿把它改成 `nsenter -m -- test`，指向一张没有 `/usr/bin` 的挂载表，于是"不存在"的
理由与装了什么毫无关系。mutant 是这两者的诚实版本：**它是故意去问主机的**，而检查必须发现。

---

## 5. 离线验证：181 检查，和对 `10ba692` 的 14 个失败

`scripts/host/zl1-loc-fp-selftest.sh`：**181 检查 / 0 失败**。

**跑在 `10ba692` 那份 `zl1-fingerprint-probe.sh` 上（把修复真的撤掉，而不是描述一遍）：164 通过 /
14 失败。** 原始输出归档在
[`evidence/loc-fp-prefix-2026-09-24.log`](evidence/loc-fp-prefix-2026-09-24.log)，本轮那次绿的在
[`evidence/loc-fp-selftest-2026-09-24.log`](evidence/loc-fp-selftest-2026-09-24.log)。

**12 个落在修复本身**，而且每一个都是一个读容器的路径；另外 2 个是 harness 自己在诚实：

| 失败的断言 | 它测的是哪一处 |
|---|---|
| `it did not create the <=27 store directory`（×4，两个 api_level 分支各两种） | `--create-store-dir` 的 `mkdir -p` |
| `it reports what it created` / `with the matching undo` | 同一处的"读了什么写"与 UNDO 的一致性 |
| `it did not create the >27 store directory` | `--create-store-dir` 的另一条分支 |
| `with the size of the module it picked` | 第 2 节的 `pick` |
| `and of the Goodix HAL underneath it` | 第 3 节的 `libfp_client5118m.so` |
| `it notes the absent AOSP fallback` | `fingerprint.default.so` 的 `[ -e ]` |
| `and the Goodix HAL's own store, which is not the path biometryd passes` | `/data/gf_data` 的 `[ -e ]` + `ls -ldn` |
| `the mutation did not land, so the check above proves nothing` | **不是探针的缺陷**：在旧探针上没有 `halpath()` 可以短路，mutant 落不下去 |

剩下两条值得点出来，因为它们**不是**探针的缺陷：一条是上表的 mutant 落不下去，另一条是 harness 自己的引用守卫
（`the health check cites 181 checks, but this harness has 178`），因为 mutant 落不下去时，
挂在 mutant 之后的三条检查根本不存在，于是它报 178，而不是把 178 说成 181 —— 这两条恰恰是 harness 诚实的地方。

一句话概括这 14 个：**把修复撤掉，这个探针没有任何一条读到容器里的路径。**

---

## 6. 这一轮**没有**确定的事

### 6.1 两次掉进 EDL 的原因，**没有确定**

事实摆在时间轴上：两次 EDL 之前，最后在跑的东西都是**指纹探针**。**这是两个点的相关性，不是归因**
——本文没有读到任何因果。上一轮（`115` §7）已经记过：pstore 是空的，postmortem 报的
"FOUND: a kernel oops/panic" 抓到的多半是**开机时**的 `Call trace:`，是假阳性。

**因为这个缺陷，还有一个新的可能**必须留在桌面上：探针唯一那个会写的模式会因为同一个 127 而**什么都
没写**，所以它**不是**"在 Android 的 /data 里乱写导致设备崩溃" —— 这一点现在可以排除了，因为我们现在
知道它写不进去。**探针在这一轮之前，对设备是只读的**，无论它自己怎么说。

### 6.2 修复**没有在设备上跑过**

`halpath()` 的验证全部是离线的（一个假的容器、一个假的 HAL 进程）。设备上第 2 节的结论
（`/vendor/lib64/hw/fingerprint.msm8996.so` 到底在不在）**仍然没有从设备上读到过** ——
离线的答案是 `98` 对 `vendor.img` 的读法给的。等设备回来，这一个数字就是探针的第一个可检验断言。

### 6.3 探针默认值的翻转：一个**相关性**，不是因果

`scripts/host/zl1-post-recovery-capture.sh` 现在**默认不跑两个探针**，`--with-probes` 才跑
（`--skip-probes` 作为旧名字保留，因为四份文档把这个词写进了操作链）。

理由就是 §6.1 那句话，一字不改：**每一个 EDL 前面都是探针，而两个探针从来没有为它们的硬件产
生过一次修复**（GPS 与指纹至今没有拿到过定位/指纹）。在发烫修复还没装、每一次开机都要用手指换来的
阶段，默认应该花在**会随这次开机消失的证据**上（keeper 的 pid 与 CPU ticks、pstore、unit 列表），
而不是两个**下一次开机还能再跑**的只读探针。

**这个默认值是可逆的、且说明写在脚本里**：它不是"探针有害"的判决，是"这次先不花在一个已知的相关性
上"。`--with-probes` 一按就回来了。

### 6.4 发烫仍然没有解决

两个发烫修复（退役 v63 debug keeper、cpufreq governor）**都还没装上** —— 它们都要在设备上执行
`--install`，而且 keeper 的退役还卡在一条链上（`111` → `115` 的 `--activate` → `112` 的
`proof-obtained` → `114` 的闸门）。本轮把那条链上"必须重启"的一步换成了**一次 ssh 往返**，那是在
为一台"每次开机都可能进 EDL"的设备省开机，但它本身不降温。

---

## 7. 下一步（顺序是有理由的，不是随便排的）

设备在 EDL，**唯一**的出口是物理长按电源 10–20 秒（这部分只有人能做的）。之后：

```
scripts/host/zl1-post-recovery-capture.sh                    # 探针默认跳过（本文）
install-netwatch-service.sh --yes --ssh
install-netwatch-service.sh --yes --ssh --activate           # 115：省掉一次重启
zl1-address-owner-proof.sh --yes                             # 决定性的测量
install-retire-debug-keeper.sh --install --now --after-proof # 只有 proof-obtained 才杀
install-cpufreq-governor.sh                                  # 发烫的另一半
```

每一步都还没有得到用户的批准；本文不改这个顺序，只改第 1 步的**默认集合**，以及第 2 步之前那个探针
的**正确性**。
