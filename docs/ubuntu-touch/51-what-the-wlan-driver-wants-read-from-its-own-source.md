# 51 — 把 Wi-Fi 驱动要什么从内核源码里读出来（日志还没有，但源码在本地）

**日期**: 2026-09-21
**状态**: `49` 的结论是"WCNSS 从来没被拉起来过，要看开机日志"，而日志还得等设备从 EDL 出来。这段时间里有更好的事可做：**内核源码树还在本地**（`/mnt/data/halium-zl1-build/kernel/leeco/msm8996`，就是那个 `3.18.140-lineage-gc2f6e859-dirty`），所以"驱动想要什么"是可以直接读出来的，而且读完就知道将来该在日志里 grep 哪几行、该检查哪几个文件名。这一篇记的就是这些。**全部是读源码 + 之前已经量到的设备状态**，没有任何新的设备操作。
**接续**: [`49`](49-two-cores-that-are-not-tls-wifi-stuck-at-wcnss-and-a-trip-into-edl.md)、[`48`](48-the-tls-fault-was-killing-seven-system-services.md)

---

## 1. 已经量到的事实，用源码读一遍

| `49` 里量到的 | 源码里对应的是 |
| --- | --- |
| `…/soc:qcom,cnss/wlan_setup` 读出 `50` | `wlan_setup_show()` 返回的是 `penv->revision_id`，而它唯一的写入点是 `cnss_pci_probe()` 里的 `pci_read_config_word(pdev, QCA6174_REV_ID_OFFSET, &penv->revision_id)`。**所以 `50`（0x32）= 从 PCI 配置空间读回来的芯片版本 —— PCIe 链路是活的，芯片在应答配置读。** 不是"芯片死了" |
| `…/soc:qcom,cnss` 和 `…/soc:wlan_en_vreg` 两个平台设备都在 | 前者是 cnss 平台驱动，后者是 `WLAN_EN_VREG_NAME = "vdd-wlan-en"` —— 这块板子上 WLAN 使能走**稳压器**而不是 GPIO（`of_property_read_bool(node, "qcom,wlan-en-vreg-support")` 为真时走 `regulator_enable()`） |
| `cnss-prealloc/status`：1888 Kb 全空 | 这个池子是 **qcacld** 在用（`drivers/net/wireless/cnss_prealloc/`）。全空 = qcacld 一次都没分配 = **WLAN 主机驱动从来没跑到那一步** |
| 没有 `wlan0`，`dmesg` 里没有 cnss 的行 | 见 §4：这条路上大部分诊断是 `pr_debug`（默认不打印），失败重试循环每轮不打任何东西 |

## 2. 拉起来的那条链

```
hdd_module_init()                        (qcacld-2.0/CORE/HDD/src/wlan_hdd_main.c)
  └─ … HIF PCIe …
      └─ cnss_wlan_register_driver(&cnss_wlan_drv_id)   (if_pci.c:3332)
          ├─ cnss_wlan_vreg_set(VREG_ON); msleep(POWER_ON_DELAY)
          ├─ [wlan_bootstrap_gpio > 0] 拉高 + msleep
          ├─ cnss_configure_wlan_en_gpio(WLAN_EN_HIGH)   -> regulator_enable("vdd-wlan-en")
          ├─ pci_register_driver(&cnss_wlan_pci_driver)  -> cnss_pci_probe()
          │     ├─ pci_read_config_word(...) -> revision_id = 0x32
          │     ├─ cnss_setup_fw_files(revision_id)      -> 选中一组固件文件名（§3）
          │     ├─ PCIe 挂起、WLAN_EN 拉低、vreg 关            <-- 故意放回睡眠
          │     ├─ cnss_wlan_fw_mem_alloc()、建 wlan_setup 属性
          │     └─ return 0                                 <-- 探测"成功返回"是正常的
          ├─ cnss_msm_pcie_register_event(...)            -> 注册 linkdown/wakeup 回调
          ├─ cnss_msm_pcie_pm_control(MSM_PCIE_RESUME)    -> 把链路重新拉起来
          └─ wdrv->probe(pdev, penv->id)                  <-- qcacld 的主探测
                                                             跑通之后才有 netdev
```

**关键点是最后一行**：`wlan0` 是 `wdrv->probe()` 成功之后才出现的。而这段代码里，`pci_register_driver` 成功、`wlan_setup` 属性建出来、探测函数 `return 0`，**都不代表芯片被拉起来了** —— `cnss_pci_probe()` 正常结束时的状态恰恰是"PCIe 挂起、WLAN_EN 低、vreg 关"。所以我们看到的 `wlan_setup=50` 只能证明"平台探测跑到了那一步"，不能证明任何后续。

`wdrv->probe()` 失败的话是一个**最多四轮的重试循环**（`probe_again > 3` 才 `pr_err("Failed to probe WLAN")`），每一轮都把链路关掉、`goto again` 重来。**中间三轮不打任何日志。**

## 3. 芯片要哪几个固件文件

`cnss_common.c` 里的表，`revision_id = 0x32`（`AR6320_REV3_2_VERSION`）走的是 `FW_FILES_QCA6174_FW_3_0`：

```
qwlan30.bin  bdwlan30.bin  otp30.bin  utf30.bin  utfbd30.bin  epping30.bin  evicted30.bin
```

设备那边 `/android/vendor/firmware_mnt/image/` 里已经确认 **有** `qwlan30.bin`（746600 字节）和 `bdwlan30.bin`（8124 字节）+ `bdwlan30.b01..b1c`。**另外五个我还没看过**（那次 `ls` 只看了前几十行），这是一条可以直接执行的检查：

```sh
ls -l /vendor/firmware_mnt/image/{qwlan30,bdwlan30,otp30,utf30,utfbd30,epping30,evicted30}.bin
```

而 `firmware_class/parameters/path` 就是 `/vendor/firmware_mnt/image`（`49` 量过），所以路径那头是对的 —— 不用去动 `/lib/firmware`（那个目录在这个 rootfs 里根本不存在）。

## 4. 将来要在日志里 grep 的原文

有了 `install-kmsg-drain.sh` 抓下来的开机日志，这条链只可能在这几个地方断，对应的原话是：

| 位置 | 日志原文 |
| --- | --- |
| vreg / 上电 | `wlan vreg ON failed`、`can't turn off wlan vreg` |
| PCIe 链路 | `PCIe link register failed! %d`、`PCIe link bring-up failed`、`PCIe link bring-up failed (link down option)`、`cnss: PCI link failed to recover` |
| PCI 探测 | `cnss: unknown device found %d`、`cnss: image desc allocation failure`、`cnss: Memory Alloc failed for codeswap feature` |
| 固件 | `cnss: meta data file open failure %s`、`cnss: image file read failed %s`、`cnss: meta data file has invalid size %s: %zu` |
| qcacld 探测 | **`Failed to probe WLAN`**（四轮都失败之后才打一次） |

反过来，**这条路上"看起来什么都没发生"是设计出来的**：`pr_debug` 的地方包括 `Code-swap not enabled: %d`（那句的文案和条件是反的，条件是 `cnss_wlan_is_codeswap_supported()`）以及探测里几处成功路径。所以要确认一件事必须开 dynamic debug 或看 `pr_err` 的原文，不能靠"日志里没有"推断"代码没走到"。

## 5. 一个看着像开关、其实是死接口的东西

`fw_image_setup` 属性（`cnss_probe()` 创建）只被一个函数用到：`cnss_setup_fw_image_table()`，而它的**唯一调用者就是这个属性的 store**。它的枚举值是：

```c
FW_IMAGE_FTM     0x01   -> 读元数据文件 "qftm.bin"
FW_IMAGE_MISSION 0x02   -> 读元数据文件 "qwlan.bin"
FW_IMAGE_BDATA   0x03   -> 读元数据文件 "bdwlan.bin"
FW_IMAGE_PRINT   0x04   -> print_allocated_image_table()，把已分配的表打出来
```

`49` 里写 `1` 得到 `EINVAL` 的**原因现在完全清楚了**：写 1 → 走 FTM → `request_firmware("qftm.bin")` 失败 → `pr_err("cnss: meta data file open failure qftm.bin")` → store 返回 `-EINVAL`。**那一次 EINVAL 其实是一条信息**：请求确实打到了内核的固件加载器，只是文件名不存在。

而写 `0` "成功"是因为 **0 不在枚举里**：三个 `if/else if` 全不匹配，直接 `pr_info("Firmware setup completed")` 返回 —— **一个静默的空操作。**

结论：这三个模式要的文件（`qftm.bin`/`qwlan.bin`/`bdwlan.bin`）都不是这颗芯片实际用的 `*30.bin`，`/vendor/firmware_mnt/image/` 里也都没有；而且**设备上没有任何东西去写这个属性**（`cnss-daemon` 的字符串里没有它，Android 的 init rc 里也没有）。所以它是这块板子上的一条死接口，**不是缺的那一步** —— 别把它当成开关。§2 里 qcacld 自己那条 BMI 路径才是加载固件的那条。

## 6. 下一步（等设备从 EDL 出来）

1. **先装 `install-kmsg-drain.sh`，再重启一次，读 `boot.log`。** 这是唯一能看见 §4 那几行的办法，`49` 已经把"不看日志就动驱动"的代价演示过一遍了。
2. 按 §3 的命令核对那七个文件名（读操作，安全）。
3. 按 §4 的表对着 `boot.log` 定位断点。
4. **确认之后再说怎么改。** 不再用 unbind/bind 之类的方式去逼驱动重新 probe。

## 7. 这一段改了哪些东西

**没有改任何文件。** 这一篇是读源码得到的结论（§1–§5），目的是让下一次上设备时是"按表核对"而不是"再试一次"。唯一相关的工具是上一段提交的 `scripts/install-kmsg-drain.sh`，它还没在设备上跑过。
