# 23 — 内核补丁候选：让发送路径不再"卡死就再也不动"

**日期**: 2026-09-17
**对应问题**: [`22-stage2-coldboot-results.md`](22-stage2-coldboot-results.md) §5 ——
约 1/4 次开机后，设备收得到但发不出去，且本次开机内不自愈。

---

## 1. 为什么在 u_ether.c 这一层动手

`u_ether.c` 里能重新打开一条**被停掉的**发送队列的地方只有三处：

| 位置 | 行 | 说明 |
| --- | --- | --- |
| `eth_start()` | ~1341 | 由 `eth_open` / `gether_up` 调用，只在链路建立时 |
| `tx_complete()` | ~876 | USB 发送完成回调 |
| `process_tx_w()` | ~1059 | 聚合发送 worker，但只调 `netif_start_queue()`，而且**只在它没有从循环里 break 出去时**才调 |

`netif_wake_queue()`——那个**同时会重新调度 qdisc** 的版本——只存在于
`tx_complete()` 和 `eth_start()`。

于是：**丢一次完成事件，队列就永久停在 stop 状态，再没有任何东西会去唤醒它**；
而那个本来就负责排空 `tx_skb_q` 的 worker 在 `break` 之后也不会重新排自己。
文件里那段注释说的就是这个形状的风险：

```
should allow aggregation only, if the number of requests queued more than
the tx requests that can be queued with no interrupt flag set sequentially.
Otherwise, packets may be blocked forever.
```

## 2. 补丁做了什么

**只动 `process_tx_w()` 的收尾**，加一段：

```c
	if (net && req_cnt > 0) {
		/*
		 * req_cnt > 0 means this pass actually moved something, so there is a
		 * free request to work with. Re-queue only then: if every request is
		 * stuck (tx_reqs empty) nothing can make progress, and re-arming
		 * would just spin this single-threaded worker.
		 */
		if (skb_queue_len(&dev->tx_skb_q) > 0)
			queue_work(uether_tx_wq, &dev->tx_work);
		if (netif_queue_stopped(net) &&
		    dev->tx_skb_q.qlen < tx_start_threshold)
			netif_wake_queue(net);
	}
```

两件事：

1. **自己重新排自己**——只要 `tx_skb_q` 里还有包，就再跑一轮，不再依赖"下一次
   `tx_complete` 会来叫我"。
2. **用 `netif_wake_queue` 而不是 `netif_start_queue`**——后者只清
   `__QUEUE_STATE_DRV_XOFF`，前者还会 `__netif_schedule` 去重启 qdisc。

### `req_cnt > 0` 这个守卫是必须的

没有它的话，当所有 tx request 都被卡住（`tx_reqs` 为空）时，worker 会不停地
把自己重新排队——而 `uether_tx_wq` 是 `max_active = 1` 的单线程队列，
那就是一个占满 CPU 的热循环（旁边代码自己都在担心 "wd may kick in"）。

`req_cnt > 0` 表示这一轮**确实推进过**，也就意味着还有空闲 request 可用——
这时重新排队才有意义。全部卡死时什么都不做才是对的，那种情况在 u_ether 这一层
本来就无解。

**RX 路径一个字节都没动。**

## 3. 性质：这是"缓解候选"，不是已确认的修复

必须说清楚：

- 它治的是**"队列停了没人唤醒"**这个已确认的代码事实（§1 的三处调用点是真的）；
- 它**没有**证明这就是设备上那个卡死的根因。§5.2c 的假设也只是"吻合"。
- 判定标准是设备侧 netwatch 的 `tx_pkts_rcvd` / `tx_qlen` / `tx_throttle` 序列：
  如果打上补丁后卡死率明显下降、或者卡死时 `tx_qlen` 仍在涨而 `tx_pkts_rcvd` 不动，
  那就是别的原因。

**所以设备侧的 netwatch 自愈不能因为有了这个补丁就撤掉。**

## 4. 构建与产物

- 脚本：[`scripts/patch-uether-tx-wakeup.sh`](../../scripts/patch-uether-tx-wakeup.sh)
  （`--apply` / `--remove` / `--status`，幂等，沙箱验证过 `--remove` 后**逐字节还原**）
- 产物：`/mnt/data/halium-zl1-candidates/halium-boot-zl1-uether-txwakeup.img`

| | 值 |
| --- | --- |
| 产物 SHA256 | `3b5277e4c08121cdb58baf619c465294a0c0b9d62b946b95a3a4144fae9a2633` |
| 相对 Phase 1 基线 | ramdisk **逐字节相同**，appended DTB 区 **逐字节相同**，只有解压后的 kernel `Image` 不同（28,258,304 → 28,274,688 字节，+16 KiB） |
| 是否可复现 | ✅ 两次完全干净重建（`rm -rf out/`）得到同一个 SHA |

这符合预期：改动只在 `u_ether.c`，也就是内核里一个目标文件。

### 三向验证：补丁是唯一变量

| 构建 | 产物 SHA256 |
| --- | --- |
| Phase 1 基线（无补丁） | `a29c18db…c0b1a3` |
| 打补丁，第 1 次干净重建 | `3b5277e4…a2633` |
| 打补丁，第 2 次干净重建 | `3b5277e4…a2633` |
| **撤掉补丁，再次干净重建** | `a29c18db…c0b1a3`（回到基线） |

四次构建、两个值，中间只改了 `u_ether.c` 的一处收尾——这既证明了补丁可复现，
也证明了它确实是唯一的差异来源。

## 5. 复现方法

```bash
scripts/patch-uether-tx-wakeup.sh /mnt/data/halium-zl1-build --apply
rm -rf /mnt/data/halium-zl1-build/out
scripts/build-halium-boot.sh /mnt/data/halium-zl1-build
```

撤掉补丁后重新构建，应当回到 Phase 1 的基线 `a29c18db…c0b1a3`——
**这也是验证"补丁是唯一变量"的方法**。
