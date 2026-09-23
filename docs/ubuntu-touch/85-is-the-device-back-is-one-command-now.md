# 85 — "设备回来了吗、状态对不对" 现在也是先跑一条命令

**日期**: 2026-09-23
**状态**: 纯离线的一轮（设备在 EDL）。`80`/`82`/`83`/`84` 每一篇的结尾都是同一句话："设备回来之后我按这个顺序做"。而每一轮真正做的第一件事是**同一套手敲的检查**：在总线上吗、是哪个模式、`usb0` 有没有流量、SSH 通不通、容器活着吗、管屏和管传感器的 unit 在不在、keeper 还停着吗、热不热。这套检查现在有一条命令：`scripts/host/zl1-health-check.sh`。它的 **EDL 分支今天是真的跑过的**（设备此刻就是那个状态），不是纸上的。

**接续**: [`80`](80-the-ut-camera-app-starts-and-our-preload-was-breaking-egl.md) §7（第一次 EDL）、[`76`](76-a-stalled-link-is-a-host-side-problem.md)（RNDIS 停摆是宿主侧的事，设备本身没坏）、[`49`](49-two-cores-that-are-not-tls-wifi-stuck-at-wcnss-and-a-trip-into-edl.md) §5–6（上一次 EDL 和它是怎么回来的）、[`72`](72-the-heat-was-the-governor-and-a-debug-keeper.md)/[`78`](78-the-sensors-came-back-without-a-reboot.md)（keeper 和传感器栈为什么要各看一眼）

---

## 1. 四种状态，而"ping 不通"分不出它们

| 状态 | 判据 | 该怎么办 |
|---|---|---|
| **不在总线上** | 没有 `33e80afe*` 的 serial，也没有 `05c6:9008` | 确认开机 / 换口换线 |
| **EDL** | USB ID `05c6:9008`（`QUSB__BULK`、无 serial） | **只有物理复位**：长按电源 10–20 秒（`49` §6 就是这么回来的；USB rebind 和干等在那次都无效）。**不跑 QFIL/qdl/firehose** |
| **RNDIS gadget 在，但不通** | serial 以 `33e80afe` 开头，`ping` 无回 | **宿主侧问题**（`76`：设备自己的计数器干净、uptime 也没断）：`scripts/host/zl1-rndis-recover.sh` |
| **通了** | SSH 能读回东西 | 跑自检 + 下面那四条测量 |

这四行是这一轮的实质内容：**它们之间不是"重启一下试试"的关系**，其中两条有各自已经写好的、更好的工具，而这个脚本的价值是**把你路由到正确的那个**，而不是自己什么都试一遍。所以它是个 router：只 ping、只 SSH 只读、只看宿主的 USB 树；不写任何 sysfs、不刷任何东西、**不替你跑 RNDIS 恢复**（那是对宿主 USB 栈的写操作，是个独立决定）。

## 2. 为什么是"先看再路由"而不是"直接修"

`76` 那次的教训值得写进工具里：RNDIS 停摆时**设备是好的**（它的 `rndis0` 计数器全零错误、uptime 跨过整个恢复过程），坏的是**宿主的接收方向**——一个只存在于宿主侧的 stall，对任何盯设备发送计数器的检测器都是隐形的。所以：

* **`ping` 不是链路测试**。脚本先 ping，再用一条**真的读回东西**的 SSH 确认（`76` 的判据）；
* **接口本身不在**是另一件事（`rndis_host` 没绑上），那时连 ping 都不用试，直接指 `zl1-rndis-recover.sh` / `install-zl1-udev-rule.sh`。

## 3. 通了之后它检查什么（都是踩过的坑）

| 检查 | 为什么是这一条 |
|---|---|
| device-tree model 里有 `LE_ZL1` | 总线识别**只靠 serial**（`76`：同总线上那台无关的小米会撞 ID），但进了设备之后 model 是第二次确认 |
| `adb devices` 里**不该**有 `33e80afe` | `49` §6 的自检：那是 stock Android 的样子，不是 UT 的 |
| `systemctl --failed` 为空 | `64` 之后一直是空的，非空就是新问题 |
| `lxc-info -n android -pH`（**不是** `lxc-ls`） | `lxc-ls` 在这台设备上对运行中的容器报 STOPPED |
| `sensorfwd` / `repowerd` / `lightdm` 三个 unit | `69`：repowerd 排在 sensorfwd 的 READY=1 之前会死，而它是这台设备上**屏幕策略的唯一拥有者** |
| `ActiveOutputs` | 抓图/上屏那套协议的起点状态 |
| keeper 的状态（`T` / 运行） | `72`：它在跑的时候烧掉约一个核、还让 systemd 每 ~6 秒 reload 一次；`T` 是安静的那个状态 |
| 热区（**全部**，不是 `thermal_zone1`）、cpu0 governor | `72` 的两个热源之一（governor 是否还是 `interactive`）；热区那一行原来读 `thermal_zone1` 再除以 1000，而**这台设备的区不是一个单位**，于是它把 55.8 °C 的 SoC 报成 0.6 °C（`96`）。现在它取全区的 `type:temp`、在宿主机用和 `device/zl1-thermal.sh` 同一张表换算，并印出最热那个的原始值与单位 |

最后它把**欠着的四条测量**连同各自的命令打出来（上屏/相机、GPS、指纹、发热），所以"设备回来了"和"下一步做什么"是同一个输出。

## 4. 验证到什么程度

* **EDL 分支是真跑过的**：写完之后立刻对当前设备状态执行了一次，它正确地认出 `05c6:9008 / QUSB__BULK / port 3-3` 并给出了上面那段处置 —— 这是这一轮唯一一次真的对着设备跑东西（只读：`lsusb` 式的 sysfs 读取，连 ping 都没发出去）。
* **纯逻辑部分用合成输入验过**：USB 表分类器的五个输入（`05c6:9008` → edl；`33e80afe…` → rndis；**`4a2fe00b…`（那台无关的小米）→ absent**；root hub → absent；空表 → absent）、`field()` 的取值、thermal 的换算是 `45.4 C`、model 匹配、keeper 状态路由。
* **没验过的**：RNDIS 分支、以及在真机上跑完整个自检 —— 那需要一个在线的设备。**"ping 通"那一段的 SSH 自检（十来个字段一次往返）从没跑过**，所以如果里面哪个字段名和真机不符，第一跑会显出来（脚本对每个缺失字段都留了 WARNING 而不是崩掉）。

## 5. 复现

```sh
scripts/host/zl1-health-check.sh                 # 先跑这个
scripts/host/zl1-health-check.sh --quiet         # 只要判语和下一步
scripts/host/zl1-health-check.sh --no-ssh        # 只做 USB/链路巡检
```

| 文件 | 作用 |
|---|---|
| `scripts/host/zl1-health-check.sh` | 新增。四种状态的分类（absent / EDL / RNDIS-不通 / 通）+ 通过之后的自检 + 把欠着的四条测量连命令一起打出来。只读；`--quiet` / `--no-ssh`；退出码 0=自查通过、1=通了但有告警、2=够不到 |
| `docs/ubuntu-touch/85-*.md` | 本篇 |

## 6. 这一轮**不**证明什么

* **不证明任何硬件能用**：它自查的是"这台设备在一个值得开始一个阶段的起点状态上"，不是"硬件都驱动了"。它一条测量都不替代。
* 不证明 RNDIS 分支的处置是完整的：它把工作交给 `zl1-rndis-recover.sh`（那个脚本自己有四级升级和真实往返测试），这里只是**指路**。
* 不证明 EDL 的成因（`80` §7 已经写明没有归因），也不证明物理复位**一定**能回来 —— 证明的是"上一次是这样回来的"（`49` §6）。
