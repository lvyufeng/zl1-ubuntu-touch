# 111 — netwatch 可以走 ssh 装了：TWRP 不再是发烫修复路上的必经一步

**日期**: 2026-09-23
**状态**: 纯离线的一轮。设备仍在 Qualcomm EDL（`05c6:9008` / port 3-3，无序列号），出来只能靠物理长按电源。
这一轮**没有**碰设备。它拆掉的是一个**流程上的路障**：`zl1-netwatch.service` 是这个端口里唯一
需要 TWRP 才能装的 unit，而它带的 `ensure_addrs()` 正是**让 debug keeper 可以退休**的那件事 ——
也就是剩下的那条发烫修复。设备一回来，装它不再需要先进 recovery 再出来。

**接续**: [`110`](110-the-lshal-columns-have-a-definition.md)（lshal 的列有定义）、
[`88`](88-the-addresses-are-ours-now-not-only-the-keepers.md)（地址现在是 netwatch 的活）、
[`94`](94-retiring-the-v63-debug-keeper-is-a-kill-not-a-unit-edit.md)（退休是一次 kill，不是改 unit）、
[`99`](99-the-remaining-heat-fix-was-broken-offline.md) / [`100`](100-the-other-half-of-the-heat-fix-and-the-only-misc-backup.md)（发烫修复的另一半，和那份唯一的 misc 备份）。

---

## 1. 一句话结论

| 问题 | 答案 |
|---|---|
| 挡住了什么？ | `zl1-boot-address-check.sh` 现在读 `inconclusive`，因为**装上去的那份 netwatch 没有 `ensure_addrs()`** —— 而 keeper 退休的门要求 `netwatch-configured`。要换掉那份构建，唯一的脚本是 `install-netwatch-service.sh`，它**只走 adb，而且要 TWRP** |
| 为什么这是个问题？ | 这条路障只在这**一个**安装器上。这个目录里其他每一个写 unit 的安装器（fingerprint、retire-keeper、container-desabotage、repowerd-ordering、shell-back-key）**都走 ssh，在跑着的设备上直接写 `/etc/systemd/system`** —— 那是同一个目录的活绑定挂载。TWRP 那一步什么也没换来 |
| 改了什么？ | `--yes --ssh`：不开 recovery、不读任何分区，在跑着的设备上把脚本和 unit 写进 `/etc/systemd/system`，然后 `sync`，由调用者重启 |
| 路上最容易写错的一处？ | **路径随传输方式而变，而且写错是静默的。** adb/TWRP 下 userdata 就是 `/data`，所以是 `/data/system-data/etc/systemd/system`；ssh 下**同一个名字是 Android 容器的 `/data`**，不是 UT 的 userdata —— 写进去会落在容器自己的文件系统里，输出看起来完全成功，而开机找不到 unit（和 misc 分区路径在 UT 与 TWRP 下不同是同一个形状） |
| 第二容易写错的一处？ | **它在替换一个正在跑的服务的脚本。** `sh` 是边跑边从文件里读脚本的，所以 `cat > $DEST` 会在活着的 watchdog 底下把文件截断，让它接着执行刚送到的任何字节。所以先写 `$DEST.new`、在设备上读回来核对、再用 `mv`（rename(2)）就位 —— 跑着的 shell 抓着旧 inode 把旧构建执行完 |
| 第三处？ | **misc 备份是"要求"而不是"自己去拍"。** 走 ssh 也要有那份已验证的备份（这个 unit 能往 misc 写 `boot-recovery`），但不会去读裸分区 —— 那会是对 adb 路径已经做过的那套交叉校验的第二次实现。没有就具名拒绝，并指出哪条路能拍 |
| 离线验证？ | `scripts/host/zl1-installers-selftest.sh` **278 检查 / 0 失败**（原来 229 条），新增第 14 节；**五次变异每一次都让它失败**（§4） |
| 这一轮没证明什么？ | **没有在设备上装过。** 走 ssh 的那一条路径在真机上从未执行过（见 §5） |

---

## 2. 那道路障是什么形状

设备回来之后，发烫修复的顺序是固定的：

```
设备回来 → 装带 ensure_addrs() 的 netwatch → 重启 → zl1-boot-address-check.sh 读 netwatch-configured
                                                                          ↓ 只有这一档发许可
                                                              install-retire-debug-keeper.sh --install --now
```

第二步是卡住的那一步。`install-netwatch-service.sh` 的第一行注释就是"with the device in TWRP"，
它用 `adb`，`BASE="/data/system-data/etc/systemd/system"` —— 因为在 TWRP 里 userdata 就是一个普通的
`/data` 挂载。而它做这件事的理由（写在同一个文件里）是：rootfs 运行时只读，`/etc/systemd/system`
是它的可写路径之一，bind 自 `/userdata/system-data/etc/systemd`，所以放进去的 unit 能活过重启。

**但是"必须从 TWRP 写"这个结论从来没有被需要过。** 这个目录里另外五个写 unit 的安装器
——`install-fingerprint-store-dir.sh`（`D=/etc/systemd/system`）、`install-retire-debug-keeper.sh`、
`install-repowerd-ordering.sh`、`install-shell-back-key.sh`、
`hybris-shims/install-container-desabotage.sh`—— 全都在**跑着的设备上走 ssh** 写 `/etc/systemd/system`，
而且都被记录为持久化了。原因是同一个：那是同一个 bind 挂载，从活的那一侧看过去就是 `/etc/systemd/system`。

所以 netwatch 是**唯一一个**绕远路的，而绕的这一步正好挡在剩下的发烫修复前面。

---

## 3. 三个必须处理对的点

### 3.1 路径随传输方式而变，写错是静默的

```sh
if [[ "$TRANSPORT" == "ssh" ]]; then
  BASE="/etc/systemd/system"
else
  BASE="/data/system-data/etc/systemd/system"
fi
```

**这一条是这一轮最危险的一处，因为它不报错。** 在跑着的设备上，`/data` 是**Android 容器的**
`/data`（`/dev/sda10[/android-data]`，bind 到容器里），不是 UT 的 `/userdata`。把 unit 写到
`/data/system-data/...` 会落在容器的文件系统里：`mkdir` 成功、`cat >` 成功、`ls -l` 成功、
输出逐字看起来和正确的一样 —— 然后下一次开机 systemd 找不到这个 unit，而唯一的线索是"它没生效"。

这和 [`49` §6 记的那件事是同一个形状](49-enter-twrp-from-ut-via-misc.md)：**misc 分区的路径在 UT 与
TWRP 下不同**。所以两个路径写成两个赋值、不是一个带条件的三元，让 `grep BASE=` 一眼能看到两条；
并且每次运行都**打印**它用的是哪条、以及哪个传输方式：

```
transport: ssh (root@10.15.19.82); unit path: /etc/systemd/system
```

### 3.2 它在替换一个正在跑的服务的脚本

netwatch 在装的时候**几乎肯定正在跑**（它就是那个每几秒采样的东西）。而 `sh` 是边执行边从文件里
读脚本的 —— 它不把脚本整个读进内存。所以：

```sh
cat > /etc/systemd/system/zl1-netwatch.sh      # ← 危险：在活着的 watchdog 底下截断它
```

会让正在执行的 shell 在下一个读取块时读到**刚送到的字节**，也就是半个脚本、或者别的东西。
web 上流传的"改 shell 脚本安全"是个误解，这在这里不是风格问题而是设备安全问题。

正确做法是**原子替换**：

```sh
"${SSH[@]}" "cat > '$DEST.new'" < "$SRC"     # 1. 写到旁边
"${SSH[@]}" "wc -c < '$DEST.new'"            # 2. 从设备读回字节数
"${SSH[@]}" "grep -q '^ensure_addrs()' '$DEST.new'"   # 3. 函数还在
"${SSH[@]}" "mv -f '$DEST.new' '$DEST'"      # 4. rename(2)：原子，跑着的 shell 抓着旧 inode
```

第 4 步是 `rename(2)`，不涉及对旧 inode 的任何写；跑着的 shell 保持它原来那个描述符，把旧构建执行完，
而新文件整体出现。**而且它不重启服务**，并且明说这一点：

```
The RUNNING watchdog was NOT restarted: it keeps executing the build it started with, and the
new one takes effect at the next boot -- which is the boot whose addresses have to be its job.
```

第 2、3 步也不是装饰。第 2 步是 [`100`](100-the-other-half-of-the-heat-fix-and-the-only-misc-backup.md)
那一族缺陷的直系亲属：一个只检查"文件在不在"的安装器，和一个只检查"传输没报错"的安装器，是同一个东西。
一个丢了尾巴的传输**在事后 `ls` 里没有任何痕迹**，只有字节数能看出来。第 3 步是 `88` 的那个判语
（`heal-first`）存在的理由：装了一份没有 `ensure_addrs()` 的构建。这里它读的是**设备上那一份**，
不是本地那一份 —— 传输把字节改坏而长度不变的唯一方式，就是长度检查看不出、这个 grep 看得出。

（诚实地说：`check-netwatch-integrity.sh` 是**第一道**闸，它在传输之前就跑了，所以一个缺函数的构建在
到达传输之前就被拒了。那个 grep 是设备侧第二次独立的读数，不是主要闸门 —— 这一点写在脚本里。）

### 3.3 misc 备份：要求，而不是自己去拍

那个 watchdog 能往 misc 写 `boot-recovery` 来进 recovery，所以那份备份和传输方式无关。
但走 ssh 的时候**不去读裸分区**：那会是对 adb 路径已经做过的那套交叉校验（读一次、再独立读一次
`wc -c`、不一致就拒绝记录）的第二次实现，而两条实现总有先腐坏的那一条。所以：

```
refusing: --ssh needs the verified misc backup at /mnt/data/zl1-backups/2026-09-17-misc/misc.img,
and it is not usable (above).
  Take one with the adb/TWRP route first:  install-netwatch-service.sh --yes        (device in TWRP)
```

现在主机上那份备份是好的（`misc.img: OK`，1 MiB），所以这条拒绝在真机上不会触发 —— 但它必须存在，
因为"没有备份也能装"正是这份备份存在的理由的反面。

---

## 4. 离线验证：278 检查，五次"必须失败"

`scripts/host/zl1-installers-selftest.sh` 新增第 14 节。它用的还是同一个 ssh 假设备
（`$FR`），因为那里 `/etc/systemd/system` 本来就是一个真目录 —— 这是重点：**同一个目录，从活的那一侧看**。

为了让这一节可测，harness 里加了三样东西：

* `paths.sed` 里多了 `/proc/device-tree` 的映射，假设备里放了一份 `qcom,msm8996` ——
  没有它，身份守卫会去读**主机自己的** `/proc`（那里没有 device tree），安装器就会拒绝，
  而那一节的所有断言都会变成关于 harness 这台机器的断言；
* ssh stub 多了 `FAKE_SSH_SHORT=N`：对 `cat > FILE` 形式的命令，只从 stdin 读 N 个字节再落地。
  这就是一次丢掉尾巴的传输，也是事后 `ls` 看不出来的那一种；
* 断言「TWRP 那棵树没被动过」之前**先把第 13 节留在那里的文件删掉** —— 否则这条断言是在检查
  "上一个场景写的文件还在"，一条不可能失败、但看起来完全像能失败的检查。

变异测试（一个不会失败的 harness 什么也证明不了）：

| 变异 | 结果 |
|---|---|
| M1 ssh 模式把 `BASE` 指回 TWRP 路径（最静默的那个） | `256 pass / **22 fail**` |
| M2 直接把 payload 写到活路径，不走 `.new` + `mv` | `259 pass / **19 fail**` |
| M3 去掉 misc 备份要求 | `274 pass / 4 fail` |
| M4 去掉字节数读回 | `277 pass / 1 fail` |
| M5 去掉设备身份守卫 | `275 pass / 3 fail` |

M1 的 22 个红点是这一节的主要产出：写错路径会让**几乎每一条**断言变红，而不是安静地过 ——
这正是"能失败"和"看起来能失败"的区别。

覆盖到的场景：无备份拒绝（并具名指路）、非 zl1 设备拒绝（且什么都没写）、
`--ssh` 装成（脚本逐字节等于源、可执行、unit、两个符号链接、`ExecStart` 是活路径）、
**TWRP 树没被动过**且**从没调用 adb**、**从没读过分区**、
payload 走 `.new` 且**没有任何命令直接写活路径**、字节数读回、`daemon-reload`、`systemctl cat`、
**不 restart / 不 enable 任何东西**、短传输在设备侧被拒且清掉 `.new`、活路径没被污染、
`--ssh --noheal` 动的是 UT 侧标记（不是 TWRP 侧）、`--ssh --remove` 只删自己那四条路径并保留日志、
未知参数退 2、`--ssh` 没有 `--yes` 仍然拒绝。

---

## 5. 这一篇**不**证明什么

* **不证明走 ssh 装过。** 这条路径**在真机上从未执行过** —— 设备在 EDL。离线覆盖的很彻底，
  但它证明的是"逻辑和失败路径是对的"，不是"这台上装好了"。
* **不证明 keeper 可以退休。** 这一轮只是让"装上新构建"这一步不再需要 TWRP。
  退休仍然要 `zl1-boot-address-check.sh` 读 `netwatch-configured`，而那要一次**重启**。
* **不证明发烫解决了。** 两条主要成因（keeper 烧满一个核、四个核钉在 `performance`）都还没在设备上装。
  走 ssh 的 netwatch 安装是它们的前置步骤，不是它们本身。
* **不证明容器路径的推论是量出来的。** `/data` 在跑着的设备上是容器的 `/data` 这一点来自
  [`106`](106-the-fingerprint-fix-is-the-directory-nobody-created.md) 记录的那个挂载
  （Android 的 `/data` 是 `/dev/sda10[/android-data]`，挂在 `/var/lib/android-data`），
  不是这一轮新量的。设备回来时 `--ssh` 会把它用的路径打出来，第一次跑就能核对。

---

## 6. 设备状态

设备在 **Qualcomm EDL**（`05c6:9008` / `QUSB__BULK`，port 3-3，无序列号）。整轮只读过主机上的
构建树、只读挂载和归档；**没有写任何分区或 boot，没有跑 QDL/QFIL，没有重启，没有拔插**。
识别目标按序列号前缀 **`33e80afe`**；总线上另一台设备 **`4a2fe00b`** 必须忽略。

下一步仍然是物理的：长按电源 10–20 秒，等 RNDIS 回来，然后
`scripts/host/zl1-post-recovery-capture.sh`。**那之后**，发烫修复的那条链现在少一步：

```
install-netwatch-service.sh --yes --ssh     # 不再需要 TWRP
```
