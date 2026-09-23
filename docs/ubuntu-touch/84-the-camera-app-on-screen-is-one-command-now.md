# 84 — "相机 app 的窗口到底有没有到屏上" 现在是一条命令

**日期**: 2026-09-23
**状态**: 纯离线的一轮（设备在 EDL，见 [`80`](80-the-ut-camera-app-starts-and-our-preload-was-breaking-egl.md) §7）。`80` 和 `77` 各自只证了一半、而且**从来没有合到一起**：`80` 证明 UT 相机 app 能起来（两个摄像头都枚举到、`Application is now active`），但**那几次运行显示器全程是关的**（`ActiveOutputs (ii) 0 0`），所以它对"屏上有什么"一个字也没说；`68` §5 / `77` 把"屏上有东西且活着"的判据量出来了（显示器 ON：没客户端时合成器 ~1.2 ticks/s，有客户端在画时 20–50/s；而**截图永远不证明活着** —— 死掉客户端的最后一帧会留在 shell 的 scene 里，NCC 0.997 的像素级相同，TurnOn/sleep/重抓也清不掉）。这一步做的是把两者**接起来**：`scripts/host/zl1-camera-app-test.sh` 一条命令跑完整套协议，并且把**两个测量并排**报出来。

**接续**: [`80`](80-the-ut-camera-app-starts-and-our-preload-was-breaking-egl.md)（app 能起来，屏上未证）、[`77`](77-the-screen-can-be-photographed-and-the-camera-is-on-it.md)（合成器 CPU 判据 + 截图不等于活着）、[`68`](68-the-camera-stage-was-one-cookie-in-the-stub.md) §5/§8（那条 1.2 vs 20–50 的band、显示器开关那两条 DBus）

---

## 1. 为什么必须两个测量一起报

这两个数字单独都能骗人：

| 只看 | 会得出 | 为什么错 |
|---|---|---|
| 合成器 CPU 高 | "在画了" | 高只说明有人在画；**画的是什么**不知道（`68` §5 明确说过：不要用 app 自报的帧率，也不要用 PNG 字节差） |
| 截图有画面 | "它在屏上、活着" | `77` 量过：**死掉客户端的最后一帧还在 scene 里**，重抓像素级相同（NCC 0.997），连 `TurnOn` → sleep 4 → 重抓都清不掉 |

所以脚本报的是**同一段时间里的两件事**：合成器在不在为它干活（活性），和抓一张图长什么样（内容）。**只有两个一起才对"窗口到屏上了吗"这个问题负责。**

## 2. 一条命令做的事（顺序就是判据）

```
0. 按 device-tree model 确认是这台 zl1（不是通用脚本）
1. 记下 ActiveOutputs，然后 TurnOn（可逆；这是 shell 自己的显示器服务）
2. 窗口 A：显示器 ON、没有相机 app 的合成器 ticks/s   ← 基线（68 量到 ~1.2/s）
3. 起 app（容器 PID namespace、会话自己的 uid、会话自己的环境）
4. 窗口 B：app 跑着时的合成器 ticks/s + app 的进程状态
5. 抓一张图（给"长什么样"用）
6. 把显示器恢复成第 1 步发现的状态，停掉 app
7. 判语：三条分支（见 §3），外加"这**不**证明什么"
```

`--keep-display` 是留给人的：**最后请你看一眼手机** —— 合成器 CPU + 截图能证明"窗口在屏上且在画"，但"画面对不对、预览里有没有画面"只有眼睛能收尾（`68` §6/§7 的结论没有变）。

## 3. 判语为什么是**三条**而不是两条

`B / A ≥ 4` 且 `B ≥ 8` → **合成器在为这个 app 干活**（对照 20–50/s 的band）；
`B ≤ A + 2` → **没有额外的合成工作**，app 没有被合成（它有没有可见窗口、或者 surface 有没有到 shell，是下一层的事）；
**其余 → 不结论**。

第三条是刻意的：`80` 那一轮的所有失败模式（EGL 断言、uid 不对被会话总线拒、`libui_compat_layer.so` 缺失）都能产生"比基线高、但远不到band"的中间值，那时诚实的回答是"去看 app 的 stderr 和那张图"，而不是在两条分支里硬选一条。脚本同时在最后用从 app 自己的 stderr 里数的六个字符串（`Creating a QMirClientScreen`、`Added camera`、`Application is now active`、`ASSERT`、`caught signal`、`not found`）把这一层证据摆在旁边。

## 4. 两个"这台设备上会骗人"的细节，脚本里已经避掉

* **`pgrep -f` 在这台设备上不可靠**（`68` §5：`pgrep -f "lomiri-system-compositor --enable"` 什么都匹配不到）。所以合成器和 app 的 pid 都是**走 `/proc` 匹配整条 cmdline** 拿的；
* **`/proc/<pid>/stat` 的 `comm` 带括号且可能含空格**，会把 utime/stime 错位到别的数字上 —— 取数前先 `sub(/^[^)]*\) /, "")`（`81` 里那个坑的同一条）。

## 5. 验证到什么程度（说清楚）

* **脚本通过了 `bash -n`，判语的三条分支用合成数字在本机验过**（`1` vs `25` → 合成；`0` vs `0` → 没有额外工作；`0` vs `5` → 不结论）；
* **从来没有在设备上跑过** —— 设备在 EDL。所以：显示器开关那两条 DBus 调用、`read_state` 里走 `/proc` 找合成器、`setsid nohup nsenter ... &` 能不能干净返回、`zl1-screenshot.sh` 的 overlay 在不在（`77` 的抓手需要 `install-shell-back-key.sh --install` 装过 overlay）—— **这四件都还没有在真机上出现过一次**。脚本对其中两件已经会当场抱怨（找不到合成器、找不到 shell、抓图失败会说"这是抓图的事实，不是 app 的事实"）。
* **不证明**窗口内容正确、不证明预览里有帧、不证明用 `lomiri-app-launch` 起会一样（`80` §6 的第三个缺口）。

## 6. 复现

```sh
# 设备在线时，一条命令（默认 12 秒一个窗口、app 跑 45 秒、抓一张图）
bash scripts/host/zl1-camera-app-test.sh

# 想自己看一眼手机：把显示器留着
bash scripts/host/zl1-camera-app-test.sh --keep-display --run-seconds 120

# 用别的模式起（比如二维码）：参数原样透传给 app 二进制
bash scripts/host/zl1-camera-app-test.sh --extra-args " --mode=barcode-reader"
```

| 文件 | 作用 |
|---|---|
| `scripts/host/zl1-camera-app-test.sh` | 新增。把 `80`（app 能起来）和 `77`/`68` §5（合成器 CPU = 活性、截图 ≠ 活性）接成一条命令；显示器先开、结束时**恢复原状**；判语三条分支；把 app 自己的 stderr 证据并排打印。`--seconds` / `--run-seconds` / `--no-shot` / `--keep-display` / `--extra-args` / `--outdir` |
| `docs/ubuntu-touch/84-*.md` | 本篇 |

## 7. 这一轮**不**证明什么

* **没有在设备上跑过**（§5）：这一篇交付的是**协议 + 一个已校验语法的执行器**，不是一个结果。任何"窗口到屏上了"的结论都必须等它跑过一次。
* 不证明合成器 ticks 的 20–50/s 这个band在这台设备**今天**还成立（那是 `68` §5 在显示器开着、`test_camera` 在跑时量的；脚本每次都会重新量基线 A，所以它不依赖这个数字，只把它当参照）。
* 不证明显示器开关（`TurnOn`/`TurnOff`）在任何状态下都安全可逆 —— `68` §8 记着它每次都给回到 `ActiveOutputs 0 0`，脚本也把"恢复原状"写进 `trap`，但那是**同一个已知的运行时杠杆**，不是新东西。
