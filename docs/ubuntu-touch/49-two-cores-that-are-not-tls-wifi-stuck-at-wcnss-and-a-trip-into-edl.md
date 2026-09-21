# 49 — 两个服务的 core 不是 TLS 了，Wi-Fi 卡在 WCNSS 没被拉起来，以及一次把设备送进 EDL 的误操作

**日期**: 2026-09-21
**状态**: `48` §5 里"要用 core 看，不猜"的三件事都做了，结论和猜测的不一样：`lomiri-location-serviced` 和 `biometryd` **加了垫片之后死的不是 TLS 那处了**，两边的 `pc` 都是 `0x0`（调了一个空函数指针），而且前者只在真的用 Android GPS 那条路（`gps::Provider`）时才崩。顺手把 `hybris-crash-hunt.sh` 一个"看起来对、其实答非所问"的取 core bug 修了。Wi-Fi 的结论比 `48` 具体得多：**内核里驱动齐全、固件路径也对、容器里 userspace 全在跑，但 WCNSS 子系统从来没被拉起来过**。最后是事故：**`cnss` 平台驱动 unbind/bind 把设备送进了 EDL（`05c6:9008`）** —— 一个看起来完全可逆的运行时操作，实际不是。
**接续**: [`48`](48-the-tls-fault-was-killing-seven-system-services.md)、[`46`](46-the-gui-runs-dev-ion-was-root-only.md)、[`40`](40-get-a-core-not-a-guess.md)

---

## 1. 先修工具：取 core 不能按名字

`hybris-crash-hunt.sh` 原来在跑之前 `rm -f $COREDIR/core.$TAG.*`，跑完取 `ls -t | head -1`。第一次拿 `lomiri-location-serviced` 去抓，拿回来的 core 解析得**非常干净**：`__ctype_get_mb_cur_max+8`，栈是 `libmir1al → libmir1server → graphics-android2 → libandroid-properties → linker/o.so → libc++ → android libc`。

那就是 `45` 那篇的结论。**但它是上一次启动留下的 `core.MirServerThread.1061654`。** 两个原因：

1. 内核的 `%e` 只保留 15 个字符，`lomiri-location-serviced` 的 core 叫 `core.lomiri-location.<pid>`，跟 `core.lomiri-location-serviced.*` 匹配不上，所以那句 `rm` 什么都没删掉；
2. 一个包装脚本（`lsc-wrapper`）死掉的其实是它 `exec` 的那个二进制，名字本来就不可能对。

于是"没有新 core"退化成了"拿最旧的 core"，而且那份 core 分析得漂漂亮亮。这正是 `40` 说的那个坑：**看起来答了，其实答的是另一道题。**

改法是按时间不按名字：

```sh
touch /tmp/$TAG.stamp
timeout 60 $CMD $ARGS >/tmp/$TAG.out 2>&1
find $COREDIR -maxdepth 1 -name 'core.*' -newer /tmp/$TAG.stamp | head -1 > /tmp/zl1-hunt-core
```

时间戳骗不了人。`--from-pid` 那条路也一起改了（它本来就按 `$EXPECT` 精确匹配，现在同样写进 `/tmp/zl1-hunt-core`）。

## 2. `lomiri-location-serviced`：垫片管用了，死在后面的空函数指针

拿包装脚本本体去跑（`/usr/libexec/lxc-android-config/lomiri-location-serviced-wrapper`，也就是 unit 真正 `ExecStart` 的东西），**exit=139，新 core 拿到了**。这次是真货：

```
signal  : 11  si_code=1  si_addr=0x0
pc       0x0                      (unmapped)
lr       0x721323aa68  liblomiri-location-service.so.3.0.0 +0xdaa68
frame0   0x721323db30  liblomiri-location-service.so.3.0.0 +0xddb30
frame2   0x721324c968  liblomiri-location-service.so.3.0.0 +0xec968
frame4   0x72131b37bc  liblomiri-location-service.so.3.0.0 +0x537bc
frame5   0x5f7fc38d9c  /usr/bin/lomiri-location-serviced +0x15d9c
frame7   0x7212c1abdc  libc.so.6 +0x8abdc
```

**`pc` 是 `0x0`，`si_addr` 是 `0`** —— 不是"读了一个空指针的成员"，是**跳到一个空函数指针上**。栈整个在 `liblomiri-location-service` 里，从主程序调进去。

它跟 TLS 有没有关系，有一个很干净的对照实验。同一份二进制、同一个垫片：

| 跑法 | 结果 |
| --- | --- |
| `--provider dummy::Provider` | **不崩**，`exit=124`（20 秒超时把它杀掉），日志里 `Instantiating and configuring: dummy::Provider` |
| `lomiri-location-serviced-wrapper`（真配置：`--provider gps::Provider --provider remote::Provider`） | **SEGV** |

**只有走 Android GPS 那条路才崩。** 所以 TLS 槽那一关已经过去了（不过去的话连 dummy 都跑不起来），现在坏的是 GPS provider 那一段里的一个函数指针 —— 大概率是从 hybris/HAL 拿回来一个 `NULL` 就直接调了。这是另一个 bug，且是可以查的 bug。

## 3. `biometryd`：同一个形状

```
signal  : 11  si_code=1  si_addr=0x0
pc       0x0
lr       0x71a66a6750  libbiometry.so.2.0.0 +0xd6750
frame0   0x71a661b99c  libbiometry.so.2.0.0 +0x4b99c
frame3   0x71a65faadc  libbiometry.so.2.0.0 +0x2aadc
frame4   0x635d996a60  /usr/bin/biometryd +0x1a60
```

一样的形状：`pc=0x0`，栈在它自己的库 `libbiometry.so.2.0.0` 里。两个服务都是"插件/后端加载进来之后，某个函数指针是空的"。

## 4. Wi-Fi：比 `48` 那句"没有模块"准确得多

`48` 写的是"没有无线模块可加载"。查下去发现**驱动是齐的，问题在更后面一层**。

**内核里什么都有**（`/proc/config.gz`）：

```
CONFIG_CFG80211=y
CONFIG_WLAN=y
CONFIG_CNSS=y          CONFIG_CNSS_PCI=y         CONFIG_CNSS_SDIO=y
# CONFIG_MAC80211 is not set
CONFIG_FW_LOADER=y     CONFIG_FW_LOADER_USER_HELPER_FALLBACK=y
```

`/proc/kallsyms` 里 **1356 个 `hdd_*`/`wlan` 符号**（qcacld-3.0 整个编进去了），`cnss_*` 一整套也在（`cnss_get_fw_image`、`cnss_wlan_pci_link_down`、`cnss_configure_wlan_en_gpio`…）。所以 `/lib/modules` 是空的、`lsmod` 是空的、`find / -name '*.ko'` 一个都没有 —— **因为全部是 `=y` 编进内核的，不是缺模块。**

**PCIe 设备已经绑上了**：`0000:01:00.0` 是 `168c:003e`（QCA6174），`driver -> cnss_wlan_pci`。

**固件路径是对的**：

```
/sys/module/firmware_class/parameters/path = /vendor/firmware_mnt/image
```

宿主上 `/vendor` 是 `/android/vendor` 的软链，所以这个路径从内核（宿主根）解析过去就是真目录，`qwlan30.bin`（746 KB）、`bdwlan30.bin`、`bdw2.bin` 都在里面。**缺的从来不是固件。**

**容器里 userspace 全在跑**：`cnss-daemon`、`/vendor/bin/hw/android.hardware.wifi@1.0-service`、`wificond`、`wifidisplayhalservice` 都是活进程，`init.svc.cnss-daemon=running`。

**但结果是没有 `wlan0`**，而且：

```
/sys/kernel/debug/cnss-prealloc/status
Total Memory: 1888Kb     Used: 0Kb     Free: 1888Kb
```

**1888 KB 全空。WCNSS 子系统从来没被拉起来过。** 这就是为什么没有 `wlan0`：不是驱动不在，是芯片的电和固件那一步没发生。

触发面也摸了：

| 属性 | 权限 | 行为 |
| --- | --- | --- |
| `…/soc:qcom,cnss/wlan_setup` | `0400` 只读 | 读出来是 `50` |
| `…/soc:qcom,cnss/fw_image_setup` | `0600` 可写 | 写 `1` → `EINVAL`；写 `0` → 成功；读回来是 `0` |
| `/sys/module/wlan/parameters/fwpath` | 1010:1010 | 写它 → `ENOSPC`（驱动的 store 不接受） |

`cnss-daemon` 里没有 `wlan_setup`/`fw_image_setup` 的字符串（在设备上 `grep -a` 提的），它做的是 `cld80211` netlink（7 处）和 WLPS。它自己也说：

```
I/cnss-daemon: Failed to initialize cld80211 family, proceed with legacy USERSOCK reception
```

`cld80211` family 是 qcacld 注册的 —— 它没注册，也就是 qcacld 的初始化没走到那一步。所有线索指向同一句话：**要把 WCNSS 拉起来（PIL 镜像 + 上电），而没人拉。**

## 5. 事故：unbind `cnss` 会把设备送进 EDL

想知道拉起来那一步为什么会失败，最直接的想法是让驱动重新 probe 一次，好把它的报错读出来 —— 因为内核 ring buffer 已经被我们自己那个 `tx_complete` 的 WARN 刷得只剩最后约 18 秒，开机时的 cnss 日志早就被覆盖了。所以我做了：

```sh
echo soc:qcom,cnss > /sys/bus/platform/drivers/cnss/unbind
echo soc:qcom,cnss > /sys/bus/platform/drivers/cnss/bind
```

在任何一个 Linux 上这都是"可逆的运行时操作"。**在这台设备上不是。** 主机这边的内核日志：

```
18:37:47 usb 3-3: USB disconnect, device number 48
18:37:47 rndis_host 3-3:1.0 usb0: unregister 'rndis_host' ... RNDIS device
18:37:49 usb 3-3: new high-speed USB device number 49 using xhci_hcd
18:37:49 usb 3-3: New USB device found, idVendor=05c6, idProduct=9008
18:37:49 usb 3-3: Product: QUSB__BULK
```

**`05c6:9008` 是 Qualcomm 的 EDL / Sahara 下载模式。** 设备从 RNDIS（`18d1:d001`）直接掉进了 EDL，`18d1:` 那个 ID 从 USB 总线上消失，SSH 当然也断了。

试过的、**没有**用的救援（都不涉及刷写）：

- USB 端口 unbind/bind（`/sys/bus/usb/drivers/usb/{unbind,bind}`）：还在 `05c6:9008`。
- 等它自己退出：没有。

按约束，**EDL 里不能用 QFIL 类工具**，所以恢复只能靠物理按键（长按电源键硬复位）。这条写在这里，也写进 memory：**在这台 zl1 上不要 unbind `cnss` / `cnss_pci`。**

`cnss_pci` 有个 `pcie_link_down_panic` 参数（当前 `0`），但从现象看，PCIe 那一侧的 link down 在 msm8996 上直接触发了 SoC 级的 crash-dump 路径，而那条路的终点就是 EDL。**一个"只是重新 probe 一次驱动"的操作，代价是整机下线。**

## 6. 下一步（都在设备回来之后）

- **先恢复设备**：长按电源键 ~10–20 秒硬复位，确认重新以 `18d1:d001`（RNDIS）出现，`grep -qa msm8996 /proc/device-tree/compatible` 自检一遍，`adb devices` 里不该有 `33e80afe`。
- **把内核日志接住。** 现在 `dmesg` 只能留最后 18 秒，`journalctl -k` 只有 1 行（journald 没接 `/dev/kmsg`）。所以写了 `scripts/install-kmsg-drain.sh`：一个 `DefaultDependencies=no` 的 unit，先把环形缓冲整份快照下来（`dmesg` 走 `SYSLOG_ACTION_READ_ALL`，读的是**整个**缓冲，所以在风暴把它刷掉之前抓得到开机的部分），再用一个常驻的 `/dev/kmsg` 读循环跟着写，8 MB 轮转。日志留在 `/userdata/zl1-kmsg/`，unit 在 `/etc/systemd/system` 这个可写路径上。**它还没在设备上跑过**（设备当时在 EDL），下次开机第一件事就是装它并核对 `boot.log` 里有没有 cnss 的行。**这一步必须在再碰 Wi-Fi 之前做完**，否则又只能在盲区里试 —— 而盲区里的试法已经证明代价是整机。
- **Wi-Fi**：有了开机日志再判断 WCNSS 那一步失败在哪 —— 固件、上电 GPB、还是 PIL。**不要再用 unbind/bind 去触发。**
- **`lomiri-location-serviced` / `biometryd`**：`pc=0x0` 已经是可查的了 —— 按 `lr`（`liblomiri-location-service.so.3.0.0+0xdaa68`、`libbiometry.so.2.0.0+0xd6750`）反查调用点，看那个函数指针是谁设置的。
- **顺带**：那个 `tx_complete` WARN 风暴本身也值得处理（它是我们 `patch-uether-tx-wakeup.sh` 带出来的），它让整个内核日志不可用，是这次只能盲试的直接原因。

## 7. 这一段改了哪些东西

| 文件 | 作用 |
| --- | --- |
| `scripts/hybris-crash-hunt.sh` | 改。取 core 从"按名字 + 取最新"改成"按时间戳取新的"（`touch` + `find -newer`），并写进 `/tmp/zl1-hunt-core`；两个分支都改。不这么改，它在找不到新 core 时会静默分析上一次启动留下的 core |
| `scripts/install-kmsg-drain.sh` | 新增。`--install` / `--remove` / `--status` / `--read`。开机时先把环形缓冲整份快照到 `/userdata/zl1-kmsg/boot.log`，再常驻跟读 `/dev/kmsg` 到 `kmsg.log`（8 MB 轮转，保留新的一半）。unit 在 `/etc/systemd/system`，排在容器之前。**尚未在设备上验证** —— 写它的时候设备在 EDL |
