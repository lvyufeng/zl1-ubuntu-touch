# 90 — `vsimd` 一直起不来，原因不是命名空间，是这个文件（32 位那份）根本不存在

**日期**: 2026-09-23
**状态**: 纯离线的一轮（设备在 EDL，与 `86`–`89` 同）。这一轮把 `70` §6(2) 那条挂了很久的日志解释清楚了，而且结论与之前记录的推断**不一样**：

```
F linker  : CANNOT LINK EXECUTABLE "/vendor/bin/vsimd": library "libQSEEComAPI.so" not found
```

`70` 把它归进"链接器/命名空间那一族"（`66` 的 `DT_NEEDED` 传递、`55` 的 `pc=0x0`），也就是说"这得在设备上查"。**不需要。**答案完全由项目已经在主机上的那两个镜像决定，而且是这一族里最无趣的那个：

> **`/vendor/bin/vsimd` 是 ELF32；全设备唯一的 `libQSEEComAPI.so` 在 `/vendor/lib64/`，是 ELF64 AArch64。32 位进程在任何搜索路径上都装不了 ELF64 的库**——所以链接器说的 "not found" 是字面意思，没有任何命名空间规则能改变它。

**接续**: [`70`](70-the-landscape-was-the-shell-laying-itself-out.md) §6(2)（原始的观察）、[`66`](66-the-input-layer-vendor-symbol-was-libinputservice.md)（`DT_NEEDED` 那一族）、[`71`](71-the-sensors-stream-the-restart-kills-the-hal.md) §4（把它列为"剩下的两条"之一）、[`88`](88-the-addresses-are-ours-now-not-only-the-keepers.md)（同样是"先查源码/镜像，别急着上设备"的一轮）

---

## 1. 结论与它推翻的东西

| 之前的记录 | 实际 |
|---|---|
| `70` §6(2)：这是"链接器/命名空间那一类问题"，因为**文件是存在的** | 存在的那个文件是 **64 位**的。存在的文件与需要的文件不是同一个东西——这仍然是 [`66`](66-the-input-layer-vendor-symbol-was-libinputservice.md) 那个形状的陷阱（"名字对上了"不等于"那是同一个对象"），只是这次差的不是路径，而是 **ELF class** |
| `70` §6(2)：`/dev/qseecom` 在、`slpi` 是 `ONLINE`，"TEE 那一侧看起来是好的" | 与本题无关。`vsimd` **根本没走到**打开 `/dev/qseecom` 那一步：它在 `execve` 之后的链接阶段就死了，进程里没有一行是 TEE 的 |
| `71` §4：把它列在"还差的两条"里，与传感器一起 | 它不是传感器链路上的一环（见 §6），而且它是**唯一**一个这样的进程（见 §3） |

## 2. 三条证据，都能离线判

**(a) ELF class 不匹配。** 从 `2026-06-07-adb-root-staged` 的两个镜像里 dump 出来直接读：

```
$ file vsimd libQSEEComAPI.so
vsimd:            ELF 32-bit LSB shared object, ARM, EABI5, interpreter /system/bin/linker
libQSEEComAPI.so: ELF 64-bit LSB shared object, ARM aarch64
$ readelf -h vsimd | grep -E "Class|Machine"
  Class:  ELF32    Machine: ARM
$ readelf -h /vendor/lib64/libQSEEComAPI.so | grep -E "Class|Machine"
  Class:  ELF64    Machine: AArch64
$ ls -l /vendor/lib64/libQSEEComAPI.so      # 31352 -- 与 70 在设备上看到的是同一个大小
```

`vsimd` 的 `DT_NEEDED` 里确实是 `libQSEEComAPI.so`（还有 `libvsim.so`、`libGPTEE_vendor.so`、`vendor.xiaomi.hardware.vsimapp@1.0.so`、`libhidlbase` 等）。

**(b) 32 位那份在两个镜像里都不存在（查过，不是假定）。** `vendor.img` 与 `system.img` 整树找 `*qseecom*`：只有 `/vendor/bin/qseecomd` 和 `/vendor/lib64/libQSEEComAPI.so`。`/vendor/lib`（32 位目录，526 个文件）与 `/system/lib`（586 个）里都没有。

**(c) 谁在启动它。** `/vendor/etc/init/vendor.xiaomi.hardware.vsimapp@1.0-service.rc`：

```
service vendor.vsimservice /vendor/bin/vsimd
    class hal
    user system
    group system
```

`class hal` 意味着容器里的 init 会**一直重启它**——这就是 `70` 测到的"每 ~5 秒一次"。

## 3. 顺手把 Android 侧全扫了一遍：只有一个

既然"某个 soname 找不到"能被镜像直接判，那就该对整个 Android 侧问一次：**每个 ELF 的每个 `DT_NEEDED`，在它自己那个 class 的目录里找得到吗？** 这变成了 `scripts/host/zl1-vendor-link-audit.sh`。跑出来（完整日志：[evidence/vendor-link-audit-2026-09-23.log](evidence/vendor-link-audit-2026-09-23.log)）：

**可执行文件：3 个有未解析的依赖，其中只有 1 个有 init 会去启动它。**

| 文件 | class | 缺什么 | init 会启动吗 |
|---|---|---|---|
| `/vendor/bin/vsimd` | 32 | `libQSEEComAPI.so` | **会**（上面那个 rc，`class hal`）|
| `/vendor/bin/mdm_helper` | 64 | `libmdmimgload.so` | 不会：**两个镜像里都没有任何 .rc 提到它** |
| `/vendor/bin/mdm_helper_proxy` | 64 | 同上 | 不会 |

`libmdmimgload.so` 在 `vendor.img` 和 `system.img` 里都**不存在**，所以这两个 `mdm_helper*` 谁启动谁失败——但没人启动它们，它们是死的文件，不是故障。这正是这个脚本要说清楚的区别：**一个列在目录里的文件和一件会反复发生的事，不是同一件事。**

**库：16 个有未解析的依赖**，逐个看它们被谁引用，全部落在两类里：

* **没有任何东西引用它**（`libcppf.so`、`libmialgoengine.so`、`libmm-qdcm-diag.so`、`(*)-touchcompanion@1.0-service.so`、`com.quicinc.cne.server@1.0.so`…）——死文件；
* **只有"另一个 class"的引用者**。这一条是这次差点被写错的地方：soname 在 `DT_NEEDED` 里是**不带 class 的字符串**，64 位的 `libmt.so` 需要的 `libmfido.so` 会在 `lib64/` 里解析，和 `lib/` 里那份 32 位的死亡副本没关系。所以脚本给每个引用者标了它自己的 class：

```
/vendor/lib/libdsi_netctrl.so  ELF32  missing: libnetmgr.so libconfigdb.so
    <- referenced by /vendor/bin/imsdatadaemon (ELF64)      <- 解析的是 lib64/libdsi_netctrl.so（存在）
    <- referenced by /vendor/lib64/lib-imsdpl.so (ELF64)
    ...
/vendor/lib/libvsim.so         ELF32  missing: libQSEEComAPI.so
    <- referenced by /vendor/bin/vsimd (ELF32)              <- 同 class，只有这一条是真的
```

**同一 class 的引用链只有一条通向"init 会启动的东西"：`vsimd` → `libvsim.so` → `libQSEEComAPI.so`。** 其他 32 位 TEE 客户端（`libmlipay`、`libtida`、`libmfido`、`libkeymaster*`、`libmt`）**每一个在 `lib64/` 里都有 64 位的兄弟**，而需要它们的 `fidoca` / `mlipayd@1.1` / `tidad@1.1` / `cnd` / `libmt@1.2.so` 全是 **ELF64**——它们用的是 64 位那份。所以那 32 位的一套是上一代 vendor 集合的残留。

## 4. 这个工具的第一版自己撒了谎（而且是最坏的一种）

第一版把"某个 soname 在不在列表里"写成 `printf '%s\n' "$list" | grep -qx "$name"`。它在**同一个镜像上跑两次，会报出不同的、毫不相干的可执行文件链接失败**（`profman` 缺 `libc.so`、`dex2oat` 缺 `libdl.so`、`audio@2.0-service` 缺 `libhardware.so`——这些文件在 `/system/lib` 里都在）。

也就是说：**如果我把第一次的输出直接写进这篇文档，我就会给这个端口凭空造出一串不存在的故障。**机制没能完全钉死（`set -o pipefail` 下"写端被 SIGPIPE 打断"会让管道的退出码不是 0，这个 shell 里确实能造出 `141`，但在 28 KB 这个量级上单独复现不出来；它只在脚本那种高负载、每次调用都 fork 的环境里出现）。所以我不声称机制，只陈述两件已测的事：**旧写法在相同输入下不稳定，新写法（`case` 模式匹配，没有管道、没有写端）连跑两次逐字相同。一个会在同一输入上变答案的布尔值，不能当证据用。**

## 5. 修法存在，而且不用编译——但我建议先不修

`vsimd` 需要的那个 32 位文件，**项目里已经有了一份**：

```
$ find /mnt/data/halium-zl1-build/vendor/leeco -name libQSEEComAPI.so
vendor/leeco/s2/proprietary/vendor/lib/libQSEEComAPI.so     <- ELF32，SONAME 相同，NEEDED 列表与 64 位那份逐条相同
vendor/leeco/s2/proprietary/vendor/lib64/libQSEEComAPI.so
vendor/leeco/msm8996-common/proprietary/vendor/lib64/libQSEEComAPI.so
```

注意：**`zl1` 自己的 blob 集合里没有 32 位那份**（`vendor/leeco/zl1/proprietary/vendor/lib`，181 个文件），`msm8996-common` 里也没有。`s2` 是另一个 LeEco 机型，它的 32 位集合里有。也就是说这个 32 位库本来就随 LeEco 的 msm8996 ROM 一起存在过（合理的猜测是：Android 6 时代它在 `/system/lib`，做 Android 9 的 vendor 分区时 32 位那一套没跟上来——**这只是猜测，镜像里已经看不到 6.0 的 system**），`vsimd` 因此在这个 ROM 上大概**从来**没成功启动过。

所以有条便宜的实验路径：把这个 32 位 `.so` 绑进容器（`/vendor` 是只读分区，所以要走 lxc 的 bind mount，不能写分区），看 `vsimd` 是否起来、那个 HAL 是否注册。

**但我建议现在别做**，理由是诚实的成本收益：

* `vsimd` / `vsimapp` 是**小米虚拟 SIM** 那一套（同一个 vendor 分区里还有 `vendor.xiaomi.hardware.mlipay/mfido/tida/mtdservice`），而 Android 9 那一侧还有 `VsimCore.apk` + `vendor.xiaomi.hardware.vsimapp-V1.0-java.jar` + `system/lib/vendor.xiaomi.hardware.vsimapp@1.0.so`。**这台设备上没有它的硬件**，它连不上任何东西。
* 它每 5 秒崩一次确实是个反复发生的事，但一次链接失败 + 退出的开销很小，**不要把它算成散热问题**（这一条我特意写死，因为"运行时报错"太容易被顺手说成"发热原因"）。
* 真正的收益是**消掉一条背景噪声和一条假线索**，不是修好一个设备功能。所以它排在 GPS / 指纹 / 传感器 / 散热之后，而且要等设备能用了再说。

## 6. 它**不**解释什么

* **不解释加速度计/陀螺仪没注册**（`70` §6(1)：`sensorfw` 只注册了 `magnetometersensor` 和 `orientationsensor`）。`vsim` 不是传感器，`vsimd` 也不在任何传感器链路上——那件事仍然是它自己的问题，而且仍然需要 `70` §6(4) 那"一只手举 20 秒"的现场测量。**这一轮没有缩小那个问题的范围**，只是把它旁边的一个噪声源解释掉了。
* **不解释** `system_server` 缺失（`70` §6(3)）、`ISensorManager` 等待、`libui_compat_layer.so`（`70` §6 的其他条目）。
* **不证明设备上的 `/vendor` 与这份备份逐字节相同**。vendor 分区在整个移植过程中没有被本项目写过（只刷过 `boot`），而 `70` 在设备上量到的 `libQSEEComAPI.so` 大小 31352 与备份里的一致，所以这份备份可信；但"可信"和"已核实"是两件事。设备回来之后一条命令能定：

```sh
ls -l /vendor/lib/libQSEEComAPI.so 2>&1        # 期望：No such file
readelf -h /vendor/bin/vsimd | grep Class      # 期望：ELF32
```

## 7. 一个更该记住的坑：校验通过不等于能用

这一轮为了拿镜像，先试的是 `2026-06-07-adb-root-exact`：

```
$ sha256sum -c SHA256SUMS | grep -c ': OK'   ->  31   (31 条全过)
$ sudo mount -o loop,ro,noload .../vendor.img /mnt/x
  mount: mount(2) system call failed: Structure needs cleaning
$ debugfs -R "stat <2>" .../vendor.img       ->  Inode: 2  Type: bad type  (inode 表是垃圾)
```

**同一天、同一批分区的 `2026-06-07-adb-root-staged` 副本能正常挂载。**两份各自的 `SHA256SUMS` 都通过。所以：**校验和证明的是"字节没坏"，不是"这些字节是一个文件系统"**——这正是 [`34`](34-correction-the-100-percent-was-the-watchdog.md) 那个形状（"仪器报出来的数"不等于"那件事"）在离线工作里的版本：**校验和是一个仪器，它有它答不了的问题。**以后取镜像默认用 `-staged`；审计脚本默认值就是它，而且有人指到 `-exact` 时会明确警告。

## 8. 复现

```sh
# 主机上，不需要设备（设备在 EDL 正好）
scripts/host/zl1-vendor-link-audit.sh            # 自己挂载 -staged 两个镜像、跑完卸掉
scripts/host/zl1-vendor-link-audit.sh --exec-only --quiet   # 只看 init 会启动的那些
scripts/host/zl1-vendor-link-audit.sh --help

# 手工要那三条事实（都只读）
sudo mount -o loop,ro,noload /mnt/data/zl1-backups/2026-06-07-adb-root-staged/vendor.img /mnt/v
debugfs -R "dump /bin/vsimd /tmp/vsimd" /mnt/data/zl1-backups/2026-06-07-adb-root-staged/vendor.img
file /tmp/vsimd && readelf -d /tmp/vsimd | grep QSEE
sudo find /mnt/v -xdev -iname '*qseecom*'
```

| 文件 | 作用 |
|---|---|
| `scripts/host/zl1-vendor-link-audit.sh` | 新增。离线只读审计：每个可执行文件/库的 `DT_NEEDED` 是否能在同 class 的目录里解析；可执行文件再对照 init 的 `.rc` 判断"有没有人启动它"，库再对照引用者判断"是不是死文件"。退出码 0 = 没有 init 会启动的可执行文件是坏的，1 = 有 |
| `docs/ubuntu-touch/evidence/vendor-link-audit-2026-09-23.log` | 本轮的原始输出与镜像身份 |
| `docs/ubuntu-touch/90-*.md` | 本篇 |

## 9. 这一轮**不**证明什么

* **不证明设备上的 vendor 分区与备份一致**（§6），两条命令可核。
* **不证明** `vsimd` 在装回 32 位库之后能正常工作：链接成功只是第一步，它还需要 `/dev/qseecom` 与 TEE 里对应的 TA，而**这台设备的 TEE 里有没有那个 TA 完全未知**（`58` 记着 `scm_call` 在这台设备上会返回 -12）。所以那条实验只应该被当成"试试链接能不能过"，不是"能修好"。
* **不证明**这一轮对任何用户可见的功能有改善——它去掉的是一条噪声和一条假线索。
* **不改动设备**：设备在 EDL，本轮对它的操作是零；上面的"修法"没有执行，也**不应该**在没有明确许可的情况下执行（它要在设备上写文件、并且要动容器的挂载表）。
