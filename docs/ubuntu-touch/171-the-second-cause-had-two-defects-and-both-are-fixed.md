# 171 — 那趟 `CONTAMINATED` 之后的两个修：一个是**等**，另一个是**一个 trap**

**日期**: 2026-09-25
**状态**: 纯离线一轮（改的是 `device/zl1-governor-temp-ab.sh` 和它的 harness；
harness 从 116 条涨到 **161 条，全绿**）。**改完之后还没有上设备跑过**——
这一轮唯一的设备动作是**清理**：把前几轮在这台笔记本 `/tmp` 里泄漏出来的
**288 个草稿目录**数了一遍并删掉（第 5 节）。没有写设备、没有刷分区、没有重启。

**接续**: [`170`](170-the-second-cause-said-i-dont-know.md)（第一次上设备：判词 `CONTAMINATED`，
以及它暴露出来的两个缺陷）、[`169`](169-the-second-heat-cause-has-an-instrument.md)（这台仪器的设计）、
[`167`](167-the-third-cause-is-worth-5-5-degrees.md)（同一个设计量第三个成因，成功过一次）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 缺陷一（消息）怎么修的？ | **整张表印出来**（38 行在一个手机终端上不算什么），并且**运行结束时说出它的草稿目录在哪**——删掉时说"已删除 `$TMP`"，`--keep` 时把路径印出来。**"archive" 这个词从脚本里消失了**，而且这是**静态断言**的：把注释剥掉之后，源码里不许出现这个词。 |
| 缺陷一底下那层怎么修的？ | **一个 EXIT trap 同时做恢复和清理**。原来的形状是第 90 行 `trap 'rm -rf "$TMP"' EXIT`、第 184 行 `trap 'do_restore' EXIT`——**POSIX 里第二个 EXIT trap 替换第一个**，所以清理一次都没跑过。现在只有一行 `trap 'do_restore; cleanup' EXIT`，harness **静态断言"EXIT trap 恰好一个"**。 |
| 这个缺陷的代价是多少？ | **量过了：这台笔记本的 `/tmp` 里有 288 个泄漏的草稿目录**，全是 harness 那几百次运行留下的（设备上另有两个，docs 170 记过）。不是估算，是 `find \| wc -l`。 |
| 缺陷二（设计）怎么修的？ | **加一个"等"**：读完 B、把核放回 `interactive` 之后，**等最热的 tsens zone 回到窗口 A 的 `--margin`（默认 0.5 °C）以内**，最多等 `--settle-back`（默认 240 s），每 `--poll`（默认 10 s）采一次，**并把等了多少秒印出来**。 |
| 为什么"等"不是"把 settle 调大"？ | 因为调大 settle 是**同一个猜测往上抬一档**（把"多长才够"从 45 秒挪到 120 秒），而这个等是**有判据的**：它要么回来（并且报出用了多久——那是这台手机的热时间常数，本身就是读数），要么**不回来**。 |
| 不回来算什么？ | **一条判词**，`no-return`（退出 1）：**这一趟不印价钱**，而且**根本不去读窗口 C**——因为那时没有对照窗口可比，"A 和 B 两个窗口给出的那个数"是**成因的代价加上还没散掉的那部分自热**。 |
| 旧设计还能用吗？ | 能，而且是**明说**的：`--settle-back 0` 关掉等待、恢复旧行为，并且印出"这样 `contaminated` 就是这个设置的属性"——第一次上设备那一趟用的实际上就是这个设置。 |
| 写 harness 时又找出什么？ | 一条**本来不可能失败的断言**：`comm -13 <<< "" <<< "$AFTER"` 在第一侧为空时报 `missing operand` 并返回非零，于是"没有剩下的目录"被读成了**通过**——而它是**唯一一个必须在场**的场景（第 4 节）。 |
| 上设备跑过了吗？ | **没有。**这一轮的修全部是离线的，harness 161 条全绿；设备上的下一次运行会用一个**新的判词词汇**和一条**新的读数字段**（等了多少秒）。 |

---

## 2. 缺陷一：不是"证据被删了"，是"证据在，但你找不到它"——而现在两半都修了

docs 170 的第一版把这件事写错了，错在**读了源码就下结论**；真正定下来的是上设备看一眼：
目录**还在**（`$TMP/deltas`，38 行全在），因为那段清理**从来没有执行过**。

所以修法有两半，而两半都必须是**可判定的**：

**（一）让它自己说在哪里。** 现在运行的最后一句话是其中之一：

```
   --keep: this run's scratch directory is /tmp/zl1-governor-temp-ab.XXXXXX (deltas, deltas.note, win.A/B/C, back).
   the scratch directory /tmp/zl1-governor-temp-ab.XXXXXX was removed (--keep leaves it instead, and a failed window forces it on).
```

而且**窗口失败时 `--keep` 被强制打开**：一个出错的窗口，它的输出是那份证据的**唯一**拷贝，
"错误带着证据一起被删掉"就是这个仓库反复写仪器去防的东西。

**（二）整张表印出来。** 那句 `... N more; the whole table is in the archive` 没有了，
因为"省掉 26 行"换来的是一条**没人能找到**的证据。现在印完所有行，并且**说出它印了多少行**：

```
   (14 zone(s) in this table, sorted by B-A; every one is printed.)
```

这一句是 harness 能抓住的东西：m8 把表截断成两行，**那句"every one is printed"还在**——
于是**断言和表本身矛盾**，而矛盾是被断言检查的（表格行数 vs 表自己声称的行数）。

**（三）底下那层：一个 EXIT trap。** 现在是

```sh
trap 'do_restore; cleanup' EXIT
```

一行。harness 对**剥掉注释的源码**静态断言 `^trap .* EXIT$` **恰好出现一次**，
因为失败形态是"应该在那里的那一行不在"，而不是"跑错了"。这一条**从通过的那一侧看不见**：
关于"恢复有没有生效"的每一条断言在旧版本上**全都成立**——只有一条数若干目录的断言能看见它。

---

## 3. 缺陷二：加一个"等"，并且把"没回来"变成一条判词而不是一个数

```
== the wait -- does window A's reading come back before the control window reads it?
   window A's hottest tsens zone: 43.5 C. Waiting up to 240s (every 10s) for it to come
   back to within 0.5 C of that before window C reads anything.
   IT CAME BACK: 43.5 C after 30s, against window A's 43.5 C (margin 0.5 C). Window C
   below is therefore a CONTROL and not a second reading of the same heat.
```

或者：

```
   IT DID NOT COME BACK within 240s: the hottest tsens zone is 48.0 C against window A's 40.9 C,
   i.e. more than 0.5 C above it. Two things can look like this and this instrument cannot tell
   them apart: the intervention's warming has not decayed (thermal mass), or the phone warmed on
   its own by more than the margin while the run went on. BOTH are statements about this RUN and
   about the phone. Neither is a price for the governor, so THIS RUN PRINTS NO PRICE: there is no
   control window to compare against, and window C is not read at all.
```

三个设计决定值得写下来：

1. **等的是"读数回来"，不是"时间过去"。** 时间到就往下走，等于什么都没解决；
   等的是**同一个传感器回到窗口 A 的水平**，容差印在判词里。
2. **不回来时不去读窗口 C。** 不读是**结论的一部分**：那三次读数如果印出来，
   读者会自己去比 B 和 C，并把一个不是价钱的数当成价钱。所以那一段只印**两窗口的表**（A、B、B-A），
   判词是 `no-return`，退出 1。
3. **等的时间本身就是读数。** "多少秒回来"是这台手机在这个干预下的热时间常数——
   它以前从来没有被量过，而它正是"等多久才够"这个问题的答案。它现在被印出来，且带着**产生它的设置**。

`--settle-back 0` 是旧设计，而且**脚本自己说它是旧设计**：

```
   --settle-back 0: THE WAIT IS OFF. Window C will start immediately after the undo, so if the
   intervention's heat has not decayed by then the control window cannot separate it from the
   governor -- which is what the first device run of this instrument measured (docs 170). The
   verdict below is read with that limitation, and 'contaminated' is a property of THIS setting.
```

---

## 4. 写这一轮时找出的两条：一条在 fixture 里，一条在**断言自己**里

**（一）fixture 必须会"凉"。** 加了等之后，那个算出温度表的 stub 不能再只按"窗口序号"给温度：
它得**随时间衰减**，否则**每一个**场景都会走进 `no-return`，而"等"这条路径就从来没有被测过。
所以 stub 现在多了一个冷却模型：干预的多余量在核被放回之后按**采样次数**衰减，
`FP_COOL=1` 是"一采就凉"，`FP_COOL=-1` 是"**在窗口里根本不凉**"——后者正是第一次上设备时那台手机的形状。
"这台手机不会凉"从此是一个**能跑的场景**，而不是一段说明。

**（二）一条本来不可能失败的断言。** m10（把清理关掉）要证明的是一件必须发生的事：
**某个草稿目录被留下**。第一版写的是

```sh
NEW=$(comm -13 <<< "$BEFORE" <<< "$AFTER")
```

而 `comm -13 <<< "" <<< "$AFTER"` 在**第一侧为空**时报 `comm: missing operand`、返回非零、**什么都不打印**。
于是"没有剩下的目录"被读成"通过"——**在唯一一个必须留下目录的场景上**。
这正是 harness 自己在 m1/m5/m7 上反复防的那种形状（**一个不可能失败的检查**），
而它这次出现在**这条断言自己的实现里**。修法是把两侧写进**文件**，并且用
`[ -s "$W/.left.new" ]` 而不是"命令有没有输出"来判。

---

## 5. 代价是量出来的：288 个目录

"清理从来没跑过"这句话可以是一段推理，也可以是一个数。这一轮数了一遍：

```
$ find /tmp -maxdepth 1 -type d -name 'zl1-governor-temp-ab.*' | wc -l
288
```

它们全部来自 harness 的几百次运行（设备上另有两个，见 docs 170）。删掉之后，**同一句话再数一次是 0**——
而这一次 0 是有意义的，因为现在的运行**会说自己删了什么**，harness 也**断言那个路径真的不存在**。

一条顺带的读数：那 288 个目录里，绝大多数是**只读的 `--status` 运行**留下的——
它们连一个窗口都没跑，却仍然在 `/tmp` 里留下了一个空目录。

---

## 6. 这一页**没有**成立的东西

* **改完之后没有上设备。** 161 条检查全是对着一个假设备跑的。新的 `--settle-back` 在**真**手机上
  要等多久，**不知道**——这个数正是下一次运行要去取的。
* **热时间常数还是没有。** 上面那个"它会在多少秒回来"的字段，**至今完全是 fixture 里的数**。
* **`no-return` 在真机上的可达性没有验证过。** 第一次上设备那一趟（45 秒的 settle，没有等待）
  读到 C 比 A 高 8.4 °C；如果 `--settle-back 240` 之下它回来了，那么那一趟就变成
  `cost-measured` 或 `contaminated`——**哪一种都还没发生**。
* **②的价钱仍然没有。** 这一页修的是**能问出价钱的仪器**，不是价钱本身。
* **288 这个数只覆盖这一台笔记本的 `/tmp`。** 设备上的 `/tmp` 只数了 docs 170 那一趟的两个，
  没有全盘扫过；`/tmp` 是 tmpfs，重启就没了，所以这条的寿命本来就短。

---

## 7. 阶段位置

| | docs 170 之后 | 这一轮之后 |
|---|---|---|
| 那张表 | 只印 12 行，其余"在 archive 里"（没有路径） | **全印，并说出印了多少行** |
| 草稿目录 | **从不清理**（288 个还在 `/tmp` 里） | 一个 trap 管恢复+清理，说出去哪了，`--keep` 可留 |
| 窗口 C 是"对照"吗 | **只因为它读同一个 governor** | **因为它读之前，读数已经回来了**；没回来就不读它 |
| 没回来时 | 报一个**不是价钱**的价钱（`contaminated`） | **不印价钱**，判词 `no-return` |
| 热时间常数 | 没有 | **下次运行会量出来**（等了多少秒） |

下一步是**把这个改过的仪器再上一次设备**：它会在 A 和 B 之后停下来等，
然后把"等了多少秒"和判词一起印出来——那一条读数**无论判词是哪一种都是新的**。
硬件清单上还没驱动起来的那几项（相机 app 上没上屏、GPS 一次定位都没有、
指纹的驱动编进了镜像但没刷）这一轮同样**一个都没有碰**。
