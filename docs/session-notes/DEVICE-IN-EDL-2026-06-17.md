# V73 EDL 状态 - 需要用户物理操作

**日期**: 2026-06-17
**状态**: ⚠️ 目标设备 zl1 (serial 33e80afe) 处于 Qualcomm EDL/QDL 模式

## 当前 USB 状态

```
Bus 003 Device 071: ID 05c6:9008 Qualcomm, Inc. Gobi Wireless Modem (QDL mode)
  iProduct: QUSB__BULK
  iSerial: (空)
```

另有无关设备（必须忽略）:
```
Bus 003 Device 066: ID 18d1:4ee7 Google Inc. (MI 4LTE, serial 4a2fe00b)  ← Xiaomi cancro, 忽略
```

## 发生了什么

1. V73 (HTTP-enhanced boot image) 成功构建并 `fastboot boot` 进入了
2. 测试任务 (test-v73.sh) 启动但被中断
3. 设备现在出现在 `05c6:9008` (Qualcomm Emergency Download Mode)
4. 这是 boot 失败或 watchdog 触发的深层重置

## V73 ramdisk 验证结果

- ✅ Python 语法检查通过 (ast.parse 成功)
- ✅ handle() 函数完整, 包含 /exec + subprocess
- ✅ 所有 16 个函数定义齐全
- ✅ bootimg 结构有效 (kernel 13.24MB + ramdisk 2.36MB)
- ✅ V73 使用与 V63 完全相同的 kernel (zImage)

**结论**: V73 ramdisk 没有语法/结构问题。EDL 可能是:
- boot 时序问题 (V73 monitor 在 init 阶段卡住导致 watchdog)
- 或用户手动操作导致

## 用户需要做的事 (退出 EDL)

设备在 EDL 模式下不响应任何软件命令 (fastboot/adb 都无效)。
需要**物理操作**让设备退出 EDL:

### 方法 1: 强制重启 (推荐先试)
- **长按电源键 15-20 秒**，直到设备完全关机
- 等待 5 秒
- 短按电源键开机
- 设备应回到正常系统或 recovery

### 方法 2: 电源+音量组合
- 同时长按 **电源键 + 音量减键** 10-15 秒
- 设备应重启
- 然后引导到 recovery 或 fastboot

### 方法 3: 拔插 USB + 强制重启
- 拔掉 USB 线
- 长按电源键 20 秒
- 重新插上 USB 线
- 检查设备状态

## 退出 EDL 后的计划

设备重启后，我们观察它进入什么模式:

1. **如果进入 fastboot** (`18d1:4ee7` serial 含 33e80afe):
   - 重新 boot V73: `fastboot boot tmp-v73-http-enhanced/halium-boot-zl1-v73-http-enhanced.img`
   - 立即测试 HTTP POST /exec

2. **如果进入 charging+debug (V63 模式)**:
   - 说明回到了 V63 (已 flash 的 boot 分区)
   - 可以再次 `fastboot boot` V73

3. **如果进入正常系统或 recovery**:
   - 从 recovery 进入 fastboot: `adb reboot bootloader`

## 回退方案

如果 V73 反复导致 EDL，放弃 V73，回到稳定的 V63:

- V63 镜像: `tmp-v63-netd-disabled/halium-boot-zl1-v63-usbd-disabled.img`
- V63 已知能正常 boot 进入 charging+debug 模式
- V63 有 HTTP GET status endpoint (但**没有** /exec)
- 在 V63 下用 GET 查看状态信息调查硬件

## 安全提醒

- 设备在 EDL 是安全的 — 不会自动 flash 任何东西
- 不要在 EDL 下尝试用 QFIRE/qfil 类工具 flash (除非有完整备份)
- 关键分区 (boot/recovery/system/vendor/persist/modem) **尚未备份**
- 在做任何 flash 操作前必须先完成分区备份
