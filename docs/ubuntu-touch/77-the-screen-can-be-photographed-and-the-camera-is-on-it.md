# 77 — 屏幕现在可以自己拍照了；相机预览**确实在屏幕上**，而"截图"这一条证据本身有它证的不到的地方

**日期**: 2026-09-23
**状态**: 相机的"到底有没有显示出来"这个问题**答完了，答案是有的**，而且答的方式是 doc 68 §5 规定的那个判据（合成器自己的 CPU），不是猜的。同时这一轮把三件事量清楚了：截图这条路怎么走（`scripts/host/zl1-screenshot.sh`）、显示器电源会影响什么（只影响合成器的 tick 判据，**不影响截图**）、以及截图**证明不了**什么（客户端退出后那一帧还在）。

**接续**: [`68`](68-the-camera-stage-was-one-cookie-in-the-stub.md)（§4.1 fb0 是残留的 framebuffer、§4.2 app 帧率不是证据、§5 合成器 CPU 表）、[`67`](67-the-preview-started-it-was-a-sched-fifo-request.md)（预览是怎么起来的）、[`74`](74-the-speaker-path-is-complete-in-software.md) §4.1（`TurnOn` 能改 `ActiveOutputs`，但 fb0 不变）

---

## 1. 为什么屏幕需要一条自己的拍照路径

在这之前没有任何办法看到这台设备的屏幕上是什么，四条路全堵死：

| 路 | 为什么不行 |
|---|---|
| `/dev/fb0` | 是**残留的 framebuffer**。DBus `TurnOn` 把 `ActiveOutputs` 从 `0 0` 改成 `1 0` 的同时，fb0 的 md5 一个字节都没变（doc 68 §4.1），也就是说它不装正在被扫描输出的东西 |
| 合成器的 DBus 接口 | 只有 `Display`、`Input`、`PowerButton`、`UserActivity` 四个，**没有截图方法** |
| `mirscreencast` | 从主机侧起不来：`failed to find/load gralloc module` |
| 音量加+音量减、PrintScreen 全局快捷键 | 都要人按 |

所以让 **shell 自己拍**：overlay（`scripts/shell-overlay-patch.py` 的第 2 个 hunk）加一个 Timer，每 2 秒看一次 `/userdata/zl1-shell-shot.request`，**内容变了**就调 `itemGrabber.capture(shell)` —— 和音量键那条路走的是同一个调用。PNG 由 ItemGrabber 自己写、自己记路径，所以这次拍照在 journal 里是可查的，不是"应该拍到了"。

主机的入口是 `scripts/host/zl1-screenshot.sh`：写一个 `date +%s%N` 进请求文件（比的是**内容**，所以同一个数字写两次不会触发，上一次跑剩的旧文件也不会误触发）→ 轮询 `/home/phablet/Pictures/Screenshots/` 里新出现的 PNG → 拷回来。它先确认 overlay **真的挂在正在跑的 shell 上**（grep `/proc/<MainPID>/root/usr/share/lomiri/Shell.qml` 里的 `zl1ShotTimer`），不挂就直接说"先装 overlay"，不会静悄悄地失败。

## 2. 先解决"这张截图是不是真的"这个问题

PNG 字节数不一样、或者 app 自己报的帧率，都不是证据（doc 68 §4.2 量过：显示器开/关，app 报 37/42/37/34 fps，完全无关）。所以这一轮用**参照物**：`base2.png` 是一张确认过的启动器画面，把每张新截图和它做 RMSE 和归一化互相关（NCC）。同样的场景 NCC 会到 0.9 以上，不同的场景只有 0.37 左右。

```
                        RMSE_vs_base2    NCC_vs_base2    NCC_vs_preview-4
base2（启动器，参照）      —                1.000           0.374
cam-3                     2283.4           0.9096          0.374
screenshot19700210_*      1495.5           0.9610          0.371     <- 这两张就是启动器
preview-1                14165.4           0.3853          0.120
preview-3                14158.5           0.3867          0.121
preview-4                 9178.6           0.3736          1.000
run2-a..d                14110..14131      ~0.385          ~0.120
on-a / on-b              14096 / 14100     0.385           0.119
on-d                      9102.5           0.3764          0.944
```

（0.37 不是"几乎一样"：RMSE 14165/65535 是 21.6% 的差。两张都偏暗的照片凑出 0.37 的相关是正常的。）

这张表本身就是这一轮的第一条更正，见下一节。

## 3. 相机的问题：**在屏幕上**，而且是按 doc 68 §5 的判据答的

合成器的 CPU 有两组数（HZ=100，取 `/proc/<pid>/stat` 的 utime+stime）：

| 状态 | 合成器 | shell |
|---|---|---|
| 显示器关、空闲 | 0 ticks/s | 0 |
| 显示器关、**预览在跑** | **4–5**（90 秒稳稳的） | — |
| 显示器开、无客户端 | 2 ticks/s | 0 |
| 显示器开、**预览在跑** | **20–26**（72 秒，均值 ~23.5） | 40–49 |

doc 68 §5 的表是 1.2（开、空闲）/ 27.8–50（开、有预览）/ 4.8（**关**、有预览）。所以"显示器关着的 4–5"落在那张表的"关"那一行，是**读不出结论的**；把显示器显式打开之后，2 → 20–26 才是那个判据要的对比。同一轮里还拍到了预览本身（`on-d.png`）。

**结论：预览是画到屏幕上的，不是只在客户端内部的缓冲区里。**

## 4. 三条诚实的更正和边界

### 4.1 之前的"显示器关着所以拍到的是启动器"是**看错了**（表已给出）

显示器关着那一轮（`preview-1..4`、`run2-a..d`）和显示器开着那一轮（`on-a`、`on-b`）的截图**是同一个场景**：对 reference 的相关都是 ~0.12，互相之间几乎逐像素相同。它们**不是**启动器（启动器是 `base2`/`cam-3`/`screenshot19700210`，NCC 0.91–0.96）。

所以：**截图里有没有预览，跟显示器开不开没有关系**。显示器电源唯一影响的是第 3 节那个 tick 判据。之前那次"negative result"是**读图读错了**，不是工具的问题，也不是显示器的锅。（`preview-1.png` 那张我这次重新看过，是一间很暗的房间，不是 home screen。）

### 4.2 客户端**退出之后，那一帧还在**——所以截图证明不了"预览是活的"

这一条是这次最该记住的：

* 相机跑完之后设备上已经**没有任何 `test_camera` 进程**（`pgrep -a test_camera` 空，开了 `wayland-0` 的进程只剩 `lomiri` 一个）；
* 这时候拍的 `fix-check.png` 和 9 分钟前客户端还在跑时拍的 `preview-4.png`，**NCC = 0.997**，也就是同一帧；
* 走一次 `TurnOn` → 等 4 秒（真的重合成一遍）→ 再拍，还是那一帧（`stale-on.png`，NCC 0.997）。之后 `TurnOff` 把 `ActiveOutputs` 还原成 `0 0`。

也就是说这一路 grab 拍到的是 **shell 场景里的内容**（那个 surface 进过场景，最后一帧还挂着），**不是**"现在有一个活着的预览"。要证"活的"，必须配第 3 节那个 tick 数（显示器开着、有预览 20–26 vs 无客户端 2），或者确认客户端进程在跑。**单张截图只能证"画面上去了"。**

> 现状备注：设备上那块 dead surface 的最后一帧**现在还挂在场景里**（显示屏是关的，用户看不到）。它要靠一次重合成/重启才会清掉。没有去动合成器，见最后。

### 4.3 17 张截图里有 **4 张是截断的**，已经把脚本修好

`cam-1.png`(525118)、`cam-2.png`(623566)、`on-c.png`(254386)、`preview-2.png`(516914) 这四张 ImageMagick 读不出尺寸、PIL 报 `image file is truncated`。原因不是 scp 偶发：轮询是"**看到新文件名就拷**"，而 shell 是**先建文件再往里写**，所以拷贝是在和 shell 的写赛跑。截断文件的下游表现很隐蔽——PNG 头是好的，`file` 高高兴兴报 `1080x1920 RGBA`，只有解码器才会报错。

`scripts/host/zl1-screenshot.sh` 现在做两件事：等设备上文件大小**连着两次不变**再拷；拷完检查文件**最后 8 个字节是不是 IEND 的 `49 45 4e 44 ae 42 60 82`（PNG 的结尾块），不是就重拷，最多 3 次，还不行就明说这是截断的、别当图片用。修完之后重测了一次，748025 字节、PIL 正常解码。

## 5. 顺手修掉 `run-camera-test.sh` 的两处谎

1. **`stdbuf -oL` 从选项变成默认。** test_camera 用 `printf` 往文件里写进度，C stdio 是块缓冲（4096 字节），被 timeout 杀掉时缓冲区尾部直接丢掉——`out` 恰好停在 4096 字节、断在半行。而 `Started camera preview.` 是**最后一行**（49 行里的第 49 行），正好在被丢掉的那一段里。所以那句 `grep -aq 'Started camera preview'` 会对一次**真的跑到预览**的运行回答 "no"。加 `--block-buffered` 可以退回旧行为（研究缓冲本身的时候用）。
2. **"reached the preview?" 现在能区分 "no" 和 "不知道"。** 没有标记、且 `out` 大小是 4096 的整数倍、且当时用的是块缓冲 → 输出 `CANNOT TELL` 并说明重跑办法；没有标记、大小不是整数倍 → 才是真的 "no"；空文件 → "什么都没打印"。

## 6. 复现

```bash
# 拍一张（overlay 必须已装：scripts/install-shell-back-key.sh --install）
bash scripts/host/zl1-screenshot.sh --out /tmp/shot.png

# 判断这张拍的是不是启动器（base2.png 是已确认的启动器参照）
compare -metric NCC base2.png /tmp/shot.png null:      # >0.9 是启动器，~0.37 不是

# 相机 + 显示器开着 + 同时量合成器 tick（判据来自 doc 68 §5）
#   见下面的"测量脚本"；它自己把 ActiveOutputs 还原成发现时的值
```

测量用到的一次性脚本（不在仓库里，两个都在 `/tmp`）：`zl1-cam-measure.sh`（显示器不动）和 `zl1-cam-measure-on.sh`（`TurnOn` → 量 → `TurnOff` 还原）。

## 7. 这一轮**不**证明什么

* **不证明预览是活的**（4.2）：截图证明 surface 进了场景，tick 数证明它在动，两样都要。
* 不证明 **app 自己的相机界面**能用——跑的是 `/usr/bin/test_camera`，不是 UT 的 camera-app。
* 不证明显示器关着的时候**用户在屏幕上能看到东西**（关着就是关着）。
* 4.2 里那块残留的最后一帧**没有清掉**，也**没有去动合成器**：清它要么等一次重合成、要么重启设备，而重启要单独商量。
* 全程只写了 `/userdata/` 下的文件和 `/home/phablet/Pictures/Screenshots/` 下的 PNG；`ActiveOutputs` 两次 `TurnOn`/`TurnOff` 都还原成了发现时的 `0 0`。没有分区写、没有重启。
