# 130 — 那一次 boot 的读数落在它自己的记录指不到的地方

**日期**: 2026-09-24
**状态**: 本轮**没有碰设备**（设备仍在 Qualcomm EDL，见 §7）。这一轮修的是[上一轮](129-the-family-total-was-typed-and-no-harness-can-see-the-tree.md)
接线接出来的那件测量的**归档位置**：`zl1-one-boot-runbook.sh` 的第 03 步**没有把 `--outdir` 传给发烫链**，
于是那条链自己做的那份归档——**包括 `06b-heat-ab.txt`，也就是 A/B 测量本身**——落在
**同一个 boot 的另一个目录里**，在 boot 自己的归档**旁边**而不是**里面**，而且那个目录被
`.gitignore` 的 `tmp-*/` 覆盖。harness 107 → **127**。

**接续**: [`128`](128-the-chain-changed-the-heat-and-never-measured-it.md)（A/B 测量本身）、
[`124`](124-the-boot-a-finger-bought-is-one-command.md)（一次 boot 一条命令，以及它的顺序）、
[`107`](107-one-physical-press-buys-one-command.md)（一次手指换一次 boot）、
[`129`](129-the-family-total-was-typed-and-no-harness-can-see-the-tree.md)（家族的树指纹）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 发现了什么？ | runbook 的第 01 步**明确**把归档目录传下去（`--outdir "$OUT/capture"`，注释写着"两份记录，谁也不会覆盖谁"），而**第 03 步什么都没传** |
| 那会怎样？ | 发烫链自己做一份归档（`INDEX.txt`、每步的文件、以及 **`06b-heat-ab.txt`**），默认落在 `$REPO/tmp-heat-fix-<timestamp>/` —— **同一个 boot 的第二个目录**，在这个归档**旁边**，被 `.gitignore` 的 `tmp-*/` 覆盖，而且 **boot 自己的 `INDEX.txt` 里一个字都没提它** |
| 为什么这特别要紧？ | 因为**这次 boot 不能重来**。落在一个"这次 boot 的记录指不到、也没人保留"的地方，就是 `107`/`124` 一直在防的那个形状：**"晚一步才发现"和"根本不能发现"，在唯一一次机会上几乎是一回事** |
| 而且它落在哪？ | `tmp-*/` —— 也就是**scratch**。boot 归档里只有 `03-heat-chain.txt`（链的 stdout），而链的原始输出、对齐记账、每步的返回码都在那份 scratch 里 |
| 修法？ | `"$HEAT" --yes --outdir "$OUT/03-heat-chain"`（`--settle` 那支同样），和第 01 步一个字不差；`INDEX.txt` 里那一行也点出它 |
| 离线怎么证明？ | harness 的替身变成 **outdir-aware**：给了 `--outdir DIR` 就往 DIR 里写（真的链就是这么干的），**没给**就往一个自己的目录写（真的链默认就是这么干的）。断言是**双向**的：读数**在** boot 的归档里，而且**不在**那个"没人告诉它该去哪儿"的目录里 |
| 变异？ | 把 `--outdir` 从被发出的脚本里删掉 → **双向断言同时红**（归档里没有了 + 出现在了替身目录里），而**运行仍然 `exit 0`** —— 也就是说光看返回码看不出这件事 |
| 顺带补的两件？ | ① 这个 harness **一直没有自己的变异机制**：`127` 引用的那两个变异是**手工**做的（`cp` 到一边、`sed`、跑、还原），那是**流程**不是**机制** —— 家族刚立的规矩（`129`）要求的正是后者。现在第 10b 节有真的 `mutate()`。② **`scripts/README.md` 也写着每个 harness 的检查数，而没有任何东西读它们**：它给 runbook harness 那一行写的还是 **95**，从 `127` 起就过期，中间过了每一轮，而那个 harness 已经长到 127（§5） |
| 离线验证？ | runbook harness 107 → **127 检查 / 0 失败**；meta-harness 129 → **134**；家族 **19 个 harness / 2169 检查 / 全绿**，树未变 |
| 动设备了吗？ | **没有。** |

---

## 2. 缺口：一句话的差别，在两个步骤之间

第 01 步是这样写的（逐字）：

```sh
# The capture archives into a directory of its OWN inside ours, so its INDEX.txt survives next to
# this one's -- two records of the same boot, and neither can overwrite the other.
if run_step 01-capture "read-only: ..." "$CAP" --outdir "$OUT/capture"; then
```

它是对的，而且它把**理由**写下来了。第 03 步是这样写的：

```sh
run_step 03-heat-chain "the two known heat fixes, ..." "$HEAT" --yes --settle "$SETTLE"
```

**没有 `--outdir`。** 而 `zl1-heat-fix-chain.sh` 自己的默认是：

```sh
[ -n "$OUT" ] || OUT="$REPO/tmp-heat-fix-$(date -u +%Y%m%dT%H%M%SZ)"
```

于是那一次 boot 会同时存在两份记录，而**真正重要的那一份**（`128` 刚接上去的 A/B 测量）在：

* 一个**不是** boot 归档的目录里；
* 一个 boot 的 `INDEX.txt` **一个字都没提**的目录里；
* 一个 `.gitignore` 的 `tmp-*/` **覆盖**的目录里（也就是说：scratch，不会被保存）。

这不是"有点乱"。`zl1-one-boot-runbook.sh` 存在的**全部理由**是：boot 不免费，出 EDL 要物理按 10–20 秒，
所以**这一次运行必须要么跑完、要么说清楚它停在哪里**。而它的记录里有一个指向不到的读数，
就等于那个读数**没有被打包进这次 boot**——查的人按 `INDEX.txt` 去找，找不到。

第 01 步和第 03 步之间只差一个参数，而**差的那一步恰好是这一轮唯一新增证据的那一步**。

---

## 3. 修法与证明

修法是两行（两个分支都要，否则 `--settle` 一给就丢）：

```sh
run_step 03-heat-chain "..." "$HEAT" --yes --settle "$SETTLE" --outdir "$OUT/03-heat-chain"
run_step 03-heat-chain "..." "$HEAT" --yes --outdir "$OUT/03-heat-chain"
```

`INDEX.txt` 里第 03 行也跟着点出它（`... its own archive (with the A/B reading) is in 03-heat-chain/ inside this one`），
因为一个指不到东西的 INDEX 正是这一轮要修的那个形状。

**证明这件事需要一个会说谎的替身。** harness 里那五个 callee 替身现在**认识 `--outdir`**，
而且它们模拟的是**真脚本的形状**，不是方便的形状：

```sh
case "$2" in CAPTURE|HEAT) marker_files=1 ;; *) marker_files=0 ;; esac
if [ "$marker_files" = 1 ]; then
  out=; want=0
  for a in "$@"; do ... [ "$a" = --outdir ] && want=1; done
  [ -n "$out" ] || out="${FP_FALLBACK_DIR:-/tmp/zl1-rb-fallback}"
  mkdir -p "$out" && printf ... > "$out/INDEX.txt" && printf ... > "$out/06b-heat-ab.txt"
fi
```

两个细节是刻意的：

* **只有 CAPTURE 和 HEAT 归档。** 五个步骤里只有这两个真脚本会自己做归档；另外三个
  （panic guard、fingerprint、trial）是写设备状态的 installer，**不归档**。一个让它们也归档的替身
  是在**发明**一个被测对象对不上的形状——这是这一族一直记的那个缺陷。
* **没给 `--outdir` 时写进一个环境变量指的地方，不是 `$PWD`。** `$PWD` 会是仓库根目录，
  于是变异场景会在仓库里留下未跟踪的文件 —— 而家族 runner（`129`）会因为**和这个被测对象无关的原因**变红。
  这本身是刚加的那条树指纹的一次真实约束。

断言因此是**双向**的：

```sh
[ -f "$OD1/03-heat-chain/06b-heat-ab.txt" ] && ok "step 03's own archive -- including the A/B reading -- lands INSIDE this boot's archive"
[ ! -f "$FALLBACK/06b-heat-ab.txt" ] && ok "and NOTHING was archived into the directory an outdir-less step would have made for itself"
```

——第二句之所以不是废话：确实有四个步骤**没有**归档，所以它测的是"该归档的都拿到了地方"，
不是"什么都没发生"。

---

## 4. 顺带：这个 harness 一直没有变异机制

`127` 引用了这个 harness 的两个变异（"删掉拒绝 = 18 条红，只删校验和 = 4 条红"），
而**那一次是手工做的**：

```sh
cp scripts/host/zl1-one-boot-runbook.sh /tmp/rb.bak
sed -i 's/^if wanted 03-heat-chain; then$/if false; then/' scripts/host/zl1-one-boot-runbook.sh
bash scripts/host/zl1-one-boot-runbook-selftest.sh            # 18 条红
cp /tmp/rb.bak scripts/host/zl1-one-boot-runbook.sh
```

**那是一套流程，不是一个机制。** 家族刚立的规矩（`129` 引 `110`/`128`）要的是后者：
一个**每次都跑、而且自己会红**的变异。现在第 10b 节有真的 `mutate()` / `mutrun()`，
和兄弟 harness 里那个一样：先断言这个 `sed` **确实改到了被发出的脚本的一行**（否则"变异体"
和被测对象行为完全一样），再断言变异体**解析得动、且走到了那些步骤**。

新加的这一个变异就是这一轮的检查：

| 变异 | 结果 |
|---|---|
| 从被发出的脚本里删掉 ` --outdir "$OUT/03-heat-chain"` | 运行**仍然 `exit 0`**（返回码看不出这件事），但**归档里不再有读数**，而**替身目录里出现了** —— 双向断言同时红 |

第一版的变异体**每个都 `exit 2`**，原因和变异无关：我把它们放在 `$W/mut/`，
而被测对象是用 `$HERE/../install-*.sh` 和 `$HERE/../../scripts/` 解析兄弟文件的，
于是它读到的是 `$W/mut/../install-netwatch-service.sh`——**不存在**。变异体现在写在
**重写过的被测对象旁边**（`$W/fake-repo/scripts/host/`），和发烫链 harness 里 `CHAIN_DIR` 的做法一致。
被 `mutate()` 的"这个 sed 改到了吗"守卫抓不出来这种——那个守卫只问 sed 有没有**改到**——
是**断言**（"运行仍然 `exit 0`"）抓出来的。

---

## 5. 第三个发现：另一页也写着这些数字，而没有任何东西读它们

改 `scripts/README.md` 的时候顺手比了一遍两页的数字——**每个 harness 都有一行，而健康检查里那条引用是被
那个 harness 自己核对过的**（`4d` 保证自查代码在，每个 harness 拿它和自己这次运行的实际数字比对）。
比较的结果是一条**从 `127` 起就过期**的行：

```
zl1-one-boot-runbook-selftest.sh        95      127   <-- MISMATCH
```

`127` 把它从 95 改成 118（`95 → 118` 写进了文档），`130` 又改到 127 —— 而
**`scripts/README.md` 那一行一次都没有跟着动**，因为它**不在任何检查的视野里**：
meta-harness 只检查"被健康检查点名的 harness 必须带自查代码"（4d）和"表格行必须闭合"（4d 旁边的 (d)），
**没有一条读那些数字本身**。

修法不是把 95 改成 127，是让这两页**对不上就红**。新的第 4f 节：

* 把健康检查**拉平成一整行**（它是会折行的：`zl1-heat-fix-chain-selftest.sh,` 结束于一个字符串字面量，
  `159 checks.` 从下一个开始——一行一行读的人**根本看不到那个数字**）；
* 用 awk 在拉平后的文本上走 `<名字>.sh<分隔><数字> checks`，**一次一个匹配、匹配完往后推**，
  这样同一个名字出现两次也不会自己把自己盖掉；
* 再读 `scripts/README.md` 的每一行脚本表，取出第一个 `**N checks**`，和上面对上的那条比；
* **印出真正比过的行数并设下限（8）**：输出是"不一致的行"，所以"0 行输出"既可能是"全都一致"、
  也可能是"提取器什么都没匹配到"，而这两种**不能是同一种读数**。

那个提取器**第一版是错的**，而错法值得记：`n = t; sub(/^.*[ ,(]/, "", n)` 里的 `^.*[ ,(]` 是**贪婪**的，
它一路吃到了数字**后面**那个空格（`checks` 前面的那个），于是每一条引用都读成了字面量 `checks`——
13 行全部"不一致"。修法是**先剥掉单位再剥名字**：

```awk
n = t; sub(/ checks$/, "", n); sub(/^.*[ ,(]/, "", n)   # strip the UNIT first, then the name
```

而且这一节**自己也带来了一个被测的东西**：`zl1-cli-usage-selftest.sh` 的第 4e 节有一个
"散文扫描器"，专门抓"双引号字符串里的反引号就是命令替换"——它**第一次跑就把这一节抓了出来**
（awk 里的 `"| \`"` 和 `"index(rest, "\`")"`），于是反引号现在用 `sprintf("%c", 96)` 生成。
一条刚写的检查被同一棵树里另一条检查抓住，是这一族最想要的形状。

---

## 6. 这一轮**不**证明什么

* **不证明第 03 步的归档是这次 boot 的完整记录。** 它证明的是**链自己的归档在 boot 的归档里面**；
  链**内部**每一步写了什么、够不够一次复盘，是链自己的 harness 的事（`118`/`128`）。
* **不证明别的步骤也有归档。** panic guard、fingerprint、trial 三者的输出是 runbook 抓的 stdout
  （`$OUT/<step>.txt`）——它们**没有**自己的归档目录，也不该有；这一轮只把**会自己归档的那两个**统一了。
* **不证明 `$OUT/03-heat-chain` 这个名字是对的。** 它是照着第 01 步的 `$OUT/capture` 起的；
  一个目录名没有对错，但**"boot 的 INDEX 点得到它"**有，而那条被断言了。
* **不证明 runbook 跑得通。** 完整链路**一次都没有在设备上跑过**，这一轮改的又是这条链路上的一个参数。
* **不证明设备侧的任何事。** 整轮没有一次 ssh。
* **4f 不证明 `scripts/README.md` 里那些没有出现在健康检查里的 harness 行。** 它比的是"两页都写了的那些"——
  今天 13 行。另外的行（比如只在这一页出现的）它对不上，也就不检查；那个数字由 row 数下限报出来，
  不是假装覆盖了。

---

## 7. 设备状态与复现

整轮没有动设备：没有写任何分区或 boot，没有跑 QDL/QFIL，没有重启。设备仍在 **Qualcomm EDL**
（`05c6:9008`，port 3-3，无序列号）。识别目标一律按序列号 **`33e80afe`**；总线上另一台小米
**`4a2fe00b`** 必须忽略。恢复仍然只能靠**物理长按电源 10–20 秒**。

```sh
# 全部在宿主机上，不碰设备。
bash scripts/host/zl1-one-boot-runbook-selftest.sh      # 127 项
bash scripts/host/zl1-selftest-family.sh                # 19 个 harness / 2169 检查

# 这一轮的核心读数：第 03 步现在被明确告知归档到哪里。
grep -n '03-heat-chain"' scripts/host/zl1-one-boot-runbook.sh

# 变异自己会不会红（第 10b 节就在 harness 里，跑它并读那五行）：
bash scripts/host/zl1-one-boot-runbook-selftest.sh | sed -n '/10b\./,/^== 11/p'
```

| 文件 | 作用 |
|---|---|
| `scripts/host/zl1-one-boot-runbook.sh` | 改：第 03 步两个分支都加 `--outdir "$OUT/03-heat-chain"`，并写下理由；`INDEX.txt` 里那一行点出该目录 |
| `scripts/host/zl1-one-boot-runbook-selftest.sh` | 改：替身 outdir-aware（只对会归档的两步）；双向断言；**新的第 10b 节**（真 `mutate()` + `mutrun()`）与那个变异 |
| `scripts/host/zl1-health-check.sh` | 改：runbook harness 的引用 118 → 127，说明里加上"第 03 步被告诉归档到哪里"这一段 |
| `scripts/README.md` | 改：runbook harness 行 **95 → 127**（从 `127` 起就过期的那个数字）、meta-harness 行补上 134，并补上第 03 步的归档说明 |
| `scripts/host/zl1-cli-usage-selftest.sh` | 改：**新的第 4f 节** —— 把 `scripts/README.md` 里每个 harness 的检查数和健康检查里那条（已被各自 harness 自查过的）引用**配对比较**，印出真正比过的行数并设了下限，还用一个夹具对在两个方向上都演示过（包括第一版那个把数字本身吃掉的提取器 bug）；引用 129 → 134 |
| `docs/ubuntu-touch/124-*.md` | 追记：家族检查数（数字留着，更正贴着写） |
| `docs/ubuntu-touch/130-*.md` | 本篇 |
