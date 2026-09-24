# 119 — 那扇门的第一个客户端，终于有人去敲了

**日期**: 2026-09-24
**状态**: 本轮**没有碰设备**（设备仍在 EDL，见 §7）。全部是 host 侧：把 `105` 里那段**只存在于文档里的命令片段**
变成一件**仪器** —— 一个会去敲门、会读门、会说出**哪一道闸回答了**、并且**把设备放回原样**的脚本，配一个 62 检查的
离线 harness。**没有在设备上安装任何东西，没有 flash，没有写分区，没有绕过权限。**

**接续**: [`105`](105-the-gps-door-already-has-a-client-the-weather-app.md)（第一个客户端是预装的天气应用）、
[`93`](93-gps-the-door-is-a-client-request-and-the-two-levers-are-dead.md)（门 = 客户端请求，两把钥匙插不进去）、
[`82`](82-*.md)（`locClientOpen` 这条字符串是**在这台设备上量到的**）、
[`117`](117-the-command-that-could-not-run-is-not-a-zero.md)（跑不起来的命令不是一个 0）、
[`104`](104-the-camera-app-instrument-measured-in-the-wrong-unit.md)（仪器先读应用自己的状态）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 这一轮做了什么？ | `scripts/host/zl1-gps-first-client.sh`：让**预装的天气应用**去要一次位置，然后读出**三道闸里哪一道回答了** |
| 为什么这是一件仪器而不是一段文档？ | 因为 `105` §5 给的就是一段**命令片段**，而 `105` §6 明说**天气应用从来没在这台设备上起过**。一次从没发生过的运行、只用散文写下来，正是这个仓库一直在消灭的形状 |
| 为什么客户端是天气应用？ | 因为它**自己的 AppArmor profile 就带着 `location` 政策组**，所以这条路**不需要任何绕过** —— 和 `zl1-location-request.sh --enable-testing`（一个真的权限绕过）不是同一件事 |
| 「门开了」的判据是什么？ | **`locClientOpen`**，而且**只有它**。理由见 §3：这条字符串是 `82` **在这台设备上量到**的，而守护进程对于"它**接受**了一个会话"会写什么，这个仓库里从来没有读到过 |
| 应用里那个开关谁来开？ | **人**。屏幕和触摸都已经由用户确认可用，脚本把它转成一句给手边的人看的提示。脚本**读**这个开关，**从不写**它 |
| 离线验证？ | `zl1-gps-first-client-selftest.sh` **62 检查 / 0 失败**；写它的过程中抓到 **3 个脚本缺陷 + 4 个 harness 自身缺陷**（§4/§5） |
| 动设备了吗？ | **没有。** 设备仍在 EDL；GPS **仍然没有任何一次 fix** |

---

## 2. 为什么这件事必须由"人去敲"来完成

`93` 把 GPS 的结论定在两层：**门的机制**（`u_hardware_gps_new` / `u_hardware_gps_start` 只从客户端的一次
`StartPositionUpdates` 里的**虚调用**到达，所以守护进程自己的启动**根本不碰硬件**）和**门前的锁**
（一个默认关闭的 trust store 闸）。`105` 接着找到了**谁可以敲**：

* 天气应用（click `weather.ubports`，app id `weather.ubports_weather_6.2.0`），**预装**；
* 它的 QML 里有 `import QtPositioning` 和 `PositionSource { active: settings.detectCurrentLocation }`；
* 它的 `.apparmor` 里 `policy_groups` **第一项就是 `location`**。

也就是说：**系统支持的那条路是通的，需要的是一个客户端去按它**。而 `105` §5 把这一步留成了一段要手打的
`ssh` 片段，并且 §6 明确记下：**天气应用从来没在这台设备上起过**。

于是这一轮把它写成仪器。和这个项目里每一件仪器一样，它必须回答的不是"我跑过了"，而是
**"门到底有没有动，以及如果没动，是哪一道闸没动"**。

---

## 3. 「门开了」的判据只有一个字符串，而且这是刻意的

最初的版本把 `CreatingSession` 也算成正向证据。**那是错的**，而且错的方向很值得记下来：

* `CreatingSession` 是**客户端看到的那条错误的名字**（`Error.CreatingSession`），也就是**被拒绝**那一侧的
  词汇（`93` §3.2）；
* 而守护进程**接受**一个会话时会写什么，**这个仓库里没有任何一次读到过**。

把一条**猜的**成功字符串放进表格、再让 verdict 去读那张表格，正是 `102`/`103` 记下来的那件事：
**一条日志字符串只可能出现在包含它的那个进程的日志里**。所以现在的结构是：

| 证据 | 来源 | 地位 |
|---|---|---|
| **`locClientOpen`** | 容器侧 logcat（vendor HAL） | **唯一的正向前提**。它是 `82` **在这台设备上量到**的字符串，而那段代码只能从 `u_hardware_gps_*` 到达（`93`） |
| `Client lacks permissions` | UT 侧守护进程 journal | **唯一可靠的负向证据**（`93` §3.2 记的就是这句话） |
| 其余新增行 | UT 侧 | **信息**，打印并归档，**不构成判决** |

于是有了这条新的分支：守护进程**记了点什么**、但既没有 `locClientOpen` 也没有那句拒绝 —— 结果是
**"SOMETHING WAS LOGGED，去读 delta"**，而不是"门开了"。**这一条是 harness 逼出来的**（§5.1）。

---

## 4. 脚本本身：它做什么，以及它**不做**什么

顺序：**读状态 → 开屏 → 标记 journal → 起应用 → 交给手边的人 → 再读门 → 停应用、恢复屏幕 → verdict**。

### 4.1 标记按**行号偏移**，不按时间

```sh
jlines() {
  ssh_d "if journalctl -b -u $JL --no-pager -o cat > /tmp/zl1-jl.txt 2>/dev/null; then
      wc -l < /tmp/zl1-jl.txt
    else
      echo COULD-NOT-RUN
    fi"
}
```

两个理由，第二个是这一轮改出来的：

1. 这台设备的**墙上时钟是错的**，`journalctl -n` 的顺序会跟着骗人（`64`，`69`/`91` 都吃过这个亏）。
   行号偏移是**关于这一次 boot 的事实**，完全不碰时钟。
2. **一次标记只能读一次 journal。** 最初的写法是"跑一次确认它能跑，再跑一次数行数"—— 两次**都是读数**，
   而一个会轮转的 journal 会让这两次落在不同的地方。离线 harness 注入 `shrink` 的时候正是这样：
   同一个标记里被读到了两次，**注入的收缩被自己抵消掉了**，场景于是测不出任何东西。

### 4.2 标记**不可信**的时候，答案是 UNANSWERED

```sh
MARK_OK=1
case "$BEFORE_N" in ''|*[!0-9]*) MARK_OK=0 ;; esac
case "$AFTER_N"  in ''|*[!0-9]*) MARK_OK=0 ;; esac
if [ "$MARK_OK" = 1 ] && [ "$AFTER_N" -lt "$BEFORE_N" ]; then
  MARK_OK=0
  say "   WARNING: the journal SHRANK ($BEFORE_N -> $AFTER_N lines) ..."
fi
```

如果 journal **变短了**，`tail -n +N` 吐出来的是**启动之前**的行 —— 那意味着一次旧
`Client lacks permissions`、甚至一段旧的"会话创建"被当成这一次的证据。所以收缩一旦被发现，
门就被报成 **UNANSWERED**，而不是一个读者会当成结论的东西。

同样地，**logcat 跑不起来**和"客户端没开"是两件事：脚本打印 `LOGCAT-COULD-NOT-RUN`，并明说
**下面的 0 是这个原因**。这是 `117` 那条规矩的第三次应用（前两次是指纹探针和 heat 链）。

### 4.3 那个开关：**读**，而且只有三种答案

```sh
if [ -r "$SET_DIR/$SET_DB" ] && command -v sqlite3 >/dev/null 2>&1; then
  v=$(sqlite3 "..." "select value from ItemTable where key like \"%detectCurrentLocation%\";")
  echo "setting=${v:-no-row}"
elif [ -r "$SET_DIR/$SET_DB" ]; then
  echo "setting=cannot-read-no-sqlite3"
else
  echo "setting=cannot-read-no-database"
fi
```

**没有写模式，而且是刻意的。** `105` §6 记着：那个键**确切**读在哪里，是**推出来的、不是量到的**
（从迁移脚本的算法 + Qt LocalStorage 的约定）。往一个**活着的** sqlite 设置库里按猜测写，就是让一个应用
丢掉它设置的方式。而这件事本来也不需要写：屏幕和触摸都已经确认可用，**人**在应用里点一下就行。

脚本把这件事变成一句**必须被读到**的提示，走 **stderr**、**不受 `--quiet` 影响**：

```
   ----------------------------------------------------------------
   ON THE PHONE: the weather app should be on screen. Open its
   settings and turn ON "detect current location".
   Then leave the phone alone. Waiting 180s ...
   ----------------------------------------------------------------
```

`--seconds` 的**下限是 30**，不是建议：低于它，这次运行量到的是"没人来得及"，而那不是关于 GPS 的事实。

### 4.4 起应用：先走**迁移脚本**，走容器 PID 命名空间，用会话自己的 uid

桌面 Exec 是 `lomiri-weather-app-migrate.py lomiri-weather-app`，而迁移脚本会 `os.execvp` 到真正的二进制 ——
所以**把 wrapper 当二进制传**才是"像 launcher 那样把它起起来"。`105` §6：直接起二进制会跳过它，第一次运行时
（配置/数据库初始化）就缺一块。这一条在 harness 里是**对真正发出去的那条命令行**做的断言，不是对注释做的。

### 4.5 它**从不**做的事

安装任何东西、写分区、开权限绕过、写应用的设置文件、重启定位服务、重启设备。`--keep-app`/`--keep-display`
是给想接着看的人留的；默认它会**停掉应用**并**把屏幕恢复成它找到的样子**。

---

## 5. 离线验证：62 检查，和它抓到的七个缺陷

`scripts/host/zl1-gps-first-client-selftest.sh`：**62 检查 / 0 失败**，干净的一次运行归档在
[`evidence/gps-first-client-selftest-2026-09-24.log`](evidence/gps-first-client-selftest-2026-09-24.log)。
传输层是 stub，**stub 就是设备**；journal 是一个**文件**，长度由 fixture 控制 —— 这正是"journal 读不到"和
"journal 收缩了"这两个场景可以存在的原因，而它们**绝不能被合并成"什么都没记"**。

### 5.1 三个**脚本**缺陷（都是 harness 逼出来的）

| 缺陷 | 它本来会造成什么 |
|---|---|
| 把 `CreatingSession` 当成"门开了"的正向证据 | 门会用**被拒绝那一侧的词汇**来宣布自己开了（§3）。现在只有 `locClientOpen` 是前提 |
| `jlines` 每个标记读**两次** journal | 一个轮转的 journal 会在**同一个标记内**被读到两次，把注入的收缩抵消掉 —— 标记本身不可信，而脚本会照常给结论 |
| `--quiet` 把 verdict 的**标题**也吞了 | `--quiet` 正是为了留下 verdict，结果留下的是没有标题的判决行（这一条同时让 harness **找不到**那个块） |

### 5.2 四个 **harness 自身**缺陷（每一个都会让"通过"没有意义）

1. **`verdict()` 取的是输出里任何一处第一行 `->`。** 脚本在 logcat 那一节有一句
   `-> the count below is 0 because IT COULD NOT RUN`，位于 verdict **之上好几节** —— 于是 verdict 块从那里开始，
   断言在一个不相关的段落上做。现在它**锚定在脚本自己的 `== verdict` 标题**上。
2. **一个 fixture 的删除泄漏到了后面每一个场景。** 场景 2（应用没起来）删掉假的 `/proc/<pid>/cmdline`，
   而 `env_reset` 不重建它 —— 于是**此后每个场景都在测"应用从未启动"**，同时对"门"下断言。
3. **`(ii)` 在 `grep -E` 里是分组，不是字面括号。** `display: (ii) 0 0` 实际只在匹配 `display: ii 0 0`。
   `busctl` 的输出行必须写成 `.ii.`。
4. **PATH 泄漏**（这是真的一个）：这台主机在 `~/miniconda3/bin` 里有 `sqlite3`，而假设备**继承了这台主机的
   PATH**。于是脚本的 `command -v sqlite3` **成功**了，**主机自己的** `sqlite3` 跑在空的 fixture 库上，
   输出 `no-row` —— 而那个场景声称在测**不存在**。`command -v` 是 shell 内建，PATH 里没有 stub 能让一个名字
   **消失**，所以 harness 现在会**构造一条把那个目录去掉的 PATH**。

---

## 6. 这一篇**不**证明什么

* **不证明能拿到 fix。** 门开了不是 fix。位置需要卫星，而下一次读数是 HAL 有没有报出来。
* **不证明开关真的开着。** 脚本不读应用的 UI 状态；上面那个设置读数是最努力的尝试、而且只读
  （`105` §6：那个键的位置是**推出来的**）。
* **不证明 `lomiri-app-launch` 起它会有同样的行为**，也不证明 QML 的 `active:` 真的是从那个键读的。
* **不证明硬件是好的。** 此前每一次读数说的都是"GPS 那一半**从来没被要求做过任何事**"；这一次运行**就是那个要求**。
  答案会不会回来，是下一个问题。

---

## 7. 设备状态与下一步

整轮没有动设备：没有写任何分区或 boot，没有跑 QDL/QFIL，没有重启，没有绕过权限。设备仍在 **Qualcomm EDL**
（`05c6:9008`，无序列号）；唯一的出口是**物理长按电源 10–20 秒**。

顺序（每一步都还没有得到用户的批准）：

```
scripts/host/zl1-post-recovery-capture.sh          # 0 系列读数；探针默认跳过
scripts/host/zl1-heat-fix-chain.sh --yes           # 发烫：部署 → 激活 → 90 s → 证明 → 退役 keeper → governor
scripts/host/zl1-gps-first-client.sh --seconds 180 # 需要手边有人：把 "detect current location" 打开
```

第三个需要**人**：屏幕和触摸已经确认可用，而那个开关是这次测量里唯一必须由手去动的东西。
