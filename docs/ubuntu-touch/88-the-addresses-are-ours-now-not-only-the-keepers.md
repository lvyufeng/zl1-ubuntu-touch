# 88 — 让 netwatch 自己配地址：退掉那个烧一个核的 keeper 的条件，现在齐了

**日期**: 2026-09-23
**状态**: 纯离线的一轮（设备在 EDL）。**在 `86`/`87` 之后我才去查 `72` §4b(d) 里那个"下一步"。** 那一节说：keeper 停掉是临时状态，"拿掉它而开机没地址，就等于 SSH 没了、要用手去按手机 —— 这个赌不做"，并且写着"我们的 `zl1-netwatch.sh` 虽然有一份等价的 `restore_addrs()`"。

**这一轮把那句话查实了，而它是一句会让人做错决定的话。** `restore_addrs()` 在这份脚本里**只被两个 heal 分支调用**；而一次 heal 要满足"宿主 ping 连续失败 45 秒"**且**"uptime ≥ 90 秒"。也就是说，一个**没有 keeper 的开机**：接口起来了但**没有地址**、**没有 SSH**，直到 uptime ~135 秒才被第一次 heal 顺手配上——**而那次 heal 是 A 级，把 RNDIS gadget 整个拆掉重枚举一遍**，还会消耗 8 次配额里的一次。不是"永久失联"（ping 失败这条路会自己把它救回来，我第一版笔记写成"永远拿不到地址"是错的），但**每一次开机都要多等两分多钟、还白白重枚举一次 USB**。所以那个赌不是"地址有没有"，而是"这一次开机值不值一次重枚举"——而在此之前没有人量过。

修法很小，而且**按"永远不赌"的顺序来**：让 netwatch 自己每轮确认那两个地址在不在（和它已经在做的 policy routing 修法是同一个写法、同一个理由），**先装它、keeper 还留着**——于是第一次证明新路径的那次开机，恰好也是一次"keeper 本来就会兜住"的开机。退掉 keeper 是再下一步，而且要一份实测判语作为许可。

**接续**: [`72`](72-the-heat-was-the-governor-and-a-debug-keeper.md) §3/§4b/§6（keeper 的代价与那个被推迟的重启测试）、[`81`](81-the-heat-line-has-an-instrument-now.md)（热线的仪器）、[`76`](76-a-stalled-link-is-a-host-side-problem.md)（为什么"地址/S-S-H 没了"这件事必须由宿主机负责把它变便宜）

---

## 1. 那句话错在哪

`72` 与 `zl1-quiet-debug-keeper.sh` 的头注释都写着同一句话的两种版本："netwatch **有**一份等价的 `restore_addrs()`"。函数确实是等价的（同样的两个地址、同样的幂等写法），问题在**调用点**：

改**之前**的调用点（`git show HEAD:scripts/device/zl1-netwatch.sh | grep -n restore_addrs`）：

```
258:restore_addrs() {          <- 定义
276:    restore_addrs          <- 在 heal_reenumerate (A) 里面
303:    restore_addrs          <- 在 heal_rebind_function (B) 里面
```

**没有第三个调用点，主循环里没有，开机时也没有。**（改完之后是三个：那两个 heal，加上新的 `ensure_addrs()`。）而 heal 的触发条件是（改之前 `:484`，改之后 `:541`）：

```sh
if [ "$HEAL_ENABLED" = "1" ] && [ "$heals" -lt "$MAX_HEALS" ] \
   && [ "$frozen" -ge "$STALL_SECONDS" ] && [ "${uptime_s:-0}" -ge "$SETTLE_SECONDS" ]
```

`frozen` 数的是"宿主 ping 不通"的轮数（`probe_host()` = `ping -c1 -W1 192.168.2.100`），每轮 2 秒（`SAMPLE_INTERVAL`）。所以：

| | keeper 在 | keeper 不在（改之前） |
|---|---|---|
| 地址什么时候配上 | 开机时（keeper 自己的 `configure_iface`，配完 `arping -A`） | **uptime ≈ 90 + 45 = 135 秒** |
| 靠什么配上 | 一条 `ip addr add` | **heal A：`enable=0` → `enable=1` 整个 gadget 重枚举**，然后才 `restore_addrs` |
| SSH 断了多久 | 0 | ~135 秒（外加一次 USB 重枚举的时间） |
| 代价 | 一个核（`72` §4b：停 0.87 核 / 跑 1.84 核） | 每次开机一次多余的重枚举，且 `MAX_HEALS=8` 用掉一次 |

**"接口在但没地址"这件事本身不会让检测器失灵**——`frozen` 只看 ping 通不通，不管有没有 RX 流量，所以它终究会触发。我最初写成"永远拿不到地址"，那是错的；**真正的差别是那 ~135 秒、以及治愈它要付的那一次重枚举**。差别的性质很重要：前者是"这条路不行"，后者是"这条路能走，但每一次开机都更差"，而后者才是需要写下来、需要量、也值得先修的东西。

## 2. 改法：让地址和 policy routing 一样，每轮自己确认

netwatch 主循环里已经有一段这个形状的东西，注释写得很清楚：

```sh
    # Re-assert the policy routing fix whenever it is missing. netd wipes and reinstalls
    # its rules as the container starts and restarts, so this cannot be a one-shot.
    [ -e "/sys/class/net/$IFACE" ] && apply_policy_routing_fix
```

地址是**完全同一个形状**的问题：会拿走地址的不只是开机（netd、heal 拆掉重建 netdev、gadget 重新绑都会）。所以新增三个小函数，紧挨着 `restore_addrs()`：

* `cur_addrs()` —— 一次 `ip -4 addr show`，把现有 IPv4 列出来；
* `addrs_ok()` —— 两个地址都在就返回 0；
* `ensure_addrs()` —— 接口不在就返回 1（heal 正在拆，不算问题）；都在就**什么都不做**；缺了就 `restore_addrs()`，有 `arping` 就顺手 `arping -A`（keeper 也是这么宣告的），然后写**一行**日志：

```
14.0s ADDRS: uptime=14.0 iface=rndis0 now='192.168.2.15/24 10.15.19.82/24 '
```

**"只在真缺的时候写日志"是有意的**：稳态下 `addrs_ok` 直接返回，一行都不会多写，所以这一行不可能刷屏；而它一旦出现，就说明**确实有东西把它们拿走了**——那正是要在日志里看见的事。

主循环里加一行调用，就放在 `apply_policy_routing_fix` 旁边：

```sh
    # Same shape, same reason: the addresses can be taken away by a heal or by the gadget
    # re-binding, not only by the boot (docs 88 -- this is what replaces the keeper's job).
    ensure_addrs
```

**这是"先装、后退休"**：keeper 一个字都没动，脚本也没 mask 任何 unit。所以新路径第一次被验证的那次开机，是一次 keeper 仍然会兜住的开机——失败了也只是回到现在的样子，不会出现"手要伸向手机"的状态。这直接对应那条长期约束（**安全优先于进度**）。

## 3. 一份判语，作为"可以退休"的许可

装好之后仍然只是**有了一条可能**；要不要动 keeper，要看**实测那一行出现了没有**。所以同一轮里做了 `scripts/device/zl1-boot-address-check.sh`（只读，在设备上跑）：

它把 netwatch 日志按 boot 切开（`netwatch start` 是边界，每行都带 uptime 前缀），然后回答三个问题：这次开机**有没有** `ADDRS:` 行、**在哪一秒**、以及**在那之前有没有 heal**；同时报 keeper 的状态（`T` 还是还在跑）、netwatch 的 unit 活没活、以及**装上去的那份构建里有没有 `ensure_addrs()`**（`sh -n` 看不出函数被删掉——这是 2026-09-19 的教训，所以 `check-netwatch-integrity.sh` 的必需函数表里也加上了这三个名字）。

判语三分支，**只有第一条给许可**：

| 判语 | 含义 | 下一步 |
|---|---|---|
| **`netwatch-configured`** | 有 `ADDRS:` 且没有更早的 heal → 新路径成立 | 可以进入退休那一步 |
| **`heal-first`** | 没有 `ADDRS:`，但 heal 在 ~135 秒时干了 → 就是 §1 描述的病态 | **不要动 keeper**；多半是装上去的构建还不含 `ensure_addrs()` |
| **`inconclusive`** | 地址在，但 netwatch 没记、heal 也没发生 → 是 keeper 配的（阶段一本来就该如此） | 这次开机对新路径一个字也没说 |

四个合成日志的场景都在本机跑过：`ADDRS` 早于任何 heal（→ 许可，退出 0）、只有 heal（→ 拒绝，退出 1）、都没有但地址在（→ inconclusive，退出 1）、以及**日志里有两次开机**（必须只读最新那次——这一条专门验过，因为把上一个 boot 的 heal 算进来会得出完全相反的判语）。

## 4. 验证到什么程度（说清楚）

* **`ensure_addrs()` 用打桩的 `ip` 跑了五个场景**：全新开机（两个地址都加、一行日志）、稳态（**不再加、不再写日志**）、heal 重建 netdev 后只剩一个（补回、一行日志）、只丢 10.x（补回）、接口不存在（返回 1 且**不写日志**——heal 正在拆的时候不该被记成"配置事件"）。输出逐条核对。
* **`zl1-boot-address-check.sh` 的四个场景**如上，含 boot 边界。
* **`check-netwatch-integrity.sh` 通过**（17 个函数全在），三个新函数在里面；`sh -n`/`bash -n`/`dash -n` 三个解释器都过。
* **没有在设备上跑过任何东西**：设备在 EDL。所以**这一轮交付的是"一个已校验的执行器 + 一份判语协议"**，不是结果。真实设备上未验证的点：`arping` 在不在（不在就跳过，日志里不体现——这是有意的，因为宣告不是关键路径）、`ip -4 addr show` 的输出格式、以及 `ensure_addrs` 每 2 秒一次 `ip` 调用的开销（相对它已经在做的 `ip rule`/`netstat` 采样可以忽略，但**没量过**）。
* **不证明 keeper 可以退掉**：只证明"现在有一个可测的方法去决定能不能"，以及"在新路径被实测证明之前，什么都不用赌"。
* **不证明退掉 keeper 就够**：keeper 的 1 Hz 循环里还有 `systemctl mask --runtime usb-moded.service` 这类动作，它到底还担着什么别的职责**没有查过**，所以退休那一步要连同"它还有没有别的活"一起看。这一轮只解决"地址"这一个阻塞点。

## 5. 复现

```sh
# 1. 改动的自检（宿主机，不需要设备）
sh -n scripts/device/zl1-netwatch.sh
bash scripts/check-netwatch-integrity.sh          # 17 个函数，含新增的三个

# 2. 设备回来、确认在线之后，装带 ensure_addrs 的那份（需要 TWRP，`--yes` 是硬门槛）
scripts/install-netwatch-service.sh --yes

# 3. 重启（**需要用户同意**），然后跑判语
scp scripts/device/zl1-boot-address-check.sh root@10.15.19.82:/tmp/
ssh root@10.15.19.82 'sh /tmp/zl1-boot-address-check.sh'

# 4. 只有它说 netwatch-configured（退出 0）时，才谈退休 keeper
ssh root@10.15.19.82 'sh /tmp/zl1-quiet-debug-keeper.sh --status'
```

| 文件 | 作用 |
|---|---|
| `scripts/device/zl1-netwatch.sh` | 改：新增 `cur_addrs()` / `addrs_ok()` / `ensure_addrs()`，主循环里每轮调用一次；地址从此不再只属于 keeper |
| `scripts/check-netwatch-integrity.sh` | 改：必需函数表加上这三个名字 |
| `scripts/device/zl1-boot-address-check.sh` | 新增。只读：按 boot 切 netwatch 日志，回答"地址是谁配的、第几秒、之前有没有 heal"，并检查装上去的那份构建里有没有 `ensure_addrs()`。三条判语；退出 0 = 可以退休 keeper |
| `scripts/device/zl1-quiet-debug-keeper.sh` | 改：头注释里那句"self-healing rather than silent"改成准确的说法（~135 秒 + 一次重枚举），并指向本篇和那份判语 |
| `scripts/install-cpufreq-governor.sh` | 改：同一条注释的另一种版本，同样更正 |
| `docs/ubuntu-touch/88-*.md` | 本篇 |

## 6. 这一轮**不**证明什么

* **不证明地址在新路径下真的会被配好**（§4）：那要一次真机开机加那份判语。**没重启**——按长期约定，重启要明确同意。
* **不证明 `ensure_addrs` 会让开机变好**：它把"~135 秒 + 一次重枚举"变成"开机后第一轮（≤2 秒）"，但那两件事都还没在真机上对比过。
* **不证明 keeper 的其它职责可以交给别人**（§4 末条）。
* 不改动设备：这一轮对设备零操作（连 `zl1-health-check.sh` 都没再跑；设备在 EDL 这件事由 USB 树确认）。
