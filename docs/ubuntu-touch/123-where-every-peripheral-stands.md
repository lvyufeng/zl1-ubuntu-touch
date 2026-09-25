# 123 — 每个外设现在到底在哪儿（一页，写给自己看的）

**日期**: 2026-09-25（**更新过**：新增 **§1.1**——"这一页不完备"这句话现在**有一个数字**了）
**状态**: 这一篇**不是一个阶段**；它最后一次更新时设备**在 fastboot**，而**那之后它变过两次状态**——
详见 §5，那里的每一句都现在带**读出它的时间**。这一篇**不是一个阶段**，是一件本来早该有的东西：
把每个外设的当前状态、**它是怎么被证明的**、以及**还没证明的那部分**收在一页上。
写它的理由很直接：仓库里最近一份"状态"文档是 [`25`](25-status-2026-09-17.md)，8 天前，
而且它整篇讲的是一个**已经解决了的问题**（网络断流）。
这中间的每一轮都在**往上加**，但没有任何一页在**回答"硬件驱动到什么程度了"**。

**为什么现在写**: 因为目标里那句话是"**所有的硬件都能驱动**"，而这句话**没法用一句"进度"来回答**，
只能一个一个说。而且这个仓库已经有过好几次教训：**"看起来没坏"和"驱动起来了"不是一回事**，
其中相当一部分是**量错了**，不是坏（[`60`](60-*.md)–[`80`](80-*.md)、[`96`](96-*.md)、
[`103`](103-*.md)、[`104`](104-*.md)）。所以这一页的每一行都**点名它的仪器**：
断言要么能自己复读，要么就说清楚它是谁的眼睛看到的。

**接续**: [`120`](120-the-subsystem-nobody-has-looked-at.md)（modem）、
[`121`](121-the-third-question-about-the-heat.md)（发烫的第三个原因）、
[`122`](122-the-experiment-that-has-to-be-able-to-refute-it.md)（怎么去试它）。

---

## 1. 一页表

三种状态，**用词是严格的**：

* **已证明** —— 有一件仪器，或者有**用户自己的眼睛/耳朵**做过见证；
* **部分** —— 链路的一段被量过了，**但"它工作了"这件事还没被证明**；
* **只量过离线** —— 仪器存在、离线可核对，**设备上一次都没跑过**。

| 外设 | 状态 | 谁证明的 / 怎么复核 | 还没证明的那部分 |
|---|---|---|---|
| **显示 + 触摸** | **已证明**（用户，2026-09-21） | 用户**亲眼、亲手**确认；GUI **冷重启后自己起来**（两个 boot unit，验过两次） | 无。**不要再重新诊断它** |
| **返回键** | **已证明**（2026-09-23） | 打补丁的 `Shell.qml` 让 `Qt.Key_Back` 走 Home 键的 `launcher.toggleDrawer`，bind-mount 安装（`install-shell-back-key.sh`，doc 75） | 无 |
| **音频（扬声器）** | **已证明**（用户，2026-09-23） | **用户听见了。**链路每一段都有证据（doc 74）：sink 的端口已是 `output-speaker`、容器 HAL 打出 `out_snd_device(2: speaker-stereo)`、codec 回读为播放态、host 上只有 `pcmC0D15p` 一个 PCM 在跑 | 无。**注意**：`pulseaudio` 是 **user** unit，用 `systemctl --user -M '32011@' is-active pulseaudio` 查，**不要**用 `systemctl is-active pulseaudio`（那个 unit 不存在，问它会得到一条假的"音频坏了"） |
| **Wi-Fi** | **已证明**（能扫到 AP） | 自己起来；`iw dev <if> scan` 返回 AP。`zl1-health-check.sh` 里读 | **连接（association）没测过** —— 需要只有用户才有的 AP 密码。接口名**每次 boot 都变**，永远不要按名字找它 |
| **蓝牙** | **部分** | `bluebinder` 在容器的 PID namespace 里跑，`hci0` 出现（`UP RUNNING`，`08:BD:D0:FA:EF:B4`），`bluetoothctl --timeout 25 scan on` 收到 **77 个设备**（含有名字的） | **配对/连接没做过**。扫描成功 ≠ 能连上 |
| **传感器（加速度/磁力/陀螺）** | **已证明**（有数据流） | `sensorfwd` 在容器 namespace 里，`availableSensorPlugins` 列出 9 个；三个调用（`loadPlugin` → `requestSensor` → `start`）都做齐之后，三路数据在流（加速度 `xyz ≈ (-3, 21, 1010)` mG，约 1 g，平放） | 无。**但"一个传感器就是三个调用"**：少一个，健康的传感器看起来也是死的 |
| **传感器 · 方向（orientation）** | **部分，而且它不是坏的** | 它是**六位置、只在变化时上报**的分类器（sensorfw 自己的描述），所以"放着不动就没有新样本"是**正确**的。仪器 `zl1-orientation-axes.sh` | **它报的值对不对**。它报 **6**，而加速度的 z 是 **+1010 mG**（Android 帧里 face-up 应该是 5）——取值链已经查到头（三个同名枚举、一张保留名字的换表、qtmir 忽略两个 face 值），**唯一还没试的候选是一次 x/y 交换**，由一次 `--portrait-up` 决定。**横屏跟着息屏/亮屏走**，因为 qtmir 只为四个**边缘**位置移动屏幕 |
| **传感器 · 光（ALS）** | **部分** | **它不是一个"从不"**：时间戳永远是 0（任何按年龄判断的测试都读成"从不"），**而 lux 字段在动**（94 → 96 → 98 → 97）。探针现在说的是"值在动，adaptor 从不给样本打时间戳" | 它有没有被**任何东西消费**（屏幕亮度策略） |
| **传感器 · 压力** | **不存在** | `pressuresensor` **连 bus object 都没有**，尽管它的 plugin 加载了 | **`availableSensorPlugins` 列的是 plugin，不是硬件** —— 这台设备没有这个传感器 |
| **摄像头** | **两部分要分开读：栈证明过，app 没有** | **栈**：`test_camera`（Halium/Android 的测试二进制，**不是 UT 的相机 app**）渲染预览时合成器 20–26 ticks/s 对空转 2 ticks/s，并且抓到一张和参照图 NCC 0.944 的截图（doc 77）。**app**：只到"起得来"——`Added camera "0"/"1"` + `Application is now active` + 30 s 不退出（doc 80），而**那几趟的显示器全程是关的**（`ActiveOutputs 0 0`），因为 app 是从主机经 `nsenter` + 一个 Python 启动器手工起的 | **app 这个程序在人手里能不能用，一次都没量过**：屏上有没有它、预览出不出帧（doc 80 §6 的头两条），以及**人真正走的那条路——点图标 → `lomiri-app-launch`——从来没成功过**，doc 84 §5 明说不证明那条路一样。仪器 `zl1-camera-app-test.sh --keep-display`（health check 第 1 项，79 条离线检查）就是量这个的，**它从来没在设备上跑过**。三个会表现成"app 起来了、屏上空的"的已知缺口：`/system/lib64/libui_compat_layer.so` 被按**绝对路径**要、而 `/android/system` 是 ro ext4（只有基名能被 `HYBRIS_LD_LIBRARY_PATH` 找到）；media-hub 的会话路径不存在；`lomiri-app-launch` 没成功过。**注意**：`file` 会把截断的 PNG 报成合法 PNG |
| **GPS** | **只量过离线** | 仪器 `zl1-gps-probe.sh`（只读）；**第一个客户端有名字了**：预装的天气 app 的 QML 里 `PositionSource { active: settings.detectCurrentLocation }`，它自己的 AppArmor profile 带 `location` | **从来没有拿到过一次定位。**`u_hardware_gps_start` **一次都没被调用过**。文档 82 的两根杠杆都是死的（v63 的 boot hook 把 `/usr/bin/getprop` 换成没有 `custom.*` 分支的 stub）。**2026-09-25 又量了一条：它在内核这一层什么都没有**——`drivers/` 里没有 GNSS 驱动、`msm8996.dtsi` 里没有 GNSS 节点、配置里没有 `CONFIG_*GNSS*`，整个 `--dump-compatibles`（1499 行）里 `gnss`/`gps` **一条都不匹配**。GNSS 引擎在调制解调器（MSS）里，而固件从来没被挂上（doc 120/154）。**所以它不可能出现在任何从设备树派生的覆盖率报告里**——见 §1.1 |
| **指纹** | **只量过离线** | 两个仪器：`zl1-fingerprint-probe.sh`（**驱动以上的层**：存目录、HAL、信任库）和 `zl1-fp-kernel-probe.sh`（docs 157，**驱动这一层**）。**根因之一找到了（离线，doc 83）：是一个缺失的目录**，不是坏的 HAL。修法存在（`install-fingerprint-store-dir.sh`，doc 106） | **两个读数都一次都没在设备上跑过。**存目录的判据是 `journalctl -b -u biometryd | grep -c "setActiveGroup failed"` **变成 0**。**2026-09-25 又量了一条（离线，doc 157）：这块板的设备树声明两个指纹块，而内核只为其中一个编了驱动**——HAL 开的那一个（`/dev/goodix_fp`）**没有驱动**（`# CONFIG_INPUT_GP5XX8 is not set`，从**镜像自己嵌的那份配置**里读出来的），板上另一个块有（`CONFIG_MSM_QBT1000=y`）。**所以"指纹不工作"必须按块说**，而补上那个驱动 = 重新编译 + 刷 boot，**还没做**。**离那一行有多远也量过了（离线，doc 158）**：`host/zl1-fp-driver-build-check.sh` 把从"选项是关的"到"驱动绑上"的每一个环节都读了一遍，判定 **`one-config-line-away`**——选项在、依赖满足、源码在、`of_match_table` 与节点逐字节相同、**这次构建产出的五棵树每一棵都带节点且每一个驱动要的属性都在**、**镜像里附着的那五棵逐字节相同**、两个 `.c` 用**这次构建自己的命令行**编得过且 51 个未定义符号全部能在 `vmlinux` 里找到。**这条链只差配置里那一行**，而"那一行改在哪、要不要刷"仍然是设备的决定。**而那一行已经改了，驱动已经进了镜像（2026-09-25，doc 159）**：`lineage_zl1_defconfig:1871` 改成 `CONFIG_INPUT_GP5XX8=y`（`diff` 的全部输出就是这一行），重新编译内核，再拼进 v63 那份 initramfs，得到 `halium-boot-zl1-v63-fpdriver.img`。**而"只差一行"是从两张镜像里算出来的**：`host/zl1-boot-image-kernel.sh --diff` 读它们**各自嵌的那份配置**，答案是 **`1 option(s) differ`**（`CONFIG_INPUT_GP5XX8 y -> not set`），而两者的 initramfs（`ebb281ff5537d99a`）与五棵附着的设备树（`5b280099e84e773c`）**逐字节相同**——所以唯一的变量是内核。**但这一行改在内核树里，不在这个仓库里**，所以"改了"这件事**只由镜像证明**；而镜像**一次都没有在设备上跑过**，驱动绑不绑得上、绑上之后 HAL 开不开得了节点、节点开得了之后存目录在不在（doc 126）**全是运行时的事，一件都没量过**。**2026-09-24 之前的探针输出不要信**：它的存在性测试是 `nsenter -m -- test`，在这台设备上跑不起来，每次都答"missing" |
| **modem / telephony** | **只量过离线** | 仪器 `zl1-modem-probe.sh`（只读、从不打开块设备，已经在 capture 的默认集里当 04b） | **一次真机读数都没取过。**离线结论是：cmdline **一直**带着 `firmware_class.path=/vendor/firmware_mnt/image`（指对了），而 UT 的 `/vendor` 是**指向 `/android/vendor` 的软链**，所以问题从"路径"变成了"**那个挂载**"。要做的是读四行（doc 120 §7.1） |
| **发热** | **三个原因都装上了**（2026-09-25，`zl1-heat-fix-chain.sh --yes` 一条命令；docs 164。**这一页在 2026-09-25 没有重读设备**——状态是 docs 164/165 那一刻的） | ① v63 debug keeper 每秒 `systemctl` 一次（约一个核）——**退休 unit 在开机时解掉它**；② 镜像把四个核**全钉在 `performance`**——`install-cpufreq-governor.sh`；③ **SoC 被禁止用自己低功耗阶梯**（每条 cmdline 都带 `lpm_levels.sleep_disabled=1`）——`install-lpm-sleep-fix.sh`（doc 160），参数读回 **`N`**、`06-lpm-fix` 判词 `installed`。仪器：`zl1-thermal.sh`、`zl1-sleep-and-throttle.sh`、`zl1-lpm-ladder-trial.sh`（实验）、`zl1-ladder-temp-ab.sh`（doc 166，三窗口 A/B/C） | **装上 ≠ 有效果**：三个都在跑，稳态读数是「0.80/4 核忙、idle 43–51 °C、没有单一支配者」（docs 164 的存档）——**这说的是三个修都开着，没说它们买到了什么**。第三因在**温度**上值多少度，靠 `zl1-ladder-temp-ab.sh` 量：A（按装机）→ B（挡住阶梯）→ C（控制窗口，和 A 同状态），因为它自己一小时内就能漂 5.3 °C，两个窗口量不出东西。**这个仪器还没在设备上跑过。** |
| **网络（RNDIS）** | **已证明，而且原因是宿主侧的** | 宿主手动 bind `rndis_host` + 设 IP（**Option C**，`V63-OPTIONC-CONFIRMED-WORKING.md`）。35 s 失联是**宿主侧**的，设备一直没问题 | 无。**链路卡住时从宿主侧重新枚举 gadget**（`authorized` 0→1）：不用重启、不用插拔、不用按键 |

**`systemctl --failed` 是空的**（自 2026-09-21 的冷启动 `c86ce828-…` 起）。
最后一个 `update-machine-info-from-deviceinfo.service` 从来不是设备的错：
它的 TLS drop-in 被写到了 `…-from-deviceinfo.d` 而不是 `…service.d`，systemd 不读那个名字。
`hostnamectl` 现在报 `Pretty hostname: LeEco Pro3`（镜像本身在 `/etc/machine-info` 里放了 "Generic device" 这个占位符，
而那个 unit **只在当前值为空时**才写）。

---

## 1.1 这张表的上限：覆盖率的两个半边

§3 写着"这一页**不声称**完备"，而**不声称**在过去是一个姿态。2026-09-25 它变成了**一个数字**。

`zl1-hardware-inventory.sh` 回答的是"**哪一块硬件没有任何脚本读过**"，而这个句子里有**两个名词**——
**行**（表里写的块）和**块**（板上真有的硬件）。它过去只量第一个：报告里的每一行、每一个计数、
连"**0 gaps**"那句总结，数的都是**表里的行**，而表是**手写的**。所以**一行都没写的块**在那份报告里
不是"缺口"，而是**根本不存在**——缺口是"一行失败了"，而**缺了一行，什么都不会失败**
（这个形状在同一个文件里已经修过一次：那份报告曾经**搜到自己的源码**，于是每个块都被自己"覆盖"，
总结印出 **34 covered / 0 gaps**——一份**不可能报缺口**的报告；那一次修的是"**谁算仪器**"，见
[`137`](137-a-boot-should-answer-the-question-nobody-asked.md)）。

[`156`](156-the-coverage-is-about-the-table-and-nothing-measured-the-table.md) 补上了第二个半边：把表里每一行的
DTB pattern 拼成一条 alternation，再问**这一块板上每一个 `path/compatible` 是不是有人认领**。第一次跑：

| 读数 | 值 |
|---|---|
| 这块板上**没有任何一行认领**的 `compatible` | **142 个不同值 / 242 个 path-compatible 对** → 表改过之后 **135 / 230** |
| 报告的表 | **29 → 30** 行 `HW` |
| 缺口 | **0 → 1 → 0**——docs 156 的读数加上那一行时**自 docs 148 清零以来第一次不为零**，而 docs 157 写了读它的探针，于是**又回到 0**：这个 0 仍然是**关于"行"的**，见这段下面两句 |
| 那一个缺口是 | **`fingerprint-spi`**：`/soc/qcom,qbt1000`，驱动**编进了内核**（`CONFIG_MSM_QBT1000=y`），它自己建出 `/dev/qbt1000` **和一个输入设备 `qbt1000_key_input`**（这个工程**在屏幕上见过**那个输入设备，doc 70/73）——而**这棵树里没有任何脚本读过它**。它的设备树子节点是 **`qcom,fingerprint-sensor-ssc-spi-conn`**：**指纹的 SPI 通路在这一块里** |

这一条读数值得记住的**不是那个数**，是它的**形状**：那 30 行里，**1 行是这次读数找出来的**，

**而这一行现在是活的**：docs 157 为它写了仪器（`zl1-fp-kernel-probe.sh`，采集链的 04o，只读，一个设备节点都不打开），于是**缺口列表回到 0**。所以那 30 行里**唯一一行不是手写的**，也是**唯一一行从"被测量找出来"到"被读上"走完全程的**。回到 0 这件事**不改变 §1.1 的上限**：那个 0 仍然是关于行的，而同一份报告在它下面两行仍然印着"这块板上有多少个 compatible 没有任何一行认领"，以及那句"没有设备树节点的硬件永远进不来"（GPS 就是那一个，见再下一段）。
其余 29 行是过去十二轮里一行一行手写进去的。**手写的清单不会报告自己漏了什么**——
所以缺口的判据从"谁忘了写探针"变成了"**读数说这里有一块没名字**"。

**而这个读数有它自己的盲区，同一轮也量了**：**没有设备树节点的硬件，它永远看不见。**
GPS 就是那个例子（§1 那行）：它在**内核这一层什么都没有**——没有驱动、没有节点、没有 `CONFIG_*`、
在整个 dump 里一条都不匹配。**所以"所有的硬件都能驱动"这句话里的 GPS 那一格，必须靠这一页来回答**，
而不是靠那份报告。这就是这一页存在的理由，现在它是**量出来的**，不是感觉出来的。

---

## 2. 三条会被误读的规则，每一条都曾经误读过

1. **截图永远不能证明一个东西是"活的"**（doc 77）。`zl1-screenshot.sh` 抓的是 shell 的 *scene*，
   **一个已经死掉的客户端最后一帧还留在里面**：在没有 `test_camera` 进程（只有 `lomiri` 占着 `wayland-0`）
   的情况下抓的一帧，和它跑着时抓的那一帧**逐像素相同**（NCC 0.997），
   而 `TurnOn` → sleep 4 → 重抓**也不清屏幕**。**"活着"的判据是合成器自己的 `utime+stime` 速率**
   （显示点亮：无客户端 2 ticks/s，有预览 20–26），**从来不是 app 自报的 fps**，也**从来不是 PNG 字节差**。
2. **走过 binder/hwbinder 的东西必须在容器的 PID namespace 里跑**（`nsenter -p`）。
   `grep -a libgbinder <binary>` 能告诉你哪些是。它**不是**"所有跟 Android 说话的东西"——
   `pulseaudio` 在 host namespace 里跑得好好的，因为 droid 音频 HAL 是**在进程内**加载的。
   同理：**Android 属性也一样**，host 上的 `getprop` 是 stub，真 `getprop.orig-zl1` 从 host 问也什么都拿不到。
3. **一件仪器的答案里混进一个和问题无关、又不受控的量，它测的就不是它声称在测的东西。**
   这条在这台设备上出现过至少五次，形态各不相同：探针按固定深度 glob DT 阶梯（**静默漏掉最深的三个 system 档**）；
   相机仪器把合成器速率打成了 100 倍（绝对门槛 `B >= 8` 变成 0.08/s，一条**不可能失败**的门槛）；
   一条断言在整份输出里找三位数字，而那份输出里含**宿主自己的 uptime**（每 1000 秒里红 100 秒）；
   一个 harness 的 applier 副本漏改 `/proc/uptime` 于是读到的是宿主的；
   以及**双引号里的 backtick 是命令替换**——一个"只读"的页面因此真的跑了 `nsenter` 和 `systemctl`，
   并在仓库根目录留下一个文件（doc 122）。

---

## 3. 这一页**不**声称什么

* **不声称"硬件都驱动了"。**表里 14 项：**5 项已证明**、**4 项部分**、**1 项不存在**、
  **3 项只量过离线**、**1 项（发热）三个修复都装上了、效果只量过一部分**（2026-09-25 更新；docs 164/166）。
* **不声称这一页是完备的。**它是"已经有人查过的那些"。**没出现在表里的东西没被查过**，那不是"没问题"。
  2026-09-25 起这句话**有一个数字**：设备树派生出来 **30 个块**，30 个都有人读了（`fingerprint-spi` 是 docs 156 的读数找出来的那一行，docs 157 给它写了仪器）——**而这个 0 只是关于行的**，因为**没有设备树节点的硬件（GPS）连在这份派生里都不会出现**——见 §1.1。
  2026-09-25 起这句话**有一个数字**：设备树派生出来 **30 个块**，其中 **1 个（`fingerprint-spi`）没有任何脚本读过**，
  而**没有设备树节点的硬件（GPS）连在这份派生里都不会出现**——见 §1.1。
* **不声称任何"部分"那一栏是好的。**"链路的一段被量过"和"它能用"是两件事，
  这一页把两者分开写就是为了这个。**这一条在摄像头上已经咬过一次**：这一页原来那一行写「预览上过屏」，
  而这句里的"预览"是 `test_camera` —— Halium/Android 的测试二进制，**不是 UT 的相机 app** 放的。
  一句话把"栈能动"读成"app 能用"是最容易犯的一次误读，所以那一行现在把两个主语分开写。
* **不声称离线结论在真机上成立。**"只量过离线"那一栏的三项（GPS、指纹、modem）
  **设备上一次都没跑过**，这正是它们被单独标出来的原因。

---

## 4. 如果只做一件事

**把三个"只量过离线"变成"跑过了"。**它们各有一条一行命令的判据：

```
指纹   --install 之后 journalctl -b -u biometryd | grep -c "setActiveGroup failed"   -> 0
modem  zl1-modem-probe.sh 的四行读数（doc 120 §7.1）
GPS    让天气 app 的 "detect current location" 打开（zl1-gps-first-client.sh）
```

三条都不需要 flash、不需要写分区，而且**前两条各有一个已经写好的、离线验证过的修法**在等着。

**但那需要设备回来**，而设备现在**在跑**（`33e80afe`，`18d1:d001`，RNDIS，见 §5）——
它自己在出了 EDL 之后回来了，而**同一天更早**它还在 fastboot 和 EDL 里各待过一段——而**一次按键只买回一次开机**，所以那一次开机的证据必须
**当场抓完**：只读链是**一条命令**，顺序被强制执行（[`107`](107-one-physical-press-buys-one-command.md)、
[`124`](124-the-boot-a-finger-bought-is-one-command.md)）。
**挡在这一切前面的仍然是电**：这一次开机的每一项都压在电池能不能撑住开机上，而那个闸门的仪器是
[`150`](150-the-gate-the-rest-of-the-project-waits-behind.md) 的 `zl1-battery-gate.sh`——
插**墙充**，然后 `bash scripts/host/zl1-battery-gate.sh --samples 9 --interval 60`。

---

## 5. 设备状态

**最后一次真实读数（2026-09-25，本机 USB 上）**：设备**在跑 Ubuntu Touch**，**不在** fastboot——
`lsusb` 是 `18d1:d001`（RNDIS），boot_id `61c4abf0-1ec6-467d-bfd3-bf09169d99d7`，
序列号 `33e80afe`，`download_mode` 读 **0**（panic guard 已装并复核）。
**而这只说明"我读它的那一刻"**：同一天它先在 fastboot（`18d1:d00d`），
接着在 EDL（`05c6:9008`）里待过，**然后自己回来了**——三种状态一天之内都出现过。

**所以这一页的规矩改成：任何一句"设备现在在 X"都要带它被读出来的时间**，
并且把**最后一次真实读数**和**最后一次看见它**分开写（[`161`](161-the-bound-was-on-the-step-and-the-hang-was-in-the-call.md) §8）。
`zl1-health-check.sh` 一行就能重读，而它自己的 `NOT ON THE USB BUS` 分支就是这句话的诚实版本。

**认它按序列号，不按 USB ID**：同一条总线上有一个无关的 Xiaomi `4a2fe00b`（`18d1:4ee7`），
而 fastboot 的 `18d1:d00d` 是两个品牌共用的 ID；`18d1:d001` 是 **RNDIS**——PID 说的是**它在跑什么**，
序列号才说**是哪一台**（[`157`](157-the-answer-is-at-the-kernel-layer-and-it-is-opposite-for-the-two-blocks.md) 之后
这一页就是这么读的）。
整轮没有写任何分区或 boot，没有跑 QDL/QFIL，没有重启，没有绕过权限。

**一次开机仍然是一条命令**（[`124`](124-the-boot-a-finger-bought-is-one-command.md)：顺序被强制执行，
不是靠记性）：

```
# 0. 物理长按 POWER 10–20 秒，等 RNDIS 和 ssh
scripts/host/zl1-one-boot-runbook.sh --status    # 只读：这个 boot 上还剩什么没做
scripts/host/zl1-one-boot-runbook.sh --yes       # 六步，按唯一能成立的顺序
ssh root@$IP 'sh /tmp/zl1-lpm-ladder-trial.sh --apply'   # ← 单独的一次决定，不是一次读数
```

它跑的是 `01 capture`（只读）→ `02 panic guard`（**唯一跨 boot 的一步**）→ `03 heat chain`（发烫 ① 和 ②）
→ `04 fingerprint`（判据：`setActiveGroup failed` 归零）→ `05 trial --status`（只读）→
`06 lpm-fix`（[doc 160](160-the-third-heat-cause-had-an-experiment-and-no-installer.md)：**只有在 05 说
`supported-not-proven` 时才**把散热 ③ 的写入装成"每次开机都做"的 unit——它的执照就是**这一次运行**写出来的那份 05 输出）。
