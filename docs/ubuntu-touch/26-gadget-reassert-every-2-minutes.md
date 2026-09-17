# 26 — 真凶：v63 keeper 每 ~2 分钟把 USB gadget 拆一次重来

> ## ⚠️ 这篇的结论已被推翻。见 [`29-correction-watchdog-not-keeper.md`](29-correction-watchdog-not-keeper.md)。
>
> ~118 秒一次的重新枚举**不是 keeper 做的，是我自己的 netwatch 在治愈**。
> 设备端 `/data/zl1-netwatch.log` 直接写着 `HEAL A: enable=0/1 on the gadget`
> 和 `HEAL B: unbind/rebind the rndis function`，时间点 117/233/358/476/594/711/825 秒，
> 平均 122 秒——与本文从主机侧量到的间隔完全对得上。
>
> 本文的测量（间隔、可达率、只写 `enable=0/1` 的代码路径）都是真的，
> **但把它归因给 keeper 是错的**，因此建议的 `noreassert` 补丁打错了目标。
> 保留原文是为了记录推理过程，结论请看 29。


**日期**: 2026-09-17
**推翻的判断**: [`22`](22-stage2-coldboot-results.md) §5 说的"约 1/4 次开机会偶发卡死"。

---

## 1. 实测数据

给设备装上 netwatch 之后第一次开机，主机侧 `host-watch-usb0.sh` 记录了 36 分钟：

```
14:41:21  8a:3c:70:8c:e4:ca
14:42:32  be:fb:b4:60:a1:38   +71s
14:44:29  e6:48:1e:09:09:34   +117s
14:46:34  b2:2b:f8:37:d5:3d   +125s
14:48:32  1e:aa:34:0d:de:aa   +118s
14:50:29  e6:c7:3f:ec:36:f3   +117s
14:52:26  1e:be:13:a1:ee:3d   +117s
14:54:20  6a:dd:b4:a3:97:de   +114s
14:55:47  da:cf:a7:68:eb:38   +87s
15:05:14  4e:d1:ef:65:0b:aa   +567s   <- 中间有一次重启
15:07:17  42:08:b9:81:a0:bd   +123s
15:09:19  1e:a4:45:35:db:c4   +122s
15:11:04  02:a1:8d:48:b7:33   +105s
15:13:10  8e:91:c8:d1:74:7a   +126s
15:15:08  7a:af:b9:ff:aa:c8   +118s
15:17:05  0e:fa:08:1e:fb:7e   +117s
```

**16 次重新枚举，间隔稳定在 117–125 秒**，每次都是一个全新的随机 host MAC。
也就是说**设备的 USB gadget 每两分钟被整个拆掉重建一次**，主机的 `usb0` 随之销毁重建。

这 36 分钟里，主机成功 ping 通设备的总次数：**2 次**。

另一组独立测量（每 2 秒采样一次，连续 4 分钟）：`usb0` 一直在、`carrier=1`、
但主机 TX 只有 3–16 个包、RX 只有 5–6 个包——**链路"看起来是通的"，实际一个包都过不去**。

## 2. 谁在拆

v63 ramdisk 里 `zl1-debug-net.sh` 的 keeper 主循环：

```sh
while :; do
    write_runtime_systemd_units
    maybe_systemctl_mask_usb
    if kill_usb_managers; then
        force_android_usb_rndis usb-manager-killed || true      # <-- 这里
    else
        force_android_usb_rndis steady || true
    fi
    ...
```

而 `force_android_usb_rndis()` 里唯一会写 gadget 的地方是：

```sh
write_file "$ANDROID_USB/enable" 0          # 断开
... 写描述符 ...
write_file "$ANDROID_USB/functions" rndis
write_file "$ANDROID_USB/enable" 1          # 重连 -> 主机看到一次完整的断开+重连
```

`enable=0` → `enable=1` 就是一次完整的重新枚举。而它只在 `reason` 为 `full` 或
`usb-manager-killed` 时才会走到这里——`steady` 会在前面 `return 0`。

**所以：keeper 每杀掉一个 USB manager，就顺手把 gadget 拆了重建一次。**
被杀的 manager 会被系统重新拉起，于是变成"杀掉 → 重建 gadget → 又被拉起 → 再杀 → 再重建"的循环。
~2 分钟的间隔就是那个 manager 重新出现所需的时间。

## 3. 这解释了之前所有的怪现象

| 之前观察到的 | 现在的解释 |
| --- | --- |
| "Network reachable for 7 samples (~30s)" —— 6 月所有 session 都撞到的那堵墙 | 每次重新枚举后有一小段可用窗口，然后下次枚举又把它打断 |
| [`22`](22-stage2-coldboot-results.md) §5.4 那张"容器起来 → 30 秒内卡死"的相关性 | **是真的，但因果不是我想的那样**：容器起来才带来那个 USB manager，keeper 才开始和它打架、才开始每 2 分钟拆 gadget。没有 `system.img` 就没有容器、没有 manager、没有拆解——所以那次能连续供状态页 8 分钟 |
| 计数器显示 "RX 在涨、TX 冻住" | 每次枚举后设备重新配置地址和队列；窗口内 RX 收到主机的 ARP 请求，但窗口很快结束，TX 没来得及送出去几个包 |
| `carrier=1` / `operstate=up` 却不是可用链路 | `carrier` 反映的是 USB 链路层，不反映"上层的包能不能过去"——这一条从头到尾都成立，6 月的记录就是被它骗了 |

## 4. 修法

被打包成一条**受版本管理的补丁**（`boot/patches/0100-no-reassert-on-usb-manager-kill.patch`）：

```sh
    if kill_usb_managers; then
        # 杀掉捣乱的 manager 才是目的；重建 gadget 不是。
        log "usb manager killed; leaving the gadget alone (no re-enumerate)"
        configure_iface rndis0 || true
        configure_iface usb0 || true
    else
```

**杀掉那个 manager 就够了，gadget 不需要跟着重建。** 重建是纯粹的副作用，
而它正是打断链路的那件事。地址仍然重新配一遍，因为被杀的 manager 可能已经把地址带走了。

### 产物

```
halium-boot-zl1-v63-noreassert.img
18,010,112 字节
SHA256 d1f4fe29e282792b37f9e21230d49527d918abd5e012cb9a66232234a0ae44c8
```

构建方式（`--patch` 是这次给 `make-v63-boot-image.sh` 新加的能力）：

```bash
scripts/make-v63-boot-image.sh \
  --kernel-from /mnt/data/halium-zl1-candidates/halium-boot-zl1-v63-usbd-disabled.img \
  --patch boot/patches/0100-no-reassert-on-usb-manager-kill.patch \
  --out /mnt/data/halium-zl1-candidates/halium-boot-zl1-v63-noreassert.img
```

已验证它相对 v63 **只差一个文件**：

```
kernel identical : True
DTBs   identical : True
cmdline identical: True
file list identical: True (322/322)
differing files  : ['scripts/init-bottom/zl1-postswitch-debug-init']
```

## 5. 老实说清楚边界

- **实测**：gadget 每 ~2 分钟重新枚举一次；36 分钟里只有 2 次能 ping 通；keeper 的
  `kill_usb_managers` → `force_android_usb_rndis usb-manager-killed` 是镜像里唯一会
  写 `enable=0/1` 的代码路径。
- **推断**（尚未直接证实）：被杀的 manager 是 UT 的 `usb-moded`（或它的 udhcpd），
  由 systemd 反复拉起；keeper 的 `write_runtime_systemd_units` 用 `/run/systemd/system`
  里的 `/dev/null` 符号链接去 mask 它，但**对已经在运行的实例无效**。
  要证实需要一份 keeper 自己的日志——那在设备上，要等一次按键。
- **因此**：`noreassert` 是不是真的解决，得看装上之后的实测：重新枚举次数应当趋近 0，
  而可用窗口从"每 2 分钟 45 秒"变成"持续可用"。

## 6. 和之前那个内核补丁的关系

[`23-uether-tx-wakeup-patch.md`](23-uether-tx-wakeup-patch.md) 修的是一个**真实的代码缺陷**
（`netif_wake_queue` 与 `netif_start_queue` 的可达性不对等），但**它多半不是这个故障的原因**。

两个都留着，但顺序要换：

1. 先上 `noreassert`——它针对的是实测到的、量级更大的问题
2. 内核补丁作为后续，在链路稳定之后再评估它有没有独立价值

**设备侧看门狗不撤。** 它现在既是记录器，也是这一轮唯一还活着的事后取证手段。
