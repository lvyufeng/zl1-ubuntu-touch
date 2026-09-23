# 89 — 把"panic → EDL"这条自动升级路径关掉：一条可逆的、不刷机的写

**日期**: 2026-09-23
**状态**: 纯离线的一轮（设备在 EDL，与 `86`–`88` 同）。`86` 把那次 EDL 的机制查清了，而机制里最要紧的一点是**它是默认武装的**：这台设备上**一次内核 panic 就会把 SoC 带着 dload 标志复位，引导程序于是进 EDL 而不是进系统**。而在这个端口上，panic 不是意外——是 HAL/驱动/HWC 里任何一处空指针的日常。于是有一条**白白存在的风险**：每次 bring-up 阶段的 panic 都可能换来一次"只有手指能解"的状态。

这一轮把那条升级关掉。用的是**驱动自己的运行时接口**，不刷任何东西，而且**可逆**：

```sh
echo 0 > /sys/module/<name>/parameters/download_mode
```

同时补上一件本来没人做的事：**每个 boot 把 `/sys/fs/pstore` 抄到持久分区**——`86` 说 pstore 是唯一活过复位的 panic 证据，而在此之前**没有任何东西在保存它**（`install-kmsg-drain.sh` 管的是 kmsg 环形缓冲，那个复位就没了）。

**接续**: [`86`](86-edl-has-a-cause-a-panic-and-the-evidence-survives.md)（机制、pstore、postmortem 脚本）、[`72`](72-the-heat-was-the-governor-and-a-debug-keeper.md)（同一个驱动家族的 Module 参数与 `boot unit` 这套安装方式）、[`58`](58-the-secure-world-refused-and-the-sensors-went-with-it.md)（`scm_call` 会返回 -12，所以"内核侧生效"这一点很重要）

---

## 1. 为什么 `echo 0` 是安全的（三条，都来自源码而不是指望）

**(a) 它不是设备本来不会进入的状态。** `download_mode` 是编译期写死的 **1**（`msm-poweroff.c:63`），而**每一次正常重启都会把它清零**（判断式在 `:279`，panic 之外的分支都为假）：

| 路径 | `msm_restart_prepare()` 的算法 | 结果 |
|---|---|---|
| `systemctl reboot`（cmd="userrequested"） | `download_mode && (in_panic \|\| restart_mode == RESTART_DLOAD)` = `1 && 0` | `set_dload_mode(0)` |
| `poweroff` | `do_msm_poweroff()`（`:396`）里直接 `set_dload_mode(0)`（`:400`） | `set_dload_mode(0)` |
| `reboot recovery` / `bootloader` | `restart_mode` 不是 `RESTART_DLOAD`，`in_panic`=0 | `set_dload_mode(0)` |
| **panic** | `in_panic`=1 | **`set_dload_mode(1)`** ← 唯一的 1 |

也就是说：**标志在 probe 时被置 1（`:582`），在每一条普通关机路径上被清掉，只有 panic 会让它保持 1。** 所以运行时写 0 只改变 panic 那一种情形，别的什么都不动。（这也顺手解释了一件以前没解释的事：为什么 "dload 标志被置上" 和 "日常重启都正常" 不矛盾。）

**(b) 就算安全世界的写失败，内核侧这一层也生效。** `set_dload_mode(on)` 的顺序是：写（本设备不存在的）IMEM magics → `scm_set_dload_mode()` → **记 `dload_mode_enabled = on`**。而 `msm_restart_prepare()` 判断用的是 `get_dload_mode()`，读的就是这个内核变量。`58` 记着这台设备的 `scm_call` 在某些开机里返回 -12——**所以"SCM 可能会拒绝"恰好是这条路径必须存在的理由**，而结构上它也确实不依赖 SCM 成功。

**(c) 接口是驱动自己设计的运行时接口。** `module_param_call(download_mode, dload_set, param_get_int, &download_mode, 0644)`（`:95`），`dload_set` 自己校验取值（只接受 0/1，`:191`）后调 `set_dload_mode`。这不是在绕过驱动，这是驱动给的开关。

## 2. 这件东西**不**做什么（必须写在最前面）

它**去掉一道闸门，不是证明 EDL 不再可能**。`msm_trigger_wdog_bite()` 在 panic 时**照样**执行（`WDOG_BITE_ON_PANIC=1`），而这台设备的引导程序**是否独立于这个标志、把看门狗复位本身也当成进 EDL 的条件**——**从来没有被测过，而且除了真的 panic 一次之外无法被测**。

所以：**它降低的是概率，不是可能性。** 归因一次 EDL 仍然只能靠 `scripts/device/zl1-edl-postmortem.sh`（先看 pstore、再看 kmsg 归档），**永远不能**说"这个 unit 装了所以那次不可能是 panic 进的"。这句话我在**设备侧脚本的每一行日志里重复了一遍**，因为有一天会有人翻日志来判断"那次是不是不可能因为 panic 进 EDL"——那个答案必须在日志里，不能在一篇他没打开过的文档里。

另外，`--remove` 会把标志**写回 1**（镜像的编译默认值），所以"拆掉"也是干净的：设备回到装之前的样子。

## 3. 第二个 unit：pstore 的抄写者（这一件零风险）

`86` 说 pstore/ramoops 是**唯一活过复位**的 panic 证据。但查过之后：**没有任何东西在保存它**——

```
$ grep -n "pstore\|ramoops" scripts/install-kmsg-drain.sh
（无输出）
```

kmsg drain 管的是 `/dev/kmsg` 的环形缓冲（复位即失），pstore 是另一回事，一直没人抄。而 ramoops 那块 1 MiB 区域会随之后的开机被复用/绕回，所以"证据在那里"和"证据还在那里"不是同一句话。

所以第二个 unit 在**每个 boot 尽量早**把 `/sys/fs/pstore/*` 抄进 `/userdata/zl1-kmsg/keep/pstore-<boot_id>.pstore/`，写一行索引到 `pstore-archive.log`，保留最新 4 份（和 kmsg 归档同一套策略）。它**只读内核、只写 `/userdata`**，不改任何策略——所以它可以单独装（`--capture-only`），也可以和上面那条策略一起装（`--install`）。

## 4. 两个"仪器自己会说谎"的地方，已经改掉（本轮实测抓到的）

这一轮的脚本在本机用**打桩的 `ssh`**（把远程命令和 stdin 抄到文件）和**打桩的 sysfs** 跑过，抓到两个真问题：

1. **写失败时它声称成功。** 第一版 `dload_set` 失败（只读 sysfs）时打印 `1 -> 1` 然后**退出 0**——于是 unit 报告 `Result=success`，而闸门根本没关。这正是这个项目反复抓到的那种形状（命令跑得通、有输出、但没回答那个问题）。**现在读回验证，不等于 0 就 `exit 1`**：一个"悄悄没关上的闸门"比一个出现在 `systemctl --failed` 里的 unit 危险得多。这个失败会**每次开机都出现**，而 `zl1-health-check.sh` 自查里就有 `systemctl --failed`，所以它一出现就会被看见。
2. **`--capture-only` 会偷偷把已装的策略 unit 删掉。** 第一版里它无条件地 disable+delete 那个 unit——也就是说"我只是想看一眼"会把一个已经装好的闸门**朝不安全的方向**拆掉。现在 `--capture-only` **完全不碰**策略 unit，并明确打印它现在是装着的还是没装。

## 5. 验证到什么程度

* **交付内容用打桩 ssh 验证过**：四个模式（`--install`/`--capture-only`/`--remove`/`--status`）都跑通、退出 0，**并且把真正要送到设备上的四个文件抄下来逐字检查过**（两个 applier + 两个 unit）——确认 here-doc 里没有一个 `$(...)`、反引号或 `$P` 被本机 shell 提前展开。
* **`zl1-panic-guard.sh` 四个场景**（打桩 `/sys/fs/pstore` + `/userdata`）：有 panic 记录（抄下来、索引写对、**原文里 `Kernel panic` 还在**）、pstore 为空（干净退出且**一个目录都不建**）、五份归档时按 mtime 只留最新四份、`/sys/fs/pstore` 整个不存在（退出 0，不把 unit 判失败）。
* **`zl1-no-edl-on-panic.sh` 四个场景**（打桩 `/sys/module/*/parameters/`）：正常写入 `1 -> 0` 且退出 0、幂等、**写不动（值停在 1）时退出 1 并明说闸门没关上**、参数不存在时退出 1。第三个场景要用"已武装 + 写不进去"才算真测到——第一版打桩先用幂等场景把值留成了 0，于是 `0 -> 0` 读回"成功"、退出 0，**这不是脚本的 bug 而是测试的 bug**，但它说明这一条必须用武装态去测，否则测的是一个恒真的判断。
* **没有在设备上跑过任何东西**（设备在 EDL）。未验证的是设备侧的事实：那个 sysfs 路径是不是 `/sys/module/msm_poweroff/parameters/download_mode`（脚本用 glob，不写死；`msm-poweroff.o` → 模块名应是 `msm_poweroff`，**没在真机上确认过**）、`/sys/fs/pstore` 复位后到底有没有东西、以及**上面 §2 那个根本问题**（关掉标志是否真的足以不进 EDL）。
* **因此：本轮交付的是"一个已校验的执行器 + 一条可逆的策略"，不是结果。** 真正的验证只能是"下一次 panic 时它正常重启了"或者"pstore 里有东西"。

## 6. 复现

```sh
# 宿主机：语法 + 把发货内容抄下来看（不需要设备）
bash -n scripts/install-no-edl-on-panic.sh
bash scripts/install-no-edl-on-panic.sh --help

# 设备在线时（先装 capture，再看装了什么）
scripts/install-no-edl-on-panic.sh --capture-only
scripts/install-no-edl-on-panic.sh --status

# 确认之后，装上策略那半
scripts/install-no-edl-on-panic.sh --install
scripts/install-no-edl-on-panic.sh --status     # 标志应为 0，两个 unit active

# 反悔
scripts/install-no-edl-on-panic.sh --remove     # 标志写回 1，unit 删除，归档保留
```

| 文件 | 作用 |
|---|---|
| `scripts/install-no-edl-on-panic.sh` | 新增。`--status`（默认）/ `--install` / `--capture-only` / `--remove`。装两个 unit：`zl1-panic-guard.service`（每 boot 抄 pstore 到 `/userdata/zl1-kmsg/keep/pstore-<boot_id>.pstore/`，保留 4 份）和 `zl1-no-edl-on-panic.service`（把 `download_mode` 写 0，**读回验证，失败即退出 1**）。都装在 `/etc/systemd/system` 那条 rw 路径上；不刷分区、不动 boot 镜像 |
| `docs/ubuntu-touch/86-*.md` | 机制与 pstore 的来源（本篇依赖它） |
| `docs/ubuntu-touch/89-*.md` | 本篇 |

## 7. 这一轮**不**证明什么

* **不证明 EDL 不再可能**（§2）：去掉了一道闸门，看门狗咬死那条路没动，而"看门狗复位是否独立触发 EDL"在这台设备上没有证据。**这一条不允许被简化成"已经防住了"。**
* **不证明**关掉标志之后一次 panic 会正常重启——那需要真的 panic 一次。
* **不证明** pstore 能活过复位（`86` §7 已经写明这台设备上从未验证过）；capture unit 的价值恰恰在于如果它活着，就会被留下来。
* **不改动设备**：设备在 EDL，本轮对它的操作是零。上面所有"验证过"都指本机打桩测试。
* 不碰 [`86`](86-edl-has-a-cause-a-panic-and-the-evidence-survives.md) §4 那个**永久**方案（改内核一行 + 刷 boot 镜像）——那仍然是一次刷写，仍然需要明确许可，本轮没有做也没有替代它。
