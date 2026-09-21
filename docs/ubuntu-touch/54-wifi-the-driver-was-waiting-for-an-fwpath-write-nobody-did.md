# 54 — Wi-Fi：驱动从来没启动过，因为它要等一次没人做的 `fwpath` 写入

**日期**: 2026-09-21
**状态**: **`wlan0` 出现了。** `49`/`51` 一直在问"WCNSS 为什么没被拉起来"，答案不在固件、不在 PCIe、不在容器里那些 userspace 进程，而在**驱动自己的源码里**：qcacld 是编进内核的（`CONFIG_QCA_CLD_WLAN=y`），而这种情况下的 `hdd_module_init()` **什么都不做** —— `/* Driver initialization is delayed to fwpath_changed_handler */ return 0;`。真正的入口是 `fwpath` 这个模块参数的 set handler，**而这台设备上从来没有东西写它**。写进去之后：`wlan0` 出现、`FW:4.1.2.57`、`HW:QCA6174_REV3_2`、`wlan: driver loaded in 1151543`、cnss 预分配池从 0 变成 600 Kb 已用。
**接续**: [`53`](53-the-bridge-libraries-are-absent-and-were-never-built.md)、[`51`](51-what-the-wlan-driver-wants-read-from-its-own-source.md)、[`49`](49-two-cores-that-are-not-tls-wifi-stuck-at-wcnss-and-a-trip-into-edl.md)

---

## 1. 先有了日志，才看得见这件事

`52` 那个快照抓取器重启之后第一次真正用上。重启后的三份快照里，`boot-35s.log` 完整地存着从 `[0.000000]` 开始的**整个开机日志**：

```
[    0.395350] wlan_en_vreg: no parameters
[    1.007028] cnss soc:qcom,cnss: for AR6320 segments only will be dumped.
[    1.034720] cnss: Platform driver probed successfully.
[    2.247846] bt_power bt_qca6174: no qca,bt-vdd-core-voltage-level property
[    2.248045] bt_power bt_qca6174: no qca,bt-vdd-pa-voltage-level property
[    2.597872] wlan_en_vreg: disabling
```

（`49` 里根本读不到这些，环型缓冲只留十几秒，而且开机那一刻还没人连着。）这份日志立刻说了三件事：

1. **平台驱动探测是成功的**（`Platform driver probed successfully`）—— 和 `51` 从源码读出来的结论一致：`cnss_pci_probe()` 正常结束时的状态就是"把芯片放回睡眠"（`wlan_en_vreg: disabling` 就是那一句）。
2. **qcacld 一行都没有。** 没有 `Failed to probe WLAN`、没有 `wlan0`、没有 `hdd_`。也就是说 `cnss_wlan_register_driver()` 压根没被调用过。
3. 固件那边按 `51` §3 核对过：`qwlan30.bin`、`bdwlan30.bin`、`otp30.bin`、`utf30.bin` **都在**，缺的三个（`utfbd30.bin`、`epping30.bin`、`evicted30.bin`）是 UTF/EPPING 测试模式用的镜像，正常 mission mode 不需要。**固件不是问题。**（`51` §3 留的那条待办就此结清。）

## 2. 答案在 `hdd_module_init` 里

`drivers/staging/qcacld-2.0/CORE/HDD/src/wlan_hdd_main.c`：

```c
#ifdef MODULE
static int __init hdd_module_init ( void)
{
   return hdd_driver_init();
}
#else /* #ifdef MODULE */
static int __init hdd_module_init ( void)
{
   /* Driver initialization is delayed to fwpath_changed_handler */
   return 0;
}
#endif
```

编成模块时它初始化；**编进内核时它什么都不做**，把整件事交给 `fwpath_changed_handler`。而这台设备正好是后者（`arch/arm64/configs/lineage_zl1_defconfig` 里 `CONFIG_QCA_CLD_WLAN=y`）。handler 做的事情是：

```c
static int fwpath_changed_handler(const char *kmessage, const struct kernel_param *kp)
{
	ret = param_set_copystring(kmessage, kp);
	if (!ret) {
		...
		ready = vos_is_load_unload_ready(__func__);
		if (!ready) { VOS_ASSERT(0); return -EINVAL; }
		vos_load_unload_protect(__func__);
		ret = kickstart_driver(true, mode_change);
		vos_load_unload_unprotect(__func__);
	}
}
```

`kickstart_driver` → `hdd_driver_init()` → PCIe HIF → `cnss_wlan_register_driver()` → 上电、引导固件。**这就是缺的那一步。**

而那台设备上谁写它？`init.qcom.rc` 只有一行 `chown wifi wifi /sys/module/wlan/parameters/fwpath` —— 也就是**原厂 Android 是靠 userspace 写的**（正常是 wifi HAL，在 Android framework 活着的时候写）。UT 这边：容器里的 wifi HAL 因为 zygote 被我们停了（`47`），而且它也不是这个角色；宿主这边没人管。所以驱动等了一辈子。

**顺带解掉 `49` 那个 ENOSPC。** `fwpath` 的缓冲区是 `#define BUF_LEN 20`，而 `param_set_copystring()` 在 `strlen(val)+1 > maxlen` 时返回 `-ENOSPC`。我试的 `/userdata/zl1-firmware` 是 21 个字符 —— 所以那个 ENOSPC 是"这个名字太长"，不是"驱动拒绝了"。**而这个值本身不是路径**：`hdd_get_fwpath()` 全文只有一个调用点，只比较前两个字符是不是 `"ap"`（AP 模式）；真正的固件目录来自内核的 `firmware_class/parameters/path`，已经是 `/vendor/firmware_mnt/image`。所以 `"sta"`（station 模式）就够了。

## 3. 结果

```
$ echo sta > /sys/module/wlan/parameters/fwpath
$ ip -brief link show wlan0
wlan0   DOWN   b4:ef:fa:d1:32:38 <NO-CARRIER,BROADCAST,MULTICAST,UP>

Host SW:4.0.11.213X, FW:4.1.2.57, HW:QCA6174_REV3_2
wlan: driver loaded in 1151543
cnss_wlan_pci 0000:01:00.0 wlp1s0: renamed from p2p0
IPv6: ADDRCONF(NETDEV_UP): wlan0: link is not ready
```

`cnss-prealloc/status`：`Used: 600Kb`（原来是 **0**，`49` 就是拿这个判定"一次都没跑过"的 —— 现在这个判据被自己证实了）。

`wlan0` 是 `DOWN`/`NO-CARRIER`，那是当然的：**没连过任何网络**。而它一出现，已经有两个 userspace 进程在跟它说话：宿主上一直在跑的 `/usr/sbin/wpa_supplicant`，和 NetworkManager（日志里的 `Qt bearer thread`）。

## 4. 一个真实的危险对比

`49` 里 `unbind` `cnss` 平台驱动把设备送进了 EDL；这一次是**往驱动的正式入口写参数**（原厂 Android 的正常启动路径），不是拆链路。两件事在源码上的区别很清楚：`unbind` 会走 `cnss_wlan_pci_remove()` 那侧（拆 PCIe link），而写 `fwpath` 走 `kickstart_driver(true, ...)` 那侧（上电、引导）。**但这也是为什么动手之前先把日志抓起来**：`49` 的教训不是"别碰"，是"别在看不见的时候碰"。

设备完好：写完之后 SSH 断了一次（当时 load 很高），但设备没有重启、没有掉 EDL、`wlan0` 一直在。

## 5. `install-wlan-bringup.sh`

手工写一次不算数 —— 每次开机都得写，而且要等 `/vendor/firmware_mnt/image` 可读（固件是经内核固件加载器读的，容器文件系统没起来之前那个路径不存在，太早写会得到看起来像"固件坏了"的失败）。所以做成了和这里其它 unit 同一个形状：

- 设备侧 `/userdata/zl1-wlan/bringup.sh`：`wlan0` 不在 → 等 `/vendor/firmware_mnt/image/qwlan30.bin` 可读 → 写 `fwpath=sta` → 记一行。每轮记一次，成功后安静下来（每 60 秒看一次）；有重试预算，`wlan0` 掉了会重新触发。
- unit `zl1-wlan-bringup.service` 在 `/etc/systemd/system`（可写路径，活过重启），`After=multi-user.target`。

## 6. 还没解决 / 下一步

- **重启验证持久化。** 还没做（这一篇写完就去做）。
- **扫描是坏的。** `wpa_supplicant` 一直在报：
  ```
  wlan: [E :HDD] __wlan_hdd_cfg80211_dump_survey: 31044: chan_info is NULL
  ```
  `wlan0` 在、驱动在、固件在，但 scan/survey 这条路上 `chan_info` 是空的。这说明**驱动起来了不等于 Wi-Fi 能用** —— 这一条要单独查。
- **NetworkManager 认不认这张卡。** 它已经在发 ioctl（`__hdd_ioctl: unknown ioctl 35591`，那是它探测无线能力时打的，qcacld 不实现那个 ioctl，不一定是问题）。要确认它能不能建起无线设备、能不能扫到 SSID。
- 上面两条都解决之前，"Wi-Fi 能用"不算成立。

## 7. 这一段改了哪些东西

| 文件 | 作用 |
| --- | --- |
| `scripts/hybris-shims/install-wlan-bringup.sh` | 新增。`--install` / `--remove` / `--status` / `--trigger`。把"写 `fwpath`"做成开机自动、可重试的 unit；`--status` 一次打印 unit 状态、`fwpath`、`wlan0`、cnss 池用量、驱动日志和 bringup 日志 |
| `scripts/install-kmsg-drain.sh` | 用的（`52` 那个），这次重启第一次证明它在设备上真的抓到了从 `[0.000000]` 开始的完整开机日志 |
