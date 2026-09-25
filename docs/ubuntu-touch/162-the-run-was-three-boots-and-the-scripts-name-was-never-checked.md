# 162 — 那次"单次开机"其实是三次，而脚本的名字是一个没人测过的断言

**日期**: 2026-09-25
**状态**: 这一轮**碰了设备**（一次只读的开机链），而它留下的第一个成果是**把上一轮的归档读对了**：
`tmp-one-boot-20260925T080325Z/` 里那 19 个读数**不是一次开机上的 19 个读数，是三次开机上的**。
归档的头写着 `boot_id: 61c4abf0-…`，而它自己的 `04d-lmh.txt` 写着 `boot id: c3ba7730-…`、
`04h-sdcard.txt` 写着 `693b2eed-…`——三个都是设备自己打的，**没有任何东西把它们连起来**。

于是这一页的三件事是同一个形状的三种写法：

① 一个**不能被打断的调用**（`nsenter -m` 进容器的 mount namespace）站在一条只读的开机链上，
而它挂掉时打出来的字**指向错的机器**；
② 一个 archive 的**头部是一个标签**，而步骤里的是**读数**，两者可以互相矛盾而没人问；
③ 一个脚本的名字（`one-boot-runbook`）是一个**断言**，而这一轮之前**没有任何东西测过它**。

**接续**: [`161`](161-the-bound-was-on-the-step-and-the-hang-was-in-the-call.md)（界下在步骤上，挂起在调用里；
这一页是它的下一层：上一轮把"哪一个界响了"分开了，这一轮问"这几步到底跑在哪台手机上"）、
[`149`](149-the-bound-of-one-boot-has-to-be-read-out-of-its-callee.md)（界要从 callee 的源码里数出来）、
[`117`](117-the-command-that-could-not-run-is-not-a-zero.md)（跑不起来的命令不是一个 0）、
[`131`](131-the-steps-had-no-clock-and-a-hang-spends-the-boot.md)（每一步都要有墙钟界）、
[`76`](76-a-stalled-link-is-a-host-side-problem.md)（停止运载流量的链路是主机侧问题）、
[`86`](86-edl-has-a-cause-a-panic-and-the-evidence-survives.md)（panic → EDL 这条路）、
[`160`](160-the-third-heat-cause-had-an-experiment-and-no-installer.md)（散热第三因的安装器）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 上一轮那次开机链，到底跑了几台手机？ | **三台**。`61c4abf0`（跑到 `04b-modem`）、`c3ba7730`（`04d` 到 `04g`）、`693b2eed`（`04h` 到 `04o`）。三个 id 都是**设备自己打的**，写在各自的步骤文件里。 |
| 那为什么归档说是一次？ | 因为 `boot_id` 是在**最上面读一次**、放进变量、然后**被携带**的——`INDEX.txt` 的头部是**标签**，步骤文件里的是**读数**，而没有任何东西比较过它们。 |
| 两次复位是什么时候？ | 从下一个步骤自己的 `uptime` 反推：`c3ba7730` 起于 **08:06:02**（`04d` 读到 `uptime 152.45s`，文件写在 08:08:35），`693b2eed` 起于 **08:11:47**（`04h` 读到 `98.20s`，写在 08:13:25）。 |
| 复位是被什么结束的？ | **不是界**。两次挂起分别起于 08:03:54 和 08:08:42，而复位发生在 **2 分 08 秒**和 **3 分 05 秒**之后，界要 4 分 30 秒（`HOST_BACKSTOP=270s`）才响。所以是**手机先下去**、ssh 的 socket 变成一个黑洞、界最后才把客户端收掉。 |
| 那两个 `124` 是谁打的？ | 上一轮已经分开：设备侧的 `timeout` 会打 `ZL1STEP-TIMEOUT device`，没有这个标记的 124 是**主机 backstop**，是关于**链路**的读数。归档里两条 124 都**没有标记**，而当时的注记把两条都算成了设备侧——这就是 doc 161 修的那一条。 |
| 挂起的调用是什么？ | `nsenter -t <pid> -m -- ls …`：进 Android 容器的 mount namespace 去列固件目录。两个探针各有一处，位置在**只读**的开机链上。 |
| 修法？ | 把**读容器视角**换成一个不需要进 namespace 的读法：内核格式的 `/proc/<pid>/mountinfo`（挂载表）+ `/proc/<pid>/root/<path>` 的存在性判断。并且两个 harness 各加一道**绊线**：源码里出现 `nsenter` 就是红。 |
| 那"三次开机"修了吗？ | 修了，而且修了**两处**：`zl1-post-recovery-capture.sh` 每一步之后**重读身份**，`zl1-one-boot-runbook.sh` 同样——因为这个脚本的**名字**就是那个断言。 |
| 身份有几个状态？ | **四个**：`same-boot` / `CHANGED-BOOT` / `unreadable` / `not-checked`。`unreadable` **不等于**"还是那次开机"——一个失败模式正好是它通过值的检查，不是一个检查。 |
| 写这一页时抓到了什么？ | 抓到**修法自己漏了一行**：`05-trial` 有它自己的 runner（它把脚本推上去、自己下界），所以**不走 `run_step`**，而重读住在 `run_step` 里——它的行停在 `not-checked`，而别的行都带标记。归档现在会**点名**这样的行（`boot_check_gap:`），并且有一个 mutation 专门删掉 step 05 的那次重读来钉住这个仪器。 |
| 还抓到了什么？ | 这个 harness 的 `want` 是**字面子串**匹配、不是正则，而成品是从 capture 的 harness 抄过来的——`^03-heat-chain +0 +CHANGED-BOOT` 是一个**永远匹配不上的模式**，它为一个**正确的**文件报了 8 个红。 |
| 刷了吗？ | **没有。刷镜像这一轮仍然没有做。** |
| 那"发烫解决了吗"？ | **没有。**`sleep_disabled` 到现在仍然读 `Y`（这一轮 09:12 重读），散热第三因**没有被安装**——`06-lpm-fix` 在上一轮被拒，因为它读到的 05 判词不是 `supported-not-proven`。 |

---

## 2. 证据：一个 archive 里三个 boot_id

`tmp-one-boot-20260925T080325Z/`（`tmp-*/` 被 gitignore，所以它不进货，但它是这一页的全部依据）。
运行窗口：`08:03:25` 起，`08:21:48` 收尾。每个步骤文件里的身份是**那个步骤自己打的**：

| 步骤文件 | 写盘时刻 | 文件里的 boot id | 文件里的 uptime |
|---|---|---|---|
| `04b-modem.txt` | 08:03:54 | `61c4abf0-1ec6-467d-bfd3-bf09169d99d7` | — |
| `04d-lmh.txt` | 08:08:35 | `c3ba7730-022d-493c-932c-67a1d2abeea4` | 152.45s |
| `04e-leds.txt` | 08:08:39 | `c3ba7730-…` | 154.37s |
| `04f-vibrator.txt` | 08:08:41 | `c3ba7730-…` | 158.45s |
| `04g-video.txt` | 08:08:42 | `c3ba7730-…` | 159.85s |
| `04h-sdcard.txt` | 08:13:25 | `693b2eed-4460-46ae-9816-83b2a9220b00` | 98.20s |
| `04i`…`04o` | 08:13:31–08:14:22 | `693b2eed-…` | 102–154s |

而**同一个目录**的 `INDEX.txt` 头部只写了一个：

```
# zl1 post-recovery capture
boot_id: 61c4abf0-1ec6-467d-bfd3-bf09169d99d7
```

`04c-sleep-throttle.txt` 里没有身份——**不是所有探针都打**。这正是这件事能藏两轮的原因：
一个读者要看出来，得**先知道哪个文件里有 id**、再**把它们并排看**。而归档的头部是一个**标签**
（"这个目录是为哪次开机起的名字"），不是**读数**；两者可以互相矛盾，而矛盾没有任何出口。

而矛盾的代价是具体的：第一次复位之后有 **14 行**（`04c` 到 `04o`，加 `07-orientation`）跑在一个
**不是归档名字上那个**身份上，而其中最后 **9 行**落在一台只起来了 **98 秒**的手机上——那 9 行里
**8 行是 `rc=1`**。在一台刚起来的手机上，"这个节点还没被创建"和"这个硬件不存在"**打出来是一模一样的字**
（doc 117）。所以那 8 行不是清单，是**一台还在起来的手机对新读者的抱怨**。

---

## 3. 两个 124，和两次复位

`capture/INDEX.txt` 里两条 124：

```
04b-modem            124   04b-modem.txt
04g-video            124   04g-video.txt
```

时间线（每一列的来源都写出来，没有一列是推的）：

| 时刻 | 事件 | 依据 |
|---|---|---|
| 08:03:54 | `04b-modem.txt` 的最后一行写盘（`container pid 35960; the same candidates in the container's mount namespace:`）——**这一行之后没有字了** | 文件 mtime |
| 08:06:02 | 手机复位 | `04d` 在 08:08:35 读到 `uptime 152.45s` |
| 08:08:29 | 主机 backstop 把这条 ssh 收掉（`timeout -k 5 270`） | 08:03:54 + 270 + 5 = 08:08:29 |
| 08:08:33 | `04c-sleep-throttle.txt` 写盘（它在**新**那次开机上跑） | 文件 mtime |
| 08:08:42 | `04g-video.txt` 的最后一行写盘——同样**之后没有字** | 文件 mtime |
| 08:11:47 | 手机第二次复位 | `04h` 在 08:13:25 读到 `uptime 98.20s` |
| 08:13:25 | `04h-sdcard.txt` 写盘（第三次开机） | 文件 mtime |

两件事是可以说的，第三件不可以：

1. 两次挂起**都发生在同一族调用上**（`nsenter -t <pid> -m --`），而且两次都是**设备侧一个标记都没打**
   ——说明设备侧的 `timeout -k 5 240` **自己也没响**，因为手机在它之前就下去了。
2. 两次复位分别在挂起开始后 **2 分 08 秒**和 **3 分 05 秒**，而界要 **4 分 30 秒**。
   所以把 ssh 结束的是**复位**（gadget 重新枚举 → socket 变成黑洞 → 主机侧客户端一直等，直到自己的界把它收掉）。
   这就是 doc 76 那条"链路停止运载流量"的形状，而它**住在这台笔记本上**。
3. **不能说**：挂起**导致**了复位。两次的间隔形状一致，两次都只有它在跑，但这一页没有能把
   "不可中断的进程"和"PMIC 硬复位"连起来的那条链。所以它作为**相关**记下来，不作为原因。

---

## 4. 修法一：把不可中断的调用从路径上删掉

两个探针各有一处 `nsenter`，都是**为了读容器的视角**：

* `scripts/device/zl1-modem-probe.sh`：容器的挂载表里有没有 `/vendor/firmware_mnt`；
* `scripts/device/zl1-video-probe.sh`：容器的 root 下面那几个固件候选目录在不在。

两处都换成一个**不需要进 namespace** 的读法：

```sh
# 挂载表：内核自己排的格式，从主机读，目标路径是相对 mount namespace 的
CVIEW=$(awk -v p=/vendor/firmware_mnt '$5 == p { print "mounted: " $5 "   (device " $3 ")" }' /proc/$A/mountinfo)
# 存在性：目标进程的 root 是内核给的一个句柄，和 nsenter 无关
[ -e "/proc/$A/root$c/$FW_NAME.mdt" ]
```

`/proc/<pid>/mountinfo` 是内核格式（字段 5 是挂载目标、字段 3 是设备），`/proc/<pid>/root/<path>`
是直接穿过目标的 root 去 `stat`。两条都**不切换 namespace**，所以一个卡住的容器不会把它们卡住。

两个 harness 各加了两道：

* **行为绊线**：stub 的 `nsenter` **存在且 exit 99**。只要被测脚本再叫一次，那一趟就带着 99 结束
  ——不是"输出少了一行"，是**点名**。
* **源码断言**：`notwant 'nsenter' "$(grep -v '^[[:space:]]*#' "$SRC")"`。**先剥掉注释行**，
  因为这一轮的注释自己在引用被删掉的那个调用，而第一版断言就是被自己的注释打红的。

---

## 5. 修法二：身份是每一步都要重读的**读数**（capture）

`scripts/host/zl1-post-recovery-capture.sh` 现在：

* 在每一步**之后**重读一次 `/proc/sys/kernel/random/boot_id`，界是 **`BOOT_CHECK_LIMIT=20`**，
  而且是**它自己的界**——一条死链路要花 20 秒，不是一步的 240 秒；
* 给每一步记一个状态，写进 `INDEX.txt` 的**每一行**：`same-boot` / `CHANGED-BOOT` / `unreadable` /
  `not-checked`；
* 把**第一次**变化完整记下来：`boot_switch: <步骤>: <旧 id> -> <新 id>`
  ——"之前是哪次、之后是哪次"才让这条界线**可用**，而不只是**已知**；
* 收尾判词是**三路**的：一直同一次 / 移动过 / **没建立起来**。

两个 harness 场景（`zl1-post-recovery-capture-selftest.sh` 第 8 节）：

* `FP_FLIP_BOOT_LMH=…`：复位**发生在 callee 里**（不是从外面翻 fixture），断言行是**逐行**标记的
  ——复位**之前**那一步仍然是 `same-boot`；
* `FP_UNLINK_BOOT_LMH=1`：重读**回来是空的**。它必须落在 `unreadable` 上，**不能**落在"还是那次"上
  ——否则收尾判词会在一次身份从未建立起来的运行上说"每一步都是同一次开机"，那是一句**读起来像证据的话**。

---

## 6. 修法三：`one-boot-runbook` 的名字也要能报否

真正跑出三次开机的是 **runbook**，不是 capture（capture 是它的 `01`）。所以同一个修法要落在它自己身上：

* `boot_check_after()` 在 `run_step()` 里，每一步之后重读一次（同样的 `BOOT_CHECK_LIMIT=20`）；
* `run_step()` 里 **先存下这一步自己的 rc，再重读**——重读会覆盖 `RB_RC`，而"一步报了 rc=0、
  手机在它底下复位了"是关于**这一步**的事实，不能被一次重读悄悄改成 `0`；
* `INDEX.txt` 的表头多一列 `boot`，头部多两行 `boot_check:` / `boot_switch:`；
* 收尾判词**独立于**步骤判词：一次运行可以**六步全过**却**不是一次开机**，也可以**失败一步**而手机从没动过。
  把两件事塞进一个 `if` 就是原来读不出东西的原因。

它和 capture 的**一处不同**：这里的步骤会**写**（02/03/04/06），所以中途复位意味着
**一次写可能被中断**——注记说的是这个，而不是只说"下面的读数属于另一台手机"。

### 6.1 写这一页时抓到的：修法自己漏了一行

`05-trial` 有它自己的 runner（它先 `scp` 再在设备侧下界跑，因为 `--apply` 默认要在设备上 settle 120 秒），
所以它**不经过 `run_step`**，而重读住在 `run_step` 里。结果：它的行停在 `not-checked`，
**而它是唯一一个 `--apply` 会写 SoC 电源参数的那一步**。

归档现在会**点名**：

```
boot_check_gap: 05-trial   <- this step RAN and was never asked which boot it ran on
```

`skip` 的行**不进这个名单**：它没跑，所以"没有重读"不是一个记录缺口；缺口是**跑了却没被问过**的行。
并且有一个 mutation（`nobootcheck05`，删掉 `boot_check_after 05-trial`）钉住这个仪器
——没有它，"6 of 6"就是一句**没有任何东西能证伪的话**。

### 6.2 还抓到的：两个 harness 的 `want` 不是同一个东西

成品断言是从 capture 的 harness 抄的，而那个文件的 `want` 是

```sh
want() { if printf '%s\n' "$2" | grep -Eq -- "$1"; then ok "$3"; … }
```

（**正则**），runbook 的 harness 是

```sh
want() { case "$2" in *"$1"*) ok "$3" ;; *) bad "$3" ;; esac; }
```

（**字面子串**）。所以 `want '^03-heat-chain +0 +CHANGED-BOOT'` 在第二个文件里是一个
**永远匹配不上的模式**——`+` 在 `case` 里没有量词的意义，`^` 和 `$` 只是两个普通字符。
它为一个**内容完全正确**的 `INDEX.txt` 报了 **8 个红**。修法是按这个文件的惯例来：
用 `grep` 把那一行**先取出来**，再对那一行做字面匹配。

---

## 7. 设备当前的样子（**2026-09-25 重读**）

按 doc 160 之后定下的规矩：设备状态要写**读它的日期**，并且要说**这一阶段有没有重读**。
这一阶段**重读了**，读数如下（全部是 2026-09-25 09:00–09:12 之间取的）：

| 读数 | 值 | 说明 |
|---|---|---|
| `boot_id` | `693b2eed-4460-46ae-9816-83b2a9220b00` | **第三次开机**，也就是上一轮那次运行里的第三次；到现在已经连续运行 57 分钟 |
| `uptime` | 3436s | SSH 通、RNDIS 通 |
| `/proc/sys/kernel/boot_reason` | `1` | 见下 |
| `/proc/sys/kernel/cold_boot` | `1` | 冷启动 |
| `lpm_levels.sleep_disabled` | `Y` | **散热第三因仍未安装** |
| `msm_thermal/enabled` | `N` | |
| `online` | `0-1` | `cpu2/cpu3` 离线 |
| `msm_therm` / `quiet_therm` | 44 / 44 | 度 |
| `pm8994_tz` | 43155 | **毫度** → 43.2 °C |
| `bms` | 38500 | **毫度** → 38.5 °C |
| tsens 最高（`tsens_tz_sensor17`） | 485 | **分度** → 48.5 °C |

三件事值得单独说：

1. **`boot_reason` 是一个新的、可查的仪器，而且它的表在内核源码里。**
   `drivers/platform/msm/qpnp-power-on.c` 里 `boot_reason = ffs(pon_sts)`，而
   `qpnp_pon_reason[]`（同文件 246 行）是
   `0=Hard Reset / 1=SMPL / 2=RTC / 3=DC 插入 / 4=USB 插入 / 5=PON1 / 6=CBL / 7=电源键`。
   所以 `boot_reason=1` 是 **`ffs` 的 1 基索引 → 下标 0 → "Triggered from Hard Reset"**，
   配合 `cold_boot=1`：这次**不是电源键按的**，是一次硬复位后的冷启。
   它**不能**区分"看门狗复位"和"软件 reboot"（两者都走 PS_HOLD），所以它是一半的答案——
   但它是**下一次**复位时唯一能说话的东西，因为 dmesg 的 ring **一分钟就绕完**，
   而 `pstore` 现在是**空的**（`ls /sys/fs/pstore/` 无内容），所以那两次复位**没有留下任何记录**。
2. **`cpu2/cpu3` 离线不是故障。** 08:02 的 `pre-state` 读的是 `online: 0-3`，那是采集在跑、
   手机在忙；现在空闲，`core_ctl`（`/sys/devices/system/cpu/cpu*/core_ctl/`，`Status: enabled`）
   把大核关掉了。而 `scaling_max_freq` 的 `1132800 / 1363200` 是**出厂值**，
   `install-cpufreq-governor.sh` 明确**不做频率上限**（它自己的注释里写了这一条）。
3. **温度仍然是 44–48.5 °C。** 和上一轮同一量级。三个散热因子里**只有两个**在真机上落过地
   （keeper 退休、governor），第三个（`sleep_disabled`）**一次都没装上**。

---

## 8. 顺手量到的第三件遗留：`zl1-v63-monitor.sh`

`install-retire-debug-keeper.sh` 退休的是 `zl1-debug-net.sh`（doc 72 的那个 keeper）。但设备上还有一个：

```
750 1 S  /bin/sh /usr/local/sbin/zl1-v63-monitor.sh
-rwxr-xr-x 1 root root  4475  /usr/local/sbin/zl1-v63-monitor.sh
-rw-r--r-- 1 root root  224740117  /userdata/zl1-v63-monitor.log     (+26969 B / 8s)
-rw-r--r-- 1 root root    7075283  /run/zl1-v63-monitor.log          (+28350 B / 8s)
```

* 它是 v63 镜像装进去的（doc 20），**ppid=1**，`/etc/systemd/system/` 里**没有**一个 unit 提到它；
* 它**还在写**，约 **3.4 KB/s**：`/userdata` 上已经 **224 MB**（约 290 MB/天），
  而 `/run` 上那份是 **tmpfs，也就是 RAM**；
* 它的 CPU 是 **单核的 ~4.6%**（`utime+stime` 在 5 秒窗口里走了 23 tick，而 `ps` 自己的
  生命期均值也是 4.6 — 两个读数一致）。
  它和 doc 72 的 keeper 是**两个进程**，退休那个**不碰**这个。

这不是这一轮的修复对象（它需要一次写、需要一次开机），但它是**散热清单上漏掉的一项**，
而且它是**只读地量到的**：一个采样窗口、两个文件的大小差、一个 pid、一次 unit 目录的查找。

---

## 9. 这一轮**没有**做的事

* **没有刷任何分区**，没有动 boot 镜像，没有进 EDL，没有碰 modem/EFS/calibration/persist；
* **没有重启设备**（两次复位是设备自己做的，时间为 08:06:02 和 08:11:47，都有 uptime 反推为证）；
* **没有安装散热第三因**（`06-lpm-fix` 被拒，`sleep_disabled` 仍是 `Y`）；
* **没有对那两次复位给出原因**。它们没有留下记录：`pstore` 空、dmesg 的 ring 一分钟就绕完、
  而 `boot_reason` 只读**当前**这次开机。

---

## 10. 阶段位置

这一轮把三个"看起来在回答、其实答的是另一层"的东西改成了会自己说出来的东西：
一个不能被打断的调用从只读链上删掉、一个 archive 的头部不再是标签而是与每行比较的读数、
一个脚本的名字第一次有了能报否的检验。**发烫仍然没有被解决**，而它的三个因子里
第三个到现在还没有装上——那需要一次开机，而这次开机的第一步就是让 `06-lpm-fix` 读到
一句 `supported-not-proven`。

下一步的顺序不变：

1. **闸门**：墙充 + `bash scripts/host/zl1-battery-gate.sh --samples 9 --interval 60`（doc 150）。
2. **闸门之后**：`scripts/host/zl1-one-boot-runbook.sh --yes`。这一轮之后，它的收尾判词会**自己说**
   这次到底是不是**一次**开机；`01-capture` 的每一个调用两侧都有界；`05-trial` 的行不再可能是 `not-checked`。
3. **跟着它的新读数**：`04b-modem` 和 `04g-video` 是这一轮换掉的两个调用点——
   它们要么**跑完**，要么明确打出"容器的 pid 回答了、它的挂载表没有"。**两种都是结果**；
   而它们**卡住**这件事本身，就是"`nsenter -m` 是那条复位相关性的嫌疑人"这个假设的反证或正证。
4. **只有用户明确同意才做**：刷 `halium-boot-zl1-v63-fpdriver.img` 或 `-modemfw`
   （撤销是刷回 `halium-boot-zl1-v63-rebuilt.img`，`ac0dd8619c05763c…`）。

**而这一页最后要说的一句是：这一次的教训不是"归档要写对"，是"归档自己不会比较"。**
三个 boot_id 一直是写在文件里的——设备一直在说，缺的是一个**每一步都问一次**的问题。
