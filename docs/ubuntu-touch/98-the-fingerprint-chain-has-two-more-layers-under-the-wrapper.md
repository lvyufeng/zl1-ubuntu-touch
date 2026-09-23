# 98 — 指纹链在包装 HAL 底下还有两层：两个 store，三处静默

**日期**: 2026-09-23
**状态**: 纯离线的一轮（设备在 EDL，`05c6:9008` / port 3-3，与 `86`–`97` 同）。这一轮把指纹整条链从 **vendor 镜像**里读完，纠正了前几篇对它的一个简化，并把它变成探针里可测量的三节。设备整轮没有测量。

**接续**: [`83`](83-the-fingerprint-einval-is-a-missing-directory.md)（`SYS_EINVAL` 是一个缺失的目录）、[`90`](90-the-one-process-that-cannot-link-and-it-is-32-bit.md)（同一条链上的 32/64 位问题）、[`97`](97-both-hardware-probes-write-the-wrong-thing.md)（上一轮，两个探针写错了地方）。证据原文在 `docs/ubuntu-touch/evidence/fp-chain-2026-09-23.log`。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 这一轮读了什么？ | `vendor.img` 里的 `fingerprint.msm8996.so`、`gxfingerprint5118m.default.so`、`libfp_client5118m.so`、`libfpservice5118m.so`、`gx_fpd`，以及那个 rc |
| 纠正了什么？ | 之前把 `fingerprint.msm8996.so` 当成一个"薄客户端"。它不是：**它自己就带着 Goodix 的传感器逻辑**（`goodix_sensor_init/enroll/match`、`Fp::connect failed!`），binder 客户端在它下面**再一层库**里 |
| 那么 `Fp::connect failed!` 是对谁说的？ | 对 **`gx_fpd`**：`libfp_client5118m.so` 去 servicemanager 取 `FingerPrintService`（接口描述符 `android.hardware.IFpService`），提供者是 `gx_fpd` |
| 有几个 store？ | **两个**，而且**不是同一层写的**：外层 `/data/system/users/0/fpdata/`（`fingerprint.msm8996.so` 里硬编码，也是 biometryd 传的、包装 HAL `access()` 的那条），内层 `/data/gf_data/*`（最里那层 HAL 自己 `fs_mkdirs`） |
| 所以 `83` 的结论冲突吗？ | 不冲突，是**不完整**。`access(W_OK)` 是**第一处**静默，不是唯一一处；它后面还有两处，任何一处都能让"目录建好了"变成一句空话 |
| 三处静默 | ① 包装 HAL 的 `access(W_OK)`（`83`，有设备证据）② `gx_fpd` 没在跑（`getService` 拿到 null）③ 内层 HAL 的 `/data/gf_data`（它从不读 biometryd 传的路径） |
| 探针现在测什么？ | 第 3 节把这三处变成三个**分别可答**的问题：`hw_get_module` 选了哪个模块、那个模块要的守候进程在不在、内层 store 在不在 |
| 一个必须记住的坑？ | `/vendor` 是**容器的**树。主机的 `test -f /vendor/...` 会把每一个模块都报成"不存在"——那正好读成"这个 HAL 没装"，是本轮新代码第一版犯的错（§5） |
| 怎么证明这条检查有牙？ | 把同一份脚本里的 `nsenter -t "$A" -m -- test -f` 改成主机的 `test -f`，它就对**同一个容器**说 "no variant match"；真脚本说 "variant match" |
| 动设备了吗？ | 没有。镜像只读挂载，跑完就卸；探针里的容器属性/模块列表/`/proc` 遍历/logcat 计数全是**合成**的 |

---

## 2. 整条链，从镜像里读出来的

每一行都有出处，原文在 `evidence/fp-chain-2026-09-23.log` 第 1–6 节。rc 里就是两个服务，供应商还自己写下了为什么要延迟启动：

```
service fps_hal /vendor/bin/hw/android.hardware.biometrics.fingerprint@2.0-service.leeco_zl1
    # "class hal" causes a race condition on some devices due to files created
    # in /data. As a workaround, postpone startup until later in boot once
    # /data is mounted.
    class late_start
    user system

service gx_fpd /vendor/bin/gx_fpd
    class late_start
    user system
```

"because of files created in /data" —— 供应商自己知道这条依赖。而这个树里**没有任何一条 rc 去建**那个目录（内层那个 `/data/gf_data` 是 HAL 自己建的）。

链（`->` 是一次真实的调用/加载）：

```
BiometricsFingerprint::setActiveGroup                  包装 HAL；access(W_OK) 的闸门（83）
  -> FingerprintDaemonProxy::setActiveGroup            同进程 binder
    -> mDevice = hw_get_module("fingerprint")          AOSP 的变体顺序：
         ro.hardware / ro.product.board=msm8996 / ro.board.platform=msm8996 / ro.arch
       => /vendor/lib64/hw/fingerprint.msm8996.so      变体命中，赢；SONAME 是
          libfingerprint5118m.default.so。它自己带着 Goodix 传感器逻辑
          （goodix_sensor_init/enroll/match、"Fp::connect failed!"、"Init goodix sensor failed!"），
          并硬编码 /data/system/users/0/fpdata/  —— 外层 store
       => /vendor/lib64/hw/gxfingerprint5118m.default.so   只能以 ".default" 被取到
       -> libfp_client5118m.so  getService("FingerPrintService")
          （接口描述符 android.hardware.IFpService；
            "FingerPrint, getService failed, try again later."）
     -> gx_fpd  （/vendor/bin/gx_fpd，late_start，user system）提供 FingerPrintService
       -> libfpservice5118m.so 调 hw_get_module("gxfingerprint5118m")
         => /vendor/lib64/hw/gxfingerprint5118m.default.so   真正的内层 HAL
            八个 /data/gf_data/… 根、fs_mkdirs、chdir，
            链 libQSEEComAPI.so 与 libfpnav5118m.so，开 /dev/goodix_fp、/dev/ion
              -> TEE，走 /dev/qseecom（rc 里 chmod 0666）
```

**两个 store 归谁，可以用计数分开**（`strings -a | grep -c`，见证据第 6 节）：

| 模块 | `/data/gf_data` | `users/0/fpdata` | `goodix_fp` | QSEECom |
|---|---|---|---|---|
| `fingerprint.msm8996.so`（变体赢的那个） | 0 | **1** | 0 | 0 |
| `gxfingerprint5118m.default.so`（`gx_fpd` 加载的） | **8** | 0 | **1** | **5** |

所以"目录建好了指纹就该通"是**三段论里少了两段**：`fingerprint.msm8996.so` 只碰 `fpdata`，`/dev/goodix_fp` 和 TEE 全在它够不到的另一层里。

---

## 3. `83` 的结论不冲突，它只是第一处静默

`83` 论证的是：`setActiveGroup` 的 `SYS_EINVAL` 来自那行**不打日志**的 `access(storePath, W_OK)`，因为 `system_server`（真 Android 里建这个目录的人）在这个 port 上不存在。这一轮读完之后，它依然是**唯一有设备证据**的一处——但它后面还有两处同性质的静默：

1. **`gx_fpd` 没在跑。** `libfp_client5118m.so` 的 `getService("FingerPrintService")` 拿到 null，它会 `Fp::reconnect()` 反复重试（"try again later"、"go into while FingerPrint,getFingerPrintService()"）。表现是**包装层一个字都不说**。
2. **内层 HAL 自己的 `/data/gf_data`。** 它 `fs_mkdirs` 建这八个根，**从不读** biometryd 传进来的路径。所以 `fpdata` 建好了、`gx_fpd` 也在跑，仍然可能在这里停住，而这一层的失败同样不会出现在包装 HAL 的日志里。

一个必须说清的边界：`Fp::connect failed!` 是**模块里的一个字符串**，不是设备日志里见过的一行。我在仓库里搜过，它从没被观测到。所以正确读法是"这是一处要找的地方"，而不是"这就是失败点"——探针现在把它和 `getService failed` 一起计入 logcat 计数，**计数为 0 正好与 `83` 一致**（失败在更早的那道闸门上）。

---

## 4. 探针改了哪里：三处静默变成三个能分别回答的问题

`scripts/device/zl1-fingerprint-probe.sh` 新增第 3 节 `under the wrapper: which module loads, and the daemon it needs`，仍然全是只读：

* **`hw_get_module` 会选谁**：在容器里读 AOSP 变体顺序用的四条 property（`ro.hardware`/`ro.product.board`/`ro.board.platform`/`ro.arch`），按 `variant_keys` 的顺序在 `/vendor/lib64/hw`、`/system/lib64/hw`、`/odm/lib64/hw` 里找 `fingerprint.<variant>.so`，命中就打印并说明**这个模块是什么角色**（带 Goodix 传感器逻辑、binder 客户端在下一层库、硬编码 `fpdata`）。
* **磁盘上到底有什么**：列出容器看到的那两个目录里所有 `finger*`/`gxfinger*` 大小。这样"选了哪个模块"是一个**观测**，不是推断。**只用大小**：`readelf`/`strings` 是主机工具，设备上根本没有，ELF 与链接事实留在它们被测量的地方（`scripts/host/zl1-vendor-link-audit.sh`，离线对着镜像跑）。
* **守候进程**：`/proc/*/cmdline` 找 `gx_fpd` 并给 pid/uid；再用 `nsenter -p` 到容器里跑 `/system/bin/service list` 找 `FingerPrintService`。**binder 命名空间是容器的**，主机自己那条 `service list` 永远答"没有"（`51` 的规则）。
* **第二个 store**：`/data/gf_data`、`/data/gf_data/enroll`、`/data/system/users/0/fpdata`，全部 `nsenter -t $A -m -- test -e`，并印出模式/uid/gid。
* **设备节点**：`/dev/goodix_fp`、`/dev/qseecom`、`/dev/ion`，并附一句"如果容器的 rc 没跑过 `on boot` 那段，这里看到的就是 HAL 看到的权限"。
* **logcat 计数**：加了 `fps_hal`、`gx_fpd`、`Fp::connect failed`、`getService failed` 四条模式。少了哪一行，和 `83` 的推理是同一类证据。

---

## 5. 一个必须走容器命名空间的坑，和那条有牙的检查

新代码第一版写的是主机上的 `[ -f /vendor/lib64/hw/fingerprint.$v.so ]`。**主机上没有那个树**（这个脚本跑在 UT 侧），于是每个模块都报 `MISSING`——而那句话读起来正好是"这个 HAL 没装"，**恰好是本节要排除的那个结论**。修法是把每个路径都走 `nsenter -t "$A" -m --`，和第二处 store 的写法完全一致。

这种错误光看代码看不出来，所以 harness 里加了一条**会失败的检查**：把同一份改写后的脚本里的 `nsenter -t "$A" -m -- test -f` 换成主机的 `test -f`，然后断言它**找不到**模块：

```
$ diff $W/fp.sh $W/fp.hostpath.sh
208c208
<       if [ -z "$pick" ] && nsenter -t "$A" -m -- test -f "$d/fingerprint.$v.so"; then
---
>       if [ -z "$pick" ] && test -f "$d/fingerprint.$v.so"; then

   -- 真脚本（容器里两个模块都在）:   -> variant match: /vendor/lib64/hw/fingerprint.msm8996.so
   -- 变异体（同一个容器）:           -> no variant match; AOSP would fall back to fingerprint.default.so
```

如果变异体也能"找到"模块，§4 的那几条断言就什么都没测。

**这一轮还在 harness 自己身上找到两个"只能通过"的检查**（证据第 11 节）：

1. 改写后的脚本仍在读 `/proc/$gxp` 拿 `gx_fpd` 的 uid——`rewrite()` 是**逐条列举**要搬进假根的变量的（`/proc/$H`、`/proc/$_pid`），`$gxp` 不在名单里。主机上没有 `/proc/7777`，于是 uid 读成**空**，而这个场景**照样通过**：分支跑了，答案是空的。修法是一条**计数式**的落地检查（`grep -o '/proc/\$'` 的条数必须等于 `$FR/proc/\$` 的条数），不合格就拒绝运行。它立刻抓出**第二个**：`/proc/$A` 那条规则原本是个 no-op（`s#/proc/\$A#/proc/\$A#g`），于是"HAL 与容器的 mount namespace 是否相同"是在**两条不存在的路径**上比的——两个空字符串相等，答"相同"，理由完全错。现在两条都是真路径，并有一节专门驱动"不同"那个分支。
2. `notwant '^systemctl restart (?!lomiri-location-service)'` 在 ERE 里用了 PCRE 的前瞻，**匹配不到任何东西**，于是永远通过。改成计数：`restart` 恰好一条。

这两条都不是新代码的缺陷，是 harness 自己的：**一个只会通过的断言，和一个不存在的检查，代价是一样的。**

---

## 6. 这一轮**不**证明什么

* **对设备的结论：零。** 设备在 EDL；探针跑的每一条 property、模块列表、`/proc` 遍历、logcat 计数都是**桩**给的答案。`MISSING /data/gf_data` 是假根树的回答，不是设备的回答。
* **"模块在磁盘上"不等于"模块被加载了"。** §2 读的是 `vendor.img`——一个文件，而且是设备在跑的那个镜像——但它回答不了 `hw_get_module` 在**那一次启动**里选了什么。
* **三处静默里哪一处真的在设备上发生，没有被判定。** `access(W_OK)` 是唯一有证据的；`gx_fpd` 与 `/data/gf_data` 是它后面的两个候选。探针现在把三处**分开量**，而不是假设第一处能解释其余。
* **两个 store 的先后顺序没有被证明。** 只有到了设备上，第 3 节的三个答案与 logcat 的四条计数一起看，才能说清是停在哪一层。
* **`libfpnav5118m.so`（内层 HAL 的导航库）没有被读。** 它存在（17800 字节），这一轮没有看它。
* **`90` 那条 32 位的结论没有被动过。** `vsimd` 的 ELF class 不匹配是另一条线上的事。

---

## 7. 复现

```sh
# 镜像只读挂载，读完整条链，然后卸掉
mkdir -p /tmp/fpcheck
sudo mount -o ro,loop /mnt/data/zl1-backups/2026-06-07-adb-root-staged/vendor.img /tmp/fpcheck
cat /tmp/fpcheck/etc/init/android.hardware.biometrics.fingerprint@2.0-service.rc
for f in /tmp/fpcheck/lib64/hw/fingerprint.msm8996.so /tmp/fpcheck/lib64/hw/gxfingerprint5118m.default.so; do
  readelf -d "$f" | grep -iE 'NEEDED|SONAME'
  strings -a "$f" | grep -E '^/data/gf_data|users/0/fpdata|Fp::connect failed|goodix_sensor_init'
done
sudo umount /tmp/fpcheck

# harness（110 项，纯主机，不碰设备）
sh scripts/host/zl1-loc-fp-selftest.sh
sh scripts/host/zl1-loc-fp-selftest.sh --keep      # 留下假根树、改写后的脚本、变异体

# 回到设备之后，这一条就是恢复顺序里的第 3 项
sh scripts/device/zl1-fingerprint-probe.sh                    # 只读：三处静默各在什么状态
sh scripts/device/zl1-fingerprint-probe.sh --create-store-dir # 唯一会写的模式，只建它判定的那一条
```

| 文件 | 作用 |
|---|---|
| `scripts/device/zl1-fingerprint-probe.sh` | 加第 3 节：模块变体选择、磁盘实况、`gx_fpd`、`FingerPrintService`、第二个 store、设备节点；logcat 模式加 `fps_hal`/`gx_fpd`/`Fp::connect failed`/`getService failed`；头部改成读出来的那条链。每个路径都走 `nsenter -m` |
| `scripts/host/zl1-loc-fp-selftest.sh` | 110 项（`97` 时是 84）。加第 9 节：链路的每个问题、两个 store、守候进程两个分支、binder 服务两个分支、namespace 相同/**不同**两个分支、以及那条变异体检查；另外修了 harness 自己的两个假检查，并加了"每个 `/proc/<var>` 都必须搬进假根"的落地检查 |
| `docs/ubuntu-touch/evidence/fp-chain-2026-09-23.log` | 这一轮的原始输出：镜像里每条断言的原字符串、110 项全文、对着 `HEAD` 的 16 条红、变异体的对照、harness 的两个坑 |
| `docs/ubuntu-touch/98-*.md` | 本篇 |
