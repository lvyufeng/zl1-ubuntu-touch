# 75 — 返回键通了：**断点精确到一行**，三次尝试才对上 shell 真正的语义；持久化已装好，但"开机就生效"还没有经过一次重启验证

**日期**: 2026-09-23
**状态**: **用户按下去，应用最小化、回到启动器 —— 返回键工作了。** 这个过程里量到了三件互相独立的事：(1) 键**确实**到了 shell（日志有一行 `zl1-back:`，里面带着 `Qt.Key_Back` 的键码），断的是**动作那一行**；(2) 第一版动作抛 `TypeError`，第二版动作**完全不报错但什么也不发生** —— 因为手机模式下这个 shell 根本没有"最小化的窗口"这个状态；(3) 最后能用的，是 **Home 键本来就在用的那一次调用**。持久化的 unit 已装好并**手工走通了它开机会走的那条路**，但"systemd 在开机时真的会跑它"这件事没验过，见 §5。

**接续**: [`73`](73-the-user-fingers-settled-the-back-key.md)（断点在 shell、shell 里一个 `Qt.Key_Back` 处理器都没有、以及那 51 秒的按键记录）、[`74`](74-the-speaker-path-is-complete-in-software.md)（同一轮里用户用耳朵确认的另一件事）

---

## 1. 用户的手指定案：键到了 shell，断在动作那一行

用户在浏览器（`morph-browser`）在前台时按返回键，日志里每一按都是**恰好一行**：

```
[35914.072834] qml: zl1-back: key=16777313 nvk=undefined spread=false app=morph-browser
[35914.818294] file:///usr/share/lomiri//Shell.qml:306: TypeError: Type error
```

两件事同时确定：

- **16777313 = `Qt.Key_Back`**（0x01000061）。这一行是我的处理器自己打的，所以**键走完了从硬件到 shell 的全程**，`[`73`](73-the-user-fingers-settled-the-back-key.md)` 里"没有处理器"的判断也就被替换成了"处理器在了、而且被调到了"。
- `Shell.qml:306` 就是**动作那一行**（`stage.onMinimizeClicked();`）。是它抛的 TypeError。

补一句 `[`73`](73-the-user-fingers-settled-the-back-key.md)` 之外的账：`spread=false`、`app=morph-browser` 说明**判据本身是好的**（铺开界面没开、前台应用的名字也读出来了），坏的只是动作。

## 2. 尝试二：把动作换成 shell 自己的最小化信号 —— 不报错，也不动

`onMinimizeClicked` 不是 `Stage` 的公开函数，它是 `Stage/Stage.qml` 里的一个**信号处理器**：

```qml
Connections {
    target: panelState                       // PanelState { id: panelState }，在 Shell.qml 里
    function onMinimizeClicked() { if (priv.focusedAppDelegate) { priv.focusedAppDelegate.requestMinimize(); } }
}
```

所以显然的修法是**发这个信号**：`panelState.minimizeClicked()`（`Shell.qml:368` 把 `panelState: panelState` 传给了 `Stage`，两边是同一个对象；QML 里信号可以当函数调用）。改完重装、重开 shell、用户再按：

```
[37346.151335] qml: zl1-back: key=16777313 nvk=undefined spread=false drawer=false app=morph-browser
```

**没有 `TypeError` 了，但屏幕上什么也没发生。** 原因在同一个文件里，而且是能读出来的：

```qml
// Stage.qml，绑定到 PanelState
property: "decorationsVisible"
value: mode == "windowed" && priv.focusedAppDelegate !== null && ...
```

**窗口装饰（也就是最小化按钮）只在 `mode == "windowed"` 时存在**，而这台手机跑的是 `mode == "staged"`（`Shell.qml` 里 `mode: usageScenario == "phone" ? "staged" : …`）。也就是说：**手机模式下这个 shell 没有"被最小化但还在的窗口"这个状态**，`requestMinimize()` 发出去是对的、收到也是对的、然后它无处可去。`priv`（`minimizeAllWindows()` 住在那里）从 `Shell.qml` 够不到。

> 这一条值得单独记住：**"没有报错的无效"比报错更难查**。所以每次改完都要让用户真的按一下，而不是看到日志里没有 error 就当作修好了。

## 3. 尝试三：Home 键走的那条路 —— 通了

Home 键（`HOMEPAGE`，172）是用户见过管用的键，`Shell.qml` 里它的处理器只有一句：

```qml
WindowInputMonitor {
    onHomeKeyActivated: {
        if (!greeter.active) {
            launcher.toggleDrawer(/* focusInputField */ false,
                                  /* onlyOpen */        false,
                                  /* alsoToggleLauncher */ true);
        }
    }
}
```

于是返回键改成同一句（并且保留 `greeter.active` 这道锁屏时的防误触护栏）：

```qml
if (stage.spreadShown) {
    stage.closeSpread();
} else if (!greeter.active && (stage.mainApp || launcher.drawerShown)) {
    launcher.toggleDrawer(false, false, true);
}
```

`Launcher.toggleDrawer` 是**切换**：启动器抽屉开着就关掉，否则把启动器推到前面（也就是"离开这个应用"）。用户按完的日志和这句话逐字对上 —— `drawer` 一按一变：

```
[37346.151335] zl1-back: … spread=false drawer=false app=morph-browser
[37346.726812] zl1-back: … spread=false drawer=true  app=morph-browser     <- 抽屉开了
[37347.162912] zl1-back: … spread=false drawer=false app=morph-browser     <- 又关了
[37347.559342] zl1-back: … spread=false drawer=true  app=morph-browser
[37347.932174] zl1-back: … spread=false drawer=false app=morph-browser
[37348.393701] zl1-back: … spread=false drawer=true  app=morph-browser
```

**用户的原话是"有反应了，回到启动器桌面"。** 没有任何一次按伴随报错（`Shell.qml` 那几行 TypeError 是开机时 Panel/WorkspaceSwitcher 的存量噪声，每次按下后面都没有它）。

## 4. 安装方式没有变：只读镜像 + 运行时 bind mount

改动仍然只在 `/userdata/zl1-shell-overlay/Shell.qml`（一份改过的 `Shell.qml`），`mount --bind` 盖在只读镜像的 `/usr/share/lomiri/Shell.qml` 上。安全性还是那三道闸：**精确字符串匹配**（锚点出现次数不等于 1 就拒绝）、**`qmllint` 两份对比**（stock 1 行诊断，patched 也是完全相同的那 1 行 —— 没有引入新错误）、以及**只有前两步过了才 mount**。

## 5. 持久化：unit 装好了，开机那条路手工走通了，但"开机时真会跑"还没验

`mount --bind` 不过重启，所以每次开机返回键都会重新失灵。持久化的做法是 `scripts/install-shell-back-key.sh --persist`：

| 装到哪 | 是什么 |
|---|---|
| `/etc/systemd/system/zl1-shell-back-key.service` | `Type=oneshot`、`RemainAfterExit=yes`、`After=local-fs.target`、`RequiresMountsFor=/userdata`、`Before=multi-user.target graphical.target`、`ConditionPathExists=/userdata/zl1-shell-overlay/Shell.qml` |
| `/etc/systemd/system/zl1-shell-back-key.sh` | 应用脚本体，来自仓库里的 `scripts/device/zl1-shell-back-key-apply.sh` |

（`/etc/systemd/system` 是本机少数可写的路径之一；只读镜像零写入。`systemctl cat` 是唯一诚实的检查 —— 已确认 diff 里就是上面这些行、`is-enabled` = `enabled`。）

**这颗 unit 的失败模式是"黑屏"，所以它的护栏是有顺序的、而且都记日志**（`/userdata/zl1-shell-back-key.log`，带 uptime，因为这台设备的墙上时钟是错的）：

1. `/userdata/zl1-shell-back-key.disabled` 存在 → 什么都不做。**这是逃生舱**：SSH 上 `touch` 一下再重启，stock shell 就回来了（shell 坏了不影响 SSH 和容器）。
2. overlay 不存在/为空 → 不做。
3. overlay 里没有补丁标记 → 不做（半截文件绝不许盖到 shell 上）。
4. mount 之后**读回来**验证：能读到标记才算成功，否则 umount 并记 error。

**开机那条路是手工走通的**（把 overlay umount 掉 → 跑那支应用脚本 → 目标路径又变回打过补丁的文件、marker 读得到、`exit=0`）。**没有验证的是"systemd 在开机时会跑它"** —— 这需要一次真正的重启，而按用户的规矩（`[`72`](72-the-heat-was-the-governor-and-a-debug-keeper.md)` §3 的 keeper、`[`73`](73-the-user-fingers-settled-the-back-key.md)` 的登录），重启要用户点头才做。**在验证之前 `--persist` 的效果按"未证明"记。**

## 6. 我自己的两个工具 bug（都是"先手工跑一遍"抓出来的）

1. **`grep -q "$MARKER"` 里的 `$MARKER` 以 `---` 开头** → grep 把它当选项，报 `unrecognized option` 并**走了"什么都不做"那条路 —— 而理由是错的**。修法是 `grep -q -- "$MARKER"`。如果没手工跑那一下，这条会一直躺着，直到某次开机莫名其妙不生效。
2. **不能用 `findmnt -no SOURCE` 去比对 overlay 的完整路径**：findmnt 显示的是**相对于承载它的那个文件系统的子路径**（`/userdata/...` 显示成 `/dev/sda10[/zl1-shell-overlay/Shell.qml]`），所以 `grep /userdata/zl1-shell-overlay/Shell.qml` 会**失败**，而挂载其实是好的。第一版就是这么写的，于是**它挂上之后立刻又自己卸掉**（日志留下 `ERROR … is not backed by …`）。修法不是改 grep，而是**换成读回来验证**：在目标路径上直接找补丁标记 —— 那才是真正要问的问题。

## 7. 文件与复现

| 文件 | 作用 |
|---|---|
| `scripts/install-shell-back-key.sh` | `--install` 造 overlay（含 `qmllint` 双份对比 + 锚点唯一性）并挂上；`--remove` 撤掉；`--status` 看挂载状态和 shell 打过哪些键；`--persist` 装开机 unit；`--unpersist` 撤掉它。**`--install` 会先卸掉已有 overlay 再从 stock 文件重建**（不卸的话锚点读到的是打过补丁的文件，会以 `ANCHOR NOT FOUND EXACTLY ONCE (0)` 中止） |
| `scripts/device/zl1-shell-back-key-apply.sh` | 开机应用脚本。带 §5 的四道护栏，全部记日志；`grep -q --` 那个坑写在注释里 |
| `scripts/device/zl1-watch-input.py` | 那 51 秒的按键记录（`[`73`](73-the-user-fingers-settled-the-back-key.md)`） |

```sh
# 装（运行时）
bash scripts/install-shell-back-key.sh --install
# 让它过重启（顺序不能反：先 --install 确认能用，再 --persist）
bash scripts/install-shell-back-key.sh --persist
# 看 shell 有没有接到键（返回键是 zl1-back:，别的键是 zl1-key:）
bash scripts/install-shell-back-key.sh --status
# 逃生舱：先触摸这个文件，再重启
touch /userdata/zl1-shell-back-key.disabled      #（在设备上）
systemctl disable zl1-shell-back-key.service     # 或者用 systemd 撤
```

**设备安全**：改的只有一个只读镜像上被 bind mount 盖住的文件（`umount` 即撤销，只读镜像零写入）、`/userdata/` 里的 overlay 副本、以及 `/etc/systemd/system` 里新增的两个文件（`--unpersist` 撤）。重启过一次 greeter（用户的会话，不是设备），重启过多次 shell 进程。**没有**重启设备、没有碰任何分区或 boot 镜像、没有进容器改文件。容器 RUNNING，`systemctl --failed` 空，SSH 正常。
